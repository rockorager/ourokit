local o = require('ouro')
local reduced, slow, mounted = o.signal(false), o.signal(false), o.signal(true)
local selected, timeout = o.signal(1), o.signal(0)
local shown = {o.signal(false), o.signal(false), o.signal(false)}
local dismissals, last_reason, menu_hits = 0, '', 0
local messages = {'Changes saved to your workspace', 'Build finished — ready to preview', 'Your settings are up to date'}
local function show_all()
  mounted:set(true)
  for _, value in ipairs(shown) do value:set(true) end
end
local function action(handler)
  return {description='Motion example control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end
return o.app {id='dev.ourokit.menus-and-toasts',actions={
  Show=action(show_all), HideFirst=action(function() shown[1]:set(false) end),
  ShowFirst=action(function() shown[1]:set(true) end),
  Hide=action(function() for _, value in ipairs(shown) do value:set(false) end end),
  Timed=action(function() timeout:set(1600); show_all() end),
  Sticky=action(function() timeout:set(0) end),
  Remove=action(function() mounted:set(false) end), Mount=action(function() mounted:set(true) end),
  Slow=action(function() slow:set(true) end), Normal=action(function() slow:set(false) end),
  Reduce=action(function() reduced:set(true) end), Full=action(function() reduced:set(false) end),
  Stats={description='Motion diagnostics',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() return {dismissals=dismissals,last_reason=last_reason,menu_hits=menu_hits,
      first=shown[1](),selected=selected()} end},
},run=function() return {windows={
  o.window {id='main',title='Menus & toasts',width=780,height=480,content=function()
    local cards={}
    for i=1,3 do
      cards[i]=o.toast {key='toast-'..i,present=shown[i](),message=messages[i],timeout=timeout(),
        duration=slow() and 1200 or 180,
        on_dismiss=function(reason)
          dismissals=dismissals+1; last_reason=reason; shown[i]:set(false)
        end}
    end
    return o.theme {key='policy',color_scheme='dark',reduced_motion=reduced(),
      o.box {key='page',width='fill',height='fill',padding=24,
        o.column {key='content',gap=16,cross_alignment='stretch',
          o.text {key='title',text='Menus & toasts',size=28,weight='medium'},
          o.text {key='hint',text='Small transitions. No motion when you prefer less.',size=14},
          o.separator {key='line'},
          o.row {key='columns',gap=24,cross_alignment='start',
            o.column {key='controls',width=260,gap=14,cross_alignment='stretch',
              o.text {key='menu-title',text='Native popups',size=17,weight='medium'},
              o.menu_button {key='menu',label='Workspace actions',popup_width=260,popup_height=112,
                duration=slow() and 1200 or 120,items={
                  {key='save',label='Save workspace',on_press=function() menu_hits=menu_hits+1; shown[1]:set(true) end},
                  {key='build',label='Build project',on_press=function() menu_hits=menu_hits+1; shown[2]:set(true) end},
                  {key='settings',label='Apply settings',on_press=function() menu_hits=menu_hits+1; shown[3]:set(true) end}}},
              o.select {key='select',label='Audio output',width=260,selected=selected(),
                duration=slow() and 1200 or 120,on_select=function(v) selected:set(v) end,
                options={{value=1,label='Speakers'},{value=2,label='Headphones'},{value=3,label='HDMI'}}},
              o.separator {key='rule'},
              o.button {key='show',label='Show three notifications',on_press=function() timeout:set(0); show_all() end},
              o.button {key='timed',label='Try auto-dismiss',variant='soft',
                on_press=function() timeout:set(5000); show_all() end},
              o.row {key='motion',gap=10,cross_alignment='center',
                o.switch {key='reduce',label='Reduced motion',checked=reduced(),on_change=function(v) reduced:set(v) end},
                o.text {key='label',text='Reduced motion'}},
            },
            o.column {key='notifications',flex=1,gap=12,cross_alignment='stretch',
              o.text {key='title',text='Application notifications',size=17,weight='medium'},
              o.text {key='hint',text='Hover or focus to pause the timeout.',size=13},
              o.column {key='stack',gap=0,cross_alignment='stretch',children=mounted() and cards or {}},
            }}}}}
  end},
}} end}
