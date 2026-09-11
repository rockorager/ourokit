const std = @import("std");
const c = @import("c.zig");
const diagnostic = @import("diagnostic.zig");
const platform = @import("../platform/window.zig");
const task = @import("../task/root.zig");
const vm_module = @import("vm.zig");
const varlink_json = @import("varlink_client.zig");
const varlink = @import("../varlink/root.zig");
const theming = @import("theme.zig");

pub const Window = struct {
    declaration: platform.SurfaceDeclaration,
    content_reference: c_int,
    all_outputs: bool = false,
    template_id: ?[]const u8 = null,
};

pub const Definition = struct {
    allocator: std.mem.Allocator,
    state: *c.State,
    id: []u8,
    theme: ?theming.Theme = null,
    inherited_colors: theming.ColorFields = .initEmpty(),
    action_schema: ?varlink.Service = null,
    actions_reference: c_int = c.no_reference,
    run_reference: c_int = c.no_reference,
    legacy_windows: ?[]Window = null,

    pub fn parseStack(allocator: std.mem.Allocator, state: *c.State) !Definition {
        return parseDefinition(allocator, state);
    }

    pub fn hasActions(self: *const Definition) bool {
        return self.actions_reference != c.no_reference;
    }

    pub fn hasRun(self: *const Definition) bool {
        return self.run_reference != c.no_reference;
    }

    pub fn deinit(self: *Definition) void {
        if (self.action_schema) |*schema| schema.deinit();
        if (self.legacy_windows) |windows| {
            for (windows) |window| deinitWindow(self.allocator, self.state, window);
            self.allocator.free(windows);
        }
        if (self.run_reference != c.no_reference)
            c.luaL_unref(self.state, c.registry_index, self.run_reference);
        if (self.actions_reference != c.no_reference)
            c.luaL_unref(self.state, c.registry_index, self.actions_reference);
        self.allocator.free(self.id);
        self.* = undefined;
    }

    fn finish(self: *Definition, windows: []Window) Application {
        const application: Application = .{
            .allocator = self.allocator,
            .state = self.state,
            .id = self.id,
            .theme = self.theme,
            .inherited_colors = self.inherited_colors,
            .action_schema = self.action_schema,
            .actions_reference = self.actions_reference,
            .run_reference = self.run_reference,
            .windows = windows,
        };
        self.id = self.id[0..0];
        self.action_schema = null;
        self.actions_reference = c.no_reference;
        self.run_reference = c.no_reference;
        self.legacy_windows = null;
        return application;
    }
};

/// One yieldable application-entry evaluation. The bootstrap task retains its
/// sole Lua result until `take` parses it into native-owned declaration data.
pub const Bootstrap = struct {
    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    task_handle: vm_module.TaskHandle,
    scope: task.ScopeHandle,
    definition: ?Definition = null,
    phase: enum { entry, run } = .entry,
    defer_run: bool = false,

    pub fn start(
        allocator: std.mem.Allocator,
        vm: *vm_module.Vm,
        scope: task.ScopeHandle,
        source: []const u8,
        chunk_name: [*:0]const u8,
    ) !Bootstrap {
        try Application.installApi(vm.state, vm.apiReference());
        return .{
            .allocator = allocator,
            .vm = vm,
            .task_handle = try vm.spawnRetainedNamed(scope, source, chunk_name),
            .scope = scope,
        };
    }

    /// Advances entry evaluation to `run(context)` and returns the complete UI
    /// declaration only after the run coroutine also finishes. A null result
    /// means the run task was scheduled and may now yield opaquely.
    pub fn advance(self: *Bootstrap, instance_id: []const u8) !?Application {
        const top = c.lua_gettop(self.vm.state);
        defer c.lua_settop(self.vm.state, top);
        try self.vm.takeRetainedResult(self.task_handle);
        switch (self.phase) {
            .entry => {
                var definition = try Definition.parseStack(self.allocator, self.vm.state);
                if (self.defer_run) {
                    errdefer definition.deinit();
                    if (definition.legacy_windows) |windows| {
                        if (definition.hasActions()) return error.EagerWindowsInHeadlessApplication;
                        return definition.finish(windows);
                    }
                    return definition.finish(try self.allocator.alloc(Window, 0));
                }
                if (definition.legacy_windows) |windows| {
                    definition.legacy_windows = null;
                    return definition.finish(windows);
                }
                if (!definition.hasRun()) {
                    definition.deinit();
                    return error.ApplicationRunRequired;
                }
                self.task_handle = self.vm.spawnRetainedRun(
                    self.scope,
                    definition.run_reference,
                    instance_id,
                ) catch |err| {
                    definition.deinit();
                    return err;
                };
                self.definition = definition;
                self.phase = .run;
                return null;
            },
            .run => {
                var definition = self.definition orelse return error.ApplicationDefinitionMissing;
                self.definition = null;
                errdefer definition.deinit();
                return definition.finish(try parseRunWindows(
                    self.allocator,
                    self.vm.state,
                ));
            },
        }
    }

    pub fn take(self: *Bootstrap) !Application {
        return (try self.advance("default")) orelse error.ApplicationRunPending;
    }

    pub fn deinit(self: *Bootstrap) void {
        if (self.definition) |*definition| definition.deinit();
        self.* = undefined;
    }
};

