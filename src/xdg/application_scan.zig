//! On-demand discovery on the caller's io_uring loop. getdents64 has no ring
//! opcode and is the only synchronous filesystem call. No worker, private
//! ring, watcher, or catalog cache.
const std = @import("std");
const linux = std.os.linux;
const applications = @import("applications.zig");
const io = @import("../loop/root.zig");
const fs = @import("../fs/root.zig");

const Directory = struct { path: [:0]const u8, relative: []const u8, depth: usize, rank: usize };
const Candidate = struct { id: []const u8, path: []const u8, rank: usize };
const State = enum { idle, dir_open, dir_stat, dir_close, reading, complete };

/// Keep this object and its borrowed Config at stable addresses until take().
/// The host submits/waits on the shared loop, routes file completions here,
/// and calls collectCanceled at safe points and after cancellation CQEs.
pub const Scan = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    config: *const applications.Config,
    reader: fs.Reader,
    state: State = .idle,
    operation: ?io.OperationHandle = null,
    canceled_operation: ?io.OperationHandle = null,
    fd: linux.fd_t = -1,
    stat: linux.Statx = undefined,
    arena: ?std.heap.ArenaAllocator = null,
    dirs: std.ArrayList(Directory) = .empty,
    current_dir: Directory = undefined,
    candidates: std.ArrayList(Candidate) = .empty,
    candidate_index: usize = 0,
    traversal_count: usize = 0,
    total_bytes: usize = 0,
    read_handle: ?fs.ReadHandle = null,
    output: std.ArrayList(applications.Entry) = .empty,
    claimed: std.StringHashMapUnmanaged(void) = .empty,
    seen: std.AutoHashMapUnmanaged([4]u64, void) = .empty,
    failure: ?anyerror = null,
    canceled: bool = false,

    pub fn init(self: *Scan, allocator: std.mem.Allocator, loop: *io.Loop, config: *const applications.Config) !void {
        var reader: fs.Reader = undefined;
        try reader.init(allocator, loop, 1);
        self.* = .{ .allocator = allocator, .loop = loop, .config = config, .reader = reader };
    }

    pub fn deinit(self: *Scan) void {
        std.debug.assert(self.state == .idle and self.fd == -1);
        self.reader.deinit();
        self.* = undefined;
    }

    fn a(self: *Scan) std.mem.Allocator {
        return self.arena.?.allocator();
    }

    pub fn start(self: *Scan) !void {
        if (self.state != .idle) return error.ScanInProgress;
        for (self.config.roots) |root| if (!std.fs.path.isAbsolute(root) or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidSearchRoot;
        self.arena = .init(self.allocator);
        errdefer self.reset();
        var index = self.config.roots.len;
        while (index != 0) {
            index -= 1;
            try self.dirs.append(self.a(), .{
                .path = try std.fs.path.joinZ(self.a(), &.{ self.config.roots[index], "applications" }),
                .relative = "",
                .depth = 0,
                .rank = index,
            });
        }
        try self.nextDirectory();
    }

    pub fn dispatch(self: *Scan, completion: io.FileCompletion) !bool {
        if (self.state == .reading) {
            if (!try self.reader.dispatch(completion)) return false;
            if (try self.reader.finished(self.read_handle.?)) self.finishRead() catch |err| try self.fail(err);
            return true;
        }
        const operation = self.operation orelse return false;
        if (!same(operation, completion.operation)) return false;
        self.operation = null;
        self.transition(completion) catch |err| try self.fail(err);
        return true;
    }

    fn transition(self: *Scan, completion: io.FileCompletion) !void {
        const result = completion.result;
        switch (self.state) {
            .dir_open => {
                std.debug.assert(completion.kind == .openat2);
                if (result < 0) {
                    if (self.canceled) return self.stop();
                    if (!missing(result)) return self.fail(resultError(result));
                    return self.nextDirectory();
                }
                self.fd = result;
                if (self.canceled) return self.stop();
                self.state = .dir_stat;
                self.operation = try self.loop.prepareStatx(self.fd, &self.stat);
            },
            .dir_stat => {
                std.debug.assert(completion.kind == .statx);
                if (result < 0) return self.fail(resultError(result));
                if (!self.canceled) {
                    const key = [4]u64{ self.current_dir.rank, self.stat.dev_major, self.stat.dev_minor, self.stat.ino };
                    if (!self.seen.contains(key)) {
                        try self.seen.put(self.a(), key, {});
                        try self.enumerate();
                    }
                }
                self.state = .dir_close;
                self.operation = try self.loop.prepareClose(self.fd);
            },
            .dir_close => {
                std.debug.assert(completion.kind == .close);
                self.fd = -1;
                if (result < 0 and !self.canceled) return self.fail(resultError(result));
                if (self.canceled or self.failure != null) return self.stop();
                try self.nextDirectory();
            },
            else => return error.UnexpectedFileCompletion,
        }
    }

    pub fn collectCanceled(self: *Scan) !void {
        if (self.canceled_operation) |operation| {
            if (!self.loop.operationPending(operation)) self.canceled_operation = null;
        }
    }

    pub fn finished(self: *const Scan) bool {
        return self.state == .complete and self.canceled_operation == null;
    }

    pub fn take(self: *Scan) !?applications.Catalog {
        if (!self.finished()) return null;
        if (self.failure != null or self.canceled) {
            const err = if (self.canceled) error.Canceled else self.failure.?;
            self.reset();
            return err;
        }
        std.mem.sort(applications.Entry, self.output.items, {}, entryLess);
        const entries = self.output.items;
        const arena = self.arena.?;
        self.arena = null;
        self.reset();
        return .{ .arena = arena, .entries = entries };
    }

    pub fn cancel(self: *Scan) !void {
        if (self.state == .idle or self.canceled) return;
        self.canceled = true;
        if (self.state == .reading) {
            try self.reader.cancel(self.read_handle.?);
        } else if (self.operation) |operation| {
            // Never cancel close: its completion retires the owned descriptor.
            if (self.state == .dir_close) return;
            try self.loop.prepareCancel(operation);
            self.canceled_operation = operation;
        }
    }

    fn nextDirectory(self: *Scan) !void {
        if (self.canceled) return self.stop();
        if (self.dirs.pop()) |dir| {
            self.current_dir = dir;
            self.operation = try self.loop.prepareOpenAt2(linux.AT.FDCWD, dir.path, .{
                .flags = @as(u32, @bitCast(linux.O{ .DIRECTORY = true, .NONBLOCK = true, .CLOEXEC = true })),
                .resolve = io.Resolve.no_magic_links,
            });
            self.state = .dir_open;
        } else {
            std.mem.sort(Candidate, self.candidates.items, {}, candidateLess);
            try self.nextRead();
        }
    }

    fn enumerate(self: *Scan) !void {
        var children: std.ArrayList(Directory) = .empty;
        var buffer: [4096]u8 align(@alignOf(usize)) = undefined;
        while (true) {
            const rc = linux.getdents64(self.fd, &buffer, buffer.len);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS) return error.DirectoryEnumerationFailed;
            if (rc == 0) break;
            var offset: usize = 0;
            while (offset < rc) {
                if (rc - offset < 20) return error.InvalidDirectoryEntry;
                const reclen = std.mem.readInt(u16, buffer[offset + 16 ..][0..2], @import("builtin").cpu.arch.endian());
                if (reclen < 20 or offset + reclen > rc) return error.InvalidDirectoryEntry;
                const kind = buffer[offset + 18];
                const raw = buffer[offset + 19 .. offset + reclen];
                const name = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse return error.InvalidDirectoryEntry];
                offset += reclen;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (self.traversal_count == applications.max_files) return error.CatalogCapacityExceeded;
                self.traversal_count += 1;
                const dir = self.current_dir;
                const rel = if (dir.relative.len == 0) try self.a().dupe(u8, name) else try std.fs.path.join(self.a(), &.{ dir.relative, name });
                const path = try std.fs.path.joinZ(self.a(), &.{ dir.path, name });
                if (kind != linux.DT.DIR and std.mem.endsWith(u8, name, ".desktop")) {
                    const id = try self.a().dupe(u8, rel);
                    for (id) |*byte| if (byte.* == '/') {
                        byte.* = '-';
                    };
                    try self.candidates.append(self.a(), .{ .id = id, .path = path, .rank = dir.rank });
                }
                if (kind == linux.DT.DIR or kind == linux.DT.LNK or kind == linux.DT.UNKNOWN) {
                    if (dir.depth == applications.max_depth) return error.CatalogCapacityExceeded;
                    try children.append(self.a(), .{ .path = path, .relative = rel, .depth = dir.depth + 1, .rank = dir.rank });
                }
            }
        }
        // DFS in pathname order makes aliases/colliding IDs deterministic.
        std.mem.sort(Directory, children.items, {}, struct {
            fn less(_: void, left: Directory, right: Directory) bool {
                return std.mem.lessThan(u8, right.path, left.path);
            }
        }.less);
        try self.dirs.appendSlice(self.a(), children.items);
    }

    fn nextRead(self: *Scan) !void {
        if (self.canceled) return self.stop();
        while (self.candidate_index < self.candidates.items.len) {
            const candidate = self.candidates.items[self.candidate_index];
            self.candidate_index += 1;
            if (self.claimed.contains(candidate.id)) continue;
            try self.claimed.put(self.a(), candidate.id, {});
            self.read_handle = try self.reader.startAt(linux.AT.FDCWD, candidate.path, .{ .max_bytes = applications.max_file_bytes, .resolve = io.Resolve.no_magic_links });
            self.state = .reading;
            return;
        }
        self.state = .complete;
    }

    fn finishRead(self: *Scan) !void {
        const handle = self.read_handle.?;
        self.read_handle = null;
        var contents = self.reader.take(handle) catch |err| switch (err) {
            error.NotRegularFile, error.FileNotFound, error.NotDir, error.SymLinkLoop => return self.nextRead(),
            error.FileTooLarge => return self.fail(error.CatalogCapacityExceeded),
            else => return self.fail(err),
        } orelse unreachable;
        defer contents.deinit();
        if (self.canceled) return self.stop();
        if (self.total_bytes +| contents.len > applications.max_total_bytes) return self.fail(error.CatalogCapacityExceeded);
        self.total_bytes += contents.len;
        const candidate = self.candidates.items[self.candidate_index - 1];
        const entry = applications.parse(self.a(), contents.bytes(), candidate.id, candidate.path, self.config) catch |err| switch (err) {
            error.MalformedDesktopEntry => null,
            else => return err,
        };
        if (entry) |value| try self.output.append(self.a(), value);
        try self.nextRead();
    }

    fn fail(self: *Scan, err: anyerror) !void {
        self.failure = err;
        try self.stop();
    }

    fn stop(self: *Scan) !void {
        if (self.fd >= 0) {
            self.state = .dir_close;
            self.operation = try self.loop.prepareClose(self.fd);
        } else self.state = .complete;
    }

    fn reset(self: *Scan) void {
        std.debug.assert(self.fd == -1 and self.operation == null);
        if (self.arena) |*arena| arena.deinit();
        const reader = self.reader;
        self.* = .{ .allocator = self.allocator, .loop = self.loop, .config = self.config, .reader = reader };
    }
};

