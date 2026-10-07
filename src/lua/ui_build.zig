const std = @import("std");
const c = @import("c.zig");
const diagnostic = @import("diagnostic.zig");
const Description = @import("description.zig").Description;
const Components = @import("components.zig").Components;
const virtual_list = @import("../ui/widget/virtual_list.zig");
const layout_builder = @import("../ui/widget/layout_builder.zig");
const animation = @import("../ui/animation.zig");
const theming = @import("theme.zig");
const ThemeFonts = @import("theme_fonts.zig").ThemeFonts;
const CallbackRegistry = @import("callbacks.zig").CallbackRegistry;
const PreparedBuild = @import("prepared_build.zig").PreparedBuild;
const Vm = @import("vm.zig").Vm;
const design = @import("../design/root.zig");
const Signals = @import("signals.zig").Signals;
const SignalOwnerRef = @import("signals.zig").OwnerRef;
const build_owner = @import("../ui/instance/build_owner.zig");
const instance = @import("../ui/instance/tree.zig");
const PointerBindings = @import("../ui/input/bindings.zig").PointerBindings;
const Buttons = @import("../ui/widget/buttons.zig").Buttons;
const TextInputs = @import("../ui/text_input/registry.zig").Registry;
const TextInputValueMode = @import("../ui/text_input/registry.zig").ValueMode;
const TextInputSession = @import("../ui/text_input/session.zig").Session;
const ListBoxes = @import("../ui/widget/listboxes.zig").ListBoxes;
const render_types = @import("../ui/render_object/types.zig");
const SemanticDescriptor = @import("../ui/semantics/snapshot.zig").Descriptor;
const text = @import("../text/root.zig");
const image_service = @import("../image/service.zig");
const image_pixels = @import("../image/pixels.zig");

// Radix Themes keeps widget geometry in component recipes while reusable color
// roles and scales remain generated design data.

const PendingHandler = @import("prepared_build.zig").Handler;

const PendingButton = struct {
    id: u64,
    enabled: bool,
};
const ListBoxAppearance = enum { default, sidebar };
const PendingListBox = struct { id: u64, selected: i64, appearance: ListBoxAppearance, enabled: bool = true };
const PendingOption = struct {
    id: u64,
    listbox_id: u64,
    value: i64,
};

const InteractionOwner = struct {
    id: u64,
    selection: bool = false,
    selected: bool = false,
    enabled: bool = true,

    fn initialColor(self: InteractionOwner, paint: instance.InteractionPaint) ?@import("../core/color.zig").Color {
        if (self.selection) return if (self.selected) paint.selected orelse paint.idle else paint.idle;
        return if (self.enabled) paint.idle else paint.disabled orelse paint.idle;
    }
};

const PendingTextInput = struct {
    target_id: u64,
    content_id: u64,
    mode: TextInputValueMode,
    behavior: @import("../ui/text_input/registry.zig").Behavior,
    session: ?TextInputSession,
};

const ParentKind = enum { box, flex, grid, stack, positioned_stack, overlay, scroll, listbox, radio_group, tab_bar, split };
const BuildParent = struct {
    id: u64,
    kind: ParentKind,
    semantic_id: ?u64 = null,
    wrap: bool = false,
    grid_columns: u8 = 0,
    grid_rows: u8 = 0,
    grid_cell: ?@FieldType(render_types.ParentData, "grid") = null,
    positioned: ?render_types.Positioned = null,
};

pub const Argument = union(enum) {
    number: f64,
    integer: i64,
    boolean: bool,
};

pub const Callback = union(enum) {
    global: [*:0]const u8,
    reference: c_int,
};

pub const ActiveBuildOwner = struct {
    owners: *build_owner.BuildOwners,
    handle: build_owner.BuildOwnerHandle,
};

// A boundary refers to the already-owned native root. It stores no descriptor,
// callback, text, or render-object snapshot. Inherited context is compared by
// value before skipping lowering.
const BoundaryContext = struct {
    parent: BuildParent,
    theme: ?theming.Theme,
    interaction: ?InteractionOwner,
    selection: ?PendingListBox,
    interactive: bool,
    parent_depth: usize,
    composition_depth: usize,
    text_revision: u64,
};
const Boundary = struct {
    context: BoundaryContext,
    root: ?u64,
    safe: bool,
};

