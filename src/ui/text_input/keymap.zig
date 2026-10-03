const std = @import("std");
const platform = @import("../../platform/window.zig");
const intent = @import("intent.zig");
pub const KeyChord = @import("../input/key_chord.zig").KeyChord;
pub const Sequence = @import("../input/key_chord.zig").Sequence;

pub const Command = enum { submit, cancel, previous, next };
pub const Clipboard = enum { copy, cut, paste };
pub const Register = enum { yank, yank_lines, put_after, put_before };
pub const Action = union(enum) {
    none,
    edit: intent.Intent,
    clipboard: Clipboard,
    register: Register,
    command: Command,

    pub fn parse(name: []const u8) !Action {
        if (std.meta.stringToEnum(Command, name)) |value| return .{ .command = value };
        if (std.meta.stringToEnum(Clipboard, name)) |value| return .{ .clipboard = value };
        if (std.meta.stringToEnum(Register, name)) |value| return .{ .register = value };
        inline for (std.meta.fields(intent.Intent)) |field| {
            if (comptime field.type == void) {
                if (std.mem.eql(u8, name, field.name)) return .{ .edit = @unionInit(intent.Intent, field.name, {}) };
            }
        }
        if (std.mem.startsWith(u8, name, "select_lines_")) return .{ .edit = .{
            .select_lines = std.meta.stringToEnum(intent.LineDestination, name[13..]) orelse return error.InvalidTextInputAction,
        } };
        inline for (.{ "move_normal", "select_inclusive" }) |prefix| {
            if (std.mem.startsWith(u8, name, prefix ++ "_")) return .{ .edit = @unionInit(intent.Intent, prefix, std.meta.stringToEnum(intent.Destination, name[prefix.len + 1 ..]) orelse return error.InvalidTextInputAction) };
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
            .register => |command| command == .put_after or command == .put_before,
            .clipboard, .none => false,
        };
    }
};

pub const Binding = struct {
    chord: KeyChord = .{},
    action: Action = .none,
};

/// A command or asynchronous paste must finish the recipe; later operations
/// must never race its callback/completion.
pub const Actions = struct {
    items: [5]Action = @splat(.none),
    len: u8 = 1,

    pub fn single(action: Action) Actions {
        var result: Actions = .{};
        result.items[0] = action;
        return result;
    }

    pub fn repeats(self: Actions) bool {
        if (self.len == 1) return self.items[0].repeats();
        if (self.len == 2 and self.items[1] == .edit and self.items[1].edit == .normalize_caret)
            return self.items[0].repeats();
        // Only synchronous character-delete recipes opt into repetition.
        // Mode changes, paste, undo groups and multi-key prefixes must not.
        if (self.items[0] != .edit or
            (self.items[0].edit != .select_character_forward and self.items[0].edit != .select_character_backward)) return false;
        for (self.items[1..self.len]) |action| switch (action) {
            .edit => |edit| if (edit != .delete_selection and edit != .normalize_caret) return false,
            .register => |command| if (command != .yank) return false,
            else => return false,
        };
        return true;
    }

    pub fn validate(self: Actions) !void {
        if (self.len == 0 or self.len > self.items.len) return error.InvalidTextInputActions;
        for (self.items[0 .. self.len - 1]) |action| {
            if (action == .command or (action == .clipboard and action.clipboard == .paste))
                return error.InvalidTextInputActions;
        }
    }
};

pub const SequenceBinding = struct {
    sequence: Sequence = .{},
    actions: Actions = .{},
};

pub const Match = union(enum) { pending, actions: Actions };

/// Native-owned overrides; copying a declaration never retains Lua storage.
/// Defaults are fallback data, not special cases in event dispatch.
pub const Keymap = struct {
    inherit_defaults: bool = true,
    multiline: bool = false,
    bindings: [128]SequenceBinding = @splat(.{}),
    len: usize = 0,

    pub fn set(self: *Keymap, chord: KeyChord, action: Action) !void {
        var sequence: Sequence = .{ .len = 1 };
        sequence.strokes[0] = chord;
        return self.setSequence(sequence, Actions.single(action));
    }

    pub fn setSequence(self: *Keymap, sequence: Sequence, actions: Actions) !void {
        try actions.validate();
        for (self.bindings[0..self.len]) |*entry| {
            if (!entry.sequence.overlaps(sequence)) continue;
            if (entry.sequence.len == sequence.len) {
                entry.actions = actions;
                return;
            }
            return error.AmbiguousKeyBinding;
        }
        if (self.len == self.bindings.len) return error.KeyBindingCapacityExceeded;
        self.bindings[self.len] = .{ .sequence = sequence, .actions = actions };
        self.len += 1;
    }

    pub fn match(self: *const Keymap, prefix: Sequence) ?Match {
        for (self.bindings[0..self.len]) |entry| {
            if (entry.sequence.len < prefix.len or !entry.sequence.overlaps(prefix)) continue;
            return if (entry.sequence.len == prefix.len) .{ .actions = entry.actions } else .pending;
        }
        if (prefix.len != 1) return null;
        const stroke = prefix.strokes[0];
        const actions = self.resolve(.{ .keycode = 0, .logical = stroke.key, .modifiers = stroke.modifiers }) orelse return null;
        return .{ .actions = actions };
    }

    pub fn resolve(self: *const Keymap, key: platform.TranslatedKey) ?Actions {
        for (self.bindings[0..self.len]) |entry|
            if (entry.sequence.len == 1 and entry.sequence.strokes[0].matches(key)) return entry.actions;
        if (self.inherit_defaults and self.multiline) for (multiline_defaults) |entry|
            if (entry.chord.matches(key)) return Actions.single(entry.action);
        if (self.inherit_defaults) for (defaults) |entry|
            if (entry.chord.matches(key)) return Actions.single(entry.action);
        return null;
    }
};

