const c = @import("c.zig");
const Range = @import("../ui/widget/range.zig").Range;

pub fn readRange(state: *c.State, table: c_int) !Range {
    var range: Range = undefined;
    inline for (.{ "value", "min", "max", "step" }) |field| {
        const kind = c.lua_getfield(state, table, field);
        defer c.lua_settop(state, -2);
        if (kind != c.type_number) return error.RangeNumberRequired;
        var valid: c_int = 0;
        @field(range, field) = c.lua_tonumberx(state, -1, &valid);
    }
    try range.validate();
    return range;
}

fn normalize(state: *c.State) callconv(.c) c_int {
    const range = readRange(state, 1) catch |err| {
        _ = c.lua_pushstring(state, @errorName(err));
        return c.lua_error(state);
    };
    var valid: c_int = 0;
    const candidate = c.lua_tonumberx(state, 2, &valid);
    c.lua_pushnumber(state, if (valid != 0) range.normalize(candidate) else range.value);
    return 1;
}

/// Install standard compositions after the native description constructors.
pub fn install(state: *c.State) !void {
    const api = c.lua_gettop(state);
    const controls = @embedFile("controls.lua");
    if (c.luaL_loadbufferx(state, controls, controls.len, "=ouro.controls", "t") != c.ok)
        return error.FormsInitializationFailed;
    c.lua_pushvalue(state, api);
    c.lua_pushcclosure(state, check, 0);
    c.lua_pushcclosure(state, valueType, 0);
    c.lua_pushcclosure(state, validateAppearance, 0);
    if (c.lua_pcallk(state, 4, 0, 0, 0, null) != c.ok)
        return error.FormsInitializationFailed;
    const source = @embedFile("forms.lua");
    if (c.luaL_loadbufferx(state, source, source.len, "=ouro.forms", "t") != c.ok)
        return error.FormsInitializationFailed;
    c.lua_pushvalue(state, api);
    c.lua_pushcclosure(state, normalize, 0);
    if (c.lua_pcallk(state, 2, 0, 0, 0, null) != c.ok)
        return error.FormsInitializationFailed;
}

fn check(state: *c.State) callconv(.c) c_int {
    if (c.lua_toboolean(state, 1) != 0) return 0;
    c.lua_settop(state, 2);
    return c.lua_error(state);
}

fn valueType(state: *c.State) callconv(.c) c_int {
    _ = c.lua_pushstring(state, c.lua_typename(state, c.lua_type(state, 1)));
    return 1;
}

fn validateAppearance(state: *c.State) callconv(.c) c_int {
    _ = @import("theme.zig").widgetOverrides(state, .{}, true) catch |err| {
        _ = c.lua_pushstring(state, @errorName(err));
        return c.lua_error(state);
    };
    return 0;
}