/// One validated application declaration. Strings are native-owned and every
/// content callback is anchored in the registry until `deinit`.
pub const Application = struct {
    allocator: std.mem.Allocator,
    state: *c.State,
    id: []u8,
    theme: ?theming.Theme = null,
    inherited_colors: theming.ColorFields = .initEmpty(),
    action_schema: ?varlink.Service = null,
    actions_reference: c_int,
    run_reference: c_int,
    windows: []Window,
    output_templates: []Window = &.{},

    /// Materialize each all-output declaration once per output name. Retain
    /// disconnected names so the native host can recreate their surfaces and
    /// preserve UI identity when they return.
    pub fn expandOutput(self: *Application, name: []const u8, capacity: usize) !bool {
        try self.extractOutputTemplates();
        var changed = false;
        for (self.output_templates) |template| {
            var found = false;
            for (self.windows) |window| {
                if (window.template_id) |id| {
                    if (std.mem.eql(u8, id, template.declaration.id()) and
                        std.mem.eql(u8, window.declaration.layer_surface.output.?, name))
                    {
                        found = true;
                        break;
                    }
                }
            }
            if (found) continue;
            if (self.windows.len >= capacity) return error.WindowCapacityExceeded;
            var layer = template.declaration.layer_surface;
            layer.id = try std.fmt.allocPrint(self.allocator, "{s}@{d}:{s}", .{ layer.id, name.len, name });
            errdefer self.allocator.free(layer.id);
            layer.namespace = try self.allocator.dupe(u8, layer.namespace);
            errdefer self.allocator.free(layer.namespace);
            layer.output = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(layer.output.?);
            for (self.windows) |window| if (std.mem.eql(u8, window.declaration.id(), layer.id))
                return error.DuplicateWindowId;
            const windows = try self.allocator.realloc(self.windows, self.windows.len + 1);
            self.windows = windows;
            _ = c.lua_rawgeti(self.state, c.registry_index, template.content_reference);
            _ = c.lua_pushlstring(self.state, name.ptr, name.len);
            c.lua_pushcclosure(self.state, outputContent, 2);
            windows[windows.len - 1] = .{
                .declaration = .{ .layer_surface = layer },
                .content_reference = c.luaL_ref(self.state, c.registry_index),
                .template_id = template.declaration.id(),
            };
            changed = true;
        }
        return changed;
    }

    pub fn extractOutputTemplates(self: *Application) !void {
        var count: usize = 0;
        for (self.windows) |window| if (window.all_outputs) {
            count += 1;
        };
        if (count == 0) return;
        for (self.windows, 0..) |window, index| {
            for (self.windows[0..index]) |prior| if (std.mem.eql(u8, window.declaration.id(), prior.declaration.id()))
                return error.DuplicateWindowId;
        }
        const templates = try self.allocator.alloc(Window, count);
        errdefer self.allocator.free(templates);
        const windows = try self.allocator.alloc(Window, self.windows.len - count);
        var ti: usize = 0;
        var wi: usize = 0;
        for (self.windows) |window| {
            if (window.all_outputs) {
                templates[ti] = window;
                ti += 1;
            } else {
                windows[wi] = window;
                wi += 1;
            }
        }
        self.allocator.free(self.windows);
        self.windows = windows;
        self.output_templates = templates;
    }

    fn outputContent(state: *c.State) callconv(.c) c_int {
        c.lua_pushvalue(state, c.upvalueIndex(1));
        c.lua_pushvalue(state, c.upvalueIndex(2));
        if (c.lua_pcallk(state, 1, 1, 0, 0, null) != c.ok) return c.lua_error(state);
        return 1;
    }

    pub fn resolvedTheme(self: *const Application, base: @import("../design/root.zig").tokens.Theme) theming.Theme {
        var result = self.theme orelse return .{ .colors = base };
        inline for (std.meta.fields(@TypeOf(base)), 0..) |field, i| {
            if (self.inherited_colors.contains(@enumFromInt(i)))
                @field(result.colors, field.name) = @field(base, field.name);
        }
        return result;
    }

    pub fn load(
        allocator: std.mem.Allocator,
        state: *c.State,
        source: []const u8,
    ) !Application {
        return loadNamed(allocator, state, source, "@application", null);
    }

    pub fn loadNamed(
        allocator: std.mem.Allocator,
        state: *c.State,
        source: []const u8,
        chunk_name: [*:0]const u8,
        diagnostic_output: ?*?diagnostic.Diagnostic,
    ) !Application {
        return loadNamedWithApiReference(
            allocator,
            state,
            source,
            chunk_name,
            diagnostic_output,
            null,
        );
    }

    pub fn loadNamedWithApi(
        allocator: std.mem.Allocator,
        state: *c.State,
        source: []const u8,
        chunk_name: [*:0]const u8,
        diagnostic_output: ?*?diagnostic.Diagnostic,
        api_reference: c_int,
    ) !Application {
        return loadNamedWithApiReference(
            allocator,
            state,
            source,
            chunk_name,
            diagnostic_output,
            api_reference,
        );
    }

    fn loadNamedWithApiReference(
        allocator: std.mem.Allocator,
        state: *c.State,
        source: []const u8,
        chunk_name: [*:0]const u8,
        diagnostic_output: ?*?diagnostic.Diagnostic,
        api_reference: ?c_int,
    ) !Application {
        try installConstructors(state, api_reference);
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        if (c.luaL_loadbufferx(state, source.ptr, source.len, chunk_name, null) != c.ok) {
            diagnostic.recordLuaStack(
                diagnostic_output,
                allocator,
                .compile,
                sourceName(chunk_name),
                state,
            );
            return error.LuaLoadFailed;
        }
        if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok) {
            diagnostic.recordLuaStack(
                diagnostic_output,
                allocator,
                .evaluate,
                sourceName(chunk_name),
                state,
            );
            return error.LuaApplicationFailed;
        }
        var definition = parseDefinition(allocator, state) catch |err| {
            diagnostic.recordError(
                diagnostic_output,
                allocator,
                .declaration,
                sourceName(chunk_name),
                err,
            );
            return err;
        };
        errdefer definition.deinit();
        if (definition.legacy_windows) |windows| {
            definition.legacy_windows = null;
            return definition.finish(windows);
        }
        if (!definition.hasRun()) return error.ApplicationRunRequired;
        const windows = invokeRun(
            allocator,
            state,
            definition.run_reference,
            "default",
        ) catch |err| {
            if (err == error.LuaApplicationRunFailed) {
                diagnostic.recordLuaStack(
                    diagnostic_output,
                    allocator,
                    .evaluate,
                    sourceName(chunk_name),
                    state,
                );
            } else diagnostic.recordError(
                diagnostic_output,
                allocator,
                .declaration,
                sourceName(chunk_name),
                err,
            );
            return err;
        };
        return definition.finish(windows);
    }

    pub fn installApi(state: *c.State, api_reference: c_int) !void {
        try installConstructors(state, api_reference);
    }

    /// Parses the application declaration at the top of the Lua stack. The
    /// caller retains stack ownership and may pop the declaration afterward.
    pub fn parseStack(allocator: std.mem.Allocator, state: *c.State) !Application {
        var definition = try parseDefinition(allocator, state);
        errdefer definition.deinit();
        if (definition.legacy_windows) |windows| {
            definition.legacy_windows = null;
            return definition.finish(windows);
        }
        if (!definition.hasRun()) return error.ApplicationRunRequired;
        return definition.finish(try invokeRun(
            allocator,
            state,
            definition.run_reference,
            "default",
        ));
    }

    pub fn hasActions(self: *const Application) bool {
        return self.actions_reference != c.no_reference;
    }

    pub fn hasRun(self: *const Application) bool {
        return self.run_reference != c.no_reference;
    }

    pub fn customInterface(self: *const Application) ?*const varlink.Interface {
        const schema = &(self.action_schema orelse return null);
        return &schema.interfaces.items[1];
    }

    pub fn startUi(self: *const Application, vm: *vm_module.Vm, scope: task.ScopeHandle, instance_id: []const u8) !vm_module.TaskHandle {
        if (vm.state != self.state) return error.ApplicationVmMismatch;
        if (!self.hasRun()) return error.ApplicationRunRequired;
        if (self.windows.len != 0) return error.ApplicationUiAlreadyStarted;
        return vm.spawnRetainedRun(scope, self.run_reference, instance_id);
    }

    pub fn finishUi(self: *Application, vm: *vm_module.Vm, handle: vm_module.TaskHandle) !void {
        if (vm.state != self.state) return error.ApplicationVmMismatch;
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        try vm.takeRetainedResult(handle);
        const windows = try parseRunWindows(self.allocator, self.state);
        for (self.windows) |window| deinitWindow(self.allocator, self.state, window);
        self.allocator.free(self.windows);
        self.windows = windows;
    }

    /// Schedules a custom action without executing Lua. Arguments are copied
    /// before the transport releases its request, and belong to the task.
    pub fn startAction(
        self: *const Application,
        vm: *vm_module.Vm,
        scope: task.ScopeHandle,
        name: []const u8,
        parameters: ?std.json.Value,
    ) !vm_module.TaskHandle {
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        if (!self.hasActions()) return error.ActionNotFound;
        _ = c.lua_rawgeti(self.state, c.registry_index, self.actions_reference);
        // Names have already been checked against the native IDL methods.
        _ = c.lua_pushlstring(self.state, name.ptr, name.len);
        if (c.lua_rawget(self.state, -2) != c.type_function) return error.ActionNotFound;
        const reference = c.luaL_ref(self.state, c.registry_index);
        defer c.luaL_unref(self.state, c.registry_index, reference);
        if (parameters) |value| {
            if (value != .null) {
                try varlink_json.pushJson(self.state, value);
            } else c.lua_createtable(self.state, 0, 0);
        } else c.lua_createtable(self.state, 0, 0);
        const argument = c.luaL_ref(self.state, c.registry_index);
        defer c.luaL_unref(self.state, c.registry_index, argument);
        return vm.spawnRetainedReference(scope, reference, &.{.{ .registry = argument }});
    }

    /// Converts the first action return value to arena-owned JSON and releases
    /// the retained coroutine, even when the returned value cannot be encoded.
    pub const ActionResult = union(enum) {
        output: std.json.Value,
        declared_error: struct { name: []const u8, parameters: std.json.Value },
    };

    pub fn takeActionResult(
        vm: *vm_module.Vm,
        handle: vm_module.TaskHandle,
        arena: std.mem.Allocator,
    ) !ActionResult {
        const top = c.lua_gettop(vm.state);
        defer c.lua_settop(vm.state, top);
        try vm.takeRetainedValue(handle);
        // No Lua return value is an empty output object. The method schema
        // still rejects it if required output fields are missing.
        if (c.lua_type(vm.state, -1) == c.type_nil)
            return .{ .output = .{ .object = .empty } };
        if (c.lua_type(vm.state, -1) != c.type_table) return error.ActionOutputTableRequired;
        var count: usize = 0;
        _ = c.lua_getfield(vm.state, -1, "__ouro_action_error");
        const is_error = c.lua_touserdata(vm.state, -1) == @as(?*anyopaque, &action_error_tag);
        c.lua_settop(vm.state, -2);
        if (is_error) {
            _ = c.lua_getfield(vm.state, -1, "name");
            var length: usize = 0;
            const name = c.lua_tolstring(vm.state, -1, &length) orelse return error.InvalidActionError;
            const owned_name = try arena.dupe(u8, name[0..length]);
            c.lua_settop(vm.state, -2);
            _ = c.lua_getfield(vm.state, -1, "parameters");
            return .{ .declared_error = .{ .name = owned_name, .parameters = try varlink_json.luaToJson(vm.state, -1, arena, 0, &count) } };
        }
        return .{ .output = try varlink_json.luaToJson(vm.state, -1, arena, 0, &count) };
    }

    pub fn deinit(self: *Application) void {
        if (self.action_schema) |*schema| schema.deinit();
        for (self.windows) |window| deinitWindow(self.allocator, self.state, window);
        self.allocator.free(self.windows);
        for (self.output_templates) |window| deinitWindow(self.allocator, self.state, window);
        self.allocator.free(self.output_templates);
        if (self.run_reference != c.no_reference)
            c.luaL_unref(self.state, c.registry_index, self.run_reference);
        if (self.actions_reference != c.no_reference)
            c.luaL_unref(self.state, c.registry_index, self.actions_reference);
        self.allocator.free(self.id);
        self.* = undefined;
    }
};

