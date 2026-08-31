const std = @import("std");
const instance = @import("../instance/tree.zig");

pub const Direction = enum { forward, backward };

/// Window-local focus policy. Instances own focusability and traversal order;
/// the manager retains only the current generation-checked identity.
pub const Manager = struct {
    focused: ?instance.InstanceHandle = null,

    pub fn reconcile(self: *Manager, tree: *instance.Tree) void {
        if (self.focused) |focused| {
            if (!tree.isFocusable(focused)) self.focused = null;
        }
    }

    pub fn clear(self: *Manager) void {
        self.focused = null;
    }

    pub fn request(self: *Manager, tree: *instance.Tree, target: instance.InstanceHandle) !bool {
        if (!tree.isFocusable(target)) return false;
        if (sameOptional(self.focused, target)) return false;
        self.focused = target;
        return true;
    }

    pub fn advance(self: *Manager, tree: *instance.Tree, direction: Direction) !bool {
        const next = try tree.nextFocusable(self.focused, direction == .backward) orelse {
            self.focused = null;
            return false;
        };
        if (sameOptional(self.focused, next)) return false;
        self.focused = next;
        return true;
    }

    pub fn current(self: *const Manager) ?instance.InstanceHandle {
        return self.focused;
    }
};

fn sameOptional(a: ?instance.InstanceHandle, b: instance.InstanceHandle) bool {
    const value = a orelse return false;
    return value.slot == b.slot and value.generation == b.generation;
}

test "focus follows retained traversal order and skips disabled instances" {
    const Scheduler = @import("../../task/scheduler.zig").Scheduler;
    const render_object = @import("../render_object/root.zig");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 4);
    defer renders.deinit();
    var tree: instance.Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, scope, 4);
    defer tree.deinit();
    try tree.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 3, .parent = 1, .object = .{ .box = .{} } },
        .{ .id = 4, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
    });
    var focus: Manager = .{};
    try std.testing.expect(try focus.advance(&tree, .forward));
    try std.testing.expectEqual(tree.handleForId(2).?, focus.current().?);
    try std.testing.expect(try focus.advance(&tree, .forward));
    try std.testing.expectEqual(tree.handleForId(4).?, focus.current().?);
    try std.testing.expect(try focus.advance(&tree, .forward));
    try std.testing.expectEqual(tree.handleForId(2).?, focus.current().?);
    try std.testing.expect(try focus.advance(&tree, .backward));
    try std.testing.expectEqual(tree.handleForId(4).?, focus.current().?);

    try tree.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 4, .parent = 1, .object = .{ .box = .{} } },
    });
    focus.reconcile(&tree);
    try std.testing.expect(focus.current() == null);

    try tree.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try scheduler.destroyScope(scope);
}
