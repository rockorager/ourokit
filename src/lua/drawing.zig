const std = @import("std");
const c = @import("c.zig");
const Drawing = @import("../ui/render_object/drawing.zig").Drawing;
const Rectangle = @import("../ui/render_object/drawing.zig").Rectangle;
const Paint = @import("../ui/render_object/drawing.zig").Command;
const paths = @import("../path/root.zig");

const metatable = "ouro.drawing.v1";
const path_metatable = "ouro.drawing.path-staging.v1";

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
    if (rawField(state, 1, "commands") != c.type_nil) {
        if (c.lua_type(state, 2) != c.type_table or rawField(state, 1, "rectangles") != c.type_nil)
            return fail(state, "ouro.drawing requires exactly one commands or rectangles array");
        c.lua_settop(state, 2);
        return constructCommands(state, allocator.*, width, height) catch |err| {
            _ = c.lua_pushstring(state, "ouro.drawing: ");
            _ = c.lua_pushstring(state, @errorName(err));
            c.lua_concat(state, 2);
            return c.lua_error(state);
        };
    }
    c.lua_settop(state, 1);
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

fn constructCommands(state: *c.State, allocator: std.mem.Allocator, width: f32, height: f32) !c_int {
    const count = try denseCount(state, 2, Drawing.max_rectangles);
    const slot = newSlot(state); // 3: final result, initially null.
    const memory: [*]Paint = @ptrCast(@alignCast(c.lua_newuserdatauv(state, count * @sizeOf(Paint), 0).?));
    const commands = memory[0..count]; // 4: Lua-owned command scratch.
    c.lua_createtable(state, @intCast(count), 0); // 5: temporary path leases.
    var segments: usize = 0;
    for (commands, 1..) |*command, index| {
        if (c.lua_rawgeti(state, 2, @intCast(index)) != c.type_table) return error.InvalidDrawingCommand;
        const kind = try enumField(enum { rectangle, fill, stroke }, state, 6, "kind", null);
        if (kind == .rectangle) {
            command.* = .{ .rectangle = try readRectangle(state, 6) };
        } else {
            _ = rawField(state, 6, "color");
            const gradient = @import("paint.zig").get(state, -1);
            const color = if (gradient != null) @import("../core/color.zig").Color.rgba(0, 0, 0, 0) else try @import("theme.zig").color(state, -1);
            c.lua_settop(state, 6);
            const style: paths.Style = if (kind == .fill)
                .{ .fill = try enumField(paths.FillRule, state, 6, "fill_rule", .nonzero) }
            else
                .{ .stroke = .{
                    .width = try numberField(state, 6, "width", null, true),
                    .cap = try enumField(@FieldType(paths.Stroke, "cap"), state, 6, "cap", .butt),
                    .join = try enumField(@FieldType(paths.Stroke, "join"), state, 6, "join", .miter),
                    .miter_limit = try numberField(state, 6, "miter_limit", 4, true),
                } };
            const path = try readPath(state, allocator, style, &segments);
            command.* = .{ .path = .{ .path = path, .color = color, .gradient = gradient } };
            // readPath leaves its owning userdata on top. Anchor it before
            // any subsequent parse/allocation can run Lua's collector.
            c.lua_rawseti(state, 5, @intCast(index));
        }
        c.lua_settop(state, 5);
    }
    slot.* = try Drawing.createCommands(allocator, .{ .width = width, .height = height }, commands);
    c.lua_settop(state, 3);
    return 1;
}

