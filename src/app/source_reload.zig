const std = @import("std");
const bundle = @import("../bundle/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const task = @import("../task/root.zig");
const source_generation = @import("source_generation.zig");

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
        const candidate = SourceGeneration.create(
            self.allocator,
            self.scheduler,
            self.loop,
            snapshot,
            self.services,
            self.config,
            &self.diagnostic,
        ) catch |err| return err;
        errdefer candidate.destroy();
        if (!std.mem.eql(u8, candidate.application.id, self.active_generation.application.id)) {
            lua.recordDiagnosticError(
                &self.diagnostic,
                self.allocator,
                .declaration,
                candidate.snapshot.entry_name,
                error.ApplicationIdChanged,
            );
            return error.ApplicationIdChanged;
        }
        self.candidate = candidate;
    }

    pub fn discard(self: *SourceReload) void {
        const candidate = self.candidate orelse return;
        candidate.destroy();
        self.candidate = null;
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
};

const initial_source =
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
    _ = try active.vm.spawnApplication("ouro.sleep(1000); retired_ran = true");
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
    _ = try loop.submit();
    var timeout_seen = false;
    var cancel_seen = false;
    while (!timeout_seen or !cancel_seen) switch (loop.dispatch(try loop.wait())) {
        .timeout => |timeout| {
            try reload.markTimeoutCompleted(timeout.operation);
            timeout_seen = true;
        },
        .timeout_cancel => cancel_seen = true,
        else => return error.UnexpectedCompletion,
    };
    while (scheduler.takeRunnable()) |handle| _ = try reload.resumeRunnable(handle);
    try std.testing.expect(!active.vm.globalBoolean("retired_ran"));
    try std.testing.expect(reload.active().vm.globalBoolean("active_ran"));
    try std.testing.expectEqual(@as(usize, 0), active.vm.activeTaskCount());
    reload.markRetiringNativeStateDetached(committed.retired);
    try std.testing.expectEqual(@as(usize, 1), reload.collectRetired());
    try std.testing.expectEqual(@as(usize, 0), reload.retiringCount());
}
