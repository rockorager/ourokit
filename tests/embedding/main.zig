const std = @import("std");
const ui = @import("ourokit_ui");

pub fn main() !void {
    var images = try ui.ImageCache.init(std.heap.page_allocator, 1);
    defer images.deinit();
    var surface: ui.Surface = undefined;
    try surface.init(std.heap.page_allocator, 6, 8);
    defer surface.deinit();
    surface.attachImageCache(&images);
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

    // The platform-neutral API accepts caller-decoded pixels without importing
    // codecs, Rust, the host, or FreeType. The surface owns a separate lease.
    var bitmap: ui.ImageBitmap = .{
        .allocator = std.heap.page_allocator,
        .pixels = try std.heap.page_allocator.dupe(u8, &.{ 10, 20, 30, 255, 60, 80, 100, 255 }),
        .width = 2,
        .height = 1,
        .intrinsic_width = 2,
        .intrinsic_height = 1,
    };
    const image = images.insert(bitmap) catch |err| {
        bitmap.deinit();
        return err;
    };
    try surface.reconcile(&.{.{ .id = 7, .parent = null, .object = .{ .image = .{ .image = image, .fit = .fill } } }});
    try images.release(image);
    _ = try surface.layout(.{ .width = 240, .height = 32 });
    try ui.software.renderResources(try surface.buildDisplayList(1), .{
        .pixels = &pixels,
        .width = 240,
        .height = 32,
        .stride = 240 * 4,
        .format = .bgra8_unorm,
    }, null, null, null, &images);
    const left = (16 * 240 + 8) * 4;
    const right = (16 * 240 + 231) * 4;
    if (!std.mem.eql(u8, pixels[left..][0..4], &.{ 30, 20, 10, 255 }) or
        !std.mem.eql(u8, pixels[right..][0..4], &.{ 100, 80, 60, 255 })) return error.IncorrectImagePixels;
    try surface.reconcile(&.{});
    if (images.byteSize() != 0) return error.ImageLeaseLeaked;
}
