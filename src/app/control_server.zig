const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const varlink = @import("../varlink/root.zig");
const ReloadRequests = @import("reload_requests.zig").ReloadRequests;

pub const interface_name = "dev.ourokit.runtime";
pub const reload_method = interface_name ++ ".Reload";
pub const status_method = interface_name ++ ".Status";

pub const interface_description =
    \\interface dev.ourokit.runtime
    \\type Diagnostic (phase: string, source: string, message: string)
    \\method Reload() -> (generation: int)
    \\method Status() -> (applicationId: string, activeGeneration: int, reloading: bool, diagnostic: ?Diagnostic)
    \\error ReloadFailed(phase: string, source: string, message: string)
;

const client_capacity = 8;
const receive_capacity = 64 * 1024;

const Waiter = struct {
    sequence: u64,
    call: varlink.CallHandle,
};

const Failure = struct {
    phase: []u8,
    source: []u8,
    message: []u8,

    fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.source);
        allocator.free(self.phase);
        self.* = undefined;
    }
};

const Client = struct {
    fd: linux.fd_t,
    protocol: varlink.Server,
    waiters: std.array_list.Managed(Waiter),
    operation: ?io_loop.OperationHandle = null,
    operation_terminal: bool = false,
    transmit: ?varlink.Transmit = null,
    received: usize = 0,
    consumed: usize = 0,
    receive_buffer: [receive_capacity]u8 = undefined,

    fn init(allocator: std.mem.Allocator, fd: linux.fd_t) !Client {
        var protocol = try varlink.Server.init(allocator, .{});
        errdefer protocol.deinit();
        return .{
            .fd = fd,
            .protocol = protocol,
            .waiters = try std.array_list.Managed(Waiter).initCapacity(allocator, 32),
        };
    }

    fn deinit(self: *Client) void {
        if (self.transmit) |*transmit| transmit.deinit();
        self.waiters.deinit();
        self.protocol.deinit();
        _ = linux.close(self.fd);
        self.* = undefined;
    }
};

