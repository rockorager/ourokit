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
  ['mount keeps the default inset when padding is omitted'] = function(t)
    t:mount(function() return o.box {key='root', width='fill', height='fill'} end,
      {width=173, height=109})
    local bounds = t:node('root').bounds
    assert(bounds.x == 12 and bounds.y == 12 and bounds.width == 149 and bounds.height == 85)
  end,

  ['mount validates padding and zero covers the full viewport'] = function(t)
    local function content()
      return o.dialog {key='modal', label='Full viewport', o.text {key='label', text='Covered'}}
    end
    for _, invalid in ipairs({-1, 1/0, 0/0, 3.5e38, 1e-100, '0', false, {}}) do
      local ok, err = pcall(function() t:mount(content, {padding=invalid}) end)
      assert(not ok and err:find('InvalidTheme', 1, true), tostring(err))
    end
    t:mount(content, {width=173, height=109, padding=0})
    local bounds = t:node('modal').bounds
    assert(bounds.x == 0 and bounds.y == 0 and bounds.width == 173 and bounds.height == 109)
  end,

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

  ['native editor recipe finishes with a named mode command'] = function(t)
    local insert = o.signal(false)
    local value = o.signal('alpha βeta\nsecond line')
    t:mount(function()
      return o.box { key = 'document', commands = {
        insert = function()
          assert(value() == 'a\nsecond line', 'native change must precede command')
          insert:set(true)
        end,
        normal = function() insert:set(false) end,
      }, o.text_editor { key = 'body', autofocus = true, multiline = true,
        text = value(), text_entry = insert(), on_change = function(v) value:set(v) end,
        key_bindings = insert() and {
          Escape = { 'end_undo_group', 'normalize_caret', command = 'normal' },
        } or {
          inherit = false, ['G G'] = 'move_document_start', L = 'move_normal_visual_right',
          ['Shift+C'] = { 'select_logical_line_end', 'begin_undo_group',
                         'delete_selection', command = 'insert' }, U = 'undo',
        },
      } }
    end)
    local id = t:node('document/body').id
    t:key('g'); t:key('g'); t:key('l'); t:key('c', { shift = true })
    assert(insert())
    t:text('tail')
    t:key('escape')
    assert(not insert())
    assert(t:node('document/body').value == 'atail\nsecond line')
    t:key('u')
    assert(t:node('document/body').value == 'alpha βeta\nsecond line')
    assert(t:node('document/body').id == id, 'mode change must retain the editor')
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
