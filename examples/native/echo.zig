//! A Zig plugin needs only the C header, not the Ourokit or Lua libraries.
const c = @cImport({
    @cInclude("ourokit/plugin.h");
});

fn echo(_: ?*anyopaque, api: [*c]const c.ouro_api_v1, _: ?*c.ouro_context, call: ?*c.ouro_call) callconv(.c) i32 {
    if (api.*.argument_count.?(call) != 1) return c.OURO_ERROR;
    var value: c.ouro_value = undefined;
    if (api.*.argument.?(call, 0, &value) != c.OURO_OK) return c.OURO_ERROR;
    // Strings are copied by set_result, before this callback returns.
    return api.*.set_result.?(call, &value);
}

fn initialize(api: [*c]const c.ouro_api_v1, context: ?*c.ouro_context) callconv(.c) i32 {
    if (api.*.abi_version != c.OURO_ABI_VERSION or api.*.struct_size < @sizeOf(c.ouro_api_v1))
        return c.OURO_ERROR;
    return api.*.register_function.?(context, "echo", 4, c.OURO_FUNCTION_READ_ONLY, echo, null);
}

export const ouro_plugin: c.ouro_plugin_descriptor = .{
    .abi_version = c.OURO_ABI_VERSION,
    .struct_size = @sizeOf(c.ouro_plugin_descriptor),
    .initialize = initialize,
};
