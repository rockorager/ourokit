pub const State = opaque {};
pub const Integer = i64;
pub const KContext = isize;
pub const CFunction = *const fn (*State) callconv(.c) c_int;
pub const KFunction = *const fn (*State, c_int, KContext) callconv(.c) c_int;

pub const ok = 0;
pub const yield = 1;
pub const type_nil = 0;
pub const registry_index = -(std.math.maxInt(c_int) / 2 + 1000);

pub fn upvalueIndex(index: c_int) c_int {
    return registry_index - index;
}

pub extern fn luaL_newstate() ?*State;
pub extern fn lua_close(state: *State) void;
pub extern fn lua_newthread(state: *State) ?*State;
pub extern fn luaL_loadbufferx(state: *State, buffer: [*]const u8, size: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
pub extern fn lua_resume(state: *State, from: ?*State, nargs: c_int, nresults: *c_int) c_int;
pub extern fn lua_yieldk(state: *State, nresults: c_int, context: KContext, continuation: KFunction) c_int;
pub extern fn lua_createtable(state: *State, array_count: c_int, record_count: c_int) void;
pub extern fn lua_pushlightuserdata(state: *State, pointer: *anyopaque) void;
pub extern fn lua_pushcclosure(state: *State, function: CFunction, upvalue_count: c_int) void;
pub extern fn lua_pushstring(state: *State, string: [*:0]const u8) ?[*:0]const u8;
pub extern fn lua_setfield(state: *State, index: c_int, key: [*:0]const u8) void;
pub extern fn lua_setglobal(state: *State, name: [*:0]const u8) void;
pub extern fn lua_getglobal(state: *State, name: [*:0]const u8) c_int;
pub extern fn lua_settop(state: *State, index: c_int) void;
pub extern fn lua_tointegerx(state: *State, index: c_int, is_number: *c_int) Integer;
pub extern fn lua_touserdata(state: *State, index: c_int) ?*anyopaque;
pub extern fn lua_toboolean(state: *State, index: c_int) c_int;
pub extern fn lua_error(state: *State) c_int;

const std = @import("std");
