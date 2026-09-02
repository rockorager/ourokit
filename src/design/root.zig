pub const tokens = @import("generated/tokens.zig");

test "canonical typography delegates generic sans-serif to platform discovery" {
    const std = @import("std");
    try std.testing.expectEqualStrings("sans-serif", tokens.foundation.typography_family);
}

test "semantic themes map onto public Radix color scales" {
    const std = @import("std");
    try std.testing.expectEqual(tokens.palette.light.indigo.step_9, tokens.light.primary);
    try std.testing.expectEqual(tokens.palette.dark.indigo.step_9, tokens.dark.primary);
    try std.testing.expectEqual(tokens.palette.light.slate.step_5, tokens.light.sidebar_accent_selected);
    try std.testing.expect(tokens.palette.dark.indigo_alpha.step_5.a < 255);
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
    try std.testing.expectEqualSlices(u8, &.{ 0x3e, 0x63, 0xdd, 0xff }, &pixel);
}
