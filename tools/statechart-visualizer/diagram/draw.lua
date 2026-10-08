-- Paint commands for the statechart diagram in Harel / SCXML / Stately
-- notation, split by update rate: `static` per graph and palette, `live` per
-- history frame, and sprites per animation frame (taken-transition pulses).
local route = require('diagram.route')
local layout = require('diagram.layout')

local M = {}

-- Neutral palettes; the view picks one from the inherited color scheme.
M.palettes = {
  light = {
    background='#f6f7f9', canvas='#fbfbfc', panel='#ffffff', panel_edge='#e3e6eb',
    state='#ffffff', state_edge='#c3c9d2', compound='#f1f3f6', compound_edge='#d3d8df', divider='#b8bfca',
    text='#1d2330', muted='#677386', faint='#a2abb8',
    arrow='#9aa3b1', arrow_live='#4b5565',
    accent='#2f6fed', active='#eaf1ff', active_edge='#2f6fed',
    taken='#ea6a0c', taken_soft='#fff1e6', pulse='#ffb27a',
    pill='#eef1f5', pill_edge='#d6dbe2', pass='#13854a', fail='#d23a2f',
    chip_running='#2f6fed', chip_done='#13854a', chip_error='#d23a2f', chip_idle='#8a94a3',
  },
  dark = {
    background='#101318', canvas='#13171d', panel='#171b22', panel_edge='#262c36',
    state='#1b2028', state_edge='#3a4250', compound='#161a21', compound_edge='#2d343f', divider='#465062',
    text='#e5e8ed', muted='#949eae', faint='#5d6778',
    arrow='#556071', arrow_live='#a7b0be',
    accent='#6aa3ff', active='#1a2a44', active_edge='#6aa3ff',
    taken='#ff9a4d', taken_soft='#3a2616', pulse='#ffc79a',
    pill='#222833', pill_edge='#343c49', pass='#4fc785', fail='#ff6b60',
    chip_running='#6aa3ff', chip_done='#4fc785', chip_error='#ff6b60', chip_idle='#6c7687',
  },
}

local K = 0.5523

local function circle_path(cx, cy, r)
  local k = r * K
  return {
    {'move', cx + r, cy},
    {'cubic', cx + r, cy + k, cx + k, cy + r, cx, cy + r},
    {'cubic', cx - k, cy + r, cx - r, cy + k, cx - r, cy},
    {'cubic', cx - r, cy - k, cx - k, cy - r, cx, cy - r},
    {'cubic', cx + k, cy - r, cx + r, cy - k, cx + r, cy},
    {'close'},
  }
end
M.circle_path = circle_path

