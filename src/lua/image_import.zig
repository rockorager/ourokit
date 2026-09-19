//! Bounded asynchronous notification-image import. Workers never touch Lua.
const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const codec = @import("../image/codec.zig");
const Bitmap = @import("../image/pixels.zig").Bitmap;
const png = @import("../renderer/png.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

const max_encoded = 4 * 1024 * 1024;
const max_pixels_bytes = 4 * 1024 * 1024;
const max_dimension = 1024;
const max_jobs = 4;

const Input = union(enum) {
    path: []u8,
    raw: struct { bytes: []u8, width: u32, height: u32, stride: usize, channels: u8 },
};

const Job = struct {
    owner: *Binding,
    input: Input,
    pipe: [2]linux.fd_t,
    byte: [1]u8 = undefined,
    operation: ?io.OperationHandle = null,
    thread: ?std.Thread = null,
    task_handle: vm_module.TaskHandle = .invalid,
    cancelled: bool = false,
    result: anyerror![]u8 = error.WorkerNotStarted,

    fn run(self: *Job) void {
        self.result = process(self.input);
        while (linux.errno(linux.write(self.pipe[1], &.{1}, 1)) == .INTR) {}
        _ = linux.close(self.pipe[1]);
    }
};

pub const Binding = struct {
    vm: *vm_module.Vm,
    loop: *io.Loop,
    jobs: [max_jobs]?*Job = @splat(null),

    pub fn init(self: *Binding, vm: *vm_module.Vm, loop: *io.Loop) void {
        self.* = .{ .vm = vm, .loop = loop };
        const L = vm.state;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        vm.pushApi(L);
        c.lua_createtable(L, 0, 1);
        c.lua_pushlightuserdata(L, self);
        c.lua_pushcclosure(L, load, 1);
        c.lua_setfield(L, -2, "load");
        c.lua_setfield(L, -2, "images");
    }

    pub fn deinit(self: *Binding) void {
        for (self.jobs) |job| std.debug.assert(job == null);
        self.* = undefined;
    }

    pub fn dispatch(self: *Binding, completion: io.FileCompletion) !bool {
        for (&self.jobs) |*slot| if (slot.*) |job| {
            const operation = job.operation orelse continue;
            if (!sameHandle(operation, completion.operation)) continue;
            if (completion.kind != .read) return error.UnexpectedImageImportCompletion;
            if (completion.result < 0) {
                job.operation = try self.loop.prepareRead(job.pipe[0], &job.byte, std.math.maxInt(u64));
                return true;
            }
            job.operation = null;
            if (job.thread) |thread| thread.join();
            job.thread = null;
            _ = linux.close(job.pipe[0]);
            try self.vm.markExternalCompleted(job.task_handle);
            if (job.cancelled or self.vm.taskCancellationRequested(job.task_handle)) self.release(slot);
            return true;
        };
        return false;
    }

    pub fn collectCanceled(self: *Binding) void {
        for (&self.jobs) |*slot| if (slot.*) |job| {
            if (job.operation == null and (job.cancelled or self.vm.taskCancellationRequested(job.task_handle))) self.release(slot);
        };
    }

    fn release(self: *Binding, slot: *?*Job) void {
        const job = slot.*.?;
        if (job.result) |bytes| std.heap.page_allocator.free(bytes) else |_| {}
        freeInput(job.input);
        self.vm.allocator.destroy(job);
        slot.* = null;
    }

    fn load(L: *c.State) callconv(.c) c_int {
        const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
        if (c.lua_gettop(L) != 1 or c.lua_type(L, 1) != c.type_table) return pushFailure(L, "InvalidOptions");
        const slot = for (&self.jobs) |*candidate| if (candidate.* == null) break candidate else continue else {
            return pushFailure(L, "ImageImportBusy");
        };
        const input = parseInput(L) catch |err| return pushFailure(L, @errorName(err));
        const job = self.vm.allocator.create(Job) catch {
            freeInput(input);
            return pushFailure(L, "OutOfMemory");
        };
        var pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
            freeInput(input);
            self.vm.allocator.destroy(job);
            return pushFailure(L, "PipeFailed");
        }
        job.* = .{ .owner = self, .input = input, .pipe = pipe };
        job.task_handle = self.vm.beginExternalWait(L, .operation, job, &lifecycle) catch |err| {
            _ = linux.close(pipe[0]);
            _ = linux.close(pipe[1]);
            freeInput(input);
            self.vm.allocator.destroy(job);
            return pushFailure(L, @errorName(err));
        };
        job.operation = self.loop.prepareRead(pipe[0], &job.byte, std.math.maxInt(u64)) catch |err| {
            self.vm.abortExternalWait(L, job.task_handle) catch unreachable;
            _ = linux.close(pipe[0]);
            _ = linux.close(pipe[1]);
            freeInput(input);
            self.vm.allocator.destroy(job);
            return pushFailure(L, @errorName(err));
        };
        slot.* = job;
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            job.result = err;
            while (linux.errno(linux.write(pipe[1], &.{1}, 1)) == .INTR) {}
            _ = linux.close(pipe[1]);
            return c.lua_yieldk(L, 0, @bitCast(@intFromPtr(job)), continuation);
        };
        return c.lua_yieldk(L, 0, @bitCast(@intFromPtr(job)), continuation);
    }
};

