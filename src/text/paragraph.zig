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

pub const LineRange = struct {
    byte_start: usize,
    byte_len: usize,
};

/// One line-local embedding-level run in visual left-to-right order. The byte
/// range remains a logical range into the original UTF-8 text.
pub const VisualRun = struct {
    byte_start: usize,
    byte_len: usize,
    level: u8,

    pub fn rightToLeft(self: VisualRun) bool {
        return self.level & 1 != 0;
    }
};

pub const VisualLine = struct {
    byte_start: usize,
    byte_len: usize,
    base_level: u8,
    run_start: usize,
    run_count: usize,
};

pub const VisualLines = struct {
    allocator: std.mem.Allocator,
    lines: []VisualLine,
    runs: []VisualRun,

    pub fn deinit(self: *VisualLines) void {
        self.allocator.free(self.runs);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn runsFor(self: *const VisualLines, line: VisualLine) []const VisualRun {
        return self.runs[line.run_start..][0..line.run_count];
    }
};

/// Applies UAX #9 L1-L2 to already-selected contiguous line ranges. SheenBidi
/// resets line-local trailing whitespace and returns level runs in visual
/// left-to-right order. For UTF-8, every offset and length is a byte count.
pub fn reorderLines(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    direction: BaseDirection,
    ranges: []const LineRange,
) !VisualLines {
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;
    try validateLineRanges(utf8, ranges);

    var lines: std.ArrayList(VisualLine) = .empty;
    errdefer lines.deinit(allocator);
    var runs: std.ArrayList(VisualRun) = .empty;
    errdefer runs.deinit(allocator);
    if (utf8.len == 0) {
        try lines.append(allocator, .{
            .byte_start = 0,
            .byte_len = 0,
            .base_level = switch (direction) {
                .auto_left_to_right, .left_to_right => 0,
                .auto_right_to_left, .right_to_left => 1,
            },
            .run_start = 0,
            .run_count = 0,
        });
        return ownedVisualLines(allocator, &lines, &runs);
    }

    const sequence: c.SBCodepointSequence = .{
        .stringEncoding = c.SBStringEncodingUTF8,
        .stringBuffer = utf8.ptr,
        .stringLength = utf8.len,
    };
    const algorithm = c.SBAlgorithmCreate(&sequence) orelse return error.OutOfMemory;
    defer c.SBAlgorithmRelease(algorithm);

    var paragraph_offset: usize = 0;
    var range_index: usize = 0;
    while (paragraph_offset < utf8.len) {
        var paragraph_len: usize = 0;
        var separator_len: usize = 0;
        c.SBAlgorithmGetParagraphBoundary(
            algorithm,
            paragraph_offset,
            utf8.len - paragraph_offset,
            &paragraph_len,
            &separator_len,
        );
        if (paragraph_len == 0 or paragraph_len > utf8.len - paragraph_offset)
            return error.InvalidBidiResult;
        const paragraph_end = paragraph_offset + paragraph_len;
        const paragraph = c.SBAlgorithmCreateParagraph(
            algorithm,
            paragraph_offset,
            paragraph_len,
            sheenBaseLevel(direction),
        ) orelse return error.OutOfMemory;
        defer c.SBParagraphRelease(paragraph);
        const base_level = c.SBParagraphGetBaseLevel(paragraph);

        while (range_index < ranges.len and ranges[range_index].byte_start < paragraph_end) {
            const range = ranges[range_index];
            const range_end = range.byte_start + range.byte_len;
            if (range.byte_start < paragraph_offset or range_end > paragraph_end or
                range.byte_len == 0) return error.LineCrossesParagraph;
            const bidi_line = c.SBParagraphCreateLine(
                paragraph,
                range.byte_start,
                range.byte_len,
            ) orelse return error.OutOfMemory;
            defer c.SBLineRelease(bidi_line);
            if (c.SBLineGetOffset(bidi_line) != range.byte_start or
                c.SBLineGetLength(bidi_line) != range.byte_len)
                return error.InvalidBidiResult;

            const run_start = runs.items.len;
            const run_count = c.SBLineGetRunCount(bidi_line);
            const run_pointer = c.SBLineGetRunsPtr(bidi_line);
            if (run_count == 0 or run_pointer == null) return error.InvalidBidiResult;
            var covered: usize = 0;
            for (run_pointer[0..run_count]) |run| {
                const run_end = std.math.add(usize, run.offset, run.length) catch
                    return error.InvalidBidiResult;
                if (run.length == 0 or run.offset < range.byte_start or run_end > range_end)
                    return error.InvalidBidiResult;
                covered += run.length;
                try runs.append(allocator, .{
                    .byte_start = run.offset,
                    .byte_len = run.length,
                    .level = run.level,
                });
            }
            if (covered != range.byte_len) return error.InvalidBidiResult;
            try lines.append(allocator, .{
                .byte_start = range.byte_start,
                .byte_len = range.byte_len,
                .base_level = base_level,
                .run_start = run_start,
                .run_count = runs.items.len - run_start,
            });
            range_index += 1;
        }
        paragraph_offset = paragraph_end;
    }
    if (range_index != ranges.len) return error.InvalidLineRanges;
    return ownedVisualLines(allocator, &lines, &runs);
}

fn validateLineRanges(utf8: []const u8, ranges: []const LineRange) !void {
    if (ranges.len == 0) return error.InvalidLineRanges;
    if (utf8.len == 0 and (ranges.len != 1 or ranges[0].byte_start != 0 or
        ranges[0].byte_len != 0)) return error.InvalidLineRanges;
    var expected_start: usize = 0;
    for (ranges) |range| {
        const end = std.math.add(usize, range.byte_start, range.byte_len) catch
            return error.InvalidLineRanges;
        if (range.byte_start != expected_start or end > utf8.len or
            !isCodepointBoundary(utf8, range.byte_start) or
            !isCodepointBoundary(utf8, end)) return error.InvalidLineRanges;
        expected_start = end;
    }
    if (expected_start != utf8.len)
        return error.InvalidLineRanges;
}

fn isCodepointBoundary(utf8: []const u8, index: usize) bool {
    return index == 0 or index == utf8.len or utf8[index] & 0xc0 != 0x80;
}

fn ownedVisualLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(VisualLine),
    runs: *std.ArrayList(VisualRun),
) !VisualLines {
    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    return .{
        .allocator = allocator,
        .lines = owned_lines,
        .runs = try runs.toOwnedSlice(allocator),
    };
}

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

