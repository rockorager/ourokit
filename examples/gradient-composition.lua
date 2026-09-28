-- Public retained-gradient fixture for tests/gradient_composition.py.
local o = require('ouro')
local revision = 1
local reject = false
local endpoint = revision == 1 and '#ffffff' or '#00ff00'
local source = {from={x=.5,y=0},to={x=160.5,y=0},stops={
  {offset=0,color='#000000'}, {offset=1,color=endpoint},
}}
local shared = o.linear_gradient(source)
local selected = o.signal(shared)
local mutations, replacements = o.signal(0), o.signal(0)
local fade = o.linear_gradient {from={x=.5,y=0},to={x=160.5,y=0},stops={
  {offset=0,color='#ff0000'}, {offset=1,color='#0000ff00'},
}}
local hard = o.linear_gradient {from={x=.5,y=0},to={x=160.5,y=0},stops={
  {offset=0,color='#304050'}, {offset=.5,color='#304050'},
  {offset=.5,color='#d09020'}, {offset=1,color='#d09020'},
}}
local recording = o.drawing {width=240,height=160,commands={
  {kind='rectangle',x=20,y=10,width=190,height=35,color=shared},
  {kind='fill',color=shared,path={
    {'move',60,60},{'line',210,60},{'line',210,105},{'line',60,105},{'close'},
  }},
  {kind='stroke',color=shared,width=14,cap='round',path={{'move',35,135},{'line',215,135}}},
}}

local function mutate_source()
  -- Change nested endpoint/stop fields, a list entry, then each outer table.
  if source.stops[1] then
    source.from.x, source.to.y = 90, 120
    source.stops[1].color = '#ff00ff'
    source.stops[2].offset = .2
    source.stops[2] = {offset=1,color='#00ffff'}
  end
  source.from, source.to, source.stops = {x=50,y=50}, {x=75,y=90}, {}
  mutations:set(mutations()+1)
end

local function replace_main()
  selected:set(o.linear_gradient {from={x=.5,y=0},to={x=160.5,y=0},stops={
    {offset=0,color=revision == 1 and '#ffffff' or '#ffff00'}, {offset=1,color='#000000'},
  }})
  replacements:set(replacements() + (revision == 1 and 3 or 7))
end

local function content(peer)
  return o.column {key='root',gap=12,
    o.text {key='title',text=peer and 'Shared retained gradients' or 'Gradient composition',size=24},
    o.text {key='legend',text='Opaque ramp / premultiplied fade / duplicate hard stop'},
    o.grid {key='samples',columns={180,180,180},rows={80},column_gap=20,
      o.box {key='ramp',column=1,row=1,width=180,height=80,surface='card',
        background=peer and shared or selected()},
      o.box {key='fade',column=2,row=1,width=180,height=80,background='#ffffff',
        o.box {key='paint',width=180,height=80,background=fade}},
      o.box {key='hard',column=3,row=1,width=180,height=80,background=hard},
    },
    o.text {key='caption',text='One recording: offset rectangle / fill / stroke; shared 117 px crop'},
    o.box {key='frame',padding=12,background='#183048',
      o.grid {key='gallery',columns={240,117},rows={160},column_gap=20,
        o.canvas {key='full',column=1,row=1,drawing=recording,
          alt='Shared gradient in rectangle, fill and stroke at recording coordinates'},
        o.canvas {key='crop',column=2,row=1,drawing=recording,
          alt='Same gradient recording cropped without stretching'},
      }},
    o.text {key='status',text=peer and 'Peer original · revision '..revision or
      'Revision '..revision..' · source edits '..mutations()..' · replacement count '..replacements()},
    o.row {key='controls',gap=10,
      o.button {key='mutate',label='Mutate source tables',on_press=mutate_source},
      o.button {key='replace',label='Replace main ramp',on_press=replace_main},
    },
  }
end

local function action(handler)
  return {description='Gradient fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end

return o.app {id='dev.ourokit.gradient-composition',actions={
  MutateSource=action(mutate_source), ReplaceMain=action(replace_main),
},run=function() return {windows={
  o.window {id='main',title='Gradient composition',width=660,height=550,
    content=function() return content(false) end},
  o.window {id='peer',title='Shared gradients',width=660,height=550,
    content=function() return content(true) end},
  reject and o.window {id='rejected',width=100,height=80,
    content=function() error('reject after preparing live gradients') end} or nil,
}} end}
