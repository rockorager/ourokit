//! Fallback shaping for already-itemized logical paragraph runs.

const std = @import("std");
const api = @import("api.zig");
const itemization = @import("itemization.zig");

pub const ShapedItemizedRun = struct {
    /// Document-relative source range.
    byte_start: usize,
    byte_len: usize,
    /// Converts HarfBuzz's paragraph-relative clusters back to document bytes.
    paragraph_start: usize,
    paragraph_content_len: usize,
    level: u8,
    script: api.Script,
    result: api.FallbackResult,
};

pub const ShapedParagraphs = struct {
    allocator: std.mem.Allocator,
    text_len: usize,
    /// Borrowed candidate order used for conservative line-fragment reshaping;
    /// both the slice and its referenced fonts must outlive this result.
    candidates: []const api.FallbackCandidate,
    language: []const u8,
    logical_size: f32,
    runs: []ShapedItemizedRun,

    pub fn deinit(self: *ShapedParagraphs) void {
        for (self.runs) |*run| run.result.deinit();
        self.allocator.free(self.runs);
        self.allocator.free(self.language);
        self.* = undefined;
    }
};

/// Shapes every logical bidi/script run while preserving the complete
/// paragraph as HarfBuzz context. Candidate fonts must outlive the result.
/// Language inheritance is not inferred; callers provide an explicit BCP 47
/// language (use `und` when it is genuinely unknown).
pub fn shapeItemizedParagraphs(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    analysis: *const itemization.ItemizedAnalysis,
    candidates: []const api.FallbackCandidate,
    language: []const u8,
    logical_size: f32,
) !ShapedParagraphs {
    const owned_language = try allocator.dupe(u8, language);
    errdefer allocator.free(owned_language);
    var runs: std.ArrayList(ShapedItemizedRun) = .empty;
    errdefer {
        for (runs.items) |*run| run.result.deinit();
        runs.deinit(allocator);
    }
    try runs.ensureTotalCapacity(allocator, analysis.runs.len);

    var expected_run: usize = 0;
    for (analysis.paragraphs) |paragraph| {
        for (analysis.runsFor(paragraph)) |run| {
            if (expected_run >= analysis.runs.len or
                run.byte_start != analysis.runs[expected_run].byte_start or
                run.byte_len != analysis.runs[expected_run].byte_len)
                return error.InvalidItemization;
            const result = try api.shapeWithFallback(
                allocator,
                candidates,
                try run.runSpec(utf8, paragraph, language, logical_size),
            );
            runs.appendAssumeCapacity(.{
                .byte_start = run.byte_start,
                .byte_len = run.byte_len,
                .paragraph_start = paragraph.byte_start,
                .paragraph_content_len = paragraph.contentLen(),
                .level = run.level,
                .script = run.script,
                .result = result,
            });
            expected_run += 1;
        }
    }
    if (expected_run != analysis.runs.len) return error.InvalidItemization;
    return .{
        .allocator = allocator,
        .text_len = utf8.len,
        .candidates = candidates,
        .language = owned_language,
        .logical_size = logical_size,
        .runs = try runs.toOwnedSlice(allocator),
    };
}

test "itemized mixed-direction runs shape with full paragraph context" {
    const utf8 = "Save حفظ";
    var itemized = try itemization.itemizeParagraphs(
        std.testing.allocator,
        utf8,
        .auto_left_to_right,
    );
    defer itemized.deinit();

    var latin = try api.Font.init(@embedFile("ourokit_test_font"), 0);
    defer latin.deinit();
    var arabic = try api.Font.init(@embedFile("ourokit_arabic_test_font"), 0);
    defer arabic.deinit();
    const candidates = [_]api.FallbackCandidate{
        .{ .handle = .{ .slot = 1, .generation = 1 }, .font = &latin },
        .{ .handle = .{ .slot = 2, .generation = 1 }, .font = &arabic },
    };
    var shaped = try shapeItemizedParagraphs(
        std.testing.allocator,
        utf8,
        &itemized,
        &candidates,
        "und",
        14,
    );
    defer shaped.deinit();

    try std.testing.expectEqual(itemized.runs.len, shaped.runs.len);
    try std.testing.expectEqual(utf8.len, shaped.text_len);
    for (shaped.runs, itemized.runs) |run, source| {
        try std.testing.expectEqual(source.byte_start, run.byte_start);
        try std.testing.expectEqual(source.byte_len, run.byte_len);
        try std.testing.expect(!run.result.has_missing_glyphs);
        try std.testing.expect(run.result.advance.x > 0);
    }
}

test "itemized shaping unwinds every caller-owned allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    const utf8 = "office text";
    var itemized = try itemization.itemizeParagraphs(allocator, utf8, .auto_left_to_right);
    defer itemized.deinit();
    var font = try api.Font.init(@embedFile("ourokit_test_font"), 0);
    defer font.deinit();
    var shaped = try shapeItemizedParagraphs(
        allocator,
        utf8,
        &itemized,
        &.{.{ .handle = .{ .slot = 1, .generation = 1 }, .font = &font }},
        "en",
        14,
    );
    defer shaped.deinit();
}
