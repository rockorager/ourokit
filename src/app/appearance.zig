const std = @import("std");
const io = @import("../loop/io_uring.zig");
const dbus = @import("../dbus/root.zig");
const wire = dbus.wire;

const daemon = "org.freedesktop.DBus";
const daemon_path = "/org/freedesktop/DBus";
const portal = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings = "org.freedesktop.portal.Settings";
const namespace = "org.freedesktop.appearance";
const key = "color-scheme";
const owner_match = "type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.portal.Desktop'";
const setting_match = "type='signal',sender='org.freedesktop.portal.Desktop',path='/org/freedesktop/portal/desktop',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='org.freedesktop.appearance',arg1='color-scheme'";

pub const ColorScheme = enum { default, light, dark };

pub const Snapshot = struct {
    color_scheme: ColorScheme = .default,
};

pub const Event = union(enum) {
    appearance_changed: Snapshot,
};

/// A transport-independent, single-event mailbox. Several writes before the
/// host's next turn are represented by the newest snapshot only.
pub const Store = struct {
    current: Snapshot = .{},
    pending: bool = false,

    pub fn update(self: *Store, snapshot: Snapshot) void {
        if (std.meta.eql(self.current, snapshot)) return;
        self.current = snapshot;
        self.pending = true;
    }

    pub fn takeEvent(self: *Store) ?Event {
        if (!self.pending) return null;
        self.pending = false;
        return .{ .appearance_changed = self.current };
    }
};

