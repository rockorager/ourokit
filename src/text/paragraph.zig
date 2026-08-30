//! Pure, headless paragraph analysis primitives. This module owns no fonts,
//! UI objects, renderer resources, platform objects, or language runtime state.

const std = @import("std");
const c = @import("c.zig").sb;

pub const BaseDirection = enum {
    auto_left_to_right,
    auto_right_to_left,
    left_to_right,
    right_to_left,
};

/// One maximal embedding-level run in logical input order. Byte ranges always
/// index the original UTF-8 input; odd levels are right-to-left. Visual order
/// is intentionally deferred until line boundaries are known.
pub const BidiRun = struct {
    byte_start: usize,
    byte_len: usize,
    level: u8,

    pub fn rightToLeft(self: BidiRun) bool {
        return self.level & 1 != 0;
    }
};

/// Metadata for one UAX #9 paragraph. Levels and logical runs are flattened in
/// the owning analysis so callers can iterate without per-paragraph allocation.
pub const BidiParagraph = struct {
    byte_start: usize,
    byte_len: usize,
    separator_len: usize,
    base_level: u8,
    level_start: usize,
    run_start: usize,
    run_count: usize,
};

pub const BidiAnalysis = struct {
    allocator: std.mem.Allocator,
    paragraphs: []BidiParagraph,
    levels: []u8,
    runs: []BidiRun,

    pub fn deinit(self: *BidiAnalysis) void {
        self.allocator.free(self.runs);
        self.allocator.free(self.levels);
        self.allocator.free(self.paragraphs);
        self.* = undefined;
    }

    pub fn levelsFor(self: *const BidiAnalysis, paragraph: BidiParagraph) []const u8 {
        return self.levels[paragraph.level_start..][0..paragraph.byte_len];
    }

    pub fn runsFor(self: *const BidiAnalysis, paragraph: BidiParagraph) []const BidiRun {
        return self.runs[paragraph.run_start..][0..paragraph.run_count];
    }
};

/// Resolves paragraph boundaries, embedding levels, and logical level runs for
/// valid UTF-8. The returned value is self-contained and does not borrow input.
/// This stage deliberately performs no shaping, fallback, line breaking, or
/// layout, making bidi cost and correctness independently testable/profileable.
pub fn analyzeBidi(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    direction: BaseDirection,
) !BidiAnalysis {
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
    if (utf8.len == 0) return emptyAnalysis(allocator, direction);

    const sequence: c.SBCodepointSequence = .{
        .stringEncoding = c.SBStringEncodingUTF8,
        .stringBuffer = utf8.ptr,
        .stringLength = utf8.len,
    };
    const algorithm = c.SBAlgorithmCreate(&sequence) orelse return error.OutOfMemory;
    defer c.SBAlgorithmRelease(algorithm);

    var paragraphs: std.ArrayList(BidiParagraph) = .empty;
    errdefer paragraphs.deinit(allocator);
    var levels: std.ArrayList(u8) = .empty;
    errdefer levels.deinit(allocator);
    var runs: std.ArrayList(BidiRun) = .empty;
    errdefer runs.deinit(allocator);

    var offset: usize = 0;
    while (offset < utf8.len) {
        var actual_length: usize = 0;
        var separator_length: usize = 0;
        c.SBAlgorithmGetParagraphBoundary(
            algorithm,
            offset,
            utf8.len - offset,
            &actual_length,
            &separator_length,
        );
        if (actual_length == 0 or actual_length > utf8.len - offset or
            separator_length > actual_length) return error.InvalidBidiResult;
        const paragraph = c.SBAlgorithmCreateParagraph(
            algorithm,
            offset,
            actual_length,
            sheenBaseLevel(direction),
        ) orelse return error.OutOfMemory;
        defer c.SBParagraphRelease(paragraph);
        if (c.SBParagraphGetOffset(paragraph) != offset or
            c.SBParagraphGetLength(paragraph) != actual_length) return error.InvalidBidiResult;

        const level_pointer = c.SBParagraphGetLevelsPtr(paragraph) orelse
            return error.InvalidBidiResult;
        const level_start = levels.items.len;
        try levels.appendSlice(allocator, level_pointer[0..actual_length]);

        const run_start = runs.items.len;
        var local_start: usize = 0;
        while (local_start < actual_length) {
            const level = level_pointer[local_start];
            var local_end = local_start + 1;
            while (local_end < actual_length and level_pointer[local_end] == level) {
                local_end += 1;
            }
            try runs.append(allocator, .{
                .byte_start = offset + local_start,
                .byte_len = local_end - local_start,
                .level = level,
            });
            local_start = local_end;
        }
        try paragraphs.append(allocator, .{
            .byte_start = offset,
            .byte_len = actual_length,
            .separator_len = separator_length,
            .base_level = c.SBParagraphGetBaseLevel(paragraph),
            .level_start = level_start,
            .run_start = run_start,
            .run_count = runs.items.len - run_start,
        });
        offset += actual_length;
    }

    const owned_paragraphs = try paragraphs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_paragraphs);
    const owned_levels = try levels.toOwnedSlice(allocator);
    errdefer allocator.free(owned_levels);
    const owned_runs = try runs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_runs);
    return .{
        .allocator = allocator,
        .paragraphs = owned_paragraphs,
        .levels = owned_levels,
        .runs = owned_runs,
    };
}

