local ouro = require("ouro")
local machine = ouro.machine
local model = require("model")(ouro.json)
local paths = ouro.xdg.paths("dev.ourokit.contacts")

local function failure(message) error({ message = message }, 0) end

-- The address book comes from server.json's URL when it exists, else from
-- the built-in sample, which keeps renames in memory.
local function remote_url()
  local bytes = paths and paths.config and ouro.files.read(paths.config .. "/server.json", { max_bytes = 64 * 1024 })
  if not bytes then return nil end
  local ok, value = pcall(ouro.json.decode, bytes)
  if not ok or type(value) ~= "table" or value.version ~= 1 or type(value.url) ~= "string" then
    failure('server.json must be {"version": 1, "url": "http(s)://…"}')
  end
  return value.url
end

local charts = require("charts")(ouro, model, {
  load = function()
    local url = remote_url()
    if not url then return { contacts = model.seed() } end
    local response = ouro.http.get(url, { timeout_ms = 10000 })
    if response.status ~= 200 then failure("GET " .. url .. " returned " .. response.status) end
    local contacts, err = model.decode_book(response.body)
    if not contacts then failure(err) end
    return { contacts = contacts, remote = url }
  end,
  save = function(remote, contact)
    if not remote then return { id = contact.id, name = contact.name, email = contact.email } end
    local url = model.contact_url(remote, contact.id)
    local response = ouro.http.request { method = "PUT", url = url, timeout_ms = 10000,
      headers = { ["Content-Type"] = "application/json" }, body = ouro.json.encode({ name = contact.name }) }
    if response.status ~= 200 then failure("PUT " .. url .. " returned " .. response.status) end
    local saved, err = model.decode_contact(response.body)
    if not saved or saved.id ~= contact.id then failure(err or "server returned another contact") end
    return saved
  end,
  exit = function() ouro.exit(0) end,
})

-- MCP calls and the window share one address book. A root actor lives in
-- application scope, so whichever starts it first, it outlives the call.
local book = charts.book:actor()
local function loaded()
  book:start()
  while book:matches("loading") do ouro.sleep(10) end
  if book:matches("failed") then return ouro.action_error("LoadFailed", { message = book:context().error }) end
end
local appearance -- Presentation chart, started by run.

local function avatar(person, size)
  if person.id == "ada" or person.id == "grace" then
    return ouro.image { key = "avatar", src = "assets/" .. person.id .. ".png", width = size, height = size, alt = person.name }
  end
  return ouro.box { key = "avatar", width = size, height = size, alignment = "center", surface = "sidebar",
    ouro.text { key = "initials", text = model.initials(person), size = size / 3 },
  }
end

local function summary(c)
  local count = #c.contacts .. " contacts"
  if not c.remote then return count .. ". Variable-height rows. One shared MCP address book." end
  local status = "Synced with " .. c.remote .. "."
  if book:matches("ready.lifecycle.quitting") then status = "Saving changes before quitting…"
  elseif book:matches("ready.sync.retrying") then status = "Could not save: " .. c.error .. ". Retrying in 5 s."
  elseif #c.pending > 0 then status = "Saving " .. #c.pending .. (#c.pending == 1 and " change…" or " changes…") end
  return count .. ". " .. status
end

local function details(c, person, index)
  local rename = { type = "RENAME", id = person.id, name = c.draft }
  return ouro.column { key = "details", gap = 16, flex = 1, cross_alignment = "stretch",
    avatar(person, 80),
    ouro.text { key = "name", text = person.name, size = 24 },
    ouro.row { key = "email", gap = 10, cross_alignment = "center",
      ouro.icon { key = "icon", src = "assets/mail.svg", width = 20, height = 20 },
      ouro.text { key = "address", text = person.email },
    },
    ouro.text { key = "note", text = model.note(index) },
    ouro.text_input { key = "rename", text = c.draft, on_change = function(value) book:send { type = "EDIT", value = value } end },
    ouro.button { key = "save", label = "Apply name", enabled = book:can(rename), on_press = book:sender(rename) },
    ouro.text { key = "hint", text = "Selection and names survive scrolling. MCP edits update this same state." },
    ouro.row { key = "exit", gap = 10, cross_alignment = "center",
      ouro.icon { key = "icon", src = "assets/log-out.svg", width = 20, height = 20 },
      ouro.button { key = "quit", label = "Quit", on_press = book:sender("QUIT") },
    },
  }
end

