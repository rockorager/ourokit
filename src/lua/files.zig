//! Small, bounded local-file API.  Filesystem work runs outside the VM thread;
//! the application io_uring is used only to publish worker completion.
const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const c = @import("c.zig");
const unwrapView = @import("machine.zig").unwrapView;
const vm_module = @import("vm.zig");
const dbus_values = @import("dbus_values.zig");

pub const default_max_bytes = 16 * 1024 * 1024;
pub const absolute_max_bytes = 64 * 1024 * 1024;
const capacity = 8;

const Kind = enum { read, write, open, mkdir };
const Phase = enum(u8) { working, canceled, committing, committed };
const WriteOptions = struct {
    permissions: enum { preserve, private } = .preserve,
    symlinks: enum { reject, replace } = .reject,
    durable: bool = true,
};
const Job = struct {
    owner: *Binding,
    kind: Kind,
    path: []u8,
    writable: bool = false,
    write_options: WriteOptions = .{},
    bytes: []u8 = &.{},
    limit: usize = default_max_bytes,
    result: anyerror![]u8 = error.NotStarted,
    pipe: [2]linux.fd_t,
    signal: [1]u8 = undefined,
    operation: ?io.OperationHandle = null,
    thread: ?std.Thread = null,
    task_handle: vm_module.TaskHandle = .invalid,
    phase: std.atomic.Value(Phase) = .init(.working),
    result_fd: linux.fd_t = -1,

    fn run(self: *Job) void {
        self.result = switch (self.kind) {
            .read => readFile(self.path, self.limit),
            .write => writeFile(self),
            .open => openFile(self),
            .mkdir => makeDirectory(self),
        };
        while (linux.errno(linux.write(self.pipe[1], &.{1}, 1)) == .INTR) {}
        _ = linux.close(self.pipe[1]);
    }
};

