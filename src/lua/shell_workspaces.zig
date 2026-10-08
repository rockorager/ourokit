const std = @import("std");
const c = @import("c.zig");
const signals_module = @import("signals.zig");
const workspaces = @import("../shell/workspaces.zig");
const task_root = @import("../task/root.zig");
const vm_module = @import("vm.zig");

const session_metatable = "ouro.shell.workspaces.session.v1";
const watcher_metatable = "ouro.shell.workspaces.watcher.v1";

/// One `ouro.shell.workspaces.watch()` stream. Lua owns the memory; a task
/// parked in `next` keeps it alive, and the binding links it only while open.
const Watcher = struct {
    owner: ?*Binding,
    previous: ?*Watcher = null,
    next: ?*Watcher = null,
    /// Store revision last returned by `next`; null until the first call.
    seen: ?u64 = null,
    handle: vm_module.TaskHandle = .invalid,
    vm: ?*vm_module.Vm = null,
    waiting: bool = false,
    canceled: bool = false,

    fn unlink(self: *Watcher) void {
        const owner = self.owner orelse return;
        if (self.previous) |previous| previous.next = self.next else owner.watchers = self.next;
        if (self.next) |next| next.previous = self.previous;
        self.previous = null;
        self.next = null;
        self.owner = null;
    }

    fn wake(self: *Watcher, canceled: bool) !void {
        if (!self.waiting) return;
        self.waiting = false;
        self.canceled = canceled;
        try self.vm.?.markExternalCompleted(self.handle);
    }
};

const Session = struct {
    owner: *Binding,
    dependency: signals_module.SignalHandle,
};

