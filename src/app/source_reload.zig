const std = @import("std");
const bundle = @import("../bundle/root.zig");
const core = @import("../core/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const task = @import("../task/root.zig");
const source_generation = @import("source_generation.zig");
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;

const SourceGeneration = source_generation.SourceGeneration;
const retiring_capacity = 4;

const RetiringGeneration = struct {
    generation: *SourceGeneration,
    cancellation_started: bool = false,
    native_state_detached: bool = false,
};

pub const Commit = struct {
    generation: u64,
    /// Borrowed until `collectRetired` succeeds or SourceReload is destroyed.
    retired: *SourceGeneration,
};

pub const WindowTarget = struct {
    id: []const u8,
    runtime: *WindowRuntime,
    size: core.SizeU,
};

/// Owns the active source generation and at most one fully prepared candidate.
/// Preparing never mutates active Lua or native application state. Committing
/// only swaps generation ownership; the app coordinator must subsequently
/// retire the returned old generation at its task/resource safe points.
pub const SourceReload = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: *const bundle.SourceProvider,
    scheduler: *task.Scheduler,
    loop: *io_loop.Loop,
    services: ?source_generation.UiServices,
    config: source_generation.Config,
    active_generation: *SourceGeneration,
    candidate: ?*SourceGeneration = null,
    module_root: ?std.os.linux.fd_t = null,
    candidate_failure: ?anyerror = null,
    retiring_generations: [retiring_capacity]?RetiringGeneration =
        [_]?RetiringGeneration{null} ** retiring_capacity,
    generation: u64 = 1,
    diagnostic: ?lua.Diagnostic = null,

    pub fn init(
        self: *SourceReload,
        allocator: std.mem.Allocator,
        io: std.Io,
        provider: *const bundle.SourceProvider,
        scheduler: *task.Scheduler,
        loop: *io_loop.Loop,
        services: ?source_generation.UiServices,
        config: source_generation.Config,
        initial: *SourceGeneration,
    ) void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .provider = provider,
            .scheduler = scheduler,
            .loop = loop,
            .services = services,
            .config = config,
            .active_generation = initial,
        };
    }

    pub fn deinit(self: *SourceReload) void {
        if (self.candidate) |candidate| candidate.destroy();
        for (&self.retiring_generations) |*entry| if (entry.*) |retiring|
            retiring.generation.destroy();
        self.active_generation.destroy();
        if (self.diagnostic) |*value| value.deinit();
        self.* = undefined;
    }

    pub fn active(self: *const SourceReload) *SourceGeneration {
        return self.active_generation;
    }

    pub fn attachModuleRoot(self: *SourceReload, directory: std.os.linux.fd_t) void {
        self.module_root = directory;
    }

    pub fn candidateReady(self: *const SourceReload) bool {
        return if (self.candidate) |candidate| candidate.application_ready else false;
    }

    pub fn takeCandidateFailure(self: *SourceReload) ?anyerror {
        const failure = self.candidate_failure;
        self.candidate_failure = null;
        return failure;
    }

    pub fn retiringCount(self: *const SourceReload) usize {
        var count: usize = 0;
        for (self.retiring_generations) |entry| if (entry != null) {
            count += 1;
        };
        return count;
    }

    pub fn lastDiagnostic(self: *const SourceReload) ?*const lua.Diagnostic {
        return if (self.diagnostic) |*value| value else null;
    }

    /// Builds a complete candidate declaration from a fresh source snapshot.
    /// The active generation remains authoritative until `commit` is called.
    pub fn prepare(self: *SourceReload) !void {
        if (self.candidate != null) return error.SourceCandidateAlreadyPrepared;
        if (self.retiringCount() == retiring_capacity)
            return error.SourceRetirementCapacityExceeded;
        self.clearDiagnostic();
        self.candidate_failure = null;
        const snapshot = self.provider.snapshot(self.io, self.allocator) catch |err| {
            lua.recordDiagnosticError(
                &self.diagnostic,
                self.allocator,
                .source,
                self.provider.entryName(),
                err,
            );
            return err;
        };
        const candidate = if (self.module_root) |root|
            SourceGeneration.createBootstrap(
                self.allocator,
                self.scheduler,
                self.loop,
                snapshot,
                root,
                self.services,
                self.config,
                &self.diagnostic,
            )
        else
            SourceGeneration.create(
                self.allocator,
                self.scheduler,
                self.loop,
                snapshot,
                self.services,
                self.config,
                &self.diagnostic,
            );
        const prepared = candidate catch |err| return err;
        const candidate_generation = prepared;
        errdefer candidate_generation.destroy();
        if (candidate_generation.application_ready and
            !std.mem.eql(u8, candidate_generation.application.id, self.active_generation.application.id))
        {
            lua.recordDiagnosticError(
                &self.diagnostic,
                self.allocator,
                .declaration,
                candidate_generation.snapshot.entry_name,
                error.ApplicationIdChanged,
            );
            return error.ApplicationIdChanged;
        }
        self.candidate = candidate_generation;
    }

    pub fn discard(self: *SourceReload) void {
        const candidate = self.candidate orelse return;
        candidate.destroy();
        self.candidate = null;
    }

    /// Prepares every retained window against the candidate generation. The
    /// first implementation requires the same window ID set; structural
    /// window changes will use reserved runtime slots in a subsequent step.
    pub fn prepareApplication(self: *SourceReload, targets: []const WindowTarget) !void {
        const candidate = self.candidate orelse return error.SourceCandidateNotPrepared;
        if (targets.len != candidate.application.windows.len) {
            self.recordBuildError(error.SourceWindowSetChanged);
            self.discard();
            return error.SourceWindowSetChanged;
        }
        for (candidate.application.windows, candidate.prepared_builds) |window, *prepared| {
            const target = findWindowTarget(targets, window.declaration.id) orelse {
                self.recordBuildError(error.SourceWindowSetChanged);
                self.discard();
                return error.SourceWindowSetChanged;
            };
            target.runtime.prepareSourceBuild(
                target.size,
                &candidate.ui_build,
                prepared,
                window.content_reference,
                self.generation + 1,
            ) catch |err| {
                self.recordBuildError(err);
                self.discard();
                return err;
            };
        }
    }

    /// Commits an already prepared same-window-set candidate. Every fallible
    /// check and allocation completes before the first retained window changes.
    pub fn commitApplication(
        self: *SourceReload,
        targets: []const WindowTarget,
        callbacks: *lua.CallbackRegistry,
    ) !Commit {
        const candidate = self.candidate orelse return error.SourceCandidateNotPrepared;
        if (targets.len != candidate.application.windows.len)
            return error.SourceWindowSetChanged;
        var callback_count: usize = 0;
        for (candidate.application.windows, candidate.prepared_builds) |window, *prepared| {
            const target = findWindowTarget(targets, window.declaration.id) orelse
                return error.SourceWindowSetChanged;
            try target.runtime.validatePreparedSourceCommit(prepared);
            callback_count = std.math.add(
                usize,
                callback_count,
                prepared.handler_count,
            ) catch return error.CallbackCapacityExceeded;
        }
        try callbacks.ensureAvailable(callback_count);

        for (candidate.application.windows, candidate.prepared_builds) |window, *prepared| {
            const target = findWindowTarget(targets, window.declaration.id).?;
            target.runtime.commitPreparedSource(
                prepared,
                callbacks,
                &candidate.vm,
                &candidate.signals,
            );
        }
        const committed = self.commit();
        self.markRetiringNativeStateDetached(committed.retired);
        return committed;
    }

    /// Atomically changes which prepared Lua declaration is authoritative.
    /// No fallible work belongs here. The returned generation remains live
    /// until its callbacks, tasks, and resources have been retired by `app`.
    pub fn commit(self: *SourceReload) Commit {
        var available_retirement_slot: ?*?RetiringGeneration = null;
        for (&self.retiring_generations) |*entry| if (entry.* == null) {
            available_retirement_slot = entry;
            break;
        };
        const retirement_slot = available_retirement_slot orelse
            @panic("source generation commit without retirement capacity");
        const candidate = self.candidate orelse @panic("source generation commit without candidate");
        const retired = self.active_generation;
        self.active_generation = candidate;
        self.candidate = null;
        retirement_slot.* = .{ .generation = retired };
        self.generation += 1;
        self.clearDiagnostic();
        return .{ .generation = self.generation, .retired = retired };
    }

    /// Starts safe-point cancellation of only the language work belonging to
    /// the retiring VM. Retained application/window scopes are not canceled.
    pub fn beginRetirement(self: *SourceReload) !void {
        for (&self.retiring_generations) |*entry| {
            const retiring = &(entry.* orelse continue);
            if (retiring.cancellation_started) continue;
            try retiring.generation.vm.requestCancellation();
            retiring.cancellation_started = true;
        }
    }

    /// The app coordinator calls this after retained windows, build owners,
    /// signals, and callback bindings no longer borrow the old generation.
    pub fn markRetiringNativeStateDetached(
        self: *SourceReload,
        generation: *SourceGeneration,
    ) void {
        for (&self.retiring_generations) |*entry| if (entry.*) |*retiring| {
            if (retiring.generation != generation) continue;
            retiring.native_state_detached = true;
            return;
        };
        @panic("detaching unknown source generation");
    }

    /// Routes a scheduler grant by ownership rather than by currentness.
    pub fn resumeRunnable(
        self: *SourceReload,
        handle: task.TaskHandle,
    ) !void {
        if (self.candidate) |candidate| if (candidate.vm.ownsSchedulerTask(handle)) {
            _ = candidate.resumeRunnable(handle, &self.diagnostic) catch |err| {
                lua.recordDiagnosticError(
                    &self.diagnostic,
                    self.allocator,
                    .evaluate,
                    candidate.snapshot.entry_name,
                    err,
                );
                candidate.destroy();
                self.candidate = null;
                self.candidate_failure = err;
                return;
            };
            if (candidate.application_ready and
                !std.mem.eql(u8, candidate.application.id, self.active_generation.application.id))
            {
                const err = error.ApplicationIdChanged;
                lua.recordDiagnosticError(
                    &self.diagnostic,
                    self.allocator,
                    .declaration,
                    candidate.snapshot.entry_name,
                    err,
                );
                candidate.destroy();
                self.candidate = null;
                self.candidate_failure = err;
            }
            return;
        };
        if (self.active_generation.vm.ownsSchedulerTask(handle)) {
            _ = try self.active_generation.vm.resumeRunnable(handle);
            return;
        }
        for (self.retiring_generations) |entry| if (entry) |retiring|
            if (retiring.generation.vm.ownsSchedulerTask(handle)) {
                _ = try retiring.generation.vm.resumeRunnable(handle);
                return;
            };
        return error.UnownedSourceTask;
    }

    pub fn markFileCompleted(self: *SourceReload, completion: io_loop.FileCompletion) !void {
        if (self.candidate) |candidate|
            if (try candidate.dispatchFile(completion)) return;
        if (try self.active_generation.dispatchFile(completion)) return;
        for (self.retiring_generations) |entry| if (entry) |retiring|
            if (try retiring.generation.dispatchFile(completion)) return;
        return error.UnownedSourceOperation;
    }

    /// Routes completion-phase state to the VM that prepared the operation.
    pub fn markTimeoutCompleted(
        self: *SourceReload,
        operation: io_loop.OperationHandle,
    ) !void {
        if (self.active_generation.vm.ownsOperation(operation))
            return self.active_generation.vm.markTimeoutCompleted(operation);
        for (self.retiring_generations) |entry| if (entry) |retiring|
            if (retiring.generation.vm.ownsOperation(operation))
                return retiring.generation.vm.markTimeoutCompleted(operation);
        return error.UnownedSourceOperation;
    }

    /// Destroys a retiring VM only after both native handoff and asynchronous
    /// task/resource retirement have completed.
    pub fn collectRetired(self: *SourceReload) usize {
        var collected: usize = 0;
        for (&self.retiring_generations) |*entry| {
            const retiring = entry.* orelse continue;
            if (!retiring.native_state_detached or
                retiring.generation.vm.activeTaskCount() != 0) continue;
            if (self.services) |services|
                if (services.callbacks.countForVm(&retiring.generation.vm) != 0) continue;
            retiring.generation.destroy();
            entry.* = null;
            collected += 1;
        }
        return collected;
    }

    fn clearDiagnostic(self: *SourceReload) void {
        if (self.diagnostic) |*value| value.deinit();
        self.diagnostic = null;
    }

    fn recordBuildError(self: *SourceReload, err: anyerror) void {
        const candidate = self.candidate orelse return;
        lua.recordDiagnosticError(
            &self.diagnostic,
            self.allocator,
            .build,
            candidate.snapshot.entry_name,
            err,
        );
    }
};

