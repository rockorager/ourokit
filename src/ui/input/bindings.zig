const std = @import("std");
const instance = @import("../instance/tree.zig");
const BuildOwnerHandle = @import("../instance/build_owner.zig").BuildOwnerHandle;

pub const HandlerKind = enum { pointer, button };

pub const Handler = struct {
    id: u32,
    kind: HandlerKind = .pointer,
};

const Entry = struct {
    owner: BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    handler: ?Handler = null,
};

/// Language-neutral, instance-owned semantic input bindings. Targets are
/// generation checked; handler IDs are opaque capabilities owned by a bridge.
pub const PointerBindings = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn init(self: *PointerBindings, allocator: std.mem.Allocator, capacity: usize) !void {
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        self.* = .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *PointerBindings) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn get(self: *const PointerBindings, target: instance.InstanceHandle) ?Handler {
        for (self.entries) |entry| if (same(entry.target, target)) return entry.handler;
        return null;
    }

    pub fn set(
        self: *PointerBindings,
        owner: BuildOwnerHandle,
        target: instance.InstanceHandle,
        handler: Handler,
    ) !?Handler {
        for (self.entries) |*entry| if (same(entry.target, target)) {
            const old = entry.handler;
            entry.owner = owner;
            entry.handler = handler;
            return old;
        };
        for (self.entries) |*entry| if (entry.handler == null) {
            entry.* = .{ .owner = owner, .target = target, .handler = handler };
            return null;
        };
        return error.PointerBindingCapacityExceeded;
    }

    pub fn availableForOwner(self: *const PointerBindings, owner: BuildOwnerHandle) usize {
        var count: usize = 0;
        for (self.entries) |entry|
            if (entry.handler == null or same(entry.owner, owner)) {
                count += 1;
            };
        return count;
    }

    pub fn takeOwner(self: *PointerBindings, owner: BuildOwnerHandle) ?Handler {
        for (self.entries) |*entry| if (entry.handler != null and same(entry.owner, owner)) {
            const old = entry.handler;
            entry.* = .{};
            return old;
        };
        return null;
    }

    pub fn remove(self: *PointerBindings, target: instance.InstanceHandle) ?Handler {
        for (self.entries) |*entry| if (same(entry.target, target)) {
            const old = entry.handler;
            entry.* = .{};
            return old;
        };
        return null;
    }

    pub fn takeInactive(self: *PointerBindings, tree: *instance.Tree) ?Handler {
        for (self.entries) |*entry| if (entry.handler != null and !tree.isActive(entry.target)) {
            const old = entry.handler;
            entry.* = .{};
            return old;
        };
        return null;
    }

    pub fn takeAny(self: *PointerBindings) ?Handler {
        for (self.entries) |*entry| if (entry.handler != null) {
            const old = entry.handler;
            entry.* = .{};
            return old;
        };
        return null;
    }
};

fn same(a: instance.InstanceHandle, b: instance.InstanceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "pointer bindings replace, clean removal, and reject stale generations" {
    const Scheduler = @import("../../task/scheduler.zig").Scheduler;
    const RenderTree = @import("../render_object/root.zig").Tree;

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 1);
    defer renders.deinit();
    var tree: instance.Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, window_scope, 1);
    defer tree.deinit();
    var bindings: PointerBindings = undefined;
    try bindings.init(std.testing.allocator, 1);
    defer bindings.deinit();

    try tree.reconcile(&.{.{ .id = 1, .parent = null, .object = .{ .box = .{} } }});
    const original = tree.handleForId(1).?;
    const owner: BuildOwnerHandle = .{ .slot = 0, .generation = 1 };
    try std.testing.expect((try bindings.set(owner, original, .{ .id = 10 })) == null);
    try std.testing.expectEqual(@as(?Handler, .{ .id = 10 }), bindings.get(original));
    try std.testing.expectEqual(
        @as(?Handler, .{ .id = 10 }),
        try bindings.set(owner, original, .{ .id = 11, .kind = .button }),
    );

    try tree.reconcile(&.{});
    try std.testing.expectEqual(
        @as(?Handler, .{ .id = 11, .kind = .button }),
        bindings.takeInactive(&tree),
    );
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try tree.reconcile(&.{.{ .id = 1, .parent = null, .object = .{ .box = .{} } }});
    const replacement = tree.handleForId(1).?;
    try std.testing.expect(replacement.generation != original.generation);
    try std.testing.expect(bindings.get(original) == null);

    try tree.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try scheduler.destroyScope(window_scope);
}
