local ouro = require("ouro")

return ouro.app {
  id = "dev.ourokit.benchmark.ourokit",
  run = function(context)
    local clicked = ouro.signal(false)
    return { windows = {
      ouro.window {
        id = "main",
        title = "Ourokit (" .. context.instance_id .. ")",
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
    } }
  end,
}
