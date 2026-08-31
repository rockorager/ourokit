//! Final headless assembly of selected lines into positioned glyph spans.

const std = @import("std");
const PointF = @import("../core/geometry.zig").PointF;
const api = @import("api.zig");
const line_layout = @import("line_layout.zig");
const paragraph = @import("paragraph.zig");
const paragraph_style = @import("paragraph_style.zig");
const shaped_paragraph = @import("shaped_paragraph.zig");

pub const Glyph = struct {
    id: u32,
    /// Document-relative logical source cluster.
    cluster: usize,
    /// Logical glyph origin relative to the line's left-edge baseline. Y grows
    /// downward, unlike HarfBuzz's Y coordinates.
    origin: PointF,
    advance: PointF,
    /// True for presentation glyphs such as an ellipsis that do not consume a
    /// source range. Their cluster is the source insertion boundary.
    synthetic: bool = false,
};

pub const Span = struct {
    font: api.FontHandle,
    direction: api.Direction,
    byte_start: usize,
    byte_len: usize,
    advance: f32,
    glyph_start: usize,
    glyph_count: usize,
};

pub const Line = struct {
    byte_start: usize,
    byte_len: usize,
    /// Logical top edge relative to the paragraph origin.
    top: f32,
    /// Physical offset from the paragraph's left edge. Start and end are
    /// resolved from this line's UAX #9 base direction during positioning.
    left: f32,
    advance: f32,
    ascender: f32,
    descender: f32,
    line_gap: f32,
    /// Distance from the line's top edge to its baseline.
    baseline: f32,
    span_start: usize,
    span_count: usize,
    glyph_start: usize,
    glyph_count: usize,
};

pub const PositionedLines = struct {
    allocator: std.mem.Allocator,
    lines: []Line,
    spans: []Span,
    glyphs: []Glyph,
    layout_width: f32,
    truncated: bool,
    source_byte_len: usize,
    ellipsis_byte_offset: ?usize,

    pub fn deinit(self: *PositionedLines) void {
        self.allocator.free(self.glyphs);
        self.allocator.free(self.spans);
        self.allocator.free(self.lines);
        self.* = undefined;
    }

    pub fn spansFor(self: *const PositionedLines, line: Line) []const Span {
        return self.spans[line.span_start..][0..line.span_count];
    }

    pub fn glyphsFor(self: *const PositionedLines, span: Span) []const Glyph {
        return self.glyphs[span.glyph_start..][0..span.glyph_count];
    }

    pub fn width(self: *const PositionedLines) f32 {
        return self.layout_width;
    }

    pub fn height(self: *const PositionedLines) f32 {
        if (self.lines.len == 0) return 0;
        const last = self.lines[self.lines.len - 1];
        return last.top + @max(0, last.ascender - last.descender + last.line_gap);
    }
};

const Fragment = struct {
    byte_start: usize,
    byte_len: usize,
    paragraph_start: usize,
    borrowed: *const api.FallbackResult,
    owned: ?api.FallbackResult = null,

    fn result(self: *const Fragment) *const api.FallbackResult {
        return if (self.owned) |*value| value else self.borrowed;
    }

    fn deinit(self: *Fragment) void {
        if (self.owned) |*value| value.deinit();
    }
};

/// Converts selected logical lines and visual bidi runs into backend-neutral,
/// positioned glyph spans. Safe boundaries reuse paragraph shaping. A line
/// touching an unsafe HarfBuzz boundary is conservatively reshaped in full;
/// changed advances return `error.ReflowRequired` rather than accepting stale
/// greedy selection.
pub fn positionLines(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    selected: *const line_layout.GreedyLines,
) !PositionedLines {
    return positionLinesWithStyle(allocator, utf8, shaped, selected, .{}, null);
}

