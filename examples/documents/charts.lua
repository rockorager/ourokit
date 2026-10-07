-- Headless behavior for Notes: a `document` chart per open note and the
-- `notes` application chart. Services are injected so tests can fake them:
--   choose(name) -> path | error{name='Canceled'}   write(path, bytes)
--   notify(options)   persist(split, paths, selected_path)   exit()
return function(ouro, model, services)
  local machine = ouro.machine
  local assign, unset = machine.assign, machine.unset

  local function report(message)
    services.notify { app_name = "Ourokit Notes", title = "Ourokit Notes", body = message }
  end

  local document = machine.create {
    id = "document", initial = "open",
    context = function(input)
      return { id = input.id, tab_value = input.tab_value, title = input.title or "Untitled", text = input.text or "",
        path = input.path, error = input.error, revision = 0, saved_revision = 0 }
    end,
    events = {
      EDIT = { field = "string", value = "string" }, SAVE = {}, SAVE_AS = {}, CLOSE = {},
      CANCEL = {}, DISCARD = {}, REPORT = { message = "string" },
    },
    guards = {
      invalid_edit = function(_, e) return model.check_edit(e.field, e.value) ~= nil end,
      changes = function(c, e) return c[e.field] ~= e.value end,
      has_path = function(c) return c.path ~= nil and not c.save_as end,
      canceled = function(_, e) return e.error.name == "Canceled" end,
      unsafe = function(c, _, state) return model.dirty(c) or state.matches("open.io.saving") end,
      idle = function(_, _, state) return state.matches("open.io.idle") end,
      saved_clean = function(c, _, state) return state.matches("open.io.idle") and not model.dirty(c) end,
    },
    actions = {
      apply_edit = assign(function(c, e) return { [e.field] = e.value, revision = c.revision + 1 } end),
      report_edit = {
        assign { error = function(_, e) return model.check_edit(e.field, e.value) end },
        function(c) report(c.error) end,
      },
      report = {
        assign { error = function(_, e) return e.message or model.message(e.error) end },
        function(c) report(c.error) end,
      },
      fail = assign { error = function(_, e) return model.message(e.error) end },
      -- A save writes the bytes and revision as they were when it started.
      begin_save = assign(function(c) return { pending = { revision = c.revision, bytes = model.encode(c) } } end),
      saved = {
        assign(function(c) return { path = c.target, error = unset, saved_revision = c.pending.revision } end),
        machine.send_parent(function(c) return { type = "SAVED", id = c.id, path = c.path } end),
        function(c) services.notify { app_name = "Ourokit Notes", title = "Note saved", body = c.title } end,
      },
    },
    actors = {
      choose = function(input)
        local path, err = services.choose(input.name)
        if not path then error(err or { name = "Canceled" }, 0) end
        return path
      end,
      write = function(input)
        local ok, err = services.write(input.path, input.bytes)
        if not ok then error(err, 0) end
        return true
      end,
    },
    states = {
      open = { type = "parallel", order = { "io", "lifecycle" },
        on = {
          EDIT = { { guard = "invalid_edit", actions = "report_edit" }, { guard = "changes", actions = "apply_edit" } },
          REPORT = { actions = "report" },
        },
        states = {
          io = { initial = "idle", states = {
            idle = { on = {
              SAVE = { target = "saving", actions = assign { save_as = false } },
              SAVE_AS = { target = "saving", actions = assign { save_as = true } },
            } },
            saving = { initial = "choosing", entry = "begin_save", tags = { "saving" }, states = {
              choosing = {
                always = { target = "writing", guard = "has_path", actions = assign { target = function(c) return c.path end } },
                invoke = { src = "choose", input = function(c) return { name = model.label(c) .. ".ournote" } end,
                  on_done = { target = "writing", actions = assign { target = function(_, e) return e.output end } },
                  on_error = { { target = "#open.io.idle", guard = "canceled" }, { target = "#open.io.idle", actions = "report" } } },
              },
              writing = {
                invoke = { src = "write", input = function(c) return { path = c.target, bytes = c.pending.bytes } end,
                  on_done = { target = "#open.io.idle", actions = "saved" },
                  on_error = { target = "#open.io.idle", actions = "fail" } },
              },
            } },
          } },
          lifecycle = { initial = "active", states = {
            active = { on = { CLOSE = { { target = "confirming", guard = "unsafe" }, { target = "#closed" } } } },
            confirming = { initial = "prompt",
              on = { CANCEL = { target = "active", actions = machine.send_parent("CLOSE_CANCELED") } },
              states = {
                -- The dialog's Save is the ordinary SAVE: io starts saving and
                -- this region waits for the outcome, in the same microstep.
                prompt = { on = { SAVE = { target = "awaiting", guard = "idle" }, DISCARD = { target = "#closed", guard = "idle" } } },
                awaiting = { always = { { target = "#closed", guard = "saved_clean" }, { target = "prompt", guard = "idle" } } },
              } },
          } },
        } },
      closed = { type = "final", output = function(c) return { path = c.path } end },
    },
  }

  local function add(c, e)
    return { id = model.child_id(c.next), tab_value = c.next, title = e.title, text = e.text, path = e.path, error = e.error }
  end

  local notes = machine.create {
    id = "notes", initial = "running",
    context = function(input) return { split = input and input.split or 0.25, next = 1, paths = {} } end,
    events = {
      NEW = {}, ADD = { title = "string?", text = "string?", path = "string?", error = "string?" },
      SELECT = { value = "integer" }, CLOSE_TAB = { value = "integer" }, RESIZE = { position = "number" },
      SAVED = { id = "string", path = "string" }, CLOSE_WINDOW = {}, CLOSE_CANCELED = {}, QUIT = {},
    },
    guards = {
      known = function(_, e, state)
        for _, id in ipairs(state.children) do if id == model.child_id(e.value) then return true end end
        return false
      end,
      last = function(_, _, state) return #state.children == 0 end,
    },
    actions = {
      add = {
        machine.spawn(document, { id = function(c) return model.child_id(c.next) end, input = add }),
        assign(function(c, e)
          local paths = c.paths
          if e.path then
            paths = {}
            for id, path in pairs(c.paths) do paths[id] = path end
            paths[model.child_id(c.next)] = e.path
          end
          return { selected = c.next, next = c.next + 1, paths = paths }
        end),
      },
      select = assign { selected = function(_, e) return e.value end },
      -- A closed tab hands selection to its next neighbor, or the previous one.
      forget = assign { selected = function(c, e, state)
        if c.selected ~= model.tab_value(e.id) then return c.selected end
        local replacement = state.children[math.min(e.index, #state.children)]
        return replacement and model.tab_value(replacement)
      end },
      remember_path = assign { paths = function(c, e)
        local paths = {}
        for id, path in pairs(c.paths) do paths[id] = path end
        paths[e.id] = e.path
        return paths
      end },
      capture = assign { closing = function(c, _, state)
        local ids = {}
        for i, id in ipairs(state.children) do ids[i] = id end
        return { ids = ids, selected = c.selected }
      end },
      -- Prompt for the first note that is dirty or saving, or quit.
      walk = function(_, _, self)
        for _, doc in ipairs(self:children()) do
          local c = doc:context()
          if model.dirty(c) or doc:matches("open.io.saving") then
            self:send { type = "SELECT", value = c.tab_value }
            doc:send("CLOSE")
            return
          end
        end
        self:send("QUIT")
      end,
      exit = function() services.exit() end,
    },
    actors = {
      -- Saving the session yields on file I/O, so it is invoked work: a
      -- function action would run in the sender's task, which the dialog
      -- that sent DISCARD takes down with it when it unmounts.
      persist = function(input) services.persist(input.split, input.paths, input.selected) end,
    },
    states = {
      running = { initial = "open",
        on = {
          NEW = { actions = "add" }, ADD = { actions = "add" },
          SELECT = { guard = "known", actions = "select" },
          CLOSE_TAB = { guard = "known", actions = { "select", machine.send_to(function(_, e) return model.child_id(e.value) end, "CLOSE") } },
          RESIZE = { actions = assign { split = function(_, e) return e.position end } },
          SAVED = { actions = "remember_path" },
          ["done.actor.*"] = { { target = "#quitting", guard = "last" }, { actions = "forget" } },
        },
        states = {
          open = { on = { CLOSE_WINDOW = "closing" } },
          closing = { initial = "walking", entry = "capture",
            on = {
              CLOSE_CANCELED = { target = "open", actions = assign { closing = unset } },
              ["done.actor.*"] = { { target = "#quitting", guard = "last" }, { target = ".walking", actions = "forget" } },
            },
            states = { walking = { entry = "walk", on = { QUIT = "#quitting" } } } },
        } },
      quitting = { invoke = { src = "persist", input = function(c)
          local paths, selected = {}, nil
          if c.closing then
            for _, id in ipairs(c.closing.ids) do paths[#paths + 1] = c.paths[id] end
            selected = c.closing.selected and c.paths[model.child_id(c.closing.selected)]
          end
          return { split = c.split, paths = paths, selected = selected }
        end, on_done = "exited", on_error = "exited" } },
      exited = { type = "final", entry = "exit" },
    },
  }

  return { document = document, notes = notes }
end
