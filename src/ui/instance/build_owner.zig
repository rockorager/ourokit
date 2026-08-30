const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;
const Scheduler = @import("../../task/scheduler.zig").Scheduler;
const ScopeHandle = @import("../../task/scheduler.zig").ScopeHandle;
const ReconcileQueue = @import("reconcile_queue.zig").ReconcileQueue;
const ReconcileWork = @import("reconcile_queue.zig").Work;

pub const BuildOwnerHandle = Handle;

pub const BuildWork = struct {
    owner: BuildOwnerHandle,
    revision: u64,
};

/// State-only notification that the registry has dirty component work. The
/// sink may queue an owning window, but must not build or enter a language VM.
pub const DirtySink = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque) anyerror!void,
};

const State = enum { free, active, retiring };

const Slot = struct {
    generation: u32 = 0,
    state: State = .free,
    key: u64 = 0,
    parent: ?BuildOwnerHandle = null,
    scope: ScopeHandle = .invalid,
    building_revision: u64 = 0,
    built_revision: u64 = 0,
    retire_mark: bool = false,
};

/// Mounted language-neutral component lifecycle. A build owner may produce a
/// normalized descriptor subtree but is not itself a render object. Dirty work
/// is direct and bounded; no retained-tree scan is required to find it. The
/// registry must retain a stable address while a language bridge can reference
/// one of its generation-checked owners.
pub const BuildOwners = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    root_scope: ScopeHandle,
    slots: []Slot,
    dirty: ReconcileQueue,
    max_build_passes: usize,
    dirty_sink: ?DirtySink = null,

    pub fn init(
        self: *BuildOwners,
        allocator: std.mem.Allocator,
        scheduler: *Scheduler,
        root_scope: ScopeHandle,
        capacity: usize,
        max_build_passes: usize,
    ) !void {
        if (capacity == 0 or max_build_passes == 0 or
            !(try scheduler.scopeAcceptsResources(root_scope))) return error.InvalidBuildOwnerConfig;
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        var dirty: ReconcileQueue = undefined;
        try dirty.init(allocator, capacity);
        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .root_scope = root_scope,
            .slots = slots,
            .dirty = dirty,
            .max_build_passes = max_build_passes,
        };
    }

    pub fn deinit(self: *BuildOwners) void {
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        self.dirty.deinit();
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Mounts one keyed component and queues its initial build. Keys are unique
    /// among siblings; component identity remains separate from render-object
    /// and signal identity.
    pub fn mount(
        self: *BuildOwners,
        parent: ?BuildOwnerHandle,
        key: u64,
    ) !BuildOwnerHandle {
        if (key == 0) return error.InvalidBuildOwnerKey;
        const parent_scope = if (parent) |handle|
            (try self.activeSlot(handle)).scope
        else
            self.root_scope;
        for (self.slots) |slot| if (slot.state == .active and
            optionalHandleEqual(slot.parent, parent) and slot.key == key)
        {
            return error.DuplicateBuildOwnerKey;
        };
        var free_index: ?usize = null;
        for (self.slots, 0..) |slot, index| if (slot.state == .free) {
            free_index = index;
            break;
        };
        const index = free_index orelse return error.BuildOwnerCapacityExceeded;
        const scope_handle = try self.scheduler.createScope(parent_scope);
        errdefer self.scheduler.destroyScope(scope_handle) catch unreachable;

        const slot = &self.slots[index];
        var generation = slot.generation +% 1;
        if (generation == 0) generation = 1;
        slot.* = .{
            .generation = generation,
            .state = .active,
            .key = key,
            .parent = parent,
            .scope = scope_handle,
        };
        const handle: BuildOwnerHandle = .{ .slot = @intCast(index), .generation = generation };
        self.dirty.register(handle) catch |err| {
            slot.* = .{ .generation = generation };
            return err;
        };
        errdefer self.dirty.unregister(handle) catch unreachable;
        _ = try self.dirty.markDirty(handle);
        return handle;
    }

    pub fn markDirty(self: *BuildOwners, owner: BuildOwnerHandle) !u64 {
        _ = try self.activeSlot(owner);
        const revision = try self.dirty.markDirty(owner);
        if (self.dirty_sink) |sink| try sink.notify(sink.context);
        return revision;
    }

    pub fn setDirtySink(self: *BuildOwners, sink: DirtySink) void {
        self.dirty_sink = sink;
    }

    pub fn beginCycle(self: *BuildOwners) BuildCycle {
        const pending = self.dirty.pendingCount();
        return .{
            .owners = self,
            .pass_count = @intFromBool(pending != 0),
            .remaining_in_pass = pending,
        };
    }

    /// Commits only the build revision. Call this after normalized descriptors
    /// have passed transactional reconciliation into the owner's retained
    /// subtree; failed descriptor production should call `retry` instead.
    pub fn complete(self: *BuildOwners, work: BuildWork) !void {
        const slot = try self.activeSlot(work.owner);
        if (slot.building_revision != work.revision) return error.StaleBuildWork;
        try self.dirty.complete(.{ .owner = work.owner, .revision = work.revision });
        slot.built_revision = work.revision;
        slot.building_revision = 0;
    }

    pub fn retry(self: *BuildOwners, work: BuildWork) !void {
        const slot = try self.activeSlot(work.owner);
        if (slot.building_revision != work.revision) return error.StaleBuildWork;
        try self.dirty.retry(.{ .owner = work.owner, .revision = work.revision });
        slot.building_revision = 0;
    }

    /// Recursively retires a component subtree. Pending build work disappears
    /// immediately, while scope cancellation executes at the task safe point.
    pub fn retire(self: *BuildOwners, owner: BuildOwnerHandle) !void {
        _ = try self.activeSlot(owner);
        for (self.slots, 0..) |slot, index| {
            if (slot.state != .active) continue;
            const candidate = handleFor(slot, index);
            if (self.isWithin(candidate, owner) and slot.building_revision != 0)
                return error.BuildInProgress;
        }
        for (self.slots, 0..) |*slot, index| {
            if (slot.state != .active) continue;
            slot.retire_mark = self.isWithin(handleFor(slot.*, index), owner);
        }
        try self.scheduler.queueScopeCancellation((try self.activeSlot(owner)).scope);
        for (self.slots, 0..) |*slot, index| {
            if (!slot.retire_mark) continue;
            try self.dirty.unregister(handleFor(slot.*, index));
            slot.state = .retiring;
            slot.retire_mark = false;
        }
    }

    pub fn collectRetired(self: *BuildOwners) !void {
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

    pub fn scope(self: *BuildOwners, owner: BuildOwnerHandle) !ScopeHandle {
        return (try self.activeSlot(owner)).scope;
    }

    pub fn builtRevision(self: *BuildOwners, owner: BuildOwnerHandle) !u64 {
        return (try self.activeSlot(owner)).built_revision;
    }

    pub fn isActive(self: *BuildOwners, owner: BuildOwnerHandle) bool {
        _ = self.activeSlot(owner) catch return false;
        return true;
    }

    fn activeSlot(self: *BuildOwners, owner: BuildOwnerHandle) !*Slot {
        if (owner.slot >= self.slots.len) return error.StaleBuildOwner;
        const slot = &self.slots[owner.slot];
        if (slot.state != .active or slot.generation != owner.generation)
            return error.StaleBuildOwner;
        return slot;
    }

    fn isWithin(
        self: *BuildOwners,
        candidate: BuildOwnerHandle,
        root: BuildOwnerHandle,
    ) bool {
        var current = candidate;
        while (true) {
            if (same(current, root)) return true;
            const slot = self.activeSlot(current) catch return false;
            current = slot.parent orelse return false;
        }
    }
};

/// One bounded stabilization cycle. Marks raised by a build are queued behind
/// already-dirty owners. A cycle fails rather than spinning indefinitely.
pub const BuildCycle = struct {
    owners: *BuildOwners,
    pass_count: usize,
    remaining_in_pass: usize,

    pub fn take(self: *BuildCycle) !?BuildWork {
        if (self.remaining_in_pass == 0) {
            const pending = self.owners.dirty.pendingCount();
            if (pending == 0) return null;
            if (self.pass_count == self.owners.max_build_passes)
                return error.BuildDidNotStabilize;
            self.pass_count += 1;
            self.remaining_in_pass = pending;
        }
        const work: ReconcileWork = self.owners.dirty.take().?;
        const slot = try self.owners.activeSlot(work.owner);
        std.debug.assert(slot.building_revision == 0);
        slot.building_revision = work.revision;
        self.remaining_in_pass -= 1;
        return .{ .owner = work.owner, .revision = work.revision };
    }
};

fn handleFor(slot: Slot, index: usize) BuildOwnerHandle {
    return .{ .slot = @intCast(index), .generation = slot.generation };
}

fn optionalHandleEqual(a: ?BuildOwnerHandle, b: ?BuildOwnerHandle) bool {
    if (a == null or b == null) return a == null and b == null;
    return same(a.?, b.?);
}

fn same(a: BuildOwnerHandle, b: BuildOwnerHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "only directly dirty mounted components rebuild" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 3, 8);
    defer owners.deinit();

    const root = try owners.mount(null, 1);
    const first = try owners.mount(root, 2);
    const second = try owners.mount(root, 3);
    var initial = owners.beginCycle();
    var initial_count: usize = 0;
    while (try initial.take()) |work| {
        initial_count += 1;
        try owners.complete(work);
    }
    try std.testing.expectEqual(@as(usize, 3), initial_count);

    _ = try owners.markDirty(first);
    _ = try owners.markDirty(first);
    var update = owners.beginCycle();
    const work = (try update.take()).?;
    try std.testing.expectEqual(first, work.owner);
    try owners.complete(work);
    try std.testing.expect((try update.take()) == null);
    try std.testing.expectEqual(@as(u64, 3), try owners.builtRevision(first));
    try std.testing.expectEqual(@as(u64, 1), try owners.builtRevision(second));

    try owners.retire(root);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "builds marked during build retry and stabilization is bounded" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 2);
    defer owners.deinit();
    const root = try owners.mount(null, 1);

    var cycle = owners.beginCycle();
    const first = (try cycle.take()).?;
    _ = try owners.markDirty(root);
    try owners.complete(first);
    const second = (try cycle.take()).?;
    _ = try owners.markDirty(root);
    try owners.complete(second);
    try std.testing.expectError(error.BuildDidNotStabilize, cycle.take());

    var next = owners.beginCycle();
    try owners.complete((try next.take()).?);
    try owners.retire(root);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "build revision commits only after transactional descriptor reconciliation" {
    const InstanceTree = @import("tree.zig").Tree;
    const Descriptor = @import("tree.zig").Descriptor;
    const RenderTree = @import("../render_object/root.zig").Tree;

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 7, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 2);
    defer renders.deinit();
    var instances: InstanceTree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 2);
    defer instances.deinit();
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const root = try owners.mount(null, 1);

    var initial = owners.beginCycle();
    const first_build = (try initial.take()).?;
    try instances.reconcile(&.{.{
        .id = 10,
        .parent = null,
        .object = .{ .box = .{ .width = 20, .height = 10 } },
    }});
    try owners.complete(first_build);
    const original = instances.handleForId(10).?;

    _ = try owners.markDirty(root);
    var invalid = owners.beginCycle();
    const failed_build = (try invalid.take()).?;
    const malformed = [_]Descriptor{
        .{ .id = 11, .parent = null, .object = .{ .box = .{} } },
        .{ .id = 11, .parent = null, .object = .{ .box = .{} } },
    };
    try std.testing.expectError(error.DuplicateInstanceId, instances.reconcile(&malformed));
    try owners.retry(failed_build);
    try std.testing.expectEqual(original, instances.handleForId(10).?);
    try std.testing.expectEqual(@as(u64, 1), try owners.builtRevision(root));

    var retry_cycle = owners.beginCycle();
    const retried = (try retry_cycle.take()).?;
    try instances.reconcile(&.{.{
        .id = 10,
        .parent = null,
        .object = .{ .box = .{ .width = 30, .height = 10 } },
    }});
    try owners.complete(retried);
    try std.testing.expectEqual(@as(u64, 2), try owners.builtRevision(root));

    try instances.reconcile(&.{});
    try owners.retire(root);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "retirement removes pending descendant builds and drains scopes later" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 2, 4);
    defer owners.deinit();
    const root = try owners.mount(null, 1);
    const child = try owners.mount(root, 2);
    const child_scope = try owners.scope(child);

    try owners.retire(root);
    try std.testing.expect(!owners.isActive(root));
    try std.testing.expect(!owners.isActive(child));
    var cycle = owners.beginCycle();
    try std.testing.expect((try cycle.take()) == null);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try std.testing.expectError(error.StaleScope, scheduler.destroyScope(child_scope));
    try scheduler.destroyScope(window_scope);
}
