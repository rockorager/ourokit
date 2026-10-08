//! Development-only statechart inspection feed. A `--dev` instance installs
//! an inactive bridge in every source generation. The first
//! `runtime.statecharts` call attaches it to the active VM: it seeds every
//! live actor's graph and current snapshot (machine.actors(), snapshot(),
//! chart:graph()) and subscribes `ouro.machine.inspect`. Records are
//! JSON-encoded in the VM and published into a bounded host ring with a
//! monotonic receive time. When no client has called for `keep_alive_ms`, the
//! next record detaches the observer, so idle instances build no records.
//! Records are design/statecharts.md section 10 transition and actor records.
const std = @import("std");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

/// started/stopped/transition/other go to the ring. The seed kinds only
/// rebuild the per-actor late-attach map.
pub const Kind = enum { started, stopped, transition, other, seed_reset, seed_started, seed_latest };

pub const Entry = struct {
    sequence: u64,
    time_ms: u64,
    bytes: []u8,
};

/// Start (with graph) and latest record of one live actor, keyed by actor
/// path, so root actors carried across source reload keep their identity.
pub const Actor = struct {
    started: ?[]u8 = null,
    latest: ?[]u8 = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    ring: []?Entry,
    head: usize = 0,
    next_sequence: u64 = 1,
    /// Counts attachments; a change tells clients to reread `actors`.
    seed: u64 = 0,
    start_ns: u64,
    last_request_ms: u64 = 0,
    keep_alive_ms: u64 = 30_000,
    max_record_bytes: usize = 256 * 1024,
    actors: std.StringArrayHashMapUnmanaged(Actor) = .empty,
    /// runtime.statecharts calls so far, and live statechart_uri subscribers
    /// (the control server counts them): both keep the observer attached.
    reads: u64 = 0,
    subscribers: usize = 0,
    /// runtime.send deliveries in flight: null until the task completes.
    results: std.AutoHashMapUnmanaged(u64, ?[]u8) = .empty,
    next_token: u64 = 1,
    /// This instance's development socket path, set once the server exists.
    endpoint: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Store {
        if (capacity == 0) return error.InvalidCapacity;
        const ring = try allocator.alloc(?Entry, capacity);
        @memset(ring, null);
        return .{ .allocator = allocator, .ring = ring, .start_ns = monotonicNs() };
    }

    pub fn deinit(self: *Store) void {
        for (self.ring) |entry| if (entry) |e| self.allocator.free(e.bytes);
        self.allocator.free(self.ring);
        self.clearActors();
        self.actors.deinit(self.allocator);
        var results = self.results.valueIterator();
        while (results.next()) |value| if (value.*) |bytes| self.allocator.free(bytes);
        self.results.deinit(self.allocator);
        if (self.endpoint) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn elapsedMs(self: *const Store) u64 {
        return (monotonicNs() -| self.start_ns) / std.time.ns_per_ms;
    }

    /// False once no client has asked for records within keep_alive_ms.
    pub fn wanted(self: *const Store) bool {
        return self.subscribers > 0 or self.elapsedMs() -| self.last_request_ms <= self.keep_alive_ms;
    }

    fn freeActor(self: *Store, actor: *Actor) void {
        if (actor.started) |bytes| self.allocator.free(bytes);
        if (actor.latest) |bytes| self.allocator.free(bytes);
        actor.* = .{};
    }

    fn clearActors(self: *Store) void {
        for (self.actors.keys(), self.actors.values()) |key, *actor| {
            self.freeActor(actor);
            self.allocator.free(key);
        }
        self.actors.clearRetainingCapacity();
    }

    fn removeActor(self: *Store, path: []const u8) void {
        const index = self.actors.getIndex(path) orelse return;
        const key = self.actors.keys()[index];
        self.freeActor(&self.actors.values()[index]);
        self.actors.orderedRemoveAt(index);
        self.allocator.free(key);
    }

    fn setActor(self: *Store, path: []const u8, started: bool, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        const slot = try self.actors.getOrPut(self.allocator, path);
        if (!slot.found_existing) {
            slot.key_ptr.* = self.allocator.dupe(u8, path) catch |err| {
                self.actors.orderedRemoveAt(slot.index);
                return err;
            };
            slot.value_ptr.* = .{};
        }
        if (started) {
            self.freeActor(slot.value_ptr);
            slot.value_ptr.started = copy;
        } else {
            if (slot.value_ptr.latest) |old| self.allocator.free(old);
            slot.value_ptr.latest = copy;
        }
    }

    pub fn publish(self: *Store, kind: Kind, actor_path: []const u8, bytes: []const u8) !void {
        if (bytes.len > self.max_record_bytes) return error.StatechartRecordTooLarge;
        switch (kind) {
            .seed_reset => {
                self.clearActors();
                self.seed += 1;
                return;
            },
            .seed_started, .seed_latest => {
                if (actor_path.len != 0) try self.setActor(actor_path, kind == .seed_started, bytes);
                return;
            },
            .stopped => self.removeActor(actor_path),
            .started, .transition => if (actor_path.len != 0) try self.setActor(actor_path, kind == .started, bytes),
            .other => {},
        }
        const owned = try self.allocator.dupe(u8, bytes);
        if (self.ring[self.head]) |old| self.allocator.free(old.bytes);
        self.ring[self.head] = .{ .sequence = self.next_sequence, .time_ms = self.elapsedMs(), .bytes = owned };
        self.head = (self.head + 1) % self.ring.len;
        self.next_sequence += 1;
    }

    /// The finished delivery's JSON (caller frees), or null while running.
    pub fn takeResult(self: *Store, token: u64) ?[]u8 {
        const entry = self.results.getEntry(token) orelse return null;
        const bytes = entry.value_ptr.* orelse return null;
        _ = self.results.remove(token);
        return bytes;
    }

    /// Forget an abandoned delivery; a later completion is discarded.
    pub fn dropResult(self: *Store, token: u64) void {
        if (self.results.fetchRemove(token)) |entry| if (entry.value) |bytes| self.allocator.free(bytes);
    }

    /// Oldest retained sequence, or next_sequence when the ring is empty.
    pub fn firstSequence(self: *const Store) u64 {
        const oldest = self.ring[self.head] orelse (self.ring[0] orelse return self.next_sequence);
        return oldest.sequence;
    }

    /// Calls `visit` for retained entries with sequence > after, oldest
    /// first, at most `limit` of them. Returns the number visited.
    pub fn each(self: *const Store, after: u64, limit: usize, context: anytype, comptime visit: fn (@TypeOf(context), Entry) anyerror!bool) !usize {
        var visited: usize = 0;
        for (0..self.ring.len) |offset| {
            if (visited == limit) break;
            const entry = self.ring[(self.head + offset) % self.ring.len] orelse continue;
            if (entry.sequence <= after) continue;
            if (!try visit(context, entry)) break;
            visited += 1;
        }
        return visited;
    }
};

fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const registry_key = "ouro.statechart_inspector";
const bridge_source = @embedFile("statechart_inspector.lua");

/// Installs the inactive bridge in a VM whose `ouro.machine` is installed.
pub fn install(vm: *vm_module.Vm, store: *Store) !void {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.luaL_loadbufferx(state, bridge_source.ptr, bridge_source.len, "=ouro.statechart_inspector", "t") != c.ok)
        return error.StatechartInspectorInitializationFailed;
    c.lua_pushlightuserdata(state, store);
    c.lua_pushcclosure(state, publish, 1);
    c.lua_pushlightuserdata(state, store);
    c.lua_pushcclosure(state, complete, 1);
    vm.pushApi(state);
    if (c.lua_pcallk(state, 3, 1, 0, 0, null) != c.ok)
        return error.StatechartInspectorInitializationFailed;
    c.lua_setfield(state, c.registry_index, registry_key);
    // ouro.development_endpoint() -> 'unix:<path>' of this --dev instance.
    vm.pushApi(state);
    c.lua_pushlightuserdata(state, store);
    c.lua_pushcclosure(state, endpoint, 1);
    c.lua_setfield(state, -2, "development_endpoint");
}

