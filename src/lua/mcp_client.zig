const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const mcp = @import("../mcp/root.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

const receive_capacity = 64 * 1024;
const max_value_depth = 32;
const max_value_count = 4096;
var json_null: u8 = 0;

const State = enum { free, connecting, sending, receiving, ready };
const CallKind = enum { tool, request, subscription };

const Slot = struct {
    owner: *McpClient = undefined,
    state: State = .free,
    fd: linux.fd_t = -1,
    protocol: mcp.Client = undefined,
    protocol_initialized: bool = false,
    transmit: ?mcp.Transmit = null,
    event: ?mcp.ClientEvent = null,
    operation: ?io.OperationHandle = null,
    operation_terminal: bool = false,
    task_handle: vm_module.TaskHandle = .invalid,
    failure: ?[]const u8 = null,
    cancellation_requested: bool = false,
    streaming: bool = false,
    subscription: ?mcp.CallHandle = null,
    uri: ?[]u8 = null,
    acknowledged: bool = false,
    guard: ?*?*Slot = null,
    received: usize = 0,
    consumed: usize = 0,
    receive_buffer: [receive_capacity]u8 = undefined,
};

/// VM-generation-owned asynchronous MCP adapter. Lua only declares calls;
/// this adapter owns Unix sockets, protocol buffers, ring operations, and the
/// scheduler resource that ties each call to its coroutine scope.
pub const McpClient = struct {
    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    loop: *io.Loop,
    slots: []Slot,

    pub fn init(
        self: *McpClient,
        allocator: std.mem.Allocator,
        vm: *vm_module.Vm,
        loop: *io.Loop,
        capacity: usize,
    ) !void {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .vm = vm, .loop = loop, .slots = slots };
        for (self.slots) |*slot| slot.owner = self;

        vm.pushApi(vm.state);
        c.lua_createtable(vm.state, 0, 2);
        c.lua_pushlightuserdata(vm.state, self);
        c.lua_pushcclosure(vm.state, call, 1);
        c.lua_setfield(vm.state, -2, "call");
        c.lua_pushlightuserdata(vm.state, self);
        c.lua_pushcclosure(vm.state, request, 1);
        c.lua_setfield(vm.state, -2, "request");
        c.lua_pushlightuserdata(vm.state, self);
        c.lua_pushcclosure(vm.state, subscribe, 1);
        c.lua_setfield(vm.state, -2, "subscribe");
        c.lua_pushlightuserdata(vm.state, &json_null);
        c.lua_setfield(vm.state, -2, "null");
        c.lua_setfield(vm.state, -2, "mcp");
        c.lua_settop(vm.state, -2);
    }

    pub fn deinit(self: *McpClient) void {
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Routes one socket CQE without entering Lua. Completion only publishes
    /// the reply or failure and marks the owning task runnable.
    pub fn dispatch(self: *McpClient, completion: io.SocketCompletion) !bool {
        for (self.slots) |*slot| {
            const operation = slot.operation orelse continue;
            if (!same(operation, completion.operation)) continue;
            slot.operation_terminal = true;
            if (slot.cancellation_requested) {
                try self.collectCanceledSlot(slot);
                return true;
            }
            slot.operation = null;
            slot.operation_terminal = false;
            if (completion.result < 0) {
                try self.finish(slot, "MCP transport operation failed");
                return true;
            }
            switch (slot.state) {
                .connecting => {
                    if (completion.kind != .connect) return error.UnexpectedSocketCompletion;
                    slot.state = .sending;
                    try self.prepareNext(slot);
                },
                .sending => {
                    if (completion.kind != .send or completion.result == 0) {
                        try self.finish(slot, "MCP connection closed while sending");
                        return true;
                    }
                    var transmit = &(slot.transmit orelse return error.MissingSocketTransmit);
                    try transmit.consume(@intCast(completion.result));
                    if (transmit.complete()) {
                        transmit.deinit();
                        slot.transmit = null;
                        slot.state = .receiving;
                    }
                    try self.prepareNext(slot);
                },
                .receiving => {
                    if (completion.kind != .recv or completion.result == 0) {
                        try self.finish(slot, "MCP connection closed before a reply");
                        return true;
                    }
                    slot.received = @intCast(completion.result);
                    slot.consumed = 0;
                    const ready = readReply(slot) catch {
                        try self.finish(slot, "invalid MCP reply");
                        return true;
                    };
                    if (ready) {
                        try self.finish(slot, null);
                        return true;
                    }
                    try self.prepareNext(slot);
                },
                .free, .ready => return error.UnexpectedSocketCompletion,
            }
            return true;
        }
        return false;
    }

    /// Called after operation-cancel CQEs, and harmless at every task safe
    /// point. Storage is released only once both original and cancel CQEs are
    /// terminal, so the kernel never retains pointers into a reused slot.
    pub fn collectCanceled(self: *McpClient) !void {
        for (self.slots) |*slot| if (slot.cancellation_requested)
            try self.collectCanceledSlot(slot);
    }

    fn collectCanceledSlot(self: *McpClient, slot: *Slot) !void {
        const operation = slot.operation orelse return;
        if (!slot.operation_terminal or self.loop.operationPending(operation)) return;
        slot.operation = null;
        slot.operation_terminal = false;
        try self.vm.markExternalCompleted(slot.task_handle);
        self.release(slot);
    }

    fn prepareNext(self: *McpClient, slot: *Slot) !void {
        slot.operation = switch (slot.state) {
            .sending => self.loop.prepareSend(slot.fd, slot.transmit.?.remaining()),
            .receiving => self.loop.prepareRecv(slot.fd, &slot.receive_buffer),
            else => return error.InvalidMcpClientState,
        } catch {
            try self.finish(slot, "could not prepare MCP transport operation");
            return;
        };
    }

    fn finish(self: *McpClient, slot: *Slot, failure: ?[]const u8) !void {
        slot.failure = failure;
        slot.state = .ready;
        if (slot.fd >= 0 and (failure != null or !slot.streaming or slot.event.? == .reply)) {
            _ = linux.close(slot.fd);
            slot.fd = -1;
        }
        try self.vm.markExternalCompleted(slot.task_handle);
    }

    /// Stop at the first record. Coalesced later records stay in receive_buffer
    /// until the callback has finished, including across callback yields.
    fn readReply(slot: *Slot) !bool {
        while (slot.consumed < slot.received) {
            const remaining = slot.receive_buffer[slot.consumed..slot.received];
            const end = if (std.mem.indexOfScalar(u8, remaining, '\n')) |index| index + 1 else remaining.len;
            const count = try slot.protocol.feed(remaining[0..end]);
            if (count != end) return error.UnexpectedBackpressure;
            slot.consumed += count;
            if (slot.protocol.takeEvent()) |value| {
                var event = value;
                errdefer event.deinit();
                if (event == .notification) {
                    if (!slot.streaming) {
                        event.deinit();
                        continue;
                    }
                    try validateNotification(slot, event.notification.message);
                }
                slot.event = event;
                return true;
            }
        }
        return false;
    }

    fn available(self: *McpClient) ?*Slot {
        for (self.slots) |*slot| if (slot.state == .free) return slot;
        return null;
    }

    fn release(self: *McpClient, slot: *Slot) void {
        std.debug.assert(slot.operation == null);
        if (slot.guard) |guard| guard.* = null;
        if (slot.fd >= 0) _ = linux.close(slot.fd);
        if (slot.event) |*event| event.deinit();
        if (slot.transmit) |*transmit| transmit.deinit();
        if (slot.uri) |uri| self.allocator.free(uri);
        if (slot.protocol_initialized) slot.protocol.deinit();
        slot.* = .{ .owner = self };
    }

    fn call(state: *c.State) callconv(.c) c_int {
        return start(state, .tool);
    }

    fn request(state: *c.State) callconv(.c) c_int {
        return start(state, .request);
    }

    fn subscribe(state: *c.State) callconv(.c) c_int {
        return start(state, .subscription);
    }

    fn start(state: *c.State, kind: CallKind) c_int {
        const streaming = kind == .subscription;
        const self = clientFromUpvalue(state) orelse
            return luaError(state, "missing Ouro MCP client");
        const argument_count = c.lua_gettop(state);
        if (streaming and (argument_count != 3 or c.lua_type(state, 3) != c.type_function))
            return luaError(state, "ouro.mcp.subscribe expects address, resource URI, and callback");
        if ((!streaming and argument_count != 2 and argument_count != 3) or
            c.lua_type(state, 1) != c.type_string or c.lua_type(state, 2) != c.type_string or
            (!streaming and argument_count >= 3 and c.lua_type(state, 3) != c.type_table))
            return luaError(state, "MCP expects address, name, and a parameters table");

        // A C-stack to-be-closed guard covers errors, exit, and cancellation
        // even while a subscription callback is yielding on another resource.
        const guard: *?*Slot = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(?*Slot), 0).?));
        guard.* = null;
        _ = c.luaL_newmetatable(state, "ouro.mcp.guard");
        c.lua_pushcclosure(state, closeGuard, 0);
        c.lua_setfield(state, -2, "__close");
        _ = c.lua_setmetatable(state, -2);
        c.lua_toclose(state, -1);

        var address_length: usize = 0;
        const address_pointer = c.lua_tolstring(state, 1, &address_length).?;
        const parsed_address = mcp.Address.parse(address_pointer[0..address_length]) catch
            return luaError(state, "invalid MCP Unix address");
        const unix_address = parsed_address.unix;
        var socket_address: linux.sockaddr.un = .{ .path = undefined };
        @memset(&socket_address.path, 0);
        const prefix: usize = if (unix_address.abstract) 1 else 0;
        const terminator: usize = @intFromBool(!unix_address.abstract);
        if (unix_address.name.len + prefix + terminator > socket_address.path.len)
            return luaError(state, "MCP Unix address is too long");
        @memcpy(socket_address.path[prefix..][0..unix_address.name.len], unix_address.name);
        const socket_address_len: linux.socklen_t = @intCast(
            @offsetOf(linux.sockaddr.un, "path") + prefix + unix_address.name.len + terminator,
        );

        var method_length: usize = 0;
        const method_pointer = c.lua_tolstring(state, 2, &method_length).?;
        const slot = self.available() orelse return luaError(state, "MCP call capacity exceeded");
        slot.streaming = streaming;
        slot.guard = guard;
        guard.* = slot;
        slot.protocol = mcp.Client.init(self.allocator, .{
            .max_pending_calls = 1,
            .max_events = 1,
            .max_transmits = 1,
        }) catch {
            self.release(slot);
            return luaError(state, "could not allocate MCP call");
        };
        slot.protocol_initialized = true;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        var value_count: usize = 0;
        const parameters: ?std.json.Value = if (!streaming and argument_count >= 3)
            luaToJson(state, 3, arena.allocator(), 0, &value_count) catch {
                arena.deinit();
                self.release(slot);
                return luaError(state, "MCP parameters must be a finite JSON object");
            }
        else
            null;
        const name = method_pointer[0..method_length];
        const outgoing = prepareCall(arena.allocator(), name, parameters, kind) catch {
            arena.deinit();
            self.release(slot);
            return luaError(state, "could not encode MCP call");
        };
        const handle = slot.protocol.call(outgoing) catch {
            arena.deinit();
            self.release(slot);
            return luaError(state, "invalid MCP call");
        };
        if (streaming) {
            slot.subscription = handle;
            slot.uri = self.allocator.dupe(u8, name) catch {
                arena.deinit();
                self.release(slot);
                return luaError(state, "could not allocate MCP subscription URI");
            };
        }
        arena.deinit();
        slot.transmit = slot.protocol.takeTransmit().?;

        const socket_result = linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            0,
        );
        if (linux.errno(socket_result) != .SUCCESS) {
            self.release(slot);
            return luaError(state, "could not create MCP Unix socket");
        }
        slot.fd = @intCast(socket_result);
        slot.state = .connecting;
        slot.task_handle = self.vm.beginExternalWait(
            state,
            .operation,
            slot,
            &resource_lifecycle,
        ) catch {
            self.release(slot);
            return luaError(state, "could not park MCP call");
        };
        slot.operation = self.loop.prepareUnixConnect(
            slot.fd,
            &socket_address,
            socket_address_len,
        ) catch {
            self.vm.abortExternalWait(state, slot.task_handle) catch unreachable;
            self.release(slot);
            return luaError(state, "could not prepare MCP connection");
        };
        return c.lua_yieldk(state, 0, contextFor(slot), callContinuation);
    }

    fn callContinuation(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
        const slot = slotFromContext(context);
        if (slot.failure) |failure| {
            slot.owner.release(slot);
            return luaErrorSlice(state, failure);
        }
        if (slot.streaming) return runSubscription(state, context, null);
        const event = slot.event orelse {
            slot.owner.release(slot);
            return luaError(state, "MCP call completed without a reply");
        };
        pushEvent(state, event) catch {
            slot.owner.release(slot);
            return luaError(state, "MCP reply could not be represented in Lua");
        };
        slot.owner.release(slot);
        return 1;
    }

    fn subscriptionContinuation(state: *c.State, status: c_int, context: c.KContext) callconv(.c) c_int {
        return runSubscription(state, context, status);
    }

    fn runSubscription(state: *c.State, context: c.KContext, callback_status: ?c_int) c_int {
        const slot = slotFromContext(context);
        const self = slot.owner;
        var status = callback_status;
        while (true) {
            if (status) |result| {
                if (result != c.ok and result != c.yield) return c.lua_error(state);
                const stop = c.lua_type(state, -1) == c.type_boolean and c.lua_toboolean(state, -1) == 0;
                c.lua_settop(state, -2);
                const final = slot.event.? == .reply;
                slot.event.?.deinit();
                slot.event = null;
                if (stop or final) {
                    self.release(slot);
                    return 0;
                }
            }
            if (slot.event == null) {
                const ready = readReply(slot) catch return luaError(state, "invalid MCP reply");
                if (!ready) {
                    slot.state = .receiving;
                    slot.task_handle = self.vm.beginExternalWait(state, .operation, slot, &resource_lifecycle) catch
                        return luaError(state, "could not park MCP subscription");
                    slot.operation = self.loop.prepareRecv(slot.fd, &slot.receive_buffer) catch {
                        self.vm.abortExternalWait(state, slot.task_handle) catch unreachable;
                        return luaError(state, "could not prepare MCP subscription receive");
                    };
                    return c.lua_yieldk(state, 0, context, callContinuation);
                }
            }
            c.lua_pushvalue(state, 3);
            pushEvent(state, slot.event.?) catch return luaError(state, "MCP notification could not be represented in Lua");
            status = c.lua_pcallk(state, 1, 1, 0, context, subscriptionContinuation);
        }
    }

    fn closeGuard(state: *c.State) callconv(.c) c_int {
        const guard: *?*Slot = @ptrCast(@alignCast(c.lua_touserdata(state, 1).?));
        if (guard.*) |slot| slot.owner.release(slot);
        return 0;
    }
};

