local count = ouro.signal(0)

local function button_story(label, enabled)
  ouro.column {
    key = "content",
    gap = 12,
    children = function()
      ouro.label { key = "heading", text = label, size = 18 }
      ouro.button { key = "button", label = "Continue", enabled = enabled }
    end,
  }
end

return ouro.storybook {
  title = "Ourokit built-in widgets",
  stories = {
    ouro.story {
      id = "label/default",
      group = "Label",
      name = "Default",
      viewport = { width = 360, height = 160 },
      content = function()
        ouro.column {
          key = "content",
          children = function()
            ouro.label { key = "label", text = "A default Ourokit label" }
          end,
        }
      end,
    },
    ouro.story {
      id = "label/sizes",
      group = "Label",
      name = "Sizes",
      viewport = { width = 360, height = 180 },
      content = function()
        ouro.column {
          key = "content",
          gap = 8,
          children = function()
            ouro.label { key = "small", text = "Small label", size = 12 }
            ouro.label { key = "body", text = "Body label", size = 14 }
            ouro.label { key = "heading", text = "Heading label", size = 18 }
          end,
        }
      end,
    },
    ouro.story {
      id = "label/wrapping",
      group = "Label",
      name = "Constraint-aware wrapping",
      viewport = { width = 280, height = 220 },
      content = function()
        ouro.column {
          key = "content",
          gap = 8,
          children = function()
            ouro.label { key = "heading", text = "Wrapped paragraph", size = 18 }
            ouro.label {
              key = "paragraph",
              text = "Ourokit lays this label out from the width supplied by its parent and reuses the positioned paragraph until those constraints change.",
            }
          end,
        }
      end,
    },
    ouro.story {
      id = "label/mixed-direction",
      group = "Label",
      name = "Mixed direction and fallback",
      viewport = { width = 320, height = 200 },
      content = function()
        ouro.column {
          key = "content",
          gap = 8,
          children = function()
            ouro.label { key = "heading", text = "English and العربية", size = 18 }
            ouro.label {
              key = "paragraph",
              text = "Save حفظ now, then continue متابعة the workflow.",
            }
          end,
        }
      end,
    },
    ouro.story {
      id = "label/alignment",
      group = "Label",
      name = "Paragraph alignment",
      viewport = { width = 420, height = 240 },
      content = function()
        ouro.column {
          key = "content",
          gap = 10,
          children = function()
            ouro.label { key = "start", text = "Start aligned", alignment = "start" }
            ouro.label { key = "center", text = "Center aligned", alignment = "center" }
            ouro.label { key = "end", text = "End aligned", alignment = "end" }
            ouro.label {
              key = "rtl-start",
              text = "بداية الفقرة العربية",
              alignment = "start",
            }
          end,
        }
      end,
    },
    ouro.story {
      id = "label/max-lines",
      group = "Label",
      name = "Maximum lines",
      viewport = { width = 300, height = 180 },
      content = function()
        ouro.column {
          key = "content",
          gap = 10,
          children = function()
            ouro.label {
              key = "limited",
              text = "This paragraph is deliberately long enough to wrap beyond two visible lines while the retained layout clips the remaining lines.",
              max_lines = 2,
              overflow = "ellipsis",
            }
            ouro.label {
              key = "rtl-limited",
              text = "احفظ هذا المستند ثم تابع إلى خطوة سير العمل التالية",
              max_lines = 1,
              overflow = "ellipsis",
            }
          end,
        }
      end,
    },
    ouro.story {
      id = "layout/row",
      group = "Layout",
      name = "Row",
      viewport = { width = 560, height = 180 },
      content = function()
        ouro.column {
          key = "content",
          gap = 12,
          children = function()
            ouro.label { key = "heading", text = "Horizontal row", size = 18 }
            ouro.row {
              key = "items",
              gap = 8,
              children = function()
                ouro.button { key = "first", label = "First" }
                ouro.button { key = "second", label = "Second" }
                ouro.button { key = "third", label = "Third" }
              end,
            }
          end,
        }
      end,
    },
    ouro.story {
      id = "layout/column",
      group = "Layout",
      name = "Column",
      viewport = { width = 360, height = 260 },
      content = function()
        ouro.column {
          key = "content",
          gap = 8,
          children = function()
            ouro.label { key = "heading", text = "Vertical column", size = 18 }
            ouro.button { key = "first", label = "First" }
            ouro.button { key = "second", label = "Second" }
            ouro.button { key = "third", label = "Third" }
          end,
        }
      end,
    },
    ouro.story {
      id = "button/default",
      group = "Button",
      name = "Default",
      viewport = { width = 360, height = 180 },
      content = function()
        button_story("Default button", true)
      end,
    },
    ouro.story {
      id = "button/hovered",
      group = "Button",
      name = "Hovered",
      viewport = { width = 360, height = 180 },
      actions = {
        { type = "hover", target = "content/button" },
      },
      content = function()
        button_story("Hovered button", true)
      end,
    },
    ouro.story {
      id = "button/pressed",
      group = "Button",
      name = "Pressed",
      viewport = { width = 360, height = 180 },
      actions = {
        { type = "pointer_down", target = "content/button" },
      },
      content = function()
        button_story("Pressed button", true)
      end,
    },
    ouro.story {
      id = "button/disabled",
      group = "Button",
      name = "Disabled",
      viewport = { width = 360, height = 180 },
      content = function()
        button_story("Disabled button", false)
      end,
    },
    ouro.story {
      id = "button/disabled-dark",
      group = "Button",
      name = "Disabled (dark, 2x)",
      viewport = { width = 360, height = 180, scale = 2 },
      color_scheme = "dark",
      content = function()
        button_story("Disabled dark button", false)
      end,
    },
    ouro.story {
      id = "button/after-click",
      group = "Button",
      name = "After click",
      viewport = { width = 360, height = 180 },
      actions = {
        { type = "click", target = "content/button" },
      },
      content = function()
        ouro.column {
          key = "content",
          gap = 12,
          children = function()
            ouro.label {
              key = "count",
              text = "Pressed " .. count() .. " times",
              size = 18,
            }
            ouro.button {
              key = "button",
              label = "Increment",
              on_press = function()
                count:set(count() + 1)
              end,
            }
          end,
        }
      end,
    },
  },
}
