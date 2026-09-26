-- State and validation kept separate so it can be tested without a compositor.
return function(json)
  local M = { documents = {}, next_id = 1 }

  function M.new(title, text, path)
    local d = { id = "document-" .. M.next_id, title = title or "Untitled", text = text or "", path = path,
      dirty = false, revision = 0, save_serial = 0, saving = false, closing = false, error = nil }
    M.next_id = M.next_id + 1
    M.documents[#M.documents + 1] = d
    return d
  end
  function M.edit(d, field, value)
    assert(field == "title" or field == "text")
    if type(value) ~= "string" or value:find("[\r\n]") then return nil, field .. " must be a single line" end
    if d[field] ~= value then d[field], d.dirty, d.revision = value, true, d.revision + 1 end
    return true
  end
  function M.encode(d)
    return json.encode({ format = "dev.ourokit.ournote", version = 1, title = d.title, text = d.text })
  end
  function M.decode(bytes)
    local ok, value = pcall(json.decode, bytes)
    if not ok or type(value) ~= "table" or value.format ~= "dev.ourokit.ournote" or value.version ~= 1
      or type(value.title) ~= "string" or type(value.text) ~= "string"
      or value.title:find("[\r\n]") or value.text:find("[\r\n]") then
      return nil, "Not a valid Ourokit note"
    end
    for key in pairs(value) do
      if key ~= "format" and key ~= "version" and key ~= "title" and key ~= "text" then return nil, "Unknown note field: " .. key end
    end
    return { title = value.title, text = value.text }
  end
  function M.begin_save(d)
    if d.saving then return nil, "Save already in progress" end
    d.save_serial = d.save_serial + 1
    local operation = { serial = d.save_serial, revision = d.revision, bytes = M.encode(d) }
    d.saving, d.save_active = true, operation
    return operation
  end
  function M.cancel_save(d, operation)
    if d.save_active ~= operation then return false end
    d.saving, d.save_active = false, nil
    return true
  end
  function M.finish_save(d, operation, path, ok, message)
    if d.save_active ~= operation then return false end
    d.saving, d.save_active = false, nil
    if not ok then d.error = message or "Save failed"; return false end
    d.path, d.error = path, nil
    -- A late save never marks edits made after its snapshot as saved.
    if operation.serial == d.save_serial and operation.revision == d.revision then d.dirty = false end
    return true
  end
  function M.parse_uri_list(bytes)
    if type(bytes) ~= "string" then return {} end
    local uris = {}
    for line in (bytes .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      if line ~= "" and line:sub(1, 1) ~= "#" then uris[#uris + 1] = line end
    end
    return uris
  end
  function M.remove(d)
    for i, candidate in ipairs(M.documents) do if candidate == d then table.remove(M.documents, i); return true end end
  end
  return M
end