/// Process-lifetime Varlink transport and built-in runtime control interface.
/// It shares Ourokit's io_uring but owns a disjoint operation namespace, so
/// socket completions can be routed without exposing Wayring's reactor tags.
pub const ControlServer = struct {
    allocator: std.mem.Allocator,
    loop: *io_loop.Loop,
    requests: *ReloadRequests,
    service: varlink.Service,
    application_id: []u8,
    path: [:0]u8,
    listener: linux.fd_t,
    listener_operation: ?io_loop.OperationHandle = null,
    listener_terminal: bool = false,
    clients: [client_capacity]?Client = [_]?Client{null} ** client_capacity,
    generation: u64,
    reloading: bool = false,
    failure: ?Failure = null,
    shutting_down: bool = false,

    pub fn init(
        self: *ControlServer,
        allocator: std.mem.Allocator,
        loop: *io_loop.Loop,
        environ: std.process.Environ,
        application_id: []const u8,
        generation: u64,
        requests: *ReloadRequests,
    ) !void {
        const runtime_directory = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR") orelse
            return error.MissingRuntimeDirectory;
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "{s}/ouro-{d}.varlink",
            .{ runtime_directory, linux.getpid() },
            0,
        );
        errdefer allocator.free(path);
        const owned_id = try allocator.dupe(u8, application_id);
        errdefer allocator.free(owned_id);
        var service = try varlink.Service.init(allocator, .{
            .vendor = "Ourokit",
            .product = "Ourokit application runtime",
            .version = "0.1.0",
            .url = "https://github.com/rockorager/ourokit",
        }, 2);
        errdefer service.deinit();
        try service.addInterface(interface_description);
        // The name is PID-scoped, so an existing node can only be debris from
        // a crashed process whose PID has since been reused.
        wayring.unix_socket.unlink(path) catch |err| switch (err) {
            error.NotFound => {},
            else => return err,
        };
        const listener = try wayring.unix_socket.listen(path, 16);
        errdefer {
            _ = linux.close(listener);
            wayring.unix_socket.unlink(path) catch {};
        }
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .requests = requests,
            .service = service,
            .application_id = owned_id,
            .path = path,
            .listener = listener,
            .generation = generation,
        };
        self.listener_operation = try loop.prepareAccept(listener);
    }

    pub fn deinit(self: *ControlServer) void {
        std.debug.assert(self.shutting_down and self.quiescent());
        self.collectClosed();
        for (&self.clients) |*entry| std.debug.assert(entry.* == null);
        if (self.listener >= 0) _ = linux.close(self.listener);
        wayring.unix_socket.unlink(self.path) catch {};
        if (self.failure) |*failure| failure.deinit(self.allocator);
        self.service.deinit();
        self.allocator.free(self.path);
        self.allocator.free(self.application_id);
        self.* = undefined;
    }

    pub fn socketPath(self: *const ControlServer) []const u8 {
        return self.path;
    }

    pub fn setReloading(self: *ControlServer, reloading: bool) void {
        self.reloading = reloading;
    }

    pub fn reloadSucceeded(self: *ControlServer, sequence: u64, generation: u64) !void {
        self.generation = generation;
        self.reloading = false;
        self.clearFailure();
        for (&self.clients) |*entry| if (entry.*) |*client| {
            var index: usize = 0;
            while (index < client.waiters.items.len) {
                const waiter = client.waiters.items[index];
                if (waiter.sequence > sequence) {
                    index += 1;
                    continue;
                }
                if (!self.shutting_down) try sendGeneration(client, waiter.call, generation);
                _ = client.waiters.orderedRemove(index);
            }
            if (!self.shutting_down) try self.pumpClient(client);
        };
    }

    pub fn reloadFailed(
        self: *ControlServer,
        sequence: u64,
        diagnostic: ?*const lua.Diagnostic,
        err: anyerror,
    ) !void {
        self.reloading = false;
        try self.replaceFailure(diagnostic, err);
        const failure = &self.failure.?;
        for (&self.clients) |*entry| if (entry.*) |*client| {
            var index: usize = 0;
            while (index < client.waiters.items.len) {
                const waiter = client.waiters.items[index];
                if (waiter.sequence > sequence) {
                    index += 1;
                    continue;
                }
                if (!self.shutting_down) try sendReloadFailure(client, waiter.call, failure.*);
                _ = client.waiters.orderedRemove(index);
            }
            if (!self.shutting_down) try self.pumpClient(client);
        };
    }

    pub fn serviceRequests(self: *ControlServer) !void {
        if (self.shutting_down) return;
        for (&self.clients) |*entry| if (entry.*) |*client| try self.pumpClient(client);
    }

    pub fn dispatch(self: *ControlServer, completion: io_loop.SocketCompletion) !bool {
        if (self.listener_operation) |operation| if (same(operation, completion.operation)) {
            self.listener_terminal = true;
            if (completion.kind != .accept) return error.UnexpectedSocketCompletion;
            if (completion.result >= 0) {
                const fd: linux.fd_t = @intCast(completion.result);
                if (self.shutting_down) {
                    _ = linux.close(fd);
                } else {
                    try self.admit(fd);
                }
            } else if (!self.shutting_down) {
                return error.AcceptFailed;
            }
            if (!self.shutting_down) {
                self.listener_operation = try self.loop.prepareAccept(self.listener);
                self.listener_terminal = false;
            } else if (!self.loop.operationPending(completion.operation)) {
                self.listener_operation = null;
                _ = linux.close(self.listener);
                self.listener = -1;
            }
            return true;
        };

        for (&self.clients) |*entry| if (entry.*) |*client| {
            const operation = client.operation orelse continue;
            if (!same(operation, completion.operation)) continue;
            client.operation_terminal = true;
            if (self.shutting_down) {
                self.collectClosed();
                return true;
            }
            switch (completion.kind) {
                .recv => {
                    if (completion.result <= 0) {
                        client.deinit();
                        entry.* = null;
                        return true;
                    }
                    client.operation = null;
                    client.operation_terminal = false;
                    client.received = @intCast(completion.result);
                    client.consumed = 0;
                },
                .send => {
                    if (completion.result <= 0) {
                        client.deinit();
                        entry.* = null;
                        return true;
                    }
                    client.operation = null;
                    client.operation_terminal = false;
                    var transmit = &(client.transmit orelse
                        return error.MissingSocketTransmit);
                    try transmit.consume(@intCast(completion.result));
                    if (transmit.complete()) {
                        transmit.deinit();
                        client.transmit = null;
                    }
                },
                .accept, .connect => return error.UnexpectedSocketCompletion,
            }
            try self.pumpClient(client);
            return true;
        };
        return false;
    }

    pub fn beginShutdown(self: *ControlServer) !void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        if (self.listener_operation) |operation| try self.loop.prepareCancel(operation);
        for (&self.clients) |*entry| if (entry.*) |*client| {
            if (client.operation) |operation| {
                try self.loop.prepareCancel(operation);
            } else {
                client.deinit();
                entry.* = null;
            }
        };
    }

    pub fn collectClosed(self: *ControlServer) void {
        if (!self.shutting_down) return;
        if (self.listener_operation) |operation| {
            if (self.listener_terminal and !self.loop.operationPending(operation)) {
                self.listener_operation = null;
                if (self.listener >= 0) {
                    _ = linux.close(self.listener);
                    self.listener = -1;
                }
            }
        }
        for (&self.clients) |*entry| if (entry.*) |*client| {
            const operation = client.operation orelse continue;
            if (client.operation_terminal and !self.loop.operationPending(operation)) {
                client.operation = null;
                client.deinit();
                entry.* = null;
            }
        };
    }

    pub fn quiescent(self: *const ControlServer) bool {
        if (!self.shutting_down or self.listener_operation != null) return false;
        for (self.clients) |entry| if (entry != null) return false;
        return true;
    }

    fn admit(self: *ControlServer, fd: linux.fd_t) !void {
        errdefer _ = linux.close(fd);
        const credentials = try wayring.unix_socket.peerCredentials(fd);
        if (credentials.uid != linux.getuid()) {
            _ = linux.close(fd);
            return;
        }
        const entry = for (&self.clients) |*candidate| {
            if (candidate.* == null) break candidate;
        } else {
            _ = linux.close(fd);
            return;
        };
        entry.* = try Client.init(self.allocator, fd);
        try self.pumpClient(&entry.*.?);
    }

    fn pumpClient(self: *ControlServer, client: *Client) !void {
        if (client.operation != null or self.shutting_down) return;
        while (true) {
            while (client.protocol.takeEvent()) |event_value| {
                var event = event_value;
                defer event.deinit();
                switch (event) {
                    .call => |*call| try self.handleCall(client, call.handle, &call.request),
                }
            }
            if (client.consumed < client.received) {
                const consumed = try client.protocol.feed(
                    client.receive_buffer[client.consumed..client.received],
                );
                client.consumed += consumed;
                if (consumed != 0) continue;
            }
            if (client.transmit == null) client.transmit = client.protocol.takeTransmit();
            if (client.transmit) |*transmit| {
                client.operation = try self.loop.prepareSend(client.fd, transmit.remaining());
                return;
            }
            if (client.consumed != client.received) return;
            client.received = 0;
            client.consumed = 0;
            // Varlink replies are ordered and non-multiplexed. Do not leave a
            // receive occupying this client's sole operation slot while a
            // long-running Reload call is waiting for its terminal reply.
            if (client.waiters.items.len != 0) return;
            client.operation = try self.loop.prepareRecv(client.fd, &client.receive_buffer);
            return;
        }
    }

    fn handleCall(
        self: *ControlServer,
        client: *Client,
        call: varlink.CallHandle,
        request: *const varlink.Request,
    ) !void {
        if (try self.service.handle(&client.protocol, call, request)) return;
        if (request.upgrade or request.more) {
            if (!request.oneway) try sendFieldError(
                self.allocator,
                &client.protocol,
                call,
                "org.varlink.service.MethodNotImplemented",
                "method",
                request.method,
            );
            return;
        }
        switch (self.service.validateRequest(request)) {
            .valid => {},
            .interface_not_found => |name| {
                if (!request.oneway) try sendFieldError(
                    self.allocator,
                    &client.protocol,
                    call,
                    "org.varlink.service.InterfaceNotFound",
                    "interface",
                    name,
                );
                return;
            },
            .member_not_found => {
                if (!request.oneway) try sendFieldError(
                    self.allocator,
                    &client.protocol,
                    call,
                    "org.varlink.service.MethodNotFound",
                    "method",
                    request.method,
                );
                return;
            },
            .invalid_parameter => |name| {
                if (!request.oneway) try sendFieldError(
                    self.allocator,
                    &client.protocol,
                    call,
                    "org.varlink.service.InvalidParameter",
                    "parameter",
                    name,
                );
                return;
            },
        }

        if (std.mem.eql(u8, request.method, reload_method)) {
            const sequence = self.requests.request();
            self.reloading = true;
            if (!request.oneway) {
                if (client.waiters.items.len == client.waiters.capacity)
                    return error.ReloadWaiterCapacityExceeded;
                client.waiters.appendAssumeCapacity(.{ .sequence = sequence, .call = call });
            }
        } else if (std.mem.eql(u8, request.method, status_method)) {
            if (!request.oneway) try self.sendStatus(client, call);
        } else unreachable;
    }

    fn sendStatus(
        self: *ControlServer,
        client: *Client,
        call: varlink.CallHandle,
    ) !void {
        var parameters = std.json.ObjectMap.empty;
        defer parameters.deinit(self.allocator);
        try parameters.put(
            self.allocator,
            "applicationId",
            .{ .string = self.application_id },
        );
        try parameters.put(
            self.allocator,
            "activeGeneration",
            .{ .integer = @intCast(self.generation) },
        );
        try parameters.put(self.allocator, "reloading", .{ .bool = self.reloading });
        if (self.failure) |failure| {
            var diagnostic = std.json.ObjectMap.empty;
            defer diagnostic.deinit(self.allocator);
            try diagnostic.put(self.allocator, "phase", .{ .string = failure.phase });
            try diagnostic.put(self.allocator, "source", .{ .string = failure.source });
            try diagnostic.put(self.allocator, "message", .{ .string = failure.message });
            try parameters.put(self.allocator, "diagnostic", .{ .object = diagnostic });
            try client.protocol.sendReply(call, .{ .object = parameters });
        } else {
            try parameters.put(self.allocator, "diagnostic", .null);
            try client.protocol.sendReply(call, .{ .object = parameters });
        }
    }

    fn replaceFailure(
        self: *ControlServer,
        diagnostic: ?*const lua.Diagnostic,
        err: anyerror,
    ) !void {
        self.clearFailure();
        const phase = if (diagnostic) |value| @tagName(value.phase) else "source";
        const source = if (diagnostic) |value| value.source_name else self.application_id;
        const message = if (diagnostic) |value| value.message else @errorName(err);
        const owned_phase = try self.allocator.dupe(u8, phase);
        errdefer self.allocator.free(owned_phase);
        const owned_source = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(owned_source);
        self.failure = .{
            .phase = owned_phase,
            .source = owned_source,
            .message = try self.allocator.dupe(u8, message),
        };
    }

    fn clearFailure(self: *ControlServer) void {
        if (self.failure) |*failure| failure.deinit(self.allocator);
        self.failure = null;
    }
};

