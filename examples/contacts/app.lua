local ouro = require("ouro")

-- Synthetic, in-memory records; the first three retain the original API IDs.
local seed = {
  { id = "ada", name = "Ada Lovelace", email = "ada@example.org" },
  { id = "grace", name = "Grace Hopper", email = "grace@example.org" },
  { id = "alan", name = "Alan Turing", email = "alan@example.org" },
}
for i = 4, 500 do
  seed[i] = { id = "person-" .. i, name = "Demo contact " .. i, email = "person" .. i .. "@example.org" }
end
local contacts, selected = ouro.signal(seed), ouro.signal(1)
local draft, terminal = ouro.signal(seed[1].name), ouro.signal(false)
local notes = {
  "Available for a quick conversation.",
  "Works across several teams. Prefers email for project updates and design reviews.",
  "Keeps detailed research notes and enjoys longer discussions about computing, collaboration, and how people learn. Available on weekday afternoons.",
}

local function select(index)
  selected:set(index)
  draft:set(contacts()[index].name)
end

local function index_of(id)
  local values = contacts()
  for i = 1, #values do if values[i].id == id then return i end end
end

local function rename(index, name)
  local previous, updated = contacts(), {}
  for i = 1, #previous do updated[i] = previous[i] end
  updated[index] = { id = previous[index].id, name = name, email = previous[index].email }
  contacts:set(updated)
  if selected() == index then draft:set(name) end
  return updated[index]
end

local function avatar(person, size)
  if person.id == "ada" or person.id == "grace" then
    return ouro.image { key = "avatar", src = "assets/" .. person.id .. ".png", width = size, height = size, alt = person.name }
  end
  local initials = person.id == "alan" and "AT" or "DC"
  return ouro.box { key = "avatar", width = size, height = size, alignment = "center", surface = "sidebar",
    ouro.text { key = "initials", text = initials, size = size / 3 },
  }
end

local function content()
  local values, current, dark = contacts(), selected(), terminal()
  local person = values[current]
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
          ouro.button { key = "theme", label = dark and "Light style" or "Terminal style", on_press = function() terminal:set(not terminal()) end },
        },
        ouro.text { key = "subtitle", text = "500 contacts. Variable-height rows. One shared MCP address book." },
        ouro.row { key = "panels", gap = 28, cross_alignment = "stretch",
          ouro.virtual_list {
            key = "people", width = 380, height = 440, item_count = #values, estimated_item_height = 132,
            item_key = function(index) return values[index].id end,
            render_item = function(index)
              local contact = values[index]
              return ouro.box { key = "row", padding = 10,
                ouro.row { key = "content", gap = 12,
                  avatar(contact, 40),
                  ouro.column { key = "text", gap = 6, flex = 1, cross_alignment = "stretch",
                    ouro.button { key = "select", label = (current == index and "• " or "") .. contact.name, on_press = function() select(index) end },
                    ouro.text { key = "email", text = contact.email },
                    ouro.text { key = "note", text = notes[(index - 1) % #notes + 1] },
                  },
                },
              }
            end,
          },
          ouro.column { key = "details", gap = 16, flex = 1, cross_alignment = "stretch",
            avatar(person, 80),
            ouro.text { key = "name", text = person.name, size = 24 },
            ouro.row { key = "email", gap = 10, cross_alignment = "center",
              ouro.icon { key = "icon", src = "assets/mail.svg", width = 20, height = 20 },
              ouro.text { key = "address", text = person.email },
            },
            ouro.text { key = "note", text = notes[(current - 1) % #notes + 1] },
            ouro.text_input { key = "rename", text = draft(), on_change = function(value) draft:set(value) end },
            ouro.button { key = "save", label = "Apply name", enabled = draft() ~= "" and draft() ~= person.name, on_press = function() rename(selected(), draft()) end },
            ouro.text { key = "hint", text = "Selection and names survive scrolling. MCP edits update this same state." },
            ouro.row { key = "exit", gap = 10, cross_alignment = "center",
              ouro.icon { key = "icon", src = "assets/log-out.svg", width = 20, height = 20 },
              ouro.button { key = "quit", label = "Quit", on_press = function() ouro.exit(0) end },
            },
          },
        },
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

return ouro.app {
  id = "dev.ourokit.contacts",
  actions = {
    GetContacts = {
      description = "Read the in-memory address book without opening a window.",
      inputSchema = empty_schema,
      outputSchema = { type = "object", properties = { contacts = { type = "array", items = contact_schema } }, required = { "contacts" }, additionalProperties = false },
      handler = function() return { contacts = contacts() } end,
    },
    SelectContact = {
      description = "Select a contact, updating the UI if it is active.",
      inputSchema = { type = "object", properties = { id = { type = "string" } }, required = { "id" }, additionalProperties = false },
      outputSchema = empty_schema,
      handler = function(params)
        local index = index_of(params.id)
        if index == nil then return ouro.action_error("ContactNotFound", { id = params.id }) end
        select(index)
      end,
    },
    RenameContact = {
      description = "Replace a contact's name in memory and update the shared UI state.",
      inputSchema = { type = "object", properties = { id = { type = "string" }, name = { type = "string" } }, required = { "id", "name" }, additionalProperties = false },
      outputSchema = { type = "object", properties = { contact = contact_schema }, required = { "contact" }, additionalProperties = false },
      handler = function(params)
        local index = index_of(params.id)
        if index == nil then return ouro.action_error("ContactNotFound", { id = params.id }) end
        return { contact = rename(index, params.name) }
      end,
    },
  },
  run = function()
    return { windows = { ouro.window { id = "main", title = "Contacts", width = 940, height = 650, content = content } } }
  end,
}
