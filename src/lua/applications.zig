//! Generation-owned discovery on the shared loop. Only the task-phase
//! continuation enters Lua; cancellation drains I/O before retirement.
const std = @import("std");
const native = @import("../xdg/applications.zig");
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");
const json = @import("mcp_client.zig");

pub const Binding = struct {
    vm: *vm_module.Vm,
    loop: *io.Loop,
    /// Borrowed immutable process configuration; outlives this generation.
    config: ?*const native.Config,
    job: ?*Job = null,

    pub fn init(self: *Binding, vm: *vm_module.Vm, loop: *io.Loop, config: ?*const native.Config) void {
        self.* = .{ .vm = vm, .loop = loop, .config = config };
        const state = vm.state;
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        vm.pushApi(state);
        if (c.lua_getfield(state, -1, "xdg") != c.type_table) {
            c.lua_settop(state, -2);
            c.lua_createtable(state, 0, 1);
        }
        c.lua_createtable(state, 0, 2);
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, list, 1);
        c.lua_setfield(state, -2, "list");
        c.lua_pushcclosure(state, prepareLaunch, 0);
        c.lua_setfield(state, -2, "prepare_launch");
        c.lua_setfield(state, -2, "applications");
        c.lua_setfield(state, -2, "xdg");
    }

    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.job == null);
        self.* = undefined;
    }

    pub fn dispatch(self: *Binding, completion: io.FileCompletion) !bool {
        const job = self.job orelse return false;
        if (!try job.scan.dispatch(completion)) return false;
        try self.collectCanceled();
        return true;
    }

    pub fn collectCanceled(self: *Binding) !void {
        const job = self.job orelse return;
        try job.scan.collectCanceled();
        if (!job.ready and job.scan.finished()) {
            job.take();
            try self.vm.markExternalCompleted(job.task_handle);
        }
        if (job.ready) {
            if (job.cancelled or self.vm.taskCancellationRequested(job.task_handle)) self.release();
        }
    }

    fn release(self: *Binding) void {
        const job = self.job.?;
        if (job.result) |value| {
            var catalog = value;
            catalog.deinit();
        } else |_| {}
        job.scan.deinit();
        self.vm.allocator.destroy(job);
        self.job = null;
    }

    fn list(state: *c.State) callconv(.c) c_int {
        const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
        if (c.lua_gettop(state) != 0) return luaError(state, "applications.list expects no arguments");
        const job = self.begin(state) catch |err| return luaError(state, @errorName(err));
        if (job.scan.finished()) {
            self.vm.abortExternalWait(state, job.task_handle) catch unreachable;
            job.take();
            return continuation(state, c.ok, @bitCast(@intFromPtr(job)));
        }
        return c.lua_yieldk(state, 0, @bitCast(@intFromPtr(job)), continuation);
    }

    fn begin(self: *Binding, state: *c.State) !*Job {
        const config = self.config orelse return error.ApplicationDiscoveryUnavailable;
        if (self.job != null) return error.ApplicationDiscoveryBusy;
        const job = try self.vm.allocator.create(Job);
        errdefer self.vm.allocator.destroy(job);
        job.* = .{ .owner = self, .scan = undefined };
        try job.scan.init(self.vm.allocator, self.loop, config);
        errdefer job.scan.deinit();
        job.task_handle = try self.vm.beginExternalWait(state, .operation, job, &lifecycle);
        errdefer self.vm.abortExternalWait(state, job.task_handle) catch unreachable;
        try job.scan.start();
        self.job = job;
        return job;
    }

    fn continuation(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
        const job: *Job = @ptrFromInt(@as(usize, @bitCast(context)));
        const failure: ?anyerror = if (job.result) |catalog| blk: {
            pushValue(state, catalog.entries) catch |err| break :blk err;
            break :blk null;
        } else |err| err;
        job.owner.release();
        if (failure) |err| return luaError(state, @errorName(err));
        return 1;
    }
};

const Job = struct {
    owner: *Binding,
    scan: native.Scan,
    task_handle: vm_module.TaskHandle = .invalid,
    ready: bool = false,
    cancelled: bool = false,
    result: anyerror!native.Catalog = error.ScanNotStarted,

    fn take(self: *Job) void {
        self.result = if (self.scan.take()) |catalog| catalog.? else |err| err;
        self.ready = true;
    }
};

fn requestCancel(pointer: *anyopaque) !void {
    const job: *Job = @ptrCast(@alignCast(pointer));
    job.cancelled = true;
    try job.scan.cancel();
}
fn destroyResource(_: *anyopaque) void {}
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = requestCancel, .destroy = destroyResource };

fn prepareLaunch(state: *c.State) callconv(.c) c_int {
    const count = c.lua_gettop(state);
    if (count < 1 or count > 2) return luaError(state, "prepare_launch expects an entry and optional options table");
    prepareValue(state, count) catch |err| return luaError(state, @errorName(err));
    return 1;
}

fn prepareValue(state: *c.State, count: c_int) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var values: usize = 0;
    const entry_json = try json.luaToJson(state, 1, a, 0, &values);
    const entry = try std.json.parseFromValueLeaky(native.Entry, a, entry_json, .{});
    const options = if (count == 2) try std.json.parseFromValueLeaky(native.LaunchOptions, a, try json.luaToJson(state, 2, a, 0, &values), .{}) else native.LaunchOptions{};
    var launch = try native.prepareLaunch(a, &entry, options);
    defer launch.deinit();
    try pushValue(state, .{ .argv = launch.argv, .cwd = launch.cwd });
}