/// Host-owned Settings portal subscription. All I/O is asynchronous; the host
/// pumps collectCanceled before submission and routes socket/timer/cancel CQEs.
/// Portal restarts are discovered through bus owner changes, never polling.
pub const Client = struct {
    allocator: std.mem.Allocator = undefined,
    store: *Store = undefined,
    bus: dbus.Client = undefined,
    enabled: bool = false,
    stopping: bool = false,
    started: bool = false,
    watching: bool = false,
    owner: ?[]u8 = null,
    owner_match_serial: ?u32 = null,
    setting_match_serial: ?u32 = null,
    activation_serial: ?u32 = null,
    owner_serial: ?u32 = null,
    read_serial: ?u32 = null,

    /// A null address disables the built-in service (for host-supplied Stores).
    pub fn init(self: *Client, allocator: std.mem.Allocator, loop: *io.Loop, store: *Store, address: ?[]const u8) !void {
        self.* = .{ .allocator = allocator, .store = store };
        const value = address orelse return;
        if (value.len == 0) return;
        try self.bus.init(allocator, loop, value);
        self.enabled = true;
    }

    pub fn dispatch(self: *Client, completion: io.SocketCompletion) !bool {
        if (!self.enabled or !try self.bus.dispatch(completion)) return false;
        try self.collectCanceled();
        return true;
    }

    pub fn dispatchTimer(self: *Client, operation: io.OperationHandle) !bool {
        if (!self.enabled or !try self.bus.dispatchTimer(operation)) return false;
        try self.collectCanceled();
        return true;
    }

    pub fn collectCanceled(self: *Client) !void {
        if (!self.enabled) return;
        try self.bus.collectCanceled();
        if (self.stopping) return;
        if (self.bus.failure != null) {
            self.store.update(.{});
            return;
        }
        if (!self.bus.isReady()) return;
        if (!self.started) {
            self.owner_match_serial = try self.daemonCall("AddMatch", owner_match);
            self.started = true;
        }
        while (try self.bus.takeMessage()) |incoming| {
            var message = incoming;
            defer message.deinit();
            try self.accept(&message);
        }
        try self.bus.collectCanceled();
    }

    pub fn stop(self: *Client) !void {
        self.stopping = true;
        if (self.enabled) try self.bus.close();
    }

    /// Valid after all native operations have drained.
    pub fn deinit(self: *Client) void {
        if (self.enabled) self.bus.deinit();
        if (self.owner) |owner| self.allocator.free(owner);
        self.* = undefined;
    }

    fn daemonCall(self: *Client, member: []const u8, argument: []const u8) !u32 {
        var body = wire.Encoder.init(self.allocator);
        defer body.deinit();
        try body.string(argument);
        if (std.mem.eql(u8, member, "StartServiceByName")) try body.uint32(0);
        return self.bus.send(.{
            .message_type = .method_call,
            .destination = daemon,
            .path = daemon_path,
            .interface = daemon,
            .member = member,
            .signature = if (std.mem.eql(u8, member, "StartServiceByName")) "su" else "s",
        }, body.bytes(), &.{});
    }

    fn accept(self: *Client, message: *const wire.Message) !void {
        if (self.stopping) return;
        if (message.messageType() == .signal) {
            if (!self.watching) return;
            if (equal(message.header.sender, daemon) and equal(message.header.path, daemon_path) and
                equal(message.header.interface, daemon) and equal(message.header.member, "NameOwnerChanged") and
                std.mem.eql(u8, message.bodySignature(), "sss"))
            {
                var body = message.bodyDecoder();
                if (!std.mem.eql(u8, try body.string(), portal)) return;
                _ = try body.string();
                const owner = try body.string();
                try body.end();
                // A newer bus signal supersedes an outstanding owner query.
                self.owner_serial = null;
                try self.setOwner(owner);
            } else if (self.owner) |owner| {
                if (!equal(message.header.sender, owner) or !equal(message.header.path, portal_path) or
                    !equal(message.header.interface, settings) or !equal(message.header.member, "SettingChanged") or
                    !std.mem.eql(u8, message.bodySignature(), "ssv")) return;
                var body = message.bodyDecoder();
                if (!std.mem.eql(u8, try body.string(), namespace) or !std.mem.eql(u8, try body.string(), key)) return;
                const scheme = readScheme(&body) catch return;
                try body.end();
                // Never let an older snapshot overwrite a newer signal.
                self.read_serial = null;
                self.store.update(.{ .color_scheme = scheme });
            }
            return;
        }
        if (message.messageType() != .method_return and message.messageType() != .error_reply) return;
        const serial = message.header.reply_serial orelse return;
        const ok = message.messageType() == .method_return;
        if (equal(message.header.sender, daemon)) {
            if (self.owner_match_serial == serial) {
                self.owner_match_serial = null;
                if (!ok) return self.disable();
                self.setting_match_serial = try self.daemonCall("AddMatch", setting_match);
            } else if (self.setting_match_serial == serial) {
                self.setting_match_serial = null;
                if (!ok) return self.disable();
                self.watching = true;
                // Activate installed portals, but never wait for one at startup.
                self.activation_serial = try self.daemonCall("StartServiceByName", portal);
            } else if (self.activation_serial == serial) {
                self.activation_serial = null;
                if (self.owner == null) self.owner_serial = try self.daemonCall("GetNameOwner", portal);
            } else if (self.owner_serial == serial) {
                self.owner_serial = null;
                if (!ok or !std.mem.eql(u8, message.bodySignature(), "s")) return self.setOwner("");
                var body = message.bodyDecoder();
                const owner = try body.string();
                try body.end();
                try self.setOwner(owner);
            }
        }
        if (self.read_serial == serial) {
            const owner = self.owner orelse return;
            if (!equal(message.header.sender, owner) and !(message.messageType() == .error_reply and equal(message.header.sender, daemon))) return;
            self.read_serial = null;
            self.store.update(.{ .color_scheme = if (ok) readAll(message) catch .default else .default });
        }
    }

    fn disable(self: *Client) !void {
        self.store.update(.{});
        try self.stop();
    }

    fn setOwner(self: *Client, value: []const u8) !void {
        if (self.owner) |owner| if (std.mem.eql(u8, owner, value)) return;
        const next = if (value.len != 0) try self.allocator.dupe(u8, value) else null;
        if (self.owner) |owner| self.allocator.free(owner);
        self.owner = next;
        self.read_serial = null;
        self.store.update(.{});
        const owner = self.owner orelse return;
        var body = wire.Encoder.init(self.allocator);
        defer body.deinit();
        const array = try body.beginArray(4);
        try body.string(namespace);
        try body.endArray(array);
        // ReadAll exists in both portal versions; unlike deprecated Read it
        // has no historical double-variant ambiguity.
        self.read_serial = try self.bus.send(.{
            .message_type = .method_call,
            .destination = owner,
            .path = portal_path,
            .interface = settings,
            .member = "ReadAll",
            .signature = "as",
        }, body.bytes(), &.{});
    }
};

fn equal(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |text| std.mem.eql(u8, text, expected) else false;
}

fn readScheme(body: *wire.Decoder) !ColorScheme {
    if (!std.mem.eql(u8, try body.variantSignature(), "u")) return error.InvalidColorScheme;
    return switch (try body.uint32()) {
        1 => .dark,
        2 => .light,
        else => .default,
    };
}

