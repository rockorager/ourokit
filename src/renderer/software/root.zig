const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const PremultipliedSrgba8 = @import("../../core/color.zig").PremultipliedSrgba8;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");

/// Both formats store premultiplied, encoded-sRGB channels. The names describe
/// byte order, not the scene color representation.
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

const max_clip_depth = 64;

pub fn render(list: scene.DisplayList, target: Target) !void {
    try target.validate();
    try list.validate();
    switch (list.damage) {
        .full => try renderRegion(list.commands, target, targetBounds(target)),
        .regions => |regions| {
            for (regions) |region| {
                const clipped = RectI.intersect(region, targetBounds(target));
                if (!clipped.isEmpty()) try renderRegion(list.commands, target, clipped);
            }
        },
    }
}

fn renderRegion(commands: []const scene.Command, target: Target, damage: RectI) !void {
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var depth: usize = 0;
    for (commands) |command| switch (command) {
        .clear => |color| fill(target, damage, color, .source),
        .push_clip_rect => |clip| {
            if (depth == max_clip_depth) return error.ClipStackOverflow;
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| fill(
            target,
            RectI.intersect(rectangle.bounds, clips[depth]),
            rectangle.color,
            rectangle.blend,
        ),
    };
}

fn fill(target: Target, bounds: RectI, color: Color, blend: scene.BlendMode) void {
    if (bounds.isEmpty()) return;
    const source = color.premultiplied();
    if (blend == .source or source.a == 255) {
        fillSource(target, bounds, source);
        return;
    }
    const left: u32 = @intCast(bounds.x);
    const top: u32 = @intCast(bounds.y);
    const right: u32 = @intCast(@as(i64, bounds.x) + bounds.width);
    const bottom: u32 = @intCast(@as(i64, bounds.y) + bounds.height);
    for (top..bottom) |y| {
        for (left..right) |x| {
            const offset = y * target.stride + x * 4;
            const destination = readPixel(target.format, target.pixels[offset..][0..4]);
            writePixel(target.format, target.pixels[offset..][0..4], sourceOver(source, destination));
        }
    }
}

fn fillSource(target: Target, bounds: RectI, source: PremultipliedSrgba8) void {
    const left: usize = @intCast(bounds.x);
    const top: usize = @intCast(bounds.y);
    const right: usize = @intCast(@as(i64, bounds.x) + bounds.width);
    const bottom: usize = @intCast(@as(i64, bounds.y) + bounds.height);
    const bytes = pixelBytes(target.format, source);
    const row_bytes = (right - left) * 4;
    for (top..bottom) |y| {
        const offset = y * target.stride + left * 4;
        const row = target.pixels[offset..][0..row_bytes];
        @memcpy(row[0..4], &bytes);
        var initialized: usize = 4;
        while (initialized < row.len) {
            const count = @min(initialized, row.len - initialized);
            @memcpy(row[initialized..][0..count], row[0..count]);
            initialized += count;
        }
    }
}

fn sourceOver(source: PremultipliedSrgba8, destination: PremultipliedSrgba8) PremultipliedSrgba8 {
    const inverse_alpha = 255 - source.a;
    return .{
        .r = addSaturating(source.r, multiply(destination.r, inverse_alpha)),
        .g = addSaturating(source.g, multiply(destination.g, inverse_alpha)),
        .b = addSaturating(source.b, multiply(destination.b, inverse_alpha)),
        .a = addSaturating(source.a, multiply(destination.a, inverse_alpha)),
    };
}

fn multiply(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * alpha + 127) / 255);
}

fn addSaturating(a: u8, b: u8) u8 {
    return @intCast(@min(@as(u16, a) + b, 255));
}

fn readPixel(format: PixelFormat, bytes: *const [4]u8) PremultipliedSrgba8 {
    return switch (format) {
        .rgba8_unorm => .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] },
        .bgra8_unorm => .{ .r = bytes[2], .g = bytes[1], .b = bytes[0], .a = bytes[3] },
    };
}