fn findWindowTarget(targets: []const WindowTarget, id: []const u8) ?WindowTarget {
    for (targets) |target| if (std.mem.eql(u8, target.id, id)) return target;
    return null;
}

const initial_source =
    \\local ouro = require("ouro")
    \\return ouro.app {
    \\  id = "dev.ouro.reload-test",
    \\  windows = {
    \\    ouro.window {
    \\      id = "main",
    \\      title = "Initial",
    \\      content = function() end,
    \\    },
    \\  },
    \\}
;

const replacement_source =
    \\local ouro = require("ouro")
    \\return ouro.app {
    \\  id = "dev.ouro.reload-test",
    \\  windows = {
    \\    ouro.window {
    \\      id = "main",
    \\      title = "Replacement",
    \\      content = function() end,
    \\    },
    \\  },
    \\}
;

const changed_identity_source =
    \\local ouro = require("ouro")
    \\return ouro.app {
    \\  id = "dev.ouro.other-app",
    \\  windows = {
    \\    ouro.window {
    \\      id = "main",
    \\      title = "Wrong identity",
    \\      content = function() end,
    \\    },
    \\  },
    \\}
;

test "failed candidates preserve active generation and valid source commits" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = initial_source,
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
        "app.lua",
    });
    defer std.testing.allocator.free(path);
    var provider = try bundle.SourceProvider.initDisk(std.testing.allocator, path);
    defer provider.deinit();
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 2, 2);
    defer scheduler.deinit();

    const initial_snapshot = try provider.snapshot(std.testing.io, std.testing.allocator);
    const initial = try SourceGeneration.create(
        std.testing.allocator,
        &scheduler,
        &loop,
        initial_snapshot,
        null,
        .{ .node_capacity = 8 },
        null,
    );
    var reload: SourceReload = undefined;
    reload.init(
        std.testing.allocator,
        std.testing.io,
        &provider,
        &scheduler,
        &loop,
        null,
        .{ .node_capacity = 8 },
        initial,
    );
    defer reload.deinit();
    const active = reload.active();

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = "return ouro.app {",
    });
    try std.testing.expectError(error.LuaLoadFailed, reload.prepare());
    try std.testing.expect(reload.active() == active);
    try std.testing.expectEqualStrings("Initial", active.application.windows[0].declaration.title);
    try std.testing.expectEqual(lua.DiagnosticPhase.compile, reload.lastDiagnostic().?.phase);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = changed_identity_source,
    });
    try std.testing.expectError(error.ApplicationIdChanged, reload.prepare());
    try std.testing.expect(reload.active() == active);
    try std.testing.expectEqual(lua.DiagnosticPhase.declaration, reload.lastDiagnostic().?.phase);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = replacement_source,
    });
    try reload.prepare();
    try std.testing.expect(reload.active() == active);
    try std.testing.expectEqualStrings("Initial", active.application.windows[0].declaration.title);
    _ = try active.vm.spawnApplication("local ouro = require('ouro'); ouro.sleep(1000); retired_ran = true");
    _ = try active.vm.resumeRunnable(scheduler.takeRunnable().?);
    const committed = reload.commit();
    try std.testing.expectEqual(@as(u64, 2), committed.generation);
    try std.testing.expect(committed.retired == active);
    try std.testing.expect(reload.active() != active);
    try std.testing.expectEqualStrings(
        "Replacement",
        reload.active().application.windows[0].declaration.title,
    );
    try std.testing.expect(reload.lastDiagnostic() == null);

    _ = try reload.active().vm.spawnApplication("active_ran = true");
    try reload.beginRetirement();
    while (scheduler.takeRunnable()) |handle| _ = try reload.resumeRunnable(handle);
    try std.testing.expect(!active.vm.globalBoolean("retired_ran"));
    try std.testing.expect(reload.active().vm.globalBoolean("active_ran"));
    try std.testing.expectEqual(@as(usize, 0), active.vm.activeTaskCount());
    reload.markRetiringNativeStateDetached(committed.retired);
    try std.testing.expectEqual(@as(usize, 1), reload.collectRetired());
    try std.testing.expectEqual(@as(usize, 0), reload.retiringCount());
}

