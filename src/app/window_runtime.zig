const std = @import("std");
const frame = @import("frame.zig");
const core = @import("../core/root.zig");
const design = @import("../design/root.zig");
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
    scroll_axis: ?platform.PointerAxis,
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
    text_inputs: ui.text_input.Registry = undefined,
    focus: ui.focus.Manager = .{},
    semantics: ui.semantics.Snapshot = undefined,
    surface_color: core.Color = undefined,
    accent_color: core.Color = undefined,
    content_color: core.Color = undefined,
    focus_color: core.Color = undefined,
    commands: []scene.Command = &.{},
    command_count: usize = 0,
    frame_state: frame.State = .{},
    output_scale: f32 = 1,
    signals: *lua.Signals = undefined,
    paragraph_sources: *text.ParagraphSourceCache = undefined,
    paragraphs: *text.ParagraphCache = undefined,
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
        focus_color: core.Color,
        signals: *lua.Signals,
        paragraph_sources: *text.ParagraphSourceCache,
        paragraphs: *text.ParagraphCache,
        config: Config,
    ) !void {
        if (config.node_capacity < 2 or config.command_capacity == 0)
            return error.InvalidWindowRuntimeCapacity;
        try self.tree.init(allocator, config.node_capacity);
        errdefer self.tree.deinit();
        self.tree.attachTextCaches(paragraph_sources, paragraphs);
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
        try self.text_inputs.init(allocator, config.node_capacity);
        errdefer self.text_inputs.deinit();
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
            .text_inputs = self.text_inputs,
            .focus = .{},
            .semantics = self.semantics,
            .surface_color = surface,
            .accent_color = accent,
            .content_color = content,
            .focus_color = focus_color,
            .commands = commands,
            .signals = signals,
            .paragraph_sources = paragraph_sources,
            .paragraphs = paragraphs,
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
        self.text_inputs.deinit();
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
        self.text_inputs.clear();
        self.focus.clear();
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

    /// Builds and validates one candidate generation into owned storage
    /// without changing retained instances, semantics, bindings, or frames.
    pub fn prepareSourceBuild(
        self: *WindowRuntime,
        size: core.SizeU,
        lua_ui: *lua.UiBuild,
        prepared: *lua.PreparedBuild,
        content_reference: c_int,
        revision: u64,
    ) !void {
        if (!self.initialized or size.width == 0 or size.height == 0)
            return error.WindowRuntimeNotReadyForSourcePreparation;
        prepared.reset();
        const work: ui.instance.BuildWork = .{
            .owner = self.root_owner,
            .revision = revision,
        };
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        const arguments = [_]lua.UiBuildArgument{
            .{ .number = width },
            .{ .number = height },
            .{ .integer = encodedColor(self.surface_color) },
            .{ .integer = encodedColor(self.accent_color) },
            .{ .integer = encodedColor(self.content_color) },
        };
        const descriptors = try lua_ui.buildCallback(
            &self.build_owners,
            work,
            .{ .reference = content_reference },
            &arguments,
        );
        var dependencies_pending = true;
        errdefer if (dependencies_pending) {
            lua_ui.rollbackHandlers();
            lua_ui.rollbackDependencies(&self.build_owners, work) catch unreachable;
        };
        try self.semantics.validate(lua_ui.semanticDescriptors());
        try lua_ui.validateDependencies(&self.build_owners, work);
        try lua_ui.capturePrepared(prepared, descriptors);
        var captured = true;
        errdefer if (captured) prepared.reset();
        if (prepared.handler_count > self.pointer_bindings.availableAfterReconcile(
            &self.instances,
            self.root_owner,
        )) return error.PointerBindingCapacityExceeded;
        if (prepared.button_count > self.buttons.availableForOwner(self.root_owner))
            return error.ButtonCapacityExceeded;
        for (prepared.handlers[0..prepared.handler_count]) |handler|
            if (!containsDescriptorId(prepared.descriptors(), handler.id))
                return error.PointerHandlerInstanceMissing;
        for (prepared.prepared_buttons[0..prepared.button_count]) |button| {
            if (descriptorForId(prepared.descriptors(), button.id)) |descriptor| {
                if (descriptor.object != .box) return error.ButtonRenderObjectMismatch;
            } else {
                return error.ButtonInstanceMissing;
            }
        }
        const plan = try self.instances.prepareReconcile(prepared.descriptors());
        try self.validatePreparedFrame(prepared.descriptors(), size);
        try lua_ui.commitDependencies(&self.build_owners, work);
        dependencies_pending = false;
        prepared.reconcile_plan = plan;
        prepared.size = size;
        captured = false;
    }

    pub fn validatePreparedSourceCommit(
        self: *WindowRuntime,
        prepared: *const lua.PreparedBuild,
    ) !void {
        if (!self.initialized or prepared.reconcile_plan == null or prepared.size == null)
            return error.SourceBuildNotPrepared;
        try self.instances.validateReconcilePlan(prepared.reconcile_plan.?);
    }

    /// Applies only prevalidated, candidate-owned state. Callback capacity
    /// must be reserved across the complete application before the first
    /// window enters this method.
    pub fn commitPreparedSource(
        self: *WindowRuntime,
        prepared: *lua.PreparedBuild,
        callbacks: *lua.CallbackRegistry,
        vm: *lua.Vm,
        signals: *lua.Signals,
    ) void {
        self.validatePreparedSourceCommit(prepared) catch unreachable;
        self.semantics.stage(prepared.semanticDescriptors());
        self.instances.applyReconcile(prepared.reconcile_plan.?) catch unreachable;

        while (self.pointer_bindings.takeInactive(&self.instances)) |old|
            callbacks.release(old.id) catch unreachable;
        while (self.pointer_bindings.takeOwner(self.root_owner)) |old|
            callbacks.release(old.id) catch unreachable;
        for (prepared.handlers[0..prepared.handler_count]) |*handler| {
            const callback = callbacks.adoptReference(
                vm,
                handler.takeReference(),
            ) catch unreachable;
            const target = self.instances.handleForId(handler.id).?;
            const old = self.pointer_bindings.set(
                self.root_owner,
                target,
                .{ .id = callback, .kind = handler.kind },
            ) catch unreachable;
            std.debug.assert(old == null);
        }

        self.buttons.removeInactive(&self.instances);
        self.buttons.beginOwner(self.root_owner);
        for (prepared.prepared_buttons[0..prepared.button_count]) |button| self.buttons.set(
            self.root_owner,
            self.instances.handleForId(button.id).?,
            button.style,
            button.enabled,
        );
        self.buttons.finishOwner(self.root_owner);
        for (0..self.buttons.slotCount()) |index|
            if (self.buttons.visualAt(index)) |visual| self.applyButtonUpdate(visual) catch unreachable;

        self.signals.disposeOwner(.{
            .owners = &self.build_owners,
            .handle = self.root_owner,
        }) catch unreachable;
        self.signals = signals;
        self.semantics.commitStaged();
        while (self.router.takeEvent() != null) {}
        _ = self.frame_state.configure(prepared.size.?) catch unreachable;
        self.frame_state.invalidatePaint();
        self.ready = true;
        prepared.reset();
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
            self.text_inputs.removeInactive(&self.instances);
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
            self.focus.reconcile(&self.instances);
            try self.applyFocusVisual(null, self.focus.current());
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
            try self.instances.syncScrollOffsets();
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

    pub fn routeKeyboard(self: *WindowRuntime, event: platform.KeyboardEvent) !void {
        try self.router.routeKeyboard(event);
    }

    /// Dispatches through either the process-wide callback registry used by
    /// reloadable applications or a directly owned VM used by storybooks.
    pub fn dispatchInput(self: *WindowRuntime, callback_service: anytype) !void {
        while (self.router.takeEvent()) |event| {
            if (event == .keyboard) {
                try self.dispatchKeyboard(event.keyboard, callback_service);
                continue;
            }
            const target = switch (event) {
                .hover_enter => |value| value.target,
                .hover_leave => |value| value.target,
                .pointer => |value| value.target,
                .keyboard => unreachable,
            };
            if (!self.instances.isActive(target)) continue;
            const activated_button = try self.updateButtonState(event);
            if (try self.applyScrollEvent(target, event)) continue;
            var bound_target = target;
            var handler = self.pointer_bindings.get(bound_target);
            while (handler == null) {
                bound_target = (try self.instances.parentOf(bound_target)) orelse break;
                handler = self.pointer_bindings.get(bound_target);
            }
            const binding = handler orelse continue;
            if (binding.kind == .button) {
                if (activated_button != null and sameHandle(activated_button.?, bound_target))
                    try self.spawnCallback(
                        callback_service,
                        binding.id,
                        try self.instances.scope(bound_target),
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
            try self.spawnCallback(
                callback_service,
                binding.id,
                try self.instances.scope(bound_target),
                &arguments,
            );
        }
    }

    fn dispatchKeyboard(self: *WindowRuntime, event: platform.KeyboardEvent, callback_service: anytype) !void {
        const key = switch (event) {
            .enter => return,
            .leave => {
                try self.applyButtonUpdate(self.buttons.release(null).visual);
                return;
            },
            .key => |value| value,
        };
        if (key.translated.logical == .tab and key.state != .released) {
            try self.applyButtonUpdate(self.buttons.release(null).visual);
            const previous = self.focus.current();
            _ = try self.focus.advance(
                &self.instances,
                if (key.translated.modifiers.shift) .backward else .forward,
            );
            try self.applyFocusVisual(previous, self.focus.current());
            return;
        }
        if (key.translated.logical == .space) switch (key.state) {
            .pressed => {
                const focused = self.focus.current() orelse return;
                if (!self.buttons.contains(focused)) return;
                try self.applyButtonUpdate(self.buttons.press(focused));
            },
            .released => try self.activateButton(callback_service, self.buttons.releaseKeyboard()),
            .repeated => {},
        } else if (key.translated.logical == .enter and key.state == .pressed) {
            const focused = self.focus.current() orelse return;
            if (!self.buttons.contains(focused) or !self.buttons.isEnabled(focused)) return;
            try self.spawnButtonCallback(callback_service, focused);
        }
    }

    fn activateButton(self: *WindowRuntime, callback_service: anytype, release: ui.widget.ButtonRelease) !void {
        try self.applyButtonUpdate(release.visual);
        const activated = release.activated orelse return;
        try self.spawnButtonCallback(callback_service, activated);
    }

    fn spawnButtonCallback(
        self: *WindowRuntime,
        callback_service: anytype,
        focused: ui.instance.InstanceHandle,
    ) !void {
        const binding = self.pointer_bindings.get(focused) orelse return;
        if (binding.kind != .button) return;
        try self.spawnCallback(
            callback_service,
            binding.id,
            try self.instances.scope(focused),
            &.{},
        );
    }

    fn spawnCallback(
        self: *WindowRuntime,
        callback_service: anytype,
        callback: lua.CallbackHandle,
        scope: task.ScopeHandle,
        arguments: []const lua.TaskArgument,
    ) !void {
        _ = self;
        const Service = @typeInfo(@TypeOf(callback_service)).pointer.child;
        if (Service == lua.CallbackRegistry) {
            _ = try callback_service.spawn(callback, scope, arguments);
        } else {
            return error.CallbackServiceUnavailable;
        }
    }

    pub fn wantsSubmission(self: *const WindowRuntime) bool {
        return self.initialized and self.frame_state.readyForSubmission();
    }

    fn applyScrollEvent(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        event: ui.input.Event,
    ) !bool {
        const axis_event = switch (event) {
            .pointer => |pointer| switch (pointer.event) {
                .axis => |axis| axis,
                else => return false,
            },
            else => return false,
        };
        const axis: ui.render_object.types.Axis = switch (axis_event.axis) {
            .vertical => .vertical,
            .horizontal => .horizontal,
        };
        var current: ?ui.instance.InstanceHandle = target;
        while (current) |start| {
            const scroll = (try self.instances.nearestScroll(start, axis)) orelse return false;
            if (try self.instances.scrollBy(scroll, axis_event.delta)) return true;
            current = try self.instances.parentOf(scroll);
        }
        return false;
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
        const scroll_axis: ?platform.PointerAxis = switch (try self.tree.objectAt(render)) {
            .scroll => |scroll| switch (scroll.axis) {
                .vertical => .vertical,
                .horizontal => .horizontal,
            },
            else => null,
        };
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
            .scroll_axis = scroll_axis,
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
                            const previous = self.focus.current();
                            _ = try self.focus.request(&self.instances, button);
                            try self.applyFocusVisual(previous, self.focus.current());
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
            .keyboard => {},
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

    /// Exercises candidate layout and scene lowering against isolated native
    /// storage. This closes the transaction boundary before retained instances
    /// change, including command-capacity and descriptor-dependent layout
    /// failures that ordinary reconciliation only encounters during framing.
    fn validatePreparedFrame(
        self: *WindowRuntime,
        descriptors: []const ui.instance.Descriptor,
        size: core.SizeU,
    ) !void {
        if (descriptors.len == 0) return;
        var tree: ui.render_object.Tree = undefined;
        try tree.init(self.allocator, descriptors.len);
        defer tree.deinit();
        tree.attachTextCaches(self.paragraph_sources, self.paragraphs);
        const handles = try self.allocator.alloc(ui.render_object.NodeHandle, descriptors.len);
        defer self.allocator.free(handles);
        for (descriptors, 0..) |descriptor, index| {
            handles[index] = try tree.create(descriptor.object);
            if (descriptor.parent) |parent_id| {
                const parent_index = descriptorIndexForId(descriptors[0..index], parent_id).?;
                try tree.appendChild(handles[parent_index], handles[index], descriptor.parent_data);
            }
        }
        const root_index = descriptorRootIndex(descriptors).?;
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        _ = try tree.layout(
            handles[root_index],
            ui.layout.Constraints.tight(.{ .width = width, .height = height }),
        );
        const commands = try self.allocator.alloc(scene.Command, self.commands.len);
        defer self.allocator.free(commands);
        var builder = try ui.render_object.Builder.init(commands, self.output_scale);
        try tree.buildScene(handles[root_index], &builder);
    }

    fn applyFocusVisual(
        self: *WindowRuntime,
        previous: ?ui.instance.InstanceHandle,
        current: ?ui.instance.InstanceHandle,
    ) !void {
        if (previous) |target| if (self.instances.isActive(target))
            try self.setFocusOutline(target, false);
        if (current) |target| try self.setFocusOutline(target, true);
    }

    fn setFocusOutline(self: *WindowRuntime, target: ui.instance.InstanceHandle, visible: bool) !void {
        const render = try self.instances.renderObject(target);
        var object = try self.tree.objectAt(render);
        if (object != .box) return;
        object.box.outline_color = if (visible) self.focus_color else null;
        object.box.outline_width = if (visible) design.tokens.foundation.focus_ring_width else 0;
        object.box.outline_gap = if (visible) design.tokens.foundation.focus_ring_gap else 0;
        try self.tree.update(render, object);
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

test "queued pointer axis scrolls retained instance only during input dispatch" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    const window: platform.WindowHandle = .{ .slot = 2, .generation = 1 };
    var runtime: WindowRuntime = .{};
    try runtime.tree.init(std.testing.allocator, 2);
    try runtime.instances.init(
        std.testing.allocator,
        &scheduler,
        &runtime.tree,
        window_scope,
        2,
    );
    try runtime.router.init(
        std.testing.allocator,
        &runtime.tree,
        &runtime.instances,
        window,
        2,
    );
    defer {
        runtime.router.deinit();
        runtime.instances.reconcile(&.{}) catch unreachable;
        scheduler.applyQueuedCancellations() catch unreachable;
        runtime.instances.collectRetired() catch unreachable;
        runtime.instances.deinit();
        runtime.tree.deinit();
        scheduler.destroyScope(window_scope) catch unreachable;
    }
    try runtime.instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .scroll = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{ .width = 40, .height = 120 } } },
    });
    const root = (try runtime.instances.rootRenderObject()).?;
    _ = try runtime.tree.layout(
        root,
        ui.layout.Constraints.tight(.{ .width = 40, .height = 50 }),
    );
    try runtime.routePointer(.{ .enter = .{
        .window = window,
        .serial = 1,
        .position = .{ .x = 10, .y = 10 },
    } });
    _ = runtime.router.takeEvent();
    try runtime.routePointer(.{ .axis = .{
        .window = window,
        .time_ms = 2,
        .axis = .vertical,
        .delta = 18,
    } });
    try std.testing.expectEqual(@as(f32, 0), try runtime.instances.scrollOffset(
        runtime.instances.handleForId(1).?,
    ));
    var unused_vm: lua.Vm = undefined;
    try runtime.dispatchInput(&unused_vm);
    try std.testing.expectEqual(@as(f32, 18), try runtime.instances.scrollOffset(
        runtime.instances.handleForId(1).?,
    ));
    try std.testing.expect(!(try runtime.tree.layoutDirty(root)));
    try std.testing.expect(try runtime.tree.paintDirty(root));
}

test "queued Tab navigation updates retained focus at the input safe point" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    const window: platform.WindowHandle = .{ .slot = 3, .generation = 1 };
    var runtime: WindowRuntime = .{};
    try runtime.tree.init(std.testing.allocator, 3);
    try runtime.instances.init(
        std.testing.allocator,
        &scheduler,
        &runtime.tree,
        window_scope,
        3,
    );
    try runtime.router.init(
        std.testing.allocator,
        &runtime.tree,
        &runtime.instances,
        window,
        2,
    );
    try runtime.buttons.init(std.testing.allocator, 3);
    runtime.focus_color = core.Color.rgba(20, 80, 220, 255);
    defer {
        runtime.buttons.clear();
        runtime.buttons.deinit();
        runtime.router.deinit();
        runtime.instances.reconcile(&.{}) catch unreachable;
        scheduler.applyQueuedCancellations() catch unreachable;
        runtime.instances.collectRetired() catch unreachable;
        runtime.instances.deinit();
        runtime.tree.deinit();
        scheduler.destroyScope(window_scope) catch unreachable;
    }
    try runtime.instances.reconcile(&.{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
        .{ .id = 3, .parent = 1, .object = .{ .box = .{} }, .focusable = true },
    });
    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 1,
        .time_ms = 2,
        .state = .pressed,
        .translated = .{ .keycode = 15, .logical = .tab },
    } });
    try std.testing.expect(runtime.focus.current() == null);
    var unused_vm: lua.Vm = undefined;
    try runtime.dispatchInput(&unused_vm);
    try std.testing.expectEqual(runtime.instances.handleForId(2).?, runtime.focus.current().?);
    const focused_render = try runtime.instances.renderObject(runtime.focus.current().?);
    try std.testing.expectEqual(runtime.focus_color, (try runtime.tree.objectAt(focused_render)).box.outline_color.?);

    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 2,
        .time_ms = 3,
        .state = .pressed,
        .translated = .{
            .keycode = 15,
            .logical = .tab,
            .modifiers = .{ .shift = true },
        },
    } });
    try runtime.dispatchInput(&unused_vm);
    try std.testing.expectEqual(runtime.instances.handleForId(3).?, runtime.focus.current().?);
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
        .keyboard => .{ .kind = 7 },
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

