/// Unassociated (straight-alpha), 8-bit desktop color. RGB uses BT.709/sRGB
/// primaries and a pure gamma-2.2 display transfer; alpha is linear.
///
/// Scene and design values use this representation. Raster backends convert it
/// to premultiplied linear-light working storage before compositing; this type is
/// never copied directly into an alpha-bearing pixel buffer.
pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn premultiplied(self: Color) PremultipliedGamma22Rgba8 {
        return .{
            .r = multiply(self.r, self.a),
            .g = multiply(self.g, self.a),
            .b = multiply(self.b, self.a),
            .a = self.a,
        };
    }
};

/// Premultiplied encoded-sRGB interchange pixels, not a blending space. This is
/// retained for decoded images and other explicitly sRGB interchange data.
pub const PremultipliedSrgba8 = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

/// Premultiplied gamma-2.2 desktop presentation pixels. Wayland buffers use
/// this untagged ordinary-graphics representation.
pub const PremultipliedGamma22Rgba8 = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

/// Converts desktop presentation storage to straight sRGB interchange bytes,
/// suitable for PNG export. Alpha is only unassociated, never transferred.
pub fn gamma22ToStraightSrgba8(pixel: PremultipliedGamma22Rgba8) [4]u8 {
    if (pixel.a == 0) return .{ 0, 0, 0, 0 };
    const alpha: f64 = @floatFromInt(pixel.a);
    // Quantize only after conversion to straight sRGB. An intermediate
    // premultiplied byte would discard most precision at small alpha.
    return .{
        quantize8(encodeSrgb(decodeGamma22(@min(@as(f64, @floatFromInt(pixel.r)) / alpha, 1)))),
        quantize8(encodeSrgb(decodeGamma22(@min(@as(f64, @floatFromInt(pixel.g)) / alpha, 1)))),
        quantize8(encodeSrgb(decodeGamma22(@min(@as(f64, @floatFromInt(pixel.b)) / alpha, 1)))),
        pixel.a,
    };
}

