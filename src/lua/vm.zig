const std = @import("std");
const c = @import("c.zig");
const Handle = @import("../core/handle.zig").Handle;
const io = @import("../loop/io_uring.zig");
const task = @import("../task/scheduler.zig");

pub const TaskHandle = Handle;

pub const ResumeResult = enum {
    completed,
    waiting,
    canceled,
};

pub const Argument = union(enum) {
    number: f64,
    integer: i64,
    boolean: bool,
    string: []const u8,
};

const YieldRequest = enum {
    none,
    sleep,
    external,
};

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    next_free: u32 = invalid_slot,
    thread: ?*c.State = null,
    thread_reference: c_int = c.no_reference,
    scheduler_handle: task.TaskHandle = .invalid,
    scope: task.ScopeHandle = .invalid,
    pending_timeout: ?io.OperationHandle = null,
    timer_resource_handle: ?task.ResourceHandle = null,
    timer_resource: TimerResource = .{},
    external_resource_handle: ?task.ResourceHandle = null,
    external_pending: bool = false,
    requested_nanoseconds: u64 = 0,
    yield_request: YieldRequest = .none,
    resume_arguments: c_int = 0,
    retain_result: bool = false,
    completed_result_count: ?c_int = null,
};

const slots_per_chunk = 32;
const invalid_slot = std.math.maxInt(u32);

