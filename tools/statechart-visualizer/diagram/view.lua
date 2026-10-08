-- The visualizer's UI as a function of its chart and the inspected data:
-- the diagram (drawings plus positioned text), the events panel, the context
-- tree and the timeline. It holds no state; every control sends an event to
-- the visualizer actor.
local o = require('ouro')
local draw = require('diagram.draw')
local layout = require('diagram.layout')
local history = require('history')
local model = require('model')
local overview_view = require('diagram.overview')

local M = {}

local function fmt_ms(ms)
  if ms >= 1000 then return string.format('%.1fs', ms / 1000) end
  return string.format('%dms', math.floor(ms))
end
M.fmt_ms = fmt_ms

local function value_text(v, null)
  if v == nil or v == null then return 'null' end
  local handle = type(v) == 'table' and type(v['$h']) == 'string' and v['$h']
  if handle then return '‹' .. handle .. '›' end
  if type(v) == 'string' then return string.format('%q', v) end
  if type(v) == 'table' then
    if type(v.message) == 'string' then return v.message end
    local ok, text = pcall(o.json.encode, v)
    return ok and text or '{…}'
  end
  return tostring(v)
end
M.value_text = value_text

local function label(key, x, y, text, size, color, width, align)
  return o.text {key=key, positioned={left=x, top=y, width=width}, text=text, size=size or 11,
    foreground=color, alignment=width and align or nil, max_lines=1, overflow=width and 'ellipsis' or 'clip'}
end

-- Drawings are cached per diagram, palette and frame.
local function drawings(plant, frame, scheme, P)
  plant.cache = plant.cache or {}
  local cache = plant.cache
  if cache.scheme ~= scheme then
    cache.scheme, cache.static, cache.frame, cache.live = scheme, nil, nil, nil
  end
  cache.static = cache.static or o.drawing {width=plant.width, height=plant.height, commands=draw.static(plant, P)}
  if cache.frame ~= frame then
    cache.frame, cache.live = frame, o.drawing {width=plant.width, height=plant.height, commands=draw.live(plant, frame, P)}
  end
  return cache.static, cache.live
end

local CHIP_TEXT = {running='running', done='done', error='error', cancelled='cancelled', idle='idle'}

