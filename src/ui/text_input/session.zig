const std = @import("std");
const model_module = @import("model.zig");

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

    pub fn apply(self: *Session, batch: EditBatch) !bool {
        var next_preedit: ?[]u8 = null;
        var next_cursor: ?model_module.Range = null;
        var transferred = false;
        defer if (!transferred) if (next_preedit) |bytes| self.allocator.free(bytes);

        if (batch.preedit) |update| if (update.text) |text| {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            if (text.len != 0) {
                if (update.cursor) |cursor| try validatePreeditCursor(text, cursor);
                next_preedit = try self.allocator.dupe(u8, text);
                next_cursor = update.cursor;
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
        const model_changed = if (has_model_edit)
            try self.model.replaceRange(replacement_range, replacement)
        else
            false;

        const old_preedit = self.preedit_bytes;
        const preedit_changed = !optionalTextEqual(old_preedit, next_preedit) or
            (next_preedit != null and !std.meta.eql(self.preedit_cursor, next_cursor));
        self.preedit_bytes = next_preedit;
        self.preedit_anchor = self.model.selection.extent;
        self.preedit_cursor = next_cursor;
        transferred = true;
        if (old_preedit) |bytes| self.allocator.free(bytes);

        if (model_changed or preedit_changed) self.revision +%= 1;
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
    _ = try session.model.setSelection(.{ .anchor = 11, .extent = 6 });
    try std.testing.expect(try session.apply(.{ .commit = .{ .text = "planet" } }));
    try std.testing.expectEqualStrings("hello planet", session.model.text());
    try std.testing.expectEqual(model_module.Selection.collapsed(12), session.model.selection);
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
