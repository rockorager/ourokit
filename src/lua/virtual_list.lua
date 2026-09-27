-- Only visited keys and mounted descriptions are evaluated. Variable heights
-- use a sparse, persistent sum tree; a failed build cannot change old measures.
local assert, valid_key = ...

local function measure(node, low, high, index, delta)
    if not node and delta == 0 then return nil end
    if low == high then
        if delta == 0 then return nil end
        if node and node.sum == delta then return node end
        return { sum = delta }
    end
    local middle = (low + high) // 2
    local left, right = node and node.left, node and node.right
    if index <= middle then left = measure(left, low, middle, index, delta)
    else right = measure(right, middle + 1, high, index, delta) end
    if not left and not right then return nil end
    if node and left == node.left and right == node.right then return node end
    return { left = left, right = right, sum = (left and left.sum or 0) + (right and right.sum or 0) }
end

local function correction(node, low, high, stop)
    if not node or stop <= low then return 0 end
    if stop > high then return node.sum end
    local middle = (low + high) // 2
    return correction(node.left, low, middle, stop) + correction(node.right, middle + 1, high, stop)
end

local function offset(tree, count, estimate, index)
    return (index - 1) * estimate + correction(tree, 1, count, index)
end

local function locate(tree, count, estimate, position)
    local low, high = 1, count
    while low < high do
        if not tree then
            local advance = position // estimate
            if advance >= high - low then return high end
            return low + (advance | 0)
        end
        local middle = (low + high) // 2
        local extent = (middle - low + 1) * estimate + (tree.left and tree.left.sum or 0)
        if position < extent then high, tree = middle, tree.left
        else low, tree, position = middle + 1, tree.right, position - extent end
    end
    return low
end

return function(props, old, id, geometry, select_reader, key_token, row_token, reuse_keys, reuse_rows, capacity)
    local width, viewport, scroll = geometry(id)
    width, viewport, scroll = width or 0, viewport or 0, scroll or 0
    if reuse_rows and old.width == width and old.viewport == viewport and old.offset == scroll then
        local unchanged, pinned = true, nil
        for i = 1, #old.rows do
            local row = old.rows[i]
            local _, height, _, focused = geometry(id, row.key)
            if focused then pinned = row.index end
            if not props.item_height and height and row.height ~= (height > 1 and height or 1) then
                unchanged = false
            end
        end
        if unchanged and pinned == old.pinned then return old end
    end
    local count = props.item_count
    local estimate = props.item_height or props.estimated_item_height
    local keys, positions, resolved = {}, {}, {}
    -- Replace the key reader as a unit, including reverse-lookup dependencies.
    -- Reusing individual keys while evaluating others would drop subscriptions.
    select_reader(key_token)
    local function key_at(index)
        local key = keys[index]
        if key then return key end
        select_reader(key_token)
        key = props.item_key(index)
        assert(valid_key(key), "item_key must return a non-empty string")
        assert(not positions[key] or positions[key] == index, "duplicate virtual list item key")
        keys[index], positions[key] = key, index
        return key
    end
    local function resolve(key, previous)
        if resolved[key] ~= nil then return resolved[key] or nil end
        local index = previous
        if props.item_index then
            select_reader(key_token)
            index = props.item_index(key)
            assert(index == nil or (index >= 1 and index <= count and index % 1 == 0),
                "item_index must return an in-range integer or nil")
            if index then
                index = index | 0
                assert(key_at(index) == key, "item_index does not match item_key")
            end
        elseif index > count or key_at(index) ~= key then
            index = nil
        end
        resolved[key] = index or false
        return index
    end

    local measurements
    if not props.item_height and reuse_keys and old.width == width and old.estimate == estimate then
        measurements = old.measurements
    end
    local anchor, within, pinned
    if old and old.count > 0 then
        local index = locate(old.measurements, old.count, old.estimate, scroll)
        local key = old.keys[index]
        if key then
            anchor = resolve(key, index)
            within = scroll - offset(old.measurements, old.count, old.estimate, index)
        end
        for i = 1, #old.rows do
            local row = old.rows[i]
            local _, height, _, focused = geometry(id, row.key)
            local current
            if focused or (not props.item_height and height) then current = resolve(row.key, row.index) end
            if focused then pinned = current end
            if current and not props.item_height and height then
                -- Keep mounted heights provisionally across width/data changes
                -- until layout replaces them, preserving deep within-row offsets.
                measurements = measure(measurements, 1, count, current, (height > 1 and height or 1) - estimate)
            end
        end
    end
    if anchor then
        local top = offset(measurements, count, estimate, anchor)
        local height = offset(measurements, count, estimate, anchor + 1) - top
        scroll = top + (within < height and within or height - 1)
    end
    local reveal = props.ensure_visible
    local reveal_index, reveal_key, reveal_top, reveal_height
    if reveal then
        if valid_key(reveal) then reveal_index = resolve(reveal, 1)
        elseif reveal <= count then reveal_index = reveal end
        if reveal_index then
            reveal_key = key_at(reveal_index)
            reveal_top = offset(measurements, count, estimate, reveal_index)
            reveal_height = offset(measurements, count, estimate, reveal_index + 1) - reveal_top
            -- Geometry feedback corrects estimated positions after mounting.
            -- Unchanged requests do not pull back ordinary wheel/key scrolling.
            if viewport > 0 and (not old or old.props.ensure_visible ~= reveal
                or old.reveal_key ~= reveal_key or old.reveal_top ~= reveal_top
                or old.reveal_height ~= reveal_height or old.viewport ~= viewport) then
                if reveal_top < scroll or reveal_height > viewport then scroll = reveal_top
                elseif reveal_top + reveal_height > scroll + viewport then
                    scroll = reveal_top + reveal_height - viewport
                end
            end
        end
    end
    local total = count * estimate + (measurements and measurements.sum or 0)
    local limit = total > viewport and total - viewport or 0
    if scroll > limit then scroll = limit end
    if scroll < 0 then scroll = 0 end

    local first, last = 1, 0
    if count > 0 then
        local visible_height = viewport > 0 and viewport or estimate * 8
        first = locate(measurements, count, estimate, scroll) - 2
        if first < 1 then first = 1 end
        last = locate(measurements, count, estimate, scroll + visible_height) + 2
        if last > count then last = count end
    end
    select_reader(row_token)
    local rows = {}
    local function row(index)
        assert(#rows < capacity, "virtual row capacity exceeded")
        local key = key_at(index)
        local top = offset(measurements, count, estimate, index)
        select_reader(row_token)
        rows[#rows + 1] = {
            key = key, index = index, y = top,
            height = offset(measurements, count, estimate, index + 1) - top,
            description = props.render_item(index),
        }
    end
    if pinned and pinned < first then row(pinned) end
    for i = first, last do row(i) end
    if pinned and pinned > last then row(pinned) end
    return { props = props, keys = keys, positions = positions, measurements = measurements,
        estimate = estimate, count = count, width = width, viewport = viewport,
        offset = scroll, total = total, rows = rows, pinned = pinned,
        reveal_key = reveal_key, reveal_top = reveal_top, reveal_height = reveal_height }
end
