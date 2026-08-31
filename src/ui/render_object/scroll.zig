const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn layout(value: types.Scroll, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    if ((value.axis == .vertical and !constraints.hasBoundedHeight()) or
        (value.axis == .horizontal and !constraints.hasBoundedWidth()))
        return error.ScrollInUnboundedAxis;

    const child = try context.onlyChild(node);
    var content: SizeF = .{ .width = 0, .height = 0 };
    if (child) |handle| {
        var child_constraints = constraints.loosen();
        switch (value.axis) {
            .vertical => child_constraints.max_height = std.math.inf(f32),
            .horizontal => child_constraints.max_width = std.math.inf(f32),
        }
        content = try context.layoutChild(handle, child_constraints);
    }
    const viewport = constraints.constrain(content);
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
