const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const PointF = @import("../../core/geometry.zig").PointF;
const RectF = @import("../../core/geometry.zig").RectF;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");
const ParagraphHandle = @import("../../text/paragraph_cache.zig").ParagraphHandle;
const ShapeHandle = @import("../../text/shape_cache.zig").ShapeHandle;
const ImageHandle = @import("../../image/cache.zig").ImageHandle;
const ImageFit = @import("../../image/pixels.zig").Fit;

/// Allocation-free lowering from logical layout coordinates to the existing
/// renderer-neutral device-space display list. Coverage bounds round outward;
/// decorated shapes snap their origin and extent separately to avoid distortion.
pub const Builder = struct {
    storage: []scene.Command,
    count: usize = 0,
    scale: f32,

    pub fn init(storage: []scene.Command, scale: f32) !Builder {
        if (storage.len == 0 or !std.math.isFinite(scale) or scale <= 0)
            return error.InvalidSceneBuilder;
        return .{ .storage = storage, .scale = scale };
    }

    pub fn clear(self: *Builder, color: Color) !void {
        try self.append(.{ .clear = color });
    }

    pub fn solidRectangle(self: *Builder, bounds: RectF, color: Color) !void {
        const device = try self.deviceRect(bounds, .outward);
        if (!device.isEmpty()) try self.append(.{ .solid_rectangle = .{ .bounds = device, .color = color } });
    }

    pub fn image(self: *Builder, handle: ImageHandle, bounds: RectF, fit: ImageFit) !void {
        const device = try self.deviceRect(bounds, .outward);
        if (!device.isEmpty()) try self.append(.{ .image = .{ .image = handle, .bounds = device, .fit = fit } });
    }

    pub fn path(self: *Builder, value: *const @import("../../path/root.zig").Path, origin: PointF, color: Color) !void {
        const device: PointF = .{ .x = origin.x * self.scale, .y = origin.y * self.scale };
        const bounds = try @import("../../path/root.zig").deviceBounds(value, device, self.scale);
        if (!bounds.isEmpty()) try self.append(.{ .path = .{
            .path = value,
            .identity = value.identity,
            .origin = device,
            .scale = self.scale,
            .bounds = bounds,
            .color = color,
        } });
    }

    pub fn boxShadow(self: *Builder, bounds: RectF, radius: f32, style: @import("../../shadow/root.zig").Style) !void {
        try style.validate();
        const device = try self.deviceRect(bounds, .preserve_size);
        if (device.isEmpty() or style.color.a == 0) return;
        const shape: @import("../../shadow/root.zig").Shape = .{
            .box = device,
            .corner_radius = @min(try self.deviceExtent(radius), @min(device.width, device.height) / 2),
            .offset = .{ .x = style.offset.x * self.scale, .y = style.offset.y * self.scale },
            .blur = style.blur * self.scale,
            .spread = style.spread * self.scale,
        };
        const painted = try @import("../../shadow/root.zig").deviceBounds(shape);
        if (!painted.isEmpty()) try self.append(.{ .shadow = .{ .shape = shape, .bounds = painted, .color = style.color } });
    }

    pub fn decoratedRectangle(
        self: *Builder,
        bounds: RectF,
        background: ?Color,
        border_color: ?Color,
        border_width: f32,
        corner_radius: f32,
    ) !void {
        const device = try self.deviceRect(bounds, .preserve_size);
        if (device.isEmpty()) return;
        const maximum = @min(device.width, device.height) / 2;
        try self.append(.{ .decorated_rectangle = .{
            .bounds = device,
            .background = background,
            .border_color = border_color,
            .border_width = @min(try self.deviceExtent(border_width), maximum),
            .corner_radius = @min(try self.deviceExtent(corner_radius), maximum),
        } });
    }

    pub fn pushClip(self: *Builder, bounds: RectF) !void {
        try self.append(.{ .push_clip_rect = try self.deviceRect(bounds, .outward) });
    }

    pub fn popClip(self: *Builder) !void {
        try self.append(.pop_clip);
    }

    pub fn glyphRun(
        self: *Builder,
        shape: ShapeHandle,
        baseline: PointF,
        color: Color,
    ) !void {
        try self.append(.{ .glyph_run = .{
            .shape = shape,
            .origin = .{ .x = baseline.x * self.scale, .y = baseline.y * self.scale },
            .scale = self.scale,
            .color = color,
        } });
    }

    pub fn paragraph(
        self: *Builder,
        layout: ParagraphHandle,
        origin: PointF,
        color: Color,
    ) !void {
        try self.append(.{ .paragraph = .{
            .layout = layout,
            .origin = .{ .x = origin.x * self.scale, .y = origin.y * self.scale },
            .scale = self.scale,
            .color = color,
        } });
    }

    pub fn displayList(self: *const Builder) scene.DisplayList {
        return .{ .commands = self.storage[0..self.count] };
    }

    fn append(self: *Builder, command: scene.Command) !void {
        if (self.count == self.storage.len) return error.SceneCapacityExceeded;
        self.storage[self.count] = command;
        self.count += 1;
    }

    fn deviceRect(self: *const Builder, bounds: RectF, rounding: enum { outward, preserve_size }) !RectI {
        if (!validRect(bounds)) return error.InvalidLogicalRectangle;
        const left = if (rounding == .outward) @floor(bounds.x * self.scale) else @round(bounds.x * self.scale);
        const top = if (rounding == .outward) @floor(bounds.y * self.scale) else @round(bounds.y * self.scale);
        const right = if (rounding == .outward) @ceil((bounds.x + bounds.width) * self.scale) else left + @ceil(bounds.width * self.scale);
        const bottom = if (rounding == .outward) @ceil((bounds.y + bounds.height) * self.scale) else top + @ceil(bounds.height * self.scale);
        const left64: f64 = left;
        const top64: f64 = top;
        const right64: f64 = right;
        const bottom64: f64 = bottom;
        if (left64 < @as(f64, @floatFromInt(std.math.minInt(i32))) or
            top64 < @as(f64, @floatFromInt(std.math.minInt(i32))) or
            right64 > @as(f64, @floatFromInt(std.math.maxInt(i32))) or
            bottom64 > @as(f64, @floatFromInt(std.math.maxInt(i32))))
            return error.DeviceRectangleOverflow;
        return .{
            .x = @intFromFloat(left64),
            .y = @intFromFloat(top64),
            .width = if (bounds.width == 0) 0 else @intFromFloat(@max(0, right64 - left64)),
            .height = if (bounds.height == 0) 0 else @intFromFloat(@max(0, bottom64 - top64)),
        };
    }

    fn deviceExtent(self: *const Builder, value: f32) !u32 {
        if (value == 0) return 0;
        const scaled = @ceil(@as(f64, value) * self.scale);
        if (!std.math.isFinite(scaled) or scaled > @as(f64, @floatFromInt(std.math.maxInt(u32))))
            return error.DeviceExtentOverflow;
        return @intFromFloat(scaled);
    }
};

