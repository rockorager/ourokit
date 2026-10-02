const std = @import("std");
const c = @import("c.zig");

/// Non-yielding protected call that preserves the stack contract of pcall,
/// capturing the traceback before Lua unwinds the failing function.
pub fn pcall(state: *c.State, arguments: c_int, results: c_int) c_int {
    const handler = c.lua_gettop(state) - arguments;
    c.lua_pushcclosure(state, traceback, 0);
    c.lua_rotate(state, handler, 1);
    const status = c.lua_pcallk(state, arguments, results, handler, 0, null);
    c.lua_rotate(state, handler, -1);
    c.lua_settop(state, -2);
    return status;
}

fn traceback(state: *c.State) callconv(.c) c_int {
    var length: usize = 0;
    const message = c.lua_tolstring(state, 1, &length);
    c.luaL_traceback(state, state, if (message) |ptr| @ptrCast(ptr) else "non-string Lua error", 1);
    return 1;
}

pub fn logLuaStack(state: *c.State) void {
    var length: usize = 0;
    const message = c.lua_tolstring(state, -1, &length);
    // Also used for expected build failures in tests; the caller returns the
    // typed error. Keep the original Lua detail on stderr without double-counting.
    std.debug.print("Lua: {s}\n", .{if (message) |ptr| ptr[0..length] else "non-string Lua error"});
}

pub const Phase = enum {
    source,
    setup,
    compile,
    evaluate,
    declaration,
    build,
};

/// Owned structured failure from preparing one source generation.
pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    phase: Phase,
    source_name: []u8,
    message: []u8,

    pub fn fromError(
        allocator: std.mem.Allocator,
        phase: Phase,
        source_name: []const u8,
        err: anyerror,
    ) !Diagnostic {
        return init(allocator, phase, source_name, @errorName(err));
    }

    pub fn fromLuaStack(
        allocator: std.mem.Allocator,
        phase: Phase,
        source_name: []const u8,
        state: *c.State,
    ) !Diagnostic {
        var length: usize = 0;
        const pointer = c.lua_tolstring(state, -1, &length);
        const message = if (pointer) |value| value[0..length] else "unknown Lua error";
        return init(allocator, phase, source_name, message);
    }

    fn init(
        allocator: std.mem.Allocator,
        phase: Phase,
        source_name: []const u8,
        message: []const u8,
    ) !Diagnostic {
        const owned_source = try allocator.dupe(u8, source_name);
        errdefer allocator.free(owned_source);
        return .{
            .allocator = allocator,
            .phase = phase,
            .source_name = owned_source,
            .message = try allocator.dupe(u8, message),
        };
    }

    pub fn deinit(self: *Diagnostic) void {
        self.allocator.free(self.message);
        self.allocator.free(self.source_name);
        self.* = undefined;
    }
};

pub fn recordError(
    output: ?*?Diagnostic,
    allocator: std.mem.Allocator,
    phase: Phase,
    source_name: []const u8,
    err: anyerror,
) void {
    const destination = output orelse return;
    if (destination.* != null) return;
    destination.* = Diagnostic.fromError(allocator, phase, source_name, err) catch null;
}

pub fn recordLuaStack(
    output: ?*?Diagnostic,
    allocator: std.mem.Allocator,
    phase: Phase,
    source_name: []const u8,
    state: *c.State,
) void {
    const destination = output orelse return;
    if (destination.* != null) return;
    destination.* = Diagnostic.fromLuaStack(
        allocator,
        phase,
        source_name,
        state,
    ) catch null;
}

test "protected call preserves arguments results and a nested Lua traceback" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    c.lua_pushinteger(state, 73);
    const source = "local function inner() local absent; return absent.value end; return function(n) if n == 7 then return n+2, n+3 end; return inner() end";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@diagnostic-fixture.lua", null));
    try std.testing.expectEqual(c.ok, pcall(state, 0, 1));
    c.lua_pushvalue(state, -1);
    c.lua_pushinteger(state, 7);
    try std.testing.expectEqual(c.ok, pcall(state, 1, 2));
    var valid: c_int = 0;
    try std.testing.expectEqual(@as(i64, 9), c.lua_tointegerx(state, -2, &valid));
    try std.testing.expectEqual(@as(i64, 10), c.lua_tointegerx(state, -1, &valid));
    c.lua_settop(state, 2);
    c.lua_pushinteger(state, 0);
    try std.testing.expect(pcall(state, 1, 0) != c.ok);
    try std.testing.expectEqual(@as(c_int, 2), c.lua_gettop(state));
    var failure = try Diagnostic.fromLuaStack(std.testing.allocator, .build, "fixture", state);
    defer failure.deinit();
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "diagnostic-fixture.lua:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "stack traceback:") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message, "absent") != null);
    try std.testing.expectEqual(@as(i64, 73), c.lua_tointegerx(state, 1, &valid));
}
