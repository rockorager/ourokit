//! Yielding HTTP API. Native callbacks never enter Lua; only continuations
//! publish response tables, after the scheduler grants task-phase execution.
const std = @import("std");
const http = @import("../http/root.zig");
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

const Job = struct {
    owner: *Binding,
    request: http.Request,
    task_handle: vm_module.TaskHandle = .invalid,
    canceled: bool = false,
    published: bool = false,
};
const Kind = enum { request, get, post };

pub const Binding = struct {
    vm: *vm_module.Vm,
    client: http.Client,
    jobs: [http.capacity]?*Job = @splat(null),

    pub fn init(self: *Binding, vm: *vm_module.Vm, loop: *io.Loop) void {
        self.* = .{ .vm = vm, .client = http.Client.init(vm.allocator, loop) };
        const L = vm.state;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        vm.pushApi(L);
        c.lua_createtable(L, 0, 3);
        inline for (.{ Kind.request, Kind.get, Kind.post }) |kind| {
            c.lua_pushlightuserdata(L, self);
            c.lua_pushinteger(L, @intFromEnum(kind));
            c.lua_pushcclosure(L, call, 2);
            c.lua_setfield(L, -2, @tagName(kind));
        }
        c.lua_setfield(L, -2, "http");
    }

    pub fn dispatch(self: *Binding, completion: io.SocketCompletion) !bool {
        if (!try self.client.dispatch(completion)) return false;
        try self.collectCanceled();
        return true;
    }

    pub fn dispatchFile(self: *Binding, completion: io.FileCompletion) bool {
        return self.client.dispatchFile(completion);
    }

    pub fn dispatchTimer(self: *Binding, operation: io.OperationHandle) !bool {
        if (!try self.client.dispatchTimer(operation)) return false;
        try self.collectCanceled();
        return true;
    }

    pub fn collectCanceled(self: *Binding) !void {
        for (&self.jobs) |*slot| if (slot.*) |job| {
            const canceled = job.canceled or self.vm.taskCancellationRequested(job.task_handle);
            if (canceled) self.client.cancel(&job.request);
            if (job.request.ready) {
                if (!job.published) {
                    try self.vm.markExternalCompleted(job.task_handle);
                    job.published = true;
                }
                if (canceled) self.release(slot);
            }
        };
        try self.client.pump();
    }

    pub fn stop(self: *Binding) !void {
        for (self.jobs) |slot| if (slot) |job| {
            job.canceled = true;
        };
        try self.client.stop();
        try self.collectCanceled();
    }

    pub fn canDeinit(self: *const Binding) bool {
        for (self.jobs) |slot| if (slot != null) return false;
        return self.client.canDeinit();
    }

    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.canDeinit());
        self.client.deinit();
        self.* = undefined;
    }

    fn release(self: *Binding, slot: *?*Job) void {
        const job = slot.*.?;
        job.request.deinit();
        self.vm.allocator.destroy(job);
        slot.* = null;
    }

    fn call(L: *c.State) callconv(.c) c_int {
        const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
        var valid: c_int = 0;
        const kind: Kind = @enumFromInt(c.lua_tointegerx(L, c.upvalueIndex(2), &valid));
        const job = self.begin(L, kind) catch |err| return luaError(L, @errorName(err));
        return c.lua_yieldk(L, 0, @bitCast(@intFromPtr(job)), continuation);
    }

    fn begin(self: *Binding, L: *c.State, kind: Kind) !*Job {
        _ = try self.vm.currentScope(L);
        if (self.client.stopping) return error.HttpStopping;
        const count = c.lua_gettop(L);
        const index: c_int = if (kind == .request) 1 else 2;
        if (kind == .request) {
            if (count != 1 or c.lua_type(L, 1) != c.type_table) return error.ExpectedRequestTable;
        } else if (count < 1 or count > 2 or (count == 2 and c.lua_type(L, 2) != c.type_table)) return error.InvalidHttpArguments;
        const has_options = count >= index;
        var options: http.Options = .{ .url = undefined };
        options.url = if (kind == .request) (try stringField(L, index, "url")) orelse return error.ExpectedUrl else try string(L, 1);
        options.method = switch (kind) {
            .get => "GET",
            .post => "POST",
            .request => (try stringField(L, index, "method")) orelse "GET",
        };
        var headers: std.ArrayList(http.Header) = .empty;
        defer headers.deinit(self.vm.allocator);
        if (has_options) {
            options.body = try stringField(L, index, "body");
            options.timeout_ms = @intCast(try integerField(L, index, "timeout_ms", 30_000, std.math.maxInt(i32)));
            options.max_bytes = @intCast(try integerField(L, index, "max_bytes", http.default_max_bytes, http.absolute_max_bytes));
            _ = c.lua_pushstring(L, "headers");
            _ = c.lua_rawget(L, index);
            defer c.lua_settop(L, count);
            if (c.lua_type(L, -1) != c.type_nil) {
                if (c.lua_type(L, -1) != c.type_table) return error.ExpectedHeadersTable;
                c.lua_pushnil(L);
                var bytes: usize = 0;
                while (c.lua_next(L, -2) != 0) {
                    const name = try string(L, -2);
                    const value = try string(L, -1);
                    if (name.len > http.max_header_bytes or value.len > http.max_header_bytes) return error.HeadersTooLarge;
                    bytes += name.len + value.len + 4;
                    if (bytes > http.max_header_bytes) return error.HeadersTooLarge;
                    try headers.append(self.vm.allocator, .{ .name = name, .value = value });
                    c.lua_settop(L, -2);
                }
            }
        }
        if (kind == .post and options.body == null) options.body = "";
        options.headers = headers.items;
        const slot = for (&self.jobs) |*slot| {
            if (slot.* == null) break slot;
        } else return error.HttpBusy;
        try self.client.ensureInitialized();
        const job = try self.vm.allocator.create(Job);
        errdefer self.vm.allocator.destroy(job);
        job.* = .{ .owner = self, .request = undefined };
        try job.request.init(self.vm.allocator, options);
        errdefer job.request.deinit();
        job.task_handle = try self.vm.beginExternalWait(L, .operation, job, &lifecycle);
        errdefer self.vm.abortExternalWait(L, job.task_handle) catch unreachable;
        try self.client.start(&job.request);
        slot.* = job;
        return job;
    }

    fn continuation(L: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
        const job: *Job = @ptrFromInt(@as(usize, @bitCast(context)));
        const slot = for (&job.owner.jobs) |*slot| {
            if (slot.* == job) break slot;
        } else unreachable;
        const failure = job.request.failure;
        if (failure == null) pushResponse(L, &job.request);
        job.owner.release(slot);
        if (failure) |err| return luaError(L, @errorName(err));
        return 1;
    }
};

