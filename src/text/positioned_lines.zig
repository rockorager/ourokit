//! Final headless assembly of selected lines into positioned glyph spans.

const std = @import("std");
const uucode = @import("uucode");
const PointF = @import("../core/geometry.zig").PointF;
const RectF = @import("../core/geometry.zig").RectF;
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

pub const CaretAffinity = enum {
    /// The trailing edge of the preceding grapheme in logical text order.
    upstream,
    /// The leading edge of the following grapheme in logical text order.
    downstream,
};

pub const VisualDirection = enum { left, right };
pub const VerticalDirection = enum { up, down };
pub const LineBoundary = enum { start, end };

pub const VerticalMove = struct {
    caret: CaretStop,
    /// Paragraph-relative physical X to preserve for subsequent vertical
    /// movement through shorter lines.
    preferred_x: f32,
};

/// One legal extended-grapheme insertion edge. A byte offset may have two
/// physically distinct stops at a bidi boundary; affinity disambiguates which
/// neighboring logical grapheme supplies the visual edge.
pub const CaretStop = struct {
    byte_offset: usize,
    /// Physical coordinate relative to the line's left edge. Add `Line.left`
    /// when converting to paragraph coordinates.
    x: f32,
    affinity: CaretAffinity,
};

pub const HitResult = struct {
    line_index: usize,
    caret: CaretStop,
};

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const Line = struct {
    byte_start: usize,
    byte_len: usize,
    base_level: u8,
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
    caret_start: usize,
    caret_count: usize,
};

