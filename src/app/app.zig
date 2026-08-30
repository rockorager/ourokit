const std = @import("std");
const IoLoop = @import("../loop/io_uring.zig").Loop;
const Scheduler = @import("../task/scheduler.zig").Scheduler;
const LuaVm = @import("../lua/vm.zig").Vm;
const lua_c = @import("../lua/c.zig");
const turn = @import("turn.zig");

pub const Phase = turn.Phase;

/// Small lifecycle and phase coordinator. Implementations remain in sibling
/// modules. `App` must retain a stable address after initialization.
pub const App = struct {
    loop: IoLoop,
    scheduler: Scheduler,
    lua_vm: LuaVm,
    turn: turn.Coordinator = .{},

    pub fn init(self: *App, allocator: std.mem.Allocator) !void {
        try self.loop.init(allocator, 32, 16);
        errdefer self.loop.deinit();
        try self.scheduler.init(allocator, 8, 16, 32);
        errdefer self.scheduler.deinit();
        try self.lua_vm.init(allocator, &self.scheduler, &self.loop);
        self.turn = .{};
    }

    pub fn deinit(self: *App) void {
        self.lua_vm.deinit();
        self.scheduler.deinit();
        self.loop.deinit();
        self.* = undefined;
    }

    pub fn prepareScript(self: *App, source: []const u8) !void {
        _ = try self.lua_vm.spawnApplication(source);
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
            .timeout => |timeout| try self.lua_vm.markTimeoutCompleted(timeout.operation),
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
            _ = try self.lua_vm.resumeRunnable(handle);
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

    try std.testing.expect(app.lua_vm.hasGlobal("ouro"));
    try std.testing.expect(!app.lua_vm.hasGlobal("print"));
    try std.testing.expect(!app.lua_vm.hasGlobal("package"));
    try std.testing.expect(!app.lua_vm.hasGlobal("coroutine"));
    try app.prepareScript("done = false; ouro.sleep(1); done = true");
    try app.runReadyTurn();
    try std.testing.expect(!app.lua_vm.globalBoolean("done"));

    try app.reapOne();
    try std.testing.expectEqual(Phase.idle, app.phase());
    try std.testing.expect(!app.lua_vm.globalBoolean("done"));

    try app.runReadyTurn();
    try std.testing.expect(app.lua_vm.globalBoolean("done"));

    // Completion closes and unreferences the first coroutine, so the same VM
    // can host a subsequent scoped task without retaining its old stack.
    try app.prepareScript("second = true");
    try app.runReadyTurn();
    try std.testing.expect(app.lua_vm.globalBoolean("second"));
}

test "independent Lua coroutine tasks wait and resume through direct operation routing" {
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();

    try app.prepareScript("first = false; ouro.sleep(1); first = true");
    try app.prepareScript("second = false; ouro.sleep(2); second = true");
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 2), app.lua_vm.activeTaskCount());
    try std.testing.expect(!app.lua_vm.globalBoolean("first"));
    try std.testing.expect(!app.lua_vm.globalBoolean("second"));

    try app.reapOne();
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 1), app.lua_vm.activeTaskCount());
    try app.reapOne();
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 0), app.lua_vm.activeTaskCount());
    try std.testing.expect(app.lua_vm.globalBoolean("first"));
    try std.testing.expect(app.lua_vm.globalBoolean("second"));
}

test "existing Lua handlers spawn as scoped yieldable tasks with typed arguments" {
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();
    try app.prepareScript(
        \\function handler(value)
        \\  handler_started = value == 7
        \\  ouro.sleep(1)
        \\  handler_done = true
        \\end
    );
    try app.runReadyTurn();
    const scope = try app.scheduler.createScope(app.scheduler.application_scope);
    _ = try app.lua_vm.spawnGlobal(scope, "handler", &.{.{ .integer = 7 }});
    try app.runReadyTurn();
    try std.testing.expect(app.lua_vm.globalBoolean("handler_started"));
    try std.testing.expect(!app.lua_vm.globalBoolean("handler_done"));
    try app.reapOne();
    try app.runReadyTurn();
    try std.testing.expect(app.lua_vm.globalBoolean("handler_done"));
    try app.scheduler.destroyScope(scope);
}

