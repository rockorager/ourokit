-- The system overview (ISA-101 high-performance HMI, Level 1/2): one tile
-- per actor, parent/child lines, traffic between actors and I/O endpoints
-- (invoke and task srcs), and the alarm list. Normal operation is grey;
-- colour marks only abnormal conditions: red for failures, amber for stuck
-- states, a brief amber flash for rejected events. Pure function of the
-- visualizer chart and the model; clicks send events.
local o = require('ouro')
local draw = require('diagram.draw')
local overview = require('overview')

local M = {}

local TILE_W, TILE_H, GAP_X, GAP_Y, INDENT, PAD, TOP = 232, 86, 44, 20, 22, 24, 30
local EP_W, EP_H, EP_GAP = 128, 30, 22
local MAX_TILES = 24
local FLASH_MS = 2000

local function short(id) return id:match('[^.]+%.[^.]+$') or id end

-- Stable placement: columns in first-seen order (roots, then component
-- groups), children below their parent, endpoints in a row underneath.
function M.layout(store)
  local kids, columns, groups = {}, {}, {}
  for _, path in ipairs(store.order) do
    local e = store.actors[path]
    if e.parent and store.actors[e.parent] then
      kids[e.parent] = kids[e.parent] or {}
      table.insert(kids[e.parent], path)
    end
  end
  local placed = 0
  local function add(column, path, depth)
    if placed >= MAX_TILES then column.more = (column.more or 0) + 1; return end
    placed = placed + 1
    column.items[#column.items + 1] = {path = path, depth = depth}
    for _, child in ipairs(kids[path] or {}) do add(column, child, depth + 1) end
  end
  for _, path in ipairs(store.order) do
    local e = store.actors[path]
    if not (e.parent and store.actors[e.parent]) then
      local instance = path:match('@(.+)$')
      if instance then
        local g = instance:match('^([^/#]+)') or instance
        if not groups[g] then
          groups[g] = {title = 'components · ' .. g, items = {}}
          columns[#columns + 1] = groups[g]
        end
        add(groups[g], path, 0)
      else
        local column = {items = {}}
        columns[#columns + 1] = column
        add(column, path, 0)
      end
    end
  end
  local tiles, by_path, bottom, right = {}, {}, PAD + TOP, PAD
  for i, column in ipairs(columns) do
    local x = PAD + (i - 1) * (TILE_W + GAP_X)
    column.x = x
    for j, item in ipairs(column.items) do
      local t = {path = item.path, depth = item.depth, x = x + item.depth * INDENT,
        y = PAD + TOP + (j - 1) * (TILE_H + GAP_Y), w = TILE_W - item.depth * INDENT, h = TILE_H, column = i}
      tiles[#tiles + 1], by_path[item.path] = t, t
      bottom = math.max(bottom, t.y + t.h)
    end
    right = x + TILE_W
  end
  local ep_y = bottom + 74
  local endpoints = {}
  for k, src in ipairs(store.endpoint_order) do
    local e = {src = src, kind = store.endpoints[src].kind, x = PAD + (k - 1) * (EP_W + EP_GAP), y = ep_y, w = EP_W, h = EP_H}
    endpoints[k], endpoints[src] = e, e
    right = math.max(right, e.x + EP_W)
  end
  return {tiles = tiles, by_path = by_path, columns = columns, endpoints = endpoints,
    width = right + PAD + 40, height = ep_y + EP_H + PAD + (#store.endpoint_order > 0 and 10 or -EP_H - 60)}
end

local function frame_of(entry) return entry.history.frames[#entry.history.frames] end

-- Unacknowledged invoke failures per unit and src, for red endpoint lines.
local function failing(store, acked)
  local out = {}
  for _, a in ipairs(store.alarms) do
    if a.src and not acked[tostring(a.id)] then out[a.actor .. '|' .. a.src] = true; out['|' .. a.src] = true end
  end
  return out
end

local function canvas_commands(store, L, P, acked, now)
  local cmds = {}
  local bad = failing(store, acked)
  local function stroke(points, color, width)
    cmds[#cmds + 1] = {kind = 'stroke', color = color, width = width or 1.5, join = 'round', cap = 'round',
      path = draw.arrow_path(points, 6)}
  end
  -- Component group frames.
  for _, column in ipairs(L.columns) do
    if column.title and #column.items > 0 then
      local last = column.items[#column.items]
      local tile = L.by_path[last.path]
      local x, y, w, h = column.x - 8, PAD + TOP - 26, TILE_W + 16, tile.y + tile.h - (PAD + TOP) + 34
      draw.dashed(cmds, P.tile_edge, x, y, x + w, y); draw.dashed(cmds, P.tile_edge, x + w, y, x + w, y + h)
      draw.dashed(cmds, P.tile_edge, x + w, y + h, x, y + h); draw.dashed(cmds, P.tile_edge, x, y + h, x, y)
    end
  end
  -- Parent/child: elbows from the parent's left edge.
  for _, t in ipairs(L.tiles) do
    local entry = store.actors[t.path]
    local parent = entry.parent and L.by_path[entry.parent]
    if parent then stroke({{parent.x + 12, parent.y + parent.h}, {parent.x + 12, t.y + t.h / 2}, {t.x, t.y + t.h / 2}}, P.line) end
  end
  -- Actor traffic (sends, children reporting back): dashed, on the right.
  for lane, key in ipairs(store.traffic_order) do
    local l = store.traffic[key]
    local a, b = L.by_path[l.from], L.by_path[l.to]
    if a and b then
      local x = math.max(a.x + a.w, b.x + b.w) + 10 + (lane % 4) * 6
      local ya, yb = a.y + a.h / 2 + 8, b.y + b.h / 2 - 8
      draw.dashed(cmds, P.line, a.x + a.w, ya, x, ya); draw.dashed(cmds, P.line, x, ya, x, yb)
      draw.dashed(cmds, P.line, x, yb, b.x + b.w + 6, yb)
      draw.arrowhead(cmds, {{x, yb}, {b.x + b.w, yb}}, P.line, 6)
    end
  end
  -- I/O bus: a stub from each unit that uses I/O to its column's trunk,
  -- trunks down to one bus above the endpoint row, one drop per endpoint.
  -- Stubs and drops darken while an invoke runs and turn red on failure.
  local running_src, unit_running = {}, {}
  for _, t in ipairs(L.tiles) do
    local frame = frame_of(store.actors[t.path])
    if frame then
      for _, pump in pairs(frame.pumps) do
        if pump.status == 'running' and frame.active[pump.state] then
          running_src[pump.src or ''] = true
          unit_running[t.path] = true
        end
      end
    end
  end
  local bus_y = (L.endpoints[1] and L.endpoints[1].y or 0) - 28
  local trunks, bus_min, bus_max = {}, nil, nil
  for _, t in ipairs(L.tiles) do
    local entry = store.actors[t.path]
    if next(entry.uses or {}) and L.endpoints[1] then
      local trunk = L.columns[t.column].x + TILE_W + 14
      local y = t.y + 20
      local failed = false
      for src in pairs(entry.uses) do if bad[t.path .. '|' .. src] then failed = true end end
      local color = failed and P.high or (unit_running[t.path] and P.line_live or P.line)
      stroke({{t.x + t.w, y}, {trunk, y}}, color, (failed or unit_running[t.path]) and 2 or 1.2)
      local tr = trunks[t.column] or {x = trunk, top = y}
      tr.top = math.min(tr.top, y)
      trunks[t.column] = tr
    end
  end
  for _, tr in pairs(trunks) do
    stroke({{tr.x, tr.top}, {tr.x, bus_y}}, P.line, 1.2)
    bus_min, bus_max = math.min(bus_min or tr.x, tr.x), math.max(bus_max or tr.x, tr.x)
  end
  for _, ep in ipairs(L.endpoints) do
    local x = ep.x + ep.w / 2
    bus_min, bus_max = math.min(bus_min or x, x), math.max(bus_max or x, x)
    local color = bad['|' .. ep.src] and P.high or (running_src[ep.src] and P.line_live or P.line)
    stroke({{x, bus_y}, {x, ep.y}}, color, color ~= P.line and 2 or 1.2)
  end
  if bus_min then stroke({{bus_min, bus_y}, {bus_max, bus_y}}, P.line, 1.2) end
  -- Endpoints: external I/O, drawn as open-ended boxes.
  for _, ep in ipairs(L.endpoints) do
    local color = bad['|' .. ep.src] and P.high or P.tile_edge
    cmds[#cmds + 1] = {kind = 'fill', color = P.tile, path = draw.rounded(ep.x, ep.y, ep.w, ep.h, 4)}
    cmds[#cmds + 1] = {kind = 'stroke', color = color, width = color == P.high and 2 or 1.2, path = draw.rounded(ep.x, ep.y, ep.w, ep.h, 4)}
    cmds[#cmds + 1] = {kind = 'stroke', color = color, width = 1.2, path = {{'move', ep.x + 8, ep.y + 5}, {'line', ep.x + 8, ep.y + ep.h - 5}}}
  end
  -- Tiles, in passes (compact() paints each merged style where it first
  -- appears): fills, badges, edges, then sparklines.
  local severities = {}
  for i, t in ipairs(L.tiles) do
    local severity = overview.severity(store, t.path, acked)
    severities[i] = severity
    local fill = severity == 'high' and P.high_soft or severity == 'medium' and P.medium_soft or P.tile
    cmds[#cmds + 1] = {kind = 'fill', color = fill, path = draw.rounded(t.x, t.y, t.w, t.h, 6)}
  end
  for _, t in ipairs(L.tiles) do
    local entry = store.actors[t.path]
    cmds[#cmds + 1] = {kind = 'fill', color = entry.stopped and P.hmi or P.badge, path = draw.rounded(t.x + 10, t.y + 28, t.w - 20, 20, 10)}
  end
  for i, t in ipairs(L.tiles) do
    local severity = severities[i]
    local edge = severity == 'high' and P.high or severity == 'medium' and P.medium or P.tile_edge
    cmds[#cmds + 1] = {kind = 'stroke', color = edge, width = severity and 2.5 or 1.2, path = draw.rounded(t.x, t.y, t.w, t.h, 6)}
    if severity then cmds[#cmds + 1] = {kind = 'fill', color = edge, path = draw.rounded(t.x, t.y, 6, t.h, 3)} end
  end
  for _, t in ipairs(L.tiles) do
    local entry = store.actors[t.path]
    -- Event-rate sparkline, last 30 s.
    local counts = overview.rate(entry, now, 30000, 15)
    local peak = 1
    for _, n in ipairs(counts) do peak = math.max(peak, n) end
    local sx, sy, sw, sh = t.x + t.w - 78, t.y + t.h - 22, 66, 14
    local path = {}
    for i, n in ipairs(counts) do
      local x, y = sx + (i - 1) * sw / (#counts - 1), sy + sh - n / peak * sh
      path[#path + 1] = {i == 1 and 'move' or 'line', x, y}
    end
    cmds[#cmds + 1] = {kind = 'stroke', color = P.line_live, width = 1.2, join = 'round', path = path}
  end
  return draw.compact(cmds)
end

local function label(key, x, y, w, spans, size)
  return o.text {key = key, positioned = {left = x, top = y, width = w}, spans = spans, size = size or 11,
    max_lines = 1, overflow = 'ellipsis'}
end

-- The topology: canvas, tile and endpoint labels, click targets, flashes.
function M.topology(viz, c, store, P, now, opts)
  local L = M.layout(store)
  local acked = c.acked or {}
  local layers = {o.canvas {key = 'lines', drawing = o.drawing {width = L.width, height = L.height,
    commands = canvas_commands(store, L, P, acked, now)}, alt = 'Actor system overview'}}
  for i, column in ipairs(L.columns) do
    if column.title then
      layers[#layers + 1] = label('g' .. i, column.x, PAD + TOP - 22, TILE_W, {{text = column.title, foreground = P.muted}}, 10)
    end
    if column.more then
      local last = L.by_path[column.items[#column.items].path]
      layers[#layers + 1] = label('more' .. i, column.x, last.y + last.h + 6, TILE_W,
        {{text = '+' .. column.more .. ' more', foreground = P.muted}}, 10)
    end
  end
  for i, t in ipairs(L.tiles) do
    local entry = store.actors[t.path]
    local frame = frame_of(entry)
    local severity = overview.severity(store, t.path, acked)
    local states = {}
    if frame then for _, id in ipairs(overview.leaves(entry.graph, frame.active)) do states[#states + 1] = short(id) end end
    local timers, invokes = 0, 0
    if frame then
      for _ in pairs(frame.timers) do timers = timers + 1 end
      for _, pump in pairs(frame.pumps) do if pump.status == 'running' and frame.active[pump.state] then invokes = invokes + 1 end end
    end
    local title = {{text = t.path, foreground = P.text}}
    if entry.machine ~= t.path:match('[^/@]+$') and entry.machine ~= t.path then
      title[#title + 1] = {text = '  ' .. tostring(entry.machine), foreground = P.muted}
    end
    layers[#layers + 1] = label('t' .. i, t.x + 12, t.y + 8, t.w - (severity and 76 or 24), title, 12)
    if severity then
      layers[#layers + 1] = label('a' .. i, t.x + t.w - 60, t.y + 9, 50, {{text = severity == 'high' and 'ALARM' or 'WARN',
        foreground = severity == 'high' and P.high or P.medium}}, 10)
    end
    layers[#layers + 1] = label('s' .. i, t.x + 18, t.y + 31, t.w - 36,
      {{text = entry.stopped and 'stopped' or (#states > 0 and table.concat(states, ' · ') or '—'), foreground = P.text}}, 11)
    local metrics = {{text = string.format('timers %d · inv %d', timers, invokes), foreground = P.muted}}
    if entry.rejected > 0 then metrics[#metrics + 1] = {text = ' · rej ' .. entry.rejected, foreground = P.muted} end
    layers[#layers + 1] = label('m' .. i, t.x + 12, t.y + t.h - 24, t.w - 100, metrics, 10)
    -- A rejected event flashes the tile amber briefly.
    local rej = entry.last_rejected
    if rej and now - rej.time < FLASH_MS then
      local function flash(p)
        if p >= 1 then return nil end
        return o.box {key = 'f' .. i, positioned = {left = t.x - 2, top = t.y - 2, width = t.w + 4, height = t.h + 4},
          radius = 8, border = P.medium .. string.format('%02x', math.floor(255 * (1 - p))), border_width = 3}
      end
      if opts.motion then
        layers[#layers + 1] = flash((now - rej.time) / FLASH_MS)
      else
        layers[#layers + 1] = o.animation {key = 'flash' .. i .. ':' .. tostring(rej.seq or rej.step),
          duration = FLASH_MS - (now - rej.time), render = flash}
      end
    end
    layers[#layers + 1] = o.box {key = 'hit' .. i, positioned = {left = t.x, top = t.y, width = t.w, height = t.h},
      role = 'button', label = 'Open ' .. t.path, activate = true, on_press = viz:event({type = 'SELECT', value = t.path})}
  end
  for k, ep in ipairs(L.endpoints) do
    layers[#layers + 1] = label('e' .. k, ep.x + 14, ep.y + 8, ep.w - 20,
      {{text = ep.src, foreground = P.text}, {text = (ep.kind == 'task' and '  task' or '  I/O')
        .. ((store.endpoints[ep.src].received or 0) > 0 and ('  ←' .. store.endpoints[ep.src].received) or ''), foreground = P.muted}}, 11)
  end
  local stack = o.stack {key = 'layers', children = layers}
  return o.layout_builder {key = 'fit', render = function(cons)
    local s = math.min(1.25, cons.max_width / L.width, cons.max_height / L.height)
    return o.box {key = 'overview', width = math.floor(L.width * s), height = math.floor(L.height * s), clip = true,
      o.stack {key = 'frame', o.box {key = 'scaled', positioned = {left = 0, top = 0, width = L.width, height = L.height},
        transform = s ~= 1 and {scale = s, origin = {x = 0, y = 0}} or nil, stack}}}
  end}
end

local function clock(store, time)
  return string.format('t+%.1fs', (time - (store.first or time)) / 1000)
end

-- The alarm list: newest first; unacknowledged rows keep their colour.
function M.alarms(viz, c, store, P, limit)
  local acked = c.acked or {}
  local open, ids = 0, {}
  for _, a in ipairs(store.alarms) do
    if not acked[tostring(a.id)] then open = open + 1; ids[#ids + 1] = a.id end
  end
  local rows = {o.row {key = 'head', gap = 8, cross_alignment = 'center',
    o.text {key = 'h', text = 'ALARMS', size = 11, weight = 'medium', foreground = P.muted},
    o.text {key = 'n', size = 11, text = open > 0 and (open .. ' unacknowledged') or 'none active',
      foreground = open > 0 and P.text or P.muted},
    o.box {key = 'sp', width = 'fill'},
    o.button {key = 'ackall', label = 'Ack all', height = 24, padding_x = 8, font_size = 11, variant = 'soft', tone = 'neutral',
      enabled = open > 0, send = viz:event({type = 'ACK_ALL', ids = ids})},
  }}
  local shown = 0
  for i = #store.alarms, 1, -1 do
    if shown >= (limit or 14) then break end
    local a = store.alarms[i]
    local active = not acked[tostring(a.id)]
    local color = active and (a.severity == 'high' and P.high or P.medium) or P.faint
    shown = shown + 1
    local text = o.text {key = 'x', size = 11, max_lines = 2, overflow = 'ellipsis', spans = {
      {text = clock(store, a.time) .. '  ', foreground = active and P.text or P.faint},
      {text = (a.severity == 'high' and 'HIGH' or 'MED') .. '  ', foreground = color},
      {text = a.actor .. '  ', foreground = active and P.text or P.faint},
      {text = a.message, foreground = active and P.muted or P.faint}}}
    rows[#rows + 1] = o.row {key = 'a' .. a.id, gap = 6, cross_alignment = 'center',
      o.button {key = 'open', label = 'Open alarm ' .. a.id, flex = 1, height = 'auto', padding_x = 6, variant = 'ghost', tone = 'neutral',
        send = viz:event({type = 'OPEN_ALARM', id = a.id, actor = a.actor, step = a.step}), text},
      active and o.button {key = 'ack', label = 'Ack', height = 22, padding_x = 6, font_size = 10, variant = 'soft', tone = 'neutral',
        send = viz:event({type = 'ACK', id = a.id})} or o.box {key = 'ack', width = 34},
    }
  end
  if #store.alarms == 0 then
    rows[#rows + 1] = o.text {key = 'none', size = 11, foreground = P.faint, text = 'Normal operation: no alarms.'}
  elseif #store.alarms > shown then
    rows[#rows + 1] = o.text {key = 'older', size = 10, foreground = P.faint, text = (#store.alarms - shown) .. ' older'}
  end
  return o.box {key = 'alarms', width = 400, height = 'fill', padding = 12, background = P.panel,
    o.column {key = 'rows', gap = 4, cross_alignment = 'stretch', children = rows}}
end

return M
