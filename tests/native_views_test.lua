-- Native APIs accept statechart context directly. actor:context() and the
-- tables read from it are read-only views (userdata), and native bindings
-- read tables raw, so each binding unwraps a view to the table behind it.
-- tests/native_views.py covers the bindings that need I/O or desktop data
-- (D-Bus, HTTP, files, MCP, prepare_launch on real desktop entries).
local o = require('ouro')
local machine = o.machine

local chart = machine.create {
  id = 'views', initial = 'idle',
  context = {
    data = { name = 'n', list = { 1, 2 }, empty = o.json.array() },
    gradient = { from = { x = 0, y = 0 }, to = { x = 10, y = 0 },
      stops = { { offset = 0, color = '#000000' }, { offset = 1, color = '#ffffff' } } },
    commands = { { kind = 'rectangle', x = 0, y = 0, width = 4, height = 4, color = '#ff0000' },
      { kind = 'fill', color = '#00ff00', path = { { 'move', 0, 0 }, { 'line', 4, 0 }, { 'line', 4, 4 }, { 'close' } } } },
    transform = { x = 3, y = 4, origin = { x = 0, y = 0 } },
    shadow = { color = '#000000', blur = 2 },
    spans = { { text = 'from ' }, { text = 'context', weight = 'medium' } },
    count = 0,
  },
  events = { BUMP = {} },
  states = { idle = { on = { BUMP = { actions = machine.assign(function(c) return { count = c.count + 1 } end) } } } },
}

return {
  ['json.encode reads context views'] = function()
    local actor = chart:start()
    local c = actor:context()
    assert(o.json.encode(c.data) == '{"empty":[],"list":[1,2],"name":"n"}', o.json.encode(c.data))
    -- The tracked view of the whole context, not only nested tables.
    assert(o.json.decode(o.json.encode(c)).count == 0)
    -- Mixed: a fresh table holding a view.
    assert(o.json.encode({ c.data.list }) == '[[1,2]]')
    actor:stop()
  end,

  ['gradients and drawings read context views'] = function()
    local actor = chart:start()
    local c = actor:context()
    assert(o.linear_gradient(c.gradient))
    assert(o.drawing { width = 4, height = 4, commands = c.commands })
    assert(o.drawing { width = 4, height = 4, rectangles = { c.commands[1] } })
    actor:stop()
  end,

  ['UI declarations read context views and stay tracked'] = function(t)
    local actor = chart:start()
    t:mount(function()
      local c = actor:context()
      return o.column { key = 'root',
        o.box { key = 'moved', width = 10, height = 10, transform = c.transform, shadow = c.shadow },
        o.text { key = 'rich', spans = c.spans },
        -- Encoding the whole context reads every key, so this text follows it.
        o.text { key = 'json', text = tostring(o.json.decode(o.json.encode(c)).count) },
      }
    end, { width = 200, height = 100 })
    assert(t:node('root/moved'))
    assert(t:node('root/rich').label == 'from context', t:node('root/rich').label)
    assert(t:node('root/json').label == '0')
    actor:send('BUMP')
    assert(t:node('root/json').label == '1', t:node('root/json').label)
  end,
}