local function dot(out, cx, cy, r, color)
  out[#out+1] = {kind='fill', color=color, path=circle_path(cx, cy, r)}
end

local function rounded(x, y, w, h, r)
  return {
    {'move', x + r, y}, {'line', x + w - r, y}, {'quadratic', x + w, y, x + w, y + r},
    {'line', x + w, y + h - r}, {'quadratic', x + w, y + h, x + w - r, y + h},
    {'line', x + r, y + h}, {'quadratic', x, y + h, x, y + h - r},
    {'line', x, y + r}, {'quadratic', x, y, x + r, y}, {'close'},
  }
end

-- Polyline with rounded orthogonal corners.
local function arrow_path(points, radius)
  local path = {{'move', points[1][1], points[1][2]}}
  for k = 2, #points - 1 do
    local a, b, c = points[k - 1], points[k], points[k + 1]
    local function toward(p, q, d)
      local len = math.abs(q[1] - p[1]) + math.abs(q[2] - p[2])
      local f = len > 0 and math.min(d, len / 2) / len or 0
      return p[1] + (q[1] - p[1]) * f, p[2] + (q[2] - p[2]) * f
    end
    local x1, y1 = toward(b, a, radius)
    local x2, y2 = toward(b, c, radius)
    path[#path+1] = {'line', x1, y1}
    path[#path+1] = {'quadratic', b[1], b[2], x2, y2}
  end
  path[#path+1] = {'line', points[#points][1], points[#points][2]}
  return path
end

local function heading(points)
  local a, b = points[#points - 1], points[#points]
  local dx, dy = b[1] - a[1], b[2] - a[2]
  return dx > 0 and 1 or (dx < 0 and -1 or 0), dy > 0 and 1 or (dy < 0 and -1 or 0)
end

local function arrowhead(out, points, color, size)
  size = size or 8
  local tip = points[#points]
  local dx, dy = heading(points)
  local px, py = -dy, dx
  out[#out+1] = {kind='fill', color=color, path={
    {'move', tip[1], tip[2]}, {'line', tip[1] - dx * size + px * size * 0.55, tip[2] - dy * size + py * size * 0.55},
    {'line', tip[1] - dx * size - px * size * 0.55, tip[2] - dy * size - py * size * 0.55}, {'close'},
  }}
end

-- Shortens the last segment so the arrowhead tip lands on the border.
local function trimmed(points, by)
  local out = {}
  for i, p in ipairs(points) do out[i] = {p[1], p[2]} end
  local dx, dy = heading(points)
  local last = out[#out]
  last[1], last[2] = last[1] - dx * by, last[2] - dy * by
  return out
end

local function dashed(out, color, x1, y1, x2, y2)
  local path, len = {}, math.abs(x2 - x1) + math.abs(y2 - y1)
  local ux, uy = (x2 - x1) / math.max(len, 1), (y2 - y1) / math.max(len, 1)
  local d = 0
  while d < len do
    local e = math.min(len, d + 6)
    path[#path+1] = {'move', x1 + ux * d, y1 + uy * d}
    path[#path+1] = {'line', x1 + ux * e, y1 + uy * e}
    d = d + 11
  end
  out[#out+1] = {kind='stroke', color=color, width=1.5, cap='round', path=path}
end

-- Windows have a fixed scene-command budget, so fills and strokes of the
-- same style merge into multi-contour paths while their bounding box stays
-- compact (a path rasterizes over its whole box). Each merged command paints
-- where its group first appeared; layers are ordered so that preserves
-- stacking.
local function bounds(path, pad)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, seg in ipairs(path) do
    for k = 2, #seg, 2 do
      local x, y = seg[k], seg[k + 1]
      if x < x0 then x0 = x end
      if x > x1 then x1 = x end
      if y < y0 then y0 = y end
      if y > y1 then y1 = y end
    end
  end
  return {x0 - pad, y0 - pad, x1 + pad, y1 + pad}
end

local function area(b) return math.max(0, b[3] - b[1]) * math.max(0, b[4] - b[2]) end

function M.compact(commands)
  local out, groups = {}, {}
  for _, c in ipairs(commands) do
    local key = table.concat({c.kind, tostring(c.color), tostring(c.width), c.cap or '', c.join or '', c.fill_rule or ''}, '|')
    local box = bounds(c.path, (c.width or 0) + 2)
    local into
    for _, g in ipairs(groups[key] or {}) do
      local u = {math.min(g.box[1], box[1]), math.min(g.box[2], box[2]), math.max(g.box[3], box[3]), math.max(g.box[4], box[4])}
      if area(u) <= math.max(90000, 2.5 * (g.covered + area(box))) then
        g.box, g.covered, into = u, g.covered + area(box), g
        break
      end
    end
    if into then
      for _, seg in ipairs(c.path) do into.command.path[#into.command.path+1] = seg end
    else
      local copy = {}
      for k, v in pairs(c) do copy[k] = v end
      copy.path = {}
      for _, seg in ipairs(c.path) do copy.path[#copy.path+1] = seg end
      groups[key] = groups[key] or {}
      table.insert(groups[key], {box=box, covered=area(box), command=copy})
      out[#out+1] = copy
    end
  end
  return out
end

-- Pill rectangles of a pipe's label, one per transition (loops list several).
function M.pill_rects(pipe)
  local rects, box = {}, pipe.label_box
  for i, p in ipairs(pipe.pills) do
    rects[i] = {x=box.x, y=box.y + (i - 1) * (layout.PILL_H + 3), w=layout.pill_width(p), h=layout.PILL_H, pill=p}
  end
  return rects
end

local function is_box(kind) return kind == 'atomic' or kind == 'final' end

function M.static(plant, P)
  local out = {{kind='fill', color=P.canvas, path={{'move', 0, 0}, {'line', plant.width, 0},
    {'line', plant.width, plant.height}, {'line', 0, plant.height}, {'close'}}}}
  local graph = plant.graph
  for _, state in ipairs(graph.states) do
    local b = plant.boxes[state.id]
    if not is_box(state.kind) then
      local parent = state.parent and graph.by_id[state.parent]
      if not (parent and parent.kind == 'parallel') then
        out[#out+1] = {kind='fill', color=P.compound, path=rounded(b.x, b.y, b.w, b.h, 12)}
        out[#out+1] = {kind='stroke', color=P.compound_edge, width=1.5, join='round', path=rounded(b.x, b.y, b.w, b.h, 12)}
      end
      if state.kind == 'parallel' then
        -- Regions are separated by dashed lines.
        for k = 2, #state.children do
          local r = plant.boxes[state.children[k]]
          if b.stacked then dashed(out, P.divider, r.x + 10, r.y, r.x + r.w - 10, r.y)
          else dashed(out, P.divider, r.x, r.y + 8, r.x, r.y + r.h - 8) end
        end
      end
    end
  end
  for _, state in ipairs(graph.states) do
    if is_box(state.kind) then
      local b = plant.boxes[state.id]
      out[#out+1] = {kind='fill', color=P.state, path=rounded(b.x, b.y, b.w, b.h, 9)}
      out[#out+1] = {kind='stroke', color=P.state_edge, width=1.5, join='round', path=rounded(b.x, b.y, b.w, b.h, 9)}
      if state.kind == 'final' then
        out[#out+1] = {kind='stroke', color=P.state_edge, width=1.5, join='round', path=rounded(b.x + 4, b.y + 4, b.w - 8, b.h - 8, 6)}
      end
      if b.lines and #b.lines > 0 then
        out[#out+1] = {kind='stroke', color=P.state_edge, width=1, path={{'move', b.x + 8, b.y + 28}, {'line', b.x + b.w - 8, b.y + 28}}}
      end
    end
  end
  for _, i in ipairs(plant.initials) do
    dot(out, i.x, i.y, 5, P.text)
    local points = {{i.x, i.y + 5}, {i.to[1], i.to[2] - 1}}
    out[#out+1] = {kind='stroke', color=P.text, width=1.5, path={{'move', i.x, i.y + 5}, {'line', i.to[1], i.to[2] - 7}}}
    arrowhead(out, points, P.text, 7)
  end
  for _, pipe in ipairs(plant.pipes) do
    out[#out+1] = {kind='stroke', color=P.arrow, width=1.5, cap='round', join='round', path=arrow_path(trimmed(pipe.points, 6), 8)}
    arrowhead(out, pipe.points, P.arrow)
  end
  for _, pipe in ipairs(plant.pipes) do
    if pipe.first then
      for _, r in ipairs(M.pill_rects(pipe)) do
        out[#out+1] = {kind='fill', color=P.pill, path=rounded(r.x, r.y, r.w, r.h, r.h / 2)}
        out[#out+1] = {kind='stroke', color=P.pill_edge, width=1, path=rounded(r.x, r.y, r.w, r.h, r.h / 2)}
      end
    end
  end
  return M.compact(out)
end

-- 'taken' (this step), 'live' (source active, guard not known false), 'idle'.
function M.pipe_state(frame, pipe)
  local t = pipe.transition
  for _, member in ipairs(pipe.group) do if frame.taken[member.id] then return 'taken' end end
  if frame.active[t.source] and frame.guards[t.id] ~= false then return 'live' end
  return 'idle'
end

-- Invoke status for a state line: running / done / error / cancelled / idle.
function M.invoke_status(frame, line)
  local info = frame.pumps[line.key]
  local status = info and info.status or 'idle'
  if status == 'running' and not frame.active[line.invoke and line.key:match('^(.*)|') or ''] then status = 'cancelled' end
  return status
end

M.CHIP_W = 62

function M.live(plant, frame, P)
  local out = {}
  local graph = plant.graph
  for _, state in ipairs(graph.states) do
    local b = plant.boxes[state.id]
    if frame.active[state.id] then
      if is_box(state.kind) then
        out[#out+1] = {kind='fill', color=P.active, path=rounded(b.x, b.y, b.w, b.h, 9)}
        out[#out+1] = {kind='stroke', color=P.active_edge, width=2, join='round', path=rounded(b.x, b.y, b.w, b.h, 9)}
        if state.kind == 'final' then
          out[#out+1] = {kind='stroke', color=P.active_edge, width=1.5, join='round', path=rounded(b.x + 4, b.y + 4, b.w - 8, b.h - 8, 6)}
        end
        if b.lines and #b.lines > 0 then
          out[#out+1] = {kind='stroke', color=P.active_edge, width=1, path={{'move', b.x + 8, b.y + 28}, {'line', b.x + b.w - 8, b.y + 28}}}
        end
      elseif state.id ~= graph.root and not (state.parent and graph.by_id[state.parent].kind == 'parallel') then
        out[#out+1] = {kind='stroke', color=P.active_edge, width=1.5, join='round', path=rounded(b.x, b.y, b.w, b.h, 12)}
      end
    end
    -- Invoke status chips, right-aligned on their lines.
    for i, line in ipairs(b.lines or {}) do
      if line.invoke then
        local status = M.invoke_status(frame, line)
        local color = P['chip_' .. (status == 'running' and 'running' or status == 'done' and 'done'
          or status == 'error' and 'error' or 'idle')]
        local y = b.y + 32 + (i - 1) * layout.LINE_H
        out[#out+1] = {kind='fill', color=color .. '2a', path=rounded(b.x + b.w - M.CHIP_W - 8, y, M.CHIP_W, 13, 6.5)}
      end
    end
  end
  for _, pipe in ipairs(plant.pipes) do
    local s = M.pipe_state(frame, pipe)
    if s ~= 'idle' then
      local color = s == 'taken' and P.taken or P.arrow_live
      out[#out+1] = {kind='stroke', color=color, width=s == 'taken' and 2.5 or 1.5, cap='round', join='round',
        path=arrow_path(trimmed(pipe.points, 6), 8)}
      arrowhead(out, pipe.points, color, s == 'taken' and 9 or 8)
    end
  end
  for _, pipe in ipairs(plant.pipes) do
    if pipe.first then
      for _, r in ipairs(M.pill_rects(pipe)) do
        local t = r.pill.transition
        if t and frame.taken[t.id] then
          out[#out+1] = {kind='fill', color=P.taken_soft, path=rounded(r.x, r.y, r.w, r.h, r.h / 2)}
          out[#out+1] = {kind='stroke', color=P.taken, width=1.5, path=rounded(r.x, r.y, r.w, r.h, r.h / 2)}
        end
      end
    end
  end
  return M.compact(out)
end

-- Pulse routes for a record: the taken transitions of each microstep, in
-- order. A rejected external event pulses nothing (its pill flashes).
function M.pulse_routes(plant, frame)
  local stages = {}
  for _, step in ipairs(frame.record.microsteps) do
    local stage = {}
    for _, id in ipairs(step.transitions) do
      for _, pipe in ipairs(plant.pipes) do
        for _, member in ipairs(pipe.group) do
          if member.id == id then stage[#stage+1] = {points=pipe.points} end
        end
      end
    end
    if #stage > 0 then stages[#stages+1] = stage end
  end
  return stages
end

local function shift(commands, dx, dy)
  for _, c in ipairs(commands) do
    for _, seg in ipairs(c.path) do
      for k = 2, #seg, 2 do seg[k], seg[k + 1] = seg[k] + dx, seg[k + 1] + dy end
    end
  end
  return commands
end

-- Moving parts as small sprites ({key, x, y, size, commands} in sprite
-- coordinates), so an animation frame damages a few dozen pixels only.
M.SPRITE = 60

function M.pulse_sprites(plant, frame, pulse, P)
  local sprites = {}
  if not pulse or pulse >= 1 then return sprites end
  local stages = M.pulse_routes(plant, frame)
  local n = #stages
  if n == 0 then return sprites end
  local k = math.min(n, math.floor(pulse * n) + 1)
  local local_t = pulse * n - (k - 1)
  local half = M.SPRITE / 2
  for i, item in ipairs(stages[k]) do
    local out = {}
    local length = route.length(item.points)
    local cx, cy = route.at(item.points, length * local_t)
    for trail = 4, 0, -1 do
      local d = length * local_t - trail * 6
      if d >= 0 then
        local x, y = route.at(item.points, d)
        local alpha = string.format('%02x', math.floor(220 * (1 - trail / 5)))
        dot(out, x, y, trail == 0 and 5.5 or 4 - trail * 0.5, P.taken .. alpha)
        if trail == 0 then dot(out, x, y, 2.5, P.pulse) end
      end
    end
    sprites[#sprites+1] = {key='pulse:' .. i, x=cx - half, y=cy - half, size=M.SPRITE,
      commands=shift(M.compact(out), half - cx, half - cy)}
  end
  return sprites
end

return M