fn prepareCall(allocator: std.mem.Allocator, name: []const u8, parameters: ?std.json.Value, kind: CallKind) !mcp.OutgoingCall {
    if (kind == .request) return .{ .method = name, .params = parameters };
    var params = std.json.ObjectMap.empty;
    if (kind == .tool) {
        try params.put(allocator, "name", .{ .string = name });
        try params.put(allocator, "arguments", parameters orelse .{ .object = .empty });
        return .{ .method = "tools/call", .params = .{ .object = params } };
    }
    var uris = std.json.Array.init(allocator);
    try uris.append(.{ .string = name });
    var notifications = std.json.ObjectMap.empty;
    try notifications.put(allocator, "resourceSubscriptions", .{ .array = uris });
    try params.put(allocator, "notifications", .{ .object = notifications });
    return .{ .method = "subscriptions/listen", .params = .{ .object = params }, .subscription = true };
}

fn validateNotification(slot: *Slot, notification: mcp.Request) !void {
    const params = notification.params orelse return error.InvalidSubscriptionNotification;
    if (params != .object) return error.InvalidSubscriptionNotification;
    const meta = params.object.get("_meta") orelse return error.InvalidSubscriptionNotification;
    if (meta != .object) return error.InvalidSubscriptionNotification;
    const id = meta.object.get("io.modelcontextprotocol/subscriptionId") orelse return error.InvalidSubscriptionNotification;
    const number: u64 = switch (id) {
        .integer => |n| std.math.cast(u64, n) orelse return error.InvalidSubscriptionNotification,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch return error.InvalidSubscriptionNotification,
        else => return error.InvalidSubscriptionNotification,
    };
    if (number != slot.subscription.?.value) return error.InvalidSubscriptionNotification;
    if (std.mem.eql(u8, notification.method, "notifications/subscriptions/acknowledged")) {
        if (slot.acknowledged) return error.InvalidSubscriptionNotification;
        const filter = params.object.get("notifications") orelse return error.InvalidSubscriptionNotification;
        if (filter != .object) return error.InvalidSubscriptionNotification;
        const uris = filter.object.get("resourceSubscriptions") orelse return error.InvalidSubscriptionNotification;
        if (uris != .array or uris.array.items.len != 1) return error.InvalidSubscriptionNotification;
        const uri = uris.array.items[0];
        if (uri != .string or !std.mem.eql(u8, uri.string, slot.uri.?)) return error.InvalidSubscriptionNotification;
        slot.acknowledged = true;
    } else if (std.mem.eql(u8, notification.method, "notifications/resources/updated")) {
        const uri = params.object.get("uri") orelse return error.InvalidSubscriptionNotification;
        if (!slot.acknowledged or uri != .string or !std.mem.eql(u8, uri.string, slot.uri.?)) return error.InvalidSubscriptionNotification;
    } else return error.InvalidSubscriptionNotification;
}