/// Linear-light, premultiplied RGBA16 UNORM working storage. Alpha and coverage
/// are linear quantities; neither passes through a transfer function.
pub const LinearRgba16 = extern struct {
    r: u16,
    g: u16,
    b: u16,
    a: u16,

    pub const transparent: LinearRgba16 = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn fromColor(color: Color) LinearRgba16 {
        const alpha = @as(f64, @floatFromInt(color.a)) / 255;
        return .{
            .r = quantize16(decoded_gamma22[color.r] * alpha),
            .g = quantize16(decoded_gamma22[color.g] * alpha),
            .b = quantize16(decoded_gamma22[color.b] * alpha),
            .a = @as(u16, color.a) * 257,
        };
    }

    pub fn fromSrgba8(pixel: PremultipliedSrgba8) LinearRgba16 {
        if (pixel.a == 0) return transparent;
        if (pixel.a == 255) return .{
            .r = decoded_srgb[pixel.r],
            .g = decoded_srgb[pixel.g],
            .b = decoded_srgb[pixel.b],
            .a = 65535,
        };
        const alpha: f64 = @floatFromInt(pixel.a);
        return .{
            .r = quantize16(decodeSrgb(@min(@as(f64, @floatFromInt(pixel.r)) / alpha, 1)) * alpha / 255),
            .g = quantize16(decodeSrgb(@min(@as(f64, @floatFromInt(pixel.g)) / alpha, 1)) * alpha / 255),
            .b = quantize16(decodeSrgb(@min(@as(f64, @floatFromInt(pixel.b)) / alpha, 1)) * alpha / 255),
            .a = @as(u16, pixel.a) * 257,
        };
    }

    pub fn toSrgba8(self: LinearRgba16) PremultipliedSrgba8 {
        if (self.a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (self.a == 65535) return .{ .r = encodeOpaque(self.r), .g = encodeOpaque(self.g), .b = encodeOpaque(self.b), .a = 255 };
        const alpha: f64 = @floatFromInt(self.a);
        return .{
            .r = quantize8(encodeSrgb(@min(@as(f64, @floatFromInt(self.r)) / alpha, 1)) * alpha / 65535),
            .g = quantize8(encodeSrgb(@min(@as(f64, @floatFromInt(self.g)) / alpha, 1)) * alpha / 65535),
            .b = quantize8(encodeSrgb(@min(@as(f64, @floatFromInt(self.b)) / alpha, 1)) * alpha / 65535),
            .a = quantize8(alpha / 65535),
        };
    }

    pub fn fromGamma22Rgba8(pixel: PremultipliedGamma22Rgba8) LinearRgba16 {
        if (pixel.a == 0) return transparent;
        if (pixel.a == 255) return fromColor(Color.rgba(pixel.r, pixel.g, pixel.b, 255));
        const alpha: f64 = @floatFromInt(pixel.a);
        return .{
            .r = quantize16(decodeGamma22(@min(@as(f64, @floatFromInt(pixel.r)) / alpha, 1)) * alpha / 255),
            .g = quantize16(decodeGamma22(@min(@as(f64, @floatFromInt(pixel.g)) / alpha, 1)) * alpha / 255),
            .b = quantize16(decodeGamma22(@min(@as(f64, @floatFromInt(pixel.b)) / alpha, 1)) * alpha / 255),
            .a = @as(u16, pixel.a) * 257,
        };
    }

    pub fn toGamma22Rgba8(self: LinearRgba16) PremultipliedGamma22Rgba8 {
        if (self.a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (self.a == 65535) return .{ .r = encodeGamma22Opaque(self.r), .g = encodeGamma22Opaque(self.g), .b = encodeGamma22Opaque(self.b), .a = 255 };
        const alpha: f64 = @floatFromInt(self.a);
        return .{
            .r = quantize8(encodeGamma22(@min(@as(f64, @floatFromInt(self.r)) / alpha, 1)) * alpha / 65535),
            .g = quantize8(encodeGamma22(@min(@as(f64, @floatFromInt(self.g)) / alpha, 1)) * alpha / 65535),
            .b = quantize8(encodeGamma22(@min(@as(f64, @floatFromInt(self.b)) / alpha, 1)) * alpha / 65535),
            .a = quantize8(alpha / 65535),
        };
    }

    pub fn scaled(self: LinearRgba16, coverage: u16) LinearRgba16 {
        return .{ .r = multiply16(self.r, coverage), .g = multiply16(self.g, coverage), .b = multiply16(self.b, coverage), .a = multiply16(self.a, coverage) };
    }

    pub fn plus(self: LinearRgba16, other: LinearRgba16) LinearRgba16 {
        return .{ .r = self.r +| other.r, .g = self.g +| other.g, .b = self.b +| other.b, .a = self.a +| other.a };
    }

    pub fn over(self: LinearRgba16, destination: LinearRgba16) LinearRgba16 {
        return self.plus(destination.scaled(65535 - self.a));
    }
};

const std = @import("std");

fn decodeSrgb(encoded: f64) f64 {
    return if (encoded <= 0.04045) encoded / 12.92 else std.math.pow(f64, (encoded + 0.055) / 1.055, 2.4);
}

fn encodeSrgb(linear: f64) f64 {
    return if (linear <= 0.0031308) linear * 12.92 else 1.055 * std.math.pow(f64, linear, 1.0 / 2.4) - 0.055;
}

fn decodeGamma22(encoded: f64) f64 {
    return std.math.pow(f64, encoded, 2.2);
}

fn encodeGamma22(linear: f64) f64 {
    return std.math.pow(f64, linear, 1.0 / 2.2);
}

// Keep opaque image sampling lookup-based after separating image and UI
// transfers; four bilinear texels must not introduce twelve pow() calls.
const decoded_srgb = blk: {
    @setEvalBranchQuota(100000);
    var values: [256]u16 = undefined;
    for (&values, 0..) |*value, i| value.* = quantize16(decodeSrgb(@as(f64, @floatFromInt(i)) / 255));
    break :blk values;
};

const decoded_gamma22 = blk: {
    @setEvalBranchQuota(100000);
    var values: [256]f64 = undefined;
    for (&values, 0..) |*value, i| value.* = decodeGamma22(@as(f64, @floatFromInt(i)) / 255);
    break :blk values;
};

// Populate the 64 KiB encode table from exact quantization boundaries. Three
// lookups per opaque presentation pixel avoid pow() and binary searches.
const encode_table = blk: {
    @setEvalBranchQuota(200000);
    var values: [65536]u8 = undefined;
    var start: usize = 0;
    for (0..255) |channel| {
        const end: usize = @intFromFloat(@ceil(decodeSrgb((@as(f64, @floatFromInt(channel)) + 0.5) / 255) * 65535));
        @memset(values[start..end], @intCast(channel));
        start = end;
    }
    @memset(values[start..], 255);
    break :blk values;
};

const encode_gamma22_table = blk: {
    @setEvalBranchQuota(200000);
    var values: [65536]u8 = undefined;
    var start: usize = 0;
    for (0..255) |channel| {
        const end: usize = @intFromFloat(@ceil(decodeGamma22((@as(f64, @floatFromInt(channel)) + 0.5) / 255) * 65535));
        @memset(values[start..end], @intCast(channel));
        start = end;
    }
    @memset(values[start..], 255);
    break :blk values;
};

fn encodeOpaque(value: u16) u8 {
    return encode_table[value];
}

fn encodeGamma22Opaque(value: u16) u8 {
    return encode_gamma22_table[value];
}

fn quantize16(value: f64) u16 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 65535));
}

fn quantize8(value: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn multiply16(channel: u16, alpha: u16) u16 {
    return @intCast((@as(u32, channel) * alpha + 32767) / 65535);
}

fn multiply(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * alpha + 127) / 255);
}

test "straight color converts to rounded premultiplied storage" {
    try std.testing.expectEqual(
        PremultipliedGamma22Rgba8{ .r = 100, .g = 50, .b = 25, .a = 128 },
        Color.rgba(199, 100, 50, 128).premultiplied(),
    );
}

