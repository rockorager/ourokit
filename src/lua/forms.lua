local ouro, normalize = ...

-- Standard compositions reuse native editing, selection, popup, and focus
-- policy. No raw input events or platform objects are handled here.
ouro.spinbox = ouro.component(function(props)
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
        enabled=enabled, key_bindings={Up='previous', Down='next'},
        on_change=function(value) draft:set({base=props.value, text=value}) end,
        on_command=function(command)
          if command == 'submit' then request(tonumber(text) or props.value)
          elseif command == 'cancel' then reset()
          elseif command == 'previous' then request(props.value + props.step)
          elseif command == 'next' then request(props.value - props.step) end
        end,
      },
      ouro.button { key='decrease', label='−', enabled=enabled and props.value > props.min,
        on_press=function() request(props.value - props.step) end },
      ouro.button { key='increase', label='+', enabled=enabled and props.value < props.max,
        on_press=function() request(props.value + props.step) end },
    }
  end
end)

ouro.select = ouro.component(function(props)
  local selected = ouro.signal(props.selected)
  local popup
  local function choose(value)
    if popup then popup:close(); popup=nil end
    if props.on_select then props.on_select(value) end
  end
  local function open()
    selected:set(props.selected)
    local handle, err = ouro.popup {
      width=props.width or 240, height=math.min(320, 24 + #props.options * 36),
      on_close=function() popup=nil end,
      content=function()
        local options={}
        for _, item in ipairs(props.options) do
          options[#options+1]=ouro.option {key=tostring(item.value), value=item.value, label=item.label}
        end
        return ouro.scroll { key='scroll',
          ouro.listbox {key='choices', selected=selected(), children=options,
            on_select=function(value) selected:set(value) end, on_activate=choose,
            on_cancel=function() if popup then popup:close(); popup=nil end end},
        }
      end,
    }
    if not handle then
      if props.on_error then props.on_error(err) else error(err.message) end
    else popup=handle end
  end
  return function()
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
    return ouro.button {key='trigger', label=(props.label and props.label .. ': ' or '') .. label .. ' ▾',
      width=props.width, enabled=props.enabled, on_press=open, flex=props.flex}
  end
end)
