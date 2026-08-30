const std = @import("std");
const ourokit = @import("ourokit");
const wayring = @import("wayring");
const protocol = @import("wayland_protocol");

const linux = std.os.linux;
const posix = std.posix;
const Handle = wayring.objects.Handle;
const Core = wayring.client.Core(protocol);
const Connection = wayring.client.Connection(protocol);
const Driver = wayring.client.Driver(protocol);
const Roundtrip = wayring.client.Roundtrip(protocol, *Handler);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var exit_after_first_frame = false;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            exit_after_first_frame = true;
        } else {
            return error.UnknownArgument;
        }
    }

    var loop: ourokit.loop.Loop = undefined;
    try loop.init(init.gpa, 64, 16);
    defer loop.deinit();

    var adapter: ourokit.platform.wayland.Adapter = undefined;
    try adapter.init(init.gpa, &loop, .{
        .buffer_group_id = 1,
        .receive_buffer_size = 16 * 1024,
        .receive_buffer_count = 8,
        .receive_control_capacity = 512,
        .fragment_block_size = 4096,
        .fragment_block_count = 4,
        .transmit_block_size = 4096,
        .transmit_block_count = 8,
        .descriptor_count = 8,
        .send_descriptor_capacity = 2,
    });
    defer adapter.deinit(init.gpa);

    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const socket = try wayring.unix_socket.connectEnvironment(&path_storage, init.minimal.environ);
    var connection = try Connection.attach(
        init.gpa,
        &adapter.reactor,
        socket,
        .{
            .received_fd_budget = 2,
            .transmit_byte_budget = 64 * 1024,
            .transmit_fd_budget = 2,
        },
        .{ .max_objects = 64, .max_client_ids = 48 },
    );

    var handler: Handler = .{
        .connection = &connection,
        .exit_after_first_frame = exit_after_first_frame,
    };
    defer handler.releaseMapping();
    const actor = try connection.actor();
    handler.registry = try Core.getRegistry(&connection.objects, &actor.transmit, null);

    var roundtrip = Roundtrip.init(&connection, &handler);
    _ = try roundtrip.begin();
    var driver = Driver.init(&connection);
    _ = try driver.schedule();
    try submitPrepared(&loop, try driver.prepare(&roundtrip));
    while (!roundtrip.settled()) {
        const completion = try loop.wait();
        if (adapter.route(completion) == null) return error.InvalidCompletion;
        try submitPrepared(&loop, try driver.dispatch(&.{completion}, &roundtrip));
    }
    try handler.requireGlobals();
    try handler.createWindow();
    _ = try driver.schedule();
    try submitPrepared(&loop, try driver.prepare(&handler));

    var close_started = false;
    while (true) {
        const peer_actor = try connection.actor();
        if (close_started and peer_actor.canDeinit()) break;

        const completion = try loop.wait();
        if (adapter.route(completion) == null) return error.InvalidCompletion;
        const progress = try driver.dispatch(&.{completion}, &handler);
        try submitPrepared(&loop, progress);

        // Object destruction is a dispatch safe point: retiring protocol
        // handles inside an event callback could invalidate later events in
        // the same received batch.
        if (handler.shutdown_requested and !handler.protocol_objects_destroyed) {
            try handler.finishShutdown();
            _ = try driver.schedule();
            try submitPrepared(&loop, try driver.prepare(&handler));
        }

        if ((handler.shutdown_ready or handler.failure != null) and !close_started) {
            const current_actor = try connection.actor();
            if (current_actor.transmit.queuedBytes() == 0 and !current_actor.transmit.sendActive()) {
                const close_prepared = try connection.prepareClose();
                close_started = true;
                _ = try driver.schedule();
                const close_progress = try driver.prepare(&handler);
                if (close_prepared or close_progress.prepared != 0 or close_progress.pending)
                    _ = try loop.submit();
            }
        }
    }

    try connection.deinit(init.gpa);
    if (handler.failure) |failure| return failure;
    std.debug.print("Ourokit Wayland example presented {d} frame(s) and exited cleanly.\n", .{handler.frames_presented});
}

fn submitPrepared(loop: *ourokit.loop.Loop, progress: Driver.Progress) !void {
    if (progress.prepared != 0 or progress.pending) _ = try loop.submit();
}

