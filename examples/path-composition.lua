-- Public path snapshot fixture for tests/path_composition.py. Run with --dev.
local o = require('ouro')
local revision = 1
local reject = false
local backdrop = revision == 1 and '#102030' or '#26394b'

local function recording(background)
  return {width=260, height=180, commands={
    {kind='rectangle', x=0, y=0, width=260, height=180, color=background},
    {kind='rectangle', x=16, y=16, width=85, height=65, color='#c05020'},
    -- Open contours close implicitly for fill, but not for stroke.
    {kind='fill', color='#20c08080', path={
      {'move',40,30}, {'line',110,30}, {'line',110,95}, {'line',40,95},
    }},
    {kind='stroke', color='#4060e0a0', width=16, path={{'move',62,60}, {'line',110,60}}},
    {kind='rectangle', x=80, y=52, width=12, height=16, color='#e8b65a'},
    -- Both contours run in the same direction: nonzero would fill the hole.
    {kind='fill', color='#75ce9f', fill_rule='even_odd', path={
      {'move',140,14}, {'line',240,14}, {'line',240,84}, {'line',140,84}, {'close'},
      {'move',168,32}, {'line',213,32}, {'line',213,65}, {'line',168,65}, {'close'},
    }},
    {kind='fill', color='#e8b65a', path={{'move',15,105}, {'line',70,105}, {'line',15,145}}},
    {kind='stroke', color='#75ce9f', width=14, path={{'move',155,105}, {'line',205,105}}},
    {kind='stroke', color='#e8b65a', width=14, cap='round', path={{'move',155,130}, {'line',205,130}}},
    {kind='stroke', color='#c77de8', width=14, cap='square', path={{'move',155,155}, {'line',205,155}}},
    {kind='stroke', color='#ef8d70', width=8, cap='round', path={
      {'move',20,165}, {'quadratic',60,110,100,165},
    }},
    {kind='stroke', color='#79bafa', width=8, path={
      {'move',115,170}, {'cubic',115,130,135,130,135,170},
    }},
  }}
end

local source = recording(backdrop)
local shared = o.drawing(source)
local selected = o.signal(shared)
local mutations, replacements = o.signal(0), o.signal(0)

local function mutate_source()
  if source.commands[3] then
    source.commands[3].color = '#ff00ff'
    source.commands[3].path[1][2] = 200
    source.commands[3].path[2] = {'line',250,170}
    source.commands[6].fill_rule = 'nonzero'
    source.commands[9].cap, source.commands[9].width = 'butt', 2
    source.commands[11].path[2][3] = 175
    source.commands[12].path = {}
    source.commands[5] = {kind='rectangle', x=0, y=0, width=260, height=180, color='#ffffff'}
  end
  source.width, source.height, source.commands = 7, 9, {}
  mutations:set(mutations()+1)
end

local function replace_main()
  selected:set(o.drawing(recording(revision == 1 and '#402438' or '#513520')))
  replacements:set(replacements()+1)
end

local function content(peer)
  return o.column {key='root', gap=12,
    o.text {key='title', text=peer and 'Shared path snapshot' or 'Immutable path recordings', size=24},
    o.text {key='subtitle', text='Ordered paint · holes · curves · cap styles'},
    o.box {key='frame', padding=12, background='#e6eaf0',
      o.grid {key='gallery', columns={260,117}, rows={180}, column_gap=23,
        o.canvas {key='full', column=1, row=1, drawing=peer and shared or selected(),
          alt='Full paths: ordered paint, even-odd hole, curves and three caps'},
        o.canvas {key='crop', column=2, row=1, drawing=shared,
          alt='Shared paths cropped to 117 logical pixels, never stretched'},
      }},
    o.text {key='caption', text='260 × 180 recording              117 px crop'},
    o.text {key='status', text=peer and 'Shared original · revision '..revision or
      'Revision '..revision..' · source edits '..mutations()..' · replacements '..replacements()},
    o.row {key='controls', gap=10,
      o.button {key='mutate', label='Mutate source tables', on_press=mutate_source},
      o.button {key='replace', label='Replace main drawing', on_press=replace_main},
    },
  }
end

local function action(handler)
  return {description='Path fixture control', inputSchema={type='object'}, outputSchema={type='object'},
    handler=function() handler(); return {} end}
end

return o.app {id='dev.ourokit.path-composition', actions={
  MutateSource=action(mutate_source), ReplaceMain=action(replace_main),
}, run=function() return {windows={
  o.window {id='main', title='Path composition', width=520, height=450,
    content=function() return content(false) end},
  o.window {id='peer', title='Shared paths', width=520, height=450,
    content=function() return content(true) end},
  reject and o.window {id='rejected', width=100, height=80,
    content=function() error('reject after preparing live paths') end} or nil,
}} end}
