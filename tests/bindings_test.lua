-- Widgets bound to statechart events: `send = actor:event(...)` on the
-- widget's main trigger, bindings in on_* hooks, commands and shortcuts.
local o = require('ouro')
local machine = o.machine
local assign = machine.assign

local chart = machine.create {
  id = 'doc', initial = 'editing',
  context = { saves = 0, text = 'draft', archived = false, tab = 1, split = 0.3, cancels = 0, picked = '' },
  events = {
    SAVE = {}, LOCK = {}, UNLOCK = {}, CANCEL = {},
    EDIT = { value = 'string' }, ARCHIVE = { value = 'boolean' }, TAB = { value = 'integer' },
    RESIZE = { position = 'number' }, PICK = { name = 'string' },
  },
  states = {
    editing = { on = {
      SAVE = { actions = assign { saves = function(c) return c.saves + 1 end } },
      LOCK = 'locked',
      EDIT = { actions = assign { text = function(_, e) return e.value end } },
      ARCHIVE = { actions = assign { archived = function(_, e) return e.value end } },
      TAB = { guard = function(_, e) return e.value ~= 3 end, actions = assign { tab = function(_, e) return e.value end } },
      RESIZE = { actions = assign { split = function(_, e) return e.position end } },
      PICK = { actions = assign { picked = function(_, e) return e.name end } },
      HOVER = machine.set('hovered', 'boolean'),
    } },
    locked = { on = {
      UNLOCK = 'editing',
      CANCEL = { actions = assign { cancels = function(c) return c.cancels + 1 end } },
    } },
  },
}

local doc
local fell_through = 0
local function view()
  local c = doc:context()
  return o.box { key = 'outer', width = 'fill', height = 'fill',
    commands = { fallback = function() fell_through = fell_through + 1 end }, shortcuts = { ['Ctrl+U'] = 'fallback' },
    o.box { key = 'root', width = 'fill', height = 'fill',
    commands = { save = doc:event('SAVE'), lock = doc:event('LOCK'), unlock = doc:event('UNLOCK') },
    shortcuts = { ['Ctrl+S'] = 'save', ['Ctrl+L'] = 'lock', ['Ctrl+U'] = 'unlock' },
    o.stack { key = 'layers',
    o.column { key = 'body', gap = 4,
      o.text { key = 'saves', text = tostring(c.saves) },
      o.button { key = 'save', label = 'Save', send = doc:event('SAVE') },
      o.button { key = 'forced', label = 'Forced', enabled = true, send = doc:event('SAVE') },
      o.button { key = 'lock', label = 'Lock', send = doc:event('LOCK') },
      o.button { key = 'unlock', label = 'Unlock', send = doc:event('UNLOCK') },
      o.text_input { key = 'edit', label = 'Text', text = c.text, send = doc:event('EDIT') },
      o.checkbox { key = 'archive', label = 'Archive', checked = c.archived, motion = 'reduce', send = doc:event('ARCHIVE') },
      o.listbox { key = 'tabs', label = 'Tabs', selected = c.tab, send = doc:event('TAB'),
        o.option { key = 'one', value = 1, label = 'One' },
        o.option { key = 'two', value = 2, label = 'Two' },
        o.option { key = 'three', value = 3, label = 'Three' },
      },
      o.button { key = 'pick', label = 'Pick', on_press = doc:event { type = 'PICK', name = 'fixed' } },
      o.button { key = 'callback', label = 'Callback', on_press = function() doc:send { type = 'PICK', name = 'callback' } end },
    },
    doc:matches('locked') and o.dialog { key = 'confirm', label = 'Locked', on_cancel = doc:event('CANCEL'),
      o.button { key = 'unlock', label = 'Unlock', send = doc:event('UNLOCK') } } or nil,
  } } }
end

local function start(t)
  doc = chart:start { scheduler = machine.manual_scheduler() }
  t:mount(view, { width = 420, height = 520 })
end

