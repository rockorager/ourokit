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

const no_scope = std.math.maxInt(u32);

const ScopeSlot = struct {
    generation: u32 = 0,
    active: bool = false,
    cancellation_queued: bool = false,
    cancellation_requested: bool = false,
    /// Set by `retireScope` on its root and same-owner descendants. Such a
    /// scope frees itself as soon as it owns no tasks, resources, or children.
    retire_when_empty: bool = false,
    parent: ScopeHandle = .invalid,
    /// Intrusive child list, so subtree walks and emptiness checks never scan
    /// unrelated scopes or allocate.
    first_child: u32 = no_scope,
    next_sibling: u32 = no_scope,
    previous_sibling: u32 = no_scope,
    task_count: u32 = 0,
    resource_count: u32 = 0,
    /// Opaque identity of the component that opened this scope, for example a
    /// Lua source generation. Never dereferenced.
    owner: ?*const anyopaque = null,
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
        if (scope_capacity >= no_scope) return error.InvalidCapacity;
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
        if (!(try self.scopeAcceptsNew(scope))) return error.ScopeCanceled;
        for (self.tasks, 0..) |*slot, index| if (slot.state == .free) {
            return self.activateTask(slot, index, scope);
        };
        const old_len = self.tasks.len;
        const new_len = std.math.mul(usize, old_len, 2) catch return error.TaskCapacityExceeded;
        if (new_len > std.math.maxInt(u32)) return error.TaskCapacityExceeded;
        self.tasks = try self.allocator.realloc(self.tasks, new_len);
        @memset(self.tasks[old_len..], .{});
        return self.activateTask(&self.tasks[old_len], old_len, scope);
    }

    /// Called only by the task phase to obtain execution permission.
    pub fn takeRunnable(self: *Scheduler) ?TaskHandle {
        for (self.tasks, 0..) |*slot, index| if (slot.state == .runnable) {
            slot.state = .running;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return null;
    }

    /// The event loop must revisit the task safe point before blocking on I/O.
    pub fn hasPendingWork(self: *const Scheduler) bool {
        for (self.tasks) |slot| if (slot.state == .runnable) return true;
        for (self.scopes) |slot| if (slot.active and slot.cancellation_queued) return true;
        return false;
    }

    pub fn wait(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        if (slot.state != .running) return error.InvalidTaskTransition;
        slot.state = .waiting;
    }

    /// Completion/platform phases may mark state only; they receive no code
    /// pointer capable of entering a language VM. Already-runnable is a valid
    /// convergence state when cancellation and I/O completion race.
    pub fn markRunnable(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        switch (slot.state) {
            .waiting => slot.state = .runnable,
            .runnable => {},
            .running, .free => return error.InvalidTaskTransition,
        }
    }

    pub fn complete(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        if (slot.state != .running) return error.InvalidTaskTransition;
        self.releaseTask(slot);
    }

    /// Rolls back a task that has been created but not granted execution.
    pub fn discardRunnableTask(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        if (slot.state != .runnable) return error.InvalidTaskTransition;
        self.releaseTask(slot);
    }

    pub fn queueScopeCancellation(self: *Scheduler, scope: ScopeHandle) !void {
        (try self.scopeSlot(scope)).cancellation_queued = true;
    }

    /// Requests cancellation of one language task without canceling the
    /// native ownership scope that contains it. Retiring source generations
    /// use this to leave retained windows and instances alive.
    pub fn requestTaskCancellation(self: *Scheduler, handle: TaskHandle) !void {
        const slot = try self.taskSlot(handle);
        if (slot.cancellation_requested) return;
        slot.cancellation_requested = true;
        if (slot.state == .waiting) slot.state = .runnable;
    }

    pub fn createScope(self: *Scheduler, parent: ScopeHandle) !ScopeHandle {
        return self.createOwnedScope(parent, null);
    }

    /// Creates a child scope tagged with an opaque owner identity so that the
    /// owner can later retire every scope it opened (`retireOwnedScopes`).
    pub fn createOwnedScope(
        self: *Scheduler,
        parent: ScopeHandle,
        owner: ?*const anyopaque,
    ) !ScopeHandle {
        if (!(try self.scopeAcceptsNew(parent))) return error.ScopeCanceled;
        for (self.scopes, 0..) |*slot, index| if (!slot.active) {
            const parent_slot = &self.scopes[parent.slot];
            var generation = slot.generation +% 1;
            if (generation == 0) generation = 1;
            slot.* = .{
                .generation = generation,
                .active = true,
                .parent = parent,
                .next_sibling = parent_slot.first_child,
                .owner = owner,
            };
            if (parent_slot.first_child != no_scope)
                self.scopes[parent_slot.first_child].previous_sibling = @intCast(index);
            parent_slot.first_child = @intCast(index);
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return error.ScopeCapacityExceeded;
    }

    /// Removes an empty scope after its resources and child scopes have been
    /// destroyed. Cancellation is normally queued first, but an empty scope
    /// may also be rolled back after failed resource creation.
    pub fn destroyScope(self: *Scheduler, handle: ScopeHandle) !void {
        if (same(handle, self.application_scope)) return error.CannotDestroyApplicationScope;
        const slot = try self.scopeSlot(handle);
        if (!isEmpty(slot)) return error.ScopeNotEmpty;
        const parent = slot.parent.slot;
        self.freeScope(handle.slot);
        self.reapUpward(parent);
    }

    /// Cancels a scope and all of its descendants, then frees it as soon as
    /// it is drained. This is the independent child-scope lifetime used by
    /// state exit: the caller forgets the handle immediately and never polls.
    /// Descendants opened by the same non-null owner are retired too; other
    /// descendants (for example a natively owned window scope) are canceled
    /// but remain until their owner calls `destroyScope`, after which the
    /// retired ancestor frees itself. Kernel cancellation is requested at the
    /// next task safe point (`applyQueuedCancellations`), but tasks in the
    /// subtree already report cancellation and will not resume user code.
    /// Generation checks reject every copy of the handle once the slot is
    /// freed or reused.
    pub fn retireScope(self: *Scheduler, handle: ScopeHandle) !void {
        if (same(handle, self.application_scope)) return error.CannotDestroyApplicationScope;
        const root = try self.scopeSlot(handle);
        root.cancellation_queued = true;
        root.retire_when_empty = true;
        if (root.owner) |owner| {
            var node: ?u32 = handle.slot;
            while (node) |index| : (node = self.nextInSubtree(index, handle.slot)) {
                if (self.scopes[index].owner == owner) self.scopes[index].retire_when_empty = true;
            }
        }
        self.reapSubtree(handle.slot);
    }

    /// Retires every live scope opened with `owner`, including their
    /// descendants. Scopes opened by other owners are unaffected unless they
    /// are nested inside a retired scope.
    pub fn retireOwnedScopes(self: *Scheduler, owner: *const anyopaque) !void {
        for (self.scopes, 0..) |slot, index| {
            if (!slot.active or slot.retire_when_empty or slot.owner != owner) continue;
            try self.retireScope(.{ .slot = @intCast(index), .generation = slot.generation });
        }
    }

    /// The app coordinator calls this at the beginning of the task safe point.
    /// Resource hooks may request kernel cancellation but must not enter Lua.
    pub fn applyQueuedCancellations(self: *Scheduler) !void {
        for (self.scopes, 0..) |scope, scope_index| {
            if (!scope.active or !scope.cancellation_queued) continue;
            const root: u32 = @intCast(scope_index);
            var node: ?u32 = root;
            while (node) |index| : (node = self.nextInSubtree(index, root))
                self.scopes[index].cancellation_requested = true;
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

    /// Cancellation applied to this task at a safe point (or requested for it
    /// individually). Adapters use this to decide when to cancel their work.
    pub fn cancellationRequested(self: *Scheduler, task: TaskHandle) !bool {
        return (try self.taskSlot(task)).cancellation_requested;
    }

    /// Like `cancellationRequested`, but also true as soon as an enclosing
    /// scope has queued cancellation. The language VM checks this before
    /// granting a resume, so a task made runnable earlier in the same turn
    /// cannot re-enter user code after its state scope has been exited.
    pub fn cancellationQueuedOrRequested(self: *Scheduler, task: TaskHandle) !bool {
        const slot = try self.taskSlot(task);
        if (slot.cancellation_requested) return true;
        return !(try self.scopeAcceptsNew(slot.scope));
    }

    pub fn registerResource(
        self: *Scheduler,
        owner: ScopeHandle,
        kind: ResourceKind,
        context: *anyopaque,
        lifecycle: *const ResourceLifecycle,
    ) !ResourceHandle {
        if (!(try self.scopeAcceptsNew(owner))) return error.ScopeCanceled;
        for (self.resources, 0..) |*slot, index| if (!slot.active) {
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.active = true;
            slot.cancellation_requested = false;
            slot.owner = owner;
            slot.kind = kind;
            slot.context = context;
            slot.lifecycle = lifecycle;
            self.scopes[owner.slot].resource_count += 1;
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
        const owner = slot.owner.slot;
        slot.active = false;
        slot.context = null;
        slot.lifecycle = null;
        slot.owner = .invalid;
        self.scopes[owner].resource_count -= 1;
        lifecycle.destroy(context);
        self.reapUpward(owner);
    }

    /// Requests cancellation of one resource without affecting sibling
    /// resources in the same retained native scope.
    pub fn requestResourceCancellation(
        self: *Scheduler,
        handle: ResourceHandle,
    ) !void {
        if (handle.slot >= self.resources.len) return error.StaleResource;
        const slot = &self.resources[handle.slot];
        if (!slot.active or slot.generation != handle.generation) return error.StaleResource;
        if (slot.cancellation_requested) return;
        slot.cancellation_requested = true;
        slot.lifecycle.?.request_cancel(slot.context.?) catch |err| {
            slot.cancellation_requested = false;
            return err;
        };
    }

    pub fn availableScopeCapacity(self: *const Scheduler) usize {
        var count: usize = 0;
        for (self.scopes) |scope| if (!scope.active) {
            count += 1;
        };
        return count;
    }

    pub fn taskCapacity(self: *const Scheduler) usize {
        return self.tasks.len;
    }

    pub fn scopeAcceptsResources(self: *Scheduler, handle: ScopeHandle) !bool {
        return self.scopeAcceptsNew(handle);
    }

    /// False once the slot has been freed or reused.
    pub fn scopeAlive(self: *Scheduler, handle: ScopeHandle) bool {
        _ = self.scopeSlot(handle) catch return false;
        return true;
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

    fn scopeAcceptsNew(self: *Scheduler, handle: ScopeHandle) !bool {
        var current = handle;
        while (true) {
            const slot = try self.scopeSlot(current);
            if (slot.cancellation_queued or slot.cancellation_requested) return false;
            if (same(current, self.application_scope)) return true;
            current = slot.parent;
        }
    }

    fn activateTask(self: *Scheduler, slot: *TaskSlot, index: usize, scope: ScopeHandle) TaskHandle {
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.state = .runnable;
        slot.scope = scope;
        slot.cancellation_requested = false;
        self.scopes[scope.slot].task_count += 1;
        return .{ .slot = @intCast(index), .generation = slot.generation };
    }

    fn releaseTask(self: *Scheduler, slot: *TaskSlot) void {
        const scope = slot.scope.slot;
        slot.state = .free;
        slot.scope = .invalid;
        slot.cancellation_requested = false;
        self.scopes[scope].task_count -= 1;
        self.reapUpward(scope);
    }

    /// Pre-order successor of `index` within the subtree rooted at `root`.
    fn nextInSubtree(self: *const Scheduler, index: u32, root: u32) ?u32 {
        if (self.scopes[index].first_child != no_scope) return self.scopes[index].first_child;
        var current = index;
        while (current != root) {
            const slot = self.scopes[current];
            if (slot.next_sibling != no_scope) return slot.next_sibling;
            current = slot.parent.slot;
        }
        return null;
    }

    /// Post-order sweep that frees every drained retiring scope in a subtree.
    /// Each successor is computed before its predecessor may be unlinked.
    fn reapSubtree(self: *Scheduler, root: u32) void {
        var index = self.firstLeaf(root);
        while (index != root) {
            const slot = self.scopes[index];
            const next = if (slot.next_sibling != no_scope)
                self.firstLeaf(slot.next_sibling)
            else
                slot.parent.slot;
            if (slot.retire_when_empty and isEmpty(&slot)) self.freeScope(index);
            index = next;
        }
        self.reapUpward(root);
    }

    fn firstLeaf(self: *const Scheduler, start: u32) u32 {
        var index = start;
        while (self.scopes[index].first_child != no_scope) index = self.scopes[index].first_child;
        return index;
    }

    /// Frees a drained retiring scope and then any retiring ancestors that it
    /// was the last occupant of. Constant work per freed level; no allocation,
    /// so completion paths may call it.
    fn reapUpward(self: *Scheduler, start: u32) void {
        var index = start;
        while (index != self.application_scope.slot) {
            const slot = &self.scopes[index];
            if (!slot.active or !slot.retire_when_empty or !isEmpty(slot)) return;
            const parent = slot.parent.slot;
            self.freeScope(index);
            index = parent;
        }
    }

    fn freeScope(self: *Scheduler, index: u32) void {
        const slot = &self.scopes[index];
        std.debug.assert(slot.active and isEmpty(slot));
        if (slot.previous_sibling != no_scope) {
            self.scopes[slot.previous_sibling].next_sibling = slot.next_sibling;
        } else {
            self.scopes[slot.parent.slot].first_child = slot.next_sibling;
        }
        if (slot.next_sibling != no_scope)
            self.scopes[slot.next_sibling].previous_sibling = slot.previous_sibling;
        slot.* = .{ .generation = slot.generation };
    }
};

fn isEmpty(slot: *const ScopeSlot) bool {
    return slot.task_count == 0 and slot.resource_count == 0 and slot.first_child == no_scope;
}

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

test "queued ancestor cancellation rejects new descendants before the safe point" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 2, 1);
    defer scheduler.deinit();
    const window = try scheduler.createScope(scheduler.application_scope);
    const widget = try scheduler.createScope(window);
    try scheduler.queueScopeCancellation(window);
    try std.testing.expectError(error.ScopeCanceled, scheduler.createScope(widget));
    try std.testing.expectError(error.ScopeCanceled, scheduler.createTask(widget));
    try scheduler.applyQueuedCancellations();
    try scheduler.destroyScope(widget);
    try scheduler.destroyScope(window);
}

test "targeted cancellation leaves a task's native scope and siblings active" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 2, 0);
    defer scheduler.deinit();
    const window = try scheduler.createScope(scheduler.application_scope);
    const retiring = try scheduler.createTask(window);
    const retained = try scheduler.createTask(window);

    try scheduler.requestTaskCancellation(retiring);
    try std.testing.expect(try scheduler.cancellationRequested(retiring));
    try std.testing.expect(!(try scheduler.cancellationRequested(retained)));
    try std.testing.expect(try scheduler.scopeAcceptsResources(window));

    try std.testing.expectEqual(retiring, scheduler.takeRunnable().?);
    try scheduler.complete(retiring);
    try std.testing.expectEqual(retained, scheduler.takeRunnable().?);
    try scheduler.complete(retained);
    try scheduler.destroyScope(window);
}

const CountingResource = struct {
    cancel_count: usize = 0,
    destroyed: bool = false,

    fn cancel(pointer: *anyopaque) !void {
        const self: *CountingResource = @ptrCast(@alignCast(pointer));
        self.cancel_count += 1;
    }
    fn destroy(pointer: *anyopaque) void {
        const self: *CountingResource = @ptrCast(@alignCast(pointer));
        self.destroyed = true;
    }

    const lifecycle: ResourceLifecycle = .{ .request_cancel = cancel, .destroy = destroy };
};

test "retired child scopes cancel every descendant and free themselves once drained" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 10, 4, 4);
    defer scheduler.deinit();
    const initial_capacity = scheduler.availableScopeCapacity();
    const owner: u8 = 0;
    const window = try scheduler.createScope(scheduler.application_scope);
    const state = try scheduler.createOwnedScope(window, &owner);
    const sibling = try scheduler.createOwnedScope(window, &owner);
    const child = try scheduler.createOwnedScope(state, &owner);
    const grandchild = try scheduler.createOwnedScope(child, &owner);
    const empty = try scheduler.createOwnedScope(state, &owner);
    // A natively owned scope nested inside a state is canceled with it but
    // still belongs to its owner, which destroys it explicitly.
    const native = try scheduler.createScope(child);

    const child_task = try scheduler.createTask(child);
    const sibling_task = try scheduler.createTask(sibling);
    try std.testing.expectEqual(child_task, scheduler.takeRunnable().?);
    try scheduler.wait(child_task);
    try std.testing.expectEqual(sibling_task, scheduler.takeRunnable().?);
    try scheduler.wait(sibling_task);
    var operation: CountingResource = .{};
    const operation_handle = try scheduler.registerResource(grandchild, .operation, &operation, &CountingResource.lifecycle);

    try scheduler.retireScope(state);
    // Already-empty retired scopes are freed immediately.
    try std.testing.expect(!scheduler.scopeAlive(empty));
    try std.testing.expect(scheduler.scopeAlive(state) and scheduler.scopeAlive(grandchild));
    // Queued: the language VM must not resume, but adapters only observe
    // cancellation once the safe point applies it.
    try std.testing.expect(try scheduler.cancellationQueuedOrRequested(child_task));
    try std.testing.expect(!(try scheduler.cancellationRequested(child_task)));
    try std.testing.expect(!(try scheduler.cancellationQueuedOrRequested(sibling_task)));
    try std.testing.expectError(error.ScopeCanceled, scheduler.createTask(grandchild));
    try std.testing.expectError(error.ScopeCanceled, scheduler.createOwnedScope(child, &owner));
    try std.testing.expectEqual(@as(usize, 0), operation.cancel_count);

    try scheduler.applyQueuedCancellations();
    try std.testing.expectEqual(@as(usize, 1), operation.cancel_count);
    try std.testing.expect(try scheduler.cancellationRequested(child_task));
    try std.testing.expect(!(try scheduler.cancellationRequested(sibling_task)));
    try std.testing.expectEqual(child_task, scheduler.takeRunnable().?);
    try std.testing.expect(scheduler.takeRunnable() == null);
    try scheduler.complete(child_task);
    try std.testing.expect(scheduler.scopeAlive(child));

    // The last resource leaving frees its retired scope from the completion
    // path; the parent stays because the native scope still occupies it.
    try scheduler.destroyResource(operation_handle);
    try std.testing.expect(operation.destroyed);
    try std.testing.expect(!scheduler.scopeAlive(grandchild));
    try std.testing.expect(scheduler.scopeAlive(child) and scheduler.scopeAlive(state));
    try scheduler.destroyScope(native);
    try std.testing.expect(!scheduler.scopeAlive(child) and !scheduler.scopeAlive(state));
    try std.testing.expect(scheduler.scopeAlive(window) and scheduler.scopeAlive(sibling));

    // Reused slots never revive stale identities.
    const reopened = try scheduler.createOwnedScope(window, &owner);
    for ([_]ScopeHandle{ state, child, grandchild, empty }) |stale| {
        try std.testing.expect(!same(stale, reopened));
        try std.testing.expectError(error.StaleScope, scheduler.retireScope(stale));
        try std.testing.expectError(error.StaleScope, scheduler.createTask(stale));
    }
    try std.testing.expectError(error.StaleResource, scheduler.destroyResource(operation_handle));

    try scheduler.retireOwnedScopes(&owner);
    try std.testing.expect(!scheduler.scopeAlive(reopened));
    try scheduler.applyQueuedCancellations();
    try std.testing.expectEqual(sibling_task, scheduler.takeRunnable().?);
    try scheduler.complete(sibling_task);
    try std.testing.expect(!scheduler.scopeAlive(sibling));
    try scheduler.destroyScope(window);
    try std.testing.expectEqual(initial_capacity, scheduler.availableScopeCapacity());
    try std.testing.expectError(error.CannotDestroyApplicationScope, scheduler.retireScope(scheduler.application_scope));
}

test "retiring a wide and deep owned tree frees every empty scope in one sweep" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 64, 1, 0);
    defer scheduler.deinit();
    const initial_capacity = scheduler.availableScopeCapacity();
    const owner: u8 = 0;
    const root = try scheduler.createOwnedScope(scheduler.application_scope, &owner);
    var parent = root;
    const depth = 6;
    for (0..depth) |_| {
        for (0..3) |_| {
            const leaf = try scheduler.createOwnedScope(parent, &owner);
            _ = try scheduler.createOwnedScope(leaf, &owner);
        }
        parent = try scheduler.createOwnedScope(parent, &owner);
    }
    const occupied = try scheduler.createTask(parent);
    try scheduler.retireScope(root);
    // Only the chain leading to the occupied scope survives.
    try std.testing.expectEqual(initial_capacity - (depth + 1), scheduler.availableScopeCapacity());
    try std.testing.expectEqual(occupied, scheduler.takeRunnable().?);
    try scheduler.complete(occupied);
    try std.testing.expect(!scheduler.scopeAlive(root));
    try std.testing.expectEqual(initial_capacity, scheduler.availableScopeCapacity());
}
