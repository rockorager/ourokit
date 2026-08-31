const std = @import("std");
const ui = @import("ourokit_ui");

const root_id = 1;
const row_id = 2;
const title_id = 3;
const minimize_id = 4;
const maximize_id = 5;
const close_id = 6;

fn titlebar(close_color: ui.core.Color) [6]ui.Descriptor {
    return .{
        .{
            .id = root_id,
            .parent = null,
            .object = .{ .box = .{
                .border_color = ui.core.Color.rgba(72, 78, 92, 255),
                .border_width = 1,
                .corner_radius = 7,
                .background = ui.core.Color.rgba(28, 31, 38, 255),
                .clip = true,
            } },
        },
        .{
            .id = row_id,
            .parent = root_id,
            .object = .{ .flex = .{
                .axis = .horizontal,
                .cross_axis_alignment = .stretch,
                .gap = 4,
            } },
        },
        .{
            .id = title_id,
            .parent = row_id,
            .object = .{ .box = .{} },
            .parent_data = .{ .flex = .{ .factor = 1 } },
        },
        .{
            .id = minimize_id,
            .parent = row_id,
            .object = .{ .box = .{
                .width = 28,
                .background = ui.core.Color.rgba(61, 67, 79, 255),
            } },
        },
        .{
            .id = maximize_id,
            .parent = row_id,
            .object = .{ .box = .{
                .width = 28,
                .background = ui.core.Color.rgba(61, 67, 79, 255),
            } },
        },
        .{
            .id = close_id,
            .parent = row_id,
            .object = .{ .box = .{ .width = 28, .background = close_color } },
        },
    };
}

test "native titlebar reconciles, lays out, renders, and captures pointer" {
    var surface: ui.Surface = undefined;
    try surface.init(std.testing.allocator, 6, 8);
    defer surface.deinit();

    var snapshot = titlebar(ui.core.Color.rgba(174, 55, 67, 255));
    try surface.reconcile(&snapshot);
    try std.testing.expectEqual(
        ui.core.SizeF{ .width = 240, .height = 32 },
        try surface.layout(.{ .width = 240, .height = 32 }),
    );
    try std.testing.expectEqual(close_id, (try surface.hitTest(.{ .x = 225, .y = 16 })).?);
    try std.testing.expectEqual(minimize_id, (try surface.hitTest(.{ .x = 155, .y = 16 })).?);

    const first_list = try surface.buildDisplayList(1);
    var rgba_pixels: [240 * 32 * 4]u8 = @splat(0);
    try ui.software.render(first_list, .{
        .pixels = &rgba_pixels,
        .width = 240,
        .height = 32,
        .stride = 240 * 4,
        .format = .rgba8_unorm,
    });
    try std.testing.expect(std.mem.indexOfNone(u8, &rgba_pixels, &.{0}) != null);

    const pressed = try surface.pointerPress(.{ .x = 225, .y = 16 });
    try std.testing.expectEqual(close_id, pressed.target.?);
    const dragged = try surface.pointerMotion(.{ .x = 40, .y = 16 });
    try std.testing.expectEqual(close_id, dragged.target.?);
    try std.testing.expectEqual(title_id, dragged.hovered.?);
    const released = try surface.pointerRelease(.{ .x = 40, .y = 16 });
    try std.testing.expectEqual(close_id, released.target.?);
    try std.testing.expectEqual(title_id, released.hovered.?);
    const after_release = try surface.pointerMotion(.{ .x = 40, .y = 16 });
    try std.testing.expectEqual(title_id, after_release.target.?);

    snapshot = titlebar(ui.core.Color.rgba(210, 65, 75, 255));
    try surface.reconcile(&snapshot);
    _ = try surface.layout(.{ .width = 360, .height = 40 });
    const scaled_list = try surface.buildDisplayList(1.5);
    var bgra_pixels: [540 * 60 * 4]u8 = @splat(0);
    try ui.software.render(scaled_list, .{
        .pixels = &bgra_pixels,
        .width = 540,
        .height = 60,
        .stride = 540 * 4,
        .format = .bgra8_unorm,
    });
    try std.testing.expect(std.mem.indexOfNone(u8, &bgra_pixels, &.{0}) != null);
}

test "native surface reports node and scene capacity failures" {
    var too_few_nodes: ui.Surface = undefined;
    try too_few_nodes.init(std.testing.allocator, 5, 8);
    defer too_few_nodes.deinit();
    const snapshot = titlebar(ui.core.Color.rgba(174, 55, 67, 255));
    try std.testing.expectError(error.SurfaceCapacityExceeded, too_few_nodes.reconcile(&snapshot));

    var too_few_commands: ui.Surface = undefined;
    try too_few_commands.init(std.testing.allocator, 6, 1);
    defer too_few_commands.deinit();
    try too_few_commands.reconcile(&snapshot);
    _ = try too_few_commands.layout(.{ .width = 240, .height = 32 });
    try std.testing.expectError(error.SceneCapacityExceeded, too_few_commands.buildDisplayList(1));
}
