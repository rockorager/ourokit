const std = @import("std");
const uucode = @import("uucode");
const CaretAffinity = @import("../../text/positioned_lines.zig").CaretAffinity;
const word_break = @import("../../text/word_break.zig");
const single_line = @import("single_line.zig");
const GapBuffer = @import("gap_buffer.zig").GapBuffer;

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
/// A secret field holds at most one PAM response.
pub const secret_capacity = 512;
const HistoryEntry = struct {
    const Edit = struct { start: usize, data_offset: usize, removed_len: usize, inserted_len: usize };
    edits: std.ArrayList(Edit) = .empty,
    // Each edit owns consecutive removed and inserted bytes, not documents.
    data: std.ArrayList(u8) = .empty,
    selection_before: Selection,
    selection_after: Selection,

    fn deinit(value: HistoryEntry, allocator: std.mem.Allocator) void {
        var self = value;
        self.edits.deinit(allocator);
        self.data.deinit(allocator);
    }
};

/// Renderer- and platform-independent state for an editable UTF-8 value.
///
/// Caret positions are always Unicode extended-grapheme boundaries. A compact
/// boundary index makes repeated cursor movement O(log n). Normal text uses a
/// gap buffer with a lazy contiguous read view and grouped, delta-based undo.
pub const Model = struct {
    allocator: std.mem.Allocator,
    // Heap ownership permits lazily refreshing the view through const Model
    // APIs without casting away constness or moving the editing gap.
    gap: ?*GapBuffer = null,
    // Only secret fields use this fixed, locked-page buffer.
    bytes: std.ArrayList(u8) = .empty,
    boundaries: std.ArrayList(usize) = .empty,
    word_boundaries: std.ArrayList(usize) = .empty,
    selection: Selection = .collapsed(0),
    revision: u64 = 0,
    history: std.ArrayList(HistoryEntry) = .empty,
    history_cursor: usize = 0,
    edit_group: ?EditKind = null,
    explicit_group: bool = false,
    explicit_group_started: bool = false,
    multiline: bool = false,
    /// Masked secret mode: the bytes live in one locked, dump-excluded page,
    /// are edited in place, wiped when removed and never copied into undo
    /// history or temporary heap buffers.
    secret_page: ?[]align(std.heap.page_size_min) u8 = null,

    pub fn init(allocator: std.mem.Allocator, raw: []const u8) !Model {
        return initWithMode(allocator, raw, false);
    }

    pub fn initWithMode(allocator: std.mem.Allocator, raw: []const u8, multiline: bool) !Model {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        const normalized = try single_line.normalizeWithMode(allocator, raw, multiline);
        defer if (normalized) |bytes| allocator.free(bytes);
        const initial = normalized orelse raw;
        const boundary_capacity = std.math.add(usize, initial.len, 1) catch
            return error.OutOfMemory;
        var self: Model = .{ .allocator = allocator, .multiline = multiline };
        errdefer self.deinit();
        const gap = try allocator.create(GapBuffer);
        gap.* = .{ .allocator = allocator };
        self.gap = gap;
        try gap.reserve(initial.len);
        gap.replaceAssumeCapacity(0, 0, initial);
        try self.boundaries.ensureTotalCapacity(allocator, boundary_capacity);
        try self.word_boundaries.ensureTotalCapacity(allocator, boundary_capacity);
        self.rebuildBoundaries();
        self.selection = .collapsed(initial.len);
        return self;
    }

    /// An empty single-line secret. Fails rather than falling back to
    /// pageable memory when the page cannot be locked.
    pub fn initSecret(allocator: std.mem.Allocator) !Model {
        const linux = std.os.linux;
        const page = try std.posix.mmap(null, std.heap.page_size_min, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(page);
        if (linux.errno(linux.mlock(page.ptr, page.len)) != .SUCCESS) return error.SecretMemoryUnavailable;
        std.posix.madvise(page.ptr, page.len, linux.MADV.DONTDUMP) catch return error.SecretMemoryUnavailable;
        var self: Model = .{ .allocator = allocator, .secret_page = page };
        self.bytes = .initBuffer(page[0..secret_capacity]);
        errdefer self.boundaries.deinit(allocator);
        try self.boundaries.ensureTotalCapacityPrecise(allocator, secret_capacity + 1);
        try self.word_boundaries.ensureTotalCapacityPrecise(allocator, 2);
        self.rebuildBoundaries();
        return self;
    }

    pub fn isSecret(self: *const Model) bool {
        return self.secret_page != null;
    }

    pub fn deinit(self: *Model) void {
        for (self.history.items) |entry| entry.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.word_boundaries.deinit(self.allocator);
        self.boundaries.deinit(self.allocator);
        if (self.secret_page) |page| {
            std.crypto.secureZero(u8, page);
            std.posix.munmap(page);
        }
        if (self.gap) |gap| {
            gap.deinit();
            self.allocator.destroy(gap);
        }
        self.* = undefined;
    }

    /// Wipes a secret's bytes, for example after submitting them.
    pub fn clearSecret(self: *Model) void {
        const page = self.secret_page orelse return;
        std.crypto.secureZero(u8, page[0..self.bytes.items.len]);
        self.bytes.items.len = 0;
        self.rebuildBoundaries();
        self.selection = .collapsed(0);
        self.bumpRevision();
    }

    pub fn text(self: *const Model) []const u8 {
        return if (self.gap) |gap| gap.text() else self.bytes.items;
    }

    pub fn byteLen(self: *const Model) usize {
        return if (self.gap) |gap| gap.len() else self.bytes.items.len;
    }

    /// Returns a borrowed view of the normalized committed-text selection.
    /// Clipboard owners must copy this view before mutating the model or
    /// retaining it past the current editing phase.
    pub fn selectedText(self: *const Model) []const u8 {
        const range = self.selection.range();
        return self.text()[range.start..range.end];
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
            .anchor = self.boundaryAtOrBefore(@min(value.anchor, self.byteLen())),
            .extent = self.boundaryAtOrBefore(@min(value.extent, self.byteLen())),
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
        const value: Selection = .{ .anchor = 0, .extent = self.byteLen() };
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
        if (self.secret_page != null) return self.replaceSecretRange(range, raw);
        const gap = self.gap.?;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        if (range.start > range.end or range.end > gap.len())
            return error.InvalidTextRange;
        if ((range.start < gap.len() and gap.byteAt(range.start) & 0xc0 == 0x80) or
            (range.end < gap.len() and gap.byteAt(range.end) & 0xc0 == 0x80))
            return error.InvalidTextOffset;
        const normalized = try single_line.normalizeWithMode(self.allocator, raw, self.multiline);
        defer if (normalized) |bytes| self.allocator.free(bytes);
        const replacement = normalized orelse raw;
        const removed_len = range.end - range.start;
        const retained_len = gap.len() - removed_len;
        const new_len = std.math.add(usize, retained_len, replacement.len) catch
            return error.OutOfMemory;
        const boundary_capacity = std.math.add(usize, new_len, 1) catch
            return error.OutOfMemory;

        if (removed_len == 0 and replacement.len == 0) {
            if (kind == .isolated and !self.explicit_group) self.breakUndoGroup();
            return false;
        }

        const coalesce = (if (self.explicit_group) self.explicit_group_started else kind != .isolated and self.edit_group == kind) and
            self.history_cursor == self.history.items.len and self.history_cursor != 0 and
            std.meta.eql(self.selection, self.history.items[self.history_cursor - 1].selection_after);
        if (!coalesce) try self.history.ensureTotalCapacity(self.allocator, @min(self.history.items.len + 1, history_limit));
        var fresh: HistoryEntry = .{ .selection_before = self.selection, .selection_after = self.selection };
        errdefer if (!coalesce) fresh.deinit(self.allocator);
        const entry = if (coalesce) &self.history.items[self.history_cursor - 1] else &fresh;
        const extend_insert = removed_len == 0 and entry.edits.items.len != 0 and
            entry.edits.items[entry.edits.items.len - 1].start + entry.edits.items[entry.edits.items.len - 1].inserted_len == range.start;
        if (!extend_insert) try entry.edits.ensureUnusedCapacity(self.allocator, 1);
        const data_offset = entry.data.items.len;
        const data_len = std.math.add(usize, removed_len, replacement.len) catch return error.OutOfMemory;
        try entry.data.ensureUnusedCapacity(self.allocator, data_len);
        entry.data.items.len += data_len;
        errdefer entry.data.items.len = data_offset;
        gap.copyRange(range.start, entry.data.items[data_offset..][0..removed_len]);
        // Capture borrowed model.text() inputs before reserve can relocate the
        // contiguous view. Failure rolls back the uncommitted history payload.
        const inserted = entry.data.items[data_offset + removed_len ..];
        @memcpy(inserted, replacement);

        // One boundary per byte plus the initial zero is a strict upper bound.
        // History and model allocations all precede the first content mutation.
        try gap.reserve(new_len);
        try self.boundaries.ensureTotalCapacity(self.allocator, boundary_capacity);
        try self.word_boundaries.ensureTotalCapacity(self.allocator, boundary_capacity);
        const was_ascii = gap.non_ascii_bytes == 0;
        const old_len = gap.len();
        const ascii_edit = was_ascii and for (inserted) |byte| {
            if (byte >= 0x80) break false;
        } else true;
        const old_line = if (ascii_edit) null else affectedHardLines(gap, range.start, range.end);
        gap.replaceAssumeCapacity(range.start, range.end, inserted);
        if (ascii_edit)
            self.updateAsciiBoundaries(range, inserted.len, old_len)
        else
            self.updateUnicodeBoundaries(old_line.?, old_line.?.end - range.end + range.start + inserted.len);

        // Text on either side may join the replacement's edge into a larger
        // grapheme. Snap forward so the resulting caret is always valid.
        const requested = range.start + replacement.len;
        self.selection = .collapsed(self.boundaryAtOrAfter(requested));
        self.bumpRevision();
        if (extend_insert) {
            entry.edits.items[entry.edits.items.len - 1].inserted_len += inserted.len;
        } else entry.edits.appendAssumeCapacity(.{
            .start = range.start,
            .data_offset = data_offset,
            .removed_len = removed_len,
            .inserted_len = inserted.len,
        });
        entry.selection_after = self.selection;
        if (!coalesce) {
            for (self.history.items[self.history_cursor..]) |discarded| discarded.deinit(self.allocator);
            self.history.items.len = self.history_cursor;
            if (self.history.items.len == history_limit)
                self.history.orderedRemove(0).deinit(self.allocator);
            self.history.appendAssumeCapacity(fresh);
            self.history_cursor = self.history.items.len;
        }
        self.edit_group = if (kind == .isolated) null else kind;
        if (self.explicit_group) self.explicit_group_started = true;
        return true;
    }

    /// In-place secret edit: no temporary copies, no history, and removed
    /// bytes are wiped. Text that would need line normalization is rejected.
    fn replaceSecretRange(self: *Model, range: Range, raw: []const u8) !bool {
        const page = self.secret_page.?;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        for (raw) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidSecretText;
        if (range.start > range.end or range.end > self.bytes.items.len)
            return error.InvalidTextRange;
        if (!isUtf8Boundary(self.bytes.items, range.start) or
            !isUtf8Boundary(self.bytes.items, range.end))
            return error.InvalidTextOffset;
        const old_len = self.bytes.items.len;
        const removed_len = range.end - range.start;
        if (removed_len == 0 and raw.len == 0) return false;
        const new_len = old_len - removed_len + raw.len;
        if (new_len > secret_capacity) return error.SecretTooLong;
        const tail = old_len - range.end;
        if (raw.len > removed_len) {
            std.mem.copyBackwards(u8, page[range.start + raw.len ..][0..tail], page[range.end..][0..tail]);
        } else {
            std.mem.copyForwards(u8, page[range.start + raw.len ..][0..tail], page[range.end..][0..tail]);
            std.crypto.secureZero(u8, page[new_len..old_len]);
        }
        @memcpy(page[range.start..][0..raw.len], raw);
        self.bytes.items.len = new_len;
        self.rebuildBoundaries();
        self.selection = .collapsed(self.boundaryAtOrAfter(range.start + raw.len));
        self.bumpRevision();
        return true;
    }

    /// Begin a fresh history entry shared by subsequent edits of any kind.
    /// Selection movement, focus/policy changes and undo/redo still end it.
    pub fn beginUndoGroup(self: *Model) void {
        self.breakUndoGroup();
        if (!self.isSecret()) self.explicit_group = true;
    }

    pub fn breakUndoGroup(self: *Model) void {
        self.edit_group = null;
        self.explicit_group = false;
        self.explicit_group_started = false;
    }

    pub fn undo(self: *Model) bool {
        self.breakUndoGroup();
        if (self.history_cursor == 0) return false;
        self.history_cursor -= 1;
        const entry = self.history.items[self.history_cursor];
        var index = entry.edits.items.len;
        while (index != 0) {
            index -= 1;
            const edit = entry.edits.items[index];
            self.gap.?.replaceAssumeCapacity(edit.start, edit.start + edit.inserted_len, entry.data.items[edit.data_offset..][0..edit.removed_len]);
        }
        self.restoreSelection(entry.selection_before);
        return true;
    }

    pub fn redo(self: *Model) bool {
        self.breakUndoGroup();
        if (self.history_cursor == self.history.items.len) return false;
        const entry = self.history.items[self.history_cursor];
        for (entry.edits.items) |edit| {
            self.gap.?.replaceAssumeCapacity(edit.start, edit.start + edit.removed_len, entry.data.items[edit.data_offset + edit.removed_len ..][0..edit.inserted_len]);
        }
        self.restoreSelection(entry.selection_after);
        self.history_cursor += 1;
        return true;
    }

    fn restoreSelection(self: *Model, selection: Selection) void {
        // Every intermediate historical value previously fit these buffers;
        // edits never shrink capacity. Undo/redo cannot fail or allocate.
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
        if (self.byteLen() == 0) return .{ .start = 0, .end = 0 };
        const at = @min(offset, self.byteLen());
        var index = lowerBound(self.word_boundaries.items, at);
        if (index == self.word_boundaries.items.len - 1 or
            (index != 0 and (self.word_boundaries.items[index] != at or affinity == .upstream))) index -= 1;
        return .{
            .start = self.boundaryAtOrBefore(self.word_boundaries.items[index]),
            .end = self.boundaryAtOrAfter(self.word_boundaries.items[index + 1]),
        };
    }

    /// The logical hard line at an insertion offset, including its terminating
    /// LF when present. Single-line models retain the historical whole-value range.
    pub fn lineRangeAt(self: *const Model, offset: usize) Range {
        if (!self.multiline) return .{ .start = 0, .end = self.byteLen() };
        const bytes = self.text();
        const at = @min(offset, bytes.len);
        const start = if (std.mem.lastIndexOfScalar(u8, bytes[0..at], '\n')) |index| index + 1 else 0;
        const end = if (std.mem.indexOfScalar(u8, bytes[at..], '\n')) |index| at + index + 1 else bytes.len;
        return .{ .start = start, .end = end };
    }

    pub fn moveLogicalLine(self: *Model, end: bool, extend: bool) bool {
        const line = self.lineRangeAt(self.selection.extent);
        const offset = if (!end) line.start else if (line.end > line.start and self.text()[line.end - 1] == '\n') line.end - 1 else line.end;
        return self.setExtent(offset, extend);
    }

    /// Select the Unicode segment under the cursor, independent of the visual
    /// edge affinity left by the preceding motion. Never include a hard newline.
    pub fn selectWord(self: *Model, around: bool) !bool {
        const bytes = self.text();
        const line = self.lineRangeAt(self.selection.extent);
        const end = if (line.end > line.start and bytes[line.end - 1] == '\n') line.end - 1 else line.end;
        if (end == line.start) return self.setSelection(.collapsed(end));
        const at = if (self.selection.extent >= end) self.boundaryBefore(end) else self.selection.extent;
        var range = self.wordRangeAt(at, .downstream);
        range.start = @max(range.start, line.start);
        range.end = @min(range.end, end);
        if (around) {
            const original_end = range.end;
            while (range.end < end and (bytes[range.end] == ' ' or bytes[range.end] == '\t')) range.end += 1;
            if (range.end == original_end)
                while (range.start > line.start and (bytes[range.start - 1] == ' ' or bytes[range.start - 1] == '\t')) {
                    range.start -= 1;
                };
        }
        return self.setSelection(.{ .anchor = range.start, .extent = range.end, .extent_affinity = .upstream });
    }

    const VimWordClass = enum { blank, keyword, punctuation };
    pub const VimWordMotion = enum { next_start, previous_start, next_end };

    fn vimWordClass(self: *const Model, index: usize) VimWordClass {
        const at = self.boundaries.items[index];
        const bytes = self.text();
        if (at == bytes.len) return .blank;
        if (bytes[at] == ' ' or bytes[at] == '\t' or bytes[at] == '\n') return .blank;
        if (bytes[at] == '_') return .keyword;
        const len = std.unicode.utf8ByteSequenceLength(bytes[at]) catch unreachable;
        const cp = std.unicode.utf8Decode(bytes[at..][0..len]) catch unreachable;
        return switch (uucode.get(.general_category, cp)) {
            .letter_uppercase,
            .letter_lowercase,
            .letter_titlecase,
            .letter_modifier,
            .letter_other,
            .mark_nonspacing,
            .mark_spacing_combining,
            .mark_enclosing,
            .number_decimal_digit,
            .number_letter,
            .number_other,
            => .keyword,
            else => .punctuation,
        };
    }

    fn vimEmptyLine(self: *const Model, index: usize) bool {
        const at = self.boundaries.items[index];
        const bytes = self.text();
        return (at == bytes.len or bytes[at] == '\n') and (at == 0 or bytes[at - 1] == '\n');
    }

    fn vimWordTarget(self: *const Model, offset: usize, motion: VimWordMotion) usize {
        const boundaries = self.boundaries.items;
        const last = boundaries.len - 1;
        var i = lowerBound(boundaries, offset);
        switch (motion) {
            .next_start => {
                const class = self.vimWordClass(i);
                if (class != .blank) {
                    while (i < last and self.vimWordClass(i) == class) i += 1;
                } else if (i < last) i += 1;
                while (i < last and self.vimWordClass(i) == .blank and !self.vimEmptyLine(i)) i += 1;
            },
            .previous_start => {
                if (i > 0) i -= 1;
                while (i > 0 and self.vimWordClass(i) == .blank and !self.vimEmptyLine(i)) i -= 1;
                const class = self.vimWordClass(i);
                if (class != .blank) while (i > 0 and self.vimWordClass(i - 1) == class) {
                    i -= 1;
                };
            },
            .next_end => {
                if (i < last) i += 1;
                while (i < last and self.vimWordClass(i) == .blank) i += 1;
                const class = self.vimWordClass(i);
                while (i + 1 < last and self.vimWordClass(i + 1) == class) i += 1;
            },
        }
        return boundaries[i];
    }

    /// Separate command-mode motions: Ctrl+Arrow retains UAX #29 semantics.
    /// End motions select inclusively but place a collapsed caret on the last
    /// grapheme. Word classes are letters/numbers/underscore versus punctuation.
    pub fn moveVimWord(self: *Model, motion: VimWordMotion, extend: bool) bool {
        var target = self.vimWordTarget(self.selection.extent, motion);
        if (extend and motion == .next_end) target = self.boundaryAfter(target);
        if (!extend and target == self.byteLen() and target > 0 and self.text()[target - 1] != '\n')
            target = self.boundaryBefore(target);
        return self.setExtent(target, extend);
    }

    /// Operator-w stops before the current hard newline. On nonblank text,
    /// change-word ends at this word's end even on its last grapheme (cw != ce).
    pub fn selectVimForwardWord(self: *Model, change: bool) !bool {
        const start = self.selection.extent;
        const line = self.lineRangeAt(start);
        const i = lowerBound(self.boundaries.items, start);
        var end = self.vimWordTarget(start, .next_start);
        if (change and self.vimWordClass(i) != .blank) {
            var j = i + 1;
            while (j + 1 < self.boundaries.items.len and self.vimWordClass(j) == self.vimWordClass(i)) j += 1;
            end = self.boundaries.items[j];
        }
        if (!self.emptyLine(line)) {
            const line_end = if (line.end > line.start and self.text()[line.end - 1] == '\n') line.end - 1 else line.end;
            end = @min(end, line_end);
        } else end = @min(end, line.end);
        return self.setSelection(.{ .anchor = start, .extent = end });
    }

    pub fn selectVimWord(self: *Model, around: bool) !bool {
        const bytes = self.text();
        const line = self.lineRangeAt(self.selection.extent);
        const end = if (line.end > line.start and bytes[line.end - 1] == '\n') line.end - 1 else line.end;
        if (end == line.start) return self.setSelection(.collapsed(end));
        const at = @min(self.selection.extent, self.boundaryBefore(end));
        var first = lowerBound(self.boundaries.items, at);
        var after = first + 1;
        const class = self.vimWordClass(first);
        while (first > 0 and self.boundaries.items[first] > line.start and self.vimWordClass(first - 1) == class) first -= 1;
        while (self.boundaries.items[after] < end and self.vimWordClass(after) == class) after += 1;
        var range: Range = .{ .start = self.boundaries.items[first], .end = self.boundaries.items[after] };
        if (around) {
            // On whitespace, aw includes the following word rather than only
            // the separator. On a word, prefer its trailing whitespace.
            if (class == .blank and range.end < end) {
                const next_class = self.vimWordClass(after);
                while (self.boundaries.items[after] < end and self.vimWordClass(after) == next_class) after += 1;
                range.end = self.boundaries.items[after];
                return self.setSelection(.{ .anchor = range.start, .extent = range.end, .extent_affinity = .upstream });
            }
            const old_end = range.end;
            while (range.end < end and (bytes[range.end] == ' ' or bytes[range.end] == '\t')) range.end += 1;
            if (old_end == range.end) while (range.start > line.start and (bytes[range.start - 1] == ' ' or bytes[range.start - 1] == '\t')) {
                range.start -= 1;
            };
        }
        return self.setSelection(.{ .anchor = range.start, .extent = range.end, .extent_affinity = .upstream });
    }

    pub fn selectLine(self: *Model) !bool {
        const range = self.lineRangeAt(self.selection.extent);
        return self.setLineSelection(range, range);
    }

    /// Extend whole hard lines, retaining the original anchor line through
    /// shrink and reversal. Upstream end affinity distinguishes a terminating
    /// LF from the empty final line at the same insertion edge.
    pub fn selectLines(self: *Model, destination: @import("intent.zig").LineDestination) !bool {
        const selection = self.selection;
        const anchor = self.lineRangeAt(if (selection.anchor_affinity == .upstream)
            self.boundaryBefore(selection.anchor)
        else
            selection.anchor);
        var active = self.lineRangeAt(if (selection.extent_affinity == .upstream)
            self.boundaryBefore(selection.extent)
        else
            selection.extent);
        const offset = switch (destination) {
            .up => if (active.start > 0) active.start - 1 else 0,
            .down => active.end,
            .start => 0,
            .end => self.byteLen(),
            .paragraph_previous, .paragraph_next => self.paragraphOffset(active.start, destination == .paragraph_next),
        };
        active = self.lineRangeAt(offset);
        return self.setLineSelection(anchor, active);
    }

    fn setLineSelection(self: *Model, anchor: Range, active: Range) !bool {
        return self.setSelection(if (active.start < anchor.start) .{
            .anchor = anchor.end,
            .anchor_affinity = if (anchor.end == anchor.start) .downstream else .upstream,
            .extent = active.start,
        } else .{
            .anchor = anchor.start,
            .extent = active.end,
            .extent_affinity = if (active.end == active.start) .downstream else .upstream,
        });
    }

    fn emptyLine(self: *const Model, line: Range) bool {
        return line.start == line.end or (line.end == line.start + 1 and self.text()[line.start] == '\n');
    }

    /// Paragraphs are runs of nonempty hard lines. Whitespace-only lines are
    /// content. An empty-line cursor selects the contiguous separator run.
    pub fn selectParagraph(self: *Model, around: bool) !bool {
        var range = self.lineRangeAt(self.selection.extent);
        const empty = self.emptyLine(range);
        while (range.start > 0) {
            const previous = self.lineRangeAt(range.start - 1);
            if (self.emptyLine(previous) != empty) break;
            range.start = previous.start;
        }
        while (range.end < self.byteLen()) {
            const next = self.lineRangeAt(range.end);
            if (self.emptyLine(next) != empty) break;
            range.end = next.end;
        }
        if (around and !empty) {
            const original_end = range.end;
            while (range.end < self.byteLen()) {
                const next = self.lineRangeAt(range.end);
                if (!self.emptyLine(next)) break;
                range.end = next.end;
            }
            if (range.end == original_end) while (range.start > 0) {
                const previous = self.lineRangeAt(range.start - 1);
                if (!self.emptyLine(previous)) break;
                range.start = previous.start;
            };
        }
        return self.setSelection(.{ .anchor = range.start, .extent = range.end, .extent_affinity = .upstream });
    }

    pub fn moveParagraph(self: *Model, forward: bool, extend: bool) bool {
        return self.setExtent(self.paragraphOffset(self.selection.extent, forward), extend);
    }

    fn paragraphOffset(self: *const Model, offset: usize, forward: bool) usize {
        var line = self.lineRangeAt(offset);
        var leaving_separator = self.emptyLine(line);
        while (if (forward) line.end < self.byteLen() else line.start > 0) {
            line = self.lineRangeAt(if (forward) line.end else line.start - 1);
            const empty = self.emptyLine(line);
            if (empty and !leaving_separator) return line.start;
            if (!empty) leaving_separator = false;
        }
        return if (forward) self.byteLen() else 0;
    }

    /// Removing an unterminated final line also removes its preceding LF.
    pub fn deleteLine(self: *Model) !bool {
        return self.deleteLineRange(self.lineRangeAt(self.selection.extent));
    }

    pub fn deleteLines(self: *Model) !bool {
        return self.deleteLineRange(self.selection.range());
    }

    fn deleteLineRange(self: *Model, selected: Range) !bool {
        var range = selected;
        var caret = range.start;
        if (range.end == self.byteLen() and range.start > 0 and
            (range.end == range.start or self.text()[range.end - 1] != '\n'))
        {
            caret = self.lineRangeAt(range.start - 1).start;
            range.start -= 1;
        }
        const changed = try self.replaceRange(range, "");
        if (changed) self.finishLineEdit(caret);
        return changed;
    }

    /// Replace selected whole lines with one empty line, preserving a final
    /// line terminator and recording the new insertion point in undo history.
    pub fn clearLines(self: *Model) !bool {
        const range = self.selection.range();
        const terminated = range.end > range.start and self.text()[range.end - 1] == '\n';
        const changed = try self.replaceRange(range, if (terminated) "\n" else "");
        if (changed) self.finishLineEdit(range.start);
        return changed;
    }

    fn finishLineEdit(self: *Model, caret: usize) void {
        self.selection = .collapsed(@min(caret, self.byteLen()));
        if (!self.isSecret()) self.history.items[self.history_cursor - 1].selection_after = self.selection;
    }

    /// Put an owned register at a character or hard-line boundary as one edit.
    /// A linewise register always ends in LF; preserve an unterminated final
    /// document line rather than introducing a second, accidental blank line.
    pub fn put(self: *Model, bytes: []const u8, linewise: bool, after: bool) !bool {
        if (bytes.len == 0 or self.isSecret()) return false;
        const at = self.selection.extent;
        if (!linewise) {
            const offset = if (after and at < self.byteLen() and self.text()[at] != '\n') self.boundaryAfter(at) else at;
            const changed = try self.replaceRange(.{ .start = offset, .end = offset }, bytes);
            if (changed) self.finishLineEdit(if (std.mem.indexOfScalar(u8, bytes, '\n') != null)
                self.boundaryAtOrBefore(offset)
            else
                self.boundaryBefore(offset + bytes.len));
            return changed;
        }
        if (!self.multiline) return false;
        std.debug.assert(bytes[bytes.len - 1] == '\n');
        const line = self.lineRangeAt(at);
        const terminated = line.end > line.start and self.text()[line.end - 1] == '\n';
        const offset = if (after) line.end else line.start;
        const append = after and !terminated;
        const payload = if (append) bytes[0 .. bytes.len - 1] else bytes;
        const inserted = try std.mem.concat(self.allocator, u8, &.{ if (append) "\n" else "", payload });
        defer self.allocator.free(inserted);
        const changed = try self.replaceRange(.{ .start = offset, .end = offset }, inserted);
        if (changed) {
            var indent: usize = 0;
            while (indent < payload.len and (payload[indent] == ' ' or payload[indent] == '\t')) indent += 1;
            self.finishLineEdit(self.boundaryAtOrBefore(offset + @intFromBool(append) + indent));
        }
        return changed;
    }

    /// Inserts an empty hard line at the active extent's line, not a wrapped
    /// visual line. Preserves selected text and records one undoable edit.
    pub fn insertLine(self: *Model, above: bool) !bool {
        if (!self.multiline) return false;
        const line = self.lineRangeAt(self.selection.extent);
        const offset = if (above) line.start else if (line.end > line.start and self.text()[line.end - 1] == '\n') line.end - 1 else line.end;
        const changed = try self.replaceRange(.{ .start = offset, .end = offset }, "\n");
        if (above) {
            // replaceRange positions after inserted bytes; the new line above
            // starts before them. Redo must restore this final caret too.
            self.selection = .collapsed(offset);
            self.history.items[self.history_cursor - 1].selection_after = self.selection;
        }
        return changed;
    }

    fn rebuildBoundaries(self: *Model) void {
        const bytes = self.text();
        self.boundaries.clearRetainingCapacity();
        self.boundaries.appendAssumeCapacity(0);
        var iterator = uucode.grapheme.utf8Iterator(bytes);
        while (iterator.nextGrapheme()) |grapheme|
            self.boundaries.appendAssumeCapacity(grapheme.end);
        self.word_boundaries.clearRetainingCapacity();
        if (self.secret_page != null) {
            // A secret is one word, so word movement reveals no structure.
            self.word_boundaries.appendAssumeCapacity(0);
            if (self.bytes.items.len != 0) self.word_boundaries.appendAssumeCapacity(self.bytes.items.len);
            return;
        }
        word_break.appendAssumeCapacity(bytes, &self.word_boundaries);
    }

    /// LF is a reset point for both segmenters. Replacing all hard lines
    /// touched by the edit therefore cannot depend on context in the retained
    /// prefix, while the first retained suffix line cannot depend on the edit.
    fn updateUnicodeBoundaries(self: *Model, old: Range, new_end: usize) void {
        const bytes = self.text();
        spliceBoundaries(&self.boundaries, old, new_end, bytes[old.start..new_end], .grapheme);
        spliceBoundaries(&self.word_boundaries, old, new_end, bytes[old.start..new_end], .word);
    }

    fn spliceBoundaries(index: *std.ArrayList(usize), old: Range, new_end: usize, local: []const u8, kind: enum { grapheme, word }) void {
        const first = lowerBound(index.items, old.start);
        const after = lowerBound(index.items, old.end + 1);
        const tail_len = index.items.len - after;
        const staged = first + local.len + 1;
        std.debug.assert(staged + tail_len <= index.capacity);
        index.items.len = @max(index.items.len, staged + tail_len);
        const source = index.items[after..][0..tail_len];
        const dest = index.items[staged..][0..tail_len];
        if (staged > after) std.mem.copyBackwards(usize, dest, source) else std.mem.copyForwards(usize, dest, source);
        for (dest) |*offset| offset.* = offset.* - old.end + new_end;

        index.items.len = first;
        switch (kind) {
            .grapheme => {
                index.appendAssumeCapacity(old.start);
                var iterator = uucode.grapheme.utf8Iterator(local);
                while (iterator.nextGrapheme()) |grapheme|
                    index.appendAssumeCapacity(old.start + grapheme.end);
            },
            .word => {
                word_break.appendAssumeCapacity(local, index);
                for (index.items[first..]) |*offset| offset.* += old.start;
            },
        }
        const local_after = index.items.len;
        index.items.len = staged + tail_len;
        std.mem.copyForwards(usize, index.items[local_after..][0..tail_len], index.items[staged..][0..tail_len]);
        index.items.len = local_after + tail_len;
    }

    fn updateAsciiBoundaries(self: *Model, range: Range, inserted_len: usize, old_len: usize) void {
        const length = self.byteLen();
        // Normalization removes CR, so every ASCII byte is a whole grapheme.
        const previous_count = self.boundaries.items.len;
        self.boundaries.items.len = length + 1;
        if (length + 1 > previous_count) {
            for (previous_count..length + 1) |index| self.boundaries.items[index] = index;
        }

        // ASCII has no ignored characters or RI parity. UAX #29 word rules
        // inspect at most two bytes on either side of a boundary. Only the
        // edit and one boundary beyond each edge need reanalysis.
        const start = range.start -| 1;
        const old_end = @min(old_len, range.end + 1);
        const new_end = @min(length, range.start + inserted_len + 1);
        const first = lowerBound(self.word_boundaries.items, start);
        const after = lowerBound(self.word_boundaries.items, old_end + 1);
        const tail_len = self.word_boundaries.items.len - after;
        var count: usize = 0;
        for (start..new_end + 1) |offset| {
            if (self.asciiWordBoundary(offset)) count += 1;
        }
        const new_after = first + count;
        const old_count = self.word_boundaries.items.len;
        self.word_boundaries.items.len = @max(old_count, new_after + tail_len);
        const source = self.word_boundaries.items[after..][0..tail_len];
        const dest = self.word_boundaries.items[new_after..][0..tail_len];
        if (new_after > after) std.mem.copyBackwards(usize, dest, source) else std.mem.copyForwards(usize, dest, source);
        for (dest) |*offset| offset.* = offset.* - range.end + range.start + inserted_len;
        var index = first;
        for (start..new_end + 1) |offset| {
            if (self.asciiWordBoundary(offset)) {
                self.word_boundaries.items[index] = offset;
                index += 1;
            }
        }
        self.word_boundaries.items.len = new_after + tail_len;
    }

    fn asciiWordBoundary(self: *const Model, offset: usize) bool {
        var bytes: [4]u8 = undefined;
        var positions: [5]usize = undefined;
        var boundaries = std.ArrayList(usize).initBuffer(&positions);
        const start = offset -| 2;
        const end = @min(self.byteLen(), offset + 2);
        self.gap.?.copyRange(start, bytes[0 .. end - start]);
        word_break.appendAssumeCapacity(bytes[0 .. end - start], &boundaries);
        return std.mem.indexOfScalar(usize, boundaries.items, offset - start) != null;
    }

    /// Number of extended graphemes, which a masked field draws as dots.
    pub fn graphemeCount(self: *const Model) usize {
        return self.boundaries.items.len - 1;
    }

    /// Grapheme index of a boundary offset, and back. Masked presentation
    /// and pointer hit testing translate through these.
    pub fn graphemeIndex(self: *const Model, offset: usize) usize {
        return lowerBound(self.boundaries.items, offset);
    }

    pub fn graphemeOffset(self: *const Model, index: usize) usize {
        return self.boundaries.items[@min(index, self.boundaries.items.len - 1)];
    }

    pub fn isBoundary(self: *const Model, offset: usize) bool {
        const index = lowerBound(self.boundaries.items, offset);
        return index < self.boundaries.items.len and self.boundaries.items[index] == offset;
    }

    fn boundaryBefore(self: *const Model, offset: usize) usize {
        const index = lowerBound(self.boundaries.items, offset);
        return if (index == 0) 0 else self.boundaries.items[index - 1];
    }

    fn boundaryAfter(self: *const Model, offset: usize) usize {
        const index = lowerBound(self.boundaries.items, offset);
        if (index >= self.boundaries.items.len - 1) return self.byteLen();
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
            if (word_break.isWordSegment(self.text()[start..end])) return start;
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
            if (word_break.isWordSegment(self.text()[start..end])) return end;
        }
        return self.byteLen();
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

fn affectedHardLines(gap: *const GapBuffer, start: usize, end: usize) Range {
    var line_start = start;
    while (line_start != 0 and gap.byteAt(line_start - 1) != '\n') : (line_start -= 1) {}
    var line_end = end;
    while (line_end < gap.len()) {
        line_end += 1;
        if (gap.byteAt(line_end - 1) == '\n') break;
    }
    return .{ .start = line_start, .end = line_end };
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

test "multiline model preserves normalized lines through selection deletion and undo" {
    var model = try Model.initWithMode(std.testing.allocator, "α\r\nβ\u{2029}👩🏽‍🚀\nZ", true);
    defer model.deinit();
    try std.testing.expect(model.multiline);
    try std.testing.expectEqualStrings("α\nβ\n👩🏽‍🚀\nZ", model.text());
    _ = try model.setSelection(.{ .anchor = "α\nβ\n".len, .extent = "α\n".len });
    _ = try model.replaceSelection("Ω\rX");
    try std.testing.expectEqualStrings("α\nΩ\nX👩🏽‍🚀\nZ", model.text());
    _ = try model.deleteBackward();
    try std.testing.expectEqualStrings("α\nΩ\n👩🏽‍🚀\nZ", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("α\nΩ\nX👩🏽‍🚀\nZ", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("α\nβ\n👩🏽‍🚀\nZ", model.text());
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

test "random multiline Unicode edits match full grapheme and word analysis" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xa917382);
    const random = prng.random();
    const ascii = [_][]const u8{ "", "a", "Qz", "_", ".", ":", "'", "\"", "19", ",", " ", "\t", "\n", "abc_12.3", "\x00", "\x7f" };
    const unicode = ascii ++ [_][]const u8{
        "Ω",
        "\u{301}",
        "🇦🇧🇨",
        "🇦🇧🇨🇩",
        "👩🏽‍🚀",
        "אב",
        "\u{200d}",
        "\u{200c}",
        "\u{600}",
        "a\u{301}\u{200c}\u{301}",
        "\n🇦🇧🇨\n",
        "x\n\u{200d}\u{301}y",
    };
    for ([_][]const []const u8{ &ascii, &unicode }) |replacements| {
        var model = try Model.initWithMode(allocator, "can't 12,345\nright", true);
        defer model.deinit();
        var expected = try allocator.dupe(u8, model.text());
        defer allocator.free(expected);
        for (0..150) |_| {
            const before = try allocator.dupe(u8, expected);
            defer allocator.free(before);
            const selection_before = model.selection;
            var changed = false;
            for (0..10) |_| {
                var a = random.uintLessThan(usize, expected.len + 1);
                var b = random.uintLessThan(usize, expected.len + 1);
                while (!isUtf8Boundary(expected, a)) a -= 1;
                while (!isUtf8Boundary(expected, b)) b -= 1;
                const start = @min(a, b);
                const end = @max(a, b);
                const replacement = replacements[random.uintLessThan(usize, replacements.len)];
                const next = try std.mem.concat(allocator, u8, &.{ expected[0..start], replacement, expected[end..] });
                allocator.free(expected);
                expected = next;
                changed = (try model.replaceRangeGrouped(.{ .start = start, .end = end }, replacement, .composition)) or changed;
                try std.testing.expectEqualStrings(expected, model.text());
                var words = try word_break.analyze(allocator, expected);
                defer words.deinit();
                try std.testing.expectEqualSlices(usize, words.boundaries, model.word_boundaries.items);
                var graphemes = uucode.grapheme.utf8Iterator(expected);
                var index: usize = 1;
                while (graphemes.nextGrapheme()) |grapheme| : (index += 1)
                    try std.testing.expectEqual(grapheme.end, model.boundaries.items[index]);
                try std.testing.expectEqual(index, model.boundaries.items.len);
            }
            if (changed) {
                const selection_after = model.selection;
                try std.testing.expect(model.undo());
                try std.testing.expectEqualStrings(before, model.text());
                try std.testing.expectEqual(selection_before, model.selection);
                try std.testing.expect(model.redo());
                try std.testing.expectEqualStrings(expected, model.text());
                try std.testing.expectEqual(selection_after, model.selection);
            }
        }
    }
}

test "text input borrowed replacement survives growth and every allocation failure" {
    const scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const initial = "abcdefgh" ** 32;
            var model = try Model.init(allocator, initial);
            defer model.deinit();
            _ = model.replaceRange(.{ .start = 3, .end = 7 }, model.text()) catch |err| {
                try std.testing.expectEqualStrings(initial, model.text());
                try std.testing.expect(!model.undo());
                return err;
            };
            try std.testing.expectEqualStrings(initial[0..3] ++ initial ++ initial[7..], model.text());
            try std.testing.expect(model.undo());
            try std.testing.expectEqualStrings(initial, model.text());
            try std.testing.expect(model.redo());
            try std.testing.expectEqualStrings(initial[0..3] ++ initial ++ initial[7..], model.text());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, scenario.run, .{});
}

test "text input repeated typing amortizes allocations and does not flatten the gap" {
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var model = try Model.init(counter.allocator(), "left right");
    defer model.deinit();
    _ = try model.setSelection(.collapsed(5));
    const allocations = counter.alloc_index;
    for (0..4096) |_| _ = try model.replaceRangeGrouped(model.selection.range(), "k", .typing);
    try std.testing.expect(counter.alloc_index - allocations < 100);
    try std.testing.expect(!model.gap.?.snapshot_valid);
    try std.testing.expectEqual(@as(usize, 4096), model.history.items[0].data.items.len);
    try std.testing.expectEqual(@as(usize, 1), model.history.items[0].edits.items.len);
    try std.testing.expectEqual(@as(usize, 4101), model.gap.?.gap_start);
    try std.testing.expectEqualStrings("left " ++ "k" ** 4096 ++ "right", model.text());
    try std.testing.expectEqual(@as(usize, 4101), model.gap.?.gap_start);
    counter.fail_index = counter.alloc_index;
    counter.resize_fail_index = counter.resize_index;
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("left right", model.text());
    try std.testing.expect(model.redo());
    try std.testing.expectEqualStrings("left " ++ "k" ** 4096 ++ "right", model.text());
}

test "logical line edits preserve selected text and restore caret and selection through history" {
    const original = "Wé\n\nlast";
    for ([_]bool{ false, true }) |above| {
        var model = try Model.initWithMode(std.testing.allocator, original, true);
        defer model.deinit();
        const reversed: Selection = .{ .anchor = original.len, .extent = 1 };
        _ = try model.setSelection(reversed);
        try std.testing.expect(try model.insertLine(above));
        try std.testing.expectEqualStrings(if (above) "\nWé\n\nlast" else "Wé\n\n\nlast", model.text());
        const after = Selection.collapsed(if (above) 0 else 4);
        try std.testing.expectEqual(after, model.selection);
        try std.testing.expect(model.undo());
        try std.testing.expectEqualStrings(original, model.text());
        try std.testing.expectEqual(reversed, model.selection);
        try std.testing.expect(!model.undo());
        try std.testing.expect(model.redo());
        try std.testing.expectEqual(after, model.selection);
    }
    var model = try Model.initWithMode(std.testing.allocator, original, true);
    defer model.deinit();
    _ = try model.setSelection(.{ .anchor = 1, .extent = 6 });
    try std.testing.expect(model.moveLogicalLine(false, true));
    try std.testing.expectEqual(Selection{ .anchor = 1, .extent = 5 }, model.selection);
    try std.testing.expect(model.moveLogicalLine(true, false));
    try std.testing.expectEqual(Selection.collapsed(9), model.selection);
    try std.testing.expect(try model.insertLine(false));
    try std.testing.expectEqualStrings("Wé\n\nlast\n", model.text());
    try std.testing.expectEqual(Selection.collapsed(10), model.selection);
    try std.testing.expect(try model.insertLine(true));
    try std.testing.expectEqualStrings("Wé\n\nlast\n\n", model.text());
    try std.testing.expectEqual(Selection.collapsed(10), model.selection);

    var single = try Model.init(std.testing.allocator, "no newline");
    defer single.deinit();
    try std.testing.expect(!try single.insertLine(true));
    try std.testing.expect(!try single.insertLine(false));
    try std.testing.expect(!single.undo());
}

test "text objects select Unicode words and surrounding space without crossing newlines" {
    var model = try Model.initWithMode(std.testing.allocator, "one  café!\n\nlast", true);
    defer model.deinit();
    _ = try model.setSelection(.collapsedAt(5, .upstream));
    _ = try model.selectWord(false);
    try std.testing.expectEqualStrings("café", model.selectedText());
    _ = try model.setSelection(.collapsed(6));
    _ = try model.selectWord(true);
    try std.testing.expectEqualStrings("  café", model.selectedText());
    _ = try model.replaceSelection("");
    try std.testing.expectEqualStrings("one!\n\nlast", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("  café", model.selectedText());
    _ = try model.setSelection(.collapsed(1));
    _ = try model.selectWord(true);
    try std.testing.expectEqualStrings("one  ", model.selectedText());
    _ = try model.setSelection(.collapsed(12));
    _ = try model.selectWord(false);
    try std.testing.expectEqualStrings("", model.selectedText());
    try std.testing.expect(!try model.replaceSelection(""));
    try std.testing.expectEqualStrings("one  café!\n\nlast", model.text());

    var graphemes = try Model.initWithMode(std.testing.allocator, "e\u{301} 👩‍💻", true);
    defer graphemes.deinit();
    _ = try graphemes.setSelection(.collapsed(4));
    _ = try graphemes.selectWord(false);
    try std.testing.expectEqualStrings("👩‍💻", graphemes.selectedText());
    _ = try graphemes.setSelection(.collapsed(0));
    _ = try graphemes.selectWord(false);
    try std.testing.expectEqualStrings("e\u{301}", graphemes.selectedText());
}

test "paragraph objects preserve separators and navigate in both directions" {
    var model = try Model.initWithMode(std.testing.allocator, "first\nα\n\n\nlast\ntail", true);
    defer model.deinit();
    _ = try model.setSelection(.collapsed(6));
    _ = try model.selectParagraph(false);
    try std.testing.expectEqualStrings("first\nα\n", model.selectedText());
    _ = try model.setSelection(.collapsed(6));
    _ = try model.selectParagraph(true);
    try std.testing.expectEqualStrings("first\nα\n\n\n", model.selectedText());
    _ = try model.setSelection(.collapsed(model.byteLen()));
    _ = try model.selectParagraph(true);
    try std.testing.expectEqualStrings("\n\nlast\ntail", model.selectedText());
    _ = try model.setSelection(.collapsed(10));
    _ = try model.selectParagraph(false);
    try std.testing.expectEqualStrings("\n\n", model.selectedText());
    _ = try model.setSelection(.collapsed(0));
    _ = model.moveParagraph(true, false);
    try std.testing.expectEqual(@as(usize, 9), model.selection.extent);
    _ = model.moveParagraph(true, false);
    try std.testing.expectEqual(model.byteLen(), model.selection.extent);
    _ = model.moveParagraph(false, false);
    try std.testing.expectEqual(@as(usize, 10), model.selection.extent);
    _ = model.moveParagraph(false, false);
    try std.testing.expectEqual(@as(usize, 0), model.selection.extent);
}

test "whole line selection shrinks reverses and includes a trailing empty line" {
    var model = try Model.initWithMode(std.testing.allocator, "α\nbeta\nc\n", true);
    defer model.deinit();
    _ = try model.setSelection(.collapsed(4));
    _ = try model.selectLine();
    try std.testing.expectEqualStrings("beta\n", model.selectedText());
    _ = try model.selectLines(.down);
    try std.testing.expectEqualStrings("beta\nc\n", model.selectedText());
    _ = try model.selectLines(.up);
    try std.testing.expectEqualStrings("beta\n", model.selectedText());
    _ = try model.selectLines(.up);
    try std.testing.expectEqualStrings("α\nbeta\n", model.selectedText());
    try std.testing.expectEqual(@as(usize, 0), model.selection.extent);
    _ = try model.selectLines(.down);
    try std.testing.expectEqualStrings("beta\n", model.selectedText());
    _ = try model.selectLines(.end);
    try std.testing.expectEqual(.downstream, model.selection.extent_affinity);
    _ = try model.selectLines(.up);
    try std.testing.expectEqual(.upstream, model.selection.extent_affinity);
    _ = try model.selectLines(.up);
    try std.testing.expectEqualStrings("beta\n", model.selectedText());
    _ = try model.setSelection(.collapsed(model.byteLen()));
    _ = try model.selectLine();
    _ = try model.selectLines(.up);
    try std.testing.expectEqualStrings("c\n", model.selectedText());
    _ = try model.selectLines(.down);
    try std.testing.expect(model.selection.isCollapsed());
    try std.testing.expectEqual(model.byteLen(), model.selection.extent);
}

test "line delete and change retain newline boundaries and native undo selections" {
    for ([_]struct { text: []const u8, at: usize, expected: []const u8, caret: usize }{
        .{ .text = "one\ntwo\nlast", .at = 5, .expected = "one\nlast", .caret = 4 },
        .{ .text = "one\ntwo\nlast", .at = 10, .expected = "one\ntwo", .caret = 4 },
        .{ .text = "one\n", .at = 4, .expected = "one", .caret = 0 },
        .{ .text = "one", .at = 1, .expected = "", .caret = 0 },
    }) |case| {
        var model = try Model.initWithMode(std.testing.allocator, case.text, true);
        defer model.deinit();
        _ = try model.setSelection(.collapsed(case.at));
        _ = try model.deleteLine();
        try std.testing.expectEqualStrings(case.expected, model.text());
        try std.testing.expectEqual(case.caret, model.selection.extent);
        try std.testing.expect(model.undo());
        try std.testing.expectEqualStrings(case.text, model.text());
        try std.testing.expectEqual(case.at, model.selection.extent);
        try std.testing.expect(model.redo());
        try std.testing.expectEqual(case.caret, model.selection.extent);
    }
    var model = try Model.initWithMode(std.testing.allocator, "one\ntwo\nlast", true);
    defer model.deinit();
    _ = try model.selectLine();
    _ = try model.selectLines(.up);
    const selected = model.selection;
    _ = try model.deleteLines();
    try std.testing.expectEqualStrings("one", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqual(selected, model.selection);
    _ = try model.clearLines();
    try std.testing.expectEqualStrings("one\n", model.text());
    try std.testing.expectEqual(@as(usize, 4), model.selection.extent);
    try std.testing.expect(model.undo());
    _ = try model.setSelection(.collapsed(1));
    _ = try model.selectLine();
    _ = try model.clearLines();
    try std.testing.expectEqualStrings("\ntwo\nlast", model.text());
    try std.testing.expectEqual(@as(usize, 0), model.selection.extent);
}

test "Vim word motions distinguish starts ends punctuation underscores and blank lines" {
    var model = try Model.initWithMode(std.testing.allocator, "one_two...  café\n\n  last", true);
    defer model.deinit();
    for ([_]struct { at: usize, motion: Model.VimWordMotion, target: usize }{
        .{ .at = 0, .motion = .next_start, .target = 7 },
        .{ .at = 7, .motion = .next_start, .target = 12 },
        .{ .at = 12, .motion = .next_start, .target = 18 },
        .{ .at = 18, .motion = .next_start, .target = 21 },
        .{ .at = 21, .motion = .previous_start, .target = 18 },
        .{ .at = 18, .motion = .previous_start, .target = 12 },
        .{ .at = 6, .motion = .previous_start, .target = 0 },
        .{ .at = 0, .motion = .previous_start, .target = 0 },
        .{ .at = 0, .motion = .next_end, .target = 6 },
        .{ .at = 6, .motion = .next_end, .target = 9 },
        .{ .at = 9, .motion = .next_end, .target = 15 },
        .{ .at = 15, .motion = .next_end, .target = 24 },
        .{ .at = 24, .motion = .next_start, .target = 24 },
    }) |case| {
        _ = try model.setSelection(.collapsed(case.at));
        _ = model.moveVimWord(case.motion, false);
        try std.testing.expectEqual(case.target, model.selection.extent);
        try std.testing.expect(model.selection.isCollapsed());
    }
    // The native Ctrl+Right path must not acquire Vim's next-start behavior.
    _ = try model.setSelection(.collapsed(0));
    _ = model.moveWordNext(false);
    try std.testing.expectEqual(@as(usize, 7), model.selection.extent);
    _ = try model.setSelection(.collapsed(12));
    _ = model.moveWordNext(false);
    try std.testing.expectEqual(@as(usize, 17), model.selection.extent);
}

test "Vim word selection keeps graphemes and differs for cw ce and dw at hard EOL" {
    var model = try Model.initWithMode(std.testing.allocator, "e\u{301}_é.. 👩‍💻", true);
    defer model.deinit();
    _ = try model.setSelection(.collapsed(0));
    _ = model.moveVimWord(.next_end, false);
    try std.testing.expectEqual(@as(usize, 4), model.selection.extent);
    _ = try model.setSelection(.collapsed(0));
    _ = model.moveVimWord(.next_end, true);
    try std.testing.expectEqualStrings("e\u{301}_é", model.selectedText());
    _ = try model.setSelection(.collapsed(6));
    _ = try model.selectVimWord(false);
    try std.testing.expectEqualStrings("..", model.selectedText());
    _ = try model.setSelection(.collapsed(8));
    _ = try model.selectVimWord(true);
    try std.testing.expectEqualStrings(" 👩‍💻", model.selectedText());
    _ = try model.setSelection(.collapsed(9));
    _ = model.moveVimWord(.next_end, true);
    try std.testing.expectEqualStrings("👩‍💻", model.selectedText());

    for ([_]struct { bytes: []const u8, at: usize, change: bool, selected: []const u8 }{
        .{ .bytes = "one  two\nlast", .at = 0, .change = false, .selected = "one  " },
        .{ .bytes = "one  two\nlast", .at = 0, .change = true, .selected = "one" },
        .{ .bytes = "one  two\nlast", .at = 2, .change = true, .selected = "e" },
        .{ .bytes = "one  \n  two", .at = 0, .change = false, .selected = "one  " },
        .{ .bytes = "one  \n  two", .at = 3, .change = true, .selected = "  " },
        .{ .bytes = "\n  two", .at = 0, .change = false, .selected = "\n" },
        .{ .bytes = "", .at = 0, .change = true, .selected = "" },
    }) |case| {
        var words = try Model.initWithMode(std.testing.allocator, case.bytes, true);
        defer words.deinit();
        _ = try words.setSelection(.collapsed(case.at));
        _ = try words.selectVimForwardWord(case.change);
        try std.testing.expectEqualStrings(case.selected, words.selectedText());
    }
    var words = try Model.initWithMode(std.testing.allocator, "one  two", true);
    defer words.deinit();
    _ = try words.setSelection(.collapsed(2));
    _ = words.moveVimWord(.next_end, true);
    try std.testing.expectEqualStrings("e  two", words.selectedText());
}

test "register puts preserve hard line structure grapheme carets and undo redo" {
    for ([_]struct { bytes: []const u8, at: usize, value: []const u8, linewise: bool = true, after: bool = true, expected: []const u8, caret: usize }{
        .{ .bytes = "one\nlast", .at = 1, .value = "  middle\n", .expected = "one\n  middle\nlast", .caret = 6 },
        .{ .bytes = "one\nlast", .at = 7, .value = "  middle\n", .expected = "one\nlast\n  middle", .caret = 11 },
        .{ .bytes = "one\nlast", .at = 5, .value = "x\ny\n", .after = false, .expected = "one\nx\ny\nlast", .caret = 4 },
        .{ .bytes = "one\n", .at = 1, .value = "x\n", .expected = "one\nx\n", .caret = 4 },
        .{ .bytes = "one\n", .at = 4, .value = "x\n", .expected = "one\n\nx", .caret = 5 },
        .{ .bytes = "", .at = 0, .value = "x\n", .expected = "\nx", .caret = 1 },
        .{ .bytes = "", .at = 0, .value = "x\n", .after = false, .expected = "x\n", .caret = 0 },
        .{ .bytes = "", .at = 0, .value = "\n", .expected = "\n", .caret = 1 },
        .{ .bytes = "a", .at = 0, .value = " \u{301}x\n", .expected = "a\n \u{301}x", .caret = 2 },
        .{ .bytes = "éZ", .at = 0, .value = "e\u{301}", .linewise = false, .expected = "ée\u{301}Z", .caret = 2 },
        .{ .bytes = "éZ", .at = 0, .value = "xy", .linewise = false, .after = false, .expected = "xyéZ", .caret = 1 },
        .{ .bytes = "eZ", .at = 0, .value = "\u{301}", .linewise = false, .expected = "e\u{301}Z", .caret = 0 },
        .{ .bytes = "a\nz", .at = 1, .value = "β", .linewise = false, .expected = "aβ\nz", .caret = 1 },
        .{ .bytes = "az", .at = 0, .value = "q\nr", .linewise = false, .expected = "aq\nrz", .caret = 1 },
    }) |case| {
        var model = try Model.initWithMode(std.testing.allocator, case.bytes, true);
        defer model.deinit();
        _ = try model.setSelection(.collapsed(case.at));
        try std.testing.expect(try model.put(case.value, case.linewise, case.after));
        try std.testing.expectEqualStrings(case.expected, model.text());
        try std.testing.expectEqual(Selection.collapsed(case.caret), model.selection);
        try std.testing.expect(model.undo());
        try std.testing.expectEqualStrings(case.bytes, model.text());
        try std.testing.expectEqual(Selection.collapsed(case.at), model.selection);
        try std.testing.expect(!model.undo());
        try std.testing.expect(model.redo());
        try std.testing.expectEqualStrings(case.expected, model.text());
        try std.testing.expectEqual(Selection.collapsed(case.caret), model.selection);
    }
}

test "editor explicit groups mix deltas but end on selection and explicit boundaries" {
    var model = try Model.initWithMode(std.testing.allocator, "old tail", true);
    defer model.deinit();
    const original: Selection = .{ .anchor = 3, .extent = 0 };
    _ = try model.setSelection(original);
    model.beginUndoGroup();
    _ = try model.replaceSelection("");
    _ = try model.replaceRangeGrouped(model.selection.range(), "β", .typing);
    _ = try model.replaceRangeGrouped(model.selection.range(), "x", .typing);
    _ = try model.deleteBackward();
    _ = try model.replaceSelection("!");
    try std.testing.expectEqualStrings("β! tail", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("old tail", model.text());
    try std.testing.expectEqual(original, model.selection);
    try std.testing.expect(!model.undo());
    try std.testing.expect(model.redo());
    try std.testing.expectEqualStrings("β! tail", model.text());
    model.beginUndoGroup();
    _ = try model.replaceSelection("1");
    _ = model.movePrevious(false);
    _ = try model.replaceSelection("2");
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("β!1 tail", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("β! tail", model.text());
    model.beginUndoGroup();
    _ = try model.replaceSelection("3");
    model.breakUndoGroup();
    _ = try model.replaceSelection("4");
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("β!3 tail", model.text());
    try std.testing.expect(model.undo());
    try std.testing.expectEqualStrings("β! tail", model.text());
}

test "secret model edits in place, caps length, rejects controls and wipes removed bytes" {
    var model = try Model.initSecret(std.testing.allocator);
    defer model.deinit();
    const page = model.secret_page.?;
    try std.testing.expect(try model.replaceSelection("hunter2"));
    try std.testing.expectEqualStrings("hunter2", model.text());
    try std.testing.expect(!model.undo());
    try std.testing.expectError(error.InvalidSecretText, model.replaceSelection("a\nb"));
    // Deleting wipes the vacated tail inside the locked page.
    _ = try model.setSelection(.{ .anchor = 3, .extent = 7 });
    try std.testing.expect(try model.replaceSelection(""));
    try std.testing.expectEqualStrings("hun", model.text());
    try std.testing.expect(std.mem.allEqual(u8, page[3..7], 0));
    // Word movement treats the whole secret as one word.
    try std.testing.expect(model.moveWordPrevious(false));
    try std.testing.expectEqual(@as(usize, 0), model.selection.extent);
    var long: [secret_capacity + 1]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expectError(error.SecretTooLong, model.replaceSelection(&long));
    model.clearSecret();
    try std.testing.expectEqualStrings("", model.text());
    try std.testing.expect(std.mem.allEqual(u8, page[0..8], 0));
}
