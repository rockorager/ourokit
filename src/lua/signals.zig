const std = @import("std");
const c = @import("c.zig");
const Handle = @import("../core/handle.zig").Handle;
const build_owner = @import("../ui/instance/build_owner.zig");

pub const SignalHandle = Handle;

pub const OwnerRef = struct {
    owners: *build_owner.BuildOwners,
    handle: build_owner.BuildOwnerHandle,
};

const SignalSlot = struct {
    generation: u32 = 0,
    active: bool = false,
};

const Edge = struct {
    active: bool = false,
    signal: SignalHandle = .invalid,
    owner: OwnerRef = undefined,
    reader: u64 = 0,
    dirty: bool = false,
};

const Read = struct { signal: SignalHandle = .invalid, reader: u64 = 0 };

const Phase = enum { idle, evaluating, awaiting_commit };

const SignalUserdata = struct {
    runtime: *Signals,
    handle: SignalHandle,
};

const metatable_name = "ouro.signal.v1";

/// Dependency graph for Lua-owned signal values. The configured capacities are
/// initial sizes: signal slots grow when a signal is created, pending reads and
/// readers while a build records reads, and subscription edges while a commit
/// is validated, so `commit`, `publish`, and release never allocate. Slots are
/// addressed only through generation-checked handles and indices, never by
/// retained pointer. This object and every referenced BuildOwners registry must
/// retain stable addresses. Owner subscriptions must be disposed before their
/// registry is destroyed.
pub const Signals = struct {
    allocator: std.mem.Allocator,
    state: *c.State,
    slots: []SignalSlot,
    /// Every slot below this index is active.
    free_hint: usize = 0,
    edges: []Edge,
    // One past the last active edge; holes remain reusable without moving edges.
    edge_extent: usize = 0,
    pending: []Read,
    pending_count: usize = 0,
    readers: []u64,
    reader_count: usize = 0,
    current_reader: u64 = 0,
    phase: Phase = .idle,
    evaluation_owner: ?OwnerRef = null,
    evaluation_revision: u64 = 0,

    pub fn init(
        self: *Signals,
        allocator: std.mem.Allocator,
        state: *c.State,
        signal_capacity: usize,
        subscription_capacity: usize,
        dependency_capacity: usize,
    ) !void {
        return self.initWithApiReference(
            allocator,
            state,
            signal_capacity,
            subscription_capacity,
            dependency_capacity,
            null,
        );
    }

    pub fn initWithApi(
        self: *Signals,
        allocator: std.mem.Allocator,
        state: *c.State,
        signal_capacity: usize,
        subscription_capacity: usize,
        dependency_capacity: usize,
        api_reference: c_int,
    ) !void {
        return self.initWithApiReference(
            allocator,
            state,
            signal_capacity,
            subscription_capacity,
            dependency_capacity,
            api_reference,
        );
    }

    fn initWithApiReference(
        self: *Signals,
        allocator: std.mem.Allocator,
        state: *c.State,
        signal_capacity: usize,
        subscription_capacity: usize,
        dependency_capacity: usize,
        api_reference: ?c_int,
    ) !void {
        if (signal_capacity == 0 or subscription_capacity == 0 or dependency_capacity == 0)
            return error.InvalidSignalCapacity;
        const slots = try allocator.alloc(SignalSlot, signal_capacity);
        errdefer allocator.free(slots);
        const edges = try allocator.alloc(Edge, subscription_capacity);
        errdefer allocator.free(edges);
        const pending = try allocator.alloc(Read, dependency_capacity);
        errdefer allocator.free(pending);
        const readers = try allocator.alloc(u64, subscription_capacity);
        errdefer allocator.free(readers);
        @memset(slots, .{});
        @memset(edges, .{});
        self.* = .{
            .allocator = allocator,
            .state = state,
            .slots = slots,
            .edges = edges,
            .pending = pending,
            .readers = readers,
        };
        try self.install(api_reference);
    }

    /// Close the associated Lua state first so signal `__gc` callbacks can
    /// release their slots while this runtime is still alive.
    pub fn deinit(self: *Signals) void {
        std.debug.assert(self.phase == .idle);
        for (self.slots) |slot| std.debug.assert(!slot.active);
        for (self.edges) |edge| std.debug.assert(!edge.active);
        self.allocator.free(self.readers);
        self.allocator.free(self.pending);
        self.allocator.free(self.edges);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn beginEvaluation(self: *Signals, owner: OwnerRef, revision: u64) !void {
        if (self.phase != .idle) return error.SignalEvaluationAlreadyActive;
        if (!owner.owners.isActive(owner.handle)) return error.StaleBuildOwner;
        self.pending_count = 0;
        self.evaluation_owner = owner;
        self.evaluation_revision = revision;
        self.phase = .evaluating;
        self.reader_count = 0;
        try self.selectReader(0);
    }

    /// Readers share a native scheduling owner but replace dependencies
    /// independently. Selection happens between non-yielding Lua callbacks.
    pub fn selectReader(self: *Signals, reader: u64) !void {
        if (self.phase != .evaluating) return error.SignalEvaluationNotActive;
        self.current_reader = reader;
        if (self.readerEvaluated(reader)) return;
        if (self.reader_count == self.readers.len) try self.grow(u64, &self.readers, self.reader_count + 1, 0);
        self.readers[self.reader_count] = reader;
        self.reader_count += 1;
    }

    /// Replace a speculative reader's reads without ending the transaction.
    /// An empty replacement also removes the committed edges of an omitted reader.
    pub fn restartReader(self: *Signals, reader: u64) !void {
        try self.selectReader(reader);
        var count: usize = 0;
        for (self.pending[0..self.pending_count]) |read| {
            if (read.reader == reader) continue;
            self.pending[count] = read;
            count += 1;
        }
        self.pending_count = count;
    }

    pub fn preserveRoot(self: *Signals) void {
        std.debug.assert(self.phase == .evaluating and self.pending_count == 0);
        self.reader_count = 0;
    }

    pub fn readerDirty(self: *Signals, reader: ?u64) bool {
        const owner = self.evaluation_owner orelse return false;
        for (self.edges[0..self.edge_extent]) |edge| if (edge.active and edge.dirty and sameOwner(edge.owner, owner) and
            (reader == null or edge.reader == reader.?)) return true;
        return false;
    }

    fn trimEdges(self: *Signals) void {
        while (self.edge_extent > 0 and !self.edges[self.edge_extent - 1].active)
            self.edge_extent -= 1;
    }

    fn readerEvaluated(self: *Signals, reader: u64) bool {
        for (self.readers[0..self.reader_count]) |evaluated| if (evaluated == reader) return true;
        return false;
    }

    pub fn finishEvaluation(self: *Signals, owner: OwnerRef, revision: u64) !void {
        try self.expectEvaluation(.evaluating, owner, revision);
        self.phase = .awaiting_commit;
    }

    pub fn abortEvaluation(self: *Signals, owner: OwnerRef, revision: u64) !void {
        try self.expectEvaluation(.evaluating, owner, revision);
        self.resetEvaluation();
    }

    /// Atomically replaces dependencies only after the owner's normalized
    /// descriptor output has reconciled successfully.
    pub fn validateCommit(self: *Signals, owner: OwnerRef, revision: u64) !void {
        try self.expectEvaluation(.awaiting_commit, owner, revision);
        var old_count: usize = 0;
        var free_count: usize = 0;
        for (self.edges) |edge| {
            if (!edge.active) free_count += 1 else if (sameOwner(edge.owner, owner) and
                self.readerEvaluated(edge.reader)) old_count += 1;
        }
        // Grow here, during validation, so commit itself cannot fail.
        if (self.pending_count > free_count + old_count)
            try self.grow(Edge, &self.edges, self.edges.len + self.pending_count - free_count - old_count, .{});
        for (self.pending[0..self.pending_count]) |read| _ = try self.signalSlot(read.signal);
    }

    pub fn commit(self: *Signals, owner: OwnerRef, revision: u64) !void {
        try self.validateCommit(owner, revision);

        for (self.edges) |*edge| {
            if (edge.active and sameOwner(edge.owner, owner) and self.readerEvaluated(edge.reader)) edge.* = .{};
        }
        self.trimEdges();
        for (self.pending[0..self.pending_count]) |read| {
            for (self.edges, 0..) |*edge, index| if (!edge.active) {
                edge.* = .{ .active = true, .signal = read.signal, .owner = owner, .reader = read.reader };
                self.edge_extent = @max(self.edge_extent, index + 1);
                break;
            };
        }
        self.resetEvaluation();
    }

    pub fn rollback(self: *Signals, owner: OwnerRef, revision: u64) !void {
        try self.expectEvaluation(.awaiting_commit, owner, revision);
        self.resetEvaluation();
    }

    pub fn disposeOwner(self: *Signals, owner: OwnerRef) !void {
        if (self.evaluation_owner) |active| if (sameOwner(active, owner))
            return error.SignalEvaluationActive;
        for (self.edges) |*edge| {
            if (edge.active and sameOwner(edge.owner, owner)) edge.* = .{};
        }
        self.trimEdges();
    }

    /// Reserves a dependency node whose value is owned by another Lua binding.
    /// The binding must release it from its userdata finalizer before the VM
    /// closes, and may read/publish it only at the same safe points as signals.
    pub fn createExternal(self: *Signals) !SignalHandle {
        return self.allocateSignal();
    }

    pub fn releaseExternal(self: *Signals, signal: SignalHandle) void {
        self.releaseSignal(signal);
    }

    pub fn readExternal(self: *Signals, signal: SignalHandle) !void {
        try self.recordRead(signal);
    }

    pub fn publishExternal(self: *Signals, signal: SignalHandle) !void {
        try self.publish(signal);
    }

    fn install(self: *Signals, api_reference: ?c_int) !void {
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        const api_type = if (api_reference) |reference|
            c.lua_rawgeti(self.state, c.registry_index, reference)
        else
            c.lua_getglobal(self.state, "ouro");
        if (api_type != c.type_table) return error.OuroApiMissing;

        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, createSignal, 1);
        c.lua_setfield(self.state, -2, "signal");

        _ = c.luaL_newmetatable(self.state, metatable_name);
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, readSignal, 1);
        c.lua_setfield(self.state, -2, "__call");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, collectSignal, 1);
        c.lua_setfield(self.state, -2, "__gc");
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, writeSignal, 1);
        c.lua_setfield(self.state, -2, "set");
        c.lua_pushvalue(self.state, -1);
        c.lua_setfield(self.state, -2, "__index");
    }

    fn allocateSignal(self: *Signals) !SignalHandle {
        const index = for (self.slots[self.free_hint..], self.free_hint..) |slot, index| {
            if (!slot.active) break index;
        } else blk: {
            const old_len = self.slots.len;
            try self.grow(SignalSlot, &self.slots, old_len + 1, .{});
            break :blk old_len;
        };
        const slot = &self.slots[index];
        var generation = slot.generation +% 1;
        if (generation == 0) generation = 1;
        slot.* = .{ .generation = generation, .active = true };
        self.free_hint = index + 1;
        return .{ .slot = @intCast(index), .generation = generation };
    }

    /// Doubles `items` until it holds at least `minimum` entries. Only creation
    /// paths call this; new entries are set to `fill`.
    fn grow(self: *Signals, comptime T: type, items: *[]T, minimum: usize, fill: T) !void {
        var length = items.len;
        while (length < minimum) length = std.math.mul(usize, length, 2) catch return error.SignalCapacityExceeded;
        if (length > std.math.maxInt(u32)) return error.SignalCapacityExceeded;
        const old_len = items.len;
        items.* = try self.allocator.realloc(items.*, length);
        @memset(items.*[old_len..], fill);
    }

    fn releaseSignal(self: *Signals, signal: SignalHandle) void {
        const slot = self.signalSlot(signal) catch return;
        for (self.edges[0..self.edge_extent]) |*edge| {
            if (edge.active and sameHandle(edge.signal, signal)) edge.* = .{};
        }
        self.trimEdges();
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
        self.free_hint = @min(self.free_hint, signal.slot);
    }

    fn recordRead(self: *Signals, signal: SignalHandle) !void {
        _ = try self.signalSlot(signal);
        if (self.phase == .idle) return;
        if (self.phase != .evaluating) return error.SignalCommitPending;
        for (self.pending[0..self.pending_count]) |existing|
            if (existing.reader == self.current_reader and sameHandle(existing.signal, signal)) return;
        if (self.pending_count == self.pending.len) try self.grow(Read, &self.pending, self.pending_count + 1, .{});
        self.pending[self.pending_count] = .{ .signal = signal, .reader = self.current_reader };
        self.pending_count += 1;
    }

    fn publish(self: *Signals, signal: SignalHandle) !void {
        if (self.phase != .idle) return error.SignalWriteDuringBuildTransaction;
        _ = try self.signalSlot(signal);
        defer self.trimEdges();
        for (self.edges) |*edge| {
            if (!edge.active or !sameHandle(edge.signal, signal)) continue;
            edge.dirty = true;
            _ = edge.owner.owners.markReaderDirty(edge.owner.handle) catch |err| switch (err) {
                error.StaleBuildOwner => {
                    edge.* = .{};
                    continue;
                },
                else => return err,
            };
        }
    }

    fn signalSlot(self: *Signals, signal: SignalHandle) !*SignalSlot {
        if (signal.slot >= self.slots.len) return error.StaleSignal;
        const slot = &self.slots[signal.slot];
        if (!slot.active or slot.generation != signal.generation) return error.StaleSignal;
        return slot;
    }

    fn expectEvaluation(
        self: *Signals,
        phase: Phase,
        owner: OwnerRef,
        revision: u64,
    ) !void {
        if (self.phase != phase or self.evaluation_owner == null or
            !sameOwner(self.evaluation_owner.?, owner) or self.evaluation_revision != revision)
            return error.StaleSignalEvaluation;
    }

    fn resetEvaluation(self: *Signals) void {
        self.pending_count = 0;
        self.evaluation_owner = null;
        self.evaluation_revision = 0;
        self.phase = .idle;
    }

    fn createSignal(state: *c.State) callconv(.c) c_int {
        const self = runtime(state) orelse return luaError(state, "invalid signal runtime");
        if (c.lua_gettop(state) != 1) return luaError(state, "ouro.signal expects one argument");
        const memory = c.lua_newuserdatauv(state, @sizeOf(SignalUserdata), 1) orelse
            return luaError(state, "cannot allocate signal");
        const handle = self.allocateSignal() catch return luaError(state, "signal capacity exceeded");
        const userdata: *SignalUserdata = @ptrCast(@alignCast(memory));
        userdata.* = .{ .runtime = self, .handle = handle };
        c.lua_pushvalue(state, 1);
        _ = c.lua_setiuservalue(state, -2, 1);
        _ = c.lua_getfield(state, c.registry_index, metatable_name);
        _ = c.lua_setmetatable(state, -2);
        return 1;
    }

    fn readSignal(state: *c.State) callconv(.c) c_int {
        const userdata = signalUserdata(state, 1) orelse return luaError(state, "invalid signal");
        // A released signal keeps its final value, read without tracking.
        if (!sameHandle(userdata.handle, Handle.invalid))
            userdata.runtime.recordRead(userdata.handle) catch return luaError(state, "cannot track signal read");
        _ = c.lua_getiuservalue(state, 1, 1);
        return 1;
    }

    fn writeSignal(state: *c.State) callconv(.c) c_int {
        const userdata = signalUserdata(state, 1) orelse return luaError(state, "invalid signal");
        if (c.lua_gettop(state) != 2) return luaError(state, "signal:set expects one value");
        if (sameHandle(userdata.handle, Handle.invalid)) return luaError(state, "signal was released");
        if (userdata.runtime.phase != .idle)
            return luaError(state, "signals cannot be written during a build transaction");
        _ = c.lua_getiuservalue(state, 1, 1);
        const equal = c.lua_rawequal(state, -1, 2) != 0;
        c.lua_settop(state, -2);
        if (equal) return 0;
        c.lua_pushvalue(state, 2);
        _ = c.lua_setiuservalue(state, 1, 1);
        userdata.runtime.publish(userdata.handle) catch return luaError(state, "cannot publish signal");
        return 0;
    }

    /// Pushes the private release function for runtime code (statechart
    /// actors), passed as a chunk argument like the scope binding and never
    /// installed on `ouro`. release(signal) frees the signal's slot and edges
    /// now instead of at garbage collection. It is idempotent and ignores
    /// values that are not signals. Afterwards the signal reads its final value
    /// without tracking, and writing it raises.
    pub fn pushRelease(state: *c.State) void {
        c.lua_pushcclosure(state, releaseLua, 0);
    }

    fn releaseLua(state: *c.State) callconv(.c) c_int {
        const userdata = signalUserdata(state, 1) orelse return 0;
        if (sameHandle(userdata.handle, Handle.invalid)) return 0;
        userdata.runtime.releaseSignal(userdata.handle);
        userdata.handle = .invalid;
        return 0;
    }

    fn collectSignal(state: *c.State) callconv(.c) c_int {
        const userdata = signalUserdata(state, 1) orelse return 0;
        userdata.runtime.releaseSignal(userdata.handle);
        userdata.handle = .invalid;
        return 0;
    }
};

