const std = @import("std");
const ourokit = @import("ourokit");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: ourokit.app.WaylandRunOptions = .{};
    var two_windows = false;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            options.exit_after_first_frame = true;
        } else if (std.mem.eql(u8, argument, "--two-windows")) {
            two_windows = true;
        } else {
            return error.UnknownArgument;
        }
    }
    const source = if (two_windows)
        @embedFile("wayland-two-windows.lua")
    else
        @embedFile("wayland.lua");
    try ourokit.app.runWayland(init, source, options);
}
