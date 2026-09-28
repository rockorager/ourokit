//! Bounded asynchronous PAM authentication. PAM and its conversation run only
//! on a native worker; this binding merely transports events to Lua.
const std = @import("std");
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");
const entry = @import("../ui/widget/auth_input.zig");

const native = struct {
    const Auth = opaque {};
    const Event = extern struct { kind: c_int, prompt_id: u64, echo: c_int, success: c_int, text: [513]u8 };
    extern fn ouro_auth_start(service: [*:0]const u8, user: [*:0]const u8) ?*Auth;
    extern fn ouro_auth_launch(auth: *Auth) void;
    extern fn ouro_auth_fd(auth: *Auth) c_int;
    extern fn ouro_auth_pop(auth: *Auth, event: *Event) c_int;
    extern fn ouro_auth_edit(auth: *Auth, id: u64, command: c_int, unicode: u32) c_int;
    extern fn ouro_auth_submit(auth: *Auth, id: u64) c_int;
    extern fn ouro_auth_clear_input(auth: *Auth, id: u64) c_int;
    extern fn ouro_auth_reason(auth: *Auth) c_int;
    extern fn ouro_auth_cancel(auth: *Auth) void;
    extern fn ouro_auth_done(auth: *Auth) c_int;
    extern fn ouro_auth_join_destroy(auth: *Auth) void;
};

pub const capacity = 4;
pub const max_service_bytes = 64;
pub const max_user_bytes = 256;
pub const max_response_bytes = 512;
const metatable = "ouro.auth.conversation";

const Job = struct {
    owner: *Binding,
    id: u64,
    auth: *native.Auth,
    operation: ?io.OperationHandle = null,
    task_handle: vm_module.TaskHandle = .invalid,
    signal: [1]u8 = undefined,
    closed: bool = false,
    waiting: bool = false,
    resumed: bool = false,
    userdata: ?*Userdata = null,
};
const Userdata = struct { job: ?*Job };

pub const Binding = struct {
    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    loop: *io.Loop,
    jobs: [capacity]?*Job = @splat(null),
    stopping: bool = false,
    next_id: u64 = 1,

    pub fn init(self: *Binding, allocator: std.mem.Allocator, vm: *vm_module.Vm, loop: *io.Loop) !void {
        self.* = .{ .allocator = allocator, .vm = vm, .loop = loop };
        const L = vm.state;
        const top = c.lua_gettop(L);
        defer c.lua_settop(L, top);
        _ = c.luaL_newmetatable(L, metatable);
        c.lua_pushcclosure(L, gc, 0);
        c.lua_setfield(L, -2, "__gc");
        c.lua_pushvalue(L, -1);
        c.lua_setfield(L, -2, "__index");
        c.lua_pushcclosure(L, next, 0);
        c.lua_setfield(L, -2, "next");
        c.lua_pushcclosure(L, submit, 0);
        c.lua_setfield(L, -2, "submit");
        c.lua_pushcclosure(L, clearInput, 0);
        c.lua_setfield(L, -2, "clear_input");
        c.lua_pushcclosure(L, cancel, 0);
        c.lua_setfield(L, -2, "cancel");
        c.lua_pushcclosure(L, cancel, 0);
        c.lua_setfield(L, -2, "close");
        c.lua_pushcclosure(L, cancel, 0);
        c.lua_setfield(L, -2, "__close");
        c.lua_settop(L, -2);
        vm.pushApi(L);
        c.lua_createtable(L, 0, 1);
        c.lua_pushlightuserdata(L, self);
        c.lua_pushcclosure(L, start, 1);
        c.lua_setfield(L, -2, "start");
        c.lua_setfield(L, -2, "auth");
    }

    pub fn dispatch(self: *Binding, completion: io.FileCompletion) !bool {
        for (&self.jobs) |*slot| if (slot.*) |job| {
            if (job.operation) |op| if (same(op, completion.operation)) {
                if (completion.kind != .read) return error.UnexpectedAuthCompletion;
                job.operation = null;
                if (job.waiting) {
                    job.waiting = false;
                    job.resumed = true;
                    try self.vm.markExternalCompleted(job.task_handle);
                }
                if (native.ouro_auth_done(job.auth) == 0)
                    job.operation = try self.loop.prepareRead(native.ouro_auth_fd(job.auth), &job.signal, std.math.maxInt(u64));
                return true;
            };
        };
        return false;
    }
    pub fn collectCanceled(self: *Binding) !void {
        for (self.jobs) |job| if (job) |j| {
            if ((j.waiting or j.resumed) and self.vm.taskCancellationRequested(j.task_handle)) {
                j.closed = true;
                native.ouro_auth_cancel(j.auth);
                if (j.waiting) {
                    j.waiting = false;
                    try self.vm.markExternalCompleted(j.task_handle);
                }
                j.resumed = false;
            }
        };
        self.collectFinished();
    }
    pub fn stop(self: *Binding) void {
        self.stopping = true;
        for (self.jobs) |job| if (job) |j| {
            j.closed = true;
            native.ouro_auth_cancel(j.auth);
        };
        self.collectFinished();
    }
    pub fn canDeinit(self: *const Binding) bool {
        for (self.jobs) |job| if (job != null) return false;
        return true;
    }
    pub fn deinit(self: *Binding) void {
        std.debug.assert(self.canDeinit());
        self.* = undefined;
    }

    fn collectFinished(self: *Binding) void {
        for (&self.jobs) |*slot| if (slot.*) |job| if (job.closed and !job.waiting and !job.resumed and job.operation == null and native.ouro_auth_done(job.auth) != 0) {
            if (job.userdata) |ud| ud.job = null;
            native.ouro_auth_join_destroy(job.auth);
            self.allocator.destroy(job);
            slot.* = null;
        };
    }
};

