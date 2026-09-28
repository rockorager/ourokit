local ouro = require("ouro")

local function tile(key, label, width, height)
  return ouro.box {
    key = key, width = width, height = height, padding = 10,
    background = "#DCEBFA", radius = 6, alignment = "center",
    ouro.text { key = "label", text = label, color = "#173B61", size = 14 },
  }
end

local function wrapping()
  return ouro.column {
    key = "content", gap = 18,
    ouro.text { key = "title", text = "Wrap · same keyed children, different width", size = 20 },
    ouro.text { key = "hint", text = "gap 8 · run_gap 14 · cross_alignment center" },
    ouro.row {
      key = "tiles", wrap = true, gap = 8, run_gap = 14, cross_alignment = "center",
      tile("a", "A · 132 × 48", 132, 48),
      tile("b", "B · 204 × 72", 204, 72),
      tile("c", "C · 108×40", 108, 40),
      tile("d", "D · 168 × 56", 168, 56),
      tile("e", "E · 116 × 64", 116, 64),
    },
  }
end

local function columns()
  return ouro.column {
    key = "content", gap = 18,
    ouro.text { key = "title", text = "Columns wrap to the right", size = 20 },
    ouro.text { key = "hint", text = "Bounded height 180 · each run stretches independently" },
    ouro.box {
      key = "bounds", height = 180,
      ouro.column {
        key = "tiles", wrap = true, gap = 10, run_gap = 22, cross_alignment = "stretch",
        tile("a", "A · 84 high", 124, 84),
        tile("b", "B · 64 high", 180, 64),
        tile("c", "C · 108 high", 136, 108),
        tile("d", "D · 52 high", 116, 52),
        tile("e", "E · 76 high", 150, 76),
      },
    },
  }
end

local function grid()
  local function cell(key, label, column, row, column_span, row_span, color)
    return ouro.box {
      key = key, column = column, row = row, column_span = column_span, row_span = row_span,
      width = "fill", height = "fill", padding = 12, background = color or "#DCEBFA", radius = 6,
      ouro.text { key = "text", text = label, color = "#173B61", size = 15 },
    }
  end
  return ouro.column {
    key = "content", gap = 16,
    ouro.text { key = "title", text = "Explicit grid · asymmetric spans", size = 20 },
    ouro.text { key = "hint", text = "Columns: 112, 1fr, 2fr · rows: auto, 64, 92 · gaps: 10 × 14" },
    ouro.grid {
      key = "grid", columns = {112, {fr = 1}, {fr = 2}}, rows = {"auto", 64, 92},
      column_gap = 10, row_gap = 14,
      cell("label", "Fixed\n112 px", 1, 1),
      cell("headline", "Two-column span. Text measures height after the column widths resolve, so the auto row grows at narrower widths.", 2, 1, 2),
      cell("rail", "Two-row\nspan", 1, 2, 1, 2, "#F5E5CC"),
      cell("one", "1fr", 2, 2),
      cell("two", "2fr", 3, 2),
      cell("footer", "Span includes the inner column gap", 2, 3, 2, 1, "#DDEFD8"),
    },
  }
end

local StatelessCard = ouro.stateless(function(props)
  return tile(props.key, props.label, "fill", 52)
end)
local StatefulCard = ouro.stateful(function(props)
  return function() return StatelessCard { key = "card", label = props.label } end
end)

local function components()
  return ouro.column {
    key = "content", gap = 16,
    ouro.text { key = "title", text = "Grid placement crosses composition boundaries", size = 20 },
    ouro.grid {
      key = "grid", columns = {120, {fr = 1}, {fr = 2}}, rows = {64, 64}, column_gap = 12, row_gap = 9,
      ouro.button { key = "button", column = 1, row = 1, label = "Button" },
      StatelessCard { key = "stateless", column = 2, row = 1, label = "Stateless" },
      StatefulCard { key = "stateful", column = 3, row = 1, label = "Stateful → stateless" },
      StatefulCard { key = "span", column = 1, row = 2, column_span = 3, label = "One component spanning all three tracks" },
    },
  }
end

local function overflow()
  local function sample(key, clip)
    local content = ouro.grid {
      key = "grid", columns = {150, 120}, rows = {70}, column_gap = 10,
      ouro.box { key = "first", column = 1, row = 1, width = "fill", height = "fill", background = "#DCEBFA",
        alignment = "center", ouro.text {key = "text", text = "150 px", color = "#173B61"} },
      ouro.box { key = "second", column = 2, row = 1, width = "fill", height = "fill", background = "#F5E5CC",
        alignment = "center", ouro.text {key = "text", text = "120 px", color = "#173B61"} },
    }
    return ouro.box {
      key = key, width = 210, height = 70, background = "#EFEFEF",
      clip and ouro.scroll { key = "viewport", content } or content,
    }
  end
  return ouro.column {
    key = "content", gap = 16,
    ouro.text { key = "title", text = "Fixed tracks overflow the 210 px box", size = 20 },
    ouro.text { key = "unclipped", text = "Unclipped: paint extends to 280 px; hits stop at 210 px" },
    sample("visible", false),
    ouro.text { key = "clipped", text = "Scroll viewport: paint and hits both stop at 210 px" },
    sample("clip", true),
  }
end

return ouro.storybook {
  title = "Layout mechanics",
  stories = {
    ouro.story { id = "wrap/wide", group = "Wrap", name = "Rows · wide", viewport = {width = 740, height = 320}, snapshot_scale = 2, color_scheme = "light", content = wrapping },
    ouro.story { id = "wrap/narrow", group = "Wrap", name = "Rows · narrow", viewport = {width = 380, height = 370}, snapshot_scale = 2, color_scheme = "light", content = wrapping },
    ouro.story { id = "wrap/columns", group = "Wrap", name = "Columns · stretch", viewport = {width = 600, height = 320}, snapshot_scale = 2, color_scheme = "light", content = columns },
    ouro.story { id = "grid/wide", group = "Grid", name = "Spans · wide", viewport = {width = 700, height = 390}, snapshot_scale = 2, color_scheme = "light", content = grid },
    ouro.story { id = "grid/narrow", group = "Grid", name = "Spans · narrow", viewport = {width = 420, height = 470}, snapshot_scale = 2, color_scheme = "light", content = grid },
    ouro.story { id = "grid/components", group = "Grid", name = "Component placement", viewport = {width = 660, height = 240}, snapshot_scale = 2, color_scheme = "light", content = components },
    ouro.story { id = "grid/overflow", group = "Grid", name = "Overflow and clipping", viewport = {width = 560, height = 330}, snapshot_scale = 2, color_scheme = "light", content = overflow },
  },
}
