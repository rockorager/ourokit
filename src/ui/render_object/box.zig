const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn validate(value: types.Box) !void {
    if (value.width) |width| if (!validExtent(width)) return error.InvalidExtent;
    if (value.height) |height| if (!validExtent(height)) return error.InvalidExtent;
    if (!validExtent(value.border_width) or !validExtent(value.corner_radius))
        return error.InvalidExtent;
    if ((value.border_width == 0) != (value.border_color == null))
        return error.InvalidBorder;
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

    const content_insets = @import("../../core/geometry.zig").Insets{
        .left = value.padding.left + value.border_width,
        .top = value.padding.top + value.border_width,
        .right = value.padding.right + value.border_width,
        .bottom = value.padding.bottom + value.border_width,
    };
    const child = try context.onlyChild(node);
    var content: SizeF = .{ .width = 0, .height = 0 };
    if (child) |handle| {
        content = try context.layoutChild(handle, constraints.deflate(content_insets));
        try context.setChildOffset(handle, .{ .x = content_insets.left, .y = content_insets.top });
    }
    return constraints.constrain(.{
        .width = content.width + content_insets.horizontal(),
        .height = content.height + content_insets.vertical(),
    });
}

fn validExtent(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

test "box module remains a typed layout implementation" {
    const Color = @import("../../core/color.zig").Color;
    try validate(.{
        .width = 20,
        .padding = .all(4),
        .border_color = Color.rgba(1, 2, 3, 255),
        .border_width = 1,
        .corner_radius = 4,
    });
    try std.testing.expectError(error.InvalidExtent, validate(.{ .height = -1 }));
    try std.testing.expectError(error.InvalidBorder, validate(.{ .border_width = 1 }));
}
