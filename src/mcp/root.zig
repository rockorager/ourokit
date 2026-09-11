//! Sans-I/O MCP 2026-07-28 over newline-delimited JSON-RPC. No initialize state.
//! feed returns the consumed byte count; retain its unconsumed suffix under
//! queue backpressure. A feed error is connection-fatal. Events own parsed JSON,
//! and transmits own serialized bytes: the caller must deinit each taken item.
//! Replies may finish in any order. Subscription notifications do not complete
//! a call; only a terminal result/error removes it. Discovery and cancellation
//! policy belong to the service consuming ServerEvent, not this transport core.
const std = @import("std");
pub const Value = std.json.Value;
pub const schema = @import("schema.zig");
pub const protocol_version = "2026-07-28";
pub const Config = struct {
    max_message_bytes: usize = 256 * 1024,
    max_outbound_message_bytes: usize = 256 * 1024,
    max_pending_calls: usize = 32,
    max_events: usize = 32,
    max_transmits: usize = 32,
};
pub const CallHandle = struct { value: u64 };
pub const Transmit = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    offset: usize = 0,
    pub fn remaining(self: *const Transmit) []const u8 {
        return self.bytes[self.offset..];
    }
    pub fn consume(self: *Transmit, count: usize) !void {
        if (count > self.remaining().len) return error.InvalidTransmitCount;
        self.offset += count;
    }
    pub fn complete(self: *const Transmit) bool {
        return self.offset == self.bytes.len;
    }
    pub fn deinit(self: *Transmit) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};
pub const Request = struct {
    document: std.json.Parsed(Value),
    method: []const u8,
    params: ?Value,
    id: ?Value,
    pub fn deinit(self: *Request) void {
        self.document.deinit();
        self.* = undefined;
    }
};
pub const Reply = struct {
    document: std.json.Parsed(Value),
    result: ?Value,
    rpc_error: ?Value,
    pub fn deinit(self: *Reply) void {
        self.document.deinit();
        self.* = undefined;
    }
};
pub const OutgoingCall = struct { method: []const u8, params: ?Value = null, subscription: bool = false };
pub const ClientEvent = union(enum) {
    reply: struct { call: CallHandle, message: Reply },
    notification: struct { message: Request },
    pub fn deinit(self: *ClientEvent) void {
        switch (self.*) {
            .reply => |*v| v.message.deinit(),
            .notification => |*v| v.message.deinit(),
        }
        self.* = undefined;
    }
};
pub const ServerEvent = union(enum) {
    call: struct { handle: CallHandle, request: Request },
    pub fn deinit(self: *ServerEvent) void {
        self.call.request.deinit();
        self.* = undefined;
    }
};
pub const Address = union(enum) {
    unix: struct { name: []const u8, abstract: bool },
    pub fn parse(input: []const u8) !Address {
        if (!std.mem.startsWith(u8, input, "unix:")) return error.UnsupportedAddressScheme;
        const name = input[5..];
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidUnixAddress;
        if (name[0] == '@') {
            if (name.len == 1) return error.InvalidUnixAddress;
            return .{ .unix = .{ .name = name[1..], .abstract = true } };
        }
        if (name[0] != '/') return error.UnixPathNotAbsolute;
        return .{ .unix = .{ .name = name, .abstract = false } };
    }
};

pub fn object(allocator: std.mem.Allocator, fields: anytype) !Value {
    var map: std.json.ObjectMap = .empty;
    errdefer map.deinit(allocator);
    inline for (fields) |field| try map.put(allocator, field[0], field[1]);
    return .{ .object = map };
}
pub fn string(value: []const u8) Value {
    return .{ .string = value };
}
pub fn get(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
pub fn isString(value: ?Value, expected: []const u8) bool {
    const v = value orelse return false;
    return v == .string and std.mem.eql(u8, v.string, expected);
}
fn validId(id: Value) bool {
    return switch (id) {
        .string, .integer, .number_string => true,
        else => false,
    };
}
fn copyId(a: std.mem.Allocator, id: Value) !Value {
    return switch (id) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        else => id,
    };
}
fn freeId(a: std.mem.Allocator, id: Value) void {
    switch (id) {
        .string => |s| a.free(s),
        .number_string => |s| a.free(s),
        else => {},
    }
}
fn equalId(a: Value, b: Value) bool {
    if (a == .string or b == .string) return a == .string and b == .string and std.mem.eql(u8, a.string, b.string);
    if (a == .number_string and b == .number_string and std.mem.eql(u8, a.number_string, b.number_string)) return true;
    return schema.equalNumbers(a, b);
}
const Pending = struct { handle: CallHandle, id: Value };
pub const Client = Peer(false);
pub const Server = Peer(true);

