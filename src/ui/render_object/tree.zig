const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const Handle = @import("../../core/handle.zig").Handle;
const PointF = @import("../../core/geometry.zig").PointF;
const RectF = @import("../../core/geometry.zig").RectF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const box_impl = @import("box.zig");
const flex_impl = @import("flex.zig");
const stack_impl = @import("stack.zig");
const scene_builder = @import("scene_builder.zig");
const text = @import("../../text/root.zig");
const types = @import("types.zig");

pub const NodeHandle = Handle;
pub const LayoutError = error{
    InvalidConstraints,
    StaleRenderObject,
    LayoutRootHasParent,
    BoxHasMultipleChildren,
    InvalidChildOffset,
    InvalidLayoutSize,
    UnconstrainedLayoutSize,
    FlexInUnboundedAxis,
    InvalidParentData,
    LabelHasChildren,
    TextCacheRequired,
    StaleShape,
};

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    object: types.Object = .{ .box = .{} },
    parent: ?NodeHandle = null,
    first_child: ?NodeHandle = null,
    last_child: ?NodeHandle = null,
    previous_sibling: ?NodeHandle = null,
    next_sibling: ?NodeHandle = null,
    parent_data: types.ParentData = .none,
    size: SizeF = .{ .width = 0, .height = 0 },
    offset: PointF = .{},
    last_constraints: Constraints = .{},
    has_layout: bool = false,
    needs_layout: bool = true,
    needs_paint: bool = true,
    layout_count: usize = 0,
};

