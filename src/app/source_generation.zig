const std = @import("std");
const bundle = @import("../bundle/root.zig");
const design = @import("../design/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");

pub const Config = struct {
    node_capacity: usize = 256,
    semantic_text_capacity: usize = 16 * 1024,
    signal_capacity: usize = 256,
    subscription_capacity: usize = 1024,
    dependency_capacity: usize = 256,
    module_capacity: usize = 64,
};

pub const UiServices = struct {
    paragraph_sources: *text.ParagraphSourceCache,
    paragraphs: *text.ParagraphCache,
    primary_font: text.FontHandle,
    medium_font: text.FontHandle,
    theme: design.tokens.Theme,
    callbacks: *lua.CallbackRegistry,
};

/// All Lua-owned meaning for one application source snapshot. This value and
/// its VM, Signals, and UiBuild fields must retain a stable address from init
/// through deinit because installed C closures point into them.
pub const SourceGeneration = struct {
    allocator: std.mem.Allocator,
    snapshot: bundle.SourceSnapshot,
    vm: lua.Vm,
    signals: lua.Signals,
    descriptor_storage: []ui.instance.Descriptor,
    semantic_storage: []ui.semantics.Descriptor,
    font_candidates: [1]text.FontHandle,
    medium_font_candidates: [1]text.FontHandle,
    callbacks: ?*lua.CallbackRegistry,
    ui_build: lua.UiBuild,
    application: lua.Application,
    prepared_builds: []lua.PreparedBuild,
    module_loader: ?lua.ModuleLoader = null,
    bootstrap: ?lua.ApplicationBootstrap = null,
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
        self.bootstrap = null;
        self.application_ready = false;
        self.services = services;
        self.config = config;
        var vm_initialized = false;
        var signals_initialized = false;
        var descriptor_storage: ?[]ui.instance.Descriptor = null;
        var semantic_storage: ?[]ui.semantics.Descriptor = null;
        var application_initialized = false;
        var prepared_build_storage: ?[]lua.PreparedBuild = null;
        var prepared_build_count: usize = 0;
        var module_loader_initialized = false;
        errdefer {
            if (prepared_build_storage) |storage| {
                for (storage[0..prepared_build_count]) |*prepared| prepared.deinit();
                allocator.free(storage);
            }
            if (application_initialized) self.application.deinit();
            if (module_loader_initialized) self.module_loader.?.deinit();
            if (vm_initialized) self.vm.deinit();
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
            self.font_candidates = .{value.primary_font};
            self.medium_font_candidates = .{value.medium_font};
            self.ui_build.attachLabelText(value.paragraph_sources, &self.font_candidates, 1) catch |err| {
                lua.recordDiagnosticError(
                    diagnostic,
                    allocator,
                    .setup,
                    self.snapshot.entry_name,
                    err,
                );
                return err;
            };
            self.ui_build.attachMediumText(&self.medium_font_candidates) catch |err| {
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
        const result = try self.vm.resumeRunnable(scheduler_handle);
        if (result == .completed and self.bootstrap != null)
            try self.finishBootstrap(diagnostic);
        return result;
    }

    pub fn dispatchFile(self: *SourceGeneration, completion: io_loop.FileCompletion) !bool {
        if (self.module_loader) |*loader| return loader.dispatch(completion);
        return false;
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
        self.module_loader.?.freeze();
        errdefer application.deinit();
        self.application = application;
        try self.validateApplicationIdentity(diagnostic);
        const prepared_builds = self.allocator.alloc(
            lua.PreparedBuild,
            application.windows.len,
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
        if (self.application_ready) {
            self.application.deinit();
            for (self.prepared_builds) |*prepared| prepared.deinit();
            self.allocator.free(self.prepared_builds);
        } else {
            std.debug.assert(self.vm.activeTaskCount() == 0);
            if (self.bootstrap) |*bootstrap| bootstrap.deinit();
        }
        if (self.module_loader) |*loader| loader.deinit();
        self.vm.deinit();
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
        \\return ouro.app {
        \\  id = "dev.ouro.generation-test",
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
        .{ .node_capacity = 8 },
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
        \\  actions = { ping = function() return "pong" end },
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
        generation.application.windows[0].declaration.title,
    );
    try std.testing.expect(generation.application.hasActions());
    _ = try generation.vm.spawnApplication("require('late')");
    try std.testing.expectError(
        error.LuaRuntimeError,
        generation.vm.resumeRunnable(scheduler.takeRunnable().?),
    );
}