fn pushEvent(state: *c.State, event: mcp.ClientEvent) !void {
    c.lua_createtable(state, 0, 2);
    switch (event) {
        .reply => |reply| {
            if (reply.message.result) |result| {
                try pushJson(state, result);
                c.lua_setfield(state, -2, "result");
            }
            if (reply.message.rpc_error) |rpc_error| {
                try pushJson(state, rpc_error);
                c.lua_setfield(state, -2, "error");
            }
        },
        .notification => |notification| {
            _ = c.lua_pushlstring(state, notification.message.method.ptr, notification.message.method.len);
            c.lua_setfield(state, -2, "method");
            if (notification.message.params) |params| {
                try pushJson(state, params);
                c.lua_setfield(state, -2, "params");
            }
        },
    }
}

/// Converts a Lua value into arena-owned JSON, including strings and keys.
/// The caller restores the Lua stack on failure and releases the arena.
pub fn luaToJson(
    state: *c.State,
    index: c_int,
    allocator: std.mem.Allocator,
    depth: usize,
    value_count: *usize,
) anyerror!std.json.Value {
    if (depth >= max_value_depth or value_count.* >= max_value_count)
        return error.ValueLimitExceeded;
    if (c.lua_checkstack(state, 4) == 0) return error.LuaStackCapacityExceeded;
    value_count.* += 1;
    return switch (c.lua_type(state, index)) {
        c.type_nil => .null,
        c.type_boolean => .{ .bool = c.lua_toboolean(state, index) != 0 },
        c.type_light_userdata => if (c.lua_touserdata(state, index) ==
            @as(*anyopaque, @ptrCast(&json_null)))
            .null
        else
            error.UnsupportedValue,
        c.type_number => if (c.lua_isinteger(state, index) != 0) blk: {
            var is_integer: c_int = 0;
            const integer = c.lua_tointegerx(state, index, &is_integer);
            if (is_integer == 0) return error.InvalidNumber;
            break :blk .{ .integer = integer };
        } else blk: {
            var is_number: c_int = 0;
            const number = c.lua_tonumberx(state, index, &is_number);
            if (is_number == 0 or !std.math.isFinite(number)) return error.InvalidNumber;
            break :blk .{ .float = number };
        },
        c.type_string => blk: {
            var length: usize = 0;
            const string = c.lua_tolstring(state, index, &length).?;
            break :blk .{ .string = try allocator.dupe(u8, string[0..length]) };
        },
        c.type_table => try luaTableToJson(state, index, allocator, depth, value_count),
        else => error.UnsupportedValue,
    };
}