pub const Binding = struct {
    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    loop: *io.Loop,
    jobs: [capacity]?*Job = @splat(null),
    stopping: bool = false,

    pub fn init(self: *Binding, allocator: std.mem.Allocator, vm: *vm_module.Vm, loop: *io.Loop) !void {
        self.* = .{ .allocator = allocator, .vm = vm, .loop = loop };
        const L = vm.state;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        vm.pushApi(L);
        c.lua_createtable(L, 0, 3);
        c.lua_pushlightuserdata(L, self);
        c.lua_pushinteger(L, @intFromEnum(Kind.read));
        c.lua_pushcclosure(L, call, 2);
        c.lua_setfield(L, -2, "read");
        c.lua_pushlightuserdata(L, self);
        c.lua_pushinteger(L, @intFromEnum(Kind.write));
        c.lua_pushcclosure(L, call, 2);
        c.lua_setfield(L, -2, "write");
        c.lua_pushlightuserdata(L, self);
        c.lua_pushinteger(L, @intFromEnum(Kind.open));
        c.lua_pushcclosure(L, call, 2);
        c.lua_setfield(L, -2, "open");
        c.lua_pushlightuserdata(L, self);
        c.lua_pushinteger(L, @intFromEnum(Kind.mkdir));
        c.lua_pushcclosure(L, call, 2);
        c.lua_setfield(L, -2, "mkdir");
        c.lua_setfield(L, -2, "files");
    }

    /// File-completion dispatch hook. Never enters Lua.
    pub fn dispatch(self: *Binding, completion: io.FileCompletion) !bool {
        for (&self.jobs) |*slot| if (slot.*) |job| {
            const op = job.operation orelse continue;
            if (!same(op, completion.operation)) continue;
            if (completion.kind != .read) return error.UnexpectedFilesCompletion;
            job.operation = null;
            if (job.thread) |thread| thread.join();
            job.thread = null;
            _ = linux.close(job.pipe[0]);
            try self.vm.markExternalCompleted(job.task_handle);
            if (job.phase.load(.acquire) == .canceled or self.vm.taskCancellationRequested(job.task_handle)) self.release(slot);
            return true;
        };
        return false;
    }

    /// Safe-point/cancellation collection hook.
    pub fn collectCanceled(self: *Binding) void {
        for (&self.jobs) |*slot| if (slot.*) |job|
            if (job.operation == null and (job.phase.load(.acquire) == .canceled or self.vm.taskCancellationRequested(job.task_handle))) self.release(slot);
    }

    /// Generation-stop hook. Existing jobs drain; no new jobs are accepted.
    pub fn stop(self: *Binding) void {
        self.stopping = true;
        for (self.jobs) |job| if (job) |j| requestCancel(j) catch {};
    }
    pub fn canDeinit(self: *const Binding) bool {
        for (self.jobs) |job| if (job != null) return false;
        return true;
    }
    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.canDeinit());
        self.* = undefined;
    }

    fn release(self: *Binding, slot: *?*Job) void {
        const job = slot.*.?;
        if (job.result) |bytes| std.heap.page_allocator.free(bytes) else |_| {}
        if (job.result_fd >= 0) _ = linux.close(job.result_fd);
        self.allocator.free(job.path);
        if (job.bytes.len != 0) self.allocator.free(job.bytes);
        self.allocator.destroy(job);
        slot.* = null;
    }

    fn call(L: *c.State) callconv(.c) c_int {
        const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
        var valid: c_int = 0;
        const kind: Kind = @enumFromInt(c.lua_tointegerx(L, c.upvalueIndex(2), &valid));
        if (self.stopping) return pushFailure(L, "GenerationStopping");
        const argc = c.lua_gettop(L);
        if (((kind == .read or kind == .open) and (argc < 1 or argc > 2)) or (kind == .write and (argc < 2 or argc > 3)) or (kind == .mkdir and argc != 1)) return pushFailure(L, "InvalidArguments");
        const input = luaBytes(L, 1) orelse return pushFailure(L, "ExpectedPath");
        const path = decodeLocalPath(self.allocator, input) catch |err| return pushFailure(L, @errorName(err));
        var limit: usize = default_max_bytes;
        var writable = false;
        var write_options: WriteOptions = .{};
        var payload: []u8 = &.{};
        if (kind == .read and argc == 2) {
            if (unwrapView(L, 2) != c.type_table) {
                self.allocator.free(path);
                return pushFailure(L, "InvalidOptions");
            }
            _ = c.lua_getfield(L, 2, "max_bytes");
            if (c.lua_type(L, -1) != c.type_nil) {
                var ok: c_int = 0;
                const n = c.lua_tointegerx(L, -1, &ok);
                if (ok == 0 or n <= 0 or n > absolute_max_bytes) {
                    c.lua_settop(L, -2);
                    self.allocator.free(path);
                    return pushFailure(L, "InvalidMaxBytes");
                }
                limit = @intCast(n);
            }
            c.lua_settop(L, -2);
        } else if (kind == .open and argc == 2) {
            if (unwrapView(L, 2) != c.type_table) {
                self.allocator.free(path);
                return pushFailure(L, "InvalidOptions");
            }
            _ = c.lua_getfield(L, 2, "writable");
            const option_type = c.lua_type(L, -1);
            if (option_type != c.type_nil and option_type != c.type_boolean) {
                c.lua_settop(L, -2);
                self.allocator.free(path);
                return pushFailure(L, "InvalidOptions");
            }
            writable = c.lua_toboolean(L, -1) != 0;
            c.lua_settop(L, -2);
        } else if (kind == .write) {
            if (argc == 3) write_options = parseWriteOptions(L) catch {
                self.allocator.free(path);
                return pushFailure(L, "InvalidOptions");
            };
            const source = luaBytes(L, 2) orelse {
                self.allocator.free(path);
                return pushFailure(L, "ExpectedBytes");
            };
            if (source.len > absolute_max_bytes) {
                self.allocator.free(path);
                return pushFailure(L, "FileTooLarge");
            }
            payload = self.allocator.dupe(u8, source) catch {
                self.allocator.free(path);
                return pushFailure(L, "OutOfMemory");
            };
        }
        const slot = for (&self.jobs) |*candidate| if (candidate.* == null) break candidate else continue else {
            self.allocator.free(path);
            if (payload.len != 0) self.allocator.free(payload);
            return pushFailure(L, "FilesBusy");
        };
        var pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) {
            self.allocator.free(path);
            if (payload.len != 0) self.allocator.free(payload);
            return pushFailure(L, "PipeFailed");
        }
        const job = self.allocator.create(Job) catch {
            _ = linux.close(pipe[0]);
            _ = linux.close(pipe[1]);
            self.allocator.free(path);
            if (payload.len != 0) self.allocator.free(payload);
            return pushFailure(L, "OutOfMemory");
        };
        job.* = .{ .owner = self, .kind = kind, .path = path, .writable = writable, .write_options = write_options, .bytes = payload, .limit = limit, .pipe = pipe };
        job.task_handle = self.vm.beginExternalWait(L, .operation, job, &lifecycle) catch {
            self.allocator.destroy(job);
            _ = linux.close(pipe[0]);
            _ = linux.close(pipe[1]);
            self.allocator.free(path);
            if (payload.len != 0) self.allocator.free(payload);
            return pushFailure(L, "CouldNotPark");
        };
        job.operation = self.loop.prepareRead(pipe[0], &job.signal, std.math.maxInt(u64)) catch {
            self.vm.abortExternalWait(L, job.task_handle) catch unreachable;
            self.allocator.destroy(job);
            _ = linux.close(pipe[0]);
            _ = linux.close(pipe[1]);
            self.allocator.free(path);
            if (payload.len != 0) self.allocator.free(payload);
            return pushFailure(L, "CouldNotPrepare");
        };
        slot.* = job;
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
            job.result = err;
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
        switch (job.kind) {
            .read => _ = c.lua_pushlstring(L, bytes.ptr, bytes.len),
            .write, .mkdir => c.lua_pushboolean(L, 1),
            .open => {
                dbus_values.pushOwnedFd(L, job.result_fd) catch {
                    job.owner.release(slot);
                    return pushFailure(L, "OutOfMemory");
                };
                job.result_fd = -1;
            },
        }
        job.owner.release(slot);
        return 1;
    } else |err| {
        job.owner.release(slot);
        const count = pushFailure(L, @errorName(err));
        if (err == error.DurabilityUncertain) {
            c.lua_pushboolean(L, 1);
            c.lua_setfield(L, -2, "committed");
        }
        return count;
    }
}

