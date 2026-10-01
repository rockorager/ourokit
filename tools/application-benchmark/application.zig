const std = @import("std");
const ourokit = @import("ourokit");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var vulkan = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--vulkan")) {
            vulkan = true;
        } else return error.UnknownArgument;
    }
    try ourokit.app.runWayland(init, @embedFile("benchmark_application"), .{ .vulkan = vulkan });
}