fn same(left: io.OperationHandle, right: io.OperationHandle) bool {
    return left.slot == right.slot and left.generation == right.generation;
}
fn missing(result: i32) bool {
    return result == -@as(i32, @intFromEnum(linux.E.NOENT)) or result == -@as(i32, @intFromEnum(linux.E.NOTDIR)) or result == -@as(i32, @intFromEnum(linux.E.LOOP));
}
fn resultError(result: i32) anyerror {
    return if (result == -@as(i32, @intFromEnum(linux.E.ACCES))) error.AccessDenied else error.ApplicationIoFailed;
}
fn candidateLess(_: void, left: Candidate, right: Candidate) bool {
    if (left.rank != right.rank) return left.rank < right.rank;
    const order = std.mem.order(u8, left.id, right.id);
    return order == .lt or (order == .eq and std.mem.lessThan(u8, left.path, right.path));
}
fn entryLess(_: void, left: applications.Entry, right: applications.Entry) bool {
    return std.mem.lessThan(u8, left.id, right.id);
}

fn testStep(scan: *Scan) !void {
    _ = try scan.loop.submit();
    switch (scan.loop.dispatch(try scan.loop.wait())) {
        .file => |completion| try std.testing.expect(try scan.dispatch(completion)),
        .operation_cancel => {},
        else => return error.UnexpectedCompletion,
    }
    try scan.collectCanceled();
}

