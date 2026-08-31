const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const PremultipliedSrgba8 = @import("../../core/color.zig").PremultipliedSrgba8;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");
const text = @import("../../text/root.zig");
const build_options = @import("ourokit_build_options");

pub const has_freetype = build_options.freetype;
pub const GlyphCache = if (has_freetype)
    @import("glyph_cache.zig").GlyphCache
else
    struct {};
const GlyphBitmap = if (has_freetype)
    @import("glyph_cache.zig").GlyphBitmap
else
    struct {};

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

const max_clip_depth = scene.max_clip_depth;

pub fn render(list: scene.DisplayList, target: Target) !void {
    return renderInternal(list, target, null, null);
}

pub fn renderText(
    list: scene.DisplayList,
    target: Target,
    glyphs: *GlyphCache,
    shapes: *const text.ShapeCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    return renderInternal(list, target, glyphs, shapes);
}

fn renderInternal(
    list: scene.DisplayList,
    target: Target,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
) !void {
    try target.validate();
    try list.validate();
    switch (list.damage) {
        .full => try renderRegion(list.commands, target, targetBounds(target), glyphs, shapes),
        .regions => |regions| {
            for (regions) |region| {
                const clipped = RectI.intersect(region, targetBounds(target));
                if (!clipped.isEmpty()) try renderRegion(list.commands, target, clipped, glyphs, shapes);
            }
        },
    }
}

fn renderRegion(
    commands: []const scene.Command,
    target: Target,
    damage: RectI,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
) !void {
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var depth: usize = 0;
    for (commands, 0..) |command, index| switch (command) {
        .clear => |color| if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], damage))
            fill(target, damage, color, .source),
        .push_clip_rect => |clip| {
            if (depth == max_clip_depth) return error.ClipStackOverflow;
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| {
            const bounds = RectI.intersect(rectangle.bounds, clips[depth]);
            if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], bounds))
                fill(target, bounds, rectangle.color, rectangle.blend);
        },
        .decorated_rectangle => |rectangle| {
            const bounds = RectI.intersect(rectangle.bounds, clips[depth]);
            drawDecoratedRectangle(target, bounds, rectangle);
        },
        .glyph_run => |run| {
            if (scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], clips[depth])) continue;
            if (!has_freetype) return error.FreeTypeDisabled;
            try drawGlyphRun(
                run,
                target,
                clips[depth],
                glyphs orelse return error.TextResourcesRequired,
                shapes orelse return error.TextResourcesRequired,
            );
        },
    };
}

fn drawGlyphRun(
    command: scene.GlyphRun,
    target: Target,
    clip: RectI,
    cache: *GlyphCache,
    shapes: *const text.ShapeCache,
) !void {
    const shaped = try shapes.get(command.shape);
    var pen = command.origin;
    for (shaped.spans) |span| {
        for (span.run.glyphs) |glyph| {
            const bitmap = try cache.get(
                span.font,
                glyph.id,
                shaped.logical_size * command.scale,
            );
            const left: i32 = @intFromFloat(@round(pen.x + glyph.offset.x * command.scale));
            const baseline: i32 = @intFromFloat(@round(pen.y - glyph.offset.y * command.scale));
            drawMask(
                target,
                clip,
                left + bitmap.left,
                baseline - bitmap.top,
                bitmap,
                command.color,
            );
            pen.x += glyph.advance.x * command.scale;
            pen.y -= glyph.advance.y * command.scale;
        }
    }
}

