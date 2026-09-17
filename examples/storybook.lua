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

local function system_fonts_story()
  local names = { "System sans-serif", "System serif", "System monospace" }
  local families = { "sans-serif", "serif", "monospace" }
  local children = {}
  for index = 1, 3 do
    children[#children + 1] = ouro.theme {
      key = families[index],
      typography = { family = families[index] },
      children = {
        ouro.column {
          key = "samples",
          gap = 8,
          children = {
            ouro.text { key = "family", text = names[index], size = 24 },
            ouro.text { key = "small", text = "12px: The quick brown fox. 0O 1Il {} []", size = 12 },
            ouro.text { key = "body", text = "16px: Café — Ελληνικά — Кириллица", size = 16 },
            ouro.button { key = "emphasis", label = "Medium control" },
          },
        },
      },
    }
  end
  return ouro.column { key = "content", gap = 24, children = children }
end

local function placeholder_story()
  return ouro.column {
    key = "content", gap = 12,
    ouro.box {
      key = "panel", width = "fill", padding = 16,
      surface = "card", border_width = 1, radius = 12,
      ouro.column {
        key = "fields", gap = 10,
        ouro.text { key = "heading", text = "Display hints, not input values", size = 18 },
        ouro.text_input {
          key = "focused", text = "", label = "Application query",
          placeholder = "Search applications...", autofocus = true,
        },
        ouro.text_input {
          key = "filled", text = "Terminal", label = "Filled query",
          placeholder = "This hint must not appear",
        },
        ouro.text_input {
          key = "readonly", default_text = "", read_only = true,
          label = "Read-only query", placeholder = "Read-only hint",
        },
        ouro.text_input {
          key = "disabled", text = "", enabled = false,
          label = "Disabled query", placeholder = "Disabled hint",
        },
        ouro.text_input {
          key = "narrow", text = "", width = 180,
          placeholder = "A long hint stays on one line and truncates",
        },
      },
    },
    ouro.box {
      key = "explicit", width = "fill", padding = 12, surface = "sidebar",
      background = "#24486a", border = "#80baff", border_width = 2, radius = 8,
      ouro.text { key = "caption", text = "Explicit background wins over surface", foreground = "#ffffff" },
    },
    ouro.box {
      key = "default", width = "fill", padding = 12,
      ouro.text { key = "caption", text = "Default box: transparent, square, no border" },
    },
  }
end

local vignette_activated = ouro.signal(false)
local function vignette_story()
  return ouro.box {
    key = "canvas", width = "fill", height = "fill", background = "#9eafc4",
    ouro.stack {
      key = "layers",
      ouro.image {
        key = "fade", src = "images/vignette.svg",
        width = "fill", height = "fill", fit = "fill",
      },
      ouro.box {
        key = "foreground", width = "fill", height = "fill", alignment = "center",
        ouro.column {
          key = "controls", gap = 12, cross_alignment = "center",
          ouro.text { key = "heading", text = "SVG fade behind a control", foreground = "#ffffff", size = 18 },
          ouro.button {
            key = "activate", width = 160,
            label = vignette_activated() and "Activated" or "Activate",
            on_press = function() vignette_activated:set(true) end,
          },
        },
      },
    },
  }
end

return ouro.storybook {
  title = "Ourokit built-in widgets",
  stories = {
    ouro.story {
      id = "text/bundled-fonts-light",
      group = "Text",
      name = "System fonts (light)",
      viewport = { width = 600, height = 520 },
      snapshot_scale = 2,
      color_scheme = "light",
      content = system_fonts_story,
    },
    ouro.story {
      id = "text/bundled-fonts-dark",
      group = "Text",
      name = "System fonts (dark)",
      viewport = { width = 600, height = 520 },
      snapshot_scale = 2,
      color_scheme = "dark",
      content = system_fonts_story,
    },
    ouro.story {
      id = "text/bundled-fonts-light-1x",
      group = "Text",
      name = "System fonts (light, 1x)",
      viewport = { width = 600, height = 520 },
      snapshot_scale = 1,
      color_scheme = "light",
      content = system_fonts_story,
    },
    ouro.story {
      id = "text/bundled-fonts-dark-1x",
      group = "Text",
      name = "System fonts (dark, 1x)",
      viewport = { width = 600, height = 520 },
      snapshot_scale = 1,
      color_scheme = "dark",
      content = system_fonts_story,
    },
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
      id = "text-input/placeholders-light", group = "Text input",
      name = "Placeholders and styled boxes (light)",
      viewport = { width = 460, height = 410 }, snapshot_scale = 2,
      color_scheme = "light", content = placeholder_story,
    },
    ouro.story {
      id = "text-input/single-line", group = "Text input",
      name = "Single-line overflow and caret reveal",
      viewport = { width = 420, height = 370 }, snapshot_scale = 2,
      color_scheme = "light",
      content = function()
        return ouro.box {
          key = "panel", width = "fill", padding = 16,
          ouro.column {
            key = "fields", gap = 10,
            ouro.text { key = "heading", text = "Single-line text input", size = 18 },
            ouro.text { key = "start-label", text = "Unfocused: beginning of the value" },
            ouro.text_input {
              key = "start", label = "Long value, unfocused",
              default_text = "The beginning of a long editable value stays on one line, all the way to the end.",
            },
            ouro.text { key = "end-label", text = "Focused: caret at the end stays visible" },
            ouro.text_input {
              key = "end", label = "Long value, focused", autofocus = true,
              default_text = "The beginning of a long editable value stays on one line, all the way to the end.",
            },
            ouro.text { key = "rtl-label", text = "Right-to-left value" },
            ouro.text_input {
              key = "rtl", label = "Arabic value",
              default_text = "اللغة العربية نص طويل في حقل إدخال واحد اللغة العربية نص طويل في حقل إدخال واحد",
            },
            ouro.text { key = "break-label", text = "Line breaks become spaces" },
            ouro.text_input {
              key = "breaks", label = "Normalized value",
              text = "First line\r\nSecond line\nThird line",
            },
          },
        }
      end,
    },
    ouro.story {
      id = "text-input/placeholders-dark", group = "Text input",
      name = "Placeholders and styled boxes (dark)",
      viewport = { width = 460, height = 410 }, snapshot_scale = 2,
      color_scheme = "dark", content = placeholder_story,
    },
    ouro.story {
      id = "stack/vignette-small", group = "Stack",
      name = "SVG fill behind interactive content (small)",
      viewport = { width = 360, height = 240 }, snapshot_scale = 2,
      color_scheme = "dark", content = vignette_story,
      actions = { { type = "click", target = "canvas/layers/foreground/controls/activate" } },
    },
    ouro.story {
      id = "stack/vignette-large", group = "Stack",
      name = "SVG fill behind interactive content (large)",
      viewport = { width = 640, height = 360 }, snapshot_scale = 2,
      color_scheme = "dark", content = vignette_story,
      actions = { { type = "click", target = "canvas/layers/foreground/controls/activate" } },
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
