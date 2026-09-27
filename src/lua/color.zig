const std = @import("std");
const c = @import("c.zig");
const Color = @import("../core/color.zig").Color;

/// Install color helpers on the Ouro API table at the top of the stack.
pub fn install(state: *c.State) void {
    c.lua_createtable(state, 0, 1);
    c.lua_pushcclosure(state, withAlpha, 0);
    c.lua_setfield(state, -2, "with_alpha");
    c.lua_setfield(state, -2, "color");
}

/// Lua colors and tokens share the same straight-alpha sRGB encoding.
pub fn push(state: *c.State, value: Color) void {
    var buffer: [9]u8 = undefined;
    const hex = std.fmt.bufPrint(&buffer, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        value.r, value.g, value.b, value.a,
    }) catch unreachable;
    _ = c.lua_pushlstring(state, hex.ptr, hex.len);
}

fn withAlpha(state: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(state) != 2)
        return fail(state, "ouro.color.with_alpha expects a color and alpha");
    var value = @import("theme.zig").color(state, 1) catch
        return fail(state, "ouro.color.with_alpha color must be #RRGGBB or #RRGGBBAA");
    if (c.lua_type(state, 2) != c.type_number)
        return fail(state, "ouro.color.with_alpha alpha must be a finite number between 0 and 1");
    var is_number: c_int = 0;
    const alpha = c.lua_tonumberx(state, 2, &is_number);
    if (!std.math.isFinite(alpha) or alpha < 0 or alpha > 1)
        return fail(state, "ouro.color.with_alpha alpha must be a finite number between 0 and 1");
    value.a = @intFromFloat(@round(alpha * 255));
    push(state, value);
    return 1;
}

fn fail(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "Lua color with_alpha preserves RGB and replaces rounded alpha" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 1);
    install(state);
    try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
    c.lua_setglobal(state, "ouro");

    const cases = .{
        .{ "'#12aBcD', 0.3", "#12abcd4d" },
        .{ "'#12aBcD20', 0.5", "#12abcd80" },
        .{ "'#12abcdff', 0", "#12abcd00" },
        .{ "'#12abcd00', 1", "#12abcdff" },
        .{ "'#12abcd', 0.499", "#12abcd7f" },
        .{ "'#12abcd', 0.501", "#12abcd80" },
        .{ "ouro.color.with_alpha('#12abcd', 0), 0.3", "#12abcd4d" },
    };
    inline for (cases) |case| {
        const source = "return ouro.color.with_alpha(" ++ case[0] ++ ")";
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "color-test", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
        try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
        var len: usize = 0;
        const actual = c.lua_tolstring(state, -1, &len).?;
        try std.testing.expectEqualStrings(case[1], actual[0..len]);
        c.lua_settop(state, 0);
    }
}

test "Lua color with_alpha rejects invalid colors alpha and argument counts" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 1);
    install(state);
    c.lua_setglobal(state, "ouro");

    inline for (.{
        "",                  "'#123456'",         "'#123456', 0.5, 1",
        "nil, 0.5",          "123456, 0.5",       "{}, 0.5",
        "false, 0.5",        "'#123', 0.5",       "'123456', 0.5",
        "'#1234567', 0.5",   "'#123456789', 0.5", "'#12345g', 0.5",
        "'#123456gg', 0.5",  "'#123456\\0', 0.5", "'#123456', nil",
        "'#123456', '0.5'",  "'#123456', true",   "'#123456', {}",
        "'#123456', -0.001", "'#123456', 1.001",  "'#123456', 0/0",
        "'#123456', 1/0",    "'#123456', -1/0",
    }) |arguments| {
        const source = "return ouro.color.with_alpha(" ++ arguments ++ ")";
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "color-test", "t"));
        try std.testing.expect(c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok);
        try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
        var len: usize = 0;
        const message = c.lua_tolstring(state, -1, &len).?;
        try std.testing.expect(std.mem.indexOf(u8, message[0..len], "ouro.color.with_alpha") != null);
        c.lua_settop(state, 0);
    }
}
