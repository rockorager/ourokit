local ouro, normalize, menus = ...

-- Standard compositions reuse native editing, selection, popup, and focus
-- policy. No raw input events or platform objects are handled here.

-- Path-only 16px icons; ouro.icon tints them with the enclosing button's
-- foreground, so they follow every variant and disabled state.
local chevron_down = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">'
  .. '<path d="M4.5 6.25 8 9.75l3.5-3.5" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>'
local cross = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">'
  .. '<path d="m4.5 4.5 7 7m0-7-7 7" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round"/></svg>'
local space = ouro.tokens.foundation
ouro.spinbox = ouro.stateful(function(props)
  local draft = ouro.signal({base=props.value, text=tostring(props.value)})
  local function reset() draft:set({base=props.value, text=tostring(props.value)}) end
  local function request(candidate)
    local value = normalize(props, candidate)
    reset()
    if props.on_change and value ~= props.value then props.on_change(value) end
  end
  return function()
    normalize(props) -- Validate even when disabled or untouched.
    local editing = draft()
    local text = editing.base == props.value and editing.text or tostring(props.value)
    local enabled = props.enabled ~= false
    return ouro.row { key='control', gap=4, flex=props.flex,
      ouro.text_input { key='value', label=props.label, text=text, width=props.width or 100,
        enabled=enabled, focus_request=props.focus_request, key_bindings={Up='previous', Down='next'},
        on_change=function(value) draft:set({base=props.value, text=value}) end,
        on_command=function(command)
          if command == 'submit' then request(tonumber(text) or props.value)
          elseif command == 'cancel' then reset()
          elseif command == 'previous' then request(props.value + props.step)
          elseif command == 'next' then request(props.value - props.step) end
        end,
      },
      ouro.button { key='decrease', label='−', variant='soft', tone='neutral', width=space.spacing_6,
        padding_x=0, enabled=enabled and props.value > props.min,
        on_press=function() request(props.value - props.step) end },
      ouro.button { key='increase', label='+', variant='soft', tone='neutral', width=space.spacing_6,
        padding_x=0, enabled=enabled and props.value < props.max,
        on_press=function() request(props.value + props.step) end },
    }
  end
end)

ouro.select = ouro.stateful(function(props)
  local selected = ouro.signal(props.selected)
  local popup
  local function choose(value)
    if popup then popup:close(); popup=nil end
    if props.on_select then props.on_select(value) end
  end
  local function open(theme)
    selected:set(props.selected)
    local handle, err = menus.open({popup_width=props.width or 240,
      popup_height=math.min(320, 24 + #props.options * 36), duration=props.duration, motion=props.motion},
      theme, function()
        local options={}
        for _, item in ipairs(props.options) do
          options[#options+1]=ouro.option {key=tostring(item.value), value=item.value, label=item.label}
        end
        return ouro.scroll { key='scroll',
          ouro.listbox {key='choices', selected=selected(), children=options,
            on_select=function(value) selected:set(value) end, on_activate=choose,
            on_cancel=function() if popup then popup:close(); popup=nil end end},
        }
      end, function() popup=nil end)
    if not handle then
      if props.on_error then props.on_error(err) else error(err.message) end
    else popup=handle end
  end
  return function()
    menus.validate(props)
    assert(type(props.options)=='table' and #props.options>0, 'select requires options')
    local label
    local seen={}
    for _, item in ipairs(props.options) do
      assert(math.type(item.value)=='integer' and type(item.label)=='string' and not seen[item.value], 'invalid select option')
      seen[item.value]=true
      if item.value==props.selected then label=item.label end
    end
    assert(label, 'select selected value must exist')
    if props.enabled == false and popup then popup:close(); popup=nil end
    -- Radix Themes surface Select trigger: the field label stays semantic;
    -- the trigger shows only the value and a trailing chevron.
    return menus.trigger {key='trigger', variant='surface', tone='neutral',
      label=(props.label and props.label .. ': ' or '') .. label,
      width=props.width or (props.flex == nil and 240 or nil), enabled=props.enabled, open=open, flex=props.flex,
      focus_request=props.focus_request,
      ouro.row {key='content', gap=space.spacing_2, cross_alignment='center',
        ouro.text {key='value', text=label, flex=1, max_lines=1, overflow='ellipsis'},
        ouro.icon {key='chevron', bytes=chevron_down, width=16, height=16},
      }}
  end
end)

ouro.tabs = ouro.stateful(function(props)
  return function()
    assert(type(props.key)=='string' and type(props.label)=='string', 'tabs requires key and label')
    assert(type(props.tabs)=='table' and #props.tabs>0, 'tabs requires nonempty tabs')
    assert(math.type(props.selected)=='integer', 'tabs selected must be an integer')
    local seen, selected={}, false
    local headers, panels={}, {}
    for _, item in ipairs(props.tabs) do
      assert(math.type(item.value)=='integer' and type(item.label)=='string' and not seen[item.value], 'invalid tab')
      assert(item.content ~= nil, 'tab content is required')
      seen[item.value]=true
      if item.value==props.selected then selected=true end
      local key=tostring(item.value)
      local children={}
      if item.closable then
        assert(type(props.on_close)=='function', 'closable tabs require on_close')
        children[1]=ouro.button {key='close', label='Close', variant='ghost', tone='neutral',
          width=space.spacing_5, height=space.spacing_5, padding_x=0, radius=space.radius_1,
          on_press=function() props.on_close(item.value) end,
          ouro.icon {key='icon', bytes=cross, width=14, height=14}}
      end
      headers[#headers+1]=ouro.tab {key=key, value=item.value, label=item.label, children=children,
        drag=item.drag, drop=item.drop}
      panels[#panels+1]=ouro.box {key=key, width='fill', height='fill', hidden=item.value~=props.selected, item.content}
    end
    assert(selected, 'tabs selected value must exist')
    assert(type(props.on_select)=='function', 'tabs on_select must be a function')
    return ouro.column {key='control', flex=props.flex, gap=0, cross_alignment='stretch',
      ouro.scroll {key='strip', axis='horizontal',
        ouro.tab_bar {key='bar', label=props.label, selected=props.selected, on_select=props.on_select, children=headers, focus_request=props.focus_request}},
      ouro.separator {key='rule'},
      ouro.stack {key='panels', flex=1, children=panels},
    }
  end
end)
