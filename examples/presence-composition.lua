-- Keep the presence declaration mounted; change present to request an exit.
local o = require('ouro')
local revision = 1
local reject = false
local invalid = nil
local shown, mounted, duration = o.signal(true), o.signal(true), o.signal(1600)
local hits, under = o.signal(0), o.signal(0)
local ground, blue, ink = '#e8eef4', '#389ac0', '#173b61'
local Card = o.stateful(function(p)
  local count = o.signal(0)
  return function()
    return o.box {key='card',width=220,height=100,radius=10,background=blue,
      opacity=p.value,transform={x=36*(1-p.value)},role='button',activate=true,
      label=string.format('Value %.6f count %d',p.value,count()),alignment='center',
      on_press=function() count:set(count()+1);hits:set(hits()+(revision==1 and 3 or 7)) end,
      o.text {key='text',text='Panel clicks '..count(),foreground='#ffffff'}}
  end
end)
local function content(peer)
  local present = peer or shown()
  if invalid ~= nil then present=invalid end
  return o.column {key='root',gap=20,
    o.text {key='title',text='Enter / exit · revision '..revision,size=26,foreground=ink},
    o.text {key='hint',text='Dismiss, then reopen mid-exit. The panel keeps its click count.'},
    o.row {key='gallery',gap=20,
      o.column {key='toast',gap=12,
        o.text {key='title',text='Dismissible toast',size=18,foreground=ink},
        o.box {key='viewport',width=280,height=150,background=ground,padding=16,alignment='left',
          (peer or mounted()) and o.presence {key='life',present=present,duration=peer and 0 or duration(),
            render=function(value)
              return o.box {key='toast',width=248,height=100,radius=10,background=ink,
                opacity=value,transform={y=20*(1-value)},padding=12,
                o.column {key='content',gap=8,
                  o.text {key='message',text='Changes saved',foreground='#ffffff'},
                  o.button {key='dismiss',label='Dismiss',on_press=function() shown:set(false) end}}}
            end} or nil}},
      o.column {key='panel',gap=12,
        o.text {key='title',text='Retained sliding panel',size=18,foreground=ink},
        o.box {key='viewport',width=280,height=150,background=ground,padding=16,clip=true,alignment='left',
          o.stack {key='layers',
            o.box {key='under',width=220,height=100,role='button',activate=true,label='Underlying target',
              on_press=function() under:set(under()+1) end},
            (peer or mounted()) and o.presence {key='life',present=present,duration=peer and 0 or duration(),
              render=function(value) return Card {key='state',value=value} end} or nil}}},
    },
    o.row {key='controls',gap=12,
      o.button {key='open',label='Show / reverse exit',on_press=function() shown:set(true) end},
      o.button {key='close',label='Dismiss both',on_press=function() shown:set(false) end}},
    o.text {key='status',text=peer and 'Independent peer' or 'Hits '..hits()..' · underlying '..under()},
  }
end
local function action(handler)
  return {description='Presence fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler();return {} end}
end
return o.app {id='dev.ourokit.presence-composition',actions={
  Open=action(function() shown:set(true) end), Close=action(function() shown:set(false) end),
  Remove=action(function() mounted:set(false) end), Mount=action(function() mounted:set(true) end),
  Instant=action(function() duration:set(0) end),
},run=function() return {windows={
  o.window {id='main',title='Presence transitions',width=640,height=400,content=function() return content(false) end},
  o.window {id='peer',title='Independent presence',width=640,height=400,content=function() return content(true) end},
  reject and o.window {id='rejected',width=100,height=80,content=function() error('reject later window') end} or nil,
}} end}
