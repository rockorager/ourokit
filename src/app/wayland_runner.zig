const std = @import("std");
const bundle = @import("../bundle/root.zig");
const windows_module = @import("windows.zig");
const source_generation = @import("source_generation.zig");
const SourceGeneration = source_generation.SourceGeneration;
const SourceReload = @import("source_reload.zig").SourceReload;
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;
const WindowRuntimeConfig = @import("window_runtime.zig").Config;
const core = @import("../core/root.zig");
const design = @import("../design/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const platform = @import("../platform/root.zig");
const renderer = @import("../renderer/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");

pub const Options = struct {
    exit_after_first_frame: bool = false,
    vulkan: bool = renderer.has_vulkan,
    window: WindowRuntimeConfig = .{},
    platform_event_capacity: usize = 256,
    signal_capacity: usize = 256,
    subscription_capacity: usize = 1024,
    dependency_capacity: usize = 256,
};

/// Runs one declarative Lua application on the production Wayland stack.
/// Applications provide source and policy; this coordinator owns all
/// native services and preserves the explicit event-loop safe points.
pub fn run(init: std.process.Init, source: []const u8, options: Options) !void {
    var provider = try bundle.SourceProvider.initEmbedded(
        init.gpa,
        "application.lua",
        source,
    );
    defer provider.deinit();
    return runSource(init, &provider, options);
}

/// Runs an application from a retained source origin. Disk providers can
/// produce later snapshots without reconstructing or losing the entry path.
pub fn runSource(
    init: std.process.Init,
    provider: *const bundle.SourceProvider,
    options: Options,
) !void {
    var diagnostic: ?lua.Diagnostic = null;
    defer if (diagnostic) |*value| value.deinit();
    var snapshot = provider.snapshot(init.io, init.gpa) catch |err| {
        lua.recordDiagnosticError(
            &diagnostic,
            init.gpa,
            .source,
            provider.entryName(),
            err,
        );
        return err;
    };
    var snapshot_owned = true;
    defer if (snapshot_owned) snapshot.deinit();

    var loop: io_loop.Loop = undefined;
    try loop.init(init.gpa, 128, 32);
    defer loop.deinit();

    var scheduler: task.Scheduler = undefined;
    try scheduler.init(init.gpa, 32, 8, 8);
    defer scheduler.deinit();

    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(init.gpa, options.window.node_capacity);
    defer callbacks.deinit();

    var database = try text.discovery.Database.init();
    defer database.deinit();
    var configured_fonts = try database.candidates(init.gpa, .{
        .family = "sans-serif",
        .language = "en",
        .pixel_size = 14,
    });
    defer configured_fonts.deinit();
    if (configured_fonts.faces.len == 0) return error.ConfiguredSansSerifNotFound;
    var fonts = text.FontCache.init(init.gpa);
    defer fonts.deinit();
    const primary_font = try loadFont(init, &fonts, configured_fonts.faces[0]);
    defer fonts.release(primary_font) catch unreachable;
    var shapes = text.ShapeCache.init(init.gpa, &fonts);
    defer shapes.deinit();
    var glyphs = try renderer.software.GlyphCache.init(init.gpa, &fonts);
    defer glyphs.deinit();
    var vulkan_renderer: renderer.vulkan = undefined;
    if (options.vulkan) vulkan_renderer = try renderer.vulkan.init(init.gpa);
    defer if (options.vulkan) vulkan_renderer.deinit();
    var vulkan_glyphs: renderer.vulkan.GlyphCache = undefined;
    if (options.vulkan) vulkan_glyphs = try renderer.vulkan.GlyphCache.init(init.gpa, &fonts, &vulkan_renderer);
    defer if (options.vulkan) vulkan_glyphs.deinit();

    const theme = design.tokens.light;
    const services: source_generation.UiServices = .{
        .shapes = &shapes,
        .primary_font = primary_font,
        .theme = theme,
        .callbacks = &callbacks,
    };
    const generation_config: source_generation.Config = .{
        .node_capacity = options.window.node_capacity,
        .signal_capacity = options.signal_capacity,
        .subscription_capacity = options.subscription_capacity,
        .dependency_capacity = options.dependency_capacity,
    };
    // SourceGeneration consumes the snapshot on both success and failure.
    snapshot_owned = false;
    const initial_generation = try SourceGeneration.create(
        init.gpa,
        &scheduler,
        &loop,
        snapshot,
        services,
        generation_config,
        &diagnostic,
    );
    var source_reload: SourceReload = undefined;
    source_reload.init(
        init.gpa,
        init.io,
        provider,
        &scheduler,
        &loop,
        services,
        generation_config,
        initial_generation,
    );
    defer source_reload.deinit();
    const generation = source_reload.active();
    const signals = &generation.signals;
    const lua_ui = &generation.ui_build;
    const application = &generation.application;
    const window_count = application.windows.len;

    var window_set: windows_module.WindowSet = undefined;
    var host: platform.wayland.Host = undefined;
    try host.init(
        init.gpa,
        &loop,
        init.minimal.environ,
        window_set.eventSink(),
        .{
            .app_id = application.id,
            .window_capacity = window_count,
            .vulkan = if (options.vulkan) &vulkan_renderer else null,
        },
    );
    defer host.deinit();
    try window_set.init(
        init.gpa,
        &scheduler,
        host.nativeHost(),
        window_count,
        options.platform_event_capacity,
    );
    defer window_set.deinit();

    const runtimes = try init.gpa.alloc(WindowRuntime, window_count);
    defer init.gpa.free(runtimes);
    @memset(runtimes, .{});
    defer for (runtimes) |*runtime| runtime.deinit();
    var dirty: ui.instance.ReconcileQueue = undefined;
    try dirty.init(init.gpa, window_count);
    defer dirty.deinit();
    const configured_sizes = try init.gpa.alloc(?core.SizeU, window_count);
    defer init.gpa.free(configured_sizes);
    @memset(configured_sizes, null);
    const desired = try init.gpa.alloc(bool, window_count);
    defer init.gpa.free(desired);
    @memset(desired, true);
    const frames_seen = try init.gpa.alloc(usize, window_count);
    defer init.gpa.free(frames_seen);
    @memset(frames_seen, 0);
    const current_storage = try init.gpa.alloc(platform.window.ToplevelDeclaration, window_count);
    defer init.gpa.free(current_storage);
    var disconnect_started = false;

    while (true) {
        var desired_changed = false;
        if (host.failure != null) {
            for (desired) |*present| {
                if (present.*) desired_changed = true;
                present.* = false;
            }
        }
        while (window_set.takeEvent()) |event| switch (event) {
            .close_requested => |handle| {
                if (indexForHandle(&window_set, application.windows, handle)) |index| {
                    if (desired[index]) {
                        desired[index] = false;
                        desired_changed = true;
                    }
                }
            },
            .configured => |configured| {
                if (indexForHandle(&window_set, application.windows, configured.window)) |index| {
                    configured_sizes[index] = .{
                        .width = configured.width,
                        .height = configured.height,
                    };
                    if (runtimes[index].registered) _ = try dirty.markDirty(configured.window);
                }
            },
            .pointer => |pointer| {
                if (indexForHandle(&window_set, application.windows, pointerWindow(pointer))) |index|
                    if (runtimes[index].ready) try runtimes[index].routePointer(pointer);
            },
        };

        // Task safe point: platform and CQE dispatch only changed state.
        try scheduler.applyQueuedCancellations();
        for (runtimes) |*runtime| try runtime.collectRetired();
        for (runtimes) |*runtime| if (runtime.ready) try runtime.dispatchInput(&callbacks);
        while (scheduler.takeRunnable()) |handle| _ = try source_reload.resumeRunnable(handle);

        var current_count: usize = 0;
        for (application.windows, desired) |window, present| {
            if (!present) continue;
            current_storage[current_count] = window.declaration;
            current_count += 1;
        }
        try window_set.reconcile(current_storage[0..current_count]);

        for (application.windows, desired, 0..) |window, present, index| {
            if (!present) {
                if (runtimes[index].registered) {
                    try dirty.unregister(runtimes[index].window);
                    runtimes[index].registered = false;
                }
                try runtimes[index].clear(lua_ui);
                continue;
            }
            const handle = window_set.handleForId(window.declaration.id).?;
            if (!runtimes[index].initialized) {
                try runtimes[index].init(
                    init.gpa,
                    &scheduler,
                    try window_set.scope(handle),
                    handle,
                    theme.surface_base,
                    theme.accent_default,
                    theme.surface_base,
                    signals,
                    &shapes,
                    options.window,
                );
                try dirty.register(handle);
                runtimes[index].registered = true;
                runtimes[index].setDirtyWindowQueue(&dirty);
            }
            if (configured_sizes[index] != null and !(try dirty.hasPending(handle)))
                _ = try dirty.markDirty(handle);
        }

        while (dirty.take()) |work| {
            const index = indexForRuntime(runtimes, work.owner) orelse return error.UnknownDirtyWindow;
            const size = configured_sizes[index] orelse
                runtimes[index].frame_state.size orelse return error.DirtyWindowNotConfigured;
            runtimes[index].reconcile(
                size,
                lua_ui,
                application.windows[index].content_reference,
            ) catch |err| {
                try dirty.retry(work);
                return err;
            };
            configured_sizes[index] = null;
            try dirty.complete(work);
        }

        for (runtimes) |*runtime| if (runtime.ready)
            try runtime.prepareFrame(try host.outputScale(runtime.window));

        for (application.windows, desired, 0..) |window, present, index| {
            if (!present) continue;
            const handle = window_set.handleForId(window.declaration.id).?;
            if (runtimes[index].wantsSubmission()) try host.requestRedraw(handle);
        }

        for (application.windows, desired, 0..) |window, present, index| {
            if (!present) continue;
            const handle = window_set.handleForId(window.declaration.id).?;
            if (runtimes[index].wantsSubmission()) if (try host.acquireFrame(handle)) |frame_buffer| {
                const list = try runtimes[index].displayList();
                (switch (frame_buffer.target) {
                    .software => |target| renderer.software.renderText(list, .{
                        .pixels = target.pixels,
                        .width = frame_buffer.width,
                        .height = frame_buffer.height,
                        .stride = target.stride,
                        .format = .bgra8_unorm,
                    }, &glyphs, &shapes),
                    .vulkan => |target| vulkan_renderer.renderDmabufText(list, target, &vulkan_glyphs, &shapes),
                }) catch |err| {
                    try host.discardFrame(frame_buffer);
                    return err;
                };
                try host.present(frame_buffer);
                try runtimes[index].frameSubmitted();
            };
            frames_seen[index] = @max(frames_seen[index], try host.framesPresented(handle));
        }

        if (options.exit_after_first_frame) {
            var all_presented = true;
            var any_present = false;
            for (desired, frames_seen) |present, count| {
                any_present = any_present or present;
                if (present and count == 0) all_presented = false;
            }
            if (any_present and all_presented) {
                @memset(desired, false);
                desired_changed = true;
            }
        }

        const serial_before_flush = window_set.changeSerial();
        try host.flush();
        if (!disconnect_started and current_count == 0 and window_set.retainedCount() == 0) {
            try host.beginDisconnect();
            disconnect_started = true;
            try host.flush();
        }
        if (host.quiescent() and window_set.retainedCount() == 0) break;
        if (desired_changed or window_set.changeSerial() != serial_before_flush) continue;
        if (host.quiescent()) continue;

        const completion = try loop.wait();
        switch (loop.dispatch(completion)) {
            .timeout => |timeout| try source_reload.markTimeoutCompleted(timeout.operation),
            .timeout_cancel => {},
            .foreign => try host.dispatchOne(completion),
            .stale => return error.StaleCompletion,
        }
    }
    if (host.failure) |failure| return failure;
}

fn loadFont(
    init: std.process.Init,
    cache: *text.FontCache,
    face: text.discovery.Face,
) !text.FontHandle {
    const file = try std.Io.Dir.openFileAbsolute(init.io, face.file, .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    const bytes = try reader.interface.allocRemaining(init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(bytes);
    return cache.acquire(.{
        .key = .{ .file = face.file, .index = face.index, .variations = face.variations },
        .bytes = bytes,
    });
}

fn indexForHandle(
    windows: *windows_module.WindowSet,
    declarations: []const lua.ApplicationWindow,
    handle: platform.window.WindowHandle,
) ?usize {
    for (declarations, 0..) |declaration, index| {
        const current = windows.handleForId(declaration.declaration.id) orelse continue;
        if (sameHandle(current, handle)) return index;
    }
    return null;
}

fn indexForRuntime(runtimes: []WindowRuntime, handle: platform.window.WindowHandle) ?usize {
    for (runtimes, 0..) |runtime, index|
        if (runtime.registered and sameHandle(runtime.window, handle)) return index;
    return null;
}

fn pointerWindow(event: platform.window.PointerEvent) platform.window.WindowHandle {
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

fn sameHandle(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