fn luaTableToJson(
    state: *c.State,
    index: c_int,
    allocator: std.mem.Allocator,
    depth: usize,
    value_count: *usize,
) anyerror!std.json.Value {
    const absolute_index = if (index < 0) c.lua_gettop(state) + index + 1 else index;
    const array_length = c.lua_rawlen(state, absolute_index);
    if (array_length != 0 or isJsonArray(state, absolute_index)) {
        try validateArray(state, absolute_index, array_length);
        var array = std.json.Array.init(allocator);
        try array.ensureTotalCapacity(array_length);
        for (1..array_length + 1) |item_index| {
            _ = c.lua_rawgeti(state, absolute_index, @intCast(item_index));
            defer c.lua_settop(state, -2);
            try array.append(try luaToJson(state, -1, allocator, depth + 1, value_count));
        }
        return .{ .array = array };
    }

    var object = std.json.ObjectMap.empty;
    c.lua_pushnil(state);
    while (c.lua_next(state, absolute_index) != 0) {
        defer c.lua_settop(state, -2);
        if (c.lua_type(state, -2) != c.type_string) return error.NonStringObjectKey;
        var key_length: usize = 0;
        const key = c.lua_tolstring(state, -2, &key_length).?;
        try object.put(allocator, try allocator.dupe(u8, key[0..key_length]), try luaToJson(
            state,
            -1,
            allocator,
            depth + 1,
            value_count,
        ));
    }
    return .{ .object = object };
}

