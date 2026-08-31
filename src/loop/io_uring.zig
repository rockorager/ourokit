const std = @import("std");
const linux = std.os.linux;
const timer_heap = @import("timer_heap.zig");

pub const OperationHandle = timer_heap.TimerHandle;

const Operation = enum(u8) {
    timer_alarm = 0xa0,
    timer_update = 0xa1,
    timer_remove = 0xa2,
};

const Control = enum { none, update, remove };

pub const Completion = struct {
    operation: OperationHandle,
    deadline_ns: u64,
};

/// `foreign` is intentionally returned unchanged to let one CQ loop route
/// Wayring and future subsystems before or after Ourokit's own operations.
pub const Dispatch = union(enum) {
    foreign,
    stale,
    timer_wakeup,
    timer_control,
};

/// Ourokit-owned raw io_uring plus a userspace logical-timer heap. Logical
/// timers never consume SQEs individually: one absolute kernel timeout tracks
/// the heap root and `IORING_TIMEOUT_UPDATE` moves that alarm when necessary.
pub const Loop = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    timers: timer_heap.TimerHeap,
    operation_capacity_hint: usize,

    alarm_generation: u32 = 0,
    alarm_active: bool = false,
    retired_alarm_generation: ?u32 = null,
    alarm_deadline_ns: u64 = 0,
    alarm_time: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    control: Control = .none,
    control_deadline_ns: u64 = 0,
    control_time: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    pub fn init(
        self: *Loop,
        allocator: std.mem.Allocator,
        entries: u16,
        operation_capacity: u32,
    ) !void {
        if (operation_capacity == 0) return error.InvalidCapacity;
        self.* = .{
            .allocator = allocator,
            .ring = try linux.IoUring.init(
                entries,
                linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN,
            ),
            .timers = timer_heap.TimerHeap.init(allocator),
            .operation_capacity_hint = operation_capacity,
        };
    }

    pub fn deinit(self: *Loop) void {
        std.debug.assert(self.timers.count() == 0);
        std.debug.assert(!self.alarm_active and self.retired_alarm_generation == null and
            self.control == .none);
        self.timers.deinit();
        self.ring.deinit();
        self.* = undefined;
    }

    /// Adds a logical CLOCK_MONOTONIC timer. The next `submit` synchronizes one
    /// kernel alarm with the earliest userspace deadline.
    pub fn prepareTimeout(self: *Loop, nanoseconds: u64) !OperationHandle {
        return self.timers.scheduleAfter(try monotonicNow(), nanoseconds);
    }

    /// Logical cancellation is immediate and produces no timer completion.
    /// Kernel alarm maintenance is coalesced at the next submission boundary.
    pub fn prepareCancel(self: *Loop, handle: OperationHandle) !void {
        if (!self.timers.cancel(handle)) return error.StaleOperation;
    }

    pub fn submit(self: *Loop) !u32 {
        try self.synchronizeAlarm();
        return self.ring.submit();
    }

    pub fn operationCapacity(self: *const Loop) usize {
        return self.operation_capacity_hint;
    }

    pub fn hasPendingTimerKernelWork(self: *const Loop) bool {
        return self.alarm_active or self.retired_alarm_generation != null or self.control != .none;
    }

    pub fn wait(self: *Loop) !linux.io_uring_cqe {
        return self.ring.copy_cqe();
    }

    /// Returns every logical timer whose deadline has passed. Callers dispatch
    /// these as state transitions only; language tasks resume at their phase.
    pub fn takeExpired(self: *Loop) !?Completion {
        const expired = self.timers.popExpired(try monotonicNow()) orelse return null;
        return .{ .operation = expired.handle, .deadline_ns = expired.deadline };
    }

    /// Validates the private timer namespace and alarm generation. No callback
    /// is invoked here and logical timer handles never enter kernel user_data.
    pub fn dispatch(self: *Loop, cqe: linux.io_uring_cqe) Dispatch {
        const decoded = decode(cqe.user_data) orelse return .foreign;
        if (decoded.operation == .timer_alarm and
            self.retired_alarm_generation == decoded.generation)
        {
            self.retired_alarm_generation = null;
            return .timer_control;
        }
        if (decoded.generation != self.alarm_generation) return .stale;
        switch (decoded.operation) {
            .timer_alarm => {
                if (!self.alarm_active) return .stale;
                self.alarm_active = false;
                return .timer_wakeup;
            },
            .timer_update => {
                if (self.control != .update) return .stale;
                if (cqe.res == 0) self.alarm_deadline_ns = self.control_deadline_ns;
                self.control = .none;
                return .timer_control;
            },
            .timer_remove => {
                if (self.control != .remove) return .stale;
                if (cqe.res == 0) {
                    self.alarm_active = false;
                    self.retired_alarm_generation = self.alarm_generation;
                }
                self.control = .none;
                return .timer_control;
            },
        }
    }

    fn synchronizeAlarm(self: *Loop) !void {
        if (self.control != .none) return;
        if (self.retired_alarm_generation != null) return;
        const desired = self.timers.nextDeadline();
        if (!self.alarm_active) {
            const deadline = desired orelse return;
            self.alarm_generation +%= 1;
            if (self.alarm_generation == 0) self.alarm_generation = 1;
            self.alarm_deadline_ns = deadline;
            self.alarm_time = timespec(deadline);
            _ = try self.ring.timeout(
                encode(.timer_alarm, self.alarm_generation),
                &self.alarm_time,
                0,
                linux.IORING_TIMEOUT_ABS,
            );
            self.alarm_active = true;
            return;
        }
        if (desired) |deadline| {
            if (deadline == self.alarm_deadline_ns) return;
            self.control = .update;
            self.control_deadline_ns = deadline;
            self.control_time = timespec(deadline);
            const sqe = try self.ring.get_sqe();
            sqe.prep_timeout_remove(
                encode(.timer_alarm, self.alarm_generation),
                linux.IORING_TIMEOUT_UPDATE | linux.IORING_TIMEOUT_ABS,
            );
            // liburing's timeout-update layout: the new timespec is in `off`,
            // while `addr` continues to identify the original timeout.
            sqe.off = @intFromPtr(&self.control_time);
            sqe.user_data = encode(.timer_update, self.alarm_generation);
        } else {
            self.control = .remove;
            _ = try self.ring.timeout_remove(
                encode(.timer_remove, self.alarm_generation),
                encode(.timer_alarm, self.alarm_generation),
                0,
            );
        }
    }
};

