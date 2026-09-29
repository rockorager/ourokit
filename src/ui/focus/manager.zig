const std = @import("std");
const instance = @import("../instance/tree.zig");

pub const Direction = enum { forward, backward };

/// Window-local focus policy. Instances own focusability and traversal order;
/// the manager retains only the current generation-checked identity.
pub const Manager = struct {
    focused: ?instance.InstanceHandle = null,
    boundary: ?instance.InstanceHandle = null,
    restore_target: ?instance.InstanceHandle = null,
    revision: u64 = 0,

    pub fn reconcile(self: *Manager, tree: *instance.Tree) void {
        const focused_before = self.focused;
        const boundary_before = self.boundary;
        defer if (!sameOptionalOptional(focused_before, self.focused) or
            !sameOptionalOptional(boundary_before, self.boundary))
        {
            self.revision +%= 1;
        };
        if (self.boundary) |boundary| {
            if (!tree.isInteractive(boundary)) {
                self.boundary = null;
                self.focused = if (self.restore_target) |target|
                    if (tree.isFocusable(target)) target else null
                else
                    null;
                self.restore_target = null;
                return;
            }
        }
        if (self.focused) |focused| {
            if (!tree.isFocusable(focused) or !self.isPermitted(tree, focused)) {
                self.focused = if (self.boundary != null) self.nextPermitted(tree, null, .forward) catch null else null;
            }
        } else if (self.boundary != null) {
            self.focused = self.nextPermitted(tree, null, .forward) catch null;
        }
    }

    pub fn clear(self: *Manager) void {
        if (self.focused != null) self.revision +%= 1;
        self.focused = null;
    }

    pub fn request(self: *Manager, tree: *instance.Tree, target: instance.InstanceHandle) !bool {
        if (!tree.isFocusable(target) or !self.isPermitted(tree, target)) return false;
        if (sameOptional(self.focused, target)) return false;
        self.focused = target;
        self.revision +%= 1;
        return true;
    }

    pub fn advance(self: *Manager, tree: *instance.Tree, direction: Direction) !bool {
        const next = try self.nextPermitted(tree, self.focused, direction) orelse {
            self.clear();
            return false;
        };
        if (sameOptional(self.focused, next)) return false;
        self.focused = next;
        self.revision +%= 1;
        return true;
    }

    pub fn current(self: *const Manager) ?instance.InstanceHandle {
        return self.focused;
    }

    /// Activates or clears the single focus-containment scope.
    pub fn setBoundary(
        self: *Manager,
        tree: *instance.Tree,
        new_boundary: ?instance.InstanceHandle,
    ) !bool {
        if (sameOptionalOptional(self.boundary, new_boundary)) return false;
        if (new_boundary) |boundary| if (!tree.isInteractive(boundary)) return false;

        if (self.boundary == null and new_boundary != null)
            self.restore_target = self.focused;
        self.boundary = new_boundary;
        self.revision +%= 1;

        if (new_boundary == null) {
            self.focused = if (self.restore_target) |target|
                if (tree.isFocusable(target)) target else null
            else
                null;
            self.restore_target = null;
        } else {
            self.focused = try self.nextPermitted(tree, null, .forward);
        }
        return true;
    }

    fn isPermitted(self: *const Manager, tree: *instance.Tree, target: instance.InstanceHandle) bool {
        const boundary = self.boundary orelse return true;
        var cursor: ?instance.InstanceHandle = target;
        while (cursor) |handle| {
            if (same(handle, boundary)) return true;
            cursor = tree.parentOf(handle) catch return false;
        }
        return false;
    }

    fn nextPermitted(
        self: *const Manager,
        tree: *instance.Tree,
        start: ?instance.InstanceHandle,
        direction: Direction,
    ) !?instance.InstanceHandle {
        if (self.boundary == null)
            return tree.nextFocusable(start, direction == .backward);

        var cursor = start;
        var first_seen: ?instance.InstanceHandle = null;
        while (try tree.nextFocusable(cursor, direction == .backward)) |candidate| {
            if (sameOptional(first_seen, candidate)) return null;
            if (first_seen == null) first_seen = candidate;
            if (self.isPermitted(tree, candidate)) return candidate;
            cursor = candidate;
        }
        return null;
    }
};

fn sameOptional(a: ?instance.InstanceHandle, b: instance.InstanceHandle) bool {
    const value = a orelse return false;
    return same(value, b);
}

fn sameOptionalOptional(a: ?instance.InstanceHandle, b: ?instance.InstanceHandle) bool {
    const right = b orelse return a == null;
    return sameOptional(a, right);
}

fn same(a: instance.InstanceHandle, b: instance.InstanceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
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

test "boundary contains traversal and restores pre-modal focus" {
    const Scheduler = @import("../../task/scheduler.zig").Scheduler;
    const render_object = @import("../render_object/root.zig");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 16, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 10);
    defer renders.deinit();
    var tree: instance.Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, scope, 10);
    defer tree.deinit();
    try tree.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 3, .parent = 1, .object = .{ .stack = .{} } },
        .{ .id = 4, .parent = 3, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 6, .parent = 3, .object = .{ .stack = .{} } },
        .{ .id = 5, .parent = 6, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 7, .parent = 1, .object = .{ .stack = .{} } },
        .{ .id = 8, .parent = 7, .object = .{ .box = .{} } },
        .{ .id = 9, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
    });

    var focus: Manager = .{};
    try std.testing.expect(try focus.request(&tree, tree.handleForId(2).?));
    try std.testing.expect(try focus.setBoundary(&tree, tree.handleForId(3)));
    try std.testing.expectEqual(tree.handleForId(4).?, focus.current().?);
    try std.testing.expect(!(try focus.request(&tree, tree.handleForId(9).?)));
    try std.testing.expect(try focus.advance(&tree, .backward));
    try std.testing.expectEqual(tree.handleForId(5).?, focus.current().?);
    try std.testing.expect(try focus.advance(&tree, .forward));
    try std.testing.expectEqual(tree.handleForId(4).?, focus.current().?);

    // Changing the active scope does not replace the original restore target.
    try std.testing.expect(try focus.setBoundary(&tree, tree.handleForId(7)));
    try std.testing.expect(focus.current() == null);
    try std.testing.expect(!(try focus.advance(&tree, .forward)));
    try std.testing.expect(!(try focus.advance(&tree, .backward)));
    try std.testing.expect(try focus.setBoundary(&tree, null));
    try std.testing.expectEqual(tree.handleForId(2).?, focus.current().?);

    // A removed focused target is reconciled within the boundary.
    try std.testing.expect(try focus.setBoundary(&tree, tree.handleForId(3)));
    try tree.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 3, .parent = 1, .object = .{ .stack = .{} } },
        .{ .id = 6, .parent = 3, .object = .{ .stack = .{} } },
        .{ .id = 5, .parent = 6, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 9, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
    });
    focus.reconcile(&tree);
    try std.testing.expectEqual(tree.handleForId(5).?, focus.current().?);

    // Removing both the boundary and saved target safely leaves no focus.
    try tree.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 9, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
    });
    focus.reconcile(&tree);
    try std.testing.expect(focus.current() == null);

    try tree.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try scheduler.destroyScope(scope);
}
