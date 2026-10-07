-- Private retained-description runtime. All records belong to this Lua VM;
-- preparing a generation never mounts native owners or changes live scopes.
local select_reader, dirty, next, assert, make_props, is_function, build_list, geometry, restart_reader, call_unmount = ...
local windows, serial, transaction = {}, 0, nil
local M = {}

-- An initializer may return a second function: it runs once, after the
-- transaction, when that committed instance leaves (unmounted, its key reused
-- by another definition, or its owner disposed). call_unmount reports errors
-- instead of propagating them: unmounting has already happened.
local function unmount(record)
    local hook = record.unmount
    if not hook then return end
    record.unmount = nil
    call_unmount(hook)
end

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
    local old = group[owner] or { mounts = {}, lists = {}, builders = {} }
    group[owner] = old -- Reserve the commit slot before native reconciliation.
    transaction = { group = group, owner = owner, old = old,
        mounts = {}, lists = {}, builders = {}, updates = {}, proposals = {}, outputs = {},
        staged_mounts = {}, staged_lists = {}, staged_builders = {}, invalidation = invalidation,
        changed_builders = {}, boundaries = {},
        native_update = native_update }
end

-- Keep proposals and reader dependencies alive while native measurement
-- refines the constraints. In particular, initializers must run only once.
function M.relower()
    local t = transaction
    t.mounts, t.lists, t.builders = {}, {}, {}
    t.outputs = {}
    t.boundaries, t.current = {}, nil
    restart_reader(-2)
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
        t.root_clean = true
    end
    t.callback, t.args = callback, args
    -- Root compositions have their own reader. Each mounted boundary owns a
    -- separate composition reader, preserved when its native subtree is kept.
    select_reader(-2)
    return t.root
end