test "disk reload keeps active generation while candidate requires modules" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = initial_source,
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
        "app.lua",
    });
    defer std.testing.allocator.free(path);
    var provider = try bundle.SourceProvider.initDisk(std.testing.allocator, path);
    defer provider.deinit();
    const module_root = (try provider.openModuleRoot(std.testing.io)).?;
    defer module_root.close(std.testing.io);
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 32, 16);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 2, 4);
    defer scheduler.deinit();
    const initial_snapshot = try provider.snapshot(std.testing.io, std.testing.allocator);
    const initial = try SourceGeneration.create(
        std.testing.allocator,
        &scheduler,
        &loop,
        initial_snapshot,
        null,
        .{ .node_capacity = 8, .module_capacity = 4 },
        null,
    );
    var reload: SourceReload = undefined;
    reload.init(
        std.testing.allocator,
        std.testing.io,
        &provider,
        &scheduler,
        &loop,
        null,
        .{ .node_capacity = 8, .module_capacity = 4 },
        initial,
    );
    defer reload.deinit();
    reload.attachModuleRoot(module_root.handle);

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "title.lua",
        .data = "return 'Required title'",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data =
        \\local ouro = require("ouro")
        \\local title = require("title")
        \\return ouro.app {
        \\  id = "dev.ouro.reload-test",
        \\  windows = {
        \\    ouro.window { id = "main", title = title, content = function() end },
        \\  },
        \\}
        ,
    });
    try reload.prepare();
    try std.testing.expect(!reload.candidateReady());
    try std.testing.expect(reload.active() == initial);

    while (!reload.candidateReady()) {
        while (scheduler.takeRunnable()) |runnable| try reload.resumeRunnable(runnable);
        if (reload.candidateReady()) break;
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| try reload.markFileCompleted(completion),
            .operation_cancel => {},
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(reload.active() == initial);
    try std.testing.expectEqualStrings(
        "Required title",
        reload.candidate.?.application.windows[0].declaration.title,
    );
}

