const std = @import("std");
const platform = @import("../../platform/window.zig");

/// A bounded sequence of logical chords. Whitespace separates strokes.
pub const Sequence = struct {
    strokes: [4]KeyChord = @splat(.{}),
    len: u8 = 0,

    pub fn parse(raw: []const u8) !Sequence {
        var result: Sequence = .{};
        var parts = std.mem.tokenizeAny(u8, raw, " \t\r\n");
        while (parts.next()) |part| {
            if (result.len == result.strokes.len) return error.KeySequenceTooLong;
            result.strokes[result.len] = try KeyChord.parse(part);
            result.len += 1;
        }
        if (result.len == 0) return error.InvalidKeyChord;
        return result;
    }

    pub fn overlaps(a: Sequence, b: Sequence) bool {
        for (0..@min(a.len, b.len)) |i|
            if (!std.meta.eql(a.strokes[i], b.strokes[i])) return false;
        return true;
    }
};

/// Exact logical key/modifier match, independent of physical keyboard layout.
pub const KeyChord = struct {
    key: platform.LogicalKey = .unidentified,
    modifiers: platform.Modifiers = .{},

    pub fn matches(self: KeyChord, key: platform.TranslatedKey) bool {
        return self.key == key.logical and std.meta.eql(self.modifiers, key.modifiers);
    }

    pub fn parse(raw: []const u8) !KeyChord {
        var result: KeyChord = .{};
        var parts = std.mem.splitScalar(u8, raw, '+');
        while (parts.next()) |part| {
            if (parts.peek() == null) {
                result.key = try parseKey(part);
                return result;
            }
            const field = if (std.ascii.eqlIgnoreCase(part, "Ctrl")) "control" else if (std.ascii.eqlIgnoreCase(part, "Shift")) "shift" else if (std.ascii.eqlIgnoreCase(part, "Alt")) "alt" else if (std.ascii.eqlIgnoreCase(part, "Super")) "logo" else return error.InvalidKeyChord;
            inline for (std.meta.fields(platform.Modifiers)) |modifier| {
                if (std.mem.eql(u8, field, modifier.name)) {
                    if (@field(result.modifiers, modifier.name)) return error.InvalidKeyChord;
                    @field(result.modifiers, modifier.name) = true;
                }
            }
        }
        return error.InvalidKeyChord;
    }
};

fn parseKey(name: []const u8) !platform.LogicalKey {
    inline for (std.meta.fields(platform.LogicalKey)) |field| {
        const spelling = comptime keyName(@enumFromInt(field.value));
        if (spelling.len != 0 and std.ascii.eqlIgnoreCase(name, spelling)) return @enumFromInt(field.value);
    }
    return error.InvalidKeyChord;
}

pub fn keyName(key: platform.LogicalKey) []const u8 {
    @setEvalBranchQuota(10000);
    return switch (key) {
        .unidentified => "",
        .tab => "Tab",
        .enter => "Enter",
        .space => "Space",
        .escape => "Escape",
        .home => "Home",
        .end => "End",
        .backspace => "Backspace",
        .delete => "Delete",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .page_up => "PageUp",
        .page_down => "PageDown",
        else => blk: {
            inline for (std.meta.fields(platform.LogicalKey)) |field| {
                if (key == @as(platform.LogicalKey, @enumFromInt(field.value))) {
                    const upper = comptime upper: {
                        const raw = if (std.mem.startsWith(u8, field.name, "key_")) field.name[4..] else if (std.mem.startsWith(u8, field.name, "digit_")) field.name[6..] else field.name;
                        var buffer: [raw.len]u8 = undefined;
                        _ = std.ascii.upperString(&buffer, raw);
                        break :upper buffer;
                    };
                    break :blk &upper;
                }
            }
            unreachable;
        },
    };
}

test "key chords normalize names and modifier order but match modifiers exactly" {
    const chord = try KeyChord.parse("shift+CTRL+r");
    try std.testing.expectEqual(KeyChord{ .key = .key_r, .modifiers = .{ .shift = true, .control = true } }, chord);
    try std.testing.expect(chord.matches(.{ .keycode = 19, .logical = .key_r, .modifiers = .{ .control = true, .shift = true }, .unicode = 18 }));
    try std.testing.expect(!chord.matches(.{ .keycode = 19, .logical = .key_r, .modifiers = .{ .control = true } }));
    try std.testing.expect(!chord.matches(.{ .keycode = 19, .logical = .key_r, .modifiers = .{ .control = true, .shift = true, .alt = true } }));
    try std.testing.expectEqual(platform.LogicalKey.page_down, (try KeyChord.parse("Alt+PageDown")).key);
    try std.testing.expectEqual(platform.LogicalKey.f12, (try KeyChord.parse("Super+F12")).key);
    try std.testing.expectEqual(platform.LogicalKey.digit_9, (try KeyChord.parse("9")).key);
    try std.testing.expectEqual(platform.LogicalKey.equal, (try KeyChord.parse("Ctrl+Equal")).key);
    try std.testing.expectEqual(platform.LogicalKey.minus, (try KeyChord.parse("Ctrl+Minus")).key);
    const plus = try KeyChord.parse("Ctrl+Shift+Plus");
    try std.testing.expect(plus.matches(.{ .keycode = 13, .logical = .plus, .modifiers = .{ .control = true, .shift = true } }));
    try std.testing.expect(!plus.matches(.{ .keycode = 13, .logical = .plus, .modifiers = .{ .shift = true } }));
    for ([_][]const u8{ "", "Ctrl+", "Ctrl+Ctrl+A", "Ctrl++A", "Meta+A", "Unknown", "F13" }) |invalid|
        try std.testing.expectError(error.InvalidKeyChord, KeyChord.parse(invalid));
}

test "contextual input sequences distinguish shared prefixes from ambiguous completion" {
    const short = try Sequence.parse("Ctrl+K");
    const first = try Sequence.parse(" ctrl+k\tCtrl+C ");
    const second = try Sequence.parse("Ctrl+K Ctrl+U");
    try std.testing.expect(short.overlaps(first));
    try std.testing.expect(first.overlaps(short));
    try std.testing.expect(!first.overlaps(second));
    try std.testing.expect(first.overlaps(try Sequence.parse("CTRL+K ctrl+c")));
    try std.testing.expectEqual(@as(u8, 4), (try Sequence.parse("A B C D")).len);
    try std.testing.expectError(error.KeySequenceTooLong, Sequence.parse("A B C D E"));
    try std.testing.expectError(error.InvalidKeyChord, Sequence.parse(" \t "));
    try std.testing.expectError(error.InvalidKeyChord, Sequence.parse("Ctrl+K Ctrl+"));
}
