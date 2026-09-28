//! Value-owned, allocation-free linear gradients. Colors are converted to
//! premultiplied linear-light RGBA16 BEFORE interpolation. No native leases,
//! caches, or foreign libraries are needed. Only pad (endpoint-color) extension
//! is supported; points and transforms are not quantized to a subpixel grid.
//!
//! Prepared is a shared CPU/GPU sampling contract, not a GPU buffer ABI. Its
//! fields are read-only after prepare. Upload its already converted colors and
//! UNORM16 stop positions; the shader must use precise separate f32 subtraction,
//! multiplication and addition for projection (no FMA), followed by the exact
//! unsigned integer interpolation below. Quantization also uses f32 arithmetic.
//!
//! Projection coefficients must be finite normal f32 values (or exact zero).
//! Validation rejects endpoint subtraction overflow and coefficients that could
//! overflow projection anywhere in the signed-i32 device-coordinate domain.
//! This rejects extremely short gradients and avoids GPU denormal differences.
//! Sample callers provide finite points with representable f32 intermediates;
//! invalid points/projections defensively return transparent, never trap.
const std = @import("std");
const geometry = @import("../core/geometry.zig");
const color = @import("../core/color.zig");
pub const PointF = geometry.PointF;
pub const Color = color.Color;
pub const LinearRgba16 = color.LinearRgba16;

pub const Stop = struct {
    offset: f32,
    color: Color,
};

const empty_stop: Stop = .{ .offset = 0, .color = Color.rgba(0, 0, 0, 0) };

pub const LinearGradient = struct {
    start: PointF,
    end: PointF,
    stops: [8]Stop,
    count: u32,

    pub fn init(start: PointF, end: PointF, stops: []const Stop) !LinearGradient {
        if (stops.len < 2 or stops.len > 8) return error.InvalidGradient;
        var result: LinearGradient = .{ .start = start, .end = end, .stops = @splat(empty_stop), .count = @intCast(stops.len) };
        @memcpy(result.stops[0..stops.len], stops);
        try result.validate();
        return result;
    }

    pub fn validate(self: LinearGradient) !void {
        if (self.count < 2 or self.count > 8 or !finite(self.start) or !finite(self.end) or
            (self.start.x == self.end.x and self.start.y == self.end.y)) return error.InvalidGradient;
        var previous: f32 = 0;
        for (self.stops[0..self.count]) |stop| {
            if (!std.math.isFinite(stop.offset) or stop.offset < previous or stop.offset > 1) return error.InvalidGradient;
            previous = stop.offset;
        }
        _ = try direction(self.start, self.end);
    }

    pub fn isOpaque(self: LinearGradient) bool {
        if (self.count < 2 or self.count > 8) return false;
        for (self.stops[0..self.count]) |stop| if (stop.color.a != 255) return false;
        return true;
    }

    /// Scale local endpoints, then translate. Positive finite scales only.
    /// f64 intermediates avoid avoidable multiply/add overflow; the resulting
    /// f32 endpoints must remain distinct and have a representable projection.
    pub fn transformed(self: LinearGradient, origin: PointF, scale: f32) !LinearGradient {
        try self.validate();
        if (!finite(origin) or !std.math.isFinite(scale) or scale <= 0) return error.InvalidTransform;
        const start = transform(self.start, origin, scale);
        const end = transform(self.end, origin, scale);
        if (!finite(start) or !finite(end) or (start.x == end.x and start.y == end.y)) return error.InvalidTransform;
        return init(start, end, self.stops[0..self.count]);
    }

    pub fn prepare(self: LinearGradient) !Prepared {
        try self.validate();
        var result: Prepared = .{
            .start = self.start,
            .direction = try direction(self.start, self.end),
            .stops = @splat(.{ .offset = 0, .color = LinearRgba16.transparent }),
            .count = self.count,
        };
        for (self.stops[0..self.count], 0..) |stop, i| {
            result.stops[i] = .{ .offset = quantize(stop.offset), .color = LinearRgba16.fromColor(stop.color) };
        }
        return result;
    }
};

pub const PreparedStop = struct {
    /// UNORM16 in u32 storage; all arithmetic can be copied directly to GLSL.
    offset: u32,
    color: LinearRgba16,
};

