//! Image fit and sampling contract shared by both backends. Pixel centers map
//! to texel centers; edges clamp. Decode texels before filtering in linear light.
const std = @import("std");
const scene = @import("../scene/root.zig");
const Bitmap = @import("../image/pixels.zig").Bitmap;
const Pixel = @import("../core/color.zig").LinearRgba16;

pub const Placement = struct {
    left: f32,
    top: f32,
    width: f32,
    height: f32,

    pub fn init(command: scene.Image, bitmap: *const Bitmap) Placement {
        var width: f32 = @floatFromInt(command.bounds.width);
        var height: f32 = @floatFromInt(command.bounds.height);
        if (command.fit != .fill) {
            const iw: f32 = @floatFromInt(bitmap.intrinsic_width);
            const ih: f32 = @floatFromInt(bitmap.intrinsic_height);
            const scale = if (command.fit == .contain) @min(width / iw, height / ih) else @max(width / iw, height / ih);
            width = iw * scale;
            height = ih * scale;
        }
        return .{
            .left = @as(f32, @floatFromInt(command.bounds.x)) + (@as(f32, @floatFromInt(command.bounds.width)) - width) * 0.5,
            .top = @as(f32, @floatFromInt(command.bounds.y)) + (@as(f32, @floatFromInt(command.bounds.height)) - height) * 0.5,
            .width = width,
            .height = height,
        };
    }

    pub fn sample(self: Placement, bitmap: *const Bitmap, x: usize, y: usize) ?Pixel {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - self.left;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - self.top;
        if (dx < 0 or dy < 0 or dx >= self.width or dy >= self.height) return null;
        const sx = std.math.clamp(dx / self.width * @as(f32, @floatFromInt(bitmap.width)) - 0.5, 0, @as(f32, @floatFromInt(bitmap.width - 1)));
        const sy = std.math.clamp(dy / self.height * @as(f32, @floatFromInt(bitmap.height)) - 0.5, 0, @as(f32, @floatFromInt(bitmap.height - 1)));
        const x0: usize = @intFromFloat(@floor(sx));
        const y0: usize = @intFromFloat(@floor(sy));
        const x1 = @min(x0 + 1, bitmap.width - 1);
        const y1 = @min(y0 + 1, bitmap.height - 1);
        const fx: u32 = @intFromFloat(@floor((sx - @floor(sx)) * 256 + 0.5));
        const fy: u32 = @intFromFloat(@floor((sy - @floor(sy)) * 256 + 0.5));
        const aa = texel(bitmap, x0, y0);
        const ba = texel(bitmap, x1, y0);
        const ab = texel(bitmap, x0, y1);
        const bb = texel(bitmap, x1, y1);
        var channels: [4]u16 = undefined;
        for (&channels, 0..) |*value, channel| {
            const a: u32 = aa[channel];
            const b: u32 = ba[channel];
            const c: u32 = ab[channel];
            const d: u32 = bb[channel];
            value.* = @intCast(((a * (256 - fx) + b * fx) * (256 - fy) + (c * (256 - fx) + d * fx) * fy + 32768) / 65536);
        }
        return .{ .r = channels[0], .g = channels[1], .b = channels[2], .a = channels[3] };
    }
};

fn texel(bitmap: *const Bitmap, x: usize, y: usize) [4]u16 {
    const bytes = bitmap.pixels[(y * bitmap.width + x) * 4 ..][0..4];
    const pixel = Pixel.fromSrgba8(.{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] });
    return .{ pixel.r, pixel.g, pixel.b, pixel.a };
}
