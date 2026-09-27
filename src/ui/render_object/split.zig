const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub const Resolution = struct {
    available: f32,
    first: f32,
    second: f32,
    divider: f32,
    min: f32,
    max: f32,
};

/// Resolves split-axis geometry. `min` and `max` are the effective first-pane
/// pixel limits, after proportional minimum shrinking when space is scarce.
pub fn resolve(value: types.Split, extent: f32) Resolution {
    const divider = @min(value.divider, @max(0, extent));
    const available = @max(0, extent - divider);
    const minimum_sum = value.min_first + value.min_second;
    const scale = if (minimum_sum > available and minimum_sum > 0) available / minimum_sum else 1;
    const minimum = value.min_first * scale;
    const maximum = available - value.min_second * scale;
    const first = std.math.clamp(value.position * available, minimum, maximum);
    return .{
        .available = available,
        .first = first,
        .second = available - first,
        .divider = divider,
        .min = minimum,
        .max = maximum,
    };
}

pub fn validate(value: types.Split) !void {
    if (!std.math.isFinite(value.position) or value.position < 0 or value.position > 1)
        return error.InvalidSplitPosition;
    if (!validNonnegative(value.min_first) or !validNonnegative(value.min_second))
        return error.InvalidSplitMinimum;
    if (!validNonnegative(value.divider)) return error.InvalidSplitDivider;
}

pub fn layout(value: types.Split, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    if (!constraints.hasBoundedWidth() or !constraints.hasBoundedHeight())
        return error.UnboundedSplitConstraints;
    const size: SizeF = .{ .width = constraints.max_width, .height = constraints.max_height };
    const extent = if (value.axis == .horizontal) size.width else size.height;
    const result = resolve(value, extent);

    const first = context.firstChild(node) orelse return error.SplitRequiresThreeChildren;
    const second = context.nextSibling(first) orelse return error.SplitRequiresThreeChildren;
    const divider = context.nextSibling(second) orelse return error.SplitRequiresThreeChildren;
    if (context.nextSibling(divider) != null) return error.SplitRequiresThreeChildren;

    const first_size: SizeF = if (value.axis == .horizontal)
        .{ .width = result.first, .height = size.height }
    else
        .{ .width = size.width, .height = result.first };
    const second_size: SizeF = if (value.axis == .horizontal)
        .{ .width = result.second, .height = size.height }
    else
        .{ .width = size.width, .height = result.second };
    const divider_size: SizeF = if (value.axis == .horizontal)
        .{ .width = result.divider, .height = size.height }
    else
        .{ .width = size.width, .height = result.divider };
    _ = try context.layoutChild(first, Constraints.tight(first_size));
    _ = try context.layoutChild(second, Constraints.tight(second_size));
    _ = try context.layoutChild(divider, Constraints.tight(divider_size));
    try context.setChildOffset(first, .{});
    try context.setChildOffset(second, axisOffset(value.axis, result.first + result.divider));
    try context.setChildOffset(divider, axisOffset(value.axis, result.first));
    return size;
}

fn axisOffset(axis: types.Axis, offset: f32) PointF {
    return if (axis == .horizontal) .{ .x = offset } else .{ .y = offset };
}

fn validNonnegative(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

test "resolve clamps asymmetric minima and proportionally shrinks them" {
    const normal = resolve(.{ .position = 0.1, .min_first = 30, .min_second = 10, .divider = 8 }, 108);
    try std.testing.expectEqual(@as(f32, 30), normal.first);
    try std.testing.expectEqual(@as(f32, 70), normal.second);
    try std.testing.expectEqual(@as(f32, 90), normal.max);

    const small = resolve(.{ .position = 1, .min_first = 60, .min_second = 20, .divider = 10 }, 50);
    try std.testing.expectEqual(@as(f32, 30), small.min);
    try std.testing.expectEqual(@as(f32, 30), small.max);
    try std.testing.expectEqual(@as(f32, 30), small.first);
    try std.testing.expectEqual(@as(f32, 10), small.second);
}