fn continuation(L: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const job: *Job = @ptrFromInt(@as(usize, @bitCast(context)));
    var slot: *?*Job = undefined;
    for (&job.owner.jobs) |*candidate| if (candidate.* == job) {
        slot = candidate;
        break;
    };
    if (job.result) |bytes| {
        _ = c.lua_pushlstring(L, bytes.ptr, bytes.len);
        job.owner.release(slot);
        return 1;
    } else |err| {
        job.owner.release(slot);
        return pushFailure(L, @errorName(err));
    }
}

fn requestCancel(pointer: *anyopaque) !void {
    const job: *Job = @ptrCast(@alignCast(pointer));
    job.cancelled = true;
}
fn destroyResource(_: *anyopaque) void {}
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = requestCancel, .destroy = destroyResource };

fn parseInput(L: *c.State) !Input {
    const path = try fieldString(L, "path");
    const data = try fieldString(L, "data");
    if ((path != null) == (data != null)) return error.ExpectedPathOrData;
    if (path) |value| {
        if (value.len == 0 or value[0] != '/' or value.len >= 4096 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPath;
        return .{ .path = try std.heap.page_allocator.dupe(u8, value) };
    }
    const width = try fieldPositiveInt(L, "width");
    const height = try fieldPositiveInt(L, "height");
    const stride = try fieldPositiveInt(L, "rowstride");
    const bits = try fieldPositiveInt(L, "bits_per_sample");
    const channels = try fieldPositiveInt(L, "channels");
    const alpha = try fieldBool(L, "has_alpha");
    if (bits != 8 or channels != (if (alpha) @as(usize, 4) else 3)) return error.InvalidPixelFormat;
    if (width > max_dimension or height > max_dimension) return error.ImageTooLarge;
    const row = std.math.mul(usize, width, channels) catch return error.ImageTooLarge;
    if (stride < row) return error.InvalidStride;
    const required = std.math.add(usize, std.math.mul(usize, height - 1, stride) catch return error.ImageTooLarge, row) catch return error.ImageTooLarge;
    if (required > max_pixels_bytes or data.?.len > max_pixels_bytes or data.?.len < required) return error.InvalidBufferLength;
    return .{ .raw = .{ .bytes = try std.heap.page_allocator.dupe(u8, data.?[0..required]), .width = @intCast(width), .height = @intCast(height), .stride = stride, .channels = @intCast(channels) } };
}

fn process(input: Input) ![]u8 {
    var bitmap = switch (input) {
        .path => |path| try loadPath(path),
        .raw => |raw| try rawBitmap(raw),
    };
    defer bitmap.deinit();
    const straight = try thumbnail(std.heap.page_allocator, bitmap);
    defer std.heap.page_allocator.free(straight.pixels);
    return png.encode(std.heap.page_allocator, straight.pixels, straight.width, straight.height, straight.width * 4);
}

fn loadPath(path: []const u8) !Bitmap {
    const root_result = linux.open("/", .{ .CLOEXEC = true, .DIRECTORY = true }, 0);
    if (linux.errno(root_result) != .SUCCESS) return error.OpenFailed;
    const root: linux.fd_t = @intCast(root_result);
    defer _ = linux.close(root);
    const name = try std.heap.page_allocator.dupeZ(u8, path[1..]);
    defer std.heap.page_allocator.free(name);
    const how: io.OpenHow = .{ .flags = @as(u32, @bitCast(linux.O{ .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true })), .resolve = io.Resolve.beneath | io.Resolve.no_symlinks | io.Resolve.no_magic_links };
    const opened = linux.syscall4(.openat2, @bitCast(@as(isize, root)), @intFromPtr(name.ptr), @intFromPtr(&how), @sizeOf(io.OpenHow));
    if (linux.errno(opened) != .SUCCESS) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var stat: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stat)) != .SUCCESS or !stat.mask.TYPE or !stat.mask.SIZE or !linux.S.ISREG(stat.mode)) return error.NotRegularFile;
    if (stat.size > max_encoded) return error.ImageEncodedBudgetExceeded;
    const bytes = try std.heap.page_allocator.alloc(u8, @intCast(stat.size));
    defer std.heap.page_allocator.free(bytes);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = linux.read(fd, bytes[at..].ptr, bytes.len - at);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS or n == 0) return error.ReadFailed;
        at += n;
    }
    return codec.decode(std.heap.page_allocator, bytes, .{ .max_decoded_bytes = max_pixels_bytes, .max_dimension = max_dimension });
}

