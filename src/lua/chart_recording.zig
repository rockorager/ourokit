//! Statechart input recording (design/statecharts.md §14). The host opens
//! one log file per process and installs a recorder bridge in every source
//! generation: `ouro.machine.recorder` writes one JSON line per external
//! input to the root actors, and this sink appends it. The header is written
//! once, so generations (source reloads) continue the same log.
const std = @import("std");
const c = @import("c.zig");
const vm_module = @import("vm.zig");
const linux = std.os.linux;

pub const Sink = struct {
    allocator: std.mem.Allocator,
    /// Null until the path is known: a development recording is named after
    /// the application id, which the host learns once the entry has loaded.
    fd: ?i32 = null,
    /// Host monotonic ms at the start of the log; entries carry t - t0.
    t0: i64,
    lines: u64 = 0,
    failed: bool = false,
    reason_buffer: [256]u8 = undefined,
    reason_length: usize = 0,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_length: usize = 0,
    /// Lines recorded before the path was assigned.
    pending: std.ArrayList(u8) = .empty,
    const max_pending = 16 * 1024 * 1024;

    pub fn location(self: *const Sink) []const u8 {
        return self.path_buffer[0..self.path_length];
    }

    pub fn reason(self: *const Sink) ?[]const u8 {
        return if (self.reason_length == 0) null else self.reason_buffer[0..self.reason_length];
    }

    /// A sink that buffers until `assign` names its file.
    pub fn deferred(allocator: std.mem.Allocator) Sink {
        return .{ .allocator = allocator, .t0 = monotonicMs() };
    }

    /// Creates (truncates) `path` now.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, application: []const u8) !Sink {
        var sink = deferred(allocator);
        try sink.assign(path, application);
        return sink;
    }

    /// Opens `path` for this process alone: an exclusive lock, then
    /// truncation. When another running instance holds `path` (the same app
    /// id twice), records to `<path without .jsonl>.<pid>.jsonl` instead, so
    /// concurrent runs never share a file. location() reports the choice.
    /// Creates missing parent directories, then writes the header and any
    /// buffered lines.
    pub fn assign(self: *Sink, path: []const u8, application: []const u8) !void {
        std.debug.assert(self.fd == null);
        if (std.fs.path.dirname(path)) |parent| try makePath(parent);
        var chosen = path;
        var alternative: [std.fs.max_path_bytes]u8 = undefined;
        const fd = (try openLocked(path)) orelse fd: {
            const stem = if (std.mem.endsWith(u8, path, ".jsonl")) path[0 .. path.len - ".jsonl".len] else path;
            chosen = std.fmt.bufPrint(&alternative, "{s}.{d}.jsonl", .{ stem, linux.getpid() }) catch return error.NameTooLong;
            break :fd (try openLocked(chosen)) orelse return error.RecordingLocked;
        };
        self.fd = fd;
        @memcpy(self.path_buffer[0..chosen.len], chosen);
        self.path_length = chosen.len;
        var header: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&header, "{{\"format\":\"ouro.machine.log\",\"version\":2,\"t0\":{d},\"app\":{f}}}", .{
            self.t0, std.json.fmt(application, .{}),
        }) catch return error.NameTooLong;
        self.append(line);
        if (!self.failed) self.writeAll(self.pending.items) catch self.fail("cannot write the recording file");
        self.pending.clearAndFree(self.allocator);
    }

    pub fn close(self: *Sink) void {
        if (self.fd) |fd| _ = linux.close(fd);
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    /// Stops recording; the app keeps running. The first reason is kept.
    pub fn fail(self: *Sink, text: []const u8) void {
        if (self.failed) return;
        self.failed = true;
        const length = @min(text.len, self.reason_buffer.len);
        @memcpy(self.reason_buffer[0..length], text[0..length]);
        self.reason_length = length;
    }

    /// Appends one line, with its newline in the same write. A failed write
    /// stops recording rather than the app.
    pub fn append(self: *Sink, line: []const u8) void {
        if (self.failed) return;
        if (self.fd == null) {
            if (self.pending.items.len + line.len + 1 > max_pending) return self.fail("too many inputs before the recording file was named");
            self.pending.appendSlice(self.allocator, line) catch return self.fail("out of memory");
            self.pending.append(self.allocator, '\n') catch return self.fail("out of memory");
            self.lines += 1;
            return;
        }
        const whole = self.allocator.alloc(u8, line.len + 1) catch return self.fail("out of memory");
        defer self.allocator.free(whole);
        @memcpy(whole[0..line.len], line);
        whole[line.len] = '\n';
        self.writeAll(whole) catch return self.fail("cannot write the recording file");
        self.lines += 1;
    }

    fn writeAll(self: *Sink, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = linux.write(self.fd.?, bytes[offset..].ptr, bytes.len - offset);
            switch (linux.errno(result)) {
                .SUCCESS => offset += result,
                .INTR => {},
                else => return error.RecordingWriteFailed,
            }
        }
    }
};

