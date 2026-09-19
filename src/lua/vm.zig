const std = @import("std");
const c = @import("c.zig");
const Handle = @import("../core/handle.zig").Handle;
const io = @import("../loop/io_uring.zig");
const task = @import("../task/scheduler.zig");
const json = @import("mcp_client.zig");
const activation = @import("activation.zig");
const platform_activation = @import("../platform/activation.zig");

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
    registry: c_int,
};

const YieldRequest = enum {
    none,
    sleep,
    external,
    exit,
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
    activation_input: ?platform_activation.Input = null,
    activation_job: ?*activation.Job = null,
};

const slots_per_chunk = 32;
const invalid_slot = std.math.maxInt(u32);

/// One isolated Lua state with growable stable-address slabs of scoped
/// coroutine tasks. The VM itself must retain a stable address because
/// Ouro-owned C closures and resource lifecycle records reference it. Only
/// allowlisted computation libraries are exposed; Ouro owns I/O and scheduling.
pub const Vm = struct {
    pub const NativeModule = struct { name: []const u8, reference: c_int };

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
    activation_provider: ?platform_activation.Provider = null,
    popup_provider: ?@import("popup.zig").Provider = null,
    /// First explicit exit request. The host drains output, cancels tasks,
    /// and tears down; this VM never exits the process or resumes user Lua.
    exit_code: ?u8 = null,
    /// Borrowed registration table; its native contexts outlive lua_close.
    native_modules: []const NativeModule = &.{},

    pub fn init(
        self: *Vm,
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        loop: *io.Loop,
    ) !void {
        const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
        errdefer c.lua_close(state);
        c.lua_pushcclosure(state, c.ouro_open_safe_libraries, 0);
        if (c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok)
            return error.LuaLibraryInitializationFailed;
        const chunks = try allocator.alloc([]Slot, 0);
        errdefer allocator.free(chunks);
        const scheduler_tasks = try allocator.alloc(?TaskHandle, scheduler.taskCapacity());
        errdefer allocator.free(scheduler_tasks);
        const operation_tasks = try allocator.alloc(?TaskHandle, loop.operationCapacity());
        errdefer allocator.free(operation_tasks);
        @memset(scheduler_tasks, null);
        @memset(operation_tasks, null);
        c.lua_createtable(state, 0, 5);
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, sleep, 1);
        c.lua_setfield(state, -2, "sleep");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, spawnChild, 1);
        c.lua_setfield(state, -2, "spawn");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, activation.request, 1);
        c.lua_setfield(state, -2, "activation_token");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, @import("popup.zig").open, 1);
        c.lua_setfield(state, -2, "popup");
        c.lua_pushcclosure(state, c.ouro_os_time, 0);
        c.lua_setfield(state, -2, "time");
        c.lua_pushcclosure(state, c.ouro_os_date, 0);
        c.lua_setfield(state, -2, "date");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, requestExit, 1);
        c.lua_setfield(state, -2, "exit");
        c.lua_createtable(state, 0, 4);
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, jsonEncode, 1);
        c.lua_setfield(state, -2, "encode");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, jsonDecode, 1);
        c.lua_setfield(state, -2, "decode");
        c.lua_pushcclosure(state, jsonArray, 0);
        c.lua_setfield(state, -2, "array");
        try json.pushJson(state, .null);
        c.lua_setfield(state, -2, "null");
        c.lua_setfield(state, -2, "json");
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

    /// Publish the host's XDG runtime directory without exposing the environment.
    /// Lua owns a copy; absent/empty values leave runtime_dir nil.
    pub fn setRuntimeDirectory(self: *Vm, directory: ?[]const u8) void {
        self.pushApi(self.state);
        if (c.lua_getfield(self.state, -1, "xdg") != c.type_table) {
            c.lua_settop(self.state, -2);
            c.lua_createtable(self.state, 0, 1);
        }
        if (directory) |value| {
            if (value.len != 0) {
                _ = c.lua_pushlstring(self.state, value.ptr, value.len);
            } else c.lua_pushnil(self.state);
        } else c.lua_pushnil(self.state);
        c.lua_setfield(self.state, -2, "runtime_dir");
        c.lua_setfield(self.state, -2, "xdg");
        c.lua_settop(self.state, -2);
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
            .registry => |reference| _ = c.lua_rawgeti(thread, c.registry_index, reference),
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
            .registry => |value| _ = c.lua_rawgeti(thread, c.registry_index, value),
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

    /// Invokes a callback as a task, retaining its return values for the caller.
    pub fn spawnRetainedReference(
        self: *Vm,
        scope: task.ScopeHandle,
        reference: c_int,
        arguments: []const Argument,
    ) !TaskHandle {
        const handle = try self.spawnReference(scope, reference, arguments);
        (try self.activeSlot(handle)).retain_result = true;
        return handle;
    }

    pub fn schedulerHandle(self: *Vm, handle: TaskHandle) !task.TaskHandle {
        return (try self.activeSlot(handle)).scheduler_handle;
    }

    pub fn setActivationInput(self: *Vm, handle: TaskHandle, input: ?platform_activation.Input) !void {
        (try self.activeSlot(handle)).activation_input = input;
    }

    pub fn takeActivationInput(self: *Vm, state: *c.State) !platform_activation.Input {
        const slot = try self.activeSlot(self.running orelse return error.NoActivationInput);
        if (slot.thread != state) return error.WrongLuaTask;
        const input = slot.activation_input orelse return error.NoActivationInput;
        slot.activation_input = null;
        return input;
    }

    pub fn retainActivationJob(self: *Vm, handle: TaskHandle, job: *activation.Job) void {
        const slot = self.activeSlot(handle) catch unreachable;
        std.debug.assert(slot.activation_job == null);
        slot.activation_job = job;
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

        if (self.exit_code != null) {
            try self.scheduler.wait(scheduler_handle);
            return .waiting;
        }

        slot.yield_request = .none;
        var result_count: c_int = 0;
        const resume_arguments = slot.resume_arguments;
        slot.resume_arguments = 0;
        const status = c.lua_resume(slot.thread.?, self.state, resume_arguments, &result_count);
        // Input provenance expires at the callback's first yield; child tasks
        // and later timer/DBus continuations cannot reuse a press.
        slot.activation_input = null;
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
                    .exit => {},
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

    /// Returns the scope of the currently running Lua coroutine.
    pub fn currentScope(self: *Vm, state: *c.State) !task.ScopeHandle {
        const slot = try self.activeSlot(self.running orelse return error.LuaTaskNotRunning);
        if (slot.thread != state) return error.WrongLuaTask;
        return slot.scope;
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

    /// Action calls use Lua's single-value convention: no return becomes nil,
    /// and additional return values are discarded. Always releases the task.
    pub fn takeRetainedValue(self: *Vm, handle: TaskHandle) !void {
        const slot = try self.activeSlot(handle);
        if (!slot.retain_result or slot.completed_result_count == null)
            return error.LuaTaskNotCompleted;
        c.lua_settop(slot.thread.?, 1);
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

    /// External adapters may discard a published result when its task was
    /// canceled before consuming it, including after the task was released.
    pub fn taskCancellationRequested(self: *Vm, handle: TaskHandle) bool {
        const slot = self.activeSlot(handle) catch return true;
        return self.scheduler.cancellationRequested(slot.scheduler_handle) catch true;
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
        if (slot.activation_job) |job| job.deinit();
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

    fn requestExit(state: *c.State) callconv(.c) c_int {
        const self: *Vm = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
        const handle = self.running orelse return luaError(state, "exit called outside a task");
        const slot = self.activeSlot(handle) catch return luaError(state, "stale Ouro task");
        if (slot.thread != state) return luaError(state, "wrong Ouro task");
        var code: c.Integer = 0;
        if (c.lua_gettop(state) != 0) {
            if (c.lua_gettop(state) != 1 or c.lua_isinteger(state, 1) == 0)
                return luaError(state, "ouro.exit expects an optional integer code from 0 to 255");
            var valid: c_int = 0;
            code = c.lua_tointegerx(state, 1, &valid);
            if (code < 0 or code > 255)
                return luaError(state, "ouro.exit expects an optional integer code from 0 to 255");
        }
        if (self.exit_code == null) self.exit_code = @intCast(code);
        slot.yield_request = .exit;
        return c.lua_yieldk(state, 0, 0, sleepContinuation);
    }

    fn jsonArray(state: *c.State) callconv(.c) c_int {
        if (c.lua_gettop(state) == 0) {
            c.lua_createtable(state, 0, 0);
        } else if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table) {
            return luaError(state, "ouro.json.array expects an optional dense sequence table");
        }
        json.markJsonArray(state, 1) catch
            return luaError(state, "JSON arrays must contain only contiguous integer keys starting at 1");
        return 1;
    }

    fn jsonEncode(state: *c.State) callconv(.c) c_int {
        if (c.lua_gettop(state) != 1) return luaError(state, "ouro.json.encode expects one value");
        const self: *Vm = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        var count: usize = 0;
        const value = json.luaToJson(state, 1, arena.allocator(), 0, &count) catch {
            arena.deinit();
            c.lua_settop(state, 1);
            return luaError(state, "value cannot be encoded as JSON");
        };
        const bytes = std.json.Stringify.valueAlloc(arena.allocator(), value, .{}) catch {
            arena.deinit();
            return luaError(state, "could not encode JSON");
        };
        _ = c.lua_pushlstring(state, bytes.ptr, bytes.len);
        arena.deinit();
        return 1;
    }

    fn jsonDecode(state: *c.State) callconv(.c) c_int {
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_string)
            return luaError(state, "ouro.json.decode expects one JSON string");
        const self: *Vm = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
        var length: usize = 0;
        const bytes = c.lua_tolstring(state, 1, &length).?;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes[0..length], .{}) catch
            return luaError(state, "invalid JSON");
        json.pushJson(state, parsed.value) catch {
            parsed.deinit();
            c.lua_settop(state, 1);
            return luaError(state, "JSON cannot be represented in Lua");
        };
        parsed.deinit();
        return 1;
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

    fn spawnChild(state: *c.State) callconv(.c) c_int {
        const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse
            return luaError(state, "missing Ouro VM");
        const self: *Vm = @ptrCast(@alignCast(pointer));
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_function)
            return luaError(state, "ouro.spawn expects exactly one function");
        const parent = self.running orelse return luaError(state, "ouro.spawn called outside a task");
        const slot = self.activeSlot(parent) catch return luaError(state, "stale Ouro task");
        if (slot.thread != state) return luaError(state, "wrong Ouro task");

        c.lua_pushvalue(state, 1);
        const reference = c.luaL_ref(state, c.registry_index);
        _ = self.spawnReference(slot.scope, reference, &.{}) catch {
            c.luaL_unref(state, c.registry_index, reference);
            return luaError(state, "could not spawn Ouro task");
        };
        c.luaL_unref(state, c.registry_index, reference);
        return 0;
    }

    fn sleepContinuation(_: *c.State, _: c_int, _: c.KContext) callconv(.c) c_int {
        return 0;
    }

    pub fn pushNativeModule(self: *Vm, state: *c.State, name: []const u8) bool {
        for (self.native_modules) |module| if (std.mem.eql(u8, module.name, name)) {
            _ = c.lua_rawgeti(state, c.registry_index, module.reference);
            return true;
        };
        return false;
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
        if (self.pushNativeModule(state, name[0..length])) return 1;
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

test "Lua XDG runtime directory is copied and absent values clear it" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 1);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();

    var directory = "/run/user/1234".*;
    vm.setRuntimeDirectory(&directory);
    @memset(&directory, 'x');
    _ = try vm.spawnApplication(
        \\local xdg = require('ouro').xdg
        \\runtime_ok = xdg.runtime_dir == '/run/user/1234'
        \\xdg.retained = true
    );
    try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(vm.globalBoolean("runtime_ok"));
    for ([_]?[]const u8{ null, "" }) |absent| {
        vm.setRuntimeDirectory("/another/runtime");
        vm.setRuntimeDirectory(absent);
        _ = try vm.spawnApplication(
            \\local xdg = require('ouro').xdg
            \\runtime_cleared = xdg.runtime_dir == nil and xdg.retained == true
        );
        try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expect(vm.globalBoolean("runtime_cleared"));
        try std.testing.expectEqual(@as(c_int, 0), c.lua_gettop(vm.state));
    }
}

test "safe Lua libraries expose only computation helpers with standard UTF-8 semantics" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 2, 2);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    try std.testing.expectEqual(@as(c_int, 0), c.lua_gettop(vm.state));

    // Check the entire initial global surface, not only known forbidden names.
    // Global enumeration is host-side: apps have no _G or metatable access.
    _ = c.lua_rawgeti(vm.state, c.registry_index, 2); // LUA_RIDX_GLOBALS
    var globals: usize = 0;
    c.lua_pushnil(vm.state);
    while (c.lua_next(vm.state, -2) != 0) {
        var length: usize = 0;
        const key = c.lua_tolstring(vm.state, -2, &length).?;
        const allowed = [_][]const u8{ "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "tonumber", "tostring", "type", "xpcall", "string", "table", "math", "utf8", "require" };
        var found = false;
        for (allowed) |name| if (std.mem.eql(u8, name, key[0..length])) {
            found = true;
            break;
        };
        try std.testing.expect(found);
        globals += 1;
        c.lua_settop(vm.state, -2);
    }
    c.lua_settop(vm.state, -2);
    try std.testing.expectEqual(@as(usize, 16), globals);

    _ = try vm.spawnApplication(
        \\local function check_fields(lib, names)
        \\  local expected = {}; for name in names:gmatch('%S+') do expected[name] = true end
        \\  for name in pairs(lib) do assert(expected[name], name); expected[name] = nil end
        \\  assert(next(expected) == nil)
        \\end
        \\check_fields(string, 'byte char find format gmatch gsub len lower match rep reverse sub upper pack packsize unpack')
        \\check_fields(table, 'concat create insert pack unpack remove move sort')
        \\check_fields(math, 'abs acos asin atan ceil cos deg exp tointeger floor fmod frexp ult ldexp log max min modf rad sin sqrt tan type pi huge maxinteger mininteger')
        \\check_fields(utf8, 'offset codepoint char len codes charpattern')
        \\assert(string.dump == nil and ('').dump == nil)
        \\assert(math.random == nil and math.randomseed == nil)
        \\assert(not pcall(require, 'io') and not pcall(require, 'package'))
        \\assert(type(require('ouro').sleep) == 'function')
        \\assert(tonumber('ff', 16) == 255 and tostring(-23) == '-23')
        \\assert(select('#', 1, nil, 3) == 3)
        \\local sum = 0
        \\for i, v in ipairs({4, 7, 9}) do sum = sum + i * v end
        \\assert(sum == 45)
        \\local names = { z=3, a=7 }; sum = 0
        \\for _, v in pairs(names) do sum = sum + v end
        \\assert(sum == 10 and next({}) == nil)
        \\assert(('a\0B'):sub(2) == '\0B' and string.format('%s:%02d', 'row', 7) == 'row:07')
        \\local changed, n = string.gsub('a12 b3', '%d+', '#')
        \\assert(changed == 'a# b#' and n == 2)
        \\local packed = string.pack('<I2', 513)
        \\assert(packed == '\1\2' and string.unpack('<I2', packed) == 513)
        \\local values = table.pack(9, nil, 4); assert(values.n == 3)
        \\local a, b, d = table.unpack(values, 1, 3); assert(a == 9 and b == nil and d == 4)
        \\values = {9, -2, 4}; table.sort(values); table.insert(values, 2, 3)
        \\assert(table.remove(values, 4) == 9 and table.concat(values, ',') == '-2,3,4')
        \\table.move(values, 1, 2, 2); assert(table.concat(values, ',') == '-2,-2,3')
        \\values = table.create(300)
        \\for i = 1, 300 do values[i] = (i * 97) % 301 end
        \\table.sort(values); for i = 1, 300 do assert(values[i] == i) end
        \\assert(math.floor(-2.3) == -3 and math.sqrt(81) == 9 and math.tointeger(2.5) == nil)
        \\assert(math.type(4) == 'integer' and math.maxinteger > 0 and math.mininteger < 0)
        \\assert(math.pi > 3.14 and math.pi < 3.15 and math.huge > math.maxinteger)
        \\local text = 'Aé🙂\0'
        \\assert(utf8.len(text) == 4 and utf8.codepoint(text, 2) == 233)
        \\assert(utf8.char(65, 233, 0x1f642, 0) == text)
        \\local first, last = utf8.offset(text, 3); assert(first == 4 and last == 7)
        \\local positions = {}; for pos, cp in utf8.codes(text) do positions[#positions+1] = pos end
        \\assert(table.concat(positions, ',') == '1,2,4,8')
        \\local count, bad = utf8.len('a\255b'); assert(count == nil and bad == 2)
        \\assert(not pcall(function() for _ in utf8.codes('\255') do end end))
        \\local surrogate = '\237\160\128'
        \\assert(utf8.len(surrogate) == nil and utf8.len(surrogate, 1, -1, true) == 1)
        \\assert(utf8.codepoint(surrogate, 1, 1, true) == 0xd800)
        \\local ok, err = pcall(error, 'expected', 0); assert(not ok and err == 'expected')
        \\ok, err = xpcall(function() error('bad', 0) end, function(e) return 'caught:' .. e end)
        \\assert(not ok and err == 'caught:bad')
        \\libraries_ok = true
    );
    try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(vm.globalBoolean("libraries_ok"));
}

test "Ouro clock and spawned coroutine APIs are scoped and asynchronous" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 4, 4);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();

    _ = try vm.spawnApplication(
        \\local ouro = require('ouro')
        \\assert(ouro.date('!%Y-%m-%d %H:%M:%S', 0) == '1970-01-01 00:00:00')
        \\local now = ouro.time(); assert(math.type(now) == 'integer' and now > 1700000000)
        \\assert(os == nil and execute == nil and remove == nil and package == nil)
        \\assert(not pcall(ouro.spawn) and not pcall(ouro.spawn, 1))
        \\assert(not pcall(ouro.spawn, function() end, function() end))
        \\assert(not pcall(ouro.date) and not pcall(ouro.date, 1))
        \\outside_fn = function() end
        \\ouro.spawn(function()
        \\  child_started = true
        \\  ouro.sleep(0)
        \\  child_finished = true
        \\end)
        \\assert(child_started == nil)
        \\parent_finished = true
    );
    try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(vm.globalBoolean("parent_finished"));
    try std.testing.expect(!vm.hasGlobal("child_started"));
    vm.pushApi(vm.state);
    _ = c.lua_getfield(vm.state, -1, "spawn");
    _ = c.lua_getglobal(vm.state, "outside_fn");
    try std.testing.expect(c.lua_pcallk(vm.state, 1, 0, 0, 0, null) != c.ok);
    c.lua_settop(vm.state, 0);

    const child_scheduler = scheduler.takeRunnable().?;
    try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(child_scheduler));
    try std.testing.expect(vm.globalBoolean("child_started"));
    try std.testing.expect(!vm.hasGlobal("child_finished"));
    try vm.markTimeoutCompleted((try loop.takeExpired()).?.operation);
    try std.testing.expect(!vm.hasGlobal("child_finished"));
    try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(vm.globalBoolean("child_finished"));

    _ = try vm.spawnApplication(
        \\local ouro = require('ouro')
        \\ouro.spawn(function() ouro.sleep(0); canceled_continuation = true end)
    );
    try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    const canceled_scheduler = scheduler.takeRunnable().?;
    try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(canceled_scheduler));
    try vm.markTimeoutCompleted((try loop.takeExpired()).?.operation);
    try scheduler.requestTaskCancellation(canceled_scheduler);
    try std.testing.expectEqual(ResumeResult.canceled, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(!vm.hasGlobal("canceled_continuation"));
}

