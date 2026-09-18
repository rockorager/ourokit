const std = @import("std");
const c = @import("freetype_c.zig").ft;
const text = @import("../../text/root.zig");
const Phase = @import("../glyph_position.zig").Phase;
const LinearRgba16 = @import("../../core/color.zig").LinearRgba16;

pub const GlyphBitmap = struct {
    /// A8 coverage, or little-endian premultiplied linear RGBA16 for color glyphs.
    pixels: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32,
    color: bool = false,

    pub fn bytesPerPixel(self: GlyphBitmap) u32 {
        return if (self.color) 8 else 1;
    }

    pub fn colorAt(self: GlyphBitmap, index: usize) LinearRgba16 {
        const pixel = self.pixels[index * 8 ..][0..8];
        return .{
            .r = std.mem.readInt(u16, pixel[0..2], .little),
            .g = std.mem.readInt(u16, pixel[2..4], .little),
            .b = std.mem.readInt(u16, pixel[4..6], .little),
            .a = std.mem.readInt(u16, pixel[6..8], .little),
        };
    }
};

const FaceKey = extern struct {
    slot: u32,
    generation: u32,
};

/// Shared by the CPU mask cache and the Vulkan atlas.
pub const GlyphKey = struct {
    font_slot: u32,
    font_generation: u32,
    glyph: u32,
    size_26_6: i32,
    phase: Phase,

    pub fn init(handle: text.FontHandle, glyph: u32, pixel_size: f32, phase: Phase) !GlyphKey {
        if (!std.math.isFinite(pixel_size) or pixel_size <= 0) return error.InvalidGlyphSize;
        const scaled = pixel_size * 64.0;
        if (@as(f64, scaled) > std.math.maxInt(i32)) return error.InvalidGlyphSize;
        const size_26_6: i32 = @intFromFloat(@round(scaled));
        if (size_26_6 <= 0) return error.InvalidGlyphSize;
        return .{ .font_slot = handle.slot, .font_generation = handle.generation, .glyph = glyph, .size_26_6 = size_26_6, .phase = phase };
    }
};

const FaceEntry = struct {
    handle: text.FontHandle,
    face: c.FT_Face,
};

