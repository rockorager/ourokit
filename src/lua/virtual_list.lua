-- Indexed metadata is retained; row descriptions exist only for the viewport.
-- This function runs at the build safe point and never mutates the old plan.
local assert, valid_key = ...

local function locate(prefix, count, offset)
    local low, high = 1, count
    while low < high do
        local middle = (low + high) // 2
        if prefix[middle + 1] <= offset then low = middle + 1 else high = middle end
    end
    return low
end

return function(props, old, id, geometry)
    local width, viewport, scroll = geometry(id)
    width, viewport, scroll = width or 0, viewport or 0, scroll or 0
    local count = props.item_count
    local estimate = props.item_height or props.estimated_item_height
    local changed = not old or old.props ~= props or old.width ~= width
    local keys, positions, heights = {}, {}, {}
    for i = 1, count do
        local key = props.item_key(i)
        assert(valid_key(key), "item_key must return a non-empty string")
        assert(not positions[key], "duplicate virtual list item key")
        keys[i], positions[key] = key, i
        local previous = old and old.positions[key]
        heights[i] = not changed and previous and old.heights[previous] or estimate
    end

    local anchor, within, pinned
    if old and old.count > 0 then
        local index = locate(old.prefix, old.count, scroll)
        anchor, within = old.keys[index], scroll - old.prefix[index]
        for i = 1, #old.rows do
            local row = old.rows[i]
            local _, height, _, focused = geometry(id, row.key)
            if focused then pinned = positions[row.key] end
            if not props.item_height and height and positions[row.key] then
                -- Mounted measurements remain provisional across prop/width
                -- changes until layout supplies their replacement. Resetting
                -- these to estimates would truncate the within-row anchor.
                -- Empty visual rows still occupy one logical pixel.
                heights[positions[row.key]] = height > 1 and height or 1
            end
        end
    end
    local prefix = { 0 }
    for i = 1, count do prefix[i + 1] = prefix[i] + heights[i] end
    if anchor and positions[anchor] then
        local index = positions[anchor]
        local offset = within < heights[index] and within or heights[index] - 1
        scroll = prefix[index] + offset
    end
    local total = prefix[count + 1]
    local limit = total > viewport and total - viewport or 0
    if scroll > limit then scroll = limit end
    if scroll < 0 then scroll = 0 end

    local first, last = 1, 0
    if count > 0 then
        local visible_height = viewport > 0 and viewport or estimate * 8
        first = locate(prefix, count, scroll) - 2
        if first < 1 then first = 1 end
        last = locate(prefix, count, scroll + visible_height) + 2
        if last > count then last = count end
    end
    local rows = {}
    local function row(index)
        rows[#rows + 1] = {
            key = keys[index], index = index, y = prefix[index], height = heights[index],
            description = props.render_item(index),
        }
    end
    if pinned and pinned < first then row(pinned) end
    for i = first, last do row(i) end
    if pinned and pinned > last then row(pinned) end
    return { props = props, keys = keys, positions = positions, heights = heights,
        prefix = prefix, count = count, width = width, viewport = viewport,
        offset = scroll, total = total, rows = rows }
end
