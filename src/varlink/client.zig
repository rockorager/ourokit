const std = @import("std");
const Decoder = @import("decoder.zig").Decoder;
const message = @import("message.zig");
const Queue = @import("queue.zig").Queue;

const PendingCall = struct {
    handle: message.CallHandle,
    more: bool,
    upgrade: bool,
};

const State = enum {
    active,
    upgraded,
    failed,
};

pub const Event = union(enum) {
    reply: struct {
        call: message.CallHandle,
        message: message.Reply,
        upgrade_accepted: bool,
    },

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .reply => |*reply| reply.message.deinit(),
        }
        self.* = undefined;
    }
};

/// Sans-I/O Varlink client. Calls may be pipelined, but replies are associated
/// strictly with the oldest reply-producing call as required by Varlink.
pub const Client = struct {
    allocator: std.mem.Allocator,
    decoder: Decoder,
    pending: std.array_list.Managed(PendingCall),
    events: Queue(Event),
    transmits: Queue(message.Transmit),
    next_call: u64 = 1,
    upgrade_call: ?message.CallHandle = null,
    state: State = .active,

    pub fn init(allocator: std.mem.Allocator, config: message.Config) !Client {
        if (config.max_pending_calls == 0 or config.max_events == 0 or
            config.max_transmits == 0) return error.InvalidCapacity;
        var decoder = try Decoder.init(allocator, config.max_message_bytes);
        errdefer decoder.deinit();
        var pending = try std.array_list.Managed(PendingCall).initCapacity(
            allocator,
            config.max_pending_calls,
        );
        errdefer pending.deinit();
        var events = try Queue(Event).init(allocator, config.max_events);
        errdefer events.deinit();
        const transmits = try Queue(message.Transmit).init(allocator, config.max_transmits);
        return .{
            .allocator = allocator,
            .decoder = decoder,
            .pending = pending,
            .events = events,
            .transmits = transmits,
        };
    }

    pub fn deinit(self: *Client) void {
        while (self.events.pop()) |event_value| {
            var event = event_value;
            event.deinit();
        }
        while (self.transmits.pop()) |transmit_value| {
            var transmit = transmit_value;
            transmit.deinit();
        }
        self.transmits.deinit();
        self.events.deinit();
        self.pending.deinit();
        self.decoder.deinit();
        self.* = undefined;
    }

    pub fn call(self: *Client, outgoing: message.OutgoingCall) !message.CallHandle {
        if (self.state != .active) return error.ConnectionNotActive;
        if (self.upgrade_call != null) return error.UpgradePending;
        if (self.transmits.full()) return error.TransmitQueueFull;
        if (!outgoing.oneway and self.pending.items.len == self.pending.capacity)
            return error.PendingCallCapacityExceeded;
        if (outgoing.upgrade and self.pending.items.len != 0)
            return error.UpgradeRequiresIdleConnection;

        var transmit = try message.serializeCall(self.allocator, outgoing);
        errdefer transmit.deinit();
        const handle = self.allocateHandle();
        try self.transmits.push(transmit);
        if (!outgoing.oneway) {
            self.pending.appendAssumeCapacity(.{
                .handle = handle,
                .more = outgoing.more,
                .upgrade = outgoing.upgrade,
            });
            if (outgoing.upgrade) self.upgrade_call = handle;
        }
        return handle;
    }

    /// Feeds as many bytes as current event capacity permits and returns the
    /// consumed prefix. Bytes after an accepted upgrade remain with the caller.
    pub fn feed(self: *Client, bytes: []const u8) !usize {
        if (self.state != .active) return error.ConnectionNotActive;
        var consumed: usize = 0;
        while (consumed < bytes.len) {
            const byte = bytes[consumed];
            if (byte == 0 and self.events.full()) break;
            const frame = self.decoder.push(byte) catch |err| {
                self.state = .failed;
                return err;
            };
            if (frame) |record| {
                self.processReply(record) catch |err| {
                    self.state = .failed;
                    return err;
                };
                self.decoder.consumeFrame();
            }
            consumed += 1;
            if (self.state == .upgraded) break;
        }
        return consumed;
    }

    pub fn takeEvent(self: *Client) ?Event {
        return self.events.pop();
    }

    pub fn takeTransmit(self: *Client) ?message.Transmit {
        return self.transmits.pop();
    }

    pub fn isUpgraded(self: *const Client) bool {
        return self.state == .upgraded;
    }

    pub fn pendingCallCount(self: *const Client) usize {
        return self.pending.items.len;
    }

    fn processReply(self: *Client, record: []const u8) !void {
        if (self.pending.items.len == 0) return error.UnexpectedReply;
        var reply = try message.parseReply(self.allocator, record);
        errdefer reply.deinit();
        const pending = self.pending.items[0];
        if (reply.continues and !pending.more) return error.UnexpectedContinuedReply;
        if (pending.upgrade and reply.continues) return error.UpgradeCannotContinue;

        const final = !reply.continues;
        const upgrade_accepted = pending.upgrade and final and reply.error_name == null;
        try self.events.push(.{ .reply = .{
            .call = pending.handle,
            .message = reply,
            .upgrade_accepted = upgrade_accepted,
        } });
        if (final) {
            _ = self.pending.orderedRemove(0);
            if (pending.upgrade) {
                self.upgrade_call = null;
                if (upgrade_accepted) self.state = .upgraded;
            }
        }
    }

    fn allocateHandle(self: *Client) message.CallHandle {
        const handle: message.CallHandle = .{ .value = self.next_call };
        self.next_call +%= 1;
        if (self.next_call == 0) self.next_call = 1;
        return handle;
    }
};

