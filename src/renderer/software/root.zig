const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");

pub const PixelFormat = enum {
    rgba8_unorm,
    bgra8_unorm,
};

pub const Target = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    format: PixelFormat,

    pub fn validate(self: Target) !void {
        const row_bytes = std.math.mul(usize, self.width, 4) catch return error.InvalidTarget;
        if (self.stride < row_bytes) return error.InvalidTarget;
        const required = std.math.mul(usize, self.stride, self.height) catch return error.InvalidTarget;
        if (self.pixels.len < required) return error.InvalidTarget;
    }
};

pub fn render(list: scene.DisplayList, target: Target) !void {
    try target.validate();
    for (list.commands) |command| switch (command) {
        .clear => |color| fill(target, .{ .x = 0, .y = 0, .width = target.width, .height = target.height }, color),
        .solid_rectangle => |rectangle| fill(target, rectangle.bounds, rectangle.color),
    };
}

fn fill(target: Target, bounds: RectI, color: Color) void {
    const left: u32 = @intCast(@max(bounds.x, 0));
    const top: u32 = @intCast(@max(bounds.y, 0));
    const right_i64 = @min(@as(i64, bounds.x) + bounds.width, target.width);
    const bottom_i64 = @min(@as(i64, bounds.y) + bounds.height, target.height);
    if (right_i64 <= left or bottom_i64 <= top) return;
    const right: u32 = @intCast(right_i64);
    const bottom: u32 = @intCast(bottom_i64);
    const bytes = pixelBytes(target.format, color);

    for (top..bottom) |y| {
        for (left..right) |x| {
            const offset = y * target.stride + x * 4;
            @memcpy(target.pixels[offset..][0..4], &bytes);
        }
    }
}

fn pixelBytes(format: PixelFormat, color: Color) [4]u8 {
    return switch (format) {
        .rgba8_unorm => .{ color.r, color.g, color.b, color.a },
        .bgra8_unorm => .{ color.b, color.g, color.r, color.a },
    };
}

test "clear and clipped rectangle produce deterministic RGBA pixels" {
    var pixels = [_]u8{0xaa} ** 28;
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(1, 2, 3, 255) },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = -1, .y = 1, .width = 3, .height = 2 },
            .color = Color.rgba(10, 20, 30, 40),
        } },
    };
    try render(.{ .commands = &commands }, .{
        .pixels = &pixels,
        .width = 3,
        .height = 2,
        .stride = 14,
        .format = .rgba8_unorm,
    });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 1, 2, 3, 255, 1, 2, 3, 255 }, pixels[0..12]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 10, 20, 30, 40, 1, 2, 3, 255 }, pixels[14..26]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, pixels[12..14]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, pixels[26..28]);
}

test "BGRA format and invalid stride are explicit" {
    var pixel = [_]u8{0} ** 4;
    const command = [_]scene.Command{.{ .clear = Color.rgba(1, 2, 3, 4) }};
    try render(.{ .commands = &command }, .{
        .pixels = &pixel,
        .width = 1,
        .height = 1,
        .stride = 4,
        .format = .bgra8_unorm,
    });
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4 }, &pixel);
    try std.testing.expectError(error.InvalidTarget, render(.{ .commands = &command }, .{
        .pixels = &pixel,
        .width = 2,
        .height = 1,
        .stride = 4,
        .format = .rgba8_unorm,
    }));
}
