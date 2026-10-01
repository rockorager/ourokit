local ouro, check, kind, validate_appearance, normalize = ...
local f = ouro.tokens.foundation
local transparent = '#00000000'

local function enabled(p)
  check(p.enabled == nil or kind(p.enabled) == 'boolean', 'enabled must be boolean')
  return p.enabled ~= false
end

local function motion(p)
  check(p.motion == nil or p.motion == 'auto' or p.motion == 'reduce' or p.motion == 'full', 'invalid motion policy')
  local duration = p.duration
  if duration == nil then duration = 180 end
  check(kind(duration) == 'number' and duration >= 0 and duration < math.huge, 'duration must be finite and nonnegative')
  return duration
end

-- Recipes execute at lowering, with the same effective theme native primitives
-- see. They do not mount component state or contribute a VM-specific identity.
ouro.button = ouro.stateless(function(p, children, theme)
  -- Validate off-state overrides too, using the same scalar rules as themes.
  validate_appearance(p)
  local c, d = theme.colors, theme.widgets.button
  local variant, tone = p.variant, p.tone
  if variant == nil then variant = 'solid' end
  if tone == nil then tone = 'accent' end
  check(variant == 'solid' or variant == 'soft' or variant == 'surface' or variant == 'ghost', 'invalid button variant')
  check(tone == 'accent' or tone == 'neutral' or tone == 'destructive', 'invalid button tone')
  check(kind(p.key) == 'string' and kind(p.label) == 'string', 'button key and label required')
  check(#children <= 1, 'button accepts one content child')
  local active = enabled(p)
  local soft, hover, selected, text, border, solid, solid_hover, solid_text
  if tone == 'accent' then
    soft, hover, selected, text, border = c.accent, c.accent_hover, c.accent_selected, c.accent_text, c.accent_border
    solid, solid_hover, solid_text = c.primary, c.primary_hover, c.primary_foreground
  elseif tone == 'neutral' then
    soft, hover, selected, text, border = c.secondary, c.secondary_hover, c.secondary_selected, c.secondary_foreground, c.input
    solid, solid_hover, solid_text = c.foreground, c.muted_foreground, c.background
  else
    soft, hover, selected, text, border = c.destructive_subtle, c.destructive_subtle_hover, c.destructive_subtle_selected, c.destructive_text, c.destructive_border
    solid, solid_hover, solid_text = c.destructive, c.destructive_hover, c.destructive_foreground
  end
  local idle, over, down, disabled
  if variant == 'solid' then idle, over, down, disabled = solid, solid_hover, solid_hover, c.disabled
  elseif variant == 'soft' then idle, over, down, disabled = soft, hover, selected, c.disabled
  elseif variant == 'surface' then idle, over, down, disabled = c.surface, soft, hover, c.muted
  else idle, over, down, disabled = transparent, soft, hover, transparent end
  local function metric(name, fallback)
    if p[name] ~= nil then return p[name] end
    if d[name] ~= nil then return d[name] end
    return fallback
  end
  local function color(name, fallback)
    if p[name] ~= nil then return p[name] end
    if variant == 'solid' and tone == 'accent' and d[name] ~= nil then return d[name] end
    return fallback
  end
  local fg = active and color('foreground', variant == 'solid' and solid_text or
    (variant == 'ghost' and tone == 'neutral' and c.muted_foreground or text)) or color('disabled_foreground', c.disabled_foreground)
  local size = metric('font_size', theme.typography.size or f.typography_2)
  local height = metric('height', theme.controls.height)
  check(height == 'auto' or (kind(height) == 'number' and height > 0), 'invalid button height')
  check(p.width == nil or kind(p.width) == 'number', 'invalid button width')
  local content = children[1] or ouro.text {key=p.key, text=p.label, size=size,
    foreground=fg, weight='medium', alignment='center', max_lines=1, overflow='ellipsis', semantic=false}
  return ouro.box {key=p.key, role='button', label=p.label, activate=true, enabled=active,
    on_press=p.on_press, on_cancel=p.on_cancel, on_interaction_change=p.on_interaction_change,
    focus_request=p.focus_request, flex=p.flex, x=p.x, y=p.y, width=p.width, height=height ~= 'auto' and height or nil,
    padding_x=metric('padding_x', f.spacing_3), alignment='center',
    radius=metric('radius', theme.controls.radius or f.radius_2),
    border_width=metric('border_width', theme.controls.border_width or (variant == 'surface' and f.border_width_default or 0)),
    background=color('background', idle), border=color('border', active and (variant == 'surface' and border or c.border) or c.border),
    states={hover=color('hover', over), pressed=color('pressed', color('hover', down)),
      disabled=color('disabled', disabled), focus=color('focus', c.ring)},
    foreground=fg, content_theme={typography={size=size}},
    content,
  }
end)

local function toggle(p, children, theme, checkbox)
  check(#children == 0, 'toggle does not accept children')
  check(kind(p.key) == 'string' and #p.key > 0 and kind(p.label) == 'string' and #p.label > 0, 'toggle key and label required')
  check(kind(p.checked) == 'boolean', 'checked must be boolean')
  local active, c = enabled(p), theme.colors
  local h, inset, ring = f.spacing_5 * 5 / 6, f.border_width_default, f.border_width_strong
  local radius = theme.controls.radius or h / 2
  local background = not active and c.disabled or (p.checked and c.primary or c.switch_track)
  local duration = motion(p)
  local thumb = ouro.transition {key='motion', target=p.checked and 1 or 0,
    duration=duration, easing='ease_out', motion=p.motion,
    render=function(value)
      if checkbox then
        return ouro.box {key='thumb', semantic=false, width=h-inset*2, height=h-inset*2,
          alignment='center', opacity=value, transform={scale=0.8+0.2*value},
          ouro.text {key='mark', text='✓', size=16, weight='medium', max_lines=1,
            foreground=active and c.primary_foreground or c.disabled_foreground, semantic=false}}
      end
      return ouro.box {key='thumb', semantic=false, width=h-inset*2, height=h-inset*2,
        transform={x=h*0.75*value},
        radius=theme.controls.radius and math.max(0,radius-inset) or h/2,
        background=active and c.switch_thumb or c.switch_disabled_thumb,
        border_width=inset, border=c.switch_border}
    end}
  return ouro.box {key=p.key, role=checkbox and 'checkbox' or 'switch', label=p.label,
    checked=p.checked, activate=true, enabled=active, on_change=p.on_change, flex=p.flex, x=p.x, y=p.y,
    focus_request=p.focus_request, width=(checkbox and h or h*1.75)+ring*4, height=h+ring*4,
    padding=ring, alignment='center', border_width=ring, border=transparent,
    radius=checkbox and f.radius_2 or radius+ring*2, states={focus=c.ring},
    ouro.box {key='track', semantic=false, width=checkbox and h or h*1.75, height=h,
      alignment=checkbox and 'center' or 'left',
      background=background, border=active and p.checked and c.primary or c.switch_border,
      border_width=inset, radius=checkbox and f.radius_1 or radius, thumb},
  }
end
ouro.switch = ouro.stateless(function(p, children, theme) return toggle(p, children, theme, false) end)
ouro.checkbox = ouro.stateless(function(p, children, theme) return toggle(p, children, theme, true) end)

ouro.collapsible = ouro.stateless(function(p, children, theme)
  check(kind(p.key) == 'string' and #p.key > 0 and kind(p.label) == 'string' and #p.label > 0, 'collapsible key and label required')
  check(kind(p.expanded) == 'boolean', 'collapsible expanded must be boolean')
  check(kind(p.on_change) == 'function', 'collapsible on_change required')
  check(#children == 1, 'collapsible requires one content child')
  local active, duration, c = enabled(p), motion(p), theme.colors
  return ouro.column {key=p.key, flex=p.flex, x=p.x, y=p.y, gap=0, cross_alignment='stretch',
    ouro.box {key='trigger', role='button', label=p.label, expanded=p.expanded,
      activate=true, enabled=active, focus_request=p.focus_request,
      on_press=function() p.on_change(not p.expanded) end,
      padding_x=f.spacing_3, padding_y=f.spacing_3, border_width=f.border_width_strong,
      border=transparent, radius=f.radius_2, background=transparent,
      states={hover=c.accent, pressed=c.accent_selected, focus=c.ring},
      ouro.row {key='heading', semantic=false, cross_alignment='center', gap=f.spacing_3,
        ouro.text {key='label', semantic=false, text=p.label, flex=1, weight='medium',
          foreground=active and c.foreground or c.disabled_foreground},
        ouro.transition {key='indicator', target=p.expanded and 1 or 0,
          duration=duration, easing='ease_out', motion=p.motion, render=function(value)
            local ink = active and c.muted_foreground or c.disabled_foreground
            return ouro.stack {key='glyph', semantic=false,
              ouro.box {key='horizontal', semantic=false, width=16, height=16, alignment='center',
                ouro.box {key='stroke', semantic=false, width=10, height=2, radius=1, background=ink}},
              ouro.box {key='vertical', semantic=false, width=16, height=16, alignment='center',
                ouro.box {key='stroke', semantic=false, width=2, height=10*(1-value), radius=1, background=ink}}}
          end}}},
    ouro.presence {key='presence', present=p.expanded, duration=duration, easing='ease_out', motion=p.motion,
      render=function(value)
        return ouro.box {key='reveal', height_factor=value, clip=true, opacity=value,
          ouro.box {key='content', padding_x=f.spacing_3, padding_bottom=f.spacing_3, children[1]}}
      end},
  }
end)

-- Single-open, application-controlled disclosure group. Stable item keys own
-- transition identity; changing selection does not remount unrelated items.
ouro.accordion = ouro.stateless(function(p, children)
  check(#children == 0 and kind(p.items) == 'table' and #p.items > 0, 'accordion requires nonempty items and no children')
  check(kind(p.key) == 'string' and #p.key > 0, 'accordion key required')
  check(p.expanded == nil or kind(p.expanded) == 'string', 'accordion expanded must be an item key or nil')
  check(kind(p.on_change) == 'function', 'accordion on_change required')
  local active = enabled(p)
  motion(p)
  local rows, seen, found = {}, {}, p.expanded == nil
  for _, item in ipairs(p.items) do
    check(kind(item) == 'table' and kind(item.key) == 'string' and #item.key > 0 and not seen[item.key], 'accordion item keys must be unique nonempty strings')
    check(item.content ~= nil, 'accordion item content required')
    seen[item.key] = true
    if p.expanded == item.key then found = true end
    local item_enabled = enabled(item)
    if #rows > 0 then rows[#rows+1] = ouro.separator {key='separator-'..item.key} end
    rows[#rows+1] = ouro.collapsible {key='item-'..item.key, label=item.label,
      expanded=p.expanded == item.key, enabled=active and item_enabled,
      duration=p.duration, motion=p.motion,
      on_change=function(open) p.on_change(open and item.key or nil) end,
      item.content}
  end
  check(found, 'accordion expanded key must exist')
  return ouro.column {key=p.key, flex=p.flex, x=p.x, y=p.y, gap=0, cross_alignment='stretch', children=rows}
end)

ouro.separator = ouro.stateless(function(p, children, theme)
  check(#children == 0, 'separator does not accept children')
  local orientation = p.orientation
  if orientation == nil then orientation = 'horizontal' end
  check(orientation == 'horizontal' or orientation == 'vertical', "separator orientation must be 'horizontal' or 'vertical'")
  local horizontal = orientation == 'horizontal'
  return ouro.box {key=p.key, role='separator', flex=p.flex, x=p.x, y=p.y,
    width=horizontal and 'fill' or f.border_width_default,
    height=horizontal and f.border_width_default or 'fill',
    background=theme.colors.border,
  }
end)

ouro.dialog = ouro.stateless(function(p, children, theme)
  check(kind(p.key) == 'string' and kind(p.label) == 'string', 'dialog key and label required')
  check(#children <= 1, 'dialog accepts one content child')
  check(p.width == nil or kind(p.width) == 'number', 'invalid dialog width')
  local width = p.width
  if width == nil then width = 360 end
  return ouro.box {key=p.key, role='dialog', label=p.label, on_cancel=p.on_cancel,
    width='fill', height='fill', alignment='center', background='#0000006e',
    ouro.box {key='panel', semantic=false, width=width, padding=16,
      background=theme.colors.card, border=theme.colors.border, border_width=1,
      radius=8, children=children}}
end)

ouro.slider = ouro.stateless(function(p, children, theme)
  check(#children == 0, 'slider does not accept children')
  check(kind(p.key) == 'string' and kind(p.label) == 'string', 'slider key and label required')
  local value = normalize(p) -- Validate and convert to native floating-point range values.
  local active, width = enabled(p), p.width
  if width == nil then width = 200 end
  check(kind(width) == 'number' and width >= 32, 'slider width must be at least 32')
  local before = math.floor((value-p.min)/(p.max*1.0-p.min)*65535 + 0.5)
  return ouro.box {key=p.key, label=p.label, enabled=active,
    range={value=p.value, min=p.min, max=p.max, step=p.step, inset=14},
    on_change=p.on_change, focus_request=p.focus_request, flex=p.flex, x=p.x, y=p.y,
    width=width, height=28, padding=4, border_width=2, border=transparent,
    radius=4, alignment='center', states={focus=theme.colors.ring},
    ouro.stack {key='layers', semantic=false,
      ouro.box {key='track-frame', semantic=false, width='fill', height=16, alignment='center',
        ouro.box {key='track', semantic=false, width='fill', height=4,
          background=theme.colors.switch_track, radius=2}},
      ouro.row {key='rail', semantic=false, main_axis_size='max', gap=0,
        ouro.box {key='before', semantic=false, width=0, flex=before > 0 and before or nil},
        ouro.box {key='thumb', semantic=false, width=16, height=16, radius=8,
          background=active and theme.colors.primary or theme.colors.disabled},
        ouro.box {key='after', semantic=false, width=0, flex=before < 65535 and 65535-before or nil}}}}
end)

ouro.split_view = ouro.stateless(function(p, children, theme)
  check(#children == 2, 'split_view requires exactly two children')
  return ouro.split {key=p.key, axis=p.axis, position=p.position,
    min_first=p.min_first, min_second=p.min_second, divider_size=8,
    on_change=p.on_change, focus_request=p.focus_request, flex=p.flex, x=p.x, y=p.y,
    children[1], children[2],
    ouro.box {key='chrome', semantic=false, width='fill', height='fill', background=transparent,
      states={hover=theme.colors.accent, pressed=theme.colors.accent_selected, focus=theme.colors.ring}}}
end)

ouro.text_input = ouro.stateless(function(p, children, theme)
  check(#children == 0, 'text_input does not accept children')
  validate_appearance(p)
  local active, c, d = enabled(p), theme.colors, theme.widgets.text_input
  local function appearance(name, fallback)
    if p[name] ~= nil then return p[name] end
    if d[name] ~= nil then return d[name] end
    return fallback
  end
  local height = appearance('height', p.multiline and 160 or theme.controls.height)
  check(kind(height) == 'number' and height > 0, 'invalid text_input height')
  local alignment
  if not p.multiline then alignment = 'left' end
  return ouro.text_editor {key=p.key, text=p.text, default_text=p.default_text,
    mask=p.mask, conversation=p.conversation, prompt_id=p.prompt_id,
    label=p.label, placeholder=p.placeholder, multiline=p.multiline,
    enabled=active, read_only=p.read_only, autofocus=p.autofocus,
    key_bindings=p.key_bindings, on_change=p.on_change, on_command=p.on_command,
    focus_request=p.focus_request, flex=p.flex, x=p.x, y=p.y,
    width=p.width, height=height, alignment=alignment,
    padding_x=appearance('padding_x', f.spacing_2), padding_y=p.multiline and f.spacing_2 or 0,
    radius=appearance('radius', theme.controls.radius or f.radius_2),
    border_width=appearance('border_width', theme.controls.border_width or f.border_width_default),
    background=appearance(active and 'background' or 'disabled', c.surface),
    border=appearance('border', active and c.input or c.border), focus=appearance('focus', c.ring),
    font_size=appearance('font_size', theme.typography.size or f.typography_2),
    foreground=appearance(active and 'foreground' or 'disabled_foreground', active and c.foreground or c.disabled_foreground),
    caret_color=appearance('foreground', c.foreground), placeholder_color=c.muted_foreground, selection_color=c.selection}
end)

local function selection_group(p, children, policy)
  local gap = p.gap
  if gap == nil then gap = policy == 'tab_list' and 0 or f.spacing_1 end
  local layout = policy == 'tab_list' and ouro.row or ouro.column
  return layout {key=p.key, selection=policy, selected=p.selected, enabled=p.enabled,
    label=p.label, appearance=p.appearance, on_select=p.on_select,
    on_activate=p.on_activate, on_cancel=p.on_cancel, focus_request=p.focus_request,
    flex=p.flex, x=p.x, y=p.y, main_axis_size='max', cross_alignment='stretch',
    gap=gap, children=children}
end
ouro.listbox = ouro.stateless(function(p, children) return selection_group(p, children, 'listbox') end)
ouro.radio_group = ouro.stateless(function(p, children) return selection_group(p, children, 'radio_group') end)
ouro.tab_bar = ouro.stateless(function(p, children) return selection_group(p, children, 'tab_list') end)

local function selection_item(p, children, theme, context, tab)
  validate_appearance(p)
  local group = context.selection
  check(group ~= nil, 'option requires a direct selection group parent')
  check(tab == (group.role == 'tab_list'), 'tab requires a tab_bar parent')
  check(kind(p.key) == 'string' and kind(p.label) == 'string', 'option key and label required')
  check(p.value ~= nil, 'option value must be an integer')
  check(p.height == nil or (kind(p.height) == 'number' and p.height > 0), 'invalid option height')
  check(tab or #children == 0, 'option does not accept children')
  local c, d = theme.colors, theme.widgets.option
  local function metric(name, fallback)
    if p[name] ~= nil then return p[name] end
    if d[name] ~= nil then return d[name] end
    return fallback
  end
  local selected, sidebar = group.selected == p.value, group.appearance == 'sidebar'
  local radio = group.role == 'radio_group'
  local idle = metric('foreground', tab and c.muted_foreground or (sidebar and c.sidebar_foreground or c.foreground))
  local active = metric('foreground', tab and c.foreground or (sidebar and c.sidebar_accent_foreground or c.accent_foreground))
  if not group.enabled then idle, active = c.disabled_foreground, c.disabled_foreground end
  local label = ouro.text {key='label', text=p.label, semantic=false,
    flex=radio and 1 or nil, size=metric('font_size', theme.typography.size or f.typography_2),
    weight=selected and (tab or sidebar) and 'medium' or 'normal', max_lines=1, overflow='ellipsis',
    foreground=idle, states={hover=active, selected=active}}
  local content = label
  if tab then
    local row = {key='content', semantic=false, gap=f.spacing_1, cross_alignment='center', label}
    for i=1,#children do row[#row+1] = children[i] end
    content = ouro.column {key='frame', semantic=false, gap=0, cross_alignment='stretch',
      ouro.box {key='inset', semantic=false, flex=1, padding_x=metric('padding_x', f.spacing_3),
        alignment='left', ouro.row(row)},
      ouro.box {key='indicator', semantic=false, height=f.border_width_strong,
        background=selected and group.enabled and c.primary or nil}}
  elseif radio then
    local fg = selected and active or idle
    content = ouro.row {key='content', semantic=false, gap=8, cross_alignment='center',
      ouro.box {key='indicator', semantic=false, width=12, height=12, radius=6,
        background=selected and fg or nil, border_width=selected and 0 or 1, border=fg}, label}
  end
  return ouro.box {key=p.key, option=p.value, label=p.label, drag=p.drag, drop=p.drop,
    height=metric('height', tab and f.spacing_7 or theme.controls.height),
    padding_x=tab and 0 or metric('padding_x', f.spacing_2), alignment=not tab and 'left' or nil,
    background=metric('background'), border=metric('border', c.border),
    border_width=metric('border_width', theme.controls.border_width or 0),
    radius=metric('radius', theme.controls.radius or f.radius_1),
    states={hover=metric('hover', tab and c.secondary or (sidebar and c.sidebar_accent or c.accent)),
      selected=metric('pressed', tab and transparent or (sidebar and c.sidebar_accent_selected or c.accent_selected))},
    content}
end
ouro.option = ouro.stateless(function(p, children, theme, context) return selection_item(p, children, theme, context, false) end)
ouro.radio = ouro.stateless(function(p, children, theme, context) return selection_item(p, children, theme, context, false) end)
ouro.tab = ouro.stateless(function(p, children, theme, context) return selection_item(p, children, theme, context, true) end)
