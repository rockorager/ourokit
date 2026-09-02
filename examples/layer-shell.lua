local ouro = require("ouro")

return ouro.app {
  id = "dev.ourokit.layer-shell-example",
  run = function()
    return { windows = {
      ouro.layer_surface {
        id = "panel",
        namespace = "ourokit-example-panel",
        layer = "top",
        width = 0,
        height = 36,
        anchors = { "top", "left", "right" },
        exclusive_zone = 36,
        keyboard_interactivity = "none",
        content = function()
          ouro.label { key = "title", text = "Ourokit layer-shell panel" }
        end,
      },
    } }
  end,
}