/// Positions only visible lines and resolves physical line offsets. A finite
/// available width makes paragraph alignment observable; null preserves the
/// natural width used by unconstrained measurement.
pub fn positionLinesWithStyle(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    selected: *const line_layout.GreedyLines,
    style: paragraph_style.Style,
    available_width: ?f32,
) !PositionedLines {
    if (utf8.len != shaped.text_len) return error.InvalidShaping;
    if (style.max_lines == 0) return error.InvalidMaxLines;
    if (available_width) |width|
        if (!std.math.isFinite(width) or width < 0) return error.InvalidWidth;
    const visible_count = @min(
        selected.lines.len,
        if (style.max_lines) |count| @as(usize, count) else selected.lines.len,
    );
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);
    var glyphs: std.ArrayList(Glyph) = .empty;
    errdefer glyphs.deinit(allocator);
    try lines.ensureTotalCapacity(allocator, visible_count);
    var line_top: f32 = 0;

    for (selected.lines[0..visible_count]) |selected_line| {
        if (!std.math.isFinite(selected_line.advance) or selected_line.advance < 0)
            return error.InvalidMeasurements;
        var fragments: std.ArrayList(Fragment) = .empty;
        defer {
            for (fragments.items) |*fragment| fragment.deinit();
            fragments.deinit(allocator);
        }
        try buildFragments(
            allocator,
            utf8,
            shaped,
            selected_line,
            &fragments,
        );

        const line_span_start = spans.items.len;
        const line_glyph_start = glyphs.items.len;
        var pen_x: f32 = 0;
        const visual_runs = selected.visualRunsFor(selected_line);
        for (visual_runs) |visual_run| try appendVisualRun(
            allocator,
            &spans,
            &glyphs,
            &pen_x,
            fragments.items,
            visual_run,
        );
        if (!std.math.isFinite(pen_x) or pen_x < 0) return error.InvalidShaping;

        const changed_advance = @abs(pen_x - selected_line.advance) > 0.001;
        if (changed_advance and (selected_line.reshape_start or selected_line.reshape_end))
            return error.ReflowRequired;
        if (changed_advance) return error.InvalidMeasurements;

        var metrics: api.Metrics = .{ .ascender = 0, .descender = 0, .line_gap = 0 };
        for (fragments.items) |*fragment| mergeMetrics(&metrics, fragment.result().metrics);
        const line_height = @max(0, metrics.ascender - metrics.descender + metrics.line_gap);
        if (!std.math.isFinite(line_height) or !std.math.isFinite(line_top))
            return error.InvalidShaping;
        lines.appendAssumeCapacity(.{
            .byte_start = selected_line.byte_start,
            .byte_len = selected_line.byte_len,
            .top = line_top,
            .left = alignmentOffset(
                style.alignment,
                available_width orelse pen_x,
                pen_x,
                selected_line.base_level,
            ),
            .advance = pen_x,
            .ascender = metrics.ascender,
            .descender = metrics.descender,
            .line_gap = metrics.line_gap,
            .baseline = metrics.ascender,
            .span_start = line_span_start,
            .span_count = spans.items.len - line_span_start,
            .glyph_start = line_glyph_start,
            .glyph_count = glyphs.items.len - line_glyph_start,
        });
        line_top += line_height;
    }

    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    const owned_spans = try spans.toOwnedSlice(allocator);
    errdefer allocator.free(owned_spans);
    var natural_width: f32 = 0;
    for (owned_lines) |line| natural_width = @max(natural_width, line.advance);
    return .{
        .allocator = allocator,
        .lines = owned_lines,
        .spans = owned_spans,
        .glyphs = try glyphs.toOwnedSlice(allocator),
        .layout_width = available_width orelse natural_width,
        .truncated = visible_count < selected.lines.len,
        .source_byte_len = utf8.len,
        .ellipsis_byte_offset = null,
    };
}

fn alignmentOffset(
    alignment: paragraph_style.Alignment,
    available_width: f32,
    line_width: f32,
    base_level: u8,
) f32 {
    const remaining = @max(0, available_width - line_width);
    return switch (alignment) {
        .start => if (base_level & 1 == 0) 0 else remaining,
        .end => if (base_level & 1 == 0) remaining else 0,
        .center => remaining / 2,
    };
}

