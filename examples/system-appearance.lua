local ouro = require("ouro")
local count = ouro.signal(0)

local Counter = ouro.component(function()
  return function()
    return ouro.button {
      key = "counter",
      label = "Count: " .. count(),
      on_press = function() count:set(count() + 1) end,
    }
  end
end)

local function content()
  return ouro.box { key = "padding", padding = 24,
    ouro.column { key = "content", gap = 20,
      ouro.text { key = "title", text = "System appearance", size = 28 },
      ouro.text { key = "description", text = "This window follows ourosettings automatically." },
      Counter { key = "retained" },
      ouro.theme { key = "fixed", color_scheme = "light",
        ouro.box { key = "card", padding = 20, background = "#ffffff",
          ouro.column { key = "body", gap = 12,
            ouro.text { key = "label", text = "This section always stays light." },
            ouro.button { key = "button", label = "Explicit light theme" },
          },
        },
      },
    },
  }
end

return ouro.app {
  id = "dev.ourokit.system-appearance",
  actions = {},
  -- Typography-only overrides still inherit the system's color scheme.
  theme = { typography = { size = 16 } },
  run = function()
    return { windows = {
      ouro.window { id = "main", title = "System appearance", width = 560, height = 400, content = content },
    } }
  end,
}
