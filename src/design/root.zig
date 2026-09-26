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

test "disabled controls retain readable opaque colors in both themes" {
    const std = @import("std");
    for ([_]tokens.Theme{ tokens.light, tokens.dark }) |theme| {
        var luminance: [2]f64 = .{ 0, 0 };
        for ([_]@import("../core/color.zig").Color{ theme.disabled, theme.disabled_foreground }, 0..) |color, i| {
            try std.testing.expectEqual(@as(u8, 255), color.a);
            for ([_]u8{ color.r, color.g, color.b }, [_]f64{ 0.2126, 0.7152, 0.0722 }) |channel, weight| {
                const encoded = @as(f64, @floatFromInt(channel)) / 255;
                const linear = if (encoded <= 0.04045) encoded / 12.92 else std.math.pow(f64, (encoded + 0.055) / 1.055, 2.4);
                luminance[i] += linear * weight;
            }
        }
        const contrast = (@max(luminance[0], luminance[1]) + 0.05) / (@min(luminance[0], luminance[1]) + 0.05);
        // Disabled controls are exempt from text contrast requirements, but
        // their labels should remain readable rather than disappear.
        try std.testing.expect(contrast >= 4.5);
        try std.testing.expect(!std.meta.eql(theme.disabled, theme.primary));
    }
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
    // Opaque Radix indigo 9 (#3e63dd) round-trips through linear light.
    try std.testing.expectEqualSlices(u8, &.{ 62, 99, 221, 255 }, &pixel);
}