fn buildFragments(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    line: line_layout.Line,
    fragments: *std.ArrayList(Fragment),
) !void {
    const line_end = std.math.add(usize, line.byte_start, line.byte_len) catch
        return error.InvalidShaping;
    for (shaped.runs) |*run| {
        const run_end = std.math.add(usize, run.byte_start, run.byte_len) catch
            return error.InvalidShaping;
        const byte_start = @max(line.byte_start, run.byte_start);
        const byte_end = @min(line_end, run_end);
        if (byte_start >= byte_end) continue;

        var fragment: Fragment = .{
            .byte_start = byte_start,
            .byte_len = byte_end - byte_start,
            .paragraph_start = run.paragraph_start,
            .borrowed = &run.result,
        };
        if (line.reshape_start or line.reshape_end) {
            const paragraph_end = std.math.add(
                usize,
                run.paragraph_start,
                run.paragraph_content_len,
            ) catch return error.InvalidShaping;
            if (paragraph_end > utf8.len) return error.InvalidShaping;
            fragment.owned = try api.shapeWithFallback(
                allocator,
                shaped.candidates,
                .{
                    .paragraph = utf8[run.paragraph_start..paragraph_end],
                    .byte_start = byte_start - run.paragraph_start,
                    .byte_len = byte_end - byte_start,
                    .direction = if (run.level & 1 == 0) .left_to_right else .right_to_left,
                    .script = run.script,
                    .language = shaped.language,
                    .logical_size = shaped.logical_size,
                },
            );
        }
        errdefer fragment.deinit();
        try fragments.append(allocator, fragment);
    }
}

fn appendVisualRun(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(Span),
    glyphs: *std.ArrayList(Glyph),
    pen_x: *f32,
    fragments: []const Fragment,
    visual_run: paragraph.VisualRun,
) !void {
    const visual_end = std.math.add(
        usize,
        visual_run.byte_start,
        visual_run.byte_len,
    ) catch return error.InvalidVisualOrder;
    const first = firstOverlappingFragment(fragments, visual_run.byte_start);
    var final = first;
    while (final < fragments.len and fragments[final].byte_start < visual_end) : (final += 1) {}
    if (visual_run.level & 1 == 0) {
        for (fragments[first..final]) |*fragment| try appendFragment(
            allocator,
            spans,
            glyphs,
            pen_x,
            fragment,
            visual_run,
            false,
        );
    } else {
        var index = final;
        while (index > first) {
            index -= 1;
            try appendFragment(
                allocator,
                spans,
                glyphs,
                pen_x,
                &fragments[index],
                visual_run,
                true,
            );
        }
    }
}

fn appendFragment(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(Span),
    glyphs: *std.ArrayList(Glyph),
    pen_x: *f32,
    fragment: *const Fragment,
    visual_run: paragraph.VisualRun,
    reverse_spans: bool,
) !void {
    const fragment_end = std.math.add(
        usize,
        fragment.byte_start,
        fragment.byte_len,
    ) catch return error.InvalidShaping;
    const visual_end = std.math.add(
        usize,
        visual_run.byte_start,
        visual_run.byte_len,
    ) catch return error.InvalidVisualOrder;
    const byte_start = @max(fragment.byte_start, visual_run.byte_start);
    const byte_end = @min(fragment_end, visual_end);
    if (byte_start >= byte_end) return;
    const source_spans = fragment.result().spans;
    if (!reverse_spans) {
        for (source_spans) |*span| try appendShapedSpan(
            allocator,
            spans,
            glyphs,
            pen_x,
            span,
            fragment.paragraph_start,
            byte_start,
            byte_end,
        );
    } else {
        var index = source_spans.len;
        while (index != 0) {
            index -= 1;
            try appendShapedSpan(
                allocator,
                spans,
                glyphs,
                pen_x,
                &source_spans[index],
                fragment.paragraph_start,
                byte_start,
                byte_end,
            );
        }
    }
}

