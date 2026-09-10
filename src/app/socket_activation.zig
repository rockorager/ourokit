const std = @import("std");
const linux = std.os.linux;

/// Detect, but never consume or close, systemd's named Varlink listener.
/// Repeated calls return the same descriptor. Ownership transfers only after
/// ControlServer initialization succeeds.
pub fn listener(environ: std.process.Environ) !?linux.fd_t {
    const pid_text = std.process.Environ.getPosix(environ, "LISTEN_PID") orelse return null;
    const pid = std.fmt.parseInt(linux.pid_t, pid_text, 10) catch return error.InvalidListenPid;
    if (pid != linux.getpid()) return null;
    const count_text = std.process.Environ.getPosix(environ, "LISTEN_FDS") orelse return error.MissingListenFds;
    const count = std.fmt.parseInt(u32, count_text, 10) catch return error.InvalidListenFds;
    if (count == 0) return null;
    if (count > std.math.maxInt(linux.fd_t) - 3) return error.InvalidListenFds;
    const names_text = std.process.Environ.getPosix(environ, "LISTEN_FDNAMES");
    var selected: ?linux.fd_t = null;
    if (names_text) |names| {
        var iterator = std.mem.splitScalar(u8, names, ':');
        for (0..count) |index| {
            const name = iterator.next() orelse return error.InvalidListenFdNames;
            if (std.mem.eql(u8, name, "varlink")) {
                if (selected != null) return error.AmbiguousVarlinkListener;
                selected = @intCast(index + 3);
            }
        }
        if (iterator.next() != null) return error.InvalidListenFdNames;
    } else if (count == 1) {
        selected = 3;
    } else return error.AmbiguousVarlinkListener;
    const fd = selected orelse return null;
    try validate(fd);
    return fd;
}

pub fn validate(fd: linux.fd_t) !void {
    var address: linux.sockaddr.un = undefined;
    var length: linux.socklen_t = @sizeOf(@TypeOf(address));
    try check(linux.getsockname(fd, @ptrCast(&address), &length));
    if (address.family != linux.AF.UNIX) return error.ListenerNotUnix;
    var socket_type: c_int = 0;
    length = @sizeOf(c_int);
    try check(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.TYPE, @ptrCast(&socket_type), &length));
    if (socket_type != linux.SOCK.STREAM) return error.ListenerNotStream;
    var listening: c_int = 0;
    length = @sizeOf(c_int);
    try check(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ACCEPTCONN, @ptrCast(&listening), &length));
    if (listening != 1) return error.SocketNotListening;
}

pub fn configure(fd: linux.fd_t) !void {
    try validate(fd);
    const flags = linux.fcntl(fd, linux.F.GETFD, 0);
    try check(flags);
    try check(linux.fcntl(fd, linux.F.SETFD, flags | linux.FD_CLOEXEC));
    const status = linux.fcntl(fd, linux.F.GETFL, 0);
    try check(status);
    const nonblocking: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    try check(linux.fcntl(fd, linux.F.SETFL, status | nonblocking));
}

