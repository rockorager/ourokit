const std = @import("std");
const uucode = @import("uucode");
const CaretAffinity = @import("../../text/positioned_lines.zig").CaretAffinity;

/// A logical selection in UTF-8 byte offsets. Anchor and extent preserve the
/// direction of an extended selection; `range` returns its normalized bounds.
pub const Selection = struct {
    anchor: usize,
    extent: usize,
    affinity: CaretAffinity = .downstream,

    pub fn collapsed(offset: usize) Selection {
        return .{ .anchor = offset, .extent = offset };
    }

    pub fn range(self: Selection) Range {
        return .{
            .start = @min(self.anchor, self.extent),
            .end = @max(self.anchor, self.extent),
        };
    }

    pub fn isCollapsed(self: Selection) bool {
        return self.anchor == self.extent;
    }
};

pub const Range = struct {
    start: usize,
    end: usize,
};

/// Renderer- and platform-independent state for an editable UTF-8 value.
///
/// Caret positions are always Unicode extended-grapheme boundaries. A compact
/// boundary index makes repeated cursor movement O(log n); text replacement
/// remains O(n), matching the contiguous storage appropriate for text fields.
/// A future long-document editor may use different private storage without
/// changing this value-level editing contract.
pub const Model = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    boundaries: std.ArrayList(usize) = .empty,
    selection: Selection = .collapsed(0),
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, initial: []const u8) !Model {
        if (!std.unicode.utf8ValidateSlice(initial)) return error.InvalidUtf8;
        const boundary_capacity = std.math.add(usize, initial.len, 1) catch
            return error.OutOfMemory;
        var self: Model = .{ .allocator = allocator };
        errdefer self.deinit();
        try self.bytes.appendSlice(allocator, initial);
        try self.boundaries.ensureTotalCapacity(allocator, boundary_capacity);
        self.rebuildBoundaries();
        self.selection = .collapsed(initial.len);
        return self;
    }

    pub fn deinit(self: *Model) void {
        self.boundaries.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn text(self: *const Model) []const u8 {
        return self.bytes.items;
    }

    pub fn setSelection(self: *Model, value: Selection) !bool {
        if (!self.isBoundary(value.anchor) or !self.isBoundary(value.extent))
            return error.InvalidGraphemeBoundary;
        if (std.meta.eql(self.selection, value)) return false;
        self.selection = value;
        self.bumpRevision();
        return true;
    }

    pub fn selectAll(self: *Model) bool {
        const value: Selection = .{ .anchor = 0, .extent = self.bytes.items.len };
        if (std.meta.eql(self.selection, value)) return false;
        self.selection = value;
        self.bumpRevision();
        return true;
    }

    /// Replaces the current selection as one atomic edit. Capacity is secured
    /// before bytes are changed, so allocation failure leaves the value intact.
    pub fn replaceSelection(self: *Model, replacement: []const u8) !bool {
        return self.replaceRange(self.selection.range(), replacement);
    }

    /// Replaces a UTF-8 byte range and leaves the caret on a grapheme boundary.
    /// Input-method deletions are specified at code-point boundaries and may
    /// legitimately split an existing grapheme (for example, removing a
    /// combining mark), so the range need not already be a grapheme boundary.
    pub fn replaceRange(self: *Model, range: Range, replacement: []const u8) !bool {
        if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
        if (range.start > range.end or range.end > self.bytes.items.len)
            return error.InvalidTextRange;
        if (!isUtf8Boundary(self.bytes.items, range.start) or
            !isUtf8Boundary(self.bytes.items, range.end))
            return error.InvalidTextOffset;
        const removed_len = range.end - range.start;
        const retained_len = self.bytes.items.len - removed_len;
        const new_len = std.math.add(usize, retained_len, replacement.len) catch
            return error.OutOfMemory;
        const boundary_capacity = std.math.add(usize, new_len, 1) catch
            return error.OutOfMemory;

        if (removed_len == 0 and replacement.len == 0) return false;

        // One boundary per byte plus the initial zero is a strict upper bound.
        // Both allocations happen before the first content mutation.
        try self.bytes.ensureTotalCapacity(self.allocator, new_len);
        try self.boundaries.ensureTotalCapacity(self.allocator, boundary_capacity);
        self.bytes.replaceRangeAssumeCapacity(range.start, removed_len, replacement);
        self.rebuildBoundaries();

        // Text on either side may join the replacement's edge into a larger
        // grapheme. Snap forward so the resulting caret is always valid.
        const requested = range.start + replacement.len;
        self.selection = .collapsed(self.boundaryAtOrAfter(requested));
        self.bumpRevision();
        return true;
    }

    /// Moves to the previous logical grapheme. Visual left/right movement is a
    /// paragraph-layout concern and must use a bidi-aware caret map instead.
    pub fn movePrevious(self: *Model, extend: bool) bool {
        if (!extend and !self.selection.isCollapsed())
            return self.setExtent(self.selection.range().start, false);
        return self.setExtent(self.boundaryBefore(self.selection.extent), extend);
    }

    /// Moves to the next logical grapheme. See `movePrevious`.
    pub fn moveNext(self: *Model, extend: bool) bool {
        if (!extend and !self.selection.isCollapsed())
            return self.setExtent(self.selection.range().end, false);
        return self.setExtent(self.boundaryAfter(self.selection.extent), extend);
    }

    pub fn deleteBackward(self: *Model) !bool {
        if (!self.selection.isCollapsed()) return self.replaceSelection("");
        const end = self.selection.extent;
        const start = self.boundaryBefore(end);
        if (start == end) return false;
        self.selection = .{ .anchor = start, .extent = end };
        return self.replaceSelection("");
    }

    pub fn deleteForward(self: *Model) !bool {
        if (!self.selection.isCollapsed()) return self.replaceSelection("");
        const start = self.selection.extent;
        const end = self.boundaryAfter(start);
        if (start == end) return false;
        self.selection = .{ .anchor = start, .extent = end };
        return self.replaceSelection("");
    }

    fn rebuildBoundaries(self: *Model) void {
        self.boundaries.clearRetainingCapacity();
        self.boundaries.appendAssumeCapacity(0);
        var iterator = uucode.grapheme.utf8Iterator(self.bytes.items);
        while (iterator.nextGrapheme()) |grapheme|
            self.boundaries.appendAssumeCapacity(grapheme.end);
    }

    fn isBoundary(self: *const Model, offset: usize) bool {
        const index = lowerBound(self.boundaries.items, offset);
        return index < self.boundaries.items.len and self.boundaries.items[index] == offset;
    }

    fn boundaryBefore(self: *const Model, offset: usize) usize {
        const index = lowerBound(self.boundaries.items, offset);
        return if (index == 0) 0 else self.boundaries.items[index - 1];
    }

    fn boundaryAfter(self: *const Model, offset: usize) usize {
        const index = lowerBound(self.boundaries.items, offset);
        if (index >= self.boundaries.items.len - 1) return self.bytes.items.len;
        return if (self.boundaries.items[index] == offset)
            self.boundaries.items[index + 1]
        else
            self.boundaries.items[index];
    }

    fn boundaryAtOrAfter(self: *const Model, offset: usize) usize {
        const index = lowerBound(self.boundaries.items, offset);
        return self.boundaries.items[@min(index, self.boundaries.items.len - 1)];
    }

    fn setExtent(self: *Model, extent: usize, extend: bool) bool {
        const value: Selection = if (extend)
            .{ .anchor = self.selection.anchor, .extent = extent }
        else
            .collapsed(extent);
        if (std.meta.eql(self.selection, value)) return false;
        self.selection = value;
        self.bumpRevision();
        return true;
    }

    fn bumpRevision(self: *Model) void {
        self.revision +%= 1;
    }
};

