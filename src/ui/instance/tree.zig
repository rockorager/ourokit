const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;
const Scheduler = @import("../../task/scheduler.zig").Scheduler;
const ScopeHandle = @import("../../task/scheduler.zig").ScopeHandle;
const render_object = @import("../render_object/root.zig");
const render_types = @import("../render_object/types.zig");

pub const InstanceHandle = Handle;

/// Compact typed data expected from the eventual generated Lua bridge. IDs are
/// semantic within one window. Parents must precede children, making snapshots
/// directly consumable without arbitrary table parsing or a temporary graph.
pub const Descriptor = struct {
    id: u64,
    parent: ?u64,
    object: render_types.Object,
    parent_data: render_types.ParentData = .none,
    focusable: bool = false,
};

const State = enum { free, active, retiring };

const Slot = struct {
    generation: u32 = 0,
    state: State = .free,
    id: u64 = 0,
    parent_id: ?u64 = null,
    depth: u32 = 0,
    scope: ScopeHandle = .invalid,
    render: ?render_object.NodeHandle = null,
    state_revision: u64 = 0,
    scroll_offset: f32 = 0,
    focusable: bool = false,
    traversal_order: usize = 0,
    reconcile_child: ?render_object.NodeHandle = null,
};

const IndexEntry = struct {
    key: u64 = 0,
    slot: usize = 0,
};

const IdIndex = struct {
    entries: []IndexEntry,

    fn clear(self: IdIndex) void {
        @memset(self.entries, .{});
    }

    fn put(self: IdIndex, key: u64, slot: usize) !bool {
        std.debug.assert(key != 0);
        var index = hash(key) & (self.entries.len - 1);
        for (0..self.entries.len) |_| {
            const entry = &self.entries[index];
            if (entry.key == 0) {
                entry.* = .{ .key = key, .slot = slot };
                return true;
            }
            if (entry.key == key) {
                entry.slot = slot;
                return false;
            }
            index = (index + 1) & (self.entries.len - 1);
        }
        return error.IndexCapacityExceeded;
    }

    fn get(self: IdIndex, key: u64) ?usize {
        if (key == 0) return null;
        var index = hash(key) & (self.entries.len - 1);
        for (0..self.entries.len) |_| {
            const entry = self.entries[index];
            if (entry.key == 0) return null;
            if (entry.key == key) return entry.slot;
            index = (index + 1) & (self.entries.len - 1);
        }
        return null;
    }
};

