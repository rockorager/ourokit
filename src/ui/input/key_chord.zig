const std = @import("std");
const platform = @import("../../platform/window.zig");

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
        const spelling = comptime if (std.mem.startsWith(u8, field.name, "key_")) field.name[4..] else if (std.mem.startsWith(u8, field.name, "digit_")) field.name[6..] else switch (@as(platform.LogicalKey, @enumFromInt(field.value))) {
            .unidentified => "",
            .arrow_left => "Left",
            .arrow_right => "Right",
            .arrow_up => "Up",
            .arrow_down => "Down",
            .page_up => "PageUp",
            .page_down => "PageDown",
            else => field.name,
        };
        if (spelling.len != 0 and std.ascii.eqlIgnoreCase(name, spelling)) return @enumFromInt(field.value);
    }
    return error.InvalidKeyChord;
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
    for ([_][]const u8{ "", "Ctrl+", "Ctrl+Ctrl+A", "Ctrl++A", "Meta+A", "Unknown", "F13" }) |invalid|
        try std.testing.expectError(error.InvalidKeyChord, KeyChord.parse(invalid));
}