pub const Prepared = struct {
    start: PointF,
    direction: PointF,
    stops: [8]PreparedStop,
    count: u32,

    pub fn sample(self: Prepared, point: PointF) LinearRgba16 {
        if (!finite(point)) return LinearRgba16.transparent;
        const projected = project(point, self.start, self.direction);
        if (!std.math.isFinite(projected)) return LinearRgba16.transparent;
        const t = quantize(std.math.clamp(projected, 0, 1));
        // Upper-bound search: the last stop wins AT every duplicate boundary,
        // including distinct f32 offsets that collapse to one UNORM16 value.
        var upper: usize = 0;
        while (upper < self.count and self.stops[upper].offset <= t) : (upper += 1) {}
        if (upper == 0) return self.stops[0].color;
        if (upper == self.count) return self.stops[upper - 1].color;
        const low = self.stops[upper - 1];
        const high = self.stops[upper];
        const span = high.offset - low.offset;
        const distance = t - low.offset;
        return .{
            .r = interpolate(low.color.r, high.color.r, distance, span),
            .g = interpolate(low.color.g, high.color.g, distance, span),
            .b = interpolate(low.color.b, high.color.b, distance, span),
            .a = interpolate(low.color.a, high.color.a, distance, span),
        };
    }
};

fn finite(point: PointF) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn transform(point: PointF, origin: PointF, scale: f32) PointF {
    @setFloatMode(.strict);
    return .{
        .x = @floatCast(@as(f64, point.x) * scale + origin.x),
        .y = @floatCast(@as(f64, point.y) * scale + origin.y),
    };
}

fn direction(start: PointF, end: PointF) !PointF {
    @setFloatMode(.strict);
    const dx = @as(f64, end.x) - start.x;
    const dy = @as(f64, end.y) - start.y;
    const squared_length = dx * dx + dy * dy;
    const result: PointF = .{ .x = @floatCast(dx / squared_length), .y = @floatCast(dy / squared_length) };
    if (!finite(result) or (dx != 0 and @abs(result.x) < std.math.floatMin(f32)) or
        (dy != 0 and @abs(result.y) < std.math.floatMin(f32))) return error.InvalidProjection;
    // Conservatively bound EVERY device pixel, not just the endpoints. Without
    // this, a tiny valid segment could overflow for ordinary nearby pixels.
    const reach_x = 2147483648.0 + @abs(@as(f64, start.x));
    const reach_y = 2147483648.0 + @abs(@as(f64, start.y));
    const max = std.math.floatMax(f32);
    // Leave a factor of two for rounding of the separate f32 operations.
    if (reach_x > max or reach_y > max or
        reach_x * @abs(@as(f64, result.x)) + reach_y * @abs(@as(f64, result.y)) > @as(f64, max) * 0.5 or
        !std.math.isFinite(project(end, start, result))) return error.InvalidProjection;
    return result;
}

fn project(point: PointF, start: PointF, vector: PointF) f32 {
    @setFloatMode(.strict);
    const dx: f32 = point.x - start.x;
    const dy: f32 = point.y - start.y;
    const x: f32 = dx * vector.x;
    const y: f32 = dy * vector.y;
    return x + y;
}

fn quantize(value: f32) u32 {
    @setFloatMode(.strict);
    const scaled: f32 = value * 65535;
    const rounded: f32 = scaled + 0.5;
    return @intFromFloat(@floor(rounded));
}

fn interpolate(a: u16, b: u16, distance: u32, span: u32) u16 {
    // span is nonzero, distance<=span<=65535. The numerator is at most
    // 65535^2+32767=4294868992, so even opaque-white interpolation fits u32.
    return @intCast((@as(u32, a) * (span - distance) + @as(u32, b) * distance + span / 2) / span);
}

const red = Color.rgba(255, 0, 0, 255);
const green = Color.rgba(0, 255, 0, 255);
const blue = Color.rgba(0, 0, 255, 255);
const test_stops = [_]Stop{ .{ .offset = 0, .color = red }, .{ .offset = 1, .color = blue } };

test "paint independent asymmetric linear-light premultiplied golden samples" {
    const gradient = try LinearGradient.init(.{ .x = -2, .y = 3 }, .{ .x = 6, .y = 3 }, &.{
        .{ .offset = 0, .color = Color.rgba(128, 64, 32, 192) },
        .{ .offset = 1, .color = Color.rgba(16, 200, 250, 85) },
    });
    const prepared = try gradient.prepare();
    // Independently evaluated sRGB transfer, alpha premultiplication, and
    // integer weights at t=1/4 (UNORM16=16384). Not derived from fromColor.
    try std.testing.expectEqual(LinearRgba16{ .r = 8016, .g = 5052, .b = 5756, .a = 42469 }, prepared.sample(.{ .x = 0, .y = 99 }));
    try std.testing.expect(!gradient.isOpaque());
}

