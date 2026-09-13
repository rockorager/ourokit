const std = @import("std");

/// Fractional device pixels, in FreeType's 26.6 units. Y increases downwards,
/// like scene coordinates; the rasterizer negates it for FreeType's Y-up axis.
pub const Phase = struct { x: u6 = 0, y: u6 = 0 };

pub const Position = struct {
    x: i32,
    y: i32,
    phase: Phase,

    pub fn init(x: f32, y: f32) Position {
        const horizontal = split(x);
        const vertical = split(y);
        return .{ .x = horizontal.anchor, .y = vertical.anchor, .phase = .{ .x = horizontal.phase, .y = vertical.phase } };
    }
};

/// Quantize only the final raster origin, never the accumulated layout pen.
/// Floor (not truncation) keeps negative origins' phases nonnegative. Carry a
/// rounded phase of 64 into the anchor so equivalent positions share masks.
fn split(value: f32) struct { anchor: i32, phase: u6 } {
    const floor = @floor(value);
    const fraction: u7 = @intFromFloat(@round((value - floor) * 64));
    return .{
        .anchor = @as(i32, @intFromFloat(floor)) + @as(i32, fraction / 64),
        .phase = @intCast(fraction % 64),
    };
}

test "raster positions floor negative coordinates and carry quantized phases" {
    try std.testing.expectEqual(Position{ .x = 3, .y = -3, .phase = .{ .x = 13, .y = 45 } }, Position.init(3.203125, -2.296875));
    try std.testing.expectEqual(Position{ .x = -1, .y = 0, .phase = .{ .x = 63, .y = 1 } }, Position.init(-0.015625, 0.015625));
    try std.testing.expectEqual(Position{ .x = 4, .y = 0, .phase = .{} }, Position.init(3.999, -0.001));
    try std.testing.expectEqual(Position{ .x = -4, .y = 7, .phase = .{} }, Position.init(-4, 7));
}