fn containsDescriptorId(descriptors: []const ui.instance.Descriptor, id: u64) bool {
    for (descriptors) |descriptor| if (descriptor.id == id) return true;
    return false;
}

fn descriptorForId(
    descriptors: []const ui.instance.Descriptor,
    id: u64,
) ?ui.instance.Descriptor {
    for (descriptors) |descriptor| if (descriptor.id == id) return descriptor;
    return null;
}

fn descriptorIndexForId(descriptors: []const ui.instance.Descriptor, id: u64) ?usize {
    for (descriptors, 0..) |descriptor, index| if (descriptor.id == id) return index;
    return null;
}

fn descriptorRootIndex(descriptors: []const ui.instance.Descriptor) ?usize {
    for (descriptors, 0..) |descriptor, index| if (descriptor.parent == null) return index;
    return null;
}

test "candidate source build prepares owned output without changing retained UI" {
    const bundle = @import("../bundle/root.zig");
    const io_loop = @import("../loop/root.zig");
    const SourceGeneration = @import("source_generation.zig").SourceGeneration;

    var loop: io_loop.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 2, 2);
    defer scheduler.deinit();
    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(std.testing.allocator, 4);
    defer callbacks.deinit();
    var active_vm: lua.Vm = undefined;
    try active_vm.init(std.testing.allocator, &scheduler, &loop);
    var active_signals: lua.Signals = undefined;
    try active_signals.initWithApi(
        std.testing.allocator,
        active_vm.state,
        2,
        2,
        2,
        active_vm.apiReference(),
    );
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    var paragraph_sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer paragraph_sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
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
        &active_signals,
        &paragraph_sources,
        &paragraphs,
        .{ .node_capacity = 4, .command_capacity = 4 },
    );

    var provider = try bundle.SourceProvider.initEmbedded(std.testing.allocator, "candidate.lua",
        \\local ouro = require("ouro")
        \\return ouro.app {
        \\  id = "dev.ouro.prepared-test",
        \\  windows = {
        \\    ouro.window {
        \\      id = "main",
        \\      title = "Candidate",
        \\      content = function() end,
        \\    },
        \\  },
        \\}
    );
    defer provider.deinit();
    const snapshot = try provider.snapshot(std.testing.io, std.testing.allocator);
    const candidate = try SourceGeneration.create(
        std.testing.allocator,
        &scheduler,
        &loop,
        snapshot,
        null,
        .{ .node_capacity = 4, .semantic_text_capacity = 64 },
        null,
    );
    try runtime.prepareSourceBuild(
        .{ .width = 320, .height = 200 },
        &candidate.ui_build,
        &candidate.prepared_builds[0],
        candidate.application.windows[0].content_reference,
        2,
    );
    try std.testing.expect(candidate.prepared_builds[0].reconcile_plan != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.instances.activeCount());
    try runtime.validatePreparedSourceCommit(&candidate.prepared_builds[0]);
    runtime.commitPreparedSource(
        &candidate.prepared_builds[0],
        &callbacks,
        &candidate.vm,
        &candidate.signals,
    );
    try std.testing.expect(candidate.prepared_builds[0].reconcile_plan == null);
    try std.testing.expect(runtime.signals == &candidate.signals);

    try runtime.clear(&candidate.ui_build);
    try scheduler.applyQueuedCancellations();
    try runtime.collectRetired();
    runtime.deinit();
    try scheduler.destroyScope(window_scope);
    candidate.destroy();
    active_vm.deinit();
    active_signals.deinit();
}