test "paint transparent blue does not tint opaque red interpolation" {
    const gradient = try LinearGradient.init(.{}, .{ .x = 8 }, &.{
        .{ .offset = 0, .color = red },
        .{ .offset = 1, .color = Color.rgba(0, 0, 255, 0) },
    });
    const p = try gradient.prepare();
    try std.testing.expectEqual(LinearRgba16{ .r = 49151, .g = 0, .b = 0, .a = 49151 }, p.sample(.{ .x = 2 }));
    try std.testing.expectEqual(LinearRgba16{ .r = 32767, .g = 0, .b = 0, .a = 32767 }, p.sample(.{ .x = 4 }));
    try std.testing.expectEqual(LinearRgba16.transparent, p.sample(.{ .x = 9 }));
    const white = try LinearGradient.init(.{}, .{ .x = 1 }, &.{
        .{ .offset = 0, .color = Color.rgba(255, 255, 255, 255) },
        .{ .offset = 1, .color = Color.rgba(255, 255, 255, 255) },
    });
    try std.testing.expectEqual(LinearRgba16{ .r = 65535, .g = 65535, .b = 65535, .a = 65535 }, (try white.prepare()).sample(.{ .x = 0.731 }));
}

test "paint duplicate stops and quantization collisions select last at boundary" {
    const gradient = try LinearGradient.init(.{}, .{ .x = 1 }, &.{
        .{ .offset = 0.25, .color = red },
        .{ .offset = 0.5, .color = green },
        .{ .offset = 0.5, .color = blue },
        .{ .offset = 0.500001, .color = red },
        .{ .offset = 0.75, .color = green },
    });
    const p = try gradient.prepare();
    try std.testing.expectEqual(@as(u32, 32768), p.stops[3].offset);
    try std.testing.expectEqual(LinearRgba16{ .r = 65535, .g = 0, .b = 0, .a = 65535 }, p.sample(.{ .x = 0.5 }));
    try std.testing.expectEqual(LinearRgba16{ .r = 4, .g = 65531, .b = 0, .a = 65535 }, p.sample(.{ .x = 32767.0 / 65535.0 }));
    try std.testing.expectEqual(LinearRgba16{ .r = 65535, .g = 0, .b = 0, .a = 65535 }, p.sample(.{ .x = -5 }));
    try std.testing.expectEqual(LinearRgba16{ .r = 0, .g = 65535, .b = 0, .a = 65535 }, p.sample(.{ .x = 5 }));
    const collapsed = try LinearGradient.init(.{}, .{ .x = 1 }, &.{
        .{ .offset = 0.25, .color = red },
        .{ .offset = 0.25, .color = blue },
    });
    const q = try collapsed.prepare();
    try std.testing.expectEqual(LinearRgba16{ .r = 65535, .g = 0, .b = 0, .a = 65535 }, q.sample(.{ .x = 0.249 }));
    try std.testing.expectEqual(LinearRgba16{ .r = 0, .g = 0, .b = 65535, .a = 65535 }, q.sample(.{ .x = 0.25 }));
}

test "paint reversed diagonal and fractional transformed coordinates" {
    const gradient = try LinearGradient.init(.{ .x = 6, .y = -3 }, .{ .x = -2, .y = 1 }, &test_stops);
    const p = try gradient.prepare();
    // (-3,1) dot (-.1,.05)=.35; f32 projection quantizes to22937.
    try std.testing.expectEqual(LinearRgba16{ .r = 42598, .g = 0, .b = 22937, .a = 65535 }, p.sample(.{ .x = 3, .y = -2 }));
    const moved = try gradient.transformed(.{ .x = -11.25, .y = 7.5 }, 1.5);
    try std.testing.expectEqual(PointF{ .x = -2.25, .y = 3 }, moved.start);
    try std.testing.expectEqual(PointF{ .x = -14.25, .y = 9 }, moved.end);
    try std.testing.expectEqual(LinearRgba16{ .r = 42598, .g = 0, .b = 22937, .a = 65535 }, (try moved.prepare()).sample(.{ .x = -6.75, .y = 4.5 }));
    try std.testing.expect(gradient.isOpaque());
}

test "paint projection keeps separate f32 operations rather than FMA" {
    const gradient = try LinearGradient.init(.{}, .{ .x = 17, .y = 13 }, &test_stops);
    const p = try gradient.prepare();
    // Independent binary32 reference: separate products sum to0.781254291534,
    // quantizing to51200. Fusing the x multiply/add gives0.781254231930 and
    // quantizes to51199 instead; this asymmetric point detects that change.
    try std.testing.expectEqual(LinearRgba16{ .r = 14335, .g = 0, .b = 51200, .a = 65535 }, p.sample(.{ .x = 16.0810546875, .y = 6.4951171875 }));
}

