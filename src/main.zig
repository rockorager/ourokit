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
    const file = if (std.fs.path.isAbsolute(application_path))
        try std.Io.Dir.openFileAbsolute(init.io, application_path, .{})
    else
        try std.Io.Dir.cwd().openFile(init.io, application_path, .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    const source = try reader.interface.allocRemaining(init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(source);
    try ourokit.app.runWayland(init, source, options);
}
