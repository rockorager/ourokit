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
        return .{
            .keycode = keycode,
            .keysym = keysym,
            .logical = logicalKey(keysym),
            .unicode = c.xkb_state_key_get_utf32(state, xkb_keycode),
            .modifiers = .{
                .shift = modifierActive(state, c.XKB_MOD_NAME_SHIFT),
                .control = modifierActive(state, c.XKB_MOD_NAME_CTRL),
                .alt = modifierActive(state, c.XKB_MOD_NAME_ALT),
                .logo = modifierActive(state, c.XKB_MOD_NAME_LOGO),
            },
        };
    }
};

fn modifierActive(state: *c.xkb_state, name: [*:0]const u8) bool {
    return c.xkb_state_mod_name_is_active(state, name, c.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn logicalKey(keysym: u32) platform.LogicalKey {
    return switch (keysym) {
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab => .tab,
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => .enter,
        c.XKB_KEY_space => .space,
        c.XKB_KEY_Escape => .escape,
        c.XKB_KEY_Left => .arrow_left,
        c.XKB_KEY_Right => .arrow_right,
        c.XKB_KEY_Up => .arrow_up,
        c.XKB_KEY_Down => .arrow_down,
        else => .unidentified,
    };
}
