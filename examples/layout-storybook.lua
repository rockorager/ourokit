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

local function constraints()
  return ouro.column {key='content',gap=18,
    ouro.text {key='title',text='Constraints down · sizes up',size=22},
    ouro.text {key='hint',text='The same layout at two widths. No window-size arithmetic.'},
    ouro.box {key='toolbar',width='fill',height=56,padding=8,background='#EEF2F6',
      ouro.row {key='row',gap=10,main_alignment='space_between',cross_alignment='center',
        ouro.button {key='back',label='Back'},
        ouro.box {key='search',flex={factor=1,fit='loose'},width='fill',max_width=260,padding=10,background='#DCEBFA',radius=6,
          ouro.text {key='label',text='Search documents',max_lines=1,overflow='ellipsis'}},
        ouro.button {key='save',label='Save'},
      }},
    ouro.box {key='center',width='fill',alignment='center',
      ouro.box {key='form',width='fill',max_width=420,padding=20,background='#DDEFD8',radius=8,
        ouro.column {key='body',gap=12,
          ouro.text {key='heading',text='A capped-width form',size=18},
          ouro.text {key='explanation',text='This form fills its available width up to 420 pixels. Narrower parent constraints win, and the paragraph reflows normally.'},
          ouro.row {key='actions',main_axis_size='max',main_alignment='end',gap=8,
            ouro.button {key='cancel',label='Cancel',variant='soft'},ouro.button {key='confirm',label='Confirm'}},
        }}},
    ouro.text {key='scroll-label',text='A bounded viewport, with capped content on its unbounded axis'},
    ouro.box {key='viewport',width='fill',height=100,background='#EEF2F6',
      ouro.scroll {key='scroll',
        ouro.box {key='inner',width='fill',alignment='center',padding=10,
          ouro.box {key='capped',width='fill',max_width=360,height='fill',min_height=100,max_height=140,padding=12,background='#F5E5CC',
            ouro.text {key='text',text='A local height cap makes fill finite even inside a vertical scroll viewport. Scroll to see the rest of this card.'}}}}},
  }
end

local function distribution()
  local rows={ouro.text {key='title',text='Main-axis alignment · gap remains the minimum',size=20}}
  for _,alignment in ipairs({'start','center','end','space_between','space_around','space_evenly'}) do
    rows[#rows+1]=ouro.column {key=alignment,gap=5,
      ouro.text {key='label',text=alignment,size=13},
      ouro.box {key='track',width='fill',background='#EEF2F6',
        ouro.row {key='row',gap=8,main_axis_size='max',main_alignment=alignment,
          tile('a','A',46,40),tile('b','B',74,40),tile('c','C',58,40)}}}
  end
  return ouro.column {key='content',gap=12,children=rows}
end

local function responsive_form(key, cap)
  return ouro.box {key=key,width='fill',max_width=cap,padding=16,background='#EEF2F6',radius=8,
    ouro.layout_builder {key='layout',render=function(c)
      local wide=c.max_width>=440
      local function field(id,label,value)
        return ouro.box {key=id,width='fill',flex=wide and 1 or nil,
          ouro.column {key='field',gap=6,
            ouro.text {key='label',text=label,size=13},
            ouro.text_input {key='input',default_text=value},
          }}
      end
      local fields={key='fields',gap=12,children={field('name','Name','Ada Lovelace'),field('team','Team','Research')}}
      return ouro.column {key='content',gap=12,
        ouro.text {key='mode',text=string.format('%g px available · %s',c.max_width,wide and 'two columns' or 'stacked fields'),size=17},
        wide and ouro.row(fields) or ouro.column(fields),
        ouro.row {key='actions',main_axis_size='max',main_alignment='end',gap=8,
          ouro.button {key='save',label='Save',variant='soft'}},
      }
    end}}
end

local Responsive=ouro.stateful(function()
  local compact=ouro.signal(false)
  return function()
    return ouro.column {key='page',gap=16,
      ouro.text {key='title',text='Composition from local constraints',size=22},
      ouro.text {key='hint',text='The same form chooses its arrangement from parent bounds, not window size.'},
      ouro.button {key='toggle',label=compact() and 'Expand first form' or 'Cap first form at 320',
        on_press=function() compact:set(not compact()) end},
      responsive_form('first',compact() and 320 or 680),
      ouro.text {key='caption',text='A second instance, always capped to 320 pixels:'},
      responsive_form('second',320),
    }
  end
end)

