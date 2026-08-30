const std = @import("std");
const ourokit = @import("ourokit");

const ToplevelDeclaration = ourokit.app.windows.ToplevelDeclaration;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var frame_limit: ?usize = null;
    var two_windows = false;
    var use_vulkan = false;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            frame_limit = 1;
        } else if (std.mem.startsWith(u8, argument, "--frame-count=")) {
            frame_limit = try std.fmt.parseInt(usize, argument["--frame-count=".len..], 10);
            if (frame_limit.? == 0) return error.InvalidFrameCount;
        } else if (std.mem.eql(u8, argument, "--two-windows")) {
            two_windows = true;
        } else if (std.mem.eql(u8, argument, "--vulkan")) {
            use_vulkan = true;
        } else {
            return error.UnknownArgument;
        }
    }

    var loop: ourokit.loop.Loop = undefined;
    try loop.init(init.gpa, 128, 32);
    defer loop.deinit();

    var scheduler: ourokit.task.Scheduler = undefined;
    try scheduler.init(init.gpa, 8, 1, 0);
    defer scheduler.deinit();

    var vulkan_renderer: ourokit.renderer.vulkan = undefined;
    if (use_vulkan) vulkan_renderer = try ourokit.renderer.vulkan.init(init.gpa);
    defer if (use_vulkan) vulkan_renderer.deinit();

    // The sink stores only this stable address. Host startup performs registry
    // discovery but cannot emit a window event before WindowSet.init below.
    var windows: ourokit.app.windows.WindowSet = undefined;
    var host: ourokit.platform.wayland.Host = undefined;
    try host.init(
        init.gpa,
        &loop,
        init.minimal.environ,
        windows.eventSink(),
        .{
            .app_id = "dev.ourokit.renderer-example",
            .window_capacity = 2,
            .vulkan = if (use_vulkan) &vulkan_renderer else null,
        },
    );
    defer host.deinit();
    if (use_vulkan and host.presentationBackend() != .vulkan_dmabuf)
        std.debug.print("linux-dmabuf unavailable; using shared-memory presentation.\n", .{});
    if (use_vulkan and host.explicitSyncEnabled())
        std.debug.print("linux-drm-syncobj explicit synchronization enabled.\n", .{});
    try windows.init(init.gpa, &scheduler, host.nativeHost(), 2, 16);
    defer windows.deinit();

    const declarations = [_]ToplevelDeclaration{
        .{ .id = "main", .title = if (use_vulkan) "Ourokit Vulkan renderer" else "Ourokit software renderer" },
        .{
            .id = "secondary",
            .title = "Ourokit second window",
            .initial_width = 420,
            .initial_height = 320,
        },
    };
    var desired = [_]bool{ true, two_windows };
    var frames_seen = [_]usize{ 0, 0 };
    var timings_seen = [_]usize{ 0, 0 };
    var timing_stats = [_]TimingStats{.{}} ** declarations.len;
    var disconnect_started = false;

    while (true) {
        var desired_changed = false;
        if (host.failure != null) {
            for (&desired) |*present| {
                if (present.*) desired_changed = true;
                present.* = false;
            }
        }
        while (windows.takeEvent()) |event| switch (event) {
            .close_requested => |handle| {
                for (declarations, 0..) |declaration, index| {
                    const current = windows.handleForId(declaration.id) orelse continue;
                    if (sameWindow(current, handle) and desired[index]) {
                        desired[index] = false;
                        desired_changed = true;
                    }
                }
            },
            .configured => {},
            .pointer => {},
        };

        // Task safe point: close-triggered scope cancellation never executes
        // from Wayring dispatch or from native window reconciliation.
        try scheduler.applyQueuedCancellations();

        var current_storage: [declarations.len]ToplevelDeclaration = undefined;
        var current_count: usize = 0;
        for (declarations, desired) |declaration, present| {
            if (!present) continue;
            current_storage[current_count] = declaration;
            current_count += 1;
        }
        try windows.reconcile(current_storage[0..current_count]);

        for (declarations, desired, 0..) |declaration, present, index| {
            if (!present) continue;
            const handle = windows.handleForId(declaration.id).?;
            frames_seen[index] = @max(frames_seen[index], try host.framesPresented(handle));
            if (try host.takePresentationTiming(handle)) |timing| {
                timings_seen[index] += 1;
                timing_stats[index].add(timing);
            }
            if (frame_limit != null and frames_seen[index] >= frame_limit.?) continue;
            if (try host.acquireFrame(handle)) |acquired| {
                var frame = acquired;
                const theme = ourokit.design.tokens.light;
                const rectangle_width = frame.width / 2;
                const rectangle_height = frame.height / 2;
                const travel = frame.width - rectangle_width;
                const current_x: u32 = @intCast((frames_seen[index] * 13) % @max(travel, 1));
                const previous_x: u32 = if (frames_seen[index] == 0)
                    current_x
                else
                    @intCast(((frames_seen[index] - 1) * 13) % @max(travel, 1));
                const damage_left = @min(current_x, previous_x);
                const damage_right = @max(current_x, previous_x) + rectangle_width;
                const requested_damage = ourokit.scene.Damage{ .regions = &.{.{
                    .x = @intCast(damage_left),
                    .y = @intCast(frame.height / 4),
                    .width = damage_right - damage_left,
                    .height = rectangle_height,
                }} };
                const commands = [_]ourokit.scene.Command{
                    .{ .clear = theme.surface_base },
                    .{ .solid_rectangle = .{
                        .bounds = .{
                            .x = @intCast(current_x),
                            .y = @intCast(frame.height / 4),
                            .width = rectangle_width,
                            .height = rectangle_height,
                        },
                        .color = theme.accent_default,
                    } },
                };
                try host.prepareFrameDamage(&frame, requested_damage);
                const list: ourokit.scene.DisplayList = .{ .commands = &commands, .damage = frame.damage() };
                (switch (frame.target) {
                    .software => |target| ourokit.renderer.software.render(list, .{
                        .pixels = target.pixels,
                        .width = frame.width,
                        .height = frame.height,
                        .stride = target.stride,
                        .format = .bgra8_unorm,
                    }),
                    .vulkan => |target| vulkan_renderer.renderDmabuf(list, target),
                }) catch |err| {
                    try host.discardFrame(frame);
                    return err;
                };
                host.present(frame) catch |err| {
                    try host.discardFrame(frame);
                    return err;
                };
            }
            if (frame_limit) |limit| if (frames_seen[index] < limit)
                try host.requestRedraw(handle);
        }

        if (frame_limit) |limit| {
            var all_presented = true;
            var any_present = false;
            for (desired, frames_seen) |present, count| {
                any_present = any_present or present;
                if (present and count < limit) all_presented = false;
            }
            if (any_present and all_presented) {
                @memset(&desired, false);
                desired_changed = true;
            }
        }

        const serial_before_flush = windows.changeSerial();
        try host.flush();

        // Host maintenance may have completed an unbusy window synchronously.
        // Loop once more to apply its queued cancellation and retire the
        // declaration tombstone before blocking for another CQE.
        if (!disconnect_started and current_count == 0 and windows.retainedCount() == 0) {
            try host.beginDisconnect();
            disconnect_started = true;
            try host.flush();
        }
        if (host.quiescent() and windows.retainedCount() == 0) break;

        if (desired_changed or windows.changeSerial() != serial_before_flush) continue;
        if (host.quiescent()) continue;

        try host.dispatchOne(try loop.wait());
    }

    if (host.failure) |failure| return failure;

    const total_frames = frames_seen[0] + frames_seen[1];
    std.debug.print(
        "Ourokit Wayland example presented {d} frame(s) across {d} window(s), received {d} timing sample(s), and exited cleanly.\n",
        .{ total_frames, @as(usize, if (two_windows) 2 else 1), timings_seen[0] + timings_seen[1] },
    );
    var combined: TimingStats = .{};
    for (timing_stats) |stats| combined.merge(stats);
    if (combined.interval_count != 0) std.debug.print(
        "Presentation intervals: avg {d:.3} ms, min {d:.3} ms, max {d:.3} ms ({d} intervals).\n",
        .{
            @as(f64, @floatFromInt(combined.total_nanoseconds)) / @as(f64, @floatFromInt(combined.interval_count)) / 1_000_000,
            @as(f64, @floatFromInt(combined.minimum_nanoseconds)) / 1_000_000,
            @as(f64, @floatFromInt(combined.maximum_nanoseconds)) / 1_000_000,
            combined.interval_count,
        },
    );
}

