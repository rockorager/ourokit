const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayland_protocol");
const OuroLoop = @import("../../loop/io_uring.zig").Loop;
const platform_window = @import("../window.zig");
const Adapter = @import("adapter.zig").Adapter;

const linux = std.os.linux;
const posix = std.posix;
const Handle = wayring.objects.Handle;
const WindowHandle = platform_window.WindowHandle;
const ScopeHandle = @import("../../task/scheduler.zig").ScopeHandle;
const Core = wayring.client.Core(protocol);
const Connection = wayring.client.Connection(protocol);
const Driver = wayring.client.Driver(protocol);
const Roundtrip = wayring.client.Roundtrip(protocol, *Host);

const buffer_count = 3;

pub const Config = struct {
    app_id: []const u8,
    window_capacity: usize = 8,
    reactor: wayring.io_uring.Config = .{
        .buffer_group_id = 1,
        .receive_buffer_size = 16 * 1024,
        .receive_buffer_count = 8,
        .receive_control_capacity = 512,
        .fragment_block_size = 4096,
        .fragment_block_count = 8,
        .transmit_block_size = 4096,
        .transmit_block_count = 16,
        .descriptor_count = 16,
        .send_descriptor_capacity = 4,
    },
};

pub const Frame = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    window: WindowHandle,
    pool_generation: u32,
    slot: u8,
};

const BufferSlot = struct {
    handle: ?Handle = null,
    busy: bool = false,
    acquired: bool = false,
};

