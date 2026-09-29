-- Retained cards exercising Ouro's application-local drag and drop protocol.
local o = require('ouro')
local revision = 1
local reject = false
local order = o.signal({'amber','violet','teal'})
local handles = o.signal(true)
local drag_kind = o.signal('item')
local tab_order, selected = o.signal({1,2}), o.signal(1)
local drops, activations = 0, 0
local last = 'No drop yet'
local status = o.signal(last)
local invalid = nil

-- Deliberately shared with Lua. The native build must copy both strings.
local copied_drag = {kind='item', value='amber'}
local names = {amber='Field notes', violet='Launch copy', teal='Release checklist'}
local colors = {amber='#f3b562', violet='#9b8afb', teal='#52b9a8'}

local function move(value, before)
  local next = {}
  for _, id in ipairs(order()) do if id ~= value then next[#next+1] = id end end
  local result = {}
  for _, id in ipairs(next) do
    if id == before then result[#result+1] = value end
    result[#result+1] = id
  end
  if before == value then result = order() end
  order:set(result)
end

local function card(id, index)
  local payload = id == 'amber' and copied_drag or {kind=drag_kind(),value=id}
  return o.box {key=id,width=220,height=252,padding=16,radius=14,background='#f8fafc',
    o.column {key='body',gap=11,
      o.row {key='top',gap=10,
        o.box {key='swatch',width=14,height=36,radius=7,background=colors[id]},
        o.box {key='heading',width=106,
          o.column {key='labels',gap=2,
            o.text {key='name',text=names[id],size=17,weight='medium',foreground='#203247'},
            o.text {key='position',text='Position '..index,foreground='#66768a'}}},
        handles() and o.box {key='handle',width=48,height=38,radius=9,background='#c5d8ec',
          focusable=true,drag=invalid or payload,
          on_pointer={kinds={'press'},button=272,propagate=true,handler=function()
            activations = activations + 1
          end},
          o.text {key='grip',text='⋮⋮',size=20,foreground='#40566f'}} or nil},
      o.text_input {key='editor',default_text='Retained draft',placeholder='Card notes'},
      -- A large, child-free semantic center gives deterministic development input.
      o.box {key='dropzone',width=188,height=66,radius=10,background='#edf2f7',focusable=true,
        drop={kind='item',on_drop=function(value,x,y)
          drops = drops + (revision == 1 and 1 or 10)
          last = string.format('%s → %s at %.1f, %.1f (r%d)',value,id,x,y,revision)
          move(value,id)
          status:set(last..' · score '..drops)
        end}},
    }}
end

local function content()
  local cards = {}
  for index,id in ipairs(order()) do cards[#cards+1] = card(id,index) end
  local tabs = {}
  for _, value in ipairs(tab_order()) do
    tabs[#tabs+1] = {value=value,label=value==1 and 'Draft' or 'Review',
      drag={kind='document-tab',value=tostring(value)},
      drop={kind='document-tab',on_drop=function(source)
        local moving = tonumber(source)
        if moving ~= value then tab_order:set({moving,value}) end
      end},
      content=o.text_input {key='editor',default_text='Tab '..value..' retained notes'}}
  end
  return o.column {key='root',gap=16,
    o.text {key='title',text='Arrange the publishing board',size=27,weight='medium',foreground='#203247'},
    o.text {key='intro',text='Drag a dotted handle onto a card’s open landing area. Notes and focus stay with stable cards.',foreground='#66768a'},
    o.row {key='cards',gap=14,table.unpack(cards)},
    o.row {key='targets',gap=12,
      o.box {key='compatible',width=330,height=54,padding=14,radius=10,background='#e5f4ef',focusable=true,
        drop={kind='item',on_drop=function(value,x,y)
          drops=drops+(revision==1 and 1 or 10); last=string.format('%s → archive at %.1f, %.1f (r%d)',value,x,y,revision)
          status:set(last..' · score '..drops)
        end},o.text {key='label',text='Compatible target · item',foreground='#245d50'}},
      o.box {key='wrong-kind',width=330,height=54,padding=14,radius=10,background='#f7e9ec',focusable=true,
        drop={kind='other',on_drop=function() error('wrong-kind drop ran') end},
        o.text {key='label',text='Incompatible target · other',foreground='#875264'}}},
    o.text {key='status',text=status(),foreground='#40566f'},
    o.box {key='tab-area',height=110,width='fill',
      o.tabs {key='documents',label='Reorderable documents',selected=selected(),
        on_select=function(value) selected:set(value) end,tabs=tabs}},
  }
end

local function action(handler)
  return {description='Drag fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() return handler() or {} end}
end
return o.app {id='dev.ourokit.drag-composition',actions={
  Inspect=action(function() return {order=table.concat(order(),','),drops=drops,activations=activations,last=last,
    tab_order=table.concat(tab_order(),','),selected=selected()} end),
  MutateSource=action(function() copied_drag.kind='other'; copied_drag.value='MUTATED' end),
  ChangeConfig=action(function() drag_kind:set(drag_kind() == 'item' and 'other' or 'item') end),
  RemoveHandles=action(function() handles:set(false) end),
  RestoreHandles=action(function() handles:set(true) end),
},run=function() return {windows={
  o.window {id='main',title='Drag composition',width=760,height=680,content=content},
  reject and o.window {id='rejected',width=100,height=80,
    content=function() error('reject after preparing drag window') end} or nil,
}} end}
