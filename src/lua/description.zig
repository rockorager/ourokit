const std = @import("std");
const c = @import("c.zig");

pub const Kind = enum {
    text,
    image,
    icon,
    button,
    text_input,
    listbox,
    option,
    box,
    row,
    column,
    scroll,
    virtual_list,
    theme,
    component,

    fn acceptsChildren(self: Kind) bool {
        return switch (self) {
            .listbox, .box, .row, .column, .scroll, .theme, .component => true,
            else => false,
        };
    }
};

const metatable = "ouro.description.v1";

/// A constructor result owns a snapshot of its properties and ordered children
/// through Lua user values. Creating one never enters native UI reconciliation.
pub const Description = struct {
    kind: Kind,

    pub fn get(state: *c.State, index: c_int) ?*Description {
        const pointer = c.luaL_testudata(state, index, metatable) orelse return null;
        return @ptrCast(@alignCast(pointer));
    }

    /// The Ouro API table is on top of the stack.
    pub fn install(state: *c.State) void {
        _ = c.luaL_newmetatable(state, metatable);
        c.lua_settop(state, -2);
        inline for (std.meta.fields(Kind)) |field| {
            if (field.value == @intFromEnum(Kind.component)) continue;
            c.lua_pushinteger(state, field.value);
            c.lua_pushcclosure(state, construct, 1);
            c.lua_setfield(state, -2, field.name);
        }
        c.lua_pushcclosure(state, component, 0);
        c.lua_setfield(state, -2, "component");
    }

    fn component(state: *c.State) callconv(.c) c_int {
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_function)
            return fail(state, "ouro.component expects one initializer function");
        c.lua_pushinteger(state, @intFromEnum(Kind.component));
        // A fresh definition token distinguishes even two definitions that use
        // the same initializer. Neither definition nor construction runs it.
        c.lua_createtable(state, 1, 0);
        c.lua_pushvalue(state, 1);
        c.lua_rawseti(state, -2, 1);
        c.lua_pushcclosure(state, construct, 2);
        return 1;
    }

    fn construct(state: *c.State) callconv(.c) c_int {
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
            return fail(state, "widget constructor expects one property table");
        var is_number: c_int = 0;
        const kind: Kind = @enumFromInt(c.lua_tointegerx(state, c.upvalueIndex(1), &is_number));
        const explicit = c.lua_getfield(state, 1, "children");
        if (explicit != c.type_nil and explicit != c.type_table)
            return fail(state, "children must be an ordered table, not a function");
        if (explicit != c.type_nil and !kind.acceptsChildren())
            return fail(state, "this widget does not accept children");
        const children_index: c_int = if (explicit == c.type_table) 2 else 1;
        const count = c.lua_rawlen(state, children_index);
        if (count != 0 and !kind.acceptsChildren())
            return fail(state, "this widget does not accept children");
        // Validate keys as well as rawlen: a sparse table has no reliable length.
        c.lua_pushnil(state);
        while (c.lua_next(state, 1) != 0) {
            if (c.lua_type(state, -2) == c.type_number) {
                const index = c.lua_tointegerx(state, -2, &is_number);
                if (is_number == 0 or index < 1 or index > count or explicit == c.type_table)
                    return fail(state, "use a dense child array or children table, not both");
            } else if (c.lua_type(state, -2) != c.type_string) {
                return fail(state, "widget property names must be strings");
            }
            c.lua_settop(state, -2);
        }
        if (explicit == c.type_table) {
            c.lua_pushnil(state);
            while (c.lua_next(state, children_index) != 0) {
                const index = c.lua_tointegerx(state, -2, &is_number);
                if (c.lua_type(state, -2) != c.type_number or is_number == 0 or index < 1 or index > count)
                    return fail(state, "children must be a dense array");
                c.lua_settop(state, -2);
            }
        }
        const pointer = c.lua_newuserdatauv(state, @sizeOf(Description), 3) orelse
            return fail(state, "cannot allocate widget description");
        const description: *Description = @ptrCast(@alignCast(pointer));
        description.* = .{ .kind = kind };
        _ = c.luaL_newmetatable(state, metatable);
        _ = c.lua_setmetatable(state, 3);
        c.lua_createtable(state, 0, 8);
        c.lua_pushnil(state);
        while (c.lua_next(state, 1) != 0) {
            if (c.lua_type(state, -2) == c.type_string) {
                c.lua_pushvalue(state, -2);
                c.lua_pushvalue(state, -2);
                c.lua_settable(state, 4);
            }
            c.lua_settop(state, -2);
        }
        c.lua_pushnil(state);
        c.lua_setfield(state, 4, "children");
        _ = c.lua_setiuservalue(state, 3, 1);
        c.lua_createtable(state, @intCast(count), 0);
        for (0..count) |index| {
            _ = c.lua_rawgeti(state, children_index, @intCast(index + 1));
            if (get(state, -1) == null)
                return fail(state, "children must contain widget descriptions without holes");
            c.lua_rawseti(state, 4, @intCast(index + 1));
        }
        _ = c.lua_setiuservalue(state, 3, 2);
        if (kind == .component) {
            c.lua_pushvalue(state, c.upvalueIndex(2));
            _ = c.lua_setiuservalue(state, 3, 3);
        }
        return 1;
    }
};

fn fail(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}
