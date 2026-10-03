//! Lua behavior tests use the same headless host and input path as Storybook.
const std = @import("std");
const host = @import("storybook_runner.zig");
const lua = @import("../lua/root.zig");
const c = @import("../lua/c.zig");
const diagnostic = @import("../lua/diagnostic.zig");
const dev = @import("development.zig");
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;

/// Called only in a bounded worker process. Null name lists without running.
pub fn execute(init: std.process.Init, source: []const u8, path: []const u8, name: ?[]const u8) ![]u8 {
    var root = try std.Io.Dir.cwd().openDir(init.io, ".", .{});
    defer root.close(init.io);
    const chunk = try std.fmt.allocPrintSentinel(init.gpa, "@{s}", .{path}, 0);
    defer init.gpa.free(chunk);
    return host.withEnvironment(init, root.handle, Job{ .source = source, .chunk = chunk, .name = name });
}

const Job = struct {
    pub const Result = []u8;
    source: []const u8,
    chunk: [:0]const u8,
    name: ?[]const u8,

    pub fn run(self: Job, env: host.Environment) ![]u8 {
        const state = env.vm.state;
        const theme = @import("../design/root.zig").tokens.light;
        env.lua_ui.enableDeclarativeWidgets(.light);
        try host.evaluateValue(env.vm, env.scheduler, env.loop, env.loader.?, self.source, self.chunk);
        if (c.lua_type(state, -1) != c.type_table) return error.TestTableRequired;
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| env.init.gpa.free(name);
            names.deinit(env.init.gpa);
        }
        c.lua_pushnil(state);
        while (c.lua_next(state, -2) != 0) {
            if (c.lua_type(state, -2) != c.type_string or c.lua_type(state, -1) != c.type_function)
                return error.NamedTestFunctionRequired;
            const name = try string(state, -2);
            if (name.len == 0) return error.EmptyTestName;
            try names.append(env.init.gpa, try env.init.gpa.dupe(u8, name));
            c.lua_settop(state, -2);
        }
        std.mem.sort([]u8, names.items, {}, lessThan);
        const selected = self.name orelse return std.json.Stringify.valueAlloc(env.init.gpa, names.items, .{});
        _ = c.lua_pushlstring(state, selected.ptr, selected.len);
        if (c.lua_rawget(state, -2) != c.type_function) return error.UnknownTest;

        const scope = try env.scheduler.createScope(env.scheduler.application_scope);
        var runtime: WindowRuntime = .{};
        try runtime.init(env.init.gpa, env.scheduler, scope, .{ .slot = 0, .generation = 1 }, theme.background, theme.primary, theme.foreground, theme.input, theme.ring, env.signals, env.paragraph_sources, env.paragraphs, .{});
        defer host.teardownRuntime(&runtime, env.lua_ui, env.scheduler, scope) catch |err| {
            std.debug.panic("component test cleanup failed: {s}", .{@errorName(err)});
        };
        var context: Context = .{ .env = env, .runtime = &runtime };
        defer if (context.content_reference != c.no_reference)
            c.luaL_unref(state, c.registry_index, context.content_reference);
        c.lua_createtable(state, 0, 10);
        inline for (.{ "mount", "node", "input" }) |method| {
            c.lua_pushlightuserdata(state, &context);
            c.lua_pushcclosure(state, @field(Context, method), 1);
            c.lua_setfield(state, -2, method);
        }
        const api = @embedFile("component_test_api.lua");
        if (c.luaL_loadbufferx(state, api, api.len, "@ouro-test-api", null) != c.ok) return error.TestApiLoadFailed;
        c.lua_pushvalue(state, -2);
        if (diagnostic.pcall(state, 1, 0) != c.ok) return error.TestApiLoadFailed;
        if (diagnostic.pcall(state, 1, 0) != c.ok) {
            diagnostic.logLuaStack(state);
            return error.LuaTestFailed;
        }
        return env.init.gpa.dupe(u8, "");
    }
};

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Context = struct {
    env: host.Environment,
    runtime: *WindowRuntime,
    viewport: lua.StorybookViewport = .{},
    snapshot_scale: f32 = 1,
    content_reference: c_int = c.no_reference,
    busy: bool = false,

    fn get(state: *c.State) *Context {
        return @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    }

    fn mount(state: *c.State) callconv(.c) c_int {
        get(state).mountImpl(state) catch |err| return fail(state, err);
        return 0;
    }

    fn mountImpl(self: *Context, state: *c.State) !void {
        if (self.busy) return error.ReentrantTestOperation;
        if (self.content_reference != c.no_reference) return error.TestAlreadyMounted;
        if (c.lua_type(state, 2) != c.type_function) return error.MountFunctionRequired;
        if (c.lua_gettop(state) >= 3) {
            if (c.lua_type(state, 3) != c.type_table) return error.InvalidTestViewport;
            inline for (.{ "width", "height" }) |field| {
                if (c.lua_getfield(state, 3, field) != c.type_nil) {
                    var valid: c_int = 0;
                    const value = c.lua_tointegerx(state, -1, &valid);
                    if (valid == 0 or value < 1 or value > 8192) return error.InvalidTestViewport;
                    @field(self.viewport, field) = @intCast(value);
                }
                c.lua_settop(state, -2);
            }
            const kind = c.lua_getfield(state, 3, "padding");
            defer c.lua_settop(state, -2);
            if (kind != c.type_nil)
                try self.runtime.setPadding(try @import("../lua/theme.zig").extent(state, -1, false));
        }
        c.lua_pushvalue(state, 2);
        self.content_reference = c.luaL_ref(state, c.registry_index);
        self.busy = true;
        defer self.busy = false;
        try self.settle();
    }

    fn input(state: *c.State) callconv(.c) c_int {
        get(state).inputImpl(state) catch |err| return fail(state, err);
        return 0;
    }

    fn inputImpl(self: *Context, state: *c.State) !void {
        if (self.busy) return error.ReentrantTestOperation;
        if (self.content_reference == c.no_reference) return error.TestNotMounted;
        var arena = std.heap.ArenaAllocator.init(self.env.init.gpa);
        defer arena.deinit();
        var count: usize = 0;
        const value = try @import("../lua/mcp_client.zig").luaToJson(state, 2, arena.allocator(), 0, &count);
        const action = try @import("development_control.zig").parseAction(value);
        self.busy = true;
        defer self.busy = false;
        var playback = try dev.Playback.init(self.runtime, dev.Token.current(self.runtime), action);
        while (try playback.advance(self.runtime) == .routed) try self.settle();
    }

    fn node(state: *c.State) callconv(.c) c_int {
        get(state).nodeImpl(state) catch |err| return fail(state, err);
        return 1;
    }

    fn nodeImpl(self: *Context, state: *c.State) !void {
        if (self.busy) return error.ReentrantTestOperation;
        if (self.content_reference == c.no_reference) return error.TestNotMounted;
        const path = try string(state, 2);
        var snapshot = try dev.inspect(self.env.init.gpa, self.runtime, .{});
        defer snapshot.deinit();
        for (snapshot.nodes) |item| {
            if (item.path) |item_path| if (std.mem.eql(u8, item_path, path)) {
                try pushValue(state, item);
                return;
            };
        }
        return error.UnknownTestNode;
    }

    fn settle(self: *Context) !void {
        try host.dispatchAndSettle(self.runtime, self.env.vm, self.env.callbacks, self.env.scheduler, self.env.lua_ui, self);
    }
};

