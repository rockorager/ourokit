-- Contextual commands and filtered input hooks; exercised by input_composition.py.
local o = require('ouro')
local revision = 1
local reject = false
local trace, pointer_trace = '', ''
local inner_saves, outer_saves, chords, delayed, activations, builds = 0, 0, 0, 0, 0, 0
local text = o.signal('abcd')
local function key_handler(tag)
  return function(event)
    assert(event.kind == 'key' and event.state == 'pressed')
    assert(event.text == nil and event.unicode == nil and event.serial == nil)
    assert(type(event.modifiers.control) == 'boolean')
    trace = trace .. tag .. ':' .. event.key .. ':' .. event.phase .. ';'
  end
end
local function pointer_handler(tag)
  return function(event)
    assert(event.kind == 'press' and event.button == 272)
    assert(type(event.x) == 'number' and type(event.y) == 'number')
    assert(event.serial == nil)
    pointer_trace = pointer_trace .. tag .. ':' .. event.phase .. ';'
  end
end
local root_commands = {
  save = function() outer_saves = outer_saves + (revision == 1 and 11 or 17) end,
  comment = function() chords = chords + (revision == 1 and 3 or 7) end,
  delayed = function() o.sleep(20); delayed = delayed + 1 end,
}
local inner_commands = {
  save = function() inner_saves = inner_saves + (revision == 1 and 5 or 13) end,
}
local root_capture, root_bubble = key_handler('root'), key_handler('root')
local inner_capture, inner_bubble = key_handler('inner'), key_handler('inner')
local leaf_bubble, blocked_capture = key_handler('leaf'), key_handler('blocked')
local pointer_capture, pointer_bubble = pointer_handler('outer'), pointer_handler('inner')

local function content()
  builds = builds + 1
  return o.box {key='root',
    commands=root_commands,
    shortcuts={['Ctrl+S']='save', ['Ctrl+K Ctrl+C']='comment', ['Ctrl+D']='delayed'},
    on_key_capture={keys={'F1','F2'}, states={'pressed'}, propagate=true, handler=root_capture},
    on_key={keys={'F1','F2'}, states={'pressed'}, propagate=true, handler=root_bubble},
    o.column {key='content', gap=12,
      o.text {key='revision', text='Input composition revision '..revision},
      o.box {key='inner', commands=inner_commands, shortcuts={['Ctrl+S']='save'},
        on_key_capture={keys={'F1'},states={'pressed'},propagate=true,handler=inner_capture},
        on_key={keys={'F1','Left'},states={'pressed'},propagate=false,handler=inner_bubble},
        o.grid {key='fields',columns={320},rows={38,'auto'},row_gap=8,
          o.box {key='leaf',column=1,row=1,focusable=true,width=300,height=38,background='#c1d3e5',
            on_key={keys={'F1'},states={'pressed'},propagate=true,handler=leaf_bubble},
            o.text {key='label',text='Inner keyboard target'}},
          o.text_input {key='editor',column=1,row=2,default_text='abcd',on_change=function(value) text:set(value) end},
        }},
      o.box {key='blocked',focusable=true,width=300,height=38,background='#d9c4aa',
        on_key_capture={keys={'F2'},states={'pressed'},propagate=false,handler=blocked_capture},
        o.text {key='label',text='Capture stops F2'}},
      o.button {key='outer',label='Outer keyboard target'},
      o.box {key='pointer',width=320,height=54,
        on_pointer_capture={kinds={'press'},button=272,propagate=true,handler=pointer_capture},
        o.box {key='sink',width=320,height=54,background='#e0bed6',
          on_pointer={kinds={'press'},button=272,propagate=false,handler=pointer_bubble},
          o.button {key='action',label='Consumed pointer / working keyboard',
            on_press=function() activations=activations+1 end}}},
      o.text {key='hint',text='Ctrl+S: scoped save · Ctrl+K Ctrl+C: chord'},
    }}
end
return o.app {id='dev.ourokit.input-composition', actions={
  Inspect={description='Read integration fixture state',inputSchema={type='object'},
    outputSchema={type='object',properties={trace={type='string'},pointer={type='string'},
      inner={type='integer'},outer={type='integer'},chords={type='integer'},
      delayed={type='integer'},activations={type='integer'},builds={type='integer'},text={type='string'}},
      required={'trace','pointer','inner','outer','chords','delayed','activations','builds','text'}},
    handler=function() return {trace=trace,pointer=pointer_trace,inner=inner_saves,outer=outer_saves,
      chords=chords,delayed=delayed,activations=activations,builds=builds,text=text()} end},
  ClearTrace={description='Clear fixture traces without rebuilding UI',inputSchema={type='object'},
    outputSchema={type='object'},handler=function() trace=''; pointer_trace=''; return {} end},
},run=function()
  local windows={o.window {id='main',title='Input composition',width=580,height=400,content=content}}
  if reject then windows[#windows+1]=o.window {id='rejected',width=120,height=80,
    content=function() error('reject later window') end} end
  return {windows=windows}
end}
