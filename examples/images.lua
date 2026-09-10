local ouro = require("ouro")

-- Original geometric SVG, deliberately shared as encoded bytes by every icon.
local arrow = [[<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="M3 10h11L9 5l3-3 10 10-10 10-3-3 5-5H3Z"/></svg>]]
local clicks = ouro.signal(0)

local function framed(key, format, fit, width, height)
  return ouro.column {
    key = key, gap = 8,
    ouro.text { key = "caption", text = format .. " / " .. fit },
    ouro.box {
      key = "frame", width = width, height = height, surface = "card",
      ouro.image {
        key = "image", src = "images/landscape." .. format,
        width = width, height = height, fit = fit,
        alt = "Mountains and a golden sun reflected in a lake",
      },
    },
  }
end

local function content()
  return ouro.column {
    key = "gallery", gap = 20,
    ouro.text { key = "title", text = "Pixels, paths, and a responsive UI", size = 26 },
    ouro.text { key = "intro", text = "Files load and decode off the UI thread. The same primitive paints on CPU and GPU." },
    ouro.row {
      key = "formats", gap = 16,
      framed("png", "png", "contain", 224, 126),
      framed("jpeg", "jpg", "contain", 224, 126),
      framed("webp", "webp", "contain", 224, 126),
    },
    ouro.row {
      key = "fitting", gap = 16,
      framed("contain", "svg", "contain", 144, 112),
      framed("cover", "png", "cover", 144, 112),
      framed("fill", "png", "fill", 144, 112),
      ouro.column {
        key = "icons", gap = 12,
        ouro.text { key = "caption", text = "SVG icons / themed + tinted" },
        ouro.row {
          key = "arrows", gap = 20,
          ouro.icon { key = "default", bytes = arrow, alt = "Forward" },
          ouro.icon { key = "orange", bytes = arrow, width = 40, height = 40, tint = "#e97e37", alt = "Forward" },
          ouro.icon { key = "blue", bytes = arrow, width = 56, height = 56, tint = "#3289c7", alt = "Forward" },
        },
      },
    },
    ouro.row {
      key = "interaction", gap = 16,
      ouro.button {
        key = "counter", label = "Still interactive: " .. clicks(),
        on_press = function() clicks:set(clicks() + 1) end,
      },
      ouro.text { key = "hint", text = "A rebuild reuses decoded assets; it does not read the files again." },
    },
  }
end

return ouro.storybook {
  id = "images", title = "Images and icons",
  stories = {
    ouro.story { id = "gallery/light", group = "Images", name = "Formats, fit, and icons", viewport = { width = 760, height = 490 }, snapshot_scale = 2, content = content },
    ouro.story { id = "gallery/dark", group = "Images", name = "Inherited icon color", color_scheme = "dark", viewport = { width = 760, height = 490 }, snapshot_scale = 2, content = content },
    ouro.story { id = "gallery/clicked", group = "Images", name = "Rebuild keeps images", viewport = { width = 760, height = 490 }, content = content,
      actions = { { type = "click", target = "gallery/interaction/counter" } } },
    ouro.story {
      id = "errors/reserved", group = "Images", name = "Missing and invalid assets keep their size", viewport = { width = 420, height = 160 },
      content = function()
        return ouro.column {
          key = "errors", gap = 10,
          ouro.text { key = "title", text = "Failed assets reserve their declared dimensions" },
          ouro.row {
            key = "slots", gap = 16,
            ouro.box { key = "missing", surface = "sidebar", ouro.image { key = "image", src = "images/missing.png", width = 100, height = 70, alt = "Missing image" } },
            ouro.box { key = "invalid", surface = "sidebar", ouro.image { key = "image", bytes = "not an image", width = 100, height = 70, alt = "Invalid image" } },
          },
        }
      end,
    },
  },
}
