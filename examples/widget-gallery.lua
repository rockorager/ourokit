local ouro = require("ouro")

return ouro.app {
  id = "dev.ourokit.benchmark.settings.ourokit",
  run = function()
    local count = ouro.signal(0)
    local query = ouro.signal("Editable text")
    return { windows = {
      ouro.window {
        id = "main",
        title = "Ourokit widget gallery",
        width = 560,
        height = 360,
        content = function()
          ouro.column {
            key = "gallery",
            gap = 12,
            children = function()
              ouro.label {
                key = "heading",
                text = "Ourokit controls",
                size = 18,
              }
              ouro.label {
                key = "count",
                text = "Pressed " .. count() .. " times",
              }
              ouro.text_input {
                key = "query",
                text = query(),
                width = 280,
                on_change = function(value)
                  query:set(value)
                end,
              }
              ouro.row {
                key = "actions",
                gap = 8,
                children = function()
                  ouro.button {
                    key = "increment",
                    label = "Increment",
                    on_press = function()
                      count:set(count() + 1)
                    end,
                  }
                  ouro.button {
                    key = "disabled",
                    label = "Disabled",
                    enabled = false,
                  }
                end,
              }
            end,
          }
        end,
      },
    } }
  end,
}
