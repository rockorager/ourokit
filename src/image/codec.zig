//! Synchronous PNG/JPEG (Wuffs), WebP (libwebp), and static SVG (resvg) decoding.
//! Pixels are tightly packed premultiplied encoded-sRGB RGBA8. Embedded ICC
//! profiles are ignored; this is not a color-management or linear-light API.
//! Raster images retain native size; JPEG orientation is applied before reporting
//! intrinsic dimensions. SVG sizes describe its viewport, before raster sizing.
//! SVG image references (including data URLs) and fonts are disabled. Convert
//! text to paths. Local fragment references within the SVG remain supported.
//! Limits bound dimensions and each decoded output buffer, not total parser,
//! filter, or decoder working memory. Native library allocation failures may
//! terminate the process (Rust's standard allocation policy).
const std = @import("std");
const core = @import("../core/root.zig");
pub const Bitmap = @import("pixels.zig").Bitmap;

pub const Options = struct {
    /// SVG resolution hints only. Preserve intrinsic aspect ratio, choosing the
    /// larger scale when both are set; fitting belongs to the renderer.
    width: ?u32 = null,
    height: ?u32 = null,
    /// Finite positive SVG fallback scale when neither dimension is specified.
    scale: f32 = 1,
    /// Replace RGB with this color, multiplying its alpha by the source mask.
    tint: ?core.Color = null,
    max_decoded_bytes: usize = 64 * 1024 * 1024,
    max_dimension: u32 = 8192,
};

const Raster = opaque {};
const Svg = opaque {};
extern fn ourokit_raster_open([*]const u8, usize, c_int, *?*Raster, *u32, *u32) c_int;
extern fn ourokit_raster_close(*Raster) void;
extern fn ourokit_raster_render(*Raster, [*]u8, usize) c_int;
extern fn ourokit_svg_open([*]const u8, usize, *f32, *f32) ?*Svg;
extern fn ourokit_svg_close(*Svg) void;
extern fn ourokit_svg_render(*Svg, [*]u8, usize, u32, u32, f32) bool;

pub fn decode(allocator: std.mem.Allocator, encoded: []const u8, options: Options) !Bitmap {
    const kind: c_int = if (std.mem.startsWith(u8, encoded, "\x89PNG\r\n\x1a\n")) 1 else if (std.mem.startsWith(u8, encoded, "\xff\xd8")) 2 else if (encoded.len >= 12 and std.mem.eql(u8, encoded[0..4], "RIFF") and std.mem.eql(u8, encoded[8..12], "WEBP")) 3 else 0;
    var bitmap = if (kind == 0)
        try decodeSvg(allocator, encoded, options)
    else
        try decodeRaster(allocator, encoded, kind, options);
    if (options.tint) |tint| {
        var i: usize = 0;
        while (i < bitmap.pixels.len) : (i += 4) {
            const alpha = multiply(bitmap.pixels[i + 3], tint.a);
            bitmap.pixels[i..][0..4].* = .{ multiply(tint.r, alpha), multiply(tint.g, alpha), multiply(tint.b, alpha), alpha };
        }
    }
    return bitmap;
}

fn outputSize(width: u32, height: u32, options: Options) !usize {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    if (width > options.max_dimension or height > options.max_dimension) return error.ImageTooLarge;
    const count = std.math.mul(usize, width, height) catch return error.ImageTooLarge;
    const bytes = std.math.mul(usize, count, 4) catch return error.ImageTooLarge;
    if (bytes > options.max_decoded_bytes) return error.ImageTooLarge;
    return bytes;
}

fn status(value: c_int) !void {
    return switch (value) {
        0 => {},
        2 => error.OutOfMemory,
        3 => error.ImageTooLarge,
        else => error.InvalidImage,
    };
}

fn decodeRaster(allocator: std.mem.Allocator, encoded: []const u8, kind: c_int, options: Options) !Bitmap {
    var handle: ?*Raster = null;
    var width: u32 = 0;
    var height: u32 = 0;
    try status(ourokit_raster_open(encoded.ptr, encoded.len, kind, &handle, &width, &height));
    defer ourokit_raster_close(handle.?);
    const len = try outputSize(width, height, options);
    var pixels = try allocator.alloc(u8, len);
    errdefer allocator.free(pixels);
    try status(ourokit_raster_render(handle.?, pixels.ptr, pixels.len));
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        for (pixels[i..][0..3]) |*channel| channel.* = multiply(channel.*, pixels[i + 3]);
    }
    const orientation = if (kind == 2) jpegOrientation(encoded) else 1;
    if (orientation != 1) {
        const oriented = try orient(allocator, pixels, width, height, orientation);
        allocator.free(pixels);
        pixels = oriented;
        if (orientation >= 5) std.mem.swap(u32, &width, &height);
    }
    return .{ .allocator = allocator, .pixels = pixels, .width = width, .height = height, .intrinsic_width = width, .intrinsic_height = height };
}

