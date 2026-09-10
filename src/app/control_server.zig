const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const varlink = @import("../varlink/root.zig");
const task = @import("../task/root.zig");
const ReloadRequests = @import("reload_requests.zig").ReloadRequests;
pub const socket_activation = @import("socket_activation.zig");

pub const interface_name = "dev.ourokit.runtime";
pub const reload_method = interface_name ++ ".Reload";
pub const status_method = interface_name ++ ".Status";
pub const activate_method = interface_name ++ ".Activate";

pub const interface_description =
    \\interface dev.ourokit.runtime
    \\type Diagnostic (phase: string, source: string, message: string)
    \\method Reload() -> (generation: int)
    \\method Status() -> (applicationId: string, activeGeneration: int, reloading: bool, uiActive: bool, diagnostic: ?Diagnostic)
    \\method Activate(activationToken: ?string) -> ()
    \\error ActivateFailed(message: string)
    \\error ReloadFailed(phase: string, source: string, message: string)
    \\error ActionFailed(message: string)
;

const client_capacity = 8;
const receive_capacity = 64 * 1024;

const Waiter = struct {
    sequence: u64,
    call: varlink.CallHandle,
};

const Action = struct {
    vm: *lua.Vm,
    handle: lua.TaskHandle,
    scope: task.ScopeHandle,
    call: ?varlink.CallHandle,
    application: *const lua.Application,
    method: []u8,
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
    action: ?Action = null,
    activation: ?varlink.CallHandle = null,
    closing: bool = false,
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
        std.debug.assert(self.action == null);
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
    owned_path: ?socket_activation.PathIdentity = null,
    listener_operation: ?io_loop.OperationHandle = null,
    listener_terminal: bool = false,
    clients: [client_capacity]?Client = [_]?Client{null} ** client_capacity,
    generation: u64,
    reloading: bool = false,
    failure: ?Failure = null,
    shutting_down: bool = false,
    application: ?*const lua.Application = null,
    vm: ?*lua.Vm = null,
    ui_active: bool = false,
    activation_queued: bool = false,
    activating: bool = false,
    activation_token: ?[]u8 = null,

    pub fn init(
        self: *ControlServer,
        allocator: std.mem.Allocator,
        loop: *io_loop.Loop,
        environ: std.process.Environ,
        application_id: []const u8,
        generation: u64,
        requests: *ReloadRequests,
    ) !void {
        return self.initListener(allocator, loop, environ, application_id, generation, requests, try socket_activation.listener(environ));
    }

    /// Takes descriptor ownership on success, never pathname ownership.
    pub fn initWithListener(self: *ControlServer, allocator: std.mem.Allocator, loop: *io_loop.Loop, environ: std.process.Environ, application_id: []const u8, generation: u64, requests: *ReloadRequests, listener: linux.fd_t) !void {
        return self.initListener(allocator, loop, environ, application_id, generation, requests, listener);
    }

    fn initListener(self: *ControlServer, allocator: std.mem.Allocator, loop: *io_loop.Loop, environ: std.process.Environ, application_id: []const u8, generation: u64, requests: *ReloadRequests, inherited: ?linux.fd_t) !void {
        const path = if (inherited) |fd| try socket_activation.listenerPath(allocator, fd) else try socket_activation.socketPath(allocator, environ, application_id);
        errdefer allocator.free(path);
        const owned_id = try allocator.dupe(u8, application_id);
        errdefer allocator.free(owned_id);
        var service = try varlink.Service.init(allocator, .{
            .vendor = "Ourokit",
            .product = "Ourokit application runtime",
            .version = "0.1.0",
            .url = "https://github.com/rockorager/ourokit",
        }, 3);
        errdefer service.deinit();
        try service.addInterface(interface_description);
        if (inherited == null) try socket_activation.makeParentDirectories(allocator, path);
        const listener = inherited orelse try wayring.unix_socket.listen(path, 16);
        errdefer if (inherited == null) {
            _ = linux.close(listener);
            wayring.unix_socket.unlink(path) catch {};
        };
        try socket_activation.configure(listener);
        const owned_path = if (inherited == null) try socket_activation.PathIdentity.read(path) else null;
        const operation = try loop.prepareAccept(listener);
        self.* = .{
            .allocator = allocator,
            .loop = loop,
            .requests = requests,
            .service = service,
            .application_id = owned_id,
            .path = path,
            .listener = listener,
            .owned_path = owned_path,
            .listener_operation = operation,
            .generation = generation,
        };
    }

    pub fn deinit(self: *ControlServer) void {
        std.debug.assert(self.shutting_down and self.quiescent());
        self.collectClosed();
        for (&self.clients) |*entry| std.debug.assert(entry.* == null);
        if (self.listener >= 0) _ = linux.close(self.listener);
        if (self.owned_path) |identity| identity.unlink(self.path);
        if (self.activation_token) |token| self.allocator.free(token);
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

    /// Updated at the task safe point and immediately after a generation commit.
    /// In-flight actions retain their original VM until completion/cancellation.
    pub fn setApplication(self: *ControlServer, application: *const lua.Application, vm: *lua.Vm) !void {
        if (self.application == application and self.vm == vm) return;
        var prepared = try self.prepareApplication(application, vm);
        defer prepared.deinit();
        self.commitApplication(&prepared);
    }

    pub const PreparedApplication = struct {
        service: ?varlink.Service,
        application: *const lua.Application,
        vm: *lua.Vm,

        pub fn deinit(self: *PreparedApplication) void {
            if (self.service) |*service| service.deinit();
            self.* = undefined;
        }
    };

    /// Allocate and validate before committing the candidate UI generation.
    /// A discarded preparation has no effect on the live server.
    pub fn prepareApplication(self: *ControlServer, application: *const lua.Application, vm: *lua.Vm) !PreparedApplication {
        if (!std.mem.eql(u8, self.application_id, application.id)) return error.ApplicationIdChanged;
        if (!application.hasActions()) return error.ApplicationActionsDisabled;
        if (vm.state != application.state) return error.ApplicationVmMismatch;
        var replacement = try varlink.Service.init(self.allocator, .{ .vendor = "Ourokit", .product = "Ourokit application runtime", .version = "0.1.0", .url = "https://github.com/rockorager/ourokit" }, 3);
        errdefer replacement.deinit();
        try replacement.addInterface(interface_description);
        if (application.customInterface()) |interface| try replacement.addInterface(interface.source);
        return .{ .service = replacement, .application = application, .vm = vm };
    }

    /// No allocation or failure after the parent's UI generation commit.
    pub fn commitApplication(self: *ControlServer, prepared: *PreparedApplication) void {
        self.service.deinit();
        self.service = prepared.service.?;
        prepared.service = null;
        self.application = prepared.application;
        self.vm = prepared.vm;
    }

    pub fn takeActivation(self: *ControlServer) bool {
        if (!self.activation_queued) return false;
        self.activation_queued = false;
        return true;
    }

    pub fn setActivated(self: *ControlServer, active: bool) void {
        self.ui_active = active;
    }

    /// The most recently supplied coalesced token, borrowed until completion.
    pub fn activationToken(self: *const ControlServer) ?[]const u8 {
        return self.activation_token;
    }

    pub fn hasClients(self: *const ControlServer) bool {
        for (self.clients) |client| if (client != null) return true;
        return false;
    }

    /// Already-produced replies, excluding actions and idle socket reads.
    pub fn hasPendingOutput(self: *const ControlServer) bool {
        for (self.clients) |entry| if (entry) |client| {
            if (client.transmit != null or client.protocol.transmits.len() != 0) return true;
        };
        return false;
    }

    /// Idle accept/read operations and open clients do not count as work.
    pub fn hasPendingCalls(self: *const ControlServer) bool {
        if (self.activating or self.activation_queued) return true;
        for (self.clients) |entry| if (entry) |client| {
            if (client.action != null or client.activation != null or client.waiters.items.len != 0 or
                client.transmit != null or client.protocol.pending.items.len != 0 or
                client.protocol.buffered.items.len != 0 or client.protocol.events.len() != 0 or
                client.protocol.transmits.len() != 0 or client.consumed < client.received) return true;
        };
        return false;
    }

    pub fn activationSucceeded(self: *ControlServer) !void {
        if (self.activation_token) |token| self.allocator.free(token);
        self.activation_token = null;
        self.ui_active = true;
        self.activating = false;
        self.activation_queued = false;
        for (&self.clients) |*entry| if (entry.*) |*client| {
            if (client.activation) |call| {
                if (!client.closing and !self.shutting_down) try client.protocol.sendReply(call, .{ .object = .empty });
                client.activation = null;
            }
            try self.pumpClient(client);
        };
    }

    pub fn activationFailed(self: *ControlServer, err: anyerror) !void {
        if (self.activation_token) |token| self.allocator.free(token);
        self.activation_token = null;
        self.activating = false;
        self.activation_queued = false;
        for (&self.clients) |*entry| if (entry.*) |*client| {
            if (client.activation) |call| {
                if (!client.closing and !self.shutting_down) try sendFieldError(self.allocator, &client.protocol, call, interface_name ++ ".ActivateFailed", "message", @errorName(err));
                client.activation = null;
            }
            try self.pumpClient(client);
        };
    }

    /// Consumes scheduler grants for custom actions, isolating Lua failures to
    /// their Varlink caller instead of terminating the application.
    pub fn resumeRunnable(self: *ControlServer, handle: task.TaskHandle) !bool {
        for (&self.clients) |*entry| if (entry.*) |*client| {
            const action = client.action orelse continue;
            if (!same(try action.vm.schedulerHandle(action.handle), handle)) continue;
            const result = action.vm.resumeRunnable(handle) catch |err| {
                client.action = null;
                defer self.allocator.free(action.method);
                defer action.vm.scheduler.destroyScope(action.scope) catch unreachable;
                if (!client.closing) if (action.call) |call|
                    try self.sendActionFailure(client, call, @errorName(err));
                return true;
            };
            if (result == .waiting) return true;
            client.action = null;
            defer self.allocator.free(action.method);
            defer action.vm.scheduler.destroyScope(action.scope) catch unreachable;
            if (result == .canceled) {
                if (!client.closing) if (action.call) |call|
                    try self.sendActionFailure(client, call, "action canceled by reload or shutdown");
                return true;
            }
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const value = lua.Application.takeActionResult(action.vm, action.handle, arena.allocator()) catch |err| {
                if (!client.closing) if (action.call) |call|
                    try self.sendActionFailure(client, call, @errorName(err));
                return true;
            };
            if (!client.closing) if (action.call) |call| {
                const schema = &action.application.action_schema.?;
                switch (value) {
                    .output => |parameters| {
                        if (schema.validateMethodOutput(action.method, parameters) != .valid) {
                            try self.sendActionFailure(client, call, "invalid action output");
                        } else client.protocol.sendReply(call, parameters) catch |err|
                            try self.sendActionFailure(client, call, @errorName(err));
                    },
                    .declared_error => |failure| {
                        const interface = action.application.customInterface().?;
                        const qualified = try std.fmt.allocPrint(arena.allocator(), "{s}.{s}", .{ interface.name, failure.name });
                        if (interface.errorDefinition(failure.name) == null or schema.validateError(qualified, failure.parameters) != .valid) {
                            try self.sendActionFailure(client, call, "invalid declared action error");
                        } else try client.protocol.sendError(call, qualified, failure.parameters);
                    },
                }
            };
            return true;
        };
        return false;
    }

    fn sendActionFailure(self: *ControlServer, client: *Client, call: varlink.CallHandle, message: []const u8) !void {
        try sendFieldError(self.allocator, &client.protocol, call, interface_name ++ ".ActionFailed", "message", message);
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
            if (self.shutting_down or client.closing) {
                self.collectClosed();
                return true;
            }
            switch (completion.kind) {
                .recv => {
                    if (completion.result <= 0) {
                        client.operation = null;
                        try self.closeClient(client);
                        self.collectClosed();
                        return true;
                    }
                    client.operation = null;
                    client.operation_terminal = false;
                    client.received = @intCast(completion.result);
                    client.consumed = 0;
                },
                .send => {
                    if (completion.result <= 0) {
                        client.operation = null;
                        try self.closeClient(client);
                        self.collectClosed();
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
            // Parsing and Lua task creation happen only in serviceRequests.
            return true;
        };
        return false;
    }

    pub fn beginShutdown(self: *ControlServer) !void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        if (self.listener_operation) |operation| try self.loop.prepareCancel(operation);
        for (&self.clients) |*entry| if (entry.*) |*client| try self.closeClient(client);
        self.collectClosed();
    }

    fn closeClient(self: *ControlServer, client: *Client) !void {
        if (client.closing) return;
        client.closing = true;
        if (client.action) |action| try action.vm.scheduler.queueScopeCancellation(action.scope);
        if (client.operation) |operation| try self.loop.prepareCancel(operation);
    }

    pub fn collectClosed(self: *ControlServer) void {
        if (self.shutting_down) if (self.listener_operation) |operation| {
            if (self.listener_terminal and !self.loop.operationPending(operation)) {
                self.listener_operation = null;
                if (self.listener >= 0) {
                    _ = linux.close(self.listener);
                    self.listener = -1;
                }
            }
        };
        for (&self.clients) |*entry| if (entry.*) |*client| {
            if (!client.closing) continue;
            if (client.operation) |operation| {
                if (!client.operation_terminal or self.loop.operationPending(operation)) continue;
                client.operation = null;
            }
            if (client.action == null) {
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
    }

    fn pumpClient(self: *ControlServer, client: *Client) !void {
        if (client.operation != null or self.shutting_down or client.closing) return;
        while (true) {
            while (client.action == null and client.activation == null) {
                const event_value = client.protocol.takeEvent() orelse break;
                var event = event_value;
                defer event.deinit();
                switch (event) {
                    .call => |*call| try self.handleCall(client, call.handle, &call.request),
                }
            }
            if (client.action == null and client.activation == null and client.consumed < client.received) {
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
            if (client.action != null or client.consumed != client.received) return;
            client.received = 0;
            client.consumed = 0;
            // Varlink replies are ordered and non-multiplexed. Do not leave a
            // receive occupying this client's sole operation slot while a
            // long-running Reload call is waiting for its terminal reply.
            if (client.waiters.items.len != 0 or client.activation != null) return;
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
        } else if (std.mem.eql(u8, request.method, activate_method)) {
            if (request.parameters) |parameters| if (parameters.object.get("activationToken")) |value| {
                if (value == .string) {
                    const token = try self.allocator.dupe(u8, value.string);
                    if (self.activation_token) |old| self.allocator.free(old);
                    self.activation_token = token;
                }
            };
            if (!self.activating) {
                self.activating = true;
                self.activation_queued = true;
            }
            // Even an active UI needs the host to present/focus its window.
            if (!request.oneway) client.activation = call;
        } else {
            const name = request.method[(std.mem.lastIndexOfScalar(u8, request.method, '.') orelse unreachable) + 1 ..];
            const application = self.application orelse {
                if (!request.oneway) try self.sendActionFailure(client, call, "application not installed");
                return;
            };
            const vm = self.vm.?;
            const owned_method = try self.allocator.dupe(u8, request.method);
            var transferred = false;
            defer if (!transferred) self.allocator.free(owned_method);
            const scope = try vm.scheduler.createScope(vm.scheduler.application_scope);
            const handle = application.startAction(vm, scope, name, request.parameters) catch |err| {
                try vm.scheduler.destroyScope(scope);
                if (!request.oneway) {
                    if (err == error.ActionNotFound) {
                        try sendFieldError(self.allocator, &client.protocol, call, "org.varlink.service.MethodNotFound", "method", request.method);
                    } else try self.sendActionFailure(client, call, @errorName(err));
                }
                return;
            };
            client.action = .{ .vm = vm, .handle = handle, .scope = scope, .call = if (request.oneway) null else call, .application = application, .method = owned_method };
            transferred = true;
        }
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
        try parameters.put(self.allocator, "uiActive", .{ .bool = self.ui_active });
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
    const direct_listener = try wayring.unix_socket.listen(expected_path, 16);
    defer wayring.unix_socket.unlink(expected_path) catch {};

    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 4, 4);
    defer scheduler.deinit();
    var vm: lua.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var outbound: lua.VarlinkClient = undefined;
    try outbound.init(std.testing.allocator, &vm, &loop, 2);
    defer outbound.deinit();
    var application = try lua.Application.loadNamedWithApi(std.testing.allocator, vm.state,
        \\local ouro = require('ouro')
        \\return ouro.app {
        \\  id = 'dev.ourokit.test',
        \\  windows = { ouro.window { id = 'main', title = 'Test', content = function() end } },
        \\  interface = [[interface dev.ourokit.test
        \\    method Subtract(left: int, right: int) -> (difference: int)
        \\    method Echo(values: ?[]?any) -> (values: ?[]?any)
        \\    method Nothing() -> ()
        \\    method Broken() -> ()
        \\    method Invalid() -> (value: int)
        \\    method Cycle() -> (self: object)
        \\    method Delayed(delay: int, value: int) -> (value: int)
        \\    method Outbound(address: string) -> (applicationId: string)
        \\    method Oneway() -> ()
        \\    method Status() -> (status: string)
        \\    method Fail(code: int) -> ()
        \\    error Rejected(code: int)
        \\  ]],
        \\  actions = {
        \\    Subtract = function(p) return {difference = p.left - p.right} end,
        \\    Echo = function(p) return p end,
        \\    Nothing = function() return {} end,
        \\    Broken = function() return missing_function() end,
        \\    Invalid = function() return {value = 'wrong type'} end,
        \\    Cycle = function() local t = {}; t.self = t; return t end,
        \\    Delayed = function(p) ouro.sleep(p.delay); return {value = p.value} end,
        \\    Outbound = function(p)
        \\      return {applicationId = ouro.varlink.call(p.address, 'dev.ourokit.runtime.Status').parameters.applicationId}
        \\    end,
        \\    Oneway = function() action_ran = true; return {} end,
        \\    Status = function() return {status = 'custom status'} end,
        \\    Fail = function(p)
        \\      if p.code == 1 then return ouro.action_error('Rejected', {code = 19}) end
        \\      if p.code == 2 then return ouro.action_error('Rejected', {code = 'wrong'}) end
        \\      return ouro.action_error('NotDeclared', {})
        \\    end,
        \\  },
        \\}
    , "@actions-test", null, vm.apiReference());
    defer application.deinit();
    var requests: ReloadRequests = .{};
    var control: ControlServer = undefined;
    try control.initWithListener(
        std.testing.allocator,
        &loop,
        environment,
        "dev.ourokit.test",
        1,
        &requests,
        direct_listener,
    );
    try control.setApplication(&application, &vm);
    try std.testing.expect(!control.hasClients() and !control.hasPendingCalls());

    _ = try loop.submit();
    const client = try wayring.unix_socket.connect(control.socketPath());
    defer _ = linux.close(client);
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }
    try control.serviceRequests();

    _ = try loop.submit();
    const request = "{\"method\":\"dev.ourokit.runtime.Reload\"}\x00";
    try std.testing.expectEqual(request.len, linux.write(client, request, request.len));
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }
    try control.serviceRequests();
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
    try control.serviceRequests();

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
    try control.serviceRequests();
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

    // Activation replies wait for the host, including presentation of an
    // already-active UI. A failed first attempt can be retried without reload.
    for (0..3) |attempt| {
        const activation_request = if (attempt == 1)
            "{\"method\":\"dev.ourokit.runtime.Activate\",\"parameters\":{\"activationToken\":\"test-token\"}}\x00"
        else
            "{\"method\":\"dev.ourokit.runtime.Activate\"}\x00";
        try std.testing.expectEqual(activation_request.len, linux.write(client, activation_request.ptr, activation_request.len));
        while (!control.activation_queued) {
            try testService(&control, &vm);
            if (control.activation_queued) break;
            try testDispatch(&control, &vm, &outbound);
        }
        try std.testing.expect(control.hasClients() and control.hasPendingCalls());
        try std.testing.expect(control.takeActivation());
        try std.testing.expect(!control.takeActivation());
        try std.testing.expect(control.clients[0].?.protocol.transmits.len() == 0);
        if (attempt == 1) try std.testing.expectEqualStrings("test-token", control.activationToken().?);
        if (attempt == 0) try control.activationFailed(error.UiUnavailable) else try control.activationSucceeded();
        try std.testing.expect(control.activationToken() == null);
        var activation_response: [256]u8 = undefined;
        const bytes = try testReceive(&control, &vm, &outbound, client, &activation_response);
        if (attempt == 0) {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "ActivateFailed") != null);
            try std.testing.expect(!control.ui_active);
        } else {
            try std.testing.expectEqualStrings("{\"parameters\":{}}", bytes);
            try std.testing.expect(control.ui_active);
        }
    }

    const cases = [_]struct { method: []const u8, parameters: []const u8 = "{}", expected: []const u8 }{
        .{ .method = "Subtract", .parameters = "{\"left\":19,\"right\":7}", .expected = "{\"parameters\":{\"difference\":12}}" },
        .{ .method = "Nothing", .expected = "{\"parameters\":{}}" },
        .{ .method = "Echo", .expected = "{\"parameters\":{}}" },
        .{ .method = "Echo", .parameters = "{\"values\":[false,7,\"hi\",null]}", .expected = "{\"parameters\":{\"values\":[false,7,\"hi\",null]}}" },
        .{ .method = "Broken", .expected = "LuaRuntimeError" },
        .{ .method = "Invalid", .expected = "invalid action output" },
        .{ .method = "Cycle", .expected = "ValueLimitExceeded" },
        .{ .method = "Missing", .expected = "org.varlink.service.MethodNotFound" },
        .{ .method = "Subtract", .parameters = "{\"left\":19,\"right\":\"7\"}", .expected = "org.varlink.service.InvalidParameter" },
        .{ .method = "Subtract", .parameters = "{\"left\":19}", .expected = "org.varlink.service.InvalidParameter" },
        .{ .method = "Nothing", .parameters = "{\"extra\":1}", .expected = "org.varlink.service.InvalidParameter" },
        .{ .method = "Status", .expected = "{\"parameters\":{\"status\":\"custom status\"}}" },
        .{ .method = "Delayed", .parameters = "{\"delay\":1,\"value\":23}", .expected = "{\"parameters\":{\"value\":23}}" },
        .{ .method = "Fail", .parameters = "{\"code\":1}", .expected = "{\"parameters\":{\"code\":19},\"error\":\"dev.ourokit.test.Rejected\"}" },
        .{ .method = "Fail", .parameters = "{\"code\":2}", .expected = "invalid declared action error" },
        .{ .method = "Fail", .parameters = "{\"code\":3}", .expected = "invalid declared action error" },
    };
    for (cases) |case| {
        const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"method\":\"dev.ourokit.test.{s}\",\"parameters\":{s}}}\x00", .{ case.method, case.parameters });
        defer std.testing.allocator.free(message);
        try std.testing.expectEqual(message.len, linux.write(client, message.ptr, message.len));
        var response: [2048]u8 = undefined;
        const bytes = try testReceive(&control, &vm, &outbound, client, &response);
        if (case.expected[0] == '{') {
            try std.testing.expectEqualStrings(case.expected, bytes);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, bytes, case.expected) != null);
        }
        try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
    }

    // An action can call another connection to the same server without blocking
    // its task phase. This also verifies native Status survives a custom name.
    const outbound_request = try std.fmt.allocPrint(std.testing.allocator, "{{\"method\":\"dev.ourokit.test.Outbound\",\"parameters\":{{\"address\":\"unix:{s}\"}}}}\x00", .{control.socketPath()});
    defer std.testing.allocator.free(outbound_request);
    try std.testing.expectEqual(outbound_request.len, linux.write(client, outbound_request.ptr, outbound_request.len));
    var response: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("{\"parameters\":{\"applicationId\":\"dev.ourokit.test\"}}", try testReceive(&control, &vm, &outbound, client, &response));

    // Pipelined oneway + ordinary call must run in order and emit no extra reply.
    const pipelined = "{\"method\":\"dev.ourokit.test.Oneway\",\"oneway\":true}\x00" ++
        "{\"method\":\"dev.ourokit.test.Nothing\"}\x00";
    try std.testing.expectEqual(pipelined.len, linux.write(client, pipelined, pipelined.len));
    try std.testing.expectEqualStrings("{\"parameters\":{}}", try testReceive(&control, &vm, &outbound, client, &response));
    try std.testing.expect(vm.globalBoolean("action_ran"));

    // Generation retirement cancels an action without resuming its continuation.
    const delayed = "{\"method\":\"dev.ourokit.test.Delayed\",\"parameters\":{\"delay\":60000,\"value\":99}}\x00";
    try std.testing.expectEqual(delayed.len, linux.write(client, delayed, delayed.len));
    while (control.clients[0].?.action == null) {
        try testService(&control, &vm);
        if (control.clients[0].?.action != null) break;
        try testDispatch(&control, &vm, &outbound);
    }
    try vm.requestCancellation();
    const canceled = try testReceive(&control, &vm, &outbound, client, &response);
    try std.testing.expect(std.mem.indexOf(u8, canceled, "dev.ourokit.runtime.ActionFailed") != null);
    try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());

    // Shutdown also drains a suspended action and its cancellation completion.
    try std.testing.expectEqual(delayed.len, linux.write(client, delayed, delayed.len));
    while (control.clients[0].?.action == null) {
        try testService(&control, &vm);
        if (control.clients[0].?.action != null) break;
        try testDispatch(&control, &vm, &outbound);
    }
    try control.beginShutdown();
    while (!control.quiescent()) {
        try testService(&control, &vm);
        if (control.quiescent()) break;
        try testDispatch(&control, &vm, &outbound);
    }
    control.deinit();
    // The supplied listener was closed, but its pathname belongs to the caller.
    const surviving_path = try std.testing.allocator.dupeZ(u8, expected_path);
    defer std.testing.allocator.free(surviving_path);
    _ = try socket_activation.PathIdentity.read(surviving_path);
}