test "XDG applications cancellation closes descriptors at every scan and reader stage" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "applications");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "applications/test.desktop", .data = "[Desktop Entry]\nType=Application\nName=Test\nExec=true\nTryExec=/usr/bin/true\n" });
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const config: applications.Config = .{ .roots = &.{root} };
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 16);
    defer loop.deinit();
    var scan: Scan = undefined;
    try scan.init(std.testing.allocator, &loop, &config);
    defer scan.deinit();
    const stages = [_][]const u8{ "dir_open", "dir_stat", "dir_close", "opening", "stat_before", "reading", "stat_after", "closing", "complete" };
    for (stages) |stage| for ([_]bool{ false, true }) |submitted| {
        try scan.start();
        while (true) {
            const current = if (scan.state == .reading) @tagName(scan.reader.slots[0].state) else @tagName(scan.state);
            if (std.mem.eql(u8, stage, current)) break;
            try std.testing.expect(!scan.finished());
            try testStep(&scan);
        }
        const fd = if (scan.state == .reading) scan.reader.slots[0].fd else scan.fd;
        if (submitted) _ = try loop.submit();
        try scan.cancel();
        while (loop.hasPendingOperations()) try testStep(&scan);
        try std.testing.expect(scan.finished());
        if (fd >= 0) try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
        try std.testing.expectError(error.Canceled, scan.take());
    };
    // Reusing the same scanner after cancellation must produce real content.
    try scan.start();
    while (!scan.finished()) try testStep(&scan);
    var catalog = (try scan.take()).?;
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try std.testing.expectEqualStrings("test.desktop", catalog.entries[0].id);
    try std.testing.expect(catalog.entries[0].visible);
}

test "XDG applications scan allocation failures drain owned I/O" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "applications");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "applications/test.desktop", .data = "[Desktop Entry]\nType=Application\nName=Test\nExec=true\nTryExec=/usr/bin/true\n" });
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const config: applications.Config = .{ .roots = &.{root} };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator, cfg: *const applications.Config) !void {
            var loop: io.Loop = undefined;
            try loop.init(std.testing.allocator, 16, 16);
            defer loop.deinit();
            var scan: Scan = undefined;
            try scan.init(allocator, &loop, cfg);
            defer scan.deinit();
            try scan.start();
            while (!scan.finished()) try testStep(&scan);
            var catalog = (try scan.take()).?;
            defer catalog.deinit();
            try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
        }
    }.run, .{&config});
}
