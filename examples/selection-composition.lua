-- Public stock-API fixture for tests/selection_composition.py.
local o = require('ouro')
local revision = 1
local reject = false

local function window(id)
  -- Declaration order deliberately differs from numeric order.
  local values = revision == 1 and {41, -7, 103} or {-19, 83, 6}
  local keys, labels = {'first', 'middle', 'last'}, {'North', 'West', 'East'}
  local selected = {list=o.signal(values[2]), radio=o.signal(values[2]), tabs=o.signal(values[2])}
  local refresh = o.signal(0)
  local traces, closes, forbidden = {}, '', 0
  local constructors = {list=o.listbox, radio=o.radio_group, tabs=o.tab_bar}
  local function group(kind, mode)
    local name = mode..'/'..kind
    local children = {}
    for i, value in ipairs(values) do
      local props = {key=keys[i], value=value, label=labels[i]}
      -- Per-option overrides must beat the enclosing widgets.option recipe.
      if i == 3 then
        props.background, props.hover, props.pressed = '#263d61', '#5c6f21', '#963f62'
        props.height = 37
      end
      if kind == 'tabs' and i == 1 then
        props[1] = o.button {key='close', label='Close North', width=22, height=22,
          padding_x=0, variant='ghost', enabled=mode ~= 'disabled',
          on_press=function()
            closes=closes..revision..':'..value..';'
            refresh:set(refresh()+1)
          end,
          o.text {key='glyph', text='×'},
        }
      end
      children[i] = (kind == 'tabs' and o.tab or o.option)(props)
    end
    return constructors[kind] {key=kind, label=mode..' '..kind,
      selected=mode == 'live' and selected[kind]() or values[2],
      appearance=kind == 'list' and 'sidebar' or 'default', enabled=mode ~= 'disabled',
      on_select=function(value)
        if mode == 'disabled' then forbidden=forbidden+1; return end
        traces[name]=(traces[name] or '')..value..';'
        if mode == 'live' then selected[kind]:set(value) end
        -- Ignored requests deliberately cause NO signal write or rebuild.
      end, children=children}
  end
  return o.window {id=id, title='Selection composition '..id, width=980, height=680,
    content=function()
      refresh()
      local rows = {}
      for _, mode in ipairs({'live', 'ignored', 'disabled'}) do
        rows[#rows+1] = o.text {key=mode..'-title', text=mode..' — listbox / radio / tabs'}
        local columns = {}
        for _, kind in ipairs({'list', 'radio', 'tabs'}) do
          columns[#columns+1] = o.box {key=kind..'-frame', width=305, group(kind, mode)}
        end
        rows[#rows+1] = o.row {key=mode, gap=12, children=columns}
      end
      local logs = {}
      for _, kind in ipairs({'list', 'radio', 'tabs'}) do
        logs[#logs+1] = o.text {key=kind, size=12,
          text=kind..' live: '..(traces['live/'..kind] or '')..' ignored: '..(traces['ignored/'..kind] or '')}
      end
      return o.column {key='root', gap=7,
        o.text {key='revision', text='Selection revision '..revision..' / '..id},
        o.theme {key='skin', widgets={option={height=32, radius=0, border_width=0,
          background='#17324d', foreground='#f3ecd1', hover='#315b27', pressed='#763457'}},
          colors={primary='#b25a19', disabled_foreground='#94a6b8'},
          o.column {key='groups', gap=5, children=rows}},
        o.row {key='actions', gap=12,
          o.button {key='report', label='Refresh traces', on_press=function() refresh:set(refresh()+1) end},
          o.button {key='external', label='Set all to first', on_press=function()
            for _, kind in ipairs({'list', 'radio', 'tabs'}) do selected[kind]:set(values[1]) end
          end},
        },
        o.column {key='traces', gap=2, children=logs},
        o.text {key='closes', text='Closes: '..closes},
        o.text {key='forbidden', text='Forbidden: '..forbidden},
      }
    end}
end

return o.app {id='dev.ourokit.selection-composition', run=function()
  local windows = {window('main'), window(revision == 1 and 'peer' or 'added')}
  -- Reject only after staging retained and new windows with fresh handlers.
  if reject then windows[#windows+1] = o.window {
    id='rejected', title='Rejected selection candidate', width=240, height=120,
    content=function() error('selection composition candidate rejected') end,
  } end
  return {windows=windows}
end}