const array_metatable = "ouro.json.array";

/// Marks a dense Lua sequence as a JSON array, preserving [] versus {} even
/// when empty. Validation also runs at encode time, since tables are mutable.
pub fn markJsonArray(state: *c.State, index: c_int) !void {
    if (c.lua_checkstack(state, 2) == 0) return error.LuaStackCapacityExceeded;
    const absolute_index = if (index < 0) c.lua_gettop(state) + index + 1 else index;
    try validateArray(state, absolute_index, c.lua_rawlen(state, absolute_index));
    _ = c.luaL_newmetatable(state, array_metatable);
    _ = c.lua_setmetatable(state, absolute_index);
}

fn isJsonArray(state: *c.State, index: c_int) bool {
    if (c.lua_getmetatable(state, index) == 0) return false;
    _ = c.luaL_newmetatable(state, array_metatable);
    const matches = c.lua_rawequal(state, -1, -2) != 0;
    c.lua_settop(state, -3);
    return matches;
}

fn validateArray(state: *c.State, index: c_int, length: usize) !void {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    c.lua_pushnil(state);
    var count: usize = 0;
    while (c.lua_next(state, index) != 0) {
        if (c.lua_isinteger(state, -2) == 0) return error.MixedTable;
        var valid: c_int = 0;
        const key = c.lua_tointegerx(state, -2, &valid);
        if (key <= 0 or key > length) return error.MixedTable;
        count += 1;
        c.lua_settop(state, -2);
    }
    if (count != length) return error.SparseArray;
}

pub fn pushJson(state: *c.State, value: std.json.Value) !void {
    var count: usize = 0;
    return pushJsonAt(state, value, 0, &count);
}

fn pushJsonAt(state: *c.State, value: std.json.Value, depth: usize, count: *usize) anyerror!void {
    if (depth >= max_value_depth or count.* >= max_value_count) return error.ValueLimitExceeded;
    count.* += 1;
    if (c.lua_checkstack(state, 4) == 0) return error.LuaStackCapacityExceeded;
    switch (value) {
        .null => c.lua_pushlightuserdata(state, &json_null),
        .bool => |boolean| c.lua_pushboolean(state, @intFromBool(boolean)),
        .integer => |integer| c.lua_pushinteger(state, integer),
        .float => |number| c.lua_pushnumber(state, number),
        .number_string => |text| {
            const integer = std.fmt.parseInt(i64, text, 10) catch {
                const number = try std.fmt.parseFloat(f64, text);
                if (!std.math.isFinite(number)) return error.InvalidNumber;
                c.lua_pushnumber(state, number);
                return;
            };
            c.lua_pushinteger(state, integer);
        },
        .string => |string| _ = c.lua_pushlstring(state, string.ptr, string.len),
        .array => |array| {
            c.lua_createtable(state, @intCast(array.items.len), 0);
            try markJsonArray(state, -1);
            for (array.items, 1..) |item, index| {
                try pushJsonAt(state, item, depth + 1, count);
                c.lua_rawseti(state, -2, @intCast(index));
            }
        },
        .object => |object| {
            c.lua_createtable(state, 0, @intCast(object.count()));
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                _ = c.lua_pushlstring(state, entry.key_ptr.*.ptr, entry.key_ptr.*.len);
                try pushJsonAt(state, entry.value_ptr.*, depth + 1, count);
                c.lua_settable(state, -3);
            }
        },
    }
}

fn requestCancel(pointer: *anyopaque) !void {
    const slot: *Slot = @ptrCast(@alignCast(pointer));
    slot.cancellation_requested = true;
    if (slot.operation) |operation| try slot.owner.loop.prepareCancel(operation);
}

fn destroyResource(_: *anyopaque) void {}

