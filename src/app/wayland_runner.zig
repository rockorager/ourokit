const std = @import("std");
const clipboard_module = @import("clipboard.zig");
const appearance_module = @import("appearance.zig");
const bundle = @import("../bundle/root.zig");
const windows_module = @import("windows.zig");
const source_generation = @import("source_generation.zig");
const SourceGeneration = source_generation.SourceGeneration;
const source_reload_module = @import("source_reload.zig");
const SourceReload = source_reload_module.SourceReload;
const ReloadRequests = @import("reload_requests.zig").ReloadRequests;
const ControlServer = @import("control_server.zig").ControlServer;
const socket_activation = @import("socket_activation.zig");
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;
const WindowRuntimeConfig = @import("window_runtime.zig").Config;
const core = @import("../core/root.zig");
const design = @import("../design/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const platform = @import("../platform/root.zig");
const renderer = @import("../renderer/root.zig");
const shell = @import("../shell/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");

pub const Options = struct {
    exit_after_first_frame: bool = false,
    /// Receives the Lua-requested exit status after all resources are drained.
    exit_code: ?*u8 = null,
    vulkan: bool = renderer.has_vulkan,
    /// Borrowed directory capability for embedded-source hosts such as Storybook.
    /// Disk applications otherwise use their source module root.
    asset_root: ?std.os.linux.fd_t = null,
    /// Optional process-lifetime control edge. Any thread may call `request`;
    /// this runner consumes and commits requests only at its safe point.
    reload_requests: ?*ReloadRequests = null,
    /// Optional host-owned appearance state. When supplied, ourosettings is
    /// not connected. Mutate on the owning event-loop thread, then wake it.
    appearance: ?*appearance_module.Store = null,
    application_window_capacity: usize = 16,
    output_capacity: usize = 16,
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
    workspace_capacity: usize = 32,
    workspace_action_capacity: usize = 32,
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
    if (comptime text.has_fontconfig) {
        return runSourceWithFontconfig(init, provider, options) catch |err| {
            if (err != error.ApplicationInterrupted) return err;
        };
    }
    return error.FontconfigDisabled;
}

/// Evaluates only the declaration for packaging. No listener, appearance
/// connection, renderer, or UI factory is started. Declaration output goes to
/// stderr so the caller can reserve stdout for the exported JSON descriptor.
pub fn exportCatalog(init: std.process.Init, provider: *const bundle.SourceProvider) ![]u8 {
    var diagnostic: ?lua.Diagnostic = null;
    defer if (diagnostic) |*value| value.deinit();
    const module_root = try provider.openModuleRoot(init.io);
    defer if (module_root) |directory| directory.close(init.io);
    var loop: io_loop.Loop = undefined;
    try loop.init(init.gpa, 128, 32);
    defer loop.deinit();
    try loop.watchSignals(&.{ .INT, .TERM });
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(init.gpa, 1024, 8, 1024);
    defer scheduler.deinit();
    const input = try std.Io.Dir.openFileAbsolute(init.io, "/dev/null", .{});
    defer input.close(init.io);
    const snapshot = try provider.snapshot(init.io, init.gpa);
    // SourceGeneration consumes the snapshot, including on setup failure.
    const config: source_generation.Config = .{
        .defer_run = true,
        .runtime_dir = std.process.Environ.getPosix(init.minimal.environ, "XDG_RUNTIME_DIR"),
    };
    const generation = if (module_root) |directory|
        try SourceGeneration.createBootstrap(init.gpa, &scheduler, &loop, snapshot, directory.handle, null, config, &diagnostic)
    else
        try SourceGeneration.create(init.gpa, &scheduler, &loop, snapshot, null, config, &diagnostic);
    defer {
        drainInitialGeneration(generation, &scheduler, &loop) catch |err|
            std.debug.panic("could not drain catalog export: {s}", .{@errorName(err)});
        generation.destroy();
    }
    generation.stdio.files = .{ .stdin = input.handle, .stdout = 2, .stderr = 2 };
    try finishInitialBootstrap(generation, &scheduler, &loop, &diagnostic);
    if (generation.vm.exit_code != null or !generation.application_ready) return error.ApplicationCatalogUnavailable;
    if (!generation.application.hasActions()) return error.ApplicationActionsDisabled;
    return @import("catalog.zig").descriptor(init.gpa, &generation.application);
}

fn runSourceWithFontconfig(
    init: std.process.Init,
    provider: *const bundle.SourceProvider,
    options: Options,
) anyerror!void {
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
    // Renderer and image threads created below inherit the blocked signals.
    try loop.watchSignals(&.{ .INT, .TERM });
    defer if (loop.receivedSignal() catch null) |signal| {
        if (options.exit_code) |code| code.* = @intCast(128 + @intFromEnum(signal));
    };

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

    var workspaces: shell.workspaces.Store = undefined;
    try workspaces.init(
        init.gpa,
        options.workspace_capacity,
        options.workspace_action_capacity,
    );
    defer workspaces.deinit();

    var applications = try @import("../xdg/applications.zig").Config.init(init.gpa, init.minimal.environ);
    defer applications.deinit();
    const generation_config: source_generation.Config = .{
        .node_capacity = options.window.node_capacity,
        .window_capacity = options.application_window_capacity,
        .semantic_text_capacity = options.window.semantic_text_capacity,
        .signal_capacity = options.signal_capacity,
        .subscription_capacity = options.subscription_capacity,
        .dependency_capacity = options.dependency_capacity,
        .runtime_dir = std.process.Environ.getPosix(init.minimal.environ, "XDG_RUNTIME_DIR"),
        .applications = &applications,
        .defer_run = true,
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
            null,
            generation_config,
            &diagnostic,
        )
    else
        try SourceGeneration.create(
            init.gpa,
            &scheduler,
            &loop,
            snapshot,
            null,
            generation_config,
            &diagnostic,
        );
    if (options.asset_root) |root| initial_generation.asset_root = root;
    var initial_generation_owned = true;
    defer if (initial_generation_owned) {
        drainInitialGeneration(initial_generation, &scheduler, &loop) catch |err|
            std.debug.panic("could not drain bootstrap: {s}", .{@errorName(err)});
        initial_generation.destroy();
    };
    if (!initial_generation.application_ready)
        try finishInitialBootstrap(initial_generation, &scheduler, &loop, &diagnostic);
    if (initial_generation.vm.exit_code) |code| {
        if (options.exit_code) |result| result.* = code;
        return;
    }
    var appearance_store: appearance_module.Store = .{};
    const appearance = options.appearance orelse &appearance_store;
    const settings_path = if (options.appearance == null and generation_config.runtime_dir != null and
        generation_config.runtime_dir.?.len != 0)
        try std.fmt.allocPrint(init.gpa, "{s}/ouro/settings.mcp.sock", .{generation_config.runtime_dir.?})
    else
        null;
    defer if (settings_path) |path| init.gpa.free(path);
    var appearance_client: appearance_module.Client = undefined;
    try appearance_client.init(init.gpa, &loop, appearance, settings_path);
    defer appearance_client.deinit();
    var source_reload: SourceReload = undefined;
    source_reload.init(
        init.gpa,
        init.io,
        provider,
        &scheduler,
        &loop,
        null,
        generation_config,
        initial_generation,
    );
    source_reload.appearance = &appearance_client;
    if (module_root) |directory| source_reload.attachModuleRoot(directory.handle);
    initial_generation_owned = false;
    var sources_destroyed = false;
    defer if (!sources_destroyed) {
        drainSources(&source_reload, &loop, null, null) catch |err|
            std.debug.panic("could not drain application: {s}", .{@errorName(err)});
        source_reload.deinit();
    };
    var runtime_reload_requests: ReloadRequests = .{};
    const reload_requests = options.reload_requests orelse &runtime_reload_requests;
    var control_storage: ControlServer = undefined;
    const control: ?*ControlServer = if (source_reload.active().application.hasActions()) &control_storage else null;
    const inherited = try socket_activation.listener(init.minimal.environ);
    if (inherited != null and control == null) return error.SocketActivationRequiresActions;
    if (control) |server| {
        try server.init(init.gpa, &loop, init.minimal.environ, source_reload.active().application.id, source_reload.generation, reload_requests);
        std.log.info("application socket: {s}", .{server.socketPath()});
    }
    var control_destroyed = false;
    defer if (!control_destroyed) if (control) |server|
        shutdownControl(server, &loop, null, &source_reload);
    if (control) |server| try server.setApplication(&source_reload.active().application, &source_reload.active().vm);
    if (inherited != null) {
        if (!(try runHeadless(&source_reload, control.?, &callbacks, reload_requests, &loop, &scheduler))) {
            if (options.exit_code) |code| code.* = source_reload.active().vm.exit_code orelse 0;
            return;
        }
    }
    errdefer |err| if (!control_destroyed) {
        failActivation(control, &source_reload, &loop, null, err) catch {};
    };

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
    var theme_fonts: @import("../lua/theme_fonts.zig").ThemeFonts = .{ .allocator = init.gpa, .io = init.io, .fonts = &fonts };
    defer theme_fonts.deinit();
    const primary_font = try loadFont(init, &fonts, configured_fonts.faces[0]);
    defer fonts.release(primary_font) catch unreachable;
    const medium_font = try loadFont(init, &fonts, configured_medium_fonts.faces[0]);
    defer fonts.release(medium_font) catch unreachable;
    var paragraph_sources = text.ParagraphSourceCache.init(init.gpa, &fonts);
    defer paragraph_sources.deinit();
    var paragraphs = text.ParagraphCache.init(init.gpa, &fonts);
    defer paragraphs.deinit();
    var images = try @import("../image/cache.zig").Cache.init(init.gpa, 256);
    defer images.deinit();
    var icon_paths = try @import("../xdg/icons.zig").SearchPaths.init(init.gpa, init.minimal.environ);
    defer icon_paths.deinit();
    var glyphs = try renderer.software.GlyphCache.init(init.gpa, &fonts);
    defer glyphs.deinit();
    var vulkan_renderer: renderer.vulkan = undefined;
    if (options.vulkan) vulkan_renderer = try renderer.vulkan.init(init.gpa);
    defer if (options.vulkan) vulkan_renderer.deinit();
    var vulkan_glyphs: renderer.vulkan.GlyphCache = undefined;
    if (options.vulkan) vulkan_glyphs = try renderer.vulkan.GlyphCache.init(init.gpa, &fonts, &vulkan_renderer);
    defer if (options.vulkan) vulkan_glyphs.deinit();
    const theme = appearanceTheme(appearance.current);
    const services: source_generation.UiServices = .{
        .paragraph_sources = &paragraph_sources,
        .paragraphs = &paragraphs,
        .primary_font = primary_font,
        .medium_font = medium_font,
        .theme = theme,
        .callbacks = &callbacks,
        .theme_fonts = &theme_fonts,
        .workspaces = &workspaces,
        .images = &images,
        .icon_roots = icon_paths.paths,
    };
    // Generations must release their text resources before the caches above.
    defer {
        if (!control_destroyed) if (control) |server| shutdownControl(server, &loop, null, &source_reload);
        control_destroyed = true;
        drainSources(&source_reload, &loop, null, null) catch |err|
            std.debug.panic("could not drain application: {s}", .{@errorName(err)});
        source_reload.deinit();
        sources_destroyed = true;
    }
    errdefer |err| if (!control_destroyed) {
        failActivation(control, &source_reload, &loop, null, err) catch {};
    };
    try source_reload.active().attachUi(services);
    source_reload.services = services;
    source_reload.config.defer_run = false;
    try source_reload.active().startUi();
    try finishUiBootstrap(&source_reload, control, &loop, &scheduler);
    const application = &source_reload.active().application;
    if (application.windows.len > options.application_window_capacity)
        return error.WindowCapacityExceeded;

    var window_set: windows_module.WindowSet = undefined;
    var host: platform.wayland.Host = undefined;
    var startup_io: StartupIo = .{ .reload = &source_reload, .loop = &loop, .control = control };
    try host.init(
        init.gpa,
        &loop,
        init.minimal.environ,
        window_set.eventSink(),
        .{
            .app_id = application.id,
            .window_capacity = options.application_window_capacity,
            .output_capacity = options.output_capacity,
            .workspaces = &workspaces,
            .workspace_capacity = options.workspace_capacity,
            .startup_completions = .{ .context = &startup_io, .dispatch = StartupIo.dispatch },
            .vulkan = if (options.vulkan) &vulkan_renderer else null,
        },
    );
    defer host.deinit();
    try application.extractOutputTemplates();
    for (host.outputs) |output| if (output.name) |name| {
        _ = try application.expandOutput(name, options.application_window_capacity);
    };
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
    defer {
        if (control) |server| shutdownControl(server, &loop, &host, &source_reload);
        control_destroyed = true;
        drainSources(&source_reload, &loop, null, null) catch |err|
            std.debug.panic("could not drain application: {s}", .{@errorName(err)});
    }
    errdefer |err| failActivation(control, &source_reload, &loop, &host, err) catch {};
    var disconnect_started = false;
    var active_reload_sequence: ?u64 = null;
    var queued_reload_sequence: ?u64 = null;
    var initial_activation_token = std.process.Environ.getPosix(init.minimal.environ, "XDG_ACTIVATION_TOKEN");

    while (true) {
        const shutdown_signal = try loop.receivedSignal();
        const active_generation = source_reload.active();
        const active_application = &active_generation.application;
        const signals = &active_generation.signals;
        const lua_ui = &active_generation.ui_build;
        if (appearance.takeEvent()) |event| switch (event) {
            .appearance_changed => |snapshot_value| {
                if (source_reload.setTheme(appearanceTheme(snapshot_value))) {
                    for (runtime_slots) |*slot| if (slot.runtime.initialized)
                        try slot.runtime.setTheme(lua_ui.widget_theme.?.colors);
                }
            },
        };
        var desired_changed = false;
        if (!disconnect_started and host.failure == null and shutdown_signal == null and active_generation.vm.exit_code == null) {
            for (host.outputs) |output| if (output.name) |name| {
                if (try active_application.expandOutput(name, runtime_slots.len)) desired_changed = true;
            };
            if (desired_changed) try syncRuntimeSlots(init.gpa, runtime_slots, active_application.windows);
        }
        clipboard.setPlatformAvailable(host.clipboardAvailable());
        while (host.takeClipboardCompletion()) |completion| {
            if (completion.canceled)
                try clipboard.acknowledgeCancellation(completion.request)
            else
                try clipboard.completePaste(completion.request, completion.text);
            try host.releaseClipboardCompletion(completion.request);
        }
        if (host.failure != null or shutdown_signal != null) {
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
        try host.enableWorkspacesIf(active_generation.workspacesRequested());
        try active_generation.syncWorkspaces();
        if (control) |server| {
            server.collectClosed();
            try server.setApplication(active_application, &active_generation.vm);
            try server.serviceRequests();
        }
        try source_reload.collectCanceledMcp();
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
        while (scheduler.takeRunnable()) |handle| {
            if (control) |server| if (try server.resumeRunnable(handle)) continue;
            try source_reload.resumeRunnable(handle);
        }
        if (control) |server| {
            server.collectClosed();
            try server.serviceRequests();
        }

        if (!disconnect_started and host.failure == null and shutdown_signal == null and active_generation.vm.exit_code == null) {
            const rebuilt = active_generation.refreshWindows() catch |err| blk: {
                std.log.err("window declaration failed: {s}", .{@errorName(err)});
                break :blk false;
            };
            if (rebuilt) {
                for (host.outputs) |output| if (output.name) |name| {
                    _ = try active_application.expandOutput(name, runtime_slots.len);
                };
                try syncRuntimeSlots(init.gpa, runtime_slots, active_application.windows);
                for (runtime_slots) |*slot| if (slot.runtime.ready and slot.desired) {
                    _ = try slot.runtime.build_owners.markDirty(slot.runtime.root_owner);
                };
                desired_changed = true;
            }
        }

        if (active_generation.vm.exit_code) |code| {
            if (options.exit_code) |result| result.* = code;
            if (!active_generation.stdio.hasPendingOutput()) {
                for (runtime_slots) |*slot| if (slot.desired) {
                    slot.desired = false;
                    desired_changed = true;
                };
            }
        }

        try host.serviceWorkspaceActions();

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
        const calls_pending = if (control) |server| server.hasPendingCalls() else false;
        if (!disconnect_started and current_count == 0 and
            (active_generation.window_owners == null or active_generation.vm.exit_code != null or shutdown_signal != null or host.failure != null or options.exit_after_first_frame) and
            (active_application.windows.len != 0 or active_application.output_templates.len == 0 or active_generation.vm.exit_code != null or shutdown_signal != null or host.failure != null) and
            (!calls_pending or active_generation.vm.exit_code != null or shutdown_signal != null) and
            (!active_generation.stdio.hasPendingOutput() or shutdown_signal != null))
        {
            try host.beginShutdown();
            try appearance_client.stop();
            if (control) |server| try server.beginShutdown();
            try source_reload.active().vm.requestCancellation();
            disconnect_started = true;
        }
        try window_set.reconcile(current_storage[0..current_count]);

        for (runtime_slots) |*slot| {
            const window = applicationWindowForId(active_application.windows, slot.id orelse continue);
            const active_handle = window_set.activeHandleForId(slot.id.?);
            if (window == null or !slot.desired or active_handle == null) {
                if (slot.runtime.registered) {
                    try dirty.unregister(slot.runtime.window);
                    slot.runtime.registered = false;
                }
                try slot.runtime.clear(lua_ui);
                slot.configured_size = null;
                slot.text_input_enabled = false;
                slot.text_input_surface_focused = false;
                slot.text_input_revision = null;
                if (window_set.handleForId(slot.id.?) == null) {
                    slot.runtime.deinit();
                    slot.runtime = .{};
                    if (!slot.declared) {
                        init.gpa.free(slot.id.?);
                        slot.* = .{};
                    }
                }
                continue;
            }
            const handle = active_handle.?;
            if (slot.runtime.initialized and !sameHandle(slot.runtime.window, handle)) {
                // The old native scope can disappear only after its widgets
                // and build owners have drained. Reopening mounts fresh UI.
                slot.runtime.deinit();
                slot.runtime = .{};
            }
            if (!slot.runtime.initialized) {
                const window_theme = lua_ui.widget_theme.?.colors;
                try slot.runtime.init(
                    init.gpa,
                    &scheduler,
                    try window_set.scope(handle),
                    handle,
                    window_theme.background,
                    window_theme.primary,
                    window_theme.foreground,
                    window_theme.input,
                    window_theme.ring,
                    signals,
                    &paragraph_sources,
                    &paragraphs,
                    options.window,
                );
                // Desktop surfaces own their entire configured rectangle.
                if (window.?.declaration == .layer_surface) slot.runtime.root_padding = 0;
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
                return @as(anyerror!void, err);
            };
            slot.configured_size = null;
            try dirty.complete(work);
        }

        if (reload_requests.take()) |sequence| {
            if (active_reload_sequence == null) {
                if (try beginReload(&source_reload, control, sequence))
                    active_reload_sequence = sequence;
            } else {
                queued_reload_sequence = sequence;
            }
        }
        if (active_reload_sequence) |sequence| {
            if (source_reload.takeCandidateFailure()) |err| {
                try reportReloadFailure(&source_reload, control, sequence, err);
                active_reload_sequence = null;
            } else if (source_reload.candidateReady()) {
                try servicePreparedReload(
                    &source_reload,
                    runtime_slots,
                    reload_targets,
                    &callbacks,
                    control,
                    sequence,
                );
                active_reload_sequence = null;
            }
        }
        if (active_reload_sequence == null) if (queued_reload_sequence) |sequence| {
            queued_reload_sequence = null;
            if (try beginReload(&source_reload, control, sequence))
                active_reload_sequence = sequence;
        };
        if (control) |server| server.setReloading(active_reload_sequence != null or queued_reload_sequence != null);
        source_reload.beginRetirement() catch |err|
            std.log.err("could not begin source-generation retirement: {s}", .{@errorName(err)});
        _ = source_reload.collectRetired();

        for (runtime_slots) |*slot| if (slot.runtime.ready)
            try slot.runtime.prepareFrame(try host.outputScale(slot.runtime.window));
        try source_reload.active().pumpImages();

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
            if (!slot.desired or !slot.runtime.registered) continue;
            if (slot.runtime.wantsSubmission()) try host.requestRedraw(slot.runtime.window);
        }

        for (runtime_slots) |*slot| {
            if (!slot.desired or !slot.runtime.registered) continue;
            const handle = slot.runtime.window;
            if (slot.runtime.wantsSubmission()) if (try host.acquireFrame(handle)) |frame_buffer| {
                const list = try slot.runtime.displayList();
                (switch (frame_buffer.target) {
                    .software => |target| renderer.software.renderResources(list, .{
                        .pixels = target.pixels,
                        .width = frame_buffer.width,
                        .height = frame_buffer.height,
                        .stride = target.stride,
                        .format = .bgra8_unorm,
                    }, &glyphs, null, &paragraphs, &images),
                    .vulkan => |target| vulkan_renderer.renderDmabufResources(
                        list,
                        target,
                        &vulkan_glyphs,
                        null,
                        &paragraphs,
                        &images,
                    ),
                }) catch |err| {
                    try host.discardFrame(frame_buffer);
                    return @as(anyerror!void, err);
                };
                try host.present(frame_buffer);
                try slot.runtime.frameSubmitted();
            };
            slot.frames_seen = @max(slot.frames_seen, try host.framesPresented(handle));
        }

        if (control) |server| {
            var presented = false;
            for (runtime_slots) |slot| presented = presented or slot.frames_seen > 0;
            if (presented) {
                _ = server.takeActivation();
                if (server.activationToken() orelse initial_activation_token) |token| {
                    for (runtime_slots) |slot| if (slot.desired and slot.runtime.initialized) {
                        try host.activate(slot.runtime.window, token);
                        break;
                    };
                }
                initial_activation_token = null;
                server.setActivated(true);
                try server.activationSucceeded();
            }
        } else if (initial_activation_token) |token| {
            for (runtime_slots) |slot| if (slot.desired and slot.frames_seen > 0) {
                try host.activate(slot.runtime.window, token);
                initial_activation_token = null;
                break;
            };
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
        // MCP and Lua timers can enqueue I/O while Wayland is idle.
        _ = try loop.submit();
        if (scheduler.hasPendingWork()) continue;
        const control_quiescent = if (control) |server| server.quiescent() else true;
        if (host.quiescent() and window_set.retainedCount() == 0 and control_quiescent and
            !loop.hasPendingTimerKernelWork() and !loop.hasPendingOperations()) break;
        if (desired_changed or window_set.changeSerial() != serial_before_flush) continue;
        if (host.quiescent() and control_quiescent and
            !loop.hasPendingTimerKernelWork() and !loop.hasPendingOperations()) continue;

        const completion = try loop.wait();
        switch (loop.dispatch(completion)) {
            .file => |file| if (!(try host.dispatchClipboardFile(file)))
                try source_reload.markFileCompleted(file),
            .socket => |socket| {
                if (control) |server| if (try server.dispatch(socket)) continue;
                try source_reload.markSocketCompleted(socket);
            },
            .operation_cancel => {
                if (control) |server| server.collectClosed();
                try source_reload.collectCanceledMcp();
            },
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout| {
                if (try host.dispatchTimer(timeout.operation)) continue;
                try source_reload.markTimeoutCompleted(timeout.operation);
            },
            .foreign => try host.dispatchOne(completion),
            .stale => return error.StaleCompletion,
            .signal_wakeup => {},
        }
    }
    if (host.failure) |failure| return @as(anyerror!void, failure);
}

/// Deliver a failed activation before the normal teardown closes its socket.
fn failActivation(control: ?*ControlServer, reload: *SourceReload, loop: *io_loop.Loop, host: ?*platform.wayland.Host, err: anyerror) !void {
    const server = control orelse return;
    if (!server.activating) return;
    try server.activationFailed(err);
    while (server.hasPendingOutput()) {
        _ = try loop.submit();
        _ = try dispatchApplication(reload, loop, server, host, null);
        try server.serviceRequests();
    }
}

/// Runs only application tasks and IPC. No font, renderer or Wayland state
/// exists yet. An accepted Activate transfers control to UI initialization.
fn runHeadless(
    reload: *SourceReload,
    control: *ControlServer,
    callbacks: *lua.CallbackRegistry,
    requests: *ReloadRequests,
    loop: *io_loop.Loop,
    scheduler: *task.Scheduler,
) !bool {
    var sequence: ?u64 = null;
    var idle_timer: ?io_loop.OperationHandle = null;
    defer if (idle_timer) |timer| loop.prepareCancel(timer) catch {};
    while (true) {
        if (try loop.receivedSignal() != null) return false;
        control.collectClosed();
        try control.setApplication(&reload.active().application, &reload.active().vm);
        try control.serviceRequests();
        try reload.collectCanceledMcp();
        try scheduler.applyQueuedCancellations();
        while (scheduler.takeRunnable()) |handle| {
            if (try control.resumeRunnable(handle)) continue;
            try reload.resumeRunnable(handle);
        }
        try control.serviceRequests();
        if (reload.active().vm.exit_code != null and !reload.active().stdio.hasPendingOutput()) return false;
        if (sequence == null) if (requests.take()) |value| {
            if (try beginReload(reload, control, value)) sequence = value;
        };
        if (sequence) |value| {
            if (reload.takeCandidateFailure()) |err| {
                try reportReloadFailure(reload, control, value, err);
                sequence = null;
            } else if (reload.candidateReady()) {
                try servicePreparedReload(reload, &.{}, &.{}, callbacks, control, value);
                sequence = null;
            }
        }
        try reload.beginRetirement();
        _ = reload.collectRetired();
        if (sequence == null and control.takeActivation()) {
            if (reload.active().application.hasRun()) return true;
            try control.activationFailed(error.ApplicationRunRequired);
        }
        const busy = control.hasClients() or sequence != null or reload.active().vm.activeTaskCount() != 0;
        if (busy) {
            if (idle_timer) |timer| try loop.prepareCancel(timer);
            idle_timer = null;
        } else if (idle_timer == null) {
            idle_timer = try loop.prepareTimeout(30 * std.time.ns_per_s);
        }
        _ = try loop.submit();
        if (scheduler.hasPendingWork()) continue;
        if (try dispatchApplication(reload, loop, control, null, &idle_timer)) return false;
    }
}

fn finishUiBootstrap(reload: *SourceReload, control: ?*ControlServer, loop: *io_loop.Loop, scheduler: *task.Scheduler) !void {
    while (reload.active().ui_task != null) {
        if (try loop.receivedSignal() != null) return error.ApplicationInterrupted;
        if (control) |server| try server.serviceRequests();
        while (scheduler.takeRunnable()) |handle| {
            if (control) |server| if (try server.resumeRunnable(handle)) continue;
            try reload.resumeRunnable(handle);
        }
        if (reload.active().vm.exit_code != null) return error.ApplicationExitedBeforeUi;
        if (reload.active().ui_task == null) return;
        _ = try loop.submit();
        _ = try dispatchApplication(reload, loop, control, null, null);
    }
}

const StartupIo = struct {
    reload: *SourceReload,
    loop: *io_loop.Loop,
    control: ?*ControlServer,

    fn dispatch(context: *anyopaque, completion: std.os.linux.io_uring_cqe) anyerror!void {
        const self: *StartupIo = @ptrCast(@alignCast(context));
        _ = try dispatchApplicationCompletion(self.reload, self.loop, self.control, null, null, completion);
        if (try self.loop.receivedSignal() != null) return error.ApplicationInterrupted;
    }
};

fn dispatchApplication(reload: *SourceReload, loop: *io_loop.Loop, control: ?*ControlServer, host: ?*platform.wayland.Host, idle_timer: ?*?io_loop.OperationHandle) !bool {
    return dispatchApplicationCompletion(reload, loop, control, host, idle_timer, try loop.wait());
}

fn dispatchApplicationCompletion(reload: *SourceReload, loop: *io_loop.Loop, control: ?*ControlServer, host: ?*platform.wayland.Host, idle_timer: ?*?io_loop.OperationHandle, completion: std.os.linux.io_uring_cqe) !bool {
    var idle_expired = false;
    switch (loop.dispatch(completion)) {
        .file => |file| {
            if (host) |value| if (try value.dispatchClipboardFile(file)) return false;
            try reload.markFileCompleted(file);
        },
        .socket => |socket| {
            if (control) |server| if (try server.dispatch(socket)) return false;
            try reload.markSocketCompleted(socket);
        },
        .operation_cancel => {
            if (control) |server| server.collectClosed();
            try reload.collectCanceledMcp();
        },
        .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout| {
            if (idle_timer) |timer| if (timer.*) |handle| {
                if (std.meta.eql(handle, timeout.operation)) {
                    timer.* = null;
                    idle_expired = true;
                    continue;
                }
            };
            if (host) |value| if (try value.dispatchTimer(timeout.operation)) continue;
            try reload.markTimeoutCompleted(timeout.operation);
        },
        .foreign => if (host) |value| try value.dispatchOne(completion) else return error.UnownedIoCompletion,
        .stale => return error.StaleCompletion,
        .signal_wakeup => {},
    }
    return idle_expired;
}

fn drainSources(reload: *SourceReload, loop: *io_loop.Loop, control: ?*ControlServer, host: ?*platform.wayland.Host) !void {
    if (reload.appearance) |client| try client.stop();
    reload.active().shutdownImages();
    if (reload.candidate) |candidate| candidate.shutdownImages();
    try reload.active().vm.requestCancellation();
    if (reload.candidate) |candidate| try candidate.vm.requestCancellation();
    try reload.beginRetirement();
    while (true) {
        try reload.scheduler.applyQueuedCancellations();
        while (reload.scheduler.takeRunnable()) |handle| {
            if (control) |server| if (try server.resumeRunnable(handle)) continue;
            try reload.resumeRunnable(handle);
        }
        try reload.collectCanceledMcp();
        _ = try loop.submit();
        if (!loop.hasPendingOperations() and !loop.hasPendingTimerKernelWork()) break;
        _ = try dispatchApplication(reload, loop, control, host, null);
    }
}

fn appearanceTheme(snapshot: appearance_module.Snapshot) design.tokens.Theme {
    return switch (snapshot.color_scheme) {
        .default, .light => design.tokens.light,
        .dark => design.tokens.dark,
    };
}

fn finishInitialBootstrap(
    generation: *SourceGeneration,
    scheduler: *task.Scheduler,
    loop: *io_loop.Loop,
    diagnostic: *?lua.Diagnostic,
) !void {
    while (!generation.application_ready) {
        if (try loop.receivedSignal() != null) return error.ApplicationInterrupted;
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
        if (generation.application_ready or
            (generation.vm.exit_code != null and !generation.stdio.hasPendingOutput())) return;
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| if (!(try generation.dispatchFile(completion)))
                return error.UnownedIoCompletion,
            .socket => |completion| if (!(try generation.dispatchSocket(completion)))
                return error.UnownedIoCompletion,
            .operation_cancel => try generation.collectCanceledMcp(),
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout|
                try generation.vm.markTimeoutCompleted(timeout.operation),
            .signal_wakeup => {},
            else => return error.UnexpectedBootstrapCompletion,
        }
    }
}

fn drainInitialGeneration(generation: *SourceGeneration, scheduler: *task.Scheduler, loop: *io_loop.Loop) !void {
    generation.shutdownImages();
    try generation.vm.requestCancellation();
    while (true) {
        try scheduler.applyQueuedCancellations();
        while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
        try generation.collectCanceledMcp();
        _ = try loop.submit();
        if (!loop.hasPendingOperations() and !loop.hasPendingTimerKernelWork()) return;
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| if (!(try generation.dispatchFile(completion))) return error.UnownedIoCompletion,
            .socket => |completion| if (!(try generation.dispatchSocket(completion))) return error.UnownedIoCompletion,
            .operation_cancel => try generation.collectCanceledMcp(),
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout|
                try generation.vm.markTimeoutCompleted(timeout.operation),
            .signal_wakeup => {},
            else => return error.UnexpectedBootstrapCompletion,
        }
    }
}

