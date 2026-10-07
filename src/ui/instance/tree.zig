const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;
const Scheduler = @import("../../task/scheduler.zig").Scheduler;
const ScopeHandle = @import("../../task/scheduler.zig").ScopeHandle;
const render_object = @import("../render_object/root.zig");
const render_types = @import("../render_object/types.zig");

pub const InstanceHandle = Handle;

/// Paint-only box/text colors driven by a retained interaction owner. The source
/// is a semantic ID, never a Lua reference or a position in a widget recipe.
pub const InteractionPaint = struct {
    source: u64,
    idle: ?@import("../../core/color.zig").Color = null,
    hover: ?@import("../../core/color.zig").Color = null,
    selected: ?@import("../../core/color.zig").Color = null,
    pressed: ?@import("../../core/color.zig").Color = null,
    disabled: ?@import("../../core/color.zig").Color = null,
    border: ?@import("../../core/color.zig").Color = null,
    focus: ?@import("../../core/color.zig").Color = null,
};

pub const ReconcilePlan = struct {
    revision: u64,
    preparation: u64,
    topology_changed: bool,
    creates_instances: bool,
    removes_instances: bool,
    descriptors: []const Descriptor,
};

/// Compact typed data expected from the eventual generated Lua bridge. IDs are
/// semantic within one window. Parents must precede children, making snapshots
/// directly consumable without arbitrary table parsing or a temporary graph.
pub const Descriptor = struct {
    id: u64,
    parent: ?u64,
    object: render_types.Object,
    /// Preserve this live root and all descendants. Only identity and edge
    /// placement are read; object and other presentation fields are ignored.
    retain_subtree: bool = false,
    parent_data: render_types.ParentData = .none,
    focusable: bool = false,
    /// False keeps paint/layout/state but suppresses subtree input.
    interactive: bool = true,
    /// Descendant instance to reveal after layout; null leaves scrolling alone.
    ensure_visible: ?u64 = null,
    /// A changed token applies one absolute offset after layout, then releases
    /// control back to native scrolling.
    scroll_to: ?@import("../render_object/scroll.zig").Request = null,
    /// A changed nonzero token requests focus after the build commits.
    focus_request: u64 = 0,
    interaction_paint: ?InteractionPaint = null,
    /// Horizontal distance from each outer edge to the range's endpoint.
    range_inset: f32 = 0,
    drag: @import("../input/drag.zig").Options = .{},
};

const State = enum { free, active, retiring };

