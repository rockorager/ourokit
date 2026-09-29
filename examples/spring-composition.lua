-- Physical springs and the shared reduced-motion policy.
local o = require('ouro')
local revision = 1
local reject = false
local invalid = nil
local goal, reduced, present = o.signal(0), o.signal(false), o.signal(true)
local hits = o.signal(0)
local looping = o.signal(false)
local spring = {mass=1,stiffness=170,damping=18}

local function action(f)
  return {description='Spring fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() f(); return {} end}
end

local function scene()
  local declaration = invalid or spring
  return o.theme {key='policy',reduced_motion=reduced(),
    o.column {key='root',gap=18,
      o.text {key='title',text='Physical motion · revision '..revision,size=26,foreground='#173b61'},
      o.text {key='hint',text='Retarget the spring in flight; reduced motion settles every timeline.'},
      o.box {key='track',width=520,height=104,padding=12,clip=true,radius=14,background='#e8eef4',alignment='left',
        o.transition {key='spring',target=goal(),spring=declaration,motion='auto',render=function(value)
          return o.box {key='ball',width=72,height=80,radius=18,background='#389ac0',
            transform={x=400*value},role='button',activate=true,
            label=string.format('Spring %.9f',value),alignment='center',
            on_press=function() hits:set(hits()+(revision==1 and 3 or 7)) end,
            o.text {key='glyph',text='●',size=30,foreground='#ffffff'}}
        end}},
      o.row {key='lower',gap=18,
        o.box {key='loop-frame',width=250,height=84,padding=8,background='#e8eef4',alignment='left',
          o.animation {key='loop',duration=700,easing='linear',loop=looping(),motion='auto',render=function(value)
            return o.box {key='pulse',width=42,height=68,radius=10,background='#e6a23c',
              transform={x=180*value},label=string.format('Loop %.9f',value)}
          end}},
        o.box {key='presence-frame',width=250,height=84,padding=8,background='#e8eef4',alignment='left',
          o.presence {key='presence',present=present(),duration=700,motion='auto',render=function(value)
            return o.box {key='toast',width=220,height=68,radius=10,background='#173b61',
              opacity=math.max(0,math.min(1,value)),transform={x=22*(1-value)},
              label=string.format('Presence %.9f',value),alignment='center',
              o.text {key='text',text='Saved',foreground='#ffffff'}}
          end}},
      },
      o.row {key='controls',gap=10,
        o.button {key='left',label='Left',on_press=function() goal:set(0) end},
        o.button {key='right',label='Right',on_press=function() goal:set(1) end},
        o.button {key='motion',label=reduced() and 'Use full motion' or 'Reduce motion',
          on_press=function() reduced:set(not reduced()) end}},
      o.text {key='status',text=(reduced() and 'Reduced' or 'Full')..' · hits '..hits()},
    }}
end

return o.app {id='dev.ourokit.spring-composition',actions={
  Left=action(function() goal:set(0) end), Right=action(function() goal:set(1) end),
  Reduce=action(function() reduced:set(true) end), Full=action(function() reduced:set(false) end),
  StartLoop=action(function() looping:set(true) end),
  Hide=action(function() present:set(false) end), Show=action(function() present:set(true) end),
},run=function() return {windows={
  o.window {id='main',title='Physical spring motion',width=580,height=430,content=scene},
  reject and o.window {id='rejected',width=100,height=80,content=function() error('reject later window') end} or nil,
}} end}
