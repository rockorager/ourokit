const platform = @import("../platform/window.zig");
const ui = @import("../ui/root.zig");

const max_surrounding_bytes = 4000;

/// Translates platform-owned text data into the language-neutral editing
/// transaction consumed by a retained session. This coordinator is the only
/// layer that knows both contracts; the UI model does not depend on Wayland or
/// platform event types.
pub fn editBatch(batch: platform.TextInputBatch) !ui.text_input.EditBatch {
    return .{
        .delete_surrounding = if (batch.delete_surrounding) |deletion| .{
            .before_bytes = deletion.before_bytes,
            .after_bytes = deletion.after_bytes,
        } else null,
        .commit = if (batch.commit) |commit| .{ .text = commit.text } else null,
        .preedit = if (batch.preedit) |preedit| .{
            .text = preedit.text,
            .cursor = try preeditCursor(preedit),
        } else null,
    };
}

/// Produces a protocol-valid bounded view around the complete selection. Long
/// documents do not force a copy; when a selection itself exceeds Wayland's
/// 4000-byte limit, surrounding support is omitted for that transaction.
pub fn surroundingState(session: *const ui.text_input.Session) platform.TextInputState {
    const surrounding = session.surrounding();
    const selection_start = @min(surrounding.cursor, surrounding.anchor);
    const selection_end = @max(surrounding.cursor, surrounding.anchor);
    const selection_len = selection_end - selection_start;
    if (selection_len > max_surrounding_bytes) return .{};

    var start: usize = 0;
    var end = surrounding.text.len;
    if (surrounding.text.len > max_surrounding_bytes) {
        const spare = max_surrounding_bytes - selection_len;
        const before = @min(selection_start, spare / 2);
        start = selection_start - before;
        end = @min(surrounding.text.len, start + max_surrounding_bytes);
        if (end - start < max_surrounding_bytes)
            start = end - max_surrounding_bytes;
        while (start < selection_start and !utf8Boundary(surrounding.text, start)) start += 1;
        while (end > selection_end and !utf8Boundary(surrounding.text, end)) end -= 1;
    }
    return .{ .surrounding = .{
        .text = surrounding.text[start..end],
        .cursor = surrounding.cursor - start,
        .anchor = surrounding.anchor - start,
    } };
}

fn preeditCursor(preedit: anytype) !?ui.text_input.Range {
    if (preedit.cursor_begin == -1 and preedit.cursor_end == -1) return null;
    if (preedit.cursor_begin < 0 or preedit.cursor_end < 0) return error.InvalidPreeditCursor;
    const begin: usize = @intCast(preedit.cursor_begin);
    const end: usize = @intCast(preedit.cursor_end);
    return .{ .start = @min(begin, end), .end = @max(begin, end) };
}

fn utf8Boundary(text: []const u8, offset: usize) bool {
    if (offset > text.len) return false;
    return offset == text.len or (text[offset] & 0xc0) != 0x80;
}

test "platform batches retain presence and normalize preedit selection" {
    const batch = try editBatch(.{
        .window = .{ .slot = 1, .generation = 1 },
        .serial = 2,
        .serial_matches_state = true,
        .delete_surrounding = .{ .before_bytes = 0, .after_bytes = 0 },
        .commit = .{ .text = "é" },
        .preedit = .{ .text = "候補", .cursor_begin = 6, .cursor_end = 0 },
    });
    try @import("std").testing.expect(batch.delete_surrounding != null);
    try @import("std").testing.expectEqualStrings("é", batch.commit.?.text.?);
    try @import("std").testing.expectEqual(
        ui.text_input.Range{ .start = 0, .end = 6 },
        batch.preedit.?.cursor.?,
    );
}

test "surrounding state is bounded and keeps complete UTF-8 selection" {
    const std = @import("std");
    const text = ("é" ** 2500) ++ " selected " ++ ("z" ** 2500);
    var session = try ui.text_input.Session.init(std.testing.allocator, text);
    defer session.deinit();
    const selected_start = ("é" ** 2500).len;
    const selected_end = selected_start + " selected ".len;
    _ = try session.model.setSelection(.{ .anchor = selected_start, .extent = selected_end });
    const state = surroundingState(&session);
    const surrounding = state.surrounding.?;
    try std.testing.expect(surrounding.text.len <= max_surrounding_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(surrounding.text));
    try std.testing.expectEqualStrings(
        " selected ",
        surrounding.text[surrounding.anchor..surrounding.cursor],
    );
    try state.validate();
}