-- The running timer of an after transition and its evaluated duration
-- (the record's ms, so named and function delays count down too).
local function running_timer(t, frame)
  local timer = frame.timers[t.after_event] or frame.timers[t.source .. '@' .. tostring(t.after)]
  return timer, timer and (timer.delay or t.after)
end

-- An after pill's text: the delay's label (`after slow`, `after 250ms`),
-- plus the time left only while its timer runs.
function M.after_text_of(t, frame, now, left)
  local timer, delay = running_timer(t, frame)
  if not timer or not delay then return t.label end
  left = left or (frame.timed and history.remaining(timer, now) or delay)
  return t.label .. ' · ' .. fmt_ms(left)
end

-- An after pill shows a countdown while its timer runs. Following live, a
-- native one-shot animation keyed by the timer token counts it down.
local function after_text(key, t, frame, now, live, render)
  local timer, delay = running_timer(t, frame)
  if not timer or not delay then return render(nil) end
  if live then
    return o.animation {key=key .. ':' .. tostring(timer.token), duration=delay,
      render=function(p) return render(delay * (1 - p)) end}
  end
  return render(frame.timed and history.remaining(timer, now) or delay)
end

local function texts(plant, frame, now, P, live)
  local graph, children = plant.graph, {}
  for _, state in ipairs(graph.states) do
    local b = plant.boxes[state.id]
    local active = frame.active[state.id]
    if state.kind == 'atomic' or state.kind == 'final' then
      children[#children+1] = label('s:' .. state.id, b.x + 8, b.y + 7, state.label, layout.TITLE_SIZE,
        active and P.text or P.muted, b.w - 16, 'center')
      for i, line in ipairs(b.lines or {}) do
        local y = b.y + 32 + (i - 1) * layout.LINE_H
        children[#children+1] = label('l:' .. state.id .. i, b.x + 10, y, line.text, layout.LINE_SIZE,
          active and P.muted or P.faint, b.w - 20 - (line.invoke and draw.CHIP_W + 4 or 0))
        if line.invoke then
          local status = draw.invoke_status(frame, line)
          local color = P['chip_' .. (status == 'running' and 'running' or status == 'done' and 'done'
            or status == 'error' and 'error' or 'idle')]
          children[#children+1] = label('c:' .. state.id .. i, b.x + b.w - draw.CHIP_W - 8, y, CHIP_TEXT[status],
            10, color, draw.CHIP_W, 'center')
        end
      end
    elseif state.id == graph.root then
      children[#children+1] = label('s:root', b.x + 14, b.y + 8, graph.id, layout.TITLE_SIZE, P.text)
    else
      local parent = state.parent and graph.by_id[state.parent]
      local region = parent and parent.kind == 'parallel'
      local text = state.label .. (state.kind == 'parallel' and '  ∥' or '')
      children[#children+1] = label('s:' .. state.id, b.x + (region and 10 or 14), b.y + (region and 5 or 8), text,
        region and 11 or 12, active and P.accent or P.muted)
    end
  end
  for i, pipe in ipairs(plant.pipes) do
    if pipe.first then
      for j, r in ipairs(draw.pill_rects(pipe)) do
        local p = r.pill
        local t = p.transition
        local taken = t and frame.taken[t.id]
        local color = taken and P.taken or ((t and frame.active[t.source]) and P.text or P.muted)
        local key = 'p:' .. i .. ':' .. j
        local function pill(left)
          local text = (t and t.after_event) and (left and M.after_text_of(t, frame, now, left) or t.label) or p.event
          local spans = {{text=text, foreground=color}}
          if p.guard then
            -- Green passed, red failed, grey not evaluated or needing a payload.
            local outcome = t and frame.guards[t.id]
            spans[#spans+1] = {text=' ' .. p.guard,
              foreground=outcome == true and P.pass or outcome == false and P.fail or P.faint}
          end
          return o.text {key=key, positioned={left=r.x + 7, top=r.y + 2}, size=layout.LABEL_SIZE, spans=spans, max_lines=1}
        end
        children[#children+1] = (t and t.after_event) and after_text(key, t, frame, now, live, pill) or pill(nil)
      end
    end
  end
  return children
end

-- The diagram: static and live drawings, pulse sprites and labels, scaled
-- to fit. opts.pulse pins the pulse phase for headless frames.
function M.diagram(plant, frame, now, P, scheme, opts)
  local static, live = drawings(plant, frame, scheme, P)
  local layers = {
    o.canvas {key='static', drawing=static, alt='Statechart: states and transitions'},
    o.canvas {key='live', drawing=live, alt='Active states and taken transitions'},
  }
  local function sprite(sp)
    return o.box {key=sp.key, positioned={left=0, top=0, width=sp.size, height=sp.size},
      transform={x=sp.x, y=sp.y},
      o.canvas {key='c', drawing=o.drawing {width=sp.size, height=sp.size, commands=sp.commands}}}
  end
  local function pulses(p)
    local children = {}
    for _, sp in ipairs(draw.pulse_sprites(plant, frame, p, P)) do children[#children+1] = sprite(sp) end
    return o.stack {key='pulses', positioned={left=0, top=0, width=plant.width, height=plant.height}, children=children}
  end
  if opts.pulse then
    layers[#layers+1] = pulses(opts.pulse)
  else
    layers[#layers+1] = o.animation {key='pulse-' .. frame.index, duration=1200, easing='ease_in_out',
      render=function(t) return t < 1 and pulses(t) or nil end}
  end
  for _, child in ipairs(texts(plant, frame, now, P, opts.live)) do layers[#layers+1] = child end
  local stack = o.theme {key='mono', typography={family='monospace'}, o.stack {key='layers', children=layers}}
  return o.layout_builder {key='fit', render=function(c)
    -- Small charts scale up a little; large ones shrink to fit.
    local s = math.min(1.4, c.max_width / plant.width, c.max_height / plant.height)
    return o.box {key='diagram', width=math.floor(plant.width * s), height=math.floor(plant.height * s), clip=true,
      o.stack {key='frame', o.box {key='scaled', positioned={left=0, top=0, width=plant.width, height=plant.height},
        transform=s ~= 1 and {scale=s, origin={x=0, y=0}} or nil, stack}}}
  end}
end

local function heading(key, text, P)
  return o.text {key=key, text=text, size=11, weight='medium', foreground=P.muted}
end

-- Whether the inspected actor would take `event` now: 'enabled' when an
-- active transition for it has no guard or one that passed, 'payload' when
-- its guard needs the event's payload to decide (record.guarded on attach
-- records, guards[].payload on transition records), 'refused' otherwise.
function M.availability(graph, frame, event)
  if frame.record.guarded and frame.record.guarded[event] then return 'payload' end
  local payload = false
  for _, t in ipairs(graph.transitions) do
    if t.event == event and frame.active[t.source] then
      local outcome = frame.guards[t.id]
      if outcome == nil or outcome == true then return 'enabled' end
      if outcome == 'payload' then payload = true end
    end
  end
  return payload and 'payload' or 'refused'
end

function M.events(viz, c, graph, frame, P, can_send)
  local rows = {heading('h', 'EVENTS', P)}
  local record = frame.record
  for i, event in ipairs(graph.events) do
    local fields = graph.fields[event]
    local has_fields = fields and next(fields) ~= nil
    local rejected = record.rejected and record.event and record.event.type == event
    -- Available with payload: highlighted like enabled, marked '…', and it
    -- opens the payload editor (even without declared fields).
    local state = M.availability(graph, frame, event)
    local enabled = state ~= 'refused'
    local editor = has_fields or state == 'payload'
    local binding = editor and viz:event({type='EDIT_PAYLOAD', name=event, fields=fields or {}})
      or viz:event({type='INJECT', name=event})
    rows[#rows+1] = o.button {key='e' .. i, label=event .. (editor and ' …' or ''), height=28, padding_x=10,
      font_size=12, variant=enabled and 'soft' or 'surface', tone=rejected and 'destructive' or (enabled and 'accent' or 'neutral'),
      enabled=can_send, send=binding}
  end
  if record.rejected and record.event then
    rows[#rows+1] = o.text {key='rejected', text=record.event.type .. ' rejected' .. (record.reason and (' (' .. record.reason .. ')') or ''),
      size=11, foreground=P.fail}
  end
  if c.editor then
    local editor = {heading('eh', 'SEND ' .. c.editor.name, P)}
    local names = {}
    for name in pairs(c.editor.fields) do names[#names+1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      editor[#editor+1] = o.text {key='fl' .. name, text=name .. ' : ' .. c.editor.fields[name], size=11, foreground=P.muted}
      editor[#editor+1] = o.text_input {key='fi' .. name, text=tostring(c.editor.drafts[name] or ''),
        send=viz:event({type='FIELD', name=name})}
    end
    editor[#editor+1] = o.row {key='ea', gap=6,
      o.button {key='send', label='Send', height=28, send=viz:event('SEND_PAYLOAD')},
      o.button {key='cancel', label='Cancel', height=28, variant='soft', tone='neutral', send=viz:event('CLOSE_EDITOR')},
    }
    rows[#rows+1] = o.box {key='editor', width='fill', padding=8, radius=8, background=P.panel, border=P.panel_edge,
      border_width=1, o.column {key='c', gap=6, children=editor}}
  end
  if c.message then rows[#rows+1] = o.text {key='msg', text=c.message, size=11, foreground=P.muted, max_lines=3, overflow='ellipsis'} end
  return o.box {key='events', width=190, height='fill', padding=12, background=P.panel,
    o.column {key='rows', gap=6, cross_alignment='stretch', children=rows}}
end

-- Context as a tree: nested tables expand three levels deep; top-level keys
-- changed by this step are highlighted.
local function tree(rows, key, value, depth, changed, P, null)
  if #rows > 80 then return end
  local indent = string.rep('  ', depth)
  -- Opaque native handles ({"$h": type}) are leaves.
  if type(value) == 'table' and value ~= null and type(value['$h']) ~= 'string' and depth < 3 then
    local keys = {}
    for k in pairs(value) do keys[#keys+1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local spans = {{text=indent .. tostring(key), foreground=changed and P.accent or P.text}}
    local hint = #keys == 0 and '  {}' or (math.type(keys[1]) and ('  [' .. #keys .. ']') or nil)
    if hint then spans[2] = {text=hint, foreground=P.faint} end
    rows[#rows+1] = o.text {key='t' .. #rows, size=12, spans=spans}
    for _, k in ipairs(keys) do tree(rows, k, value[k], depth + 1, false, P, null) end
  else
    rows[#rows+1] = o.text {key='t' .. #rows, size=12, max_lines=2, overflow='ellipsis', spans={
      {text=indent .. tostring(key) .. ': ', foreground=changed and P.accent or P.muted},
      {text=value_text(value, null), foreground=changed and P.accent or P.text}}}
  end
end

function M.side(plant, frame, now, P, null, live)
  local rows = {heading('h1', 'CONTEXT', P)}
  local keys = {}
  for k in pairs(frame.context) do keys[#keys+1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do tree(rows, k, frame.context[k], 0, frame.changed[k], P, null) end
  rows[#rows+1] = o.box {key='sp1', height=8}
  rows[#rows+1] = heading('h2', 'TIMERS', P)
  local any = false
  local timers = {}
  for _, timer in pairs(frame.timers) do timers[#timers+1] = timer end
  table.sort(timers, function(a, b) return a.state < b.state end)
  for i, timer in ipairs(timers) do
    any = true
    local function row(left)
      local what = timer.name and (timer.name .. (timer.delay and (' (' .. fmt_ms(timer.delay) .. ')') or ''))
        or (timer.delay and fmt_ms(timer.delay) or '?')
      return o.text {key='tm' .. i, size=12, spans={{text='after ' .. what .. ' ', foreground=P.text},
        {text=timer.state .. (left and ('  ' .. fmt_ms(left) .. ' left') or ''), foreground=P.muted}}}
    end
    if live and timer.delay then
      rows[#rows+1] = o.animation {key='tma' .. tostring(timer.token), duration=timer.delay,
        render=function(p) return row(timer.delay * (1 - p)) end}
    else
      rows[#rows+1] = row(frame.timed and history.remaining(timer, now) or nil)
    end
  end
  if not any then rows[#rows+1] = o.text {key='tm', text='none', size=12, foreground=P.faint} end
  rows[#rows+1] = o.box {key='sp2', height=8}
  rows[#rows+1] = heading('h3', 'INVOKES', P)
  local pumps = {}
  for key, info in pairs(frame.pumps) do pumps[#pumps+1] = {key=key, info=info} end
  table.sort(pumps, function(a, b) return a.key < b.key end)
  for i, p in ipairs(pumps) do
    local status = p.info.status
    if status == 'running' and not frame.active[p.info.state] then status = 'cancelled' end
    rows[#rows+1] = o.text {key='iv' .. i, size=12, max_lines=2, overflow='ellipsis', spans={
      {text=tostring(p.info.src or p.key:match('|(.*)$')) .. ' ', foreground=P.text},
      {text=status .. (p.info.error and (': ' .. value_text(p.info.error, null)) or ''),
        foreground=status == 'running' and P.chip_running or status == 'error' and P.chip_error
          or status == 'done' and P.chip_done or P.muted}}}
  end
  if #pumps == 0 then rows[#rows+1] = o.text {key='iv', text='none', size=12, foreground=P.faint} end
  return o.box {key='side', width=270, height='fill', padding=12, background=P.panel,
    o.scroll {key='scroll', axis='vertical', height='fill', o.column {key='rows', gap=3, children=rows}}}
end

local function describe(graph, record)
  if record.rejected then return 'rejected' .. (record.reason and (' (' .. record.reason .. ')') or '') end
  local parts = {}
  for _, step in ipairs(record.microsteps) do
    for _, id in ipairs(step.transitions) do
      local t = graph.transition_by_id[id]
      if t then
        local target = t.targets[1] and t.targets[1]:match('[^.]+$') or '⟲'
        parts[#parts+1] = (t.source:match('[^.]+$') or graph.id) .. ' → ' .. target
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

function M.timeline(viz, hist, cursor, following, playing, width, P, file)
  local frames = hist.frames
  local n = #frames
  local span = math.max(1, n > 0 and frames[n].time or 1)
  local h = 34
  local origin = {external=P.accent, dev=P.accent, widget=P.accent, timer=P.taken, invoke=P.chip_done,
    init=P.faint, attach=P.faint}
  local cmds = {{kind='stroke', color=P.panel_edge, width=2, path={{'move', 8, 17}, {'line', width - 8, 17}}}}
  local function x_of(f) return 8 + (width - 16) * (f.time / span) end
  for i, f in ipairs(frames) do
    local r = f.record
    local color = r.rejected and P.fail or origin[r.origin] or P.muted
    cmds[#cmds+1] = {kind='fill', color=color .. (i <= cursor and 'ff' or '55'), path=draw.circle_path(x_of(f), 17, 4)}
  end
  if n > 0 then
    local x = x_of(frames[cursor])
    cmds[#cmds+1] = {kind='stroke', color=P.text, width=1.5, path={{'move', x, 2}, {'line', x, h - 2}}}
  end
  local rows = {}
  local first = math.max(1, math.min(cursor - 2, n - 4))
  for i = first, math.min(n, first + 4) do
    local r = frames[i].record
    local selected = i == cursor
    local line = (selected and '▸ ' or '  ') .. string.format('#%-3d t+%6.2fs  %-8s  %-28s  %s', r.seq or i, (r.time or 0) / 1000,
      r.origin, r.event and r.event.type or '—', describe(hist.graph, r))
    rows[#rows+1] = o.text {key='log' .. i, text=line, size=11, max_lines=1, overflow='ellipsis',
      foreground=r.rejected and P.fail or (selected and P.text or P.muted)}
  end
  local controls = {
    o.button {key='prev', label='◀', width=34, height=28, variant='soft', tone='neutral', send=viz:event({type='STEP', delta=-1}), enabled=cursor > 1},
    o.button {key='next', label='▶', width=34, height=28, variant='soft', tone='neutral', send=viz:event({type='STEP', delta=1}), enabled=cursor < n},
    n > 1 and o.slider {key='scrub', label='History', width=width - 300, value=cursor, min=1, max=n, step=1,
      send=viz:event('SCRUB')} or o.box {key='scrub', width=width - 300},
    file and o.button {key='play', label=playing and 'Pause' or 'Play', width=80, height=28, variant='soft',
      send=viz:event(playing and 'PAUSE' or 'PLAY')}
      or o.button {key='live', label=following and '● Live' or 'Go live', width=80, height=28,
        variant=following and 'solid' or 'soft', send=viz:event('LIVE')},
  }
  return o.box {key='timeline', width='fill', padding_x=12, padding_y=8, background=P.panel,
    o.column {key='c', gap=6,
      o.row {key='head', gap=12,
        heading('title', 'TIMELINE', P),
        o.text {key='pos', size=11, foreground=P.muted,
          text=n > 0 and string.format('step %d / %d · t+%.2fs', cursor, n, frames[cursor].time / 1000) or 'waiting for records'},
      },
      o.canvas {key='ticks', drawing=o.drawing {width=width, height=h, commands=cmds}, alt='Event timeline'},
      o.row {key='controls', gap=8, cross_alignment='center', children=controls},
      o.column {key='log', gap=1, children=rows},
    }}
end

-- Status of the connection region, for the header chip.
function M.status(viz)
  if viz:matches('connection.in_process') then return 'live · in-process', 'live' end
  if viz:matches('connection.connected.live') then return 'live · push', 'live' end
  if viz:matches('connection.connected.attaching') then return 'attaching', 'busy' end
  if viz:matches('connection.polling') then return 'live · polling', 'live' end
  if viz:matches('connection.detached') then return 'detached · retrying', 'error' end
  if viz:matches('connection.loading') then return 'loading', 'busy' end
  if viz:matches('connection.loaded') then return 'recording', 'live' end
  if viz:matches('connection.failed') then return 'failed', 'error' end
  return 'starting', 'busy'
end

-- Breadcrumbs down the display hierarchy: Overview › unit › step › record.
local function crumb(key, text, event, current, P)
  if current then return o.text {key=key, text=text, size=13, weight='medium', foreground=P.text} end
  return o.button {key=key, label=text, height=26, padding_x=8, font_size=13, variant='ghost', tone='neutral', send=event}
end

function M.header(viz, c, P, scheme, store, cursor)
  local row = {o.text {key='brand', text='Statechart inspector', size=14, weight='medium', foreground=P.text},
    o.box {key='gap', width=8}}
  local level = viz:matches('screen.record') and 4 or viz:matches('screen.unit') and 3 or 1
  row[#row+1] = crumb('c1', 'Overview', viz:event('OVERVIEW'), level == 1, P)
  if level > 1 and c.selected then
    local entry = store.actors[c.selected]
    row[#row+1] = o.text {key='s1', text='›', size=13, foreground=P.faint}
    row[#row+1] = crumb('c2', c.selected .. (entry and entry.stopped and ' ■' or ''), viz:event('UNIT'), level == 3, P)
    if cursor then
      row[#row+1] = o.text {key='s2', text='›', size=13, foreground=P.faint}
      row[#row+1] = crumb('c3', 'step ' .. cursor, viz:event('RECORD'), level == 4, P)
    end
  end
  local source = c.mode == 'file' and ('recording · ' .. tostring(c.path))
    or c.mode == 'socket' and ('attached · ' .. tostring(c.address)) or 'in-process'
  local status, tone = M.status(viz)
  -- Ring overflows the client reseeded from the late-attach snapshot.
  if (c.gaps or 0) > 0 then status = status .. ' · ' .. c.gaps .. (c.gaps == 1 and ' gap' or ' gaps') end
  row[#row+1] = o.box {key='spacer', width='fill'}
  row[#row+1] = o.text {key='source', text=source, size=11, foreground=P.muted, max_lines=1, overflow='ellipsis'}
  row[#row+1] = o.box {key='status', padding_x=8, padding_y=2, radius=9,
    background=(tone == 'live' and P.pass or tone == 'error' and P.fail or P.muted) .. '26',
    o.text {key='t', text=status, size=11, foreground=tone == 'live' and P.pass or tone == 'error' and P.fail or P.muted}}
  return o.box {key='header', width='fill', padding_x=14, padding_y=8, background=P.panel,
    o.row {key='r', gap=6, cross_alignment='center', children=row}}
end

-- Level 4: everything one record says, plus the alarms it raised.
local function record_detail(store, entry, frame, P)
  local r = frame.record
  local lines = {}
  local function add(k, v, color) lines[#lines+1] = o.text {key='l' .. #lines, size=12, max_lines=3, overflow='ellipsis',
    spans={{text=k .. '  ', foreground=P.muted}, {text=v, foreground=color or P.text}}} end
  add('actor', entry.path .. '  (' .. tostring(entry.machine) .. ')')
  add('step', string.format('%d  ·  seq %s  ·  t+%.3fs', frame.index, tostring(r.seq), (r.time or 0) / 1000))
  add('event', (r.event and r.event.type or '—') .. '  ·  origin ' .. tostring(r.origin))
  if r.event then add('payload', value_text(r.event, store.null)) end
  add('outcome', r.rejected and ('rejected (' .. tostring(r.reason) .. ')') or 'handled', r.rejected and P.medium or nil)
  local states = {}
  for _, id in ipairs(r.configuration) do if id ~= '' then states[#states+1] = id end end
  add('states', table.concat(states, ', '))
  for i, m in ipairs(r.microsteps) do
    local ts = {}
    for _, id in ipairs(m.transitions) do
      local t = entry.graph.transition_by_id[id]
      ts[#ts+1] = t and ('#' .. id .. ' ' .. t.source .. ' → ' .. (t.targets[1] or '⟲') .. ' [' .. t.label .. ']') or ('#' .. id)
    end
    add('microstep ' .. i, table.concat(ts, '; ') .. '  exit ' .. table.concat(m.exited, ',') .. '  enter ' .. table.concat(m.entered, ','))
  end
  for _, t in ipairs(r.timers) do
    add('timer', t.op .. ' ' .. tostring(t.state) .. ' after ' .. (t.name and (t.name .. ' ') or '')
      .. (t.delay and (t.delay .. 'ms') or ''))
  end
  for _, v in ipairs(r.invokes) do
    add('invoke', v.op .. ' ' .. tostring(v.id) .. ((v.src and v.src ~= v.id) and (' (' .. tostring(v.src) .. ')') or '') .. (v.error and (': ' .. value_text(v.error, store.null)) or ''),
      v.op == 'error' and P.high or nil)
  end
  local keys = {}
  for k in pairs(frame.changed) do keys[#keys+1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do add('context.' .. k, value_text(frame.context[k], store.null), P.accent) end
  for _, a in ipairs(store.alarms) do
    if a.actor == entry.path and a.step == frame.index then
      add('alarm', (a.severity == 'high' and 'HIGH ' or 'MED ') .. a.message, a.severity == 'high' and P.high or P.medium)
    end
  end
  return o.box {key='record', flex=1, height='fill', padding=20, background=P.canvas,
    o.scroll {key='scroll', axis='vertical', height='fill', o.column {key='lines', gap=6, children=lines}}}
end

-- The whole window for the visualizer actor `viz` over `store`.
-- props.motion pins the pulse phase and props.now the clock (storybook);
-- props.overview_now pins the overview's clock (scheduler time).
M.Screen = o.stateless(function(props, _, theme)
  local viz, store = props.viz, props.store
  local scheme = theme and theme.color_scheme or 'light'
  local P = draw.palettes[scheme] or draw.palettes.light
  local c = viz:context()
  -- Context reads are tracked per key: reading `revision` is what rebuilds
  -- the screen when an ingest batch lands in the (non-reactive) store.
  local _ = c.revision
  local entry = c.selected and store.actors[c.selected]
  local body, cursor
  if viz:matches('screen.overview') then
    local now = props.overview_now or store.now or 0
    body = o.row {key='overview-body', gap=0, flex=1, cross_alignment='stretch',
      o.box {key='topology', flex=1, height='fill', background=P.hmi, clip=true, alignment='center', padding=8,
        #store.order > 0 and overview_view.topology(viz, c, store, P, now, {motion=props.motion})
          or o.text {key='waiting', foreground=P.muted, text=c.message or 'Waiting for actors…'}},
      overview_view.alarms(viz, c, store, P),
    }
  elseif not entry or #entry.history.frames == 0 then
    body = o.box {key='main', width='fill', flex=1, alignment='center', background=P.canvas,
      o.text {key='waiting', text=c.message or (c.mode == 'socket' and ('Waiting for records from ' .. tostring(c.address)))
        or 'Waiting for actors…', foreground=P.muted}}
  else
    local hist = entry.history
    local n = #hist.frames
    cursor = c.cursor and math.min(c.cursor, n) or n
    local frame = hist.frames[cursor]
    local following = not c.cursor
    local now = props.now or frame.time
    local live = following and not props.motion
    local middle
    if viz:matches('screen.record') then
      middle = {record_detail(store, entry, frame, P)}
    else
      local plant = model.plant(store, entry)
      middle = {
        M.events(viz, c, entry.graph, frame, P, c.mode ~= 'file' and entry.machine ~= nil and not entry.stopped),
        o.box {key='diagram-frame', flex=1, height='fill', background=P.canvas, clip=true, alignment='center',
          M.diagram(plant, frame, now, P, scheme, {pulse=props.motion, live=live})},
        M.side(plant, frame, now, P, store.null, live),
      }
    end
    local column = {}
    -- The alarm that opened this unit, until acknowledged.
    local opened = c.alarm and store.alarms[c.alarm]
    if opened and opened.actor == entry.path and not (c.acked or {})[tostring(opened.id)] then
      local color = opened.severity == 'high' and P.high or P.medium
      column[#column+1] = o.box {key='banner', width='fill', padding_x=14, padding_y=6,
        background=opened.severity == 'high' and P.high_soft or P.medium_soft,
        o.row {key='r', gap=10, cross_alignment='center',
          o.text {key='t', size=12, flex=1, max_lines=1, overflow='ellipsis', spans={
            {text=(opened.severity == 'high' and 'ALARM  ' or 'WARNING  '), foreground=color},
            {text=opened.message .. '  (step ' .. opened.step .. ')', foreground=P.text}}},
          o.button {key='ack', label='Acknowledge', height=24, padding_x=8, font_size=11, variant='soft', tone='neutral',
            send=viz:event({type='ACK', id=opened.id})}}}
    end
    column[#column+1] = o.row {key='body', gap=0, flex=1, cross_alignment='stretch', children=middle}
    column[#column+1] = M.timeline(viz, hist, cursor, following, viz:matches('view.playing'), props.timeline_width or 1300, P, c.mode == 'file')
    body = o.column {key='main', gap=0, flex=1, cross_alignment='stretch', children=column}
  end
  return o.box {key='root', width='fill', height='fill', background=P.background,
    o.column {key='screen', gap=1, cross_alignment='stretch',
      M.header(viz, c, P, scheme, store, cursor),
      body,
    }}
end)

return M
