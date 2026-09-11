//! Best-effort, process-owned runtime catalog. All filesystem work happens at
//! the service safe point, never during the infallible application commit.
const std = @import("std");
const linux = std.os.linux;
const mcp = @import("../mcp/root.zig");
const catalog = @import("catalog.zig");

pub const Publication = struct {
    allocator: std.mem.Allocator,
    runtime: []u8,
    endpoint: []u8,
    filename: [:0]u8,
    directory: ?linux.fd_t = null,
    identity: ?Identity = null,

    pub fn init(a: std.mem.Allocator, environ: std.process.Environ, id: []const u8, socket: []const u8) !Publication {
        const raw_runtime = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
        if (raw_runtime.len == 0 or raw_runtime[0] != '/') return error.InvalidRuntimeDirectory;
        const trimmed = std.mem.trimEnd(u8, raw_runtime, "/");
        const runtime = if (trimmed.len == 0) "/" else trimmed;
        const prefix_len = if (runtime.len == 1) 0 else runtime.len;
        if (!std.mem.startsWith(u8, socket, runtime) or socket.len <= prefix_len or socket[prefix_len] != '/') return error.SocketOutsideRuntimeDirectory;
        // socketPath appends '/' to XDG_RUNTIME_DIR, so a valid trailing slash
        // produces repeated separators here. Normalize only this boundary;
        // descriptorValue still rejects traversal and empty internal segments.
        const endpoint = std.mem.trimStart(u8, socket[prefix_len..], "/");
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        _ = try catalog.descriptorValue(arena.allocator(), id, endpoint, .null);
        const owned_runtime = try a.dupe(u8, runtime);
        errdefer a.free(owned_runtime);
        const owned_endpoint = try a.dupe(u8, endpoint);
        errdefer a.free(owned_endpoint);
        return .{ .allocator = a, .runtime = owned_runtime, .endpoint = owned_endpoint, .filename = try std.fmt.allocPrintSentinel(a, "{s}.json", .{id}, 0) };
    }

    pub fn deinit(self: *Publication) void {
        if (self.directory) |fd| {
            if (self.identity) |owned| {
                const current = stat(fd, self.filename) catch null;
                if (current) |value| if (std.meta.eql(owned, Identity.from(value))) {
                    _ = linux.unlinkat(fd, self.filename, 0);
                };
            }
            _ = linux.close(fd);
        }
        self.allocator.free(self.filename);
        self.allocator.free(self.endpoint);
        self.allocator.free(self.runtime);
        self.* = undefined;
    }

    pub fn publish(self: *Publication, id: []const u8, tools_json: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const list = try std.json.parseFromSlice(mcp.Value, a, tools_json, .{ .parse_numbers = false });
        var descriptor = try catalog.descriptorValue(a, id, self.endpoint, list.value);
        var proc_buffer: [4096]u8 = undefined;
        const proc = try open(linux.AT.FDCWD, "/proc/self/stat", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        defer _ = linux.close(proc);
        const count = linux.read(proc, &proc_buffer, proc_buffer.len);
        try check(count);
        if (count == proc_buffer.len) return error.ProcessStatTooLarge;
        try descriptor.object.put(a, "runtime", try mcp.object(a, .{
            .{ "pid", mcp.Value{ .integer = linux.getpid() } },
            .{ "start_ticks", mcp.string(try startTicks(proc_buffer[0..count])) },
        }));
        const bytes = try catalog.serialize(a, descriptor);
        if (self.directory == null) self.directory = try openDirectory(a, self.runtime);
        const fd = self.directory.?;
        try safe(try stat(fd, ""), linux.S.IFDIR);
        const existing = stat(fd, self.filename) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |value| {
            try safe(value, linux.S.IFREG);
            if (self.identity) |owned| if (!std.meta.eql(owned, Identity.from(value))) return error.CatalogReplaced;
        } else if (self.identity != null) return error.CatalogReplaced;
        var nonce: [16]u8 = undefined;
        if (linux.getrandom(&nonce, nonce.len, 0) != nonce.len) return error.RandomFailed;
        const temp = try std.fmt.allocPrintSentinel(a, ".{s}.{x}.tmp", .{ id, nonce }, 0);
        const output = try open(fd, temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true });
        defer _ = linux.close(output);
        defer _ = linux.unlinkat(fd, temp, 0);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = linux.write(output, bytes[offset..].ptr, bytes.len - offset);
            if (linux.errno(written) == .INTR) continue;
            try check(written);
            if (written == 0) return error.WriteFailed;
            offset += written;
        }
        const identity = Identity.from(try stat(output, ""));
        try check(linux.renameat(fd, temp, fd, self.filename));
        self.identity = identity;
    }
};

