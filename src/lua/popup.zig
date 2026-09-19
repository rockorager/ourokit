const std = @import("std");
const c = @import("c.zig");
const Vm = @import("vm.zig").Vm;
const Handle = @import("../core/handle.zig").Handle;
const platform = @import("../platform/window.zig");

pub const Options = struct {
    input: @import("../platform/activation.zig").Input,
    scope: Handle,
    width: u32,
    height: u32,
    content: c_int,
    on_close: c_int,
};

/// References transfer to the provider only on successful open. The provider
/// outlives the VM; handles are generation checked and close is idempotent.
pub const Provider = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, *Vm, Options) anyerror!Handle,
    close: *const fn (*anyopaque, Handle) void,
};

const Userdata = struct { provider: Provider, handle: Handle };
const metatable = "ouro.popup";

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
    }
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

fn parse(vm: *Vm, state: *c.State) !Options {
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return error.InvalidPopupArguments;
    const input = try vm.takeActivationInput(state);
    const width = try dimension(state, "width");
    const height = try dimension(state, "height");
    try (platform.PopupDeclaration{ .id = "popup", .input = input, .width = width, .height = height }).validate();
    if (c.lua_getfield(state, 1, "content") != c.type_function) return error.PopupContentRequired;
    const content = c.luaL_ref(state, c.registry_index);
    errdefer c.luaL_unref(state, c.registry_index, content);
    const kind = c.lua_getfield(state, 1, "on_close");
    if (kind != c.type_function and kind != c.type_nil) return error.InvalidPopupCallback;
    const on_close = c.luaL_ref(state, c.registry_index);
    return .{ .input = input, .scope = try vm.currentScope(state), .width = width, .height = height, .content = content, .on_close = on_close };
}

fn dimension(state: *c.State, field: [*:0]const u8) !u32 {
    _ = c.lua_getfield(state, 1, field);
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
    };
    var fake: Fake = .{};
    vm.popup_provider = .{ .context = &fake, .open = Fake.start, .close = Fake.stop };
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
    const valid = try vm.spawnApplication("local o=require('ouro'); local p=assert(o.popup{width=97,height=53,content=function() end,on_close=function() end}); p:close(); p:close(); assert(o.popup{width=97,height=53,content=function() end}==nil)");
    try vm.setActivationInput(valid, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expectEqual(input, fake.options.?.input);
    try std.testing.expectEqual(scheduler.application_scope, fake.options.?.scope);
    try std.testing.expectEqual(@as(u32, 97), fake.options.?.width);
    try std.testing.expectEqual(@as(u32, 53), fake.options.?.height);
    try std.testing.expectEqual(@as(usize, 2), fake.closes);
    release(vm.state, fake.options.?);
    fake.options = null;
    const delayed = try vm.spawnApplication("local o=require('ouro'); o.spawn(function() assert(o.popup{width=97,height=53,content=function() end}==nil) end); o.sleep(0); assert(o.popup{width=97,height=53,content=function() end}==nil)");
    try vm.setActivationInput(delayed, input);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try vm.markTimeoutCompleted((try loop.takeExpired()).?.operation);
    _ = try vm.resumeRunnable(scheduler.takeRunnable().?);
    try std.testing.expect(fake.options == null);
}
