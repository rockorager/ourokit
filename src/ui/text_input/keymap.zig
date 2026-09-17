const std = @import("std");
const platform = @import("../../platform/window.zig");
const intent = @import("intent.zig");
pub const KeyChord = @import("../input/key_chord.zig").KeyChord;

pub const Command = enum { submit, cancel, previous, next };
pub const Clipboard = enum { copy, cut, paste };
pub const Action = union(enum) {
    none,
    edit: intent.Intent,
    clipboard: Clipboard,
    command: Command,

    pub fn parse(name: []const u8) !Action {
        if (std.meta.stringToEnum(Command, name)) |value| return .{ .command = value };
        if (std.meta.stringToEnum(Clipboard, name)) |value| return .{ .clipboard = value };
        inline for (std.meta.fields(intent.Intent)) |field| {
            if (comptime !std.mem.eql(u8, field.name, "move")) {
                if (std.mem.eql(u8, name, field.name)) return .{ .edit = @unionInit(intent.Intent, field.name, {}) };
            }
        }
        const extend = std.mem.startsWith(u8, name, "select_");
        if (extend or std.mem.startsWith(u8, name, "move_")) {
            const destination = std.meta.stringToEnum(intent.Destination, name[if (extend) @as(usize, 7) else 5..]) orelse return error.InvalidTextInputAction;
            return .{ .edit = .{ .move = .{ .destination = destination, .extend = extend } } };
        }
        return error.InvalidTextInputAction;
    }

    pub fn repeats(self: Action) bool {
        return switch (self) {
            .edit => true,
            .command => |command| command == .previous or command == .next,
            .clipboard, .none => false,
        };
    }
};

pub const Binding = struct {
    chord: KeyChord = .{},
    action: Action = .none,
};

/// Native-owned overrides; copying a declaration never retains Lua storage.
/// Defaults are fallback data, not special cases in event dispatch.
pub const Keymap = struct {
    inherit_defaults: bool = true,
    bindings: [64]Binding = @splat(.{}),
    len: usize = 0,

    pub fn set(self: *Keymap, chord: KeyChord, action: Action) !void {
        for (self.bindings[0..self.len]) |*entry| {
            if (std.meta.eql(entry.chord, chord)) {
                entry.action = action;
                return;
            }
        }
        if (self.len == self.bindings.len) return error.KeyBindingCapacityExceeded;
        self.bindings[self.len] = .{ .chord = chord, .action = action };
        self.len += 1;
    }

    pub fn resolve(self: *const Keymap, key: platform.TranslatedKey) ?Action {
        for (self.bindings[0..self.len]) |entry|
            if (entry.chord.matches(key)) return entry.action;
        if (self.inherit_defaults) for (defaults) |entry|
            if (entry.chord.matches(key)) return entry.action;
        return null;
    }
};

pub const defaults = blk: {
    @setEvalBranchQuota(100000);
    const definitions = .{
        .{ "Ctrl+A", "select_all" },
        .{ "Ctrl+Z", "undo" },
        .{ "Ctrl+Shift+Z", "redo" },
        .{ "Ctrl+Y", "redo" },
        .{ "Ctrl+C", "copy" },
        .{ "Ctrl+X", "cut" },
        .{ "Ctrl+V", "paste" },
        .{ "Backspace", "delete_backward" },
        .{ "Delete", "delete_forward" },
        .{ "Ctrl+Backspace", "delete_word_backward" },
        .{ "Ctrl+Delete", "delete_word_forward" },
        .{ "Left", "move_visual_left" },
        .{ "Right", "move_visual_right" },
        .{ "Up", "previous" },
        .{ "Down", "next" },
        .{ "Home", "move_line_start" },
        .{ "End", "move_line_end" },
        .{ "Ctrl+Left", "move_word_previous" },
        .{ "Ctrl+Right", "move_word_next" },
        .{ "Shift+Left", "select_visual_left" },
        .{ "Shift+Right", "select_visual_right" },
        .{ "Shift+Up", "select_line_up" },
        .{ "Shift+Down", "select_line_down" },
        .{ "Shift+Home", "select_line_start" },
        .{ "Shift+End", "select_line_end" },
        .{ "Ctrl+Shift+Left", "select_word_previous" },
        .{ "Ctrl+Shift+Right", "select_word_next" },
        .{ "Enter", "submit" },
        .{ "Escape", "cancel" },
        // Preserve the existing Shift-insensitive non-navigation defaults.
        .{ "Ctrl+Shift+A", "select_all" },
        .{ "Ctrl+Shift+Y", "redo" },
        .{ "Ctrl+Shift+C", "copy" },
        .{ "Ctrl+Shift+X", "cut" },
        .{ "Ctrl+Shift+V", "paste" },
        .{ "Shift+Backspace", "delete_backward" },
        .{ "Shift+Delete", "delete_forward" },
        .{ "Ctrl+Shift+Backspace", "delete_word_backward" },
        .{ "Ctrl+Shift+Delete", "delete_word_forward" },
    };
    var result: [definitions.len]Binding = undefined;
    for (definitions, 0..) |definition, i| {
        result[i] = .{
            .chord = KeyChord.parse(definition[0]) catch unreachable,
            .action = Action.parse(definition[1]) catch unreachable,
        };
    }
    break :blk result;
};

