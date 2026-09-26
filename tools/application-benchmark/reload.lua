local ouro = require("ouro")

-- The driver replaces these two literals in a private temporary source copy.
local marker = "@MARKER@"
local color = "@COLOR@"

return ouro.app {
  id = "dev.ourokit.benchmark.reload",
  run = function()
    return { windows = {
      ouro.window {
        id = "main", title = "Reload measurement", width = 320, height = 240,
        content = function()
          return ouro.column {
            key = "content", gap = 12,
            ouro.box { key = "color", width = 128, height = 96, background = color },
            ouro.text { key = "marker", text = marker },
          }
        end,
      },
    } }
  end,
}
