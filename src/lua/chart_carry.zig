//! Carries statechart actors across source reload.
//!
//!   1. When preparation starts, `persist` asks the live generation for plain
//!      snapshots of its root actors (`ouro.machine.persist_roots`).
//!   2. `adopt` copies them into the candidate VM and hands them to
//!      `ouro.machine.carry` before the candidate's source runs, so a root
//!      actor created there with the same id and chart restores from them.
//!   3. After commit, `release` starts the restored actors' timers and invokes
//!      (`ouro.machine.release`). A failed candidate never reaches this step.
//!
//! The live generation is only read. Values cross Lua states by a direct deep
//! copy, never a serialization format, so integers, floats, and integer keys
//! survive unchanged.
const std = @import("std");
const c = @import("c.zig");
const Vm = @import("vm.zig").Vm;
const json = @import("mcp_client.zig");

/// Plain persisted data is shallow in practice; this bounds native recursion.
const max_depth = 64;

/// Registry reference to the live generation's persisted entries.
pub const Persisted = struct {
    vm: *Vm,
    reference: c_int,

    pub fn deinit(self: Persisted) void {
        c.luaL_unref(self.vm.state, c.registry_index, self.reference);
    }
};

/// Persists the live generation's root actors. Returns null when the VM has no
/// statechart module or no root actor to carry. Actors whose state is not plain
/// data are reported on stderr and start fresh in the new generation.
pub fn persist(vm: *Vm) !?Persisted {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (!pushMachineFunction(vm, "persist_roots")) return null;
    if (c.lua_pcallk(state, 0, 2, 0, 0, null) != c.ok) {
        reportError(state, "could not persist statechart actors");
        return error.ChartPersistFailed;
    }
    if (c.lua_type(state, -1) == c.type_table) {
        var index: c.Integer = 1;
        while (c.lua_rawgeti(state, -1, index) == c.type_string) : (index += 1) {
            var length: usize = 0;
            const reason = c.lua_tolstring(state, -1, &length).?;
            std.debug.print("ourokit: statechart not carried across reload: {s}\n", .{reason[0..length]});
            c.lua_settop(state, -2);
        }
        c.lua_settop(state, -2);
    }
    c.lua_settop(state, -2);
    if (c.lua_type(state, -1) != c.type_table or c.lua_rawlen(state, -1) == 0) return null;
    return .{ .vm = vm, .reference = c.luaL_ref(state, c.registry_index) };
}

/// Copies persisted entries into `target` and registers them for restoration.
/// Call after the candidate's statechart module is installed and before its
/// source runs.
pub fn adopt(target: *Vm, persisted: Persisted) !void {
    const state = target.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (!pushMachineFunction(target, "carry")) return error.ChartCarryUnavailable;
    const source = persisted.vm.state;
    const source_top = c.lua_gettop(source);
    defer c.lua_settop(source, source_top);
    _ = c.lua_rawgeti(source, c.registry_index, persisted.reference);
    try copyPlain(source, c.lua_gettop(source), state, 0);
    if (c.lua_pcallk(state, 1, 0, 0, 0, null) != c.ok) {
        reportError(state, "could not carry statechart actors");
        return error.ChartCarryFailed;
    }
}

/// Starts restored actors' timers and invokes in the newly committed
/// generation. Failures are reported but never undo the commit.
pub fn release(vm: *Vm) void {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (!pushMachineFunction(vm, "release")) return;
    if (c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok)
        reportError(state, "could not resume restored statechart work");
}

fn pushMachineFunction(vm: *Vm, name: [*:0]const u8) bool {
    vm.pushApi(vm.state);
    if (c.lua_getfield(vm.state, -1, "machine") != c.type_table) return false;
    return c.lua_getfield(vm.state, -1, name) == c.type_function;
}

fn reportError(state: *c.State, context: []const u8) void {
    var length: usize = 0;
    const message = c.lua_tolstring(state, -1, &length) orelse "non-string Lua error";
    std.debug.print("ourokit: {s}: {s}\n", .{ context, message[0..length] });
}

