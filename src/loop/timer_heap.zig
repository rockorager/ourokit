const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;

pub const TimerHandle = Handle;

/// A timer removed from the heap. The handle remains useful as an identity for
/// dispatch, but has already been invalidated in the directory.
pub const Expired = struct {
    handle: TimerHandle,
    deadline: u64,
};

const no_slot = std.math.maxInt(u32);

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    deadline: u64 = 0,
    sequence: u64 = 0,
    heap_index: usize = 0,
    next_free: u32 = no_slot,
};

/// Userspace timers ordered by absolute CLOCK_MONOTONIC nanoseconds.
///
/// Handles contain directory indices rather than addresses, so growth cannot
/// invalidate identities. Equal deadlines are returned in scheduling order.
pub const TimerHeap = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    heap: std.ArrayList(u32) = .empty,
    free_head: u32 = no_slot,
    next_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) TimerHeap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TimerHeap) void {
        self.heap.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const TimerHeap) usize {
        return self.heap.items.len;
    }

    pub fn nextDeadline(self: *const TimerHeap) ?u64 {
        if (self.heap.items.len == 0) return null;
        return self.slots.items[self.heap.items[0]].deadline;
    }

    /// Schedules an absolute monotonic deadline.
    pub fn schedule(self: *TimerHeap, deadline: u64) !TimerHandle {
        if (self.next_sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        if (self.free_head == no_slot and self.slots.items.len == no_slot)
            return error.TimerCapacityExceeded;
        try self.heap.ensureUnusedCapacity(self.allocator, 1);
        if (self.free_head == no_slot)
            try self.slots.ensureUnusedCapacity(self.allocator, 1);

        const slot_index = self.takeSlot();
        const slot = &self.slots.items[slot_index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.active = true;
        slot.deadline = deadline;
        slot.sequence = self.next_sequence;
        self.next_sequence += 1;
        slot.heap_index = self.heap.items.len;
        self.heap.appendAssumeCapacity(slot_index);
        self.siftUp(slot.heap_index);
        return .{ .slot = slot_index, .generation = slot.generation };
    }

    /// Schedules relative to `now`, rejecting rather than wrapping overflow.
    pub fn scheduleAfter(self: *TimerHeap, now: u64, delay: u64) !TimerHandle {
        const deadline = std.math.add(u64, now, delay) catch
            return error.DeadlineOverflow;
        return self.schedule(deadline);
    }

    /// Removes an active timer. A false result means the handle is stale.
    pub fn cancel(self: *TimerHeap, handle: TimerHandle) bool {
        if (handle.slot >= self.slots.items.len) return false;
        const slot = &self.slots.items[handle.slot];
        if (!slot.active or slot.generation != handle.generation) return false;
        self.removeAt(slot.heap_index);
        return true;
    }

    pub fn popExpired(self: *TimerHeap, now: u64) ?Expired {
        if (self.heap.items.len == 0) return null;
        const index = self.heap.items[0];
        const slot = self.slots.items[index];
        if (slot.deadline > now) return null;
        self.removeAt(0);
        return .{
            .handle = .{ .slot = index, .generation = slot.generation },
            .deadline = slot.deadline,
        };
    }

    fn takeSlot(self: *TimerHeap) u32 {
        if (self.free_head != no_slot) {
            const index = self.free_head;
            self.free_head = self.slots.items[index].next_free;
            return index;
        }
        const index: u32 = @intCast(self.slots.items.len);
        self.slots.appendAssumeCapacity(.{});
        return index;
    }

    fn removeAt(self: *TimerHeap, position: usize) void {
        const removed = self.heap.items[position];
        const last = self.heap.pop().?;
        if (position < self.heap.items.len) {
            self.heap.items[position] = last;
            self.slots.items[last].heap_index = position;
            if (position > 0 and self.less(last, self.heap.items[(position - 1) / 2]))
                self.siftUp(position)
            else
                self.siftDown(position);
        }
        const slot = &self.slots.items[removed];
        slot.active = false;
        slot.next_free = self.free_head;
        self.free_head = removed;
    }

    fn less(self: *const TimerHeap, lhs_index: u32, rhs_index: u32) bool {
        const lhs = self.slots.items[lhs_index];
        const rhs = self.slots.items[rhs_index];
        return lhs.deadline < rhs.deadline or
            (lhs.deadline == rhs.deadline and lhs.sequence < rhs.sequence);
    }

    fn siftUp(self: *TimerHeap, initial: usize) void {
        var position = initial;
        while (position > 0) {
            const parent = (position - 1) / 2;
            if (!self.less(self.heap.items[position], self.heap.items[parent])) break;
            self.swap(position, parent);
            position = parent;
        }
    }

    fn siftDown(self: *TimerHeap, initial: usize) void {
        var position = initial;
        while (true) {
            const left = position * 2 + 1;
            if (left >= self.heap.items.len) break;
            const right = left + 1;
            const child = if (right < self.heap.items.len and
                self.less(self.heap.items[right], self.heap.items[left])) right else left;
            if (!self.less(self.heap.items[child], self.heap.items[position])) break;
            self.swap(position, child);
            position = child;
        }
    }

    fn swap(self: *TimerHeap, a: usize, b: usize) void {
        std.mem.swap(u32, &self.heap.items[a], &self.heap.items[b]);
        self.slots.items[self.heap.items[a]].heap_index = a;
        self.slots.items[self.heap.items[b]].heap_index = b;
    }
};

test "timers pop by deadline and equal deadlines preserve insertion order" {
    var timers = TimerHeap.init(std.testing.allocator);
    defer timers.deinit();
    const late = try timers.schedule(30);
    const equal_a = try timers.schedule(10);
    const middle = try timers.schedule(20);
    const equal_b = try timers.schedule(10);
    try std.testing.expectEqual(@as(?u64, 10), timers.nextDeadline());
    try std.testing.expectEqual(equal_a, timers.popExpired(10).?.handle);
    try std.testing.expectEqual(equal_b, timers.popExpired(10).?.handle);
    try std.testing.expect(timers.popExpired(19) == null);
    try std.testing.expectEqual(middle, timers.popExpired(20).?.handle);
    try std.testing.expectEqual(late, timers.popExpired(30).?.handle);
    try std.testing.expectEqual(@as(usize, 0), timers.count());
    try std.testing.expect(timers.nextDeadline() == null);
}

test "cancellation removes root middle and last heap positions" {
    var timers = TimerHeap.init(std.testing.allocator);
    defer timers.deinit();
    const root = try timers.schedule(1);
    _ = try timers.schedule(2);
    const middle = try timers.schedule(3);
    const last = try timers.schedule(4);
    try std.testing.expect(timers.cancel(root));
    try std.testing.expect(timers.cancel(middle));
    try std.testing.expect(timers.cancel(last));
    try std.testing.expectEqual(@as(usize, 1), timers.count());
    try std.testing.expectEqual(@as(u64, 2), timers.popExpired(2).?.deadline);
}

test "cancellation rejects stale generations and reused slots get new identities" {
    var timers = TimerHeap.init(std.testing.allocator);
    defer timers.deinit();
    const old = try timers.schedule(1);
    try std.testing.expect(timers.cancel(old));
    try std.testing.expect(!timers.cancel(old));
    const replacement = try timers.schedule(2);
    try std.testing.expectEqual(old.slot, replacement.slot);
    try std.testing.expect(old.generation != replacement.generation);
    try std.testing.expect(!timers.cancel(old));
    try std.testing.expect(timers.cancel(replacement));
}

test "directory and heap grow dynamically" {
    var timers = TimerHeap.init(std.testing.allocator);
    defer timers.deinit();
    const total = 4096;
    for (0..total) |i| _ = try timers.schedule(@intCast(total - i));
    try std.testing.expectEqual(@as(usize, total), timers.count());
    for (1..total + 1) |deadline|
        try std.testing.expectEqual(@as(u64, @intCast(deadline)), timers.popExpired(@intCast(deadline)).?.deadline);
}

test "deadline boundaries and schedule-after overflow" {
    var timers = TimerHeap.init(std.testing.allocator);
    defer timers.deinit();
    const zero = try timers.scheduleAfter(0, 0);
    const maximum = try timers.scheduleAfter(std.math.maxInt(u64) - 1, 1);
    try std.testing.expectError(error.DeadlineOverflow, timers.scheduleAfter(std.math.maxInt(u64), 1));
    try std.testing.expectEqual(zero, timers.popExpired(0).?.handle);
    try std.testing.expect(timers.popExpired(std.math.maxInt(u64) - 1) == null);
    try std.testing.expectEqual(maximum, timers.popExpired(std.math.maxInt(u64)).?.handle);
}
