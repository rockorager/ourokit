const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const PointF = @import("../../core/geometry.zig").PointF;
const RectF = @import("../../core/geometry.zig").RectF;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");
const ParagraphHandle = @import("../../text/paragraph_cache.zig").ParagraphHandle;
const ShapeHandle = @import("../../text/shape_cache.zig").ShapeHandle;

/// Allocation-free lowering from logical layout coordinates to the existing
/// renderer-neutral device-space display list. Conservative edge rounding is
/// explicit until subpixel coverage semantics are implemented in both peers.
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
        const device = try self.deviceRect(bounds);
        if (!device.isEmpty()) try self.append(.{ .solid_rectangle = .{ .bounds = device, .color = color } });
    }

    pub fn decoratedRectangle(
        self: *Builder,
        bounds: RectF,
        background: ?Color,
        border_color: ?Color,
        border_width: f32,
        corner_radius: f32,
    ) !void {
        const device = try self.deviceRect(bounds);
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
        try self.append(.{ .push_clip_rect = try self.deviceRect(bounds) });
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

    fn deviceRect(self: *const Builder, bounds: RectF) !RectI {
        if (!validRect(bounds)) return error.InvalidLogicalRectangle;
        const left = @floor(bounds.x * self.scale);
        const top = @floor(bounds.y * self.scale);
        const right = @ceil((bounds.x + bounds.width) * self.scale);
        const bottom = @ceil((bounds.y + bounds.height) * self.scale);
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
            .width = @intFromFloat(@max(0, right64 - left64)),
            .height = @intFromFloat(@max(0, bottom64 - top64)),
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