test "desktop compositing applies gamma 2.2 to RGB but not alpha or coverage" {
    const black = LinearRgba16.fromColor(Color.rgba(0, 0, 0, 255));
    const white = LinearRgba16.fromColor(Color.rgba(255, 255, 255, 255));
    const half_white = white.scaled(32768);
    try std.testing.expectEqual(PremultipliedGamma22Rgba8{ .r = 186, .g = 186, .b = 186, .a = 255 }, half_white.over(black).toGamma22Rgba8());
    try std.testing.expectEqual(PremultipliedGamma22Rgba8{ .r = 186, .g = 186, .b = 186, .a = 255 }, black.scaled(32768).over(white).toGamma22Rgba8());
    // Transparent presentation is encoded THEN premultiplied, not an encoding
    // of premultiplied linear channels (which would yield 186 RGB).
    try std.testing.expectEqual(PremultipliedGamma22Rgba8{ .r = 128, .g = 128, .b = 128, .a = 128 }, half_white.toGamma22Rgba8());
    const foreground = LinearRgba16.fromColor(Color.rgba(200, 100, 50, 128));
    const background = LinearRgba16.fromColor(Color.rgba(20, 40, 60, 255));
    try std.testing.expectEqual(PremultipliedGamma22Rgba8{ .r = 147, .g = 77, .b = 55, .a = 255 }, foreground.over(background).toGamma22Rgba8());
}

test "sRGB interchange conversion remains piecewise and preserves dark shades" {
    // Exhaust every valid channel/alpha pair, especially low-alpha colors.
    for (1..256) |a| for (0..a + 1) |channel| {
        const pixel: PremultipliedSrgba8 = .{ .r = @intCast(channel), .g = 0, .b = 0, .a = @intCast(a) };
        try std.testing.expectEqual(pixel, LinearRgba16.fromSrgba8(pixel).toSrgba8());
    };
    const dark = LinearRgba16.fromSrgba8(.{ .r = 1, .g = 2, .b = 3, .a = 255 });
    try std.testing.expect(dark.r > 0 and dark.r < dark.g and dark.g < dark.b);
    try std.testing.expectEqual(LinearRgba16.transparent, LinearRgba16.fromSrgba8(.{ .r = 255, .g = 10, .b = 20, .a = 0 }));
}

test "gamma 2.2 presentation quantizes linear light and preserves alpha" {
    for (1..256) |alpha| for (0..alpha + 1) |channel| {
        const pixel: PremultipliedGamma22Rgba8 = .{ .r = @intCast(channel), .g = 0, .b = 0, .a = @intCast(alpha) };
        const a: f64 = @floatFromInt(alpha);
        const c: f64 = @floatFromInt(channel);
        const expected: u16 = @intFromFloat(@floor(std.math.pow(f64, c / a, 2.2) * a / 255 * 65535 + 0.5));
        const linear = LinearRgba16.fromGamma22Rgba8(pixel);
        try std.testing.expectEqual(expected, linear.r);
        const encoded = linear.toGamma22Rgba8();
        try std.testing.expectEqual(pixel.a, encoded.a);
        try std.testing.expect(@abs(@as(i16, encoded.r) - pixel.r) <= 1);
    };
    // Code 1 is below half a UNORM16 step; do not distort the transfer
    // function to claim a lossless round trip at the darkest values.
    const dark = LinearRgba16.fromColor(Color.rgba(1, 2, 3, 255));
    try std.testing.expectEqual(LinearRgba16{ .r = 0, .g = 2, .b = 4, .a = 65535 }, dark);
    try std.testing.expectEqual(LinearRgba16.transparent, LinearRgba16.fromGamma22Rgba8(.{ .r = 255, .g = 10, .b = 20, .a = 0 }));
}

test "PNG export converts straight RGB before quantizing at low alpha" {
    try std.testing.expectEqual([4]u8{ 31, 110, 220, 7 }, gamma22ToStraightSrgba8(.{ .r = 1, .g = 3, .b = 6, .a = 7 }));
    try std.testing.expectEqual([4]u8{ 0, 9, 129, 255 }, gamma22ToStraightSrgba8(.{ .r = 1, .g = 17, .b = 128, .a = 255 }));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, gamma22ToStraightSrgba8(.{ .r = 5, .g = 8, .b = 3, .a = 0 }));
}

test "opaque lookup matches the sRGB transfer function at every linear16 level" {
    for (0..65536) |level| {
        const value = @as(f64, @floatFromInt(level)) / 65535;
        const srgb = if (value <= 0.0031308) 12.92 * value else 1.055 * std.math.pow(f64, value, 1.0 / 2.4) - 0.055;
        const expected: u8 = @intFromFloat(@floor(srgb * 255 + 0.5));
        try std.testing.expectEqual(expected, encodeOpaque(@intCast(level)));
    }
}

test "opaque desktop lookup matches independent gamma 2.2 math" {
    for (0..65536) |level| {
        const value = @as(f64, @floatFromInt(level)) / 65535;
        const expected: u8 = @intFromFloat(@floor(std.math.pow(f64, value, 1.0 / 2.2) * 255 + 0.5));
        try std.testing.expectEqual(expected, encodeGamma22Opaque(@intCast(level)));
    }
}
