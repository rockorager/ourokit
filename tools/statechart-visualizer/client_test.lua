-- The runtime.statecharts client against a scripted endpoint (second review
-- L-5): no duplicate ingest on reseed, cut pages are not "caught up", and
-- a restarted app resets the cursor.
--   (cd tools/statechart-visualizer && ../../zig-out/bin/ouroctl test client_test.lua)
local o = require('ouro')
local client = require('client')
local json = o.json

local function record(actor, sequence, event)
  return json.encode({kind = 'transition', actor = actor, sequence = sequence, event = {type = event}})
end

-- A fake endpoint: replies in order, remembering each call's arguments.
local function endpoint(replies)
  local calls = {}
  return function(arguments)
    calls[#calls + 1] = arguments
    local out = assert(table.remove(replies, 1), 'unexpected call after=' .. tostring(arguments.after))
    out.records = out.records or {}
    return {result = {structuredContent = out, isError = false}}
  end, calls
end

local function run(replies, cursor)
  local call, calls = endpoint(replies)
  local seen = {}
  local changed = client.fetch(call, cursor, function(r) seen[#seen + 1] = r.event and r.event.type or r.kind end,
    function() return false end, json, 2)
  return seen, calls, changed
end

local function list(t) return table.concat(t, ',') end

return {
  ['an actor latest already read from the ring is not ingested again'] = function()
    local seen = run({{epoch = 7, next = 2, seed = 1, records = {
        {sequence = 1, record = record('a', 1, 'GO')}, {sequence = 2, record = record('a', 2, 'STOP')}},
      actors = {{actor = 'a', started = json.encode({kind = 'actor'}), latest = record('a', 2, 'STOP'), latest_sequence = 2}}},
    }, {after = 0})
    assert(list(seen) == 'actor,GO,STOP', list(seen))
    -- A synthetic attach record (latest_sequence 0) is always applied.
    seen = run({{epoch = 7, next = 0, seed = 1,
      actors = {{actor = 'a', started = json.null, latest = record('a', nil, 'ouro.attach'), latest_sequence = 0}}}}, {after = 0})
    assert(list(seen) == 'ouro.attach', list(seen))
  end,

  ['a page cut short (more) is followed by another before actors apply'] = function()
    local cursor = {after = 0}
    local seen, calls = run({
      -- Cut by the byte budget: one record, fewer than the limit (2), more = true.
      {epoch = 7, next = 1, more = true, seed = 1, records = {{sequence = 1, record = record('a', 1, 'GO')}},
        actors = {{actor = 'a', started = json.null, latest = record('a', 3, 'LATE'), latest_sequence = 3}}},
      {epoch = 7, next = 3, seed = 1, records = {{sequence = 2, record = record('a', 2, 'STOP')}, {sequence = 3, record = record('a', 3, 'LATE')}},
        actors = {{actor = 'a', started = json.null, latest = record('a', 3, 'LATE'), latest_sequence = 3}}},
    }, cursor)
    assert(list(seen) == 'GO,STOP,LATE', list(seen))
    assert(#calls == 2 and calls[2].after == 1 and cursor.after == 3 and cursor.seed == 1)
  end,

  ['a new epoch starts over from the beginning'] = function()
    local cursor = {after = 40, seed = 3, epoch = 7}
    local seen, calls = run({
      {epoch = 9, next = 40, seed = 1},
      {epoch = 9, next = 1, seed = 1, records = {{sequence = 1, record = record('a', 1, 'GO')}},
        actors = {{actor = 'a', started = json.encode({kind = 'actor'}), latest = record('a', 1, 'GO'), latest_sequence = 1}}},
    }, cursor)
    assert(calls[2].after == 0 and calls[2].actors == true and calls[2].seed == nil, 'restart: cursor and seed reset')
    assert(list(seen) == 'actor,GO' and cursor.after == 1 and cursor.epoch == 9 and cursor.seed == 1, list(seen))
  end,

  ['a gap reseeds and counts'] = function()
    local cursor = {after = 5, seed = 1, epoch = 7, gaps = 0}
    local seen = run({
      {epoch = 7, next = 9, first = 8, dropped = true, seed = 1, records = {{sequence = 8, record = record('a', 8, 'X')},
        {sequence = 9, record = record('a', 9, 'Y')}}},
      {epoch = 7, next = 9, seed = 1,
        actors = {{actor = 'a', started = json.null, latest = record('a', 9, 'Y'), latest_sequence = 9}}},
    }, cursor)
    assert(list(seen) == 'X,Y' and cursor.gaps == 1 and cursor.seed == 1 and cursor.after == 9, list(seen))
  end,

  ['records of an actor first met in this page are kept'] = function()
    -- Like model.ingest: transitions of actors without a started record are dropped.
    local call = endpoint({{epoch = 7, next = 1, seed = 1, records = {{sequence = 1, record = record('a', 1, 'GO')}},
      actors = {{actor = 'a', started = json.encode({kind = 'actor', actor = 'a'}), latest = record('a', 1, 'GO'), latest_sequence = 1}}}})
    local known, kept = {}, {}
    client.fetch(call, {after = 0}, function(r)
      if r.kind == 'actor' then known[r.actor] = true elseif known[r.actor] then kept[#kept + 1] = r.event.type end
    end, function() return false end, json, 2)
    assert(list(kept) == 'GO', 'got ' .. list(kept))
  end,
}
