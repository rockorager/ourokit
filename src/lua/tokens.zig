const std = @import("std");
const c = @import("c.zig");
const tokens = @import("../design/root.zig").tokens;
const Color = @import("../core/color.zig").Color;

/// Publish copies of the generated token catalog on the Ouro API table.
/// Reflect generated data rather than maintaining a second Lua token list.
pub fn install(state: *c.State) void {
    c.lua_createtable(state, 0, 4);
    inline for (.{ "foundation", "palette", "light", "dark" }) |name| {
        push(state, @field(tokens, name));
        c.lua_setfield(state, -2, name);
    }
    c.lua_setfield(state, -2, "tokens");
}

fn push(state: *c.State, value: anytype) void {
    @setEvalBranchQuota(100_000);
    const T = @TypeOf(value);
    if (T == type) {
        const declarations = comptime std.meta.declarations(value);
        c.lua_createtable(state, 0, @intCast(declarations.len));
        inline for (declarations) |decl| {
            push(state, @field(value, decl.name));
            c.lua_setfield(state, -2, decl.name);
        }
    } else if (T == Color) {
        var buffer: [9]u8 = undefined;
        const hex = std.fmt.bufPrint(&buffer, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            value.r, value.g, value.b, value.a,
        }) catch unreachable;
        _ = c.lua_pushlstring(state, hex.ptr, hex.len);
    } else if (T == []const u8) {
        _ = c.lua_pushlstring(state, value.ptr, value.len);
    } else switch (@typeInfo(T)) {
        .float => c.lua_pushnumber(state, value),
        .@"struct" => {
            const fields = comptime std.meta.fields(T);
            c.lua_createtable(state, 0, @intCast(fields.len));
            inline for (fields) |field| {
                push(state, @field(value, field.name));
                c.lua_setfield(state, -2, field.name);
            }
        },
        else => @compileError("unsupported design token type: " ++ @typeName(T)),
    }
}

test "Lua tokens export the complete generated catalog without stack drift" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 1);
    install(state);
    try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
    try std.testing.expectEqual(c.type_table, c.lua_getfield(state, -1, "tokens"));
    inline for (.{ "foundation", "palette", "light", "dark" }) |name| {
        _ = c.lua_getfield(state, -1, name);
        try check(state, @field(tokens, name));
        c.lua_settop(state, -2);
    }
    try std.testing.expectEqual(@as(c_int, 2), c.lua_gettop(state));
}

// Check every generated leaf against its native value, decoding colors through
// the consumer's parser so channel ordering and alpha must round-trip exactly.
fn check(state: *c.State, expected: anytype) !void {
    @setEvalBranchQuota(100_000);
    const T = @TypeOf(expected);
    if (T == type) {
        try std.testing.expectEqual(c.type_table, c.lua_type(state, -1));
        inline for (comptime std.meta.declarations(expected)) |decl| {
            _ = c.lua_getfield(state, -1, decl.name);
            try check(state, @field(expected, decl.name));
            c.lua_settop(state, -2);
        }
    } else if (T == Color) {
        try std.testing.expectEqual(expected, try @import("theme.zig").color(state, -1));
    } else if (T == []const u8) {
        var len: usize = 0;
        const actual = c.lua_tolstring(state, -1, &len) orelse return error.MissingToken;
        try std.testing.expectEqualStrings(expected, actual[0..len]);
    } else switch (@typeInfo(T)) {
        .float => {
            try std.testing.expectEqual(c.type_number, c.lua_type(state, -1));
            var is_number: c_int = 0;
            try std.testing.expectEqual(@as(f64, expected), c.lua_tonumberx(state, -1, &is_number));
        },
        .@"struct" => {
            try std.testing.expectEqual(c.type_table, c.lua_type(state, -1));
            inline for (std.meta.fields(T)) |field| {
                _ = c.lua_getfield(state, -1, field.name);
                try check(state, @field(expected, field.name));
                c.lua_settop(state, -2);
            }
        },
        else => @compileError("unsupported design token type: " ++ @typeName(T)),
    }
}
