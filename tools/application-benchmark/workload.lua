local ouro = require("ouro")
local generation = ouro.signal(0)

-- Called at a task safe point by the native benchmark driver, before timing.
function benchmark_step(frame)
  generation:set(frame)
end

local function row(index, value, height)
  return ouro.box {
    key = "row-" .. index, width = 640, height = height, padding = 4,
    background = index % 2 == 1 and "#f1f5f9" or "#ffffff",
    ouro.text {
      key = "label", size = 14, foreground = "#111827",
      text = string.format("Row %06d | value %06d", index, value),
    },
  }
end

local function scrolling()
  local frame = generation()
  return ouro.virtual_list {
    key = "rows", item_count = 10000, item_height = 28,
    item_key = function(index) return "item-" .. index end,
    scroll_to = { offset = frame * 14, token = frame + 1 },
    render_item = function(index) return row(index, 0, 28) end,
  }
end

local function retained(profile)
  return function()
    local frame = generation()
    local height = profile == "relayout" and frame % 2 == 1 and 32 or 28
    local value = profile == "rebuild" and frame or 0
    local rows = {}
    for index = 1, 1000 do rows[index] = row(index, value, height) end
    return ouro.scroll {
      key = "rows",
      ouro.column { key = "content", gap = 0, children = rows },
    }
  end
end

-- Native-only diagnostics. Counter reads happen outside the timed build.
local root_calls, row_calls = 0, 0
function benchmark_probe()
  benchmark_root_calls = root_calls
  benchmark_row_calls = row_calls
end

local function counted_row(index, value)
  row_calls = row_calls + 1
  return row(index, value, 28)
end

local Leaf = ouro.stateful(function(props)
  return function()
    local value = props.index == 7 and generation() or 0
    return counted_row(props.index, value)
  end
end)

local function sparse(leaf)
  return function()
    root_calls = root_calls + 1
    local frame = not leaf and generation() or 0
    local rows = {}
    for index = 1, 1000 do
      rows[index] = leaf and Leaf { key = "leaf-" .. index, index = index }
        or counted_row(index, index == 7 and frame or 0)
    end
    return ouro.scroll { key = "rows",
      ouro.column { key = "content", gap = 0, children = rows } }
  end
end

local function sustained_scroll()
  root_calls = root_calls + 1
  local frame = generation()
  local phase = frame % 4800
  local step = phase <= 2400 and phase or 4800 - phase
  return ouro.virtual_list {
    key = "rows", item_count = 10000, item_height = 28,
    item_key = function(index) return "item-" .. index end,
    scroll_to = { offset = step * 112, token = frame + 1 },
    render_item = function(index) return counted_row(index, 0) end,
  }
end

local function keyed_churn()
  root_calls = root_calls + 1
  local frame = generation()
  local base, phase = math.floor(frame / 3) * 8, frame % 3
  local rows = {}
  for position = 1, 1000 do
    local index = phase == 1 and 1001 - position
      or phase == 2 and (position + 16) % 1000 + 1 or position
    rows[position] = counted_row(base + index, 0)
  end
  return ouro.scroll { key = "rows",
    ouro.column { key = "content", gap = 0, children = rows } }
end

return ouro.storybook {
  id = "frame-workload", title = "Matched frame workloads",
  stories = {
    ouro.story { id = "scroll", name = "10,000 virtualized rows",
      viewport = { width = 640, height = 720 }, content = scrolling },
    ouro.story { id = "rebuild", name = "1,000 retained rows, text updates",
      viewport = { width = 640, height = 720 }, content = retained("rebuild") },
    ouro.story { id = "relayout", name = "1,000 retained rows, height updates",
      viewport = { width = 640, height = 720 }, content = retained("relayout") },
    ouro.story { id = "sparse-parent", name = "One changed label, parent invalidation",
      viewport = { width = 640, height = 720 }, content = sparse(false) },
    ouro.story { id = "sparse-leaf", name = "One changed label, isolated component",
      viewport = { width = 640, height = 720 }, content = sparse(true) },
    ouro.story { id = "sustained-scroll", name = "Repeated virtual-list traversal",
      viewport = { width = 640, height = 720 }, content = sustained_scroll },
    ouro.story { id = "keyed-churn", name = "Reorder, rotate, replace eight rows",
      viewport = { width = 640, height = 720 }, content = keyed_churn },
  },
}