local function responsive()
  return Responsive {key='responsive'}
end

local Baselines=ouro.stateful(function()
  local large=ouro.signal(true)
  return function()
    return ouro.column {key='page',gap=20,
      ouro.text {key='title',text='Align the text, not the boxes',size=22},
      ouro.text {key='hint',text='First-line baselines cross padding, borders, and composed controls.'},
      ouro.button {key='toggle',label=large() and 'Reduce headline size' or 'Restore headline size',
        on_press=function() large:set(not large()) end},
      ouro.box {key='mixed',width='fill',padding=16,background='#EEF2F6',radius=8,
        ouro.row {key='row',gap=18,cross_alignment='baseline',
          ouro.text {key='headline',text='Agate',size=large() and 38 or 22},
          ouro.box {key='tag',padding_x=12,padding_y=8,border_width=1,border='#B8CCD9',background='#DCEBFA',radius=6,
            ouro.text {key='text',text='small label',size=14}},
          ouro.column {key='lines',gap=5,
            ouro.text {key='first',text='First line',size=20},
            ouro.text {key='second',text='Second line stays below',size=13}},
          ouro.box {key='marker',width=10,height=54,background='#B87B36',radius=3},
        }},
      ouro.text {key='marker-hint',text='The gold marker has no text baseline, so it stays at the top.',size=13},
      ouro.box {key='form',width='fill',padding=16,background='#EEF2F6',radius=8,
        ouro.row {key='row',gap=14,cross_alignment='baseline',
          ouro.text {key='label',text='Name',size=18},
          ouro.text_input {key='input',default_text='Ada Lovelace',font_size=16,height=46,flex=1},
          ouro.button {key='save',label='Save',height=34},
        }},
      ouro.text {key='note',text='Changing the headline size repositions siblings without replacing their state.',size=13},
    }
  end
end)

local function baselines()
  return Baselines {key='baseline'}
end

local function baseline_wrap()
  local children={key='row',wrap=true,cross_alignment='baseline',gap=12,run_gap=18}
  for i,spec in ipairs({{'Quartz',30,8},{'small',13,14},{'Topaz',24,3},{'Agate',36,6},{'Opal',16,12}}) do
    children[#children+1]=ouro.box {key='tile'..i,padding_x=12,padding_y=spec[3],background='#DCEBFA',radius=6,
      ouro.text {key='text',text=spec[1],size=spec[2]}}
  end
  return ouro.column {key='page',gap=18,
    ouro.text {key='title',text='A baseline for each wrapped run',size=22},
    ouro.text {key='hint',text='Different font sizes and padding. Each run reserves its own ascent and descent.'},
    ouro.row(children),
  }
end

local function ratio_card(key, label, ratio, color, flex)
  return ouro.box {key=key,aspect_ratio=ratio,flex=flex,padding=6,background=color,radius=6,
    ouro.layout_builder {key='bounds',render=function(c)
      return ouro.box {key='center',alignment='center',
        ouro.column {key='labels',gap=3,cross_alignment='center',
          ouro.text {key='ratio',text=label,size=16},
          ouro.text {key='size',text=string.format('%.0f × %.0f',c.max_width+12,c.max_height+12),size=11},
        }}
    end}}
end

local Ratios=ouro.stateful(function()
  local square=ouro.signal(false)
  return function()
    return ouro.column {key='page',gap=18,
      ouro.text {key='title',text='Shape from constraints',size=22},
      ouro.text {key='hint',text='Equal flex widths; each card derives its own height. Ratios include padding.'},
      ouro.button {key='toggle',label=square() and 'Restore 16:9 preview' or 'Make preview square',
        on_press=function() square:set(not square()) end},
      ouro.row {key='cards',gap=12,
        ratio_card('preview',square() and '1:1' or '16:9',square() and 1 or 16/9,'#DCEBFA',1),
        ratio_card('square','1:1',1,'#DDEFD8',1),
        ratio_card('portrait','3:4',3/4,'#F5E5CC',1)},
      ouro.text {key='note',text='The same keyed cards resize with their parent. Changing a ratio changes layout, not just paint.',size=13},
    }
  end
end)

