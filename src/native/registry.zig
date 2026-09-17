const std = @import("std");
const abi = @import("root.zig").abi;
const c = @import("../lua/c.zig");
const Vm = @import("../lua/vm.zig").Vm;
const Signals = @import("../lua/signals.zig").Signals;
const Handle = @import("../core/handle.zig").Handle;

pub const Module = struct {
    name: []const u8,
    descriptor: *const abi.ouro_plugin_descriptor,
};

const Context = struct {
    allocator: std.mem.Allocator,
    signals: *Signals,
    reference: c_int = c.no_reference,
    initializing: bool = true,
    in_call: bool = false,
    read_only: bool = false,
    destroy: abi.ouro_destroy = null,
    user: ?*anyopaque = null,
    dependencies: std.ArrayList(Handle) = .empty,
    functions: std.ArrayList(Binding) = .empty,

    fn deinit(self: *Context) void {
        self.initializing = false;
        if (self.destroy) |destroy| destroy(self.user);
        for (self.dependencies.items) |handle| self.signals.releaseExternal(handle);
        self.dependencies.deinit(self.allocator);
        for (self.functions.items) |binding| self.allocator.free(binding.name);
        self.functions.deinit(self.allocator);
    }

    fn owns(self: *Context, signal: u64) ?Handle {
        for (self.dependencies.items) |handle| if (encode(handle) == signal) return handle;
        return null;
    }
};

const Binding = struct {
    context: *Context,
    name: []const u8,
    function: abi.ouro_function,
    user: ?*anyopaque,
    flags: u32,
};

const Call = struct {
    context: *Context,
    state: *c.State,
    count: usize,
    failed: bool = false,
    result: abi.ouro_value = std.mem.zeroes(abi.ouro_value),
    result_bytes: ?[]u8 = null,
    message: ?[]u8 = null,

    fn deinit(self: *Call) void {
        if (self.result_bytes) |bytes| self.context.allocator.free(bytes);
        if (self.message) |bytes| self.context.allocator.free(bytes);
    }
};

/// Must live through lua_close: closures reference these contexts. The host
/// owns the library handles and keeps their code loaded even longer.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    contexts: []Context,
    modules: []Vm.NativeModule,

    pub fn init(self: *Registry, allocator: std.mem.Allocator, vm: *Vm, signals: *Signals, modules: []const Module) !void {
        if (vm.native_modules.len != 0) return error.NativeModulesAlreadyInstalled;
        // Validate all descriptors/names before running any plugin code.
        for (modules, 0..) |module, index| {
            try validate(module);
            for (modules[0..index]) |previous| if (std.mem.eql(u8, previous.name, module.name))
                return error.DuplicateNativeModule;
        }
        const contexts = try allocator.alloc(Context, modules.len);
        errdefer allocator.free(contexts);
        const references = try allocator.alloc(Vm.NativeModule, modules.len);
        errdefer allocator.free(references);
        var count: usize = 0;
        errdefer for (contexts[0..count]) |*context| {
            c.luaL_unref(vm.state, c.registry_index, context.reference);
            context.deinit();
        };
        const top = c.lua_gettop(vm.state);
        defer c.lua_settop(vm.state, top);
        if (c.lua_checkstack(vm.state, 2) == 0) return error.OutOfMemory;
        for (modules, contexts, references) |module, *context, *reference| {
            context.* = .{
                .allocator = allocator,
                .signals = signals,
            };
            count += 1;
            // Registration only copies native data. No Lua allocation/error can
            // unwind a plugin's C or Zig initialization frame.
            if (module.descriptor.initialize.?(&api, @ptrCast(context)) != abi.OURO_OK)
                return error.NativePluginInitializationFailed;
            context.initializing = false;
            c.lua_pushcclosure(vm.state, publishModule, 0);
            c.lua_pushlightuserdata(vm.state, context);
            if (c.lua_pcallk(vm.state, 1, 0, 0, 0, null) != c.ok)
                return error.NativePluginInitializationFailed;
            reference.* = .{ .name = module.name, .reference = context.reference };
        }
        self.* = .{ .allocator = allocator, .contexts = contexts, .modules = references };
        vm.native_modules = references;
    }

    /// Call AFTER Vm.deinit and BEFORE Signals.deinit, including error paths.
    pub fn deinit(self: *Registry) void {
        var index = self.contexts.len;
        while (index != 0) {
            index -= 1;
            self.contexts[index].deinit();
        }
        self.allocator.free(self.modules);
        self.allocator.free(self.contexts);
        self.* = undefined;
    }
};

