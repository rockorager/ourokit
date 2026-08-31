const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const platform_window = @import("../../platform/window.zig");
const instance = @import("../instance/root.zig");
const render_object = @import("../render_object/root.zig");
const text_input = @import("../text_input/root.zig");

pub const Event = union(enum) {
    hover_enter: struct {
        target: instance.InstanceHandle,
        position: PointF,
        serial: ?u32,
    },
    hover_leave: struct {
        target: instance.InstanceHandle,
        serial: ?u32,
    },
    pointer: struct {
        target: instance.InstanceHandle,
        hovered: ?instance.InstanceHandle,
        position: PointF,
        event: platform_window.PointerEvent,
    },
    keyboard: platform_window.KeyboardEvent,
    text_input: struct {
        batch: text_input.EditBatch,
        serial_matches_state: bool,
    },
};

/// State-only pointer router. Platform events become bounded instance-targeted
/// data during the input phase; taking an event later cannot execute language
/// or widget code. The ring queue keeps high-rate motion delivery O(1).
pub const Router = struct {
    allocator: std.mem.Allocator,
    render_tree: *render_object.Tree,
    instances: *instance.Tree,
    window: platform_window.WindowHandle,
    events: []Event,
    head: usize = 0,
    count: usize = 0,
    hovered: ?instance.InstanceHandle = null,
    captured: ?instance.InstanceHandle = null,
    pointer_position: PointF = .{},

    pub fn init(
        self: *Router,
        allocator: std.mem.Allocator,
        render_tree: *render_object.Tree,
        instances: *instance.Tree,
        window: platform_window.WindowHandle,
        event_capacity: usize,
    ) !void {
        if (event_capacity == 0) return error.InvalidCapacity;
        const events = try allocator.alloc(Event, event_capacity);
        self.* = .{
            .allocator = allocator,
            .render_tree = render_tree,
            .instances = instances,
            .window = window,
            .events = events,
        };
    }

    pub fn deinit(self: *Router) void {
        std.debug.assert(self.count == 0);
        self.allocator.free(self.events);
        self.* = undefined;
    }

    pub fn route(self: *Router, event: platform_window.PointerEvent) !void {
        if (!sameWindow(pointerWindow(event), self.window)) return error.WrongWindow;
        if (self.hovered) |hovered| if (!self.instances.isActive(hovered)) {
            self.hovered = null;
        };
        switch (event) {
            .enter => |enter| {
                self.pointer_position = enter.position;
                const target = try self.targetAt(enter.position);
                try self.ensureSpace(transitionCount(self.hovered, target));
                self.transition(target, enter.position, enter.serial);
            },
            .leave => |leave| {
                try self.ensureSpace(if (self.hovered == null) 0 else 1);
                if (self.hovered) |hovered|
                    self.enqueueAssumeCapacity(.{ .hover_leave = .{
                        .target = hovered,
                        .serial = leave.serial,
                    } });
                self.hovered = null;
            },
            .motion => |motion| {
                self.pointer_position = motion.position;
                const target = try self.targetAt(motion.position);
                try self.ensureSpace(transitionCount(self.hovered, target) +
                    @as(usize, @intFromBool(target != null)));
                self.transition(target, motion.position, null);
                if (target) |handle| self.enqueueAssumeCapacity(.{ .pointer = .{
                    .target = handle,
                    .hovered = target,
                    .position = self.pointer_position,
                    .event = event,
                } });
            },
            .button => |button| {
                const target = switch (button.state) {
                    .pressed => self.hovered orelse return,
                    .released => self.captured orelse self.hovered orelse return,
                };
                try self.ensureSpace(1);
                self.enqueueAssumeCapacity(.{ .pointer = .{
                    .target = target,
                    .hovered = self.hovered,
                    .position = self.pointer_position,
                    .event = event,
                } });
                self.captured = switch (button.state) {
                    .pressed => target,
                    .released => null,
                };
            },
            else => {
                const target = self.hovered orelse self.captured orelse return;
                try self.ensureSpace(1);
                self.enqueueAssumeCapacity(.{ .pointer = .{
                    .target = target,
                    .hovered = self.hovered,
                    .position = self.pointer_position,
                    .event = event,
                } });
            },
        }
    }

    pub fn routeKeyboard(self: *Router, event: platform_window.KeyboardEvent) !void {
        if (!sameWindow(keyboardWindow(event), self.window)) return error.WrongWindow;
        try self.ensureSpace(1);
        self.enqueueAssumeCapacity(.{ .keyboard = event });
    }

    pub fn routeTextInput(
        self: *Router,
        batch_value: text_input.EditBatch,
        serial_matches_state: bool,
    ) !void {
        try self.ensureSpace(1);
        var batch = batch_value;
        var commit_text: ?[]u8 = null;
        errdefer if (commit_text) |bytes| self.allocator.free(bytes);
        var preedit_text: ?[]u8 = null;
        errdefer if (preedit_text) |bytes| self.allocator.free(bytes);
        if (batch.commit) |*commit| if (commit.text) |value| {
            commit_text = try self.allocator.dupe(u8, value);
            commit.text = commit_text.?;
        };
        if (batch.preedit) |*preedit| if (preedit.text) |value| {
            preedit_text = try self.allocator.dupe(u8, value);
            preedit.text = preedit_text.?;
        };
        self.enqueueAssumeCapacity(.{ .text_input = .{
            .batch = batch,
            .serial_matches_state = serial_matches_state,
        } });
    }

    pub fn takeEvent(self: *Router) ?Event {
        if (self.count == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % self.events.len;
        self.count -= 1;
        return event;
    }

    pub fn releaseEvent(self: *Router, event: Event) void {
        if (event != .text_input) return;
        if (event.text_input.batch.preedit) |preedit| if (preedit.text) |bytes|
            self.allocator.free(@constCast(bytes));
        if (event.text_input.batch.commit) |commit| if (commit.text) |bytes|
            self.allocator.free(@constCast(bytes));
    }

    pub fn hoveredInstance(self: *const Router) ?instance.InstanceHandle {
        return self.hovered;
    }

    fn targetAt(self: *Router, position: PointF) !?instance.InstanceHandle {
        const root = (try self.instances.rootRenderObject()) orelse return null;
        const render = (try self.render_tree.hitTest(root, position)) orelse return null;
        return self.instances.instanceForRenderObject(render) orelse error.UnownedRenderObject;
    }

    fn transition(
        self: *Router,
        target: ?instance.InstanceHandle,
        position: PointF,
        serial: ?u32,
    ) void {
        if (optionalHandleEqual(self.hovered, target)) return;
        if (self.hovered) |hovered| self.enqueueAssumeCapacity(.{ .hover_leave = .{
            .target = hovered,
            .serial = serial,
        } });
        if (target) |next| self.enqueueAssumeCapacity(.{ .hover_enter = .{
            .target = next,
            .position = position,
            .serial = serial,
        } });
        self.hovered = target;
    }

    fn ensureSpace(self: *const Router, required: usize) !void {
        if (required > self.events.len - self.count) return error.InputEventCapacityExceeded;
    }

    fn enqueueAssumeCapacity(self: *Router, event: Event) void {
        std.debug.assert(self.count < self.events.len);
        const tail = (self.head + self.count) % self.events.len;
        self.events[tail] = event;
        self.count += 1;
    }
};

fn pointerWindow(event: platform_window.PointerEvent) platform_window.WindowHandle {
    return switch (event) {
        .enter => |value| value.window,
        .leave => |value| value.window,
        .motion => |value| value.window,
        .button => |value| value.window,
        .axis => |value| value.window,
        .axis_source => |value| value.window,
        .axis_stop => |value| value.window,
        .axis_steps => |value| value.window,
        .axis_steps120 => |value| value.window,
        .frame => |window| window,
    };
}

fn keyboardWindow(event: platform_window.KeyboardEvent) platform_window.WindowHandle {
    return switch (event) {
        .enter => |value| value.window,
        .leave => |value| value.window,
        .key => |value| value.window,
    };
}

fn transitionCount(
    old: ?instance.InstanceHandle,
    new: ?instance.InstanceHandle,
) usize {
    if (optionalHandleEqual(old, new)) return 0;
    return @as(usize, @intFromBool(old != null)) + @as(usize, @intFromBool(new != null));
}

fn optionalHandleEqual(a: ?instance.InstanceHandle, b: ?instance.InstanceHandle) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.slot == b.?.slot and a.?.generation == b.?.generation;
}

