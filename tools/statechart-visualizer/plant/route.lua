-- Orthogonal pipe routing on an 8 px grid. Each transition is routed with A*
-- over (node, heading) states: tanks and instruments block, vessel walls and
-- headers are expensive to cross, bends cost extra, and every routed pipe
-- raises the cost of its cells so later pipes run beside it instead of on it.
local M = {}
M.CELL = 8

local INF = math.huge
local DX, DY = {1, 0, -1, 0}, {0, 1, 0, -1}   -- E S W N
local BEND, WALL, NEAR_WALL, HEADER, TANK_MARGIN, OCCUPIED, NEIGHBOR, OUTSIDE, LABEL = 10, 30, 3, 14, 5, 14, 5, 60, 12

local function new_heap() return {keys={}, vals={}, n=0} end

local function push(h, key, val)
  local n = h.n + 1
  h.n = n
  local keys, vals = h.keys, h.vals
  while n > 1 do
    local p = n // 2
    if keys[p] <= key then break end
    keys[n], vals[n] = keys[p], vals[p]
    n = p
  end
  keys[n], vals[n] = key, val
end

local function pop(h)
  local keys, vals = h.keys, h.vals
  local top = vals[1]
  local key, val = keys[h.n], vals[h.n]
  keys[h.n], vals[h.n] = nil, nil
  h.n = h.n - 1
  local n, size = 1, h.n
  while true do
    local c = n * 2
    if c > size then break end
    if c < size and keys[c + 1] < keys[c] then c = c + 1 end
    if key <= keys[c] then break end
    keys[n], vals[n] = keys[c], vals[c]
    n = c
  end
  if size > 0 then keys[n], vals[n] = key, val end
  return top
end

local function contains(outer, inner)
  return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.w <= outer.x + outer.w
    and inner.y + inner.h <= outer.y + outer.h and outer ~= inner
end

