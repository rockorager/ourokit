const std = @import("std");
const ui = @import("ourokit_ui");

pub fn main() !void {
    var surface: ui.Surface = undefined;
    try surface.init(std.heap.page_allocator, 6, 8);
    defer surface.deinit();
    try surface.reconcile(&.{
        .{
            .id = 1,
            .parent = null,
            .object = .{ .box = .{
                .background = ui.core.Color.rgba(28, 31, 38, 255),
                .border_color = ui.core.Color.rgba(72, 78, 92, 255),
                .border_width = 1,
                .corner_radius = 7,
            } },
        },
        .{ .id = 2, .parent = 1, .object = .{ .flex = .{ .gap = 4 } } },
        .{
            .id = 3,
            .parent = 2,
            .object = .{ .box = .{} },
            .parent_data = .{ .flex = .{ .factor = 1 } },
        },
        .{ .id = 4, .parent = 2, .object = .{ .box = .{ .width = 28 } } },
        .{ .id = 5, .parent = 2, .object = .{ .box = .{ .width = 28 } } },
        .{
            .id = 6,
            .parent = 2,
            .object = .{ .box = .{
                .width = 28,
                .background = ui.core.Color.rgba(174, 55, 67, 255),
            } },
        },
    });
    _ = try surface.layout(.{ .width = 240, .height = 32 });
    const list = try surface.buildDisplayList(1);
    var pixels: [240 * 32 * 4]u8 = @splat(0);
    try ui.software.render(list, .{
        .pixels = &pixels,
        .width = 240,
        .height = 32,
        .stride = 240 * 4,
        .format = .bgra8_unorm,
    });
    if (std.mem.indexOfNone(u8, &pixels, &.{0}) == null) return error.NothingRendered;
}
