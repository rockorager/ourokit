const std = @import("std");
const c = @import("c.zig");
const vm = @import("vm.zig");
const task = @import("../task/root.zig");
const model = @import("../shell/session.zig");
const metatable = "ouro.session.resource.v1";
const Resource = struct { owner: *Binding, handle: model.Handle, kind: model.Kind };
const Wait = struct {
    owner: *Binding = undefined,
    handle: model.Handle = .invalid,
    task_handle: vm.TaskHandle = .invalid,
    active: bool = false,
    canceled: bool = false,
    result: ?model.Event = null,
};

pub const Binding = struct {
    vm: *vm.Vm,
    store: *model.Store,
    waits: [model.capacity]Wait = @splat(.{}),
    owned: [model.capacity]?model.Handle = @splat(null),
    stopping: bool = false,
    candidate: bool = false,

    pub fn init(self: *Binding, machine: *vm.Vm, store: *model.Store) !void {
        self.* = .{ .vm = machine, .store = store };
        const L = machine.state;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        machine.pushApi(L);
        c.lua_createtable(L, 0, 4);
        inline for (.{ "idle", "power", "lock", "outputs" }, 0..) |name, index| {
            c.lua_pushlightuserdata(L, self);
            c.lua_pushinteger(L, index);
            c.lua_pushcclosure(L, create, 2);
            c.lua_setfield(L, -2, name);
        }
        c.lua_setfield(L, -2, "session");
        _ = c.luaL_newmetatable(L, metatable);
        c.lua_pushvalue(L, -1);
        c.lua_setfield(L, -2, "__index");
        inline for (.{ "next", "set", "unlock", "close", "__close", "__gc" }, .{ next, setPower, unlock, close, close, gc }) |name, function| {
            c.lua_pushcclosure(L, function, 0);
            c.lua_setfield(L, -2, name);
        }
    }

    pub fn sync(self: *Binding) !void {
        for (&self.waits) |*wait| {
            if (!wait.active and wait.result != null and self.vm.taskCancellationRequested(wait.task_handle)) wait.result = null;
            if (!wait.active) continue;
            const resource = self.store.get(wait.handle);
            if (wait.canceled or resource == null) {
                wait.result = .closed;
            } else if (resource.?.take()) |event| {
                wait.result = event;
            } else if (resource.?.terminal) {
                wait.result = .closed;
            } else if (self.store.outputChanged(resource.?)) {
                wait.result = .outputs;
            } else continue;
            wait.active = false;
            try self.vm.markExternalCompleted(wait.task_handle);
            if (wait.canceled or self.vm.taskCancellationRequested(wait.task_handle)) wait.result = null;
        }
    }

    pub fn stop(self: *Binding) void {
        self.stopping = true;
        for (self.owned) |handle| if (handle) |value| self.store.close(value, true);
        for (&self.waits) |*wait| if (wait.active) {
            wait.canceled = true;
        };
    }

    pub fn activate(self: *Binding) void {
        self.candidate = false;
        for (self.owned) |handle| if (handle) |value| {
            if (self.store.get(value)) |resource| resource.enabled = true;
        };
    }

    pub fn deinit(self: *Binding) void {
        self.stop();
        for (self.waits) |wait| std.debug.assert(!wait.active);
    }

    fn create(L: *c.State) callconv(.c) c_int {
        const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
        var valid_kind: c_int = 0;
        const kind: model.Kind = @enumFromInt(c.lua_tointegerx(L, c.upvalueIndex(2), &valid_kind));
        if (self.stopping) return fail(L, "GenerationStopping");
        if (self.candidate and kind == .lock) return fail(L, "SessionLockDuringReload");
        var timeout: u32 = 0;
        var input_only = false;
        var name: []const u8 = "";
        switch (kind) {
            .idle => {
                var valid: c_int = 0;
                const value = c.lua_tointegerx(L, 1, &valid);
                if (valid == 0 or value < 0 or value > std.math.maxInt(u32) or c.lua_gettop(L) > 2)
                    return fail(L, "idle expects milliseconds and optional input_only boolean");
                timeout = @intCast(value);
                if (c.lua_gettop(L) == 2 and c.lua_type(L, 2) != c.type_boolean) return fail(L, "input_only must be boolean");
                input_only = c.lua_toboolean(L, 2) != 0;
            },
            .power => {
                var len: usize = 0;
                if (c.lua_gettop(L) != 1 or c.lua_type(L, 1) != c.type_string) return fail(L, "power expects an output name");
                const bytes = c.lua_tolstring(L, 1, &len).?;
                if (len == 0 or len > 256 or std.mem.indexOfScalar(u8, bytes[0..len], 0) != null) return fail(L, "invalid output name");
                name = bytes[0..len];
            },
            .lock => if (c.lua_gettop(L) != 0) return fail(L, "lock expects no arguments"),
            .outputs => if (c.lua_gettop(L) != 0) return fail(L, "outputs expects no arguments"),
        }
        const memory = c.lua_newuserdatauv(L, @sizeOf(Resource), 0).?;
        const resource: *Resource = @ptrCast(@alignCast(memory));
        const handle = self.store.create(kind) catch |err| return fail(L, @errorName(err));
        const native = self.store.get(handle).?;
        native.enabled = !self.candidate;
        native.timeout_ms = timeout;
        native.input_only = input_only;
        @memcpy(native.output[0..name.len], name);
        native.output_len = name.len;
        resource.* = .{ .owner = self, .handle = handle, .kind = kind };
        self.owned[handle.slot] = handle;
        _ = c.lua_getfield(L, c.registry_index, metatable);
        _ = c.lua_setmetatable(L, -2);
        return 1;
    }

    fn next(L: *c.State) callconv(.c) c_int {
        const r = argument(L) orelse return fail(L, "invalid session resource");
        const self = r.owner;
        const wait = &self.waits[r.handle.slot];
        if (wait.active or wait.result != null) return fail(L, "session resource already has a reader");
        const native = self.store.get(r.handle) orelse return push(L, .closed);
        if (native.take()) |event| return push(L, event);
        if (native.terminal or self.stopping) return push(L, .closed);
        if (self.store.outputChanged(native)) return push(L, .outputs);
        wait.* = .{ .owner = self, .handle = r.handle };
        wait.task_handle = self.vm.beginExternalWait(L, .operation, wait, &lifecycle) catch |err| return fail(L, @errorName(err));
        wait.active = true;
        return c.lua_yieldk(L, 0, @bitCast(@intFromPtr(wait)), continuation);
    }

    fn continuation(L: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
        const wait: *Wait = @ptrFromInt(@as(usize, @bitCast(context)));
        const event = wait.result orelse .closed;
        wait.result = null;
        return push(L, event);
    }

    fn setPower(L: *c.State) callconv(.c) c_int {
        const r = argument(L) orelse return fail(L, "invalid session resource");
        const native = r.owner.store.get(r.handle) orelse return fail(L, "resource closed");
        if (native.kind != .power or native.terminal or native.close_requested) return fail(L, "power control unavailable");
        if (c.lua_gettop(L) != 2 or c.lua_type(L, 2) != c.type_boolean) return fail(L, "set expects boolean power state");
        native.desired_power = c.lua_toboolean(L, 2) != 0;
        return 0;
    }

    fn unlock(L: *c.State) callconv(.c) c_int {
        const r = argument(L) orelse return fail(L, "invalid session resource");
        r.owner.store.unlock(r.handle) catch |err| return fail(L, @errorName(err));
        return 0;
    }

    fn close(L: *c.State) callconv(.c) c_int {
        const r = argument(L) orelse return 0;
        r.owner.store.close(r.handle, false);
        return 0;
    }

    fn gc(L: *c.State) callconv(.c) c_int {
        const r = argument(L) orelse return 0;
        r.owner.store.close(r.handle, true);
        return 0;
    }
};

