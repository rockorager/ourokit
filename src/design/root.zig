pub const tokens = @import("generated/tokens.zig");

test "canonical typography delegates generic sans-serif to platform discovery" {
    const std = @import("std");
    try std.testing.expectEqualStrings("sans-serif", tokens.foundation.typography_family);
}

test "semantic tokens are consumable by renderer-neutral scenes" {
    const std = @import("std");
    const scene = @import("../scene/root.zig");
    const software = @import("../renderer/software/root.zig");

    const commands = [_]scene.Command{
        .{ .clear = tokens.light.background },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .color = tokens.light.primary,
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
    try std.testing.expectEqualSlices(u8, &.{ 0x17, 0x17, 0x17, 0xff }, &pixel);
}