pub const PositionedLines = struct {
    allocator: std.mem.Allocator,
    lines: []Line,
    spans: []Span,
    glyphs: []Glyph,
    carets: []CaretStop,
    layout_width: f32,
    truncated: bool,
    source_byte_len: usize,
    ellipsis_byte_offset: ?usize,

    pub fn deinit(self: *PositionedLines) void {
        self.allocator.free(self.carets);
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

    pub fn caretsFor(self: *const PositionedLines, line: Line) []const CaretStop {
        return self.carets[line.caret_start..][0..line.caret_count];
    }

    pub fn caretFor(
        self: *const PositionedLines,
        line: Line,
        byte_offset: usize,
        affinity: CaretAffinity,
    ) ?CaretStop {
        for (self.caretsFor(line)) |caret|
            if (caret.byte_offset == byte_offset and caret.affinity == affinity) return caret;
        return null;
    }

    /// Maps a line-local physical coordinate to the nearest grapheme edge in
    /// O(log n). At a shared edge, approaching from the left chooses the prior
    /// physical segment and approaching from the right chooses the following
    /// one; an exact hit deterministically chooses the following segment.
    pub fn hitTest(self: *const PositionedLines, line: Line, x: f32) ?CaretStop {
        const stops = self.caretsFor(line);
        if (stops.len == 0 or !std.math.isFinite(x)) return null;
        if (x < stops[0].x) return stops[0];
        if (x >= stops[stops.len - 1].x) return stops[stops.len - 1];

        var low: usize = 0;
        var high = stops.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (stops[middle].x < x)
                low = middle + 1
            else
                high = middle;
        }
        std.debug.assert(low < stops.len);
        if (@abs(stops[low].x - x) <= 0.001) {
            var last = low;
            while (last + 1 < stops.len and @abs(stops[last + 1].x - stops[low].x) <= 0.001)
                last += 1;
            return stops[last];
        }
        const left = stops[low - 1];
        const right = stops[low];
        return if (x - left.x < right.x - x) left else right;
    }

    /// Maps paragraph-local coordinates to a line and bidi-aware insertion
    /// edge. Wrapped-line identity is retained because one logical byte offset
    /// can have a trailing position on one line and a leading position on the
    /// next.
    pub fn hitTestPoint(self: *const PositionedLines, point: PointF) ?HitResult {
        if (self.lines.len == 0 or !std.math.isFinite(point.x) or !std.math.isFinite(point.y))
            return null;
        var low: usize = 0;
        var high = self.lines.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.lines[middle].top <= point.y)
                low = middle + 1
            else
                high = middle;
        }
        var line_index = if (low == 0) @as(usize, 0) else low - 1;
        while (true) {
            const line = self.lines[line_index];
            if (self.hitTest(line, point.x - line.left)) |caret|
                return .{ .line_index = line_index, .caret = caret };
            if (line_index + 1 == self.lines.len) return null;
            line_index += 1;
        }
    }

    pub fn caretRectangle(
        self: *const PositionedLines,
        line_index: usize,
        byte_offset: usize,
        affinity: CaretAffinity,
        caret_width: f32,
    ) !RectF {
        if (line_index >= self.lines.len) return error.InvalidLine;
        if (!std.math.isFinite(caret_width) or caret_width <= 0) return error.InvalidCaretWidth;
        const line = self.lines[line_index];
        const caret = self.caretFor(line, byte_offset, affinity) orelse
            return error.CaretNotFound;
        return .{
            .x = line.left + caret.x,
            .y = line.top,
            .width = caret_width,
            .height = @max(0, line.ascender - line.descender),
        };
    }

    pub fn caretRectangleForOffset(
        self: *const PositionedLines,
        byte_offset: usize,
        affinity: CaretAffinity,
        caret_width: f32,
    ) !RectF {
        if (affinity == .downstream) {
            for (self.lines, 0..) |line, line_index|
                if (self.caretFor(line, byte_offset, affinity) != null)
                    return self.caretRectangle(
                        line_index,
                        byte_offset,
                        affinity,
                        caret_width,
                    );
        } else {
            var line_index = self.lines.len;
            while (line_index != 0) {
                line_index -= 1;
                const line = self.lines[line_index];
                if (self.caretFor(line, byte_offset, affinity) != null)
                    return self.caretRectangle(
                        line_index,
                        byte_offset,
                        affinity,
                        caret_width,
                    );
            }
        }
        if (self.visualIndex(byte_offset, affinity)) |index| {
            for (self.lines, 0..) |line, line_index| {
                if (index < line.caret_start or index >= line.caret_start + line.caret_count)
                    continue;
                const caret = self.carets[index];
                return self.caretRectangle(
                    line_index,
                    caret.byte_offset,
                    caret.affinity,
                    caret_width,
                );
            }
        }
        return error.CaretNotFound;
    }

    /// Traverses the physical caret sequence produced by bidi reordering. Line
    /// arrays are top-to-bottom and each line's carets are left-to-right.
    /// Co-located upstream/downstream variants are one visual position and are
    /// skipped; affinity variants at distinct bidi edges remain traversable.
    pub fn visualNeighbor(
        self: *const PositionedLines,
        byte_offset: usize,
        affinity: CaretAffinity,
        direction: VisualDirection,
    ) ?CaretStop {
        const index = self.visualIndex(byte_offset, affinity) orelse return null;
        return switch (direction) {
            .left => blk: {
                var candidate = index;
                while (candidate != 0) {
                    candidate -= 1;
                    if (!self.sameVisualPosition(index, candidate)) break;
                }
                break :blk self.carets[candidate];
            },
            .right => blk: {
                var candidate = index;
                while (candidate + 1 < self.carets.len) {
                    candidate += 1;
                    if (!self.sameVisualPosition(index, candidate)) break;
                }
                break :blk self.carets[candidate];
            },
        };
    }

    pub fn visualOrder(
        self: *const PositionedLines,
        a_offset: usize,
        a_affinity: CaretAffinity,
        b_offset: usize,
        b_affinity: CaretAffinity,
    ) ?std.math.Order {
        const a = self.visualIndex(a_offset, a_affinity) orelse return null;
        const b = self.visualIndex(b_offset, b_affinity) orelse return null;
        return std.math.order(a, b);
    }

    /// Returns the directional start or end of the current visual line. Start
    /// is the left edge for an LTR base line and the right edge for RTL.
    pub fn lineBoundary(
        self: *const PositionedLines,
        byte_offset: usize,
        affinity: CaretAffinity,
        boundary: LineBoundary,
    ) ?CaretStop {
        const index = self.visualIndex(byte_offset, affinity) orelse return null;
        const line = self.lineForVisualIndex(index) orelse return null;
        const carets = self.caretsFor(line);
        if (carets.len == 0) return null;
        const rtl = line.base_level & 1 != 0;
        return switch (boundary) {
            .start => if (rtl) carets[carets.len - 1] else carets[0],
            .end => if (rtl) carets[0] else carets[carets.len - 1],
        };
    }

    /// Moves to the closest physical X on an adjacent visual line. The first
    /// move captures the current paragraph-relative X; later moves retain it
    /// so crossing a short line does not permanently shift the caret column.
    pub fn verticalNeighbor(
        self: *const PositionedLines,
        byte_offset: usize,
        affinity: CaretAffinity,
        preferred_x: ?f32,
        direction: VerticalDirection,
    ) ?VerticalMove {
        const index = self.visualIndex(byte_offset, affinity) orelse return null;
        const line_index = self.lineIndexForVisualIndex(index) orelse return null;
        const line = self.lines[line_index];
        const x = preferred_x orelse line.left + self.carets[index].x;
        const target_index = switch (direction) {
            .up => if (line_index == 0) line_index else line_index - 1,
            .down => if (line_index + 1 == self.lines.len) line_index else line_index + 1,
        };
        if (target_index == line_index) return .{
            .caret = self.carets[index],
            .preferred_x = x,
        };
        const target = self.lines[target_index];
        return .{
            .caret = self.hitTest(target, x - target.left) orelse return null,
            .preferred_x = x,
        };
    }

    fn visualIndex(
        self: *const PositionedLines,
        byte_offset: usize,
        affinity: CaretAffinity,
    ) ?usize {
        if (self.visualIndexExact(byte_offset, affinity)) |index| return index;
        if (affinity == .downstream) {
            for (self.carets, 0..) |caret, index|
                if (caret.byte_offset == byte_offset) return index;
        } else {
            var index = self.carets.len;
            while (index != 0) {
                index -= 1;
                if (self.carets[index].byte_offset == byte_offset) return index;
            }
        }
        return null;
    }

    fn visualIndexExact(
        self: *const PositionedLines,
        byte_offset: usize,
        affinity: CaretAffinity,
    ) ?usize {
        if (affinity == .downstream) {
            for (self.lines) |line| for (self.caretsFor(line), 0..) |caret, index|
                if (caret.byte_offset == byte_offset and caret.affinity == affinity)
                    return line.caret_start + index;
        } else {
            var line_index = self.lines.len;
            while (line_index != 0) {
                line_index -= 1;
                const line = self.lines[line_index];
                const carets = self.caretsFor(line);
                var index = carets.len;
                while (index != 0) {
                    index -= 1;
                    const caret = carets[index];
                    if (caret.byte_offset == byte_offset and caret.affinity == affinity)
                        return line.caret_start + index;
                }
            }
        }
        return null;
    }

    fn sameVisualPosition(self: *const PositionedLines, a: usize, b: usize) bool {
        const line = self.lineForVisualIndex(a) orelse return false;
        const end = line.caret_start + line.caret_count;
        if (b < line.caret_start or b >= end) return false;
        return @abs(self.carets[a].x - self.carets[b].x) <= 0.001;
    }

    fn lineForVisualIndex(self: *const PositionedLines, index: usize) ?Line {
        const line_index = self.lineIndexForVisualIndex(index) orelse return null;
        return self.lines[line_index];
    }

    fn lineIndexForVisualIndex(self: *const PositionedLines, index: usize) ?usize {
        for (self.lines, 0..) |line, line_index|
            if (index >= line.caret_start and index < line.caret_start + line.caret_count)
                return line_index;
        return null;
    }

    /// Emits one rectangle for each contiguous physical selection fragment.
    /// The caller owns storage, keeping selection-only updates allocation-free.
    /// Caret pairs are retained in physical order, so this remains linear even
    /// when a logical range becomes discontiguous under UAX #9 reordering.
    pub fn selectionRectangles(
        self: *const PositionedLines,
        range: ByteRange,
        storage: []RectF,
    ) ![]const RectF {
        var iterator = try self.selectionRectangleIterator(range);
        var count: usize = 0;
        while (try iterator.next()) |rect| {
            if (count == storage.len) return error.SelectionRectangleCapacityExceeded;
            storage[count] = rect;
            count += 1;
        }
        return storage[0..count];
    }

    pub fn selectionRectangleIterator(
        self: *const PositionedLines,
        range: ByteRange,
    ) !SelectionRectangleIterator {
        if (range.start > range.end or range.end > self.source_byte_len)
            return error.InvalidSelectionRange;
        return .{ .positioned = self, .range = range };
    }

    pub fn width(self: *const PositionedLines) f32 {
        return self.layout_width;
    }

    /// Maximum shaped advance of the visible lines, independent of the width
    /// reserved for paragraph alignment.
    pub fn contentWidth(self: *const PositionedLines) f32 {
        var result: f32 = 0;
        for (self.lines) |line| result = @max(result, line.advance);
        return result;
    }

    pub fn height(self: *const PositionedLines) f32 {
        if (self.lines.len == 0) return 0;
        const last = self.lines[self.lines.len - 1];
        return last.top + @max(0, last.ascender - last.descender + last.line_gap);
    }
};

