const std = @import("std");

pub const Fit = enum { contain, cover, fill };

/// Owned tightly packed premultiplied encoded-sRGB RGBA8 pixels. Intrinsic
/// dimensions describe the oriented asset before SVG raster sizing.
pub const Bitmap = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,
    intrinsic_width: u32,
    intrinsic_height: u32,

    pub fn deinit(self: *Bitmap) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};
