const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/io_uring.zig");
const mcp = @import("../mcp/root.zig");

const receive_capacity = 16 * 1024;
const message_capacity = mcp.max_message_bytes;
const resource_uri = "ouro://settings/appearance/color_scheme";
const subscription_id_key = "io.modelcontextprotocol/subscriptionId";
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

/// Host-owned MCP appearance subscription. The host routes socket CQEs, expired
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
    protocol: mcp.Client = undefined,
    protocol_initialized: bool = false,
    transmit: ?mcp.Transmit = null,
    subscription: ?mcp.CallHandle = null,
    acknowledged: bool = false,
    read: ?mcp.CallHandle = null,
    dirty: bool = false,
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
        self.protocol = try mcp.Client.init(self.allocator, .{
            .max_message_bytes = message_capacity,
            .max_outbound_message_bytes = message_capacity,
            .max_pending_calls = 2,
            .max_events = 1,
            .max_transmits = 1,
        });
        self.protocol_initialized = true;
        const params = try std.json.parseFromSlice(mcp.Value, self.allocator,
            \\{"notifications":{"resourceSubscriptions":["ouro://settings/appearance/color_scheme"]}}
        , .{});
        defer params.deinit();
        self.subscription = try self.protocol.call(.{
            .method = "subscriptions/listen",
            .params = params.value,
            .subscription = true,
        });
        self.transmit = self.protocol.takeTransmit().?;
    }

    fn prepareNext(self: *Client) !void {
        // Drain each received batch before sending queued calls. A subscription
        // and its read share this single socket operation slot.
        if (self.state == .receiving and self.transmit == null) {
            self.transmit = self.protocol.takeTransmit();
            if (self.transmit != null) self.state = .sending;
        }
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
                switch (event) {
                    .notification => |notification| try self.acceptNotification(notification.message),
                    .reply => |reply| {
                        if (reply.call.value == self.subscription.?.value) return error.SubscriptionEnded;
                        const read = self.read orelse return error.UnexpectedReadReply;
                        if (reply.call.value != read.value) return error.UnexpectedReadReply;
                        if (reply.message.rpc_error != null) return error.ReadFailed;
                        const scheme = try self.readScheme(reply.message.result orelse return error.InvalidReadReply);
                        self.read = null;
                        self.store.update(.{ .color_scheme = scheme });
                        self.retry_ns = retry_min_ns;
                        if (self.dirty) try self.requestRead();
                    },
                }
            }
        }
    }

    fn acceptNotification(self: *Client, notification: mcp.Request) !void {
        const params = notification.params orelse return error.InvalidNotification;
        if (params != .object) return error.InvalidNotification;
        const meta = params.object.get("_meta") orelse return error.InvalidNotification;
        if (meta != .object) return error.InvalidNotification;
        const id = meta.object.get(subscription_id_key) orelse return error.InvalidNotification;
        const subscription_id = switch (id) {
            .number_string => |number| std.fmt.parseInt(u64, number, 10) catch return,
            else => return,
        };
        if (subscription_id != self.subscription.?.value) return;
        if (std.mem.eql(u8, notification.method, "notifications/subscriptions/acknowledged")) {
            if (self.acknowledged) return error.DuplicateAcknowledgment;
            const notifications = params.object.get("notifications") orelse return error.InvalidAcknowledgment;
            if (notifications != .object) return error.InvalidAcknowledgment;
            const resources = notifications.object.get("resourceSubscriptions") orelse return error.InvalidAcknowledgment;
            if (resources != .array) return error.InvalidAcknowledgment;
            for (resources.array.items) |uri| {
                if (uri == .string and std.mem.eql(u8, uri.string, resource_uri)) {
                    self.acknowledged = true;
                    try self.requestRead();
                    return;
                }
            }
            return error.InvalidAcknowledgment;
        }
        if (std.mem.eql(u8, notification.method, "notifications/resources/updated")) {
            if (!self.acknowledged) return error.UpdateBeforeAcknowledgment;
            const uri = params.object.get("uri") orelse return error.InvalidNotification;
            if (uri != .string) return error.InvalidNotification;
            if (!std.mem.eql(u8, uri.string, resource_uri)) return;
            if (self.read != null) {
                self.dirty = true;
            } else try self.requestRead();
        }
    }

    fn requestRead(self: *Client) !void {
        std.debug.assert(self.acknowledged and self.read == null);
        const params = try std.json.parseFromSlice(mcp.Value, self.allocator,
            \\{"uri":"ouro://settings/appearance/color_scheme"}
        , .{});
        defer params.deinit();
        self.read = try self.protocol.call(.{ .method = "resources/read", .params = params.value });
        self.dirty = false;
    }

    fn readScheme(self: *Client, result: mcp.Value) !ColorScheme {
        if (result != .object) return error.InvalidReadReply;
        const contents = result.object.get("contents") orelse return error.InvalidReadReply;
        if (contents != .array or contents.array.items.len != 1) return error.InvalidReadReply;
        const content = contents.array.items[0];
        if (content != .object) return error.InvalidReadReply;
        const uri = content.object.get("uri") orelse return error.InvalidReadReply;
        if (uri != .string or !std.mem.eql(u8, uri.string, resource_uri)) return error.InvalidReadReply;
        const mime = content.object.get("mimeType") orelse return error.InvalidReadReply;
        if (mime != .string or !std.mem.eql(u8, mime.string, "application/json")) return error.InvalidReadReply;
        const text = content.object.get("text") orelse return error.InvalidReadReply;
        if (text != .string) return error.InvalidReadReply;
        return parseSelection(self.allocator, text.string);
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
        self.subscription = null;
        self.acknowledged = false;
        self.read = null;
        self.dirty = false;
        self.received = 0;
        self.consumed = 0;
    }

    fn finishStop(self: *Client) void {
        self.releaseConnection();
        self.state = .stopped;
    }
};

