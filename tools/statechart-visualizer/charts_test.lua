-- The visualizer's own chart on a manual clock, with fake services:
--   ouroctl test tools/statechart-visualizer/charts_test.lua
local o = require('ouro')
local machine = o.machine
local charts = require('charts')

local function batch(revision, n)
  return {type = 'RECORDS', revision = revision, actors = {'stopwatch'}, counts = {stopwatch = n}, after = n, seed = 1}
end

local function start(services, input)
  local clock = machine.manual_scheduler()
  local viz = charts(services):start {id = 'visualizer', scheduler = clock, input = input}
  return viz, clock
end

local noop = function() end

return {
  ['push attaches live, follows batches and polls only without the resource'] = function()
    local follows, polls, failing = 0, 0, false
    local services = {observe = noop, load = noop, inject = noop, watch = noop}
    function services.follow(input, send)
      follows = follows + 1
      if failing then error(failing, 0) end
      send({type = 'ATTACHED'})
      send(batch(1, 3))
    end
    function services.poll() polls = polls + 1 end
    local viz, clock = start(services, {mode = 'socket', address = 'unix:/x'})
    clock.run_tasks()
    assert(viz:matches('connection.connected.live'), 'acknowledged subscription is live')
    assert(viz:context().selected == 'stopwatch' and viz:context().counts.stopwatch == 3)
    assert(viz:context().after == 3 and follows == 1 and polls == 0)
    clock.advance(10000)
    assert(polls == 0 and follows == 1, 'push does not poll or resubscribe while idle')

    -- An endpoint without ouro://statecharts falls back to polling.
    failing = 'NoPush: Unknown resource'
    local fallback, fclock = start(services, {mode = 'socket', address = 'unix:/y'})
    fclock.run_tasks()
    assert(fallback:matches('connection.polling'), 'NoPush falls back to polling')
    for _ = 1, 5 do fclock.advance(200); fclock.run_tasks() end
    assert(polls >= 5, 'polling re-enters every 200 ms: ' .. polls)

    -- Any other failure detaches with a message and retries after a second.
    failing = 'Detached: the subscription ended'
    local broken, bclock = start(services, {mode = 'socket', address = 'unix:/z'})
    bclock.run_tasks()
    assert(broken:matches('connection.detached') and broken:context().message:find('Detached'))
    failing = false
    bclock.advance(1000); bclock.run_tasks()
    assert(broken:matches('connection.connected.live'), 'the retry reattaches')
  end,

  ['scrubbing, stepping, playing and going live move the cursor'] = function()
    local services = {follow = noop, poll = noop, load = noop, inject = noop, watch = noop}
    function services.observe(_, send) send(batch(1, 5)) end
    local viz, clock = start(services, {mode = 'in_process'})
    clock.run_tasks()
    assert(viz:matches('connection.in_process') and viz:matches('view.following') and viz:context().cursor == false)
    viz:send({type = 'SCRUB', value = 2})
    assert(viz:matches('view.scrubbing') and viz:context().cursor == 2)
    viz:send({type = 'STEP', delta = 10})
    assert(viz:context().cursor == 5, 'the cursor clamps to the history')
    viz:send({type = 'SCRUB', value = 3}); viz:send('PLAY')
    clock.advance(500)
    assert(viz:matches('view.playing') and viz:context().cursor == 4)
    clock.advance(1000)
    assert(viz:matches('view.scrubbing') and viz:context().cursor == 5, 'playback stops at the end')
    viz:send('LIVE')
    assert(viz:matches('view.following') and viz:context().cursor == false)
  end,

  ['the payload editor converts drafts and sends through inject'] = function()
    local sent
    local services = {follow = noop, poll = noop, load = noop, watch = noop}
    function services.observe(_, send) send(batch(1, 1)) end
    function services.inject(input) sent = input; return input.event.type .. ' accepted' end
    local viz, clock = start(services, {mode = 'in_process'})
    clock.run_tasks()
    viz:send({type = 'EDIT_PAYLOAD', name = 'MAX_LAPS', fields = {value = 'integer'}})
    assert(viz:matches('editor.open') and viz:context().editor.drafts.value == '')
    viz:send({type = 'FIELD', name = 'value', value = '3'})
    viz:send('SEND_PAYLOAD')
    clock.run_tasks()
    assert(viz:matches('editor.closed') and viz:context().editor == false)
    assert(sent.actor == 'stopwatch' and sent.event.type == 'MAX_LAPS' and sent.event.value == 3, 'integer drafts convert')
    assert(viz:context().message == 'MAX_LAPS accepted')
    viz:send({type = 'INJECT', name = 'START'})
    clock.run_tasks()
    assert(sent.event.type == 'START' and viz:context().message == 'START accepted')
  end,

  ['the overview drills into units and alarms, acknowledges, and watches for stuck states'] = function()
    local watched = {}
    local services = {follow = noop, poll = noop, load = noop, inject = noop}
    function services.observe(_, send)
      local event = batch(1, 6)
      event.wait = 2500
      send(event)
    end
    function services.watch(input)
      watched[#watched + 1] = input.wait
      return {revision = 2, actors = {'stopwatch'}, counts = {stopwatch = 7}}
    end
    local viz, clock = start(services, {mode = 'in_process'})
    clock.run_tasks()
    assert(viz:matches('screen.overview'), 'the overview is Level 1')
    assert(watched[1] == 2500 and viz:matches('watch.idle') and viz:context().wait == false, 'one check, no next deadline')
    assert(viz:context().counts.stopwatch == 7 and viz:context().revision == 2)
    viz:send({type = 'SELECT', value = 'stopwatch'})
    assert(viz:matches('screen.unit') and viz:matches('view.following'))
    viz:send('RECORD')
    assert(viz:matches('screen.record'))
    viz:send('UNIT'); viz:send('OVERVIEW')
    assert(viz:matches('screen.overview'))
    viz:send({type = 'OPEN_ALARM', id = 3, actor = 'stopwatch', step = 4})
    assert(viz:matches('screen.unit') and viz:matches('view.scrubbing'))
    assert(viz:context().cursor == 4 and viz:context().alarm == 3 and viz:context().selected == 'stopwatch')
    viz:send({type = 'ACK', id = 3})
    viz:send({type = 'ACK_ALL', ids = {1, 2}})
    local acked = viz:context().acked
    assert(acked['1'] and acked['2'] and acked['3'] and not acked['4'])
  end,
}
