//! Private task-scope binding for the statechart interpreter. The closures are
//! never installed on `ouro`; a loader passes them as chunk arguments to its
//! embedded Lua (the forms.zig/controls.lua pattern), so only that chunk can
//! open, spawn into, or close scopes.
//!
//!     local open, spawn, close, alive = ...
//!     local scope = open(parent?)      -- parent defaults to the running task's scope;
//!                                      -- 'application' parents it like spawn_app
//!     spawn(scope, fn, ...)            -- queue fn(...) as a task in scope; no handle
//!     close(scope)                     -- cancel the subtree; idempotent
//!     alive(scope)                     -- false once closed, canceled, or stale
//!
//! Scopes are owned by the source generation's VM, so reload retires them.
//! Errors are raised as strings beginning with the error name, for example
//! "ScopeCanceled: ...".
const std = @import("std");
const c = @import("c.zig");
const task = @import("../task/root.zig");
const Vm = @import("vm.zig").Vm;
const Argument = @import("vm.zig").Argument;

/// Values pushed by `pushChunkArguments`, in order: open, spawn, close, alive.
pub const chunk_argument_count = 4;
/// Extra arguments `spawn` forwards to the spawned function.
pub const max_spawn_arguments = 16;
const metatable = "ouro.task_scope";
const Userdata = struct { handle: task.ScopeHandle };

/// Pushes the four closures for an embedded loader chunk and returns
/// `chunk_argument_count`. Call with the chunk already on the stack, then add
/// the return value to the `lua_pcallk` argument count. A Lua state that has
/// no `Vm` (bare test states) receives four nils, so the chunk can fall back.
pub fn pushChunkArguments(state: *c.State) c_int {
    const vm = Vm.fromState(state);
    if (vm != null) {
        _ = c.luaL_newmetatable(state, metatable);
        c.lua_settop(state, -2);
    }
    inline for (.{ open, spawn, close, alive }) |function| {
        if (vm) |owner| {
            c.lua_pushlightuserdata(state, owner);
            c.lua_pushcclosure(state, function, 1);
        } else c.lua_pushnil(state);
    }
    return chunk_argument_count;
}

fn open(state: *c.State) callconv(.c) c_int {
    const vm = upvalueVm(state);
    const top = c.lua_gettop(state);
    if (top > 1) return raise(state, "InvalidArguments: open expects an optional parent scope");
    const parent: task.ScopeHandle = if (top == 0 or c.lua_type(state, 1) == c.type_nil)
        vm.currentScope(state) catch
            return raise(state, "NoParentScope: open needs a parent scope outside a running task")
    else if (c.lua_type(state, 1) == c.type_string) application: {
        // "application": like spawn_app, outlive the calling task (an MCP
        // action, a widget callback) but not generation retirement. Where
        // application spawns are unavailable (reload candidates, tests,
        // Storybook), use the running task's scope if there is one.
        var length: usize = 0;
        const name = c.lua_tolstring(state, 1, &length).?;
        if (!std.mem.eql(u8, name[0..length], "application"))
            return raise(state, "InvalidArguments: open expects an optional parent scope");
        if (vm.app_spawn_allowed) break :application vm.scheduler.application_scope;
        // Outside any task (an `ouroctl test` body, a Storybook module), the
        // host itself is the only owner left: use its application scope.
        break :application vm.currentScope(state) catch vm.scheduler.application_scope;
    } else (scopeArgument(state, 1) orelse
        return raise(state, "InvalidArguments: open expects an optional parent scope")).handle;
    // Allocate the userdata first so a Lua memory error cannot strand a scope.
    const userdata: *Userdata = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(Userdata), 0).?));
    userdata.* = .{ .handle = .invalid };
    _ = c.luaL_newmetatable(state, metatable);
    _ = c.lua_setmetatable(state, -2);
    userdata.handle = vm.openScope(parent) catch |err| return raiseScopeError(state, vm, err);
    return 1;
}

fn spawn(state: *c.State) callconv(.c) c_int {
    const vm = upvalueVm(state);
    const userdata = scopeArgument(state, 1) orelse
        return raise(state, "InvalidArguments: spawn expects a scope and a function");
    if (c.lua_type(state, 2) != c.type_function)
        return raise(state, "InvalidArguments: spawn expects a scope and a function");
    const count: usize = @intCast(c.lua_gettop(state) - 2);
    if (count > max_spawn_arguments)
        return raise(state, "InvalidArguments: spawn forwards at most 16 arguments");
    // Registry anchors are released before returning or raising.
    var references: [max_spawn_arguments + 1]c_int = undefined;
    var arguments: [max_spawn_arguments]Argument = undefined;
    for (0..count + 1) |index| {
        c.lua_pushvalue(state, @intCast(index + 2));
        references[index] = c.luaL_ref(state, c.registry_index);
    }
    for (arguments[0..count], references[1 .. count + 1]) |*argument, reference|
        argument.* = .{ .registry = reference };
    const result = vm.spawnReference(userdata.handle, references[0], arguments[0..count]);
    for (references[0 .. count + 1]) |reference| c.luaL_unref(state, c.registry_index, reference);
    _ = result catch |err| return raiseScopeError(state, vm, err);
    return 0;
}