fn endpoint(state: *c.State) callconv(.c) c_int {
    const store: *Store = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)) orelse return 0));
    const path = store.endpoint orelse return 0;
    _ = c.lua_pushstring(state, "unix:");
    _ = c.lua_pushlstring(state, path.ptr, path.len);
    c.lua_concat(state, 2);
    return 1;
}

/// Pushes bridge[name] and returns true, or pushes nothing when the VM has
/// no bridge (no ouro.machine).
fn pushBridge(state: *c.State, name: [*:0]const u8) bool {
    if (c.lua_getfield(state, c.registry_index, registry_key) != c.type_table) {
        c.lua_settop(state, -2);
        return false;
    }
    _ = c.lua_getfield(state, -1, name);
    c.lua_rotate(state, -2, 1);
    c.lua_settop(state, -2);
    return true;
}

/// Called by the development endpoint at a safe point, with no task running:
/// renews the keep-alive and attaches the active VM's bridge if needed.
/// Seeding reads actor snapshots, pending timers and invokes, graphs and
/// accepted events; it runs no application callbacks besides guards.
pub fn attach(vm: *vm_module.Vm, store: *Store) !void {
    store.last_request_ms = store.elapsedMs();
    store.reads += 1;
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (!pushBridge(state, "attach")) return;
    if (c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok) return error.StatechartInspectorAttachFailed;
}

/// One actor's complete current state as owned JSON, or null when no live
/// actor has that path. Same safe-point rules as attach.
pub fn inspect(allocator: std.mem.Allocator, vm: *vm_module.Vm, path: []const u8) !?[]u8 {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (!pushBridge(state, "inspect")) return null;
    _ = c.lua_pushlstring(state, path.ptr, path.len);
    if (c.lua_pcallk(state, 1, 1, 0, 0, null) != c.ok) return error.StatechartInspectFailed;
    const bytes = argument(state, -1) orelse return null;
    return try allocator.dupe(u8, bytes);
}

