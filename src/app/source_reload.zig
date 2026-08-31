const std = @import("std");
const bundle = @import("../bundle/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const task = @import("../task/root.zig");
const source_generation = @import("source_generation.zig");

const SourceGeneration = source_generation.SourceGeneration;

pub const Commit = struct {
    generation: u64,
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
        self.active_generation.destroy();
        if (self.diagnostic) |*value| value.deinit();
        self.* = undefined;
    }

    pub fn active(self: *const SourceReload) *SourceGeneration {
        return self.active_generation;
    }

    pub fn lastDiagnostic(self: *const SourceReload) ?*const lua.Diagnostic {
        return if (self.diagnostic) |*value| value else null;
    }

    /// Builds a complete candidate declaration from a fresh source snapshot.
    /// The active generation remains authoritative until `commit` is called.
    pub fn prepare(self: *SourceReload) !void {
        if (self.candidate != null) return error.SourceCandidateAlreadyPrepared;
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
        const candidate = self.candidate orelse @panic("source generation commit without candidate");
        const retired = self.active_generation;
        self.active_generation = candidate;
        self.candidate = null;
        self.generation += 1;
        self.clearDiagnostic();
        return .{ .generation = self.generation, .retired = retired };
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
    const committed = reload.commit();
    defer committed.retired.destroy();
    try std.testing.expectEqual(@as(u64, 2), committed.generation);
    try std.testing.expect(reload.active() != active);
    try std.testing.expectEqualStrings(
        "Replacement",
        reload.active().application.windows[0].declaration.title,
    );
    try std.testing.expect(reload.lastDiagnostic() == null);
}