test "text input bindings replace defaults disable exact chords and start empty" {
    var map: Keymap = .{};
    const key: platform.TranslatedKey = .{ .keycode = 44, .logical = .key_z, .modifiers = .{ .control = true } };
    try std.testing.expectEqual(Action{ .edit = .undo }, map.resolve(key).?);
    try map.set(try KeyChord.parse("Ctrl+Z"), .none);
    try std.testing.expectEqual(Action.none, map.resolve(key).?);
    try map.set(try KeyChord.parse("Ctrl+Z"), .{ .edit = .redo });
    try std.testing.expectEqual(Action{ .edit = .redo }, map.resolve(key).?);
    try std.testing.expectEqual(@as(usize, 1), map.len);
    map = .{ .inherit_defaults = false };
    try std.testing.expect(map.resolve(key) == null);
    try map.set(try KeyChord.parse("Alt+R"), .{ .edit = .redo });
    try std.testing.expectEqual(Action{ .edit = .redo }, map.resolve(.{ .keycode = 19, .logical = .key_r, .modifiers = .{ .alt = true } }).?);
    try std.testing.expect(map.resolve(.{ .keycode = 19, .logical = .key_r, .modifiers = .{ .alt = true, .shift = true } }) == null);
    try std.testing.expectError(error.InvalidTextInputAction, Action.parse("select_unknown"));
    try std.testing.expectError(error.InvalidTextInputAction, Action.parse("move"));
    try std.testing.expect(!(try Action.parse("submit")).repeats());
    try std.testing.expect(!(try Action.parse("paste")).repeats());
    try std.testing.expect((try Action.parse("previous")).repeats());
    try std.testing.expect((try Action.parse("delete_backward")).repeats());
}

test "default text input bindings preserve editing selection clipboard and commands" {
    const map: Keymap = .{};
    const Case = struct { key: platform.LogicalKey, modifiers: platform.Modifiers = .{}, action: Action };
    for ([_]Case{
        .{ .key = .key_z, .modifiers = .{ .control = true }, .action = .{ .edit = .undo } },
        .{ .key = .key_z, .modifiers = .{ .control = true, .shift = true }, .action = .{ .edit = .redo } },
        .{ .key = .key_y, .modifiers = .{ .control = true }, .action = .{ .edit = .redo } },
        .{ .key = .key_a, .modifiers = .{ .control = true }, .action = .{ .edit = .select_all } },
        .{ .key = .key_c, .modifiers = .{ .control = true }, .action = .{ .clipboard = .copy } },
        .{ .key = .home, .action = .{ .edit = .{ .move = .{ .destination = .line_start } } } },
        .{ .key = .arrow_left, .modifiers = .{ .control = true }, .action = .{ .edit = .{ .move = .{ .destination = .word_previous } } } },
        .{ .key = .arrow_up, .modifiers = .{ .shift = true }, .action = .{ .edit = .{ .move = .{ .destination = .line_up, .extend = true } } } },
        .{ .key = .backspace, .modifiers = .{ .control = true, .shift = true }, .action = .{ .edit = .delete_word_backward } },
        .{ .key = .enter, .action = .{ .command = .submit } },
        .{ .key = .arrow_up, .action = .{ .command = .previous } },
    }) |case| try std.testing.expectEqual(case.action, map.resolve(.{ .keycode = 0, .logical = case.key, .modifiers = case.modifiers }).?);
    try std.testing.expect(map.resolve(.{ .keycode = 0, .logical = .key_z }) == null);
    try std.testing.expect(map.resolve(.{ .keycode = 0, .logical = .key_v, .modifiers = .{ .control = true, .alt = true } }) == null);
    try std.testing.expect(map.resolve(.{ .keycode = 0, .logical = .enter, .modifiers = .{ .shift = true } }) == null);
}

test "full keymaps still allow replacing existing bindings" {
    var map: Keymap = .{};
    const keys = [_]platform.LogicalKey{ .key_a, .key_b, .key_c, .key_d };
    for (0..64) |i| try map.set(.{ .key = keys[i / 16], .modifiers = @bitCast(@as(u4, @intCast(i % 16))) }, .none);
    try std.testing.expectEqual(@as(usize, 64), map.len);
    try std.testing.expectError(error.KeyBindingCapacityExceeded, map.set(.{ .key = .key_e }, .{ .edit = .undo }));
    try map.set(.{ .key = .key_d }, .{ .edit = .redo });
    try std.testing.expectEqual(Action{ .edit = .redo }, map.resolve(.{ .keycode = 0, .logical = .key_d }).?);
    try std.testing.expectEqual(@as(usize, 64), map.len);
}
