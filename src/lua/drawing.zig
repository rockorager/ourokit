const std = @import("std");
const c = @import("c.zig");
const Drawing = @import("../ui/render_object/drawing.zig").Drawing;
const Rectangle = @import("../ui/render_object/drawing.zig").Rectangle;

const metatable = "ouro.drawing.v1";

/// Install on the API table. The closure copies the allocator, not a VM or
/// build-context pointer; drawings can be constructed outside UI evaluation.
pub fn install(state: *c.State, allocator: std.mem.Allocator) void {
    const storage: *std.mem.Allocator = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(std.mem.Allocator), 0).?));
    storage.* = allocator;
    c.lua_pushcclosure(state, construct, 1);
    c.lua_setfield(state, -2, "drawing");
}

/// Call inside a protected Lua frame; ownership remains with the caller even
/// if Lua allocation fails. Acquire the userdata lease only after Lua setup.
pub fn push(state: *c.State, drawing: *Drawing) void {
    const slot = newSlot(state);
    drawing.retain();
    slot.* = drawing;
}

fn newSlot(state: *c.State) *?*Drawing {
    const slot: *?*Drawing = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(?*Drawing), 0).?));
    slot.* = null;
    _ = c.luaL_newmetatable(state, metatable);
    c.lua_pushcclosure(state, release, 0);
    c.lua_setfield(state, -2, "__gc");
    _ = c.lua_pushstring(state, "ouro.drawing");
    c.lua_setfield(state, -2, "__metatable");
    _ = c.lua_setmetatable(state, -2);
    return slot;
}

pub fn get(state: *c.State, index: c_int) ?*Drawing {
    const slot: *?*Drawing = @ptrCast(@alignCast(c.luaL_testudata(state, index, metatable) orelse return null));
    return slot.*;
}

fn release(state: *c.State) callconv(.c) c_int {
    const slot: *?*Drawing = @ptrCast(@alignCast(c.luaL_testudata(state, 1, metatable) orelse return 0));
    if (slot.*) |drawing| drawing.release();
    slot.* = null;
    return 0;
}

fn construct(state: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return fail(state, "ouro.drawing expects one declaration table");
    const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    const width = numberField(state, 1, "width", null, true) catch
        return fail(state, "ouro.drawing width must be a finite nonnegative number");
    const height = numberField(state, 1, "height", null, true) catch
        return fail(state, "ouro.drawing height must be a finite nonnegative number");
    if (rawField(state, 1, "rectangles") != c.type_table)
        return fail(state, "ouro.drawing rectangles must be a dense array");
    const count = c.lua_rawlen(state, 2);
    if (count > Drawing.max_rectangles)
        return fail(state, "ouro.drawing accepts at most 4096 rectangles");
    c.lua_pushnil(state);
    while (c.lua_next(state, 2) != 0) {
        var is_integer: c_int = 0;
        const index = c.lua_tointegerx(state, -2, &is_integer);
        if (c.lua_type(state, -2) != c.type_number or is_integer == 0 or index < 1 or index > count)
            return fail(state, "ouro.drawing rectangles must be a dense array");
        c.lua_settop(state, -2);
    }
    // All scratch storage belongs to Lua: a Lua error/OOM can longjmp across
    // this function without leaking native allocations. Initialize the result
    // finalizer before creating the native snapshot, then transfer its one lease
    // without any intervening allocating Lua calls.
    const slot = newSlot(state);
    const memory: [*]Rectangle = @ptrCast(@alignCast(c.lua_newuserdatauv(state, count * @sizeOf(Rectangle), 0).?));
    const rectangles = memory[0..count];
    for (rectangles, 1..) |*rectangle, index| {
        if (c.lua_rawgeti(state, 2, @intCast(index)) != c.type_table)
            return fail(state, "ouro.drawing rectangles must contain tables without holes");
        rectangle.* = readRectangle(state, 5) catch
            return fail(state, "ouro.drawing rectangle requires finite x/y, nonnegative width/height/corner_radius, and a #RRGGBB or #RRGGBBAA color");
        c.lua_settop(state, 4);
    }
    slot.* = Drawing.create(allocator.*, .{ .width = width, .height = height }, rectangles) catch |err|
        return fail(state, switch (err) {
            error.OutOfMemory => "ouro.drawing allocation failed",
            else => "ouro.drawing invalid geometry",
        });
    c.lua_settop(state, 3);
    return 1;
}

