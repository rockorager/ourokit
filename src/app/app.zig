const std = @import("std");
const IoLoop = @import("../loop/io_uring.zig").Loop;
const Scheduler = @import("../task/scheduler.zig").Scheduler;
const LuaTask = @import("../lua/task.zig").Task;
const turn = @import("turn.zig");

pub const Phase = turn.Phase;

/// Small lifecycle and phase coordinator. Implementations remain in sibling
/// modules. `App` must retain a stable address after initialization.
pub const App = struct {
    loop: IoLoop,
    scheduler: Scheduler,
    lua_task: LuaTask,
    turn: turn.Coordinator = .{},

    pub fn init(self: *App, allocator: std.mem.Allocator) !void {
        try self.loop.init(allocator, 32, 16);
        errdefer self.loop.deinit();
        try self.scheduler.init(allocator, 8, 16, 32);
        errdefer self.scheduler.deinit();
        try self.lua_task.init(&self.scheduler, &self.loop);
        self.turn = .{};
    }

    pub fn deinit(self: *App) void {
        self.lua_task.deinit();
        self.scheduler.deinit();
        self.loop.deinit();
        self.* = undefined;
    }

    pub fn prepareScript(self: *App, source: []const u8) !void {
        _ = try self.lua_task.prepare(source);
    }

    /// Runs all nonblocking phases and submits SQEs prepared by runnable tasks.
    pub fn runReadyTurn(self: *App) !void {
        try self.turn.runReadyTurn(.{
            .context = self,
            .translate_platform_events = translatePlatformEvents,
            .mark_tasks_runnable = markTasksRunnable,
            .resume_tasks = resumeTasks,
            .reconcile_instances = reconcileInstances,
            .layout_and_build_scenes = layoutAndBuildScenes,
            .submit_frames = submitFrames,
            .flush_wayland_and_submissions = flush,
        });
    }

    /// Waits for one CQE and performs state-only dispatch. This method cannot
    /// call into Lua; a subsequent `runReadyTurn` owns that safe point.
    pub fn reapOne(self: *App) !void {
        const Reap = struct {
            app: *App,
            completion: std.os.linux.io_uring_cqe,

            fn dispatch(context: *anyopaque) !void {
                const reap: *@This() = @ptrCast(@alignCast(context));
                try reap.app.dispatchCompletion(reap.completion);
            }
        };
        var reap = Reap{ .app = self, .completion = try self.loop.wait() };
        try self.turn.reap(&reap, Reap.dispatch);
    }

    pub fn phase(self: *const App) Phase {
        return self.turn.phase;
    }

    fn dispatchCompletion(self: *App, completion: std.os.linux.io_uring_cqe) !void {
        switch (self.loop.dispatch(completion)) {
            .timeout => |timeout| try self.lua_task.markTimeoutCompleted(timeout.operation),
            .timeout_cancel => {},
            .foreign => return error.ForeignCompletion,
            .stale => return error.StaleCompletion,
        }
    }

    fn translatePlatformEvents(context: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self;
        // The Wayland adapter will append translated Ourokit platform events.
    }

    fn markTasksRunnable(context: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self;
        // CQE/platform phases already changed state; scope cancellation is
        // applied only at the immediately following task safe point.
    }

    fn resumeTasks(context: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(context));
        try self.scheduler.applyQueuedCancellations();
        while (self.scheduler.takeRunnable()) |handle| {
            try self.lua_task.resumeRunnable(handle);
        }
    }

    fn reconcileInstances(context: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self;
    }

    fn layoutAndBuildScenes(context: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self;
    }

    fn submitFrames(context: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self;
    }

    fn flush(context: *anyopaque) !void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = try self.loop.submit();
    }
};

test "io_uring completion marks Lua runnable without re-entering it" {
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expect(app.lua_task.hasGlobal("ouro"));
    try std.testing.expect(!app.lua_task.hasGlobal("print"));
    try std.testing.expect(!app.lua_task.hasGlobal("package"));
    try std.testing.expect(!app.lua_task.hasGlobal("coroutine"));
    try app.prepareScript("done = false; ouro.sleep(1); done = true");
    try app.runReadyTurn();
    try std.testing.expect(!app.lua_task.globalBoolean("done"));

    try app.reapOne();
    try std.testing.expectEqual(Phase.idle, app.phase());
    try std.testing.expect(!app.lua_task.globalBoolean("done"));

    try app.runReadyTurn();
    try std.testing.expect(app.lua_task.globalBoolean("done"));
}
