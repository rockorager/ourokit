-- Public box-shadow fixture for tests/shadow_composition.py. Run with --dev.
local o = require('ouro')
local revision = 1
local reject = false
local invalid_shadow = nil
local mode, presses = o.signal(0), o.signal(0)
local ground = '#dce6f0'

local function current_shadow(value)
  if invalid_shadow ~= nil then return invalid_shadow end
  if value == 2 then return nil end
  if value == 1 then
    return {x=-18, y=8, spread=-6, color='#4050a0'}
  end
  return {x=20, y=12, spread=4, color=revision == 1 and '#203040' or '#803020'}
end

local function press()
  presses:set(presses() + (revision == 1 and 3 or 7))
end

local function hard(peer)
  return o.box {key='hard', column=1, row=1, width=180, height=150, background=ground,
    o.grid {key='layout', columns={32,80,24,44}, rows={32,60,58},
      -- Its center lies in the shadow only. Declared first so an incorrectly
      -- expanded hit region on the later target would occlude this probe.
      o.box {key='probe', column=3, row=2, width=24, height=60, label='Shadow-only hit probe',
        activate=true, role='button', on_press=function() end},
      o.box {key='target', column=2, row=2, width=80, height=60,
        activate=true, role='button', label='Opaque shadow target', on_press=press,
        background='#e8b65a', border='#247080', border_width=3,
        shadow=current_shadow(peer and 0 or mode())},
    }}
end

local function sample(key, column, row, shadow, radius, background)
  return o.box {key=key, column=column, row=row, width=180, height=150, background=ground,
    o.grid {key='layout', columns={32,80,68}, rows={32,60,58},
      o.box {key='target', column=2, row=2, width=80, height=60,
        radius=radius, background=background, shadow=shadow},
    }}
end

local function clipped()
  return o.box {key='clip', column=2, row=2, width=180, height=150, background=ground,
    o.grid {key='outer', columns={20,110,50}, rows={20,94,36},
      o.box {key='viewport', column=2, row=2, width=110, height=94,
        o.scroll {key='scroll',
          o.grid {key='layout', columns={20,80,20}, rows={20,60,20},
            o.box {key='target', column=2, row=2, width=80, height=60,
              background='#e8b65a', shadow={x=28,y=24,color='#203040'}},
          }}},
    }}
end

local function content(peer)
  return o.column {key='root', gap=12,
    o.text {key='title', text=peer and 'Peer shadows' or 'Box-shadow composition', size=24},
    o.text {key='legend', text='Offset / transparent knockout\nBlur falloff / ancestor scroll clip'},
    o.grid {key='gallery', columns={180,180}, rows={150,150}, column_gap=24, row_gap=24,
      hard(peer),
      sample('knockout',2,1,{spread=12,color='#204060'},14,nil),
      sample('blur',1,2,{blur=12,color='#000000'},0,'#ffffff'),
      clipped(),
    },
    o.text {key='status', text=peer and 'Peer original · revision '..revision or
      'Revision '..revision..' · mode '..mode()..' · presses '..presses()},
    o.row {key='controls', gap=10,
      o.button {key='cycle', label='Replace / remove / reset', on_press=function() mode:set((mode()+1)%3) end},
      o.button {key='press', label='Invoke callback', on_press=press},
    },
  }
end

local function action(handler)
  return {description='Shadow fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end

return o.app {id='dev.ourokit.shadow-composition', actions={
  ReplaceShadow=action(function() mode:set(1) end),
  RemoveShadow=action(function() mode:set(2) end),
  ResetShadow=action(function() mode:set(0) end),
}, run=function() return {windows={
  o.window {id='main',title='Shadow composition',width=460,height=570,
    content=function() return content(false) end},
  o.window {id='peer',title='Peer shadows',width=460,height=570,
    content=function() return content(true) end},
  reject and o.window {id='rejected',width=100,height=80,
    content=function() error('reject after preparing live shadows') end} or nil,
}} end}
