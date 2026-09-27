//! Publish only directory-related environment values, never the process environment.
const std = @import("std");
const c = @import("c.zig");
const Vm = @import("vm.zig").Vm;

pub fn install(vm: *Vm, environ: std.process.Environ) !void {
    const L = vm.state;
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    const source = @embedFile("xdg.lua");
    if (c.luaL_loadbufferx(L, source, source.len, "=ouro.xdg", "t") != c.ok) return error.XdgInitializationFailed;
    vm.pushApi(L);
    c.lua_createtable(L, 0, 7);
    inline for (.{ "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_DIRS" }) |key| {
        if (environ.getPosix(key)) |value| {
            _ = c.lua_pushlstring(L, value.ptr, value.len);
            c.lua_setfield(L, -2, key);
        }
    }
    if (c.lua_pcallk(L, 2, 0, 0, 0, null) != c.ok) return error.XdgInitializationFailed;
}
