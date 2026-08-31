//! Logical paragraph runs at the intersection of bidi level and script.

const std = @import("std");
const api = @import("api.zig");
const bidi_module = @import("paragraph.zig");
const script_module = @import("script_itemization.zig");

pub const ItemizedRun = struct {
    byte_start: usize,
    byte_len: usize,
    level: u8,
    script: api.Script,

    pub fn direction(self: ItemizedRun) api.Direction {
        return if (self.level & 1 == 0) .left_to_right else .right_to_left;
    }

    /// Converts this document-relative run to HarfBuzz's paragraph-relative
    /// range while retaining the complete logical paragraph as shaping context.
    pub fn runSpec(
        self: ItemizedRun,
        utf8: []const u8,
        paragraph: ItemizedParagraph,
        language: []const u8,
        logical_size: f32,
    ) !api.RunSpec {
        const paragraph_end = std.math.add(usize, paragraph.byte_start, paragraph.byte_len) catch
            return error.InvalidRange;
        if (paragraph.separator_len > paragraph.byte_len or paragraph_end > utf8.len)
            return error.InvalidRange;
        const content_len = paragraph.contentLen();
        const content_end = paragraph.byte_start + content_len;
        const run_end = std.math.add(usize, self.byte_start, self.byte_len) catch
            return error.InvalidRange;
        if (self.byte_start < paragraph.byte_start or run_end > content_end)
            return error.InvalidRange;
        return .{
            .paragraph = utf8[paragraph.byte_start..content_end],
            .byte_start = self.byte_start - paragraph.byte_start,
            .byte_len = self.byte_len,
            .direction = self.direction(),
            .script = self.script,
            .language = language,
            .logical_size = logical_size,
        };
    }
};

pub const ItemizedParagraph = struct {
    byte_start: usize,
    /// Includes the paragraph separator, when present.
    byte_len: usize,
    separator_len: usize,
    base_level: u8,
    level_start: usize,
    run_start: usize,
    run_count: usize,

    pub fn contentLen(self: ItemizedParagraph) usize {
        return self.byte_len - self.separator_len;
    }
};

pub const ItemizedAnalysis = struct {
    allocator: std.mem.Allocator,
    paragraphs: []ItemizedParagraph,
    levels: []u8,
    runs: []ItemizedRun,

    pub fn deinit(self: *ItemizedAnalysis) void {
        self.allocator.free(self.runs);
        self.allocator.free(self.levels);
        self.allocator.free(self.paragraphs);
        self.* = undefined;
    }

    pub fn levelsFor(self: *const ItemizedAnalysis, paragraph: ItemizedParagraph) []const u8 {
        return self.levels[paragraph.level_start..][0..paragraph.byte_len];
    }

    pub fn runsFor(self: *const ItemizedAnalysis, paragraph: ItemizedParagraph) []const ItemizedRun {
        return self.runs[paragraph.run_start..][0..paragraph.run_count];
    }
};

/// Produces maximal logical runs with one embedding level and one script.
/// Script context is resolved independently for each UAX #9 paragraph, and
/// paragraph separators are metadata rather than shaping input. Visual order,
/// language selection, shaping, and line breaking remain later stages.
pub fn itemizeParagraphs(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: bidi_module.BaseDirection,
) !ItemizedAnalysis {
    var bidi = try bidi_module.analyzeBidi(allocator, utf8, base_direction);
    errdefer bidi.deinit();

    var paragraphs: std.ArrayList(ItemizedParagraph) = .empty;
    errdefer paragraphs.deinit(allocator);
    var runs: std.ArrayList(ItemizedRun) = .empty;
    errdefer runs.deinit(allocator);

    for (bidi.paragraphs) |paragraph| {
        const content_len = paragraph.byte_len - paragraph.separator_len;
        const content = utf8[paragraph.byte_start..][0..content_len];
        var scripts = try script_module.analyzeScripts(allocator, content);
        defer scripts.deinit();
        const run_start = runs.items.len;
        try appendIntersections(
            allocator,
            &runs,
            bidi.runsFor(paragraph),
            scripts.runs,
            paragraph.byte_start,
            content_len,
        );
        try paragraphs.append(allocator, .{
            .byte_start = paragraph.byte_start,
            .byte_len = paragraph.byte_len,
            .separator_len = paragraph.separator_len,
            .base_level = paragraph.base_level,
            .level_start = paragraph.level_start,
            .run_start = run_start,
            .run_count = runs.items.len - run_start,
        });
    }

    const owned_paragraphs = try paragraphs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_paragraphs);
    const owned_runs = try runs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_runs);
    allocator.free(bidi.paragraphs);
    allocator.free(bidi.runs);
    const levels = bidi.levels;
    bidi = undefined;
    return .{
        .allocator = allocator,
        .paragraphs = owned_paragraphs,
        .levels = levels,
        .runs = owned_runs,
    };
}

