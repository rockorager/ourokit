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
const wait_mt = "ouro.dbus.wait";
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
};
const Wait = struct {
    binding: *Binding = undefined,
    active: bool = false,
    kind: enum { connect, call, subscribe, next } = .call,
    bus: *Bus = undefined,
    sub: ?*Subscription = null,
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
        installMetatable(L, wait_mt, &.{.{ "__close", closeWaitLua }});
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
                    if (sub.guard == null and !self.subHasWait(sub)) self.releaseSub(sub);
                }
            };
            try bus.client.collectCanceled();
            if (bus.closing) {
                try bus.client.close();
                if (bus.client.canDeinit() and !self.busHasWait(bus)) {
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
            for (self.subscriptions) |*sub| if (sub.active and sub.bus == bus and sub.phase != .closing and matches(sub, message)) {
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
        for (self.waits) |*wait| if (wait.active and !wait.completed and wait.kind == .call and wait.bus == bus and wait.serial == serial) {
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
        if (wait.result) |*message| message.deinit();
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
        self.clearSubQueue(sub);
        if (sub.guard) |guard| guard.* = null;
        if (sub.resource) |resource| self.vm.scheduler.destroyResource(resource) catch unreachable;
        inline for (.{ "sender", "sender_owner", "path", "interface", "member" }) |field| if (@field(sub, field)) |value| self.allocator.free(value);
        self.allocator.free(sub.rule);
        sub.* = .{ .binding = self };
    }
};

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
    const sub = try getHandle(Subscription, L, 1, sub_mt);
    const self = sub.binding;
    _ = try self.vm.currentScope(L);
    if (sub.phase == .closing) return sub.failure orelse error.SubscriptionClosed;
    if (self.subHasWait(sub)) return error.SubscriptionAlreadyWaiting;
    if (sub.queue.items.len != 0) {
        var message = self.popSignal(sub);
        defer message.deinit();
        try values.pushMessage(L, &message);
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
    if (wait.failure) |err| return localError(L, err);
    if (wait.result) |*message| {
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
    const guard = handlePointer(Subscription, L, 1, sub_mt) orelse return localError(L, error.InvalidSubscription);
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
    const guard: *?*T = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(?*T), if (T == Subscription) 1 else 0) orelse return error.OutOfMemory));
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