fn parseDefinition(allocator: std.mem.Allocator, state: *c.State) !Definition {
    if (c.lua_type(state, -1) != c.type_table) return error.ApplicationDeclarationRequired;
    var inherited_colors = theming.ColorFields.initEmpty();
    const theme = blk: {
        const kind = c.lua_getfield(state, -1, "theme");
        defer c.lua_settop(state, -2);
        if (kind == c.type_nil) break :blk null;
        const value = try theming.apply(state, -1, .{
            .colors = @import("../design/root.zig").tokens.light,
        });
        inherited_colors = theming.inheritedColors(state, -1);
        break :blk value;
    };
    const id = try requiredString(allocator, state, -1, "id");
    errdefer allocator.free(id);
    const actions_reference = try optionalActions(state, -1);
    errdefer if (actions_reference != c.no_reference)
        c.luaL_unref(state, c.registry_index, actions_reference);
    var action_schema = try parseActionSchema(allocator, state, actions_reference);
    errdefer if (action_schema) |*schema| schema.deinit();
    const run_reference = try optionalFunction(state, -1, "run");
    errdefer if (run_reference != c.no_reference)
        c.luaL_unref(state, c.registry_index, run_reference);
    const legacy_windows = try optionalWindows(allocator, state, -1);
    errdefer if (legacy_windows) |windows| {
        for (windows) |window| deinitWindow(allocator, state, window);
        allocator.free(windows);
    };
    if (run_reference != c.no_reference and legacy_windows != null)
        return error.ConflictingApplicationRun;
    return .{
        .allocator = allocator,
        .state = state,
        .id = id,
        .theme = theme,
        .inherited_colors = inherited_colors,
        .action_schema = action_schema,
        .actions_reference = actions_reference,
        .run_reference = run_reference,
        .legacy_windows = legacy_windows,
    };
}

