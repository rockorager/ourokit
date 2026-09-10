const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

const chunk_size = 64 * 1024;
const Stream = enum { stdin, stdout, stderr };
const State = enum { free, pending, ready };

const Slot = struct {
    owner: *Stdio = undefined,
    state: State = .free,
    stream: Stream = .stdin,
    buffer: []u8 = &.{},
    transferred: usize = 0,
    operation: ?io.OperationHandle = null,
    operation_terminal: bool = false,
    task_handle: vm_module.TaskHandle = .invalid,
    failure: ?[:0]const u8 = null,
    cancellation_requested: bool = false,
};

/// Stable-address, generation-owned adapter. File descriptors are borrowed:
/// do not close or change them until operations drain. Blocking pipes are
/// handled by io_uring workers, never by the Lua/UI thread. Nonblocking file
/// errors (including EAGAIN) are reported to Lua. Concurrent writes are not
/// atomic with respect to other writers; await each write to preserve order.
pub const Stdio = struct {
    pub const Files = struct {
        stdin: linux.fd_t = 0,
        stdout: linux.fd_t = 1,
        stderr: linux.fd_t = 2,
    };

    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    loop: *io.Loop,
    files: Files,
    slots: []Slot,

    pub fn init(self: *Stdio, allocator: std.mem.Allocator, vm: *vm_module.Vm, loop: *io.Loop, capacity: usize) !void {
        try self.initWithFiles(allocator, vm, loop, capacity, .{});
    }

    pub fn initWithFiles(self: *Stdio, allocator: std.mem.Allocator, vm: *vm_module.Vm, loop: *io.Loop, capacity: usize, files: Files) !void {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .vm = vm, .loop = loop, .files = files, .slots = slots };
        for (slots) |*slot| slot.owner = self;
        vm.pushApi(vm.state);
        inline for (.{ Stream.stdin, Stream.stdout, Stream.stderr }) |stream| {
            c.lua_createtable(vm.state, 0, 1);
            c.lua_pushlightuserdata(vm.state, self);
            c.lua_pushinteger(vm.state, @intFromEnum(stream));
            c.lua_pushcclosure(vm.state, call, 2);
            c.lua_setfield(vm.state, -2, if (stream == .stdin) "read" else "write");
            c.lua_setfield(vm.state, -2, @tagName(stream));
        }
        c.lua_settop(vm.state, -2);
    }

    pub fn deinit(self: *Stdio) void {
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Output has drained when the kernel has accepted every byte, even if
    /// the Lua continuation is suspended by an explicit exit request.
    pub fn hasPendingOutput(self: *const Stdio) bool {
        for (self.slots) |slot| {
            if (slot.state == .pending and slot.stream != .stdin) return true;
        }
        return false;
    }

    /// Completion phase only; never enters Lua. A write resumes its task only
    /// after every suffix has been accepted, or a terminal error occurs.
    pub fn dispatch(self: *Stdio, completion: io.FileCompletion) !bool {
        for (self.slots) |*slot| {
            const operation = slot.operation orelse continue;
            if (!same(operation, completion.operation)) continue;
            if (completion.kind != (if (slot.stream == .stdin) io.OperationKind.read else .write))
                return error.UnexpectedStdioCompletion;
            slot.operation_terminal = true;
            if (slot.cancellation_requested) {
                try self.collectCanceledSlot(slot);
                return true;
            }
            slot.operation = null;
            slot.operation_terminal = false;
            if (completion.result < 0) {
                try self.finish(slot, "stdio operation failed");
            } else if (slot.stream == .stdin) {
                slot.transferred = @intCast(completion.result);
                try self.finish(slot, null);
            } else if (completion.result == 0) {
                try self.finish(slot, "stdio write made no progress");
            } else {
                slot.transferred += @intCast(completion.result);
                if (slot.transferred == slot.buffer.len) {
                    try self.finish(slot, null);
                } else {
                    self.prepare(slot) catch try self.finish(slot, "could not prepare stdio write");
                }
            }
            return true;
        }
        return false;
    }

    /// Call at task safe points and after cancel CQEs. Retain buffers until
    /// BOTH the original operation and its cancellation have terminated.
    /// Also discard ready results canceled before their Lua continuation.
    pub fn collectCanceled(self: *Stdio) !void {
        for (self.slots) |*slot| {
            if (slot.cancellation_requested) {
                try self.collectCanceledSlot(slot);
            } else if (slot.state == .ready and self.vm.taskCancellationRequested(slot.task_handle)) {
                self.release(slot);
            }
        }
    }

    fn collectCanceledSlot(self: *Stdio, slot: *Slot) !void {
        const operation = slot.operation orelse return;
        if (!slot.operation_terminal or self.loop.operationPending(operation)) return;
        slot.operation = null;
        try self.vm.markExternalCompleted(slot.task_handle);
        self.release(slot);
    }

    fn finish(self: *Stdio, slot: *Slot, failure: ?[:0]const u8) !void {
        slot.failure = failure;
        slot.state = .ready;
        try self.vm.markExternalCompleted(slot.task_handle);
    }

    fn prepare(self: *Stdio, slot: *Slot) !void {
        const offset = std.math.maxInt(u64);
        slot.operation = if (slot.stream == .stdin)
            try self.loop.prepareRead(self.files.stdin, slot.buffer, offset)
        else
            try self.loop.prepareWrite(
                if (slot.stream == .stdout) self.files.stdout else self.files.stderr,
                slot.buffer[slot.transferred..][0..@min(chunk_size, slot.buffer.len - slot.transferred)],
                offset,
            );
    }

    fn release(self: *Stdio, slot: *Slot) void {
        self.allocator.free(slot.buffer);
        slot.* = .{ .owner = self };
    }

    fn call(state: *c.State) callconv(.c) c_int {
        const self: *Stdio = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
        var valid: c_int = 0;
        const stream: Stream = @enumFromInt(c.lua_tointegerx(state, c.upvalueIndex(2), &valid));
        if (c.lua_gettop(state) != 1) return luaError(state, "stdio expects one argument");
        var length: usize = 0;
        var bytes: ?[*]const u8 = null;
        if (stream == .stdin) {
            if (c.lua_isinteger(state, 1) == 0) return luaError(state, "stdin.read expects a positive integer byte limit");
            const limit = c.lua_tointegerx(state, 1, &valid);
            if (limit <= 0) return luaError(state, "stdin.read expects a positive integer byte limit");
            length = @intCast(@min(limit, chunk_size));
        } else {
            if (c.lua_type(state, 1) != c.type_string) return luaError(state, "stdio.write expects a byte string");
            bytes = c.lua_tolstring(state, 1, &length).?;
            if (length == 0) return 0;
        }
        const slot = for (self.slots) |*candidate| {
            if (candidate.state == .free) break candidate;
        } else return luaError(state, "stdio operation capacity exceeded");
        slot.buffer = self.allocator.alloc(u8, length) catch return luaError(state, "could not allocate stdio buffer");
        if (bytes) |source| @memcpy(slot.buffer, source[0..length]);
        slot.stream = stream;
        slot.state = .pending;
        slot.task_handle = self.vm.beginExternalWait(state, .operation, slot, &resource_lifecycle) catch {
            self.release(slot);
            return luaError(state, "could not park stdio operation");
        };
        self.prepare(slot) catch {
            self.vm.abortExternalWait(state, slot.task_handle) catch unreachable;
            self.release(slot);
            return luaError(state, "could not prepare stdio operation");
        };
        return c.lua_yieldk(state, 0, @bitCast(@intFromPtr(slot)), continuation);
    }

    fn continuation(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
        const slot: *Slot = @ptrFromInt(@as(usize, @bitCast(context)));
        if (slot.failure) |failure| {
            slot.owner.release(slot);
            return luaError(state, failure);
        }
        const result_count: c_int = if (slot.stream == .stdin) 1 else 0;
        if (slot.stream == .stdin) {
            if (slot.transferred == 0) c.lua_pushnil(state) else _ = c.lua_pushlstring(state, slot.buffer.ptr, slot.transferred);
        }
        slot.owner.release(slot);
        return result_count;
    }
};

