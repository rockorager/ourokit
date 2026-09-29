-- Native paint-only translation and uniform scale, at two device pixels per point.
local o = require('ouro')
local ink, ground = '#173b61', '#e8eef4'
local function page(title,caption,content)
  return o.box {key='page',padding=24,background='#f5f7fa',
    o.column {key='content',gap=20,
      o.text {key='title',text=title,size=28,foreground=ink},
      o.text {key='caption',text=caption,size=16,foreground='#42566c'},content,
    }}
end
local function panel(key,title,caption,width,content)
  return o.box {key=key,width=width,
    o.column {key='content',gap=12,
      o.text {key='title',text=title,size=20,foreground=ink},content,
      o.text {key='caption',text=caption,size=14,foreground='#42566c'},
    }}
end
local function geometry_stage(transform)
  return o.box {key='stage',width=200,height=180,background=ground,
    o.grid {key='layout',columns={35,80,85},rows={50,60,70},
      o.box {key='marker',column=2,row=2,width=80,height=60,background='#ffffff',border='#91a5b9',border_width=1},
      o.box {key='card',column=2,row=2,width=80,height=60,transform=transform,
        background='#389ac0',border='#173b61',border_width=2,padding=8,
        o.text {key='text',text='Paint',size=18,foreground='#ffffff'}},
    }}
end
local function geometry()
  return page('Transform the paint, keep the layout', 'The white marker always occupies the original 80 × 60 layout slot.',
    o.row {key='panels',gap=20,
      panel('identity','Identity','No transform; paint covers its original slot.',200,geometry_stage(nil)),
      panel('translate','Translation','x +60, y −20. The original slot stays put.',200,geometry_stage({x=60,y=-20})),
      panel('scale','Scale about center','Scale 1.5 around local origin (40, 30). Text and border scale too.',200,
        geometry_stage({scale=1.5,origin={x=40,y=30}})),
    })
end
local outer_transform = {x=20,y=12,scale=1.5,origin={x=20,y=10}}
local function nested_stage(flat)
  local inner = o.box {key='inner',column=2,row=2,width=40,height=30,background='#ad74ce',
    transform={x=4,y=-2,scale=.5,origin={x=10,y=6}}}
  return o.box {key='stage',width=310,height=220,background=ground,
    o.grid {key='layout',columns={40,20,40,60,150},rows={40,15,30,55,80},
      o.box {key='outer',column=2,column_span=3,row=2,row_span=3,width=120,height=100,
        transform=outer_transform,background='#adc3d8',
        not flat and o.grid {key='layout',columns={20,40,60},rows={15,30,55},inner} or nil},
      flat and o.box {key='flat',column=3,row=3,width=40,height=30,background='#ad74ce',
        transform={x=33.5,y=16,scale=.75}} or nil,
    }}
end
local function nested()
  return page('Nested origins compose parent after child', 'The two scenes agree: the smaller purple shape has effective scale 0.75.',
    o.row {key='panels',gap=20,
      panel('nested','Nested maps','Outer scale 1.5; inner scale 0.5, each with a different origin and translation.',310,nested_stage(false)),
      panel('flat','Equivalent flat map','The purple sibling uses scale 0.75 and translation (33.5, 16).',310,nested_stage(true)),
    })
end
local gradient = o.linear_gradient {from={x=0,y=0},to={x=190,y=130},stops={
  {offset=0,color='#326d8a'},{offset=1,color='#162c55'},
}}
local drawing = o.drawing {width=154,height=94,commands={
  {kind='stroke',width=7,cap='round',color='#e8b65a',path={
    {'move',5,80},{'cubic',40,30,100,110,145,65},
  }},
}}
local function content_stage(clipped)
  return o.box {key='stage',width=310,height=240,background=ground,
    o.grid {key='layout',columns={24,230,56},rows={24,170,46},
      o.box {key='viewport',column=2,row=2,width=230,height=170,radius=24,clip=clipped,background='#ffffff',
        o.grid {key='layout',columns={20,190,20},rows={20,130,20},
          o.box {key='card',column=2,row=2,width=190,height=130,radius=14,opacity=.65,
            transform={x=20,y=5,scale=1.2,origin={x=20,y=20}},
            background=gradient,border='#173b61',border_width=2,padding=16,
            shadow={x=8,y=8,blur=8,color='#203040a0'},
            o.stack {key='layers',
              o.canvas {key='curve',drawing=drawing,alt='Gold transformed cubic stroke'},
              o.box {key='copy',width=154,height=94,
                o.column {key='text',gap=6,
                  o.text {key='title',text='Native paint',size=20,foreground='#ffffff'},
                  o.text {key='caption',text='One transformed group',size=12,foreground='#ffffff'},
                }},
            }},
        }},
    }}
end
local function content()
  return page('Transform every paint, then respect ancestor clips', 'Scale 1.2 · opacity 0.65 · gradient, text, path, border and shadow',
    o.row {key='panels',gap=20,
      panel('overflow','Unclipped overflow','The transformed group extends beyond the white parent without changing layout.',310,content_stage(false)),
      panel('clipped','Rounded ancestor clip','The same group and its shadow stop at the parent’s rounded boundary.',310,content_stage(true)),
    })
end
local inside, under = o.signal(0), o.signal(0)
local function input_stage(moved)
  return o.box {key='stage',width=310,height=200,background=ground,
    o.grid {key='layout',columns={40,30,30,30,180},rows={30,20,30,20,100},
      o.box {key='marker',column=2,column_span=3,row=2,row_span=3,width=90,height=70,background='#ffffff'},
      o.box {key='old',column=3,row=3,width=30,height=30,background='#e8b65a',
        activate=true,role='button',label='Old-position sibling',on_press=function() under:set(under()+1) end},
      o.box {key='target',column=2,column_span=3,row=2,row_span=3,width=90,height=70,
        transform=moved and {x=120,y=15} or nil,background='#389ac0',radius=10,padding=16,
        activate=true,role='button',label='Moved target',on_press=function() inside:set(inside()+1) end,
        o.text {key='label',text='Click',size=20,foreground='#ffffff'}},
    }}
end
local function input()
  return page('Input follows visual coordinates', 'Playback: target '..inside()..' · underlying old position '..under(),
    o.row {key='panels',gap=20,
      panel('identity','Original position','The blue target covers the gold sibling.',310,input_stage(false)),
      panel('moved','Translated position','The old position now reaches gold; the moved blue target still activates.',310,input_stage(true)),
    })
end
return o.storybook {title='Paint-only transforms',stories={
  o.story {id='transforms/geometry',name='Paint and layout',viewport={width=700,height=460},snapshot_scale=2,color_scheme='light',content=geometry},
  o.story {id='transforms/nested',name='Nested local origins',viewport={width=700,height=500},snapshot_scale=2,color_scheme='light',content=nested},
  o.story {id='transforms/content',name='Mixed transformed paint and clips',viewport={width=700,height=530},snapshot_scale=2,color_scheme='light',content=content},
  o.story {id='transforms/input',name='Transformed hit locations',viewport={width=700,height=470},snapshot_scale=2,color_scheme='light',content=input,actions={
    {type='click',target='page/content/panels/identity/content/stage/layout/target'},
    {type='click',target='page/content/panels/moved/content/stage/layout/old'},
    {type='click',target='page/content/panels/moved/content/stage/layout/target'},
  }},
}}