/// Lowers returned Lua descriptions into typed native descriptors, parent first.
/// Constructor evaluation has no UI side effects. Contextual layout, theme, and
/// widget policy remain here, not in the description constructors.
pub const UiBuild = struct {
    state: *c.State,
    storage: []instance.Descriptor,
    count: usize = 0,
    root_reference: c_int = c.no_reference,
    components: Components = .{},
    component_namespace: u64 = 0,
    component_scope_clean: bool = true,
    interaction_owner: ?InteractionOwner = null,
    interactive: bool = true,
    composition_depth: usize = 0,
    native_dependent_count: usize = 0,
    full_lowering: bool = false,
    retention_blocked: bool = false,
    virtual_lists: virtual_list.Snapshot = .{},
    layout_builders: layout_builder.Snapshot = .{},
    layout_proposals: layout_builder.Snapshot = .{},
    layout_measurement: ?struct {
        context: *anyopaque,
        measure: *const fn (*anyopaque, []instance.Descriptor, *layout_builder.Snapshot) anyerror!bool,
    } = null,
    animations: ?*const animation.Registry = null,
    pending_animations: [256]animation.Descriptor = undefined,
    pending_animation_count: usize = 0,
    semantic_storage: []SemanticDescriptor = &.{},
    semantic_count: usize = 0,
    active_owner: ?ActiveBuildOwner = null,
    signals: ?*Signals = null,
    callbacks: ?*CallbackRegistry = null,
    callback_vm: ?*Vm = null,
    text_sources: ?*text.ParagraphSourceCache = null,
    paragraphs: ?*text.ParagraphCache = null,
    text_candidates: []const text.FontHandle = &.{},
    medium_candidates: []const text.FontHandle = &.{},
    text_configuration_revision: u64 = 0,
    widget_theme: ?theming.Theme = null,
    text_input_bindings: @import("key_bindings.zig").Keymap = .{},
    root_padding: f32 = design.tokens.foundation.spacing_3,
    root_background: ?@import("../core/color.zig").Color = null,
    theme_fonts: ?*ThemeFonts = null,
    images: ?*image_service.Service = null,
    image_scale: f32 = 1,
    images_staged: bool = false,
    drawings_staged: bool = false,
    theme_stack: [32]theming.Theme = undefined,
    theme_count: usize = 0,
    parent_stack: [32]BuildParent = undefined,
    parent_count: usize = 0,
    sources_staged: bool = false,
    pending_handlers: [256]PendingHandler = undefined,
    pending_handler_count: usize = 0,
    pending_buttons: [256]PendingButton = undefined,
    pending_button_count: usize = 0,
    pending_text_inputs: [256]PendingTextInput = undefined,
    pending_text_input_count: usize = 0,
    pending_listboxes: [256]PendingListBox = undefined,
    pending_listbox_count: usize = 0,
    pending_options: [256]PendingOption = undefined,
    pending_option_count: usize = 0,

    pub fn init(
        self: *UiBuild,
        state: *c.State,
        storage: []instance.Descriptor,
    ) !void {
        return self.initWithApiReference(state, storage, null);
    }

    pub fn initWithApi(
        self: *UiBuild,
        state: *c.State,
        storage: []instance.Descriptor,
        api_reference: c_int,
    ) !void {
        return self.initWithApiReference(state, storage, api_reference);
    }

    fn initWithApiReference(
        self: *UiBuild,
        state: *c.State,
        storage: []instance.Descriptor,
        api_reference: ?c_int,
    ) !void {
        if (storage.len == 0) return error.InvalidDescriptorCapacity;
        self.* = .{ .state = state, .storage = storage };

        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        const api_type = if (api_reference) |reference|
            c.lua_rawgeti(state, c.registry_index, reference)
        else
            c.lua_getglobal(state, "ouro");
        if (api_type != c.type_table) return error.OuroApiMissing;
        Description.install(state);
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, measureText, 1);
        c.lua_setfield(state, -2, "measure_text");
        try @import("forms.zig").install(state);
        try @import("machine.zig").install(state);
        try self.components.init(state);
    }

    /// Executes a non-yielding mounted build callback in the reconciliation
    /// phase. The returned slice is borrowed until the next build.
    pub fn build(
        self: *UiBuild,
        owners: *build_owner.BuildOwners,
        work: build_owner.BuildWork,
        function_name: [*:0]const u8,
        arguments: []const Argument,
    ) ![]const instance.Descriptor {
        return self.buildCallback(owners, work, .{ .global = function_name }, arguments);
    }

    pub fn buildCallback(
        self: *UiBuild,
        owners: *build_owner.BuildOwners,
        work: build_owner.BuildWork,
        callback: Callback,
        arguments: []const Argument,
    ) ![]const instance.Descriptor {
        if (self.active_owner != null) return error.LuaBuildReentered;
        self.discardHandlers();
        self.discardPendingTextInputs();
        self.discardSources();
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        c.luaL_unref(self.state, c.registry_index, self.root_reference);
        self.root_reference = c.no_reference;
        // Builds without an attached signal graph may discard borrowed output
        // simply by starting another build. Never retain an abandoned proposal.
        if (self.signals == null) try self.components.call("rollback");
        try self.components.begin(owners, work.owner);
        errdefer self.components.call("rollback") catch unreachable;
        self.components.push("root");
        const callback_type = switch (callback) {
            .global => |name| c.lua_getglobal(self.state, name),
            .reference => |reference| c.lua_rawgeti(self.state, c.registry_index, reference),
        };
        if (callback_type != c.type_function)
            return error.LuaBuildFunctionMissing;
        self.layout_proposals = .{};
        self.full_lowering = false;
        self.active_owner = .{ .owners = owners, .handle = work.owner };
        defer self.active_owner = null;
        if (self.images) |images| try images.beginOwner(owners, work.owner);
        errdefer if (self.images) |images| images.rollbackOwner(owners, work.owner);
        const signal_owner: SignalOwnerRef = .{ .owners = owners, .handle = work.owner };
        if (self.signals) |signals| try signals.beginEvaluation(signal_owner, work.revision);
        errdefer {
            self.discardHandlers();
            self.discardPendingTextInputs();
            self.discardSources();
            self.pending_button_count = 0;
            self.pending_listbox_count = 0;
            self.pending_option_count = 0;
            if (self.signals) |signals| signals.abortEvaluation(signal_owner, work.revision) catch unreachable;
        }
        for (arguments) |argument| switch (argument) {
            .number => |value| c.lua_pushnumber(self.state, value),
            .integer => |value| c.lua_pushinteger(self.state, value),
            .boolean => |value| c.lua_pushboolean(self.state, @intFromBool(value)),
        };
        var status = diagnostic.pcall(self.state, @intCast(arguments.len + 1), 1);
        if (status == c.ok) {
            c.lua_pushvalue(self.state, -1);
            self.root_reference = c.luaL_ref(self.state, c.registry_index);
        }
        var pass: usize = 0;
        while (status == c.ok) : (pass += 1) {
            if (pass > self.layout_builders.entries.len) return error.LayoutBuilderDidNotSettle;
            if (pass != 0) {
                self.discardHandlers();
                self.discardPendingTextInputs();
                self.discardSources();
                try self.components.call("relower");
                if (self.images) |images| {
                    images.rollbackOwner(owners, work.owner);
                    try images.beginOwner(owners, work.owner);
                }
            }
            try self.beginLowering();
            c.lua_pushlightuserdata(self.state, self);
            c.lua_pushcclosure(self.state, lowerDescription, 1);
            _ = c.lua_rawgeti(self.state, c.registry_index, self.root_reference);
            status = diagnostic.pcall(self.state, 1, 0);
            if (status != c.ok or self.layout_builders.count == 0) break;
            // Isolated measurement requires a complete tree. A builder may
            // appear after a retained sibling, so restart before measuring.
            if (!self.full_lowering) {
                self.full_lowering = true;
                continue;
            }
            const measurement = self.layout_measurement orelse return error.LayoutBuilderMeasurementRequired;
            if (try measurement.measure(measurement.context, self.storage[0..self.count], &self.layout_builders)) break;
            self.layout_proposals = self.layout_builders;
        }
        if (status == c.ok) {
            self.components.push("finish");
            status = diagnostic.pcall(self.state, 0, 1);
            if (status == c.ok) {
                c.luaL_unref(self.state, c.registry_index, self.root_reference);
                self.root_reference = c.luaL_ref(self.state, c.registry_index);
            }
        }
        if (status != c.ok) {
            diagnostic.logLuaStack(self.state);
            if (status == c.yield) return error.LuaBuildYielded;
            return error.LuaBuildFailed;
        }
        if (self.signals) |signals| try signals.finishEvaluation(signal_owner, work.revision);
        return self.storage[0..self.count];
    }

    fn beginLowering(self: *UiBuild) !void {
        self.count = 0;
        self.semantic_count = 0;
        self.parent_count = 0;
        self.theme_count = 0;
        self.component_namespace = 0;
        self.component_scope_clean = true;
        self.interaction_owner = null;
        self.interactive = true;
        self.composition_depth = 0;
        self.native_dependent_count = 0;
        self.retention_blocked = false;
        self.virtual_lists = .{};
        self.layout_builders = .{};
        self.pending_animation_count = 0;
        self.pending_button_count = 0;
        self.pending_text_input_count = 0;
        self.pending_listbox_count = 0;
        self.pending_option_count = 0;
        if (self.widget_theme) |theme| {
            try self.append(.{
                .id = 1,
                .parent = null,
                .object = .{ .box = .{
                    .padding = .all(self.root_padding),
                    .background = self.root_background orelse theme.colors.background,
                } },
            });
            self.parent_stack[0] = .{ .id = 2, .kind = .stack };
            self.parent_count = 1;
            try self.append(.{ .id = 2, .parent = 1, .object = .{ .stack = .{ .clip = true } } });
        }
    }

    /// Reserve callback storage and validate capacity before the native tree
    /// changes. The generated handler targets are validated by reconciliation.
    pub fn validateBindings(
        self: *UiBuild,
        bindings: *PointerBindings,
        buttons: *Buttons,
        text_inputs: *TextInputs,
        tree: *instance.Tree,
        owner: build_owner.BuildOwnerHandle,
    ) !void {
        const callbacks = self.callbacks orelse if (self.pending_handler_count == 0)
            null
        else
            return error.CallbackServiceUnavailable;
        if (self.pending_handler_count != 0 and
            self.pending_handler_count > bindings.availableAfterReconcile(tree, owner))
            return error.PointerBindingCapacityExceeded;
        if (self.pending_button_count != 0 and self.pending_button_count > buttons.availableForOwnerRetaining(owner, tree))
            return error.ButtonCapacityExceeded;
        if (self.pending_text_input_count != 0 and self.pending_text_input_count > text_inputs.availableForOwnerRetaining(owner, tree))
            return error.TextInputCapacityExceeded;
        if (self.pending_handler_count != 0) {
            const reclaimable = bindings.reclaimableForOwner(tree, owner);
            if (self.pending_handler_count > reclaimable)
                try callbacks.?.ensureAvailable(self.pending_handler_count - reclaimable);
        }
    }

    /// Commits the staged Lua references only after instance reconciliation.
    /// Bindings omitted by the new build are removed, and all replaced or
    /// removed registry references are released explicitly.
    pub fn commitBindings(
        self: *UiBuild,
        bindings: *PointerBindings,
        buttons: *Buttons,
        text_inputs: *TextInputs,
        listboxes: *ListBoxes,
        tree: *instance.Tree,
        owner: build_owner.BuildOwnerHandle,
    ) !void {
        try self.validateBindings(bindings, buttons, text_inputs, tree, owner);
        const callbacks = self.callbacks;
        for (self.pending_handlers[0..self.pending_handler_count]) |pending|
            if (tree.handleForId(pending.id) == null) return error.PointerHandlerInstanceMissing;
        for (self.pending_buttons[0..self.pending_button_count]) |pending|
            if (tree.handleForId(pending.id) == null) return error.ButtonInstanceMissing;
        for (self.pending_text_inputs[0..self.pending_text_input_count]) |pending|
            if (tree.handleForId(pending.target_id) == null or
                tree.handleForId(pending.content_id) == null)
                return error.TextInputInstanceMissing;
        for (self.pending_text_inputs[0..self.pending_text_input_count]) |*pending|
            try text_inputs.prepareMount(
                tree.handleForId(pending.target_id).?,
                pending.mode,
                &pending.session,
            );
        for (self.pending_listboxes[0..self.pending_listbox_count]) |pending|
            if (tree.handleForId(pending.id) == null) return error.ListBoxInstanceMissing;
        for (self.pending_options[0..self.pending_option_count]) |pending|
            if (tree.handleForId(pending.id) == null or tree.handleForId(pending.listbox_id) == null)
                return error.ListBoxOptionInstanceMissing;
        while (bindings.takeInactive(tree)) |old|
            callbacks.?.release(old.id) catch unreachable;
        while (bindings.takeUnretainedOwner(owner, tree)) |old|
            callbacks.?.release(old.id) catch unreachable;
        for (self.pending_handlers[0..self.pending_handler_count]) |pending| {
            const handle = callbacks.?.adoptReference(
                self.callback_vm.?,
                pending.reference,
            ) catch unreachable;
            const old = bindings.set(
                owner,
                tree.handleForId(pending.id).?,
                .{ .id = handle, .kind = pending.kind, .open_override = pending.open_override, .include_capture = pending.include_capture, .propagate = pending.propagate, .filter = pending.filter, .sequence = pending.sequence, .command = pending.command },
            ) catch unreachable;
            if (old) |handler| callbacks.?.release(handler.id) catch unreachable;
        }
        bindings.pruneScrollStates(tree);
        buttons.beginOwnerRetaining(owner, tree);
        for (self.pending_buttons[0..self.pending_button_count]) |pending| buttons.set(
            owner,
            tree.handleForId(pending.id).?,
            pending.enabled,
        );
        buttons.finishOwner(owner);
        text_inputs.beginOwnerRetaining(owner, tree);
        for (self.pending_text_inputs[0..self.pending_text_input_count]) |*pending| {
            try text_inputs.mountPrepared(
                owner,
                tree.handleForId(pending.target_id).?,
                tree.handleForId(pending.content_id).?,
                pending.mode,
                pending.behavior,
                &pending.session,
            );
        }
        text_inputs.finishOwner(owner);
        self.pending_handler_count = 0;
        self.pending_button_count = 0;
        self.discardPendingTextInputs();
        listboxes.beginOwnerRetaining(owner, tree);
        for (self.pending_listboxes[0..self.pending_listbox_count]) |pending| try listboxes.setList(
            owner,
            tree.handleForId(pending.id).?,
            pending.selected,
        );
        for (self.pending_options[0..self.pending_option_count]) |pending| try listboxes.setOption(
            owner,
            tree.handleForId(pending.listbox_id).?,
            tree.handleForId(pending.id).?,
            pending.value,
        );
        listboxes.finishOwnerRetaining(owner, tree);
        self.pending_handler_count = 0;
        self.pending_button_count = 0;
        self.pending_listbox_count = 0;
        self.pending_option_count = 0;
        self.discardSources();
    }

    pub fn rollbackHandlers(self: *UiBuild) void {
        self.discardHandlers();
        self.pending_button_count = 0;
        self.discardPendingTextInputs();
        self.pending_listbox_count = 0;
        self.pending_option_count = 0;
        self.discardSources();
    }

    /// Transfers one completed build into generation-owned storage so another
    /// candidate window may build without releasing this window's callbacks
    /// or shapes. No retained native UI is changed here.
    pub fn capturePrepared(
        self: *UiBuild,
        prepared: *PreparedBuild,
        descriptors: []const instance.Descriptor,
    ) !void {
        if (prepared.state != self.state or descriptors.len != self.count or
            descriptors.ptr != self.storage.ptr) return error.InvalidPreparedBuildSource;
        for (descriptors) |descriptor| if (descriptor.retain_subtree)
            return error.RetainedPreparedBuild;
        if (descriptors.len > prepared.descriptor_storage.len or
            self.semantic_count > prepared.semantic_storage.len or
            self.pending_handler_count > prepared.handlers.len or
            self.pending_button_count > prepared.prepared_buttons.len or
            self.pending_text_input_count > prepared.text_inputs.len)
            return error.PreparedBuildCapacityExceeded;
        if (self.pending_listbox_count > prepared.prepared_listboxes.len or
            self.pending_option_count > prepared.prepared_options.len)
            return error.PreparedBuildCapacityExceeded;
        var semantic_text_count: usize = 0;
        for (self.semantic_storage[0..self.semantic_count]) |descriptor| {
            semantic_text_count = std.math.add(
                usize,
                semantic_text_count,
                descriptor.label.len,
            ) catch return error.PreparedSemanticTextCapacityExceeded;
            if (semantic_text_count > prepared.semantic_text.len)
                return error.PreparedSemanticTextCapacityExceeded;
        }

        prepared.reset();
        _ = c.lua_rawgeti(self.state, c.registry_index, self.root_reference);
        prepared.description_reference = c.luaL_ref(self.state, c.registry_index);
        @memcpy(prepared.descriptor_storage[0..descriptors.len], descriptors);
        prepared.descriptor_count = descriptors.len;
        prepared.virtual_lists = self.virtual_lists;
        prepared.layout_builders = self.layout_builders;
        @memcpy(prepared.animations[0..self.pending_animation_count], self.animationDescriptors());
        prepared.animation_count = self.pending_animation_count;
        var text_offset: usize = 0;
        for (
            self.semantic_storage[0..self.semantic_count],
            prepared.semantic_storage[0..self.semantic_count],
        ) |source, *destination| {
            @memcpy(
                prepared.semantic_text[text_offset..][0..source.label.len],
                source.label,
            );
            destination.* = source;
            destination.label = prepared.semantic_text[text_offset..][0..source.label.len];
            text_offset += source.label.len;
        }
        prepared.semantic_count = self.semantic_count;
        prepared.semantic_text_count = text_offset;
        for (
            self.pending_handlers[0..self.pending_handler_count],
            prepared.handlers[0..self.pending_handler_count],
        ) |source, *destination| destination.* = source;
        prepared.handler_count = self.pending_handler_count;
        for (
            self.pending_buttons[0..self.pending_button_count],
            prepared.prepared_buttons[0..self.pending_button_count],
        ) |source, *destination| destination.* = .{
            .id = source.id,
            .enabled = source.enabled,
        };
        prepared.button_count = self.pending_button_count;
        for (
            self.pending_text_inputs[0..self.pending_text_input_count],
            prepared.text_inputs[0..self.pending_text_input_count],
        ) |*source, *destination| {
            destination.* = .{
                .target_id = source.target_id,
                .content_id = source.content_id,
                .mode = source.mode,
                .behavior = source.behavior,
                .session = source.session,
            };
            source.session = null;
        }
        prepared.text_input_count = self.pending_text_input_count;
        prepared.owns_shapes = self.sources_staged;
        self.pending_handler_count = 0;
        self.pending_button_count = 0;
        self.pending_text_input_count = 0;
        for (self.pending_listboxes[0..self.pending_listbox_count], prepared.prepared_listboxes[0..self.pending_listbox_count]) |source, *destination|
            destination.* = .{ .id = source.id, .selected = source.selected };
        prepared.listbox_count = self.pending_listbox_count;
        for (self.pending_options[0..self.pending_option_count], prepared.prepared_options[0..self.pending_option_count]) |source, *destination|
            destination.* = .{
                .id = source.id,
                .listbox_id = source.listbox_id,
                .value = source.value,
            };
        prepared.option_count = self.pending_option_count;
        prepared.owns_shapes = self.sources_staged;
        self.pending_handler_count = 0;
        self.pending_button_count = 0;
        self.pending_listbox_count = 0;
        self.pending_option_count = 0;
        self.sources_staged = false;
        prepared.images = if (self.images) |images| images.cache else null;
        prepared.owns_images = self.images_staged;
        self.images_staged = false;
        prepared.owns_drawings = self.drawings_staged;
        self.drawings_staged = false;
    }

    pub fn clearHandlers(self: *UiBuild, bindings: *PointerBindings) void {
        while (bindings.takeAny()) |handler|
            self.callbacks.?.release(handler.id) catch unreachable;
    }

    /// Commits signal dependencies after the typed descriptor snapshot has
    /// reconciled transactionally into the retained instance tree.
    pub fn validateDependencies(
        self: *UiBuild,
        owners: *build_owner.BuildOwners,
        work: build_owner.BuildWork,
    ) !void {
        if (self.signals) |signals| try signals.validateCommit(
            .{ .owners = owners, .handle = work.owner },
            work.revision,
        );
    }

    pub fn commitDependencies(
        self: *UiBuild,
        owners: *build_owner.BuildOwners,
        work: build_owner.BuildWork,
    ) !void {
        if (self.signals) |signals| try signals.commit(
            .{ .owners = owners, .handle = work.owner },
            work.revision,
        );
        self.components.call("commit") catch unreachable;
        if (self.images) |images| images.commitOwner(owners, work.owner);
    }

    /// Preserves the previous dependency set when descriptor reconciliation
    /// fails after a successful Lua callback.
    pub fn rollbackDependencies(
        self: *UiBuild,
        owners: *build_owner.BuildOwners,
        work: build_owner.BuildWork,
    ) !void {
        if (self.signals) |signals| try signals.rollback(
            .{ .owners = owners, .handle = work.owner },
            work.revision,
        );
        self.components.call("rollback") catch unreachable;
        if (self.images) |images| images.rollbackOwner(owners, work.owner);
    }

    pub fn disposeOwner(self: *UiBuild, owners: *build_owner.BuildOwners, owner: build_owner.BuildOwnerHandle) void {
        if (self.images) |images| images.disposeOwner(owners, owner);
        self.components.dispose(owners, owner);
        c.luaL_unref(self.state, c.registry_index, self.root_reference);
        self.root_reference = c.no_reference;
    }

    pub fn activeOwner(self: *const UiBuild) ?ActiveBuildOwner {
        return self.active_owner;
    }

    pub fn attachSignals(self: *UiBuild, signals: *Signals) void {
        std.debug.assert(self.active_owner == null and self.signals == null);
        self.signals = signals;
        self.components.signals = signals;
    }

    pub fn attachCallbacks(
        self: *UiBuild,
        callbacks: *CallbackRegistry,
        vm: *Vm,
    ) void {
        std.debug.assert(self.active_owner == null and self.callbacks == null);
        std.debug.assert(self.state == vm.state);
        self.callbacks = callbacks;
        self.callback_vm = vm;
    }

    pub fn attachText(
        self: *UiBuild,
        sources: *text.ParagraphSourceCache,
        candidates: []const text.FontHandle,
        configuration_revision: u64,
    ) !void {
        if (self.active_owner != null or self.text_sources != null or candidates.len == 0)
            return error.InvalidTextService;
        self.text_sources = sources;
        self.text_candidates = candidates;
        self.text_configuration_revision = configuration_revision;
    }

    pub fn attachMediumText(self: *UiBuild, candidates: []const text.FontHandle) !void {
        if (self.active_owner != null or self.text_sources == null or
            self.medium_candidates.len != 0 or candidates.len == 0)
            return error.InvalidMediumTextService;
        self.medium_candidates = candidates;
    }

    pub fn enableDeclarativeWidgets(self: *UiBuild, scheme: theming.ColorScheme) void {
        std.debug.assert(self.active_owner == null and self.widget_theme == null);
        self.widget_theme = .{ .colors = scheme.colors(), .color_scheme = scheme };
    }

    pub fn attachSemantics(self: *UiBuild, storage: []SemanticDescriptor) !void {
        if (self.active_owner != null or self.semantic_storage.len != 0 or storage.len == 0)
            return error.InvalidSemanticStorage;
        self.semantic_storage = storage;
    }

    pub fn semanticDescriptors(self: *const UiBuild) []const SemanticDescriptor {
        return self.semantic_storage[0..self.semantic_count];
    }

    pub fn animationDescriptors(self: *const UiBuild) []const animation.Descriptor {
        return self.pending_animations[0..self.pending_animation_count];
    }

    fn lowerDescription(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_type(state, 1) == c.type_nil) return 0;
        const description = Description.get(state, 1) orelse
            return luaError(state, "build must return a widget description or nil");
        // These owners still consume complete snapshots or native samples.
        // Keep lowering them until their own retention contracts support skips.
        switch (description.kind) {
            .animation, .transition, .presence, .virtual_list, .layout_builder, .image, .icon, .canvas, .scroll => self.native_dependent_count += 1,
            else => {},
        }
        const emit: c.CFunction = switch (description.kind) {
            .text => emitText,
            .image => emitImage,
            .canvas => emitCanvas,
            .icon => emitIcon,
            .text_editor => emitTextEditor,
            .split => emitSplit,
            .box => emitBox,
            .stack => emitStack,
            .anchored => emitAnchored,
            .grid => emitGrid,
            .row => emitRow,
            .column => emitColumn,
            .scroll => emitScroll,
            .theme => emitTheme,
            .stateful => return self.lowerComponent(state),
            .stateless => return self.lowerComposition(state),
            .animation, .transition, .presence => return self.lowerAnimation(state, description.kind),
            .virtual_list => return self.lowerVirtualList(state),
            .layout_builder => return self.lowerLayoutBuilder(state),
        };
        c.lua_pushlightuserdata(state, self);
        _ = c.lua_getiuservalue(state, 1, 2);
        c.lua_pushcclosure(state, emit, 2);
        _ = c.lua_getiuservalue(state, 1, 1);
        if (c.lua_pcallk(state, 1, 0, 0, 0, null) != c.ok) return c.lua_error(state);
        return 0;
    }

    fn lowerAnimation(self: *UiBuild, state: *c.State, kind: @import("description.zig").Kind) c_int {
        const transition = kind != .animation;
        const presence = kind == .presence;
        if (self.composition_depth == 32) return luaError(state, "composition nesting too deep");
        self.composition_depth += 1;
        defer self.composition_depth -= 1;
        _ = c.lua_getiuservalue(state, 1, 1);
        var parent = self.compositionParent(state, 2) catch |err| return luaError(state, parentDataErrorMessage(err));
        const key = tableString(state, 2, "key") orelse return luaError(state, "animation key is required");
        if (key.len == 0) return luaError(state, "animation key is required");
        const spring = tableOptionalSpring(state, 2) catch return luaError(state, "invalid spring configuration");
        var duration: c.Integer = 0;
        if (spring != null) {
            if (kind != .transition) return luaError(state, "spring requires a transition");
            inline for (.{ "duration", "easing" }) |field| {
                const specified = c.lua_getfield(state, 2, field) != c.type_nil;
                c.lua_settop(state, -2);
                if (specified) return luaError(state, "spring cannot specify duration or easing");
            }
        } else {
            duration = tableRequiredInteger(state, 2, "duration") orelse return luaError(state, "animation duration must be non-negative integer milliseconds");
            if (duration < 0) return luaError(state, "animation duration must be non-negative integer milliseconds");
        }
        const motion = tableOptionalEnum(enum { auto, reduce, full }, state, 2, "motion", .auto) orelse return luaError(state, "invalid motion policy");
        var descriptor: animation.Descriptor = .{
            .id = semanticId(key, (if (presence) @as(u64, 0x70726573656e74) else if (transition) @as(u64, 0x7472616e736974) else 0x616e696d617465) ^ parent.id ^ self.component_namespace),
            .config = .{
                .duration_ns = std.math.mul(u64, @intCast(duration), std.time.ns_per_ms) catch return luaError(state, "animation duration too large"),
                .easing = tableOptionalEnum(animation.Easing, state, 2, "easing", .linear) orelse return luaError(state, "invalid animation easing"),
                .loop = tableOptionalBoolean(state, 2, "loop", false) orelse return luaError(state, "animation loop must be boolean"),
                .spring = spring,
                .reduced_motion = switch (motion) {
                    .auto => if (self.currentStyle()) |style| style.reduced_motion else false,
                    .reduce => true,
                    .full => false,
                },
            },
        };
        var present = true;
        if (presence) {
            if (c.lua_getfield(state, 2, "present") != c.type_boolean) return luaError(state, "presence present must be boolean");
            present = c.lua_toboolean(state, -1) != 0;
            c.lua_settop(state, -2);
            descriptor.transition = .{ .target = if (present) 1 else 0, .initial = 0 };
        } else if (transition) {
            if (c.lua_getfield(state, 2, "target") != c.type_number) return luaError(state, "transition target must be a finite number");
            var valid: c_int = 0;
            const target = c.lua_tonumberx(state, -1, &valid);
            c.lua_settop(state, -2);
            descriptor.transition = .{ .target = target };
            const initial_kind = c.lua_getfield(state, 2, "initial");
            if (initial_kind != c.type_nil) {
                if (initial_kind != c.type_number) return luaError(state, "transition initial must be a finite number");
                descriptor.transition.?.initial = c.lua_tonumberx(state, -1, &valid);
            }
            c.lua_settop(state, -2);
        }
        descriptor.validate() catch return luaError(state, "invalid animation or transition configuration");
        if (self.pending_animation_count == self.pending_animations.len) return luaError(state, "animation capacity exceeded");
        for (self.animationDescriptors()) |existing| if (existing.id == descriptor.id) return luaError(state, "duplicate animation key");
        self.pending_animations[self.pending_animation_count] = descriptor;
        self.pending_animation_count += 1;
        if (c.lua_getfield(state, 2, "render") != c.type_function) return luaError(state, "animation render must be a function");
        c.lua_settop(state, -2);
        const progress = if (self.animations) |registry| registry.sample(descriptor) else descriptor.initial();
        if (presence and !present and progress == 0) return 0;
        const previous_interactive = self.interactive;
        self.interactive = self.interactive and (!presence or present);
        defer self.interactive = previous_interactive;
        self.appendSemantic(.{ .id = descriptor.id, .parent = semanticParent(parent), .role = .group, .key = key }) catch
            return luaError(state, "cannot append animation semantics");
        self.components.push("compose");
        if (c.lua_getfield(state, 2, "render") != c.type_function) return luaError(state, "animation render must be a function");
        c.lua_pushnumber(state, progress);
        if (c.lua_pcallk(state, 2, 1, 0, 0, null) != c.ok) return c.lua_error(state);
        parent.semantic_id = descriptor.id;
        self.pushParent(parent) catch return luaError(state, "animation nesting too deep");
        const previous = self.component_namespace;
        self.component_namespace = descriptor.id;
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, lowerDescription, 1);
        c.lua_pushvalue(state, -2);
        const status = c.lua_pcallk(state, 1, 0, 0, 0, null);
        self.component_namespace = previous;
        self.popParent();
        if (status != c.ok) return c.lua_error(state);
        return 0;
    }

    fn lowerComposition(self: *UiBuild, state: *c.State) c_int {
        if (self.composition_depth == 32) return luaError(state, "composition nesting too deep");
        self.composition_depth += 1;
        defer self.composition_depth -= 1;
        const theme = self.currentStyle() orelse return luaError(state, "composition requires a theme");
        _ = c.lua_getiuservalue(state, 1, 1);
        const parent = self.compositionParent(state, -1) catch |err| return luaError(state, parentDataErrorMessage(err));
        c.lua_settop(state, 1);
        self.components.push("compose");
        _ = c.lua_getiuservalue(state, 1, 3);
        _ = c.lua_getiuservalue(state, 1, 1);
        _ = c.lua_getiuservalue(state, 1, 2);
        @import("tokens.zig").push(state, theme);
        c.lua_createtable(state, 0, 1);
        if (self.currentSelection()) |group| {
            c.lua_createtable(state, 0, 4);
            _ = c.lua_pushstring(state, switch (self.currentParent().?.kind) {
                .listbox => "listbox",
                .radio_group => "radio_group",
                .tab_bar => "tab_list",
                else => unreachable,
            });
            c.lua_setfield(state, -2, "role");
            c.lua_pushinteger(state, group.selected);
            c.lua_setfield(state, -2, "selected");
            c.lua_pushboolean(state, @intFromBool(group.enabled));
            c.lua_setfield(state, -2, "enabled");
            _ = c.lua_pushstring(state, @tagName(group.appearance));
            c.lua_setfield(state, -2, "appearance");
            c.lua_setfield(state, -2, "selection");
        }
        if (c.lua_pcallk(state, 5, 1, 0, 0, null) != c.ok) return c.lua_error(state);
        if (parent.kind == .grid or parent.kind == .positioned_stack) self.pushParent(parent) catch return luaError(state, "composition nesting too deep");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, lowerDescription, 1);
        c.lua_pushvalue(state, -2);
        const status = c.lua_pcallk(state, 1, 0, 0, 0, null);
        if (parent.kind == .grid or parent.kind == .positioned_stack) self.popParent();
        if (status != c.ok) return c.lua_error(state);
        return 0;
    }

    // A composition contributes no layout node. Carry its placement through
    // its returned root, without mutating descriptions or individual recipes.
    // Root properties can override inherited placement; descendants cannot
    // inherit it once a real container has pushed its own parent context.
    fn compositionParent(self: *UiBuild, state: *c.State, props: c_int) !BuildParent {
        var parent = self.currentParent() orelse return error.WidgetParentMissing;
        if (try tableOptionalPositioned(state, props)) |placement| {
            if (parent.kind != .positioned_stack) return error.PositionedRequiresStackParent;
            parent.positioned = placement;
        }
        if (parent.kind == .grid) {
            for ([_][:0]const u8{ "column", "row", "column_span", "row_span" }) |field| {
                const kind = c.lua_getfield(state, props, field);
                c.lua_settop(state, -2);
                if (kind != c.type_nil) {
                    parent.grid_cell = (try declarativeParentData(self, state, props)).grid;
                    break;
                }
            }
        }
        return parent;
    }

    fn currentSelection(self: *const UiBuild) ?PendingListBox {
        const parent = self.currentParent() orelse return null;
        if (parent.kind != .listbox and parent.kind != .radio_group and parent.kind != .tab_bar) return null;
        for (self.pending_listboxes[0..self.pending_listbox_count]) |group|
            if (group.id == parent.id) return group;
        return null;
    }

    fn lowerComponent(self: *UiBuild, state: *c.State) c_int {
        _ = c.lua_getiuservalue(state, 1, 1);
        const parent = self.compositionParent(state, -1) catch |err| return luaError(state, parentDataErrorMessage(err));
        const key = tableString(state, -1, "key") orelse return luaError(state, "component key is required");
        if (key.len == 0) return luaError(state, "component key is required");
        c.lua_settop(state, 1);
        self.components.push("render");
        _ = c.lua_getiuservalue(state, 1, 3);
        _ = c.lua_getiuservalue(state, 1, 1);
        _ = c.lua_getiuservalue(state, 1, 2);
        c.lua_pushinteger(state, @bitCast(self.component_namespace));
        c.lua_pushinteger(state, @bitCast(parent.id));
        if (c.lua_pcallk(state, 5, 4, 0, 0, null) != c.ok) return c.lua_error(state);
        // Stack: description, output, token, clean, mounted record.
        const retained = c.lua_toboolean(state, 4) != 0;
        var number: c_int = 0;
        const token: u64 = @intCast(c.lua_tointegerx(state, 3, &number));
        const group = semanticId("component", token ^ @as(u64, @intFromPtr(state)));
        const context: BoundaryContext = .{
            .parent = parent,
            .theme = self.currentStyle(),
            .interaction = self.interaction_owner,
            .selection = self.currentSelection(),
            .interactive = self.interactive,
            .parent_depth = self.parent_count,
            .composition_depth = self.composition_depth,
            .text_revision = self.text_configuration_revision,
        };
        self.components.push("enter");
        c.lua_pushvalue(state, 5);
        c.lua_pushboolean(state, @intFromBool(retained and self.component_scope_clean));
        if (c.lua_pcallk(state, 2, 1, 0, 0, null) != c.ok) return c.lua_error(state);
        if (!self.full_lowering and !self.retention_blocked and c.lua_type(state, -1) != c.type_nil) {
            const old: *const Boundary = @ptrCast(@alignCast(c.lua_touserdata(state, -1).?));
            if (old.safe and std.meta.eql(old.context, context)) if (self.components.instances) |tree| {
                if (old.root) |root| {
                    const marker = tree.retainDescriptor(root) catch return luaError(state, "retained component root missing");
                    self.append(marker) catch return luaError(state, "cannot retain component root");
                }
                self.appendSemantic(.{ .id = group, .parent = semanticParent(parent), .role = .group, .key = key, .retain_subtree = true }) catch
                    return luaError(state, "cannot retain component semantics");
                self.components.call("retain") catch return luaError(state, "cannot retain component mounts");
                return 0;
            };
        }
        c.lua_settop(state, 2);
        self.components.call("lower") catch return luaError(state, "cannot begin component lowering");
        self.appendSemantic(.{ .id = group, .parent = semanticParent(parent), .role = .group, .key = key }) catch
            return luaError(state, "cannot append component semantics");
        var component_parent = parent;
        component_parent.semantic_id = group;
        self.pushParent(component_parent) catch
            return luaError(state, "component nesting is too deep");
        const previous = self.component_namespace;
        self.component_namespace = group;
        const previous_clean = self.component_scope_clean;
        self.component_scope_clean = previous_clean and retained;
        const start = self.count;
        const dependent_start = self.native_dependent_count;
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, lowerDescription, 1);
        c.lua_pushvalue(state, -2);
        const status = c.lua_pcallk(state, 1, 0, 0, 0, null);
        self.component_namespace = previous;
        self.component_scope_clean = previous_clean;
        self.popParent();
        if (status != c.ok) return c.lua_error(state);
        self.components.push("leave");
        const boundary: *Boundary = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(Boundary), 0)));
        boundary.* = .{
            .context = context,
            .root = if (self.count > start) self.storage[start].id else null,
            .safe = self.native_dependent_count == dependent_start,
        };
        if (c.lua_pcallk(state, 1, 0, 0, 0, null) != c.ok) return c.lua_error(state);
        return 0;
    }

    fn lowerLayoutBuilder(self: *UiBuild, state: *c.State) c_int {
        const parent = self.currentParent() orelse return luaError(state, "layout_builder requires a parent");
        _ = c.lua_getiuservalue(state, 1, 1);
        const key = tableString(state, 2, "key") orelse return luaError(state, "layout_builder key is required");
        if (key.len == 0) return luaError(state, "layout_builder key is required");
        if (c.lua_getfield(state, 2, "render") != c.type_function) return luaError(state, "layout_builder render must be a function");
        c.lua_settop(state, -2);
        const id = semanticId(key, 0x6c61796f7574 ^ parent.id ^ self.component_namespace);
        for (self.layout_builders.entries[0..self.layout_builders.count]) |entry|
            if (entry.id == id) return luaError(state, "duplicate layout_builder key");
        if (self.layout_builders.count == self.layout_builders.entries.len) return luaError(state, "layout_builder capacity exceeded");
        const constraints = self.layout_proposals.find(id);
        self.layout_builders.entries[self.layout_builders.count] = .{ .id = id, .constraints = constraints };
        self.layout_builders.count += 1;
        const parent_data = declarativeParentData(self, state, 2) catch |err| return luaError(state, parentDataErrorMessage(err));
        self.append(.{ .id = id, .parent = parent.id, .parent_data = parent_data, .object = .{ .box = .{} } }) catch
            return luaError(state, "cannot append layout_builder");
        self.appendSemantic(.{ .id = id, .parent = semanticParent(parent), .role = .group, .key = key }) catch
            return luaError(state, "cannot append layout_builder semantics");
        const bounds = constraints orelse return 0;
        self.components.push("layout");
        c.lua_pushvalue(state, 2);
        c.lua_pushinteger(state, @bitCast(id));
        c.lua_createtable(state, 0, 4);
        inline for (.{ "min_width", "max_width", "min_height", "max_height" }) |field| {
            c.lua_pushnumber(state, @field(bounds, field));
            c.lua_setfield(state, -2, field);
        }
        c.lua_pushboolean(state, @intFromBool(self.component_scope_clean));
        if (c.lua_pcallk(state, 4, 2, 0, 0, null) != c.ok) return c.lua_error(state);
        const previous_clean = self.component_scope_clean;
        self.component_scope_clean = previous_clean and c.lua_toboolean(state, -1) != 0;
        defer self.component_scope_clean = previous_clean;
        c.lua_settop(state, -2);
        self.pushParent(.{ .id = id, .kind = .box }) catch return luaError(state, "layout_builder nesting too deep");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, lowerDescription, 1);
        c.lua_pushvalue(state, -2);
        const status = c.lua_pcallk(state, 1, 0, 0, 0, null);
        self.popParent();
        if (status != c.ok) return c.lua_error(state);
        return 0;
    }

    fn lowerVirtualList(self: *UiBuild, state: *c.State) c_int {
        const parent = self.currentParent() orelse return luaError(state, "virtual_list requires a parent");
        _ = c.lua_getiuservalue(state, 1, 1);
        const props: c_int = 2;
        const key = tableString(state, props, "key") orelse return luaError(state, "virtual_list key is required");
        const count = tableRequiredInteger(state, props, "item_count") orelse return luaError(state, "item_count must be an integer");
        if (count < 0 or count > std.math.maxInt(i32)) return luaError(state, "invalid item_count");
        inline for (.{ "item_key", "render_item" }) |name| {
            const kind = c.lua_getfield(state, props, name);
            c.lua_settop(state, -2);
            if (kind != c.type_function) return luaError(state, "item_key and render_item must be functions");
        }
        const index_kind = c.lua_getfield(state, props, "item_index");
        c.lua_settop(state, -2);
        if (index_kind != c.type_nil and index_kind != c.type_function)
            return luaError(state, "item_index must be a function");
        const reveal_kind = c.lua_getfield(state, props, "ensure_visible");
        c.lua_settop(state, -2);
        switch (reveal_kind) {
            c.type_nil => {},
            c.type_number => {
                const index = tableRequiredInteger(state, props, "ensure_visible") orelse
                    return luaError(state, "ensure_visible must be a positive integer or item key");
                if (index < 1)
                    return luaError(state, "ensure_visible must be a positive integer or item key");
            },
            c.type_string => {
                if (tableString(state, props, "ensure_visible").?.len == 0)
                    return luaError(state, "ensure_visible item key must not be empty");
                if (index_kind != c.type_function)
                    return luaError(state, "ensure_visible item key requires item_index");
            },
            else => return luaError(state, "ensure_visible must be a positive integer or item key"),
        }
        const fixed = tableOptionalNullableExtent(state, props, "item_height") orelse return luaError(state, "invalid item_height");
        const estimated = tableOptionalNullableExtent(state, props, "estimated_item_height") orelse return luaError(state, "invalid estimated_item_height");
        if ((fixed.value == null) == (estimated.value == null))
            return luaError(state, "provide exactly one of item_height and estimated_item_height");
        const estimate = fixed.value orelse estimated.value.?;
        if (estimate <= 0) return luaError(state, "item height must be positive");
        const width = tableOptionalSize(state, props, "width", .fill) orelse return luaError(state, "invalid virtual_list width");
        const height = tableOptionalSize(state, props, "height", .fill) orelse return luaError(state, "invalid virtual_list height");
        const scroll = tableScroll(state, props, self.currentTheme().?) catch return luaError(state, "invalid virtual_list scrollbar or axis");
        if (scroll.axis != .vertical) return luaError(state, "virtual_list only supports a vertical axis");
        const scroll_to = tableScrollRequest(state, props) catch return luaError(state, "scroll_to requires a finite non-negative offset and positive integer token; cannot combine with ensure_visible");
        const parent_data = declarativeParentData(self, state, props) catch |err| return luaError(state, parentDataErrorMessage(err));
        const outer = semanticId(key, 0x7669727475616c ^ parent.id ^ self.component_namespace);
        const id = semanticId("viewport", outer);
        const extent = semanticId("extent", id);
        const stack = semanticId("rows", id);
        self.components.push("virtual");
        c.lua_pushvalue(state, props);
        c.lua_pushinteger(state, @bitCast(id));
        c.lua_pushboolean(state, @intFromBool(self.component_scope_clean));
        c.lua_pushinteger(state, @intCast(self.virtual_lists.rows.len - self.virtual_lists.row_count));
        if (c.lua_pcallk(state, 4, 2, 0, 0, null) != c.ok) return c.lua_error(state);
        const retained = c.lua_toboolean(state, -1) != 0;
        c.lua_settop(state, -2);
        const plan: c_int = 3;
        const total = tableRequiredExtent(state, plan, "total") orelse return luaError(state, "virtual list extent is too large");
        if (self.virtual_lists.count == self.virtual_lists.lists.len) return luaError(state, "virtual list capacity exceeded");
        const list_index = self.virtual_lists.count;
        self.virtual_lists.count += 1;
        self.virtual_lists.lists[list_index] = .{
            .id = id,
            .width = tableRequiredExtent(state, plan, "width").?,
            .viewport = tableRequiredExtent(state, plan, "viewport").?,
            .offset = tableRequiredExtent(state, plan, "offset").?,
            .total = total,
            .estimate = estimate,
            .fixed = fixed.value != null,
            .row_start = self.virtual_lists.row_count,
            .row_count = 0,
        };
        self.append(.{ .id = outer, .parent = parent.id, .parent_data = parent_data, .object = .{ .box = .{ .width = width.extent(), .fill_width = width.isFill(), .height = height.extent(), .fill_height = height.isFill() } } }) catch return luaError(state, "cannot append virtual list");
        self.append(.{ .id = id, .parent = outer, .focusable = true, .focus_request = tableFocusRequest(state, props) catch |err| return luaError(state, @errorName(err)), .scroll_to = scroll_to, .object = .{ .scroll = scroll } }) catch return luaError(state, "cannot append virtual viewport");
        self.stageCallbackAt(state, props, id, "on_scroll", .scroll_change) catch |err| return luaError(state, @errorName(err));
        self.appendSemantic(.{ .id = id, .parent = semanticParent(parent), .role = .group, .key = key }) catch return luaError(state, "cannot append virtual semantics");
        self.append(.{ .id = extent, .parent = id, .object = .{ .box = .{ .height = total, .fill_width = true } } }) catch return luaError(state, "cannot append virtual extent");
        self.append(.{ .id = stack, .parent = extent, .object = .{ .stack = .{ .unbounded_height = true } } }) catch return luaError(state, "cannot append virtual rows");
        _ = c.lua_getfield(state, plan, "rows");
        const rows: c_int = 4;
        const row_count = c.lua_rawlen(state, rows);
        // Reserve this list's contiguous feedback before lowering nested lists.
        if (self.virtual_lists.row_count + row_count > self.virtual_lists.rows.len) return luaError(state, "virtual row capacity exceeded");
        const row_start = self.virtual_lists.row_count;
        self.virtual_lists.row_count += row_count;
        self.virtual_lists.lists[list_index].row_count = row_count;
        const previous_clean = self.component_scope_clean;
        self.component_scope_clean = previous_clean and retained;
        defer self.component_scope_clean = previous_clean;
        for (0..row_count) |index| {
            _ = c.lua_rawgeti(state, rows, @intCast(index + 1));
            const row: c_int = 5;
            const row_key = tableString(state, row, "key").?;
            const row_id = virtual_list.rowId(id, row_key);
            const y = tableRequiredExtent(state, row, "y").?;
            const row_height = tableRequiredExtent(state, row, "height").?;
            self.virtual_lists.rows[row_start + index] = .{ .id = row_id, .y = y, .height = row_height };
            self.append(.{ .id = row_id, .parent = stack, .parent_data = .{ .stack = .{ .y = y } }, .object = .{ .box = .{ .fill_width = true, .height = fixed.value, .min_height = if (fixed.value == null) 1 else 0, .clip = true } } }) catch return luaError(state, "cannot append virtual row");
            self.appendSemantic(.{ .id = row_id, .parent = id, .role = .group, .key = row_key }) catch return luaError(state, "cannot append virtual row semantics");
            self.pushParent(.{ .id = row_id, .kind = .box }) catch return luaError(state, "virtual row nesting too deep");
            c.lua_pushlightuserdata(state, self);
            c.lua_pushcclosure(state, lowerDescription, 1);
            _ = c.lua_getfield(state, row, "description");
            const status = c.lua_pcallk(state, 1, 0, 0, 0, null);
            self.popParent();
            if (status != c.ok) return c.lua_error(state);
            c.lua_settop(state, rows);
        }
        return 0;
    }

    fn append(self: *UiBuild, descriptor: instance.Descriptor) !void {
        if (self.active_owner == null) return error.ConstructorOutsideBuild;
        if (self.count == self.storage.len) return error.DescriptorCapacityExceeded;
        self.storage[self.count] = descriptor;
        self.storage[self.count].interactive = descriptor.interactive and self.interactive;
        self.count += 1;
    }

    fn appendSemantic(self: *UiBuild, descriptor: SemanticDescriptor) !void {
        if (self.semantic_count == self.semantic_storage.len)
            return error.SemanticDescriptorCapacityExceeded;
        self.semantic_storage[self.semantic_count] = descriptor;
        self.semantic_storage[self.semantic_count].enabled = descriptor.enabled and self.interactive;
        self.semantic_count += 1;
    }

    fn currentParent(self: *const UiBuild) ?BuildParent {
        if (self.parent_count == 0) return null;
        return self.parent_stack[self.parent_count - 1];
    }

    fn pushParent(self: *UiBuild, parent: BuildParent) !void {
        if (self.parent_count == self.parent_stack.len) return error.WidgetNestingTooDeep;
        self.parent_stack[self.parent_count] = parent;
        self.parent_count += 1;
    }

    fn popParent(self: *UiBuild) void {
        std.debug.assert(self.parent_count != 0);
        self.parent_count -= 1;
    }

    fn currentTheme(self: *const UiBuild) ?design.tokens.Theme {
        const value = self.currentStyle() orelse return null;
        return value.colors;
    }

    fn currentStyle(self: *const UiBuild) ?theming.Theme {
        if (self.theme_count != 0) return self.theme_stack[self.theme_count - 1];
        return self.widget_theme;
    }

    fn themedFonts(self: *UiBuild, medium: bool) ![]const text.FontHandle {
        const style = self.currentStyle().?;
        const family = style.typography.family.name();
        if (family.len != 0) {
            const fonts = self.theme_fonts orelse return error.ThemeFontServiceUnavailable;
            return fonts.get(family, medium);
        }
        return if (medium and self.medium_candidates.len != 0) self.medium_candidates else self.text_candidates;
    }

    fn pushTheme(self: *UiBuild, theme: theming.Theme) !void {
        if (self.theme_count == self.theme_stack.len) return error.WidgetNestingTooDeep;
        self.theme_stack[self.theme_count] = theme;
        self.theme_count += 1;
    }

    fn popTheme(self: *UiBuild) void {
        std.debug.assert(self.theme_count != 0);
        self.theme_count -= 1;
    }

    fn emitText(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.text expects one declaration table");
        return self.emitDeclarativeText(state);
    }

    fn emitImage(state: *c.State) callconv(.c) c_int {
        return emitImageKind(state, false);
    }

    fn emitCanvas(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        const parent = self.currentParent() orelse return luaError(state, "canvas requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "canvas key is required");
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        _ = c.lua_getfield(state, 1, "drawing");
        const drawing = @import("drawing.zig").get(state, -1) orelse return luaError(state, "canvas drawing must be a native drawing");
        const id = semanticId(key, 0x63616e766173 ^ parent.id ^ self.component_namespace);
        self.append(.{
            .id = id,
            .parent = parent.id,
            .object = .{ .canvas = drawing },
            .parent_data = parent_data,
        }) catch return luaError(state, "cannot append canvas descriptor");
        drawing.retain();
        self.drawings_staged = true;
        self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .image,
            .key = key,
            .label = tableString(state, 1, "alt") orelse "",
        }) catch return luaError(state, "cannot append canvas semantics");
        return 0;
    }

    fn emitIcon(state: *c.State) callconv(.c) c_int {
        return emitImageKind(state, true);
    }

    fn emitImageKind(state: *c.State, icon: bool) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        const theme = self.currentTheme() orelse return luaError(state, "declarative widgets unavailable");
        const parent = self.currentParent() orelse return luaError(state, "image requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "image key is required");
        const path = tableOptionalString(state, 1, "src") orelse return luaError(state, "image src must be a string");
        const bytes = tableOptionalString(state, 1, "bytes") orelse return luaError(state, "image bytes must be a string");
        const name = tableOptionalString(state, 1, "name") orelse return luaError(state, "icon name must be a string");
        const icon_theme = tableOptionalString(state, 1, "theme") orelse return luaError(state, "icon theme must be a string");
        if ((!icon and name.present) or (icon_theme.present and !name.present) or
            @as(u8, @intFromBool(path.present)) + @as(u8, @intFromBool(bytes.present)) + @as(u8, @intFromBool(name.present)) != 1)
            return luaError(state, "image expects exactly one src or bytes; icons also accept name and optional theme");
        const width = tableOptionalSize(state, 1, "width", if (icon) .{ .exact = 24 } else .auto) orelse
            return luaError(state, "invalid image width");
        const height = tableOptionalSize(state, 1, "height", if (icon) .{ .exact = 24 } else .auto) orelse
            return luaError(state, "invalid image height");
        if (icon and (width.isFill() or height.isFill())) return luaError(state, "icon dimensions must be numeric");
        const logical_width = width.extent();
        const logical_height = height.extent();
        var fit: image_pixels.Fit = .contain;
        const fit_type = c.lua_getfield(state, 1, "fit");
        if (fit_type != c.type_nil) {
            const fit_name = string(state, -1) orelse return luaError(state, "invalid image fit");
            fit = std.meta.stringToEnum(image_pixels.Fit, fit_name) orelse return luaError(state, "invalid image fit");
        }
        c.lua_settop(state, -2);
        var tint: ?@import("../core/color.zig").Color = if (icon and
            (!name.present or std.mem.endsWith(u8, name.value, "-symbolic"))) theme.foreground else null;
        if (c.lua_getfield(state, 1, "tint") != c.type_nil)
            tint = theming.color(state, -1) catch |err| return luaError(state, @errorName(err));
        c.lua_settop(state, -2);
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const active = self.active_owner.?;
        const source: image_service.Source = if (name.present) .{ .icon = .{
            .name = name.value,
            .theme = if (icon_theme.present) icon_theme.value else "hicolor",
            .size = (rasterDimension(@max(logical_width.?, logical_height.?), 1) catch return luaError(state, "icon too large")).?,
            .scale = (rasterDimension(1, self.image_scale) catch return luaError(state, "icon scale too large")).?,
        } } else if (path.present) .{ .path = path.value } else .{ .bytes = bytes.value };
        // A host without an image service behaves like a failed asset: the
        // leaf keeps its declared dimensions and paints nothing.
        const handle = if (self.images) |images| images.request(
            source,
            .{
                .width = rasterDimension(logical_width, self.image_scale) catch return luaError(state, "image raster too large"),
                .height = rasterDimension(logical_height, self.image_scale) catch return luaError(state, "image raster too large"),
                .tint = tint,
                .scale = self.image_scale,
            },
            .{ .owners = active.owners, .handle = active.handle },
        ) catch |err| return luaError(state, @errorName(err)) else null;
        if (handle) |value| self.images.?.cache.retain(value) catch |err| return luaError(state, @errorName(err));
        const id = semanticId(key, 0x696d616765 ^ parent.id ^ self.component_namespace);
        self.append(.{
            .id = id,
            .parent = parent.id,
            .object = .{ .image = .{
                .image = handle,
                .width = logical_width,
                .height = logical_height,
                .fill_width = width.isFill(),
                .fill_height = height.isFill(),
                .fit = fit,
            } },
            .parent_data = parent_data,
        }) catch {
            if (handle) |value| self.images.?.cache.release(value) catch unreachable;
            return luaError(state, "cannot append image descriptor");
        };
        self.images_staged = true;
        self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .image,
            .key = key,
            .label = tableString(state, 1, "alt") orelse "",
        }) catch return luaError(state, "cannot append image semantics");
        return 0;
    }

    fn emitTextEditor(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        const theme = self.currentTheme() orelse return luaError(state, "declarative widgets unavailable");
        const defaults = self.currentStyle().?;
        const visual = theming.widgetOverrides(state, .{}, true) catch |err| return luaError(state, @errorName(err));
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.text_editor expects one declaration table");
        const parent = self.currentParent() orelse return luaError(state, "text_input requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "text_input key is required");
        const controlled = tableOptionalString(state, 1, "text") orelse
            return luaError(state, "text_input text must be a string");
        const uncontrolled = tableOptionalString(state, 1, "default_text") orelse
            return luaError(state, "text_input default_text must be a string");
        const placeholder = tableOptionalString(state, 1, "placeholder") orelse
            return luaError(state, "text_input placeholder must be a string");
        const label = tableOptionalString(state, 1, "label") orelse
            return luaError(state, "text_input label must be a string");
        // A conversation binds the field to an authentication prompt: its
        // text goes natively to PAM on submit and never reaches Lua.
        const conversation_type = c.lua_getfield(state, 1, "conversation");
        c.lua_settop(state, -2);
        const secret: ?@import("../ui/text_input/secret.zig").Secret = if (conversation_type == c.type_nil) null else @import("auth.zig").secretFromTable(state, 1) catch |err| return luaError(state, @errorName(err));
        const mask = tableOptionalBoolean(state, 1, "mask", secret != null) orelse
            return luaError(state, "text_input mask must be a boolean");
        if (secret != null) {
            if (!mask) return luaError(state, "text_input with a conversation must be masked");
            if (controlled.present or uncontrolled.present)
                return luaError(state, "text_input with a conversation never accepts text or default_text");
            const change_type = c.lua_getfield(state, 1, "on_change");
            c.lua_settop(state, -2);
            if (change_type != c.type_nil) return luaError(state, "text_input with a conversation never accepts on_change");
        } else if (controlled.present == uncontrolled.present)
            return luaError(state, "text_input requires exactly one of text or default_text");
        const mode: TextInputValueMode = if (controlled.present) .controlled else .uncontrolled;
        const multiline = tableOptionalBoolean(state, 1, "multiline", false) orelse
            return luaError(state, "text_input multiline must be a boolean");
        if (mask and multiline) return luaError(state, "text_input mask requires a single-line field");
        const width = tableOptionalSize(state, 1, "width", .fill) orelse
            return luaError(state, "invalid text_input width");
        const height = tableOptionalSize(state, 1, "height", .auto) orelse
            return luaError(state, "invalid text_editor height");
        const padding = tableOptionalExtent(state, 1, "padding", 0) orelse
            return luaError(state, "invalid text_editor padding");
        const padding_x = visual.padding_x orelse padding;
        const padding_y = tableOptionalExtent(state, 1, "padding_y", padding) orelse
            return luaError(state, "invalid text_editor padding_y");
        const alignment = tableOptionalBoxAlignment(state, 1) orelse
            return luaError(state, "invalid text_editor alignment");
        const caret_shape = tableOptionalEnum(render_types.CaretShape, state, 1, "caret_shape", .beam) orelse
            return luaError(state, "invalid caret_shape; expected beam, block, or underline");
        var colors = .{
            .placeholder_color = theme.muted_foreground,
            .selection_color = theme.selection,
            .caret_color = visual.foreground orelse theme.foreground,
        };
        inline for (.{ "placeholder_color", "selection_color", "caret_color" }) |field| {
            if (c.lua_getfield(state, 1, field) != c.type_nil)
                @field(colors, field) = theming.color(state, -1) catch |err| return luaError(state, @errorName(err));
            c.lua_settop(state, -2);
        }
        const enabled = tableOptionalBoolean(state, 1, "enabled", true) orelse
            return luaError(state, "text_input enabled must be a boolean");
        const read_only = tableOptionalBoolean(state, 1, "read_only", false) orelse
            return luaError(state, "text_input read_only must be a boolean");
        const text_entry = tableOptionalBoolean(state, 1, "text_entry", true) orelse
            return luaError(state, "text_input text_entry must be a boolean");
        const caret_blink = tableOptionalBoolean(state, 1, "caret_blink", true) orelse
            return luaError(state, "text_input caret_blink must be a boolean");
        const autofocus = tableOptionalBoolean(state, 1, "autofocus", false) orelse
            return luaError(state, "text_input autofocus must be a boolean");
        var bindings = @import("key_bindings.zig").field(state, 1, "key_bindings", self.text_input_bindings) catch |err|
            return luaError(state, @errorName(err));
        bindings.multiline = multiline;
        const target_id = semanticId(key, 0x74657874696e7075 ^ parent.id ^ self.component_namespace);
        const content_id = semanticId(key, 0x636f6e74656e74 ^ target_id);
        const border_width = visual.border_width orelse 0;
        const sources = self.text_sources orelse return luaError(state, "text service unavailable");
        if (self.pending_text_input_count == self.pending_text_inputs.len)
            return luaError(state, "text_input capacity exceeded");
        const controller = @import("editor.zig").fromTable(state, 1) catch |err| return luaError(state, @errorName(err));
        // Stage ownership before any Lua error can longjmp past Zig cleanup.
        self.pending_text_inputs[self.pending_text_input_count] = .{
            .target_id = target_id,
            .content_id = content_id,
            .mode = mode,
            .behavior = .{ .enabled = enabled, .read_only = read_only, .text_entry = text_entry, .caret_blink = caret_blink, .autofocus = autofocus, .key_bindings = bindings, .border_color = visual.border, .focus_color = visual.focus orelse theme.ring, .secret = secret },
            .session = if (mask)
                TextInputSession.initSecret(sources.allocator) catch return luaError(state, "cannot create masked text_input session")
            else
                TextInputSession.initWithMode(
                    sources.allocator,
                    if (controlled.present) controlled.value else uncontrolled.value,
                    multiline,
                ) catch return luaError(state, "cannot create text_input session"),
        };
        const pending_session = &self.pending_text_inputs[self.pending_text_input_count].session.?;
        self.pending_text_inputs[self.pending_text_input_count].behavior.controller = controller;
        if (controller) |value| value.retain();
        self.pending_text_input_count += 1;
        if (mask and secret == null) {
            const value = if (controlled.present) controlled.value else uncontrolled.value;
            _ = pending_session.model.replaceSelection(value) catch return luaError(state, "invalid masked text_input text");
        }
        // Masked fields draw one dot per grapheme; the value stays in the session.
        var mask_buffer: [@import("../ui/text_input/model.zig").secret_capacity * 3]u8 = undefined;
        const initial = if (mask) blk: {
            const count = pending_session.model.graphemeCount();
            for (0..count) |i| @memcpy(mask_buffer[i * 3 ..][0..3], "•");
            break :blk mask_buffer[0 .. count * 3];
        } else pending_session.model.text();
        self.append(.{
            .id = target_id,
            .parent = parent.id,
            .object = .{ .box = .{
                .width = width.extent(),
                .fill_width = width.isFill(),
                .height = height.extent(),
                .fill_height = height.isFill(),
                .padding = .{ .left = padding_x, .right = padding_x, .top = padding_y, .bottom = padding_y },
                .alignment = alignment.value,
                .background = visual.background,
                .border_color = if (border_width > 0) visual.border else null,
                .border_width = border_width,
                .corner_radius = visual.radius orelse 0,
            } },
            .focusable = enabled,
            .focus_request = tableFocusRequest(state, 1) catch |err| return luaError(state, @errorName(err)),
            .parent_data = declarativeParentData(self, state, 1) catch |err|
                return luaError(state, parentDataErrorMessage(err)),
        }) catch return luaError(state, "cannot append text_input descriptor");

        const source = sources.acquire(.{
            .utf8 = initial,
            .language = "und",
            .logical_size = visual.font_size orelse defaults.typography.size orelse design.tokens.foundation.typography_2,
            .candidates = self.themedFonts(false) catch |err| return luaError(state, @errorName(err)),
            .configuration_revision = self.text_configuration_revision,
        }) catch return luaError(state, "cannot retain text_input text");
        const placeholder_source = if (placeholder.present and placeholder.value.len != 0) sources.acquire(.{
            .utf8 = placeholder.value,
            .language = "und",
            .logical_size = visual.font_size orelse defaults.typography.size orelse design.tokens.foundation.typography_2,
            .candidates = (sources.get(source) catch unreachable).candidates,
            .configuration_revision = self.text_configuration_revision,
        }) catch {
            sources.release(source) catch unreachable;
            return luaError(state, "cannot retain text_input placeholder");
        } else null;
        self.append(.{
            .id = content_id,
            .parent = target_id,
            .object = .{ .text_input = .{
                .source = source,
                .multiline = multiline,
                .placeholder = placeholder_source,
                .placeholder_color = colors.placeholder_color,
                .color = visual.foreground orelse theme.foreground,
                .selection_color = colors.selection_color,
                .caret_color = colors.caret_color,
                .caret_shape = caret_shape,
                .selection_start = initial.len,
                .selection_end = initial.len,
                .caret_offset = initial.len,
                .preedit_color = null,
            } },
        }) catch {
            if (placeholder_source) |hint| sources.release(hint) catch unreachable;
            sources.release(source) catch unreachable;
            return luaError(state, "cannot append text_input content");
        };
        self.sources_staged = true;
        self.appendSemantic(.{
            .id = target_id,
            .parent = semanticParent(parent),
            .role = .text_field,
            .key = key,
            .label = if (label.present) label.value else if (mask) (if (placeholder.present) placeholder.value else "Password") else initial,
            .enabled = enabled,
        }) catch return luaError(state, "cannot append text_input semantics");

        const names = [_]struct { name: [*:0]const u8, kind: @import("../ui/input/bindings.zig").HandlerKind }{
            .{ .name = "on_change", .kind = .text_input_change },
            .{ .name = "on_command", .kind = .text_input_command },
        };
        for (names) |callback| {
            const callback_type = c.lua_getfield(state, 1, callback.name);
            defer c.lua_settop(state, -2);
            if (callback_type == c.type_nil) continue;
            if (callback_type != c.type_function) return luaError(state, "text_input callback must be a function");
            if (self.pending_handler_count == self.pending_handlers.len)
                return luaError(state, "input handler capacity exceeded");
            c.lua_pushvalue(state, -1);
            self.pending_handlers[self.pending_handler_count] = .{
                .id = target_id,
                .reference = c.luaL_ref(state, c.registry_index),
                .kind = callback.kind,
            };
            self.pending_handler_count += 1;
        }
        return 0;
    }

    fn emitSplit(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (self.currentTheme() == null) return luaError(state, "declarative widgets unavailable");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.split expects one declaration table");
        if (c.lua_rawlen(state, c.upvalueIndex(2)) != 3)
            return luaError(state, "split requires two panes and divider content");
        const parent = self.currentParent() orelse return luaError(state, "split requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "split key is required");
        const axis = tableOptionalAxis(state, 1, "axis", .horizontal) orelse return luaError(state, "invalid split axis");
        const position = tableOptionalFraction(state, 1, "position", 0.5) orelse return luaError(state, "split position must be between zero and one");
        const min_first = tableOptionalExtent(state, 1, "min_first", 0) orelse return luaError(state, "invalid split min_first");
        const min_second = tableOptionalExtent(state, 1, "min_second", 0) orelse return luaError(state, "invalid split min_second");
        const divider_size = tableOptionalExtent(state, 1, "divider_size", 8) orelse return luaError(state, "invalid split divider_size");
        const parent_data = declarativeParentData(self, state, 1) catch |err| return luaError(state, parentDataErrorMessage(err));
        const id = semanticId(key, 0x73706c6974 ^ parent.id ^ self.component_namespace);
        const divider = semanticId("divider", id);
        self.append(.{ .id = id, .parent = parent.id, .parent_data = parent_data, .object = .{ .split = .{
            .axis = axis,
            .position = position,
            .min_first = min_first,
            .min_second = min_second,
            .divider = divider_size,
        } } }) catch return luaError(state, "cannot append split descriptor");
        self.appendSemantic(.{ .id = id, .parent = semanticParent(parent), .role = .group, .key = key }) catch return luaError(state, "cannot append split semantics");
        self.pushParent(.{ .id = id, .kind = .split, .semantic_id = id }) catch return luaError(state, "split nesting is too deep");
        for (1..3) |index| {
            c.lua_pushlightuserdata(state, self);
            c.lua_pushcclosure(state, lowerDescription, 1);
            _ = c.lua_rawgeti(state, c.upvalueIndex(2), @intCast(index));
            if (c.lua_pcallk(state, 1, 0, 0, 0, null) != c.ok) {
                self.popParent();
                return c.lua_error(state);
            }
        }
        self.popParent();
        // The resize slot owns input and semantics, but no visual recipe.
        // Its child inherits native interaction state for declarative paint.
        self.append(.{ .id = divider, .parent = id, .focusable = true, .focus_request = tableFocusRequest(state, 1) catch |err| return luaError(state, @errorName(err)), .object = .{ .box = .{} } }) catch return luaError(state, "cannot append split divider");
        if (self.pending_button_count == self.pending_buttons.len) return luaError(state, "button capacity exceeded");
        self.pending_buttons[self.pending_button_count] = .{ .id = divider, .enabled = true };
        self.pending_button_count += 1;
        self.appendSemantic(.{ .id = divider, .parent = id, .role = .separator, .key = "divider" }) catch return luaError(state, "cannot append split divider semantics");
        self.stageCallback(state, divider, "on_change", .split_change) catch |err| return luaError(state, @errorName(err));
        const previous_owner = self.interaction_owner;
        self.interaction_owner = .{ .id = divider };
        defer self.interaction_owner = previous_owner;
        self.pushParent(.{ .id = divider, .kind = .box }) catch return luaError(state, "split nesting is too deep");
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, lowerDescription, 1);
        _ = c.lua_rawgeti(state, c.upvalueIndex(2), 3);
        const status = c.lua_pcallk(state, 1, 0, 0, 0, null);
        self.popParent();
        if (status != c.ok) return c.lua_error(state);
        return 0;
    }

    fn emitDeclarativeText(self: *UiBuild, state: *c.State) c_int {
        const theme = self.currentTheme() orelse return luaError(state, "declarative widgets unavailable");
        const defaults = self.currentStyle().?;
        const visual = theming.widgetOverrides(state, defaults.widgets.text, false) catch |err| return luaError(state, @errorName(err));
        const parent = self.currentParent() orelse return luaError(state, "text requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "text key is required");
        const logical_size = tableOptionalExtent(
            state,
            1,
            "size",
            visual.font_size orelse defaults.typography.size orelse design.tokens.foundation.typography_3,
        ) orelse return luaError(state, "invalid text size");
        const alignment = tableOptionalParagraphAlignment(state, 1, "alignment", .start) orelse
            return luaError(state, "invalid text alignment; expected start, center, end, or justify (logical, not left/right)");
        const max_lines_value = tableOptionalPositiveInteger(state, 1, "max_lines", 0) orelse
            return luaError(state, "invalid text max_lines");
        const overflow = tableOptionalParagraphOverflow(state, 1, "overflow", .clip) orelse
            return luaError(state, "invalid text overflow");
        if (overflow == .ellipsis and max_lines_value == 0)
            return luaError(state, "text ellipsis requires max_lines");
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const sources = self.text_sources orelse return luaError(state, "text service unavailable");
        const weight = tableOptionalEnum(TextWeight, state, 1, "weight", .normal) orelse
            return luaError(state, "text weight must be normal or medium");
        const paint = readInteractionPaint(state, self.interaction_owner, visual.foreground orelse theme.foreground, null, false) catch |err|
            return luaError(state, @errorName(err));
        const source = self.retainDeclarativeText(state, logical_size, weight) catch |err|
            return luaError(state, @errorName(err));
        const value = (sources.get(source) catch unreachable).utf8;
        const id = semanticId(key, 0x6c6162656c ^ parent.id ^ self.component_namespace);
        self.append(.{
            .id = id,
            .parent = parent.id,
            .interaction_paint = paint,
            .object = .{ .text = .{
                .source = source,
                .color = if (paint) |p| self.interaction_owner.?.initialColor(p).? else visual.foreground orelse theme.foreground,
                .alignment = alignment,
                .max_lines = if (max_lines_value == 0) null else max_lines_value,
                .overflow = overflow,
            } },
            .parent_data = parent_data,
        }) catch {
            sources.release(source) catch unreachable;
            return luaError(state, "cannot append text descriptor");
        };
        self.sources_staged = true;
        const semantic = tableOptionalBoolean(state, 1, "semantic", true) orelse return luaError(state, "semantic must be boolean");
        if (semantic and value.len != 0) self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .text,
            .key = key,
            .label = value,
        }) catch return luaError(state, "cannot append text semantics");
        self.emitTextLinks(state, id, source, semantic) catch |err| return luaError(state, @errorName(err));
        return 0;
    }

    /// Uses the same source/font policy and shaping as rendered text. Available
    /// during builds so inherited typography is unambiguous.
    fn measureText(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "measure_text requires a UI build");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "measure_text expects one text declaration table");
        const defaults = self.currentStyle() orelse return luaError(state, "measure_text requires a theme");
        const visual = theming.widgetOverrides(state, defaults.widgets.text, false) catch |err| return luaError(state, @errorName(err));
        const size = tableOptionalExtent(state, 1, "size", visual.font_size orelse defaults.typography.size orelse design.tokens.foundation.typography_3) orelse return luaError(state, "invalid text size");
        const width = tableOptionalExtent(state, 1, "max_width", 16384) orelse return luaError(state, "invalid text max_width");
        const weight = tableOptionalEnum(TextWeight, state, 1, "weight", .normal) orelse return luaError(state, "invalid text weight");
        const max_lines = tableOptionalPositiveInteger(state, 1, "max_lines", 0) orelse return luaError(state, "invalid text max_lines");
        const overflow = tableOptionalParagraphOverflow(state, 1, "overflow", .clip) orelse return luaError(state, "invalid text overflow");
        if (overflow == .ellipsis and max_lines == 0) return luaError(state, "text ellipsis requires max_lines");
        const sources = self.text_sources orelse return luaError(state, "text service unavailable");
        const paragraphs = self.paragraphs orelse return luaError(state, "text measurement unavailable");
        const source = self.retainDeclarativeText(state, size, weight) catch |err| return luaError(state, @errorName(err));
        const value = sources.get(source) catch unreachable;
        const handle = paragraphs.acquire(.{
            .utf8 = value.utf8,
            .base_direction = value.base_direction,
            .language = value.language,
            .logical_size = value.logical_size,
            .max_width = width,
            .candidates = value.candidates,
            .runs = value.runs,
            .configuration_revision = value.configuration_revision,
            .style = .{ .max_lines = if (max_lines == 0) null else max_lines, .overflow = overflow },
        }) catch |err| {
            sources.release(source) catch unreachable;
            return luaError(state, @errorName(err));
        };
        const layout = paragraphs.get(handle) catch unreachable;
        const measured_width = @min(width, layout.positioned.contentWidth());
        const measured_height = layout.size.height;
        paragraphs.release(handle) catch unreachable;
        sources.release(source) catch unreachable;
        c.lua_createtable(state, 0, 2);
        c.lua_pushnumber(state, measured_width);
        c.lua_setfield(state, -2, "width");
        c.lua_pushnumber(state, measured_height);
        c.lua_setfield(state, -2, "height");
        return 1;
    }

    const TextWeight = enum { normal, medium };

    fn emitTextLinks(self: *UiBuild, state: *c.State, parent: u64, source: text.ParagraphSourceHandle, semantic: bool) !void {
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        if (c.lua_getfield(state, 1, "spans") == c.type_nil) return;
        const spans = c.lua_gettop(state);
        const retained = try self.text_sources.?.get(source);
        const theme = self.currentTheme().?;
        for (retained.runs, 0..) |run, i| {
            _ = c.lua_rawgeti(state, spans, @intCast(i + 1));
            const span = c.lua_gettop(state);
            if (c.lua_getfield(state, span, "on_press") != c.type_nil) {
                if (!semantic) return error.LinkRequiresSemantics;
                if (self.interaction_owner != null) return error.LinkInsideControl;
                const key = tableString(state, span, "key") orelse return error.LinkKeyRequired;
                const enabled = tableOptionalBoolean(state, span, "enabled", true) orelse return error.InvalidLinkEnabled;
                const id = semanticId(key, 0x6c696e6b ^ parent ^ self.component_namespace);
                if (self.pending_button_count == self.pending_buttons.len) return error.InputHandlerCapacityExceeded;
                self.pending_buttons[self.pending_button_count] = .{ .id = id, .enabled = enabled };
                self.pending_button_count += 1;
                try self.stageCallbackAt(state, span, id, "on_press", .button);
                const color = run.color orelse theme.accent_text;
                try self.append(.{
                    .id = id,
                    .parent = parent,
                    .focusable = enabled,
                    .object = .{ .box = .{ .background = color } },
                    .parent_data = .{ .text_range = .{ .start = run.byte_start, .end = run.byte_end } },
                    .interaction_paint = .{ .source = id, .idle = color, .hover = theme.accent_text, .pressed = theme.foreground, .focus = theme.ring },
                });
                try self.appendSemantic(.{ .id = id, .parent = parent, .role = .link, .key = key, .label = retained.utf8[run.byte_start..run.byte_end], .enabled = enabled });
            }
            c.lua_settop(state, spans);
        }
    }

    fn retainDeclarativeText(self: *UiBuild, state: *c.State, size: f32, weight: TextWeight) !text.ParagraphSourceHandle {
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        const sources = self.text_sources.?;
        const candidates = try self.themedFonts(weight == .medium);
        const spans_type = c.lua_getfield(state, 1, "spans");
        if (spans_type == c.type_nil) return sources.acquire(.{
            .utf8 = tableString(state, 1, "text") orelse return error.TextContentRequired,
            .language = "und",
            .logical_size = size,
            .candidates = candidates,
            .configuration_revision = self.text_configuration_revision,
        });
        if (spans_type != c.type_table) return error.InvalidTextSpans;
        const spans = c.lua_gettop(state);
        if (c.lua_getfield(state, 1, "text") != c.type_nil) return error.TextAndSpansAreExclusive;
        c.lua_settop(state, spans);
        const count = c.lua_rawlen(state, spans);
        if (count == 0) return error.InvalidTextSpans;
        // Reject sparse arrays and named entries, rather than silently losing text.
        c.lua_pushnil(state);
        while (c.lua_next(state, spans) != 0) {
            var valid: c_int = 0;
            const index = c.lua_tointegerx(state, -2, &valid);
            if (c.lua_isinteger(state, -2) == 0 or valid == 0 or index < 1 or index > count)
                return error.InvalidTextSpans;
            c.lua_settop(state, -2);
        }
        const allocator = sources.allocator;
        var utf8: std.ArrayList(u8) = .empty;
        defer utf8.deinit(allocator);
        var runs: std.ArrayList(text.StyledRun) = .empty;
        defer runs.deinit(allocator);
        var fonts: std.ArrayList(text.FontHandle) = .empty;
        defer fonts.deinit(allocator);
        for (0..count) |i| {
            if (c.lua_rawgeti(state, spans, @intCast(i + 1)) != c.type_table) return error.InvalidTextSpans;
            const span = c.lua_gettop(state);
            const content = tableString(state, span, "text") orelse return error.TextContentRequired;
            if (content.len == 0) return error.EmptyTextSpan;
            const span_size = tableOptionalExtent(state, span, "size", size) orelse return error.InvalidTextSize;
            const span_weight = tableOptionalEnum(TextWeight, state, span, "weight", weight) orelse return error.InvalidTextWeight;
            var color: ?@import("../core/color.zig").Color = if (c.lua_getfield(state, span, "foreground") == c.type_nil) null else try theming.color(state, -1);
            c.lua_settop(state, span);
            if (c.lua_getfield(state, span, "on_press") != c.type_nil) {
                const enabled = tableOptionalBoolean(state, span, "enabled", true) orelse return error.InvalidLinkEnabled;
                color = if (enabled) color orelse self.currentTheme().?.accent_text else self.currentTheme().?.disabled_foreground;
            }
            c.lua_settop(state, span);
            const selected = try self.themedFonts(span_weight == .medium);
            const start = utf8.items.len;
            try utf8.appendSlice(allocator, content);
            try runs.append(allocator, .{
                .byte_start = start,
                .byte_end = utf8.items.len,
                .logical_size = span_size,
                .candidate_start = fonts.items.len,
                .candidate_count = selected.len,
                .color = color,
            });
            try fonts.appendSlice(allocator, selected);
            c.lua_settop(state, spans);
        }
        return sources.acquire(.{
            .utf8 = utf8.items,
            .language = "und",
            .logical_size = size,
            .candidates = fonts.items,
            .runs = runs.items,
            .configuration_revision = self.text_configuration_revision,
        });
    }

    fn emitRow(state: *c.State) callconv(.c) c_int {
        return emitFlexContainer(state, .horizontal);
    }

    fn emitColumn(state: *c.State) callconv(.c) c_int {
        return emitFlexContainer(state, .vertical);
    }

    fn emitGrid(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (self.currentTheme() == null) return luaError(state, "declarative widgets unavailable");
        const parent = self.currentParent() orelse return luaError(state, "grid requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "grid key is required");
        const value: render_types.Grid = .{
            .columns = tableGridTracks(state, 1, "columns") orelse return luaError(state, "invalid grid columns"),
            .rows = tableGridTracks(state, 1, "rows") orelse return luaError(state, "invalid grid rows"),
            .column_gap = tableOptionalExtent(state, 1, "column_gap", 0) orelse return luaError(state, "invalid grid column_gap"),
            .row_gap = tableOptionalExtent(state, 1, "row_gap", 0) orelse return luaError(state, "invalid grid row_gap"),
        };
        const semantic = tableOptionalBoolean(state, 1, "semantic", true) orelse return luaError(state, "semantic must be boolean");
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const id = semanticId(key, 0x67726964 ^ parent.id ^ self.component_namespace);
        self.append(.{
            .id = id,
            .parent = parent.id,
            .object = .{ .grid = value },
            .parent_data = parent_data,
        }) catch return luaError(state, "cannot append grid descriptor");
        if (semantic) self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .group,
            .key = key,
        }) catch return luaError(state, "cannot append grid semantics");
        return self.emitChildren(state, .{
            .id = id,
            .kind = .grid,
            .grid_columns = value.columns.len,
            .grid_rows = value.rows.len,
            .semantic_id = if (semantic) id else semanticParent(parent),
        });
    }

    fn emitStack(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (self.currentTheme() == null) return luaError(state, "declarative widgets unavailable");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.stack expects one declaration table");
        const parent = self.currentParent() orelse return luaError(state, "stack requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "stack key is required");
        const semantic = tableOptionalBoolean(state, 1, "semantic", true) orelse return luaError(state, "semantic must be boolean");
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const id = semanticId(key, 0x737461636b ^ parent.id ^ self.component_namespace);
        self.append(.{
            .id = id,
            .parent = parent.id,
            .object = .{ .stack = .{} },
            .parent_data = parent_data,
        }) catch return luaError(state, "cannot append stack descriptor");
        if (semantic) self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .group,
            .key = key,
        }) catch return luaError(state, "cannot append stack semantics");
        // Keep public placement separate from the internal root's legacy x/y.
        return self.emitChildren(state, .{ .id = id, .kind = .positioned_stack, .semantic_id = if (semantic) id else semanticParent(parent) });
    }

    fn emitAnchored(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (self.currentTheme() == null) return luaError(state, "declarative widgets unavailable");
        const parent = self.currentParent() orelse return luaError(state, "anchored requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "anchored key is required");
        const count = c.lua_rawlen(state, c.upvalueIndex(2));
        if (count < 1 or count > 2) return luaError(state, "anchored requires a trigger and optional floating content");
        const value: render_types.Anchored = .{
            .side = tableOptionalEnum(render_types.Anchored.Side, state, 1, "side", .bottom) orelse
                return luaError(state, "invalid anchored side"),
            .alignment = tableOptionalEnum(render_types.Anchored.Alignment, state, 1, "alignment", .start) orelse
                return luaError(state, "invalid anchored alignment"),
            .gap = tableOptionalExtent(state, 1, "gap", 4) orelse return luaError(state, "invalid anchored gap"),
            .margin = tableOptionalExtent(state, 1, "margin", 8) orelse return luaError(state, "invalid anchored margin"),
            .flip = tableOptionalBoolean(state, 1, "flip", true) orelse return luaError(state, "anchored flip must be boolean"),
        };
        const semantic = tableOptionalBoolean(state, 1, "semantic", true) orelse return luaError(state, "semantic must be boolean");
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const id = semanticId(key, 0x616e63686f726564 ^ parent.id ^ self.component_namespace);
        self.append(.{ .id = id, .parent = parent.id, .object = .{ .anchored = value }, .parent_data = parent_data }) catch
            return luaError(state, "cannot append anchored descriptor");
        if (semantic) self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .group,
            .key = key,
        }) catch return luaError(state, "cannot append anchored semantics");
        return self.emitChildren(state, .{ .id = id, .kind = .overlay, .semantic_id = if (semantic) id else semanticParent(parent) });
    }

    fn emitBox(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        const theme = self.currentTheme() orelse return luaError(state, "declarative widgets unavailable");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.box expects one declaration table");
        const parent = self.currentParent() orelse return luaError(state, "box requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "box key is required");
        const width = tableOptionalSize(state, 1, "width", .auto) orelse
            return luaError(state, "invalid box width");
        const height = tableOptionalSize(state, 1, "height", .auto) orelse
            return luaError(state, "invalid box height");
        const height_factor_kind = c.lua_getfield(state, 1, "height_factor");
        c.lua_settop(state, -2);
        const height_factor: ?f32 = if (height_factor_kind == c.type_nil) null else tableOptionalFraction(state, 1, "height_factor", 1) orelse
            return luaError(state, "box height_factor must be a finite number from zero to one");
        if (height_factor != null and (height.extent() != null or height.isFill()))
            return luaError(state, "box height_factor conflicts with height");
        const ratio_kind = c.lua_getfield(state, 1, "aspect_ratio");
        const aspect_ratio: ?f32 = if (ratio_kind == c.type_nil) null else if (ratio_kind == c.type_number)
            finiteFloat(state, -1) orelse return luaError(state, "aspect_ratio must be a finite positive number")
        else
            return luaError(state, "aspect_ratio must be a finite positive number");
        c.lua_settop(state, -2);
        if (aspect_ratio) |ratio| if (ratio <= 0)
            return luaError(state, "aspect_ratio must be a finite positive number");
        const min_width = tableOptionalExtent(state, 1, "min_width", 0) orelse
            return luaError(state, "invalid box min_width");
        const min_height = tableOptionalExtent(state, 1, "min_height", 0) orelse
            return luaError(state, "invalid box min_height");
        const max_width_kind = c.lua_getfield(state, 1, "max_width");
        if (max_width_kind != c.type_nil and max_width_kind != c.type_number)
            return luaError(state, "box maxima must be numbers");
        const max_height_kind = c.lua_getfield(state, 1, "max_height");
        if (max_height_kind != c.type_nil and max_height_kind != c.type_number)
            return luaError(state, "box maxima must be numbers");
        const max_width: OptionalExtent = .{ .value = if (max_width_kind == c.type_nil) null else requiredExtent(state, -2) orelse return luaError(state, "invalid box max_width") };
        const max_height: OptionalExtent = .{ .value = if (max_height_kind == c.type_nil) null else requiredExtent(state, -1) orelse return luaError(state, "invalid box max_height") };
        c.lua_settop(state, -3);
        if (max_width.value) |maximum| {
            if (maximum < min_width or (width.extent() != null and width.extent().? > maximum))
                return luaError(state, "box max_width conflicts with minimum or width");
        }
        if (max_height.value) |maximum| {
            if (maximum < min_height or (height.extent() != null and height.extent().? > maximum))
                return luaError(state, "box max_height conflicts with minimum or height");
        }
        const opacity = tableOptionalFraction(state, 1, "opacity", 1) orelse
            return luaError(state, "box opacity must be a finite number from zero to one");
        const transform = tableOptionalTransform(state, 1) catch
            return luaError(state, "box transform requires finite x/y/origin and a positive uniform scale");
        if (width.extent()) |value| if (value < min_width)
            return luaError(state, "box width must be at least min_width");
        if (height.extent()) |value| if (value < min_height)
            return luaError(state, "box height must be at least min_height");
        const padding = tableOptionalExtent(state, 1, "padding", 0) orelse
            return luaError(state, "invalid box padding");
        const padding_x = tableOptionalExtent(state, 1, "padding_x", padding) orelse
            return luaError(state, "invalid box padding_x");
        const padding_y = tableOptionalExtent(state, 1, "padding_y", padding) orelse
            return luaError(state, "invalid box padding_y");
        var insets: @import("../core/geometry.zig").Insets = .{ .left = padding_x, .right = padding_x, .top = padding_y, .bottom = padding_y };
        inline for (.{ "left", "right", "top", "bottom" }) |edge| {
            const kind = c.lua_getfield(state, 1, "padding_" ++ edge);
            if (kind != c.type_nil and kind != c.type_number) return luaError(state, "box edge padding must be a finite non-negative number");
            if (kind != c.type_nil) @field(insets, edge) = requiredExtent(state, -1) orelse
                return luaError(state, "box edge padding must be a finite non-negative number");
            c.lua_settop(state, -2);
        }
        const alignment = tableOptionalBoxAlignment(state, 1) orelse
            return luaError(state, "invalid box alignment");
        const surface = tableOptionalSurface(state, 1, theme) orelse
            return luaError(state, "box surface must be 'background', 'card', 'popover', or 'sidebar'");
        const shadow = tableOptionalShadow(state, 1) catch
            return luaError(state, "box shadow requires a color and finite x/y/spread and nonnegative blur");
        var visual: theming.Overrides = .{};
        const background_kind = c.lua_getfield(state, 1, "background");
        const background_gradient = @import("paint.zig").get(state, -1);
        if (background_kind != c.type_nil and background_gradient == null)
            visual.background = theming.color(state, -1) catch |err| return luaError(state, @errorName(err));
        c.lua_settop(state, -2);
        inline for (.{ "foreground", "border", "border_width", "radius" }) |field| {
            if (c.lua_getfield(state, 1, field) != c.type_nil) {
                @field(visual, field) = if (@TypeOf(@field(visual, field)) == ?f32)
                    theming.extent(state, -1, false) catch |err| return luaError(state, @errorName(err))
                else
                    theming.color(state, -1) catch |err| return luaError(state, @errorName(err));
            }
            c.lua_settop(state, -2);
        }
        const border_width = visual.border_width orelse 0;
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const id = semanticId(key, 0x626f78 ^ parent.id ^ self.component_namespace);
        const activate = tableOptionalBoolean(state, 1, "activate", false) orelse return luaError(state, "activate must be boolean");
        var enabled = tableOptionalBoolean(state, 1, "enabled", true) orelse return luaError(state, "enabled must be boolean");
        var role = tableOptionalEnum(@import("../ui/semantics/snapshot.zig").Role, state, 1, "role", .group) orelse return luaError(state, "invalid semantic role");
        if (role != .group and role != .button and role != .checkbox and role != .@"switch" and role != .separator and role != .dialog)
            return luaError(state, "box role must be group, button, checkbox, switch, separator, or dialog");
        const semantic = tableOptionalBoolean(state, 1, "semantic", true) orelse return luaError(state, "semantic must be boolean");
        if (activate and !semantic) return luaError(state, "activation requires semantics");
        if (role == .dialog) {
            if (!semantic or activate or !enabled) return luaError(state, "dialog requires semantics, enabled=true, and no activation");
            _ = tableString(state, 1, "label") orelse return luaError(state, "dialog label required");
        }
        var checked = tableOptionalBoolean(state, 1, "checked", false) orelse return luaError(state, "checked must be boolean");
        const expanded_kind = c.lua_getfield(state, 1, "expanded");
        c.lua_settop(state, -2);
        const expanded: ?bool = if (expanded_kind == c.type_nil) null else tableOptionalBoolean(state, 1, "expanded", false) orelse return luaError(state, "expanded must be boolean");
        if (expanded != null and (!semantic or !activate or role != .button))
            return luaError(state, "expanded requires an activating semantic button");
        var range: ?@import("../ui/widget/range.zig").Range = null;
        var range_inset: f32 = 0;
        const range_type = c.lua_getfield(state, 1, "range");
        if (range_type != c.type_nil) {
            if (range_type != c.type_table) return luaError(state, "range must be a table");
            range = @import("forms.zig").readRange(state, -1) catch |err| return luaError(state, @errorName(err));
            range_inset = tableOptionalExtent(state, -1, "inset", 0) orelse return luaError(state, "invalid range inset");
            if (!semantic) return luaError(state, "range requires semantics");
            inline for (.{ "activate", "role", "checked", "option", "on_press" }) |field| {
                const field_type = c.lua_getfield(state, 1, field);
                c.lua_settop(state, -2);
                if (field_type != c.type_nil) return luaError(state, "range owns activation and role; option, checked, and on_press are unsupported");
            }
            _ = tableString(state, 1, "label") orelse return luaError(state, "range label required");
            role = .slider;
        }
        c.lua_settop(state, -2);
        const option_type = c.lua_getfield(state, 1, "option");
        c.lua_settop(state, -2);
        var selected = false;
        var owner = if (activate or range != null) InteractionOwner{ .id = id, .enabled = enabled } else self.interaction_owner;
        if (option_type != c.type_nil) {
            if (!semantic) return luaError(state, "selection requires semantics");
            inline for (.{ "activate", "role", "checked", "enabled" }) |field| {
                const field_type = c.lua_getfield(state, 1, field);
                c.lua_settop(state, -2);
                if (field_type != c.type_nil) return luaError(state, "selection owns activate, role, checked, and enabled");
            }
            const group = self.currentSelection() orelse return luaError(state, "option requires a direct selection group parent");
            const value = tableRequiredInteger(state, 1, "option") orelse return luaError(state, "option value must be an integer");
            _ = tableString(state, 1, "label") orelse return luaError(state, "option label is required");
            for (self.pending_options[0..self.pending_option_count]) |option| {
                if (option.listbox_id == parent.id and option.value == value) return luaError(state, "selection values must be unique");
            }
            if (self.pending_option_count == self.pending_options.len) return luaError(state, "listbox option capacity exceeded");
            self.pending_options[self.pending_option_count] = .{ .id = id, .listbox_id = parent.id, .value = value };
            self.pending_option_count += 1;
            selected = group.selected == value;
            enabled = group.enabled;
            checked = parent.kind == .radio_group and selected;
            role = if (parent.kind == .radio_group) .radio else if (parent.kind == .tab_bar) .tab else .option;
            owner = .{ .id = id, .selection = true, .selected = selected, .enabled = enabled };
        }
        const paint = readInteractionPaint(state, owner, visual.background orelse surface.value, visual.border orelse theme.border, true) catch |err|
            return luaError(state, @errorName(err));
        if (activate or range != null) {
            if (self.pending_button_count == self.pending_buttons.len) return luaError(state, "activation capacity exceeded");
            const press_type = c.lua_getfield(state, 1, "on_press");
            const change_type = c.lua_getfield(state, 1, "on_change");
            c.lua_settop(state, -3);
            if (press_type != c.type_nil and change_type != c.type_nil)
                return luaError(state, "activation accepts on_press or on_change, not both");
            self.pending_buttons[self.pending_button_count] = .{ .id = id, .enabled = enabled };
            self.pending_button_count += 1;
            if (activate) self.stageCallback(state, id, "on_press", .button) catch |err| return luaError(state, @errorName(err));
            self.stageCallback(state, id, "on_change", if (range != null) .range_change else .@"switch") catch |err| return luaError(state, @errorName(err));
        }
        if (activate or range != null or role == .dialog) self.stageCallback(state, id, "on_cancel", .cancel) catch |err| return luaError(state, @errorName(err));
        const focusable = tableOptionalBoolean(state, 1, "focusable", false) orelse
            return luaError(state, "focusable must be boolean");
        const drag = self.readDrag(state, id) catch |err| return luaError(state, @errorName(err));
        self.append(.{
            .id = id,
            .parent = parent.id,
            .focusable = (activate or range != null or focusable) and enabled,
            .focus_request = tableFocusRequest(state, 1) catch |err| return luaError(state, @errorName(err)),
            .interaction_paint = paint,
            .range_inset = range_inset,
            .drag = if (enabled) drag else .{},
            .object = .{ .box = .{
                .width = width.extent(),
                .hidden = tableOptionalBoolean(state, 1, "hidden", false) orelse
                    return luaError(state, "box hidden must be boolean"),
                .height = height.extent(),
                .fill_width = width.isFill(),
                .fill_height = height.isFill(),
                .height_factor = height_factor,
                .min_width = min_width,
                .min_height = min_height,
                .max_width = max_width.value,
                .max_height = max_height.value,
                .aspect_ratio = aspect_ratio,
                .padding = insets,
                .alignment = alignment.value,
                .background = if (paint) |p| owner.?.initialColor(p) else visual.background orelse surface.value,
                .background_gradient = background_gradient,
                .border_color = if (border_width > 0) visual.border orelse theme.border else null,
                .border_width = border_width,
                .corner_radius = visual.radius orelse 0,
                .shadow = shadow,
                .opacity = opacity,
                .transform = transform,
                .clip = tableOptionalBoolean(state, 1, "clip", false) orelse
                    return luaError(state, "box clip must be boolean"),
            } },
            .parent_data = parent_data,
        }) catch return luaError(state, "cannot append box descriptor");
        if (semantic) self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = role,
            .key = key,
            .label = tableString(state, 1, "label") orelse "",
            .enabled = enabled,
            .checked = checked,
            .expanded = expanded,
            .selected = selected,
            .range = range,
        }) catch return luaError(state, "cannot append box semantics");
        self.stageCallback(state, id, "on_interaction_change", .interaction_change) catch |err|
            return luaError(state, @errorName(err));
        self.stageCallback(state, id, "_on_popup_anchor", .popup_anchor) catch |err|
            return luaError(state, @errorName(err));
        self.stageCallback(state, id, "on_drop_text", .drop_text) catch |err|
            return luaError(state, @errorName(err));
        self.stageCallback(state, id, "on_drop_uris", .drop_uris) catch |err|
            return luaError(state, @errorName(err));
        self.stageInput(state, id) catch |err| return luaError(state, @errorName(err));
        const previous_owner = self.interaction_owner;
        self.interaction_owner = owner;
        defer self.interaction_owner = previous_owner;
        const content_theme_type = c.lua_getfield(state, 1, "content_theme");
        const has_content_theme = content_theme_type != c.type_nil or visual.foreground != null;
        if (has_content_theme) {
            var content_theme = if (content_theme_type != c.type_nil)
                theming.apply(state, -1, self.currentStyle().?) catch |err| return luaError(state, @errorName(err))
            else
                self.currentStyle().?;
            if (visual.foreground) |foreground| {
                content_theme.colors.foreground = foreground;
                content_theme.widgets.text.foreground = null;
            }
            self.pushTheme(content_theme) catch return luaError(state, "theme nesting too deep");
        }
        c.lua_settop(state, -2);
        defer if (has_content_theme) self.popTheme();
        return self.emitChildren(state, .{ .id = id, .kind = .box, .semantic_id = if (semantic) id else semanticParent(parent) });
    }

    fn readDrag(self: *UiBuild, state: *c.State, id: u64) !@import("../ui/input/drag.zig").Options {
        const drag = @import("../ui/input/drag.zig");
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        var result: drag.Options = .{};
        inline for (.{ "drag", "drop" }) |field| {
            const kind = c.lua_getfield(state, 1, field);
            if (kind != c.type_nil) {
                if (kind != c.type_table) return error.InvalidDragDeclaration;
                const table = c.lua_gettop(state);
                c.lua_pushnil(state);
                while (c.lua_next(state, table) != 0) {
                    const name = string(state, -2) orelse return error.InvalidDragDeclaration;
                    if (!std.mem.eql(u8, name, "kind") and !std.mem.eql(u8, name, if (comptime std.mem.eql(u8, field, "drag")) "value" else "on_drop"))
                        return error.InvalidDragDeclaration;
                    c.lua_settop(state, -2);
                }
                const tag = try drag.Name.init(tableString(state, table, "kind") orelse return error.DragKindRequired);
                if (comptime std.mem.eql(u8, field, "drag")) {
                    result.source = .{ .kind = tag, .value = try drag.Name.init(tableString(state, table, "value") orelse return error.DragValueRequired) };
                } else {
                    if (c.lua_getfield(state, table, "on_drop") != c.type_function) return error.DropCallbackRequired;
                    c.lua_settop(state, table);
                    try self.stageCallbackAt(state, table, id, "on_drop", .drop_internal);
                    result.accept = tag;
                }
            }
            c.lua_settop(state, top);
        }
        return result;
    }

    fn stageInput(self: *UiBuild, state: *c.State, id: u64) !void {
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        inline for (.{ "on_key_capture", "on_key", "on_pointer_capture", "on_pointer", "on_pointer_down_outside" }, .{ .key_capture, .key_bubble, .pointer_capture, .pointer_bubble, .pointer_down_outside }) |name, kind| {
            const value_type = c.lua_getfield(state, 1, name);
            if (value_type != c.type_nil) {
                if (value_type != c.type_table) return error.InvalidInputHandler;
                const index = c.lua_gettop(state);
                const keyboard = kind == .key_capture or kind == .key_bubble;
                // A misspelled filter must not silently become a catch-all.
                c.lua_pushnil(state);
                while (c.lua_next(state, index) != 0) {
                    const field = string(state, -2) orelse return error.InvalidInputHandler;
                    if (!std.mem.eql(u8, field, "handler") and !std.mem.eql(u8, field, "propagate") and
                        !(keyboard and (std.mem.eql(u8, field, "keys") or std.mem.eql(u8, field, "states"))) and
                        !(!keyboard and (std.mem.eql(u8, field, "button") or
                            (kind != .pointer_down_outside and std.mem.eql(u8, field, "kinds")))))
                        return error.InvalidInputFilter;
                    c.lua_settop(state, -2);
                }
                if (c.lua_getfield(state, index, "propagate") != c.type_boolean) return error.InputPropagationRequired;
                const propagate = c.lua_toboolean(state, -1) != 0;
                c.lua_settop(state, -2);
                const filter = try @import("key_bindings.zig").listenerFilter(state, index, keyboard);
                if (c.lua_getfield(state, index, "handler") != c.type_function) return error.CallbackMustBeFunction;
                if (self.pending_handler_count == self.pending_handlers.len) return error.InputHandlerCapacityExceeded;
                self.pending_handlers[self.pending_handler_count] = .{
                    .id = id,
                    .reference = c.luaL_ref(state, c.registry_index),
                    .kind = kind,
                    .propagate = propagate,
                    .filter = filter,
                };
                self.pending_handler_count += 1;
            }
            c.lua_settop(state, top);
        }
        const commands_type = c.lua_getfield(state, 1, "commands");
        const commands = c.lua_gettop(state);
        if (commands_type != c.type_nil) {
            if (commands_type != c.type_table) return error.InvalidCommands;
            c.lua_pushnil(state);
            while (c.lua_next(state, commands) != 0) {
                const name = string(state, -2) orelse return error.InvalidCommands;
                if (name.len == 0 or c.lua_type(state, -1) != c.type_function) return error.InvalidCommands;
                const command = try @import("../ui/input/command.zig").Name.init(name);
                if (self.pending_handler_count == self.pending_handlers.len) return error.InputHandlerCapacityExceeded;
                c.lua_pushvalue(state, -1);
                self.pending_handlers[self.pending_handler_count] = .{
                    .id = id,
                    .reference = c.luaL_ref(state, c.registry_index),
                    .kind = .command,
                    .command = command,
                };
                self.pending_handler_count += 1;
                c.lua_settop(state, -2);
            }
        }
        const shortcuts_type = c.lua_getfield(state, 1, "shortcuts");
        if (shortcuts_type == c.type_nil) return;
        if (shortcuts_type != c.type_table or commands_type != c.type_table) return error.InvalidShortcuts;
        const shortcuts = c.lua_gettop(state);
        const first = self.pending_handler_count;
        c.lua_pushnil(state);
        while (c.lua_next(state, shortcuts) != 0) {
            const raw = string(state, -2) orelse return error.InvalidShortcuts;
            _ = string(state, -1) orelse return error.InvalidShortcuts;
            const sequence = try @import("../ui/input/key_chord.zig").Sequence.parse(raw);
            for (self.pending_handlers[first..self.pending_handler_count]) |previous|
                if (sequence.overlaps(previous.sequence)) return error.AmbiguousShortcut;
            c.lua_pushvalue(state, -1);
            if (c.lua_rawget(state, commands) != c.type_function) return error.UnknownCommand;
            if (self.pending_handler_count == self.pending_handlers.len) return error.InputHandlerCapacityExceeded;
            self.pending_handlers[self.pending_handler_count] = .{
                .id = id,
                .reference = c.luaL_ref(state, c.registry_index),
                .kind = .shortcut,
                .sequence = sequence,
            };
            self.pending_handler_count += 1;
            c.lua_settop(state, -2);
        }
    }

    fn stageCallback(self: *UiBuild, state: *c.State, id: u64, name: [*:0]const u8, kind: @import("../ui/input/bindings.zig").HandlerKind) !void {
        return self.stageCallbackAt(state, 1, id, name, kind);
    }

    fn stageCallbackAt(self: *UiBuild, state: *c.State, table: c_int, id: u64, name: [*:0]const u8, kind: @import("../ui/input/bindings.zig").HandlerKind) !void {
        const callback_type = c.lua_getfield(state, table, name);
        defer c.lua_settop(state, -2);
        if (callback_type == c.type_nil) return;
        if (callback_type != c.type_function) return error.CallbackMustBeFunction;
        if (self.pending_handler_count == self.pending_handlers.len) return error.InputHandlerCapacityExceeded;
        var open_override: ?bool = null;
        var include_capture = false;
        if (kind == .popup_anchor) {
            const value_type = c.lua_getfield(state, table, "_popup_open");
            if (value_type != c.type_boolean) return error.InvalidPopoverOpen;
            open_override = c.lua_toboolean(state, -1) != 0;
            c.lua_settop(state, -2);
        }
        if (kind == .interaction_change or kind == .popup_anchor) {
            include_capture = tableOptionalBoolean(state, table, "_popover_interaction", false) orelse return error.InvalidPopoverInteraction;
        }
        c.lua_pushvalue(state, -1);
        self.pending_handlers[self.pending_handler_count] = .{
            .id = id,
            .reference = c.luaL_ref(state, c.registry_index),
            .kind = kind,
            .open_override = open_override,
            .include_capture = include_capture,
        };
        self.pending_handler_count += 1;
    }

    fn emitTheme(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (self.currentTheme() == null) return luaError(state, "declarative widgets unavailable");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.theme expects one declaration table");
        const parent = self.currentParent() orelse return luaError(state, "theme requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "theme key is required");
        const theme = theming.apply(state, 1, self.currentStyle().?) catch |err| return luaError(state, @errorName(err));
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const id = semanticId(key, 0x7468656d65 ^ parent.id ^ self.component_namespace);
        self.append(.{
            .id = id,
            .parent = parent.id,
            .object = .{ .box = .{ .background = theme.colors.background } },
            .parent_data = parent_data,
        }) catch return luaError(state, "cannot append theme descriptor");
        self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .group,
            .key = key,
        }) catch return luaError(state, "cannot append theme semantics");
        self.pushTheme(theme) catch return luaError(state, "widget nesting is too deep");
        defer self.popTheme();
        return self.emitChildren(state, .{ .id = id, .kind = .box });
    }

    fn emitChildren(
        self: *UiBuild,
        state: *c.State,
        parent: BuildParent,
    ) c_int {
        self.pushParent(parent) catch return luaError(state, "widget nesting is too deep");
        const children = c.upvalueIndex(2);
        var status: c_int = c.ok;
        for (0..c.lua_rawlen(state, children)) |index| {
            c.lua_pushlightuserdata(state, self);
            c.lua_pushcclosure(state, lowerDescription, 1);
            _ = c.lua_rawgeti(state, children, @intCast(index + 1));
            status = c.lua_pcallk(state, 1, 0, 0, 0, null);
            if (status != c.ok) break;
        }
        self.popParent();
        if (status != c.ok) return c.lua_error(state);
        return 0;
    }

    fn emitScroll(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (self.currentTheme() == null) return luaError(state, "declarative widgets unavailable");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.scroll expects one declaration table");
        const parent = self.currentParent() orelse return luaError(state, "scroll requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "scroll key is required");
        const scroll = tableScroll(state, 1, self.currentTheme().?) catch return luaError(state, "invalid scrollbar or scroll axis");
        const scroll_to = tableScrollRequest(state, 1) catch return luaError(state, "scroll_to requires a finite non-negative offset and positive integer token; cannot combine with ensure_visible");
        const reveal_kind = c.lua_getfield(state, 1, "ensure_visible");
        c.lua_settop(state, -2);
        if (reveal_kind != c.type_nil and reveal_kind != c.type_string)
            return luaError(state, "scroll ensure_visible must be a descendant key path");
        const reveal = tableString(state, 1, "ensure_visible");
        if (reveal) |path| {
            var segments = std.mem.splitScalar(u8, path, '/');
            while (segments.next()) |segment| if (segment.len == 0)
                return luaError(state, "invalid ensure_visible key path");
        }
        const parent_data = declarativeParentData(self, state, 1) catch |err|
            return luaError(state, parentDataErrorMessage(err));
        const id = semanticId(key, 0x7363726f6c6c ^ parent.id ^ self.component_namespace);
        const descriptor_index = self.count;
        const semantic_start = self.semantic_count;
        self.append(.{
            .id = id,
            .parent = parent.id,
            .object = .{ .scroll = scroll },
            .scroll_to = scroll_to,
            .parent_data = parent_data,
        }) catch return luaError(state, "cannot append scroll descriptor");
        self.stageCallback(state, id, "on_scroll", .scroll_change) catch |err| return luaError(state, @errorName(err));
        self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .group,
            .key = key,
        }) catch return luaError(state, "cannot append scroll semantics");
        const previous_blocked = self.retention_blocked;
        self.retention_blocked = previous_blocked or reveal != null;
        defer self.retention_blocked = previous_blocked;
        const status = self.emitChildren(state, .{ .id = id, .kind = .scroll });
        if (reveal) |path| {
            var target: ?u64 = id;
            var segments = std.mem.splitScalar(u8, path, '/');
            while (segments.next()) |segment| {
                var found: ?u64 = null;
                for (self.semantic_storage[semantic_start..self.semantic_count]) |candidate| {
                    if (candidate.parent != target or !std.mem.eql(u8, candidate.key, segment)) continue;
                    if (found != null) return luaError(state, "ambiguous ensure_visible key path");
                    found = candidate.id;
                }
                target = found;
                if (target == null) break;
            }
            // Components are semantic namespaces. As with semantic input
            // targets, their returned root supplies the actual geometry.
            resolve: while (target) |candidate| {
                for (self.storage[descriptor_index + 1 .. self.count]) |descriptor| {
                    if (descriptor.id != candidate) continue;
                    self.storage[descriptor_index].ensure_visible = candidate;
                    break :resolve;
                }
                target = null;
                for (self.semantic_storage[semantic_start..self.semantic_count]) |child| {
                    if (child.parent != candidate) continue;
                    target = child.id;
                    break;
                }
            }
        }
        return status;
    }

    fn discardHandlers(self: *UiBuild) void {
        for (self.pending_handlers[0..self.pending_handler_count]) |pending|
            c.luaL_unref(self.state, c.registry_index, pending.reference);
        self.pending_handler_count = 0;
    }

    fn discardPendingTextInputs(self: *UiBuild) void {
        for (self.pending_text_inputs[0..self.pending_text_input_count]) |*pending| {
            if (pending.session) |*session| session.deinit();
            if (pending.behavior.controller) |controller| controller.release();
        }
        self.pending_text_input_count = 0;
    }

    fn discardSources(self: *UiBuild) void {
        if (self.drawings_staged) for (self.storage[0..self.count]) |descriptor| if (!descriptor.retain_subtree) switch (descriptor.object) {
            .canvas => |value| value.release(),
            else => {},
        };
        self.drawings_staged = false;
        if (self.images_staged) for (self.storage[0..self.count]) |descriptor| if (!descriptor.retain_subtree) switch (descriptor.object) {
            .image => |value| if (value.image) |handle| self.images.?.cache.release(handle) catch unreachable,
            else => {},
        };
        self.images_staged = false;
        if (self.sources_staged) for (self.storage[0..self.count]) |descriptor| if (!descriptor.retain_subtree) switch (descriptor.object) {
            .text => |value| self.text_sources.?.release(value.source) catch unreachable,
            .text_input => |input| {
                self.text_sources.?.release(input.source) catch unreachable;
                if (input.placeholder) |placeholder| self.text_sources.?.release(placeholder) catch unreachable;
            },
            else => {},
        };
        self.sources_staged = false;
    }
};