fn requestCancel(pointer: *anyopaque) !void {
    const slot: *Slot = @ptrCast(@alignCast(pointer));
    if (slot.operation) |operation| try slot.owner.loop.prepareCancel(operation);
    slot.cancellation_requested = true;
}

fn destroyResource(_: *anyopaque) void {}

const resource_lifecycle: task.ResourceLifecycle = .{
    .request_cancel = requestCancel,
    .destroy = destroyResource,
};

fn same(first: io.OperationHandle, second: io.OperationHandle) bool {
    return first.slot == second.slot and first.generation == second.generation;
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

const TestRuntime = struct {
    loop: io.Loop = undefined,
    scheduler: task.Scheduler = undefined,
    vm: vm_module.Vm = undefined,
    stdio: Stdio = undefined,

    fn init(self: *TestRuntime, files: Stdio.Files) !void {
        try self.loop.init(std.testing.allocator, 16, 16);
        errdefer self.loop.deinit();
        try self.scheduler.init(std.testing.allocator, 2, 4, 4);
        errdefer self.scheduler.deinit();
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        errdefer self.vm.deinit();
        try self.stdio.initWithFiles(std.testing.allocator, &self.vm, &self.loop, 4, files);
    }

    fn deinit(self: *TestRuntime) void {
        self.stdio.deinit();
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
            .file => |completion| try std.testing.expect(try self.stdio.dispatch(completion)),
            .operation_cancel => try self.stdio.collectCanceled(),
            else => return error.UnexpectedCompletion,
        }
    }

    fn cancel(self: *TestRuntime) !void {
        try self.vm.requestCancellation();
        while (self.scheduler.takeRunnable()) |runnable| _ = try self.vm.resumeRunnable(runnable);
        while (self.loop.hasPendingOperations()) try self.completeOne();
        while (self.scheduler.takeRunnable()) |runnable| _ = try self.vm.resumeRunnable(runnable);
        try self.stdio.collectCanceled();
        try std.testing.expectEqual(@as(usize, 0), self.vm.activeTaskCount());
    }
};

