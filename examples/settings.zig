const std = @import("std");
const ourokit = @import("ourokit");

pub fn main(init: std.process.Init) !void {
    try ourokit.app.runWayland(init, @embedFile("widget-gallery.lua"), .{});
}