fn readPath(state: *c.State, allocator: std.mem.Allocator, style: paths.Style, total: *usize) !*paths.Path {
    if (rawField(state, 6, "path") != c.type_table) return error.InvalidDrawingPath;
    const count = try denseCount(state, 7, 4096);
    if (count > 65536 - total.*) return error.DrawingPathCapacityExceeded;
    total.* += count;
    // The staged userdata owns native geometry even if a later Lua call
    // longjmps. No native allocation is left solely in a Zig local variable.
    const slot: *?*paths.Path = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(?*paths.Path), 0).?));
    slot.* = null;
    _ = c.luaL_newmetatable(state, path_metatable);
    c.lua_pushcclosure(state, releasePath, 0);
    c.lua_setfield(state, -2, "__gc");
    _ = c.lua_setmetatable(state, -2); // 8: staged path owner.
    const memory: [*]paths.Command = @ptrCast(@alignCast(c.lua_newuserdatauv(state, count * @sizeOf(paths.Command), 0).?));
    for (memory[0..count], 1..) |*command, index| {
        if (c.lua_rawgeti(state, 7, @intCast(index)) != c.type_table) return error.InvalidPathSegment;
        const fields = try denseCount(state, 10, 7);
        _ = c.lua_rawgeti(state, 10, 1);
        const kind = try readEnum(enum { move, line, quadratic, cubic, close }, state, -1);
        c.lua_settop(state, 10);
        const arity: usize = switch (kind) {
            .move, .line => 2,
            .quadratic => 4,
            .cubic => 6,
            .close => 0,
        };
        if (fields != arity + 1) return error.InvalidPathSegment;
        var numbers: [6]f32 = undefined;
        for (numbers[0..arity], 2..) |*number, field| {
            _ = c.lua_rawgeti(state, 10, @intCast(field));
            number.* = try readNumber(state, -1, false);
            c.lua_settop(state, 10);
        }
        command.* = switch (kind) {
            .move => .{ .move = .{ .x = numbers[0], .y = numbers[1] } },
            .line => .{ .line = .{ .x = numbers[0], .y = numbers[1] } },
            .quadratic => .{ .quadratic = .{ .control = .{ .x = numbers[0], .y = numbers[1] }, .to = .{ .x = numbers[2], .y = numbers[3] } } },
            .cubic => .{ .cubic = .{ .control1 = .{ .x = numbers[0], .y = numbers[1] }, .control2 = .{ .x = numbers[2], .y = numbers[3] }, .to = .{ .x = numbers[4], .y = numbers[5] } } },
            .close => .close,
        };
        c.lua_settop(state, 9);
    }
    const value = try paths.Path.create(allocator, memory[0..count], style);
    slot.* = value;
    c.lua_settop(state, 8);
    c.lua_rotate(state, 7, 1);
    c.lua_settop(state, 7);
    return value;
}

fn releasePath(state: *c.State) callconv(.c) c_int {
    const slot: *?*paths.Path = @ptrCast(@alignCast(c.luaL_testudata(state, 1, path_metatable) orelse return 0));
    if (slot.*) |path| path.release();
    slot.* = null;
    return 0;
}

fn denseCount(state: *c.State, index: c_int, limit: usize) !usize {
    const count = c.lua_rawlen(state, index);
    if (count > limit) return error.DrawingCapacityExceeded;
    c.lua_pushnil(state);
    while (c.lua_next(state, index) != 0) {
        var is_integer: c_int = 0;
        const key = c.lua_tointegerx(state, -2, &is_integer);
        if (c.lua_type(state, -2) != c.type_number or is_integer == 0 or key < 1 or key > count)
            return error.InvalidDrawingArray;
        c.lua_settop(state, -2);
    }
    return count;
}

fn enumField(comptime T: type, state: *c.State, index: c_int, name: [*:0]const u8, default: ?T) !T {
    const kind = rawField(state, index, name);
    defer c.lua_settop(state, -2);
    if (kind == c.type_nil) if (default) |value| return value;
    return readEnum(T, state, -1);
}

fn readEnum(comptime T: type, state: *c.State, index: c_int) !T {
    if (c.lua_type(state, index) != c.type_string) return error.InvalidDrawingOption;
    var length: usize = 0;
    const text = c.lua_tolstring(state, index, &length).?;
    return std.meta.stringToEnum(T, text[0..length]) orelse error.InvalidDrawingOption;
}

fn readRectangle(state: *c.State, index: c_int) !Rectangle {
    const x = try numberField(state, index, "x", null, false);
    const y = try numberField(state, index, "y", null, false);
    const width = try numberField(state, index, "width", null, true);
    const height = try numberField(state, index, "height", null, true);
    const radius = try numberField(state, index, "corner_radius", 0, true);
    _ = rawField(state, index, "color");
    defer c.lua_settop(state, -2);
    const gradient = @import("paint.zig").get(state, -1);
    const color = if (gradient != null) @import("../core/color.zig").Color.rgba(0, 0, 0, 0) else try @import("theme.zig").color(state, -1);
    return .{ .bounds = .{ .x = x, .y = y, .width = width, .height = height }, .color = color, .gradient = gradient, .corner_radius = radius };
}

