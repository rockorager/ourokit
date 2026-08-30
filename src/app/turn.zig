const std = @import("std");

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

pub const Hook = *const fn (*anyopaque) anyerror!void;

/// The only entry point for a nonblocking application turn. Keeping the order
/// here makes safe points structural rather than a convention duplicated by
/// each application host. Hook implementations remain in their owning sibling
/// modules and may only perform work permitted by their named phase.
pub const ReadyHooks = struct {
    context: *anyopaque,
    translate_platform_events: Hook,
    mark_tasks_runnable: Hook,
    resume_tasks: Hook,
    reconcile_instances: Hook,
    layout_and_build_scenes: Hook,
    submit_frames: Hook,
    flush_wayland_and_submissions: Hook,
};

pub const Coordinator = struct {
    phase: Phase = .idle,

    pub fn reap(self: *Coordinator, context: *anyopaque, hook: Hook) !void {
        try self.enter(.reap_completions_and_wayring);
        defer self.phase = .idle;
        try hook(context);
    }

    pub fn runReadyTurn(self: *Coordinator, hooks: ReadyHooks) !void {
        if (self.phase != .idle) return error.TurnAlreadyRunning;
        defer self.phase = .idle;

        try self.run(.translate_platform_events, hooks.context, hooks.translate_platform_events);
        try self.run(.mark_tasks_runnable, hooks.context, hooks.mark_tasks_runnable);
        try self.run(.resume_tasks, hooks.context, hooks.resume_tasks);
        try self.run(.reconcile_instances, hooks.context, hooks.reconcile_instances);
        try self.run(.layout_and_build_scenes, hooks.context, hooks.layout_and_build_scenes);
        try self.run(.submit_frames, hooks.context, hooks.submit_frames);
        try self.run(
            .flush_wayland_and_submissions,
            hooks.context,
            hooks.flush_wayland_and_submissions,
        );
    }

    fn run(self: *Coordinator, phase: Phase, context: *anyopaque, hook: Hook) !void {
        self.phase = phase;
        try hook(context);
    }

    fn enter(self: *Coordinator, phase: Phase) !void {
        if (self.phase != .idle) return error.TurnAlreadyRunning;
        self.phase = phase;
    }
};

test "coordinator fixes ready-turn order and restores idle after failure" {
    const Recorder = struct {
        coordinator: *Coordinator,
        phases: [7]Phase = undefined,
        count: usize = 0,
        fail_at: ?Phase = null,

        fn record(pointer: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            const phase = self.coordinator.phase;
            if (self.fail_at == phase) return error.InjectedFailure;
            self.phases[self.count] = phase;
            self.count += 1;
        }

        fn hooks(self: *@This()) ReadyHooks {
            return .{
                .context = self,
                .translate_platform_events = record,
                .mark_tasks_runnable = record,
                .resume_tasks = record,
                .reconcile_instances = record,
                .layout_and_build_scenes = record,
                .submit_frames = record,
                .flush_wayland_and_submissions = record,
            };
        }
    };

    var coordinator: Coordinator = .{};
    var recorder: Recorder = .{ .coordinator = &coordinator };
    try coordinator.runReadyTurn(recorder.hooks());
    try std.testing.expectEqualSlices(Phase, &.{
        .translate_platform_events,
        .mark_tasks_runnable,
        .resume_tasks,
        .reconcile_instances,
        .layout_and_build_scenes,
        .submit_frames,
        .flush_wayland_and_submissions,
    }, recorder.phases[0..recorder.count]);
    try std.testing.expectEqual(Phase.idle, coordinator.phase);

    recorder.count = 0;
    recorder.fail_at = .resume_tasks;
    try std.testing.expectError(error.InjectedFailure, coordinator.runReadyTurn(recorder.hooks()));
    try std.testing.expectEqual(Phase.idle, coordinator.phase);
}