fn parseSelection(allocator: std.mem.Allocator, encoded: []const u8) !ColorScheme {
    const parsed = try std.json.parseFromSlice(mcp.Value, allocator, encoded, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSelection;
    const object = parsed.value.object;
    const revision = object.get("revision") orelse return error.InvalidRevision;
    if (revision != .string or revision.string.len == 0 or revision.string.len > 128 or
        !std.unicode.utf8ValidateSlice(revision.string)) return error.InvalidRevision;
    const exists = object.get("exists") orelse return error.InvalidSelection;
    if (exists != .bool) return error.InvalidSelection;
    const value = object.get("value") orelse return error.InvalidSelection;
    if (!exists.bool) {
        if (value != .null) return error.InvalidSelection;
        return .default;
    }
    if (value != .string) return error.InvalidColorScheme;
    return std.meta.stringToEnum(ColorScheme, value.string) orelse error.InvalidColorScheme;
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

test "appearance selection distinguishes missing from null and validates opaque revisions" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(ColorScheme.default, try parseSelection(allocator,
        \\{"revision":"opaque","exists":false,"value":null}
    ));
    try std.testing.expectEqual(ColorScheme.default, try parseSelection(allocator,
        \\{"revision":"opaque","exists":true,"value":"default"}
    ));
    try std.testing.expectEqual(ColorScheme.dark, try parseSelection(allocator,
        \\{"revision":"not-a-counter","exists":true,"value":"d\u0061rk"}
    ));
    try std.testing.expectError(error.InvalidColorScheme, parseSelection(allocator,
        \\{"revision":"1","exists":true,"value":null}
    ));
    try std.testing.expectError(error.InvalidSelection, parseSelection(allocator,
        \\{"revision":"1","exists":false,"value":"dark"}
    ));
    try std.testing.expectError(error.InvalidSelection, parseSelection(allocator,
        \\{"revision":"1","exists":false}
    ));
    try std.testing.expectError(error.InvalidColorScheme, parseSelection(allocator,
        \\{"revision":"1","exists":true,"value":"unknown"}
    ));
    try std.testing.expectError(error.InvalidRevision, parseSelection(allocator,
        \\{"revision":"","exists":true,"value":"light"}
    ));
    try std.testing.expectError(error.InvalidRevision, parseSelection(allocator,
        \\{"revision":1,"exists":true,"value":"light"}
    ));
    const prefix = "{\"revision\":\"";
    const suffix = "\",\"exists\":true,\"value\":\"light\"}";
    try std.testing.expectEqual(ColorScheme.light, try parseSelection(allocator, prefix ++ "é" ** 64 ++ suffix));
    try std.testing.expectError(error.InvalidRevision, parseSelection(allocator, prefix ++ "é" ** 64 ++ "x" ++ suffix));
    if (parseSelection(allocator, prefix ++ "\xff" ++ suffix)) |_| return error.AcceptedInvalidUtf8 else |_| {}
}

test "appearance subscribes before read and coalesces dirty invalidations across fragmented records" {
    var store: Store = .{};
    var client: Client = .{ .allocator = std.testing.allocator, .store = &store };
    try client.initProtocol();
    defer client.releaseConnection();
    const subscription = try testTakeRequest(&client, "subscriptions/listen");
    try std.testing.expect(client.protocol.takeTransmit() == null);
    try std.testing.expect(client.read == null);
    const ack = try testNotification(subscription, true, resource_uri);
    defer std.testing.allocator.free(ack);
    const split = ack.len / 3;
    try testReceive(&client, ack[0..split]);
    try std.testing.expect(store.takeEvent() == null);
    try std.testing.expect(client.read == null);
    try testReceive(&client, ack[split..]);
    const first_read = try testTakeRequest(&client, "resources/read");
    try std.testing.expectEqual(@as(usize, 2), client.protocol.pendingCallCount());
    const update = try testNotification(subscription, false, resource_uri);
    defer std.testing.allocator.free(update);
    const first_reply = try testReply(first_read, resource_uri,
        \\{"revision":"z","exists":true,"value":"light"}
    );
    defer std.testing.allocator.free(first_reply);
    const batch = try std.mem.concat(std.testing.allocator, u8, &.{ update, update, first_reply, update });
    defer std.testing.allocator.free(batch);
    try testReceive(&client, batch);
    try std.testing.expectEqual(ColorScheme.light, store.current.color_scheme);
    const second_read = try testTakeRequest(&client, "resources/read");
    try std.testing.expect(second_read != first_read);
    try std.testing.expect(client.protocol.takeTransmit() == null);
    try std.testing.expectEqual(@as(usize, 2), client.protocol.pendingCallCount());
    // The final notification in the batch belongs to the second read, not
    // the completed first read, so it must cause one more read afterwards.
    try std.testing.expect(client.dirty);
    const second_reply = try testReply(second_read, resource_uri,
        \\{"revision":"a","exists":true,"value":"dark"}
    );
    defer std.testing.allocator.free(second_reply);
    try testReceive(&client, second_reply[0 .. second_reply.len - 1]);
    try std.testing.expectEqual(ColorScheme.light, store.current.color_scheme);
    try testReceive(&client, second_reply[second_reply.len - 1 ..]);
    try std.testing.expectEqual(ColorScheme.dark, store.takeEvent().?.appearance_changed.color_scheme);
    const third_read = try testTakeRequest(&client, "resources/read");
    const third_reply = try testReply(third_read, resource_uri,
        \\{"revision":"same-selection","exists":true,"value":"dark"}
    );
    defer std.testing.allocator.free(third_reply);
    try testReceive(&client, third_reply);
    try std.testing.expect(store.takeEvent() == null);
    try std.testing.expect(client.read == null and !client.dirty);
    try std.testing.expectEqual(@as(usize, 1), client.protocol.pendingCallCount());
    try std.testing.expect(client.protocol.takeTransmit() == null);
    try testReceive(&client, update);
    _ = try testTakeRequest(&client, "resources/read");
}

test "appearance ignores unrelated subscription IDs and URIs but rejects wrong acknowledgment and order" {
    var store: Store = .{ .current = .{ .color_scheme = .dark } };
    var client: Client = .{ .allocator = std.testing.allocator, .store = &store };
    try client.initProtocol();
    defer client.releaseConnection();
    const subscription = try testTakeRequest(&client, "subscriptions/listen");
    const wrong_id = try testNotification(subscription + 99, true, resource_uri);
    defer std.testing.allocator.free(wrong_id);
    try testReceive(&client, wrong_id);
    try std.testing.expect(!client.acknowledged and client.read == null);
    const wrong_uri = try testNotification(subscription, true, "ouro://settings/other");
    defer std.testing.allocator.free(wrong_uri);
    try std.testing.expectError(error.InvalidAcknowledgment, testReceive(&client, wrong_uri));
    const update = try testNotification(subscription, false, resource_uri);
    defer std.testing.allocator.free(update);
    try std.testing.expectError(error.UpdateBeforeAcknowledgment, testReceive(&client, update));
    const ack = try testNotification(subscription, true, resource_uri);
    defer std.testing.allocator.free(ack);
    try testReceive(&client, ack);
    _ = try testTakeRequest(&client, "resources/read");
    const unrelated_uri = try testNotification(subscription, false, "ouro://settings/other");
    defer std.testing.allocator.free(unrelated_uri);
    try testReceive(&client, unrelated_uri);
    const unrelated_id = try testNotification(subscription + 99, false, resource_uri);
    defer std.testing.allocator.free(unrelated_id);
    try testReceive(&client, unrelated_id);
    try std.testing.expect(!client.dirty);
    try std.testing.expect(client.protocol.takeTransmit() == null);
    try std.testing.expectEqual(ColorScheme.dark, store.current.color_scheme);
    try std.testing.expect(store.takeEvent() == null);
}

test "appearance invalid replies retain last good state" {
    const cases = .{
        .{ resource_uri, "{\"revision\":\"\",\"exists\":true,\"value\":\"light\"}" },
        .{ resource_uri, "{\"revision\":\"1\",\"exists\":true,\"value\":null}" },
        .{ resource_uri, "{\"revision\":\"1\",\"exists\":true,\"value\":\"unknown\"}" },
        .{ resource_uri, "{\"revision\":\"1\",\"exists\":false,\"value\":\"light\"}" },
        .{ "ouro://settings/other", "{\"revision\":\"1\",\"exists\":true,\"value\":\"light\"}" },
    };
    inline for (cases) |case| {
        var store: Store = .{ .current = .{ .color_scheme = .dark } };
        var client: Client = .{ .allocator = std.testing.allocator, .store = &store };
        try client.initProtocol();
        defer client.releaseConnection();
        const subscription = try testTakeRequest(&client, "subscriptions/listen");
        const ack = try testNotification(subscription, true, resource_uri);
        defer std.testing.allocator.free(ack);
        try testReceive(&client, ack);
        const read = try testTakeRequest(&client, "resources/read");
        const reply = try testReply(read, case[0], case[1]);
        defer std.testing.allocator.free(reply);
        if (testReceive(&client, reply)) |_| return error.AcceptedInvalidReply else |_| {}
        try std.testing.expectEqual(ColorScheme.dark, store.current.color_scheme);
        try std.testing.expect(store.takeEvent() == null);
    }
}

test "appearance rejects uncorrelated replies and terminal subscription results" {
    for ([_]bool{ false, true }) |terminal| {
        var store: Store = .{ .current = .{ .color_scheme = .dark } };
        var client: Client = .{ .allocator = std.testing.allocator, .store = &store };
        try client.initProtocol();
        defer client.releaseConnection();
        const subscription = try testTakeRequest(&client, "subscriptions/listen");
        const reply = try testReply(if (terminal) subscription else subscription + 99, resource_uri,
            \\{"revision":"1","exists":true,"value":"light"}
        );
        defer std.testing.allocator.free(reply);
        if (testReceive(&client, reply)) |_| return error.AcceptedUnexpectedReply else |_| {}
        try std.testing.expectEqual(ColorScheme.dark, store.current.color_scheme);
        try std.testing.expect(store.takeEvent() == null);
    }
}

test "appearance accepts 4 MiB including newline and rejects one extra byte" {
    for ([_]usize{ 0, 1 }) |extra| {
        var store: Store = .{ .current = .{ .color_scheme = .dark } };
        var client: Client = .{ .allocator = std.testing.allocator, .store = &store };
        try client.initProtocol();
        defer client.releaseConnection();
        const subscription = try testTakeRequest(&client, "subscriptions/listen");
        const ack = try testNotification(subscription, true, resource_uri);
        defer std.testing.allocator.free(ack);
        try testReceive(&client, ack);
        const read = try testTakeRequest(&client, "resources/read");
        const reply = try testReply(read, resource_uri,
            \\{"revision":"1","exists":true,"value":"light"}
        );
        defer std.testing.allocator.free(reply);
        const padded = try std.testing.allocator.alloc(u8, message_capacity + extra);
        defer std.testing.allocator.free(padded);
        @memset(padded, ' ');
        @memcpy(padded[0 .. reply.len - 1], reply[0 .. reply.len - 1]);
        padded[padded.len - 1] = '\n';
        if (extra == 0) {
            try testReceive(&client, padded);
            try std.testing.expectEqual(ColorScheme.light, store.takeEvent().?.appearance_changed.color_scheme);
        } else {
            try std.testing.expectError(error.MessageTooLarge, testReceive(&client, padded));
            try std.testing.expectEqual(ColorScheme.dark, store.current.color_scheme);
            try std.testing.expect(store.takeEvent() == null);
        }
    }
}

test "native appearance retries and reconnects with subscribe ack read then drains receive cancellation" {
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
    const subscription = try testSocketRequest(accepted, "subscriptions/listen");
    const ack = try testNotification(subscription, true, resource_uri);
    defer std.testing.allocator.free(ack);
    try std.testing.expectEqual(ack.len, linux.write(accepted, ack.ptr, ack.len));
    try testDispatch(&client);
    while (client.state != .receiving) try testDispatch(&client);
    try std.testing.expect(store.takeEvent() == null);
    const read = try testSocketRequest(accepted, "resources/read");
    const reply = try testReply(read, resource_uri,
        \\{"revision":"1","exists":true,"value":"dark"}
    );
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqual(reply.len, linux.write(accepted, reply.ptr, reply.len));
    try testDispatch(&client);
    try std.testing.expectEqual(ColorScheme.dark, store.takeEvent().?.appearance_changed.color_scheme);
    const retired_operation = client.operation.?;
    _ = linux.close(accepted);
    while (client.state != .waiting) try testDispatch(&client);
    try std.testing.expectEqual(ColorScheme.dark, store.current.color_scheme);
    try std.testing.expect(store.takeEvent() == null);
    while (client.state != .receiving) try testDispatch(&client);
    try std.testing.expect(!same(retired_operation, client.operation.?));
    try std.testing.expect(!try client.dispatch(.{ .operation = retired_operation, .kind = .recv, .result = 0 }));
    const reconnected_raw = linux.accept(listener, null, null);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(reconnected_raw));
    const reconnected: linux.fd_t = @intCast(reconnected_raw);
    defer _ = linux.close(reconnected);
    const resubscription = try testSocketRequest(reconnected, "subscriptions/listen");
    try std.testing.expect(!client.acknowledged and client.read == null and !client.dirty);
    const reack = try testNotification(resubscription, true, resource_uri);
    defer std.testing.allocator.free(reack);
    try std.testing.expectEqual(reack.len, linux.write(reconnected, reack.ptr, reack.len));
    try testDispatch(&client);
    while (client.state != .receiving) try testDispatch(&client);
    const reread = try testSocketRequest(reconnected, "resources/read");
    const missing = try testReply(reread, resource_uri,
        \\{"revision":"2","exists":false,"value":null}
    );
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(missing.len, linux.write(reconnected, missing.ptr, missing.len));
    try testDispatch(&client);
    try std.testing.expectEqual(ColorScheme.default, store.takeEvent().?.appearance_changed.color_scheme);
    // A receive is pending at stop. Keep all protocol/socket storage alive
    // until both the operation's terminal CQE and cancel CQE are drained.
    try std.testing.expect(client.operation != null);
    try client.stop();
    try std.testing.expectEqual(State.stopping, client.state);
    try std.testing.expect(client.protocol_initialized);
    while (loop.hasPendingOperations() or loop.hasPendingTimerKernelWork()) try testDispatch(&client);
    try std.testing.expectEqual(State.stopped, client.state);
    try std.testing.expect(store.takeEvent() == null);
}