/// Backend-owned FreeType faces, coverage masks and color glyphs. Font bytes and
/// shaping identity remain owned by the shared text service; this renderer
/// retains every face handle it caches.
pub const GlyphCache = struct {
    allocator: std.mem.Allocator,
    fonts: *text.FontCache,
    library: c.FT_Library,
    faces: std.AutoHashMapUnmanaged(FaceKey, *FaceEntry) = .empty,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, *GlyphBitmap) = .empty,
    pixel_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, fonts: *text.FontCache) !GlyphCache {
        var library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitializationFailed;
        errdefer _ = c.FT_Done_FreeType(library);
        // Adobe's size-dependent darkening compensates for linear-light
        // coverage blending. Do not force experimental auto-hinter darkening
        // onto fallback fonts.
        const engine: c.FT_UInt = c.FT_HINTING_ADOBE;
        const no_darkening: c.FT_Bool = 0;
        for ([_][:0]const u8{ "cff", "type1", "t1cid" }) |module| {
            if (c.FT_Get_Module(library, module.ptr) == null) continue;
            if (c.FT_Property_Set(library, module.ptr, "hinting-engine", &engine) != 0 or
                c.FT_Property_Set(library, module.ptr, "no-stem-darkening", &no_darkening) != 0)
                return error.FreeTypeConfigurationFailed;
        }
        return .{ .allocator = allocator, .fonts = fonts, .library = library };
    }

    pub fn deinit(self: *GlyphCache) void {
        self.clear();
        self.glyphs.deinit(self.allocator);
        var face_iterator = self.faces.valueIterator();
        while (face_iterator.next()) |entry| {
            _ = c.FT_Done_Face(entry.*.face);
            self.fonts.release(entry.*.handle) catch unreachable;
            self.allocator.destroy(entry.*);
        }
        self.faces.deinit(self.allocator);
        _ = c.FT_Done_FreeType(self.library);
        self.* = undefined;
    }

    fn clear(self: *GlyphCache) void {
        var glyph_iterator = self.glyphs.valueIterator();
        while (glyph_iterator.next()) |glyph| {
            self.allocator.free(glyph.*.pixels);
            self.allocator.destroy(glyph.*);
        }
        self.glyphs.clearRetainingCapacity();
        self.pixel_bytes = 0;
    }

    /// Returned masks remain valid until the next cache lookup or deinit.
    pub fn get(
        self: *GlyphCache,
        handle: text.FontHandle,
        glyph: u32,
        pixel_size: f32,
    ) !*const GlyphBitmap {
        return self.getPhase(handle, glyph, pixel_size, .{});
    }

    pub fn getPhase(self: *GlyphCache, handle: text.FontHandle, glyph: u32, pixel_size: f32, phase: Phase) !*const GlyphBitmap {
        const key = try GlyphKey.init(handle, glyph, pixel_size, phase);
        if (self.glyphs.get(key)) |cached| return cached;

        const face_value = try self.face(handle);
        const scalable = face_value.*.face_flags & c.FT_FACE_FLAG_SCALABLE != 0;
        var scale: [2]f64 = .{ 1, 1 };
        if (!scalable and face_value.*.num_fixed_sizes > 0) {
            const strikes = face_value.*.available_sizes[0..@intCast(face_value.*.num_fixed_sizes)];
            var selected: usize = 0;
            for (strikes, 0..) |strike, index| {
                if (@abs(strike.y_ppem - key.size_26_6) < @abs(strikes[selected].y_ppem - key.size_26_6)) selected = index;
            }
            if (c.FT_Select_Size(face_value, @intCast(selected)) != 0) return error.GlyphSizeFailed;
            scale = .{
                @as(f64, @floatFromInt(key.size_26_6)) / @as(f64, @floatFromInt(strikes[selected].x_ppem)),
                @as(f64, @floatFromInt(key.size_26_6)) / @as(f64, @floatFromInt(strikes[selected].y_ppem)),
            };
        } else if (c.FT_Set_Char_Size(face_value, 0, key.size_26_6, 72, 72) != 0)
            return error.GlyphSizeFailed;
        const flags: c.FT_Int32 = @intCast(c.FT_LOAD_TARGET_LIGHT | c.FT_LOAD_COLOR |
            @as(c_long, if (scalable and face_value.*.face_flags & c.FT_FACE_FLAG_COLOR == 0) c.FT_LOAD_NO_BITMAP else 0));
        if (c.FT_Load_Glyph(face_value, glyph, flags) != 0)
            return error.GlyphLoadFailed;
        const is_bitmap = face_value.*.glyph.*.format == c.FT_GLYPH_FORMAT_BITMAP;
        // Translate the loaded/hinted outline, before coverage rasterization.
        // Bearings include this translation; callers add only integer anchors.
        if (face_value.*.glyph.*.format == c.FT_GLYPH_FORMAT_OUTLINE)
            c.FT_Outline_Translate(&face_value.*.glyph.*.outline, phase.x, -@as(c.FT_Pos, phase.y));
        if (c.FT_Render_Glyph(face_value.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0)
            return error.GlyphRenderFailed;
        const source = face_value.*.glyph.*.bitmap;
        const color = source.pixel_mode == c.FT_PIXEL_MODE_BGRA;
        if (!color and source.pixel_mode != c.FT_PIXEL_MODE_GRAY and source.pixel_mode != c.FT_PIXEL_MODE_MONO)
            return error.UnsupportedGlyphBitmap;

        const left = @as(f64, @floatFromInt(face_value.*.glyph.*.bitmap_left)) * scale[0] +
            (if (is_bitmap) @as(f64, @floatFromInt(phase.x)) / 64 else 0);
        const top = -@as(f64, @floatFromInt(face_value.*.glyph.*.bitmap_top)) * scale[1] +
            (if (is_bitmap) @as(f64, @floatFromInt(phase.y)) / 64 else 0);
        const width_f = @ceil(left + @as(f64, @floatFromInt(source.width)) * scale[0]) - @floor(left);
        const height_f = @ceil(top + @as(f64, @floatFromInt(source.rows)) * scale[1]) - @floor(top);
        // Only demanded phases are cached. Bound phase churn (including empty
        // glyphs) without holding 4096 variants per glyph indefinitely.
        const max_bytes = 16 * 1024 * 1024;
        const bpp: u32 = if (color) 8 else 1;
        if (width_f > max_bytes or height_f > max_bytes) return error.GlyphTooLarge;
        const width: u32 = @intFromFloat(width_f);
        const height: u32 = @intFromFloat(height_f);
        const bytes = try std.math.mul(usize, try std.math.mul(usize, width, height), bpp);
        if (bytes > max_bytes) return error.GlyphTooLarge;
        if (self.pixel_bytes + bytes > max_bytes or self.glyphs.count() >= 16384) self.clear();
        const pixels = try self.allocator.alloc(u8, bytes);
        errdefer self.allocator.free(pixels);
        if (color or is_bitmap) {
            resampleBitmap(pixels, width, height, source, scale, .{ left - @floor(left), top - @floor(top) }, color);
        } else copyBitmap(pixels, source);
        const bitmap = try self.allocator.create(GlyphBitmap);
        errdefer self.allocator.destroy(bitmap);
        bitmap.* = .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .left = @intFromFloat(@floor(left)),
            .top = @intFromFloat(-@floor(top)),
            .color = color,
        };
        try self.glyphs.put(self.allocator, key, bitmap);
        self.pixel_bytes += bytes;
        return bitmap;
    }

    fn face(self: *GlyphCache, handle: text.FontHandle) !c.FT_Face {
        const key: FaceKey = .{ .slot = handle.slot, .generation = handle.generation };
        if (self.faces.get(key)) |entry| return entry.face;
        const font = try self.fonts.get(handle);
        const source = font.rasterSource();
        if (source.bytes.len > std.math.maxInt(c.FT_Long)) return error.FontTooLarge;
        var face_value: c.FT_Face = null;
        if (c.FT_New_Memory_Face(
            self.library,
            source.bytes.ptr,
            @intCast(source.bytes.len),
            @intCast(source.face_index),
            &face_value,
        ) != 0) return error.FreeTypeFaceFailed;
        errdefer _ = c.FT_Done_Face(face_value);
        try applyVariations(self.allocator, self.library, face_value, source.variations);
        try self.fonts.retain(handle);
        errdefer self.fonts.release(handle) catch unreachable;
        const entry = try self.allocator.create(FaceEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .handle = handle, .face = face_value };
        try self.faces.put(self.allocator, key, entry);
        return face_value;
    }
};

