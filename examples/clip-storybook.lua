-- Native rounded child clips, including deterministic corner input at 2×.
local o = require('ouro')
local ink, ground = '#173b61', '#e5ebf2'
local gradient = o.linear_gradient {from={x=0,y=0},to={x=250,y=160},stops={
  {offset=0,color='#326d8a'},{offset=1,color='#162c55'},
}}
local artwork = o.drawing {width=250,height=160,commands={
  {kind='stroke',width=30,color='#183c67',path={{'move',-20,10},{'line',270,150}}},
  {kind='rectangle',x=-6,y=-6,width=36,height=36,color='#e8b65a'},
  {kind='rectangle',x=220,y=130,width=36,height=36,color='#75ce9f'},
}}
local overlap = o.drawing {width=230,height=160,rectangles={
  {x=0,y=0,width=170,height=130,color='#fa786980'},
  {x=70,y=40,width=160,height=120,color='#79bafa80'},
}}

local function panel(key,title,caption,content)
  return o.box {key=key,width=310,
    o.column {key='content',gap=12,
      o.text {key='title',text=title,size=20,foreground=ink},content,
      o.text {key='caption',text=caption,size=14,foreground='#42566c'},
    }}
end
local function page(title,caption,content)
  return o.box {key='page',padding=24,background='#f5f7fa',
    o.column {key='content',gap=20,
      o.text {key='title',text=title,size=28,foreground=ink},
      o.text {key='caption',text=caption,size=16,foreground='#42566c'},content,
    }}
end

local function content_stage(clipped)
  return o.box {key='stage',width=310,height=210,background=ground,
    o.grid {key='layout',columns={30,250,30},rows={24,160,26},
      o.box {key='card',column=2,row=2,width=250,height=160,radius=28,clip=clipped,
        o.stack {key='layers',
          o.box {key='gradient',width=250,height=160,background=gradient},
          o.canvas {key='drawing',drawing=artwork,alt='Diagonal stripe with gold and green corner tiles'},
          o.box {key='copy',width=250,height=160,padding=32,
            o.column {key='text',gap=12,
              o.text {key='title',text='Native content',size=22,foreground='#ffffff'},
              o.text {key='caption',text='Gradient + drawing + text',size=16,foreground='#ffffff'},
            }},
        }},
    }}
end
local function content()
  return page('One shape clips every child', 'Radius 28 · identical layout · only the child clip changes',
    o.row {key='panels',gap=20,
      panel('off','Unclipped','clip=false preserves square child corners.',content_stage(false)),
      panel('on','Rounded clip','clip=true trims gradient, drawing and text together.',content_stage(true)),
    })
end

local function nested_stage(scroll)
  local children = o.grid {key='layout',columns={16,250},rows={12,170},
    o.box {key='outer',column=2,row=2,width=250,height=170,radius=36,clip=true,background='#ffffff',
      o.grid {key='layout',columns={30,230},rows={20,160},
        o.box {key='inner',column=2,row=2,width=230,height=160,radius=30,clip=true,
          o.stack {key='layers',
            o.box {key='base',width=230,height=160,background=gradient},
            o.canvas {key='drawing',drawing=overlap,alt='Two translucent rectangles overlap within nested clips'},
          }},
      }},
  }
  return o.box {key='stage',width=310,height=220,background=ground,
    o.grid {key='layout',columns={24,230,56},rows={24,170,26},
      o.box {key='viewport',column=2,row=2,width=230,height=170,
        scroll and o.scroll {key='scroll',children} or children},
    }}
end
local function nested()
  return page('Nested rounded clips & Scroll', 'Per-draw clip coverage: overlapping paints remain separate draws.',
    o.row {key='panels',gap=20,
      panel('rounded','Two rounded clips','The offset inner shape intersects the larger outer curve.',nested_stage(false)),
      panel('scroll','Plus an ancestor Scroll','The same nested content also obeys a rectangular viewport.',nested_stage(true)),
    })
end

local function shadow_stage(scroll)
  local children = o.grid {key='layout',columns={40,120,20},rows={35,90},
    o.box {key='card',column=2,row=2,width=120,height=90,radius=24,clip=true,
      shadow={x=12,y=12,blur=10,spread=4,color='#20304090'},
      o.box {key='fill',width=120,height=90,background='#e8b65a'}},
  }
  return o.box {key='stage',width=310,height=210,background=ground,
    o.grid {key='layout',columns={24,180,106},rows={24,125,61},
      o.box {key='viewport',column=2,row=2,width=180,height=125,background='#ffffff',
        scroll and o.scroll {key='scroll',children} or children},
    }}
end
local function shadows()
  return page('Own paint precedes the child clip', 'A rounded child clip does not erase its box’s outset shadow.',
    o.row {key='panels',gap=20,
      panel('own','Own clip','Rounded children; soft shadow outside their clip.',shadow_stage(false)),
      panel('ancestor','Ancestor clip','The same shadow is trimmed by the ancestor Scroll.',shadow_stage(true)),
    })
end

local inside, under = o.signal(0), o.signal(0)
local function hit_inside() inside:set(inside()+1) end
local function input_stage(clipped)
  return o.box {key='stage',width=310,height=200,background=ground,
    o.grid {key='layout',columns={40,18,162,90},rows={30,18,112,40},
      o.box {key='under',column=2,row=2,width=18,height=18,background='#e89b64',
        activate=true,role='button',label='Underlying corner',on_press=function() under:set(under()+1) end},
      o.box {key='card',column=2,column_span=2,row=2,row_span=2,width=180,height=130,radius=40,clip=clipped,
        activate=true,role='button',label='Card center',on_press=hit_inside,
        o.grid {key='content',columns={18,162},rows={18,112},
          o.box {key='fill',column=1,column_span=2,row=1,row_span=2,width=180,height=130,background='#389ac0'},
          o.box {key='corner',column=1,row=1,width=18,height=18,
            activate=true,role='button',label='Child corner',on_press=hit_inside},
        }},
    }}
end
local function input()
  return page('Clipped corners let input through', 'Playback result: underlying '..under()..' · inside '..inside(),
    o.row {key='panels',gap=20,
      panel('rounded','Rounded hit shape','The orange corner is an underlying sibling, not part of the card.',input_stage(true)),
      panel('unclipped','Rectangular hit shape','Without clipping, the child covers and owns the same corner.',input_stage(false)),
    })
end

return o.storybook {title='Rounded child clips',stories={
  o.story {id='clips/content',name='Rounded child content',viewport={width=700,height=460},snapshot_scale=2,color_scheme='light',content=content},
  o.story {id='clips/nested',name='Nested rounded and Scroll clips',viewport={width=700,height=480},snapshot_scale=2,color_scheme='light',content=nested},
  o.story {id='clips/shadows',name='Own and ancestor shadow clipping',viewport={width=700,height=460},snapshot_scale=2,color_scheme='light',content=shadows},
  o.story {id='clips/input',name='Clipped corner input',viewport={width=700,height=460},snapshot_scale=2,color_scheme='light',content=input,actions={
    {type='click',target='page/content/panels/rounded/content/stage/layout/under'},
    {type='click',target='page/content/panels/rounded/content/stage/layout/card'},
    {type='click',target='page/content/panels/unclipped/content/stage/layout/card/content/corner'},
  }},
}}
