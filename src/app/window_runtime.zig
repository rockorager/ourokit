const std = @import("std");
const clipboard_module = @import("clipboard.zig");
const frame = @import("frame.zig");
const scroll_motion = @import("scroll.zig");
const scroll_geometry = @import("../ui/render_object/scroll.zig");
const text_input_coordinator = @import("text_input.zig");
const core = @import("../core/root.zig");
const lua = @import("../lua/root.zig");
const lua_c = @import("../lua/c.zig");
const platform = @import("../platform/window.zig");
const scene = @import("../scene/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");
const virtual_list = @import("../ui/widget/virtual_list.zig");
const layout_builder = @import("../ui/widget/layout_builder.zig");
const listener = @import("../ui/input/listener.zig");
const KeySequence = @import("../ui/input/key_chord.zig").Sequence;
const internal_drag = @import("../ui/input/drag.zig");

pub const Config = struct {
    node_capacity: usize = 256,
    build_pass_capacity: usize = 16,
    input_capacity: usize = 128,
    command_capacity: usize = 512,
    semantic_text_capacity: usize = 16 * 1024,
    /// Enable monotonic CPU phase timing for explicitly opted-in development.
    measure_phases: bool = false,
    /// Duration of each caret phase. Zero keeps the caret steady.
    caret_blink_interval_ns: u64 = 500 * std.time.ns_per_ms,
};

pub const SemanticTarget = struct {
    center: core.PointF,
    bounds: core.RectF,
    role: ui.semantics.Role,
    enabled: bool,
    visible: bool,
    scroll_axis: ?platform.PointerAxis,
};

pub const Measurement = struct {
    count: u64 = 0,
    timed_count: u64 = 0,
    total_ns: u64 = 0,
    last_ns: ?u64 = null,

    fn finish(self: *Measurement, start: ?u64) void {
        self.count +|= 1;
        self.last_ns = null;
        const before = start orelse return;
        const after = @import("../loop/root.zig").monotonicNow() catch return;
        const elapsed = after -| before;
        self.timed_count +|= 1;
        self.total_ns +|= elapsed;
        self.last_ns = elapsed;
    }
};

/// Successful CPU phases and accepted backend submissions, not presentation
/// timestamps or input-to-display latency. Failed phase attempts are excluded.
pub const Metrics = struct {
    builds: Measurement = .{},
    layouts: Measurement = .{},
    paints: Measurement = .{},
    input_events: u64 = 0,
    submitted_frames: u64 = 0,
};

pub const TextInputStatus = struct {
    state: platform.TextInputState,
    generation: u64,
    model_revision: u64,
    session_revision: u64,
    scene_revision: u64,
    commit_permitted: bool,
};