fn applyVariations(
    allocator: std.mem.Allocator,
    library: c.FT_Library,
    face: c.FT_Face,
    variations: []const text.Font.Variation,
) !void {
    if (variations.len == 0) return;
    var axes: ?*c.FT_MM_Var = null;
    if (c.FT_Get_MM_Var(face, &axes) != 0 or axes == null) return error.FontHasNoVariations;
    defer _ = c.FT_Done_MM_Var(library, axes);
    const coordinates = try allocator.alloc(c.FT_Fixed, axes.?.num_axis);
    defer allocator.free(coordinates);
    if (c.FT_Get_Var_Design_Coordinates(face, axes.?.num_axis, coordinates.ptr) != 0)
        return error.VariationReadFailed;
    for (variations) |variation| {
        var found = false;
        for (axes.?.axis[0..axes.?.num_axis], 0..) |axis, index| {
            if (axis.tag != variation.tag) continue;
            const fixed = @as(f64, variation.value) * 65536.0;
            if (!std.math.isFinite(fixed) or fixed < -2147483648.0 or
                fixed > 2147483647.0) return error.InvalidVariation;
            coordinates[index] = @intFromFloat(@round(fixed));
            found = true;
            break;
        }
        if (!found) return error.InvalidVariationAxis;
    }
    if (c.FT_Set_Var_Design_Coordinates(face, axes.?.num_axis, coordinates.ptr) != 0)
        return error.VariationWriteFailed;
}