/// One source-generation's reactive view of the process-owned workspace
/// store. Calling the returned session during a UI build subscribes that build
/// to snapshots published at ext-workspace-v1 `done` boundaries.
pub const Binding = struct {
    state: *c.State,
    signals: *signals_module.Signals,
    store: *workspaces.Store,
    connected: bool = false,
    dependency: ?signals_module.SignalHandle = null,
    seen_revision: u64 = 0,
    /// Open watch() streams. The protocol stays unbound until the first
    /// connect() or watch(); with no watcher parked, sync wakes nothing.
    watchers: ?*Watcher = null,
    watched: bool = false,

    pub fn init(
        self: *Binding,
        state: *c.State,
        signals: *signals_module.Signals,
        store: *workspaces.Store,
        api_reference: c_int,
    ) !void {
        self.* = .{
            .state = state,
            .signals = signals,
            .store = store,
            .seen_revision = store.revision,
        };
        try self.install(api_reference);
    }

    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.dependency == null);
        // Lua closes before the binding, collecting every watcher.
        std.debug.assert(self.watchers == null);
        self.* = undefined;
    }

    pub fn requested(self: *const Binding) bool {
        return self.connected or self.watched;
    }

    /// Task safe point: publish a new `done` snapshot to the reactive session
    /// and resume every watcher parked in `next`.
    pub fn sync(self: *Binding) !void {
        if (self.seen_revision == self.store.revision) return;
        self.seen_revision = self.store.revision;
        if (self.connected) try self.signals.publishExternal(self.dependency.?);
        var watcher = self.watchers;
        while (watcher) |current| : (watcher = current.next) try current.wake(false);
    }

    fn install(self: *Binding, api_reference: c_int) !void {
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        if (c.lua_rawgeti(self.state, c.registry_index, api_reference) != c.type_table)
            return error.OuroApiMissing;

        c.lua_createtable(self.state, 0, 1);
        c.lua_createtable(self.state, 0, 5);
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, connect, 1);
        c.lua_setfield(self.state, -2, "connect");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, watch, 1);
        c.lua_setfield(self.state, -2, "watch");
        inline for (.{ "activate", "deactivate", "remove" }, 0..) |name, kind| {
            c.lua_pushlightuserdata(self.state, self);
            c.lua_pushinteger(self.state, kind);
            c.lua_pushcclosure(self.state, requestByHandle, 2);
            c.lua_setfield(self.state, -2, name);
        }
        c.lua_setfield(self.state, -2, "workspaces");
        c.lua_setfield(self.state, -2, "shell");

        _ = c.luaL_newmetatable(self.state, watcher_metatable);
        c.lua_createtable(self.state, 0, 2);
        c.lua_pushcclosure(self.state, watcherNext, 0);
        c.lua_setfield(self.state, -2, "next");
        c.lua_pushcclosure(self.state, watcherClose, 0);
        c.lua_setfield(self.state, -2, "close");
        c.lua_setfield(self.state, -2, "__index");
        c.lua_pushcclosure(self.state, watcherClose, 0);
        c.lua_setfield(self.state, -2, "__close");
        c.lua_pushcclosure(self.state, watcherClose, 0);
        c.lua_setfield(self.state, -2, "__gc");
        c.lua_pushboolean(self.state, 0);
        c.lua_setfield(self.state, -2, "__metatable");
        c.lua_settop(self.state, -2);

        _ = c.luaL_newmetatable(self.state, session_metatable);
        c.lua_pushcclosure(self.state, readSession, 0);
        c.lua_setfield(self.state, -2, "__call");
        c.lua_pushcclosure(self.state, collectSession, 0);
        c.lua_setfield(self.state, -2, "__gc");
    }

    /// `actions` adds activate/deactivate/remove closures (the reactive
    /// session). Without them the snapshot is plain data for charts: each
    /// workspace carries an opaque `handle` string for the request functions.
    fn pushSnapshot(self: *Binding, state: *c.State) void {
        self.pushSnapshotWith(state, true);
    }

    fn pushSnapshotWith(self: *Binding, state: *c.State, actions: bool) void {
        const snapshot = self.store.snapshot();
        c.lua_createtable(state, 0, 2);
        c.lua_pushboolean(state, @intFromBool(self.store.available));
        c.lua_setfield(state, -2, "available");
        c.lua_createtable(state, @intCast(snapshot.len), 0);
        for (snapshot, 0..) |workspace, index| {
            c.lua_createtable(state, 0, 14);
            if (workspace.id) |id| {
                _ = c.lua_pushlstring(state, id.ptr, id.len);
            } else c.lua_pushnil(state);
            c.lua_setfield(state, -2, "id");
            _ = c.lua_pushlstring(state, workspace.name.ptr, workspace.name.len);
            c.lua_setfield(state, -2, "name");
            c.lua_createtable(state, @intCast(workspace.coordinates.len), 0);
            for (workspace.coordinates, 0..) |coordinate, coordinate_index| {
                c.lua_pushinteger(state, coordinate);
                c.lua_rawseti(state, -2, @intCast(coordinate_index + 1));
            }
            c.lua_setfield(state, -2, "coordinates");
            c.lua_createtable(state, @intCast(workspace.outputs.len), 0);
            for (workspace.outputs, 0..) |output, output_index| {
                _ = c.lua_pushlstring(state, output.ptr, output.len);
                c.lua_rawseti(state, -2, @intCast(output_index + 1));
            }
            c.lua_setfield(state, -2, "outputs");
            setBoolean(state, "active", workspace.state.active);
            setBoolean(state, "urgent", workspace.state.urgent);
            setBoolean(state, "hidden", workspace.state.hidden);
            setBoolean(state, "can_activate", workspace.capabilities.activate);
            setBoolean(state, "can_deactivate", workspace.capabilities.deactivate);
            setBoolean(state, "can_remove", workspace.capabilities.remove);
            if (actions) {
                self.pushAction(state, workspace.handle, .activate);
                c.lua_setfield(state, -2, "activate");
                self.pushAction(state, workspace.handle, .deactivate);
                c.lua_setfield(state, -2, "deactivate");
                self.pushAction(state, workspace.handle, .remove);
                c.lua_setfield(state, -2, "remove");
            } else {
                var buffer: [48]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "{d}:{d}", .{ workspace.handle.slot, workspace.handle.generation }) catch unreachable;
                _ = c.lua_pushlstring(state, text.ptr, text.len);
                c.lua_setfield(state, -2, "handle");
            }
            c.lua_rawseti(state, -2, @intCast(index + 1));
        }
        c.lua_setfield(state, -2, "workspaces");
    }

    fn pushAction(
        self: *Binding,
        state: *c.State,
        workspace: workspaces.WorkspaceHandle,
        kind: workspaces.ActionKind,
    ) void {
        c.lua_pushlightuserdata(state, self);
        c.lua_pushinteger(state, workspace.slot);
        c.lua_pushinteger(state, workspace.generation);
        c.lua_pushinteger(state, @intFromEnum(kind));
        c.lua_pushcclosure(state, requestAction, 4);
    }
};

