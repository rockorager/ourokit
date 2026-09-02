const std = @import("std");
const Scheduler = @import("../task/scheduler.zig").Scheduler;
const ScopeHandle = @import("../task/scheduler.zig").ScopeHandle;
const platform_window = @import("../platform/window.zig");

pub const WindowHandle = platform_window.WindowHandle;
pub const ToplevelDeclaration = platform_window.ToplevelDeclaration;
pub const LayerSurfaceDeclaration = platform_window.LayerSurfaceDeclaration;
pub const SurfaceDeclaration = platform_window.SurfaceDeclaration;
pub const NativeHost = platform_window.NativeHost;
pub const PointerEvent = platform_window.PointerEvent;
pub const KeyboardEvent = platform_window.KeyboardEvent;
pub const TextInputEvent = platform_window.TextInputEvent;

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
    text_input: TextInputEvent,
};

const State = enum { free, active, closing, closed };
const Role = enum { toplevel, layer_surface };

const Slot = struct {
    generation: u32 = 0,
    state: State = .free,
    id: ?[]u8 = null,
    title: ?[]u8 = null,
    namespace: ?[]u8 = null,
    role: Role = .toplevel,
    initial_width: u32 = 0,
    initial_height: u32 = 0,
    min_width: u32 = 0,
    min_height: u32 = 0,
    layer: platform_window.Layer = .top,
    anchors: platform_window.Anchors = .{},
    exclusive_zone: i32 = 0,
    exclusive_edge: ?platform_window.Edge = null,
    margins: platform_window.Margins = .{},
    keyboard_interactivity: platform_window.KeyboardInteractivity = .none,
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
    event_head: usize = 0,
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
    pub fn reconcile(self: *WindowSet, declarations: []const SurfaceDeclaration) !void {
        try validateDeclarations(declarations);
        try self.validateTransitions(declarations);
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
            switch (declaration) {
                .toplevel => |toplevel| {
                    if (!std.mem.eql(u8, slot.title.?, toplevel.title)) {
                        const replacement = try self.allocator.dupe(u8, toplevel.title);
                        errdefer self.allocator.free(replacement);
                        try self.host.updateTitle(handleFor(slot, index), toplevel.title);
                        self.allocator.free(slot.title.?);
                        slot.title = replacement;
                    }
                    if (slot.min_width != toplevel.min_width or slot.min_height != toplevel.min_height) {
                        try self.host.updateMinimumSize(
                            handleFor(slot, index),
                            toplevel.min_width,
                            toplevel.min_height,
                        );
                        slot.min_width = toplevel.min_width;
                        slot.min_height = toplevel.min_height;
                    }
                },
                .layer_surface => |layer_surface| if (!layerStateEqual(slot, layer_surface)) {
                    try self.host.updateLayerSurface(handleFor(slot, index), layer_surface);
                    setLayerState(slot, layer_surface);
                },
            }
        }

        for (declarations) |declaration| {
            if (self.findById(declaration.id()) != null) continue;
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

    pub fn enqueueTextInput(self: *WindowSet, event: TextInputEvent) !void {
        _ = try self.slotFor(textInputWindow(event));
        const owned = try cloneTextInput(self.allocator, event);
        errdefer freeTextInput(self.allocator, owned);
        try self.enqueue(.{ .text_input = owned });
    }

    /// Consumed only by the application's platform-event translation phase.
    pub fn takeEvent(self: *WindowSet) ?Event {
        if (self.event_count == 0) return null;
        const event = self.events[self.event_head];
        self.event_head = (self.event_head + 1) % self.events.len;
        self.event_count -= 1;
        return event;
    }

    pub fn releaseEvent(self: *WindowSet, event: Event) void {
        if (event == .text_input) freeTextInput(self.allocator, event.text_input);
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

    fn create(self: *WindowSet, declaration: SurfaceDeclaration) !void {
        var free_index: ?usize = null;
        for (self.slots, 0..) |slot, index| if (slot.state == .free) {
            free_index = index;
            break;
        };
        const index = free_index orelse return error.WindowCapacityExceeded;
        const id = try self.allocator.dupe(u8, declaration.id());
        errdefer self.allocator.free(id);
        const title = switch (declaration) {
            .toplevel => |value| try self.allocator.dupe(u8, value.title),
            .layer_surface => null,
        };
        errdefer if (title) |value| self.allocator.free(value);
        const namespace = switch (declaration) {
            .toplevel => null,
            .layer_surface => |value| try self.allocator.dupe(u8, value.namespace),
        };
        errdefer if (namespace) |value| self.allocator.free(value);
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
            .namespace = namespace,
            .role = declarationRole(declaration),
            .initial_width = declaration.initialWidth(),
            .initial_height = declaration.initialHeight(),
            .scope = scope_handle,
        };
        switch (declaration) {
            .toplevel => |value| {
                slot.min_width = value.min_width;
                slot.min_height = value.min_height;
            },
            .layer_surface => |value| setLayerState(slot, value),
        }
    }

    fn collectClosed(self: *WindowSet, declarations: []const SurfaceDeclaration) !void {
        for (self.slots) |*slot| {
            if (slot.state != .closed or findDeclaration(declarations, slot.id.?) != null) continue;
            self.scheduler.destroyScope(slot.scope) catch |err| switch (err) {
                error.ScopeNotEmpty => continue,
                else => return err,
            };
            self.allocator.free(slot.id.?);
            if (slot.title) |title| self.allocator.free(title);
            if (slot.namespace) |namespace| self.allocator.free(namespace);
            const generation = slot.generation;
            slot.* = .{ .generation = generation };
        }
    }

    fn findById(self: *WindowSet, id: []const u8) ?*Slot {
        for (self.slots) |*slot|
            if (slot.state != .free and std.mem.eql(u8, slot.id.?, id)) return slot;
        return null;
    }

    fn ensureCreateCapacity(self: *WindowSet, declarations: []const SurfaceDeclaration) !void {
        var free_count: usize = 0;
        for (self.slots) |slot| if (slot.state == .free) {
            free_count += 1;
        };
        var create_count: usize = 0;
        for (declarations) |declaration| if (self.findById(declaration.id()) == null) {
            create_count += 1;
        };
        if (create_count > free_count) return error.WindowCapacityExceeded;
    }

    fn validateTransitions(self: *WindowSet, declarations: []const SurfaceDeclaration) !void {
        for (declarations) |declaration| {
            const slot = self.findById(declaration.id()) orelse continue;
            if (slot.state != .active) continue;
            if (slot.role != declarationRole(declaration)) return error.WindowRoleChanged;
            if (declaration == .layer_surface) {
                if (!std.mem.eql(u8, slot.namespace.?, declaration.layer_surface.namespace))
                    return error.LayerSurfaceNamespaceChanged;
                if (slot.exclusive_edge != null and declaration.layer_surface.exclusive_edge == null)
                    return error.LayerSurfaceExclusiveEdgeCannotBeCleared;
            }
        }
    }

    fn slotFor(self: *WindowSet, handle: WindowHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleWindow;
        const slot = &self.slots[handle.slot];
        if (slot.state == .free or slot.generation != handle.generation) return error.StaleWindow;
        return slot;
    }

    fn enqueue(self: *WindowSet, event: Event) !void {
        if (self.event_count == self.events.len) return error.PlatformEventCapacityExceeded;
        const tail = (self.event_head + self.event_count) % self.events.len;
        self.events[tail] = event;
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

    fn sinkTextInput(context: *anyopaque, event: TextInputEvent) !void {
        const self: *WindowSet = @ptrCast(@alignCast(context));
        try self.enqueueTextInput(event);
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
        .text_input = sinkTextInput,
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

fn textInputWindow(event: TextInputEvent) WindowHandle {
    return switch (event) {
        .enter, .leave => |window| window,
        .batch => |batch| batch.window,
    };
}

fn cloneTextInput(allocator: std.mem.Allocator, event: TextInputEvent) !TextInputEvent {
    return switch (event) {
        .enter => |window| .{ .enter = window },
        .leave => |window| .{ .leave = window },
        .batch => |batch| blk: {
            const commit_text = if (batch.commit) |commit|
                if (commit.text) |text| try allocator.dupe(u8, text) else null
            else
                null;
            errdefer if (commit_text) |text| allocator.free(text);
            const preedit_text = if (batch.preedit) |preedit|
                if (preedit.text) |text| try allocator.dupe(u8, text) else null
            else
                null;
            break :blk .{ .batch = .{
                .window = batch.window,
                .serial = batch.serial,
                .serial_matches_state = batch.serial_matches_state,
                .delete_surrounding = batch.delete_surrounding,
                .commit = if (batch.commit != null) .{ .text = commit_text } else null,
                .preedit = if (batch.preedit) |preedit| .{
                    .text = preedit_text,
                    .cursor_begin = preedit.cursor_begin,
                    .cursor_end = preedit.cursor_end,
                } else null,
            } };
        },
    };
}

fn freeTextInput(allocator: std.mem.Allocator, event: TextInputEvent) void {
    switch (event) {
        .batch => |batch| {
            if (batch.commit) |commit| if (commit.text) |text| allocator.free(text);
            if (batch.preedit) |preedit| if (preedit.text) |text| allocator.free(text);
        },
        else => {},
    }
}

fn validateDeclarations(declarations: []const SurfaceDeclaration) !void {
    for (declarations, 0..) |declaration, index| {
        if (declaration.id().len == 0) return error.EmptyWindowId;
        switch (declaration) {
            .toplevel => |toplevel| {
                if (toplevel.initial_width == 0 or toplevel.initial_height == 0)
                    return error.InvalidWindowSize;
                if (toplevel.min_width > toplevel.initial_width or
                    toplevel.min_height > toplevel.initial_height or
                    toplevel.min_width > std.math.maxInt(i32) or
                    toplevel.min_height > std.math.maxInt(i32)) return error.InvalidMinimumWindowSize;
            },
            .layer_surface => |layer_surface| {
                try layer_surface.validate();
            },
        }
        for (declarations[0..index]) |earlier|
            if (std.mem.eql(u8, earlier.id(), declaration.id())) return error.DuplicateWindowId;
    }
}

fn findDeclaration(
    declarations: []const SurfaceDeclaration,
    id: []const u8,
) ?SurfaceDeclaration {
    for (declarations) |declaration|
        if (std.mem.eql(u8, declaration.id(), id)) return declaration;
    return null;
}

fn declarationRole(declaration: SurfaceDeclaration) Role {
    return switch (declaration) {
        .toplevel => .toplevel,
        .layer_surface => .layer_surface,
    };
}

fn layerStateEqual(slot: *const Slot, declaration: LayerSurfaceDeclaration) bool {
    return slot.initial_width == declaration.width and
        slot.initial_height == declaration.height and
        slot.layer == declaration.layer and
        std.meta.eql(slot.anchors, declaration.anchors) and
        slot.exclusive_zone == declaration.exclusive_zone and
        slot.exclusive_edge == declaration.exclusive_edge and
        std.meta.eql(slot.margins, declaration.margins) and
        slot.keyboard_interactivity == declaration.keyboard_interactivity;
}

fn setLayerState(slot: *Slot, declaration: LayerSurfaceDeclaration) void {
    slot.initial_width = declaration.width;
    slot.initial_height = declaration.height;
    slot.layer = declaration.layer;
    slot.anchors = declaration.anchors;
    slot.exclusive_zone = declaration.exclusive_zone;
    slot.exclusive_edge = declaration.exclusive_edge;
    slot.margins = declaration.margins;
    slot.keyboard_interactivity = declaration.keyboard_interactivity;
}

fn handleFor(slot: *const Slot, index: usize) WindowHandle {
    return .{ .slot = @intCast(index), .generation = slot.generation };
}

const FakeHost = struct {
    const Action = union(enum) {
        create: struct { handle: WindowHandle, scope: ScopeHandle },
        update_title: WindowHandle,
        update_minimum_size: struct { handle: WindowHandle, width: u32, height: u32 },
        update_layer_surface: WindowHandle,
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
        _: SurfaceDeclaration,
    ) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .create = .{ .handle = handle, .scope = scope_handle } });
    }

    fn updateTitle(context: *anyopaque, handle: WindowHandle, _: []const u8) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .update_title = handle });
    }

    fn updateMinimumSize(
        context: *anyopaque,
        handle: WindowHandle,
        width: u32,
        height: u32,
    ) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .update_minimum_size = .{
            .handle = handle,
            .width = width,
            .height = height,
        } });
    }

    fn updateLayerSurface(
        context: *anyopaque,
        handle: WindowHandle,
        _: LayerSurfaceDeclaration,
    ) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .update_layer_surface = handle });
    }

    fn beginClose(context: *anyopaque, handle: WindowHandle) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        self.append(.{ .begin_close = handle });
    }

    const vtable: NativeHost.VTable = .{
        .create = create,
        .update_title = updateTitle,
        .update_minimum_size = updateMinimumSize,
        .update_layer_surface = updateLayerSurface,
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

    const initial = [_]SurfaceDeclaration{
        .{ .toplevel = .{ .id = "main", .title = "Main" } },
        .{ .toplevel = .{ .id = "tools", .title = "Tools", .initial_width = 320, .initial_height = 240 } },
    };
    try windows.reconcile(&initial);
    try std.testing.expectEqual(@as(usize, 2), windows.activeCount());
    try std.testing.expectEqual(@as(usize, 2), host.count);
    const main_handle = host.actions[0].create.handle;
    const main_scope = host.actions[0].create.scope;
    try std.testing.expectEqual(main_scope, try windows.scope(main_handle));

    const updated = [_]SurfaceDeclaration{
        .{ .toplevel = .{ .id = "main", .title = "Renamed", .min_width = 300, .min_height = 200 } },
    };
    try windows.reconcile(&updated);
    try std.testing.expectEqual(@as(usize, 1), windows.activeCount());
    try std.testing.expectEqual(@as(usize, 5), host.count);
    try std.testing.expectEqual(main_handle, host.actions[2].update_title);
    try std.testing.expectEqual(main_handle, host.actions[3].update_minimum_size.handle);
    try std.testing.expectEqual(@as(u32, 300), host.actions[3].update_minimum_size.width);
    try std.testing.expectEqual(@as(u32, 200), host.actions[3].update_minimum_size.height);
    const tools_handle = host.actions[1].create.handle;
    try std.testing.expectEqual(tools_handle, host.actions[4].begin_close);

    try scheduler.applyQueuedCancellations();
    try windows.markClosed(tools_handle);
    try windows.reconcile(&updated);
    try std.testing.expectError(error.StaleWindow, windows.scope(tools_handle));

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(main_handle);
    try windows.reconcile(&.{});
}

