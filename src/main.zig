const std = @import("std");
const ourokit = @import("ourokit");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedApplicationPath;
    const file = if (std.fs.path.isAbsolute(args[1]))
        try std.Io.Dir.openFileAbsolute(init.io, args[1], .{})
    else
        try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    const source = try reader.interface.allocRemaining(init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(source);
    try ourokit.app.runWayland(init, source, .{});
}