const RevealGeometry = struct { id: u64, start: f32, extent: f32, viewport: f32 };

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
    scroll_to: ?@import("../render_object/scroll.zig").Request = null,
    scroll_request_pending: bool = false,
    ensure_visible: ?u64 = null,
    revealed: ?RevealGeometry = null,
    focusable: bool = false,
    focus_request: u64 = 0,
    focus_request_pending: bool = false,
    interaction_paint: ?InteractionPaint = null,
    range_inset: f32 = 0,
    drag: @import("../input/drag.zig").Options = .{},
    traversal_order: usize = 0,
    retained: bool = false,
    reconcile_child: ?render_object.NodeHandle = null,
    rebuild_children: bool = false,
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
    /// Stable slots in ascending order, including scopes still draining.
    occupied: []usize,
    occupied_count: usize = 0,
    descriptor_entries: []IndexEntry,
    instance_entries: []IndexEntry,
    render_entries: []IndexEntry,
    indices_dirty: bool = false,
    box_has_child: []bool,
    revision: u64 = 0,
    preparation: u64 = 0,

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
        const occupied = try allocator.alloc(usize, capacity);
        errdefer allocator.free(occupied);
        const index_capacity = try indexCapacity(capacity);
        const descriptor_entries = try allocator.alloc(IndexEntry, index_capacity);
        errdefer allocator.free(descriptor_entries);
        const instance_entries = try allocator.alloc(IndexEntry, index_capacity);
        errdefer allocator.free(instance_entries);
        const render_entries = try allocator.alloc(IndexEntry, index_capacity);
        errdefer allocator.free(render_entries);
        const box_has_child = try allocator.alloc(bool, capacity);
        errdefer allocator.free(box_has_child);
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
            .occupied = occupied,
            .descriptor_entries = descriptor_entries,
            .instance_entries = instance_entries,
            .render_entries = render_entries,
            .box_has_child = box_has_child,
        };
    }

    pub fn deinit(self: *Tree) void {
        std.debug.assert(self.occupied_count == 0);
        self.allocator.free(self.box_has_child);
        self.allocator.free(self.render_entries);
        self.allocator.free(self.instance_entries);
        self.allocator.free(self.descriptor_entries);
        self.allocator.free(self.occupied);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn occupiedSlots(self: *const Tree) []const usize {
        return self.occupied[0..self.occupied_count];
    }

    /// Compatibility wrapper for ordinary single-window builds. Application
    /// source reload prepares every window before applying any window plan.
    pub fn reconcile(self: *Tree, descriptors: []const Descriptor) !void {
        try self.collectRetired();
        const plan = try self.prepareReconcile(descriptors);
        try self.applyReconcile(plan);
    }

    /// Completes descriptor, topology, scope, and capacity validation without
    /// changing retained instance or render-object ownership.
    pub fn prepareReconcile(
        self: *Tree,
        descriptors: []const Descriptor,
    ) !ReconcilePlan {
        self.preparation +%= 1;
        if (self.indices_dirty) try self.rebuildIndices();
        for (self.occupiedSlots()) |index| self.slots[index].retained = false;
        errdefer for (self.occupiedSlots()) |index| {
            self.slots[index].retained = false;
        };
        for (descriptors) |descriptor| if (descriptor.retain_subtree) {
            const root = self.findActiveById(descriptor.id) orelse return error.RetainedInstanceMissing;
            if (!optionalIdEqual(root.parent_id, descriptor.parent)) return error.InstanceReparented;
            if (!std.meta.eql(try self.render_tree.parentData(root.render.?), descriptor.parent_data))
                return error.RetainedInstanceEdgeChanged;
            try self.markRetained(root.render.?);
        };
        for (descriptors) |descriptor| if (!descriptor.retain_subtree) {
            if (self.findActiveById(descriptor.id)) |slot| if (slot.retained) return error.OverlappingRetainedSubtree;
        };
        try self.validateSnapshot(descriptors);

        var create_count: usize = 0;
        var omitted_count: usize = 0;
        for (descriptors) |descriptor| {
            if (descriptor.retain_subtree) continue;
            if (self.findAnyById(descriptor.id)) |existing| switch (existing.state) {
                .active => {
                    if (!optionalIdEqual(existing.parent_id, descriptor.parent))
                        return error.InstanceReparented;
                    // Only these objects acquire cache references on update.
                    // Comparing geometry-only objects here repeats the large
                    // property comparison performed by render_tree.update.
                    switch (descriptor.object) {
                        .text, .text_input, .image => {
                            const current = try self.render_tree.objectAt(existing.render.?);
                            if (!std.meta.eql(current, descriptor.object))
                                try self.render_tree.validateRetain(descriptor.object);
                        },
                        else => {},
                    }
                },
                .retiring => return error.InstanceRetiring,
                .free => unreachable,
            } else {
                create_count += 1;
                try self.render_tree.validateRetain(descriptor.object);
                const parent_scope = if (descriptor.parent) |parent_id|
                    (self.findActiveById(parent_id) orelse continue).scope
                else
                    self.owner_scope;
                if (!(try self.scheduler.scopeAcceptsResources(parent_scope)))
                    return error.ScopeCanceled;
            }
        }
        for (self.occupiedSlots()) |index| {
            const slot = self.slots[index];
            if (slot.state == .active and !slot.retained and self.descriptorForId(descriptors, slot.id) == null)
                omitted_count += 1;
        }
        if (create_count != 0) {
            if (create_count > self.freeCount()) return error.InstanceCapacityExceeded;
            // Reserve during preparation so applyReconcile cannot fail.
            try self.scheduler.reserveScopes(create_count);
            if (create_count > self.render_tree.availableCapacity() + omitted_count)
                return error.RenderObjectCapacityExceeded;
        }

        var topology_changed = create_count != 0 or omitted_count != 0;
        if (!topology_changed) {
            for (self.occupiedSlots()) |index| {
                const slot = &self.slots[index];
                if (slot.state != .active) continue;
                slot.reconcile_child = if (slot.retained) null else self.render_tree.firstChild(slot.render.?);
            }
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
            if (!topology_changed) for (self.occupiedSlots()) |index| {
                const slot = self.slots[index];
                if (slot.state == .active and slot.reconcile_child != null) {
                    topology_changed = true;
                    break;
                }
            };
        }

        return .{
            .revision = self.revision,
            .preparation = self.preparation,
            .topology_changed = topology_changed,
            .creates_instances = create_count != 0,
            .removes_instances = omitted_count != 0,
            .descriptors = descriptors,
        };
    }

    /// Applies a previously validated plan. A retained-tree change between
    /// prepare and apply invalidates the plan rather than misapplying it.
    pub fn validateReconcilePlan(self: *const Tree, plan: ReconcilePlan) !void {
        if (plan.revision != self.revision or plan.preparation != self.preparation) return error.StaleReconcilePlan;
    }

    pub fn applyReconcile(
        self: *Tree,
        plan: ReconcilePlan,
    ) !void {
        try self.validateReconcilePlan(plan);
        const descriptors = plan.descriptors;
        const topology_changed = plan.topology_changed;

        if (topology_changed) {
            // Identify only parents whose ordered, typed edge list changed.
            // Detaching a whole affected list keeps append semantics simple
            // without invalidating unrelated branches.
            for (self.occupiedSlots()) |index| {
                const slot = &self.slots[index];
                if (slot.state != .active) continue;
                slot.reconcile_child = if (slot.retained) null else self.render_tree.firstChild(slot.render.?);
                slot.rebuild_children = false;
            }
            for (descriptors) |descriptor| {
                const parent_id = descriptor.parent orelse continue;
                const parent = self.findActiveById(parent_id) orelse continue;
                const child = self.findActiveById(descriptor.id);
                const expected = parent.reconcile_child;
                if (child == null or expected == null or !same(expected.?, child.?.render.?) or
                    !std.meta.eql(try self.render_tree.parentData(child.?.render.?), descriptor.parent_data))
                {
                    parent.rebuild_children = true;
                } else {
                    parent.reconcile_child = self.render_tree.nextSibling(expected.?);
                }
            }
            for (self.occupiedSlots()) |index| {
                const slot = &self.slots[index];
                if (slot.state == .active and slot.reconcile_child != null)
                    slot.rebuild_children = true;
            }
            for (self.occupiedSlots()) |index| {
                const slot = self.slots[index];
                if (slot.state != .active or slot.parent_id == null) continue;
                const parent = self.findActiveById(slot.parent_id.?).?;
                if (parent.rebuild_children)
                    self.render_tree.detachChild(slot.render.?) catch unreachable;
            }
        }

        if (plan.removes_instances) for (self.occupiedSlots()) |index| {
            const slot = &self.slots[index];
            if (slot.state != .active or slot.retained or self.descriptorForId(descriptors, slot.id) != null) continue;
            self.scheduler.queueScopeCancellation(slot.scope) catch unreachable;
            self.render_tree.destroy(slot.render.?) catch unreachable;
            slot.render = null;
            slot.state = .retiring;
            self.indices_dirty = true;
        };

        if (plan.creates_instances) for (descriptors) |descriptor| {
            if (self.findActiveById(descriptor.id) != null) continue;
            const parent_slot = if (descriptor.parent) |parent_id|
                self.findActiveById(parent_id).?
            else
                null;
            const instance_scope = self.scheduler.createScope(if (parent_slot) |parent|
                parent.scope
            else
                self.owner_scope) catch unreachable;
            const render = self.render_tree.create(descriptor.object) catch unreachable;
            const slot_index = self.freeIndex().?;
            var position = self.occupied_count;
            while (position > 0 and self.occupied[position - 1] > slot_index) : (position -= 1)
                self.occupied[position] = self.occupied[position - 1];
            self.occupied[position] = slot_index;
            self.occupied_count += 1;
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
                .rebuild_children = true,
            };
            _ = (IdIndex{ .entries = self.instance_entries }).put(
                descriptor.id,
                slot_index,
            ) catch unreachable;
            _ = (IdIndex{ .entries = self.render_entries }).put(
                renderKey(render),
                slot_index,
            ) catch unreachable;
        };

        var traversal_order: usize = 0;
        for (descriptors) |descriptor| {
            const slot = self.findActiveById(descriptor.id).?;
            if (descriptor.retain_subtree) {
                self.orderRetained(slot.render.?, &traversal_order);
                if (topology_changed) if (descriptor.parent) |parent_id| {
                    const parent = self.findActiveById(parent_id).?;
                    if (parent.rebuild_children)
                        self.render_tree.appendChild(parent.render.?, slot.render.?, descriptor.parent_data) catch unreachable;
                };
                continue;
            }
            try self.render_tree.setInteractive(slot.render.?, descriptor.interactive);
            slot.focusable = descriptor.focusable;
            slot.interaction_paint = descriptor.interaction_paint;
            slot.range_inset = descriptor.range_inset;
            slot.drag = descriptor.drag;
            slot.ensure_visible = descriptor.ensure_visible;
            if (descriptor.ensure_visible == null) slot.revealed = null;
            slot.scroll_request_pending = descriptor.scroll_to != null and
                (slot.scroll_request_pending or slot.scroll_to == null or descriptor.scroll_to.?.token != slot.scroll_to.?.token);
            slot.scroll_to = descriptor.scroll_to;
            slot.focus_request_pending = descriptor.focus_request != 0 and descriptor.focus_request != slot.focus_request;
            slot.focus_request = descriptor.focus_request;
            slot.traversal_order = traversal_order;
            traversal_order += 1;
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
                if (parent.rebuild_children)
                    self.render_tree.appendChild(
                        parent.render.?,
                        slot.render.?,
                        descriptor.parent_data,
                    ) catch unreachable;
            };
        }
        self.revision +%= 1;
    }

    /// Retiring instances retain their scopes until the task safe point has
    /// canceled and drained all descendants/resources.
    pub fn collectRetired(self: *Tree) !void {
        var progress = true;
        var changed = false;
        while (progress) {
            progress = false;
            var index: usize = 0;
            while (index < self.occupied_count) {
                const slot = &self.slots[self.occupied[index]];
                if (slot.state != .retiring) {
                    index += 1;
                    continue;
                }
                self.scheduler.destroyScope(slot.scope) catch |err| switch (err) {
                    error.ScopeNotEmpty => {
                        index += 1;
                        continue;
                    },
                    else => return err,
                };
                const generation = slot.generation;
                slot.* = .{ .generation = generation };
                self.indices_dirty = true;
                self.occupied_count -= 1;
                std.mem.copyForwards(usize, self.occupied[index..self.occupied_count], self.occupied[index + 1 .. self.occupied_count + 1]);
                progress = true;
                changed = true;
            }
        }
        if (changed) self.revision +%= 1;
    }

    pub fn rootRenderObject(self: *Tree) !?render_object.NodeHandle {
        var root: ?render_object.NodeHandle = null;
        for (self.occupiedSlots()) |index| {
            const slot = self.slots[index];
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

    pub fn paintAt(self: *const Tree, index: usize) ?struct { render: render_object.NodeHandle, paint: InteractionPaint } {
        if (index >= self.slots.len) return null;
        const slot = self.slots[index];
        if (slot.state != .active) return null;
        return .{ .render = slot.render.?, .paint = slot.interaction_paint orelse return null };
    }

    pub fn rangeInset(self: *Tree, handle: InstanceHandle) !f32 {
        return (try self.activeSlot(handle)).range_inset;
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

    pub fn dragOptions(self: *Tree, handle: InstanceHandle) !@import("../input/drag.zig").Options {
        return (try self.activeSlot(handle)).drag;
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

    pub fn isRetained(self: *Tree, handle: InstanceHandle) bool {
        return (self.activeSlot(handle) catch return false).retained;
    }

    pub fn traversalOrder(self: *Tree, handle: InstanceHandle) !usize {
        return (try self.activeSlot(handle)).traversal_order;
    }

    pub fn retainDescriptor(self: *Tree, id: u64) !Descriptor {
        const slot = self.findActiveById(id) orelse return error.RetainedInstanceMissing;
        return .{ .id = id, .parent = slot.parent_id, .object = undefined, .parent_data = try self.render_tree.parentData(slot.render.?), .retain_subtree = true };
    }

    fn markRetained(self: *Tree, render: render_object.NodeHandle) !void {
        const slot = try self.activeSlot(self.instanceForRenderObject(render).?);
        if (slot.retained) return error.OverlappingRetainedSubtree;
        slot.retained = true;
        var child = self.render_tree.firstChild(render);
        while (child) |node| {
            try self.markRetained(node);
            child = self.render_tree.nextSibling(node);
        }
    }

    fn orderRetained(self: *Tree, render: render_object.NodeHandle, order: *usize) void {
        const slot = self.activeSlot(self.instanceForRenderObject(render).?) catch unreachable;
        slot.traversal_order = order.*;
        order.* += 1;
        var child = self.render_tree.firstChild(render);
        while (child) |node| {
            self.orderRetained(node, order);
            child = self.render_tree.nextSibling(node);
        }
    }

    /// Visibility includes every retained Box ancestor. Hidden instances stay
    /// active (and retain widget state), but cannot participate in input.
    pub fn isVisible(self: *Tree, handle: InstanceHandle) bool {
        const slot = self.activeSlot(handle) catch return false;
        return self.render_tree.isVisible(slot.render.?) catch false;
    }

    pub fn isInteractive(self: *Tree, handle: InstanceHandle) bool {
        const slot = self.activeSlot(handle) catch return false;
        return self.render_tree.isInteractive(slot.render.?) catch false;
    }

    pub fn isFocusable(self: *Tree, handle: InstanceHandle) bool {
        const slot = self.activeSlot(handle) catch return false;
        return slot.focusable and self.isInteractive(handle);
    }

    /// Consume requests in declaration order, including ineligible targets:
    /// rejected requests must not become delayed focus steals on later builds.
    pub fn takeFocusRequest(self: *Tree) ?InstanceHandle {
        var selected: ?usize = null;
        for (self.occupiedSlots()) |index| {
            const slot = self.slots[index];
            if (slot.state != .active or !slot.focus_request_pending) continue;
            if (selected == null or slot.traversal_order < self.slots[selected.?].traversal_order)
                selected = index;
        }
        const index = selected orelse return null;
        self.slots[index].focus_request_pending = false;
        return handleFor(self.slots[index], index);
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
        for (self.occupiedSlots()) |index| {
            const slot = self.slots[index];
            if (slot.state != .active or !slot.focusable or
                !(self.render_tree.isInteractive(slot.render.?) catch false)) continue;
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

    pub fn applyScrollRequests(self: *Tree) !bool {
        var applied = false;
        for (self.occupiedSlots()) |index| {
            const slot = &self.slots[index];
            if (slot.state != .active or !slot.scroll_request_pending) continue;
            const handle: InstanceHandle = .{ .slot = @intCast(index), .generation = slot.generation };
            _ = try self.scrollBy(handle, slot.scroll_to.?.offset - slot.scroll_offset);
            slot.scroll_request_pending = false;
            applied = true;
        }
        return applied;
    }

    /// Reveal changed targets or changed geometry, without undoing manual
    /// scrolling when the same declaration is rebuilt unchanged.
    pub fn revealScrollTargets(self: *Tree) !bool {
        var changed = false;
        for (self.occupiedSlots()) |index| {
            const slot = &self.slots[index];
            if (slot.state != .active) continue;
            const id = slot.ensure_visible orelse continue;
            const object = try self.render_tree.objectAt(slot.render.?);
            if (object != .scroll) continue;
            const target = self.handleForId(id) orelse continue;
            const axis = object.scroll.axis;
            const size = try self.render_tree.nodeSize(try self.renderObject(target));
            const viewport = try self.render_tree.nodeSize(slot.render.?);
            var start: f32 = 0;
            var current: ?InstanceHandle = target;
            while (current) |candidate| {
                if (try self.semanticId(candidate) == slot.id) break;
                current = try self.scrollParent(candidate);
                // The direct child's offset is exactly the viewport's scroll
                // translation. Exclude it rather than canceling large floats.
                if (current) |parent| if (try self.semanticId(parent) != slot.id) {
                    const position = try self.render_tree.nodeOffset(try self.renderObject(candidate));
                    start += if (axis == .vertical) position.y else position.x;
                };
            }
            if (current == null) continue;
            const geometry: RevealGeometry = .{
                .id = id,
                .start = start,
                .extent = if (axis == .vertical) size.height else size.width,
                .viewport = if (axis == .vertical) viewport.height else viewport.width,
            };
            if (slot.revealed) |old| if (std.meta.eql(old, geometry)) continue;
            slot.revealed = geometry;
            const end = start + @min(geometry.extent, geometry.viewport);
            const offset = if (start < slot.scroll_offset or geometry.extent > geometry.viewport)
                start
            else if (end > slot.scroll_offset + geometry.viewport)
                end - geometry.viewport
            else
                slot.scroll_offset;
            if (try self.scrollBy(self.handleForId(slot.id).?, offset - slot.scroll_offset)) changed = true;
        }
        return changed;
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
            current = try self.scrollParent(handle);
        }
        return null;
    }

    /// Floating content keeps logical ancestry for events and focus, but is
    /// outside ancestor scroll viewports for wheel routing and reveal requests.
    pub fn scrollParent(self: *Tree, handle: InstanceHandle) !?InstanceHandle {
        const parent = (try self.parentOf(handle)) orelse return null;
        const render = try self.renderObject(parent);
        if ((try self.render_tree.objectAt(render)) == .anchored and
            !std.meta.eql(self.render_tree.firstChild(render).?, try self.renderObject(handle)))
            return null;
        return parent;
    }

    /// Layout may reduce a scroll extent after content changes. Synchronize
    /// clamped renderer values back into their authoritative instance slots.
    pub fn syncScrollOffsets(self: *Tree) !void {
        for (self.occupiedSlots()) |index| {
            const slot = &self.slots[index];
            if (slot.state != .active) continue;
            if ((try self.render_tree.objectAt(slot.render.?)) != .scroll) continue;
            slot.scroll_offset = try self.render_tree.scrollOffset(slot.render.?);
        }
    }

    pub fn activeCount(self: *const Tree) usize {
        var count: usize = 0;
        for (self.occupiedSlots()) |index| {
            if (self.slots[index].state == .active) count += 1;
        }
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
        return self.slots.len - self.occupied_count;
    }

    fn validateSnapshot(self: *Tree, descriptors: []const Descriptor) !void {
        if (descriptors.len > self.slots.len) return error.InstanceCapacityExceeded;
        const descriptor_index = IdIndex{ .entries = self.descriptor_entries };
        descriptor_index.clear();
        @memset(self.box_has_child[0..descriptors.len], false);
        var roots: usize = 0;
        for (descriptors, 0..) |descriptor, index| {
            if (descriptor.id == 0) return error.InvalidInstanceId;
            if (!descriptor.retain_subtree) {
                try descriptor.drag.validate();
                if (!std.math.isFinite(descriptor.range_inset) or descriptor.range_inset < 0)
                    return error.InvalidRangeInset;
                try render_object.Tree.validate(descriptor.object);
                if (descriptor.scroll_to) |request| {
                    if (descriptor.object != .scroll or descriptor.ensure_visible != null or request.token == 0 or
                        !std.math.isFinite(request.offset) or request.offset < 0) return error.InvalidScrollRequest;
                }
            }
            if (!(try descriptor_index.put(descriptor.id, index)))
                return error.DuplicateInstanceId;
            if (descriptor.parent) |parent_id| {
                const parent_index = descriptor_index.get(parent_id) orelse
                    return error.ParentMustPrecedeChild;
                if (parent_index == index) return error.ParentMustPrecedeChild;
                if (descriptors[parent_index].retain_subtree) return error.OverlappingRetainedSubtree;
                try render_object.Tree.validateEdge(
                    descriptors[parent_index].object,
                    descriptor.parent_data,
                );
                if (descriptors[parent_index].object == .box) {
                    if (self.box_has_child[parent_index]) return error.BoxAlreadyHasChild;
                    self.box_has_child[parent_index] = true;
                }
            } else {
                roots += 1;
                if (descriptor.parent_data != .none) return error.RootHasParentData;
            }
            if (!descriptor.retain_subtree) if (descriptor.interaction_paint) |paint| {
                if (descriptor.object != .box and descriptor.object != .text) return error.InvalidInteractionPaint;
                if (descriptor.object == .text and (paint.idle == null or paint.focus != null)) return error.InvalidInteractionPaint;
                var source: ?u64 = descriptor.id;
                while (source != null and source.? != paint.source) {
                    const source_index = descriptor_index.get(source.?) orelse return error.InvalidInteractionPaint;
                    source = descriptors[source_index].parent;
                }
                if (source == null) return error.InvalidInteractionPaint;
            };
        }
        if (descriptors.len != 0 and roots != 1) return error.InvalidRootCount;
    }

    fn rebuildIndices(self: *Tree) !void {
        const instance_index = IdIndex{ .entries = self.instance_entries };
        const render_index = IdIndex{ .entries = self.render_entries };
        instance_index.clear();
        render_index.clear();
        for (self.occupiedSlots()) |index| {
            const slot = self.slots[index];
            _ = try instance_index.put(slot.id, index);
            if (slot.render) |render| _ = try render_index.put(renderKey(render), index);
        }
        self.indices_dirty = false;
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
    const stale_plan = try instances.prepareReconcile(&reordered);
    try std.testing.expectEqual(
        try instances.renderObject(second),
        renders.firstChild(initial_root).?,
    );
    try instances.reconcile(&initial);
    try std.testing.expectError(
        error.StaleReconcilePlan,
        instances.applyReconcile(stale_plan),
    );
    const plan = try instances.prepareReconcile(&reordered);
    try instances.applyReconcile(plan);
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

test "retained subtree plans preserve descendants reorder focus and reject overlap transactionally" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 16, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 5);
    defer renders.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, scope, 5);
    defer tree.deinit();
    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 27 } } },
        .{ .id = 3, .parent = 2, .object = .{ .box = .{ .height = 13 } }, .focusable = true },
        .{ .id = 4, .parent = 1, .object = .{ .box = .{ .width = 41 } }, .focusable = true },
    };
    try tree.reconcile(&initial);
    const child = tree.handleForId(3).?;
    const sibling = tree.handleForId(4).?;
    const retained = try tree.retainDescriptor(2);
    const retained_child = try tree.retainDescriptor(3);
    const partial = [_]Descriptor{ initial[0], retained, initial[3] };
    const plan = try tree.prepareReconcile(&partial);
    try std.testing.expect(!plan.topology_changed);
    try tree.applyReconcile(plan);
    try std.testing.expectEqual(@as(usize, 4), tree.activeCount());
    try std.testing.expect(tree.isRetained(child));
    try std.testing.expectEqual(initial[2].object, try renders.objectAt(try tree.renderObject(child)));
    try std.testing.expectEqual(@as(?InstanceHandle, child), try tree.nextFocusable(null, false));
    const reordered = [_]Descriptor{ initial[0], initial[3], retained };
    try tree.reconcile(&reordered);
    try std.testing.expectEqual(child, tree.handleForId(3).?);
    try std.testing.expectEqual(@as(?InstanceHandle, sibling), try tree.nextFocusable(null, false));
    try std.testing.expectEqual(@as(?InstanceHandle, child), try tree.nextFocusable(sibling, false));
    try std.testing.expectError(error.OverlappingRetainedSubtree, tree.prepareReconcile(&.{ initial[0], retained, retained_child }));
    try std.testing.expectError(error.OverlappingRetainedSubtree, tree.prepareReconcile(&.{ initial[0], retained, initial[2] }));
    try std.testing.expectEqual(@as(usize, 4), tree.activeCount());
    // Even a failed later preparation invalidates the earlier scratch plan.
    const stale = try tree.prepareReconcile(&partial);
    try std.testing.expectError(error.OverlappingRetainedSubtree, tree.prepareReconcile(&.{ initial[0], retained, retained_child }));
    try std.testing.expectError(error.StaleReconcilePlan, tree.applyReconcile(stale));
    try tree.reconcile(&.{initial[0]});
    try std.testing.expect(!tree.isActive(child));
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try std.testing.expectError(error.RetainedInstanceMissing, tree.prepareReconcile(&partial));
    try tree.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try scheduler.destroyScope(scope);
}

