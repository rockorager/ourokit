const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;
const platform = @import("../platform/window.zig");
const task = @import("../task/scheduler.zig");

pub const RequestHandle = Handle;

pub const Target = struct {
    window: platform.WindowHandle,
    text_input: Handle,
};

pub const Action = union(enum) {
    set_selection: struct {
        serial: u32,
        text: []const u8,
    },
    request_paste: struct {
        request: RequestHandle,
        window: platform.WindowHandle,
    },
    cancel_paste: RequestHandle,
};

pub const Completion = struct {
    request: RequestHandle,
    target: Target,
    /// Owned by the coordinator until `releaseCompletion` returns. Null means
    /// that no compatible text offer existed or the transfer failed.
    text: ?[]const u8,
};

const State = enum {
    free,
    queued,
    active,
    cancellation_pending,
    completed,
    delivered,
    canceled,
};

const Slot = struct {
    coordinator: *Coordinator = undefined,
    index: u32 = 0,
    generation: u32 = 0,
    state: State = .free,
    resource: task.ResourceHandle = .invalid,
    target: Target = .{ .window = .invalid, .text_input = .invalid },
    text: ?[]u8 = null,
};

/// Language-neutral clipboard request ownership. The coordinator does not
/// implement a clipboard: platform adapters consume actions and return owned
/// UTF-8 completions. Every request is also a scheduler resource in its owning
/// application/window/widget scope, so disposal cancels the same lifecycle
/// used by timers and other asynchronous operations.
///
/// `self`, `scheduler`, and all slots retain stable addresses until `deinit`.
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    scheduler: *task.Scheduler,
    slots: []Slot,
    actions: []Action,
    action_head: usize = 0,
    action_count: usize = 0,
    max_text_bytes: usize,
    platform_available: bool = false,

    pub fn init(
        self: *Coordinator,
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        request_capacity: usize,
        action_capacity: usize,
        max_text_bytes: usize,
    ) !void {
        if (request_capacity == 0 or action_capacity < request_capacity or max_text_bytes == 0)
            return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, request_capacity);
        errdefer allocator.free(slots);
        const actions = try allocator.alloc(Action, action_capacity);
        errdefer allocator.free(actions);
        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .slots = slots,
            .actions = actions,
            .max_text_bytes = max_text_bytes,
        };
        for (self.slots, 0..) |*slot, index| slot.* = .{
            .coordinator = self,
            .index = @intCast(index),
        };
    }

    pub fn deinit(self: *Coordinator) void {
        std.debug.assert(self.action_count == 0);
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        self.allocator.free(self.actions);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn setPlatformAvailable(self: *Coordinator, available: bool) void {
        self.platform_available = available;
    }

    pub fn platformAvailable(self: *const Coordinator) bool {
        return self.platform_available;
    }

    /// Copies selected text before a cut can mutate its borrowed model slice.
    /// The returned action owns these bytes until `releaseAction`.
    pub fn setSelection(
        self: *Coordinator,
        serial: u32,
        text: []const u8,
    ) !void {
        if (!self.platform_available) return error.ClipboardUnavailable;
        if (text.len == 0) return;
        if (text.len > self.max_text_bytes) return error.ClipboardTextTooLarge;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.enqueue(.{ .set_selection = .{
            .serial = serial,
            .text = owned,
        } });
    }

    pub fn requestPaste(
        self: *Coordinator,
        owner: task.ScopeHandle,
        target: Target,
    ) !RequestHandle {
        const slot = for (self.slots) |*candidate| {
            if (candidate.state == .free) break candidate;
        } else return error.ClipboardRequestCapacityExceeded;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.state = .queued;
        slot.target = target;
        slot.text = null;
        slot.resource = self.scheduler.registerResource(
            owner,
            .operation,
            slot,
            &resource_lifecycle,
        ) catch |err| {
            slot.state = .free;
            return err;
        };
        const handle = handleFor(slot);
        self.enqueue(.{ .request_paste = .{
            .request = handle,
            .window = target.window,
        } }) catch |err| {
            self.scheduler.destroyResource(slot.resource) catch unreachable;
            return err;
        };
        return handle;
    }

    /// Platform phase only. Stale queued actions are skipped after scope
    /// cancellation; returned requests have transitioned to active.
    pub fn takeAction(self: *Coordinator) ?Action {
        while (self.action_count != 0) {
            const action = self.actions[self.action_head];
            self.action_head = (self.action_head + 1) % self.actions.len;
            self.action_count -= 1;
            switch (action) {
                .set_selection => return action,
                .request_paste => |request| {
                    const slot = self.slotFor(request.request) catch continue;
                    if (slot.state != .queued) continue;
                    slot.state = .active;
                },
                .cancel_paste => |request| {
                    const slot = self.slotFor(request) catch continue;
                    if (slot.state != .cancellation_pending) continue;
                },
            }
            return action;
        }
        return null;
    }

    pub fn releaseAction(self: *Coordinator, action: Action) void {
        switch (action) {
            .set_selection => |selection| self.allocator.free(selection.text),
            .request_paste, .cancel_paste => {},
        }
    }

    /// Takes ownership by copying platform-provided bytes before the platform
    /// transfer buffer or pipe may be reused. A completion racing cancellation
    /// is terminal but is intentionally not delivered to the disposed target.
    pub fn completePaste(
        self: *Coordinator,
        request: RequestHandle,
        text: ?[]const u8,
    ) !void {
        const slot = try self.slotFor(request);
        if (slot.state == .cancellation_pending) {
            slot.state = .canceled;
            return;
        }
        if (slot.state != .active) return error.InvalidClipboardTransition;
        if (text) |bytes| {
            // Clipboard data is untrusted platform input. Oversized or invalid
            // UTF-8 payloads behave like an unavailable text offer rather than
            // terminating the application event loop.
            if (bytes.len > self.max_text_bytes or !std.unicode.utf8ValidateSlice(bytes)) {
                slot.state = .completed;
                return;
            }
            slot.text = try self.allocator.dupe(u8, bytes);
        }
        slot.state = .completed;
    }

    pub fn acknowledgeCancellation(self: *Coordinator, request: RequestHandle) !void {
        const slot = try self.slotFor(request);
        if (slot.state != .cancellation_pending) return error.InvalidClipboardTransition;
        slot.state = .canceled;
    }

    /// Input safe point only. The caller must revalidate `target.text_input`
    /// before applying text because the retained instance may have retired.
    pub fn takeCompletion(self: *Coordinator) ?Completion {
        for (self.slots) |*slot| if (slot.state == .completed) {
            slot.state = .delivered;
            return .{
                .request = handleFor(slot),
                .target = slot.target,
                .text = slot.text,
            };
        };
        return null;
    }

    pub fn releaseCompletion(self: *Coordinator, request: RequestHandle) !void {
        const slot = try self.slotFor(request);
        if (slot.state != .delivered) return error.InvalidClipboardTransition;
        try self.scheduler.destroyResource(slot.resource);
    }

    /// Safe-point maintenance after queued scope cancellations and platform
    /// terminal acknowledgements. Never call while scheduler cancellation is
    /// iterating its resource registry.
    pub fn collectCanceled(self: *Coordinator) !void {
        for (self.slots) |*slot| if (slot.state == .canceled) {
            try self.scheduler.destroyResource(slot.resource);
        };
    }

    fn enqueue(self: *Coordinator, action: Action) !void {
        if (self.action_count == self.actions.len) return error.ClipboardActionCapacityExceeded;
        const tail = (self.action_head + self.action_count) % self.actions.len;
        self.actions[tail] = action;
        self.action_count += 1;
    }

    fn slotFor(self: *Coordinator, handle: RequestHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleClipboardRequest;
        const slot = &self.slots[handle.slot];
        if (slot.state == .free or slot.generation != handle.generation)
            return error.StaleClipboardRequest;
        return slot;
    }
};

