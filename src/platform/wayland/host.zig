const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayland_protocol");
const build_options = @import("ourokit_build_options");
const OuroLoop = @import("../../loop/io_uring.zig").Loop;
const LoopFileCompletion = @import("../../loop/io_uring.zig").FileCompletion;
const platform_window = @import("../window.zig");
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");
const Adapter = @import("adapter.zig").Adapter;
const Repeat = @import("repeat.zig");
const TextInput = @import("text_input.zig");
const WaylandClipboard = @import("clipboard.zig");
const Xkb = if (build_options.xkbcommon) @import("xkb.zig") else @import("xkb_disabled.zig");
const Vulkan = if (build_options.vulkan)
    @import("../../renderer/vulkan/root.zig")
else
    @import("../../renderer/vulkan/disabled.zig");

const linux = std.os.linux;
const posix = std.posix;
const Handle = wayring.objects.Handle;
const WindowHandle = platform_window.WindowHandle;
const ClipboardRequestHandle = @import("../../core/handle.zig").Handle;
const ScopeHandle = @import("../../task/scheduler.zig").ScopeHandle;
const Core = wayring.client.Core(protocol);
const Connection = wayring.client.Connection(protocol);
const Driver = wayring.client.Driver(protocol);
const Roundtrip = wayring.client.Roundtrip(protocol, *Host);

const buffer_count = 3;
const presentation_feedback_capacity = 8;
const fractional_scale_denominator = 120;

pub const Config = struct {
    app_id: []const u8,
    window_capacity: usize = 8,
    /// Prefer Vulkan linux-dmabuf presentation when compositor feedback and
    /// the selected Vulkan device share a renderable ARGB8888 modifier.
    vulkan: ?*Vulkan = null,
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
        .send_descriptor_capacity = 32,
    },
};

pub const Frame = struct {
    target: union(enum) {
        software: struct {
            pixels: []u8,
            stride: usize,
        },
        vulkan: *Vulkan.DmabufTarget,
    },
    width: u32,
    height: u32,
    window: WindowHandle,
    pool_generation: u32,
    slot: u8,
    damage_regions: [1]RectI = undefined,
    damage_count: u8 = 0,
    requested_damage: DamageSummary = .full,
    damage_prepared: bool = false,

    pub fn damage(self: *const Frame) scene.Damage {
        return if (self.damage_count == 0)
            .{ .regions = &.{} }
        else if (self.damage_regions[0].x == 0 and self.damage_regions[0].y == 0 and
            self.damage_regions[0].width == self.width and self.damage_regions[0].height == self.height)
            .full
        else
            .{ .regions = self.damage_regions[0..self.damage_count] };
    }
};

pub const PresentationBackend = enum { shared_memory, vulkan_dmabuf };

pub const PresentationTiming = struct {
    clock_id: u32,
    seconds: u64,
    nanoseconds: u32,
    refresh_nanoseconds: u32,
    sequence: u64,
    vsync: bool,
    hardware_clock: bool,
    hardware_completion: bool,
    zero_copy: bool,
};

const drm_format_argb8888: u32 = (@as(u32, 'A')) |
    (@as(u32, 'R') << 8) |
    (@as(u32, '2') << 16) |
    (@as(u32, '4') << 24);
const drm_format_modifier_linear: u64 = 0;
const dmabuf_table_entry_size = 16;

const BufferSlot = struct {
    handle: ?Handle = null,
    busy: bool = false,
    acquired: bool = false,
    last_present_serial: u64 = 0,
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

const DmabufSlot = struct {
    handle: ?Handle = null,
    timeline: ?Handle = null,
    target: ?Vulkan.DmabufTarget = null,
    busy: bool = false,
    acquired: bool = false,
    last_present_serial: u64 = 0,
};

pub const DamageSummary = union(enum) {
    none,
    full,
    bounds: RectI,
};

fn summarizeDamage(damage: scene.Damage, frame_bounds: RectI) DamageSummary {
    return switch (damage) {
        .full => .full,
        .regions => |regions| blk: {
            var result: DamageSummary = .none;
            for (regions) |region| {
                const clipped = RectI.intersect(region, frame_bounds);
                if (!clipped.isEmpty()) result = unionDamage(result, .{ .bounds = clipped }, frame_bounds);
            }
            break :blk result;
        },
    };
}

fn unionDamage(a: DamageSummary, b: DamageSummary, frame_bounds: RectI) DamageSummary {
    if (a == .full or b == .full) return .full;
    if (a == .none) return b;
    if (b == .none) return a;
    const a_bounds = a.bounds;
    const b_bounds = b.bounds;
    const left = @min(a_bounds.x, b_bounds.x);
    const top = @min(a_bounds.y, b_bounds.y);
    const right = @max(@as(i64, a_bounds.x) + a_bounds.width, @as(i64, b_bounds.x) + b_bounds.width);
    const bottom = @max(@as(i64, a_bounds.y) + a_bounds.height, @as(i64, b_bounds.y) + b_bounds.height);
    const bounds: RectI = .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
    return if (bounds.x == frame_bounds.x and bounds.y == frame_bounds.y and
        bounds.width == frame_bounds.width and bounds.height == frame_bounds.height)
        .full
    else
        .{ .bounds = bounds };
}

const DamageRecord = struct {
    serial: u64 = 0,
    damage: DamageSummary = .none,
};

const DamageHistory = struct {
    serial: u64 = 0,
    records: [buffer_count]DamageRecord = [_]DamageRecord{.{}} ** buffer_count,

    fn expand(
        self: *const DamageHistory,
        last_present_serial: u64,
        requested: DamageSummary,
        frame_bounds: RectI,
    ) DamageSummary {
        if (requested == .full or last_present_serial == 0 or last_present_serial > self.serial)
            return .full;
        if (self.serial - last_present_serial > self.records.len) return .full;
        var result = requested;
        var serial = last_present_serial + 1;
        while (serial <= self.serial) : (serial += 1) {
            const record = self.records[serial % self.records.len];
            if (record.serial != serial) return .full;
            result = unionDamage(result, record.damage, frame_bounds);
            if (result == .full) return .full;
        }
        return result;
    }

    fn commit(self: *DamageHistory, requested: DamageSummary) u64 {
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        self.records[self.serial % self.records.len] = .{ .serial = self.serial, .damage = requested };
        return self.serial;
    }
};

const DmabufBuffers = struct {
    slots: [buffer_count]DmabufSlot = [_]DmabufSlot{.{}} ** buffer_count,
    width: u32 = 0,
    height: u32 = 0,
    generation: u32 = 0,

    fn matches(self: *const DmabufBuffers, width: u32, height: u32) bool {
        return self.slots[0].target != null and self.width == width and self.height == height;
    }

    fn anyBusy(self: *const DmabufBuffers) bool {
        for (self.slots) |slot| if (slot.busy or slot.acquired or
            (slot.target != null and slot.target.?.gpu_pending)) return true;
        return false;
    }

    fn slotForId(self: *DmabufBuffers, id: u32) ?*DmabufSlot {
        for (&self.slots) |*slot| if (slot.handle != null and slot.handle.?.id == id) return slot;
        return null;
    }

    fn containsId(self: *const DmabufBuffers, id: u32) bool {
        for (self.slots) |slot| if (slot.handle != null and slot.handle.?.id == id) return true;
        return false;
    }

    fn create(
        self: *DmabufBuffers,
        renderer: *Vulkan,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        dmabuf: Handle,
        sync_manager: ?Handle,
        modifier: u64,
        width: u32,
        height: u32,
        generation: u32,
    ) !void {
        std.debug.assert(self.slots[0].target == null);
        if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
            return error.BufferPoolTooLarge;
        var initialized: usize = 0;
        errdefer for (self.slots[0..initialized]) |*slot| {
            if (slot.target) |*target| target.deinit(renderer);
            slot.* = .{};
        };
        for (&self.slots) |*slot| {
            slot.target = try Vulkan.DmabufTarget.init(renderer, width, height, modifier);
            initialized += 1;
            const target = &slot.target.?;
            if (sync_manager) |manager| {
                const fd = try target.exportSyncobjFd(renderer);
                var fd_owned = true;
                errdefer {
                    if (fd_owned) _ = linux.close(fd);
                }
                slot.timeline = (try protocol.wp_linux_drm_syncobj_manager_v1.construct_import_timeline(
                    objects,
                    transmit,
                    manager,
                    .{ .fd = fd },
                )).id;
                fd_owned = false;
            }
            const params = (try protocol.zwp_linux_dmabuf_v1.construct_create_params(
                objects,
                transmit,
                dmabuf,
                .{},
            )).params_id;
            for (target.planes[0..target.plane_count], 0..) |plane, plane_index| {
                const fd = try target.exportFd(renderer);
                var fd_owned = true;
                errdefer {
                    if (fd_owned) _ = linux.close(fd);
                }
                wayring.client.sendRequest(
                    protocol.zwp_linux_buffer_params_v1,
                    objects,
                    transmit,
                    params,
                    .{ .add = .{
                        .fd = fd,
                        .plane_idx = @intCast(plane_index),
                        .offset = plane.offset,
                        .stride = plane.stride,
                        .modifier_hi = @truncate(target.modifier >> 32),
                        .modifier_lo = @truncate(target.modifier),
                    } },
                ) catch |err| {
                    _ = linux.close(fd);
                    fd_owned = false;
                    return err;
                };
                fd_owned = false;
            }
            slot.handle = (try protocol.zwp_linux_buffer_params_v1.construct_create_immed(
                objects,
                transmit,
                params,
                .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .format = drm_format_argb8888,
                    .flags = .fromInt(0),
                },
            )).buffer_id;
            try wayring.client.sendRequest(
                protocol.zwp_linux_buffer_params_v1,
                objects,
                transmit,
                params,
                .{ .destroy = .{} },
            );
        }
        self.width = width;
        self.height = height;
        self.generation = generation;
    }

    fn destroy(
        self: *DmabufBuffers,
        renderer: *Vulkan,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
    ) !void {
        std.debug.assert(!self.anyBusy());
        for (&self.slots) |*slot| {
            if (slot.handle) |handle|
                try wayring.client.sendRequest(protocol.wl_buffer, objects, transmit, handle, .{ .destroy = .{} });
            if (slot.timeline) |timeline|
                try wayring.client.sendRequest(
                    protocol.wp_linux_drm_syncobj_timeline_v1,
                    objects,
                    transmit,
                    timeline,
                    .{ .destroy = .{} },
                );
            if (slot.target) |*target| target.deinit(renderer);
            slot.* = .{};
        }
        const generation = self.generation;
        self.* = .{ .generation = generation };
    }

    fn releaseLocal(self: *DmabufBuffers, renderer: *Vulkan) void {
        for (&self.slots) |*slot| {
            if (slot.target) |*target| target.deinit(renderer);
            slot.* = .{};
        }
    }
};