fn start(L: *c.State) callconv(.c) c_int {
    const self: *Binding = @ptrCast(@alignCast(c.lua_touserdata(L, c.upvalueIndex(1)).?));
    if (self.stopping or c.lua_gettop(L) != 2) return failure(L, "InvalidArguments");
    const service = checked(L, 1, max_service_bytes) orelse return failure(L, "InvalidService");
    for (service) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return failure(L, "InvalidService");
    const user = checked(L, 2, max_user_bytes) orelse return failure(L, "InvalidUsername");
    const slot = for (&self.jobs) |*s| if (s.* == null) break s else continue else return failure(L, "AuthBusy");
    var sbuf: [max_service_bytes + 1]u8 = undefined;
    var ubuf: [max_user_bytes + 1]u8 = undefined;
    @memcpy(sbuf[0..service.len], service);
    sbuf[service.len] = 0;
    @memcpy(ubuf[0..user.len], user);
    ubuf[user.len] = 0;
    const ud: *Userdata = @ptrCast(@alignCast(c.lua_newuserdatauv(L, @sizeOf(Userdata), 0).?));
    ud.* = .{ .job = null };
    _ = c.luaL_newmetatable(L, metatable);
    _ = c.lua_setmetatable(L, -2);
    const job = self.allocator.create(Job) catch return failure(L, "OutOfMemory");
    const handle = native.ouro_auth_start(@ptrCast(&sbuf), @ptrCast(&ubuf)) orelse {
        self.allocator.destroy(job);
        return failure(L, "AuthUnavailable");
    };
    job.* = .{ .owner = self, .auth = handle, .id = self.next_id };
    self.next_id += 1;
    slot.* = job;
    ud.job = job;
    job.userdata = ud;
    job.operation = self.loop.prepareRead(native.ouro_auth_fd(handle), &job.signal, std.math.maxInt(u64)) catch {
        ud.job = null;
        slot.* = null;
        native.ouro_auth_join_destroy(handle);
        self.allocator.destroy(job);
        return failure(L, "CouldNotPrepare");
    };
    native.ouro_auth_launch(handle);
    return 1;
}

fn next(L: *c.State) callconv(.c) c_int {
    const job = get(L) orelse return failure(L, "ConversationClosed");
    if (job.waiting or job.resumed) return failure(L, "AlreadyWaiting");
    if (job.closed) return failure(L, "ConversationClosed");
    var event: native.Event = undefined;
    if (native.ouro_auth_pop(job.auth, &event) != 0) {
        if (event.kind == 4) job.closed = true;
        return pushEvent(L, &event, job.auth);
    }
    if (native.ouro_auth_done(job.auth) != 0) return failure(L, "ConversationClosed");
    job.task_handle = job.owner.vm.beginExternalWait(L, .operation, job, &lifecycle) catch return failure(L, "CouldNotPark");
    job.waiting = true;
    return c.lua_yieldk(L, 0, @bitCast(@intFromPtr(job)), continuation);
}
fn continuation(L: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
    const job: *Job = @ptrFromInt(@as(usize, @bitCast(context)));
    job.resumed = false;
    if (job.closed) return failure(L, "ConversationClosed");
    var event: native.Event = undefined;
    if (native.ouro_auth_pop(job.auth, &event) != 0) {
        if (event.kind == 4) job.closed = true;
        return pushEvent(L, &event, job.auth);
    }
    // A previous event was consumed synchronously before its wake byte.
    return next(L);
}
fn submit(L: *c.State) callconv(.c) c_int {
    const job = get(L) orelse return failure(L, "ConversationClosed");
    if (job.closed) return failure(L, "ConversationClosed");
    var ok: c_int = 0;
    const id = c.lua_tointegerx(L, 2, &ok);
    if (ok == 0 or id <= 0 or c.lua_gettop(L) != 2) return failure(L, "InvalidPromptId");
    if (native.ouro_auth_submit(job.auth, @intCast(id)) == 0) return failure(L, "StalePrompt");
    c.lua_pushboolean(L, 1);
    return 1;
}
fn clearInput(L: *c.State) callconv(.c) c_int {
    const job = get(L) orelse return failure(L, "ConversationClosed");
    if (job.closed) return failure(L, "ConversationClosed");
    var ok: c_int = 0;
    const id = c.lua_tointegerx(L, 2, &ok);
    if (ok == 0 or id <= 0 or c.lua_gettop(L) != 2) return failure(L, "InvalidPromptId");
    if (native.ouro_auth_clear_input(job.auth, @intCast(id)) == 0) return failure(L, "StalePrompt");
    c.lua_pushboolean(L, 1);
    return 1;
}
fn cancel(L: *c.State) callconv(.c) c_int {
    if (userdata(L)) |ud| if (ud.job) |job| {
        job.closed = true;
        native.ouro_auth_cancel(job.auth);
    };
    c.lua_pushboolean(L, 1);
    return 1;
}
fn gc(L: *c.State) callconv(.c) c_int {
    if (userdata(L)) |ud| {
        if (ud.job) |job| {
            job.closed = true;
            job.userdata = null;
            native.ouro_auth_cancel(job.auth);
        }
        ud.job = null;
    }
    return 0;
}
fn requestCancel(pointer: *anyopaque) !void {
    const job: *Job = @ptrCast(@alignCast(pointer));
    job.closed = true;
    native.ouro_auth_cancel(job.auth);
}
fn destroy(_: *anyopaque) void {}
const lifecycle: task.ResourceLifecycle = .{ .request_cancel = requestCancel, .destroy = destroy };

