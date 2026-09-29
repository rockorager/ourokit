const std = @import("std");
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn layout(value: types.Stack, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    var desired: SizeF = .{ .width = 0, .height = 0 };
    var child_constraints = constraints.loosen();
    if (value.unbounded_height) child_constraints.max_height = std.math.inf(f32);
    var has_normal = false;
    var has_positioned = false;
    var child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const data = try context.parentData(handle);
        if (data == .positioned) {
            has_positioned = true;
            continue;
        }
        has_normal = true;
        const position = try stackData(data);
        const child_size = try context.layoutChild(handle, child_constraints);
        try context.setChildOffset(handle, position);
        desired.width = @max(desired.width, position.x + child_size.width);
        desired.height = @max(desired.height, position.y + child_size.height);
    }
    if (!has_normal and has_positioned) {
        if (!constraints.hasBoundedWidth() or !constraints.hasBoundedHeight())
            return error.PositionedStackInUnboundedAxis;
        desired = .{ .width = constraints.max_width, .height = constraints.max_height };
    }
    const size = constraints.constrain(desired);
    child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const data = try context.parentData(handle);
        if (data != .positioned) continue;
        const p = data.positioned;
        const width = if (p.left != null and p.right != null) @max(0, size.width - p.left.? - p.right.?) else p.width;
        const height = if (p.top != null and p.bottom != null) @max(0, size.height - p.top.? - p.bottom.?) else p.height;
        const child_size = try context.layoutChild(handle, .{
            .min_width = width orelse 0,
            .max_width = width orelse std.math.inf(f32),
            .min_height = height orelse 0,
            .max_height = height orelse std.math.inf(f32),
        });
        try context.setChildOffset(handle, .{
            .x = p.left orelse if (p.right) |right| size.width - right - child_size.width else 0,
            .y = p.top orelse if (p.bottom) |bottom| size.height - bottom - child_size.height else 0,
        });
    }
    return size;
}

fn stackData(data: types.ParentData) !@import("../../core/geometry.zig").PointF {
    return switch (data) {
        .none => .{},
        .stack => |value| .{ .x = value.x, .y = value.y },
        else => error.InvalidParentData,
    };
}