const multiline_defaults = blk: {
    @setEvalBranchQuota(100000);
    const definitions = .{
        .{ "Enter", "insert_newline" },
        .{ "Shift+Enter", "insert_newline" },
        .{ "Up", "move_line_up" },
        .{ "Down", "move_line_down" },
        .{ "Ctrl+Home", "move_document_start" },
        .{ "Ctrl+End", "move_document_end" },
        .{ "Ctrl+Shift+Home", "select_document_start" },
        .{ "Ctrl+Shift+End", "select_document_end" },
    };
    var result: [definitions.len]Binding = undefined;
    for (definitions, 0..) |definition, i| result[i] = .{
        .chord = KeyChord.parse(definition[0]) catch unreachable,
        .action = Action.parse(definition[1]) catch unreachable,
    };
    break :blk result;
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
    try std.testing.expectEqual(Action{ .edit = .undo }, map.resolve(key).?.items[0]);
    try map.set(try KeyChord.parse("Ctrl+Z"), .none);
    try std.testing.expectEqual(Action.none, map.resolve(key).?.items[0]);
    try map.set(try KeyChord.parse("Ctrl+Z"), .{ .edit = .redo });
    try std.testing.expectEqual(Action{ .edit = .redo }, map.resolve(key).?.items[0]);
    try std.testing.expectEqual(@as(usize, 1), map.len);
    map = .{ .inherit_defaults = false };
    try std.testing.expect(map.resolve(key) == null);
    try map.set(try KeyChord.parse("Alt+R"), .{ .edit = .redo });
    try std.testing.expectEqual(Action{ .edit = .redo }, map.resolve(.{ .keycode = 19, .logical = .key_r, .modifiers = .{ .alt = true } }).?.items[0]);
    try std.testing.expect(map.resolve(.{ .keycode = 19, .logical = .key_r, .modifiers = .{ .alt = true, .shift = true } }) == null);
    try std.testing.expectError(error.InvalidTextInputAction, Action.parse("select_unknown"));
    try std.testing.expectError(error.InvalidTextInputAction, Action.parse("move"));
    try std.testing.expect(!(try Action.parse("submit")).repeats());
    try std.testing.expect(!(try Action.parse("paste")).repeats());
    try std.testing.expect((try Action.parse("previous")).repeats());
    try std.testing.expect((try Action.parse("delete_backward")).repeats());
}

test "character delete recipes repeat without repeating mode changes or asynchronous operations" {
    var actions: Actions = .{ .len = 4 };
    inline for (.{ "select_character_forward", "yank", "delete_selection", "normalize_caret" }, 0..) |name, i|
        actions.items[i] = try Action.parse(name);
    try std.testing.expect(actions.repeats());
    actions.items[0] = try Action.parse("select_character_backward");
    try std.testing.expect(actions.repeats());
    actions.items[3] = try Action.parse("submit");
    try std.testing.expect(!actions.repeats());
    actions.items[3] = try Action.parse("paste");
    try std.testing.expect(!actions.repeats());
    actions.items[3] = try Action.parse("begin_undo_group");
    try std.testing.expect(!actions.repeats());
    actions = .{ .len = 2 };
    actions.items[0] = try Action.parse("undo");
    actions.items[1] = try Action.parse("normalize_caret");
    try std.testing.expect(actions.repeats());
    try std.testing.expectEqual(Action{ .edit = .{ .move_normal = .logical_line_end } }, try Action.parse("move_normal_logical_line_end"));
    try std.testing.expectEqual(Action{ .edit = .{ .select_inclusive = .visual_left } }, try Action.parse("select_inclusive_visual_left"));
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
    }) |case| try std.testing.expectEqual(case.action, map.resolve(.{ .keycode = 0, .logical = case.key, .modifiers = case.modifiers }).?.items[0]);
    try std.testing.expect(map.resolve(.{ .keycode = 0, .logical = .key_z }) == null);
    try std.testing.expect(map.resolve(.{ .keycode = 0, .logical = .key_v, .modifiers = .{ .control = true, .alt = true } }) == null);
    try std.testing.expect(map.resolve(.{ .keycode = 0, .logical = .enter, .modifiers = .{ .shift = true } }) == null);
}

test "full keymaps still allow replacing existing bindings" {
    var map: Keymap = .{};
    const keys = [_]platform.LogicalKey{ .key_a, .key_b, .key_c, .key_d, .key_e, .key_f, .key_g, .key_h };
    for (0..128) |i| try map.set(.{ .key = keys[i / 16], .modifiers = @bitCast(@as(u4, @intCast(i % 16))) }, .none);
    try std.testing.expectEqual(@as(usize, 128), map.len);
    try std.testing.expectError(error.KeyBindingCapacityExceeded, map.set(.{ .key = .key_i }, .{ .edit = .undo }));
    try map.set(.{ .key = .key_d }, .{ .edit = .redo });
    try std.testing.expectEqual(Action{ .edit = .redo }, map.resolve(.{ .keycode = 0, .logical = .key_d }).?.items[0]);
    try std.testing.expectEqual(@as(usize, 128), map.len);
}
