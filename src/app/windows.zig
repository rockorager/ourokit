const std = @import("std");
const Scheduler = @import("../task/scheduler.zig").Scheduler;
const ScopeHandle = @import("../task/scheduler.zig").ScopeHandle;
const platform_window = @import("../platform/window.zig");

pub const WindowHandle = platform_window.WindowHandle;
pub const ToplevelDeclaration = platform_window.ToplevelDeclaration;
pub const NativeHost = platform_window.NativeHost;
pub const PointerEvent = platform_window.PointerEvent;
pub const KeyboardEvent = platform_window.KeyboardEvent;

/// Events are data queued by the platform phase. They contain no callback
/// capable of entering Lua or mutating a retained UI tree.
pub const Event = union(enum) {
    close_requested: WindowHandle,
    configured: struct {
        window: WindowHandle,
        width: u32,
        height: u32,
    },
    pointer: PointerEvent,
    keyboard: KeyboardEvent,
};

const State = enum { free, active, closing, closed };

const Slot = struct {
    generation: u32 = 0,
    state: State = .free,
    id: ?[]u8 = null,
    title: ?[]u8 = null,
    initial_width: u32 = 0,
    initial_height: u32 = 0,
    scope: ScopeHandle = .invalid,
};

/// Reconciles transactional declaration snapshots into stable native window
/// identities. `self`, `scheduler`, and the native host must retain stable
/// addresses while native windows exist.
pub const WindowSet = struct {
    allocator: std.mem.Allocator,
    scheduler: *Scheduler,
    host: NativeHost,
    slots: []Slot,
    events: []Event,
    event_count: usize = 0,
    change_serial: u64 = 0,

    pub fn init(
        self: *WindowSet,
        allocator: std.mem.Allocator,
        scheduler: *Scheduler,
        host: NativeHost,
        window_capacity: usize,
        event_capacity: usize,
    ) !void {
        if (window_capacity == 0 or event_capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, window_capacity);
        errdefer allocator.free(slots);
        const events = try allocator.alloc(Event, event_capacity);
        @memset(slots, .{});
        self.* = .{
            .allocator = allocator,
            .scheduler = scheduler,
            .host = host,
            .slots = slots,
            .events = events,
        };
    }

    pub fn deinit(self: *WindowSet) void {
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        std.debug.assert(self.event_count == 0);
        self.allocator.free(self.events);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Applies one complete, already-decoded desired-state snapshot. Validation
    /// finishes before native state changes, so malformed Lua output can never
    /// partially replace the last valid window set.
    pub fn reconcile(self: *WindowSet, declarations: []const ToplevelDeclaration) !void {
        try validateDeclarations(declarations);
        try self.collectClosed(declarations);
        try self.ensureCreateCapacity(declarations);

        for (self.slots, 0..) |*slot, index| {
            if (slot.state != .active) continue;
            const declaration = findDeclaration(declarations, slot.id.?) orelse {
                const handle = handleFor(slot, index);
                try self.host.beginClose(handle);
                try self.scheduler.queueScopeCancellation(slot.scope);
                slot.state = .closing;
                continue;
            };
            if (!std.mem.eql(u8, slot.title.?, declaration.title)) {
                const replacement = try self.allocator.dupe(u8, declaration.title);
                errdefer self.allocator.free(replacement);
                try self.host.updateTitle(handleFor(slot, index), declaration.title);
                self.allocator.free(slot.title.?);
                slot.title = replacement;
            }
        }

        for (declarations) |declaration| {
            if (self.findById(declaration.id) != null) continue;
            try self.create(declaration);
        }
    }

    /// Protocol dispatch calls this state-only method after native teardown is
    /// complete. Scope cancellation is deferred to the next task safe point;
    /// slot reclamation occurs during a later reconciliation phase.
    pub fn markClosed(self: *WindowSet, handle: WindowHandle) !void {
        const slot = try self.slotFor(handle);
        if (slot.state == .closed) return;
        if (slot.state != .active and slot.state != .closing) return error.InvalidWindowTransition;
        try self.scheduler.queueScopeCancellation(slot.scope);
        slot.state = .closed;
        self.change_serial +%= 1;
    }

    pub fn enqueueCloseRequest(self: *WindowSet, handle: WindowHandle) !void {
        _ = try self.slotFor(handle);
        try self.enqueue(.{ .close_requested = handle });
    }

    pub fn enqueueConfigured(
        self: *WindowSet,
        handle: WindowHandle,
        width: u32,
        height: u32,
    ) !void {
        _ = try self.slotFor(handle);
        if (width == 0 or height == 0) return error.InvalidWindowSize;
        try self.enqueue(.{ .configured = .{ .window = handle, .width = width, .height = height } });
    }

    pub fn enqueuePointer(self: *WindowSet, event: PointerEvent) !void {
        _ = try self.slotFor(pointerWindow(event));
        try self.enqueue(.{ .pointer = event });
    }

    pub fn enqueueKeyboard(self: *WindowSet, event: KeyboardEvent) !void {
        _ = try self.slotFor(keyboardWindow(event));
        try self.enqueue(.{ .keyboard = event });
    }

    /// Consumed only by the application's platform-event translation phase.
    pub fn takeEvent(self: *WindowSet) ?Event {
        if (self.event_count == 0) return null;
        const event = self.events[0];
        self.event_count -= 1;
        if (self.event_count != 0)
            std.mem.copyForwards(Event, self.events[0..self.event_count], self.events[1..][0..self.event_count]);
        return event;
    }

    pub fn scope(self: *WindowSet, handle: WindowHandle) !ScopeHandle {
        return (try self.slotFor(handle)).scope;
    }

    pub fn activeCount(self: *const WindowSet) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot.state == .active) {
            count += 1;
        };
        return count;
    }

    pub fn retainedCount(self: *const WindowSet) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot.state != .free) {
            count += 1;
        };
        return count;
    }

    pub fn handleForId(self: *WindowSet, id: []const u8) ?WindowHandle {
        for (self.slots, 0..) |*slot, index|
            if (slot.state != .free and std.mem.eql(u8, slot.id.?, id)) return handleFor(slot, index);
        return null;
    }

    pub fn changeSerial(self: *const WindowSet) u64 {
        return self.change_serial;
    }

    pub fn eventSink(self: *WindowSet) platform_window.EventSink {
        return .{ .context = self, .vtable = &event_sink_vtable };
    }

    fn create(self: *WindowSet, declaration: ToplevelDeclaration) !void {
        var free_index: ?usize = null;
        for (self.slots, 0..) |slot, index| if (slot.state == .free) {
            free_index = index;
            break;
        };
        const index = free_index orelse return error.WindowCapacityExceeded;
        const id = try self.allocator.dupe(u8, declaration.id);
        errdefer self.allocator.free(id);
        const title = try self.allocator.dupe(u8, declaration.title);
        errdefer self.allocator.free(title);
        const scope_handle = try self.scheduler.createScope(self.scheduler.application_scope);
        errdefer self.scheduler.destroyScope(scope_handle) catch unreachable;

        const slot = &self.slots[index];
        var generation = slot.generation +% 1;
        if (generation == 0) generation = 1;
        const handle: WindowHandle = .{ .slot = @intCast(index), .generation = generation };
        try self.host.create(handle, scope_handle, declaration);
        slot.* = .{
            .generation = generation,
            .state = .active,
            .id = id,
            .title = title,
            .initial_width = declaration.initial_width,
            .initial_height = declaration.initial_height,
            .scope = scope_handle,
        };
    }

    fn collectClosed(self: *WindowSet, declarations: []const ToplevelDeclaration) !void {
        for (self.slots) |*slot| {
            if (slot.state != .closed or findDeclaration(declarations, slot.id.?) != null) continue;
            self.scheduler.destroyScope(slot.scope) catch |err| switch (err) {
                error.ScopeNotEmpty => continue,
                else => return err,
            };
            self.allocator.free(slot.id.?);
            self.allocator.free(slot.title.?);
            const generation = slot.generation;
            slot.* = .{ .generation = generation };
        }
    }

    fn findById(self: *WindowSet, id: []const u8) ?*Slot {
        for (self.slots) |*slot|
            if (slot.state != .free and std.mem.eql(u8, slot.id.?, id)) return slot;
        return null;
    }

    fn ensureCreateCapacity(self: *WindowSet, declarations: []const ToplevelDeclaration) !void {
        var free_count: usize = 0;
        for (self.slots) |slot| if (slot.state == .free) {
            free_count += 1;
        };
        var create_count: usize = 0;
        for (declarations) |declaration| if (self.findById(declaration.id) == null) {
            create_count += 1;
        };
        if (create_count > free_count) return error.WindowCapacityExceeded;
    }

    fn slotFor(self: *WindowSet, handle: WindowHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleWindow;
        const slot = &self.slots[handle.slot];
        if (slot.state == .free or slot.generation != handle.generation) return error.StaleWindow;
        return slot;
    }

    fn enqueue(self: *WindowSet, event: Event) !void {
        if (self.event_count == self.events.len) return error.PlatformEventCapacityExceeded;
        self.events[self.event_count] = event;
        self.event_count += 1;
        self.change_serial +%= 1;
    }

    fn sinkCloseRequested(context: *anyopaque, handle: WindowHandle) !void {
        const self: *WindowSet = @ptrCast(@alignCast(context));
        try self.enqueueCloseRequest(handle);
    }

    fn sinkConfigured(context: *anyopaque, handle: WindowHandle, width: u32, height: u32) !void {
        const self: *WindowSet = @ptrCast(@alignCast(context));
        try self.enqueueConfigured(handle, width, height);
    }

    fn sinkPointer(context: *anyopaque, event: PointerEvent) !void {
        const self: *WindowSet = @ptrCast(@alignCast(context));
        try self.enqueuePointer(event);
    }

    fn sinkKeyboard(context: *anyopaque, event: KeyboardEvent) !void {
        const self: *WindowSet = @ptrCast(@alignCast(context));
        try self.enqueueKeyboard(event);
    }

    fn sinkClosed(context: *anyopaque, handle: WindowHandle) !void {
        const self: *WindowSet = @ptrCast(@alignCast(context));
        try self.markClosed(handle);
    }

    const event_sink_vtable: platform_window.EventSink.VTable = .{
        .close_requested = sinkCloseRequested,
        .configured = sinkConfigured,
        .pointer = sinkPointer,
        .keyboard = sinkKeyboard,
        .closed = sinkClosed,
    };
};

