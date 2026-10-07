-- Plain functions over desktop entries. Behavior over time lives in charts.lua.
-- Entries are the tables `ouro.xdg.applications.list()` returns. They are kept
-- as-is so `prepare_launch` gets them back unchanged; optional fields are
-- `ouro.json.null`, so only string values count as present.
local M = {}

local function text(value) return type(value) == "string" and value or nil end
M.text = text

local function lower(value) return (text(value) or ""):lower() end

local function by_name(a, b)
  local x, y = lower(a.name), lower(b.name)
  if x ~= y then return x < y end
  return a.id < b.id
end

-- Visible entries, ordered by name. Returns a new list of the same entries.
function M.catalog(entries)
  local out = {}
  for _, entry in ipairs(entries) do
    if entry.visible then out[#out + 1] = entry end
  end
  table.sort(out, by_name)
  return out
end

local function words(query)
  local out = {}
  for word in lower(query):gmatch("%S+") do out[#out + 1] = word end
  return out
end

local function starts(haystack, needle) return haystack:sub(1, #needle) == needle end

-- Does any word of `haystack` start with `word`?
local function word_start(haystack, word)
  return haystack:find("%f[%w]" .. (word:gsub("%p", "%%%0"))) ~= nil
end

-- How well one query word matches an entry; 0 means no match.
local function word_score(entry, word)
  local name = lower(entry.name)
  if starts(name, word) then return 100 end
  if word_start(name, word) then return 80 end
  if name:find(word, 1, true) then return 60 end
  if word_start(lower(entry.generic_name), word) then return 40 end
  for _, keyword in ipairs(entry.keywords or {}) do
    if starts(lower(keyword), word) then return 30 end
  end
  if word_start(lower(entry.comment), word) then return 20 end
  if lower(entry.id):find(word, 1, true) then return 10 end
  return 0
end

-- Entries matching every word of the query, best first. An empty query
-- returns the catalog unchanged.
function M.results(entries, query)
  local terms = words(query)
  if #terms == 0 then return entries end
  local scored = {}
  for _, entry in ipairs(entries) do
    local total = 0
    for _, word in ipairs(terms) do
      local score = word_score(entry, word)
      if score == 0 then total = nil break end
      total = total + score
    end
    if total then scored[#scored + 1] = { entry = entry, score = total } end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return by_name(a.entry, b.entry)
  end)
  local out = {}
  for i, item in ipairs(scored) do out[i] = item.entry end
  return out
end

-- Keyboard selection wraps around both ends.
function M.move(index, delta, count)
  if count == 0 then return 1 end
  return (index - 1 + delta) % count + 1
end

function M.clamp(index, count)
  if count == 0 then return 1 end
  return math.max(1, math.min(index, count))
end

-- A secondary line for a result row.
function M.detail(entry)
  return text(entry.comment) or text(entry.generic_name) or entry.id
end

-- Named icons only: desktop files may also give absolute paths, which
-- `ouro.xdg.icon` does not accept.
function M.icon(entry)
  local icon = text(entry.icon)
  if icon and icon ~= "" and not icon:find("/", 1, true) then return icon end
end

function M.message(err)
  if type(err) == "table" or type(err) == "userdata" then
    return text(err.message) or text(err.name) or "Unknown error"
  end
  return tostring(err)
end

return M
