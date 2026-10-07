//! Installs the pure-Lua statechart prototype (`ouro.machine`, see
//! design/statecharts.md) with a native read-only view primitive and the
//! private task-scope binding from scopes.zig. The
//! application sandbox has no setmetatable, so views are userdata whose user
//! value is the underlying table.
const std = @import("std");
const c = @import("c.zig");
const Vm = @import("vm.zig").Vm;
const TaskHandle = @import("vm.zig").TaskHandle;
const task = @import("../task/root.zig");

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
    c.lua_pushcclosure(state, atomic, 0);
    c.lua_pushcclosure(state, waiterNew, 0);
    c.lua_pushcclosure(state, waiterPark, 0);
    c.lua_pushcclosure(state, waiterWake, 0);
    c.lua_pushcclosure(state, waiterWaiting, 0);
    c.lua_pushcclosure(state, trackedView, 0);
    // Private release(signal); a no-op for values that aren't ouro signals.
    @import("signals.zig").Signals.pushRelease(state);
    if (c.lua_pcallk(state, 10 + extra, 0, 0, 0, null) != c.ok)
        return error.MachineInitializationFailed;
    // Recording and replay (design/statecharts.md §14) extend ouro.machine.
    const replay = @embedFile("machine_replay.lua");
    if (c.luaL_loadbufferx(state, replay, replay.len, "=ouro.machine.replay", "t") != c.ok)
        return error.MachineInitializationFailed;
    c.lua_pushvalue(state, api);
    _ = c.lua_getfield(state, api, "machine");
    if (c.lua_pcallk(state, 2, 0, 0, 0, null) != c.ok)
        return error.MachineInitializationFailed;
    // Generated tests: guard-aware paths to every reachable state.
    const paths = @embedFile("machine_paths.lua");
    if (c.luaL_loadbufferx(state, paths, paths.len, "=ouro.machine.paths", "t") != c.ok)
        return error.MachineInitializationFailed;
    c.lua_pushvalue(state, api);
    _ = c.lua_getfield(state, api, "machine");
    if (c.lua_pcallk(state, 2, 0, 0, 0, null) != c.ok)
        return error.MachineInitializationFailed;
    c.lua_settop(state, api);
}

/// atomic(label, fn, ...) calls fn(...) as a non-yielding section and returns
/// its results. Guards, assigns, expressions and function actions run this
/// way: the Vm makes sleep, exit, spawn and every Ouro I/O wait fail before
/// they touch task state, and the call itself is not yieldable, so nothing can
/// suspend the sender's task halfway through a macrostep's effects. A
/// violation raises "YieldInAction: <label> called <operation> ..." even if
/// the function swallowed the operation's own error.
fn atomic(state: *c.State) callconv(.c) c_int {
    const vm = Vm.fromState(state);
    const arguments = c.lua_gettop(state) - 2;
    if (arguments < 0 or c.lua_type(state, 2) != c.type_function) {
        _ = c.lua_pushstring(state, "atomic expects a label and a function");
        return c.lua_error(state);
    }
    const owner = vm orelse {
        if (c.lua_pcallk(state, arguments, -1, 0, 0, null) != c.ok) return c.lua_error(state);
        return c.lua_gettop(state) - 1;
    };
    const before = owner.atomic_violation;
    owner.atomic_depth += 1;
    const status = c.lua_pcallk(state, arguments, -1, 0, 0, null);
    owner.atomic_depth -= 1;
    const violation = owner.atomic_violation;
    owner.atomic_violation = before;
    if (violation != null and violation != before) {
        c.lua_settop(state, 1);
        var label_length: usize = 0;
        const label = c.lua_tolstring(state, 1, &label_length) orelse "machine function";
        var buffer: [512]u8 = undefined;
        const fallback = "YieldInAction: a machine function waited or spawned; move async work into an invoke or a spawned actor";
        const message = std.fmt.bufPrint(&buffer, "YieldInAction: {s} called {s}, which waits or spawns; " ++
            "move async work into an invoke or a spawned actor", .{ label[0..label_length], std.mem.span(violation.?) }) catch fallback;
        _ = c.lua_pushlstring(state, message.ptr, message.len);
        return c.lua_error(state);
    }
    if (status != c.ok) return c.lua_error(state);
    return c.lua_gettop(state) - 1;
}

/// Sets `ouro.machine.strict`: hosts make it follow development mode, so
/// undeclared events raise under --dev and in tests and are rejected in
/// production.
pub fn setStrict(vm: *Vm, strict: bool) void {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    vm.pushApi(state);
    if (c.lua_getfield(state, -1, "machine") != c.type_table) return;
    c.lua_pushboolean(state, @intFromBool(strict));
    c.lua_setfield(state, -2, "strict");
}

