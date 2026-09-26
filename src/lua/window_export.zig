const std = @import("std");
const c = @import("c.zig");
const Vm = @import("vm.zig").Vm;
const task = @import("../task/scheduler.zig");
const platform = @import("../platform/window_export.zig");

const metatable = "ouro.window_export";

pub const Job = struct {
    vm: *Vm,
    handle: @import("vm.zig").TaskHandle = .invalid,
    provider: platform.Provider,
    request: platform.Request = undefined,
    pending: bool = false,
    result: ?platform.Export = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Job) void {
        std.debug.assert(!self.pending);
        if (self.result) |*result| result.close();
        self.vm.allocator.destroy(self);
    }
    fn complete(context: *anyopaque, result: anyerror!platform.Export) !void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.pending = false;
        if (result) |value| self.result = value else |err| self.failure = err;
        try self.vm.markExternalCompleted(self.handle);
    }
    fn cancel(context: *anyopaque) !void {
        const self: *Job = @ptrCast(@alignCast(context));
        try self.provider.cancel(self.provider.context, &self.request);
        try complete(self, error.WindowExportCanceled);
    }
    fn destroy(_: *anyopaque) void {}
};
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = Job.cancel, .destroy = Job.destroy };

pub fn request(L: *c.State) callconv(.c) c_int {
    const vm: *Vm = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
    var len: usize = 0;
    if (c.lua_gettop(L) != 1 or c.lua_type(L, 1) != c.type_string) return fail(L, error.InvalidWindowId);
    const id = c.lua_tolstring(L, 1, &len).?[0..len];
    const provider = vm.window_export_provider orelse return fail(L, error.WindowExportUnavailable);
    const job = vm.allocator.create(Job) catch return fail(L, error.OutOfMemory);
    job.* = .{ .vm = vm, .provider = provider };
    job.request = .{ .context = job, .complete = Job.complete };
    job.handle = vm.beginExternalWait(L, .operation, job, &lifecycle) catch |err| {
        job.deinit();
        return fail(L, err);
    };
    provider.start(provider.context, id, &job.request) catch |err| {
        vm.abortExternalWait(L, job.handle) catch unreachable;
        job.deinit();
        return fail(L, err);
    };
    job.pending = true;
    vm.retainWindowExportJob(job.handle, job);
    return c.lua_yieldk(L, 0, @bitCast(@intFromPtr(job)), continuation);
}

fn continuation(L: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const job: *Job = @ptrFromInt(@as(usize, @bitCast(context)));
    if (job.failure) |err| return fail(L, err);
    const guard: *?platform.Export = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(?platform.Export), 1).?));
    guard.* = job.result;
    job.result = null;
    _ = c.luaL_newmetatable(L, metatable);
    c.lua_pushcclosure(L, close, 0);
    c.lua_setfield(L, -2, "close");
    c.lua_pushcclosure(L, close, 0);
    c.lua_setfield(L, -2, "__close");
    c.lua_pushcclosure(L, close, 0);
    c.lua_setfield(L, -2, "__gc");
    c.lua_pushcclosure(L, index, 0);
    c.lua_setfield(L, -2, "__index");
    _ = c.lua_setmetatable(L, -2);
    c.lua_createtable(L, 0, 1);
    c.lua_pushcclosure(L, close, 0);
    c.lua_setfield(L, -2, "close");
    const value = guard.*.?.handle;
    _ = c.lua_pushlstring(L, value.ptr, value.len);
    c.lua_setfield(L, -2, "handle");
    _ = c.lua_setiuservalue(L, -2, 1);
    return 1;
}

fn index(L: *c.State) callconv(.c) c_int {
    _ = c.lua_getiuservalue(L, 1, 1);
    var len: usize = 0;
    const key = c.lua_tolstring(L, 2, &len) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    if (std.mem.eql(u8, key[0..len], "handle")) _ = c.lua_getfield(L, -1, "handle") else if (std.mem.eql(u8, key[0..len], "close")) _ = c.lua_getfield(L, -1, "close") else c.lua_pushnil(L);
    return 1;
}

fn close(L: *c.State) callconv(.c) c_int {
    const guard: *?platform.Export = @ptrCast(@alignCast(c.luaL_testudata(L, 1, metatable) orelse return 0));
    if (guard.*) |*value| value.close();
    guard.* = null;
    return 0;
}

