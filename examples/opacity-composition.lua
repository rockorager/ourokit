-- Isolated group opacity, exercised by tests/opacity_composition.py.
local o = require('ouro')
local revision = 1
local reject = false
local invalid_opacity = nil
local opacity, animating, count = o.signal(.5), o.signal(false), o.signal(0)
local ground = '#e8eef4'
local recording = o.drawing {width=120,height=100,commands={
  {kind='rectangle',x=0,y=0,width=85,height=70,color='#c05030'},
  {kind='rectangle',x=35,y=20,width=85,height=70,color=revision == 1 and '#326cba' or '#24b48a'},
}}
local function canvas()
  return o.canvas {key='paint',drawing=recording,alt='Opaque red and blue overlap'}
end
local function set_opacity(value) animating:set(false); opacity:set(value) end
local function hit() count:set(count() + (revision == 1 and 3 or 7)) end

local function mutable(peer)
  return o.box {key='mutable',column=1,row=1,width=180,height=150,background=ground,
    o.grid {key='layout',columns={30,120,30},rows={25,100,25},
      o.animation {key='motion',column=2,row=2,duration=peer and 0 or (animating() and 4000 or 0),
        easing='linear',loop=false,render=function(progress)
          local alpha = peer and .5 or (animating() and progress or opacity())
          return o.box {key='group',width=120,height=100,
            opacity=invalid_opacity == nil and alpha or invalid_opacity,
            activate=true,role='button',label=string.format('Opacity %.6f',alpha),on_press=hit,
            canvas()}
        end},
    }}
end
local function nested()
  return o.box {key='nested',column=2,row=1,width=180,height=150,background=ground,
    o.grid {key='layout',columns={30,120,30},rows={25,100,25},
      o.box {key='outer',column=2,row=2,width=120,height=100,opacity=.5,
        o.box {key='inner',width=120,height=100,opacity=.5,canvas()}},
    }}
end
local function decoration()
  return o.box {key='decoration',column=1,row=2,width=180,height=150,background=ground,
    o.grid {key='layout',columns={32,80,68},rows={32,60,58},
      o.box {key='group',column=2,row=2,width=80,height=60,opacity=.5,
        background='#e8b65a',border='#247080',border_width=3,
        shadow={x=20,y=12,color='#203040'},
        o.grid {key='layout',columns={10,30,34},rows={10,20,24},
          o.box {key='child',column=2,row=2,width=30,height=20,background='#389464'},
        }},
    }}
end
local function clipping()
  return o.box {key='clipping',column=2,row=2,width=180,height=150,background=ground,
    o.grid {key='layout',columns={30,100,50},rows={25,90,35},
      o.box {key='clip',column=2,row=2,width=100,height=90,radius=24,clip=true,
        o.grid {key='layout',columns={120},rows={100},
          o.box {key='group',column=1,row=1,width=120,height=100,opacity=.5,canvas()},
        }},
    }}
end
local function content(peer)
  return o.column {key='root',gap=12,
    o.text {key='title',text=peer and 'Peer opacity' or 'Isolated group opacity',size=24},
    o.text {key='legend',text='Mutable overlap / nested quarter opacity\nOwn paint + shadow / ancestor rounded clip'},
    o.grid {key='gallery',columns={180,180},rows={150,150},column_gap=24,row_gap=24,
      mutable(peer),nested(),decoration(),clipping()},
    o.text {key='status',text=peer and 'Peer revision '..revision or
      'Revision '..revision..' · count '..count()},
    o.row {key='controls',gap=10,
      o.button {key='zero',label='Zero',on_press=function() set_opacity(0) end},
      o.button {key='half',label='Half',on_press=function() set_opacity(.5) end},
      o.button {key='full',label='Full',on_press=function() set_opacity(1) end},
      o.button {key='fade',label='Animate',on_press=function() animating:set(true) end},
    },
  }
end
local function action(handler)
  return {description='Opacity fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end
return o.app {id='dev.ourokit.opacity-composition',actions={
  Zero=action(function() set_opacity(0) end),
  Half=action(function() set_opacity(.5) end),
  Full=action(function() set_opacity(1) end),
  Fade=action(function() animating:set(true) end),
},run=function() return {windows={
  o.window {id='main',title='Opacity composition',width=480,height=590,
    content=function() return content(false) end},
  o.window {id='peer',title='Peer opacity',width=480,height=590,
    content=function() return content(true) end},
  reject and o.window {id='rejected',width=100,height=80,
    content=function() error('reject after preparing both opacity windows') end} or nil,
}} end}
