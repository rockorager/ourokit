-- Headless behavior for Contacts: the `contacts` address book chart and the
-- `appearance` presentation chart. Services are injected so tests can fake them:
--   load() -> { contacts = {...}, remote = url? }   save(remote, contact) -> contact
--   exit()
-- load and save may yield on I/O and throw on failure; they run as invokes.
return function(ouro, model, services)
  local machine = ouro.machine
  local assign, unset = machine.assign, machine.unset

  -- Renames apply locally at once (the UI and MCP see them immediately) and
  -- queue in `pending`; the sync region writes them one at a time.
  local book = machine.create {
    id = "contacts", initial = "loading",
    context = { contacts = {}, pending = {}, draft = "" },
    events = {
      SELECT = { id = "string" }, EDIT = { value = "string" }, RENAME = { id = "string", name = "string" },
      RETRY = {}, QUIT = {},
    },
    guards = {
      known = function(c, e) return model.find(c.contacts, e.id) ~= nil end,
      renames = function(c, e)
        local contact = model.find(c.contacts, e.id)
        return contact ~= nil and contact.name ~= e.name and model.check_name(e.name) == nil
      end,
      pending = function(c) return #c.pending > 0 end,
      -- Nothing left to write, or the write failed: quitting stops waiting.
      settled = function(c, _, state) return #c.pending == 0 or state.matches("ready.sync.retrying") end,
    },
    actions = {
      loaded = assign(function(_, e)
        local first = e.output.contacts[1]
        return { contacts = e.output.contacts, remote = e.output.remote or unset, error = unset,
          selected = first and first.id or unset, draft = first and first.name or "" }
      end),
      select = assign(function(c, e) return { selected = e.id, draft = model.find(c.contacts, e.id).name } end),
      edit = assign { draft = function(_, e) return e.value end },
      rename = assign(function(c, e)
        return { contacts = model.replaced(c.contacts, model.renamed(model.find(c.contacts, e.id), e.name)),
          pending = model.with(c.pending, e.id), draft = c.selected == e.id and e.name or c.draft }
      end),
      -- A save writes the record as it was when the save started.
      begin_save = assign { saving = function(c) return model.find(c.contacts, c.pending[1]) end },
      -- The server's copy wins unless the name changed again during the save;
      -- then the id stays pending and the newer name is written next.
      saved = assign(function(c, e)
        local current = model.find(c.contacts, c.saving.id)
        local changes = { saving = unset, error = unset }
        if current and current.name == c.saving.name then
          changes.pending = model.without(c.pending, c.saving.id)
          changes.contacts = model.replaced(c.contacts, e.output)
          if c.selected == c.saving.id then changes.draft = e.output.name end
        end
        return changes
      end),
      fail = assign { error = function(_, e) return model.message(e.error) end },
    },
    actors = {
      load = function() return services.load() end,
      save = function(input) return services.save(input.remote, input.contact) end,
      exit = function() services.exit() end, -- Actions cannot exit; this is invoked work.
    },
    states = {
      loading = {
        invoke = { src = "load", on_done = { target = "ready", actions = "loaded" }, on_error = { target = "failed", actions = "fail" } },
        on = { QUIT = "exiting" },
      },
      failed = { on = { RETRY = "loading", QUIT = "exiting" } },
      ready = { type = "parallel", order = { "sync", "lifecycle" },
        on = {
          SELECT = { guard = "known", actions = "select" },
          EDIT = { actions = "edit" },
          RENAME = { guard = "renames", actions = "rename" },
        },
        states = {
          sync = { initial = "idle", states = {
            idle = { always = { target = "saving", guard = "pending" } },
            saving = { entry = "begin_save",
              invoke = { src = "save", input = function(c) return { remote = c.remote, contact = c.saving } end,
                on_done = { target = "idle", actions = "saved" }, on_error = { target = "retrying", actions = "fail" } } },
            retrying = { after = { [5000] = "saving" }, on = { RETRY = "saving" } },
          } },
          -- Quit waits for queued renames, at most five seconds; a second Quit exits now.
          lifecycle = { initial = "running", states = {
            running = { on = { QUIT = "quitting" } },
            quitting = { always = { target = "#exiting", guard = "settled" }, after = { [5000] = "#exiting" },
              on = { QUIT = "#exiting" } },
          } },
        } },
      exiting = { invoke = { src = "exit", on_done = "exited", on_error = "exited" } },
      exited = { type = "final" },
    },
  }

  -- Presentation only: which visual style the window uses.
  local appearance = machine.create {
    id = "appearance", initial = "light", events = { TOGGLE = {} },
    states = { light = { on = { TOGGLE = "terminal" } }, terminal = { on = { TOGGLE = "light" } } },
  }

  return { book = book, appearance = appearance }
end