fn readRectangle(state: *c.State, index: c_int) !Rectangle {
    const x = try numberField(state, index, "x", null, false);
    const y = try numberField(state, index, "y", null, false);
    const width = try numberField(state, index, "width", null, true);
    const height = try numberField(state, index, "height", null, true);
    const radius = try numberField(state, index, "corner_radius", 0, true);
    _ = rawField(state, index, "color");
    defer c.lua_settop(state, -2);
    const color = try @import("theme.zig").color(state, -1);
    return .{ .bounds = .{ .x = x, .y = y, .width = width, .height = height }, .color = color, .corner_radius = radius };
}

fn numberField(state: *c.State, index: c_int, name: [*:0]const u8, default: ?f32, nonnegative: bool) !f32 {
    const kind = rawField(state, index, name);
    defer c.lua_settop(state, -2);
    if (kind == c.type_nil) if (default) |value| return value;
    if (kind != c.type_number) return error.InvalidDrawingNumber;
    var is_number: c_int = 0;
    const number = c.lua_tonumberx(state, -1, &is_number);
    if (!std.math.isFinite(number) or @abs(number) > std.math.floatMax(f32) or (nonnegative and number < 0))
        return error.InvalidDrawingNumber;
    const value: f32 = @floatCast(number);
    if (number != 0 and value == 0) return error.InvalidDrawingNumber;
    return value;
}

fn rawField(state: *c.State, index: c_int, name: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, name);
    return c.lua_rawget(state, index);
}