fn rasterDimension(logical: ?f32, scale: f32) !?u32 {
    const value = logical orelse return null;
    const physical = @ceil(value * scale);
    if (!std.math.isFinite(physical) or physical > 8192) return error.ImageTooLarge;
    return @intFromFloat(@max(1, physical));
}

fn emitFlexContainer(state: *c.State, axis: render_types.Axis) c_int {
    const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
    if (self.currentTheme() == null) return luaError(state, "declarative widgets unavailable");
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return luaError(state, "row and column expect one declaration table");
    const parent = self.currentParent() orelse return luaError(state, "container requires a widget parent");
    const key = tableString(state, 1, "key") orelse return luaError(state, "container key is required");
    const gap = tableOptionalExtent(state, 1, "gap", design.tokens.foundation.spacing_2) orelse
        return luaError(state, "invalid container gap");
    const wrap = tableOptionalBoolean(state, 1, "wrap", false) orelse return luaError(state, "wrap must be boolean");
    const run_gap = tableOptionalExtent(state, 1, "run_gap", gap) orelse return luaError(state, "invalid container run_gap");
    const cross_alignment = tableOptionalCrossAxisAlignment(
        state,
        1,
        "cross_alignment",
        .start,
    ) orelse return luaError(state, "invalid container cross_alignment");
    if (cross_alignment == .baseline and axis != .horizontal)
        return luaError(state, "baseline alignment requires a row");
    const main_axis_size = tableOptionalEnum(render_types.MainAxisSize, state, 1, "main_axis_size", .min) orelse
        return luaError(state, "main_axis_size must be min or max");
    const main_alignment = tableOptionalEnum(render_types.MainAxisAlignment, state, 1, "main_alignment", .start) orelse
        return luaError(state, "invalid container main_alignment");
    const selection_type = c.lua_getfield(state, 1, "selection");
    c.lua_settop(state, -2);
    const selection = if (selection_type == c.type_nil) null else tableOptionalEnum(enum { listbox, radio_group, tab_list }, state, 1, "selection", .listbox) orelse
        return luaError(state, "selection must be listbox, radio_group, or tab_list");
    const semantic = tableOptionalBoolean(state, 1, "semantic", true) orelse return luaError(state, "semantic must be boolean");
    if (selection != null and !semantic) return luaError(state, "selection requires semantics");
    const enabled = if (selection != null) tableOptionalBoolean(state, 1, "enabled", true) orelse
        return luaError(state, "selection group enabled must be boolean") else true;
    const parent_data = declarativeParentData(self, state, 1) catch |err|
        return luaError(state, parentDataErrorMessage(err));
    const id = semanticId(
        key,
        (if (axis == .horizontal) @as(u64, 0x726f77) else @as(u64, 0x636f6c756d6e)) ^ parent.id ^ self.component_namespace,
    );
    self.append(.{
        .id = id,
        .parent = parent.id,
        .focusable = selection != null and enabled,
        .focus_request = if (selection != null) tableFocusRequest(state, 1) catch |err| return luaError(state, @errorName(err)) else 0,
        .object = .{ .flex = .{
            .axis = axis,
            .main_axis_size = main_axis_size,
            .main_axis_alignment = main_alignment,
            .cross_axis_alignment = cross_alignment,
            .gap = gap,
            .wrap = wrap,
            .run_gap = run_gap,
        } },
        .parent_data = parent_data,
    }) catch return luaError(state, "cannot append container descriptor");
    if (semantic) self.appendSemantic(.{
        .id = id,
        .parent = semanticParent(parent),
        .role = if (selection) |kind| switch (kind) {
            .listbox => .listbox,
            .radio_group => .radio_group,
            .tab_list => .tab_list,
        } else .group,
        .key = key,
        .label = if (selection != null) tableString(state, 1, "label") orelse "" else "",
        .enabled = enabled,
    }) catch return luaError(state, "cannot append container semantics");
    if (selection != null) {
        const selected = tableRequiredInteger(state, 1, "selected") orelse return luaError(state, "selection selected must be an integer");
        const appearance = tableOptionalListBoxAppearance(state, 1) orelse return luaError(state, "selection appearance must be default or sidebar");
        if (self.pending_listbox_count == self.pending_listboxes.len) return luaError(state, "listbox capacity exceeded");
        self.pending_listboxes[self.pending_listbox_count] = .{ .id = id, .selected = selected, .enabled = enabled, .appearance = appearance };
        self.pending_listbox_count += 1;
        const callback_type = c.lua_getfield(state, 1, "on_select");
        c.lua_settop(state, -2);
        if (callback_type != c.type_function) return luaError(state, "selection on_select must be a function");
        self.stageCallback(state, id, "on_select", .listbox) catch |err| return luaError(state, @errorName(err));
        self.stageCallback(state, id, "on_activate", .selection_activate) catch |err| return luaError(state, @errorName(err));
        self.stageCallback(state, id, "on_cancel", .cancel) catch |err| return luaError(state, @errorName(err));
    }
    return self.emitChildren(state, .{ .id = id, .kind = if (selection) |kind| switch (kind) {
        .listbox => .listbox,
        .radio_group => .radio_group,
        .tab_list => .tab_bar,
    } else .flex, .wrap = wrap, .semantic_id = if (semantic) id else semanticParent(parent) });
}