local function panels(c)
  local values = c.contacts
  local person, index = model.find(values, c.selected)
  return ouro.row { key = "panels", gap = 28, cross_alignment = "stretch",
    ouro.virtual_list {
      key = "people", width = 380, height = 440, item_count = #values, estimated_item_height = 132,
      item_key = function(i) return values[i].id end,
      render_item = function(i)
        local contact = values[i]
        return ouro.box { key = "row", padding = 10,
          ouro.row { key = "content", gap = 12,
            avatar(contact, 40),
            ouro.column { key = "text", gap = 6, flex = 1, cross_alignment = "stretch",
              ouro.button { key = "select", label = (contact.id == c.selected and "• " or "") .. contact.name,
                on_press = book:sender { type = "SELECT", id = contact.id } },
              ouro.text { key = "email", text = contact.email },
              ouro.text { key = "note", text = model.note(i) },
            },
          },
        }
      end,
    },
    person and details(c, person, index) or ouro.text { key = "empty", text = "No contacts." },
  }
end

local function unavailable(c)
  local loading = book:matches("loading")
  return ouro.column { key = "unavailable", gap = 16,
    ouro.text { key = "status", text = loading and "Loading contacts…" or ("Could not load contacts: " .. c.error) },
    ouro.button { key = "retry", label = "Retry", enabled = book:can("RETRY"), on_press = book:sender("RETRY") },
  }
end

local function content()
  local c, dark = book:context(), appearance:matches("terminal")
  local ready = book:matches("ready")
  return ouro.theme {
    key = "app", color_scheme = dark and "dark" or "light",
    colors = dark and { background = "#101810", foreground = "#b4f889", primary = "#244524", primary_hover = "#365c26", primary_foreground = "#d6ffb3", sidebar = "#192719", sidebar_foreground = "#b4f889", input = "#568845", ring = "#b4f889" } or nil,
    typography = { family = dark and "monospace" or "sans-serif", size = 16 },
    controls = { height = 36, radius = dark and 0 or 10, border_width = dark and 1 or 0 },
    widgets = { text_input = { border_width = 1 } },
    ouro.box { key = "inset", padding = 20,
      ouro.column { key = "body", gap = 16, cross_alignment = "stretch",
        ouro.row { key = "heading", gap = 16, cross_alignment = "center",
          ouro.text { key = "title", text = "Contacts", size = 30, flex = 1 },
          book:can("RETRY") and ready and ouro.button { key = "retry", label = "Retry now", on_press = book:sender("RETRY") } or ouro.box { key = "no-retry" },
          ouro.button { key = "theme", label = dark and "Light style" or "Terminal style", on_press = appearance:sender("TOGGLE") },
        },
        ouro.text { key = "subtitle", text = ready and summary(c) or "One shared MCP address book." },
        ready and panels(c) or unavailable(c),
      },
    },
  }
end

local contact_schema = {
  type = "object",
  properties = { id = { type = "string" }, name = { type = "string" }, email = { type = "string" } },
  required = { "id", "name", "email" }, additionalProperties = false,
}
local empty_schema = { type = "object", additionalProperties = false }

-- Actions are external events: SELECT and RENAME go to the same chart the
-- window uses, and its guards decide what is accepted.
return ouro.app {
  id = "dev.ourokit.contacts",
  single_instance = true,
  actions = {
    GetContacts = {
      description = "Read the address book without opening a window.",
      inputSchema = empty_schema,
      outputSchema = { type = "object", properties = { contacts = { type = "array", items = contact_schema } }, required = { "contacts" }, additionalProperties = false },
      handler = function()
        local err = loaded(); if err then return err end
        return { contacts = machine.plain(book:context().contacts) }
      end,
    },
    SelectContact = {
      description = "Select a contact, updating the UI if it is active.",
      inputSchema = { type = "object", properties = { id = { type = "string" } }, required = { "id" }, additionalProperties = false },
      outputSchema = empty_schema,
      handler = function(params)
        local err = loaded(); if err then return err end
        local event = { type = "SELECT", id = params.id }
        if not book:can(event) then return ouro.action_error("ContactNotFound", { id = params.id }) end
        book:send(event)
      end,
    },
    RenameContact = {
      description = "Rename a contact in the shared address book; the UI updates at once and the change is saved in the background.",
      inputSchema = { type = "object", properties = { id = { type = "string" }, name = { type = "string" } }, required = { "id", "name" }, additionalProperties = false },
      outputSchema = { type = "object", properties = { contact = contact_schema }, required = { "contact" }, additionalProperties = false },
      handler = function(params)
        local err = loaded(); if err then return err end
        if not model.find(book:context().contacts, params.id) then return ouro.action_error("ContactNotFound", { id = params.id }) end
        local invalid = model.check_name(params.name)
        if invalid then return ouro.action_error("InvalidName", { name = params.name, message = invalid }) end
        book:send { type = "RENAME", id = params.id, name = params.name } -- Ignored when the name is unchanged.
        return { contact = machine.plain((model.find(book:context().contacts, params.id))) }
      end,
    },
  },
  run = function()
    book:start()
    appearance = charts.appearance:start()
    return { windows = { ouro.window { id = "main", title = "Contacts", width = 940, height = 650,
      on_close_request = book:sender("QUIT"), content = content } } }
  end,
}
