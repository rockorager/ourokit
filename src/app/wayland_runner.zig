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
const development_control = @import("development_control.zig");
const desktop = @import("../lua/desktop_application.zig");
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;
const WindowRuntimeConfig = @import("window_runtime.zig").Config;
const core = @import("../core/root.zig");
const design = @import("../design/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const lua_c = @import("../lua/c.zig");
const platform = @import("../platform/root.zig");
const renderer = @import("../renderer/root.zig");
const shell = @import("../shell/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");

pub const Options = struct {
    development: bool = false,
    mcp: bool = false,
    headless: bool = false,
    desktop: desktop.Options = .{},
    native_modules: []const @import("../native/root.zig").Module = &.{},
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
    /// Optional host-owned appearance state. When supplied, the Settings portal is
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
    content_reference: c_int = lua_c.no_reference,
    content_changed: bool = false,
    desired: bool = false,
    configured_size: ?core.SizeU = null,
    frames_seen: usize = 0,
    runtime: WindowRuntime = .{},
    text_input_generation: ?u64 = null,
    text_input_surface_focused: bool = false,
    text_input_revision: ?TextInputRevision = null,
    popup: ?Popup = null,
};

const Popup = struct {
    window: lua.ApplicationWindow,
    vm: *lua.Vm,
    owner: task.ScopeHandle,
    resource: ?task.ResourceHandle,
    content_lease: lua.CallbackHandle,
    on_close: c_int,
    handle: core.Handle,
    notified: bool = false,
    pending_size: ?core.SizeU = null,

    fn cancel(context: *anyopaque) !void {
        const slot: *RuntimeSlot = @ptrCast(@alignCast(context));
        slot.desired = false;
    }
    fn destroy(_: *anyopaque) void {}
    const lifecycle: task.ResourceLifecycle = .{ .request_cancel = cancel, .destroy = destroy };
};

const PopupHost = struct {
    allocator: std.mem.Allocator,
    windows: *windows_module.WindowSet,
    host: *platform.wayland.Host,
    callbacks: *lua.CallbackRegistry,
    slots: []RuntimeSlot,
    sequence: u64 = 0,

    fn open(context: *anyopaque, vm: *lua.Vm, options: @import("../lua/popup.zig").Options) !core.Handle {
        const self: *PopupHost = @ptrCast(@alignCast(context));
        const parent = runtimeSlotForHandle(self.slots, options.anchor.window) orelse return error.StalePopupParent;
        if (!parent.desired or !parent.runtime.instances.isInteractive(options.anchor.target)) return error.StalePopupParent;
        if (options.input == null and !passiveAnchorLive(parent, options.anchor)) return error.StalePopupAnchor;
        if (parent.popup != null) return error.NestedPopupUnsupported;
        for (self.slots) |slot| if (slot.popup != null and slot.desired and slot.popup.?.window.declaration.popup.input != null)
            return error.PopupAlreadyOpen;
        const slot = for (self.slots) |*candidate| {
            if (candidate.id == null) break candidate;
        } else return error.WindowCapacityExceeded;
        self.sequence += 1;
        const id = try std.fmt.allocPrint(self.allocator, "__ouro_popup_{d}", .{self.sequence});
        errdefer self.allocator.free(id);
        const resource = try self.windows.scheduler.registerResource(options.scope, .window, slot, &Popup.lifecycle);
        errdefer self.windows.scheduler.destroyResource(resource) catch unreachable;
        try self.callbacks.ensureAvailable(1);
        const declaration: platform.window.SurfaceDeclaration = .{ .popup = .{
            .id = id,
            .anchor = options.anchor,
            .input = options.input,
            .width = options.width,
            .height = options.height,
            .side = options.side,
            .gap = options.gap,
            .transparent = options.transparent,
            .pointer_input = options.pointer_input,
        } };
        try self.windows.create(declaration);
        // Native creation retires any passive surface before mapping its
        // replacement. A tooltip must never prevent a menu from opening.
        for (self.slots) |*old| if (old.popup != null and (options.input != null or
            sameHandle(old.popup.?.window.declaration.popup.anchor.window, options.anchor.window)))
        {
            old.desired = false;
        };
        const handle = self.windows.activeHandleForId(id).?;
        slot.* = .{ .id = id, .desired = true, .popup = .{
            .window = .{ .declaration = declaration, .content_reference = options.content },
            .vm = vm,
            .owner = options.scope,
            .resource = resource,
            .content_lease = self.callbacks.adoptReference(vm, options.content) catch unreachable,
            .on_close = options.on_close,
            .handle = handle,
        } };
        if (options.input != null) parent.runtime.popup_target = options.anchor.target;
        return handle;
    }

    fn passiveAnchorLive(parent: *RuntimeSlot, anchor: platform.window.PopupAnchor) bool {
        if (!parent.runtime.instances.isInteractive(anchor.target)) return false;
        if (anchor.controlled) {
            const binding = parent.runtime.pointer_bindings.getKind(anchor.target, .popup_anchor) orelse return false;
            if (binding.open_override != true) return false;
        } else if (!parent.runtime.pointer_bindings.interactionActive(anchor.target)) return false;
        const rectangle = parent.runtime.anchorRectangle(anchor.target) catch return false;
        return std.meta.eql(rectangle, anchor.rectangle);
    }

    fn close(context: *anyopaque, handle: core.Handle) void {
        const self: *PopupHost = @ptrCast(@alignCast(context));
        for (self.slots) |*slot| if (slot.popup) |popup| {
            if (sameHandle(popup.handle, handle)) slot.desired = false;
        };
    }

    fn resize(context: *anyopaque, handle: core.Handle, width: u32, height: u32) !void {
        const self: *PopupHost = @ptrCast(@alignCast(context));
        // The handle is usable immediately after open, even before the first
        // configure has initialized its WindowRuntime.
        const slot = for (self.slots) |*candidate| {
            if (candidate.popup) |value| if (sameHandle(value.handle, handle)) break candidate;
        } else return error.StalePopup;
        const popup = &slot.popup.?;
        if (!slot.desired) return error.StalePopup;
        // Parent props captured by the content closure are not signal reads in
        // the popup's owner. Refresh even if its requested size did not change.
        if (slot.runtime.ready) _ = try slot.runtime.build_owners.markDirty(slot.runtime.root_owner);
        const declaration = popup.window.declaration.popup;
        if (declaration.width == width and declaration.height == height) {
            popup.pending_size = null;
            return;
        }
        if (!try self.host.popupResizeSupported(handle)) return error.PopupResizeUnsupported;
        popup.pending_size = .{ .width = width, .height = height };
    }

    fn flushResizes(self: *PopupHost) !void {
        for (self.slots) |*slot| if (slot.desired) {
            if (slot.popup) |*popup| if (popup.pending_size) |size| {
                var declaration = popup.window.declaration.popup;
                declaration.width = size.width;
                declaration.height = size.height;
                try self.host.resizePopup(popup.handle, declaration);
                popup.window.declaration.popup = declaration;
                popup.pending_size = null;
            };
        };
    }

    fn closing(self: *PopupHost) !void {
        for (self.slots) |*slot| if (slot.popup) |*popup| {
            const declaration = popup.window.declaration.popup;
            const anchor = declaration.anchor;
            const parent = runtimeSlotForHandle(self.slots, anchor.window);
            if (parent == null or !parent.?.desired or !parent.?.runtime.instances.isActive(anchor.target) or
                self.windows.activeHandleForId(slot.id.?) == null) slot.desired = false;
            if (slot.desired and declaration.input == null and !passiveAnchorLive(parent.?, anchor)) slot.desired = false;
            if (slot.desired or popup.notified) continue;
            popup.notified = true;
            if (declaration.input != null) if (parent) |value| try value.runtime.restorePopupFocus(anchor.target);
            if (popup.on_close >= 0) {
                _ = popup.vm.spawnReference(popup.owner, popup.on_close, &.{}) catch |err| switch (err) {
                    error.ScopeCanceled => core.Handle.invalid,
                    else => return err,
                };
            }
        };
    }

    fn release(self: *PopupHost, slot: *RuntimeSlot) void {
        const popup = slot.popup orelse return;
        const c = @import("../lua/c.zig");
        c.luaL_unref(popup.vm.state, c.registry_index, popup.on_close);
        self.callbacks.release(popup.content_lease) catch unreachable;
        if (popup.resource) |resource| self.windows.scheduler.destroyResource(resource) catch unreachable;
        slot.popup = null;
    }
};

const DragHost = struct {
    host: *platform.wayland.Host,

    fn start(context: *anyopaque, input: @import("../platform/activation.zig").Input, mime: @import("../lua/drag.zig").Mime, bytes: []const u8) !void {
        const self: *DragHost = @ptrCast(@alignCast(context));
        try self.host.startDrag(input.window, input.serial, switch (mime) {
            .text => .text,
            .uri_list => .uri_list,
        }, bytes);
    }
};

const WindowExportHost = struct {
    host: *platform.wayland.Host,
    windows: *windows_module.WindowSet,

    fn start(context: *anyopaque, id: []const u8, request: *@import("../platform/window_export.zig").Request) !void {
        const self: *WindowExportHost = @ptrCast(@alignCast(context));
        request.window = self.windows.handleForId(id) orelse return error.StaleWindow;
        try self.host.startWindowExport(request);
    }

    fn cancel(context: *anyopaque, request: *@import("../platform/window_export.zig").Request) !void {
        const self: *WindowExportHost = @ptrCast(@alignCast(context));
        try self.host.cancelWindowExport(request);
    }
};

const PendingDrop = struct {
    request: core.Handle,
    window: core.Handle,
    selection: @import("window_runtime.zig").DropSelection,
    generation: u64,
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
    if (!options.headless and !renderer.software.has_freetype) return error.FreeTypeDisabled;
    return runSourceInternal(init, provider, options) catch |err| {
        if (err != error.ApplicationInterrupted) return err;
    };
}

/// Evaluates only the declaration for packaging. No listener, appearance
/// connection, renderer, or UI factory is started. Declaration output goes to
/// stderr so the caller can reserve stdout for the exported JSON descriptor.
pub fn exportCatalog(init: std.process.Init, provider: *const bundle.SourceProvider) ![]u8 {
    return exportCatalogWithModules(init, provider, &.{});
}

pub fn exportCatalogWithModules(init: std.process.Init, provider: *const bundle.SourceProvider, modules: []const @import("../native/root.zig").Module) ![]u8 {
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
        .native_modules = modules,
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

fn runSourceInternal(
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
    const module_root_fd = if (module_root) |directory| directory.handle else options.asset_root;
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
    var session: @import("../shell/session.zig").Store = .{};
    try workspaces.init(
        init.gpa,
        options.workspace_capacity,
        options.workspace_action_capacity,
    );
    defer workspaces.deinit();

    var applications = try @import("../xdg/applications.zig").Config.init(init.gpa, init.minimal.environ);
    defer applications.deinit();
    const generation_config: source_generation.Config = .{
        .native_modules = options.native_modules,
        .node_capacity = options.window.node_capacity,
        .window_capacity = options.application_window_capacity,
        .semantic_text_capacity = options.window.semantic_text_capacity,
        .signal_capacity = options.signal_capacity,
        .subscription_capacity = options.subscription_capacity,
        .dependency_capacity = options.dependency_capacity,
        .runtime_dir = std.process.Environ.getPosix(init.minimal.environ, "XDG_RUNTIME_DIR"),
        .environ = init.minimal.environ,
        .applications = &applications,
        .defer_run = true,
    };
    // SourceGeneration consumes the snapshot on both success and failure.
    snapshot_owned = false;
    const initial_generation = if (module_root_fd) |root|
        try SourceGeneration.createBootstrap(
            init.gpa,
            &scheduler,
            &loop,
            snapshot,
            root,
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
    if (options.development and options.mcp) return error.ConflictingControlModes;
    var desktop_options = options.desktop;
    desktop_options.development = options.development;
    desktop_options.token = init.minimal.environ.getPosix("XDG_ACTIVATION_TOKEN");
    desktop_options.startup_id = init.minimal.environ.getPosix("DESKTOP_STARTUP_ID");
    initial_generation.desktop_task = try desktop.start(&initial_generation.vm, initial_generation.application.desktop_reference, &initial_generation.application.desktop_state, desktop_options);
    try finishInitialBootstrap(initial_generation, &scheduler, &loop, &diagnostic);
    if (desktop.flag(initial_generation.vm.state, initial_generation.application.desktop_state, "forwarded")) return;
    if (initial_generation.vm.exit_code) |code| {
        if (options.exit_code) |result| result.* = code;
        return;
    }
    var appearance_store: appearance_module.Store = .{};
    const appearance = options.appearance orelse &appearance_store;
    var appearance_client: appearance_module.Client = undefined;
    // Reuse session-address resolution, but own the connection across reloads.
    try appearance_client.init(init.gpa, &loop, appearance, if (options.appearance == null) initial_generation.dbus.session_address else null);
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
    if (module_root_fd) |root| source_reload.attachModuleRoot(root);
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
    const control: ?*ControlServer = if (options.development or options.mcp) &control_storage else null;
    if (options.mcp and !source_reload.active().application.hasActions()) return error.ApplicationActionsDisabled;
    if (control) |server| {
        try server.init(init.gpa, &loop, init.minimal.environ, source_reload.active().application.id, source_reload.generation, reload_requests, options.development);
        std.log.info("{s} socket: {s}", .{ if (options.development) "development" else "application", server.socketPath() });
    }
    var development_service: development_control.Service = .{ .allocator = init.gpa, .io = init.io };
    defer development_service.deinit();
    var runtime_config = options.window;
    if (options.development) runtime_config.measure_phases = true;
    var control_destroyed = false;
    defer if (!control_destroyed) if (control) |server|
        shutdownControl(server, &loop, null, &source_reload);
    if (options.development) try control.?.registerDevelopmentTools(development_control.tools);
    if (control) |server| try server.setApplication(&source_reload.active().application, &source_reload.active().vm);
    if (options.headless or options.desktop.dbus_activated) {
        if (!(try runHeadless(&source_reload, control, &callbacks, reload_requests, &loop, &scheduler, options.headless, options.development, &development_service))) {
            if (options.exit_code) |code| code.* = source_reload.active().vm.exit_code orelse 0;
            return;
        }
    }

    var fonts = text.FontCache.init(init.gpa);
    defer fonts.deinit();
    var theme_fonts: @import("../lua/theme_fonts.zig").ThemeFonts = .{ .allocator = init.gpa, .io = init.io, .fonts = &fonts };
    defer theme_fonts.deinit();
    const font_candidates = try theme_fonts.get("sans-serif", false);
    const medium_font_candidates = try theme_fonts.get("sans-serif", true);
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
    var paragraph_bounds: renderer.software.ParagraphBounds = .{ .glyphs = &glyphs, .paragraphs = &paragraphs };
    var software_scratch: renderer.software.Scratch = .{};
    defer software_scratch.deinit(std.heap.page_allocator);
    var path_masks = @import("../path/root.zig").MaskCache.init(init.gpa);
    defer path_masks.deinit();
    var shadow_masks = @import("../shadow/root.zig").MaskCache.init(init.gpa);
    defer shadow_masks.deinit();
    var vulkan_renderer: renderer.vulkan = undefined;
    if (options.vulkan) vulkan_renderer = try renderer.vulkan.init(init.gpa);
    defer if (options.vulkan) vulkan_renderer.deinit();
    var vulkan_glyphs: renderer.vulkan.GlyphCache = undefined;
    if (options.vulkan) vulkan_glyphs = try renderer.vulkan.GlyphCache.init(init.gpa, &fonts, &vulkan_renderer);
    defer if (options.vulkan) vulkan_glyphs.deinit();
    const services: source_generation.UiServices = .{
        .paragraph_sources = &paragraph_sources,
        .paragraphs = &paragraphs,
        .font_candidates = font_candidates,
        .medium_font_candidates = medium_font_candidates,
        .color_scheme = appearanceScheme(appearance.current),
        .reduced_motion = appearance.current.reduced_motion,
        .callbacks = &callbacks,
        .theme_fonts = &theme_fonts,
        .workspaces = &workspaces,
        .session = &session,
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
            .session = &session,
            .workspace_capacity = options.workspace_capacity,
            .startup_completions = .{ .context = &startup_io, .dispatch = StartupIo.dispatch },
            .vulkan = if (options.vulkan) &vulkan_renderer else null,
        },
    );
    defer host.deinit();
    callbacks.activation_provider = host.activationProvider();
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
    const development_windows = try init.gpa.alloc(development_control.Window, if (options.development) options.application_window_capacity else 0);
    defer init.gpa.free(development_windows);
    try syncRuntimeSlots(init.gpa, runtime_slots, application.windows);
    var popups: PopupHost = .{ .allocator = init.gpa, .windows = &window_set, .host = &host, .callbacks = &callbacks, .slots = runtime_slots };
    callbacks.popup_provider = .{ .context = &popups, .open = PopupHost.open, .close = PopupHost.close, .resize = PopupHost.resize };
    var drag_host: DragHost = .{ .host = &host };
    callbacks.drag_provider = .{ .context = &drag_host, .start = DragHost.start };
    var window_export_host: WindowExportHost = .{ .host = &host, .windows = &window_set };
    callbacks.window_export_provider = .{ .context = &window_export_host, .start = WindowExportHost.start, .cancel = WindowExportHost.cancel };
    var drag_window: ?core.Handle = null;
    var drag_position: platform.window.LogicalPosition = .{};
    var drag_text = false;
    var drag_uris = false;
    var drag_selection: ?@import("window_runtime.zig").DropSelection = null;
    var pending_drop: ?PendingDrop = null;
    var drop_sequence: u32 = 0;
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
        drainSources(&source_reload, &loop, control, .{
            .host = &host,
            .popups = &popups,
            .clipboard = &clipboard,
            .drop_request = if (pending_drop) |pending| pending.request else null,
        }) catch |err|
            std.debug.panic("could not drain application: {s}", .{@errorName(err)});
        if (control) |server| server.deinit();
        control_destroyed = true;
    }
    var disconnect_started = false;
    var active_reload_sequence: ?u64 = null;
    var queued_reload_sequence: ?u64 = null;
    var animation_timer: @import("animation_timer.zig").Timer = .{};
    defer animation_timer.stop(&loop) catch unreachable;

    while (true) {
        const shutdown_signal = try loop.receivedSignal();
        const active_generation = source_reload.active();
        active_generation.vm.window_export_provider = callbacks.window_export_provider;
        const active_application = &active_generation.application;
        const signals = &active_generation.signals;
        const lua_ui = &active_generation.ui_build;
        if (appearance.takeEvent()) |event| switch (event) {
            .appearance_changed => |snapshot_value| {
                if (source_reload.setTheme(appearanceScheme(snapshot_value), snapshot_value.reduced_motion)) {
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
                            if (applicationWindowForId(active_application.windows, slot.id.?)) |window| {
                                if (window.on_close_request >= 0) {
                                    _ = try active_generation.vm.spawnReference(try window_set.scope(handle), window.on_close_request, &.{});
                                    continue;
                                }
                            }
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
                    // Owner-events grabs still deliver pointer events on the
                    // parent. Dismiss without activating content underneath.
                    if (pointer == .button and pointer.button.state == .pressed) {
                        var dismissed = false;
                        for (runtime_slots) |*candidate| if (candidate.popup != null and candidate.desired and
                            candidate.popup.?.window.declaration.popup.input != null and
                            !sameHandle(candidate.popup.?.handle, pointer.button.window))
                        {
                            candidate.desired = false;
                            dismissed = true;
                        };
                        if (dismissed) continue;
                    }
                    if (slotForNativeHandle(&window_set, runtime_slots, pointerWindow(pointer))) |slot|
                        if (slot.desired and slot.runtime.ready) try slot.runtime.routePointer(pointer);
                },
                .keyboard => |physical_keyboard| {
                    const keyboard = popupKeyboard(runtime_slots, physical_keyboard);
                    // Keep the parent's physical focus state accurate even
                    // when its grab routes input to a popup. In particular,
                    // wlroots need not send another enter after dismissal.
                    if (physical_keyboard != .key and !sameHandle(keyboardWindow(keyboard), keyboardWindow(physical_keyboard))) {
                        if (slotForNativeHandle(&window_set, runtime_slots, keyboardWindow(physical_keyboard))) |parent|
                            if (parent.desired and parent.runtime.ready) try parent.runtime.routeKeyboard(physical_keyboard);
                    }
                    if (slotForNativeHandle(&window_set, runtime_slots, keyboardWindow(keyboard))) |slot| {
                        if (slot.popup != null and keyboard == .key and keyboard.key.state == .pressed and keyboard.key.translated.logical == .escape) {
                            slot.desired = false;
                            continue;
                        }
                        if (slot.desired and slot.runtime.ready) try slot.runtime.routeKeyboard(keyboard);
                    }
                },
                .text_input => |text_input_event| switch (text_input_event) {
                    .enter => |handle| if (slotForNativeHandle(&window_set, runtime_slots, handle)) |slot| {
                        slot.text_input_surface_focused = true;
                        slot.text_input_generation = null;
                        slot.text_input_revision = null;
                        if (slot.runtime.ready) try slot.runtime.routeTextInput(text_input_event);
                    },
                    .leave => |handle| if (slotForNativeHandle(&window_set, runtime_slots, handle)) |slot| {
                        slot.text_input_surface_focused = false;
                        slot.text_input_generation = null;
                        slot.text_input_revision = null;
                        if (slot.runtime.ready) try slot.runtime.routeTextInput(text_input_event);
                    },
                    .batch => |batch| {
                        if (slotForNativeHandle(&window_set, runtime_slots, batch.window)) |slot|
                            if (slot.runtime.ready)
                                try slot.runtime.routeTextInput(text_input_event);
                    },
                },
            }
        }

        while (try host.takeDragEvent()) |event| switch (event) {
            .enter => |enter| {
                drag_window = enter.window;
                drag_position = enter.position;
                drag_text = enter.text;
                drag_uris = enter.uri_list;
                drag_selection = if (slotForNativeHandle(&window_set, runtime_slots, enter.window)) |slot|
                    try slot.runtime.dropTarget(drag_position, drag_text, drag_uris)
                else
                    null;
                try host.acceptDrag(if (drag_selection) |selection| selection.mime else null);
            },
            .motion => |motion| {
                drag_position = motion.position;
                drag_selection = if (drag_window) |window|
                    if (slotForNativeHandle(&window_set, runtime_slots, window)) |slot|
                        try slot.runtime.dropTarget(drag_position, drag_text, drag_uris)
                    else
                        null
                else
                    null;
                try host.acceptDrag(if (drag_selection) |selection| selection.mime else null);
            },
            .leave => {
                drag_window = null;
                drag_selection = null;
            },
            .drop => {
                if (pending_drop == null and drag_window != null and drag_selection != null) {
                    drop_sequence +%= 1;
                    if (drop_sequence == 0) drop_sequence = 1;
                    // Clipboard paste requests use indexed slots; reserve a
                    // disjoint identity for the runner-owned drop transfer.
                    const request: core.Handle = .{ .slot = std.math.maxInt(u32), .generation = drop_sequence };
                    const selection = drag_selection.?;
                    if (try host.receiveDrop(request, selection.mime)) pending_drop = .{
                        .request = request,
                        .window = drag_window.?,
                        .selection = selection,
                        .generation = source_reload.generation,
                    } else try host.rejectDrop();
                } else try host.rejectDrop();
            },
        };
        while (host.takeDropCompletion()) |completion| {
            var accepted = false;
            if (pending_drop) |pending| if (sameHandle(pending.request, completion.request) and completion.bytes != null and
                pending.generation == source_reload.generation and host.failure == null and shutdown_signal == null)
            {
                if (slotForNativeHandle(&window_set, runtime_slots, pending.window)) |slot|
                    accepted = try slot.runtime.deliverDrop(&callbacks, pending.selection, completion.bytes.?);
            };
            try host.finishDrop(completion.request, accepted);
            pending_drop = null;
        }

        // Task safe point: platform and CQE dispatch only changed state.
        try host.pumpSession();
        try host.enableWorkspacesIf(active_generation.workspacesRequested());
        try active_generation.syncWorkspaces();
        if (control) |server| {
            server.collectClosed();
            try server.setApplication(active_application, &active_generation.vm);
            try server.serviceRequests();
        }
        try source_reload.collectCanceledMcp();
        try scheduler.applyQueuedCancellations();
        try popups.closing();
        for (runtime_slots) |*slot| try slot.runtime.collectRetired();
        for (runtime_slots) |*slot| if (slot.desired and slot.runtime.ready) {
            slot.runtime.popup_anchors_ready = try host.framesPresented(slot.runtime.window) > 0;
            try slot.runtime.dispatchInput(&callbacks);
        };
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
                    if (slot.content_changed)
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
        try popups.closing();
        for (runtime_slots) |slot| if (slot.popup != null and slot.desired) {
            current_storage[current_count] = slot.popup.?.window.declaration;
            current_count += 1;
        };
        const calls_pending = if (control) |server| server.hasPendingCalls() else false;
        if (pending_drop) |pending| {
            const slot = slotForNativeHandle(&window_set, runtime_slots, pending.window);
            if (slot == null or !slot.?.desired or pending.generation != source_reload.generation or
                host.failure != null or shutdown_signal != null or active_generation.vm.exit_code != null)
                _ = try host.cancelClipboard(pending.request);
        }
        if (!disconnect_started and current_count == 0 and
            (active_generation.window_owners == null or active_generation.vm.exit_code != null or shutdown_signal != null or host.failure != null or options.exit_after_first_frame) and
            (active_application.windows.len != 0 or active_application.output_templates.len == 0 or active_generation.vm.exit_code != null or shutdown_signal != null or host.failure != null) and
            (!calls_pending or active_generation.vm.exit_code != null or shutdown_signal != null) and
            (!active_generation.stdio.hasPendingOutput() or shutdown_signal != null))
        {
            try host.beginShutdown();
            try appearance_client.stop();
            if (control) |server| try server.beginShutdown();
            // Persistent D-Bus receives outlive Lua tasks. Retire them before
            // waiting for ring quiescence, not only in the deferred drain.
            source_reload.active().dbus.shutdown();
            source_reload.active().auth.stop();
            source_reload.active().audio.stop();
            if (source_reload.active().session) |*binding| binding.stop();
            if (source_reload.candidate) |candidate| {
                candidate.dbus.shutdown();
                candidate.auth.stop();
                candidate.audio.stop();
                if (candidate.session) |*binding| binding.stop();
                try candidate.vm.requestCancellation();
            }
            try source_reload.active().vm.requestCancellation();
            disconnect_started = true;
        }
        try window_set.reconcile(current_storage[0..current_count]);

        for (runtime_slots) |*slot| {
            const window = if (slot.popup) |*popup| &popup.window else applicationWindowForId(active_application.windows, slot.id orelse continue);
            const active_handle = window_set.activeHandleForId(slot.id.?);
            if (window == null or !slot.desired or active_handle == null) {
                if (slot.runtime.registered) {
                    try dirty.unregister(slot.runtime.window);
                    slot.runtime.registered = false;
                }
                try slot.runtime.clear(lua_ui);
                slot.configured_size = null;
                slot.text_input_generation = null;
                slot.text_input_surface_focused = false;
                slot.text_input_revision = null;
                if (window_set.handleForId(slot.id.?) == null) {
                    slot.runtime.deinit();
                    slot.runtime = .{};
                    popups.release(slot);
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
                    runtime_config,
                );
                // Grabs are user-initiated. Some layer-shell compositors keep
                // physical focus on the parent; popupKeyboard routes its keys.
                slot.runtime.keyboard_focused = slot.popup != null and slot.popup.?.window.declaration.popup.input != null;
                slot.runtime.text_input_surface_focused = false;
                if (slot.popup) |popup| slot.runtime.callback_scope = popup.owner;
                try dirty.register(handle);
                slot.runtime.registered = true;
                slot.runtime.setDirtyWindowQueue(&dirty);
                slot.runtime.setClipboardCoordinator(&clipboard);
            }
            try slot.runtime.setPadding(switch (window.?.declaration) {
                .toplevel => |toplevel| toplevel.padding orelse design.tokens.foundation.spacing_3,
                else => 0,
            });
            try slot.runtime.setBackground(switch (window.?.declaration) {
                .layer_surface => |layer| layer.background,
                .popup => |popup| if (popup.input == null or popup.transparent) core.Color{ .r = 0, .g = 0, .b = 0, .a = 0 } else null,
                .toplevel => |toplevel| toplevel.background,
            });
            if (slot.configured_size != null and !(try dirty.hasPending(handle)))
                _ = try dirty.markDirty(handle);
        }

        // Momentum can dirty virtual-list builders. Advance before draining
        // them so the rows for the new offset are present in this frame.
        const animation_now = try io_loop.monotonicNow();
        for (runtime_slots) |*slot| if (slot.desired and slot.runtime.ready) {
            try slot.runtime.prepareFrame(try host.outputScale(slot.runtime.window));
            try slot.runtime.advanceAnimations(animation_now);
        };

        while (dirty.take()) |work| {
            const slot = runtimeSlotForHandle(runtime_slots, work.owner) orelse
                return error.UnknownDirtyWindow;
            const window = (if (slot.popup) |*popup| &popup.window else applicationWindowForId(active_application.windows, slot.id.?)) orelse
                return error.UnknownDirtyWindow;
            const size = slot.configured_size orelse
                slot.runtime.frame_state.size orelse return error.DirtyWindowNotConfigured;
            slot.runtime.reconcile(
                size,
                lua_ui,
                window.content_reference,
            ) catch |err| {
                if (slot.runtime.ready) {
                    try dirty.retry(work);
                    return @as(anyerror!void, err);
                }
                // Failed initial content still owns a root build scope. Exit
                // via the ordinary close/drain phases rather than deinitializing
                // a mounted runtime while unwinding this stack.
                std.log.err("initial window build failed ({s}): {s}", .{ active_generation.snapshot.entry_name, @errorName(err) });
                try dirty.complete(work);
                active_generation.vm.exit_code = 1;
                desired_changed = true;
                break;
            };
            slot.configured_size = null;
            try dirty.complete(work);
        }
        try popups.flushResizes();

        if (if (options.development) reload_requests.take() else null) |sequence| {
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
            } else if (source_reload.candidateReady() and !development_service.playing()) {
                var popup_retiring = false;
                for (runtime_slots) |*slot| if (slot.popup != null) {
                    slot.desired = false;
                    popup_retiring = true;
                };
                if (!popup_retiring) {
                    try servicePreparedReload(
                        &source_reload,
                        runtime_slots,
                        reload_targets,
                        &callbacks,
                        control,
                        sequence,
                        .{ .windows = &window_set, .host = &host, .dirty = &dirty, .clipboard = &clipboard, .config = runtime_config },
                    );
                    active_reload_sequence = null;
                }
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

        var animation_delay: ?u64 = null;
        for (runtime_slots) |*slot| if (slot.desired and slot.runtime.ready) {
            const scale = try host.outputScale(slot.runtime.window);
            try slot.runtime.prepareFrame(scale);
            try host.setPointerCursor(slot.runtime.window, try slot.runtime.pointerCursor());
            if (try slot.runtime.animationDelay()) |delay|
                animation_delay = @min(animation_delay orelse delay, delay);
        };
        try animation_timer.update(&loop, try io_loop.monotonicNow(), animation_delay);
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
                if (slot.text_input_generation != value.generation) {
                    try host.enableTextInput(slot.runtime.window, value.state, value.generation);
                    slot.text_input_generation = value.generation;
                    slot.text_input_revision = revision;
                } else if (value.commit_permitted and
                    !std.meta.eql(slot.text_input_revision.?, revision))
                {
                    try host.updateTextInput(slot.runtime.window, value.state);
                    slot.text_input_revision = revision;
                }
            } else if (slot.text_input_generation != null) {
                try host.disableTextInput(slot.runtime.window);
                slot.text_input_generation = null;
                slot.text_input_revision = null;
            }
        };

        for (runtime_slots) |*slot| {
            if (!slot.desired or !slot.runtime.registered) continue;
            if (slot.runtime.wantsSubmission()) {
                slot.runtime.damage_tracker.paragraph_bounds = if (host.presentationBackend() == .shared_memory)
                    .{ .context = &paragraph_bounds, .resolve = renderer.software.ParagraphBounds.resolve, .snapshot = renderer.software.ParagraphBounds.snapshot }
                else
                    null;
                try host.prepareScene(slot.runtime.window, try slot.runtime.displayList());
                try host.requestRedraw(slot.runtime.window);
            }
        }

        for (runtime_slots) |*slot| {
            if (!slot.desired or !slot.runtime.registered) continue;
            const handle = slot.runtime.window;
            if (slot.runtime.wantsSubmission()) if (try host.acquireFrame(handle)) |acquired| {
                var frame_buffer = acquired;
                errdefer host.discardFrame(frame_buffer) catch {};
                var list = try slot.runtime.displayList();
                try host.prepareFrameDamage(&frame_buffer, list.damage);
                list.damage = frame_buffer.damage();
                (switch (frame_buffer.target) {
                    .software => |target| renderer.software.renderResources(list, .{
                        .pixels = target.pixels,
                        .width = frame_buffer.width,
                        .height = frame_buffer.height,
                        .stride = target.stride,
                        .format = .bgra8_unorm,
                        .scratch = &software_scratch,
                        .path_masks = &path_masks,
                        .shadow_masks = &shadow_masks,
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
                    return @as(anyerror!void, err);
                };
                try host.present(frame_buffer);
                try slot.runtime.frameSubmitted();
            };
            slot.frames_seen = @max(slot.frames_seen, try host.framesPresented(handle));
        }

        var development_work = false;
        if (options.development and !scheduler.hasPendingWork()) if (control) |server| {
            var count: usize = 0;
            for (runtime_slots) |*slot| if (slot.desired and slot.runtime.ready) {
                development_windows[count] = .{ .id = slot.id.?, .runtime = &slot.runtime };
                count += 1;
            };
            development_work = try development_service.poll(server, &source_reload, development_windows[0..count]);
            try server.serviceRequests();
        };

        for (runtime_slots) |slot| if (slot.desired and slot.frames_seen > 0) {
            const app = &source_reload.active().application;
            if (control) |server| server.setActivated(true);
            const window = applicationWindowForId(app.windows, slot.id.?) orelse continue;
            if (window.declaration != .toplevel) continue;
            if (try desktop.takeToken(init.gpa, app.state, app.desktop_state)) |token| {
                defer init.gpa.free(token);
                try host.activate(slot.runtime.window, token);
            }
            break;
        };

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

        // :close() is state-only and may run during a content build. Revisit
        // reconciliation without waiting for unrelated compositor input.
        for (runtime_slots) |slot| if (slot.popup != null and !slot.desired and
            window_set.activeHandleForId(slot.id.?) != null)
        {
            desired_changed = true;
        };
        const serial_before_flush = window_set.changeSerial();
        try host.pumpSession();
        try host.flush();
        // MCP and Lua timers can enqueue I/O while Wayland is idle.
        try source_reload.collectCanceledMcp();
        _ = try loop.submit();
        if (scheduler.hasPendingWork() or development_work) continue;
        const scroll_events = for (runtime_slots) |*slot| {
            if (slot.desired and slot.runtime.ready and
                (slot.runtime.hasQueuedInput() or slot.runtime.hasPendingScrollEvents())) break true;
        } else false;
        if (scroll_events) continue;
        const control_quiescent = if (control) |server| server.quiescent() else true;
        if (host.quiescent() and window_set.retainedCount() == 0 and control_quiescent and
            !loop.hasPendingTimerKernelWork() and !loop.hasPendingOperations()) break;
        if (desired_changed or window_set.changeSerial() != serial_before_flush) continue;
        if (host.quiescent() and control_quiescent and
            !loop.hasPendingTimerKernelWork() and !loop.hasPendingOperations()) continue;

        var completion = try loop.wait();
        var timers_due = false;
        // Timer and socket CQEs have no cross-stream ordering guarantee. Drain
        // the ready batch before firing timers so an already-received keyboard
        // release cancels repeat even when a slow render delayed dispatch.
        while (true) {
            switch (loop.dispatch(completion)) {
                .file => |file| if (!(try host.dispatchClipboardFile(file)))
                    try source_reload.markFileCompleted(file),
                .socket => |socket| {
                    const handled = if (control) |server| try server.dispatch(socket) else false;
                    if (!handled) try source_reload.markSocketCompleted(socket);
                },
                .operation_cancel => {
                    if (control) |server| server.collectClosed();
                    try source_reload.collectCanceledMcp();
                },
                .timer_wakeup, .timer_control => timers_due = true,
                .foreign => try host.dispatchOne(completion),
                .stale => return error.StaleCompletion,
                .signal_wakeup => {},
            }
            // Dispatch may rearm receives. Submit them and run deferred kernel
            // task work without waiting before deciding the input batch ended.
            // cq_ready alone cannot see work behind IORING_SETUP_DEFER_TASKRUN.
            // Do not resynchronize the alarm until due timers are consumed.
            _ = try loop.submitRing();
            try loop.flushTaskWork();
            if (loop.ring.cq_ready() == 0) break;
            completion = try loop.wait();
        }
        if (timers_due) while (try loop.takeExpired()) |timeout| {
            if (animation_timer.fired(timeout.operation)) continue;
            if (try host.dispatchTimer(timeout.operation)) continue;
            try source_reload.markTimeoutCompleted(timeout.operation);
        };
    }
    if (host.failure) |failure| return @as(anyerror!void, failure);
}

/// Runs only application tasks and IPC. No font, renderer or Wayland state
/// exists yet. An accepted Activate transfers control to UI initialization.
fn runHeadless(
    reload: *SourceReload,
    control: ?*ControlServer,
    callbacks: *lua.CallbackRegistry,
    requests: *ReloadRequests,
    loop: *io_loop.Loop,
    scheduler: *task.Scheduler,
    stay_headless: bool,
    development: bool,
    development_service: *development_control.Service,
) !bool {
    var sequence: ?u64 = null;
    while (true) {
        if (try loop.receivedSignal() != null) return false;
        if (control) |server| {
            server.collectClosed();
            try server.setApplication(&reload.active().application, &reload.active().vm);
            try server.serviceRequests();
        }
        try reload.collectCanceledMcp();
        try scheduler.applyQueuedCancellations();
        while (scheduler.takeRunnable()) |handle| {
            if (control) |server| if (try server.resumeRunnable(handle)) continue;
            try reload.resumeRunnable(handle);
        }
        if (control) |server| try server.serviceRequests();
        if (reload.active().vm.exit_code != null and !reload.active().stdio.hasPendingOutput()) return false;
        if (development and sequence == null) if (requests.take()) |value| {
            if (try beginReload(reload, control, value)) sequence = value;
        };
        if (sequence) |value| {
            if (reload.takeCandidateFailure()) |err| {
                try reportReloadFailure(reload, control, value, err);
                sequence = null;
            } else if (reload.candidateReady()) {
                try servicePreparedReload(reload, &.{}, &.{}, callbacks, control, value, null);
                sequence = null;
            }
        }
        try reload.beginRetirement();
        _ = reload.collectRetired();
        const app = &reload.active().application;
        if (!stay_headless and desktop.flag(app.state, app.desktop_state, "requested")) return true;
        const development_work = if (development and control != null)
            try development_service.poll(control.?, reload, &.{})
        else
            false;
        if (control) |server| try server.serviceRequests();
        try reload.collectCanceledMcp();
        _ = try loop.submit();
        if (scheduler.hasPendingWork() or development_work) continue;
        _ = try dispatchApplication(reload, loop, control, null, null);
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
        try reload.collectCanceledMcp();
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

const NativeDrain = struct {
    host: *platform.wayland.Host,
    popups: *PopupHost,
    clipboard: *clipboard_module.Coordinator,
    drop_request: ?core.Handle = null,
};

fn drainSources(reload: *SourceReload, loop: *io_loop.Loop, control: ?*ControlServer, native: ?NativeDrain) !void {
    // Error unwinding must perform the same ownership retirement as ordinary
    // application exit. Keep every shared-ring owner alive until it is drained.
    const host = if (native) |value| value.host else null;
    if (native) |value| {
        try value.host.beginShutdown();
        if (value.drop_request) |request| _ = try value.host.cancelClipboard(request);
        for (value.popups.slots) |*slot| {
            slot.desired = false;
            try slot.runtime.clear(&reload.active().ui_build);
        }
        for (value.popups.slots) |*slot| value.popups.release(slot);
    }
    if (control) |server| try server.beginShutdown();
    if (reload.appearance) |client| try client.stop();
    reload.active().shutdownImages();
    if (reload.candidate) |candidate| candidate.shutdownImages();
    reload.active().dbus.shutdown();
    if (reload.candidate) |candidate| candidate.dbus.shutdown();
    try reload.active().http.stop();
    if (reload.candidate) |candidate| try candidate.http.stop();
    reload.active().auth.stop();
    reload.active().audio.stop();
    if (reload.active().session) |*binding| binding.stop();
    if (reload.candidate) |candidate| {
        candidate.auth.stop();
        candidate.audio.stop();
        if (candidate.session) |*binding| binding.stop();
    }
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
        if (native) |value| {
            // Configure/input events can already be queued when rendering
            // fails. Release their owned data without re-entering the UI.
            while (value.popups.windows.takeEvent()) |event| value.popups.windows.releaseEvent(event);
            while (value.clipboard.takeAction()) |action| {
                defer value.clipboard.releaseAction(action);
                if (action == .cancel_paste) {
                    if (!(try value.host.cancelClipboard(action.cancel_paste)))
                        try value.clipboard.acknowledgeCancellation(action.cancel_paste);
                }
            }
            while (value.host.takeClipboardCompletion()) |completion| {
                try value.clipboard.completePaste(completion.request, null);
                try value.host.releaseClipboardCompletion(completion.request);
            }
            while (value.host.takeDropCompletion()) |completion| try value.host.finishDrop(completion.request, false);
            while (value.clipboard.takeCompletion()) |completion| try value.clipboard.releaseCompletion(completion.request);
            try value.clipboard.collectCanceled();
            for (value.popups.slots) |*slot| try slot.runtime.collectRetired();
            try value.popups.windows.reconcile(&.{});
            try value.host.flush();
        }
        if (control) |server| server.collectClosed();
        _ = try loop.submit();
        const host_quiescent = if (host) |value| value.quiescent() else true;
        const windows_quiescent = if (native) |value| value.popups.windows.retainedCount() == 0 else true;
        const control_quiescent = if (control) |server| server.quiescent() else true;
        if (host_quiescent and windows_quiescent and control_quiescent and
            !loop.hasPendingOperations() and !loop.hasPendingTimerKernelWork()) break;
        if (reload.scheduler.hasPendingWork() or
            (host_quiescent and control_quiescent and !loop.hasPendingOperations() and !loop.hasPendingTimerKernelWork())) continue;
        _ = try dispatchApplication(reload, loop, control, host, null);
    }
}

fn appearanceScheme(snapshot: appearance_module.Snapshot) @import("../lua/theme.zig").ColorScheme {
    return switch (snapshot.color_scheme) {
        .default, .light => .light,
        .dark => .dark,
    };
}

fn finishInitialBootstrap(
    generation: *SourceGeneration,
    scheduler: *task.Scheduler,
    loop: *io_loop.Loop,
    diagnostic: *?lua.Diagnostic,
) !void {
    while (!generation.application_ready or generation.desktop_task != null) {
        if (try loop.receivedSignal() != null) return error.ApplicationInterrupted;
        // The task safe point, as in the main loop: without it, retired scopes
        // never ask parked external waits to cancel during bootstrap.
        try scheduler.applyQueuedCancellations();
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
        if ((generation.application_ready and generation.desktop_task == null) or
            (generation.vm.exit_code != null and !generation.stdio.hasPendingOutput())) return;
        try generation.collectCanceledMcp();
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| if (!(try generation.dispatchFile(completion)))
                return error.UnownedIoCompletion,
            .socket => |completion| if (!(try generation.dispatchSocket(completion)))
                return error.UnownedIoCompletion,
            .operation_cancel => try generation.collectCanceledMcp(),
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout| {
                if (!(try generation.dispatchTimer(timeout.operation))) return error.UnownedIoCompletion;
            },
            .signal_wakeup => {},
            else => return error.UnexpectedBootstrapCompletion,
        }
    }
}

fn drainInitialGeneration(generation: *SourceGeneration, scheduler: *task.Scheduler, loop: *io_loop.Loop) !void {
    generation.shutdownImages();
    generation.dbus.shutdown();
    generation.auth.stop();
    generation.audio.stop();
    try generation.http.stop();
    if (generation.session) |*binding| binding.stop();
    try generation.vm.requestCancellation();
    while (true) {
        try scheduler.applyQueuedCancellations();
        while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
        try generation.collectCanceledMcp();
        _ = try loop.submit();
        // Completing canceled external waits schedules their Lua close guards.
        // Run those before waiting on a peer that may never send another byte.
        if (scheduler.hasPendingWork()) continue;
        if (!loop.hasPendingOperations() and !loop.hasPendingTimerKernelWork()) return;
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| if (!(try generation.dispatchFile(completion))) return error.UnownedIoCompletion,
            .socket => |completion| if (!(try generation.dispatchSocket(completion))) return error.UnownedIoCompletion,
            .operation_cancel => try generation.collectCanceledMcp(),
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout| {
                if (!(try generation.dispatchTimer(timeout.operation))) return error.UnownedIoCompletion;
            },
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
    if (reload.services) |services| if (services.session) |session| {
        if (session.blocksReload()) {
            try reportReloadFailure(reload, control, request_sequence, error.SessionLockActive);
            return false;
        }
    };
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
    native: ?ReloadNativeContext,
) !void {
    var candidate_pending = true;
    defer if (candidate_pending) reload.discard();

    const candidate = reload.candidate.?;
    if (reload.services) |services| if (services.session) |session| {
        if (session.blocksReload()) {
            try reportReloadFailure(reload, control, request_sequence, error.SessionLockActive);
            return;
        }
    };
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
    var prepared_slots: ?PreparedRuntimeSlots = if (native) |context|
        PreparedRuntimeSlots.init(reload, slots, target_storage, context) catch |err| {
            try reportReloadFailure(reload, control, request_sequence, err);
            return;
        }
    else
        null;
    defer if (prepared_slots) |*prepared| prepared.deinit();
    const targets = if (prepared_slots) |prepared| target_storage[0..prepared.target_count] else target_storage[0..0];
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
    if (control) |server| server.commitApplication(&prepared_control.?);
    if (prepared_slots) |*prepared| {
        prepared.commit() catch |err| {
            // Local ownership has committed. Never claim that a transport or
            // native allocation failure rolled back already-issued requests.
            const context = native.?;
            std.log.err("source generation {d} committed, but native window commit failed; shutting down: {s}", .{ committed.generation, @errorName(err) });
            context.host.failure = err;
            try context.host.beginShutdown();
            for (slots) |*slot| {
                slot.desired = false;
                if (slot.id) |id| if (context.windows.handleForId(id)) |handle|
                    try context.windows.markClosed(handle);
            }
            if (control) |server| try server.reloadFailed(request_sequence, null, error.NativeWindowCommitFailed);
            return;
        };
    }
    if (control) |server| {
        try server.reloadSucceeded(request_sequence, committed.generation);
    }
    std.log.info(
        "source reload request {d} committed generation {d}",
        .{ request_sequence, committed.generation },
    );
}

const ReloadNativeContext = struct {
    windows: *windows_module.WindowSet,
    host: *platform.wayland.Host,
    dirty: *ui.instance.ReconcileQueue,
    clipboard: *clipboard_module.Coordinator,
    config: WindowRuntimeConfig,
};

/// Runtime addresses must never move: trees, signals and build owners borrow
/// them. Reserve unused slots in place, then either publish or dismantle only
/// those reservations. Existing slots are unchanged until commit.
const PreparedRuntimeSlots = struct {
    const Scratch = struct { runtime: WindowRuntime = .{}, scope: ?task.ScopeHandle = null };
    reload: *SourceReload,
    candidate: *SourceGeneration,
    context: ReloadNativeContext,
    slots: []RuntimeSlot,
    reserved: []bool,
    scratch: []Scratch,
    declarations: []platform.window.SurfaceDeclaration,
    windows: windows_module.WindowSet.Prepared,
    target_count: usize = 0,
    committed: bool = false,

    fn init(
        reload: *SourceReload,
        slots: []RuntimeSlot,
        targets: []source_reload_module.WindowTarget,
        context: ReloadNativeContext,
    ) !PreparedRuntimeSlots {
        const allocator = reload.allocator;
        const candidate = reload.candidate.?;
        if (candidate.application.windows.len > slots.len) return error.WindowCapacityExceeded;
        const declarations = try allocator.alloc(platform.window.SurfaceDeclaration, candidate.application.windows.len);
        errdefer allocator.free(declarations);
        var declaration_count: usize = 0;
        for (candidate.application.windows) |window| {
            if (runtimeSlotForId(slots, window.declaration.id())) |slot| {
                if (slot.declared and !slot.desired) continue;
                if (!slot.declared) return error.SourceWindowRetiring;
            }
            declarations[declaration_count] = window.declaration;
            declaration_count += 1;
        }
        var windows = try context.windows.prepare(declarations[0..declaration_count]);
        errdefer windows.deinit();
        const reserved = try allocator.alloc(bool, slots.len);
        errdefer allocator.free(reserved);
        @memset(reserved, false);
        const scratch = try allocator.alloc(Scratch, candidate.application.windows.len);
        errdefer allocator.free(scratch);
        @memset(scratch, .{});
        var prepared: PreparedRuntimeSlots = .{
            .reload = reload,
            .candidate = candidate,
            .context = context,
            .slots = slots,
            .reserved = reserved,
            .scratch = scratch,
            .declarations = declarations,
            .windows = windows,
        };
        errdefer prepared.clearReservations();
        for (candidate.application.windows, 0..) |window, index| {
            const id = window.declaration.id();
            const slot = runtimeSlotForId(slots, id) orelse blk: {
                for (slots, 0..) |*slot, slot_index| if (slot.id == null) {
                    slot.id = try allocator.dupe(u8, id);
                    reserved[slot_index] = true;
                    break :blk slot;
                };
                return error.WindowCapacityExceeded;
            };
            const handle = prepared.windows.handleForId(id);
            const suppressed = slot.declared and !slot.desired or handle == null;
            const runtime = if (suppressed) &scratch[index].runtime else &slot.runtime;
            if (!runtime.initialized) {
                const scope = if (suppressed) blk: {
                    scratch[index].scope = try reload.scheduler.createScope(reload.scheduler.application_scope);
                    break :blk scratch[index].scope.?;
                } else prepared.windows.scope(handle.?);
                const theme = candidate.ui_build.widget_theme.?.colors;
                const services = candidate.services.?;
                // commitPreparedSource detaches the runtime's old graph before
                // adopting the candidate. Even empty new runtimes must start
                // on the old graph, or commit would erase freshly built edges.
                const signals = if (suppressed) &candidate.signals else &reload.active().signals;
                try runtime.init(allocator, reload.scheduler, scope, handle orelse .invalid, theme.background, theme.primary, theme.foreground, theme.input, theme.ring, signals, services.paragraph_sources, services.paragraphs, context.config);
            }
            if (prepared.target_count == targets.len) return error.WindowCapacityExceeded;
            targets[prepared.target_count] = .{
                .id = id,
                .runtime = runtime,
                .size = slot.configured_size orelse runtime.frame_state.size orelse .{
                    .width = @max(1, window.declaration.initialWidth()),
                    .height = @max(1, window.declaration.initialHeight()),
                },
                .disposition = if (suppressed) .validate_only else .retain,
            };
            prepared.target_count += 1;
        }
        for (slots) |*slot| {
            const id = slot.id orelse continue;
            if (applicationWindowForId(candidate.application.windows, id) != null) continue;
            if (prepared.target_count == targets.len) return error.WindowCapacityExceeded;
            targets[prepared.target_count] = .{ .id = id, .runtime = &slot.runtime, .size = .{ .width = 1, .height = 1 }, .disposition = .remove };
            prepared.target_count += 1;
        }
        return prepared;
    }

    fn clearReservations(self: *PreparedRuntimeSlots) void {
        for (self.scratch) |*scratch| {
            scratch.runtime.clear(&self.candidate.ui_build) catch unreachable;
            scratch.runtime.collectRetired() catch unreachable;
            scratch.runtime.deinit();
            if (scratch.scope) |scope| self.reload.scheduler.destroyScope(scope) catch unreachable;
        }
        if (!self.committed) for (self.slots, self.reserved) |*slot, reserved| {
            if (!reserved) continue;
            slot.runtime.signals = &self.candidate.signals;
            slot.runtime.clear(&self.candidate.ui_build) catch unreachable;
            slot.runtime.collectRetired() catch unreachable;
            slot.runtime.deinit();
            self.reload.allocator.free(slot.id.?);
            slot.* = .{};
        };
    }

    fn deinit(self: *PreparedRuntimeSlots) void {
        self.clearReservations();
        self.windows.deinit();
        self.reload.allocator.free(self.scratch);
        self.reload.allocator.free(self.reserved);
        self.reload.allocator.free(self.declarations);
    }

    fn commit(self: *PreparedRuntimeSlots) !void {
        self.committed = true;
        for (self.slots) |*slot| {
            const id = slot.id orelse continue;
            const window = applicationWindowForId(self.candidate.application.windows, id);
            const declared = window != null;
            slot.content_reference = if (window) |value| value.content_reference else lua_c.no_reference;
            slot.content_changed = false;
            if (!declared) {
                slot.desired = false;
                if (slot.runtime.registered) {
                    self.context.dirty.unregister(slot.runtime.window) catch unreachable;
                    slot.runtime.registered = false;
                }
            } else if (!slot.declared) {
                slot.desired = true;
                self.context.dirty.register(slot.runtime.window) catch unreachable;
                slot.runtime.registered = true;
                slot.runtime.setDirtyWindowQueue(self.context.dirty);
                slot.runtime.setClipboardCoordinator(self.context.clipboard);
            }
            slot.declared = declared;
        }
        try self.windows.commit();
    }
};

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
        target.content_changed = target.declared and
            target.content_reference != declaration.content_reference;
        target.content_reference = declaration.content_reference;
        if (!target.declared) {
            target.desired = true;
            target.frames_seen = 0;
        }
        target.next_declared = true;
    }
    for (slots) |*slot| {
        if (slot.popup != null) continue;
        if (slot.declared and !slot.next_declared) {
            slot.desired = false;
            slot.content_reference = lua_c.no_reference;
            slot.content_changed = false;
        }
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

fn popupKeyboard(slots: []RuntimeSlot, event: platform.window.KeyboardEvent) platform.window.KeyboardEvent {
    const source = keyboardWindow(event);
    for (slots) |slot| if (slot.desired) {
        const popup = slot.popup orelse continue;
        const input = popup.window.declaration.popup.input orelse continue;
        if (!sameHandle(input.window, source)) continue;
        var routed = event;
        switch (routed) {
            .enter => |*value| value.window = popup.handle,
            .leave => |*value| value.window = popup.handle,
            .key => |*value| {
                value.source_window = source;
                value.window = popup.handle;
            },
        }
        return routed;
    };
    return event;
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

test "render failure drains native and application owners before returning original error" {
    const allocator = std.testing.allocator;
    const protocol = @import("wayland_protocol");
    const Host = platform.wayland.Host;
    const linux = std.os.linux;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "app.lua", .data =
        \\local o = require('ouro')
        \\return o.app { id='dev.ouro.drain-test', run=function() return {windows={
        \\  o.window {id='main', title='Drain', width=300, height=40, content=function() return o.column{key='root'} end}
        \\}} end }
    });
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "app.lua" });
    defer allocator.free(path);
    var provider = try bundle.SourceProvider.initDisk(allocator, path);
    defer provider.deinit();
    var loop: io_loop.Loop = undefined;
    try loop.init(allocator, 32, 16);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(allocator, 128, 16, 32);
    defer scheduler.deinit();
    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(allocator, 16);
    defer callbacks.deinit();
    var clipboard: clipboard_module.Coordinator = undefined;
    try clipboard.init(allocator, &scheduler, 4, 8, 256);
    defer clipboard.deinit();
    var fonts = text.FontCache.init(allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{ .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 }, .bytes = @embedFile("ourokit_test_font_static") });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(allocator, &fonts);
    defer paragraphs.deinit();
    const theme = design.tokens.light;
    const services: source_generation.UiServices = .{
        .paragraph_sources = &sources,
        .paragraphs = &paragraphs,
        .font_candidates = &.{font},
        .medium_font_candidates = &.{font},
        .color_scheme = .light,
        .callbacks = &callbacks,
    };
    const config: source_generation.Config = .{ .node_capacity = 8, .semantic_text_capacity = 128 };
    const initial = try SourceGeneration.create(allocator, &scheduler, &loop, try provider.snapshot(std.testing.io, allocator), services, config, null);
    var reload: SourceReload = undefined;
    reload.init(allocator, std.testing.io, &provider, &scheduler, &loop, services, config, initial);
    defer reload.deinit();

    var windows: windows_module.WindowSet = undefined;
    var host: Host = .{
        .allocator = allocator,
        .loop = &loop,
        .sink = windows.eventSink(),
        .app_id = try allocator.dupe(u8, "dev.ouro.drain-test"),
        .vulkan = null,
        .adapter = undefined,
        .connection = undefined,
        .driver = undefined,
        .registry = undefined,
        .text_input_pending = @FieldType(Host, "text_input_pending").init(allocator),
        .clipboard = try @FieldType(Host, "clipboard").init(allocator, &loop, 4, 4, 4, 4, 256),
        .xkb = try @FieldType(Host, "xkb").init(),
        .windows = try allocator.alloc(std.meta.Child(@FieldType(Host, "windows")), 1),
        .outputs = try allocator.alloc(std.meta.Child(@FieldType(Host, "outputs")), 1),
    };
    @memset(host.windows, .{});
    @memset(host.outputs, .{});
    try host.adapter.init(allocator, &loop, (platform.wayland.HostConfig{ .app_id = "test" }).reactor);
    var sockets: [2]linux.fd_t = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets)) != .SUCCESS) return error.SocketFailed;
    defer _ = linux.close(sockets[1]);
    host.connection = try @FieldType(Host, "connection").attach(allocator, &host.adapter.reactor, sockets[0], .{
        .received_fd_budget = 4,
        .transmit_byte_budget = 4096,
        .transmit_fd_budget = 4,
    }, .{ .max_objects = 64, .max_client_ids = 64 });
    host.driver = @FieldType(Host, "driver").init(&host.connection);
    defer host.deinit();
    const objects = &host.connection.objects;
    host.registry = try objects.createLocal(&protocol.wl_registry.info, 1, null);
    host.compositor = try objects.createLocal(&protocol.wl_compositor.info, 4, null);
    host.wm_base = try objects.createLocal(&protocol.xdg_wm_base.info, 5, null);
    try windows.init(allocator, &scheduler, host.nativeHost(), 1, 8);
    defer windows.deinit();
    try windows.reconcile(&.{initial.application.windows[0].declaration});
    const handle = windows.activeHandleForId("main").?;
    var slots = [_]RuntimeSlot{.{ .id = try allocator.dupe(u8, "main"), .desired = true }};
    defer allocator.free(slots[0].id.?);
    const runtime = &slots[0].runtime;
    try runtime.init(allocator, &scheduler, try windows.scope(handle), handle, theme.background, theme.primary, theme.foreground, theme.input, theme.ring, &initial.signals, &sources, &paragraphs, .{ .node_capacity = 8, .command_capacity = 16 });
    defer runtime.deinit();
    try runtime.reconcile(.{ .width = 300, .height = 40 }, &initial.ui_build, initial.application.windows[0].content_reference);
    try std.testing.expect(runtime.ready);
    var popups: PopupHost = .{ .allocator = allocator, .windows = &windows, .host = &host, .callbacks = &callbacks, .slots = &slots };

    var environment_map: std.process.Environ.Map = .init(allocator);
    defer environment_map.deinit();
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    try environment_map.put("XDG_RUNTIME_DIR", directory);
    const environ: std.process.Environ = .{ .block = try environment_map.createPosixBlock(allocator, .{}) };
    defer environ.block.deinit(allocator);
    var requests: ReloadRequests = .{};
    var control: ControlServer = undefined;
    try control.init(allocator, &loop, environ, "dev.ouro.drain-test", 1, &requests, true);
    defer control.deinit();
    _ = try initial.vm.spawnApplication("require('ouro').sleep(60000); error('canceled task resumed')");
    while (scheduler.takeRunnable()) |runnable| try reload.resumeRunnable(runnable);
    // Clipboard pipes share the application CQE namespace but belong to the
    // native host. Keep a paste and runner-owned drop blocked on input too.
    const paste = try clipboard.requestPaste(try windows.scope(handle), .{ .window = handle, .text_input = .invalid });
    const paste_action = clipboard.takeAction().?;
    try std.testing.expectEqual(paste, paste_action.request_paste.request);
    clipboard.releaseAction(paste_action);
    const drop: core.Handle = .{ .slot = std.math.maxInt(u32), .generation = 1 };
    var writers: [2]linux.fd_t = undefined;
    for ([_]core.Handle{ paste, drop }, 0..) |request, index| {
        var pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
        writers[index] = pipe[1];
        const transfer = &host.clipboard.transfers[index];
        transfer.* = .{ .request = request, .fd = pipe[0], .drag = index == 1 };
        transfer.operation = try loop.prepareRead(pipe[0], &transfer.scratch, std.math.maxInt(u64));
        transfer.state = .reading;
    }
    defer for (writers) |fd| {
        _ = linux.close(fd);
    };
    var configure: [12]u8 = undefined;
    std.mem.writeInt(u32, configure[0..4], host.windows[0].xdg_surface.?.id, .little);
    std.mem.writeInt(u32, configure[4..8], 12 << 16, .little);
    std.mem.writeInt(u32, configure[8..12], 73, .little);
    try std.testing.expectEqual(configure.len, linux.write(sockets[1], &configure, configure.len));
    try host.flush();
    const actor = try host.connection.actor();
    try std.testing.expect(actor.receive_active);
    try std.testing.expect(actor.transmit.sendActive());
    try std.testing.expect(loop.hasPendingOperations()); // Control accept.
    try std.testing.expect(loop.hasPendingTimerKernelWork()); // Application sleep.
    // Match the unconsumed configure found during the original unwind.
    try windows.enqueueConfigured(handle, 300, 40);
    try windows.enqueueTextInput(.{ .batch = .{ .window = handle, .serial = 72, .serial_matches_state = true, .delete_surrounding = null, .commit = .{ .text = "queued input" }, .preedit = null } });
    host.windows[0].configured = true;
    host.windows[0].width = 0; // Inject a real extent-validation failure.
    const Failure = struct {
        fn run(reload_: *SourceReload, loop_: *io_loop.Loop, control_: *ControlServer, native: NativeDrain, handle_: core.Handle) !void {
            defer drainSources(reload_, loop_, control_, native) catch unreachable;
            try native.host.prepareScene(handle_, .{ .commands = &.{} });
        }
    };
    try std.testing.expectError(error.InvalidScaledExtent, Failure.run(&reload, &loop, &control, .{ .host = &host, .popups = &popups, .clipboard = &clipboard, .drop_request = drop }, handle));
    try std.testing.expect(host.quiescent());
    try std.testing.expect(control.quiescent());
    try std.testing.expectEqual(@as(usize, 0), windows.retainedCount());
    try std.testing.expectEqual(null, windows.takeEvent());
    try std.testing.expect(!loop.hasPendingOperations() and !loop.hasPendingTimerKernelWork());
    try std.testing.expect(!runtime.ready);
    try std.testing.expect(!scheduler.hasPendingWork());
    try std.testing.expectEqual(@as(usize, 0), initial.vm.activeTaskCount());
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
    try std.testing.expect(!main.content_changed and !tools.content_changed);

    var changed = reordered;
    changed[0].content_reference = 3;
    try syncRuntimeSlots(std.testing.allocator, &slots, &changed);
    try std.testing.expect(!main.content_changed);
    try std.testing.expect(tools.content_changed);

    try syncRuntimeSlots(std.testing.allocator, &slots, initial[1..]);
    try std.testing.expect(!main.declared and !main.desired);
    try std.testing.expect(tools.declared and tools.desired);
    try syncRuntimeSlots(std.testing.allocator, &slots, &initial);
    try std.testing.expect(main.declared and main.desired);
    try std.testing.expectEqual(@as(usize, 0), main.frames_seen);
}