/// One isolated Lua state with growable stable-address slabs of scoped
/// coroutine tasks. The VM itself must retain a stable address because
/// Ouro-owned C closures and resource lifecycle records reference it. Lua's
/// standard libraries remain unopened.
pub const Vm = struct {
    allocator: std.mem.Allocator,
    scheduler: *task.Scheduler,
    loop: *io.Loop,
    state: *c.State,
    api_reference: c_int,
    chunks: [][]Slot,
    free_head: u32 = invalid_slot,
    scheduler_tasks: []?TaskHandle,
    operation_tasks: []?TaskHandle,
    running: ?TaskHandle = null,
    sleep_enabled: bool = true,

    pub fn init(
        self: *Vm,
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        loop: *io.Loop,
    ) !void {
        const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
        errdefer c.lua_close(state);
        const chunks = try allocator.alloc([]Slot, 0);
        errdefer allocator.free(chunks);
        const scheduler_tasks = try allocator.alloc(?TaskHandle, scheduler.taskCapacity());
        errdefer allocator.free(scheduler_tasks);
        const operation_tasks = try allocator.alloc(?TaskHandle, loop.operationCapacity());
        errdefer allocator.free(operation_tasks);
        @memset(scheduler_tasks, null);
        @memset(operation_tasks, null);
        c.lua_createtable(state, 0, 1);
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, sleep, 1);
        c.lua_setfield(state, -2, "sleep");
        const api_reference = c.luaL_ref(state, c.registry_index);

        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .loop = loop,
            .state = state,
            .api_reference = api_reference,
            .chunks = chunks,
            .scheduler_tasks = scheduler_tasks,
            .operation_tasks = operation_tasks,
        };

        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, builtinRequire, 1);
        c.lua_setglobal(state, "require");
    }

    pub fn deinit(self: *Vm) void {
        std.debug.assert(self.running == null);
        for (self.chunks) |chunk| {
            for (chunk) |slot| std.debug.assert(!slot.active);
        }
        for (self.scheduler_tasks) |entry| std.debug.assert(entry == null);
        for (self.operation_tasks) |entry| std.debug.assert(entry == null);
        c.luaL_unref(self.state, c.registry_index, self.api_reference);
        c.lua_close(self.state);
        self.allocator.free(self.operation_tasks);
        self.allocator.free(self.scheduler_tasks);
        for (self.chunks) |chunk| self.allocator.free(chunk);
        self.allocator.free(self.chunks);
        self.* = undefined;
    }

    /// Headless deterministic hosts disable wall-clock waits before invoking
    /// user callbacks. The Lua call then fails synchronously without creating
    /// an io_uring operation that would make snapshot completion time-based.
    pub fn disableSleep(self: *Vm) void {
        self.sleep_enabled = false;
    }

    pub fn spawnApplication(self: *Vm, source: []const u8) !TaskHandle {
        return self.spawn(self.scheduler.application_scope, source);
    }

    pub fn pushApi(self: *Vm, state: *c.State) void {
        const value_type = c.lua_rawgeti(state, c.registry_index, self.api_reference);
        std.debug.assert(value_type == c.type_table);
    }

    pub fn apiReference(self: *const Vm) c_int {
        return self.api_reference;
    }

    /// Loads a chunk into a new explicitly anchored coroutine and creates its
    /// language-neutral scheduler task under the supplied ownership scope.
    pub fn spawn(
        self: *Vm,
        scope: task.ScopeHandle,
        source: []const u8,
    ) !TaskHandle {
        return self.spawnNamed(scope, source, "@application", false);
    }

    /// Candidate bootstrap variant. Completion retains the coroutine and its
    /// one result until `takeRetainedResult` transfers that value to the main
    /// state for declaration parsing.
    pub fn spawnRetainedNamed(
        self: *Vm,
        scope: task.ScopeHandle,
        source: []const u8,
        chunk_name: [*:0]const u8,
    ) !TaskHandle {
        return self.spawnNamed(scope, source, chunk_name, true);
    }

    fn spawnNamed(
        self: *Vm,
        scope: task.ScopeHandle,
        source: []const u8,
        chunk_name: [*:0]const u8,
        retain_result: bool,
    ) !TaskHandle {
        const handle = try self.reserveSlot();
        var reserved = true;
        errdefer if (reserved) self.releaseSlot(handle);
        const main_top = c.lua_gettop(self.state);
        errdefer c.lua_settop(self.state, main_top);
        const thread = c.lua_newthread(self.state) orelse return error.LuaThreadCreationFailed;
        if (c.luaL_loadbufferx(thread, source.ptr, source.len, chunk_name, null) != c.ok) {
            _ = c.lua_closethread(thread, null);
            c.lua_settop(thread, 0);
            return error.LuaLoadFailed;
        }
        const scheduler_handle = try self.scheduler.createTask(scope);
        var scheduler_created = true;
        errdefer if (scheduler_created)
            self.scheduler.discardRunnableTask(scheduler_handle) catch unreachable;
        try self.ensureSchedulerMap(scheduler_handle.slot);
        const thread_reference = c.luaL_ref(self.state, c.registry_index);

        const slot = try self.activeSlot(handle);
        slot.* = .{
            .generation = handle.generation,
            .active = true,
            .thread = thread,
            .thread_reference = thread_reference,
            .scheduler_handle = scheduler_handle,
            .scope = scope,
            .timer_resource = .{ .vm = self, .task_handle = handle },
            .retain_result = retain_result,
        };
        std.debug.assert(self.scheduler_tasks[scheduler_handle.slot] == null);
        self.scheduler_tasks[scheduler_handle.slot] = handle;
        reserved = false;
        scheduler_created = false;
        return handle;
    }

    /// Creates a scoped coroutine from an existing Lua function. This is the
    /// task-phase invocation seam for event handlers; it does not run Lua.
    pub fn spawnGlobal(
        self: *Vm,
        scope: task.ScopeHandle,
        function_name: [*:0]const u8,
        arguments: []const Argument,
    ) !TaskHandle {
        const handle = try self.reserveSlot();
        var reserved = true;
        errdefer if (reserved) self.releaseSlot(handle);
        const main_top = c.lua_gettop(self.state);
        errdefer c.lua_settop(self.state, main_top);
        const thread = c.lua_newthread(self.state) orelse return error.LuaThreadCreationFailed;
        if (c.lua_getglobal(self.state, function_name) != c.type_function)
            return error.LuaFunctionMissing;
        c.lua_xmove(self.state, thread, 1);
        for (arguments) |argument| switch (argument) {
            .number => |value| c.lua_pushnumber(thread, value),
            .integer => |value| c.lua_pushinteger(thread, value),
            .boolean => |value| c.lua_pushboolean(thread, @intFromBool(value)),
            .string => |value| _ = c.lua_pushlstring(thread, value.ptr, value.len),
        };
        const scheduler_handle = try self.scheduler.createTask(scope);
        var scheduler_created = true;
        errdefer if (scheduler_created)
            self.scheduler.discardRunnableTask(scheduler_handle) catch unreachable;
        try self.ensureSchedulerMap(scheduler_handle.slot);
        const thread_reference = c.luaL_ref(self.state, c.registry_index);
        const slot = try self.activeSlot(handle);
        slot.* = .{
            .generation = handle.generation,
            .active = true,
            .thread = thread,
            .thread_reference = thread_reference,
            .scheduler_handle = scheduler_handle,
            .scope = scope,
            .timer_resource = .{ .vm = self, .task_handle = handle },
            .resume_arguments = @intCast(arguments.len),
        };
        self.scheduler_tasks[scheduler_handle.slot] = handle;
        reserved = false;
        scheduler_created = false;
        return handle;
    }

    pub fn spawnReference(
        self: *Vm,
        scope: task.ScopeHandle,
        reference: c_int,
        arguments: []const Argument,
    ) !TaskHandle {
        const handle = try self.reserveSlot();
        var reserved = true;
        errdefer if (reserved) self.releaseSlot(handle);
        const main_top = c.lua_gettop(self.state);
        errdefer c.lua_settop(self.state, main_top);
        const thread = c.lua_newthread(self.state) orelse return error.LuaThreadCreationFailed;
        if (c.lua_rawgeti(self.state, c.registry_index, reference) != c.type_function)
            return error.LuaFunctionMissing;
        c.lua_xmove(self.state, thread, 1);
        for (arguments) |argument| switch (argument) {
            .number => |value| c.lua_pushnumber(thread, value),
            .integer => |value| c.lua_pushinteger(thread, value),
            .boolean => |value| c.lua_pushboolean(thread, @intFromBool(value)),
            .string => |value| _ = c.lua_pushlstring(thread, value.ptr, value.len),
        };
        const scheduler_handle = try self.scheduler.createTask(scope);
        var scheduler_created = true;
        errdefer if (scheduler_created)
            self.scheduler.discardRunnableTask(scheduler_handle) catch unreachable;
        try self.ensureSchedulerMap(scheduler_handle.slot);
        const thread_reference = c.luaL_ref(self.state, c.registry_index);
        const slot = try self.activeSlot(handle);
        slot.* = .{
            .generation = handle.generation,
            .active = true,
            .thread = thread,
            .thread_reference = thread_reference,
            .scheduler_handle = scheduler_handle,
            .scope = scope,
            .timer_resource = .{ .vm = self, .task_handle = handle },
            .resume_arguments = @intCast(arguments.len),
        };
        self.scheduler_tasks[scheduler_handle.slot] = handle;
        reserved = false;
        scheduler_created = false;
        return handle;
    }

    /// Candidate `ouro.app.run(context)` invocation. The sole return value is
    /// retained so native declaration parsing can happen after any opaque
    /// asynchronous yields complete.
    pub fn spawnRetainedRun(
        self: *Vm,
        scope: task.ScopeHandle,
        reference: c_int,
        instance_id: []const u8,
    ) !TaskHandle {
        const handle = try self.reserveSlot();
        var reserved = true;
        errdefer if (reserved) self.releaseSlot(handle);
        const main_top = c.lua_gettop(self.state);
        errdefer c.lua_settop(self.state, main_top);
        const thread = c.lua_newthread(self.state) orelse return error.LuaThreadCreationFailed;
        if (c.lua_rawgeti(self.state, c.registry_index, reference) != c.type_function)
            return error.LuaFunctionMissing;
        c.lua_xmove(self.state, thread, 1);
        c.lua_createtable(thread, 0, 1);
        _ = c.lua_pushlstring(thread, instance_id.ptr, instance_id.len);
        c.lua_setfield(thread, -2, "instance_id");
        const scheduler_handle = try self.scheduler.createTask(scope);
        var scheduler_created = true;
        errdefer if (scheduler_created)
            self.scheduler.discardRunnableTask(scheduler_handle) catch unreachable;
        try self.ensureSchedulerMap(scheduler_handle.slot);
        const thread_reference = c.luaL_ref(self.state, c.registry_index);
        const slot = try self.activeSlot(handle);
        slot.* = .{
            .generation = handle.generation,
            .active = true,
            .thread = thread,
            .thread_reference = thread_reference,
            .scheduler_handle = scheduler_handle,
            .scope = scope,
            .timer_resource = .{ .vm = self, .task_handle = handle },
            .resume_arguments = 1,
            .retain_result = true,
        };
        self.scheduler_tasks[scheduler_handle.slot] = handle;
        reserved = false;
        scheduler_created = false;
        return handle;
    }

    /// Must only run after Scheduler.takeRunnable grants task-phase execution.
    pub fn resumeRunnable(
        self: *Vm,
        scheduler_handle: task.TaskHandle,
    ) !ResumeResult {
        const handle = try self.handleForSchedulerTask(scheduler_handle);
        const slot = try self.activeSlot(handle);
        if (self.running != null) return error.LuaVmReentered;
        self.running = handle;
        defer self.running = null;

        if (try self.scheduler.cancellationRequested(scheduler_handle)) {
            if (slot.pending_timeout != null or slot.external_pending) {
                try self.scheduler.wait(scheduler_handle);
                return .waiting;
            }
            if (slot.timer_resource_handle) |resource| {
                try self.scheduler.destroyResource(resource);
                slot.timer_resource_handle = null;
            }
            try self.scheduler.complete(scheduler_handle);
            if (self.closeTask(handle) != c.ok) return error.LuaThreadCloseFailed;
            return .canceled;
        }

        slot.yield_request = .none;
        var result_count: c_int = 0;
        const resume_arguments = slot.resume_arguments;
        slot.resume_arguments = 0;
        const status = c.lua_resume(slot.thread.?, self.state, resume_arguments, &result_count);
        switch (status) {
            c.ok => {
                try self.scheduler.complete(scheduler_handle);
                if (slot.retain_result) {
                    slot.completed_result_count = result_count;
                    self.scheduler_tasks[scheduler_handle.slot] = null;
                    return .completed;
                }
                if (self.closeTask(handle) != c.ok) return error.LuaThreadCloseFailed;
                return .completed;
            },
            c.yield => {
                switch (slot.yield_request) {
                    .none => {
                        try self.scheduler.complete(scheduler_handle);
                        _ = self.closeTask(handle);
                        return error.UnsupportedYield;
                    },
                    .sleep => {
                        slot.timer_resource_handle = self.scheduler.registerResource(
                            slot.scope,
                            .timer,
                            &slot.timer_resource,
                            &timer_lifecycle,
                        ) catch |err| {
                            try self.scheduler.complete(scheduler_handle);
                            _ = self.closeTask(handle);
                            return err;
                        };
                        const operation = self.loop.prepareTimeout(slot.requested_nanoseconds) catch |err| {
                            try self.scheduler.destroyResource(slot.timer_resource_handle.?);
                            slot.timer_resource_handle = null;
                            try self.scheduler.complete(scheduler_handle);
                            _ = self.closeTask(handle);
                            return err;
                        };
                        slot.pending_timeout = operation;
                        try self.ensureOperationMap(operation.slot);
                        std.debug.assert(self.operation_tasks[operation.slot] == null);
                        self.operation_tasks[operation.slot] = handle;
                    },
                    .external => slot.external_pending = true,
                }
                try self.scheduler.wait(scheduler_handle);
                return .waiting;
            },
            else => {
                try self.scheduler.complete(scheduler_handle);
                _ = self.closeTask(handle);
                return error.LuaRuntimeError;
            },
        }
    }

    /// Completion-phase state transition only. It cannot invoke Lua.
    pub fn markTimeoutCompleted(self: *Vm, operation: io.OperationHandle) !void {
        if (operation.slot >= self.operation_tasks.len) return error.StaleOperation;
        const handle = self.operation_tasks[operation.slot] orelse return error.StaleOperation;
        const slot = try self.activeSlot(handle);
        const pending = slot.pending_timeout orelse return error.StaleOperation;
        if (!same(pending, operation)) return error.StaleOperation;
        self.operation_tasks[operation.slot] = null;
        slot.pending_timeout = null;
        try self.scheduler.destroyResource(slot.timer_resource_handle.?);
        slot.timer_resource_handle = null;
        try self.scheduler.markRunnable(slot.scheduler_handle);
    }

    /// Registers externally-owned asynchronous work for the running Lua task.
    /// The caller must immediately yield from `state`; the scheduler then owns
    /// cancellation through `lifecycle`. This function never submits I/O.
    pub fn beginExternalWait(
        self: *Vm,
        state: *c.State,
        kind: task.ResourceKind,
        context: *anyopaque,
        lifecycle: *const task.ResourceLifecycle,
    ) !TaskHandle {
        const handle = self.running orelse return error.LuaTaskNotRunning;
        const slot = try self.activeSlot(handle);
        if (slot.thread != state) return error.WrongLuaTask;
        if (slot.yield_request != .none or slot.pending_timeout != null or
            slot.external_resource_handle != null or slot.external_pending)
            return error.LuaTaskAlreadyWaiting;
        const resource = try self.scheduler.registerResource(
            slot.scope,
            kind,
            context,
            lifecycle,
        );
        slot.external_resource_handle = resource;
        slot.yield_request = .external;
        return handle;
    }

    /// Rolls back registration when an external operation could not be
    /// prepared. This is valid only before the C callback yields.
    pub fn abortExternalWait(
        self: *Vm,
        state: *c.State,
        handle: TaskHandle,
    ) !void {
        if (self.running == null or !same(self.running.?, handle))
            return error.LuaTaskNotRunning;
        const slot = try self.activeSlot(handle);
        if (slot.thread != state) return error.WrongLuaTask;
        if (slot.yield_request != .external or slot.external_pending)
            return error.LuaTaskNotWaiting;
        try self.scheduler.destroyResource(slot.external_resource_handle.?);
        slot.external_resource_handle = null;
        slot.yield_request = .none;
    }

    /// Completion-phase transition for an external wait. Resource data must
    /// be published before this call. Lua runs only after the task phase takes
    /// the newly-runnable scheduler task.
    pub fn markExternalCompleted(self: *Vm, handle: TaskHandle) !void {
        const slot = try self.activeSlot(handle);
        if (!slot.external_pending) return error.LuaTaskNotWaiting;
        slot.external_pending = false;
        try self.scheduler.destroyResource(slot.external_resource_handle.?);
        slot.external_resource_handle = null;
        try self.scheduler.markRunnable(slot.scheduler_handle);
    }

    /// Moves the sole retained result to the main state and releases the
    /// bootstrap coroutine. The caller owns the main-state stack value.
    pub fn takeRetainedResult(self: *Vm, handle: TaskHandle) !void {
        const slot = try self.activeSlot(handle);
        const result_count = slot.completed_result_count orelse
            return error.LuaTaskNotCompleted;
        if (!slot.retain_result or result_count != 1)
            return error.LuaBootstrapResultRequired;
        c.lua_xmove(slot.thread.?, self.state, 1);
        if (self.closeTask(handle) != c.ok) return error.LuaThreadCloseFailed;
    }

    pub fn hasGlobal(self: *Vm, name: [*:0]const u8) bool {
        const value_type = c.lua_getglobal(self.state, name);
        c.lua_settop(self.state, -2);
        return value_type != c.type_nil;
    }

    pub fn globalBoolean(self: *Vm, name: [*:0]const u8) bool {
        _ = c.lua_getglobal(self.state, name);
        const value = c.lua_toboolean(self.state, -1) != 0;
        c.lua_settop(self.state, -2);
        return value;
    }

    pub fn activeTaskCount(self: *const Vm) usize {
        var count: usize = 0;
        for (self.chunks) |chunk| for (chunk) |slot| if (slot.active) {
            count += 1;
        };
        return count;
    }

    pub fn ownsSchedulerTask(self: *Vm, handle: task.TaskHandle) bool {
        _ = self.handleForSchedulerTask(handle) catch return false;
        return true;
    }

    pub fn ownsOperation(self: *Vm, operation: io.OperationHandle) bool {
        if (operation.slot >= self.operation_tasks.len) return false;
        const handle = self.operation_tasks[operation.slot] orelse return false;
        const slot = self.activeSlot(handle) catch return false;
        const pending = slot.pending_timeout orelse return false;
        return same(pending, operation);
    }

    /// Cancels only tasks and resources created by this VM. Their retained
    /// native scopes remain usable by a replacement source generation.
    pub fn requestCancellation(self: *Vm) !void {
        for (self.chunks) |chunk| for (chunk) |*slot| if (slot.active) {
            if (slot.timer_resource_handle) |resource|
                try self.scheduler.requestResourceCancellation(resource);
            if (slot.external_resource_handle) |resource|
                try self.scheduler.requestResourceCancellation(resource);
            try self.scheduler.requestTaskCancellation(slot.scheduler_handle);
        };
    }

    fn closeTask(self: *Vm, handle: TaskHandle) c_int {
        const slot = self.activeSlot(handle) catch return c.ok;
        std.debug.assert(slot.pending_timeout == null and slot.timer_resource_handle == null and
            !slot.external_pending and slot.external_resource_handle == null);
        const status = c.lua_closethread(slot.thread.?, null);
        c.lua_settop(slot.thread.?, 0);
        c.luaL_unref(self.state, c.registry_index, slot.thread_reference);
        if (self.scheduler_tasks[slot.scheduler_handle.slot]) |mapped| {
            if (same(mapped, handle)) self.scheduler_tasks[slot.scheduler_handle.slot] = null;
        }
        self.releaseSlot(handle);
        return status;
    }

    fn activeSlot(self: *Vm, handle: TaskHandle) !*Slot {
        const slot = self.slotAt(handle.slot) orelse return error.StaleLuaTask;
        if (!slot.active or slot.generation != handle.generation) return error.StaleLuaTask;
        return slot;
    }

    fn reserveSlot(self: *Vm) !TaskHandle {
        if (self.free_head == invalid_slot) try self.growSlots();
        const index = self.free_head;
        const slot = self.slotAt(index).?;
        self.free_head = slot.next_free;
        var generation = slot.generation +% 1;
        if (generation == 0) generation = 1;
        slot.* = .{ .generation = generation, .active = true };
        return .{ .slot = index, .generation = generation };
    }

    fn releaseSlot(self: *Vm, handle: TaskHandle) void {
        const slot = self.slotAt(handle.slot).?;
        std.debug.assert(slot.active and slot.generation == handle.generation);
        slot.* = .{ .generation = handle.generation, .next_free = self.free_head };
        self.free_head = handle.slot;
    }

    fn growSlots(self: *Vm) !void {
        if (self.chunks.len >= std.math.maxInt(u32) / slots_per_chunk)
            return error.LuaTaskCapacityExceeded;
        const chunk = try self.allocator.alloc(Slot, slots_per_chunk);
        errdefer self.allocator.free(chunk);
        const old_count = self.chunks.len;
        self.chunks = try self.allocator.realloc(self.chunks, old_count + 1);
        self.chunks[old_count] = chunk;
        const base: u32 = @intCast(old_count * slots_per_chunk);
        for (chunk, 0..) |*slot, offset| {
            const next = if (offset + 1 < slots_per_chunk)
                base + @as(u32, @intCast(offset + 1))
            else
                self.free_head;
            slot.* = .{ .next_free = next };
        }
        self.free_head = base;
    }

    fn slotAt(self: *Vm, index: u32) ?*Slot {
        const chunk_index = index / slots_per_chunk;
        if (chunk_index >= self.chunks.len) return null;
        return &self.chunks[chunk_index][index % slots_per_chunk];
    }

    fn ensureSchedulerMap(self: *Vm, slot: u32) !void {
        if (slot < self.scheduler_tasks.len) return;
        var new_len = self.scheduler_tasks.len;
        while (slot >= new_len) new_len = std.math.mul(usize, new_len, 2) catch
            return error.LuaTaskCapacityExceeded;
        const old_len = self.scheduler_tasks.len;
        self.scheduler_tasks = try self.allocator.realloc(self.scheduler_tasks, new_len);
        @memset(self.scheduler_tasks[old_len..], null);
    }

    fn ensureOperationMap(self: *Vm, slot: u32) !void {
        if (slot < self.operation_tasks.len) return;
        var new_len = self.operation_tasks.len;
        while (slot >= new_len) new_len = std.math.mul(usize, new_len, 2) catch
            return error.TimerCapacityExceeded;
        const old_len = self.operation_tasks.len;
        self.operation_tasks = try self.allocator.realloc(self.operation_tasks, new_len);
        @memset(self.operation_tasks[old_len..], null);
    }

    fn handleForSchedulerTask(
        self: *Vm,
        scheduler_handle: task.TaskHandle,
    ) !TaskHandle {
        if (scheduler_handle.slot >= self.scheduler_tasks.len) return error.StaleTask;
        const handle = self.scheduler_tasks[scheduler_handle.slot] orelse return error.StaleTask;
        const slot = try self.activeSlot(handle);
        if (!same(slot.scheduler_handle, scheduler_handle)) return error.StaleTask;
        return handle;
    }

    fn sleep(state: *c.State) callconv(.c) c_int {
        const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse
            return luaError(state, "missing Ouro VM");
        const self: *Vm = @ptrCast(@alignCast(pointer));
        if (!self.sleep_enabled) return luaError(state, "sleep is unavailable in deterministic playback");
        const handle = self.running orelse return luaError(state, "sleep called outside a task");
        const slot = self.activeSlot(handle) catch return luaError(state, "stale Ouro task");
        if (slot.thread != state) return luaError(state, "wrong Ouro task");
        if (slot.yield_request != .none or slot.pending_timeout != null or slot.external_pending)
            return luaError(state, "task already has pending I/O");
        var is_number: c_int = 0;
        const milliseconds = c.lua_tointegerx(state, 1, &is_number);
        if (is_number == 0 or milliseconds < 0)
            return luaError(state, "ouro.sleep expects non-negative milliseconds");
        slot.requested_nanoseconds = std.math.mul(
            u64,
            @intCast(milliseconds),
            std.time.ns_per_ms,
        ) catch return luaError(state, "ouro.sleep duration is too large");
        slot.yield_request = .sleep;
        return c.lua_yieldk(state, 0, 0, sleepContinuation);
    }

    fn sleepContinuation(_: *c.State, _: c_int, _: c.KContext) callconv(.c) c_int {
        return 0;
    }

    fn builtinRequire(state: *c.State) callconv(.c) c_int {
        const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse
            return luaError(state, "missing Ouro VM");
        const self: *Vm = @ptrCast(@alignCast(pointer));
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_string)
            return luaError(state, "require expects one module name");
        var length: usize = 0;
        const name = c.lua_tolstring(state, 1, &length) orelse
            return luaError(state, "require expects one module name");
        if (!std.mem.eql(u8, name[0..length], "ouro"))
            return luaError(state, "application module loading is unavailable");
        self.pushApi(state);
        return 1;
    }
};