fn writePixel(format: PixelFormat, destination: *[4]u8, pixel: PremultipliedSrgba8) void {
    destination.* = pixelBytes(format, pixel);
}

fn pixelBytes(format: PixelFormat, pixel: PremultipliedSrgba8) [4]u8 {
    return switch (format) {
        .rgba8_unorm => .{ pixel.r, pixel.g, pixel.b, pixel.a },
        .bgra8_unorm => .{ pixel.b, pixel.g, pixel.r, pixel.a },
    };
}

fn targetBounds(target: Target) RectI {
    return .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
}

test "clear and clipped rectangle produce deterministic premultiplied pixels" {
    var pixels = [_]u8{0xaa} ** 28;
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(1, 2, 3, 255) },
        .{ .push_clip_rect = .{ .x = 0, .y = 1, .width = 2, .height = 1 } },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = -1, .y = 0, .width = 3, .height = 2 },
            .color = Color.rgba(20, 40, 60, 128),
        } },
        .pop_clip,
    };
    try render(.{ .commands = &commands }, .{
        .pixels = &pixels,
        .width = 3,
        .height = 2,
        .stride = 14,
        .format = .rgba8_unorm,
    });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 1, 2, 3, 255, 1, 2, 3, 255 }, pixels[0..12]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 21, 31, 255, 10, 21, 31, 255, 1, 2, 3, 255 }, pixels[14..26]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, pixels[12..14]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa }, pixels[26..28]);
}

test "damage preserves pixels outside non-overlapping regions" {
    var pixels = [_]u8{0xaa} ** 12;
    const commands = [_]scene.Command{.{ .clear = Color.rgba(1, 2, 3, 255) }};
    const regions = [_]RectI{
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ .x = 2, .y = 0, .width = 1, .height = 1 },
    };
    try render(.{ .commands = &commands, .damage = .{ .regions = &regions } }, .{
        .pixels = &pixels,
        .width = 3,
        .height = 1,
        .stride = 12,
        .format = .rgba8_unorm,
    });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 0xaa, 0xaa, 0xaa, 0xaa, 1, 2, 3, 255 }, &pixels);
    try std.testing.expectError(error.OverlappingDamage, render(.{
        .commands = &commands,
        .damage = .{ .regions = &.{
            .{ .x = 0, .y = 0, .width = 2, .height = 1 },
            .{ .x = 1, .y = 0, .width = 2, .height = 1 },
        } },
    }, .{ .pixels = &pixels, .width = 3, .height = 1, .stride = 12, .format = .rgba8_unorm }));
}

test "BGRA storage, target validation, and clip balance are explicit" {
    var pixel = [_]u8{0} ** 4;
    const command = [_]scene.Command{.{ .clear = Color.rgba(10, 20, 30, 128) }};
    try render(.{ .commands = &command }, .{
        .pixels = &pixel,
        .width = 1,
        .height = 1,
        .stride = 4,
        .format = .bgra8_unorm,
    });
    try std.testing.expectEqualSlices(u8, &.{ 15, 10, 5, 128 }, &pixel);
    try std.testing.expectError(error.InvalidTarget, render(.{ .commands = &command }, .{
        .pixels = &pixel,
        .width = 2,
        .height = 1,
        .stride = 4,
        .format = .rgba8_unorm,
    }));
    try std.testing.expectError(error.UnbalancedClipStack, render(.{
        .commands = &.{.pop_clip},
    }, .{ .pixels = &pixel, .width = 1, .height = 1, .stride = 4, .format = .rgba8_unorm }));
    try std.testing.expectError(error.ClearInsideClip, render(.{
        .commands = &.{
            .{ .push_clip_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 } },
            .{ .clear = Color.rgba(0, 0, 0, 0) },
            .pop_clip,
        },
    }, .{ .pixels = &pixel, .width = 1, .height = 1, .stride = 4, .format = .rgba8_unorm }));
}