/// Runs the complete disk-read, candidate-build, and application commit at the
/// reconciliation safe point. Failure is deliberately non-fatal: the active
/// generation and its last good frames remain authoritative.
fn beginReload(
    reload: *SourceReload,
    control: ?*ControlServer,
    request_sequence: u64,
) !bool {
    reload.prepare() catch |err| {
        try reportReloadFailure(reload, control, request_sequence, err);
        return false;
    };
    if (control) |server| server.setReloading(true);
    return true;
}

fn servicePreparedReload(
    reload: *SourceReload,
    slots: []RuntimeSlot,
    target_storage: []source_reload_module.WindowTarget,
    callbacks: *lua.CallbackRegistry,
    control: ?*ControlServer,
    request_sequence: u64,
) !void {
    var candidate_pending = true;
    defer if (candidate_pending) reload.discard();

    const candidate = reload.candidate.?;
    // Include disconnected outputs retained by the active generation, keeping
    // reload's window identities aligned with the host's hotplug lifetimes.
    candidate.application.extractOutputTemplates() catch |err| {
        try reportReloadFailure(reload, control, request_sequence, err);
        return;
    };
    for (reload.active().application.windows) |window| if (window.template_id != null) {
        _ = candidate.application.expandOutput(window.declaration.layer_surface.output.?, slots.len) catch |err| {
            try reportReloadFailure(reload, control, request_sequence, err);
            return;
        };
    };
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
    var prepared_control: ?ControlServer.PreparedApplication = if (control) |server|
        server.prepareApplication(&candidate.application, &candidate.vm) catch |err| {
            try reportReloadFailure(reload, control, request_sequence, err);
            return;
        }
    else
        null;
    defer if (prepared_control) |*prepared| prepared.deinit();
    const committed = reload.commitApplication(targets, callbacks) catch |err| {
        try reportReloadFailure(reload, control, request_sequence, err);
        return;
    };
    candidate_pending = false;
    if (control) |server| {
        server.commitApplication(&prepared_control.?);
        try server.reloadSucceeded(request_sequence, committed.generation);
    }
    std.log.info(
        "source reload request {d} committed generation {d}",
        .{ request_sequence, committed.generation },
    );
}

