const std = @import("std");
const Decoder = @import("decoder.zig").Decoder;
const message = @import("message.zig");
const Queue = @import("queue.zig").Queue;

const State = enum {
    active,
    upgrade_requested,
    upgraded,
    failed,
};

const PendingCall = struct {
    handle: message.CallHandle,
    more: bool,
    upgrade: bool,
    final_queued: bool = false,
};

const BufferedReply = struct {
    call: message.CallHandle,
    transmit: message.Transmit,
    final: bool,
    accepts_upgrade: bool,
};

pub const Event = union(enum) {
    call: struct {
        handle: message.CallHandle,
        request: message.Request,
    },

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .call => |*call| call.request.deinit(),
        }
        self.* = undefined;
    }
};

/// Sans-I/O Varlink server. Requests may be handled concurrently. Submitted
/// replies are buffered and emitted only when their call reaches the head of
/// the protocol's non-multiplexed reply order.
pub const Server = struct {
    allocator: std.mem.Allocator,
    decoder: Decoder,
    pending: std.array_list.Managed(PendingCall),
    buffered: std.array_list.Managed(BufferedReply),
    events: Queue(Event),
    transmits: Queue(message.Transmit),
    next_call: u64 = 1,
    state: State = .active,

    pub fn init(allocator: std.mem.Allocator, config: message.Config) !Server {
        if (config.max_pending_calls == 0 or config.max_buffered_replies == 0 or
            config.max_events == 0 or config.max_transmits == 0)
            return error.InvalidCapacity;
        var decoder = try Decoder.init(allocator, config.max_message_bytes);
        errdefer decoder.deinit();
        var pending = try std.array_list.Managed(PendingCall).initCapacity(
            allocator,
            config.max_pending_calls,
        );
        errdefer pending.deinit();
        var buffered = try std.array_list.Managed(BufferedReply).initCapacity(
            allocator,
            config.max_buffered_replies,
        );
        errdefer buffered.deinit();
        var events = try Queue(Event).init(allocator, config.max_events);
        errdefer events.deinit();
        const transmits = try Queue(message.Transmit).init(allocator, config.max_transmits);
        return .{
            .allocator = allocator,
            .decoder = decoder,
            .pending = pending,
            .buffered = buffered,
            .events = events,
            .transmits = transmits,
        };
    }

    pub fn deinit(self: *Server) void {
        while (self.events.pop()) |event_value| {
            var event = event_value;
            event.deinit();
        }
        for (self.buffered.items) |*reply| reply.transmit.deinit();
        while (self.transmits.pop()) |transmit_value| {
            var transmit = transmit_value;
            transmit.deinit();
        }
        self.transmits.deinit();
        self.events.deinit();
        self.buffered.deinit();
        self.pending.deinit();
        self.decoder.deinit();
        self.* = undefined;
    }

    /// Feeds a prefix that fits current request capacity. An upgrade request
    /// stops framing at its delimiter until the application accepts or rejects
    /// it with a final reply.
    pub fn feed(self: *Server, bytes: []const u8) !usize {
        if (self.state != .active) return error.ConnectionNotReceiving;
        var consumed: usize = 0;
        while (consumed < bytes.len) {
            const byte = bytes[consumed];
            if (byte == 0 and (self.events.full() or
                self.pending.items.len == self.pending.capacity)) break;
            const frame = self.decoder.push(byte) catch |err| {
                self.state = .failed;
                return err;
            };
            if (frame) |record| {
                self.processRequest(record) catch |err| {
                    self.state = .failed;
                    return err;
                };
                self.decoder.consumeFrame();
            }
            consumed += 1;
            if (self.state != .active) break;
        }
        return consumed;
    }

    pub fn takeEvent(self: *Server) ?Event {
        return self.events.pop();
    }

    pub fn sendReply(
        self: *Server,
        call: message.CallHandle,
        parameters: ?message.Value,
    ) !void {
        try self.queueReply(call, parameters, null, false);
    }

    pub fn sendContinued(
        self: *Server,
        call: message.CallHandle,
        parameters: ?message.Value,
    ) !void {
        try self.queueReply(call, parameters, null, true);
    }

    pub fn sendError(
        self: *Server,
        call: message.CallHandle,
        error_name: []const u8,
        parameters: ?message.Value,
    ) !void {
        try self.queueReply(call, parameters, error_name, false);
    }

    pub fn takeTransmit(self: *Server) ?message.Transmit {
        const transmit = self.transmits.pop() orelse return null;
        self.flushReady();
        return transmit;
    }

    pub fn isUpgraded(self: *const Server) bool {
        return self.state == .upgraded;
    }

    pub fn pendingCallCount(self: *const Server) usize {
        return self.pending.items.len;
    }

    fn processRequest(self: *Server, record: []const u8) !void {
        var request = try message.parseRequest(self.allocator, record);
        errdefer request.deinit();
        if ((request.oneway and (request.more or request.upgrade)) or
            (request.more and request.upgrade))
            return error.IncompatibleCallFlags;
        const handle = self.allocateHandle();
        if (!request.oneway) self.pending.appendAssumeCapacity(.{
            .handle = handle,
            .more = request.more,
            .upgrade = request.upgrade,
        });
        try self.events.push(.{ .call = .{ .handle = handle, .request = request } });
        if (request.upgrade) self.state = .upgrade_requested;
    }

    fn queueReply(
        self: *Server,
        call: message.CallHandle,
        parameters: ?message.Value,
        error_name: ?[]const u8,
        continues: bool,
    ) !void {
        if (self.state == .upgraded or self.state == .failed)
            return error.ConnectionNotActive;
        const pending = self.findPending(call) orelse return error.UnknownCall;
        if (pending.final_queued) return error.CallAlreadyFinished;
        if (continues and (!pending.more or pending.upgrade))
            return error.ContinuedReplyNotAllowed;
        if (self.buffered.items.len == self.buffered.capacity)
            return error.BufferedReplyCapacityExceeded;

        const final = !continues;
        const accepts_upgrade = pending.upgrade and final and error_name == null;
        var transmit = try message.serializeReply(
            self.allocator,
            parameters,
            error_name,
            continues,
            if (accepts_upgrade) .upgrade else .none,
        );
        errdefer transmit.deinit();
        self.buffered.appendAssumeCapacity(.{
            .call = call,
            .transmit = transmit,
            .final = final,
            .accepts_upgrade = accepts_upgrade,
        });
        if (final) pending.final_queued = true;
        self.flushReady();
    }

    fn flushReady(self: *Server) void {
        while (self.pending.items.len != 0 and !self.transmits.full()) {
            const head = self.pending.items[0];
            const reply_index = self.findBuffered(head.handle) orelse return;
            const reply = self.buffered.orderedRemove(reply_index);
            self.transmits.push(reply.transmit) catch unreachable;
            if (!reply.final) continue;
            _ = self.pending.orderedRemove(0);
            if (head.upgrade) {
                self.state = if (reply.accepts_upgrade) .upgraded else .active;
                return;
            }
        }
    }

    fn findPending(self: *Server, handle: message.CallHandle) ?*PendingCall {
        for (self.pending.items) |*pending|
            if (pending.handle.value == handle.value) return pending;
        return null;
    }

    fn findBuffered(self: *Server, handle: message.CallHandle) ?usize {
        for (self.buffered.items, 0..) |reply, index|
            if (reply.call.value == handle.value) return index;
        return null;
    }

    fn allocateHandle(self: *Server) message.CallHandle {
        const handle: message.CallHandle = .{ .value = self.next_call };
        self.next_call +%= 1;
        if (self.next_call == 0) self.next_call = 1;
        return handle;
    }
};

