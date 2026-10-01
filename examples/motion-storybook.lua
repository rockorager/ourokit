local o = require('ouro')
local function content(options)
  local checked, expanded = o.signal(options.checked or false), o.signal(options.expanded or false)
  return function()
    return o.theme {key='policy', reduced_motion=true,
      o.column {key='root', gap=16, cross_alignment='stretch',
        o.text {key='title', text='Motion components', size=24},
        o.row {key='toggles', gap=16, cross_alignment='center',
          o.switch {key='switch', label='Sync', checked=checked(), enabled=not options.disabled,
            on_change=function(v) checked:set(v) end},
          o.checkbox {key='check', label='Save', checked=checked(), enabled=not options.disabled,
            on_change=function(v) checked:set(v) end},
          o.text {key='label', text=options.disabled and 'Disabled' or 'Sync and save'}},
        o.collapsible {key='details', label='Workspace details', expanded=expanded(), enabled=not options.disabled,
          on_change=function(v) expanded:set(v) end,
          o.column {key='body', gap=12,
            o.text {key='description', text='Natural-height content. No fixed panel size.'},
            o.text_input {key='name', label='Workspace name', default_text='My workspace', width=240}}},
        o.text {key='footer', text='Tab, then Enter or Space to toggle.'},
      }}
  end
end
return o.storybook {stories={
  o.story {id='motion/closed', name='Closed', viewport={width=400,height=330}, snapshot_scale=2, content=content({})},
  o.story {id='motion/open', name='Open and checked', viewport={width=400,height=330}, snapshot_scale=2, content=content({checked=true,expanded=true})},
  o.story {id='motion/dark', name='Dark', color_scheme='dark', viewport={width=400,height=330}, snapshot_scale=2, content=content({checked=true,expanded=true})},
  o.story {id='motion/disabled', name='Disabled', viewport={width=400,height=330}, snapshot_scale=2, content=content({checked=true,disabled=true})},
  o.story {id='motion/focus', name='Keyboard focus', viewport={width=400,height=330}, snapshot_scale=2, content=content({}),
    actions={{type='tab',target='policy/root/toggles/switch'},
      {type='tab',target='policy/root/toggles/check'}, {type='tab',target='policy/root/details/trigger'}}},
  o.story {id='motion/activated', name='Activated disclosure', viewport={width=400,height=330}, snapshot_scale=2, content=content({}),
    actions={{type='click',target='policy/root/details/trigger'}}},
}}
