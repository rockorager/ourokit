//! Reactive system-output controls. The worker owns all PipeWire objects;
//! snapshots cross into Lua only through the host's I/O safe point.
const std = @import("std");
const c = @import("c.zig");
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const Vm = @import("vm.zig").Vm;
const signals_module = @import("signals.zig");
const native = @cImport({
    @cInclude("audio.h");
});
const metatable = "ouro.audio.output";
const Userdata = struct { job: ?*Job = null };
const Job = struct {
    owner: *Binding,
    native: *native.struct_ouro_audio,
    userdata: ?*Userdata,
    signal: signals_module.SignalHandle,
    resource: ?task.ResourceHandle = null,
    operation: ?io.OperationHandle = null,
    byte: [1]u8 = undefined,
    snapshot: native.struct_ouro_audio_snapshot = std.mem.zeroes(native.struct_ouro_audio_snapshot),
    closed: bool = false,
    revision: u64 = 1,
    seen_revision: u64 = 0,
    waiter: @import("vm.zig").TaskHandle = .invalid,
    waiting: bool = false,
    resumed: bool = false,
};

pub const Binding = struct {
    vm: *Vm,
    signals: *signals_module.Signals,
    jobs: [8]?*Job = @splat(null),
    stopping: bool = false,
    candidate: bool = false,

    pub fn init(self: *Binding, vm: *Vm, signals: *signals_module.Signals) void {
        self.* = .{ .vm = vm, .signals = signals };
        const L = vm.state;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        _ = c.luaL_newmetatable(L, metatable);
        inline for (.{ .{ "__call", read }, .{ "__gc", gc }, .{ "__close", close }, .{ "close", close }, .{ "next", next }, .{ "set_volume", setVolume }, .{ "adjust_volume", adjustVolume }, .{ "set_muted", setMuted } }) |entry| {
            c.lua_pushcclosure(L, entry[1], 0);
            c.lua_setfield(L, -2, entry[0]);
        }
        c.lua_pushvalue(L, -1);
        c.lua_setfield(L, -2, "__index");
        vm.pushApi(L);
        c.lua_createtable(L, 0, 1);
        c.lua_pushlightuserdata(L, self);
        c.lua_pushcclosure(L, defaultOutput, 1);
        c.lua_setfield(L, -2, "default_output");
        c.lua_setfield(L, -2, "audio");
    }

    pub fn dispatch(self: *Binding, completion: io.FileCompletion) !bool {
        for (self.jobs) |slot| if (slot) |job| {
            if (job.operation) |op| if (std.meta.eql(op, completion.operation)) {
                job.operation = null;
                native.ouro_audio_snapshot(job.native, &job.snapshot);
                job.revision += 1;
                if (job.waiting) {
                    job.waiting = false;
                    job.resumed = true;
                    try self.vm.markExternalCompleted(job.waiter);
                }
                if (!job.closed) try self.signals.publishExternal(job.signal);
                if (native.ouro_audio_done(job.native) == 0) {
                    job.operation = try self.vm.loop.prepareRead(native.ouro_audio_fd(job.native), &job.byte, std.math.maxInt(u64));
                } else job.closed = true;
                try self.collectCanceled();
                return true;
            };
        };
        return false;
    }

    pub fn collectCanceled(self: *Binding) !void {
        for (&self.jobs) |*slot| if (slot.*) |job| {
            if ((job.waiting or job.resumed) and self.vm.taskCancellationRequested(job.waiter)) {
                stopJob(job);
                if (job.waiting) {
                    job.waiting = false;
                    try self.vm.markExternalCompleted(job.waiter);
                }
                job.resumed = false;
            }
            if (!job.closed or job.waiting or job.resumed or job.operation != null or native.ouro_audio_done(job.native) == 0) continue;
            if (job.userdata) |ud| ud.job = null;
            if (job.resource) |resource| try self.vm.scheduler.destroyResource(resource);
            self.signals.releaseExternal(job.signal);
            native.ouro_audio_destroy(job.native);
            self.vm.allocator.destroy(job);
            slot.* = null;
        };
    }
    pub fn stop(self: *Binding) void {
        self.stopping = true;
        for (self.jobs) |slot| if (slot) |job| stopJob(job);
    }
    pub fn canDeinit(self: *const Binding) bool {
        for (self.jobs) |slot| if (slot != null) return false;
        return true;
    }
    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.canDeinit());
    }
};