fn parseWriteOptions(L: *c.State) !WriteOptions {
    if (unwrapView(L, 3) != c.type_table) return error.InvalidOptions;
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    var options: WriteOptions = .{};
    // Reject unknown keys, including misspellings of a save policy.
    c.lua_pushnil(L);
    while (c.lua_next(L, 3) != 0) {
        const key = luaBytes(L, -2) orelse return error.InvalidOptions;
        if (std.mem.eql(u8, key, "permissions")) {
            options.permissions = std.meta.stringToEnum(@TypeOf(options.permissions), luaBytes(L, -1) orelse return error.InvalidOptions) orelse return error.InvalidOptions;
        } else if (std.mem.eql(u8, key, "symlinks")) {
            options.symlinks = std.meta.stringToEnum(@TypeOf(options.symlinks), luaBytes(L, -1) orelse return error.InvalidOptions) orelse return error.InvalidOptions;
        } else if (std.mem.eql(u8, key, "durable")) {
            if (c.lua_type(L, -1) != c.type_boolean) return error.InvalidOptions;
            options.durable = c.lua_toboolean(L, -1) != 0;
        } else return error.InvalidOptions;
        c.lua_settop(L, -2);
    }
    return options;
}

fn requestCancel(pointer: *anyopaque) !void {
    const job: *Job = @ptrCast(@alignCast(pointer));
    _ = job.phase.cmpxchgStrong(.working, .canceled, .acq_rel, .acquire);
}
fn destroy(_: *anyopaque) void {}
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = requestCancel, .destroy = destroy };

