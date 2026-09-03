const std = @import("std");
const c = @import("c.zig");
const signals_module = @import("signals.zig");
const workspaces = @import("../shell/workspaces.zig");

const session_metatable = "ouro.shell.workspaces.session.v1";

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
        self.* = undefined;
    }

    pub fn requested(self: *const Binding) bool {
        return self.connected;
    }

    pub fn sync(self: *Binding) !void {
        if (!self.connected or self.seen_revision == self.store.revision) return;
        self.seen_revision = self.store.revision;
        try self.signals.publishExternal(self.dependency.?);
    }

    fn install(self: *Binding, api_reference: c_int) !void {
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        if (c.lua_rawgeti(self.state, c.registry_index, api_reference) != c.type_table)
            return error.OuroApiMissing;

        c.lua_createtable(self.state, 0, 1);
        c.lua_createtable(self.state, 0, 1);
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, connect, 1);
        c.lua_setfield(self.state, -2, "connect");
        c.lua_setfield(self.state, -2, "workspaces");
        c.lua_setfield(self.state, -2, "shell");

        _ = c.luaL_newmetatable(self.state, session_metatable);
        c.lua_pushcclosure(self.state, readSession, 0);
        c.lua_setfield(self.state, -2, "__call");
        c.lua_pushcclosure(self.state, collectSession, 0);
        c.lua_setfield(self.state, -2, "__gc");
    }

    fn pushSnapshot(self: *Binding, state: *c.State) void {
        const snapshot = self.store.snapshot();
        c.lua_createtable(state, 0, 2);
        c.lua_pushboolean(state, @intFromBool(self.store.available));
        c.lua_setfield(state, -2, "available");
        c.lua_createtable(state, @intCast(snapshot.len), 0);
        for (snapshot, 0..) |workspace, index| {
            c.lua_createtable(state, 0, 13);
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
            setBoolean(state, "active", workspace.state.active);
            setBoolean(state, "urgent", workspace.state.urgent);
            setBoolean(state, "hidden", workspace.state.hidden);
            setBoolean(state, "can_activate", workspace.capabilities.activate);
            setBoolean(state, "can_deactivate", workspace.capabilities.deactivate);
            setBoolean(state, "can_remove", workspace.capabilities.remove);
            self.pushAction(state, workspace.handle, .activate);
            c.lua_setfield(state, -2, "activate");
            self.pushAction(state, workspace.handle, .deactivate);
            c.lua_setfield(state, -2, "deactivate");
            self.pushAction(state, workspace.handle, .remove);
            c.lua_setfield(state, -2, "remove");
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
