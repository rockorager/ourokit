const std = @import("std");
const clipboard_module = @import("clipboard.zig");
const frame = @import("frame.zig");
const text_input_coordinator = @import("text_input.zig");
const core = @import("../core/root.zig");
const lua = @import("../lua/root.zig");
const lua_c = @import("../lua/c.zig");
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

pub const TextInputStatus = struct {
    state: platform.TextInputState,
    model_revision: u64,
    session_revision: u64,
    scene_revision: u64,
    commit_permitted: bool,
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
    listboxes: ui.widget.ListBoxes = .{},
    text_inputs: ui.text_input.Registry = undefined,
    focus: ui.focus.Manager = .{},
    semantics: ui.semantics.Snapshot = undefined,
    surface_color: core.Color = undefined,
    accent_color: core.Color = undefined,
    content_color: core.Color = undefined,
    border_color: core.Color = undefined,
    focus_color: core.Color = undefined,
    commands: []scene.Command = &.{},
    command_count: usize = 0,
    frame_state: frame.State = .{},
    output_scale: f32 = 1,
    signals: *lua.Signals = undefined,
    paragraph_sources: *text.ParagraphSourceCache = undefined,
    paragraphs: *text.ParagraphCache = undefined,
    dirty_windows: ?*ui.instance.ReconcileQueue = null,
    clipboard: ?*clipboard_module.Coordinator = null,
    reconciling: bool = false,
    text_input_commit_permitted: bool = true,

    pub fn init(
        self: *WindowRuntime,
        allocator: std.mem.Allocator,
        scheduler: *task.Scheduler,
        window_scope: task.ScopeHandle,
        window: platform.WindowHandle,
        surface: core.Color,
        accent: core.Color,
        content: core.Color,
        border_color: core.Color,
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
        try self.listboxes.init(allocator, config.node_capacity);
        errdefer self.listboxes.deinit();
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
            .listboxes = self.listboxes,
            .text_inputs = self.text_inputs,
            .focus = .{},
            .semantics = self.semantics,
            .surface_color = surface,
            .accent_color = accent,
            .content_color = content,
            .border_color = border_color,
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

    pub fn setClipboardCoordinator(self: *WindowRuntime, clipboard: *clipboard_module.Coordinator) void {
        self.clipboard = clipboard;
    }

    pub fn deinit(self: *WindowRuntime) void {
        if (!self.initialized) return;
        std.debug.assert(self.pointer_bindings.takeAny() == null);
        self.allocator.free(self.commands);
        self.semantics.deinit();
        self.text_inputs.deinit();
        self.listboxes.deinit();
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
        self.listboxes.clear();
        self.text_inputs.clear();
        self.focus.clear();
        while (self.router.takeEvent()) |event| self.router.releaseEvent(event);
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
        if (prepared.text_input_count > self.text_inputs.availableForOwner(self.root_owner))
            return error.TextInputCapacityExceeded;
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
        for (prepared.text_inputs[0..prepared.text_input_count]) |*input| {
            if (!containsDescriptorId(prepared.descriptors(), input.target_id) or
                !containsDescriptorId(prepared.descriptors(), input.content_id))
                return error.TextInputInstanceMissing;
            if (self.instances.handleForId(input.target_id)) |target| {
                try self.text_inputs.prepareMount(target, input.mode, &input.session);
                if (!self.text_inputs.contains(target)) continue;
                const retained = try self.text_inputs.session(target);
                const candidate = &input.session.?.model;
                const descriptor_index = descriptorIndexForId(
                    prepared.descriptors(),
                    input.content_id,
                ).?;
                var object = &prepared.descriptor_storage[descriptor_index].object;
                if (object.* != .text_input) return error.TextInputRenderObjectMismatch;
                if (input.mode == .uncontrolled or
                    std.mem.eql(u8, retained.model.text(), candidate.text()))
                {
                    const retained_content = try self.text_inputs.content(target);
                    const retained_object = try self.tree.objectAt(
                        try self.instances.renderObject(retained_content),
                    );
                    if (retained_object != .text_input)
                        return error.TextInputRenderObjectMismatch;
                    try self.paragraph_sources.validateRetain(retained_object.text_input.source);
                    try self.paragraph_sources.retain(retained_object.text_input.source);
                    self.paragraph_sources.release(object.text_input.source) catch unreachable;
                    object.text_input.source = retained_object.text_input.source;
                    object.text_input.selection_start = retained_object.text_input.selection_start;
                    object.text_input.selection_end = retained_object.text_input.selection_end;
                    object.text_input.caret_offset = retained_object.text_input.caret_offset;
                    object.text_input.caret_affinity = retained_object.text_input.caret_affinity;
                    object.text_input.show_caret = retained_object.text_input.show_caret;
                    object.text_input.preedit = retained_object.text_input.preedit;
                    object.text_input.preedit_color = if (object.text_input.preedit != null)
                        object.text_input.caret_color
                    else
                        null;
                } else {
                    const selection = candidate.selection;
                    const range = selection.range();
                    object.text_input.selection_start = range.start;
                    object.text_input.selection_end = range.end;
                    object.text_input.caret_offset = selection.extent;
                    object.text_input.caret_affinity = selection.extent_affinity;
                    object.text_input.show_caret = optionalSameHandle(self.focus.current(), target);
                }
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
        self.listboxes.removeInactive(&self.instances);
        self.listboxes.beginOwner(self.root_owner);
        for (prepared.prepared_listboxes[0..prepared.listbox_count]) |listbox| self.listboxes.setList(
            self.root_owner,
            self.instances.handleForId(listbox.id).?,
            listbox.selected,
        ) catch unreachable;
        for (prepared.prepared_options[0..prepared.option_count]) |option| self.listboxes.setOption(
            self.root_owner,
            self.instances.handleForId(option.listbox_id).?,
            self.instances.handleForId(option.id).?,
            self.instances.handleForId(option.content_id).?,
            option.value,
            option.style,
        ) catch unreachable;
        self.listboxes.finishOwner(self.root_owner);
        for (0..self.buttons.slotCount()) |index|
            if (self.buttons.visualAt(index)) |visual| self.applyButtonUpdate(visual) catch unreachable;
        self.refreshListBoxVisuals() catch unreachable;

        self.text_inputs.removeInactive(&self.instances);
        self.text_inputs.beginOwner(self.root_owner);
        for (prepared.text_inputs[0..prepared.text_input_count]) |*input| self.text_inputs.mountPrepared(
            self.root_owner,
            self.instances.handleForId(input.target_id).?,
            self.instances.handleForId(input.content_id).?,
            input.mode,
            input.behavior,
            &input.session,
        ) catch unreachable;
        self.text_inputs.finishOwner(self.root_owner);

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
            self.listboxes.removeInactive(&self.instances);
            self.text_inputs.removeInactive(&self.instances);
            lua_ui.commitBindings(
                &self.pointer_bindings,
                &self.buttons,
                &self.text_inputs,
                &self.listboxes,
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
            for (0..self.buttons.slotCount()) |index|
                if (self.buttons.visualAt(index)) |visual| try self.applyButtonUpdate(visual);
            try self.refreshListBoxVisuals();
            try self.applyFocusVisual(null, self.focus.current());
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

    pub fn textInputStatus(self: *WindowRuntime) !?TextInputStatus {
        const focused = self.focus.current() orelse return null;
        if (!self.text_inputs.contains(focused)) return null;
        const behavior = try self.text_inputs.getBehavior(focused);
        if (!behavior.enabled or behavior.read_only) return null;
        const session = try self.text_inputs.session(focused);
        var state = text_input_coordinator.surroundingState(session);
        const content = try self.text_inputs.content(focused);
        const render = try self.instances.renderObject(content);
        const local = try self.tree.textCaretRectangle(render);
        const origin = try self.instanceOrigin(content);
        state.cursor_rectangle = .{
            .x = @intFromFloat(@floor(origin.x + local.x)),
            .y = @intFromFloat(@floor(origin.y + local.y)),
            .width = @intFromFloat(@ceil(local.width)),
            .height = @intFromFloat(@ceil(local.height)),
        };
        return .{
            .state = state,
            .model_revision = session.model.revision,
            .session_revision = session.revision,
            .scene_revision = self.frame_state.scene_revision,
            .commit_permitted = self.text_input_commit_permitted,
        };
    }

    pub fn routePointer(self: *WindowRuntime, event: platform.PointerEvent) !void {
        try self.router.route(event);
    }

    pub fn routeKeyboard(self: *WindowRuntime, event: platform.KeyboardEvent) !void {
        try self.router.routeKeyboard(event);
    }

    pub fn routeTextInput(self: *WindowRuntime, event: platform.TextInputEvent) !void {
        const batch = switch (event) {
            .batch => |value| value,
            .enter, .leave => return,
        };
        if (!sameHandle(batch.window, self.window)) return error.WrongWindow;
        try self.router.routeTextInput(
            try text_input_coordinator.editBatch(batch),
            batch.serial_matches_state,
        );
    }

    /// Dispatches through either the process-wide callback registry used by
    /// reloadable applications or a directly owned VM used by storybooks.
    pub fn dispatchInput(self: *WindowRuntime, callback_service: anytype) !void {
        while (self.router.takeEvent()) |event| {
            defer self.router.releaseEvent(event);
            if (event == .text_input) {
                const focused = self.focus.current() orelse continue;
                if (!self.text_inputs.contains(focused)) continue;
                const behavior = try self.text_inputs.getBehavior(focused);
                if (!behavior.enabled or behavior.read_only) continue;
                self.text_input_commit_permitted = event.text_input.serial_matches_state;
                const session = try self.text_inputs.session(focused);
                const model_revision = session.model.revision;
                if (try session.apply(event.text_input.batch)) try self.syncTextInputVisuals();
                if (session.model.revision != model_revision)
                    try self.notifyTextInputChanged(callback_service, focused);
                continue;
            }
            if (event == .keyboard) {
                try self.dispatchKeyboard(event.keyboard, callback_service);
                continue;
            }
            const target = switch (event) {
                .hover_enter => |value| value.target,
                .hover_leave => |value| value.target,
                .pointer => |value| value.target,
                .keyboard => unreachable,
                .text_input => unreachable,
            };
            if (!self.instances.isActive(target)) continue;
            try self.updateTextInputPointer(target, event);
            const activated_button = try self.updateButtonState(event);
            try self.updateListBoxHover(event);
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
            if (binding.kind == .listbox) {
                const selection = try self.listBoxPointerSelection(target, event) orelse continue;
                const previous = self.focus.current();
                self.listboxes.select(selection);
                try self.refreshListBoxVisuals();
                _ = try self.focus.request(&self.instances, selection.listbox);
                try self.applyFocusVisual(previous, self.focus.current());
                try self.ensureOptionVisible(selection.option);
                try self.spawnListBoxCallback(callback_service, binding.id, selection);
                continue;
            }
            if (binding.kind == .text_input_change) continue;
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
                try self.applyButtonUpdate(self.buttons.release());
                return;
            },
            .key => |value| value,
        };
        if (key.translated.logical == .tab and key.state != .released) {
            try self.applyButtonUpdate(self.buttons.release());
            const previous = self.focus.current();
            _ = try self.focus.advance(
                &self.instances,
                if (key.translated.modifiers.shift) .backward else .forward,
            );
            try self.applyFocusVisual(previous, self.focus.current());
            return;
        }
        if (self.focus.current()) |focused| if (self.text_inputs.contains(focused) and
            key.state != .released)
        {
            const session = try self.text_inputs.session(focused);
            const behavior = try self.text_inputs.getBehavior(focused);
            if (key.state == .pressed) {
                if (textInputClipboardShortcut(key.translated)) |command| {
                    if (!behavior.enabled or (behavior.read_only and command != .copy)) return;
                    if (session.preedit() != null) return;
                    session.endSelectionDrag();
                    const clipboard = self.clipboard orelse return;
                    if (!clipboard.platformAvailable()) return;
                    switch (command) {
                        .copy, .cut => {
                            const selected = session.model.selectedText();
                            if (selected.len == 0) return;
                            try clipboard.setSelection(key.serial, selected);
                            if (command == .cut) {
                                session.preferred_x = null;
                                if (try session.model.replaceSelection("")) {
                                    try self.syncTextInputVisuals();
                                    try self.notifyTextInputChanged(callback_service, focused);
                                }
                            }
                        },
                        .paste => _ = try clipboard.requestPaste(
                            try self.instances.scope(focused),
                            .{ .window = self.window, .text_input = focused },
                        ),
                    }
                    return;
                }
            }
            const intent = textInputIntent(key.translated);
            if (session.preedit() != null and intent != null) return;
            if (intent) |value| if (!behavior.enabled or
                (behavior.read_only and intentEditsText(value))) return;
            const changed = if (intent) |value|
                try self.applyTextInputIntent(focused, value)
            else
                false;
            if (changed) {
                try self.syncTextInputVisuals();
                if (intentEditsText(intent.?))
                    try self.notifyTextInputChanged(callback_service, focused);
            }
            if (intent != null) return;
        };
        if ((key.translated.logical == .arrow_up or key.translated.logical == .arrow_down or
            key.translated.logical == .home or key.translated.logical == .end) and
            key.state != .released)
        {
            const focused = self.focus.current() orelse return;
            if (!self.listboxes.contains(focused)) return;
            const selection = switch (key.translated.logical) {
                .home => self.listboxes.edge(focused, false),
                .end => self.listboxes.edge(focused, true),
                .arrow_up => self.listboxes.move(focused, -1),
                .arrow_down => self.listboxes.move(focused, 1),
                else => unreachable,
            } orelse return;
            const binding = self.pointer_bindings.get(focused) orelse return;
            if (binding.kind != .listbox) return;
            try self.refreshListBoxVisuals();
            try self.applyFocusVisual(null, self.focus.current());
            try self.ensureOptionVisible(selection.option);
            try self.spawnListBoxCallback(callback_service, binding.id, selection);
            return;
        }
        if (key.translated.logical == .space) switch (key.state) {
            .pressed => {
                const focused = self.focus.current() orelse return;
                if (!self.buttons.contains(focused) or !self.buttons.isEnabled(focused)) return;
                try self.applyButtonUpdate(self.buttons.press(focused));
                try self.spawnButtonCallback(callback_service, focused);
            },
            .released => try self.applyButtonUpdate(self.buttons.releaseKeyboard()),
            .repeated => {},
        } else if (key.translated.logical == .enter and key.state == .pressed) {
            const focused = self.focus.current() orelse return;
            if (!self.buttons.contains(focused) or !self.buttons.isEnabled(focused)) return;
            try self.spawnButtonCallback(callback_service, focused);
        }
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

    fn spawnListBoxCallback(
        self: *WindowRuntime,
        callback_service: anytype,
        callback: lua.CallbackHandle,
        selection: ui.widget.ListBoxSelection,
    ) !void {
        const arguments = [_]lua.TaskArgument{.{ .integer = selection.value }};
        try self.spawnCallback(
            callback_service,
            callback,
            try self.instances.scope(selection.listbox),
            &arguments,
        );
    }

    fn listBoxPointerSelection(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        event: ui.input.Event,
    ) !?ui.widget.ListBoxSelection {
        const pointer = switch (event) {
            .pointer => |value| value,
            else => return null,
        };
        const button = switch (pointer.event) {
            .button => |value| value,
            else => return null,
        };
        if (button.button != 0x110 or button.state != .released) return null;
        var current: ?ui.instance.InstanceHandle = target;
        while (current) |candidate| {
            if (self.listboxes.option(candidate)) |selection| return selection;
            current = try self.instances.parentOf(candidate);
        }
        return null;
    }

    fn ensureOptionVisible(self: *WindowRuntime, option: ui.instance.InstanceHandle) !void {
        const scroll = (try self.instances.nearestScroll(option, .vertical)) orelse return;
        const scroll_render = try self.instances.renderObject(scroll);
        const viewport = try self.tree.nodeSize(scroll_render);
        const option_size = try self.tree.nodeSize(try self.instances.renderObject(option));
        var y: f32 = 0;
        var current: ?ui.instance.InstanceHandle = option;
        while (current) |candidate| {
            if (sameHandle(candidate, scroll)) break;
            y += (try self.tree.nodeOffset(try self.instances.renderObject(candidate))).y;
            current = try self.instances.parentOf(candidate);
        }
        const delta = if (y < 0) y else if (y + option_size.height > viewport.height)
            y + option_size.height - viewport.height
        else
            0;
        if (delta != 0 and try self.instances.scrollBy(scroll, delta))
            self.frame_state.invalidatePaint();
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

    fn notifyTextInputChanged(
        self: *WindowRuntime,
        callback_service: anytype,
        target: ui.instance.InstanceHandle,
    ) !void {
        const binding = self.pointer_bindings.get(target) orelse return;
        if (binding.kind != .text_input_change) return;
        const value = (try self.text_inputs.session(target)).model.text();
        try self.spawnCallback(
            callback_service,
            binding.id,
            try self.instances.scope(target),
            &.{.{ .string = value }},
        );
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
                            if (!self.buttons.isEnabled(button)) return null;
                            const previous = self.focus.current();
                            _ = try self.focus.request(&self.instances, button);
                            try self.applyFocusVisual(previous, self.focus.current());
                            try self.applyButtonUpdate(self.buttons.press(button));
                            return button;
                        },
                        .released => {
                            try self.applyButtonUpdate(self.buttons.release());
                        },
                    }
                },
                else => {},
            },
            .keyboard => {},
            .text_input => unreachable,
        }
        return null;
    }

    fn updateListBoxHover(self: *WindowRuntime, event: ui.input.Event) !void {
        switch (event) {
            .hover_enter => |hover| if (try self.listBoxOptionAncestor(hover.target)) |option|
                try self.applyListBoxVisualUpdate(self.listboxes.setHovered(option, true)),
            .hover_leave => |hover| if (try self.listBoxOptionAncestor(hover.target)) |option|
                try self.applyListBoxVisualUpdate(self.listboxes.setHovered(option, false)),
            else => {},
        }
    }

    fn listBoxOptionAncestor(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
    ) !?ui.instance.InstanceHandle {
        var current: ?ui.instance.InstanceHandle = target;
        while (current) |candidate| {
            if (self.listboxes.option(candidate) != null) return candidate;
            current = try self.instances.parentOf(candidate);
        }
        return null;
    }

    fn updateTextInputPointer(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        event: ui.input.Event,
    ) !void {
        const pointer = switch (event) {
            .pointer => |value| value,
            else => return,
        };
        switch (pointer.event) {
            .button => |button| {
                if (button.button != 0x110) return;
                const input = (try self.textInputAncestor(target)) orelse return;
                if (!(try self.text_inputs.getBehavior(input)).enabled) return;
                const session = try self.text_inputs.session(input);
                switch (button.state) {
                    .pressed => {
                        const previous = self.focus.current();
                        _ = try self.focus.request(&self.instances, input);
                        try self.applyFocusVisual(previous, self.focus.current());
                        const caret = try self.textCaretAtPointer(input, pointer.position);
                        if (try session.beginSelectionDrag(caret.byte_offset, caret.affinity))
                            try self.syncTextInputVisuals();
                    },
                    .released => session.endSelectionDrag(),
                }
            },
            .motion => {
                const input = (try self.textInputAncestor(target)) orelse return;
                const session = try self.text_inputs.session(input);
                if (!session.isSelecting()) return;
                const caret = try self.textCaretAtPointer(input, pointer.position);
                if (try session.updateSelectionDrag(caret.byte_offset, caret.affinity))
                    try self.syncTextInputVisuals();
            },
            else => {},
        }
    }

    fn textCaretAtPointer(
        self: *WindowRuntime,
        input: ui.instance.InstanceHandle,
        position: core.PointF,
    ) !text.CaretStop {
        const content = try self.text_inputs.content(input);
        const render = try self.instances.renderObject(content);
        const origin = try self.instanceOrigin(content);
        return (try self.tree.hitTestText(render, .{
            .x = position.x - origin.x,
            .y = position.y - origin.y,
        })).caret;
    }

    fn applyTextInputIntent(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        intent: ui.text_input.EditIntent,
    ) !bool {
        const session = try self.text_inputs.session(target);
        session.endSelectionDrag();
        return switch (intent) {
            .select_all => blk: {
                session.preferred_x = null;
                break :blk session.model.selectAll();
            },
            .delete_backward => blk: {
                session.preferred_x = null;
                break :blk try session.model.deleteBackward();
            },
            .delete_forward => blk: {
                session.preferred_x = null;
                break :blk try session.model.deleteForward();
            },
            .delete_word_backward => blk: {
                session.preferred_x = null;
                break :blk try session.model.deleteWordBackward();
            },
            .delete_word_forward => blk: {
                session.preferred_x = null;
                break :blk try session.model.deleteWordForward();
            },
            .move => |move| switch (move.destination) {
                .word_previous => blk: {
                    session.preferred_x = null;
                    break :blk session.model.moveWordPrevious(move.extend);
                },
                .word_next => blk: {
                    session.preferred_x = null;
                    break :blk session.model.moveWordNext(move.extend);
                },
                else => try self.moveTextInputCaret(target, session, move),
            },
        };
    }

    /// Input safe point only. The app clipboard coordinator has already
    /// validated request generation and UTF-8 ownership; retained instance
    /// generation is revalidated here before the edit is applied.
    pub fn applyClipboardPaste(
        self: *WindowRuntime,
        callback_service: anytype,
        target: ui.instance.InstanceHandle,
        bytes: []const u8,
    ) !bool {
        if (!self.instances.isActive(target) or !self.text_inputs.contains(target)) return false;
        const behavior = try self.text_inputs.getBehavior(target);
        if (!behavior.enabled or behavior.read_only) return false;
        const session = try self.text_inputs.session(target);
        session.endSelectionDrag();
        const changed = try session.apply(.{ .commit = .{ .text = bytes } });
        if (changed) {
            try self.syncTextInputVisuals();
            try self.notifyTextInputChanged(callback_service, target);
        }
        return changed;
    }

    fn moveTextInputCaret(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        session: *ui.text_input.Session,
        move: ui.text_input.MoveIntent,
    ) !bool {
        const current = session.model.selection;
        const content = try self.text_inputs.content(target);
        const render = try self.instances.renderObject(content);
        const horizontal: ?text.VisualCaretDirection = switch (move.destination) {
            .visual_left => .left,
            .visual_right => .right,
            .word_previous, .word_next => unreachable,
            else => null,
        };
        if (horizontal) |direction| if (!move.extend and !current.isCollapsed()) {
            session.preferred_x = null;
            const order = try self.tree.textVisualOrder(
                render,
                current.anchor,
                current.anchor_affinity,
                current.extent,
                current.extent_affinity,
            );
            const use_anchor = switch (direction) {
                .left => order != .gt,
                .right => order == .gt,
            };
            return session.model.setSelection(if (use_anchor)
                .collapsedAt(current.anchor, current.anchor_affinity)
            else
                .collapsedAt(current.extent, current.extent_affinity));
        };

        const next = switch (move.destination) {
            .word_previous, .word_next => unreachable,
            .visual_left, .visual_right => blk: {
                session.preferred_x = null;
                break :blk try self.tree.textVisualNeighbor(
                    render,
                    current.extent,
                    current.extent_affinity,
                    horizontal.?,
                );
            },
            .line_start, .line_end => blk: {
                session.preferred_x = null;
                break :blk try self.tree.textLineBoundary(
                    render,
                    current.extent,
                    current.extent_affinity,
                    if (move.destination == .line_start) .start else .end,
                );
            },
            .line_up, .line_down => blk: {
                const result = try self.tree.textVerticalNeighbor(
                    render,
                    current.extent,
                    current.extent_affinity,
                    session.preferred_x,
                    if (move.destination == .line_up) .up else .down,
                );
                session.preferred_x = result.preferred_x;
                break :blk result.caret;
            },
        };
        return session.model.setSelection(if (move.extend) .{
            .anchor = current.anchor,
            .extent = next.byte_offset,
            .anchor_affinity = current.anchor_affinity,
            .extent_affinity = next.affinity,
        } else .collapsedAt(next.byte_offset, next.affinity));
    }

    fn textInputAncestor(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
    ) !?ui.instance.InstanceHandle {
        var current = target;
        while (true) {
            if (self.text_inputs.contains(current)) return current;
            current = (try self.instances.parentOf(current)) orelse return null;
        }
    }

    fn instanceOrigin(self: *WindowRuntime, target: ui.instance.InstanceHandle) !core.PointF {
        var origin: core.PointF = .{};
        var current: ?ui.instance.InstanceHandle = target;
        while (current) |handle| {
            origin = core.PointF.add(
                origin,
                try self.tree.nodeOffset(try self.instances.renderObject(handle)),
            );
            current = try self.instances.parentOf(handle);
        }
        return origin;
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

    fn refreshListBoxVisuals(self: *WindowRuntime) !void {
        for (0..self.listboxes.optionSlots()) |index| {
            const option = self.listboxes.optionAt(index) orelse continue;
            try self.applyListBoxVisual(self.listboxes.currentVisual(option));
        }
        self.frame_state.invalidatePaint();
    }

    fn applyListBoxVisualUpdate(
        self: *WindowRuntime,
        update: ?ui.widget.ListBoxVisualUpdate,
    ) !void {
        const next = update orelse return;
        try self.applyListBoxVisual(next);
        self.frame_state.invalidatePaint();
    }

    fn applyListBoxVisual(self: *WindowRuntime, update: ui.widget.ListBoxVisualUpdate) !void {
        const option_render = try self.instances.renderObject(update.option);
        var option = try self.tree.objectAt(option_render);
        if (option != .box) return error.ListBoxOptionRenderObjectMismatch;
        option.box.background = update.visual.background;
        option.box.outline_color = null;
        option.box.outline_width = 0;
        option.box.outline_gap = 0;
        try self.tree.update(option_render, option);

        const content_render = try self.instances.renderObject(update.content);
        var content = try self.tree.objectAt(content_render);
        if (content != .label) return error.ListBoxOptionContentRenderObjectMismatch;
        content.label.color = update.visual.foreground;
        try self.tree.update(content_render, content);
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
        if (!self.initialized) return;
        if (previous) |target| if (self.instances.isActive(target) and self.text_inputs.contains(target))
            try self.setTextInputBorder(target, self.border_color);
        if (current) |target| if (self.text_inputs.contains(target))
            try self.setTextInputBorder(target, self.focus_color);
        try self.syncTextInputVisuals();
    }

    fn setTextInputBorder(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        color: core.Color,
    ) !void {
        const render = try self.instances.renderObject(target);
        var object = try self.tree.objectAt(render);
        if (object != .box) return error.TextInputRenderObjectMismatch;
        if (std.meta.eql(object.box.border_color, color)) return;
        object.box.border_color = color;
        try self.tree.update(render, object);
        self.frame_state.invalidatePaint();
    }

    fn syncTextInputVisuals(self: *WindowRuntime) !void {
        if (!self.initialized) return;
        for (0..self.text_inputs.slotCount()) |index| {
            const mounted = self.text_inputs.mountedAt(index) orelse continue;
            if (!self.instances.isActive(mounted.target) or
                !self.instances.isActive(mounted.content)) continue;
            const render = try self.instances.renderObject(mounted.content);
            var object = try self.tree.objectAt(render);
            if (object != .text_input) return error.TextInputRenderObjectMismatch;

            var presentation = try ui.text_input.buildPresentation(self.allocator, mounted.session);
            defer presentation.deinit();
            const previous_source = try self.paragraph_sources.get(object.text_input.source);
            const source = try self.paragraph_sources.acquire(.{
                .utf8 = presentation.text,
                .base_direction = previous_source.base_direction,
                .language = previous_source.language,
                .logical_size = previous_source.logical_size,
                .candidates = previous_source.candidates,
                .configuration_revision = previous_source.configuration_revision,
            });
            defer self.paragraph_sources.release(source) catch unreachable;

            object.text_input.source = source;
            object.text_input.selection_start = presentation.selection.start;
            object.text_input.selection_end = presentation.selection.end;
            object.text_input.caret_offset = presentation.caret_offset;
            object.text_input.caret_affinity = presentation.caret_affinity;
            object.text_input.show_caret = presentation.show_caret and
                optionalSameHandle(self.focus.current(), mounted.target);
            object.text_input.preedit = if (presentation.preedit) |range| .{
                .start = range.start,
                .end = range.end,
            } else null;
            object.text_input.preedit_color = if (presentation.preedit != null)
                object.text_input.caret_color
            else
                null;
            try self.tree.update(render, object);
        }
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
    try std.testing.expect((try runtime.tree.objectAt(focused_render)).box.outline_color == null);

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

test "text input protocol batches mutate retained sessions only at the input safe point" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    const window: platform.WindowHandle = .{ .slot = 7, .generation = 1 };
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const source = try sources.acquire(.{
        .utf8 = "hello",
        .language = "und",
        .logical_size = 14,
        .candidates = &.{font},
        .configuration_revision = 1,
    });

    var runtime: WindowRuntime = .{};
    try runtime.tree.init(std.testing.allocator, 2);
    runtime.tree.attachTextCaches(&sources, &paragraphs);
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
    try runtime.pointer_bindings.init(std.testing.allocator, 2);
    try runtime.buttons.init(std.testing.allocator, 2);
    try runtime.text_inputs.init(std.testing.allocator, 1);
    runtime.allocator = std.testing.allocator;
    runtime.initialized = true;
    runtime.window = window;
    runtime.paragraph_sources = &sources;
    runtime.border_color = core.Color.rgba(90, 90, 90, 255);
    runtime.focus_color = core.Color.rgba(20, 80, 220, 255);
    defer {
        runtime.text_inputs.clear();
        runtime.text_inputs.deinit();
        runtime.buttons.clear();
        runtime.buttons.deinit();
        runtime.pointer_bindings.deinit();
        runtime.router.deinit();
        runtime.instances.reconcile(&.{}) catch unreachable;
        scheduler.applyQueuedCancellations() catch unreachable;
        runtime.instances.collectRetired() catch unreachable;
        runtime.instances.deinit();
        runtime.tree.deinit();
        scheduler.destroyScope(window_scope) catch unreachable;
    }
    try runtime.instances.reconcile(&.{
        .{
            .id = 1,
            .parent = null,
            .object = .{ .box = .{
                .width = 160,
                .height = 32,
                .border_color = runtime.border_color,
                .border_width = 1,
            } },
            .focusable = true,
        },
        .{ .id = 2, .parent = 1, .object = .{ .text_input = .{
            .source = source,
            .color = core.Color.rgba(10, 10, 10, 255),
            .selection_color = core.Color.rgba(20, 40, 200, 100),
            .caret_color = core.Color.rgba(10, 10, 10, 255),
            .selection_start = 5,
            .selection_end = 5,
            .caret_offset = 5,
        } } },
    });
    try sources.release(source);
    const target = runtime.instances.handleForId(1).?;
    const content = runtime.instances.handleForId(2).?;
    const owner: ui.instance.BuildOwnerHandle = .{ .slot = 1, .generation = 1 };
    try runtime.text_inputs.mount(owner, target, content, "hello");
    var loop: @import("../loop/io_uring.zig").Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var callback_vm: lua.Vm = undefined;
    try callback_vm.init(std.testing.allocator, &scheduler, &loop);
    defer callback_vm.deinit();
    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(std.testing.allocator, 1);
    defer callbacks.deinit();
    const callback_source = "return function(value) changed_text = value end";
    try std.testing.expectEqual(
        lua_c.ok,
        lua_c.luaL_loadbufferx(
            callback_vm.state,
            callback_source.ptr,
            callback_source.len,
            "@text-change-test",
            null,
        ),
    );
    try std.testing.expectEqual(lua_c.ok, lua_c.lua_pcallk(callback_vm.state, 0, 1, 0, 0, null));
    const callback = try callbacks.adoptReference(
        &callback_vm,
        lua_c.luaL_ref(callback_vm.state, lua_c.registry_index),
    );
    _ = try runtime.pointer_bindings.set(owner, target, .{
        .id = callback,
        .kind = .text_input_change,
    });
    _ = try runtime.focus.request(&runtime.instances, target);
    _ = try runtime.tree.layout(
        (try runtime.instances.rootRenderObject()).?,
        ui.layout.Constraints.tight(.{ .width = 160, .height = 32 }),
    );
    try runtime.applyFocusVisual(null, target);
    const focused_box = (try runtime.tree.objectAt(try runtime.instances.renderObject(target))).box;
    try std.testing.expectEqual(runtime.focus_color, focused_box.border_color.?);
    try std.testing.expectEqual(@as(f32, 1), focused_box.border_width);
    try std.testing.expect(focused_box.outline_color == null);

    var commit = [_]u8{'!'};
    try runtime.routeTextInput(.{ .batch = .{
        .window = window,
        .serial = 1,
        .serial_matches_state = true,
        .delete_surrounding = null,
        .commit = .{ .text = &commit },
        .preedit = null,
    } });
    @memset(&commit, '?');
    try std.testing.expectEqualStrings("hello", (try runtime.text_inputs.session(target)).model.text());
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings("hello!", (try runtime.text_inputs.session(target)).model.text());
    try std.testing.expect(!callback_vm.hasGlobal("changed_text"));
    try std.testing.expectEqual(
        lua.ResumeResult.completed,
        try callback_vm.resumeRunnable(scheduler.takeRunnable().?),
    );
    try std.testing.expectEqual(lua_c.type_string, lua_c.lua_getglobal(callback_vm.state, "changed_text"));
    var changed_length: usize = 0;
    const changed_text = lua_c.lua_tolstring(callback_vm.state, -1, &changed_length).?;
    try std.testing.expectEqualStrings("hello!", changed_text[0..changed_length]);
    lua_c.lua_settop(callback_vm.state, -2);
    const render = try runtime.instances.renderObject(content);
    const object = try runtime.tree.objectAt(render);
    try std.testing.expectEqualStrings("hello!", (try sources.get(object.text_input.source)).utf8);

    try runtime.routeTextInput(.{ .batch = .{
        .window = window,
        .serial = 1,
        .serial_matches_state = false,
        .delete_surrounding = null,
        .commit = .{ .text = "?" },
        .preedit = null,
    } });
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings("hello!?", (try runtime.text_inputs.session(target)).model.text());
    try std.testing.expect(!runtime.text_input_commit_permitted);
    try runtime.routeTextInput(.{ .batch = .{
        .window = window,
        .serial = 2,
        .serial_matches_state = true,
        .delete_surrounding = null,
        .commit = null,
        .preedit = null,
    } });
    try runtime.dispatchInput(&callbacks);
    try std.testing.expect(runtime.text_input_commit_permitted);

    const before_left = (try runtime.text_inputs.session(target)).model.selection;
    const expected_left = try runtime.tree.textVisualNeighbor(
        render,
        before_left.extent,
        before_left.extent_affinity,
        .left,
    );
    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 3,
        .time_ms = 4,
        .state = .pressed,
        .translated = .{ .keycode = 105, .logical = .arrow_left },
    } });
    try runtime.dispatchInput(&callbacks);
    const after_left = (try runtime.text_inputs.session(target)).model.selection;
    try std.testing.expectEqual(expected_left.byte_offset, after_left.extent);
    try std.testing.expectEqual(expected_left.affinity, after_left.extent_affinity);
    try std.testing.expect(after_left.isCollapsed());

    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 4,
        .time_ms = 5,
        .state = .pressed,
        .translated = .{
            .keycode = 105,
            .logical = .arrow_left,
            .modifiers = .{ .shift = true },
        },
    } });
    try runtime.dispatchInput(&callbacks);
    const extended = (try runtime.text_inputs.session(target)).model.selection;
    try std.testing.expectEqual(after_left.anchor, extended.anchor);
    try std.testing.expect(!extended.isCollapsed());

    const expected_home = try runtime.tree.textLineBoundary(
        render,
        extended.extent,
        extended.extent_affinity,
        .start,
    );
    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 5,
        .time_ms = 6,
        .state = .pressed,
        .translated = .{ .keycode = 102, .logical = .home },
    } });
    try runtime.dispatchInput(&callbacks);
    const after_home = try runtime.text_inputs.session(target);
    try std.testing.expectEqual(expected_home.byte_offset, after_home.model.selection.extent);
    try std.testing.expectEqual(expected_home.affinity, after_home.model.selection.extent_affinity);
    try std.testing.expect(after_home.model.selection.isCollapsed());
    try std.testing.expect(after_home.preferred_x == null);

    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 6,
        .time_ms = 7,
        .state = .pressed,
        .translated = .{ .keycode = 103, .logical = .arrow_up },
    } });
    try runtime.dispatchInput(&callbacks);
    try std.testing.expect((try runtime.text_inputs.session(target)).preferred_x != null);

    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 7,
        .time_ms = 8,
        .state = .pressed,
        .translated = .{
            .keycode = 106,
            .logical = .arrow_right,
            .modifiers = .{ .control = true },
        },
    } });
    try runtime.dispatchInput(&callbacks);
    const after_word = try runtime.text_inputs.session(target);
    try std.testing.expectEqual(@as(usize, 5), after_word.model.selection.extent);
    try std.testing.expect(after_word.preferred_x == null);

    _ = try runtime.tree.layout(
        (try runtime.instances.rootRenderObject()).?,
        ui.layout.Constraints.tight(.{ .width = 160, .height = 32 }),
    );
    const drag_start: core.PointF = .{ .x = 1, .y = 10 };
    const drag_end: core.PointF = .{ .x = 70, .y = 10 };
    const expected_drag_start = try runtime.textCaretAtPointer(target, drag_start);
    const expected_drag_end = try runtime.textCaretAtPointer(target, drag_end);
    try std.testing.expect(expected_drag_start.byte_offset != expected_drag_end.byte_offset);
    try runtime.routePointer(.{ .enter = .{
        .window = window,
        .serial = 8,
        .position = drag_start,
    } });
    try runtime.dispatchInput(&callbacks);
    try runtime.routePointer(.{ .button = .{
        .window = window,
        .serial = 9,
        .time_ms = 9,
        .button = 0x110,
        .state = .pressed,
    } });
    try runtime.dispatchInput(&callbacks);
    try std.testing.expect((try runtime.text_inputs.session(target)).isSelecting());
    try runtime.routePointer(.{ .motion = .{
        .window = window,
        .time_ms = 10,
        .position = drag_end,
    } });
    try runtime.dispatchInput(&callbacks);
    const dragged = (try runtime.text_inputs.session(target)).model.selection;
    try std.testing.expectEqual(expected_drag_start.byte_offset, dragged.anchor);
    try std.testing.expectEqual(expected_drag_start.affinity, dragged.anchor_affinity);
    try std.testing.expectEqual(expected_drag_end.byte_offset, dragged.extent);
    try std.testing.expectEqual(expected_drag_end.affinity, dragged.extent_affinity);
    try runtime.routePointer(.{ .button = .{
        .window = window,
        .serial = 10,
        .time_ms = 11,
        .button = 0x110,
        .state = .released,
    } });
    try runtime.dispatchInput(&callbacks);
    try std.testing.expect(!(try runtime.text_inputs.session(target)).isSelecting());

    while (scheduler.takeRunnable()) |runnable|
        _ = try callback_vm.resumeRunnable(runnable);
    var read_only_candidate: ?ui.text_input.Session = try ui.text_input.Session.init(
        std.testing.allocator,
        "ignored",
    );
    defer if (read_only_candidate) |*session_value| session_value.deinit();
    try runtime.text_inputs.prepareMount(target, .uncontrolled, &read_only_candidate);
    try runtime.text_inputs.mountPrepared(
        owner,
        target,
        content,
        .uncontrolled,
        .{ .read_only = true },
        &read_only_candidate,
    );
    const before_read_only = try std.testing.allocator.dupe(
        u8,
        (try runtime.text_inputs.session(target)).model.text(),
    );
    defer std.testing.allocator.free(before_read_only);
    try runtime.routeTextInput(.{ .batch = .{
        .window = window,
        .serial = 11,
        .serial_matches_state = true,
        .delete_surrounding = null,
        .commit = .{ .text = "blocked" },
        .preedit = null,
    } });
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings(
        before_read_only,
        (try runtime.text_inputs.session(target)).model.text(),
    );
    try std.testing.expect(scheduler.takeRunnable() == null);
    try std.testing.expect((try runtime.textInputStatus()) == null);
    _ = runtime.pointer_bindings.remove(target);
    try callbacks.release(callback);

    try fonts.release(font);
}

