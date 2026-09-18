//! Width-specific paragraph layout and presentation finalization.

const std = @import("std");
const SizeF = @import("../core/geometry.zig").SizeF;
const api = @import("api.zig");
const itemization = @import("itemization.zig");
const line_break = @import("line_break.zig");
const line_layout = @import("line_layout.zig");
const measurement = @import("measurement.zig");
const paragraph = @import("paragraph.zig");
const paragraph_style = @import("paragraph_style.zig");
const positioned_lines = @import("positioned_lines.zig");
const shaped_paragraph = @import("shaped_paragraph.zig");

pub const Layout = struct {
    positioned: positioned_lines.PositionedLines,
    logical_size: f32,
    size: SizeF,

    pub fn deinit(self: *Layout) void {
        self.positioned.deinit();
        self.* = undefined;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    candidates: []const api.FallbackCandidate,
    language: []const u8,
    logical_size: f32,
    max_width: f32,
    style: paragraph_style.Style,
    include_caret_stops: bool,
) !Layout {
    var positioned = try buildPositioned(
        allocator,
        utf8,
        base_direction,
        candidates,
        language,
        logical_size,
        max_width,
        style,
        include_caret_stops,
    );
    errdefer positioned.deinit();
    return .{
        .size = .{ .width = positioned.width(), .height = positioned.height() },
        .positioned = positioned,
        .logical_size = logical_size,
    };
}

fn buildPositioned(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    candidates: []const api.FallbackCandidate,
    language: []const u8,
    logical_size: f32,
    max_width: f32,
    style: paragraph_style.Style,
    include_caret_stops: bool,
) !positioned_lines.PositionedLines {
    var itemized = try itemization.itemizeParagraphs(allocator, utf8, base_direction);
    defer itemized.deinit();
    var shaped = try shaped_paragraph.shapeItemizedParagraphs(
        allocator,
        utf8,
        &itemized,
        candidates,
        language,
        logical_size,
    );
    defer shaped.deinit();
    var breaks = try line_break.analyzeLineBreaks(allocator, utf8);
    defer breaks.deinit();
    var measured = try measurement.measureBreakSegments(allocator, breaks.breaks, &shaped);
    defer measured.deinit();
    var selected = try line_layout.selectGreedyLines(
        allocator,
        utf8,
        base_direction,
        breaks.breaks,
        &measured,
        max_width,
    );
    defer selected.deinit();
    var positioned = try positionWithReflow(
        allocator,
        utf8,
        base_direction,
        &shaped,
        &selected,
        breaks.breaks,
        style,
        include_caret_stops,
    );
    if (style.overflow != .ellipsis or !positioned.truncated) return positioned;
    positioned.deinit();
    return buildEllipsized(
        allocator,
        utf8,
        base_direction,
        candidates,
        language,
        logical_size,
        max_width,
        style,
        include_caret_stops,
        selected.lines[@as(usize, style.max_lines.?) - 1],
        breaks.breaks,
    );
}

fn buildPlainPositioned(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    candidates: []const api.FallbackCandidate,
    language: []const u8,
    logical_size: f32,
    max_width: f32,
    style: paragraph_style.Style,
    include_caret_stops: bool,
) !positioned_lines.PositionedLines {
    var itemized = try itemization.itemizeParagraphs(allocator, utf8, base_direction);
    defer itemized.deinit();
    var shaped = try shaped_paragraph.shapeItemizedParagraphs(
        allocator,
        utf8,
        &itemized,
        candidates,
        language,
        logical_size,
    );
    defer shaped.deinit();
    var breaks = try line_break.analyzeLineBreaks(allocator, utf8);
    defer breaks.deinit();
    var measured = try measurement.measureBreakSegments(allocator, breaks.breaks, &shaped);
    defer measured.deinit();
    var selected = try line_layout.selectGreedyLines(
        allocator,
        utf8,
        base_direction,
        breaks.breaks,
        &measured,
        max_width,
    );
    defer selected.deinit();
    return positionWithReflow(
        allocator,
        utf8,
        base_direction,
        &shaped,
        &selected,
        breaks.breaks,
        style,
        include_caret_stops,
    );
}

fn positionWithReflow(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    selected: *line_layout.GreedyLines,
    breaks: []const line_break.LineBreak,
    style: paragraph_style.Style,
    include_caret_stops: bool,
) !positioned_lines.PositionedLines {
    const width = if (selected.max_width == std.math.floatMax(f32)) null else selected.max_width;
    return positioned_lines.positionLinesWithOptions(
        allocator,
        utf8,
        shaped,
        selected,
        style,
        width,
        include_caret_stops,
    ) catch |err| {
        if (err != error.ReflowRequired) return err;
        const reflowed = try reflowLines(allocator, utf8, base_direction, shaped, breaks, selected.max_width);
        selected.deinit();
        selected.* = reflowed;
        return positioned_lines.positionLinesWithOptions(
            allocator,
            utf8,
            shaped,
            selected,
            style,
            width,
            include_caret_stops,
        );
    };
}

/// Slow path for unsafe breaks whose reshaping changed the provisional width.
/// Select using actual fragment widths, preserving legal breaks, paragraph
/// context and oversized unbreakable segments. No retry loop can oscillate
/// between provisional and reshaped widths.
fn reflowLines(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    breaks: []const line_break.LineBreak,
    max_width: f32,
) !line_layout.GreedyLines {
    var lines: std.ArrayList(line_layout.Line) = .empty;
    defer lines.deinit(allocator);
    var start: usize = 0;
    var index: usize = 0;
    while (index < breaks.len) {
        var next = index;
        var advance: f32 = 0;
        while (next < breaks.len) {
            const candidate = breaks[next];
            const measured = try positioned_lines.measureReshapedLine(
                allocator,
                utf8,
                shaped,
                start,
                candidate.byte_offset - start,
            );
            if (measured > max_width and next > index) break;
            advance = measured;
            next += 1;
            if (candidate.kind == .mandatory or measured > max_width) break;
        }
        const boundary = breaks[next - 1];
        try lines.append(allocator, .{
            .byte_start = start,
            .byte_len = boundary.byte_offset - start,
            .advance = advance,
            .mandatory = boundary.kind == .mandatory,
            .reshape_start = true,
            .reshape_end = true,
            .base_level = 0,
            .visual_run_start = 0,
            .visual_run_count = 0,
        });
        start = boundary.byte_offset;
        index = next;
    }
    const ranges = try allocator.alloc(paragraph.LineRange, lines.items.len);
    defer allocator.free(ranges);
    for (ranges, lines.items) |*range, line| range.* = .{
        .byte_start = line.byte_start,
        .byte_len = line.byte_len,
    };
    var visual = try paragraph.reorderLines(allocator, utf8, base_direction, ranges);
    defer visual.deinit();
    for (lines.items, visual.lines) |*line, visual_line| {
        line.base_level = visual_line.base_level;
        line.visual_run_start = visual_line.run_start;
        line.visual_run_count = visual_line.run_count;
    }
    const owned_lines = try lines.toOwnedSlice(allocator);
    const visual_runs = visual.runs;
    visual.runs = &.{};
    return .{ .allocator = allocator, .max_width = max_width, .lines = owned_lines, .visual_runs = visual_runs };
}

const ellipsis_utf8 = "\xE2\x80\xA6";

/// Finalizes the last visible line at a legal UAX #14 opportunity, then runs
/// the complete itemize/shape/wrap/bidi/position pipeline over the synthesized
/// paragraph. This keeps the ellipsis in shaping and bidi context and avoids
/// renderer-owned glyph injection. If contextual reshaping changes fit, the
/// next earlier legal opportunity is tried.
fn buildEllipsized(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    candidates: []const api.FallbackCandidate,
    language: []const u8,
    logical_size: f32,
    max_width: f32,
    style: paragraph_style.Style,
    include_caret_stops: bool,
    final_line: line_layout.Line,
    breaks: []const line_break.LineBreak,
) !positioned_lines.PositionedLines {
    var boundary = final_line.byte_start + final_line.byte_len;
    while (true) {
        const prefix_len = trimFinalLineWhitespace(utf8, final_line.byte_start, boundary);
        const synthesized = try allocator.alloc(u8, prefix_len + ellipsis_utf8.len);
        defer allocator.free(synthesized);
        @memcpy(synthesized[0..prefix_len], utf8[0..prefix_len]);
        @memcpy(synthesized[prefix_len..], ellipsis_utf8);
        var candidate = try buildPlainPositioned(
            allocator,
            synthesized,
            base_direction,
            candidates,
            language,
            logical_size,
            max_width,
            .{ .alignment = style.alignment },
            include_caret_stops,
        );
        if (candidate.lines.len <= style.max_lines.?) {
            remapEllipsis(&candidate, utf8.len, prefix_len);
            return candidate;
        }
        candidate.deinit();
        if (boundary == final_line.byte_start) return error.EllipsisDoesNotFit;
        boundary = previousBreak(breaks, final_line.byte_start, boundary);
    }
}

fn previousBreak(breaks: []const line_break.LineBreak, minimum: usize, before: usize) usize {
    var result = minimum;
    for (breaks) |opportunity| {
        if (opportunity.byte_offset >= before) break;
        if (opportunity.byte_offset > minimum) result = opportunity.byte_offset;
    }
    return result;
}

fn trimFinalLineWhitespace(utf8: []const u8, minimum: usize, boundary: usize) usize {
    var end = boundary;
    while (end > minimum) switch (utf8[end - 1]) {
        ' ', '\t', '\r', '\n' => end -= 1,
        else => break,
    };
    return end;
}

fn remapEllipsis(
    positioned: *positioned_lines.PositionedLines,
    source_byte_len: usize,
    insertion: usize,
) void {
    for (positioned.lines) |*line| {
        const line_end = line.byte_start + line.byte_len;
        if (line_end > insertion) line.byte_len = insertion -| line.byte_start;
    }
    for (positioned.glyphs) |*glyph| if (glyph.cluster >= insertion) {
        glyph.cluster = insertion;
        glyph.synthetic = true;
    };
    for (positioned.carets) |*caret| {
        if (caret.byte_offset >= insertion) caret.byte_offset = insertion;
    }
    for (positioned.spans) |*span| {
        if (span.byte_start >= insertion) {
            span.byte_start = insertion;
            span.byte_len = 0;
        } else if (span.byte_start + span.byte_len > insertion) {
            span.byte_len = insertion - span.byte_start;
        }
    }
    positioned.truncated = true;
    positioned.source_byte_len = source_byte_len;
    positioned.ellipsis_byte_offset = insertion;
}
