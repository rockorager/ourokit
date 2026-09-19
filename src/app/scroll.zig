const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;

pub const interval_ns = 8 * std.time.ns_per_ms;

/// One finger-scroll axis. Positions stay in the retained instance tree;
/// this only tracks gesture velocity and the originating scroll container.
pub const Motion = struct {
    target: ?Handle = null,
    velocity: f32 = 0,
    sample_ms: ?u32 = null,
    active: bool = false,
    tick_ns: ?u64 = null,

    pub fn sample(self: *Motion, target: Handle, delta: f32, time_ms: u32) void {
        if (!std.meta.eql(self.target, @as(?Handle, target))) self.* = .{ .target = target };
        const previous = self.sample_ms;
        self.sample_ms = time_ms;
        const dt = time_ms -% (previous orelse {
            self.velocity = 0;
            return;
        });
        if (dt > 200) {
            self.velocity = 0;
            return;
        }
        if (dt == 0) return;
        const instantaneous = delta * 1000 / @as(f32, @floatFromInt(dt));
        self.velocity = std.math.clamp(0.25 * self.velocity + 0.75 * instantaneous, -8000, 8000);
    }

    pub fn stop(self: *Motion, time_ms: u32) void {
        const last = self.sample_ms orelse return;
        self.sample_ms = null;
        // Holding still before lifting must not resurrect an old fast sample.
        if (time_ms -% last > 200 or @abs(self.velocity) < 150) {
            self.* = .{};
            return;
        }
        self.active = true;
        self.tick_ns = null;
    }

    pub fn advance(self: *Motion, now_ns: u64) f32 {
        if (!self.active) return 0;
        const previous = self.tick_ns orelse now_ns;
        self.tick_ns = now_ns;
        const dt_ms = @as(f32, @floatFromInt(now_ns -| previous)) / std.time.ns_per_ms;
        const delta = self.velocity * dt_ms / 1000;
        self.velocity *= std.math.pow(f32, 0.998, dt_ms);
        if (@abs(self.velocity) < 30) self.active = false;
        return delta;
    }
};

test "scroll momentum uses wrapped timestamps, decays with elapsed time and stops" {
    const target: Handle = .{ .slot = 1, .generation = 1 };
    var motion: Motion = .{};
    motion.sample(target, 8, std.math.maxInt(u32) - 3);
    motion.sample(target, 8, 4); // Eight milliseconds across wraparound.
    try std.testing.expectEqual(@as(f32, 750), motion.velocity);
    motion.stop(5);
    try std.testing.expect(motion.active);
    try std.testing.expectEqual(@as(f32, 0), motion.advance(100 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(f32, 6), motion.advance(108 * std.time.ns_per_ms));
    try std.testing.expectApproxEqAbs(@as(f32, 738.08), motion.velocity, 0.01);
    const next = motion.advance(188 * std.time.ns_per_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 59.046), next, 0.01);
    for (24..300) |tick| _ = motion.advance(tick * interval_ns);
    try std.testing.expect(!motion.active);
    try std.testing.expectEqual(@as(f32, 0), motion.advance(300 * interval_ns));
}

test "scroll momentum rejects stale and slow gestures and resets on retarget" {
    const a: Handle = .{ .slot = 1, .generation = 1 };
    const b: Handle = .{ .slot = 1, .generation = 2 };
    var motion: Motion = .{};
    motion.sample(a, -8, 0);
    motion.sample(a, -8, 8);
    try std.testing.expectEqual(@as(f32, -750), motion.velocity);
    motion.stop(209);
    try std.testing.expect(!motion.active);
    motion.sample(a, 8, 300);
    motion.sample(a, 8, 308);
    motion.sample(b, 8, 316);
    motion.stop(317);
    try std.testing.expect(!motion.active);
    motion.sample(a, 1, 400);
    motion.sample(a, 1, 410);
    motion.stop(411);
    try std.testing.expect(!motion.active);
    motion.sample(a, 1000, 500);
    motion.sample(a, 1000, 501);
    try std.testing.expectEqual(@as(f32, 8000), motion.velocity);
    motion.sample(a, 1, 702);
    motion.stop(703);
    try std.testing.expect(!motion.active);
}