fn readInteractionPaint(state: *c.State, owner: ?InteractionOwner, idle: ?@import("../core/color.zig").Color, border: ?@import("../core/color.zig").Color, box: bool) !?instance.InteractionPaint {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const kind = c.lua_getfield(state, 1, "states");
    if (kind == c.type_nil) return null;
    if (kind != c.type_table) return error.StatesMustBeTable;
    const source = owner orelse return error.StatesRequireInteractionAncestor;
    var paint: instance.InteractionPaint = .{ .source = source.id, .idle = idle, .border = border };
    inline for (.{ "hover", "pressed", "disabled", "selected", "focus" }) |field| {
        if (c.lua_getfield(state, -1, field) != c.type_nil) {
            if (comptime std.mem.eql(u8, field, "selected")) {
                if (!source.selection) return error.SelectedRequiresSelection;
            }
            if (comptime std.mem.eql(u8, field, "pressed") or std.mem.eql(u8, field, "disabled")) {
                if (source.selection) return error.ActivationStateRequiresActivation;
            }
            if (comptime std.mem.eql(u8, field, "focus")) {
                if (!box) return error.FocusRequiresBox;
            }
            @field(paint, field) = try theming.color(state, -1);
        }
        c.lua_settop(state, -2);
    }
    return paint;
}