fn readAll(message: *const wire.Message) !ColorScheme {
    if (!std.mem.eql(u8, message.bodySignature(), "a{sa{sv}}")) return error.InvalidSettings;
    var body = message.bodyDecoder();
    var scheme: ColorScheme = .default;
    const namespaces_end = try body.beginArray(8);
    while (!try body.arrayFinished(namespaces_end)) {
        try body.structAlignment();
        const name = try body.string();
        const keys_end = try body.beginArray(8);
        while (!try body.arrayFinished(keys_end)) {
            try body.structAlignment();
            const name_key = try body.string();
            if (std.mem.eql(u8, name, namespace) and std.mem.eql(u8, name_key, key)) {
                scheme = try readScheme(&body);
            } else try body.skipSignatureValue("v");
        }
        try body.endArray(keys_end);
    }
    try body.endArray(namespaces_end);
    try body.end();
    return scheme;
}

test "appearance Store suppresses equality and coalesces changes" {
    var store: Store = .{};
    store.update(.{});
    try std.testing.expect(store.takeEvent() == null);
    store.update(.{ .color_scheme = .light });
    store.update(.{ .color_scheme = .dark });
    const event = store.takeEvent().?;
    try std.testing.expectEqual(ColorScheme.dark, event.appearance_changed.color_scheme);
    try std.testing.expect(store.takeEvent() == null);
}

test "appearance portal decodes unsigned preferences and missing or invalid settings" {
    for ([_]u32{ 0, 1, 2, 3, std.math.maxInt(u32) }, [_]ColorScheme{ .default, .dark, .light, .default, .default }) |value, expected| {
        var body = try testSettings(value);
        defer body.deinit();
        var message = try testMessage(.{ .message_type = .method_return, .reply_serial = 42, .signature = "a{sa{sv}}" }, body.bytes());
        defer message.deinit();
        try std.testing.expectEqual(expected, try readAll(&message));
    }
    var missing = try testSettings(null);
    defer missing.deinit();
    var message = try testMessage(.{ .message_type = .method_return, .reply_serial = 42, .signature = "a{sa{sv}}" }, missing.bytes());
    defer message.deinit();
    try std.testing.expectEqual(ColorScheme.default, try readAll(&message));
    // Signed integers and nested variants are not this setting's wire type.
    for ([_][]const u8{ &.{ 1, 'i', 0, 0, 1, 0, 0, 0 }, &.{ 1, 'v', 0, 1, 'u', 0, 0, 0, 1, 0, 0, 0 } }) |bytes| {
        var body: wire.Decoder = .{ .data = bytes, .endian = .little };
        try std.testing.expectError(error.InvalidColorScheme, readScheme(&body));
    }
}

test "appearance portal subscribes before activation and survives absence and owner replacement" {
    var store: Store = .{};
    var client: Client = .{ .allocator = std.testing.allocator, .store = &store, .bus = .{ .allocator = std.testing.allocator, .phase = .ready } };
    defer testDeinit(&client);
    client.owner_match_serial = try client.daemonCall("AddMatch", owner_match);
    try testRequest(&client, 0, "AddMatch", "s", daemon, owner_match);
    try std.testing.expect(client.read_serial == null and !client.watching);
    try testAccept(&client, .{ .message_type = .method_return, .sender = daemon, .reply_serial = client.owner_match_serial }, &.{});
    try testRequest(&client, 1, "AddMatch", "s", daemon, setting_match);
    try std.testing.expect(client.read_serial == null and !client.watching);
    try testAccept(&client, .{ .message_type = .method_return, .sender = daemon, .reply_serial = client.setting_match_serial }, &.{});
    try testRequest(&client, 2, "StartServiceByName", "su", daemon, portal);
    try std.testing.expect(client.watching and client.read_serial == null);
    try testAccept(&client, .{ .message_type = .error_reply, .sender = daemon, .reply_serial = client.activation_serial, .error_name = "org.freedesktop.DBus.Error.ServiceUnknown" }, &.{});
    try testRequest(&client, 3, "GetNameOwner", "s", daemon, portal);
    try testAccept(&client, .{ .message_type = .error_reply, .sender = daemon, .reply_serial = client.owner_serial, .error_name = "org.freedesktop.DBus.Error.NameHasNoOwner" }, &.{});
    try std.testing.expectEqual(ColorScheme.default, store.current.color_scheme);
    try std.testing.expect(store.takeEvent() == null);
    try std.testing.expectEqual(@as(usize, 4), client.bus.outgoing.items.len);

    // A later service appears without any retry timer or new subscription.
    try testOwner(&client, "", ":1.71");
    try testRequest(&client, 4, "ReadAll", "as", ":1.71", namespace);
    const stale_read = client.read_serial.?;
    try testChanged(&client, ":1.71", namespace, key, 1);
    try std.testing.expectEqual(ColorScheme.dark, store.takeEvent().?.appearance_changed.color_scheme);
    try testSnapshot(&client, ":1.71", stale_read, 2);
    try std.testing.expect(store.takeEvent() == null); // Late light snapshot loses to dark signal.
    try testOwner(&client, ":1.71", "");
    try std.testing.expectEqual(ColorScheme.default, store.takeEvent().?.appearance_changed.color_scheme);
    try testOwner(&client, "", ":1.92");
    const new_read = client.read_serial.?;
    try std.testing.expect(new_read != stale_read);
    try testSnapshot(&client, ":1.71", new_read, 1); // Right serial, retired sender.
    try std.testing.expectEqual(new_read, client.read_serial.?);
    try testSnapshot(&client, ":1.92", new_read, 2);
    try std.testing.expectEqual(ColorScheme.light, store.takeEvent().?.appearance_changed.color_scheme);
    try testChanged(&client, ":1.71", namespace, key, 1);
    try testChanged(&client, ":1.92", "org.example.other", key, 1);
    try testChanged(&client, ":1.92", namespace, "contrast", 1);
    try testChanged(&client, ":1.92", namespace, key, 2);
    try std.testing.expect(store.takeEvent() == null);
    try testChanged(&client, ":1.92", namespace, key, 42);
    try std.testing.expectEqual(ColorScheme.default, store.takeEvent().?.appearance_changed.color_scheme);
    try std.testing.expectEqual(@as(usize, 6), client.bus.outgoing.items.len);
}

