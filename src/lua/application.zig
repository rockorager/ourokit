const std = @import("std");
const c = @import("c.zig");
const diagnostic = @import("diagnostic.zig");
const platform = @import("../platform/window.zig");

pub const Window = struct {
    declaration: platform.ToplevelDeclaration,
    content_reference: c_int,
};

/// One validated application declaration. Strings are native-owned and every
/// content callback is anchored in the registry until `deinit`.
pub const Application = struct {
    allocator: std.mem.Allocator,
    state: *c.State,
    id: []u8,
    windows: []Window,

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
        return parse(allocator, state) catch |err| {
            diagnostic.recordError(
                diagnostic_output,
                allocator,
                .declaration,
                sourceName(chunk_name),
                err,
            );
            return err;
        };
    }

    pub fn installApi(state: *c.State, api_reference: c_int) !void {
        try installConstructors(state, api_reference);
    }

    /// Parses the application declaration at the top of the Lua stack. The
    /// caller retains stack ownership and may pop the declaration afterward.
    pub fn parseStack(allocator: std.mem.Allocator, state: *c.State) !Application {
        return parse(allocator, state);
    }

    fn parse(allocator: std.mem.Allocator, state: *c.State) !Application {
        if (c.lua_type(state, -1) != c.type_table) return error.ApplicationDeclarationRequired;

        const id = try requiredString(allocator, state, -1, "id");
        errdefer allocator.free(id);
        if (c.lua_getfield(state, -1, "windows") != c.type_table)
            return error.WindowsDeclarationRequired;
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
            const title = try requiredString(allocator, state, -1, "title");
            errdefer allocator.free(title);
            const width = try optionalDimension(state, -1, "width", 640);
            const height = try optionalDimension(state, -1, "height", 480);
            if (c.lua_getfield(state, -1, "content") != c.type_function)
                return error.WindowContentRequired;
            const content_reference = c.luaL_ref(state, c.registry_index);
            window.* = .{
                .declaration = .{
                    .id = window_id,
                    .title = title,
                    .initial_width = width,
                    .initial_height = height,
                },
                .content_reference = content_reference,
            };
            initialized += 1;
            c.lua_settop(state, -2);
        }
        return .{ .allocator = allocator, .state = state, .id = id, .windows = windows };
    }

    pub fn deinit(self: *Application) void {
        for (self.windows) |window| deinitWindow(self.allocator, self.state, window);
        self.allocator.free(self.windows);
        self.allocator.free(self.id);
        self.* = undefined;
    }
};

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
}

fn identityTable(state: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return luaError(state, "constructor expects one declaration table");
    c.lua_pushvalue(state, 1);
    return 1;
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

fn deinitWindow(allocator: std.mem.Allocator, state: *c.State, window: Window) void {
    c.luaL_unref(state, c.registry_index, window.content_reference);
    allocator.free(window.declaration.title);
    allocator.free(window.declaration.id);
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
        \\      content = function() end,
        \\    },
        \\  },
        \\}
    );
    defer application.deinit();
    try std.testing.expectEqualStrings("dev.ouro.test", application.id);
    try std.testing.expectEqual(@as(usize, 1), application.windows.len);
    try std.testing.expectEqualStrings("main", application.windows[0].declaration.id);
    try std.testing.expectEqual(@as(u32, 320), application.windows[0].declaration.initial_width);
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
