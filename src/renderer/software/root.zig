const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const PremultipliedSrgba8 = @import("../../core/color.zig").PremultipliedSrgba8;
const LinearRgba16 = @import("../../core/color.zig").LinearRgba16;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");
const text = @import("../../text/root.zig");
const build_options = @import("ourokit_build_options");
const ImageCache = @import("../../image/cache.zig").Cache;
const ImagePlacement = @import("../image_sampling.zig").Placement;
const GlyphPosition = @import("../glyph_position.zig").Position;

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
    /// Allocates the RGBA16 working buffer for a render call. Presentation
    /// bytes retain their existing encoded-premultiplied sRGB representation.
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn validate(self: Target) !void {
        const row_bytes = std.math.mul(usize, self.width, 4) catch return error.InvalidTarget;
        if (self.stride < row_bytes) return error.InvalidTarget;
        const required = std.math.mul(usize, self.stride, self.height) catch return error.InvalidTarget;
        if (self.pixels.len < required) return error.InvalidTarget;
    }
};

const RasterTarget = struct {
    pixels: []LinearRgba16,
    width: u32,
    height: u32,
};

const max_clip_depth = scene.max_clip_depth;

pub fn render(list: scene.DisplayList, target: Target) !void {
    return renderResources(list, target, null, null, null, null);
}

pub fn renderText(
    list: scene.DisplayList,
    target: Target,
    glyphs: *GlyphCache,
    shapes: *const text.ShapeCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    return renderResources(list, target, glyphs, shapes, null, null);
}

pub fn renderParagraphs(
    list: scene.DisplayList,
    target: Target,
    glyphs: *GlyphCache,
    paragraphs: *const text.ParagraphCache,
) !void {
    return renderTextResources(list, target, glyphs, null, paragraphs);
}

/// Renders a display list containing either or both text command kinds.
pub fn renderTextResources(
    list: scene.DisplayList,
    target: Target,
    glyphs: *GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    return renderResources(list, target, glyphs, shapes, paragraphs, null);
}

pub fn renderResources(
    list: scene.DisplayList,
    target: Target,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: ?*const ImageCache,
) !void {
    try target.validate();
    try list.validate();
    // Resolve before touching the target, even for clipped or undamaged images.
    for (list.commands) |command| switch (command) {
        .image => |value| _ = try (images orelse return error.ImageResourcesRequired).get(value.image),
        else => {},
    };
    if (list.commands.len == 0 or target.width == 0 or target.height == 0) return;
    if (list.damage == .regions and list.damage.regions.len == 0) return;
    const pixels = try target.allocator.alloc(LinearRgba16, try std.math.mul(usize, target.width, target.height));
    defer target.allocator.free(pixels);
    const working: RasterTarget = .{ .pixels = pixels, .width = target.width, .height = target.height };
    switch (list.damage) {
        .full => try renderOutputRegion(list.commands, target, working, targetBounds(target), glyphs, shapes, paragraphs, images),
        .regions => |regions| {
            for (regions) |region| {
                const clipped = RectI.intersect(region, targetBounds(target));
                if (!clipped.isEmpty()) try renderOutputRegion(list.commands, target, working, clipped, glyphs, shapes, paragraphs, images);
            }
        },
    }
}

fn renderOutputRegion(
    commands: []const scene.Command,
    output: Target,
    working: RasterTarget,
    damage: RectI,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: ?*const ImageCache,
) !void {
    const left: usize = @intCast(damage.x);
    const top: usize = @intCast(damage.y);
    // A leading clear supplies every damaged pixel; never decode undefined
    // caller storage in the normal full-scene rendering path.
    if (commands[0] != .clear) {
        for (top..top + damage.height) |y| for (left..left + damage.width) |x| {
            const offset = y * output.stride + x * 4;
            working.pixels[y * working.width + x] = LinearRgba16.fromSrgba8(readPixel(output.format, output.pixels[offset..][0..4]));
        };
    }
    try renderRegion(commands, working, damage, glyphs, shapes, paragraphs, images);
    for (top..top + damage.height) |y| for (left..left + damage.width) |x| {
        const offset = y * output.stride + x * 4;
        writePixel(output.format, output.pixels[offset..][0..4], working.pixels[y * working.width + x].toSrgba8());
    };
}