fn pushResponse(L: *c.State, request: *http.Request) void {
    c.lua_createtable(L, 0, 3);
    c.lua_pushinteger(L, request.status);
    c.lua_setfield(L, -2, "status");
    _ = c.lua_pushlstring(L, request.body.items.ptr, request.body.items.len);
    c.lua_setfield(L, -2, "body");
    c.lua_createtable(L, 0, 8);
    var lines = std.mem.splitSequence(u8, request.headers.items, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        // Header storage is request-owned and no longer used by curl.
        const name: []u8 = @constCast(line[0..colon]);
        for (name) |*byte| byte.* = std.ascii.toLower(byte.*);
        _ = c.lua_pushlstring(L, name.ptr, name.len);
        c.lua_pushvalue(L, -1);
        if (c.lua_rawget(L, -3) == c.type_nil) {
            c.lua_settop(L, -2);
            c.lua_createtable(L, 1, 0);
        }
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        _ = c.lua_pushlstring(L, value.ptr, value.len);
        c.lua_rawseti(L, -2, @intCast(c.lua_rawlen(L, -2) + 1));
        c.lua_settable(L, -3);
    }
    c.lua_setfield(L, -2, "headers");
}

fn requestCancel(context: *anyopaque) !void {
    const job: *Job = @ptrCast(@alignCast(context));
    job.canceled = true;
}
fn destroyResource(_: *anyopaque) void {}
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = requestCancel, .destroy = destroyResource };