fn rawBitmap(raw: anytype) !Bitmap {
    const pixels = try std.heap.page_allocator.alloc(u8, @as(usize, raw.width) * raw.height * 4);
    for (0..raw.height) |y| for (0..raw.width) |x| {
        const s = y * raw.stride + x * raw.channels;
        const d = (y * raw.width + x) * 4;
        const alpha = if (raw.channels == 4) raw.bytes[s + 3] else 255;
        for (0..3) |channel| pixels[d + channel] = @intCast((@as(u16, raw.bytes[s + channel]) * alpha + 127) / 255);
        pixels[d + 3] = alpha;
    };
    return .{ .allocator = std.heap.page_allocator, .pixels = pixels, .width = raw.width, .height = raw.height, .intrinsic_width = raw.width, .intrinsic_height = raw.height };
}

const Straight = struct { pixels: []u8, width: usize, height: usize };
fn thumbnail(a: std.mem.Allocator, bitmap: Bitmap) !Straight {
    const longest = @max(bitmap.width, bitmap.height);
    const w: usize = if (longest <= 128) bitmap.width else @max(1, @as(usize, bitmap.width) * 128 / longest);
    const h: usize = if (longest <= 128) bitmap.height else @max(1, @as(usize, bitmap.height) * 128 / longest);
    const out = try a.alloc(u8, w * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const s = ((y * bitmap.height / h) * bitmap.width + x * bitmap.width / w) * 4;
        const d = (y * w + x) * 4;
        const alpha = bitmap.pixels[s + 3];
        for (0..3) |ch| out[d + ch] = if (alpha == 0) 0 else @intCast(@min(255, (@as(u16, bitmap.pixels[s + ch]) * 255 + alpha / 2) / alpha));
        out[d + 3] = alpha;
    };
    return .{ .pixels = out, .width = w, .height = h };
}

