const std = @import("std");
const files = @import("files.zig");
const c = @import("c.zig");
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const vm_module = @import("vm.zig");

const Runtime = struct {
    loop: io.Loop = undefined,
    scheduler: task.Scheduler = undefined,
    vm: vm_module.Vm = undefined,
    binding: files.Binding = undefined,

    fn init(self: *Runtime) !void {
        try self.loop.init(std.testing.allocator, 16, 16);
        errdefer self.loop.deinit();
        try self.scheduler.init(std.testing.allocator, 4, 8, 8);
        errdefer self.scheduler.deinit();
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        errdefer self.vm.deinit();
        try self.binding.init(std.testing.allocator, &self.vm, &self.loop);
    }

    fn deinit(self: *Runtime) void {
        self.binding.stop();
        while (!self.binding.canDeinit()) self.complete() catch unreachable;
        self.binding.deinit();
        self.vm.deinit();
        self.scheduler.deinit();
        self.loop.deinit();
    }

    fn setString(self: *Runtime, name: [*:0]const u8, value: []const u8) void {
        _ = c.lua_pushlstring(self.vm.state, value.ptr, value.len);
        c.lua_setglobal(self.vm.state, name);
    }

    fn complete(self: *Runtime) !void {
        _ = try self.loop.submit();
        switch (self.loop.dispatch(try self.loop.wait())) {
            .file => |completion| try std.testing.expect(try self.binding.dispatch(completion)),
            .operation_cancel => self.binding.collectCanceled(),
            else => return error.UnexpectedCompletion,
        }
    }

    fn run(self: *Runtime, source: []const u8) !void {
        _ = try self.vm.spawnApplication(source);
        while (true) {
            while (self.scheduler.takeRunnable()) |runnable| {
                const result = try self.vm.resumeRunnable(runnable);
                if (result == .completed) return;
            }
            try self.complete();
        }
    }
};

test "strict local URI conversion preserves escaped bytes" {
    const a = std.testing.allocator;
    const path = try files.decodeLocalPath(a, "file://localhost/tmp/a%20b%ff");
    defer a.free(path);
    try std.testing.expectEqualSlices(u8, "/tmp/a b\xff", path);
    try std.testing.expectError(error.NonLocalFileUri, files.decodeLocalPath(a, "file://example.com/tmp/a"));
    try std.testing.expectError(error.InvalidFileUri, files.decodeLocalPath(a, "file:///tmp/a?x"));
    try std.testing.expectError(error.MalformedEscape, files.decodeLocalPath(a, "file:///tmp/%x0"));
    try std.testing.expectError(error.InvalidFileUri, files.decodeLocalPath(a, "file:///tmp/%00"));
    try std.testing.expectError(error.InvalidFileUri, files.decodeLocalPath(a, "file:///tmp/a%2fb"));
}

test "plain paths must be absolute and NUL-free" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.PathMustBeAbsolute, files.decodeLocalPath(a, "relative"));
    try std.testing.expectError(error.InvalidPath, files.decodeLocalPath(a, "/tmp/a\x00b"));
}

test "files binding writes and reads asymmetric binary data and opens owned FDs" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "payload" });
    defer std.testing.allocator.free(path);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", path);
    const payload = "\x00short\xff" ++ ("0123456789abcdef" ** 4097) ++ "tail\x00";
    runtime.setString("payload", payload);
    try runtime.run(
        \\local f = require('ouro').files
        \\local ok, e = f.write(path, payload); assert(ok and not e)
        \\local got, re = f.read(path, {max_bytes = #payload}); assert(not re and got == payload)
        \\local fd, oe = f.open(path); assert(fd and not oe)
        \\done = true
    );
    try std.testing.expect(runtime.vm.globalBoolean("done"));
    const actual = try temporary.dir.readFileAlloc(std.testing.io, "payload", std.testing.allocator, .limited(payload.len + 1));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, payload, actual);
}