fn testPipe(nonblocking: bool) ![2]linux.fd_t {
    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = nonblocking })) != .SUCCESS)
        return error.PipeCreationFailed;
    return fds;
}

test "stdio raw stdin bounds reads, preserves NUL, yields other tasks, and returns nil at EOF" {
    const pipe = try testPipe(false);
    defer _ = linux.close(pipe[0]);
    var runtime: TestRuntime = .{};
    try runtime.init(.{ .stdin = pipe[0] });
    defer runtime.deinit();

    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
        "local o = require('ouro'); first = o.stdin.read(3); second = o.stdin.read(20); eof = o.stdin.read(1) == nil",
    ));
    _ = try runtime.loop.submit();
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start("other_ran = true"));
    try std.testing.expect(runtime.vm.globalBoolean("other_ran"));
    try std.testing.expect(!runtime.vm.hasGlobal("first"));
    const input = "a\x00b\xffZ";
    try std.testing.expectEqual(input.len, linux.write(pipe[1], input.ptr, input.len));
    _ = linux.close(pipe[1]);
    for ([_]vm_module.ResumeResult{ .waiting, .waiting, .completed }) |expected| {
        try runtime.completeOne();
        try std.testing.expectEqual(expected, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
    }
    _ = c.lua_getglobal(runtime.vm.state, "first");
    var length: usize = 0;
    const first = c.lua_tolstring(runtime.vm.state, -1, &length).?;
    try std.testing.expectEqualStrings("a\x00b", first[0..length]);
    c.lua_settop(runtime.vm.state, -2);
    _ = c.lua_getglobal(runtime.vm.state, "second");
    const second = c.lua_tolstring(runtime.vm.state, -1, &length).?;
    try std.testing.expectEqualStrings("\xffZ", second[0..length]);
    c.lua_settop(runtime.vm.state, -2);
    try std.testing.expect(runtime.vm.globalBoolean("eof"));
}

