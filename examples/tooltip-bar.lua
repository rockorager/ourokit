-- Native tooltip surfaces can extend outside this 36px layer-shell bar.
local o = require('ouro')
local visible, enabled, reduced = o.signal(true), o.signal(true), o.signal(false)
local selected = o.signal(1)
local shifted = o.signal(false)
local volume_open, volume_visible, volume = o.signal(false), o.signal(true), o.signal(0.37)
local volume_interactive = o.signal(true)
local volume_active, volume_closes = false, 0
local errors = 0
local last_error
local function failure(err) errors=errors+1; last_error=err.name; error(err.message) end
local function bar()
  return o.theme {key='theme', color_scheme='dark', reduced_motion=reduced(),
    o.box {key='bar', width='fill', height='fill', padding_x=12, background='#181b25',
      o.row {key='items', gap=16, cross_alignment='center',
        o.text {key='brand', text=shifted() and 'OUROKIT AUDIO' or 'OUROKIT', size=13, weight='medium'},
        o.box {key='network-slot', children=visible() and {o.tooltip {key='network', text='Connected to the studio network', width=260,
          enabled=enabled(), on_error=failure,
          o.button {key='button', label='Network', height=28, variant='ghost'}}} or {}},
        o.tooltip {key='select', text='Choose an audio output', width=210, on_error=failure,
          o.select {key='output', label='Audio output', width=160, selected=selected(),
            on_select=function(v) selected:set(v) end, on_error=failure,
            options={{value=1,label='Speakers'}, {value=2,label='Headphones'}}}},
        o.box {key='volume-slot', children=volume_visible() and {o.popover {key='volume',
          open=volume_open(), width=260, height=100, gap=6, on_error=failure,
          interactive=volume_interactive(),
          on_interaction_change=function(active) volume_active=active end,
          on_close=function() volume_closes=volume_closes+1 end,
          content=function()
            return o.box {key='body', width='fill', height='fill', padding=16, radius=8,
              background='#242732', o.column {key='controls', gap=12,
                o.text {key='label', text='Studio speakers — '..math.floor(volume()*100+0.5)..'%', foreground='#ffffff'},
                volume_interactive() and o.slider {key='slider', label='Volume', width=228, value=volume(), min=0, max=1, step=0.01,
                  on_change=function(value) volume:set(value) end} or
                  o.box {key='level', width=228, height=8, background='#666666', radius=4,
                    o.box {key='fill', width=228*volume(), height=8, radius=4, background='#74a7ff'}}}}
          end,
          o.button {key='button', label='Volume', height=28, variant='ghost'}}} or {}},
        o.box {key='spacer', flex=1},
        o.tooltip {key='clock', text='Thursday, October 1', side='top', width=200, on_error=failure,
          o.button {key='button', label='09:41', height=28, variant='ghost'}},
        o.tooltip {key='edge', text='Placed inside the screen, outside the bar', side='right', width=300, on_error=failure,
          o.button {key='button', label='Status', height=28, variant='ghost'}},
      }}}
end
local function action(handler)
  return {description='Tooltip example control', inputSchema={type='object'}, outputSchema={type='object'},
    handler=function() handler(); return {} end}
end
return o.app {id='dev.ourokit.tooltip-bar', actions={
  Hide=action(function() visible:set(false) end), Show=action(function() visible:set(true) end),
  Disable=action(function() enabled:set(false) end), Enable=action(function() enabled:set(true) end),
  Reduce=action(function() reduced:set(true) end), Full=action(function() reduced:set(false) end),
  MoveTip=action(function() shifted:set(not shifted()) end),
  OpenVolume=action(function() volume_open:set(true) end), CloseVolume=action(function() volume_open:set(false) end),
  SetVolume=action(function() volume:set(.63) end), HideVolume=action(function() volume_visible:set(false) end),
  ShowVolume=action(function() volume_visible:set(true) end),
  PassiveVolume=action(function() volume_interactive:set(false) end),
  Stats={description='Tooltip diagnostics', inputSchema={type='object'}, outputSchema={type='object'},
    handler=function() return {errors=errors, last_error=last_error, selected=selected(),
      volume=volume(), volume_active=volume_active, volume_closes=volume_closes} end},
}, run=function() return {windows={
  o.layer_surface {id='bar', namespace='ourokit-tooltips', layer='top', width=0, height=36,
    anchors={'top','left','right'}, exclusive_zone=36, keyboard_interactivity='none', content=bar},
}} end}
