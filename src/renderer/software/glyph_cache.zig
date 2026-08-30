const std = @import("std");
const c = @import("freetype_c.zig").ft;
const text = @import("../../text/root.zig");

pub const GlyphBitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32,
};

const FaceKey = extern struct {
    slot: u32,
    generation: u32,
};

const GlyphKey = extern struct {
    font_slot: u32,
    font_generation: u32,
    glyph: u32,
    size_26_6: i32,
};

const FaceEntry = struct {
    handle: text.FontHandle,
    face: c.FT_Face,
};

/// Backend-owned FreeType faces and grayscale glyph masks. Font bytes and
/// shaping identity remain owned by the shared text service; this renderer
/// retains every face handle it caches.
pub const GlyphCache = struct {
    allocator: std.mem.Allocator,
    fonts: *text.FontCache,
    library: c.FT_Library,
    faces: std.AutoHashMapUnmanaged(FaceKey, *FaceEntry) = .empty,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, *GlyphBitmap) = .empty,

    pub fn init(allocator: std.mem.Allocator, fonts: *text.FontCache) !GlyphCache {
        var library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitializationFailed;
        return .{ .allocator = allocator, .fonts = fonts, .library = library };
    }

    pub fn deinit(self: *GlyphCache) void {
        var glyph_iterator = self.glyphs.valueIterator();
        while (glyph_iterator.next()) |glyph| {
            self.allocator.free(glyph.*.pixels);
            self.allocator.destroy(glyph.*);
        }
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

    pub fn get(
        self: *GlyphCache,
        handle: text.FontHandle,
        glyph: u32,
        pixel_size: f32,
    ) !*const GlyphBitmap {
        if (!std.math.isFinite(pixel_size) or pixel_size <= 0) return error.InvalidGlyphSize;
        const scaled = pixel_size * 64.0;
        if (@as(f64, scaled) > std.math.maxInt(i32)) return error.InvalidGlyphSize;
        const size_26_6: i32 = @intFromFloat(@round(scaled));
        if (size_26_6 <= 0) return error.InvalidGlyphSize;
        const key: GlyphKey = .{
            .font_slot = handle.slot,
            .font_generation = handle.generation,
            .glyph = glyph,
            .size_26_6 = size_26_6,
        };
        if (self.glyphs.get(key)) |cached| return cached;

        const face_value = try self.face(handle);
        if (c.FT_Set_Char_Size(face_value, 0, size_26_6, 72, 72) != 0)
            return error.GlyphSizeFailed;
        if (c.FT_Load_Glyph(face_value, glyph, c.FT_LOAD_DEFAULT) != 0)
            return error.GlyphLoadFailed;
        if (c.FT_Render_Glyph(face_value.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0)
            return error.GlyphRenderFailed;
        const source = face_value.*.glyph.*.bitmap;
        if (source.pixel_mode != c.FT_PIXEL_MODE_GRAY and source.pixel_mode != c.FT_PIXEL_MODE_MONO)
            return error.UnsupportedGlyphBitmap;

        const width: u32 = source.width;
        const height: u32 = source.rows;
        const pixels = try self.allocator.alloc(u8, try std.math.mul(usize, width, height));
        errdefer self.allocator.free(pixels);
        copyBitmap(pixels, source);
        const bitmap = try self.allocator.create(GlyphBitmap);
        errdefer self.allocator.destroy(bitmap);
        bitmap.* = .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .left = face_value.*.glyph.*.bitmap_left,
            .top = face_value.*.glyph.*.bitmap_top,
        };
        try self.glyphs.put(self.allocator, key, bitmap);
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