/// Pushes onto `to` a deep copy of the plain value at absolute `index` in
/// `from`: nil, booleans, numbers, strings, `ouro.json.null`, and tables with
/// string or integer keys. Tables are read raw. On error the caller restores both stack tops.
fn copyPlain(from: *c.State, index: c_int, to: *c.State, depth: usize) !void {
    if (depth > max_depth) return error.CarriedStateTooDeep;
    if (c.lua_checkstack(from, 2) == 0 or c.lua_checkstack(to, 3) == 0) return error.LuaStackExhausted;
    switch (c.lua_type(from, index)) {
        c.type_nil => c.lua_pushnil(to),
        c.type_boolean => c.lua_pushboolean(to, c.lua_toboolean(from, index)),
        c.type_number => {
            var valid: c_int = 0;
            if (c.lua_isinteger(from, index) != 0)
                c.lua_pushinteger(to, c.lua_tointegerx(from, index, &valid))
            else
                c.lua_pushnumber(to, c.lua_tonumberx(from, index, &valid));
        },
        c.type_string => {
            var length: usize = 0;
            const bytes = c.lua_tolstring(from, index, &length).?;
            _ = c.lua_pushlstring(to, bytes, length);
        },
        c.type_table => {
            c.lua_createtable(to, 0, 0);
            c.lua_pushnil(from);
            while (c.lua_next(from, index) != 0) {
                const key = c.lua_gettop(from) - 1;
                const key_type = c.lua_type(from, key);
                if (key_type != c.type_string and !(key_type == c.type_number and c.lua_isinteger(from, key) != 0))
                    return error.CarriedStateNotPlain;
                try copyPlain(from, key, to, depth + 1);
                try copyPlain(from, c.lua_gettop(from), to, depth + 1);
                // New tables have no metatable, so this is a raw set.
                c.lua_settable(to, -3);
                c.lua_settop(from, -2);
            }
        },
        // The same pointer in every VM, so it crosses unchanged.
        c.type_light_userdata => {
            if (!json.isJsonNull(from, index)) return error.CarriedStateNotPlain;
            c.lua_pushlightuserdata(to, c.lua_touserdata(from, index).?);
        },
        else => return error.CarriedStateNotPlain,
    }
}

test "plain values cross Lua states unchanged and non-plain values are rejected" {
    const from = c.luaL_newstate().?;
    defer c.lua_close(from);
    const to = c.luaL_newstate().?;
    defer c.lua_close(to);
    c.lua_pushcclosure(to, c.ouro_open_safe_libraries, 0);
    try std.testing.expectEqual(c.ok, c.lua_pcallk(to, 0, 0, 0, 0, null));
    const source =
        \\return {s = 'a\0b', i = 7, f = 7.0, n = -0.5, t = true, list = {1, 2, 3},
        \\  [3] = 'sparse', [-1] = 'negative', nested = {deep = {deeper = {}}}}
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(from, source, source.len, "=from", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(from, 0, 1, 0, 0, null));
    try copyPlain(from, 1, to, 0);
    try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(from));
    c.lua_setglobal(to, "copied");
    const check =
        \\local c = copied
        \\return c.s == 'a\0b' and math.type(c.i) == 'integer' and math.type(c.f) == 'float'
        \\  and c.f == 7 and c.n == -0.5 and c.t == true and #c.list == 3 and c.list[3] == 3
        \\  and c[3] == 'sparse' and c[-1] == 'negative' and type(c.nested.deep.deeper) == 'table'
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(to, check, check.len, "=to", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(to, 0, 1, 0, 0, null));
    try std.testing.expect(c.lua_toboolean(to, -1) != 0);

    c.lua_settop(from, 0);
    c.lua_settop(to, 0);
    for ([_][]const u8{ "return {f = function() end}", "return {[true] = 1}", "return {[1.5] = 1}" }) |bad| {
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(from, bad.ptr, bad.len, "=bad", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(from, 0, 1, 0, 0, null));
        try std.testing.expectError(error.CarriedStateNotPlain, copyPlain(from, 1, to, 0));
        c.lua_settop(from, 0);
        c.lua_settop(to, 0);
    }
    // ouro.json.null keeps its identity; other light userdata is rejected.
    c.lua_createtable(from, 0, 1);
    try json.pushJson(from, .null);
    c.lua_setfield(from, -2, "missing");
    try copyPlain(from, 1, to, 0);
    _ = c.lua_getfield(to, -1, "missing");
    try std.testing.expect(json.isJsonNull(to, -1));
    c.lua_settop(from, 0);
    c.lua_settop(to, 0);
    var other: u8 = 0;
    c.lua_pushlightuserdata(from, &other);
    try std.testing.expectError(error.CarriedStateNotPlain, copyPlain(from, 1, to, 0));
    c.lua_settop(from, 0);
    c.lua_settop(to, 0);
    const deep = "local t = {}; local root = t; for i = 1, 100 do t.x = {}; t = t.x end; return root";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(from, deep, deep.len, "=deep", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(from, 0, 1, 0, 0, null));
    try std.testing.expectError(error.CarriedStateTooDeep, copyPlain(from, 1, to, 0));
}