fn pointerWindow(event: PointerEvent) WindowHandle {
    return switch (event) {
        .enter => |value| value.window,
        .leave => |value| value.window,
        .motion => |value| value.window,
        .button => |value| value.window,
        .axis => |value| value.window,
        .axis_source => |value| value.window,
        .axis_stop => |value| value.window,
        .axis_steps => |value| value.window,
        .axis_steps120 => |value| value.window,
        .frame => |window| window,
    };
}

fn keyboardWindow(event: KeyboardEvent) WindowHandle {
    return switch (event) {
        .enter => |value| value.window,
        .leave => |value| value.window,
        .key => |value| value.window,
    };
}

fn validateDeclarations(declarations: []const ToplevelDeclaration) !void {
    for (declarations, 0..) |declaration, index| {
        if (declaration.id.len == 0) return error.EmptyWindowId;
        if (declaration.initial_width == 0 or declaration.initial_height == 0)
            return error.InvalidWindowSize;
        for (declarations[0..index]) |earlier|
            if (std.mem.eql(u8, earlier.id, declaration.id)) return error.DuplicateWindowId;
    }
}

fn findDeclaration(
    declarations: []const ToplevelDeclaration,
    id: []const u8,
) ?ToplevelDeclaration {
    for (declarations) |declaration|
        if (std.mem.eql(u8, declaration.id, id)) return declaration;
    return null;
}

