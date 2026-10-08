-- The visualizer's own behavior as one parallel chart (it dogfoods the
-- application model; design/statecharts.md §6):
--   connection  where records come from: in-process, a replayed recording
--               file, or a --dev endpoint with push (subscribe) and a
--               polling fallback, detaching and retrying on errors;
--   view        which actor is shown, and following live vs scrubbing vs
--               playing a recording;
--   editor      the payload editor for events with fields;
--   screen      the HMI hierarchy: overview (Level 1/2) -> unit statechart
--               (Level 3) -> record detail (Level 4);
--   watch       one timer for the next possible stuck-state alarm.
-- Alarm acknowledgements are context (`acked`, keyed by alarm id).
-- Effects are injected `services` (invokes and one-shot tasks), so storybook
-- and tests can run the chart without sockets. Inspected data itself lives
-- in model.lua; RECORDS events bump `revision` and carry per-actor counts.
local ouro = require('ouro')
local machine = ouro.machine
local assign = machine.assign

-- Drafts are text; convert them for the field's declared type.
local function convert(kind, text)
  local base = tostring(kind):gsub('%?$', '')
  if text == nil or text == '' then return nil end
  if base == 'integer' then return math.tointeger(tonumber(text)) or text end
  if base == 'number' then return tonumber(text) or text end
  if base == 'boolean' then return text == 'true' or (text ~= 'false' and text) end
  return text
end

local function clamp(c, value)
  local n = c.counts[c.selected] or 0
  return math.max(1, math.min(n, value))
end

