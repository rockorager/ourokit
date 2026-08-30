const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;

pub const OwnerHandle = Handle;

pub const Work = struct {
    owner: OwnerHandle,
    revision: u64,
};

const Slot = struct {
    registered: bool = false,
    generation: u32 = 0,
    requested_revision: u64 = 0,
    applied_revision: u64 = 0,
    queued: bool = false,
    in_progress_revision: u64 = 0,
};

/// Bounded dirty-owner queue between task state and instance reconciliation.
/// Marking is state-only and allocation-free. Snapshot production belongs to
/// the consumer of `take`, during the reconciliation phase.
pub const ReconcileQueue = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    queue: []OwnerHandle,
    head: usize = 0,
    count: usize = 0,

    pub fn init(self: *ReconcileQueue, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        const queue = try allocator.alloc(OwnerHandle, capacity);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .slots = slots, .queue = queue };
    }

    pub fn deinit(self: *ReconcileQueue) void {
        for (self.slots) |slot| std.debug.assert(slot.in_progress_revision == 0);
        self.allocator.free(self.queue);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn register(self: *ReconcileQueue, owner: OwnerHandle) !void {
        if (owner.slot >= self.slots.len or owner.generation == 0) return error.InvalidOwner;
        const slot = &self.slots[owner.slot];
        if (slot.registered) return error.OwnerAlreadyRegistered;
        slot.* = .{ .registered = true, .generation = owner.generation };
    }

    pub fn unregister(self: *ReconcileQueue, owner: OwnerHandle) !void {
        const slot = try self.slotFor(owner);
        if (slot.in_progress_revision != 0) return error.ReconciliationInProgress;
        if (slot.queued) self.removeQueued(owner);
        slot.* = .{};
    }

    /// Coalesces repeated marks while preserving a revision that changes for
    /// every requested rebuild, including marks made while work is in flight.
    pub fn markDirty(self: *ReconcileQueue, owner: OwnerHandle) !u64 {
        const slot = try self.slotFor(owner);
        if (slot.requested_revision == std.math.maxInt(u64)) return error.RevisionOverflow;
        slot.requested_revision += 1;
        if (!slot.queued and slot.in_progress_revision == 0) try self.enqueue(owner, slot);
        return slot.requested_revision;
    }

    pub fn hasPending(self: *ReconcileQueue, owner: OwnerHandle) !bool {
        const slot = try self.slotFor(owner);
        return slot.queued or slot.in_progress_revision != 0 or
            slot.requested_revision != slot.applied_revision;
    }

    pub fn pendingCount(self: *const ReconcileQueue) usize {
        return self.count;
    }

    pub fn take(self: *ReconcileQueue) ?Work {
        if (self.count == 0) return null;
        const owner = self.queue[self.head];
        self.head = (self.head + 1) % self.queue.len;
        self.count -= 1;
        const slot = &self.slots[owner.slot];
        std.debug.assert(slot.registered and slot.generation == owner.generation and slot.queued);
        slot.queued = false;
        slot.in_progress_revision = slot.requested_revision;
        return .{ .owner = owner, .revision = slot.in_progress_revision };
    }

    pub fn complete(self: *ReconcileQueue, work: Work) !void {
        const slot = try self.slotFor(work.owner);
        if (slot.in_progress_revision != work.revision) return error.StaleReconciliation;
        slot.applied_revision = work.revision;
        slot.in_progress_revision = 0;
        if (slot.requested_revision != slot.applied_revision) try self.enqueue(work.owner, slot);
    }

    pub fn retry(self: *ReconcileQueue, work: Work) !void {
        const slot = try self.slotFor(work.owner);
        if (slot.in_progress_revision != work.revision) return error.StaleReconciliation;
        slot.in_progress_revision = 0;
        try self.enqueue(work.owner, slot);
    }

    fn slotFor(self: *ReconcileQueue, owner: OwnerHandle) !*Slot {
        if (owner.slot >= self.slots.len) return error.StaleOwner;
        const value = &self.slots[owner.slot];
        if (!value.registered or value.generation != owner.generation) return error.StaleOwner;
        return value;
    }

    fn enqueue(self: *ReconcileQueue, owner: OwnerHandle, slot: *Slot) !void {
        if (self.count == self.queue.len) return error.ReconcileQueueFull;
        const tail = (self.head + self.count) % self.queue.len;
        self.queue[tail] = owner;
        self.count += 1;
        slot.queued = true;
    }

    fn removeQueued(self: *ReconcileQueue, owner: OwnerHandle) void {
        var write: usize = 0;
        for (0..self.count) |read| {
            const value = self.queue[(self.head + read) % self.queue.len];
            if (same(value, owner)) continue;
            self.queue[(self.head + write) % self.queue.len] = value;
            write += 1;
        }
        std.debug.assert(write + 1 == self.count);
        self.count = write;
    }
};

fn same(a: OwnerHandle, b: OwnerHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "dirty owners deduplicate and preserve marks made during reconciliation" {
    var queue: ReconcileQueue = undefined;
    try queue.init(std.testing.allocator, 2);
    defer queue.deinit();
    const first: OwnerHandle = .{ .slot = 0, .generation = 3 };
    const second: OwnerHandle = .{ .slot = 1, .generation = 7 };
    try queue.register(first);
    try queue.register(second);

    _ = try queue.markDirty(first);
    _ = try queue.markDirty(first);
    _ = try queue.markDirty(second);
    const work = queue.take().?;
    try std.testing.expectEqual(first, work.owner);
    try std.testing.expectEqual(@as(u64, 2), work.revision);
    _ = try queue.markDirty(first);
    try queue.complete(work);
    const second_work = queue.take().?;
    try std.testing.expectEqual(second, second_work.owner);
    try queue.complete(second_work);
    const repeated = queue.take().?;
    try std.testing.expectEqual(first, repeated.owner);
    try std.testing.expectEqual(@as(u64, 3), repeated.revision);
    try queue.complete(repeated);

    try queue.unregister(first);
    try queue.unregister(second);
}

test "unregister removes queued work and rejects stale generations" {
    var queue: ReconcileQueue = undefined;
    try queue.init(std.testing.allocator, 1);
    defer queue.deinit();
    const old: OwnerHandle = .{ .slot = 0, .generation = 1 };
    try queue.register(old);
    _ = try queue.markDirty(old);
    try queue.unregister(old);
    try std.testing.expect(queue.take() == null);
    try std.testing.expectError(error.StaleOwner, queue.markDirty(old));

    const replacement: OwnerHandle = .{ .slot = 0, .generation = 2 };
    try queue.register(replacement);
    _ = try queue.markDirty(replacement);
    const work = queue.take().?;
    try queue.retry(work);
    try queue.complete(queue.take().?);
    try queue.unregister(replacement);
}
