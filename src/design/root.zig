pub const tokens = @import("generated/tokens.zig");

test "semantic tokens are consumable by renderer-neutral scenes" {
    const std = @import("std");
    const scene = @import("../scene/root.zig");
    const software = @import("../renderer/software/root.zig");

    const commands = [_]scene.Command{
        .{ .clear = tokens.light.surface_base },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .color = tokens.light.accent_default,
        } },
    };
    var pixel: [4]u8 = undefined;
    try software.render(.{ .commands = &commands }, .{
        .pixels = &pixel,
        .width = 1,
        .height = 1,
        .stride = 4,
        .format = .rgba8_unorm,
    });
    try std.testing.expectEqualSlices(u8, &.{ 0x24, 0x6b, 0xdb, 0xff }, &pixel);
}