fn userdata(L: *c.State) ?*Userdata {
    return @ptrCast(@alignCast(c.luaL_testudata(L, 1, metatable) orelse return null));
}
fn get(L: *c.State) ?*Job {
    return (userdata(L) orelse return null).job;
}
fn checked(L: *c.State, index: c_int, limit: usize) ?[]const u8 {
    if (c.lua_type(L, index) != c.type_string) return null;
    var len: usize = 0;
    const p = c.lua_tolstring(L, index, &len) orelse return null;
    const value = p[0..len];
    if ((len == 0 and limit != max_response_bytes) or len > limit or std.mem.indexOfScalar(u8, value, 0) != null) return null;
    return value;
}
fn pushEvent(L: *c.State, event: *const native.Event, auth: *native.Auth) c_int {
    c.lua_createtable(L, 0, 4);
    const kind: [*:0]const u8 = switch (event.kind) {
        1 => "prompt",
        2 => "info",
        3 => "error",
        4 => "result",
        else => "error",
    };
    _ = c.lua_pushstring(L, kind);
    c.lua_setfield(L, -2, "type");
    if (event.kind == 1) {
        c.lua_pushinteger(L, @intCast(event.prompt_id));
        c.lua_setfield(L, -2, "id");
        c.lua_pushboolean(L, event.echo);
        c.lua_setfield(L, -2, "echo");
    }
    if (event.kind >= 1 and event.kind <= 3) {
        const text = std.mem.sliceTo(&event.text, 0);
        _ = c.lua_pushlstring(L, text.ptr, text.len);
        c.lua_setfield(L, -2, "text");
    }
    if (event.kind == 4) {
        c.lua_pushboolean(L, event.success);
        c.lua_setfield(L, -2, "success");
        _ = c.lua_pushstring(L, switch (native.ouro_auth_reason(auth)) {
            0 => "success",
            1 => "denied",
            2 => "unavailable",
            3 => "canceled",
            4 => "timeout",
            else => "worker_failed",
        });
        c.lua_setfield(L, -2, "reason");
    }
    return 1;
}
fn failure(L: *c.State, message: [*:0]const u8) c_int {
    c.lua_pushnil(L);
    _ = c.lua_pushstring(L, message);
    return 2;
}
fn same(a: io.OperationHandle, b: io.OperationHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

pub fn inputFromTable(L: *c.State, table: c_int) !entry.Input {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    _ = c.lua_getfield(L, table, "conversation");
    const ud: *Userdata = @ptrCast(@alignCast(c.luaL_testudata(L, -1, metatable) orelse return error.InvalidConversation));
    const job = ud.job orelse return error.ConversationClosed;
    if (job.closed) return error.ConversationClosed;
    _ = c.lua_getfield(L, table, "prompt_id");
    var valid: c_int = 0;
    const id = c.lua_tointegerx(L, -1, &valid);
    if (valid == 0 or id <= 0) return error.InvalidPromptId;
    return .{ .context = job.owner, .job = job.id, .prompt = @intCast(id), .dispatch = entryAction };
}

fn entryAction(context: *anyopaque, id: u64, prompt: u64, command: entry.Command, unicode: u32) entry.Result {
    const self: *Binding = @ptrCast(@alignCast(context));
    for (self.jobs) |maybe| if (maybe) |job| {
        if (job.id != id or job.closed) continue;
        const result = switch (command) {
            .submit => native.ouro_auth_submit(job.auth, prompt),
            .clear => native.ouro_auth_clear_input(job.auth, prompt),
            .cancel => blk: {
                if (native.ouro_auth_clear_input(job.auth, prompt) == 0) break :blk @as(c_int, 0);
                job.closed = true;
                native.ouro_auth_cancel(job.auth);
                break :blk @as(c_int, 1);
            },
            else => native.ouro_auth_edit(job.auth, prompt, @intFromEnum(command), unicode),
        };
        return if (result == 1) .ok else if (result == -1) .full else .stale;
    };
    return .stale;
}