fn Peer(comptime server: bool) type {
    return struct {
        const Self = @This();
        const Event = if (server) ServerEvent else ClientEvent;
        allocator: std.mem.Allocator,
        config: Config,
        input: std.array_list.Managed(u8),
        events: std.array_list.Managed(Event),
        transmits: std.array_list.Managed(Transmit),
        pending: std.array_list.Managed(Pending),
        next: u64 = 1,
        ended: bool = false,

        pub fn init(a: std.mem.Allocator, config: Config) !Self {
            if (config.max_message_bytes == 0 or config.max_outbound_message_bytes == 0 or config.max_pending_calls == 0 or config.max_events == 0 or config.max_transmits == 0) return error.InvalidCapacity;
            if (config.max_message_bytes > 256 * 1024 or config.max_outbound_message_bytes > 256 * 1024) return error.InvalidCapacity;
            return .{ .allocator = a, .config = config, .input = .init(a), .events = .init(a), .transmits = .init(a), .pending = .init(a) };
        }
        pub fn deinit(self: *Self) void {
            for (self.events.items) |*e| e.deinit();
            for (self.transmits.items) |*t| t.deinit();
            for (self.pending.items) |p| freeId(self.allocator, p.id);
            self.input.deinit();
            self.events.deinit();
            self.transmits.deinit();
            self.pending.deinit();
            self.* = undefined;
        }
        pub fn pendingCallCount(self: *const Self) usize {
            return self.pending.items.len;
        }
        pub fn takeEvent(self: *Self) ?Event {
            return if (self.events.items.len == 0) null else self.events.orderedRemove(0);
        }
        pub fn takeTransmit(self: *Self) ?Transmit {
            return if (self.transmits.items.len == 0) null else self.transmits.orderedRemove(0);
        }
        pub fn endInput(self: *Self) !void {
            self.ended = true;
            if (self.input.items.len != 0) return error.TruncatedMessage;
        }
        fn enqueue(self: *Self, value: anytype) !void {
            if (self.transmits.items.len == self.config.max_transmits) return error.TransmitCapacityExceeded;
            const storage = try self.allocator.alloc(u8, self.config.max_outbound_message_bytes);
            defer self.allocator.free(storage);
            var writer: std.Io.Writer = .fixed(storage);
            std.json.Stringify.value(value, .{}, &writer) catch return error.MessageTooLarge;
            writer.writeByte('\n') catch return error.MessageTooLarge;
            const bytes = try self.allocator.dupe(u8, writer.buffered());
            errdefer self.allocator.free(bytes);
            try self.transmits.append(.{ .allocator = self.allocator, .bytes = bytes });
        }
        fn sendRequest(self: *Self, method: []const u8, params: ?Value, id: ?Value) !void {
            if (method.len == 0) return error.InvalidMethod;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var p = try object(a, .{});
            if (params) |v| {
                if (v != .object) return error.ParametersMustBeObject;
                var it = v.object.iterator();
                while (it.next()) |entry| try p.object.put(a, entry.key_ptr.*, entry.value_ptr.*);
            }
            if (id != null) {
                var meta = try object(a, .{});
                if (get(p, "_meta")) |v| {
                    if (v != .object) return error.InvalidMetadata;
                    var it = v.object.iterator();
                    while (it.next()) |e| try meta.object.put(a, e.key_ptr.*, e.value_ptr.*);
                }
                try meta.object.put(a, "io.modelcontextprotocol/protocolVersion", string(protocol_version));
                try meta.object.put(a, "io.modelcontextprotocol/clientCapabilities", try object(a, .{}));
                try meta.object.put(a, "io.modelcontextprotocol/clientInfo", try object(a, .{ .{ "name", string("ourokit") }, .{ "version", string("0.1.0") } }));
                try p.object.put(a, "_meta", meta);
            }
            var envelope = try object(a, .{ .{ "jsonrpc", string("2.0") }, .{ "method", string(method) }, .{ "params", p } });
            if (id) |v| try envelope.object.put(a, "id", v);
            try self.enqueue(envelope);
        }
        pub fn call(self: *Self, outgoing: OutgoingCall) !CallHandle {
            if (server) @compileError("Server cannot initiate calls");
            if (self.ended) return error.InputEnded;
            if (self.pending.items.len == self.config.max_pending_calls) return error.PendingCallCapacityExceeded;
            if (self.next > std.math.maxInt(i64)) return error.CallIdExhausted;
            const handle: CallHandle = .{ .value = self.next };
            const id: Value = .{ .integer = @intCast(self.next) };
            try self.pending.ensureUnusedCapacity(1);
            try self.sendRequest(outgoing.method, outgoing.params, id);
            self.pending.appendAssumeCapacity(.{ .handle = handle, .id = id });
            self.next += 1;
            return handle;
        }
        pub fn notify(self: *Self, method: []const u8, params: ?Value) !void {
            try self.sendRequest(method, params, null);
        }
        pub fn sendNotification(self: *Self, method: []const u8, params: ?Value) !void {
            try self.notify(method, params);
        }
        fn index(self: *Self, handle: CallHandle) !usize {
            for (self.pending.items, 0..) |p, i| if (p.handle.value == handle.value) return i;
            return error.UnknownCall;
        }
        fn remove(self: *Self, i: usize) void {
            freeId(self.allocator, self.pending.orderedRemove(i).id);
        }
        /// Forget only after the owner has completed cancellation. This emits no wire message.
        /// A cancelled client call must normally remain pending until its terminal reply.
        pub fn abandon(self: *Self, handle: CallHandle) !void {
            self.remove(try self.index(handle));
        }
        pub fn handleForId(self: *Self, id: Value) ?CallHandle {
            if (!validId(id)) return null;
            for (self.pending.items) |p| if (equalId(p.id, id)) return p.handle;
            return null;
        }
        pub fn sendResult(self: *Self, handle: CallHandle, result: Value) !void {
            const i = try self.index(handle);
            if (result != .object) return error.InvalidResult;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var out = try object(a, .{});
            var it = result.object.iterator();
            while (it.next()) |e| try out.object.put(a, e.key_ptr.*, e.value_ptr.*);
            try out.object.put(a, "resultType", string("complete"));
            try self.enqueue(.{ .jsonrpc = "2.0", .id = self.pending.items[i].id, .result = out });
            self.remove(i);
        }
        fn rpcError(self: *Self, id: ?Value, code: i32, message: []const u8, data: ?Value) !void {
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var detail = try object(a, .{ .{ "code", Value{ .integer = code } }, .{ "message", string(message) } });
            if (data) |v| try detail.object.put(a, "data", v);
            var out = try object(a, .{ .{ "jsonrpc", string("2.0") }, .{ "error", detail } });
            if (id) |v| try out.object.put(a, "id", v);
            try self.enqueue(out);
        }
        pub fn sendError(self: *Self, handle: CallHandle, code: i32, message: []const u8, data: ?Value) !void {
            const i = try self.index(handle);
            try self.rpcError(self.pending.items[i].id, code, message, data);
            self.remove(i);
        }
        pub fn feed(self: *Self, bytes: []const u8) !usize {
            if (self.ended) return error.InputEnded;
            var count: usize = 0;
            for (bytes) |byte| {
                if (self.events.items.len == self.config.max_events or (server and self.transmits.items.len == self.config.max_transmits)) break;
                if (self.input.items.len + 1 > self.config.max_message_bytes) return error.MessageTooLarge;
                if (byte == '\n') {
                    try self.frame(self.input.items);
                    self.input.clearRetainingCapacity();
                } else {
                    if (self.input.items.len + 1 == self.config.max_message_bytes) return error.MessageTooLarge;
                    try self.input.append(byte);
                }
                count += 1;
            }
            return count;
        }
        fn frame(self: *Self, bytes: []const u8) !void {
            var doc = std.json.parseFromSlice(Value, self.allocator, bytes, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (server) return self.rpcError(null, -32700, "Parse error", null);
                return error.InvalidJson;
            };
            var transferred = false;
            defer if (!transferred) doc.deinit();
            const v = doc.value;
            const raw_id = get(v, "id");
            const id = if (raw_id) |x| (if (validId(x)) x else null) else null;
            const method = get(v, "method");
            const params = get(v, "params");
            if (!isString(get(v, "jsonrpc"), "2.0") or (raw_id != null and id == null)) {
                if (server) return self.rpcError(id, -32600, "Invalid request", null);
                return error.InvalidEnvelope;
            }
            if (server or method != null) {
                if (method == null or method.? != .string or method.?.string.len == 0 or (params != null and params.? != .object) or get(v, "result") != null or get(v, "error") != null or (!server and id != null)) {
                    if (server) return self.rpcError(id, -32600, "Invalid request", null);
                    return error.InvalidEnvelope;
                }
                if (server and id != null) {
                    const meta = if (params) |p| get(p, "_meta") else null;
                    const version = if (meta) |m| get(m, "io.modelcontextprotocol/protocolVersion") else null;
                    if (version == null or version.? != .string) return self.rpcError(id, -32602, "Missing protocol version", null);
                    if (!isString(version, protocol_version)) {
                        var arena: std.heap.ArenaAllocator = .init(self.allocator);
                        defer arena.deinit();
                        var supported = std.array_list.Managed(Value).init(arena.allocator());
                        try supported.append(string(protocol_version));
                        return self.rpcError(id, -32022, "Unsupported protocol version", try object(arena.allocator(), .{ .{ "supported", Value{ .array = supported } }, .{ "requested", version.? } }));
                    }
                    const capabilities = get(meta.?, "io.modelcontextprotocol/clientCapabilities");
                    if (capabilities == null or capabilities.? != .object) return self.rpcError(id, -32602, "Missing client capabilities", null);
                    if (self.handleForId(id.?) != null) return self.rpcError(id, -32600, "Duplicate active request ID", null);
                    if (self.pending.items.len == self.config.max_pending_calls) return self.rpcError(id, -32000, "Pending request capacity exceeded", null);
                }
                const request: Request = .{ .document = doc, .method = method.?.string, .params = params, .id = id };
                if (server) {
                    const handle: CallHandle = .{ .value = if (id != null) self.next else 0 };
                    try self.events.ensureUnusedCapacity(1);
                    if (id) |x| {
                        const next = std.math.add(u64, self.next, 1) catch return error.CallIdExhausted;
                        const owned = try copyId(self.allocator, x);
                        errdefer freeId(self.allocator, owned);
                        try self.pending.append(.{ .handle = handle, .id = owned });
                        self.next = next;
                    }
                    self.events.appendAssumeCapacity(.{ .call = .{ .handle = handle, .request = request } });
                } else try self.events.append(.{ .notification = .{ .message = request } });
                transferred = true;
                return;
            }
            const result = get(v, "result");
            const rpc_error = get(v, "error");
            if (id == null or (result == null) == (rpc_error == null)) return error.InvalidEnvelope;
            if (result) |r| {
                if (r != .object) return error.InvalidResult;
                if (get(r, "resultType")) |kind| if (!isString(kind, "complete")) return error.UnsupportedResultType;
            }
            if (rpc_error) |e| {
                const code = get(e, "code") orelse return error.InvalidRpcError;
                const msg = get(e, "message") orelse return error.InvalidRpcError;
                if (code != .number_string or msg != .string) return error.InvalidRpcError;
                _ = std.fmt.parseInt(i32, code.number_string, 10) catch return error.InvalidRpcError;
            }
            const handle = self.handleForId(id.?) orelse return error.UnknownCall;
            try self.events.append(.{ .reply = .{ .call = handle, .message = .{ .document = doc, .result = result, .rpc_error = rpc_error } } });
            transferred = true;
            self.remove(try self.index(handle));
        }
    };
}

