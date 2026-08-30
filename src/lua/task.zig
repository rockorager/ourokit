const std = @import("std");
const c = @import("c.zig");
const io = @import("../loop/io_uring.zig");
const task = @import("../task/scheduler.zig");

/// One Lua application coroutine for milestone one. The object must retain a
/// stable address because the `ouro.sleep` closure stores its address as an
/// upvalue. No Lua standard library is opened or linked.
pub const Task = struct {
    scheduler: *task.Scheduler,
    loop: *io.Loop,
    state: *c.State,
    thread: ?*c.State = null,
    handle: ?task.TaskHandle = null,
    pending_timeout: ?io.OperationHandle = null,
    timer_resource_handle: ?task.ResourceHandle = null,
    timer_resource: TimerResource,
    requested_nanoseconds: u64 = 0,
    sleep_requested: bool = false,

    pub fn init(self: *Task, scheduler: *task.Scheduler, loop: *io.Loop) !void {
        const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
        self.* = .{
            .scheduler = scheduler,
            .loop = loop,
            .state = state,
            .timer_resource = .{ .owner = self },
        };
        c.lua_createtable(state, 0, 1);
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, sleep, 1);
        c.lua_setfield(state, -2, "sleep");
        c.lua_setglobal(state, "ouro");
    }

    pub fn deinit(self: *Task) void {
        std.debug.assert(self.handle == null and self.pending_timeout == null and self.timer_resource_handle == null);
        c.lua_close(self.state);
        self.* = undefined;
    }

    /// Loads a chunk and creates a runnable language-neutral task, but does not
    /// execute Lua. Execution is reserved for `resumeRunnable` in task phase.
    pub fn prepare(self: *Task, source: []const u8) !task.TaskHandle {
        if (self.thread != null) return error.TaskAlreadyPrepared;
        const thread = c.lua_newthread(self.state) orelse return error.LuaThreadCreationFailed;
        if (c.luaL_loadbufferx(thread, source.ptr, source.len, "@application", null) != c.ok)
            return error.LuaLoadFailed;
        const handle = try self.scheduler.createTask(self.scheduler.application_scope);
        self.thread = thread;
        self.handle = handle;
        return handle;
    }

    /// Must only be called after Scheduler.takeRunnable grants the task phase.
    pub fn resumeRunnable(self: *Task, handle: task.TaskHandle) !void {
        if (!same(self.handle orelse return error.StaleTask, handle)) return error.StaleTask;
        if (try self.scheduler.cancellationRequested(handle)) {
            if (self.pending_timeout != null) {
                try self.scheduler.wait(handle);
                return;
            }
            try self.scheduler.complete(handle);
            self.handle = null;
            return error.TaskCanceled;
        }
        self.sleep_requested = false;
        var result_count: c_int = 0;
        const status = c.lua_resume(self.thread.?, self.state, 0, &result_count);
        switch (status) {
            c.ok => {
                try self.scheduler.complete(handle);
                self.handle = null;
            },
            c.yield => {
                if (!self.sleep_requested) return error.UnsupportedYield;
                self.timer_resource_handle = try self.scheduler.registerResource(
                    self.scheduler.application_scope,
                    .timer,
                    &self.timer_resource,
                    &timer_lifecycle,
                );
                errdefer {
                    self.scheduler.destroyResource(self.timer_resource_handle.?) catch {};
                    self.timer_resource_handle = null;
                }
                self.pending_timeout = try self.loop.prepareTimeout(self.requested_nanoseconds);
                try self.scheduler.wait(handle);
            },
            else => return error.LuaRuntimeError,
        }
    }

    /// Completion phase state transition only. It cannot invoke `lua_resume`.
    pub fn markTimeoutCompleted(self: *Task, operation: io.OperationHandle) !void {
        const pending = self.pending_timeout orelse return error.StaleOperation;
        if (!same(pending, operation)) return error.StaleOperation;
        self.pending_timeout = null;
        try self.scheduler.destroyResource(self.timer_resource_handle.?);
        self.timer_resource_handle = null;
        try self.scheduler.markRunnable(self.handle.?);
    }

    pub fn hasGlobal(self: *Task, name: [*:0]const u8) bool {
        const value_type = c.lua_getglobal(self.state, name);
        c.lua_settop(self.state, -2);
        return value_type != c.type_nil;
    }

    pub fn globalBoolean(self: *Task, name: [*:0]const u8) bool {
        _ = c.lua_getglobal(self.state, name);
        const value = c.lua_toboolean(self.state, -1) != 0;
        c.lua_settop(self.state, -2);
        return value;
    }

    fn sleep(state: *c.State) callconv(.c) c_int {
        const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse return luaError(state, "missing Ouro task");
        const self: *Task = @ptrCast(@alignCast(pointer));
        var is_number: c_int = 0;
        const milliseconds = c.lua_tointegerx(state, 1, &is_number);
        if (is_number == 0 or milliseconds < 0) return luaError(state, "ouro.sleep expects non-negative milliseconds");
        self.requested_nanoseconds = std.math.mul(u64, @intCast(milliseconds), std.time.ns_per_ms) catch
            return luaError(state, "ouro.sleep duration is too large");
        self.sleep_requested = true;
        return c.lua_yieldk(state, 0, 0, sleepContinuation);
    }

    fn sleepContinuation(_: *c.State, _: c_int, _: c.KContext) callconv(.c) c_int {
        return 0;
    }

    fn luaError(state: *c.State, message: [*:0]const u8) c_int {
        _ = c.lua_pushstring(state, message);
        return c.lua_error(state);
    }

    const TimerResource = struct {
        owner: *Task,

        fn requestCancel(pointer: *anyopaque) !void {
            const resource: *TimerResource = @ptrCast(@alignCast(pointer));
            try resource.owner.loop.prepareCancel(resource.owner.pending_timeout.?);
        }

        fn destroy(_: *anyopaque) void {}
    };

    const timer_lifecycle: task.ResourceLifecycle = .{
        .request_cancel = TimerResource.requestCancel,
        .destroy = TimerResource.destroy,
    };
};

fn same(a: @import("../core/handle.zig").Handle, b: @import("../core/handle.zig").Handle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