fn dimension(value: f64, options: Options) !u32 {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidDimensions;
    const rounded = @ceil(value);
    if (rounded > @as(f64, @floatFromInt(options.max_dimension))) return error.ImageTooLarge;
    return @intFromFloat(rounded);
}

fn decodeSvg(allocator: std.mem.Allocator, encoded: []const u8, options: Options) !Bitmap {
    if (!std.math.isFinite(options.scale) or options.scale <= 0) return error.InvalidDimensions;
    if (options.width == 0 or options.height == 0) return error.InvalidDimensions;
    var intrinsic_width: f32 = 0;
    var intrinsic_height: f32 = 0;
    const handle = ourokit_svg_open(encoded.ptr, encoded.len, &intrinsic_width, &intrinsic_height) orelse return error.InvalidImage;
    defer ourokit_svg_close(handle);
    const iw = try dimension(intrinsic_width, options);
    const ih = try dimension(intrinsic_height, options);
    const sx: f64 = if (options.width) |w| @as(f64, @floatFromInt(w)) / intrinsic_width else 0;
    const sy: f64 = if (options.height) |h| @as(f64, @floatFromInt(h)) / intrinsic_height else 0;
    const scale: f64 = if (options.width == null and options.height == null) options.scale else @max(sx, sy);
    const width = try dimension(@as(f64, intrinsic_width) * scale, options);
    const height = try dimension(@as(f64, intrinsic_height) * scale, options);
    const len = try outputSize(width, height, options);
    const render_scale: f32 = @floatCast(scale);
    if (!std.math.isFinite(render_scale) or render_scale <= 0) return error.InvalidDimensions;
    const pixels = try allocator.alloc(u8, len);
    errdefer allocator.free(pixels);
    if (!ourokit_svg_render(handle, pixels.ptr, pixels.len, width, height, render_scale)) return error.InvalidImage;
    return .{ .allocator = allocator, .pixels = pixels, .width = width, .height = height, .intrinsic_width = iw, .intrinsic_height = ih };
}

fn multiply(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * alpha + 127) / 255);
}

// JPEG APP1/TIFF parsing is independent of the decoder. Ignore malformed or
// unknown EXIF metadata without trusting offsets or rejecting valid image data.
fn jpegOrientation(encoded: []const u8) u8 {
    var pos: usize = 2;
    while (pos < encoded.len) {
        if (encoded[pos] != 0xff) break;
        while (pos < encoded.len and encoded[pos] == 0xff) : (pos += 1) {}
        if (pos == encoded.len) break;
        const marker = encoded[pos];
        pos += 1;
        if (marker == 0xda or marker == 0xd9) break;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd8)) continue;
        if (encoded.len - pos < 2) break;
        const len = std.mem.readInt(u16, encoded[pos..][0..2], .big);
        if (len < 2 or len > encoded.len - pos) break;
        const payload = encoded[pos + 2 .. pos + len];
        if (marker == 0xe1 and std.mem.startsWith(u8, payload, "Exif\x00\x00")) {
            if (tiffOrientation(payload[6..])) |orientation| return orientation;
        }
        pos += len;
    }
    return 1;
}

fn tiffOrientation(data: []const u8) ?u8 {
    if (data.len < 8) return null;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, data[0..2], "II")) .little else if (std.mem.eql(u8, data[0..2], "MM")) .big else return null;
    if (std.mem.readInt(u16, data[2..4], endian) != 42) return null;
    const offset = std.mem.readInt(u32, data[4..8], endian);
    if (offset > data.len or data.len - offset < 2) return null;
    var entries = data[offset..];
    const count = std.mem.readInt(u16, entries[0..2], endian);
    entries = entries[2..];
    if (count > entries.len / 12) return null;
    for (0..count) |i| {
        const entry = entries[i * 12 ..][0..12];
        if (std.mem.readInt(u16, entry[0..2], endian) != 0x112) continue;
        if (std.mem.readInt(u16, entry[2..4], endian) != 3 or std.mem.readInt(u32, entry[4..8], endian) != 1) return null;
        const orientation = std.mem.readInt(u16, entry[8..10], endian);
        return if (orientation >= 1 and orientation <= 8) @intCast(orientation) else null;
    }
    return null;
}

fn orient(allocator: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, orientation: u8) ![]u8 {
    const output = try allocator.alloc(u8, pixels.len);
    const stride = if (orientation >= 5) height else width;
    for (0..height) |y| {
        for (0..width) |x| {
            const dest: [2]usize = switch (orientation) {
                2 => .{ width - 1 - x, y },
                3 => .{ width - 1 - x, height - 1 - y },
                4 => .{ x, height - 1 - y },
                5 => .{ y, x },
                6 => .{ height - 1 - y, x },
                7 => .{ height - 1 - y, width - 1 - x },
                8 => .{ y, width - 1 - x },
                else => unreachable,
            };
            output[(dest[1] * stride + dest[0]) * 4 ..][0..4].* = pixels[(y * width + x) * 4 ..][0..4].*;
        }
    }
    return output;
}

test {
    _ = @import("codec_tests.zig");
}