fn sendGeneration(client: *Client, call: varlink.CallHandle, generation: u64) !void {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(client.protocol.allocator);
    try parameters.put(
        client.protocol.allocator,
        "generation",
        .{ .integer = @intCast(generation) },
    );
    try client.protocol.sendReply(call, .{ .object = parameters });
}

fn sendReloadFailure(client: *Client, call: varlink.CallHandle, failure: Failure) !void {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(client.protocol.allocator);
    try parameters.put(client.protocol.allocator, "phase", .{ .string = failure.phase });
    try parameters.put(client.protocol.allocator, "source", .{ .string = failure.source });
    try parameters.put(client.protocol.allocator, "message", .{ .string = failure.message });
    try client.protocol.sendError(
        call,
        interface_name ++ ".ReloadFailed",
        .{ .object = parameters },
    );
}

fn sendFieldError(
    allocator: std.mem.Allocator,
    server: *varlink.Server,
    call: varlink.CallHandle,
    error_name: []const u8,
    field: []const u8,
    value: []const u8,
) !void {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(allocator);
    try parameters.put(allocator, field, .{ .string = value });
    try server.sendError(call, error_name, .{ .object = parameters });
}

fn same(first: io_loop.OperationHandle, second: io_loop.OperationHandle) bool {
    return first.slot == second.slot and first.generation == second.generation;
}