test "topology reconciliation relayouts only the affected sibling branch" {
    const Constraints = @import("../layout/constraints.zig").Constraints;
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 12, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 8);
    defer renders.deinit();
    var instances: Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 8);
    defer instances.deinit();

    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .flex = .{ .main_axis_size = .min } } },
        .{ .id = 3, .parent = 2, .object = .{ .box = .{ .width = 10, .height = 10 } } },
        .{ .id = 4, .parent = 1, .object = .{ .stack = .{} } },
        .{ .id = 5, .parent = 4, .object = .{ .box = .{ .width = 20, .height = 20 } } },
        .{ .id = 6, .parent = 4, .object = .{ .box = .{ .width = 30, .height = 30 } } },
    };
    try instances.reconcile(&initial);
    const root = (try instances.rootRenderObject()).?;
    const unchanged = try instances.renderObject(instances.handleForId(2).?);
    _ = try renders.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));
    const count = try renders.layoutCount(unchanged);

    const reordered = [_]Descriptor{ initial[0], initial[1], initial[2], initial[3], initial[5], initial[4] };
    const reorder_plan = try instances.prepareReconcile(&reordered);
    try std.testing.expect(reorder_plan.topology_changed);
    try std.testing.expect(!reorder_plan.creates_instances and !reorder_plan.removes_instances);
    try instances.applyReconcile(reorder_plan);
    _ = try renders.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));
    try std.testing.expectEqual(count, try renders.layoutCount(unchanged));

    const removed = [_]Descriptor{ reordered[0], reordered[1], reordered[2], reordered[3], reordered[4] };
    try instances.reconcile(&removed);
    _ = try renders.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));
    try std.testing.expectEqual(count, try renders.layoutCount(unchanged));

    const created = [_]Descriptor{ removed[0], removed[1], removed[2], removed[3], removed[4], .{ .id = 7, .parent = 4, .object = .{ .box = .{ .width = 15, .height = 15 } } } };
    try instances.reconcile(&created);
    _ = try renders.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));
    try std.testing.expectEqual(count, try renders.layoutCount(unchanged));

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "occupied slots retain draining scopes and reuse holes without moving handles" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 20, 1, 0);
    defer scheduler.deinit();
    const owner = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 16);
    defer renders.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, owner, 1024);
    defer tree.deinit();
    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 3, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 4, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
    };
    try tree.reconcile(&initial);
    const removed = tree.handleForId(2).?;
    const retained = tree.handleForId(4).?;
    const child_scope = try scheduler.createScope(try tree.scope(removed));
    try tree.reconcile(&.{ initial[0], initial[3] });
    try tree.collectRetired();
    try std.testing.expectEqual(@as(usize, 3), tree.occupiedSlots().len);
    try std.testing.expectEqual(@as(usize, 2), tree.activeCount());
    try std.testing.expectEqual(retained, tree.handleForId(4).?);
    try std.testing.expectError(error.InstanceRetiring, tree.prepareReconcile(&initial));
    try scheduler.applyQueuedCancellations();
    try scheduler.destroyScope(child_scope);
    try tree.collectRetired();
    try std.testing.expectEqual(@as(usize, 2), tree.occupiedSlots().len);
    try std.testing.expectEqual(@as(usize, 1022), tree.freeCount());

    // Reusing holes preserves ascending slot order, not insertion order.
    try tree.reconcile(&initial);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, tree.occupiedSlots());
    const replacement = tree.handleForId(2).?;
    try std.testing.expectEqual(removed.slot, replacement.slot);
    try std.testing.expect(removed.generation != replacement.generation);
    try std.testing.expect(!tree.isActive(removed));
    try std.testing.expectEqual(retained, tree.handleForId(4).?);
    try std.testing.expectEqual(replacement, (try tree.nextFocusable(null, false)).?);
    try std.testing.expectEqual(retained, (try tree.nextFocusable(null, true)).?);
    const plan = try tree.prepareReconcile(&initial);
    try std.testing.expect(!plan.topology_changed);
    try tree.applyReconcile(plan);
    try tree.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try std.testing.expectEqual(@as(usize, 0), tree.occupiedSlots().len);
    try std.testing.expectEqual(@as(usize, 1024), tree.freeCount());
    try scheduler.destroyScope(owner);
}