pub fn validate(module: Module) !void {
    if (std.mem.eql(u8, module.name, "ouro")) return error.ReservedNativeModule;
    try @import("../bundle/module_name.zig").validate(module.name);
    if (module.descriptor.abi_version != abi.OURO_ABI_VERSION)
        return error.UnsupportedNativePluginAbi;
    if (module.descriptor.struct_size < @sizeOf(abi.ouro_plugin_descriptor))
        return error.InvalidNativePluginDescriptor;
    if (module.descriptor.initialize == null) return error.InvalidNativePluginDescriptor;
}

fn publishModule(state: *c.State) callconv(.c) c_int {
    const context: *Context = @ptrCast(@alignCast(c.lua_touserdata(state, 1).?));
    c.lua_createtable(state, 0, @intCast(context.functions.items.len));
    for (context.functions.items) |*binding| {
        _ = c.lua_pushlstring(state, binding.name.ptr, binding.name.len);
        c.lua_pushlightuserdata(state, binding);
        c.lua_pushcclosure(state, invoke, 1);
        c.lua_settable(state, -3);
    }
    context.reference = c.luaL_ref(state, c.registry_index);
    return 0;
}

fn invoke(state: *c.State) callconv(.c) c_int {
    const binding: *const Binding = @ptrCast(@alignCast(c.lua_touserdata(state, c.upvalueIndex(1)).?));
    const context = binding.context;
    if (context.in_call) return fail(state, "native callback re-entry is forbidden");
    const read_only = binding.flags & abi.OURO_FUNCTION_READ_ONLY != 0;
    if (!read_only and context.signals.phase != .idle)
        return fail(state, "mutating native function called during UI build");
    var call: Call = .{ .context = context, .state = state, .count = @intCast(c.lua_gettop(state)) };
    if (c.lua_checkstack(state, 2) == 0) return fail(state, "native result stack unavailable");
    c.lua_pushcclosure(state, pushResult, 0);
    context.in_call = true;
    context.read_only = read_only;
    const status = binding.function.?(binding.user, &api, @ptrCast(context), @ptrCast(&call));
    context.in_call = false;
    call.failed = status != abi.OURO_OK;
    // Push under a protected call so Lua OOM cannot skip native-owned cleanup.
    c.lua_pushlightuserdata(state, &call);
    const pushed = c.lua_pcallk(state, 1, 1, 0, 0, null);
    call.deinit();
    if (pushed != c.ok) return c.lua_error(state);
    return 1;
}

fn pushResult(state: *c.State) callconv(.c) c_int {
    const call: *Call = @ptrCast(@alignCast(c.lua_touserdata(state, 1).?));
    if (call.failed) {
        const message = call.message orelse "native function failed";
        _ = c.lua_pushlstring(state, message.ptr, message.len);
        return c.lua_error(state);
    }
    switch (call.result.type) {
        abi.OURO_NIL => c.lua_pushnil(state),
        abi.OURO_BOOLEAN => c.lua_pushboolean(state, @intFromBool(call.result.integer != 0)),
        abi.OURO_INTEGER => c.lua_pushinteger(state, call.result.integer),
        abi.OURO_NUMBER => c.lua_pushnumber(state, call.result.number),
        abi.OURO_STRING => {
            const bytes = call.result_bytes.?;
            _ = c.lua_pushlstring(state, bytes.ptr, bytes.len);
        },
        else => unreachable,
    }
    return 1;
}

fn registerFunction(raw: ?*abi.ouro_context, name: [*c]const u8, length: usize, flags: u32, function: abi.ouro_function, user: ?*anyopaque) callconv(.c) i32 {
    const context = getContext(raw) orelse return abi.OURO_ERROR;
    if (!context.initializing or function == null or name == null or length == 0 or
        flags & ~@as(u32, abi.OURO_FUNCTION_READ_ONLY) != 0) return abi.OURO_ERROR;
    for (context.functions.items) |binding| if (std.mem.eql(u8, binding.name, name[0..length])) return abi.OURO_ERROR;
    const owned = context.allocator.dupe(u8, name[0..length]) catch return abi.OURO_ERROR;
    context.functions.append(context.allocator, .{ .context = context, .name = owned, .function = function, .user = user, .flags = flags }) catch {
        context.allocator.free(owned);
        return abi.OURO_ERROR;
    };
    return abi.OURO_OK;
}

fn setDestroy(raw: ?*abi.ouro_context, destroy: abi.ouro_destroy, user: ?*anyopaque) callconv(.c) i32 {
    const context = getContext(raw) orelse return abi.OURO_ERROR;
    if (!context.initializing or context.destroy != null or destroy == null) return abi.OURO_ERROR;
    context.destroy = destroy;
    context.user = user;
    return abi.OURO_OK;
}

fn argumentCount(raw: ?*abi.ouro_call) callconv(.c) usize {
    const call = getCall(raw) orelse return 0;
    return call.count;
}