test "runtime interface is accepted by the Varlink schema parser" {
    var service = try varlink.Service.init(std.testing.allocator, .{
        .vendor = "test",
        .product = "test",
        .version = "1",
        .url = "https://example.invalid",
    }, 2);
    defer service.deinit();
    try service.addInterface(interface_description);
    try std.testing.expect(service.findInterface(interface_name) != null);
}

test "runtime server holds Reload reply until the generation commits" {
    var environment_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment_map.deinit();
    try environment_map.put("XDG_RUNTIME_DIR", "/tmp");
    const environment: std.process.Environ = .{
        .block = try environment_map.createPosixBlock(std.testing.allocator, .{}),
    };
    defer environment.block.deinit(std.testing.allocator);

    const expected_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/ouro-{d}.varlink",
        .{linux.getpid()},
    );
    defer std.testing.allocator.free(expected_path);
    wayring.unix_socket.unlink(expected_path) catch {};

    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var requests: ReloadRequests = .{};
    var control: ControlServer = undefined;
    try control.init(
        std.testing.allocator,
        &loop,
        environment,
        "dev.ourokit.test",
        1,
        &requests,
    );

    _ = try loop.submit();
    const client = try wayring.unix_socket.connect(control.socketPath());
    defer _ = linux.close(client);
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }

    _ = try loop.submit();
    const request = "{\"method\":\"dev.ourokit.runtime.Reload\"}\x00";
    try std.testing.expectEqual(request.len, linux.write(client, request, request.len));
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }
    try std.testing.expectEqual(@as(?u64, 1), requests.take());

    try control.reloadSucceeded(1, 2);
    _ = try loop.submit();
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }
    var reply: [256]u8 = undefined;
    const reply_len = linux.read(client, &reply, reply.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(reply_len));
    try std.testing.expect(std.mem.indexOf(u8, reply[0..reply_len], "\"generation\":2") != null);

    const status_request = "{\"method\":\"dev.ourokit.runtime.Status\"}\x00";
    try std.testing.expectEqual(
        status_request.len,
        linux.write(client, status_request, status_request.len),
    );
    _ = try loop.submit();
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }
    _ = try loop.submit();
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }
    const status_len = linux.read(client, &reply, reply.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(status_len));
    try std.testing.expect(std.mem.indexOf(
        u8,
        reply[0..status_len],
        "\"applicationId\":\"dev.ourokit.test\"",
    ) != null);

    try control.beginShutdown();
    while (!control.quiescent()) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
            .operation_cancel => control.collectClosed(),
            else => return error.UnexpectedCompletion,
        }
        control.collectClosed();
    }
    control.deinit();
}