/// Keyed identity/lifecycle layer above render objects. Reconciliation is a
/// distinct safe-point phase; disposal queues scope cancellation and never
/// executes task or language callbacks.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    render_tree: *render_object.Tree,
    owner_scope: ScopeHandle,
    slots: []Slot,
    descriptor_entries: []IndexEntry,
    instance_entries: []IndexEntry,
    render_entries: []IndexEntry,

    pub fn init(
        self: *Tree,
        allocator: std.mem.Allocator,
        scheduler: *Scheduler,
        render_tree: *render_object.Tree,
        owner_scope: ScopeHandle,
        capacity: usize,
    ) !void {
        if (capacity == 0 or !(try scheduler.scopeAcceptsResources(owner_scope)))
            return error.InvalidInstanceOwner;
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        const index_capacity = try indexCapacity(capacity);
        const descriptor_entries = try allocator.alloc(IndexEntry, index_capacity);
        errdefer allocator.free(descriptor_entries);
        const instance_entries = try allocator.alloc(IndexEntry, index_capacity);
        errdefer allocator.free(instance_entries);
        const render_entries = try allocator.alloc(IndexEntry, index_capacity);
        errdefer allocator.free(render_entries);
        @memset(slots, .{});
        @memset(descriptor_entries, .{});
        @memset(instance_entries, .{});
        @memset(render_entries, .{});
        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .render_tree = render_tree,
            .owner_scope = owner_scope,
            .slots = slots,
            .descriptor_entries = descriptor_entries,
            .instance_entries = instance_entries,
            .render_entries = render_entries,
        };
    }

    pub fn deinit(self: *Tree) void {
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        self.allocator.free(self.render_entries);
        self.allocator.free(self.instance_entries);
        self.allocator.free(self.descriptor_entries);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Applies one complete normalized snapshot. Validation and capacity
    /// preflight finish before topology or lifecycle state changes.
    pub fn reconcile(self: *Tree, descriptors: []const Descriptor) !void {
        try self.validateSnapshot(descriptors);
        try self.collectRetired();
        try self.rebuildIndices();

        var create_count: usize = 0;
        var omitted_count: usize = 0;
        for (descriptors) |descriptor| {
            if (self.findAnyById(descriptor.id)) |existing| switch (existing.state) {
                .active => {
                    if (!optionalIdEqual(existing.parent_id, descriptor.parent))
                        return error.InstanceReparented;
                },
                .retiring => return error.InstanceRetiring,
                .free => unreachable,
            } else {
                create_count += 1;
                const parent_scope = if (descriptor.parent) |parent_id|
                    (self.findActiveById(parent_id) orelse continue).scope
                else
                    self.owner_scope;
                if (!(try self.scheduler.scopeAcceptsResources(parent_scope)))
                    return error.ScopeCanceled;
            }
        }
        for (self.slots) |slot| if (slot.state == .active and
            self.descriptorForId(descriptors, slot.id) == null)
        {
            omitted_count += 1;
        };
        if (create_count > self.freeCount()) return error.InstanceCapacityExceeded;
        if (create_count > self.scheduler.availableScopeCapacity())
            return error.ScopeCapacityExceeded;
        if (create_count > self.render_tree.availableCapacity() + omitted_count)
            return error.RenderObjectCapacityExceeded;

        var topology_changed = create_count != 0 or omitted_count != 0;
        if (!topology_changed) {
            for (self.slots) |*slot| if (slot.state == .active) {
                slot.reconcile_child = self.render_tree.firstChild(slot.render.?);
            };
            for (descriptors) |descriptor| {
                const parent_id = descriptor.parent orelse continue;
                const child = self.findActiveById(descriptor.id).?;
                const parent = self.findActiveById(parent_id).?;
                const expected = parent.reconcile_child orelse {
                    topology_changed = true;
                    break;
                };
                if (!same(expected, child.render.?) or
                    !std.meta.eql(try self.render_tree.parentData(child.render.?), descriptor.parent_data))
                {
                    topology_changed = true;
                    break;
                }
                parent.reconcile_child = self.render_tree.nextSibling(expected);
            }
            if (!topology_changed) for (self.slots) |slot| {
                if (slot.state == .active and slot.reconcile_child != null) {
                    topology_changed = true;
                    break;
                }
            };
        }

        if (topology_changed) {
            // Detach first so retained objects can change typed parent roles
            // and desired order without replacing their identities.
            for (self.slots) |slot| if (slot.state == .active and slot.parent_id != null)
                try self.render_tree.detachChild(slot.render.?);
        }

        for (self.slots) |*slot| {
            if (slot.state != .active or self.descriptorForId(descriptors, slot.id) != null) continue;
            try self.scheduler.queueScopeCancellation(slot.scope);
            try self.render_tree.destroy(slot.render.?);
            slot.render = null;
            slot.state = .retiring;
        }

        for (descriptors) |descriptor| {
            if (self.findActiveById(descriptor.id) != null) continue;
            const parent_slot = if (descriptor.parent) |parent_id|
                self.findActiveById(parent_id).?
            else
                null;
            const instance_scope = try self.scheduler.createScope(if (parent_slot) |parent|
                parent.scope
            else
                self.owner_scope);
            const render = self.render_tree.create(descriptor.object) catch |err| {
                self.scheduler.destroyScope(instance_scope) catch unreachable;
                return err;
            };
            const slot_index = self.freeIndex().?;
            const slot = &self.slots[slot_index];
            var generation = slot.generation +% 1;
            if (generation == 0) generation = 1;
            slot.* = .{
                .generation = generation,
                .state = .active,
                .id = descriptor.id,
                .parent_id = descriptor.parent,
                .depth = if (parent_slot) |parent| parent.depth + 1 else 0,
                .scope = instance_scope,
                .render = render,
            };
            _ = try (IdIndex{ .entries = self.instance_entries }).put(descriptor.id, slot_index);
            _ = try (IdIndex{ .entries = self.render_entries }).put(renderKey(render), slot_index);
        }

        for (descriptors, 0..) |descriptor, traversal_order| {
            const slot = self.findActiveById(descriptor.id).?;
            slot.focusable = descriptor.focusable;
            slot.traversal_order = traversal_order;
            const previous = try self.render_tree.objectAt(slot.render.?);
            try self.render_tree.update(slot.render.?, descriptor.object);
            if (descriptor.object == .scroll) {
                if (previous != .scroll) slot.scroll_offset = 0;
                slot.scroll_offset = try self.render_tree.setScrollOffset(
                    slot.render.?,
                    slot.scroll_offset,
                );
            } else {
                slot.scroll_offset = 0;
            }
            if (topology_changed) if (descriptor.parent) |parent_id| {
                const parent = self.findActiveById(parent_id).?;
                try self.render_tree.appendChild(parent.render.?, slot.render.?, descriptor.parent_data);
            };
        }
    }

    /// Retiring instances retain their scopes until the task safe point has
    /// canceled and drained all descendants/resources.
    pub fn collectRetired(self: *Tree) !void {
        var progress = true;
        while (progress) {
            progress = false;
            for (self.slots) |*slot| {
                if (slot.state != .retiring) continue;
                self.scheduler.destroyScope(slot.scope) catch |err| switch (err) {
                    error.ScopeNotEmpty => continue,
                    else => return err,
                };
                const generation = slot.generation;
                slot.* = .{ .generation = generation };
                progress = true;
            }
        }
    }

    pub fn rootRenderObject(self: *Tree) !?render_object.NodeHandle {
        var root: ?render_object.NodeHandle = null;
        for (self.slots) |slot| {
            if (slot.state != .active or slot.parent_id != null) continue;
            if (root != null) return error.MultipleInstanceRoots;
            root = slot.render.?;
        }
        return root;
    }

    pub fn handleForId(self: *Tree, id: u64) ?InstanceHandle {
        const index = (IdIndex{ .entries = self.instance_entries }).get(id) orelse return null;
        const slot = self.slots[index];
        if (slot.state != .active or slot.id != id) return null;
        return handleFor(slot, index);
    }

    pub fn instanceForRenderObject(
        self: *Tree,
        render: render_object.NodeHandle,
    ) ?InstanceHandle {
        const index = (IdIndex{ .entries = self.render_entries }).get(renderKey(render)) orelse return null;
        const slot = self.slots[index];
        if (slot.state != .active or !same(slot.render.?, render)) return null;
        return handleFor(slot, index);
    }

    pub fn renderObject(self: *Tree, handle: InstanceHandle) !render_object.NodeHandle {
        return (try self.activeSlot(handle)).render.?;
    }

    pub fn scope(self: *Tree, handle: InstanceHandle) !ScopeHandle {
        return (try self.activeSlot(handle)).scope;
    }

    pub fn semanticId(self: *Tree, handle: InstanceHandle) !u64 {
        return (try self.activeSlot(handle)).id;
    }

    pub fn parentOf(self: *Tree, handle: InstanceHandle) !?InstanceHandle {
        const parent_id = (try self.activeSlot(handle)).parent_id orelse return null;
        return self.handleForId(parent_id) orelse error.ActiveInstanceParentMissing;
    }

    pub fn stateRevision(self: *Tree, handle: InstanceHandle) !u64 {
        return (try self.activeSlot(handle)).state_revision;
    }

    pub fn isActive(self: *Tree, handle: InstanceHandle) bool {
        _ = self.activeSlot(handle) catch return false;
        return true;
    }

    pub fn isFocusable(self: *Tree, handle: InstanceHandle) bool {
        const slot = self.activeSlot(handle) catch return false;
        return slot.focusable;
    }

    pub fn nextFocusable(
        self: *Tree,
        current: ?InstanceHandle,
        reverse: bool,
    ) !?InstanceHandle {
        const current_order: usize = if (current) |handle|
            (try self.activeSlot(handle)).traversal_order
        else if (reverse)
            std.math.maxInt(usize)
        else
            0;
        var selected: ?usize = null;
        var wrapped: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.state != .active or !slot.focusable) continue;
            if (wrapped == null or orderBefore(slot.traversal_order, self.slots[wrapped.?].traversal_order, reverse))
                wrapped = index;
            const eligible = if (current == null)
                true
            else if (reverse)
                slot.traversal_order < current_order
            else
                slot.traversal_order > current_order;
            if (eligible and (selected == null or
                orderBefore(slot.traversal_order, self.slots[selected.?].traversal_order, reverse)))
                selected = index;
        }
        const index = selected orelse wrapped orelse return null;
        return handleFor(self.slots[index], index);
    }

    pub fn bumpStateRevision(self: *Tree, handle: InstanceHandle) !void {
        const slot = try self.activeSlot(handle);
        slot.state_revision +%= 1;
    }

    /// Scroll state belongs to the retained instance. Render state is updated
    /// at the input safe point and only invalidates paint.
    pub fn scrollBy(self: *Tree, handle: InstanceHandle, delta: f32) !bool {
        if (!std.math.isFinite(delta)) return error.InvalidScrollDelta;
        const slot = try self.activeSlot(handle);
        if ((try self.render_tree.objectAt(slot.render.?)) != .scroll)
            return error.InstanceIsNotScrollable;
        const previous = slot.scroll_offset;
        slot.scroll_offset = try self.render_tree.setScrollOffset(slot.render.?, previous + delta);
        if (slot.scroll_offset == previous) return false;
        slot.state_revision +%= 1;
        return true;
    }

    pub fn scrollOffset(self: *Tree, handle: InstanceHandle) !f32 {
        return (try self.activeSlot(handle)).scroll_offset;
    }

    pub fn nearestScroll(
        self: *Tree,
        start: InstanceHandle,
        axis: render_types.Axis,
    ) !?InstanceHandle {
        var current: ?InstanceHandle = start;
        while (current) |handle| {
            const slot = try self.activeSlot(handle);
            const object = try self.render_tree.objectAt(slot.render.?);
            if (object == .scroll and object.scroll.axis == axis) return handle;
            current = try self.parentOf(handle);
        }
        return null;
    }

    /// Layout may reduce a scroll extent after content changes. Synchronize
    /// clamped renderer values back into their authoritative instance slots.
    pub fn syncScrollOffsets(self: *Tree) !void {
        for (self.slots) |*slot| {
            if (slot.state != .active) continue;
            if ((try self.render_tree.objectAt(slot.render.?)) != .scroll) continue;
            slot.scroll_offset = try self.render_tree.scrollOffset(slot.render.?);
        }
    }

    pub fn activeCount(self: *const Tree) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot.state == .active) {
            count += 1;
        };
        return count;
    }

    fn activeSlot(self: *Tree, handle: InstanceHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleInstance;
        const slot = &self.slots[handle.slot];
        if (slot.state != .active or slot.generation != handle.generation)
            return error.StaleInstance;
        return slot;
    }

    fn findAnyById(self: *Tree, id: u64) ?*Slot {
        const index = (IdIndex{ .entries = self.instance_entries }).get(id) orelse return null;
        const slot = &self.slots[index];
        if (slot.state == .free or slot.id != id) return null;
        return slot;
    }

    fn findActiveById(self: *Tree, id: u64) ?*Slot {
        const slot = self.findAnyById(id) orelse return null;
        return if (slot.state == .active) slot else null;
    }

    fn freeIndex(self: *Tree) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.state == .free) return index;
        return null;
    }

    fn freeCount(self: *const Tree) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot.state == .free) {
            count += 1;
        };
        return count;
    }

    fn validateSnapshot(self: *Tree, descriptors: []const Descriptor) !void {
        if (descriptors.len > self.slots.len) return error.InstanceCapacityExceeded;
        const descriptor_index = IdIndex{ .entries = self.descriptor_entries };
        descriptor_index.clear();
        var roots: usize = 0;
        for (descriptors, 0..) |descriptor, index| {
            if (descriptor.id == 0) return error.InvalidInstanceId;
            try render_object.Tree.validate(descriptor.object);
            if (!(try descriptor_index.put(descriptor.id, index)))
                return error.DuplicateInstanceId;
            if (descriptor.parent) |parent_id| {
                const parent_index = descriptor_index.get(parent_id) orelse
                    return error.ParentMustPrecedeChild;
                if (parent_index == index) return error.ParentMustPrecedeChild;
                try render_object.Tree.validateEdge(
                    descriptors[parent_index].object,
                    descriptor.parent_data,
                );
            } else {
                roots += 1;
                if (descriptor.parent_data != .none) return error.RootHasParentData;
            }
        }
        if (descriptors.len != 0 and roots != 1) return error.InvalidRootCount;
    }

    fn rebuildIndices(self: *Tree) !void {
        const instance_index = IdIndex{ .entries = self.instance_entries };
        const render_index = IdIndex{ .entries = self.render_entries };
        instance_index.clear();
        render_index.clear();
        for (self.slots, 0..) |slot, index| {
            if (slot.state == .free) continue;
            _ = try instance_index.put(slot.id, index);
            if (slot.render) |render| _ = try render_index.put(renderKey(render), index);
        }
    }

    fn descriptorForId(
        self: *Tree,
        descriptors: []const Descriptor,
        id: u64,
    ) ?Descriptor {
        const index = (IdIndex{ .entries = self.descriptor_entries }).get(id) orelse return null;
        return descriptors[index];
    }
};

