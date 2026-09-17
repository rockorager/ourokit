const std = @import("std");
const bundle = @import("../bundle/root.zig");
const design = @import("../design/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const shell = @import("../shell/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");
const image_service = @import("../image/service.zig");
const ImageCache = @import("../image/cache.zig").Cache;
const native = @import("../native/root.zig");

pub const Config = struct {
    /// Code and names remain borrowed through destruction of all generations.
    native_modules: []const native.Module = &.{},
    node_capacity: usize = 256,
    window_capacity: usize = 16,
    semantic_text_capacity: usize = 16 * 1024,
    signal_capacity: usize = 256,
    subscription_capacity: usize = 1024,
    dependency_capacity: usize = 256,
    module_capacity: usize = 64,
    mcp_call_capacity: usize = 16,
    /// Borrowed for the generation/config lifetime; copied into each Lua VM.
    runtime_dir: ?[]const u8 = null,
    /// Borrowed process environment; the D-Bus adapter copies bus addresses.
    environ: std.process.Environ = .empty,
    /// Immutable process configuration; absent in deterministic/export hosts.
    applications: ?*const @import("../xdg/applications.zig").Config = null,
    defer_run: bool = false,
};

pub const UiServices = struct {
    paragraph_sources: *text.ParagraphSourceCache,
    paragraphs: *text.ParagraphCache,
    /// Ordered candidates borrowed from the host for the services' lifetime.
    font_candidates: []const text.FontHandle,
    medium_font_candidates: []const text.FontHandle,
    theme: design.tokens.Theme,
    callbacks: *lua.CallbackRegistry,
    theme_fonts: ?*@import("../lua/theme_fonts.zig").ThemeFonts = null,
    workspaces: ?*shell.workspaces.Store = null,
    images: ?*ImageCache = null,
    icon_roots: []const []const u8 = &.{},
};

/// All Lua-owned meaning for one application source snapshot. This value and
/// its VM, Signals, and UiBuild fields must retain a stable address from init
/// through deinit because installed C closures point into them.
pub const SourceGeneration = struct {
    allocator: std.mem.Allocator,
    snapshot: bundle.SourceSnapshot,
    vm: lua.Vm,
    mcp_client: lua.McpClient,
    dbus: lua.Dbus,
    stdio: lua.Stdio,
    applications: lua.Applications,
    signals: lua.Signals,
    native_modules: ?native.Registry = null,
    window_owners: ?ui.instance.BuildOwners = null,
    window_owner: ui.instance.BuildOwnerHandle = .invalid,
    shell_workspaces: ?lua.ShellWorkspaces = null,
    descriptor_storage: []ui.instance.Descriptor,
    semantic_storage: []ui.semantics.Descriptor,
    callbacks: ?*lua.CallbackRegistry,
    ui_build: lua.UiBuild,
    application: lua.Application,
    prepared_builds: []lua.PreparedBuild,
    module_loader: ?lua.ModuleLoader = null,
    images: ?image_service.Service = null,
    asset_root: ?std.os.linux.fd_t = null,
    bootstrap: ?lua.ApplicationBootstrap = null,
    ui_task: ?lua.TaskHandle = null,
    application_ready: bool = false,
    services: ?UiServices = null,
    config: Config = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        loop: *io_loop.Loop,
        snapshot: bundle.SourceSnapshot,
        services: ?UiServices,
        config: Config,
        diagnostic: ?*?lua.Diagnostic,
    ) !*SourceGeneration {
        const generation = allocator.create(SourceGeneration) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                snapshot.entry_name,
                err,
            );
            var owned_snapshot = snapshot;
            owned_snapshot.deinit();
            return err;
        };
        errdefer allocator.destroy(generation);
        try generation.init(
            allocator,
            scheduler,
            loop,
            snapshot,
            services,
            config,
            diagnostic,
        );
        return generation;
    }

    pub fn init(
        self: *SourceGeneration,
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        loop: *io_loop.Loop,
        snapshot: bundle.SourceSnapshot,
        services: ?UiServices,
        config: Config,
        diagnostic: ?*?lua.Diagnostic,
    ) !void {
        return self.initMode(
            allocator,
            scheduler,
            loop,
            snapshot,
            services,
            config,
            diagnostic,
            null,
        );
    }

    pub fn createBootstrap(
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        loop: *io_loop.Loop,
        snapshot: bundle.SourceSnapshot,
        module_root: std.os.linux.fd_t,
        services: ?UiServices,
        config: Config,
        diagnostic: ?*?lua.Diagnostic,
    ) !*SourceGeneration {
        const generation = allocator.create(SourceGeneration) catch |err| {
            var owned_snapshot = snapshot;
            owned_snapshot.deinit();
            return err;
        };
        errdefer allocator.destroy(generation);
        try generation.initMode(
            allocator,
            scheduler,
            loop,
            snapshot,
            services,
            config,
            diagnostic,
            module_root,
        );
        return generation;
    }

    fn initMode(
        self: *SourceGeneration,
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        loop: *io_loop.Loop,
        snapshot: bundle.SourceSnapshot,
        services: ?UiServices,
        config: Config,
        diagnostic: ?*?lua.Diagnostic,
        module_root: ?std.os.linux.fd_t,
    ) !void {
        self.allocator = allocator;
        self.snapshot = snapshot;
        self.module_loader = null;
        self.native_modules = null;
        self.images = null;
        self.asset_root = module_root;
        self.shell_workspaces = null;
        self.bootstrap = null;
        self.ui_task = null;
        self.application_ready = false;
        self.window_owners = null;
        self.window_owner = .invalid;
        self.services = services;
        self.config = config;
        var vm_initialized = false;
        var mcp_client_initialized = false;
        var dbus_initialized = false;
        var stdio_initialized = false;
        var applications_initialized = false;
        var signals_initialized = false;
        var shell_workspaces_initialized = false;
        var descriptor_storage: ?[]ui.instance.Descriptor = null;
        var semantic_storage: ?[]ui.semantics.Descriptor = null;
        var application_initialized = false;
        var prepared_build_storage: ?[]lua.PreparedBuild = null;
        var prepared_build_count: usize = 0;
        var module_loader_initialized = false;
        errdefer {
            self.disposeWindowOwner();
            if (prepared_build_storage) |storage| {
                for (storage[0..prepared_build_count]) |*prepared| prepared.deinit();
                allocator.free(storage);
            }
            if (application_initialized) self.application.deinit();
            if (module_loader_initialized) self.module_loader.?.deinit();
            if (self.images) |*images| images.deinit();
            if (applications_initialized) self.applications.deinit();
            if (stdio_initialized) self.stdio.deinit();
            if (dbus_initialized) self.dbus.deinit();
            if (mcp_client_initialized) self.mcp_client.deinit();
            if (vm_initialized) self.vm.deinit();
            if (self.native_modules) |*modules| modules.deinit();
            if (shell_workspaces_initialized) self.shell_workspaces.?.deinit();
            if (signals_initialized) self.signals.deinit();
            if (semantic_storage) |storage| allocator.free(storage);
            if (descriptor_storage) |storage| allocator.free(storage);
            self.snapshot.deinit();
        }
        if (config.node_capacity == 0) {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                error.InvalidGenerationCapacity,
            );
            return error.InvalidGenerationCapacity;
        }

        self.vm.init(allocator, scheduler, loop) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        vm_initialized = true;
        self.mcp_client.init(
            allocator,
            &self.vm,
            loop,
            config.mcp_call_capacity,
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        mcp_client_initialized = true;
        try self.dbus.init(allocator, &self.vm, loop, config.environ);
        dbus_initialized = true;
        try self.stdio.init(allocator, &self.vm, loop, config.mcp_call_capacity);
        stdio_initialized = true;
        self.signals.initWithApi(
            allocator,
            self.vm.state,
            config.signal_capacity,
            config.subscription_capacity,
            config.dependency_capacity,
            self.vm.apiReference(),
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        signals_initialized = true;
        if (config.native_modules.len != 0) {
            var modules: native.Registry = undefined;
            modules.init(allocator, &self.vm, &self.signals, config.native_modules) catch |err| {
                lua.recordDiagnosticError(diagnostic, allocator, .setup, self.snapshot.entry_name, err);
                return err;
            };
            self.native_modules = modules;
        }
        if (services) |value| if (value.workspaces) |store| {
            self.shell_workspaces = @as(lua.ShellWorkspaces, undefined);
            self.shell_workspaces.?.init(
                self.vm.state,
                &self.signals,
                store,
                self.vm.apiReference(),
            ) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    allocator,
                    .setup,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            shell_workspaces_initialized = true;
        };

        self.descriptor_storage = allocator.alloc(
            ui.instance.Descriptor,
            config.node_capacity,
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        descriptor_storage = self.descriptor_storage;
        self.semantic_storage = allocator.alloc(
            ui.semantics.Descriptor,
            config.node_capacity,
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        semantic_storage = self.semantic_storage;
        self.ui_build.initWithApi(
            self.vm.state,
            self.descriptor_storage,
            self.vm.apiReference(),
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        self.vm.setRuntimeDirectory(config.runtime_dir);
        self.applications.init(&self.vm, loop, config.applications);
        applications_initialized = true;
        self.ui_build.attachSignals(&self.signals);
        self.ui_build.attachSemantics(self.semantic_storage) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        if (services) |value| {
            self.callbacks = value.callbacks;
            self.ui_build.attachCallbacks(value.callbacks, &self.vm);
            self.ui_build.attachText(value.paragraph_sources, value.font_candidates, 1) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    allocator,
                    .setup,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            self.ui_build.attachMediumText(value.medium_font_candidates) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    allocator,
                    .setup,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            self.ui_build.enableDeclarativeWidgets(value.theme);
            self.ui_build.theme_fonts = value.theme_fonts;
            try self.attachImages(value.images, value.icon_roots);
        } else {
            self.callbacks = null;
        }

        if (module_root) |root_fd| {
            self.module_loader = @as(lua.ModuleLoader, undefined);
            self.module_loader.?.init(
                allocator,
                &self.vm,
                loop,
                root_fd,
                config.module_capacity,
            ) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    allocator,
                    .setup,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            module_loader_initialized = true;
            self.bootstrap = lua.ApplicationBootstrap.start(
                allocator,
                &self.vm,
                scheduler.application_scope,
                self.snapshot.bytes,
                self.snapshot.chunk_name,
            ) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    allocator,
                    .evaluate,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            self.bootstrap.?.defer_run = config.defer_run;
            return;
        }

        if (config.defer_run) {
            self.bootstrap = try lua.ApplicationBootstrap.start(
                allocator,
                &self.vm,
                scheduler.application_scope,
                self.snapshot.bytes,
                self.snapshot.chunk_name,
            );
            self.bootstrap.?.defer_run = true;
            return;
        }

        self.application = lua.Application.loadNamedWithApi(
            allocator,
            self.vm.state,
            self.snapshot.bytes,
            self.snapshot.chunk_name,
            diagnostic,
            self.vm.apiReference(),
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .declaration,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        application_initialized = true;
        self.ui_build.text_input_bindings = self.application.text_input_bindings;
        _ = try self.refreshWindows();
        if (services) |value| {
            self.ui_build.widget_theme = self.application.resolvedTheme(value.theme);
        }
        try self.validateApplicationIdentity(diagnostic);
        self.application_ready = true;
        self.prepared_builds = allocator.alloc(
            lua.PreparedBuild,
            self.application.windows.len,
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        prepared_build_storage = self.prepared_builds;
        for (self.prepared_builds) |*prepared| {
            prepared.init(
                allocator,
                self.vm.state,
                if (services) |value| value.paragraph_sources else null,
                config.node_capacity,
                config.semantic_text_capacity,
            ) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    allocator,
                    .setup,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            prepared_build_count += 1;
        }
    }

    pub fn resumeRunnable(
        self: *SourceGeneration,
        scheduler_handle: task.TaskHandle,
        diagnostic: ?*?lua.Diagnostic,
    ) !lua.ResumeResult {
        const is_ui = if (self.ui_task) |handle|
            std.meta.eql(try self.vm.schedulerHandle(handle), scheduler_handle)
        else
            false;
        const result = self.vm.resumeRunnable(scheduler_handle) catch |err| {
            if (is_ui) self.ui_task = null;
            return err;
        };
        if (result == .canceled and is_ui) self.ui_task = null;
        if (result == .completed and self.bootstrap != null)
            try self.finishBootstrap(diagnostic);
        if (result == .completed and is_ui) {
            const handle = self.ui_task.?;
            self.ui_task = null;
            try self.application.finishUi(&self.vm, handle);
            _ = try self.refreshWindows();
            for (self.prepared_builds) |*prepared| prepared.deinit();
            self.allocator.free(self.prepared_builds);
            self.prepared_builds = &.{};
            const builds = try self.allocator.alloc(lua.PreparedBuild, self.application.windows.len);
            var initialized: usize = 0;
            errdefer {
                for (builds[0..initialized]) |*prepared| prepared.deinit();
                self.allocator.free(builds);
            }
            for (builds) |*prepared| {
                try prepared.init(self.allocator, self.vm.state, if (self.services) |value| value.paragraph_sources else null, self.config.node_capacity, self.config.semantic_text_capacity);
                initialized += 1;
            }
            self.prepared_builds = builds;
            if (self.module_loader) |*loader| loader.freeze();
        }
        return result;
    }

    pub fn startUi(self: *SourceGeneration) !void {
        if (self.ui_task != null) return error.UiActivationInProgress;
        if (!self.application.hasRun() and self.application.windows.len != 0) return;
        self.ui_task = try self.application.startUi(&self.vm, self.vm.scheduler.application_scope, "default");
    }

    pub fn attachUi(self: *SourceGeneration, services: UiServices) !void {
        self.services = services;
        self.callbacks = services.callbacks;
        self.ui_build.attachCallbacks(services.callbacks, &self.vm);
        try self.ui_build.attachText(services.paragraph_sources, services.font_candidates, 1);
        try self.ui_build.attachMediumText(services.medium_font_candidates);
        self.ui_build.enableDeclarativeWidgets(services.theme);
        self.ui_build.widget_theme = self.application.resolvedTheme(services.theme);
        self.ui_build.text_input_bindings = self.application.text_input_bindings;
        self.ui_build.theme_fonts = services.theme_fonts;
        try self.attachImages(services.images, services.icon_roots);
        if (services.workspaces) |store| {
            self.shell_workspaces = @as(lua.ShellWorkspaces, undefined);
            try self.shell_workspaces.?.init(self.vm.state, &self.signals, store, self.vm.apiReference());
        }
    }

    fn attachImages(self: *SourceGeneration, cache_optional: ?*ImageCache, icon_roots: []const []const u8) !void {
        const cache = cache_optional orelse return;
        std.debug.assert(self.images == null);
        self.images = @as(image_service.Service, undefined);
        self.images.?.init(self.allocator, self.vm.loop, cache, self.asset_root) catch |err| {
            self.images = null;
            return err;
        };
        self.images.?.icon_roots = icon_roots;
        self.ui_build.images = &self.images.?;
    }

    /// Starts queued asset work only after the active generation reconciles.
    /// Candidate preparation queues descriptions but never starts workers.
    pub fn pumpImages(self: *SourceGeneration) !void {
        if (self.images) |*images| try images.pump();
    }

    pub fn shutdownImages(self: *SourceGeneration) void {
        if (self.images) |*images| images.shutdown();
    }

    pub fn imagesQuiescent(self: *const SourceGeneration) bool {
        return if (self.images) |*images| images.canDeinit() else true;
    }

    pub fn dispatchFile(self: *SourceGeneration, completion: io_loop.FileCompletion) !bool {
        if (self.images) |*images| if (try images.dispatch(completion)) return true;
        if (try self.applications.dispatch(completion)) return true;
        if (try self.stdio.dispatch(completion)) return true;
        if (self.module_loader) |*loader| return loader.dispatch(completion);
        return false;
    }

    pub fn dispatchSocket(self: *SourceGeneration, completion: io_loop.SocketCompletion) !bool {
        if (try self.dbus.dispatch(completion)) return true;
        return self.mcp_client.dispatch(completion);
    }

    pub fn dispatchTimer(self: *SourceGeneration, operation: io_loop.OperationHandle) !bool {
        if (try self.dbus.dispatchTimer(operation)) return true;
        if (!self.vm.ownsOperation(operation)) return false;
        try self.vm.markTimeoutCompleted(operation);
        return true;
    }

    pub fn collectCanceledMcp(self: *SourceGeneration) !void {
        try self.dbus.collectCanceled();
        try self.mcp_client.collectCanceled();
        try self.stdio.collectCanceled();
        try self.applications.collectCanceled();
    }

    pub fn workspacesRequested(self: *const SourceGeneration) bool {
        return if (self.shell_workspaces) |*binding| binding.requested() else false;
    }

    /// Apply host defaults at a safe point, retaining declaration overrides.
    /// The caller invalidates mounted build owners when this returns true.
    pub fn setTheme(self: *SourceGeneration, theme: design.tokens.Theme) bool {
        const services = if (self.services) |*value| value else return false;
        services.theme = theme;
        if (!self.application_ready) return false;
        const resolved = self.application.resolvedTheme(theme);
        if (std.meta.eql(self.ui_build.widget_theme, @as(@TypeOf(self.ui_build.widget_theme), resolved))) return false;
        self.ui_build.widget_theme = resolved;
        return true;
    }

    pub fn syncWorkspaces(self: *SourceGeneration) !void {
        if (self.shell_workspaces) |*binding| try binding.sync();
    }

    /// Window declarations use the same dependency graph as widget builds,
    /// with one application-level owner. Only dirty declarations enter Lua.
    pub fn refreshWindows(self: *SourceGeneration) !bool {
        if (self.application.windows_reference == @import("../lua/c.zig").no_reference) return false;
        if (self.window_owners == null) {
            var owners: ui.instance.BuildOwners = undefined;
            try owners.init(self.allocator, self.vm.scheduler, self.vm.scheduler.application_scope, 1, 8);
            self.window_owners = owners;
            self.window_owner = self.window_owners.?.mount(null, 1) catch |err| {
                self.window_owners.?.deinit();
                self.window_owners = null;
                return err;
            };
        }
        const owners = &self.window_owners.?;
        var cycle = owners.beginCycle();
        const work = (try cycle.take()) orelse return false;
        errdefer owners.retry(work) catch unreachable;
        const owner: lua.SignalOwnerRef = .{ .owners = owners, .handle = self.window_owner };
        try self.signals.beginEvaluation(owner, work.revision);
        var finished = false;
        errdefer {
            if (finished) self.signals.rollback(owner, work.revision) catch unreachable else self.signals.abortEvaluation(owner, work.revision) catch unreachable;
        }
        var candidate = self.application;
        candidate.windows = try self.application.evaluateWindows(self.config.window_capacity);
        candidate.output_templates = &.{};
        errdefer {
            candidate.releaseWindows(candidate.windows);
            candidate.releaseWindows(candidate.output_templates);
        }
        try candidate.extractOutputTemplates();
        // Keep output-expanded IDs stable, including disconnected outputs.
        for (self.application.windows) |window| if (window.template_id != null) {
            _ = try candidate.expandOutput(window.declaration.layer_surface.output.?, self.config.window_capacity);
        };
        try self.signals.finishEvaluation(owner, work.revision);
        finished = true;
        try self.signals.validateCommit(owner, work.revision);
        try self.signals.commit(owner, work.revision);
        self.application.releaseWindows(self.application.windows);
        self.application.releaseWindows(self.application.output_templates);
        self.application.windows = candidate.windows;
        self.application.output_templates = candidate.output_templates;
        try owners.complete(work);
        return true;
    }

    fn disposeWindowOwner(self: *SourceGeneration) void {
        if (self.window_owners) |*owners| {
            self.signals.disposeOwner(.{ .owners = owners, .handle = self.window_owner }) catch unreachable;
            owners.retire(self.window_owner) catch unreachable;
            self.vm.scheduler.applyQueuedCancellations() catch unreachable;
            owners.collectRetired() catch unreachable;
            owners.deinit();
            self.window_owners = null;
        }
    }

    fn finishBootstrap(self: *SourceGeneration, diagnostic: ?*?lua.Diagnostic) !void {
        const application_optional = self.bootstrap.?.advance("default") catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                self.allocator,
                .declaration,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        if (application_optional == null) return;
        var application = application_optional.?;
        self.bootstrap.?.deinit();
        self.bootstrap = null;
        if (!self.config.defer_run) if (self.module_loader) |*loader| loader.freeze();
        self.application = application;
        self.ui_build.text_input_bindings = application.text_input_bindings;
        errdefer {
            self.disposeWindowOwner();
            self.application.deinit();
        }
        _ = try self.refreshWindows();
        if (self.services) |value| {
            self.ui_build.widget_theme = application.resolvedTheme(value.theme);
        }
        try self.validateApplicationIdentity(diagnostic);
        const prepared_builds = self.allocator.alloc(
            lua.PreparedBuild,
            self.application.windows.len,
        ) catch |err| {
            lua.recordDiagnosticError(
                diagnostic,
                self.allocator,
                .setup,
                self.snapshot.entry_name,
                err,
            );
            return err;
        };
        var initialized: usize = 0;
        errdefer {
            for (prepared_builds[0..initialized]) |*prepared| prepared.deinit();
            self.allocator.free(prepared_builds);
        }
        for (prepared_builds) |*prepared| {
            prepared.init(
                self.allocator,
                self.vm.state,
                if (self.services) |value| value.paragraph_sources else null,
                self.config.node_capacity,
                self.config.semantic_text_capacity,
            ) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    self.allocator,
                    .setup,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            initialized += 1;
        }
        self.prepared_builds = prepared_builds;
        self.application_ready = true;
    }

    fn validateApplicationIdentity(
        self: *SourceGeneration,
        diagnostic: ?*?lua.Diagnostic,
    ) !void {
        const expected = self.snapshot.application_id orelse return;
        if (std.mem.eql(u8, expected, self.application.id)) return;
        lua.recordDiagnosticError(
            diagnostic,
            self.allocator,
            .declaration,
            self.snapshot.entry_name,
            error.ApplicationIdMismatch,
        );
        return error.ApplicationIdMismatch;
    }

    pub fn deinit(self: *SourceGeneration) void {
        if (self.callbacks) |callbacks|
            std.debug.assert(callbacks.countForVm(&self.vm) == 0);
        self.disposeWindowOwner();
        if (self.application_ready) {
            self.application.deinit();
            for (self.prepared_builds) |*prepared| prepared.deinit();
            self.allocator.free(self.prepared_builds);
        } else {
            std.debug.assert(self.vm.activeTaskCount() == 0);
            if (self.bootstrap) |*bootstrap| bootstrap.deinit();
        }
        if (self.module_loader) |*loader| loader.deinit();
        if (self.images) |*images| images.deinit();
        self.applications.deinit();
        self.stdio.deinit();
        self.dbus.deinit();
        self.mcp_client.deinit();
        self.vm.deinit();
        if (self.native_modules) |*modules| modules.deinit();
        if (self.shell_workspaces) |*binding| binding.deinit();
        self.signals.deinit();
        self.allocator.free(self.semantic_storage);
        self.allocator.free(self.descriptor_storage);
        self.snapshot.deinit();
        self.* = undefined;
    }

    pub fn destroy(self: *SourceGeneration) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }
};

test "source generation owns a named snapshot and application Lua state" {
    var provider = try bundle.SourceProvider.initEmbedded(std.testing.allocator, "generation-test.lua",
        \\local ouro = require("ouro")
        \\assert(ouro.xdg.runtime_dir == "/run/user/1234")
        \\assert(type(ouro.xdg.icon) == "function")
        \\return ouro.app {
        \\  id = "dev.ouro.generation-test",
        \\  text_input_bindings = {['Alt+R'] = 'redo'},
        \\  windows = {
        \\    ouro.window {
        \\      id = "main",
        \\      title = "Generation",
        \\      content = function() end,
        \\    },
        \\  },
        \\}
    );
    defer provider.deinit();
    const snapshot = try provider.snapshot(std.testing.io, std.testing.allocator);
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 2, 2);
    defer scheduler.deinit();
    var diagnostic: ?lua.Diagnostic = null;
    defer if (diagnostic) |*value| value.deinit();
    const generation = try SourceGeneration.create(
        std.testing.allocator,
        &scheduler,
        &loop,
        snapshot,
        null,
        .{ .node_capacity = 8, .runtime_dir = "/run/user/1234" },
        &diagnostic,
    );
    defer generation.destroy();
    try std.testing.expect(diagnostic == null);
    try std.testing.expectEqualStrings(
        "dev.ouro.generation-test",
        generation.application.id,
    );
    try std.testing.expectEqualStrings("generation-test.lua", generation.snapshot.entry_name);
    try std.testing.expectEqual(@as(usize, 1), generation.prepared_builds.len);
    try std.testing.expectEqual(@as(usize, 0), generation.prepared_builds[0].descriptors().len);
    try std.testing.expectEqual(ui.text_input.KeyAction{ .edit = .redo }, generation.ui_build.text_input_bindings.resolve(.{
        .keycode = 19,
        .logical = .key_r,
        .modifiers = .{ .alt = true },
    }).?);
}

test "source generation rejects Lua identity that differs from package metadata" {
    const snapshot = try bundle.SourceSnapshot.initApplication(
        std.testing.allocator,
        "app.lua",
        \\local ouro = require("ouro")
        \\return ouro.app {
        \\  id = "dev.ouro.wrong",
        \\  windows = {
        \\    ouro.window { id = "main", title = "Wrong", content = function() end },
        \\  },
        \\}
    ,
        "dev.ouro.expected",
    );
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 2, 4);
    defer scheduler.deinit();
    try std.testing.expectError(
        error.ApplicationIdMismatch,
        SourceGeneration.create(
            std.testing.allocator,
            &scheduler,
            &loop,
            snapshot,
            null,
            .{ .node_capacity = 8 },
            null,
        ),
    );
}

test "source generation bootstrap retains async module closure before becoming ready" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data =
        \\local ouro = require("ouro")
        \\return ouro.app {
        \\  id = "dev.ouro.async-generation",
        \\  actions = {},
        \\  run = function(context)
        \\    local title = require("title")
        \\    return { windows = {
        \\      ouro.window {
        \\        id = "main",
        \\        title = title .. ":" .. context.instance_id,
        \\        content = function() end,
        \\      },
        \\    } }
        \\  end,
        \\}
        ,
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "title.lua",
        .data = "return 'Loaded asynchronously'",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "late.lua",
        .data = "return 'too late'",
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
        "app.lua",
    });
    defer std.testing.allocator.free(path);
    var provider = try bundle.SourceProvider.initDiskApplication(
        std.testing.allocator,
        path,
        "dev.ouro.async-generation",
    );
    defer provider.deinit();
    const module_root = (try provider.openModuleRoot(std.testing.io)).?;
    defer module_root.close(std.testing.io);
    const snapshot = try provider.snapshot(std.testing.io, std.testing.allocator);

    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 32, 16);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 2, 4);
    defer scheduler.deinit();
    const generation = try SourceGeneration.createBootstrap(
        std.testing.allocator,
        &scheduler,
        &loop,
        snapshot,
        module_root.handle,
        null,
        .{ .node_capacity = 8, .module_capacity = 4 },
        null,
    );
    defer generation.destroy();

    while (!generation.application_ready) {
        while (scheduler.takeRunnable()) |runnable|
            _ = try generation.resumeRunnable(runnable, null);
        if (generation.application_ready) break;
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| try std.testing.expect(try generation.dispatchFile(completion)),
            .operation_cancel => {},
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expectEqualStrings(
        "dev.ouro.async-generation",
        generation.application.id,
    );
    try std.testing.expectEqualStrings(
        "Loaded asynchronously:default",
        generation.application.windows[0].declaration.toplevel.title,
    );
    try std.testing.expect(generation.application.hasActions());
    _ = try generation.vm.spawnApplication("require('late')");
    try std.testing.expectError(
        error.LuaRuntimeError,
        generation.vm.resumeRunnable(scheduler.takeRunnable().?),
    );
}

