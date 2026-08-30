const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;

pub const ScopeHandle = Handle;
pub const TaskHandle = Handle;
pub const ResourceHandle = Handle;

pub const ResourceKind = enum {
    operation,
    timer,
    window,
    service,
};

/// A language-neutral ownership hook. Context pointers live only in this
/// generation-checked registry and are never placed in kernel `user_data`.
pub const ResourceLifecycle = struct {
    request_cancel: *const fn (*anyopaque) anyerror!void,
    destroy: *const fn (*anyopaque) void,
};

const ScopeSlot = struct {
    generation: u32 = 0,
    active: bool = false,
    cancellation_queued: bool = false,
    cancellation_requested: bool = false,
    parent: ScopeHandle = .invalid,
};

const TaskState = enum { free, runnable, running, waiting };

const TaskSlot = struct {
    generation: u32 = 0,
    state: TaskState = .free,
    scope: ScopeHandle = .invalid,
    cancellation_requested: bool = false,
};

const ResourceSlot = struct {
    generation: u32 = 0,
    active: bool = false,
    cancellation_requested: bool = false,
    owner: ScopeHandle = .invalid,
    kind: ResourceKind = .operation,
    context: ?*anyopaque = null,
    lifecycle: ?*const ResourceLifecycle = null,
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    scopes: []ScopeSlot,
    tasks: []TaskSlot,
    resources: []ResourceSlot,
    application_scope: ScopeHandle,

    pub fn init(
        self: *Scheduler,
        allocator: std.mem.Allocator,
        scope_capacity: usize,
        task_capacity: usize,
        resource_capacity: usize,
    ) !void {
        if (scope_capacity == 0 or task_capacity == 0) return error.InvalidCapacity;
        const scopes = try allocator.alloc(ScopeSlot, scope_capacity);
        errdefer allocator.free(scopes);
        const tasks = try allocator.alloc(TaskSlot, task_capacity);
        errdefer allocator.free(tasks);
        const resources = try allocator.alloc(ResourceSlot, resource_capacity);
        errdefer allocator.free(resources);
        @memset(scopes, .{});
        @memset(tasks, .{});
        @memset(resources, .{});
        scopes[0] = .{ .generation = 1, .active = true };
        self.* = .{
            .allocator = allocator,
            .scopes = scopes,
            .tasks = tasks,
            .resources = resources,
            .application_scope = .{ .slot = 0, .generation = 1 },
        };
    }

    pub fn deinit(self: *Scheduler) void {
        for (self.tasks) |task| std.debug.assert(task.state == .free);
        for (self.resources) |resource| std.debug.assert(!resource.active);
        for (self.scopes[1..]) |scope| std.debug.assert(!scope.active);
        self.allocator.free(self.resources);
        self.allocator.free(self.tasks);
        self.allocator.free(self.scopes);
        self.* = undefined;
    }

    pub fn createTask(self: *Scheduler, scope: ScopeHandle) !TaskHandle {
        if ((try self.scopeSlot(scope)).cancellation_requested) return error.ScopeCanceled;
        for (self.tasks, 0..) |*slot, index| if (slot.state == .free) {
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.state = .runnable;
            slot.scope = scope;
            slot.cancellation_requested = false;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return error.TaskCapacityExceeded;
    }

    /// Called only by the task phase to obtain execution permission.
    pub fn takeRunnable(self: *Scheduler) ?TaskHandle {
        for (self.tasks, 0..) |*slot, index| if (slot.state == .runnable) {
            slot.state = .running;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return null;
    }

    pub fn wait(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        if (slot.state != .running) return error.InvalidTaskTransition;
        slot.state = .waiting;
    }

    /// Completion/platform phases may mark state only; they receive no code
    /// pointer capable of entering a language VM.
    pub fn markRunnable(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        if (slot.state != .waiting) return error.InvalidTaskTransition;
        slot.state = .runnable;
    }

    pub fn complete(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        if (slot.state != .running) return error.InvalidTaskTransition;
        slot.state = .free;
        slot.scope = .invalid;
        slot.cancellation_requested = false;
    }

    pub fn queueScopeCancellation(self: *Scheduler, scope: ScopeHandle) !void {
        (try self.scopeSlot(scope)).cancellation_queued = true;
    }

    pub fn createScope(self: *Scheduler, parent: ScopeHandle) !ScopeHandle {
        const parent_slot = try self.scopeSlot(parent);
        if (parent_slot.cancellation_requested) return error.ScopeCanceled;
        for (self.scopes, 0..) |*slot, index| if (!slot.active) {
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.active = true;
            slot.cancellation_queued = false;
            slot.cancellation_requested = false;
            slot.parent = parent;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return error.ScopeCapacityExceeded;
    }

    /// Removes an empty scope after its resources and child scopes have been
    /// destroyed. Cancellation is normally queued first, but an empty scope
    /// may also be rolled back after failed resource creation.
    pub fn destroyScope(self: *Scheduler, handle: ScopeHandle) !void {
        if (same(handle, self.application_scope)) return error.CannotDestroyApplicationScope;
        _ = try self.scopeSlot(handle);
        for (self.tasks) |task|
            if (task.state != .free and same(task.scope, handle)) return error.ScopeNotEmpty;
        for (self.resources) |resource|
            if (resource.active and same(resource.owner, handle)) return error.ScopeNotEmpty;
        for (self.scopes) |scope|
            if (scope.active and same(scope.parent, handle)) return error.ScopeNotEmpty;
        const slot = &self.scopes[handle.slot];
        slot.active = false;
        slot.cancellation_queued = false;
        slot.cancellation_requested = false;
        slot.parent = .invalid;
    }

    /// The app coordinator calls this at the beginning of the task safe point.
    /// Resource hooks may request kernel cancellation but must not enter Lua.
    pub fn applyQueuedCancellations(self: *Scheduler) !void {
        for (self.scopes, 0..) |scope, scope_index| {
            if (!scope.active or !scope.cancellation_queued) continue;
            const root: ScopeHandle = .{ .slot = @intCast(scope_index), .generation = scope.generation };
            for (self.scopes, 0..) |*candidate, candidate_index| {
                if (!candidate.active) continue;
                const handle: ScopeHandle = .{
                    .slot = @intCast(candidate_index),
                    .generation = candidate.generation,
                };
                if (self.isWithin(handle, root)) candidate.cancellation_requested = true;
            }
        }
        for (self.scopes) |*scope| scope.cancellation_queued = false;

        for (self.tasks) |*task| {
            if (task.state == .free or !(try self.scopeSlot(task.scope)).cancellation_requested) continue;
            task.cancellation_requested = true;
            if (task.state == .waiting) task.state = .runnable;
        }
        for (self.resources) |*resource| {
            if (!resource.active or resource.cancellation_requested or
                !(try self.scopeSlot(resource.owner)).cancellation_requested) continue;
            resource.cancellation_requested = true;
            try resource.lifecycle.?.request_cancel(resource.context.?);
        }
    }

    pub fn cancellationRequested(self: *Scheduler, task: TaskHandle) !bool {
        return (try self.taskSlot(task)).cancellation_requested;
    }

    pub fn registerResource(
        self: *Scheduler,
        owner: ScopeHandle,
        kind: ResourceKind,
        context: *anyopaque,
        lifecycle: *const ResourceLifecycle,
    ) !ResourceHandle {
        if ((try self.scopeSlot(owner)).cancellation_requested) return error.ScopeCanceled;
        for (self.resources, 0..) |*slot, index| if (!slot.active) {
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.active = true;
            slot.cancellation_requested = false;
            slot.owner = owner;
            slot.kind = kind;
            slot.context = context;
            slot.lifecycle = lifecycle;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return error.ResourceCapacityExceeded;
    }

    pub fn destroyResource(self: *Scheduler, handle: ResourceHandle) !void {
        if (handle.slot >= self.resources.len) return error.StaleResource;
        const slot = &self.resources[handle.slot];
        if (!slot.active or slot.generation != handle.generation) return error.StaleResource;
        const context = slot.context.?;
        const lifecycle = slot.lifecycle.?;
        slot.active = false;
        slot.context = null;
        slot.lifecycle = null;
        lifecycle.destroy(context);
    }

    fn scopeSlot(self: *Scheduler, handle: ScopeHandle) !*ScopeSlot {
        if (handle.slot >= self.scopes.len) return error.StaleScope;
        const slot = &self.scopes[handle.slot];
        if (!slot.active or slot.generation != handle.generation) return error.StaleScope;
        return slot;
    }

    fn taskSlot(self: *Scheduler, handle: TaskHandle) !*TaskSlot {
        if (handle.slot >= self.tasks.len) return error.StaleTask;
        const slot = &self.tasks[handle.slot];
        if (slot.state == .free or slot.generation != handle.generation) return error.StaleTask;
        return slot;
    }

    fn isWithin(self: *Scheduler, candidate: ScopeHandle, root: ScopeHandle) bool {
        var current = candidate;
        while (true) {
            if (same(current, root)) return true;
            const slot = self.scopeSlot(current) catch return false;
            if (same(current, self.application_scope)) return false;
            current = slot.parent;
        }
    }
};

fn same(a: Handle, b: Handle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "completion and cancellation only make tasks runnable until task phase" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 2, 0);
    defer scheduler.deinit();
    const task = try scheduler.createTask(scheduler.application_scope);
    try std.testing.expectEqual(task, scheduler.takeRunnable().?);
    try scheduler.wait(task);
    try scheduler.queueScopeCancellation(scheduler.application_scope);
    try std.testing.expect(scheduler.takeRunnable() == null);
    try scheduler.applyQueuedCancellations();
    try std.testing.expect(try scheduler.cancellationRequested(task));
    try std.testing.expectEqual(task, scheduler.takeRunnable().?);
    try scheduler.complete(task);
}

test "one scope registry owns heterogeneous resources" {
    const Context = struct {
        canceled: bool = false,
        destroyed: bool = false,

        fn cancel(pointer: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.canceled = true;
        }
        fn destroy(pointer: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.destroyed = true;
        }
    };
    const lifecycle: ResourceLifecycle = .{
        .request_cancel = Context.cancel,
        .destroy = Context.destroy,
    };
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 2);
    defer scheduler.deinit();
    var timer: Context = .{};
    var window: Context = .{};
    const timer_handle = try scheduler.registerResource(scheduler.application_scope, .timer, &timer, &lifecycle);
    const window_handle = try scheduler.registerResource(scheduler.application_scope, .window, &window, &lifecycle);
    try scheduler.queueScopeCancellation(scheduler.application_scope);
    try scheduler.applyQueuedCancellations();
    try std.testing.expect(timer.canceled and window.canceled);
    try scheduler.destroyResource(timer_handle);
    try scheduler.destroyResource(window_handle);
    try std.testing.expect(timer.destroyed and window.destroyed);
    try std.testing.expectError(error.StaleResource, scheduler.destroyResource(timer_handle));
}

test "scope cancellation cascades without running task or resource code early" {
    const Context = struct {
        cancel_count: usize = 0,

        fn cancel(pointer: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            self.cancel_count += 1;
        }
        fn destroy(_: *anyopaque) void {}
    };
    const lifecycle: ResourceLifecycle = .{
        .request_cancel = Context.cancel,
        .destroy = Context.destroy,
    };

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 2, 2);
    defer scheduler.deinit();
    const window = try scheduler.createScope(scheduler.application_scope);
    const widget = try scheduler.createScope(window);
    const task = try scheduler.createTask(widget);
    try std.testing.expectEqual(task, scheduler.takeRunnable().?);
    try scheduler.wait(task);
    var resource: Context = .{};
    const resource_handle = try scheduler.registerResource(widget, .operation, &resource, &lifecycle);

    try scheduler.queueScopeCancellation(window);
    try std.testing.expectEqual(@as(usize, 0), resource.cancel_count);
    try std.testing.expect(scheduler.takeRunnable() == null);
    try scheduler.applyQueuedCancellations();
    try std.testing.expectEqual(@as(usize, 1), resource.cancel_count);
    try std.testing.expectEqual(task, scheduler.takeRunnable().?);
    try std.testing.expect(try scheduler.cancellationRequested(task));
    try std.testing.expectError(error.ScopeCanceled, scheduler.createScope(window));
    try std.testing.expectError(error.ScopeCanceled, scheduler.createTask(widget));
    var rejected_resource: Context = .{};
    try std.testing.expectError(
        error.ScopeCanceled,
        scheduler.registerResource(widget, .service, &rejected_resource, &lifecycle),
    );
    try scheduler.complete(task);
    try scheduler.destroyResource(resource_handle);
    try scheduler.destroyScope(widget);
    try scheduler.destroyScope(window);
}