fn reportReloadFailure(
    reload: *const SourceReload,
    control: ?*ControlServer,
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
        if (control) |server| try server.reloadFailed(request_sequence, diagnostic, err);
    } else {
        std.log.err(
            "source reload request {d} failed: {s}",
            .{ request_sequence, @errorName(err) },
        );
        if (control) |server| try server.reloadFailed(request_sequence, null, err);
    }
}

fn shutdownControl(
    control: *ControlServer,
    loop: *io_loop.Loop,
    host: ?*platform.wayland.Host,
    source_reload: *SourceReload,
) void {
    control.beginShutdown() catch |err|
        std.debug.panic("could not stop runtime control server: {s}", .{@errorName(err)});
    while (!control.quiescent()) {
        source_reload.scheduler.applyQueuedCancellations() catch |err|
            std.debug.panic("could not cancel action tasks: {s}", .{@errorName(err)});
        while (source_reload.scheduler.takeRunnable()) |handle| {
            if (control.resumeRunnable(handle) catch |err|
                std.debug.panic("could not drain action task: {s}", .{@errorName(err)})) continue;
            source_reload.resumeRunnable(handle) catch |err|
                std.debug.panic("could not drain source task: {s}", .{@errorName(err)});
        }
        control.collectClosed();
        if (control.quiescent()) break;
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
                    source_reload.markSocketCompleted(socket) catch |err|
                        std.debug.panic("could not drain source socket: {s}", .{@errorName(err)});
            },
            .operation_cancel => {
                control.collectClosed();
                source_reload.collectCanceledMcp() catch |err|
                    std.debug.panic("could not drain source cancellation: {s}", .{@errorName(err)});
            },
            .timer_wakeup, .timer_control => while (loop.takeExpired() catch |err|
                std.debug.panic("could not drain timer: {s}", .{@errorName(err)})) |timeout|
            {
                if (host) |value| if (value.dispatchTimer(timeout.operation) catch |err|
                    std.debug.panic("could not drain host timer: {s}", .{@errorName(err)})) continue;
                source_reload.markTimeoutCompleted(timeout.operation) catch |err|
                    std.debug.panic("could not drain source timer: {s}", .{@errorName(err)});
            },
            .foreign => if (host) |value| value.dispatchOne(completion) catch |err|
                std.debug.panic("could not drain host I/O: {s}", .{@errorName(err)}) else std.debug.panic("unowned host I/O", .{}),
            .stale => std.debug.panic("stale completion during control shutdown", .{}),
            .signal_wakeup => {},
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