fn validRect(rect: RectF) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and
        std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and
        rect.width >= 0 and rect.height >= 0;
}

test "scene lowering scales logical rectangles conservatively" {
    var commands: [2]scene.Command = undefined;
    var builder = try Builder.init(&commands, 2);
    try builder.solidRectangle(
        .{ .x = 1.25, .y = 2.5, .width = 3.5, .height = 4.25 },
        Color.rgba(1, 2, 3, 255),
    );
    try std.testing.expectEqual(
        RectI{ .x = 2, .y = 5, .width = 8, .height = 9 },
        builder.displayList().commands[0].solid_rectangle.bounds,
    );

    try builder.decoratedRectangle(
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        Color.rgba(4, 5, 6, 255),
        Color.rgba(7, 8, 9, 255),
        0.5,
        2.25,
    );
    const decorated = builder.displayList().commands[1].decorated_rectangle;
    try std.testing.expectEqual(@as(u32, 1), decorated.border_width);
    try std.testing.expectEqual(@as(u32, 5), decorated.corner_radius);
}

test "decorated shapes retain dimensions at fractional origins and scales" {
    const cases = [_]struct { scale: f32, expected: RectI }{
        .{ .scale = 1, .expected = .{ .x = 3, .y = -1, .width = 12, .height = 12 } },
        .{ .scale = 1.25, .expected = .{ .x = 4, .y = -2, .width = 15, .height = 15 } },
        .{ .scale = 2, .expected = .{ .x = 6, .y = -3, .width = 24, .height = 24 } },
    };
    for (cases) |case| {
        var commands: [1]scene.Command = undefined;
        var builder = try Builder.init(&commands, case.scale);
        try builder.decoratedRectangle(
            .{ .x = 3, .y = -1.25, .width = 12, .height = 12 },
            Color.rgba(20, 40, 180, 255),
            null,
            0,
            6,
        );
        try std.testing.expectEqual(case.expected, commands[0].decorated_rectangle.bounds);
    }
    var commands: [1]scene.Command = undefined;
    var builder = try Builder.init(&commands, 1);
    try builder.decoratedRectangle(
        .{ .x = 0.75, .y = 2.25, .width = 10, .height = 4 },
        null,
        Color.rgba(20, 40, 180, 255),
        1,
        2,
    );
    try std.testing.expectEqual(RectI{ .x = 1, .y = 2, .width = 10, .height = 4 }, commands[0].decorated_rectangle.bounds);
}