test "paint copies stops and initializes unused storage deterministically" {
    var stops = test_stops;
    const gradient = try LinearGradient.init(.{}, .{ .y = 4 }, &stops);
    stops[0].color = green;
    try std.testing.expectEqual(red, gradient.stops[0].color);
    const p = try gradient.prepare();
    for (gradient.stops[2..]) |stop| try std.testing.expectEqual(empty_stop, stop);
    for (p.stops[2..]) |stop| try std.testing.expectEqual(PreparedStop{ .offset = 0, .color = LinearRgba16.transparent }, stop);
    try std.testing.expectEqual(LinearRgba16{ .r = 49151, .g = 0, .b = 16384, .a = 65535 }, p.sample(.{ .x = 888, .y = 1 }));
    var eight = [_]Stop{test_stops[0]} ** 8;
    eight[7] = .{ .offset = 1, .color = Color.rgba(0, 0, 255, 0) };
    const full = try LinearGradient.init(.{}, .{ .x = 1 }, &eight);
    try std.testing.expectEqual(@as(u32, 8), full.count);
    try std.testing.expect(!full.isOpaque());
    try std.testing.expectEqual(LinearRgba16.transparent, (try full.prepare()).sample(.{ .x = 1 }));
}

test "paint rejects malformed stops endpoints and unrepresentable projections" {
    try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{}, .{ .x = 1 }, &.{}));
    try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{}, .{ .x = 1 }, test_stops[0..1]));
    const too_many = [_]Stop{test_stops[0]} ** 9;
    try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{}, .{ .x = 1 }, &too_many));
    try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{}, .{}, &test_stops));
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{ .x = bad }, .{ .x = 1 }, &test_stops));
        try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{}, .{ .y = bad }, &test_stops));
        var stops = test_stops;
        stops[1].offset = bad;
        try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{}, .{ .x = 1 }, &stops));
    }
    for ([_][2]f32{ .{ -0.001, 1 }, .{ 0, 1.001 }, .{ 0.75, 0.25 } }) |offsets| {
        var stops = test_stops;
        stops[0].offset = offsets[0];
        stops[1].offset = offsets[1];
        try std.testing.expectError(error.InvalidGradient, LinearGradient.init(.{}, .{ .x = 1 }, &stops));
    }
    try std.testing.expectError(error.InvalidProjection, LinearGradient.init(.{}, .{ .x = 1e-30 }, &test_stops));
    try std.testing.expectError(error.InvalidProjection, LinearGradient.init(.{}, .{ .x = 1e38 }, &test_stops));
    try std.testing.expectError(error.InvalidProjection, LinearGradient.init(.{ .x = -3e38 }, .{ .x = 3e38 }, &test_stops));
    _ = try LinearGradient.init(.{}, .{ .x = 1e-28 }, &test_stops);
    _ = try LinearGradient.init(.{}, .{ .x = 1e37 }, &test_stops);
    var invalid = try LinearGradient.init(.{}, .{ .x = 1 }, &test_stops);
    invalid.count = 9;
    try std.testing.expectError(error.InvalidGradient, invalid.validate());
    try std.testing.expectError(error.InvalidGradient, invalid.prepare());
    try std.testing.expect(!invalid.isOpaque());
}

test "paint rejects invalid transforms and handles invalid sample points" {
    const gradient = try LinearGradient.init(.{}, .{ .x = 2 }, &test_stops);
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |scale| {
        try std.testing.expectError(error.InvalidTransform, gradient.transformed(.{}, scale));
    }
    try std.testing.expectError(error.InvalidTransform, gradient.transformed(.{ .y = std.math.nan(f32) }, 1));
    try std.testing.expectError(error.InvalidTransform, gradient.transformed(.{}, std.math.floatMax(f32)));
    try std.testing.expectError(error.InvalidTransform, gradient.transformed(.{ .x = 1e20 }, 1));
    try std.testing.expectError(error.InvalidProjection, gradient.transformed(.{}, 1e-30));
    const p = try gradient.prepare();
    try std.testing.expectEqual(LinearRgba16.transparent, p.sample(.{ .y = std.math.nan(f32) }));
    try std.testing.expectEqual(LinearRgba16.transparent, p.sample(.{ .x = std.math.inf(f32) }));
    const tiny = try LinearGradient.init(.{}, .{ .x = 1e-28, .y = -1e-28 }, &test_stops);
    const q = try tiny.prepare();
    // Finite points outside the guaranteed device domain can produce infinity
    // or inf+-inf; neither may reach float-to-integer conversion.
    try std.testing.expectEqual(LinearRgba16.transparent, q.sample(.{ .x = 1e38 }));
    try std.testing.expectEqual(LinearRgba16.transparent, q.sample(.{ .x = 1e38, .y = 1e38 }));
}
