-- Public-API fixture for tests/control_composition.py; also runnable with ouroctl.
local o = require('ouro')
local revision = 1
local reject = false
local count = o.signal(revision == 1 and 5 or 31)
local checked, switched = o.signal(true), o.signal(false)
local changes, requests = o.signal(''), o.signal('')
local forbidden = o.signal(0)
local function disabled() forbidden:set(forbidden() + 1) end
local function content()
  local root = o.column {key='root', gap=12,
    o.text {key='revision', text='Composition revision '..revision},
    o.button {key='custom', label='Semantic action '..revision, width=340, height='auto',
      variant='soft', tone='neutral',
      on_press=function() count:set(count() + (revision == 1 and 7 or 13)) end,
      o.row {key='content', gap=17, cross_alignment='center',
        o.box {key='swatch', width=29, height=37, background='#193bc7'},
        o.column {key='copy', gap=3,
          o.text {key='title', text='Visible custom action'},
          o.text {key='detail', text='Count '..count()},
        },
      },
    },
    o.button {key='disabled-button', label='Disabled action', enabled=false, on_press=disabled},
    o.row {key='checks', gap=11, cross_alignment='center',
      o.checkbox {key='live', label='Archive locally', checked=checked(),
        on_change=function(value)
          changes:set(changes()..(value and 'C1;' or 'C0;')); checked:set(value)
        end},
      o.checkbox {key='disabled', label='Disabled checkbox', checked=false, enabled=false, on_change=disabled},
      o.text {key='label', text='Archive locally / disabled unchecked'},
    },
    o.row {key='switches', gap=11, cross_alignment='center',
      o.switch {key='live', label='Publish remotely', checked=switched(),
        on_change=function(value)
          changes:set(changes()..(value and 'S1;' or 'S0;')); switched:set(value)
        end},
      o.switch {key='disabled', label='Disabled switch', checked=true, enabled=false, on_change=disabled},
      o.text {key='label', text='Publish remotely / disabled checked'},
    },
    o.row {key='ignored', gap=11, cross_alignment='center',
      o.checkbox {key='check', label='Ignored checkbox request', checked=false,
        on_change=function(value) requests:set(requests()..(value and 'C1;' or 'C0;')) end},
      o.switch {key='switch', label='Ignored switch request', checked=true,
        on_change=function(value) requests:set(requests()..(value and 'S1;' or 'S0;')) end},
      o.text {key='label', text='Controlled: requests deliberately ignored'},
    },
    o.button {key='external', label='Set checkbox off and switch on', on_press=function()
      checked:set(false); switched:set(true)
    end},
    o.text {key='changes', text='Changes: '..changes()},
    o.text {key='requests', text='Requests: '..requests()},
    o.text {key='forbidden', text='Forbidden: '..forbidden()},
  }
  return root
end
return o.app {id='dev.ourokit.control-composition', run=function()
  local windows = {
    o.window {id='main', title='Control composition', width=540, height=520, content=content},
  }
  -- Fail a later window after the replacement controls have been staged.
  if reject then windows[#windows+1] = o.window {
    id='rejected', title='Rejected candidate', width=240, height=120,
    content=function() error('control composition candidate rejected') end,
  } end
  return {windows=windows}
end}
