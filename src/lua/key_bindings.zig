const std = @import("std");
const c = @import("c.zig");
const keymap = @import("../ui/text_input/keymap.zig");
pub const Keymap = keymap.Keymap;

/// Merge an app or widget declaration without retaining references or changing
/// the Lua stack. Errors leave the inherited map untouched.
pub fn field(state: *c.State, index: c_int, name: [*:0]const u8, base: Keymap) !Keymap {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.lua_checkstack(state, 4) == 0) return error.OutOfMemory;
    const kind = c.lua_getfield(state, index, name);
    if (kind == c.type_nil) return base;
    if (kind != c.type_table) return error.InvalidKeyBindings;
    const table = c.lua_gettop(state);
    var result = base;
    _ = c.lua_getfield(state, table, "inherit");
    if (c.lua_type(state, -1) != c.type_nil) {
        if (c.lua_type(state, -1) != c.type_boolean) return error.InvalidKeyBindings;
        if (c.lua_toboolean(state, -1) == 0) result = .{ .inherit_defaults = false };
    }
    c.lua_settop(state, -2);
    var seen: Keymap = .{ .inherit_defaults = false };
    c.lua_pushnil(state);
    while (c.lua_next(state, table) != 0) {
        defer c.lua_settop(state, -2);
        const name_bytes = try string(state, -2);
        if (std.mem.eql(u8, name_bytes, "inherit")) continue;
        const chord = try keymap.KeyChord.parse(name_bytes);
        for (seen.bindings[0..seen.len]) |binding|
            if (std.meta.eql(binding.chord, chord)) return error.DuplicateKeyBinding;
        try seen.set(chord, .none);
        const action: keymap.Action = if (c.lua_type(state, -1) == c.type_boolean and c.lua_toboolean(state, -1) == 0)
            .none
        else
            try keymap.Action.parse(try string(state, -1));
        try result.set(chord, action);
    }
    return result;
}

fn string(state: *c.State, index: c_int) ![]const u8 {
    if (c.lua_type(state, index) != c.type_string) return error.InvalidKeyBindings;
    var len: usize = 0;
    const bytes = c.lua_tolstring(state, index, &len) orelse return error.InvalidKeyBindings;
    return bytes[0..len];
}

test "Lua binding maps inherit replace reject ambiguous chords and restore the stack" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    const source =
        \\return {app = {['Ctrl+Z'] = false, ['Alt+R'] = 'redo'},
        \\  widget = {['Alt+R'] = 'undo'}, empty = {inherit = false},
        \\  fresh = {inherit = false, ['Super+Left'] = 'select_word_previous'},
        \\  duplicate = {['Ctrl+Shift+A'] = 'undo', ['shift+ctrl+a'] = 'redo'},
        \\  bad_key = {['Ctrl+'] = 'undo'}, bad_action = {['A'] = 'typo'},
        \\  bad_type = {['A'] = true}, bad_inherit = {inherit = 0}}
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@key-bindings", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
    const app = try field(state, -1, "app", .{});
    const widget = try field(state, -1, "widget", app);
    const alt_r: @import("../platform/window.zig").TranslatedKey = .{ .keycode = 19, .logical = .key_r, .modifiers = .{ .alt = true } };
    try std.testing.expectEqual(keymap.Action{ .edit = .redo }, app.resolve(alt_r).?);
    try std.testing.expectEqual(keymap.Action{ .edit = .undo }, widget.resolve(alt_r).?);
    try std.testing.expectEqual(keymap.Action.none, widget.resolve(.{ .keycode = 44, .logical = .key_z, .modifiers = .{ .control = true } }).?);
    try std.testing.expectEqual(keymap.Action{ .clipboard = .copy }, widget.resolve(.{ .keycode = 46, .logical = .key_c, .modifiers = .{ .control = true } }).?);
    const empty = try field(state, -1, "empty", widget);
    try std.testing.expect(!empty.inherit_defaults and empty.len == 0);
    const fresh = try field(state, -1, "fresh", widget);
    try std.testing.expect(!fresh.inherit_defaults and fresh.len == 1);
    try std.testing.expect(fresh.resolve(alt_r) == null);
    try std.testing.expectError(error.DuplicateKeyBinding, field(state, -1, "duplicate", app));
    try std.testing.expectError(error.InvalidKeyChord, field(state, -1, "bad_key", app));
    try std.testing.expectError(error.InvalidTextInputAction, field(state, -1, "bad_action", app));
    try std.testing.expectError(error.InvalidKeyBindings, field(state, -1, "bad_type", app));
    try std.testing.expectError(error.InvalidKeyBindings, field(state, -1, "bad_inherit", app));
    try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
}
