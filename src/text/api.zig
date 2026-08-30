//! Font shaping, grapheme, fallback, and font-cache implementation.

const std = @import("std");
const uucode = @import("uucode");
const c = @import("c.zig").hb;
const PointF = @import("../core/geometry.zig").PointF;
const Handle = @import("../core/handle.zig").Handle;
const build_options = @import("ourokit_build_options");

pub const has_fontconfig = build_options.fontconfig;
pub const discovery = if (has_fontconfig) @import("fontconfig.zig") else struct {};

pub const Direction = enum {
    left_to_right,
    right_to_left,
    top_to_bottom,
    bottom_to_top,

    fn harfbuzz(self: Direction) c.hb_direction_t {
        return switch (self) {
            .left_to_right => c.HB_DIRECTION_LTR,
            .right_to_left => c.HB_DIRECTION_RTL,
            .top_to_bottom => c.HB_DIRECTION_TTB,
            .bottom_to_top => c.HB_DIRECTION_BTT,
        };
    }
};

/// ISO 15924 script identity. Callers must itemize Common and Inherited code
/// points into surrounding script runs before shaping.
pub const Script = enum(u32) {
    arabic = c.HB_SCRIPT_ARABIC,
    cyrillic = c.HB_SCRIPT_CYRILLIC,
    devanagari = c.HB_SCRIPT_DEVANAGARI,
    greek = c.HB_SCRIPT_GREEK,
    han = c.HB_SCRIPT_HAN,
    hebrew = c.HB_SCRIPT_HEBREW,
    latin = c.HB_SCRIPT_LATIN,
    _,

    pub fn fromIso15924(tag: *const [4]u8) Script {
        return @enumFromInt(c.hb_script_from_iso15924_tag(c.HB_TAG(tag[0], tag[1], tag[2], tag[3])));
    }

    fn harfbuzz(self: Script) c.hb_script_t {
        return @intFromEnum(self);
    }
};

pub const Glyph = struct {
    id: u32,
    /// Byte offset into the original paragraph, not the shaped substring.
    cluster: u32,
    advance: PointF,
    offset: PointF,
    unsafe_to_break: bool,
};

pub const Metrics = struct {
    ascender: f32,
    descender: f32,
    line_gap: f32,
};

