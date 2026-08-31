const std = @import("std");
const PointF = @import("../core/geometry.zig").PointF;
const SizeF = @import("../core/geometry.zig").SizeF;
const scene = @import("../scene/root.zig");
const text = @import("../text/root.zig");
const Constraints = @import("layout/constraints.zig").Constraints;
const render_object = @import("render_object/root.zig");
const render_types = @import("render_object/types.zig");

/// One node in a complete, parent-before-child native UI snapshot. IDs are
/// stable within a surface and are returned by hit testing and pointer input.
pub const Descriptor = struct {
    id: u64,
    parent: ?u64,
    object: render_types.Object,
    parent_data: render_types.ParentData = .none,
};

pub const PointerResult = struct {
    target: ?u64,
    hovered: ?u64,
};

const Slot = struct {
    active: bool = false,
    id: u64 = 0,
    parent: ?u64 = null,
    order: usize = 0,
    render: render_object.NodeHandle = .invalid,
};

/// Fixed-capacity owner for a scheduler-free native render tree and its
/// synchronous display-list storage. Reconciliation is keyed but deliberately
/// contains no component lifecycle, callbacks, or application scheduling.
pub const Surface = struct {
    allocator: std.mem.Allocator,
    tree: render_object.Tree,
    slots: []Slot,
    commands: []scene.Command,
    root: ?render_object.NodeHandle = null,
    command_count: usize = 0,
    hovered: ?u64 = null,
    captured: ?u64 = null,

    pub fn init(
        self: *Surface,
        allocator: std.mem.Allocator,
        node_capacity: usize,
        scene_capacity: usize,
    ) !void {
        if (node_capacity == 0 or scene_capacity == 0) return error.InvalidCapacity;
        var tree: render_object.Tree = undefined;
        try tree.init(allocator, node_capacity);
        errdefer tree.deinit();
        const slots = try allocator.alloc(Slot, node_capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const commands = try allocator.alloc(scene.Command, scene_capacity);
        self.* = .{
            .allocator = allocator,
            .tree = tree,
            .slots = slots,
            .commands = commands,
        };
    }

    pub fn deinit(self: *Surface) void {
        self.allocator.free(self.commands);
        self.allocator.free(self.slots);
        self.tree.deinit();
        self.* = undefined;
    }

    /// Text caches are optional, caller-owned, and must outlive the surface.
    pub fn attachTextCaches(
        self: *Surface,
        sources: *text.ParagraphSourceCache,
        paragraphs: *text.ParagraphCache,
    ) void {
        self.tree.attachTextCaches(sources, paragraphs);
    }

    /// Reconciles one complete native snapshot. Validation and capacity checks
    /// complete before the retained tree is changed. Existing IDs keep their
    /// render-object handles, including across reordering and reparenting.
    pub fn reconcile(self: *Surface, descriptors: []const Descriptor) !void {
        try self.validateSnapshot(descriptors);

        var topology_changed = false;
        for (self.slots) |slot| if (slot.active and descriptorIndex(descriptors, slot.id) == null) {
            topology_changed = true;
            break;
        };
        if (!topology_changed) for (descriptors, 0..) |descriptor, order| {
            const slot = self.slotForId(descriptor.id) orelse {
                topology_changed = true;
                break;
            };
            const object = try self.tree.objectAt(slot.render);
            if (!optionalIdEqual(slot.parent, descriptor.parent) or slot.order != order or
                std.meta.activeTag(object) != std.meta.activeTag(descriptor.object) or
                (descriptor.parent != null and
                    !std.meta.eql(try self.tree.parentData(slot.render), descriptor.parent_data)))
            {
                topology_changed = true;
                break;
            }
        };

        if (topology_changed) for (self.slots) |slot| if (slot.active and slot.parent != null)
            try self.tree.detachChild(slot.render);

        var index = self.slots.len;
        while (index > 0) {
            index -= 1;
            const slot = &self.slots[index];
            if (!slot.active or descriptorIndex(descriptors, slot.id) != null) continue;
            try self.tree.destroy(slot.render);
            slot.* = .{};
        }

        for (descriptors, 0..) |descriptor, order| {
            const slot = self.slotForId(descriptor.id) orelse blk: {
                const free = self.freeSlot() orelse return error.SurfaceCapacityExceeded;
                const render = try self.tree.create(descriptor.object);
                free.* = .{
                    .active = true,
                    .id = descriptor.id,
                    .parent = descriptor.parent,
                    .order = order,
                    .render = render,
                };
                break :blk free;
            };
            try self.tree.update(slot.render, descriptor.object);
            slot.parent = descriptor.parent;
            slot.order = order;
        }

        self.root = null;
        for (descriptors) |descriptor| {
            const slot = self.slotForId(descriptor.id).?;
            if (descriptor.parent) |parent_id| {
                if (topology_changed) try self.tree.appendChild(
                    self.slotForId(parent_id).?.render,
                    slot.render,
                    descriptor.parent_data,
                );
            } else {
                self.root = slot.render;
            }
        }
        if (self.hovered) |id| {
            if (self.slotForId(id) == null) self.hovered = null;
        }
        if (self.captured) |id| {
            if (self.slotForId(id) == null) self.captured = null;
        }
        self.command_count = 0;
    }

    pub fn layout(self: *Surface, logical_size: SizeF) !SizeF {
        const root = self.root orelse return error.SurfaceHasNoRoot;
        return self.tree.layout(root, Constraints.tight(logical_size));
    }

    /// Rebuilds and returns a borrowed display list valid until the next
    /// reconciliation or scene build. Output scale affects scene lowering, not
    /// logical layout or hit-test coordinates.
    pub fn buildDisplayList(self: *Surface, scale: f32) !scene.DisplayList {
        const root = self.root orelse return error.SurfaceHasNoRoot;
        var builder = try render_object.Builder.init(self.commands, scale);
        try self.tree.buildScene(root, &builder);
        const list = builder.displayList();
        self.command_count = list.commands.len;
        return list;
    }

    pub fn displayList(self: *const Surface) scene.DisplayList {
        return .{ .commands = self.commands[0..self.command_count] };
    }

    pub fn hitTest(self: *Surface, point: PointF) !?u64 {
        const root = self.root orelse return null;
        const render = (try self.tree.hitTest(root, point)) orelse return null;
        for (self.slots) |slot| if (slot.active and same(slot.render, render)) return slot.id;
        return error.UnownedRenderObject;
    }

    pub fn pointerMotion(self: *Surface, point: PointF) !PointerResult {
        self.hovered = try self.hitTest(point);
        return .{ .target = self.captured orelse self.hovered, .hovered = self.hovered };
    }

    /// Press captures the currently hit node until release, matching Ourokit's
    /// application pointer router without requiring platform event types.
    pub fn pointerPress(self: *Surface, point: PointF) !PointerResult {
        self.hovered = try self.hitTest(point);
        self.captured = self.hovered;
        return .{ .target = self.captured, .hovered = self.hovered };
    }

    pub fn pointerRelease(self: *Surface, point: PointF) !PointerResult {
        self.hovered = try self.hitTest(point);
        const result: PointerResult = .{
            .target = self.captured orelse self.hovered,
            .hovered = self.hovered,
        };
        self.captured = null;
        return result;
    }

    fn validateSnapshot(self: *Surface, descriptors: []const Descriptor) !void {
        if (descriptors.len > self.slots.len) return error.SurfaceCapacityExceeded;
        var roots: usize = 0;
        for (descriptors, 0..) |descriptor, index| {
            if (descriptor.id == 0) return error.InvalidSurfaceNodeId;
            try render_object.Tree.validate(descriptor.object);
            if (descriptorIndex(descriptors[0..index], descriptor.id) != null)
                return error.DuplicateSurfaceNodeId;
            if (descriptor.parent) |parent_id| {
                const parent_index = descriptorIndex(descriptors[0..index], parent_id) orelse
                    return error.ParentMustPrecedeChild;
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

    fn slotForId(self: *Surface, id: u64) ?*Slot {
        for (self.slots) |*slot| if (slot.active and slot.id == id) return slot;
        return null;
    }

    fn freeSlot(self: *Surface) ?*Slot {
        for (self.slots) |*slot| if (!slot.active) return slot;
        return null;
    }
};

fn descriptorIndex(descriptors: []const Descriptor, id: u64) ?usize {
    for (descriptors, 0..) |descriptor, index| if (descriptor.id == id) return index;
    return null;
}

fn same(a: render_object.NodeHandle, b: render_object.NodeHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn optionalIdEqual(a: ?u64, b: ?u64) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}