test "runtime server stable listener never replaces an existing owner" {
    var buffer: [128]u8 = undefined;
    const runtime = try std.fmt.bufPrintZ(&buffer, "/tmp/ourokit-owner-{d}", .{linux.getpid()});
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mkdir(runtime, 0o700)));
    defer _ = linux.rmdir(runtime);
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("XDG_RUNTIME_DIR", runtime);
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(std.testing.allocator, .{}) };
    defer environ.block.deinit(std.testing.allocator);
    const apps = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/ourokit/apps", .{runtime}, 0);
    defer std.testing.allocator.free(apps);
    const ourokit = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/ourokit", .{runtime}, 0);
    defer std.testing.allocator.free(ourokit);
    defer _ = linux.rmdir(ourokit);
    defer _ = linux.rmdir(apps);
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var requests: ReloadRequests = .{};
    var first: ControlServer = undefined;
    try first.init(std.testing.allocator, &loop, environ, "dev.test.owner", 1, &requests);
    const path = try std.testing.allocator.dupeZ(u8, first.socketPath());
    defer std.testing.allocator.free(path);
    const identity = try socket_activation.PathIdentity.read(path);
    var second: ControlServer = undefined;
    try std.testing.expectError(error.AddressInUse, second.init(std.testing.allocator, &loop, environ, "dev.test.owner", 1, &requests));
    try std.testing.expectEqual(identity, try socket_activation.PathIdentity.read(path));
    try socket_activation.validate(first.listener);
    try first.beginShutdown();
    while (!first.quiescent()) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .socket => |completion| try std.testing.expect(try first.dispatch(completion)),
            .operation_cancel => first.collectClosed(),
            else => return error.UnexpectedCompletion,
        }
    }
    first.deinit();
    try std.testing.expectError(error.SocketActivationSystemCallFailed, socket_activation.PathIdentity.read(path));
}