/// A parked task for machine.wait_for. The Lua userdata owns this memory; the
/// parked coroutine keeps it alive (it is on that task's stack), and the
/// scheduler only holds it as a resource context while the task waits.
const Waiter = struct {
    handle: TaskHandle = .invalid,
    vm: ?*Vm = null,
    waiting: bool = false,
    code: c.Integer = 0,
};
const waiter_metatable = "ouro.machine.waiter";
/// Wake code reported when the scheduler cancels the waiting task.
const canceled_code = -1;

fn waiterArgument(state: *c.State) *Waiter {
    return @ptrCast(@alignCast(c.luaL_testudata(state, 1, waiter_metatable) orelse {
        _ = c.lua_pushstring(state, "machine waiter expected");
        _ = c.lua_error(state);
        unreachable;
    }));
}

fn raiseText(state: *c.State, text: []const u8) c_int {
    _ = c.lua_pushlstring(state, text.ptr, text.len);
    return c.lua_error(state);
}

/// waiter_new(cleanup) -> waiter. Closing it (a `<close>` local) calls
/// cleanup once: on return, on error, and when a canceled task unwinds.
fn waiterNew(state: *c.State) callconv(.c) c_int {
    const waiter: *Waiter = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(Waiter), 1).?));
    waiter.* = .{};
    c.lua_pushvalue(state, 1);
    _ = c.lua_setiuservalue(state, -2, 1);
    if (c.luaL_newmetatable(state, waiter_metatable) != 0) {
        c.lua_pushcclosure(state, waiterClose, 0);
        c.lua_setfield(state, -2, "__close");
        c.lua_pushboolean(state, 0);
        c.lua_setfield(state, -2, "__metatable");
    }
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

fn waiterClose(state: *c.State) callconv(.c) c_int {
    const waiter = waiterArgument(state);
    waiter.waiting = false;
    if (c.lua_getiuservalue(state, 1, 1) != c.type_function) return 0;
    c.lua_pushnil(state);
    _ = c.lua_setiuservalue(state, 1, 1); // Run cleanup once.
    if (c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok) return c.lua_error(state);
    return 0;
}

fn waiterCancel(context: *anyopaque) !void {
    const waiter: *Waiter = @ptrCast(@alignCast(context));
    if (!waiter.waiting) return;
    waiter.waiting = false;
    waiter.code = canceled_code;
    try waiter.vm.?.markExternalCompleted(waiter.handle);
}

fn waiterDestroy(_: *anyopaque) void {} // Lua owns the waiter.

const waiter_lifecycle: task.ResourceLifecycle = .{ .request_cancel = waiterCancel, .destroy = waiterDestroy };

/// waiter_park(waiter) yields the running task until waiter_wake, then returns
/// the wake code. Inside an atomic section this fails like any Ouro wait.
fn waiterPark(state: *c.State) callconv(.c) c_int {
    const waiter = waiterArgument(state);
    const vm = Vm.fromState(state) orelse return raiseText(state, "WaitUnavailable: no Ouro runtime");
    if (waiter.waiting) return raiseText(state, "machine waiter is already parked");
    waiter.handle = vm.beginExternalWait(state, .operation, waiter, &waiter_lifecycle) catch |err| {
        if (err == error.YieldInAtomicSection) return raiseText(state, "YieldInAtomicSection: machine.wait_for");
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "machine.wait_for must run in an Ouro task ({s})", .{@errorName(err)}) catch "machine.wait_for must run in an Ouro task";
        return raiseText(state, text);
    };
    waiter.vm = vm;
    waiter.waiting = true;
    waiter.code = 0;
    return c.lua_yieldk(state, 0, @bitCast(@intFromPtr(waiter)), waiterResumed);
}

fn waiterResumed(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const waiter: *Waiter = @ptrFromInt(@as(usize, @bitCast(context)));
    c.lua_pushinteger(state, waiter.code);
    return 1;
}

/// waiter_wake(waiter, code) -> boolean: resumes a parked task with `code`.
fn waiterWake(state: *c.State) callconv(.c) c_int {
    const waiter = waiterArgument(state);
    var valid: c_int = 0;
    const code = c.lua_tointegerx(state, 2, &valid);
    if (!waiter.waiting) {
        c.lua_pushboolean(state, 0);
        return 1;
    }
    waiter.waiting = false;
    waiter.code = code;
    waiter.vm.?.markExternalCompleted(waiter.handle) catch |err| return raiseText(state, @errorName(err));
    c.lua_pushboolean(state, 1);
    return 1;
}

fn waiterWaiting(state: *c.State) callconv(.c) c_int {
    c.lua_pushboolean(state, @intFromBool(waiterArgument(state).waiting));
    return 1;
}