test "identity indexes survive unchanged builds and repeated slot reuse" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    const owner = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 1);
    defer renders.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, owner, 1);
    defer tree.deinit();
    var previous_render: ?render_object.NodeHandle = null;
    for (1..20) |id| {
        const snapshot = [_]Descriptor{.{ .id = id, .parent = null, .object = .{ .box = .{ .width = @floatFromInt(id) } } }};
        try tree.reconcile(&snapshot);
        const handle = tree.handleForId(id).?;
        const render = try tree.renderObject(handle);
        try std.testing.expectEqual(handle, tree.instanceForRenderObject(render).?);
        if (previous_render) |old| {
            try std.testing.expectEqual(@as(?InstanceHandle, null), tree.instanceForRenderObject(old));
            try std.testing.expectEqual(@as(?InstanceHandle, null), tree.handleForId(id - 1));
        }
        try std.testing.expect(!tree.indices_dirty);
        try tree.reconcile(&snapshot);
        try std.testing.expectEqual(handle, tree.handleForId(id).?);
        try std.testing.expectEqual(render, try tree.renderObject(handle));
        const plan = try tree.prepareReconcile(&snapshot);
        try tree.reconcile(&.{});
        try std.testing.expect(tree.indices_dirty);
        try std.testing.expectEqual(@as(?InstanceHandle, null), tree.instanceForRenderObject(render));
        try std.testing.expectError(error.StaleReconcilePlan, tree.applyReconcile(plan));
        try scheduler.applyQueuedCancellations();
        try tree.collectRetired();
        try std.testing.expect(tree.indices_dirty);
        previous_render = render;
    }
    try scheduler.destroyScope(owner);
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