test "layer popup keyboard routing isolates parent and preserves physical provenance" {
    const parent: core.Handle = .{ .slot = 3, .generation = 7 };
    const child: core.Handle = .{ .slot = 9, .generation = 2 };
    var slots = [_]RuntimeSlot{.{ .desired = true, .popup = .{
        .window = .{ .declaration = .{ .popup = .{
            .id = "popup",
            .input = .{ .window = parent, .serial = 123 },
            .anchor = .{ .window = parent, .target = .invalid, .rectangle = .{ .x = 1, .y = 2, .width = 30, .height = 40 } },
            .width = 200,
            .height = 90,
        } }, .content_reference = -2 },
        .vm = undefined,
        .owner = .invalid,
        .resource = null,
        .content_lease = .invalid,
        .on_close = -2,
        .handle = child,
    } }};
    const key: platform.window.KeyboardEvent = .{ .key = .{
        .window = parent,
        .serial = 812,
        .time_ms = 43,
        .state = .pressed,
        .translated = .{ .keycode = 28, .logical = .enter },
    } };
    const routed = popupKeyboard(&slots, key);
    try std.testing.expectEqual(child, routed.key.window);
    try std.testing.expectEqual(parent, routed.key.source_window.?);
    try std.testing.expectEqual(@as(u32, 812), routed.key.serial);
    try std.testing.expectEqual(key.key.translated, routed.key.translated);
    var unrelated = key;
    unrelated.key.window.generation += 1;
    try std.testing.expectEqualDeep(unrelated, popupKeyboard(&slots, unrelated));
    var direct = key;
    direct.key.window = child;
    try std.testing.expectEqualDeep(direct, popupKeyboard(&slots, direct));
    slots[0].popup.?.window.declaration.popup.input = null;
    try std.testing.expectEqualDeep(key, popupKeyboard(&slots, key));
    slots[0].desired = false;
    try std.testing.expectEqualDeep(key, popupKeyboard(&slots, key));
}