test "headless source generation preserves action state when UI is activated later" {
    const allocator = std.testing.allocator;
    const snapshot = try bundle.SourceSnapshot.initApplication(allocator, "headless.lua",
        \\local ouro = require('ouro')
        \\local title = ouro.signal('before')
        \\return ouro.app {
        \\  id = 'dev.ouro.headless',
        \\  text_input_bindings = {['Alt+U'] = 'undo'},
        \\  actions = { Change = {
        \\    description = 'Change the title',
        \\    inputSchema = {type='object', additionalProperties=false},
        \\    outputSchema = {type='object', additionalProperties=false},
        \\    handler = function() title:set('after action'); return {} end,
        \\  } },
        \\  run = function()
        \\    ui_started = true
        \\    ouro.sleep(1)
        \\    return { windows = { ouro.window {
        \\      id = 'main', title = title(), content = function() end,
        \\    } } }
        \\  end,
        \\}
    , "dev.ouro.headless");
    var loop: io_loop.Loop = undefined;
    try loop.init(allocator, 32, 16);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(allocator, 8, 4, 8);
    defer scheduler.deinit();
    const generation = try SourceGeneration.create(allocator, &scheduler, &loop, snapshot, null, .{ .defer_run = true }, null);
    defer generation.destroy();
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expect(generation.application_ready);
    try std.testing.expectEqual(@as(usize, 0), generation.application.windows.len);
    try std.testing.expect(!generation.vm.hasGlobal("ui_started"));
    try std.testing.expect(generation.services == null);
    try std.testing.expectEqual(ui.text_input.KeyAction{ .edit = .undo }, generation.ui_build.text_input_bindings.resolve(.{
        .keycode = 22,
        .logical = .key_u,
        .modifiers = .{ .alt = true },
    }).?);
    const action = try generation.application.startAction(&generation.vm, scheduler.application_scope, "Change", null);
    _ = try generation.vm.resumeRunnable(scheduler.takeRunnable().?);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = try lua.Application.takeActionResult(&generation.vm, action, arena.allocator());
    try std.testing.expect(reply == .output);
    try std.testing.expect(!generation.vm.hasGlobal("ui_started"));
    try generation.startUi();
    while (generation.ui_task != null) {
        while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
        if (generation.ui_task == null) break;
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .timer_wakeup, .timer_control => while (try loop.takeExpired()) |timeout| {
                if (!(try generation.dispatchTimer(timeout.operation))) return error.UnownedSourceOperation;
            },
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(generation.vm.globalBoolean("ui_started"));
    try std.testing.expectEqualStrings("after action", generation.application.windows[0].declaration.toplevel.title);
    try std.testing.expectError(error.ApplicationUiAlreadyStarted, generation.startUi());
}

test "reactive windows track signals, retain output identities, and roll back invalid declarations" {
    const allocator = std.testing.allocator;
    const snapshot = try bundle.SourceSnapshot.initApplication(allocator, "reactive.lua",
        \\local ouro = require('ouro')
        \\visible = ouro.signal(false)
        \\invalid = ouro.signal(false)
        \\empty = ouro.signal(false)
        \\unused = ouro.signal(0)
        \\return ouro.app { id = 'dev.ouro.reactive', run = function()
        \\  return { windows = function()
        \\    if empty() then return {} end
        \\    local bar = ouro.layer_surface {
        \\      id='bar', namespace='bar', outputs='all', layer='top',
        \\      width=0, height=40, anchors={'top', 'left', 'right'}, content=function() end,
        \\    }
        \\    if invalid() then return {bar, bar} end
        \\    if visible() then return {bar, ouro.window {id='launcher', title='Launcher', content=function() end}} end
        \\    return {bar}
        \\  end }
        \\end }
    , "dev.ouro.reactive");
    var loop: io_loop.Loop = undefined;
    try loop.init(allocator, 32, 16);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(allocator, 8, 4, 8);
    defer scheduler.deinit();
    const generation = try SourceGeneration.create(allocator, &scheduler, &loop, snapshot, null, .{}, null);
    defer generation.destroy();
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expectEqual(@as(usize, 1), generation.application.output_templates.len);
    _ = try generation.application.expandOutput("DP-2", 3);
    _ = try generation.application.expandOutput("HDMI-A-1", 3);
    try std.testing.expect(!(try generation.refreshWindows()));
    _ = try generation.vm.spawnApplication("unused:set(1); visible:set(true)");
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expect(try generation.refreshWindows());
    try std.testing.expectEqual(@as(usize, 3), generation.application.windows.len);
    try std.testing.expectEqualStrings("launcher", generation.application.windows[0].declaration.id());
    try std.testing.expectEqualStrings("bar@4:DP-2", generation.application.windows[1].declaration.id());
    try std.testing.expectEqualStrings("bar@8:HDMI-A-1", generation.application.windows[2].declaration.id());
    const retained = generation.application.windows.ptr;
    _ = try generation.vm.spawnApplication("invalid:set(true)");
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expectError(error.DuplicateWindowId, generation.refreshWindows());
    try std.testing.expectEqual(retained, generation.application.windows.ptr);
    _ = try generation.vm.spawnApplication("invalid:set(false); visible:set(false)");
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expect(try generation.refreshWindows());
    try std.testing.expectEqual(@as(usize, 2), generation.application.windows.len);
    _ = try generation.vm.spawnApplication("empty:set(true)");
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expect(try generation.refreshWindows());
    try std.testing.expectEqual(@as(usize, 0), generation.application.windows.len);
    try std.testing.expectError(error.ApplicationUiAlreadyStarted, generation.startUi());
    _ = try generation.vm.spawnApplication("visible:set(true); unused:set(2)");
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expect(!(try generation.refreshWindows()));
    _ = try generation.vm.spawnApplication("empty:set(false)");
    while (scheduler.takeRunnable()) |handle| _ = try generation.resumeRunnable(handle, null);
    try std.testing.expect(try generation.refreshWindows());
    try std.testing.expectEqualStrings("launcher", generation.application.windows[0].declaration.id());
}