const resource_lifecycle: task.ResourceLifecycle = .{
    .request_cancel = requestCancel,
    .destroy = destroyResource,
};

fn clientFromUpvalue(state: *c.State) ?*McpClient {
    const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn contextFor(slot: *Slot) c.KContext {
    return @bitCast(@as(usize, @intFromPtr(slot)));
}

fn slotFromContext(context: c.KContext) *Slot {
    return @ptrFromInt(@as(usize, @bitCast(context)));
}

fn same(first: io.OperationHandle, second: io.OperationHandle) bool {
    return first.slot == second.slot and first.generation == second.generation;
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

fn luaErrorSlice(state: *c.State, message: []const u8) c_int {
    _ = c.lua_pushlstring(state, message.ptr, message.len);
    return c.lua_error(state);
}

const TestServer = struct {
    listener: linux.fd_t,
    reply: []const u8 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"isError\":false,\"structuredContent\":{\"answer\":42,\"nested\":[true,\"ok\",null],\"empty\":[]}}}\n",
    request: [512]u8 = undefined,
    request_length: usize = 0,
    succeeded: bool = false,

    fn run(self: *TestServer) void {
        const accepted_result = linux.accept(self.listener, null, null);
        if (linux.errno(accepted_result) != .SUCCESS) return;
        const accepted: linux.fd_t = @intCast(accepted_result);
        defer _ = linux.close(accepted);
        while (self.request_length < self.request.len) {
            const result = linux.read(
                accepted,
                self.request[self.request_length..].ptr,
                self.request.len - self.request_length,
            );
            if (linux.errno(result) != .SUCCESS or result == 0) return;
            self.request_length += result;
            if (std.mem.indexOfScalar(u8, self.request[0..self.request_length], '\n') != null) break;
        }
        var written: usize = 0;
        while (written < self.reply.len) {
            const result = linux.write(accepted, self.reply[written..].ptr, self.reply.len - written);
            if (linux.errno(result) != .SUCCESS or result == 0) return;
            written += result;
        }
        self.succeeded = true;
    }
};

fn testListener(name: []const u8) !linux.fd_t {
    var address: linux.sockaddr.un = .{ .path = undefined };
    @memset(&address.path, 0);
    @memcpy(address.path[1..][0..name.len], name);
    const address_len: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + 1 + name.len,
    );
    const result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    if (linux.errno(result) != .SUCCESS) return error.SocketCreationFailed;
    const listener: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(listener);
    if (linux.errno(linux.bind(listener, @ptrCast(&address), address_len)) != .SUCCESS)
        return error.SocketBindFailed;
    if (linux.errno(linux.listen(listener, 1)) != .SUCCESS) return error.SocketListenFailed;
    return listener;
}

test "Lua MCP tool call uses runtime transport and converts JSON values" {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "ouro-lua-mcp-{d}", .{linux.getpid()});
    const listener = try testListener(name);
    defer _ = linux.close(listener);
    var server: TestServer = .{ .listener = listener };
    const server_thread = try std.Thread.spawn(.{}, TestServer.run, .{&server});

    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 2);
    defer scheduler.deinit();
    var vm: vm_module.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var client: McpClient = undefined;
    try client.init(std.testing.allocator, &vm, &loop, 1);
    defer client.deinit();

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "local ouro = require('ouro'); " ++
            "local reply = ouro.mcp.call('unix:@{s}', 'echo', " ++
            "{{ value = 7, list = {{ 1, true, ouro.mcp.null }}, empty = ouro.json.array() }}); " ++
            "local result = reply.result.structuredContent; " ++
            "mcp_ok = reply.error == nil and reply.result.isError == false and result.answer == 42 " ++
            "and result.nested[1] == true and result.nested[2] == 'ok' " ++
            "and result.nested[3] == ouro.mcp.null " ++
            "and ouro.json.encode(result.empty) == '[]'",
        .{name},
    );
    defer std.testing.allocator.free(source);
    _ = try vm.spawnApplication(source);
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
    while (vm.activeTaskCount() != 0) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .socket => |completion| try std.testing.expect(try client.dispatch(completion)),
            else => return error.UnexpectedCompletion,
        }
        if (scheduler.takeRunnable()) |runnable| _ = try vm.resumeRunnable(runnable);
    }
    server_thread.join();
    try std.testing.expect(vm.globalBoolean("mcp_ok"));
    try std.testing.expect(server.succeeded);
    try std.testing.expect(std.mem.indexOf(
        u8,
        server.request[0..server.request_length],
        "\"method\":\"tools/call\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        server.request[0..server.request_length],
        "\"value\":7",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        server.request[0..server.request_length],
        "\"empty\":[]",
    ) != null);
}

test "canceling a Lua MCP call drains ring operations before releasing its slot" {
    try testCancelReceive(false);
}

test "canceling a Lua MCP subscription drains its pending receive" {
    try testCancelReceive(true);
}

