local o = require('ouro')
local initial_padding = 0
local initial_background = '#18344b'
local reject = false
local mode, opened = o.signal(0), o.signal(false)
local function close() opened:set(false) end

local Scheme = o.stateless(function(p, children, theme)
  local dark = theme.color_scheme == 'dark'
  return o.box {key=p.key, padding=12, background=dark and '#283444' or '#e4edf4',
    foreground=dark and '#ffffff' or '#162838',
    o.text {key='label', text=p.label .. ': ' .. theme.color_scheme},
  }
end)
local Retained = o.stateful(function()
  return function() return Scheme {key='scheme', label='Inherited scheme'} end
end)

local function content()
  local children = {o.box {key='page', width='fill', height='fill', padding=24,
    o.column {key='body', gap=12,
      o.text {key='title', text='Window-owned layout', size=26, foreground=mode()==2 and '#162838' or '#ffffff'},
      Retained {key='retained'},
      o.theme {key='light', color_scheme='light', colors={background='#000000'},
        Scheme {key='scheme', label='Explicit light (black palette background)'},
      },
      o.theme {key='dark', color_scheme='dark', colors={background='#ffffff'},
        o.theme {key='nested', controls={height=36},
          Scheme {key='scheme', label='Nested dark (white palette background)'},
        },
      },
      o.button {key='modal', label='Open full-window dialog', on_press=function() opened:set(true) end},
      o.button {key='inset', label='Cycle window padding / background', on_press=function() mode:set((mode()+1)%3) end},
    },
  }}
  if opened() then children[#children+1] = o.dialog {key='dialog', label='Full-window dialog', width=350, on_cancel=close,
    o.column {key='body', gap=16,
      o.text {key='title', text='Every edge is covered', size=22},
      o.text {key='detail', text='Page padding stays inside the modal backdrop.'},
      o.button {key='close', label='Close dialog', on_press=close},
    },
  } end
  return o.stack {key='root', children=children}
end

return o.app {
  id='dev.ourokit.window-theme',
  -- Pin every color, but not the scheme: live preference updates must still
  -- invalidate compositions. Palette luminance cannot identify this scheme.
  theme={colors=o.tokens.light},
  run=function() return {windows=function()
    local padding, background = initial_padding, initial_background
    if mode() == 1 then padding, background = 19, '#704524'
    elseif mode() == 2 then padding, background = nil, nil end
    return {
      o.window {id='main', title='Window theme', width=580, height=440,
        padding=padding, background=background, content=content},
      o.window {id='defaults', title='Unchanged defaults', width=260, height=140,
        content=function()
          if reject then error('reject later window') end
          return o.box {key='root', width='fill', height='fill', o.text {key='label', text='Default 12 px inset'}}
        end},
    }
  end} end,
}