test "layer surface declarations retain identity and update role-specific state" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 1, 2);
    defer windows.deinit();

    const initial: SurfaceDeclaration = .{ .layer_surface = .{
        .id = "panel",
        .namespace = "ouro-shell",
        .width = 0,
        .height = 32,
        .layer = .top,
        .anchors = .{ .top = true, .left = true, .right = true },
        .exclusive_zone = 32,
        .exclusive_edge = .top,
    } };
    try windows.reconcile(&.{initial});
    const handle = host.actions[0].create.handle;

    var updated = initial;
    updated.layer_surface.height = 40;
    updated.layer_surface.exclusive_zone = 40;
    updated.layer_surface.keyboard_interactivity = .on_demand;
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(handle, host.actions[1].update_layer_surface);

    var cleared_edge = updated;
    cleared_edge.layer_surface.exclusive_edge = null;
    try std.testing.expectError(
        error.LayerSurfaceExclusiveEdgeCannotBeCleared,
        windows.reconcile(&.{cleared_edge}),
    );

    var changed_namespace = updated;
    changed_namespace.layer_surface.namespace = "other";
    try std.testing.expectError(
        error.LayerSurfaceNamespaceChanged,
        windows.reconcile(&.{changed_namespace}),
    );
    try std.testing.expectEqual(@as(usize, 2), host.count);

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(handle);
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

    try windows.reconcile(&.{.{ .toplevel = .{ .id = "main", .title = "Main" } }});
    const duplicate = [_]SurfaceDeclaration{
        .{ .toplevel = .{ .id = "same", .title = "One" } },
        .{ .toplevel = .{ .id = "same", .title = "Two" } },
    };
    try std.testing.expectError(error.DuplicateWindowId, windows.reconcile(&duplicate));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 1), windows.activeCount());

    const too_many = [_]SurfaceDeclaration{
        .{ .toplevel = .{ .id = "first", .title = "First" } },
        .{ .toplevel = .{ .id = "second", .title = "Second" } },
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

    const declaration = [_]SurfaceDeclaration{.{ .toplevel = .{ .id = "main", .title = "Main" } }};
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

    try windows.reconcile(&.{.{ .toplevel = .{ .id = "main", .title = "Main" } }});
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

test "text input batches own protocol strings until safe-point translation" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 1, 2);
    defer windows.deinit();

    try windows.reconcile(&.{.{ .toplevel = .{ .id = "main", .title = "Main" } }});
    const handle = host.actions[0].create.handle;
    var commit = [_]u8{ 'o', 'k' };
    var preedit = [_]u8{ 'n', 'e', 'w' };
    try windows.eventSink().textInput(.{ .batch = .{
        .window = handle,
        .serial = 4,
        .serial_matches_state = true,
        .delete_surrounding = .{ .before_bytes = 1, .after_bytes = 0 },
        .commit = .{ .text = &commit },
        .preedit = .{ .text = &preedit, .cursor_begin = 0, .cursor_end = 3 },
    } });
    @memset(&commit, 'x');
    @memset(&preedit, 'x');

    const event = windows.takeEvent().?;
    defer windows.releaseEvent(event);
    try std.testing.expectEqualStrings("ok", event.text_input.batch.commit.?.text.?);
    try std.testing.expectEqualStrings("new", event.text_input.batch.preedit.?.text.?);

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(handle);
    try windows.reconcile(&.{});
}
