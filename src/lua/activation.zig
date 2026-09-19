const std = @import("std");
const c = @import("c.zig");
const Vm = @import("vm.zig").Vm;
const Handle = @import("vm.zig").TaskHandle;
const task = @import("../task/scheduler.zig");
const platform = @import("../platform/activation.zig");

/// Owned by the callback's VM task, including the ready-but-not-resumed interval.
pub const Job = struct {
    vm: *Vm,
    handle: Handle = .invalid,
    provider: platform.Provider,
    request: platform.Request = undefined,
    pending: bool = false,
    token: ?[]u8 = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Job) void {
        std.debug.assert(!self.pending);
        if (self.token) |token| self.vm.allocator.free(token);
        self.vm.allocator.destroy(self);
    }

    fn complete(context: *anyopaque, result: anyerror![]const u8) !void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.pending = false;
        if (result) |token| {
            self.token = self.vm.allocator.dupe(u8, token) catch null;
            if (self.token == null) self.failure = error.OutOfMemory;
        } else |err| self.failure = err;
        try self.vm.markExternalCompleted(self.handle);
    }

    fn cancel(context: *anyopaque) !void {
        const self: *Job = @ptrCast(@alignCast(context));
        try self.provider.cancel(self.provider.context, &self.request);
        try complete(self, error.ActivationCanceled);
    }

    fn destroy(_: *anyopaque) void {} // The task owns the result through resume/cancel.
};

const lifecycle: task.ResourceLifecycle = .{ .request_cancel = Job.cancel, .destroy = Job.destroy };

pub fn request(state: *c.State) callconv(.c) c_int {
    const vm: *Vm = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    if (c.lua_gettop(state) != 0) return failure(state, error.InvalidActivationArguments);
    const input = vm.takeActivationInput(state) catch |err| return failure(state, err);
    const provider = vm.activation_provider orelse return failure(state, error.ActivationUnavailable);
    const job = vm.allocator.create(Job) catch return failure(state, error.OutOfMemory);
    job.* = .{ .vm = vm, .provider = provider };
    job.request = .{ .input = input, .context = job, .complete = Job.complete };
    job.handle = vm.beginExternalWait(state, .operation, job, &lifecycle) catch |err| {
        job.deinit();
        return failure(state, err);
    };
    provider.start(provider.context, &job.request) catch |err| {
        vm.abortExternalWait(state, job.handle) catch unreachable;
        job.deinit();
        return failure(state, err);
    };
    job.pending = true;
    vm.retainActivationJob(job.handle, job);
    return c.lua_yieldk(state, 0, @bitCast(@intFromPtr(job)), continuation);
}

fn continuation(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const job: *Job = @ptrFromInt(@as(usize, @bitCast(context)));
    if (job.failure) |err| return failure(state, err);
    const token = job.token.?;
    _ = c.lua_pushlstring(state, token.ptr, token.len);
    return 1;
}

fn failure(state: *c.State, err: anyerror) c_int {
    c.lua_pushnil(state);
    c.lua_createtable(state, 0, 2);
    const name = @errorName(err);
    _ = c.lua_pushlstring(state, name.ptr, name.len);
    c.lua_setfield(state, -2, "name");
    _ = c.lua_pushlstring(state, name.ptr, name.len);
    c.lua_setfield(state, -2, "message");
    return 2;
}