/// Area-filter bitmap strikes in premultiplied linear light, with transparent
/// pixels outside the glyph. Include the fractional origin before filtering so
/// bitmap glyphs follow the same subpixel-position contract as outlines.
fn resampleBitmap(destination: []u8, width: u32, height: u32, source: c.FT_Bitmap, scale: [2]f64, offset: [2]f64, color: bool) void {
    for (0..height) |y| for (0..width) |x| {
        const x0 = (@as(f64, @floatFromInt(x)) - offset[0]) / scale[0];
        const x1 = (@as(f64, @floatFromInt(x + 1)) - offset[0]) / scale[0];
        const y0 = (@as(f64, @floatFromInt(y)) - offset[1]) / scale[1];
        const y1 = (@as(f64, @floatFromInt(y + 1)) - offset[1]) / scale[1];
        const first_x: usize = @intFromFloat(@max(0, @floor(x0)));
        const last_x: usize = @intFromFloat(@min(@as(f64, @floatFromInt(source.width)), @ceil(x1)));
        const first_y: usize = @intFromFloat(@max(0, @floor(y0)));
        const last_y: usize = @intFromFloat(@min(@as(f64, @floatFromInt(source.rows)), @ceil(y1)));
        var sum: [4]f64 = .{ 0, 0, 0, 0 };
        for (first_y..@max(first_y, last_y)) |sy| for (first_x..@max(first_x, last_x)) |sx| {
            const weight = (@min(x1, @as(f64, @floatFromInt(sx + 1))) - @max(x0, @as(f64, @floatFromInt(sx)))) *
                (@min(y1, @as(f64, @floatFromInt(sy + 1))) - @max(y0, @as(f64, @floatFromInt(sy)))) * scale[0] * scale[1];
            const pixel = bitmapPixel(source, sx, sy);
            for (&sum, pixel) |*value, channel| value.* += @as(f64, @floatFromInt(channel)) * weight;
        };
        if (color) {
            const output = destination[(y * width + x) * 8 ..][0..8];
            for (sum, 0..) |value, channel| std.mem.writeInt(u16, output[channel * 2 ..][0..2], @intFromFloat(@round(std.math.clamp(value, 0, 65535))), .little);
        } else destination[y * width + x] = @intFromFloat(@round(std.math.clamp(sum[3] / 257, 0, 255)));
    };
}

