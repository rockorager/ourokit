-- One native outset shadow per box; every story exports at 2× scale.
local o = require('ouro')
local ground, ink = '#e5ebf2', '#173b61'

local function panel(key, title, caption, width, content)
  return o.box {key=key, width=width,
    o.column {key='content', gap=12,
      o.text {key='title',text=title,size=20,color=ink},
      content,
      o.text {key='caption',text=caption,size=14,color='#42566c'},
    }}
end

local function page(title, caption, content)
  return o.box {key='page',padding=24,background='#f5f7fa',
    o.column {key='content',gap=20,
      o.text {key='title',text=title,size=28,color=ink},
      o.text {key='caption',text=caption,size=16,color='#42566c'},
      content,
    }}
end

local function card(shadow)
  return o.box {key='stage',width=200,height=180,background=ground,
    o.grid {key='layout',columns={50,90,60},rows={44,70,66},
      o.box {key='card',column=2,row=2,width=90,height=70,radius=12,
        background='#ffffff',border='#c4cfdb',border_width=1,shadow=shadow},
    }}
end

local function styles()
  return page('Offset, softness & signed spread', 'Shadow geometry never changes the size or position of a box.',
    o.row {key='panels',gap=20,
      panel('hard','Hard offset','x 14 · y 12 · blur 0\nspread 0',200,
        card({x=14,y=12,color='#426da4'})),
      panel('expanded','Soft + expanded','x 0 · y 8 · blur 16\nspread +5',200,
        card({y=8,blur=16,spread=5,color='#172c5060'})),
      panel('contracted','Soft + contracted','x −12 · y 10 · blur 8\nspread −6',200,
        card({x=-12,y=10,blur=8,spread=-6,color='#684794a0'})),
    })
end

local function glass(key, background)
  return o.box {key=key,width=310,height=190,
    o.stack {key='layers',
      o.grid {key='backdrop',columns={155,155},rows={190},
        o.box {key='left',column=1,row=1,width=155,height=190,background='#d9e5f3'},
        o.box {key='right',column=2,row=1,width=155,height=190,background='#f0d9b5'},
      },
      o.box {key='center',width=310,height=190,alignment='center',
        o.box {key='glass',width=150,height=94,radius=22,background=background,
          border='#5f6f82',border_width=1,shadow={y=6,blur=14,spread=12,color='#304e8290'}}},
    }}
end

local function knockout()
  return page('Transparent boxes keep a clear interior', 'The ORIGINAL rounded box is knocked out of its shadow mask.',
    o.row {key='panels',gap=20,
      panel('transparent','No background','The two backdrop colors remain unchanged inside the outline.',310,
        glass('stage',nil)),
      panel('translucent','Translucent fill','Only the translucent white fill changes the interior; no shadow tint.',310,
        glass('stage','#ffffff60')),
    })
end

local function clipping_stage(clipped)
  local content = o.grid {key='layout',columns={70,90,20},rows={25,60,15},
    o.box {key='card',column=2,row=2,width=90,height=60,radius=10,background='#e8b65a',
      shadow={x=14,y=14,blur=16,color='#203040b0'}},
  }
  return o.box {key='stage',width=310,height=190,background=ground,
    o.grid {key='outer',columns={24,180,106},rows={24,100,66},
      o.box {key='viewport',column=2,row=2,width=180,height=100,background='#ffffff',
        clipped and o.scroll {key='scroll',content} or content},
    }}
end

local function clipping()
  return page('Ancestor clipping', 'White rectangles mark identical 180 × 100 parent bounds.',
    o.row {key='panels',gap=20,
      panel('visible','Ordinary box','The outset shadow paints beyond its parent’s white bounds.',310,clipping_stage(false)),
      panel('clipped','Scroll viewport','The ancestor scroll clip cuts off shadow coverage at its bounds.',310,clipping_stage(true)),
    })
end

local function popup()
  return page('Anchored popup elevation', 'A native overlay casts one soft shadow above ordinary page content.',
    o.box {key='stage',width=640,height=290,padding=24,background=ground,
      o.column {key='body',gap=22,
        o.anchored {key='menu',side='bottom',alignment='start',gap=12,margin=24,
          o.button {key='trigger',width=190,label='Workspace options'},
          o.box {key='popup',width=300,height=178,padding=18,radius=12,background='#ffffff',
            border='#c4cfdb',border_width=1,shadow={y=10,blur=20,spread=1,color='#172c5060'},
            o.column {key='items',gap=14,
              o.text {key='title',text='Workspace',size=20,color=ink},
              o.text {key='first',text='Open recent project',color='#42566c'},
              o.text {key='second',text='Browse workspace files',color='#42566c'},
              o.text {key='third',text='Manage preferences',color='#42566c'},
            }},
        },
        o.box {key='underneath',width=540,height=160,padding=18,background='#d1deed',
          o.text {key='label',text='Underlying content',color='#607a99'}},
      }})
end

return o.storybook {title='Box shadows',stories={
  o.story {id='shadows/styles',name='Offset and signed spread',viewport={width=700,height=450},snapshot_scale=2,color_scheme='light',content=styles},
  o.story {id='shadows/knockout',name='Transparent knockout',viewport={width=700,height=450},snapshot_scale=2,color_scheme='light',content=knockout},
  o.story {id='shadows/clipping',name='Ancestor clipping',viewport={width=700,height=450},snapshot_scale=2,color_scheme='light',content=clipping},
  o.story {id='shadows/popup',name='Anchored popup elevation',viewport={width=700,height=450},snapshot_scale=2,color_scheme='light',content=popup},
}}