/// Fixed-capacity, allocation-free-during-layout storage for the closed typed
/// render-object set. This is deliberately not the widget/instance tree.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    text_cache: ?*text.ShapeCache = null,

    pub fn init(self: *Tree, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *Tree) void {
        for (self.slots) |entry| if (entry.active) self.releaseObject(entry.object);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// The shape cache must outlive this tree. Label objects retain their shape
    /// handles across reconciliation and release them on replacement/teardown.
    pub fn attachTextCache(self: *Tree, cache: *text.ShapeCache) void {
        std.debug.assert(self.text_cache == null);
        self.text_cache = cache;
    }

    pub fn create(self: *Tree, object: types.Object) !NodeHandle {
        try validateObject(object);
        try self.retainObject(object);
        errdefer self.releaseObject(object);
        for (self.slots, 0..) |*candidate, index| {
            if (candidate.active) continue;
            var generation = candidate.generation +% 1;
            if (generation == 0) generation = 1;
            candidate.* = .{ .generation = generation, .active = true, .object = object };
            return .{ .slot = @intCast(index), .generation = generation };
        }
        return error.RenderObjectCapacityExceeded;
    }

    pub fn destroy(self: *Tree, handle: NodeHandle) !void {
        const target = try self.slot(handle);
        if (target.first_child != null) return error.RenderObjectHasChildren;
        const generation = target.generation;
        try self.detach(handle);
        self.releaseObject(target.object);
        self.slots[handle.slot] = .{ .generation = generation };
    }

    pub fn detachChild(self: *Tree, handle: NodeHandle) !void {
        try self.detach(handle);
    }

    pub fn availableCapacity(self: *const Tree) usize {
        var count: usize = 0;
        for (self.slots) |candidate| if (!candidate.active) {
            count += 1;
        };
        return count;
    }

    pub fn validate(object: types.Object) !void {
        try validateObject(object);
    }

    pub fn validateEdge(parent: types.Object, data: types.ParentData) !void {
        try validateParentData(parent, data);
    }

    pub fn appendChild(
        self: *Tree,
        parent: NodeHandle,
        child: NodeHandle,
        data: types.ParentData,
    ) !void {
        var ancestor: ?NodeHandle = parent;
        while (ancestor) |current| {
            if (same(current, child)) return error.RenderObjectCycle;
            ancestor = (try self.slot(current)).parent;
        }
        const parent_slot = try self.slot(parent);
        const child_slot = try self.slot(child);
        if (child_slot.parent != null) return error.RenderObjectAlreadyAttached;
        try validateParentData(parent_slot.object, data);
        if (parent_slot.object == .box and parent_slot.first_child != null)
            return error.BoxAlreadyHasChild;
        if (parent_slot.object == .label) return error.LabelHasChildren;

        child_slot.parent = parent;
        child_slot.parent_data = data;
        child_slot.previous_sibling = parent_slot.last_child;
        child_slot.next_sibling = null;
        if (parent_slot.last_child) |last|
            (try self.slot(last)).next_sibling = child
        else
            parent_slot.first_child = child;
        parent_slot.last_child = child;
        self.markNeedsLayout(parent);
    }

    pub fn setParentData(self: *Tree, child: NodeHandle, data: types.ParentData) !void {
        const child_slot = try self.slot(child);
        const parent = child_slot.parent orelse return error.RenderObjectNotAttached;
        try validateParentData((try self.slot(parent)).object, data);
        if (std.meta.eql(child_slot.parent_data, data)) return;
        child_slot.parent_data = data;
        self.markNeedsLayout(parent);
    }

    pub fn update(self: *Tree, handle: NodeHandle, object: types.Object) !void {
        try validateObject(object);
        const target = try self.slot(handle);
        if (std.meta.eql(target.object, object)) return;
        if (object == .box and target.first_child != null and
            !same(target.first_child.?, target.last_child.?)) return error.BoxAlreadyHasChild;
        var child = target.first_child;
        while (child) |child_handle| : (child = (try self.slot(child_handle)).next_sibling)
            try validateParentData(object, (try self.slot(child_handle)).parent_data);

        const affects_layout = layoutPropertiesChanged(target.object, object);
        try self.retainObject(object);
        const previous = target.object;
        target.object = object;
        self.releaseObject(previous);
        if (affects_layout)
            self.markNeedsLayout(handle)
        else
            self.markNeedsPaint(handle);
    }

    pub fn objectAt(self: *Tree, handle: NodeHandle) !types.Object {
        return (try self.slot(handle)).object;
    }

    pub fn layout(self: *Tree, root: NodeHandle, constraints: Constraints) LayoutError!SizeF {
        try constraints.validate();
        const root_slot = try self.slot(root);
        if (root_slot.parent != null) return error.LayoutRootHasParent;
        root_slot.offset = .{};
        return self.layoutNode(root, constraints);
    }

    pub fn buildScene(
        self: *Tree,
        root: NodeHandle,
        builder: *scene_builder.Builder,
    ) !void {
        const root_slot = try self.slot(root);
        if (!root_slot.has_layout or root_slot.needs_layout) return error.LayoutRequired;
        try self.paintNode(root, builder, .{});
    }

    pub fn hitTest(self: *Tree, root: NodeHandle, point: PointF) !?NodeHandle {
        const root_slot = try self.slot(root);
        if (!root_slot.has_layout or root_slot.needs_layout) return error.LayoutRequired;
        return self.hitTestNode(root, point);
    }

    pub fn nodeSize(self: *Tree, handle: NodeHandle) !SizeF {
        const target = try self.slot(handle);
        if (!target.has_layout or !(try self.layoutPathCurrent(handle))) return error.LayoutRequired;
        return target.size;
    }

    pub fn nodeOffset(self: *Tree, handle: NodeHandle) !PointF {
        const target = try self.slot(handle);
        if (!target.has_layout or !(try self.layoutPathCurrent(handle))) return error.LayoutRequired;
        return target.offset;
    }

    pub fn layoutCount(self: *Tree, handle: NodeHandle) !usize {
        return (try self.slot(handle)).layout_count;
    }

    pub fn layoutDirty(self: *Tree, handle: NodeHandle) !bool {
        return (try self.slot(handle)).needs_layout;
    }

    pub fn paintDirty(self: *Tree, handle: NodeHandle) !bool {
        return (try self.slot(handle)).needs_paint;
    }

    pub fn firstChild(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).first_child;
    }

    pub fn nextSibling(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).next_sibling;
    }

    pub fn childCount(self: *Tree, handle: NodeHandle) usize {
        var count: usize = 0;
        var child = self.firstChild(handle);
        while (child) |current| : (child = self.nextSibling(current)) count += 1;
        return count;
    }

    pub fn onlyChild(self: *Tree, handle: NodeHandle) LayoutError!?NodeHandle {
        const first = (try self.slot(handle)).first_child orelse return null;
        if ((try self.slot(first)).next_sibling != null) return error.BoxHasMultipleChildren;
        return first;
    }

    pub fn parentData(self: *Tree, handle: NodeHandle) LayoutError!types.ParentData {
        return (try self.slot(handle)).parent_data;
    }

    pub fn size(self: *Tree, handle: NodeHandle) LayoutError!SizeF {
        const target = try self.slot(handle);
        if (!target.has_layout) return error.InvalidLayoutSize;
        return target.size;
    }

    pub fn layoutChild(self: *Tree, handle: NodeHandle, constraints: Constraints) LayoutError!SizeF {
        return self.layoutNode(handle, constraints);
    }

    pub fn setChildOffset(self: *Tree, handle: NodeHandle, offset: PointF) LayoutError!void {
        if (!validPoint(offset)) return error.InvalidChildOffset;
        const child = try self.slot(handle);
        if (std.meta.eql(child.offset, offset)) return;
        child.offset = offset;
        self.markNeedsPaint(handle);
    }

    fn layoutNode(self: *Tree, handle: NodeHandle, constraints: Constraints) LayoutError!SizeF {
        try constraints.validate();
        const current = try self.slot(handle);
        if (!current.needs_layout and current.has_layout and
            std.meta.eql(current.last_constraints, constraints)) return current.size;
        const object = current.object;
        const result = switch (object) {
            .box => |value| try box_impl.layout(value, self, handle, constraints),
            .flex => |value| try flex_impl.layout(value, self, handle, constraints),
            .stack => |value| try stack_impl.layout(value, self, handle, constraints),
            .label => try self.layoutLabel(object.label, constraints),
        };
        if (!validSize(result)) return error.InvalidLayoutSize;
        const constrained = constraints.constrain(result);
        if (!std.meta.eql(result, constrained)) return error.UnconstrainedLayoutSize;
        const target = try self.slot(handle);
        target.size = result;
        target.last_constraints = constraints;
        target.has_layout = true;
        target.needs_layout = false;
        target.needs_paint = true;
        target.layout_count += 1;
        return result;
    }

    fn paintNode(
        self: *Tree,
        handle: NodeHandle,
        builder: *scene_builder.Builder,
        origin: PointF,
    ) !void {
        const target = try self.slot(handle);
        const bounds: RectF = .{
            .x = origin.x,
            .y = origin.y,
            .width = target.size.width,
            .height = target.size.height,
        };
        const clips = switch (target.object) {
            .box => |value| paint: {
                if (value.background) |color| try builder.solidRectangle(bounds, color);
                break :paint value.clip;
            },
            .flex => false,
            .stack => |value| value.clip,
            .label => |value| paint: {
                const shaped = try self.shape(value.shape);
                try builder.pushClip(bounds);
                try builder.glyphRun(
                    value.shape,
                    .{ .x = origin.x, .y = origin.y + shaped.metrics.ascender },
                    value.color,
                );
                break :paint true;
            },
        };
        if (clips and target.object != .label) try builder.pushClip(bounds);
        var child = target.first_child;
        while (child) |child_handle| {
            const child_slot = try self.slot(child_handle);
            const next = child_slot.next_sibling;
            try self.paintNode(child_handle, builder, PointF.add(origin, child_slot.offset));
            child = next;
        }
        if (clips) try builder.popClip();
        target.needs_paint = false;
    }

    fn hitTestNode(self: *Tree, handle: NodeHandle, point: PointF) !?NodeHandle {
        const target = try self.slot(handle);
        if (!(RectF{ .x = 0, .y = 0, .width = target.size.width, .height = target.size.height }).contains(point))
            return null;
        var child = target.last_child;
        while (child) |child_handle| {
            const child_slot = try self.slot(child_handle);
            const previous = child_slot.previous_sibling;
            if (try self.hitTestNode(child_handle, .{
                .x = point.x - child_slot.offset.x,
                .y = point.y - child_slot.offset.y,
            })) |hit| return hit;
            child = previous;
        }
        return handle;
    }

    fn detach(self: *Tree, handle: NodeHandle) !void {
        const target = try self.slot(handle);
        const parent_handle = target.parent orelse return;
        const parent = try self.slot(parent_handle);
        if (target.previous_sibling) |previous|
            (try self.slot(previous)).next_sibling = target.next_sibling
        else
            parent.first_child = target.next_sibling;
        if (target.next_sibling) |next|
            (try self.slot(next)).previous_sibling = target.previous_sibling
        else
            parent.last_child = target.previous_sibling;
        target.parent = null;
        target.previous_sibling = null;
        target.next_sibling = null;
        target.parent_data = .none;
        self.markNeedsLayout(parent_handle);
    }

    fn markNeedsLayout(self: *Tree, handle: NodeHandle) void {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = self.slot(value) catch unreachable;
            target.needs_layout = true;
            target.needs_paint = true;
            current = target.parent;
        }
    }

    fn markNeedsPaint(self: *Tree, handle: NodeHandle) void {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = self.slot(value) catch unreachable;
            target.needs_paint = true;
            current = target.parent;
        }
    }

    fn layoutPathCurrent(self: *Tree, handle: NodeHandle) !bool {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = try self.slot(value);
            if (target.needs_layout) return false;
            current = target.parent;
        }
        return true;
    }

    fn slot(self: *Tree, handle: NodeHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleRenderObject;
        const target = &self.slots[handle.slot];
        if (!target.active or target.generation != handle.generation)
            return error.StaleRenderObject;
        return target;
    }

    fn layoutLabel(self: *Tree, label: types.Label, constraints: Constraints) LayoutError!SizeF {
        const shaped = try self.shape(label.shape);
        return constraints.constrain(.{
            .width = @abs(shaped.advance.x),
            .height = @max(0, shaped.metrics.ascender - shaped.metrics.descender + shaped.metrics.line_gap),
        });
    }

    fn shape(self: *Tree, handle: text.ShapeHandle) LayoutError!*const text.FallbackResult {
        const cache = self.text_cache orelse return error.TextCacheRequired;
        return cache.get(handle) catch return error.StaleShape;
    }

    fn retainObject(self: *Tree, object: types.Object) !void {
        switch (object) {
            .label => |label| {
                const cache = self.text_cache orelse return error.TextCacheRequired;
                try cache.retain(label.shape);
            },
            else => {},
        }
    }

    fn releaseObject(self: *Tree, object: types.Object) void {
        switch (object) {
            .label => |label| self.text_cache.?.release(label.shape) catch unreachable,
            else => {},
        }
    }
};