fn bridge(state: *c.State) ?*UiBuild {
    const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse return null;
    const self: *UiBuild = @ptrCast(@alignCast(pointer));
    return if (self.active_owner != null) self else null;
}

fn string(state: *c.State, index: c_int) ?[]const u8 {
    if (c.lua_type(state, index) != c.type_string) return null;
    var length: usize = 0;
    const value = c.lua_tolstring(state, index, &length) orelse return null;
    return value[0..length];
}

fn tableString(state: *c.State, table: c_int, field: [*:0]const u8) ?[]const u8 {
    if (c.lua_getfield(state, table, field) != c.type_string) {
        c.lua_settop(state, -2);
        return null;
    }
    const value = string(state, -1);
    c.lua_settop(state, -2);
    return value;
}

const OptionalString = struct {
    present: bool,
    value: []const u8 = "",
};

fn tableOptionalString(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) ?OptionalString {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .{ .present = false };
    return .{ .present = true, .value = string(state, -1) orelse return null };
}

fn tableOptionalExtent(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: f32,
) ?f32 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    return requiredExtent(state, -1);
}

const OptionalExtent = struct { value: ?f32 };

fn tableOptionalNullableExtent(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) ?OptionalExtent {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .{ .value = null };
    return .{ .value = requiredExtent(state, -1) orelse return null };
}

