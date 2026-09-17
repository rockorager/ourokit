const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;
const PointF = @import("../../core/geometry.zig").PointF;

/// A click sequence belongs to one target and a small physical neighborhood.
pub const Clicks = struct {
    interval_ms: u32 = 500,
    distance: f32 = 5,
    target: ?Handle = null,
    position: PointF = .{},
    time_ms: u32 = 0,
    count: u2 = 0,

    pub fn press(self: *Clicks, target: Handle, position: PointF, time_ms: u32) u2 {
        self.motion(position);
        self.count = if (std.meta.eql(self.target, @as(?Handle, target)) and
            time_ms -% self.time_ms <= self.interval_ms) self.count % 3 + 1 else 1;
        self.target = target;
        self.position = position;
        self.time_ms = time_ms;
        return self.count;
    }

    pub fn motion(self: *Clicks, position: PointF) void {
        const dx = position.x - self.position.x;
        const dy = position.y - self.position.y;
        if (dx * dx + dy * dy > self.distance * self.distance) self.reset();
    }

    pub fn reset(self: *Clicks) void {
        self.target = null;
        self.count = 0;
    }
};

test "click sequences respect target distance timeout and timestamp wrap" {
    var clicks: Clicks = .{};
    const target: Handle = .{ .slot = 1, .generation = 1 };
    try std.testing.expectEqual(@as(u2, 1), clicks.press(target, .{}, std.math.maxInt(u32) - 10));
    try std.testing.expectEqual(@as(u2, 2), clicks.press(target, .{ .x = 3, .y = 4 }, 10));
    try std.testing.expectEqual(@as(u2, 3), clicks.press(target, .{ .x = 3, .y = 4 }, 510));
    try std.testing.expectEqual(@as(u2, 1), clicks.press(target, .{ .x = 3, .y = 4 }, 511));
    try std.testing.expectEqual(@as(u2, 1), clicks.press(target, .{ .x = 3, .y = 4 }, 1012));
    clicks.motion(.{ .x = 9, .y = 4 });
    try std.testing.expectEqual(@as(u2, 1), clicks.press(target, .{ .x = 3, .y = 4 }, 1013));
    try std.testing.expectEqual(@as(u2, 1), clicks.press(.{ .slot = 1, .generation = 2 }, .{ .x = 3, .y = 4 }, 1014));
}
