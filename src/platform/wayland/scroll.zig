const std = @import("std");
const platform = @import("../window.zig");

/// Wayland axis metadata may follow the delta it describes. Normalize only at
/// wl_pointer.frame, preferring value120 over discrete steps over raw values.
pub const Pending = struct {
    source: ?platform.PointerAxisSource = null,
    axes: [2]Axis = @splat(.{}),

    const Axis = struct {
        delta: f32 = 0,
        time_ms: u32 = 0,
        steps: ?f32 = null,
        steps120: ?f32 = null,
        stop_ms: ?u32 = null,
    };

    pub fn push(self: *Pending, event: platform.PointerEvent) void {
        switch (event) {
            .axis => |value| {
                const axis = &self.axes[@intFromEnum(value.axis)];
                axis.delta += value.delta;
                axis.time_ms = value.time_ms;
            },
            .axis_source => |value| self.source = value.source,
            .axis_steps => |value| {
                const axis = &self.axes[@intFromEnum(value.axis)];
                axis.steps = (axis.steps orelse 0) + @as(f32, @floatFromInt(value.steps));
            },
            .axis_steps120 => |value| {
                const axis = &self.axes[@intFromEnum(value.axis)];
                axis.steps120 = (axis.steps120 orelse 0) + @as(f32, @floatFromInt(value.steps120));
            },
            .axis_stop => |value| self.axes[@intFromEnum(value.axis)].stop_ms = value.time_ms,
            else => unreachable,
        }
    }

    pub fn flush(self: *Pending, window: platform.WindowHandle, sink: anytype) !void {
        defer self.* = .{};
        for (self.axes, 0..) |axis, index| {
            const wheel = self.source == .wheel or self.source == .wheel_tilt or
                (self.source == null and (axis.steps120 != null or axis.steps != null));
            const steps = if (axis.steps120) |value| value / 120 else axis.steps;
            const delta = if (wheel and steps != null) steps.? * 100 else axis.delta * 3;
            if (delta != 0) try sink.pointer(.{ .axis = .{
                .window = window,
                .axis = @enumFromInt(index),
                .time_ms = axis.time_ms,
                .delta = delta,
                .source = self.source,
            } });
        }
        // Deliver both movement axes before either stop can launch momentum.
        for (self.axes, 0..) |axis, index| if (axis.stop_ms) |time_ms| {
            try sink.pointer(.{ .axis_stop = .{
                .window = window,
                .axis = @enumFromInt(index),
                .time_ms = time_ms,
            } });
        };
    }
};

test "Wayland scroll normalizes framed wheel metadata and continuous deltas" {
    const Sink = struct {
        events: [4]platform.PointerEvent = undefined,
        count: usize = 0,
        pub fn pointer(self: *@This(), event: platform.PointerEvent) !void {
            self.events[self.count] = event;
            self.count += 1;
        }
    };
    const window: platform.WindowHandle = .{ .slot = 1, .generation = 1 };
    var sink: Sink = .{};
    var pending: Pending = .{};
    pending.push(.{ .axis = .{ .window = window, .axis = .vertical, .time_ms = 12, .delta = 15 } });
    pending.push(.{ .axis_steps = .{ .window = window, .axis = .vertical, .steps = 1 } });
    pending.push(.{ .axis_steps120 = .{ .window = window, .axis = .vertical, .steps120 = 30 } });
    pending.push(.{ .axis = .{ .window = window, .axis = .horizontal, .time_ms = 12, .delta = -15 } });
    pending.push(.{ .axis_steps = .{ .window = window, .axis = .horizontal, .steps = -2 } });
    pending.push(.{ .axis_source = .{ .window = window, .source = .wheel } });
    try pending.flush(window, &sink);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(@as(f32, 25), sink.events[0].axis.delta);
    try std.testing.expectEqual(@as(f32, -200), sink.events[1].axis.delta);
    try std.testing.expectEqual(platform.PointerAxisSource.wheel, sink.events[0].axis.source.?);
    try pending.flush(window, &sink);
    try std.testing.expectEqual(@as(usize, 2), sink.count);

    sink.count = 0;
    pending.push(.{ .axis = .{ .window = window, .axis = .vertical, .time_ms = 20, .delta = 4 } });
    pending.push(.{ .axis = .{ .window = window, .axis = .horizontal, .time_ms = 20, .delta = -2.5 } });
    pending.push(.{ .axis_source = .{ .window = window, .source = .finger } });
    pending.push(.{ .axis_stop = .{ .window = window, .axis = .vertical, .time_ms = 21 } });
    try pending.flush(window, &sink);
    try std.testing.expectEqual(@as(f32, 12), sink.events[0].axis.delta);
    try std.testing.expectEqual(@as(f32, -7.5), sink.events[1].axis.delta);
    try std.testing.expectEqual(@as(u32, 21), sink.events[2].axis_stop.time_ms);

    sink.count = 0;
    pending.push(.{ .axis = .{ .window = window, .axis = .vertical, .time_ms = 30, .delta = 15 } });
    try pending.flush(window, &sink);
    try std.testing.expectEqual(@as(f32, 45), sink.events[0].axis.delta);
    try std.testing.expectEqual(null, sink.events[0].axis.source);
}