fn freeInput(input: Input) void {
    switch (input) {
        .path => |v| std.heap.page_allocator.free(v),
        .raw => |v| std.heap.page_allocator.free(v.bytes),
    }
}
fn fieldString(L: *c.State, name: [*:0]const u8) !?[]const u8 {
    const kind = c.lua_getfield(L, 1, name);
    defer c.lua_settop(L, -2);
    if (kind == c.type_nil) return null;
    if (kind != c.type_string) return error.ExpectedString;
    var len: usize = 0;
    const p = c.lua_tolstring(L, -1, &len) orelse return null;
    return p[0..len];
}
fn fieldPositiveInt(L: *c.State, name: [*:0]const u8) !usize {
    _ = c.lua_getfield(L, 1, name);
    defer c.lua_settop(L, -2);
    if (c.lua_isinteger(L, -1) == 0) return error.ExpectedInteger;
    var ok: c_int = 0;
    const v = c.lua_tointegerx(L, -1, &ok);
    if (v <= 0 or v > std.math.maxInt(usize)) return error.ExpectedPositiveInteger;
    return @intCast(v);
}
fn fieldBool(L: *c.State, name: [*:0]const u8) !bool {
    _ = c.lua_getfield(L, 1, name);
    defer c.lua_settop(L, -2);
    if (c.lua_type(L, -1) != c.type_boolean) return error.ExpectedBoolean;
    return c.lua_toboolean(L, -1) != 0;
}
fn pushFailure(L: *c.State, name: [*:0]const u8) c_int {
    c.lua_pushnil(L);
    c.lua_createtable(L, 0, 2);
    _ = c.lua_pushstring(L, name);
    c.lua_setfield(L, -2, "code");
    _ = c.lua_pushstring(L, name);
    c.lua_setfield(L, -2, "message");
    return 2;
}
fn sameHandle(a: io.OperationHandle, b: io.OperationHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "padded asymmetric RGB and alpha raw images normalize independently" {
    const rgb_bytes: []const u8 = &.{ 1, 2, 3, 4, 5, 6, 99, 8, 9, 10, 11, 12, 13 };
    var rgb = try rawBitmap(.{ .bytes = rgb_bytes, .width = 2, .height = 2, .stride = 7, .channels = 3 });
    defer rgb.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255, 8, 9, 10, 255, 11, 12, 13, 255 }, rgb.pixels);

    const rgba_bytes: []const u8 = &.{ 10, 20, 30, 40, 50, 60, 70, 80 };
    var rgba = try rawBitmap(.{ .bytes = rgba_bytes, .width = 1, .height = 2, .stride = 4, .channels = 4 });
    defer rgba.deinit();
    const straight = try thumbnail(std.testing.allocator, rgba);
    defer std.testing.allocator.free(straight.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 13, 19, 32, 40, 51, 61, 70, 80 }, straight.pixels);
}

test "thumbnail preserves aspect ratio and never upscales" {
    const pixels = try std.testing.allocator.alloc(u8, 256 * 64 * 4);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 255);
    const result = try thumbnail(std.testing.allocator, .{ .allocator = std.testing.allocator, .pixels = pixels, .width = 256, .height = 64, .intrinsic_width = 256, .intrinsic_height = 64 });
    defer std.testing.allocator.free(result.pixels);
    try std.testing.expectEqual(@as(usize, 128), result.width);
    try std.testing.expectEqual(@as(usize, 32), result.height);
}

const TestRuntime = struct {
    loop: io.Loop = undefined,
    scheduler: task.Scheduler = undefined,
    vm: vm_module.Vm = undefined,
    binding: Binding = undefined,

    fn init(self: *TestRuntime) !void {
        try self.loop.init(std.testing.allocator, 16, 16);
        try self.scheduler.init(std.testing.allocator, 8, 8, 8);
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        self.binding.init(&self.vm, &self.loop);
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
    fn complete(self: *TestRuntime) !void {
        while (self.loop.hasPendingOperations()) {
            _ = try self.loop.submit();
            switch (self.loop.dispatch(try self.loop.wait())) {
                .file => |completion| try std.testing.expect(try self.binding.dispatch(completion)),
                else => return error.UnexpectedCompletion,
            }
        }
    }
    fn resumeAll(self: *TestRuntime) !void {
        while (self.scheduler.takeRunnable()) |runnable| _ = try self.vm.resumeRunnable(runnable);
        self.binding.collectCanceled();
    }
    fn cancel(self: *TestRuntime) !void {
        try self.vm.requestCancellation();
        try self.resumeAll();
        try self.complete();
        try self.resumeAll();
        try std.testing.expectEqual(@as(usize, 0), self.vm.activeTaskCount());
        for (self.binding.jobs) |job| try std.testing.expect(job == null);
    }
};

test "image import validates raw metadata and returns owned pixels asynchronously" {
    var runtime: TestRuntime = .{};
    try runtime.init();
    defer runtime.deinit();
    defer runtime.cancel() catch unreachable;
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
        \\local load = require('ouro').images.load
        \\local function options()
        \\  return { data = string.char(1,2,3,4,5,6,99,8,9,10,11,12,13),
        \\    width = 2, height = 2, rowstride = 7, bits_per_sample = 8, channels = 3, has_alpha = false }
        \\end
        \\for _, field in ipairs({'width', 'height', 'rowstride'}) do
        \\  local v = options(); v[field] = 0; assert(load(v) == nil)
        \\end
        \\for _, change in ipairs({{'rowstride',5}, {'channels',4}, {'bits_per_sample',16},
        \\  {'has_alpha',true}, {'width',1025}, {'data','short'}, {'data',123}, {'path',false}}) do
        \\  local v = options(); v[change[1]] = change[2]; assert(load(v) == nil)
        \\end
        \\assert(load{path='relative.png'} == nil)
        \\assert(load{path='/tmp/a',data='x'} == nil)
        \\result = assert(load(options()))
    ));
    try std.testing.expect(runtime.binding.jobs[0] != null);
    try runtime.complete();
    try runtime.resumeAll();
    _ = c.lua_getglobal(runtime.vm.state, "result");
    var len: usize = 0;
    const bytes = c.lua_tolstring(runtime.vm.state, -1, &len).?[0..len];
    var bitmap = try codec.decode(std.testing.allocator, bytes, .{});
    defer bitmap.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255, 8, 9, 10, 255, 11, 12, 13, 255 }, bitmap.pixels);
    c.lua_settop(runtime.vm.state, -2);
}

