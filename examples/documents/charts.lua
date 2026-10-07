-- Headless behavior for Notes: a `document` chart per open note and the
-- `notes` application chart. Services are injected so tests can fake them:
--   choose(name) -> path | error{name='Canceled'}   write(path, bytes)
--   choose_files() -> uris | error   read(uri) -> {title, text} | nil, error
--   notify(options)   persist(split, paths, selected_path)   exit()
-- Everything that waits (dialogs, files, D-Bus notifications) is an invoke or
-- a spawned task; actions only compute.
return function(ouro, model, services)
  local machine = ouro.machine
  local assign, unset = machine.assign, machine.unset

  -- One-shot notification tasks, owned by the state that raised them.
  local function notify(title, body_of)
    return machine.spawn("notify", { input = function(c, e) return { title = title, body = body_of(c, e) } end })
  end
  local function notify_task(input)
    services.notify { app_name = "Ourokit Notes", title = input.title, body = input.body }
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
        notify("Ourokit Notes", function(c) return c.error end),
      },
      report = {
        assign { error = function(_, e) return e.message or model.message(e.error) end },
        notify("Ourokit Notes", function(c) return c.error end),
      },
      fail = assign { error = function(_, e) return model.message(e.error) end },
      -- A save writes the bytes and revision as they were when it started.
      begin_save = assign(function(c) return { pending = { revision = c.revision, bytes = model.encode(c) } } end),
      saved = {
        assign(function(c) return { path = c.target, error = unset, saved_revision = c.pending.revision } end),
        notify("Note saved", function(c) return c.title end),
      },
    },
    actors = {
      notify = notify_task,
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
  local function unsafe(child)
    return model.dirty(child.context) or machine.matches(child, "open.io.saving")
  end
  -- The first open note that is dirty or saving, read from child snapshots.
  local function first_unsafe(state)
    for _, id in ipairs(state.children) do
      local child = state.children[id]
      if child and child.machine == "document" and unsafe(child) then return id, child end
    end
  end
  local function is_document(id) return id:match("^document%.%d+$") ~= nil end

  -- Reading files is a one-shot task; results come back as done.actor.read.*.
  local function read_all(uris)
    local notes = {}
    for _, uri in ipairs(uris) do
      local value, err = services.read(uri)
      if value then notes[#notes + 1] = { title = value.title, text = value.text, path = uri }
      else
        local message = "Could not open " .. tostring(uri) .. ": " .. model.message(err)
        services.notify { app_name = "Ourokit Notes", title = "Ourokit Notes", body = message }
        notes[#notes + 1] = { error = message }
      end
    end
    return { notes = notes }
  end

  local notes = machine.create {
    id = "notes", initial = "running",
    context = function(input) return { split = input and input.split or 0.25, next = 1 } end,
    events = {
      NEW = {}, ADD = { title = "string?", text = "string?", path = "string?", error = "string?" },
      OPEN = {}, OPEN_URIS = { uris = "table" },
      SELECT = { value = "integer" }, CLOSE_TAB = { value = "integer" }, RESIZE = { position = "number" },
      CLOSE_WINDOW = {}, CLOSE_CANCELED = {},
    },
    guards = {
      known = function(_, e, state) return state.children[model.child_id(e.value)] ~= nil end,
      last = function(_, _, state)
        for _, id in ipairs(state.children) do if is_document(id) then return false end end
        return true
      end,
      all_safe = function(_, _, state) return first_unsafe(state) == nil end,
    },
    actions = {
      add = {
        machine.spawn(document, { id = function(c) return model.child_id(c.next) end, input = add }),
        assign(function(c) return { selected = c.next, next = c.next + 1 } end),
      },
      select = assign { selected = function(_, e) return e.value end },
      -- A closed tab hands selection to its next neighbor, or the previous one.
      forget = assign { selected = function(c, e, state)
        if c.selected ~= model.tab_value(e.id) then return c.selected end
        local documents = {}
        for _, id in ipairs(state.children) do if is_document(id) then documents[#documents + 1] = id end end
        local replacement = documents[math.min(e.index, #documents)]
        return replacement and model.tab_value(replacement)
      end },
      -- The session is what was open when the close started, including notes
      -- discarded during the walk.
      capture = assign { closing = function(c, _, state)
        local paths, selected = {}, nil
        for _, id in ipairs(state.children) do
          local child = state.children[id]
          if child and child.machine == "document" then
            paths[#paths + 1] = child.context.path
            if child.context.tab_value == c.selected then selected = child.context.path end
          end
        end
        return { paths = paths, selected = selected }
      end },
      prompt = {
        assign { selected = function(_, _, state) local _, child = first_unsafe(state); return child.context.tab_value end },
        machine.send_to(function(_, _, state) return (first_unsafe(state)) end, "CLOSE"),
      },
      -- Opening reports through events: one ADD per note read.
      opened = function(_, e, self)
        for _, note in ipairs(e.output.notes) do
          self:send { type = "ADD", title = note.title, text = note.text, path = note.path, error = note.error }
        end
      end,
      report_open = function(c, e, self)
        local doc = c.selected and self:child(model.child_id(c.selected))
        if doc then doc:send { type = "REPORT", message = model.message(e.error) } end
      end,
    },
    actors = {
      -- The chooser needs only the parent window, not press provenance, so it
      -- runs as a task rather than in the button callback.
      open = function()
        local uris, err = services.choose_files()
        if not uris then
          if err and err.name ~= "Canceled" then error(err, 0) end
          return { notes = {} }
        end
        return read_all(uris)
      end,
      read = function(input) return read_all(input.uris) end,
      -- Persisting the session waits on file I/O, so it is invoked work.
      quit = function(input)
        services.persist(input.split, input.paths, input.selected)
        services.exit()
      end,
    },
    states = {
      running = { initial = "open",
        on = {
          NEW = { actions = "add" }, ADD = { actions = "add" },
          OPEN = { actions = machine.spawn("open") },
          OPEN_URIS = { actions = machine.spawn("read", { input = function(_, e) return { uris = e.uris } end }) },
          ["done.actor.open.*"] = { actions = "opened" }, ["done.actor.read.*"] = { actions = "opened" },
          ["error.actor.open.*"] = { actions = "report_open" },
          SELECT = { guard = "known", actions = "select" },
          CLOSE_TAB = { guard = "known", actions = { "select", machine.send_to(function(_, e) return model.child_id(e.value) end, "CLOSE") } },
          RESIZE = { actions = assign { split = function(_, e) return e.position end } },
          ["done.actor.document.*"] = { { target = "#quitting", guard = "last" }, { actions = "forget" } },
        },
        states = {
          open = { on = { CLOSE_WINDOW = "closing" } },
          closing = { initial = "walking", entry = "capture",
            on = {
              CLOSE_CANCELED = { target = "open", actions = assign { closing = unset } },
              -- Re-enter walking, not closing: the captured session stays.
              ["done.actor.document.*"] = { { target = "#quitting", guard = "last" }, { target = ".walking", actions = "forget" } },
            },
            states = {
              -- Prompt each unsafe note in turn; with none left, quit.
              walking = { always = { { target = "#quitting", guard = "all_safe" }, { target = "prompting", actions = "prompt" } } },
              prompting = {},
            } },
        } },
      quitting = { invoke = { src = "quit", input = function(c)
          local closing = c.closing or { paths = {} }
          return { split = c.split, paths = closing.paths, selected = closing.selected }
        end, on_done = "exited", on_error = "exited" } },
      exited = { type = "final" },
    },
  }

  return { document = document, notes = notes }
end