test "literal Unix addresses" {
    try std.testing.expectEqualStrings("/tmp/a;b", (try Address.parse("unix:/tmp/a;b")).unix.name);
    try std.testing.expectEqualStrings("a;b", (try Address.parse("unix:@a;b")).unix.name);
    try std.testing.expectError(error.UnixPathNotAbsolute, Address.parse("unix:relative"));
}

test "correlated out of order replies, subscription notifications, metadata and short writes" {
    const a = std.testing.allocator;
    var client = try Client.init(a, .{});
    defer client.deinit();
    var server = try Server.init(a, .{});
    defer server.deinit();
    const first = try client.call(.{ .method = "subscriptions/listen", .subscription = true });
    const second = try client.call(.{ .method = "tools/list" });
    while (client.takeTransmit()) |t| {
        var tx = t;
        defer tx.deinit();
        while (!tx.complete()) {
            try std.testing.expectEqual(1, try server.feed(tx.remaining()[0..1]));
            try tx.consume(1);
        }
    }
    var e1 = server.takeEvent().?;
    defer e1.deinit();
    var e2 = server.takeEvent().?;
    defer e2.deinit();
    try std.testing.expect(isString(get(get(e1.call.request.params.?, "_meta").?, "io.modelcontextprotocol/protocolVersion"), protocol_version));
    try server.sendResult(e2.call.handle, .{ .object = .empty });
    try server.sendNotification("notifications/subscriptions/acknowledged", null);
    while (server.takeTransmit()) |t| {
        var tx = t;
        defer tx.deinit();
        _ = try client.feed(tx.bytes);
    }
    var reply = client.takeEvent().?;
    defer reply.deinit();
    try std.testing.expectEqual(second.value, reply.reply.call.value);
    var note = client.takeEvent().?;
    defer note.deinit();
    try std.testing.expect(note == .notification);
    try std.testing.expectEqual(1, client.pendingCallCount());
    try server.sendResult(e1.call.handle, .{ .object = .empty });
    var tx = server.takeTransmit().?;
    defer tx.deinit();
    _ = try client.feed(tx.bytes);
    var terminal = client.takeEvent().?;
    defer terminal.deinit();
    try std.testing.expectEqual(first.value, terminal.reply.call.value);
    try std.testing.expectEqual(0, client.pendingCallCount());
}

