const std = @import("std");
const Loop = @import("../../loop/io_uring.zig").Loop;
const TimerHandle = @import("../../loop/io_uring.zig").OperationHandle;
const platform = @import("../window.zig");

pub const Fire = struct {
    window: platform.WindowHandle,
    serial: u32,
    time_ms: u32,
    keycode: u32,
};

const Armed = struct {
    timer: TimerHandle,
    window: platform.WindowHandle,
    serial: u32,
    next_time_ns: u64,
    keycode: u32,
};

/// Client-side wl_keyboard repeat policy. The compositor supplies rate and
/// delay; one logical Ouro timer is retained only while a repeatable key is
/// held. Expiration returns data and rearms without invoking application code.
pub const State = struct {
    rate_hz: u31 = 0,
    delay_ms: u31 = 0,
    armed: ?Armed = null,

    pub fn setInfo(self: *State, loop: *Loop, rate: i32, delay_ms: i32) !void {
        try self.stop(loop);
        if (rate <= 0) {
            self.rate_hz = 0;
            self.delay_ms = 0;
            return;
        }
        if (delay_ms < 0) return error.InvalidKeyboardRepeatInfo;
        self.rate_hz = @intCast(rate);
        self.delay_ms = @intCast(delay_ms);
    }

    pub fn press(
        self: *State,
        loop: *Loop,
        window: platform.WindowHandle,
        serial: u32,
        time_ms: u32,
        keycode: u32,
        repeatable: bool,
    ) !void {
        if (!repeatable or self.rate_hz == 0) return;
        try self.stop(loop);
        const delay_ns = std.math.mul(u64, self.delay_ms, std.time.ns_per_ms) catch
            return error.InvalidKeyboardRepeatInfo;
        self.armed = .{
            .timer = try loop.prepareTimeout(delay_ns),
            .window = window,
            .serial = serial,
            .next_time_ns = @as(u64, time_ms) * std.time.ns_per_ms + delay_ns,
            .keycode = keycode,
        };
    }

    pub fn release(self: *State, loop: *Loop, keycode: u32) !void {
        const armed = self.armed orelse return;
        if (armed.keycode == keycode) try self.stop(loop);
    }

    pub fn stop(self: *State, loop: *Loop) !void {
        const armed = self.armed orelse return;
        try loop.prepareCancel(armed.timer);
        self.armed = null;
    }

    pub fn owns(self: *const State, timer: TimerHandle) bool {
        const armed = self.armed orelse return false;
        return same(armed.timer, timer);
    }

    /// Called after the loop has removed `timer` from its heap. Rearms from
    /// now rather than emitting catch-up bursts after a delayed application
    /// turn, while event timestamps advance by the compositor's cadence.
    pub fn fired(self: *State, loop: *Loop, timer: TimerHandle) !?Fire {
        var armed = self.armed orelse return null;
        if (!same(armed.timer, timer)) return null;
        self.armed = null;
        const interval_ns = @max(@as(u64, 1), std.time.ns_per_s / self.rate_hz);
        const fire: Fire = .{
            .window = armed.window,
            .serial = armed.serial,
            .time_ms = @truncate(armed.next_time_ns / std.time.ns_per_ms),
            .keycode = armed.keycode,
        };
        armed.next_time_ns +%= interval_ns;
        armed.timer = try loop.prepareTimeout(interval_ns);
        self.armed = armed;
        return fire;
    }
};

fn same(a: TimerHandle, b: TimerHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "repeat honors compositor policy and rearms one logical timer" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var repeat: State = .{};
    try repeat.setInfo(&loop, 25, 400);
    const window: platform.WindowHandle = .{ .slot = 2, .generation = 3 };
    try repeat.press(&loop, window, 7, 100, 30, true);
    const first = repeat.armed.?.timer;
    try std.testing.expect(repeat.owns(first));
    try loop.prepareCancel(first); // Models expiry removal without wall-clock waiting.
    const fired = (try repeat.fired(&loop, first)).?;
    try std.testing.expectEqual(window, fired.window);
    try std.testing.expectEqual(@as(u32, 500), fired.time_ms);
    try std.testing.expect(!repeat.owns(first));
    try repeat.release(&loop, 30);
    try std.testing.expect(repeat.armed == null);
}

test "disabled and non-repeatable keys never allocate timers" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 1);
    defer loop.deinit();
    var repeat: State = .{};
    const window: platform.WindowHandle = .{ .slot = 1, .generation = 1 };
    try repeat.setInfo(&loop, 0, 500);
    try repeat.press(&loop, window, 1, 2, 3, true);
    try std.testing.expect(repeat.armed == null);
    try repeat.setInfo(&loop, 30, 500);
    try repeat.press(&loop, window, 1, 2, 3, false);
    try std.testing.expect(repeat.armed == null);
    try repeat.press(&loop, window, 1, 2, 4, true);
    const active = repeat.armed.?.timer;
    try repeat.press(&loop, window, 2, 3, 5, false);
    try std.testing.expect(repeat.owns(active));
    try repeat.stop(&loop);
    try std.testing.expectError(error.InvalidKeyboardRepeatInfo, repeat.setInfo(&loop, 30, -1));
}

test "fractional-millisecond repeat cadence does not accumulate truncation" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 1);
    defer loop.deinit();
    var repeat: State = .{};
    const window: platform.WindowHandle = .{ .slot = 1, .generation = 1 };
    try repeat.setInfo(&loop, 60, 0);
    try repeat.press(&loop, window, 1, 100, 30, true);
    const first = repeat.armed.?.timer;
    try loop.prepareCancel(first);
    try std.testing.expectEqual(@as(u32, 100), (try repeat.fired(&loop, first)).?.time_ms);
    const second = repeat.armed.?.timer;
    try loop.prepareCancel(second);
    try std.testing.expectEqual(@as(u32, 116), (try repeat.fired(&loop, second)).?.time_ms);
    const third = repeat.armed.?.timer;
    try loop.prepareCancel(third);
    try std.testing.expectEqual(@as(u32, 133), (try repeat.fired(&loop, third)).?.time_ms);
    try repeat.stop(&loop);
}