pub const DropSelection = struct {
    target: ui.instance.InstanceHandle,
    handler: ui.input.Handler,
    mime: @import("../platform/wayland/clipboard.zig").DragMime,
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
    activation_input: ?@import("../platform/activation.zig").Input = null,
    pointer_input: ?@import("../platform/activation.zig").Input = null,
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
    clicks: ui.input.Clicks = .{},
    pending_shortcut: ?struct {
        target: ui.instance.InstanceHandle,
        focus_revision: u64,
        revision: u64,
        prefix: KeySequence,
        deadline_ns: u64,
    } = null,
    input_now_ns: u64 = 0,
    private_keys_down: std.EnumSet(platform.LogicalKey) = std.EnumSet(platform.LogicalKey).initEmpty(),
    selection_pointer: ?core.PointF = null,
    range_drag: ?ui.instance.InstanceHandle = null,
    split_drag: ?struct { target: ui.instance.InstanceHandle, grab_offset: f32 } = null,
    scrollbar_drag: ?struct { target: ui.instance.InstanceHandle, grab_offset: f32 } = null,
    drag_session: ?internal_drag.Session = null,
    selection_tick_ns: ?u64 = null,
    scroll_motions: [2]scroll_motion.Motion = @splat(.{}),
    // Headless windows act focused; native hosts start false until keyboard enter.
    keyboard_focused: bool = true,
    // Pointer focus still routes keys, but only keyboard navigation draws rings.
    keyboard_focus_visible: bool = false,
    caret_blink_interval_ns: u64 = (Config{}).caret_blink_interval_ns,
    caret_visible: bool = true,
    caret_deadline_ns: ?u64 = null,
    caret_activity: ?CaretActivity = null,
    animation_now_ns: u64 = 0,
    animations: ui.animation.Registry = undefined,
    animation_deadline_ns: ?u64 = null,
    animation_frame_pending: bool = false,
    semantics: ui.semantics.Snapshot = undefined,
    surface_color: core.Color = undefined,
    background: ?core.Color = null,
    accent_color: core.Color = undefined,
    content_color: core.Color = undefined,
    border_color: core.Color = undefined,
    focus_color: core.Color = undefined,
    commands: []scene.Command = &.{},
    command_count: usize = 0,
    damage_tracker: scene.DamageTracker = undefined,
    frame_state: frame.State = .{},
    output_scale: f32 = 1,
    root_padding: f32 = @import("../design/root.zig").tokens.foundation.spacing_3,
    /// Popup visual disposal must not cancel a selected asynchronous action.
    callback_scope: ?task.ScopeHandle = null,
    popup_target: ?ui.instance.InstanceHandle = null,
    signals: *lua.Signals = undefined,
    paragraph_sources: *text.ParagraphSourceCache = undefined,
    paragraphs: *text.ParagraphCache = undefined,
    dirty_windows: ?*ui.instance.ReconcileQueue = null,
    clipboard: ?*clipboard_module.Coordinator = null,
    reconciling: bool = false,
    text_input_commit_permitted: bool = true,
    text_input_surface_focused: bool = true,
    text_input_owner: ?struct { target: ui.instance.InstanceHandle, session: u64 } = null,
    text_input_generation: u64 = 0,
    virtual_lists: virtual_list.Snapshot = .{},
    layout_builders: layout_builder.Snapshot = .{},
    native_work: bool = false,
    virtual_offsets_pending: bool = false,
    development_generation: u64 = 1,
    development_revision: u64 = 0,
    measure_phases: bool = false,
    metrics: Metrics = .{},

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
        self.animations = try ui.animation.Registry.init(allocator, config.node_capacity);
        errdefer self.animations.deinit();
        try self.semantics.init(allocator, config.node_capacity, config.semantic_text_capacity);
        errdefer self.semantics.deinit();
        const commands = try allocator.alloc(scene.Command, config.command_capacity);
        errdefer allocator.free(commands);
        var damage_tracker = try scene.DamageTracker.init(allocator, config.command_capacity);
        errdefer damage_tracker.deinit();
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
            .caret_blink_interval_ns = config.caret_blink_interval_ns,
            .animations = self.animations,
            .semantics = self.semantics,
            .surface_color = surface,
            .accent_color = accent,
            .content_color = content,
            .border_color = border_color,
            .focus_color = focus_color,
            .commands = commands,
            .damage_tracker = damage_tracker,
            .signals = signals,
            .paragraph_sources = paragraph_sources,
            .paragraphs = paragraphs,
            .measure_phases = config.measure_phases,
        };
    }

    fn phaseStart(self: *const WindowRuntime) ?u64 {
        if (!self.measure_phases) return null;
        return @import("../loop/root.zig").monotonicNow() catch null;
    }

    pub fn setDirtyWindowQueue(
        self: *WindowRuntime,
        dirty_windows: *ui.instance.ReconcileQueue,
    ) void {
        self.dirty_windows = dirty_windows;
        self.build_owners.setDirtySink(.{ .context = self, .notify = notifyDirtyWindow });
    }

    pub fn setTheme(self: *WindowRuntime, theme: @import("../design/root.zig").tokens.Theme) !void {
        self.surface_color = theme.background;
        self.accent_color = theme.primary;
        self.content_color = theme.foreground;
        self.border_color = theme.input;
        self.focus_color = theme.ring;
        if (self.ready) _ = try self.build_owners.markDirty(self.root_owner);
    }

    pub fn setBackground(self: *WindowRuntime, background: ?core.Color) !void {
        if (std.meta.eql(self.background, background)) return;
        self.background = background;
        if (self.ready) _ = try self.build_owners.markDirty(self.root_owner);
    }

    pub fn setClipboardCoordinator(self: *WindowRuntime, clipboard: *clipboard_module.Coordinator) void {
        self.clipboard = clipboard;
    }

    /// Hit tests the retained tree and resolves the nearest matching box
    /// binding. The returned generation-checked identity is snapshotted by the
    /// runner when transfer begins.
    pub fn dropTarget(self: *WindowRuntime, position: platform.LogicalPosition, text_offer: bool, uri_offer: bool) !?DropSelection {
        if (!self.ready) return null;
        const root = (try self.instances.rootRenderObject()) orelse return null;
        const render = (try self.tree.hitTest(root, .{ .x = position.x, .y = position.y })) orelse return null;
        var current: ?ui.instance.InstanceHandle = self.instances.instanceForRenderObject(render);
        if (current) |target| if (!self.instances.isInteractive(target)) return null;
        if (self.focus.boundary) |boundary| if (!try self.containsTarget(boundary, current)) return null;
        while (current) |target| {
            if (uri_offer) if (self.pointer_bindings.getKind(target, .drop_uris)) |handler|
                return .{ .target = target, .handler = handler, .mime = .uri_list };
            if (text_offer) if (self.pointer_bindings.getKind(target, .drop_text)) |handler|
                return .{ .target = target, .handler = handler, .mime = .text };
            current = try self.instances.parentOf(target);
        }
        return null;
    }

    pub fn deliverDrop(self: *WindowRuntime, callbacks: *lua.CallbackRegistry, selection: DropSelection, bytes: []const u8) !bool {
        if (!self.ready) return false;
        if (!self.instances.isInteractive(selection.target)) return false;
        if (self.focus.boundary) |boundary| if (!try self.containsTarget(boundary, selection.target)) return false;
        const kind: ui.input.HandlerKind = if (selection.mime == .text) .drop_text else .drop_uris;
        const current = self.pointer_bindings.getKind(selection.target, kind) orelse return false;
        if (!std.meta.eql(current, selection.handler)) return false;
        if (selection.mime == .text and !std.unicode.utf8ValidateSlice(bytes)) return false;
        if (selection.mime == .uri_list and !@import("../platform/wayland/clipboard.zig").validUriList(bytes)) return false;
        _ = try callbacks.spawn(current.id, self.callback_scope orelse try self.instances.scope(selection.target), &.{.{ .string = bytes }});
        return true;
    }

    pub fn deinit(self: *WindowRuntime) void {
        if (!self.initialized) return;
        std.debug.assert(self.pointer_bindings.takeAny() == null);
        self.allocator.free(self.commands);
        self.damage_tracker.deinit();
        self.semantics.deinit();
        self.animations.deinit();
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
        self.development_generation +%= 1;
        lua_ui.clearHandlers(&self.pointer_bindings);
        self.buttons.clear();
        self.listboxes.clear();
        self.text_inputs.clear();
        self.animations.clear();
        self.animation_deadline_ns = null;
        self.animation_frame_pending = false;
        self.focus = .{};
        self.range_drag = null;
        self.split_drag = null;
        self.scrollbar_drag = null;
        self.cancelInternalDrag();
        self.text_input_owner = null;
        self.text_input_generation +%= 1;
        self.clicks.reset();
        self.selection_pointer = null;
        self.selection_tick_ns = null;
        self.scroll_motions = @splat(.{});
        self.caret_activity = null;
        self.resetCaretBlink();
        while (self.router.takeEvent()) |event| self.router.releaseEvent(event);
        if (self.build_owners.isActive(self.root_owner)) {
            try self.signals.disposeOwner(.{
                .owners = &self.build_owners,
                .handle = self.root_owner,
            });
            lua_ui.disposeOwner(&self.build_owners, self.root_owner);
            try self.build_owners.retire(self.root_owner);
        }
        if (self.ready) try self.instances.reconcile(&.{});
        self.ready = false;
        self.command_count = 0;
        self.frame_state = .{};
        self.damage_tracker.invalidate();
        self.virtual_lists = .{};
        self.layout_builders = .{};
        self.native_work = false;
        self.virtual_offsets_pending = false;
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
        const started = self.phaseStart();
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
            .{ .integer = encodedColor(lua_ui.root_background orelse self.surface_color) },
            .{ .integer = encodedColor(self.accent_color) },
            .{ .integer = encodedColor(self.content_color) },
        };
        lua_ui.components.instances = &self.instances;
        lua_ui.components.focused = self.focus.current();
        lua_ui.components.native_update = false;
        // Candidate generations start fresh, without sampling or mutating
        // the live generation's timelines during preparation.
        lua_ui.animations = null;
        lua_ui.image_scale = self.output_scale;
        lua_ui.root_padding = self.root_padding;
        if (lua_ui.images) |images| if (self.tree.images == null) self.tree.attachImageCache(images.cache);
        defer lua_ui.components.instances = null;
        var measurement: LayoutMeasurement = .{ .runtime = self, .size = size, .lua_ui = lua_ui };
        lua_ui.layout_measurement = .{ .context = &measurement, .measure = LayoutMeasurement.measure };
        defer lua_ui.layout_measurement = null;
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
        if (prepared.button_count != 0 and prepared.button_count > self.buttons.availableForOwner(self.root_owner))
            return error.ButtonCapacityExceeded;
        if (prepared.text_input_count != 0 and prepared.text_input_count > self.text_inputs.availableForOwner(self.root_owner))
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
        try self.retainTextInputPresentation(prepared.descriptor_storage[0..prepared.descriptor_count], prepared.text_inputs[0..prepared.text_input_count]);
        const plan = try self.instances.prepareReconcile(prepared.descriptors());
        if (prepared.handler_count != 0 and prepared.handler_count > self.pointer_bindings.availableAfterReconcile(
            &self.instances,
            self.root_owner,
        )) return error.PointerBindingCapacityExceeded;
        try self.animations.validate(prepared.animations[0..prepared.animation_count]);
        _ = try self.validatePreparedFrame(prepared.descriptors(), size, lua_ui.root_background != null, null);
        try lua_ui.commitDependencies(&self.build_owners, work);
        dependencies_pending = false;
        prepared.reconcile_plan = plan;
        prepared.size = size;
        captured = false;
        self.metrics.builds.finish(started);
    }

    /// Measure candidates using the presentation that mountPrepared will retain,
    /// rather than the declaration's possibly obsolete default_text.
    fn retainTextInputPresentation(self: *WindowRuntime, descriptors: []ui.instance.Descriptor, inputs: anytype) !void {
        for (inputs) |*input| {
            if (!containsDescriptorId(descriptors, input.target_id) or
                !containsDescriptorId(descriptors, input.content_id))
                return error.TextInputInstanceMissing;
            if (self.instances.handleForId(input.target_id)) |target| {
                try self.text_inputs.prepareMount(target, input.mode, &input.session);
                if (!self.text_inputs.contains(target)) continue;
                const retained = try self.text_inputs.session(target);
                const candidate = &input.session.?.model;
                const descriptor_index = descriptorIndexForId(
                    descriptors,
                    input.content_id,
                ).?;
                var object = &descriptors[descriptor_index].object;
                if (object.* != .text_input) return error.TextInputRenderObjectMismatch;
                const retained_secret = (try self.text_inputs.getBehavior(target)).secret;
                const same_secret = if (retained_secret) |value|
                    input.behavior.secret != null and value.eql(input.behavior.secret.?)
                else
                    input.behavior.secret == null;
                if (retained.model.multiline == candidate.multiline and
                    retained.model.isSecret() == candidate.isSecret() and same_secret and
                    (input.mode == .uncontrolled or
                        std.mem.eql(u8, retained.model.text(), candidate.text())))
                {
                    const retained_content = try self.text_inputs.content(target);
                    const retained_object = try self.tree.objectAt(
                        try self.instances.renderObject(retained_content),
                    );
                    if (retained_object != .text_input)
                        return error.TextInputRenderObjectMismatch;
                    const old_source = try self.paragraph_sources.get(retained_object.text_input.source);
                    const new_source = try self.paragraph_sources.get(object.text_input.source);
                    const source = try self.paragraph_sources.acquire(.{
                        .utf8 = old_source.utf8,
                        .base_direction = new_source.base_direction,
                        .language = new_source.language,
                        .logical_size = new_source.logical_size,
                        .candidates = new_source.candidates,
                        .configuration_revision = new_source.configuration_revision,
                    });
                    self.paragraph_sources.release(object.text_input.source) catch unreachable;
                    object.text_input.source = source;
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
                    object.text_input.show_caret = optionalSameHandle(self.focus.current(), target) and self.keyboard_focused and self.caret_visible;
                }
            }
        }
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
        self.cancelInternalDrag();
        self.development_generation +%= 1;
        self.semantics.stage(prepared.semanticDescriptors());
        self.instances.applyReconcile(prepared.reconcile_plan.?) catch unreachable;
        self.animations.clear();
        self.animations.reconcile(prepared.animations[0..prepared.animation_count]) catch unreachable;
        self.animation_deadline_ns = null;
        self.animation_frame_pending = false;

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
                .{ .id = callback, .kind = handler.kind, .propagate = handler.propagate, .filter = handler.filter, .sequence = handler.sequence },
            ) catch unreachable;
            std.debug.assert(old == null);
        }

        self.buttons.removeInactive(&self.instances);
        self.buttons.beginOwner(self.root_owner);
        for (prepared.prepared_buttons[0..prepared.button_count]) |button| self.buttons.set(
            self.root_owner,
            self.instances.handleForId(button.id).?,
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
            option.value,
        ) catch unreachable;
        self.listboxes.finishOwner(self.root_owner);
        for (0..self.buttons.slotCount()) |index|
            if (self.buttons.targetAt(index)) |target| self.applyButtonUpdate(target) catch unreachable;
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

        self.focus.reconcile(&self.instances);
        if (self.text_inputs.takeAutofocus()) |target| {
            const previous = self.focus.current();
            _ = self.focus.request(&self.instances, target) catch unreachable;
            self.applyFocusVisual(previous, self.focus.current()) catch unreachable;
        }
        if (self.focus.current()) |target| self.setFocusBorder(target, true) catch unreachable;
        self.signals.disposeOwner(.{
            .owners = &self.build_owners,
            .handle = self.root_owner,
        }) catch unreachable;
        self.signals = signals;
        self.semantics.commitStaged();
        self.syncDialogFocus() catch unreachable;
        self.applyFocusRequests() catch unreachable;
        self.scrollbar_drag = null;
        @memset(self.pointer_bindings.scrolls, .{});
        self.pointer_bindings.scroll_limit = 0;
        while (self.router.takeEvent() != null) {}
        _ = self.frame_state.configure(prepared.size.?) catch unreachable;
        self.frame_state.invalidatePaint();
        self.damage_tracker.invalidate();
        self.ready = true;
        self.virtual_lists = prepared.virtual_lists;
        self.layout_builders = prepared.layout_builders;
        self.virtual_offsets_pending = true;
        self.native_work = false;
        if (self.virtual_lists.count != 0) self.queueNativeBuild() catch unreachable;
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
        lua_ui.components.instances = &self.instances;
        lua_ui.animations = &self.animations;
        defer lua_ui.animations = null;
        lua_ui.image_scale = self.output_scale;
        lua_ui.root_padding = self.root_padding;
        lua_ui.root_background = self.background;
        if (lua_ui.images) |images| if (self.tree.images == null) self.tree.attachImageCache(images.cache);
        defer lua_ui.components.instances = null;
        var measurement: LayoutMeasurement = .{ .runtime = self, .size = size, .lua_ui = lua_ui };
        lua_ui.layout_measurement = .{ .context = &measurement, .measure = LayoutMeasurement.measure };
        defer lua_ui.layout_measurement = null;
        var builds = self.build_owners.beginCycle();
        while (try builds.take()) |work| {
            const started = self.phaseStart();
            std.debug.assert(sameHandle(work.owner, self.root_owner));
            lua_ui.components.focused = self.focus.current();
            lua_ui.components.native_update = self.native_work;
            const arguments = [_]lua.UiBuildArgument{
                .{ .number = width },
                .{ .number = height },
                .{ .integer = encodedColor(self.background orelse self.surface_color) },
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
            self.instances.collectRetired() catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            const plan = self.instances.prepareReconcile(descriptors) catch |err| {
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
            lua_ui.validateBindings(
                &self.pointer_bindings,
                &self.buttons,
                &self.text_inputs,
                &self.instances,
                work.owner,
            ) catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            self.animations.validate(lua_ui.animationDescriptors()) catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            self.semantics.stage(lua_ui.semanticDescriptors());
            self.instances.applyReconcile(plan) catch unreachable;
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
            try self.syncDialogFocus();
            if (self.callback_scope != null and self.focus.current() == null)
                _ = try self.focus.advance(&self.instances, .forward);
            if (self.text_inputs.takeAutofocus()) |target| {
                const previous = self.focus.current();
                _ = try self.focus.request(&self.instances, target);
                try self.applyFocusVisual(previous, self.focus.current());
            }
            try self.applyFocusRequests();
            for (0..self.buttons.slotCount()) |index|
                if (self.buttons.targetAt(index)) |target| try self.applyButtonUpdate(target);
            try self.refreshListBoxVisuals();
            try self.applyFocusVisual(null, self.focus.current());
            self.virtual_lists = lua_ui.virtual_lists;
            self.layout_builders = lua_ui.layout_builders;
            self.animations.reconcile(lua_ui.animationDescriptors()) catch unreachable;
            // This build consumed current samples, including an external
            // invalidation between animation frames. Never postpone a wakeup.
            self.animation_frame_pending = false;
            if (self.animations.delay()) |delay| {
                const deadline = self.animation_now_ns +| delay;
                self.animation_deadline_ns = @min(self.animation_deadline_ns orelse deadline, deadline);
            } else self.animation_deadline_ns = null;
            self.virtual_offsets_pending = true;
            self.native_work = false;
            try self.build_owners.complete(work);
            self.development_revision +%= 1;
            self.metrics.builds.finish(started);
            // Native layout feeds the next bounded build pass; it never calls Lua.
            try self.prepareFrame(self.output_scale);
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
            self.damage_tracker.invalidate();
            _ = try self.build_owners.markDirty(self.root_owner);
        }
        const root = (try self.instances.rootRenderObject()) orelse return;
        const size = self.frame_state.size.?;
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        if (self.frame_state.needsLayout() or try self.tree.layoutDirty(root)) {
            const started = self.phaseStart();
            self.frame_state.invalidateLayout();
            _ = try self.tree.layout(
                root,
                ui.layout.Constraints.tight(.{ .width = width, .height = height }),
            );
            try self.instances.syncScrollOffsets();
            try self.frame_state.layoutComplete();
            self.metrics.layouts.finish(started);
        }
        try self.updateVirtualLayout();
        for (self.layout_builders.entries[0..self.layout_builders.count]) |entry| {
            const target = self.instances.handleForId(entry.id) orelse continue;
            const bounds = try self.tree.lastConstraints(try self.instances.renderObject(target));
            if (!std.meta.eql(bounds, entry.constraints)) try self.queueNativeBuild();
        }
        if (try self.instances.revealScrollTargets()) self.frame_state.invalidatePaint();
        if (try self.instances.applyScrollRequests()) {
            self.scroll_motions = @splat(.{});
            self.scrollbar_drag = null;
            if (self.virtual_lists.count != 0) try self.queueNativeBuild();
        }
        if (self.scrollbar_drag) |drag| {
            const render = if (self.instances.isInteractive(drag.target)) try self.instances.renderObject(drag.target) else null;
            const object = if (render) |node| try self.tree.objectAt(node) else null;
            if (object == null or object.? != .scroll or object.?.scroll.scrollbar == null)
                self.scrollbar_drag = null;
        }
        try self.reconcileInternalDrag();
        if (try self.tree.paintDirty(root) or self.frame_state.needsScene()) {
            const started = self.phaseStart();
            self.frame_state.invalidatePaint();
            var builder = try ui.render_object.Builder.init(self.commands, self.output_scale);
            // The root paints the tint once. Reset reused buffers so a
            // translucent root never blends with the previous frame.
            if (self.background != null) try builder.clear(core.Color.rgba(0, 0, 0, 0));
            try self.tree.buildScene(root, &builder);
            if (self.drag_session) |drag| if (drag.active) {
                try builder.pushClip(.{ .x = 0, .y = 0, .width = width, .height = height });
                if (drag.target) |target| try builder.decoratedRectangle(
                    try self.tree.paintBounds(try self.instances.renderObject(target)),
                    null,
                    self.focus_color,
                    2,
                    0,
                );
                const source = try self.instances.renderObject(drag.source);
                const offset: core.PointF = .{
                    .x = drag.position.x - drag.start.x + 12,
                    .y = drag.position.y - drag.start.y + 24,
                };
                var bounds = try self.tree.paintBounds(source);
                bounds.x += offset.x;
                bounds.y += offset.y;
                // Transparent sources (e.g. tab labels) need an opaque plate
                // so destination text cannot show through the moving glyphs.
                var plate = self.surface_color;
                plate.a = 255;
                try builder.decoratedRectangle(bounds, plate, self.border_color, 1, 4);
                try builder.pushOpacity(0.75);
                try self.tree.buildPreview(source, &builder, offset);
                try builder.popOpacity();
                try builder.popClip();
            };
            self.command_count = builder.displayList().commands.len;
            _ = try self.frame_state.sceneBuilt();
            self.metrics.paints.finish(started);
        }
    }

    fn queueNativeBuild(self: *WindowRuntime) !void {
        if (self.native_work) return;
        self.native_work = true;
        _ = try self.build_owners.markReaderDirty(self.root_owner);
    }

    fn updateVirtualLayout(self: *WindowRuntime) !void {
        var changed = false;
        for (self.virtual_lists.lists[0..self.virtual_lists.count]) |list| {
            const target = self.instances.handleForId(list.id) orelse continue;
            const render = try self.instances.renderObject(target);
            const size = scroll_geometry.contentViewport((try self.tree.objectAt(render)).scroll, try self.tree.nodeSize(render));
            if (self.virtual_offsets_pending) {
                if (try self.instances.scrollBy(target, list.offset - try self.instances.scrollOffset(target)))
                    self.frame_state.invalidatePaint();
            }
            if (@abs(size.width - list.width) > 0.01 or @abs(size.height - list.viewport) > 0.01)
                changed = true;
            if (!list.fixed) for (self.virtual_lists.rows[list.row_start..][0..list.row_count]) |row| {
                const handle = self.instances.handleForId(row.id) orelse continue;
                const measured = try self.tree.nodeSize(try self.instances.renderObject(handle));
                if (@abs(measured.height - row.height) > 0.01) changed = true;
            };
        }
        self.virtual_offsets_pending = false;
        if (changed) try self.queueNativeBuild();
    }

    pub fn textInputStatus(self: *WindowRuntime) !?TextInputStatus {
        if (try self.refreshTextInputOwner()) try self.syncTextInputVisuals();
        const focused = (self.text_input_owner orelse return null).target;
        const session = try self.text_inputs.session(focused);
        var state = text_input_coordinator.surroundingState(session);
        const content = try self.text_inputs.content(focused);
        const render = try self.instances.renderObject(content);
        const local = try self.tree.textCaretRectangle(render);
        const rectangle = (try self.tree.paintTransform(render)).rect(local);
        state.cursor_rectangle = .{
            .x = @intFromFloat(@floor(rectangle.x)),
            .y = @intFromFloat(@floor(rectangle.y)),
            .width = @intFromFloat(@ceil(rectangle.width)),
            .height = @intFromFloat(@ceil(rectangle.height)),
        };
        return .{
            .state = state,
            .generation = self.text_input_generation,
            .model_revision = session.model.revision,
            .session_revision = session.revision,
            .scene_revision = self.frame_state.scene_revision,
            .commit_permitted = self.text_input_commit_permitted,
        };
    }

    pub fn routePointer(self: *WindowRuntime, event: platform.PointerEvent) !void {
        try self.router.route(event);
        if (event == .leave) {
            self.cancelInternalDrag();
            self.scrollbar_drag = null;
        }
        // A press outside the hit tree is not queued, but must still stop a fling.
        if (event == .button and event.button.state == .pressed) {
            self.pending_shortcut = null;
            self.scroll_motions = @splat(.{});
        }
    }

    pub fn pointerCursor(self: *WindowRuntime) !platform.PointerCursor {
        if (!self.ready or !self.router.pointer_inside) return .default;
        if (self.split_drag) |drag| if (try self.splitCursor(drag.target)) |cursor| return cursor;
        if (self.router.captured) |captured| if (self.instances.isActive(captured)) {
            if (try self.textInputAncestor(captured)) |input|
                if ((try self.text_inputs.session(input)).isSelecting()) return .text;
        };
        // Re-hit-test so rebuilding under a stationary pointer updates its shape.
        const root = (try self.instances.rootRenderObject()) orelse return .default;
        const render = (try self.tree.hitTest(root, self.router.pointer_position)) orelse return .default;
        const target = self.instances.instanceForRenderObject(render) orelse return .default;
        if (try self.splitCursor(target)) |cursor| return cursor;
        const input = (try self.textInputAncestor(target)) orelse return .default;
        return if ((try self.text_inputs.getBehavior(input)).enabled) .text else .default;
    }

    fn splitCursor(self: *WindowRuntime, target: ui.instance.InstanceHandle) !?platform.PointerCursor {
        if (!self.instances.isInteractive(target)) return null;
        var current = target;
        while (true) {
            if (self.pointer_bindings.get(current)) |binding| {
                if (binding.kind != .split_change) return null;
                break;
            }
            current = (try self.instances.parentOf(current)) orelse return null;
        }
        const parent = (try self.instances.parentOf(current)) orelse return null;
        const object = try self.tree.objectAt(try self.instances.renderObject(parent));
        if (object != .split) return null;
        return if (object.split.axis == .horizontal) .col_resize else .row_resize;
    }

    pub fn routeKeyboard(self: *WindowRuntime, event: platform.KeyboardEvent) !void {
        try self.router.routeKeyboard(event);
    }

    pub fn routeTextInput(self: *WindowRuntime, event: platform.TextInputEvent) !void {
        const batch = switch (event) {
            .batch => |value| value,
            .enter, .leave => |window| {
                if (!sameHandle(window, self.window)) return error.WrongWindow;
                return self.router.routeTextInputFocus(event == .enter);
            },
        };
        if (!sameHandle(batch.window, self.window)) return error.WrongWindow;
        try self.router.routeTextInput(
            try text_input_coordinator.editBatch(batch),
            batch.serial_matches_state,
            batch.generation orelse self.text_input_generation,
        );
    }

    /// Dispatches through either the process-wide callback registry used by
    /// reloadable applications or a directly owned VM used by storybooks.
    pub fn dispatchInput(self: *WindowRuntime, callback_service: anytype) !void {
        return self.dispatchInputAt(callback_service, try @import("../loop/root.zig").monotonicNow());
    }

    /// A monotonic clock seam for deterministic input timeout tests.
    pub fn dispatchInputAt(self: *WindowRuntime, callback_service: anytype, now_ns: u64) !void {
        self.input_now_ns = now_ns;
        self.validatePendingShortcut();
        while (self.router.takeEvent()) |event| {
            defer self.router.releaseEvent(event);
            // A platform leave may be queued behind the press that arms the
            // session. Motion-generated hover leaves have no platform serial.
            if (event == .hover_leave and event.hover_leave.serial != null) self.cancelInternalDrag();
            self.development_revision +%= 1;
            self.metrics.input_events +|= 1;
            self.activation_input = null;
            self.pointer_input = null;
            defer self.activation_input = null;
            defer self.pointer_input = null;
            const serial: ?u32 = switch (event) {
                .pointer => |pointer| switch (pointer.event) {
                    .button => |button| if (button.state == .pressed) button.serial else null,
                    else => null,
                },
                .keyboard => |keyboard| switch (keyboard) {
                    .key => |key| if (key.state == .pressed) key.serial else null,
                    else => null,
                },
                else => null,
            };
            if (serial) |value| {
                const source = if (event == .keyboard and event.keyboard == .key)
                    event.keyboard.key.source_window orelse self.window
                else
                    self.window;
                if (value != 0) {
                    self.activation_input = .{ .window = source, .serial = value };
                    if (event == .pointer) self.pointer_input = self.activation_input;
                }
            }
            if (event == .text_input_focus) {
                self.pending_shortcut = null;
                self.text_input_surface_focused = event.text_input_focus;
                try self.syncTextInputVisuals();
                continue;
            }
            if (event == .text_input) {
                self.pending_shortcut = null;
                _ = try self.refreshTextInputOwner();
                const focused = (self.text_input_owner orelse continue).target;
                if (event.text_input.generation != self.text_input_generation) continue;
                self.text_input_commit_permitted = event.text_input.serial_matches_state;
                const session = try self.text_inputs.session(focused);
                const model_revision = session.model.revision;
                _ = try session.apply(event.text_input.batch);
                self.resetCaretBlink();
                try self.syncTextInputVisuals();
                if (session.model.revision != model_revision)
                    try self.notifyTextInputChanged(callback_service, focused);
                continue;
            }
            if (event == .keyboard) {
                try self.dispatchKeyboard(event.keyboard, callback_service);
                continue;
            }
            // Once captured as a drag, motion/release belong to the native
            // session, including a release outside the hit tree or modal scope.
            if (try self.dispatchInternalDrag(event, callback_service)) continue;
            if (event == .pointer) switch (event.pointer.event) {
                .button => |button| if (button.state == .pressed) {
                    self.pending_shortcut = null;
                    self.scroll_motions = @splat(.{});
                    if (self.keyboard_focus_visible) {
                        self.keyboard_focus_visible = false;
                        try self.applyFocusVisual(self.focus.current(), self.focus.current());
                    }
                },
                .axis => {
                    for (&self.scroll_motions) |*motion| if (motion.active) {
                        motion.* = .{};
                    };
                },
                .axis_stop => |stop| {
                    self.scroll_motions[@intFromEnum(stop.axis)].stop(stop.time_ms);
                    continue;
                },
                else => {},
            };
            const target = switch (event) {
                .hover_enter => |value| value.target,
                .hover_leave => |value| value.target,
                .pointer => |value| value.target,
                .keyboard => unreachable,
                .text_input, .text_input_focus => unreachable,
            };
            if (!self.instances.isInteractive(target)) continue;
            if (event == .pointer and event.pointer.event == .button and event.pointer.event.button.state == .pressed) {
                const has_outside = for (self.pointer_bindings.entries[0..self.pointer_bindings.entry_limit]) |entry| {
                    if (entry.handler) |handler| if (handler.kind == .pointer_down_outside) break true;
                } else false;
                if (has_outside) if (try self.instances.rootRenderObject()) |root| {
                    var input = pointerListenerEvent(event).?;
                    input.phase = .capture;
                    if (try self.dispatchOutsidePointer(root, target, input, callback_service)) continue;
                };
            }
            if (self.focus.boundary) |boundary| if (!try self.containsTarget(boundary, target)) continue;
            if (pointerListenerEvent(event)) |input| {
                // Release bookkeeping is not a vetoable default action: a
                // filtered release must never leave an existing native drag stuck.
                if (input.kind == .release and input.button == 0x110) {
                    try self.applyButtonUpdate(self.buttons.release());
                    self.range_drag = null;
                    self.split_drag = null;
                    self.scrollbar_drag = null;
                    if (try self.textInputAncestor(target)) |field|
                        (try self.text_inputs.session(field)).endSelectionDrag();
                    self.selection_pointer = null;
                }
                if (input.kind == .leave) {
                    _ = try self.updateButtonState(event);
                    try self.updateListBoxHover(event);
                }
                if (try self.dispatchListeners(target, input, callback_service)) continue;
            }
            if (try self.dispatchScrollbar(target, event)) continue;
            if (event == .pointer and event.pointer.event == .button and
                event.pointer.event.button.button == 0x110 and event.pointer.event.button.state == .pressed)
                try self.armInternalDrag(target, event.pointer.position);
            try self.updateTextInputPointer(target, event);
            const activated_button = try self.updateButtonState(event);
            if (event == .pointer and event.pointer.event == .button and
                event.pointer.event.button.button == 0x110 and event.pointer.event.button.state == .pressed)
            {
                var ancestor: ?ui.instance.InstanceHandle = target;
                while (ancestor) |handle| {
                    if (self.virtual_lists.find(try self.instances.semanticId(handle)) != null) {
                        const previous = self.focus.current();
                        _ = try self.focus.request(&self.instances, handle);
                        try self.applyFocusVisual(previous, self.focus.current());
                        break;
                    }
                    if (self.instances.isFocusable(handle)) {
                        const previous = self.focus.current();
                        _ = try self.focus.request(&self.instances, handle);
                        try self.applyFocusVisual(previous, self.focus.current());
                        break;
                    }
                    ancestor = try self.instances.parentOf(handle);
                }
            }
            try self.updateListBoxHover(event);
            if (try self.applyScrollEvent(target, event)) continue;
            var bound_target = target;
            var handler = self.pointer_bindings.get(bound_target);
            while (handler == null) {
                if (self.focus.boundary) |boundary| if (sameHandle(boundary, bound_target)) break;
                bound_target = (try self.instances.parentOf(bound_target)) orelse break;
                handler = self.pointer_bindings.get(bound_target);
            }
            const binding = handler orelse continue;
            if (binding.kind == .split_change) {
                if (event != .pointer) continue;
                const pointer = event.pointer;
                const parent = (try self.instances.parentOf(bound_target)) orelse continue;
                const parent_render = try self.instances.renderObject(parent);
                const object = try self.tree.objectAt(parent_render);
                if (object != .split) continue;
                const axis = object.split.axis;
                const transform = try self.tree.paintTransform(parent_render);
                const local_pointer = transform.inversePoint(pointer.position);
                if (pointer.event == .button and pointer.event.button.button == 0x110) {
                    if (pointer.event.button.state == .pressed) {
                        const divider_origin = transform.inversePoint((try self.tree.paintTransform(try self.instances.renderObject(bound_target))).point(.{}));
                        self.split_drag = .{
                            .target = bound_target,
                            .grab_offset = axisCoordinate(axis, local_pointer) - axisCoordinate(axis, divider_origin),
                        };
                    } else self.split_drag = null;
                }
                const drag = self.split_drag orelse continue;
                if (!sameHandle(drag.target, bound_target) or
                    (pointer.event != .motion and pointer.event != .button)) continue;
                const size = try self.tree.nodeSize(parent_render);
                const extent = if (axis == .horizontal) size.width else size.height;
                const resolution = @import("../ui/render_object/split.zig").resolve(object.split, extent);
                const requested = axisCoordinate(axis, local_pointer) - drag.grab_offset;
                const first = std.math.clamp(requested, resolution.min, resolution.max);
                const fraction = if (resolution.available == 0) @as(f32, 0) else first / resolution.available;
                if (fraction != object.split.position)
                    try self.spawnCallback(callback_service, binding.id, try self.instances.scope(bound_target), &.{.{ .number = fraction }});
                continue;
            }
            if (binding.kind == .range_change) {
                if (event != .pointer) continue;
                const pointer = event.pointer;
                const semantic = self.semantics.findId(try self.instances.semanticId(bound_target)) orelse continue;
                if (!semantic.enabled) {
                    self.range_drag = null;
                    continue;
                }
                if (pointer.event == .button and pointer.event.button.button == 0x110) {
                    self.range_drag = if (pointer.event.button.state == .pressed) bound_target else null;
                }
                if (self.range_drag == null or !sameHandle(self.range_drag.?, bound_target)) continue;
                if (pointer.event != .motion and pointer.event != .button) continue;
                const render = try self.instances.renderObject(bound_target);
                const local_pointer = (try self.tree.paintTransform(render)).inversePoint(pointer.position);
                const size = try self.tree.nodeSize(render);
                const range = semantic.range.?;
                const inset = try self.instances.rangeInset(bound_target);
                const value = range.atFraction((local_pointer.x - inset) / @max(1, size.width - 2 * inset));
                if (value != range.value) try self.spawnCallback(callback_service, binding.id, try self.instances.scope(bound_target), &.{.{ .number = value }});
                continue;
            }
            if (binding.kind == .button or binding.kind == .@"switch") {
                if (activated_button != null and sameHandle(activated_button.?, bound_target))
                    try self.spawnButtonCallback(callback_service, bound_target);
                continue;
            }
            if (binding.kind == .listbox) {
                const selection = try self.listBoxPointerSelection(target, event) orelse continue;
                const semantic = self.semantics.findId(try self.instances.semanticId(selection.listbox)) orelse continue;
                if (!semantic.enabled) continue;
                const previous = self.focus.current();
                if (semantic.role != .radio_group and semantic.role != .tab_list) self.listboxes.select(selection);
                try self.refreshListBoxVisuals();
                _ = try self.focus.request(&self.instances, selection.listbox);
                try self.applyFocusVisual(previous, self.focus.current());
                try self.ensureOptionVisible(selection.option);
                try self.spawnListBoxCallback(callback_service, binding.id, selection);
                try self.activateSelection(callback_service, selection.listbox, selection.value);
                continue;
            }
            if (binding.kind == .text_input_change or binding.kind == .text_input_command) continue;
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
        // A queued press may have preceded a platform leave in this batch.
        if (!self.router.pointer_inside) self.scrollbar_drag = null;
        try self.syncInteractions(callback_service);
        try self.publishScrollEvents(callback_service);
    }

    fn observedScrollMetrics(self: *WindowRuntime, target: ui.instance.InstanceHandle) ?scroll_geometry.Metrics {
        if (!self.ready or self.native_work or self.frame_state.needsLayout()) return null;
        const root = (self.instances.rootRenderObject() catch return null) orelse return null;
        if (self.tree.layoutDirty(root) catch return null) return null;
        const render = self.instances.renderObject(target) catch return null;
        return self.tree.scrollMetrics(render) catch null;
    }

    pub fn hasPendingScrollEvents(self: *WindowRuntime) bool {
        self.pointer_bindings.pruneScrollStates(&self.instances);
        for (self.pointer_bindings.entries[0..self.pointer_bindings.entry_limit]) |entry| {
            const handler = entry.handler orelse continue;
            if (handler.kind != .scroll_change) continue;
            const metrics = self.observedScrollMetrics(entry.target) orelse continue;
            const observed = self.pointer_bindings.scrollObservation(entry.target).*;
            if (observed == null or !std.meta.eql(observed.?, metrics)) return true;
        }
        return false;
    }

    fn publishScrollEvents(self: *WindowRuntime, callback_service: anytype) !void {
        self.pointer_bindings.pruneScrollStates(&self.instances);
        for (self.pointer_bindings.entries[0..self.pointer_bindings.entry_limit]) |*entry| {
            const handler = entry.handler orelse continue;
            if (handler.kind != .scroll_change) continue;
            const metrics = self.observedScrollMetrics(entry.target) orelse continue;
            const observed = self.pointer_bindings.scrollObservation(entry.target);
            if (observed.* != null and std.meta.eql(observed.*.?, metrics)) continue;
            try self.spawnCallback(callback_service, handler.id, try self.instances.scope(entry.target), &.{.{ .scroll = metrics }});
            observed.* = metrics;
        }
    }

    fn dispatchScrollbar(self: *WindowRuntime, target: ui.instance.InstanceHandle, event: ui.input.Event) !bool {
        if (event != .pointer) return false;
        const pointer = event.pointer;
        const render = try self.instances.renderObject(target);
        const object = try self.tree.objectAt(render);
        if (object != .scroll or object.scroll.scrollbar == null) return false;
        const size = try self.tree.nodeSize(render);
        const local = (try self.tree.paintTransform(render)).inversePoint(pointer.position);
        const metrics = try self.tree.scrollMetrics(render);
        const thumb = scroll_geometry.thumb(metrics);
        const coordinate = axisCoordinate(object.scroll.axis, local);
        if (pointer.event == .button and pointer.event.button.button == 0x110 and pointer.event.button.state == .pressed) {
            if (!scroll_geometry.track(object.scroll, size).contains(local)) return false;
            if (self.instances.isFocusable(target)) {
                const previous = self.focus.current();
                _ = try self.focus.request(&self.instances, target);
                try self.applyFocusVisual(previous, self.focus.current());
            }
            if (coordinate >= thumb.start and coordinate < thumb.start + thumb.length) {
                self.scrollbar_drag = .{ .target = target, .grab_offset = coordinate - thumb.start };
            } else {
                const delta = if (coordinate < thumb.start) -metrics.viewport else metrics.viewport;
                if (try self.instances.scrollBy(target, delta))
                    if (self.virtual_lists.find(try self.instances.semanticId(target)) != null) try self.queueNativeBuild();
            }
            return true;
        }
        const drag = self.scrollbar_drag orelse return false;
        if (!sameHandle(drag.target, target) or pointer.event != .motion) return false;
        const travel = metrics.viewport - thumb.length;
        const offset = if (travel > 0) std.math.clamp((coordinate - drag.grab_offset) / travel, 0, 1) * metrics.max_offset else 0;
        if (try self.instances.scrollBy(target, offset - metrics.offset))
            if (self.virtual_lists.find(try self.instances.semanticId(target)) != null) try self.queueNativeBuild();
        return true;
    }

    fn containsTarget(self: *WindowRuntime, ancestor: ui.instance.InstanceHandle, descendant: ?ui.instance.InstanceHandle) !bool {
        var current = descendant;
        while (current) |target| {
            if (!self.instances.isActive(target)) return false;
            if (sameHandle(target, ancestor)) return true;
            current = try self.instances.parentOf(target);
        }
        return false;
    }

    fn cancelInternalDrag(self: *WindowRuntime) void {
        if (self.drag_session != null) self.frame_state.invalidatePaint();
        self.drag_session = null;
    }

    fn armInternalDrag(self: *WindowRuntime, hit: ui.instance.InstanceHandle, position: core.PointF) !void {
        self.cancelInternalDrag();
        var current: ?ui.instance.InstanceHandle = hit;
        while (current) |target| {
            if (self.text_inputs.contains(target)) return;
            if ((try self.instances.dragOptions(target)).source) |payload| {
                self.drag_session = .{ .source = target, .payload = payload, .start = position, .position = position };
                return;
            }
            // A nested control owns its gesture, rather than dragging its card.
            if (self.instances.isFocusable(target) or self.buttons.contains(target) or self.pointer_bindings.get(target) != null) return;
            if (self.focus.boundary) |boundary| if (sameHandle(boundary, target)) return;
            current = try self.instances.parentOf(target);
        }
    }

    fn internalDropTarget(self: *WindowRuntime, drag: internal_drag.Session) !?ui.instance.InstanceHandle {
        const root = (try self.instances.rootRenderObject()) orelse return null;
        const render = (try self.tree.hitTest(root, drag.position)) orelse return null;
        var current = self.instances.instanceForRenderObject(render);
        if (current) |hit| if (!self.instances.isInteractive(hit)) return null;
        if (try self.containsTarget(drag.source, current)) return null;
        if (self.focus.boundary) |boundary| if (!try self.containsTarget(boundary, current)) return null;
        while (current) |target| {
            if ((try self.instances.dragOptions(target)).accept) |kind| {
                if (internal_drag.Name.eql(kind, drag.payload.kind) and self.pointer_bindings.getKind(target, .drop_internal) != null)
                    return target;
            }
            if (self.focus.boundary) |boundary| if (sameHandle(boundary, target)) break;
            current = try self.instances.parentOf(target);
        }
        return null;
    }

    fn reconcileInternalDrag(self: *WindowRuntime) !void {
        const drag = self.drag_session orelse return;
        if (!self.instances.isInteractive(drag.source) or
            !std.meta.eql((try self.instances.dragOptions(drag.source)).source, @as(?internal_drag.Payload, drag.payload)))
        {
            self.cancelInternalDrag();
            return;
        }
        if (self.focus.boundary) |boundary| if (!try self.containsTarget(boundary, drag.source)) {
            self.cancelInternalDrag();
            return;
        };
        if (drag.active) {
            const target = try self.internalDropTarget(drag);
            if (!std.meta.eql(target, drag.target)) self.frame_state.invalidatePaint();
            self.drag_session.?.target = target;
        }
    }

    fn dispatchInternalDrag(self: *WindowRuntime, event: ui.input.Event, callbacks: anytype) !bool {
        if (event != .pointer or self.drag_session == null) return false;
        try self.reconcileInternalDrag();
        if (self.drag_session == null) return false;
        const pointer = event.pointer;
        if (pointer.event == .motion) {
            self.drag_session.?.move(pointer.position);
            if (!self.drag_session.?.active) return false;
            self.drag_session.?.target = try self.internalDropTarget(self.drag_session.?);
            self.frame_state.invalidatePaint();
            try self.applyButtonUpdate(self.buttons.release());
            self.range_drag = null;
            self.split_drag = null;
            return true;
        }
        if (pointer.event == .button and pointer.event.button.button == 0x110 and pointer.event.button.state == .released) {
            var drag = self.drag_session.?;
            drag.position = pointer.position;
            self.cancelInternalDrag();
            if (!drag.active) return false;
            try self.applyButtonUpdate(self.buttons.release());
            self.range_drag = null;
            self.split_drag = null;
            if (try self.internalDropTarget(drag)) |target| {
                const binding = self.pointer_bindings.getKind(target, .drop_internal).?;
                const local = (try self.tree.paintTransform(try self.instances.renderObject(target))).inversePoint(drag.position);
                try self.spawnCallback(callbacks, binding.id, try self.instances.scope(target), &.{
                    .{ .string = drag.payload.value.slice() }, .{ .number = local.x }, .{ .number = local.y },
                });
            }
            return true;
        }
        return false;
    }

    fn applyFocusRequests(self: *WindowRuntime) !void {
        const previous = self.focus.current();
        while (self.instances.takeFocusRequest()) |target|
            _ = try self.focus.request(&self.instances, target);
        if (!std.meta.eql(previous, self.focus.current()))
            try self.applyFocusVisual(previous, self.focus.current());
    }

    fn syncDialogFocus(self: *WindowRuntime) !void {
        const captured = self.router.captured;
        self.router.reconcile();
        if (self.router.captured == null) self.scrollbar_drag = null;
        if (captured != null and self.router.captured == null)
            try self.applyButtonUpdate(self.buttons.release());
        for (&self.scroll_motions) |*motion| if (motion.active and !self.instances.isInteractive(motion.target.?)) {
            motion.* = .{};
        };
        var boundary: ?ui.instance.InstanceHandle = null;
        for (0..self.semantics.count()) |index| {
            const node = try self.semantics.node(index);
            if (node.role == .dialog) {
                if (self.instances.handleForId(node.id)) |candidate| {
                    if (self.instances.isInteractive(candidate)) boundary = candidate;
                }
            }
        }
        const previous = self.focus.current();
        const changed = try self.focus.setBoundary(&self.instances, boundary);
        self.focus.reconcile(&self.instances);
        if (self.range_drag) |target| {
            const semantic = if (self.instances.isActive(target))
                self.semantics.findId(try self.instances.semanticId(target))
            else
                null;
            if (semantic == null or semantic.?.range == null or !semantic.?.enabled or !self.instances.isInteractive(target)) self.range_drag = null;
        }
        if (self.split_drag) |drag| {
            if (!self.instances.isInteractive(drag.target) or
                self.pointer_bindings.getKind(drag.target, .split_change) == null)
                self.split_drag = null;
        }
        if (changed) {
            self.pending_shortcut = null;
            self.cancelInternalDrag();
            self.range_drag = null;
            self.split_drag = null;
            self.scrollbar_drag = null;
            try self.applyButtonUpdate(self.buttons.release());
        }
        try self.applyFocusVisual(previous, self.focus.current());
    }

    fn activateSelection(self: *WindowRuntime, callbacks: anytype, target: ui.instance.InstanceHandle, value: i64) !void {
        const binding = self.pointer_bindings.getKind(target, .selection_activate) orelse return;
        try self.spawnCallback(callbacks, binding.id, try self.instances.scope(target), &.{.{ .integer = value }});
    }

    fn syncInteractions(self: *WindowRuntime, callback_service: anytype) !void {
        const observing = for (self.pointer_bindings.entries[0..self.pointer_bindings.entry_limit]) |entry| {
            if (entry.handler != null and entry.handler.?.kind == .interaction_change) break true;
        } else false;
        if (!observing) return;
        // Hit-test current geometry, rather than a leaf which may have been
        // removed by the preceding build. Descendant transitions stay active.
        var hovered: ?ui.instance.InstanceHandle = null;
        if (self.router.pointer_inside) {
            if (try self.instances.rootRenderObject()) |root| {
                const hit = self.tree.hitTest(root, self.router.pointer_position) catch |err| switch (err) {
                    // Input can invalidate layout. Publish after layout has
                    // caught up, not from obsolete bounds.
                    error.LayoutRequired => return,
                    else => return err,
                };
                if (hit) |render|
                    hovered = self.instances.instanceForRenderObject(render);
            }
        }
        const focused = if (self.keyboard_focused) self.focus.current() else null;
        for (self.pointer_bindings.entries[0..self.pointer_bindings.entry_limit]) |entry| {
            const handler = entry.handler orelse continue;
            if (handler.kind != .interaction_change or !self.instances.isInteractive(entry.target)) continue;
            const active = try self.containsTarget(entry.target, hovered) or try self.containsTarget(entry.target, focused) or
                try self.containsTarget(entry.target, self.popup_target);
            if (self.pointer_bindings.interactionChanged(&self.instances, entry.target, active)) {
                if (active) {
                    const rectangle: ?core.RectI = self.anchorRectangle(entry.target) catch |err| switch (err) {
                        error.LayoutRequired, error.PopupAnchorNotVisible => null,
                        else => return err,
                    };
                    if (rectangle) |bounds| try self.spawnCallback(callback_service, handler.id, try self.instances.scope(entry.target), &.{
                        .{ .boolean = true },
                        .{ .popup_anchor = .{ .window = self.window, .target = entry.target, .rectangle = bounds } },
                    }) else try self.spawnCallback(callback_service, handler.id, try self.instances.scope(entry.target), &.{.{ .boolean = true }});
                } else try self.spawnCallback(callback_service, handler.id, try self.instances.scope(entry.target), &.{.{ .boolean = false }});
            }
        }
    }

    fn keyboardTarget(self: *WindowRuntime) !?ui.instance.InstanceHandle {
        if (self.focus.current()) |target| {
            if (!self.instances.isInteractive(target)) return null;
            if (self.focus.boundary) |boundary| if (!try self.containsTarget(boundary, target)) return null;
            return target;
        }
        if (self.focus.boundary) |boundary| return boundary;
        var root = (try self.instances.rootRenderObject()) orelse return null;
        // Skip single-child structural wrappers, including the window's
        // padding/stack, without arbitrarily selecting an unfocused branch.
        while (self.tree.firstChild(root)) |child| {
            if (self.tree.nextSibling(child) != null) break;
            const target = self.instances.instanceForRenderObject(child) orelse break;
            if (!self.instances.isInteractive(target)) break;
            root = child;
        }
        return self.instances.instanceForRenderObject(root);
    }

    fn inputParent(self: *WindowRuntime, target: ui.instance.InstanceHandle) !?ui.instance.InstanceHandle {
        if (self.focus.boundary) |boundary| if (sameHandle(target, boundary)) return null;
        return self.instances.parentOf(target);
    }

    fn captureInput(self: *WindowRuntime, target: ui.instance.InstanceHandle, event: listener.Event, callbacks: anytype) anyerror!bool {
        if (try self.inputParent(target)) |parent|
            if (try self.captureInput(parent, event, callbacks)) return true;
        return self.invokeListener(target, event, if (event.kind == .key) .key_capture else .pointer_capture, callbacks);
    }

    fn invokeListener(self: *WindowRuntime, target: ui.instance.InstanceHandle, event: listener.Event, kind: ui.input.HandlerKind, callbacks: anytype) !bool {
        if (!self.instances.isInteractive(target)) return false;
        const handler = self.pointer_bindings.getKind(target, kind) orelse return false;
        if (!handler.filter.matches(event)) return false;
        try self.spawnCallback(callbacks, handler.id, try self.instances.scope(target), &.{.{ .input = event }});
        return !handler.propagate;
    }

    // Outside listeners are composition policy, not an overlay lifetime rule.
    // Reverse logical order gives nested/later scopes the first opportunity to
    // consume a press. Descendants, including floated descendants, are inside.
    fn dispatchOutsidePointer(self: *WindowRuntime, render: ui.render_object.NodeHandle, hit: ui.instance.InstanceHandle, event: listener.Event, callbacks: anytype) anyerror!bool {
        if (!try self.tree.isInteractive(render)) return false;
        var child = self.tree.lastChild(render);
        while (child) |node| : (child = self.tree.previousSibling(node)) {
            if (try self.dispatchOutsidePointer(node, hit, event, callbacks)) return true;
        }
        const target = self.instances.instanceForRenderObject(render) orelse return false;
        if (self.focus.boundary) |boundary| if (!try self.containsTarget(boundary, target)) return false;
        if (try self.containsTarget(target, hit)) return false;
        return self.invokeListener(target, event, .pointer_down_outside, callbacks);
    }

    /// Routing decisions are entirely native. Lua runs later, in scheduler
    /// order, and cannot retroactively veto a default by returning or yielding.
    fn dispatchListeners(self: *WindowRuntime, target: ui.instance.InstanceHandle, event: listener.Event, callbacks: anytype) !bool {
        var input = event;
        input.phase = .capture;
        if (try self.captureInput(target, input, callbacks)) {
            if (event.kind == .key and event.state == .pressed) self.pending_shortcut = null;
            return true;
        }
        if (event.kind == .key and try self.dispatchShortcut(target, event, callbacks)) return true;
        input.phase = .bubble;
        var current: ?ui.instance.InstanceHandle = target;
        while (current) |candidate| {
            if (try self.invokeListener(candidate, input, if (event.kind == .key) .key_bubble else .pointer_bubble, callbacks)) return true;
            current = try self.inputParent(candidate);
        }
        return false;
    }

    fn validatePendingShortcut(self: *WindowRuntime) void {
        const pending = self.pending_shortcut orelse return;
        if (pending.deadline_ns <= self.input_now_ns or pending.revision != self.pointer_bindings.revision or
            pending.focus_revision != self.focus.revision or
            !self.instances.isInteractive(pending.target))
            self.pending_shortcut = null;
    }

    fn dispatchShortcut(self: *WindowRuntime, target: ui.instance.InstanceHandle, event: listener.Event, callbacks: anytype) !bool {
        self.validatePendingShortcut();
        if (event.state != .pressed) return event.state == .repeated and self.pending_shortcut != null;
        var prefix: KeySequence = .{};
        var current: ?ui.instance.InstanceHandle = target;
        if (self.pending_shortcut) |pending| {
            self.pending_shortcut = null;
            if (event.key.logical == .escape) return true;
            prefix = pending.prefix;
            prefix.strokes[prefix.len] = .{ .key = event.key.logical, .modifiers = event.key.modifiers };
            prefix.len += 1;
            if (try self.matchShortcut(pending.target, prefix, callbacks)) return true;
            // Prefixes are consumed, never replayed. A mismatch gets one new
            // lookup from the current focus before ordinary input fallback.
        }
        prefix = .{};
        prefix.strokes[0] = .{ .key = event.key.logical, .modifiers = event.key.modifiers };
        prefix.len = 1;
        while (current) |candidate| {
            if (try self.matchShortcut(candidate, prefix, callbacks)) return true;
            current = try self.inputParent(candidate);
        }
        return false;
    }

    fn matchShortcut(self: *WindowRuntime, target: ui.instance.InstanceHandle, prefix: KeySequence, callbacks: anytype) !bool {
        for (self.pointer_bindings.entries[0..self.pointer_bindings.entry_limit]) |entry| {
            const handler = entry.handler orelse continue;
            if (handler.kind != .shortcut or !sameHandle(entry.target, target) or
                handler.sequence.len < prefix.len or !prefix.overlaps(handler.sequence)) continue;
            if (handler.sequence.len == prefix.len) {
                try self.spawnCallback(callbacks, handler.id, try self.instances.scope(target), &.{});
            } else {
                self.pending_shortcut = .{
                    .target = target,
                    .focus_revision = self.focus.revision,
                    .revision = self.pointer_bindings.revision,
                    .prefix = prefix,
                    .deadline_ns = self.input_now_ns +| std.time.ns_per_s,
                };
            }
            return true;
        }
        return false;
    }

    fn dispatchKeyboard(self: *WindowRuntime, event: platform.KeyboardEvent, callback_service: anytype) !void {
        const key = switch (event) {
            .enter => {
                self.keyboard_focused = true;
                self.resetCaretBlink();
                try self.syncTextInputVisuals();
                return;
            },
            .leave => {
                self.pending_shortcut = null;
                self.keyboard_focused = false;
                self.cancelInternalDrag();
                self.range_drag = null;
                self.split_drag = null;
                self.resetCaretBlink();
                try self.applyButtonUpdate(self.buttons.release());
                self.clicks.reset();
                if (self.focus.current()) |target| if (self.text_inputs.contains(target)) {
                    const session = try self.text_inputs.session(target);
                    session.model.breakUndoGroup();
                    session.endSelectionDrag();
                };
                try self.syncTextInputVisuals();
                return;
            },
            .key => |value| value,
        };
        if (self.drag_session != null and key.state == .pressed and key.translated.logical == .escape) {
            self.cancelInternalDrag();
            try self.applyButtonUpdate(self.buttons.release());
            return;
        }
        // Secret editors and composition own the entire raw key stream,
        // including releases and Tab. Generic Lua never sees those keys.
        const private_keys = if (self.focus.current()) |focused| blk: {
            if (!self.text_inputs.contains(focused)) break :blk false;
            const session = try self.text_inputs.session(focused);
            break :blk session.model.isSecret() or session.preedit() != null;
        } else false;
        const was_private = self.private_keys_down.contains(key.translated.logical);
        if (key.state == .pressed) {
            self.private_keys_down.setPresent(key.translated.logical, private_keys);
        } else if (key.state == .released) {
            self.private_keys_down.remove(key.translated.logical);
        }
        // Focus or IME state can change between a private press and its
        // release. Do not disclose the tail of that stream to a new target.
        if (!private_keys and was_private and key.state != .pressed) {
            if (key.state == .released and key.translated.logical == .space)
                try self.applyButtonUpdate(self.buttons.release());
            return;
        }
        if (private_keys) {
            self.pending_shortcut = null;
        } else if (try self.keyboardTarget()) |target| {
            if (key.state == .released and key.translated.logical == .space)
                try self.applyButtonUpdate(self.buttons.release());
            const input: listener.Event = .{
                .kind = .key,
                .key = .{ .keycode = 0, .logical = key.translated.logical, .modifiers = key.translated.modifiers },
                .state = switch (key.state) {
                    .pressed => .pressed,
                    .released => .released,
                    .repeated => .repeated,
                },
            };
            if (try self.dispatchListeners(target, input, callback_service)) return;
        }
        if (key.state != .released) {
            self.clicks.reset();
            self.resetCaretBlink();
            switch (key.translated.logical) {
                .tab,
                .arrow_left,
                .arrow_right,
                .arrow_up,
                .arrow_down,
                .home,
                .end,
                .page_up,
                .page_down,
                .space,
                .enter,
                => if (!self.keyboard_focus_visible) {
                    self.keyboard_focus_visible = true;
                    try self.applyFocusVisual(self.focus.current(), self.focus.current());
                },
                else => {},
            }
            try self.syncTextInputVisuals();
        }
        if (self.focus.current()) |focused| if (self.text_inputs.contains(focused) and
            key.state != .released)
        {
            const session = try self.text_inputs.session(focused);
            const behavior = try self.text_inputs.getBehavior(focused);
            const masked = session.model.isSecret();
            // Ctrl+U clears a masked field, as terminals and screen lockers do.
            if (masked and key.translated.logical == .key_u and key.translated.modifiers.control and
                !key.translated.modifiers.shift and !key.translated.modifiers.alt and !key.translated.modifiers.logo)
            {
                if (key.state == .pressed and behavior.enabled and !behavior.read_only) {
                    session.endSelectionDrag();
                    _ = session.model.selectAll();
                    if (try session.model.replaceSelection("")) {
                        try self.syncTextInputVisuals();
                        try self.notifyTextInputChanged(callback_service, focused);
                    }
                }
                return;
            }
            if (behavior.key_bindings.resolve(key.translated)) |resolved| {
                const action = if (masked) maskedKeyAction(resolved, behavior) else resolved;
                // Composition and explicit field commands own Escape first.
                // Otherwise a plain field lets its enclosing dialog cancel.
                const bubble_cancel = action == .command and action.command == .cancel and
                    session.preedit() == null and self.pointer_bindings.getKind(focused, .text_input_command) == null;
                if (!bubble_cancel) {
                    if (key.state == .pressed or action.repeats())
                        try self.applyTextInputAction(focused, action, key.serial, callback_service);
                    return;
                }
            }
            const translated = key.translated;
            // A wl_keyboard key reaching the client was not consumed by the
            // input method. Advertising text-input-v3 alone does not own text
            // entry; ordinary typing must also work without an active IME.
            if (behavior.enabled and !behavior.read_only and
                session.preedit() == null and !translated.modifiers.control and
                !translated.modifiers.alt and !translated.modifiers.logo and
                translated.unicode >= 0x20 and translated.unicode <= 0x10ffff and
                !(translated.unicode >= 0x7f and translated.unicode <= 0x9f))
            {
                var bytes: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(translated.unicode), &bytes) catch return;
                session.endSelectionDrag();
                const typed = session.typeText(bytes[0..len]) catch |err| switch (err) {
                    // A full masked field ignores further keys.
                    error.SecretTooLong => false,
                    else => return err,
                };
                if (typed) {
                    try self.syncTextInputVisuals();
                    try self.notifyTextInputChanged(callback_service, focused);
                }
                return;
            }
        };
        if (key.translated.logical == .escape and key.state == .pressed) {
            var current = self.focus.current() orelse self.focus.boundary;
            while (current) |target| {
                if (self.pointer_bindings.getKind(target, .cancel)) |handler| {
                    const previous = self.focus.current();
                    _ = try self.focus.request(&self.instances, target);
                    try self.applyFocusVisual(previous, self.focus.current());
                    try self.spawnCallback(callback_service, handler.id, try self.instances.scope(target), &.{});
                    return;
                }
                if (self.focus.boundary) |boundary| if (sameHandle(target, boundary)) break;
                current = try self.instances.parentOf(target);
            }
        }
        if (key.translated.logical == .tab and key.state != .released) {
            try self.applyButtonUpdate(self.buttons.release());
            const previous = self.focus.current();
            _ = try self.focus.advance(
                &self.instances,
                if (key.translated.modifiers.shift) .backward else .forward,
            );
            try self.applyFocusVisual(previous, self.focus.current());
            if (self.focus.current()) |focused| try self.ensureOptionVisible(focused);
            return;
        }
        if (key.state != .released) if (self.focus.current()) |focused| {
            if (self.pointer_bindings.getKind(focused, .split_change)) |binding| {
                const parent = (try self.instances.parentOf(focused)) orelse return;
                const render = try self.instances.renderObject(parent);
                const object = try self.tree.objectAt(render);
                if (object != .split) return;
                const size = try self.tree.nodeSize(render);
                const extent = if (object.split.axis == .horizontal) size.width else size.height;
                const resolution = @import("../ui/render_object/split.zig").resolve(object.split, extent);
                const delta: ?f32 = switch (key.translated.logical) {
                    .arrow_left => if (object.split.axis == .horizontal) -10 else null,
                    .arrow_right => if (object.split.axis == .horizontal) 10 else null,
                    .arrow_up => if (object.split.axis == .vertical) -10 else null,
                    .arrow_down => if (object.split.axis == .vertical) 10 else null,
                    .home => resolution.min - resolution.first,
                    .end => resolution.max - resolution.first,
                    else => null,
                };
                if (delta) |amount| {
                    const first = std.math.clamp(resolution.first + amount, resolution.min, resolution.max);
                    const fraction = if (resolution.available == 0) @as(f32, 0) else first / resolution.available;
                    if (fraction != object.split.position)
                        try self.spawnCallback(callback_service, binding.id, try self.instances.scope(focused), &.{.{ .number = fraction }});
                    return;
                }
            }
            if (self.pointer_bindings.getKind(focused, .range_change)) |binding| {
                const semantic = self.semantics.findId(try self.instances.semanticId(focused)).?;
                if (!semantic.enabled) return;
                const range = semantic.range.?;
                const value = switch (key.translated.logical) {
                    .arrow_left, .arrow_down => range.increment(-1),
                    .arrow_right, .arrow_up => range.increment(1),
                    .page_down => range.increment(-10),
                    .page_up => range.increment(10),
                    .home => range.min,
                    .end => range.max,
                    else => return,
                };
                if (value != range.value) try self.spawnCallback(callback_service, binding.id, try self.instances.scope(focused), &.{.{ .number = value }});
                return;
            }
            if (self.listboxes.contains(focused) and (key.translated.logical == .enter or key.translated.logical == .space) and key.state == .pressed) {
                try self.activateSelection(callback_service, focused, self.listboxes.selectedValue(focused).?);
                return;
            }
        };
        if (key.state != .released) if (self.focus.current()) |focused| {
            if (!self.listboxes.contains(focused)) if (try self.instances.nearestScroll(focused, .vertical)) |scroll| {
                if (self.virtual_lists.find(try self.instances.semanticId(scroll))) |list| {
                    const offset = try self.instances.scrollOffset(scroll);
                    const delta: ?f32 = switch (key.translated.logical) {
                        .home => -offset,
                        .end => list.total,
                        .page_up => -list.viewport,
                        .page_down => list.viewport,
                        .arrow_up => -list.estimate,
                        .arrow_down => list.estimate,
                        else => null,
                    };
                    if (delta) |amount| {
                        if (try self.instances.scrollBy(scroll, amount)) {
                            self.frame_state.invalidatePaint();
                            try self.queueNativeBuild();
                        }
                        return;
                    }
                }
            };
        };
        if ((key.translated.logical == .arrow_up or key.translated.logical == .arrow_down or
            key.translated.logical == .arrow_left or key.translated.logical == .arrow_right or
            key.translated.logical == .home or key.translated.logical == .end) and
            key.state != .released)
        {
            const focused = self.focus.current() orelse return;
            if (!self.listboxes.contains(focused)) return;
            const semantic = self.semantics.findId(try self.instances.semanticId(focused)).?;
            const controlled = semantic.role == .radio_group or semantic.role == .tab_list;
            if (!controlled and (key.translated.logical == .arrow_left or key.translated.logical == .arrow_right)) return;
            if (semantic.role == .tab_list and (key.translated.logical == .arrow_up or key.translated.logical == .arrow_down)) return;
            const old = self.listboxes.selectedValue(focused).?;
            var selection = switch (key.translated.logical) {
                .home => self.listboxes.edge(focused, false),
                .end => self.listboxes.edge(focused, true),
                .arrow_up, .arrow_left => self.listboxes.move(focused, -1),
                .arrow_down, .arrow_right => self.listboxes.move(focused, 1),
                else => unreachable,
            } orelse return;
            if (controlled) {
                if (selection.value == old and key.translated.logical != .home and key.translated.logical != .end)
                    selection = self.listboxes.edge(focused, key.translated.logical == .arrow_up or key.translated.logical == .arrow_left).?;
                var restore = selection;
                restore.value = old;
                self.listboxes.select(restore);
            }
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
            .released => try self.applyButtonUpdate(self.buttons.release()),
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
        if (self.activation_input) |*input| {
            input.target = focused;
            input.anchor = self.anchorRectangle(focused) catch |err| switch (err) {
                error.LayoutRequired, error.PopupAnchorNotVisible => null,
                else => return err,
            };
        }
        const binding = self.pointer_bindings.get(focused) orelse return;
        if (binding.kind == .@"switch") {
            const semantic = self.semantics.findId(try self.instances.semanticId(focused)) orelse return;
            if (!semantic.enabled) return;
            // Read only the committed application value. Rejected requests and
            // pending callback tasks must not optimistically flip the control.
            try self.spawnCallback(callback_service, binding.id, try self.instances.scope(focused), &.{.{ .boolean = !semantic.checked }});
            return;
        }
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
        if (!isListBoxActivation(button.button, button.state)) return null;
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
        if (delta != 0 and try self.instances.scrollBy(scroll, delta)) {
            self.frame_state.invalidatePaint();
            if (self.virtual_lists.find(try self.instances.semanticId(scroll)) != null)
                try self.queueNativeBuild();
        }
    }

    fn spawnCallback(
        self: *WindowRuntime,
        callback_service: anytype,
        callback: lua.CallbackHandle,
        scope: task.ScopeHandle,
        arguments: []const lua.TaskArgument,
    ) !void {
        const Service = @typeInfo(@TypeOf(callback_service)).pointer.child;
        if (Service == lua.CallbackRegistry) {
            const spawned = try callback_service.spawnInput(callback, self.callback_scope orelse scope, arguments, self.activation_input);
            try callback_service.setPointerInput(callback, spawned, self.pointer_input);
        } else {
            return error.CallbackServiceUnavailable;
        }
    }

    pub fn restorePopupFocus(self: *WindowRuntime, target: ui.instance.InstanceHandle) !void {
        self.popup_target = null;
        if (!self.ready or !self.instances.isActive(target)) return;
        const previous = self.focus.current();
        _ = try self.focus.request(&self.instances, target);
        try self.applyFocusVisual(previous, self.focus.current());
    }

    pub fn anchorRectangle(self: *WindowRuntime, target: ui.instance.InstanceHandle) !core.RectI {
        const bounds = try self.tree.paintBounds(try self.instances.renderObject(target));
        const viewport = self.frame_state.size orelse return error.WindowNotConfigured;
        const left = @max(0, @floor(bounds.x));
        const top = @max(0, @floor(bounds.y));
        const right = @min(@as(f32, @floatFromInt(viewport.width)), @ceil(bounds.x + bounds.width));
        const bottom = @min(@as(f32, @floatFromInt(viewport.height)), @ceil(bounds.y + bounds.height));
        if (right <= left or bottom <= top) return error.PopupAnchorNotVisible;
        return .{ .x = @intFromFloat(left), .y = @intFromFloat(top), .width = @intFromFloat(right - left), .height = @intFromFloat(bottom - top) };
    }

    fn notifyTextInputChanged(
        self: *WindowRuntime,
        callback_service: anytype,
        target: ui.instance.InstanceHandle,
    ) !void {
        // Authentication text never reaches Lua.
        if ((try self.text_inputs.getBehavior(target)).secret != null) return;
        const binding = self.pointer_bindings.getKind(target, .text_input_change) orelse return;
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
        if (try self.textInputAncestor(target)) |input| {
            const render = try self.instances.renderObject(try self.text_inputs.content(input));
            const axis: ui.render_object.types.Axis = if (axis_event.axis == .vertical) .vertical else .horizontal;
            if (try self.tree.scrollTextInput(render, axis, axis_event.delta / (try self.tree.paintTransform(render)).scale)) {
                self.scroll_motions[@intFromEnum(axis_event.axis)] = .{};
                return true;
            }
        }
        const scroll = try self.scrollBy(target, axis_event.axis, axis_event.delta);
        const motion = &self.scroll_motions[@intFromEnum(axis_event.axis)];
        if (axis_event.source == .finger and scroll != null) {
            motion.sample(scroll.?, axis_event.delta, axis_event.time_ms);
        } else {
            motion.* = .{};
        }
        return scroll != null;
    }

    fn scrollBy(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        pointer_axis: platform.PointerAxis,
        delta: f32,
    ) !?ui.instance.InstanceHandle {
        const axis: ui.render_object.types.Axis = switch (pointer_axis) {
            .vertical => .vertical,
            .horizontal => .horizontal,
        };
        var current: ?ui.instance.InstanceHandle = target;
        while (current) |start| {
            const scroll = (try self.instances.nearestScroll(start, axis)) orelse return null;
            const scale = (try self.tree.paintTransform(try self.instances.renderObject(scroll))).scale;
            if (try self.instances.scrollBy(scroll, delta / scale)) {
                if (self.virtual_lists.find(try self.instances.semanticId(scroll)) != null)
                    try self.queueNativeBuild();
                return scroll;
            }
            current = try self.instances.scrollParent(scroll);
        }
        return null;
    }

    pub fn displayList(self: *WindowRuntime) !scene.DisplayList {
        if (!self.frame_state.readyForSubmission()) return error.FrameNotReady;
        const size = self.frame_state.size.?;
        const commands = self.commands[0..self.command_count];
        return .{
            .commands = commands,
            .damage = try self.damage_tracker.compare(commands, .{
                .x = 0,
                .y = 0,
                .width = @intFromFloat(@ceil(@as(f64, @floatFromInt(size.width)) * self.output_scale)),
                .height = @intFromFloat(@ceil(@as(f64, @floatFromInt(size.height)) * self.output_scale)),
            }),
        };
    }

    /// Resolves a retained semantic key path into the logical center used by
    /// deterministic headless input. Geometry is accumulated through the
    /// actual laid-out instance ancestry, so synthetic events use normal hit
    /// testing rather than addressing widget state directly.
    pub fn semanticTarget(self: *WindowRuntime, path: []const u8) !SemanticTarget {
        if (!self.ready) return error.WindowRuntimeNotReady;
        const semantic = try self.semantics.findPath(path);
        return self.semanticNodeTarget(semantic.id);
    }

    pub fn semanticNodeTarget(self: *WindowRuntime, id: u64) anyerror!SemanticTarget {
        if (!self.ready) return error.WindowRuntimeNotReady;
        const semantic = self.semantics.findId(id) orelse return error.SemanticInstanceMissing;
        const target = self.instances.handleForId(semantic.id) orelse {
            if (semantic.role != .group) return error.SemanticInstanceMissing;
            // A component is a semantic namespace, not an extra layout box.
            // Its one returned root supplies geometry; nil has empty bounds.
            for (0..self.semantics.count()) |index| {
                const child = try self.semantics.node(index);
                if (child.parent == id) {
                    var geometry = try self.semanticNodeTarget(child.id);
                    geometry.role = .group;
                    geometry.enabled = semantic.enabled;
                    geometry.scroll_axis = null;
                    return geometry;
                }
            }
            return .{ .center = .{}, .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .role = .group, .enabled = semantic.enabled, .visible = false, .scroll_axis = null };
        };
        const render = try self.instances.renderObject(target);
        const scroll_axis: ?platform.PointerAxis = if (self.text_inputs.contains(target) and
            (try self.text_inputs.session(target)).model.multiline) .vertical else switch (try self.tree.objectAt(render)) {
            .scroll => |scroll| switch (scroll.axis) {
                .vertical => .vertical,
                .horizontal => .horizontal,
            },
            else => null,
        };
        const bounds = try self.tree.paintBounds(render);
        var center: core.PointF = .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
        if (try self.tree.textRangePoint(render)) |point| {
            center = point;
        } else if (self.listboxes.option(target) != null) {
            // Custom selection content can contain independent controls. Find
            // a point routed to the item, not its close button or text input.
            center = try self.selectionPoint(target, render) orelse center;
        }
        return .{
            .center = center,
            .bounds = bounds,
            .role = semantic.role,
            .enabled = semantic.enabled,
            .visible = self.instances.isVisible(target),
            .scroll_axis = scroll_axis,
        };
    }

    fn selectionPoint(self: *WindowRuntime, target: ui.instance.InstanceHandle, render: ui.render_object.NodeHandle) anyerror!?core.PointF {
        const bounds = try self.tree.paintBounds(render);
        const center: core.PointF = .{ .x = bounds.x + bounds.width / 2, .y = bounds.y + bounds.height / 2 };
        const root = (try self.instances.rootRenderObject()).?;
        if (try self.tree.hitTest(root, center)) |hit| {
            var current = self.instances.instanceForRenderObject(hit);
            while (current) |candidate| {
                if (sameHandle(candidate, target)) return center;
                if (self.pointer_bindings.get(candidate) != null or self.text_inputs.contains(candidate)) break;
                current = try self.instances.parentOf(candidate);
            }
        }
        var child = self.tree.firstChild(render);
        while (child) |node| : (child = self.tree.nextSibling(node)) {
            if (try self.selectionPoint(target, node)) |point| return point;
        }
        return null;
    }

    pub fn frameSubmitted(self: *WindowRuntime) !void {
        _ = try self.displayList();
        try self.frame_state.submitted();
        self.damage_tracker.submitted();
        self.metrics.submitted_frames +|= 1;
    }

    fn notifyDirtyWindow(context: *anyopaque) !void {
        const self: *WindowRuntime = @ptrCast(@alignCast(context));
        if (!self.registered or self.reconciling) return;
        _ = try self.dirty_windows.?.markDirty(self.window);
    }

    fn updateButtonState(self: *WindowRuntime, event: ui.input.Event) !?ui.instance.InstanceHandle {
        switch (event) {
            .hover_enter => |hover| if (try self.buttonAncestor(hover.target)) |button|
                try self.applyButtonUpdate(self.buttons.setHovered(button, true)),
            .hover_leave => |hover| if (try self.buttonAncestor(hover.target)) |button|
                try self.applyButtonUpdate(self.buttons.setHovered(button, false)),
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
            .text_input, .text_input_focus => unreachable,
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
                if (button.button != 0x110) {
                    self.clicks.reset();
                    return;
                }
                const input = (try self.textInputAncestor(target)) orelse {
                    self.clicks.reset();
                    return;
                };
                if (!(try self.text_inputs.getBehavior(input)).enabled) return;
                const session = try self.text_inputs.session(input);
                if (session.preedit() != null) return;
                switch (button.state) {
                    .pressed => {
                        // Resolve the click against what was visible before
                        // focus starts revealing the retained caret.
                        const caret = try self.textCaretAtPointer(input, pointer.position);
                        if (button.modifiers.shift) self.clicks.reset();
                        const count = self.clicks.press(input, pointer.position, button.time_ms);
                        _ = try session.beginPointerSelection(caret.byte_offset, caret.affinity, switch (count) {
                            2 => .word,
                            3 => .line,
                            else => .character,
                        }, button.modifiers.shift);
                        self.resetCaretBlink();
                        self.selection_pointer = pointer.position;
                        self.selection_tick_ns = null;
                        const previous = self.focus.current();
                        _ = try self.focus.request(&self.instances, input);
                        try self.applyFocusVisual(previous, self.focus.current());
                    },
                    .released => {
                        session.endSelectionDrag();
                        self.resetCaretBlink();
                        self.selection_pointer = null;
                        try self.syncTextInputVisuals();
                    },
                }
            },
            .motion => {
                self.clicks.motion(pointer.position);
                const input = (try self.textInputAncestor(target)) orelse return;
                const session = try self.text_inputs.session(input);
                if (!session.isSelecting()) return;
                self.selection_pointer = pointer.position;
                const caret = try self.textCaretAtPointer(input, try self.clampSelectionPointer(input, pointer.position));
                if (try session.updateSelectionDrag(caret.byte_offset, caret.affinity))
                    try self.syncTextInputVisuals();
            },
            else => {},
        }
    }

    fn clampSelectionPointer(self: *WindowRuntime, input: ui.instance.InstanceHandle, position: core.PointF) !core.PointF {
        const content = try self.text_inputs.content(input);
        const bounds = try self.tree.paintBounds(try self.instances.renderObject(content));
        const multiline = (try self.text_inputs.session(input)).model.multiline;
        return .{ .x = std.math.clamp(position.x, bounds.x, bounds.x + bounds.width), .y = if (multiline)
            std.math.clamp(position.y, bounds.y, bounds.y + bounds.height)
        else
            bounds.y + bounds.height / 2 };
    }

    const SelectionScroll = struct { input: ui.instance.InstanceHandle, render: ui.render_object.NodeHandle, axis: ui.render_object.types.Axis, speed: f32 };

    fn selectionScroll(self: *WindowRuntime) !?SelectionScroll {
        if (!self.initialized) return null;
        const position = self.selection_pointer orelse return null;
        const input = self.focus.current() orelse return null;
        if (!self.instances.isActive(input) or !self.text_inputs.contains(input)) return null;
        const session = try self.text_inputs.session(input);
        if (!session.isSelecting() or session.preedit() != null or (session.drag_anchor.?.granularity == .line and !session.model.multiline) or
            !(try self.text_inputs.getBehavior(input)).enabled) return null;
        const edge = try self.clampSelectionPointer(input, position);
        const axis: ui.render_object.types.Axis = if (session.model.multiline and position.y != edge.y) .vertical else .horizontal;
        const distance = if (axis == .vertical) position.y - edge.y else position.x - edge.x;
        if (distance == 0) return null;
        const render = try self.instances.renderObject(try self.text_inputs.content(input));
        const speed = std.math.sign(distance) * std.math.clamp(@abs(distance) * 12, 40, 800) / (try self.tree.paintTransform(render)).scale;
        if (try self.tree.textScrollDelta(render, axis, speed) == 0) return null;
        return .{ .input = input, .render = render, .axis = axis, .speed = speed };
    }

    const CaretActivity = struct {
        target: ui.instance.InstanceHandle,
        model_revision: u64,
        session_revision: u64,
        selection: ui.text_input.Selection,
        selecting: bool,
    };

    fn resetCaretBlink(self: *WindowRuntime) void {
        self.caret_visible = true;
        self.caret_deadline_ns = null;
    }

    // Rebuilds and animation frames must not restart an unchanged caret phase.
    fn refreshCaretActivity(self: *WindowRuntime) !bool {
        var activity: ?CaretActivity = null;
        if (self.focus.current()) |target| if (self.instances.isActive(target) and self.instances.isVisible(target) and self.text_inputs.contains(target)) {
            const session = try self.text_inputs.session(target);
            activity = .{
                .target = target,
                .model_revision = session.model.revision,
                .session_revision = session.revision,
                .selection = session.model.selection,
                .selecting = session.isSelecting(),
            };
        };
        if (std.meta.eql(activity, self.caret_activity)) return false;
        self.caret_activity = activity;
        self.resetCaretBlink();
        return true;
    }

    fn caretShouldBlink(self: *WindowRuntime) !bool {
        if (!self.initialized or !self.keyboard_focused or self.caret_blink_interval_ns == 0) return false;
        const target = self.focus.current() orelse return false;
        if (!self.instances.isActive(target) or !self.instances.isVisible(target) or !self.text_inputs.contains(target)) return false;
        const behavior = try self.text_inputs.getBehavior(target);
        const session = try self.text_inputs.session(target);
        return behavior.enabled and !behavior.read_only and session.preedit() == null and
            !session.isSelecting() and session.model.selection.isCollapsed();
    }

    /// The native host owns one timer for the earliest requested animation.
    pub fn animationDelay(self: *WindowRuntime) !?u64 {
        var delay: ?u64 = if (try self.selectionScroll() != null) 16 * std.time.ns_per_ms else null;
        if (self.animation_frame_pending or self.animations.delay() != null) {
            const next = if (self.animation_deadline_ns) |deadline| deadline -| self.animation_now_ns else 0;
            delay = @min(delay orelse next, next);
        }
        for (self.scroll_motions) |motion| if (motion.active) {
            delay = @min(delay orelse scroll_motion.interval_ns, scroll_motion.interval_ns);
        };
        if (try self.caretShouldBlink()) {
            const caret_delay = if (self.caret_deadline_ns) |deadline| deadline -| self.animation_now_ns else self.caret_blink_interval_ns;
            delay = @min(delay orelse caret_delay, caret_delay);
        }
        return delay;
    }

    pub fn advanceAnimations(self: *WindowRuntime, now_ns: u64) !void {
        if (!self.initialized) return;
        self.animation_now_ns = now_ns;
        // Input and development socket wakeups also enter this method. Sample
        // their time, but publish at frame cadence instead of making every
        // inspect request invalidate its own token before the next request.
        const changed = self.animations.advance(now_ns);
        self.animation_frame_pending = self.animation_frame_pending or changed;
        if (self.animation_deadline_ns == null or now_ns >= self.animation_deadline_ns.?) {
            if (self.animation_frame_pending) try self.queueNativeBuild();
            self.animation_deadline_ns = if (self.animations.delay()) |delay| now_ns +| delay else null;
        }
        for (&self.scroll_motions, 0..) |*motion, index| {
            if (!motion.active) continue;
            if (!self.instances.isActive(motion.target.?)) {
                motion.* = .{};
                continue;
            }
            const delta = motion.advance(now_ns);
            if (delta == 0) continue;
            // Start at the retained container, not a recycled virtual-list row
            // or the current hover target. Preserve ordinary edge chaining.
            if (try self.scrollBy(motion.target.?, @enumFromInt(index), delta)) |target| {
                motion.target = target;
            } else {
                motion.* = .{};
            }
        }
        if (try self.refreshCaretActivity()) try self.syncTextInputVisuals();
        if (try self.caretShouldBlink()) {
            const interval = self.caret_blink_interval_ns;
            const deadline = self.caret_deadline_ns orelse now_ns +| interval;
            self.caret_deadline_ns = deadline;
            if (now_ns >= deadline) {
                const phases = (now_ns - deadline) / interval + 1;
                self.caret_deadline_ns = deadline +| (phases *| interval);
                if (phases % 2 != 0) {
                    self.caret_visible = !self.caret_visible;
                    try self.syncTextInputVisuals();
                }
            }
        } else {
            self.caret_deadline_ns = null;
            if (!self.caret_visible) {
                self.caret_visible = true;
                try self.syncTextInputVisuals();
            }
        }
        const scroll = (try self.selectionScroll()) orelse {
            self.selection_tick_ns = null;
            return;
        };
        const previous = self.selection_tick_ns orelse now_ns;
        self.selection_tick_ns = now_ns;
        const elapsed: f32 = @floatFromInt(@min(now_ns -| previous, 50 * std.time.ns_per_ms));
        if (!try self.tree.scrollTextInput(scroll.render, scroll.axis, scroll.speed * elapsed / std.time.ns_per_s)) return;
        const session = try self.text_inputs.session(scroll.input);
        const caret = try self.textCaretAtPointer(scroll.input, try self.clampSelectionPointer(scroll.input, self.selection_pointer.?));
        _ = try session.updateSelectionDrag(caret.byte_offset, caret.affinity);
        try self.syncTextInputVisuals();
    }

    fn textCaretAtPointer(
        self: *WindowRuntime,
        input: ui.instance.InstanceHandle,
        position: core.PointF,
    ) !text.CaretStop {
        const content = try self.text_inputs.content(input);
        const render = try self.instances.renderObject(content);
        const point = (try self.tree.paintTransform(render)).inversePoint(position);
        var caret = (try self.tree.hitTestText(render, point)).caret;
        // Masked layout holds dots; translate the hit back to the value.
        const model = &(try self.text_inputs.session(input)).model;
        if (model.isSecret()) caret.byte_offset = ui.text_input.maskedToModel(model, caret.byte_offset);
        return caret;
    }

    /// Masked fields never copy their text out or keep undo history, and a
    /// field bound to an authentication prompt does not read the clipboard.
    fn maskedKeyAction(action: ui.text_input.KeyAction, behavior: ui.text_input.Behavior) ui.text_input.KeyAction {
        return switch (action) {
            .clipboard => |command| if (command == .paste and behavior.secret == null) action else .none,
            .edit => |intent| switch (intent) {
                .undo, .redo => .none,
                else => action,
            },
            else => action,
        };
    }

    fn applyTextInputAction(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        action: ui.text_input.KeyAction,
        serial: u32,
        callback_service: anytype,
    ) !void {
        const behavior = try self.text_inputs.getBehavior(target);
        const session = try self.text_inputs.session(target);
        if (!behavior.enabled or session.preedit() != null) return;
        const intent: ui.text_input.EditIntent = switch (action) {
            .none => return,
            .edit => |value| value,
            .command => |command| blk: {
                session.model.breakUndoGroup();
                // Submit sends the text natively; Lua hears only the outcome.
                const name: []const u8 = if (behavior.secret) |secret| switch (command) {
                    .submit => sent: {
                        const accepted = secret.respond(session.model.text());
                        session.model.clearSecret();
                        try self.syncTextInputVisuals();
                        break :sent if (accepted) "submit" else "stale";
                    },
                    .cancel => canceled: {
                        session.model.clearSecret();
                        try self.syncTextInputVisuals();
                        break :canceled "cancel";
                    },
                    else => @tagName(command),
                } else @tagName(command);
                if (self.pointer_bindings.getKind(target, .text_input_command)) |binding| {
                    try self.spawnCallback(callback_service, binding.id, try self.instances.scope(target), &.{.{ .string = name }});
                    return;
                }
                if (behavior.secret != null) return;
                // List-style navigation commands retain caret navigation as
                // their fallback when the application has no command handler.
                break :blk switch (command) {
                    .previous => .{ .move = .{ .destination = .line_up } },
                    .next => .{ .move = .{ .destination = .line_down } },
                    .submit, .cancel => return,
                };
            },
            .clipboard => |command| {
                if (behavior.read_only and command != .copy) return;
                session.endSelectionDrag();
                session.model.breakUndoGroup();
                const clipboard = self.clipboard orelse return;
                if (!clipboard.platformAvailable()) return;
                switch (command) {
                    .copy, .cut => {
                        const selected = session.model.selectedText();
                        if (selected.len == 0) return;
                        try clipboard.setSelection(serial, selected);
                        if (command == .cut) {
                            session.preferred_x = null;
                            if (try session.model.replaceSelection("")) {
                                try self.syncTextInputVisuals();
                                try self.notifyTextInputChanged(callback_service, target);
                            }
                        }
                    },
                    .paste => _ = try clipboard.requestPaste(
                        try self.instances.scope(target),
                        .{ .window = self.window, .text_input = target },
                    ),
                }
                return;
            },
        };
        if (behavior.read_only and intentEditsText(intent)) return;
        if (try self.applyTextInputIntent(target, intent)) {
            try self.syncTextInputVisuals();
            if (intentEditsText(intent)) try self.notifyTextInputChanged(callback_service, target);
        }
        // Navigation also reveals a stationary caret after manual scrolling.
        if (intent == .move) try self.tree.revealTextInputCaret(
            try self.instances.renderObject(try self.text_inputs.content(target)),
        );
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
            .undo, .redo => blk: {
                session.preferred_x = null;
                break :blk if (intent == .undo) session.model.undo() else session.model.redo();
            },
            .insert_newline => blk: {
                session.preferred_x = null;
                break :blk if (session.model.multiline) try session.model.replaceSelection("\n") else false;
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
        if (!behavior.enabled or behavior.read_only or behavior.secret != null) return false;
        const session = try self.text_inputs.session(target);
        session.endSelectionDrag();
        const masked = session.model.isSecret();
        // Password managers often copy a trailing line break.
        const pasted = if (masked) std.mem.trimEnd(u8, bytes, "\r\n") else bytes;
        const changed = session.apply(.{ .commit = .{ .text = pasted } }) catch |err| switch (err) {
            error.SecretTooLong, error.InvalidSecretText => false,
            else => return err,
        };
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
        if (session.model.isSecret()) {
            // Masked text is one left-to-right line of dots; move logically.
            session.preferred_x = null;
            return switch (move.destination) {
                .visual_left => if (!move.extend and !current.isCollapsed())
                    session.model.setSelection(.collapsed(current.range().start))
                else
                    session.model.movePrevious(move.extend),
                .visual_right => if (!move.extend and !current.isCollapsed())
                    session.model.setSelection(.collapsed(current.range().end))
                else
                    session.model.moveNext(move.extend),
                .word_previous, .word_next => unreachable,
                else => session.model.setSelection(if (move.destination == .line_start or
                    move.destination == .document_start or move.destination == .line_up)
                    (if (move.extend) .{ .anchor = current.anchor, .extent = 0 } else .collapsed(0))
                else if (move.extend)
                    .{ .anchor = current.anchor, .extent = session.model.text().len }
                else
                    .collapsed(session.model.text().len)),
            };
        }
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
            .document_start, .document_end => blk: {
                session.preferred_x = null;
                break :blk text.CaretStop{
                    .byte_offset = if (move.destination == .document_start) 0 else session.model.text().len,
                    .x = 0,
                    .affinity = .downstream,
                };
            },
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

    fn applyInteractionPaint(self: *WindowRuntime, target: ui.instance.InstanceHandle, focused: bool) !void {
        const id = try self.instances.semanticId(target);
        const selection = self.listboxes.option(target) != null;
        for (self.instances.occupiedSlots()) |index| {
            const binding = self.instances.paintAt(index) orelse continue;
            if (binding.paint.source != id) continue;
            var object = try self.tree.objectAt(binding.render);
            const previous = object;
            const color = if (selection) self.listboxes.paintColor(target, binding.paint) else self.buttons.paintColor(target, binding.paint);
            switch (object) {
                .box => |*box| box.background = color,
                .text => |*text_object| text_object.color = color.?,
                else => unreachable,
            }
            if (binding.paint.focus) |focus_color| {
                if (object.box.border_width == 0) {
                    object.box.outline_color = if (focused) focus_color else null;
                    object.box.outline_width = if (focused) 2 else 0;
                    object.box.outline_gap = 0;
                    object.box.outline_inset = true;
                } else object.box.border_color = if (focused) focus_color else binding.paint.border;
            }
            if (std.meta.eql(previous, object)) continue;
            try self.tree.update(binding.render, object);
            self.frame_state.invalidatePaint();
        }
    }

    fn applyButtonUpdate(self: *WindowRuntime, update: ?ui.instance.InstanceHandle) !void {
        const target = update orelse return;
        try self.applyInteractionPaint(target, self.keyboard_focus_visible and
            if (self.focus.current()) |focused| sameHandle(focused, target) else false);
    }

    fn refreshListBoxVisuals(self: *WindowRuntime) !void {
        for (0..self.listboxes.optionSlots()) |index| {
            const option = self.listboxes.optionAt(index) orelse continue;
            try self.applyListBoxVisualUpdate(option);
        }
        self.frame_state.invalidatePaint();
    }

    fn applyListBoxVisualUpdate(
        self: *WindowRuntime,
        update: ?ui.instance.InstanceHandle,
    ) !void {
        const option = update orelse return;
        const selection = self.listboxes.option(option).?;
        const focused = self.keyboard_focus_visible and
            (if (self.focus.current()) |focus| sameHandle(focus, selection.listbox) else false) and
            selection.value == self.listboxes.selectedValue(selection.listbox);
        try self.applyInteractionPaint(option, focused);
        try self.setControlBorder(option, self.focus_color, focused);
    }

    /// Exercises candidate layout and scene lowering against isolated native
    /// storage. This closes the transaction boundary before retained instances
    /// change, including command-capacity and descriptor-dependent layout
    /// failures that ordinary reconciliation only encounters during framing.
    const LayoutMeasurement = struct {
        runtime: *WindowRuntime,
        size: core.SizeU,
        lua_ui: *lua.UiBuild,

        fn measure(context: *anyopaque, descriptors: []ui.instance.Descriptor, builders: *layout_builder.Snapshot) !bool {
            const self: *LayoutMeasurement = @ptrCast(@alignCast(context));
            try self.runtime.retainTextInputPresentation(descriptors, self.lua_ui.pending_text_inputs[0..self.lua_ui.pending_text_input_count]);
            _ = try self.runtime.instances.prepareReconcile(descriptors);
            return self.runtime.validatePreparedFrame(descriptors, self.size, self.lua_ui.root_background != null, builders);
        }
    };

    fn validatePreparedFrame(
        self: *WindowRuntime,
        descriptors: []const ui.instance.Descriptor,
        size: core.SizeU,
        transparent_clear: bool,
        builders: ?*layout_builder.Snapshot,
    ) !bool {
        if (descriptors.len == 0) return true;
        var tree: ui.render_object.Tree = undefined;
        try tree.init(self.allocator, descriptors.len);
        defer tree.deinit();
        tree.attachTextCaches(self.paragraph_sources, self.paragraphs);
        if (self.tree.images) |images| tree.attachImageCache(images);
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
        var probe_entries: [128]ui.render_object.Tree.LayoutProbe.Entry = undefined;
        var probe: ui.render_object.Tree.LayoutProbe = .{ .entries = &.{} };
        if (builders) |snapshot| {
            for (snapshot.entries[0..snapshot.count], 0..) |entry, index|
                probe_entries[index] = .{ .handle = handles[descriptorIndexForId(descriptors, entry.id).?], .constraints = entry.constraints };
            probe.entries = probe_entries[0..snapshot.count];
            tree.layout_probe = &probe;
        }
        _ = tree.layout(
            handles[root_index],
            ui.layout.Constraints.tight(.{ .width = width, .height = height }),
        ) catch |err| switch (err) {
            error.LayoutBuilderPending => {
                const request = probe.request.?;
                builders.?.entries[request.index].constraints = request.constraints;
                return false;
            },
            else => return err,
        };
        const commands = try self.allocator.alloc(scene.Command, self.commands.len);
        defer self.allocator.free(commands);
        var builder = try ui.render_object.Builder.init(commands, self.output_scale);
        if (transparent_clear) try builder.clear(core.Color.rgba(0, 0, 0, 0));
        try tree.buildScene(handles[root_index], &builder);
        const count = builder.count;
        for (descriptors, handles) |descriptor, handle| if (descriptor.drag.source != null) {
            builder.count = count;
            try builder.pushClip(.{ .x = 0, .y = 0, .width = width, .height = height });
            try builder.decoratedRectangle(.{ .x = 0, .y = 0, .width = width, .height = height }, null, self.focus_color, 2, 0);
            try builder.decoratedRectangle(.{ .x = 0, .y = 0, .width = width, .height = height }, self.surface_color, self.border_color, 1, 4);
            try builder.pushOpacity(0.75);
            try tree.buildPreview(handle, &builder, .{});
            try builder.popOpacity();
            try builder.popClip();
        };
        return true;
    }

    fn applyFocusVisual(
        self: *WindowRuntime,
        previous: ?ui.instance.InstanceHandle,
        current: ?ui.instance.InstanceHandle,
    ) !void {
        if (!self.initialized) return;
        if (!std.meta.eql(previous, current)) {
            self.pending_shortcut = null;
            if (previous) |target| if (self.text_inputs.contains(target)) {
                const session = try self.text_inputs.session(target);
                session.model.breakUndoGroup();
                session.endSelectionDrag();
            };
            if (current) |target| if (self.text_inputs.contains(target))
                (try self.text_inputs.session(target)).model.breakUndoGroup();
        }
        if (previous) |target| if (self.instances.isActive(target)) try self.setFocusBorder(target, false);
        if (current) |target| if (self.instances.isActive(target)) try self.setFocusBorder(target, true);
        try self.syncTextInputVisuals();
    }

    fn setFocusBorder(self: *WindowRuntime, target: ui.instance.InstanceHandle, requested: bool) !void {
        const focused = requested and (self.keyboard_focus_visible or self.text_inputs.contains(target));
        if (self.buttons.contains(target))
            return self.applyInteractionPaint(target, focused);
        if (self.listboxes.contains(target)) {
            for (0..self.listboxes.optionSlots()) |index| {
                const option = self.listboxes.optionAt(index) orelse continue;
                const selection = self.listboxes.option(option).?;
                if (!sameHandle(selection.listbox, target)) continue;
                try self.applyInteractionPaint(option, focused and selection.value == self.listboxes.selectedValue(target));
                try self.setControlBorder(option, self.focus_color, focused and selection.value == self.listboxes.selectedValue(target));
            }
            return;
        }
        const color = if (self.text_inputs.contains(target)) blk: {
            const behavior = try self.text_inputs.getBehavior(target);
            break :blk if (focused) behavior.focus_color orelse self.focus_color else behavior.border_color orelse self.border_color;
        } else return;
        try self.setControlBorder(target, color, focused);
    }

    fn setControlBorder(
        self: *WindowRuntime,
        target: ui.instance.InstanceHandle,
        color: core.Color,
        focused: bool,
    ) !void {
        const render = try self.instances.renderObject(target);
        var object = try self.tree.objectAt(render);
        if (object != .box) return error.ControlRenderObjectMismatch;
        // A borderless input may live inside application-owned field chrome.
        // Focus recolors an input's existing border; it must not invent one.
        if (self.text_inputs.contains(target) and object.box.border_width == 0) return;
        if (object.box.border_width == 0 or self.listboxes.option(target) != null) {
            const outline: ?core.Color = if (focused) color else null;
            if (std.meta.eql(object.box.outline_color, outline)) return;
            object.box.outline_width = if (focused) 2 else 0;
            object.box.outline_gap = 0;
            object.box.outline_inset = true;
            object.box.outline_color = outline;
        } else {
            if (std.meta.eql(object.box.border_color, color)) return;
            object.box.border_color = color;
        }
        try self.tree.update(render, object);
        self.frame_state.invalidatePaint();
    }

    fn refreshTextInputOwner(self: *WindowRuntime) !bool {
        var owner: @TypeOf(self.text_input_owner) = null;
        if (self.keyboard_focused and self.text_input_surface_focused) {
            if (self.focus.current()) |target| if (self.instances.isActive(target) and self.instances.isVisible(target) and self.text_inputs.contains(target)) {
                const behavior = try self.text_inputs.getBehavior(target);
                // Masked text is never shared with an input method.
                const masked = (try self.text_inputs.session(target)).model.isSecret();
                if (behavior.enabled and !behavior.read_only and !masked) owner = .{
                    .target = target,
                    .session = try self.text_inputs.sessionGeneration(target),
                };
            };
        }
        if (std.meta.eql(owner, self.text_input_owner)) return false;
        if (self.text_input_owner) |previous| if (self.text_inputs.contains(previous.target) and
            previous.session == try self.text_inputs.sessionGeneration(previous.target))
            (try self.text_inputs.session(previous.target)).cancelComposition();
        self.text_input_owner = owner;
        self.text_input_generation +%= 1;
        self.text_input_commit_permitted = true;
        return true;
    }

    fn syncTextInputVisuals(self: *WindowRuntime) !void {
        if (!self.initialized) return;
        _ = try self.refreshTextInputOwner();
        _ = try self.refreshCaretActivity();
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
            object.text_input.reveal_caret = optionalSameHandle(self.focus.current(), mounted.target) and !mounted.session.isSelecting();
            object.text_input.show_caret = presentation.show_caret and object.text_input.reveal_caret and
                self.keyboard_focused and (self.caret_visible or mounted.session.preedit() != null);
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

test "contextual input scopes timeouts privacy and task lifetime" {
    const Fixture = struct {
        scheduler: task.Scheduler = undefined,
        loop: @import("../loop/io_uring.zig").Loop = undefined,
        vm: lua.Vm = undefined,
        callbacks: lua.CallbackRegistry = undefined,
        runtime: WindowRuntime = .{},
        scope: task.ScopeHandle = undefined,
        const owner: ui.instance.BuildOwnerHandle = .{ .slot = 0, .generation = 1 };
        const window: platform.WindowHandle = .{ .slot = 1, .generation = 1 };

        fn init(self: *@This()) !void {
            try self.scheduler.init(std.testing.allocator, 16, 16, 4);
            self.scope = try self.scheduler.createScope(self.scheduler.application_scope);
            try self.loop.init(std.testing.allocator, 8, 4);
            try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
            try self.callbacks.init(std.testing.allocator, 16);
            const r = &self.runtime;
            try r.tree.init(std.testing.allocator, 5);
            try r.instances.init(std.testing.allocator, &self.scheduler, &r.tree, self.scope, 5);
            try r.router.init(std.testing.allocator, &r.tree, &r.instances, window, 16);
            try r.pointer_bindings.init(std.testing.allocator, 16);
            try r.buttons.init(std.testing.allocator, 5);
            try r.text_inputs.init(std.testing.allocator, 2);
            try r.semantics.init(std.testing.allocator, 5, 128);
            try r.instances.reconcile(&.{
                .{ .id = 1, .parent = null, .object = .{ .box = .{} } },
                .{ .id = 2, .parent = 1, .object = .{ .stack = .{} } },
                .{ .id = 3, .parent = 2, .object = .{ .stack = .{} } },
                .{ .id = 4, .parent = 3, .object = .{ .box = .{ .width = 100, .height = 80 } }, .focusable = true },
                .{ .id = 5, .parent = 3, .object = .{ .box = .{ .width = 100, .height = 80 } }, .focusable = true },
            });
            _ = try r.tree.layout((try r.instances.rootRenderObject()).?, ui.layout.Constraints.tight(.{ .width = 100, .height = 80 }));
        }

        fn deinit(self: *@This()) void {
            const r = &self.runtime;
            while (r.pointer_bindings.takeAny()) |handler| self.callbacks.release(handler.id) catch unreachable;
            self.callbacks.deinit();
            self.vm.deinit();
            r.text_inputs.clear();
            r.text_inputs.deinit();
            r.buttons.clear();
            r.buttons.deinit();
            r.semantics.deinit();
            r.pointer_bindings.deinit();
            r.router.deinit();
            r.instances.reconcile(&.{}) catch unreachable;
            self.scheduler.applyQueuedCancellations() catch unreachable;
            r.instances.collectRetired() catch unreachable;
            r.instances.deinit();
            r.tree.deinit();
            self.scheduler.destroyScope(self.scope) catch unreachable;
            self.scheduler.deinit();
            self.loop.deinit();
        }

        fn bind(self: *@This(), id: u64, source: []const u8, value: ui.input.Handler) !void {
            try std.testing.expectEqual(lua_c.ok, lua_c.luaL_loadbufferx(self.vm.state, source.ptr, source.len, "@input-test", "t"));
            try std.testing.expectEqual(lua_c.ok, lua_c.lua_pcallk(self.vm.state, 0, 1, 0, 0, null));
            var handler = value;
            handler.id = try self.callbacks.adoptReference(&self.vm, lua_c.luaL_ref(self.vm.state, lua_c.registry_index));
            if (try self.runtime.pointer_bindings.set(owner, self.runtime.instances.handleForId(id).?, handler)) |old|
                try self.callbacks.release(old.id);
        }

        fn key(self: *@This(), name: []const u8, state: platform.KeyState, now: u64) !void {
            const chord = try ui.input.KeyChord.parse(name);
            try self.runtime.routeKeyboard(.{ .key = .{
                .window = window,
                .serial = 0,
                .time_ms = 0,
                .state = state,
                .translated = .{ .keycode = 0, .logical = chord.key, .modifiers = chord.modifiers },
            } });
            try self.runtime.dispatchInputAt(&self.callbacks, now);
        }

        fn drain(self: *@This()) !void {
            while (self.scheduler.takeRunnable()) |handle| _ = try self.vm.resumeRunnable(handle);
        }

        fn count(self: *@This()) i64 {
            _ = lua_c.lua_getglobal(self.vm.state, "count");
            defer lua_c.lua_settop(self.vm.state, -2);
            var valid: c_int = 0;
            return lua_c.lua_tointegerx(self.vm.state, -1, &valid);
        }
    };
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const r = &f.runtime;
    const leaf = r.instances.handleForId(4).?;
    const other = r.instances.handleForId(5).?;
    const command = "return function() count=(count or 0)+7 end";
    try f.bind(3, command, .{ .id = .invalid, .kind = .shortcut, .sequence = try KeySequence.parse("Ctrl+K Ctrl+C") });
    try f.bind(3, command, .{ .id = .invalid, .kind = .shortcut, .sequence = try KeySequence.parse("Ctrl+S") });
    // No focused control: skip native window wrappers, but not sibling scopes.
    try f.key("Ctrl+S", .pressed, 0);
    try std.testing.expectEqual(@as(i64, 0), f.count());
    try f.drain();
    try std.testing.expectEqual(@as(i64, 7), f.count());
    _ = try r.focus.request(&r.instances, leaf);
    try f.key("Ctrl+K", .pressed, 10);
    try f.key("Ctrl+K", .repeated, 20);
    try f.key("Ctrl+K", .released, 30);
    try f.key("Ctrl+C", .pressed, std.time.ns_per_s + 9);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count());
    try f.key("Ctrl+K", .pressed, 2 * std.time.ns_per_s);
    try f.key("Ctrl+C", .pressed, 3 * std.time.ns_per_s);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count()); // Exact expiry, not one ns later.
    try f.key("Ctrl+K", .pressed, 4 * std.time.ns_per_s);
    _ = try r.focus.request(&r.instances, other);
    try f.key("Ctrl+C", .pressed, 4 * std.time.ns_per_s + 1);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count());
    try f.key("Ctrl+K", .pressed, 5 * std.time.ns_per_s);
    _ = try r.focus.setBoundary(&r.instances, other);
    try f.key("Ctrl+C", .pressed, 5 * std.time.ns_per_s + 1);
    try f.key("Ctrl+S", .pressed, 5 * std.time.ns_per_s + 2);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count()); // No command outside modal.
    _ = try r.focus.setBoundary(&r.instances, null);
    try f.key("Ctrl+K", .pressed, 6 * std.time.ns_per_s);
    try f.bind(3, command, .{ .id = .invalid, .kind = .shortcut, .sequence = try KeySequence.parse("Ctrl+S") });
    try f.key("Ctrl+C", .pressed, 6 * std.time.ns_per_s + 1);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count()); // Binding/reload replacement.
    // Even a focus/modal round trip between input events invalidates a prefix.
    try f.key("Ctrl+K", .pressed, 6 * std.time.ns_per_s + 2);
    _ = try r.focus.request(&r.instances, leaf);
    _ = try r.focus.request(&r.instances, other);
    try f.key("Ctrl+C", .pressed, 6 * std.time.ns_per_s + 3);
    try f.key("Ctrl+K", .pressed, 6 * std.time.ns_per_s + 4);
    _ = try r.focus.setBoundary(&r.instances, other);
    _ = try r.focus.setBoundary(&r.instances, null);
    try f.key("Ctrl+C", .pressed, 6 * std.time.ns_per_s + 5);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count());

    // Consuming only a press leaves motion/release delivery captured at its
    // original target, but does not arm the native button under that target.
    try f.bind(3, "return function(e) assert(e.kind=='press' and e.x==10 and e.y==11 and e.button==272); pointer_trace='press;' end", .{
        .id = .invalid,
        .kind = .pointer_capture,
        .propagate = false,
        .filter = .{ .kinds = std.EnumSet(listener.Kind).initOne(.press), .button = 272 },
    });
    try f.bind(5, "return function(e) assert(e.x==150 and e.y==19); pointer_trace=pointer_trace..e.kind..';' end", .{
        .id = .invalid,
        .kind = .pointer_bubble,
        .filter = .{ .kinds = std.EnumSet(listener.Kind).initMany(&.{ .motion, .release }) },
    });
    r.buttons.set(Fixture.owner, other, true);
    try r.routePointer(.{ .enter = .{ .window = Fixture.window, .serial = 0, .position = .{ .x = 10, .y = 11 } } });
    try r.routePointer(.{ .button = .{ .window = Fixture.window, .serial = 0, .time_ms = 0, .button = 272, .state = .pressed } });
    try r.dispatchInputAt(&f.callbacks, 6 * std.time.ns_per_s + 6);
    try std.testing.expect(r.buttons.armed == null);
    try std.testing.expectEqual(other, r.router.captured.?);
    try f.drain();
    try r.routePointer(.{ .motion = .{ .window = Fixture.window, .time_ms = 1, .position = .{ .x = 150, .y = 19 } } });
    try r.routePointer(.{ .button = .{ .window = Fixture.window, .serial = 0, .time_ms = 2, .button = 272, .state = .released } });
    try r.dispatchInputAt(&f.callbacks, 6 * std.time.ns_per_s + 7);
    try f.drain();
    try std.testing.expect(r.router.captured == null);
    _ = lua_c.lua_getglobal(f.vm.state, "pointer_trace");
    var trace_len: usize = 0;
    const trace = lua_c.lua_tolstring(f.vm.state, -1, &trace_len).?;
    try std.testing.expectEqualStrings("press;motion;release;", trace[0..trace_len]);
    lua_c.lua_settop(f.vm.state, -2);
    // Consuming a release still clears a button armed by a preceding default.
    _ = r.buttons.press(other);
    try f.bind(5, "return function() end", .{ .id = .invalid, .kind = .key_bubble, .propagate = false });
    _ = try r.focus.request(&r.instances, other);
    try f.key("Space", .released, 6 * std.time.ns_per_s + 8);
    try std.testing.expect(r.buttons.armed == null);
    try f.drain();
    r.buttons.clear();

    const observe = "return function(e) assert(e.unicode==nil and e.serial==nil and e.text==nil); count=(count or 0)+1 end";
    try f.bind(3, observe, .{ .id = .invalid, .kind = .key_capture });
    _ = try r.focus.setBoundary(&r.instances, other);
    try f.key("F1", .pressed, 7 * std.time.ns_per_s);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count()); // No capture outside modal.
    _ = try r.focus.setBoundary(&r.instances, null);
    _ = try r.focus.request(&r.instances, leaf);
    var session: ?ui.text_input.Session = try ui.text_input.Session.initSecret(std.testing.allocator);
    try r.text_inputs.mountPrepared(Fixture.owner, leaf, leaf, .uncontrolled, .{}, &session);
    try f.key("Ctrl+S", .pressed, 8 * std.time.ns_per_s);
    try f.key("Ctrl+S", .released, 8 * std.time.ns_per_s + 1);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count());
    try f.key("Ctrl+S", .pressed, 8 * std.time.ns_per_s + 2);
    _ = try r.focus.request(&r.instances, other);
    try f.key("Ctrl+S", .repeated, 8 * std.time.ns_per_s + 3);
    try f.key("Ctrl+S", .released, 8 * std.time.ns_per_s + 4);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count()); // Private release after focus changed.
    _ = try r.focus.request(&r.instances, leaf);
    r.text_inputs.clear();
    try r.text_inputs.mount(Fixture.owner, leaf, leaf, "safe");
    _ = try (try r.text_inputs.session(leaf)).apply(.{ .preedit = .{ .text = "private", .cursor = .{ .start = 0, .end = 7 } } });
    try f.key("Ctrl+S", .pressed, 9 * std.time.ns_per_s);
    try f.key("Ctrl+S", .released, 9 * std.time.ns_per_s + 1);
    try f.drain();
    try std.testing.expectEqual(@as(i64, 14), f.count());
    r.text_inputs.clear();
    // An error is a task failure, not a request to run the stock Tab default.
    try f.bind(4, "return function() error('handler failed') end", .{ .id = .invalid, .kind = .key_bubble, .propagate = false });
    try f.key("Tab", .pressed, 10 * std.time.ns_per_s);
    try std.testing.expectEqual(leaf, r.focus.current().?);
    _ = try f.vm.resumeRunnable(f.scheduler.takeRunnable().?); // outer observer
    try std.testing.expectError(error.LuaRuntimeError, f.vm.resumeRunnable(f.scheduler.takeRunnable().?));
    try std.testing.expectEqual(leaf, r.focus.current().?);
    // Queued callbacks retain scope cancellation, even before their first run.
    try f.key("F1", .pressed, 11 * std.time.ns_per_s);
    try f.scheduler.queueScopeCancellation(try r.instances.scope(leaf));
    try f.scheduler.applyQueuedCancellations();
    _ = try f.vm.resumeRunnable(f.scheduler.takeRunnable().?);
    try std.testing.expectEqual(lua.ResumeResult.canceled, try f.vm.resumeRunnable(f.scheduler.takeRunnable().?));
}

