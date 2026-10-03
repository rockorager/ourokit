const std = @import("std");
const c = @import("c.zig");
const Vm = @import("vm.zig").Vm;
const Handle = @import("../core/handle.zig").Handle;
const platform = @import("../platform/window.zig");

pub const Options = struct {
    anchor: platform.PopupAnchor,
    input: ?@import("../platform/activation.zig").Input,
    scope: Handle,
    width: u32,
    height: u32,
    side: @FieldType(platform.PopupDeclaration, "side") = .bottom,
    gap: u32 = 0,
    transparent: bool = false,
    pointer_input: bool = false,
    content: c_int,
    on_close: c_int,
};

/// References transfer to the provider only on successful open. The provider
/// outlives the VM; handles are generation checked and close is idempotent.
pub const Provider = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, *Vm, Options) anyerror!Handle,
    close: *const fn (*anyopaque, Handle) void,
    resize: ?*const fn (*anyopaque, Handle, u32, u32) anyerror!void = null,
};

const Userdata = struct { provider: Provider, handle: Handle };
const metatable = "ouro.popup";
const anchor_metatable = "ouro.popup_anchor";

/// Opaque geometry/lifetime identity, deliberately not an activation serial.
pub fn pushAnchor(state: *c.State, anchor: platform.PopupAnchor) void {
    const value: *platform.PopupAnchor = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(platform.PopupAnchor), 0).?));
    value.* = anchor;
    _ = c.luaL_newmetatable(state, anchor_metatable);
    _ = c.lua_setmetatable(state, -2);
}

pub fn open(state: *c.State) callconv(.c) c_int {
    const vm: *Vm = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    const options = parse(vm, state) catch |err| return failure(state, err);
    const provider = vm.popup_provider orelse {
        release(state, options);
        return failure(state, error.PopupUnavailable);
    };
    const handle = provider.open(provider.context, vm, options) catch |err| {
        release(state, options);
        return failure(state, err);
    };
    const value: *Userdata = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(Userdata), 0).?));
    value.* = .{ .provider = provider, .handle = handle };
    if (c.luaL_newmetatable(state, metatable) != 0) {
        c.lua_pushvalue(state, -1);
        c.lua_setfield(state, -2, "__index");
        c.lua_pushcclosure(state, close, 0);
        c.lua_setfield(state, -2, "close");
        c.lua_pushcclosure(state, resize, 0);
        c.lua_setfield(state, -2, "resize");
    }
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

fn parse(vm: *Vm, state: *c.State) !Options {
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return error.InvalidPopupArguments;
    const anchor_kind = c.lua_getfield(state, 1, "anchor");
    const input = if (anchor_kind == c.type_nil) try vm.takeActivationInput(state) else null;
    const anchor: platform.PopupAnchor = if (input) |press| .{
        .window = press.window,
        .target = press.target,
        .rectangle = press.anchor orelse return error.PopupAnchorRequired,
    } else blk: {
        const raw = c.luaL_testudata(state, -1, anchor_metatable) orelse return error.InvalidPopupAnchor;
        break :blk @as(*platform.PopupAnchor, @ptrCast(@alignCast(raw))).*;
    };
    c.lua_settop(state, -2);
    const width = try dimension(state, 1, "width");
    const height = try dimension(state, 1, "height");
    var side: @FieldType(platform.PopupDeclaration, "side") = .bottom;
    if (c.lua_getfield(state, 1, "side") != c.type_nil) {
        if (c.lua_type(state, -1) != c.type_string) return error.InvalidPopupSide;
        var len: usize = 0;
        const bytes = c.lua_tolstring(state, -1, &len).?;
        side = std.meta.stringToEnum(@TypeOf(side), bytes[0..len]) orelse return error.InvalidPopupSide;
    }
    c.lua_settop(state, -2);
    var gap: u32 = 0;
    if (c.lua_getfield(state, 1, "gap") != c.type_nil) {
        if (c.lua_isinteger(state, -1) == 0) return error.InvalidPopupGap;
        var valid: c_int = 0;
        const value = c.lua_tointegerx(state, -1, &valid);
        if (value < 0 or value > 1024) return error.InvalidPopupGap;
        gap = @intCast(value);
    }
    c.lua_settop(state, -2);
    try (platform.PopupDeclaration{ .id = "popup", .anchor = anchor, .input = input, .width = width, .height = height, .side = side, .gap = gap }).validate();
    const transparency_kind = c.lua_getfield(state, 1, "transparent");
    if (transparency_kind != c.type_nil and transparency_kind != c.type_boolean) return error.InvalidPopupTransparency;
    const transparent = c.lua_toboolean(state, -1) != 0;
    c.lua_settop(state, -2);
    const pointer_kind = c.lua_getfield(state, 1, "pointer_input");
    if (pointer_kind != c.type_nil and pointer_kind != c.type_boolean) return error.InvalidPopupPointerInput;
    const pointer_input = c.lua_toboolean(state, -1) != 0;
    c.lua_settop(state, -2);
    const scope = try vm.currentScope(state);
    if (c.lua_getfield(state, 1, "content") != c.type_function) return error.PopupContentRequired;
    const content = c.luaL_ref(state, c.registry_index);
    errdefer c.luaL_unref(state, c.registry_index, content);
    const kind = c.lua_getfield(state, 1, "on_close");
    if (kind != c.type_function and kind != c.type_nil) return error.InvalidPopupCallback;
    const on_close = c.luaL_ref(state, c.registry_index);
    return .{ .anchor = anchor, .input = input, .scope = scope, .width = width, .height = height, .side = side, .gap = gap, .transparent = transparent, .pointer_input = pointer_input, .content = content, .on_close = on_close };
}