-- Cost grid: node (i, j) sits at (i * CELL, j * CELL).
local function build_grid(plant)
  local C = M.CELL
  local cols, rows = plant.width // C + 1, plant.height // C + 1
  local cost = {}
  for n = 0, cols * rows - 1 do cost[n] = 1 end
  local function add(i, j, v)
    if i >= 0 and j >= 0 and i < cols and j < rows then
      local n = j * cols + i
      cost[n] = cost[n] + v
    end
  end
  local function block(i, j)
    if i >= 0 and j >= 0 and i < cols and j < rows then cost[j * cols + i] = INF end
  end
  local root = plant.boxes[plant.graph.root]
  for j = 0, rows - 1 do
    for i = 0, cols - 1 do
      local x, y = i * C, j * C
      if x <= root.x or y <= root.y or x >= root.x + root.w or y >= root.y + root.h then add(i, j, OUTSIDE) end
    end
  end
  for id, b in pairs(plant.boxes) do
    local i0, j0, i1, j1 = b.x // C, b.y // C, (b.x + b.w) // C, (b.y + b.h) // C
    if b.kind == 'atomic' or b.kind == 'final' then
      for j = j0 - 1, j1 + 1 do for i = i0 - 1, i1 + 1 do
        if i >= i0 and i <= i1 and j >= j0 and j <= j1 then block(i, j) else add(i, j, TANK_MARGIN) end
      end end
    elseif id ~= plant.graph.root then
      for i = i0, i1 do
        add(i, j0, WALL); add(i, j1, WALL); add(i, j0 + 1, NEAR_WALL); add(i, j1 - 1, NEAR_WALL)
        add(i, j0 - 1, NEAR_WALL); add(i, j1 + 1, NEAR_WALL)
      end
      for j = j0 + 1, j1 - 1 do
        add(i0, j, WALL); add(i1, j, WALL); add(i0 + 1, j, NEAR_WALL); add(i1 - 1, j, NEAR_WALL)
        add(i0 - 1, j, NEAR_WALL); add(i1 + 1, j, NEAR_WALL)
      end
      for j = j0 + 1, j0 + b.header // C do for i = i0 + 1, i1 - 1 do add(i, j, HEADER) end end
    end
  end
  for _, list in ipairs({plant.gauges, plant.pumps}) do
    for _, g in ipairs(list) do
      local r = g.r + 6
      for j = (g.y - r) // C, (g.y + r) // C + 1 do for i = (g.x - r) // C, (g.x + r) // C + 1 do
        local dx, dy = i * C - g.x, j * C - g.y
        if dx * dx + dy * dy <= r * r then block(i, j) end
      end end
    end
  end
  -- Instrument readouts: gauge times above dials, pump captions beside pumps.
  local function soft_rect(x0, y0, x1, y1)
    for j = y0 // C, y1 // C + 1 do for i = x0 // C, x1 // C + 1 do add(i, j, LABEL) end end
  end
  for _, g in ipairs(plant.gauges) do soft_rect(g.x - 22, g.y - g.r - 16, g.x + 22, g.y - g.r) end
  for _, p in ipairs(plant.pumps) do soft_rect(p.x + p.r + 6, p.y - 2, p.x + p.r + 6 + 6 * (#p.src + 12), p.y + 12) end
  return {cost=cost, cols=cols, rows=rows}
end

-- Ring of nodes one cell outside (or inside) a box, with the heading that
-- leaves (or enters) it. `inside` is used when the other end is nested.
local function ring(b, inside, top_inset)
  local C, nodes = M.CELL, {}
  local i0, j0, i1, j1 = b.x // C, b.y // C, (b.x + b.w) // C, (b.y + b.h) // C
  local o = inside and 1 or -1
  local jt = inside and (j0 + (top_inset or 0) // C + 1) or j0 - 1
  local cx, cy = (i0 + i1) / 2, (j0 + j1) / 2
  for i = i0 + 2, i1 - 2 do
    nodes[#nodes+1] = {i=i, j=jt, out=inside and 2 or 4, edge={i * C, b.y}, bias=math.abs(i - cx)}
    nodes[#nodes+1] = {i=i, j=j1 - o, out=inside and 4 or 2, edge={i * C, b.y + b.h}, bias=math.abs(i - cx)}
  end
  for j = math.max(j0 + 2, inside and jt + 1 or 0), j1 - 2 do
    nodes[#nodes+1] = {i=i0 + o, j=j, out=inside and 1 or 3, edge={b.x, j * C}, bias=math.abs(j - cy)}
    nodes[#nodes+1] = {i=i1 - o, j=j, out=inside and 3 or 1, edge={b.x + b.w, j * C}, bias=math.abs(j - cy)}
  end
  return nodes
end

local function opposite(d) return (d + 1) % 4 + 1 end

local function astar(grid, from, to)
  local cols, rows, cost = grid.cols, grid.rows, grid.cost
  local g, came = {}, {}
  local heap = new_heap()
  local goals = {}
  local gx0, gy0, gx1, gy1 = INF, INF, -INF, -INF
  for _, node in ipairs(to) do
    -- Arrive heading into the target: opposite of the ring's outward heading.
    goals[node.j * cols + node.i] = {dir=opposite(node.out), node=node}
    gx0, gy0 = math.min(gx0, node.i), math.min(gy0, node.j)
    gx1, gy1 = math.max(gx1, node.i), math.max(gy1, node.j)
  end
  local function h(i, j)
    local dx = i < gx0 and gx0 - i or (i > gx1 and i - gx1 or 0)
    local dy = j < gy0 and gy0 - j or (j > gy1 and j - gy1 or 0)
    return dx + dy
  end
  local starts = {}
  for _, node in ipairs(from) do
    if node.i >= 0 and node.j >= 0 and node.i < cols and node.j < rows then
      local n = node.j * cols + node.i
      if cost[n] < INF then
        local s = n * 4 + node.out - 1
        local initial = node.bias * 0.5
        if g[s] == nil or initial < g[s] then
          g[s], starts[s] = initial, node
          push(heap, initial + h(node.i, node.j), s)
        end
      end
    end
  end
  local closed = {}
  while heap.n > 0 do
    local s = pop(heap)
    if not closed[s] then
      closed[s] = true
      local n, d = s // 4, s % 4 + 1
      local i, j = n % cols, n // cols
      local goal = goals[n]
      if goal and goal.dir == d then
        local path, cur = {}, s
        while cur do table.insert(path, 1, cur); cur = came[cur] end
        return path, starts[path[1]], goal.node
      end
      for nd = 1, 4 do
        if nd ~= opposite(d) then
          local ni, nj = i + DX[nd], j + DY[nd]
          if ni >= 0 and nj >= 0 and ni < cols and nj < rows then
            local nn = nj * cols + ni
            local step = cost[nn]
            if step < INF then
              local ns = nn * 4 + nd - 1
              local cand = g[s] + step + (nd ~= d and BEND or 0)
              if not closed[ns] and (g[ns] == nil or cand < g[ns]) then
                g[ns], came[ns] = cand, s
                push(heap, cand + h(ni, nj), ns)
              end
            end
          end
        end
      end
    end
  end
end

local function simplify(points)
  local out = {}
  for _, p in ipairs(points) do
    local n = #out
    if n >= 2 then
      local a, b = out[n - 1], out[n]
      if (a[1] == b[1] and b[1] == p[1]) or (a[2] == b[2] and b[2] == p[2]) then out[n] = p
      elseif not (b[1] == p[1] and b[2] == p[2]) then out[n + 1] = p end
    elseif n == 0 or not (out[n][1] == p[1] and out[n][2] == p[2]) then
      out[n + 1] = p
    end
  end
  return out
end

local function occupy(grid, points)
  local C, cols = M.CELL, grid.cols
  for k = 1, #points - 1 do
    local a, b = points[k], points[k + 1]
    local i0, j0, i1, j1 = a[1] // C, a[2] // C, b[1] // C, b[2] // C
    local si, sj = i1 > i0 and 1 or (i1 < i0 and -1 or 0), j1 > j0 and 1 or (j1 < j0 and -1 or 0)
    local i, j = i0, j0
    while true do
      if i >= 0 and j >= 0 and i < cols and j < grid.rows then
        local n = j * cols + i
        if grid.cost[n] < INF then grid.cost[n] = grid.cost[n] + OCCUPIED end
        -- Neighbours too, so parallel pipes keep a 16 px pitch when they can.
        for _, d in ipairs(si ~= 0 and {-cols, cols} or {-1, 1}) do
          local m = n + d
          if m >= 0 and m < cols * grid.rows and grid.cost[m] < INF then grid.cost[m] = grid.cost[m] + NEIGHBOR end
        end
      end
      if i == i1 and j == j1 then break end
      i, j = i + si, j + sj
    end
  end
end

-- Label anchor: midpoint of the longest segment and its orientation.
function M.anchor(points)
  local best, at, horizontal = -1, nil, true
  for k = 1, #points - 1 do
    local a, b = points[k], points[k + 1]
    local len = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2])
    if len > best then best, at, horizontal = len, {(a[1] + b[1]) / 2, (a[2] + b[2]) / 2}, a[2] == b[2] end
  end
  return at, horizontal, best
end

function M.length(points)
  local total = 0
  for k = 1, #points - 1 do
    total = total + math.abs(points[k][1] - points[k + 1][1]) + math.abs(points[k][2] - points[k + 1][2])
  end
  return total
end

-- Point at distance d along the polyline, and its heading.
function M.at(points, d)
  for k = 1, #points - 1 do
    local a, b = points[k], points[k + 1]
    local len = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2])
    if d <= len or k == #points - 1 then
      local f = len > 0 and math.min(1, d / len) or 0
      return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, b[1] - a[1], b[2] - a[2]
    end
    d = d - len
  end
  local p = points[#points]
  return p[1], p[2], 1, 0
end

function M.route_all(plant)
  local grid = build_grid(plant)
  local boxes, graph = plant.boxes, plant.graph
  local pipes, loops, jobs = {}, {}, {}
  for _, t in ipairs(graph.transitions) do
    local targets = #t.targets > 0 and t.targets or {t.source}
    for k, target in ipairs(targets) do
      if target == t.source then
        -- Every targetless or self transition of a state shares one
        -- recirculation loop on its right wall.
        local loop = loops[t.source]
        if loop then
          table.insert(loop.group, t)
        else
          local b = boxes[t.source]
          local x0, x1 = b.x + b.w, b.x + b.w + 16
          local points = {{x0, b.y + 24}, {x1, b.y + 24}, {x1, b.y + b.h - 24}, {x0, b.y + b.h - 24}}
          occupy(grid, points)
          loop = {transition=t, group={t}, target=target, first=true, loop=true, points=points}
          loops[t.source] = loop
          pipes[#pipes+1] = loop
        end
      else
        local s, e = boxes[t.source], boxes[target]
        jobs[#jobs+1] = {t=t, target=target, first=k == 1,
          dist=math.abs(s.x + s.w / 2 - e.x - e.w / 2) + math.abs(s.y + s.h / 2 - e.y - e.h / 2)}
      end
    end
  end
  table.sort(jobs, function(a, b) return a.dist < b.dist end)
  for _, job in ipairs(jobs) do
    local s, e = boxes[job.t.source], boxes[job.target]
    local from = ring(s, contains(s, e), s.header)
    local to = ring(e, contains(e, s), e.header)
    local path, start, finish = astar(grid, from, to)
    local points
    if path then
      points = {start.edge}
      for _, st in ipairs(path) do
        local n = st // 4
        points[#points+1] = {(n % grid.cols) * M.CELL, (n // grid.cols) * M.CELL}
      end
      points[#points+1] = finish.edge
      points = simplify(points)
    else
      -- Unroutable: a straight dog-leg keeps the transition visible.
      local ax, ay, bx, by = s.x + s.w, s.y + s.h / 2, e.x, e.y + e.h / 2
      points = {{ax, ay}, {(ax + bx) / 2, ay}, {(ax + bx) / 2, by}, {bx, by}}
    end
    occupy(grid, points)
    pipes[#pipes+1] = {transition=job.t, group={job.t}, target=job.target, first=job.first, points=points}
  end
  table.sort(pipes, function(a, b) return a.transition.index < b.transition.index end)
  for _, pipe in ipairs(pipes) do
    pipe.length = M.length(pipe.points)
    pipe.anchor, pipe.horizontal = M.anchor(pipe.points)
  end
  return pipes
end

return M