fn argument(L: *c.State) ?*Resource {
    return @ptrCast(@alignCast(c.luaL_testudata(L, 1, metatable) orelse return null));
}
fn fail(L: *c.State, text: [*:0]const u8) c_int {
    _ = c.lua_pushstring(L, text);
    return c.lua_error(L);
}
fn push(L: *c.State, event: model.Event) c_int {
    const resource = argument(L).?;
    if (resource.kind == .outputs) {
        const store = resource.owner.store;
        const current = store.get(resource.handle);
        if (event != .outputs or current == null) {
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, if (event == .failed) "failed" else "closed");
            return 2;
        }
        current.?.output_revision = store.output_revision;
        c.lua_createtable(L, @intCast(store.output_count), 0);
        for (0..store.output_count) |i| {
            _ = c.lua_pushlstring(L, &store.output_names[i], store.output_lengths[i]);
            c.lua_rawseti(L, -2, @intCast(i + 1));
        }
        return 1;
    }
    const name = @tagName(event);
    _ = c.lua_pushlstring(L, name.ptr, name.len);
    return 1;
}
fn cancel(pointer: *anyopaque) !void {
    const wait: *Wait = @ptrCast(@alignCast(pointer));
    wait.canceled = true;
    wait.owner.store.close(wait.handle, false);
}
fn destroy(_: *anyopaque) void {}
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = cancel, .destroy = destroy };

test "session wait cancellation preserves lock and candidate resources stay inert" {
    const io = @import("../loop/io_uring.zig");
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 4, 4);
    defer scheduler.deinit();
    var machine: vm.Vm = undefined;
    try machine.init(std.testing.allocator, &scheduler, &loop);
    var store: model.Store = .{};
    var binding: Binding = undefined;
    try binding.init(&machine, &store);
    defer {
        machine.deinit();
        binding.deinit();
    }
    binding.candidate = true;
    _ = try machine.spawnApplication(
        \\local o = require('ouro')
        \\assert(not pcall(o.session.lock))
        \\assert(not pcall(o.session.idle, -1))
        \\assert(not pcall(o.session.idle, 4294967296))
        \\stream = o.session.idle(41, true)
    );
    while (scheduler.takeRunnable()) |handle| _ = try machine.resumeRunnable(handle);
    try std.testing.expect(!store.resources[0].enabled);
    binding.activate();
    try std.testing.expect(store.resources[0].enabled);
    _ = try machine.spawnApplication(
        \\local o = require('ouro')
        \\lock = o.session.lock()
        \\assert(lock:next() == 'locked')
        \\assert(lock:next() == 'unlocked')
        \\unexpected_unlock = true
    );
    while (scheduler.takeRunnable()) |handle| _ = try machine.resumeRunnable(handle);
    const lock = store.lock_handle.?;
    store.lock_state = .locked;
    store.get(lock).?.push(.locked);
    try binding.sync();
    while (scheduler.takeRunnable()) |handle| _ = try machine.resumeRunnable(handle);
    try machine.requestCancellation();
    try scheduler.applyQueuedCancellations();
    try binding.sync();
    while (scheduler.takeRunnable()) |handle| _ = try machine.resumeRunnable(handle);
    try std.testing.expect(!machine.globalBoolean("unexpected_unlock"));
    try std.testing.expectEqual(model.LockState.locked, store.lock_state);
    try std.testing.expect(!store.get(lock).?.close_requested);
    try std.testing.expectEqual(@as(usize, 0), machine.activeTaskCount());
}