fn handleFor(slot: *const Slot) RequestHandle {
    return .{ .slot = slot.index, .generation = slot.generation };
}

fn requestCancel(context: *anyopaque) !void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    switch (slot.state) {
        .queued, .completed, .delivered => slot.state = .canceled,
        .active => {
            slot.state = .cancellation_pending;
            slot.coordinator.enqueue(.{ .cancel_paste = handleFor(slot) }) catch |err| {
                slot.state = .active;
                return err;
            };
        },
        .cancellation_pending, .canceled => {},
        .free => unreachable,
    }
}

fn destroy(context: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    if (slot.text) |text| slot.coordinator.allocator.free(text);
    slot.state = .free;
    slot.resource = .invalid;
    slot.target = .{ .window = .invalid, .text_input = .invalid };
    slot.text = null;
}

const resource_lifecycle: task.ResourceLifecycle = .{
    .request_cancel = requestCancel,
    .destroy = destroy,
};

test "paste completion owns UTF-8 and preserves generation-checked target" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 1, 2);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);

    var clipboard: Coordinator = undefined;
    try clipboard.init(std.testing.allocator, &scheduler, 2, 4, 1024);
    defer clipboard.deinit();

    const target: Target = .{
        .window = .{ .slot = 3, .generation = 7 },
        .text_input = .{ .slot = 4, .generation = 9 },
    };
    const request = try clipboard.requestPaste(window_scope, target);
    try std.testing.expectEqual(Action{ .request_paste = .{
        .request = request,
        .window = target.window,
    } }, clipboard.takeAction().?);
    var temporary = [_]u8{ 'h', 0xc3, 0xa9 };
    try clipboard.completePaste(request, &temporary);
    temporary[0] = 'x';
    const completion = clipboard.takeCompletion().?;
    try std.testing.expectEqual(target, completion.target);
    try std.testing.expectEqualStrings("hé", completion.text.?);
    try clipboard.releaseCompletion(request);
    try std.testing.expectError(error.StaleClipboardRequest, clipboard.completePaste(request, "x"));

    try scheduler.queueScopeCancellation(window_scope);
    try scheduler.applyQueuedCancellations();
    try scheduler.destroyScope(window_scope);
}

