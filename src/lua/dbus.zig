//! Generic, scoped D-Bus access. CQEs publish data; only continuations touch Lua.
const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const dbus = @import("../dbus/root.zig");
const wire = dbus.wire;
const c = @import("c.zig");
const vm_module = @import("vm.zig");
const values = @import("dbus_values.zig");

const bus_mt = "ouro.dbus.connection";
const sub_mt = "ouro.dbus.subscription";
const export_mt = "ouro.dbus.export";
const wait_mt = "ouro.dbus.wait";
const request_mt = "ouro.dbus.request";
const name_mt = "ouro.dbus.name";
const daemon = "org.freedesktop.DBus";
const daemon_path = "/org/freedesktop/DBus";
const owner_match = "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'";

const Bus = struct {
    binding: *Binding = undefined,
    active: bool = false,
    client: dbus.Client = undefined,
    resource: ?task.ResourceHandle = null,
    guard: ?*?*Bus = null,
    closing: bool = false,
    ready: bool = false,
    setup_serial: ?u32 = null,
};
const Subscription = struct {
    binding: *Binding = undefined,
    active: bool = false,
    bus: *Bus = undefined,
    resource: ?task.ResourceHandle = null,
    guard: ?*?*Subscription = null,
    phase: enum { resolving, adding, ready, closing } = .resolving,
    serial: u32 = 0,
    added: bool = false,
    rule: []u8 = &.{},
    sender: ?[]u8 = null,
    sender_owner: ?[]u8 = null,
    path: ?[]u8 = null,
    interface: ?[]u8 = null,
    member: ?[]u8 = null,
    failure: ?anyerror = null,
    queue: std.ArrayList(wire.Message) = .empty,
    queued_bytes: usize = 0,
    // Exported interfaces use the same bounded, single-consumer inbox as signals.
    scope: ?task.ScopeHandle = null,
    methods: std.ArrayList(Method) = .empty,
    signals: std.ArrayList(Method) = .empty,
    requests: usize = 0,
};
const Method = struct { name: []u8, input: []u8, output: []u8 };
const Request = struct {
    active: bool = false,
    sub: *Subscription = undefined,
    message: wire.Message = undefined,
    output: []const u8 = "",
    guard: ?*?*Request = null,
};
const Name = struct {
    active: bool = false,
    bus: *Bus = undefined,
    value: []u8 = &.{},
    closing: bool = false,
    requested: bool = false,
    resource: ?task.ResourceHandle = null,
    guard: ?*?*Name = null,
};
const Wait = struct {
    binding: *Binding = undefined,
    active: bool = false,
    kind: enum { connect, call, subscribe, next, own_name } = .call,
    bus: *Bus = undefined,
    sub: ?*Subscription = null,
    name: ?*Name = null,
    serial: u32 = 0,
    task_handle: vm_module.TaskHandle = .invalid,
    timer: ?io.OperationHandle = null,
    guard: ?*?*Wait = null,
    canceled: bool = false,
    completed: bool = false,
    result: ?wire.Message = null,
    failure: ?anyerror = null,
};

