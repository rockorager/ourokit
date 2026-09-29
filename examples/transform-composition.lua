-- Paint-only transforms; tests/transform_composition.py checks window coordinates.
local o = require('ouro')
local revision = 1
local reject = false
local invalid_transform = nil
local moved, animating = o.signal(true), o.signal(false)
local hits, underneath = o.signal(0), o.signal(0)
local ground = '#e8eef4'
local color = revision == 1 and '#389ac0' or '#63b48a'
local retained_transform = {x=18,y=6,scale=1.25,origin={x=8,y=4}}
local retained = o.box {key='card',column=2,row=2,width=64,height=40,radius=10,
  transform=retained_transform,background='#75b98a'}
local recording = o.drawing {width=60,height=60,commands={
  {kind='rectangle',x=0,y=0,width=60,height=60,color='#c05030'},
  {kind='rectangle',x=20,y=10,width=40,height=50,color=color},
}}
local function hit() hits:set(hits() + (revision == 1 and 1 or 7)) end
local function hit_under() underneath:set(underneath() + (revision == 1 and 3 or 11)) end
local function set_moved(value) animating:set(false); moved:set(value) end
local function mutable(peer)
  return o.box {key='mutable',column=1,row=1,width=200,height=150,background=ground,
    o.grid {key='layout',columns={20,20,20,20,50,10,60},rows={30,10,15,5,10,5,75},
      o.box {key='marker',column=2,column_span=3,row=2,row_span=4,width=60,height=40,background='#ffffff'},
      o.box {key='old',column=3,row=3,row_span=2,width=20,height=20,background='#c05b37',
        activate=true,role='button',label='Original-position sibling',on_press=hit_under},
      o.box {key='new',column=6,row=4,row_span=3,width=10,height=20,
        activate=true,role='button',label='Moved-position sibling',on_press=hit_under},
      o.animation {key='motion',column=2,column_span=3,row=2,row_span=4,
        duration=peer and 0 or (animating() and 4000 or 0),easing='linear',loop=false,
        render=function(progress)
          local value = peer and 1 or (animating() and progress or (moved() and 1 or 0))
          local transform = nil
          if value ~= 0 then transform={x=80*value,y=10*value,scale=1+.5*value,origin={x=20,y=10}} end
          if invalid_transform ~= nil then transform=invalid_transform end
          return o.box {key='target',width=60,height=40,transform=transform,
            background=color,border='#247080',border_width=2,shadow={x=12,y=8,color='#203040'},
            activate=true,role='button',label=string.format('Progress %.6f',value),on_press=hit,
            o.grid {key='content',columns={8,20,28},rows={8,12,16},
              o.box {key='child',column=2,row=2,width=20,height=12,background='#e8b65a'},
            }}
        end},
    }}
end
local function nested()
  return o.box {key='nested',column=2,row=1,width=200,height=150,background=ground,
    o.grid {key='layout',columns={20,100,80},rows={20,80,50},
      o.box {key='outer',column=2,row=2,width=100,height=80,background='#adc3d8',
        transform={x=10,y=6,scale=1.5,origin={x=20,y=10}},
        o.grid {key='layout',columns={20,40,40},rows={15,30,35},
          o.box {key='inner',column=2,row=2,width=40,height=30,background='#ad74ce',
            transform={x=4,y=-2,scale=.5,origin={x=10,y=6}}},
        }},
    }}
end
local function clipping()
  return o.box {key='clipping',column=1,row=2,width=200,height=150,background=ground,
    o.grid {key='layout',columns={30,100,70},rows={30,80,40},
      o.box {key='clip',column=2,row=2,width=100,height=80,radius=18,clip=true,
        o.grid {key='layout',columns={60},rows={60},
          o.box {key='group',column=1,row=1,width=60,height=60,opacity=.5,
            transform={x=30,y=-10,scale=1.5,origin={x=10,y=20}},
            o.canvas {key='paint',drawing=recording,alt='Opaque overlap transformed inside a rounded ancestor'}},
        }},
    }}
end
local function copied()
  return o.box {key='copied',column=2,row=2,width=200,height=150,background=ground,
    o.grid {key='layout',columns={30,64,106},rows={30,40,80},retained}}
end
local function content(peer)
  return o.column {key='root',gap=12,
    o.text {key='title',text=peer and 'Peer transforms' or 'Paint-only transforms',size=24},
    o.text {key='legend',text='Moved paint + input / nested origins\nRounded clip + opacity / copied native values'},
    o.grid {key='gallery',columns={200,200},rows={150,150},column_gap=20,row_gap=24,
      mutable(peer),nested(),clipping(),copied()},
    o.text {key='status',text=peer and 'Peer revision '..revision or
      'Revision '..revision..' · hits '..hits()..' · under '..underneath()},
    o.row {key='controls',gap=10,
      o.button {key='identity',label='Identity',on_press=function() set_moved(false) end},
      o.button {key='moved',label='Transform',on_press=function() set_moved(true) end},
      o.button {key='animate',label='Animate',on_press=function() animating:set(true) end},
    },
  }
end
local function action(handler)
  return {description='Transform fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end
return o.app {id='dev.ourokit.transform-composition',actions={
  Identity=action(function() set_moved(false) end),
  Transform=action(function() set_moved(true) end),
  Animate=action(function() animating:set(true) end),
  MutateSource=action(function()
    retained_transform.x=900; retained_transform.scale=.01; retained_transform.origin.x=-600
  end),
  RestoreSource=action(function()
    retained_transform.x=18; retained_transform.scale=1.25; retained_transform.origin.x=8
  end),
},run=function() return {windows={
  o.window {id='main',title='Transform composition',width=480,height=590,
    content=function() return content(false) end},
  o.window {id='peer',title='Peer transforms',width=480,height=590,
    content=function() return content(true) end},
  reject and o.window {id='rejected',width=100,height=80,
    content=function() error('reject after preparing transformed windows') end} or nil,
}} end}
