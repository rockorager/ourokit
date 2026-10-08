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
const Role = enum { toplevel, layer_surface, session_lock, popup };

const Slot = struct {
    generation: u32 = 0,
    state: State = .free,
    dropped: bool = false,
    native_pending: bool = false,
    id: ?[]u8 = null,
    title: ?[]u8 = null,
    namespace: ?[]u8 = null,
    output: ?[]u8 = null,
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
    background: ?@import("../core/color.zig").Color = null,
    background_effect: ?platform_window.BackgroundEffect = null,
    input_region: ?@import("../core/geometry.zig").RectI = null,
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
    /// Declarations `reconcile` could not create or update because the host
    /// lacks a protocol they need. Taken by the runner after each reconcile.
    unsupported: std.ArrayList(Unsupported) = .empty,

    pub const Unsupported = struct { id: []u8, err: anyerror };

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
        for (self.unsupported.items) |item| self.allocator.free(item.id);
        self.unsupported.deinit(self.allocator);
        self.allocator.free(self.events);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Reserves local resources without issuing native requests or changing
    /// live slots. Closing slots and compositor tombstones remain occupied:
    /// replacing a full set needs temporary headroom until retirement drains.
    pub fn prepare(self: *WindowSet, declarations: []const SurfaceDeclaration) !Prepared {
        try validateDeclarations(declarations);
        try self.validateTransitions(declarations);
        // Reload commits cannot undo native effects: reject unsupported
        // surfaces while the candidate can still be refused.
        for (declarations) |declaration| try self.host.check(declaration);
        try self.ensureCreateCapacity(declarations);
        const additions = try self.allocator.alloc(Slot, self.slots.len);
        @memset(additions, .{});
        errdefer self.allocator.free(additions);
        const titles = try self.allocator.alloc(?[]u8, self.slots.len);
        @memset(titles, null);
        var prepared: Prepared = .{
            .windows = self,
            .declarations = declarations,
            .additions = additions,
            .titles = titles,
        };
        // Prepared owns both arrays from here on.
        errdefer prepared.releaseContents();
        for (declarations) |declaration| {
            if (self.findById(declaration.id())) |slot| {
                if (slot.state == .active and declaration == .toplevel and
                    !std.mem.eql(u8, slot.title.?, declaration.toplevel.title))
                {
                    const index = self.handleForId(declaration.id()).?.slot;
                    titles[index] = try self.allocator.dupe(u8, declaration.toplevel.title);
                }
                continue;
            }
            for (self.slots, additions) |slot, *addition| {
                if (slot.state != .free or addition.state != .free) continue;
                addition.* = try self.prepareSlot(declaration, slot.generation);
                break;
            }
        }
        return prepared;
    }

    pub const Prepared = struct {
        windows: *WindowSet,
        declarations: []const SurfaceDeclaration,
        additions: []Slot,
        titles: []?[]u8,

        pub fn deinit(self: *Prepared) void {
            self.releaseContents();
            self.windows.allocator.free(self.additions);
            self.* = undefined;
        }

        fn releaseContents(self: *Prepared) void {
            for (self.additions) |slot| if (slot.state != .free) {
                self.windows.scheduler.destroyScope(slot.scope) catch unreachable;
                self.windows.freeSlotStrings(slot);
            };
            for (self.titles) |title| if (title) |value| self.windows.allocator.free(value);
            self.windows.allocator.free(self.titles);
        }

        pub fn handleForId(self: *Prepared, id: []const u8) ?WindowHandle {
            if (self.windows.activeHandleForId(id)) |handle| return handle;
            for (self.additions, 0..) |*slot, index| {
                if (slot.state != .free and std.mem.eql(u8, slot.id.?, id)) return handleFor(slot, index);
            }
            return null;
        }

        pub fn scope(self: *Prepared, handle: WindowHandle) ScopeHandle {
            const addition = self.additions[handle.slot];
            if (addition.state != .free) return addition.scope;
            return self.windows.scope(handle) catch unreachable;
        }

        /// The caller has committed its validated local application before
        /// entering here. Protocol/transport failures are fatal host failures,
        /// NOT recoverable reload rejection: native effects cannot be undone.
        pub fn commit(self: *Prepared) !void {
            const windows = self.windows;
            // Publish every reserved scope first, so ownership remains known
            // even if a later native request fails.
            for (windows.slots, self.additions) |*slot, *addition| {
                if (addition.state == .free) continue;
                slot.* = addition.*;
                addition.* = .{};
            }
            for (windows.slots, 0..) |*slot, index| {
                if (slot.state != .active) continue;
                const declaration = findDeclaration(self.declarations, slot.id.?) orelse {
                    slot.dropped = true;
                    try windows.host.beginClose(handleFor(slot, index));
                    try windows.scheduler.queueScopeCancellation(slot.scope);
                    slot.state = .closing;
                    continue;
                };
                // New slots have not yet had native creation.
                if (slot.native_pending) {
                    try windows.host.create(handleFor(slot, index), slot.scope, declaration);
                    slot.native_pending = false;
                    continue;
                }
                switch (declaration) {
                    .toplevel => |value| {
                        if (self.titles[index]) |title| {
                            try windows.host.updateTitle(handleFor(slot, index), title);
                            windows.allocator.free(slot.title.?);
                            slot.title = title;
                            self.titles[index] = null;
                        }
                        if (slot.min_width != value.min_width or slot.min_height != value.min_height) {
                            try windows.host.updateMinimumSize(handleFor(slot, index), value.min_width, value.min_height);
                            slot.min_width = value.min_width;
                            slot.min_height = value.min_height;
                        }
                    },
                    .layer_surface => |value| if (!layerStateEqual(slot, value)) {
                        try windows.host.updateLayerSurface(handleFor(slot, index), value);
                        setLayerState(slot, value);
                    },
                    .popup => {},
                }
            }
            for (windows.slots) |*slot| if (slot.state != .free and findDeclaration(self.declarations, slot.id.?) == null) {
                slot.dropped = true;
            };
        }
    };

    /// Applies one complete, already-decoded desired-state snapshot. Validation
    /// finishes before native state changes, so malformed Lua output can never
    /// partially replace the last valid window set.
    pub fn reconcile(self: *WindowSet, declarations: []const SurfaceDeclaration) !void {
        try validateDeclarations(declarations);
        try self.validateTransitions(declarations);
        for (self.slots) |*slot| if (slot.state != .free and findDeclaration(declarations, slot.id.?) == null) {
            slot.dropped = true;
        };
        try self.collectClosed();
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
                    // An unsupported update keeps the native surface as it
                    // was; the runner closes it and reports the failure.
                    self.host.updateLayerSurface(handleFor(slot, index), layer_surface) catch |err| {
                        try self.skipUnsupported(slot.id.?, err);
                        continue;
                    };
                    setLayerState(slot, layer_surface);
                },
                .popup => {},
            }
        }

        for (declarations) |declaration| {
            if (self.findById(declaration.id()) != null) continue;
            self.create(declaration) catch |err| try self.skipUnsupported(declaration.id(), err);
        }
    }

    /// The native-transition part of `reconcile`'s validation for one
    /// declaration, changing nothing: a retained id cannot change its role,
    /// layer namespace or output, or clear an explicit exclusive edge.
    pub fn checkTransition(self: *WindowSet, declaration: SurfaceDeclaration) !void {
        try self.validateTransitions(&.{declaration});
        try self.host.check(declaration);
    }

    /// The next declaration `reconcile` skipped as unsupported; the caller
    /// frees `id` with `releaseUnsupported`.
    pub fn takeUnsupported(self: *WindowSet) ?Unsupported {
        if (self.unsupported.items.len == 0) return null;
        return self.unsupported.orderedRemove(0);
    }

    pub fn releaseUnsupported(self: *WindowSet, item: Unsupported) void {
        self.allocator.free(item.id);
    }

    fn skipUnsupported(self: *WindowSet, id: []const u8, err: anyerror) !void {
        if (!platform_window.isUnsupported(err)) return err;
        for (self.unsupported.items) |item| if (std.mem.eql(u8, item.id, id)) return;
        const owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned);
        try self.unsupported.append(self.allocator, .{ .id = owned, .err = err });
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

    pub fn activeHandleForId(self: *WindowSet, id: []const u8) ?WindowHandle {
        for (self.slots, 0..) |*slot, index|
            if (slot.state == .active and std.mem.eql(u8, slot.id.?, id)) return handleFor(slot, index);
        return null;
    }

    pub fn changeSerial(self: *const WindowSet) u64 {
        return self.change_serial;
    }

    pub fn eventSink(self: *WindowSet) platform_window.EventSink {
        return .{ .context = self, .vtable = &event_sink_vtable };
    }

    pub fn create(self: *WindowSet, declaration: SurfaceDeclaration) !void {
        try validateDeclarations(&.{declaration});
        if (self.findById(declaration.id()) != null) return error.DuplicateWindowId;
        var free_index: ?usize = null;
        for (self.slots, 0..) |slot, index| if (slot.state == .free) {
            free_index = index;
            break;
        };
        const index = free_index orelse grown: {
            const first = self.slots.len;
            try self.growSlots(1);
            break :grown first;
        };
        var prepared = try self.prepareSlot(declaration, self.slots[index].generation);
        errdefer {
            self.scheduler.destroyScope(prepared.scope) catch unreachable;
            self.freeSlotStrings(prepared);
        }
        try self.host.create(handleFor(&prepared, index), prepared.scope, declaration);
        prepared.native_pending = false;
        self.slots[index] = prepared;
    }

    fn freeSlotStrings(self: *WindowSet, slot: Slot) void {
        self.allocator.free(slot.id.?);
        if (slot.title) |value| self.allocator.free(value);
        if (slot.namespace) |value| self.allocator.free(value);
        if (slot.output) |value| self.allocator.free(value);
    }

    fn prepareSlot(self: *WindowSet, declaration: SurfaceDeclaration, previous_generation: u32) !Slot {
        const id = try self.allocator.dupe(u8, declaration.id());
        errdefer self.allocator.free(id);
        const title = switch (declaration) {
            .toplevel => |value| try self.allocator.dupe(u8, value.title),
            .layer_surface, .popup => null,
        };
        errdefer if (title) |value| self.allocator.free(value);
        const namespace = switch (declaration) {
            .toplevel, .popup => null,
            .layer_surface => |value| try self.allocator.dupe(u8, value.namespace),
        };
        errdefer if (namespace) |value| self.allocator.free(value);
        const output = switch (declaration) {
            .toplevel, .popup => null,
            .layer_surface => |value| if (value.output) |name|
                try self.allocator.dupe(u8, name)
            else
                null,
        };
        errdefer if (output) |value| self.allocator.free(value);
        const scope_handle = try self.scheduler.createScope(self.scheduler.application_scope);
        errdefer self.scheduler.destroyScope(scope_handle) catch unreachable;

        var generation = previous_generation +% 1;
        if (generation == 0) generation = 1;
        var slot: Slot = .{
            .generation = generation,
            .state = .active,
            .native_pending = true,
            .id = id,
            .title = title,
            .namespace = namespace,
            .output = output,
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
            .layer_surface => |value| setLayerState(&slot, value),
            .popup => {},
        }
        return slot;
    }

    fn collectClosed(self: *WindowSet) !void {
        for (self.slots) |*slot| {
            // A native close does not reopen an unchanged declaration. A
            // dropped-and-restored declaration does, after teardown drains.
            if (slot.state != .closed or !slot.dropped) continue;
            self.scheduler.destroyScope(slot.scope) catch |err| switch (err) {
                error.ScopeNotEmpty => continue,
                else => return err,
            };
            self.allocator.free(slot.id.?);
            if (slot.title) |title| self.allocator.free(title);
            if (slot.namespace) |namespace| self.allocator.free(namespace);
            if (slot.output) |output| self.allocator.free(output);
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
        if (create_count > free_count) try self.growSlots(create_count - free_count);
    }

    /// Slots are addressed by index (window handles), so growing may move
    /// them. Only preparation and creation grow; commit never does.
    fn growSlots(self: *WindowSet, additional: usize) !void {
        const old_len = self.slots.len;
        self.slots = try self.allocator.realloc(self.slots, @max(old_len + additional, old_len * 2));
        @memset(self.slots[old_len..], .{});
    }

    fn validateTransitions(self: *WindowSet, declarations: []const SurfaceDeclaration) !void {
        for (declarations) |declaration| {
            const slot = self.findById(declaration.id()) orelse continue;
            if (slot.state != .active) continue;
            if (slot.role != declarationRole(declaration)) return error.WindowRoleChanged;
            if (declaration == .layer_surface) {
                if (!std.mem.eql(u8, slot.namespace.?, declaration.layer_surface.namespace))
                    return error.LayerSurfaceNamespaceChanged;
                if (!optionalStringEqual(slot.output, declaration.layer_surface.output))
                    return error.LayerSurfaceOutputChanged;
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
                .generation = batch.generation,
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
                if (layer_surface.session_lock) for (declarations[0..index]) |earlier| {
                    if (earlier == .layer_surface and earlier.layer_surface.session_lock and
                        optionalStringEqual(earlier.layer_surface.output, layer_surface.output))
                        return error.DuplicateLockOutput;
                };
            },
            .popup => |popup| try popup.validate(),
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
        .layer_surface => |value| if (value.session_lock) .session_lock else .layer_surface,
        .popup => .popup,
    };
}

fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn layerStateEqual(slot: *const Slot, declaration: LayerSurfaceDeclaration) bool {
    return slot.initial_width == declaration.width and
        slot.initial_height == declaration.height and
        slot.layer == declaration.layer and
        std.meta.eql(slot.anchors, declaration.anchors) and
        slot.exclusive_zone == declaration.exclusive_zone and
        slot.exclusive_edge == declaration.exclusive_edge and
        std.meta.eql(slot.margins, declaration.margins) and
        std.meta.eql(slot.background, declaration.background) and
        slot.background_effect == declaration.background_effect and
        std.meta.eql(slot.input_region, declaration.input_region) and
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
    slot.background = declaration.background;
    slot.background_effect = declaration.background_effect;
    slot.input_region = declaration.input_region;
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

    actions: [128]Action = undefined,
    count: usize = 0,
    /// Behaves like a compositor without ext-session-lock.
    refuse_lock: bool = false,

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
        declaration: SurfaceDeclaration,
    ) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        try check(context, declaration);
        self.append(.{ .create = .{ .handle = handle, .scope = scope_handle } });
    }

    fn check(context: *anyopaque, declaration: SurfaceDeclaration) !void {
        const self: *FakeHost = @ptrCast(@alignCast(context));
        if (self.refuse_lock and declaration == .layer_surface and declaration.layer_surface.session_lock)
            return error.SessionLockUnavailable;
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
        .check = check,
    };
};