test "transformed range and split pointer drags dispatch local values with capture" {
    for ([_]bool{ false, true }) |split| {
        var scheduler: task.Scheduler = undefined;
        try scheduler.init(std.testing.allocator, 16, 16, 4);
        defer scheduler.deinit();
        const scope = try scheduler.createScope(scheduler.application_scope);
        var loop: @import("../loop/io_uring.zig").Loop = undefined;
        try loop.init(std.testing.allocator, 8, 4);
        defer loop.deinit();
        var vm: lua.Vm = undefined;
        try vm.init(std.testing.allocator, &scheduler, &loop);
        defer vm.deinit();
        var callbacks: lua.CallbackRegistry = undefined;
        try callbacks.init(std.testing.allocator, 1);
        defer callbacks.deinit();
        const source = "return function(value) last=value; calls=(calls or 0)+1 end";
        try std.testing.expectEqual(lua_c.ok, lua_c.luaL_loadbufferx(vm.state, source.ptr, source.len, "@transformed-drag", "t"));
        try std.testing.expectEqual(lua_c.ok, lua_c.lua_pcallk(vm.state, 0, 1, 0, 0, null));
        const callback = try callbacks.adoptReference(&vm, lua_c.luaL_ref(vm.state, lua_c.registry_index));
        defer callbacks.release(callback) catch unreachable;
        const window: platform.WindowHandle = .{ .slot = 1, .generation = 1 };
        var r: WindowRuntime = .{};
        try r.tree.init(std.testing.allocator, 5);
        try r.instances.init(std.testing.allocator, &scheduler, &r.tree, scope, 5);
        try r.router.init(std.testing.allocator, &r.tree, &r.instances, window, 16);
        try r.pointer_bindings.init(std.testing.allocator, 1);
        try r.buttons.init(std.testing.allocator, 5);
        try r.text_inputs.init(std.testing.allocator, 1);
        try r.semantics.init(std.testing.allocator, 1, 32);
        defer {
            r.text_inputs.deinit();
            r.buttons.deinit();
            r.semantics.deinit();
            r.pointer_bindings.deinit();
            r.router.deinit();
            r.instances.reconcile(&.{}) catch unreachable;
            scheduler.applyQueuedCancellations() catch unreachable;
            r.instances.collectRetired() catch unreachable;
            r.instances.deinit();
            r.tree.deinit();
            scheduler.destroyScope(scope) catch unreachable;
        }
        const descriptors = [_]ui.instance.Descriptor{
            .{ .id = 1, .parent = null, .object = .{ .box = .{ .transform = .{ .translation = .{ .x = 30, .y = 3 }, .scale = 0.75, .origin = .{ .x = 8, .y = 4 } } } } },
            .{ .id = 2, .parent = 1, .object = if (split) .{ .split = .{ .position = 0.25, .divider = 8 } } else .{ .box = .{} }, .range_inset = 8 },
            .{ .id = 3, .parent = 2, .object = .{ .box = .{} } },
            .{ .id = 4, .parent = 2, .object = .{ .box = .{} } },
            .{ .id = 5, .parent = 2, .object = .{ .box = .{} } },
        };
        try r.instances.reconcile(descriptors[0..if (split) @as(usize, 5) else 2]);
        r.semantics.stage(&.{.{ .id = 2, .parent = null, .role = .slider, .range = .{ .value = 10, .min = 10, .max = 110, .step = 1 } }});
        r.semantics.commitStaged();
        const target = r.instances.handleForId(if (split) 5 else 2).?;
        _ = try r.pointer_bindings.set(.{ .slot = 0, .generation = 1 }, target, .{ .id = callback, .kind = if (split) .split_change else .range_change });
        const root = (try r.instances.rootRenderObject()).?;
        _ = try r.tree.layout(root, ui.layout.Constraints.tight(.{ .width = 120, .height = 80 }));
        // Map is window=(32,4)+local*0.75. Range endpoints are x=8,112;
        // split divider starts at x=28, grabbed three local pixels from its edge.
        try r.routePointer(.{ .enter = .{ .window = window, .serial = 0, .position = .{ .x = if (split) 55.25 else 57.5, .y = 13 } } });
        try r.routePointer(.{ .button = .{ .window = window, .serial = 0, .time_ms = 0, .button = 272, .state = .pressed } });
        try r.dispatchInput(&callbacks);
        while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);
        try std.testing.expectEqual(target, r.router.captured.?);
        try r.routePointer(.{ .motion = .{ .window = window, .time_ms = 1, .position = .{ .x = if (split) 76.25 else 96.5, .y = 13 } } });
        try r.dispatchInput(&callbacks);
        while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);
        _ = lua_c.lua_getglobal(vm.state, "last");
        var valid: c_int = 0;
        try std.testing.expectEqual(@as(f64, if (split) 0.5 else 85), lua_c.lua_tonumberx(vm.state, -1, &valid));
        try std.testing.expectEqual(@as(c_int, 1), valid);
        lua_c.lua_settop(vm.state, -2);
        _ = lua_c.lua_getglobal(vm.state, "calls");
        try std.testing.expectEqual(@as(i64, if (split) 1 else 2), lua_c.lua_tointegerx(vm.state, -1, &valid));
        try std.testing.expectEqual(@as(c_int, 1), valid);
        lua_c.lua_settop(vm.state, -2);
        try r.routePointer(.{ .button = .{ .window = window, .serial = 0, .time_ms = 2, .button = 272, .state = .released } });
        try r.dispatchInput(&callbacks);
        try std.testing.expect(r.router.captured == null and r.range_drag == null and r.split_drag == null);
        try std.testing.expectEqual(@as(usize, 1), try r.tree.layoutCount(root));
    }
}

