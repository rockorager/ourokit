const std = @import("std");
const clipboard_module = @import("clipboard.zig");
const bundle = @import("../bundle/root.zig");
const windows_module = @import("windows.zig");
const source_generation = @import("source_generation.zig");
const SourceGeneration = source_generation.SourceGeneration;
const source_reload_module = @import("source_reload.zig");
const SourceReload = source_reload_module.SourceReload;
const ReloadRequests = @import("reload_requests.zig").ReloadRequests;
const ControlServer = @import("control_server.zig").ControlServer;
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
    /// Optional process-lifetime control edge. Any thread may call `request`;
    /// this runner consumes and commits requests only at its safe point.
    reload_requests: ?*ReloadRequests = null,
    application_window_capacity: usize = 16,
    window: WindowRuntimeConfig = .{},
    scope_capacity: usize = 1024,
    resource_capacity: usize = 1024,
    clipboard_request_capacity: usize = 16,
    clipboard_action_capacity: usize = 128,
    clipboard_max_text_bytes: usize = 1024 * 1024,
    platform_event_capacity: usize = 256,
    signal_capacity: usize = 256,
    subscription_capacity: usize = 1024,
    dependency_capacity: usize = 256,
};

const TextInputRevision = struct {
    model: u64,
    session: u64,
    scene: u64,
};

const RuntimeSlot = struct {
    id: ?[]u8 = null,
    declared: bool = false,
    next_declared: bool = false,
    desired: bool = false,
    configured_size: ?core.SizeU = null,
    frames_seen: usize = 0,
    runtime: WindowRuntime = .{},
    text_input_enabled: bool = false,
    text_input_surface_focused: bool = false,
    text_input_revision: ?TextInputRevision = null,
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
    if (comptime text.has_fontconfig) return runSourceWithFontconfig(init, provider, options);
    return error.FontconfigDisabled;
}

