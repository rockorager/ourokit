const std = @import("std");
const c = @import("c.zig");
const Color = @import("../core/color.zig").Color;
const design = @import("../design/root.zig");
const Signals = @import("signals.zig").Signals;
const SignalOwnerRef = @import("signals.zig").OwnerRef;
const build_owner = @import("../ui/instance/build_owner.zig");
const instance = @import("../ui/instance/tree.zig");
const PointerBindings = @import("../ui/input/bindings.zig").PointerBindings;
const text = @import("../text/root.zig");

const PendingHandler = struct {
    id: u64,
    reference: c_int,
    kind: @import("../ui/input/bindings.zig").HandlerKind = .pointer,
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

/// Provisional constructor-specific Lua boundary. Build callbacks append
/// already-typed normalized descriptors; there is no `{ type = "..." }`
/// parser or renderer access. The eventual schema generator will replace the
/// spelling while preserving this native contract.
pub const UiBuild = struct {
    state: *c.State,
    storage: []instance.Descriptor,
    count: usize = 0,
    active_owner: ?ActiveBuildOwner = null,
    signals: ?*Signals = null,
    label_shapes: ?*text.ShapeCache = null,
    label_candidates: []const text.FontHandle = &.{},
    label_configuration_revision: u64 = 0,
    widget_theme: ?design.tokens.Theme = null,
    shapes_staged: bool = false,
    pending_handlers: [32]PendingHandler = undefined,
    pending_handler_count: usize = 0,

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
        try self.install("box", emitBox);
        try self.install("padded_box", emitPaddedBox);
        try self.install("stack", emitStack);
        try self.install("positioned_box", emitPositionedBox);
        try self.install("label", emitLabel);
        try self.install("on_pointer", bindPointer);
        try self.install("button", emitButton);
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
        self.active_owner = .{ .owners = owners, .handle = work.owner };
        defer self.active_owner = null;
        if (self.widget_theme) |theme| {
            try self.append(.{
                .id = 1,
                .parent = null,
                .object = .{ .box = .{ .background = theme.surface_base } },
            });
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
    pub fn commitHandlers(
        self: *UiBuild,
        bindings: *PointerBindings,
        tree: *instance.Tree,
        owner: build_owner.BuildOwnerHandle,
    ) !void {
        if (self.pending_handler_count > bindings.availableForOwner(owner))
            return error.PointerBindingCapacityExceeded;
        for (self.pending_handlers[0..self.pending_handler_count]) |pending|
            if (tree.handleForId(pending.id) == null) return error.PointerHandlerInstanceMissing;
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
        self.pending_handler_count = 0;
        self.discardShapes();
    }

    pub fn rollbackHandlers(self: *UiBuild) void {
        self.discardHandlers();
        self.discardShapes();
    }

    pub fn clearHandlers(self: *UiBuild, bindings: *PointerBindings) void {
        while (bindings.takeAny()) |handler|
            c.luaL_unref(self.state, c.registry_index, @intCast(handler.id));
    }

    /// Commits signal dependencies after the typed descriptor snapshot has
    /// reconciled transactionally into the retained instance tree.
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

    fn emitBox(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 5) return luaError(state, "ouro.box expects 5 arguments");
        const descriptor: instance.Descriptor = .{
            .id = integerId(state, 1) orelse return luaError(state, "invalid box id"),
            .parent = parentId(state, 2) orelse return luaError(state, "invalid box parent"),
            .object = .{ .box = .{
                .width = optionalExtent(state, 3) orelse return luaError(state, "invalid box width"),
                .height = optionalExtent(state, 4) orelse return luaError(state, "invalid box height"),
                .background = packedColor(state, 5) orelse return luaError(state, "invalid box color"),
            } },
        };
        self.append(descriptor) catch return luaError(state, "cannot append box descriptor");
        return 0;
    }

    fn emitPaddedBox(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 6) return luaError(state, "ouro.padded_box expects 6 arguments");
        const padding = requiredExtent(state, 5) orelse
            return luaError(state, "invalid box padding");
        const descriptor: instance.Descriptor = .{
            .id = integerId(state, 1) orelse return luaError(state, "invalid box id"),
            .parent = parentId(state, 2) orelse return luaError(state, "invalid box parent"),
            .object = .{ .box = .{
                .width = optionalExtent(state, 3) orelse return luaError(state, "invalid box width"),
                .height = optionalExtent(state, 4) orelse return luaError(state, "invalid box height"),
                .padding = .all(padding),
                .background = packedColor(state, 6) orelse return luaError(state, "invalid box color"),
            } },
        };
        self.append(descriptor) catch return luaError(state, "cannot append box descriptor");
        return 0;
    }

    fn emitStack(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 3) return luaError(state, "ouro.stack expects 3 arguments");
        if (c.lua_type(state, 3) != c.type_boolean) return luaError(state, "invalid stack clip");
        const descriptor: instance.Descriptor = .{
            .id = integerId(state, 1) orelse return luaError(state, "invalid stack id"),
            .parent = parentId(state, 2) orelse return luaError(state, "invalid stack parent"),
            .object = .{ .stack = .{ .clip = c.lua_toboolean(state, 3) != 0 } },
        };
        self.append(descriptor) catch return luaError(state, "cannot append stack descriptor");
        return 0;
    }

    fn emitPositionedBox(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 7) return luaError(state, "ouro.positioned_box expects 7 arguments");
        const descriptor: instance.Descriptor = .{
            .id = integerId(state, 1) orelse return luaError(state, "invalid positioned box id"),
            .parent = parentId(state, 2) orelse return luaError(state, "invalid positioned box parent"),
            .object = .{ .box = .{
                .width = requiredExtent(state, 5) orelse return luaError(state, "invalid positioned box width"),
                .height = requiredExtent(state, 6) orelse return luaError(state, "invalid positioned box height"),
                .background = packedColor(state, 7) orelse return luaError(state, "invalid positioned box color"),
            } },
            .parent_data = .{ .stack = .{
                .x = finiteFloat(state, 3) orelse return luaError(state, "invalid positioned box x"),
                .y = finiteFloat(state, 4) orelse return luaError(state, "invalid positioned box y"),
            } },
        };
        self.append(descriptor) catch return luaError(state, "cannot append positioned box descriptor");
        return 0;
    }

    fn emitLabel(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 5) return luaError(state, "ouro.label expects 5 arguments");
        const shapes = self.label_shapes orelse return luaError(state, "label text service unavailable");
        const value = string(state, 3) orelse return luaError(state, "invalid label text");
        if (!text.supportsSimpleLabel(value))
            return luaError(state, "label requires one LTR Latin-script line");
        const logical_size = requiredExtent(state, 4) orelse
            return luaError(state, "invalid label size");
        if (logical_size == 0) return luaError(state, "invalid label size");
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
        const descriptor: instance.Descriptor = .{
            .id = integerId(state, 1) orelse {
                shapes.release(shape) catch unreachable;
                return luaError(state, "invalid label id");
            },
            .parent = parentId(state, 2) orelse {
                shapes.release(shape) catch unreachable;
                return luaError(state, "invalid label parent");
            },
            .object = .{ .label = .{
                .shape = shape,
                .color = packedColor(state, 5) orelse {
                    shapes.release(shape) catch unreachable;
                    return luaError(state, "invalid label color");
                },
            } },
        };
        self.append(descriptor) catch {
            shapes.release(shape) catch unreachable;
            return luaError(state, "cannot append label descriptor");
        };
        self.shapes_staged = true;
        return 0;
    }

    fn bindPointer(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        if (c.lua_gettop(state) != 2 or c.lua_type(state, 2) != c.type_function)
            return luaError(state, "ouro.on_pointer expects instance id and function");
        const id = integerId(state, 1) orelse return luaError(state, "invalid pointer instance id");
        for (self.pending_handlers[0..self.pending_handler_count]) |*pending| if (pending.id == id) {
            c.luaL_unref(state, c.registry_index, pending.reference);
            c.lua_pushvalue(state, 2);
            pending.reference = c.luaL_ref(state, c.registry_index);
            return 0;
        };
        if (self.pending_handler_count == self.pending_handlers.len)
            return luaError(state, "pointer handler capacity exceeded");
        c.lua_pushvalue(state, 2);
        self.pending_handlers[self.pending_handler_count] = .{
            .id = id,
            .reference = c.luaL_ref(state, c.registry_index),
        };
        self.pending_handler_count += 1;
        return 0;
    }

    fn emitButton(state: *c.State) callconv(.c) c_int {
        const self = bridge(state) orelse return luaError(state, "invalid Ouro UI build context");
        const theme = self.widget_theme orelse return luaError(state, "declarative widgets unavailable");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return luaError(state, "ouro.button expects one declaration table");
        const key = tableString(state, 1, "key") orelse return luaError(state, "button key is required");
        const label = tableString(state, 1, "label") orelse return luaError(state, "button label is required");
        const x = tableOptionalExtent(state, 1, "x", design.tokens.foundation.spacing_3) orelse
            return luaError(state, "invalid button x");
        const y = tableOptionalExtent(state, 1, "y", design.tokens.foundation.spacing_3) orelse
            return luaError(state, "invalid button y");
        const width = tableOptionalExtent(state, 1, "width", 160) orelse
            return luaError(state, "invalid button width");
        const height = tableOptionalExtent(
            state,
            1,
            "height",
            design.tokens.foundation.component_height_large,
        ) orelse return luaError(state, "invalid button height");
        const button_id = semanticId(key, 0x627574746f6e);
        const label_id = semanticId(key, 0x6c6162656c);
        self.append(.{
            .id = button_id,
            .parent = 2,
            .object = .{ .box = .{
                .width = width,
                .height = height,
                .padding = .all(design.tokens.foundation.spacing_3),
                .background = theme.accent_default,
            } },
            .parent_data = .{ .stack = .{ .x = x, .y = y } },
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
            .object = .{ .label = .{ .shape = shape, .color = theme.surface_base } },
        }) catch {
            shapes.release(shape) catch unreachable;
            return luaError(state, "cannot append button label descriptor");
        };
        self.shapes_staged = true;

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
            .kind = .press,
        };
        self.pending_handler_count += 1;
        return 0;
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

