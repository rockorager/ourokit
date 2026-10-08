const std = @import("std");
const c = @import("c.zig");
const unwrapView = @import("machine.zig").unwrapView;
const Vm = @import("vm.zig").Vm;
const Controller = @import("../ui/text_input/controller.zig").Controller;
const Selection = @import("../ui/text_input/model.zig").Selection;
const metatable = "ouro.editor_controller";
const token_metatable = "ouro.editor_revision";
const Userdata = struct { vm: *Vm, controller: *Controller };
const Revision = struct { controller: *Controller, token: Controller.Token };

pub fn create(state: *c.State) callconv(.c) c_int {
    const vm: *Vm = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    if (c.lua_gettop(state) != 0) return failure(state, error.InvalidEditorArguments);
    // Allocate the Lua owner before the native reference, so Lua allocation
    // failures cannot strand the native allocation across a longjmp.
    const value: *Userdata = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(Userdata), 0).?));
    if (c.luaL_newmetatable(state, metatable) != 0) {
        c.lua_pushboolean(state, 0);
        c.lua_setfield(state, -2, "__metatable");
        c.lua_pushcclosure(state, destroy, 0);
        c.lua_setfield(state, -2, "__gc");
        c.lua_createtable(state, 0, 6);
        inline for (.{ .{ "state", getState }, .{ "read", read }, .{ "select", select }, .{ "replace", replace }, .{ "begin_undo_group", beginGroup }, .{ "end_undo_group", endGroup } }) |method| {
            c.lua_pushcclosure(state, method[1], 0);
            c.lua_setfield(state, -2, method[0]);
        }
        c.lua_setfield(state, -2, "__index");
    }
    const controller = Controller.create(vm.allocator) catch |err| return failure(state, err);
    value.* = .{ .vm = vm, .controller = controller };
    _ = c.lua_setmetatable(state, -2);
    return 1;
}

/// Borrowed during lowering. Pending declarations retain it separately.
pub fn fromTable(state: *c.State, index: c_int) !?*Controller {
    const kind = c.lua_getfield(state, index, "controller");
    defer c.lua_settop(state, -2);
    if (kind == c.type_nil) return null;
    const raw = c.luaL_testudata(state, -1, metatable) orelse return error.InvalidEditorController;
    return @as(*Userdata, @ptrCast(@alignCast(raw))).controller;
}

fn receiver(state: *c.State, count: c_int) !*Controller {
    if (c.lua_gettop(state) != count) return error.InvalidEditorArguments;
    const raw = c.luaL_testudata(state, 1, metatable) orelse return error.InvalidEditorController;
    const value: *Userdata = @ptrCast(@alignCast(raw));
    _ = try value.vm.currentScope(state);
    return value.controller;
}

fn revision(state: *c.State, controller: *Controller) !Controller.Token {
    const raw = c.luaL_testudata(state, 2, token_metatable) orelse return error.InvalidEditorRevision;
    const value: *Revision = @ptrCast(@alignCast(raw));
    if (value.controller != controller) return error.InvalidEditorRevision;
    return value.token;
}

fn pushState(state: *c.State, controller: *Controller, value: Controller.State) c_int {
    c.lua_createtable(state, 0, 3);
    const token: *Revision = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(Revision), 0).?));
    if (c.luaL_newmetatable(state, token_metatable) != 0) {
        c.lua_pushboolean(state, 0);
        c.lua_setfield(state, -2, "__metatable");
        c.lua_pushcclosure(state, destroyToken, 0);
        c.lua_setfield(state, -2, "__gc");
    }
    token.* = .{ .controller = controller, .token = value.token };
    controller.retain();
    _ = c.lua_setmetatable(state, -2);
    c.lua_setfield(state, -2, "token");
    c.lua_pushinteger(state, @intCast(value.bytes));
    c.lua_setfield(state, -2, "bytes");
    c.lua_createtable(state, 0, 4);
    inline for (.{ "anchor", "extent" }) |name| {
        c.lua_pushinteger(state, @intCast(@field(value.selection, name)));
        c.lua_setfield(state, -2, name);
    }
    inline for (.{ "anchor_affinity", "extent_affinity" }) |name| {
        _ = c.lua_pushstring(state, @tagName(@field(value.selection, name)));
        c.lua_setfield(state, -2, name);
    }
    inline for (.{ "line_caret", "character_caret" }) |field| {
        if (@field(value.selection, field)) |caret| {
            c.lua_createtable(state, 0, 3);
            inline for (.{ "anchor", "extent", "column" }) |name| {
                c.lua_pushinteger(state, @intCast(@field(caret, name)));
                c.lua_setfield(state, -2, name);
            }
            inline for (.{ "anchor_affinity", "extent_affinity" }) |name| {
                _ = c.lua_pushstring(state, @tagName(@field(caret, name)));
                c.lua_setfield(state, -2, name);
            }
            c.lua_setfield(state, -2, field);
        }
    }
    c.lua_setfield(state, -2, "selection");
    return 1;
}

fn offset(state: *c.State, index: c_int) !usize {
    if (c.lua_isinteger(state, index) == 0) return error.InvalidTextOffset;
    var valid: c_int = 0;
    const value = c.lua_tointegerx(state, index, &valid);
    if (value < 0) return error.InvalidTextOffset;
    return @intCast(value);
}