fn bitmapPixel(source: c.FT_Bitmap, x: usize, y: usize) [4]u16 {
    const pitch: usize = @intCast(if (source.pitch < 0) -source.pitch else source.pitch);
    const row_y = if (source.pitch < 0) source.rows - 1 - y else y;
    const row = source.buffer[row_y * pitch ..][0..pitch];
    if (source.pixel_mode == c.FT_PIXEL_MODE_BGRA) {
        const bgra = row[x * 4 ..][0..4];
        const pixel = LinearRgba16.fromSrgba8(.{ .r = bgra[2], .g = bgra[1], .b = bgra[0], .a = bgra[3] });
        return .{ pixel.r, pixel.g, pixel.b, pixel.a };
    }
    const alpha: u16 = if (source.pixel_mode == c.FT_PIXEL_MODE_MONO)
        (if (row[x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0) @as(u16, 65535) else 0)
    else if (source.num_grays <= 1) 0 else @intCast(@as(u32, row[x]) * 65535 / (source.num_grays - 1));
    return .{ 0, 0, 0, alpha };
}

fn copyBitmap(destination: []u8, source: c.FT_Bitmap) void {
    const pitch_abs: usize = @intCast(if (source.pitch < 0) -source.pitch else source.pitch);
    for (0..source.rows) |y| {
        const source_y = if (source.pitch < 0) source.rows - 1 - y else y;
        const row = source.buffer[source_y * pitch_abs ..][0..pitch_abs];
        const output = destination[y * source.width ..][0..source.width];
        switch (source.pixel_mode) {
            c.FT_PIXEL_MODE_GRAY => for (output, row[0..source.width]) |*pixel, value| {
                pixel.* = if (source.num_grays <= 1)
                    0
                else
                    @intCast((@as(u32, value) * 255) / (source.num_grays - 1));
            },
            c.FT_PIXEL_MODE_MONO => {
                for (output, 0..) |*pixel, x|
                    pixel.* = if (row[x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0) 255 else 0;
            },
            else => unreachable,
        }
    }
}

test "bitmap emoji strikes scale bearings, colors and phases to requested size" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const handle = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/EmojiTest.ttf", .index = 0 },
        .bytes = @embedFile("../../text/fonts/EmojiTest.ttf"),
    });
    defer fonts.release(handle) catch unreachable;
    var cache = try GlyphCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    const face_value = try cache.face(handle);
    // The original crash: a bitmap-only font cannot accept this outline size.
    try std.testing.expect(c.FT_Set_Char_Size(face_value, 0, 14 * 64, 72, 72) != 0);
    const glyph = (try fonts.get(handle)).nominalGlyph('👋').?;
    const small = try cache.get(handle, glyph, 14);
    try std.testing.expect(small.color);
    // The pinned 109 ppem strike has a 136x128 bitmap and top bearing 101.
    try std.testing.expectEqual(@as(u32, 18), small.width);
    try std.testing.expectEqual(@as(u32, 17), small.height);
    try std.testing.expectEqual(@as(i32, 13), small.top);
    try std.testing.expectEqual(@as(i32, 0), small.left);
    var colored = false;
    var partial_alpha = false;
    for (0..small.width * small.height) |index| {
        const pixel = small.colorAt(index);
        colored = colored or (pixel.r > pixel.b and pixel.g > pixel.b);
        partial_alpha = partial_alpha or (pixel.a > 0 and pixel.a < 65535);
        try std.testing.expect(pixel.r <= pixel.a and pixel.g <= pixel.a and pixel.b <= pixel.a);
    }
    try std.testing.expect(colored and partial_alpha);
    const shifted = try cache.getPhase(handle, glyph, 14, .{ .x = 32, .y = 16 });
    try std.testing.expect(shifted != small);
    try std.testing.expect(!std.mem.eql(u8, small.pixels, shifted.pixels));
    try std.testing.expectEqual(shifted, try cache.getPhase(handle, glyph, 14, .{ .x = 32, .y = 16 }));
    const large = try cache.get(handle, glyph, 28);
    try std.testing.expectEqual(@as(u32, 35), large.width);
    try std.testing.expectEqual(@as(u32, 33), large.height);
    try std.testing.expectEqual(@as(i32, 26), large.top);
}

test "bitmap glyph filtering decodes BGRA before averaging and preserves transparent edges" {
    // Asymmetric colors, partial alpha, and row padding catch channel swaps,
    // encoded-space filtering, double premultiplication and pitch mistakes.
    var bytes = [_]u8{ 0, 0, 255, 255, 0, 128, 0, 128, 99, 99, 99, 99, 255, 0, 0, 255, 0, 0, 0, 0, 88, 88, 88, 88 };
    var source: c.FT_Bitmap = std.mem.zeroes(c.FT_Bitmap);
    source.width = 2;
    source.rows = 2;
    source.pitch = 12;
    source.buffer = &bytes;
    source.pixel_mode = c.FT_PIXEL_MODE_BGRA;
    var pixels: [32]u8 = undefined;
    const bitmap: GlyphBitmap = .{ .pixels = &pixels, .width = 2, .height = 2, .left = 0, .top = 0, .color = true };
    resampleBitmap(&pixels, 2, 2, source, .{ 1, 1 }, .{ 0, 0 }, true);
    try std.testing.expectEqual(LinearRgba16{ .r = 65535, .g = 0, .b = 0, .a = 65535 }, bitmap.colorAt(0));
    try std.testing.expectEqual(LinearRgba16{ .r = 0, .g = 32896, .b = 0, .a = 32896 }, bitmap.colorAt(1));
    source.pitch = -12;
    resampleBitmap(&pixels, 2, 2, source, .{ 1, 1 }, .{ 0, 0 }, true);
    try std.testing.expectEqual(LinearRgba16{ .r = 0, .g = 0, .b = 65535, .a = 65535 }, bitmap.colorAt(0));
    resampleBitmap(pixels[0..8], 1, 1, source, .{ 0.5, 0.5 }, .{ 0, 0 }, true);
    try std.testing.expectEqual(LinearRgba16{ .r = 16384, .g = 8224, .b = 16384, .a = 40992 }, bitmap.colorAt(0));
    source.width = 1;
    source.rows = 1;
    source.pitch = 4;
    resampleBitmap(&pixels, 2, 2, source, .{ 1, 1 }, .{ 0.5, 0.25 }, true);
    const expected = [_]u16{ 24576, 24576, 8192, 8192 };
    for (expected, 0..) |value, index|
        try std.testing.expectEqual(LinearRgba16{ .r = value, .g = 0, .b = 0, .a = value }, bitmap.colorAt(index));
    source.pixel_mode = c.FT_PIXEL_MODE_MONO;
    source.width = 3;
    source.pitch = 1;
    bytes[0] = 0xa0;
    resampleBitmap(pixels[0..6], 6, 1, source, .{ 2, 1 }, .{ 0, 0 }, false);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 0, 0, 255, 255 }, pixels[0..6]);
    source.pixel_mode = c.FT_PIXEL_MODE_GRAY;
    source.width = 2;
    source.pitch = 2;
    source.num_grays = 256;
    bytes[0] = 255;
    bytes[1] = 0;
    resampleBitmap(pixels[0..1], 1, 1, source, .{ 0.5, 1 }, .{ 0, 0 }, false);
    try std.testing.expectEqual(@as(u8, 128), pixels[0]);
}