/// An append-only descriptor on `path` holding its exclusive lock, truncated;
/// null when another process holds the lock.
fn openLocked(path: []const u8) !?i32 {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const result = linux.openat(linux.AT.FDCWD, buffer[0..path.len :0], .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o600);
    if (linux.errno(result) != .SUCCESS) return error.RecordingOpenFailed;
    const fd: i32 = @intCast(result);
    const lock_exclusive = 2;
    const lock_nonblocking = 4;
    switch (linux.errno(linux.flock(fd, lock_exclusive | lock_nonblocking))) {
        .SUCCESS => {},
        .AGAIN => {
            _ = linux.close(fd);
            return null;
        },
        else => {
            _ = linux.close(fd);
            return error.RecordingOpenFailed;
        },
    }
    if (linux.errno(linux.ftruncate(fd, 0)) != .SUCCESS) {
        _ = linux.close(fd);
        return error.RecordingOpenFailed;
    }
    return fd;
}

fn makePath(path: []const u8) !void {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buffer.len) return error.NameTooLong;
    var index: usize = 1;
    while (index <= path.len) : (index += 1) {
        if (index != path.len and path[index] != '/') continue;
        @memcpy(buffer[0..index], path[0..index]);
        buffer[index] = 0;
        const result = linux.mkdirat(linux.AT.FDCWD, buffer[0..index :0], 0o700);
        switch (linux.errno(result)) {
            .SUCCESS, .EXIST => {},
            else => return error.RecordingOpenFailed,
        }
    }
}

fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

const bridge_source =
    \\local write, t0, fail, ouro = ...
    \\local machine = ouro.machine
    \\if machine and machine.recorder then machine.recorder(write, {t0 = t0, header = false, fail = fail}) end
;

/// Installs the recorder in a VM whose `ouro.machine` is installed, before
/// application code (and before carried actors are adopted).
pub fn install(vm: *vm_module.Vm, sink: *Sink) !void {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.luaL_loadbufferx(state, bridge_source.ptr, bridge_source.len, "=ouro.machine.recording", "t") != c.ok)
        return error.StatechartRecorderInitializationFailed;
    c.lua_pushlightuserdata(state, sink);
    c.lua_pushcclosure(state, write, 1);
    c.lua_pushinteger(state, sink.t0);
    c.lua_pushlightuserdata(state, sink);
    c.lua_pushcclosure(state, failRecording, 1);
    vm.pushApi(state);
    if (c.lua_pcallk(state, 4, 0, 0, 0, null) != c.ok)
        return error.StatechartRecorderInitializationFailed;
}

fn failRecording(state: *c.State) callconv(.c) c_int {
    const sink: *Sink = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)) orelse return 0));
    var length: usize = 0;
    const text = c.lua_tolstring(state, 1, &length) orelse "recording failed";
    sink.fail(text[0..length]);
    return 0;
}

fn write(state: *c.State) callconv(.c) c_int {
    const sink: *Sink = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)) orelse return 0));
    if (c.lua_type(state, 1) != c.type_string) return 0;
    var length: usize = 0;
    const bytes = c.lua_tolstring(state, 1, &length) orelse return 0;
    sink.append(bytes[0..length]);
    return 0;
}

test "recording sink writes a header and one line per append" {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/ourokit-recording-test-{d}/nested/log.jsonl", .{linux.getpid()});
    var sink = try Sink.open(std.testing.allocator, path, "dev.test");
    sink.append("{\"k\":\"start\"}");
    try std.testing.expectEqual(@as(u64, 2), sink.lines);
    try std.testing.expectEqualStrings(path, sink.location());
    sink.fail("first");
    sink.fail("second");
    sink.append("{}");
    try std.testing.expectEqualStrings("first", sink.reason().?);
    try std.testing.expectEqual(@as(u64, 2), sink.lines);
    sink.close();
    // Deferred: lines wait for the name.
    var later = Sink.deferred(std.testing.allocator);
    later.append("{\"k\":\"start\"}");
    const named = try std.fmt.bufPrint(&path_buffer, "/tmp/ourokit-recording-test-{d}/later.jsonl", .{linux.getpid()});
    try later.assign(named, "dev.test");
    try std.testing.expectEqual(@as(u64, 2), later.lines);
    later.close();
    // A second sink on a held path records beside it, under its pid.
    var first = try Sink.open(std.testing.allocator, named, "dev.test");
    defer first.close();
    // flock locks belong to the open file description: a second open in the
    // same process conflicts like another process would.
    var second = try Sink.open(std.testing.allocator, named, "dev.test");
    defer second.close();
    try std.testing.expect(!std.mem.eql(u8, first.location(), second.location()));
    try std.testing.expect(std.mem.endsWith(u8, second.location(), ".jsonl"));
}
