const std = @import("std");
const model_module = @import("model.zig");
const CaretAffinity = @import("../../text/positioned_lines.zig").CaretAffinity;
const single_line = @import("single_line.zig");

pub const DeleteSurrounding = struct {
    before_bytes: u32,
    after_bytes: u32,
};

pub const TextUpdate = struct { text: ?[]const u8 };

pub const PreeditUpdate = struct {
    text: ?[]const u8,
    /// UTF-8 byte range inside `text`; null hides the preedit cursor.
    cursor: ?model_module.Range,
};

/// One input-method transaction after platform protocol batching. Presence is
/// retained separately from empty values because a zero-length deletion or an
/// explicit empty commit still has replacement semantics around a selection.
pub const EditBatch = struct {
    delete_surrounding: ?DeleteSurrounding = null,
    commit: ?TextUpdate = null,
    preedit: ?PreeditUpdate = null,
};

pub const Preedit = struct {
    text: []const u8,
    anchor: usize,
    cursor: ?model_module.Range,
};

pub const Surrounding = struct {
    text: []const u8,
    cursor: usize,
    anchor: usize,
};

pub const SelectionGranularity = enum { character, word, line };

const DragAnchor = struct {
    range: model_module.Range,
    affinity: CaretAffinity,
    granularity: SelectionGranularity,
};

