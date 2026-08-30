const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn validate(value: types.Box) !void {
    if (value.width) |width| if (!validExtent(width)) return error.InvalidExtent;
    if (value.height) |height| if (!validExtent(height)) return error.InvalidExtent;
    if (!validExtent(value.padding.left) or !validExtent(value.padding.top) or
        !validExtent(value.padding.right) or !validExtent(value.padding.bottom))
        return error.InvalidInsets;
}

pub fn layout(value: types.Box, context: anytype, node: anytype, incoming: Constraints) !SizeF {
    var constraints = incoming;
    if (value.width) |width| {
        const resolved = std.math.clamp(width, constraints.min_width, constraints.max_width);
        constraints.min_width = resolved;
        constraints.max_width = resolved;
    }
    if (value.height) |height| {
        const resolved = std.math.clamp(height, constraints.min_height, constraints.max_height);
        constraints.min_height = resolved;
        constraints.max_height = resolved;
    }

    const child = try context.onlyChild(node);
    var content: SizeF = .{ .width = 0, .height = 0 };
    if (child) |handle| {
        content = try context.layoutChild(handle, constraints.deflate(value.padding));
        try context.setChildOffset(handle, .{ .x = value.padding.left, .y = value.padding.top });
    }
    return constraints.constrain(.{
        .width = content.width + value.padding.horizontal(),
        .height = content.height + value.padding.vertical(),
    });
}

fn validExtent(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

test "box module remains a typed layout implementation" {
    try validate(.{ .width = 20, .padding = .all(4) });
    try std.testing.expectError(error.InvalidExtent, validate(.{ .height = -1 }));
}