test "shadow lowering scales style and matches snapped rounded decoration" {
    var commands: [2]scene.Command = undefined;
    var builder = try Builder.init(&commands, 1.5);
    const bounds: RectF = .{ .x = -1.25, .y = 3.5, .width = 17, .height = 9 };
    try builder.boxShadow(bounds, 2.5, .{ .offset = .{ .x = -2.25, .y = 4.5 }, .blur = 6, .spread = -1, .color = Color.rgba(20, 30, 40, 128) });
    try builder.decoratedRectangle(bounds, Color.rgba(10, 20, 30, 255), null, 0, 2.5);
    const shape = commands[0].shadow.shape;
    try std.testing.expectEqual(RectI{ .x = -2, .y = 5, .width = 26, .height = 14 }, shape.box);
    try std.testing.expectEqual(shape.box, commands[1].decorated_rectangle.bounds);
    try std.testing.expectEqual(@as(u32, 4), shape.corner_radius);
    try std.testing.expectEqual(shape.corner_radius, commands[1].decorated_rectangle.corner_radius);
    try std.testing.expectEqual(PointF{ .x = -3.375, .y = 6.75 }, shape.offset);
    try std.testing.expectEqual(@as(f32, 9), shape.blur);
    try std.testing.expectEqual(@as(f32, -1.5), shape.spread);
    try builder.displayList().validate();
    builder.count = 0;
    try builder.boxShadow(bounds, 0, .{ .color = Color.rgba(0, 0, 0, 0) });
    try std.testing.expectEqual(@as(usize, 0), builder.count);
    try std.testing.expectError(error.BlurTooLarge, builder.boxShadow(bounds, 0, .{ .blur = 86, .color = Color.rgba(0, 0, 0, 255) }));
}

test "device rectangles preserve exact empty dimensions" {
    var commands: [1]scene.Command = undefined;
    const builder = try Builder.init(&commands, 1.5);

    try std.testing.expectEqual(
        RectI{ .x = 0, .y = 0, .width = 0, .height = 4 },
        try builder.deviceRect(.{ .x = 0.25, .y = 0.5, .width = 0, .height = 2 }, .outward),
    );
    try std.testing.expectEqual(
        RectI{ .x = 1, .y = 0, .width = 2, .height = 0 },
        try builder.deviceRect(.{ .x = 1.25, .y = 0.25, .width = 0.5, .height = 0 }, .outward),
    );
    try std.testing.expectEqual(
        RectI{ .x = -1, .y = -2, .width = 0, .height = 0 },
        try builder.deviceRect(.{ .x = -0.25, .y = -1.25, .width = 0, .height = 0 }, .outward),
    );
}

test "device rectangles conservatively retain positive subpixel extents" {
    var commands: [1]scene.Command = undefined;
    const builder = try Builder.init(&commands, 1.5);

    try std.testing.expectEqual(
        RectI{ .x = 0, .y = 1, .width = 1, .height = 1 },
        try builder.deviceRect(.{ .x = 0.25, .y = 1.25, .width = 0.01, .height = 0.01 }, .outward),
    );
}

test "empty logical clips remain empty at fractional origins" {
    var commands: [1]scene.Command = undefined;
    var builder = try Builder.init(&commands, 1.5);

    try builder.pushClip(.{ .x = 0.25, .y = 1.25, .width = 0, .height = 3 });

    const clip = builder.displayList().commands[0].push_clip_rect;
    try std.testing.expect(clip.isEmpty());
    try std.testing.expectEqual(RectI{ .x = 0, .y = 1, .width = 0, .height = 6 }, clip);
}
