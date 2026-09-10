local ouro = require("ouro")

local themes = {
  paper = {
    colors = {
      background = "#f5efe3", foreground = "#35291f", surface = "#fffaf0",
      primary = "#983b25", primary_hover = "#76301e", primary_foreground = "#fffaf0",
      accent = "#ecdbc3", accent_selected = "#ddc3a1", accent_foreground = "#35291f",
      input = "#b59d7d", border = "#b59d7d", ring = "#983b25",
      disabled = "#e3d7c5", disabled_foreground = "#776855", selection = "#ddc3a1",
    },
    typography = { family = "serif", size = 19 },
    controls = { height = 44, radius = 0, border_width = 1 },
    widgets = { button = { padding_x = 22 }, text = { font_size = 19 } },
  },
  terminal = {
    color_scheme = "dark",
    colors = {
      background = "#101810", foreground = "#b4f889", surface = "#101810",
      primary = "#172a17", primary_hover = "#244524", primary_foreground = "#b4f889",
      accent = "#244524", accent_selected = "#365c26", accent_foreground = "#d6ffb3",
      input = "#568845", border = "#568845", ring = "#c4ff96",
      disabled = "#162016", disabled_foreground = "#56714e", selection = "#365c26",
    },
    typography = { family = "monospace", size = 14 },
    controls = { height = 30, radius = 0, border_width = 1 },
    widgets = { button = { padding_x = 14, pressed = "#365c26" } },
  },
  candy = {
    colors = {
      background = "#f3eaff", foreground = "#39205b", surface = "#fffbff",
      primary = "#7c3ed6", primary_hover = "#6025b5", primary_foreground = "#ffffff",
      accent = "#e8d4ff", accent_selected = "#d4b6ff", accent_foreground = "#39205b",
      input = "#c5a3e7", border = "#c5a3e7", ring = "#8d3fe3",
      disabled = "#e4d4f1", disabled_foreground = "#887099", selection = "#d4b6ff",
    },
    typography = { family = "sans-serif", size = 18 },
    controls = { height = 48, radius = 24, border_width = 0 },
    widgets = { button = { padding_x = 28 }, text_input = { radius = 14, border_width = 2 } },
  },
}

-- All three entry points use this exact component tree and behavior. Only
-- ouro.app.theme changes; no control declares a style override.
local function content()
  local people = {
    { name = "Ada Lovelace", email = "ada@example.org" },
    { name = "Grace Hopper", email = "grace@example.org" },
    { name = "Alan Turing", email = "alan@example.org" },
  }
  local selected = ouro.signal(1)
  local name, email = ouro.signal(people[1].name), ouro.signal(people[1].email)
  local status = ouro.signal("All changes saved")
  local function select(index)
    selected:set(index)
    name:set(people[index].name)
    email:set(people[index].email)
    status:set("All changes saved")
  end
  return function()
    local options = {}
    for i = 1, #people do
      options[#options + 1] = ouro.option { key = "person-" .. i, value = i, label = people[i].name }
    end
    return ouro.box {
      key = "app", padding = 24,
      ouro.column {
        key = "body", gap = 24, cross_alignment = "stretch",
        ouro.text { key = "heading", text = "Contacts", size = 32 },
        ouro.text { key = "subtitle", text = "One app. Different defaults. No per-control styling." },
        ouro.row {
          key = "panels", gap = 32, cross_alignment = "stretch",
          ouro.box {
            key = "people-panel", width = 230,
            ouro.listbox { key = "people", selected = selected(), on_select = select, children = options },
          },
          ouro.column {
            key = "details", flex = 1, gap = 12, cross_alignment = "stretch",
            ouro.text { key = "name-label", text = "Name" },
            ouro.text_input { key = "name", text = name(), on_change = function(value) name:set(value); status:set("Unsaved changes") end },
            ouro.text { key = "email-label", text = "Email" },
            ouro.text_input { key = "email", text = email(), on_change = function(value) email:set(value); status:set("Unsaved changes") end },
            ouro.row {
              key = "actions", gap = 12,
              ouro.button { key = "save", label = "Save", on_press = function()
                people[selected()] = { name = name(), email = email() }
                status:set("Changes saved")
              end },
              ouro.button { key = "reset", label = "Reset", on_press = function() select(selected()) end },
              ouro.button { key = "sync", label = "Sync", enabled = false },
            },
            ouro.text { key = "status", text = status() },
          },
        },
      },
    }
  end
end

local function app(style)
  return ouro.app {
    id = "dev.ourokit.theme-" .. style,
    theme = themes[style],
    windows = { ouro.window {
      id = "main", title = "Contacts — " .. style, width = 800, height = 480,
      content = content(),
    } },
  }
end

return { app = app, themes = themes, content = content }