local function ratios()
  return Ratios {key='ratios'}
end

local function ratio_bounds()
  return ouro.column {key='page',gap=16,
    ouro.text {key='title',text='Parent constraints still win',size=22},
    ouro.text {key='width-label',text='Loose 160 × 130 parent · 2:1 resolves to 160 × 80'},
    ouro.box {key='width',width=160,height=130,alignment='center',background='#EEF2F6',
      ratio_card('card','2:1',2,'#DCEBFA')},
    ouro.text {key='height-label',text='Loose 210 × 64 parent · 3:2 resolves to 96 × 64'},
    ouro.box {key='height',width=210,height=64,alignment='center',background='#EEF2F6',
      ratio_card('card','3:2',1.5,'#DDEFD8')},
    ouro.text {key='tight-label',text='Tight 140 × 90 parent · overrides the requested 2:1'},
    ouro.box {key='tight',width=140,height=90,
      ratio_card('card','2:1 requested',2,'#F5E5CC')},
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
    ouro.story { id = "constraints/wide", group = "Constraints", name = "Capped form · wide", viewport = {width = 760, height = 590}, snapshot_scale = 2, color_scheme = "light", content = constraints },
    ouro.story { id = "constraints/narrow", group = "Constraints", name = "Capped form · narrow", viewport = {width = 380, height = 670}, snapshot_scale = 2, color_scheme = "light", content = constraints },
    ouro.story { id = "constraints/alignment", group = "Constraints", name = "Main-axis distribution", viewport = {width = 580, height = 510}, snapshot_scale = 2, color_scheme = "light", content = distribution },
    ouro.story { id = "builder/wide", group = "Layout builder", name = "Local widths", viewport = {width = 740, height = 650}, snapshot_scale = 2, color_scheme = "light", content = responsive },
    ouro.story { id = "builder/narrow", group = "Layout builder", name = "Narrow parent", viewport = {width = 380, height = 720}, snapshot_scale = 2, color_scheme = "light", content = responsive },
    ouro.story { id = "builder/changed", group = "Layout builder", name = "Local resize playback", viewport = {width = 740, height = 700}, snapshot_scale = 2, color_scheme = "light", content = responsive,
      actions = {{type='click',target='responsive/page/toggle'}} },
    ouro.story { id = "baseline/mixed", group = "Baseline", name = "Mixed fonts and controls", viewport = {width = 700, height = 440}, snapshot_scale = 2, color_scheme = "light", content = baselines },
    ouro.story { id = "baseline/changed", group = "Baseline", name = "Font-size playback", viewport = {width = 700, height = 440}, snapshot_scale = 2, color_scheme = "light", content = baselines,
      actions = {{type='click',target='baseline/page/toggle'}} },
    ouro.story { id = "baseline/wrap", group = "Baseline", name = "Independent run metrics", viewport = {width = 420, height = 400}, snapshot_scale = 2, color_scheme = "light", content = baseline_wrap },
    ouro.story { id = "aspect/wide", group = "Aspect ratio", name = "Flexible cards · wide", viewport = {width = 740, height = 520}, snapshot_scale = 2, color_scheme = "light", content = ratios },
    ouro.story { id = "aspect/narrow", group = "Aspect ratio", name = "Flexible cards · narrow", viewport = {width = 380, height = 440}, snapshot_scale = 2, color_scheme = "light", content = ratios },
    ouro.story { id = "aspect/changed", group = "Aspect ratio", name = "Ratio change playback", viewport = {width = 740, height = 520}, snapshot_scale = 2, color_scheme = "light", content = ratios,
      actions = {{type='click',target='ratios/page/toggle'}} },
    ouro.story { id = "aspect/bounds", group = "Aspect ratio", name = "Bounded and tight parents", viewport = {width = 580, height = 540}, snapshot_scale = 2, color_scheme = "light", content = ratio_bounds },
  },
}
