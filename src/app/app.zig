const std = @import("std");
const IoLoop = @import("../loop/io_uring.zig").Loop;
const Scheduler = @import("../task/scheduler.zig").Scheduler;
const LuaTask = @import("../lua/task.zig").Task;

pub const Phase = enum {
    idle,
    reap_completions_and_wayring,
    translate_platform_events,
    mark_tasks_runnable,
    resume_tasks,
    reconcile_instances,
    layout_and_build_scenes,
    submit_frames,
    flush_wayland_and_submissions,
};

/// Small lifecycle and phase coordinator. Implementations remain in sibling
/// modules. `App` must retain a stable address after initialization.
pub const App = struct {
    loop: IoLoop,
    scheduler: Scheduler,
    lua_task: LuaTask,
    phase: Phase = .idle,

    pub fn init(self: *App, allocator: std.mem.Allocator) !void {
        try self.loop.init(allocator, 32, 16);
        errdefer self.loop.deinit();
        try self.scheduler.init(allocator, 8, 16, 32);
        errdefer self.scheduler.deinit();
        try self.lua_task.init(&self.scheduler, &self.loop);
        self.phase = .idle;
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
        self.translatePlatformEvents();
        self.markTasksRunnable();
        try self.resumeTasks();
        self.reconcileInstances();
        self.layoutAndBuildScenes();
        self.submitFrames();
        try self.flush();
        self.phase = .idle;
    }

    /// Waits for one CQE and performs state-only dispatch. This method cannot
    /// call into Lua; a subsequent `runReadyTurn` owns that safe point.
    pub fn reapOne(self: *App) !void {
        self.phase = .reap_completions_and_wayring;
        switch (self.loop.dispatch(try self.loop.wait())) {
            .timeout => |completion| try self.lua_task.markTimeoutCompleted(completion.operation),
            .timeout_cancel => {},
            .foreign => return error.ForeignCompletion,
            .stale => return error.StaleCompletion,
        }
        self.phase = .idle;
    }

    fn translatePlatformEvents(self: *App) void {
        self.phase = .translate_platform_events;
        // The Wayland adapter will append translated Ourokit platform events.
    }

    fn markTasksRunnable(self: *App) void {
        self.phase = .mark_tasks_runnable;
        // CQE/platform phases already changed state; scope cancellation is
        // applied only at the immediately following task safe point.
    }

    fn resumeTasks(self: *App) !void {
        self.phase = .resume_tasks;
        try self.scheduler.applyQueuedCancellations();
        while (self.scheduler.takeRunnable()) |handle| {
            try self.lua_task.resumeRunnable(handle);
        }
    }

    fn reconcileInstances(self: *App) void {
        self.phase = .reconcile_instances;
    }

    fn layoutAndBuildScenes(self: *App) void {
        self.phase = .layout_and_build_scenes;
    }

    fn submitFrames(self: *App) void {
        self.phase = .submit_frames;
    }

    fn flush(self: *App) !void {
        self.phase = .flush_wayland_and_submissions;
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
    try std.testing.expectEqual(Phase.idle, app.phase);
    try std.testing.expect(!app.lua_task.globalBoolean("done"));

    try app.runReadyTurn();
    try std.testing.expect(app.lua_task.globalBoolean("done"));
}