fn readFile(path: []const u8, limit: usize) ![]u8 {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const raw = linux.openat(linux.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
    try check(raw);
    const fd: linux.fd_t = @intCast(raw);
    defer _ = linux.close(fd);
    var stat: linux.Statx = undefined;
    try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stat));
    if (stat.mode & linux.S.IFMT != linux.S.IFREG) return error.NotRegularFile;
    if (stat.size > limit) return error.FileTooLarge;
    const expected: usize = @intCast(stat.size);
    const out = try std.heap.page_allocator.alloc(u8, expected + 1);
    errdefer std.heap.page_allocator.free(out);
    var at: usize = 0;
    while (at < expected) {
        const result = linux.read(fd, out[at..].ptr, expected - at);
        if (linux.errno(result) == .INTR) continue;
        try check(result);
        const n: usize = @intCast(result);
        if (n == 0) return error.UnexpectedEndOfFile;
        at += n;
    }
    while (true) {
        const result = linux.read(fd, out[expected..].ptr, 1);
        if (linux.errno(result) == .INTR) continue;
        try check(result);
        if (result != 0) return error.FileChangedDuringRead;
        break;
    }
    return try std.heap.page_allocator.realloc(out, expected);
}

fn openFile(job: *Job) ![]u8 {
    const path = try std.heap.page_allocator.dupeZ(u8, job.path);
    defer std.heap.page_allocator.free(path);
    const raw = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = if (job.writable) .RDWR else .RDONLY, .CLOEXEC = true, .NONBLOCK = true }, 0);
    try check(raw);
    const fd: linux.fd_t = @intCast(raw);
    errdefer _ = linux.close(fd);
    var stat: linux.Statx = undefined;
    try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat));
    const kind = stat.mode & linux.S.IFMT;
    if (kind != linux.S.IFREG and kind != linux.S.IFDIR) return error.NotRegularFileOrDirectory;
    job.result_fd = fd;
    return &.{};
}

fn makeDirectory(job: *Job) ![]u8 {
    var components = std.mem.tokenizeScalar(u8, job.path, '/');
    while (components.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
    const opened = linux.openat(linux.AT.FDCWD, "/", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true }, 0);
    try check(opened);
    var fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    components.reset();
    while (components.next()) |part| {
        if (job.phase.load(.acquire) == .canceled) return error.Canceled;
        const name = try std.heap.page_allocator.dupeZ(u8, part);
        defer std.heap.page_allocator.free(name);
        const made = linux.mkdirat(fd, name, 0o700);
        if (linux.errno(made) != .EXIST) try check(made);
        const child = linux.openat(fd, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true }, 0);
        try check(child);
        _ = linux.close(fd);
        fd = @intCast(child);
    }
    return &.{};
}

fn writeFile(job: *Job) ![]u8 {
    return writeFileWith(job, linux);
}

// The syscall parameter allows deterministic tests at the commit boundary.
fn writeFileWith(job: *Job, comptime Sys: type) ![]u8 {
    if (job.phase.load(.acquire) == .canceled) return error.Canceled;
    const directory = std.fs.path.dirname(job.path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(job.path);
    const directory_z = try std.heap.page_allocator.dupeZ(u8, directory);
    defer std.heap.page_allocator.free(directory_z);
    const opened_directory = linux.openat(linux.AT.FDCWD, directory_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true }, 0);
    try check(opened_directory);
    const directory_fd: linux.fd_t = @intCast(opened_directory);
    defer _ = linux.close(directory_fd);
    const base_z = try std.heap.page_allocator.dupeZ(u8, base);
    defer std.heap.page_allocator.free(base_z);
    const mode = try destinationMode(directory_fd, base_z, job.write_options);
    var random: [8]u8 = undefined;
    const random_size = linux.getrandom(&random, random.len, 0);
    try check(random_size);
    if (random_size != random.len) return error.RandomUnavailable;
    const temp = try std.fmt.allocPrintSentinel(std.heap.page_allocator, ".{s}.ouro-{x}", .{ base, random }, 0);
    defer std.heap.page_allocator.free(temp);
    const opened = linux.openat(directory_fd, temp, .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .CREAT = true, .EXCL = true }, 0o600);
    try check(opened);
    const fd: linux.fd_t = @intCast(opened);
    var exists = true;
    defer {
        _ = linux.close(fd);
        if (exists) _ = linux.unlinkat(directory_fd, temp, 0);
    }
    var at: usize = 0;
    while (at < job.bytes.len) {
        if (job.phase.load(.acquire) == .canceled) return error.Canceled;
        const slice = job.bytes[at..@min(job.bytes.len, at + 64 * 1024)];
        const result = linux.write(fd, slice.ptr, slice.len);
        if (linux.errno(result) == .INTR) continue;
        try check(result);
        const n: usize = @intCast(result);
        if (n == 0) return error.WriteMadeNoProgress;
        at += n;
    }
    // Apply only rwx bits, after writing: never propagate set-ID/sticky bits.
    if (mode) |bits| try check(Sys.fchmod(fd, bits));
    try syncFile(fd, Sys);
    // Recheck the policy after staging; this is not a concurrent-writer lock.
    _ = try destinationMode(directory_fd, base_z, job.write_options);
    if (job.phase.cmpxchgStrong(.working, .committing, .acq_rel, .acquire) != null) return error.Canceled;
    try check(Sys.renameat(directory_fd, temp, directory_fd, base_z));
    exists = false;
    job.phase.store(.committed, .release);
    // Once the gate is crossed cancellation must not skip directory sync.
    if (job.write_options.durable) syncFile(directory_fd, Sys) catch return error.DurabilityUncertain;
    return &.{};
}

