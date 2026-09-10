const c = @import("c.zig");
const Signals = @import("signals.zig").Signals;
const BuildOwners = @import("../ui/instance/build_owner.zig").BuildOwners;
const Handle = @import("../core/handle.zig").Handle;
const Instances = @import("../ui/instance/tree.zig").Tree;
const virtual_list = @import("../ui/widget/virtual_list.zig");

/// Lua-owned records and closures are pinned by this registry table. The
/// bridge itself owns no allocations and must remain at a stable address.
pub const Components = struct {
    state: *c.State = undefined,
    reference: c_int = c.no_reference,
    signals: ?*Signals = null,
    instances: ?*Instances = null,
    focused: ?Handle = null,
    native_update: bool = false,

    pub fn init(self: *Components, state: *c.State) !void {
        self.state = state;
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        const source = @embedFile("components.lua");
        if (c.luaL_loadbufferx(state, source.ptr, source.len, "@ouro/components.lua", "t") != c.ok)
            return error.ComponentRuntimeLoadFailed;
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, selectReader, 1);
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, readerDirty, 1);
        c.lua_pushcclosure(state, next, 0);
        c.lua_pushcclosure(state, check, 0);
        c.lua_pushcclosure(state, makeProps, 0);
        c.lua_pushcclosure(state, isFunction, 0);
        const list_source = @embedFile("virtual_list.lua");
        if (c.luaL_loadbufferx(state, list_source.ptr, list_source.len, "@ouro/virtual_list.lua", "t") != c.ok)
            return error.ComponentRuntimeLoadFailed;
        c.lua_pushcclosure(state, check, 0);
        c.lua_pushcclosure(state, validKey, 0);
        if (c.lua_pcallk(state, 2, 1, 0, 0, null) != c.ok) return error.ComponentRuntimeLoadFailed;
        c.lua_pushlightuserdata(state, self);
        c.lua_pushcclosure(state, geometry, 1);
        if (c.lua_pcallk(state, 8, 1, 0, 0, null) != c.ok) return error.ComponentRuntimeLoadFailed;
        self.reference = c.luaL_ref(state, c.registry_index);
    }

    pub fn push(self: *Components, name: [*:0]const u8) void {
        _ = c.lua_rawgeti(self.state, c.registry_index, self.reference);
        _ = c.lua_getfield(self.state, -1, name);
        // Remove the table, leaving the callable at the original stack top.
        c.lua_rotate(self.state, -2, 1);
        c.lua_settop(self.state, -2);
    }

    pub fn begin(self: *Components, owners: *BuildOwners, owner: Handle) !void {
        self.push("begin");
        self.pushOwner(owners, owner);
        c.lua_pushinteger(self.state, @bitCast(try owners.invalidationRevision(owner)));
        c.lua_pushboolean(self.state, @intFromBool(self.native_update));
        if (c.lua_pcallk(self.state, 4, 0, 0, 0, null) != c.ok) return error.ComponentBuildFailed;
    }

    pub fn call(self: *Components, name: [*:0]const u8) !void {
        self.push(name);
        if (c.lua_pcallk(self.state, 0, 0, 0, 0, null) != c.ok) return error.ComponentBuildFailed;
    }

    pub fn dispose(self: *Components, owners: *BuildOwners, owner: Handle) void {
        self.push("dispose");
        self.pushOwner(owners, owner);
        if (c.lua_pcallk(self.state, 2, 0, 0, 0, null) != c.ok) unreachable;
    }

    fn pushOwner(self: *Components, owners: *BuildOwners, owner: Handle) void {
        c.lua_pushlightuserdata(self.state, owners);
        c.lua_pushinteger(self.state, @bitCast((@as(u64, owner.generation) << 32) | owner.slot));
    }

    fn runtime(state: *c.State) *Components {
        return @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    }

    // Private primitives let the runtime use ordinary Lua without installing
    // global standard libraries or broadening the application's capabilities.
    fn next(state: *c.State) callconv(.c) c_int {
        c.lua_settop(state, 2);
        if (c.lua_next(state, 1) != 0) return 2;
        return 0;
    }

    fn check(state: *c.State) callconv(.c) c_int {
        if (c.lua_toboolean(state, 1) != 0) return 0;
        c.lua_settop(state, 2);
        return c.lua_error(state);
    }

    fn isFunction(state: *c.State) callconv(.c) c_int {
        c.lua_pushboolean(state, @intFromBool(c.lua_type(state, 1) == c.type_function));
        return 1;
    }

    fn validKey(state: *c.State) callconv(.c) c_int {
        c.lua_pushboolean(state, @intFromBool(c.lua_type(state, 1) == c.type_string and c.lua_rawlen(state, 1) > 0));
        return 1;
    }

    /// Read the last completed native layout, only from a protected Lua build.
    fn geometry(state: *c.State) callconv(.c) c_int {
        const self = runtime(state);
        const instances = self.instances orelse return 0;
        var valid: c_int = 0;
        var id: u64 = @bitCast(c.lua_tointegerx(state, 1, &valid));
        if (c.lua_type(state, 2) == c.type_string) {
            var length: usize = 0;
            const key = c.lua_tolstring(state, 2, &length).?;
            id = virtual_list.rowId(id, key[0..length]);
        }
        const target = instances.handleForId(id) orelse return 0;
        const render = instances.renderObject(target) catch return 0;
        const size = instances.render_tree.nodeSize(render) catch return 0;
        const offset = instances.render_tree.scrollOffset(render) catch 0;
        var focused = self.focused;
        var contains_focus = false;
        while (focused) |handle| {
            if (handle.slot == target.slot and handle.generation == target.generation) {
                contains_focus = true;
                break;
            }
            focused = instances.parentOf(handle) catch null;
        }
        c.lua_pushnumber(state, size.width);
        c.lua_pushnumber(state, size.height);
        c.lua_pushnumber(state, offset);
        c.lua_pushboolean(state, @intFromBool(contains_focus));
        return 4;
    }

    fn makeProps(state: *c.State) callconv(.c) c_int {
        _ = c.lua_newuserdatauv(state, 0, 1);
        c.lua_pushvalue(state, 1);
        _ = c.lua_setiuservalue(state, -2, 1);
        if (c.luaL_newmetatable(state, "ouro.component.props") != 0) {
            c.lua_pushcclosure(state, readProp, 0);
            c.lua_setfield(state, -2, "__index");
            c.lua_pushcclosure(state, writeProp, 0);
            c.lua_setfield(state, -2, "__newindex");
            c.lua_pushboolean(state, 0);
            c.lua_setfield(state, -2, "__metatable");
        }
        _ = c.lua_setmetatable(state, -2);
        return 1;
    }

    fn readProp(state: *c.State) callconv(.c) c_int {
        _ = c.lua_getiuservalue(state, 1, 1);
        _ = c.lua_getfield(state, -1, "values");
        c.lua_pushvalue(state, 2);
        _ = c.lua_rawget(state, -2);
        return 1;
    }

    fn writeProp(state: *c.State) callconv(.c) c_int {
        _ = c.lua_pushstring(state, "component props are read-only");
        return c.lua_error(state);
    }

    fn selectReader(state: *c.State) callconv(.c) c_int {
        const signals = runtime(state).signals orelse return 0;
        var number: c_int = 0;
        const reader = c.lua_tointegerx(state, 1, &number);
        if (reader == -1) {
            signals.preserveRoot();
        } else signals.selectReader(@intCast(reader)) catch {
            _ = c.lua_pushstring(state, "component dependency capacity exceeded");
            return c.lua_error(state);
        };
        return 0;
    }

    fn readerDirty(state: *c.State) callconv(.c) c_int {
        var number: c_int = 0;
        const reader: ?u64 = if (c.lua_gettop(state) == 0) null else @intCast(c.lua_tointegerx(state, 1, &number));
        const signals = runtime(state).signals;
        c.lua_pushboolean(state, @intFromBool(if (signals) |value| value.readerDirty(reader) else false));
        return 1;
    }
};