fn runtime(state: *c.State) ?*Signals {
    const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn signalUserdata(state: *c.State, index: c_int) ?*SignalUserdata {
    const memory = c.luaL_testudata(state, index, metatable_name) orelse return null;
    return @ptrCast(@alignCast(memory));
}

fn sameHandle(a: Handle, b: Handle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sameOwner(a: OwnerRef, b: OwnerRef) bool {
    return a.owners == b.owners and sameHandle(a.handle, b.handle);
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "signal slots grow on creation and release frees them deterministically" {
    const state = c.luaL_newstate().?;
    c.lua_pushcclosure(state, c.ouro_open_safe_libraries, 0);
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 0, 0, 0, null));
    c.lua_createtable(state, 0, 1);
    c.lua_setglobal(state, "ouro");
    var signals: Signals = undefined;
    try signals.init(std.testing.allocator, state, 1, 1, 1);
    // Close Lua first so signal finalizers run while the runtime is alive.
    defer {
        c.lua_close(state);
        signals.deinit();
    }
    Signals.pushRelease(state);
    c.lua_setglobal(state, "release");
    const source =
        \\local list = {}
        \\for i = 1, 100 do list[i] = ouro.signal(i) end
        \\for i = 1, 100 do release(list[i]) end
        \\release(list[1]); release({}); release(nil)
        \\assert(list[7]() == 7, 'a released signal keeps its final value')
        \\assert(not pcall(list[7].set, list[7], 8), 'writing a released signal raises')
        \\kept = ouro.signal('kept')
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source, source.len, "=release", "t"));
    if (c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok) {
        var length: usize = 0;
        std.debug.print("{s}\n", .{c.lua_tolstring(state, -1, &length).?[0..length]});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(signals.slots.len >= 100);
    var active: usize = 0;
    for (signals.slots) |slot| {
        if (slot.active) active += 1;
    }
    // Only `kept` is live: released slots were reused, not leaked to the GC.
    try std.testing.expectEqual(@as(usize, 1), active);
}
