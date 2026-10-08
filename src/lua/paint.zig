const std = @import("std");
const c = @import("c.zig");
const unwrapView = @import("machine.zig").unwrapView;
const unwrapTop = @import("machine.zig").unwrapTop;
const paint = @import("../paint/root.zig");
const PointF = @import("../core/geometry.zig").PointF;
const metatable = "ouro.linear-gradient.v1";

pub fn install(state: *c.State) void {
    c.lua_pushcclosure(state, construct, 0);
    c.lua_setfield(state, -2, "linear_gradient");
}

/// Paints are copied values, not leases into the Lua heap.
pub fn get(state: *c.State, index: c_int) ?paint.LinearGradient {
    const value: *const paint.LinearGradient = @ptrCast(@alignCast(c.luaL_testudata(state, index, metatable) orelse return null));
    return value.*;
}

fn construct(state: *c.State) callconv(.c) c_int {
    const gradient = read(state) catch |err| {
        _ = c.lua_pushstring(state, "ouro.linear_gradient: ");
        _ = c.lua_pushstring(state, @errorName(err));
        c.lua_concat(state, 2);
        return c.lua_error(state);
    };
    // Parsing uses stack values only: Lua allocation failure cannot strand a
    // native allocation or a borrowed pointer. Userdata needs no finalizer.
    const value: *paint.LinearGradient = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(paint.LinearGradient), 0).?));
    value.* = gradient;
    _ = c.luaL_newmetatable(state, metatable);
    _ = c.lua_pushstring(state, "ouro.linear_gradient");
    c.lua_setfield(state, -2, "__metatable");
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

fn read(state: *c.State) !paint.LinearGradient {
    if (c.lua_gettop(state) != 1 or unwrapView(state, 1) != c.type_table) return error.InvalidGradient;
    const start = try point(state, "from");
    const end = try point(state, "to");
    if (unwrapTop(state, rawField(state, 1, "stops")) != c.type_table) return error.InvalidGradientStops;
    const count = c.lua_rawlen(state, 2);
    if (count < 2 or count > 8) return error.InvalidGradientStops;
    c.lua_pushnil(state);
    while (c.lua_next(state, 2) != 0) {
        var integer: c_int = 0;
        const index = c.lua_tointegerx(state, -2, &integer);
        if (c.lua_type(state, -2) != c.type_number or integer == 0 or index < 1 or index > count)
            return error.InvalidGradientStops;
        c.lua_settop(state, -2);
    }
    var stops: [8]paint.Stop = undefined;
    for (stops[0..count], 1..) |*stop, index| {
        if (unwrapTop(state, c.lua_rawgeti(state, 2, @intCast(index))) != c.type_table) return error.InvalidGradientStop;
        _ = rawField(state, 3, "offset");
        const offset = try number(state, -1);
        c.lua_settop(state, 3);
        _ = rawField(state, 3, "color");
        stop.* = .{ .offset = offset, .color = try @import("theme.zig").color(state, -1) };
        c.lua_settop(state, 2);
    }
    return paint.LinearGradient.init(start, end, stops[0..count]);
}

fn point(state: *c.State, name: [*:0]const u8) !PointF {
    defer c.lua_settop(state, 1);
    if (unwrapTop(state, rawField(state, 1, name)) != c.type_table) return error.InvalidGradientPoint;
    _ = rawField(state, 2, "x");
    const x = try number(state, -1);
    c.lua_settop(state, 2);
    _ = rawField(state, 2, "y");
    return .{ .x = x, .y = try number(state, -1) };
}

fn number(state: *c.State, index: c_int) !f32 {
    if (c.lua_type(state, index) != c.type_number) return error.InvalidGradientNumber;
    var is_number: c_int = 0;
    const value = c.lua_tonumberx(state, index, &is_number);
    if (!std.math.isFinite(value) or @abs(value) > std.math.floatMax(f32)) return error.InvalidGradientNumber;
    const narrowed: f32 = @floatCast(value);
    if (value != 0 and narrowed == 0) return error.InvalidGradientNumber;
    return narrowed;
}

fn rawField(state: *c.State, index: c_int, name: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, name);
    return c.lua_rawget(state, index);
}

test "Lua linear gradients snapshot nested values and are immutable" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 1);
    install(state);
    c.lua_setglobal(state, "ouro");
    const source =
        \\local stop = {offset=.25,color='#ff000080'}
        \\local data = {from={x=-2,y=3},to={x=19,y=11},stops={stop,{offset=1,color='#0000ff00'}}}
        \\local gradient = ouro.linear_gradient(data)
        \\stop.offset, stop.color, data.from.x, data.to.y, data.stops = 0, '#ffffff', 100, 0, {}
        \\return gradient
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@gradient", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
    const value = get(state, 1).?;
    try std.testing.expectEqual(PointF{ .x = -2, .y = 3 }, value.start);
    try std.testing.expectEqual(PointF{ .x = 19, .y = 11 }, value.end);
    try std.testing.expectEqual(@as(f32, 0.25), value.stops[0].offset);
    try std.testing.expectEqual(@as(u8, 128), value.stops[0].color.a);
    c.lua_setglobal(state, "gradient");
    const mutate = "gradient.stops = {}";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, mutate.ptr, mutate.len, "@gradient", "t"));
    try std.testing.expect(c.lua_pcallk(state, 0, 0, 0, 0, null) != c.ok);
}

test "Lua linear gradients reject malformed numbers arrays and endpoints" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 1);
    install(state);
    c.lua_setglobal(state, "ouro");
    for ([_][]const u8{
        "g.from=nil",                                             "g.to=g.from",           "g.from.x='0'",          "g.to.y=0/0",             "g.to.x=1/0",              "g.from.x=1e-100",
        "g.stops={}",                                             "g.stops[2]=nil",        "g.stops.extra=true",    "g.stops[1]=false",       "g.stops[3.5]=g.stops[1]", "g.stops[1].offset=-.1",
        "g.stops[2].offset=1.1",                                  "g.stops[1].offset='0'", "g.stops[2].offset=0/0", "g.stops[1].color=false", "g.stops[2].color='#fff'", "g.stops[1].offset=1; g.stops[2].offset=0",
        "for i=3,9 do g.stops[i]={offset=1,color='#ffffff'} end",
    }) |mutation| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "local g={{from={{x=0,y=0}},to={{x=7,y=3}},stops={{{{offset=0,color='#000000'}},{{offset=1,color='#ffffff'}}}}}}; {s}; return ouro.linear_gradient(g)", .{mutation});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@gradient-rejection", "t"));
        try std.testing.expect(c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok);
        c.lua_settop(state, 0);
    }
}
