local ouro = require("ouro")

-- Sample in-memory data. A real address book would read/write its datastore.
local contacts = ouro.signal({
  { id = "ada", name = "Ada Lovelace", email = "ada@example.org" },
  { id = "grace", name = "Grace Hopper", email = "grace@example.org" },
  { id = "alan", name = "Alan Turing", email = "alan@example.org" },
})
local selected = ouro.signal(1)

local function index_of(id)
  local values = contacts()
  for i = 1, #values do
    if values[i].id == id then return i end
  end
end

return ouro.app {
  id = "dev.ourokit.contacts",
  interface = [[
    # A small address book, available without opening a window.
    interface dev.ourokit.contacts
    type Contact (id: string, name: string, email: string)
    method GetContacts() -> (contacts: []Contact)
    method SelectContact(id: string) -> ()
    method RenameContact(id: string, name: string) -> (contact: Contact)
    error ContactNotFound(id: string)
  ]],
  actions = {
    GetContacts = function()
      return { contacts = contacts() }
    end,
    SelectContact = function(params)
      local index = index_of(params.id)
      if index == nil then return ouro.action_error("ContactNotFound", { id = params.id }) end
      selected:set(index)
    end,
    RenameContact = function(params)
      local index = index_of(params.id)
      if index == nil then return ouro.action_error("ContactNotFound", { id = params.id }) end
      local previous = contacts()
      local updated = {}
      for i = 1, #previous do updated[i] = previous[i] end
      updated[index] = { id = params.id, name = params.name, email = previous[index].email }
      contacts:set(updated)
      return { contact = updated[index] }
    end,
  },
  run = function()
    return { windows = {
      ouro.window {
        id = "main", title = "Contacts", width = 660, height = 420,
        content = function()
          local values = contacts()
          local person = values[selected()]
          local options = {}
          for i = 1, #values do
            options[#options + 1] = ouro.option { key = values[i].id, value = i, label = values[i].name }
          end
          return ouro.box {
            key = "app", padding = 24,
            ouro.column {
              key = "body", gap = 24, cross_alignment = "stretch",
              ouro.label { key = "title", text = "Contacts", size = 28 },
              ouro.label { key = "subtitle", text = "One address book. With or without a window." },
              ouro.row {
                key = "panels", gap = 24, cross_alignment = "stretch",
                ouro.box {
                  key = "sidebar", width = 240, padding = 12, surface = "sidebar",
                  ouro.listbox {
                    key = "people", gap = 6, selected = selected(),
                    on_select = function(index) selected:set(index) end,
                    children = options,
                  },
                },
                ouro.column {
                  key = "details", gap = 16, flex = 1,
                  ouro.label { key = "name", text = person.name, size = 22 },
                  ouro.label { key = "email", text = person.email },
                  ouro.label { key = "note", text = "Changes through Varlink appear here." },
                  ouro.button {
                    key = "quit", label = "Quit", width = 100, height = 40,
                    on_press = function() ouro.exit(0) end,
                  },
                },
              },
            },
          }
        end,
      },
    } }
  end,
}
