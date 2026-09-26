//! Explicit development and optional production MCP endpoints. Neither is a
//! desktop activation mechanism. No systemd listener is implicitly adopted.
const std = @import("std");
const linux = std.os.linux;

pub fn socketPath(a: std.mem.Allocator, environ: std.process.Environ, id: []const u8, development: bool) ![:0]u8 {
    if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.InvalidApplicationId;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return error.InvalidApplicationId;
    const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
    if (runtime.len == 0 or runtime[0] != '/') return error.InvalidRuntimeDirectory;
    if (development) {
        var nonce: [16]u8 = undefined;
        if (linux.getrandom(&nonce, nonce.len, 0) != nonce.len) return error.RandomFailed;
        return std.fmt.allocPrintSentinel(a, "{s}/ourokit/dev/{x}", .{ std.mem.trimEnd(u8, runtime, "/"), nonce }, 0);
    }
    return std.fmt.allocPrintSentinel(a, "{s}/ourokit/apps/{s}", .{ std.mem.trimEnd(u8, runtime, "/"), id }, 0);
}

/// Never unlink a pre-existing node. Development names are random and private.
pub fn makeParentDirectories(a: std.mem.Allocator, path: [:0]const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidSocketPath;
    const root = std.fs.path.dirname(parent) orelse return error.InvalidSocketPath;
    for ([_][]const u8{ root, parent }) |directory| {
        const name = try a.dupeZ(u8, directory);
        defer a.free(name);
        const result = linux.mkdir(name, 0o700);
        if (linux.errno(result) != .EXIST) try check(result);
        var stat: linux.Statx = undefined;
        try check(linux.statx(linux.AT.FDCWD, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &stat));
        if (stat.mode & linux.S.IFMT != linux.S.IFDIR or stat.uid != linux.getuid() or stat.mode & 0o077 != 0)
            return error.UnsafeSocketDirectory;
    }
}

/// CLI diagnostics accept only an explicit endpoint in this session's dev
/// directory, never an application ID or a production socket.
pub fn validateDevelopmentPath(a: std.mem.Allocator, environ: std.process.Environ, path: []const u8) !void {
    const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
    const prefix = try std.fmt.allocPrint(a, "{s}/ourokit/dev/", .{std.mem.trimEnd(u8, runtime, "/")});
    defer a.free(prefix);
    if (!std.mem.startsWith(u8, path, prefix)) return error.ExpectedDevelopmentEndpoint;
    const name = path[prefix.len..];
    if (name.len != 32) return error.ExpectedDevelopmentEndpoint;
    for (name) |byte| if (!std.ascii.isHex(byte)) return error.ExpectedDevelopmentEndpoint;
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
    if (linux.errno(result) != .SUCCESS) return error.ControlEndpointSystemCallFailed;
}

test "development endpoints are unique and cannot resolve production identities" {
    const a = std.testing.allocator;
    var map: std.process.Environ.Map = .init(a);
    defer map.deinit();
    try map.put("XDG_RUNTIME_DIR", "/tmp");
    const env: std.process.Environ = .{ .block = try map.createPosixBlock(a, .{}) };
    defer env.block.deinit(a);
    const first = try socketPath(a, env, "org.example.App", true);
    defer a.free(first);
    const second = try socketPath(a, env, "org.example.App", true);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try validateDevelopmentPath(a, env, first);
    try std.testing.expectError(error.ExpectedDevelopmentEndpoint, validateDevelopmentPath(a, env, "/tmp/ourokit/apps/org.example.App"));
    try std.testing.expectError(error.ExpectedDevelopmentEndpoint, validateDevelopmentPath(a, env, "org.example.App"));
}