test "native appearance stop drains an in-flight connect without publishing" {
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var store: Store = .{};
    var client: Client = undefined;
    try client.init(std.testing.allocator, &loop, &store, "/missing/settings.mcp.sock");
    defer client.deinit();
    try client.stop();
    try client.stop();
    while (loop.hasPendingOperations() or loop.hasPendingTimerKernelWork()) try testDispatch(&client);
    try std.testing.expectEqual(State.stopped, client.state);
    try std.testing.expect(store.takeEvent() == null);
}

// These fixtures use JSON directly, never an MCP server or its encoders.
fn testNotification(id: u64, ack: bool, uri: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}},{s}\"{s}\"{s}}}}}\n",
        .{
            if (ack) "notifications/subscriptions/acknowledged" else "notifications/resources/updated",
            id,
            if (ack) "\"notifications\":{\"resourceSubscriptions\":[" else "\"uri\":",
            uri,
            if (ack) "]}" else "",
        },
    );
}

fn testReply(id: u64, uri: []const u8, selection: []const u8) ![]u8 {
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, selection, .{});
    defer std.testing.allocator.free(text);
    return std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\",\"contents\":[{{\"uri\":\"{s}\",\"mimeType\":\"application/json\",\"text\":{s}}}]}}}}\n",
        .{ id, uri, text },
    );
}

