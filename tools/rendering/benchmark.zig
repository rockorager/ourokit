const std = @import("std");
const ourokit = @import("ourokit");
const pixman = @cImport({
    @cInclude("pixman.h");
});

const width = 1920;
const height = 1080;
const opaque_count = 100;
const alpha_count = 20;
const command_count = 1 + opaque_count + alpha_count;
const iterations = 120;

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").mode == .Debug)
        std.debug.print("warning: use -Doptimize=ReleaseFast for meaningful results\n", .{});
    const pixels_len = width * height * 4;
    const ouro_pixels = try init.gpa.alignedAlloc(u8, .of(u32), pixels_len);
    defer init.gpa.free(ouro_pixels);
    const pixman_pixels = try init.gpa.alignedAlloc(u8, .of(u32), pixels_len);
    defer init.gpa.free(pixman_pixels);

    var commands: [command_count]ourokit.scene.Command = undefined;
    var opaque_boxes: [opaque_count]pixman.pixman_box32_t = undefined;
    var alpha_boxes: [alpha_count]pixman.pixman_box32_t = undefined;
    buildWorkload(&commands, &opaque_boxes, &alpha_boxes);

    const image = pixman.pixman_image_create_bits(
        pixman.PIXMAN_a8r8g8b8,
        width,
        height,
        @ptrCast(@alignCast(pixman_pixels.ptr)),
        width * 4,
    ) orelse return error.PixmanImageAllocationFailed;
    defer _ = pixman.pixman_image_unref(image);

    try renderOuro(&commands, ouro_pixels);
    try renderPixman(image, &opaque_boxes, &alpha_boxes);
    try std.testing.expectEqualSlices(u8, ouro_pixels, pixman_pixels);

    const ouro_start = nanoTime();
    for (0..iterations) |_| try renderOuro(&commands, ouro_pixels);
    const pixman_start = nanoTime();
    for (0..iterations) |_| try renderPixman(image, &opaque_boxes, &alpha_boxes);
    const end = nanoTime();
    const ouro_ns = pixman_start - ouro_start;
    const pixman_ns = end - pixman_start;
    std.mem.doNotOptimizeAway(ouro_pixels[0]);
    std.mem.doNotOptimizeAway(pixman_pixels[0]);

    printResult("ouro-direct", ouro_ns);
    printResult("pixman-0.46.4", pixman_ns);
    std.debug.print("ratio pixman/ouro: {d:.3}\n", .{
        @as(f64, @floatFromInt(pixman_ns)) / @as(f64, @floatFromInt(ouro_ns)),
    });
}

fn nanoTime() u64 {
    const linux = std.os.linux;
    var value: linux.timespec = undefined;
    std.debug.assert(linux.errno(linux.clock_gettime(.MONOTONIC, &value)) == .SUCCESS);
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}

fn buildWorkload(
    commands: *[command_count]ourokit.scene.Command,
    opaque_boxes: *[opaque_count]pixman.pixman_box32_t,
    alpha_boxes: *[alpha_count]pixman.pixman_box32_t,
) void {
    commands[0] = .{ .clear = ourokit.core.Color.rgba(247, 247, 248, 255) };
    for (opaque_boxes, 0..) |*box, index| {
        const x: i32 = @intCast((index % 10) * 190);
        const y: i32 = @intCast((index / 10) * 100);
        box.* = .{ .x1 = x, .y1 = y, .x2 = x + 160, .y2 = y + 72 };
        commands[1 + index] = .{ .solid_rectangle = .{
            .bounds = .{ .x = x, .y = y, .width = 160, .height = 72 },
            .color = ourokit.core.Color.rgba(36, 107, 219, 255),
        } };
    }
    for (alpha_boxes, 0..) |*box, index| {
        const x: i32 = @intCast((index % 5) * 380 + 40);
        const y: i32 = @intCast((index / 5) * 240 + 40);
        box.* = .{ .x1 = x, .y1 = y, .x2 = x + 300, .y2 = y + 160 };
        commands[1 + opaque_count + index] = .{ .solid_rectangle = .{
            .bounds = .{ .x = x, .y = y, .width = 300, .height = 160 },
            .color = ourokit.core.Color.rgba(200, 50, 40, 128),
        } };
    }
}

fn renderOuro(commands: []const ourokit.scene.Command, pixels: []u8) !void {
    try ourokit.renderer.software.render(.{ .commands = commands }, .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = width * 4,
        .format = .bgra8_unorm,
    });
}

fn renderPixman(
    image: *pixman.pixman_image_t,
    opaque_boxes: []const pixman.pixman_box32_t,
    alpha_boxes: []const pixman.pixman_box32_t,
) !void {
    const clear = pixman.pixman_color_t{
        .red = 247 * 257,
        .green = 247 * 257,
        .blue = 248 * 257,
        .alpha = 255 * 257,
    };
    const opaque_color = pixman.pixman_color_t{
        .red = 36 * 257,
        .green = 107 * 257,
        .blue = 219 * 257,
        .alpha = 255 * 257,
    };
    const alpha = ourokit.core.Color.rgba(200, 50, 40, 128).premultiplied();
    const translucent = pixman.pixman_color_t{
        .red = @as(u16, alpha.r) * 257,
        .green = @as(u16, alpha.g) * 257,
        .blue = @as(u16, alpha.b) * 257,
        .alpha = @as(u16, alpha.a) * 257,
    };
    const full = [1]pixman.pixman_box32_t{.{ .x1 = 0, .y1 = 0, .x2 = width, .y2 = height }};
    if (pixman.pixman_image_fill_boxes(pixman.PIXMAN_OP_SRC, image, &clear, 1, &full) == 0)
        return error.PixmanFillFailed;
    if (pixman.pixman_image_fill_boxes(
        pixman.PIXMAN_OP_SRC,
        image,
        &opaque_color,
        @intCast(opaque_boxes.len),
        opaque_boxes.ptr,
    ) == 0) return error.PixmanFillFailed;
    if (pixman.pixman_image_fill_boxes(
        pixman.PIXMAN_OP_OVER,
        image,
        &translucent,
        @intCast(alpha_boxes.len),
        alpha_boxes.ptr,
    ) == 0) return error.PixmanFillFailed;
}

fn printResult(name: []const u8, total_ns: u64) void {
    const per_frame = @as(f64, @floatFromInt(total_ns)) / iterations / std.time.ns_per_ms;
    std.debug.print("{s}: {d:.3} ms/frame ({d} iterations)\n", .{ name, per_frame, iterations });
}