fn dimension(state: *c.State, table: c_int, field: [*:0]const u8) !u32 {
    _ = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (c.lua_isinteger(state, -1) == 0) return error.InvalidPopupSize;
    var valid: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &valid);
    if (value <= 0 or value > 16384) return error.InvalidPopupSize;
    return @intCast(value);
}

fn release(state: *c.State, options: Options) void {
    c.luaL_unref(state, c.registry_index, options.content);
    c.luaL_unref(state, c.registry_index, options.on_close);
}

fn close(state: *c.State) callconv(.c) c_int {
    const raw = c.luaL_testudata(state, 1, metatable) orelse return failure(state, error.InvalidPopupHandle);
    const value: *Userdata = @ptrCast(@alignCast(raw));
    value.provider.close(value.provider.context, value.handle);
    return 0;
}

fn resize(state: *c.State) callconv(.c) c_int {
    const raw = c.luaL_testudata(state, 1, metatable) orelse return failure(state, error.InvalidPopupHandle);
    if (c.lua_gettop(state) != 2 or c.lua_type(state, 2) != c.type_table)
        return failure(state, error.InvalidPopupArguments);
    const value: *Userdata = @ptrCast(@alignCast(raw));
    const width = dimension(state, 2, "width") catch |err| return failure(state, err);
    const height = dimension(state, 2, "height") catch |err| return failure(state, err);
    const update = value.provider.resize orelse return failure(state, error.PopupResizeUnsupported);
    update(value.provider.context, value.handle, width, height) catch |err| return failure(state, err);
    c.lua_pushboolean(state, 1);
    return 1;
}

fn failure(state: *c.State, err: anyerror) c_int {
    c.lua_pushnil(state);
    c.lua_createtable(state, 0, 2);
    const name = @errorName(err);
    _ = c.lua_pushlstring(state, name.ptr, name.len);
    c.lua_setfield(state, -2, "name");
    _ = c.lua_pushlstring(state, name.ptr, name.len);
    c.lua_setfield(state, -2, "message");
    return 2;
}

