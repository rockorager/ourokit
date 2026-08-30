const std = @import("std");
const Color = @import("../core/color.zig").Color;
const scene = @import("../scene/root.zig");
const software = @import("software/root.zig");

/// Backend conformance fixture. Future backends render the same commands and
/// compare their readback against `expected_rgba` under the documented
/// rasterization tolerance. Current integer rectangles require exact bytes.
pub const Fixture = struct {
    name: []const u8,
    width: u32,
    height: u32,
    commands: []const scene.Command,
    expected_rgba: []const u8,
};

const alpha_commands = [_]scene.Command{
    .{ .clear = Color.rgba(20, 40, 60, 255) },
    .{ .solid_rectangle = .{
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = Color.rgba(200, 100, 50, 128),
    } },
};

pub const fixtures = [_]Fixture{.{
    .name = "premultiplied encoded-srgb source-over",
    .width = 2,
    .height = 1,
    .commands = &alpha_commands,
    .expected_rgba = &.{ 110, 70, 55, 255, 20, 40, 60, 255 },
}};

test "software backend satisfies exact integer conformance fixtures" {
    for (fixtures) |fixture| {
        const size = fixture.width * fixture.height * 4;
        const pixels = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0);
        try software.render(.{ .commands = fixture.commands }, .{
            .pixels = pixels,
            .width = fixture.width,
            .height = fixture.height,
            .stride = fixture.width * 4,
            .format = .rgba8_unorm,
        });
        std.testing.expectEqualSlices(u8, fixture.expected_rgba, pixels) catch |err| {
            std.debug.print("conformance fixture failed: {s}\n", .{fixture.name});
            return err;
        };
    }
}