-- A launcher-shaped chart: ACTIVATE names the top match for the query.
local ENTRIES = { 'fir-tree', 'firefox', 'files' }
local function top(query)
  for _, id in ipairs(ENTRIES) do
    if id:sub(1, #query) == query then return id end
  end
end
local search = machine.create {
  id = 'search', initial = 'open', context = { query = 'fire', activated = '' },
  states = { open = { on = {
    QUERY = machine.set('query', 'string'),
    ACTIVATE = { actions = assign { activated = function(_, e) return e.id end } },
  } } },
}
-- Enter deletes a character and submits in one keystroke, so the submit
-- command runs before the rebuild that would follow the edit.
local function search_view(finder, submit)
  return function()
    return o.text_input { key = 'query', label = 'Query', text = finder:context().query,
      send = finder:event('QUERY'), key_bindings = { Enter = { 'delete_backward', 'submit' } },
      on_command = { submit = submit(finder) } }
  end
end

local switches = machine.create {
  id = 'switch', initial = 'off', context = { presses = 0, hovered = false },
  states = {
    off = { on = { PRESS = { target = 'on', actions = assign { presses = function(c) return c.presses + 1 end } } } },
    on = { on = { PRESS = { target = 'off', actions = assign { presses = function(c) return c.presses + 1 end } } } },
  },
  on = { HOVER = machine.set('hovered', 'boolean') },
}
local idle = machine.create { id = 'idle', initial = 'resting', events = { PRESS = {} }, states = { resting = {} } }

return {
  ['buttons send their event and follow can()'] = function(t)
    start(t)
    assert(t:node('outer/root/layers/body/save').enabled and not t:node('outer/root/layers/body/unlock').enabled)
    t:click('outer/root/layers/body/save')
    assert(doc:context().saves == 1 and t:node('outer/root/layers/body/saves').label == '1')
    t:click('outer/root/layers/body/lock')
    assert(doc:matches('locked'))
    -- Rebuilt from the snapshot: Save is refused while locked, Unlock accepted.
    assert(not t:node('outer/root/layers/body/save').enabled and t:node('outer/root/layers/confirm/unlock').enabled)
    local ok, err = pcall(function() t:click('outer/root/layers/body/save') end)
    assert(not ok, 'a refused event disables its button')
    assert(t:node('outer/root/layers/body/forced').enabled, 'explicit enabled wins')
    t:click('outer/root/layers/confirm/unlock')
    assert(doc:matches('editing') and t:node('outer/root/layers/body/save').enabled)
  end,

  ['fixed event tables and plain callbacks still work'] = function(t)
    start(t)
    t:click('outer/root/layers/body/pick')
    assert(doc:context().picked == 'fixed')
    t:click('outer/root/layers/body/callback')
    assert(doc:context().picked == 'callback')
  end,

  ['value widgets send their value in the value field'] = function(t)
    start(t)
    t:click('outer/root/layers/body/edit')
    t:key('a', { control = true })
    t:text('final')
    assert(doc:context().text == 'final' and t:node('outer/root/layers/body/edit').value == 'final')
    t:click('outer/root/layers/body/archive')
    assert(doc:context().archived == true and t:node('outer/root/layers/body/archive').checked)
    t:click('outer/root/layers/body/tabs/two')
    assert(doc:context().tab == 2)
    -- A guard that refuses the value leaves the selection where the chart has it.
    t:click('outer/root/layers/body/tabs/three')
    assert(doc:context().tab == 2)
  end,

  ['refused commands drop their shortcuts and refused cancels drop Escape'] = function(t)
    start(t)
    t:key('s', { control = true })
    assert(doc:context().saves == 1)
    -- UNLOCK is refused while editing, so Ctrl+U is not bound here and
    -- reaches the enclosing scope's shortcut.
    t:key('u', { control = true })
    assert(doc:matches('editing') and fell_through == 1)
    t:key('l', { control = true })
    assert(doc:matches('locked'))
    t:key('escape')
    assert(doc:context().cancels == 1, 'the dialog sends CANCEL on Escape')
    t:click('outer/root/layers/confirm/unlock')
    assert(doc:matches('editing'))
  end,

  ['lowering copies the props table; send excludes the classic hook'] = function(t)
    doc = chart:start { scheduler = machine.manual_scheduler() }
    local props = { key = 'root', commands = { save = doc:event('SAVE') }, shortcuts = { ['Ctrl+S'] = 'save' } }
    o.box(props); o.box(props)
    assert(props.commands.save.actor == doc and props.shortcuts['Ctrl+S'] == 'save')
    local ok, err = pcall(function()
      t:mount(function()
        return o.button { key = 'both', label = 'Both', send = doc:event('SAVE'), on_press = function() end }
      end)
    end)
    assert(not ok, 'send and on_press together fail the build')
  end,

  ['a binding field names the payload field for the value'] = function(t)
    doc = chart:start { scheduler = machine.manual_scheduler() }
    t:mount(function()
      return o.text_input { key = 'name', label = 'Name', text = doc:context().picked, send = doc:event('PICK', 'name') }
    end)
    t:click('name')
    t:text('ada')
    assert(doc:context().picked == 'ada')
  end,
  ['interaction changes carry the active flag'] = function(t)
    doc = chart:start { scheduler = machine.manual_scheduler() }
    t:mount(function()
      return o.column { key = 'root',
        o.button { key = 'target', label = 'Target', on_interaction_change = doc:event('HOVER') },
        o.button { key = 'other', label = 'Other' } }
    end)
    t:hover('root/target')
    assert(doc:context().hovered == true)
    t:hover('root/other')
    assert(doc:context().hovered == false)
  end,

  ['a lazy payload resolves at dispatch when a key outruns the rebuild'] = function(t)
    local finder = search:start { scheduler = machine.manual_scheduler() }
    t:mount(search_view(finder, function(f)
      return f:event(function(snapshot) return { type = 'ACTIVATE', id = top(snapshot.context.query) } end)
    end))
    t:click('query')
    t:key('end')
    t:key('enter')
    assert(finder:context().query == 'fir', finder:context().query)
    assert(finder:context().activated == 'fir-tree', 'lazy: ' .. finder:context().activated)
  end,

  ['a render-time payload is stale when a key outruns the rebuild'] = function(t)
    local finder = search:start { scheduler = machine.manual_scheduler() }
    t:mount(search_view(finder, function(f)
      return f:event { type = 'ACTIVATE', id = top(f:context().query) }
    end))
    t:click('query')
    t:key('end')
    t:key('enter')
    assert(finder:context().query == 'fir')
    assert(finder:context().activated == 'firefox', 'eager payloads carry the rendered query: ' .. finder:context().activated)
  end,

  ['a lazy binding that resolves to nothing is disabled and sends nothing'] = function(t)
    local finder = search:start { scheduler = machine.manual_scheduler() }
    t:mount(function()
      return o.button { key = 'go', label = 'Go', send = finder:event(function(snapshot)
        local id = top(snapshot.context.query)
        return id and { type = 'ACTIVATE', id = id } end) }
    end)
    t:click('go')
    assert(finder:context().activated == 'firefox')
    finder:send { type = 'QUERY', value = 'zzz' }
    assert(not t:node('go').enabled, 'no match: disabled')
  end,

  ['one widget sends to several actors; enabled while any accepts'] = function(t)
    local a = switches:start { scheduler = machine.manual_scheduler() }
    local b = switches:start { scheduler = machine.manual_scheduler() }
    local still = idle:start { scheduler = machine.manual_scheduler() }
    t:mount(function()
      return o.column { key = 'root',
        o.button { key = 'both', label = 'Both', send = { a:event('PRESS'), b:event('PRESS') },
          on_interaction_change = { a:event('HOVER'), b:event('HOVER') } },
        o.button { key = 'mixed', label = 'Mixed', send = { still:event('PRESS'), a:event('PRESS') } },
        o.button { key = 'none', label = 'None', send = { still:event('PRESS') } },
      }
    end)
    assert(t:node('root/mixed').enabled and not t:node('root/none').enabled)
    t:hover('root/both')
    assert(a:context().hovered and b:context().hovered, 'value hooks fan out too')
    t:hover('root/mixed')
    assert(not a:context().hovered and not b:context().hovered)
    t:click('root/both')
    assert(a:context().presses == 1 and b:context().presses == 1 and a:matches('on') and b:matches('on'))
    t:click('root/mixed')
    assert(a:context().presses == 2 and a:matches('off') and b:context().presses == 1, 'a refusing target is skipped')
  end,
}