/// Stable-address adapter owned by one source generation. All userdata are
/// invalidated before native slot storage can be reused or freed.
pub const Binding = struct {
    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    loop: *io.Loop,
    buses: []Bus,
    subscriptions: []Subscription,
    waits: []Wait,
    requests: [128]Request = @splat(.{}),
    names: [64]Name = @splat(.{}),
    session_address: ?[]u8 = null,
    system_address: []u8,
    stopping: bool = false,

    pub fn init(self: *Binding, allocator: std.mem.Allocator, vm: *vm_module.Vm, loop: *io.Loop, environ: std.process.Environ) !void {
        const buses = try allocator.alloc(Bus, 8);
        errdefer allocator.free(buses);
        const subscriptions = try allocator.alloc(Subscription, 64);
        errdefer allocator.free(subscriptions);
        const waits = try allocator.alloc(Wait, 128);
        errdefer allocator.free(waits);
        const session = if (environ.getPosix("DBUS_SESSION_BUS_ADDRESS")) |address|
            try allocator.dupe(u8, address)
        else if (environ.getPosix("XDG_RUNTIME_DIR")) |directory|
            try sessionAddress(allocator, directory)
        else
            null;
        errdefer if (session) |address| allocator.free(address);
        const system = try allocator.dupe(u8, environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS") orelse "unix:path=/run/dbus/system_bus_socket");
        errdefer allocator.free(system);
        self.* = .{ .allocator = allocator, .vm = vm, .loop = loop, .buses = buses, .subscriptions = subscriptions, .waits = waits, .session_address = session, .system_address = system };
        for (buses) |*bus| bus.* = .{ .binding = self };
        for (subscriptions) |*sub| sub.* = .{ .binding = self };
        for (waits) |*wait| wait.* = .{ .binding = self };
        const L = vm.state;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        vm.pushApi(L);
        c.lua_createtable(L, 0, 3);
        try values.install(L);
        c.lua_pushlightuserdata(L, self);
        c.lua_pushcclosure(L, connect, 1);
        c.lua_setfield(L, -2, "connect");
        c.lua_setfield(L, -2, "dbus");
        installMetatable(L, bus_mt, &.{ .{ "call", call }, .{ "subscribe", subscribe }, .{ "close", closeBusLua }, .{ "__close", closeBusLua }, .{ "__gc", closeBusLua } });
        installMetatable(L, sub_mt, &.{ .{ "next", next }, .{ "close", closeSubLua }, .{ "__close", closeSubLua }, .{ "__gc", closeSubLua } });
        installMetatable(L, export_mt, &.{ .{ "close", closeSubLua }, .{ "__close", closeSubLua }, .{ "__gc", closeSubLua } });
        installMetatable(L, wait_mt, &.{.{ "__close", closeWaitLua }});
        installMetatable(L, request_mt, &.{ .{ "reply", replyLua }, .{ "error", errorLua }, .{ "__close", closeRequestLua }, .{ "__gc", closeRequestLua } });
        installMetatable(L, name_mt, &.{ .{ "close", closeNameLua }, .{ "__close", closeNameLua }, .{ "__gc", closeNameLua } });
        _ = c.luaL_newmetatable(L, bus_mt);
        c.lua_pushcclosure(L, ownName, 0);
        c.lua_setfield(L, -2, "own_name");
        c.lua_pushcclosure(L, emitLua, 0);
        c.lua_setfield(L, -2, "emit");
        const source = @embedFile("dbus_service.lua");
        if (c.luaL_loadbufferx(L, source, source.len, "=ouro.dbus.service", "t") != c.ok) return error.ServiceInitializationFailed;
        vm.pushApi(L);
        c.lua_pushcclosure(L, exportLua, 0);
        c.lua_pushcclosure(L, next, 0);
        if (c.lua_pcallk(L, 3, 1, 0, 0, null) != c.ok) return error.ServiceInitializationFailed;
        c.lua_setfield(L, -2, "export");
    }

    /// Retires this generation's persistent connections without canceling
    /// native scopes shared with its replacement. Pump until canDeinit().
    pub fn shutdown(self: *Binding) void {
        self.stopping = true;
        for (self.buses) |*bus| if (bus.active) {
            bus.closing = true;
        };
    }

    pub fn canDeinit(self: *const Binding) bool {
        for (self.buses) |bus| if (bus.active) return false;
        for (self.waits) |wait| if (wait.active) return false;
        for (self.subscriptions) |sub| if (sub.active and sub.scope != null) return false;
        return true;
    }

    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.canDeinit());
        for (self.subscriptions) |*sub| if (sub.active) self.releaseSub(sub);
        self.allocator.free(self.buses);
        self.allocator.free(self.subscriptions);
        self.allocator.free(self.waits);
        if (self.session_address) |address| self.allocator.free(address);
        self.allocator.free(self.system_address);
        self.* = undefined;
    }

    pub fn dispatch(self: *Binding, completion: io.SocketCompletion) !bool {
        for (self.buses) |*bus| if (bus.active) {
            if (try bus.client.dispatch(completion)) {
                try self.collectCanceled();
                return true;
            }
        };
        return false;
    }

    pub fn dispatchTimer(self: *Binding, operation: io.OperationHandle) !bool {
        for (self.buses) |*bus| if (bus.active and try bus.client.dispatchTimer(operation)) {
            try self.collectCanceled();
            return true;
        };
        for (self.waits) |*wait| if (wait.active) {
            if (wait.timer) |timer| if (same(timer, operation)) {
                wait.timer = null;
                if (wait.kind == .connect) wait.bus.closing = true;
                if (wait.kind == .own_name) wait.name.?.closing = true;
                if (wait.kind == .subscribe) wait.sub.?.phase = .closing;
                try self.finish(wait, error.Timeout);
                return true;
            };
        };
        return false;
    }

    /// Host safe-point pump, also called for terminal cancellation CQEs.
    pub fn collectCanceled(self: *Binding) !void {
        for (self.waits) |*wait| if (wait.active and wait.canceled and !wait.completed) {
            if (wait.kind == .connect) wait.bus.closing = true;
            if (wait.kind == .subscribe) wait.sub.?.phase = .closing;
            if (wait.kind == .own_name) wait.name.?.closing = true;
            try self.finish(wait, error.Canceled);
            self.releaseWait(wait);
        };
        for (self.buses) |*bus| if (bus.active) {
            if (bus.closing) try bus.client.close();
            try bus.client.collectCanceled();
            if (bus.client.isReady() and !bus.closing and bus.setup_serial == null and !bus.ready)
                bus.setup_serial = daemonCall(bus, "AddMatch", owner_match) catch |err| blk: {
                    bus.client.failure = err;
                    break :blk null;
                };
            while (try bus.client.takeMessage()) |incoming| {
                var message = incoming;
                defer message.deinit();
                self.route(bus, &message) catch |err| {
                    bus.client.failure = err;
                    break;
                };
            }
            if (bus.client.failure != null) bus.closing = true;
            for (self.waits) |*wait| if (wait.active and !wait.completed and wait.bus == bus) {
                if (bus.closing) {
                    try self.finish(wait, bus.client.failure orelse error.ConnectionClosed);
                } else if (wait.kind == .connect and bus.ready) try self.finish(wait, null);
            };
            for (self.subscriptions) |*sub| if (sub.active and sub.bus == bus) {
                if (bus.closing) {
                    sub.failure = bus.client.failure orelse error.ConnectionClosed;
                    sub.phase = .closing;
                }
                if (sub.phase == .closing) {
                    if (sub.scope) |scope| {
                        try self.vm.scheduler.queueScopeCancellation(scope);
                        for (&self.requests) |*request| if (request.active and request.sub == sub) {
                            sendError(bus, &request.message, "org.freedesktop.DBus.Error.Failed", "Export closed") catch {
                                bus.closing = true;
                            };
                            self.releaseRequest(request);
                        };
                        for (sub.queue.items) |*message| sendError(bus, message, "org.freedesktop.DBus.Error.Failed", "Export closed") catch {
                            bus.closing = true;
                        };
                    }
                    if (sub.added and !bus.closing) {
                        _ = daemonCall(bus, "RemoveMatch", sub.rule) catch |err| {
                            if (err == error.QueueFull) continue;
                            bus.closing = true;
                            continue;
                        };
                        sub.added = false;
                    }
                    for (self.waits) |*wait| if (wait.active and !wait.completed and wait.sub == sub)
                        try self.finish(wait, sub.failure orelse error.SubscriptionClosed);
                    // Keep an error-bearing handle until Lua observes/ closes it.
                    self.clearSubQueue(sub);
                    if (sub.resource) |resource| {
                        try self.vm.scheduler.destroyResource(resource);
                        sub.resource = null;
                    }
                    if (sub.scope) |scope| {
                        self.vm.scheduler.destroyScope(scope) catch |err| switch (err) {
                            error.ScopeNotEmpty => continue,
                            else => return err,
                        };
                        sub.scope = null;
                    }
                    if (sub.guard == null and !self.subHasWait(sub)) self.releaseSub(sub);
                }
            };
            for (&self.names) |*name| if (name.active and name.bus == bus and (name.closing or bus.closing)) {
                if (name.requested and !bus.closing) {
                    _ = daemonCall(bus, "ReleaseName", name.value) catch |err| {
                        if (err == error.QueueFull) continue;
                        bus.closing = true;
                        continue;
                    };
                    name.requested = false;
                }
                var waiting = false;
                for (self.waits) |wait| if (wait.active and wait.name == name) {
                    waiting = true;
                };
                if (!waiting) self.releaseName(name);
            };
            try bus.client.collectCanceled();
            if (bus.closing) {
                try bus.client.close();
                if (bus.client.canDeinit() and !self.busHasWait(bus)) {
                    var serving = false;
                    for (self.subscriptions) |sub| if (sub.active and sub.bus == bus and sub.scope != null) {
                        serving = true;
                    };
                    if (serving) continue;
                    for (self.subscriptions) |*sub| if (sub.active and sub.bus == bus) self.releaseSub(sub);
                    if (bus.guard) |guard| guard.* = null;
                    if (bus.resource) |resource| try self.vm.scheduler.destroyResource(resource);
                    bus.client.deinit();
                    bus.* = .{ .binding = self };
                }
            }
        };
    }

    fn route(self: *Binding, bus: *Bus, message: *wire.Message) !void {
        if (message.header.message_type == .method_call) return self.routeCall(bus, message);
        if (message.header.message_type == .signal) {
            if (optionalEqual(message.header.sender, daemon) and optionalEqual(message.header.interface, daemon) and optionalEqual(message.header.path, daemon_path) and optionalEqual(message.header.member, "NameOwnerChanged") and std.mem.eql(u8, message.header.signature, "sss")) {
                var decoder = message.bodyDecoder();
                const name = try decoder.string();
                _ = try decoder.string();
                const owner = try decoder.string();
                for (self.subscriptions) |*sub| if (sub.active and sub.bus == bus and optionalEqual(sub.sender, name)) {
                    const copy = try self.allocator.dupe(u8, owner);
                    if (sub.sender_owner) |old| self.allocator.free(old);
                    sub.sender_owner = copy;
                };
            }
            for (self.subscriptions) |*sub| if (sub.active and sub.scope == null and sub.bus == bus and sub.phase != .closing and matches(sub, message)) {
                if (sub.queue.items.len >= 64 or message.data.len > 1024 * 1024 -| sub.queued_bytes) {
                    sub.failure = error.SignalQueueOverflow;
                    sub.phase = .closing;
                    continue;
                }
                var copy = try cloneMessage(self.allocator, message);
                sub.queue.append(self.allocator, copy) catch |err| {
                    copy.deinit();
                    return err;
                };
                sub.queued_bytes += copy.data.len;
                for (self.waits) |*wait| if (wait.active and !wait.completed and wait.kind == .next and wait.sub == sub) {
                    wait.result = self.popSignal(sub);
                    try self.finish(wait, null);
                    break;
                };
            };
            return;
        }
        if (message.header.message_type != .method_return and message.header.message_type != .error_reply) return;
        const serial = message.header.reply_serial orelse return;
        if (bus.setup_serial == serial) {
            if (message.header.message_type == .error_reply) return error.MatchRegistrationFailed;
            bus.ready = true;
            return;
        }
        for (self.subscriptions) |*sub| if (sub.active and sub.bus == bus and sub.serial == serial and sub.phase != .closing) {
            if (sub.phase == .resolving) {
                if (message.header.message_type == .method_return) {
                    if (!std.mem.eql(u8, message.header.signature, "s")) return error.InvalidReply;
                    var decoder = message.bodyDecoder();
                    const owner = try self.allocator.dupe(u8, try decoder.string());
                    if (sub.sender_owner) |old| self.allocator.free(old);
                    sub.sender_owner = owner;
                } else if (!optionalEqual(message.header.error_name, "org.freedesktop.DBus.Error.NameHasNoOwner")) {
                    sub.phase = .closing;
                    sub.failure = error.MatchRegistrationFailed;
                    return;
                }
                sub.serial = try daemonCall(bus, "AddMatch", sub.rule);
                sub.added = true;
                sub.phase = .adding;
            } else if (sub.phase == .adding) {
                sub.phase = if (message.header.message_type == .method_return) .ready else .closing;
                for (self.waits) |*wait| if (wait.active and !wait.completed and wait.kind == .subscribe and wait.sub == sub) {
                    if (message.header.message_type == .error_reply) wait.result = try cloneMessage(self.allocator, message);
                    try self.finish(wait, null);
                };
            }
            return;
        };
        for (self.waits) |*wait| if (wait.active and !wait.completed and (wait.kind == .call or wait.kind == .own_name) and wait.bus == bus and wait.serial == serial) {
            wait.result = try cloneMessage(self.allocator, message);
            try self.finish(wait, null);
            return;
        };
    }

    fn finish(self: *Binding, wait: *Wait, failure: ?anyerror) !void {
        if (wait.completed) return;
        wait.failure = failure;
        wait.completed = true;
        if (wait.timer) |timer| {
            try self.loop.prepareCancel(timer);
            wait.timer = null;
        }
        try self.vm.markExternalCompleted(wait.task_handle);
    }

    fn beginWait(self: *Binding, L: *c.State, bus: *Bus, sub: ?*Subscription, kind: @FieldType(Wait, "kind"), timeout_ms: ?u32) !*Wait {
        const wait = for (self.waits) |*entry| {
            if (!entry.active) break entry;
        } else return error.CallCapacityExceeded;
        wait.* = .{ .binding = self, .active = true, .bus = bus, .sub = sub, .kind = kind };
        errdefer self.releaseWait(wait);
        wait.guard = try pushHandle(Wait, L, wait, wait_mt);
        c.lua_toclose(L, -1);
        if (timeout_ms) |ms| wait.timer = try self.loop.prepareTimeout(@as(u64, ms) * std.time.ns_per_ms);
        wait.task_handle = try self.vm.beginExternalWait(L, .operation, wait, &wait_lifecycle);
        return wait;
    }

    fn abortWait(self: *Binding, L: *c.State, wait: *Wait) void {
        self.vm.abortExternalWait(L, wait.task_handle) catch unreachable;
        self.releaseWait(wait);
    }

    fn releaseWait(self: *Binding, wait: *Wait) void {
        if (wait.timer) |timer| self.loop.prepareCancel(timer) catch {};
        if (wait.result) |*message| {
            if (message.header.message_type == .method_call)
                sendError(wait.bus, message, "org.freedesktop.DBus.Error.Failed", "Request canceled") catch {
                    wait.bus.closing = true;
                };
            message.deinit();
        }
        if (wait.guard) |guard| guard.* = null;
        wait.* = .{ .binding = self };
    }
    fn busHasWait(self: *Binding, bus: *Bus) bool {
        for (self.waits) |wait| if (wait.active and wait.bus == bus) return true;
        return false;
    }
    fn subHasWait(self: *Binding, sub: *Subscription) bool {
        for (self.waits) |wait| if (wait.active and wait.sub == sub) return true;
        return false;
    }
    fn popSignal(_: *Binding, sub: *Subscription) wire.Message {
        const message = sub.queue.orderedRemove(0);
        sub.queued_bytes -= message.data.len;
        return message;
    }
    fn clearSubQueue(self: *Binding, sub: *Subscription) void {
        for (sub.queue.items) |*message| message.deinit();
        sub.queue.deinit(self.allocator);
        sub.queue = .empty;
        sub.queued_bytes = 0;
    }
    fn releaseSub(self: *Binding, sub: *Subscription) void {
        std.debug.assert(sub.scope == null and sub.requests == 0);
        self.clearSubQueue(sub);
        if (sub.guard) |guard| guard.* = null;
        if (sub.resource) |resource| self.vm.scheduler.destroyResource(resource) catch unreachable;
        inline for (.{ "sender", "sender_owner", "path", "interface", "member" }) |field| if (@field(sub, field)) |value| self.allocator.free(value);
        self.allocator.free(sub.rule);
        for (sub.methods.items) |method| freeMethod(self.allocator, method);
        sub.methods.deinit(self.allocator);
        for (sub.signals.items) |signal| freeMethod(self.allocator, signal);
        sub.signals.deinit(self.allocator);
        sub.* = .{ .binding = self };
    }

    fn releaseName(self: *Binding, name: *Name) void {
        if (name.guard) |guard| guard.* = null;
        if (name.resource) |resource| self.vm.scheduler.destroyResource(resource) catch unreachable;
        self.allocator.free(name.value);
        name.* = .{};
    }

    fn releaseRequest(_: *Binding, request: *Request) void {
        request.sub.requests -= 1;
        if (request.guard) |guard| guard.* = null;
        request.message.deinit();
        request.* = .{};
    }

    fn pushIncoming(self: *Binding, L: *c.State, sub: *Subscription, message: *wire.Message) !void {
        const top = c.lua_gettop(L);
        values.pushMessage(L, message) catch |err| {
            if (sub.scope == null) return err;
            // A wire-valid body may exceed Lua's value/depth budget. Reject only
            // this call, not the export or its dispatcher.
            c.lua_settop(L, top);
            c.lua_createtable(L, 0, 2);
            c.lua_pushboolean(L, 1);
            c.lua_setfield(L, -2, "_decode_error");
        };
        if (sub.scope == null) return;
        const request = for (&self.requests) |*entry| {
            if (!entry.active) break entry;
        } else return error.CallCapacityExceeded;
        const method = findMethod(sub, message.header.member.?).?;
        request.* = .{ .active = true, .sub = sub, .output = method.output, .message = try cloneMessage(self.allocator, message) };
        sub.requests += 1;
        errdefer self.releaseRequest(request);
        request.guard = try pushHandle(Request, L, request, request_mt);
        c.lua_pushvalue(L, 1);
        _ = c.lua_setiuservalue(L, -2, 1);
        c.lua_setfield(L, -2, "_request");
        // Ownership of the obligation to reply moved to the request guard.
        message.header.flags |= 1;
    }

    fn routeCall(self: *Binding, bus: *Bus, message: *wire.Message) !void {
        if (bus.closing) return;
        const header = message.header;
        if (header.sender == null) return error.ProtocolError;
        var target: ?*Subscription = null;
        var known_path = false;
        for (self.subscriptions) |*sub| if (sub.active and sub.bus == bus and sub.scope != null and sub.phase == .ready and optionalEqual(header.path, sub.path.?)) {
            known_path = true;
            if (header.interface) |interface| {
                if (!std.mem.eql(u8, interface, sub.interface.?)) continue;
            } else if (findMethod(sub, header.member.?) == null) continue;
            if (target != null) return sendError(bus, message, "org.freedesktop.DBus.Error.UnknownMethod", "Ambiguous interface");
            target = sub;
        };
        if (known_path and optionalEqual(header.interface, "org.freedesktop.DBus.Introspectable") and optionalEqual(header.member, "Introspect")) {
            if (header.signature.len != 0) return sendError(bus, message, "org.freedesktop.DBus.Error.InvalidArgs", "Expected no arguments");
            return self.introspect(bus, message);
        }
        const sub = target orelse return sendError(bus, message, if (known_path) "org.freedesktop.DBus.Error.UnknownMethod" else "org.freedesktop.DBus.Error.UnknownObject", "No exported method");
        const method = findMethod(sub, header.member.?) orelse return sendError(bus, message, "org.freedesktop.DBus.Error.UnknownMethod", "No exported method");
        if (!std.mem.eql(u8, header.signature, method.input)) return sendError(bus, message, "org.freedesktop.DBus.Error.InvalidArgs", "Signature does not match method");
        var pending: usize = 0;
        for (self.subscriptions) |entry| if (entry.active and entry.scope != null) {
            pending += entry.queue.items.len + entry.requests;
        };
        var sub_pending = sub.queue.items.len + sub.requests;
        var sub_bytes = sub.queued_bytes;
        for (self.requests) |request| if (request.active and request.sub == sub) {
            sub_bytes += request.message.data.len;
        };
        for (self.waits) |wait| if (wait.active and wait.result != null and wait.result.?.header.message_type == .method_call) {
            pending += 1;
            if (wait.sub == sub) {
                sub_pending += 1;
                sub_bytes += wait.result.?.data.len;
            }
        };
        if (pending >= self.requests.len or sub_pending >= 64 or message.data.len > 1024 * 1024 -| sub_bytes)
            return sendError(bus, message, "org.freedesktop.DBus.Error.LimitsExceeded", "Too many pending requests");
        var copy = try cloneMessage(self.allocator, message);
        sub.queue.append(self.allocator, copy) catch |err| {
            copy.deinit();
            return err;
        };
        sub.queued_bytes += copy.data.len;
        for (self.waits) |*wait| if (wait.active and !wait.completed and wait.kind == .next and wait.sub == sub) {
            wait.result = self.popSignal(sub);
            try self.finish(wait, null);
            break;
        };
    }

    fn introspect(self: *Binding, bus: *Bus, message: *wire.Message) !void {
        var xml: std.Io.Writer.Allocating = .init(self.allocator);
        defer xml.deinit();
        const writer = &xml.writer;
        try writer.writeAll("<node><interface name=\"org.freedesktop.DBus.Introspectable\"><method name=\"Introspect\"><arg type=\"s\" direction=\"out\"/></method></interface>");
        for (self.subscriptions) |sub| if (sub.active and sub.bus == bus and sub.scope != null and sub.phase == .ready and optionalEqual(message.header.path, sub.path.?)) {
            try writer.print("<interface name=\"{s}\">", .{sub.interface.?});
            for (sub.methods.items) |method| {
                try writer.print("<method name=\"{s}\">", .{method.name});
                try xmlArgs(writer, method.input, "in");
                try xmlArgs(writer, method.output, "out");
                try writer.writeAll("</method>");
            }
            for (sub.signals.items) |signal| {
                try writer.print("<signal name=\"{s}\">", .{signal.name});
                try xmlArgs(writer, signal.input, "out");
                try writer.writeAll("</signal>");
            }
            try writer.writeAll("</interface>");
        };
        try writer.writeAll("</node>");
        var encoded = wire.Encoder.init(self.allocator);
        defer encoded.deinit();
        try encoded.string(xml.written());
        try sendReturn(bus, message, "s", encoded.bytes(), &.{});
    }
};

