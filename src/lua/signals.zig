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
};

const Phase = enum { idle, evaluating, awaiting_commit };

const SignalUserdata = struct {
    runtime: *Signals,
    handle: SignalHandle,
};

const metatable_name = "ouro.signal.v1";

/// Fixed-capacity dependency graph for Lua-owned signal values. This object and
/// every referenced BuildOwners registry must retain stable addresses. Owner
/// subscriptions must be disposed before their registry is destroyed.
pub const Signals = struct {
    allocator: std.mem.Allocator,
    state: *c.State,
    slots: []SignalSlot,
    edges: []Edge,
    pending: []SignalHandle,
    pending_count: usize = 0,
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
        const pending = try allocator.alloc(SignalHandle, dependency_capacity);
        errdefer allocator.free(pending);
        @memset(slots, .{});
        @memset(edges, .{});
        self.* = .{
            .allocator = allocator,
            .state = state,
            .slots = slots,
            .edges = edges,
            .pending = pending,
        };
        try self.install(api_reference);
    }

    /// Close the associated Lua state first so signal `__gc` callbacks can
    /// release their slots while this runtime is still alive.
    pub fn deinit(self: *Signals) void {
        std.debug.assert(self.phase == .idle);
        for (self.slots) |slot| std.debug.assert(!slot.active);
        for (self.edges) |edge| std.debug.assert(!edge.active);
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
            if (!edge.active) free_count += 1 else if (sameOwner(edge.owner, owner)) old_count += 1;
        }
        if (self.pending_count > free_count + old_count) return error.SubscriptionCapacityExceeded;
        for (self.pending[0..self.pending_count]) |signal| _ = try self.signalSlot(signal);
    }

    pub fn commit(self: *Signals, owner: OwnerRef, revision: u64) !void {
        try self.validateCommit(owner, revision);

        for (self.edges) |*edge| {
            if (edge.active and sameOwner(edge.owner, owner)) edge.* = .{};
        }
        for (self.pending[0..self.pending_count]) |signal| {
            for (self.edges) |*edge| if (!edge.active) {
                edge.* = .{ .active = true, .signal = signal, .owner = owner };
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
        for (self.slots, 0..) |*slot, index| if (!slot.active) {
            var generation = slot.generation +% 1;
            if (generation == 0) generation = 1;
            slot.* = .{ .generation = generation, .active = true };
            return .{ .slot = @intCast(index), .generation = generation };
        };
        return error.SignalCapacityExceeded;
    }

    fn releaseSignal(self: *Signals, signal: SignalHandle) void {
        const slot = self.signalSlot(signal) catch return;
        for (self.edges) |*edge| {
            if (edge.active and sameHandle(edge.signal, signal)) edge.* = .{};
        }
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
    }

    fn recordRead(self: *Signals, signal: SignalHandle) !void {
        _ = try self.signalSlot(signal);
        if (self.phase == .idle) return;
        if (self.phase != .evaluating) return error.SignalCommitPending;
        for (self.pending[0..self.pending_count]) |existing|
            if (sameHandle(existing, signal)) return;
        if (self.pending_count == self.pending.len) return error.DependencyCapacityExceeded;
        self.pending[self.pending_count] = signal;
        self.pending_count += 1;
    }

    fn publish(self: *Signals, signal: SignalHandle) !void {
        if (self.phase != .idle) return error.SignalWriteDuringBuildTransaction;
        _ = try self.signalSlot(signal);
        for (self.edges) |*edge| {
            if (!edge.active or !sameHandle(edge.signal, signal)) continue;
            _ = edge.owner.owners.markDirty(edge.owner.handle) catch |err| switch (err) {
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
        userdata.runtime.recordRead(userdata.handle) catch return luaError(state, "cannot track signal read");
        _ = c.lua_getiuservalue(state, 1, 1);
        return 1;
    }

    fn writeSignal(state: *c.State) callconv(.c) c_int {
        const userdata = signalUserdata(state, 1) orelse return luaError(state, "invalid signal");
        if (c.lua_gettop(state) != 2) return luaError(state, "signal:set expects one value");
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