test "stdio stdout and stderr preserve every byte across real short pipe writes" {
    inline for (.{ "stdout", "stderr" }) |stream| {
        const pipe = try testPipe(true);
        defer _ = linux.close(pipe[0]);
        defer _ = linux.close(pipe[1]);
        var runtime: TestRuntime = .{};
        var files: Stdio.Files = .{};
        @field(files, stream) = pipe[1];
        try runtime.init(files);
        defer runtime.deinit();
        // Fix capacity below the requested write, forcing actual short CQEs.
        try std.testing.expectEqual(@as(usize, 4096), linux.fcntl(pipe[1], linux.F.SETPIPE_SZ, 4096));
        const payload = try std.testing.allocator.alloc(u8, chunk_size + 113);
        defer std.testing.allocator.free(payload);
        for (payload, 0..) |*byte, index| byte.* = @truncate(index * 17 + index / 251);
        _ = try runtime.start("function output(s) require('ouro')." ++ stream ++ ".write(s); written = true end");
        _ = try runtime.vm.spawnGlobal(runtime.scheduler.application_scope, "output", &.{.{ .string = payload }});
        try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
        var received: usize = 0;
        var completions: usize = 0;
        var buffer: [4096]u8 = undefined;
        while (runtime.stdio.hasPendingOutput()) {
            try runtime.completeOne();
            completions += 1;
            const count = try std.posix.read(pipe[0], &buffer);
            try std.testing.expect(count > 0);
            try std.testing.expectEqualSlices(u8, payload[received..][0..count], buffer[0..count]);
            received += count;
            try std.testing.expect(!runtime.vm.globalBoolean("written"));
            if (received < payload.len) try std.testing.expect(runtime.scheduler.takeRunnable() == null);
        }
        try std.testing.expect(completions > 2);
        try std.testing.expectEqual(payload.len, received);
        try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
        try std.testing.expect(runtime.vm.globalBoolean("written"));
    }
}

test "stdio backpressured stdout and stderr do not block scheduling and drain after exit" {
    const out = try testPipe(false);
    defer _ = linux.close(out[0]);
    defer _ = linux.close(out[1]);
    const err = try testPipe(false);
    defer _ = linux.close(err[0]);
    defer _ = linux.close(err[1]);
    var runtime: TestRuntime = .{};
    try runtime.init(.{ .stdout = out[1], .stderr = err[1] });
    defer runtime.deinit();
    const filler: [4096]u8 = @splat('x');
    for ([_][2]linux.fd_t{ out, err }) |pipe| {
        try std.testing.expectEqual(@as(usize, 4096), linux.fcntl(pipe[1], linux.F.SETPIPE_SZ, 4096));
        try std.testing.expectEqual(filler.len, linux.write(pipe[1], &filler, filler.len));
    }
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start("require('ouro').stdout.write('out\\0'); out_continued = true"));
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start("require('ouro').stderr.write('err!'); err_continued = true"));
    _ = try runtime.loop.submit();
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start("ui_ran = true"));
    try std.testing.expect(runtime.vm.globalBoolean("ui_ran"));
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start("require('ouro').exit(23); exit_continued = true"));
    try std.testing.expectEqual(@as(?u8, 23), runtime.vm.exit_code);
    try std.testing.expect(runtime.stdio.hasPendingOutput());
    var discarded: [4096]u8 = undefined;
    for ([_][2]linux.fd_t{ out, err }) |pipe| try std.testing.expectEqual(filler.len, try std.posix.read(pipe[0], &discarded));
    while (runtime.stdio.hasPendingOutput()) try runtime.completeOne();
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try std.posix.read(out[0], &buffer));
    try std.testing.expectEqualStrings("out\x00", &buffer);
    try std.testing.expectEqual(@as(usize, 4), try std.posix.read(err[0], &buffer));
    try std.testing.expectEqualStrings("err!", &buffer);
    while (runtime.scheduler.takeRunnable()) |runnable|
        try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.vm.resumeRunnable(runnable));
    try runtime.cancel();
    try std.testing.expect(!runtime.vm.globalBoolean("out_continued"));
    try std.testing.expect(!runtime.vm.globalBoolean("err_continued"));
    try std.testing.expect(!runtime.vm.globalBoolean("exit_continued"));
}