test "structural reload validates later additions and capacity before retaining removing or creating windows" {
    const TestHost = struct {
        creates: usize = 0,
        updates: usize = 0,
        closes: usize = 0,
        fn create(context: *anyopaque, _: core.Handle, _: task.ScopeHandle, _: platform.window.SurfaceDeclaration) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.creates += 1;
        }
        fn title(context: *anyopaque, _: core.Handle, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.updates += 1;
        }
        fn minimum(_: *anyopaque, _: core.Handle, _: u32, _: u32) !void {}
        fn layer(_: *anyopaque, _: core.Handle, _: platform.window.LayerSurfaceDeclaration) !void {}
        fn close(context: *anyopaque, _: core.Handle) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.closes += 1;
        }
        const vtable: platform.window.NativeHost.VTable = .{
            .create = create,
            .update_title = title,
            .update_minimum_size = minimum,
            .update_layer_surface = layer,
            .begin_close = close,
        };
    };
    const Source = struct {
        fn write(dir: std.Io.Dir, declarations: []const u8) !void {
            const source = try std.mem.concat(std.testing.allocator, u8, &.{
                \\local ouro = require('ouro')
                \\local function window(id, label, fail)
                \\  local value = ouro.signal(label)
                \\  return ouro.window { id=id, title=label, width=320, height=200, content=function()
                \\    if fail then error('late new window failed') end
                \\    return ouro.button { key='button', label=value(), on_press=function() value:set('Pressed') end }
                \\  end }
                \\end
                \\return ouro.app { id='dev.ouro.structural-test', run=function() return {windows={
                ,
                declarations,
                "}} end}",
            });
            defer std.testing.allocator.free(source);
            try dir.writeFile(std.testing.io, .{ .sub_path = "app.lua", .data = source });
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try Source.write(temporary.dir, "window('keep','Old'), window('remove','Gone')");
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "app.lua" });
    defer std.testing.allocator.free(path);
    var provider = try bundle.SourceProvider.initDisk(std.testing.allocator, path);
    defer provider.deinit();
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 128, 8, 8);
    defer scheduler.deinit();
    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(std.testing.allocator, 32);
    defer callbacks.deinit();
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{ .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 }, .bytes = @embedFile("ourokit_test_font_static") });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const services: source_generation.UiServices = .{
        .paragraph_sources = &sources,
        .paragraphs = &paragraphs,
        .font_candidates = &.{font},
        .medium_font_candidates = &.{font},
        .color_scheme = .light,
        .callbacks = &callbacks,
    };
    const config: source_generation.Config = .{ .node_capacity = 16, .semantic_text_capacity = 256 };
    const initial = try SourceGeneration.create(std.testing.allocator, &scheduler, &loop, try provider.snapshot(std.testing.io, std.testing.allocator), services, config, null);
    var reload: SourceReload = undefined;
    reload.init(std.testing.allocator, std.testing.io, &provider, &scheduler, &loop, services, config, initial);
    defer reload.deinit();
    var host: TestHost = .{};
    var windows: windows_module.WindowSet = undefined;
    try windows.init(std.testing.allocator, &scheduler, .{ .context = &host, .vtable = &TestHost.vtable }, 4, 8);
    defer windows.deinit();
    var dirty: ui.instance.ReconcileQueue = undefined;
    try dirty.init(std.testing.allocator, 4);
    defer dirty.deinit();
    var clipboard: clipboard_module.Coordinator = undefined;
    try clipboard.init(std.testing.allocator, &scheduler, 1, 1, 256);
    defer clipboard.deinit();
    const context: ReloadNativeContext = .{ .windows = &windows, .host = undefined, .dirty = &dirty, .clipboard = &clipboard, .config = .{ .node_capacity = 16, .command_capacity = 16 } };
    var slots = [_]RuntimeSlot{.{}} ** 4;
    defer {
        for (&slots) |*slot| {
            slot.runtime.clear(&reload.active().ui_build) catch unreachable;
            if (slot.id) |id| if (windows.handleForId(id)) |native_handle| windows.markClosed(native_handle) catch unreachable;
        }
        scheduler.applyQueuedCancellations() catch unreachable;
        for (&slots) |*slot| {
            slot.runtime.collectRetired() catch unreachable;
            slot.runtime.deinit();
            if (slot.id) |id| std.testing.allocator.free(id);
        }
        windows.reconcile(&.{}) catch unreachable;
    }
    var targets: [4]source_reload_module.WindowTarget = undefined;
    try reload.prepare();
    {
        var prepared = try PreparedRuntimeSlots.init(&reload, &slots, &targets, context);
        defer prepared.deinit();
        try reload.prepareApplication(targets[0..prepared.target_count]);
        _ = try reload.commitApplication(targets[0..prepared.target_count], &callbacks);
        try prepared.commit();
    }
    try reload.beginRetirement();
    try std.testing.expectEqual(@as(usize, 1), reload.collectRetired());
    const active = reload.active();
    const keep = runtimeSlotForId(&slots, "keep").?;
    const removed = runtimeSlotForId(&slots, "remove").?;
    try std.testing.expectEqual(applicationWindowForId(active.application.windows, "keep").?.content_reference, keep.content_reference);
    try syncRuntimeSlots(std.testing.allocator, &slots, active.application.windows);
    try std.testing.expect(!keep.content_changed and !removed.content_changed);
    const handle = keep.runtime.window;
    const scope = try windows.scope(handle);
    const button_id = (try keep.runtime.semantics.findPath("button")).id;
    const button = keep.runtime.instances.handleForId(button_id).?;
    const old_handler = keep.runtime.pointer_bindings.get(button).?;
    _ = try keep.runtime.focus.request(&keep.runtime.instances, button);
    try keep.runtime.prepareFrame(1);
    const commands = try std.testing.allocator.dupe(@import("../scene/root.zig").Command, keep.runtime.commands[0..keep.runtime.command_count]);
    defer std.testing.allocator.free(commands);
    const old_callbacks = callbacks.countForVm(&active.vm);
    const available_scopes = scheduler.availableScopeCapacity();
    try std.testing.expect(old_callbacks > 1);

    // A valid addition and retained-window edit precede the failing addition.
    try Source.write(temporary.dir, "window('new-first','New'), window('keep','Changed'), window('new-late','Bad',true)");
    try reload.prepare();
    {
        var prepared = try PreparedRuntimeSlots.init(&reload, &slots, &targets, context);
        defer prepared.deinit();
        var failed = false;
        reload.prepareApplication(targets[0..prepared.target_count]) catch {
            failed = true;
        };
        try std.testing.expect(failed);
    }
    try reload.beginRetirement();
    try std.testing.expectEqual(@as(usize, 1), reload.collectRetired());
    try std.testing.expect(reload.active() == active);
    try std.testing.expectEqual(@as(usize, 2), host.creates);
    try std.testing.expectEqual(@as(usize, 0), host.updates);
    try std.testing.expectEqual(@as(usize, 0), host.closes);
    try std.testing.expect(runtimeSlotForId(&slots, "new-first") == null);
    try std.testing.expectEqual(available_scopes, scheduler.availableScopeCapacity());
    try std.testing.expectEqual(old_callbacks, callbacks.countForVm(&active.vm));
    try std.testing.expectEqualDeep(old_handler, keep.runtime.pointer_bindings.get(button).?);
    try std.testing.expectEqualStrings("Old", (try keep.runtime.semantics.findPath("button")).label);
    try std.testing.expectEqualStrings("Gone", (try removed.runtime.semantics.findPath("button")).label);
    try std.testing.expectEqualDeep(commands, keep.runtime.commands[0..keep.runtime.command_count]);
    try std.testing.expectEqual(button, keep.runtime.focus.current().?);

    // Each tree fits independently, but the application-wide sum does not.
    try Source.write(temporary.dir, "window('new-first','New'), window('keep','Changed'), window('new-late','Later')");
    try reload.prepare();
    {
        var prepared = try PreparedRuntimeSlots.init(&reload, &slots, &targets, context);
        defer prepared.deinit();
        try reload.prepareApplication(targets[0..prepared.target_count]);
        const per_window = reload.candidate.?.prepared_builds[0].descriptors().len;
        var held: [128]task.ScopeHandle = undefined;
        var held_count: usize = 0;
        while (scheduler.availableScopeCapacity() > per_window) : (held_count += 1)
            held[held_count] = try scheduler.createScope(scheduler.application_scope);
        defer for (held[0..held_count]) |held_scope| scheduler.destroyScope(held_scope) catch unreachable;
        try std.testing.expectError(error.ScopeCapacityExceeded, reload.commitApplication(targets[0..prepared.target_count], &callbacks));
        try std.testing.expect(reload.active() == active);
        try std.testing.expectEqual(old_callbacks, callbacks.countForVm(&active.vm));
        try std.testing.expectEqualDeep(commands, keep.runtime.commands[0..keep.runtime.command_count]);
        reload.discard();
    }
    try reload.beginRetirement();
    try std.testing.expectEqual(@as(usize, 1), reload.collectRetired());

    try Source.write(temporary.dir, "window('new-first','New'), window('keep','Changed')");
    try reload.prepare();
    {
        var prepared = try PreparedRuntimeSlots.init(&reload, &slots, &targets, context);
        defer prepared.deinit();
        try reload.prepareApplication(targets[0..prepared.target_count]);
        _ = try reload.commitApplication(targets[0..prepared.target_count], &callbacks);
        try prepared.commit();
    }
    try std.testing.expectEqual(handle, windows.activeHandleForId("keep").?);
    try std.testing.expectEqual(scope, try windows.scope(handle));
    try std.testing.expect(keep == runtimeSlotForId(&slots, "keep").?);
    try std.testing.expectEqual(button, keep.runtime.instances.handleForId(button_id).?);
    try std.testing.expectEqual(button, keep.runtime.focus.current().?);
    try std.testing.expectEqualStrings("Changed", (try keep.runtime.semantics.findPath("button")).label);
    try std.testing.expectEqualStrings("New", (try runtimeSlotForId(&slots, "new-first").?.runtime.semantics.findPath("button")).label);
    try std.testing.expectEqual(@as(usize, 0), callbacks.countForVm(&active.vm));
    try std.testing.expect(!removed.runtime.ready and !removed.desired);
    try std.testing.expectEqual(@as(usize, 3), host.creates);
    try std.testing.expectEqual(@as(usize, 1), host.closes);
    try reload.beginRetirement();
    try scheduler.applyQueuedCancellations();
    for (&slots) |*slot| try slot.runtime.collectRetired();
    try std.testing.expectEqual(@as(usize, 1), reload.collectRetired());

    // A compositor-closed declaration remains suppressed across reload.
    const added = runtimeSlotForId(&slots, "new-first").?;
    // A new runtime must keep the candidate's dependency graph on commit.
    // Publishing its signal must notify the native dirty queue immediately,
    // without relying on a subsequent configure/rebuild to repair the graph.
    const added_button = added.runtime.instances.handleForId((try added.runtime.semantics.findPath("button")).id).?;
    try std.testing.expect(!(try dirty.hasPending(added.runtime.window)));
    _ = try callbacks.spawn(added.runtime.pointer_bindings.get(added_button).?.id, try windows.scope(added.runtime.window), &.{});
    while (scheduler.takeRunnable()) |runnable| try reload.resumeRunnable(runnable);
    try std.testing.expect(try dirty.hasPending(added.runtime.window));
    added.desired = false;
    try windows.markClosed(added.runtime.window);
    try added.runtime.clear(&reload.active().ui_build);
    try scheduler.applyQueuedCancellations();
    try added.runtime.collectRetired();
    try reload.prepare();
    {
        var prepared = try PreparedRuntimeSlots.init(&reload, &slots, &targets, context);
        defer prepared.deinit();
        try reload.prepareApplication(targets[0..prepared.target_count]);
        _ = try reload.commitApplication(targets[0..prepared.target_count], &callbacks);
        try prepared.commit();
    }
    try std.testing.expect(!added.desired and !added.runtime.ready);
    try std.testing.expect(windows.activeHandleForId("new-first") == null);
    try std.testing.expectEqual(@as(usize, 3), host.creates);
    try reload.beginRetirement();
    _ = reload.collectRetired();
}
