-- Native elapsed-time animation; render callbacks only return descriptions.
-- Exercised by tests/animation_composition.py on a private compositor.
local o = require('ouro')
local revision = 1
local reject = false
local shown, duration, easing, looping = o.signal(true), o.signal(1200), o.signal('linear'), o.signal(false)
local noise, reversed, delayed = o.signal(0), o.signal(false), o.signal(false)
local peer_shown, peer_open = o.signal(false), o.signal(true)
local count, peer_count = revision == 1 and 3 or 19, 0
local increment = revision == 1 and 5 or 11

local function bar(progress, peer)
  assert(type(progress)=='number' and progress>=0 and progress<=1)
  local width = math.floor((peer and 91 or 43) + (peer and 112 or 234)*progress + 0.5)
  return o.box {key='bar',width=width,height=76,padding=4,background='#37656f',
    o.column {key='content',gap=4,
      o.text {key='value',text=tostring(width),foreground='#ffffff',size=14},
      o.button {key='hit',label='+'..increment,width=34,height=28,padding_x=0,font_size=12,
        on_press=function()
          if peer then peer_count=peer_count+increment else count=count+increment end
        end},
    }}
end

local function content(peer)
  local visible = peer and peer_shown() or (not peer and shown())
  local hide_start = not peer and delayed()
  local children = {
    o.box {key='marker',column=2,row=1,width=17,height=13,background='#b96335'},
    o.box {key='spacer',column=1,row=2,width=47,height=76,background='#dcebea'},
  }
  if visible then
    children[#children+1] = o.animation {key='motion',column=2,row=2,
      duration=peer and 1200 or duration(),easing=peer and 'ease_in' or easing(),loop=not peer and looping(),
      render=function(progress)
        if hide_start and progress<0.35 then return nil end
        return bar(progress, peer)
      end}
  end
  if not peer and reversed() then
    local first = children[1]; children[1] = children[#children]; children[#children] = first
  end
  return o.column {key='root',gap=12,
    o.text {key='title',text=(peer and 'Peer' or 'Main')..' animation · revision '..revision,size=20},
    o.text {key='noise',text='Unrelated value: '..(peer and 0 or noise())},
    o.grid {key='tracks',columns={47,300},rows={13,76},column_gap=19,row_gap=11,children=children},
    o.text {key='hint',text=peer and 'Independent window: 91 → 203' or 'One shot: 43 → 277'},
    o.text {key='help',text='Use the development actions to restart, loop, reorder or remove.'},
  }
end

local function action(handler)
  return {description='Animation fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end

return o.app {id='dev.ourokit.animation-composition',actions={
  Inspect={description='Read callback state without invalidating animation',inputSchema={type='object'},
    outputSchema={type='object',properties={revision={type='integer'},count={type='integer'},peer_count={type='integer'}},
      required={'revision','count','peer_count'}},
    handler=function() return {revision=revision,count=count,peer_count=peer_count} end},
  RestartMain=action(function() duration:set(1200); easing:set('linear'); looping:set(false); delayed:set(false); shown:set(true) end),
  RemoveMain=action(function() shown:set(false) end),
  LoopMain=action(function() duration:set(1000); easing:set('linear'); looping:set(true); delayed:set(false); shown:set(true) end),
  InstantMain=action(function() duration:set(0); looping:set(false); delayed:set(false); shown:set(true) end),
  RetimeMain=action(function() duration:set(900); easing:set('ease_out') end),
  NilMain=action(function() duration:set(1200); easing:set('ease_in_out'); looping:set(false); delayed:set(true); shown:set(true) end),
  Unrelated=action(function() noise:set(noise()+1) end),
  Reorder=action(function() reversed:set(not reversed()) end),
  StartPeer=action(function() peer_shown:set(true) end),
  RemovePeer=action(function() peer_shown:set(false) end),
  ClosePeer=action(function() peer_open:set(false) end),
  OpenPeer=action(function() peer_open:set(true) end),
},run=function() return {windows=function()
  local windows={o.window {id='main',title='Animation composition',width=440,height=300,
    content=function() return content(false) end}}
  if peer_open() then windows[#windows+1]=o.window {id='peer',title='Independent animation',width=440,height=300,
    content=function() return content(true) end} end
  if reject then windows[#windows+1]=o.window {id='rejected',width=100,height=80,
    content=function() error('reject later window') end} end
  return windows
end} end}