const DeclaredSize = union(enum) {
    auto,
    fill,
    exact: f32,

    fn extent(self: DeclaredSize) ?f32 {
        return switch (self) {
            .auto, .fill => null,
            .exact => |value| value,
        };
    }

    fn isFill(self: DeclaredSize) bool {
        return switch (self) {
            .fill => true,
            .auto, .exact => false,
        };
    }
};

fn tableOptionalSize(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: DeclaredSize,
) ?DeclaredSize {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    if (value_type == c.type_number)
        return .{ .exact = requiredExtent(state, -1) orelse return null };
    const value = string(state, -1) orelse return null;
    return if (std.mem.eql(u8, value, "fill")) .fill else null;
}

const OptionalAlignment = struct { value: ?render_types.Alignment };

fn tableOptionalBoxAlignment(state: *c.State, table: c_int) ?OptionalAlignment {
    const value_type = c.lua_getfield(state, table, "alignment");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .{ .value = null };
    const value = string(state, -1) orelse return null;
    if (std.mem.eql(u8, value, "center")) return .{ .value = .center };
    if (std.mem.eql(u8, value, "left")) return .{ .value = .{ .horizontal = .minimum, .vertical = .center } };
    if (std.mem.eql(u8, value, "right")) return .{ .value = .{ .horizontal = .maximum, .vertical = .center } };
    if (std.mem.eql(u8, value, "top_left")) return .{ .value = .{ .horizontal = .minimum, .vertical = .minimum } };
    if (std.mem.eql(u8, value, "top")) return .{ .value = .{ .horizontal = .center, .vertical = .minimum } };
    if (std.mem.eql(u8, value, "top_right")) return .{ .value = .{ .horizontal = .maximum, .vertical = .minimum } };
    if (std.mem.eql(u8, value, "bottom_left")) return .{ .value = .{ .horizontal = .minimum, .vertical = .maximum } };
    if (std.mem.eql(u8, value, "bottom")) return .{ .value = .{ .horizontal = .center, .vertical = .maximum } };
    if (std.mem.eql(u8, value, "bottom_right")) return .{ .value = .{ .horizontal = .maximum, .vertical = .maximum } };
    return null;
}

fn tableOptionalBoolean(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: bool,
) ?bool {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    if (value_type != c.type_boolean) return null;
    return c.lua_toboolean(state, -1) != 0;
}

fn tableOptionalParagraphAlignment(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: text.ParagraphAlignment,
) ?text.ParagraphAlignment {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    const value = string(state, -1) orelse return null;
    if (std.mem.eql(u8, value, "start")) return .start;
    if (std.mem.eql(u8, value, "end")) return .end;
    if (std.mem.eql(u8, value, "center")) return .center;
    if (std.mem.eql(u8, value, "justify")) return .justify;
    return null;
}

const OptionalSurface = struct { value: ?@TypeOf(design.tokens.light.background) };

fn tableOptionalTransform(state: *c.State, table: c_int) !@import("../core/geometry.zig").Transform {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const kind = c.lua_getfield(state, table, "transform");
    if (kind == c.type_nil) return .{};
    if (kind != c.type_table) return error.InvalidTransform;
    const index = c.lua_gettop(state);
    var result: @import("../core/geometry.zig").Transform = .{};
    inline for (.{ "x", "y", "scale" }) |field| {
        const field_kind = c.lua_getfield(state, index, field);
        if (field_kind != c.type_nil) {
            if (field_kind != c.type_number) return error.InvalidTransform;
            const value = finiteFloat(state, -1) orelse return error.InvalidTransform;
            if (comptime std.mem.eql(u8, field, "scale")) result.scale = value else @field(result.translation, field) = value;
        }
        c.lua_settop(state, index);
    }
    const origin_kind = c.lua_getfield(state, index, "origin");
    if (origin_kind != c.type_nil) {
        if (origin_kind != c.type_table) return error.InvalidTransform;
        const origin_index = c.lua_gettop(state);
        inline for (.{ "x", "y" }) |field| {
            const field_kind = c.lua_getfield(state, origin_index, field);
            if (field_kind != c.type_nil) {
                if (field_kind != c.type_number) return error.InvalidTransform;
                @field(result.origin, field) = finiteFloat(state, -1) orelse return error.InvalidTransform;
            }
            c.lua_settop(state, origin_index);
        }
    }
    try result.validate();
    return result;
}

fn tableOptionalShadow(state: *c.State, table: c_int) !?@import("../shadow/root.zig").Style {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const kind = c.lua_getfield(state, table, "shadow");
    if (kind == c.type_nil) return null;
    if (kind != c.type_table) return error.InvalidShadow;
    const index = c.lua_gettop(state);
    _ = c.lua_getfield(state, index, "color");
    var result: @import("../shadow/root.zig").Style = .{ .color = try theming.color(state, -1) };
    c.lua_settop(state, index);
    inline for (.{ "x", "y", "blur", "spread" }) |field| {
        const field_kind = c.lua_getfield(state, index, field);
        if (field_kind != c.type_nil) {
            if (field_kind != c.type_number) return error.InvalidShadow;
            const value = finiteFloat(state, -1) orelse return error.InvalidShadow;
            if (comptime std.mem.eql(u8, field, "x")) result.offset.x = value else if (comptime std.mem.eql(u8, field, "y")) result.offset.y = value else @field(result, field) = value;
        }
        c.lua_settop(state, index);
    }
    try result.validate();
    return result;
}

fn tableOptionalSurface(
    state: *c.State,
    table: c_int,
    theme: design.tokens.Theme,
) ?OptionalSurface {
    const value_type = c.lua_getfield(state, table, "surface");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .{ .value = null };
    const value = string(state, -1) orelse return null;
    if (std.mem.eql(u8, value, "background")) return .{ .value = theme.background };
    if (std.mem.eql(u8, value, "card")) return .{ .value = theme.card };
    if (std.mem.eql(u8, value, "popover")) return .{ .value = theme.popover };
    if (std.mem.eql(u8, value, "sidebar")) return .{ .value = theme.sidebar };
    return null;
}

fn tableOptionalListBoxAppearance(state: *c.State, table: c_int) ?ListBoxAppearance {
    const value_type = c.lua_getfield(state, table, "appearance");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .default;
    const value = string(state, -1) orelse return null;
    if (std.mem.eql(u8, value, "default")) return .default;
    if (std.mem.eql(u8, value, "sidebar")) return .sidebar;
    return null;
}

fn tableOptionalParagraphOverflow(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: text.ParagraphOverflow,
) ?text.ParagraphOverflow {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    const value = string(state, -1) orelse return null;
    if (std.mem.eql(u8, value, "clip")) return .clip;
    if (std.mem.eql(u8, value, "ellipsis")) return .ellipsis;
    return null;
}

fn tableOptionalSpring(state: *c.State, table: c_int) !?animation.Spring {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const kind = c.lua_getfield(state, table, "spring");
    if (kind == c.type_nil) return null;
    if (kind != c.type_table) return error.InvalidSpringConfig;
    const index = c.lua_gettop(state);
    var result: animation.Spring = .{};
    c.lua_pushnil(state);
    while (c.lua_next(state, index) != 0) {
        const key = string(state, -2) orelse return error.InvalidSpringConfig;
        if (c.lua_type(state, -1) != c.type_number) return error.InvalidSpringConfig;
        var valid: c_int = 0;
        const number = c.lua_tonumberx(state, -1, &valid);
        inline for (std.meta.fields(animation.Spring)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                @field(result, field.name) = number;
                break;
            }
        } else return error.InvalidSpringConfig;
        c.lua_settop(state, -2);
    }
    try result.validate();
    return result;
}

fn tableOptionalEnum(
    comptime T: type,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: T,
) ?T {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    return std.meta.stringToEnum(T, string(state, -1) orelse return null);
}

fn tableOptionalAxis(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: render_types.Axis,
) ?render_types.Axis {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    const value = string(state, -1) orelse return null;
    if (std.mem.eql(u8, value, "vertical")) return .vertical;
    if (std.mem.eql(u8, value, "horizontal")) return .horizontal;
    return null;
}

fn tableOptionalFraction(state: *c.State, table: c_int, field: [*:0]const u8, default: f32) ?f32 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    if (value_type != c.type_number) return null;
    var is_number: c_int = 0;
    const value = c.lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(value) or value < 0 or value > 1) return null;
    return @floatCast(value);
}

fn tableOptionalCrossAxisAlignment(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: render_types.CrossAxisAlignment,
) ?render_types.CrossAxisAlignment {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    const value = string(state, -1) orelse return null;
    if (std.mem.eql(u8, value, "start")) return .start;
    if (std.mem.eql(u8, value, "center")) return .center;
    if (std.mem.eql(u8, value, "end")) return .end;
    if (std.mem.eql(u8, value, "stretch")) return .stretch;
    if (std.mem.eql(u8, value, "baseline")) return .baseline;
    return null;
}

fn tableFocusRequest(state: *c.State, table: c_int) !u64 {
    const kind = c.lua_getfield(state, table, "focus_request");
    defer c.lua_settop(state, -2);
    if (kind == c.type_nil) return 0;
    if (kind != c.type_number) return error.FocusRequestMustBeNonNegativeInteger;
    var is_integer: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_integer);
    if (is_integer == 0 or value < 0) return error.FocusRequestMustBeNonNegativeInteger;
    return @intCast(value);
}

/// A zero default represents an omitted optional positive integer. Explicit
/// zero and negative values remain invalid.
fn tableOptionalPositiveInteger(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: u32,
) ?u32 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_number);
    if (is_number == 0 or value <= 0 or value > std.math.maxInt(u32)) return null;
    return @intCast(value);
}

fn tableGridTracks(state: *c.State, table: c_int, field: [*:0]const u8) ?render_types.GridTracks {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.lua_getfield(state, table, field) != c.type_table) return null;
    const index = top + 1;
    const count = c.lua_rawlen(state, index);
    if (count == 0 or count > render_types.GridTracks.capacity) return null;
    // rawlen alone cannot distinguish a dense array from a sparse table.
    c.lua_pushnil(state);
    while (c.lua_next(state, index) != 0) {
        var is_integer: c_int = 0;
        const key = c.lua_tointegerx(state, -2, &is_integer);
        if (c.lua_type(state, -2) != c.type_number or is_integer == 0 or key < 1 or key > count) return null;
        c.lua_settop(state, -2);
    }
    var result: render_types.GridTracks = .{ .len = @intCast(count) };
    for (0..count) |track| {
        const kind = c.lua_rawgeti(state, index, @intCast(track + 1));
        result.values[track] = switch (kind) {
            c.type_number => .{ .fixed = requiredExtent(state, -1) orelse return null },
            c.type_string => if (std.mem.eql(u8, string(state, -1) orelse return null, "auto")) .auto else return null,
            c.type_table => fraction: {
                const weight = tableRequiredExtent(state, -1, "fr") orelse return null;
                if (weight == 0) return null;
                break :fraction .{ .fr = weight };
            },
            else => return null,
        };
        c.lua_settop(state, -2);
    }
    return result;
}

fn declarativeParentData(
    self: *const UiBuild,
    state: *c.State,
    table: c_int,
) !render_types.ParentData {
    const parent = self.currentParent() orelse return error.WidgetParentMissing;
    const flex = try tableOptionalFlex(state, table);
    if (parent.wrap and flex != null) return error.FlexInWrap;
    const positioned = try tableOptionalPositioned(state, table);
    if (positioned != null and parent.kind != .positioned_stack) return error.PositionedRequiresStackParent;
    return switch (parent.kind) {
        .flex, .listbox, .radio_group, .tab_bar => if (flex) |value| .{ .flex = value } else .none,
        .grid => grid: {
            if (flex != null) return error.FlexRequiresRowOrColumnParent;
            const column = tableOptionalPositiveInteger(state, table, "column", if (parent.grid_cell) |cell| @as(u32, cell.column) + 1 else 0) orelse return error.InvalidGridPlacement;
            const row = tableOptionalPositiveInteger(state, table, "row", if (parent.grid_cell) |cell| @as(u32, cell.row) + 1 else 0) orelse return error.InvalidGridPlacement;
            const column_span = tableOptionalPositiveInteger(state, table, "column_span", if (parent.grid_cell) |cell| cell.column_span else 1) orelse return error.InvalidGridPlacement;
            const row_span = tableOptionalPositiveInteger(state, table, "row_span", if (parent.grid_cell) |cell| cell.row_span else 1) orelse return error.InvalidGridPlacement;
            if (column == 0 or row == 0 or
                @as(u64, column) + column_span - 1 > parent.grid_columns or
                @as(u64, row) + row_span - 1 > parent.grid_rows) return error.InvalidGridPlacement;
            break :grid .{ .grid = .{
                .column = @intCast(column - 1),
                .row = @intCast(row - 1),
                .column_span = @intCast(column_span),
                .row_span = @intCast(row_span),
            } };
        },
        .box, .overlay, .scroll, .split => if (flex == null) .none else error.FlexRequiresRowOrColumnParent,
        .positioned_stack => positioned_stack: {
            if (flex != null) return error.FlexRequiresRowOrColumnParent;
            break :positioned_stack if (positioned orelse parent.positioned) |value| .{ .positioned = value } else .none;
        },
        .stack => stack: {
            if (flex != null) return error.FlexRequiresRowOrColumnParent;
            const x = tableOptionalExtent(state, table, "x", 0) orelse return error.InvalidPosition;
            const y = tableOptionalExtent(state, table, "y", 0) orelse return error.InvalidPosition;
            break :stack .{ .stack = .{ .x = x, .y = y } };
        },
    };
}

fn tableScroll(state: *c.State, table: c_int, theme: design.tokens.Theme) !render_types.Scroll {
    return .{
        .axis = tableOptionalAxis(state, table, "axis", .vertical) orelse return error.InvalidScrollAxis,
        .scrollbar = if (tableOptionalBoolean(state, table, "scrollbar", false) orelse return error.InvalidScrollbar)
            .{ .track = theme.background, .thumb = theme.muted_foreground }
        else
            null,
    };
}

fn tableScrollRequest(state: *c.State, table: c_int) !?@import("../ui/render_object/scroll.zig").Request {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const kind = c.lua_getfield(state, table, "scroll_to");
    if (kind == c.type_nil) return null;
    if (kind != c.type_table) return error.InvalidScrollRequest;
    const index = c.lua_gettop(state);
    if (c.lua_getfield(state, table, "ensure_visible") != c.type_nil) return error.InvalidScrollRequest;
    c.lua_settop(state, index);
    c.lua_pushnil(state);
    while (c.lua_next(state, index) != 0) {
        const key = string(state, -2) orelse return error.InvalidScrollRequest;
        if (!std.mem.eql(u8, key, "offset") and !std.mem.eql(u8, key, "token")) return error.InvalidScrollRequest;
        c.lua_settop(state, -2);
    }
    if (c.lua_getfield(state, index, "offset") != c.type_number) return error.InvalidScrollRequest;
    const offset = requiredExtent(state, -1) orelse return error.InvalidScrollRequest;
    c.lua_settop(state, index);
    const token = tableRequiredInteger(state, index, "token") orelse return error.InvalidScrollRequest;
    if (token <= 0) return error.InvalidScrollRequest;
    return .{ .offset = offset, .token = @intCast(token) };
}

fn tableOptionalPositioned(state: *c.State, table: c_int) !?render_types.Positioned {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const kind = c.lua_getfield(state, table, "positioned");
    if (kind == c.type_nil) return null;
    if (kind != c.type_table) return error.InvalidPositioned;
    const index = c.lua_gettop(state);
    var result: render_types.Positioned = .{};
    c.lua_pushnil(state);
    while (c.lua_next(state, index) != 0) {
        const key = string(state, -2) orelse return error.InvalidPositioned;
        var known = false;
        inline for (.{ "left", "top", "right", "bottom", "width", "height" }) |field| {
            if (std.mem.eql(u8, key, field)) {
                if (c.lua_type(state, -1) != c.type_number) return error.InvalidPositioned;
                @field(result, field) = finiteFloat(state, -1) orelse return error.InvalidPositioned;
                known = true;
            }
        }
        if (!known) return error.InvalidPositioned;
        c.lua_settop(state, -2);
    }
    result.validate() catch return error.InvalidPositioned;
    return result;
}

fn tableOptionalFlex(state: *c.State, table: c_int) !?@FieldType(render_types.ParentData, "flex") {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const value_type = c.lua_getfield(state, table, "flex");
    if (value_type == c.type_nil) return null;
    var fit: render_types.FlexFit = .tight;
    if (value_type == c.type_table) {
        const index = c.lua_gettop(state);
        c.lua_pushnil(state);
        while (c.lua_next(state, index) != 0) {
            const key = string(state, -2) orelse return error.InvalidFlexFactor;
            if (!std.mem.eql(u8, key, "factor") and !std.mem.eql(u8, key, "fit")) return error.InvalidFlexFactor;
            c.lua_settop(state, -2);
        }
        fit = tableOptionalEnum(render_types.FlexFit, state, index, "fit", .tight) orelse return error.InvalidFlexFactor;
        if (c.lua_getfield(state, index, "factor") != c.type_number) return error.InvalidFlexFactor;
    }
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_number);
    if (is_number == 0 or value <= 0 or value > std.math.maxInt(u16))
        return error.InvalidFlexFactor;
    return .{ .factor = @intCast(value), .fit = fit };
}

fn tableRequiredInteger(state: *c.State, table: c_int, field: [*:0]const u8) ?i64 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type != c.type_number) return null;
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_number);
    return if (is_number != 0) value else null;
}