fn validateObject(object: types.Object) !void {
    switch (object) {
        .box => |value| try box_impl.validate(value),
        .flex => |value| try flex_impl.validate(value),
        .stack => {},
        .label => {},
    }
}

fn validateParentData(parent: types.Object, data: types.ParentData) !void {
    switch (parent) {
        .box => if (data != .none) return error.InvalidParentData,
        .flex => if (data != .none and data != .flex) return error.InvalidParentData,
        .stack => switch (data) {
            .none => {},
            .stack => |value| if (!validPoint(.{ .x = value.x, .y = value.y }))
                return error.InvalidParentData,
            .flex => return error.InvalidParentData,
        },
        .label => return error.LabelHasChildren,
    }
}

fn layoutPropertiesChanged(old: types.Object, new: types.Object) bool {
    if (std.meta.activeTag(old) != std.meta.activeTag(new)) return true;
    return switch (old) {
        .box => |old_box| changed: {
            const new_box = new.box;
            break :changed old_box.width != new_box.width or old_box.height != new_box.height or
                !std.meta.eql(old_box.padding, new_box.padding);
        },
        .flex => |old_flex| !std.meta.eql(old_flex, new.flex),
        .stack => false,
        .label => |old_label| !sameShape(old_label.shape, new.label.shape),
    };
}