test "surfaces the host cannot provide are skipped and reported, not fatal" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{ .refuse_lock = true };
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 2, 4);
    defer windows.deinit();

    const lock: SurfaceDeclaration = .{ .layer_surface = .{
        .id = "lock",
        .namespace = "session-lock",
        .session_lock = true,
        .output = "HEADLESS-1",
        .width = 0,
        .height = 0,
        .layer = .overlay,
        .anchors = .{ .top = true, .bottom = true, .left = true, .right = true },
    } };
    const declarations = [_]SurfaceDeclaration{ .{ .toplevel = .{ .id = "main", .title = "Main" } }, lock };
    try windows.reconcile(&declarations);
    try std.testing.expectEqual(@as(usize, 1), windows.activeCount());
    const skipped = windows.takeUnsupported().?;
    defer windows.releaseUnsupported(skipped);
    try std.testing.expectEqualStrings("lock", skipped.id);
    try std.testing.expectEqual(@as(anyerror, error.SessionLockUnavailable), skipped.err);
    try std.testing.expectEqual(@as(?WindowSet.Unsupported, null), windows.takeUnsupported());
    // Checks before commit reject it too: reactive refreshes and reloads.
    try std.testing.expectError(error.SessionLockUnavailable, windows.checkTransition(lock));
    try std.testing.expectError(error.SessionLockUnavailable, windows.prepare(&declarations));

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(host.actions[0].create.handle);
    try windows.reconcile(&.{});
}

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
        .output = "DP-1",
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

    var changed_output = updated;
    changed_output.layer_surface.output = "HDMI-A-1";
    try std.testing.expectError(
        error.LayerSurfaceOutputChanged,
        windows.reconcile(&.{changed_output}),
    );
    try std.testing.expectEqual(@as(usize, 2), host.count);

    updated.layer_surface.background = .rgba(17, 24, 32, 184);
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(handle, host.actions[2].update_layer_surface);
    updated.layer_surface.background_effect = .blur;
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(handle, host.actions[3].update_layer_surface);
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(@as(usize, 4), host.count);
    updated.layer_surface.background = null;
    updated.layer_surface.background_effect = null;
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(handle, host.actions[4].update_layer_surface);

    updated.layer_surface.input_region = .{ .x = 3, .y = 7, .width = 110, .height = 23 };
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(handle, host.actions[5].update_layer_surface);
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(@as(usize, 6), host.count);
    updated.layer_surface.input_region.?.height = 0;
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(handle, host.actions[6].update_layer_surface);
    var invalid_region = updated;
    invalid_region.layer_surface.input_region.?.width = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidLayerSurfaceInputRegion, windows.reconcile(&.{invalid_region}));
    try std.testing.expectEqual(@as(usize, 7), host.count);
    updated.layer_surface.input_region = null;
    try windows.reconcile(&.{updated});
    try std.testing.expectEqual(handle, host.actions[7].update_layer_surface);

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
    var invalid = too_many;
    invalid[1].toplevel.initial_width = 0;
    try std.testing.expectError(error.InvalidWindowSize, windows.reconcile(&invalid));
    try std.testing.expectEqual(@as(usize, 1), host.count);
    try std.testing.expectEqual(@as(usize, 1), windows.activeCount());

    const handle = host.actions[0].create.handle;
    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(handle);
    try windows.reconcile(&.{});
}

