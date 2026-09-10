const std = @import("std");
const scene = @import("../scene/root.zig");
const Color = @import("../core/color.zig").Color;
const RectI = @import("../core/geometry.zig").RectI;
const images = @import("../image/cache.zig");
const Fit = @import("../image/pixels.zig").Fit;
const software = @import("software/root.zig");
const build_options = @import("ourokit_build_options");
const vulkan = if (build_options.vulkan) @import("vulkan/root.zig") else @import("vulkan/disabled.zig");

pub fn insertFixture(cache: *images.Cache) !images.ImageHandle {
    const pixels = try cache.allocator.dupe(u8, &.{
        240, 0, 0,   255, 0,  128, 0,  128, 0,   0,   0,  0,
        0,   0, 200, 255, 64, 32,  16, 64,  220, 180, 40, 255,
    });
    errdefer cache.allocator.free(pixels);
    return cache.insert(.{ .allocator = cache.allocator, .pixels = pixels, .width = 3, .height = 2, .intrinsic_width = 3, .intrinsic_height = 2 });
}

test "image fit centers contain and cover, fill uses bilinear premultiplied source-over" {
    var cache = try images.Cache.init(std.testing.allocator, 1);
    defer cache.deinit();
    const handle = try insertFixture(&cache);
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(20, 40, 60, 255) },
        .{ .image = .{ .image = handle, .bounds = .{ .x = 1, .y = 1, .width = 6, .height = 6 } } },
    };
    var pixels: [8 * 8 * 4]u8 = undefined;
    const target: software.Target = .{ .pixels = &pixels, .width = 8, .height = 8, .stride = 32, .format = .rgba8_unorm };
    try software.renderResources(.{ .commands = &commands }, target, null, null, null, &cache);
    // Contain renders 6x4, centered vertically; the first and last rows stay clear.
    try std.testing.expectEqualSlices(u8, &.{ 20, 40, 60, 255 }, pixels[(1 * 8 + 1) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 240, 0, 0, 255 }, pixels[(2 * 8 + 1) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 20, 40, 60, 255 }, pixels[(6 * 8 + 1) * 4 ..][0..4]);
    commands[1].image.fit = .cover;
    try software.renderResources(.{ .commands = &commands }, target, null, null, null, &cache);
    // Cover renders 9x6, cropping 1.5 pixels at each horizontal edge.
    try std.testing.expectEqualSlices(u8, &.{ 202, 25, 5, 255 }, pixels[(1 * 8 + 1) * 4 ..][0..4]);
    commands[1].image.fit = .fill;
    commands[1].image.bounds.height = 4;
    try software.renderResources(.{ .commands = &commands }, target, null, null, null, &cache);
    // Four texels weighted 9/16, 3/16, 3/16, 1/16 produce (139,26,39,219),
    // then source-over adds (3,6,8,36) from the destination.
    try std.testing.expectEqualSlices(u8, &.{ 142, 32, 47, 255 }, pixels[(2 * 8 + 2) * 4 ..][0..4]);
    // Fully transparent upper-right texel preserves the background.
    try std.testing.expectEqualSlices(u8, &.{ 20, 40, 60, 255 }, pixels[(1 * 8 + 6) * 4 ..][0..4]);
}

