local ouro = require("ouro")

local Counter = ouro.component(function(props)
  local count = ouro.signal(props.initial)
  local renders = 0
  return function()
    renders = renders + 1
    return ouro.column {
      key = "counter", gap = 10, flex = props.flex,
      ouro.label { key = "title", text = props.title, size = 18 },
      ouro.button {
        key = "increment", label = "Count: " .. count(),
        on_press = function() count:set(count() + 1) end,
      },
      ouro.label { key = "renders", text = "Counter renders: " .. renders },
    }
  end
end)

local Demo = ouro.component(function()
  local renamed, reversed, visible = ouro.signal(false), ouro.signal(false), ouro.signal(true)
  local renders = 0
  return function()
    renders = renders + 1
    local prefix = "Counter "
    if renamed() then prefix = "Renamed " end
    local first = Counter { key = "first", title = prefix .. "A", initial = 0, flex = 1 }
    local second = Counter { key = "second", title = prefix .. "B", initial = 100, flex = 1 }
    local counters
    if not visible() then counters = { second }
    elseif reversed() then counters = { second, first }
    else counters = { first, second } end
    return ouro.column {
      key = "content", gap = 20,
      ouro.label { key = "heading", text = "Retained Lua components", size = 24 },
      ouro.label { key = "renders", text = "Parent renders: " .. renders },
      ouro.row { key = "counters", gap = 40, children = counters },
      ouro.row {
        key = "controls", gap = 10,
        ouro.button { key = "rename", label = "Change props", on_press = function() renamed:set(not renamed()) end },
        ouro.button { key = "reverse", label = "Reorder", on_press = function() reversed:set(not reversed()) end },
        ouro.button { key = "visible", label = "Unmount / remount A", on_press = function() visible:set(not visible()) end },
      },
      ouro.label { key = "help", text = "Increment one counter: its sibling and parent do not render. Reorder and rename preserve state." },
    }
  end
end)

local Option = ouro.component(function(props)
  return function() return ouro.option { key = "option", value = props.value, label = props.label } end
end)
local selected = ouro.signal(1)

local function content() return Demo { key = "demo" } end
local first = "demo/content/counters/first/counter/increment"
local second = "demo/content/counters/second/counter/increment"
local controls = "demo/content/controls/"

return ouro.storybook {
  id = "components", title = "Retained Lua components",
  stories = {
    ouro.story { id = "counters/initial", name = "Independent counters", group = "Components", viewport = { width = 760, height = 320 }, content = content },
    ouro.story { id = "counters/first-click", name = "Only A renders", group = "Components", viewport = { width = 760, height = 320 }, content = content,
      actions = { { type = "click", target = first } } },
    ouro.story { id = "counters/second-click", name = "Only B renders", group = "Components", viewport = { width = 760, height = 320 }, content = content,
      actions = { { type = "click", target = second } } },
    ouro.story { id = "counters/props-reorder", name = "Props and reorder retain state", group = "Components", viewport = { width = 760, height = 320 }, content = content,
      actions = { { type = "click", target = first }, { type = "click", target = controls .. "rename" }, { type = "click", target = controls .. "reverse" } } },
    ouro.story { id = "counters/remount", name = "Remount resets A", group = "Components", viewport = { width = 760, height = 320 }, content = content,
      actions = { { type = "click", target = first }, { type = "click", target = controls .. "visible" }, { type = "click", target = controls .. "visible" } } },
    ouro.story { id = "options/namespaced", name = "Component options", group = "Components", viewport = { width = 320, height = 160 },
      content = function()
        return ouro.listbox { key = "options", selected = selected(), on_select = function(value) selected:set(value) end,
          Option { key = "first", value = 1, label = "First option" },
          Option { key = "second", value = 2, label = "Second option" },
        }
      end,
      actions = { { type = "hover", target = "options/second/option" } },
    },
  },
}