fn preparedAllocationFailure(allocator: std.mem.Allocator) !void {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 4, 4);
    defer windows.deinit();
    try windows.reconcile(&.{
        .{ .toplevel = .{ .id = "keep", .title = "Old" } },
        .{ .toplevel = .{ .id = "remove", .title = "Removed" } },
    });
    const keep = windows.activeHandleForId("keep").?;
    const removed = windows.activeHandleForId("remove").?;
    const scopes = scheduler.availableScopeCapacity();
    defer {
        windows.allocator = std.testing.allocator;
        windows.markClosed(keep) catch unreachable;
        windows.markClosed(removed) catch unreachable;
        windows.reconcile(&.{}) catch unreachable;
    }
    windows.allocator = allocator;
    var prepared = windows.prepare(&.{
        .{ .toplevel = .{ .id = "new-first", .title = "First" } },
        .{ .toplevel = .{ .id = "keep", .title = "Changed" } },
        .{ .layer_surface = .{ .id = "new-last", .namespace = "test", .output = "DP-1", .width = 100, .height = 40, .layer = .top } },
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), host.count);
        try std.testing.expectEqual(keep, windows.activeHandleForId("keep").?);
        try std.testing.expectEqual(removed, windows.activeHandleForId("remove").?);
        try std.testing.expectEqualStrings("Old", windows.slots[keep.slot].title.?);
        try std.testing.expect(!windows.slots[removed.slot].dropped);
        try std.testing.expectEqual(scopes, scheduler.availableScopeCapacity());
        return err;
    };
    prepared.deinit();
    try std.testing.expectEqual(scopes, scheduler.availableScopeCapacity());
    try std.testing.expectEqual(@as(usize, 2), host.count);
}