test "bundled CFF faces rasterize grayscale outlines in every weight and style" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts);
    defer glyphs.deinit();
    for (std.enums.values(text.bundled.Family)) |family| {
        for (std.enums.values(text.bundled.Weight)) |weight| {
            for (std.enums.values(text.bundled.Style)) |style| {
                const handle = try text.bundled.acquire(&fonts, family, weight, style);
                defer fonts.release(handle) catch unreachable;
                const font = try fonts.get(handle);
                for ([_]f32{ 12, 24 }) |size| {
                    const bitmap = try glyphs.get(handle, font.nominalGlyph('S').?, size);
                    try std.testing.expect(bitmap.width > 0 and bitmap.height > 0);
                    var has_partial_coverage = false;
                    for (bitmap.pixels) |coverage| {
                        has_partial_coverage = has_partial_coverage or (coverage > 0 and coverage < 255);
                    }
                    try std.testing.expect(has_partial_coverage);
                }
            }
        }
    }
}

test "stem darkening increases small bundled CFF glyph coverage without changing advances" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    var darkened = try GlyphCache.init(std.testing.allocator, &fonts);
    defer darkened.deinit();
    var plain = try GlyphCache.init(std.testing.allocator, &fonts);
    defer plain.deinit();
    const no_darkening: c.FT_Bool = 1;
    try std.testing.expectEqual(@as(c.FT_Error, 0), c.FT_Property_Set(plain.library, "cff", "no-stem-darkening", &no_darkening));
    for (std.enums.values(text.bundled.Family)) |family| {
        const handle = try text.bundled.acquire(&fonts, family, .regular, .roman);
        defer fonts.release(handle) catch unreachable;
        const font = try fonts.get(handle);
        const glyph = font.nominalGlyph('m').?;
        const dark = try darkened.get(handle, glyph, 12);
        const light = try plain.get(handle, glyph, 12);
        var dark_coverage: u64 = 0;
        var light_coverage: u64 = 0;
        for (dark.pixels) |value| dark_coverage += value;
        for (light.pixels) |value| light_coverage += value;
        try std.testing.expect(dark_coverage > light_coverage);
        try std.testing.expectEqual((try plain.face(handle)).*.glyph.*.advance.x, (try darkened.face(handle)).*.glyph.*.advance.x);
    }
}