fn drawMask(
    target: Target,
    clip: RectI,
    x: i32,
    y: i32,
    bitmap: *const GlyphBitmap,
    color: Color,
) void {
    const bounds = RectI.intersect(clip, .{
        .x = x,
        .y = y,
        .width = bitmap.width,
        .height = bitmap.height,
    });
    if (bounds.isEmpty()) return;
    const source_color = color.premultiplied();
    const source_x: usize = @intCast(bounds.x - x);
    const source_y: usize = @intCast(bounds.y - y);
    const width: usize = bounds.width;
    const height: usize = bounds.height;
    for (0..height) |row| {
        for (0..width) |column| {
            const coverage = bitmap.pixels[(source_y + row) * bitmap.width + source_x + column];
            if (coverage == 0) continue;
            const source: PremultipliedSrgba8 = .{
                .r = multiply(source_color.r, coverage),
                .g = multiply(source_color.g, coverage),
                .b = multiply(source_color.b, coverage),
                .a = multiply(source_color.a, coverage),
            };
            const destination_offset = (@as(usize, @intCast(bounds.y)) + row) * target.stride +
                (@as(usize, @intCast(bounds.x)) + column) * 4;
            const destination = readPixel(
                target.format,
                target.pixels[destination_offset..][0..4],
            );
            writePixel(
                target.format,
                target.pixels[destination_offset..][0..4],
                sourceOver(source, destination),
            );
        }
    }
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

fn drawDecoratedRectangle(
    target: Target,
    clipped_bounds: RectI,
    rectangle: scene.DecoratedRectangle,
) void {
    if (clipped_bounds.isEmpty()) return;
    const left: u32 = @intCast(clipped_bounds.x);
    const top: u32 = @intCast(clipped_bounds.y);
    const right: u32 = @intCast(@as(i64, clipped_bounds.x) + clipped_bounds.width);
    const bottom: u32 = @intCast(@as(i64, clipped_bounds.y) + clipped_bounds.height);
    const inset = @min(rectangle.border_width, @min(rectangle.bounds.width, rectangle.bounds.height) / 2);
    const inner: RectI = .{
        .x = rectangle.bounds.x + @as(i32, @intCast(inset)),
        .y = rectangle.bounds.y + @as(i32, @intCast(inset)),
        .width = rectangle.bounds.width - 2 * inset,
        .height = rectangle.bounds.height - 2 * inset,
    };
    const inner_radius = rectangle.corner_radius -| inset;
    for (top..bottom) |y| {
        for (left..right) |x| {
            const outer_coverage = roundedRectangleCoverage(rectangle.bounds, rectangle.corner_radius, x, y);
            if (outer_coverage == 0) continue;
            const inner_coverage = if (rectangle.border_color != null)
                roundedRectangleCoverage(inner, inner_radius, x, y)
            else
                255;
            const border_coverage = if (rectangle.border_color != null)
                multiply(outer_coverage, 255 - inner_coverage)
            else
                0;
            const background_coverage = if (rectangle.background != null)
                multiply(outer_coverage, inner_coverage)
            else
                0;
            const coverage = addSaturating(border_coverage, background_coverage);
            if (coverage == 0) continue;
            const source = addPixels(
                coveredColor(rectangle.border_color, border_coverage),
                coveredColor(rectangle.background, background_coverage),
            );
            blendCoveredPixel(target, x, y, source, coverage, rectangle.blend);
        }
    }
}

fn roundedRectangleCoverage(bounds: RectI, radius_value: u32, x: usize, y: usize) u8 {
    if (bounds.isEmpty()) return 0;
    const radius: f64 = @floatFromInt(@min(radius_value, @min(bounds.width, bounds.height) / 2));
    const px: f64 = @as(f64, @floatFromInt(x)) + 0.5;
    const py: f64 = @as(f64, @floatFromInt(y)) + 0.5;
    const left: f64 = @floatFromInt(bounds.x);
    const top: f64 = @floatFromInt(bounds.y);
    const right = left + @as(f64, @floatFromInt(bounds.width));
    const bottom = top + @as(f64, @floatFromInt(bounds.height));
    if (radius == 0) return if (px >= left and px < right and py >= top and py < bottom) 255 else 0;
    const half_width = (right - left) * 0.5;
    const half_height = (bottom - top) * 0.5;
    const dx = @abs(px - (left + right) * 0.5) - (half_width - radius);
    const dy = @abs(py - (top + bottom) * 0.5) - (half_height - radius);
    const outside = @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0));
    const distance = outside + @min(@max(dx, dy), 0) - radius;
    const coverage = std.math.clamp(0.5 - distance, 0, 1);
    return @intFromFloat(@floor(coverage * 255 + 0.5));
}