fn connect(state: *c.State) callconv(.c) c_int {
    const self = bindingFromUpvalue(state, 1) orelse
        return luaError(state, "missing Ouro workspace binding");
    if (c.lua_gettop(state) != 0)
        return luaError(state, "ouro.shell.workspaces.connect expects no arguments");
    if (self.connected)
        return luaError(state, "ouro.shell.workspaces.connect may only be called once");
    const dependency = self.signals.createExternal() catch
        return luaError(state, "signal capacity exceeded");
    const memory = c.lua_newuserdatauv(state, @sizeOf(Session), 0) orelse {
        self.signals.releaseExternal(dependency);
        return luaError(state, "cannot allocate workspace session");
    };
    const session: *Session = @ptrCast(@alignCast(memory));
    session.* = .{ .owner = self, .dependency = dependency };
    self.connected = true;
    self.dependency = dependency;
    self.seen_revision = self.store.revision;
    _ = c.lua_getfield(state, c.registry_index, session_metatable);
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

/// watch() -> watcher. `watcher:next()` returns the current snapshot first,
/// then parks the calling task until the next `done` batch. Snapshots are
/// plain data, so a statechart can keep them in context. Close the watcher
/// (or let its task's scope end) to stop.
fn watch(state: *c.State) callconv(.c) c_int {
    const self = bindingFromUpvalue(state, 1) orelse
        return luaError(state, "missing Ouro workspace binding");
    if (c.lua_gettop(state) != 0)
        return luaError(state, "ouro.shell.workspaces.watch expects no arguments");
    const watcher: *Watcher = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(Watcher), 0) orelse
        return luaError(state, "cannot allocate workspace watcher")));
    watcher.* = .{ .owner = self, .next = self.watchers };
    if (self.watchers) |head| head.previous = watcher;
    self.watchers = watcher;
    self.watched = true;
    _ = c.lua_getfield(state, c.registry_index, watcher_metatable);
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

fn watcherArgument(state: *c.State) ?*Watcher {
    const memory = c.luaL_testudata(state, 1, watcher_metatable) orelse return null;
    return @ptrCast(@alignCast(memory));
}

fn watcherNext(state: *c.State) callconv(.c) c_int {
    const watcher = watcherArgument(state) orelse return luaError(state, "workspace watcher expected");
    const owner = watcher.owner orelse return luaError(state, "workspace watcher is closed");
    if (watcher.waiting) return luaError(state, "workspace watcher is already waiting");
    if (watcher.seen == null or watcher.seen.? != owner.store.revision) {
        watcher.seen = owner.store.revision;
        owner.pushSnapshotWith(state, false);
        return 1;
    }
    const vm = vm_module.Vm.fromState(state) orelse return luaError(state, "workspace watch needs an Ouro task");
    watcher.handle = vm.beginExternalWait(state, .operation, watcher, &watcher_lifecycle) catch |err| return switch (err) {
        error.YieldInAtomicSection => luaError(state, "YieldInAtomicSection: workspace watcher next"),
        else => luaError(state, "workspace watcher next must run in an Ouro task"),
    };
    watcher.vm = vm;
    watcher.waiting = true;
    watcher.canceled = false;
    return c.lua_yieldk(state, 0, @bitCast(@intFromPtr(watcher)), watcherResumed);
}

fn watcherResumed(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const watcher: *Watcher = @ptrFromInt(@as(usize, @bitCast(context)));
    if (watcher.canceled) return luaError(state, "workspace watch canceled");
    const owner = watcher.owner orelse return luaError(state, "workspace watcher is closed");
    watcher.seen = owner.store.revision;
    owner.pushSnapshotWith(state, false);
    return 1;
}

fn watcherClose(state: *c.State) callconv(.c) c_int {
    const watcher = watcherArgument(state) orelse return 0;
    // A task parked in another coroutine resumes with an error.
    watcher.wake(true) catch {};
    watcher.unlink();
    return 0;
}

fn watcherCancel(context: *anyopaque) !void {
    const watcher: *Watcher = @ptrCast(@alignCast(context));
    try watcher.wake(true);
}

fn watcherDestroy(_: *anyopaque) void {} // Lua owns the watcher.

const watcher_lifecycle: task_root.ResourceLifecycle = .{ .request_cancel = watcherCancel, .destroy = watcherDestroy };