fn bridge(state: *c.State) ?*UiBuild {
    const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse return null;
    const self: *UiBuild = @ptrCast(@alignCast(pointer));
    return if (self.active_owner != null) self else null;
}

fn integerId(state: *c.State, index: c_int) ?u64 {
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, index, &is_number);
    if (is_number == 0 or value <= 0) return null;
    return @intCast(value);
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

fn semanticId(key: []const u8, domain: u64) u64 {
    return std.hash.Wyhash.hash(domain, key) | (@as(u64, 1) << 63);
}

/// Parent zero is the compact root sentinel. Returning a nested optional lets
/// callers distinguish a valid root from malformed input.
fn parentId(state: *c.State, index: c_int) ??u64 {
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, index, &is_number);
    if (is_number == 0 or value < 0) return null;
    return if (value == 0) @as(?u64, null) else @as(?u64, @intCast(value));
}

fn optionalExtent(state: *c.State, index: c_int) ??f32 {
    if (c.lua_type(state, index) == c.type_nil) return @as(?f32, null);
    const value = requiredExtent(state, index) orelse return null;
    return @as(?f32, value);
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

fn packedColor(state: *c.State, index: c_int) ?Color {
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, index, &is_number);
    if (is_number == 0 or value < 0 or value > std.math.maxInt(u32)) return null;
    const encoded: u32 = @intCast(value);
    return Color.rgba(
        @truncate(encoded >> 24),
        @truncate(encoded >> 16),
        @truncate(encoded >> 8),
        @truncate(encoded),
    );
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "Lua build emits typed normalized descriptors without standard libraries" {
    const Scheduler = @import("../task/scheduler.zig").Scheduler;
    const BuildOwners = build_owner.BuildOwners;
    const RenderTree = @import("../ui/render_object/root.zig").Tree;

    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 3);
    c.lua_setglobal(state, "ouro");
    try std.testing.expectEqual(c.type_nil, c.lua_getglobal(state, "print"));
    c.lua_settop(state, -2);

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 3);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 3);
    defer instances.deinit();
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [3]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);

    const source =
        \\function build()
        \\  ouro.stack(1, 0, true)
        \\  ouro.box(2, 1, nil, nil, 0x112233ff)
        \\  ouro.positioned_box(3, 1, 4, 5, 20, 10, 0xaabbccff)
        \\end
    ;
    try execute(state, source);
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 3), descriptors.len);
    try std.testing.expect(descriptors[0].object.stack.clip);
    try std.testing.expectEqual(@as(u8, 0x11), descriptors[1].object.box.background.?.r);
    try std.testing.expectEqual(@as(f32, 4), descriptors[2].parent_data.stack.x);
    try instances.reconcile(descriptors);
    try owners.complete(work);

    try instances.reconcile(&.{});
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "Lua composed button label flows through layout scene and software glyph cache" {
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
    try renders.init(std.testing.allocator, 2);
    renders.attachTextCache(&shapes);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 2);
    defer instances.deinit();
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [2]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachLabelText(&shapes, &.{font}, 1);

    try execute(state,
        \\function build()
        \\  ouro.padded_box(1, 0, 120, 36, 8, 0xf0f0f0ff)
        \\  ouro.label(2, 1, "Benchmark", 18, 0x142850ff)
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
    const size = try renders.layout(root, .{ .max_width = 160, .max_height = 36 });
    try std.testing.expectEqual(@as(f32, 120), size.width);
    try std.testing.expectEqual(@as(f32, 36), size.height);
    var command_storage: [4]scene.Command = undefined;
    var builder = try SceneBuilder.init(&command_storage, 1);
    try renders.buildScene(root, &builder);
    try std.testing.expectEqual(@as(usize, 4), builder.displayList().commands.len);
    try std.testing.expect(builder.displayList().commands[2] == .glyph_run);

    var glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer glyphs.deinit();
    var pixels = [_]u8{0} ** (160 * 36 * 4);
    try software.renderText(builder.displayList(), .{
        .pixels = &pixels,
        .width = 160,
        .height = 36,
        .stride = 160 * 4,
        .format = .rgba8_unorm,
    }, &glyphs, &shapes);
    var ink: usize = 0;
    for (0..pixels.len / 4) |index| {
        if (!std.mem.eql(u8, pixels[index * 4 ..][0..4], &.{ 240, 240, 240, 255 }))
            ink += 1;
    }
    try std.testing.expect(ink > 200);

    try instances.reconcile(&.{});
    try std.testing.expectEqual(@as(usize, 0), shapes.count());
    try fonts.release(font);
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try instances.collectRetired();
    try owners.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "declarative button normalizes to typed objects and a press binding" {
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
    var storage: [4]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    try ui.attachLabelText(&shapes, &.{font}, 1);
    ui.enableDeclarativeWidgets(design.tokens.light);
    try execute(state,
        \\function build()
        \\  ouro.button {
        \\    key = "benchmark",
        \\    label = "Benchmark",
        \\    on_press = function() end,
        \\  }
        \\end
    );
    var cycle = owners.beginCycle();
    const work = (try cycle.take()).?;
    const descriptors = try ui.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 4), descriptors.len);
    try std.testing.expect(descriptors[0].object == .box);
    try std.testing.expect(descriptors[1].object == .stack);
    try std.testing.expect(descriptors[2].object == .box);
    try std.testing.expect(descriptors[3].object == .label);
    try std.testing.expectEqual(descriptors[2].id, descriptors[3].parent.?);
    try std.testing.expectEqual(@as(usize, 1), ui.pending_handler_count);
    try std.testing.expectEqual(.press, ui.pending_handlers[0].kind);
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
    try std.testing.expectError(error.LuaChunkFailed, execute(state, "ouro.box(1, 0, nil, nil, 0xffffffff)"));
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
    try renders.init(std.testing.allocator, 2);
    defer renders.deinit();
    var instances: instance.Tree = undefined;
    try instances.init(std.testing.allocator, &scheduler, &renders, window_scope, 2);
    defer instances.deinit();
    var owners: BuildOwners = undefined;
    try owners.init(std.testing.allocator, &scheduler, window_scope, 1, 8);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var storage: [2]instance.Descriptor = undefined;
    var ui: UiBuild = undefined;
    try ui.init(state, &storage);
    ui.attachSignals(&signals);

    const source =
        \\count = ouro.signal(10)
        \\other = ouro.signal(30)
        \\choose_count = ouro.signal(true)
        \\duplicate = ouro.signal(false)
        \\late = ouro.signal(50)
        \\mutate = ouro.signal(false)
        \\function build()
        \\  local width = other()
        \\  if choose_count() then width = count() end
        \\  if mutate() then count:set(99) end
        \\  ouro.box(1, 0, width, 10, 0xffffffff)
        \\  if duplicate() then
        \\    late()
        \\    ouro.box(1, 0, 1, 1, 0xffffffff)
        \\  end
        \\end
    ;
    try execute(state, source);

    var initial = owners.beginCycle();
    const first = (try initial.take()).?;
    const first_descriptors = try ui.build(&owners, first, "build", &.{});
    try std.testing.expectEqual(@as(f32, 10), first_descriptors[0].object.box.width.?);
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
    try std.testing.expectEqual(@as(f32, 20), second_descriptors[0].object.box.width.?);
    try instances.reconcile(second_descriptors);
    try ui.commitDependencies(&owners, second);
    try owners.complete(second);

    // Switch the dynamic dependency from count to other.
    try execute(state, "choose_count:set(false)");
    try std.testing.expectEqual(@as(usize, 2), wake_counter.count);
    var switched = owners.beginCycle();
    const third = (try switched.take()).?;
    const third_descriptors = try ui.build(&owners, third, "build", &.{});
    try std.testing.expectEqual(@as(f32, 30), third_descriptors[0].object.box.width.?);
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