fn testCancelReceive(streaming: bool) !void {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "ouro-lua-mcp-cancel-{d}", .{linux.getpid()});
    const listener = try testListener(name);
    defer _ = linux.close(listener);

    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 1, 2);
    defer scheduler.deinit();
    var vm: vm_module.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var client: McpClient = undefined;
    try client.init(std.testing.allocator, &vm, &loop, 1);
    defer client.deinit();

    const scope = try scheduler.createScope(scheduler.application_scope);
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "local ouro = require('ouro'); canceled_call_continued = false; " ++
            "ouro.mcp.{s}('unix:@{s}', 'ouro://test'{s}); " ++
            "canceled_call_continued = true",
        .{ if (streaming) "subscribe" else "call", name, if (streaming) ", function() canceled_call_continued = true end" else "" },
    );
    defer std.testing.allocator.free(source);
    _ = try vm.spawn(scope, source);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);

    // Advance through connect and send so cancellation exercises an in-flight receive.
    for (0..2) |_| {
        _ = try loop.submit();
        const completion = loop.dispatch(try loop.wait()).socket;
        try std.testing.expect(try client.dispatch(completion));
    }
    try scheduler.queueScopeCancellation(scope);
    try scheduler.applyQueuedCancellations();
    if (scheduler.takeRunnable()) |runnable|
        try std.testing.expectEqual(vm_module.ResumeResult.waiting, try vm.resumeRunnable(runnable));
    while (loop.hasPendingOperations()) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .socket => |completion| try std.testing.expect(try client.dispatch(completion)),
            .operation_cancel => try client.collectCanceled(),
            else => return error.UnexpectedCompletion,
        }
    }
    try client.collectCanceled();
    try std.testing.expectEqual(vm_module.ResumeResult.canceled, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(!vm.globalBoolean("canceled_call_continued"));
    try scheduler.destroyScope(scope);
}

const acknowledged_reply = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"notifications\":{\"resourceSubscriptions\":[\"ouro://test\"]}}}\n";
const updated_reply = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"uri\":\"ouro://test\"}}\n";
const final_reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"}}\n";

test "Lua MCP subscription delivers acknowledgments and updates across yielding callbacks" {
    try testSubscription(acknowledged_reply ++ updated_reply ++ final_reply,
        \\local values = {}
        \\watch(function(reply)
        \\  ouro.sleep(1)
        \\  values[#values + 1] = reply.method or reply.result.resultType
        \\  if reply.method == 'notifications/resources/updated' then assert(reply.params.uri == 'ouro://test') end
        \\end)
        \\subscription_ok = #values == 3 and values[1] == 'notifications/subscriptions/acknowledged'
        \\  and values[2] == 'notifications/resources/updated' and values[3] == 'complete'
    , .none);
}

test "Lua MCP subscription stops before buffered notifications and propagates callback errors" {
    try testSubscription(acknowledged_reply ++ updated_reply ++ final_reply,
        \\local count = 0
        \\watch(function(reply)
        \\  count = count + 1
        \\  assert(reply.method == 'notifications/subscriptions/acknowledged')
        \\  return false
        \\end)
        \\subscription_ok = count == 1
    , .none);
    try testSubscription(acknowledged_reply ++ final_reply,
        \\local ok, err = pcall(watch, function()
        \\  ouro.sleep(1)
        \\  error('callback failed')
        \\end)
        \\subscription_ok = not ok and string.find(err, 'callback failed') ~= nil
    , .none);
}

test "Lua MCP subscription exposes terminal RPC errors and rejects broken streams" {
    try testSubscription(acknowledged_reply ++ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"denied\"}}\n",
        \\local count = 0
        \\watch(function(reply)
        \\  count = count + 1
        \\  if count == 2 then
        \\    assert(reply.error.code == -32602 and reply.error.message == 'denied')
        \\    assert(reply.method == nil)
        \\  end
        \\end)
        \\subscription_ok = count == 2
    , .none);
    for ([_][]const u8{ acknowledged_reply, acknowledged_reply ++ "{", acknowledged_reply ++ "invalid\n" }) |replies| {
        try testSubscription(replies,
            \\local count = 0
            \\local ok = pcall(watch, function() count = count + 1 end)
            \\subscription_ok = not ok and count == 1
        , .none);
    }
}

test "Lua MCP subscription validates acknowledgment ordering, URI, and subscription ID" {
    for ([_][]const u8{
        updated_reply,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":2},\"notifications\":{\"resourceSubscriptions\":[\"ouro://test\"]}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"notifications\":{\"resourceSubscriptions\":[\"ouro://other\"]}}}\n",
    }) |wire| {
        try testSubscription(wire,
            \\local count = 0
            \\local ok = pcall(watch, function() count = count + 1 end)
            \\subscription_ok = not ok and count == 0
        , .none);
    }
    try testSubscription(acknowledged_reply ++ acknowledged_reply,
        \\local count = 0
        \\local ok = pcall(watch, function() count = count + 1 end)
        \\subscription_ok = not ok and count == 1
    , .none);
}

test "Lua MCP subscription cancellation closes ready notifications and yielding callbacks" {
    try testSubscription(acknowledged_reply,
        \\watch(function() subscription_ran = true end)
    , .ready);
    try testSubscription(acknowledged_reply ++ final_reply,
        \\watch(function()
        \\  ouro.sleep(60)
        \\  subscription_ran = true
        \\end)
    , .callback);
}

fn testSubscription(replies: []const u8, body: []const u8, cancel: enum { none, ready, callback }) !void {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "ouro-lua-subscription-{d}", .{linux.getpid()});
    const listener = try testListener(name);
    defer _ = linux.close(listener);
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 2);
    defer scheduler.deinit();
    var vm: vm_module.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var client: McpClient = undefined;
    try client.init(std.testing.allocator, &vm, &loop, 1);
    defer client.deinit();
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "local ouro = require('ouro'); " ++
            "local function watch(callback) ouro.mcp.subscribe('unix:@{s}', " ++
            "'ouro://test', callback) end; {s}",
        .{ name, body },
    );
    defer std.testing.allocator.free(source);
    _ = try vm.spawnApplication(source);
    try std.testing.expectEqual(vm_module.ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));

    // Complete connect and send, then queue all replies before submitting recv.
    // This exercises coalesced records rather than relying on thread timing.
    for (0..2) |_| {
        _ = try loop.submit();
        try std.testing.expect(try client.dispatch(loop.dispatch(try loop.wait()).socket));
    }
    var server: TestServer = .{ .listener = listener, .reply = replies };
    TestServer.run(&server);
    try std.testing.expect(server.succeeded);
    const request = server.request[0 .. server.request_length - 1];
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("subscriptions/listen", parsed.value.object.get("method").?.string);
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("ouro://test", params.get("notifications").?.object.get("resourceSubscriptions").?.array.items[0].string);
    try std.testing.expectEqualStrings("2026-07-28", params.get("_meta").?.object.get("io.modelcontextprotocol/protocolVersion").?.string);

    var canceled = false;
    while (vm.activeTaskCount() != 0) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .socket => |completion| try std.testing.expect(try client.dispatch(completion)),
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout|
                try vm.markTimeoutCompleted(timeout.operation),
            .operation_cancel => try client.collectCanceled(),
            else => return error.UnexpectedCompletion,
        }
        if (cancel == .ready and !canceled) {
            try vm.requestCancellation();
            canceled = true;
        }
        while (scheduler.takeRunnable()) |runnable| {
            _ = try vm.resumeRunnable(runnable);
            if (cancel == .callback and !canceled) {
                try vm.requestCancellation();
                canceled = true;
            }
        }
    }
    try std.testing.expect(client.available() != null);
    try std.testing.expect(!loop.hasPendingOperations());
    while (loop.hasPendingTimerKernelWork()) {
        _ = try loop.submit();
        _ = loop.dispatch(try loop.wait());
    }
    if (cancel == .none) {
        try std.testing.expect(vm.globalBoolean("subscription_ok"));
    } else {
        try std.testing.expect(canceled);
        try std.testing.expect(!vm.globalBoolean("subscription_ran"));
    }
}

