-- Headless behavior for the launcher. Services are injected so tests can
-- fake them:
--   scan() -> entries        (ouro.xdg.applications.list in the app)
--   launch(entry) -> true    (prepare_launch + start; throws on failure)
-- The chart knows nothing about surfaces. The view maps `open` to a layer
-- surface; everything `open` invokes is cancelled when it exits.
return function(ouro, model, services)
  local machine = ouro.machine
  local assign, unset = machine.assign, machine.unset

  local function results(c) return model.results(c.entries, c.query) end
  local function index(c, e) return e.index or c.selected end

  local launcher = machine.create {
    id = "launcher", initial = "hidden",
    context = { query = "", entries = {}, selected = 1 },
    events = {
      TOGGLE = {}, OPEN = {}, CLOSE = {},
      QUERY = { text = "string" },
      MOVE = { delta = "integer" },
      SELECT = { index = "integer" },
      ACTIVATE = { index = "integer?" },
      RETRY = {},
    },
    guards = {
      match = function(c, e) local i = index(c, e); return i >= 1 and i <= #results(c) end,
    },
    actions = {
      -- Each opening starts from an empty query. Entries from the previous
      -- scan stay so the list is not empty while the new scan runs.
      reset = assign { query = "", selected = 1, error = unset, launching = unset },
      query = assign(function(_, e) return { query = e.text, selected = 1, error = unset } end),
      move = assign { selected = function(c, e) return model.move(c.selected, e.delta, #results(c)) end },
      select = assign { selected = function(_, e) return e.index end },
      scanned = assign(function(c, e)
        return { entries = e.output, error = unset, selected = model.clamp(c.selected, #model.results(e.output, c.query)) }
      end),
      pick = assign(function(c, e)
        local i = index(c, e)
        return { selected = i, launching = results(c)[i], error = unset }
      end),
      fail = assign { error = function(_, e) return model.message(e.error) end },
    },
    actors = {
      scan = function() return model.catalog(services.scan()) end,
      launch = function(entry) return services.launch(entry) end,
    },
    states = {
      hidden = { on = { TOGGLE = "open", OPEN = "open" } },
      open = { initial = "loading", entry = "reset",
        on = {
          TOGGLE = "hidden", CLOSE = "hidden",
          QUERY = { actions = "query" },
          MOVE = { actions = "move" },
          SELECT = { guard = "match", actions = "select" },
        },
        states = {
          loading = { tags = { "busy" },
            invoke = { src = "scan",
              on_done = { target = "ready", actions = "scanned" },
              on_error = { target = "failed", actions = "fail" } } },
          ready = { on = { ACTIVATE = { target = "launching", guard = "match", actions = "pick" } } },
          launching = { tags = { "busy" },
            invoke = { src = "launch", input = function(c) return c.launching end,
              on_done = "#hidden",
              on_error = { target = "ready", actions = "fail" } } },
          failed = { on = { RETRY = "loading", ACTIVATE = "loading" } },
        } },
    },
  }

  return { launcher = launcher }
end
