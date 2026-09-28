-- Native path rendering, in logical pixels. Every export uses a 2× snapshot.
local o = require('ouro')
local ink, teal, gold, pink = '#79bafa', '#75ce9f', '#e8b65a', '#c77de8'
local paper = '#102030'

local function drawing(width, height, commands)
  table.insert(commands, 1, {kind='rectangle', x=0, y=0, width=width, height=height, color=paper})
  return o.drawing {width=width, height=height, commands=commands}
end

local function panel(key, title, caption, image, width)
  return o.box {key=key, width=width,
    o.column {key='content', gap=10,
      o.text {key='title', text=title, size=19, color='#173b61'},
      o.canvas {key='image', drawing=image, alt=caption},
      o.text {key='caption', text=caption, size=14, color='#42566c'},
    }}
end

local function page(title, caption, content)
  return o.box {key='page', padding=24, background='#f1f4f8',
    o.column {key='content', gap=18,
      o.text {key='title', text=title, size=28, color='#173b61'},
      o.text {key='caption', text=caption, size=16, color='#42566c'},
      content,
    }}
end

local function nested(rule)
  return drawing(200,180, {{kind='fill', color=teal, fill_rule=rule, path={
    {'move',20,20}, {'line',180,20}, {'line',180,160}, {'line',20,160}, {'close'},
    {'move',62,54}, {'line',142,54}, {'line',142,124}, {'line',62,124}, {'close'},
  }}})
end

local function fills()
  local concave = drawing(200,180, {
    {kind='fill', color=ink, path={
      {'move',20,20}, {'line',170,20}, {'line',170,62}, {'line',74,62},
      {'line',74,151}, {'line',20,151}, {'close'},
    }},
    {kind='fill', color=gold, path={{'move',97,89}, {'line',178,89}, {'line',137,153}}},
  })
  return page('Fill rules & concave contours', 'Both nested contours have the same winding direction.',
    o.row {key='panels', gap=20,
      panel('concave', 'Concave + open', 'A concave L; the gold triangle closes implicitly.', concave, 200),
      panel('nonzero', 'Nonzero', 'Same-direction contours remain solid.', nested('nonzero'), 200),
      panel('evenodd', 'Even-odd', 'The identical inner contour becomes a hole.', nested('even_odd'), 200),
    })
end

local function curves()
  local image = drawing(640,230, {
    {kind='stroke', color='#34485e', width=2, path={
      {'move',28,180}, {'line',150,10}, {'line',272,180},
      {'move',356,180}, {'line',350,10}, {'line',570,10}, {'line',604,180},
    }},
    {kind='stroke', color=ink, width=12, cap='round', path={
      {'move',28,180}, {'quadratic',150,10,272,180},
    }},
    {kind='stroke', color=gold, width=12, cap='round', path={
      {'move',356,180}, {'cubic',350,10,570,10,604,180},
    }},
    {kind='rectangle', x=145, y=5, width=10, height=10, color=pink, corner_radius=3},
    {kind='rectangle', x=345, y=5, width=10, height=10, color=pink, corner_radius=3},
    {kind='rectangle', x=565, y=5, width=10, height=10, color=pink, corner_radius=3},
  })
  return page('Quadratic & cubic strokes', '12 px strokes · round caps · faint control polygons',
    panel('curves', 'One control point / two control points',
      'Blue: quadratic. Gold: asymmetric cubic. Pink squares mark off-curve control points.', image, 640))
end

local function styles()
  local panels = {}
  local caps, joins = {'butt','round','square'}, {'miter','round','bevel'}
  local colors = {ink,teal,gold}
  for i=1,3 do
    panels[i] = panel(caps[i], caps[i]..' / '..joins[i],
      i == 1 and 'Butt stops at the guide; miter extends the corner (limit 4).' or
      i == 2 and 'Round caps and joins keep a circular outline.' or
      'Square caps extend; bevel cuts the outer corner.',
      drawing(200,180, {
        {kind='rectangle', x=39, y=18, width=2, height=54, color='#34485e'},
        {kind='rectangle', x=159, y=18, width=2, height=54, color='#34485e'},
        {kind='stroke', color=colors[i], width=20, cap=caps[i], path={{'move',40,45}, {'line',160,45}}},
        {kind='stroke', color=colors[i], width=20, join=joins[i], miter_limit=4,
          path={{'move',35,155}, {'line',100,95}, {'line',165,155}}},
      }), 200)
  end
  return page('Caps & joins', '20 px strokes · cap endpoints shown by vertical guides',
    o.row {key='panels', gap=20, children=panels})
end

local source = {width=420, height=180, commands={
  {kind='rectangle', x=0, y=0, width=420, height=180, color=paper},
  {kind='fill', color=teal, fill_rule='even_odd', path={
    {'move',-20,24}, {'line',248,24}, {'line',248,156}, {'line',-20,156}, {'close'},
    {'move',48,54}, {'line',200,54}, {'line',200,126}, {'line',48,126}, {'close'},
  }},
  {kind='stroke', color=pink, width=16, cap='round', path={
    {'move',16,140}, {'cubic',124,-20,228,220,402,40},
  }},
  {kind='rectangle', x=280, y=38, width=108, height=104, color='#e8b65ab0', corner_radius=18},
}}
local retained = o.drawing(source)
-- This is deliberately before the first scene: construction copies all layers.
source.commands[2].path[2][2] = 0
source.commands[2].fill_rule = 'nonzero'
source.commands[3].color = '#ff0000'
source.commands = {}

local function snapshots()
  return page('Shared, clipped, retained', 'One immutable recording · logical sizes unchanged at 2× export',
    o.row {key='panels', gap=20,
      panel('full', 'Full · 420 × 180', 'Source geometry and styles were mutated after construction.', retained, 420),
      panel('crop', 'Crop · 180 × 180', 'The same snapshot, clipped rather than stretched.', retained, 180),
    })
end

return o.storybook {title='Path drawings', stories={
  o.story {id='paths/fills', name='Fill rules and concavity', viewport={width=700,height=440}, snapshot_scale=2, color_scheme='light', content=fills},
  o.story {id='paths/curves', name='Quadratic and cubic curves', viewport={width=700,height=480}, snapshot_scale=2, color_scheme='light', content=curves},
  o.story {id='paths/styles', name='Stroke caps and joins', viewport={width=700,height=440}, snapshot_scale=2, color_scheme='light', content=styles},
  o.story {id='paths/snapshots', name='Shared clipped snapshots', viewport={width=700,height=440}, snapshot_scale=2, color_scheme='light', content=snapshots},
}}
