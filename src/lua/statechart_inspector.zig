//! Development-only statechart inspection feed. In `--dev` instances each
//! source generation registers an `ouro.machine.inspect` observer that
//! JSON-encodes every record and publishes it here, stamped with a host
//! monotonic time. The development endpoint (`runtime.statecharts`) reads the
//! bounded ring with a sequence cursor and never evaluates Lua. A record is a
//! design/statecharts.md §10 transition or actor lifecycle record.
const std = @import("std");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

pub const Kind = enum { started, stopped, transition, other };

pub const Entry = struct {
    sequence: u64,
    time_ms: u64,
    bytes: []u8,
};

/// Latest lifecycle and transition record per live actor, so a late attach
/// can rebuild every plant even after the ring has evicted its start.
pub const Actor = struct {
    epoch: u32,
    started: ?[]u8 = null,
    latest: ?[]u8 = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    ring: []?Entry,
    head: usize = 0,
    next_sequence: u64 = 1,
    /// Each Lua VM install gets a new epoch. Records from a newer epoch
    /// retire actors published by older VMs, which cannot send `stopped`.
    epoch: u32 = 0,
    installs: u32 = 0,
    start_ns: u64,
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
        for (self.actors.keys(), self.actors.values()) |key, *actor| {
            self.freeActor(actor);
            self.allocator.free(key);
        }
        self.actors.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn elapsedMs(self: *const Store) u64 {
        return (monotonicNs() -| self.start_ns) / std.time.ns_per_ms;
    }

    fn freeActor(self: *Store, actor: *Actor) void {
        if (actor.started) |bytes| self.allocator.free(bytes);
        if (actor.latest) |bytes| self.allocator.free(bytes);
        actor.* = .{ .epoch = actor.epoch };
    }

    fn removeActor(self: *Store, index: usize) void {
        const key = self.actors.keys()[index];
        self.freeActor(&self.actors.values()[index]);
        self.actors.orderedRemoveAt(index);
        self.allocator.free(key);
    }

    pub fn publish(self: *Store, epoch: u32, kind: Kind, actor_path: []const u8, bytes: []const u8) !void {
        if (bytes.len > self.max_record_bytes) return error.StatechartRecordTooLarge;
        if (epoch > self.epoch) {
            self.epoch = epoch;
            var index: usize = self.actors.count();
            while (index > 0) {
                index -= 1;
                if (self.actors.values()[index].epoch < epoch) self.removeActor(index);
            }
        }
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        if (kind != .other and actor_path.len != 0) switch (kind) {
            .stopped => if (self.actors.getIndex(actor_path)) |index| self.removeActor(index),
            .started, .transition => {
                const copy = try self.allocator.dupe(u8, bytes);
                errdefer self.allocator.free(copy);
                const slot = try self.actors.getOrPut(self.allocator, actor_path);
                if (!slot.found_existing) {
                    slot.key_ptr.* = self.allocator.dupe(u8, actor_path) catch |err| {
                        self.actors.orderedRemoveAt(slot.index);
                        return err;
                    };
                    slot.value_ptr.* = .{ .epoch = epoch };
                }
                slot.value_ptr.epoch = epoch;
                if (kind == .started) {
                    self.freeActor(slot.value_ptr);
                    slot.value_ptr.started = copy;
                } else {
                    if (slot.value_ptr.latest) |old| self.allocator.free(old);
                    slot.value_ptr.latest = copy;
                }
            },
            .other => unreachable,
        };
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

const bridge_source =
    \\local publish, ouro = ...
    \\local machine, json = ouro.machine, ouro.json
    \\if not machine then return end
    \\-- Valves need guard outcomes, which records lack: add the declared events
    \\-- the actor would accept now (actor:accepted(), guards included).
    \\local function accepted(record)
    \\  if record.kind ~= 'transition' or record.status ~= 'active' then return end
    \\  for _, actor in ipairs(machine.actors()) do
    \\    if actor.path == record.actor then
    \\      local ok, list = pcall(actor.accepted, actor)
    \\      if ok then record.accepted = list end
    \\      return
    \\    end
    \\  end
    \\end
    \\machine.inspect(function(record)
    \\  accepted(record)
    \\  local kind = record.kind == 'actor' and record.action or record.kind
    \\  local ok, bytes = pcall(json.encode, record)
    \\  if not ok then
    \\    kind, bytes = 'other', json.encode({kind = 'encode_error', actor = record.actor,
    \\      machine = record.machine, message = tostring(bytes)})
    \\  end
    \\  publish(kind, record.actor or '', bytes)
    \\end)
;

/// Registers the observer in a VM whose `ouro.machine` is already installed.
pub fn install(vm: *vm_module.Vm, store: *Store) !void {
    const state = vm.state;
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.luaL_loadbufferx(state, bridge_source.ptr, bridge_source.len, "=ouro.statechart_inspector", "t") != c.ok)
        return error.StatechartInspectorInitializationFailed;
    store.installs += 1;
    const epoch = store.installs;
    c.lua_pushlightuserdata(state, store);
    c.lua_pushinteger(state, epoch);
    c.lua_pushcclosure(state, publish, 2);
    vm.pushApi(state);
    if (c.lua_pcallk(state, 2, 0, 0, 0, null) != c.ok)
        return error.StatechartInspectorInitializationFailed;
}

fn argument(state: *c.State, index: c_int) ?[]const u8 {
    if (c.lua_type(state, index) != c.type_string) return null;
    var len: usize = 0;
    const ptr = c.lua_tolstring(state, index, &len) orelse return null;
    return ptr[0..len];
}

fn publish(state: *c.State) callconv(.c) c_int {
    const store: *Store = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)) orelse return 0));
    var is_number: c_int = 0;
    const epoch: u32 = @intCast(c.lua_tointegerx(state, c.upvalueIndex(2), &is_number));
    const kind_name = argument(state, 1) orelse return fail(state, "statechart publish expects a kind");
    const actor = argument(state, 2) orelse "";
    const bytes = argument(state, 3) orelse return fail(state, "statechart publish expects JSON bytes");
    const kind = std.meta.stringToEnum(Kind, kind_name) orelse .other;
    store.publish(epoch, kind, actor, bytes) catch |err| return fail(state, @errorName(err));
    return 0;
}

fn fail(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "statechart store keeps a bounded ring and per-actor late-attach state" {
    var store = try Store.init(std.testing.allocator, 3);
    defer store.deinit();
    try store.publish(1, .started, "doc", "{\"kind\":\"actor\",\"action\":\"started\"}");
    try store.publish(1, .transition, "doc", "{\"sequence\":1}");
    try store.publish(1, .transition, "doc", "{\"sequence\":2}");
    try store.publish(1, .transition, "doc", "{\"sequence\":3}");
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
    // A newer VM retires actors published by older ones.
    try store.publish(2, .started, "other", "{}");
    try std.testing.expect(store.actors.get("doc") == null);
    try store.publish(2, .stopped, "other", "{}");
    try std.testing.expectEqual(@as(usize, 0), store.actors.count());
    try std.testing.expectError(error.StatechartRecordTooLarge, store.publish(2, .other, "", "x" ** (256 * 1024 + 1)));
}
