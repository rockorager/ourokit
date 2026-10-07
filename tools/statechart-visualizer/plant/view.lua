-- Widget composition for the plant HMI: drawing layers stacked under
-- positioned text, the context tag panel and the event-log timeline.
local o = require('ouro')
local draw = require('plant.draw')
local history = require('history')
local layout = require('plant.layout')

local M = {}
local C = draw.colors
local T = {
  text='#c8d0d8', dim='#7d8a97', faint='#56616d', label='#e6edf3', amber='#f2c14e',
  red='#ff6b62', green='#7ee08f', teal='#5fd8c9', panel='#11161b', panel_edge='#2a333d',
}
M.text_colors = T

-- Positioned text leaves directly in the stack: windows have a fixed widget
-- instance budget (256), so labels avoid wrapper boxes.
local function label(key, x, y, text, size, color, width, align)
  return o.text {key=key, positioned={left=x, top=y, width=width}, text=text, size=size or 11,
    foreground=color or T.text, alignment=width and align or nil}
end

local function fmt_ms(ms)
  if ms >= 1000 then return string.format('%.1fs', ms / 1000) end
  return string.format('%dms', math.floor(ms))
end
M.fmt_ms = fmt_ms

local function value_text(v)
  if v == false or v == nil or v == o.json.null then return '—' end
  if type(v) == 'table' then
    if type(v.message) == 'string' then return v.message end
    local ok, text = pcall(o.json.encode, v)
    return ok and text or '{…}'
  end
  return tostring(v)
end
M.value_text = value_text

local function cached(plant, key, build)
  plant.cache = plant.cache or {}
  local hit = plant.cache[key]
  if hit then return hit end
  local value = build()
  plant.cache = {[key] = value, static=plant.cache.static}
  return value
end

