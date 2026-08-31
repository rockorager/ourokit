const std = @import("std");
const uucode = @import("uucode");
const model_module = @import("model.zig");
const Session = @import("session.zig").Session;

/// One owned, immutable text-input presentation snapshot. IME preedit remains
/// separate from the committed Model, but is inserted here before shaping so
/// it participates in bidi resolution, fallback, and line breaking exactly as
/// visible text does.
pub const Presentation = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    selection: model_module.Range,
    caret_offset: usize,
    caret_affinity: @import("../../text/positioned_lines.zig").CaretAffinity,
    show_caret: bool,
    preedit: ?model_module.Range,

    pub fn deinit(self: *Presentation) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn build(allocator: std.mem.Allocator, session: *const Session) !Presentation {
    const committed = session.model.text();
    const preedit = session.preedit() orelse {
        const selection = session.model.selection;
        return .{
            .allocator = allocator,
            .text = try allocator.dupe(u8, committed),
            .selection = selection.range(),
            .caret_offset = selection.extent,
            .caret_affinity = selection.affinity,
            .show_caret = selection.isCollapsed(),
            .preedit = null,
        };
    };

    const length = std.math.add(usize, committed.len, preedit.text.len) catch
        return error.OutOfMemory;
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..preedit.anchor], committed[0..preedit.anchor]);
    @memcpy(bytes[preedit.anchor..][0..preedit.text.len], preedit.text);
    @memcpy(bytes[preedit.anchor + preedit.text.len ..], committed[preedit.anchor..]);

    const raw_preedit: model_module.Range = .{
        .start = preedit.anchor,
        .end = preedit.anchor + preedit.text.len,
    };
    const visual_preedit = graphemeRange(bytes, raw_preedit);
    const cursor = if (preedit.cursor) |value|
        graphemeRange(bytes, .{
            .start = preedit.anchor + value.start,
            .end = preedit.anchor + value.end,
        })
    else
        model_module.Range{ .start = visual_preedit.end, .end = visual_preedit.end };

    return .{
        .allocator = allocator,
        .text = bytes,
        .selection = cursor,
        .caret_offset = cursor.end,
        .caret_affinity = .downstream,
        .show_caret = preedit.cursor != null and cursor.start == cursor.end,
        .preedit = visual_preedit,
    };
}

/// Expand protocol code-point offsets to complete extended graphemes. This is
/// required at composition seams too: a combining-mark preedit can join the
/// adjacent committed base character into one visible cluster.
fn graphemeRange(text: []const u8, raw: model_module.Range) model_module.Range {
    var start: usize = 0;
    var end: usize = text.len;
    var iterator = uucode.grapheme.utf8Iterator(text);
    while (iterator.nextGrapheme()) |grapheme| {
        if (raw.start >= grapheme.start and raw.start <= grapheme.end) start = if (raw.start == grapheme.end)
            grapheme.end
        else
            grapheme.start;
        if (raw.end >= grapheme.start and raw.end <= grapheme.end) {
            end = if (raw.end == grapheme.start) grapheme.start else grapheme.end;
            break;
        }
    }
    return .{ .start = start, .end = @max(start, end) };
}

test "committed presentation preserves directional selection and affinity" {
    var session = try Session.init(std.testing.allocator, "abc אבג");
    defer session.deinit();
    _ = try session.model.setSelection(.{
        .anchor = session.model.text().len,
        .extent = 4,
        .affinity = .upstream,
    });
    var result = try build(std.testing.allocator, &session);
    defer result.deinit();
    try std.testing.expectEqualStrings(session.model.text(), result.text);
    try std.testing.expectEqual(model_module.Range{ .start = 4, .end = session.model.text().len }, result.selection);
    try std.testing.expectEqual(@as(usize, 4), result.caret_offset);
    try std.testing.expectEqual(.upstream, result.caret_affinity);
    try std.testing.expect(!result.show_caret);
    try std.testing.expect(result.preedit == null);
}

test "preedit is shaped in context and code-point cursor expands to graphemes" {
    var session = try Session.init(std.testing.allocator, "AZ");
    defer session.deinit();
    _ = try session.model.setSelection(.collapsed(1));
    try std.testing.expect(try session.apply(.{ .preedit = .{
        .text = "e\u{301}",
        .cursor = .{ .start = 1, .end = 1 },
    } }));

    var result = try build(std.testing.allocator, &session);
    defer result.deinit();
    try std.testing.expectEqualStrings("Ae\u{301}Z", result.text);
    try std.testing.expectEqual(model_module.Range{ .start = 1, .end = 4 }, result.preedit.?);
    try std.testing.expectEqual(model_module.Range{ .start = 1, .end = 4 }, result.selection);
    try std.testing.expect(!result.show_caret);
    try std.testing.expectEqualStrings("AZ", session.model.text());
}

test "combining preedit expands its underline across the composition seam" {
    var session = try Session.init(std.testing.allocator, "AZ");
    defer session.deinit();
    _ = try session.model.setSelection(.collapsed(1));
    try std.testing.expect(try session.apply(.{ .preedit = .{
        .text = "\u{301}",
        .cursor = .{ .start = "\u{301}".len, .end = "\u{301}".len },
    } }));

    var result = try build(std.testing.allocator, &session);
    defer result.deinit();
    try std.testing.expectEqualStrings("A\u{301}Z", result.text);
    try std.testing.expectEqual(model_module.Range{ .start = 0, .end = 3 }, result.preedit.?);
    try std.testing.expectEqual(model_module.Range{ .start = 3, .end = 3 }, result.selection);
    try std.testing.expect(result.show_caret);
}