fn textInputIntent(key: platform.TranslatedKey) ?ui.text_input.EditIntent {
    if (key.modifiers.alt or key.modifiers.logo) return null;
    const extend = key.modifiers.shift;
    if (key.modifiers.control) return switch (key.logical) {
        .key_a => .select_all,
        .backspace => .delete_word_backward,
        .delete => .delete_word_forward,
        .arrow_left => .{ .move = .{ .destination = .word_previous, .extend = extend } },
        .arrow_right => .{ .move = .{ .destination = .word_next, .extend = extend } },
        else => null,
    };
    return switch (key.logical) {
        .backspace => .delete_backward,
        .delete => .delete_forward,
        .arrow_left => .{ .move = .{ .destination = .visual_left, .extend = extend } },
        .arrow_right => .{ .move = .{ .destination = .visual_right, .extend = extend } },
        .arrow_up => .{ .move = .{ .destination = .line_up, .extend = extend } },
        .arrow_down => .{ .move = .{ .destination = .line_down, .extend = extend } },
        .home => .{ .move = .{ .destination = .line_start, .extend = extend } },
        .end => .{ .move = .{ .destination = .line_end, .extend = extend } },
        else => null,
    };
}

fn intentEditsText(intent: ui.text_input.EditIntent) bool {
    return switch (intent) {
        .delete_backward, .delete_forward, .delete_word_backward, .delete_word_forward => true,
        .select_all, .move => false,
    };
}

