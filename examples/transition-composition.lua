-- Interruptible numeric transitions on the shared native animation clock.
local o = require('ouro')
local revision = 1
local reject = false
local invalid = nil
local goal, duration, shown = o.signal(0), o.signal(1600), o.signal(true)
local hovered, noise, hits = o.signal(false), o.signal(0), o.signal(0)
local ink, blue, ground = '#173b61', '#389ac0', '#e8eef4'
local function panel(key, title, child)
  return o.column {key=key,gap=12,width=180,
    o.text {key='title',text=title,size=18,foreground=ink},child}
end
local function content(peer)
  local target = peer and .35 or goal()
  if invalid ~= nil then target=invalid end
  return o.column {key='root',gap=20,
    o.text {key='title',text='Interruptible transitions · revision '..revision,size=26,foreground=ink},
    o.text {key='hint',text='Change direction mid-flight. Layout stays put; settled motion sleeps.'},
    o.row {key='gallery',gap=20,
      panel('hover','Hover scale',o.box {key='viewport',width=180,height=120,padding=20,background=ground,
        on_pointer={kinds={'enter','leave'},propagate=true,handler=function(e) if not peer then hovered:set(e.kind=='enter') end end},
        o.transition {key='motion',target=not peer and hovered() and 1.12 or 1,duration=240,easing='ease_out',
          render=function(scale)
            return o.box {key='card',width=140,height=80,radius=12,background=blue,
              transform={scale=scale,origin={x=70,y=40}},label=string.format('Scale %.6f',scale),
              alignment='center',o.text {key='label',text='Hover me',foreground='#ffffff'}}
          end}}),
      panel('slide','Sliding panel',o.box {key='viewport',width=180,height=120,padding=10,alignment='left',clip=true,radius=12,background=ground,
        (peer or shown()) and o.transition {key='motion',target=target,duration=duration(),easing='linear',
          render=function(value)
            return o.box {key='card',width=80,height=100,radius=8,background=blue,
              transform={x=80*value},role='button',activate=true,label=string.format('Value %.6f',value),
              on_press=function() hits:set(hits()+(revision==1 and 3 or 7)) end,
              alignment='center',o.text {key='label',text='Slide',foreground='#ffffff'}}
          end} or nil}),
      panel('fade','Group fade',o.box {key='viewport',width=180,height=120,padding=10,background=ground,
        o.transition {key='motion',target=target,duration=duration(),easing='linear',render=function(value)
          return o.box {key='card',width=160,height=100,radius=8,background=blue,opacity=.25+.75*value,
            label=string.format('Value %.6f',value),alignment='center',
            o.text {key='label',text='Fade',foreground='#ffffff'}}
        end}}),
    },
    o.row {key='controls',gap=12,
      o.button {key='open',label='Open / brighten',on_press=function() goal:set(1) end},
      o.button {key='close',label='Reverse',on_press=function() goal:set(0) end},
    },
    o.text {key='status',text=peer and 'Independent peer at 0.35' or 'Hits '..hits()..' · unrelated '..noise()},
  }
end
local function action(handler)
  return {description='Transition fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler();return {} end}
end
return o.app {id='dev.ourokit.transition-composition',actions={
  Open=action(function() goal:set(1) end), Close=action(function() goal:set(0) end),
  Retime=action(function() duration:set(800) end), Instant=action(function() duration:set(0);goal:set(1) end),
  Remove=action(function() shown:set(false) end), Show=action(function() shown:set(true) end),
  Noise=action(function() noise:set(noise()+1) end),
},run=function() return {windows={
  o.window {id='main',title='Interruptible transitions',width=640,height=360,content=function() return content(false) end},
  o.window {id='peer',title='Independent transitions',width=640,height=360,content=function() return content(true) end},
  reject and o.window {id='rejected',width=100,height=80,content=function() error('reject later window') end} or nil,
}} end}