fn validPoint(point: PointF) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn validSize(size_value: SizeF) bool {
    return std.math.isFinite(size_value.width) and std.math.isFinite(size_value.height) and
        size_value.width >= 0 and size_value.height >= 0;
}

fn same(a: NodeHandle, b: NodeHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sameShape(a: text.ShapeHandle, b: text.ShapeHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "flex layout is bounded, cached, and separates paint invalidation" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .flex = .{ .gap = 5, .cross_axis_alignment = .stretch } });
    const fixed = try tree.create(.{ .box = .{
        .width = 20,
        .background = Color.rgba(10, 20, 30, 255),
    } });
    const expanded = try tree.create(.{ .box = .{ .background = Color.rgba(40, 50, 60, 255) } });
    try tree.appendChild(root, fixed, .none);
    try tree.appendChild(root, expanded, .{ .flex = .{ .factor = 1 } });

    try std.testing.expectEqual(
        SizeF{ .width = 100, .height = 20 },
        try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 20 })),
    );
    try std.testing.expectEqual(SizeF{ .width = 20, .height = 20 }, try tree.nodeSize(fixed));
    try std.testing.expectEqual(SizeF{ .width = 75, .height = 20 }, try tree.nodeSize(expanded));
    try std.testing.expectEqual(PointF{ .x = 25, .y = 0 }, try tree.nodeOffset(expanded));

    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 20 }));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(root));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(expanded));
    try tree.update(expanded, .{ .box = .{ .background = Color.rgba(70, 80, 90, 255) } });
    try std.testing.expect(!(try tree.layoutDirty(root)));
    try std.testing.expect(try tree.paintDirty(root));
    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 20 }));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(root));
}

