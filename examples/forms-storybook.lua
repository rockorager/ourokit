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

local Level = o.stateless(function(p, children, theme)
  local c = theme.colors
  local before = math.floor((p.value+2.25)/5.25*65535+0.5)
  return o.box {key=p.key, label='Custom level', enabled=not p.disabled,
    range={value=p.value,min=-2.25,max=3,step=0.5,inset=22}, on_change=p.on_change,
    width=400,height=44,padding=8,border_width=2,border=c.border,radius=6,
    background=c.secondary,states={focus=c.ring},alignment='center',
    o.stack {key='layers',semantic=false,
      o.box {key='track-frame',semantic=false,width='fill',height=24,alignment='center',
        o.box {key='track',semantic=false,width='fill',height=8,background=c.switch_track}},
      o.row {key='rail',semantic=false,main_axis_size='max',gap=0,
        o.box {key='before',semantic=false,width=0,flex=before>0 and before or nil},
        o.box {key='thumb',semantic=false,width=24,height=24,radius=4,
          background=c.primary,states={disabled=c.disabled}},
        o.box {key='after',semantic=false,width=0,flex=before<65535 and 65535-before or nil}}}}
end)

local function custom_range(disabled)
  local value = o.signal(-1.25)
  local function change(v) value:set(v) end
  return function()
    return o.column {key='ranges',gap=16,
      o.text {key='title',text='Custom range geometry',size=24},
      Level {key='wide',value=value(),disabled=disabled,on_change=change},
      o.text {key='narrow-label',text='Same recipe constrained to 180 pixels'},
      o.box {key='narrow',width=180,Level {key='control',value=value(),disabled=disabled,on_change=change}},
      o.text {key='value',text='Value: '..value()},
      o.text {key='stock-label',text='Stock slider endpoints'},
      o.row {key='endpoints',gap=16,
        o.slider {key='min',label='Minimum',width=180,value=-2.25,min=-2.25,max=3,step=0.5,enabled=not disabled},
        o.slider {key='max',label='Maximum',width=180,value=3,min=-2.25,max=3,step=0.5,enabled=not disabled}}}
  end
end

local SplitGrip = o.stateless(function(p, children, theme)
  local c = theme.colors
  local horizontal = p.axis == 'horizontal'
  return o.box {key=p.key,semantic=false,width='fill',height='fill',alignment='center',
    background=c.secondary,states={hover=c.accent,pressed=c.accent_selected,focus=c.ring},
    o.box {key='grip',semantic=false,width=horizontal and 4 or 44,height=horizontal and 44 or 4,
      radius=2,background=c.muted_foreground,states={hover=c.primary,pressed=c.primary}}}
end)

local function split_view(axis, custom)
  local position = o.signal(0.25)
  return function()
    local panes = {key='panes',axis=axis,position=position(),min_first=40,min_second=70,
      on_change=function(v) position:set(v) end,
      o.box {key='first',surface='sidebar',padding=12,o.text {key='title',text='First pane'}},
      o.box {key='second',surface='card',padding=12,o.text {key='title',text='Second pane'}}}
    if custom then
      panes.divider_size=24
      panes[3]=SplitGrip {key='chrome',axis=axis}
      return o.split(panes)
    end
    return o.split_view(panes)
  end
end

local EditorLayout = o.stateless(function(p, children, theme)
  local c, active = theme.colors, not p.disabled
  local fg = active and c.foreground or c.disabled_foreground
  return o.column {key=p.key,gap=14,
    o.text {key='title',text='Native editing, Lua chrome',size=24},
    o.text {key='bare-label',text='Unstyled editor · intrinsic height'},
    o.text_editor {key='bare',default_text='No field background, border, or padding',enabled=active,foreground=fg},
    o.box {key='search-frame',surface='sidebar',padding=12,radius=12,
      o.row {key='search',gap=12,cross_alignment='center',
        o.text {key='label',text='Find'},
        o.text_editor {key='query',text=p.query,placeholder='Search this workspace',flex=1,height=36,
          padding_x=9,alignment='left',radius=6,background=c.surface,foreground=fg,
          border_width=1,border=c.input,focus=c.ring,enabled=active,on_change=p.on_change},
        o.button {key='clear',label='Clear',variant='ghost',tone='neutral',enabled=active,
          on_press=function() p.on_change('') end}}},
    o.text {key='notes-label',text='Multiline · custom viewport and selection colors'},
    o.text_editor {key='notes',default_text='First line: aéZ\nSecond line: editable notes',multiline=true,
      height=110,padding_x=16,padding_y=11,background=c.secondary,foreground=fg,
      border_width=2,border=c.input,focus=c.ring,radius=10,enabled=active,
      selection_color=c.accent_selected,caret_color=c.primary},
    o.text {key='stock-label',text='Stock Lua recipe'},
    o.text_input {key='stock',default_text='',placeholder='Standard input',enabled=active}}
end)

