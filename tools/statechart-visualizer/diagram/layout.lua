-- Lays a normalized statechart graph out in Harel/SCXML notation: atomic
-- states are rounded boxes sized to their content (key, entry/exit actions,
-- invokes), compound states contain their children under a title, parallel
-- states hold regions separated by dashed lines. Siblings are layered by
-- breadth-first distance from the initial child, east or south, whichever
-- fits the drawing's aspect ratio. Transitions are routed by diagram.route.
local route = require('diagram.route')

local M = {}

M.MIN_W, M.MIN_H = 112, 44
M.PAD, M.HEADER, M.REGION_HEADER = 26, 30, 24
M.GAP_X, M.GAP_Y = 168, 100
M.MARGIN = 24
M.TITLE_SIZE, M.LINE_SIZE, M.LINE_H = 13, 11, 15

-- Monospace label metrics (DejaVu Sans Mono advance is 0.602 em).
M.LABEL_SIZE = 11
local function text_width(text, size) return utf8.len(text) * size * 0.602 end
M.text_width = text_width

-- The lines drawn inside an atomic or final state, Stately style.
function M.state_lines(state)
  local lines = {}
  for _, name in ipairs(state.entry or {}) do lines[#lines+1] = {kind='entry', text='entry / ' .. name} end
  for _, name in ipairs(state.exit or {}) do lines[#lines+1] = {kind='exit', text='exit / ' .. name} end
  for _, v in ipairs(state.invoke) do
    lines[#lines+1] = {kind='invoke', text='invoke: ' .. v.src, invoke=v, key=state.id .. '|' .. v.id}
  end
  return lines
end

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
M.ASPECT = 1.5

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
    local lines = M.state_lines(state)
    local w = math.max(M.MIN_W, text_width(state.label, M.TITLE_SIZE) + 32)
    -- Invoke lines carry a status chip of up to "cancelled".
    for _, line in ipairs(lines) do
      w = math.max(w, text_width(line.text, M.LINE_SIZE) + (line.invoke and 84 or 24))
    end
    local h = math.max(M.MIN_H, 30 + #lines * M.LINE_H + (#lines > 0 and 8 or 0))
    w, h = math.ceil(w / route.CELL) * route.CELL, math.ceil(h / route.CELL) * route.CELL
    sizes[state.id] = {w=w, h=h, lines=lines}
    return w, h
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
  local stacked = misfit(mw, mh + header) + 0.1 < misfit(rw, rh + header)
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

-- Returns {width, height, boxes, pipes, initials}. Coordinates are logical
-- pixels in the drawing.
function M.layout(graph)
  local sizes, boxes = {}, {}
  local root = graph.by_id[graph.root]
  local w, h = measure(graph, root, sizes)
  local ox, oy = snap(M.MARGIN), snap(M.MARGIN)
  place(graph, root, sizes, boxes, ox, oy)
  -- Grid-align every box so routed arrows sit on cell centers symmetrically.
  for id, box in pairs(boxes) do
    box.x, box.y = snap(box.x), snap(box.y)
    box.lines = sizes[id].lines
  end
  local plant = {graph=graph, boxes=boxes, width=snap(ox + w + M.MARGIN + 48), height=snap(oy + h + M.MARGIN + 24),
    gauges={}, pumps={}}
  -- Initial pseudostates: a dot above the initial child of every compound.
  plant.initials = {}
  for _, state in ipairs(graph.states) do
    if state.kind == 'compound' and state.initial and boxes[state.initial] then
      local child = boxes[state.initial]
      plant.initials[#plant.initials+1] = {state=state.id, target=state.initial,
        x=child.x + 18, y=child.y - 18, to={child.x + 18, child.y}}
    end
  end
  plant.pipes = route.route_all(plant)
  M.place_labels(plant)
  return plant
end

-- Pill text: the event label and, separately, the guard (colored by outcome).
function M.pill(t)
  return {event=t.label, guard=t.guard and ('[' .. (t.guard == true and 'guard' or t.guard) .. ']') or nil, transition=t}
end

local function pill_width(p)
  -- After pills leave room for their running countdown (" · 99.9s").
  local extra = (p.transition and p.transition.after_event) and ' · 99.9s' or ''
  return text_width(p.event .. extra .. (p.guard and (' ' .. p.guard) or ''), M.LABEL_SIZE) + 14
end
M.pill_width = pill_width
M.PILL_H = 18

local function overlap(a, b)
  local w = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
  local h = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
  return (w > 0 and h > 0) and w * h or 0
end

-- Greedy collision-avoiding placement of transition pills: candidates sit
-- beside every segment; boxes, titles, arrows and earlier pills are
-- penalized. A recirculation loop lists one pill per transition.
function M.place_labels(plant)
  local hard, soft = {}, {}
  for id, b in pairs(plant.boxes) do
    if b.kind == 'atomic' or b.kind == 'final' then hard[#hard+1] = {x=b.x - 2, y=b.y - 2, w=b.w + 4, h=b.h + 4}
    elseif id ~= plant.graph.root then hard[#hard+1] = {x=b.x, y=b.y, w=b.w, h=b.header} end
  end
  for _, i in ipairs(plant.initials) do hard[#hard+1] = {x=i.x - 8, y=i.y - 8, w=16, h=26} end
  -- Small self loops are as hard to read through as boxes.
  for _, pipe in ipairs(plant.pipes) do
    for k = 1, #pipe.points - 1 do
      local a, b = pipe.points[k], pipe.points[k + 1]
      local list = pipe.top and hard or soft
      list[#list+1] = {x=math.min(a[1], b[1]) - 4, y=math.min(a[2], b[2]) - 4,
        w=math.abs(a[1] - b[1]) + 8, h=math.abs(a[2] - b[2]) + 8}
    end
  end
  local placed = {}
  local function score_box(c)
    local score = 0
    for _, r in ipairs(hard) do score = score + overlap(c, r) * 200 end
    for _, r in ipairs(placed) do score = score + overlap(c, r) * 60 end
    for _, r in ipairs(soft) do score = score + overlap(c, r) * 3 end
    if c.x < 0 or c.y < 0 or c.x + c.w > plant.width or c.y + c.h > plant.height then score = score + 1e6 end
    return score
  end
  -- Loops have the fewest good spots; place their pills first.
  local order = {}
  for _, pipe in ipairs(plant.pipes) do if pipe.first then order[#order+1] = pipe end end
  table.sort(order, function(a, b)
    if (a.loop and 0 or 1) ~= (b.loop and 0 or 1) then return a.loop ~= nil end
    return a.transition.index < b.transition.index
  end)
  -- The lowest compound (or parallel region) holding both ends: a pill that
  -- leaves it reads as belonging to a neighbouring region.
  local graph = plant.graph
  local function container(t, target)
    local ancestors = {}
    local s = graph.by_id[t.source]
    while s do ancestors[s.id] = true; s = s.parent and graph.by_id[s.parent] end
    local e = graph.by_id[target]
    if target == t.source then e = e.parent and graph.by_id[e.parent] end
    while e and not ancestors[e.id] do e = e.parent and graph.by_id[e.parent] end
    if e and target ~= t.source and e.id == t.source then e = e.parent and graph.by_id[e.parent] end
    return e and plant.boxes[e.id]
  end
  for _, pipe in ipairs(order) do
    do
      local box = container(pipe.transition, pipe.target)
      local function outside(c)
        if not box then return 0 end
        return c.w * c.h - overlap(c, {x=box.x + 2, y=box.y + 2, w=box.w - 4, h=box.h - 4})
      end
      local pills = {}
      for i, member in ipairs(pipe.group) do
        if i > 6 then pills[#pills+1] = {event='+' .. (#pipe.group - 6) .. ' more'}; break end
        pills[#pills+1] = M.pill(member)
      end
      local w = 0
      for _, p in ipairs(pills) do w = math.max(w, pill_width(p)) end
      local h = #pills * (M.PILL_H + 3) - 3
      local best, best_score
      local total = route.length(pipe.points)
      local walked = 0
      for k = 1, #pipe.points - 1 do
        local a, b = pipe.points[k], pipe.points[k + 1]
        local len = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2])
        local horizontal = a[2] == b[2]
        local mx, my = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
        local base = math.abs(walked + len / 2 - total / 2) * 0.4 + (len < 40 and 400 or 0)
        local candidates = {}
        if pipe.loop and pipe.top then
          candidates[1] = {x=pipe.points[1][1] - 4, y=pipe.points[2][2] - h - 3}
          candidates[2] = {x=pipe.points[4][1] + 6, y=pipe.points[2][2] - h / 2}
          candidates[3] = {x=pipe.points[4][1] + 4 - w, y=pipe.points[2][2] - h - 3}
          candidates[4] = {x=(pipe.points[1][1] + pipe.points[4][1] - w) / 2, y=pipe.points[2][2] - h - 3}
        elseif pipe.loop then
          candidates[1] = {x=math.max(a[1], b[1]) + 6, y=my - h / 2}
        elseif horizontal then
          for _, dx in ipairs({0, -w / 2 - 8, w / 2 + 8}) do
            candidates[#candidates+1] = {x=mx - w / 2 + dx, y=my - h - 4}
            candidates[#candidates+1] = {x=mx - w / 2 + dx, y=my + 4}
            candidates[#candidates+1] = {x=mx - w / 2 + dx, y=my - h / 2}
          end
        else
          for _, dy in ipairs({0, -h - 8, h + 8}) do
            candidates[#candidates+1] = {x=mx + 6, y=my - h / 2 + dy}
            candidates[#candidates+1] = {x=mx - w - 6, y=my - h / 2 + dy}
            candidates[#candidates+1] = {x=mx - w / 2, y=my - h / 2 + dy}
          end
        end
        for _, c in ipairs(candidates) do
          c.w, c.h = w, h
          local score = base + score_box(c) + outside(c) * 150
          if not best_score or score < best_score then best, best_score = c, score end
        end
        walked = walked + len
      end
      pipe.label_box, pipe.pills = best, pills
      placed[#placed+1] = best
    end
  end
  -- Root loops have no in-bounds spot; grow the canvas to keep them whole.
  for _, r in ipairs(placed) do
    plant.width = math.max(plant.width, math.ceil(r.x + r.w + 4))
    plant.height = math.max(plant.height, math.ceil(r.y + r.h + 4))
  end
end

return M