pub fn socketPath(allocator: std.mem.Allocator, environ: std.process.Environ, application_id: []const u8) ![:0]u8 {
    if (application_id.len == 0 or std.mem.eql(u8, application_id, ".") or std.mem.eql(u8, application_id, "..")) return error.InvalidApplicationId;
    for (application_id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return error.InvalidApplicationId;
    const runtime = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
    if (runtime.len == 0 or runtime[0] != '/') return error.InvalidRuntimeDirectory;
    return std.fmt.allocPrintSentinel(allocator, "{s}/ourokit/apps/{s}", .{ runtime, application_id }, 0);
}

pub fn listenerPath(allocator: std.mem.Allocator, fd: linux.fd_t) ![:0]u8 {
    var address: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
    var length: linux.socklen_t = @sizeOf(@TypeOf(address));
    try check(linux.getsockname(fd, @ptrCast(&address), &length));
    return allocator.dupeZ(u8, std.mem.sliceTo(&address.path, 0));
}

/// Never remove an existing node to bind. A stale socket requires explicit
/// operator cleanup; this avoids both live-listener takeover and probe races.
pub fn makeParentDirectories(allocator: std.mem.Allocator, path: [:0]const u8) !void {
    const apps = std.fs.path.dirname(path) orelse return error.InvalidSocketPath;
    const ourokit = std.fs.path.dirname(apps) orelse return error.InvalidSocketPath;
    for ([_][]const u8{ ourokit, apps }) |directory| {
        const name = try allocator.dupeZ(u8, directory);
        defer allocator.free(name);
        const result = linux.mkdir(name, 0o700);
        if (linux.errno(result) != .EXIST) try check(result);
        var stat: linux.Statx = undefined;
        try check(linux.statx(linux.AT.FDCWD, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stat));
        if (stat.mode & linux.S.IFMT != linux.S.IFDIR or stat.uid != linux.getuid() or stat.mode & 0o022 != 0)
            return error.UnsafeSocketDirectory;
    }
}

pub const PathIdentity = struct {
    inode: u64,
    device_major: u32,
    device_minor: u32,

    pub fn read(path: [:0]const u8) !PathIdentity {
        var stat: linux.Statx = undefined;
        try check(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .INO = true }, &stat));
        return .{ .inode = stat.ino, .device_major = stat.dev_major, .device_minor = stat.dev_minor };
    }

    pub fn unlink(self: PathIdentity, path: [:0]const u8) void {
        const current = read(path) catch return;
        if (std.meta.eql(self, current)) _ = linux.unlink(path);
    }
};

fn check(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.SocketActivationSystemCallFailed;
}

test "systemd listener detection is repeatable and validates descriptor type" {
    const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    try check(socket_result);
    const fd: linux.fd_t = @intCast(socket_result);
    defer _ = linux.close(fd);
    try std.testing.expectError(error.SocketNotListening, validate(fd));
    var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = [_]u8{0} ** 108 };
    // Autobind an abstract address, avoiding filesystem cleanup in detection.
    try check(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sa_family_t)));
    try check(linux.listen(fd, 4));
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    const pid = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{linux.getpid()});
    defer std.testing.allocator.free(pid);
    const count = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{fd - 2});
    defer std.testing.allocator.free(count);
    var names: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer names.deinit();
    for (3..@intCast(fd)) |_| try names.writer.writeAll("other:");
    try names.writer.writeAll("varlink");
    try map.put("LISTEN_PID", pid);
    try map.put("LISTEN_FDS", count);
    try map.put("LISTEN_FDNAMES", names.written());
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(std.testing.allocator, .{}) };
    defer environ.block.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?linux.fd_t, fd), try listener(environ));
    try std.testing.expectEqual(@as(?linux.fd_t, fd), try listener(environ));
    try configure(fd);
    const status: linux.O = @bitCast(@as(u32, @intCast(linux.fcntl(fd, linux.F.GETFL, 0))));
    try std.testing.expect(status.NONBLOCK);
    try std.testing.expect(linux.fcntl(fd, linux.F.GETFD, 0) & linux.FD_CLOEXEC != 0);
    // PID mismatch must ignore even otherwise malformed activation metadata.
    try map.put("LISTEN_PID", "0");
    try map.put("LISTEN_FDS", "invalid");
    const other: std.process.Environ = .{ .block = try map.createPosixBlock(std.testing.allocator, .{}) };
    defer other.block.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?linux.fd_t, null), try listener(other));
    const inet_result = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    try check(inet_result);
    defer _ = linux.close(@intCast(inet_result));
    try std.testing.expectError(error.ListenerNotUnix, validate(@intCast(inet_result)));
}

test "systemd socket path is stable and rejects traversal" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("XDG_RUNTIME_DIR", "/run/user/1234");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(std.testing.allocator, .{}) };
    defer environ.block.deinit(std.testing.allocator);
    const path = try socketPath(std.testing.allocator, environ, "dev.example.App");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1234/ourokit/apps/dev.example.App", path);
    for ([_][]const u8{ "", ".", "..", "../other", "dev/app", "bad\x00id" }) |id|
        try std.testing.expectError(error.InvalidApplicationId, socketPath(std.testing.allocator, environ, id));
}
