local t = ...

function t:click(target) self:input { action = 'click', target = target } end
function t:hover(target) self:input { action = 'hover', target = target } end
function t:text(text) self:input { action = 'text', text = text } end
function t:scroll(target, delta)
  self:input { action = 'scroll', target = target, delta = delta }
end
function t:key(key, modifiers)
  modifiers = modifiers or {}
  self:input {
    action = 'key', key = key, shift = modifiers.shift,
    control = modifiers.control, alt = modifiers.alt, logo = modifiers.logo,
  }
end
