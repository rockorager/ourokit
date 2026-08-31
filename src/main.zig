const std = @import("std");
const ourokit = @import("ourokit");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: ourokit.app.WaylandRunOptions = .{};
    var path: ?[]const u8 = null;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--vulkan")) {
            options.vulkan = true;
        } else if (std.mem.eql(u8, argument, "--software")) {
            options.vulkan = false;
        } else if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            options.exit_after_first_frame = true;
        } else if (path == null) {
            path = argument;
        } else {
            return error.UnknownArgument;
        }
    }
    const application_path = path orelse return error.ExpectedApplicationPath;
    var provider = try ourokit.bundle.SourceProvider.initDisk(init.gpa, application_path);
    defer provider.deinit();
    try ourokit.app.runWaylandSource(init, &provider, options);
}
