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
};

pub const UiServices = struct {
    shapes: *text.ShapeCache,
    primary_font: text.FontHandle,
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
    callbacks: ?*lua.CallbackRegistry,
    ui_build: lua.UiBuild,
    application: lua.Application,
    prepared_builds: []lua.PreparedBuild,

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
        self.allocator = allocator;
        self.snapshot = snapshot;
        var vm_initialized = false;
        var signals_initialized = false;
        var descriptor_storage: ?[]ui.instance.Descriptor = null;
        var semantic_storage: ?[]ui.semantics.Descriptor = null;
        var application_initialized = false;
        var prepared_build_storage: ?[]lua.PreparedBuild = null;
        var prepared_build_count: usize = 0;
        errdefer {
            if (prepared_build_storage) |storage| {
                for (storage[0..prepared_build_count]) |*prepared| prepared.deinit();
                allocator.free(storage);
            }
            if (application_initialized) self.application.deinit();
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
            self.ui_build.attachLabelText(value.shapes, &self.font_candidates, 1) catch |err| {
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
                if (services) |value| value.shapes else null,
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

    pub fn deinit(self: *SourceGeneration) void {
        if (self.callbacks) |callbacks|
            std.debug.assert(callbacks.countForVm(&self.vm) == 0);
        self.application.deinit();
        for (self.prepared_builds) |*prepared| prepared.deinit();
        self.allocator.free(self.prepared_builds);
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
