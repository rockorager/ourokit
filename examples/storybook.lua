local ouro = require("ouro")
local count = ouro.signal(0)

local function button_story(label, enabled)
  return ouro.column {
    key = "content",
    gap = 12,
    children = {
      ouro.text { key = "heading", text = label, size = 18 },
      ouro.button { key = "button", label = "Continue", enabled = enabled },
    },
  }
end

local function scroll_story()
  local children = {
    ouro.text { key = "heading", text = "Application settings", size = 18 },
  }
  for index = 1, 12 do
    children[#children + 1] = ouro.button {
      key = "setting-" .. index,
      label = "Setting " .. index,
    }
  end
  return ouro.scroll {
    key = "settings-scroll",
    children = {
      ouro.column {
        key = "settings",
        gap = 10,
        children = children,
      },
    },
  }
end

local function listbox_story()
  return ouro.listbox {
    key = "options",
    selected = 2,
    on_select = function() end,
    children = {
      ouro.option { key = "first", value = 1, label = "First option" },
      ouro.option { key = "second", value = 2, label = "Selected option" },
      ouro.option { key = "third", value = 3, label = "Hovered option" },
    },
  }
end

return ouro.storybook {
  title = "Ourokit built-in widgets",
  stories = {
    ouro.story {
      id = "text/default",
      group = "Text",
      name = "Default",
      viewport = { width = 360, height = 160 },
      content = function()
        return ouro.column {
          key = "content",
          children = {
            ouro.text { key = "label", text = "Default Ourokit text" },
          },
        }
      end,
    },
    ouro.story {
      id = "text/sizes",
      group = "Text",
      name = "Sizes",
      viewport = { width = 360, height = 180 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 8,
          children = {
            ouro.text { key = "small", text = "Small text", size = 12 },
            ouro.text { key = "body", text = "Body text", size = 14 },
            ouro.text { key = "heading", text = "Heading text", size = 18 },
          },
        }
      end,
    },
    ouro.story {
      id = "text/wrapping",
      group = "Text",
      name = "Constraint-aware wrapping",
      viewport = { width = 280, height = 220 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 8,
          children = {
            ouro.text { key = "heading", text = "Wrapped paragraph", size = 18 },
            ouro.text {
              key = "paragraph",
              text = "Ourokit lays this text out from the width supplied by its parent and reuses the positioned paragraph until those constraints change.",
            },
          },
        }
      end,
    },
    ouro.story {
      id = "text/mixed-direction",
      group = "Text",
      name = "Mixed direction and fallback",
      viewport = { width = 320, height = 200 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 8,
          children = {
            ouro.text { key = "heading", text = "English and العربية", size = 18 },
            ouro.text {
              key = "paragraph",
              text = "Save حفظ now, then continue متابعة the workflow.",
            },
          },
        }
      end,
    },
    ouro.story {
      id = "text/alignment",
      group = "Text",
      name = "Paragraph alignment",
      viewport = { width = 420, height = 240 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 10,
          children = {
            ouro.text { key = "start", text = "Start aligned", alignment = "start" },
            ouro.text { key = "center", text = "Center aligned", alignment = "center" },
            ouro.text { key = "end", text = "End aligned", alignment = "end" },
            ouro.text {
              key = "rtl-start",
              text = "بداية الفقرة العربية",
              alignment = "start",
            },
            ouro.text {
              key = "justified",
              text = "Justified text expands eligible spaces on every soft-wrapped line except the final line.",
              alignment = "justify",
            },
          },
        }
      end,
    },
    ouro.story {
      id = "text/max-lines",
      group = "Text",
      name = "Maximum lines",
      viewport = { width = 300, height = 180 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 10,
          children = {
            ouro.text {
              key = "limited",
              text = "This paragraph is deliberately long enough to wrap beyond two visible lines while the retained layout clips the remaining lines.",
              max_lines = 2,
              overflow = "ellipsis",
            },
            ouro.text {
              key = "rtl-limited",
              text = "احفظ هذا المستند ثم تابع إلى خطوة سير العمل التالية",
              max_lines = 1,
              overflow = "ellipsis",
            },
          },
        }
      end,
    },
    ouro.story {
      id = "layout/row",
      group = "Layout",
      name = "Row",
      viewport = { width = 560, height = 180 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 12,
          children = {
            ouro.text { key = "heading", text = "Horizontal row", size = 18 },
            ouro.row {
              key = "items",
              gap = 8,
              children = {
                ouro.button { key = "first", label = "First" },
                ouro.button { key = "second", label = "Second" },
                ouro.button { key = "third", label = "Third" },
              },
            },
          },
        }
      end,
    },
    ouro.story {
      id = "layout/column",
      group = "Layout",
      name = "Column",
      viewport = { width = 360, height = 260 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 8,
          children = {
            ouro.text { key = "heading", text = "Vertical column", size = 18 },
            ouro.button { key = "first", label = "First" },
            ouro.button { key = "second", label = "Second" },
            ouro.button { key = "third", label = "Third" },
          },
        }
      end,
    },
    ouro.story {
      id = "layout/box",
      group = "Layout",
      name = "Constrained box",
      viewport = { width = 360, height = 200 },
      content = function()
        return ouro.box {
          key = "frame",
          width = 320,
          height = 160,
          padding = 20,
          alignment = "center",
          children = {
            ouro.button { key = "centered", label = "Centered" },
          },
        }
      end,
    },
    ouro.story {
      id = "layout/scroll",
      group = "Layout",
      name = "Scrollable settings list",
      viewport = { width = 380, height = 280 },
      content = function()
        return scroll_story()
      end,
    },
    ouro.story {
      id = "layout/scroll-offset",
      group = "Layout",
      name = "Scrolled settings list",
      viewport = { width = 380, height = 280 },
      actions = {
        { type = "scroll", target = "settings-scroll", delta = 180 },
      },
      content = function()
        return scroll_story()
      end,
    },
    ouro.story {
      id = "theme/dark",
      group = "Theme",
      name = "Dark scope",
      viewport = { width = 360, height = 200 },
      content = function()
        return ouro.theme {
          key = "dark-theme",
          color_scheme = "dark",
          children = {
            ouro.box {
              key = "surface",
              width = 336,
              height = 176,
              alignment = "center",
              children = {
                ouro.button { key = "button", label = "Dark theme" },
              },
            },
          },
        }
      end,
    },
    ouro.story {
      id = "text-input/states",
      group = "Text input",
      name = "Editable, read-only, and disabled",
      viewport = { width = 420, height = 240 },
      content = function()
        return ouro.column {
          key = "content",
          gap = 10,
          children = {
            ouro.text_input {
              key = "editable",
              default_text = "Editable value",
            },
            ouro.text_input {
              key = "read-only",
              default_text = "Read-only value",
              read_only = true,
            },
            ouro.text_input {
              key = "disabled",
              default_text = "Disabled value",
              enabled = false,
            },
          },
        }
      end,
    },
    ouro.story {
      id = "listbox/states",
      group = "ListBox",
      name = "Default, selected, and hovered",
      viewport = { width = 360, height = 220 },
      actions = {
        { type = "hover", target = "options/third" },
      },
      content = function()
        return listbox_story()
      end,
    },
    ouro.story {
      id = "button/default",
      group = "Button",
      name = "Default",
      viewport = { width = 360, height = 180 },
      content = function()
        return button_story("Default button", true)
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
        return button_story("Hovered button", true)
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
        return button_story("Pressed button", true)
      end,
    },
    ouro.story {
      id = "button/disabled",
      group = "Button",
      name = "Disabled",
      viewport = { width = 360, height = 180 },
      content = function()
        return button_story("Disabled button", false)
      end,
    },
    ouro.story {
      id = "button/disabled-dark",
      group = "Button",
      name = "Disabled (dark, 2x)",
      viewport = { width = 360, height = 180 },
      snapshot_scale = 2,
      color_scheme = "dark",
      content = function()
        return button_story("Disabled dark button", false)
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
        return ouro.column {
          key = "content",
          gap = 12,
          children = {
            ouro.text {
              key = "count",
              text = "Pressed " .. count() .. " times",
              size = 18,
            },
            ouro.button {
              key = "button",
              label = "Increment",
              on_press = function()
                count:set(count() + 1)
              end,
            },
          },
        }
      end,
    },
  },
}