const TimerResource = struct {
    vm: *Vm = undefined,
    task_handle: TaskHandle = .invalid,

    fn requestCancel(pointer: *anyopaque) !void {
        const resource: *TimerResource = @ptrCast(@alignCast(pointer));
        const slot = try resource.vm.activeSlot(resource.task_handle);
        const operation = slot.pending_timeout orelse return;
        try resource.vm.loop.prepareCancel(operation);
        resource.vm.operation_tasks[operation.slot] = null;
        slot.pending_timeout = null;
    }

    fn destroy(_: *anyopaque) void {}
};

const timer_lifecycle: task.ResourceLifecycle = .{
    .request_cancel = TimerResource.requestCancel,
    .destroy = TimerResource.destroy,
};

fn same(a: Handle, b: Handle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

const TestExternalWait = struct {
    vm: *Vm,
    handle: TaskHandle = .invalid,
    canceled: bool = false,
    destroyed: bool = false,

    fn install(self: *TestExternalWait) void {
        c.lua_pushlightuserdata(self.vm.state, self);
        c.lua_pushcclosure(self.vm.state, wait, 1);
        c.lua_setglobal(self.vm.state, "wait_external");
    }

    fn wait(state: *c.State) callconv(.c) c_int {
        const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse
            return luaError(state, "missing external wait");
        const self: *TestExternalWait = @ptrCast(@alignCast(pointer));
        self.handle = self.vm.beginExternalWait(
            state,
            .operation,
            self,
            &test_external_lifecycle,
        ) catch return luaError(state, "could not begin external wait");
        return c.lua_yieldk(state, 0, 0, continuation);
    }

    fn continuation(_: *c.State, _: c_int, _: c.KContext) callconv(.c) c_int {
        return 0;
    }

    fn requestCancel(pointer: *anyopaque) !void {
        const self: *TestExternalWait = @ptrCast(@alignCast(pointer));
        self.canceled = true;
    }

    fn destroy(pointer: *anyopaque) void {
        const self: *TestExternalWait = @ptrCast(@alignCast(pointer));
        self.destroyed = true;
    }
};

const test_external_lifecycle: task.ResourceLifecycle = .{
    .request_cancel = TestExternalWait.requestCancel,
    .destroy = TestExternalWait.destroy,
};

test "external waits resume only in task phase and drain before cancellation" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 2, 2);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();

    var completed: TestExternalWait = .{ .vm = &vm };
    completed.install();
    _ = try vm.spawnApplication("wait_external(); resumed = true");
    try std.testing.expectEqual(
        ResumeResult.waiting,
        try vm.resumeRunnable(scheduler.takeRunnable().?),
    );
    try vm.markExternalCompleted(completed.handle);
    try std.testing.expect(completed.destroyed);
    try std.testing.expect(!vm.globalBoolean("resumed"));
    try std.testing.expectEqual(
        ResumeResult.completed,
        try vm.resumeRunnable(scheduler.takeRunnable().?),
    );
    try std.testing.expect(vm.globalBoolean("resumed"));

    var canceled: TestExternalWait = .{ .vm = &vm };
    canceled.install();
    _ = try vm.spawnApplication("wait_external(); canceled_resumed = true");
    try std.testing.expectEqual(
        ResumeResult.waiting,
        try vm.resumeRunnable(scheduler.takeRunnable().?),
    );
    try vm.requestCancellation();
    try std.testing.expect(canceled.canceled);
    try std.testing.expectEqual(@as(usize, 1), vm.activeTaskCount());
    // Completion may win the race with the cancellation-runnable task. Both
    // transitions converge without entering Lua from this completion call.
    try vm.markExternalCompleted(canceled.handle);
    try std.testing.expect(canceled.destroyed);
    try std.testing.expectEqual(
        ResumeResult.canceled,
        try vm.resumeRunnable(scheduler.takeRunnable().?),
    );
    try std.testing.expect(!vm.hasGlobal("canceled_resumed"));
}