fn appendIntersections(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(ItemizedRun),
    bidi_runs: []const bidi_module.BidiRun,
    script_runs: []const script_module.ScriptRun,
    paragraph_start: usize,
    content_len: usize,
) !void {
    const content_end = paragraph_start + content_len;
    var cursor = paragraph_start;
    var bidi_index: usize = 0;
    var script_index: usize = 0;
    while (cursor < content_end) {
        while (bidi_index < bidi_runs.len and
            bidi_runs[bidi_index].byte_start + bidi_runs[bidi_index].byte_len <= cursor)
            bidi_index += 1;
        while (script_index < script_runs.len and
            paragraph_start + script_runs[script_index].byte_start + script_runs[script_index].byte_len <= cursor)
            script_index += 1;
        if (bidi_index == bidi_runs.len or script_index == script_runs.len)
            return error.InvalidAnalysis;

        const bidi_run = bidi_runs[bidi_index];
        const script_run = script_runs[script_index];
        const script_start = paragraph_start + script_run.byte_start;
        const byte_start = @max(cursor, @max(bidi_run.byte_start, script_start));
        if (byte_start != cursor) return error.InvalidAnalysis;
        const byte_end = @min(content_end, @min(
            bidi_run.byte_start + bidi_run.byte_len,
            script_start + script_run.byte_len,
        ));
        if (byte_end <= byte_start) return error.InvalidAnalysis;
        try output.append(allocator, .{
            .byte_start = byte_start,
            .byte_len = byte_end - byte_start,
            .level = bidi_run.level,
            .script = script_run.script,
        });
        cursor = byte_end;
    }
    if (script_runs.len != 0 and content_len == 0) return error.InvalidAnalysis;
}

fn script(tag: *const [4]u8) api.Script {
    return api.Script.fromIso15924(tag);
}

test "itemization intersects script and bidi boundaries in logical order" {
    const value = "Latin Ελληνικά אבג";
    var analysis = try itemizeParagraphs(std.testing.allocator, value, .auto_left_to_right);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.paragraphs.len);
    const runs = analysis.runsFor(analysis.paragraphs[0]);
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try std.testing.expectEqual(script("Latn"), runs[0].script);
    try std.testing.expectEqual(script("Grek"), runs[1].script);
    try std.testing.expectEqual(script("Hebr"), runs[2].script);
    try std.testing.expectEqual(api.Direction.left_to_right, runs[0].direction());
    try std.testing.expectEqual(api.Direction.left_to_right, runs[1].direction());
    try std.testing.expectEqual(api.Direction.right_to_left, runs[2].direction());
    var expected_start: usize = 0;
    for (runs) |run| {
        try std.testing.expectEqual(expected_start, run.byte_start);
        expected_start += run.byte_len;
    }
    try std.testing.expectEqual(value.len, expected_start);
}

