-- Lays a normalized statechart graph out as a process plant: atomic states
-- are tanks, compound states are vessels containing their children, parallel
-- regions are side-by-side compartments. Siblings are layered left to right by
-- breadth-first distance from the initial child so flow mostly runs east.
local route = require('plant.route')

local M = {}

M.TANK_W, M.TANK_H = 108, 70
M.PAD, M.HEADER, M.REGION_HEADER = 26, 28, 24
M.GAP_X, M.GAP_Y = 124, 60
M.MARGIN = 24

-- Monospace label metrics (DejaVu Sans Mono advance is 0.602 em).
M.LABEL_SIZE = 10
local function text_width(text, size) return utf8.len(text) * size * 0.602 end
M.text_width = text_width

local function child_of(graph, ancestor, id)
  local state = graph.by_id[id]
  while state and state.parent ~= ancestor do state = state.parent and graph.by_id[state.parent] end
  return state and state.id
end

local function layers(graph, state)
  local edges = {}
  for _, t in ipairs(graph.transitions) do
    for _, target in ipairs(t.targets) do
      local a, b = child_of(graph, state.id, t.source), child_of(graph, state.id, target)
      if a and b and a ~= b then edges[a] = edges[a] or {}; table.insert(edges[a], b) end
    end
  end
  local rank, queue = {[state.initial or state.children[1]] = 0}, {state.initial or state.children[1]}
  local head = 1
  while queue[head] do
    local id = queue[head]; head = head + 1
    for _, next_id in ipairs(edges[id] or {}) do
      if rank[next_id] == nil then rank[next_id] = rank[id] + 1; queue[#queue+1] = next_id end
    end
  end
  local deepest = 0
  for _, r in pairs(rank) do deepest = math.max(deepest, r) end
  local columns = {}
  for _, id in ipairs(state.children) do
    local r = rank[id] or (deepest + 1)
    columns[r+1] = columns[r+1] or {}
    table.insert(columns[r+1], id)
  end
  local dense = {}
  for i = 1, #columns + 2 do if columns[i] then dense[#dense+1] = columns[i] end end
  return dense
end

local measure

-- Target aspect ratio of the plant area; each vessel picks the layer
-- direction (east or south) that brings it closest.
M.ASPECT = 1.9

local function measure_compound(graph, state, sizes, header)
  local layer_ids = layers(graph, state)
  local child = {}
  for _, column in ipairs(layer_ids) do
    for _, id in ipairs(column) do
      local w, h = measure(graph, graph.by_id[id], sizes)
      child[id] = {w=w, h=h}
    end
  end
  local function arrange(east)
    local cross, along = {}, {}
    local inner_w, inner_h = 0, 0
    for l, ids in ipairs(layer_ids) do
      cross[l], along[l] = 0, 0
      for i, id in ipairs(ids) do
        local c = child[id]
        if east then cross[l], along[l] = math.max(cross[l], c.w), along[l] + c.h + (i > 1 and M.GAP_Y or 0)
        else cross[l], along[l] = math.max(cross[l], c.h), along[l] + c.w + (i > 1 and M.GAP_X or 0) end
      end
      if east then inner_w, inner_h = inner_w + cross[l] + (l > 1 and M.GAP_X or 0), math.max(inner_h, along[l])
      else inner_h, inner_w = inner_h + cross[l] + (l > 1 and M.GAP_Y or 0), math.max(inner_w, along[l]) end
    end
    return {w=inner_w + 2 * M.PAD, h=inner_h + header + 2 * M.PAD, east=east, layers=layer_ids,
      cross=cross, along=along, header=header}
  end
  local east, south = arrange(true), arrange(false)
  local function misfit(a) return math.abs(math.log(a.w / a.h / M.ASPECT)) end
  local chosen = (#layer_ids < 2 or misfit(east) <= misfit(south)) and east or south
  sizes[state.id] = chosen
  return chosen.w, chosen.h
end

function measure(graph, state, sizes)
  if state.kind == 'atomic' or state.kind == 'final' then
    sizes[state.id] = {w=M.TANK_W, h=M.TANK_H}
    return M.TANK_W, M.TANK_H
  end
  local parent = state.parent and graph.by_id[state.parent]
  local header = (parent and parent.kind == 'parallel') and M.REGION_HEADER or M.HEADER
  if state.kind == 'compound' then return measure_compound(graph, state, sizes, header) end
  -- Parallel: compartments under one header, side by side unless stacking
  -- them fits the plant's aspect ratio much better.
  local rw, rh, mw, mh = 0, 0, 0, 0
  for _, id in ipairs(state.children) do
    local cw, ch = measure(graph, graph.by_id[id], sizes)
    rw, rh, mw, mh = rw + cw, math.max(rh, ch), math.max(mw, cw), mh + ch
  end
  local function misfit(w, h) return math.abs(math.log(w / h / M.ASPECT)) end
  local stacked = misfit(mw, mh + header) + 0.35 < misfit(rw, rh + header)
  for _, id in ipairs(state.children) do
    if stacked then sizes[id].w = mw else sizes[id].h = rh end
  end
  local w, h = stacked and mw or rw, stacked and mh or rh
  sizes[state.id] = {w=w, h=h + header, header=header, stacked=stacked}
  return w, h + header
end

local function place(graph, state, sizes, boxes, x, y)
  local size = sizes[state.id]
  boxes[state.id] = {x=x, y=y, w=size.w, h=size.h, header=size.header, kind=state.kind, depth=state.depth, stacked=size.stacked}
  if state.kind == 'parallel' then
    local cx, cy = x, y + size.header
    for _, id in ipairs(state.children) do
      place(graph, graph.by_id[id], sizes, boxes, cx, cy)
      if size.stacked then cy = cy + sizes[id].h else cx = cx + sizes[id].w end
    end
  elseif state.kind == 'compound' then
    local inner_x, inner_y = x + M.PAD, y + size.header + M.PAD
    local inner_w, inner_h = size.w - 2 * M.PAD, size.h - size.header - 2 * M.PAD
    local offset = 0
    for l, ids in ipairs(size.layers) do
      -- Center each layer's run along its axis, and each child across it.
      local run = (size.east and inner_h or inner_w) - size.along[l]
      local pos = run / 2
      for _, id in ipairs(ids) do
        local c = sizes[id]
        if size.east then
          place(graph, graph.by_id[id], sizes, boxes, inner_x + offset + (size.cross[l] - c.w) / 2, inner_y + pos)
          pos = pos + c.h + M.GAP_Y
        else
          place(graph, graph.by_id[id], sizes, boxes, inner_x + pos, inner_y + offset + (size.cross[l] - c.h) / 2)
          pos = pos + c.w + M.GAP_X
        end
      end
      offset = offset + size.cross[l] + (size.east and M.GAP_X or M.GAP_Y)
    end
  end
end

local function snap(v) return math.floor(v / route.CELL + 0.5) * route.CELL end

-- Returns {width, height, boxes, pipes, manifold}. Coordinates are logical
-- pixels in the plant drawing.
function M.layout(graph)
  local sizes, boxes = {}, {}
  local root = graph.by_id[graph.root]
  local w, h = measure(graph, root, sizes)
  local widest = 0
  for _, event in ipairs(graph.events) do widest = math.max(widest, text_width(event, 11)) end
  local ox, oy = snap(M.MARGIN + widest + 64 + 56), snap(M.MARGIN + 8)
  place(graph, root, sizes, boxes, ox, oy)
  -- Grid-align every box so routed pipes sit on cell centers symmetrically.
  for _, box in pairs(boxes) do box.x, box.y = snap(box.x), snap(box.y) end
  local plant = {graph=graph, boxes=boxes, width=snap(ox + w + M.MARGIN + 48), height=snap(oy + h + M.MARGIN + 24)}
  -- Instruments sit on tank corners: gauges top-right, pumps bottom-left.
  plant.gauges, plant.pumps = {}, {}
  for _, state in ipairs(graph.states) do
    local box = boxes[state.id]
    for i, a in ipairs(state.after) do
      plant.gauges[#plant.gauges+1] = {state=state.id, delay=a.delay, transition=a.transition,
        x=box.x + box.w - 6 - (i - 1) * 34, y=box.y + 2, r=15}
    end
    for i, v in ipairs(state.invoke) do
      plant.pumps[#plant.pumps+1] = {state=state.id, id=v.id, src=v.src, key=state.id .. '|' .. v.id,
        x=box.x + 4 + (i - 1) * 40, y=box.y + box.h - 2, r=15}
    end
  end
  -- Inlet manifold: a vertical header left of the root vessel, one nozzle
  -- per external event, feeding the root through a single pipe.
  local root_box = boxes[graph.root]
  local events = graph.events
  local spacing = 34
  local widest = 0
  for _, event in ipairs(events) do widest = math.max(widest, text_width(event, 11)) end
  local mx = snap(M.MARGIN + widest + 64)
  local top = snap(root_box.y + 40)
  plant.manifold = {x=mx, top=top, bottom=top + math.max(1, #events - 1) * spacing, nozzles={}}
  for i, event in ipairs(events) do
    plant.manifold.nozzles[i] = {event=event, x=mx - 52, y=top + (i - 1) * spacing}
  end
  local feed_y = snap((plant.manifold.top + plant.manifold.bottom) / 2)
  plant.manifold.feed = {{mx, feed_y}, {root_box.x, feed_y}}
  plant.height = math.max(plant.height, snap(plant.manifold.bottom + 60))
  plant.pipes = route.route_all(plant)
  M.place_labels(plant)
  return plant
end


-- Guarded labels wrap the guard onto a second line to stay narrow.
function M.pipe_text(t)
  if not t.guard then return t.label end
  local guard = '[' .. (t.guard == true and 'guard' or t.guard) .. ']'
  if utf8.len(t.label) + utf8.len(guard) > 14 then return t.label .. '\n' .. guard end
  return t.label .. ' ' .. guard
end

-- Valve body plus actuator: the stem points up on horizontal pipes and
-- left on vertical ones.
function M.valve_box(x, y, horizontal)
  if horizontal then return {x=x - 12, y=y - 24, w=24, h=36} end
  return {x=x - 24, y=y - 12, w=36, h=24}
end

local function overlap(a, b)
  local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
  local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
  return (w > 0 and h > 0) and w * h or 0
end

-- Greedy collision-avoiding placement of pipe labels and valves: candidates
-- sit beside every segment; boxes, headers, instruments, pipes and earlier
-- labels are penalized. Valves go on the segment the label chose.
function M.place_labels(plant)
  local hard, soft = {}, {}
  for id, b in pairs(plant.boxes) do
    if b.kind == 'atomic' or b.kind == 'final' then hard[#hard+1] = {x=b.x - 2, y=b.y - 2, w=b.w + 4, h=b.h + 4}
    elseif id ~= plant.graph.root then hard[#hard+1] = {x=b.x, y=b.y, w=b.w, h=b.header} end
  end
  for _, g in ipairs(plant.gauges) do hard[#hard+1] = {x=g.x - g.r - 22, y=g.y - g.r - 16, w=2 * g.r + 44, h=2 * g.r + 16} end
  for _, p in ipairs(plant.pumps) do
    local w = text_width(p.src .. ' · cancelled', 10)
    hard[#hard+1] = {x=p.x - p.r, y=p.y - p.r, w=2 * p.r + 8 + w, h=2 * p.r + 4}
  end
  for _, pipe in ipairs(plant.pipes) do
    for k = 1, #pipe.points - 1 do
      local a, b = pipe.points[k], pipe.points[k + 1]
      soft[#soft+1] = {x=math.min(a[1], b[1]) - 4, y=math.min(a[2], b[2]) - 4,
        w=math.abs(a[1] - b[1]) + 8, h=math.abs(a[2] - b[2]) + 8}
    end
  end
  local placed = {}
  local order = {}
  for _, pipe in ipairs(plant.pipes) do if pipe.first then order[#order+1] = pipe end end
  -- Valved pipes have the fewest good spots; place them first.
  table.sort(order, function(a, b)
    local ga, gb = a.transition.guard and 0 or 1, b.transition.guard and 0 or 1
    if ga ~= gb then return ga < gb end
    return a.transition.index < b.transition.index
  end)
  local function score_box(c)
    local score = 0
    for _, r in ipairs(hard) do score = score + overlap(c, r) * 200 end
    for _, r in ipairs(placed) do score = score + overlap(c, r) * 60 end
    for _, r in ipairs(soft) do score = score + overlap(c, r) * 3 end
    if c.x < 0 or c.y < 0 or c.x + c.w > plant.width or c.y + c.h > plant.height then score = score + 1e6 end
    return score
  end
  for _, pipe in ipairs(order) do
    local t = pipe.transition
    local text = M.pipe_text(t)
    if pipe.loop and #pipe.group > 1 then
      local names = {}
      for i, member in ipairs(pipe.group) do
        if i > 6 then names[#names+1] = '+' .. (#pipe.group - 6) .. ' more'; break end
        names[#names+1] = M.pipe_text(member):gsub('\n', ' ')
      end
      text = table.concat(names, '\n')
    end
    local w, lines = 0, 0
    for line in text:gmatch('[^\n]+') do w, lines = math.max(w, text_width(line, M.LABEL_SIZE) + 4), lines + 1 end
    local h = 14 * lines
    local valve = t.guard and not pipe.loop
    local best, best_score, best_valve
    local total = route.length(pipe.points)
    local walked = 0
    for k = 1, #pipe.points - 1 do
      local a, b = pipe.points[k], pipe.points[k + 1]
      local len = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2])
      local horizontal = a[2] == b[2]
      for _, f in ipairs(valve and {0.5, 0.3, 0.7} or {0.5}) do
        local mx, my = a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f
        local vbox = valve and M.valve_box(mx, my, horizontal)
        local base = math.abs(walked + len * f - total / 2) * 0.4 + (len < 40 and 400 or 0)
        if valve then
          base = base + score_box(vbox) * 2 + (len < 48 and 3000 or 0)
        end
        local candidates = {}
        if pipe.loop then
          candidates[1] = {x=math.max(a[1], b[1]) + 4, y=my - h / 2}
        elseif horizontal then
          local off = valve and 16 or 0
          for _, dx in ipairs({0, -w / 2 - off, w / 2 + off}) do
            candidates[#candidates+1] = {x=mx - w / 2 + dx, y=my - h - 5}
            candidates[#candidates+1] = {x=mx - w / 2 + dx, y=my + 6}
          end
        else
          for _, dy in ipairs({0, -h - 8, h + 8}) do
            candidates[#candidates+1] = {x=mx + 8, y=my - h / 2 + dy}
            candidates[#candidates+1] = {x=mx - w - (valve and 26 or 8), y=my - h / 2 + dy}
          end
        end
        for _, c in ipairs(candidates) do
          c.w, c.h = w, h
          local score = base + score_box(c) + (vbox and overlap(c, vbox) * 60 or 0)
          if not best_score or score < best_score then
            best, best_score = c, score
            best_valve = {anchor={mx, my}, horizontal=horizontal, box=vbox}
          end
        end
      end
      walked = walked + len
    end
    pipe.label_box, pipe.label_text = best, text
    pipe.anchor, pipe.horizontal = best_valve.anchor, best_valve.horizontal
    placed[#placed+1] = best
    if valve then placed[#placed+1] = best_valve.box end
  end
end

return M
