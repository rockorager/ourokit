pub const SizeU = struct {
    width: u32,
    height: u32,
};

/// Integer device-pixel rectangle. Negative origins are valid and clipped by
/// raster backends; width and height are always non-negative.
pub const RectI = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn intersect(a: RectI, b: RectI) RectI {
        const left = @max(@as(i64, a.x), b.x);
        const top = @max(@as(i64, a.y), b.y);
        const right = @min(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width);
        const bottom = @min(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height);
        if (right <= left or bottom <= top) return .{
            .x = clampI32(left),
            .y = clampI32(top),
            .width = 0,
            .height = 0,
        };
        return .{
            .x = clampI32(left),
            .y = clampI32(top),
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }

    pub fn isEmpty(self: RectI) bool {
        return self.width == 0 or self.height == 0;
    }
};

fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

const std = @import("std");

test "rectangle intersection handles disjoint and overflowing extents" {
    try std.testing.expectEqual(
        RectI{ .x = 5, .y = 4, .width = 5, .height = 6 },
        RectI.intersect(
            .{ .x = 0, .y = 0, .width = 10, .height = 10 },
            .{ .x = 5, .y = 4, .width = 20, .height = 20 },
        ),
    );
    try std.testing.expect(RectI.intersect(
        .{ .x = std.math.maxInt(i32), .y = 0, .width = 100, .height = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    ).isEmpty());
}
