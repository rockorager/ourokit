local o = require('ouro')
local count = o.signal(7)

local function counter()
  return o.column { key = 'root',
    o.text { key = 'count', text = tostring(count()) },
    o.button { key = 'increment', label = 'Increment',
      on_press = function() count:set(count() + 3) end },
    o.button { key = 'disabled', label = 'Disabled', enabled = false,
      on_press = function() error('disabled callback ran') end },
    o.text_input { key = 'edit', label = 'Name', default_text = 'aéZ' },
  }
end

return {
  -- These checks previously needed application_services/development_runtime
  -- plus Sway. They exercise the same retained input path without a desktop.
  ['click and keyboard activation update component state'] = function(t)
    t:mount(counter, { width = 420, height = 300 })
    assert(t:node('root/count').label == '7')
    local before = t:node('root/increment')
    assert(before.role == 'button' and before.bounds.width > 0)
    assert(type(before.id) == 'string' and before.parent == t:node('root').id)
    t:hover('root/increment')
    assert(t:node('root/count').label == '7')
    before.label = 'mutated copy'
    assert(t:node('root/increment').label == 'Increment')
    t:click('root/increment')
    assert(t:node('root/count').label == '10')
    assert(t:node('root/increment').focused)
    t:key('enter')
    assert(t:node('root/count').label == '13')
    t:key('space')
    assert(t:node('root/count').label == '16')
    assert(t:node('root/increment').id == before.id)
  end,

  ['disabled controls reject clicks and are skipped by Tab'] = function(t)
    t:mount(counter)
    assert(t:node('root/count').label == '7', 'state leaked between tests')
    t:click('root/increment')
    local ok, err = pcall(function() t:click('root/disabled') end)
    assert(not ok and err:find('DevelopmentTargetDisabled', 1, true), tostring(err))
    assert(t:node('root/count').label == '10')
    assert(t:node('root/increment').focused)
    t:key('tab')
    assert(t:node('root/edit').focused)
    t:key('tab', { shift = true })
    assert(t:node('root/increment').focused)
  end,

  ['text input uses UTF-8 selection and normal editing commands'] = function(t)
    t:mount(counter)
    t:click('root/edit')
    t:key('end')
    t:key('arrow_left', { shift = true })
    local selected = t:node('root/edit')
    assert(selected.selection.anchor == 4 and selected.selection.extent == 3)
    t:text('Ω!')
    t:key('backspace')
    assert(t:node('root/edit').value == 'aéΩ')
    t:key('a', { control = true })
    t:text('Replaced')
    assert(t:node('root/edit').value == 'Replaced')
  end,

  ['controlled checkbox updates through its callback'] = function(t)
    local checked = o.signal(false)
    t:mount(function()
      return o.checkbox { key = 'check', label = 'Archive locally',
        checked = checked(), motion = 'reduce',
        on_change = function(value) checked:set(value) end }
    end)
    assert(not t:node('check').checked)
    t:click('check')
    assert(t:node('check').checked and checked())
    t:key('space')
    assert(not t:node('check').checked and not checked())
  end,

  ['scroll deltas accumulate on the retained list'] = function(t)
    t:mount(function()
      return o.column { key = 'root',
        o.virtual_list { key = 'rows', flex = 1, item_count = 100, item_height = 30,
          item_key = function(i) return 'row-' .. i end,
          render_item = function(i) return o.text { key = 'label', text = 'Item ' .. i } end },
      }
    end, { width = 320, height = 240 })
    assert(t:node('root/rows').scroll_offset == 0)
    t:scroll('root/rows', 73)
    assert(t:node('root/rows').scroll_offset == 73)
    t:scroll('root/rows', -19)
    assert(t:node('root/rows').scroll_offset == 54)
  end,
}