fn string(state: *c.State, index: c_int) ![]const u8 {
    if (c.lua_type(state, index) != c.type_string) return error.ExpectedString;
    var length: usize = 0;
    return c.lua_tolstring(state, index, &length).?[0..length];
}

// Raise only after native resources and defers have been released.
fn fail(state: *c.State, err: anyerror) c_int {
    const message = @errorName(err);
    _ = c.lua_pushlstring(state, message.ptr, message.len);
    return c.lua_error(state);
}

fn pushValue(state: *c.State, value: anytype) !void {
    if (c.lua_checkstack(state, 4) == 0) return error.LuaStackCapacityExceeded;
    switch (@typeInfo(@TypeOf(value))) {
        .bool => c.lua_pushboolean(state, @intFromBool(value)),
        .int => c.lua_pushinteger(state, @intCast(value)),
        .float => c.lua_pushnumber(state, value),
        .@"enum" => {
            const name = @tagName(value);
            _ = c.lua_pushlstring(state, name.ptr, name.len);
        },
        .optional => if (value) |item| try pushValue(state, item) else c.lua_pushnil(state),
        .pointer => {
            _ = c.lua_pushlstring(state, value.ptr, value.len);
        },
        .@"struct" => |info| {
            c.lua_createtable(state, 0, @intCast(info.fields.len));
            inline for (info.fields) |field| {
                if (comptime @TypeOf(value) == dev.Node and
                    (std.mem.eql(u8, field.name, "id") or std.mem.eql(u8, field.name, "parent")))
                {
                    // Match development inspection's lossless hexadecimal IDs.
                    const id: ?u64 = @field(value, field.name);
                    if (id) |number| {
                        var buffer: [16]u8 = undefined;
                        const bytes = try std.fmt.bufPrint(&buffer, "{x}", .{number});
                        _ = c.lua_pushlstring(state, bytes.ptr, bytes.len);
                    } else c.lua_pushnil(state);
                } else try pushValue(state, @field(value, field.name));
                c.lua_setfield(state, -2, field.name);
            }
        },
        else => @compileError("unsupported test node value"),
    }
}
