/// Unassociated (straight-alpha), 8-bit sRGB color.
///
/// Scene and design values use this representation. Raster backends convert it
/// to the destination's premultiplied storage before compositing; this type is
/// never copied directly into an alpha-bearing pixel buffer.
pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn premultiplied(self: Color) PremultipliedSrgba8 {
        return .{
            .r = multiply(self.r, self.a),
            .g = multiply(self.g, self.a),
            .b = multiply(self.b, self.a),
            .a = self.a,
        };
    }
};

/// Premultiplied 8-bit sRGB storage used by the first software target
/// contract. Compositing is deterministic encoded-sRGB source-over. A future
/// color-managed surface must use a distinct format rather than changing this
/// type's meaning.
pub const PremultipliedSrgba8 = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

fn multiply(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * alpha + 127) / 255);
}

test "straight color converts to rounded premultiplied storage" {
    const std = @import("std");
    try std.testing.expectEqual(
        PremultipliedSrgba8{ .r = 100, .g = 50, .b = 25, .a = 128 },
        Color.rgba(199, 100, 50, 128).premultiplied(),
    );
}