local function editor_layout(disabled)
  local query = o.signal('aéZ workspace')
  return function()
    return EditorLayout {key='editors',query=query(),disabled=disabled,on_change=function(v) query:set(v) end}
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
  o.story {id='range-layout/light', name='Custom ranges', viewport={width=460,height=360}, snapshot_scale=2, content=custom_range(false)},
  o.story {id='range-layout/dark', name='Custom ranges (dark)', color_scheme='dark', viewport={width=460,height=360}, snapshot_scale=2, content=custom_range(false)},
  o.story {id='range-layout/disabled', name='Custom ranges (disabled)', viewport={width=460,height=360}, snapshot_scale=2, content=custom_range(true)},
  o.story {id='range-layout/focus', name='Custom ranges (keyboard focus)', viewport={width=460,height=360}, snapshot_scale=2, content=custom_range(false),
    actions={{type='tab',target='ranges/wide'}}},
  o.story {id='range-layout/changed', name='Custom ranges (changed)', viewport={width=460,height=360}, snapshot_scale=2, content=custom_range(false),
    actions={{type='click',target='ranges/narrow/control'}}},
  o.story {id='split/horizontal', name='Horizontal split', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal')},
  o.story {id='split/vertical', name='Vertical split', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('vertical')},
  o.story {id='split/dark', name='Split (dark)', color_scheme='dark', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal')},
  o.story {id='split/hover', name='Split (hover)', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal'),
    actions={{type='hover',target='panes/divider'}}},
  o.story {id='split/pressed', name='Split (pressed)', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal'),
    actions={{type='pointer_down',target='panes/divider'}}},
  o.story {id='split/focus', name='Split (keyboard focus)', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal'),
    actions={{type='tab',target='panes/divider'}}},
  o.story {id='split-custom/horizontal', name='Custom horizontal divider', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal',true)},
  o.story {id='split-custom/vertical', name='Custom vertical divider', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('vertical',true)},
  o.story {id='split-custom/dark', name='Custom divider (dark)', color_scheme='dark', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal',true)},
  o.story {id='split-custom/hover', name='Custom divider (hover)', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal',true),
    actions={{type='hover',target='panes/divider'}}},
  o.story {id='split-custom/pressed', name='Custom divider (pressed)', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal',true),
    actions={{type='pointer_down',target='panes/divider'}}},
  o.story {id='split-custom/focus', name='Custom divider (keyboard focus)', viewport={width=440,height=260}, snapshot_scale=2, content=split_view('horizontal',true),
    actions={{type='tab',target='panes/divider'}}},
  o.story {id='editor-layout/light', name='Custom editor chrome', viewport={width=540,height=470}, snapshot_scale=2, content=editor_layout(false)},
  o.story {id='editor-layout/dark', name='Custom editor chrome (dark)', color_scheme='dark', viewport={width=540,height=470}, snapshot_scale=2, content=editor_layout(false)},
  o.story {id='editor-layout/disabled', name='Custom editor chrome (disabled)', viewport={width=540,height=470}, snapshot_scale=2, content=editor_layout(true)},
  o.story {id='editor-layout/focus', name='Custom editor chrome (focused)', viewport={width=540,height=470}, snapshot_scale=2, content=editor_layout(false),
    actions={{type='tab',target='editors/bare'}, {type='tab',target='editors/search-frame/search/query'}}},
  o.story {id='editor-layout/cleared', name='Custom editor chrome (cleared)', viewport={width=540,height=470}, snapshot_scale=2, content=editor_layout(false),
    actions={{type='click',target='editors/search-frame/search/clear'}}},
}}