fn parseActionSchema(allocator: std.mem.Allocator, state: *c.State, actions: c_int) !?varlink.Service {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const description = try optionalString(allocator, state, -1, "interface");
    defer if (description) |value| allocator.free(value);
    var schema: ?varlink.Service = null;
    errdefer if (schema) |*value| value.deinit();
    if (description) |source| {
        schema = try varlink.Service.init(allocator, .{ .vendor = "Ourokit", .product = "Application", .version = "1", .url = "https://github.com/rockorager/ourokit" }, 2);
        try schema.?.addInterface(source);
        if (std.mem.eql(u8, schema.?.interfaces.items[1].name, "dev.ourokit.runtime")) return error.ReservedApplicationInterface;
    }
    var handler_count: usize = 0;
    if (actions != c.no_reference) {
        _ = c.lua_rawgeti(state, c.registry_index, actions);
        c.lua_pushnil(state);
        while (c.lua_next(state, -2) != 0) {
            handler_count += 1;
            const interface = if (schema) |*value| &value.interfaces.items[1] else return error.ActionInterfaceRequired;
            var length: usize = 0;
            const name = c.lua_tolstring(state, -2, &length).?;
            if (interface.method(name[0..length]) == null) return error.ActionMethodMismatch;
            c.lua_settop(state, -2);
        }
    }
    var method_count: usize = 0;
    if (schema) |*value| for (value.interfaces.items[1].members) |member| {
        if (member == .method) method_count += 1;
    };
    if (method_count != handler_count) return error.ActionMethodMismatch;
    return schema;
}

fn invokeRun(
    allocator: std.mem.Allocator,
    state: *c.State,
    reference: c_int,
    instance_id: []const u8,
) ![]Window {
    if (c.lua_rawgeti(state, c.registry_index, reference) != c.type_function)
        return error.ApplicationRunMissing;
    c.lua_createtable(state, 0, 1);
    _ = c.lua_pushlstring(state, instance_id.ptr, instance_id.len);
    c.lua_setfield(state, -2, "instance_id");
    if (c.lua_pcallk(state, 1, 1, 0, 0, null) != c.ok)
        return error.LuaApplicationRunFailed;
    return parseRunWindows(allocator, state);
}

fn optionalActions(state: *c.State, table: c_int) !c_int {
    const value_type = c.lua_getfield(state, table, "actions");
    if (value_type == c.type_nil) {
        c.lua_settop(state, -2);
        return c.no_reference;
    }
    if (value_type != c.type_table) {
        c.lua_settop(state, -2);
        return error.InvalidActionsDeclaration;
    }
    c.lua_pushnil(state);
    while (c.lua_next(state, -2) != 0) {
        if (c.lua_type(state, -2) != c.type_string or
            c.lua_type(state, -1) != c.type_function)
        {
            c.lua_settop(state, -3);
            c.lua_settop(state, -2);
            return error.InvalidActionDeclaration;
        }
        var name_length: usize = 0;
        _ = c.lua_tolstring(state, -2, &name_length);
        if (name_length == 0) {
            c.lua_settop(state, -3);
            c.lua_settop(state, -2);
            return error.InvalidActionDeclaration;
        }
        c.lua_settop(state, -2);
    }
    return c.luaL_ref(state, c.registry_index);
}

fn optionalFunction(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) !c_int {
    const value_type = c.lua_getfield(state, table, field);
    if (value_type == c.type_nil) {
        c.lua_settop(state, -2);
        return c.no_reference;
    }
    if (value_type != c.type_function) {
        c.lua_settop(state, -2);
        return error.ApplicationRunInvalid;
    }
    return c.luaL_ref(state, c.registry_index);
}

fn optionalWindows(
    allocator: std.mem.Allocator,
    state: *c.State,
    table: c_int,
) !?[]Window {
    const value_type = c.lua_getfield(state, table, "windows");
    if (value_type == c.type_nil) {
        c.lua_settop(state, -2);
        return null;
    }
    if (value_type != c.type_table) {
        c.lua_settop(state, -2);
        return error.InvalidWindowsDeclaration;
    }
    defer c.lua_settop(state, -2);
    return @as(?[]Window, try parseWindowsTable(allocator, state));
}