fn parentDataErrorMessage(err: anyerror) [*:0]const u8 {
    return switch (err) {
        error.InvalidFlexFactor => "flex requires a positive integer or {factor=integer, fit='tight'|'loose'}",
        error.FlexInWrap => "flex is not supported in wrapping rows or columns",
        error.InvalidGridPlacement => "grid children require row and column with spans inside declared tracks",
        error.FlexRequiresRowOrColumnParent => "flex requires a direct row or column parent",
        error.InvalidPosition => "invalid widget position",
        error.InvalidPositioned => "positioned requires finite insets and non-negative extents, at most two per axis",
        error.PositionedRequiresStackParent => "positioned requires a direct stack parent",
        error.WidgetParentMissing => "widget parent is missing",
        else => "invalid widget parent data",
    };
}

fn semanticId(key: []const u8, domain: u64) u64 {
    return std.hash.Wyhash.hash(domain, key) | (@as(u64, 1) << 63);
}

fn semanticParent(parent: BuildParent) ?u64 {
    if (parent.semantic_id) |id| return id;
    return if (parent.id == 2) null else parent.id;
}

fn requiredExtent(state: *c.State, index: c_int) ?f32 {
    const value = finiteFloat(state, index) orelse return null;
    return if (value >= 0) value else null;
}

fn tableRequiredExtent(state: *c.State, table: c_int, field: [*:0]const u8) ?f32 {
    _ = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    return requiredExtent(state, -1);
}

fn finiteFloat(state: *c.State, index: c_int) ?f32 {
    var is_number: c_int = 0;
    const value = c.lua_tonumberx(state, index, &is_number);
    if (is_number == 0 or !std.math.isFinite(value) or
        value < -std.math.floatMax(f32) or value > std.math.floatMax(f32)) return null;
    return @floatCast(value);
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    if (c.lua_type(state, 1) == c.type_table) {
        if (tableString(state, 1, "key")) |key| {
            _ = c.lua_pushstring(state, "widget '");
            _ = c.lua_pushlstring(state, key.ptr, key.len);
            _ = c.lua_pushstring(state, "': ");
            _ = c.lua_pushstring(state, message);
            c.lua_concat(state, 4);
            return c.lua_error(state);
        }
    }
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "contextual input validates filters commands and shortcut ambiguity transactionally" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    var ui: UiBuild = .{ .state = state, .storage = &.{} };
    defer ui.rollbackHandlers();
    const cases = [_]struct { source: []const u8, failure: ?anyerror, count: usize = 2 }{
        .{ .source = "{on_key={handler=function() end}}", .failure = error.InputPropagationRequired },
        .{ .source = "{on_key={propagate=false,handler=function() end,key={'A'}}}", .failure = error.InvalidInputFilter },
        .{ .source = "{on_key={propagate=false,handler=function() end,keys={}}}", .failure = error.InvalidInputFilter },
        .{ .source = "{on_key={propagate=false,handler=function() end,keys={[2]='A'}}}", .failure = error.InvalidInputFilter },
        .{ .source = "{on_key={propagate=false,handler=function() end,states={'press'}}}", .failure = error.InvalidInputFilter },
        .{ .source = "{on_pointer={propagate=false,handler=function() end,kinds={'key'}}}", .failure = error.InvalidInputFilter },
        .{ .source = "{on_pointer={propagate=false,handler=function() end,button=-1}}", .failure = error.InvalidInputFilter },
        .{ .source = "{on_pointer_down_outside={propagate=false,handler=function() end,kinds={'press'}}}", .failure = error.InvalidInputFilter },
        .{ .source = "{commands={unused=1}}", .failure = error.InvalidCommands },
        .{ .source = "{commands={},shortcuts={['Ctrl+S']='typo'}}", .failure = error.UnknownCommand },
        .{ .source = "{commands={go=function() end},shortcuts={['Ctrl+S']='go',['ctrl+s']='go'}}", .failure = error.AmbiguousShortcut },
        .{ .source = "{commands={go=function() end},shortcuts={['Ctrl+K']='go',['Ctrl+K C']='go'}}", .failure = error.AmbiguousShortcut },
        .{ .source = "{commands={go=function() end},shortcuts={['Ctrl+K C']='go',['Ctrl+K U']='go'}}", .failure = null, .count = 3 },
        .{ .source = "{on_key={propagate=false,handler=function() end,keys={'Ctrl+Left'},states={'pressed'}},on_pointer={propagate=true,handler=function() end,kinds={'press'},button=272}}", .failure = null },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "return {s}", .{case.source});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@input-validation", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
        if (case.failure) |failure| {
            try std.testing.expectError(failure, ui.stageInput(state, 42));
        } else {
            try ui.stageInput(state, 42);
            try std.testing.expectEqual(case.count, ui.pending_handler_count);
        }
        try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
        ui.rollbackHandlers();
        c.lua_settop(state, 0);
    }
}

test "Lua box transforms copy finite uniform values and reject malformed declarations" {
    const Transform = @import("../core/geometry.zig").Transform;
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    for ([_][]const u8{
        "false",   "1",        "{scale=0}",   "{scale=-1}",     "{scale=1/0}",      "{scale=1e-45}",
        "{x=0/0}", "{y=1e39}", "{scale='2'}", "{origin=false}", "{origin={x='3'}}", "{origin={y=1/0}}",
    }) |invalid| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "return {{transform={s}}}", .{invalid});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@transform-validation", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
        try std.testing.expectError(error.InvalidTransform, tableOptionalTransform(state, 1));
        try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
        c.lua_settop(state, 0);
    }
    const valid = "return {transform={x=-3.25,y=7.5,scale=1.25,origin={x=9,y=-4}}}, {transform={}}, {}";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, valid.ptr, valid.len, "@transform-validation", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 3, 0, 0, null));
    const value = try tableOptionalTransform(state, 1);
    try std.testing.expectEqual(Transform{ .translation = .{ .x = -3.25, .y = 7.5 }, .scale = 1.25, .origin = .{ .x = 9, .y = -4 } }, value);
    try std.testing.expectEqual(Transform{}, try tableOptionalTransform(state, 2));
    try std.testing.expectEqual(Transform{}, try tableOptionalTransform(state, 3));
    c.lua_settop(state, 0);
    try std.testing.expectEqual(@as(f32, 9), value.origin.x);
}

test "Lua box shadows validate signed numbers defaults and rejected declarations" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    for ([_][]const u8{
        "false",                        "1",                          "{}",                      "{color=false}",            "{color='red'}",
        "{color='#000000',blur=-1}",    "{color='#000000',blur=0/0}", "{color='#000000',x=1/0}", "{color='#000000',y=1e39}", "{color='#000000',spread='2'}",
        "{color='#000000',blur=false}",
    }) |invalid| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "return {{shadow={s}}}", .{invalid});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@shadow-validation", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
        const result = tableOptionalShadow(state, 1);
        if (result) |_| return error.InvalidShadowAccepted else |_| {}
        try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
        c.lua_settop(state, 0);
    }
    const valid = "return {shadow={color='#12345680',x=-3.25,y=7.5,spread=-2}}, {shadow={color='#abcdef'}}, {}";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, valid.ptr, valid.len, "@shadow-validation", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 3, 0, 0, null));
    const value = (try tableOptionalShadow(state, 1)).?;
    try std.testing.expectEqual(@as(f32, -3.25), value.offset.x);
    try std.testing.expectEqual(@as(f32, 7.5), value.offset.y);
    try std.testing.expectEqual(@as(f32, -2), value.spread);
    try std.testing.expectEqual(@as(u8, 128), value.color.a);
    const defaults = (try tableOptionalShadow(state, 2)).?;
    try std.testing.expectEqual(@as(f32, 0), defaults.blur + defaults.spread + defaults.offset.x + defaults.offset.y);
    try std.testing.expect((try tableOptionalShadow(state, 3)) == null);
}

test "Lua UI exposes only declarative constructors without standard libraries" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    try std.testing.expectEqual(c.type_nil, c.lua_getglobal(state, "print"));
    c.lua_settop(state, -2);

    var storage: [1]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);

    try std.testing.expectEqual(c.type_table, c.lua_getglobal(state, "ouro"));
    inline for (.{
        "text", "button", "text_input", "listbox", "option", "box", "stack", "row", "column", "scroll", "theme",
    }) |name| {
        try std.testing.expectEqual(c.type_function, c.lua_getfield(state, -1, name));
        c.lua_settop(state, -2);
    }
    inline for (.{ "label", "padded_box", "positioned_box", "on_pointer" }) |name| {
        try std.testing.expectEqual(c.type_nil, c.lua_getfield(state, -1, name));
        c.lua_settop(state, -2);
    }
}

test "declarative text input separates focus identity from editable render content" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;

    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 8);
    c.lua_setglobal(state, "ouro");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var owners: build_owner.BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var storage: [5]instance.Descriptor = undefined;
    var semantic_storage: [2]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachText(&sources, &.{font}, 1);
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(.light);
    try execute(state,
        \\function build()
        \\  return ouro.column {
        \\    key = "content",
        \\    ouro.text_input {
        \\      key = "query",
        \\      text = "Initial\r\nvalue",
        \\      placeholder = "Search",
        \\      label = "Query",
        \\      read_only = true,
        \\      text_entry = false,
        \\      caret_shape = 'underline',
        \\      on_change = function(value) changed = value end,
        \\    },
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 5), descriptors.len);
    try std.testing.expect(descriptors[3].object == .box);
    try std.testing.expect(descriptors[3].focusable);
    try std.testing.expect(descriptors[3].object.box.width == null);
    try std.testing.expect(descriptors[3].object.box.fill_width);
    try std.testing.expectEqual(@as(f32, 0), descriptors[3].object.box.padding.top);
    try std.testing.expectEqual(@as(f32, 0), descriptors[3].object.box.padding.bottom);
    try std.testing.expectEqual(
        design.tokens.foundation.spacing_2,
        descriptors[3].object.box.padding.left,
    );
    try std.testing.expectEqual(design.tokens.light.input, descriptors[3].object.box.border_color.?);
    try std.testing.expectEqual(design.tokens.light.surface, descriptors[3].object.box.background.?);
    try std.testing.expectEqual(design.tokens.foundation.radius_2, descriptors[3].object.box.corner_radius);
    try std.testing.expect(descriptors[4].object == .text_input);
    try std.testing.expectEqual(.underline, descriptors[4].object.text_input.caret_shape);
    try std.testing.expectEqual(descriptors[3].id, descriptors[4].parent.?);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_text_input_count);
    try std.testing.expectEqual(.controlled, ui.pending_text_inputs[0].mode);
    try std.testing.expect(ui.pending_text_inputs[0].behavior.read_only);
    try std.testing.expect(!ui.pending_text_inputs[0].behavior.text_entry);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_handler_count);
    try std.testing.expectEqual(.text_input_change, ui.pending_handlers[0].kind);
    try std.testing.expectEqual(.text_field, ui.semanticDescriptors()[1].role);
    try std.testing.expectEqualStrings("Query", ui.semanticDescriptors()[1].label);
    try std.testing.expectEqualStrings("Search", (try sources.get(descriptors[4].object.text_input.placeholder.?)).utf8);
    try std.testing.expectEqualStrings("Initial value", (try sources.get(descriptors[4].object.text_input.source)).utf8);
    try std.testing.expectEqual("Initial value".len, descriptors[4].object.text_input.caret_offset);
    var prepared: PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, state, &sources, 5, 64);
    defer prepared.deinit();
    try ui.capturePrepared(&prepared, descriptors);
    try std.testing.expectEqual(@as(usize, 1), prepared.text_input_count);
    try std.testing.expectEqual(.controlled, prepared.text_inputs[0].mode);
    try std.testing.expect(prepared.text_inputs[0].behavior.read_only);
    try std.testing.expectEqualStrings(
        "Initial value",
        prepared.text_inputs[0].session.?.model.text(),
    );
    try std.testing.expectEqual(@as(usize, 1), prepared.handler_count);
    try std.testing.expectEqual(.text_input_change, prepared.handlers[0].kind);
    prepared.reset();
    try std.testing.expectEqual(@as(usize, 0), sources.count());
    // Failure after session creation must release normalized model storage,
    // even though Lua errors bypass defers in the C-callable widget emitter.
    try execute(state,
        \\function invalid_build()
        \\  return ouro.text_input { key = "bad", text = "first\nsecond", flex = 0 }
        \\end
    );
    try std.testing.expectError(error.LuaBuildFailed, ui.build(&owners, work, "invalid_build", &.{}));
    try std.testing.expectEqual(@as(usize, 0), ui.pending_text_input_count);
    try std.testing.expectEqual(@as(usize, 0), sources.count());
    try owners.complete(work);
    try fonts.release(font);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "declarative sidebar listbox uses paired active visuals" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const BuildOwners = build_owner.BuildOwners;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 3);
    c.lua_setglobal(state, "ouro");

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
    const medium_font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Medium.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_storybook_medium_font"),
    });
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var storage: [7]instance.Descriptor = undefined;
    var semantic_storage: [3]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachText(&sources, &.{font}, 1);
    try ui.attachMediumText(&.{medium_font});
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(.light);
    try execute(state,
        \\function build()
        \\  return ouro.listbox {
        \\    key = "navigation",
        \\    appearance = "sidebar",
        \\    selected = 2,
        \\    on_select = function() end,
        \\    ouro.option { key = "first", value = 1, label = "First" },
        \\    ouro.option { key = "second", value = 2, label = "Second" },
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 7), descriptors.len);
    try std.testing.expectEqual(design.tokens.light.sidebar_foreground, descriptors[4].object.text.color);
    try std.testing.expectEqual(
        design.tokens.light.sidebar_accent_selected,
        descriptors[5].object.box.background.?,
    );
    try std.testing.expectEqual(
        design.tokens.light.sidebar_accent_foreground,
        descriptors[6].object.text.color,
    );
    try std.testing.expectEqual(@as(usize, 2), ui.pending_option_count);
    try std.testing.expectEqual(descriptors[3].id, ui.pending_options[0].id);
    try std.testing.expectEqual(descriptors[3].id, descriptors[4].interaction_paint.?.source);
    try std.testing.expectEqual(
        design.tokens.light.sidebar_accent_foreground,
        descriptors[4].interaction_paint.?.hover.?,
    );
    const idle_source = try sources.get(descriptors[4].object.text.source);
    const selected_source = try sources.get(descriptors[6].object.text.source);
    try std.testing.expectEqual(font, idle_source.candidates[0]);
    try std.testing.expectEqual(medium_font, selected_source.candidates[0]);

    var prepared: PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, state, &sources, 7, 64);
    defer prepared.deinit();
    try ui.capturePrepared(&prepared, descriptors);
    try std.testing.expectEqual(descriptors[5].id, prepared.prepared_options[1].id);
    try std.testing.expectEqual(descriptors[5].id, prepared.descriptors()[6].interaction_paint.?.source);
    prepared.reset();
    try owners.complete(work);
    try fonts.release(font);
    try fonts.release(medium_font);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "declarative flex is contextual child data and containers expose cross alignment" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const BuildOwners = build_owner.BuildOwners;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [5]instance.Descriptor = undefined;
    var semantic_storage: [3]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(.light);
    try execute(state,
        \\function build()
        \\  return ouro.row {
        \\    key = "layout",
        \\    cross_alignment = "stretch",
        \\    ouro.box { key = "fixed", width = 40 },
        \\    ouro.box { key = "expanded", flex = 2 },
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 5), descriptors.len);
    try std.testing.expectEqual(
        render_types.CrossAxisAlignment.stretch,
        descriptors[2].object.flex.cross_axis_alignment,
    );
    try std.testing.expectEqual(@as(u16, 2), descriptors[4].parent_data.flex.factor);
    try std.testing.expectEqual(render_types.FlexFit.tight, descriptors[4].parent_data.flex.fit);
    ui.rollbackHandlers();
    try owners.complete(work);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "declarative flex rejects invalid factors and non-flex parents" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 1);
    c.lua_pushinteger(state, 1);
    c.lua_setfield(state, -2, "flex");
    var storage: [1]instance.Descriptor = undefined;
    var ui: UiBuild = .{ .state = state, .storage = &storage };
    ui.parent_stack[0] = .{ .id = 1, .kind = .box };
    ui.parent_count = 1;
    try std.testing.expectError(
        error.FlexRequiresRowOrColumnParent,
        declarativeParentData(&ui, state, -1),
    );

    ui.parent_stack[0].kind = .flex;
    c.lua_pushinteger(state, 0);
    c.lua_setfield(state, -2, "flex");
    try std.testing.expectError(error.InvalidFlexFactor, declarativeParentData(&ui, state, -1));
}

test "declarative grid and wrap validate declarations and retain keyed children through placement changes" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const RenderTree = @import("../ui/render_object/root.zig").Tree;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 32, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var owners: build_owner.BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 16);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, scope, 16);
    defer instances.deinit();
    var storage: [8]instance.Descriptor = undefined;
    var semantics: [6]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachSemantics(&semantics);
    ui.enableDeclarativeWidgets(.light);
    try execute(state,
        \\columns = {31, {fr=2}, "auto"}
        \\row = 1
        \\span = 2
        \\wrap = false
        \\weight = nil
        \\run_gap = 9
        \\local Leaf = ouro.stateless(function(p)
        \\  return ouro.box {key=p.key, width=21, height=13}
        \\end)
        \\local Card = ouro.stateful(function(p)
        \\  return function() return Leaf {key="leaf"} end
        \\end)
        \\wrap_mounts = 0
        \\wrap_renders = 0
        \\local FlexChild = ouro.stateful(function(p)
        \\  wrap_mounts = wrap_mounts + 1
        \\  return function()
        \\    wrap_renders = wrap_renders + 1
        \\    return ouro.box {key="leaf", width=71, height=11, flex=p.weight}
        \\  end
        \\end)
        \\function build(reorder)
        \\  local a = ouro.box {key="a", column=2, row=row, column_span=span, width="fill", height=17}
        \\  local b = ouro.box {key="b", column=1, row=2, width=21, height=13}
        \\  return ouro.grid {key="grid", columns=columns, rows={23, 37}, column_gap=5,
        \\    children = reorder and {b,a} or {a,b}}
        \\end
        \\function custom(reorder)
        \\  local a = Card {key="a", column=2, row=row, column_span=span}
        \\  local b = Leaf {key="b", column=1, row=2}
        \\  return ouro.grid {key="grid", columns=columns, rows={23,37}, column_gap=5,
        \\    children = reorder and {b,a} or {a,b}}
        \\end
        \\function stock(reorder)
        \\  local a = ouro.button {key="a", label="A", column=2, row=row, column_span=span,
        \\    ouro.box {key="content", width=9, height=7, semantic=false}}
        \\  local b = ouro.box {key="b", column=1, row=2, width=21, height=13}
        \\  return ouro.grid {key="grid", columns=columns, rows={23,37}, column_gap=5,
        \\    children = reorder and {b,a} or {a,b}}
        \\end
        \\function wrapping(reorder)
        \\  local a = ouro.box {key="a", width=71, height=11, flex=weight}
        \\  local b = ouro.box {key="b", width=53, height=29}
        \\  return ouro.row {key="wrap", wrap=wrap, run_gap=run_gap, gap=3,
        \\    children = reorder and {b,a} or {a,b}}
        \\end
        \\function stateful_wrapping(reorder)
        \\  local a = FlexChild {key="a", weight=weight, tick=reorder}
        \\  local b = ouro.box {key="b", width=53, height=29}
        \\  return ouro.row {key="wrap", wrap=wrap, run_gap=run_gap, gap=3,
        \\    children = reorder and {b,a} or {a,b}}
        \\end
    );
    for ([_][:0]const u8{ "build", "custom", "stock", "wrapping", "stateful_wrapping" }) |function| {
        try execute(state, "row=1; span=2; wrap=false");
        var saved: ?instance.InstanceHandle = null;
        for (0..2) |pass| {
            if (pass == 1) try execute(state, "row=2; span=1; wrap=true");
            _ = try owners.markDirty(owner);
            var cycle = owners.beginCycle();
            const work = (try cycle.take()).?;
            const descriptors = try ui.build(&owners, work, function, &.{.{ .boolean = pass == 1 }});
            try instances.reconcile(descriptors);
            const a = instances.handleForId(descriptors[if (pass == 0) 3 else 4].id).?;
            if (saved) |handle| try std.testing.expectEqual(handle, a) else saved = a;
            if (descriptors[2].object == .grid) {
                try std.testing.expectEqual(@as(f32, 2), descriptors[2].object.grid.columns.values[1].fr);
                const cell = descriptors[if (pass == 0) 3 else 4].parent_data.grid;
                try std.testing.expectEqual(@as(u8, @intCast(pass)), cell.row);
                try std.testing.expectEqual(@as(u8, if (pass == 0) 2 else 1), cell.column_span);
            } else {
                try std.testing.expectEqual(pass == 1, descriptors[2].object.flex.wrap);
                try std.testing.expectEqual(@as(f32, 9), descriptors[2].object.flex.run_gap);
            }
            _ = try renders.layout((try instances.rootRenderObject()).?, .{ .max_width = 120, .max_height = 100 });
            try ui.commitDependencies(&owners, work);
            ui.rollbackHandlers();
            try owners.complete(work);
            try scheduler.applyQueuedCancellations();
            try instances.collectRetired();
        }
    }
    var is_integer: c_int = 0;
    _ = c.lua_getglobal(state, "wrap_mounts");
    try std.testing.expectEqual(@as(i64, 1), c.lua_tointegerx(state, -1, &is_integer));
    c.lua_settop(state, -2);
    _ = c.lua_getglobal(state, "wrap_renders");
    try std.testing.expectEqual(@as(i64, 2), c.lua_tointegerx(state, -1, &is_integer));
    c.lua_settop(state, -2);
    try execute(state, "weight=1; wrap=true");
    _ = try owners.markDirty(owner);
    var rebuilding = owners.beginCycle();
    const invalid_rebuild = (try rebuilding.take()).?;
    try std.testing.expectError(error.LuaBuildFailed, ui.build(&owners, invalid_rebuild, "stateful_wrapping", &.{}));
    try owners.complete(invalid_rebuild);
    try execute(state, "weight=nil");
    // Malformed arrays, invalid track numbers, missing/out-of-range cells,
    // and wrap weights fail during Lua lowering, before native reconciliation.
    for ([_][]const u8{
        "columns={}",    "columns={[1]=20,[3]=40}",             "columns={a=20,30}",
        "columns={-1}",  "columns={{fr=0}}",                    "columns={1/0}",
        "columns={0/0}", "columns={31,{fr=2},'auto'}; row=nil", "row=0",
        "row=3",         "row=1.5",                             "row=1; span=4",
        "span=0",        "span=4294967295",
    }) |invalid| {
        try execute(state, invalid);
        _ = try owners.markDirty(owner);
        var cycle = owners.beginCycle();
        const work = (try cycle.take()).?;
        try std.testing.expectError(error.LuaBuildFailed, ui.build(&owners, work, "build", &.{}));
        try owners.complete(work);
    }
    for ([_][]const u8{ "weight=1", "weight=nil; run_gap=-1", "run_gap=9; wrap='yes'" }) |invalid| {
        try execute(state, invalid);
        _ = try owners.markDirty(owner);
        var cycle = owners.beginCycle();
        const work = (try cycle.take()).?;
        try std.testing.expectError(error.LuaBuildFailed, ui.build(&owners, work, "wrapping", &.{}));
        try owners.complete(work);
    }
    try instances.reconcile(&.{});
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(scope);
}