const WindowState = enum { free, open, closing, surfaces_destroyed, shutdown };

const Window = struct {
    state: WindowState = .free,
    handle: WindowHandle = .invalid,
    scope: ScopeHandle = .invalid,
    surface: ?Handle = null,
    xdg_surface: ?Handle = null,
    toplevel: ?Handle = null,
    viewport: ?Handle = null,
    fractional_scale: ?Handle = null,
    frame_callback: ?Handle = null,
    presentation_feedbacks: [presentation_feedback_capacity]?Handle = [_]?Handle{null} ** presentation_feedback_capacity,
    sync_surface: ?Handle = null,
    last_presentation: ?PresentationTiming = null,
    buffers: ShmBuffers = .{},
    retired_buffers: ShmBuffers = .{},
    dmabuf_buffers: DmabufBuffers = .{},
    retired_dmabuf_buffers: DmabufBuffers = .{},
    width: u32 = 0,
    height: u32 = 0,
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    scale_120: u32 = fractional_scale_denominator,
    configured: bool = false,
    pending_redraw: bool = false,
    frames_presented: usize = 0,
    next_pool_generation: u32 = 1,
    damage_history: DamageHistory = .{},

    fn ownsObject(self: *const Window, object_id: u32) bool {
        return (self.surface != null and self.surface.?.id == object_id) or
            (self.xdg_surface != null and self.xdg_surface.?.id == object_id) or
            (self.toplevel != null and self.toplevel.?.id == object_id) or
            (self.viewport != null and self.viewport.?.id == object_id) or
            (self.fractional_scale != null and self.fractional_scale.?.id == object_id) or
            (self.frame_callback != null and self.frame_callback.?.id == object_id) or
            self.ownsPresentationFeedback(object_id) or
            (self.sync_surface != null and self.sync_surface.?.id == object_id) or
            self.buffers.containsId(object_id) or self.retired_buffers.containsId(object_id) or
            self.dmabuf_buffers.containsId(object_id) or self.retired_dmabuf_buffers.containsId(object_id);
    }

    fn ownsPresentationFeedback(self: *const Window, object_id: u32) bool {
        for (self.presentation_feedbacks) |feedback|
            if (feedback != null and feedback.?.id == object_id) return true;
        return false;
    }

    fn addPresentationFeedback(self: *Window, feedback: Handle) bool {
        for (&self.presentation_feedbacks) |*candidate| if (candidate.* == null) {
            candidate.* = feedback;
            return true;
        };
        return false;
    }

    fn canAddPresentationFeedback(self: *const Window) bool {
        for (self.presentation_feedbacks) |feedback| if (feedback == null) return true;
        return false;
    }

    fn presentationFeedbackFor(self: *Window, object_id: u32) ?*?Handle {
        for (&self.presentation_feedbacks) |*feedback|
            if (feedback.* != null and feedback.*.?.id == object_id) return feedback;
        return null;
    }

    fn hasPresentationFeedback(self: *const Window) bool {
        for (self.presentation_feedbacks) |feedback| if (feedback != null) return true;
        return false;
    }
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    loop: *OuroLoop,
    sink: platform_window.EventSink,
    app_id: []u8,
    vulkan: ?*Vulkan,
    adapter: Adapter,
    connection: Connection,
    driver: Driver,
    registry: Handle,
    compositor: ?Handle = null,
    shm: ?Handle = null,
    dmabuf: ?Handle = null,
    dmabuf_version: u32 = 0,
    dmabuf_feedback: ?Handle = null,
    dmabuf_format_table: ?[]align(std.heap.page_size_min) u8 = null,
    dmabuf_modifier: ?u64 = null,
    dmabuf_tranche_device_matches: bool = false,
    dmabuf_linear_argb8888: bool = false,
    presentation: ?Handle = null,
    presentation_clock_id: ?u32 = null,
    viewporter: ?Handle = null,
    fractional_scale_manager: ?Handle = null,
    sync_manager: ?Handle = null,
    wm_base: ?Handle = null,
    text_input_manager: ?Handle = null,
    text_input_manager_global_name: ?u32 = null,
    text_input: ?Handle = null,
    text_input_active: ?WindowHandle = null,
    text_input_pending: TextInput.Pending,
    clipboard: WaylandClipboard.Clipboard,
    seat: ?Handle = null,
    seat_global_name: ?u32 = null,
    pointer: ?Handle = null,
    pointer_focus: ?WindowHandle = null,
    keyboard: ?Handle = null,
    keyboard_focus: ?WindowHandle = null,
    keyboard_repeat: Repeat.State = .{},
    xkb: Xkb.Keyboard,
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
        self.vulkan = config.vulkan;
        self.windows = windows;
        self.disconnect_started = false;
        self.transport_lost = false;
        self.submission_pending = false;
        self.failure = null;
        self.compositor = null;
        self.shm = null;
        self.dmabuf = null;
        self.dmabuf_version = 0;
        self.dmabuf_feedback = null;
        self.dmabuf_format_table = null;
        self.dmabuf_modifier = null;
        self.dmabuf_tranche_device_matches = false;
        self.dmabuf_linear_argb8888 = false;
        self.presentation = null;
        self.presentation_clock_id = null;
        self.viewporter = null;
        self.fractional_scale_manager = null;
        self.sync_manager = null;
        self.wm_base = null;
        self.text_input_manager = null;
        self.text_input_manager_global_name = null;
        self.text_input = null;
        self.text_input_active = null;
        self.text_input_pending = TextInput.Pending.init(allocator);
        errdefer self.text_input_pending.deinit();
        self.clipboard = try WaylandClipboard.Clipboard.init(allocator, loop, 8, 4, 16, 16, 1024 * 1024);
        errdefer self.clipboard.deinit();
        self.seat = null;
        self.seat_global_name = null;
        self.pointer = null;
        self.pointer_focus = null;
        self.keyboard = null;
        self.keyboard_focus = null;
        self.keyboard_repeat = .{};
        self.xkb = try Xkb.Keyboard.init();
        errdefer self.xkb.deinit();
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
                .transmit_fd_budget = 32,
            },
            .{ .max_objects = 100 + config.window_capacity * 18, .max_client_ids = 80 + config.window_capacity * 18 },
        );
        self.driver = Driver.init(&self.connection);
        self.finishStartup() catch |err| {
            try self.abortStartup();
            self.clipboard.abandonProtocol();
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
        if (self.dmabuf != null) {
            if (self.dmabuf_version >= 4) {
                self.dmabuf_feedback = (try protocol.zwp_linux_dmabuf_v1.construct_get_default_feedback(
                    &self.connection.objects,
                    try self.queue(),
                    self.dmabuf.?,
                    .{},
                )).id;
            }
            var dmabuf_roundtrip = Roundtrip.init(&self.connection, self);
            _ = try dmabuf_roundtrip.begin();
            try self.flush();
            while (!dmabuf_roundtrip.settled()) {
                try self.dispatch(try self.loop.wait(), &dmabuf_roundtrip);
                try self.flushRoundtrip(&dmabuf_roundtrip);
            }
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
        self.releaseDmabufFormatTable();
    }

    pub fn deinit(self: *Host) void {
        std.debug.assert(self.quiescent());
        self.connection.deinit(self.allocator) catch unreachable;
        self.clipboard.abandonProtocol();
        for (self.windows) |*window| {
            std.debug.assert(window.state == .free or window.state == .shutdown);
            if (window.state == .shutdown) self.releaseWindowLocal(window);
        }
        self.releaseDmabufFormatTable();
        self.adapter.deinit(self.allocator);
        self.clipboard.deinit();
        self.text_input_pending.deinit();
        self.xkb.deinit();
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
        try self.releaseClipboardManager();
        if ((try self.connection.actor()).lifecycle == .open and
            try self.connection.prepareClose()) self.submission_pending = true;
        self.disconnect_started = true;
        _ = try self.driver.schedule();
    }

    /// Stops the connection without publishing per-object destructors. This
    /// is the final-application shutdown path: retiring objects locally while
    /// receive dispatch remains active can reject already-in-flight Wayland
    /// events that still name those objects.
    pub fn beginShutdown(self: *Host) !void {
        if (self.disconnect_started) return;
        if ((try self.connection.actor()).lifecycle == .open and
            try self.connection.prepareClose()) self.submission_pending = true;
        self.disconnect_started = true;
        for (self.windows) |*window| {
            if (window.state == .free) continue;
            const handle = window.handle;
            window.state = .shutdown;
            window.pending_redraw = false;
            try self.sink.closed(handle);
        }
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

    pub fn outputScale(self: *Host, handle: WindowHandle) !f32 {
        const scale = (try self.windowFor(handle)).scale_120;
        return @as(f32, @floatFromInt(scale)) / fractional_scale_denominator;
    }

    /// Borrows one persistent presentation slot during frame submission. CPU
    /// access or Vulkan queue submission must finish with `present` or
    /// `discardFrame` before completion dispatch resumes; Vulkan execution may
    /// continue under the slot's GPU/compositor completion gates.
    pub fn acquireFrame(self: *Host, handle: WindowHandle) !?Frame {
        const window = try self.windowFor(handle);
        if (window.state != .open or !window.configured or !window.pending_redraw or
            window.frame_callback != null) return null;
        const pixel_width = try scaledExtent(window.width, window.scale_120);
        const pixel_height = try scaledExtent(window.height, window.scale_120);
        try self.prepareBuffers(window);
        if (self.usingDmabuf()) {
            if (!window.dmabuf_buffers.matches(pixel_width, pixel_height)) return null;
            for (&window.dmabuf_buffers.slots, 0..) |*slot, index| {
                if (slot.busy or slot.acquired) continue;
                if (!try slot.target.?.ready(self.vulkan.?)) continue;
                slot.acquired = true;
                return .{
                    .target = .{ .vulkan = &slot.target.? },
                    .width = pixel_width,
                    .height = pixel_height,
                    .window = handle,
                    .pool_generation = window.dmabuf_buffers.generation,
                    .slot = @intCast(index),
                };
            }
            return null;
        }
        if (!window.buffers.matches(pixel_width, pixel_height)) return null;
        for (&window.buffers.slots, 0..) |*slot, index| {
            if (slot.busy or slot.acquired) continue;
            slot.acquired = true;
            const start = index * window.buffers.slot_size;
            return .{
                .target = .{ .software = .{
                    .pixels = window.buffers.mapping.?[start..][0..window.buffers.slot_size],
                    .stride = window.buffers.stride,
                } },
                .width = pixel_width,
                .height = pixel_height,
                .window = handle,
                .pool_generation = window.buffers.generation,
                .slot = @intCast(index),
            };
        }
        return null;
    }

    /// Expands current scene damage by the changes committed since this slot
    /// was last presented. Render `frame.damage()` rather than the original
    /// damage, while `present` reports only the current change to Wayland.
    pub fn prepareFrameDamage(self: *Host, frame: *Frame, requested: scene.Damage) !void {
        const window = try self.windowFor(frame.window);
        const slot_serial = switch (frame.target) {
            .software => blk: {
                const slot = try self.shmFrameSlot(frame.*);
                if (!slot.acquired) return error.StaleFrame;
                break :blk slot.last_present_serial;
            },
            .vulkan => blk: {
                const slot = try self.dmabufFrameSlot(frame.*);
                if (!slot.acquired) return error.StaleFrame;
                break :blk slot.last_present_serial;
            },
        };
        const bounds: RectI = .{ .x = 0, .y = 0, .width = frame.width, .height = frame.height };
        const current = if (window.damage_history.serial == 0)
            DamageSummary.full
        else
            summarizeDamage(requested, bounds);
        const expanded = window.damage_history.expand(slot_serial, current, bounds);
        frame.requested_damage = current;
        frame.damage_prepared = true;
        switch (expanded) {
            .none => frame.damage_count = 0,
            .full => {
                frame.damage_regions[0] = bounds;
                frame.damage_count = 1;
            },
            .bounds => |region| {
                frame.damage_regions[0] = region;
                frame.damage_count = 1;
            },
        }
    }

    pub fn discardFrame(self: *Host, frame: Frame) !void {
        switch (frame.target) {
            .software => {
                const slot = try self.shmFrameSlot(frame);
                if (!slot.acquired) return error.StaleFrame;
                slot.acquired = false;
            },
            .vulkan => {
                const slot = try self.dmabufFrameSlot(frame);
                if (!slot.acquired) return error.StaleFrame;
                try slot.target.?.wait(self.vulkan.?);
                slot.acquired = false;
            },
        }
    }

    pub fn present(self: *Host, frame: Frame) !void {
        const window = try self.windowFor(frame.window);
        if (window.state != .open) return error.WindowClosing;
        const buffer = switch (frame.target) {
            .software => blk: {
                const slot = try self.shmFrameSlot(frame);
                if (!slot.acquired or slot.busy) return error.StaleFrame;
                break :blk slot.handle.?;
            },
            .vulkan => |target| blk: {
                const slot = try self.dmabufFrameSlot(frame);
                if (!slot.acquired or slot.busy or &slot.target.? != target) return error.StaleFrame;
                break :blk slot.handle.?;
            },
        };
        const transmit = try self.queue();
        const objects = &self.connection.objects;
        switch (frame.target) {
            .software => {},
            .vulkan => {
                const slot = try self.dmabufFrameSlot(frame);
                if (window.sync_surface) |surface_sync| {
                    const timeline = slot.timeline orelse return error.MissingExplicitSyncTimeline;
                    const points = slot.target.?.syncPoints();
                    try wayring.client.sendRequest(
                        protocol.wp_linux_drm_syncobj_surface_v1,
                        objects,
                        transmit,
                        surface_sync,
                        .{ .set_acquire_point = .{
                            .timeline = timeline.id,
                            .point_hi = @truncate(points.acquire >> 32),
                            .point_lo = @truncate(points.acquire),
                        } },
                    );
                    try wayring.client.sendRequest(
                        protocol.wp_linux_drm_syncobj_surface_v1,
                        objects,
                        transmit,
                        surface_sync,
                        .{ .set_release_point = .{
                            .timeline = timeline.id,
                            .point_hi = @truncate(points.release >> 32),
                            .point_lo = @truncate(points.release),
                        } },
                    );
                }
            },
        }
        try wayring.client.sendRequest(
            protocol.wl_surface,
            objects,
            transmit,
            window.surface.?,
            .{ .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 } },
        );
        try self.sendSurfaceDamage(window.surface.?, if (frame.damage_prepared) frame.requested_damage else .full);
        window.frame_callback = (try protocol.wl_surface.construct_frame(
            objects,
            transmit,
            window.surface.?,
            .{},
        )).callback;
        if (self.presentation != null and window.canAddPresentationFeedback()) {
            const feedback = (try protocol.wp_presentation.construct_feedback(
                objects,
                transmit,
                self.presentation.?,
                .{ .surface = window.surface.?.id },
            )).callback;
            std.debug.assert(window.addPresentationFeedback(feedback));
        }
        try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, window.surface.?, .{ .commit = .{} });
        switch (frame.target) {
            .software => {
                const slot = try self.shmFrameSlot(frame);
                slot.acquired = false;
                slot.busy = true;
                slot.last_present_serial = window.damage_history.commit(
                    if (frame.damage_prepared) frame.requested_damage else .full,
                );
            },
            .vulkan => {
                const slot = try self.dmabufFrameSlot(frame);
                slot.acquired = false;
                slot.busy = true;
                slot.last_present_serial = window.damage_history.commit(
                    if (frame.damage_prepared) frame.requested_damage else .full,
                );
            },
        }
        window.pending_redraw = false;
        _ = try self.driver.schedule();
    }

    pub fn framesPresented(self: *Host, handle: WindowHandle) !usize {
        return (try self.windowFor(handle)).frames_presented;
    }

    pub fn takePresentationTiming(self: *Host, handle: WindowHandle) !?PresentationTiming {
        const window = try self.windowFor(handle);
        defer window.last_presentation = null;
        return window.last_presentation;
    }

    pub fn presentationBackend(self: *const Host) PresentationBackend {
        return if (self.usingDmabuf()) .vulkan_dmabuf else .shared_memory;
    }

    pub fn explicitSyncEnabled(self: *const Host) bool {
        return self.usingDmabuf() and self.sync_manager != null;
    }

    /// Activates one retained editable target. Keyboard focus alone never
    /// turns raw key metadata into application text. Calling this for a new
    /// target performs the full disable/enable transaction required by
    /// text-input-v3, including moves within one surface.
    pub fn enableTextInput(self: *Host, handle: WindowHandle, state: platform_window.TextInputState) !void {
        try state.validate();
        _ = try self.windowFor(handle);
        if (self.text_input == null) return error.TextInputProtocolUnavailable;
        if (self.text_input_pending.focused == null or
            !sameWindow(self.text_input_pending.focused.?, handle))
            return error.TextInputSurfaceNotFocused;
        if (self.text_input_active != null) {
            try self.sendTextInputRequest(.{ .disable = .{} });
            try self.commitTextInputState();
        }
        try self.sendTextInputRequest(.{ .enable = .{} });
        try self.sendTextInputState(state);
        try self.commitTextInputState();
        self.text_input_active = handle;
    }

    pub fn textInputAvailable(self: *const Host) bool {
        return self.text_input != null;
    }

    pub fn clipboardAvailable(self: *const Host) bool {
        return self.clipboard.available();
    }

    pub fn setClipboard(self: *Host, serial: u32, text: []const u8) !void {
        try self.clipboard.setSelection(
            &self.connection.objects,
            try self.queue(),
            serial,
            text,
        );
        _ = try self.driver.schedule();
    }

    pub fn requestClipboard(self: *Host, request: ClipboardRequestHandle) !bool {
        const started = try self.clipboard.requestPaste(
            &self.connection.objects,
            try self.queue(),
            request,
        );
        if (!started) return false;
        self.submission_pending = true;
        _ = try self.driver.schedule();
        return true;
    }

    pub fn cancelClipboard(self: *Host, request: ClipboardRequestHandle) !bool {
        const canceled = try self.clipboard.cancel(request);
        if (canceled) self.submission_pending = true;
        return canceled;
    }

    pub fn dispatchClipboardFile(self: *Host, completion: LoopFileCompletion) !bool {
        const handled = try self.clipboard.dispatchFile(completion);
        if (handled) self.submission_pending = true;
        return handled;
    }

    pub fn takeClipboardCompletion(self: *Host) ?WaylandClipboard.Completion {
        return self.clipboard.takeCompletion();
    }

    pub fn releaseClipboardCompletion(self: *Host, request: ClipboardRequestHandle) !void {
        try self.clipboard.releaseCompletion(request);
    }

    pub fn updateTextInput(self: *Host, handle: WindowHandle, state: platform_window.TextInputState) !void {
        try state.validate();
        if (self.text_input_active == null or !sameWindow(self.text_input_active.?, handle))
            return error.TextInputNotActive;
        try self.sendTextInputState(state);
        try self.commitTextInputState();
    }

    pub fn disableTextInput(self: *Host, handle: WindowHandle) !void {
        if (self.text_input_active == null or !sameWindow(self.text_input_active.?, handle)) return;
        try self.sendTextInputRequest(.{ .disable = .{} });
        try self.commitTextInputState();
        self.text_input_active = null;
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

    fn sendSurfaceDamage(self: *Host, surface: Handle, damage: DamageSummary) !void {
        const region = switch (damage) {
            .none => return,
            .full => RectI{
                .x = 0,
                .y = 0,
                .width = std.math.maxInt(i32),
                .height = std.math.maxInt(i32),
            },
            .bounds => |bounds| bounds,
        };
        try wayring.client.sendRequest(
            protocol.wl_surface,
            &self.connection.objects,
            try self.queue(),
            surface,
            .{ .damage_buffer = .{
                .x = region.x,
                .y = region.y,
                .width = @intCast(region.width),
                .height = @intCast(region.height),
            } },
        );
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

    fn shmFrameSlot(self: *Host, frame: Frame) !*BufferSlot {
        const window = try self.windowFor(frame.window);
        if (window.buffers.generation != frame.pool_generation or frame.slot >= buffer_count)
            return error.StaleFrame;
        return &window.buffers.slots[frame.slot];
    }

    fn dmabufFrameSlot(self: *Host, frame: Frame) !*DmabufSlot {
        const window = try self.windowFor(frame.window);
        if (window.dmabuf_buffers.generation != frame.pool_generation or frame.slot >= buffer_count)
            return error.StaleFrame;
        return &window.dmabuf_buffers.slots[frame.slot];
    }

    fn prepareBuffers(self: *Host, window: *Window) !void {
        if (self.usingDmabuf()) return self.prepareDmabufBuffers(window);
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        const pixel_width = try scaledExtent(window.width, window.scale_120);
        const pixel_height = try scaledExtent(window.height, window.scale_120);
        if (window.retired_buffers.mapping != null and !window.retired_buffers.anyBusy())
            try window.retired_buffers.destroy(objects, transmit);
        if (window.buffers.matches(pixel_width, pixel_height)) return;
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
            pixel_width,
            pixel_height,
            window.next_pool_generation,
        );
        _ = try self.driver.schedule();
    }

    fn prepareDmabufBuffers(self: *Host, window: *Window) !void {
        const renderer = self.vulkan.?;
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        const pixel_width = try scaledExtent(window.width, window.scale_120);
        const pixel_height = try scaledExtent(window.height, window.scale_120);
        if (window.retired_dmabuf_buffers.slots[0].target != null and
            !window.retired_dmabuf_buffers.anyBusy())
            try window.retired_dmabuf_buffers.destroy(renderer, objects, transmit);
        if (window.dmabuf_buffers.matches(pixel_width, pixel_height)) return;
        if (window.retired_dmabuf_buffers.slots[0].target != null) return;
        if (window.dmabuf_buffers.slots[0].target != null) {
            if (window.dmabuf_buffers.anyBusy()) {
                window.retired_dmabuf_buffers = window.dmabuf_buffers;
                window.dmabuf_buffers = .{};
            } else {
                try window.dmabuf_buffers.destroy(renderer, objects, transmit);
            }
        }
        window.next_pool_generation +%= 1;
        if (window.next_pool_generation == 0) window.next_pool_generation = 1;
        try window.dmabuf_buffers.create(
            renderer,
            objects,
            transmit,
            self.dmabuf.?,
            self.sync_manager,
            self.selectedDmabufModifier().?,
            pixel_width,
            pixel_height,
            window.next_pool_generation,
        );
        _ = try self.driver.schedule();
    }

    fn usingDmabuf(self: *const Host) bool {
        return self.vulkan != null and self.vulkan.?.supportsDmabuf() and
            self.dmabuf != null and self.selectedDmabufModifier() != null;
    }

    fn selectedDmabufModifier(self: *const Host) ?u64 {
        if (self.dmabuf_version >= 4) return self.dmabuf_modifier;
        return if (self.dmabuf_linear_argb8888 and self.vulkan.?.supportsDmabufModifier(drm_format_modifier_linear))
            drm_format_modifier_linear
        else
            null;
    }

    fn maintainWindows(self: *Host) !void {
        for (self.windows) |*window| {
            if (window.state == .closing and window.frame_callback == null and !window.hasPresentationFeedback())
                try self.destroySurfaces(window);
            if (window.state != .surfaces_destroyed) continue;
            const objects = &self.connection.objects;
            const transmit = try self.queue();
            if (window.buffers.mapping != null and !window.buffers.anyBusy())
                try window.buffers.destroy(objects, transmit);
            if (window.retired_buffers.mapping != null and !window.retired_buffers.anyBusy())
                try window.retired_buffers.destroy(objects, transmit);
            if (self.vulkan) |renderer| {
                if (window.dmabuf_buffers.slots[0].target != null and !window.dmabuf_buffers.anyBusy())
                    try window.dmabuf_buffers.destroy(renderer, objects, transmit);
                if (window.retired_dmabuf_buffers.slots[0].target != null and
                    !window.retired_dmabuf_buffers.anyBusy())
                    try window.retired_dmabuf_buffers.destroy(renderer, objects, transmit);
            }
            if (window.buffers.mapping != null or window.retired_buffers.mapping != null or
                window.dmabuf_buffers.slots[0].target != null or
                window.retired_dmabuf_buffers.slots[0].target != null) continue;
            const handle = window.handle;
            const next_pool_generation = window.next_pool_generation;
            window.* = .{ .next_pool_generation = next_pool_generation };
            try self.sink.closed(handle);
        }
    }

    fn abandonWindows(self: *Host) !void {
        self.releaseDmabufFormatTable();
        self.text_input_active = null;
        self.text_input_pending.resetObject();
        for (self.windows) |*window| {
            if (window.state == .free) continue;
            const closed_reported = window.state == .shutdown;
            const handle = window.handle;
            self.releaseWindowLocal(window);
            if (!closed_reported) try self.sink.closed(handle);
        }
    }

    fn releaseWindowLocal(self: *Host, window: *Window) void {
        window.buffers.releaseLocal();
        window.retired_buffers.releaseLocal();
        if (self.vulkan) |renderer| {
            window.dmabuf_buffers.releaseLocal(renderer);
            window.retired_dmabuf_buffers.releaseLocal(renderer);
        }
        const next_pool_generation = window.next_pool_generation;
        window.* = .{ .next_pool_generation = next_pool_generation };
    }

    fn releaseDmabufFormatTable(self: *Host) void {
        if (self.dmabuf_format_table) |mapping| posix.munmap(mapping);
        self.dmabuf_format_table = null;
    }

    fn destroySurfaces(self: *Host, window: *Window) !void {
        std.debug.assert(window.frame_callback == null);
        if (self.text_input_active) |active|
            if (sameWindow(active, window.handle)) try self.disableTextInput(window.handle);
        _ = self.text_input_pending.leave(window.handle);
        if (self.pointer_focus) |focus| {
            if (sameWindow(focus, window.handle)) self.pointer_focus = null;
        }
        if (self.keyboard_focus) |focus| {
            if (sameWindow(focus, window.handle)) self.keyboard_focus = null;
        }
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        if (window.fractional_scale) |handle|
            try wayring.client.sendRequest(protocol.wp_fractional_scale_v1, objects, transmit, handle, .{ .destroy = .{} });
        if (window.viewport) |handle|
            try wayring.client.sendRequest(protocol.wp_viewport, objects, transmit, handle, .{ .destroy = .{} });
        if (window.toplevel) |handle|
            try wayring.client.sendRequest(protocol.xdg_toplevel, objects, transmit, handle, .{ .destroy = .{} });
        if (window.xdg_surface) |handle|
            try wayring.client.sendRequest(protocol.xdg_surface, objects, transmit, handle, .{ .destroy = .{} });
        if (window.sync_surface) |handle|
            try wayring.client.sendRequest(
                protocol.wp_linux_drm_syncobj_surface_v1,
                objects,
                transmit,
                handle,
                .{ .destroy = .{} },
            );
        if (window.surface) |handle|
            try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, handle, .{ .destroy = .{} });
        window.toplevel = null;
        window.xdg_surface = null;
        window.fractional_scale = null;
        window.viewport = null;
        window.sync_surface = null;
        window.surface = null;
        for (&window.buffers.slots) |*slot| slot.acquired = false;
        for (&window.retired_buffers.slots) |*slot| slot.acquired = false;
        for (&window.dmabuf_buffers.slots) |*slot| slot.acquired = false;
        for (&window.retired_dmabuf_buffers.slots) |*slot| slot.acquired = false;
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
        const viewport = if (self.viewporter) |viewporter|
            (try protocol.wp_viewporter.construct_get_viewport(
                objects,
                transmit,
                viewporter,
                .{ .surface = surface.id },
            )).id
        else
            null;
        const fractional_scale = if (self.fractional_scale_manager != null and viewport != null)
            (try protocol.wp_fractional_scale_manager_v1.construct_get_fractional_scale(
                objects,
                transmit,
                self.fractional_scale_manager.?,
                .{ .surface = surface.id },
            )).id
        else
            null;
        const sync_surface = if (self.sync_manager) |manager|
            (try protocol.wp_linux_drm_syncobj_manager_v1.construct_get_surface(
                objects,
                transmit,
                manager,
                .{ .surface = surface.id },
            )).id
        else
            null;
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
        try setMinimumSize(
            objects,
            transmit,
            toplevel,
            declaration.min_width,
            declaration.min_height,
        );
        if (viewport) |viewport_handle| try setViewport(
            objects,
            transmit,
            viewport_handle,
            declaration.initial_width,
            declaration.initial_height,
            fractional_scale_denominator,
        );
        try wayring.client.sendRequest(protocol.wl_surface, objects, transmit, surface, .{ .commit = .{} });
        window.* = .{
            .state = .open,
            .handle = handle,
            .scope = scope,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .viewport = viewport,
            .fractional_scale = fractional_scale,
            .sync_surface = sync_surface,
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

    fn nativeUpdateMinimumSize(
        context: *anyopaque,
        handle: WindowHandle,
        width: u32,
        height: u32,
    ) !void {
        const self: *Host = @ptrCast(@alignCast(context));
        const window = try self.windowFor(handle);
        if (window.state != .open) return error.WindowClosing;
        const objects = &self.connection.objects;
        const transmit = try self.queue();
        try setMinimumSize(objects, transmit, window.toplevel.?, width, height);
        try wayring.client.sendRequest(
            protocol.wl_surface,
            objects,
            transmit,
            window.surface.?,
            .{ .commit = .{} },
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
        .update_minimum_size = nativeUpdateMinimumSize,
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
                    if (self.clipboard.managerRemoved(removed.name))
                        try self.releaseClipboardManager();
                    if (self.text_input_manager_global_name != null and
                        self.text_input_manager_global_name.? == removed.name)
                        try self.releaseTextInputManager();
                },
            }
        } else if (interface == &protocol.wl_seat.info) {
            switch (try wayring.client.decodeEvent(protocol.wl_seat, objects, self.seat.?, message, fds)) {
                .capabilities => |capabilities| {
                    try self.updatePointerCapability(
                        capabilities.capabilities.contains(protocol.wl_seat.capability.pointer),
                    );
                    try self.updateKeyboardCapability(
                        build_options.xkbcommon and
                            capabilities.capabilities.contains(protocol.wl_seat.capability.keyboard),
                    );
                },
                .name => {},
            }
        } else if (interface == &protocol.wl_pointer.info) {
            try self.pointerEvent(message, fds);
        } else if (interface == &protocol.wl_keyboard.info) {
            try self.keyboardEvent(message, fds);
        } else if (interface == &protocol.wl_data_device.info) {
            try self.clipboard.dataDeviceEvent(objects, try self.queue(), message, fds);
        } else if (interface == &protocol.wl_data_offer.info) {
            try self.clipboard.dataOfferEvent(objects, message, fds);
        } else if (interface == &protocol.wl_data_source.info) {
            try self.clipboard.dataSourceEvent(objects, try self.queue(), message, fds);
            self.submission_pending = true;
        } else if (interface == &protocol.zwp_text_input_v3.info) {
            try self.textInputEvent(message, fds);
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
                    if (window.width != window.pending_width or window.height != window.pending_height)
                        window.damage_history = .{};
                    window.width = window.pending_width;
                    window.height = window.pending_height;
                    if (window.viewport) |viewport| try setViewport(
                        objects,
                        try self.queue(),
                        viewport,
                        window.width,
                        window.height,
                        window.scale_120,
                    );
                    window.configured = true;
                    window.pending_redraw = true;
                    try self.sink.configured(window.handle, window.width, window.height);
                },
            }
        } else if (interface == &protocol.wp_fractional_scale_v1.info) {
            const window = try self.windowForObject(message.header.object_id);
            switch (try wayring.client.decodeEvent(
                protocol.wp_fractional_scale_v1,
                objects,
                window.fractional_scale.?,
                message,
                fds,
            )) {
                .preferred_scale => |preferred| {
                    if (preferred.scale == 0) return error.InvalidFractionalScale;
                    if (window.scale_120 != preferred.scale) {
                        window.scale_120 = preferred.scale;
                        window.damage_history = .{};
                        window.pending_redraw = true;
                        if (window.viewport) |viewport| try setViewport(
                            objects,
                            try self.queue(),
                            viewport,
                            window.width,
                            window.height,
                            window.scale_120,
                        );
                    }
                },
            }
        } else if (interface == &protocol.wl_buffer.info) {
            const window = try self.windowForObject(message.header.object_id);
            if (window.buffers.slotForId(message.header.object_id) orelse
                window.retired_buffers.slotForId(message.header.object_id)) |slot|
            {
                _ = try wayring.client.decodeEvent(protocol.wl_buffer, objects, slot.handle.?, message, fds);
                slot.busy = false;
            } else if (window.dmabuf_buffers.slotForId(message.header.object_id) orelse
                window.retired_dmabuf_buffers.slotForId(message.header.object_id)) |slot|
            {
                _ = try wayring.client.decodeEvent(protocol.wl_buffer, objects, slot.handle.?, message, fds);
                try slot.target.?.wait(self.vulkan.?);
                slot.busy = false;
            } else return error.UnknownBuffer;
        } else if (interface == &protocol.wl_callback.info) {
            const window = try self.windowForObject(message.header.object_id);
            _ = try wayring.client.decodeEvent(protocol.wl_callback, objects, window.frame_callback.?, message, fds);
            window.frame_callback = null;
            window.frames_presented += 1;
        } else if (interface == &protocol.wp_presentation.info) {
            const presentation_event = try wayring.client.decodeEvent(
                protocol.wp_presentation,
                objects,
                self.presentation.?,
                message,
                fds,
            );
            self.presentation_clock_id = presentation_event.clock_id.clk_id;
        } else if (interface == &protocol.wp_presentation_feedback.info) {
            const window = try self.windowForObject(message.header.object_id);
            const feedback = window.presentationFeedbackFor(message.header.object_id) orelse
                return error.UnknownPresentationFeedback;
            switch (try wayring.client.decodeEvent(
                protocol.wp_presentation_feedback,
                objects,
                feedback.*.?,
                message,
                fds,
            )) {
                .sync_output => {},
                .discarded => feedback.* = null,
                .presented => |presented| {
                    const flags = presented.flags;
                    window.last_presentation = .{
                        .clock_id = self.presentation_clock_id orelse 0,
                        .seconds = (@as(u64, presented.tv_sec_hi) << 32) | presented.tv_sec_lo,
                        .nanoseconds = presented.tv_nsec,
                        .refresh_nanoseconds = presented.refresh,
                        .sequence = (@as(u64, presented.seq_hi) << 32) | presented.seq_lo,
                        .vsync = flags.contains(protocol.wp_presentation_feedback.kind.vsync),
                        .hardware_clock = flags.contains(protocol.wp_presentation_feedback.kind.hw_clock),
                        .hardware_completion = flags.contains(protocol.wp_presentation_feedback.kind.hw_completion),
                        .zero_copy = flags.contains(protocol.wp_presentation_feedback.kind.zero_copy),
                    };
                    feedback.* = null;
                },
            }
        } else if (interface == &protocol.wl_shm.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_shm, objects, self.shm.?, message, fds);
        } else if (interface == &protocol.zwp_linux_dmabuf_v1.info) {
            switch (try wayring.client.decodeEvent(protocol.zwp_linux_dmabuf_v1, objects, self.dmabuf.?, message, fds)) {
                .modifier => |modifier| {
                    const value = (@as(u64, modifier.modifier_hi) << 32) | modifier.modifier_lo;
                    if (modifier.format == drm_format_argb8888 and value == drm_format_modifier_linear)
                        self.dmabuf_linear_argb8888 = true;
                },
                .format => {},
            }
        } else if (interface == &protocol.zwp_linux_dmabuf_feedback_v1.info) {
            switch (try wayring.client.decodeEvent(
                protocol.zwp_linux_dmabuf_feedback_v1,
                objects,
                self.dmabuf_feedback.?,
                message,
                fds,
            )) {
                .format_table => |table| {
                    if (self.dmabuf_format_table) |mapping| posix.munmap(mapping);
                    if (table.size == 0 or table.size % dmabuf_table_entry_size != 0) {
                        _ = linux.close(table.fd);
                        return error.InvalidDmabufFormatTable;
                    }
                    self.dmabuf_format_table = posix.mmap(
                        null,
                        table.size,
                        .{ .READ = true },
                        .{ .TYPE = .PRIVATE },
                        table.fd,
                        0,
                    ) catch |err| {
                        _ = linux.close(table.fd);
                        return err;
                    };
                    _ = linux.close(table.fd);
                },
                .main_device => {},
                .tranche_target_device => |tranche| {
                    self.dmabuf_tranche_device_matches = self.vulkan.?.matchesDrmDevice(tranche.device);
                },
                .tranche_formats => |formats| {
                    if (self.dmabuf_modifier == null and self.dmabuf_tranche_device_matches) {
                        const table = self.dmabuf_format_table orelse return error.MissingDmabufFormatTable;
                        if (formats.indices.len % 2 != 0) return error.InvalidDmabufFormatIndices;
                        var offset: usize = 0;
                        while (offset < formats.indices.len) : (offset += 2) {
                            const index = std.mem.readInt(u16, formats.indices[offset..][0..2], .little);
                            const entry_offset = @as(usize, index) * dmabuf_table_entry_size;
                            if (entry_offset + dmabuf_table_entry_size > table.len)
                                return error.InvalidDmabufFormatIndex;
                            const format = std.mem.readInt(u32, table[entry_offset..][0..4], .little);
                            const modifier = std.mem.readInt(u64, table[entry_offset + 8 ..][0..8], .little);
                            if (format == drm_format_argb8888 and self.vulkan.?.supportsDmabufModifier(modifier)) {
                                self.dmabuf_modifier = modifier;
                                break;
                            }
                        }
                    }
                },
                .tranche_flags => {},
                .tranche_done => self.dmabuf_tranche_device_matches = false,
                .done => {
                    if (self.dmabuf_format_table) |mapping| posix.munmap(mapping);
                    self.dmabuf_format_table = null;
                },
            }
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
        } else if (std.mem.eql(u8, global.interface, protocol.wp_presentation.info.name)) {
            self.presentation = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wp_presentation.info,
                @min(global.version, 2),
                null,
            );
        } else if (std.mem.eql(u8, global.interface, protocol.wp_viewporter.info.name)) {
            self.viewporter = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wp_viewporter.info,
                1,
                null,
            );
        } else if (std.mem.eql(u8, global.interface, protocol.wp_fractional_scale_manager_v1.info.name)) {
            self.fractional_scale_manager = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wp_fractional_scale_manager_v1.info,
                1,
                null,
            );
        } else if (self.vulkan != null and
            std.mem.eql(u8, global.interface, protocol.wp_linux_drm_syncobj_manager_v1.info.name))
        {
            self.sync_manager = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wp_linux_drm_syncobj_manager_v1.info,
                1,
                null,
            );
        } else if (self.vulkan != null and self.dmabuf == null and
            std.mem.eql(u8, global.interface, protocol.zwp_linux_dmabuf_v1.info.name))
        {
            const version = @min(global.version, 4);
            self.dmabuf = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.zwp_linux_dmabuf_v1.info,
                version,
                null,
            );
            self.dmabuf_version = version;
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
        } else if (std.mem.eql(u8, global.interface, protocol.zwp_text_input_manager_v3.info.name) and
            self.text_input_manager == null)
        {
            self.text_input_manager = try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.zwp_text_input_manager_v3.info,
                1,
                null,
            );
            self.text_input_manager_global_name = global.name;
            try self.ensureTextInput();
        } else if (std.mem.eql(u8, global.interface, protocol.wl_data_device_manager.info.name) and
            self.clipboard.manager == null)
        {
            self.clipboard.bindManager(try Core.bind(
                objects,
                transmit,
                self.registry,
                global.name,
                &protocol.wl_data_device_manager.info,
                @min(global.version, 3),
                null,
            ), global.name);
            try self.ensureClipboardDevice();
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
            try self.ensureTextInput();
            try self.ensureClipboardDevice();
        }
    }

    fn ensureClipboardDevice(self: *Host) !void {
        if (try self.clipboard.ensureDevice(
            &self.connection.objects,
            try self.queue(),
            self.seat,
        )) _ = try self.driver.schedule();
    }

    fn releaseClipboardManager(self: *Host) !void {
        if (try self.clipboard.releaseManager(
            &self.connection.objects,
            try self.queue(),
        )) _ = try self.driver.schedule();
    }

    fn ensureTextInput(self: *Host) !void {
        if (self.text_input != null or self.text_input_manager == null or self.seat == null) return;
        self.text_input_pending.resetObject();
        self.text_input = (try protocol.zwp_text_input_manager_v3.construct_get_text_input(
            &self.connection.objects,
            try self.queue(),
            self.text_input_manager.?,
            .{ .seat = self.seat.?.id },
        )).id;
        _ = try self.driver.schedule();
    }

    fn releaseTextInput(self: *Host) !void {
        const text_input = self.text_input orelse return;
        try wayring.client.sendRequest(
            protocol.zwp_text_input_v3,
            &self.connection.objects,
            try self.queue(),
            text_input,
            .{ .destroy = .{} },
        );
        self.text_input = null;
        self.text_input_active = null;
        self.text_input_pending.resetObject();
        _ = try self.driver.schedule();
    }

    fn releaseTextInputManager(self: *Host) !void {
        try self.releaseTextInput();
        if (self.text_input_manager) |manager| {
            try wayring.client.sendRequest(
                protocol.zwp_text_input_manager_v3,
                &self.connection.objects,
                try self.queue(),
                manager,
                .{ .destroy = .{} },
            );
            self.text_input_manager = null;
            self.text_input_manager_global_name = null;
            _ = try self.driver.schedule();
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
        try self.releaseTextInput();
        try self.releasePointer();
        try self.releaseKeyboard();
        if (try self.clipboard.releaseDevice(
            &self.connection.objects,
            try self.queue(),
        )) _ = try self.driver.schedule();
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

    fn updateKeyboardCapability(self: *Host, available: bool) !void {
        if (available and self.keyboard == null) {
            self.keyboard = (try protocol.wl_seat.construct_get_keyboard(
                &self.connection.objects,
                try self.queue(),
                self.seat.?,
                .{},
            )).id;
            _ = try self.driver.schedule();
        } else if (!available and self.keyboard != null) {
            try self.releaseKeyboard();
        }
    }

    fn releaseKeyboard(self: *Host) !void {
        const keyboard = self.keyboard orelse return;
        try self.keyboard_repeat.stop(self.loop);
        try wayring.client.sendRequest(
            protocol.wl_keyboard,
            &self.connection.objects,
            try self.queue(),
            keyboard,
            .{ .release = .{} },
        );
        self.keyboard = null;
        self.keyboard_focus = null;
        _ = try self.driver.schedule();
    }

    fn keyboardEvent(
        self: *Host,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const keyboard_event = try wayring.client.decodeEvent(
            protocol.wl_keyboard,
            &self.connection.objects,
            self.keyboard.?,
            message,
            fds,
        );
        switch (keyboard_event) {
            .keymap => |keymap| {
                if (keymap.format.value != protocol.wl_keyboard.keymap_format.xkb_v1.value) {
                    _ = linux.close(keymap.fd);
                    return error.UnsupportedKeymapFormat;
                }
                try self.xkb.installKeymap(keymap.fd, keymap.size);
            },
            .enter => |enter| {
                const window = try self.windowForSurface(enter.surface);
                self.keyboard_focus = window.handle;
                try self.sink.keyboard(.{ .enter = .{
                    .window = window.handle,
                    .serial = enter.serial,
                } });
            },
            .leave => |leave| {
                const window = try self.windowForSurface(leave.surface);
                try self.keyboard_repeat.stop(self.loop);
                try self.sink.keyboard(.{ .leave = .{
                    .window = window.handle,
                    .serial = leave.serial,
                } });
                if (self.keyboard_focus) |focused| {
                    if (sameWindow(focused, window.handle)) self.keyboard_focus = null;
                }
            },
            .key => |key| {
                const window = self.keyboard_focus orelse return error.KeyboardWithoutFocus;
                const state = try keyboardKeyState(key.state);
                try self.sink.keyboard(.{ .key = .{
                    .window = window,
                    .serial = key.serial,
                    .time_ms = key.time,
                    .state = state,
                    .translated = self.xkb.translate(key.key),
                } });
                switch (state) {
                    .pressed => try self.keyboard_repeat.press(
                        self.loop,
                        window,
                        key.serial,
                        key.time,
                        key.key,
                        self.xkb.repeats(key.key),
                    ),
                    .released => try self.keyboard_repeat.release(self.loop, key.key),
                    .repeated => unreachable,
                }
            },
            .modifiers => |modifiers| self.xkb.updateModifiers(
                modifiers.mods_depressed,
                modifiers.mods_latched,
                modifiers.mods_locked,
                modifiers.group,
            ),
            .repeat_info => |info| try self.keyboard_repeat.setInfo(
                self.loop,
                info.rate,
                info.delay,
            ),
        }
    }

    fn textInputEvent(
        self: *Host,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        switch (try wayring.client.decodeEvent(
            protocol.zwp_text_input_v3,
            &self.connection.objects,
            self.text_input.?,
            message,
            fds,
        )) {
            .enter => |enter| {
                const window = try self.windowForSurface(enter.surface);
                self.text_input_active = null;
                self.text_input_pending.enter(window.handle);
                try self.sink.textInput(.{ .enter = window.handle });
            },
            .leave => |leave| {
                const window = try self.windowForSurface(leave.surface);
                self.text_input_active = null;
                if (self.text_input_pending.leave(window.handle))
                    try self.sink.textInput(.{ .leave = window.handle });
            },
            .preedit_string => |preedit| try self.text_input_pending.setPreedit(
                preedit.text,
                preedit.cursor_begin,
                preedit.cursor_end,
            ),
            .commit_string => |commit| try self.text_input_pending.setCommit(commit.text),
            .delete_surrounding_text => |deletion| self.text_input_pending.setDelete(
                deletion.before_length,
                deletion.after_length,
            ),
            .done => |done| try self.text_input_pending.finishDone(done.serial, self.sink),
            else => return error.UnsupportedTextInputEvent,
        }
    }

    fn sendTextInputRequest(self: *Host, request: protocol.zwp_text_input_v3.Request) !void {
        try wayring.client.sendRequest(
            protocol.zwp_text_input_v3,
            &self.connection.objects,
            try self.queue(),
            self.text_input orelse return error.TextInputProtocolUnavailable,
            request,
        );
    }

    fn sendTextInputState(self: *Host, state: platform_window.TextInputState) !void {
        if (state.surrounding) |surrounding| try self.sendTextInputRequest(.{ .set_surrounding_text = .{
            .text = surrounding.text,
            .cursor = @intCast(surrounding.cursor),
            .anchor = @intCast(surrounding.anchor),
        } });
        try self.sendTextInputRequest(.{ .set_text_change_cause = .{
            .cause = if (state.change_cause == .input_method)
                protocol.zwp_text_input_v3.change_cause.input_method
            else
                protocol.zwp_text_input_v3.change_cause.other,
        } });
        try self.sendTextInputRequest(.{ .set_content_type = .{
            .hint = protocol.zwp_text_input_v3.content_hint.fromInt(@as(u16, @bitCast(state.content_hints))),
            .purpose = protocol.zwp_text_input_v3.content_purpose.fromInt(@intFromEnum(state.content_purpose)),
        } });
        if (state.cursor_rectangle) |rectangle| try self.sendTextInputRequest(.{ .set_cursor_rectangle = .{
            .x = rectangle.x,
            .y = rectangle.y,
            .width = rectangle.width,
            .height = rectangle.height,
        } });
    }

    fn commitTextInputState(self: *Host) !void {
        try self.sendTextInputRequest(.{ .commit = .{} });
        self.text_input_pending.noteCommit();
        _ = try self.driver.schedule();
    }

    /// Routes one expired Ouro logical timer. This remains a state-only CQE
    /// transition: the repeated key is queued for the input safe point.
    pub fn dispatchTimer(self: *Host, timer: @import("../../loop/io_uring.zig").OperationHandle) !bool {
        if (!self.keyboard_repeat.owns(timer)) return false;
        const fire = (try self.keyboard_repeat.fired(self.loop, timer)) orelse return false;
        try self.sink.keyboard(.{ .key = .{
            .window = fire.window,
            .serial = fire.serial,
            .time_ms = fire.time_ms,
            .state = .repeated,
            .translated = self.xkb.translate(fire.keycode),
        } });
        return true;
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
            // A frame terminates the preceding logical group. In particular,
            // it can follow leave, after that event has cleared focus.
            .frame => if (self.pointer_focus) |window| try self.sink.pointer(.{ .frame = window }),
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

fn scaledExtent(logical: u32, scale_120: u32) !u32 {
    if (logical == 0 or scale_120 == 0) return error.InvalidScaledExtent;
    const numerator = @as(u64, logical) * scale_120;
    const pixels = (numerator + fractional_scale_denominator - 1) / fractional_scale_denominator;
    if (pixels > std.math.maxInt(u32)) return error.ScaledExtentOverflow;
    return @intCast(pixels);
}

fn setMinimumSize(
    objects: *wayring.objects.ClientObjects,
    transmit: *wayring.tx.Queue,
    toplevel: Handle,
    width: u32,
    height: u32,
) !void {
    if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
        return error.InvalidMinimumWindowSize;
    try wayring.client.sendRequest(protocol.xdg_toplevel, objects, transmit, toplevel, .{
        .set_min_size = .{ .width = @intCast(width), .height = @intCast(height) },
    });
}

fn setViewport(
    objects: *wayring.objects.ClientObjects,
    transmit: *wayring.tx.Queue,
    viewport: Handle,
    width: u32,
    height: u32,
    scale_120: u32,
) !void {
    if (width == 0 or height == 0 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
        return error.InvalidViewportDestination;
    try wayring.client.sendRequest(protocol.wp_viewport, objects, transmit, viewport, .{
        .set_source = .{
            .x = 0,
            .y = 0,
            .width = try scaledSourceExtent(width, scale_120),
            .height = try scaledSourceExtent(height, scale_120),
        },
    });
    try wayring.client.sendRequest(protocol.wp_viewport, objects, transmit, viewport, .{
        .set_destination = .{ .width = @intCast(width), .height = @intCast(height) },
    });
}

fn scaledSourceExtent(logical: u32, scale_120: u32) !i32 {
    if (logical == 0 or scale_120 == 0) return error.InvalidScaledExtent;
    const numerator = @as(u128, logical) * scale_120 * 256;
    const fixed = (numerator + fractional_scale_denominator / 2) / fractional_scale_denominator;
    if (fixed == 0 or fixed > std.math.maxInt(i32)) return error.ScaledExtentOverflow;
    return @intCast(fixed);
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

fn keyboardKeyState(value: protocol.wl_keyboard.key_state) !platform_window.KeyState {
    if (value.value == protocol.wl_keyboard.key_state.released.value) return .released;
    if (value.value == protocol.wl_keyboard.key_state.pressed.value) return .pressed;
    if (value.value == protocol.wl_keyboard.key_state.repeated.value) return .repeated;
    return error.UnknownKeyboardKeyState;
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

test "damage history expands a stale slot and falls back when age is unknown" {
    const bounds: RectI = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    var history: DamageHistory = .{};
    try std.testing.expect(history.expand(0, .{ .bounds = .{ .x = 1, .y = 1, .width = 2, .height = 2 } }, bounds) == .full);

    const first = history.commit(.{ .bounds = .{ .x = 0, .y = 10, .width = 10, .height = 10 } });
    _ = history.commit(.{ .bounds = .{ .x = 20, .y = 10, .width = 10, .height = 10 } });
    const expanded = history.expand(first, .{ .bounds = .{ .x = 40, .y = 10, .width = 10, .height = 10 } }, bounds);
    try std.testing.expectEqual(RectI{ .x = 20, .y = 10, .width = 30, .height = 10 }, expanded.bounds);

    _ = history.commit(.none);
    _ = history.commit(.none);
    _ = history.commit(.none);
    try std.testing.expect(history.expand(first, .none, bounds) == .full);
}

test "fractional scale rounds buffer extents up" {
    try std.testing.expectEqual(@as(u32, 800), try scaledExtent(640, 150));
    try std.testing.expectEqual(@as(u32, 2), try scaledExtent(1, 150));
    try std.testing.expectEqual(@as(u32, 640), try scaledExtent(640, 120));
}

test "fractional viewport source excludes rounded buffer padding" {
    try std.testing.expectEqual(@as(i32, 800 * 256), try scaledSourceExtent(640, 150));
    try std.testing.expectEqual(@as(i32, 320), try scaledSourceExtent(1, 150));
    try std.testing.expectEqual(@as(i32, 640 * 256), try scaledSourceExtent(640, 120));
    try std.testing.expectEqual(@as(i32, 571 * 256 + 64), try scaledSourceExtent(457, 150));
}