pub const ShapedRun = struct {
    allocator: std.mem.Allocator,
    glyphs: []Glyph,
    direction: Direction,
    byte_start: usize,
    byte_len: usize,
    advance: PointF,
    metrics: Metrics,

    pub fn deinit(self: *ShapedRun) void {
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

/// One already-itemized shaping run. `paragraph` remains in logical order,
/// including for RTL text. Direction, script, language, and font are explicit:
/// HarfBuzz guesses none of them and does not perform bidi or fallback.
pub const RunSpec = struct {
    paragraph: []const u8,
    byte_start: usize = 0,
    byte_len: ?usize = null,
    direction: Direction,
    script: Script,
    /// BCP 47 language tag, such as `en` or `ar`.
    language: []const u8,
    logical_size: f32,
};

pub const Font = struct {
    face: *c.hb_face_t,
    base_font: *c.hb_font_t,
    units_per_em: u32,
    raster_bytes: []u8,
    raster_face_index: u32,
    raster_variations: []Variation,

    pub const Variation = struct {
        tag: u32,
        value: f32,
    };

    pub const RasterSource = struct {
        bytes: []const u8,
        face_index: u32,
        variations: []const Variation,
    };

    pub fn init(bytes: []const u8, face_index: u32) !Font {
        return initInternal(bytes, face_index, null);
    }

    /// Initialize the exact face selected by Fontconfig. Fontconfig's upper
    /// index word names a variable-font instance, except for its `0x8000`
    /// sentinel, which means the base variable face. Variation assignments are
    /// applied after named-instance defaults.
    pub fn initConfigured(
        bytes: []const u8,
        fontconfig_index: u32,
        variations: ?[]const u8,
    ) !Font {
        const instance = fontconfig_index >> 16;
        const harfbuzz_index = if (instance == 0x8000)
            fontconfig_index & 0xffff
        else
            fontconfig_index;
        return initInternal(bytes, harfbuzz_index, variations);
    }

    fn initInternal(bytes: []const u8, face_index: u32, variations: ?[]const u8) !Font {
        if (bytes.len > std.math.maxInt(c_uint)) return error.FontTooLarge;
        const raster_bytes = try std.heap.c_allocator.dupe(u8, bytes);
        errdefer std.heap.c_allocator.free(raster_bytes);
        const blob = c.hb_blob_create(
            raster_bytes.ptr,
            @intCast(raster_bytes.len),
            c.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.OutOfMemory;
        defer c.hb_blob_destroy(blob);
        if (c.hb_blob_get_length(blob) != raster_bytes.len) return error.OutOfMemory;

        const face = c.hb_face_create(blob, face_index) orelse return error.OutOfMemory;
        errdefer c.hb_face_destroy(face);
        const units_per_em = c.hb_face_get_upem(face);
        if (units_per_em == 0 or c.hb_face_get_glyph_count(face) == 0) return error.InvalidFont;

        const font = c.hb_font_create(face) orelse return error.OutOfMemory;
        errdefer c.hb_font_destroy(font);
        if (c.hb_font_is_immutable(font) != 0) return error.OutOfMemory;
        c.hb_ot_font_set_funcs(font);
        var raster_variations: std.ArrayList(Variation) = .empty;
        errdefer raster_variations.deinit(std.heap.c_allocator);
        if (variations) |assignments| {
            var iterator = std.mem.splitScalar(u8, assignments, ',');
            while (iterator.next()) |assignment| {
                const trimmed = std.mem.trim(u8, assignment, " \t\r\n");
                if (trimmed.len == 0 or trimmed.len > std.math.maxInt(c_int))
                    return error.InvalidVariations;
                var variation: c.hb_variation_t = undefined;
                if (c.hb_variation_from_string(trimmed.ptr, @intCast(trimmed.len), &variation) == 0)
                    return error.InvalidVariations;
                c.hb_font_set_variation(font, variation.tag, variation.value);
                try raster_variations.append(std.heap.c_allocator, .{
                    .tag = variation.tag,
                    .value = variation.value,
                });
            }
        }
        return .{
            .face = face,
            .base_font = font,
            .units_per_em = units_per_em,
            .raster_bytes = raster_bytes,
            .raster_face_index = face_index,
            .raster_variations = try raster_variations.toOwnedSlice(std.heap.c_allocator),
        };
    }

    pub fn deinit(self: *Font) void {
        c.hb_font_destroy(self.base_font);
        c.hb_face_destroy(self.face);
        std.heap.c_allocator.free(self.raster_variations);
        std.heap.c_allocator.free(self.raster_bytes);
        self.* = undefined;
    }

    pub fn rasterSource(self: *const Font) RasterSource {
        return .{
            .bytes = self.raster_bytes,
            .face_index = self.raster_face_index,
            .variations = self.raster_variations,
        };
    }

    /// Reports nominal cmap coverage. Paragraph itemization uses this to pick
    /// a face before shaping; HarfBuzz itself does not perform font fallback.
    pub fn hasGlyph(self: *const Font, codepoint: u21) bool {
        return self.nominalGlyph(codepoint) != null;
    }

    pub fn nominalGlyph(self: *const Font, codepoint: u21) ?u32 {
        var glyph: c.hb_codepoint_t = 0;
        return if (c.hb_font_get_nominal_glyph(self.base_font, codepoint, &glyph) != 0) glyph else null;
    }

    pub fn shape(self: *const Font, allocator: std.mem.Allocator, spec: RunSpec) !ShapedRun {
        if (!std.math.isFinite(spec.logical_size) or spec.logical_size <= 0) return error.InvalidSize;
        if (!std.unicode.utf8ValidateSlice(spec.paragraph)) return error.InvalidUtf8;
        const byte_len = spec.byte_len orelse spec.paragraph.len -| spec.byte_start;
        const byte_end = std.math.add(usize, spec.byte_start, byte_len) catch return error.InvalidRange;
        if (byte_end > spec.paragraph.len or
            !isCodepointBoundary(spec.paragraph, spec.byte_start) or
            !isCodepointBoundary(spec.paragraph, byte_end)) return error.InvalidRange;
        if (spec.paragraph.len > std.math.maxInt(c_int) or
            spec.byte_start > std.math.maxInt(c_uint) or
            byte_len > std.math.maxInt(c_int)) return error.TextTooLarge;
        if (spec.language.len == 0 or spec.language.len > std.math.maxInt(c_int)) return error.InvalidLanguage;

        const scale_f = spec.logical_size * 64.0;
        if (scale_f > @as(f32, @floatFromInt(std.math.maxInt(c_int)))) return error.InvalidSize;
        const scale: c_int = @intFromFloat(@round(scale_f));
        if (scale == 0) return error.InvalidSize;

        const font = c.hb_font_create_sub_font(self.base_font) orelse return error.OutOfMemory;
        defer c.hb_font_destroy(font);
        c.hb_font_set_scale(font, scale, scale);
        c.hb_font_set_ptem(font, spec.logical_size);

        const buffer = c.hb_buffer_create() orelse return error.OutOfMemory;
        defer c.hb_buffer_destroy(buffer);
        if (c.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        c.hb_buffer_set_direction(buffer, spec.direction.harfbuzz());
        c.hb_buffer_set_script(buffer, spec.script.harfbuzz());
        c.hb_buffer_set_language(buffer, c.hb_language_from_string(spec.language.ptr, @intCast(spec.language.len)));
        c.hb_buffer_set_cluster_level(buffer, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS);
        var flags: c.hb_buffer_flags_t = c.HB_BUFFER_FLAG_DEFAULT;
        if (spec.byte_start == 0) flags |= c.HB_BUFFER_FLAG_BOT;
        if (byte_end == spec.paragraph.len) flags |= c.HB_BUFFER_FLAG_EOT;
        c.hb_buffer_set_flags(buffer, flags);
        c.hb_buffer_add_utf8(
            buffer,
            spec.paragraph.ptr,
            @intCast(spec.paragraph.len),
            @intCast(spec.byte_start),
            @intCast(byte_len),
        );
        if (c.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;
        c.hb_shape(font, buffer, null, 0);
        if (c.hb_buffer_allocation_successful(buffer) == 0) return error.OutOfMemory;

        var glyph_count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(buffer, &glyph_count);
        const positions = c.hb_buffer_get_glyph_positions(buffer, null);
        if (glyph_count != 0 and (infos == null or positions == null)) return error.OutOfMemory;
        const glyphs = try allocator.alloc(Glyph, glyph_count);
        errdefer allocator.free(glyphs);
        var advance: PointF = .{};
        for (glyphs, 0..) |*glyph, index| {
            const info = infos[index];
            const position = positions[index];
            glyph.* = .{
                .id = info.codepoint,
                .cluster = info.cluster,
                .advance = .{
                    .x = fromFixed(position.x_advance),
                    .y = fromFixed(position.y_advance),
                },
                .offset = .{
                    .x = fromFixed(position.x_offset),
                    .y = fromFixed(position.y_offset),
                },
                .unsafe_to_break = (c.hb_glyph_info_get_glyph_flags(&infos[index]) & c.HB_GLYPH_FLAG_UNSAFE_TO_BREAK) != 0,
            };
            advance = advance.add(glyph.advance);
        }

        var extents: c.hb_font_extents_t = undefined;
        c.hb_font_get_extents_for_direction(font, spec.direction.harfbuzz(), &extents);
        return .{
            .allocator = allocator,
            .glyphs = glyphs,
            .direction = spec.direction,
            .byte_start = spec.byte_start,
            .byte_len = byte_len,
            .advance = advance,
            .metrics = .{
                .ascender = fromFixed(extents.ascender),
                .descender = fromFixed(extents.descender),
                .line_gap = fromFixed(extents.line_gap),
            },
        };
    }
};

pub const Grapheme = struct {
    byte_start: usize,
    byte_end: usize,
};

pub const FontHandle = Handle;
pub const FontCache = @import("font_cache.zig").Cache(Font, FontHandle);

/// A cache-owned font in Fontconfig candidate order. The cache retains `font`
/// for the entire shaping call; shaped output stores only its stable handle.
pub const FallbackCandidate = struct {
    handle: FontHandle,
    font: *const Font,
};

pub const ShapedSpan = struct {
    font: FontHandle,
    run: ShapedRun,
};

/// Logical-order spans for one already-itemized bidi/script/language run.
/// Paragraph layout performs visual ordering later.
pub const FallbackResult = struct {
    allocator: std.mem.Allocator,
    spans: []ShapedSpan,
    logical_size: f32,
    advance: PointF,
    metrics: Metrics,
    has_missing_glyphs: bool,

    pub fn deinit(self: *FallbackResult) void {
        for (self.spans) |*span| span.run.deinit();
        self.allocator.free(self.spans);
        self.* = undefined;
    }
};

/// Collect uucode's Unicode 17 extended-grapheme boundaries, including its
/// documented isolated-emoji-modifier tailoring. These boundaries serve
/// cursoring and selection; HarfBuzz glyph clusters remain a distinct mapping.
pub fn graphemes(allocator: std.mem.Allocator, utf8: []const u8) ![]Grapheme {
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
    var result: std.ArrayList(Grapheme) = .empty;
    errdefer result.deinit(allocator);
    var iterator = uucode.grapheme.utf8Iterator(utf8);
    while (iterator.nextGrapheme()) |grapheme| try result.append(allocator, .{
        .byte_start = grapheme.start,
        .byte_end = grapheme.end,
    });
    return result.toOwnedSlice(allocator);
}

/// The deliberately narrow first Label contract: one LTR Latin-script line.
/// Common and Inherited characters remain attached to that run; every other
/// script is rejected rather than shaped under an incorrect script property.
pub fn supportsSimpleLabel(utf8: []const u8) bool {
    const view = std.unicode.Utf8View.init(utf8) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| switch (uucode.get(.script, codepoint)) {
        .latin, .common, .inherited => {},
        else => return false,
    };
    return true;
}

/// Shape an itemized run using configured candidates in priority order.
///
/// A single face is preferred for the entire run. If none succeeds, selection
/// occurs per extended grapheme and adjacent equal-face selections are merged
/// before final shaping. Every shape call receives full paragraph context, so
/// fallback boundaries do not force Arabic characters into isolated forms.
/// An unresolved grapheme uses the first candidate's `.notdef` and sets
/// `has_missing_glyphs`; text is never silently omitted.
pub fn shapeWithFallback(
    allocator: std.mem.Allocator,
    candidates: []const FallbackCandidate,
    spec: RunSpec,
) !FallbackResult {
    if (candidates.len == 0) return error.NoFallbackCandidates;
    for (candidates) |candidate|
        if (candidate.handle.generation == 0) return error.InvalidFontHandle;

    const byte_len = spec.byte_len orelse spec.paragraph.len -| spec.byte_start;
    const byte_end = std.math.add(usize, spec.byte_start, byte_len) catch return error.InvalidRange;
    if (byte_end > spec.paragraph.len) return error.InvalidRange;
    const all_graphemes = try graphemes(allocator, spec.paragraph);
    defer allocator.free(all_graphemes);
    var run_graphemes: std.ArrayList(Grapheme) = .empty;
    defer run_graphemes.deinit(allocator);
    for (all_graphemes) |grapheme| {
        if (grapheme.byte_end <= spec.byte_start or grapheme.byte_start >= byte_end) continue;
        if (grapheme.byte_start < spec.byte_start or grapheme.byte_end > byte_end)
            return error.RunSplitsGrapheme;
        try run_graphemes.append(allocator, grapheme);
    }

    for (candidates) |candidate| {
        var run = try candidate.font.shape(allocator, spec);
        if (!hasMissingGlyph(run.glyphs))
            return singleSpanResult(allocator, candidate.handle, run, spec.logical_size, false);
        run.deinit();
    }

    const Selection = struct {
        candidate_index: usize,
        byte_start: usize,
        byte_end: usize,
    };
    var selections: std.ArrayList(Selection) = .empty;
    defer selections.deinit(allocator);
    var unresolved = false;
    for (run_graphemes.items) |grapheme| {
        var selected: usize = 0;
        var found = false;
        for (candidates, 0..) |candidate, index| {
            var probe = try candidate.font.shape(allocator, withRange(spec, grapheme.byte_start, grapheme.byte_end));
            defer probe.deinit();
            if (!hasMissingGlyph(probe.glyphs)) {
                selected = index;
                found = true;
                break;
            }
        }
        unresolved = unresolved or !found;
        if (selections.items.len != 0) {
            const previous = &selections.items[selections.items.len - 1];
            if (previous.candidate_index == selected and previous.byte_end == grapheme.byte_start) {
                previous.byte_end = grapheme.byte_end;
                continue;
            }
        }
        try selections.append(allocator, .{
            .candidate_index = selected,
            .byte_start = grapheme.byte_start,
            .byte_end = grapheme.byte_end,
        });
    }

    var spans: std.ArrayList(ShapedSpan) = .empty;
    errdefer {
        for (spans.items) |*span| span.run.deinit();
        spans.deinit(allocator);
    }
    var advance: PointF = .{};
    var metrics: Metrics = .{ .ascender = 0, .descender = 0, .line_gap = 0 };
    for (selections.items) |selection| {
        const candidate = candidates[selection.candidate_index];
        var run = try candidate.font.shape(
            allocator,
            withRange(spec, selection.byte_start, selection.byte_end),
        );
        errdefer run.deinit();
        unresolved = unresolved or hasMissingGlyph(run.glyphs);
        advance = advance.add(run.advance);
        if (spans.items.len == 0) {
            metrics = run.metrics;
        } else {
            metrics.ascender = @max(metrics.ascender, run.metrics.ascender);
            metrics.descender = @min(metrics.descender, run.metrics.descender);
            metrics.line_gap = @max(metrics.line_gap, run.metrics.line_gap);
        }
        try spans.append(allocator, .{ .font = candidate.handle, .run = run });
    }
    return .{
        .allocator = allocator,
        .spans = try spans.toOwnedSlice(allocator),
        .logical_size = spec.logical_size,
        .advance = advance,
        .metrics = metrics,
        .has_missing_glyphs = unresolved,
    };
}

fn singleSpanResult(
    allocator: std.mem.Allocator,
    font: FontHandle,
    run: ShapedRun,
    logical_size: f32,
    has_missing_glyphs: bool,
) !FallbackResult {
    var owned_run = run;
    errdefer owned_run.deinit();
    const spans = try allocator.alloc(ShapedSpan, 1);
    spans[0] = .{ .font = font, .run = owned_run };
    return .{
        .allocator = allocator,
        .spans = spans,
        .logical_size = logical_size,
        .advance = owned_run.advance,
        .metrics = owned_run.metrics,
        .has_missing_glyphs = has_missing_glyphs,
    };
}

fn withRange(spec: RunSpec, byte_start: usize, byte_end: usize) RunSpec {
    var ranged = spec;
    ranged.byte_start = byte_start;
    ranged.byte_len = byte_end - byte_start;
    return ranged;
}

fn hasMissingGlyph(glyphs: []const Glyph) bool {
    for (glyphs) |glyph| if (glyph.id == 0) return true;
    return false;
}

fn isCodepointBoundary(bytes: []const u8, index: usize) bool {
    return index == 0 or index == bytes.len or bytes[index] & 0xc0 != 0x80;
}

fn fromFixed(value: c.hb_position_t) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}

test "uucode segments extended grapheme clusters independently of shaping clusters" {
    const text = "a\u{0301}👩🏽‍🚀🇨🇭";
    const values = try graphemes(std.testing.allocator, text);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("a\u{0301}", text[values[0].byte_start..values[0].byte_end]);
    try std.testing.expectEqualStrings("👩🏽‍🚀", text[values[1].byte_start..values[1].byte_end]);
    try std.testing.expectEqualStrings("🇨🇭", text[values[2].byte_start..values[2].byte_end]);
}

test "simple label contract rejects scripts requiring paragraph itemization" {
    try std.testing.expect(supportsSimpleLabel("Save as… (2)"));
    try std.testing.expect(supportsSimpleLabel("cafe\u{0301}"));
    try std.testing.expect(!supportsSimpleLabel("Save حفظ"));
    try std.testing.expect(!supportsSimpleLabel("broken\xff"));
}

test "HarfBuzz performs OpenType ligature, combining, and RTL shaping" {
    const bytes = @embedFile("ourokit_test_font");
    var font = try Font.init(bytes, 0);
    defer font.deinit();

    var latin = try font.shape(std.testing.allocator, .{
        .paragraph = "office a\u{0301}",
        .direction = .left_to_right,
        .script = .latin,
        .language = "en",
        .logical_size = 16,
    });
    defer latin.deinit();
    try std.testing.expect(latin.glyphs.len < 9);
    try std.testing.expect(latin.advance.x > 0);
    try std.testing.expect(latin.metrics.ascender > 0);
    try std.testing.expect(latin.metrics.descender < 0);
    try std.testing.expectEqual(@as(u32, 1), latin.glyphs[1].cluster);

    try std.testing.expect(!font.hasGlyph('س'));
    const arabic_bytes = @embedFile("ourokit_arabic_test_font");
    var arabic_font = try Font.init(arabic_bytes, 0);
    defer arabic_font.deinit();
    try std.testing.expect(arabic_font.hasGlyph('س'));
    const arabic_text = "سلام";
    var arabic = try arabic_font.shape(std.testing.allocator, .{
        .paragraph = arabic_text,
        .direction = .right_to_left,
        .script = .arabic,
        .language = "ar",
        .logical_size = 16,
    });
    defer arabic.deinit();
    var has_contextual_form = false;
    for (arabic.glyphs) |glyph| {
        const start: usize = glyph.cluster;
        const codepoint_len = try std.unicode.utf8ByteSequenceLength(arabic_text[start]);
        const codepoint = try std.unicode.utf8Decode(arabic_text[start..][0..codepoint_len]);
        has_contextual_form = has_contextual_form or glyph.id != arabic_font.nominalGlyph(codepoint).?;
    }
    try std.testing.expect(has_contextual_form);
    try std.testing.expect(arabic.advance.x > 0);
    for (arabic.glyphs[1..], arabic.glyphs[0 .. arabic.glyphs.len - 1]) |current, previous|
        try std.testing.expect(current.cluster <= previous.cluster);
}

test "run ranges preserve paragraph-relative clusters and reject split UTF-8" {
    const bytes = @embedFile("ourokit_test_font");
    var font = try Font.init(bytes, 0);
    defer font.deinit();
    const paragraph = "x café y";
    var run = try font.shape(std.testing.allocator, .{
        .paragraph = paragraph,
        .byte_start = 2,
        .byte_len = 5,
        .direction = .left_to_right,
        .script = .latin,
        .language = "fr",
        .logical_size = 13,
    });
    defer run.deinit();
    try std.testing.expectEqual(@as(u32, 2), run.glyphs[0].cluster);
    try std.testing.expectError(error.InvalidRange, font.shape(std.testing.allocator, .{
        .paragraph = paragraph,
        .byte_start = 6,
        .byte_len = 1,
        .direction = .left_to_right,
        .script = .latin,
        .language = "fr",
        .logical_size = 13,
    }));
}

test "fallback shaping uses configured order and preserves unresolved text" {
    const inter_bytes = @embedFile("ourokit_test_font");
    var inter = try Font.init(inter_bytes, 0);
    defer inter.deinit();
    const arabic_bytes = @embedFile("ourokit_arabic_test_font");
    var arabic = try Font.init(arabic_bytes, 0);
    defer arabic.deinit();
    const inter_handle: FontHandle = .{ .slot = 1, .generation = 1 };
    const arabic_handle: FontHandle = .{ .slot = 2, .generation = 1 };
    const spec: RunSpec = .{
        .paragraph = "سلام",
        .direction = .right_to_left,
        .script = .arabic,
        .language = "ar",
        .logical_size = 16,
    };

    var fallback = try shapeWithFallback(std.testing.allocator, &.{
        .{ .handle = inter_handle, .font = &inter },
        .{ .handle = arabic_handle, .font = &arabic },
    }, spec);
    defer fallback.deinit();
    try std.testing.expectEqual(@as(usize, 1), fallback.spans.len);
    try std.testing.expectEqual(arabic_handle, fallback.spans[0].font);
    try std.testing.expect(!fallback.has_missing_glyphs);

    var unresolved = try shapeWithFallback(std.testing.allocator, &.{
        .{ .handle = inter_handle, .font = &inter },
    }, spec);
    defer unresolved.deinit();
    try std.testing.expectEqual(@as(usize, 1), unresolved.spans.len);
    try std.testing.expectEqual(inter_handle, unresolved.spans[0].font);
    try std.testing.expect(unresolved.has_missing_glyphs);
    try std.testing.expect(unresolved.spans[0].run.glyphs.len != 0);
}

test "fallback shaping rejects itemized runs that split a grapheme" {
    const bytes = @embedFile("ourokit_test_font");
    var font = try Font.init(bytes, 0);
    defer font.deinit();
    const text = "a\u{0301}";
    try std.testing.expectError(error.RunSplitsGrapheme, shapeWithFallback(
        std.testing.allocator,
        &.{.{ .handle = .{ .slot = 1, .generation = 1 }, .font = &font }},
        .{
            .paragraph = text,
            .byte_start = 1,
            .byte_len = text.len - 1,
            .direction = .left_to_right,
            .script = .latin,
            .language = "en",
            .logical_size = 16,
        },
    ));
}

test "Fontconfig variable sentinel and variations map to HarfBuzz" {
    const bytes = @embedFile("ourokit_test_font");
    var font = try Font.initConfigured(bytes, 0x80000000, "wght=700");
    defer font.deinit();
    try std.testing.expectEqual(
        @as(c_uint, c.HB_FONT_NO_VAR_NAMED_INSTANCE),
        c.hb_font_get_var_named_instance(font.base_font),
    );
    try std.testing.expectError(
        error.InvalidVariations,
        Font.initConfigured(bytes, 0, "not-an-axis"),
    );
}

test "font cache deduplicates, grows without moving fonts, and rejects stale handles" {
    const bytes = @embedFile("ourokit_test_font");
    var cache = FontCache.init(std.testing.allocator);
    defer cache.deinit();

    const first = try cache.acquire(.{
        .key = .{ .file = "/fonts/primary.ttf", .index = 0 },
        .bytes = bytes,
    });
    const first_pointer = try cache.get(first);
    const duplicate = try cache.acquire(.{
        .key = .{ .file = "/fonts/primary.ttf", .index = 0 },
        .bytes = bytes,
    });
    try std.testing.expectEqual(first, duplicate);

    var handles: [17]FontHandle = undefined;
    for (&handles, 0..) |*handle, index| {
        var path_buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/fonts/fallback-{d}.ttf", .{index});
        handle.* = try cache.acquire(.{ .key = .{ .file = path, .index = 0 }, .bytes = bytes });
    }
    try std.testing.expectEqual(first_pointer, try cache.get(first));
    try std.testing.expectEqual(@as(usize, 18), cache.count());

    try cache.release(duplicate);
    _ = try cache.get(first);
    try cache.release(first);
    try std.testing.expectError(error.StaleFont, cache.get(first));
    const replacement = try cache.acquire(.{
        .key = .{ .file = "/fonts/primary.ttf", .index = 0 },
        .bytes = bytes,
    });
    try std.testing.expectEqual(first.slot, replacement.slot);
    try std.testing.expect(replacement.generation != first.generation);

    for (handles) |handle| try cache.release(handle);
    try cache.release(replacement);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

test "font cache source revisions prevent stale file reuse" {
    const bytes = @embedFile("ourokit_test_font");
    var cache = FontCache.init(std.testing.allocator);
    defer cache.deinit();
    const old = try cache.acquire(.{
        .key = .{ .file = "/fonts/configured.ttf", .index = 0, .source_revision = 1 },
        .bytes = bytes,
    });
    const updated = try cache.acquire(.{
        .key = .{ .file = "/fonts/configured.ttf", .index = 0, .source_revision = 2 },
        .bytes = bytes,
    });
    try std.testing.expect(old.slot != updated.slot);
    try cache.release(old);
    try cache.release(updated);
}