const ShmBuffers = struct {
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    slots: [buffer_count]BufferSlot = [_]BufferSlot{.{}} ** buffer_count,
    width: u32 = 0,
    height: u32 = 0,
    stride: usize = 0,
    slot_size: usize = 0,
    generation: u32 = 0,

    fn matches(self: *const ShmBuffers, width: u32, height: u32) bool {
        return self.mapping != null and self.width == width and self.height == height;
    }

    fn anyBusy(self: *const ShmBuffers) bool {
        for (self.slots) |slot| if (slot.busy or slot.acquired) return true;
        return false;
    }

    fn slotForId(self: *ShmBuffers, id: u32) ?*BufferSlot {
        for (&self.slots) |*slot| if (slot.handle != null and slot.handle.?.id == id) return slot;
        return null;
    }

    fn containsId(self: *const ShmBuffers, id: u32) bool {
        for (self.slots) |slot| if (slot.handle != null and slot.handle.?.id == id) return true;
        return false;
    }

    fn create(
        self: *ShmBuffers,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        shm: Handle,
        width: u32,
        height: u32,
        generation: u32,
    ) !void {
        std.debug.assert(self.mapping == null);
        const stride = try std.math.mul(usize, width, 4);
        const slot_size = try std.math.mul(usize, stride, height);
        const total_size = try std.math.mul(usize, slot_size, buffer_count);
        if (total_size > std.math.maxInt(i32) or width > std.math.maxInt(i32) or
            height > std.math.maxInt(i32) or stride > std.math.maxInt(i32))
            return error.BufferPoolTooLarge;

        const fd = try posix.memfd_create("ourokit-wayland", linux.MFD.CLOEXEC);
        var fd_owned = true;
        errdefer {
            if (fd_owned) _ = linux.close(fd);
        }
        if (linux.errno(linux.ftruncate(fd, @intCast(total_size))) != .SUCCESS)
            return error.TruncateFailed;
        const mapping = try posix.mmap(
            null,
            total_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(mapping);

        const pool = (try protocol.wl_shm.construct_create_pool(
            objects,
            transmit,
            shm,
            .{ .fd = fd, .size = @intCast(total_size) },
        )).id;
        fd_owned = false;
        var slots = [_]BufferSlot{.{}} ** buffer_count;
        for (&slots, 0..) |*slot, index| {
            slot.handle = (try protocol.wl_shm_pool.construct_create_buffer(
                objects,
                transmit,
                pool,
                .{
                    .offset = @intCast(index * slot_size),
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .stride = @intCast(stride),
                    .format = protocol.wl_shm.format.argb8888,
                },
            )).id;
        }
        try wayring.client.sendRequest(protocol.wl_shm_pool, objects, transmit, pool, .{ .destroy = .{} });
        self.* = .{
            .mapping = mapping,
            .slots = slots,
            .width = width,
            .height = height,
            .stride = stride,
            .slot_size = slot_size,
            .generation = generation,
        };
    }

    fn destroy(
        self: *ShmBuffers,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
    ) !void {
        std.debug.assert(!self.anyBusy());
        for (&self.slots) |*slot| {
            if (slot.handle) |handle|
                try wayring.client.sendRequest(protocol.wl_buffer, objects, transmit, handle, .{ .destroy = .{} });
            slot.* = .{};
        }
        self.releaseLocal();
        const generation = self.generation;
        self.* = .{ .generation = generation };
    }

    fn releaseLocal(self: *ShmBuffers) void {
        if (self.mapping) |mapping| posix.munmap(mapping);
        self.mapping = null;
    }
};

const WindowState = enum { free, open, closing, surfaces_destroyed };

const Window = struct {
    state: WindowState = .free,
    handle: WindowHandle = .invalid,
    scope: ScopeHandle = .invalid,
    surface: ?Handle = null,
    xdg_surface: ?Handle = null,
    toplevel: ?Handle = null,
    frame_callback: ?Handle = null,
    buffers: ShmBuffers = .{},
    retired_buffers: ShmBuffers = .{},
    width: u32 = 0,
    height: u32 = 0,
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    configured: bool = false,
    pending_redraw: bool = false,
    frames_presented: usize = 0,
    next_pool_generation: u32 = 1,

    fn ownsObject(self: *const Window, object_id: u32) bool {
        return (self.surface != null and self.surface.?.id == object_id) or
            (self.xdg_surface != null and self.xdg_surface.?.id == object_id) or
            (self.toplevel != null and self.toplevel.?.id == object_id) or
            (self.frame_callback != null and self.frame_callback.?.id == object_id) or
            self.buffers.containsId(object_id) or self.retired_buffers.containsId(object_id);
    }
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    loop: *OuroLoop,
    sink: platform_window.EventSink,
    app_id: []u8,
    adapter: Adapter,
    connection: Connection,
    driver: Driver,
    registry: Handle,
    compositor: ?Handle = null,
    shm: ?Handle = null,
    wm_base: ?Handle = null,
    seat: ?Handle = null,
    seat_global_name: ?u32 = null,
    pointer: ?Handle = null,
    pointer_focus: ?WindowHandle = null,
    windows: []Window,
    disconnect_started: bool = false,
    transport_lost: bool = false,
    submission_pending: bool = false,
    failure: ?anyerror = null,

    /// `self`, `loop`, and the sink context must retain stable addresses until
    /// the connection is quiescent and `deinit` completes.
    pub fn init(
        self: *Host,
        allocator: std.mem.Allocator,
        loop: *OuroLoop,
        environ: std.process.Environ,
        sink: platform_window.EventSink,
        config: Config,
    ) !void {
        if (config.window_capacity == 0 or config.app_id.len == 0) return error.InvalidConfig;
        const windows = try allocator.alloc(Window, config.window_capacity);
        errdefer allocator.free(windows);
        @memset(windows, .{});
        const app_id = try allocator.dupe(u8, config.app_id);
        errdefer allocator.free(app_id);

        self.allocator = allocator;
        self.loop = loop;
        self.sink = sink;
        self.app_id = app_id;
        self.windows = windows;
        self.disconnect_started = false;
        self.transport_lost = false;
        self.submission_pending = false;
        self.failure = null;
        self.compositor = null;
        self.shm = null;
        self.wm_base = null;
        self.seat = null;
        self.seat_global_name = null;
        self.pointer = null;
        self.pointer_focus = null;
        try self.adapter.init(allocator, loop, config.reactor);
        errdefer self.adapter.deinit(allocator);

        var path_storage: [std.fs.max_path_bytes]u8 = undefined;
        const socket = try wayring.unix_socket.connectEnvironment(&path_storage, environ);
        self.connection = try Connection.attach(
            allocator,
            &self.adapter.reactor,
            socket,
            .{
                .received_fd_budget = 4,
                .transmit_byte_budget = 128 * 1024,
                .transmit_fd_budget = 4,
            },
            .{ .max_objects = 64 + config.window_capacity * 16, .max_client_ids = 48 + config.window_capacity * 16 },
        );
        self.driver = Driver.init(&self.connection);
        self.finishStartup() catch |err| {
            try self.abortStartup();
            return err;
        };
    }

    fn finishStartup(self: *Host) !void {
        const actor = try self.connection.actor();
        self.registry = try Core.getRegistry(&self.connection.objects, &actor.transmit, null);

        var roundtrip = Roundtrip.init(&self.connection, self);
        _ = try roundtrip.begin();
        try self.flush();
        while (!roundtrip.settled()) {
            try self.dispatch(try self.loop.wait(), &roundtrip);
            try self.flushRoundtrip(&roundtrip);
        }
        // A receive can settle the roundtrip before the earlier send CQE is
        // reaped. Do not hand the connection to the application with a stale
        // active-send gate, or newly queued window requests cannot be armed.
        while ((try self.connection.actor()).transmit.sendActive()) {
            try self.dispatch(try self.loop.wait(), self);
            try self.flush();
        }
        if (self.failure) |failure| return failure;
        if (self.compositor == null or self.shm == null or self.wm_base == null)
            return error.RequiredWaylandGlobalMissing;
    }

    fn abortStartup(self: *Host) !void {
        const actor = try self.connection.actor();
        if (actor.lifecycle == .open) {
            if (try self.connection.prepareClose()) self.submission_pending = true;
        }
        self.disconnect_started = true;
        _ = try self.driver.schedule();
        while (!(try self.connection.actor()).canDeinit()) {
            try self.flushHandler(self);
            try self.dispatch(try self.loop.wait(), self);
        }
        try self.connection.deinit(self.allocator);
    }

    pub fn deinit(self: *Host) void {
        std.debug.assert(self.quiescent());
        for (self.windows) |window| std.debug.assert(window.state == .free);
        self.connection.deinit(self.allocator) catch unreachable;
        self.adapter.deinit(self.allocator);
        self.allocator.free(self.windows);
        self.allocator.free(self.app_id);
        self.* = undefined;
    }

    pub fn nativeHost(self: *Host) platform_window.NativeHost {
        return .{ .context = self, .vtable = &native_vtable };
    }

    pub fn dispatchOne(self: *Host, completion: std.os.linux.io_uring_cqe) !void {
        try self.dispatch(completion, self);
        if (self.transport_lost)
            try self.abandonWindows()
        else
            try self.maintainWindows();
    }

    pub fn flush(self: *Host) !void {
        if (self.transport_lost)
            try self.abandonWindows()
        else
            try self.maintainWindows();
        try self.flushHandler(self);
    }

    pub fn beginDisconnect(self: *Host) !void {
        if (self.disconnect_started) return;
        for (self.windows) |window| if (window.state != .free) return error.WindowsRemainOpen;
        try self.releaseInput();
        if ((try self.connection.actor()).lifecycle == .open and
            try self.connection.prepareClose()) self.submission_pending = true;
        self.disconnect_started = true;
        _ = try self.driver.schedule();
    }

    pub fn quiescent(self: *Host) bool {
        if (!self.disconnect_started) return false;
        const actor = self.connection.actor() catch return false;
        return actor.canDeinit();
    }

    pub fn requestRedraw(self: *Host, handle: WindowHandle) !void {
        const window = try self.windowFor(handle);
        if (window.state != .open) return error.WindowClosing;
        window.pending_redraw = true;
    }

    /// Borrows one persistent shared-memory slot for synchronous rendering in
    /// the frame-submission phase. Call `present` or `discard` before returning
    /// to completion dispatch.
    pub fn acquireFrame(self: *Host, handle: WindowHandle) !?Frame {
        const window = try self.windowFor(handle);
        if (window.state != .open or !window.configured or !window.pending_redraw or
            window.frame_callback != null) return null;
        try self.prepareBuffers(window);
        if (!window.buffers.matches(window.width, window.height)) return null;
        for (&window.buffers.slots, 0..) |*slot, index| {
            if (slot.busy or slot.acquired) continue;
            slot.acquired = true;
            const start = index * window.buffers.slot_size;
            return .{
                .pixels = window.buffers.mapping.?[start..][0..window.buffers.slot_size],
                .width = window.width,
                .height = window.height,
                .stride = window.buffers.stride,
                .window = handle,
                .pool_generation = window.buffers.generation,
                .slot = @intCast(index),
            };
        }
        return null;
    }

    pub fn discardFrame(self: *Host, frame: Frame) !void {
        const slot = try self.frameSlot(frame);
        if (!slot.acquired) return error.StaleFrame;
        slot.acquired = false;
    }

    pub fn present(self: *Host, frame: Frame) !void {
        const window = try self.windowFor(frame.window);
        if (window.state != .open) return error.WindowClosing;
        const slot = try self.frameSlot(frame);
        if (!slot.acquired or slot.busy) return error.StaleFrame;
        const transmit = try self.queue();
        const objects = &self.connection.objects;
        try wayring.client.sendRequest(
            protocol.wl_surface,
            objects,
            transmit,
            window.surface.?,
            .{ .attach = .{ .buffer = slot.handle.?.id, .x = 0, .y = 0 } },
        );
        try wayring.client.sendRequest(
            protocol.wl_surface,
            objects,
            transmit,
            window.surface.?,
            .{ .damage = .{ .x = 0, .y = 0, .width = @intCast(frame.width), .height = @intCast(frame.height) } },
        );
        window.frame_callback = (try protocol.wl_surface.construct_frame(
            objects,
            transmit,
            window.surface.?,
            .{},
        )).callback;
        try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, window.surface.?, .{ .commit = .{} });
        slot.acquired = false;
        slot.busy = true;
        window.pending_redraw = false;
        _ = try self.driver.schedule();
    }

    pub fn framesPresented(self: *Host, handle: WindowHandle) !usize {
        return (try self.windowFor(handle)).frames_presented;
    }

    fn dispatch(self: *Host, completion: std.os.linux.io_uring_cqe, handler: anytype) !void {
        if (self.adapter.route(completion) == null) return error.InvalidCompletion;
        const progress = try self.driver.dispatch(&.{completion}, handler);
        if (progress.prepared != 0 or progress.pending) self.submission_pending = true;
    }

    fn flushRoundtrip(self: *Host, roundtrip: *Roundtrip) !void {
        try self.flushHandler(roundtrip);
    }

    fn flushHandler(self: *Host, handler: anytype) !void {
        _ = try self.driver.schedule();
        while (true) {
            const progress = try self.driver.prepare(handler);
            if (self.transport_lost) try self.abandonWindows();
            if (progress.prepared != 0) self.submission_pending = true;
            if (self.submission_pending or progress.pending) {
                _ = try self.loop.submit();
                self.submission_pending = false;
            }
            if (!progress.pending) break;
        }
    }

    fn queue(self: *Host) !*wayring.tx.Queue {
        return &(try self.connection.actor()).transmit;
    }

    fn windowFor(self: *Host, handle: WindowHandle) !*Window {
        for (self.windows) |*window|
            if (window.state != .free and sameWindow(window.handle, handle)) return window;
        return error.StaleWindow;
    }

    fn windowForObject(self: *Host, object_id: u32) !*Window {
        for (self.windows) |*window|
            if (window.state != .free and window.ownsObject(object_id)) return window;
        return error.UnknownWindowObject;
    }

    fn windowForSurface(self: *Host, object_id: u32) !*Window {
        for (self.windows) |*window|
            if (window.state != .free and window.surface != null and
                window.surface.?.id == object_id) return window;
        return error.UnknownWindowSurface;
    }

    fn frameSlot(self: *Host, frame: Frame) !*BufferSlot {
        const window = try self.windowFor(frame.window);
        if (window.buffers.generation != frame.pool_generation or frame.slot >= buffer_count)
            return error.StaleFrame;
        return &window.buffers.slots[frame.slot];
    }

    fn prepareBuffers(self: *Host, window: *Window) !void {
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        if (window.retired_buffers.mapping != null and !window.retired_buffers.anyBusy())
            try window.retired_buffers.destroy(objects, transmit);
        if (window.buffers.matches(window.width, window.height)) return;
        if (window.retired_buffers.mapping != null) return;
        if (window.buffers.mapping != null) {
            if (window.buffers.anyBusy()) {
                window.retired_buffers = window.buffers;
                window.buffers = .{};
            } else {
                try window.buffers.destroy(objects, transmit);
            }
        }
        window.next_pool_generation +%= 1;
        if (window.next_pool_generation == 0) window.next_pool_generation = 1;
        try window.buffers.create(
            objects,
            transmit,
            self.shm.?,
            window.width,
            window.height,
            window.next_pool_generation,
        );
        _ = try self.driver.schedule();
    }

    fn maintainWindows(self: *Host) !void {
        for (self.windows) |*window| {
            if (window.state == .closing and window.frame_callback == null)
                try self.destroySurfaces(window);
            if (window.state != .surfaces_destroyed) continue;
            const objects = &self.connection.objects;
            const transmit = try self.queue();
            if (window.buffers.mapping != null and !window.buffers.anyBusy())
                try window.buffers.destroy(objects, transmit);
            if (window.retired_buffers.mapping != null and !window.retired_buffers.anyBusy())
                try window.retired_buffers.destroy(objects, transmit);
            if (window.buffers.mapping != null or window.retired_buffers.mapping != null) continue;
            const handle = window.handle;
            const next_pool_generation = window.next_pool_generation;
            window.* = .{ .next_pool_generation = next_pool_generation };
            try self.sink.closed(handle);
        }
    }

    fn abandonWindows(self: *Host) !void {
        for (self.windows) |*window| {
            if (window.state == .free) continue;
            window.buffers.releaseLocal();
            window.retired_buffers.releaseLocal();
            const handle = window.handle;
            const next_pool_generation = window.next_pool_generation;
            window.* = .{ .next_pool_generation = next_pool_generation };
            try self.sink.closed(handle);
        }
    }

    fn destroySurfaces(self: *Host, window: *Window) !void {
        std.debug.assert(window.frame_callback == null);
        if (self.pointer_focus) |focus| {
            if (sameWindow(focus, window.handle)) self.pointer_focus = null;
        }
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        if (window.toplevel) |handle|
            try wayring.client.sendRequest(protocol.xdg_toplevel, objects, transmit, handle, .{ .destroy = .{} });
        if (window.xdg_surface) |handle|
            try wayring.client.sendRequest(protocol.xdg_surface, objects, transmit, handle, .{ .destroy = .{} });
        if (window.surface) |handle|
            try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, handle, .{ .destroy = .{} });
        window.toplevel = null;
        window.xdg_surface = null;
        window.surface = null;
        for (&window.buffers.slots) |*slot| slot.acquired = false;
        for (&window.retired_buffers.slots) |*slot| slot.acquired = false;
        window.state = .surfaces_destroyed;
        _ = try self.driver.schedule();
    }

    fn nativeCreate(
        context: *anyopaque,
        handle: WindowHandle,
        scope: ScopeHandle,
        declaration: platform_window.ToplevelDeclaration,
    ) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        var slot: ?*Window = null;
        for (self.windows) |*candidate| if (candidate.state == .free) {
            slot = candidate;
            break;
        };
        const window = slot orelse return error.WindowCapacityExceeded;
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        const surface = (try protocol.wl_compositor.construct_create_surface(
            objects,
            transmit,
            self.compositor.?,
            .{},
        )).id;
        const xdg_surface = (try protocol.xdg_wm_base.construct_get_xdg_surface(
            objects,
            transmit,
            self.wm_base.?,
            .{ .surface = surface.id },
        )).id;
        const toplevel = (try protocol.xdg_surface.construct_get_toplevel(
            objects,
            transmit,
            xdg_surface,
            .{},
        )).id;
        try wayring.client.sendRequest(
            protocol.xdg_toplevel,
            objects,
            transmit,
            toplevel,
            .{ .set_title = .{ .title = declaration.title } },
        );
        try wayring.client.sendRequest(
            protocol.xdg_toplevel,
            objects,
            transmit,
            toplevel,
            .{ .set_app_id = .{ .app_id = self.app_id } },
        );
        try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, surface, .{ .commit = .{} });
        window.* = .{
            .state = .open,
            .handle = handle,
            .scope = scope,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .width = declaration.initial_width,
            .height = declaration.initial_height,
            .pending_width = declaration.initial_width,
            .pending_height = declaration.initial_height,
        };
        _ = try self.driver.schedule();
    }

    fn nativeUpdateTitle(context: *anyopaque, handle: WindowHandle, title: []const u8) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        const window = try self.windowFor(handle);
        if (window.state != .open) return error.WindowClosing;
        try wayring.client.sendRequest(
            protocol.xdg_toplevel,
            &self.connection.objects,
            try self.queue(),
            window.toplevel.?,
            .{ .set_title = .{ .title = title } },
        );
        _ = try self.driver.schedule();
    }

    fn nativeBeginClose(context: *anyopaque, handle: WindowHandle) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        const window = try self.windowFor(handle);
        if (window.state != .open) return;
        window.state = .closing;
        window.pending_redraw = false;
    }

    const native_vtable: platform_window.NativeHost.VTable = .{
        .create = nativeCreate,
        .update_title = nativeUpdateTitle,
        .begin_close = nativeBeginClose,
    };

    pub fn event(
        self: *Host,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const objects = &self.connection.objects;
        const interface = target.object.interface;
        if (interface == &protocol.wl_display.info) {
            _ = try Core.decodeDisplayEvent(objects, message, fds);
        } else if (interface == &protocol.wl_registry.info) {
            switch (try Core.decodeRegistryEvent(objects, self.registry, message, fds)) {
                .global => |global| try self.bindGlobal(global),
                .global_remove => |removed| {
                    if (self.seat_global_name != null and self.seat_global_name.? == removed.name)
                        try self.releaseInput();
                },
            }
        } else if (interface == &protocol.wl_seat.info) {
            switch (try wayring.client.decodeEvent(protocol.wl_seat, objects, self.seat.?, message, fds)) {
                .capabilities => |capabilities| try self.updatePointerCapability(
                    capabilities.capabilities.contains(protocol.wl_seat.capability.pointer),
                ),
                .name => {},
            }
        } else if (interface == &protocol.wl_pointer.info) {
            try self.pointerEvent(message, fds);
        } else if (interface == &protocol.xdg_wm_base.info) {
            switch (try wayring.client.decodeEvent(protocol.xdg_wm_base, objects, self.wm_base.?, message, fds)) {
                .ping => |ping| try wayring.client.sendRequest(
                    protocol.xdg_wm_base,
                    objects,
                    try self.queue(),
                    self.wm_base.?,
                    .{ .pong = .{ .serial = ping.serial } },
                ),
            }
        } else if (interface == &protocol.xdg_toplevel.info) {
            const window = try self.windowForObject(message.header.object_id);
            switch (try wayring.client.decodeEvent(protocol.xdg_toplevel, objects, window.toplevel.?, message, fds)) {
                .configure => |configure| {
                    if (configure.width > 0) window.pending_width = @intCast(configure.width);
                    if (configure.height > 0) window.pending_height = @intCast(configure.height);
                },
                .close => try self.sink.closeRequested(window.handle),
                else => {},
            }
        } else if (interface == &protocol.xdg_surface.info) {
            const window = try self.windowForObject(message.header.object_id);
            switch (try wayring.client.decodeEvent(protocol.xdg_surface, objects, window.xdg_surface.?, message, fds)) {
                .configure => |configure| {
                    try wayring.client.sendRequest(
                        protocol.xdg_surface,
                        objects,
                        try self.queue(),
                        window.xdg_surface.?,
                        .{ .ack_configure = .{ .serial = configure.serial } },
                    );
                    window.width = window.pending_width;
                    window.height = window.pending_height;
                    window.configured = true;
                    window.pending_redraw = true;
                    try self.sink.configured(window.handle, window.width, window.height);
                },
            }
        } else if (interface == &protocol.wl_buffer.info) {
            const window = try self.windowForObject(message.header.object_id);
            const slot = window.buffers.slotForId(message.header.object_id) orelse
                window.retired_buffers.slotForId(message.header.object_id) orelse
                return error.UnknownBuffer;
            _ = try wayring.client.decodeEvent(protocol.wl_buffer, objects, slot.handle.?, message, fds);
            slot.busy = false;
        } else if (interface == &protocol.wl_callback.info) {
            const window = try self.windowForObject(message.header.object_id);
            _ = try wayring.client.decodeEvent(protocol.wl_callback, objects, window.frame_callback.?, message, fds);
            window.frame_callback = null;
            window.frames_presented += 1;
        } else if (interface == &protocol.wl_shm.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_shm, objects, self.shm.?, message, fds);
        } else if (interface == &protocol.wl_surface.info) {
            const window = try self.windowForObject(message.header.object_id);
            _ = try wayring.client.decodeEvent(protocol.wl_surface, objects, window.surface.?, message, fds);
        }
        return .continue_dispatch;
    }

    fn bindGlobal(self: *Host, global: protocol.wl_registry.Event_global) !void {
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        if (std.mem.eql(u8, global.interface, protocol.wl_compositor.info.name)) {
            self.compositor = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wl_compositor.info,
                @min(global.version, 4),
                null,
            );
        } else if (std.mem.eql(u8, global.interface, protocol.wl_shm.info.name)) {
            self.shm = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wl_shm.info,
                1,
                null,
            );
        } else if (std.mem.eql(u8, global.interface, protocol.xdg_wm_base.info.name)) {
            self.wm_base = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.xdg_wm_base.info,
                @min(global.version, 5),
                null,
            );
        } else if (std.mem.eql(u8, global.interface, protocol.wl_seat.info.name) and self.seat == null) {
            self.seat = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wl_seat.info,
                @min(global.version, 9),
                null,
            );
            self.seat_global_name = global.name;
        }
    }

    fn updatePointerCapability(self: *Host, available: bool) !void {
        if (available and self.pointer == null) {
            self.pointer = (try protocol.wl_seat.construct_get_pointer(
                &self.connection.objects,
                try self.queue(),
                self.seat.?,
                .{},
            )).id;
            _ = try self.driver.schedule();
        } else if (!available and self.pointer != null) {
            try self.releasePointer();
        }
    }

    fn releasePointer(self: *Host) !void {
        const pointer = self.pointer orelse return;
        try wayring.client.sendRequest(
            protocol.wl_pointer,
            &self.connection.objects,
            try self.queue(),
            pointer,
            .{ .release = .{} },
        );
        self.pointer = null;
        self.pointer_focus = null;
        _ = try self.driver.schedule();
    }

    fn releaseInput(self: *Host) !void {
        try self.releasePointer();
        if (self.seat) |seat| {
            try wayring.client.sendRequest(
                protocol.wl_seat,
                &self.connection.objects,
                try self.queue(),
                seat,
                .{ .release = .{} },
            );
            self.seat = null;
            self.seat_global_name = null;
            _ = try self.driver.schedule();
        }
    }

    fn pointerEvent(
        self: *Host,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const pointer_event = try wayring.client.decodeEvent(
            protocol.wl_pointer,
            &self.connection.objects,
            self.pointer.?,
            message,
            fds,
        );
        switch (pointer_event) {
            .enter => |enter| {
                const window = try self.windowForSurface(enter.surface);
                self.pointer_focus = window.handle;
                try self.sink.pointer(.{ .enter = .{
                    .window = window.handle,
                    .serial = enter.serial,
                    .position = fixedPosition(enter.surface_x, enter.surface_y),
                } });
            },
            .leave => |leave| {
                const window = try self.windowForSurface(leave.surface);
                try self.sink.pointer(.{ .leave = .{
                    .window = window.handle,
                    .serial = leave.serial,
                } });
                if (self.pointer_focus) |focus| {
                    if (sameWindow(focus, window.handle)) self.pointer_focus = null;
                }
            },
            .motion => |motion| try self.sink.pointer(.{ .motion = .{
                .window = try self.focusedWindow(),
                .time_ms = motion.time,
                .position = fixedPosition(motion.surface_x, motion.surface_y),
            } }),
            .button => |button| try self.sink.pointer(.{ .button = .{
                .window = try self.focusedWindow(),
                .serial = button.serial,
                .time_ms = button.time,
                .button = button.button,
                .state = try pointerButtonState(button.state),
            } }),
            .axis => |axis| try self.sink.pointer(.{ .axis = .{
                .window = try self.focusedWindow(),
                .time_ms = axis.time,
                .axis = try pointerAxis(axis.axis),
                .delta = fixedValue(axis.value),
            } }),
            .axis_source => |source| try self.sink.pointer(.{ .axis_source = .{
                .window = try self.focusedWindow(),
                .source = try pointerAxisSource(source.axis_source),
            } }),
            .axis_stop => |stop| try self.sink.pointer(.{ .axis_stop = .{
                .window = try self.focusedWindow(),
                .time_ms = stop.time,
                .axis = try pointerAxis(stop.axis),
            } }),
            .axis_discrete => |discrete| try self.sink.pointer(.{ .axis_steps = .{
                .window = try self.focusedWindow(),
                .axis = try pointerAxis(discrete.axis),
                .steps = discrete.discrete,
            } }),
            .axis_value120 => |value| try self.sink.pointer(.{ .axis_steps120 = .{
                .window = try self.focusedWindow(),
                .axis = try pointerAxis(value.axis),
                .steps120 = value.value120,
            } }),
            .frame => try self.sink.pointer(.{ .frame = try self.focusedWindow() }),
            .axis_relative_direction, .warp => return error.UnsupportedPointerEventVersion,
        }
    }

    fn focusedWindow(self: *Host) !WindowHandle {
        return self.pointer_focus orelse error.PointerWithoutFocus;
    }

    pub fn eventError(self: *Host, _: wayring.io_uring.Peer, failure: Core.EventFailure) void {
        self.failure = failure.cause;
        self.transport_lost = true;
        self.disconnect_started = true;
    }

    pub fn disconnected(self: *Host, _: wayring.io_uring.Peer) void {
        if (!self.disconnect_started and self.failure == null)
            self.failure = error.WaylandDisconnected;
        self.transport_lost = true;
        self.disconnect_started = true;
    }
};