fn destinationMode(directory_fd: linux.fd_t, base: [*:0]const u8, options: WriteOptions) !?u32 {
    var stat: linux.Statx = undefined;
    const result = linux.statx(directory_fd, base, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &stat);
    if (linux.errno(result) == .NOENT) return null;
    try check(result);
    switch (stat.mode & linux.S.IFMT) {
        linux.S.IFLNK => {
            if (options.symlinks == .reject) return error.SymlinkNotAllowed;
            return null;
        },
        linux.S.IFREG => return if (options.permissions == .preserve) @as(u32, stat.mode & 0o777) else null,
        else => return error.NotRegularFile,
    }
}

fn syncFile(fd: linux.fd_t, comptime Sys: type) !void {
    while (true) {
        const result = Sys.fsync(fd);
        if (linux.errno(result) == .INTR) continue;
        return check(result);
    }
}

fn check(result: usize) !void {
    const e = linux.errno(result);
    if (e != .SUCCESS) return errnoError(e);
}

fn errnoError(e: linux.E) anyerror {
    return switch (e) {
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .ISDIR => error.IsDirectory,
        .NOTDIR => error.NotDirectory,
        .NOSPC => error.NoSpaceLeft,
        .ROFS => error.ReadOnlyFileSystem,
        else => error.FileSystemError,
    };
}

/// Strictly accepts absolute paths and local `file:` URIs. URI escapes decode
/// to filename bytes; encoded slash and NUL are rejected.
pub fn decodeLocalPath(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidPath;
    if (!std.mem.startsWith(u8, input, "file:")) {
        if (input.len == 0 or input[0] != '/') return error.PathMustBeAbsolute;
        return allocator.dupe(u8, input);
    }
    var rest = input[5..];
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return error.InvalidFileUri;
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidFileUri;
        const authority = rest[0..slash];
        if (authority.len != 0 and !std.ascii.eqlIgnoreCase(authority, "localhost")) return error.NonLocalFileUri;
        rest = rest[slash..];
    }
    if (rest.len == 0 or rest[0] != '/') return error.InvalidFileUri;
    var out = try allocator.alloc(u8, rest.len);
    errdefer allocator.free(out);
    var source: usize = 0;
    var dest: usize = 0;
    while (source < rest.len) {
        if (rest[source] == '%') {
            if (source + 2 >= rest.len) return error.MalformedEscape;
            const value = std.fmt.parseInt(u8, rest[source + 1 .. source + 3], 16) catch return error.MalformedEscape;
            if (value == 0 or value == '/') return error.InvalidFileUri;
            out[dest] = value;
            source += 3;
        } else {
            out[dest] = rest[source];
            source += 1;
        }
        dest += 1;
    }
    return allocator.realloc(out, dest);
}