test "stdio cancellation drains blocked reads and writes and discards ready results" {
    inline for (.{ "stdin.read(17)", "stdout.write('blocked')", "stderr.write('blocked')" }) |operation| {
        const pipe = try testPipe(false);
        defer _ = linux.close(pipe[0]);
        defer _ = linux.close(pipe[1]);
        if (comptime !std.mem.startsWith(u8, operation, "stdin")) {
            try std.testing.expectEqual(@as(usize, 4096), linux.fcntl(pipe[1], linux.F.SETPIPE_SZ, 4096));
            const filler: [4096]u8 = @splat('x');
            try std.testing.expectEqual(filler.len, linux.write(pipe[1], &filler, filler.len));
        }
        var runtime: TestRuntime = .{};
        try runtime.init(.{ .stdin = pipe[0], .stdout = pipe[1], .stderr = pipe[1] });
        defer runtime.deinit();
        _ = try runtime.start("require('ouro')." ++ operation ++ "; continued = true");
        _ = try runtime.loop.submit();
        try runtime.cancel();
        try std.testing.expect(!runtime.vm.globalBoolean("continued"));
        for (runtime.stdio.slots) |slot| try std.testing.expectEqual(State.free, slot.state);
    }
    const pipe = try testPipe(false);
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    var runtime: TestRuntime = .{};
    try runtime.init(.{ .stdin = pipe[0] });
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1), linux.write(pipe[1], "r", 1));
    _ = try runtime.start("require('ouro').stdin.read(1); continued = true");
    try runtime.completeOne();
    try std.testing.expectEqual(State.ready, runtime.stdio.slots[0].state);
    try runtime.cancel();
    try std.testing.expect(!runtime.vm.globalBoolean("continued"));
    try std.testing.expectEqual(State.free, runtime.stdio.slots[0].state);
}

test "stdio errors release storage and empty writes are no-ops" {
    var runtime: TestRuntime = .{};
    try runtime.init(.{ .stdin = -1, .stdout = -1, .stderr = -1 });
    defer runtime.deinit();
    inline for (.{ "stdin.read(1)", "stdout.write('x')", "stderr.write('x')" }) |operation| {
        _ = try runtime.start("require('ouro')." ++ operation ++ "; continued = true");
        try runtime.completeOne();
        try std.testing.expectError(error.LuaRuntimeError, runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
        try std.testing.expect(!runtime.vm.globalBoolean("continued"));
        for (runtime.stdio.slots) |slot| try std.testing.expectEqual(State.free, slot.state);
    }
    inline for (.{ "stdin.read(0)", "stdin.read(-1)", "stdin.read(1.5)", "stdout.write(1)", "stderr.write(nil)" }) |operation| {
        try std.testing.expectError(error.LuaRuntimeError, runtime.start("require('ouro')." ++ operation));
    }
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start("local o = require('ouro'); o.stdout.write(''); o.stderr.write('')"));
    try std.testing.expect(!runtime.loop.hasPendingOperations());
}

test "stdio broken output pipes raise Lua errors without terminating the host" {
    const pipe = try testPipe(false);
    _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    var runtime: TestRuntime = .{};
    try runtime.init(.{ .stdout = pipe[1], .stderr = pipe[1] });
    defer runtime.deinit();
    inline for (.{ "stdout", "stderr" }) |stream| {
        _ = try runtime.start("require('ouro')." ++ stream ++ ".write('broken')");
        try runtime.completeOne();
        try std.testing.expectError(error.LuaRuntimeError, runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
        try std.testing.expect(!runtime.stdio.hasPendingOutput());
    }
}