test "reconcile plans distinguish property updates removals and creations at capacity" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 2);
    defer renders.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, scope, 3);
    defer tree.deinit();
    const root: Descriptor = .{ .id = 1, .parent = null, .object = .{ .stack = .{} } };
    const child: Descriptor = .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 17 } } };
    try tree.reconcile(&.{ root, child });
    const original = tree.handleForId(2).?;
    try std.testing.expectEqual(@as(usize, 0), scheduler.availableScopeCapacity());
    try std.testing.expectEqual(@as(usize, 0), renders.availableCapacity());

    var changed = child;
    changed.object.box.width = 39;
    const update = try tree.prepareReconcile(&.{ root, changed });
    try std.testing.expect(!update.creates_instances and !update.removes_instances and !update.topology_changed);
    try tree.applyReconcile(update);
    try std.testing.expectEqual(original, tree.handleForId(2).?);
    try std.testing.expectEqual(@as(?f32, 39), (try renders.objectAt(try tree.renderObject(original))).box.width);
    changed.object.box.width = -1;
    try std.testing.expectError(error.InvalidExtent, tree.prepareReconcile(&.{ root, changed }));
    try std.testing.expectEqual(@as(?f32, 39), (try renders.objectAt(try tree.renderObject(original))).box.width);

    var replacement = child;
    replacement.id = 3;
    // Replacement needs a new scope before the retiring scope drains;
    // preparation reserves it instead of failing.
    _ = try tree.prepareReconcile(&.{ root, replacement });
    try std.testing.expect(scheduler.availableScopeCapacity() >= 1);
    const removal = try tree.prepareReconcile(&.{root});
    try std.testing.expect(removal.removes_instances and !removal.creates_instances);
    try tree.applyReconcile(removal);
    try std.testing.expect(!tree.isActive(original));
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    const creation = try tree.prepareReconcile(&.{ root, replacement });
    try std.testing.expect(creation.creates_instances and !creation.removes_instances);
    try tree.applyReconcile(creation);
    try std.testing.expect(tree.handleForId(3) != null);

    try tree.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try scheduler.destroyScope(scope);
}

