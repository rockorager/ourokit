-- A target app for live attachment: runs the fixture charts in real time on
-- the default scheduler. Start it as a development instance:
--   zig-out/bin/ouroctl run tools/statechart-visualizer/feed.lua --dev
-- then attach the visualizer to the printed development socket.
local o = require('ouro')
local scenario = require('scenario')
local fixtures = {require('fixtures.document'), require('fixtures.connection')}

-- Started at load so `--headless --dev` (no run) feeds too.
for _, fixture in ipairs(fixtures) do o.spawn(function() scenario.live(fixture) end) end

return o.app {id = 'dev.ourokit.statechart-feed', run = function()
  return {windows = {o.window {id = 'main', title = 'Statechart feed', width = 420, height = 120,
    content = function()
      return o.text {key = 'hint', text = 'Running document and connection charts. Attach the visualizer to this --dev socket.'}
    end}}}
end}