test "server emits pipelined calls and orders asynchronous replies" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    const input =
        "{\"method\":\"org.example.First\"}\x00" ++
        "{\"method\":\"org.example.Second\"}\x00";
    try std.testing.expectEqual(input.len, try server.feed(input));
    var first_event = server.takeEvent().?;
    const first = first_event.call.handle;
    var second_event = server.takeEvent().?;
    const second = second_event.call.handle;
    try server.sendReply(second, null);
    try std.testing.expect(server.takeTransmit() == null);
    try server.sendError(first, "org.example.FirstFailed", null);

    var transmit = server.takeTransmit().?;
    try std.testing.expect(std.mem.indexOf(u8, transmit.bytes, "FirstFailed") != null);
    transmit.deinit();
    transmit = server.takeTransmit().?;
    try std.testing.expectEqualSlices(u8, "{}\x00", transmit.bytes);
    transmit.deinit();
    first_event.deinit();
    second_event.deinit();
}

test "server enforces streaming and oneway reply rules" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    const input =
        "{\"method\":\"org.example.Notify\",\"oneway\":true}\x00" ++
        "{\"method\":\"org.example.Watch\",\"more\":true}\x00";
    _ = try server.feed(input);
    var oneway = server.takeEvent().?;
    var stream = server.takeEvent().?;
    try std.testing.expectError(error.UnknownCall, server.sendReply(oneway.call.handle, null));
    try server.sendContinued(stream.call.handle, null);
    try server.sendReply(stream.call.handle, null);
    try std.testing.expectError(error.UnknownCall, server.sendReply(stream.call.handle, null));
    var transmit = server.takeTransmit().?;
    try std.testing.expect(std.mem.indexOf(u8, transmit.bytes, "continues") != null);
    transmit.deinit();
    transmit = server.takeTransmit().?;
    transmit.deinit();
    oneway.deinit();
    stream.deinit();
}

test "server stops framing at an upgrade and marks its confirmation" {
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    const request = "{\"method\":\"org.example.Upgrade\",\"upgrade\":true}\x00raw";
    const consumed = try server.feed(request);
    try std.testing.expectEqual(request.len - 3, consumed);
    var event = server.takeEvent().?;
    try server.sendReply(event.call.handle, null);
    try std.testing.expect(server.isUpgraded());
    var transmit = server.takeTransmit().?;
    try std.testing.expectEqual(message.AfterSend.upgrade, transmit.after_send);
    transmit.deinit();
    event.deinit();
}