const view_cache = "ouro.machine.view_cache";

fn pushMetatable(state: *c.State) void {
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
}

/// Push the weak-keyed table -> plain view cache (an ephemeron table: a view
/// references its table, and both go once nothing else holds the table).
fn pushCache(state: *c.State) void {
    if (c.lua_getfield(state, c.registry_index, view_cache) == c.type_table) return;
    c.lua_settop(state, -2);
    c.lua_createtable(state, 0, 0);
    c.lua_createtable(state, 0, 1);
    _ = c.lua_pushstring(state, "k");
    c.lua_setfield(state, -2, "__mode");
    _ = c.lua_setmetatable(state, -2);
    c.lua_pushvalue(state, -1);
    c.lua_setfield(state, c.registry_index, view_cache);
}

/// Replace the value at the top of the stack with its view when it is a
/// table. Plain views are cached per table, so repeated reads and iteration
/// do not allocate.
fn wrapTop(state: *c.State) void {
    if (c.lua_type(state, -1) != c.type_table) return;
    pushCache(state); // t, cache
    c.lua_pushvalue(state, -2);
    if (c.lua_rawget(state, -2) != c.type_nil) { // t, cache, view
        c.lua_rotate(state, -3, 1); // view, t, cache
        c.lua_settop(state, -3);
        return;
    }
    c.lua_settop(state, -2); // t, cache
    _ = c.lua_newuserdatauv(state, 0, 2); // t, cache, ud
    c.lua_pushvalue(state, -3);
    _ = c.lua_setiuservalue(state, -2, 1);
    pushMetatable(state);
    _ = c.lua_setmetatable(state, -2);
    c.lua_pushvalue(state, -3); // t, cache, ud, t
    c.lua_pushvalue(state, -2); // t, cache, ud, t, ud
    c.lua_rawset(state, -4); // t, cache, ud
    c.lua_rotate(state, -3, 1); // ud, t, cache
    c.lua_settop(state, -3);
}

/// tracked_view(t, hook) -> a read-only view whose field reads return
/// hook(t, key), and whose # and pairs first call hook(t, nil). Actors use it
/// to read the per-key signals behind a context or snapshot. Not cached.
fn trackedView(state: *c.State) callconv(.c) c_int {
    c.lua_settop(state, 2);
    if (c.lua_type(state, 1) != c.type_table or c.lua_type(state, 2) != c.type_function) {
        _ = c.lua_pushstring(state, "tracked_view expects a table and a hook");
        return c.lua_error(state);
    }
    _ = c.lua_newuserdatauv(state, 0, 2);
    c.lua_pushvalue(state, 1);
    _ = c.lua_setiuservalue(state, -2, 1);
    c.lua_pushvalue(state, 2);
    _ = c.lua_setiuservalue(state, -2, 2);
    pushMetatable(state);
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

/// Calls the tracked view's hook with (t, key) and leaves one result, or
/// returns false for plain views (nothing pushed).
fn callHook(state: *c.State, key: c_int) bool {
    if (c.lua_getiuservalue(state, 1, 2) != c.type_function) {
        c.lua_settop(state, -2);
        return false;
    }
    _ = c.lua_getiuservalue(state, 1, 1);
    if (key == 0) c.lua_pushnil(state) else c.lua_pushvalue(state, key);
    if (c.lua_pcallk(state, 2, 1, 0, 0, null) != c.ok) _ = c.lua_error(state);
    return true;
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
    c.lua_settop(state, 2);
    if (callHook(state, 2)) return 1;
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
    c.lua_settop(state, 1);
    if (callHook(state, 0)) c.lua_settop(state, 1);
    _ = pushTarget(state, 1);
    c.lua_pushinteger(state, @intCast(c.lua_rawlen(state, -1)));
    return 1;
}

fn pairs(state: *c.State) callconv(.c) c_int {
    c.lua_settop(state, 1);
    if (callHook(state, 0)) c.lua_settop(state, 1); // Iteration depends on every key.
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
    // Tracked views yield what their hook returns for each key, so iterating
    // snapshot.children yields each child's own tracked view.
    if (c.lua_getiuservalue(state, 1, 2) == c.type_function) { // t, k, v, hook
        c.lua_rotate(state, -2, 1); // t, k, hook, v
        c.lua_settop(state, -2); // t, k, hook
        c.lua_pushvalue(state, 3); // t, k, hook, t
        c.lua_pushvalue(state, 4); // t, k, hook, t, k
        if (c.lua_pcallk(state, 2, 1, 0, 0, null) != c.ok) return c.lua_error(state);
        return 2; // k, hook(t, k)
    }
    c.lua_settop(state, -2);
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
