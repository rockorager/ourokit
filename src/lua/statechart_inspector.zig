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
        self.* = undefined;
    }

    pub fn elapsedMs(self: *const Store) u64 {
        return (monotonicNs() -| self.start_ns) / std.time.ns_per_ms;
    }

    /// False once no client has asked for records within keep_alive_ms.
    pub fn wanted(self: *const Store) bool {
        return self.elapsedMs() -| self.last_request_ms <= self.keep_alive_ms;
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

// Returns attach(), idempotent per VM. Records already carry time_ms and
// guard valve states; seeded snapshots add pending timers and invokes.
const bridge_source =
    \\local publish, ouro = ...
    \\local machine, json = ouro.machine, ouro.json
    \\if not machine then return nil end
    \\local unsubscribe
    \\local function send(kind, record)
    \\  local ok, bytes = pcall(json.encode, record)
    \\  if not ok then
    \\    kind, bytes = 'other', json.encode({kind = 'encode_error', actor = record.actor,
    \\      machine = record.machine, message = tostring(bytes)})
    \\  end
    \\  return publish(kind, record.actor or '', bytes)
    \\end
    \\local function observe(record)
    \\  local kind = record.kind == 'actor' and record.action or record.kind
    \\  if not send(kind, record) and unsubscribe then unsubscribe(); unsubscribe = nil end
    \\end
    \\-- Current state of one actor as a synthetic started + transition pair.
    \\local function seed(actor)
    \\  local clock = actor._scheduler and actor._scheduler.clock
    \\  local now = clock and clock() or nil
    \\  send('seed_started', {kind = 'actor', action = 'started', actor = actor.path, machine = actor.chart.id,
    \\    parent = actor._parent and actor._parent.path, graph = actor.chart:graph(), seeded = true, time_ms = now})
    \\  local snapshot = machine.plain(actor:snapshot())
    \\  local record = {kind = 'transition', actor = actor.path, machine = actor.chart.id, origin = 'attach',
    \\    seeded = true, event = {type = 'ouro.attach'}, handled = true, rejected = false, time_ms = now,
    \\    microsteps = {}, exited = {}, entered = {}, timers = {}, invokes = {}, children = {}, actions = {},
    \\    states = snapshot.states, status = snapshot.status, context = snapshot.context}
    \\  for _, live in ipairs(actor.pending_timers and actor:pending_timers() or {}) do
    \\    record.timers[#record.timers + 1] = {action = 'started', state = live.state, delay = live.delay,
    \\      event = live.event, token = live.token, time_ms = live.time_ms}
    \\  end
    \\  for _, live in ipairs(actor.pending_invokes and actor:pending_invokes() or {}) do
    \\    record.invokes[#record.invokes + 1] = {action = 'started', state = live.state, id = live.id,
    \\      src = live.src, token = live.token, time_ms = live.time_ms}
    \\  end
    \\  send('seed_latest', record)
    \\end
    \\return function()
    \\  if unsubscribe then return end
    \\  unsubscribe = machine.inspect(observe)
    \\  publish('seed_reset', '', '{}')
    \\  for _, actor in ipairs(machine.actors()) do
    \\    local ok, err = pcall(seed, actor)
    \\    if not ok then print('statechart inspector cannot seed ' .. tostring(actor.path) .. ': ' .. tostring(err)) end
    \\  end
    \\end
;

/// Installs the inactive bridge in a VM whose `ouro.machine` is installed.
pub fn install(vm: *vm_module.Vm, store: *Store) !void {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.luaL_loadbufferx(state, bridge_source.ptr, bridge_source.len, "=ouro.statechart_inspector", "t") != c.ok)
        return error.StatechartInspectorInitializationFailed;
    c.lua_pushlightuserdata(state, store);
    c.lua_pushcclosure(state, publish, 1);
    vm.pushApi(state);
    if (c.lua_pcallk(state, 2, 1, 0, 0, null) != c.ok)
        return error.StatechartInspectorInitializationFailed;
    c.lua_setfield(state, c.registry_index, registry_key);
}

/// Called by the development endpoint at a safe point, with no task running:
/// renews the keep-alive and attaches the active VM's bridge if needed.
/// Seeding reads actor snapshots, pending timers and invokes, and graphs;
/// it runs no application callbacks.
pub fn attach(vm: *vm_module.Vm, store: *Store) !void {
    store.last_request_ms = store.elapsedMs();
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.lua_getfield(state, c.registry_index, registry_key) != c.type_function) return;
    if (c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok) return error.StatechartInspectorAttachFailed;
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
