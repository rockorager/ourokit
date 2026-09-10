const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/io_uring.zig");
const varlink = @import("../varlink/client.zig");
const message = @import("../varlink/message.zig");

const receive_capacity = 16 * 1024;
const retry_min_ns = 250 * std.time.ns_per_ms;
const retry_max_ns = 10 * std.time.ns_per_s;

pub const ColorScheme = enum { default, light, dark };

pub const Snapshot = struct {
    color_scheme: ColorScheme = .default,
};

pub const Event = union(enum) {
    appearance_changed: Snapshot,
};

/// A transport-independent, single-event mailbox. Several writes before the
/// host's next turn are represented by the newest snapshot only.
pub const Store = struct {
    current: Snapshot = .{},
    pending: bool = false,

    pub fn update(self: *Store, snapshot: Snapshot) void {
        if (std.meta.eql(self.current, snapshot)) return;
        self.current = snapshot;
        self.pending = true;
    }

    pub fn takeEvent(self: *Store) ?Event {
        if (!self.pending) return null;
        self.pending = false;
        return .{ .appearance_changed = self.current };
    }
};

const State = enum { disabled, waiting, connecting, sending, receiving, stopping, stopped };

/// Host-owned WatchPath subscription. The host routes socket CQEs, expired
/// logical timers, and operation-cancel CQEs to this object.
pub const Client = struct {
    allocator: std.mem.Allocator = undefined,
    loop: *io.Loop = undefined,
    store: *Store = undefined,
    socket_path: ?[]u8 = null,
    state: State = .disabled,
    fd: linux.fd_t = -1,
    operation: ?io.OperationHandle = null,
    operation_terminal: bool = false,
    cancellation_requested: bool = false,
    timer: ?io.OperationHandle = null,
    retry_ns: u64 = retry_min_ns,
    protocol: varlink.Client = undefined,
    protocol_initialized: bool = false,
    transmit: ?message.Transmit = null,
    received: usize = 0,
    consumed: usize = 0,
    receive_buffer: [receive_capacity]u8 = undefined,

    pub fn init(self: *Client, allocator: std.mem.Allocator, loop: *io.Loop, store: *Store, socket_path: ?[]const u8) !void {
        self.* = .{ .allocator = allocator, .loop = loop, .store = store };
        const path = socket_path orelse return;
        if (path.len == 0) return;
        self.socket_path = try allocator.dupe(u8, path);
        errdefer {
            self.releaseConnection();
            allocator.free(self.socket_path.?);
            self.socket_path = null;
        }
        self.startConnection() catch try self.scheduleRetry();
    }

    pub fn dispatch(self: *Client, completion: io.SocketCompletion) !bool {
        const operation = self.operation orelse return false;
        if (!same(operation, completion.operation)) return false;
        self.operation_terminal = true;
        if (self.cancellation_requested) {
            try self.collectCanceled();
            return true;
        }
        self.operation = null;
        self.operation_terminal = false;
        if (completion.result < 0 or
            (completion.result == 0 and self.state != .connecting))
        {
            try self.connectionLost();
            return true;
        }
        switch (self.state) {
            .connecting => if (completion.kind != .connect) return error.UnexpectedSocketCompletion,
            .sending => if (completion.kind != .send) return error.UnexpectedSocketCompletion,
            .receiving => if (completion.kind != .recv) return error.UnexpectedSocketCompletion,
            else => return error.UnexpectedSocketCompletion,
        }
        switch (self.state) {
            .connecting => {
                self.state = .sending;
                try self.prepareNext();
            },
            .sending => {
                var transmit = &(self.transmit orelse return error.MissingTransmit);
                transmit.consume(@intCast(completion.result)) catch {
                    try self.connectionLost();
                    return true;
                };
                if (transmit.complete()) {
                    transmit.deinit();
                    self.transmit = null;
                    self.state = .receiving;
                }
                try self.prepareNext();
            },
            .receiving => {
                self.received = @intCast(completion.result);
                self.consumed = 0;
                self.consumeReceived() catch {
                    try self.connectionLost();
                    return true;
                };
                if (self.state == .receiving) try self.prepareNext();
            },
            else => unreachable,
        }
        return true;
    }

    pub fn dispatchTimer(self: *Client, operation: io.OperationHandle) !bool {
        const timer = self.timer orelse return false;
        if (!same(timer, operation)) return false;
        self.timer = null;
        if (self.state == .stopping) {
            self.finishStop();
        } else self.startConnection() catch try self.scheduleRetry();
        return true;
    }

    pub fn collectCanceled(self: *Client) !void {
        if (!self.cancellation_requested) return;
        const operation = self.operation orelse return;
        if (!self.operation_terminal or self.loop.operationPending(operation)) return;
        self.operation = null;
        self.operation_terminal = false;
        self.cancellation_requested = false;
        self.finishStop();
    }

    pub fn stop(self: *Client) !void {
        if (self.state == .disabled or self.state == .stopped) {
            self.state = .stopped;
            return;
        }
        if (self.state == .stopping) return;
        self.state = .stopping;
        if (self.timer) |timer| {
            self.loop.prepareCancel(timer) catch |err| if (err != error.StaleOperation) return err;
            self.timer = null;
        }
        if (self.operation) |operation| {
            self.cancellation_requested = true;
            self.loop.prepareCancel(operation) catch |err| if (err != error.StaleOperation) return err;
            return;
        }
        self.finishStop();
    }

    /// Valid only after stop has reached `stopped` (or for a disabled client).
    pub fn deinit(self: *Client) void {
        std.debug.assert(self.state == .disabled or self.state == .stopped);
        std.debug.assert(self.operation == null and self.timer == null);
        self.releaseConnection();
        if (self.socket_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    fn startConnection(self: *Client) !void {
        const path = self.socket_path orelse return;
        self.releaseConnection();
        try self.initProtocol();
        const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
        if (linux.errno(socket_result) != .SUCCESS) return error.SocketUnavailable;
        self.fd = @intCast(socket_result);
        var address: linux.sockaddr.un = .{ .path = undefined };
        @memset(&address.path, 0);
        if (path.len + 1 > address.path.len) return error.NameTooLong;
        @memcpy(address.path[0..path.len], path);
        const length: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
        self.state = .connecting;
        self.operation = try self.loop.prepareUnixConnect(self.fd, &address, length);
    }

    fn initProtocol(self: *Client) !void {
        self.protocol = try varlink.Client.init(self.allocator, .{
            .max_message_bytes = receive_capacity,
            .max_outbound_message_bytes = receive_capacity,
            .max_pending_calls = 1,
            .max_events = 1,
            .max_transmits = 1,
        });
        self.protocol_initialized = true;
        var parameters = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
        defer parameters.deinit(self.allocator);
        try parameters.put(self.allocator, "path", .{ .string = "/appearance/color_scheme" });
        _ = try self.protocol.call(.{
            .method = "dev.rockorager.ouro.Settings.WatchPath",
            .parameters = .{ .object = parameters },
            .more = true,
        });
        self.transmit = self.protocol.takeTransmit().?;
    }

    fn prepareNext(self: *Client) !void {
        self.operation = switch (self.state) {
            .sending => self.loop.prepareSend(self.fd, self.transmit.?.remaining()),
            .receiving => self.loop.prepareRecv(self.fd, &self.receive_buffer),
            else => return error.InvalidState,
        } catch {
            try self.connectionLost();
            return;
        };
    }

    fn consumeReceived(self: *Client) !void {
        while (self.consumed < self.received) {
            const used = try self.protocol.feed(self.receive_buffer[self.consumed..self.received]);
            if (used == 0) return error.ProtocolBackpressure;
            self.consumed += used;
            while (self.protocol.takeEvent()) |event_value| {
                var event = event_value;
                defer event.deinit();
                const reply = event.reply.message;
                if (!reply.continues or reply.error_name != null) return error.SubscriptionEnded;
                const parameters = reply.parameters orelse return error.InvalidWatchReply;
                const object = switch (parameters) {
                    .object => |value| value,
                    else => return error.InvalidWatchReply,
                };
                _ = switch (object.get("revision") orelse return error.InvalidWatchReply) {
                    .string => |value| value,
                    else => return error.InvalidWatchReply,
                };
                const exists = switch (object.get("exists") orelse return error.InvalidWatchReply) {
                    .bool => |value| value,
                    else => return error.InvalidWatchReply,
                };
                const encoded = switch (object.get("value_json") orelse return error.InvalidWatchReply) {
                    .string => |value| value,
                    else => return error.InvalidWatchReply,
                };
                const scheme = if (exists)
                    parseScheme(self.allocator, encoded) orelse return error.InvalidColorScheme
                else
                    .default;
                self.store.update(.{ .color_scheme = scheme });
                self.retry_ns = retry_min_ns;
            }
        }
    }

    fn connectionLost(self: *Client) !void {
        self.operation = null;
        self.releaseConnection();
        try self.scheduleRetry();
    }

    fn scheduleRetry(self: *Client) !void {
        self.releaseConnection();
        self.state = .waiting;
        self.timer = try self.loop.prepareTimeout(self.retry_ns);
        self.retry_ns = @min(retry_max_ns, self.retry_ns * 2);
    }

    fn releaseConnection(self: *Client) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
        if (self.transmit) |*transmit| transmit.deinit();
        self.transmit = null;
        if (self.protocol_initialized) self.protocol.deinit();
        self.protocol_initialized = false;
        self.received = 0;
        self.consumed = 0;
    }

    fn finishStop(self: *Client) void {
        self.releaseConnection();
        self.state = .stopped;
    }
};

fn parseScheme(allocator: std.mem.Allocator, encoded: []const u8) ?ColorScheme {
    const parsed = std.json.parseFromSlice(ColorScheme, allocator, encoded, .{}) catch return null;
    defer parsed.deinit();
    return parsed.value;
}

fn same(a: io.OperationHandle, b: io.OperationHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "Store suppresses equality and coalesces changes" {
    var store: Store = .{};
    store.update(.{});
    try std.testing.expect(store.takeEvent() == null);
    store.update(.{ .color_scheme = .light });
    store.update(.{ .color_scheme = .dark });
    const event = store.takeEvent().?;
    try std.testing.expectEqual(ColorScheme.dark, event.appearance_changed.color_scheme);
    try std.testing.expect(store.takeEvent() == null);
}

test "color scheme JSON is strict" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(ColorScheme.default, parseScheme(allocator, "\"default\"").?);
    try std.testing.expectEqual(ColorScheme.light, parseScheme(allocator, "\"light\"").?);
    try std.testing.expectEqual(ColorScheme.dark, parseScheme(allocator, " \"d\\u0061rk\" ").?);
    try std.testing.expect(parseScheme(allocator, "dark") == null);
    try std.testing.expect(parseScheme(allocator, "\"unknown\"") == null);
}

test "WatchPath replies parse across fragments and coalesce records" {
    var store: Store = .{};
    var client: Client = .{ .allocator = std.testing.allocator, .store = &store };
    try client.initProtocol();
    defer client.releaseConnection();
    client.transmit.?.deinit();
    client.transmit = null;
    const input =
        "{\"parameters\":{\"revision\":\"1\",\"exists\":true,\"value_json\":\"\\\"light\\\"\"},\"continues\":true}\x00" ++
        "{\"parameters\":{\"revision\":\"2\",\"exists\":true,\"value_json\":\"\\\"dark\\\"\"},\"continues\":true}\x00";
    const split = input.len / 3;
    @memcpy(client.receive_buffer[0..split], input[0..split]);
    client.received = split;
    try client.consumeReceived();
    try std.testing.expect(store.takeEvent() == null);
    @memcpy(client.receive_buffer[0 .. input.len - split], input[split..]);
    client.received = input.len - split;
    client.consumed = 0;
    try client.consumeReceived();
    try std.testing.expectEqual(ColorScheme.dark, store.takeEvent().?.appearance_changed.color_scheme);
}

test "native appearance retries unavailable settings and retains state on disconnect" {
    const unix = @import("wayring").unix_socket;
    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/ouro-appearance-{d}.sock", .{linux.getpid()});
    defer std.testing.allocator.free(path);
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var store: Store = .{};
    var client: Client = undefined;
    try client.init(std.testing.allocator, &loop, &store, path);
    defer client.deinit();
    try testDispatch(&client);
    try std.testing.expectEqual(State.waiting, client.state);
    try std.testing.expectEqual(ColorScheme.default, store.current.color_scheme);

    const listener = try unix.listen(path, 1);
    defer _ = linux.close(listener);
    defer unix.unlink(path) catch unreachable;
    while (client.state != .receiving) try testDispatch(&client);
    const accepted_raw = linux.accept(listener, null, null);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(accepted_raw));
    const accepted: linux.fd_t = @intCast(accepted_raw);
    var request: [512]u8 = undefined;
    const length = linux.read(accepted, &request, request.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(length));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request[0 .. length - 1], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("more").?.bool);
    try std.testing.expectEqualStrings("dev.rockorager.ouro.Settings.WatchPath", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("/appearance/color_scheme", parsed.value.object.get("parameters").?.object.get("path").?.string);
    const reply = "{\"parameters\":{\"revision\":\"1\",\"exists\":true,\"value_json\":\"\\\"dark\\\"\"},\"continues\":true}\x00";
    try std.testing.expectEqual(reply.len, linux.write(accepted, reply, reply.len));
    try testDispatch(&client);
    try std.testing.expectEqual(ColorScheme.dark, store.takeEvent().?.appearance_changed.color_scheme);
    _ = linux.close(accepted);
    while (client.state != .waiting) try testDispatch(&client);
    try std.testing.expectEqual(ColorScheme.dark, store.current.color_scheme);
    try std.testing.expect(store.takeEvent() == null);
    try client.stop();
    while (loop.hasPendingOperations() or loop.hasPendingTimerKernelWork()) try testDispatch(&client);
    try std.testing.expectEqual(State.stopped, client.state);
}

test "native appearance stop drains an in-flight connect without publishing" {
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var store: Store = .{};
    var client: Client = undefined;
    try client.init(std.testing.allocator, &loop, &store, "/missing/ourosettings.sock");
    defer client.deinit();
    try client.stop();
    try client.stop();
    while (loop.hasPendingOperations() or loop.hasPendingTimerKernelWork()) try testDispatch(&client);
    try std.testing.expectEqual(State.stopped, client.state);
    try std.testing.expect(store.takeEvent() == null);
}

fn testDispatch(client: *Client) !void {
    _ = try client.loop.submit();
    switch (client.loop.dispatch(try client.loop.wait())) {
        .socket => |completion| try std.testing.expect(try client.dispatch(completion)),
        .operation_cancel => try client.collectCanceled(),
        .timer_control, .timer_wakeup => while (try client.loop.takeExpired()) |timeout|
            try std.testing.expect(try client.dispatchTimer(timeout.operation)),
        else => return error.UnexpectedCompletion,
    }
}