fn findMethod(sub: *const Subscription, member: []const u8) ?Method {
    for (sub.methods.items) |method| if (std.mem.eql(u8, method.name, member)) return method;
    return null;
}
fn freeMethod(allocator: std.mem.Allocator, method: Method) void {
    allocator.free(method.name);
    allocator.free(method.input);
    allocator.free(method.output);
}
fn readMethod(allocator: std.mem.Allocator, L: *c.State, signal: bool) !Method {
    const member = try string(L, -2);
    if (!validMatchValue("member", member)) return error.InvalidMethod;
    const input = if (signal) try string(L, -1) else try stringField(L, c.lua_gettop(L), "input");
    const output = if (signal) "" else try stringField(L, c.lua_gettop(L), "output");
    if (!wire.validSignature(input, true) or !wire.validSignature(output, true)) return error.InvalidSignature;
    const name = try allocator.dupe(u8, member);
    errdefer allocator.free(name);
    const owned_input = try allocator.dupe(u8, input);
    errdefer allocator.free(owned_input);
    return .{ .name = name, .input = owned_input, .output = try allocator.dupe(u8, output) };
}
fn xmlArgs(writer: *std.Io.Writer, signature: []const u8, direction: []const u8) !void {
    var start: usize = 0;
    while (start < signature.len) {
        const end = try wire.signatureEnd(signature, start, false);
        try writer.print("<arg type=\"{s}\" direction=\"{s}\"/>", .{ signature[start..end], direction });
        start = end;
    }
}
fn sendReturn(bus: *Bus, message: *const wire.Message, signature: []const u8, body: []const u8, fds: []const linux.fd_t) !void {
    if (bus.closing or message.header.flags & 1 != 0) return;
    _ = try bus.client.send(.{ .message_type = .method_return, .destination = message.header.sender, .reply_serial = message.header.serial, .signature = signature }, body, fds);
}
fn sendError(bus: *Bus, message: *const wire.Message, name: []const u8, detail: []const u8) !void {
    if (bus.closing or message.header.flags & 1 != 0) return;
    var encoder = wire.Encoder.init(bus.binding.allocator);
    defer encoder.deinit();
    try encoder.string(detail);
    _ = try bus.client.send(.{ .message_type = .error_reply, .destination = message.header.sender, .reply_serial = message.header.serial, .error_name = name, .signature = "s" }, encoder.bytes(), &.{});
}
fn exportLua(L: *c.State) callconv(.c) c_int {
    exportImpl(L) catch |err| return localError(L, err);
    return 1;
}
fn exportImpl(L: *c.State) !void {
    const bus = try getHandle(Bus, L, 1, bus_mt);
    if (!bus.ready or bus.closing) return error.ConnectionClosed;
    const self = bus.binding;
    const parent = try self.vm.currentScope(L);
    const path = try stringField(L, 2, "path");
    const interface = try stringField(L, 2, "interface");
    if (!wire.validObjectPath(path) or !validMatchValue("interface", interface)) return error.InvalidExport;
    if (std.mem.eql(u8, interface, "org.freedesktop.DBus.Introspectable")) return error.ReservedInterface;
    for (self.subscriptions) |sub| if (sub.active and sub.bus == bus and sub.scope != null and sub.phase != .closing and optionalEqual(sub.path, path) and optionalEqual(sub.interface, interface)) return error.AlreadyExported;
    const sub = for (self.subscriptions) |*entry| {
        if (!entry.active) break entry;
    } else return error.SubscriptionCapacityExceeded;
    sub.* = .{ .binding = self, .bus = bus, .active = true, .phase = .ready };
    errdefer self.releaseSub(sub);
    sub.path = try self.allocator.dupe(u8, path);
    sub.interface = try self.allocator.dupe(u8, interface);
    inline for (.{ "methods", "signals" }) |field| {
        _ = c.lua_getfield(L, 2, field);
        const index = c.lua_gettop(L);
        if (c.lua_type(L, index) != c.type_table) return error.InvalidExport;
        c.lua_pushnil(L);
        while (c.lua_next(L, index) != 0) {
            if (@field(sub, field).items.len >= 128) return error.MethodCapacityExceeded;
            const method = try readMethod(self.allocator, L, std.mem.eql(u8, field, "signals"));
            @field(sub, field).append(self.allocator, method) catch |err| {
                freeMethod(self.allocator, method);
                return err;
            };
            c.lua_settop(L, -2);
        }
        c.lua_settop(L, -2);
    }
    sub.guard = try pushHandle(Subscription, L, sub, export_mt);
    c.lua_pushvalue(L, 1);
    _ = c.lua_setiuservalue(L, -2, 1);
    const scope = try self.vm.scheduler.createScope(parent);
    sub.scope = scope;
    errdefer {
        self.vm.scheduler.destroyScope(scope) catch unreachable;
        sub.scope = null;
    }
    sub.resource = try self.vm.scheduler.registerResource(parent, .service, sub, &sub_lifecycle);
    c.lua_pushvalue(L, 3);
    const dispatcher = c.luaL_ref(L, c.registry_index);
    defer c.luaL_unref(L, c.registry_index, dispatcher);
    c.lua_pushvalue(L, -1);
    const stream = c.luaL_ref(L, c.registry_index);
    defer c.luaL_unref(L, c.registry_index, stream);
    _ = try self.vm.spawnReference(scope, dispatcher, &.{.{ .registry = stream }});
}
fn replyLua(L: *c.State) callconv(.c) c_int {
    replyImpl(L) catch |err| return localError(L, err);
    c.lua_pushboolean(L, 1);
    return 1;
}
fn replyImpl(L: *c.State) !void {
    const request = try getHandle(Request, L, 1, request_mt);
    const bus = request.sub.bus;
    if (bus.closing or request.sub.phase == .closing) return error.ConnectionClosed;
    var encoded = try values.encode(L, 2, request.output, bus.binding.allocator);
    defer encoded.deinit();
    try sendReturn(bus, &request.message, request.output, encoded.body, encoded.fds);
    bus.binding.releaseRequest(request);
}
fn errorLua(L: *c.State) callconv(.c) c_int {
    errorImpl(L) catch |err| return localError(L, err);
    c.lua_pushboolean(L, 1);
    return 1;
}
fn errorImpl(L: *c.State) !void {
    const request = try getHandle(Request, L, 1, request_mt);
    const name = try string(L, 2);
    const detail = try string(L, 3);
    if (!validMatchValue("interface", name)) return error.InvalidErrorName;
    try sendError(request.sub.bus, &request.message, name, detail);
    request.sub.binding.releaseRequest(request);
}
fn closeRequestLua(L: *c.State) callconv(.c) c_int {
    const guard = handlePointer(Request, L, 1, request_mt) orelse return 0;
    if (guard.*) |request| {
        const bus = request.sub.bus;
        sendError(bus, &request.message, "org.freedesktop.DBus.Error.Failed", "Handler did not return a valid reply") catch {
            bus.closing = true;
        };
        bus.binding.releaseRequest(request);
    }
    return 0;
}
fn emitLua(L: *c.State) callconv(.c) c_int {
    emitImpl(L) catch |err| return localError(L, err);
    c.lua_pushboolean(L, 1);
    return 1;
}
fn emitImpl(L: *c.State) !void {
    if (c.lua_gettop(L) != 2 or c.lua_type(L, 2) != c.type_table) return error.InvalidSignal;
    const bus = try getHandle(Bus, L, 1, bus_mt);
    if (!bus.ready or bus.closing) return error.ConnectionClosed;
    _ = try bus.binding.vm.currentScope(L);
    var metadata: wire.Metadata = .{ .message_type = .signal, .path = try stringField(L, 2, "path"), .interface = try stringField(L, 2, "interface"), .member = try stringField(L, 2, "member"), .signature = try stringField(L, 2, "signature") };
    if (!validMatchValue("interface", metadata.interface.?) or !validMatchValue("member", metadata.member.?)) return error.InvalidSignal;
    _ = c.lua_getfield(L, 2, "destination");
    if (c.lua_type(L, -1) != c.type_nil) {
        metadata.destination = try string(L, -1);
        if (!validMatchValue("sender", metadata.destination.?)) return error.InvalidSignal;
    }
    c.lua_settop(L, -2);
    _ = c.lua_getfield(L, 2, "args");
    var encoded = try values.encode(L, -1, metadata.signature, bus.binding.allocator);
    defer encoded.deinit();
    _ = try bus.client.send(metadata, encoded.body, encoded.fds);
}
fn ownName(L: *c.State) callconv(.c) c_int {
    const wait = ownNameImpl(L) catch |err| return localError(L, err);
    return yieldWait(L, wait);
}
fn ownNameImpl(L: *c.State) !*Wait {
    if (c.lua_gettop(L) != 2) return error.InvalidArguments;
    const bus = try getHandle(Bus, L, 1, bus_mt);
    if (!bus.ready or bus.closing) return error.ConnectionClosed;
    const self = bus.binding;
    const scope = try self.vm.currentScope(L);
    const value = try string(L, 2);
    if (!validMatchValue("sender", value) or value[0] == ':' or std.mem.eql(u8, value, daemon)) return error.InvalidBusName;
    for (self.names) |name| if (name.active and name.bus == bus and std.mem.eql(u8, name.value, value)) return error.NameAlreadyRequested;
    const name = for (&self.names) |*entry| {
        if (!entry.active) break entry;
    } else return error.NameCapacityExceeded;
    name.* = .{ .active = true, .bus = bus };
    errdefer self.releaseName(name);
    name.value = try self.allocator.dupe(u8, value);
    name.guard = try pushHandle(Name, L, name, name_mt);
    c.lua_pushvalue(L, 1);
    _ = c.lua_setiuservalue(L, -2, 1);
    name.resource = try self.vm.scheduler.registerResource(scope, .service, name, &name_lifecycle);
    var encoder = wire.Encoder.init(self.allocator);
    defer encoder.deinit();
    try encoder.string(value);
    try encoder.uint32(4); // DO_NOT_QUEUE: never replace an existing daemon.
    const wait = try self.beginWait(L, bus, null, .own_name, 2000);
    errdefer self.abortWait(L, wait);
    wait.name = name;
    wait.serial = try bus.client.send(.{ .message_type = .method_call, .destination = daemon, .path = daemon_path, .interface = daemon, .member = "RequestName", .signature = "su" }, encoder.bytes(), &.{});
    name.requested = true;
    return wait;
}
fn closeNameLua(L: *c.State) callconv(.c) c_int {
    const guard = handlePointer(Name, L, 1, name_mt) orelse return localError(L, error.InvalidHandle);
    if (guard.*) |name| {
        name.closing = true;
        name.guard = null;
        guard.* = null;
    }
    return 0;
}
fn cancelName(pointer: *anyopaque) !void {
    const name: *Name = @ptrCast(@alignCast(pointer));
    name.closing = true;
}
const name_lifecycle: task.ResourceLifecycle = .{ .request_cancel = cancelName, .destroy = destroyResource };

