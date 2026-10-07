-- Paint commands for the plant, split into three layers so each changes at
-- its own rate: `static` per graph, `live` per history frame and clock tick,
-- and `motion` per animation frame (pulses and pump rotors).
local route = require('plant.route')
local history = require('history')

local M = {}

local C = {
  background='#161b21', grid='#1d242c',
  wall='#5b6672', wall_hi='#7d8a97', interior='#0f1318', seam='#2a333d',
  compound_wall='#3b4552', header='#202830', compound_fill='#13181e', divider='#2e3742',
  lit_wall='#4fd1c1', lit_header='#173936', lit_fill='#112523',
  liquid='#1f9e93', liquid_top='#59dccd', liquid_deep='#147a71',
  final_liquid='#6cbf43', final_top='#a6e86f',
  pipe_outer='#262e37', pipe_inner='#46525e', pipe_live='#3d7c80', pipe_taken='#f2c14e',
  pulse='#fff6c8', pulse_glow='#f2c14e',
  valve_open='#4cc46b', valve_closed='#e0524d', valve_idle='#38424d', valve_line='#c8d0d8',
  dial='#0b0f13', dial_ring='#8d99a6', dial_track='#2a333d', timer='#f2a93b', timer_hot='#ffdf8a',
  pump_body='#1a2027', pump_ring='#7d8a97', pump_run='#4fd1c1', pump_error='#e0524d', pump_done='#4cc46b',
  pump_stop='#56616d', manifold='#56626f', reject='#ff5a4f', accept='#4fd1c1',
}
M.colors = C

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
  out[#out+1] = {kind='rectangle', x=cx - r, y=cy - r, width=2 * r, height=2 * r, corner_radius=r, color=color}
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
local function pipe_path(points, radius)
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

-- Windows have a fixed scene-command budget (512), so fills and strokes of
-- the same style merge into multi-contour paths. Merging is local: a path is
-- rasterized over its whole bounding box, so a group only grows while its
-- box stays compact. Each merged command paints where its group first
-- appeared; the layers are ordered so that this preserves stacking.
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
    if c.kind == 'rectangle' then
      local r = c.corner_radius or 0
      local path
      if r > 0 and math.abs(2 * r - c.width) < 0.01 and math.abs(2 * r - c.height) < 0.01 then
        path = circle_path(c.x + r, c.y + r, r)
      elseif r > 0 then
        path = rounded(c.x, c.y, c.width, c.height, math.min(r, c.width / 2, c.height / 2))
      else
        path = {{'move', c.x, c.y}, {'line', c.x + c.width, c.y}, {'line', c.x + c.width, c.y + c.height},
          {'line', c.x, c.y + c.height}, {'close'}}
      end
      c = {kind='fill', color=c.color, path=path}
    end
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

local function arc_path(cx, cy, r, from, to, steps)
  local path = {}
  for s = 0, steps do
    local a = from + (to - from) * s / steps
    path[#path+1] = {s == 0 and 'move' or 'line', cx + r * math.cos(a), cy + r * math.sin(a)}
  end
  return path
end

local function heading(points, at_end)
  local a, b
  if at_end then a, b = points[#points - 1], points[#points] else a, b = points[1], points[2] end
  local dx, dy = b[1] - a[1], b[2] - a[2]
  return dx > 0 and 1 or (dx < 0 and -1 or 0), dy > 0 and 1 or (dy < 0 and -1 or 0)
end

local function arrow(out, points, color)
  local tip = points[#points]
  local dx, dy = heading(points, true)
  local bx, by = tip[1] - dx * 3, tip[2] - dy * 3
  local px, py = -dy, dx
  out[#out+1] = {kind='fill', color=color, path={
    {'move', bx, by}, {'line', bx - dx * 10 + px * 6, by - dy * 10 + py * 6},
    {'line', bx - dx * 10 - px * 6, by - dy * 10 - py * 6}, {'close'},
  }}
end

local function flange(out, point, dx, dy, color)
  local px, py = -dy, dx
  out[#out+1] = {kind='stroke', color=color, width=3.5, path={
    {'move', point[1] + px * 7, point[2] + py * 7}, {'line', point[1] - px * 7, point[2] - py * 7},
  }}
end

local function tank(out, b, final)
  out[#out+1] = {kind='fill', color=C.interior, path=rounded(b.x, b.y, b.w, b.h, 16)}
  out[#out+1] = {kind='stroke', color=C.seam, width=1, path={
    {'move', b.x + 6, b.y + 14}, {'line', b.x + b.w - 6, b.y + 14},
    {'move', b.x + 6, b.y + b.h - 14}, {'line', b.x + b.w - 6, b.y + b.h - 14},
  }}
  out[#out+1] = {kind='stroke', color=C.wall, width=3, join='round', path=rounded(b.x, b.y, b.w, b.h, 16)}
  if final then
    out[#out+1] = {kind='stroke', color=C.wall, width=1.5, join='round', path=rounded(b.x + 5, b.y + 5, b.w - 10, b.h - 10, 12)}
  end
end

function M.static(plant)
  local out = {{kind='rectangle', x=0, y=0, width=plant.width, height=plant.height, color=C.background}}
  local grid = {}
  for x = 0, plant.width, 32 do grid[#grid+1] = {'move', x, 0}; grid[#grid+1] = {'line', x, plant.height} end
  for y = 0, plant.height, 32 do grid[#grid+1] = {'move', 0, y}; grid[#grid+1] = {'line', plant.width, y} end
  out[#out+1] = {kind='stroke', color=C.grid, width=1, path=grid}
  local graph = plant.graph
  -- Vessels from the outside in, so children paint over their parents.
  for _, state in ipairs(graph.states) do
    local b = plant.boxes[state.id]
    if state.kind == 'compound' or state.kind == 'parallel' then
      local parent = state.parent and graph.by_id[state.parent]
      if parent and parent.kind == 'parallel' then
        -- Compartment: the parallel vessel supplies the outer wall.
        out[#out+1] = {kind='rectangle', x=b.x + 2, y=b.y + 2, width=b.w - 4, height=b.header - 4, color=C.header}
      else
        out[#out+1] = {kind='fill', color=C.compound_fill, path=rounded(b.x, b.y, b.w, b.h, 10)}
        out[#out+1] = {kind='fill', color=C.header, path={
          {'move', b.x + 10, b.y}, {'line', b.x + b.w - 10, b.y}, {'quadratic', b.x + b.w, b.y, b.x + b.w, b.y + 10},
          {'line', b.x + b.w, b.y + b.header}, {'line', b.x, b.y + b.header}, {'line', b.x, b.y + 10},
          {'quadratic', b.x, b.y, b.x + 10, b.y}, {'close'},
        }}
        out[#out+1] = {kind='stroke', color=C.compound_wall, width=4, join='round', path=rounded(b.x, b.y, b.w, b.h, 10)}
      end
      if state.kind == 'parallel' then
        -- Compartment walls: a doubled bulkhead between regions.
        for k = 2, #state.children do
          local r = plant.boxes[state.children[k]]
          local path = b.stacked and {
            {'move', r.x + 4, r.y - 3}, {'line', r.x + r.w - 4, r.y - 3},
            {'move', r.x + 4, r.y + 3}, {'line', r.x + r.w - 4, r.y + 3},
          } or {
            {'move', r.x - 3, r.y + 4}, {'line', r.x - 3, r.y + r.h - 4},
            {'move', r.x + 3, r.y + 4}, {'line', r.x + 3, r.y + r.h - 4},
          }
          out[#out+1] = {kind='stroke', color=C.divider, width=2, path=path}
        end
      end
    end
  end
  for _, state in ipairs(graph.states) do
    if state.kind == 'atomic' or state.kind == 'final' then tank(out, plant.boxes[state.id], state.kind == 'final') end
  end
  for _, pipe in ipairs(plant.pipes) do
    local path = pipe_path(pipe.points, 7)
    out[#out+1] = {kind='stroke', color=C.pipe_outer, width=8, cap='butt', join='round', path=path}
    out[#out+1] = {kind='stroke', color=C.pipe_inner, width=4, cap='butt', join='round', path=path}
    local sx, sy = heading(pipe.points, false)
    flange(out, pipe.points[1], sx, sy, C.wall)
    arrow(out, pipe.points, C.wall_hi)
  end
  -- Manifold: vertical header, inlet nozzles, feed into the root vessel.
  local m = plant.manifold
  local body = {}
  for _, n in ipairs(m.nozzles) do body[#body+1] = {'move', n.x, n.y}; body[#body+1] = {'line', m.x, n.y} end
  body[#body+1] = {'move', m.feed[1][1], m.feed[1][2]}; body[#body+1] = {'line', m.feed[2][1], m.feed[2][2]}
  out[#out+1] = {kind='stroke', color=C.pipe_outer, width=8, path=body}
  out[#out+1] = {kind='stroke', color=C.pipe_inner, width=4, path=body}
  out[#out+1] = {kind='fill', color=C.manifold, path=rounded(m.x - 8, m.top - 16, 16, m.bottom - m.top + 32, 6)}
  out[#out+1] = {kind='stroke', color=C.wall_hi, width=1.5, path=rounded(m.x - 8, m.top - 16, 16, m.bottom - m.top + 32, 6)}
  for _, n in ipairs(m.nozzles) do
    out[#out+1] = {kind='rectangle', x=n.x - 4, y=n.y - 9, width=6, height=18, color=C.wall, corner_radius=1}
  end
  return M.compact(out)
end

local function valve(out, pipe, state)
  local p, horizontal = pipe.anchor, pipe.horizontal
  local x, y = p[1], p[2]
  local fill = state == true and C.valve_open or (state == false and C.valve_closed or C.valve_idle)
  local a, b = 11, 8
  local tri
  if horizontal then
    tri = {{'move', x - a, y - b}, {'line', x, y}, {'line', x - a, y + b}, {'close'},
           {'move', x + a, y - b}, {'line', x, y}, {'line', x + a, y + b}, {'close'}}
  else
    tri = {{'move', x - b, y - a}, {'line', x, y}, {'line', x + b, y - a}, {'close'},
           {'move', x - b, y + a}, {'line', x, y}, {'line', x + b, y + a}, {'close'}}
  end
  out[#out+1] = {kind='fill', color=fill, path=tri}
  out[#out+1] = {kind='stroke', color=C.valve_line, width=1.5, join='round', path=tri}
  -- Stem and actuator, perpendicular to the flow.
  local sx, sy = horizontal and 0 or -1, horizontal and -1 or 0
  out[#out+1] = {kind='stroke', color=C.valve_line, width=1.5, path={{'move', x, y}, {'line', x + sx * 14, y + sy * 14}}}
  local ax, ay = x + sx * 16, y + sy * 16
  out[#out+1] = {kind='rectangle', x=ax - 6, y=ay - 4, width=12, height=8, corner_radius=4, color=fill}
end

-- Countdown gauge in local coordinates (dial centered at r + 3). `fraction`
-- is the remaining share of the delay; nil means no timer is running.
function M.gauge(r, fraction, fired)
  local out = {}
  local x, y = r + 3, r + 3
  dot(out, x, y, r + 2, C.background)
  dot(out, x, y, r, fired and C.timer_hot or C.dial)
  local from, sweep = math.rad(135), math.rad(270)
  out[#out+1] = {kind='stroke', color=C.dial_track, width=3, cap='round', path=arc_path(x, y, r - 5, from, from + sweep, 18)}
  local f = fraction or 0
  if f > 0 then
    out[#out+1] = {kind='stroke', color=C.timer, width=3, cap='round',
      path=arc_path(x, y, r - 5, from, from + sweep * f, math.max(2, math.floor(18 * f)))}
  end
  local needle = from + sweep * f
  out[#out+1] = {kind='stroke', color=fraction and C.timer_hot or C.dial_ring, width=1.5, cap='round', path={
    {'move', x, y}, {'line', x + (r - 4) * math.cos(needle), y + (r - 4) * math.sin(needle)}}}
  dot(out, x, y, 2, C.dial_ring)
  out[#out+1] = {kind='stroke', color=fraction and C.timer or C.dial_ring, width=2, path=circle_path(x, y, r)}
  return M.compact(out)
end

local function rotor(out, p, angle, color)
  local path = {}
  for k = 0, 2 do
    local a = angle + k * 2 * math.pi / 3
    path[#path+1] = {'move', p.x, p.y}
    path[#path+1] = {'quadratic', p.x + 7 * math.cos(a - 0.6), p.y + 7 * math.sin(a - 0.6),
      p.x + 10 * math.cos(a + 0.3), p.y + 10 * math.sin(a + 0.3)}
  end
  out[#out+1] = {kind='stroke', color=color, width=2.5, cap='round', path=path}
  dot(out, p.x, p.y, 2.5, color)
end

local function pump(out, p, status)
  local ring = status == 'running' and C.pump_run or status == 'error' and C.pump_error
    or status == 'done' and C.pump_done or C.pump_ring
  -- Tangential discharge nozzle, then the casing.
  out[#out+1] = {kind='rectangle', x=p.x, y=p.y - p.r, width=p.r + 6, height=8, color=C.pump_ring, corner_radius=1}
  dot(out, p.x, p.y, p.r + 2, C.background)
  dot(out, p.x, p.y, p.r, status == 'error' and '#5a1b1a' or C.pump_body)
  out[#out+1] = {kind='stroke', color=ring, width=2.5, path=circle_path(p.x, p.y, p.r)}
  if status ~= 'running' then
    rotor(out, p, -math.pi / 2, status == 'error' and C.pump_error or C.pump_stop)
  end
  if status == 'cancelled' then
    out[#out+1] = {kind='stroke', color=C.pump_error, width=2, cap='round', path={
      {'move', p.x + p.r - 2, p.y + p.r - 9}, {'line', p.x + p.r + 6, p.y + p.r - 1},
      {'move', p.x + p.r + 6, p.y + p.r - 9}, {'line', p.x + p.r - 2, p.y + p.r - 1}}}
  end
end

-- Which pipes are lit, and which valve state applies to each.
local function pipe_state(plant, frame, pipe)
  local t = pipe.transition
  for _, member in ipairs(pipe.group) do if frame.taken[member.id] then return 'taken' end end
  local guard = t.guard and frame.guards[t.id]
  if frame.active[t.source] and (not t.guard or guard ~= false) then return 'live' end
  return 'idle'
end

function M.live(plant, frame)
  local out = {}
  local graph = plant.graph
  for _, state in ipairs(graph.states) do
    local b = plant.boxes[state.id]
    if frame.active[state.id] then
      if state.kind == 'atomic' or state.kind == 'final' then
        local final = state.kind == 'final'
        local level = b.y + b.h * 0.46
        out[#out+1] = {kind='fill', color=final and C.final_liquid or C.liquid, path={
          {'move', b.x + 5, level}, {'line', b.x + b.w - 5, level}, {'line', b.x + b.w - 5, b.y + b.h - 14},
          {'quadratic', b.x + b.w - 5, b.y + b.h - 5, b.x + b.w - 14, b.y + b.h - 5},
          {'line', b.x + 14, b.y + b.h - 5}, {'quadratic', b.x + 5, b.y + b.h - 5, b.x + 5, b.y + b.h - 14}, {'close'},
        }}
        out[#out+1] = {kind='rectangle', x=b.x + 5, y=b.y + b.h - 18, width=b.w - 10, height=6,
          color=final and '#4f9a2c' or C.liquid_deep}
        out[#out+1] = {kind='stroke', color=final and C.final_top or C.liquid_top, width=2, path={
          {'move', b.x + 6, level}, {'line', b.x + b.w - 6, level}}}
        out[#out+1] = {kind='stroke', color=C.lit_wall, width=3, join='round', path=rounded(b.x, b.y, b.w, b.h, 16)}
      elseif state.parent and graph.by_id[state.parent].kind == 'parallel' then
        out[#out+1] = {kind='rectangle', x=b.x + 2, y=b.y + 2, width=b.w - 4, height=b.header - 4, color=C.lit_header}
      elseif state.id ~= graph.root then
        out[#out+1] = {kind='stroke', color=C.lit_wall, width=2, join='round', path=rounded(b.x + 1, b.y + 1, b.w - 2, b.h - 2, 9)}
        out[#out+1] = {kind='rectangle', x=b.x + 3, y=b.y + 3, width=b.w - 6, height=b.header - 4, color=C.lit_header, corner_radius=7}
      end
    end
  end
  for _, pipe in ipairs(plant.pipes) do
    local s = pipe_state(plant, frame, pipe)
    if s ~= 'idle' then
      out[#out+1] = {kind='stroke', color=s == 'taken' and C.pipe_taken or C.pipe_live, width=4, cap='butt',
        join='round', path=pipe_path(pipe.points, 7)}
      arrow(out, pipe.points, s == 'taken' and C.pipe_taken or C.lit_wall)
    end
  end
  for _, pipe in ipairs(plant.pipes) do
    local t = pipe.transition
    if t.guard and pipe.first and not pipe.loop then valve(out, pipe, frame.taken[t.id] or frame.guards[t.id]) end
  end
  for _, p in ipairs(plant.pumps) do
    local status = frame.pumps[p.key] and frame.pumps[p.key].status or 'idle'
    if status == 'running' and not frame.active[p.state] then status = 'cancelled' end
    pump(out, p, status)
  end
  local record = frame.record
  if record.event and record.origin == 'external' then
    for _, n in ipairs(plant.manifold.nozzles) do
      if n.event == record.event.type then
        local color = record.rejected and C.reject or C.accept
        out[#out+1] = {kind='rectangle', x=n.x - 4, y=n.y - 9, width=6, height=18, color=color, corner_radius=1}
        if not record.rejected then
          local path = {{'move', n.x, n.y}, {'line', plant.manifold.x, n.y}}
          out[#out+1] = {kind='stroke', color=C.pipe_taken, width=4, path=path}
          out[#out+1] = {kind='stroke', color=C.pipe_taken, width=4, path={
            {'move', plant.manifold.feed[1][1], plant.manifold.feed[1][2]},
            {'line', plant.manifold.feed[2][1], plant.manifold.feed[2][2]}}}
        end
      end
    end
  end
  return M.compact(out)
end

-- Pulse routes for a record: manifold → pipes for external events, gauge →
-- pipe for timers, pump → pipe for invoke results. Microsteps run in order.
function M.pulse_routes(plant, frame)
  local record = frame.record
  local stages = {}
  if record.origin == 'external' and record.event then
    for _, n in ipairs(plant.manifold.nozzles) do
      if n.event == record.event.type then
        local feed = plant.manifold.feed
        if record.rejected then
          stages[#stages+1] = {{points={{n.x - 30, n.y}, {n.x, n.y}}, reject=true}}
        else
          stages[#stages+1] = {{points={{n.x, n.y}, {plant.manifold.x, n.y}, {plant.manifold.x, feed[1][2]}, feed[2]}}}
        end
      end
    end
  end
  for _, step in ipairs(record.microsteps) do
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
-- coordinates), so an animation frame damages only a few dozen pixels
-- instead of re-rendering the whole plant.
M.SPRITE = 100

function M.rotor_sprite(p, spin)
  local size = 2 * p.r + 8
  local out = {}
  rotor(out, {x=size / 2, y=size / 2}, spin * 2 * math.pi, C.pump_run)
  return {key='rotor:' .. p.key, x=p.x - size / 2, y=p.y - size / 2, size=size, commands=M.compact(out)}
end

function M.pulse_sprites(plant, frame, pulse)
  local sprites = {}
  if not pulse or pulse >= 1 then return sprites end
  local stages = M.pulse_routes(plant, frame)
  local n = #stages
  if n == 0 then return sprites end
  local k = math.min(n, math.floor(pulse * n) + 1)
  local local_t = pulse * n - (k - 1)
  local half = M.SPRITE / 2
  for i, item in ipairs(stages[k]) do
    local out, cx, cy = {}, nil, nil
    if item.reject then
      -- Rejected events burst at the manifold inlet and fade.
      local tip = item.points[2]
      cx, cy = tip[1] - 4, tip[2]
      local r = 6 + 16 * local_t
      local alpha = string.format('%02x', math.floor(255 * (1 - local_t)))
      out[#out+1] = {kind='stroke', color=C.reject .. alpha, width=3, path=circle_path(cx, cy, r)}
      local spokes = {}
      for sp = 0, 7 do
        local a = sp * math.pi / 4
        spokes[#spokes+1] = {'move', cx + (r + 3) * math.cos(a), cy + (r + 3) * math.sin(a)}
        spokes[#spokes+1] = {'line', cx + (r + 9) * math.cos(a), cy + (r + 9) * math.sin(a)}
      end
      out[#out+1] = {kind='stroke', color=C.reject .. alpha, width=2, cap='round', path=spokes}
    else
      local length = route.length(item.points)
      cx, cy = route.at(item.points, length * local_t)
      for trail = 5, 0, -1 do
        local d = length * local_t - trail * 7
        if d >= 0 then
          local x, y = route.at(item.points, d)
          local alpha = string.format('%02x', math.floor(255 * (1 - trail / 6)))
          dot(out, x, y, trail == 0 and 7 or 5 - trail * 0.6, C.pulse_glow .. alpha)
          if trail == 0 then dot(out, x, y, 3.5, C.pulse) end
        end
      end
    end
    sprites[#sprites+1] = {key='pulse:' .. i, x=cx - half, y=cy - half, size=M.SPRITE,
      commands=shift(M.compact(out), half - cx, half - cy)}
  end
  return sprites
end

return M