/// Allocation-free physical selection traversal used directly by scene
/// construction. Adjacent selected graphemes on one visual line are merged.
pub const SelectionRectangleIterator = struct {
    positioned: *const PositionedLines,
    range: ByteRange,
    line_index: usize = 0,
    caret_index: usize = 0,
    pending: ?RectF = null,

    pub fn next(self: *SelectionRectangleIterator) !?RectF {
        var current = self.pending orelse (try self.nextFragment() orelse return null);
        self.pending = null;
        while (try self.nextFragment()) |fragment| {
            const current_end = current.x + current.width;
            if (@abs(fragment.y - current.y) <= 0.001 and
                @abs(fragment.height - current.height) <= 0.001 and
                fragment.x <= current_end + 0.001)
            {
                current.width = @max(current_end, fragment.x + fragment.width) - current.x;
                continue;
            }
            self.pending = fragment;
            return current;
        }
        return current;
    }

    fn nextFragment(self: *SelectionRectangleIterator) !?RectF {
        if (self.range.start == self.range.end) return null;
        while (self.line_index < self.positioned.lines.len) {
            const line = self.positioned.lines[self.line_index];
            const stops = self.positioned.caretsFor(line);
            if (stops.len % 2 != 0 and stops.len != 1) return error.InvalidCaretMap;
            while (self.caret_index + 1 < stops.len) {
                const left = stops[self.caret_index];
                const right = stops[self.caret_index + 1];
                self.caret_index += 2;
                const logical = caretPairRange(left, right) orelse {
                    if (left.byte_offset == right.byte_offset) continue;
                    return error.InvalidCaretMap;
                };
                if (logical.start < self.range.start or logical.end > self.range.end) continue;
                const width = @max(0, right.x - left.x);
                const height = @max(0, line.ascender - line.descender);
                if (width == 0 or height == 0) continue;
                return .{
                    .x = line.left + left.x,
                    .y = line.top,
                    .width = width,
                    .height = height,
                };
            }
            self.line_index += 1;
            self.caret_index = 0;
        }
        return null;
    }
};