fn close(state: *c.State) callconv(.c) c_int {
    const vm = upvalueVm(state);
    const userdata = scopeArgument(state, 1) orelse
        return raise(state, "InvalidArguments: close expects a scope");
    vm.closeScope(userdata.handle) catch |err| switch (err) {
        error.StaleScope => {},
        else => return raiseScopeError(state, vm, err),
    };
    return 0;
}

fn alive(state: *c.State) callconv(.c) c_int {
    const vm = upvalueVm(state);
    const userdata = scopeArgument(state, 1) orelse
        return raise(state, "InvalidArguments: alive expects a scope");
    const open_scope = vm.scheduler.scopeAcceptsResources(userdata.handle) catch false;
    c.lua_pushboolean(state, @intFromBool(open_scope));
    return 1;
}

fn upvalueVm(state: *c.State) *Vm {
    return @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
}

fn scopeArgument(state: *c.State, index: c_int) ?*Userdata {
    return @ptrCast(@alignCast(c.luaL_testudata(state, index, metatable) orelse return null));
}

fn raiseScopeError(state: *c.State, vm: *Vm, err: anyerror) c_int {
    var buffer: [192]u8 = undefined;
    const message = switch (err) {
        error.ScopeCapacityExceeded => std.fmt.bufPrintZ(
            &buffer,
            "ScopeCapacityExceeded: all {d} task scopes are in use; closed scopes are reused once their started tasks and I/O drain",
            .{vm.scheduler.scopeCapacity()},
        ),
        error.ScopeCanceled => std.fmt.bufPrintZ(&buffer, "ScopeCanceled: the scope or an enclosing scope is closed", .{}),
        error.StaleScope => std.fmt.bufPrintZ(&buffer, "StaleScope: the scope no longer exists", .{}),
        else => std.fmt.bufPrintZ(&buffer, "{s}", .{@errorName(err)}),
    } catch unreachable;
    return raise(state, message.ptr);
}

