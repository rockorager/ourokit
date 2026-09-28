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

local function separators()
  return o.column {key='separators', gap=16,
    o.text {key='title', text='Separators', size=24},
    o.text {key='horizontal-label', text='Horizontal: fills the available width'},
    o.separator {key='horizontal'},
    o.box {key='vertical-region', width=400, height=80,
      o.row {key='columns', gap=20, cross_alignment='center',
        o.text {key='left', text='Left column'},
        o.separator {key='vertical', orientation='vertical'},
        o.text {key='right', text='Right column'},
      }},
    o.text {key='theme-label', text='Nested theme: blue border'},
    o.theme {key='nested', colors={border='#137ba9'},
      o.separator {key='themed', orientation='horizontal'}},
  }
end

local Choice = o.stateless(function(p, children, theme, context)
  local active = context.selection.enabled
  return o.box {key=p.key, option=p.value, label=p.label, width=p.width,
    height=p.height or 48, flex=p.flex, padding=12, radius=6, alignment='left',
    background=theme.colors.secondary,
    states={hover=theme.colors.accent_hover, selected=active and theme.colors.accent_selected or theme.colors.disabled},
    o.text {key='label', text=p.label, semantic=false,
      foreground=active and theme.colors.foreground or theme.colors.disabled_foreground}}
end)

local function selection_layout(disabled)
  local selected = o.signal(-7)
  return function()
    return o.column {key='layout', gap=16,
      o.text {key='title', text='Selection without stock layout', size=24},
      o.text {key='intrinsic-label', text='Intrinsic width · centered, unequal heights'},
      o.row {key='intrinsic', selection='radio_group', selected=selected(), enabled=not disabled,
        on_select=function(v) selected:set(v) end, main_axis_size='min', gap=12, cross_alignment='center',
        Choice {key='first', value=41, label='Compact', width=110},
        Choice {key='second', value=-7, label='Expanded', width=190, height=72}},
      o.text {key='flex-label', text='Available width · 1:3 flex children'},
      o.row {key='weighted', selection='radio_group', selected=selected(), enabled=not disabled,
        on_select=function(v) selected:set(v) end, main_axis_size='max', gap=12,
        Choice {key='first', value=41, label='One', flex=1},
        Choice {key='second', value=-7, label='Three', flex=3}},
      o.text {key='value', text='Selected value: '..selected()},
    }
  end
end

local function custom_dialog()
  local opened = o.signal(false)
  local function close() opened:set(false) end
  return function()
    return o.stack {key='root',
      o.column {key='page', gap=16,
        o.text {key='title', text='Workspace', size=24},
        o.button {key='open', label='Open details', on_press=function() opened:set(true) end},
        o.text {key='status', text=opened() and 'Details open' or 'Details closed'}},
      o.box {key='sheet', role='dialog', label='Workspace details', hidden=not opened(),
        width='fill', height='fill', alignment='right', background='#00000040', on_cancel=close,
        o.box {key='panel', semantic=false, width=300, height='fill', padding=20, surface='card',
          o.column {key='body', gap=20,
            o.box {key='stripe', height=4, width='fill', background='#137ba9', semantic=false},
            o.text {key='title', text='Workspace details', size=22},
            o.text {key='detail', text='Custom layout, native modality.'},
            o.text {key='hint', text='Tab stays here. Escape closes.'},
            o.button {key='close', label='Close details', on_press=close}}}}}
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
  o.story {id='separator/light', name='Separators', viewport={width=480,height=300}, snapshot_scale=2, content=separators},
  o.story {id='separator/dark', name='Separators (dark)', color_scheme='dark', viewport={width=480,height=300}, snapshot_scale=2, content=separators},
  o.story {id='selection-layout/light', name='Custom selection layout', viewport={width=560,height=340}, snapshot_scale=2, content=selection_layout(false)},
  o.story {id='selection-layout/dark', name='Custom selection layout (dark)', color_scheme='dark', viewport={width=560,height=340}, snapshot_scale=2, content=selection_layout(false)},
  o.story {id='selection-layout/disabled', name='Custom selection layout (disabled)', viewport={width=560,height=340}, snapshot_scale=2, content=selection_layout(true)},
  o.story {id='selection-layout/changed', name='Custom selection layout (changed)', viewport={width=560,height=340}, snapshot_scale=2, content=selection_layout(false),
    actions={{type='click',target='layout/intrinsic/first'}}},
  o.story {id='dialog-layout/light', name='Custom modal side sheet', viewport={width=560,height=340}, snapshot_scale=2, content=custom_dialog(),
    actions={{type='click',target='root/page/open'}}},
  o.story {id='dialog-layout/dark', name='Custom modal side sheet (dark)', color_scheme='dark', viewport={width=560,height=340}, snapshot_scale=2, content=custom_dialog(),
    actions={{type='click',target='root/page/open'}}},
  o.story {id='dialog-layout/closed', name='Custom modal side sheet (closed)', viewport={width=560,height=340}, snapshot_scale=2, content=custom_dialog(),
    actions={{type='click',target='root/page/open'}, {type='click',target='root/sheet/body/close'}}},
}}
