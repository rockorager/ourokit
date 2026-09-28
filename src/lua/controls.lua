local ouro, check, kind, validate_appearance = ...
local f = ouro.tokens.foundation
local transparent = '#00000000'

local function enabled(p)
  check(p.enabled == nil or kind(p.enabled) == 'boolean', 'enabled must be boolean')
  return p.enabled ~= false
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
  local thumb
  if checkbox and p.checked then
    thumb = ouro.text {key='thumb', text='✓', size=16, weight='medium', max_lines=1,
      foreground=active and c.primary_foreground or c.disabled_foreground, semantic=false}
  else
    thumb = ouro.box {key='thumb', semantic=false, width=checkbox and 10 or h-inset*2,
      height=checkbox and 10 or h-inset*2, radius=checkbox and 1 or (theme.controls.radius and (radius > inset and radius-inset or 0) or h/2),
      background=checkbox and background or (active and c.switch_thumb or c.switch_disabled_thumb),
      border_width=checkbox and 0 or inset, border=c.switch_border}
  end
  return ouro.box {key=p.key, role=checkbox and 'checkbox' or 'switch', label=p.label,
    checked=p.checked, activate=true, enabled=active, on_change=p.on_change, flex=p.flex, x=p.x, y=p.y,
    focus_request=p.focus_request, width=(checkbox and h or h*1.75)+ring*4, height=h+ring*4,
    padding=ring, alignment='center', border_width=ring, border=transparent,
    radius=checkbox and f.radius_2 or radius+ring*2, states={focus=c.ring},
    ouro.box {key='track', semantic=false, width=checkbox and h or h*1.75, height=h,
      alignment=checkbox and 'center' or (p.checked and 'right' or 'left'),
      background=background, border=active and p.checked and c.primary or c.switch_border,
      border_width=inset, radius=checkbox and f.radius_1 or radius, thumb},
  }
end
ouro.switch = ouro.stateless(function(p, children, theme) return toggle(p, children, theme, false) end)
ouro.checkbox = ouro.stateless(function(p, children, theme) return toggle(p, children, theme, true) end)

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
  return ouro.box {key=p.key, option=p.value, label=p.label,
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
