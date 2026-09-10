local ouro = require("ouro")

local function sample(key, name, label, tint)
  return ouro.column {
    key = key, gap = 12,
    ouro.box {
      key = "frame", surface = "card", padding = 16,
      ouro.xdg.icon {
        key = "icon", name = name, theme = "Adwaita",
        width = 48, height = 48, tint = tint, alt = label,
      },
    },
    ouro.text { key = "label", text = label },
  }
end

local function content()
  return ouro.column {
    key = "icons", gap = 20,
    ouro.text { key = "title", text = "XDG named icons", size = 26 },
    ouro.text { key = "subtitle", text = "Adwaita theme • system lookup • async image loading" },
    ouro.row {
      key = "samples", gap = 24,
      sample("color", "folder", "Original colors"),
      sample("symbolic", "folder-symbolic", "Foreground"),
      sample("tinted", "document-save-symbolic", "Explicit tint", "#3289c7"),
      sample("missing", "ourokit-example-missing-icon", "Missing (reserved)"),
    },
  }
end

-- Install Adwaita to see these icons. Themes are supplied by the host system,
-- not bundled with this example; missing icons reserve their declared size.
return ouro.storybook {
  id = "xdg-icons", title = "XDG icons",
  stories = {
    ouro.story { id = "icons/light", name = "Color and symbolic icons", viewport = { width = 640, height = 250 }, snapshot_scale = 2, content = content },
    ouro.story { id = "icons/dark", name = "Inherited dark foreground", color_scheme = "dark", viewport = { width = 640, height = 250 }, snapshot_scale = 2, content = content },
  },
}
