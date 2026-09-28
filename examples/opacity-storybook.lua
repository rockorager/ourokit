-- Native isolated opacity. All snapshots use two device pixels per logical pixel.
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
local function layers(alpha,child_alpha)
  return o.box {key='group',width=200,height=135,opacity=alpha,
    o.grid {key='layers',columns={60,80,60},rows={35,65,35},
      o.box {key='red',column=1,column_span=2,row=1,row_span=2,width=140,height=100,
        opacity=child_alpha,background='#c05030'},
      o.box {key='blue',column=2,column_span=2,row=2,row_span=2,width=140,height=100,
        opacity=child_alpha,background='#326cba'},
    }}
end
local function stage(content)
  return o.box {key='stage',width=200,height=175,background=ground,
    o.grid {key='layout',columns={200},rows={20,135,20},
      o.box {key='holder',column=1,row=2,width=200,height=135,content},
    }}
end
local function overlap()
  return page('One group, not two translucent children', 'Opaque blue covers red first. The completed group then fades in linear light.',
    o.row {key='panels',gap=20,
      panel('opaque','Opaque','The blue overlap is the same color as blue alone.',200,stage(layers(1,1))),
      panel('group','Group 0.5','One fade preserves that equality across the overlap.',200,stage(layers(.5,1))),
      panel('children','Each child 0.5','Different: red contributes beneath translucent blue.',200,stage(layers(1,.5))),
    })
end
local hits = o.signal(0)
local function nested()
  return page('Nested opacity multiplies; input does not fade', 'Playback: the invisible third group has received '..hits()..' click.',
    o.row {key='panels',gap=20,
      panel('nested','0.5 × 0.5','Two isolated groups produce quarter opacity.',200,
        stage(o.box {key='outer',width=200,height=135,opacity=.5,layers(.5,1)})),
      panel('quarter','Group 0.25','The same colors as the nested group.',200,stage(layers(.25,1))),
      panel('zero','Group 0','No pixels, but still mounted and hittable.',200,
        stage(o.box {key='invisible',width=200,height=135,opacity=0,
          activate=true,role='button',label='Invisible group',on_press=function() hits:set(hits()+1) end,
          layers(1,1)})),
    })
end
local gradient = o.linear_gradient {from={x=0,y=0},to={x=230,y=160},stops={
  {offset=0,color='#326d8a'},{offset=1,color='#162c55'},
}}
local path = o.drawing {width=190,height=110,commands={
  {kind='stroke',width=8,cap='round',color='#e8b65a',path={
    {'move',8,96},{'cubic',50,35,110,135,180,78},
  }},
}}
local function card_stage(alpha)
  return o.box {key='stage',width=310,height=220,background=ground,
    o.grid {key='layout',columns={40,230,40},rows={24,160,36},
      o.box {key='card',column=2,row=2,width=230,height=160,opacity=alpha,radius=18,
        background=gradient,border='#173b61',border_width=2,padding=18,
        shadow={x=4,y=10,blur=12,color='#20304090'},
        o.stack {key='layers',
          o.canvas {key='curve',drawing=path,alt='Gold cubic stroke with round caps'},
          o.box {key='copy',width=190,height=110,
            o.column {key='text',gap=8,
              o.text {key='title',text='One layer',size=24,foreground='#ffffff'},
              o.text {key='caption',text='Gradient · text · path',size=15,foreground='#ffffff'},
            }},
        }},
    }}
end
local function content()
  return page('Own paint and children fade together', 'The border, gradient, text, path and outset shadow belong to one isolated group.',
    o.row {key='panels',gap=20,
      panel('opaque','Opacity 1','The fast path paints without isolation.',310,card_stage(1)),
      panel('half','Opacity 0.5','Overlaps inside the card stay opaque before the final fade.',310,card_stage(.5)),
    })
end
local function clip_stage(ancestor)
  return o.box {key='stage',width=310,height=220,background=ground,
    o.grid {key='layout',columns={45,220,45},rows={25,170,25},
      o.box {key='outer',column=2,row=2,width=220,height=170,radius=36,clip=ancestor,
        o.box {key='group',width=220,height=170,opacity=.5,radius=36,clip=not ancestor,
          o.stack {key='layers',
            o.box {key='red',width=220,height=170,background='#c05030'},
            o.box {key='blue',width=220,height=170,background='#326cba'},
            o.box {key='copy',width=220,height=170,padding=36,
              o.text {key='text',text='Two full-size\nopaque children',size=20,foreground='#ffffff'}},
          }}},
    }}
end
local function clipping()
  return page('Where the rounded clip is applied matters', 'Compare the antialiased perimeter; interior paint and final opacity are identical.',
    o.row {key='panels',gap=20,
      panel('ancestor','Ancestor clip','One rounded coverage mask applies to the finished group.',310,clip_stage(true)),
      panel('internal','Internal clip','Inside the group, rounded coverage still applies separately to each draw.',310,clip_stage(false)),
    })
end
return o.storybook {title='Isolated group opacity',stories={
  o.story {id='opacity/overlap',name='Group versus child opacity',viewport={width=700,height=460},snapshot_scale=2,color_scheme='light',content=overlap},
  o.story {id='opacity/nested',name='Nested and zero opacity',viewport={width=700,height=460},snapshot_scale=2,color_scheme='light',content=nested,actions={
    {type='click',target='page/content/panels/zero/content/stage/layout/holder/invisible'},
  }},
  o.story {id='opacity/content',name='Own paint and mixed children',viewport={width=700,height=490},snapshot_scale=2,color_scheme='light',content=content},
  o.story {id='opacity/clipping',name='Ancestor versus internal clipping',viewport={width=700,height=490},snapshot_scale=2,color_scheme='light',content=clipping},
}}