local function labels(plant, frame, now)
  local graph, children = plant.graph, {}
  for _, state in ipairs(graph.states) do
    local b = plant.boxes[state.id]
    local active = frame.active[state.id]
    if state.kind == 'atomic' or state.kind == 'final' then
      children[#children+1] = label('s:' .. state.id, b.x, b.y + 18, state.label:upper(), 12,
        active and T.label or T.dim, b.w, 'center')
    elseif state.id ~= graph.root then
      local text = state.label:upper() .. (state.kind == 'parallel' and '  ║ PARALLEL' or '')
      children[#children+1] = label('s:' .. state.id, b.x + 12, b.y + (b.header - 14) / 2, text, 11,
        active and T.teal or T.dim)
    else
      children[#children+1] = label('s:' .. state.id, b.x + 14, b.y + 8,
        'MACHINE · ' .. graph.id:upper(), 12, T.text)
    end
  end
  for i, pipe in ipairs(plant.pipes) do
    if pipe.first then
      local t, taken = pipe.transition, false
      for _, member in ipairs(pipe.group) do taken = taken or frame.taken[member.id] end
      local color = taken and T.amber or (frame.active[t.source] and T.text or T.faint)
      local box = pipe.label_box
      children[#children+1] = label('p:' .. i, box.x + 2, box.y, pipe.label_text, layout.LABEL_SIZE, color)
    end
  end
  for i, p in ipairs(plant.pumps) do
    local info = frame.pumps[p.key]
    local status = info and info.status or 'idle'
    if status == 'running' and not frame.active[p.state] then status = 'cancelled' end
    local color = status == 'running' and T.teal or status == 'error' and T.red or status == 'done' and T.green or T.faint
    children[#children+1] = label('u:' .. i, p.x + p.r + 14, p.y + 3, p.src .. ' · ' .. status, 10, color)
  end
  local m, record = plant.manifold, frame.record
  children[#children+1] = label('m:title', m.x - 72, m.top - 40, 'INLET', 10, T.dim, 80, 'center')
  for i, n in ipairs(m.nozzles) do
    local hit = record.origin == 'external' and record.event and record.event.type == n.event
    local color = hit and (record.rejected and T.red or T.amber) or T.dim
    children[#children+1] = label('m:' .. i, n.x - 112, n.y - 7, n.event, 11, color, 104, 'end')
  end
  if record.rejected and record.event then
    children[#children+1] = o.box {key='m:rejected', positioned={left=m.x - 100, top=m.bottom + 26}, padding_x=6, padding_y=3,
      background='#4a1715', radius=3,
      o.text {key='t', text='REJECTED ' .. record.event.type, size=10, foreground=T.red}}
  end
  return children
end

-- opts.pulse / opts.spin pin motion for headless frames; otherwise native
-- animations drive the pulse (one shot per record) and pump rotors (loop).
function M.plant(plant, frame, now, opts)
  opts = opts or {}
  plant.cache = plant.cache or {}
  plant.cache.static = plant.cache.static or o.drawing {width=plant.width, height=plant.height, commands=draw.static(plant)}
  local live = cached(plant, frame.index, function()
    return o.drawing {width=plant.width, height=plant.height, commands=draw.live(plant, frame)}
  end)
  local layers = {
    o.canvas {key='static', drawing=plant.cache.static, alt='Statechart plant: vessels and pipes'},
    o.canvas {key='live', drawing=live, alt='Active states, valves, gauges and pumps'},
  }
  -- Sprites are positioned at the origin and moved by a paint-only
  -- transform, so animation frames neither relayout nor repaint the plant.
  local function sprite(sp)
    return o.box {key=sp.key, positioned={left=0, top=0, width=sp.size, height=sp.size},
      transform={x=sp.x, y=sp.y},
      o.canvas {key='c', drawing=o.drawing {width=sp.size, height=sp.size, commands=sp.commands}}}
  end
  local function pulses(p)
    local children = {}
    for _, sp in ipairs(draw.pulse_sprites(plant, frame, p)) do children[#children+1] = sprite(sp) end
    return o.stack {key='pulses', positioned={left=0, top=0, width=plant.width, height=plant.height}, children=children}
  end
  local running = {}
  for _, p in ipairs(plant.pumps) do
    local info = frame.pumps[p.key]
    if info and info.status == 'running' and frame.active[p.state] then running[#running+1] = p end
  end
  if opts.pulse or opts.spin then
    for _, p in ipairs(running) do layers[#layers+1] = sprite(draw.rotor_sprite(p, opts.spin or 0)) end
    layers[#layers+1] = pulses(opts.pulse)
  else
    for _, p in ipairs(running) do
      layers[#layers+1] = o.animation {key='spin:' .. p.key, duration=1200, loop=true,
        render=function(t) return sprite(draw.rotor_sprite(p, t)) end}
    end
    layers[#layers+1] = o.animation {key='pulse-' .. frame.index, duration=1400, easing='ease_in_out',
      render=function(t) return t < 1 and pulses(t) or nil end}
  end
  for i, g in ipairs(plant.gauges) do layers[#layers+1] = M.gauge('gauge:' .. i, g, frame, now, opts.live) end
  for _, child in ipairs(labels(plant, frame, now)) do layers[#layers+1] = child end
  local stack = o.stack {key='layers', children=layers}
  -- Scale the whole plant (drawings and labels alike) to the available area.
  return o.layout_builder {key='fit', render=function(c)
    local s = math.min(1, c.max_width / plant.width, c.max_height / plant.height)
    -- A positioned child keeps its full logical size; the transform then
    -- shrinks its paint into the clipped, scaled footprint.
    return o.box {key='plant', width=math.floor(plant.width * s), height=math.floor(plant.height * s), clip=true,
      o.stack {key='frame', o.box {key='scaled', positioned={left=0, top=0, width=plant.width, height=plant.height},
        transform=s < 1 and {scale=s, origin={x=0, y=0}} or nil, stack}}}
  end}
end

-- Remaining time on a gauge's timer at machine time `now`, or nil.
local function timer_at(g, frame, now)
  local timer = frame.timers[g.state .. '@' .. tostring(g.delay)]
  if not timer then return nil end
  -- Untimed records (no machine clock) can only say the timer is armed.
  return frame.timed and history.remaining(timer, now) or timer.delay, timer
end

-- A gauge is its own small canvas and readout. While following live, a
-- one-shot native animation sweeps the needle over the remaining time, so a
-- running timer costs frames only until it would fire; no Lua ticker runs.
function M.gauge(key, g, frame, now, live)
  local remaining, timer = timer_at(g, frame, now)
  local fired = frame.fired and frame.fired[g.state .. '@' .. tostring(g.delay)]
  local size = 2 * g.r + 6
  local function render(left)
    return o.box {key='g', width=60, height=size + 16,
      o.column {key='c', gap=1, cross_alignment='center',
        o.text {key='t', text=left and fmt_ms(left) or fmt_ms(g.delay), size=10, foreground=left and T.amber or T.faint},
        o.canvas {key='dial', drawing=o.drawing {width=size, height=size,
          commands=draw.gauge(g.r, left and left / g.delay, fired)}, alt='Timer gauge'},
      }}
  end
  local body
  if live and timer then
    -- Keyed by the timer's entry token: later records keep the same sweep.
    body = o.animation {key='sweep-' .. tostring(timer.token), duration=g.delay,
      render=function(p) return render(g.delay * (1 - p)) end}
  else
    body = render(remaining)
  end
  return o.box {key=key, positioned={left=g.x - 30, top=g.y - g.r - 3 - 16}, body}
end

local function faceplate(key, title, value, changed, color)
  return o.box {key=key, width='fill', padding_x=10, padding_y=6, background=T.panel, radius=3,
    border=changed and T.amber or T.panel_edge, border_width=1,
    o.column {key='c', gap=2,
      o.text {key='k', text=title, size=10, foreground=T.dim},
      o.text {key='v', text=value, size=14, foreground=color or (changed and T.amber or T.green), max_lines=2, overflow='ellipsis'},
    }}
end

function M.tags(plant, frame, now, live)
  local keys = {}
  for k in pairs(frame.context) do keys[#keys+1] = k end
  table.sort(keys)
  local rows = {o.text {key='h1', text='CONTEXT TAGS', size=11, foreground=T.dim}}
  for _, k in ipairs(keys) do
    rows[#rows+1] = faceplate('ctx:' .. k, k:upper(), value_text(frame.context[k]), frame.changed[k])
  end
  rows[#rows+1] = o.box {key='sp1', height=6}
  rows[#rows+1] = o.text {key='h2', text='TIMERS', size=11, foreground=T.dim}
  local any = false
  for _, g in ipairs(plant.gauges) do
    local remaining, timer = timer_at(g, frame, now)
    if remaining then
      any = true
      local title = g.state:match('[^.]+$'):upper() .. ' · AFTER ' .. fmt_ms(g.delay)
      if live then
        rows[#rows+1] = o.animation {key='tmr:' .. tostring(timer.token), duration=g.delay,
          render=function(p) return faceplate('fp', title, fmt_ms(g.delay * (1 - p)) .. ' left', false, T.amber) end}
      else
        rows[#rows+1] = faceplate('tmr:' .. g.state .. g.delay, title, fmt_ms(remaining) .. ' left', false, T.amber)
      end
    end
  end
  if not any then rows[#rows+1] = o.text {key='tmr:none', text='none pending', size=11, foreground=T.faint} end
  rows[#rows+1] = o.box {key='sp2', height=6}
  rows[#rows+1] = o.text {key='h3', text='INVOKES', size=11, foreground=T.dim}
  for _, p in ipairs(plant.pumps) do
    local info = frame.pumps[p.key] or {status='idle'}
    local status = info.status
    if status == 'running' and not frame.active[p.state] then status = 'cancelled' end
    local color = status == 'running' and T.teal or status == 'error' and T.red or status == 'done' and T.green or T.dim
    rows[#rows+1] = faceplate('inv:' .. p.id, p.id:upper() .. ' · ' .. p.src,
      status .. (info.error and (': ' .. value_text(info.error)) or ''), false, color)
  end
  return o.box {key='tags', width=230, height='fill', padding=12, background='#0d1115',
    o.column {key='rows', gap=6, children=rows}}
end

local function describe(graph, record)
  if record.rejected then return 'rejected — no enabled transition' end
  local parts = {}
  for _, step in ipairs(record.microsteps) do
    for _, id in ipairs(step.transitions) do
      local t = graph.transition_by_id[id]
      if t then
        local target = t.targets[1] and t.targets[1]:match('[^.]+$') or '⟲'
        parts[#parts+1] = (step.event and (step.event.type .. ': ') or '') .. t.source:match('[^.]+$') .. ' → ' .. target
      end
    end
  end
  if #parts == 0 then
    local entered = {}
    for _, id in ipairs(record.entered) do entered[#entered+1] = id:match('[^.]+$') end
    return #entered > 0 and ('entered ' .. table.concat(entered, ', ')) or 'no state change'
  end
  return table.concat(parts, ' · ')
end

local origin_color = {external=T.teal, timer=T.amber, invoke='#79bafa', init=T.dim, internal=T.dim}

function M.timeline(hist, cursor, width, handlers)
  local frames = hist.frames
  local n = #frames
  local span = math.max(1, n > 0 and frames[n].time or 1)
  local h = 46
  local cmds = {{kind='rectangle', x=0, y=0, width=width, height=h, color='#0d1115'},
    {kind='stroke', color=C.pipe_outer, width=8, path={{'move', 12, 24}, {'line', width - 12, 24}}},
    {kind='stroke', color=C.pipe_inner, width=4, path={{'move', 12, 24}, {'line', width - 12, 24}}}}
  local function x_of(f) return 12 + (width - 24) * (f.time / span) end
  for i, f in ipairs(frames) do
    local x = x_of(f)
    local r = f.record
    local color = r.rejected and T.red or origin_color[r.origin] or T.dim
    cmds[#cmds+1] = {kind='rectangle', x=x - 2, y=8, width=4, height=32, color=color .. (i <= cursor and 'ff' or '66'), corner_radius=2}
  end
  if n > 0 then
    local x = x_of(frames[cursor])
    cmds[#cmds+1] = {kind='fill', color=T.label, path={{'move', x - 7, 0}, {'line', x + 7, 0}, {'line', x, 9}, {'close'}}}
    cmds[#cmds+1] = {kind='stroke', color=T.label, width=1.5, path={{'move', x, 0}, {'line', x, h}}}
  end
  local rows = {}
  local first = math.max(1, math.min(cursor - 2, n - 4))
  for i = first, math.min(n, first + 4) do
    local r = frames[i].record
    local selected = i == cursor
    -- One monospace text per row keeps the widget count low.
    local line = (selected and '▶ ' or '  ') .. string.format('#%02d  t+%6.2fs  %-8s  %-34s  %s', r.seq or i, (r.time or 0) / 1000, r.origin,
      r.event and r.event.type or '—', describe(hist.graph, r))
    rows[#rows+1] = o.text {key='log' .. i, text=line, size=11, max_lines=1, overflow='ellipsis',
      foreground=r.rejected and T.red or (selected and T.label or T.text)}
  end
  local controls = {
    o.button {key='prev', label='◀', width=36, enabled=cursor > 1, on_press=handlers.prev},
    o.button {key='next', label='▶', width=36, enabled=cursor < n, on_press=handlers.next},
    n > 1 and o.slider {key='scrub', label='History', width=width - 260, value=cursor, min=1, max=n, step=1,
      on_change=handlers.scrub} or o.box {key='scrub', width=width - 260},
    o.button {key='live', label=handlers.following and '● LIVE' or 'Go live', width=96, on_press=handlers.live},
  }
  return o.box {key='timeline', width='fill', padding=12, background='#0d1115',
    o.column {key='c', gap=8,
      o.row {key='head', gap=12,
        o.text {key='title', text='EVENT LOG', size=11, foreground=T.dim},
        o.text {key='pos', text=n > 0 and string.format('step %d / %d  ·  t+%.2fs', cursor, n, frames[cursor].time / 1000) or 'waiting for records',
          size=11, foreground=T.text},
      },
      o.canvas {key='ticks', drawing=o.drawing {width=width, height=h, commands=cmds}, alt='Event timeline'},
      o.row {key='controls', gap=8, children=controls},
      o.column {key='log', gap=1, children=rows},
    }}
end

function M.header(title, source, status, status_color, tabs)
  local row = {
    o.text {key='brand', text='OUROKIT · STATECHART PLANT', size=13, foreground=T.teal, weight='medium'},
    o.text {key='machine', text=title, size=13, foreground=T.label},
  }
  -- One tab per observed actor.
  for i, tab in ipairs(tabs or {}) do
    row[#row+1] = o.button {key='tab' .. i, label=tab.label, height=26, padding_x=10, font_size=11,
      variant=tab.selected and 'solid' or 'ghost', on_press=tab.on_press}
  end
  row[#row+1] = o.text {key='source', text=source, size=11, foreground=T.dim}
  row[#row+1] = o.box {key='spacer', width='fill'}
  row[#row+1] = o.text {key='status', text=status, size=12, foreground=status_color or T.green}
  return o.box {key='header', width='fill', padding_x=16, padding_y=8, background='#0d1115',
    o.row {key='r', gap=14, cross_alignment='center', children=row}}
end

-- Whole window body for one machine at history position `cursor`.
function M.screen(model)
  local hist, plant = model.history, model.plant
  local n = #hist.frames
  local cursor = model.cursor or n
  local frame = hist.frames[cursor]
  local body
  if frame then
    local now = model.now or frame.time
    local following = model.cursor == nil and not model.motion
    body = o.row {key='main', gap=0, flex=1, cross_alignment='stretch',
      o.box {key='plant-frame', flex=1, height='fill', background=C.background, clip=true, alignment='center',
        M.plant(plant, frame, now, model.motion or {live=following})},
      M.tags(plant, frame, now, following),
    }
  else
    body = o.box {key='main', width='fill', flex=1, alignment='center',
      o.text {key='waiting', text='Waiting for the first transition record…', foreground=T.dim}}
  end
  return o.theme {key='hmi', color_scheme='dark', typography={family='monospace'},
    colors={primary='#1f3d3a', primary_foreground='#5fd8c9'},
   o.column {key='screen', gap=0, cross_alignment='stretch',
    M.header(model.title or plant.graph.id, model.source or 'fixture', model.status or (model.cursor and 'HISTORY' or 'LIVE'),
      model.cursor and T.amber or (model.status == 'LIVE' and T.green or T.amber), model.tabs),
    body,
    M.timeline(hist, cursor, model.timeline_width or 1180, model.handlers or {}),
  }}
end

return M