test "declarative Lua text flows through layout scene and software glyph cache" {
    const software = @import("../renderer/software/root.zig");
    if (comptime !software.has_freetype) return error.SkipZigTest;
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const BuildOwners = build_owner.BuildOwners;
    const RenderTree = @import("../ui/render_object/root.zig").Tree;
    const SceneBuilder = @import("../ui/render_object/root.zig").Builder;
    const scene = @import("../scene/root.zig");

    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 5);
    c.lua_setglobal(state, "ouro");

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 4);
    renders.attachTextCaches(&sources, &paragraphs);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 4);
    defer instances.deinit();
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [4]instance.Descriptor = undefined;
    var semantic_storage: [2]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachText(&sources, &.{ font, arabic }, 1);
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(.light);

    try execute(state,
        \\function build()
        \\  return ouro.column {
        \\    key = "content",
        \\    ouro.text {
        \\      key = "benchmark",
        \\      text = "Benchmark حفظ",
        \\      size = 18,
        \\      alignment = "center",
        \\      max_lines = 1,
        \\      overflow = "ellipsis",
        \\    },
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try instances.reconcile(descriptors);
    ui.rollbackHandlers();
    try owners.complete(work);
    try std.testing.expectEqual(@as(usize, 1), sources.count());
    var retained_text: ?render_types.Text = null;
    for (descriptors) |descriptor| switch (descriptor.object) {
        .text => |value| retained_text = value,
        else => {},
    };
    const text_descriptor = retained_text.?;
    try std.testing.expectEqual(text.ParagraphAlignment.center, text_descriptor.alignment);
    try std.testing.expectEqual(@as(?u32, 1), text_descriptor.max_lines);
    try std.testing.expectEqual(text.ParagraphOverflow.ellipsis, text_descriptor.overflow);

    const root = (try instances.rootRenderObject()).?;
    const size = try renders.layout(root, .{ .max_width = 160, .max_height = 64 });
    try std.testing.expect(size.width > 0 and size.height > 0);
    var command_storage: [8]scene.Command = undefined;
    var builder = try SceneBuilder.init(&command_storage, 1);
    try renders.buildScene(root, &builder);
    var found_paragraph = false;
    for (builder.displayList().commands) |command| {
        if (command == .paragraph) found_paragraph = true;
    }
    try std.testing.expect(found_paragraph);
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());

    var glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer glyphs.deinit();
    var pixels = [_]u8{0} ** (160 * 64 * 4);
    try software.renderParagraphs(builder.displayList(), .{
        .pixels = &pixels,
        .width = 160,
        .height = 64,
        .stride = 160 * 4,
        .format = .rgba8_unorm,
    }, &glyphs, &paragraphs);
    try std.testing.expect(std.mem.indexOfNone(u8, &pixels, &.{0}) != null);

    try instances.reconcile(&.{});
    try std.testing.expectEqual(@as(usize, 0), sources.count());
    try std.testing.expectEqual(@as(usize, 0), paragraphs.count());
    try fonts.release(font);
    try fonts.release(arabic);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "box maxima and edge padding preserve strict validation and defaults" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var owners: build_owner.BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [3]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    ui.enableDeclarativeWidgets(.light);
    try execute(state, "function build() return ouro.box(props) end");

    for ([_][]const u8{
        "max_width='20'",      "max_height=false",      "max_width=-1",                "max_height=0/0",
        "max_width=1/0",       "width=21,max_width=20", "min_height=31,max_height=30", "padding_left='4'",
        "padding_right=false", "padding_top=-1",        "padding_bottom=1/0",
    }) |fields| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "props={{key='box',semantic=false,{s}}}", .{fields});
        defer std.testing.allocator.free(source);
        try execute(state, source);
        _ = try owners.markDirty(owner);
        var cycle = owners.beginCycle();
        const work = (try cycle.take()).?;
        try std.testing.expectError(error.LuaBuildFailed, ui.build(&owners, work, "build", &.{}));
        ui.rollbackHandlers();
        try owners.complete(work);
    }
    try execute(state, "props={key='box',semantic=false,max_width=71,max_height=93,padding=3,padding_x=5,padding_left=0,padding_bottom=7}");
    _ = try owners.markDirty(owner);
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    const box = descriptors[2].object.box;
    try std.testing.expectEqual(@as(?f32, 71), box.max_width);
    try std.testing.expectEqual(@as(?f32, 93), box.max_height);
    try std.testing.expectEqual(@import("../core/geometry.zig").Insets{ .left = 0, .right = 5, .top = 3, .bottom = 7 }, box.padding);
    ui.rollbackHandlers();
    try owners.complete(work);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(scope);
}

test "nested declarative widgets include constrained boxes and scoped themes" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const BuildOwners = build_owner.BuildOwners;

    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
    const medium_font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Medium.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_storybook_medium_font"),
    });
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var storage: [9]instance.Descriptor = undefined;
    var semantic_storage: [6]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachText(&sources, &.{font}, 1);
    try ui.attachMediumText(&.{medium_font});
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(.light);
    try execute(state,
        \\function build()
        \\  return ouro.box {
        \\    key = "frame",
        \\    width = 320,
        \\    height = 200,
        \\    min_width = 280,
        \\    min_height = 160,
        \\    padding = 8,
        \\    alignment = "center",
        \\    clip = true,
        \\    opacity = 0.375,
        \\    shadow = {x=-3,y=5,blur=8,spread=-1,color='#11223380'},
        \\    ouro.theme {
        \\      key = "dark",
        \\      color_scheme = "dark",
        \\      ouro.column {
        \\        key = "content",
        \\        ouro.text { key = "title", text = "Controls" },
        \\        ouro.row {
        \\          key = "actions",
        \\          ouro.button {
        \\            key = "benchmark",
        \\            label = "Benchmark",
        \\            on_press = function() end,
        \\          },
        \\        },
        \\      },
        \\    },
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 9), descriptors.len);
    try std.testing.expect(descriptors[0].object == .box);
    try std.testing.expect(descriptors[1].object == .stack);
    try std.testing.expectEqual(@as(?f32, 320), descriptors[2].object.box.width);
    try std.testing.expectEqual(@as(?f32, 200), descriptors[2].object.box.height);
    try std.testing.expectEqual(@as(f32, 280), descriptors[2].object.box.min_width);
    try std.testing.expectEqual(@as(f32, 160), descriptors[2].object.box.min_height);
    try std.testing.expect(descriptors[2].object.box.clip);
    try std.testing.expect(!descriptors[3].object.box.clip);
    try std.testing.expectEqual(@as(f32, 0.375), descriptors[2].object.box.opacity);
    try std.testing.expectEqual(@as(f32, 1), descriptors[3].object.box.opacity);
    try std.testing.expectEqual(@as(f32, -3), descriptors[2].object.box.shadow.?.offset.x);
    try std.testing.expectEqual(@as(f32, 8), descriptors[2].object.box.shadow.?.blur);
    try std.testing.expectEqual(@as(u8, 128), descriptors[2].object.box.shadow.?.color.a);
    try std.testing.expectEqual(
        render_types.Alignment.center,
        descriptors[2].object.box.alignment.?,
    );
    try std.testing.expectEqual(design.tokens.dark.background, descriptors[3].object.box.background.?);
    try std.testing.expect(descriptors[4].object == .flex);
    try std.testing.expect(descriptors[5].object == .text);
    try std.testing.expect(descriptors[6].object == .flex);
    try std.testing.expectEqual(design.tokens.dark.primary, descriptors[7].object.box.background.?);
    try std.testing.expect(descriptors[7].focusable);
    try std.testing.expect(descriptors[7].object.box.width == null);
    try std.testing.expectEqual(@as(f32, 0), descriptors[7].object.box.min_width);
    try std.testing.expectEqual(
        @as(?f32, design.tokens.foundation.spacing_6),
        descriptors[7].object.box.height,
    );
    try std.testing.expectEqual(
        design.tokens.foundation.radius_2,
        descriptors[7].object.box.corner_radius,
    );
    try std.testing.expectEqual(@as(f32, 0), descriptors[7].object.box.padding.top);
    try std.testing.expectEqual(@as(f32, 0), descriptors[7].object.box.padding.bottom);
    try std.testing.expectEqual(design.tokens.foundation.spacing_3, descriptors[7].object.box.padding.left);
    try std.testing.expectEqual(design.tokens.foundation.spacing_3, descriptors[7].object.box.padding.right);
    try std.testing.expectEqual(design.tokens.dark.primary_foreground, descriptors[8].object.text.color);
    const button_source = try sources.get(descriptors[8].object.text.source);
    try std.testing.expectEqual(@as(usize, 1), button_source.candidates.len);
    try std.testing.expectEqual(medium_font, button_source.candidates[0]);
    try std.testing.expectEqual(@as(?u32, 1), descriptors[8].object.text.max_lines);
    try std.testing.expectEqual(text.ParagraphOverflow.ellipsis, descriptors[8].object.text.overflow);
    try std.testing.expectEqual(descriptors[7].id, descriptors[8].parent.?);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_handler_count);
    try std.testing.expectEqual(.button, ui.pending_handlers[0].kind);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_button_count);
    try std.testing.expectEqual(design.tokens.dark.disabled, descriptors[7].interaction_paint.?.disabled.?);
    try std.testing.expectEqual(@as(usize, 6), ui.semanticDescriptors().len);
    try std.testing.expectEqualStrings("Controls", ui.semanticDescriptors()[3].label);
    try std.testing.expectEqualStrings("Benchmark", ui.semanticDescriptors()[5].label);
    var prepared: PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, state, &sources, 9, 128);
    defer prepared.deinit();
    try ui.capturePrepared(&prepared, descriptors);
    try std.testing.expectEqual(@as(usize, 9), prepared.descriptors().len);
    try std.testing.expectEqual(@as(usize, 6), prepared.semanticDescriptors().len);
    try std.testing.expectEqualStrings("Controls", prepared.semanticDescriptors()[3].label);
    try std.testing.expectEqualStrings("Benchmark", prepared.semanticDescriptors()[5].label);
    try std.testing.expectEqual(@as(usize, 1), prepared.handler_count);
    try std.testing.expectEqual(.button, prepared.handlers[0].kind);
    try std.testing.expectEqual(@as(usize, 1), prepared.button_count);
    ui.rollbackHandlers();
    try owners.complete(work);
    try fonts.release(font);
    try fonts.release(medium_font);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "buttons retain semantics and input bindings with intrinsic or fixed custom content" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 3);
    c.lua_setglobal(state, "ouro");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var owners: build_owner.BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [4]instance.Descriptor = undefined;
    var semantics: [2]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachSemantics(&semantics);
    ui.enableDeclarativeWidgets(.dark);
    try execute(state,
        \\button_height = "auto"
        \\function build()
        \\  return ouro.button {
        \\    key = "launch", label = "Launch application", height = button_height,
        \\    on_press = function() end,
        \\    children = { ouro.box { key = "content", width = 28, height = 24 } },
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 4), descriptors.len);
    try std.testing.expect(descriptors[2].focusable);
    try std.testing.expectEqual(@as(?f32, null), descriptors[2].object.box.height);
    try std.testing.expectEqual(descriptors[2].id, descriptors[3].parent.?);
    try std.testing.expectEqual(@as(?f32, 28), descriptors[3].object.box.width);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_button_count);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_handler_count);
    try std.testing.expectEqual(.button, ui.pending_handlers[0].kind);
    try std.testing.expectEqual(descriptors[2].id, ui.pending_handlers[0].id);
    try std.testing.expectEqual(.button, ui.semanticDescriptors()[0].role);
    try std.testing.expectEqualStrings("Launch application", ui.semanticDescriptors()[0].label);
    ui.rollbackHandlers();
    try owners.complete(work);
    for ([_]struct { source: [:0]const u8, height: f32 }{
        .{ .source = "button_height = 44", .height = 44 },
        .{ .source = "button_height = nil", .height = 32 },
    }) |case| {
        try execute(state, case.source);
        _ = try owners.markDirty(owner);
        var next = owners.beginCycle();
        const update = (try next.take()).?;
        const fixed = try ui.build(&owners, update, "build", &.{});
        try std.testing.expectEqual(@as(?f32, case.height), fixed[2].object.box.height);
        ui.rollbackHandlers();
        try owners.complete(update);
    }
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(scope);
}

test "Lua constructors are pure and reject callback children" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 3);
    c.lua_setglobal(state, "ouro");
    var storage: [1]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try execute(state, "description = ouro.column { key = 'content', ouro.box { key = 'child' } }");
    try std.testing.expectEqual(@as(usize, 0), ui.count);
    try std.testing.expectEqual(@as(usize, 0), ui.pending_handler_count);
    for ([_][]const u8{
        "ouro.column { key = 'content', children = function() end }",
        "ouro.column { children = {}, ouro.box { key = 'child' } }",
        "ouro.column { key = 'content', [false] = 'invalid' }",
        "ouro.column { key = 'content', [{}] = 'invalid' }",
        "ouro.column { [1.5] = ouro.box { key = 'child' } }",
        "ouro.column { [0] = ouro.box { key = 'child' } }",
        "ouro.column { [2] = ouro.box { key = 'child' } }",
        "ouro.column { children = { [2] = ouro.box { key = 'child' } } }",
        "ouro.column { children = { named = ouro.box { key = 'child' } } }",
        "ouro.column { {} }",
        "ouro.column { false }",
        "ouro.text { key = 'leaf', text = 'Hello', ouro.box { key = 'child' } }",
        "ouro.text_editor { key = 'leaf', text = 'Hello', children = {} }",
    }) |source| try std.testing.expectError(error.LuaChunkFailed, execute(state, source));
}

test "returned descriptions snapshot props forward children and preserve keyed instances" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const RenderTree = @import("../ui/render_object/root.zig").Tree;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 16, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var owners: build_owner.BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 8);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, scope, 8);
    defer instances.deinit();
    var storage: [8]instance.Descriptor = undefined;
    var semantics: [6]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachSemantics(&semantics);
    ui.enableDeclarativeWidgets(.light);
    try execute(state,
        \\local function Card(props)
        \\  return ouro.column { key = props.key, gap = 7, children = props.children }
        \\end
        \\local props = { key = "first", width = 37 }
        \\local first = ouro.box(props)
        \\props.width = 999
        \\local second = ouro.box { key = "second", width = 61 }
        \\local children = { first, second }
        \\local card = Card { key = "card", children = children }
        \\children[1] = second
        \\local ignored = ouro.box { key = "unattached", width = 1000 }
        \\function build() return card end
        \\function reordered()
        \\  return Card { key = "card", children = { second, first } }
        \\end
        \\function invalid_root() return { card } end
        \\function empty() return nil end
    );
    try std.testing.expectEqual(@as(usize, 0), ui.count);
    var cycle = owners.beginCycle();
    const first = (try cycle.take()).?;
    const initial = try ui.build(&owners, first, "build", &.{});
    try std.testing.expectEqual(@as(usize, 5), initial.len);
    try std.testing.expectEqual(@as(f32, 7), initial[2].object.flex.gap);
    try std.testing.expectEqual(@as(?f32, 37), initial[3].object.box.width);
    try std.testing.expectEqual(@as(?f32, 61), initial[4].object.box.width);
    try std.testing.expectEqual(initial[2].id, initial[3].parent.?);
    const first_id = initial[3].id;
    const second_id = initial[4].id;
    try instances.reconcile(initial);
    const first_handle = instances.handleForId(first_id).?;
    const second_handle = instances.handleForId(second_id).?;
    ui.rollbackHandlers();
    try owners.complete(first);

    _ = try owners.markDirty(owner);
    var next = owners.beginCycle();
    const work = (try next.take()).?;
    const reordered = try ui.build(&owners, work, "reordered", &.{});
    try std.testing.expectEqual(second_id, reordered[3].id);
    try std.testing.expectEqual(first_id, reordered[4].id);
    try instances.reconcile(reordered);
    try std.testing.expectEqual(first_handle, instances.handleForId(first_id).?);
    try std.testing.expectEqual(second_handle, instances.handleForId(second_id).?);
    ui.rollbackHandlers();
    try owners.complete(work);

    _ = try owners.markDirty(owner);
    var failing = owners.beginCycle();
    const invalid_work = (try failing.take()).?;
    try std.testing.expectError(error.LuaBuildFailed, ui.build(&owners, invalid_work, "invalid_root", &.{}));
    try owners.retry(invalid_work);
    var recovery = owners.beginCycle();
    const empty_work = (try recovery.take()).?;
    const empty = try ui.build(&owners, empty_work, "empty", &.{});
    try std.testing.expectEqual(@as(usize, 2), empty.len);
    try instances.reconcile(empty);
    try std.testing.expect(instances.handleForId(first_id) == null);
    ui.rollbackHandlers();
    try owners.complete(empty_work);

    try instances.reconcile(&.{});
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(scope);
}

test "prepared descriptions stay alive across builds and release on reset" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    c.lua_createtable(state, 1, 0);
    c.lua_createtable(state, 0, 1);
    _ = c.lua_pushstring(state, "v");
    c.lua_setfield(state, -2, "__mode");
    _ = c.lua_setmetatable(state, -2);
    c.lua_setglobal(state, "weak");
    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var owners: build_owner.BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [3]instance.Descriptor = undefined;
    var semantics: [1]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachSemantics(&semantics);
    ui.enableDeclarativeWidgets(.light);
    try execute(state,
        \\function build()
        \\  local result = ouro.box { key = "prepared", width = 73 }
        \\  weak[1] = result
        \\  return result
        \\end
        \\function empty() end
    );
    var prepared: PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, state, null, 3, 64);
    defer prepared.deinit();
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try ui.capturePrepared(&prepared, descriptors);
    try owners.complete(work);
    _ = try owners.markDirty(owner);
    var next = owners.beginCycle();
    const next_work = (try next.take()).?;
    _ = try ui.build(&owners, next_work, "empty", &.{});
    try owners.complete(next_work);
    _ = c.lua_gc(state, 2); // LUA_GCCOLLECT
    _ = c.lua_getglobal(state, "weak");
    _ = c.lua_rawgeti(state, -1, 1);
    try std.testing.expect(Description.get(state, -1) != null);
    c.lua_settop(state, 0);
    try std.testing.expectEqual(@as(?f32, 73), prepared.descriptors()[2].object.box.width);
    try std.testing.expectEqualStrings("prepared", prepared.semanticDescriptors()[0].key);
    prepared.reset();
    _ = c.lua_gc(state, 2);
    _ = c.lua_getglobal(state, "weak");
    try std.testing.expectEqual(c.type_nil, c.lua_rawgeti(state, -1, 1));
    c.lua_settop(state, 0);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(scope);
}

fn execute(state: *c.State, source: []const u8) !void {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.luaL_loadbufferx(state, source.ptr, source.len, "@ui-build-test", null) != c.ok)
        return error.LuaLoadFailed;
    if (c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok) return error.LuaChunkFailed;
}

test "signals dirty only dependent mounted builds and replace dependencies transactionally" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const BuildOwners = build_owner.BuildOwners;
    const RenderTree = @import("../ui/render_object/root.zig").Tree;
    const WakeCounter = struct {
        count: usize = 0,

        fn notify(context: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };

    var signals: Signals = undefined;
    var signals_initialized = false;
    defer if (signals_initialized) signals.deinit();
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    try signals.init(std.testing.allocator, state, 6, 8, 6);
    signals_initialized = true;

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 5);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 5);
    defer instances.deinit();
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 8);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [5]instance.Descriptor = undefined;
    var semantic_storage: [3]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    ui.attachSignals(&signals);
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(.light);

    const source =
        \\count = ouro.signal(10)
        \\other = ouro.signal(30)
        \\choose_count = ouro.signal(true)
        \\duplicate = ouro.signal(false)
        \\late = ouro.signal(50)
        \\mutate = ouro.signal(false)
        \\function build()
        \\  local gap = other()
        \\  if choose_count() then gap = count() end
        \\  if mutate() then count:set(99) end
        \\  local children = { ouro.row { key = "child" } }
        \\  if duplicate() then
        \\    late()
        \\    children[#children + 1] = ouro.row { key = "child" }
        \\  end
        \\  return ouro.column {
        \\    key = "content",
        \\    gap = gap,
        \\    children = children,
        \\  }
        \\end
    ;
    try execute(state, source);

    var initial = owners.beginCycle();
    const first = (try initial.take()).?;
    const first_descriptors = try ui.build(&owners, first, "build", &.{});
    try std.testing.expectEqual(@as(f32, 10), first_descriptors[2].object.flex.gap);
    try instances.reconcile(first_descriptors);
    try ui.commitDependencies(&owners, first);
    try owners.complete(first);
    var wake_counter: WakeCounter = .{};
    owners.setDirtySink(.{ .context = &wake_counter, .notify = WakeCounter.notify });

    // Raw-equal writes are suppressed.
    try execute(state, "count:set(10)");
    var unchanged = owners.beginCycle();
    try std.testing.expect((try unchanged.take()) == null);
    try std.testing.expectEqual(@as(usize, 0), wake_counter.count);

    try execute(state, "count:set(20)");
    try std.testing.expectEqual(@as(usize, 1), wake_counter.count);
    var changed = owners.beginCycle();
    const second = (try changed.take()).?;
    const second_descriptors = try ui.build(&owners, second, "build", &.{});
    try std.testing.expectEqual(@as(f32, 20), second_descriptors[2].object.flex.gap);
    try instances.reconcile(second_descriptors);
    try ui.commitDependencies(&owners, second);
    try owners.complete(second);

    // Switch the dynamic dependency from count to other.
    try execute(state, "choose_count:set(false)");
    try std.testing.expectEqual(@as(usize, 2), wake_counter.count);
    var switched = owners.beginCycle();
    const third = (try switched.take()).?;
    const third_descriptors = try ui.build(&owners, third, "build", &.{});
    try std.testing.expectEqual(@as(f32, 30), third_descriptors[2].object.flex.gap);
    try instances.reconcile(third_descriptors);
    try ui.commitDependencies(&owners, third);
    try owners.complete(third);
    try execute(state, "count:set(40)");
    var unsubscribed = owners.beginCycle();
    try std.testing.expect((try unsubscribed.take()) == null);
    try std.testing.expectEqual(@as(usize, 2), wake_counter.count);

    // Signal writes cannot re-enter state mutation from a build callback.
    try execute(state, "mutate:set(true)");
    var mutating = owners.beginCycle();
    const mutating_work = (try mutating.take()).?;
    try std.testing.expectError(
        error.LuaBuildFailed,
        ui.build(&owners, mutating_work, "build", &.{}),
    );
    try owners.retry(mutating_work);
    try execute(state, "mutate:set(false)");
    var recovered = owners.beginCycle();
    const recovered_work = (try recovered.take()).?;
    const recovered_descriptors = try ui.build(&owners, recovered_work, "build", &.{});
    try instances.reconcile(recovered_descriptors);
    try ui.commitDependencies(&owners, recovered_work);
    try owners.complete(recovered_work);

    // A descriptor transaction failure rolls back newly observed dependencies.
    try execute(state, "duplicate:set(true)");
    var failed = owners.beginCycle();
    const failed_work = (try failed.take()).?;
    const invalid = try ui.build(&owners, failed_work, "build", &.{});
    try std.testing.expectError(error.DuplicateInstanceId, instances.reconcile(invalid));
    try ui.rollbackDependencies(&owners, failed_work);
    try owners.retry(failed_work);
    try execute(state, "duplicate:set(false)");
    var retried = owners.beginCycle();
    const retried_work = (try retried.take()).?;
    const valid = try ui.build(&owners, retried_work, "build", &.{});
    try instances.reconcile(valid);
    try ui.commitDependencies(&owners, retried_work);
    try owners.complete(retried_work);
    try execute(state, "late:set(60)");
    var rolled_back_dependency = owners.beginCycle();
    try std.testing.expect((try rolled_back_dependency.take()) == null);

    try signals.disposeOwner(.{ .owners = &owners, .handle = owner });
    try execute(state, "other:set(35)");
    var disposed = owners.beginCycle();
    try std.testing.expect((try disposed.take()) == null);
    try instances.reconcile(&.{});
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}
