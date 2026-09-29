-- One native paragraph with styled, interactive spans.
local o = require('ouro')
local revision = 1
local reject = false
local invalid = nil
local compact = o.signal(false)
local restyled = o.signal(false)
local hits = o.signal(0)

local copied_spans = {
  {text='Native rich text keeps ',foreground='#26384a'},
  {text='one paragraph',size=22,weight='medium',foreground='#a23b72'},
  {text=' while links wrap with the surrounding words. ',foreground='#26384a'},
  {key='guide',text='Read the composition guide',weight='medium',foreground='#126b8c',
    on_press=function() hits:set(hits() + (revision == 1 and 3 or 7)) end},
  {text=' — ثم يعود النص من اليمين إلى اليسار بأمان.',foreground='#26384a'},
}

local function story(peer)
  local spans = invalid or copied_spans
  return o.column {key='root',gap=14,
    o.text {key='title',text=peer and 'Independent rich text' or 'Rich text, composed naturally',
      size=26,weight='medium',foreground='#19324a'},
    o.text {key='intro',text='A single paragraph can mix emphasis, color, direction and accessible links.',
      foreground='#526579'},
    o.box {key='card',width=not peer and compact() and 330 or 500,padding=20,radius=12,background='#f1f5f8',
      o.text {key='story',size=17,foreground='#26384a',max_lines=6,overflow='ellipsis',
        alignment='start',spans=spans}},
    o.text {key='links',size=17,spans={
      {text='Try the '},
      {key='normal',text='enabled link',weight='medium',foreground=not peer and restyled() and '#a23b72' or '#126b8c',
        on_press=function() hits:set(hits() + (revision == 1 and 3 or 7)) end},
      {text=' or compare the '},
      {key='disabled',text='disabled link',foreground='#7b8793',enabled=false,
        on_press=function() hits:set(hits() + 1000) end},
      {text='.'},
    }},
    o.text {key='status',text=peer and 'Peer revision '..revision or 'Activations '..hits(),
      foreground='#526579'},
    o.row {key='controls',gap=10,
      o.button {key='width',label='Toggle paragraph width',on_press=function() compact:set(not compact()) end},
      o.button {key='style',label='Change link color',on_press=function() restyled:set(not restyled()) end}},
  }
end
local function action(handler)
  return {description='Rich-text fixture control',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() handler(); return {} end}
end
return o.app {id='dev.ourokit.rich-text-composition',actions={
  Compact=action(function() compact:set(true) end),
  Wide=action(function() compact:set(false) end),
  Restyle=action(function() restyled:set(not restyled()) end),
  MutateSource=action(function()
    copied_spans[1].text='MUTATED'; copied_spans[2].foreground='#ff0000'
    copied_spans[4].on_press=function() hits:set(9999) end
  end),
  RestoreSource=action(function()
    copied_spans[1].text='Native rich text keeps '; copied_spans[2].foreground='#a23b72'
    copied_spans[4].on_press=function() hits:set(hits() + (revision == 1 and 3 or 7)) end
  end),
},run=function() return {windows={
  o.window {id='main',title='Rich text composition',width=570,height=400,
    content=function() return story(false) end},
  o.window {id='peer',title='Peer rich text',width=570,height=400,
    content=function() return story(true) end},
  reject and o.window {id='rejected',width=100,height=80,
    content=function() error('reject after preparing rich text windows') end} or nil,
}} end}