test "only absent resultType falls back, and numeric lexemes survive" {
    const a = std.testing.allocator;
    var client = try Client.init(a, .{});
    defer client.deinit();
    _ = try client.call(.{ .method = "resources/read" });
    try std.testing.expectError(error.UnsupportedResultType, client.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":null}}\n"));
    // feed errors are fatal to the transport; test a new connection for fallback.
    var other = try Client.init(a, .{});
    defer other.deinit();
    _ = try other.call(.{ .method = "resources/read" });
    _ = try other.feed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"number\":1e0}}\n");
    var e = other.takeEvent().?;
    defer e.deinit();
    try std.testing.expectEqualStrings("1e0", get(e.reply.message.result.?, "number").?.number_string);
}

test "bounds include newline, queues backpressure, malformed errors omit unreadable ID" {
    const a = std.testing.allocator;
    var bounded = try Server.init(a, .{ .max_message_bytes = 3 });
    defer bounded.deinit();
    try std.testing.expectEqual(3, try bounded.feed("{}\n"));
    try std.testing.expectError(error.MessageTooLarge, bounded.feed("123"));
    var server = try Server.init(a, .{ .max_transmits = 1 });
    defer server.deinit();
    try std.testing.expectEqual(2, try server.feed("[\n[\n"));
    var tx = server.takeTransmit().?;
    defer tx.deinit();
    var doc = try std.json.parseFromSlice(Value, a, tx.bytes, .{});
    defer doc.deinit();
    try std.testing.expect(get(doc.value, "id") == null);
    try std.testing.expectEqual(-32700, get(get(doc.value, "error").?, "code").?.integer);
    try std.testing.expectEqual(2, try server.feed("[\n"));
    try std.testing.expectError(error.TruncatedMessage, bounded.endInput());
}