fn runSourceWithFontconfig(
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
    const module_root = try provider.openModuleRoot(init.io);
    defer if (module_root) |directory| directory.close(init.io);
    var loop: io_loop.Loop = undefined;
    try loop.init(init.gpa, 128, 32);
    defer loop.deinit();

    var scheduler: task.Scheduler = undefined;
    try scheduler.init(init.gpa, options.scope_capacity, 8, options.resource_capacity);
    defer scheduler.deinit();

    var clipboard: clipboard_module.Coordinator = undefined;
    try clipboard.init(
        init.gpa,
        &scheduler,
        options.clipboard_request_capacity,
        options.clipboard_action_capacity,
        options.clipboard_max_text_bytes,
    );
    defer clipboard.deinit();

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
    var configured_medium_fonts = try database.candidates(init.gpa, .{
        .family = "sans-serif",
        .language = "en",
        .pixel_size = 14,
        .weight = .medium,
    });
    defer configured_medium_fonts.deinit();
    if (configured_medium_fonts.faces.len == 0) return error.ConfiguredSansSerifMediumNotFound;
    var fonts = text.FontCache.init(init.gpa);
    defer fonts.deinit();
    const primary_font = try loadFont(init, &fonts, configured_fonts.faces[0]);
    defer fonts.release(primary_font) catch unreachable;
    const medium_font = try loadFont(init, &fonts, configured_medium_fonts.faces[0]);
    defer fonts.release(medium_font) catch unreachable;
    var paragraph_sources = text.ParagraphSourceCache.init(init.gpa, &fonts);
    defer paragraph_sources.deinit();
    var paragraphs = text.ParagraphCache.init(init.gpa, &fonts);
    defer paragraphs.deinit();
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
        .paragraph_sources = &paragraph_sources,
        .paragraphs = &paragraphs,
        .primary_font = primary_font,
        .medium_font = medium_font,
        .theme = theme,
        .callbacks = &callbacks,
    };
    const generation_config: source_generation.Config = .{
        .node_capacity = options.window.node_capacity,
        .semantic_text_capacity = options.window.semantic_text_capacity,
        .signal_capacity = options.signal_capacity,
        .subscription_capacity = options.subscription_capacity,
        .dependency_capacity = options.dependency_capacity,
    };
    // SourceGeneration consumes the snapshot on both success and failure.
    snapshot_owned = false;
    const initial_generation = if (module_root) |directory|
        try SourceGeneration.createBootstrap(
            init.gpa,
            &scheduler,
            &loop,
            snapshot,
            directory.handle,
            services,
            generation_config,
            &diagnostic,
        )
    else
        try SourceGeneration.create(
            init.gpa,
            &scheduler,
            &loop,
            snapshot,
            services,
            generation_config,
            &diagnostic,
        );
    var initial_generation_owned = true;
    errdefer if (initial_generation_owned) initial_generation.destroy();
    if (!initial_generation.application_ready)
        try finishInitialBootstrap(initial_generation, &scheduler, &loop, &diagnostic);
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
    if (module_root) |directory| source_reload.attachModuleRoot(directory.handle);
    initial_generation_owned = false;
    defer source_reload.deinit();
    const application = &source_reload.active().application;
    if (application.windows.len > options.application_window_capacity)
        return error.WindowCapacityExceeded;

    var window_set: windows_module.WindowSet = undefined;
    var host: platform.wayland.Host = undefined;
    try host.init(
        init.gpa,
        &loop,
        init.minimal.environ,
        window_set.eventSink(),
        .{
            .app_id = application.id,
            .window_capacity = options.application_window_capacity,
            .vulkan = if (options.vulkan) &vulkan_renderer else null,
        },
    );
    defer host.deinit();
    try window_set.init(
        init.gpa,
        &scheduler,
        host.nativeHost(),
        options.application_window_capacity,
        options.platform_event_capacity,
    );
    defer window_set.deinit();

    const runtime_slots = try init.gpa.alloc(RuntimeSlot, options.application_window_capacity);
    @memset(runtime_slots, .{});
    defer {
        for (runtime_slots) |*slot| {
            slot.runtime.deinit();
            if (slot.id) |id| init.gpa.free(id);
        }
        init.gpa.free(runtime_slots);
    }
    try syncRuntimeSlots(init.gpa, runtime_slots, application.windows);
    var dirty: ui.instance.ReconcileQueue = undefined;
    try dirty.init(init.gpa, options.application_window_capacity);
    defer dirty.deinit();
    const current_storage = try init.gpa.alloc(
        platform.window.SurfaceDeclaration,
        options.application_window_capacity,
    );
    defer init.gpa.free(current_storage);
    const reload_targets = try init.gpa.alloc(
        source_reload_module.WindowTarget,
        options.application_window_capacity,
    );
    defer init.gpa.free(reload_targets);
    var runtime_reload_requests: ReloadRequests = .{};
    const reload_requests = options.reload_requests orelse &runtime_reload_requests;
    var control: ControlServer = undefined;
    try control.init(
        init.gpa,
        &loop,
        init.minimal.environ,
        provider.applicationId() orelse application.id,
        source_reload.generation,
        reload_requests,
    );
    defer shutdownControl(&control, &loop, &host, &source_reload);
    std.log.info("runtime control socket: {s}", .{control.socketPath()});
    var disconnect_started = false;
    var active_reload_sequence: ?u64 = null;
    var queued_reload_sequence: ?u64 = null;

    while (true) {
        const active_generation = source_reload.active();
        const active_application = &active_generation.application;
        const signals = &active_generation.signals;
        const lua_ui = &active_generation.ui_build;
        var desired_changed = false;
        clipboard.setPlatformAvailable(host.clipboardAvailable());
        while (host.takeClipboardCompletion()) |completion| {
            if (completion.canceled)
                try clipboard.acknowledgeCancellation(completion.request)
            else
                try clipboard.completePaste(completion.request, completion.text);
            try host.releaseClipboardCompletion(completion.request);
        }
        if (host.failure != null) {
            for (runtime_slots) |*slot| {
                if (slot.desired) desired_changed = true;
                slot.desired = false;
            }
        }
        while (window_set.takeEvent()) |event| {
            defer window_set.releaseEvent(event);
            switch (event) {
                .close_requested => |handle| {
                    if (slotForNativeHandle(&window_set, runtime_slots, handle)) |slot| {
                        if (slot.desired) {
                            slot.desired = false;
                            desired_changed = true;
                        }
                    }
                },
                .configured => |configured| {
                    if (slotForNativeHandle(&window_set, runtime_slots, configured.window)) |slot| {
                        slot.configured_size = .{
                            .width = configured.width,
                            .height = configured.height,
                        };
                        if (slot.runtime.registered) _ = try dirty.markDirty(configured.window);
                    }
                },
                .pointer => |pointer| {
                    if (slotForNativeHandle(&window_set, runtime_slots, pointerWindow(pointer))) |slot|
                        if (slot.runtime.ready) try slot.runtime.routePointer(pointer);
                },
                .keyboard => |keyboard| {
                    if (slotForNativeHandle(&window_set, runtime_slots, keyboardWindow(keyboard))) |slot|
                        if (slot.runtime.ready) try slot.runtime.routeKeyboard(keyboard);
                },
                .text_input => |text_input_event| switch (text_input_event) {
                    .enter => |handle| if (slotForNativeHandle(&window_set, runtime_slots, handle)) |slot| {
                        slot.text_input_surface_focused = true;
                        slot.text_input_enabled = false;
                        slot.text_input_revision = null;
                    },
                    .leave => |handle| if (slotForNativeHandle(&window_set, runtime_slots, handle)) |slot| {
                        slot.text_input_surface_focused = false;
                        slot.text_input_enabled = false;
                        slot.text_input_revision = null;
                    },
                    .batch => |batch| {
                        if (slotForNativeHandle(&window_set, runtime_slots, batch.window)) |slot|
                            if (slot.runtime.ready)
                                try slot.runtime.routeTextInput(text_input_event);
                    },
                },
            }
        }

        // Task safe point: platform and CQE dispatch only changed state.
        control.collectClosed();
        try control.serviceRequests();
        try scheduler.applyQueuedCancellations();
        for (runtime_slots) |*slot| try slot.runtime.collectRetired();
        for (runtime_slots) |*slot| if (slot.runtime.ready)
            try slot.runtime.dispatchInput(&callbacks);
        while (clipboard.takeCompletion()) |completion| {
            if (completion.text) |bytes| {
                if (slotForNativeHandle(&window_set, runtime_slots, completion.target.window)) |slot| {
                    if (slot.runtime.ready) {
                        _ = try slot.runtime.applyClipboardPaste(
                            &callbacks,
                            completion.target.text_input,
                            bytes,
                        );
                    }
                }
            }
            try clipboard.releaseCompletion(completion.request);
        }
        try clipboard.collectCanceled();
        while (scheduler.takeRunnable()) |handle| _ = try source_reload.resumeRunnable(handle);

        while (clipboard.takeAction()) |action| {
            defer clipboard.releaseAction(action);
            switch (action) {
                .set_selection => |selection| try host.setClipboard(
                    selection.serial,
                    selection.text,
                ),
                .request_paste => |request| {
                    if (!host.clipboardAvailable() or !(try host.requestClipboard(request.request))) {
                        try clipboard.completePaste(request.request, null);
                        const unavailable = clipboard.takeCompletion().?;
                        try clipboard.releaseCompletion(unavailable.request);
                    }
                },
                .cancel_paste => |request| {
                    if (!(try host.cancelClipboard(request)))
                        try clipboard.acknowledgeCancellation(request);
                },
            }
        }

        var current_count: usize = 0;
        for (active_application.windows) |window| {
            const slot = runtimeSlotForId(runtime_slots, window.declaration.id()).?;
            if (!slot.desired) continue;
            current_storage[current_count] = window.declaration;
            current_count += 1;
        }
        if (!disconnect_started and current_count == 0) {
            try host.beginShutdown();
            try control.beginShutdown();
            disconnect_started = true;
        }
        try window_set.reconcile(current_storage[0..current_count]);

        for (runtime_slots) |*slot| {
            const window = applicationWindowForId(active_application.windows, slot.id orelse continue);
            if (window == null or !slot.desired) {
                if (slot.runtime.registered) {
                    try dirty.unregister(slot.runtime.window);
                    slot.runtime.registered = false;
                }
                try slot.runtime.clear(lua_ui);
                continue;
            }
            const handle = window_set.handleForId(window.?.declaration.id()).?;
            if (!slot.runtime.initialized) {
                try slot.runtime.init(
                    init.gpa,
                    &scheduler,
                    try window_set.scope(handle),
                    handle,
                    theme.background,
                    theme.primary,
                    theme.foreground,
                    theme.input,
                    theme.ring,
                    signals,
                    &paragraph_sources,
                    &paragraphs,
                    options.window,
                );
                try dirty.register(handle);
                slot.runtime.registered = true;
                slot.runtime.setDirtyWindowQueue(&dirty);
                slot.runtime.setClipboardCoordinator(&clipboard);
            }
            if (slot.configured_size != null and !(try dirty.hasPending(handle)))
                _ = try dirty.markDirty(handle);
        }

        while (dirty.take()) |work| {
            const slot = runtimeSlotForHandle(runtime_slots, work.owner) orelse
                return error.UnknownDirtyWindow;
            const window = applicationWindowForId(active_application.windows, slot.id.?) orelse
                return error.UnknownDirtyWindow;
            const size = slot.configured_size orelse
                slot.runtime.frame_state.size orelse return error.DirtyWindowNotConfigured;
            slot.runtime.reconcile(
                size,
                lua_ui,
                window.content_reference,
            ) catch |err| {
                try dirty.retry(work);
                return err;
            };
            slot.configured_size = null;
            try dirty.complete(work);
        }

        if (reload_requests.take()) |sequence| {
            if (active_reload_sequence == null) {
                if (try beginReload(&source_reload, &control, sequence))
                    active_reload_sequence = sequence;
            } else {
                queued_reload_sequence = sequence;
            }
        }
        if (active_reload_sequence) |sequence| {
            if (source_reload.takeCandidateFailure()) |err| {
                try reportReloadFailure(&source_reload, &control, sequence, err);
                active_reload_sequence = null;
            } else if (source_reload.candidateReady()) {
                try servicePreparedReload(
                    &source_reload,
                    runtime_slots,
                    reload_targets,
                    &callbacks,
                    &control,
                    sequence,
                );
                active_reload_sequence = null;
            }
        }
        if (active_reload_sequence == null) if (queued_reload_sequence) |sequence| {
            queued_reload_sequence = null;
            if (try beginReload(&source_reload, &control, sequence))
                active_reload_sequence = sequence;
        };
        control.setReloading(active_reload_sequence != null or queued_reload_sequence != null);
        source_reload.beginRetirement() catch |err|
            std.log.err("could not begin source-generation retirement: {s}", .{@errorName(err)});
        _ = source_reload.collectRetired();

        for (runtime_slots) |*slot| if (slot.runtime.ready)
            try slot.runtime.prepareFrame(try host.outputScale(slot.runtime.window));

        if (host.textInputAvailable()) for (runtime_slots) |*slot| {
            if (!slot.runtime.ready or !slot.text_input_surface_focused) continue;
            const status = try slot.runtime.textInputStatus();
            if (status) |value| {
                const revision: TextInputRevision = .{
                    .model = value.model_revision,
                    .session = value.session_revision,
                    .scene = value.scene_revision,
                };
                if (!slot.text_input_enabled) {
                    try host.enableTextInput(slot.runtime.window, value.state);
                    slot.text_input_enabled = true;
                    slot.text_input_revision = revision;
                } else if (value.commit_permitted and
                    !std.meta.eql(slot.text_input_revision.?, revision))
                {
                    try host.updateTextInput(slot.runtime.window, value.state);
                    slot.text_input_revision = revision;
                }
            } else if (slot.text_input_enabled) {
                try host.disableTextInput(slot.runtime.window);
                slot.text_input_enabled = false;
                slot.text_input_revision = null;
            }
        };

        for (runtime_slots) |*slot| {
            if (!slot.desired or !slot.runtime.initialized) continue;
            if (slot.runtime.wantsSubmission()) try host.requestRedraw(slot.runtime.window);
        }

        for (runtime_slots) |*slot| {
            if (!slot.desired or !slot.runtime.initialized) continue;
            const handle = slot.runtime.window;
            if (slot.runtime.wantsSubmission()) if (try host.acquireFrame(handle)) |frame_buffer| {
                const list = try slot.runtime.displayList();
                (switch (frame_buffer.target) {
                    .software => |target| renderer.software.renderTextResources(list, .{
                        .pixels = target.pixels,
                        .width = frame_buffer.width,
                        .height = frame_buffer.height,
                        .stride = target.stride,
                        .format = .bgra8_unorm,
                    }, &glyphs, null, &paragraphs),
                    .vulkan => |target| vulkan_renderer.renderDmabufTextResources(
                        list,
                        target,
                        &vulkan_glyphs,
                        null,
                        &paragraphs,
                    ),
                }) catch |err| {
                    try host.discardFrame(frame_buffer);
                    return err;
                };
                try host.present(frame_buffer);
                try slot.runtime.frameSubmitted();
            };
            slot.frames_seen = @max(slot.frames_seen, try host.framesPresented(handle));
        }

        if (options.exit_after_first_frame) {
            var all_presented = true;
            var any_present = false;
            for (runtime_slots) |slot| {
                any_present = any_present or slot.desired;
                if (slot.desired and slot.frames_seen == 0) all_presented = false;
            }
            if (any_present and all_presented) {
                for (runtime_slots) |*slot| slot.desired = false;
                desired_changed = true;
            }
        }

        const serial_before_flush = window_set.changeSerial();
        try host.flush();
        if (host.quiescent() and window_set.retainedCount() == 0 and control.quiescent() and
            !loop.hasPendingTimerKernelWork() and !loop.hasPendingOperations()) break;
        if (desired_changed or window_set.changeSerial() != serial_before_flush) continue;
        if (host.quiescent() and control.quiescent() and
            !loop.hasPendingTimerKernelWork() and !loop.hasPendingOperations()) continue;

        const completion = try loop.wait();
        switch (loop.dispatch(completion)) {
            .file => |file| if (!(try host.dispatchClipboardFile(file)))
                try source_reload.markFileCompleted(file),
            .socket => |socket| if (!(try control.dispatch(socket)))
                return error.UnownedIoCompletion,
            .operation_cancel => control.collectClosed(),
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout| {
                if (try host.dispatchTimer(timeout.operation)) continue;
                try source_reload.markTimeoutCompleted(timeout.operation);
            },
            .foreign => try host.dispatchOne(completion),
            .stale => return error.StaleCompletion,
        }
    }
    if (host.failure) |failure| return failure;
}