test "Lua coroutine slabs and scheduler routing grow without moving active tasks" {
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();

    // One task enters I/O before later spawns force both a second Lua slab and
    // scheduler-directory growth. Its resource context must remain stable.
    try app.prepareScript("sleeper_done = false; ouro.sleep(1); sleeper_done = true");
    try app.runReadyTurn();
    for (0..40) |_| try app.prepareScript("spawned = true");
    try std.testing.expectEqual(@as(usize, 41), app.lua_vm.activeTaskCount());
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 1), app.lua_vm.activeTaskCount());
    try std.testing.expect(app.lua_vm.globalBoolean("spawned"));

    try app.reapOne();
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 0), app.lua_vm.activeTaskCount());
    try std.testing.expect(app.lua_vm.globalBoolean("sleeper_done"));
}

test "scope cancellation stops only its owned Lua coroutine tasks" {
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();
    const first_scope = try app.scheduler.createScope(app.scheduler.application_scope);
    const second_scope = try app.scheduler.createScope(app.scheduler.application_scope);
    _ = try app.lua_vm.spawn(first_scope, "first_after = false; ouro.sleep(60000); first_after = true");
    _ = try app.lua_vm.spawn(second_scope, "second_after = false; ouro.sleep(60000); second_after = true");
    try app.runReadyTurn();

    try app.scheduler.queueScopeCancellation(first_scope);
    try app.runReadyTurn();
    try app.reapOne();
    try app.reapOne();
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 1), app.lua_vm.activeTaskCount());
    try std.testing.expect(!app.lua_vm.globalBoolean("first_after"));

    try app.scheduler.queueScopeCancellation(second_scope);
    try app.runReadyTurn();
    try app.reapOne();
    try app.reapOne();
    try app.runReadyTurn();
    try std.testing.expectEqual(@as(usize, 0), app.lua_vm.activeTaskCount());
    try std.testing.expect(!app.lua_vm.globalBoolean("second_after"));
    try app.scheduler.destroyScope(first_scope);
    try app.scheduler.destroyScope(second_scope);
}

test "canceling a suspended Lua task closes to-be-closed values" {
    const CloseProbe = struct {
        closed: bool = false,

        fn install(self: *@This(), state: *lua_c.State) void {
            lua_c.lua_pushlightuserdata(state, self);
            lua_c.lua_pushcclosure(state, create, 1);
            lua_c.lua_setglobal(state, "make_close_probe");
        }

        fn create(state: *lua_c.State) callconv(.c) c_int {
            const self = fromUpvalue(state);
            _ = lua_c.lua_newuserdatauv(state, 1, 0) orelse return luaError(state);
            lua_c.lua_createtable(state, 0, 1);
            lua_c.lua_pushlightuserdata(state, self);
            lua_c.lua_pushcclosure(state, close, 1);
            lua_c.lua_setfield(state, -2, "__close");
            _ = lua_c.lua_setmetatable(state, -2);
            return 1;
        }

        fn close(state: *lua_c.State) callconv(.c) c_int {
            fromUpvalue(state).closed = true;
            return 0;
        }

        fn fromUpvalue(state: *lua_c.State) *@This() {
            const pointer = lua_c.lua_touserdata(state, lua_c.upvalueIndex(1)).?;
            return @ptrCast(@alignCast(pointer));
        }

        fn luaError(state: *lua_c.State) c_int {
            _ = lua_c.lua_pushstring(state, "cannot allocate close probe");
            return lua_c.lua_error(state);
        }
    };

    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();
    var probe: CloseProbe = .{};
    probe.install(app.lua_vm.state);
    try app.prepareScript(
        \\local resource <close> = make_close_probe()
        \\ouro.sleep(60000)
    );
    try app.runReadyTurn();
    try std.testing.expect(!probe.closed);

    try app.scheduler.queueScopeCancellation(app.scheduler.application_scope);
    try app.runReadyTurn();
    try app.reapOne();
    try app.reapOne();
    try app.runReadyTurn();
    try std.testing.expect(probe.closed);
}