// Use the established JSON value bridge, including explicit nulls and marked
// empty arrays, so returned entries round-trip through prepare_launch unchanged.
fn pushValue(state: *c.State, value: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), value, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), bytes, .{});
    try json.pushJson(state, parsed.value);
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

const TestRuntime = struct {
    loop: io.Loop = undefined,
    scheduler: task.Scheduler = undefined,
    vm: vm_module.Vm = undefined,
    binding: Binding = undefined,

    fn init(self: *TestRuntime, config: ?*const native.Config) !void {
        try self.loop.init(std.testing.allocator, 16, 16);
        errdefer self.loop.deinit();
        try self.scheduler.init(std.testing.allocator, 2, 4, 4);
        errdefer self.scheduler.deinit();
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        self.vm.setRuntimeDirectory("/test/runtime");
        self.binding.init(&self.vm, &self.loop, config);
    }

    fn deinit(self: *TestRuntime) void {
        self.binding.deinit();
        self.vm.deinit();
        self.scheduler.deinit();
        self.loop.deinit();
    }

    fn start(self: *TestRuntime, source: []const u8) !vm_module.ResumeResult {
        _ = try self.vm.spawnApplication(source);
        return self.vm.resumeRunnable(self.scheduler.takeRunnable().?);
    }

    fn completeOne(self: *TestRuntime) !void {
        _ = try self.loop.submit();
        switch (self.loop.dispatch(try self.loop.wait())) {
            .file => |completion| try std.testing.expect(try self.binding.dispatch(completion)),
            .operation_cancel => try self.binding.collectCanceled(),
            else => return error.UnexpectedCompletion,
        }
    }

    fn complete(self: *TestRuntime) !void {
        while (self.loop.hasPendingOperations()) try self.completeOne();
    }

    fn cancel(self: *TestRuntime) !void {
        try self.vm.requestCancellation();
        while (self.scheduler.takeRunnable()) |runnable| _ = try self.vm.resumeRunnable(runnable);
        while (self.loop.hasPendingOperations()) try self.completeOne();
        while (self.scheduler.takeRunnable()) |runnable| _ = try self.vm.resumeRunnable(runnable);
        try self.binding.collectCanceled();
        try std.testing.expectEqual(@as(usize, 0), self.vm.activeTaskCount());
        try std.testing.expect(self.binding.job == null);
    }
};

test "Lua applications list yields fresh snapshots and prepares exact argv without launching" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "applications");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "applications/editor.desktop", .data = "[Desktop Entry]\nType=Application\nName=An Editor\nExec=editor --title %c %F\n" });
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const config: native.Config = .{ .roots = &.{root} };
    var runtime: TestRuntime = .{};
    try runtime.init(&config);
    defer runtime.deinit();
    defer runtime.cancel() catch unreachable;

    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
        \\local o = require('ouro')
        \\assert(o.xdg.runtime_dir == '/test/runtime')
        \\entries = o.xdg.applications.list()
        \\assert(#entries == 1 and entries[1].name == 'An Editor' and entries[1].visible)
        \\assert(entries[1].icon == o.json.null and #entries[1].actions == 0)
        \\local launch = o.xdg.applications.prepare_launch(entries[1])
        \\assert(#launch.argv == 3 and launch.argv[1] == 'editor')
        \\assert(launch.argv[2] == '--title' and launch.argv[3] == 'An Editor')
        \\assert(launch.cwd == o.json.null)
        \\prepared = true
    ));
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start(
        "local o = require('ouro'); concurrent_rejected = not pcall(o.xdg.applications.list); other_ran = true",
    ));
    try std.testing.expect(runtime.vm.globalBoolean("other_ran"));
    try std.testing.expect(runtime.vm.globalBoolean("concurrent_rejected"));
    try std.testing.expect(!runtime.vm.hasGlobal("entries"));
    try runtime.complete();
    try std.testing.expect(!runtime.vm.hasGlobal("entries"));
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
    try std.testing.expect(runtime.vm.globalBoolean("prepared"));

    try temp.dir.deleteFile(std.testing.io, "applications/editor.desktop");
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
        "local o = require('ouro'); fresh = o.xdg.applications.list(); assert(#fresh == 0 and #entries == 1)",
    ));
    try runtime.complete();
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
}

test "Lua applications cancellation drains pending and ready work without resuming its continuation" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const config: native.Config = .{ .roots = &.{root} };
    for ([_]bool{ false, true }) |ready| {
        var runtime: TestRuntime = .{};
        try runtime.init(&config);
        defer runtime.deinit();
        try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
            "require('ouro').xdg.applications.list(); resumed_after_cancel = true",
        ));
        if (ready) try runtime.complete();
        try runtime.cancel();
        try std.testing.expect(!runtime.vm.hasGlobal("resumed_after_cancel"));
    }
}

test "Lua applications rejects unavailable hosts and start errors without poisoning later calls" {
    var runtime: TestRuntime = .{};
    try runtime.init(null);
    defer runtime.deinit();
    defer runtime.cancel() catch unreachable;
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start(
        "assert(not pcall(require('ouro').xdg.applications.list))",
    ));
    const invalid: native.Config = .{ .roots = &.{"relative"} };
    runtime.binding.config = &invalid;
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start(
        "local ok, err = pcall(require('ouro').xdg.applications.list); failed = not ok and err == 'InvalidSearchRoot'",
    ));
    try std.testing.expect(runtime.vm.globalBoolean("failed"));
    const valid: native.Config = .{ .roots = &.{} };
    runtime.binding.config = &valid;
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start(
        "recovered = #require('ouro').xdg.applications.list() == 0",
    ));
    try std.testing.expect(runtime.vm.globalBoolean("recovered"));
}