fn finishInitialBootstrap(
    generation: *SourceGeneration,
    scheduler: *task.Scheduler,
    loop: *io_loop.Loop,
    diagnostic: *?lua.Diagnostic,
) !void {
    while (!generation.application_ready) {
        while (scheduler.takeRunnable()) |runnable|
            _ = generation.resumeRunnable(runnable, diagnostic) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    generation.allocator,
                    .evaluate,
                    generation.snapshot.entry_name,
                    err,
                );
                return err;
            };
        if (generation.application_ready) return;
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| if (!(try generation.dispatchFile(completion)))
                return error.UnownedIoCompletion,
            .operation_cancel => {},
            else => return error.UnexpectedBootstrapCompletion,
        }
    }
}

/// Runs the complete disk-read, candidate-build, and application commit at the
/// reconciliation safe point. Failure is deliberately non-fatal: the active
/// generation and its last good frames remain authoritative.
fn beginReload(
    reload: *SourceReload,
    control: *ControlServer,
    request_sequence: u64,
) !bool {
    reload.prepare() catch |err| {
        try reportReloadFailure(reload, control, request_sequence, err);
        return false;
    };
    control.setReloading(true);
    return true;
}

fn servicePreparedReload(
    reload: *SourceReload,
    slots: []RuntimeSlot,
    target_storage: []source_reload_module.WindowTarget,
    callbacks: *lua.CallbackRegistry,
    control: *ControlServer,
    request_sequence: u64,
) !void {
    var candidate_pending = true;
    defer if (candidate_pending) reload.discard();

    const candidate = reload.candidate.?;
    var target_count: usize = 0;
    for (candidate.application.windows) |window| {
        const slot = runtimeSlotForId(slots, window.declaration.id()) orelse {
            try reportReloadFailure(
                reload,
                control,
                request_sequence,
                error.SourceWindowSetChanged,
            );
            return;
        };
        target_storage[target_count] = .{
            .id = window.declaration.id(),
            .runtime = &slot.runtime,
            .size = slot.configured_size orelse slot.runtime.frame_state.size orelse .{
                .width = 0,
                .height = 0,
            },
        };
        target_count += 1;
    }
    const targets = target_storage[0..target_count];
    reload.prepareApplication(targets) catch |err| {
        try reportReloadFailure(reload, control, request_sequence, err);
        return;
    };
    const committed = reload.commitApplication(targets, callbacks) catch |err| {
        try reportReloadFailure(reload, control, request_sequence, err);
        return;
    };
    candidate_pending = false;
    try control.reloadSucceeded(request_sequence, committed.generation);
    std.log.info(
        "source reload request {d} committed generation {d}",
        .{ request_sequence, committed.generation },
    );
}

