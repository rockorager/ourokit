-- Views for the generated state stories (states.stories.lua): each chart id
-- maps to a function that takes the actor and returns window content.
local ouro = require("ouro")
local model = require("model")
local view = require("view")(ouro, model, ouro.machine.selector(model.results))

return {
  viewport = { width = 900, height = 600 },
  launcher = function(launcher)
    return function()
      -- A flat stand-in for the desktop under the translucent layer surface.
      return ouro.box { key = "desktop", width = "fill", height = "fill", background = "#3b4b63",
        ouro.box { key = "surface", width = "fill", height = "fill", background = "#10141c99",
          view.content(launcher) } }
    end
  end,
}