test "box child validation handles interleaved descendants and resets after rejection" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 16, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 8);
    defer renders.deinit();
    var instances: Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 8);
    defer instances.deinit();
    const valid = [_]Descriptor{
        .{ .id = 100, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 80, .parent = 100, .object = .{ .box = .{} } },
        .{ .id = 12, .parent = 100, .object = .{ .box = .{} } },
        .{ .id = 400, .parent = 80, .object = .{ .box = .{} } },
        .{ .id = 22, .parent = 12, .object = .{ .box = .{} } },
        .{ .id = 401, .parent = 400, .object = .{ .box = .{} } },
    };
    try instances.reconcile(&valid);
    const parent = instances.handleForId(80).?;
    const child = try instances.renderObject(instances.handleForId(400).?);
    const invalid = valid ++ [_]Descriptor{.{ .id = 77, .parent = 80, .object = .{ .box = .{} } }};
    try std.testing.expectError(error.BoxAlreadyHasChild, instances.prepareReconcile(&invalid));
    try std.testing.expectEqual(parent, instances.handleForId(80).?);
    try std.testing.expectEqual(child, renders.firstChild(try instances.renderObject(parent)).?);
    try std.testing.expectEqual(@as(?InstanceHandle, null), instances.handleForId(77));
    try instances.reconcile(&valid);
    try instances.reconcile(&valid);
    try std.testing.expectEqual(parent, instances.handleForId(80).?);
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