/// activate/deactivate/remove(handle) for a `handle` from a watch snapshot.
fn requestByHandle(state: *c.State) callconv(.c) c_int {
    const self = bindingFromUpvalue(state, 1) orelse
        return luaError(state, "missing Ouro workspace binding");
    const kind: workspaces.ActionKind = switch (integerUpvalue(state, 2) orelse 9) {
        0 => .activate,
        1 => .deactivate,
        2 => .remove,
        else => return luaError(state, "invalid workspace action"),
    };
    var length: usize = 0;
    const text = if (c.lua_type(state, 1) == c.type_string) c.lua_tolstring(state, 1, &length).?[0..length] else return luaError(state, "workspace request expects a workspace handle string");
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return luaError(state, "invalid workspace handle");
    const slot = std.fmt.parseInt(u32, text[0..colon], 10) catch return luaError(state, "invalid workspace handle");
    const generation = std.fmt.parseInt(u32, text[colon + 1 ..], 10) catch return luaError(state, "invalid workspace handle");
    self.store.request(.{ .workspace = .{ .slot = slot, .generation = generation }, .kind = kind }) catch |err| return switch (err) {
        error.StaleWorkspace => luaError(state, "workspace is no longer available"),
        error.WorkspaceActionCapacityExceeded => luaError(state, "workspace action capacity exceeded"),
    };
    return 0;
}

fn readSession(state: *c.State) callconv(.c) c_int {
    const session = sessionFromArgument(state) orelse
        return luaError(state, "invalid workspace session");
    if (c.lua_gettop(state) != 1)
        return luaError(state, "workspace session expects no arguments");
    session.owner.signals.readExternal(session.dependency) catch
        return luaError(state, "cannot track workspace state read");
    session.owner.pushSnapshot(state);
    return 1;
}

fn collectSession(state: *c.State) callconv(.c) c_int {
    const session = sessionFromArgument(state) orelse return 0;
    if (session.owner.dependency) |dependency| {
        if (sameHandle(dependency, session.dependency)) {
            session.owner.signals.releaseExternal(dependency);
            session.owner.dependency = null;
            session.owner.connected = false;
        }
    }
    session.dependency = .invalid;
    return 0;
}

fn requestAction(state: *c.State) callconv(.c) c_int {
    const self = bindingFromUpvalue(state, 1) orelse
        return luaError(state, "missing Ouro workspace binding");
    const slot = integerUpvalue(state, 2) orelse return luaError(state, "invalid workspace action");
    const generation = integerUpvalue(state, 3) orelse return luaError(state, "invalid workspace action");
    const action_value = integerUpvalue(state, 4) orelse return luaError(state, "invalid workspace action");
    const kind: workspaces.ActionKind = switch (action_value) {
        0 => .activate,
        1 => .deactivate,
        2 => .remove,
        else => return luaError(state, "invalid workspace action"),
    };
    self.store.request(.{
        .workspace = .{ .slot = @intCast(slot), .generation = @intCast(generation) },
        .kind = kind,
    }) catch |err| return switch (err) {
        error.StaleWorkspace => luaError(state, "workspace is no longer available"),
        error.WorkspaceActionCapacityExceeded => luaError(state, "workspace action capacity exceeded"),
    };
    return 0;
}

fn bindingFromUpvalue(state: *c.State, index: c_int) ?*Binding {
    const pointer = c.lua_touserdata(state, c.upvalueIndex(index)) orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn integerUpvalue(state: *c.State, index: c_int) ?u64 {
    var is_integer: c_int = 0;
    const value = c.lua_tointegerx(state, c.upvalueIndex(index), &is_integer);
    if (is_integer == 0 or value < 0) return null;
    return @intCast(value);
}

fn sessionFromArgument(state: *c.State) ?*Session {
    const memory = c.luaL_testudata(state, 1, session_metatable) orelse return null;
    return @ptrCast(@alignCast(memory));
}

fn setBoolean(state: *c.State, name: [*:0]const u8, value: bool) void {
    c.lua_pushboolean(state, @intFromBool(value));
    c.lua_setfield(state, -2, name);
}

fn sameHandle(a: signals_module.SignalHandle, b: signals_module.SignalHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "workspace connection exposes snapshots and queues actions" {
    const io = @import("../loop/io_uring.zig");
    const task = @import("../task/scheduler.zig");
    const Vm = @import("vm.zig").Vm;

    var store: workspaces.Store = undefined;
    try store.init(std.testing.allocator, 2, 2);
    defer store.deinit();
    const workspace = try store.create();
    try store.setId(workspace, "persistent-one");
    try store.setName(workspace, "One");
    try store.setCoordinates(workspace, &.{ 2, 3 });
    try store.setOutputs(workspace, &.{ "DP-1", "HDMI-A-1" });
    try store.setState(workspace, .{ .active = true });
    try store.setCapabilities(workspace, .{ .activate = true });
    try store.commit();

    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 2, 0);
    defer scheduler.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    var signals: signals_module.Signals = undefined;
    try signals.initWithApi(std.testing.allocator, vm.state, 4, 4, 4, vm.apiReference());
    var binding: Binding = undefined;
    try binding.init(vm.state, &signals, &store, vm.apiReference());
    defer {
        vm.deinit();
        binding.deinit();
        signals.deinit();
    }

    _ = try vm.spawnApplication(
        \\local ouro = require("ouro")
        \\local session = ouro.shell.workspaces.connect()
        \\local snapshot = session()
        \\local workspace = snapshot.workspaces[1]
        \\workspace_ok = snapshot.available and workspace.id == "persistent-one"
        \\  and workspace.name == "One" and workspace.coordinates[1] == 2
        \\  and workspace.outputs[1] == "DP-1" and workspace.outputs[2] == "HDMI-A-1"
        \\  and workspace.active and workspace.can_activate
        \\workspace.activate()
    );
    while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);

    try std.testing.expect(binding.requested());
    try std.testing.expect(vm.globalBoolean("workspace_ok"));
    const action = store.takeAction().?;
    try std.testing.expectEqual(workspaces.ActionKind.activate, action.kind);
    try std.testing.expect(sameWorkspaceHandle(workspace, action.workspace));
}