fn testReceive(client: *Client, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = @min(bytes.len - offset, client.receive_buffer.len);
        @memcpy(client.receive_buffer[0..count], bytes[offset..][0..count]);
        client.received = count;
        client.consumed = 0;
        try client.consumeReceived();
        offset += count;
    }
}

fn testTakeRequest(client: *Client, method: []const u8) !u64 {
    var transmit = if (client.transmit) |transmit| transmit else client.protocol.takeTransmit() orelse return error.MissingRequest;
    client.transmit = null;
    defer transmit.deinit();
    return testRequest(transmit.remaining(), method);
}

fn testSocketRequest(fd: linux.fd_t, method: []const u8) !u64 {
    var request: [2048]u8 = undefined;
    var length: usize = 0;
    while (length < request.len) {
        const count = linux.read(fd, request[length..].ptr, request.len - length);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(count));
        try std.testing.expect(count > 0);
        length += count;
        if (std.mem.indexOfScalar(u8, request[0..length], '\n') != null) break;
    }
    return testRequest(request[0..length], method);
}

fn testRequest(bytes: []const u8, method: []const u8) !u64 {
    try std.testing.expect(bytes.len <= message_capacity);
    try std.testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, bytes, 0) == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bytes));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0 .. bytes.len - 1], .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", object.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings(method, object.get("method").?.string);
    try std.testing.expect(object.get("more") == null and object.get("parameters") == null);
    const params = object.get("params").?.object;
    const meta = params.get("_meta").?.object;
    try std.testing.expectEqualStrings("2026-07-28", meta.get("io.modelcontextprotocol/protocolVersion").?.string);
    try std.testing.expectEqual(@as(usize, 0), meta.get("io.modelcontextprotocol/clientCapabilities").?.object.count());
    try std.testing.expect(meta.get("io.modelcontextprotocol/clientInfo").?.object.get("name").?.string.len > 0);
    if (std.mem.eql(u8, method, "subscriptions/listen")) {
        const resources = params.get("notifications").?.object.get("resourceSubscriptions").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), resources.len);
        try std.testing.expectEqualStrings(resource_uri, resources[0].string);
    } else {
        try std.testing.expectEqualStrings(resource_uri, params.get("uri").?.string);
    }
    return @intCast(object.get("id").?.integer);
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