fn selectionValue(state: *c.State) !Selection {
    if (unwrapView(state, 3) != c.type_table) return error.InvalidEditorSelection;
    var value: Selection = .collapsed(0);
    inline for (.{ "anchor", "extent" }) |name| {
        _ = c.lua_getfield(state, 3, name);
        @field(value, name) = try offset(state, -1);
        c.lua_settop(state, -2);
    }
    inline for (.{ "anchor_affinity", "extent_affinity" }) |name| {
        if (c.lua_getfield(state, 3, name) != c.type_nil) {
            if (c.lua_type(state, -1) != c.type_string) return error.InvalidCaretAffinity;
            var len: usize = 0;
            const bytes = c.lua_tolstring(state, -1, &len).?;
            @field(value, name) = std.meta.stringToEnum(@TypeOf(@field(value, name)), bytes[0..len]) orelse return error.InvalidCaretAffinity;
        }
        c.lua_settop(state, -2);
    }
    inline for (.{ "line_caret", "character_caret" }) |field| {
        if (c.lua_getfield(state, 3, field) != c.type_nil) {
            if (unwrapView(state, -1) != c.type_table) return error.InvalidEditorSelection;
            var caret: Selection.LineCaret = .{ .anchor = 0, .extent = 0, .column = 0 };
            inline for (.{ "anchor", "extent", "column" }) |name| {
                _ = c.lua_getfield(state, -1, name);
                @field(caret, name) = try offset(state, -1);
                c.lua_settop(state, -2);
            }
            inline for (.{ "anchor_affinity", "extent_affinity" }) |name| {
                if (c.lua_getfield(state, -1, name) != c.type_nil) {
                    if (c.lua_type(state, -1) != c.type_string) return error.InvalidCaretAffinity;
                    var len: usize = 0;
                    const bytes = c.lua_tolstring(state, -1, &len).?;
                    @field(caret, name) = std.meta.stringToEnum(@TypeOf(@field(caret, name)), bytes[0..len]) orelse return error.InvalidCaretAffinity;
                }
                c.lua_settop(state, -2);
            }
            @field(value, field) = caret;
        }
        c.lua_settop(state, -2);
    }
    return value;
}

fn getState(state: *c.State) callconv(.c) c_int {
    const controller = receiver(state, 1) catch |err| return failure(state, err);
    const value = controller.state() catch |err| return failure(state, err);
    return pushState(state, controller, value);
}

fn read(state: *c.State) callconv(.c) c_int {
    const controller = receiver(state, 4) catch |err| return failure(state, err);
    const token = revision(state, controller) catch |err| return failure(state, err);
    const start = offset(state, 3) catch |err| return failure(state, err);
    const end = offset(state, 4) catch |err| return failure(state, err);
    const bytes = controller.read(token, .{ .start = start, .end = end }) catch |err| return failure(state, err);
    _ = c.lua_pushlstring(state, bytes.ptr, bytes.len);
    return 1;
}

fn select(state: *c.State) callconv(.c) c_int {
    const controller = receiver(state, 3) catch |err| return failure(state, err);
    const token = revision(state, controller) catch |err| return failure(state, err);
    const selection = selectionValue(state) catch |err| return failure(state, err);
    const value = controller.select(token, selection) catch |err| return failure(state, err);
    return pushState(state, controller, value);
}

fn replace(state: *c.State) callconv(.c) c_int {
    const controller = receiver(state, 5) catch |err| return failure(state, err);
    const token = revision(state, controller) catch |err| return failure(state, err);
    const start = offset(state, 3) catch |err| return failure(state, err);
    const end = offset(state, 4) catch |err| return failure(state, err);
    if (c.lua_type(state, 5) != c.type_string) return failure(state, error.InvalidEditorText);
    var len: usize = 0;
    const bytes = c.lua_tolstring(state, 5, &len).?;
    const value = controller.replace(token, .{ .start = start, .end = end }, bytes[0..len]) catch |err| return failure(state, err);
    return pushState(state, controller, value);
}

fn group(state: *c.State, begin: bool) c_int {
    const controller = receiver(state, 2) catch |err| return failure(state, err);
    const token = revision(state, controller) catch |err| return failure(state, err);
    const value = controller.undoGroup(token, begin) catch |err| return failure(state, err);
    return pushState(state, controller, value);
}
fn beginGroup(state: *c.State) callconv(.c) c_int {
    return group(state, true);
}
fn endGroup(state: *c.State) callconv(.c) c_int {
    return group(state, false);
}
fn destroy(state: *c.State) callconv(.c) c_int {
    const value: *Userdata = @ptrCast(@alignCast(c.luaL_testudata(state, 1, metatable).?));
    value.controller.release();
    return 0;
}
fn destroyToken(state: *c.State) callconv(.c) c_int {
    const value: *Revision = @ptrCast(@alignCast(c.luaL_testudata(state, 1, token_metatable).?));
    value.controller.release();
    return 0;
}
fn failure(state: *c.State, err: anyerror) c_int {
    c.lua_pushnil(state);
    c.lua_createtable(state, 0, 2);
    _ = c.lua_pushstring(state, @errorName(err));
    c.lua_setfield(state, -2, "name");
    _ = c.lua_pushstring(state, @errorName(err));
    c.lua_setfield(state, -2, "message");
    return 2;
}