/// Retained editing state independent of Wayland, Lua, and rendering. Preedit
/// text stays outside the committed model; paragraph presentation can overlay
/// it at `anchor`, while surrounding text remains directly usable by an input
/// method without first removing composition bytes.
pub const Session = struct {
    allocator: std.mem.Allocator,
    model: model_module.Model,
    preedit_bytes: ?[]u8 = null,
    preedit_anchor: usize = 0,
    preedit_cursor: ?model_module.Range = null,
    /// Paragraph-relative physical X retained across consecutive vertical
    /// moves. Horizontal movement, pointer placement, and edits clear it.
    preferred_x: ?f32 = null,
    drag_anchor: ?DragAnchor = null,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, initial: []const u8) !Session {
        return .{
            .allocator = allocator,
            .model = try model_module.Model.init(allocator, initial),
        };
    }

    pub fn deinit(self: *Session) void {
        if (self.preedit_bytes) |bytes| self.allocator.free(bytes);
        self.model.deinit();
        self.* = undefined;
    }

    pub fn preedit(self: *const Session) ?Preedit {
        return .{
            .text = self.preedit_bytes orelse return null,
            .anchor = self.preedit_anchor,
            .cursor = self.preedit_cursor,
        };
    }

    pub fn surrounding(self: *const Session) Surrounding {
        return .{
            .text = self.model.text(),
            .cursor = self.model.selection.extent,
            .anchor = self.model.selection.anchor,
        };
    }

    pub fn beginSelectionDrag(
        self: *Session,
        byte_offset: usize,
        affinity: CaretAffinity,
    ) !bool {
        return self.beginPointerSelection(byte_offset, affinity, .character, false);
    }

    pub fn beginPointerSelection(
        self: *Session,
        byte_offset: usize,
        affinity: CaretAffinity,
        granularity: SelectionGranularity,
        extend: bool,
    ) !bool {
        const range = switch (granularity) {
            .character => model_module.Range{ .start = byte_offset, .end = byte_offset },
            .word => self.model.wordRangeAt(byte_offset, affinity),
            .line => model_module.Range{ .start = 0, .end = self.model.text().len },
        };
        const previous = self.drag_anchor;
        errdefer self.drag_anchor = previous;
        self.drag_anchor = .{
            .range = if (extend) .{ .start = self.model.selection.anchor, .end = self.model.selection.anchor } else range,
            .affinity = if (extend) self.model.selection.anchor_affinity else affinity,
            .granularity = if (extend) .character else granularity,
        };
        return self.updateSelectionDrag(byte_offset, affinity);
    }

    pub fn updateSelectionDrag(
        self: *Session,
        byte_offset: usize,
        affinity: CaretAffinity,
    ) !bool {
        const anchor = self.drag_anchor orelse return false;
        const selected: model_module.Selection = switch (anchor.granularity) {
            .character => .{
                .anchor = anchor.range.start,
                .extent = byte_offset,
                .anchor_affinity = anchor.affinity,
                .extent_affinity = affinity,
            },
            .word => blk: {
                const range = self.model.wordRangeAt(byte_offset, affinity);
                break :blk if (range.start < anchor.range.start)
                    .{ .anchor = anchor.range.end, .extent = range.start, .anchor_affinity = .upstream }
                else
                    .{ .anchor = anchor.range.start, .extent = @max(anchor.range.end, range.end), .extent_affinity = .upstream };
            },
            .line => .{ .anchor = 0, .extent = self.model.text().len, .extent_affinity = .upstream },
        };
        const changed = try self.model.setSelection(selected);
        self.preferred_x = null;
        return changed;
    }

    pub fn endSelectionDrag(self: *Session) void {
        self.drag_anchor = null;
    }

    pub fn isSelecting(self: *const Session) bool {
        return self.drag_anchor != null;
    }

    pub fn apply(self: *Session, batch: EditBatch) !bool {
        return self.applyEdit(batch, .isolated);
    }

    pub fn typeText(self: *Session, bytes: []const u8) !bool {
        return self.applyEdit(.{ .commit = .{ .text = bytes } }, .typing);
    }

    fn applyEdit(self: *Session, batch: EditBatch, kind: model_module.EditKind) !bool {
        var next_preedit: ?[]u8 = null;
        var next_cursor: ?model_module.Range = null;
        var transferred = false;
        defer if (!transferred) if (next_preedit) |bytes| self.allocator.free(bytes);

        if (batch.preedit) |update| if (update.text) |text| {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            if (text.len != 0) {
                if (update.cursor) |cursor| try validatePreeditCursor(text, cursor);
                next_preedit = try single_line.normalize(self.allocator, text) orelse
                    try self.allocator.dupe(u8, text);
                next_cursor = if (update.cursor) |cursor| .{
                    .start = single_line.offset(text, cursor.start),
                    .end = single_line.offset(text, cursor.end),
                } else null;
            }
        };

        const base = if (self.preedit_bytes != null)
            model_module.Range{ .start = self.preedit_anchor, .end = self.preedit_anchor }
        else
            self.model.selection.range();
        var replacement_range = base;
        if (batch.delete_surrounding) |deletion| {
            const before: usize = deletion.before_bytes;
            const after: usize = deletion.after_bytes;
            if (before > base.start or after > self.model.text().len - base.end)
                return error.DeleteSurroundingOutOfBounds;
            replacement_range = .{
                .start = base.start - before,
                .end = base.end + after,
            };
        }

        const replacement = if (batch.commit) |commit| commit.text orelse "" else "";
        if (!std.unicode.utf8ValidateSlice(replacement)) return error.InvalidUtf8;
        const has_model_edit = batch.delete_surrounding != null or batch.commit != null or
            (next_preedit != null and replacement_range.start != replacement_range.end);
        const composing = self.preedit_bytes != null or next_preedit != null;
        const model_changed = if (has_model_edit)
            try self.model.replaceRangeGrouped(replacement_range, replacement, if (composing) .composition else kind)
        else
            false;

        const old_preedit = self.preedit_bytes;
        // Starting a composition without a selection still ends a typing run.
        // Selection removal and subsequent commits remain one undo step until
        // the input method clears preedit (including cancellation).
        if ((!has_model_edit and old_preedit == null and next_preedit != null) or
            (composing and next_preedit == null)) self.model.breakUndoGroup();
        const preedit_changed = !optionalTextEqual(old_preedit, next_preedit) or
            (next_preedit != null and !std.meta.eql(self.preedit_cursor, next_cursor));
        self.preedit_bytes = next_preedit;
        self.preedit_anchor = self.model.selection.extent;
        self.preedit_cursor = next_cursor;
        transferred = true;
        if (old_preedit) |bytes| self.allocator.free(bytes);

        if (model_changed or preedit_changed) {
            self.preferred_x = null;
            self.drag_anchor = null;
            self.revision +%= 1;
        }
        return model_changed or preedit_changed;
    }
};