test "stack paints in order and hit tests front to back" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{ .clip = true } });
    const back = try tree.create(.{ .box = .{
        .width = 50,
        .height = 50,
        .background = Color.rgba(1, 2, 3, 255),
    } });
    const front = try tree.create(.{ .box = .{
        .width = 20,
        .height = 20,
        .background = Color.rgba(4, 5, 6, 255),
    } });
    try tree.appendChild(root, back, .none);
    try tree.appendChild(root, front, .{ .stack = .{ .x = 10, .y = 10 } });
    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));

    try std.testing.expectEqual(front, (try tree.hitTest(root, .{ .x = 15, .y = 15 })).?);
    try std.testing.expectEqual(back, (try tree.hitTest(root, .{ .x = 5, .y = 5 })).?);
    try std.testing.expectEqual(root, (try tree.hitTest(root, .{ .x = 90, .y = 70 })).?);
    try std.testing.expect((try tree.hitTest(root, .{ .x = 100, .y = 40 })) == null);

    var commands: [4]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    const list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), list.commands.len);
    try std.testing.expectEqual(@as(i32, 0), list.commands[1].solid_rectangle.bounds.x);
    try std.testing.expectEqual(@as(i32, 10), list.commands[2].solid_rectangle.bounds.x);
    try std.testing.expect(!(try tree.paintDirty(root)));
    try list.validate();
}

test "flex children reject an unbounded main axis" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .flex = .{ .axis = .vertical } });
    const child = try tree.create(.{ .box = .{} });
    try tree.appendChild(root, child, .{ .flex = .{ .factor = 1 } });
    try std.testing.expectError(error.FlexInUnboundedAxis, tree.layout(root, .{}));
}

test "box padding participates in constraints and child changes invalidate ancestors" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .box = .{ .padding = .all(4) } });
    const child = try tree.create(.{ .box = .{ .width = 20, .height = 10 } });
    try tree.appendChild(root, child, .none);
    try std.testing.expectEqual(
        SizeF{ .width = 28, .height = 18 },
        try tree.layout(root, .{ .max_width = 100, .max_height = 100 }),
    );
    try std.testing.expectEqual(PointF{ .x = 4, .y = 4 }, try tree.nodeOffset(child));

    try tree.update(child, .{ .box = .{ .width = 30, .height = 10 } });
    try std.testing.expect(try tree.layoutDirty(root));
    try std.testing.expectEqual(
        SizeF{ .width = 38, .height = 18 },
        try tree.layout(root, .{ .max_width = 100, .max_height = 100 }),
    );
    try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(root));
}

test "render-object topology rejects cycles and stale generations" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const child = try tree.create(.{ .stack = .{} });
    try tree.appendChild(root, child, .none);
    try std.testing.expectError(error.RenderObjectCycle, tree.appendChild(child, root, .none));
    try tree.destroy(child);
    try std.testing.expectError(error.StaleRenderObject, tree.nodeSize(child));
    const replacement = try tree.create(.{ .box = .{} });
    try std.testing.expectEqual(child.slot, replacement.slot);
    try std.testing.expect(child.generation != replacement.generation);
}