test "files read limit and failed replacement preserve destination" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "payload", .data = "preserved-long-value" });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "payload", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", path);
    try runtime.run(
        \\local f = require('ouro').files
        \\local bytes, e = f.read(path, {max_bytes = 3}); assert(bytes == nil and e.name == 'FileTooLarge' and e.message)
        \\local ok, we = f.write(path .. '/child', 'replacement'); assert(ok == nil and we)
        \\checked = true
    );
    try std.testing.expect(runtime.vm.globalBoolean("checked"));
    const actual = try temporary.dir.readFileAlloc(std.testing.io, "payload", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("preserved-long-value", actual);
}

test "files open and read reject devices and FIFOs without opening them blocking" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const fifo_z = try std.fs.path.joinZ(std.testing.allocator, &.{ directory, "pipe" });
    defer std.testing.allocator.free(fifo_z);
    const made = std.os.linux.mknodat(std.os.linux.AT.FDCWD, fifo_z, std.os.linux.S.IFIFO | 0o600, 0);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(made));
    const fifo = try temporary.dir.realPathFileAlloc(std.testing.io, "pipe", std.testing.allocator);
    defer std.testing.allocator.free(fifo);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("fifo", fifo);
    try runtime.run(
        \\local f = require('ouro').files
        \\local b, re = f.read(fifo); assert(b == nil and re.name == 'NotRegularFile')
        \\local fd, fe = f.open(fifo); assert(fd == nil and fe.name == 'NotRegularFileOrDirectory')
        \\local dev, de = f.open('/dev/null'); assert(dev == nil and de.name == 'NotRegularFileOrDirectory')
        \\checked = true
    );
    try std.testing.expect(runtime.vm.globalBoolean("checked"));
}

test "files stop cancels and drains workers without stale Lua resume" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "payload", .data = "input" ** 16384 });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "payload", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", path);
    _ = try runtime.vm.spawnApplication("require('ouro').files.read(path); stale_resume=true");
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
    runtime.binding.stop();
    try runtime.vm.requestCancellation();
    while (!runtime.binding.canDeinit()) try runtime.complete();
    try std.testing.expectEqual(vm_module.ResumeResult.canceled, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
    try std.testing.expect(!runtime.vm.hasGlobal("stale_resume"));
    try std.testing.expectEqual(@as(usize, 0), runtime.vm.activeTaskCount());

    _ = try runtime.vm.spawnApplication(
        \\local value,e=require('ouro').files.read(path)
        \\assert(value == nil and e.name == 'GenerationStopping')
        \\rejected=true
    );
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
    try std.testing.expect(runtime.vm.globalBoolean("rejected"));
}

test "files write preserves rwx modes, strips special bits and offers private replacement" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ directory, "document" });
    defer std.testing.allocator.free(path);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", path);
    try runtime.run("assert(require('ouro').files.write(path, 'new'))");
    const private_mode = (try fileStat(path)).mode & 0o7777;
    try std.testing.expectEqual(@as(u16, 0), private_mode & ~@as(u16, 0o600));
    for ([_]u32{ 0o664, 0o751, 0o440, 0o000, 0o7751 }) |mode| {
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fchmodat(std.os.linux.AT.FDCWD, path, mode)));
        try runtime.run("assert(require('ouro').files.write(path, 'replacement'))");
        try std.testing.expectEqual(@as(u16, @intCast(mode & 0o777)), (try fileStat(path)).mode & 0o7777);
    }
    try runtime.run(
        \\assert(require('ouro').files.write(path, 'private', {permissions='private', symlinks='replace', durable=false}))
    );
    try std.testing.expectEqual(private_mode, (try fileStat(path)).mode & 0o7777);
    const actual = try temporary.dir.readFileAlloc(std.testing.io, "document", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("private", actual);
}