test "glyph phases match full signed FreeType translation and retain distinct cache identities" {
    const Position = @import("../glyph_position.zig").Position;
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const handle = try text.bundled.acquire(&fonts, .serif, .regular, .italic);
    defer fonts.release(handle) catch unreachable;
    var cache = try GlyphCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    var reference = try GlyphCache.init(std.testing.allocator, &fonts);
    defer reference.deinit();
    const glyph = (try fonts.get(handle)).nominalGlyph('R').?;
    const zero = try cache.get(handle, glyph, 19.375);
    const x_only = try cache.getPhase(handle, glyph, 19.375, .{ .x = 13 });
    const y_only = try cache.getPhase(handle, glyph, 19.375, .{ .y = 13 });
    try std.testing.expect(zero != x_only and zero != y_only and x_only != y_only);
    try std.testing.expect(!std.mem.eql(u8, zero.pixels, x_only.pixels));
    try std.testing.expect(!std.mem.eql(u8, zero.pixels, y_only.pixels));
    try std.testing.expectEqual(x_only, try cache.getPhase(handle, glyph, 19.375, .{ .x = 13 }));
    try std.testing.expect(x_only != try cache.getPhase(handle, glyph, 19.5, .{ .x = 13 }));

    // An independent FreeType face translates by the *whole* signed origin,
    // rather than calling split or translating by the cache's phase.
    const face_value = try reference.face(handle);
    for ([_][2]i32{ .{ 205, -147 }, .{ -147, 205 }, .{ -1, -33 } }) |origin| {
        const position = Position.init(@as(f32, @floatFromInt(origin[0])) / 64, @as(f32, @floatFromInt(origin[1])) / 64);
        const bitmap = try cache.getPhase(handle, glyph, 19.375, position.phase);
        var delta: c.FT_Vector = .{ .x = origin[0], .y = -origin[1] };
        c.FT_Set_Transform(face_value, null, &delta);
        try std.testing.expectEqual(@as(c.FT_Error, 0), c.FT_Set_Char_Size(face_value, 0, 1240, 72, 72));
        const flags = c.FT_LOAD_TARGET_LIGHT | c.FT_LOAD_NO_BITMAP;
        try std.testing.expectEqual(@as(c.FT_Error, 0), c.FT_Load_Glyph(face_value, glyph, flags));
        try std.testing.expectEqual(@as(c.FT_Error, 0), c.FT_Render_Glyph(face_value.*.glyph, c.FT_RENDER_MODE_NORMAL));
        const slot = face_value.*.glyph;
        try std.testing.expectEqual(slot.*.bitmap_left, position.x + bitmap.left);
        try std.testing.expectEqual(-slot.*.bitmap_top, position.y - bitmap.top);
        try std.testing.expectEqual(slot.*.bitmap.width, bitmap.width);
        try std.testing.expectEqual(slot.*.bitmap.rows, bitmap.height);
        const pixels = try std.testing.allocator.alloc(u8, bitmap.pixels.len);
        defer std.testing.allocator.free(pixels);
        copyBitmap(pixels, slot.*.bitmap);
        try std.testing.expectEqualSlices(u8, pixels, bitmap.pixels);
    }
    // Equal slot numbers from different font generations must not alias.
    const key = try GlyphKey.init(handle, glyph, 19.375, .{ .x = 13 });
    var other = key;
    other.font_generation += 1;
    try std.testing.expect(!std.meta.eql(key, other));
}

test "glyph mask budget clears demanded phases and rerasterizes without changing pixels" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const handle = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(handle) catch unreachable;
    var cache = try GlyphCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    const glyph = (try fonts.get(handle)).nominalGlyph('S').?;
    const original = try cache.getPhase(handle, glyph, 21.375, .{ .x = 7, .y = 41 });
    const pixels = try std.testing.allocator.dupe(u8, original.pixels);
    defer std.testing.allocator.free(pixels);
    // Simulate an exhausted byte budget, then miss with a different phase.
    cache.pixel_bytes = 16 * 1024 * 1024;
    _ = try cache.getPhase(handle, glyph, 21.375, .{ .x = 8, .y = 41 });
    try std.testing.expectEqual(@as(u32, 1), cache.glyphs.count());
    try std.testing.expect(cache.pixel_bytes < 16 * 1024 * 1024);
    const again = try cache.getPhase(handle, glyph, 21.375, .{ .x = 7, .y = 41 });
    try std.testing.expectEqualSlices(u8, pixels, again.pixels);
}