test "Lua MCP subscription decoder retains fragmented and coalesced records" {
    var slot: Slot = .{ .streaming = true, .uri = try std.testing.allocator.dupe(u8, "ouro://test") };
    defer std.testing.allocator.free(slot.uri.?);
    slot.protocol = try mcp.Client.init(std.testing.allocator, .{ .max_events = 1 });
    defer slot.protocol.deinit();
    slot.subscription = try slot.protocol.call(.{ .method = "subscriptions/listen", .subscription = true });
    const split = acknowledged_reply.len - 4;
    @memcpy(slot.receive_buffer[0..split], acknowledged_reply[0..split]);
    slot.received = split;
    try std.testing.expect(!try McpClient.readReply(&slot));
    const rest = acknowledged_reply[split..] ++ updated_reply;
    @memcpy(slot.receive_buffer[0..rest.len], rest);
    slot.received = rest.len;
    slot.consumed = 0;
    for ([_][]const u8{ "notifications/subscriptions/acknowledged", "notifications/resources/updated" }) |expected| {
        try std.testing.expect(try McpClient.readReply(&slot));
        try std.testing.expectEqualStrings(expected, slot.event.?.notification.message.method);
        slot.event.?.deinit();
        slot.event = null;
    }
    try std.testing.expectEqual(slot.received, slot.consumed);
    try std.testing.expect(!try McpClient.readReply(&slot));
}

test "Lua MCP JSON conversion bounds incoming nesting and value count" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var array = std.json.Array.init(arena.allocator());
    try array.appendNTimes(.{ .integer = 19 }, 4095);
    try pushJson(state, .{ .array = array });
    try std.testing.expectEqual(@as(usize, 4095), c.lua_rawlen(state, -1));
    c.lua_settop(state, 0);
    try array.append(.{ .integer = 7 });
    try std.testing.expectError(error.ValueLimitExceeded, pushJson(state, .{ .array = array }));
    c.lua_settop(state, 0);
    var nested: std.json.Value = .{ .bool = true };
    for (0..31) |_| {
        var wrapper = std.json.Array.init(arena.allocator());
        try wrapper.append(nested);
        nested = .{ .array = wrapper };
    }
    try pushJson(state, nested);
    c.lua_settop(state, 0);
    var wrapper = std.json.Array.init(arena.allocator());
    try wrapper.append(nested);
    try std.testing.expectError(error.ValueLimitExceeded, pushJson(state, .{ .array = wrapper }));
}
