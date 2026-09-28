//! Process-owned session resources. No Lua or protocol pointers cross this boundary.
const std = @import("std");
pub const Handle = @import("../core/handle.zig").Handle;
pub const capacity = 32;
pub const Kind = enum { idle, power, lock, outputs };
pub const Event = enum { idled, resumed, on, off, locked, finished, unlocked, failed, closed, outputs };
pub const LockState = enum { unlocked, requested, pending, locked, unlocking, abandoned };

pub const Resource = struct {
    generation: u32 = 1,
    used: bool = false,
    enabled: bool = true,
    kind: Kind = .idle,
    timeout_ms: u32 = 0,
    input_only: bool = false,
    output: [256]u8 = undefined,
    output_len: usize = 0,
    started: bool = false,
    close_requested: bool = false,
    detached: bool = false,
    terminal: bool = false,
    desired_power: ?bool = null,
    output_revision: u64 = 0,
    events: [16]Event = undefined,
    count: usize = 0,

    pub fn push(self: *Resource, event: Event) void {
        if (self.terminal) return;
        if (self.count == self.events.len) {
            // Consumers must never mistake a lossy stream for an acknowledgement.
            self.count = 0;
            self.events[0] = .failed;
            self.count = 1;
            self.terminal = true;
            return;
        }
        self.events[self.count] = event;
        self.count += 1;
        self.terminal = switch (event) {
            .finished, .unlocked, .failed, .closed => true,
            else => false,
        };
    }

    pub fn take(self: *Resource) ?Event {
        if (self.count == 0) return null;
        const event = self.events[0];
        self.count -= 1;
        std.mem.copyForwards(Event, self.events[0..self.count], self.events[1 .. self.count + 1]);
        return event;
    }
};

pub const Store = struct {
    resources: [capacity]Resource = @splat(.{}),
    lock_state: LockState = .unlocked,
    lock_handle: ?Handle = null,
    idle_version: u32 = 0,
    power_available: bool = false,
    lock_available: bool = false,
    output_names: [32][256]u8 = undefined,
    output_lengths: [32]u16 = @splat(0),
    output_count: usize = 0,
    output_revision: u64 = 0,
    outputs_ready: bool = false,

    pub fn updateOutputs(self: *Store, names: []const []const u8) !void {
        if (names.len > self.output_names.len) return error.OutputCapacityExceeded;
        var changed = self.output_revision == 0 or names.len != self.output_count;
        for (names, 0..) |name, i| {
            if (name.len > self.output_names[i].len) return error.OutputNameTooLong;
            if (i >= self.output_count or !std.mem.eql(u8, name, self.output_names[i][0..self.output_lengths[i]])) changed = true;
        }
        self.outputs_ready = true;
        if (!changed) return;
        for (names, 0..) |name, i| {
            @memcpy(self.output_names[i][0..name.len], name);
            self.output_lengths[i] = @intCast(name.len);
        }
        self.output_count = names.len;
        self.output_revision += 1;
    }

    pub fn outputChanged(self: *const Store, resource: *const Resource) bool {
        return self.outputs_ready and resource.kind == .outputs and resource.enabled and !resource.terminal and !resource.close_requested and
            self.output_revision != resource.output_revision;
    }

    pub fn create(self: *Store, kind: Kind) !Handle {
        if (kind == .lock and self.blocksReload()) return error.SessionLockAlreadyActive;
        for (&self.resources, 0..) |*resource, index| if (!resource.used) {
            resource.* = .{ .used = true, .generation = resource.generation, .kind = kind };
            const handle: Handle = .{ .slot = @intCast(index), .generation = resource.generation };
            if (kind == .lock) {
                self.lock_state = .requested;
                self.lock_handle = handle;
            }
            return handle;
        };
        return error.SessionCapacityExceeded;
    }

    pub fn get(self: *Store, handle: Handle) ?*Resource {
        if (handle.slot >= capacity) return null;
        const resource = &self.resources[handle.slot];
        return if (resource.used and resource.generation == handle.generation) resource else null;
    }

    pub fn blocksReload(self: *const Store) bool {
        return self.lock_state != .unlocked;
    }

    pub fn unlock(self: *Store, handle: Handle) !void {
        const resource = self.get(handle) orelse return error.StaleSessionResource;
        if (resource.kind != .lock or self.lock_state != .locked or self.lock_handle == null or
            !std.meta.eql(self.lock_handle.?, handle)) return error.SessionNotLocked;
        self.lock_state = .unlocking;
    }

    pub fn close(self: *Store, handle: Handle, detached: bool) void {
        const resource = self.get(handle) orelse return;
        if (resource.kind == .outputs) {
            self.release(handle.slot); // no protocol object needs asynchronous destruction
            return;
        }
        resource.detached = resource.detached or detached;
        // GC, cancellation and generation shutdown are NEVER permission to unlock.
        if (resource.kind != .lock or resource.terminal or !self.blocksReload()) resource.close_requested = true;
    }

    pub fn release(self: *Store, index: usize) void {
        const resource = &self.resources[index];
        var generation = resource.generation +% 1;
        if (generation == 0) generation = 1;
        resource.* = .{ .generation = generation };
    }
};

test "session lock lifetime is fail closed and stale handles cannot unlock" {
    var store: Store = .{};
    const lock = try store.create(.lock);
    try std.testing.expect(store.blocksReload());
    try std.testing.expectError(error.SessionNotLocked, store.unlock(lock));
    store.lock_state = .locked;
    store.close(lock, true);
    try std.testing.expect(!store.get(lock).?.close_requested);
    try std.testing.expectError(error.SessionLockAlreadyActive, store.create(.lock));
    try store.unlock(lock);
    try std.testing.expect(store.blocksReload());
    store.release(lock.slot);
    try std.testing.expectError(error.StaleSessionResource, store.unlock(lock));
}

test "session streams preserve transitions and explicitly fail on overflow" {
    var resource: Resource = .{};
    resource.push(.idled);
    resource.push(.resumed);
    try std.testing.expectEqual(Event.idled, resource.take().?);
    try std.testing.expectEqual(Event.resumed, resource.take().?);
    for (0..17) |_| resource.push(.idled);
    try std.testing.expectEqual(Event.failed, resource.take().?);
    try std.testing.expect(resource.terminal);
}

test "output snapshots include empty state and coalesce topology and names" {
    var store: Store = .{};
    const handle = try store.create(.outputs);
    const resource = store.get(handle).?;
    try std.testing.expect(!store.outputChanged(resource)); // wait for initial registry discovery
    try store.updateOutputs(&.{});
    try std.testing.expect(store.outputChanged(resource));
    resource.output_revision = store.output_revision;
    try store.updateOutputs(&.{});
    try std.testing.expect(!store.outputChanged(resource));
    try store.updateOutputs(&.{ "DP-1", "HDMI-2" });
    resource.output_revision = store.output_revision;
    try store.updateOutputs(&.{ "DP-1", "HDMI-3" });
    try std.testing.expect(store.outputChanged(resource));
    try store.updateOutputs(&.{"HDMI-3"});
    try std.testing.expectEqual(@as(usize, 1), store.output_count);
    try std.testing.expectEqualStrings("HDMI-3", store.output_names[0][0..store.output_lengths[0]]);
    try store.updateOutputs(&.{});
    try std.testing.expectEqual(@as(usize, 0), store.output_count);
    try std.testing.expectEqual(@as(usize, 0), resource.count); // snapshots do not fill the event queue
    store.close(handle, false);
    try std.testing.expect(!store.outputChanged(resource));
}