test "scope cancellation queues platform cancellation without delivering data" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 1, 1);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);

    var clipboard: Coordinator = undefined;
    try clipboard.init(std.testing.allocator, &scheduler, 1, 2, 64);
    defer clipboard.deinit();

    const request = try clipboard.requestPaste(window_scope, .{
        .window = .{ .slot = 1, .generation = 1 },
        .text_input = .{ .slot = 2, .generation = 1 },
    });
    _ = clipboard.takeAction().?;
    try scheduler.queueScopeCancellation(window_scope);
    try scheduler.applyQueuedCancellations();
    try std.testing.expectEqual(Action{ .cancel_paste = request }, clipboard.takeAction().?);
    try clipboard.completePaste(request, "racing data");
    try std.testing.expect(clipboard.takeCompletion() == null);
    try clipboard.collectCanceled();
    try scheduler.destroyScope(window_scope);
}

test "selection action owns bytes before a cut can mutate its model" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 1, 1);
    defer scheduler.deinit();
    var clipboard: Coordinator = undefined;
    try clipboard.init(std.testing.allocator, &scheduler, 1, 2, 64);
    defer clipboard.deinit();

    var selected = [_]u8{ 'c', 'o', 'p', 'y' };
    try std.testing.expectError(
        error.ClipboardUnavailable,
        clipboard.setSelection(9, &selected),
    );
    clipboard.setPlatformAvailable(true);
    try clipboard.setSelection(9, &selected);
    selected[0] = 'x';
    const action = clipboard.takeAction().?;
    try std.testing.expectEqualStrings("copy", action.set_selection.text);
    try std.testing.expectEqual(@as(u32, 9), action.set_selection.serial);
    clipboard.releaseAction(action);
}