fn indexCapacity(capacity: usize) !usize {
    const target = std.math.mul(usize, capacity, 2) catch return error.CapacityOverflow;
    var result: usize = 1;
    while (result < target)
        result = std.math.mul(usize, result, 2) catch return error.CapacityOverflow;
    return result;
}

fn hash(key: u64) usize {
    var value = key +% 0x9e3779b97f4a7c15;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return @truncate(value ^ (value >> 31));
}

fn renderKey(handle: render_object.NodeHandle) u64 {
    return (@as(u64, handle.generation) << 32) | (@as(u64, handle.slot) + 1);
}

fn optionalIdEqual(a: ?u64, b: ?u64) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn handleFor(slot: Slot, index: usize) InstanceHandle {
    return .{ .slot = @intCast(index), .generation = slot.generation };
}

fn same(a: Handle, b: Handle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn orderBefore(a: usize, b: usize, reverse: bool) bool {
    return if (reverse) a > b else a < b;
}

test "typed snapshots preserve keyed state and reorder render children" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 4);
    defer renders.deinit();
    var instances: Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 4);
    defer instances.deinit();

    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 20, .height = 20 } } },
        .{ .id = 3, .parent = 1, .object = .{ .box = .{ .width = 30, .height = 30 } } },
    };
    try instances.reconcile(&initial);
    const second = instances.handleForId(2).?;
    try instances.bumpStateRevision(second);
    const initial_root = (try instances.rootRenderObject()).?;
    _ = try renders.layout(
        initial_root,
        @import("../layout/constraints.zig").Constraints.tight(.{ .width = 100, .height = 80 }),
    );
    var no_commands: [1]@import("../../scene/root.zig").Command = undefined;
    var builder = try render_object.Builder.init(&no_commands, 1);
    try renders.buildScene(initial_root, &builder);
    try instances.reconcile(&initial);
    try std.testing.expect(!(try renders.layoutDirty(initial_root)));
    try std.testing.expect(!(try renders.paintDirty(initial_root)));
    try std.testing.expectEqual(@as(usize, 1), try renders.layoutCount(initial_root));

    const reordered = [_]Descriptor{
        initial[0],
        initial[2],
        .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 25, .height = 20 } } },
    };
    try instances.reconcile(&reordered);
    try std.testing.expectEqual(second, instances.handleForId(2).?);
    try std.testing.expectEqual(@as(u64, 1), try instances.stateRevision(second));
    const root = (try instances.rootRenderObject()).?;
    try std.testing.expectEqual(
        try instances.renderObject(instances.handleForId(3).?),
        renders.firstChild(root).?,
    );

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "invalid snapshots are transactional and retirement waits for scope drain" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 2);
    defer renders.deinit();
    var instances: Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 2);
    defer instances.deinit();
    try instances.reconcile(&.{.{ .id = 1, .parent = null, .object = .{ .box = .{} } }});
    const original = instances.handleForId(1).?;
    try std.testing.expectError(error.DuplicateInstanceId, instances.reconcile(&.{
        .{ .id = 2, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 2, .object = .{ .box = .{} } },
    }));
    try std.testing.expectEqual(original, instances.handleForId(1).?);

    const child_scope = try scheduler.createScope(try instances.scope(original));
    try instances.reconcile(&.{});
    try instances.collectRetired();
    try std.testing.expectError(error.InstanceRetiring, instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .box = .{} } },
    }));
    try scheduler.applyQueuedCancellations();
    try scheduler.destroyScope(child_scope);
    try instances.collectRetired();
    try instances.reconcile(&.{.{ .id = 1, .parent = null, .object = .{ .box = .{} } }});
    try std.testing.expect(original.generation != instances.handleForId(1).?.generation);

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "scroll offset is retained by keyed instance and clamped by layout" {
    const Constraints = @import("../layout/constraints.zig").Constraints;
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 2);
    defer renders.deinit();
    var instances: Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 2);
    defer instances.deinit();
    const snapshot = [_]Descriptor{
        .{ .id = 1, .parent = null, .object = .{ .scroll = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 40, .height = 120 } } },
    };
    try instances.reconcile(&snapshot);
    const root = (try instances.rootRenderObject()).?;
    _ = try renders.layout(root, Constraints.tight(.{ .width = 40, .height = 50 }));
    const scroll = instances.handleForId(1).?;
    try std.testing.expect(try instances.scrollBy(scroll, 25));
    try std.testing.expectEqual(@as(f32, 25), try instances.scrollOffset(scroll));
    try instances.reconcile(&snapshot);
    try std.testing.expectEqual(scroll, instances.handleForId(1).?);
    try std.testing.expectEqual(@as(f32, 25), try instances.scrollOffset(scroll));
    try std.testing.expect(try instances.scrollBy(scroll, 1000));
    try std.testing.expectEqual(@as(f32, 70), try instances.scrollOffset(scroll));

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}