test "internal drag dispatches compatible ancestor with transformed local coordinates" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 16, 16, 4);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var loop: @import("../loop/io_uring.zig").Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var vm: lua.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(std.testing.allocator, 1);
    defer callbacks.deinit();
    const source_code = "return function(value,x,y) result_value=value; result_x=x; result_y=y; calls=(calls or 0)+1 end";
    try std.testing.expectEqual(lua_c.ok, lua_c.luaL_loadbufferx(vm.state, source_code.ptr, source_code.len, "@internal-drag", "t"));
    try std.testing.expectEqual(lua_c.ok, lua_c.lua_pcallk(vm.state, 0, 1, 0, 0, null));
    const callback = try callbacks.adoptReference(&vm, lua_c.luaL_ref(vm.state, lua_c.registry_index));
    defer callbacks.release(callback) catch unreachable;

    const window: platform.WindowHandle = .{ .slot = 1, .generation = 1 };
    var r: WindowRuntime = .{};
    try r.tree.init(std.testing.allocator, 6);
    try r.instances.init(std.testing.allocator, &scheduler, &r.tree, scope, 6);
    try r.router.init(std.testing.allocator, &r.tree, &r.instances, window, 16);
    try r.pointer_bindings.init(std.testing.allocator, 1);
    try r.buttons.init(std.testing.allocator, 6);
    try r.text_inputs.init(std.testing.allocator, 1);
    defer {
        r.text_inputs.deinit();
        r.buttons.deinit();
        r.pointer_bindings.deinit();
        r.router.deinit();
        r.instances.reconcile(&.{}) catch unreachable;
        scheduler.applyQueuedCancellations() catch unreachable;
        r.instances.collectRetired() catch unreachable;
        r.instances.deinit();
        r.tree.deinit();
        scheduler.destroyScope(scope) catch unreachable;
    }
    const card = internal_drag.Payload{ .kind = try internal_drag.Name.init("card"), .value = try internal_drag.Name.init("item-42") };
    const descriptors = [_]ui.instance.Descriptor{
        .{ .id = 1, .parent = null, .object = .{ .stack = .{} } },
        .{ .id = 2, .parent = 1, .object = .{ .stack = .{} }, .parent_data = .{ .stack = .{ .x = 10, .y = 10 } }, .drag = .{ .source = card } },
        .{ .id = 3, .parent = 2, .object = .{ .box = .{} } },
        .{ .id = 4, .parent = 1, .object = .{ .box = .{ .width = 60, .height = 50, .transform = .{ .translation = .{ .x = 7, .y = -3 }, .scale = 1.5, .origin = .{ .x = 4, .y = 8 } } } }, .parent_data = .{ .stack = .{ .x = 90, .y = 20 } }, .drag = .{ .accept = try internal_drag.Name.init("card") } },
        .{ .id = 5, .parent = 4, .object = .{ .box = .{} }, .drag = .{ .accept = try internal_drag.Name.init("other") } },
        .{ .id = 6, .parent = 2, .object = .{ .box = .{} }, .focusable = true },
    };
    try r.instances.reconcile(&descriptors);
    const root = (try r.instances.rootRenderObject()).?;
    _ = try r.tree.layout(root, ui.layout.Constraints.tight(.{ .width = 200, .height = 120 }));
    const source = r.instances.handleForId(2).?;
    const source_child = r.instances.handleForId(3).?;
    const target = r.instances.handleForId(4).?;
    const control = r.instances.handleForId(6).?;
    _ = try r.pointer_bindings.set(.{ .slot = 0, .generation = 1 }, target, .{ .id = callback, .kind = .drop_internal });

    try r.armInternalDrag(source_child, .{ .x = 15, .y = 15 });
    const motion = ui.input.Event{ .pointer = .{ .target = target, .hovered = target, .position = .{ .x = 21, .y = 15 }, .event = .{ .motion = .{ .window = window, .time_ms = 1, .position = .{ .x = 21, .y = 15 } } } } };
    try std.testing.expect(try r.dispatchInternalDrag(motion, &callbacks)); // exactly six pixels
    try std.testing.expect(r.drag_session.?.active);
    // A source descendant is never a target.
    try std.testing.expect((try r.internalDropTarget(r.drag_session.?)) == null);

    const drop_position: core.PointF = .{ .x = 130, .y = 47 };
    // Target map is (95,13)+local*1.5, independently of the helper under test.
    const release = ui.input.Event{ .pointer = .{ .target = target, .hovered = target, .position = drop_position, .event = .{ .button = .{ .window = window, .serial = 0, .time_ms = 2, .button = 0x110, .state = .released } } } };
    r.drag_session.?.position = drop_position;
    try std.testing.expect(try r.dispatchInternalDrag(release, &callbacks));
    while (scheduler.takeRunnable()) |handle| _ = try vm.resumeRunnable(handle);
    _ = lua_c.lua_getglobal(vm.state, "result_value");
    var result_len: usize = 0;
    const result = lua_c.lua_tolstring(vm.state, -1, &result_len).?;
    try std.testing.expectEqualStrings("item-42", result[0..result_len]);
    lua_c.lua_settop(vm.state, -2);
    var valid: c_int = 0;
    _ = lua_c.lua_getglobal(vm.state, "result_x");
    try std.testing.expectEqual(@as(f64, @as(f32, 70.0 / 3.0)), lua_c.lua_tonumberx(vm.state, -1, &valid));
    try std.testing.expectEqual(@as(c_int, 1), valid);
    lua_c.lua_settop(vm.state, -2);
    _ = lua_c.lua_getglobal(vm.state, "result_y");
    try std.testing.expectEqual(@as(f64, @as(f32, 68.0 / 3.0)), lua_c.lua_tonumberx(vm.state, -1, &valid));
    try std.testing.expectEqual(@as(c_int, 1), valid);
    lua_c.lua_settop(vm.state, -2);

    // Nested controls own presses, and changing/removing the source cancels.
    try r.armInternalDrag(control, .{ .x = 15, .y = 15 });
    try std.testing.expect(r.drag_session == null);
    try r.armInternalDrag(source, .{ .x = 15, .y = 15 });
    r.drag_session.?.move(.{ .x = 400, .y = 300 });
    var outside_release = release;
    outside_release.pointer.position = .{ .x = 400, .y = 300 };
    try std.testing.expect(try r.dispatchInternalDrag(outside_release, &callbacks));
    try std.testing.expect(scheduler.takeRunnable() == null);
    try std.testing.expect(r.drag_session == null);
    try r.armInternalDrag(source, .{ .x = 15, .y = 15 });
    try r.dispatchKeyboard(.{ .key = .{ .window = window, .serial = 0, .time_ms = 3, .state = .pressed, .translated = .{ .keycode = 0, .logical = .escape } } }, &callbacks);
    try std.testing.expect(r.drag_session == null);
    try r.armInternalDrag(source, .{ .x = 15, .y = 15 });
    r.focus.boundary = target;
    try r.reconcileInternalDrag();
    try std.testing.expect(r.drag_session == null);
    r.focus.boundary = null;
    try r.armInternalDrag(source, .{ .x = 15, .y = 15 });
    var changed = descriptors;
    changed[1].drag = .{};
    try r.instances.reconcile(&changed);
    try r.reconcileInternalDrag();
    try std.testing.expect(r.drag_session == null);
    try r.instances.reconcile(&descriptors);
    try r.armInternalDrag(source, .{ .x = 15, .y = 15 });
    try r.instances.reconcile(&.{descriptors[0]});
    try r.reconcileInternalDrag();
    try std.testing.expect(r.drag_session == null);
}

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
    runtime.damage_tracker = try scene.DamageTracker.init(std.testing.allocator, commands.len);
    defer runtime.damage_tracker.deinit();
    try runtime.instances.reconcile(&.{.{
        .id = 1,
        .parent = null,
        .object = .{ .box = .{ .background = core.Color.rgba(1, 2, 3, 255) } },
    }});

    _ = try runtime.frame_state.configure(.{ .width = 100, .height = 80 });
    try runtime.prepareFrame(1);
    try std.testing.expect((try runtime.displayList()).damage == .full);
    try runtime.frameSubmitted();
    const root = (try runtime.instances.rootRenderObject()).?;
    const initial_layout_count = try runtime.tree.layoutCount(root);
    try std.testing.expect(!(try runtime.tree.layoutDirty(root)));

    _ = try runtime.frame_state.configure(.{ .width = 100, .height = 80 });
    try runtime.prepareFrame(1);
    try std.testing.expectEqual(@as(usize, 0), (try runtime.displayList()).damage.regions.len);
    try runtime.frameSubmitted();

    _ = try runtime.frame_state.configure(.{ .width = 120, .height = 80 });
    try std.testing.expect(!(try runtime.tree.layoutDirty(root)));
    try runtime.prepareFrame(1);

    try std.testing.expectEqual(initial_layout_count + 1, try runtime.tree.layoutCount(root));
    try std.testing.expect(runtime.wantsSubmission());
    try std.testing.expect((try runtime.displayList()).damage == .full);
}