fn isUtf8Boundary(text: []const u8, offset: usize) bool {
    if (offset > text.len) return false;
    return offset == text.len or (text[offset] & 0xc0) != 0x80;
}

fn lowerBound(values: []const usize, needle: usize) usize {
    var first: usize = 0;
    var count = values.len;
    while (count != 0) {
        const step = count / 2;
        const index = first + step;
        if (values[index] < needle) {
            first = index + 1;
            count -= step + 1;
        } else {
            count = step;
        }
    }
    return first;
}

test "movement and deletion use extended grapheme boundaries" {
    const woman_astronaut = "👩🏽‍🚀";
    var model = try Model.init(std.testing.allocator, "Ae\u{301}" ++ woman_astronaut ++ "🇨🇭Z");
    defer model.deinit();

    try std.testing.expect(model.movePrevious(false));
    try std.testing.expectEqual(model.text().len - 1, model.selection.extent);
    try std.testing.expect(model.movePrevious(false));
    try std.testing.expectEqual(model.text().len - 1 - "🇨🇭".len, model.selection.extent);
    try std.testing.expect(try model.deleteBackward());
    try std.testing.expectEqualStrings("Ae\u{301}🇨🇭Z", model.text());
    try std.testing.expect(try model.deleteForward());
    try std.testing.expectEqualStrings("Ae\u{301}Z", model.text());
    try std.testing.expect(try model.deleteBackward());
    try std.testing.expectEqualStrings("AZ", model.text());
}

