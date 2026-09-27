local o = require('ouro')
local function content(options)
  options=options or {}
  local checked, value, choice = o.signal(true), o.signal(12), o.signal(29)
  return function()
    local enabled=not options.disabled
    local children={o.column {key='form',gap=16,
      o.text {key='title',text='Form controls',size=24},
      o.row {key='autosave',gap=10,cross_alignment='center',
        o.checkbox {key='control',label='Save automatically',checked=checked(),enabled=enabled,on_change=function(v) checked:set(v) end},
        o.text {key='label',text='Save automatically'}},
      o.radio_group {key='mode',selected=choice(),enabled=enabled,on_select=function(v) choice:set(v) end,
        o.radio {key='ask',value=17,label='Ask before reloading'},
        o.radio {key='reload',value=29,label='Reload unchanged documents'},
        o.radio {key='keep',value=43,label='Keep the current contents'}},
      o.select {key='encoding',label='Encoding',selected=2,enabled=enabled,width=300,
        options={{value=1,label='UTF-8'},{value=2,label='UTF-16'}}},
      o.text {key='size-label',text='Text size: '..value()},
      o.slider {key='size',label='Text size',width=300,value=value(),min=8,max=32,step=1,enabled=enabled,on_change=function(v) value:set(v) end},
      o.spinbox {key='number',label='Text size',value=value(),min=8,max=32,step=1,enabled=enabled,on_change=function(v) value:set(v) end},
    }}
    if options.dialog then children[2]=o.dialog {key='confirm',label='Reset preferences',width=390,
      o.column {key='body',gap=16,
        o.text {key='title',text='Reset preferences?',size=22},
        o.text {key='detail',text='Your current editor preferences will be replaced.'},
        o.row {key='actions',gap=10,o.button {key='cancel',label='Cancel',variant='soft',tone='neutral'},o.button {key='reset',label='Reset'}},
      }} end
    return o.stack {key='root',children=children}
  end
end
return o.storybook {id='forms', title='Form controls', stories={
  o.story {id='forms/light', name='Light', viewport={width=540,height=640}, content=content()},
  o.story {id='forms/dark', name='Dark', color_scheme='dark', viewport={width=540,height=640}, content=content()},
  o.story {id='forms/disabled', name='Disabled', viewport={width=540,height=640}, content=content{disabled=true}},
  o.story {id='forms/dialog', name='Modal confirmation', viewport={width=540,height=640}, content=content{dialog=true}},
  o.story {id='forms/changed', name='Changed and keyboard focused', viewport={width=540,height=640}, content=content(),
    actions={{type='click',target='root/form/autosave/control'}, {type='click',target='root/form/mode/keep'},
      {type='click',target='root/form/size'}}},
  o.story {id='forms/narrow', name='Constrained slider', viewport={width=220,height=100}, content=function()
    return o.slider {key='level',label='Level',width=300,value=7.5,min=0,max=10,step=0.5}
  end},
}}