fn string(L: *c.State, index: c_int) ![]const u8 {
    if (c.lua_type(L, index) != c.type_string) return error.ExpectedString;
    var length: usize = 0;
    const value = c.lua_tolstring(L, index, &length) orelse return error.ExpectedString;
    return value[0..length];
}
fn stringField(L: *c.State, index: c_int, name: [*:0]const u8) !?[]const u8 {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_pushstring(L, name);
    if (c.lua_rawget(L, index) == c.type_nil) return null;
    return try string(L, -1);
}
fn integerField(L: *c.State, index: c_int, name: [*:0]const u8, default: i64, maximum: i64) !i64 {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_pushstring(L, name);
    if (c.lua_rawget(L, index) == c.type_nil) return default;
    if (c.lua_isinteger(L, -1) == 0) return error.InvalidHttpLimits;
    var valid: c_int = 0;
    const value = c.lua_tointegerx(L, -1, &valid);
    if (valid == 0 or value <= 0 or value > maximum) return error.InvalidHttpLimits;
    return value;
}
fn luaError(L: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(L, message);
    return c.lua_error(L);
}

fn testStep(loop: *io.Loop, binding: *Binding) !void {
    try binding.collectCanceled();
    _ = try loop.submit();
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| _ = try binding.dispatch(completion),
        .file => |completion| _ = binding.dispatchFile(completion),
        .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timer| {
            _ = try binding.dispatchTimer(timer.operation);
        },
        .operation_cancel => {},
        else => return error.UnexpectedCompletion,
    }
}

fn testAwaitingResponse(binding: *const Binding) bool {
    for (binding.client.watches.items) |watch| {
        if (watch.active and watch.events == std.os.linux.POLL.IN and watch.operation != null) return true;
    }
    return false;
}

test "HTTP request owned by a retired state scope is released while curl's socket watch drains" {
    const linux = std.os.linux;
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 4, 4);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var vm: vm_module.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var binding: Binding = undefined;
    binding.init(&vm, &loop);
    // A loopback peer that accepts in its backlog and never answers.
    const opened = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    const listener: linux.fd_t = @intCast(opened);
    defer _ = linux.close(listener);
    var address: linux.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var address_length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(listener, @ptrCast(&address), address_length)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(listener, 1)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.getsockname(listener, @ptrCast(&address), &address_length)));

    var source_buffer: [128]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "response = require('ouro').http.get('http://127.0.0.1:{d}/'); resumed = true", .{std.mem.bigToNative(u16, address.port)});
    const state = try vm.openScope(scheduler.application_scope);
    const inner = try vm.openScope(state);
    _ = try vm.spawn(inner, source);
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
    while (!testAwaitingResponse(&binding)) try testStep(&loop, &binding);

    try scheduler.retireScope(state);
    try scheduler.applyQueuedCancellations();
    try binding.collectCanceled();
    try std.testing.expectEqual(vm_module.ResumeResult.canceled, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(!vm.globalBoolean("resumed"));
    for (binding.jobs) |job| try std.testing.expect(job == null);
    try std.testing.expect(!scheduler.scopeAlive(state) and !scheduler.scopeAlive(inner));
    // The request is gone, but curl's client-owned watch (on a duplicated fd,
    // with no request storage) is still draining its poll cancellation.
    try std.testing.expect(loop.hasPendingOperations());

    try binding.stop();
    while (!binding.canDeinit() or loop.hasPendingOperations() or loop.hasPendingTimerKernelWork())
        try testStep(&loop, &binding);
    binding.deinit();
}
