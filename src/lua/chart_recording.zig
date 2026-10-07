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
    fd: i32,
    /// Host monotonic ms at the start of the log; entries carry t - t0.
    t0: i64,
    lines: u64 = 0,
    failed: bool = false,

    /// Creates (truncates) `path`, creating missing parent directories.
    pub fn open(path: []const u8, application: []const u8) !Sink {
        if (std.fs.path.dirname(path)) |parent| try makePath(parent);
        var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        const result = linux.openat(linux.AT.FDCWD, buffer[0..path.len :0], .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        }, 0o600);
        if (linux.errno(result) != .SUCCESS) return error.RecordingOpenFailed;
        var sink: Sink = .{ .fd = @intCast(result), .t0 = monotonicMs() };
        var header: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&header, "{{\"format\":\"ouro.machine.log\",\"version\":1,\"t0\":{d},\"app\":{f}}}", .{
            sink.t0, std.json.fmt(application, .{}),
        }) catch return error.NameTooLong;
        sink.append(line);
        return sink;
    }

    pub fn close(self: *Sink) void {
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    /// Appends one line. A failed write stops recording rather than the app.
    pub fn append(self: *Sink, line: []const u8) void {
        if (self.failed) return;
        self.writeAll(line) catch {
            self.failed = true;
            return;
        };
        self.writeAll("\n") catch {
            self.failed = true;
            return;
        };
        self.lines += 1;
    }

    fn writeAll(self: *Sink, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const result = linux.write(self.fd, bytes[offset..].ptr, bytes.len - offset);
            switch (linux.errno(result)) {
                .SUCCESS => offset += result,
                .INTR => {},
                else => return error.RecordingWriteFailed,
            }
        }
    }
};

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
    \\local write, t0, ouro = ...
    \\local machine = ouro.machine
    \\if machine and machine.recorder then machine.recorder(write, {t0 = t0, header = false}) end
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
    vm.pushApi(state);
    if (c.lua_pcallk(state, 3, 0, 0, 0, null) != c.ok)
        return error.StatechartRecorderInitializationFailed;
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
    var sink = try Sink.open(path, "dev.test");
    sink.append("{\"k\":\"start\"}");
    try std.testing.expectEqual(@as(u64, 2), sink.lines);
    sink.close();
}
