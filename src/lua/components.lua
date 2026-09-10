-- Private retained-description runtime. All records belong to this Lua VM;
-- preparing a generation never mounts native owners or changes live scopes.
local select_reader, dirty, next, assert, make_props, is_function, build_list, geometry = ...
local windows, serial, transaction = {}, 0, nil
local M = {}

local function equal(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for k, v in next, a do if b[k] ~= v then return false end end
    for k, v in next, b do if a[k] ~= v then return false end end
    return true
end

function M.begin(registry, owner, invalidation, native_update)
    assert(not transaction, "component transaction already active")
    local group = windows[registry]
    if not group then group = {}; windows[registry] = group end
    local old = group[owner] or { mounts = {}, lists = {} }
    group[owner] = old -- Reserve the commit slot before native reconciliation.
    transaction = { group = group, owner = owner, old = old,
        mounts = {}, lists = {}, updates = {}, outputs = {}, invalidation = invalidation,
        native_update = native_update }
end

function M.root(callback, ...)
    local t = transaction
    local args = { ... }
    if t.old.callback ~= callback or t.old.invalidation ~= t.invalidation
        or not equal(t.old.args, args) or dirty(0) or (not t.native_update and not dirty()) then
        t.root = callback(...)
    else
        select_reader(-1) -- Preserve the clean root's committed dependencies.
        t.root = t.old.root
    end
    t.callback, t.args = callback, args
    return t.root
end

function M.render(definition, props, children, parent, visual_parent)
    local t = transaction
    -- Length-prefix the arbitrary user key; parent tokens are mount identities.
    local identity = parent .. ":" .. visual_parent .. ":" .. #props.key .. ":" .. props.key
    assert(not t.mounts[identity], "duplicate component key")
    local old = t.old.mounts[identity]
    if old and old.definition ~= definition then old = nil end
    local values = {}
    for k, v in next, props do values[k] = v end
    values.children = children
    local record = old
    if not record then
        serial = serial + 1
        record = { token = serial, definition = definition, output = {}, values = values }
        record.proxy = make_props(record)
    end
    t.mounts[identity] = record
    local changed = not old or not equal(record.values.children, children)
    if old and not changed then values.children = record.values.children end
    changed = changed or not equal(record.values, values)
    -- The proxy reads staged props during rendering. Rollback restores its
    -- committed backing table before native event dispatch can resume.
    local update = { record = record, previous = record.values, values = values,
        output = record.output }
    t.updates[#t.updates + 1] = update
    record.values = values
    if not old or changed or dirty(record.token) then
        select_reader(record.token)
        if not old then
            record.render = definition[1](record.proxy)
            assert(is_function(record.render), "component initializer must return a render function")
        end
        update.output = { value = record.render() }
    end
    -- Prepared snapshots outlive later updates to the same mounted record.
    -- Pin immutable output cells, not just the mutable retained mount table.
    t.outputs[#t.outputs + 1] = update.output
    return update.output.value, record.token
end

function M.virtual(props, id)
    local t = transaction
    assert(not t.lists[id], "duplicate virtual list key")
    local old = t.old.lists[id]
    local token
    if old then token = old.token else serial = serial + 1; token = serial end
    select_reader(token)
    local plan = build_list(props, old, id, geometry)
    plan.token = token
    t.lists[id] = plan
    return plan
end

function M.finish()
    local t = transaction
    for identity, record in next, t.old.mounts do
        if t.mounts[identity] ~= record then select_reader(record.token) end
    end
    for id, record in next, t.old.lists do
        if not t.lists[id] then select_reader(record.token) end
    end
    t.next = { root = t.root, mounts = t.mounts, lists = t.lists, callback = t.callback,
        args = t.args, invalidation = t.invalidation }
    -- This table also pins every lowered description until prepared output
    -- or borrowed semantic strings no longer need it.
    return t
end

function M.commit()
    local t = transaction
    for index = 1, #t.updates do
        local update = t.updates[index]
        update.record.output = update.output
    end
    t.group[t.owner] = t.next
    t.old, t.updates, t.group = nil, nil, nil
    transaction = nil
end

function M.rollback()
    if not transaction then return end
    for index = 1, #transaction.updates do
        local update = transaction.updates[index]
        update.record.values = update.previous
    end
    transaction = nil
end

function M.dispose(registry, owner)
    local group = windows[registry]
    if group then
        group[owner] = nil
        if not next(group) then windows[registry] = nil end
    end
end

return M