fn coveredColor(color: ?Color, coverage: u8) PremultipliedSrgba8 {
    const source = if (color) |value| value.premultiplied() else return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return .{
        .r = multiply(source.r, coverage),
        .g = multiply(source.g, coverage),
        .b = multiply(source.b, coverage),
        .a = multiply(source.a, coverage),
    };
}

fn addPixels(a: PremultipliedSrgba8, b: PremultipliedSrgba8) PremultipliedSrgba8 {
    return .{
        .r = addSaturating(a.r, b.r),
        .g = addSaturating(a.g, b.g),
        .b = addSaturating(a.b, b.b),
        .a = addSaturating(a.a, b.a),
    };
}

fn blendCoveredPixel(
    target: Target,
    x: usize,
    y: usize,
    source: PremultipliedSrgba8,
    coverage: u8,
    blend: scene.BlendMode,
) void {
    const offset = y * target.stride + x * 4;
    if (coverage == 255 and (blend == .source or source.a == 255)) {
        writePixel(target.format, target.pixels[offset..][0..4], source);
        return;
    }
    const destination = readPixel(target.format, target.pixels[offset..][0..4]);
    const result = if (blend == .source)
        addPixels(source, .{
            .r = multiply(destination.r, 255 - coverage),
            .g = multiply(destination.g, 255 - coverage),
            .b = multiply(destination.b, 255 - coverage),
            .a = multiply(destination.a, 255 - coverage),
        })
    else
        sourceOver(source, destination);
    writePixel(target.format, target.pixels[offset..][0..4], result);
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

test "fully covered draw is not executed" {
    var pixel = [_]u8{0} ** 4;
    const commands = [_]scene.Command{
        .{ .glyph_run = .{
            .shape = .{ .slot = 0, .generation = 1 },
            .origin = .{},
            .scale = 1,
            .color = Color.rgba(255, 255, 255, 255),
        } },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .color = Color.rgba(10, 20, 30, 255),
        } },
    };
    try render(.{ .commands = &commands }, .{
        .pixels = &pixel,
        .width = 1,
        .height = 1,
        .stride = 4,
        .format = .rgba8_unorm,
    });
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, &pixel);
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

test "HarfBuzz glyph runs rasterize deterministically through backend cache" {
    if (comptime !has_freetype) return error.SkipZigTest;
    const font_bytes = @embedFile("ourokit_test_font_static");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
        .bytes = font_bytes,
    });
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    const shape = try shapes.acquire(.{
        .spec = .{
            .paragraph = "Benchmark",
            .direction = .left_to_right,
            .script = .latin,
            .language = "en",
            .logical_size = 18,
        },
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    try fonts.release(font);
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts);
    defer glyphs.deinit();

    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(240, 240, 240, 255) },
        .{ .glyph_run = .{
            .shape = shape,
            .origin = .{ .x = 4, .y = 24 },
            .scale = 1,
            .color = Color.rgba(20, 40, 80, 255),
        } },
    };
    var first = [_]u8{0} ** (160 * 36 * 4);
    var second = [_]u8{0xaa} ** first.len;
    const target: Target = .{
        .pixels = &first,
        .width = 160,
        .height = 36,
        .stride = 160 * 4,
        .format = .rgba8_unorm,
    };
    try renderText(.{ .commands = &commands }, target, &glyphs, &shapes);
    var second_target = target;
    second_target.pixels = &second;
    try renderText(.{ .commands = &commands }, second_target, &glyphs, &shapes);
    try std.testing.expectEqualSlices(u8, &first, &second);
    var changed_pixels: usize = 0;
    for (0..first.len / 4) |index| {
        const pixel = first[index * 4 ..][0..4];
        try std.testing.expectEqual(@as(u8, 255), pixel[3]);
        if (!std.mem.eql(u8, pixel, &.{ 240, 240, 240, 255 })) changed_pixels += 1;
    }
    try std.testing.expect(changed_pixels > 200);
    try std.testing.expectError(
        error.TextResourcesRequired,
        render(.{ .commands = &commands }, target),
    );
    try std.testing.expectError(
        error.ResourceLeaseRequired,
        scene.Frame.init(std.testing.allocator, &commands, .full),
    );
    try shapes.release(shape);
}