test "saturated pending calls still accept cancellation and report version errors" {
    const a = std.testing.allocator;
    var client = try Client.init(a, .{});
    defer client.deinit();
    var server = try Server.init(a, .{ .max_pending_calls = 1 });
    defer server.deinit();
    _ = try client.call(.{ .method = "subscriptions/listen", .subscription = true });
    var tx = client.takeTransmit().?;
    defer tx.deinit();
    _ = try server.feed(tx.bytes);
    var event = server.takeEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(1, server.pendingCallCount());
    const cancel = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":1}}\n";
    try std.testing.expectEqual(cancel.len, try server.feed(cancel));
    var note = server.takeEvent().?;
    defer note.deinit();
    try std.testing.expect(note.call.request.id == null);
    try std.testing.expectEqual(event.call.handle.value, server.handleForId(get(note.call.request.params.?, "requestId").?).?.value);
    try std.testing.expectError(error.UnknownCall, server.sendResult(note.call.handle, .{ .object = .empty }));
    _ = try client.call(.{ .method = "tools/list" });
    var excess = client.takeTransmit().?;
    defer excess.deinit();
    _ = try server.feed(excess.bytes);
    var rejected = server.takeTransmit().?;
    defer rejected.deinit();
    _ = try client.feed(rejected.bytes);
    var failure = client.takeEvent().?;
    defer failure.deinit();
    try std.testing.expectEqualStrings("-32000", get(failure.reply.message.rpc_error.?, "code").?.number_string);
    try server.sendError(event.call.handle, -32800, "Cancelled", null);
    var terminal = server.takeTransmit().?;
    defer terminal.deinit();
    _ = try client.feed(terminal.bytes);
    var done = client.takeEvent().?;
    defer done.deinit();
    try std.testing.expectEqual(0, client.pendingCallCount());
    const wrong_version = "{\"jsonrpc\":\"2.0\",\"id\":\"opaque\",\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2025-11-25\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n";
    _ = try server.feed(wrong_version);
    var version = server.takeTransmit().?;
    defer version.deinit();
    var doc = try std.json.parseFromSlice(Value, a, version.bytes, .{});
    defer doc.deinit();
    try std.testing.expect(isString(get(doc.value, "id"), "opaque"));
    const detail = get(doc.value, "error").?;
    try std.testing.expectEqual(-32022, get(detail, "code").?.integer);
    try std.testing.expect(isString(get(get(detail, "data").?, "requested"), "2025-11-25"));
}

