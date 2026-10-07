//! Headless statechart tools (design/statecharts.md §14): load an
//! application's modules in the deterministic test host, so its charts are
//! created, without calling `run`, then call one `ouro.machine` tool with a
//! string argument. `ouroctl replay` and `ouroctl test --generate` use it.
const std = @import("std");
const host = @import("storybook_runner.zig");
const c = @import("../lua/c.zig");
const diagnostic = @import("../lua/diagnostic.zig");

pub const Result = struct {
    /// Owned by the caller's allocator (init.gpa).
    text: []u8,
    ok: bool,
};

/// Evaluates `entry_path` with its directory as the module root, then calls
/// `ouro.machine[tool](argument, options_json)`, which returns (text, ok).
pub fn call(init: std.process.Init, entry_path: []const u8, tool: [:0]const u8, argument: []const u8, options_json: []const u8) !Result {
    const parent = std.fs.path.dirname(entry_path) orelse ".";
    var root = if (std.fs.path.isAbsolute(parent))
        try std.Io.Dir.openDirAbsolute(init.io, parent, .{})
    else
        try std.Io.Dir.cwd().openDir(init.io, parent, .{});
    defer root.close(init.io);
    const file = if (std.fs.path.isAbsolute(entry_path))
        try std.Io.Dir.openFileAbsolute(init.io, entry_path, .{})
    else
        try std.Io.Dir.cwd().openFile(init.io, entry_path, .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    const source = try reader.interface.allocRemaining(init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(source);
    const chunk = try std.fmt.allocPrintSentinel(init.gpa, "@{s}", .{std.fs.path.basename(entry_path)}, 0);
    defer init.gpa.free(chunk);
    return host.withEnvironment(init, root.handle, Job{
        .source = source,
        .chunk = chunk,
        .tool = tool,
        .argument = argument,
        .options = options_json,
    });
}

const Job = struct {
    pub const Result = @import("chart_tools.zig").Result;
    source: []const u8,
    chunk: [:0]const u8,
    tool: [:0]const u8,
    argument: []const u8,
    options: []const u8,

    pub fn run(self: Job, env: host.Environment) !@import("chart_tools.zig").Result {
        const state = env.vm.state;
        env.lua_ui.enableDeclarativeWidgets(.light);
        // The entry returns ouro.app { ... }; declarations are plain tables here
        // because `run` is never called.
        const prelude =
            \\local o = ...
            \\for _, name in ipairs({'app', 'window', 'layer_surface', 'lock_surface'}) do
            \\  if o[name] == nil then o[name] = function(t) return t end end
            \\end
            \\if o.action_error == nil then o.action_error = function(name, p) return {name = name, parameters = p} end end
            \\-- Module code may compute paths; replay never touches the user's files.
            \\o.xdg = o.xdg or {}
            \\if o.xdg.paths == nil then
            \\  o.xdg.paths = function(id)
            \\    local root = '/nonexistent/ourokit-chart-tools/'
            \\    return {config = root .. 'config/' .. id, data = root .. 'data/' .. id, state = root .. 'state/' .. id,
            \\      cache = root .. 'cache/' .. id, config_dirs = {}, data_dirs = {}}
            \\  end
            \\end
        ;
        if (c.luaL_loadbufferx(state, prelude, prelude.len, "=ouro.chart_tools", "t") != c.ok) return error.StatechartToolFailed;
        env.vm.pushApi(state);
        if (c.lua_pcallk(state, 1, 0, 0, 0, null) != c.ok) return error.StatechartToolFailed;
        try host.evaluateValue(env.vm, env.scheduler, env.loop, env.loader.?, self.source, self.chunk);
        c.lua_settop(state, 0);
        env.vm.pushApi(state);
        if (c.lua_getfield(state, -1, "machine") != c.type_table) return error.StatechartsUnavailable;
        if (c.lua_getfield(state, -1, self.tool.ptr) != c.type_function) return error.StatechartToolUnavailable;
        _ = c.lua_pushlstring(state, self.argument.ptr, self.argument.len);
        _ = c.lua_pushlstring(state, self.options.ptr, self.options.len);
        if (diagnostic.pcall(state, 2, 2) != c.ok) {
            diagnostic.logLuaStack(state);
            return error.StatechartToolFailed;
        }
        var length: usize = 0;
        const text = c.lua_tolstring(state, -2, &length) orelse return error.StatechartToolFailed;
        return .{ .text = try env.init.gpa.dupe(u8, text[0..length]), .ok = c.lua_toboolean(state, -1) != 0 };
    }
};