fn defaultOutput(L: *c.State) callconv(.c) c_int {
    const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
    if (c.lua_gettop(L) != 0) return failure(L, "InvalidArguments");
    if (self.stopping) return failure(L, "AudioStopped");
    const scope = self.vm.currentScope(L) catch return failure(L, "TaskRequired");
    const slot = for (&self.jobs) |*slot| if (slot.* == null) break slot else continue else return failure(L, "AudioCapacityExceeded");
    const ud: *Userdata = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(Userdata), 0).?));
    ud.* = .{};
    _ = c.luaL_newmetatable(L, metatable);
    _ = c.lua_setmetatable(L, -2);
    const signal = self.signals.createExternal() catch return failure(L, "SignalCapacityExceeded");
    const job = self.vm.allocator.create(Job) catch {
        self.signals.releaseExternal(signal);
        return failure(L, "OutOfMemory");
    };
    const backend = native.ouro_audio_create() orelse {
        self.signals.releaseExternal(signal);
        self.vm.allocator.destroy(job);
        return failure(L, "AudioUnavailable");
    };
    job.* = .{ .owner = self, .native = backend, .userdata = ud, .signal = signal };
    job.resource = self.vm.scheduler.registerResource(scope, .service, job, &lifecycle) catch {
        native.ouro_audio_destroy(backend);
        self.signals.releaseExternal(signal);
        self.vm.allocator.destroy(job);
        return failure(L, "ResourceCapacityExceeded");
    };
    job.operation = self.vm.loop.prepareRead(native.ouro_audio_fd(backend), &job.byte, std.math.maxInt(u64)) catch {
        self.vm.scheduler.destroyResource(job.resource.?) catch unreachable;
        native.ouro_audio_destroy(backend);
        self.signals.releaseExternal(signal);
        self.vm.allocator.destroy(job);
        return failure(L, "CouldNotPrepare");
    };
    ud.job = job;
    slot.* = job;
    if (native.ouro_audio_launch(backend) != 0) {
        stopJob(job);
        return failure(L, "AudioUnavailable");
    }
    return 1;
}