test "itemization resets script context and omits paragraph separators" {
    const value = "Latin\n(Ελληνικά)\r\nالعربية";
    var analysis = try itemizeParagraphs(std.testing.allocator, value, .auto_left_to_right);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 3), analysis.paragraphs.len);
    const expected_scripts = [_]api.Script{ script("Latn"), script("Grek"), script("Arab") };
    for (analysis.paragraphs, expected_scripts) |paragraph, expected_script| {
        const runs = analysis.runsFor(paragraph);
        try std.testing.expectEqual(@as(usize, 1), runs.len);
        try std.testing.expectEqual(expected_script, runs[0].script);
        try std.testing.expectEqual(paragraph.contentLen(), runs[0].byte_len);
        try std.testing.expectEqual(paragraph.byte_start, runs[0].byte_start);
    }
    try std.testing.expectEqual(@as(usize, 1), analysis.paragraphs[0].separator_len);
    try std.testing.expectEqual(@as(usize, 2), analysis.paragraphs[1].separator_len);
}

test "itemization preserves bidi levels for combining graphemes" {
    const value = "a\u{0301} ב\u{05B0}";
    var analysis = try itemizeParagraphs(std.testing.allocator, value, .auto_left_to_right);
    defer analysis.deinit();
    const paragraph = analysis.paragraphs[0];
    for (analysis.runsFor(paragraph)) |run| {
        for (analysis.levelsFor(paragraph)[run.byte_start..][0..run.byte_len]) |level|
            try std.testing.expectEqual(run.level, level);
    }
}

test "itemized runs feed explicit HarfBuzz fallback specs" {
    const value = "Save حفظ";
    var analysis = try itemizeParagraphs(std.testing.allocator, value, .auto_left_to_right);
    defer analysis.deinit();
    const paragraph = analysis.paragraphs[0];
    const runs = analysis.runsFor(paragraph);
    try std.testing.expectEqual(@as(usize, 2), runs.len);

    var latin = try api.Font.init(@embedFile("ourokit_test_font"), 0);
    defer latin.deinit();
    var arabic = try api.Font.init(@embedFile("ourokit_arabic_test_font"), 0);
    defer arabic.deinit();
    const candidates = [_]api.FallbackCandidate{
        .{ .handle = .{ .slot = 1, .generation = 1 }, .font = &latin },
        .{ .handle = .{ .slot = 2, .generation = 1 }, .font = &arabic },
    };
    for (runs) |run| {
        var shaped = try api.shapeWithFallback(
            std.testing.allocator,
            &candidates,
            try run.runSpec(value, paragraph, "und", 14),
        );
        defer shaped.deinit();
        try std.testing.expect(!shaped.has_missing_glyphs);
        try std.testing.expectEqual(run.direction(), shaped.spans[0].run.direction);
        for (shaped.spans) |span| for (span.run.glyphs) |glyph| {
            try std.testing.expect(glyph.cluster >= run.byte_start);
            try std.testing.expect(glyph.cluster < run.byte_start + run.byte_len);
        };
    }
}

test "run specs use paragraph-local ranges and omit separators" {
    const value = "first\nעברית";
    var analysis = try itemizeParagraphs(std.testing.allocator, value, .auto_left_to_right);
    defer analysis.deinit();
    const paragraph = analysis.paragraphs[1];
    const run = analysis.runsFor(paragraph)[0];
    const spec = try run.runSpec(value, paragraph, "he", 12);
    try std.testing.expectEqualStrings("עברית", spec.paragraph);
    try std.testing.expectEqual(@as(usize, 0), spec.byte_start);
    try std.testing.expectEqual(spec.paragraph.len, spec.byte_len.?);
    try std.testing.expectEqual(api.Direction.right_to_left, spec.direction);
}

test "itemization defines empty input and rejects malformed UTF-8" {
    var empty = try itemizeParagraphs(std.testing.allocator, "", .right_to_left);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty.paragraphs.len);
    try std.testing.expectEqual(@as(usize, 0), empty.runs.len);
    try std.testing.expectEqual(@as(u8, 1), empty.paragraphs[0].base_level);
    try std.testing.expectError(
        error.InvalidUtf8,
        itemizeParagraphs(std.testing.allocator, "bad\xff", .auto_left_to_right),
    );
}

test "itemization unwinds every caller-owned allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    var analysis = try itemizeParagraphs(
        allocator,
        "Latin Ελληνικά\nالعربية \u{2066}123\u{2069}",
        .auto_left_to_right,
    );
    defer analysis.deinit();
    std.mem.doNotOptimizeAway(analysis.runs.len);
}