fn renderRegion(
    commands: []const scene.Command,
    target: RasterTarget,
    damage: RectI,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: ?*const ImageCache,
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
        .image => |value| {
            const bitmap = try images.?.get(value.image);
            const bounds = RectI.intersect(value.bounds, clips[depth]);
            if (bounds.isEmpty()) continue;
            const placement = ImagePlacement.init(value, bitmap);
            const left: usize = @intCast(bounds.x);
            const top: usize = @intCast(bounds.y);
            for (top..top + bounds.height) |y| for (left..left + bounds.width) |x| {
                const source = placement.sample(bitmap, x, y) orelse continue;
                const offset = y * target.width + x;
                target.pixels[offset] = source.over(target.pixels[offset]);
            };
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
        .paragraph => |paragraph| {
            if (scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], clips[depth])) continue;
            if (!has_freetype) return error.FreeTypeDisabled;
            try drawParagraph(
                paragraph,
                target,
                clips[depth],
                glyphs orelse return error.TextResourcesRequired,
                paragraphs orelse return error.TextResourcesRequired,
            );
        },
    };
}

fn drawGlyphRun(
    command: scene.GlyphRun,
    target: RasterTarget,
    clip: RectI,
    cache: *GlyphCache,
    shapes: *const text.ShapeCache,
) !void {
    const shaped = try shapes.get(command.shape);
    var pen = command.origin;
    for (shaped.spans) |span| {
        for (span.run.glyphs) |glyph| {
            const position = GlyphPosition.init(pen.x + glyph.offset.x * command.scale, pen.y - glyph.offset.y * command.scale);
            const bitmap = try cache.getPhase(
                span.font,
                glyph.id,
                shaped.logical_size * command.scale,
                position.phase,
            );
            drawMask(
                target,
                clip,
                position.x + bitmap.left,
                position.y - bitmap.top,
                bitmap,
                command.color,
            );
            pen.x += glyph.advance.x * command.scale;
            pen.y -= glyph.advance.y * command.scale;
        }
    }
}

fn drawParagraph(
    command: scene.Paragraph,
    target: RasterTarget,
    clip: RectI,
    cache: *GlyphCache,
    paragraphs: *const text.ParagraphCache,
) !void {
    const layout = try paragraphs.get(command.layout);
    for (layout.positioned.lines) |line| {
        const baseline = command.origin.y + (line.top + line.baseline) * command.scale;
        for (layout.positioned.spansFor(line)) |span| {
            for (layout.positioned.glyphsFor(span)) |glyph| {
                const position = GlyphPosition.init(
                    command.origin.x + (line.left + glyph.origin.x) * command.scale,
                    baseline + glyph.origin.y * command.scale,
                );
                const bitmap = try cache.getPhase(
                    span.font,
                    glyph.id,
                    layout.logical_size * command.scale,
                    position.phase,
                );
                drawMask(
                    target,
                    clip,
                    position.x + bitmap.left,
                    position.y - bitmap.top,
                    bitmap,
                    command.color,
                );
            }
        }
    }
}

fn drawMask(
    target: RasterTarget,
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
    const source_color = LinearRgba16.fromColor(color);
    const source_x: usize = @intCast(bounds.x - x);
    const source_y: usize = @intCast(bounds.y - y);
    const width: usize = bounds.width;
    const height: usize = bounds.height;
    for (0..height) |row| {
        for (0..width) |column| {
            const coverage = bitmap.pixels[(source_y + row) * bitmap.width + source_x + column];
            if (coverage == 0) continue;
            const source = source_color.scaled(@as(u16, coverage) * 257);
            const destination_offset = (@as(usize, @intCast(bounds.y)) + row) * target.width +
                @as(usize, @intCast(bounds.x)) + column;
            target.pixels[destination_offset] = source.over(target.pixels[destination_offset]);
        }
    }
}

fn fill(target: RasterTarget, bounds: RectI, color: Color, blend: scene.BlendMode) void {
    if (bounds.isEmpty()) return;
    const source = LinearRgba16.fromColor(color);
    if (blend == .source or source.a == 65535) {
        fillSource(target, bounds, source);
        return;
    }
    const left: u32 = @intCast(bounds.x);
    const top: u32 = @intCast(bounds.y);
    const right: u32 = @intCast(@as(i64, bounds.x) + bounds.width);
    const bottom: u32 = @intCast(@as(i64, bounds.y) + bounds.height);
    for (top..bottom) |y| {
        for (left..right) |x| {
            const offset = y * target.width + x;
            target.pixels[offset] = source.over(target.pixels[offset]);
        }
    }
}