fn sameWorkspaceHandle(a: workspaces.WorkspaceHandle, b: workspaces.WorkspaceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "workspace watchers stream plain snapshots at done boundaries" {
    const io = @import("../loop/io_uring.zig");
    const scheduler_module = @import("../task/scheduler.zig");
    const Vm = vm_module.Vm;

    var store: workspaces.Store = undefined;
    try store.init(std.testing.allocator, 2, 2);
    defer store.deinit();
    const workspace = try store.create();
    try store.setName(workspace, "One");
    try store.setCapabilities(workspace, .{ .activate = true });
    try store.commit();

    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var scheduler: scheduler_module.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 4, 4);
    defer scheduler.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    var signals: signals_module.Signals = undefined;
    try signals.initWithApi(std.testing.allocator, vm.state, 4, 4, 4, vm.apiReference());
    var binding: Binding = undefined;
    try binding.init(vm.state, &signals, &store, vm.apiReference());
    defer {
        vm.deinit();
        binding.deinit();
        signals.deinit();
    }
    // Nobody watches: the protocol stays unbound and sync wakes nothing.
    try std.testing.expect(!binding.requested());

    _ = try vm.spawnApplication(
        \\local ouro = require("ouro")
        \\local watch <close> = ouro.shell.workspaces.watch()
        \\local first = watch:next()
        \\first_ok = first.available and first.workspaces[1].name == "One"
        \\  and type(first.workspaces[1].handle) == "string" and first.workspaces[1].activate == nil
        \\parked = true
        \\local second = watch:next()
        \\second_name = second.workspaces[1].name
        \\ouro.shell.workspaces.activate(second.workspaces[1].handle)
        \\stale_rejected = not pcall(ouro.shell.workspaces.activate, '99:1')
    );
    _ = try vm.spawnApplication(
        \\canceled_watch = require("ouro").shell.workspaces.watch()
        \\canceled_watch:next()
        \\local ok, err = pcall(canceled_watch.next, canceled_watch)
        \\canceled_message = tostring(err)
    );
    while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);
    try std.testing.expect(binding.requested());
    try std.testing.expect(vm.globalBoolean("first_ok"));
    try std.testing.expect(vm.globalBoolean("parked"));
    try std.testing.expect(!vm.hasGlobal("second_name"));

    // A revision that sync has already seen wakes nobody.
    try binding.sync();
    try std.testing.expectEqual(@as(?scheduler_module.TaskHandle, null), scheduler.takeRunnable());

    // Closing a watcher from another task resumes its parked task with an error.
    _ = try vm.spawnApplication("canceled_watch:close()");
    while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);
    _ = try vm.spawnApplication("assert(canceled_message:find('workspace watch canceled'), canceled_message) cancel_ok = true");
    while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);
    try std.testing.expect(vm.globalBoolean("cancel_ok"));

    try store.setName(workspace, "Renamed");
    try binding.sync(); // Not yet committed: no done boundary.
    try std.testing.expect(!vm.hasGlobal("second_name"));
    try store.commit();
    try binding.sync();
    while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);
    var name_length: usize = 0;
    _ = c.lua_getglobal(vm.state, "second_name");
    try std.testing.expectEqualStrings("Renamed", c.lua_tolstring(vm.state, -1, &name_length).?[0..name_length]);
    c.lua_settop(vm.state, -2);
    try std.testing.expect(vm.globalBoolean("stale_rejected"));
    const action = store.takeAction().?;
    try std.testing.expectEqual(workspaces.ActionKind.activate, action.kind);
    try std.testing.expect(sameWorkspaceHandle(workspace, action.workspace));
}
