const c = @import("c.zig");
const Drawing = @import("../ui/render_object/drawing.zig").Drawing;

const metatable = "ouro.drawing.v1";

/// Call inside a protected Lua frame; ownership remains with the caller even
/// if Lua allocation fails. Acquire the userdata lease only after Lua setup.
pub fn push(state: *c.State, drawing: *Drawing) void {
    const slot: *?*Drawing = @ptrCast(@alignCast(c.lua_newuserdatauv(state, @sizeOf(?*Drawing), 0).?));
    slot.* = null;
    _ = c.luaL_newmetatable(state, metatable);
    c.lua_pushcclosure(state, release, 0);
    c.lua_setfield(state, -2, "__gc");
    _ = c.lua_pushstring(state, "ouro.drawing");
    c.lua_setfield(state, -2, "__metatable");
    _ = c.lua_setmetatable(state, -2);
    drawing.retain();
    slot.* = drawing;
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
