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
