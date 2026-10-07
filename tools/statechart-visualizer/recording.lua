-- Recorded statechart sessions (design/statecharts.md §14). A recording is
-- an `ouro.machine.log`: inputs only, against the app's charts. Replaying it
-- with `--records` expands it into the §10 inspection stream this tool
-- draws, graphs included:
--   ouroctl replay app.jsonl examples/app --records app.records.jsonl
--   ouroctl run tools/statechart-visualizer/app.lua -- app.records.jsonl
local M = {}

-- Parses JSON lines into §10 records. Returns records, or nil and a message
-- that says what to do with a raw log.
function M.parse(text, json)
  local records = {}
  local number = 0
  for line in text:gmatch('[^\n]+') do
    number = number + 1
    if line:find('%S') then
      local ok, value = pcall(json.decode, line)
      if not ok or type(value) ~= 'table' then return nil, 'line ' .. number .. ' is not JSON' end
      if value.format == 'ouro.machine.log' then
        return nil, 'this is a raw recording; expand it first with: ouroctl replay <log> <app> --records <file>'
      end
      if value.kind ~= 'actor' and value.kind ~= 'transition' then
        return nil, 'line ' .. number .. ' is not a statechart record'
      end
      records[#records + 1] = value
    end
  end
  if #records == 0 then return nil, 'no records' end
  return records
end

return M