fn argument(raw: ?*abi.ouro_call, index: usize, output: [*c]abi.ouro_value) callconv(.c) i32 {
    const call = getCall(raw) orelse return abi.OURO_ERROR;
    if (output == null or index >= argumentCount(raw)) return abi.OURO_ERROR;
    const out: *abi.ouro_value = output;
    const slot: c_int = @intCast(index + 1);
    const state = call.state;
    out.* = std.mem.zeroes(abi.ouro_value);
    switch (c.lua_type(state, slot)) {
        c.type_nil => out.type = abi.OURO_NIL,
        c.type_boolean => {
            out.type = abi.OURO_BOOLEAN;
            out.integer = c.lua_toboolean(state, slot);
        },
        c.type_number => {
            var valid: c_int = 0;
            if (c.lua_isinteger(state, slot) != 0) {
                out.type = abi.OURO_INTEGER;
                out.integer = c.lua_tointegerx(state, slot, &valid);
            } else {
                out.type = abi.OURO_NUMBER;
                out.number = c.lua_tonumberx(state, slot, &valid);
            }
        },
        c.type_string => {
            out.type = abi.OURO_STRING;
            out.bytes = c.lua_tolstring(state, slot, &out.length).?;
        },
        else => return abi.OURO_ERROR,
    }
    return abi.OURO_OK;
}

fn setResult(raw: ?*abi.ouro_call, input: [*c]const abi.ouro_value) callconv(.c) i32 {
    const call = getCall(raw) orelse return abi.OURO_ERROR;
    if (input == null) return abi.OURO_ERROR;
    const value: *const abi.ouro_value = input;
    if (value.type > abi.OURO_STRING) return abi.OURO_ERROR;
    const bytes = if (value.type == abi.OURO_STRING) blk: {
        if (value.bytes == null and value.length != 0) return abi.OURO_ERROR;
        break :blk call.context.allocator.dupe(u8, if (value.length == 0) "" else value.bytes[0..value.length]) catch return abi.OURO_ERROR;
    } else null;
    if (call.result_bytes) |previous| call.context.allocator.free(previous);
    call.result_bytes = bytes;
    call.result = value.*;
    return abi.OURO_OK;
}

fn setError(raw: ?*abi.ouro_call, bytes: [*c]const u8, length: usize) callconv(.c) i32 {
    const call = getCall(raw) orelse return abi.OURO_ERROR;
    if (bytes == null and length != 0) return abi.OURO_ERROR;
    const message = call.context.allocator.dupe(u8, if (length == 0) "" else bytes[0..length]) catch return abi.OURO_ERROR;
    if (call.message) |previous| call.context.allocator.free(previous);
    call.message = message;
    return abi.OURO_OK;
}

fn signalCreate(raw: ?*abi.ouro_context, out: [*c]u64) callconv(.c) i32 {
    const context = getContext(raw) orelse return abi.OURO_ERROR;
    if (!context.initializing or out == null) return abi.OURO_ERROR;
    const handle = context.signals.createExternal() catch return abi.OURO_ERROR;
    context.dependencies.append(context.allocator, handle) catch {
        context.signals.releaseExternal(handle);
        return abi.OURO_ERROR;
    };
    out.* = encode(handle);
    return abi.OURO_OK;
}

fn signalRead(raw: ?*abi.ouro_context, value: u64) callconv(.c) i32 {
    const context = getContext(raw) orelse return abi.OURO_ERROR;
    if (!context.in_call) return abi.OURO_ERROR;
    const handle = context.owns(value) orelse return abi.OURO_ERROR;
    context.signals.readExternal(handle) catch return abi.OURO_ERROR;
    return abi.OURO_OK;
}

fn signalPublish(raw: ?*abi.ouro_context, value: u64) callconv(.c) i32 {
    const context = getContext(raw) orelse return abi.OURO_ERROR;
    if (!context.in_call or context.read_only) return abi.OURO_ERROR;
    const handle = context.owns(value) orelse return abi.OURO_ERROR;
    context.signals.publishExternal(handle) catch return abi.OURO_ERROR;
    return abi.OURO_OK;
}

fn encode(handle: Handle) u64 {
    return @as(u64, handle.generation) << 32 | handle.slot;
}

fn getContext(raw: ?*abi.ouro_context) ?*Context {
    return @ptrCast(@alignCast(raw));
}

fn getCall(raw: ?*abi.ouro_call) ?*Call {
    return @ptrCast(@alignCast(raw));
}

fn fail(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

const api: abi.ouro_api_v1 = .{
    .abi_version = abi.OURO_ABI_VERSION,
    .struct_size = @sizeOf(abi.ouro_api_v1),
    .register_function = registerFunction,
    .set_destroy = setDestroy,
    .argument_count = argumentCount,
    .argument = argument,
    .set_result = setResult,
    .set_error = setError,
    .signal_create = signalCreate,
    .signal_read = signalRead,
    .signal_publish = signalPublish,
};