fn connect(L: *c.State) callconv(.c) c_int {
    const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
    const wait = connectImpl(self, L) catch |err| return localError(L, err);
    return yieldWait(L, wait);
}
fn connectImpl(self: *Binding, L: *c.State) !*Wait {
    if (c.lua_gettop(L) != 1) return error.InvalidArguments;
    if (self.stopping) return error.ConnectionClosed;
    const scope = try self.vm.currentScope(L);
    const target = try string(L, 1);
    const address = if (std.mem.eql(u8, target, "session")) self.session_address orelse return error.AddressUnavailable else if (std.mem.eql(u8, target, "system")) self.system_address else target;
    const bus = for (self.buses) |*entry| {
        if (!entry.active) break entry;
    } else return error.ConnectionCapacityExceeded;
    bus.* = .{ .binding = self };
    bus.guard = try pushHandle(Bus, L, bus, bus_mt);
    errdefer {
        if (bus.guard) |guard| guard.* = null;
        bus.guard = null;
    }
    const wait = try self.beginWait(L, bus, null, .connect, 2000);
    errdefer self.abortWait(L, wait);
    bus.resource = try self.vm.scheduler.registerResource(scope, .service, bus, &bus_lifecycle);
    errdefer {
        self.vm.scheduler.destroyResource(bus.resource.?) catch unreachable;
        bus.resource = null;
        if (bus.guard) |guard| guard.* = null;
    }
    try bus.client.init(self.allocator, self.loop, address);
    bus.active = true;
    return wait;
}

