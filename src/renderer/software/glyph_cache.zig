const std = @import("std");
const c = @import("freetype_c.zig").ft;
const text = @import("../../text/root.zig");
const Phase = @import("../glyph_position.zig").Phase;

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

/// Backend-owned FreeType faces and grayscale glyph masks. Font bytes and
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
        if (c.FT_Set_Char_Size(face_value, 0, key.size_26_6, 72, 72) != 0)
            return error.GlyphSizeFailed;
        const flags = c.FT_LOAD_TARGET_LIGHT | c.FT_LOAD_NO_BITMAP;
        if (c.FT_Load_Glyph(face_value, glyph, flags) != 0)
            return error.GlyphLoadFailed;
        // Translate the loaded/hinted outline, before coverage rasterization.
        // Bearings include this translation; callers add only integer anchors.
        if (face_value.*.glyph.*.format == c.FT_GLYPH_FORMAT_OUTLINE)
            c.FT_Outline_Translate(&face_value.*.glyph.*.outline, phase.x, -@as(c.FT_Pos, phase.y));
        if (c.FT_Render_Glyph(face_value.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0)
            return error.GlyphRenderFailed;
        const source = face_value.*.glyph.*.bitmap;
        if (source.pixel_mode != c.FT_PIXEL_MODE_GRAY and source.pixel_mode != c.FT_PIXEL_MODE_MONO)
            return error.UnsupportedGlyphBitmap;

        const width: u32 = source.width;
        const height: u32 = source.rows;
        const bytes = try std.math.mul(usize, width, height);
        // Only demanded phases are cached. Bound phase churn (including empty
        // glyphs) without holding 4096 variants per glyph indefinitely.
        const max_bytes = 16 * 1024 * 1024;
        if (bytes > max_bytes) return error.GlyphTooLarge;
        if (self.pixel_bytes + bytes > max_bytes or self.glyphs.count() >= 16384) self.clear();
        const pixels = try self.allocator.alloc(u8, bytes);
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