test "application transaction prepares all retained windows before generation swap" {
    const text = @import("../text/root.zig");

    var provider = try bundle.SourceProvider.initEmbedded(
        std.testing.allocator,
        "transaction.lua",
        initial_source,
    );
    defer provider.deinit();
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 12, 2, 2);
    defer scheduler.deinit();
    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(std.testing.allocator, 4);
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    var paragraph_sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer paragraph_sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();

    const snapshot = try provider.snapshot(std.testing.io, std.testing.allocator);
    const initial = try SourceGeneration.create(
        std.testing.allocator,
        &scheduler,
        &loop,
        snapshot,
        null,
        .{ .node_capacity = 4, .semantic_text_capacity = 64 },
        null,
    );
    var reload: SourceReload = undefined;
    reload.init(
        std.testing.allocator,
        std.testing.io,
        &provider,
        &scheduler,
        &loop,
        null,
        .{ .node_capacity = 4, .semantic_text_capacity = 64 },
        initial,
    );
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var runtime: WindowRuntime = .{};
    try runtime.init(
        std.testing.allocator,
        &scheduler,
        window_scope,
        .{ .slot = 0, .generation = 1 },
        core.Color.rgba(1, 2, 3, 255),
        core.Color.rgba(4, 5, 6, 255),
        core.Color.rgba(7, 8, 9, 255),
        core.Color.rgba(10, 11, 12, 255),
        core.Color.rgba(13, 14, 15, 255),
        &initial.signals,
        &paragraph_sources,
        &paragraphs,
        .{ .node_capacity = 4, .command_capacity = 4 },
    );
    const targets = [_]WindowTarget{.{
        .id = "main",
        .runtime = &runtime,
        .size = .{ .width = 320, .height = 200 },
    }};

    try reload.prepare();
    const candidate = reload.candidate.?;
    try reload.prepareApplication(&targets);
    try std.testing.expect(reload.active() == initial);
    const committed = try reload.commitApplication(&targets, &callbacks);
    try std.testing.expect(reload.active() == candidate);
    try std.testing.expect(runtime.signals == &candidate.signals);
    try std.testing.expectEqual(@as(u64, 2), committed.generation);
    try reload.beginRetirement();
    try std.testing.expectEqual(@as(usize, 1), reload.collectRetired());

    try runtime.clear(&candidate.ui_build);
    try scheduler.applyQueuedCancellations();
    try runtime.collectRetired();
    runtime.deinit();
    try scheduler.destroyScope(window_scope);
    reload.deinit();
    callbacks.deinit();
}