fn caretPairRange(left: CaretStop, right: CaretStop) ?ByteRange {
    if (left.x > right.x + 0.001) return null;
    if (left.affinity == .downstream and right.affinity == .upstream and
        left.byte_offset < right.byte_offset)
        return .{ .start = left.byte_offset, .end = right.byte_offset };
    if (left.affinity == .upstream and right.affinity == .downstream and
        right.byte_offset < left.byte_offset)
        return .{ .start = right.byte_offset, .end = left.byte_offset };
    return null;
}

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
    return positionLinesWithOptions(
        allocator,
        utf8,
        shaped,
        selected,
        style,
        available_width,
        true,
    );
}

/// Allows noninteractive labels to omit caret storage and its construction
/// cost. Editable or selectable text requests immutable caret stops explicitly.
pub fn positionLinesWithOptions(
    allocator: std.mem.Allocator,
    utf8: []const u8,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    selected: *const line_layout.GreedyLines,
    style: paragraph_style.Style,
    available_width: ?f32,
    include_caret_stops: bool,
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
    var carets: std.ArrayList(CaretStop) = .empty;
    errdefer carets.deinit(allocator);
    const source_graphemes = if (include_caret_stops)
        try api.graphemes(allocator, utf8)
    else
        &.{};
    defer if (include_caret_stops) allocator.free(source_graphemes);
    try lines.ensureTotalCapacity(allocator, visible_count);
    var line_top: f32 = 0;

    for (selected.lines[0..visible_count], 0..) |selected_line, line_index| {
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

        if (style.alignment == .justify and
            line_index + 1 < visible_count and
            !selected_line.mandatory and
            available_width != null)
        {
            pen_x = justifyLine(
                utf8,
                spans.items[line_span_start..],
                glyphs.items[line_glyph_start..],
                pen_x,
                available_width.?,
            );
        }

        const line_caret_start = carets.items.len;
        if (include_caret_stops) try appendLineCarets(
            allocator,
            &carets,
            source_graphemes,
            shaped,
            selected_line,
            pen_x,
            spans.items[line_span_start..],
            glyphs.items,
        );

        var metrics: api.Metrics = .{ .ascender = 0, .descender = 0, .line_gap = 0 };
        for (fragments.items) |*fragment| mergeMetrics(&metrics, fragment.result().metrics);
        const line_height = @max(0, metrics.ascender - metrics.descender + metrics.line_gap);
        if (!std.math.isFinite(line_height) or !std.math.isFinite(line_top))
            return error.InvalidShaping;
        lines.appendAssumeCapacity(.{
            .byte_start = selected_line.byte_start,
            .byte_len = selected_line.byte_len,
            .base_level = selected_line.base_level,
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
            .caret_start = line_caret_start,
            .caret_count = carets.items.len - line_caret_start,
        });
        line_top += line_height;
    }

    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    const owned_spans = try spans.toOwnedSlice(allocator);
    errdefer allocator.free(owned_spans);
    const owned_glyphs = try glyphs.toOwnedSlice(allocator);
    errdefer allocator.free(owned_glyphs);
    var natural_width: f32 = 0;
    for (owned_lines) |line| natural_width = @max(natural_width, line.advance);
    return .{
        .allocator = allocator,
        .lines = owned_lines,
        .spans = owned_spans,
        .glyphs = owned_glyphs,
        .carets = try carets.toOwnedSlice(allocator),
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
        .justify => 0,
    };
}

/// Expands only Unicode line-break class SP glyphs that have visible glyphs on
/// both physical sides. Glyphs are already assembled in left-to-right visual
/// order, so this is linear and independent of logical bidi order. Script-
/// specific kashida and inter-character CJK expansion remain separate policy.
fn justifyLine(
    utf8: []const u8,
    spans: []Span,
    glyphs: []Glyph,
    natural_width: f32,
    available_width: f32,
) f32 {
    const extra = @max(0, available_width - natural_width);
    if (extra == 0 or glyphs.len < 3) return natural_width;
    var opportunities: usize = 0;
    for (glyphs[1 .. glyphs.len - 1]) |glyph|
        if (isExpandableSpace(utf8, glyph)) {
            opportunities += 1;
        };
    if (opportunities == 0) return natural_width;

    const per_opportunity = extra / @as(f32, @floatFromInt(opportunities));
    var shift: f32 = 0;
    var physical_index: usize = 0;
    for (spans) |*span| {
        var span_expansion: f32 = 0;
        for (glyphs[span.glyph_start - spans[0].glyph_start ..][0..span.glyph_count]) |*glyph| {
            glyph.origin.x += shift;
            if (physical_index != 0 and physical_index + 1 < glyphs.len and
                isExpandableSpace(utf8, glyph.*))
            {
                glyph.advance.x += per_opportunity;
                shift += per_opportunity;
                span_expansion += per_opportunity;
            }
            physical_index += 1;
        }
        span.advance += span_expansion;
    }
    return natural_width + shift;
}