fn fail(L: *c.State, err: anyerror) c_int {
    c.lua_pushnil(L);
    c.lua_createtable(L, 0, 2);
    const name = @errorName(err);
    _ = c.lua_pushlstring(L, name.ptr, name.len);
    c.lua_setfield(L, -2, "name");
    _ = c.lua_pushlstring(L, name.ptr, name.len);
    c.lua_setfield(L, -2, "message");
    return 2;
}

test "window exports replace completed jobs and reject handle misuse" {
    const io = @import("../loop/root.zig");
    const Fake = struct {
        requests: [2]?*platform.Request = .{ null, null },
        started: usize = 0,
        canceled: usize = 0,
        closed: usize = 0,

        fn start(context: *anyopaque, _: []const u8, request_: *platform.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.requests[self.started] = request_;
            self.started += 1;
        }
        fn cancel(context: *anyopaque, request_: *platform.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (&self.requests) |*entry| {
                if (entry.* == request_) entry.* = null;
            }
            self.canceled += 1;
        }
        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed += 1;
        }
        fn finish(self: *@This(), request_index: usize, value: []const u8) !void {
            const request_ = self.requests[request_index].?;
            self.requests[request_index] = null;
            try request_.complete(request_.context, .{ .context = self, .handle = value, .closeFn = @This().close });
        }
    };
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 4, 4);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var fake: Fake = .{};
    vm.window_export_provider = .{ .context = &fake, .start = Fake.start, .cancel = Fake.cancel };

    _ = try vm.spawnApplication(
        \\local o=require('ouro')
        \\local a=assert(o._desktop_parent('a')); assert(a.handle == 'one')
        \\local b=assert(o._desktop_parent('b')); assert(b.handle == 'two')
        \\local close=b.close; close({}); b:close(); b:close()
        \\assert(b.handle == 'two'); done=true
    );
    try std.testing.expectEqual(@import("vm.zig").ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try fake.finish(0, "one");
    try std.testing.expectEqual(@import("vm.zig").ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
    // Starting the second export releases the completed first job, but not
    // the first lease now owned by Lua.
    try std.testing.expectEqual(@as(usize, 0), fake.closed);
    try fake.finish(1, "two");
    try std.testing.expectEqual(@import("vm.zig").ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(vm.globalBoolean("done"));
    try std.testing.expectEqual(@as(usize, 1), fake.closed);
}

test "window export cancellation closes pending and completed leases without continuation" {
    const io = @import("../loop/root.zig");
    const Fake = struct {
        request: ?*platform.Request = null,
        canceled: usize = 0,
        closed: usize = 0,
        fn start(context: *anyopaque, _: []const u8, request_: *platform.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.request = request_;
        }
        fn cancel(context: *anyopaque, _: *platform.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.request = null;
            self.canceled += 1;
        }
        fn close(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closed += 1;
        }
        fn finish(self: *@This()) !void {
            const request_ = self.request.?;
            self.request = null;
            try request_.complete(request_.context, .{ .context = self, .handle = "discarded", .closeFn = @This().close });
        }
    };
    inline for (.{ false, true }) |complete_first| {
        var scheduler: task.Scheduler = undefined;
        try scheduler.init(std.testing.allocator, 2, 4, 4);
        defer scheduler.deinit();
        var loop: io.Loop = undefined;
        try loop.init(std.testing.allocator, 8, 8);
        defer loop.deinit();
        var vm: Vm = undefined;
        try vm.init(std.testing.allocator, &scheduler, &loop);
        defer vm.deinit();
        var fake: Fake = .{};
        vm.window_export_provider = .{ .context = &fake, .start = Fake.start, .cancel = Fake.cancel };
        _ = try vm.spawnApplication("require('ouro')._desktop_parent('x'); resumed=true");
        _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
        if (complete_first) try fake.finish();
        try vm.requestCancellation();
        try std.testing.expectEqual(@import("vm.zig").ResumeResult.canceled, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expect(!vm.hasGlobal("resumed"));
        try std.testing.expectEqual(@as(usize, @intFromBool(!complete_first)), fake.canceled);
        try std.testing.expectEqual(@as(usize, @intFromBool(complete_first)), fake.closed);
    }
}