fn call(L: *c.State) callconv(.c) c_int {
    const wait = callImpl(L) catch |err| return localError(L, err);
    return yieldWait(L, wait);
}
fn callImpl(L: *c.State) !*Wait {
    if (c.lua_gettop(L) != 2) return error.InvalidArguments;
    const bus = try getHandle(Bus, L, 1, bus_mt);
    if (!bus.ready or bus.closing) return error.ConnectionClosed;
    const self = bus.binding;
    _ = try self.vm.currentScope(L);
    if (c.lua_type(L, 2) != c.type_table) return error.InvalidCall;
    const metadata: wire.Metadata = .{ .message_type = .method_call, .destination = try stringField(L, 2, "destination"), .path = try stringField(L, 2, "path"), .interface = try stringField(L, 2, "interface"), .member = try stringField(L, 2, "member"), .signature = try stringField(L, 2, "signature") };
    try validateMetadata(metadata);
    const timeout = try timeoutField(L, 2);
    _ = c.lua_getfield(L, 2, "args");
    var encoded = try values.encode(L, -1, metadata.signature, self.allocator);
    defer encoded.deinit();
    c.lua_settop(L, -2);
    const wait = try self.beginWait(L, bus, null, .call, timeout);
    wait.serial = bus.client.send(metadata, encoded.body, encoded.fds) catch |err| {
        self.abortWait(L, wait);
        return err;
    };
    return wait;
}
fn yieldWait(L: *c.State, wait: *Wait) c_int {
    // Allocation-owning helpers have returned and run their defers before
    // lua_yieldk longjmps out of the C entrypoint.
    return c.lua_yieldk(L, 0, @intCast(@intFromPtr(wait)), continuation);
}

