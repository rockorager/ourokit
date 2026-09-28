-- Public rounded-child-clip fixture for tests/clip_composition.py.
local o = require('ouro')
local revision = 1
local reject = false
local clipped, radius = o.signal(true), o.signal(24)
local inside, under = o.signal(0), o.signal(0)
local ground = '#dce6f0'
local paint = revision == 1 and '#389ac0' or '#63b48a'
local function hit_inside() inside:set(inside() + (revision == 1 and 1 or 7)) end
local function hit_under() under:set(under() + (revision == 1 and 3 or 11)) end

local function shape(peer)
  return o.box {key='shape',column=1,row=1,width=180,height=150,background=ground,
    o.grid {key='layout',columns={32,12,68,68},rows={32,12,48,58},
      -- Direct siblings: no covering wrapper can intercept corner fall-through.
      o.box {key='under',column=2,row=2,width=12,height=12,background='#c05b37',
        activate=true,role='button',label='Underlying corner',on_press=hit_under},
      o.box {key='target',column=2,column_span=2,row=2,row_span=2,width=80,height=60,
        clip=peer or clipped(),radius=peer and 24 or radius(),background='#ffffff',
        activate=true,role='button',label='Clipped box center',on_press=hit_inside,
        o.grid {key='content',columns={12,68},rows={12,48},
          o.box {key='paint',column=1,column_span=2,row=1,row_span=2,width=80,height=60,background=paint},
          o.box {key='corner',column=1,row=1,width=12,height=12,
            activate=true,role='button',label='Child corner',on_press=hit_inside},
        }},
    }}
end

local function own_shadow()
  return o.box {key='own',column=2,row=1,width=180,height=150,background=ground,
    o.grid {key='layout',columns={32,80,68},rows={32,60,58},
      o.box {key='target',column=2,row=2,width=80,height=60,clip=true,radius=20,
        shadow={x=14,y=14,spread=2,color='#203040'},
        o.box {key='paint',width=80,height=60,background=paint}},
    }}
end

local function nested()
  return o.box {key='nested',column=1,row=2,width=180,height=150,background=ground,
    o.grid {key='layout',columns={30,100,50},rows={25,90,35},
      o.box {key='outer',column=2,row=2,width=100,height=90,clip=true,radius=30,background='#ffffff',
        o.grid {key='layout',columns={25,90},rows={10,80},
          o.box {key='inner',column=2,row=2,width=90,height=80,clip=true,radius=24,
            o.box {key='paint',width=90,height=80,background='#ad74ce'}},
        }},
    }}
end

local function ancestor()
  return o.box {key='ancestor',column=2,row=2,width=180,height=150,background=ground,
    o.grid {key='layout',columns={20,110,50},rows={20,94,36},
      o.box {key='viewport',column=2,row=2,width=110,height=94,
        o.scroll {key='scroll',
          o.grid {key='layout',columns={20,80,20},rows={20,60,20},
            o.box {key='target',column=2,row=2,width=80,height=60,clip=true,radius=20,
              shadow={x=28,y=24,color='#203040'},
              o.box {key='paint',width=80,height=60,background=paint}},
          }}},
    }}
end

local function content(peer)
  return o.column {key='root',gap=12,
    o.text {key='title',text=peer and 'Peer rounded clips' or 'Rounded child clipping',size=24},
    o.text {key='legend',text='Corner input / own shadow\nNested clips / ancestor Scroll clip'},
    o.grid {key='gallery',columns={180,180},rows={150,150},column_gap=24,row_gap=24,
      shape(peer),own_shadow(),nested(),ancestor()},
    o.text {key='status',text=peer and 'Peer original · revision '..revision or
      'Revision '..revision..' · clip '..tostring(clipped())..' · radius '..radius()..
      ' · inside '..inside()..' · under '..under()},
    o.row {key='controls',gap=10,
      o.button {key='square',label='Square corners',on_press=function() radius:set(0) end},
      o.button {key='toggle',label='Toggle clip',on_press=function() clipped:set(not clipped()) end},
      o.button {key='round',label='Radius 24',on_press=function() radius:set(24) end},
    },
  }
end

local function action(handler)
  return {description='Clip fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end

return o.app {id='dev.ourokit.clip-composition',actions={
  Square=action(function() radius:set(0) end),
  Round=action(function() radius:set(24) end),
  ToggleClip=action(function() clipped:set(not clipped()) end),
},run=function() return {windows={
  o.window {id='main',title='Clip composition',width=480,height=590,
    content=function() return content(false) end},
  o.window {id='peer',title='Peer clips',width=480,height=590,
    content=function() return content(true) end},
  reject and o.window {id='rejected',width=100,height=80,
    content=function() error('reject after preparing live rounded clips') end} or nil,
}} end}