const Identity = struct {
    inode: u64,
    major: u32,
    minor: u32,
    fn from(value: linux.Statx) Identity {
        return .{ .inode = value.ino, .major = value.dev_major, .minor = value.dev_minor };
    }
};

fn startTicks(bytes: []const u8) ![]const u8 {
    // comm can contain spaces and ')'; the last ')' terminates it.
    const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.InvalidProcessStat;
    var fields = std.mem.tokenizeAny(u8, bytes[end + 1 ..], " \n");
    for (0..19) |_| _ = fields.next() orelse return error.InvalidProcessStat;
    const ticks = fields.next() orelse return error.InvalidProcessStat;
    if (ticks.len == 0) return error.InvalidProcessStat;
    for (ticks) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidProcessStat;
    return ticks;
}

fn openDirectory(a: std.mem.Allocator, runtime: []const u8) !linux.fd_t {
    // Walk every component from / with O_NOFOLLOW, anchoring each subsequent
    // lookup to its directory descriptor. Runtime ancestors need not be owned
    // by us (e.g. /run/user), but the runtime root and all created dirs must be.
    var fd = try open(linux.AT.FDCWD, "/", .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    errdefer _ = linux.close(fd);
    if (runtime.len > 1) {
        var segments = std.mem.splitScalar(u8, runtime[1..], '/');
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidRuntimeDirectory;
            const path = try a.dupeZ(u8, segment);
            const next = try open(fd, path, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
            _ = linux.close(fd);
            fd = next;
        }
    }
    try safe(try stat(fd, ""), linux.S.IFDIR);
    for ([_][:0]const u8{ "ouro", "mcp", "apps" }) |name| {
        const result = linux.mkdirat(fd, name, 0o700);
        if (linux.errno(result) != .EXIST) try check(result);
        const next = try open(fd, name, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        _ = linux.close(fd);
        fd = next;
        try safe(try stat(fd, ""), linux.S.IFDIR);
    }
    return fd;
}

fn safe(value: linux.Statx, kind: u16) !void {
    if (value.mode & linux.S.IFMT != kind or value.uid != linux.getuid() or value.mode & 0o022 != 0) return error.UnsafeCatalogPath;
}

fn stat(fd: linux.fd_t, path: [:0]const u8) !linux.Statx {
    var value: linux.Statx = undefined;
    try check(linux.statx(fd, path, linux.AT.SYMLINK_NOFOLLOW | linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .INO = true }, &value));
    return value;
}

fn open(fd: linux.fd_t, path: [:0]const u8, flags: linux.O) !linux.fd_t {
    const result = linux.openat(fd, path, flags, 0o600);
    try check(result);
    return @intCast(result);
}

fn check(result: usize) !void {
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        else => return error.CatalogSystemCallFailed,
    }
}

test "catalog runtime process identity accepts comm parentheses" {
    try std.testing.expectEqualStrings("987654", try startTicks("123 (worker ) busy) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 23"));
    try std.testing.expectError(error.InvalidProcessStat, startTicks("123 (worker) S 1 2"));
}

test "catalog runtime normalizes trailing separators without accepting sibling prefixes" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "/run/user/123/", "/run/user/123///", "/" }) |runtime| {
        var map: std.process.Environ.Map = .init(a);
        defer map.deinit();
        try map.put("XDG_RUNTIME_DIR", runtime);
        const environ: std.process.Environ = .{ .block = try map.createPosixBlock(a, .{}) };
        defer environ.block.deinit(a);
        const socket = try @import("socket_activation.zig").socketPath(a, environ, "dev.test.catalog");
        defer a.free(socket);
        var publication = try Publication.init(a, environ, "dev.test.catalog", socket);
        defer publication.deinit();
        try std.testing.expectEqualStrings("ourokit/apps/dev.test.catalog", publication.endpoint);
        if (runtime.len > 1) {
            try std.testing.expectEqualStrings("/run/user/123", publication.runtime);
            try std.testing.expectError(error.SocketOutsideRuntimeDirectory, Publication.init(a, environ, "dev.test.catalog", "/run/user/1234/other.sock"));
        }
    }
}