test "selected lines receive line-local L1 levels and visual L2 run order" {
    const utf8 = "abc אבג xyz";
    var visual = try reorderLines(std.testing.allocator, utf8, .left_to_right, &.{
        .{ .byte_start = 0, .byte_len = 11 },
        .{ .byte_start = 11, .byte_len = 3 },
    });
    defer visual.deinit();
    try std.testing.expectEqual(@as(usize, 2), visual.lines.len);
    try std.testing.expectEqualSlices(VisualRun, &.{
        .{ .byte_start = 0, .byte_len = 4, .level = 0 },
        .{ .byte_start = 4, .byte_len = 6, .level = 1 },
        // UAX #9 L1 resets this line's trailing space to the base level.
        .{ .byte_start = 10, .byte_len = 1, .level = 0 },
    }, visual.runsFor(visual.lines[0]));
    try std.testing.expectEqualSlices(VisualRun, &.{
        .{ .byte_start = 11, .byte_len = 3, .level = 0 },
    }, visual.runsFor(visual.lines[1]));
}

test "visual line ordering preserves paragraphs and validates boundaries" {
    const utf8 = "one\nאבג";
    var visual = try reorderLines(std.testing.allocator, utf8, .auto_left_to_right, &.{
        .{ .byte_start = 0, .byte_len = 4 },
        .{ .byte_start = 4, .byte_len = 6 },
    });
    defer visual.deinit();
    try std.testing.expectEqual(@as(u8, 0), visual.lines[0].base_level);
    try std.testing.expectEqual(@as(u8, 1), visual.lines[1].base_level);
    try std.testing.expect(visual.runsFor(visual.lines[1])[0].rightToLeft());

    try std.testing.expectError(error.LineCrossesParagraph, reorderLines(
        std.testing.allocator,
        utf8,
        .auto_left_to_right,
        &.{.{ .byte_start = 0, .byte_len = utf8.len }},
    ));
    try std.testing.expectError(error.InvalidLineRanges, reorderLines(
        std.testing.allocator,
        "é",
        .left_to_right,
        &.{
            .{ .byte_start = 0, .byte_len = 1 },
            .{ .byte_start = 1, .byte_len = 1 },
        },
    ));
}

test "visual line ordering defines empty input and unwinds allocations" {
    var empty = try reorderLines(
        std.testing.allocator,
        "",
        .right_to_left,
        &.{.{ .byte_start = 0, .byte_len = 0 }},
    );
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 1), empty.lines.len);
    try std.testing.expectEqual(@as(u8, 1), empty.lines[0].base_level);
    try std.testing.expectEqual(@as(usize, 0), empty.runs.len);
    try std.testing.expectError(error.InvalidLineRanges, reorderLines(
        std.testing.allocator,
        "",
        .left_to_right,
        &.{
            .{ .byte_start = 0, .byte_len = 0 },
            .{ .byte_start = 0, .byte_len = 0 },
        },
    ));

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseVisualAllocationFailure,
        .{},
    );
}

fn exerciseVisualAllocationFailure(allocator: std.mem.Allocator) !void {
    var visual = try reorderLines(allocator, "abc אבג", .auto_left_to_right, &.{
        .{ .byte_start = 0, .byte_len = 4 },
        .{ .byte_start = 4, .byte_len = 6 },
    });
    defer visual.deinit();
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