fn read(L: *c.State) callconv(.c) c_int {
    const job = get(L) orelse return failure(L, "OutputClosed");
    job.owner.signals.readExternal(job.signal) catch return failure(L, "CouldNotTrackSignal");
    const s = &job.snapshot;
    c.lua_createtable(L, 0, 9);
    boolean(L, "connected", s.connected != 0);
    boolean(L, "available", s.available != 0);
    if (s.identity != 0) {
        c.lua_pushinteger(L, @intCast(s.identity));
        c.lua_setfield(L, -2, "identity");
        c.lua_pushinteger(L, s.id);
        c.lua_setfield(L, -2, "id");
        _ = c.lua_pushstring(L, @ptrCast(&s.name));
        c.lua_setfield(L, -2, "name");
        _ = c.lua_pushstring(L, @ptrCast(&s.description));
        c.lua_setfield(L, -2, "description");
    }
    if (s.available != 0) {
        c.lua_pushnumber(L, s.volume);
        c.lua_setfield(L, -2, "volume");
        boolean(L, "muted", s.muted != 0);
    }
    if (s.@"error" != 0) {
        _ = c.lua_pushstring(L, switch (s.@"error") {
            2 => "PermissionDenied",
            3 => "StaleOutput",
            4 => "AudioCapacityExceeded",
            else => "AudioBackendError",
        });
        c.lua_setfield(L, -2, "error");
    }
    return 1;
}
fn next(L: *c.State) callconv(.c) c_int {
    const job = get(L) orelse return failure(L, "OutputClosed");
    _ = job.owner.vm.currentScope(L) catch return failure(L, "TaskRequired");
    if (job.waiting or job.resumed) return failure(L, "AlreadyWaiting");
    if (job.seen_revision != job.revision) {
        job.seen_revision = job.revision;
        return read(L);
    }
    job.waiter = job.owner.vm.beginExternalWait(L, .operation, job, &lifecycle) catch return failure(L, "CouldNotPark");
    job.waiting = true;
    return c.lua_yieldk(L, 0, @bitCast(@intFromPtr(job)), continuation);
}
fn continuation(L: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const job: *Job = @ptrFromInt(@as(usize, @bitCast(context)));
    job.resumed = false;
    return next(L);
}
fn setVolume(L: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(L) != 2 or c.lua_type(L, 2) != c.type_number) return failure(L, "InvalidVolume");
    var valid: c_int = 0;
    const value = c.lua_tonumberx(L, 2, &valid);
    if (!std.math.isFinite(value) or value < 0 or value > 1) return failure(L, "InvalidVolume");
    return set(L, 0, value);
}
fn adjustVolume(L: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(L) != 2 or c.lua_type(L, 2) != c.type_number) return failure(L, "InvalidVolume");
    var valid: c_int = 0;
    const value = c.lua_tonumberx(L, 2, &valid);
    if (!std.math.isFinite(value) or value < -1 or value > 1) return failure(L, "InvalidVolume");
    return set(L, 2, value);
}
fn setMuted(L: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(L) != 2 or c.lua_type(L, 2) != c.type_boolean) return failure(L, "InvalidMute");
    return set(L, 1, @floatFromInt(c.lua_toboolean(L, 2)));
}
fn set(L: *c.State, kind: c_int, value: f64) c_int {
    const job = get(L) orelse return failure(L, "OutputClosed");
    _ = job.owner.vm.currentScope(L) catch return failure(L, "TaskRequired");
    if (job.owner.candidate) return failure(L, "AudioCandidate");
    if (job.snapshot.available == 0) return failure(L, "OutputUnavailable");
    switch (native.ouro_audio_set(job.native, job.snapshot.identity, kind, value)) {
        0 => {
            c.lua_pushboolean(L, 1);
            return 1;
        },
        1 => return failure(L, "OutputUnavailable"),
        2 => return failure(L, "AudioQueueFull"),
        else => return failure(L, "StaleOutput"),
    }
}
fn userdata(L: *c.State) ?*Userdata {
    return @ptrCast(@alignCast(c.luaL_testudata(L, 1, metatable) orelse return null));
}
fn get(L: *c.State) ?*Job {
    const job = (userdata(L) orelse return null).job orelse return null;
    return if (job.closed) null else job;
}
fn stopJob(job: *Job) void {
    job.closed = true;
    native.ouro_audio_stop(job.native);
}
fn close(L: *c.State) callconv(.c) c_int {
    if (userdata(L)) |ud| if (ud.job) |job| stopJob(job);
    c.lua_pushboolean(L, 1);
    return 1;
}
fn gc(L: *c.State) callconv(.c) c_int {
    if (userdata(L)) |ud| {
        if (ud.job) |job| {
            stopJob(job);
            job.userdata = null;
        }
        ud.job = null;
    }
    return 0;
}
fn cancel(pointer: *anyopaque) !void {
    stopJob(@ptrCast(@alignCast(pointer)));
}
fn destroy(_: *anyopaque) void {}
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = cancel, .destroy = destroy };
fn boolean(L: *c.State, key: [*:0]const u8, value: bool) void {
    c.lua_pushboolean(L, @intFromBool(value));
    c.lua_setfield(L, -2, key);
}
fn failure(L: *c.State, message: [*:0]const u8) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushstring(L, message);
    return 2;
}
