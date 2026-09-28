-- In-window overlays: Lua owns visibility and dismissal; Zig owns geometry.
local o = require('ouro')
local revision = 1
local reject = false
local opened, nested, modal, narrow = o.signal(false), o.signal(false), o.signal(false), o.signal(false)
local trigger_request, nested_request = o.signal(0), o.signal(0)
local ignored = false
local count, nested_count, outside, underneath = revision == 1 and 3 or 19, 0, 0, 0
local increment = revision == 1 and 5 or 11
local function close()
  opened:set(false); nested:set(false)
  nested_request:set(0)
  if not modal() then trigger_request:set(trigger_request()+1) end
end
local function close_nested()
  nested:set(false); nested_request:set(nested_request()+1)
end
local function popup()
  return o.box {key='panel', role=modal() and 'dialog' or 'group', label='Overlay panel',
    width=220, height=148, padding=9, background='#dcebea', border='#37656f', border_width=1,
    on_cancel=close,
    on_key={keys={'Escape'}, states={'pressed'}, propagate=false, handler=close},
    on_pointer_down_outside={button=272, propagate=false, handler=function(event)
      assert(event.kind=='press' and event.phase=='capture' and event.serial==nil)
      outside=outside+1
      if not ignored then close() end
    end},
    o.column {key='content', gap=9,
      o.text {key='title', text='Floated outside the scroll clip'},
      o.button {key='inside', label='Add '..increment, on_press=function() count=count+increment end},
      o.anchored {key='nested', side='right', gap=5,
        o.button {key='trigger', label='Nested overlay', focus_request=nested_request(),
          on_press=function() nested:set(not nested()) end},
        nested() and o.box {key='panel', width=138, height=58, padding=9, background='#f5dfbd',
          on_key={keys={'Escape'}, states={'pressed'}, propagate=false, handler=close_nested},
          on_pointer_down_outside={button=272, propagate=false, handler=close_nested},
          o.button {key='action',label='Nested +7',on_press=function() nested_count=nested_count+7 end}} or nil,
      },
    }}
end
local function content()
  return o.column {key='root',gap=14,
    o.text {key='title',text='Anchored overlays · revision '..revision,size=20},
    o.row {key='row',gap=narrow() and 16 or 200,
      o.box {key='frame',width=140,height=84,background='#e7eaf0',
        o.scroll {key='scroll',
          o.column {key='body',gap=0,
            o.box {key='spacer',height=24},
            o.anchored {key='overlay',side='right',alignment='start',gap=7,margin=9,
              o.button {key='trigger',label='Open overlay',width=112,focus_request=trigger_request(),
                on_press=function() opened:set(not opened()) end},
              opened() and popup() or nil},
            o.box {key='tail',height=160},
          }}},
      o.button {key='outside',label='Underlying',on_press=function() underneath=underneath+1 end},
    },
    o.text {key='hint',text='Overlay paint and input escape the grey scroll viewport.'},
    o.text {key='policy',text='Outside press / Escape close; nested overlays close first.'},
  }
end
local function action(handler)
  return {description='Overlay fixture control',inputSchema={type='object'},outputSchema={type='object'},handler=handler}
end
return o.app {id='dev.ourokit.overlay-composition',actions={
  Inspect={description='Read overlay fixture state',inputSchema={type='object'},
    outputSchema={type='object',properties={count={type='integer'},nested_count={type='integer'},outside={type='integer'},
      underneath={type='integer'},opened={type='boolean'},nested={type='boolean'}},
      required={'count','nested_count','outside','underneath','opened','nested'}},
    handler=function() return {count=count,nested_count=nested_count,outside=outside,underneath=underneath,opened=opened(),nested=nested()} end},
  Ignore=action(function() ignored=true; return {} end),
  Accept=action(function() ignored=false; return {} end),
  Modal=action(function() modal:set(true); return {} end),
  Narrow=action(function() narrow:set(true); return {} end),
  Open=action(function() opened:set(true); return {} end),
},run=function()
  local windows={o.window {id='main',title='Anchored overlay composition',width=narrow() and 340 or 540,height=390,content=content}}
  if reject then windows[#windows+1]=o.window {id='rejected',width=100,height=80,
    content=function() error('reject later window') end} end
  return {windows=windows}
end}
