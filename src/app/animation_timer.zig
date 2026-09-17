const std = @import("std");
const io = @import("../loop/root.zig");

/// One demand-driven wakeup shared by all windows. Frame submissions never
/// postpone an already-armed deadline, and idle windows allocate no timer.
pub const Timer = struct {
    armed: ?struct { operation: io.OperationHandle, deadline_ns: u64 } = null,

    pub fn update(self: *Timer, loop: *io.Loop, now_ns: u64, delay_ns: ?u64) !void {
        if (self.armed) |armed| {
            if (delay_ns) |delay| if (armed.deadline_ns <= now_ns +| delay) return;
            try self.stop(loop);
        }
        if (delay_ns) |delay| self.armed = .{
            .operation = try loop.prepareTimeout(delay),
            .deadline_ns = now_ns +| delay,
        };
    }

    pub fn stop(self: *Timer, loop: *io.Loop) !void {
        if (self.armed) |armed| try loop.prepareCancel(armed.operation);
        self.armed = null;
    }

    pub fn fired(self: *Timer, operation: io.OperationHandle) bool {
        const armed = self.armed orelse return false;
        if (!std.meta.eql(armed.operation, operation)) return false;
        self.armed = null;
        return true;
    }
};

test "animation timer keeps the earliest wakeup cancels idle work and rejects stale expiry" {
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var timer: Timer = .{};
    try timer.update(&loop, 0, null);
    try std.testing.expect(timer.armed == null);
    try timer.update(&loop, 0, 500 * std.time.ns_per_ms);
    const first = timer.armed.?.operation;
    try timer.update(&loop, 10 * std.time.ns_per_ms, 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(first, timer.armed.?.operation);
    try timer.update(&loop, 10 * std.time.ns_per_ms, 16 * std.time.ns_per_ms);
    try std.testing.expect(!timer.fired(first));
    const next = timer.armed.?.operation;
    try loop.prepareCancel(next); // Simulate removing the expired timer.
    try std.testing.expect(timer.fired(next));
    try timer.update(&loop, 26 * std.time.ns_per_ms, 16 * std.time.ns_per_ms);
    try timer.update(&loop, 27 * std.time.ns_per_ms, null);
    try std.testing.expect(timer.armed == null);
}
