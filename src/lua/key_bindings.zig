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
        const sequence = try keymap.Sequence.parse(name_bytes);
        for (seen.bindings[0..seen.len]) |binding|
            if (binding.sequence.len == sequence.len and binding.sequence.overlaps(sequence)) return error.DuplicateKeyBinding;
        try seen.setSequence(sequence, .{});
        var actions: keymap.Actions = .{};
        if (c.lua_type(state, -1) == c.type_table) {
            const array = c.lua_gettop(state);
            const count = denseArray(state, array) catch return error.InvalidTextInputActions;
            if (count == 0 or count > actions.items.len) return error.InvalidTextInputActions;
            actions.len = @intCast(count);
            for (0..count) |i| {
                _ = c.lua_rawgeti(state, array, @intCast(i + 1));
                actions.items[i] = try keymap.Action.parse(try string(state, -1));
                c.lua_settop(state, -2);
            }
        } else if (!(c.lua_type(state, -1) == c.type_boolean and c.lua_toboolean(state, -1) == 0)) {
            actions = keymap.Actions.single(try keymap.Action.parse(try string(state, -1)));
        }
        try result.setSequence(sequence, actions);
    }
    return result;
}

fn string(state: *c.State, index: c_int) ![]const u8 {
    if (c.lua_type(state, index) != c.type_string) return error.InvalidKeyBindings;
    var len: usize = 0;
    const bytes = c.lua_tolstring(state, index, &len) orelse return error.InvalidKeyBindings;
    return bytes[0..len];
}

/// Native listener filters share the editor's logical chord parser, but never
/// resolve editor actions or externally exposed application actions.
pub fn listenerFilter(state: *c.State, index: c_int, keyboard: bool) !@import("../ui/input/listener.zig").Filter {
    const listener = @import("../ui/input/listener.zig");
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    var result: listener.Filter = .{};
    if (keyboard) {
        const kind = c.lua_getfield(state, index, "keys");
        if (kind != c.type_nil) {
            const count = try denseArray(state, c.lua_gettop(state));
            if (count == 0 or count > result.keys.len) return error.InvalidInputFilter;
            for (0..count) |i| {
                _ = c.lua_rawgeti(state, -1, @intCast(i + 1));
                result.keys[i] = try keymap.KeyChord.parse(try string(state, -1));
                c.lua_settop(state, -2);
            }
            result.key_count = @intCast(count);
        }
        c.lua_settop(state, -2);
        try enumFilter(listener.State, state, index, "states", &result.states);
    } else {
        try enumFilter(listener.Kind, state, index, "kinds", &result.kinds);
        if (c.lua_getfield(state, index, "button") != c.type_nil) {
            var valid: c_int = 0;
            const button = c.lua_tointegerx(state, -1, &valid);
            if (c.lua_type(state, -1) != c.type_number or valid == 0 or button < 0 or button > std.math.maxInt(u32))
                return error.InvalidInputFilter;
            result.button = @intCast(button);
        }
    }
    return result;
}

fn enumFilter(comptime E: type, state: *c.State, index: c_int, name: [*:0]const u8, result: *std.EnumSet(E)) !void {
    const kind = c.lua_getfield(state, index, name);
    defer c.lua_settop(state, -2);
    if (kind == c.type_nil) return;
    const count = try denseArray(state, c.lua_gettop(state));
    if (count == 0) return error.InvalidInputFilter;
    result.* = std.EnumSet(E).initEmpty();
    for (0..count) |i| {
        _ = c.lua_rawgeti(state, -1, @intCast(i + 1));
        const value = std.meta.stringToEnum(E, try string(state, -1)) orelse return error.InvalidInputFilter;
        if (comptime E == @import("../ui/input/listener.zig").Kind) {
            if (value == .key) return error.InvalidInputFilter;
        }
        result.insert(value);
        c.lua_settop(state, -2);
    }
}

fn denseArray(state: *c.State, index: c_int) !usize {
    if (c.lua_type(state, index) != c.type_table) return error.InvalidInputFilter;
    const count = c.lua_rawlen(state, index);
    c.lua_pushnil(state);
    while (c.lua_next(state, index) != 0) {
        var valid: c_int = 0;
        const i = c.lua_tointegerx(state, -2, &valid);
        if (c.lua_type(state, -2) != c.type_number or valid == 0 or i < 1 or i > count)
            return error.InvalidInputFilter;
        c.lua_settop(state, -2);
    }
    return count;
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
    try std.testing.expectEqual(keymap.Action{ .edit = .redo }, app.resolve(alt_r).?.items[0]);
    try std.testing.expectEqual(keymap.Action{ .edit = .undo }, widget.resolve(alt_r).?.items[0]);
    try std.testing.expectEqual(keymap.Action.none, widget.resolve(.{ .keycode = 44, .logical = .key_z, .modifiers = .{ .control = true } }).?.items[0]);
    try std.testing.expectEqual(keymap.Action{ .clipboard = .copy }, widget.resolve(.{ .keycode = 46, .logical = .key_c, .modifiers = .{ .control = true } }).?.items[0]);
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

test "Lua editor sequences validate recipes ambiguity and dense arrays" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    const source =
        \\return { good={inherit=false, ['C I W']={'select_word_inner','delete_selection','submit'}, ['C A W']='select_word_around'},
        \\ prefix={C='undo',['C I W']='redo'}, duplicate={['C I W']='undo',['c i w']='redo'},
        \\ empty={X={}}, sparse={X={[1]='undo',[3]='redo'}}, named={X={foo='undo'}},
        \\ long={X={'undo','undo','undo','undo','undo','undo'}},
        \\ callback={X={'submit','delete_selection'}}, paste={X={'paste','delete_selection'}}}
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@sequences", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
    const map = try field(state, -1, "good", .{});
    try std.testing.expectEqual(.pending, map.match(try keymap.Sequence.parse("C")).?);
    try std.testing.expectEqual(.pending, map.match(try keymap.Sequence.parse("C I")).?);
    const actions = map.match(try keymap.Sequence.parse("C I W")).?.actions;
    try std.testing.expectEqual(@as(u8, 3), actions.len);
    try std.testing.expectEqual(keymap.Action{ .edit = .select_word_inner }, actions.items[0]);
    try std.testing.expectEqual(keymap.Action{ .edit = .delete_selection }, actions.items[1]);
    try std.testing.expectEqual(keymap.Action{ .command = .submit }, actions.items[2]);
    try std.testing.expect(map.match(try keymap.Sequence.parse("C X")) == null);
    try std.testing.expectError(error.AmbiguousKeyBinding, field(state, -1, "prefix", .{}));
    try std.testing.expectError(error.DuplicateKeyBinding, field(state, -1, "duplicate", .{}));
    for ([_][*:0]const u8{ "empty", "sparse", "named", "long", "callback", "paste" }) |name|
        try std.testing.expectError(error.InvalidTextInputActions, field(state, -1, name, .{}));
    try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
}
