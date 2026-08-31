const std = @import("std");
const frame = @import("frame.zig");
const core = @import("../core/root.zig");
const lua = @import("../lua/root.zig");
const platform = @import("../platform/window.zig");
const scene = @import("../scene/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");

pub const Config = struct {
    node_capacity: usize = 256,
    build_pass_capacity: usize = 16,
    input_capacity: usize = 128,
    command_capacity: usize = 512,
    semantic_text_capacity: usize = 16 * 1024,
};

pub const SemanticTarget = struct {
    center: core.PointF,
    role: ui.semantics.Role,
    enabled: bool,
};

/// Retained UI state for one application window. This coordinates sibling UI,
/// task, Lua, text, and scene implementations without owning platform objects
/// or a renderer backend.
pub const WindowRuntime = struct {
    allocator: std.mem.Allocator = undefined,
    initialized: bool = false,
    registered: bool = false,
    ready: bool = false,
    window: platform.WindowHandle = .invalid,
    tree: ui.render_object.Tree = undefined,
    instances: ui.instance.Tree = undefined,
    build_owners: ui.instance.BuildOwners = undefined,
    root_owner: ui.instance.BuildOwnerHandle = .invalid,
    router: ui.input.Router = undefined,
    pointer_bindings: ui.input.PointerBindings = undefined,
    buttons: ui.widget.Buttons = undefined,
    semantics: ui.semantics.Snapshot = undefined,
    surface_color: core.Color = undefined,
    accent_color: core.Color = undefined,
    content_color: core.Color = undefined,
    commands: []scene.Command = &.{},
    command_count: usize = 0,
    frame_state: frame.State = .{},
    output_scale: f32 = 1,
    signals: *lua.Signals = undefined,
    dirty_windows: ?*ui.instance.ReconcileQueue = null,
    reconciling: bool = false,

    pub fn init(
        self: *WindowRuntime,
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        window_scope: task.ScopeHandle,
        window: platform.WindowHandle,
        surface: core.Color,
        accent: core.Color,
        content: core.Color,
        signals: *lua.Signals,
        shapes: *text.ShapeCache,
        config: Config,
    ) !void {
        if (config.node_capacity < 2 or config.command_capacity == 0)
            return error.InvalidWindowRuntimeCapacity;
        try self.tree.init(allocator, config.node_capacity);
        errdefer self.tree.deinit();
        self.tree.attachTextCache(shapes);
        try self.instances.init(allocator, scheduler, &self.tree, window_scope, config.node_capacity);
        errdefer self.instances.deinit();
        try self.build_owners.init(allocator, scheduler, window_scope, 1, config.build_pass_capacity);
        errdefer self.build_owners.deinit();
        try self.router.init(allocator, &self.tree, &self.instances, window, config.input_capacity);
        errdefer self.router.deinit();
        try self.pointer_bindings.init(allocator, config.node_capacity);
        errdefer self.pointer_bindings.deinit();
        try self.buttons.init(allocator, config.node_capacity);
        errdefer self.buttons.deinit();
        try self.semantics.init(allocator, config.node_capacity, config.semantic_text_capacity);
        errdefer self.semantics.deinit();
        const commands = try allocator.alloc(scene.Command, config.command_capacity);
        errdefer allocator.free(commands);
        self.root_owner = try self.build_owners.mount(null, 1);
        self.* = .{
            .allocator = allocator,
            .initialized = true,
            .window = window,
            .tree = self.tree,
            .instances = self.instances,
            .build_owners = self.build_owners,
            .root_owner = self.root_owner,
            .router = self.router,
            .pointer_bindings = self.pointer_bindings,
            .buttons = self.buttons,
            .semantics = self.semantics,
            .surface_color = surface,
            .accent_color = accent,
            .content_color = content,
            .commands = commands,
            .signals = signals,
        };
    }

    pub fn setDirtyWindowQueue(
        self: *WindowRuntime,
        dirty_windows: *ui.instance.ReconcileQueue,
    ) void {
        self.dirty_windows = dirty_windows;
        self.build_owners.setDirtySink(.{ .context = self, .notify = notifyDirtyWindow });
    }

    pub fn deinit(self: *WindowRuntime) void {
        if (!self.initialized) return;
        std.debug.assert(self.pointer_bindings.takeAny() == null);
        self.allocator.free(self.commands);
        self.semantics.deinit();
        self.buttons.deinit();
        self.pointer_bindings.deinit();
        self.router.deinit();
        self.build_owners.deinit();
        self.instances.deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    pub fn collectRetired(self: *WindowRuntime) !void {
        if (!self.initialized) return;
        try self.build_owners.collectRetired();
        try self.instances.collectRetired();
    }

    pub fn clear(self: *WindowRuntime, lua_ui: *lua.UiBuild) !void {
        if (!self.initialized) return;
        lua_ui.clearHandlers(&self.pointer_bindings);
        self.buttons.clear();
        while (self.router.takeEvent() != null) {}
        if (self.build_owners.isActive(self.root_owner)) {
            try self.signals.disposeOwner(.{
                .owners = &self.build_owners,
                .handle = self.root_owner,
            });
            try self.build_owners.retire(self.root_owner);
        }
        if (self.ready) try self.instances.reconcile(&.{});
        self.ready = false;
        self.command_count = 0;
        self.frame_state = .{};
    }

    pub fn reconcile(
        self: *WindowRuntime,
        size: core.SizeU,
        lua_ui: *lua.UiBuild,
        content_reference: c_int,
    ) !void {
        std.debug.assert(!self.reconciling);
        self.reconciling = true;
        defer self.reconciling = false;
        const size_changed = try self.frame_state.configure(size);
        if (size_changed and self.ready) _ = try self.build_owners.markDirty(self.root_owner);
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        var builds = self.build_owners.beginCycle();
        while (try builds.take()) |work| {
            std.debug.assert(sameHandle(work.owner, self.root_owner));
            const arguments = [_]lua.UiBuildArgument{
                .{ .number = width },
                .{ .number = height },
                .{ .integer = encodedColor(self.surface_color) },
                .{ .integer = encodedColor(self.accent_color) },
                .{ .integer = encodedColor(self.content_color) },
            };
            const descriptors = lua_ui.buildCallback(
                &self.build_owners,
                work,
                .{ .reference = content_reference },
                &arguments,
            ) catch |err| {
                try self.build_owners.retry(work);
                return err;
            };
            self.instances.reconcile(descriptors) catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            self.semantics.validate(lua_ui.semanticDescriptors()) catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            lua_ui.validateDependencies(&self.build_owners, work) catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            self.semantics.stage(lua_ui.semanticDescriptors());
            self.buttons.removeInactive(&self.instances);
            lua_ui.commitBindings(
                &self.pointer_bindings,
                &self.buttons,
                &self.instances,
                work.owner,
            ) catch |err| {
                self.semantics.discardStaged();
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            lua_ui.commitDependencies(&self.build_owners, work) catch |err| {
                self.semantics.discardStaged();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            self.semantics.commitStaged();
            for (0..self.buttons.slotCount()) |index|
                if (self.buttons.visualAt(index)) |visual| try self.applyButtonUpdate(visual);
            try self.build_owners.complete(work);
        }
        try self.prepareFrame(self.output_scale);
        self.ready = true;
    }

    pub fn prepareFrame(self: *WindowRuntime, output_scale: f32) !void {
        if (!self.initialized or self.frame_state.size == null) return;
        if (!std.math.isFinite(output_scale) or output_scale <= 0) return error.InvalidOutputScale;
        if (self.output_scale != output_scale) {
            self.output_scale = output_scale;
            self.frame_state.invalidatePaint();
        }
        const root = (try self.instances.rootRenderObject()) orelse return;
        const size = self.frame_state.size.?;
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        if (self.frame_state.needsLayout() or try self.tree.layoutDirty(root)) {
            self.frame_state.invalidateLayout();
            _ = try self.tree.layout(
                root,
                ui.layout.Constraints.tight(.{ .width = width, .height = height }),
            );
            try self.frame_state.layoutComplete();
        }
        if (try self.tree.paintDirty(root) or self.frame_state.needsScene()) {
            self.frame_state.invalidatePaint();
            var builder = try ui.render_object.Builder.init(self.commands, self.output_scale);
            try self.tree.buildScene(root, &builder);
            self.command_count = builder.displayList().commands.len;
            _ = try self.frame_state.sceneBuilt();
        }
    }

    pub fn routePointer(self: *WindowRuntime, event: platform.PointerEvent) !void {
        try self.router.route(event);
    }

    pub fn dispatchInput(self: *WindowRuntime, vm: *lua.Vm) !void {
        while (self.router.takeEvent()) |event| {
            const target = switch (event) {
                .hover_enter => |value| value.target,
                .hover_leave => |value| value.target,
                .pointer => |value| value.target,
            };
            if (!self.instances.isActive(target)) continue;
            const activated_button = try self.updateButtonState(event);
            var bound_target = target;
            var handler = self.pointer_bindings.get(bound_target);
            while (handler == null) {
                bound_target = (try self.instances.parentOf(bound_target)) orelse break;
                handler = self.pointer_bindings.get(bound_target);
            }
            const binding = handler orelse continue;
            if (binding.kind == .button) {
                if (activated_button != null and sameHandle(activated_button.?, bound_target))
                    _ = try vm.spawnReference(
                        try self.instances.scope(bound_target),
                        @intCast(binding.id),
                        &.{},
                    );
                continue;
            }
            const values = inputValues(event);
            const arguments = [_]lua.TaskArgument{
                .{ .integer = values.kind },
                .{ .integer = @intCast(try self.instances.semanticId(target)) },
                .{ .number = values.x },
                .{ .number = values.y },
                .{ .integer = values.value1 },
                .{ .integer = values.value2 },
            };
            _ = try vm.spawnReference(
                try self.instances.scope(bound_target),
                @intCast(binding.id),
                &arguments,
            );
        }
    }

    pub fn wantsSubmission(self: *const WindowRuntime) bool {
        return self.initialized and self.frame_state.readyForSubmission();
    }

    pub fn displayList(self: *WindowRuntime) !scene.DisplayList {
        if (!self.frame_state.readyForSubmission()) return error.FrameNotReady;
        return .{ .commands = self.commands[0..self.command_count] };
    }

    /// Resolves a retained semantic key path into the logical center used by
    /// deterministic headless input. Geometry is accumulated through the
    /// actual laid-out instance ancestry, so synthetic events use normal hit
    /// testing rather than addressing widget state directly.
    pub fn semanticTarget(self: *WindowRuntime, path: []const u8) !SemanticTarget {
        if (!self.ready) return error.WindowRuntimeNotReady;
        const semantic = try self.semantics.findPath(path);
        const target = self.instances.handleForId(semantic.id) orelse
            return error.SemanticInstanceMissing;
        const render = try self.instances.renderObject(target);
        const size = try self.tree.nodeSize(render);
        var origin: core.PointF = .{};
        var current: ?ui.instance.InstanceHandle = target;
        while (current) |instance_handle| {
            origin = core.PointF.add(
                origin,
                try self.tree.nodeOffset(try self.instances.renderObject(instance_handle)),
            );
            current = try self.instances.parentOf(instance_handle);
        }
        return .{
            .center = .{
                .x = origin.x + size.width / 2,
                .y = origin.y + size.height / 2,
            },
            .role = semantic.role,
            .enabled = semantic.enabled,
        };
    }

    pub fn frameSubmitted(self: *WindowRuntime) !void {
        try self.frame_state.submitted();
    }

    fn notifyDirtyWindow(context: *anyopaque) !void {
        const self: *WindowRuntime = @ptrCast(@alignCast(context));
        if (!self.registered or self.reconciling) return;
        _ = try self.dirty_windows.?.markDirty(self.window);
    }

    fn updateButtonState(self: *WindowRuntime, event: ui.input.Event) !?ui.instance.InstanceHandle {
        switch (event) {
            .hover_enter => |hover| if (try self.buttonAncestor(hover.target)) |button|
                try self.applyButtonColor(button, self.buttons.setHovered(button, true)),
            .hover_leave => |hover| if (try self.buttonAncestor(hover.target)) |button|
                try self.applyButtonColor(button, self.buttons.setHovered(button, false)),
            .pointer => |pointer| switch (pointer.event) {
                .button => |button_event| {
                    if (button_event.button != 0x110) return null;
                    switch (button_event.state) {
                        .pressed => {
                            const button = (try self.buttonAncestor(pointer.target)) orelse return null;
                            try self.applyButtonUpdate(self.buttons.press(button));
                        },
                        .released => {
                            const hovered = if (pointer.hovered) |target|
                                try self.buttonAncestor(target)
                            else
                                null;
                            const release = self.buttons.release(hovered);
                            try self.applyButtonUpdate(release.visual);
                            return release.activated;
                        },
                    }
                },
                else => {},
            },
        }
        return null;
    }

    fn buttonAncestor(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
    ) !?ui.instance.InstanceHandle {
        var current = target;
        while (true) {
            if (self.buttons.contains(current)) return current;
            current = (try self.instances.parentOf(current)) orelse return null;
        }
    }

    fn applyButtonColor(
        self: *WindowRuntime,
        button: ui.instance.InstanceHandle,
        next: ?core.Color,
    ) !void {
        const color = next orelse return;
        const render = try self.instances.renderObject(button);
        var object = try self.tree.objectAt(render);
        if (object != .box) return error.ButtonRenderObjectMismatch;
        if (std.meta.eql(object.box.background, color)) return;
        object.box.background = color;
        try self.tree.update(render, object);
        self.frame_state.invalidatePaint();
    }

    fn applyButtonUpdate(self: *WindowRuntime, update: ?ui.widget.ButtonVisualUpdate) !void {
        const value = update orelse return;
        try self.applyButtonColor(value.target, value.color);
    }
};

test "resize lays out a clean render tree before rebuilding its scene" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);

    var runtime: WindowRuntime = .{};
    try runtime.tree.init(std.testing.allocator, 1);
    try runtime.instances.init(
        std.testing.allocator,
        &scheduler,
        &runtime.tree,
        window_scope,
        1,
    );
    defer {
        runtime.instances.reconcile(&.{}) catch unreachable;
        scheduler.applyQueuedCancellations() catch unreachable;
        runtime.instances.collectRetired() catch unreachable;
        runtime.instances.deinit();
        runtime.tree.deinit();
        scheduler.destroyScope(window_scope) catch unreachable;
    }
    var commands: [1]scene.Command = undefined;
    runtime.initialized = true;
    runtime.commands = &commands;
    try runtime.instances.reconcile(&.{.{
        .id = 1,
        .parent = null,
        .object = .{ .box = .{ .background = core.Color.rgba(1, 2, 3, 255) } },
    }});

    _ = try runtime.frame_state.configure(.{ .width = 100, .height = 80 });
    try runtime.prepareFrame(1);
    try runtime.frameSubmitted();
    const root = (try runtime.instances.rootRenderObject()).?;
    const initial_layout_count = try runtime.tree.layoutCount(root);
    try std.testing.expect(!(try runtime.tree.layoutDirty(root)));

    _ = try runtime.frame_state.configure(.{ .width = 120, .height = 80 });
    try std.testing.expect(!(try runtime.tree.layoutDirty(root)));
    try runtime.prepareFrame(1);

    try std.testing.expectEqual(initial_layout_count + 1, try runtime.tree.layoutCount(root));
    try std.testing.expect(runtime.wantsSubmission());
}

const InputValues = struct {
    kind: i64,
    x: f64 = 0,
    y: f64 = 0,
    value1: i64 = 0,
    value2: i64 = 0,
};

fn inputValues(event: ui.input.Event) InputValues {
    return switch (event) {
        .hover_enter => |value| .{ .kind = 1, .x = value.position.x, .y = value.position.y },
        .hover_leave => .{ .kind = 2 },
        .pointer => |value| switch (value.event) {
            .motion => |motion| .{ .kind = 3, .x = motion.position.x, .y = motion.position.y },
            .button => |button| .{
                .kind = 4,
                .value1 = button.button,
                .value2 = @intFromEnum(button.state),
            },
            .axis => |axis| .{ .kind = 5, .value1 = @intFromEnum(axis.axis), .x = axis.delta },
            else => .{ .kind = 6 },
        },
    };
}

fn encodedColor(color: core.Color) i64 {
    return (@as(i64, color.r) << 24) |
        (@as(i64, color.g) << 16) |
        (@as(i64, color.b) << 8) |
        color.a;
}

fn sameHandle(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
