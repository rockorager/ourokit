//! Logical advance measurement at shared Unicode line-break opportunities.

const std = @import("std");
const api = @import("api.zig");
const line_break = @import("line_break.zig");
const shaped_paragraph = @import("shaped_paragraph.zig");

pub const Segment = struct {
    /// Horizontal advance since the preceding opportunity.
    advance: f32 = 0,
    /// Breaking here requires reshaping both adjacent fragments according to
    /// HarfBuzz's `HB_GLYPH_FLAG_UNSAFE_TO_BREAK` contract.
    requires_reshape: bool = false,
};

pub const Measurement = struct {
    allocator: std.mem.Allocator,
    segments: []Segment,

    pub fn deinit(self: *Measurement) void {
        self.allocator.free(self.segments);
        self.* = undefined;
    }

    pub fn advances(self: *const Measurement, allocator: std.mem.Allocator) ![]f32 {
        const result = try allocator.alloc(f32, self.segments.len);
        for (result, self.segments) |*advance, segment| advance.* = segment.advance;
        return result;
    }
};

/// Projects logical HarfBuzz cluster advances onto UAX #14 opportunities.
/// Work is linear in opportunities plus glyphs. Whole-run shaping provides
/// provisional widths for selection; `requires_reshape` prevents callers from
/// incorrectly reusing glyphs across an unsafe selected boundary.
pub fn measureBreakSegments(
    allocator: std.mem.Allocator,
    breaks: []const line_break.LineBreak,
    shaped: *const shaped_paragraph.ShapedParagraphs,
) !Measurement {
    if (breaks.len == 0 or breaks[breaks.len - 1].byte_offset != shaped.text_len or
        breaks[breaks.len - 1].kind != .mandatory)
        return error.InvalidBreaks;
    const segments = try allocator.alloc(Segment, breaks.len);
    errdefer allocator.free(segments);
    @memset(segments, .{});

    var previous_break: usize = 0;
    for (breaks) |opportunity| {
        if (opportunity.byte_offset < previous_break or opportunity.byte_offset > shaped.text_len)
            return error.InvalidBreaks;
        previous_break = opportunity.byte_offset;
    }

    var previous_run_end: usize = 0;
    var opportunity_index: usize = 0;
    for (shaped.runs) |*shaped_run| {
        const run_end = std.math.add(usize, shaped_run.byte_start, shaped_run.byte_len) catch
            return error.InvalidShaping;
        if (shaped_run.byte_start < previous_run_end or run_end > shaped.text_len)
            return error.InvalidShaping;
        previous_run_end = run_end;
        while (opportunity_index < breaks.len and
            breaks[opportunity_index].byte_offset < shaped_run.byte_start)
            opportunity_index += 1;

        for (shaped_run.result.spans) |span| {
            try measureSpan(
                segments,
                breaks,
                &opportunity_index,
                shaped_run.paragraph_start,
                span.run,
                shaped_run.byte_start,
                run_end,
            );
        }
    }
    for (segments) |segment|
        if (!std.math.isFinite(segment.advance) or segment.advance < 0)
            return error.InvalidShaping;
    return .{ .allocator = allocator, .segments = segments };
}

fn measureSpan(
    segments: []Segment,
    breaks: []const line_break.LineBreak,
    opportunity_index: *usize,
    paragraph_start: usize,
    run: api.ShapedRun,
    itemized_start: usize,
    itemized_end: usize,
) !void {
    const span_end = std.math.add(usize, run.byte_start, run.byte_len) catch
        return error.InvalidShaping;
    const document_start = std.math.add(usize, paragraph_start, run.byte_start) catch
        return error.InvalidShaping;
    const document_end = std.math.add(usize, paragraph_start, span_end) catch
        return error.InvalidShaping;
    if (document_start < itemized_start or document_end > itemized_end)
        return error.InvalidShaping;

    var index: usize = switch (run.direction) {
        .left_to_right => 0,
        .right_to_left => run.glyphs.len,
        else => return error.UnsupportedDirection,
    };
    var previous_cluster: ?usize = null;
    while (nextLogicalCluster(run.glyphs, run.direction, &index)) |glyph_cluster| {
        const cluster = std.math.add(usize, paragraph_start, glyph_cluster.byte_offset) catch
            return error.InvalidShaping;
        if (cluster < document_start or cluster >= document_end) return error.InvalidShaping;
        if (previous_cluster) |previous| {
            if (cluster < previous) return error.InvalidShaping;
            if (cluster != previous) {
                while (opportunity_index.* < breaks.len and
                    breaks[opportunity_index.*].byte_offset < cluster)
                {
                    if (breaks[opportunity_index.*].byte_offset > previous)
                        segments[opportunity_index.*].requires_reshape = true;
                    opportunity_index.* += 1;
                }
            }
        }
        while (opportunity_index.* < breaks.len and
            breaks[opportunity_index.*].byte_offset <= cluster)
        {
            if (breaks[opportunity_index.*].byte_offset == cluster and
                glyph_cluster.unsafe_to_break)
                segments[opportunity_index.*].requires_reshape = true;
            opportunity_index.* += 1;
        }
        if (opportunity_index.* >= segments.len) return error.InvalidShaping;
        segments[opportunity_index.*].advance += glyph_cluster.advance;
        previous_cluster = cluster;
    }
    if (previous_cluster) |cluster| {
        while (opportunity_index.* < breaks.len and
            breaks[opportunity_index.*].byte_offset < document_end)
        {
            if (breaks[opportunity_index.*].byte_offset > cluster)
                segments[opportunity_index.*].requires_reshape = true;
            opportunity_index.* += 1;
        }
    }
}