test "appearance portal owner signal supersedes lookup and direct replacement retires reads" {
    var store: Store = .{};
    var client: Client = .{ .allocator = std.testing.allocator, .store = &store, .watching = true, .bus = .{ .allocator = std.testing.allocator, .phase = .ready } };
    defer testDeinit(&client);
    client.owner_serial = try client.daemonCall("GetNameOwner", portal);
    const query = client.owner_serial.?;
    try testOwner(&client, "", ":1.8");
    var body = wire.Encoder.init(std.testing.allocator);
    defer body.deinit();
    try body.string(":1.7");
    try testAccept(&client, .{ .message_type = .method_return, .sender = daemon, .reply_serial = query, .signature = "s" }, body.bytes());
    try std.testing.expectEqualStrings(":1.8", client.owner.?);
    const old_read = client.read_serial.?;
    try testOwner(&client, ":1.8", ":1.9");
    try testSnapshot(&client, ":1.8", old_read, 1);
    try std.testing.expect(store.takeEvent() == null);
    try testSnapshot(&client, ":1.9", client.read_serial.?, 1);
    try std.testing.expectEqual(ColorScheme.dark, store.takeEvent().?.appearance_changed.color_scheme);
    client.stopping = true;
    try testChanged(&client, ":1.9", namespace, key, 2);
    try std.testing.expect(store.takeEvent() == null);
}

test "appearance portal disabled and missing buses fall back without publishing after stop" {
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var store: Store = .{ .current = .{ .color_scheme = .dark } };
    var client: Client = undefined;
    try client.init(std.testing.allocator, &loop, &store, null);
    try client.collectCanceled();
    try client.stop();
    client.deinit();
    try std.testing.expectEqual(ColorScheme.dark, store.current.color_scheme);
    for ([_]bool{ true, false }) |stop_before_connect| {
        store = .{ .current = .{ .color_scheme = .dark } };
        try client.init(std.testing.allocator, &loop, &store, "unix:abstract=ouro-appearance-missing-bus");
        defer client.deinit();
        if (!stop_before_connect) {
            while (client.bus.failure == null) try testStep(&loop, &client, null);
            try std.testing.expectEqual(ColorScheme.default, store.takeEvent().?.appearance_changed.color_scheme);
        }
        try client.stop();
        try client.stop();
        while (loop.hasPendingOperations() or loop.hasPendingTimerKernelWork()) try testStep(&loop, &client, null);
        try std.testing.expect(client.bus.canDeinit());
        try std.testing.expect(store.takeEvent() == null);
        try std.testing.expectEqual(if (stop_before_connect) ColorScheme.dark else ColorScheme.default, store.current.color_scheme);
    }
}

