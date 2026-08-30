local clicked = ouro.signal(false)

return ouro.app {
  id = "dev.ourokit.example",
  windows = {
    ouro.window {
      id = "main",
      title = "Ourokit",
      width = 480,
      height = 320,
      content = function()
        ouro.button {
          key = "benchmark",
          label = clicked() and "Clicked" or "Benchmark",
          on_press = function()
            clicked:set(not clicked())
          end,
        }
      end,
    },
  },
}
