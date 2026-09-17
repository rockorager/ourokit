const std = @import("std");
const platform = @import("../window.zig");

const c = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const Keyboard = struct {
    context: *c.xkb_context,
    keymap: ?*c.xkb_keymap = null,
    state: ?*c.xkb_state = null,

    pub fn init() !Keyboard {
        return .{ .context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextCreationFailed };
    }

    pub fn deinit(self: *Keyboard) void {
        if (self.state) |state| c.xkb_state_unref(state);
        if (self.keymap) |keymap| c.xkb_keymap_unref(keymap);
        c.xkb_context_unref(self.context);
        self.* = undefined;
    }

    pub fn installKeymap(self: *Keyboard, fd: std.os.linux.fd_t, size: u32) !void {
        defer _ = std.os.linux.close(fd);
        if (size == 0) return error.InvalidXkbKeymap;
        const mapping = try std.posix.mmap(
            null,
            size,
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        defer std.posix.munmap(mapping);
        if (mapping[size - 1] != 0) return error.InvalidXkbKeymap;
        const keymap = c.xkb_keymap_new_from_string(
            self.context,
            @ptrCast(mapping.ptr),
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapCreationFailed;
        errdefer c.xkb_keymap_unref(keymap);
        const state = c.xkb_state_new(keymap) orelse return error.XkbStateCreationFailed;
        if (self.state) |old| c.xkb_state_unref(old);
        if (self.keymap) |old| c.xkb_keymap_unref(old);
        self.keymap = keymap;
        self.state = state;
    }

    pub fn updateModifiers(
        self: *Keyboard,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        const state = self.state orelse return;
        _ = c.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }

    pub fn translate(self: *Keyboard, keycode: u32) platform.TranslatedKey {
        const state = self.state orelse return .{ .keycode = keycode };
        const xkb_keycode = keycode + 8;
        const keysym = c.xkb_state_key_get_one_sym(state, xkb_keycode);
        var logical = logicalKey(keysym);
        // Shift+digit still names the digit binding even when it produces
        // punctuation. Keep the actual keysym/Unicode for ordinary typing.
        if (logical == .unidentified and modifierActive(state, c.XKB_MOD_NAME_SHIFT)) {
            var symbols: [*c]const c.xkb_keysym_t = null;
            const count = c.xkb_keymap_key_get_syms_by_level(self.keymap.?, xkb_keycode, c.xkb_state_key_get_layout(state, xkb_keycode), 0, &symbols);
            if (count == 1 and symbols[0] >= '0' and symbols[0] <= '9')
                logical = logicalKey(symbols[0]);
        }
        return .{
            .keycode = keycode,
            .keysym = keysym,
            .logical = logical,
            .unicode = c.xkb_state_key_get_utf32(state, xkb_keycode),
            .modifiers = .{
                .shift = modifierActive(state, c.XKB_MOD_NAME_SHIFT),
                .control = modifierActive(state, c.XKB_MOD_NAME_CTRL),
                .alt = modifierActive(state, c.XKB_MOD_NAME_ALT),
                .logo = modifierActive(state, c.XKB_MOD_NAME_LOGO),
            },
        };
    }

    pub fn repeats(self: *const Keyboard, keycode: u32) bool {
        const keymap = self.keymap orelse return false;
        return c.xkb_keymap_key_repeats(keymap, keycode + 8) != 0;
    }
};

fn modifierActive(state: *c.xkb_state, name: [*:0]const u8) bool {
    return c.xkb_state_mod_name_is_active(state, name, c.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn logicalKey(keysym: u32) platform.LogicalKey {
    // Logical identity is independent of Ctrl's control-code translation and
    // letter case, so application bindings work with arbitrary letters.
    inline for ("abcdefghijklmnopqrstuvwxyz") |letter| {
        if (keysym == letter or keysym == std.ascii.toUpper(letter))
            return @field(platform.LogicalKey, "key_" ++ .{letter});
    }
    inline for ("0123456789") |digit| {
        if (keysym == digit) return @field(platform.LogicalKey, "digit_" ++ .{digit});
    }
    inline for (1..13) |number| {
        if (keysym == c.XKB_KEY_F1 + number - 1)
            return @field(platform.LogicalKey, std.fmt.comptimePrint("f{d}", .{number}));
    }
    return switch (keysym) {
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab => .tab,
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => .enter,
        c.XKB_KEY_space => .space,
        c.XKB_KEY_Escape => .escape,
        c.XKB_KEY_Left => .arrow_left,
        c.XKB_KEY_Right => .arrow_right,
        c.XKB_KEY_Up => .arrow_up,
        c.XKB_KEY_Down => .arrow_down,
        c.XKB_KEY_Home, c.XKB_KEY_KP_Home => .home,
        c.XKB_KEY_End, c.XKB_KEY_KP_End => .end,
        c.XKB_KEY_Page_Up, c.XKB_KEY_KP_Page_Up => .page_up,
        c.XKB_KEY_Page_Down, c.XKB_KEY_KP_Page_Down => .page_down,
        c.XKB_KEY_BackSpace => .backspace,
        c.XKB_KEY_Delete, c.XKB_KEY_KP_Delete => .delete,
        else => .unidentified,
    };
}

test "bindable letters digits and function keys retain logical identity" {
    inline for ("abcdefghijklmnopqrstuvwxyz") |letter| {
        const expected = @field(platform.LogicalKey, "key_" ++ .{letter});
        try std.testing.expectEqual(expected, logicalKey(letter));
        try std.testing.expectEqual(expected, logicalKey(std.ascii.toUpper(letter)));
    }
    try std.testing.expectEqual(platform.LogicalKey.digit_7, logicalKey(c.XKB_KEY_7));
    try std.testing.expectEqual(platform.LogicalKey.f12, logicalKey(c.XKB_KEY_F12));
    try std.testing.expectEqual(platform.LogicalKey.unidentified, logicalKey(c.XKB_KEY_F13));
}

test "native bindings retain Ctrl letters and shifted digits without changing typed Unicode" {
    var keyboard = try Keyboard.init();
    defer keyboard.deinit();
    const names: c.xkb_rule_names = .{ .rules = "evdev", .model = "pc105", .layout = "us", .variant = "", .options = "" };
    keyboard.keymap = c.xkb_keymap_new_from_names(keyboard.context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymapCreationFailed;
    keyboard.state = c.xkb_state_new(keyboard.keymap.?) orelse return error.XkbStateCreationFailed;
    const shift: u32 = @as(u32, 1) << @intCast(c.xkb_keymap_mod_get_index(keyboard.keymap.?, c.XKB_MOD_NAME_SHIFT));
    const control: u32 = @as(u32, 1) << @intCast(c.xkb_keymap_mod_get_index(keyboard.keymap.?, c.XKB_MOD_NAME_CTRL));
    keyboard.updateModifiers(control, 0, 0, 0);
    const ctrl_r = keyboard.translate(19);
    try std.testing.expectEqual(platform.LogicalKey.key_r, ctrl_r.logical);
    try std.testing.expectEqual(@as(u32, 18), ctrl_r.unicode);
    try std.testing.expectEqual(platform.Modifiers{ .control = true }, ctrl_r.modifiers);
    keyboard.updateModifiers(control | shift, 0, 0, 0);
    try std.testing.expectEqual(platform.LogicalKey.key_r, keyboard.translate(19).logical);
    keyboard.updateModifiers(shift, 0, 0, 0);
    const shifted_digit = keyboard.translate(10);
    try std.testing.expectEqual(platform.LogicalKey.digit_9, shifted_digit.logical);
    try std.testing.expectEqual(@as(u32, '('), shifted_digit.unicode);
    try std.testing.expectEqual(@as(u32, c.XKB_KEY_parenleft), shifted_digit.keysym);
    try std.testing.expectEqual(platform.Modifiers{ .shift = true }, shifted_digit.modifiers);
}