// Run under a disposable dbus-run-session with OURO_APPEARANCE_INTEGRATION=1.
test "appearance portal live bus recovers service restart without polling and drains shutdown" {
    if (std.testing.environ.getPosix("OURO_APPEARANCE_INTEGRATION") == null) return error.SkipZigTest;
    const address = std.testing.environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse return error.MissingTestBus;
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 32, 16);
    defer loop.deinit();
    var store: Store = .{};
    var client: Client = undefined;
    try client.init(std.testing.allocator, &loop, &store, address);
    defer client.deinit();
    var service: dbus.Client = .{ .allocator = std.testing.allocator, .loop = &loop };
    defer service.deinit();
    defer {
        client.stop() catch unreachable;
        service.close() catch unreachable;
        while (loop.hasPendingOperations() or loop.hasPendingTimerKernelWork()) testStep(&loop, &client, &service) catch unreachable;
    }
    try std.testing.expect(!client.bus.isReady()); // init only submits connection work.
    while (!client.watching or client.activation_serial != null or client.owner_serial != null) try testStep(&loop, &client, &service);
    try std.testing.expect(client.owner == null);
    try std.testing.expectEqual(ColorScheme.default, store.current.color_scheme);
    try std.testing.expect(client.bus.timer == null);
    const idle_serial = client.bus.next_serial;

    for ([_]u32{ 1, 2 }, [_]ColorScheme{ .dark, .light }) |preference, expected| {
        // Each iteration is a new connection with a new unique owner name.
        service.deinit();
        try service.init(std.testing.allocator, &loop, address);
        while (!service.isReady()) try testStep(&loop, &client, &service);
        var request = wire.Encoder.init(std.testing.allocator);
        defer request.deinit();
        try request.string(portal);
        try request.uint32(4); // Do not queue for a name owned by another service.
        const name_serial = try service.send(.{ .message_type = .method_call, .destination = daemon, .path = daemon_path, .interface = daemon, .member = "RequestName", .signature = "su" }, request.bytes(), &.{});
        var answered = false;
        while (!answered) {
            try testStep(&loop, &client, &service);
            while (try service.takeMessage()) |incoming| {
                var message = incoming;
                defer message.deinit();
                if (message.header.reply_serial == name_serial) {
                    try std.testing.expectEqual(wire.MessageType.method_return, message.messageType());
                    var body = message.bodyDecoder();
                    try std.testing.expectEqual(@as(u32, 1), try body.uint32());
                }
                if (message.messageType() != .method_call) continue;
                try std.testing.expectEqualStrings("ReadAll", message.header.member.?);
                try std.testing.expectEqualStrings(settings, message.header.interface.?);
                try std.testing.expectEqualStrings(portal_path, message.header.path.?);
                try std.testing.expectEqualStrings("as", message.bodySignature());
                var body = message.bodyDecoder();
                const end = try body.beginArray(4);
                try std.testing.expectEqualStrings(namespace, try body.string());
                try body.endArray(end);
                try body.end();
                var response = try testSettings(preference);
                defer response.deinit();
                _ = try service.send(.{ .message_type = .method_return, .destination = message.header.sender, .reply_serial = message.header.serial, .signature = "a{sa{sv}}" }, response.bytes(), &.{});
                answered = true;
            }
        }
        while (store.current.color_scheme != expected) try testStep(&loop, &client, &service);
        try std.testing.expectEqual(expected, store.takeEvent().?.appearance_changed.color_scheme);
        try std.testing.expect(client.bus.timer == null);
        try std.testing.expectEqual(idle_serial + preference, client.bus.next_serial); // Exactly one ReadAll per owner.
        if (preference == 1) {
            var changed = wire.Encoder.init(std.testing.allocator);
            defer changed.deinit();
            try changed.string(namespace);
            try changed.string(key);
            try changed.variantSignature("u");
            try changed.uint32(2);
            _ = try service.send(.{ .message_type = .signal, .path = portal_path, .interface = settings, .member = "SettingChanged", .signature = "ssv" }, changed.bytes(), &.{});
            while (store.current.color_scheme != .light) try testStep(&loop, &client, &service);
            try std.testing.expectEqual(ColorScheme.light, store.takeEvent().?.appearance_changed.color_scheme);
        }
        try service.close();
        while (!service.canDeinit() or client.owner != null) try testStep(&loop, &client, &service);
        try std.testing.expectEqual(ColorScheme.default, store.takeEvent().?.appearance_changed.color_scheme);
    }
    try std.testing.expect(client.bus.timer == null);
}

