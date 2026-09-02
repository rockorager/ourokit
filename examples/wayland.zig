const std = @import("std");
const ourokit = @import("ourokit");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: ourokit.app.WaylandRunOptions = .{};
    var two_windows = false;
    var layer_shell = false;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            options.exit_after_first_frame = true;
        } else if (std.mem.eql(u8, argument, "--vulkan")) {
            options.vulkan = true;
        } else if (std.mem.eql(u8, argument, "--software")) {
            options.vulkan = false;
        } else if (std.mem.eql(u8, argument, "--two-windows")) {
            two_windows = true;
        } else if (std.mem.eql(u8, argument, "--layer-shell")) {
            layer_shell = true;
        } else {
            return error.UnknownArgument;
        }
    }
    if (two_windows and layer_shell) return error.ConflictingExampleModes;
    const source = if (layer_shell)
        @embedFile("layer-shell.lua")
    else if (two_windows)
        @embedFile("wayland-two-windows.lua")
    else
        @embedFile("wayland.lua");
    try ourokit.app.runWayland(init, source, options);
}
