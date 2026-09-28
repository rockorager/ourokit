-- Native linear-light gradients, exported at 2× without changing logical size.
local o = require('ouro')
local ink, ground = '#173b61', '#e5ebf2'

local function panel(key,title,caption,width,content)
  return o.box {key=key,width=width,
    o.column {key='content',gap=12,
      o.text {key='title',text=title,size=20,color=ink},
      content,
      o.text {key='caption',text=caption,size=14,color='#42566c'},
    }}
end

local function page(title,caption,content)
  return o.box {key='page',padding=24,background='#f5f7fa',
    o.column {key='content',gap=20,
      o.text {key='title',text=title,size=28,color=ink},
      o.text {key='caption',text=caption,size=16,color='#42566c'},
      content,
    }}
end

local function geometry()
  local stops = {{offset=0,color='#d95648'},{offset=.35,color='#f0c26c'},{offset=1,color='#326dba'}}
  local diagonal = o.linear_gradient {from={x=0,y=0},to={x=200,y=160},stops=stops}
  local reversed = o.linear_gradient {from={x=200,y=160},to={x=0,y=0},stops=stops}
  local bands = o.linear_gradient {from={x=20,y=0},to={x=180,y=0},stops={
    {offset=0,color='#423f78'}, {offset=.2,color='#b35fa4'},
    {offset=.7,color='#efab74'}, {offset=1,color='#78c4ab'},
  }}
  return page('Direction & multiple stops', 'Explicit endpoints in logical pixels; colors interpolate in linear light.',
    o.row {key='panels',gap=20,
      panel('diagonal','Diagonal','(0, 0) → (200, 160)\nThree asymmetric stops.',200,
        o.box {key='ramp',width=200,height=160,background=diagonal}),
      panel('reversed','Reversed','Same stops, with the endpoints swapped.',200,
        o.box {key='ramp',width=200,height=160,background=reversed}),
      panel('multiple','Four stops','Constant color before x 20 and after x 180.',200,
        o.box {key='ramp',width=200,height=160,background=bands}),
    })
end

local function stops()
  local hard = o.linear_gradient {from={x=0,y=0},to={x=310,y=0},stops={
    {offset=0,color='#304f72'}, {offset=.4,color='#304f72'},
    {offset=.4,color='#e8b65a'}, {offset=.7,color='#e8b65a'},
    {offset=.7,color='#75ce9f'}, {offset=1,color='#75ce9f'},
  }}
  local fade = o.linear_gradient {from={x=0,y=0},to={x=310,y=0},stops={
    {offset=0,color='#ff0000'}, {offset=1,color='#0000ff00'},
  }}
  local backdrop = {}
  for i=1,4 do
    backdrop[i] = o.box {key='band-'..i,column=i,row=1,width=77.5,height=160,
      background=i%2 == 0 and '#c5cfdb' or '#ffffff'}
  end
  return page('Hard stops & transparent endpoints', 'Duplicate offsets make a hard edge; transparent blue contributes no hue.',
    o.row {key='panels',gap=20,
      panel('hard','Last stop wins','Duplicate offsets at 0.4 and 0.7 produce three solid bands.',310,
        o.box {key='ramp',width=310,height=160,background=hard}),
      panel('fade','Red → transparent blue','Premultiplied interpolation fades red without a purple or blue halo.',310,
        o.box {key='stage',width=310,height=160,
          o.stack {key='layers',
            o.grid {key='backdrop',columns={77.5,77.5,77.5,77.5},rows={160},children=backdrop},
            o.box {key='ramp',width=310,height=160,background=fade},
          }}),
    })
end

local surface_gradient = o.linear_gradient {from={x=0,y=0},to={x=180,y=90},stops={
  {offset=0,color='#f5d595'}, {offset=.45,color='#8bd6b0'}, {offset=1,color='#4b85c5'},
}}
local function surface(clipped)
  local content = o.grid {key='layout',columns={35,180},rows={20,90,20},
    o.box {key='card',column=2,row=2,width=180,height=90,radius=16,
      background=surface_gradient,border='#274461',border_width=3,
      shadow={x=8,y=10,blur=12,color='#172c5070'}},
  }
  return o.box {key='stage',width=310,height=210,background=ground,
    o.grid {key='outer',columns={24,190,96},rows={24,130,56},
      o.box {key='viewport',column=2,row=2,width=190,height=130,background='#ffffff',
        clipped and o.scroll {key='scroll',content} or content},
    }}
end

local function surfaces()
  return page('Rounded surfaces & ancestor clips', 'Box-local gradient · solid 3 px border · one soft outset shadow',
    o.row {key='panels',gap=20,
      panel('visible','Unclipped','The rounded surface extends beyond its white parent bounds.',310,surface(false)),
      panel('clipped','Scroll clip','The right edge is cropped. Gradient coordinates do not stretch.',310,surface(true)),
    })
end

local source = {from={x=0,y=0},to={x=420,y=0},stops={
  {offset=0,color='#f19a75'}, {offset=.4,color='#e9c878'}, {offset=1,color='#79bafa'},
}}
local retained = o.linear_gradient(source)
local recording = o.drawing {width=420,height=180,commands={
  {kind='rectangle',x=16,y=20,width=110,height=140,corner_radius=14,color=retained},
  {kind='fill',color=retained,path={
    {'move',155,25},{'line',250,25},{'line',250,70},{'line',190,70},
    {'line',190,155},{'line',155,155},{'close'},
  }},
  {kind='stroke',width=16,cap='round',color=retained,path={
    {'move',270,140},{'cubic',300,0,350,180,395,40},
  }},
}}
source.from.x, source.to.x = 200, 210
source.stops[1].color = '#00ff00'
source.stops = {}

local function canvas(key,width)
  return o.box {key=key,width=width,height=180,background='#183048',
    o.canvas {key='image',drawing=recording,alt='Shared retained gradient rectangle, concave fill and cubic stroke'}}
end

local function snapshots()
  return page('One gradient, retained across paint commands', 'Drawing coordinates belong to the recording, not each primitive.',
    o.row {key='panels',gap=20,
      panel('full','Full · 420 × 180','Rectangle, fill and stroke share one immutable gradient after source mutations.',420,canvas('stage',420)),
      panel('crop','Crop · 180 × 180','The same recording, clipped without stretching.',180,canvas('stage',180)),
    })
end

return o.storybook {title='Linear gradients',stories={
  o.story {id='gradients/geometry',name='Direction and multiple stops',viewport={width=700,height=440},snapshot_scale=2,color_scheme='light',content=geometry},
  o.story {id='gradients/stops',name='Hard stops and transparency',viewport={width=700,height=440},snapshot_scale=2,color_scheme='light',content=stops},
  o.story {id='gradients/surfaces',name='Rounded surfaces and clipping',viewport={width=700,height=460},snapshot_scale=2,color_scheme='light',content=surfaces},
  o.story {id='gradients/snapshots',name='Shared retained recording',viewport={width=700,height=480},snapshot_scale=2,color_scheme='light',content=snapshots},
}}
