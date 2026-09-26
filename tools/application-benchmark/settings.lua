local ouro = require("ouro")

-- Kept separate from the widget gallery: this is the matched GTK/Qt workload.
return ouro.app {
  id = "dev.ourokit.benchmark.settings.ourokit",
  run = function()
    local count = ouro.signal(0)
    return { windows = {
      ouro.window {
        id = "main",
        title = "Ourokit settings benchmark",
        width = 560,
        height = 360,
        content = function()
          return ouro.column {
            key = "settings",
            gap = 12,
            ouro.text { key = "heading", text = "Ourokit controls", size = 18 },
            ouro.text { key = "count", text = "Pressed " .. count() .. " times" },
            ouro.row {
              key = "actions",
              gap = 8,
              ouro.button {
                key = "increment", label = "Increment", width = 160, height = 40,
                on_press = function() count:set(count() + 1) end,
              },
              ouro.button {
                key = "disabled", label = "Disabled", width = 160, height = 40,
                enabled = false,
              },
            },
          }
        end,
      },
    } }
  end,
}