fn sameWindow(a: platform_window.WindowHandle, b: platform_window.WindowHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "pointer routing hit tests front to back and queues hover transitions" {
    const Scheduler = @import("../../task/scheduler.zig").Scheduler;
    const Constraints = @import("../layout/constraints.zig").Constraints;
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 3);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 3);
    defer instances.deinit();
    try instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 50, .height = 50 } } },
        .{
            .id = 3,
            .parent = 1,
            .object = .{ .box = .{ .width = 20, .height = 20 } },
            .parent_data = .{ .stack = .{ .x = 10, .y = 10 } },
        },
    });
    _ = try renders.layout(
        (try instances.rootRenderObject()).?,
        Constraints.tight(.{ .width = 100, .height = 80 }),
    );

    const window: platform_window.WindowHandle = .{ .slot = 4, .generation = 2 };
    var router: Router = undefined;
    try router.init(std.testing.allocator, &renders, &instances, window, 4);
    defer router.deinit();
    try router.route(.{ .enter = .{
        .window = window,
        .serial = 10,
        .position = .{ .x = 15, .y = 15 },
    } });
    const front = instances.handleForId(3).?;
    try std.testing.expectEqual(front, router.takeEvent().?.hover_enter.target);

    try router.route(.{ .motion = .{
        .window = window,
        .time_ms = 20,
        .position = .{ .x = 5, .y = 5 },
    } });
    const back = instances.handleForId(2).?;
    try std.testing.expectEqual(front, router.takeEvent().?.hover_leave.target);
    try std.testing.expectEqual(back, router.takeEvent().?.hover_enter.target);
    const motion = router.takeEvent().?.pointer;
    try std.testing.expectEqual(back, motion.target);
    try std.testing.expectEqual(@as(u32, 20), motion.event.motion.time_ms);

    try router.route(.{ .button = .{
        .window = window,
        .serial = 11,
        .time_ms = 21,
        .button = 0x110,
        .state = .pressed,
    } });
    try std.testing.expectEqual(back, router.takeEvent().?.pointer.target);
    try router.route(.{ .leave = .{ .window = window, .serial = 12 } });
    try std.testing.expectEqual(back, router.takeEvent().?.hover_leave.target);
    try router.route(.{ .button = .{
        .window = window,
        .serial = 13,
        .time_ms = 22,
        .button = 0x110,
        .state = .released,
    } });
    const captured_release = router.takeEvent().?.pointer;
    try std.testing.expectEqual(back, captured_release.target);
    try std.testing.expect(captured_release.hovered == null);
    try std.testing.expect(router.takeEvent() == null);

    var commit = [_]u8{ 'o', 'k' };
    var preedit = [_]u8{ 'n', 'e', 'w' };
    try router.routeTextInput(.{
        .commit = .{ .text = &commit },
        .preedit = .{ .text = &preedit, .cursor = .{ .start = 0, .end = 3 } },
    }, true);
    @memset(&commit, 'x');
    @memset(&preedit, 'x');
    const owned = router.takeEvent().?;
    defer router.releaseEvent(owned);
    try std.testing.expectEqualStrings("ok", owned.text_input.batch.commit.?.text.?);
    try std.testing.expectEqualStrings("new", owned.text_input.batch.preedit.?.text.?);

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "motion queue overflow is transactional" {
    const Scheduler = @import("../../task/scheduler.zig").Scheduler;
    const Constraints = @import("../layout/constraints.zig").Constraints;
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: render_object.Tree = undefined;
    try renders.init(std.testing.allocator, 2);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 2);
    defer instances.deinit();
    try instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 10, .height = 10 } } },
    });
    _ = try renders.layout(
        (try instances.rootRenderObject()).?,
        Constraints.tight(.{ .width = 20, .height = 20 }),
    );
    const window: platform_window.WindowHandle = .{ .slot = 1, .generation = 1 };
    var router: Router = undefined;
    try router.init(std.testing.allocator, &renders, &instances, window, 1);
    defer router.deinit();
    try router.route(.{ .enter = .{
        .window = window,
        .serial = 1,
        .position = .{ .x = 2, .y = 2 },
    } });
    _ = router.takeEvent();
    try std.testing.expectError(error.InputEventCapacityExceeded, router.route(.{ .motion = .{
        .window = window,
        .time_ms = 2,
        .position = .{ .x = 15, .y = 15 },
    } }));
    try std.testing.expectEqual(instances.handleForId(2).?, router.hoveredInstance().?);
    try std.testing.expect(router.takeEvent() == null);

    try instances.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try scheduler.destroyScope(window_scope);
}
