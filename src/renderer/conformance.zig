const std = @import("std");
const Color = @import("../core/color.zig").Color;
const scene = @import("../scene/root.zig");
const software = @import("software/root.zig");

test "shadow coverage knockout clipping and changed extents replay exactly" {
    const shadows = @import("../shadow/root.zig");
    const allocator = std.testing.allocator;
    const viewport = @import("../core/geometry.zig").RectI{ .x = 0, .y = 0, .width = 64, .height = 48 };
    var tracker = try scene.DamageTracker.init(allocator, 4);
    defer tracker.deinit();
    var shape: shadows.Shape = .{ .box = .{ .x = 10, .y = 8, .width = 20, .height = 16 }, .offset = .{ .x = 12, .y = 4 } };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(7, 11, 19, 255) },
        .{ .push_clip_rect = .{ .x = 0, .y = 0, .width = 40, .height = 48 } },
        .{ .shadow = .{ .shape = shape, .bounds = try shadows.deviceBounds(shape), .color = Color.rgba(220, 50, 80, 128) } },
        .pop_clip,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 34, .y = 14, .width = 2, .height = 3 }, .color = Color.rgba(251, 197, 29, 255) } },
    };
    var full: [64 * 48 * 4]u8 = undefined;
    var partial: @TypeOf(full) = undefined;
    const target: software.Target = .{ .pixels = &full, .width = 64, .height = 48, .stride = 64 * 4, .format = .rgba8_unorm, .allocator = allocator };
    var partial_target = target;
    partial_target.pixels = &partial;
    for (0..4) |revision| {
        if (revision == 1) {
            // Change every extent-producing property, including negative placement.
            shape = .{ .box = .{ .x = 5, .y = 13, .width = 20, .height = 16 }, .corner_radius = 5, .offset = .{ .x = -7.25, .y = 3.5 }, .blur = 6, .spread = 2 };
            commands[2].shadow.shape = shape;
            commands[2].shadow.bounds = try shadows.deviceBounds(shape);
        } else if (revision == 2) {
            // Color must invalidate paint despite identical coverage and bounds.
            commands[2].shadow.color = Color.rgba(20, 190, 120, 211);
        }
        const removed = [_]scene.Command{ commands[0], commands[4] };
        const current: []const scene.Command = if (revision == 3) &removed else &commands;
        const damage = try tracker.compare(current, viewport);
        try software.render(.{ .commands = current }, target);
        try software.render(.{ .commands = current, .damage = damage }, partial_target);
        try std.testing.expectEqualSlices(u8, &full, &partial);
        if (revision == 0) {
            // Full-coverage source-over calculated independently in linear sRGB.
            try std.testing.expectEqualSlices(u8, &.{ 162, 36, 59, 255 }, full[(18 * 64 + 32) * 4 ..][0..4]);
            // The original box is transparent yet still knocks out its interior.
            try std.testing.expectEqualSlices(u8, &.{ 7, 11, 19, 255 }, full[(18 * 64 + 26) * 4 ..][0..4]);
            try std.testing.expectEqualSlices(u8, &.{ 7, 11, 19, 255 }, full[(18 * 64 + 41) * 4 ..][0..4]);
            try std.testing.expectEqualSlices(u8, &.{ 251, 197, 29, 255 }, full[(15 * 64 + 35) * 4 ..][0..4]);
        }
        if (revision == 1) {
            // Knockout remains clear after blur; outside the box the tail fades.
            try std.testing.expectEqualSlices(u8, &.{ 7, 11, 19, 255 }, full[(20 * 64 + 12) * 4 ..][0..4]);
            try std.testing.expect(full[(20 * 64 + 3) * 4] > full[(10 * 64 + 3) * 4]);
            try std.testing.expect(full[(10 * 64 + 3) * 4] > 7);
        }
        if (@import("ourokit_build_options").vulkan) {
            const vulkan = @import("vulkan/root.zig");
            var renderer = vulkan.init(allocator) catch |err| switch (err) {
                error.VulkanUnavailable => return error.SkipZigTest,
                else => return err,
            };
            defer renderer.deinit();
            var gpu = try vulkan.Target.init(&renderer, 64, 48);
            defer gpu.deinit(&renderer);
            try renderer.render(.{ .commands = current }, &gpu);
            var actual: @TypeOf(full) = undefined;
            try gpu.readPixels(&actual, 64 * 4, .rgba8_unorm);
            try std.testing.expectEqualSlices(u8, &full, &actual);
        }
        tracker.submitted();
        try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(current, viewport)).regions.len);
    }
    const invalid = [_]scene.Command{.{ .shadow = .{ .shape = shape, .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(0, 0, 0, 255) } }};
    try std.testing.expectError(error.InvalidShadow, (scene.DisplayList{ .commands = &invalid }).validate());
    try std.testing.expect(!(scene.DisplayList{ .commands = commands[1..4] }).isOpaque(viewport));
}

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

const decorated_commands = [_]scene.Command{
    .{ .clear = Color.rgba(0, 0, 0, 255) },
    .{ .decorated_rectangle = .{
        .bounds = .{ .x = 0, .y = 0, .width = 5, .height = 5 },
        .background = Color.rgba(0, 200, 0, 255),
        .border_color = Color.rgba(200, 0, 0, 255),
        .border_width = 1,
        .corner_radius = 2,
    } },
};

