local ouro = require("ouro")

local clicked = ouro.signal(false)

return ouro.app {
  id = "dev.ourokit.benchmark.ourokit",
  windows = {
    ouro.window {
      id = "main",
      title = "Ourokit",
      width = 480,
      height = 320,
      content = function()
        ouro.column {
          key = "content",
          children = function()
            ouro.button {
              key = "benchmark",
              label = clicked() and "Clicked" or "Benchmark",
              width = 160,
              height = 44,
              on_press = function()
                clicked:set(not clicked())
              end,
            }
          end,
        }
      end,
    },
  },
}