test "prepared window reservations roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, preparedAllocationFailure, .{});
}

test "preparing past the initial window capacity grows without dropping live identities" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 1, 2);
    defer windows.deinit();
    try windows.reconcile(&.{.{ .toplevel = .{ .id = "old", .title = "Old" } }});
    const handle = windows.activeHandleForId("old").?;
    var prepared = try windows.prepare(&.{
        .{ .toplevel = .{ .id = "old", .title = "Old" } },
        .{ .toplevel = .{ .id = "new", .title = "New" } },
    });
    try std.testing.expect(windows.slots.len >= 2);
    try std.testing.expect(prepared.handleForId("new") != null);
    prepared.deinit();
    try std.testing.expectEqual(handle, windows.activeHandleForId("old").?);
    try std.testing.expect(!windows.slots[handle.slot].dropped);
    try std.testing.expectEqual(@as(usize, 1), host.count);
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

test "restoring a dropped window while it closes remounts after scope drainage" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 5, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 2, 2);
    defer windows.deinit();
    const declarations = [_]SurfaceDeclaration{
        .{ .toplevel = .{ .id = "bar", .title = "Bar" } },
        .{ .toplevel = .{ .id = "launcher", .title = "Launcher" } },
    };
    try windows.reconcile(&declarations);
    const bar = windows.activeHandleForId("bar").?;
    const original = windows.activeHandleForId("launcher").?;
    const child = try scheduler.createScope(try windows.scope(original));
    try windows.reconcile(declarations[0..1]);
    try windows.reconcile(&declarations);
    try std.testing.expect(windows.activeHandleForId("launcher") == null);
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(original);
    try windows.reconcile(&declarations);
    try std.testing.expect(windows.activeHandleForId("launcher") == null);
    try scheduler.destroyScope(child);
    try windows.reconcile(&declarations);
    const replacement = windows.activeHandleForId("launcher").?;
    try std.testing.expect(!std.meta.eql(original, replacement));
    try std.testing.expectEqual(bar, windows.activeHandleForId("bar").?);
    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(bar);
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
        .generation = 91,
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
    try std.testing.expectEqual(@as(?u64, 91), event.text_input.batch.generation);
    try std.testing.expectEqualStrings("ok", event.text_input.batch.commit.?.text.?);
    try std.testing.expectEqualStrings("new", event.text_input.batch.preedit.?.text.?);

    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try windows.markClosed(handle);
    try windows.reconcile(&.{});
}

test "forty windows open past the initial capacity and close back to baseline" {
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    var host: FakeHost = .{};
    var windows: WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, host.interface(), 16, 2);
    defer windows.deinit();
    const baseline = scheduler.scopeCapacity() - scheduler.availableScopeCapacity();
    var ids: [40][8]u8 = undefined;
    var declarations: [40]SurfaceDeclaration = undefined;
    for (&declarations, &ids, 0..) |*declaration, *id, index|
        declaration.* = .{ .toplevel = .{ .id = try std.fmt.bufPrint(id, "w{d}", .{index}), .title = "Window" } };
    try windows.reconcile(&declarations);
    try std.testing.expectEqual(@as(usize, 40), windows.activeCount());
    try std.testing.expectEqual(@as(usize, 40), host.count);
    var handles: [40]WindowHandle = undefined;
    for (&handles, declarations) |*handle, declaration| handle.* = windows.activeHandleForId(declaration.id()).?;
    try windows.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    for (handles) |handle| try windows.markClosed(handle);
    try windows.reconcile(&.{});
    try std.testing.expectEqual(@as(usize, 0), windows.activeCount());
    try std.testing.expectEqual(baseline, scheduler.scopeCapacity() - scheduler.availableScopeCapacity());
}
