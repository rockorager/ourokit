-- Headless behavior for the launcher. Services are injected so tests can
-- fake them:
--   scan() -> entries        (ouro.xdg.applications.list in the app)
--   launch(entry) -> true    (prepare_launch + start; throws on failure)
-- All launcher state lives here, including the query and the selection.
-- The view declares the layer surface while the chart is `open` and binds
-- it with `send = launcher`, so the surface reports back as surface.*
-- events; everything `open` invokes is cancelled when it exits.
return function(ouro, model, services)
  local machine = ouro.machine
  local assign, unset = machine.assign, machine.unset

  -- One filter per (entries, query), shared by guards, can() and the view.
  local results = machine.selector(model.results)
  -- ACTIVATE names an entry by id (a row click, or Enter's payload resolved
  -- from the current snapshot), by index, or by nothing: the selection.
  local function index(c, e)
    if e.id then
      for i, entry in ipairs(results(c.entries, c.query)) do
        if entry.id == e.id then return i end
      end
      return 0
    end
    return e.index or c.selected
  end

  local launcher = machine.create {
    id = "launcher", initial = "hidden",
    context = { query = "", entries = {}, selected = 1 },
    events = {
      TOGGLE = {}, OPEN = {}, CLOSE = {},
      QUERY = { value = "string" },
      MOVE = { delta = "integer" },
      SELECT = { index = "integer" },
      ACTIVATE = { id = "string?", index = "integer?" },
      RETRY = {},
    },
    guards = {
      match = function(c, e) local i = index(c, e); return i >= 1 and i <= #results(c.entries, c.query) end,
    },
    actions = {
      -- Each opening starts from an empty query. Entries from the previous
      -- scan stay so the list is not empty while the new scan runs.
      reset = assign { query = "", selected = 1, error = unset, launching = unset },
      query = assign(function(_, e) return { query = e.value, selected = 1, error = unset } end),
      move = assign { selected = function(c, e) return model.move(c.selected, e.delta, #results(c.entries, c.query)) end },
      select = assign { selected = function(_, e) return e.index end },
      scanned = assign(function(c, e)
        return { entries = e.output, error = unset, selected = model.clamp(c.selected, #results(e.output, c.query)) }
      end),
      pick = assign(function(c, e)
        local i = index(c, e)
        return { selected = i, launching = results(c.entries, c.query)[i], error = unset }
      end),
      fail = assign { error = function(_, e) return model.message(e.error) end },
      -- The surface could not be shown: its declaration was rejected, failed
      -- a native transition, its content failed to build, or windows()
      -- threw. Hidden keeps the reason for MCP and logs.
      surface_failed = assign { error = function(_, e) return "Launcher surface failed (" .. e.reason .. "): " .. e.message end },
    },
    actors = {
      scan = function() return model.catalog(services.scan()) end,
      launch = function(entry) return services.launch(entry) end,
    },
    states = {
      hidden = { on = {
        TOGGLE = "open", OPEN = "open",
        -- The surface finished closing after we left `open`: nothing to do.
        ["surface.closed.launcher"] = {},
      } },
      open = { initial = "loading", entry = "reset",
        on = {
          TOGGLE = "hidden", CLOSE = "hidden",
          ["surface.mapped.launcher"] = {},
          ["surface.close_requested.launcher"] = "hidden",
          ["surface.failed.launcher"] = { target = "hidden", actions = "surface_failed" },
          -- windows() itself failed (run's declaration has send = launcher).
          ["surface.failed"] = { target = "hidden", actions = "surface_failed" },
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

  return { launcher = launcher, results = results }
end