fn emptyAnalysis(allocator: std.mem.Allocator, direction: BaseDirection) !BidiAnalysis {
    const paragraphs = try allocator.alloc(BidiParagraph, 1);
    errdefer allocator.free(paragraphs);
    const levels = try allocator.alloc(u8, 0);
    errdefer allocator.free(levels);
    const runs = try allocator.alloc(BidiRun, 0);
    errdefer allocator.free(runs);
    paragraphs[0] = .{
        .byte_start = 0,
        .byte_len = 0,
        .separator_len = 0,
        .base_level = switch (direction) {
            .auto_left_to_right, .left_to_right => 0,
            .auto_right_to_left, .right_to_left => 1,
        },
        .level_start = 0,
        .run_start = 0,
        .run_count = 0,
    };
    return .{
        .allocator = allocator,
        .paragraphs = paragraphs,
        .levels = levels,
        .runs = runs,
    };
}

fn sheenBaseLevel(direction: BaseDirection) c.SBLevel {
    return switch (direction) {
        .auto_left_to_right => c.SBLevelDefaultLTR,
        .auto_right_to_left => c.SBLevelDefaultRTL,
        .left_to_right => 0,
        .right_to_left => 1,
    };
}

test "bidi analysis exposes mixed-direction logical runs in UTF-8 byte ranges" {
    const value = "abc אבג";
    var analysis = try analyzeBidi(std.testing.allocator, value, .auto_left_to_right);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.paragraphs.len);
    const paragraph = analysis.paragraphs[0];
    try std.testing.expectEqual(@as(u8, 0), paragraph.base_level);
    const runs = analysis.runsFor(paragraph);
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqual(BidiRun{ .byte_start = 0, .byte_len = 4, .level = 0 }, runs[0]);
    try std.testing.expectEqual(BidiRun{ .byte_start = 4, .byte_len = 6, .level = 1 }, runs[1]);
    try std.testing.expect(!runs[0].rightToLeft());
    try std.testing.expect(runs[1].rightToLeft());
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 }, analysis.levelsFor(paragraph));
}

test "bidi analysis preserves paragraph separators and explicit base direction" {
    var analysis = try analyzeBidi(std.testing.allocator, "one\r\nשתיים\n", .right_to_left);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 2), analysis.paragraphs.len);
    try std.testing.expectEqual(@as(usize, 5), analysis.paragraphs[0].byte_len);
    try std.testing.expectEqual(@as(usize, 2), analysis.paragraphs[0].separator_len);
    try std.testing.expectEqual(@as(u8, 1), analysis.paragraphs[0].base_level);
    try std.testing.expectEqual(@as(usize, 11), analysis.paragraphs[1].byte_len);
    try std.testing.expectEqual(@as(usize, 1), analysis.paragraphs[1].separator_len);
}

test "bidi runs remain contiguous in logical order through isolates" {
    const value = "LTR \u{2067}אבג 123\u{2069} tail";
    var analysis = try analyzeBidi(std.testing.allocator, value, .auto_left_to_right);
    defer analysis.deinit();
    const paragraph = analysis.paragraphs[0];
    const levels = analysis.levelsFor(paragraph);
    var expected_start = paragraph.byte_start;
    for (analysis.runsFor(paragraph)) |run| {
        try std.testing.expectEqual(expected_start, run.byte_start);
        try std.testing.expect(run.byte_len != 0);
        for (levels[run.byte_start - paragraph.byte_start ..][0..run.byte_len]) |level| {
            try std.testing.expectEqual(run.level, level);
        }
        expected_start += run.byte_len;
    }
    try std.testing.expectEqual(paragraph.byte_start + paragraph.byte_len, expected_start);
}

test "bidi analysis defines empty input and rejects malformed UTF-8" {
    var empty = try analyzeBidi(std.testing.allocator, "", .auto_right_to_left);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty.paragraphs.len);
    try std.testing.expectEqual(@as(u8, 1), empty.paragraphs[0].base_level);
    try std.testing.expectError(
        error.InvalidUtf8,
        analyzeBidi(std.testing.allocator, "broken\xff", .auto_left_to_right),
    );
}

test "bidi analysis unwinds every caller-owned allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    var analysis = try analyzeBidi(
        allocator,
        "LTR \u{2067}אבג 123\u{2069}\r\nsecond paragraph",
        .auto_left_to_right,
    );
    defer analysis.deinit();
    std.mem.doNotOptimizeAway(analysis.runs.len);
}
