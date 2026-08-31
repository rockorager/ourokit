const std = @import("std");
const platform = @import("../window.zig");

const max_event_text_bytes = 64 * 1024;

/// Owns text-input-v3 event fragments until `done` makes them one atomic
/// platform event. Wayring's decoded strings borrow receive storage and must
/// never escape protocol dispatch directly.
pub const Pending = struct {
    allocator: std.mem.Allocator,
    focused: ?platform.WindowHandle = null,
    commit_count: u32 = 0,
    commit_received: bool = false,
    commit_is_null: bool = false,
    commit_bytes: std.ArrayList(u8) = .empty,
    preedit_received: bool = false,
    preedit_is_null: bool = false,
    preedit_bytes: std.ArrayList(u8) = .empty,
    preedit_cursor_begin: i32 = 0,
    preedit_cursor_end: i32 = 0,
    delete_received: bool = false,
    delete_before_bytes: u32 = 0,
    delete_after_bytes: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Pending {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pending) void {
        self.commit_bytes.deinit(self.allocator);
        self.preedit_bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn enter(self: *Pending, window: platform.WindowHandle) void {
        self.clearBatch();
        self.focused = window;
    }

    pub fn leave(self: *Pending, window: platform.WindowHandle) bool {
        if (self.focused == null or !sameHandle(self.focused.?, window)) return false;
        self.clearBatch();
        self.focused = null;
        return true;
    }

    pub fn noteCommit(self: *Pending) void {
        self.commit_count +%= 1;
    }

    pub fn resetObject(self: *Pending) void {
        self.clearBatch();
        self.focused = null;
        self.commit_count = 0;
    }

    pub fn setCommit(self: *Pending, text: ?[]const u8) !void {
        try setText(
            self.allocator,
            &self.commit_bytes,
            &self.commit_received,
            &self.commit_is_null,
            text,
        );
    }

    pub fn setPreedit(self: *Pending, text: ?[]const u8, cursor_begin: i32, cursor_end: i32) !void {
        try validatePreedit(text, cursor_begin, cursor_end);
        try setText(
            self.allocator,
            &self.preedit_bytes,
            &self.preedit_received,
            &self.preedit_is_null,
            text,
        );
        self.preedit_cursor_begin = cursor_begin;
        self.preedit_cursor_end = cursor_end;
    }

    pub fn setDelete(self: *Pending, before_bytes: u32, after_bytes: u32) void {
        self.delete_received = true;
        self.delete_before_bytes = before_bytes;
        self.delete_after_bytes = after_bytes;
    }

    /// The returned slices borrow this accumulator and remain valid only until
    /// `finishDone` returns. The sink therefore has to copy them synchronously.
    pub fn finishDone(self: *Pending, serial: u32, sink: platform.EventSink) !void {
        const window = self.focused orelse {
            self.clearBatch();
            return;
        };
        defer self.clearBatch();
        try sink.textInput(.{ .batch = .{
            .window = window,
            .serial = serial,
            .serial_matches_state = serial == self.commit_count,
            .delete_surrounding = if (self.delete_received) .{
                .before_bytes = self.delete_before_bytes,
                .after_bytes = self.delete_after_bytes,
            } else null,
            .commit = if (self.commit_received) .{
                .text = if (self.commit_is_null) null else self.commit_bytes.items,
            } else null,
            .preedit = if (self.preedit_received) .{
                .text = if (self.preedit_is_null) null else self.preedit_bytes.items,
                .cursor_begin = self.preedit_cursor_begin,
                .cursor_end = self.preedit_cursor_end,
            } else null,
        } });
    }

    fn clearBatch(self: *Pending) void {
        self.commit_received = false;
        self.commit_is_null = false;
        self.commit_bytes.clearRetainingCapacity();
        self.preedit_received = false;
        self.preedit_is_null = false;
        self.preedit_bytes.clearRetainingCapacity();
        self.preedit_cursor_begin = 0;
        self.preedit_cursor_end = 0;
        self.delete_received = false;
        self.delete_before_bytes = 0;
        self.delete_after_bytes = 0;
    }
};

fn setText(
    allocator: std.mem.Allocator,
    destination: *std.ArrayList(u8),
    received: *bool,
    is_null: *bool,
    text: ?[]const u8,
) !void {
    if (text) |bytes| {
        if (bytes.len > max_event_text_bytes) return error.TextInputEventTooLarge;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        try destination.resize(allocator, bytes.len);
        @memcpy(destination.items, bytes);
        is_null.* = false;
    } else {
        destination.clearRetainingCapacity();
        is_null.* = true;
    }
    received.* = true;
}

fn validatePreedit(text: ?[]const u8, begin: i32, end: i32) !void {
    const bytes = text orelse {
        if ((begin == -1 and end == -1) or (begin == 0 and end == 0)) return;
        return error.InvalidPreeditCursor;
    };
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    if (begin == -1 or end == -1) {
        if (begin == -1 and end == -1) return;
        return error.InvalidPreeditCursor;
    }
    if (begin < 0 or end < 0) return error.InvalidPreeditCursor;
    if (!utf8Boundary(bytes, @intCast(begin)) or !utf8Boundary(bytes, @intCast(end)))
        return error.InvalidPreeditCursor;
}

fn utf8Boundary(text: []const u8, offset: usize) bool {
    if (offset > text.len) return false;
    return offset == text.len or (text[offset] & 0xc0) != 0x80;
}

fn sameHandle(a: platform.WindowHandle, b: platform.WindowHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

const TestSink = struct {
    expected_window: platform.WindowHandle,
    calls: usize = 0,

    fn interface(self: *TestSink) platform.EventSink {
        return .{ .context = self, .vtable = &vtable };
    }

    fn textInput(context: *anyopaque, event: platform.TextInputEvent) !void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        const batch = event.batch;
        try std.testing.expectEqual(self.expected_window, batch.window);
        try std.testing.expectEqual(@as(u32, 7), batch.serial);
        try std.testing.expect(!batch.serial_matches_state);
        try std.testing.expectEqual(@as(u32, 3), batch.delete_surrounding.?.before_bytes);
        try std.testing.expectEqual(@as(u32, 2), batch.delete_surrounding.?.after_bytes);
        try std.testing.expectEqualStrings("é", batch.commit.?.text.?);
        try std.testing.expectEqualStrings("候補", batch.preedit.?.text.?);
        try std.testing.expectEqual(@as(i32, 0), batch.preedit.?.cursor_begin);
        try std.testing.expectEqual(@as(i32, "候補".len), batch.preedit.?.cursor_end);
        self.calls += 1;
    }

    fn closeRequested(_: *anyopaque, _: platform.WindowHandle) !void {}
    fn configured(_: *anyopaque, _: platform.WindowHandle, _: u32, _: u32) !void {}
    fn pointer(_: *anyopaque, _: platform.PointerEvent) !void {}
    fn keyboard(_: *anyopaque, _: platform.KeyboardEvent) !void {}
    fn closed(_: *anyopaque, _: platform.WindowHandle) !void {}

    const vtable: platform.EventSink.VTable = .{
        .close_requested = closeRequested,
        .configured = configured,
        .pointer = pointer,
        .keyboard = keyboard,
        .text_input = textInput,
        .closed = closed,
    };
};

test "text input fragments become one copied done batch" {
    const window: platform.WindowHandle = .{ .slot = 2, .generation = 4 };
    var pending = Pending.init(std.testing.allocator);
    defer pending.deinit();
    pending.enter(window);
    pending.noteCommit();
    try pending.setCommit("discarded");
    try pending.setCommit("é");
    pending.setDelete(3, 2);
    try pending.setPreedit("候補", 0, "候補".len);
    var sink: TestSink = .{ .expected_window = window };
    try pending.finishDone(7, sink.interface());
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqual(@as(usize, 0), pending.commit_bytes.items.len);
    try std.testing.expectEqual(@as(usize, 0), pending.preedit_bytes.items.len);
}

test "preedit cursors must be UTF-8 byte boundaries" {
    var pending = Pending.init(std.testing.allocator);
    defer pending.deinit();
    try std.testing.expectError(error.InvalidPreeditCursor, pending.setPreedit("é", 1, 2));
    try std.testing.expectError(error.InvalidPreeditCursor, pending.setPreedit("text", -1, 0));
    try pending.setPreedit("text", -1, -1);
}