fn testDeinit(client: *Client) void {
    client.bus.phase = .closed;
    client.bus.deinit();
    client.deinit();
}

fn testMessage(metadata: wire.Metadata, body: []const u8) !wire.Message {
    const bytes = try wire.encodeMessage(std.testing.allocator, metadata, 901, body, 0);
    errdefer std.testing.allocator.free(bytes);
    return wire.parseMessage(std.testing.allocator, bytes, &.{});
}

fn testAccept(client: *Client, metadata: wire.Metadata, body: []const u8) !void {
    var message = try testMessage(metadata, body);
    defer message.deinit();
    try client.accept(&message);
}

fn testRequest(client: *Client, index: usize, member: []const u8, signature: []const u8, destination: []const u8, argument: []const u8) !void {
    var message = try wire.parseMessage(std.testing.allocator, client.bus.outgoing.items[index].bytes, &.{});
    try std.testing.expectEqualStrings(member, message.header.member.?);
    try std.testing.expectEqualStrings(signature, message.bodySignature());
    try std.testing.expectEqualStrings(destination, message.header.destination.?);
    try std.testing.expectEqualStrings(if (std.mem.eql(u8, member, "ReadAll")) settings else daemon, message.header.interface.?);
    try std.testing.expectEqualStrings(if (std.mem.eql(u8, member, "ReadAll")) portal_path else daemon_path, message.header.path.?);
    var body = message.bodyDecoder();
    const end = if (std.mem.eql(u8, signature, "as")) try body.beginArray(4) else null;
    try std.testing.expectEqualStrings(argument, try body.string());
    if (end) |position| try body.endArray(position);
    if (std.mem.eql(u8, signature, "su")) try std.testing.expectEqual(@as(u32, 0), try body.uint32());
    try body.end();
}

fn testOwner(client: *Client, old: []const u8, new: []const u8) !void {
    var body = wire.Encoder.init(std.testing.allocator);
    defer body.deinit();
    try body.string(portal);
    try body.string(old);
    try body.string(new);
    try testAccept(client, .{ .message_type = .signal, .sender = daemon, .path = daemon_path, .interface = daemon, .member = "NameOwnerChanged", .signature = "sss" }, body.bytes());
}

fn testChanged(client: *Client, sender: []const u8, name: []const u8, name_key: []const u8, value: u32) !void {
    var body = wire.Encoder.init(std.testing.allocator);
    defer body.deinit();
    try body.string(name);
    try body.string(name_key);
    try body.variantSignature("u");
    try body.uint32(value);
    try testAccept(client, .{ .message_type = .signal, .sender = sender, .path = portal_path, .interface = settings, .member = "SettingChanged", .signature = "ssv" }, body.bytes());
}

fn testSettings(value: ?u32) !wire.Encoder {
    var body = wire.Encoder.init(std.testing.allocator);
    errdefer body.deinit();
    const namespaces = try body.beginArray(8);
    try body.structAlignment();
    try body.string(namespace);
    const keys = try body.beginArray(8);
    // An unrelated key preceding our key catches premature termination.
    try body.structAlignment();
    try body.string("contrast");
    try body.variantSignature("u");
    try body.uint32(1);
    if (value) |number| {
        try body.structAlignment();
        try body.string(key);
        try body.variantSignature("u");
        try body.uint32(number);
    }
    try body.endArray(keys);
    try body.endArray(namespaces);
    return body;
}

fn testSnapshot(client: *Client, sender: []const u8, serial: u32, value: ?u32) !void {
    var body = try testSettings(value);
    defer body.deinit();
    try testAccept(client, .{ .message_type = .method_return, .sender = sender, .reply_serial = serial, .signature = "a{sa{sv}}" }, body.bytes());
}

fn testStep(loop: *io.Loop, client: *Client, service: ?*dbus.Client) !void {
    try client.collectCanceled();
    if (service) |bus| try bus.collectCanceled();
    _ = try loop.submit();
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| if (!try client.dispatch(completion)) {
            try std.testing.expect(try (service orelse return error.UnownedCompletion).dispatch(completion));
        },
        .operation_cancel => {
            try client.collectCanceled();
            if (service) |bus| try bus.collectCanceled();
        },
        .timer_control, .timer_wakeup => while (try loop.takeExpired()) |timer| {
            if (!try client.dispatchTimer(timer.operation)) {
                try std.testing.expect(try (service orelse return error.UnownedCompletion).dispatchTimer(timer.operation));
            }
        },
        else => return error.UnexpectedCompletion,
    }
}