test "popup requires fresh scoped input and transfers only valid callbacks" {
    const task = @import("../task/scheduler.zig");
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 4, 8, 8);
    defer scheduler.deinit();
    var loop: @import("../loop/io_uring.zig").Loop = undefined;
    try loop.init(std.testing.allocator, 8, 8);
    defer loop.deinit();
    var vm: Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    const Fake = struct {
        options: ?Options = null,
        closes: usize = 0,
        resizes: usize = 0,
        fn start(context: *anyopaque, _: *Vm, options: Options) !Handle {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.options = options;
            return .{ .slot = 4, .generation = 9 };
        }
        fn stop(context: *anyopaque, handle: Handle) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(handle.slot == 4 and handle.generation == 9);
            self.closes += 1;
        }
        fn update(context: *anyopaque, handle: Handle, width: u32, height: u32) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqual(Handle{ .slot = 4, .generation = 9 }, handle);
            try std.testing.expectEqual(@as(u32, 137), width);
            try std.testing.expectEqual(@as(u32, 41), height);
            self.resizes += 1;
        }
    };
    var fake: Fake = .{};
    vm.popup_provider = .{ .context = &fake, .open = Fake.start, .close = Fake.stop, .resize = Fake.update };
    const input: @import("../platform/activation.zig").Input = .{
        .window = .{ .slot = 2, .generation = 7 },
        .serial = 719,
        .target = .{ .slot = 11, .generation = 3 },
        .anchor = .{ .x = 41, .y = 87, .width = 83, .height = 29 },
    };
    _ = try vm.spawnApplication("local p,e=require('ouro').popup{width=97,height=53,content=function() end}; assert(p==nil and e.name=='NoActivationInput')");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    const bad = try vm.spawnApplication("local p,e=require('ouro').popup{width=0,height=53,content=function() end}; assert(p==nil and e.name=='InvalidPopupSize')");
    try vm.setActivationInput(bad, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(fake.options == null);
    const valid = try vm.spawnApplication(
        \\local o=require('ouro')
        \\local p=assert(o.popup{width=97,height=53,content=function() end,on_close=function() end})
        \\for _, w in ipairs({0, -1, 1.5, 16385}) do
        \\  local ok, err=p:resize{width=w,height=41}
        \\  assert(ok==nil and err.name=='InvalidPopupSize')
        \\end
        \\assert(p:resize{width=137,height=41})
        \\p:close(); p:close()
        \\assert(o.popup{width=97,height=53,content=function() end}==nil)
    );
    try vm.setActivationInput(valid, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expectEqual(input, fake.options.?.input.?);
    try std.testing.expectEqual(scheduler.application_scope, fake.options.?.scope);
    try std.testing.expectEqual(@as(u32, 97), fake.options.?.width);
    try std.testing.expectEqual(@as(u32, 53), fake.options.?.height);
    try std.testing.expect(!fake.options.?.transparent);
    try std.testing.expectEqual(@as(usize, 2), fake.closes);
    try std.testing.expectEqual(@as(usize, 1), fake.resizes);
    release(vm.state, fake.options.?);
    fake.options = null;
    for ([_][]const u8{ "true", "false" }) |value| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "assert(require('ouro').popup{{width=97,height=53,transparent={s},content=function() end}})", .{value});
        defer std.testing.allocator.free(source);
        const opening = try vm.spawnApplication(source);
        try vm.setActivationInput(opening, input);
        _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
        try std.testing.expectEqual(std.mem.eql(u8, value, "true"), fake.options.?.transparent);
        release(vm.state, fake.options.?);
        fake.options = null;
    }
    const invalid_transparency = try vm.spawnApplication("local p,e=require('ouro').popup{width=97,height=53,transparent=1,content=function() end}; assert(p==nil and e.name=='InvalidPopupTransparency')");
    try vm.setActivationInput(invalid_transparency, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(fake.options == null);
    const delayed = try vm.spawnApplication("local o=require('ouro'); o.spawn(function() assert(o.popup{width=97,height=53,content=function() end}==nil) end); o.sleep(0); assert(o.popup{width=97,height=53,content=function() end}==nil)");
    try vm.setActivationInput(delayed, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try vm.markTimeoutCompleted((try loop.takeExpired()).?.operation);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(fake.options == null);

    const anchor: platform.PopupAnchor = .{ .window = input.window, .target = input.target, .rectangle = input.anchor.? };
    pushAnchor(vm.state, anchor);
    c.lua_setglobal(vm.state, "anchor");
    _ = try vm.spawnApplication("local o=require('ouro'); o.sleep(0); assert(o.popup{anchor=anchor,side='left',gap=9,width=97,height=53,content=function() end})");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try vm.markTimeoutCompleted((try loop.takeExpired()).?.operation);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(fake.options.?.input == null);
    try std.testing.expectEqualDeep(anchor, fake.options.?.anchor);
    try std.testing.expectEqual(.left, fake.options.?.side);
    try std.testing.expectEqual(@as(u32, 9), fake.options.?.gap);
    release(vm.state, fake.options.?);
    fake.options = null;
    _ = try vm.spawnApplication("local p,e=require('ouro').popup{anchor={},width=97,height=53,content=function() end}; assert(p==nil and e.name=='InvalidPopupAnchor')");
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(fake.options == null);
}
