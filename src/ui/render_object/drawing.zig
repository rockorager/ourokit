const std = @import("std");
const geometry = @import("../../core/geometry.zig");
const Color = @import("../../core/color.zig").Color;
const Builder = @import("scene_builder.zig").Builder;

pub const Rectangle = struct {
    bounds: geometry.RectF,
    color: Color,
    corner_radius: f32 = 0,
};

/// Host-owned, immutable logical-coordinate paint snapshot. Leases belong to
/// Lua, prepared builds, and render trees on the event thread. Frames receive
/// value-only scene commands, never this object or a plugin callback.
pub const Drawing = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    size: geometry.SizeF,
    rectangles: []const Rectangle,

    pub const max_rectangles = 4096;

    pub fn create(allocator: std.mem.Allocator, size: geometry.SizeF, rectangles: []const Rectangle) !*Drawing {
        if (!std.math.isFinite(size.width) or !std.math.isFinite(size.height) or
            size.width < 0 or size.height < 0) return error.InvalidDrawingSize;
        if (rectangles.len > max_rectangles) return error.DrawingCapacityExceeded;
        for (rectangles) |rectangle| {
            const bounds = rectangle.bounds;
            if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or
                !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or
                !std.math.isFinite(bounds.x + bounds.width) or !std.math.isFinite(bounds.y + bounds.height) or
                bounds.width < 0 or bounds.height < 0 or
                !std.math.isFinite(rectangle.corner_radius) or rectangle.corner_radius < 0)
                return error.InvalidDrawingRectangle;
        }
        const copy = try allocator.dupe(Rectangle, rectangles);
        errdefer allocator.free(copy);
        const self = try allocator.create(Drawing);
        self.* = .{ .allocator = allocator, .size = size, .rectangles = copy };
        return self;
    }

    pub fn retain(self: *Drawing) void {
        self.references += 1;
    }

    pub fn release(self: *Drawing) void {
        self.references -= 1;
        if (self.references != 0) return;
        const allocator = self.allocator;
        allocator.free(self.rectangles);
        allocator.destroy(self);
    }

    /// Coordinates remain logical pixels: constraints crop rather than stretch
    /// the recording. A failed emission rolls back the entire drawing.
    pub fn paint(self: *const Drawing, builder: *Builder, bounds: geometry.RectF) !void {
        const start = builder.count;
        errdefer builder.count = start;
        try builder.pushClip(bounds);
        for (self.rectangles) |rectangle| {
            const local = rectangle.bounds;
            const positioned: geometry.RectF = .{
                .x = bounds.x + local.x,
                .y = bounds.y + local.y,
                .width = local.width,
                .height = local.height,
            };
            if (rectangle.corner_radius == 0)
                try builder.solidRectangle(positioned, rectangle.color)
            else
                try builder.decoratedRectangle(positioned, rectangle.color, null, 0, rectangle.corner_radius);
        }
        try builder.popClip();
    }
};

test "drawing copies rectangles and emits translated scaled clipped scene values atomically" {
    const scene = @import("../../scene/root.zig");
    var rectangles = [_]Rectangle{
        .{ .bounds = .{ .x = -2.25, .y = 3.5, .width = 17, .height = 4.25 }, .color = Color.rgba(7, 31, 127, 191) },
        .{ .bounds = .{ .x = 2, .y = 1, .width = 9, .height = 6 }, .color = Color.rgba(61, 190, 160, 255), .corner_radius = 1.25 },
    };
    const value = try Drawing.create(std.testing.allocator, .{ .width = 20, .height = 10 }, &rectangles);
    defer value.release();
    rectangles[0].color = Color.rgba(0, 0, 0, 0);
    var storage: [5]scene.Command = undefined;
    var builder = try Builder.init(&storage, 2);
    try builder.clear(Color.rgba(255, 255, 255, 255));
    const bounds: geometry.RectF = .{ .x = 10.25, .y = 20.5, .width = 13, .height = 8 };
    try value.paint(&builder, bounds);
    try builder.displayList().validate();
    try std.testing.expectEqual(geometry.RectI{ .x = 20, .y = 41, .width = 27, .height = 16 }, storage[1].push_clip_rect);
    try std.testing.expectEqual(geometry.RectI{ .x = 16, .y = 48, .width = 34, .height = 9 }, storage[2].solid_rectangle.bounds);
    try std.testing.expectEqual(Color.rgba(7, 31, 127, 191), storage[2].solid_rectangle.color);
    try std.testing.expectEqual(@as(u32, 3), storage[3].decorated_rectangle.corner_radius);
    try std.testing.expect(storage[4] == .pop_clip);

    // Enough room for the drawings, but not the closing clip: no partial batch.
    builder.storage = storage[0..4];
    builder.count = 1;
    try std.testing.expectError(error.SceneCapacityExceeded, value.paint(&builder, bounds));
    try std.testing.expectEqual(@as(usize, 1), builder.count);
    try builder.displayList().validate();
}

test "drawing rejects invalid geometry and unwinds allocation failures" {
    const size: geometry.SizeF = .{ .width = 17, .height = 9 };
    const good: Rectangle = .{ .bounds = .{ .x = -3, .y = 2, .width = 8, .height = 4 }, .color = Color.rgba(1, 2, 3, 4) };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseDrawingAllocation, .{ size, &[_]Rectangle{good} });
    try std.testing.expectError(error.InvalidDrawingSize, Drawing.create(std.testing.allocator, .{ .width = std.math.nan(f32), .height = 1 }, &.{}));
    try std.testing.expectError(error.InvalidDrawingSize, Drawing.create(std.testing.allocator, .{ .width = 1, .height = -1 }, &.{}));
    var invalid = good;
    invalid.bounds.width = -1;
    try std.testing.expectError(error.InvalidDrawingRectangle, Drawing.create(std.testing.allocator, size, &.{invalid}));
    invalid = good;
    invalid.bounds.x = std.math.inf(f32);
    try std.testing.expectError(error.InvalidDrawingRectangle, Drawing.create(std.testing.allocator, size, &.{invalid}));
    invalid = good;
    invalid.corner_radius = std.math.nan(f32);
    try std.testing.expectError(error.InvalidDrawingRectangle, Drawing.create(std.testing.allocator, size, &.{invalid}));
    const too_many = [_]Rectangle{good} ** (Drawing.max_rectangles + 1);
    try std.testing.expectError(error.DrawingCapacityExceeded, Drawing.create(std.testing.allocator, size, &too_many));
    const maximum = try Drawing.create(std.testing.allocator, size, too_many[0..Drawing.max_rectangles]);
    maximum.release();
}

fn exerciseDrawingAllocation(allocator: std.mem.Allocator, size: geometry.SizeF, rectangles: []const Rectangle) !void {
    const value = try Drawing.create(allocator, size, rectangles);
    value.release();
}