fn subscribe(L: *c.State) callconv(.c) c_int {
    const wait = subscribeImpl(L) catch |err| return localError(L, err);
    return yieldWait(L, wait);
}
fn subscribeImpl(L: *c.State) !*Wait {
    if (c.lua_gettop(L) != 2) return error.InvalidArguments;
    const bus = try getHandle(Bus, L, 1, bus_mt);
    if (!bus.ready or bus.closing) return error.ConnectionClosed;
    const self = bus.binding;
    const scope = try self.vm.currentScope(L);
    if (c.lua_type(L, 2) != c.type_table) return error.InvalidMatch;
    const sub = for (self.subscriptions) |*entry| {
        if (!entry.active) break entry;
    } else return error.SubscriptionCapacityExceeded;
    sub.* = .{ .binding = self, .bus = bus, .active = true };
    errdefer self.releaseSub(sub);
    inline for (.{ "sender", "path", "interface", "member" }) |field| {
        _ = c.lua_getfield(L, 2, field);
        if (c.lua_type(L, -1) != c.type_nil) {
            const value = try string(L, -1);
            if (!validMatchValue(field, value)) return error.InvalidMatch;
            @field(sub, field) = try self.allocator.dupe(u8, value);
        }
        c.lua_settop(L, -2);
    }
    var rule: std.Io.Writer.Allocating = .init(self.allocator);
    defer rule.deinit();
    try rule.writer.writeAll("type='signal'");
    inline for (.{ "sender", "path", "interface", "member" }) |field| if (@field(sub, field)) |value|
        try rule.writer.print(",{s}='{s}'", .{ field, value });
    sub.rule = try self.allocator.dupe(u8, rule.written());
    sub.guard = try pushHandle(Subscription, L, sub, sub_mt);
    // A stream keeps its connection reachable even if Lua drops the original
    // bus variable. Explicit close and scope disposal still close both.
    c.lua_pushvalue(L, 1);
    _ = c.lua_setiuservalue(L, -2, 1);
    sub.resource = try self.vm.scheduler.registerResource(scope, .service, sub, &sub_lifecycle);
    const wait = try self.beginWait(L, bus, sub, .subscribe, 2000);
    errdefer self.abortWait(L, wait);
    if (sub.sender) |sender| {
        if (sender[0] == ':' or std.mem.eql(u8, sender, daemon)) {
            sub.sender_owner = try self.allocator.dupe(u8, sender);
            sub.phase = .adding;
        } else sub.phase = .resolving;
    } else sub.phase = .adding;
    sub.serial = if (sub.phase == .resolving) try daemonCall(bus, "GetNameOwner", sub.sender.?) else try daemonCall(bus, "AddMatch", sub.rule);
    sub.added = sub.phase == .adding;
    return wait;
}

fn next(L: *c.State) callconv(.c) c_int {
    const wait = nextImpl(L) catch |err| return localError(L, err);
    return if (wait) |pending| yieldWait(L, pending) else 1;
}
fn nextImpl(L: *c.State) !?*Wait {
    const guard = handlePointer(Subscription, L, 1, sub_mt) orelse handlePointer(Subscription, L, 1, export_mt) orelse return error.InvalidHandle;
    const sub = guard.* orelse return error.Closed;
    const self = sub.binding;
    _ = try self.vm.currentScope(L);
    if (sub.phase == .closing) return sub.failure orelse error.SubscriptionClosed;
    if (self.subHasWait(sub)) return error.SubscriptionAlreadyWaiting;
    if (sub.queue.items.len != 0) {
        var message = self.popSignal(sub);
        defer message.deinit();
        errdefer if (sub.scope != null) {
            sendError(sub.bus, &message, "org.freedesktop.DBus.Error.Failed", "Cannot decode request") catch {
                sub.bus.closing = true;
            };
            sub.phase = .closing;
        };
        try self.pushIncoming(L, sub, &message);
        return null;
    }
    const wait = try self.beginWait(L, sub.bus, sub, .next, null);
    return wait;
}

fn continuation(L: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const wait: *Wait = @ptrFromInt(@as(usize, @intCast(context)));
    return continueImpl(L, wait) catch |err| localError(L, err);
}
fn continueImpl(L: *c.State, wait: *Wait) !c_int {
    defer wait.binding.releaseWait(wait);
    errdefer if (wait.name) |name| {
        name.closing = true;
    };
    if (wait.failure) |err| return localError(L, err);
    if (wait.kind == .own_name) {
        const name = wait.name.?;
        const message = if (wait.result) |*message| message else return error.MissingReply;
        if (message.header.message_type != .error_reply) {
            if (!std.mem.eql(u8, message.header.signature, "u")) return error.InvalidReply;
            var decoder = message.bodyDecoder();
            if (try decoder.uint32() != 1) {
                name.requested = false;
                return error.NameUnavailable;
            }
            c.lua_pushvalue(L, 3);
            return 1;
        }
        name.closing = true;
    }
    if (wait.result) |*message| {
        if (message.header.message_type == .method_call) {
            if (wait.sub.?.phase == .closing) return error.SubscriptionClosed;
            try wait.binding.pushIncoming(L, wait.sub.?, message);
            return 1;
        }
        if (message.header.message_type == .error_reply) {
            c.lua_pushnil(L);
            try values.pushMessage(L, message);
            setString(L, "kind", "remote");
            setString(L, "name", message.header.error_name.?);
            var decoder = message.bodyDecoder();
            const detail = if (message.header.signature.len != 0 and message.header.signature[0] == 's') try decoder.string() else message.header.error_name.?;
            setString(L, "message", detail);
            return 2;
        }
        try values.pushMessage(L, message);
        return 1;
    }
    if (wait.kind == .connect) c.lua_pushvalue(L, 2) else if (wait.kind == .subscribe) c.lua_pushvalue(L, 3) else return error.MissingReply;
    return 1;
}

fn closeBusLua(L: *c.State) callconv(.c) c_int {
    const guard = handlePointer(Bus, L, 1, bus_mt) orelse return localError(L, error.InvalidConnection);
    if (guard.*) |bus| {
        bus.closing = true;
        bus.guard = null;
        guard.* = null;
    }
    return 0;
}
fn closeSubLua(L: *c.State) callconv(.c) c_int {
    const guard = handlePointer(Subscription, L, 1, sub_mt) orelse handlePointer(Subscription, L, 1, export_mt) orelse return localError(L, error.InvalidSubscription);
    if (guard.*) |sub| {
        sub.phase = .closing;
        sub.guard = null;
        guard.* = null;
    }
    return 0;
}
fn closeWaitLua(L: *c.State) callconv(.c) c_int {
    const guard = handlePointer(Wait, L, 1, wait_mt) orelse return 0;
    if (guard.*) |wait| {
        if (wait.name) |name| name.closing = true;
        if (wait.completed) wait.binding.releaseWait(wait) else {
            wait.canceled = true;
            wait.guard = null;
            guard.* = null;
        }
    }
    return 0;
}

fn cancelBus(pointer: *anyopaque) !void {
    const bus: *Bus = @ptrCast(@alignCast(pointer));
    bus.closing = true;
}
fn cancelSub(pointer: *anyopaque) !void {
    const sub: *Subscription = @ptrCast(@alignCast(pointer));
    sub.phase = .closing;
}
fn cancelWait(pointer: *anyopaque) !void {
    const wait: *Wait = @ptrCast(@alignCast(pointer));
    wait.canceled = true;
}
fn destroyResource(_: *anyopaque) void {}
const bus_lifecycle: task.ResourceLifecycle = .{ .request_cancel = cancelBus, .destroy = destroyResource };
const sub_lifecycle: task.ResourceLifecycle = .{ .request_cancel = cancelSub, .destroy = destroyResource };
const wait_lifecycle: task.ResourceLifecycle = .{ .request_cancel = cancelWait, .destroy = destroyResource };