fn handleFor(slot: *const Slot, index: usize) WindowHandle {
    return .{ .slot = @intCast(index), .generation = slot.generation };
}

const FakeHost = struct {
    const Action = union(enum) {
        create: struct { handle: WindowHandle, scope: ScopeHandle },
        update_title: WindowHandle,
        begin_close: WindowHandle,
    };

    actions: [16]Action = undefined,
    count: usize = 0,

    fn interface(self: *FakeHost) NativeHost {
        return .{ .context = self, .vtable = &vtable };
    }

    fn append(self: *FakeHost, action: Action) void {
        self.actions[self.count] = action;
        self.count += 1;
    }

    fn create(
        context: *anyopaque,
        handle: WindowHandle,
        scope_handle: ScopeHandle,
        _: ToplevelDeclaration,
    ) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .create = .{ .handle = handle, .scope = scope_handle } });
    }

    fn updateTitle(context: *anyopaque, handle: WindowHandle, _: []const u8) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .update_title = handle });
    }

    fn beginClose(context: *anyopaque, handle: WindowHandle) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .begin_close = handle });
    }

    const vtable: NativeHost.VTable = .{
        .create = create,
        .update_title = updateTitle,
        .begin_close = beginClose,
    };
};

test "window declarations reconcile into stable scoped native identities" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 2, 4);
    defer windows.deinit();

    const initial = [_]ToplevelDeclaration{
        .{ .id = "main", .title = "Main" },
        .{ .id = "tools", .title = "Tools", .initial_width = 320, .initial_height = 240 },
    };
    try windows.reconcile(&initial);
    try std.testing.expectEqual(@as(usize, 2), windows.activeCount());
    try std.testing.expectEqual(@as(usize, 2), host.count);
    const main_handle = host.actions[0].create.handle;
    const main_scope = host.actions[0].create.scope;
    try std.testing.expectEqual(main_scope, try windows.scope(main_handle));

    const updated = [_]ToplevelDeclaration{
        .{ .id = "main", .title = "Renamed" },
    };
    try windows.reconcile(&updated);
    try std.testing.expectEqual(@as(usize, 1), windows.activeCount());
    try std.testing.expectEqual(@as(usize, 4), host.count);
    try std.testing.expectEqual(main_handle, host.actions[2].update_title);
    const tools_handle = host.actions[1].create.handle;
    try std.testing.expectEqual(tools_handle, host.actions[3].begin_close);

    try scheduler.applyQueuedCancellations();
    try windows.markClosed(tools_handle);
    try windows.reconcile(&updated);
    try std.testing.expectError(error.StaleWindow, windows.scope(tools_handle));

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(main_handle);
    try windows.reconcile(&.{});
}

