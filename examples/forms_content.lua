local o = require('ouro')

return function(options)
  options = options or {}
  local checked, mode, size = o.signal(true), o.signal(29), o.signal(12)
  local selected, dialog = o.signal(2), o.signal(options.dialog or false)
  local function close() dialog:set(false) end
  return function()
    local enabled = not options.disabled
    local children = {o.column {key='form', gap=14,
      o.text {key='heading', text='Editor preferences', size=24},
      o.row {key='autosave', gap=10, cross_alignment='center',
        o.checkbox {key='control', label='Save automatically', checked=checked(), enabled=enabled,
          on_change=function(value) checked:set(value) end},
        o.text {key='label', text='Save automatically'},
      },
      o.text {key='mode-label', text='When a document changes'},
      o.radio_group {key='mode', selected=mode(), enabled=enabled, on_select=function(value) mode:set(value) end,
        o.radio {key='ask', value=17, label='Ask before reloading'},
        o.radio {key='reload', value=29, label='Reload unchanged documents'},
        o.radio {key='keep', value=43, label='Keep the current contents'},
      },
      o.select {key='encoding', label='Encoding', selected=selected(), enabled=enabled, width=300,
        options={{value=1,label='UTF-8'},{value=2,label='UTF-16'},{value=3,label='ASCII'}},
        on_select=function(value) selected:set(value) end},
      o.text {key='size-label', text='Text size: '..size()},
      o.slider {key='size', label='Text size', width=300, value=size(), min=8, max=32, step=1, enabled=enabled,
        on_change=function(value) size:set(value) end},
      o.spinbox {key='number', label='Text size', value=size(), min=8, max=32, step=1, enabled=enabled,
        on_change=function(value) size:set(value) end},
      o.button {key='reset', label='Reset preferences…', enabled=enabled, on_press=function() dialog:set(true) end},
      o.text {key='hint', text='Tab between controls. Arrows adjust selections and values.\nEnter commits a typed number; Escape cancels the draft.'},
    }}
    if dialog() then children[#children+1]=o.dialog {key='confirm', label='Reset preferences', width=390, on_cancel=close,
      o.column {key='body', gap=16,
        o.text {key='title', text='Reset preferences?', size=22},
        o.text {key='detail', text='Your current editor preferences will be replaced.'},
        o.row {key='actions', gap=10,
          o.button {key='cancel', label='Cancel', on_press=close},
          o.button {key='reset', label='Reset', on_press=function()
            checked:set(true); mode:set(29); size:set(12); selected:set(2); close()
          end},
        },
      },
    } end
    return o.stack {key='root', children=children}
  end
end
