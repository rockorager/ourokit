-- A stopwatch with laps and a settings dialog: the smallest complete chart app
-- (design/statecharts.md §0).
--   ouroctl run examples/stopwatch/ouro.json
-- charts.lua holds the behavior and view.lua the UI. tests/stopwatch_test.lua
-- drives both with `ouroctl test`.
local ouro = require('ouro')
local charts = require('charts')
local view = require('view')

return ouro.app {
  id = 'dev.ourokit.stopwatch',
  run = function()
    -- run is a task, so root actors start here. An actor created while a
    -- reload candidate runs is restored with its state (design §9).
    local stopwatch = charts.stopwatch:start { id = 'stopwatch' }
    return { windows = {
      ouro.window { id = 'main', title = 'Stopwatch', width = 420, height = 460, content = view.content(stopwatch) },
    } }
  end,
}
