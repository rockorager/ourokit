const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;
const instance = @import("../instance/tree.zig");
const BuildOwnerHandle = @import("../instance/build_owner.zig").BuildOwnerHandle;

pub const HandlerKind = enum {
    pointer,
    button,
    @"switch",
    text_input_change,
    text_input_command,
    listbox,
    interaction_change,
    cancel,

    fn primary(self: HandlerKind) bool {
        return self == .pointer or self == .button or self == .@"switch" or self == .listbox;
    }
};

pub const Handler = struct {
    id: Handle,
    kind: HandlerKind = .pointer,
};

const Entry = struct {
    owner: BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    handler: ?Handler = null,
};

const InteractionState = struct {
    target: instance.InstanceHandle = .invalid,
    active: bool = false,
};

/// Language-neutral, instance-owned semantic input bindings. Targets are
/// generation checked; handler IDs are opaque capabilities owned by a bridge.
pub const PointerBindings = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    interactions: []InteractionState,

    pub fn init(self: *PointerBindings, allocator: std.mem.Allocator, capacity: usize) !void {
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        const interactions = try allocator.alloc(InteractionState, capacity);
        @memset(entries, .{});
        @memset(interactions, .{});
        self.* = .{ .allocator = allocator, .entries = entries, .interactions = interactions };
    }

    pub fn deinit(self: *PointerBindings) void {
        self.allocator.free(self.interactions);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn get(self: *const PointerBindings, target: instance.InstanceHandle) ?Handler {
        for (self.entries) |entry| if (same(entry.target, target) and entry.handler != null and
            entry.handler.?.kind.primary())
            return entry.handler;
        return null;
    }

    /// State survives callback replacement, but never instance removal or reuse.
    pub fn interactionChanged(self: *PointerBindings, tree: *instance.Tree, target: instance.InstanceHandle, active: bool) bool {
        var empty: ?*InteractionState = null;
        for (self.interactions) |*state| {
            if (!tree.isActive(state.target) or self.getKind(state.target, .interaction_change) == null)
                state.* = .{};
            if (same(state.target, target)) {
                const changed = state.active != active;
                state.active = active;
                return changed;
            }
            if (same(state.target, .invalid)) empty = state;
        }
        // There cannot be more interaction targets than bindings.
        empty.?.* = .{ .target = target, .active = active };
        // Publish the initial state too: a retained Lua component can replace
        // its observed native instance while keeping its previous signal.
        return true;
    }

    pub fn getKind(self: *const PointerBindings, target: instance.InstanceHandle, kind: HandlerKind) ?Handler {
        for (self.entries) |entry| if (same(entry.target, target) and entry.handler != null and
            entry.handler.?.kind == kind) return entry.handler;
        return null;
    }

    pub fn set(
        self: *PointerBindings,
        owner: BuildOwnerHandle,
        target: instance.InstanceHandle,
        handler: Handler,
    ) !?Handler {
        for (self.entries) |*entry| if (same(entry.target, target) and entry.handler != null and
            sameBindingKind(entry.handler.?.kind, handler.kind))
        {
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

    pub fn availableAfterReconcile(
        self: *const PointerBindings,
        tree: *instance.Tree,
        owner: BuildOwnerHandle,
    ) usize {
        var count: usize = 0;
        for (self.entries) |entry|
            if (entry.handler == null or same(entry.owner, owner) or
                !tree.isActive(entry.target))
            {
                count += 1;
            };
        return count;
    }

    pub fn reclaimableForOwner(
        self: *const PointerBindings,
        tree: *instance.Tree,
        owner: BuildOwnerHandle,
    ) usize {
        var count: usize = 0;
        for (self.entries) |entry|
            if (entry.handler != null and
                (same(entry.owner, owner) or !tree.isActive(entry.target)))
            {
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

fn sameBindingKind(a: HandlerKind, b: HandlerKind) bool {
    return a == b or (a.primary() and b.primary());
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
    try bindings.init(std.testing.allocator, 2);
    defer bindings.deinit();

    try tree.reconcile(&.{.{ .id = 1, .parent = null, .object = .{ .box = .{} } }});
    const original = tree.handleForId(1).?;
    const owner: BuildOwnerHandle = .{ .slot = 0, .generation = 1 };
    const first: Handle = .{ .slot = 10, .generation = 1 };
    const second: Handle = .{ .slot = 11, .generation = 2 };
    try std.testing.expect((try bindings.set(owner, original, .{ .id = first })) == null);
    try std.testing.expectEqual(@as(?Handler, .{ .id = first }), bindings.get(original));
    try std.testing.expectEqual(
        @as(?Handler, .{ .id = first }),
        try bindings.set(owner, original, .{ .id = second, .kind = .button }),
    );

    try tree.reconcile(&.{});
    try std.testing.expectEqual(
        @as(?Handler, .{ .id = second, .kind = .button }),
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

test "text input callback kinds coexist and retire independently" {
    var bindings: PointerBindings = undefined;
    try bindings.init(std.testing.allocator, 2);
    defer bindings.deinit();
    const owner: BuildOwnerHandle = .{ .slot = 2, .generation = 3 };
    const target: instance.InstanceHandle = .{ .slot = 4, .generation = 5 };
    const change: Handler = .{ .id = .{ .slot = 6, .generation = 7 }, .kind = .text_input_change };
    const command: Handler = .{ .id = .{ .slot = 8, .generation = 9 }, .kind = .text_input_command };

    try std.testing.expect((try bindings.set(owner, target, change)) == null);
    try std.testing.expect((try bindings.set(owner, target, command)) == null);
    try std.testing.expectEqual(change, bindings.getKind(target, .text_input_change).?);
    try std.testing.expectEqual(command, bindings.getKind(target, .text_input_command).?);
    try std.testing.expect(bindings.get(target) == null);
    try std.testing.expect(bindings.takeOwner(owner) != null);
    try std.testing.expect(bindings.takeOwner(owner) != null);
    try std.testing.expect(bindings.takeOwner(owner) == null);
}