test "files write rejects links by default and explicitly replaces links without touching targets" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "target", .data = "target stays" });
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ directory, "link" });
    defer std.testing.allocator.free(path);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", path);
    for ([_][:0]const u8{ "target", "missing-target" }) |target| {
        try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.symlinkat(target, temporary.dir.handle, "link")));
        try runtime.run(
            \\local ok, e = require('ouro').files.write(path, 'replacement')
            \\assert(ok == nil and e.name == 'SymlinkNotAllowed' and not e.committed)
        );
        try std.testing.expectEqual(@as(u16, std.os.linux.S.IFLNK), (try fileStat(path)).mode & std.os.linux.S.IFMT);
        try runtime.run("assert(require('ouro').files.write(path, 'replacement', {symlinks='replace'}))");
        try std.testing.expectEqual(@as(u16, std.os.linux.S.IFREG), (try fileStat(path)).mode & std.os.linux.S.IFMT);
        try std.testing.expectEqual(@as(u16, 0), (try fileStat(path)).mode & 0o177);
        const actual = try temporary.dir.readFileAlloc(std.testing.io, "link", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("replacement", actual);
        try temporary.dir.deleteFile(std.testing.io, "link");
    }
    const target = try temporary.dir.readFileAlloc(std.testing.io, "target", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("target stays", target);
    try std.testing.expectError(error.FileNotFound, temporary.dir.openFile(std.testing.io, "missing-target", .{}));
}

test "files write rejects malformed policies before changing the destination" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "document", .data = "original" });
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, "document", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", path);
    try runtime.run(
        \\local f = require('ouro').files
        \\for _, options in ipairs({false, 'preserve', {permissions='all'}, {symlinks='follow'}, {durable=1}, {durabl=false}, {[1]='private'}}) do
        \\    local ok, e = f.write(path, 'wrong', options)
        \\    assert(ok == nil and e.name == 'InvalidOptions' and not e.committed)
        \\end
        \\assert(f.read(path) == 'original')
        \\assert(f.write(path, 'valid', {}))
    );
}

fn fileStat(path: [:0]const u8) !std.os.linux.Statx {
    var stat: std.os.linux.Statx = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.statx(std.os.linux.AT.FDCWD, path, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &stat)));
    return stat;
}

test "files write reports committed durability errors to Lua" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "document" });
    defer std.testing.allocator.free(path);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", path);
    _ = try runtime.vm.spawnApplication(
        \\local ok, e = require('ouro').files.write(path, '')
        \\assert(ok == nil and e.name == 'DurabilityUncertain' and e.committed == true)
        \\reported = true
    );
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
    try runtime.complete();
    // The worker's injected syscall failures are tested in files.zig. Here,
    // inject its post-rename result after joining to exercise Lua delivery.
    const job = runtime.binding.jobs[0].?;
    _ = try job.result;
    job.result = error.DurabilityUncertain;
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try runtime.vm.resumeRunnable(runtime.scheduler.takeRunnable().?));
    try std.testing.expect(runtime.vm.globalBoolean("reported"));
}

test "files write refuses directory and FIFO destinations without changing them" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "directory", .default_dir);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mknodat(temporary.dir.handle, "fifo", std.os.linux.S.IFIFO | 0o600, 0)));
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    var runtime: Runtime = .{};
    try runtime.init();
    defer runtime.deinit();
    runtime.setString("path", directory);
    try runtime.run(
        \\for _, name in ipairs({'directory', 'fifo'}) do
        \\    local ok, e = require('ouro').files.write(path .. '/' .. name, 'wrong', {symlinks='replace'})
        \\    assert(ok == nil and e.name == 'NotRegularFile' and not e.committed)
        \\end
    );
    var stat: std.os.linux.Statx = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.statx(temporary.dir.handle, "fifo", 0, .{ .TYPE = true }, &stat)));
    try std.testing.expectEqual(@as(u16, std.os.linux.S.IFIFO), stat.mode & std.os.linux.S.IFMT);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.statx(temporary.dir.handle, "directory", 0, .{ .TYPE = true }, &stat)));
    try std.testing.expectEqual(@as(u16, std.os.linux.S.IFDIR), stat.mode & std.os.linux.S.IFMT);
}
