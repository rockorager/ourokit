const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const varlink = @import("../varlink/root.zig");
const control = @import("control_server.zig");
const socket_activation = @import("socket_activation.zig");

pub const Diagnostic = struct {
    phase: []u8,
    source: []u8,
    message: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.source);
        allocator.free(self.phase);
        self.* = undefined;
    }
};

pub const Status = struct {
    application_id: []u8,
    generation: u64,
    reloading: bool,
    diagnostic: ?Diagnostic,

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        if (self.diagnostic) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.application_id);
        self.* = undefined;
    }
};

pub const ReloadResult = union(enum) {
    committed: u64,
    failed: Diagnostic,

    pub fn deinit(self: *ReloadResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .committed => {},
            .failed => |*diagnostic| diagnostic.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const Application = struct {
    path: []u8,
    status: Status,

    pub fn deinit(self: *Application, allocator: std.mem.Allocator) void {
        self.status.deinit(allocator);
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Resolves the application's well-known address. Connecting can activate its
/// systemd service; discovering the owner never scans unrelated sockets.
pub fn findApplication(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    application_id: []const u8,
) !Application {
    _ = io;
    const socket_path = try socket_activation.socketPath(allocator, environ, application_id);
    defer allocator.free(socket_path);
    const path = try allocator.dupe(u8, socket_path);
    errdefer allocator.free(path);
    var status = try statusAt(allocator, path);
    errdefer status.deinit(allocator);
    if (!std.mem.eql(u8, status.application_id, application_id)) return error.ApplicationIdMismatch;
    return .{ .path = path, .status = status };
}

pub fn activateAt(allocator: std.mem.Allocator, path: []const u8, token: ?[]const u8) !void {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(allocator);
    if (token) |value| try parameters.put(allocator, "activationToken", .{ .string = value });
    var reply = try call(allocator, path, control.interface_name ++ ".Activate", .{ .object = parameters });
    defer reply.deinit();
    if (reply.error_name != null) return error.ActivationFailed;
}

pub fn statusAt(allocator: std.mem.Allocator, path: []const u8) !Status {
    var reply = try call(allocator, path, control.status_method, null);
    defer reply.deinit();
    if (reply.error_name != null) return error.StatusFailed;
    const parameters = reply.parameters orelse return error.InvalidStatusReply;
    const object = switch (parameters) {
        .object => |value| value,
        else => return error.InvalidStatusReply,
    };
    const application_id = try dupeStringField(allocator, object, "applicationId");
    errdefer allocator.free(application_id);
    const generation = try unsignedField(object, "activeGeneration");
    const reloading = switch (object.get("reloading") orelse return error.InvalidStatusReply) {
        .bool => |value| value,
        else => return error.InvalidStatusReply,
    };
    const diagnostic = try optionalDiagnostic(allocator, object.get("diagnostic") orelse
        return error.InvalidStatusReply);
    return .{
        .application_id = application_id,
        .generation = generation,
        .reloading = reloading,
        .diagnostic = diagnostic,
    };
}

pub fn reloadAt(allocator: std.mem.Allocator, path: []const u8) !ReloadResult {
    var reply = try call(allocator, path, control.reload_method, null);
    defer reply.deinit();
    const parameters = reply.parameters orelse return error.InvalidReloadReply;
    const object = switch (parameters) {
        .object => |value| value,
        else => return error.InvalidReloadReply,
    };
    if (reply.error_name) |name| {
        if (!std.mem.eql(u8, name, control.interface_name ++ ".ReloadFailed"))
            return error.ReloadFailed;
        return .{ .failed = try diagnosticFromObject(allocator, object) };
    }
    return .{ .committed = try unsignedField(object, "generation") };
}

fn call(
    allocator: std.mem.Allocator,
    path: []const u8,
    method: []const u8,
    parameters: ?std.json.Value,
) !varlink.Reply {
    const fd = try wayring.unix_socket.connect(path);
    defer _ = linux.close(fd);
    var client = try varlink.Client.init(allocator, .{});
    defer client.deinit();
    _ = try client.call(.{ .method = method, .parameters = parameters });
    while (client.takeTransmit()) |transmit_value| {
        var transmit = transmit_value;
        defer transmit.deinit();
        while (!transmit.complete()) {
            const result = linux.write(
                fd,
                transmit.remaining().ptr,
                transmit.remaining().len,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return error.ConnectionClosed;
                    try transmit.consume(result);
                },
                .INTR => continue,
                .AGAIN => try waitFor(fd, linux.POLL.OUT),
                else => return error.SocketWriteFailed,
            }
        }
    }

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const result = linux.read(fd, &buffer, buffer.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.ConnectionClosed;
                var consumed: usize = 0;
                while (consumed < result) {
                    const count = try client.feed(buffer[consumed..result]);
                    consumed += count;
                    if (client.takeEvent()) |event_value| {
                        var event = event_value;
                        return switch (event) {
                            .reply => |*reply| blk: {
                                const message = reply.message;
                                reply.message = undefined;
                                event = undefined;
                                break :blk message;
                            },
                        };
                    }
                    if (count == 0) return error.ClientEventCapacityExceeded;
                }
            },
            .INTR => continue,
            .AGAIN => try waitFor(fd, linux.POLL.IN),
            else => return error.SocketReadFailed,
        }
    }
}

fn waitFor(fd: linux.fd_t, events: i16) !void {
    var poll_descriptors = [_]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    while (true) {
        const result = linux.poll(&poll_descriptors, poll_descriptors.len, -1);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) continue;
                if (poll_descriptors[0].revents &
                    (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
                    return error.ConnectionClosed;
                return;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) !u64 {
    const value = object.get(name) orelse return error.MissingReplyField;
    const integer = switch (value) {
        .integer => |number| number,
        .number_string => |number| return std.fmt.parseUnsigned(u64, number, 10),
        else => return error.InvalidReplyField,
    };
    if (integer < 0) return error.InvalidReplyField;
    return @intCast(integer);
}

fn dupeStringField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) ![]u8 {
    return allocator.dupe(u8, switch (object.get(name) orelse return error.MissingReplyField) {
        .string => |value| value,
        else => return error.InvalidReplyField,
    });
}

fn optionalDiagnostic(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !?Diagnostic {
    return switch (value) {
        .null => null,
        .object => |object| try diagnosticFromObject(allocator, object),
        else => error.InvalidReplyField,
    };
}

fn diagnosticFromObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !Diagnostic {
    const phase = try dupeStringField(allocator, object, "phase");
    errdefer allocator.free(phase);
    const source = try dupeStringField(allocator, object, "source");
    errdefer allocator.free(source);
    return .{
        .phase = phase,
        .source = source,
        .message = try dupeStringField(allocator, object, "message"),
    };
}