fn appendShapedSpan(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(Span),
    glyphs: *std.ArrayList(Glyph),
    pen_x: *f32,
    span: *const api.ShapedSpan,
    paragraph_start: usize,
    byte_start: usize,
    byte_end: usize,
) !void {
    const span_start = std.math.add(usize, paragraph_start, span.run.byte_start) catch
        return error.InvalidShaping;
    const span_end = std.math.add(usize, span_start, span.run.byte_len) catch
        return error.InvalidShaping;
    const selected_start = @max(span_start, byte_start);
    const selected_end = @min(span_end, byte_end);
    if (selected_start >= selected_end) return;

    const glyph_start = glyphs.items.len;
    const pen_start = pen_x.*;
    for (span.run.glyphs) |glyph| {
        const cluster = std.math.add(usize, paragraph_start, glyph.cluster) catch
            return error.InvalidShaping;
        if (cluster < selected_start or cluster >= selected_end) continue;
        if (!std.math.isFinite(glyph.advance.x) or !std.math.isFinite(glyph.advance.y) or
            !std.math.isFinite(glyph.offset.x) or !std.math.isFinite(glyph.offset.y) or
            @abs(glyph.advance.y) > 0.001) return error.InvalidShaping;
        try glyphs.append(allocator, .{
            .id = glyph.id,
            .cluster = cluster,
            .origin = .{ .x = pen_x.* + glyph.offset.x, .y = -glyph.offset.y },
            .advance = .{ .x = glyph.advance.x, .y = -glyph.advance.y },
        });
        pen_x.* += glyph.advance.x;
    }
    const glyph_count = glyphs.items.len - glyph_start;
    if (glyph_count == 0) return;
    try spans.append(allocator, .{
        .font = span.font,
        .direction = span.run.direction,
        .byte_start = selected_start,
        .byte_len = selected_end - selected_start,
        .advance = pen_x.* - pen_start,
        .glyph_start = glyph_start,
        .glyph_count = glyph_count,
    });
}

fn firstOverlappingFragment(fragments: []const Fragment, byte_start: usize) usize {
    var low: usize = 0;
    var high = fragments.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (fragments[middle].byte_start + fragments[middle].byte_len <= byte_start)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

fn mergeMetrics(target: *api.Metrics, value: api.Metrics) void {
    target.ascender = @max(target.ascender, value.ascender);
    target.descender = @min(target.descender, value.descender);
    target.line_gap = @max(target.line_gap, value.line_gap);
}

test "mixed-script selected lines become positioned visual glyph spans" {
    const fixture = @import("positioned_lines_test.zig");
    try fixture.testPositionedLines(positionLines);
}

test "unsafe shaping changes demand line reflow" {
    const fixture = @import("positioned_lines_test.zig");
    try fixture.testUnsafeReflow(positionLines);
}

test "positioned assembly unwinds every caller-owned allocation failure" {
    const fixture = @import("positioned_lines_test.zig");
    var value: fixture.Fixture = undefined;
    try value.init("Safe text", 10_000);
    defer value.deinit();
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{&value},
    );
}

test "paragraph alignment resolves from each line base direction and clips whole lines" {
    const fixture = @import("positioned_lines_test.zig");
    var value: fixture.Fixture = undefined;
    try value.init("one two three four five six", 45);
    defer value.deinit();
    try std.testing.expect(value.selected.lines.len > 1);

    var centered = try positionLinesWithStyle(
        std.testing.allocator,
        value.utf8,
        &value.shaped,
        &value.selected,
        .{ .alignment = .center, .max_lines = 1 },
        100,
    );
    defer centered.deinit();
    try std.testing.expectEqual(@as(usize, 1), centered.lines.len);
    try std.testing.expect(centered.truncated);
    try std.testing.expectEqual(@as(f32, 100), centered.width());
    try std.testing.expectApproxEqAbs(
        (100 - centered.lines[0].advance) / 2,
        centered.lines[0].left,
        0.001,
    );

    value.selected.lines[0].base_level = 1;
    var rtl_start = try positionLinesWithStyle(
        std.testing.allocator,
        value.utf8,
        &value.shaped,
        &value.selected,
        .{ .max_lines = 1 },
        100,
    );
    defer rtl_start.deinit();
    try std.testing.expectApproxEqAbs(
        100 - rtl_start.lines[0].advance,
        rtl_start.lines[0].left,
        0.001,
    );
}

fn exerciseAllocationFailure(
    allocator: std.mem.Allocator,
    fixture: *const @import("positioned_lines_test.zig").Fixture,
) !void {
    var positioned = try positionLines(
        allocator,
        fixture.utf8,
        &fixture.shaped,
        &fixture.selected,
    );
    defer positioned.deinit();
}
