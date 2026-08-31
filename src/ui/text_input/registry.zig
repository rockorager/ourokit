const std = @import("std");
const build_owner = @import("../instance/build_owner.zig");
const instance = @import("../instance/tree.zig");
const Session = @import("session.zig").Session;

const Entry = struct {
    owner: build_owner.BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    content: instance.InstanceHandle = .invalid,
    session: ?Session = null,
    active: bool = false,
    seen: bool = false,
};

/// Retained TextInput state keyed by generation-checked instance identity.
/// Declarative rebuilds rediscover entries but do not replace their editing
/// sessions. Omission or instance retirement deterministically destroys owned
/// text and composition state.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn init(self: *Registry, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidTextInputCapacity;
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        self.* = .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries) |entry| std.debug.assert(!entry.active);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn availableForOwner(self: *const Registry, owner: build_owner.BuildOwnerHandle) usize {
        var count: usize = 0;
        for (self.entries) |entry| if (!entry.active or same(entry.owner, owner)) {
            count += 1;
        };
        return count;
    }

    pub fn beginOwner(self: *Registry, owner: build_owner.BuildOwnerHandle) void {
        for (self.entries) |*entry| {
            if (entry.active and same(entry.owner, owner)) entry.seen = false;
        }
    }

    pub fn mount(
        self: *Registry,
        owner: build_owner.BuildOwnerHandle,
        target: instance.InstanceHandle,
        content_handle: instance.InstanceHandle,
        initial: []const u8,
    ) !void {
        for (self.entries) |*entry| if (entry.active and same(entry.target, target)) {
            entry.owner = owner;
            entry.content = content_handle;
            entry.seen = true;
            return;
        };
        for (self.entries) |*entry| if (!entry.active) {
            entry.* = .{
                .owner = owner,
                .target = target,
                .content = content_handle,
                .session = try Session.init(self.allocator, initial),
                .active = true,
                .seen = true,
            };
            return;
        };
        return error.TextInputCapacityExceeded;
    }

    pub fn finishOwner(self: *Registry, owner: build_owner.BuildOwnerHandle) void {
        for (self.entries) |*entry|
            if (entry.active and same(entry.owner, owner) and !entry.seen) destroy(entry);
    }

    pub fn removeInactive(self: *Registry, tree: *instance.Tree) void {
        for (self.entries) |*entry|
            if (entry.active and !tree.isActive(entry.target)) destroy(entry);
    }

    pub fn clear(self: *Registry) void {
        for (self.entries) |*entry| if (entry.active) destroy(entry);
    }

    pub fn contains(self: *const Registry, target: instance.InstanceHandle) bool {
        return self.find(target) != null;
    }

    pub fn session(self: *Registry, target: instance.InstanceHandle) !*Session {
        return &(self.find(target) orelse return error.TextInputNotFound).session.?;
    }

    pub fn content(self: *const Registry, target: instance.InstanceHandle) !instance.InstanceHandle {
        return (self.find(target) orelse return error.TextInputNotFound).content;
    }

    fn destroy(entry: *Entry) void {
        entry.session.?.deinit();
        entry.* = .{};
    }

    fn find(self: anytype, target: instance.InstanceHandle) ?if (@TypeOf(self) == *Registry) *Entry else *const Entry {
        for (self.entries) |*entry|
            if (entry.active and same(entry.target, target)) return entry;
        return null;
    }
};

fn same(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "retained sessions survive rediscovery and dispose with their owner" {
    var registry: Registry = undefined;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const owner: build_owner.BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const content: instance.InstanceHandle = .{ .slot = 5, .generation = 6 };

    registry.beginOwner(owner);
    try registry.mount(owner, target, content, "initial");
    registry.finishOwner(owner);
    _ = try (try registry.session(target)).model.replaceSelection(" edited");
    registry.beginOwner(owner);
    try registry.mount(owner, target, content, "replacement must not reset state");
    registry.finishOwner(owner);
    try std.testing.expectEqualStrings("initial edited", (try registry.session(target)).model.text());

    registry.beginOwner(owner);
    registry.finishOwner(owner);
    try std.testing.expect(!registry.contains(target));
}