fn parseRunWindows(allocator: std.mem.Allocator, state: *c.State) ![]Window {
    if (c.lua_type(state, -1) != c.type_table) return error.ApplicationRunDeclarationRequired;
    if (c.lua_getfield(state, -1, "windows") != c.type_table)
        return error.WindowsDeclarationRequired;
    defer c.lua_settop(state, -2);
    return parseWindowsTable(allocator, state);
}

fn parseWindowsTable(allocator: std.mem.Allocator, state: *c.State) ![]Window {
    const count = c.lua_rawlen(state, -1);
    if (count == 0) return error.ApplicationRequiresWindow;
    const windows = try allocator.alloc(Window, count);
    errdefer allocator.free(windows);
    var initialized: usize = 0;
    errdefer for (windows[0..initialized]) |window| deinitWindow(allocator, state, window);
    for (windows, 1..) |*window, index| {
        if (c.lua_rawgeti(state, -1, @intCast(index)) != c.type_table)
            return error.InvalidWindowDeclaration;
        const window_id = try requiredString(allocator, state, -1, "id");
        errdefer allocator.free(window_id);
        const role = try surfaceRole(state, -1);
        const outputs_type = c.lua_getfield(state, -1, "outputs");
        var outputs_length: usize = 0;
        const all_outputs = outputs_type == c.type_string and
            std.mem.eql(u8, c.lua_tolstring(state, -1, &outputs_length).?[0..outputs_length], "all");
        c.lua_settop(state, -2);
        if (outputs_type != c.type_nil and (!all_outputs or role != .layer_surface))
            return error.InvalidOutputSelector;
        const declaration: platform.SurfaceDeclaration = switch (role) {
            .toplevel => blk: {
                const title = try requiredString(allocator, state, -1, "title");
                errdefer allocator.free(title);
                const width = try optionalDimension(state, -1, "width", 640);
                const height = try optionalDimension(state, -1, "height", 480);
                const min_width = try optionalNonNegativeDimension(state, -1, "min_width", 0);
                const min_height = try optionalNonNegativeDimension(state, -1, "min_height", 0);
                if (min_width > width or min_height > height)
                    return error.MinimumWindowSizeExceedsInitialSize;
                break :blk .{ .toplevel = .{
                    .id = window_id,
                    .title = title,
                    .initial_width = width,
                    .initial_height = height,
                    .min_width = min_width,
                    .min_height = min_height,
                } };
            },
            .layer_surface => blk: {
                const namespace = try requiredString(allocator, state, -1, "namespace");
                errdefer allocator.free(namespace);
                const output = try optionalString(allocator, state, -1, "output");
                errdefer if (output) |value| allocator.free(value);
                if (all_outputs and output != null) return error.ConflictingOutputSelectors;
                const layer_surface: platform.LayerSurfaceDeclaration = .{
                    .id = window_id,
                    .namespace = namespace,
                    .output = output,
                    .width = try optionalNonNegativeDimension(state, -1, "width", 0),
                    .height = try optionalNonNegativeDimension(state, -1, "height", 0),
                    .layer = try requiredEnum(platform.Layer, state, -1, "layer"),
                    .anchors = try optionalAnchors(state, -1),
                    .exclusive_zone = try optionalSignedInteger(state, -1, "exclusive_zone", 0, -1),
                    .exclusive_edge = try optionalNullableEnum(platform.Edge, state, -1, "exclusive_edge"),
                    .margins = try optionalMargins(state, -1),
                    .keyboard_interactivity = try optionalEnum(
                        platform.KeyboardInteractivity,
                        state,
                        -1,
                        "keyboard_interactivity",
                        .none,
                    ),
                };
                try layer_surface.validate();
                break :blk .{ .layer_surface = layer_surface };
            },
        };
        errdefer switch (declaration) {
            .toplevel => |value| allocator.free(value.title),
            .layer_surface => |value| {
                allocator.free(value.namespace);
                if (value.output) |output| allocator.free(output);
            },
        };
        if (c.lua_getfield(state, -1, "content") != c.type_function)
            return error.WindowContentRequired;
        const content_reference = c.luaL_ref(state, c.registry_index);
        window.* = .{
            .declaration = declaration,
            .content_reference = content_reference,
            .all_outputs = all_outputs,
        };
        initialized += 1;
        c.lua_settop(state, -2);
    }
    return windows;
}

fn installConstructors(state: *c.State, api_reference: ?c_int) !void {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    const api_type = if (api_reference) |reference|
        c.lua_rawgeti(state, c.registry_index, reference)
    else
        c.lua_getglobal(state, "ouro");
    if (api_type != c.type_table) return error.OuroApiMissing;
    c.lua_pushcclosure(state, identityTable, 0);
    c.lua_setfield(state, -2, "app");
    c.lua_pushcclosure(state, identityTable, 0);
    c.lua_setfield(state, -2, "window");
    c.lua_pushcclosure(state, layerSurfaceTable, 0);
    c.lua_setfield(state, -2, "layer_surface");
    c.lua_pushcclosure(state, actionError, 0);
    c.lua_setfield(state, -2, "action_error");
}

var action_error_tag: u8 = 0;

fn actionError(state: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(state) != 2 or c.lua_type(state, 1) != c.type_string or c.lua_type(state, 2) != c.type_table)
        return luaError(state, "action_error expects an error name and parameters table");
    c.lua_createtable(state, 0, 3);
    c.lua_pushlightuserdata(state, &action_error_tag);
    c.lua_setfield(state, -2, "__ouro_action_error");
    c.lua_pushvalue(state, 1);
    c.lua_setfield(state, -2, "name");
    c.lua_pushvalue(state, 2);
    c.lua_setfield(state, -2, "parameters");
    return 1;
}

fn identityTable(state: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return luaError(state, "constructor expects one declaration table");
    c.lua_pushvalue(state, 1);
    return 1;
}

fn layerSurfaceTable(state: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return luaError(state, "constructor expects one declaration table");
    _ = c.lua_pushstring(state, "layer_surface");
    c.lua_setfield(state, 1, "__ouro_surface_role");
    c.lua_pushvalue(state, 1);
    return 1;
}

