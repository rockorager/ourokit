//! Installs the pure-Lua statechart prototype (`ouro.machine`, see
//! design/statecharts.md) with a native read-only view primitive and the
//! private task-scope binding from scopes.zig. The
//! application sandbox has no setmetatable, so views are userdata whose user
//! value is the underlying table.
const std = @import("std");
const c = @import("c.zig");

const view_metatable = "ouro.machine.view";

pub fn install(state: *c.State) !void {
    const api = c.lua_gettop(state);
    const source = @embedFile("machine.lua");
    if (c.luaL_loadbufferx(state, source, source.len, "=ouro.machine", "t") != c.ok)
        return error.MachineInitializationFailed;
    c.lua_pushvalue(state, api);
    c.lua_pushcclosure(state, view, 0);
    c.lua_pushcclosure(state, raw, 0);
    // Native task scopes (open, spawn, close, alive), or four nils without a Vm.
    const extra = @import("scopes.zig").pushChunkArguments(state);
    if (c.lua_pcallk(state, 3 + extra, 0, 0, 0, null) != c.ok)
        return error.MachineInitializationFailed;
    c.lua_settop(state, api);
}

/// Replace the value at the top of the stack with a view when it is a table.
fn wrapTop(state: *c.State) void {
    if (c.lua_type(state, -1) != c.type_table) return;
    _ = c.lua_newuserdatauv(state, 0, 1);
    c.lua_rotate(state, -2, 1);
    _ = c.lua_setiuservalue(state, -2, 1);
    if (c.luaL_newmetatable(state, view_metatable) != 0) {
        c.lua_pushcclosure(state, index, 0);
        c.lua_setfield(state, -2, "__index");
        c.lua_pushcclosure(state, newIndex, 0);
        c.lua_setfield(state, -2, "__newindex");
        c.lua_pushcclosure(state, length, 0);
        c.lua_setfield(state, -2, "__len");
        c.lua_pushcclosure(state, pairs, 0);
        c.lua_setfield(state, -2, "__pairs");
        c.lua_pushcclosure(state, equal, 0);
        c.lua_setfield(state, -2, "__eq");
        _ = c.lua_pushstring(state, "machine view");
        c.lua_setfield(state, -2, "__name");
        c.lua_pushboolean(state, 0);
        c.lua_setfield(state, -2, "__metatable");
    }
    _ = c.lua_setmetatable(state, -2);
}

/// Push the table behind a view, or return false when the value is not one.
fn pushTarget(state: *c.State, slot: c_int) bool {
    if (c.luaL_testudata(state, slot, view_metatable) == null) return false;
    _ = c.lua_getiuservalue(state, slot, 1);
    return true;
}

fn view(state: *c.State) callconv(.c) c_int {
    c.lua_settop(state, 1);
    if (c.luaL_testudata(state, 1, view_metatable) != null) return 1;
    wrapTop(state);
    return 1;
}

fn raw(state: *c.State) callconv(.c) c_int {
    c.lua_settop(state, 1);
    if (!pushTarget(state, 1)) c.lua_pushvalue(state, 1);
    return 1;
}

fn index(state: *c.State) callconv(.c) c_int {
    _ = pushTarget(state, 1);
    c.lua_pushvalue(state, 2);
    _ = c.lua_rawget(state, -2);
    wrapTop(state);
    return 1;
}

fn newIndex(state: *c.State) callconv(.c) c_int {
    _ = c.lua_pushstring(state, "machine context is read-only; change it with machine.assign");
    return c.lua_error(state);
}

fn length(state: *c.State) callconv(.c) c_int {
    _ = pushTarget(state, 1);
    c.lua_pushinteger(state, @intCast(c.lua_rawlen(state, -1)));
    return 1;
}

fn pairs(state: *c.State) callconv(.c) c_int {
    c.lua_pushcclosure(state, step, 0);
    c.lua_pushvalue(state, 1);
    c.lua_pushnil(state);
    return 3;
}

fn step(state: *c.State) callconv(.c) c_int {
    c.lua_settop(state, 2);
    _ = pushTarget(state, 1);
    c.lua_pushvalue(state, 2);
    if (c.lua_next(state, 3) == 0) return 0;
    wrapTop(state);
    return 2;
}

fn equal(state: *c.State) callconv(.c) c_int {
    if (!pushTarget(state, 1) or !pushTarget(state, 2)) {
        c.lua_pushboolean(state, 0);
        return 1;
    }
    c.lua_pushboolean(state, c.lua_rawequal(state, -1, -2));
    return 1;
}

test "machine views are read-only, recursive and comparable" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_pushcclosure(state, c.ouro_open_safe_libraries, 0);
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 0, 0, 0, null));
    c.lua_pushcclosure(state, view, 0);
    c.lua_setglobal(state, "view");
    c.lua_pushcclosure(state, raw, 0);
    c.lua_setglobal(state, "raw");
    const source =
        \\local t = {a = 1, nested = {list = {'x', 'y'}}}
        \\local v = view(t)
        \\assert(type(v) == 'userdata' and v.a == 1 and v.nested.list[2] == 'y')
        \\assert(#v.nested.list == 2 and v.nested == v.nested and v ~= view({}))
        \\assert(raw(v) == t and raw(v.nested) == t.nested and raw(5) == 5 and view(v) == v)
        \\assert(not pcall(function() v.a = 2 end) and t.a == 1)
        \\assert(not pcall(function() v.nested.b = 2 end) and t.nested.b == nil)
        \\local seen = {}
        \\for k, value in pairs(v) do seen[k] = value end
        \\assert(seen.a == 1 and type(seen.nested) == 'userdata')
        \\local items = {}
        \\for i, item in ipairs(v.nested.list) do items[i] = item end
        \\assert(items[1] == 'x' and items[2] == 'y' and view('s') == 's')
    ;
    if (c.luaL_loadbufferx(state, source, source.len, "=machine-view-test", "t") != c.ok or
        c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok)
    {
        var len: usize = 0;
        std.debug.print("{s}\n", .{c.lua_tolstring(state, -1, &len).?[0..len]});
        return error.LuaTestFailed;
    }
}
