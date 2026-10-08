const c = @import("c.zig");
const unwrapView = @import("machine.zig").unwrapView;
const unwrapTop = @import("machine.zig").unwrapTop;
const Vm = @import("vm.zig").Vm;

pub const Mime = enum { text, uri_list };
pub const Provider = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque, @import("../platform/activation.zig").Input, Mime, []const u8) anyerror!void,
};

pub fn start(state: *c.State) callconv(.c) c_int {
    const vm: *Vm = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    if (c.lua_gettop(state) != 1 or unwrapView(state, 1) != c.type_table)
        return fail(state, "InvalidDragPayload");
    const input = vm.takePointerInput(state) catch |err| return fail(state, @errorName(err));
    const provider = vm.drag_provider orelse return fail(state, "DragUnavailable");
    var mime: Mime = undefined;
    var bytes: []const u8 = undefined;
    if (c.lua_getfield(state, 1, "text") == c.type_string) {
        var len: usize = 0;
        const value = c.lua_tolstring(state, -1, &len).?;
        if (c.lua_getfield(state, 1, "uris") != c.type_nil) return fail(state, "InvalidDragPayload");
        mime = .text;
        bytes = value[0..len];
    } else {
        if (c.lua_type(state, -1) != c.type_nil) return fail(state, "InvalidDragPayload");
        c.lua_settop(state, -2);
        if (unwrapTop(state, c.lua_getfield(state, 1, "uris")) != c.type_table) return fail(state, "InvalidDragPayload");
        const count = c.lua_rawlen(state, -1);
        if (count == 0) return fail(state, "InvalidDragPayload");
        _ = c.lua_pushstring(state, "");
        var index: usize = 1;
        while (index <= count) : (index += 1) {
            if (c.lua_rawgeti(state, -2, @intCast(index)) != c.type_string) return fail(state, "InvalidDragPayload");
            _ = c.lua_pushstring(state, "\n");
            c.lua_concat(state, 3);
        }
        var len: usize = 0;
        const value = c.lua_tolstring(state, -1, &len).?;
        mime = .uri_list;
        bytes = value[0..len];
    }
    provider.start(provider.context, input, mime, bytes) catch |err| return fail(state, @errorName(err));
    c.lua_pushboolean(state, 1);
    return 1;
}

fn fail(state: *c.State, name: []const u8) c_int {
    c.lua_pushnil(state);
    c.lua_createtable(state, 0, 1);
    _ = c.lua_pushlstring(state, name.ptr, name.len);
    c.lua_setfield(state, -2, "name");
    return 2;
}
