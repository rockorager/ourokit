const std = @import("std");
const uucode = @import("uucode");
const CaretAffinity = @import("../../text/positioned_lines.zig").CaretAffinity;
const word_break = @import("../../text/word_break.zig");
const single_line = @import("single_line.zig");

/// A logical selection in UTF-8 byte offsets. Anchor and extent preserve the
/// direction of an extended selection; `range` returns its normalized bounds.
pub const Selection = struct {
    anchor: usize,
    extent: usize,
    anchor_affinity: CaretAffinity = .downstream,
    extent_affinity: CaretAffinity = .downstream,

    pub fn collapsed(offset: usize) Selection {
        return .{ .anchor = offset, .extent = offset };
    }

    pub fn collapsedAt(offset: usize, affinity: CaretAffinity) Selection {
        return .{
            .anchor = offset,
            .extent = offset,
            .anchor_affinity = affinity,
            .extent_affinity = affinity,
        };
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

pub const EditKind = enum { isolated, typing, delete_backward, delete_forward, composition };

const history_limit = 100;
const HistoryEntry = struct {
    before: []u8,
    after: []u8,
    selection_before: Selection,
    selection_after: Selection,

    fn deinit(self: HistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.before);
        allocator.free(self.after);
    }
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
    word_boundaries: std.ArrayList(usize) = .empty,
    selection: Selection = .collapsed(0),
    revision: u64 = 0,
    history: std.ArrayList(HistoryEntry) = .empty,
    history_cursor: usize = 0,
    edit_group: ?EditKind = null,

    pub fn init(allocator: std.mem.Allocator, raw: []const u8) !Model {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        const normalized = try single_line.normalize(allocator, raw);
        defer if (normalized) |bytes| allocator.free(bytes);
        const initial = normalized orelse raw;
        const boundary_capacity = std.math.add(usize, initial.len, 1) catch
            return error.OutOfMemory;
        var self: Model = .{ .allocator = allocator };
        errdefer self.deinit();
        try self.bytes.appendSlice(allocator, initial);
        try self.boundaries.ensureTotalCapacity(allocator, boundary_capacity);
        try self.word_boundaries.ensureTotalCapacity(allocator, boundary_capacity);
        self.rebuildBoundaries();
        self.selection = .collapsed(initial.len);
        return self;
    }

    pub fn deinit(self: *Model) void {
        for (self.history.items) |entry| entry.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.word_boundaries.deinit(self.allocator);
        self.boundaries.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn text(self: *const Model) []const u8 {
        return self.bytes.items;
    }

    /// Returns a borrowed view of the normalized committed-text selection.
    /// Clipboard owners must copy this view before mutating the model or
    /// retaining it past the current editing phase.
    pub fn selectedText(self: *const Model) []const u8 {
        const range = self.selection.range();
        return self.bytes.items[range.start..range.end];
    }

    pub fn setSelection(self: *Model, value: Selection) !bool {
        if (!self.isBoundary(value.anchor) or !self.isBoundary(value.extent))
            return error.InvalidGraphemeBoundary;
        self.breakUndoGroup();
        if (std.meta.eql(self.selection, value)) return false;
        self.selection = value;
        self.bumpRevision();
        return true;
    }

    /// Restores a selection across a controlled value replacement. Offsets
    /// beyond the new value or inside a changed grapheme snap backward to the
    /// nearest valid caret boundary.
    pub fn setSelectionClamped(self: *Model, value: Selection) bool {
        self.breakUndoGroup();
        const next: Selection = .{
            .anchor = self.boundaryAtOrBefore(@min(value.anchor, self.bytes.items.len)),
            .extent = self.boundaryAtOrBefore(@min(value.extent, self.bytes.items.len)),
            .anchor_affinity = value.anchor_affinity,
            .extent_affinity = value.extent_affinity,
        };
        if (std.meta.eql(self.selection, next)) return false;
        self.selection = next;
        self.bumpRevision();
        return true;
    }

    pub fn selectAll(self: *Model) bool {
        self.breakUndoGroup();
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
    pub fn replaceRange(self: *Model, range: Range, raw: []const u8) !bool {
        return self.replaceRangeGrouped(range, raw, .isolated);
    }

    /// Consecutive edits of one kind share a history entry until an explicit
    /// boundary or selection movement. IME sessions delimit composition groups.
    pub fn replaceRangeGrouped(self: *Model, range: Range, raw: []const u8, kind: EditKind) !bool {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        if (range.start > range.end or range.end > self.bytes.items.len)
            return error.InvalidTextRange;
        if (!isUtf8Boundary(self.bytes.items, range.start) or
            !isUtf8Boundary(self.bytes.items, range.end))
            return error.InvalidTextOffset;
        const normalized = try single_line.normalize(self.allocator, raw);
        defer if (normalized) |bytes| self.allocator.free(bytes);
        const replacement = normalized orelse raw;
        const removed_len = range.end - range.start;
        const retained_len = self.bytes.items.len - removed_len;
        const new_len = std.math.add(usize, retained_len, replacement.len) catch
            return error.OutOfMemory;
        const boundary_capacity = std.math.add(usize, new_len, 1) catch
            return error.OutOfMemory;

        if (removed_len == 0 and replacement.len == 0) {
            if (kind == .isolated) self.breakUndoGroup();
            return false;
        }

        const coalesce = kind != .isolated and self.edit_group == kind and
            self.history_cursor == self.history.items.len and self.history_cursor != 0 and
            std.meta.eql(self.selection, self.history.items[self.history_cursor - 1].selection_after);
        const before = if (!coalesce) try self.allocator.dupe(u8, self.text()) else null;
        errdefer if (before) |bytes| self.allocator.free(bytes);
        const after = try self.allocator.alloc(u8, new_len);
        errdefer self.allocator.free(after);
        @memcpy(after[0..range.start], self.bytes.items[0..range.start]);
        @memcpy(after[range.start..][0..replacement.len], replacement);
        @memcpy(after[range.start + replacement.len ..], self.bytes.items[range.end..]);
        if (!coalesce) try self.history.ensureTotalCapacity(self.allocator, @min(self.history.items.len + 1, history_limit));

        // One boundary per byte plus the initial zero is a strict upper bound.
        // History and model allocations all precede the first content mutation.
        try self.bytes.ensureTotalCapacity(self.allocator, new_len);
        try self.boundaries.ensureTotalCapacity(self.allocator, boundary_capacity);
        try self.word_boundaries.ensureTotalCapacity(self.allocator, boundary_capacity);
        const selection_before = self.selection;
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSliceAssumeCapacity(after);
        self.rebuildBoundaries();

        // Text on either side may join the replacement's edge into a larger
        // grapheme. Snap forward so the resulting caret is always valid.
        const requested = range.start + replacement.len;
        self.selection = .collapsed(self.boundaryAtOrAfter(requested));
        self.bumpRevision();
        if (coalesce) {
            const last = &self.history.items[self.history_cursor - 1];
            self.allocator.free(last.after);
            last.after = after;
            last.selection_after = self.selection;
        } else {
            for (self.history.items[self.history_cursor..]) |entry| entry.deinit(self.allocator);
            self.history.items.len = self.history_cursor;
            if (self.history.items.len == history_limit)
                self.history.orderedRemove(0).deinit(self.allocator);
            self.history.appendAssumeCapacity(.{
                .before = before.?,
                .after = after,
                .selection_before = selection_before,
                .selection_after = self.selection,
            });
            self.history_cursor = self.history.items.len;
        }
        self.edit_group = if (kind == .isolated) null else kind;
        return true;
    }

    pub fn breakUndoGroup(self: *Model) void {
        self.edit_group = null;
    }

    pub fn undo(self: *Model) bool {
        self.breakUndoGroup();
        if (self.history_cursor == 0) return false;
        self.history_cursor -= 1;
        const entry = self.history.items[self.history_cursor];
        self.restore(entry.before, entry.selection_before);
        return true;
    }

    pub fn redo(self: *Model) bool {
        self.breakUndoGroup();
        if (self.history_cursor == self.history.items.len) return false;
        const entry = self.history.items[self.history_cursor];
        self.restore(entry.after, entry.selection_after);
        self.history_cursor += 1;
        return true;
    }

    fn restore(self: *Model, bytes: []const u8, selection: Selection) void {
        // Every snapshot previously fit these buffers; edits never shrink
        // their capacity. Undo/redo cannot fail or allocate.
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSliceAssumeCapacity(bytes);
        self.rebuildBoundaries();
        self.selection = selection;
        self.bumpRevision();
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
        return self.replaceRangeGrouped(.{ .start = start, .end = end }, "", .delete_backward);
    }

    pub fn deleteForward(self: *Model) !bool {
        if (!self.selection.isCollapsed()) return self.replaceSelection("");
        const start = self.selection.extent;
        const end = self.boundaryAfter(start);
        if (start == end) return false;
        return self.replaceRangeGrouped(.{ .start = start, .end = end }, "", .delete_forward);
    }

    pub fn moveWordPrevious(self: *Model, extend: bool) bool {
        if (!extend and !self.selection.isCollapsed())
            return self.setExtent(self.selection.range().start, false);
        return self.setExtent(self.wordBoundaryBefore(self.selection.extent), extend);
    }

    pub fn moveWordNext(self: *Model, extend: bool) bool {
        if (!extend and !self.selection.isCollapsed())
            return self.setExtent(self.selection.range().end, false);
        return self.setExtent(self.wordBoundaryAfter(self.selection.extent), extend);
    }

    pub fn deleteWordBackward(self: *Model) !bool {
        if (!self.selection.isCollapsed()) return self.replaceSelection("");
        const end = self.selection.extent;
        const start = self.wordBoundaryBefore(end);
        if (start == end) return false;
        return self.replaceRange(.{ .start = start, .end = end }, "");
    }

    pub fn deleteWordForward(self: *Model) !bool {
        if (!self.selection.isCollapsed()) return self.replaceSelection("");
        const start = self.selection.extent;
        const end = self.wordBoundaryAfter(start);
        if (start == end) return false;
        return self.replaceRange(.{ .start = start, .end = end }, "");
    }

    /// The Unicode segment touching this insertion edge. Unlike word
    /// navigation, selection includes whitespace and punctuation segments.
    pub fn wordRangeAt(self: *const Model, offset: usize, affinity: CaretAffinity) Range {
        if (self.bytes.items.len == 0) return .{ .start = 0, .end = 0 };
        const at = @min(offset, self.bytes.items.len);
        var index = lowerBound(self.word_boundaries.items, at);
        if (index == self.word_boundaries.items.len - 1 or
            (index != 0 and (self.word_boundaries.items[index] != at or affinity == .upstream))) index -= 1;
        return .{
            .start = self.boundaryAtOrBefore(self.word_boundaries.items[index]),
            .end = self.boundaryAtOrAfter(self.word_boundaries.items[index + 1]),
        };
    }

    fn rebuildBoundaries(self: *Model) void {
        self.boundaries.clearRetainingCapacity();
        self.boundaries.appendAssumeCapacity(0);
        var iterator = uucode.grapheme.utf8Iterator(self.bytes.items);
        while (iterator.nextGrapheme()) |grapheme|
            self.boundaries.appendAssumeCapacity(grapheme.end);
        self.word_boundaries.clearRetainingCapacity();
        word_break.appendAssumeCapacity(self.bytes.items, &self.word_boundaries);
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

    fn boundaryAtOrBefore(self: *const Model, offset: usize) usize {
        const index = lowerBound(self.boundaries.items, offset);
        if (index == self.boundaries.items.len or self.boundaries.items[index] != offset)
            return self.boundaries.items[index - 1];
        return self.boundaries.items[index];
    }

    fn wordBoundaryBefore(self: *const Model, offset: usize) usize {
        var index = lowerBound(self.word_boundaries.items, offset);
        while (index != 0) {
            const start = self.word_boundaries.items[index - 1];
            const end = self.word_boundaries.items[index];
            if (word_break.isWordSegment(self.bytes.items[start..end])) return start;
            index -= 1;
        }
        return 0;
    }

    fn wordBoundaryAfter(self: *const Model, offset: usize) usize {
        var index = lowerBound(self.word_boundaries.items, offset);
        if (index != 0 and (index == self.word_boundaries.items.len or
            self.word_boundaries.items[index] != offset)) index -= 1;
        while (index + 1 < self.word_boundaries.items.len) : (index += 1) {
            const start = self.word_boundaries.items[index];
            const end = self.word_boundaries.items[index + 1];
            if (word_break.isWordSegment(self.bytes.items[start..end])) return end;
        }
        return self.bytes.items.len;
    }

    fn setExtent(self: *Model, extent: usize, extend: bool) bool {
        self.breakUndoGroup();
        const value: Selection = if (extend)
            .{
                .anchor = self.selection.anchor,
                .extent = extent,
                .anchor_affinity = self.selection.anchor_affinity,
            }
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

test "single line model normalizes initial values and replacements before placing caret" {
    var model = try Model.init(std.testing.allocator, "a\r\né\u{2029}z");
    defer model.deinit();
    try std.testing.expectEqualStrings("a é z", model.text());
    try std.testing.expectEqual(Selection.collapsed("a é z".len), model.selection);
    _ = try model.setSelection(.{ .anchor = 2, .extent = 4 });
    _ = try model.replaceSelection("Ω\r\nB\u{2028}C");
    try std.testing.expectEqualStrings("a Ω B C z", model.text());
    try std.testing.expectEqual(Selection.collapsed("a Ω B C".len), model.selection);
}

test "selection direction is retained and replacement is normalized" {
    var model = try Model.init(std.testing.allocator, "one אבג three");
    defer model.deinit();
    try std.testing.expect(try model.setSelection(.{ .anchor = 10, .extent = 4 }));
    try std.testing.expectEqual(Range{ .start = 4, .end = 10 }, model.selection.range());
    try std.testing.expectEqualStrings("אבג", model.selectedText());
    try std.testing.expect(try model.replaceSelection("two"));
    try std.testing.expectEqualStrings("one two three", model.text());
    try std.testing.expectEqual(Selection.collapsed(7), model.selection);
}

test "controlled selection restoration clamps to grapheme boundaries" {
    var model = try Model.init(std.testing.allocator, "aé");
    defer model.deinit();
    try std.testing.expect(model.setSelectionClamped(.{ .anchor = 2, .extent = 99 }));
    try std.testing.expectEqual(@as(usize, 1), model.selection.anchor);
    try std.testing.expectEqual("aé".len, model.selection.extent);
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

test "word movement and deletion use Unicode word boundaries" {
    var model = try Model.init(std.testing.allocator, "can't stop 123");
    defer model.deinit();

    try std.testing.expect(model.moveWordPrevious(false));
    try std.testing.expectEqual(@as(usize, 11), model.selection.extent);
    try std.testing.expect(model.moveWordPrevious(false));
    try std.testing.expectEqual(@as(usize, 6), model.selection.extent);
    try std.testing.expect(model.moveWordPrevious(false));
    try std.testing.expectEqual(@as(usize, 0), model.selection.extent);
    try std.testing.expect(model.moveWordNext(false));
    try std.testing.expectEqual(@as(usize, 5), model.selection.extent);
    try std.testing.expect(model.moveWordNext(false));
    try std.testing.expectEqual(@as(usize, 10), model.selection.extent);

    _ = try model.setSelection(.collapsed(model.text().len));
    try std.testing.expect(try model.deleteWordBackward());
    try std.testing.expectEqualStrings("can't stop ", model.text());
    try std.testing.expect(try model.deleteWordBackward());
    try std.testing.expectEqualStrings("can't ", model.text());
}

test "word movement keeps emoji sequences and combining text atomic" {
    const astronaut = "👩🏽‍🚀";
    var model = try Model.init(std.testing.allocator, "e\u{301}lan " ++ astronaut);
    defer model.deinit();
    try std.testing.expect(model.moveWordPrevious(false));
    try std.testing.expectEqual("e\u{301}lan ".len, model.selection.extent);
    try std.testing.expect(model.moveWordPrevious(false));
    try std.testing.expectEqual(@as(usize, 0), model.selection.extent);
    try std.testing.expect(model.moveWordNext(true));
    try std.testing.expectEqual(@as(usize, 0), model.selection.anchor);
    try std.testing.expectEqual("e\u{301}lan".len, model.selection.extent);
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

test "text input undo groups repeated deletions and restores the original caret" {
    const original = "A👩🏽‍🚀éZ";
    var model = try Model.init(std.testing.allocator, original);
    defer model.deinit();
    _ = try model.deleteBackward();
    _ = try model.deleteBackward();
    try std.testing.expectEqualStrings("A👩🏽‍🚀", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings(original, model.text());
    try std.testing.expectEqual(Selection.collapsed(original.len), model.selection);
    try std.testing.expect(!model.undo());
    try std.testing.expect(model.redo());
    try std.testing.expectEqualStrings("A👩🏽‍🚀", model.text());

    try std.testing.expect(model.undo());
    _ = try model.setSelection(.collapsed(1));
    _ = try model.deleteForward();
    _ = try model.deleteForward();
    try std.testing.expectEqualStrings("AZ", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings(original, model.text());
    try std.testing.expectEqual(Selection.collapsed(1), model.selection);
    try std.testing.expect(model.redo());
    try std.testing.expectEqualStrings("AZ", model.text());
    try std.testing.expect(!model.redo());
}

test "text input undo restores graphemes after codepoint range edits" {
    var model = try Model.init(std.testing.allocator, "Ae\u{301}B");
    defer model.deinit();
    _ = try model.setSelection(.collapsed("Ae\u{301}".len));
    _ = try model.replaceRange(.{ .start = 2, .end = 4 }, "");
    try std.testing.expectEqualStrings("AeB", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("Ae\u{301}B", model.text());
    try std.testing.expectEqual(Selection.collapsed(4), model.selection);
    try std.testing.expect(model.redo());
    try std.testing.expectEqual(Selection.collapsed(2), model.selection);
    _ = model.selectAll();
    _ = try model.replaceSelection("");
    try std.testing.expectEqualStrings("", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("AeB", model.text());
    try std.testing.expectEqual(Selection{ .anchor = 0, .extent = 3 }, model.selection);
}

test "text input history retains one hundred steps and discards redo after a new edit" {
    var model = try Model.init(std.testing.allocator, "");
    defer model.deinit();
    for (0..101) |_| _ = try model.replaceSelection("x");
    for (0..100) |_| try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("x", model.text());
    try std.testing.expect(!model.undo());
    for (0..100) |_| try std.testing.expect(model.redo());
    try std.testing.expectEqual(@as(usize, 101), model.text().len);
    try std.testing.expect(!model.redo());
    for (0..99) |_| try std.testing.expect(model.undo());
    _ = try model.replaceSelection("Y");
    try std.testing.expectEqualStrings("xxY", model.text());
    try std.testing.expect(!model.redo());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("xx", model.text());
}

test "text input history survives every edit allocation failure and restores without allocating" {
    const scenario = struct {
        fn run(allocator: std.mem.Allocator, coalesce: bool) !void {
            var model = try Model.init(allocator, "ABCDE");
            defer model.deinit();
            _ = try model.replaceRangeGrouped(model.selection.range(), "x", .typing);
            if (!coalesce) _ = model.undo();
            const expected_before = if (coalesce) "ABCDEx" else "ABCDE";
            const selection = model.selection;
            const revision = model.revision;
            _ = model.replaceRangeGrouped(model.selection.range(), "\r\nlong replacement with Ω and several words", .typing) catch |err| {
                try std.testing.expectEqualStrings(expected_before, model.text());
                try std.testing.expectEqual(selection, model.selection);
                try std.testing.expectEqual(revision, model.revision);
                if (coalesce) {
                    try std.testing.expect(model.undo());
                    try std.testing.expectEqualStrings("ABCDE", model.text());
                }
                try std.testing.expect(model.redo());
                try std.testing.expectEqualStrings("ABCDEx", model.text());
                return err;
            };
            try std.testing.expect(!model.redo());
            try std.testing.expect(model.undo());
            try std.testing.expectEqualStrings("ABCDE", model.text());
            try std.testing.expect(model.redo());
            try std.testing.expectEqualStrings(
                if (coalesce) "ABCDEx long replacement with Ω and several words" else "ABCDE long replacement with Ω and several words",
                model.text(),
            );
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scenario.run, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scenario.run, .{true});
}
