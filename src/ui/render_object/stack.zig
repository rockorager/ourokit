const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn layout(_: types.Stack, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    var desired: SizeF = .{ .width = 0, .height = 0 };
    var child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const position = try stackData(try context.parentData(handle));
        const child_size = try context.layoutChild(handle, constraints.loosen());
        try context.setChildOffset(handle, position);
        desired.width = @max(desired.width, position.x + child_size.width);
        desired.height = @max(desired.height, position.y + child_size.height);
    }
    return constraints.constrain(desired);
}

fn stackData(data: types.ParentData) !@import("../../core/geometry.zig").PointF {
    return switch (data) {
        .none => .{},
        .stack => |value| .{ .x = value.x, .y = value.y },
        .flex => error.InvalidParentData,
    };
}
