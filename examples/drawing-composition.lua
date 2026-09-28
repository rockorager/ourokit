-- Immutable recordings authored in Lua, shared by ordinary canvas leaves.
-- Run with --dev; tests/drawing_composition.py exercises pixels and reloads.
local o = require('ouro')
local revision = 1
local reject = false
local backdrop = revision == 1 and '#102030' or '#26394b'

local function recording(background)
  return {width=240, height=150, rectangles={
    {x=0, y=0, width=240, height=150, color=background},
    {x=19, y=17, width=103, height=67, color='#c05020'},
    {x=61, y=39, width=91, height=57, color='#20c08080'},
    {x=83, y=53, width=83, height=53, color='#4060e0a0'},
    {x=173, y=23, width=49, height=91, color='#e8b65a', corner_radius=16},
    {x=-9, y=120, width=43, height=17, color='#75ce9f'},
  }}
end

local source = recording(backdrop)
local shared = o.drawing(source)
assert(type(shared) == 'userdata')
assert(not pcall(function() shared.width = 1 end), 'drawings must be immutable')
assert(type(o.drawing {width=0, height=0, rectangles={}}) == 'userdata')
local selected = o.signal(shared)
local mutations, replacements = o.signal(0), o.signal(0)

local function mutate_source()
  -- Change every table layer after construction, then force a fresh scene.
  if source.rectangles[2] then
    source.rectangles[2].color = '#ff00ff'
    source.rectangles[2].x = 140
  end
  source.rectangles[3] = {x=0, y=0, width=240, height=150, color='#ffffff'}
  source.width, source.height = 7, 9
  source.rectangles = {}
  mutations:set(mutations()+1)
end

local function replace_main()
  selected:set(o.drawing(recording('#402438')))
  replacements:set(replacements()+1)
end

local function content(peer)
  return o.column {key='root', gap=14,
    o.text {key='title', text=peer and 'One recording, another window' or 'Immutable drawings', size=24},
    o.text {key='subtitle', text='Layered color · rounded edges · logical pixels'},
    o.box {key='frame', padding=12, background='#e6eaf0',
      o.grid {key='gallery', columns={240,117}, rows={150}, column_gap=23,
        o.canvas {key='full', column=1, row=1, drawing=peer and shared or selected(),
          alt='Full drawing: ordered translucent rectangles and a rounded gold bar'},
        o.canvas {key='crop', column=2, row=1, drawing=shared,
          alt='Same recording cropped to 117 logical pixels'},
      }},
    o.text {key='caption', text='240 × 150 recording          117 px crop, never stretched'},
    o.text {key='status', text=peer and 'Shared original · revision '..revision or
      'Revision '..revision..' · source edits '..mutations()..' · replacements '..replacements()},
    o.row {key='controls', gap=10,
      o.button {key='mutate', label='Mutate source tables', on_press=mutate_source},
      o.button {key='replace', label='Replace main drawing', on_press=replace_main},
    },
  }
end

local function action(handler)
  return {description='Drawing fixture control', inputSchema={type='object'}, outputSchema={type='object'},
    handler=function() handler(); return {} end}
end

return o.app {id='dev.ourokit.drawing-composition', actions={
  MutateSource=action(mutate_source), ReplaceMain=action(replace_main),
}, run=function() return {windows={
  o.window {id='main', title='Drawing composition', width=500, height=430,
    content=function() return content(false) end},
  o.window {id='peer', title='Shared drawing', width=500, height=430,
    content=function() return content(true) end},
  reject and o.window {id='rejected', width=100, height=80,
    content=function() error('reject after preparing live drawings') end} or nil,
}} end}