const ClipboardShortcut = enum { copy, cut, paste };

fn textInputClipboardShortcut(key: platform.TranslatedKey) ?ClipboardShortcut {
    if (!key.modifiers.control or key.modifiers.alt or key.modifiers.logo) return null;
    return switch (key.logical) {
        .key_c => .copy,
        .key_x => .cut,
        .key_v => .paste,
        else => null,
    };
}

test "platform keys translate to neutral text editing intents" {
    try std.testing.expectEqual(
        ui.text_input.EditIntent{ .move = .{ .destination = .line_up, .extend = true } },
        textInputIntent(.{
            .keycode = 1,
            .logical = .arrow_up,
            .modifiers = .{ .shift = true },
        }).?,
    );
    try std.testing.expectEqual(
        ui.text_input.EditIntent{ .move = .{ .destination = .line_start } },
        textInputIntent(.{ .keycode = 1, .logical = .home }).?,
    );
    try std.testing.expectEqual(
        ui.text_input.EditIntent{ .move = .{ .destination = .word_previous } },
        textInputIntent(.{
            .keycode = 1,
            .logical = .arrow_left,
            .modifiers = .{ .control = true },
        }).?,
    );
    try std.testing.expectEqual(
        ui.text_input.EditIntent.select_all,
        textInputIntent(.{
            .keycode = 1,
            .logical = .key_a,
            .modifiers = .{ .control = true },
        }).?,
    );
    try std.testing.expectEqual(
        ClipboardShortcut.copy,
        textInputClipboardShortcut(.{
            .keycode = 1,
            .logical = .key_c,
            .modifiers = .{ .control = true },
        }).?,
    );
    try std.testing.expect(textInputClipboardShortcut(.{
        .keycode = 1,
        .logical = .key_v,
        .modifiers = .{ .control = true, .alt = true },
    }) == null);
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
        .text_input => unreachable,
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

fn optionalSameHandle(a: ?ui.instance.InstanceHandle, b: ui.instance.InstanceHandle) bool {
    return if (a) |value| sameHandle(value, b) else false;
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
        core.Color.rgba(13, 14, 15, 255),
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