test "queued pointer axis applies transformed logical deltas only during input dispatch" {
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    const window: platform.WindowHandle = .{ .slot = 2, .generation = 1 };
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
    try runtime.pointer_bindings.init(std.testing.allocator, 2);
    defer runtime.pointer_bindings.deinit();
    try runtime.text_inputs.init(std.testing.allocator, 2);
    defer runtime.text_inputs.deinit();
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
        .{ .id = 3, .parent = null, .object = .{ .box = .{} } },
        .{ .id = 1, .parent = 3, .object = .{ .scroll = .{} } },
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
    try runtime.tree.update(root, .{ .box = .{ .transform = .{ .translation = .{ .x = 3, .y = 4 }, .scale = 1.5 } } });
    try runtime.routePointer(.{ .axis = .{ .window = window, .time_ms = 3, .axis = .vertical, .delta = 18 } });
    try runtime.dispatchInput(&unused_vm);
    try std.testing.expectEqual(@as(f32, 30), try runtime.instances.scrollOffset(runtime.instances.handleForId(1).?));
    try std.testing.expectEqual(@as(usize, 1), try runtime.tree.layoutCount(root));
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
    try runtime.text_inputs.init(std.testing.allocator, 3);
    try runtime.pointer_bindings.init(std.testing.allocator, 3);
    defer runtime.pointer_bindings.deinit();
    defer {
        runtime.text_inputs.deinit();
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

test "text input protocol batches and transformed pointer selection use retained sessions at the input safe point" {
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
    const placeholder = try sources.acquire(.{
        .utf8 = "Search applications",
        .language = "und",
        .logical_size = 14,
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    defer sources.release(placeholder) catch unreachable;

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
    var commands: [32]scene.Command = undefined;
    runtime.commands = &commands;
    runtime.background = core.Color.rgba(0, 0, 0, 0);
    runtime.damage_tracker = try scene.DamageTracker.init(std.testing.allocator, commands.len);
    defer runtime.damage_tracker.deinit();
    const PaintCheck = struct {
        pixels: [160 * 32 * 4]u8 = @splat(0xaa),
        fn check(self: *@This(), value: *WindowRuntime, font_cache: *text.FontCache, paragraph_cache: *text.ParagraphCache, initial: bool) !void {
            const software = @import("../renderer/software/root.zig");
            if (!software.has_freetype) return;
            try value.prepareFrame(1);
            const list = try value.displayList();
            if (initial) {
                try std.testing.expect(list.damage == .full);
            } else {
                try std.testing.expect(list.damage == .regions and list.damage.regions.len == 1);
                try std.testing.expect(list.damage.regions[0].width < 160);
            }
            var glyphs = try software.GlyphCache.init(std.testing.allocator, font_cache);
            defer glyphs.deinit();
            var destination: software.Target = .{ .pixels = &self.pixels, .width = 160, .height = 32, .stride = 640, .format = .rgba8_unorm };
            try software.renderParagraphs(list, destination, &glyphs, paragraph_cache);
            var expected: [160 * 32 * 4]u8 = undefined;
            destination.pixels = &expected;
            try software.renderParagraphs(.{ .commands = list.commands }, destination, &glyphs, paragraph_cache);
            try std.testing.expectEqualSlices(u8, &expected, &self.pixels);
            try value.frameSubmitted();
        }
    };
    var paint_check: PaintCheck = .{};
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
            .placeholder = placeholder,
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
    _ = try runtime.frame_state.configure(.{ .width = 160, .height = 32 });
    try paint_check.check(&runtime, &fonts, &paragraphs, true);

    var history_key: platform.KeyboardEvent = .{ .key = .{
        .window = window,
        .serial = 20,
        .time_ms = 20,
        .state = .pressed,
        .translated = .{ .keycode = 44, .logical = .key_z, .modifiers = .{ .control = true } },
    } };
    try runtime.routeKeyboard(history_key);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expect(scheduler.takeRunnable() == null);
    try std.testing.expectEqualStrings("hello", (try runtime.text_inputs.session(target)).model.text());

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
    try paint_check.check(&runtime, &fonts, &paragraphs, false);

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
    try paint_check.check(&runtime, &fonts, &paragraphs, false);

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
    try paint_check.check(&runtime, &fonts, &paragraphs, false);

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
    const input_render = try runtime.instances.renderObject(target);
    const untransformed = try runtime.tree.objectAt(input_render);
    var transformed = untransformed;
    transformed.box.transform = .{ .translation = .{ .x = 30, .y = 2 }, .scale = 0.75, .origin = .{ .x = 10, .y = 6 } };
    try runtime.tree.update(input_render, transformed);
    try std.testing.expect(!try runtime.tree.layoutDirty(input_render));
    try std.testing.expectEqual(core.RectI{ .x = 32, .y = 3, .width = 121, .height = 25 }, try runtime.anchorRectangle(target));
    const local_caret = try runtime.tree.textCaretRectangle(render);
    const transformed_status = (try runtime.textInputStatus()).?.state.cursor_rectangle.?;
    try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(32.5 + 0.75 * (1 + local_caret.x)))), transformed_status.x);
    try std.testing.expectEqual(@as(i32, @intFromFloat(@floor(3.5 + 0.75 * (1 + local_caret.y)))), transformed_status.y);
    try std.testing.expectEqual(@as(i32, @intFromFloat(@ceil(0.75 * local_caret.height))), transformed_status.height);
    try runtime.routePointer(.{ .enter = .{
        .window = window,
        .serial = 8,
        .position = .{ .x = 33.25, .y = 11 },
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
        .position = .{ .x = 85, .y = 11 },
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
    try runtime.tree.update(input_render, untransformed);

    const editing = try runtime.text_inputs.session(target);
    _ = editing.model.selectAll();
    var character: platform.KeyboardEvent = .{ .key = .{
        .window = window,
        .serial = 11,
        .time_ms = 12,
        .state = .pressed,
        .translated = .{ .keycode = 30, .unicode = 'Ω' },
    } };
    try runtime.routeKeyboard(character);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings("Ω", editing.model.text());
    character.key.state = .repeated;
    character.key.translated.unicode = 'β';
    try runtime.routeKeyboard(character);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings("Ωβ", editing.model.text());
    inline for (.{ platform.Modifiers{ .control = true }, platform.Modifiers{ .alt = true }, platform.Modifiers{ .logo = true } }) |modifiers| {
        character.key.translated.modifiers = modifiers;
        try runtime.routeKeyboard(character);
        try runtime.dispatchInput(&callbacks);
        try std.testing.expectEqualStrings("Ωβ", editing.model.text());
    }
    character.key.translated.modifiers = .{};
    character.key.state = .released;
    try runtime.routeKeyboard(character);
    try runtime.dispatchInput(&callbacks);
    character.key.state = .pressed;
    for ([_]u32{ 0x1f, 0x7f, 0x9f, 0xd800, 0x110000 }) |codepoint| {
        character.key.translated.unicode = codepoint;
        try runtime.routeKeyboard(character);
        try runtime.dispatchInput(&callbacks);
    }
    try std.testing.expectEqualStrings("Ωβ", editing.model.text());
    _ = try editing.apply(.{ .preedit = .{ .text = "composing", .cursor = null } });
    character.key.translated.unicode = 'x';
    try runtime.routeKeyboard(character);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings("Ωβ", editing.model.text());
    _ = try editing.apply(.{ .preedit = .{ .text = null, .cursor = null } });

    while (scheduler.takeRunnable()) |runnable|
        _ = try callback_vm.resumeRunnable(runnable);
    // Clearing a hinted field emits the empty value, never its display hint.
    _ = editing.model.selectAll();
    try runtime.routeKeyboard(.{ .key = .{
        .window = window,
        .serial = 12,
        .time_ms = 13,
        .state = .pressed,
        .translated = .{ .keycode = 14, .logical = .backspace },
    } });
    try runtime.dispatchInput(&callbacks);
    while (scheduler.takeRunnable()) |runnable|
        _ = try callback_vm.resumeRunnable(runnable);
    try std.testing.expectEqualStrings("", editing.model.text());
    try std.testing.expectEqual(lua_c.type_string, lua_c.lua_getglobal(callback_vm.state, "changed_text"));
    const empty_changed = lua_c.lua_tolstring(callback_vm.state, -1, &changed_length).?;
    try std.testing.expectEqualStrings("", empty_changed[0..changed_length]);
    lua_c.lua_settop(callback_vm.state, -2);
    _ = try runtime.tree.layout((try runtime.instances.rootRenderObject()).?, ui.layout.Constraints.tight(.{ .width = 160, .height = 32 }));
    try std.testing.expectEqualStrings("", (try runtime.textInputStatus()).?.state.surrounding.?.text);
    // Preedit is visible presentation only; it does not dispatch on_change.
    try runtime.routeTextInput(.{ .batch = .{
        .window = window,
        .serial = 13,
        .serial_matches_state = true,
        .delete_surrounding = null,
        .commit = null,
        .preedit = .{ .text = "候", .cursor_begin = 3, .cursor_end = 3 },
    } });
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings("", editing.model.text());
    try std.testing.expect(scheduler.takeRunnable() == null);
    const composing_input = (try runtime.tree.objectAt(render)).text_input;
    try std.testing.expectEqualStrings("候", (try sources.get(composing_input.source)).utf8);
    try std.testing.expect(composing_input.preedit != null);
    try std.testing.expectEqual(placeholder, composing_input.placeholder.?);
    _ = try editing.apply(.{ .preedit = .{ .text = null, .cursor = null } });
    try runtime.syncTextInputVisuals();

    // Paste is normalized before callbacks, and the IME rectangle follows the
    // horizontally scrolled caret rather than its unbounded paragraph X.
    const pasted = "first\r\nsecond with a long editable value ending in Ω";
    const normalized = "first second with a long editable value ending in Ω";
    try std.testing.expect(try runtime.applyClipboardPaste(&callbacks, target, pasted));
    try std.testing.expectEqualStrings(normalized, editing.model.text());
    while (scheduler.takeRunnable()) |runnable|
        _ = try callback_vm.resumeRunnable(runnable);
    try std.testing.expectEqual(lua_c.type_string, lua_c.lua_getglobal(callback_vm.state, "changed_text"));
    const pasted_change = lua_c.lua_tolstring(callback_vm.state, -1, &changed_length).?;
    try std.testing.expectEqualStrings(normalized, pasted_change[0..changed_length]);
    lua_c.lua_settop(callback_vm.state, -2);
    _ = try runtime.tree.layout((try runtime.instances.rootRenderObject()).?, ui.layout.Constraints.tight(.{ .width = 160, .height = 32 }));
    var status = (try runtime.textInputStatus()).?;
    try std.testing.expectEqual(@as(i32, 158), status.state.cursor_rectangle.?.x);
    try std.testing.expectEqualStrings(normalized, status.state.surrounding.?.text);

    var navigation: platform.KeyboardEvent = .{ .key = .{
        .window = window,
        .serial = 14,
        .time_ms = 15,
        .state = .pressed,
        .translated = .{ .keycode = 102, .logical = .home },
    } };
    try runtime.routeKeyboard(navigation);
    try runtime.dispatchInput(&callbacks);
    status = (try runtime.textInputStatus()).?;
    try std.testing.expectEqual(@as(i32, 1), status.state.cursor_rectangle.?.x);
    try std.testing.expectEqual(@as(usize, 0), editing.model.selection.extent);

    // An unfocused field may retain an offscreen caret. Focusing by click must
    // hit the visible text before revealing that old caret.
    runtime.focus.clear();
    try runtime.applyFocusVisual(target, null);
    _ = try editing.model.setSelection(.collapsed(normalized.len));
    try runtime.syncTextInputVisuals();
    try runtime.updateTextInputPointer(target, .{ .pointer = .{
        .target = target,
        .hovered = target,
        .position = .{ .x = 1, .y = 10 },
        .event = .{ .button = .{
            .window = window,
            .serial = 15,
            .time_ms = 16,
            .button = 0x110,
            .state = .pressed,
        } },
    } });
    try std.testing.expectEqual(@as(usize, 0), editing.model.selection.extent);
    try std.testing.expectEqual(@as(i32, 1), (try runtime.textInputStatus()).?.state.cursor_rectangle.?.x);

    navigation.key.translated.logical = .end;
    navigation.key.translated.modifiers.shift = true;
    try runtime.routeKeyboard(navigation);
    try runtime.dispatchInput(&callbacks);
    status = (try runtime.textInputStatus()).?;
    try std.testing.expectEqual(@as(i32, 158), status.state.cursor_rectangle.?.x);
    try std.testing.expectEqual(@as(usize, 0), editing.model.selection.anchor);
    try std.testing.expectEqual(normalized.len, editing.model.selection.extent);
    try std.testing.expect(!(try runtime.tree.objectAt(render)).text_input.show_caret);
    try std.testing.expect(scheduler.takeRunnable() == null);

    // A long composition is also one line, without committing its value.
    _ = try editing.model.setSelection(.collapsed(normalized.len));
    _ = try editing.apply(.{ .preedit = .{ .text = "composition beyond the viewport", .cursor = .{
        .start = "composition beyond the viewport".len,
        .end = "composition beyond the viewport".len,
    } } });
    try runtime.syncTextInputVisuals();
    _ = try runtime.tree.layout((try runtime.instances.rootRenderObject()).?, ui.layout.Constraints.tight(.{ .width = 160, .height = 32 }));
    status = (try runtime.textInputStatus()).?;
    try std.testing.expectEqual(@as(i32, 158), status.state.cursor_rectangle.?.x);
    try std.testing.expectEqualStrings(normalized, status.state.surrounding.?.text);
    const composing_revision = editing.model.revision;
    try runtime.routeKeyboard(history_key);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqual(composing_revision, editing.model.revision);
    try std.testing.expect(editing.preedit() != null);
    try std.testing.expect(scheduler.takeRunnable() == null);
    _ = try editing.apply(.{ .preedit = .{ .text = null, .cursor = null } });
    try runtime.syncTextInputVisuals();

    // Undo paste as one step and deliver exactly one normal change callback.
    try runtime.routeKeyboard(history_key);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings("", editing.model.text());
    _ = try callback_vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(scheduler.takeRunnable() == null);
    try std.testing.expectEqual(lua_c.type_string, lua_c.lua_getglobal(callback_vm.state, "changed_text"));
    const undone = lua_c.lua_tolstring(callback_vm.state, -1, &changed_length).?;
    try std.testing.expectEqualStrings("", undone[0..changed_length]);
    lua_c.lua_settop(callback_vm.state, -2);

    history_key.key.translated.modifiers.shift = true;
    try runtime.routeKeyboard(history_key);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings(normalized, editing.model.text());
    _ = try callback_vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(scheduler.takeRunnable() == null);
    _ = try runtime.tree.layout((try runtime.instances.rootRenderObject()).?, ui.layout.Constraints.tight(.{ .width = 160, .height = 32 }));
    try std.testing.expectEqual(@as(i32, 158), (try runtime.textInputStatus()).?.state.cursor_rectangle.?.x);

    character.key.state = .pressed;
    character.key.translated.unicode = 'A';
    try runtime.routeKeyboard(character);
    try runtime.dispatchInput(&callbacks);
    character.key.state = .repeated;
    character.key.translated.unicode = 'B';
    try runtime.routeKeyboard(character);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings(normalized ++ "AB", editing.model.text());
    while (scheduler.takeRunnable()) |runnable| _ = try callback_vm.resumeRunnable(runnable);
    history_key.key.translated.modifiers.shift = false;
    try runtime.routeKeyboard(history_key);
    try runtime.dispatchInput(&callbacks);
    try std.testing.expectEqualStrings(normalized, editing.model.text());
    _ = try callback_vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(scheduler.takeRunnable() == null);

    // Focus loss and submit split typing even without a command callback.
    for ([_]platform.KeyboardEvent{
        .{ .leave = .{ .window = window, .serial = 21 } },
        .{ .key = .{
            .window = window,
            .serial = 22,
            .time_ms = 22,
            .state = .pressed,
            .translated = .{ .keycode = 28, .logical = .enter },
        } },
    }) |boundary| {
        character.key.translated.unicode = 'A';
        try runtime.routeKeyboard(character);
        try runtime.dispatchInput(&callbacks);
        try runtime.routeKeyboard(boundary);
        try runtime.dispatchInput(&callbacks);
        character.key.translated.unicode = 'B';
        try runtime.routeKeyboard(character);
        try runtime.dispatchInput(&callbacks);
        while (scheduler.takeRunnable()) |runnable| _ = try callback_vm.resumeRunnable(runnable);
        try runtime.routeKeyboard(history_key);
        try runtime.dispatchInput(&callbacks);
        try std.testing.expectEqualStrings(normalized ++ "A", editing.model.text());
        _ = try callback_vm.resumeRunnable(scheduler.takeRunnable().?);
        try runtime.routeKeyboard(history_key);
        try runtime.dispatchInput(&callbacks);
        try std.testing.expectEqualStrings(normalized, editing.model.text());
        _ = try callback_vm.resumeRunnable(scheduler.takeRunnable().?);
        try std.testing.expect(scheduler.takeRunnable() == null);
    }

    // Command callbacks use the same configurable map and action-specific
    // repeat policy; disabled keys cannot reach the old command dispatch.
    var custom: ui.text_input.Behavior = .{};
    try custom.key_bindings.set(try ui.input.KeyChord.parse("Enter"), .none);
    try custom.key_bindings.set(try ui.input.KeyChord.parse("Ctrl+Enter"), .{ .command = .submit });
    try custom.key_bindings.set(try ui.input.KeyChord.parse("Alt+P"), .{ .command = .previous });
    var custom_candidate: ?ui.text_input.Session = try ui.text_input.Session.init(std.testing.allocator, "ignored");
    defer if (custom_candidate) |*value| value.deinit();
    try runtime.text_inputs.mountPrepared(owner, target, content, .uncontrolled, custom, &custom_candidate);
    _ = runtime.pointer_bindings.remove(target);
    _ = try runtime.pointer_bindings.set(owner, target, .{ .id = callback, .kind = .text_input_command });
    const CommandCase = struct { logical: platform.LogicalKey, modifiers: platform.Modifiers, state: platform.KeyState, expected: ?[]const u8 };
    for ([_]CommandCase{
        .{ .logical = .enter, .modifiers = .{}, .state = .pressed, .expected = null },
        .{ .logical = .enter, .modifiers = .{ .control = true }, .state = .pressed, .expected = "submit" },
        .{ .logical = .enter, .modifiers = .{ .control = true }, .state = .repeated, .expected = null },
        .{ .logical = .key_p, .modifiers = .{ .alt = true }, .state = .pressed, .expected = "previous" },
        .{ .logical = .key_p, .modifiers = .{ .alt = true }, .state = .repeated, .expected = "previous" },
        .{ .logical = .key_p, .modifiers = .{ .alt = true }, .state = .released, .expected = null },
    }) |case| {
        try runtime.routeKeyboard(.{ .key = .{
            .window = window,
            .serial = 25,
            .time_ms = 25,
            .state = case.state,
            .translated = .{ .keycode = 0, .logical = case.logical, .modifiers = case.modifiers },
        } });
        try runtime.dispatchInput(&callbacks);
        if (case.expected) |expected| {
            _ = try callback_vm.resumeRunnable(scheduler.takeRunnable().?);
            _ = lua_c.lua_getglobal(callback_vm.state, "changed_text");
            const value = lua_c.lua_tolstring(callback_vm.state, -1, &changed_length).?;
            try std.testing.expectEqualStrings(expected, value[0..changed_length]);
            lua_c.lua_settop(callback_vm.state, -2);
        }
        try std.testing.expect(scheduler.takeRunnable() == null);
        try std.testing.expectEqualStrings(normalized, editing.model.text());
    }
    _ = runtime.pointer_bindings.remove(target);
    _ = try runtime.pointer_bindings.set(owner, target, .{ .id = callback, .kind = .text_input_change });

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
    try runtime.routeKeyboard(character);
    try runtime.dispatchInput(&callbacks);
    try runtime.routeKeyboard(history_key);
    try runtime.dispatchInput(&callbacks);
    history_key.key.translated.modifiers.shift = true;
    try runtime.routeKeyboard(history_key);
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

fn pointerListenerEvent(event: ui.input.Event) ?listener.Event {
    return switch (event) {
        .hover_enter => |hover| .{ .kind = .enter, .x = hover.position.x, .y = hover.position.y },
        .hover_leave => |hover| .{ .kind = .leave, .x = hover.position.x, .y = hover.position.y },
        .pointer => |pointer| switch (pointer.event) {
            .motion => .{ .kind = .motion, .x = pointer.position.x, .y = pointer.position.y },
            .button => |button| .{
                .kind = if (button.state == .pressed) .press else .release,
                .x = pointer.position.x,
                .y = pointer.position.y,
                .button = button.button,
            },
            .axis => |axis| .{ .kind = .axis, .x = pointer.position.x, .y = pointer.position.y, .delta = axis.delta, .axis = axis.axis },
            else => null,
        },
        else => null,
    };
}

fn intentEditsText(intent: ui.text_input.EditIntent) bool {
    return switch (intent) {
        .undo, .redo, .insert_newline, .delete_backward, .delete_forward, .delete_word_backward, .delete_word_forward => true,
        .select_all, .move => false,
    };
}

fn isListBoxActivation(button: u32, state: platform.PointerButtonState) bool {
    return button == 0x110 and state == .pressed;
}

test "listbox pointer activation occurs on primary press" {
    try std.testing.expect(isListBoxActivation(0x110, .pressed));
    try std.testing.expect(!isListBoxActivation(0x110, .released));
    try std.testing.expect(!isListBoxActivation(0x111, .pressed));
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
        .text_input, .text_input_focus => unreachable,
    };
}

fn encodedColor(color: core.Color) i64 {
    return (@as(i64, color.r) << 24) |
        (@as(i64, color.g) << 16) |
        (@as(i64, color.b) << 8) |
        color.a;
}

fn axisCoordinate(axis: ui.render_object.types.Axis, point: core.PointF) f32 {
    return if (axis == .horizontal) point.x else point.y;
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

test "candidate source build preserves layer background alpha without changing retained UI" {
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
        \\  run = function() return { windows = {
        \\    ouro.window {
        \\      id = "main",
        \\      title = "Candidate",
        \\      content = function() end,
        \\    },
        \\  } } end,
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
    try std.testing.expectEqual(@as(f32, 12), runtime.root_padding);
    runtime.root_padding = 0;
    candidate.ui_build.enableDeclarativeWidgets(@import("../design/root.zig").tokens.light);
    const tint = core.Color.rgba(17, 24, 32, 184);
    candidate.ui_build.root_background = tint;
    try runtime.prepareSourceBuild(
        .{ .width = 320, .height = 200 },
        &candidate.ui_build,
        &candidate.prepared_builds[0],
        candidate.application.windows[0].content_reference,
        2,
    );
    try std.testing.expect(candidate.prepared_builds[0].reconcile_plan != null);
    try std.testing.expectEqual(@as(f32, 0), candidate.prepared_builds[0].descriptors()[0].object.box.padding.top);
    try std.testing.expectEqual(tint, candidate.prepared_builds[0].descriptors()[0].object.box.background.?);
    try std.testing.expectEqual(null, runtime.background);
    try std.testing.expectEqual(@as(usize, 0), runtime.instances.activeCount());
    try runtime.validatePreparedSourceCommit(&candidate.prepared_builds[0]);
    runtime.background = tint;
    runtime.commitPreparedSource(
        &candidate.prepared_builds[0],
        &callbacks,
        &candidate.vm,
        &candidate.signals,
    );
    try std.testing.expect(candidate.prepared_builds[0].reconcile_plan == null);
    try std.testing.expect(runtime.signals == &candidate.signals);

    // Resize and fractional scaling must preserve the tint at every pixel.
    // Repaint the same nonzero storage twice to detect alpha accumulation.
    _ = try runtime.frame_state.configure(.{ .width = 13, .height = 7 });
    try runtime.prepareFrame(1.5);
    var pixels: [20 * 11 * 4]u8 = @splat(255);
    for (0..2) |_| {
        try @import("../renderer/software/root.zig").render(try runtime.displayList(), .{
            .pixels = &pixels,
            .width = 20,
            .height = 11,
            .stride = 80,
            .format = .bgra8_unorm,
        });
        var offset: usize = 0;
        while (offset < pixels.len) : (offset += 4)
            try std.testing.expectEqualSlices(u8, &.{ 23, 17, 12, 184 }, pixels[offset..][0..4]);
    }
    try runtime.setTheme(@import("../design/root.zig").tokens.dark);
    try runtime.reconcile(.{ .width = 13, .height = 7 }, &candidate.ui_build, candidate.application.windows[0].content_reference);
    try std.testing.expectEqual(tint, candidate.ui_build.storage[0].object.box.background.?);
    try runtime.setBackground(null);
    try runtime.reconcile(.{ .width = 13, .height = 7 }, &candidate.ui_build, candidate.application.windows[0].content_reference);
    try std.testing.expectEqual(candidate.ui_build.widget_theme.?.colors.background, candidate.ui_build.storage[0].object.box.background.?);

    try runtime.clear(&candidate.ui_build);
    try scheduler.applyQueuedCancellations();
    try runtime.collectRetired();
    runtime.deinit();
    try scheduler.destroyScope(window_scope);
    candidate.destroy();
    active_vm.deinit();
    active_signals.deinit();
}