fn daemonCall(bus: *Bus, member: []const u8, argument: []const u8) !u32 {
    var encoder = wire.Encoder.init(bus.binding.allocator);
    defer encoder.deinit();
    try encoder.string(argument);
    return bus.client.send(.{ .message_type = .method_call, .destination = daemon, .path = daemon_path, .interface = daemon, .member = member, .signature = "s" }, encoder.bytes(), &.{});
}
fn cloneMessage(allocator: std.mem.Allocator, message: *const wire.Message) !wire.Message {
    const data = try allocator.dupe(u8, message.data);
    errdefer allocator.free(data);
    const fds = try allocator.alloc(linux.fd_t, message.fds.len);
    var count: usize = 0;
    errdefer {
        for (fds[0..count]) |fd| _ = linux.close(fd);
        allocator.free(fds);
    }
    for (message.fds) |fd| {
        const result = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(result) != .SUCCESS) return error.InvalidFileDescriptor;
        fds[count] = @intCast(result);
        count += 1;
    }
    return wire.parseMessage(allocator, data, fds);
}
fn matches(sub: *Subscription, message: *const wire.Message) bool {
    if (sub.sender != null and (sub.sender_owner == null or !optionalEqual(message.header.sender, sub.sender_owner.?))) return false;
    inline for (.{ "path", "interface", "member" }) |field| if (@field(sub, field)) |value| {
        if (!optionalEqual(@field(message.header, field), value)) return false;
    };
    return true;
}
fn optionalEqual(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |text| std.mem.eql(u8, text, expected) else false;
}
fn same(a: io.OperationHandle, b: io.OperationHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
fn installMetatable(L: *c.State, name: [*:0]const u8, methods: []const struct { [*:0]const u8, c.CFunction }) void {
    _ = c.luaL_newmetatable(L, name);
    for (methods) |method| {
        c.lua_pushcclosure(L, method[1], 0);
        c.lua_setfield(L, -2, method[0]);
    }
    c.lua_pushvalue(L, -1);
    c.lua_setfield(L, -2, "__index");
    c.lua_settop(L, -2);
}
fn pushHandle(comptime T: type, L: *c.State, value: *T, mt: [*:0]const u8) !*?*T {
    const guard: *?*T = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(?*T), if (T == Subscription or T == Request or T == Name) 1 else 0) orelse return error.OutOfMemory));
    guard.* = value;
    _ = c.luaL_newmetatable(L, mt);
    _ = c.lua_setmetatable(L, -2);
    return guard;
}
fn handlePointer(comptime T: type, L: *c.State, index: c_int, mt: [*:0]const u8) ?*?*T {
    return @ptrCast(@alignCast(c.luaL_testudata(L, index, mt)));
}
fn getHandle(comptime T: type, L: *c.State, index: c_int, mt: [*:0]const u8) !*T {
    const guard = handlePointer(T, L, index, mt) orelse return error.InvalidHandle;
    return guard.* orelse error.Closed;
}
fn string(L: *c.State, index: c_int) ![]const u8 {
    if (c.lua_type(L, index) != c.type_string) return error.ExpectedString;
    var length: usize = 0;
    const pointer = c.lua_tolstring(L, index, &length) orelse return error.ExpectedString;
    return pointer[0..length];
}
fn stringField(L: *c.State, index: c_int, name: [*:0]const u8) ![]const u8 {
    _ = c.lua_getfield(L, index, name);
    defer c.lua_settop(L, -2);
    return string(L, -1);
}
fn timeoutField(L: *c.State, index: c_int) !u32 {
    _ = c.lua_getfield(L, index, "timeout_ms");
    defer c.lua_settop(L, -2);
    if (c.lua_type(L, -1) == c.type_nil) return 25000;
    if (c.lua_isinteger(L, -1) == 0) return error.InvalidTimeout;
    var valid: c_int = 0;
    const number = c.lua_tointegerx(L, -1, &valid);
    if (number < 1 or number > 2147483647) return error.InvalidTimeout;
    return @intCast(number);
}
fn localError(L: *c.State, err: anyerror) c_int {
    c.lua_pushnil(L);
    c.lua_createtable(L, 0, 3);
    setString(L, "kind", if (err == error.Timeout) "timeout" else if (err == error.SignalQueueOverflow) "overflow" else "local");
    setString(L, "name", @errorName(err));
    setString(L, "message", @errorName(err));
    return 2;
}
fn setString(L: *c.State, name: [*:0]const u8, value: []const u8) void {
    _ = c.lua_pushlstring(L, value.ptr, value.len);
    c.lua_setfield(L, -2, name);
}
fn validMatchValue(comptime field: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, field, "path")) return wire.validObjectPath(value);
    if (value.len == 0 or value.len > 255) return false;
    const bus_name = std.mem.eql(u8, field, "sender");
    const unique = bus_name and value[0] == ':';
    const member = std.mem.eql(u8, field, "member");
    var parts = std.mem.splitScalar(u8, value[@intFromBool(unique)..], '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (part.len == 0 or (!unique and std.ascii.isDigit(part[0]))) return false;
        for (part) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and !(bus_name and byte == '-')) return false;
    }
    return if (member) count == 1 else count >= 2;
}
fn validateMetadata(metadata: wire.Metadata) !void {
    if (!validMatchValue("sender", metadata.destination.?) or !validMatchValue("interface", metadata.interface.?) or !validMatchValue("member", metadata.member.?)) return error.InvalidCall;
}
fn sessionAddress(allocator: std.mem.Allocator, directory: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("unix:path=");
    for (directory) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '_' or byte == '-' or byte == '.') try writer.writer.writeByte(byte) else try writer.writer.print("%{X:0>2}", .{byte});
    }
    try writer.writer.writeAll("/bus");
    return allocator.dupe(u8, writer.written());
}

test "D-Bus Lua invalid addresses and cancellation release scoped connections" {
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();
    try app.prepareScript(
        \\local d = require('ouro').dbus
        \\local bus, err = d.connect('tcp:host=localhost')
        \\assert(bus == nil and err.name == 'AddressUnavailable')
        \\invalid_done = true
    );
    try runTestApp(&app);
    try std.testing.expect(app.lua_vm.globalBoolean("invalid_done"));
    try app.prepareScript("local bus = require('ouro').dbus.connect('unix:abstract=ouro_dbus_absent'); canceled_after = true");
    try app.runReadyTurn();
    try app.scheduler.queueScopeCancellation(app.scheduler.application_scope);
    try drainTestApp(&app);
    try std.testing.expect(!app.lua_vm.globalBoolean("canceled_after"));
}