test "selection direction is retained and replacement is normalized" {
    var model = try Model.init(std.testing.allocator, "one אבג three");
    defer model.deinit();
    try std.testing.expect(try model.setSelection(.{ .anchor = 10, .extent = 4 }));
    try std.testing.expectEqual(Range{ .start = 4, .end = 10 }, model.selection.range());
    try std.testing.expect(try model.replaceSelection("two"));
    try std.testing.expectEqualStrings("one two three", model.text());
    try std.testing.expectEqual(Selection.collapsed(7), model.selection);
}

test "extended movement preserves anchor and collapses by direction" {
    var model = try Model.init(std.testing.allocator, "abc");
    defer model.deinit();
    try std.testing.expect(model.movePrevious(true));
    try std.testing.expect(model.movePrevious(true));
    try std.testing.expectEqual(Selection{ .anchor = 3, .extent = 1 }, model.selection);
    try std.testing.expect(model.moveNext(false));
    try std.testing.expectEqual(Selection.collapsed(3), model.selection);
    try std.testing.expect(model.movePrevious(true));
    try std.testing.expect(model.movePrevious(false));
    try std.testing.expectEqual(Selection.collapsed(2), model.selection);
}

test "replacement seam cannot leave caret inside a grapheme" {
    var model = try Model.init(std.testing.allocator, "\u{301}b");
    defer model.deinit();
    try std.testing.expect(try model.setSelection(.collapsed(0)));
    try std.testing.expect(try model.replaceSelection("a"));
    try std.testing.expectEqualStrings("a\u{301}b", model.text());
    try std.testing.expectEqual(Selection.collapsed("a\u{301}".len), model.selection);
}

test "input method ranges may remove one code point within a grapheme" {
    var model = try Model.init(std.testing.allocator, "Ae\u{301}B");
    defer model.deinit();
    try std.testing.expect(try model.replaceRange(.{ .start = 2, .end = 4 }, ""));
    try std.testing.expectEqualStrings("AeB", model.text());
    try std.testing.expectEqual(Selection.collapsed(2), model.selection);
}

test "invalid UTF-8 and invalid selection boundaries do not mutate the model" {
    var model = try Model.init(std.testing.allocator, "e\u{301}");
    defer model.deinit();
    const revision = model.revision;
    try std.testing.expectError(error.InvalidGraphemeBoundary, model.setSelection(.collapsed(1)));
    try std.testing.expectError(error.InvalidUtf8, model.replaceSelection("\xff"));
    try std.testing.expectEqualStrings("e\u{301}", model.text());
    try std.testing.expectEqual(revision, model.revision);
}

test "allocation failure leaves editable content and selection intact" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var model = try Model.init(failing.allocator(), "stable");
    defer model.deinit();
    const selection = model.selection;
    const revision = model.revision;

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(
        error.OutOfMemory,
        model.replaceSelection("a replacement large enough to require new storage"),
    );
    try std.testing.expectEqualStrings("stable", model.text());
    try std.testing.expectEqual(selection, model.selection);
    try std.testing.expectEqual(revision, model.revision);
}