fn raise(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

const io = @import("../loop/io_uring.zig");

/// Loads a chunk that receives the closures exactly as an embedded loader
/// would, and stores them in the test-only global `scopes`.
fn installForTest(vm: *Vm) !void {
    const source = "local open, spawn, close, alive = ...; scopes = {open = open, spawn = spawn, close = close, alive = alive}";
    if (c.luaL_loadbufferx(vm.state, source, source.len, "=scope-test", "t") != c.ok) return error.TestLoadFailed;
    const count = pushChunkArguments(vm.state);
    if (c.lua_pcallk(vm.state, count, 0, 0, 0, null) != c.ok) return error.TestLoadFailed;
}

fn runAll(vm: *Vm, scheduler: *task.Scheduler) !void {
    try scheduler.applyQueuedCancellations();
    while (scheduler.takeRunnable()) |runnable| _ = try vm.resumeRunnable(runnable);
}

test "private scope closures open, spawn into, and close nested state scopes from Lua" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 8, 8);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    try installForTest(&vm);
    const baseline = scheduler.availableScopeCapacity();

    _ = try vm.spawnApplication(
        \\local ouro = require('ouro')
        \\for key in pairs(ouro) do assert(not key:find('scope'), key) end
        \\local open, spawn, close, alive = scopes.open, scopes.spawn, scopes.close, scopes.alive
        \\outer = open()
        \\inner = open(outer)
        \\sibling = open(nil)
        \\assert(alive(outer) and alive(inner) and alive(sibling))
        \\spawn(inner, function(a, b, c, ...)
        \\  received = a == 1 and b == nil and c == 'x' and select('#', ...) == 0
        \\  ouro.sleep(60000)
        \\  inner_resumed = true
        \\end, 1, nil, 'x')
        \\spawn(outer, function() ouro.sleep(60000); outer_resumed = true end)
        \\spawn(sibling, function() ouro.sleep(60000); sibling_resumed = true end)
        \\local function fails(prefix, ...)
        \\  local ok, err = pcall(...)
        \\  assert(not ok and err:find(prefix, 1, true) == 1, tostring(err))
        \\end
        \\fails('InvalidArguments', open, 42)
        \\fails('InvalidArguments', open, outer, outer)
        \\fails('InvalidArguments', spawn, outer)
        \\fails('InvalidArguments', spawn, {}, function() end)
        \\fails('InvalidArguments', spawn, outer, function() end, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17)
        \\fails('InvalidArguments', close, 'outer')
        \\fails('InvalidArguments', alive)
        \\assert(not received)
    );
    try runAll(&vm, &scheduler);
    try std.testing.expect(vm.globalBoolean("received"));
    try std.testing.expectEqual(@as(usize, 3), loop.timers.count());
    try std.testing.expectEqual(baseline - 3, scheduler.availableScopeCapacity());

    // State exit: closing the outer scope cancels the nested one too.
    _ = try vm.spawnApplication(
        \\local open, spawn, close, alive = scopes.open, scopes.spawn, scopes.close, scopes.alive
        \\close(outer)
        \\close(outer)
        \\assert(not alive(outer) and not alive(inner) and alive(sibling))
        \\local ok, err = pcall(spawn, inner, function() end)
        \\assert(not ok and err:find('ScopeCanceled', 1, true) == 1, err)
        \\ok, err = pcall(open, inner)
        \\assert(not ok and err:find('ScopeCanceled', 1, true) == 1, err)
    );
    try runAll(&vm, &scheduler);
    // Timers and kernel work are canceled at the next safe point.
    try std.testing.expectEqual(@as(usize, 3), loop.timers.count());
    try runAll(&vm, &scheduler);
    try std.testing.expectEqual(@as(usize, 1), loop.timers.count());
    try std.testing.expect(!vm.globalBoolean("inner_resumed") and !vm.globalBoolean("outer_resumed"));
    try std.testing.expectEqual(baseline - 1, scheduler.availableScopeCapacity());

    // Freed handles are stale: close is a no-op, spawn and open raise.
    _ = try vm.spawnApplication(
        \\local open, spawn, close, alive = scopes.open, scopes.spawn, scopes.close, scopes.alive
        \\close(inner)
        \\local ok, err = pcall(spawn, outer, function() end)
        \\assert(not ok and err:find('StaleScope', 1, true) == 1, err)
        \\stale_checked = true
    );
    try runAll(&vm, &scheduler);
    try std.testing.expect(vm.globalBoolean("stale_checked"));

    // Outside a task there is no implicit parent.
    _ = c.lua_getglobal(vm.state, "scopes");
    _ = c.lua_getfield(vm.state, -1, "open");
    try std.testing.expect(c.lua_pcallk(vm.state, 0, 1, 0, 0, null) != c.ok);
    var length: usize = 0;
    const message = c.lua_tolstring(vm.state, -1, &length).?;
    try std.testing.expect(std.mem.startsWith(u8, message[0..length], "NoParentScope"));
    c.lua_settop(vm.state, 0);

    // Generation retirement retires scopes the binding opened.
    try vm.requestCancellation();
    try runAll(&vm, &scheduler);
    try runAll(&vm, &scheduler);
    try std.testing.expect(!vm.globalBoolean("sibling_resumed"));
    try std.testing.expectEqual(baseline, scheduler.availableScopeCapacity());
    try std.testing.expectEqual(@as(usize, 0), loop.timers.count());
}

test "rapid state toggling reuses scopes immediately and capacity errors are diagnosable" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 4, 4);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    try installForTest(&vm);

    // Three free scopes, but ten thousand enter/exit cycles in one task turn:
    // work that never started is discarded when its state exits.
    _ = try vm.spawnApplication(
        \\local ouro = require('ouro')
        \\local open, spawn, close = scopes.open, scopes.spawn, scopes.close
        \\local machine = open()
        \\for i = 1, 10000 do
        \\  local state = open(machine)
        \\  spawn(state, function() error('work of an exited state ran') end)
        \\  spawn(state, function() ouro.sleep(1000) end)
        \\  close(state)
        \\end
        \\local held = {open(machine), open(machine)}
        \\local ok, err = pcall(open, machine)
        \\assert(not ok and err:find('^ScopeCapacityExceeded: all 4 task scopes are in use'), err)
        \\close(machine)
        \\toggled = true
    );
    try runAll(&vm, &scheduler);
    try std.testing.expect(vm.globalBoolean("toggled"));
    try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
    try std.testing.expectEqual(@as(usize, 3), scheduler.availableScopeCapacity());
    try std.testing.expectEqual(@as(usize, 0), loop.timers.count());
}

test "scope chunk arguments are nil in a Lua state without a VM" {
    const state = c.luaL_newstate().?;
    defer c.lua_close(state);
    const source = "local open, spawn, close, alive = ...; return open == nil and spawn == nil and close == nil and alive == nil";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source, source.len, "=bare", "t"));
    try std.testing.expectEqual(@as(c_int, chunk_argument_count), pushChunkArguments(state));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, chunk_argument_count, 1, 0, 0, null));
    try std.testing.expect(c.lua_toboolean(state, -1) != 0);
}
