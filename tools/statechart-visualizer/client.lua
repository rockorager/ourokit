-- The visualizer's runtime.statecharts client: one fetch, paging until
-- caught up. `call(arguments)` performs the MCP tools/call and returns the
-- JSON-RPC reply; `cursor` = {after, seed, epoch, gaps} is updated in place;
-- `ingest(record, time)` takes each record once. Returns whether anything
-- other than the visualizer's own feedback (`own(record)`) arrived.
--   * Records are ingested strictly by ring sequence (the cursor), and an
--     actor's `latest` only when the cursor has not passed it yet
--     (latest_sequence; 0 marks a synthetic attach record), so nothing is
--     ingested twice.
--   * `more` says the page was cut (limit or byte budget): fetch again.
--   * A gap (dropped) asks for the late-attach actors again.
--   * A new epoch means the app restarted behind this address: start over.
local M = {}

function M.fetch(call, cursor, ingest, own, json, limit)
  local changed = false
  while true do
    local reply = call({after = cursor.after, limit = limit, text = true, seed = cursor.seed, actors = cursor.seed == nil})
    if reply.error then error('FetchFailed: ' .. tostring(reply.error.message), 0) end
    local out = reply.result.structuredContent
    if reply.result.isError then error('FetchFailed: ' .. json.encode(out), 0) end
    if cursor.epoch ~= nil and out.epoch ~= nil and out.epoch ~= cursor.epoch then
      cursor.after, cursor.seed, cursor.epoch, changed = 0, nil, out.epoch, true
    else
      cursor.epoch = out.epoch or cursor.epoch
      -- Started records (graphs) first: the page's records may belong to
      -- actors this client meets for the first time.
      for _, actor in ipairs(out.actors or {}) do
        if actor.started ~= json.null then ingest(json.decode(actor.started), out.time_ms) end
      end
      for _, entry in ipairs(out.records) do
        local record = json.decode(entry.record)
        ingest(record, entry.time_ms)
        if not own(record) then changed = true end
      end
      -- The ring evicted records past the cursor: reseed from current state
      -- (the next page asks for actors).
      if out.dropped and cursor.seed ~= nil then cursor.seed, cursor.gaps, changed = nil, (cursor.gaps or 0) + 1, true end
      if out.actors and not out.more then
        for _, actor in ipairs(out.actors) do
          local seen = (actor.latest_sequence or 0) > 0 and actor.latest_sequence <= out.next
          if actor.latest ~= json.null and not seen then ingest(json.decode(actor.latest), out.time_ms) end
        end
        cursor.seed, changed = out.seed, true
      end
      cursor.after = out.next
      if not out.more and cursor.seed ~= nil then return changed end
    end
  end
end

return M
