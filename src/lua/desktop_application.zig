//! Declaration and launch state for standard desktop activation. References
//! belong to the application VM; bus resources belong to its application scope.
const std = @import("std");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

pub const Options = struct {
    development: bool = false,
    dbus_activated: bool = false,
    client: bool = false,
    uris: []const []const u8 = &.{},
    action: ?[]const u8 = null,
    token: ?[]const u8 = null,
    startup_id: ?[]const u8 = null,
};

pub fn declaration(L: *c.State, id: []const u8) !c_int {
    const table = c.lua_gettop(L);
    _ = c.lua_getfield(L, table, "single_instance");
    if (c.lua_type(L, -1) != c.type_nil and c.lua_type(L, -1) != c.type_boolean) return error.InvalidSingleInstance;
    if (c.lua_toboolean(L, -1) != 0) try validateId(id);
    c.lua_settop(L, table);
    c.lua_createtable(L, 0, 5);
    inline for (.{ "id", "single_instance", "activate", "open", "activate_action" }) |field| {
        const kind = c.lua_getfield(L, table, field);
        if (comptime !std.mem.eql(u8, field, "id") and !std.mem.eql(u8, field, "single_instance")) {
            if (kind != c.type_nil and kind != c.type_function) return error.InvalidDesktopHook;
        }
        c.lua_setfield(L, -2, field);
    }
    return c.luaL_ref(L, c.registry_index);
}

pub fn validateId(id: []const u8) !void {
    if (id.len > 255 or std.mem.indexOfScalar(u8, id, '.') == null) return error.InvalidDesktopApplicationId;
    var parts = std.mem.splitScalar(u8, id, '.');
    while (parts.next()) |part| {
        if (part.len == 0 or std.ascii.isDigit(part[0])) return error.InvalidDesktopApplicationId;
        for (part) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidDesktopApplicationId;
    }
}

pub fn start(vm: *vm_module.Vm, definition: c_int, state: *c_int, options: Options) !vm_module.TaskHandle {
    const L = vm.state;
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    const source = @embedFile("desktop_application.lua");
    if (c.luaL_loadbufferx(L, source.ptr, source.len, "@ouro/desktop_application", "t") != c.ok) return error.DesktopBootstrapInvalid;
    const function = c.luaL_ref(L, c.registry_index);
    defer c.luaL_unref(L, c.registry_index, function);
    c.lua_createtable(L, 0, 4);
    state.* = c.luaL_ref(L, c.registry_index);
    c.lua_createtable(L, 0, 8);
    inline for (.{ "development", "dbus_activated", "client" }) |field| {
        c.lua_pushboolean(L, @intFromBool(@field(options, field)));
        c.lua_setfield(L, -2, field);
    }
    inline for (.{ "action", "token", "startup_id" }) |field| {
        if (@field(options, field)) |value| {
            _ = c.lua_pushlstring(L, value.ptr, value.len);
            c.lua_setfield(L, -2, field);
        }
    }
    c.lua_createtable(L, @intCast(options.uris.len), 0);
    for (options.uris, 1..) |uri, index| {
        _ = c.lua_pushlstring(L, uri.ptr, uri.len);
        c.lua_rawseti(L, -2, @intCast(index));
    }
    c.lua_setfield(L, -2, "uris");
    const config = c.luaL_ref(L, c.registry_index);
    defer c.luaL_unref(L, c.registry_index, config);
    return vm.spawnRetainedReference(vm.scheduler.application_scope, function, &.{
        .{ .registry = vm.apiReference() }, .{ .registry = definition },
        .{ .registry = state.* },           .{ .registry = config },
    });
}

pub fn flag(L: *c.State, state: c_int, name: [*:0]const u8) bool {
    if (state == c.no_reference) return false;
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_rawgeti(L, c.registry_index, state);
    _ = c.lua_getfield(L, -1, name);
    return c.lua_toboolean(L, -1) != 0;
}

/// Copies and consumes the most recent token only when a surface is ready.
pub fn takeToken(a: std.mem.Allocator, L: *c.State, state: c_int) !?[]u8 {
    if (state == c.no_reference) return null;
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_rawgeti(L, c.registry_index, state);
    _ = c.lua_getfield(L, -1, "token");
    var len: usize = 0;
    const text = c.lua_tolstring(L, -1, &len) orelse return null;
    const copy = try a.dupe(u8, text[0..len]);
    c.lua_settop(L, -2);
    c.lua_pushnil(L);
    c.lua_setfield(L, -2, "token");
    return copy;
}
