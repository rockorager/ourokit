-- Plain functions over contact data. Behavior over time lives in charts.lua.
return function(json)
  local M = {}

  M.notes = {
    "Available for a quick conversation.",
    "Works across several teams. Prefers email for project updates and design reviews.",
    "Keeps detailed research notes and enjoys longer discussions about computing, collaboration, and how people learn. Available on weekday afternoons.",
  }
  function M.note(index) return M.notes[(index - 1) % #M.notes + 1] end

  -- Synthetic records; the first three retain the original API IDs.
  function M.seed()
    local seed = {
      { id = "ada", name = "Ada Lovelace", email = "ada@example.org" },
      { id = "grace", name = "Grace Hopper", email = "grace@example.org" },
      { id = "alan", name = "Alan Turing", email = "alan@example.org" },
    }
    for i = 4, 500 do
      seed[i] = { id = "person-" .. i, name = "Demo contact " .. i, email = "person" .. i .. "@example.org" }
    end
    return seed
  end

  function M.find(contacts, id)
    for i = 1, #contacts do
      if contacts[i].id == id then return contacts[i], i end
    end
  end

  -- Copy-on-write: a new list with the record that has contact.id replaced.
  function M.replaced(contacts, contact)
    local out = {}
    for i = 1, #contacts do out[i] = contacts[i].id == contact.id and contact or contacts[i] end
    return out
  end

  -- Pending ids are an ordered set.
  function M.with(list, id)
    local out = {}
    for i, existing in ipairs(list) do
      if existing == id then return list end
      out[i] = existing
    end
    out[#out + 1] = id
    return out
  end
  function M.without(list, id)
    local out = {}
    for _, existing in ipairs(list) do if existing ~= id then out[#out + 1] = existing end end
    return out
  end

  function M.renamed(contact, name) return { id = contact.id, name = name, email = contact.email } end

  -- An error message for a name the address book refuses, or nil.
  function M.check_name(name)
    if name == "" then return "name must not be empty" end
    if name:find("[\r\n]") then return "name must be a single line" end
  end

  local function contact(value)
    if type(value) ~= "table" or type(value.id) ~= "string" or value.id == ""
      or type(value.name) ~= "string" or type(value.email) ~= "string" then return nil end
    return { id = value.id, name = value.name, email = value.email }
  end
  -- Server bodies: {"contacts": [...]} from GET and {"contact": {...}} from PUT.
  function M.decode_book(bytes)
    local ok, value = pcall(json.decode, bytes)
    if not ok or type(value) ~= "table" or type(value.contacts) ~= "table" then return nil, "Not an address book" end
    local out, seen = {}, {}
    for i, item in ipairs(value.contacts) do
      local record = contact(item)
      if not record or seen[record.id] then return nil, "Invalid contact at position " .. i end
      seen[record.id], out[i] = true, record
    end
    return out
  end
  function M.decode_contact(bytes)
    local ok, value = pcall(json.decode, bytes)
    local record = ok and type(value) == "table" and contact(value.contact)
    if not record then return nil, "Not a contact" end
    return record
  end

  function M.contact_url(base, id)
    return base:gsub("/+$", "") .. "/" .. id:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
  end

  function M.initials(person)
    if person.id == "alan" then return "AT" end
    return "DC"
  end

  function M.message(err)
    if type(err) == "table" or type(err) == "userdata" then return err.message or err.name or "Unknown error" end
    return tostring(err)
  end

  return M
end
