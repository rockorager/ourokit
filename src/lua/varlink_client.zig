const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const varlink = @import("../varlink/root.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

const receive_capacity = 64 * 1024;
const max_value_depth = 32;
const max_value_count = 4096;
var json_null: u8 = 0;

const State = enum { free, connecting, sending, receiving, ready };

const Slot = struct {
    owner: *VarlinkClient = undefined,
    state: State = .free,
    fd: linux.fd_t = -1,
    protocol: varlink.Client = undefined,
    protocol_initialized: bool = false,
    transmit: ?varlink.Transmit = null,
    reply: ?varlink.Reply = null,
    operation: ?io.OperationHandle = null,
    operation_terminal: bool = false,
    task_handle: vm_module.TaskHandle = .invalid,
    failure: ?[]const u8 = null,
    cancellation_requested: bool = false,
    receive_buffer: [receive_capacity]u8 = undefined,
};

/// VM-generation-owned asynchronous Varlink adapter. Lua only declares calls;
/// this adapter owns Unix sockets, protocol buffers, ring operations, and the
/// scheduler resource that ties each call to its coroutine scope.
pub const VarlinkClient = struct {
    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    loop: *io.Loop,
    slots: []Slot,

    pub fn init(
        self: *VarlinkClient,
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
        c.lua_pushlightuserdata(vm.state, &json_null);
        c.lua_setfield(vm.state, -2, "null");
        c.lua_setfield(vm.state, -2, "varlink");
        c.lua_settop(vm.state, -2);
    }

    pub fn deinit(self: *VarlinkClient) void {
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Routes one socket CQE without entering Lua. Completion only publishes
    /// the reply or failure and marks the owning task runnable.
    pub fn dispatch(self: *VarlinkClient, completion: io.SocketCompletion) !bool {
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
                try self.finish(slot, "Varlink transport operation failed");
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
                        try self.finish(slot, "Varlink connection closed while sending");
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
                        try self.finish(slot, "Varlink connection closed before a reply");
                        return true;
                    }
                    const received: usize = @intCast(completion.result);
                    var consumed: usize = 0;
                    while (consumed < received) {
                        const count = slot.protocol.feed(slot.receive_buffer[consumed..received]) catch {
                            try self.finish(slot, "invalid Varlink reply");
                            return true;
                        };
                        consumed += count;
                        if (slot.protocol.takeEvent()) |event_value| {
                            var event = event_value;
                            switch (event) {
                                .reply => |*reply| {
                                    slot.reply = reply.message;
                                    reply.message = undefined;
                                    event = undefined;
                                },
                            }
                            try self.finish(slot, null);
                            return true;
                        }
                        if (count == 0) {
                            try self.finish(slot, "Varlink reply exceeded event capacity");
                            return true;
                        }
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
    pub fn collectCanceled(self: *VarlinkClient) !void {
        for (self.slots) |*slot| if (slot.cancellation_requested)
            try self.collectCanceledSlot(slot);
    }

    fn collectCanceledSlot(self: *VarlinkClient, slot: *Slot) !void {
        const operation = slot.operation orelse return;
        if (!slot.operation_terminal or self.loop.operationPending(operation)) return;
        slot.operation = null;
        slot.operation_terminal = false;
        try self.vm.markExternalCompleted(slot.task_handle);
        self.release(slot);
    }

    fn prepareNext(self: *VarlinkClient, slot: *Slot) !void {
        slot.operation = switch (slot.state) {
            .sending => self.loop.prepareSend(slot.fd, slot.transmit.?.remaining()),
            .receiving => self.loop.prepareRecv(slot.fd, &slot.receive_buffer),
            else => return error.InvalidVarlinkClientState,
        } catch {
            try self.finish(slot, "could not prepare Varlink transport operation");
            return;
        };
    }

    fn finish(self: *VarlinkClient, slot: *Slot, failure: ?[]const u8) !void {
        slot.failure = failure;
        slot.state = .ready;
        if (slot.fd >= 0) {
            _ = linux.close(slot.fd);
            slot.fd = -1;
        }
        try self.vm.markExternalCompleted(slot.task_handle);
    }

    fn available(self: *VarlinkClient) ?*Slot {
        for (self.slots) |*slot| if (slot.state == .free) return slot;
        return null;
    }

    fn release(self: *VarlinkClient, slot: *Slot) void {
        if (slot.fd >= 0) _ = linux.close(slot.fd);
        if (slot.reply) |*reply| reply.deinit();
        if (slot.transmit) |*transmit| transmit.deinit();
        if (slot.protocol_initialized) slot.protocol.deinit();
        slot.* = .{ .owner = self };
    }

    fn call(state: *c.State) callconv(.c) c_int {
        const self = clientFromUpvalue(state) orelse
            return luaError(state, "missing Ouro Varlink client");
        const argument_count = c.lua_gettop(state);
        if ((argument_count != 2 and argument_count != 3) or
            c.lua_type(state, 1) != c.type_string or c.lua_type(state, 2) != c.type_string or
            (argument_count == 3 and c.lua_type(state, 3) != c.type_table))
            return luaError(state, "ouro.varlink.call expects address, method, and optional parameters table");

        var address_length: usize = 0;
        const address_pointer = c.lua_tolstring(state, 1, &address_length).?;
        const parsed_address = varlink.Address.parse(address_pointer[0..address_length]) catch
            return luaError(state, "invalid Varlink address");
        const unix_address = switch (parsed_address) {
            .unix => |address| address,
            else => return luaError(state, "ouro.varlink currently supports only unix: addresses"),
        };
        var socket_address: linux.sockaddr.un = .{ .path = undefined };
        @memset(&socket_address.path, 0);
        const prefix: usize = if (unix_address.abstract) 1 else 0;
        const terminator: usize = @intFromBool(!unix_address.abstract);
        if (unix_address.name.len + prefix + terminator > socket_address.path.len)
            return luaError(state, "Varlink Unix address is too long");
        @memcpy(socket_address.path[prefix..][0..unix_address.name.len], unix_address.name);
        const socket_address_len: linux.socklen_t = @intCast(
            @offsetOf(linux.sockaddr.un, "path") + prefix + unix_address.name.len + terminator,
        );

        var method_length: usize = 0;
        const method_pointer = c.lua_tolstring(state, 2, &method_length).?;
        const slot = self.available() orelse return luaError(state, "Varlink call capacity exceeded");
        slot.protocol = varlink.Client.init(self.allocator, .{
            .max_message_bytes = receive_capacity,
            .max_outbound_message_bytes = receive_capacity,
            .max_pending_calls = 1,
            .max_events = 1,
            .max_transmits = 1,
        }) catch return luaError(state, "could not allocate Varlink call");
        slot.protocol_initialized = true;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        var value_count: usize = 0;
        const parameters: ?std.json.Value = if (argument_count == 3)
            luaToJson(state, 3, arena.allocator(), 0, &value_count) catch {
                arena.deinit();
                self.release(slot);
                return luaError(state, "Varlink parameters must be a finite JSON object");
            }
        else
            null;
        _ = slot.protocol.call(.{
            .method = method_pointer[0..method_length],
            .parameters = parameters,
        }) catch {
            arena.deinit();
            self.release(slot);
            return luaError(state, "invalid Varlink call");
        };
        arena.deinit();
        slot.transmit = slot.protocol.takeTransmit().?;

        const socket_result = linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            0,
        );
        if (linux.errno(socket_result) != .SUCCESS) {
            self.release(slot);
            return luaError(state, "could not create Varlink Unix socket");
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
            return luaError(state, "could not park Varlink call");
        };
        slot.operation = self.loop.prepareUnixConnect(
            slot.fd,
            &socket_address,
            socket_address_len,
        ) catch {
            self.vm.abortExternalWait(state, slot.task_handle) catch unreachable;
            self.release(slot);
            return luaError(state, "could not prepare Varlink connection");
        };
        return c.lua_yieldk(state, 0, contextFor(slot), callContinuation);
    }

    fn callContinuation(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
        const slot = slotFromContext(context);
        if (slot.failure) |failure| {
            slot.owner.release(slot);
            return luaErrorSlice(state, failure);
        }
        const reply = &(slot.reply orelse {
            slot.owner.release(slot);
            return luaError(state, "Varlink call completed without a reply");
        });
        c.lua_createtable(state, 0, 2);
        if (reply.parameters) |parameters| {
            pushJson(state, parameters) catch {
                slot.owner.release(slot);
                return luaError(state, "Varlink reply could not be represented in Lua");
            };
            c.lua_setfield(state, -2, "parameters");
        }
        if (reply.error_name) |name| {
            _ = c.lua_pushlstring(state, name.ptr, name.len);
            c.lua_setfield(state, -2, "error");
        }
        slot.owner.release(slot);
        return 1;
    }
};

fn luaToJson(
    state: *c.State,
    index: c_int,
    allocator: std.mem.Allocator,
    depth: usize,
    value_count: *usize,
) anyerror!std.json.Value {
    if (depth >= max_value_depth or value_count.* >= max_value_count)
        return error.ValueLimitExceeded;
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
            break :blk .{ .string = string[0..length] };
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
    if (array_length != 0) {
        var array = std.json.Array.init(allocator);
        try array.ensureTotalCapacity(array_length);
        for (1..array_length + 1) |item_index| {
            _ = c.lua_rawgeti(state, absolute_index, @intCast(item_index));
            defer c.lua_settop(state, -2);
            try array.append(try luaToJson(state, -1, allocator, depth + 1, value_count));
        }
        c.lua_pushnil(state);
        var count: usize = 0;
        while (c.lua_next(state, absolute_index) != 0) {
            count += 1;
            c.lua_settop(state, -2);
        }
        if (count != array_length) return error.MixedTable;
        return .{ .array = array };
    }

    var object = std.json.ObjectMap.empty;
    c.lua_pushnil(state);
    while (c.lua_next(state, absolute_index) != 0) {
        defer c.lua_settop(state, -2);
        if (c.lua_type(state, -2) != c.type_string) return error.NonStringObjectKey;
        var key_length: usize = 0;
        const key = c.lua_tolstring(state, -2, &key_length).?;
        try object.put(allocator, key[0..key_length], try luaToJson(
            state,
            -1,
            allocator,
            depth + 1,
            value_count,
        ));
    }
    return .{ .object = object };
}

fn pushJson(state: *c.State, value: std.json.Value) !void {
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
            for (array.items, 1..) |item, index| {
                try pushJson(state, item);
                c.lua_rawseti(state, -2, @intCast(index));
            }
        },
        .object => |object| {
            c.lua_createtable(state, 0, @intCast(object.count()));
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                _ = c.lua_pushlstring(state, entry.key_ptr.*.ptr, entry.key_ptr.*.len);
                try pushJson(state, entry.value_ptr.*);
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

fn clientFromUpvalue(state: *c.State) ?*VarlinkClient {
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
            if (std.mem.indexOfScalar(u8, self.request[0..self.request_length], 0) != null) break;
        }
        const reply = "{\"parameters\":{\"answer\":42,\"nested\":[true,\"ok\",null]}}\x00";
        var written: usize = 0;
        while (written < reply.len) {
            const result = linux.write(accepted, reply[written..].ptr, reply.len - written);
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

test "Lua Varlink call uses runtime transport and converts JSON values" {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "ouro-lua-varlink-{d}", .{linux.getpid()});
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
    var client: VarlinkClient = undefined;
    try client.init(std.testing.allocator, &vm, &loop, 1);
    defer client.deinit();

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "local ouro = require('ouro'); " ++
            "local reply = ouro.varlink.call('unix:@{s}', 'org.example.Echo', " ++
            "{{ value = 7, list = {{ 1, true, ouro.varlink.null }} }}); " ++
            "varlink_ok = reply.error == nil and reply.parameters.answer == 42 " ++
            "and reply.parameters.nested[1] == true and reply.parameters.nested[2] == 'ok' " ++
            "and reply.parameters.nested[3] == ouro.varlink.null",
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
    try std.testing.expect(vm.globalBoolean("varlink_ok"));
    try std.testing.expect(server.succeeded);
    try std.testing.expect(std.mem.indexOf(
        u8,
        server.request[0..server.request_length],
        "\"method\":\"org.example.Echo\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        server.request[0..server.request_length],
        "\"value\":7",
    ) != null);
}

test "canceling a Lua Varlink call drains ring operations before releasing its slot" {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "ouro-lua-varlink-cancel-{d}", .{linux.getpid()});
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
    var client: VarlinkClient = undefined;
    try client.init(std.testing.allocator, &vm, &loop, 1);
    defer client.deinit();

    const scope = try scheduler.createScope(scheduler.application_scope);
    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        "local ouro = require('ouro'); canceled_call_continued = false; " ++
            "ouro.varlink.call('unix:@{s}', 'org.example.Wait'); " ++
            "canceled_call_continued = true",
        .{name},
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