test "invalid declaration snapshots do not alter native windows" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 3, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 2, 2);
    defer windows.deinit();

    try windows.reconcile(&.{.{ .id = "main", .title = "Main" }});
    const duplicate = [_]ToplevelDeclaration{
        .{ .id = "same", .title = "One" },
        .{ .id = "same", .title = "Two" },
    };
    try std.testing.expectError(error.DuplicateWindowId, windows.reconcile(&duplicate));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 1), windows.activeCount());

    const too_many = [_]ToplevelDeclaration{
        .{ .id = "first", .title = "First" },
        .{ .id = "second", .title = "Second" },
    };
    try std.testing.expectError(error.WindowCapacityExceeded, windows.reconcile(&too_many));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 1), windows.activeCount());

    const handle = host.actions[0].create.handle;
    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(handle);
    try windows.reconcile(&.{});
}

test "platform close requests are queued as data and stale declarations stay suppressed" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 1, 2);
    defer windows.deinit();

    const declaration = [_]ToplevelDeclaration{.{ .id = "main", .title = "Main" }};
    try windows.reconcile(&declaration);
    const original = host.actions[0].create.handle;
    const initial_serial = windows.changeSerial();
    try windows.eventSink().closeRequested(original);
    try std.testing.expect(windows.changeSerial() != initial_serial);
    const event = windows.takeEvent().?;
    try std.testing.expectEqual(original, event.close_requested);
    try std.testing.expect(windows.takeEvent() == null);

    try windows.markClosed(original);
    try scheduler.applyQueuedCancellations();
    try windows.reconcile(&declaration);
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try windows.reconcile(&.{});
    try windows.reconcile(&declaration);
    const replacement = host.actions[1].create.handle;
    try std.testing.expectEqual(original.slot, replacement.slot);
    try std.testing.expect(original.generation != replacement.generation);

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(replacement);
    try windows.reconcile(&.{});
}

test "typed pointer events remain data until platform translation" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 1, 2);
    defer windows.deinit();

    try windows.reconcile(&.{.{ .id = "main", .title = "Main" }});
    const handle = host.actions[0].create.handle;
    try windows.eventSink().pointer(.{ .motion = .{
        .window = handle,
        .time_ms = 42,
        .position = .{ .x = 12.5, .y = 8.25 },
    } });
    const queued = windows.takeEvent().?.pointer.motion;
    try std.testing.expectEqual(handle, queued.window);
    try std.testing.expectEqual(@as(u32, 42), queued.time_ms);
    try std.testing.expectEqual(@as(f32, 12.5), queued.position.x);
    try std.testing.expectEqual(@as(f32, 8.25), queued.position.y);

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(handle);
    try windows.reconcile(&.{});
}