fn reportReloadFailure(
    reload: *const SourceReload,
    control: *ControlServer,
    request_sequence: u64,
    err: anyerror,
) !void {
    if (reload.lastDiagnostic()) |diagnostic| {
        std.log.err(
            "source reload request {d} failed in {s} ({s}): {s}",
            .{
                request_sequence,
                @tagName(diagnostic.phase),
                diagnostic.source_name,
                diagnostic.message,
            },
        );
        try control.reloadFailed(request_sequence, diagnostic, err);
    } else {
        std.log.err(
            "source reload request {d} failed: {s}",
            .{ request_sequence, @errorName(err) },
        );
        try control.reloadFailed(request_sequence, null, err);
    }
}

fn shutdownControl(
    control: *ControlServer,
    loop: *io_loop.Loop,
    host: *platform.wayland.Host,
    source_reload: *SourceReload,
) void {
    control.beginShutdown() catch |err|
        std.debug.panic("could not stop runtime control server: {s}", .{@errorName(err)});
    while (!control.quiescent()) {
        _ = loop.submit() catch |err|
            std.debug.panic("could not submit control shutdown: {s}", .{@errorName(err)});
        const completion = loop.wait() catch |err|
            std.debug.panic("could not wait for control shutdown: {s}", .{@errorName(err)});
        switch (loop.dispatch(completion)) {
            .file => |file| source_reload.markFileCompleted(file) catch |err|
                std.debug.panic("could not drain source I/O: {s}", .{@errorName(err)}),
            .socket => |socket| {
                if (!(control.dispatch(socket) catch |err|
                    std.debug.panic("could not drain control I/O: {s}", .{@errorName(err)})))
                    std.debug.panic("unowned socket completion during shutdown", .{});
            },
            .operation_cancel => control.collectClosed(),
            .timer_wakeup, .timer_control => while (loop.takeExpired() catch |err|
                std.debug.panic("could not drain timer: {s}", .{@errorName(err)})) |timeout|
            {
                if (host.dispatchTimer(timeout.operation) catch |err|
                    std.debug.panic("could not drain host timer: {s}", .{@errorName(err)})) continue;
                source_reload.markTimeoutCompleted(timeout.operation) catch |err|
                    std.debug.panic("could not drain source timer: {s}", .{@errorName(err)});
            },
            .foreign => host.dispatchOne(completion) catch |err|
                std.debug.panic("could not drain host I/O: {s}", .{@errorName(err)}),
            .stale => std.debug.panic("stale completion during control shutdown", .{}),
        }
        control.collectClosed();
    }
    control.deinit();
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

fn syncRuntimeSlots(
    allocator: std.mem.Allocator,
    slots: []RuntimeSlot,
    declarations: []const lua.ApplicationWindow,
) !void {
    for (slots) |*slot| slot.next_declared = false;
    for (declarations) |declaration| {
        const id = declaration.declaration.id();
        var slot = runtimeSlotForId(slots, id);
        if (slot == null) {
            for (slots) |*candidate| if (candidate.id == null) {
                const owned_id = try allocator.dupe(u8, id);
                candidate.* = .{ .id = owned_id };
                slot = candidate;
                break;
            };
        }
        const target = slot orelse return error.WindowCapacityExceeded;
        if (!target.declared) {
            target.desired = true;
            target.frames_seen = 0;
        }
        target.next_declared = true;
    }
    for (slots) |*slot| {
        if (slot.declared and !slot.next_declared) slot.desired = false;
        slot.declared = slot.next_declared;
        slot.next_declared = false;
    }
}

fn runtimeSlotForId(slots: []RuntimeSlot, id: []const u8) ?*RuntimeSlot {
    for (slots) |*slot|
        if (slot.id != null and std.mem.eql(u8, slot.id.?, id)) return slot;
    return null;
}

fn applicationWindowForId(
    declarations: []const lua.ApplicationWindow,
    id: []const u8,
) ?*const lua.ApplicationWindow {
    for (declarations) |*declaration|
        if (std.mem.eql(u8, declaration.declaration.id(), id)) return declaration;
    return null;
}

fn slotForNativeHandle(
    windows: *windows_module.WindowSet,
    slots: []RuntimeSlot,
    handle: platform.window.WindowHandle,
) ?*RuntimeSlot {
    for (slots) |*slot| {
        const current = windows.handleForId(slot.id orelse continue) orelse continue;
        if (sameHandle(current, handle)) return slot;
    }
    return null;
}

fn runtimeSlotForHandle(
    slots: []RuntimeSlot,
    handle: platform.window.WindowHandle,
) ?*RuntimeSlot {
    for (slots) |*slot|
        if (slot.runtime.registered and sameHandle(slot.runtime.window, handle)) return slot;
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

fn keyboardWindow(event: platform.window.KeyboardEvent) platform.window.WindowHandle {
    return switch (event) {
        .enter => |value| value.window,
        .leave => |value| value.window,
        .key => |value| value.window,
    };
}

fn sameHandle(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "runtime slots retain window state by ID across declaration changes" {
    var slots = [_]RuntimeSlot{.{}} ** 2;
    defer for (&slots) |*slot| if (slot.id) |id| std.testing.allocator.free(id);
    const initial = [_]lua.ApplicationWindow{
        .{
            .declaration = .{ .toplevel = .{ .id = "main", .title = "Main" } },
            .content_reference = 1,
        },
        .{
            .declaration = .{ .toplevel = .{ .id = "tools", .title = "Tools" } },
            .content_reference = 2,
        },
    };
    try syncRuntimeSlots(std.testing.allocator, &slots, &initial);
    const main = runtimeSlotForId(&slots, "main").?;
    const tools = runtimeSlotForId(&slots, "tools").?;
    main.frames_seen = 4;
    tools.configured_size = .{ .width = 320, .height = 240 };

    const reordered = [_]lua.ApplicationWindow{ initial[1], initial[0] };
    try syncRuntimeSlots(std.testing.allocator, &slots, &reordered);
    try std.testing.expect(runtimeSlotForId(&slots, "main").? == main);
    try std.testing.expect(runtimeSlotForId(&slots, "tools").? == tools);
    try std.testing.expectEqual(@as(usize, 4), main.frames_seen);
    try std.testing.expectEqual(@as(u32, 320), tools.configured_size.?.width);

    try syncRuntimeSlots(std.testing.allocator, &slots, initial[1..]);
    try std.testing.expect(!main.declared and !main.desired);
    try std.testing.expect(tools.declared and tools.desired);
    try syncRuntimeSlots(std.testing.allocator, &slots, &initial);
    try std.testing.expect(main.declared and main.desired);
    try std.testing.expectEqual(@as(usize, 0), main.frames_seen);
}