const SurfaceRole = enum { toplevel, layer_surface };

fn surfaceRole(state: *c.State, table: c_int) !SurfaceRole {
    const value_type = c.lua_getfield(state, table, "__ouro_surface_role");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .toplevel;
    if (value_type != c.type_string) return error.InvalidSurfaceRole;
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.InvalidSurfaceRole;
    return std.meta.stringToEnum(SurfaceRole, value[0..length]) orelse error.InvalidSurfaceRole;
}

fn requiredEnum(
    comptime Enum: type,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) !Enum {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type != c.type_string) return error.RequiredEnumMissing;
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.RequiredEnumMissing;
    return std.meta.stringToEnum(Enum, value[0..length]) orelse error.InvalidEnumValue;
}

fn optionalEnum(
    comptime Enum: type,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: Enum,
) !Enum {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    if (value_type != c.type_string) return error.InvalidEnumValue;
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.InvalidEnumValue;
    return std.meta.stringToEnum(Enum, value[0..length]) orelse error.InvalidEnumValue;
}

fn optionalNullableEnum(
    comptime Enum: type,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) !?Enum {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return null;
    if (value_type != c.type_string) return error.InvalidEnumValue;
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.InvalidEnumValue;
    return std.meta.stringToEnum(Enum, value[0..length]) orelse error.InvalidEnumValue;
}

fn optionalAnchors(state: *c.State, table: c_int) !platform.Anchors {
    const value_type = c.lua_getfield(state, table, "anchors");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .{};
    if (value_type != c.type_table) return error.InvalidLayerSurfaceAnchors;
    var anchors: platform.Anchors = .{};
    const count = c.lua_rawlen(state, -1);
    for (1..count + 1) |index| {
        if (c.lua_rawgeti(state, -1, @intCast(index)) != c.type_string)
            return error.InvalidLayerSurfaceAnchor;
        var length: usize = 0;
        const value = c.lua_tolstring(state, -1, &length) orelse
            return error.InvalidLayerSurfaceAnchor;
        const name = value[0..length];
        if (std.mem.eql(u8, name, "top"))
            anchors.top = true
        else if (std.mem.eql(u8, name, "bottom"))
            anchors.bottom = true
        else if (std.mem.eql(u8, name, "left"))
            anchors.left = true
        else if (std.mem.eql(u8, name, "right"))
            anchors.right = true
        else
            return error.InvalidLayerSurfaceAnchor;
        c.lua_settop(state, -2);
    }
    return anchors;
}

fn optionalMargins(state: *c.State, table: c_int) !platform.Margins {
    const value_type = c.lua_getfield(state, table, "margins");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .{};
    if (value_type != c.type_table) return error.InvalidLayerSurfaceMargins;
    return .{
        .top = try optionalSignedInteger(state, -1, "top", 0, std.math.minInt(i32)),
        .right = try optionalSignedInteger(state, -1, "right", 0, std.math.minInt(i32)),
        .bottom = try optionalSignedInteger(state, -1, "bottom", 0, std.math.minInt(i32)),
        .left = try optionalSignedInteger(state, -1, "left", 0, std.math.minInt(i32)),
    };
}

fn requiredString(
    allocator: std.mem.Allocator,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) ![]u8 {
    if (c.lua_getfield(state, table, field) != c.type_string) return error.RequiredStringMissing;
    defer c.lua_settop(state, -2);
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.RequiredStringMissing;
    if (length == 0) return error.RequiredStringMissing;
    return allocator.dupe(u8, value[0..length]);
}

fn optionalString(
    allocator: std.mem.Allocator,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) !?[]u8 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return null;
    if (value_type != c.type_string) return error.InvalidOptionalString;
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.InvalidOptionalString;
    if (length == 0) return error.EmptyOutputName;
    return try allocator.dupe(u8, value[0..length]);
}

fn optionalDimension(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: u32,
) !u32 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_number);
    if (is_number == 0 or value <= 0 or value > std.math.maxInt(u32))
        return error.InvalidWindowDimension;
    return @intCast(value);
}

fn optionalNonNegativeDimension(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: u32,
) !u32 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_number);
    if (is_number == 0 or value < 0 or value > std.math.maxInt(i32))
        return error.InvalidWindowDimension;
    return @intCast(value);
}

fn optionalSignedInteger(
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: i32,
    minimum: i32,
) !i32 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_number);
    if (is_number == 0 or value < minimum or value > std.math.maxInt(i32))
        return error.InvalidLayerSurfaceInteger;
    return @intCast(value);
}

fn deinitWindow(allocator: std.mem.Allocator, state: *c.State, window: Window) void {
    c.luaL_unref(state, c.registry_index, window.content_reference);
    switch (window.declaration) {
        .toplevel => |declaration| {
            allocator.free(declaration.title);
            allocator.free(declaration.id);
        },
        .layer_surface => |declaration| {
            if (declaration.output) |output| allocator.free(output);
            allocator.free(declaration.namespace);
            allocator.free(declaration.id);
        },
    }
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

fn sourceName(chunk_name: [*:0]const u8) []const u8 {
    const name = std.mem.span(chunk_name);
    return if (name.len != 0 and name[0] == '@') name[1..] else name;
}

test "declarative application owns windows and content callbacks" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    var application = try Application.load(std.testing.allocator, state,
        \\return ouro.app {
        \\  id = "dev.ouro.test",
        \\  windows = {
        \\    ouro.window {
        \\      id = "main",
        \\      title = "Test",
        \\      width = 320,
        \\      height = 200,
        \\      min_width = 280,
        \\      min_height = 160,
        \\      content = function() end,
        \\    },
        \\  },
        \\}
    );
    defer application.deinit();
    try std.testing.expectEqualStrings("dev.ouro.test", application.id);
    try std.testing.expectEqual(@as(usize, 1), application.windows.len);
    try std.testing.expectEqualStrings("main", application.windows[0].declaration.id());
    try std.testing.expectEqual(@as(u32, 320), application.windows[0].declaration.toplevel.initial_width);
    try std.testing.expectEqual(@as(u32, 280), application.windows[0].declaration.toplevel.min_width);
    try std.testing.expectEqual(@as(u32, 160), application.windows[0].declaration.toplevel.min_height);
}