test "retained bootstrap task transfers exactly one result to the main state" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 0);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();

    const retained = try vm.spawnRetainedNamed(
        scheduler.application_scope,
        "return 42",
        "@bootstrap.lua",
    );
    const runnable = scheduler.takeRunnable().?;
    try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(runnable));
    try std.testing.expect(!vm.ownsSchedulerTask(runnable));
    try std.testing.expectEqual(@as(usize, 1), vm.activeTaskCount());
    try vm.takeRetainedResult(retained);
    try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
    var is_integer: c_int = 0;
    try std.testing.expectEqual(@as(c.Integer, 42), c.lua_tointegerx(vm.state, -1, &is_integer));
    try std.testing.expectEqual(@as(c_int, 1), is_integer);
    c.lua_settop(vm.state, -2);
}

test "callback string arguments preserve UTF-8 bytes and embedded NUL" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 0);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();

    _ = try vm.spawnApplication("function receive(value) received = value end");
    try std.testing.expectEqual(
        ResumeResult.completed,
        try vm.resumeRunnable(scheduler.takeRunnable().?),
    );
    const value = "héllo\x00世界";
    _ = try vm.spawnGlobal(
        scheduler.application_scope,
        "receive",
        &.{.{ .string = value }},
    );
    try std.testing.expectEqual(
        ResumeResult.completed,
        try vm.resumeRunnable(scheduler.takeRunnable().?),
    );
    try std.testing.expectEqual(c.type_string, c.lua_getglobal(vm.state, "received"));
    defer c.lua_settop(vm.state, -2);
    var length: usize = 0;
    const received = c.lua_tolstring(vm.state, -1, &length).?;
    try std.testing.expectEqualStrings(value, received[0..length]);
}
