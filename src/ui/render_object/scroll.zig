const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub const Metrics = struct {
    axis: types.Axis,
    offset: f32,
    viewport: f32,
    content: f32,
    max_offset: f32,
};

pub const Request = struct { offset: f32, token: u64 };
pub const gutter: f32 = 12;

pub fn contentViewport(value: types.Scroll, size: SizeF) SizeF {
    var result = size;
    if (value.scrollbar != null) switch (value.axis) {
        .vertical => result.width = @max(0, size.width - gutter),
        .horizontal => result.height = @max(0, size.height - gutter),
    };
    return result;
}

pub fn track(value: types.Scroll, size: SizeF) @import("../../core/geometry.zig").RectF {
    return switch (value.axis) {
        .vertical => .{ .x = @max(0, size.width - gutter), .y = 0, .width = @min(gutter, size.width), .height = size.height },
        .horizontal => .{ .x = 0, .y = @max(0, size.height - gutter), .width = size.width, .height = @min(gutter, size.height) },
    };
}

pub fn thumb(metrics: Metrics) struct { start: f32, length: f32 } {
    if (metrics.viewport == 0) return .{ .start = 0, .length = 0 };
    const length = @min(metrics.viewport, @max(24, metrics.viewport * (metrics.viewport / @max(metrics.viewport, metrics.content))));
    return .{ .start = if (metrics.max_offset > 0) (metrics.viewport - length) * (metrics.offset / metrics.max_offset) else 0, .length = length };
}

pub fn layout(value: types.Scroll, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    if ((value.axis == .vertical and !constraints.hasBoundedHeight()) or
        (value.axis == .horizontal and !constraints.hasBoundedWidth()))
        return error.ScrollInUnboundedAxis;

    const child = try context.onlyChild(node);
    var content: SizeF = .{ .width = 0, .height = 0 };
    if (child) |handle| {
        var child_constraints = constraints.loosen();
        const inner = contentViewport(value, .{ .width = child_constraints.max_width, .height = child_constraints.max_height });
        child_constraints.max_width = inner.width;
        child_constraints.max_height = inner.height;
        switch (value.axis) {
            .vertical => child_constraints.max_height = std.math.inf(f32),
            .horizontal => child_constraints.max_width = std.math.inf(f32),
        }
        content = try context.layoutChild(handle, child_constraints);
    }
    var desired = content;
    if (value.scrollbar != null) switch (value.axis) {
        .vertical => desired.width += gutter,
        .horizontal => desired.height += gutter,
    };
    const viewport = constraints.constrain(desired);
    try context.finishScrollLayout(node, viewport, content);
    return viewport;
}

pub fn childOffset(axis: types.Axis, offset: f32) PointF {
    return switch (axis) {
        .vertical => .{ .y = -offset },
        .horizontal => .{ .x = -offset },
    };
}

test "scroll child offset follows its physical axis" {
    try std.testing.expectEqual(PointF{ .y = -12 }, childOffset(.vertical, 12));
    try std.testing.expectEqual(PointF{ .x = -8 }, childOffset(.horizontal, 8));
}

test "scrollbar geometry covers empty short proportional and minimum thumbs" {
    const cases = [_]struct { viewport: f32, content: f32, offset: f32, start: f32, length: f32 }{
        .{ .viewport = 0, .content = 0, .offset = 0, .start = 0, .length = 0 },
        .{ .viewport = 17, .content = 900, .offset = 500, .start = 0, .length = 17 },
        .{ .viewport = 100, .content = 0, .offset = 0, .start = 0, .length = 100 },
        .{ .viewport = 100, .content = 80, .offset = 0, .start = 0, .length = 100 },
        .{ .viewport = 120, .content = 480, .offset = 120, .start = 30, .length = 30 },
        .{ .viewport = 80, .content = 320, .offset = 240, .start = 56, .length = 24 },
    };
    for (cases) |case| {
        const result = thumb(.{ .axis = .vertical, .offset = case.offset, .viewport = case.viewport, .content = case.content, .max_offset = @max(0, case.content - case.viewport) });
        try std.testing.expectEqual(case.start, result.start);
        try std.testing.expectEqual(case.length, result.length);
    }
}