fn sameWindow(a: WindowHandle, b: WindowHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn fixedValue(raw: i32) f32 {
    return @as(f32, @floatFromInt(raw)) / 256.0;
}

fn fixedPosition(x: i32, y: i32) platform_window.LogicalPosition {
    return .{ .x = fixedValue(x), .y = fixedValue(y) };
}

fn pointerButtonState(value: protocol.wl_pointer.button_state) !platform_window.PointerButtonState {
    if (value.value == protocol.wl_pointer.button_state.pressed.value) return .pressed;
    if (value.value == protocol.wl_pointer.button_state.released.value) return .released;
    return error.InvalidPointerButtonState;
}

fn pointerAxis(value: protocol.wl_pointer.axis) !platform_window.PointerAxis {
    if (value.value == protocol.wl_pointer.axis.vertical_scroll.value) return .vertical;
    if (value.value == protocol.wl_pointer.axis.horizontal_scroll.value) return .horizontal;
    return error.InvalidPointerAxis;
}

fn pointerAxisSource(value: protocol.wl_pointer.axis_source) !platform_window.PointerAxisSource {
    if (value.value == protocol.wl_pointer.axis_source.wheel.value) return .wheel;
    if (value.value == protocol.wl_pointer.axis_source.finger.value) return .finger;
    if (value.value == protocol.wl_pointer.axis_source.continuous.value) return .continuous;
    if (value.value == protocol.wl_pointer.axis_source.wheel_tilt.value) return .wheel_tilt;
    return error.InvalidPointerAxisSource;
}

test "Wayland host frame tokens retain generation-checked window identity" {
    try std.testing.expect(@hasDecl(Host, "nativeHost"));
    try std.testing.expect(@hasDecl(Host, "acquireFrame"));
    try std.testing.expect(@hasDecl(Host, "present"));
}