fn isExpandableSpace(utf8: []const u8, glyph: Glyph) bool {
    if (glyph.synthetic or glyph.cluster >= utf8.len) return false;
    const sequence_len = std.unicode.utf8ByteSequenceLength(utf8[glyph.cluster]) catch return false;
    if (glyph.cluster + sequence_len > utf8.len) return false;
    const codepoint = std.unicode.utf8Decode(utf8[glyph.cluster..][0..sequence_len]) catch return false;
    return uucode.get(.line_break, codepoint) == .sp;
}

fn appendLineCarets(
    allocator: std.mem.Allocator,
    carets: *std.ArrayList(CaretStop),
    graphemes: []const api.Grapheme,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    line: line_layout.Line,
    line_advance: f32,
    spans: []const Span,
    glyphs: []const Glyph,
) !void {
    const line_caret_start = carets.items.len;
    if (spans.len == 0) {
        try appendCaret(allocator, carets, line_caret_start, .{
            .byte_offset = line.byte_start,
            .x = 0,
            .affinity = .downstream,
        });
        if (line.byte_len != 0) try appendCaret(allocator, carets, line_caret_start, .{
            .byte_offset = line.byte_start + line.byte_len,
            .x = 0,
            .affinity = .upstream,
        });
        return;
    }

    var ligature_positions: std.ArrayList(f32) = .empty;
    defer ligature_positions.deinit(allocator);
    var span_x: f32 = 0;
    for (spans) |span| {
        if (span.glyph_start + span.glyph_count > glyphs.len) return error.InvalidShaping;
        const span_glyphs = glyphs[span.glyph_start..][0..span.glyph_count];
        const span_end = std.math.add(usize, span.byte_start, span.byte_len) catch
            return error.InvalidShaping;
        var glyph_index: usize = 0;
        var cluster_x = span_x;
        while (glyph_index < span_glyphs.len) {
            const cluster = span_glyphs[glyph_index].cluster;
            var glyph_end = glyph_index;
            var cluster_advance: f32 = 0;
            while (glyph_end < span_glyphs.len and span_glyphs[glyph_end].cluster == cluster) : (glyph_end += 1) {
                const advance = span_glyphs[glyph_end].advance.x;
                if (!std.math.isFinite(advance) or advance < 0) return error.InvalidShaping;
                cluster_advance += advance;
            }
            const cluster_end = switch (span.direction) {
                .left_to_right => if (glyph_end < span_glyphs.len)
                    span_glyphs[glyph_end].cluster
                else
                    span_end,
                .right_to_left => if (glyph_index == 0)
                    span_end
                else
                    span_glyphs[glyph_index - 1].cluster,
                else => return error.UnsupportedTextDirection,
            };
            if (cluster < span.byte_start or cluster_end <= cluster or cluster_end > span_end)
                return error.InvalidShaping;
            try appendClusterCarets(
                allocator,
                carets,
                line_caret_start,
                &ligature_positions,
                graphemes,
                shaped,
                span,
                span_glyphs[glyph_index..glyph_end],
                cluster,
                cluster_end,
                cluster_x,
                cluster_advance,
            );
            cluster_x += cluster_advance;
            glyph_index = glyph_end;
        }
        if (@abs(cluster_x - (span_x + span.advance)) > 0.001)
            return error.InvalidShaping;
        span_x += span.advance;
    }
    if (@abs(span_x - line_advance) > 0.001) return error.InvalidShaping;
}