test "a later window build failure leaves every retained window on the active generation" {
    const design = @import("../design/root.zig");
    const text = @import("../text/root.zig");

    const initial_two_windows =
        \\local ouro = require("ouro")
        \\local function content(label)
        \\  return function()
        \\    ouro.column {
        \\      key = "content",
        \\      children = function()
        \\        ouro.label { key = "label", text = label }
        \\      end,
        \\    }
        \\  end
        \\end
        \\return ouro.app {
        \\  id = "dev.ouro.atomic-window-test",
        \\  windows = {
        \\    ouro.window { id = "first", title = "First", content = content("Active first") },
        \\    ouro.window { id = "second", title = "Second", content = content("Active second") },
        \\  },
        \\}
    ;
    const failing_second_window =
        \\local ouro = require("ouro")
        \\return ouro.app {
        \\  id = "dev.ouro.atomic-window-test",
        \\  windows = {
        \\    ouro.window {
        \\      id = "first",
        \\      title = "Changed first",
        \\      content = function()
        \\        ouro.column {
        \\          key = "content",
        \\          children = function()
        \\            ouro.label { key = "label", text = "Candidate first" }
        \\          end,
        \\        }
        \\      end,
        \\    },
        \\    ouro.window {
        \\      id = "second",
        \\      title = "Changed second",
        \\      content = function() error("candidate second failed") end,
        \\    },
        \\  },
        \\}
    ;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = initial_two_windows,
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
        "app.lua",
    });
    defer std.testing.allocator.free(path);
    var provider = try bundle.SourceProvider.initDisk(std.testing.allocator, path);
    defer provider.deinit();
    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 24, 4, 4);
    defer scheduler.deinit();
    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(std.testing.allocator, 16);
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
    defer fonts.release(font) catch unreachable;
    var paragraph_sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer paragraph_sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const services: source_generation.UiServices = .{
        .paragraph_sources = &paragraph_sources,
        .paragraphs = &paragraphs,
        .primary_font = font,
        .medium_font = font,
        .theme = design.tokens.light,
        .callbacks = &callbacks,
    };
    const config: source_generation.Config = .{
        .node_capacity = 8,
        .semantic_text_capacity = 128,
    };

    const snapshot = try provider.snapshot(std.testing.io, std.testing.allocator);
    const initial = try SourceGeneration.create(
        std.testing.allocator,
        &scheduler,
        &loop,
        snapshot,
        services,
        config,
        null,
    );
    var reload: SourceReload = undefined;
    reload.init(
        std.testing.allocator,
        std.testing.io,
        &provider,
        &scheduler,
        &loop,
        services,
        config,
        initial,
    );

    var scopes: [2]task.ScopeHandle = undefined;
    var runtimes = [_]WindowRuntime{.{}} ** 2;
    for (&runtimes, 0..) |*runtime, index| {
        scopes[index] = try scheduler.createScope(scheduler.application_scope);
        try runtime.init(
            std.testing.allocator,
            &scheduler,
            scopes[index],
            .{ .slot = @intCast(index), .generation = 1 },
            core.Color.rgba(1, 2, 3, 255),
            core.Color.rgba(4, 5, 6, 255),
            core.Color.rgba(7, 8, 9, 255),
            core.Color.rgba(10, 11, 12, 255),
            core.Color.rgba(13, 14, 15, 255),
            &initial.signals,
            &paragraph_sources,
            &paragraphs,
            .{ .node_capacity = 8, .command_capacity = 16 },
        );
        try runtime.reconcile(
            .{ .width = 320, .height = 200 },
            &initial.ui_build,
            initial.application.windows[index].content_reference,
        );
    }
    try std.testing.expectEqualStrings("Active first", (try runtimes[0].semantics.node(1)).label);
    try std.testing.expectEqualStrings("Active second", (try runtimes[1].semantics.node(1)).label);
    const first_instance_count = runtimes[0].instances.activeCount();
    const second_instance_count = runtimes[1].instances.activeCount();

    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = failing_second_window,
    });
    try reload.prepare();
    const targets = [_]WindowTarget{
        .{ .id = "first", .runtime = &runtimes[0], .size = .{ .width = 320, .height = 200 } },
        .{ .id = "second", .runtime = &runtimes[1], .size = .{ .width = 320, .height = 200 } },
    };
    var build_failed = false;
    reload.prepareApplication(&targets) catch {
        build_failed = true;
    };
    try std.testing.expect(build_failed);
    try std.testing.expect(reload.active() == initial);
    try std.testing.expect(reload.candidate == null);
    try std.testing.expect(runtimes[0].signals == &initial.signals);
    try std.testing.expect(runtimes[1].signals == &initial.signals);
    try std.testing.expectEqual(first_instance_count, runtimes[0].instances.activeCount());
    try std.testing.expectEqual(second_instance_count, runtimes[1].instances.activeCount());
    try std.testing.expectEqualStrings("Active first", (try runtimes[0].semantics.node(1)).label);
    try std.testing.expectEqualStrings("Active second", (try runtimes[1].semantics.node(1)).label);
    try std.testing.expectEqual(lua.DiagnosticPhase.build, reload.lastDiagnostic().?.phase);

    for (&runtimes) |*runtime| try runtime.clear(&initial.ui_build);
    try scheduler.applyQueuedCancellations();
    for (&runtimes) |*runtime| {
        try runtime.collectRetired();
        runtime.deinit();
    }
    for (scopes) |scope| try scheduler.destroyScope(scope);
    reload.deinit();
    callbacks.deinit();
}