test "client pipelines calls and associates streamed replies in order" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    const first = try client.call(.{ .method = "org.example.First", .more = true });
    const second = try client.call(.{ .method = "org.example.Second" });
    while (client.takeTransmit()) |value| {
        var transmit = value;
        transmit.deinit();
    }

    const input =
        "{\"parameters\":{},\"continues\":true}\x00" ++
        "{\"parameters\":{}}\x00" ++
        "{\"error\":\"org.example.No\"}\x00";
    try std.testing.expectEqual(input.len, try client.feed(input));
    var event = client.takeEvent().?;
    try std.testing.expectEqual(first, event.reply.call);
    try std.testing.expect(event.reply.message.continues);
    event.deinit();
    event = client.takeEvent().?;
    try std.testing.expectEqual(first, event.reply.call);
    try std.testing.expect(!event.reply.message.continues);
    event.deinit();
    event = client.takeEvent().?;
    try std.testing.expectEqual(second, event.reply.call);
    try std.testing.expectEqualStrings("org.example.No", event.reply.message.error_name.?);
    event.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.pendingCallCount());
}

test "client excludes oneway calls from reply association and preserves upgrade bytes" {
    var client = try Client.init(std.testing.allocator, .{});
    defer client.deinit();
    _ = try client.call(.{ .method = "org.example.Notify", .oneway = true });
    const upgrade = try client.call(.{ .method = "org.example.Upgrade", .upgrade = true });
    while (client.takeTransmit()) |value| {
        var transmit = value;
        transmit.deinit();
    }

    const input = "{\"parameters\":{}}\x00raw-protocol";
    const consumed = try client.feed(input);
    try std.testing.expectEqual(input.len - "raw-protocol".len, consumed);
    try std.testing.expect(client.isUpgraded());
    var event = client.takeEvent().?;
    try std.testing.expectEqual(upgrade, event.reply.call);
    try std.testing.expect(event.reply.upgrade_accepted);
    event.deinit();
}

test "client applies event backpressure before consuming a delimiter" {
    var client = try Client.init(std.testing.allocator, .{ .max_events = 1 });
    defer client.deinit();
    _ = try client.call(.{ .method = "org.example.First", .more = true });
    while (client.takeTransmit()) |value| {
        var transmit = value;
        transmit.deinit();
    }
    const first = "{\"continues\":true}\x00";
    const second = "{}\x00";
    const input = first ++ second;
    try std.testing.expectEqual(first.len + second.len - 1, try client.feed(input));
    var event = client.takeEvent().?;
    event.deinit();
    try std.testing.expectEqual(@as(usize, 1), try client.feed(input[input.len - 1 ..]));
    event = client.takeEvent().?;
    event.deinit();
}