/// One summary row per live actor (runtime.statecharts rollup), as JSON.
pub fn rollup(allocator: std.mem.Allocator, vm: *vm_module.Vm) !?[]u8 {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (!pushBridge(state, "rollup")) return null;
    if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok) return error.StatechartInspectFailed;
    const bytes = argument(state, -1) orelse return null;
    return try allocator.dupe(u8, bytes);
}

/// Spawns runtime.send's delivery as a task in the active VM's application
/// scope; its JSON result arrives through takeResult(token).
pub fn send(vm: *vm_module.Vm, store: *Store, request_json: []const u8) !u64 {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (!pushBridge(state, "send")) return error.StatechartInspectionUnavailable;
    const reference = c.luaL_ref(state, c.registry_index);
    defer c.luaL_unref(state, c.registry_index, reference);
    const token = store.next_token;
    store.next_token += 1;
    try store.results.put(store.allocator, token, null);
    errdefer _ = store.results.remove(token);
    _ = try vm.spawnReference(vm.scheduler.application_scope, reference, &.{
        .{ .integer = @intCast(token) },
        .{ .string = request_json },
    });
    return token;
}

fn argument(state: *c.State, index: c_int) ?[]const u8 {
    if (c.lua_type(state, index) != c.type_string) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(state, index, &len) orelse return null;
    return ptr[0..len];
}

/// publish(kind, actor, json) -> keep observing?
fn publish(state: *c.State) callconv(.c) c_int {
    const store: *Store = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)) orelse return 0));
    const kind_name = argument(state, 1) orelse return fail(state, "statechart publish expects a kind");
    const actor = argument(state, 2) orelse "";
    const bytes = argument(state, 3) orelse return fail(state, "statechart publish expects JSON bytes");
    const kind = std.meta.stringToEnum(Kind, kind_name) orelse .other;
    store.publish(kind, actor, bytes) catch |err| return fail(state, @errorName(err));
    c.lua_pushboolean(state, @intFromBool(store.wanted()));
    return 1;
}

/// complete(token, json): a runtime.send task's result.
fn complete(state: *c.State) callconv(.c) c_int {
    const store: *Store = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)) orelse return 0));
    var is_number: c_int = 0;
    const token = c.lua_tointegerx(state, 1, &is_number);
    const bytes = argument(state, 2) orelse return fail(state, "statechart complete expects JSON bytes");
    if (is_number == 0 or token < 0) return fail(state, "statechart complete expects a token");
    const entry = store.results.getPtr(@intCast(token)) orelse return 0;
    if (entry.* != null) return 0;
    entry.* = store.allocator.dupe(u8, bytes) catch |err| return fail(state, @errorName(err));
    return 0;
}

fn fail(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "statechart store keeps a bounded ring and path-keyed late-attach state" {
    var store = try Store.init(std.testing.allocator, 3);
    defer store.deinit();
    try store.publish(.started, "doc", "{\"kind\":\"actor\",\"action\":\"started\"}");
    try store.publish(.transition, "doc", "{\"sequence\":1}");
    try store.publish(.transition, "doc", "{\"sequence\":2}");
    try store.publish(.transition, "doc", "{\"sequence\":3}");
    try std.testing.expectEqual(@as(u64, 2), store.firstSequence());
    const actor = store.actors.get("doc").?;
    try std.testing.expectEqualStrings("{\"kind\":\"actor\",\"action\":\"started\"}", actor.started.?);
    try std.testing.expectEqualStrings("{\"sequence\":3}", actor.latest.?);
    const Collect = struct {
        seen: [4]u64 = undefined,
        count: usize = 0,
        fn visit(self: *@This(), entry: Entry) anyerror!bool {
            self.seen[self.count] = entry.sequence;
            self.count += 1;
            return true;
        }
    };
    var collect: Collect = .{};
    try std.testing.expectEqual(@as(usize, 2), try store.each(2, 8, &collect, Collect.visit));
    try std.testing.expectEqualSlices(u64, &.{ 3, 4 }, collect.seen[0..2]);
    // A reattach reseeds the map without touching the ring.
    try store.publish(.seed_reset, "", "{}");
    try store.publish(.seed_started, "doc", "{\"seeded\":true}");
    try std.testing.expectEqual(@as(u64, 1), store.seed);
    try std.testing.expectEqualStrings("{\"seeded\":true}", store.actors.get("doc").?.started.?);
    try std.testing.expectEqual(@as(u64, 5), store.next_sequence);
    try store.publish(.stopped, "doc", "{}");
    try std.testing.expectEqual(@as(usize, 0), store.actors.count());
    try std.testing.expectError(error.StatechartRecordTooLarge, store.publish(.other, "", "x" ** (256 * 1024 + 1)));
    store.keep_alive_ms = 0;
    store.last_request_ms = store.elapsedMs() + 1;
    try std.testing.expect(store.wanted());
}