fn luaBytes(L: *c.State, index: c_int) ?[]const u8 {
    if (c.lua_type(L, index) != c.type_string) return null;
    var n: usize = 0;
    const p = c.lua_tolstring(L, index, &n) orelse return null;
    return p[0..n];
}
fn pushFailure(L: *c.State, message: [*:0]const u8) c_int {
    c.lua_pushnil(L);
    c.lua_createtable(L, 0, 2);
    _ = c.lua_pushstring(L, message);
    c.lua_setfield(L, -2, "name");
    _ = c.lua_pushstring(L, message);
    c.lua_setfield(L, -2, "message");
    return 2;
}
fn same(a: io.OperationHandle, b: io.OperationHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "files write syscall failures and cancellation respect the commit gate" {
    const Case = enum { chmod_failure, file_sync_failure, rename_failure, directory_sync_failure, unsupported_sync, canceled_early, canceled_before_gate, canceled_after_gate, interrupted_sync, file_sync_only };
    const Sys = struct {
        var scenario: Case = undefined;
        var job: *Job = undefined;
        var events: [8]u8 = undefined;
        var count: usize = 0;
        var interrupted_file: bool = false;
        var interrupted_directory: bool = false;

        fn record(event: u8) void {
            events[count] = event;
            count += 1;
        }
        fn fail(e: linux.E) usize {
            return @bitCast(-@as(isize, @intFromEnum(e)));
        }
        pub fn fchmod(fd: linux.fd_t, mode: linux.mode_t) usize {
            record('m');
            if (scenario == .chmod_failure) return fail(.PERM);
            return linux.fchmod(fd, mode);
        }
        pub fn fsync(fd: linux.fd_t) usize {
            var stat: linux.Statx = undefined;
            check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &stat)) catch unreachable;
            const directory = stat.mode & linux.S.IFMT == linux.S.IFDIR;
            record(if (directory) 'd' else 'f');
            if (directory) {
                std.debug.assert(job.phase.load(.acquire) == .committed);
                if (scenario == .directory_sync_failure) return fail(.IO);
                if (scenario == .unsupported_sync) return fail(.INVAL);
            } else {
                if (scenario == .file_sync_failure) return fail(.NOSPC);
                if (scenario == .canceled_before_gate) requestCancel(job) catch unreachable;
            }
            if (scenario == .interrupted_sync) {
                const interrupted = if (directory) &interrupted_directory else &interrupted_file;
                if (!interrupted.*) {
                    interrupted.* = true;
                    return fail(.INTR);
                }
            }
            return linux.fsync(fd);
        }
        pub fn renameat(old_fd: linux.fd_t, old: [*:0]const u8, new_fd: linux.fd_t, new: [*:0]const u8) usize {
            record('r');
            std.debug.assert(job.phase.load(.acquire) == .committing);
            if (scenario == .rename_failure) return fail(.ACCES);
            if (scenario == .canceled_after_gate) requestCancel(job) catch unreachable;
            return linux.renameat(old_fd, old, new_fd, new);
        }
    };
    const scenarios = [_]struct { case: Case, failure: ?anyerror, committed: bool, events: []const u8 }{
        .{ .case = .chmod_failure, .failure = error.FileSystemError, .committed = false, .events = "m" },
        .{ .case = .file_sync_failure, .failure = error.NoSpaceLeft, .committed = false, .events = "mf" },
        .{ .case = .rename_failure, .failure = error.AccessDenied, .committed = false, .events = "mfr" },
        .{ .case = .directory_sync_failure, .failure = error.DurabilityUncertain, .committed = true, .events = "mfrd" },
        .{ .case = .unsupported_sync, .failure = error.DurabilityUncertain, .committed = true, .events = "mfrd" },
        .{ .case = .canceled_early, .failure = error.Canceled, .committed = false, .events = "" },
        .{ .case = .canceled_before_gate, .failure = error.Canceled, .committed = false, .events = "mf" },
        .{ .case = .canceled_after_gate, .failure = null, .committed = true, .events = "mfrd" },
        .{ .case = .interrupted_sync, .failure = null, .committed = true, .events = "mffrdd" },
        .{ .case = .file_sync_only, .failure = null, .committed = true, .events = "mfr" },
    };
    for (scenarios) |scenario| {
        var temporary = std.testing.tmpDir(.{ .iterate = true });
        defer temporary.cleanup();
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "document", .data = "original" });
        const path = try temporary.dir.realPathFileAlloc(std.testing.io, "document", std.testing.allocator);
        defer std.testing.allocator.free(path);
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        try check(linux.fchmodat(linux.AT.FDCWD, path_z, 0o641));
        var job: Job = .{
            .owner = undefined,
            .kind = .write,
            .path = path,
            .bytes = @constCast("replacement\x00tail"),
            .pipe = undefined,
            .write_options = .{ .durable = scenario.case != .file_sync_only },
        };
        Sys.scenario = scenario.case;
        Sys.job = &job;
        Sys.count = 0;
        Sys.interrupted_file = false;
        Sys.interrupted_directory = false;
        if (scenario.case == .canceled_early) try requestCancel(&job);
        if (scenario.failure) |failure| {
            try std.testing.expectError(failure, writeFileWith(&job, Sys));
        } else {
            _ = try writeFileWith(&job, Sys);
        }
        try std.testing.expectEqualStrings(scenario.events, Sys.events[0..Sys.count]);
        try std.testing.expectEqual(scenario.committed, job.phase.load(.acquire) == .committed);
        const actual = try temporary.dir.readFileAlloc(std.testing.io, "document", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(if (scenario.committed) "replacement\x00tail" else "original", actual);
        var stat: linux.Statx = undefined;
        try check(linux.statx(linux.AT.FDCWD, path_z, 0, .{ .MODE = true }, &stat));
        try std.testing.expectEqual(@as(u16, 0o641), stat.mode & 0o7777);
        var iterator = temporary.dir.iterate();
        const entry = (try iterator.next(std.testing.io)).?;
        try std.testing.expectEqualStrings("document", entry.name);
        try std.testing.expectEqual(null, try iterator.next(std.testing.io));
    }
}