test "layer surface constructor parses shell policy into a distinct declaration" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 3);
    c.lua_setglobal(state, "ouro");
    var application = try Application.load(std.testing.allocator, state,
        \\return ouro.app {
        \\  id = "dev.ouro.shell",
        \\  windows = { ouro.layer_surface {
        \\    id = "panel",
        \\    namespace = "ouro-shell",
        \\    output = "DP-1",
        \\    layer = "top",
        \\    width = 0,
        \\    height = 32,
        \\    anchors = { "top", "left", "right" },
        \\    exclusive_zone = 32,
        \\    exclusive_edge = "top",
        \\    margins = { top = 1, right = 2, bottom = 3, left = 4 },
        \\    keyboard_interactivity = "on_demand",
        \\    content = function() end,
        \\  } },
        \\}
    );
    defer application.deinit();
    const declaration = application.windows[0].declaration.layer_surface;
    try std.testing.expectEqualStrings("panel", declaration.id);
    try std.testing.expectEqualStrings("ouro-shell", declaration.namespace);
    try std.testing.expectEqualStrings("DP-1", declaration.output.?);
    try std.testing.expectEqual(platform.Layer.top, declaration.layer);
    try std.testing.expectEqual(@as(u32, 0), declaration.width);
    try std.testing.expectEqual(@as(u32, 32), declaration.height);
    try std.testing.expect(declaration.anchors.top);
    try std.testing.expect(declaration.anchors.left);
    try std.testing.expect(declaration.anchors.right);
    try std.testing.expectEqual(@as(i32, 32), declaration.exclusive_zone);
    try std.testing.expectEqual(platform.Edge.top, declaration.exclusive_edge.?);
    try std.testing.expectEqual(@as(i32, 4), declaration.margins.left);
    try std.testing.expectEqual(platform.KeyboardInteractivity.on_demand, declaration.keyboard_interactivity);
}

test "window minimum dimensions cannot exceed the initial size" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    try std.testing.expectError(
        error.MinimumWindowSizeExceedsInitialSize,
        Application.load(std.testing.allocator, state,
            \\return ouro.app {
            \\  id = "dev.ouro.test",
            \\  windows = { ouro.window {
            \\    id = "main", title = "Test", width = 320, min_width = 321,
            \\    content = function() end,
            \\  } },
            \\}
        ),
    );
}

test "application actions remain headless while run builds one UI generation" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    var application = try Application.load(std.testing.allocator, state,
        \\return ouro.app {
        \\  id = "dev.ouro.contacts",
        \\  interface = [[interface dev.ouro.contacts
        \\    method GetContacts() -> (name: string)]],
        \\  actions = {
        \\    GetContacts = function() return {name = "Ada"} end,
        \\  },
        \\  run = function(context)
        \\    return { windows = {
        \\      ouro.window {
        \\        id = "main",
        \\        title = context.instance_id == "default" and "Contacts" or "Wrong",
        \\        content = function() end,
        \\      },
        \\    } }
        \\  end,
        \\}
    );
    defer application.deinit();
    try std.testing.expect(application.hasActions());
    try std.testing.expectEqualStrings("Contacts", application.windows[0].declaration.toplevel.title);
}

test "application actions opt in by table presence, including an empty table" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    const cases = [_]struct { field: []const u8, enabled: bool }{
        .{ .field = "", .enabled = false },
        .{ .field = "actions = nil,", .enabled = false },
        .{ .field = "actions = {},", .enabled = true },
        .{ .field = "interface = [[interface dev.ouro.test method Ping() -> ()]], actions = { Ping = function() return {} end },", .enabled = true },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "return ouro.app {{ id = 'dev.ouro.test', {s} windows = {{ ouro.window {{ id = 'main', title = 'Test', content = function() end }} }} }}", .{case.field});
        defer std.testing.allocator.free(source);
        var application = try Application.load(std.testing.allocator, state, source);
        defer application.deinit();
        try std.testing.expectEqual(case.enabled, application.hasActions());
    }
    try std.testing.expectError(error.InvalidActionsDeclaration, Application.load(std.testing.allocator, state, "return ouro.app { id = 'dev.ouro.test', actions = false, windows = {} }"));
}

test "application rejects malformed action declarations" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    try std.testing.expectError(
        error.InvalidActionDeclaration,
        Application.load(std.testing.allocator, state,
            \\return ouro.app {
            \\  id = "dev.ouro.contacts",
            \\  actions = { get_contacts = "not a function" },
            \\  run = function() return { windows = {} } end,
            \\}
        ),
    );
}

test "named application load reports structured Lua diagnostics" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    var failure: ?diagnostic.Diagnostic = null;
    defer if (failure) |*value| value.deinit();
    try std.testing.expectError(
        error.LuaLoadFailed,
        Application.loadNamed(
            std.testing.allocator,
            state,
            "return ouro.app {",
            "@broken/app.lua",
            &failure,
        ),
    );
    try std.testing.expect(failure != null);
    try std.testing.expectEqual(diagnostic.Phase.compile, failure.?.phase);
    try std.testing.expectEqualStrings("broken/app.lua", failure.?.source_name);
    try std.testing.expect(failure.?.message.len != 0);
}