test "D-Bus Lua live bus multiplexes calls signals and remote errors" {
    if (std.testing.environ.getPosix("OURO_DBUS_INTEGRATION") == null) return error.SkipZigTest;
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.initWithEnvironment(std.testing.allocator, std.testing.environ);
    defer app.deinit();
    defer drainTestApp(&app) catch {};
    try app.prepareScript(
        \\local ouro = require('ouro')
        \\local bus, err = ouro.dbus.connect('session')
        \\assert(bus, err and err.message)
        \\local function invoke(member, signature, args)
        \\  return bus:call { destination='org.freedesktop.DBus', path='/org/freedesktop/DBus', interface='org.freedesktop.DBus', member=member, signature=signature, args=args }
        \\end
        \\local stream = assert(bus:subscribe { sender='org.freedesktop.DBus', interface='org.freedesktop.DBus', member='NameOwnerChanged' })
        \\local results = 0
        \\for i=1,3 do ouro.spawn(function()
        \\  local reply = assert(invoke('ListNames', '', {}))
        \\  assert(reply.signature == 'as' and #reply.args[1] >= 2)
        \\  results = results + 1
        \\end) end
        \\local reply = assert(invoke('RequestName', 'su', {'dev.ourokit.DbusTest', 4}))
        \\assert(reply.signature == 'u' and reply.args[1] == 1)
        \\local signal = assert(stream:next())
        \\assert(signal.sender == 'org.freedesktop.DBus' and signal.signature == 'sss')
        \\assert(signal.args[1] == 'dev.ourokit.DbusTest' and signal.args[2] == '' and signal.args[3]:sub(1,1) == ':')
        \\local missing, failure = invoke('DoesNotExist', '', {})
        \\assert(missing == nil and failure.kind == 'remote')
        \\assert(failure.name == 'org.freedesktop.DBus.Error.UnknownMethod' and failure.signature == 's')
        \\assert(results == 3)
        \\local exported = assert(bus:export {path='/test', interface='dev.ourokit.Test', methods={
        \\  Unanswered={input='', output='', handler=function() ouro.sleep(10000); return {} end},
        \\}})
        \\local timed, deadline = bus:call {destination='dev.ourokit.DbusTest', path='/test', interface='dev.ourokit.Test', member='Unanswered', signature='', args={}, timeout_ms=10}
        \\assert(timed == nil and deadline.kind == 'timeout')
        \\assert(invoke('ListNames', '', {})) -- Timing out did not close the shared bus.
        \\stream:close()
        \\bus:close()
        \\live_done = true
    );
    try runTestApp(&app);
    try std.testing.expect(app.lua_vm.globalBoolean("live_done"));
}

test "D-Bus Lua live scope cancellation detaches a waiter without closing a shared bus" {
    if (std.testing.environ.getPosix("OURO_DBUS_INTEGRATION") == null) return error.SkipZigTest;
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.initWithEnvironment(std.testing.allocator, std.testing.environ);
    defer app.deinit();
    defer drainTestApp(&app) catch {};
    try app.prepareScript(
        \\bus = assert(require('ouro').dbus.connect('session'))
        \\local reply = assert(bus:call {destination='org.freedesktop.DBus', path='/org/freedesktop/DBus', interface='org.freedesktop.DBus', member='RequestName', signature='su', args={'dev.ourokit.CancelTest', 4}})
        \\assert(reply.args[1] == 1)
        \\stream = assert(bus:subscribe {sender='dev.ourokit.NotRunning', interface='dev.ourokit.Test', member='Never'})
    );
    try runTestApp(&app);
    const scope = try app.scheduler.createScope(app.scheduler.application_scope);
    _ = try app.lua_vm.spawn(scope,
        \\local reply = bus:call {destination='dev.ourokit.CancelTest', path='/test', interface='dev.ourokit.Test', member='Unanswered', signature='', args={}}
        \\call_after_cancel = true
    );
    _ = try app.lua_vm.spawn(scope, "stream:next(); next_after_cancel = true");
    try app.runReadyTurn();
    try app.scheduler.queueScopeCancellation(scope);
    try app.runReadyTurn();
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 0), app.lua_vm.activeTaskCount());
    try std.testing.expect(!app.lua_vm.globalBoolean("call_after_cancel"));
    try std.testing.expect(!app.lua_vm.globalBoolean("next_after_cancel"));
    try app.scheduler.destroyScope(scope);
    try app.prepareScript(
        \\local reply = assert(bus:call {destination='org.freedesktop.DBus', path='/org/freedesktop/DBus', interface='org.freedesktop.DBus', member='ListNames', signature='', args={}})
        \\assert(reply.signature == 'as')
        \\stream:close(); bus:close()
        \\shared_survived = true
    );
    try runTestApp(&app);
    try std.testing.expect(app.lua_vm.globalBoolean("shared_survived"));
}

test "D-Bus service routing bounds pending calls and honors no-reply headers" {
    const a = std.testing.allocator;
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.init(a);
    defer app.deinit();
    const binding = &app.dbus;
    // Exercise routing without a socket or bus daemon. send only queues frames.
    var bus: Bus = .{ .binding = binding, .ready = true, .client = .{ .allocator = a, .phase = .ready } };
    defer {
        bus.client.phase = .closed;
        bus.client.deinit();
    }
    const sub = &binding.subscriptions[0];
    sub.* = .{ .binding = binding, .active = true, .bus = &bus, .phase = .ready, .scope = app.scheduler.application_scope };
    defer {
        sub.scope = null;
        binding.releaseSub(sub);
    }
    sub.path = try a.dupe(u8, "/test");
    sub.interface = try a.dupe(u8, "dev.ourokit.Test");
    try sub.methods.append(a, .{ .name = try a.dupe(u8, "Empty"), .input = try a.dupe(u8, ""), .output = try a.dupe(u8, "") });
    const bytes = try wire.encodeMessage(a, .{ .message_type = .method_call, .sender = ":1.42", .path = "/test", .member = "Empty" }, 917, &.{}, 0);
    var message = try wire.parseMessage(a, bytes, &.{});
    defer message.deinit();
    // Omitting the interface is valid when the member resolves unambiguously.
    for (0..64) |_| try binding.routeCall(&bus, &message);
    try std.testing.expectEqual(@as(usize, 64), sub.queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), bus.client.outgoing.items.len);
    try binding.routeCall(&bus, &message);
    try std.testing.expectEqual(@as(usize, 64), sub.queue.items.len);
    var reply = try wire.parseMessage(a, bus.client.outgoing.items[0].bytes, &.{});
    try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.LimitsExceeded", reply.header.error_name.?);
    try std.testing.expectEqual(@as(u32, 917), reply.header.reply_serial.?);
    try std.testing.expectEqualStrings(":1.42", reply.header.destination.?);
    binding.clearSubQueue(sub);
    // The byte limit applies at equality, and includes requests held by handlers.
    binding.requests[0] = .{ .active = true, .sub = sub, .message = try cloneMessage(a, &message) };
    sub.requests = 1;
    sub.queued_bytes = 1024 * 1024 - 2 * message.data.len;
    try binding.routeCall(&bus, &message);
    try std.testing.expectEqual(@as(usize, 1), sub.queue.items.len);
    try binding.routeCall(&bus, &message);
    try std.testing.expectEqual(@as(usize, 1), sub.queue.items.len);
    try std.testing.expectEqual(@as(usize, 2), bus.client.outgoing.items.len);
    binding.releaseRequest(&binding.requests[0]);
    binding.clearSubQueue(sub);
    message.header.flags = 1;
    try binding.routeCall(&bus, &message);
    try std.testing.expectEqual(@as(usize, 1), sub.queue.items.len); // Still dispatched.
    try sendReturn(&bus, &message, "", &.{}, &.{});
    try sendError(&bus, &message, "dev.ourokit.Error", "ignored");
    try std.testing.expectEqual(@as(usize, 2), bus.client.outgoing.items.len);
    message.header.flags = 0;
    try sendReturn(&bus, &message, "", &.{}, &.{});
    reply = try wire.parseMessage(a, bus.client.outgoing.items[2].bytes, &.{});
    try std.testing.expectEqual(wire.MessageType.method_return, reply.header.message_type);
    try std.testing.expectEqual(@as(u32, 917), reply.header.reply_serial.?);
    try std.testing.expectEqualStrings(":1.42", reply.header.destination.?);
}

test "D-Bus Lua live exports yield reply emit and cancel" {
    if (std.testing.environ.getPosix("OURO_DBUS_INTEGRATION") == null) return error.SkipZigTest;
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.initWithEnvironment(std.testing.allocator, std.testing.environ);
    defer app.deinit();
    defer drainTestApp(&app) catch {};
    try app.prepareScript(@embedFile("dbus_service_test.lua"));
    try runTestApp(&app);
    try std.testing.expect(app.lua_vm.globalBoolean("service_done"));
}

fn runTestApp(app: *@import("../app/app.zig").App) !void {
    while (app.lua_vm.activeTaskCount() != 0) {
        try app.runReadyTurn();
        if (app.lua_vm.activeTaskCount() == 0) break;
        if (!app.scheduler.hasPendingWork()) try app.reapOne();
    }
}
fn drainTestApp(app: *@import("../app/app.zig").App) !void {
    try app.scheduler.queueScopeCancellation(app.scheduler.application_scope);
    while (true) {
        try app.runReadyTurn();
        if (app.scheduler.hasPendingWork()) continue;
        if (!app.loop.hasPendingOperations() and !app.loop.hasPendingTimerKernelWork()) break;
        try app.reapOne();
    }
    try std.testing.expectEqual(@as(usize, 0), app.lua_vm.activeTaskCount());
    try std.testing.expect(app.dbus.canDeinit());
}