test "safe Lua protected calls yield through Ouro and cannot catch cancellation" {
    inline for (.{ "pcall", "xpcall" }) |protected| {
        var scheduler: task.Scheduler = undefined;
        try scheduler.init(std.testing.allocator, 1, 2, 2);
        defer scheduler.deinit();
        var loop: io.Loop = undefined;
        try loop.init(std.testing.allocator, 8, 8);
        defer loop.deinit();
        var vm: Vm = undefined;
        try vm.init(std.testing.allocator, &scheduler, &loop);
        defer vm.deinit();
        const source = "local ok, result = " ++ protected ++
            "(function() wait_external(); return 37 end, function(e) caught = true; return e end); " ++
            "assert(ok and result == 37); resumed = true";

        var completed: TestExternalWait = .{ .vm = &vm };
        completed.install();
        _ = try vm.spawnApplication(source);
        try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try vm.markExternalCompleted(completed.handle);
        try std.testing.expect(completed.destroyed);
        try std.testing.expect(!vm.hasGlobal("resumed"));
        try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expect(vm.globalBoolean("resumed"));

        var failed: TestExternalWait = .{ .vm = &vm };
        failed.install();
        _ = try vm.spawnApplication("local ok, err = " ++ protected ++
            "(function() wait_external(); error('after wait', 0) end, function(e) return e .. ':handled' end); " ++
            "assert(not ok and err == 'after wait" ++ (if (comptime std.mem.eql(u8, protected, "xpcall")) ":handled" else "") ++ "'); failure_handled = true");
        try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try vm.markExternalCompleted(failed.handle);
        try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expect(vm.globalBoolean("failure_handled"));

        var canceled: TestExternalWait = .{ .vm = &vm };
        canceled.install();
        _ = try vm.spawnApplication("resumed = false; " ++ source);
        try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try vm.requestCancellation();
        try std.testing.expect(canceled.canceled);
        try vm.markExternalCompleted(canceled.handle);
        try std.testing.expectEqual(ResumeResult.canceled, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expect(canceled.destroyed);
        try std.testing.expect(!vm.globalBoolean("resumed"));
        try std.testing.expect(!vm.hasGlobal("caught"));
        try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
    }
}

test "activation tokens preserve callback provenance and cancellation ownership" {
    const Fake = struct {
        requests: [2]?*platform_activation.Request = .{ null, null },
        canceled: usize = 0,
        fn start(context: *anyopaque, request: *platform_activation.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (&self.requests) |*slot| if (slot.* == null) {
                slot.* = request;
                return;
            };
            return error.Busy;
        }
        fn cancel(context: *anyopaque, request: *platform_activation.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (&self.requests) |*slot| if (slot.* == request) {
                slot.* = null;
                self.canceled += 1;
                return;
            };
        }
        fn finish(self: *@This(), index: usize, token: []const u8) !void {
            const request = self.requests[index].?;
            self.requests[index] = null;
            try request.complete(request.context, token);
        }
    };
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 8, 8);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var provider: Fake = .{};
    const input: platform_activation.Input = .{ .window = .{ .slot = 3, .generation = 7 }, .serial = 191 };
    _ = try vm.spawnApplication("local t,e = require('ouro').activation_token(); assert(t == nil and e.name == 'NoActivationInput')");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    const unsupported = try vm.spawnApplication("local t,e = require('ouro').activation_token(); assert(t == nil and e.name == 'ActivationUnavailable')");
    try vm.setActivationInput(unsupported, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    vm.activation_provider = .{ .context = &provider, .start = Fake.start, .cancel = Fake.cancel };
    const first = try vm.spawnApplication("local o = require('ouro'); assert(o.activation_token() == 'first'); assert(o.activation_token() == nil)");
    const second = try vm.spawnApplication("assert(require('ouro').activation_token() == 'second')");
    try vm.setActivationInput(first, input);
    const other: platform_activation.Input = .{ .window = .{ .slot = 4, .generation = 9 }, .serial = 273 };
    try vm.setActivationInput(second, other);
    try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expectEqual(input, provider.requests[0].?.input);
    try std.testing.expectEqual(other, provider.requests[1].?.input);
    try provider.finish(1, "second");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try provider.finish(0, "first");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);

    const delayed = try vm.spawnApplication("local o=require('ouro'); o.spawn(function() assert(o.activation_token() == nil) end); o.sleep(0); assert(o.activation_token() == nil)");
    try vm.setActivationInput(delayed, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try vm.markTimeoutCompleted((try loop.takeExpired()).?.operation);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);

    // Both pending cancellation and completion followed by cancellation must
    // free token storage without resuming user Lua or retaining host pointers.
    for ([_]bool{ false, true }) |complete_first| {
        const pending = try vm.spawnApplication("require('ouro').activation_token(); error('must not resume')");
        try vm.setActivationInput(pending, input);
        _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
        if (complete_first) try provider.finish(0, "discarded");
        try vm.requestCancellation();
        try std.testing.expectEqual(ResumeResult.canceled, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expect(provider.requests[0] == null);
    }
    try std.testing.expectEqual(@as(usize, 1), provider.canceled);
}

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

test "Lua JSON API preserves nested values, null, integers, and binary escapes" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 1);
    defer scheduler.deinit();
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();

    _ = try vm.spawnApplication(
        \\local j = require('ouro').json
        \\local v = j.decode(' {"a":[true,null,-7,2.5],"n":9007199254740993,"s":"a\\u0000b","é":"ok"} ')
        \\json_ok = v.a[1] == true and v.a[2] == j.null and v.a[3] == -7 and v.a[4] == 2.5
        \\    and v.n == 9007199254740993 and v.s == 'a\0b' and v['é'] == 'ok'
        \\local r = j.decode(j.encode(v))
        \\roundtrip_ok = r.a[2] == j.null and r.n == 9007199254740993 and r.s == 'a\0b'
        \\encode_ok = j.encode({true, j.null, -7, 'x'}) == '[true,null,-7,"x"]'
        \\    and j.encode(nil) == 'null' and j.encode({}) == '{}'
        \\arrays_ok = j.encode(j.decode('[]')) == '[]' and j.encode(j.decode('{}')) == '{}'
        \\    and j.encode(j.decode('[[],{},[null,[]]]')) == '[[],{},[null,[]]]'
        \\    and j.encode(j.array()) == '[]' and j.encode(j.array({})) == '[]'
        \\local a = {1, j.null, 3}; local marked = j.array(a)
        \\arrays_ok = arrays_ok and a == marked and j.encode(marked) == '[1,null,3]'
        \\a[1] = nil; a[2] = nil; a[3] = nil
        \\arrays_ok = arrays_ok and j.encode(a) == '[]'
    );
    try std.testing.expectEqual(ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    try std.testing.expect(vm.globalBoolean("json_ok"));
    try std.testing.expect(vm.globalBoolean("roundtrip_ok"));
    try std.testing.expect(vm.globalBoolean("encode_ok"));
    try std.testing.expect(vm.globalBoolean("arrays_ok"));

    for ([_][]const u8{
        "require('ouro').json.decode('{')",
        "require('ouro').json.decode('true false')",
        "require('ouro').json.decode(7)",
        "require('ouro').json.encode(function() end)",
        "require('ouro').json.encode({1, a=2})",
        "require('ouro').json.encode(0/0)",
        "local t = {}; t.self = t; require('ouro').json.encode(t)",
        "require('ouro').json.array(false)",
        "require('ouro').json.array({}, {})",
        "require('ouro').json.array({extra = true})",
        "require('ouro').json.array({[0] = true})",
        "require('ouro').json.array({[-1] = true})",
        "require('ouro').json.array({[1.5] = true})",
        "require('ouro').json.array({[1] = true, [3] = true})",
        "require('ouro').json.encode({true, nil, true, extra = true})",
        "local j = require('ouro').json; local a = j.array(); a.extra = true; j.encode(a)",
        "local j = require('ouro').json; local a = j.array({1,2,3}); a[2] = nil; j.encode(a)",
    }) |source| {
        _ = try vm.spawnApplication(source);
        try std.testing.expectError(error.LuaRuntimeError, vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
        try std.testing.expectEqual(@as(c_int, 0), c.lua_gettop(vm.state));
    }
}

test "Lua exit validates codes, defaults to zero, and never continues callbacks" {
    for ([_][]const u8{ "", "255" }, [_]u8{ 0, 255 }) |argument, expected| {
        var scheduler: task.Scheduler = undefined;
        try scheduler.init(std.testing.allocator, 1, 2, 1);
        defer scheduler.deinit();
        var loop: io.Loop = undefined;
        try loop.init(std.testing.allocator, 8, 4);
        defer loop.deinit();
        var vm: Vm = undefined;
        try vm.init(std.testing.allocator, &scheduler, &loop);
        defer vm.deinit();
        for ([_][]const u8{
            "require('ouro').exit(-1)",
            "require('ouro').exit(256)",
            "require('ouro').exit(1.5)",
            "require('ouro').exit('2')",
            "require('ouro').exit(0, 1)",
        }) |source| {
            _ = try vm.spawnApplication(source);
            try std.testing.expectError(error.LuaRuntimeError, vm.resumeRunnable(scheduler.takeRunnable().?));
            try std.testing.expect(vm.exit_code == null);
        }
        const source = try std.fmt.allocPrint(std.testing.allocator, "require('ouro').exit({s}); continued = true", .{argument});
        defer std.testing.allocator.free(source);
        _ = try vm.spawnApplication(source);
        _ = try vm.spawnApplication("other_continued = true; require('ouro').exit(99)");
        try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expectEqual(@as(?u8, expected), vm.exit_code);
        try std.testing.expectEqual(ResumeResult.waiting, try vm.resumeRunnable(scheduler.takeRunnable().?));
        try std.testing.expectEqual(@as(?u8, expected), vm.exit_code);
        try std.testing.expect(!vm.globalBoolean("continued"));
        try std.testing.expect(!vm.globalBoolean("other_continued"));
        try std.testing.expect(!loop.hasPendingOperations());
        try vm.requestCancellation();
        while (scheduler.takeRunnable()) |runnable|
            try std.testing.expectEqual(ResumeResult.canceled, try vm.resumeRunnable(runnable));
        try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
    }
}
