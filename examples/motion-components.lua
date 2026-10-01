-- Run with: ouroctl run examples/motion-components.lua
local o = require('ouro')
local synced, saved = o.signal(false), o.signal(false)
local details, selected = o.signal(false), o.signal(nil)
local reduced, dark = o.signal(false), o.signal(false)
local duration = 240

local Card = o.stateless(function(p, children, theme)
  return o.box {key=p.key, flex=p.flex, padding=12, radius=12,
    background=theme.colors.card, border=theme.colors.border, border_width=1,
    o.column {key='body', gap=10, cross_alignment='stretch', children=children}}
end)
local Caption = o.stateless(function(p, _, theme)
  return o.text {key=p.key, text=p.text, size=13, foreground=theme.colors.muted_foreground}
end)
local function setting(key, title, description, control)
  return o.row {key=key, gap=12, cross_alignment='center',
    o.column {key='label', flex=1, gap=4,
      o.text {key='title', text=title, weight='medium'},
      Caption {key='description', text=description}}, control}
end
local function scene()
  return o.theme {key='policy', color_scheme=dark() and 'dark' or 'light', reduced_motion=reduced(),
    o.box {key='page', width='fill', height='fill', surface='background', padding=8,
      o.column {key='root', gap=16, cross_alignment='stretch',
        o.column {key='intro', gap=6,
          o.text {key='eyebrow', text='OUROKIT / COMPONENTS', size=12, weight='medium'},
          o.text {key='title', text='A little motion. A lot less work.', size=28, weight='medium'},
          Caption {key='subtitle', text='Native controls, composed in Lua. Interruptible by default.'}},
        o.row {key='toolbar', gap=8, cross_alignment='center',
          o.button {key='motion', label=reduced() and 'Reduced motion: on' or 'Reduced motion: off',
            variant='soft', tone='neutral', on_press=function() reduced:set(not reduced()) end},
          o.button {key='theme', label=dark() and 'Light theme' or 'Dark theme',
            variant='ghost', tone='neutral', on_press=function() dark:set(not dark()) end},
          o.box {key='spacer', flex=1},
          Caption {key='timing', text='240 ms · ease-out'}},
        o.row {key='columns', gap=20,
          o.column {key='left', flex=1, gap=16, cross_alignment='stretch',
            Card {key='toggles',
              o.text {key='title', text='Preferences', size=18, weight='medium'},
              setting('sync', 'Keep in sync', 'A sliding thumb, stable layout.',
                o.switch {key='control', label='Keep in sync', checked=synced(), duration=duration,
                  on_change=function(v) synced:set(v) end}),
              o.separator {key='separator'},
              setting('save', 'Save a local copy', 'A checkmark with a soft arrival.',
                o.checkbox {key='control', label='Save a local copy', checked=saved(), duration=duration,
                  on_change=function(v) saved:set(v) end}),
              o.separator {key='separator-disabled'},
              setting('disabled', 'Managed by your team', 'Disabled controls stay out of focus.',
                o.switch {key='control', label='Managed by your team', checked=true, enabled=false})},
            Card {key='disclosure',
              o.text {key='title', text='Collapsible', size=18, weight='medium'},
              o.collapsible {key='details', label='Advanced preferences', expanded=details(), duration=duration,
                on_change=function(v) details:set(v) end,
                o.column {key='settings', gap=12, cross_alignment='stretch',
                  Caption {key='description', text='Content keeps its natural height while the panel reveals it.'},
                  o.text_input {key='name', label='Workspace name', default_text='My workspace', width=240},
                  Caption {key='hint', text='Reverse before closing finishes to keep this draft.'}}}},
          },
          Card {key='accordion', flex=1,
            o.text {key='title', text='Good defaults, built in', size=18, weight='medium'},
            Caption {key='subtitle', text='One section open at a time.'},
            o.accordion {key='faq', expanded=selected(), duration=duration,
              on_change=function(v) selected:set(v) end, items={
                {key='motion', label='Motion that respects you', content=o.column {key='body', gap=10,
                  Caption {key='text', text='System reduced motion is inherited automatically. No timers or preference checks in application code.'},
                  o.button {key='reduce', label='Try reduced motion', variant='soft',
                    on_press=function() reduced:set(true) end}}},
                {key='keyboard', label='Keyboard comes first', content=o.column {key='body', gap=10,
                  Caption {key='text', text='Tab to a heading. Enter or Space opens it. Exiting content immediately stops receiving input.'},
                  o.button {key='action', label='A focusable action', variant='soft', tone='neutral'}}},
                {key='identity', label='Change your mind mid-flight', content=
                  Caption {key='text', text='Reverse an opening or closing animation without a jump. Native identity survives until the exit finishes.'}},
                {key='later', label='More settings (unavailable)', enabled=false, content=o.text {key='text', text='Not available'}},
              }},
          },
        },
        Caption {key='footer', text=reduced() and 'REDUCED MOTION · Immediate state changes. No animation wakeups.'
          or 'FULL MOTION · Try rapid toggles, keyboard navigation, and reversing a disclosure.'},
      }}}
end
local function action(callback)
  return {description='Motion showcase control', inputSchema={type='object'}, outputSchema={type='object'},
    handler=function() callback(); return {} end}
end
return o.app {id='dev.ourokit.motion-components', actions={
  On=action(function() synced:set(true); saved:set(true) end),
  Off=action(function() synced:set(false); saved:set(false) end),
  Open=action(function() details:set(true) end), Close=action(function() details:set(false) end),
  First=action(function() selected:set('motion') end), Second=action(function() selected:set('keyboard') end),
  Third=action(function() selected:set('identity') end), Collapse=action(function() selected:set(nil) end),
  Reduce=action(function() reduced:set(true) end), Full=action(function() reduced:set(false) end),
  Dark=action(function() dark:set(true) end), Light=action(function() dark:set(false) end),
}, run=function() return {windows={
  o.window {id='main', title='Ourokit · Motion components', width=840, height=680, content=scene},
}} end}
