const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const mcp = @import("../mcp/root.zig");
const task = @import("../task/root.zig");
const ReloadRequests = @import("reload_requests.zig").ReloadRequests;
const catalog = @import("catalog.zig");
const Publication = @import("catalog_publication.zig").Publication;
pub const socket_activation = @import("socket_activation.zig");

pub const reload_method = "runtime.reload";
pub const status_method = "runtime.status";
pub const activate_method = "runtime.activate";

const client_capacity = 8;
const receive_capacity = 64 * 1024;
const subscription_capacity = 32;

const Subscription = struct {
    call: mcp.CallHandle,
    id: std.json.Parsed(mcp.Value),
    dirty: bool = false,
};

const Waiter = struct {
    sequence: u64,
    call: mcp.CallHandle,
};

const Action = struct {
    vm: *lua.Vm,
    handle: lua.TaskHandle,
    scope: task.ScopeHandle,
    call: ?mcp.CallHandle,
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
    protocol: mcp.Server,
    waiters: std.array_list.Managed(Waiter),
    operation: ?io_loop.OperationHandle = null,
    operation_terminal: bool = false,
    read_operation: ?io_loop.OperationHandle = null,
    read_terminal: bool = false,
    transmit: ?mcp.Transmit = null,
    received: usize = 0,
    consumed: usize = 0,
    action: ?Action = null,
    activation: ?mcp.CallHandle = null,
    subscriptions: [subscription_capacity]?Subscription = @splat(null),
    closing: bool = false,
    receive_buffer: [receive_capacity]u8 = undefined,

    fn init(allocator: std.mem.Allocator, fd: linux.fd_t) !Client {
        var protocol = try mcp.Server.init(allocator, .{});
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
        for (&self.subscriptions) |*entry| if (entry.*) |*subscription| subscription.id.deinit();
        self.waiters.deinit();
        self.protocol.deinit();
        _ = linux.close(self.fd);
        self.* = undefined;
    }
};

