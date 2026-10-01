-- Native tooltip surfaces can extend outside this 36px layer-shell bar.
local o = require('ouro')
local visible, enabled, reduced = o.signal(true), o.signal(true), o.signal(false)
local selected = o.signal(1)
local errors = 0
local last_error
local function failure(err) errors=errors+1; last_error=err.name; error(err.message) end
local function bar()
  return o.theme {key='theme', color_scheme='dark', reduced_motion=reduced(),
    o.box {key='bar', width='fill', height='fill', padding_x=12, background='#181b25',
      o.row {key='items', gap=16, cross_alignment='center',
        o.text {key='brand', text='OUROKIT', size=13, weight='medium'},
        o.box {key='network-slot', children=visible() and {o.tooltip {key='network', text='Connected to the studio network', width=260,
          enabled=enabled(), on_error=failure,
          o.button {key='button', label='Network', height=28, variant='ghost'}}} or {}},
        o.tooltip {key='select', text='Choose an audio output', width=210, on_error=failure,
          o.select {key='output', label='Audio output', width=160, selected=selected(),
            on_select=function(v) selected:set(v) end, on_error=failure,
            options={{value=1,label='Speakers'}, {value=2,label='Headphones'}}}},
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
  Stats={description='Tooltip diagnostics', inputSchema={type='object'}, outputSchema={type='object'},
    handler=function() return {errors=errors, last_error=last_error, selected=selected()} end},
}, run=function() return {windows={
  o.layer_surface {id='bar', namespace='ourokit-tooltips', layer='top', width=0, height=36,
    anchors={'top','left','right'}, exclusive_zone=36, keyboard_interactivity='none', content=bar},
}} end}