const GlyphCluster = struct {
    byte_offset: usize,
    advance: f32,
    unsafe_to_break: bool,
};

fn nextLogicalCluster(
    glyphs: []const api.Glyph,
    direction: api.Direction,
    index: *usize,
) ?GlyphCluster {
    return switch (direction) {
        .left_to_right => if (index.* < glyphs.len) value: {
            const cluster = glyphs[index.*].cluster;
            var result: GlyphCluster = .{
                .byte_offset = cluster,
                .advance = 0,
                .unsafe_to_break = false,
            };
            while (index.* < glyphs.len and glyphs[index.*].cluster == cluster) {
                result.advance += glyphs[index.*].advance.x;
                result.unsafe_to_break = result.unsafe_to_break or
                    glyphs[index.*].unsafe_to_break;
                index.* += 1;
            }
            break :value result;
        } else null,
        .right_to_left => if (index.* != 0) value: {
            const cluster = glyphs[index.* - 1].cluster;
            var result: GlyphCluster = .{
                .byte_offset = cluster,
                .advance = 0,
                .unsafe_to_break = false,
            };
            while (index.* != 0 and glyphs[index.* - 1].cluster == cluster) {
                index.* -= 1;
                result.advance += glyphs[index.*].advance.x;
                result.unsafe_to_break = result.unsafe_to_break or
                    glyphs[index.*].unsafe_to_break;
            }
            break :value result;
        } else null,
        else => null,
    };
}

test "real HarfBuzz clusters measure legal break segments" {
    const utf8 = "office text";
    var itemized = try @import("itemization.zig").itemizeParagraphs(
        std.testing.allocator,
        utf8,
        .auto_left_to_right,
    );
    defer itemized.deinit();
    var font = try api.Font.init(@embedFile("ourokit_test_font"), 0);
    defer font.deinit();
    var shaped = try shaped_paragraph.shapeItemizedParagraphs(
        std.testing.allocator,
        utf8,
        &itemized,
        &.{.{ .handle = .{ .slot = 1, .generation = 1 }, .font = &font }},
        "en",
        16,
    );
    defer shaped.deinit();
    var opportunities = try line_break.analyzeLineBreaks(std.testing.allocator, utf8);
    defer opportunities.deinit();
    var measured = try measureBreakSegments(
        std.testing.allocator,
        opportunities.breaks,
        &shaped,
    );
    defer measured.deinit();

    try std.testing.expectEqual(opportunities.breaks.len, measured.segments.len);
    var total: f32 = 0;
    for (measured.segments) |segment| total += segment.advance;
    try std.testing.expectApproxEqAbs(shaped.runs[0].result.advance.x, total, 0.001);
}

test "unsafe cluster boundaries are explicit" {
    var glyphs = [_]api.Glyph{
        .{ .id = 1, .cluster = 0, .advance = .{ .x = 4 }, .offset = .{}, .unsafe_to_break = false },
        .{ .id = 2, .cluster = 2, .advance = .{ .x = 5 }, .offset = .{}, .unsafe_to_break = true },
    };
    var spans = [_]api.ShapedSpan{.{
        .font = .{ .slot = 1, .generation = 1 },
        .run = .{
            .allocator = std.testing.allocator,
            .glyphs = &glyphs,
            .direction = .left_to_right,
            .byte_start = 0,
            .byte_len = 4,
            .advance = .{ .x = 9 },
            .metrics = .{ .ascender = 1, .descender = 0, .line_gap = 0 },
        },
    }};
    var runs = [_]shaped_paragraph.ShapedItemizedRun{.{
        .byte_start = 0,
        .byte_len = 4,
        .paragraph_start = 0,
        .paragraph_content_len = 4,
        .level = 0,
        .script = .latin,
        .result = .{
            .allocator = std.testing.allocator,
            .spans = &spans,
            .logical_size = 12,
            .advance = .{ .x = 9 },
            .metrics = .{ .ascender = 1, .descender = 0, .line_gap = 0 },
            .has_missing_glyphs = false,
        },
    }};
    const shaped: shaped_paragraph.ShapedParagraphs = .{
        .allocator = std.testing.allocator,
        .text_len = 4,
        .candidates = &.{},
        .language = "und",
        .logical_size = 12,
        .runs = &runs,
    };
    var measured = try measureBreakSegments(std.testing.allocator, &.{
        .{ .byte_offset = 2, .kind = .allowed },
        .{ .byte_offset = 4, .kind = .mandatory },
    }, &shaped);
    defer measured.deinit();
    try std.testing.expect(measured.segments[0].requires_reshape);
    try std.testing.expectEqual(@as(f32, 4), measured.segments[0].advance);
    try std.testing.expectEqual(@as(f32, 5), measured.segments[1].advance);
}

test "break measurement unwinds every output allocation failure" {
    const shaped: shaped_paragraph.ShapedParagraphs = .{
        .allocator = std.testing.allocator,
        .text_len = 0,
        .candidates = &.{},
        .language = "und",
        .logical_size = 12,
        .runs = &.{},
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{&shaped},
    );
}

fn exerciseAllocationFailure(
    allocator: std.mem.Allocator,
    shaped: *const shaped_paragraph.ShapedParagraphs,
) !void {
    var measured = try measureBreakSegments(allocator, &.{.{
        .byte_offset = 0,
        .kind = .mandatory,
    }}, shaped);
    defer measured.deinit();
}