test "files write pins the parent and rechecks destination symlinks before commit" {
    const Sys = struct {
        var root: linux.fd_t = undefined;
        var retarget_parent: bool = undefined;
        var staged: bool = false;
        pub const fchmod = linux.fchmod;
        pub const renameat = linux.renameat;
        pub fn fsync(fd: linux.fd_t) usize {
            if (!staged) {
                staged = true;
                if (retarget_parent) {
                    check(linux.unlinkat(root, "route", 0)) catch unreachable;
                    check(linux.symlinkat("second", root, "route")) catch unreachable;
                } else {
                    check(linux.renameat(root, "first/document", root, "first/original")) catch unreachable;
                    check(linux.symlinkat("original", root, "first/document")) catch unreachable;
                }
            } else {
                var expected: linux.Statx = undefined;
                var actual: linux.Statx = undefined;
                check(linux.statx(root, "first", 0, .{ .INO = true }, &expected)) catch unreachable;
                check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &actual)) catch unreachable;
                std.debug.assert(expected.ino == actual.ino);
            }
            return linux.fsync(fd);
        }
    };
    for ([_]bool{ true, false }) |retarget_parent| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDir(std.testing.io, "first", .default_dir);
        try temporary.dir.createDir(std.testing.io, "second", .default_dir);
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "first/document", .data = "first original" });
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "second/document", .data = "second untouched" });
        try check(linux.symlinkat("first", temporary.dir.handle, "route"));
        const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        const path = try std.fs.path.join(std.testing.allocator, &.{ root, "route/document" });
        defer std.testing.allocator.free(path);
        var job: Job = .{ .owner = undefined, .kind = .write, .path = path, .bytes = @constCast("saved"), .pipe = undefined };
        Sys.root = temporary.dir.handle;
        Sys.retarget_parent = retarget_parent;
        Sys.staged = false;
        if (retarget_parent) {
            _ = try writeFileWith(&job, Sys);
        } else {
            try std.testing.expectError(error.SymlinkNotAllowed, writeFileWith(&job, Sys));
            var stat: linux.Statx = undefined;
            try check(linux.statx(temporary.dir.handle, "first/document", linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &stat));
            try std.testing.expectEqual(@as(u16, linux.S.IFLNK), stat.mode & linux.S.IFMT);
        }
        const first = try temporary.dir.readFileAlloc(std.testing.io, "first/document", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(first);
        try std.testing.expectEqualStrings(if (retarget_parent) "saved" else "first original", first);
        const second = try temporary.dir.readFileAlloc(std.testing.io, "second/document", std.testing.allocator, .limited(64));
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualStrings("second untouched", second);
    }
}
