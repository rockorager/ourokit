pub const State = opaque {};
pub const Integer = i64;
pub const KContext = isize;
pub const CFunction = *const fn (*State) callconv(.c) c_int;
pub const KFunction = *const fn (*State, c_int, KContext) callconv(.c) c_int;

pub const ok = 0;
pub const yield = 1;
pub const type_nil = 0;
pub const type_boolean = 1;
pub const type_number = 3;
pub const type_string = 4;
pub const type_table = 5;
pub const type_function = 6;
pub const registry_index = -(std.math.maxInt(c_int) / 2 + 1000);
pub const no_reference = -2;

pub fn upvalueIndex(index: c_int) c_int {
    return registry_index - index;
}

pub extern fn luaL_newstate() ?*State;
pub extern fn luaL_newmetatable(state: *State, name: [*:0]const u8) c_int;
pub extern fn luaL_testudata(state: *State, index: c_int, name: [*:0]const u8) ?*anyopaque;
pub extern fn luaL_ref(state: *State, table_index: c_int) c_int;
pub extern fn luaL_unref(state: *State, table_index: c_int, reference: c_int) void;
pub extern fn lua_close(state: *State) void;
pub extern fn lua_newthread(state: *State) ?*State;
pub extern fn lua_closethread(state: *State, from: ?*State) c_int;
pub extern fn luaL_loadbufferx(state: *State, buffer: [*]const u8, size: usize, name: [*:0]const u8, mode: ?[*:0]const u8) c_int;
pub extern fn lua_gettop(state: *State) c_int;
pub extern fn lua_xmove(from: *State, to: *State, count: c_int) void;
pub extern fn lua_type(state: *State, index: c_int) c_int;
pub extern fn lua_resume(state: *State, from: ?*State, nargs: c_int, nresults: *c_int) c_int;
pub extern fn lua_pcallk(state: *State, nargs: c_int, nresults: c_int, error_function: c_int, context: KContext, continuation: ?KFunction) c_int;
pub extern fn lua_yieldk(state: *State, nresults: c_int, context: KContext, continuation: KFunction) c_int;
pub extern fn lua_createtable(state: *State, array_count: c_int, record_count: c_int) void;
pub extern fn lua_pushnumber(state: *State, value: f64) void;
pub extern fn lua_pushinteger(state: *State, value: Integer) void;
pub extern fn lua_pushboolean(state: *State, value: c_int) void;
pub extern fn lua_pushvalue(state: *State, index: c_int) void;
pub extern fn lua_pushlightuserdata(state: *State, pointer: *anyopaque) void;
pub extern fn lua_pushcclosure(state: *State, function: CFunction, upvalue_count: c_int) void;
pub extern fn lua_pushstring(state: *State, string: [*:0]const u8) ?[*:0]const u8;
pub extern fn lua_setfield(state: *State, index: c_int, key: [*:0]const u8) void;
pub extern fn lua_setglobal(state: *State, name: [*:0]const u8) void;
pub extern fn lua_getglobal(state: *State, name: [*:0]const u8) c_int;
pub extern fn lua_getfield(state: *State, index: c_int, key: [*:0]const u8) c_int;
pub extern fn lua_rawgeti(state: *State, index: c_int, integer: Integer) c_int;
pub extern fn lua_settop(state: *State, index: c_int) void;
pub extern fn lua_newuserdatauv(state: *State, size: usize, user_value_count: c_int) ?*anyopaque;
pub extern fn lua_getiuservalue(state: *State, index: c_int, user_value: c_int) c_int;
pub extern fn lua_setiuservalue(state: *State, index: c_int, user_value: c_int) c_int;
pub extern fn lua_setmetatable(state: *State, index: c_int) c_int;
pub extern fn lua_rawequal(state: *State, first: c_int, second: c_int) c_int;
pub extern fn lua_tonumberx(state: *State, index: c_int, is_number: *c_int) f64;
pub extern fn lua_tointegerx(state: *State, index: c_int, is_number: *c_int) Integer;
pub extern fn lua_touserdata(state: *State, index: c_int) ?*anyopaque;
pub extern fn lua_tolstring(state: *State, index: c_int, length: *usize) ?[*]const u8;
pub extern fn lua_toboolean(state: *State, index: c_int) c_int;
pub extern fn lua_error(state: *State) c_int;

const std = @import("std");