const TimingStats = struct {
    previous_nanoseconds: ?u128 = null,
    interval_count: usize = 0,
    total_nanoseconds: u128 = 0,
    minimum_nanoseconds: u64 = std.math.maxInt(u64),
    maximum_nanoseconds: u64 = 0,

    fn add(self: *TimingStats, timing: ourokit.platform.wayland.PresentationTiming) void {
        const timestamp = @as(u128, timing.seconds) * std.time.ns_per_s + timing.nanoseconds;
        if (self.previous_nanoseconds) |previous| if (timestamp > previous and
            timestamp - previous <= std.math.maxInt(u64))
        {
            const interval: u64 = @intCast(timestamp - previous);
            self.interval_count += 1;
            self.total_nanoseconds += interval;
            self.minimum_nanoseconds = @min(self.minimum_nanoseconds, interval);
            self.maximum_nanoseconds = @max(self.maximum_nanoseconds, interval);
        };
        self.previous_nanoseconds = timestamp;
    }

    fn merge(self: *TimingStats, other: TimingStats) void {
        if (other.interval_count == 0) return;
        self.interval_count += other.interval_count;
        self.total_nanoseconds += other.total_nanoseconds;
        self.minimum_nanoseconds = @min(self.minimum_nanoseconds, other.minimum_nanoseconds);
        self.maximum_nanoseconds = @max(self.maximum_nanoseconds, other.maximum_nanoseconds);
    }
};

fn sameWindow(a: ourokit.platform.window.WindowHandle, b: ourokit.platform.window.WindowHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
