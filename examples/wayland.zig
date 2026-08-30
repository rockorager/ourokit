const std = @import("std");
const ourokit = @import("ourokit");

const ToplevelDeclaration = ourokit.app.windows.ToplevelDeclaration;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var exit_after_first_frame = false;
    var two_windows = false;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            exit_after_first_frame = true;
        } else if (std.mem.eql(u8, argument, "--two-windows")) {
            two_windows = true;
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

    // The sink stores only this stable address. Host startup performs registry
    // discovery but cannot emit a window event before WindowSet.init below.
    var windows: ourokit.app.windows.WindowSet = undefined;
    var host: ourokit.platform.wayland.Host = undefined;
    try host.init(
        init.gpa,
        &loop,
        init.minimal.environ,
        windows.eventSink(),
        .{ .app_id = "dev.ourokit.renderer-example", .window_capacity = 2 },
    );
    defer host.deinit();
    try windows.init(init.gpa, &scheduler, host.nativeHost(), 2, 16);
    defer windows.deinit();

    const declarations = [_]ToplevelDeclaration{
        .{ .id = "main", .title = "Ourokit software renderer" },
        .{
            .id = "secondary",
            .title = "Ourokit second window",
            .initial_width = 420,
            .initial_height = 320,
        },
    };
    var desired = [_]bool{ true, two_windows };
    var frames_seen = [_]usize{ 0, 0 };
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
            if (try host.acquireFrame(handle)) |frame| {
                const theme = ourokit.design.tokens.light;
                const commands = [_]ourokit.scene.Command{
                    .{ .clear = theme.surface_base },
                    .{ .solid_rectangle = .{
                        .bounds = .{
                            .x = @intCast(frame.width / 4),
                            .y = @intCast(frame.height / 4),
                            .width = frame.width / 2,
                            .height = frame.height / 2,
                        },
                        .color = theme.accent_default,
                    } },
                };
                ourokit.renderer.software.render(.{ .commands = &commands }, .{
                    .pixels = frame.pixels,
                    .width = frame.width,
                    .height = frame.height,
                    .stride = frame.stride,
                    .format = .bgra8_unorm,
                }) catch |err| {
                    try host.discardFrame(frame);
                    return err;
                };
                try host.present(frame);
            }
            frames_seen[index] = @max(frames_seen[index], try host.framesPresented(handle));
        }

        if (exit_after_first_frame) {
            var all_presented = true;
            var any_present = false;
            for (desired, frames_seen) |present, count| {
                any_present = any_present or present;
                if (present and count == 0) all_presented = false;
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
        "Ourokit Wayland example presented {d} frame(s) across {d} window(s) and exited cleanly.\n",
        .{ total_frames, @as(usize, if (two_windows) 2 else 1) },
    );
}

fn sameWindow(a: ourokit.platform.window.WindowHandle, b: ourokit.platform.window.WindowHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