test "image import bounds concurrency and drains cancellation before and after completion" {
    for ([_]bool{ false, true }) |ready| {
        var runtime: TestRuntime = .{};
        try runtime.init();
        defer runtime.deinit();
        for (0..max_jobs) |_| try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
            \\local bytes = require('ouro').images.load{data='rgb', width=1, height=1,
            \\  rowstride=3, channels=3, bits_per_sample=8, has_alpha=false}
            \\error('canceled import resumed')
        ));
        try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.start(
            \\local bytes, err = require('ouro').images.load{path='/missing.png'}
            \\assert(bytes == nil and err.code == 'ImageImportBusy')
        ));
        if (ready) try runtime.complete();
        try runtime.cancel();
    }
}

test "image import drains a signaled failure without a worker thread" {
    for ([_]bool{ false, true }) |cancelled| {
        var runtime: TestRuntime = .{};
        try runtime.init();
        defer runtime.deinit();
        defer runtime.cancel() catch unreachable;
        try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
            \\local bytes, err = require('ouro').images.load{data='rgb', width=1, height=1,
            \\  rowstride=3, channels=3, bits_per_sample=8, has_alpha=false}
            \\assert(bytes == nil and err.code == 'ThreadSpawnFailed')
        ));
        // Reproduce spawn failure's state: a signaled pipe and an error, with
        // no thread to join. Its operation still owns the job until dispatch.
        const job = runtime.binding.jobs[0].?;
        job.thread.?.join();
        job.thread = null;
        if (job.result) |bytes| std.heap.page_allocator.free(bytes) else |_| {}
        job.result = error.ThreadSpawnFailed;
        if (cancelled) {
            try runtime.cancel();
        } else {
            try runtime.complete();
            try runtime.resumeAll();
        }
    }
}

test "file imports own content and reject missing, oversized, symlink and special sources" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const image = try png.encode(std.testing.allocator, &.{ 31, 72, 119, 255 }, 1, 1, 4);
    defer std.testing.allocator.free(image);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "image.png", .data = image });
    const large = try std.testing.allocator.alloc(u8, max_encoded + 1);
    defer std.testing.allocator.free(large);
    @memset(large, 0);
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "large.png", .data = large });
    const link = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/link.png", .{root}, 0);
    defer std.testing.allocator.free(link);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlink("image.png", link)));
    const fifo = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/fifo", .{root}, 0);
    defer std.testing.allocator.free(fifo);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknod(fifo, linux.S.IFIFO | 0o600, 0)));
    var runtime: TestRuntime = .{};
    try runtime.init();
    defer runtime.deinit();
    defer runtime.cancel() catch unreachable;
    _ = c.lua_pushlstring(runtime.vm.state, root.ptr, root.len);
    c.lua_setglobal(runtime.vm.state, "root");
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
        \\result = assert(require('ouro').images.load{path=root .. '/image.png'})
    ));
    try runtime.complete();
    try runtime.resumeAll();
    try temporary.dir.deleteFile(std.testing.io, "image.png");
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.start(
        \\local load = require('ouro').images.load
        \\assert(result:sub(1,8) == '\137PNG\r\n\26\n')
        \\for _, path in ipairs({'/image.png','/large.png','/link.png','/fifo','/'}) do
        \\  local bytes, err = load{path=root .. path}; assert(not bytes and err.code)
        \\end
    ));
    while (runtime.vm.activeTaskCount() != 0) {
        try runtime.complete();
        try runtime.resumeAll();
    }
}
