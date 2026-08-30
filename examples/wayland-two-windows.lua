local clicked = ouro.signal(false)

local function content()
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
end

return ouro.app {
  id = "dev.ourokit.example",
  windows = {
    ouro.window {
      id = "main",
      title = "Ourokit",
      width = 480,
      height = 320,
      content = content,
    },
    ouro.window {
      id = "secondary",
      title = "Ourokit second window",
      width = 420,
      height = 320,
      content = content,
    },
  },
}
