local ouro = require("ouro")
local counter = require("example.counter")

return ouro.app {
  id = "dev.ouro.native",
  actions = {}, -- Enables the local control endpoint, including source reload.
  run = function()
    return { windows = {
      ouro.window {
        id = "main", title = "Native C counter", width = 420, height = 220,
        content = function()
          local value = counter.get()
          return ouro.box {
            key = "inset", padding = 24,
            ouro.column {
              key = "content", gap = 16,
              ouro.text { key = "value", text = "Native value: " .. value, size = 24 },
              ouro.button {
                key = "increment", label = "Add 7",
                on_press = function() counter.set((counter.get() + 7) % 101) end,
              },
              ouro.text { key = "note", text = "C owns the state. Ourokit signals update the UI." },
            },
          }
        end,
      },
    } }
  end,
}