test "software images honor clipping, damage, BGRA padding and reject stale resources before drawing" {
    var cache = try images.Cache.init(std.testing.allocator, 1);
    defer cache.deinit();
    const handle = try insertFixture(&cache);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(20, 40, 60, 255) },
        .{ .push_clip_rect = .{ .x = 2, .y = 1, .width = 3, .height = 3 } },
        .{ .image = .{ .image = handle, .bounds = .{ .x = 1, .y = 1, .width = 6, .height = 4 }, .fit = .fill } },
        .pop_clip,
    };
    const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{.{ .x = 1, .y = 2, .width = 5, .height = 2 }} } };
    var pixels = [_]u8{0xaa} ** (8 * 36);
    const target: software.Target = .{ .pixels = &pixels, .width = 8, .height = 8, .stride = 36, .format = .bgra8_unorm };
    try software.renderResources(list, target, null, null, null, &cache);
    try std.testing.expectEqualSlices(u8, &.{ 47, 32, 142, 255 }, pixels[2 * 36 + 2 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 60, 40, 20, 255 }, pixels[2 * 36 + 1 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 60, 40, 20, 255 }, pixels[2 * 36 + 5 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, pixels[1 * 36 + 2 * 4 ..][0..4]);
    for (0..8) |y| try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, pixels[y * 36 + 32 ..][0..4]);
    const before = pixels;
    try std.testing.expectError(error.ImageResourcesRequired, software.render(list, target));
    try cache.release(handle);
    _ = try insertFixture(&cache); // Recycle the slot; an old generation must not resolve.
    try std.testing.expectError(error.StaleImageHandle, software.renderResources(list, target, null, null, null, &cache));
    try std.testing.expectEqualSlices(u8, &before, &pixels);
}

test "Vulkan images match software across fit modes, downscale, clipping, damage and alpha" {
    if (comptime !build_options.vulkan) return error.SkipZigTest;
    var renderer = vulkan.init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try vulkan.Target.init(&renderer, 11, 9);
    defer target.deinit(&renderer);
    var cache = try images.Cache.init(std.testing.allocator, 1);
    defer cache.deinit();
    const handle = try insertFixture(&cache);
    const bounds = [_]RectI{
        .{ .x = 1, .y = 1, .width = 6, .height = 6 },
        .{ .x = -2, .y = 2, .width = 11, .height = 5 },
        .{ .x = 3, .y = 4, .width = 2, .height = 1 },
        .{ .x = 2, .y = 0, .width = 0, .height = 7 },
    };
    for ([_]Fit{ .contain, .cover, .fill }) |fit| for (bounds) |box| {
        const commands = [_]scene.Command{
            .{ .clear = Color.rgba(20, 40, 60, 127) },
            .{ .image = .{ .image = handle, .bounds = .{ .x = 0, .y = 0, .width = 3, .height = 2 } } },
            .{ .push_clip_rect = .{ .x = 1, .y = 1, .width = 7, .height = 6 } },
            .{ .image = .{ .image = handle, .bounds = box, .fit = fit } },
            .pop_clip,
            .{ .solid_rectangle = .{ .bounds = .{ .x = 6, .y = 5, .width = 3, .height = 3 }, .color = Color.rgba(25, 87, 191, 64) } },
        };
        var expected = [_]u8{0} ** (11 * 9 * 4);
        var actual: [expected.len]u8 = undefined;
        const cpu: software.Target = .{ .pixels = &expected, .width = 11, .height = 9, .stride = 44, .format = .rgba8_unorm };
        var list = scene.DisplayList.init(&commands);
        try software.renderResources(list, cpu, null, null, null, &cache);
        try renderer.renderResources(list, &target, null, null, null, &cache);
        try target.readPixels(&actual, 44, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        list.damage = .{ .regions = &.{ .{ .x = 2, .y = 1, .width = 4, .height = 2 }, .{ .x = 0, .y = 4, .width = 5, .height = 4 } } };
        try software.renderResources(list, cpu, null, null, null, &cache);
        try renderer.renderResources(list, &target, null, null, null, &cache);
        try target.readPixels(&actual, 44, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    };
    const stale = [_]scene.Command{
        .{ .clear = Color.rgba(255, 255, 255, 255) },
        .{ .image = .{ .image = handle, .bounds = bounds[0] } },
    };
    var before: [11 * 9 * 4]u8 = undefined;
    try target.readPixels(&before, 44, .rgba8_unorm);
    try std.testing.expectError(error.ImageResourcesRequired, renderer.renderResources(.{ .commands = &stale }, &target, null, null, null, null));
    try cache.release(handle);
    _ = try insertFixture(&cache);
    try std.testing.expectError(error.StaleImageHandle, renderer.renderResources(.{ .commands = &stale }, &target, null, null, null, &cache));
    var after: [before.len]u8 = undefined;
    try target.readPixels(&after, 44, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &before, &after);
}
