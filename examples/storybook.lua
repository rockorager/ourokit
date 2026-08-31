return ouro.storybook {
  title = "Ourokit controls",
  stories = {
    ouro.story {
      id = "button/default",
      group = "Button",
      name = "Default",
      viewport = { width = 320, height = 180, scale = 1 },
      content = function()
        ouro.column {
          key = "content",
          gap = 12,
          children = function()
            ouro.label { key = "heading", text = "Default button", size = 18 }
            ouro.button { key = "button", label = "Continue" }
          end,
        }
      end,
    },
    ouro.story {
      id = "button/disabled-dark",
      group = "Button",
      name = "Disabled (dark)",
      viewport = { width = 320, height = 180, scale = 2 },
      color_scheme = "dark",
      content = function()
        ouro.column {
          key = "content",
          gap = 12,
          children = function()
            ouro.label { key = "heading", text = "Disabled button", size = 18 }
            ouro.button { key = "button", label = "Continue", enabled = false }
          end,
        }
      end,
    },
  },
}