fn drawDecoratedRectangle(
    target: RasterTarget,
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
            const source = coveredColor(rectangle.border_color, border_coverage).plus(
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

fn coveredColor(color: ?Color, coverage: u8) LinearRgba16 {
    const source = if (color) |value| LinearRgba16.fromColor(value) else return LinearRgba16.transparent;
    return source.scaled(@as(u16, coverage) * 257);
}

fn blendCoveredPixel(
    target: RasterTarget,
    x: usize,
    y: usize,
    source: LinearRgba16,
    coverage: u8,
    blend: scene.BlendMode,
) void {
    const offset = y * target.width + x;
    if (coverage == 255 and (blend == .source or source.a == 65535)) {
        target.pixels[offset] = source;
        return;
    }
    const destination = target.pixels[offset];
    const result = if (blend == .source)
        source.plus(destination.scaled(@as(u16, 255 - coverage) * 257))
    else
        source.over(destination);
    target.pixels[offset] = result;
}

fn fillSource(target: RasterTarget, bounds: RectI, source: LinearRgba16) void {
    const left: usize = @intCast(bounds.x);
    const top: usize = @intCast(bounds.y);
    const right: usize = @intCast(@as(i64, bounds.x) + bounds.width);
    const bottom: usize = @intCast(@as(i64, bounds.y) + bounds.height);
    for (top..bottom) |y| {
        @memset(target.pixels[y * target.width + left .. y * target.width + right], source);
    }
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

fn targetBounds(target: anytype) RectI {
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
    try std.testing.expectEqualSlices(u8, &.{ 12, 27, 42, 255, 12, 27, 42, 255, 1, 2, 3, 255 }, pixels[14..26]);
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

test "glyph runs scale offsets and accumulate fractional advances before raster placement" {
    if (comptime !has_freetype) return error.SkipZigTest;
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(font) catch unreachable;
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    const shape = try shapes.acquire(.{
        .spec = .{ .paragraph = "Ri", .direction = .left_to_right, .script = .latin, .language = "en", .logical_size = 13.25 },
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    defer shapes.release(shape) catch unreachable;
    // Synthetic shaped metrics make each coordinate independently calculable.
    const run = (try shapes.get(shape)).spans[0].run;
    run.glyphs[0].offset = .{ .x = -0.5, .y = 0.25 };
    run.glyphs[0].advance = .{ .x = 6.25, .y = 0.5 };
    run.glyphs[1].offset = .{ .x = 0.75, .y = -0.375 };
    var cache = try GlyphCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    var actual = [_]LinearRgba16{LinearRgba16.fromColor(Color.rgba(255, 255, 255, 255))} ** (40 * 30);
    var expected = actual;
    const clip: RectI = .{ .x = 0, .y = 1, .width = 39, .height = 28 };
    const color = Color.rgba(19, 47, 83, 211);
    try drawGlyphRun(.{ .shape = shape, .origin = .{ .x = -2.25, .y = 20.125 }, .scale = 1.5, .color = color }, .{ .pixels = &actual, .width = 40, .height = 30 }, clip, &cache, &shapes);
    // Expected origins: (-3, 19.75), (8.25, 19.9375), size 19.875.
    const first = try cache.getPhase(font, run.glyphs[0].id, 19.875, .{ .x = 0, .y = 48 });
    drawMask(.{ .pixels = &expected, .width = 40, .height = 30 }, clip, -3 + first.left, 19 - first.top, first, color);
    const second = try cache.getPhase(font, run.glyphs[1].id, 19.875, .{ .x = 16, .y = 60 });
    drawMask(.{ .pixels = &expected, .width = 40, .height = 30 }, clip, 8 + second.left, 19 - second.top, second, color);
    try std.testing.expectEqualSlices(LinearRgba16, &expected, &actual);
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

test "positioned mixed-script paragraphs rasterize through leased scene resources" {
    if (comptime !has_freetype) return error.SkipZigTest;
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const latin = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const layout = try paragraphs.acquire(.{
        .utf8 = "Save حفظ now and continue",
        .language = "und",
        .logical_size = 18,
        .max_width = 120,
        .candidates = &.{ latin, arabic },
        .configuration_revision = 1,
    });
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts);
    defer glyphs.deinit();
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(240, 240, 240, 255) },
        .{ .paragraph = .{
            .layout = layout,
            .origin = .{ .x = 4, .y = 4 },
            .scale = 1,
            .color = Color.rgba(20, 40, 80, 255),
        } },
    };
    {
        var frame = try scene.Frame.initWithResources(
            std.testing.allocator,
            &commands,
            .full,
            .{ .paragraphs = &paragraphs },
        );
        defer frame.deinit();
        try paragraphs.release(layout);
        try fonts.release(latin);
        try fonts.release(arabic);

        var first = [_]u8{0} ** (160 * 80 * 4);
        var second = [_]u8{0xaa} ** first.len;
        const target: Target = .{
            .pixels = &first,
            .width = 160,
            .height = 80,
            .stride = 160 * 4,
            .format = .rgba8_unorm,
        };
        try renderParagraphs(frame.displayList(), target, &glyphs, &paragraphs);
        var second_target = target;
        second_target.pixels = &second;
        try renderParagraphs(frame.displayList(), second_target, &glyphs, &paragraphs);
        try std.testing.expectEqualSlices(u8, &first, &second);
        var changed_pixels: usize = 0;
        for (0..first.len / 4) |index| {
            const pixel = first[index * 4 ..][0..4];
            if (!std.mem.eql(u8, pixel, &.{ 240, 240, 240, 255 })) changed_pixels += 1;
        }
        try std.testing.expect(changed_pixels > 300);
    }
    try std.testing.expectError(error.StaleParagraph, paragraphs.get(layout));
    // The backend glyph cache independently leases rasterized faces.
    _ = try fonts.get(latin);
    _ = try fonts.get(arabic);
}

test "repeated faint blends retain linear precision until presentation" {
    var commands: [101]scene.Command = undefined;
    commands[0] = .{ .clear = Color.rgba(255, 255, 255, 255) };
    for (commands[1..]) |*command| command.* = .{ .solid_rectangle = .{
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = Color.rgba(0, 0, 0, 1),
    } };
    var pixel: [4]u8 = undefined;
    try render(.{ .commands = &commands }, .{ .pixels = &pixel, .width = 1, .height = 1, .stride = 4, .format = .rgba8_unorm, .allocator = std.testing.allocator });
    // Encode((254/255)^100) = 214.372, unlike per-draw 8-bit encoding.
    try std.testing.expectEqualSlices(u8, &.{ 214, 214, 214, 255 }, &pixel);
}

test "glyph masks are linear coverage in both polarities and transparent output" {
    if (comptime !has_freetype) return error.SkipZigTest;
    var mask_pixels = [_]u8{128};
    const mask: GlyphBitmap = .{ .pixels = &mask_pixels, .width = 1, .height = 1, .left = 0, .top = 0 };
    var pixels: [1]LinearRgba16 = undefined;
    const target: RasterTarget = .{ .pixels = &pixels, .width = 1, .height = 1 };
    const bounds: RectI = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    const black = Color.rgba(0, 0, 0, 255);
    const white = Color.rgba(255, 255, 255, 255);
    for ([_]Color{ black, white }) |background| {
        pixels[0] = LinearRgba16.fromColor(background);
        drawMask(target, bounds, 0, 0, &mask, if (background.r == 0) white else black);
        // A8 coverage is not sRGB-decoded: both polarities are near 188,
        // not 128 (encoded blending) or 229 (decoded black coverage).
        const expected: u8 = if (background.r == 0) 188 else 187;
        try std.testing.expectEqual(PremultipliedSrgba8{ .r = expected, .g = expected, .b = expected, .a = 255 }, pixels[0].toSrgba8());
    }
    pixels[0] = LinearRgba16.transparent;
    drawMask(target, bounds, 0, 0, &mask, white);
    try std.testing.expectEqual(PremultipliedSrgba8{ .r = 128, .g = 128, .b = 128, .a = 128 }, pixels[0].toSrgba8());

    // Masked source replacement retains (1-coverage), not (1-source alpha).
    pixels[0] = LinearRgba16.fromColor(white);
    blendCoveredPixel(target, 0, 0, .transparent, 128, .source);
    try std.testing.expectEqual(PremultipliedSrgba8{ .r = 127, .g = 127, .b = 127, .a = 127 }, pixels[0].toSrgba8());
}