fn numberField(state: *c.State, index: c_int, name: [*:0]const u8, default: ?f32, nonnegative: bool) !f32 {
    const kind = rawField(state, index, name);
    defer c.lua_settop(state, -2);
    if (kind == c.type_nil) if (default) |value| return value;
    return readNumber(state, -1, nonnegative);
}

fn readNumber(state: *c.State, index: c_int, nonnegative: bool) !f32 {
    if (c.lua_type(state, index) != c.type_number) return error.InvalidDrawingNumber;
    var is_number: c_int = 0;
    const number = c.lua_tonumberx(state, index, &is_number);
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

test "Lua path drawings preserve paint order and copy geometry and stroke style" {
    const state = try testState(std.testing.allocator);
    defer c.lua_close(state);
    try testCall(state,
        \\local points = {{'move',2,3},{'quadratic',7,13,17,5},{'cubic',21,2,29,19,31,7}}
        \\local stroke = {kind='stroke',path=points,width=3.5,color='#15263780',cap='round',join='bevel',miter_limit=2}
        \\local commands = {
        \\  {kind='fill',path={{'move',1,1},{'line',11,1},{'line',7,13},{'close'}},color='#ee0022',fill_rule='even_odd'},
        \\  {kind='rectangle',x=9,y=5,width=7,height=3,color='#ab12cd'}, stroke,
        \\}
        \\local result = ouro.drawing {width=43,height=29,commands=commands}
        \\points[1][2], points[2], stroke.width, stroke.cap, commands[1] = 999, {'close'}, 12, 'square', nil
        \\return result
    );
    _ = c.lua_gc(state, 2); // Drop temporary construction leases, keep result.
    const drawing = get(state, -1).?;
    try std.testing.expectEqual(@as(usize, 0), drawing.rectangles.len);
    try std.testing.expectEqual(@as(usize, 3), drawing.commands.len);
    const fill = drawing.commands[0].path;
    try std.testing.expectEqual(paths.FillRule.even_odd, fill.path.style.fill);
    try std.testing.expectEqual(@as(f32, 9), drawing.commands[1].rectangle.bounds.x);
    const stroke = drawing.commands[2].path;
    try std.testing.expectEqual(paths.Stroke{ .width = 3.5, .cap = .round, .join = .bevel, .miter_limit = 2 }, stroke.path.style.stroke);
    try std.testing.expectEqual(@as(f32, 2), stroke.path.commands[0].move.x);
    try std.testing.expectEqual(@as(f32, 13), stroke.path.commands[1].quadratic.control.y);
    try std.testing.expectEqual(@as(f32, 29), stroke.path.commands[2].cubic.control2.x);
    try std.testing.expectEqual(@as(u8, 128), stroke.color.a);
}

test "Lua path drawings reject malformed records and unwind partial construction" {
    const state = try testState(std.testing.allocator);
    defer c.lua_close(state);
    try testCall(state,
        \\local good = {kind='fill',color='#abcdef',path={{'move',0,0},{'line',9,2},{'line',3,7},{'close'}}}
        \\local function invalid(value)
        \\  assert(not pcall(ouro.drawing, value))
        \\end
        \\invalid {width=1,height=1,commands={},rectangles={}}
        \\invalid {width=1,height=1,commands=false}
        \\invalid {width=1,height=1,commands={[2]=good}}
        \\for _, bad in ipairs {false, {}, {kind='triangle'},
        \\    {kind='fill',color='#ffffff',path={{'line',1,2}}},
        \\    {kind='fill',color='#ffffff',path={{'move',1,2,3}}},
        \\    {kind='fill',color='#ffffff',path={{'move',1}}},
        \\    {kind='fill',color='#ffffff',path={{'move','1',2}}},
        \\    {kind='fill',color='#ffffff',path={{'move',0/0,2}}},
        \\    {kind='fill',color='#ffffff',path={{'move',0,0},{'close'},{'line',1,1}}},
        \\    {kind='fill',color='#ffffff',path={{'move',0,0},{'quadratic',1,2,3}}},
        \\    {kind='fill',color='#ffffff',path={{'move',0,0},{'cubic',1,2,3,4,5}}},
        \\    {kind='fill',color='#ffffff',path={['1']={'move',0,0}}},
        \\    {kind='fill',color='#ffffff',path={},fill_rule='winding'},
        \\    {kind='stroke',color='#ffffff',path=good.path,width=0},
        \\    {kind='stroke',color='#ffffff',path=good.path,width=1,cap='flat'},
        \\    {kind='stroke',color='#ffffff',path=good.path,width=1,join='sharp'},
        \\    {kind='stroke',color='#ffffff',path=good.path,width=1,miter_limit=0.5}} do
        \\  invalid {width=19,height=13,commands={good,bad}}
        \\end
        \\local commands = {}; for i=1,4097 do commands[i]=good end
        \\invalid {width=19,height=13,commands=commands}
        \\local path = {}; for i=1,4097 do path[i]={'move',0,0} end
        \\invalid {width=19,height=13,commands={{kind='fill',path=path,color='#ffffff'}}}
        \\path[4097] = nil
        \\commands = {}; for i=1,16 do commands[i]={kind='fill',path=path,color='#ffffff'} end
        \\assert(ouro.drawing {width=19,height=13,commands=commands})
        \\commands[17] = {kind='fill',path={{'move',1,1}},color='#ffffff'}
        \\invalid {width=19,height=13,commands=commands}
        \\return ouro.drawing {width=0,height=0,commands={}}
    );
    _ = c.lua_gc(state, 2);
    try std.testing.expectEqual(@as(usize, 0), get(state, -1).?.commands.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPathAllocation, .{});
}

fn testPathAllocation(allocator: std.mem.Allocator) !void {
    const state = try testState(allocator);
    defer c.lua_close(state);
    const source =
        \\local path={{'move',1,2},{'line',13,5},{'line',7,11},{'close'}}
        \\return ouro.drawing {width=17,height=13,commands={
        \\  {kind='fill',path=path,color='#abcdef'},
        \\  {kind='stroke',path=path,width=2,color='#123456'},
        \\}}
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "drawing-test", "t"));
    if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok) {
        var length: usize = 0;
        const message = c.lua_tolstring(state, -1, &length).?;
        try std.testing.expectEqualStrings("ouro.drawing: OutOfMemory", message[0..length]);
        return error.OutOfMemory;
    }
    _ = c.lua_gc(state, 2);
    try std.testing.expectEqual(@as(usize, 2), get(state, -1).?.commands.len);
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