return function(services)
  return machine.create {
    id = 'visualizer', type = 'parallel', order = {'connection', 'view', 'editor', 'screen', 'watch'},
    context = function(input)
      return {
        mode = input.mode, address = input.address or false, path = input.path or false,
        revision = 0, actors = {}, counts = {}, after = 0, seed = false, gaps = 0,
        acked = {}, wait = false, alarm = false,
        selected = false, cursor = false, message = false, editor = false,
      }
    end,
    events = {
      RECORDS = {revision = 'integer', actors = 'table', counts = 'table', after = 'integer?', seed = 'integer?', gaps = 'integer?',
        wait = 'number?'},
      ATTACHED = {},
      SELECT = {value = 'string'},
      SCRUB = {value = 'number'},
      STEP = {delta = 'integer'},
      LIVE = {}, PLAY = {}, PAUSE = {},
      INJECT = {name = 'string'},
      EDIT_PAYLOAD = {name = 'string', fields = 'table'},
      FIELD = {name = 'string', value = 'any'},
      SEND_PAYLOAD = {}, CLOSE_EDITOR = {},
      OVERVIEW = {}, UNIT = {}, RECORD = {},
      OPEN_ALARM = {id = 'integer', actor = 'string', step = 'integer'},
      ACK = {id = 'integer'}, ACK_ALL = {ids = 'table'},
    },
    guards = {
      in_process = function(c) return c.mode == 'in_process' end,
      file = function(c) return c.mode == 'file' end,
      no_push = function(_, e) return tostring(e.error):find('NoPush', 1, true) ~= nil end,
      at_end = function(c) return (c.cursor or 0) >= (c.counts[c.selected] or 0) end,
      waiting = function(c) return c.wait ~= false end,
      wait_event = function(_, e) return e.wait ~= nil end,
    },
    actions = {
      records = assign(function(c, e)
        local selected = c.selected
        if not selected or not e.counts[selected] then selected = e.actors[1] or false end
        return {revision = e.revision, actors = e.actors, counts = e.counts, selected = selected,
          after = e.after or c.after, seed = e.seed or c.seed, gaps = e.gaps or c.gaps, wait = e.wait or false}
      end),
      -- The stuck-state check ran (watch service): new alarms and deadline.
      checked = assign(function(_, e)
        local o = e.output
        return {revision = o.revision, actors = o.actors, counts = o.counts, wait = o.wait or false}
      end),
      open_alarm = assign(function(c, e)
        local n = c.counts[e.actor] or 0
        return {selected = e.actor, cursor = math.max(1, math.min(n, e.step)), alarm = e.id}
      end),
      ack = assign {acked = function(c, e)
        local acked = {}
        for k, v in pairs(c.acked) do acked[k] = v end
        acked[tostring(e.id)] = true
        return acked
      end},
      ack_all = assign {acked = function(c, e)
        local acked = {}
        for k, v in pairs(c.acked) do acked[k] = v end
        for _, id in ipairs(e.ids) do acked[tostring(id)] = true end
        return acked
      end},
      loaded = assign(function(_, e)
        local o = e.output
        return {revision = o.revision, actors = o.actors, counts = o.counts, selected = o.actors[1] or false,
          cursor = 1, message = false}
      end),
      report = assign {message = function(_, e) return tostring(e.error) end},
      clear_message = assign {message = false},
      select = assign(function(c, e) return {selected = e.value, cursor = c.mode == 'file' and 1 or false} end),
      scrub = assign {cursor = function(c, e) return clamp(c, math.floor(e.value)) end},
      step = assign {cursor = function(c, e) return clamp(c, (c.cursor or c.counts[c.selected] or 1) + e.delta) end},
      advance = assign {cursor = function(c) return clamp(c, (c.cursor or 0) + 1) end},
      follow = assign {cursor = false},
      open_editor = assign(function(_, e)
        local drafts = {}
        for name in pairs(e.fields) do drafts[name] = '' end
        return {editor = {name = e.name, fields = e.fields, drafts = drafts}}
      end),
      draft = assign {editor = function(c, e)
        local drafts = {}
        for k, v in pairs(c.editor.drafts) do drafts[k] = v end
        drafts[e.name] = tostring(e.value)
        return {name = c.editor.name, fields = c.editor.fields, drafts = drafts}
      end},
      close_editor = assign {editor = false},
      injected = assign {message = function(_, e) return e.output end},
      -- One-shot task: deliver an event to the inspected actor.
      inject = machine.spawn('inject', {input = function(c, e)
        return {mode = c.mode, address = c.address, actor = c.selected, event = {type = e.name}}
      end}),
      inject_payload = machine.spawn('inject', {input = function(c)
        local event = {type = c.editor.name}
        for name, kind in pairs(c.editor.fields) do event[name] = convert(kind, c.editor.drafts[name]) end
        return {mode = c.mode, address = c.address, actor = c.selected, event = event}
      end}),
    },
    actors = {
      observe = services.observe, follow = services.follow, poll = services.poll,
      load = services.load, inject = services.inject, watch = services.watch,
    },
    states = {
      connection = {initial = 'starting', on = {RECORDS = {actions = 'records'}}, states = {
        starting = {always = {{target = 'in_process', guard = 'in_process'}, {target = 'loading', guard = 'file'},
          {target = 'connected'}}},
        in_process = {invoke = {src = 'observe'}},
        loading = {invoke = {src = 'load', input = function(c) return {path = c.path} end,
          on_done = {target = 'loaded', actions = 'loaded'}, on_error = {target = 'failed', actions = 'report'}}},
        loaded = {},
        failed = {},
        -- Push: the invoke subscribes to ouro://statecharts and fetches on
        -- each notification. An endpoint without the resource falls back to
        -- polling; a broken connection detaches and retries.
        connected = {initial = 'attaching',
          invoke = {src = 'follow', input = function(c) return {address = c.address, after = c.after} end,
            on_error = {{target = 'polling', guard = 'no_push'}, {target = 'detached', actions = 'report'}}},
          states = {
            attaching = {on = {ATTACHED = {target = 'live', actions = 'clear_message'}}},
            live = {},
          }},
        polling = {
          invoke = {src = 'poll', input = function(c) return {address = c.address, after = c.after, seed = c.seed} end,
            on_error = {target = 'detached', actions = 'report'}},
          after = {[200] = {target = 'polling', reenter = true}}},
        detached = {after = {[1000] = 'connected'}},
      }},
      view = {initial = 'following',
        on = {
          SELECT = {{target = '.scrubbing', guard = 'file', actions = 'select'}, {target = '.following', actions = 'select'}},
          -- An alarm opens its unit at the step that raised it.
          OPEN_ALARM = {target = '.scrubbing', actions = 'open_alarm'},
        },
        states = {
          following = {on = {
            SCRUB = {target = 'scrubbing', actions = 'scrub'},
            STEP = {target = 'scrubbing', actions = 'step'},
            PLAY = {target = 'playing'},
          }},
          scrubbing = {on = {
            SCRUB = {actions = 'scrub'}, STEP = {actions = 'step'},
            LIVE = {target = 'following', actions = 'follow'},
            PLAY = {target = 'playing'},
          }},
          playing = {
            after = {[500] = {{target = 'scrubbing', guard = 'at_end'}, {target = 'playing', reenter = true, actions = 'advance'}}},
            on = {
              PAUSE = 'scrubbing',
              SCRUB = {target = 'scrubbing', actions = 'scrub'}, STEP = {target = 'scrubbing', actions = 'step'},
              LIVE = {target = 'following', actions = 'follow'},
            }},
        }},
      editor = {initial = 'closed',
        on = {
          INJECT = {actions = 'inject'},
          ['done.actor.*'] = {actions = 'injected'},
          ['error.actor.*'] = {actions = 'report'},
        },
        states = {
          closed = {on = {EDIT_PAYLOAD = {target = 'open', actions = 'open_editor'}}},
          open = {on = {
            EDIT_PAYLOAD = {actions = 'open_editor'},
            FIELD = {actions = 'draft'},
            SEND_PAYLOAD = {target = 'closed', actions = {'inject_payload', 'close_editor'}},
            CLOSE_EDITOR = {target = 'closed', actions = 'close_editor'},
          }},
        }},
      -- ISA-101 display hierarchy; breadcrumbs send OVERVIEW / UNIT.
      screen = {initial = 'overview',
        on = {
          ACK = {actions = 'ack'}, ACK_ALL = {actions = 'ack_all'},
          OVERVIEW = '.overview', SELECT = '.unit', OPEN_ALARM = '.unit',
        },
        states = {
          overview = {},
          unit = {on = {RECORD = 'record'}},
          record = {on = {UNIT = 'unit'}},
        }},
      -- Stuck states need time to pass without records: one invoke sleeps
      -- until the earliest possible alarm, then the check runs.
      watch = {initial = 'idle', states = {
        idle = {always = {target = 'waiting', guard = 'waiting'}},
        waiting = {
          invoke = {src = 'watch', input = function(c) return {wait = c.wait} end,
            on_done = {target = 'idle', actions = 'checked'}},
          on = {RECORDS = {{target = 'waiting', reenter = true, guard = 'wait_event'}, {target = 'idle'}}}},
      }},
    },
  }
end
