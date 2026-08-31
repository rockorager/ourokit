const std = @import("std");
const c = @import("c.zig");
const design = @import("../design/root.zig");
const Signals = @import("signals.zig").Signals;
const SignalOwnerRef = @import("signals.zig").OwnerRef;
const build_owner = @import("../ui/instance/build_owner.zig");
const instance = @import("../ui/instance/tree.zig");
const PointerBindings = @import("../ui/input/bindings.zig").PointerBindings;
const Buttons = @import("../ui/widget/buttons.zig").Buttons;
const ButtonStyle = @import("../ui/widget/buttons.zig").Style;
const render_types = @import("../ui/render_object/types.zig");
const SemanticDescriptor = @import("../ui/semantics/snapshot.zig").Descriptor;
const text = @import("../text/root.zig");

const PendingHandler = struct {
    id: u64,
    reference: c_int,
    kind: @import("../ui/input/bindings.zig").HandlerKind,
};

const PendingButton = struct {
    id: u64,
    enabled: bool,
    style: ButtonStyle,
};

const ParentKind = enum { box, flex, stack };
const BuildParent = struct { id: u64, kind: ParentKind };

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

/// Constructor-specific Lua boundary. Build callbacks append already-typed
/// normalized descriptors; there is no `{ type = "..." }` parser, numeric-ID
/// escape hatch, or renderer access. A future schema generator may produce
/// this binding while preserving the native contract.
pub const UiBuild = struct {
    state: *c.State,
    storage: []instance.Descriptor,
    count: usize = 0,
    semantic_storage: []SemanticDescriptor = &.{},
    semantic_count: usize = 0,
    active_owner: ?ActiveBuildOwner = null,
    signals: ?*Signals = null,
    label_shapes: ?*text.ShapeCache = null,
    label_candidates: []const text.FontHandle = &.{},
    label_configuration_revision: u64 = 0,
    widget_theme: ?design.tokens.Theme = null,
    parent_stack: [32]BuildParent = undefined,
    parent_count: usize = 0,
    shapes_staged: bool = false,
    pending_handlers: [32]PendingHandler = undefined,
    pending_handler_count: usize = 0,
    pending_buttons: [32]PendingButton = undefined,
    pending_button_count: usize = 0,

    pub fn init(
        self: *UiBuild,
        state: *c.State,
        storage: []instance.Descriptor,
    ) !void {
        if (storage.len == 0) return error.InvalidDescriptorCapacity;
        self.* = .{ .state = state, .storage = storage };

        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        if (c.lua_getglobal(state, "ouro") != c.type_table) return error.OuroApiMissing;
        try self.install("label", emitLabel);
        try self.install("button", emitButton);
        try self.install("row", emitRow);
        try self.install("column", emitColumn);
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
        self.discardShapes();
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        const callback_type = switch (callback) {
            .global => |name| c.lua_getglobal(self.state, name),
            .reference => |reference| c.lua_rawgeti(self.state, c.registry_index, reference),
        };
        if (callback_type != c.type_function)
            return error.LuaBuildFunctionMissing;
        self.count = 0;
        self.semantic_count = 0;
        self.parent_count = 0;
        self.pending_button_count = 0;
        self.active_owner = .{ .owners = owners, .handle = work.owner };
        defer self.active_owner = null;
        if (self.widget_theme) |theme| {
            try self.append(.{
                .id = 1,
                .parent = null,
                .object = .{ .box = .{ .background = theme.surface_base } },
            });
            self.parent_stack[0] = .{ .id = 2, .kind = .stack };
            self.parent_count = 1;
            try self.append(.{
                .id = 2,
                .parent = 1,
                .object = .{ .stack = .{ .clip = true } },
            });
        }
        const signal_owner: SignalOwnerRef = .{ .owners = owners, .handle = work.owner };
        if (self.signals) |signals| try signals.beginEvaluation(signal_owner, work.revision);
        for (arguments) |argument| switch (argument) {
            .number => |value| c.lua_pushnumber(self.state, value),
            .integer => |value| c.lua_pushinteger(self.state, value),
            .boolean => |value| c.lua_pushboolean(self.state, @intFromBool(value)),
        };
        const status = c.lua_pcallk(self.state, @intCast(arguments.len), 0, 0, 0, null);
        if (status != c.ok) {
            self.discardHandlers();
            self.pending_button_count = 0;
            self.discardShapes();
            if (self.signals) |signals| try signals.abortEvaluation(signal_owner, work.revision);
            if (status == c.yield) return error.LuaBuildYielded;
            return error.LuaBuildFailed;
        }
        if (self.signals) |signals| try signals.finishEvaluation(signal_owner, work.revision);
        return self.storage[0..self.count];
    }

    /// Commits the staged Lua references only after instance reconciliation.
    /// Bindings omitted by the new build are removed, and all replaced or
    /// removed registry references are released explicitly.
    pub fn commitBindings(
        self: *UiBuild,
        bindings: *PointerBindings,
        buttons: *Buttons,
        tree: *instance.Tree,
        owner: build_owner.BuildOwnerHandle,
    ) !void {
        if (self.pending_handler_count > bindings.availableForOwner(owner))
            return error.PointerBindingCapacityExceeded;
        if (self.pending_button_count > buttons.availableForOwner(owner))
            return error.ButtonCapacityExceeded;
        for (self.pending_handlers[0..self.pending_handler_count]) |pending|
            if (tree.handleForId(pending.id) == null) return error.PointerHandlerInstanceMissing;
        for (self.pending_buttons[0..self.pending_button_count]) |pending|
            if (tree.handleForId(pending.id) == null) return error.ButtonInstanceMissing;
        while (bindings.takeInactive(tree)) |old|
            c.luaL_unref(self.state, c.registry_index, @intCast(old.id));
        while (bindings.takeOwner(owner)) |old|
            c.luaL_unref(self.state, c.registry_index, @intCast(old.id));
        for (self.pending_handlers[0..self.pending_handler_count]) |pending| {
            const old = try bindings.set(
                owner,
                tree.handleForId(pending.id).?,
                .{ .id = @intCast(pending.reference), .kind = pending.kind },
            );
            if (old) |handler| c.luaL_unref(self.state, c.registry_index, @intCast(handler.id));
        }
        buttons.beginOwner(owner);
        for (self.pending_buttons[0..self.pending_button_count]) |pending| buttons.set(
            owner,
            tree.handleForId(pending.id).?,
            pending.style,
            pending.enabled,
        );
        buttons.finishOwner(owner);
        self.pending_handler_count = 0;
        self.pending_button_count = 0;
        self.discardShapes();
    }

    pub fn rollbackHandlers(self: *UiBuild) void {
        self.discardHandlers();
        self.pending_button_count = 0;
        self.discardShapes();
    }

    pub fn clearHandlers(self: *UiBuild, bindings: *PointerBindings) void {
        while (bindings.takeAny()) |handler|
            c.luaL_unref(self.state, c.registry_index, @intCast(handler.id));
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
    }

    pub fn activeOwner(self: *const UiBuild) ?ActiveBuildOwner {
        return self.active_owner;
    }

    pub fn attachSignals(self: *UiBuild, signals: *Signals) void {
        std.debug.assert(self.active_owner == null and self.signals == null);
        self.signals = signals;
    }

    pub fn attachLabelText(
        self: *UiBuild,
        shapes: *text.ShapeCache,
        candidates: []const text.FontHandle,
        configuration_revision: u64,
    ) !void {
        if (self.active_owner != null or self.label_shapes != null or candidates.len == 0)
            return error.InvalidLabelTextService;
        self.label_shapes = shapes;
        self.label_candidates = candidates;
        self.label_configuration_revision = configuration_revision;
    }

    pub fn enableDeclarativeWidgets(self: *UiBuild, theme: design.tokens.Theme) void {
        std.debug.assert(self.active_owner == null and self.widget_theme == null);
        self.widget_theme = theme;
    }

    pub fn attachSemantics(self: *UiBuild, storage: []SemanticDescriptor) !void {
        if (self.active_owner != null or self.semantic_storage.len != 0 or storage.len == 0)
            return error.InvalidSemanticStorage;
        self.semantic_storage = storage;
    }

    pub fn semanticDescriptors(self: *const UiBuild) []const SemanticDescriptor {
        return self.semantic_storage[0..self.semantic_count];
    }

    fn install(self: *UiBuild, name: [*:0]const u8, function: c.CFunction) !void {
        c.lua_pushlightuserdata(self.state, self);
        c.lua_pushcclosure(self.state, function, 1);
        c.lua_setfield(self.state, -2, name);
    }

    fn append(self: *UiBuild, descriptor: instance.Descriptor) !void {
        if (self.active_owner == null) return error.ConstructorOutsideBuild;
        if (self.count == self.storage.len) return error.DescriptorCapacityExceeded;
        self.storage[self.count] = descriptor;
        self.count += 1;
    }

    fn appendSemantic(self: *UiBuild, descriptor: SemanticDescriptor) !void {
        if (self.semantic_count == self.semantic_storage.len)
            return error.SemanticDescriptorCapacityExceeded;
        self.semantic_storage[self.semantic_count] = descriptor;
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

    fn emitLabel(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.label expects one declaration table");
        return self.emitDeclarativeLabel(state);
    }

    fn emitButton(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        const theme = self.widget_theme orelse return luaError(state, "declarative widgets unavailable");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.button expects one declaration table");
        const key = tableString(state, 1, "key") orelse return luaError(state, "button key is required");
        const label = tableString(state, 1, "label") orelse return luaError(state, "button label is required");
        const parent = self.currentParent() orelse return luaError(state, "button requires a widget parent");
        const enabled = tableOptionalBoolean(state, 1, "enabled", true) orelse
            return luaError(state, "invalid button enabled state");
        const width = tableOptionalExtent(state, 1, "width", 160) orelse
            return luaError(state, "invalid button width");
        const height = tableOptionalExtent(
            state,
            1,
            "height",
            design.tokens.foundation.component_height_large,
        ) orelse return luaError(state, "invalid button height");
        const button_id = semanticId(key, 0x627574746f6e ^ parent.id);
        const label_id = semanticId(key, 0x6c6162656c ^ button_id);
        const style: ButtonStyle = .{
            .idle = theme.accent_default,
            .hovered = theme.accent_hovered,
            .pressed = theme.accent_pressed,
            .disabled = theme.border_default,
        };
        self.append(.{
            .id = button_id,
            .parent = parent.id,
            .object = .{ .box = .{
                .width = width,
                .height = height,
                .padding = .all(design.tokens.foundation.spacing_3),
                .background = if (enabled) style.idle else style.disabled,
            } },
            .parent_data = declarativeParentData(self, state, 1) orelse
                return luaError(state, "invalid button position"),
        }) catch return luaError(state, "cannot append button descriptor");

        const shapes = self.label_shapes orelse return luaError(state, "label text service unavailable");
        if (!text.supportsSimpleLabel(label))
            return luaError(state, "button label requires one LTR Latin-script line");
        const shape = shapes.acquire(.{
            .spec = .{
                .paragraph = label,
                .direction = .left_to_right,
                .script = .latin,
                .language = "en",
                .logical_size = design.tokens.foundation.typography_body,
            },
            .candidates = self.label_candidates,
            .configuration_revision = self.label_configuration_revision,
        }) catch return luaError(state, "cannot shape button label");
        self.append(.{
            .id = label_id,
            .parent = button_id,
            .object = .{ .label = .{
                .shape = shape,
                .color = if (enabled) theme.surface_base else theme.content_secondary,
            } },
        }) catch {
            shapes.release(shape) catch unreachable;
            return luaError(state, "cannot append button label descriptor");
        };
        self.shapes_staged = true;
        if (self.pending_button_count == self.pending_buttons.len)
            return luaError(state, "button capacity exceeded");
        self.pending_buttons[self.pending_button_count] = .{
            .id = button_id,
            .enabled = enabled,
            .style = style,
        };
        self.pending_button_count += 1;
        self.appendSemantic(.{
            .id = button_id,
            .parent = semanticParent(parent),
            .role = .button,
            .label = label,
            .enabled = enabled,
        }) catch return luaError(state, "cannot append button semantics");

        const callback_type = c.lua_getfield(state, 1, "on_press");
        defer c.lua_settop(state, -2);
        if (callback_type == c.type_nil) return 0;
        if (callback_type != c.type_function) return luaError(state, "button on_press must be a function");
        if (self.pending_handler_count == self.pending_handlers.len)
            return luaError(state, "pointer handler capacity exceeded");
        c.lua_pushvalue(state, -1);
        self.pending_handlers[self.pending_handler_count] = .{
            .id = button_id,
            .reference = c.luaL_ref(state, c.registry_index),
            .kind = .button,
        };
        self.pending_handler_count += 1;
        return 0;
    }

    fn emitDeclarativeLabel(self: *UiBuild, state: *c.State) c_int {
        const theme = self.widget_theme orelse return luaError(state, "declarative widgets unavailable");
        const parent = self.currentParent() orelse return luaError(state, "label requires a widget parent");
        const key = tableString(state, 1, "key") orelse return luaError(state, "label key is required");
        const value = tableString(state, 1, "text") orelse return luaError(state, "label text is required");
        const logical_size = tableOptionalExtent(
            state,
            1,
            "size",
            design.tokens.foundation.typography_body,
        ) orelse return luaError(state, "invalid label size");
        const shapes = self.label_shapes orelse return luaError(state, "label text service unavailable");
        if (!text.supportsSimpleLabel(value))
            return luaError(state, "label requires one LTR Latin-script line");
        const shape = shapes.acquire(.{
            .spec = .{
                .paragraph = value,
                .direction = .left_to_right,
                .script = .latin,
                .language = "en",
                .logical_size = logical_size,
            },
            .candidates = self.label_candidates,
            .configuration_revision = self.label_configuration_revision,
        }) catch return luaError(state, "cannot shape label");
        const id = semanticId(key, 0x6c6162656c ^ parent.id);
        self.append(.{
            .id = id,
            .parent = parent.id,
            .object = .{ .label = .{ .shape = shape, .color = theme.content_primary } },
            .parent_data = declarativeParentData(self, state, 1) orelse {
                shapes.release(shape) catch unreachable;
                return luaError(state, "invalid label position");
            },
        }) catch {
            shapes.release(shape) catch unreachable;
            return luaError(state, "cannot append label descriptor");
        };
        self.shapes_staged = true;
        self.appendSemantic(.{
            .id = id,
            .parent = semanticParent(parent),
            .role = .label,
            .label = value,
        }) catch return luaError(state, "cannot append label semantics");
        return 0;
    }

    fn emitRow(state: *c.State) callconv(.c) c_int {
        return emitFlexContainer(state, .horizontal);
    }

    fn emitColumn(state: *c.State) callconv(.c) c_int {
        return emitFlexContainer(state, .vertical);
    }

    fn discardHandlers(self: *UiBuild) void {
        for (self.pending_handlers[0..self.pending_handler_count]) |pending|
            c.luaL_unref(self.state, c.registry_index, pending.reference);
        self.pending_handler_count = 0;
    }

    fn discardShapes(self: *UiBuild) void {
        if (!self.shapes_staged) return;
        const shapes = self.label_shapes.?;
        for (self.storage[0..self.count]) |descriptor| switch (descriptor.object) {
            .label => |label| shapes.release(label.shape) catch unreachable,
            else => {},
        };
        self.shapes_staged = false;
    }
};

fn emitFlexContainer(state: *c.State, axis: render_types.Axis) c_int {
    const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
    if (self.widget_theme == null) return luaError(state, "declarative widgets unavailable");
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return luaError(state, "row and column expect one declaration table");
    const parent = self.currentParent() orelse return luaError(state, "container requires a widget parent");
    const key = tableString(state, 1, "key") orelse return luaError(state, "container key is required");
    const gap = tableOptionalExtent(state, 1, "gap", design.tokens.foundation.spacing_2) orelse
        return luaError(state, "invalid container gap");
    const id = semanticId(
        key,
        (if (axis == .horizontal) @as(u64, 0x726f77) else @as(u64, 0x636f6c756d6e)) ^ parent.id,
    );
    self.append(.{
        .id = id,
        .parent = parent.id,
        .object = .{ .flex = .{
            .axis = axis,
            .main_axis_size = .min,
            .cross_axis_alignment = .start,
            .gap = gap,
        } },
        .parent_data = declarativeParentData(self, state, 1) orelse
            return luaError(state, "invalid container position"),
    }) catch return luaError(state, "cannot append container descriptor");
    self.appendSemantic(.{
        .id = id,
        .parent = semanticParent(parent),
        .role = .group,
    }) catch return luaError(state, "cannot append container semantics");
    if (c.lua_getfield(state, 1, "children") != c.type_function) {
        c.lua_settop(state, -2);
        return luaError(state, "container children function is required");
    }
    self.pushParent(.{ .id = id, .kind = .flex }) catch {
        c.lua_settop(state, -2);
        return luaError(state, "widget nesting is too deep");
    };
    const status = c.lua_pcallk(state, 0, 0, 0, 0, null);
    self.popParent();
    if (status != c.ok) return c.lua_error(state);
    return 0;
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

fn declarativeParentData(self: *const UiBuild, state: *c.State, table: c_int) ?render_types.ParentData {
    const parent = self.currentParent() orelse return null;
    return switch (parent.kind) {
        .box, .flex => .none,
        .stack => stack: {
            const default = if (parent.id == 2) design.tokens.foundation.spacing_3 else 0;
            const x = tableOptionalExtent(state, table, "x", default) orelse return null;
            const y = tableOptionalExtent(state, table, "y", default) orelse return null;
            break :stack .{ .stack = .{ .x = x, .y = y } };
        },
    };
}

fn semanticId(key: []const u8, domain: u64) u64 {
    return std.hash.Wyhash.hash(domain, key) | (@as(u64, 1) << 63);
}

fn semanticParent(parent: BuildParent) ?u64 {
    return if (parent.id == 2) null else parent.id;
}

fn requiredExtent(state: *c.State, index: c_int) ?f32 {
    const value = finiteFloat(state, index) orelse return null;
    return if (value >= 0) value else null;
}

fn finiteFloat(state: *c.State, index: c_int) ?f32 {
    var is_number: c_int = 0;
    const value = c.lua_tonumberx(state, index, &is_number);
    if (is_number == 0 or !std.math.isFinite(value) or
        value < -std.math.floatMax(f32) or value > std.math.floatMax(f32)) return null;
    return @floatCast(value);
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
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
    inline for (.{ "label", "button", "row", "column" }) |name| {
        try std.testing.expectEqual(c.type_function, c.lua_getfield(state, -1, name));
        c.lua_settop(state, -2);
    }
    inline for (.{ "box", "padded_box", "stack", "positioned_box", "on_pointer" }) |name| {
        try std.testing.expectEqual(c.type_nil, c.lua_getfield(state, -1, name));
        c.lua_settop(state, -2);
    }
}

test "declarative Lua label flows through layout scene and software glyph cache" {
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
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 4);
    renders.attachTextCache(&shapes);
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
    try ui.attachLabelText(&shapes, &.{font}, 1);
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(design.tokens.light);

    try execute(state,
        \\function build()
        \\  ouro.column {
        \\    key = "content",
        \\    children = function()
        \\      ouro.label { key = "benchmark", text = "Benchmark", size = 18 }
        \\    end,
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try instances.reconcile(descriptors);
    ui.rollbackHandlers();
    try owners.complete(work);
    try std.testing.expectEqual(@as(usize, 1), shapes.count());

    const root = (try instances.rootRenderObject()).?;
    const size = try renders.layout(root, .{ .max_width = 160, .max_height = 64 });
    try std.testing.expect(size.width > 0 and size.height > 0);
    var command_storage: [8]scene.Command = undefined;
    var builder = try SceneBuilder.init(&command_storage, 1);
    try renders.buildScene(root, &builder);
    var found_glyph_run = false;
    for (builder.displayList().commands) |command| {
        if (command == .glyph_run) found_glyph_run = true;
    }
    try std.testing.expect(found_glyph_run);

    var glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer glyphs.deinit();
    var pixels = [_]u8{0} ** (160 * 64 * 4);
    try software.renderText(builder.displayList(), .{
        .pixels = &pixels,
        .width = 160,
        .height = 64,
        .stride = 160 * 4,
        .format = .rgba8_unorm,
    }, &glyphs, &shapes);
    try std.testing.expect(std.mem.indexOfNone(u8, &pixels, &.{0}) != null);

    try instances.reconcile(&.{});
    try std.testing.expectEqual(@as(usize, 0), shapes.count());
    try fonts.release(font);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "nested declarative widgets normalize to typed objects and a Button binding" {
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
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    var storage: [7]instance.Descriptor = undefined;
    var semantic_storage: [4]SemanticDescriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachLabelText(&shapes, &.{font}, 1);
    try ui.attachSemantics(&semantic_storage);
    ui.enableDeclarativeWidgets(design.tokens.light);
    try execute(state,
        \\function build()
        \\  ouro.column {
        \\    key = "content",
        \\    children = function()
        \\      ouro.label { key = "title", text = "Controls" }
        \\      ouro.row {
        \\        key = "actions",
        \\        children = function()
        \\          ouro.button {
        \\            key = "benchmark",
        \\            label = "Benchmark",
        \\            on_press = function() end,
        \\          }
        \\        end,
        \\      }
        \\    end,
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 7), descriptors.len);
    try std.testing.expect(descriptors[0].object == .box);
    try std.testing.expect(descriptors[1].object == .stack);
    try std.testing.expect(descriptors[2].object == .flex);
    try std.testing.expect(descriptors[3].object == .label);
    try std.testing.expect(descriptors[4].object == .flex);
    try std.testing.expect(descriptors[5].object == .box);
    try std.testing.expect(descriptors[6].object == .label);
    try std.testing.expectEqual(descriptors[5].id, descriptors[6].parent.?);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_handler_count);
    try std.testing.expectEqual(.button, ui.pending_handlers[0].kind);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_button_count);
    try std.testing.expectEqual(@as(usize, 4), ui.semanticDescriptors().len);
    try std.testing.expectEqualStrings("Controls", ui.semanticDescriptors()[1].label);
    try std.testing.expectEqualStrings("Benchmark", ui.semanticDescriptors()[3].label);
    ui.rollbackHandlers();
    try owners.complete(work);
    try fonts.release(font);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "Lua constructors reject calls outside the mounted build phase" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 3);
    c.lua_setglobal(state, "ouro");
    var storage: [1]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try std.testing.expectError(
        error.LuaChunkFailed,
        execute(state, "ouro.column { key = 'content', children = function() end }"),
    );
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
    ui.enableDeclarativeWidgets(design.tokens.light);

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
        \\  ouro.column {
        \\    key = "content",
        \\    gap = gap,
        \\    children = function()
        \\      ouro.row { key = "child", children = function() end }
        \\      if duplicate() then
        \\        late()
        \\        ouro.row { key = "child", children = function() end }
        \\      end
        \\    end,
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