/// Process-lifetime MCP transport and built-in runtime tools.
/// It shares Ourokit's io_uring but owns a disjoint operation namespace, so
/// socket completions can be routed without exposing Wayring's reactor tags.
pub const ControlServer = struct {
    allocator: std.mem.Allocator,
    loop: *io_loop.Loop,
    requests: *ReloadRequests,
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
    tools_json: []u8,
    publication: ?Publication = null,
    publication_dirty: bool = false,

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
        const tools_json = try catalog.tools(allocator, null);
        errdefer allocator.free(tools_json);
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
            .application_id = owned_id,
            .path = path,
            .listener = listener,
            .owned_path = owned_path,
            .listener_operation = operation,
            .generation = generation,
            .tools_json = tools_json,
            .publication = Publication.init(allocator, environ, application_id, path) catch null,
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
        if (self.publication) |*publication| publication.deinit();
        self.allocator.free(self.tools_json);
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
        application: *const lua.Application,
        vm: *lua.Vm,
        allocator: std.mem.Allocator,
        tools_json: []u8,
        changed: bool,

        pub fn deinit(self: *PreparedApplication) void {
            self.allocator.free(self.tools_json);
            self.* = undefined;
        }
    };

    /// Allocate and validate before committing the candidate UI generation.
    /// A discarded preparation has no effect on the live server.
    pub fn prepareApplication(self: *ControlServer, application: *const lua.Application, vm: *lua.Vm) !PreparedApplication {
        if (!std.mem.eql(u8, self.application_id, application.id)) return error.ApplicationIdChanged;
        if (!application.hasActions()) return error.ApplicationActionsDisabled;
        if (vm.state != application.state) return error.ApplicationVmMismatch;
        const tools_json = try catalog.tools(self.allocator, application);
        return .{ .application = application, .vm = vm, .allocator = self.allocator, .tools_json = tools_json, .changed = !std.mem.eql(u8, self.tools_json, tools_json) };
    }

    /// No allocation or failure after the parent's UI generation commit.
    pub fn commitApplication(self: *ControlServer, prepared: *PreparedApplication) void {
        self.publication_dirty = self.publication_dirty or self.application == null or prepared.changed;
        self.application = prepared.application;
        self.vm = prepared.vm;
        if (prepared.changed) {
            std.mem.swap([]u8, &self.tools_json, &prepared.tools_json);
            for (&self.clients) |*entry| if (entry.*) |*client| {
                for (&client.subscriptions) |*slot| if (slot.*) |*subscription| {
                    subscription.dirty = true;
                };
            };
        }
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
            if (client.transmit != null or client.protocol.transmits.items.len != 0) return true;
        };
        return false;
    }

    /// Idle accept/read operations and open clients do not count as work.
    pub fn hasPendingCalls(self: *const ControlServer) bool {
        if (self.activating or self.activation_queued) return true;
        for (self.clients) |entry| if (entry) |client| {
            if (client.action != null or client.activation != null or client.waiters.items.len != 0 or
                client.transmit != null or client.protocol.pending.items.len != 0 or
                client.protocol.events.items.len != 0 or
                client.protocol.transmits.items.len != 0 or client.consumed < client.received) return true;
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
                if (!client.closing and !self.shutting_down) sendToolResult(&client.protocol, call, .{ .object = .empty }, false) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.closeClient(client);
                };
                client.activation = null;
            }
        };
        try self.serviceRequests();
    }

    pub fn activationFailed(self: *ControlServer, err: anyerror) !void {
        if (self.activation_token) |token| self.allocator.free(token);
        self.activation_token = null;
        self.activating = false;
        self.activation_queued = false;
        for (&self.clients) |*entry| if (entry.*) |*client| {
            if (client.activation) |call| {
                if (!client.closing and !self.shutting_down) sendToolError(&client.protocol, call, "ActivateFailed", @errorName(err), null) catch |send_err| {
                    if (send_err == error.OutOfMemory) return send_err;
                    try self.closeClient(client);
                };
                client.activation = null;
            }
        };
        try self.serviceRequests();
    }

    /// Consumes scheduler grants for custom actions, isolating Lua failures to
    /// their MCP caller instead of terminating the application.
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
                const tool = action.application.actionTool(action.method).?;
                switch (value) {
                    .output => |parameters| {
                        if (!mcp.schema.validate(mcp.get(tool, "outputSchema").?, parameters)) {
                            try self.sendActionFailure(client, call, "invalid action output");
                        } else sendToolResult(&client.protocol, call, parameters, false) catch |err|
                            try self.sendActionFailure(client, call, @errorName(err));
                    },
                    .declared_error => |failure| {
                        sendToolError(&client.protocol, call, failure.name, failure.name, failure.parameters) catch |err|
                            try self.sendActionFailure(client, call, @errorName(err));
                    },
                }
            };
            return true;
        };
        return false;
    }

    fn sendActionFailure(self: *ControlServer, client: *Client, call: mcp.CallHandle, message: []const u8) !void {
        sendToolError(&client.protocol, call, "ActionFailed", message, null) catch |err| {
            if (err == error.OutOfMemory) return err;
            try self.closeClient(client);
        };
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
                if (!self.shutting_down and !client.closing) sendGeneration(client, waiter.call, generation) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.closeClient(client);
                };
                _ = client.waiters.orderedRemove(index);
            }
        };
        try self.serviceRequests();
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
                if (!self.shutting_down and !client.closing) sendReloadFailure(client, waiter.call, failure.*) catch |send_err| {
                    if (send_err == error.OutOfMemory) return send_err;
                    try self.closeClient(client);
                };
                _ = client.waiters.orderedRemove(index);
            }
        };
        try self.serviceRequests();
    }

    pub fn serviceRequests(self: *ControlServer) !void {
        if (self.shutting_down) return;
        if (self.publication_dirty) {
            self.publication_dirty = false;
            // Retry on the next catalog change, not every event-loop turn.
            // A best-effort discovery hint must never roll back a generation.
            if (self.publication) |*publication| publication.publish(self.application_id, self.tools_json) catch {};
        }
        for (&self.clients) |*entry| if (entry.*) |*client| {
            self.pumpClient(client) catch |err| {
                if (err == error.OutOfMemory) return err;
                try self.closeClient(client);
            };
        };
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
            const reading = if (client.read_operation) |op| same(op, completion.operation) else false;
            const writing = if (client.operation) |op| same(op, completion.operation) else false;
            if (!reading and !writing) continue;
            if (reading) client.read_terminal = true else client.operation_terminal = true;
            if (self.shutting_down or client.closing) {
                self.collectClosed();
                return true;
            }
            switch (completion.kind) {
                .recv => {
                    if (completion.result <= 0) {
                        client.read_operation = null;
                        try self.closeClient(client);
                        self.collectClosed();
                        return true;
                    }
                    client.read_operation = null;
                    client.read_terminal = false;
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
                .accept, .connect, .recvmsg, .sendmsg => return error.UnexpectedSocketCompletion,
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
        if (client.read_operation) |operation| try self.loop.prepareCancel(operation);
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
            if (client.read_operation) |operation| {
                if (!client.read_terminal or self.loop.operationPending(operation)) continue;
                client.read_operation = null;
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
        if (self.shutting_down or client.closing) return;
        while (true) {
            while (client.protocol.transmits.items.len < client.protocol.config.max_transmits) {
                const event_value = client.protocol.takeEvent() orelse break;
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
            self.notifyCatalog(client) catch {
                // The generation is already committed. Failure to publish an
                // invalidation retires this peer, never the application.
                try self.closeClient(client);
                return;
            };
            if (client.operation == null) {
                if (client.transmit == null) client.transmit = client.protocol.takeTransmit();
                if (client.transmit) |*transmit| {
                    client.operation = try self.loop.prepareSend(client.fd, transmit.remaining());
                    client.operation_terminal = false;
                }
            }
            if (client.consumed != client.received or client.read_operation != null) return;
            client.received = 0;
            client.consumed = 0;
            // Reads and writes own independent operations: a sleeping action
            // never prevents status, reload, or cancellation on this connection.
            client.read_operation = try self.loop.prepareRecv(client.fd, &client.receive_buffer);
            client.read_terminal = false;
            return;
        }
    }

    fn notifyCatalog(self: *ControlServer, client: *Client) !void {
        // Acknowledgments are queued before registration. Coalescing only
        // dirty invalidations bounds slow listeners without losing the
        // subscribe-then-list race: later commits dirty them again.
        for (&client.subscriptions) |*entry| if (entry.*) |*subscription| {
            if (!subscription.dirty or client.protocol.transmits.items.len == client.protocol.config.max_transmits) continue;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            try client.protocol.sendNotification("notifications/tools/list_changed", try subscriptionParams(arena.allocator(), subscription.id.value));
            subscription.dirty = false;
        };
    }

    fn handleCall(
        self: *ControlServer,
        client: *Client,
        call: mcp.CallHandle,
        request: *const mcp.Request,
    ) !void {
        if (request.id == null) {
            if (std.mem.eql(u8, request.method, "notifications/cancelled")) {
                const id = mcp.get(request.params orelse return, "requestId") orelse return;
                const target = client.protocol.handleForId(id) orelse return;
                for (&client.subscriptions) |*entry| if (entry.*) |*subscription| {
                    if (subscription.call.value != target.value) continue;
                    var arena: std.heap.ArenaAllocator = .init(self.allocator);
                    defer arena.deinit();
                    try client.protocol.sendResult(target, try subscriptionParams(arena.allocator(), subscription.id.value));
                    subscription.id.deinit();
                    entry.* = null;
                    return;
                };
                if (client.action) |action| if (action.call != null and action.call.?.value == target.value) {
                    try action.vm.scheduler.queueScopeCancellation(action.scope);
                };
            }
            return;
        }
        if (std.mem.eql(u8, request.method, "server/discover")) {
            var doc = try std.json.parseFromSlice(mcp.Value, self.allocator,
                \\{"supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"ourokit","version":"0.1.0"}},"ttlMs":60000,"cacheScope":"private"}
            , .{});
            defer doc.deinit();
            return client.protocol.sendResult(call, doc.value);
        }
        if (std.mem.eql(u8, request.method, "tools/list")) return self.sendTools(client, call);
        if (std.mem.eql(u8, request.method, "subscriptions/listen")) {
            const notifications = mcp.get(request.params orelse return client.protocol.sendError(call, -32602, "Missing subscription filter", null), "notifications") orelse
                return client.protocol.sendError(call, -32602, "Missing subscription filter", null);
            const changed = mcp.get(notifications, "toolsListChanged") orelse return client.protocol.sendError(call, -32602, "Unsupported subscription filter", null);
            if (changed != .bool or !changed.bool) return client.protocol.sendError(call, -32602, "Unsupported subscription filter", null);
            const slot = for (&client.subscriptions) |*entry| {
                if (entry.* == null) break entry;
            } else return client.protocol.sendError(call, -32000, "Subscription capacity exceeded", null);
            const bytes = try std.json.Stringify.valueAlloc(self.allocator, request.id.?, .{});
            defer self.allocator.free(bytes);
            var id = try std.json.parseFromSlice(mcp.Value, self.allocator, bytes, .{ .allocate = .alloc_always, .parse_numbers = false });
            errdefer id.deinit();
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var params = try subscriptionParams(a, id.value);
            try params.object.put(a, "notifications", try mcp.object(a, .{.{ "toolsListChanged", mcp.Value{ .bool = true } }}));
            try client.protocol.sendNotification("notifications/subscriptions/acknowledged", params);
            slot.* = .{ .call = call, .id = id };
            return;
        }
        if (!std.mem.eql(u8, request.method, "tools/call")) return client.protocol.sendError(call, -32601, "Method not found", null);
        const params = request.params orelse return client.protocol.sendError(call, -32602, "Missing tool parameters", null);
        const name_value = mcp.get(params, "name") orelse return client.protocol.sendError(call, -32602, "Missing tool name", null);
        if (name_value != .string) return client.protocol.sendError(call, -32602, "Invalid tool name", null);
        const name = name_value.string;
        const arguments = mcp.get(params, "arguments") orelse mcp.Value{ .object = .empty };
        var builtins = try std.json.parseFromSlice(mcp.Value, self.allocator, catalog.builtin_tools, .{});
        defer builtins.deinit();
        const tool = for (builtins.value.array.items) |item| {
            if (mcp.isString(mcp.get(item, "name"), name)) break item;
        } else (if (self.application) |app| app.actionTool(name) else null) orelse
            return client.protocol.sendError(call, -32602, "Unknown tool", null);
        if (!mcp.schema.validate(mcp.get(tool, "inputSchema").?, arguments))
            return client.protocol.sendError(call, -32602, "Invalid tool arguments", null);

        if (std.mem.eql(u8, name, reload_method)) {
            const sequence = self.requests.request();
            self.reloading = true;
            if (client.waiters.items.len == client.waiters.capacity) return error.ReloadWaiterCapacityExceeded;
            client.waiters.appendAssumeCapacity(.{ .sequence = sequence, .call = call });
        } else if (std.mem.eql(u8, name, status_method)) {
            try self.sendStatus(client, call);
        } else if (std.mem.eql(u8, name, activate_method)) {
            if (client.activation != null) return sendToolError(&client.protocol, call, "Busy", "Activation already pending", null);
            if (arguments.object.get("activationToken")) |value| {
                if (value == .string) {
                    const token = try self.allocator.dupe(u8, value.string);
                    if (self.activation_token) |old| self.allocator.free(old);
                    self.activation_token = token;
                }
            }
            if (!self.activating) {
                self.activating = true;
                self.activation_queued = true;
            }
            // Even an active UI needs the host to present/focus its window.
            client.activation = call;
        } else {
            if (client.action != null) return sendToolError(&client.protocol, call, "Busy", "One custom action per connection", null);
            const application = self.application.?;
            const vm = self.vm.?;
            const owned_method = try self.allocator.dupe(u8, name);
            var transferred = false;
            defer if (!transferred) self.allocator.free(owned_method);
            const scope = try vm.scheduler.createScope(vm.scheduler.application_scope);
            const handle = application.startAction(vm, scope, name, arguments) catch |err| {
                try vm.scheduler.destroyScope(scope);
                try self.sendActionFailure(client, call, @errorName(err));
                return;
            };
            client.action = .{ .vm = vm, .handle = handle, .scope = scope, .call = call, .application = application, .method = owned_method };
            transferred = true;
        }
    }

    fn sendStatus(
        self: *ControlServer,
        client: *Client,
        call: mcp.CallHandle,
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
            try sendToolResult(&client.protocol, call, .{ .object = parameters }, false);
        } else {
            try parameters.put(self.allocator, "diagnostic", .null);
            try sendToolResult(&client.protocol, call, .{ .object = parameters }, false);
        }
    }

    fn sendTools(self: *ControlServer, client: *Client, call: mcp.CallHandle) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const list = try std.json.parseFromSlice(mcp.Value, a, self.tools_json, .{ .parse_numbers = false });
        try client.protocol.sendResult(call, try mcp.object(a, .{ .{ "tools", list.value }, .{ "ttlMs", mcp.Value{ .integer = 60000 } }, .{ "cacheScope", mcp.string("private") } }));
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

fn sendGeneration(client: *Client, call: mcp.CallHandle, generation: u64) !void {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(client.protocol.allocator);
    try parameters.put(
        client.protocol.allocator,
        "generation",
        .{ .integer = @intCast(generation) },
    );
    try sendToolResult(&client.protocol, call, .{ .object = parameters }, false);
}

fn sendReloadFailure(client: *Client, call: mcp.CallHandle, failure: Failure) !void {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(client.protocol.allocator);
    try parameters.put(client.protocol.allocator, "phase", .{ .string = failure.phase });
    try parameters.put(client.protocol.allocator, "source", .{ .string = failure.source });
    try parameters.put(client.protocol.allocator, "message", .{ .string = failure.message });
    try sendToolError(&client.protocol, call, "ReloadFailed", failure.message, .{ .object = parameters });
}

fn sendToolError(server: *mcp.Server, call: mcp.CallHandle, code: []const u8, message: []const u8, parameters: ?mcp.Value) !void {
    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var detail = try mcp.object(a, .{ .{ "code", mcp.string(code) }, .{ "message", mcp.string(message) } });
    if (parameters) |value| try detail.object.put(a, "parameters", value);
    try sendToolResult(server, call, try mcp.object(a, .{.{ "error", detail }}), true);
}

fn sendToolResult(server: *mcp.Server, call: mcp.CallHandle, value: mcp.Value, is_error: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    var content = std.array_list.Managed(mcp.Value).init(a);
    try content.append(try mcp.object(a, .{ .{ "type", mcp.string("text") }, .{ "text", mcp.string(text) } }));
    try server.sendResult(call, try mcp.object(a, .{ .{ "structuredContent", value }, .{ "content", mcp.Value{ .array = content } }, .{ "isError", mcp.Value{ .bool = is_error } } }));
}

fn subscriptionParams(a: std.mem.Allocator, id: mcp.Value) !mcp.Value {
    return mcp.object(a, .{.{ "_meta", try mcp.object(a, .{.{ "io.modelcontextprotocol/subscriptionId", id }}) }});
}

fn same(first: io_loop.OperationHandle, second: io_loop.OperationHandle) bool {
    return first.slot == second.slot and first.generation == second.generation;
}

test "runtime tool schemas use the supported JSON Schema subset" {
    const bytes = try catalog.tools(std.testing.allocator, null);
    defer std.testing.allocator.free(bytes);
    var tools = try std.json.parseFromSlice(mcp.Value, std.testing.allocator, bytes, .{});
    defer tools.deinit();
    for (tools.value.array.items) |tool| {
        try mcp.schema.check(mcp.get(tool, "inputSchema").?);
        try mcp.schema.check(mcp.get(tool, "outputSchema").?);
    }
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
        "/tmp/ouro-{d}.mcp",
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
    var outbound: lua.McpClient = undefined;
    try outbound.init(std.testing.allocator, &vm, &loop, 2);
    defer outbound.deinit();
    var application = try lua.Application.loadNamedWithApi(std.testing.allocator, vm.state,
        \\local ouro = require('ouro')
        \\local empty = {type='object', additionalProperties=false}
        \\local function obj(props, required) return {type='object', properties=props, required=required, additionalProperties=false} end
        \\local int, str = {type='integer'}, {type='string'}
        \\local function action(input, output, handler) return {description='Test action', inputSchema=input, outputSchema=output, handler=handler} end
        \\return ouro.app {
        \\  id = 'dev.ourokit.test',
        \\  windows = { ouro.window { id = 'main', title = 'Test', content = function() end } },
        \\  actions = {
        \\    Subtract = action(obj({left=int,right=int},{'left','right'}), obj({difference=int},{'difference'}), function(p) return {difference=p.left-p.right} end),
        \\    Echo = action({type='object'}, {type='object'}, function(p) return p end),
        \\    Nothing = action(empty, empty, function() return {} end),
        \\    Broken = action(empty, empty, function() return missing_function() end),
        \\    Invalid = action(empty, obj({value=int},{'value'}), function() return {value='wrong type'} end),
        \\    Cycle = action(empty, {type='object'}, function() local t={}; t.self=t; return t end),
        \\    Delayed = action(obj({delay=int,value=int},{'delay','value'}), obj({value=int},{'value'}), function(p) ouro.sleep(p.delay); return {value=p.value} end),
        \\    Outbound = action(obj({address=str},{'address'}), obj({applicationId=str},{'applicationId'}), function(p)
        \\      return {applicationId=ouro.mcp.call(p.address,'runtime.status').result.structuredContent.applicationId}
        \\    end),
        \\    Status = action(empty, obj({status=str},{'status'}), function() return {status='custom status'} end),
        \\    Fail = action(obj({code=int},{'code'}), empty, function(p)
        \\      if p.code == 1 then return ouro.action_error('Rejected', {code = 19}) end
        \\      if p.code == 2 then return ouro.action_error('Rejected', {code = 'wrong'}) end
        \\      return ouro.action_error('NotDeclared', {})
        \\    end),
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
    try control.serviceRequests();

    // Preparing a catalog is not publishing it. A later candidate UI failure
    // must leave the active app, serialized catalog and publication bit intact.
    {
        const before = try std.testing.allocator.dupe(u8, control.tools_json);
        defer std.testing.allocator.free(before);
        var candidate = try lua.Application.loadNamedWithApi(std.testing.allocator, vm.state,
            \\local o = require('ouro')
            \\return o.app {id='dev.ourokit.test', actions={}, windows={o.window{id='candidate',title='Candidate',content=function() end}}}
        , "@discarded-catalog", null, vm.apiReference());
        defer candidate.deinit();
        var prepared = try control.prepareApplication(&candidate, &vm);
        defer prepared.deinit();
        try std.testing.expect(prepared.changed);
        try std.testing.expectEqualStrings(before, control.tools_json);
        try std.testing.expect(control.application == &application and !control.publication_dirty);

        const exported = try catalog.descriptor(std.testing.allocator, &application);
        defer std.testing.allocator.free(exported);
        var descriptor = try std.json.parseFromSlice(mcp.Value, std.testing.allocator, exported, .{});
        defer descriptor.deinit();
        try std.testing.expectEqual(@as(i64, 1), mcp.get(descriptor.value, "schema_version").?.integer);
        try std.testing.expect(mcp.isString(mcp.get(descriptor.value, "application_id"), "dev.ourokit.test"));
        try std.testing.expect(mcp.isString(mcp.get(mcp.get(descriptor.value, "endpoint").?, "runtime_path"), "ourokit/apps/dev.ourokit.test"));
        const exported_tools = try catalog.serialize(std.testing.allocator, mcp.get(descriptor.value, "tools").?);
        defer std.testing.allocator.free(exported_tools);
        try std.testing.expectEqualStrings(before, exported_tools);
    }

    _ = try loop.submit();
    const client = try wayring.unix_socket.connect(control.socketPath());
    defer _ = linux.close(client);
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| try std.testing.expect(try control.dispatch(completion)),
        else => return error.UnexpectedCompletion,
    }
    try control.serviceRequests();

    _ = try loop.submit();
    const request = try testRequest(reload_method, "{}");
    defer std.testing.allocator.free(request);
    try std.testing.expectEqual(request.len, linux.write(client, request.ptr, request.len));
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
    var reply: [2048]u8 = undefined;
    const reply_len = linux.read(client, &reply, reply.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(reply_len));
    try std.testing.expect(std.mem.indexOf(u8, reply[0..reply_len], "\"generation\":2") != null);
    try control.serviceRequests();

    const status_request = try testRequest(status_method, "{}");
    defer std.testing.allocator.free(status_request);
    try std.testing.expectEqual(
        status_request.len,
        linux.write(client, status_request.ptr, status_request.len),
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
        const activation_request = try testRequest(activate_method, if (attempt == 1) "{\"activationToken\":\"test-token\"}" else "{}");
        defer std.testing.allocator.free(activation_request);
        try std.testing.expectEqual(activation_request.len, linux.write(client, activation_request.ptr, activation_request.len));
        while (!control.activation_queued) {
            try testService(&control, &vm);
            if (control.activation_queued) break;
            try testDispatch(&control, &vm, &outbound);
        }
        try std.testing.expect(control.hasClients() and control.hasPendingCalls());
        try std.testing.expect(control.takeActivation());
        try std.testing.expect(!control.takeActivation());
        try std.testing.expect(control.clients[0].?.protocol.transmits.items.len == 0);
        if (attempt == 1) try std.testing.expectEqualStrings("test-token", control.activationToken().?);
        if (attempt == 0) try control.activationFailed(error.UiUnavailable) else try control.activationSucceeded();
        try std.testing.expect(control.activationToken() == null);
        var activation_response: [2048]u8 = undefined;
        const bytes = try testReceive(&control, &vm, &outbound, client, &activation_response);
        if (attempt == 0) {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "ActivateFailed") != null);
            try std.testing.expect(!control.ui_active);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "\"structuredContent\":{}") != null);
            try std.testing.expect(control.ui_active);
        }
    }

    const cases = [_]struct { method: []const u8, parameters: []const u8 = "{}", expected: []const u8 }{
        .{ .method = "Subtract", .parameters = "{\"left\":19,\"right\":7}", .expected = "\"structuredContent\":{\"difference\":12}" },
        .{ .method = "Nothing", .expected = "\"structuredContent\":{}" },
        .{ .method = "Echo", .expected = "\"structuredContent\":{}" },
        .{ .method = "Echo", .parameters = "{\"values\":[false,7,\"hi\",null]}", .expected = "\"structuredContent\":{\"values\":[false,7,\"hi\",null]}" },
        .{ .method = "Broken", .expected = "LuaRuntimeError" },
        .{ .method = "Invalid", .expected = "invalid action output" },
        .{ .method = "Cycle", .expected = "ValueLimitExceeded" },
        .{ .method = "Missing", .expected = "Unknown tool" },
        .{ .method = "Subtract", .parameters = "{\"left\":19,\"right\":\"7\"}", .expected = "Invalid tool arguments" },
        .{ .method = "Subtract", .parameters = "{\"left\":19}", .expected = "Invalid tool arguments" },
        .{ .method = "Nothing", .parameters = "{\"extra\":1}", .expected = "Invalid tool arguments" },
        .{ .method = "Status", .expected = "\"structuredContent\":{\"status\":\"custom status\"}" },
        .{ .method = "Delayed", .parameters = "{\"delay\":1,\"value\":23}", .expected = "\"structuredContent\":{\"value\":23}" },
        .{ .method = "Fail", .parameters = "{\"code\":1}", .expected = "\"parameters\":{\"code\":19}" },
        .{ .method = "Fail", .parameters = "{\"code\":2}", .expected = "\"parameters\":{\"code\":\"wrong\"}" },
        .{ .method = "Fail", .parameters = "{\"code\":3}", .expected = "NotDeclared" },
    };
    for (cases) |case| {
        const message = try testRequest(case.method, case.parameters);
        defer std.testing.allocator.free(message);
        try std.testing.expectEqual(message.len, linux.write(client, message.ptr, message.len));
        var response: [2048]u8 = undefined;
        const bytes = try testReceive(&control, &vm, &outbound, client, &response);
        try std.testing.expect(std.mem.indexOf(u8, bytes, case.expected) != null);
        try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
    }

    // An action can call another connection to the same server without blocking
    // its task phase. This also verifies native Status survives a custom name.
    const outbound_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"address\":\"unix:{s}\"}}", .{control.socketPath()});
    defer std.testing.allocator.free(outbound_args);
    const outbound_request = try testRequest("Outbound", outbound_args);
    defer std.testing.allocator.free(outbound_request);
    try std.testing.expectEqual(outbound_request.len, linux.write(client, outbound_request.ptr, outbound_request.len));
    var response: [2048]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try testReceive(&control, &vm, &outbound, client, &response), "\"structuredContent\":{\"applicationId\":\"dev.ourokit.test\"}") != null);

    // Generation retirement cancels an action without resuming its continuation.
    const delayed = try testRequest("Delayed", "{\"delay\":60000,\"value\":99}");
    defer std.testing.allocator.free(delayed);
    try std.testing.expectEqual(delayed.len, linux.write(client, delayed.ptr, delayed.len));
    while (control.clients[0].?.action == null) {
        try testService(&control, &vm);
        if (control.clients[0].?.action != null) break;
        try testDispatch(&control, &vm, &outbound);
    }
    try vm.requestCancellation();
    const canceled = try testReceive(&control, &vm, &outbound, client, &response);
    try std.testing.expect(std.mem.indexOf(u8, canceled, "ActionFailed") != null);
    try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());

    // Shutdown also drains a suspended action and its cancellation completion.
    try std.testing.expectEqual(delayed.len, linux.write(client, delayed.ptr, delayed.len));
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

fn testRequest(name: []const u8, arguments: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s},\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{{}}}}}}}}\n", .{ name, arguments });
}

fn testDispatch(control: *ControlServer, vm: *lua.Vm, outbound: *lua.McpClient) !void {
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

fn testReceive(control: *ControlServer, vm: *lua.Vm, outbound: *lua.McpClient, fd: linux.fd_t, buffer: []u8) ![]const u8 {
    var received: usize = 0;
    while (true) {
        try testService(control, vm);
        _ = try control.loop.submit();
        const count = linux.recvfrom(fd, buffer[received..].ptr, buffer.len - received, linux.MSG.DONTWAIT, null, null);
        switch (linux.errno(count)) {
            .SUCCESS => {
                if (count == 0) return error.ConnectionClosed;
                received += count;
                if (std.mem.indexOfScalar(u8, buffer[0..received], '\n')) |end| return buffer[0..end];
                if (received == buffer.len) return error.ReplyTooLarge;
            },
            .AGAIN => {},
            else => return error.ReceiveFailed,
        }
        if (vm.scheduler.hasPendingWork()) continue;
        try testDispatch(control, vm, outbound);
    }
}