test "floating subtrees fence scroll lookup and reveal but retain inner scrolling" {
    const Constraints = @import("../layout/constraints.zig").Constraints;
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 16, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 10);
    defer renders.deinit();
    var instances: Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 10);
    defer instances.deinit();
    try instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .scroll = .{} }, .ensure_visible = 8 },
        .{ .id = 2, .parent = 1, .object = .{ .stack = .{} } },
        .{ .id = 3, .parent = 2, .object = .{ .anchored = .{} }, .parent_data = .{ .stack = .{ .y = 20 } } },
        .{ .id = 4, .parent = 3, .object = .{ .box = .{ .width = 23, .height = 17 } } },
        .{ .id = 5, .parent = 3, .object = .{ .box = .{ .width = 60, .height = 40 } } },
        .{ .id = 6, .parent = 5, .object = .{ .scroll = .{} }, .ensure_visible = 8 },
        .{ .id = 7, .parent = 6, .object = .{ .stack = .{} } },
        .{ .id = 8, .parent = 7, .object = .{ .box = .{ .width = 31, .height = 19 } }, .parent_data = .{ .stack = .{ .y = 110 } } },
        .{ .id = 9, .parent = 2, .object = .{ .box = .{ .width = 13, .height = 21 } }, .parent_data = .{ .stack = .{ .y = 160 } } },
    });
    _ = try renders.layout((try instances.rootRenderObject()).?, Constraints.tight(.{ .width = 100, .height = 60 }));
    const outer = instances.handleForId(1).?;
    const inner = instances.handleForId(6).?;
    try std.testing.expectEqual(outer, (try instances.nearestScroll(instances.handleForId(4).?, .vertical)).?);
    try std.testing.expect((try instances.nearestScroll(instances.handleForId(5).?, .vertical)) == null);
    try std.testing.expectEqual(inner, (try instances.nearestScroll(instances.handleForId(8).?, .vertical)).?);
    try std.testing.expect(try instances.revealScrollTargets());
    try std.testing.expectEqual(@as(f32, 0), try instances.scrollOffset(outer));
    try std.testing.expectEqual(@as(f32, 89), try instances.scrollOffset(inner));
    try std.testing.expect(!try instances.revealScrollTargets());

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "image reconciliation preserves identity and prevalidates stale replacements before removal" {
    const ImageCache = @import("../../image/cache.zig").Cache;
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 2);
    defer renders.deinit();
    renders.attachImageCache(&images);
    var instances: Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 2);
    defer instances.deinit();
    try instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .image = .{ .width = 63, .height = 21 } } },
    });
    const identity = instances.handleForId(2).?;
    const root = (try instances.rootRenderObject()).?;
    const leaf = renders.firstChild(root).?;
    const bitmap = @import("../../image/pixels.zig").Bitmap{
        .allocator = std.testing.allocator,
        .pixels = try std.testing.allocator.dupe(u8, &.{ 17, 31, 63, 255 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = 120,
        .intrinsic_height = 40,
    };
    const image = try images.insert(bitmap);
    const loaded = [_]Descriptor{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .image = .{ .image = image } } },
    };
    try instances.reconcile(&loaded);
    try images.release(image);
    try instances.reconcile(&loaded);
    try std.testing.expectEqual(identity, instances.handleForId(2).?);
    try std.testing.expectEqual(leaf, renders.firstChild(root).?);

    const stale: Handle = .{ .slot = image.slot, .generation = image.generation + 1 };
    try std.testing.expectError(error.StaleImageHandle, instances.prepareReconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .image = .{ .image = stale } } },
    }));
    try std.testing.expectEqual(identity, instances.handleForId(2).?);
    try std.testing.expectEqual(leaf, renders.firstChild(root).?);
    try std.testing.expectEqual(image, (try renders.objectAt(leaf)).image.image.?);
    try std.testing.expectError(error.ImageHasChildren, instances.prepareReconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .image = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .image = .{} } },
    }));

    try instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
    });
    try std.testing.expectError(error.StaleImageHandle, images.get(image));
    var replacement_bitmap = bitmap;
    replacement_bitmap.pixels = try std.testing.allocator.dupe(u8, &.{ 3, 7, 11, 255 });
    const replacement = try images.insert(replacement_bitmap);
    try std.testing.expect(replacement.generation != image.generation);
    try std.testing.expectError(error.StaleImageHandle, instances.prepareReconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .image = .{ .image = image } } },
    }));
    try images.release(replacement);

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}