fn appendClusterCarets(
    allocator: std.mem.Allocator,
    carets: *std.ArrayList(CaretStop),
    line_caret_start: usize,
    ligature_positions: *std.ArrayList(f32),
    all_graphemes: []const api.Grapheme,
    shaped: *const shaped_paragraph.ShapedParagraphs,
    span: Span,
    cluster_glyphs: []const Glyph,
    cluster_start: usize,
    cluster_end: usize,
    cluster_x: f32,
    cluster_advance: f32,
) !void {
    const grapheme_start = firstGraphemeEndingAfter(all_graphemes, cluster_start);
    var grapheme_end = grapheme_start;
    while (grapheme_end < all_graphemes.len and
        all_graphemes[grapheme_end].byte_start < cluster_end) : (grapheme_end += 1)
    {}
    const cluster_graphemes = all_graphemes[grapheme_start..grapheme_end];
    if (cluster_graphemes.len == 0 or
        cluster_graphemes[0].byte_start != cluster_start or
        cluster_graphemes[cluster_graphemes.len - 1].byte_end != cluster_end)
        return error.InvalidShaping;

    const internal_count = cluster_graphemes.len - 1;
    ligature_positions.clearRetainingCapacity();
    try ligature_positions.resize(allocator, internal_count);
    var use_font_positions = false;
    if (internal_count != 0 and cluster_glyphs.len == 1) {
        const font = fontForHandle(shaped.candidates, span.font) orelse
            return error.InvalidFontHandle;
        const total = try font.ligatureCarets(
            span.direction,
            shaped.logical_size,
            cluster_glyphs[0].id,
            ligature_positions.items,
        );
        use_font_positions = total == internal_count and validLigatureCarets(
            ligature_positions.items,
            cluster_advance,
        );
    }

    for (0..cluster_graphemes.len) |physical_index| {
        const logical_index = if (span.direction == .right_to_left)
            cluster_graphemes.len - 1 - physical_index
        else
            physical_index;
        const grapheme = cluster_graphemes[logical_index];
        const left = cluster_x + caretCoordinate(
            physical_index,
            cluster_graphemes.len,
            cluster_advance,
            ligature_positions.items,
            use_font_positions,
        );
        const right = cluster_x + caretCoordinate(
            physical_index + 1,
            cluster_graphemes.len,
            cluster_advance,
            ligature_positions.items,
            use_font_positions,
        );
        if (span.direction == .right_to_left) {
            try appendCaret(allocator, carets, line_caret_start, .{
                .byte_offset = grapheme.byte_end,
                .x = left,
                .affinity = .upstream,
            });
            try appendCaret(allocator, carets, line_caret_start, .{
                .byte_offset = grapheme.byte_start,
                .x = right,
                .affinity = .downstream,
            });
        } else {
            try appendCaret(allocator, carets, line_caret_start, .{
                .byte_offset = grapheme.byte_start,
                .x = left,
                .affinity = .downstream,
            });
            try appendCaret(allocator, carets, line_caret_start, .{
                .byte_offset = grapheme.byte_end,
                .x = right,
                .affinity = .upstream,
            });
        }
    }
}

fn caretCoordinate(
    boundary: usize,
    grapheme_count: usize,
    advance: f32,
    font_positions: []const f32,
    use_font_positions: bool,
) f32 {
    if (boundary == 0) return 0;
    if (boundary == grapheme_count) return advance;
    if (use_font_positions) return font_positions[boundary - 1];
    return advance * @as(f32, @floatFromInt(boundary)) /
        @as(f32, @floatFromInt(grapheme_count));
}

fn validLigatureCarets(positions: []const f32, advance: f32) bool {
    var previous: f32 = 0;
    for (positions) |position| {
        if (!std.math.isFinite(position) or position <= previous or position >= advance)
            return false;
        previous = position;
    }
    return true;
}