const red = [_]u8{ 200, 0, 0, 255 };
const green = [_]u8{ 0, 200, 0, 255 };
// sRGB encode(sRGB-decode(200/255) * coverage), with geometric coverage
// 97/255, 234/255, and border/background weights 53/255 and 202/255.
const corner_red = [_]u8{ 129, 0, 0, 255 };
const edge_red = [_]u8{ 192, 0, 0, 255 };
const edge_mix = [_]u8{ 97, 180, 0, 255 };

pub const fixtures = [_]Fixture{
    .{
        .name = "premultiplied linear-light source-over",
        .width = 2,
        .height = 1,
        .commands = &alpha_commands,
        .expected_rgba = &.{ 147, 77, 55, 255, 20, 40, 60, 255 },
    },
    .{
        .name = "rounded background and border",
        .width = 5,
        .height = 5,
        .commands = &decorated_commands,
        .expected_rgba = &(corner_red ++ edge_red ++ red ++ edge_red ++ corner_red ++
            edge_red ++ edge_mix ++ green ++ edge_mix ++ edge_red ++
            red ++ green ++ green ++ green ++ red ++
            edge_red ++ edge_mix ++ green ++ edge_mix ++ edge_red ++
            corner_red ++ edge_red ++ red ++ edge_red ++ corner_red),
    },
};

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

test "path coverage preserves holes paint order clips and backend parity" {
    const paths = @import("../path/root.zig");
    const allocator = std.testing.allocator;
    const fill = try paths.Path.create(allocator, &.{
        .{ .move = .{ .x = 2, .y = 2 } },
        .{ .line = .{ .x = 22, .y = 2 } },
        .{ .line = .{ .x = 22, .y = 18 } },
        .{ .line = .{ .x = 2, .y = 18 } },
        .close,
        .{ .move = .{ .x = 7, .y = 6 } },
        .{ .line = .{ .x = 15, .y = 6 } },
        .{ .line = .{ .x = 15, .y = 12 } },
        .{ .line = .{ .x = 7, .y = 12 } },
        .close,
    }, .{ .fill = .even_odd });
    defer fill.release();
    const stroke = try paths.Path.create(allocator, &.{
        .{ .move = .{ .x = 3, .y = 25 } },
        .{ .quadratic = .{ .control = .{ .x = 9, .y = 14 }, .to = .{ .x = 16, .y = 24 } } },
        .{ .cubic = .{ .control1 = .{ .x = 23, .y = 33 }, .control2 = .{ .x = 31, .y = 14 }, .to = .{ .x = 37, .y = 26 } } },
    }, .{ .stroke = .{ .width = 2.5, .cap = .round, .join = .bevel } });
    defer stroke.release();
    const origin = @import("../core/geometry.zig").PointF{ .x = 0.25, .y = 0.5 };
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(7, 11, 19, 255) },
        .{ .path = .{ .path = fill, .identity = fill.identity, .origin = .{}, .scale = 1, .bounds = try paths.deviceBounds(fill, .{}, 1), .color = Color.rgba(220, 50, 80, 128) } },
        .{ .path = .{ .path = stroke, .identity = stroke.identity, .origin = origin, .scale = 1.25, .bounds = try paths.deviceBounds(stroke, origin, 1.25), .color = Color.rgba(30, 210, 95, 173) } },
        .{ .push_clip_rect = .{ .x = 28, .y = 0, .width = 5, .height = 20 } },
        .{ .path = .{ .path = fill, .identity = fill.identity, .origin = .{ .x = 24 }, .scale = 1, .bounds = try paths.deviceBounds(fill, .{ .x = 24 }, 1), .color = Color.rgba(13, 25, 231, 255) } },
        .pop_clip,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 3, .y = 3, .width = 2, .height = 2 }, .color = Color.rgba(251, 197, 29, 255) } },
    };
    var expected: [48 * 40 * 4]u8 = undefined;
    try software.render(.{ .commands = &commands }, .{ .pixels = &expected, .width = 48, .height = 40, .stride = 48 * 4, .format = .rgba8_unorm, .allocator = allocator });
    // Independently calculated sRGB linear-light source-over at full coverage.
    try std.testing.expectEqualSlices(u8, &.{ 162, 36, 59, 255 }, expected[(4 * 48 + 19) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 7, 11, 19, 255 }, expected[(8 * 48 + 9) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 251, 197, 29, 255 }, expected[(3 * 48 + 3) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 13, 25, 231, 255 }, expected[(4 * 48 + 29) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 7, 11, 19, 255 }, expected[(4 * 48 + 34) * 4 ..][0..4]);
    if (@import("ourokit_build_options").vulkan) {
        const vulkan = @import("vulkan/root.zig");
        var renderer = vulkan.init(allocator) catch |err| switch (err) {
            error.VulkanUnavailable => return error.SkipZigTest,
            else => return err,
        };
        defer renderer.deinit();
        var target = try vulkan.Target.init(&renderer, 48, 40);
        defer target.deinit(&renderer);
        try renderer.render(.{ .commands = &commands }, &target);
        var actual: @TypeOf(expected) = undefined;
        try target.readPixels(&actual, 48 * 4, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        // Each damage traversal must restart the path-upload command index.
        try renderer.render(.{ .commands = &commands, .damage = .{ .regions = &.{
            .{ .x = 1, .y = 1, .width = 22, .height = 17 },
            .{ .x = 26, .y = 0, .width = 11, .height = 20 },
        } } }, &target);
        try target.readPixels(&actual, 48 * 4, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}
