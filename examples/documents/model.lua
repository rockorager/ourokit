-- Plain functions over note data. Behavior over time lives in charts.lua.
return function(json)
  local M = {}

  -- An edit is a committed field value from the native editor. Returns an
  -- error message, or nil when the value is acceptable.
  function M.check_edit(field, value)
    if field ~= "title" and field ~= "text" then return "unknown field " .. tostring(field) end
    if type(value) ~= "string" then return field .. " must be text" end
    if field == "title" and value:find("[\r\n]") then return "title must be a single line" end
    if field == "text" and value:find("\r") then return "text must use LF line endings" end
  end
  -- Dirty is a calculation, not a state: a save records the revision it wrote.
  function M.dirty(d) return d.revision ~= d.saved_revision end
  function M.encode(d)
    return json.encode({ format = "dev.ourokit.ournote", version = 1, title = d.title, text = d.text })
  end
  function M.decode(bytes)
    local ok, value = pcall(json.decode, bytes)
    if not ok or type(value) ~= "table" or value.format ~= "dev.ourokit.ournote" or value.version ~= 1
      or type(value.title) ~= "string" or type(value.text) ~= "string"
      or value.title:find("[\r\n]") or value.text:find("\r") then
      return nil, "Not a valid Ourokit note"
    end
    for key in pairs(value) do
      if key ~= "format" and key ~= "version" and key ~= "title" and key ~= "text" then return nil, "Unknown note field: " .. key end
    end
    return { title = value.title, text = value.text }
  end
  function M.parse_uri_list(bytes)
    if type(bytes) ~= "string" then return {} end
    local uris = {}
    for line in (bytes .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      if line ~= "" and line:sub(1, 1) ~= "#" then uris[#uris + 1] = line end
    end
    return uris
  end
  function M.message(err)
    if type(err) == "table" or type(err) == "userdata" then return err.message or err.name or "Unknown error" end
    return tostring(err)
  end
  function M.label(d) return d.title ~= "" and d.title or "Untitled" end
  function M.tab_value(id) return tonumber(id:match("(%d+)$")) end
  function M.child_id(value) return "document." .. value end
  return M
end