test "failed outbound serialization is bounded and leaves call state unchanged" {
    const a = std.testing.allocator;
    var client = try Client.init(a, .{ .max_outbound_message_bytes = 10 });
    defer client.deinit();
    try std.testing.expectError(error.MessageTooLarge, client.call(.{ .method = "tools/list" }));
    try std.testing.expectEqual(0, client.pendingCallCount());
    try std.testing.expect(client.takeTransmit() == null);
}

fn allocationLifecycle(a: std.mem.Allocator) !void {
    var client = try Client.init(a, .{});
    defer client.deinit();
    var server = try Server.init(a, .{});
    defer server.deinit();
    _ = try client.call(.{ .method = "tools/list" });
    var tx = client.takeTransmit().?;
    defer tx.deinit();
    _ = try server.feed(tx.bytes);
    var request = server.takeEvent().?;
    defer request.deinit();
    try server.sendResult(request.call.handle, .{ .object = .empty });
    var reply = server.takeTransmit().?;
    defer reply.deinit();
    _ = try client.feed(reply.bytes);
    var event = client.takeEvent().?;
    defer event.deinit();
}

test "protocol ownership survives allocation failure at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}

test "numeric peer IDs retain fractional and large lexemes without aliasing" {
    const a = std.testing.allocator;
    var server = try Server.init(a, .{});
    defer server.deinit();
    const suffix = ",\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}\n";
    inline for (.{ "9007199254740993", "9007199254740992", "1.5" }) |id| {
        _ = try server.feed("{\"jsonrpc\":\"2.0\",\"id\":" ++ id ++ suffix);
        var event = server.takeEvent().?;
        defer event.deinit();
        try std.testing.expectEqualStrings(id, event.call.request.id.?.number_string);
    }
    const first = server.handleForId(.{ .number_string = "9007199254740993" }).?;
    const second = server.handleForId(.{ .number_string = "9007199254740992" }).?;
    try std.testing.expect(first.value != second.value);
    const fraction = server.handleForId(.{ .number_string = "15e-1" }).?;
    try server.sendResult(fraction, .{ .object = .empty });
    var tx = server.takeTransmit().?;
    defer tx.deinit();
    var doc = try std.json.parseFromSlice(Value, a, tx.bytes, .{ .parse_numbers = false });
    defer doc.deinit();
    try std.testing.expectEqualStrings("1.5", get(doc.value, "id").?.number_string);
    try std.testing.expectEqual(2, server.pendingCallCount());
}