test "typed application requires exact native method and handler agreement" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    const cases = [_]struct { fields: []const u8, expected: anyerror }{
        .{ .fields = "actions = { Ping = function() return {} end },", .expected = error.ActionInterfaceRequired },
        .{ .fields = "interface = [[interface dev.test.actions method Ping() -> ()]], actions = {},", .expected = error.ActionMethodMismatch },
        .{ .fields = "interface = [[interface dev.test.actions method Ping() -> ()]], actions = { Pong = function() return {} end },", .expected = error.ActionMethodMismatch },
        .{ .fields = "interface = [[interface dev.test.actions method Ping() -> ()]],", .expected = error.ActionMethodMismatch },
        .{ .fields = "interface = [[interface dev.ourokit.runtime error Rejected()]], actions = {},", .expected = error.ReservedApplicationInterface },
        .{ .fields = "interface = [[interface org.varlink.service error Rejected()]], actions = {},", .expected = error.DuplicateInterface },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "return ouro.app {{ id = 'dev.test.app', {s} run = function() return {{windows = {{}}}} end }}", .{case.fields});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(case.expected, Application.load(std.testing.allocator, state, source));
    }
}

test "deferred application retains actions and transactionally starts UI in the same VM" {
    const loop_module = @import("../loop/root.zig");
    var loop: loop_module.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 4, 4);
    defer scheduler.deinit();
    var vm: vm_module.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var bootstrap = try Bootstrap.start(std.testing.allocator, &vm, scheduler.application_scope,
        \\local ouro = require('ouro')
        \\local attempts = 0
        \\return ouro.app {
        \\ id = 'dev.test.deferred', actions = {},
        \\ run = function(context)
        \\   run_called = true
        \\   attempts = attempts + 1
        \\   if attempts == 1 then
        \\     return {windows = {
        \\       ouro.window {id='first', title='First', content=function() end},
        \\       ouro.window {id='invalid', title='Invalid'},
        \\     }}
        \\   end
        \\   return {windows = {ouro.window {id='main', title=context.instance_id, content=function() end}}}
        \\ end,
        \\}
    , "@deferred");
    defer bootstrap.deinit();
    bootstrap.defer_run = true;
    try std.testing.expectEqual(vm_module.ResumeResult.completed, try vm.resumeRunnable(scheduler.takeRunnable().?));
    var application = (try bootstrap.advance("not yet")).?;
    defer application.deinit();
    try std.testing.expect(application.hasRun() and application.hasActions());
    try std.testing.expectEqual(@as(usize, 0), application.windows.len);
    try std.testing.expect(!vm.globalBoolean("run_called"));
    const first = try application.startUi(&vm, scheduler.application_scope, "first");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expectError(error.WindowContentRequired, application.finishUi(&vm, first));
    try std.testing.expectEqual(@as(usize, 0), application.windows.len);
    try std.testing.expectEqual(@as(usize, 0), vm.activeTaskCount());
    const second = try application.startUi(&vm, scheduler.application_scope, "retained VM");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try application.finishUi(&vm, second);
    try std.testing.expectEqualStrings("retained VM", application.windows[0].declaration.toplevel.title);
    try std.testing.expect(vm.globalBoolean("run_called"));
    try std.testing.expectError(error.ApplicationUiAlreadyStarted, application.startUi(&vm, scheduler.application_scope, "duplicate"));
}

test "deferred application permits legacy standalone windows but rejects eager service windows" {
    const loop_module = @import("../loop/root.zig");
    var loop: loop_module.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 4, 4);
    defer scheduler.deinit();
    var vm: vm_module.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    for ([_]bool{ false, true }) |service| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "local ouro = require('ouro'); return ouro.app {{ id='dev.test.legacy', {s} windows = {{ouro.window {{id='main', title='Legacy', content=function() end}}}} }}", .{if (service) "actions = {}," else ""});
        defer std.testing.allocator.free(source);
        var bootstrap = try Bootstrap.start(std.testing.allocator, &vm, scheduler.application_scope, source, "@legacy");
        defer bootstrap.deinit();
        bootstrap.defer_run = true;
        _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
        if (service) {
            try std.testing.expectError(error.EagerWindowsInHeadlessApplication, bootstrap.advance("main"));
        } else {
            var application = (try bootstrap.advance("main")).?;
            defer application.deinit();
            try std.testing.expect(!application.hasRun());
            try std.testing.expectEqual(@as(usize, 1), application.windows.len);
        }
    }
}

test "all-output layers materialize stable independent callbacks and retain disconnected names" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    var application = try Application.load(std.testing.allocator, state,
        \\return ouro.app { id='dev.test.outputs', windows={
        \\ ouro.layer_surface {id='panel', namespace='test', outputs='all',
        \\   layer='top', height=40, anchors={'top','left','right'},
        \\   content=function(output) return output end},
        \\ ouro.window {id='settings', title='Settings', content=function() return 'settings' end},
        \\} }
    );
    defer application.deinit();
    try application.extractOutputTemplates();
    try std.testing.expectEqual(@as(usize, 1), application.windows.len);
    try std.testing.expectEqual(@as(usize, 1), application.output_templates.len);
    try std.testing.expect(try application.expandOutput("DP-1", 4));
    const first_reference = application.windows[1].content_reference;
    try std.testing.expect(try application.expandOutput("eDP-1", 4));
    try std.testing.expect(!(try application.expandOutput("DP-1", 4)));
    try std.testing.expectEqual(first_reference, application.windows[1].content_reference);
    for (application.windows[1..], [_][]const u8{ "DP-1", "eDP-1" }) |window, expected| {
        try std.testing.expectEqualStrings(expected, window.declaration.layer_surface.output.?);
        _ = c.lua_rawgeti(state, c.registry_index, window.content_reference);
        try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
        var length: usize = 0;
        const value = c.lua_tolstring(state, -1, &length).?;
        try std.testing.expectEqualStrings(expected, value[0..length]);
        c.lua_settop(state, -2);
    }
    // Seeing only the remaining output does not discard the disconnected one.
    try std.testing.expect(!(try application.expandOutput("eDP-1", 4)));
    try std.testing.expectEqual(@as(usize, 3), application.windows.len);
    try std.testing.expectError(error.WindowCapacityExceeded, application.expandOutput("HDMI-A-1", 3));
    try std.testing.expect(try application.expandOutput("HDMI-A-1", 4));
    try std.testing.expectEqualStrings("panel@8:HDMI-A-1", application.windows[3].declaration.id());
}