const Handler = struct {
    connection: *Connection,
    registry: Handle = undefined,
    compositor: ?Handle = null,
    shm: ?Handle = null,
    wm_base: ?Handle = null,
    surface: ?Handle = null,
    xdg_surface: ?Handle = null,
    toplevel: ?Handle = null,
    frame_callback: ?Handle = null,
    buffer: ?Handle = null,
    mapping: ?[]align(std.heap.page_size_min) u8 = null,
    width: i32 = 640,
    height: i32 = 480,
    pending_redraw: bool = false,
    configured: bool = false,
    exit_after_first_frame: bool,
    shutdown_requested: bool = false,
    shutdown_ready: bool = false,
    protocol_objects_destroyed: bool = false,
    frames_presented: usize = 0,
    failure: ?anyerror = null,

    fn queue(handler: *Handler) !*wayring.tx.Queue {
        return &(try handler.connection.actor()).transmit;
    }

    fn requireGlobals(handler: *const Handler) !void {
        if (handler.compositor == null or handler.shm == null or handler.wm_base == null)
            return error.RequiredWaylandGlobalMissing;
    }

    fn createWindow(handler: *Handler) !void {
        const transmit = try handler.queue();
        const objects = &handler.connection.objects;
        handler.surface = (try protocol.wl_compositor.construct_create_surface(
            objects,
            transmit,
            handler.compositor.?,
            .{},
        )).id;
        handler.xdg_surface = (try protocol.xdg_wm_base.construct_get_xdg_surface(
            objects,
            transmit,
            handler.wm_base.?,
            .{ .surface = handler.surface.?.id },
        )).id;
        handler.toplevel = (try protocol.xdg_surface.construct_get_toplevel(
            objects,
            transmit,
            handler.xdg_surface.?,
            .{},
        )).id;
        try wayring.client.sendRequest(
            protocol.xdg_toplevel,
            objects,
            transmit,
            handler.toplevel.?,
            .{ .set_title = .{ .title = "Ourokit software renderer" } },
        );
        try wayring.client.sendRequest(
            protocol.wl_surface,
            objects,
            transmit,
            handler.surface.?,
            .{ .commit = .{} },
        );
    }

    pub fn event(
        handler: *Handler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const objects = &handler.connection.objects;
        const interface = target.object.interface;
        if (interface == &protocol.wl_display.info) {
            _ = try Core.decodeDisplayEvent(objects, message, fds);
        } else if (interface == &protocol.wl_registry.info) {
            switch (try Core.decodeRegistryEvent(objects, handler.registry, message, fds)) {
                .global => |global| try handler.bindGlobal(global),
                .global_remove => {},
            }
        } else if (interface == &protocol.xdg_wm_base.info) {
            switch (try wayring.client.decodeEvent(protocol.xdg_wm_base, objects, handler.wm_base.?, message, fds)) {
                .ping => |ping| try wayring.client.sendRequest(
                    protocol.xdg_wm_base,
                    objects,
                    try handler.queue(),
                    handler.wm_base.?,
                    .{ .pong = .{ .serial = ping.serial } },
                ),
            }
        } else if (interface == &protocol.xdg_toplevel.info) {
            switch (try wayring.client.decodeEvent(protocol.xdg_toplevel, objects, handler.toplevel.?, message, fds)) {
                .configure => |configure| {
                    if (configure.width > 0) handler.width = configure.width;
                    if (configure.height > 0) handler.height = configure.height;
                    handler.pending_redraw = true;
                },
                .close => handler.requestShutdown(),
                else => {},
            }
        } else if (interface == &protocol.xdg_surface.info) {
            switch (try wayring.client.decodeEvent(protocol.xdg_surface, objects, handler.xdg_surface.?, message, fds)) {
                .configure => |configure| {
                    try wayring.client.sendRequest(
                        protocol.xdg_surface,
                        objects,
                        try handler.queue(),
                        handler.xdg_surface.?,
                        .{ .ack_configure = .{ .serial = configure.serial } },
                    );
                    handler.configured = true;
                    handler.pending_redraw = true;
                    if (handler.buffer == null) try handler.renderFrame();
                },
            }
        } else if (interface == &protocol.wl_buffer.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_buffer, objects, handler.buffer.?, message, fds);
            try wayring.client.sendRequest(
                protocol.wl_buffer,
                objects,
                try handler.queue(),
                handler.buffer.?,
                .{ .destroy = .{} },
            );
            handler.buffer = null;
            handler.releaseMapping();
            if (!handler.shutdown_requested and handler.pending_redraw) {
                try handler.renderFrame();
            }
        } else if (interface == &protocol.wl_callback.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_callback, objects, handler.frame_callback.?, message, fds);
            handler.frame_callback = null;
            handler.frames_presented += 1;
            if (handler.exit_after_first_frame) handler.requestShutdown();
        } else if (interface == &protocol.wl_shm.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_shm, objects, handler.shm.?, message, fds);
        } else if (interface == &protocol.wl_surface.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_surface, objects, handler.surface.?, message, fds);
        }
        return .continue_dispatch;
    }

    fn bindGlobal(handler: *Handler, global: protocol.wl_registry.Event_global) !void {
        const objects = &handler.connection.objects;
        const transmit = try handler.queue();
        if (std.mem.eql(u8, global.interface, protocol.wl_compositor.info.name)) {
            handler.compositor = try Core.bind(
                objects,
                transmit,
                handler.registry,
                global.name,
                &protocol.wl_compositor.info,
                @min(global.version, 4),
                null,
            );
        } else if (std.mem.eql(u8, global.interface, protocol.wl_shm.info.name)) {
            handler.shm = try Core.bind(
                objects,
                transmit,
                handler.registry,
                global.name,
                &protocol.wl_shm.info,
                1,
                null,
            );
        } else if (std.mem.eql(u8, global.interface, protocol.xdg_wm_base.info.name)) {
            handler.wm_base = try Core.bind(
                objects,
                transmit,
                handler.registry,
                global.name,
                &protocol.xdg_wm_base.info,
                @min(global.version, 5),
                null,
            );
        }
    }

    fn renderFrame(handler: *Handler) !void {
        if (!handler.configured or handler.buffer != null or handler.width <= 0 or handler.height <= 0)
            return;
        const width: u32 = @intCast(handler.width);
        const height: u32 = @intCast(handler.height);
        const stride = try std.math.mul(usize, width, 4);
        const size = try std.math.mul(usize, stride, height);
        if (size > std.math.maxInt(i32)) return error.BufferTooLarge;

        const fd = try posix.memfd_create("ourokit-wayland", linux.MFD.CLOEXEC);
        var fd_owned = true;
        errdefer {
            if (fd_owned) _ = linux.close(fd);
        }
        if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS)
            return error.TruncateFailed;
        const mapping = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer posix.munmap(mapping);

        const theme = ourokit.design.tokens.light;
        const commands = [_]ourokit.scene.Command{
            .{ .clear = theme.surface_base },
            .{ .solid_rectangle = .{
                .bounds = .{
                    .x = @intCast(width / 4),
                    .y = @intCast(height / 4),
                    .width = width / 2,
                    .height = height / 2,
                },
                .color = theme.accent_default,
            } },
        };
        try ourokit.renderer.software.render(.{ .commands = &commands }, .{
            .pixels = mapping,
            .width = width,
            .height = height,
            .stride = stride,
            .format = .bgra8_unorm,
        });

        const objects = &handler.connection.objects;
        const transmit = try handler.queue();
        const pool = (try protocol.wl_shm.construct_create_pool(
            objects,
            transmit,
            handler.shm.?,
            .{ .fd = fd, .size = @intCast(size) },
        )).id;
        fd_owned = false;
        const buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            objects,
            transmit,
            pool,
            .{
                .offset = 0,
                .width = handler.width,
                .height = handler.height,
                .stride = @intCast(stride),
                .format = protocol.wl_shm.format.argb8888,
            },
        )).id;
        try wayring.client.sendRequest(protocol.wl_shm_pool, objects, transmit, pool, .{ .destroy = .{} });
        try wayring.client.sendRequest(
            protocol.wl_surface,
            objects,
            transmit,
            handler.surface.?,
            .{ .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 } },
        );
        try wayring.client.sendRequest(
            protocol.wl_surface,
            objects,
            transmit,
            handler.surface.?,
            .{ .damage = .{ .x = 0, .y = 0, .width = handler.width, .height = handler.height } },
        );
        handler.frame_callback = (try protocol.wl_surface.construct_frame(
            objects,
            transmit,
            handler.surface.?,
            .{},
        )).callback;
        try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, handler.surface.?, .{ .commit = .{} });
        handler.mapping = mapping;
        handler.buffer = buffer;
        handler.pending_redraw = false;
    }

    fn requestShutdown(handler: *Handler) void {
        handler.shutdown_requested = true;
    }

    fn finishShutdown(handler: *Handler) !void {
        if (handler.protocol_objects_destroyed) return;
        const objects = &handler.connection.objects;
        const transmit = try handler.queue();
        if (handler.toplevel) |handle|
            try wayring.client.sendRequest(protocol.xdg_toplevel, objects, transmit, handle, .{ .destroy = .{} });
        if (handler.xdg_surface) |handle|
            try wayring.client.sendRequest(protocol.xdg_surface, objects, transmit, handle, .{ .destroy = .{} });
        if (handler.surface) |handle|
            try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, handle, .{ .destroy = .{} });
        if (handler.wm_base) |handle|
            try wayring.client.sendRequest(protocol.xdg_wm_base, objects, transmit, handle, .{ .destroy = .{} });
        handler.protocol_objects_destroyed = true;
        handler.shutdown_ready = true;
    }

    fn releaseMapping(handler: *Handler) void {
        if (handler.mapping) |mapping| posix.munmap(mapping);
        handler.mapping = null;
    }

    pub fn eventError(
        handler: *Handler,
        _: wayring.io_uring.Peer,
        failure: Core.EventFailure,
    ) void {
        handler.failure = failure.cause;
    }

    pub fn disconnected(_: *Handler, _: wayring.io_uring.Peer) void {}
};
