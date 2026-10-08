-- Views for the generated state stories (states.stories.lua): each chart id
-- maps to a function that takes the actor and returns window content.
local view = require('view')
return { viewport = { width = 420, height = 460 }, stopwatch = view.content }
