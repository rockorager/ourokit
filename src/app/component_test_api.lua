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
-- Move the virtual statechart clock (design/statecharts.md §8): due `after`
-- timers fire at their deadlines, then the UI settles if one is mounted.
function t:advance(ms)
  require('ouro').machine.advance(ms)
  local ok, err = pcall(self.settle, self)
  if not ok and not tostring(err):find('TestNotMounted', 1, true) then error(err, 0) end
end