fn validatePreeditCursor(text: []const u8, cursor: model_module.Range) !void {
    if (cursor.start > cursor.end or !utf8Boundary(text, cursor.start) or
        !utf8Boundary(text, cursor.end)) return error.InvalidPreeditCursor;
}

fn utf8Boundary(text: []const u8, offset: usize) bool {
    if (offset > text.len) return false;
    return offset == text.len or (text[offset] & 0xc0) != 0x80;
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

test "commit replaces the normalized selection" {
    var session = try Session.init(std.testing.allocator, "hello world");
    defer session.deinit();
    session.preferred_x = 42;
    _ = try session.model.setSelection(.{ .anchor = 11, .extent = 6 });
    try std.testing.expect(try session.apply(.{ .commit = .{ .text = "planet" } }));
    try std.testing.expectEqualStrings("hello planet", session.model.text());
    try std.testing.expectEqual(model_module.Selection.collapsed(12), session.model.selection);
    try std.testing.expect(session.preedit() == null);
    try std.testing.expect(session.preferred_x == null);
}

test "text input typing undo restores directional selection and separates navigation paste and cut" {
    var session = try Session.init(std.testing.allocator, "AΩZ");
    defer session.deinit();
    const selected: model_module.Selection = .{ .anchor = 3, .extent = 1, .anchor_affinity = .upstream };
    _ = try session.model.setSelection(selected);
    _ = try session.typeText("e");
    _ = try session.typeText("\u{301}");
    _ = try session.typeText("👩🏽‍🚀");
    const typed = "Ae\u{301}👩🏽‍🚀Z";
    try std.testing.expectEqualStrings(typed, session.model.text());
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings("AΩZ", session.model.text());
    try std.testing.expectEqual(selected, session.model.selection);
    try std.testing.expect(session.model.redo());
    try std.testing.expectEqualStrings(typed, session.model.text());
    try std.testing.expectEqual(model_module.Selection.collapsed(typed.len - 1), session.model.selection);

    // Even a click at the current position terminates a typing run.
    _ = try session.typeText("!");
    _ = try session.model.setSelection(session.model.selection);
    _ = try session.typeText("?");
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings("Ae\u{301}👩🏽‍🚀!Z", session.model.text());
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings(typed, session.model.text());

    _ = try session.apply(.{ .commit = .{ .text = "\r\npaste" } });
    try std.testing.expect(!session.model.redo());
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings(typed, session.model.text());
    try std.testing.expect(session.model.redo());
    const pasted = "Ae\u{301}👩🏽‍🚀 pasteZ";
    try std.testing.expectEqualStrings(pasted, session.model.text());
    _ = session.model.selectAll();
    _ = try session.model.replaceSelection("");
    try std.testing.expectEqualStrings("", session.model.text());
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings(pasted, session.model.text());
    try std.testing.expectEqual(model_module.Selection{ .anchor = 0, .extent = pasted.len }, session.model.selection);
}

test "text input composition undo includes selection removal but not preedit updates" {
    var session = try Session.init(std.testing.allocator, "abcd");
    defer session.deinit();
    const selected: model_module.Selection = .{ .anchor = 3, .extent = 1 };
    _ = try session.model.setSelection(selected);
    _ = try session.apply(.{ .preedit = .{ .text = "e", .cursor = null } });
    _ = try session.apply(.{ .preedit = .{ .text = "é", .cursor = null } });
    _ = try session.apply(.{ .commit = .{ .text = "Ω" } });
    try std.testing.expectEqualStrings("aΩd", session.model.text());
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings("abcd", session.model.text());
    try std.testing.expectEqual(selected, session.model.selection);
    try std.testing.expect(!session.model.undo());
    try std.testing.expect(session.model.redo());
    try std.testing.expectEqualStrings("aΩd", session.model.text());
    try std.testing.expectEqual(model_module.Selection.collapsed(3), session.model.selection);

    _ = try session.apply(.{ .preedit = .{ .text = "x", .cursor = null } });
    _ = try session.apply(.{ .commit = .{ .text = "X" } });
    try std.testing.expectEqualStrings("aΩXd", session.model.text());
    // Cancelling a preedit with no selected value adds no undo entry.
    _ = try session.apply(.{ .preedit = .{ .text = "unused", .cursor = null } });
    _ = try session.apply(.{ .preedit = .{ .text = null, .cursor = null } });
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings("aΩd", session.model.text());
    try std.testing.expect(session.model.undo());
    try std.testing.expectEqualStrings("abcd", session.model.text());
}

test "single line IME preedit maps cursors and commits normalized surrounding text" {
    var session = try Session.init(std.testing.allocator, "az");
    defer session.deinit();
    _ = try session.model.setSelection(.collapsed(1));
    _ = try session.apply(.{ .preedit = .{
        .text = "é\r\n候\u{2028}補",
        .cursor = .{ .start = "é\r\n".len, .end = "é\r\n候\u{2028}".len },
    } });
    try std.testing.expectEqualStrings("é 候 補", session.preedit().?.text);
    try std.testing.expectEqual(model_module.Range{ .start = "é ".len, .end = "é 候 ".len }, session.preedit().?.cursor.?);
    try std.testing.expectEqualStrings("az", session.surrounding().text);
    _ = try session.apply(.{ .commit = .{ .text = "é\r\n候\u{2028}補" } });
    try std.testing.expectEqualStrings("aé 候 補z", session.surrounding().text);
    try std.testing.expectEqual("aé 候 補".len, session.surrounding().cursor);
    try std.testing.expect(session.preedit() == null);
}

test "preedit removes selection but remains outside committed text" {
    var session = try Session.init(std.testing.allocator, "hello world");
    defer session.deinit();
    _ = try session.model.setSelection(.{ .anchor = 6, .extent = 11 });
    try std.testing.expect(try session.apply(.{ .preedit = .{
        .text = "世界",
        .cursor = .{ .start = 0, .end = "世界".len },
    } }));
    try std.testing.expectEqualStrings("hello ", session.model.text());
    try std.testing.expectEqual(@as(usize, 6), session.preedit().?.anchor);
    try std.testing.expectEqualStrings("世界", session.preedit().?.text);
    try std.testing.expectEqual(model_module.Selection.collapsed(6), session.model.selection);
    try std.testing.expectEqualStrings("hello ", session.surrounding().text);
    try std.testing.expectEqual(@as(usize, 6), session.surrounding().cursor);
}

test "selection drag retains its bidi-aware anchor until release" {
    var session = try Session.init(std.testing.allocator, "abc");
    defer session.deinit();
    try std.testing.expect(try session.beginSelectionDrag(1, .upstream));
    try std.testing.expect(session.isSelecting());
    try std.testing.expect(try session.updateSelectionDrag(3, .downstream));
    try std.testing.expectEqual(model_module.Selection{
        .anchor = 1,
        .extent = 3,
        .anchor_affinity = .upstream,
        .extent_affinity = .downstream,
    }, session.model.selection);
    session.endSelectionDrag();
    try std.testing.expect(!session.isSelecting());
    try std.testing.expect(!(try session.updateSelectionDrag(0, .downstream)));
    try std.testing.expectError(
        error.InvalidGraphemeBoundary,
        session.beginSelectionDrag(4, .downstream),
    );
    try std.testing.expect(!session.isSelecting());
}

test "delete is measured outside selection or standalone preedit" {
    var selected = try Session.init(std.testing.allocator, "abcDEFghi");
    defer selected.deinit();
    _ = try selected.model.setSelection(.{ .anchor = 3, .extent = 6 });
    _ = try selected.apply(.{ .delete_surrounding = .{
        .before_bytes = 1,
        .after_bytes = 1,
    } });
    try std.testing.expectEqualStrings("abhi", selected.model.text());

    var composing = try Session.init(std.testing.allocator, "abcDEFghi");
    defer composing.deinit();
    _ = try composing.model.setSelection(.collapsed(6));
    _ = try composing.apply(.{ .preedit = .{ .text = "候補", .cursor = null } });
    _ = try composing.apply(.{
        .delete_surrounding = .{ .before_bytes = 1, .after_bytes = 1 },
        .commit = .{ .text = "X" },
    });
    try std.testing.expectEqualStrings("abcDEXhi", composing.model.text());
    try std.testing.expect(composing.preedit() == null);
}

test "absent and explicit zero deletion remain distinct" {
    var session = try Session.init(std.testing.allocator, "abc");
    defer session.deinit();
    _ = try session.model.setSelection(.{ .anchor = 1, .extent = 2 });
    try std.testing.expect(!(try session.apply(.{})));
    try std.testing.expectEqualStrings("abc", session.model.text());
    _ = try session.apply(.{ .delete_surrounding = .{ .before_bytes = 0, .after_bytes = 0 } });
    try std.testing.expectEqualStrings("ac", session.model.text());
}

test "invalid protocol ranges leave session unchanged" {
    var session = try Session.init(std.testing.allocator, "AéB");
    defer session.deinit();
    _ = try session.model.setSelection(.collapsed(3));
    try std.testing.expectError(error.InvalidTextOffset, session.apply(.{
        .delete_surrounding = .{ .before_bytes = 1, .after_bytes = 0 },
        .preedit = .{ .text = "safe", .cursor = null },
    }));
    try std.testing.expectEqualStrings("AéB", session.model.text());
    try std.testing.expect(session.preedit() == null);
}

test "pointer word selection respects Unicode segments and reverses by whole words" {
    var session = try Session.init(std.testing.allocator, "one Ωtwo 👩‍💻 end");
    defer session.deinit();
    _ = try session.beginPointerSelection(6, .downstream, .word, false);
    try std.testing.expectEqualStrings("Ωtwo", session.model.text()[session.model.selection.range().start..session.model.selection.range().end]);
    _ = try session.updateSelectionDrag(10, .downstream);
    try std.testing.expectEqual(@as(usize, 4), session.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 21), session.model.selection.extent);
    _ = try session.updateSelectionDrag(1, .downstream);
    try std.testing.expectEqual(@as(usize, 9), session.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    _ = try session.updateSelectionDrag(6, .downstream);
    try std.testing.expectEqual(@as(usize, 4), session.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 9), session.model.selection.extent);
    _ = try session.beginPointerSelection(9, .downstream, .word, false);
    try std.testing.expectEqualStrings(" ", session.model.text()[session.model.selection.range().start..session.model.selection.range().end]);
    _ = try session.beginPointerSelection(9, .upstream, .word, false);
    try std.testing.expectEqual(@as(usize, 4), session.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 9), session.model.selection.extent);
}

test "shift click retains directional anchor and triple click keeps the entire line" {
    var session = try Session.init(std.testing.allocator, "AéB words");
    defer session.deinit();
    _ = try session.model.setSelection(.{ .anchor = 9, .extent = 3, .anchor_affinity = .upstream });
    _ = try session.beginPointerSelection(1, .downstream, .word, true);
    try std.testing.expectEqual(@as(usize, 9), session.model.selection.anchor);
    try std.testing.expectEqual(CaretAffinity.upstream, session.model.selection.anchor_affinity);
    try std.testing.expectEqual(@as(usize, 1), session.model.selection.extent);
    const anchor = session.drag_anchor;
    session.preferred_x = 42;
    try std.testing.expectError(error.InvalidGraphemeBoundary, session.beginSelectionDrag(2, .downstream));
    try std.testing.expectEqualDeep(anchor, session.drag_anchor);
    try std.testing.expectEqual(@as(?f32, 42), session.preferred_x);
    _ = try session.beginPointerSelection(3, .downstream, .line, false);
    _ = try session.updateSelectionDrag(0, .downstream);
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 10), session.model.selection.extent);
    session.endSelectionDrag();
    try std.testing.expect(!session.isSelecting());
}
