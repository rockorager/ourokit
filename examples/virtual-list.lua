local ouro = require("ouro")

local item_count = 10000

local function person_key(index)
  return "person-" .. index
end

local function fixed_content()
  return ouro.virtual_list {
    key = "people",
    item_count = item_count,
    item_key = person_key,
    item_height = 40,
    render_item = function(index)
      return ouro.box {
        key = "row",
        padding = 10,
        ouro.label { key = "name", text = "Person " .. index },
      }
    end,
  }
end

local variable_text = {
  "A short profile.",
  "Works across several teams and keeps detailed notes about current projects.",
  "Available for design reviews, planning sessions, and longer discussions that wrap onto several lines in a narrow viewport.",
}

local function variable_content()
  -- Row state lives outside render_item because offscreen rows are unmounted.
  local expanded, revision = {}, ouro.signal(0)
  return function()
    return ouro.virtual_list {
      key = "people",
      item_count = item_count,
      item_key = person_key,
      estimated_item_height = 48,
      render_item = function(index)
        revision()
        local key = person_key(index)
        local open = expanded[key] == true
        local detail = variable_text[index % #variable_text + 1]
        local children = {
          ouro.label {
            key = "description",
            text = "Person " .. index .. ": " .. detail,
          },
          ouro.button {
            key = "expand",
            label = open and "Show less" or "Show more",
            on_press = function()
              expanded[key] = not expanded[key]
              revision:set(revision() + 1)
            end,
          },
        }
        if open then
          children[#children + 1] = ouro.label {
            key = "details",
            text = "Expanded details remain durable in keyed application state after this row scrolls out of the viewport.",
          }
        end
        return ouro.box {
          key = "row",
          padding = 8,
          ouro.column {
            key = "content",
            gap = 6,
            children = children,
          },
        }
      end,
    }
  end
end

local variable_initial = variable_content()
local variable_expanded = variable_content()
local variable_narrow = variable_content()

return ouro.storybook {
  id = "virtual-list",
  title = "Virtual lists",
  stories = {
    ouro.story {
      id = "fixed/initial",
      group = "Virtual list",
      name = "10,000 fixed rows",
      viewport = { width = 420, height = 320 },
      content = fixed_content,
    },
    ouro.story {
      id = "fixed/distant",
      group = "Virtual list",
      name = "Distant fixed rows",
      viewport = { width = 420, height = 320 },
      content = fixed_content,
      actions = { { type = "scroll", target = "people", delta = 120000 } },
    },
    ouro.story {
      id = "variable/initial",
      group = "Virtual list",
      name = "Variable wrapped rows",
      viewport = { width = 420, height = 360 },
      content = variable_initial,
    },
    ouro.story {
      id = "variable/expanded",
      group = "Virtual list",
      name = "Expanded variable row",
      viewport = { width = 420, height = 360 },
      content = variable_expanded,
      actions = { { type = "click", target = "people/person-1/row/content/expand" } },
    },
    ouro.story {
      id = "variable/narrow",
      group = "Virtual list",
      name = "Narrow variable rows",
      viewport = { width = 260, height = 360 },
      content = variable_narrow,
    },
  },
}