test "Lua gradient drawing retains value paints after Lua closes and crops recording coordinates" {
    var drawing: *Drawing = undefined;
    {
        const state = try testState(std.testing.allocator);
        defer c.lua_close(state);
        try testCall(state,
            \\local g = ouro.linear_gradient {from={x=1,y=2},to={x=17,y=6},
            \\  stops={{offset=0,color='#ff0000'},{offset=1,color='#0000ff00'}}}
            \\return ouro.drawing {width=23,height=19,commands={
            \\  {kind='rectangle',x=7,y=3,width=13,height=9,color=g},
            \\  {kind='fill',path={{'move',2,1},{'line',12,3},{'line',4,9},{'close'}},color=g},
            \\  {kind='stroke',path={{'move',1,3},{'line',11,8}},width=2,color=g}}}
        );
        drawing = get(state, -1).?;
        drawing.retain();
    }
    defer drawing.release();
    const scene = @import("../scene/root.zig");
    const PointF = @import("../core/geometry.zig").PointF;
    var commands: [5]scene.Command = undefined;
    var builder = try @import("../ui/render_object/scene_builder.zig").Builder.init(&commands, 1.5);
    try drawing.paint(&builder, .{ .x = 10, .y = 20, .width = 8, .height = 7 });
    try builder.displayList().validate();
    try std.testing.expectEqual(@as(u32, 12), commands[0].push_clip_rect.width);
    for ([_]@import("../paint/root.zig").LinearGradient{
        commands[1].decorated_rectangle.background_gradient.?, commands[2].path.gradient.?, commands[3].path.gradient.?,
    }) |gradient| {
        // All primitives share recording coordinates, despite their offsets.
        try std.testing.expectEqual(PointF{ .x = 16.5, .y = 33 }, gradient.start);
        try std.testing.expectEqual(PointF{ .x = 40.5, .y = 39 }, gradient.end);
        try std.testing.expectEqual(@as(u8, 0), gradient.stops[1].color.a);
    }
}

fn testState(allocator: std.mem.Allocator) !*c.State {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    errdefer c.lua_close(state);
    c.lua_pushcclosure(state, c.ouro_open_safe_libraries, 0);
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 0, 0, 0, null));
    c.lua_createtable(state, 0, 1);
    install(state, allocator);
    @import("paint.zig").install(state);
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