fn fail(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "Lua drawing snapshots nested tables and a retained lease outlives Lua" {
    var drawing: *Drawing = undefined;
    {
        const state = try testState(std.testing.allocator);
        defer c.lua_close(state);
        try testCall(state,
            \\local r = {x=-3.25, y=2.5, width=17, height=8.5, color='#19aBcD80'}
            \\local source = {width=31, height=19, rectangles={r,
            \\  {x=7, y=3, width=11, height=9, color='#923401', corner_radius=2.5}}}
            \\local value = ouro.drawing(source)
            \\r.width, r.color = 1, '#ffffff'
            \\source.width, source.rectangles[2], source.rectangles = 1, nil, {}
            \\return value
        );
        drawing = get(state, -1).?;
        try std.testing.expectEqual(@as(usize, 1), drawing.references);
        try std.testing.expectEqual(@as(f32, 31), drawing.size.width);
        try std.testing.expectEqual(@as(f32, 19), drawing.size.height);
        try std.testing.expectEqual(@as(usize, 2), drawing.rectangles.len);
        try std.testing.expectEqual(Rectangle{
            .bounds = .{ .x = -3.25, .y = 2.5, .width = 17, .height = 8.5 },
            .color = .{ .r = 25, .g = 171, .b = 205, .a = 128 },
        }, drawing.rectangles[0]);
        try std.testing.expectEqual(@as(f32, 2.5), drawing.rectangles[1].corner_radius);
        try std.testing.expectEqual(@as(u8, 255), drawing.rectangles[1].color.a);
        drawing.retain();
    }
    defer drawing.release();
    try std.testing.expectEqual(@as(usize, 1), drawing.references);
    var commands: [4]@import("../scene/root.zig").Command = undefined;
    var builder = try @import("../ui/render_object/scene_builder.zig").Builder.init(&commands, 2);
    try drawing.paint(&builder, .{ .x = 10, .y = 20, .width = 23, .height = 13 });
    try builder.displayList().validate();
    try std.testing.expectEqual(@as(u32, 46), commands[0].push_clip_rect.width);
    try std.testing.expectEqual(@as(i32, 13), commands[1].solid_rectangle.bounds.x);
    try std.testing.expectEqual(@as(u32, 35), commands[1].solid_rectangle.bounds.width);
    try std.testing.expectEqual(@as(u32, 5), commands[2].decorated_rectangle.corner_radius);
}

test "Lua drawing validates numbers colors dense lists and capacity boundaries" {
    const state = try testState(std.testing.allocator);
    defer c.lua_close(state);
    try testCall(state,
        \\local function rectangle()
        \\  return {x=1, y=-2, width=11, height=7, color='#123456'}
        \\end
        \\local function invalid(source)
        \\  local ok, err = pcall(ouro.drawing, source)
        \\  assert(not ok and string.find(err, 'ouro.drawing', 1, true), err)
        \\end
        \\assert(not pcall(ouro.drawing))
        \\assert(not pcall(ouro.drawing, {}, {}))
        \\for _, value in ipairs {false, '1', {}, -1, 0/0, 1/0, 1e39, 1e-50} do
        \\  invalid {width=value, height=1, rectangles={}}
        \\  invalid {width=1, height=value, rectangles={}}
        \\end
        \\invalid {height=1, rectangles={}}
        \\invalid {width=1, rectangles={}}
        \\invalid {width=1, height=1}
        \\for _, field in ipairs {'x','y','width','height','corner_radius'} do
        \\  for _, value in ipairs {false, '1', {}, 0/0, 1/0, -1/0, 1e39, 1e-50} do
        \\    local r = rectangle(); r[field] = value
        \\    invalid {width=1, height=1, rectangles={r}}
        \\  end
        \\  if field ~= 'corner_radius' then
        \\    local r = rectangle(); r[field] = nil
        \\    invalid {width=1, height=1, rectangles={r}}
        \\  end
        \\  if field ~= 'x' and field ~= 'y' then
        \\    local r = rectangle(); r[field] = -1
        \\    invalid {width=1, height=1, rectangles={r}}
        \\  end
        \\end
        \\for _, color in ipairs {false, 123456, {}, '#123', '#12345g', '#123456789', '#123456\0'} do
        \\  local r = rectangle(); r.color = color
        \\  invalid {width=1, height=1, rectangles={r}}
        \\end
        \\local r = rectangle(); r.color = nil
        \\invalid {width=1, height=1, rectangles={r}}
        \\for _, list in ipairs {false, 'x', {false}, {[2]=r}, {[1]=r,[3]=r},
        \\    {[0]=r}, {[-1]=r}, {[1.5]=r}, {['1']=r}, {extra=r}} do
        \\  invalid {width=1, height=1, rectangles=list}
        \\end
        \\invalid {width=1, height=1, rectangles={{x=3e38,y=0,width=3e38,height=1,color='#123456'}}}
        \\local empty = ouro.drawing {width=0, height=0, rectangles={}}
        \\assert(type(empty) == 'userdata' and not pcall(function() empty.width=1 end))
        \\local zero = rectangle(); zero.width, zero.height = 0, 0
        \\ouro.drawing {width=0, height=1, rectangles={zero}}
        \\local list = {}
        \\for i=1,4096 do list[i] = rectangle() end
        \\local maximum = ouro.drawing {width=17, height=9, rectangles=list}
        \\list[4097] = rectangle()
        \\invalid {width=17, height=9, rectangles=list}
        \\return maximum
    );
    const drawing = get(state, -1).?;
    try std.testing.expectEqual(Drawing.max_rectangles, drawing.rectangles.len);
    try std.testing.expectEqual(@as(f32, 11), drawing.rectangles[4095].bounds.width);
}

test "Lua drawing unwinds every native allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testAllocation, .{});
}

fn testAllocation(allocator: std.mem.Allocator) !void {
    const state = try testState(allocator);
    defer c.lua_close(state);
    const source = "return ouro.drawing {width=13,height=9,rectangles={{x=-1,y=3,width=5,height=7,color='#123456'}}}";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "drawing-test", "t"));
    if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok) {
        var length: usize = 0;
        const message = c.lua_tolstring(state, -1, &length).?;
        try std.testing.expectEqualStrings("ouro.drawing allocation failed", message[0..length]);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(@as(usize, 1), get(state, -1).?.rectangles.len);
}

fn testState(allocator: std.mem.Allocator) !*c.State {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    errdefer c.lua_close(state);
    c.lua_pushcclosure(state, c.ouro_open_safe_libraries, 0);
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 0, 0, 0, null));
    c.lua_createtable(state, 0, 1);
    install(state, allocator);
    c.lua_setglobal(state, "ouro");
    return state;
}

fn testCall(state: *c.State, source: []const u8) !void {
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "drawing-test", "t"));
    const status = c.lua_pcallk(state, 0, 1, 0, 0, null);
    if (status != c.ok) {
        var length: usize = 0;
        const message = c.lua_tolstring(state, -1, &length).?;
        std.debug.print("Lua drawing test: {s}\n", .{message[0..length]});
    }
    try std.testing.expectEqual(c.ok, status);
}