function M.render(definition, props, children, parent, visual_parent)
    local t = transaction
    -- Length-prefix the arbitrary user key; parent tokens are mount identities.
    local identity = parent .. ":" .. visual_parent .. ":" .. #props.key .. ":" .. props.key
    assert(not t.mounts[identity], "duplicate component key")
    local old = t.staged_mounts[identity] or t.old.mounts[identity]
    if old and old.definition ~= definition then old = nil end
    -- Constructor property snapshots are private and immutable. A clean,
    -- unchanged declaration needs neither a props copy nor a staged update.
    -- Proposals must use the transactional path, not committed output/props.
    local unchanged = old and old.props == props and old.values.children == children and not t.proposals[old]
    local reader_dirty = unchanged and dirty(old.token)
    if unchanged and not reader_dirty then
        t.mounts[identity], t.staged_mounts[identity] = old, old
        t.outputs[#t.outputs + 1] = old.output
        return old.output.value, old.token, true, old
    end
    local values = {}
    for k, v in next, props do values[k] = v end
    values.children = children
    local record = old
    if not record then
        serial = serial + 1
        record = { token = serial, identity = identity, definition = definition, output = {}, values = values }
        record.proxy = make_props(record)
    end
    t.mounts[identity], t.staged_mounts[identity] = record, record
    local changed = not old or not equal(record.values.children, children)
    if old and not changed then values.children = record.values.children end
    changed = changed or not equal(record.values, values)
    -- The proxy reads staged props during rendering. Rollback restores its
    -- committed backing table before native event dispatch can resume.
    local update = t.proposals[record]
    local repeated = update ~= nil
    if not update then
        update = { record = record, previous = record.values, output = record.output, retained = true }
        t.proposals[record] = update
        t.updates[#t.updates + 1] = update
    end
    update.props = props
    record.values = values
    local retained = old and not changed and (repeated or not (reader_dirty or dirty(record.token)))
    if not retained then
        update.retained = false
        restart_reader(record.token)
        if not old then
            record.render, record.unmount = definition[1](record.proxy)
            assert(is_function(record.render), "component initializer must return a render function")
            assert(record.unmount == nil or is_function(record.unmount),
                "component initializer's second result must be an unmount function")
        end
        update.output = { value = record.render() }
    end
    -- Prepared snapshots outlive later updates to the same mounted record.
    -- Pin immutable output cells, not just the mutable retained mount table.
    t.outputs[#t.outputs + 1] = update.output
    return update.output.value, record.token, update.retained, record
end

local function subtree_clean(record)
    if dirty(record.token) or dirty(-record.token - 2) then return false end
    local boundary = record.boundary
    if not boundary then return false end
    for index = 1, #boundary.children do
        if not subtree_clean(boundary.children[index]) then return false end
    end
    return true
end

-- Boundaries own identities and dependency relationships, not another copy of
-- their descriptions. Native metadata records only context and the live root.
function M.enter(record, retained)
    local t = transaction
    local parent = t.current
    if parent then parent.children[#parent.children + 1] = record end
    t.current = { record = record, children = {}, parent = parent }
    if retained and t.root_clean and not t.native_update and subtree_clean(record) then
        return record.boundary.native
    end
end

function M.lower()
    restart_reader(-transaction.current.record.token - 2)
end

local function keep_descendants(record)
    local t = transaction
    for index = 1, #record.boundary.children do
        local child = record.boundary.children[index]
        assert(not t.mounts[child.identity], "duplicate component key")
        t.mounts[child.identity], t.staged_mounts[child.identity] = child, child
        keep_descendants(child)
    end
end

function M.retain()
    local t = transaction
    keep_descendants(t.current.record)
    t.current = t.current.parent
end

function M.leave(native)
    local t = transaction
    local current = t.current
    t.boundaries[current.record] = { native = native, children = current.children }
    t.current = current.parent
end

-- Stateless expansion output must outlive lowering too: semantic strings and
-- prepared descriptions borrow its storage until the candidate is released.
function M.compose(render, ...)
    local current = transaction.current
    select_reader(current and -current.record.token - 2 or -2)
    local value = render(...)
    local outputs = transaction.outputs
    outputs[#outputs + 1] = value
    return value
end

function M.layout(props, id, constraints, scope_clean)
    local t = transaction
    assert(not t.builders[id], "duplicate layout_builder key")
    local staged = t.staged_builders[id]
    local old = staged or t.old.builders[id]
    local token
    if old then token = old.token else serial = serial + 1; token = serial end
    local retained = old and equal(old.props, props) and equal(old.constraints, constraints)
        and (staged or (t.root_clean and scope_clean and not dirty(token)))
    local record = old
    if not retained then
        t.changed_builders[id] = true
        restart_reader(token)
        -- Keep a private copy: mutation of the argument cannot falsify the cache key.
        local argument = {}
        for k, v in next, constraints do argument[k] = v end
        record = { token = token, props = props, constraints = constraints,
            output = props.render(argument) }
    end
    t.builders[id], t.staged_builders[id] = record, record
    t.outputs[#t.outputs + 1] = record
    return record.output, not t.changed_builders[id]
end

function M.virtual(props, id, scope_clean, capacity)
    local t = transaction
    assert(not t.lists[id], "duplicate virtual list key")
    local old = t.staged_lists[id] or t.old.lists[id]
    local token, key_token
    if old then token, key_token = old.token, old.key_token
    else serial = serial + 2; token, key_token = serial - 1, serial end
    -- An executed ancestor may change plain captured data even when it returns
    -- the same declaration. Only retained scopes can preserve provider reads.
    local reuse_keys = old and old.props == props and t.root_clean and scope_clean and not dirty(key_token)
    local plan = build_list(props, old, id, geometry, select_reader, key_token, token,
        reuse_keys, reuse_keys and not dirty(token), capacity)
    if plan ~= old then plan.token, plan.key_token = token, key_token end
    t.lists[id], t.staged_lists[id] = plan, plan
    return plan, plan == old
end

function M.finish()
    local t = transaction
    for _, records in next, { t.old.mounts, t.staged_mounts } do
        for identity, record in next, records do
            if t.mounts[identity] ~= record then
                restart_reader(record.token)
                restart_reader(-record.token - 2)
            end
        end
    end
    for _, records in next, { t.old.lists, t.staged_lists } do
        for id, record in next, records do
            if not t.lists[id] then
                restart_reader(record.token)
                restart_reader(record.key_token)
            end
        end
    end
    for _, records in next, { t.old.builders, t.staged_builders } do
        for id, record in next, records do
            if not t.builders[id] then restart_reader(record.token) end
        end
    end
    t.next = { root = t.root, mounts = t.mounts, lists = t.lists, builders = t.builders, callback = t.callback,
        args = t.args, invalidation = t.invalidation }
    -- This table also pins every lowered description until prepared output
    -- or borrowed semantic strings no longer need it.
    return t
end

function M.commit()
    local t = transaction
    for record, boundary in next, t.boundaries do record.boundary = boundary end
    t.boundaries = nil
    for index = 1, #t.updates do
        local update = t.updates[index]
        update.record.output = update.output
        update.record.props = update.props
    end
    -- Committed instances that did not survive, plus new ones that were
    -- initialized and then dropped within this transaction.
    local left = {}
    for _, records in next, { t.old.mounts, t.staged_mounts } do
        for identity, record in next, records do
            if t.next.mounts[identity] ~= record then left[record] = true end
        end
    end
    t.group[t.owner] = t.next
    t.old, t.updates, t.group = nil, nil, nil
    t.proposals, t.staged_mounts, t.staged_lists, t.staged_builders = nil, nil, nil, nil
    transaction = nil
    for record in next, left do unmount(record) end
end

function M.rollback()
    if not transaction then return end
    local t = transaction
    for index = 1, #t.updates do
        local update = t.updates[index]
        update.record.values = update.previous
    end
    transaction = nil
    -- Instances first initialized by the failed build never mounted.
    for identity, record in next, t.staged_mounts do
        if t.old.mounts[identity] ~= record then unmount(record) end
    end
end

function M.dispose(registry, owner)
    local group = windows[registry]
    if group then
        local mounted = group[owner]
        group[owner] = nil
        if not next(group) then windows[registry] = nil end
        if mounted then
            for _, record in next, mounted.mounts do unmount(record) end
        end
    end
end

return M