fn firstGraphemeEndingAfter(graphemes: []const api.Grapheme, byte_offset: usize) usize {
    var low: usize = 0;
    var high = graphemes.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (graphemes[middle].byte_end <= byte_offset)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

fn fontForHandle(
    candidates: []const api.FallbackCandidate,
    handle: api.FontHandle,
) ?*const api.Font {
    for (candidates) |candidate| if (candidate.handle.slot == handle.slot and
        candidate.handle.generation == handle.generation) return candidate.font;
    return null;
}

fn appendCaret(
    allocator: std.mem.Allocator,
    carets: *std.ArrayList(CaretStop),
    line_caret_start: usize,
    caret: CaretStop,
) !void {
    if (!std.math.isFinite(caret.x) or caret.x < 0) return error.InvalidShaping;
    if (carets.items.len > line_caret_start) {
        const previous = carets.items[carets.items.len - 1];
        if (caret.x + 0.001 < previous.x) return error.InvalidVisualOrder;
        if (caret.byte_offset == previous.byte_offset and
            caret.affinity == previous.affinity and
            @abs(caret.x - previous.x) <= 0.001) return;
    }
    try carets.append(allocator, caret);
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

test "caret stops preserve graphemes, ligatures, and bidi affinity" {
    const fixture = @import("positioned_lines_test.zig");
    const mixed = "Save حفظ now";
    var mixed_fixture: fixture.Fixture = undefined;
    try mixed_fixture.init(mixed, 10_000);
    defer mixed_fixture.deinit();
    var mixed_positioned = try positionLines(
        std.testing.allocator,
        mixed,
        &mixed_fixture.shaped,
        &mixed_fixture.selected,
    );
    defer mixed_positioned.deinit();

    const mixed_carets = mixed_positioned.caretsFor(mixed_positioned.lines[0]);
    var previous_x: f32 = 0;
    var bidi_boundary_first: ?f32 = null;
    var bidi_boundary_second: ?f32 = null;
    for (mixed_carets) |caret| {
        try std.testing.expect(caret.x + 0.001 >= previous_x);
        previous_x = caret.x;
        if (caret.byte_offset == 5) {
            if (bidi_boundary_first == null)
                bidi_boundary_first = caret.x
            else if (@abs(caret.x - bidi_boundary_first.?) > 0.001)
                bidi_boundary_second = caret.x;
        }
    }
    try std.testing.expect(bidi_boundary_first != null);
    try std.testing.expect(bidi_boundary_second != null);
    for (mixed_carets) |caret| {
        const left = mixed_positioned.visualNeighbor(caret.byte_offset, caret.affinity, .left).?;
        const right = mixed_positioned.visualNeighbor(caret.byte_offset, caret.affinity, .right).?;
        try std.testing.expect(left.x < caret.x or @abs(left.x - caret.x) <= 0.001);
        try std.testing.expect(right.x > caret.x or @abs(right.x - caret.x) <= 0.001);
        if (@abs(left.x - caret.x) <= 0.001)
            try std.testing.expectEqual(mixed_carets[0].x, caret.x);
        if (@abs(right.x - caret.x) <= 0.001)
            try std.testing.expectEqual(mixed_carets[mixed_carets.len - 1].x, caret.x);
    }

    const clustered = "office a\u{301}b";
    var clustered_fixture: fixture.Fixture = undefined;
    try clustered_fixture.init(clustered, 10_000);
    defer clustered_fixture.deinit();
    var clustered_positioned = try positionLines(
        std.testing.allocator,
        clustered,
        &clustered_fixture.shaped,
        &clustered_fixture.selected,
    );
    defer clustered_positioned.deinit();
    const clustered_carets = clustered_positioned.caretsFor(clustered_positioned.lines[0]);
    try std.testing.expect(caretX(clustered_carets, 2, .downstream) != null);
    try std.testing.expect(caretX(clustered_carets, 3, .downstream) != null);
    try std.testing.expect(caretX(clustered_carets, 8, .downstream) == null);
    const ligature_left = caretX(clustered_carets, 1, .downstream).?;
    const ligature_first = caretX(clustered_carets, 2, .downstream).?;
    const ligature_second = caretX(clustered_carets, 3, .downstream).?;
    const ligature_right = caretX(clustered_carets, 4, .upstream).?;
    try std.testing.expect(ligature_left < ligature_first);
    try std.testing.expect(ligature_first < ligature_second);
    try std.testing.expect(ligature_second < ligature_right);
    const clustered_line = clustered_positioned.lines[0];
    const before_first = clustered_positioned.hitTest(
        clustered_line,
        ligature_first - (ligature_first - ligature_left) / 4,
    ).?;
    try std.testing.expectEqual(@as(usize, 2), before_first.byte_offset);
    try std.testing.expectEqual(CaretAffinity.upstream, before_first.affinity);
    const after_first = clustered_positioned.hitTest(
        clustered_line,
        ligature_first + (ligature_second - ligature_first) / 4,
    ).?;
    try std.testing.expectEqual(@as(usize, 2), after_first.byte_offset);
    try std.testing.expectEqual(CaretAffinity.downstream, after_first.affinity);
    try std.testing.expectEqual(
        CaretAffinity.downstream,
        clustered_positioned.hitTest(clustered_line, ligature_first).?.affinity,
    );

    const rtl = "אבג";
    var rtl_fixture: fixture.Fixture = undefined;
    try rtl_fixture.init(rtl, 10_000);
    defer rtl_fixture.deinit();
    var rtl_positioned = try positionLines(
        std.testing.allocator,
        rtl,
        &rtl_fixture.shaped,
        &rtl_fixture.selected,
    );
    defer rtl_positioned.deinit();
    const rtl_line = rtl_positioned.lines[0];
    try std.testing.expect(rtl_line.base_level & 1 != 0);
    const rtl_middle = rtl_positioned.caretsFor(rtl_line)[1];
    const rtl_start = rtl_positioned.lineBoundary(
        rtl_middle.byte_offset,
        rtl_middle.affinity,
        .start,
    ).?;
    const rtl_end = rtl_positioned.lineBoundary(
        rtl_middle.byte_offset,
        rtl_middle.affinity,
        .end,
    ).?;
    try std.testing.expect(rtl_start.x > rtl_end.x);

    const wrapped = "one two three four five six";
    var wrapped_fixture: fixture.Fixture = undefined;
    try wrapped_fixture.init(wrapped, 45);
    defer wrapped_fixture.deinit();
    var wrapped_positioned = try positionLines(
        std.testing.allocator,
        wrapped,
        &wrapped_fixture.shaped,
        &wrapped_fixture.selected,
    );
    defer wrapped_positioned.deinit();
    try std.testing.expect(wrapped_positioned.lines.len > 1);
    var rectangle_storage: [32]RectF = undefined;
    const rectangles = try wrapped_positioned.selectionRectangles(
        .{ .start = 0, .end = wrapped.len },
        &rectangle_storage,
    );
    try std.testing.expectEqual(wrapped_positioned.lines.len, rectangles.len);
    for (wrapped_positioned.lines, rectangles) |line, rectangle| {
        try std.testing.expectApproxEqAbs(line.left, rectangle.x, 0.001);
        try std.testing.expectApproxEqAbs(line.advance, rectangle.width, 0.001);
        try std.testing.expectApproxEqAbs(line.top, rectangle.y, 0.001);
        try std.testing.expectApproxEqAbs(
            line.ascender - line.descender,
            rectangle.height,
            0.001,
        );
    }
    const second_line = wrapped_positioned.lines[1];
    const point_hit = wrapped_positioned.hitTestPoint(.{
        .x = second_line.left + second_line.advance / 2,
        .y = second_line.top + (second_line.ascender - second_line.descender) / 2,
    }).?;
    try std.testing.expectEqual(@as(usize, 1), point_hit.line_index);
    const second_carets = wrapped_positioned.caretsFor(second_line);
    const second_middle = second_carets[second_carets.len / 2];
    try std.testing.expectEqual(
        second_carets[0],
        wrapped_positioned.lineBoundary(
            second_middle.byte_offset,
            second_middle.affinity,
            .start,
        ).?,
    );
    try std.testing.expectEqual(
        second_carets[second_carets.len - 1],
        wrapped_positioned.lineBoundary(
            second_middle.byte_offset,
            second_middle.affinity,
            .end,
        ).?,
    );
    const preferred_x = second_line.left + second_middle.x;
    const moved_up = wrapped_positioned.verticalNeighbor(
        second_middle.byte_offset,
        second_middle.affinity,
        null,
        .up,
    ).?;
    try std.testing.expectApproxEqAbs(preferred_x, moved_up.preferred_x, 0.001);
    const moved_up_index = wrapped_positioned.visualIndex(
        moved_up.caret.byte_offset,
        moved_up.caret.affinity,
    ).?;
    try std.testing.expectEqual(
        @as(usize, 0),
        wrapped_positioned.lineIndexForVisualIndex(moved_up_index).?,
    );
    const moved_back = wrapped_positioned.verticalNeighbor(
        moved_up.caret.byte_offset,
        moved_up.caret.affinity,
        moved_up.preferred_x,
        .down,
    ).?;
    try std.testing.expectApproxEqAbs(preferred_x, moved_back.preferred_x, 0.001);
    const moved_back_index = wrapped_positioned.visualIndex(
        moved_back.caret.byte_offset,
        moved_back.caret.affinity,
    ).?;
    try std.testing.expectEqual(
        @as(usize, 1),
        wrapped_positioned.lineIndexForVisualIndex(moved_back_index).?,
    );
    const first_caret = wrapped_positioned.caretsFor(wrapped_positioned.lines[0])[0];
    const caret_rectangle = try wrapped_positioned.caretRectangle(
        0,
        first_caret.byte_offset,
        first_caret.affinity,
        1,
    );
    try std.testing.expectEqual(@as(f32, 1), caret_rectangle.width);
    try std.testing.expectError(
        error.SelectionRectangleCapacityExceeded,
        wrapped_positioned.selectionRectangles(.{ .start = 0, .end = wrapped.len }, &.{}),
    );
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
    try std.testing.expectEqual(centered.lines[0].advance, centered.contentWidth());
    try std.testing.expect(centered.contentWidth() < centered.width());
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

test "inter-word justification expands visual gaps in linear order" {
    var spans = [_]Span{.{
        .font = .{ .slot = 1, .generation = 1 },
        .direction = .left_to_right,
        .byte_start = 0,
        .byte_len = 3,
        .advance = 15,
        .glyph_start = 0,
        .glyph_count = 3,
    }};
    var glyphs = [_]Glyph{
        .{ .id = 1, .cluster = 0, .origin = .{ .x = 0 }, .advance = .{ .x = 5 } },
        .{ .id = 2, .cluster = 1, .origin = .{ .x = 5 }, .advance = .{ .x = 5 } },
        .{ .id = 3, .cluster = 2, .origin = .{ .x = 10 }, .advance = .{ .x = 5 } },
    };
    try std.testing.expectEqual(@as(f32, 25), justifyLine("a b", &spans, &glyphs, 15, 25));
    try std.testing.expectEqual(@as(f32, 0), glyphs[0].origin.x);
    try std.testing.expectEqual(@as(f32, 5), glyphs[1].origin.x);
    try std.testing.expectEqual(@as(f32, 20), glyphs[2].origin.x);
    try std.testing.expectEqual(@as(f32, 25), spans[0].advance);
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

fn caretX(carets: []const CaretStop, byte_offset: usize, affinity: CaretAffinity) ?f32 {
    for (carets) |caret|
        if (caret.byte_offset == byte_offset and caret.affinity == affinity) return caret.x;
    return null;
}