const Decoded = struct {
    operation: Operation,
    generation: u32,
};

fn encode(operation: Operation, generation: u32) u64 {
    return @intFromEnum(operation) | (@as(u64, generation) << 32);
}

fn decode(value: u64) ?Decoded {
    const operation: Operation = switch (@as(u8, @truncate(value))) {
        @intFromEnum(Operation.timer_alarm) => .timer_alarm,
        @intFromEnum(Operation.timer_update) => .timer_update,
        @intFromEnum(Operation.timer_remove) => .timer_remove,
        else => return null,
    };
    return .{ .operation = operation, .generation = @truncate(value >> 32) };
}

fn timespec(nanoseconds: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
}

fn monotonicNow() !u64 {
    var value: linux.timespec = undefined;
    switch (linux.errno(linux.clock_gettime(.MONOTONIC, &value))) {
        .SUCCESS => {},
        else => return error.ClockUnavailable,
    }
    return std.math.add(
        u64,
        try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s),
        @intCast(value.nsec),
    );
}

fn drainKernelTimer(loop: *Loop) !void {
    while (loop.hasPendingTimerKernelWork()) {
        _ = try loop.submit();
        _ = loop.dispatch(try loop.wait());
    }
}

test "many logical timers share one kernel alarm and expire in order" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();

    const late = try loop.prepareTimeout(4 * std.time.ns_per_ms);
    const early = try loop.prepareTimeout(1 * std.time.ns_per_ms);
    const middle = try loop.prepareTimeout(2 * std.time.ns_per_ms);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(early, (try loop.takeExpired()).?.operation);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(middle, (try loop.takeExpired()).?.operation);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(late, (try loop.takeExpired()).?.operation);
}

test "an earlier logical timer updates the submitted kernel alarm" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();

    const late = try loop.prepareTimeout(50 * std.time.ns_per_ms);
    _ = try loop.submit();
    const early = try loop.prepareTimeout(1 * std.time.ns_per_ms);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_control, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(early, (try loop.takeExpired()).?.operation);
    try loop.prepareCancel(late);
}

test "logical cancellation invalidates immediately and removes the kernel alarm" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 1);
    defer loop.deinit();

    const operation = try loop.prepareTimeout(std.time.ns_per_s);
    _ = try loop.submit();
    try loop.prepareCancel(operation);
    try std.testing.expectError(error.StaleOperation, loop.prepareCancel(operation));
    try drainKernelTimer(&loop);
    try std.testing.expect((try loop.takeExpired()) == null);
}
