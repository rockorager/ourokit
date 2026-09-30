local o = require('ouro')

local Scrolling = o.stateful(function()
  local request = o.signal(nil)
  local vertical, horizontal, virtual = o.signal('Measuring…'), o.signal('Measuring…'), o.signal('Measuring…')
  local token = 0
  local function move(far)
    token = token + 1
    request:set({token=token, far=far})
  end
  local function observe(signal)
    return function(m) signal:set(string.format('Offset %.0f / %.0f', m.offset, m.max_offset)) end
  end
  return function()
    local command = request()
    local function at(offset)
      return command and {token=command.token, offset=command.far and offset or 0} or nil
    end
    local rows = {key='cards', gap=8}
    local cards = {key='cards', gap=10}
    for i=1,12 do
      rows[#rows+1] = o.box {key='item-'..i, width='fill', height=48, padding=12,
        background=i%2==0 and '#DCEBFA' or '#E9F1F8', radius=4,
        o.text {key='label', text='Section '..i, foreground='#173B61'}}
      cards[#cards+1] = o.box {key='item-'..i, width=180, height=64, alignment='center',
        background=i%2==0 and '#DDEFD8' or '#EAF4E7', radius=4,
        o.text {key='label', text='Card '..i, foreground='#264D2A'}}
    end
    return o.column {key='page', gap=14,
      o.text {key='title', text='One retained offset · wheel, thumb, and code', size=22},
      o.text {key='hint', text='Native scrollbars reserve space. Callbacks observe; tokened requests move.'},
      o.row {key='controls', gap=10,
        o.button {key='jump', label='Jump to distant content', on_press=function() move(true) end},
        o.button {key='top', label='Back to start', on_press=function() move(false) end}},
      o.row {key='panels', gap=24, cross_alignment='start',
        o.column {key='ordinary', flex=1, gap=8,
          o.text {key='title', text='Ordinary viewport', size=18},
          o.text {key='metrics', text=vertical(), size=13},
          o.box {key='frame', width='fill', height=200,
            o.scroll {key='view', scrollbar=true, scroll_to=at(155), on_scroll=observe(vertical), o.column(rows)}}},
        o.column {key='virtual', flex=1, gap=8,
          o.text {key='title', text='10,000 virtual rows', size=18},
          o.text {key='metrics', text=virtual(), size=13},
          o.virtual_list {key='view', height=200, scrollbar=true, scroll_to=at(200003),
            on_scroll=observe(virtual), item_count=10000, item_height=40,
            item_key=function(i) return 'item-'..i end,
            render_item=function(i) return o.box {key='row', height=40, width='fill', padding=10,
              background=i%2==0 and '#F5E5CC' or '#FAF1E2',
              o.text {key='label', text='Record '..i, foreground='#573C19'}} end}},
      },
      o.text {key='horizontal-metrics', text='Horizontal · '..horizontal(), size=14},
      o.box {key='strip', width='fill', height=76,
        o.scroll {key='view', axis='horizontal', scrollbar=true, scroll_to=at(195), on_scroll=observe(horizontal), o.row(cards)}},
      o.text {key='note', text='Drag either thumb or click its track. Virtual rows also support Home / End and Page Up / Down.', size=13},
    }
  end
end)

local function content() return Scrolling {key='scrolls'} end
return o.storybook {title='Scroll state', stories={
  o.story {id='scroll/initial', name='Initial positions', viewport={width=720,height=550}, snapshot_scale=2,
    color_scheme='light', content=content},
  o.story {id='scroll/requested', name='Distant requests', viewport={width=720,height=550}, snapshot_scale=2,
    color_scheme='light', content=content, actions={{type='click',target='scrolls/page/controls/jump'}}},
  o.story {id='scroll/returned', name='Request then wheel then home', viewport={width=720,height=550}, snapshot_scale=2,
    color_scheme='dark', content=content, actions={{type='click',target='scrolls/page/controls/jump'},
      {type='scroll',target='scrolls/page/panels/virtual/view',delta=73},
      {type='click',target='scrolls/page/controls/top'}}},
}}