fn testService(control: *ControlServer, vm: *lua.Vm) !void {
    try vm.scheduler.applyQueuedCancellations();
    try control.serviceRequests();
    while (vm.scheduler.takeRunnable()) |handle|
        try std.testing.expect(try control.resumeRunnable(handle));
    control.collectClosed();
    try control.serviceRequests();
}

fn testDispatch(control: *ControlServer, vm: *lua.Vm, outbound: *lua.VarlinkClient) !void {
    _ = try control.loop.submit();
    switch (control.loop.dispatch(try control.loop.wait())) {
        .socket => |completion| if (!(try control.dispatch(completion))) {
            try std.testing.expect(try outbound.dispatch(completion));
        },
        .operation_cancel => {
            control.collectClosed();
            try outbound.collectCanceled();
        },
        .timer_wakeup, .timer_control => while (try control.loop.takeExpired()) |timeout|
            try vm.markTimeoutCompleted(timeout.operation),
        else => return error.UnexpectedCompletion,
    }
}

fn testReceive(control: *ControlServer, vm: *lua.Vm, outbound: *lua.VarlinkClient, fd: linux.fd_t, buffer: []u8) ![]const u8 {
    var received: usize = 0;
    while (true) {
        try testService(control, vm);
        _ = try control.loop.submit();
        const count = linux.recvfrom(fd, buffer[received..].ptr, buffer.len - received, linux.MSG.DONTWAIT, null, null);
        switch (linux.errno(count)) {
            .SUCCESS => {
                if (count == 0) return error.ConnectionClosed;
                received += count;
                if (std.mem.indexOfScalar(u8, buffer[0..received], 0)) |end| return buffer[0..end];
                if (received == buffer.len) return error.ReplyTooLarge;
            },
            .AGAIN => {},
            else => return error.ReceiveFailed,
        }
        if (vm.scheduler.hasPendingWork()) continue;
        try testDispatch(control, vm, outbound);
    }
}
