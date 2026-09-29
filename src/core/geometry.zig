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

/// Positive uniform paint transform. Translation follows scaling about origin;
/// layout geometry is not changed. Compositions normalize the origin to zero.
pub const Transform = struct {
    translation: PointF = .{},
    scale: f32 = 1,
    origin: PointF = .{},

    pub fn validate(self: Transform) !void {
        if (!std.math.isFinite(self.scale) or self.scale <= 0 or
            !std.math.isFinite(1 / self.scale) or
            !std.math.isFinite(self.translation.x) or !std.math.isFinite(self.translation.y) or
            !std.math.isFinite(self.origin.x) or !std.math.isFinite(self.origin.y))
            return error.InvalidTransform;
    }

    pub fn point(self: Transform, value: PointF) PointF {
        return .{
            .x = @floatCast(@as(f64, self.translation.x) + self.origin.x + @as(f64, self.scale) * (@as(f64, value.x) - self.origin.x)),
            .y = @floatCast(@as(f64, self.translation.y) + self.origin.y + @as(f64, self.scale) * (@as(f64, value.y) - self.origin.y)),
        };
    }

    pub fn inversePoint(self: Transform, value: PointF) PointF {
        return .{
            .x = @floatCast((@as(f64, value.x) - self.translation.x - self.origin.x) / self.scale + self.origin.x),
            .y = @floatCast((@as(f64, value.y) - self.translation.y - self.origin.y) / self.scale + self.origin.y),
        };
    }

    pub fn rect(self: Transform, value: RectF) RectF {
        const start = self.point(.{ .x = value.x, .y = value.y });
        return .{ .x = start.x, .y = start.y, .width = value.width * self.scale, .height = value.height * self.scale };
    }

    /// Apply child first, then this parent. f64 intermediates avoid overflow
    /// before cancellation; the stored map and its inverse must remain finite.
    pub fn compose(self: Transform, child: Transform) !Transform {
        try self.validate();
        try child.validate();
        const result: Transform = .{
            .scale = @floatCast(@as(f64, self.scale) * child.scale),
            .translation = .{
                .x = @floatCast(@as(f64, self.translation.x) + @as(f64, self.origin.x) * (1 - @as(f64, self.scale)) + @as(f64, self.scale) * (@as(f64, child.translation.x) + @as(f64, child.origin.x) * (1 - @as(f64, child.scale)))),
                .y = @floatCast(@as(f64, self.translation.y) + @as(f64, self.origin.y) * (1 - @as(f64, self.scale)) + @as(f64, self.scale) * (@as(f64, child.translation.y) + @as(f64, child.origin.y) * (1 - @as(f64, child.scale)))),
            },
        };
        try result.validate();
        return result;
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

    /// Logical contour containment, not the antialiased device-pixel fringe.
    pub fn containsRounded(self: RectF, point: PointF, radius: f32) bool {
        if (!self.contains(point)) return false;
        const r: f64 = @min(@as(f64, radius), @as(f64, @min(self.width, self.height)) * 0.5);
        if (r == 0) return true;
        const x = @as(f64, point.x) - self.x;
        const y = @as(f64, point.y) - self.y;
        const dx = @max(@max(r - x, x - (self.width - r)), 0);
        const dy = @max(@max(r - y, y - (self.height - r)), 0);
        return dx * dx + dy * dy <= r * r;
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

test "transform composition preserves asymmetric origins and rejects collapsed or overflowing maps" {
    const outer: Transform = .{ .translation = .{ .x = 17, .y = -9 }, .scale = 1.5, .origin = .{ .x = 8, .y = 4 } };
    const inner: Transform = .{ .translation = .{ .x = -3, .y = 11 }, .scale = 0.5, .origin = .{ .x = 10, .y = -6 } };
    const combined = try outer.compose(inner);
    // Inner maps (6,14) to (5,15); outer maps that to (20.5,11.5).
    try std.testing.expectEqual(PointF{ .x = 20.5, .y = 11.5 }, combined.point(.{ .x = 6, .y = 14 }));
    try std.testing.expectEqual(PointF{ .x = 6, .y = 14 }, combined.inversePoint(.{ .x = 20.5, .y = 11.5 }));
    try std.testing.expectEqual(RectF{ .x = 20.5, .y = 11.5, .width = 9, .height = 5.25 }, combined.rect(.{ .x = 6, .y = 14, .width = 12, .height = 7 }));
    for ([_]f32{ 0, -1, std.math.inf(f32), std.math.nan(f32), std.math.floatTrueMin(f32) }) |bad|
        try std.testing.expectError(error.InvalidTransform, (Transform{ .scale = bad }).validate());
    try std.testing.expectError(error.InvalidTransform, (Transform{ .origin = .{ .y = std.math.inf(f32) } }).validate());
    try std.testing.expectError(error.InvalidTransform, (Transform{ .scale = 1e30 }).compose(.{ .scale = 1e20 }));
    try std.testing.expectError(error.InvalidTransform, (Transform{ .scale = 1e-30 }).compose(.{ .scale = 1e-20 }));
    try std.testing.expectError(error.InvalidTransform, (Transform{ .translation = .{ .x = std.math.floatMax(f32) } }).compose(.{ .translation = .{ .x = std.math.floatMax(f32) } }));
}

test "rounded logical hit contours clamp oversized radii and retain half-open edges" {
    const rect: RectF = .{ .x = -3, .y = 7, .width = 30, .height = 20 };
    try std.testing.expect(!rect.containsRounded(.{ .x = -2, .y = 8 }, 10));
    try std.testing.expect(rect.containsRounded(.{ .x = -2, .y = 8 }, 0));
    // Radius10, center(7,17): the3-4-5 scaled boundary at(1,9).
    try std.testing.expect(rect.containsRounded(.{ .x = 1, .y = 9 }, 100));
    try std.testing.expect(!rect.containsRounded(.{ .x = 0.99, .y = 9 }, 100));
    try std.testing.expect(rect.containsRounded(.{ .x = 7, .y = 7 }, 100));
    try std.testing.expect(!rect.containsRounded(.{ .x = 27, .y = 17 }, 100));
    try std.testing.expect(!rect.containsRounded(.{ .x = 7, .y = 27 }, 100));
}
