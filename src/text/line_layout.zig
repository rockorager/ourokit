//! Glue between measured opportunities, wrap policy, and line-local bidi.

const std = @import("std");
const line_break = @import("line_break.zig");
const measurement = @import("measurement.zig");
const paragraph = @import("paragraph.zig");
const greedy = @import("wrap/greedy.zig");

pub const Line = struct {
    byte_start: usize,
    byte_len: usize,
    advance: f32,
    mandatory: bool,
    /// Unsafe HarfBuzz boundaries require reshaping both adjacent line
    /// fragments before their glyphs can be emitted.
    reshape_start: bool,
    reshape_end: bool,
    base_level: u8,
    visual_run_start: usize,
    visual_run_count: usize,
};

pub const GreedyLines = struct {
    allocator: std.mem.Allocator,
    max_width: f32,
    lines: []Line,
    visual_runs: []paragraph.VisualRun,

    pub fn deinit(self: *GreedyLines) void {
        self.allocator.free(self.visual_runs);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn visualRunsFor(self: *const GreedyLines, line: Line) []const paragraph.VisualRun {
        return self.visual_runs[line.visual_run_start..][0..line.visual_run_count];
    }
};

/// Selects greedy lines from shaped measurements, then applies SheenBidi's
/// line-specific UAX #9 L1-L2 processing. This stage does not reshape unsafe
/// boundaries; it marks exactly which adjacent fragments require that work.
pub fn selectGreedyLines(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    breaks: []const line_break.LineBreak,
    measured: *const measurement.Measurement,
    max_width: f32,
) !GreedyLines {
    if (breaks.len != measured.segments.len) return error.InvalidMeasurements;
    const advances = try measured.advances(allocator);
    defer allocator.free(advances);
    var wrapped = try greedy.wrap(allocator, breaks, advances, max_width);
    defer wrapped.deinit();

    const ranges = try allocator.alloc(paragraph.LineRange, wrapped.lines.len);
    defer allocator.free(ranges);
    for (ranges, wrapped.lines) |*range, line| range.* = .{
        .byte_start = line.byte_start,
        .byte_len = line.byte_len,
    };
    var visual = try paragraph.reorderLines(allocator, utf8, base_direction, ranges);
    defer visual.deinit();
    if (visual.lines.len != wrapped.lines.len) return error.InvalidVisualOrder;

    const lines = try allocator.alloc(Line, wrapped.lines.len);
    errdefer allocator.free(lines);
    var opportunity_index: usize = 0;
    var reshape_start = false;
    for (lines, wrapped.lines, visual.lines) |*line, wrapped_line, visual_line| {
        const line_end = wrapped_line.byte_start + wrapped_line.byte_len;
        while (opportunity_index < breaks.len and
            breaks[opportunity_index].byte_offset < line_end)
            opportunity_index += 1;
        if (opportunity_index == breaks.len or
            breaks[opportunity_index].byte_offset != line_end)
            return error.InvalidMeasurements;
        if (visual_line.byte_start != wrapped_line.byte_start or
            visual_line.byte_len != wrapped_line.byte_len)
            return error.InvalidVisualOrder;
        const reshape_end = measured.segments[opportunity_index].requires_reshape;
        line.* = .{
            .byte_start = wrapped_line.byte_start,
            .byte_len = wrapped_line.byte_len,
            .advance = wrapped_line.advance,
            .mandatory = wrapped_line.mandatory,
            .reshape_start = reshape_start,
            .reshape_end = reshape_end,
            .base_level = visual_line.base_level,
            .visual_run_start = visual_line.run_start,
            .visual_run_count = visual_line.run_count,
        };
        reshape_start = reshape_end;
        opportunity_index += 1;
    }

    const visual_runs = visual.runs;
    visual.runs = &.{};
    return .{
        .allocator = allocator,
        .max_width = max_width,
        .lines = lines,
        .visual_runs = visual_runs,
    };
}

test "real shaping flows through greedy selection and line-local bidi" {
    const api = @import("api.zig");
    const itemization = @import("itemization.zig");
    const shaped_paragraph = @import("shaped_paragraph.zig");
    const utf8 = "Save حفظ now";
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
    var shaped = try shaped_paragraph.shapeItemizedParagraphs(
        std.testing.allocator,
        utf8,
        &itemized,
        &.{
            .{ .handle = .{ .slot = 1, .generation = 1 }, .font = &latin },
            .{ .handle = .{ .slot = 2, .generation = 1 }, .font = &arabic },
        },
        "und",
        14,
    );
    defer shaped.deinit();
    var opportunities = try line_break.analyzeLineBreaks(std.testing.allocator, utf8);
    defer opportunities.deinit();
    var measured = try measurement.measureBreakSegments(
        std.testing.allocator,
        opportunities.breaks,
        &shaped,
    );
    defer measured.deinit();

    var measured_advance: f32 = 0;
    for (measured.segments) |segment| measured_advance += segment.advance;
    var shaped_advance: f32 = 0;
    for (shaped.runs) |run| shaped_advance += run.result.advance.x;
    try std.testing.expectApproxEqAbs(shaped_advance, measured_advance, 0.001);

    var selected = try selectGreedyLines(
        std.testing.allocator,
        utf8,
        .auto_left_to_right,
        opportunities.breaks,
        &measured,
        measured.segments[0].advance + 0.01,
    );
    defer selected.deinit();
    try std.testing.expect(selected.lines.len >= 2);
    var saw_rtl = false;
    for (selected.lines) |line| {
        for (selected.visualRunsFor(line)) |run|
            saw_rtl = saw_rtl or run.rightToLeft();
    }
    try std.testing.expect(saw_rtl);
}

test "greedy line selection propagates unsafe boundaries and allocation failures" {
    var segments = [_]measurement.Segment{
        .{ .advance = 4, .requires_reshape = true },
        .{ .advance = 4 },
    };
    const measured: measurement.Measurement = .{
        .allocator = std.testing.allocator,
        .segments = &segments,
    };
    var selected = try selectGreedyLines(
        std.testing.allocator,
        "a b ",
        .left_to_right,
        &.{
            .{ .byte_offset = 2, .kind = .allowed },
            .{ .byte_offset = 4, .kind = .mandatory },
        },
        &measured,
        4,
    );
    defer selected.deinit();
    try std.testing.expect(selected.lines[0].reshape_end);
    try std.testing.expect(selected.lines[1].reshape_start);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    var segments = [_]measurement.Segment{.{ .advance = 1 }};
    const measured: measurement.Measurement = .{
        .allocator = allocator,
        .segments = &segments,
    };
    var selected = try selectGreedyLines(
        allocator,
        "x",
        .left_to_right,
        &.{.{ .byte_offset = 1, .kind = .mandatory }},
        &measured,
        1,
    );
    defer selected.deinit();
}
