pub const SizeU = struct {
    width: u32,
    height: u32,
};

/// Logical UI geometry. Layout remains independent of output scale and pixel
/// format; scene construction lowers these values into device coordinates.
pub const PointF = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: PointF, b: PointF) PointF {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};

pub const SizeF = struct {
    width: f32,
    height: f32,
};

pub const RectF = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: RectF, point: PointF) bool {
        return point.x >= self.x and point.y >= self.y and
            point.x < self.x + self.width and point.y < self.y + self.height;
    }
};

pub const Insets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn all(value: f32) Insets {
        return .{ .left = value, .top = value, .right = value, .bottom = value };
    }

    pub fn horizontal(self: Insets) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Insets) f32 {
        return self.top + self.bottom;
    }
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

test "logical rectangles use half-open hit-test bounds" {
    const rect: RectF = .{ .x = 2, .y = 3, .width = 4, .height = 5 };
    try std.testing.expect(rect.contains(.{ .x = 2, .y = 3 }));
    try std.testing.expect(rect.contains(.{ .x = 5.999, .y = 7.999 }));
    try std.testing.expect(!rect.contains(.{ .x = 6, .y = 4 }));
}
