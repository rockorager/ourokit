const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn validate(value: types.Flex) !void {
    if (!std.math.isFinite(value.gap) or value.gap < 0) return error.InvalidGap;
}

pub fn layout(value: types.Flex, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    const child_count = context.childCount(node);
    const total_gap = if (child_count > 1) value.gap * @as(f32, @floatFromInt(child_count - 1)) else 0;
    var occupied_main = total_gap;
    var cross_extent: f32 = 0;
    var total_flex: u64 = 0;

    var child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const data = try flexData(try context.parentData(handle));
        if (data.factor != 0) {
            total_flex += data.factor;
            continue;
        }
        const size = try context.layoutChild(handle, nonFlexConstraints(value, constraints));
        occupied_main += mainExtent(value.axis, size);
        cross_extent = @max(cross_extent, crossExtent(value.axis, size));
    }

    const bounded_main = mainBounded(value.axis, constraints);
    if (total_flex != 0 and !bounded_main) return error.FlexInUnboundedAxis;
    const available_main = mainMaximum(value.axis, constraints);
    const remaining = if (bounded_main) @max(0, available_main - occupied_main) else 0;

    child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const data = try flexData(try context.parentData(handle));
        if (data.factor == 0) continue;
        const allocation = remaining * @as(f32, @floatFromInt(data.factor)) /
            @as(f32, @floatFromInt(total_flex));
        const size = try context.layoutChild(
            handle,
            flexConstraints(value, constraints, allocation, data.fit),
        );
        occupied_main += mainExtent(value.axis, size);
        cross_extent = @max(cross_extent, crossExtent(value.axis, size));
    }

    var desired = fromExtents(value.axis, occupied_main, cross_extent);
    if (value.main_axis_size == .max and bounded_main)
        setMainExtent(value.axis, &desired, available_main);
    const size = constraints.constrain(desired);

    var cursor: f32 = 0;
    child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const child_size = try context.size(handle);
        const cross_offset = switch (value.cross_axis_alignment) {
            .start, .stretch => 0,
            .center => (crossExtent(value.axis, size) - crossExtent(value.axis, child_size)) / 2,
            .end => crossExtent(value.axis, size) - crossExtent(value.axis, child_size),
        };
        try context.setChildOffset(handle, pointFromExtents(value.axis, cursor, cross_offset));
        cursor += mainExtent(value.axis, child_size) + value.gap;
    }
    return size;
}

const FlexData = struct { factor: u16, fit: types.FlexFit };

fn flexData(data: types.ParentData) !FlexData {
    return switch (data) {
        .none => .{ .factor = 0, .fit = .tight },
        .flex => |value| .{ .factor = value.factor, .fit = value.fit },
        .stack => error.InvalidParentData,
    };
}

fn nonFlexConstraints(value: types.Flex, constraints: Constraints) Constraints {
    const stretch = value.cross_axis_alignment == .stretch;
    return switch (value.axis) {
        .horizontal => .{
            .max_width = std.math.inf(f32),
            .min_height = if (stretch and constraints.hasBoundedHeight()) constraints.max_height else 0,
            .max_height = constraints.max_height,
        },
        .vertical => .{
            .min_width = if (stretch and constraints.hasBoundedWidth()) constraints.max_width else 0,
            .max_width = constraints.max_width,
            .max_height = std.math.inf(f32),
        },
    };
}

fn flexConstraints(
    value: types.Flex,
    constraints: Constraints,
    allocation: f32,
    fit: types.FlexFit,
) Constraints {
    const tight_main = fit == .tight;
    const stretch = value.cross_axis_alignment == .stretch;
    return switch (value.axis) {
        .horizontal => .{
            .min_width = if (tight_main) allocation else 0,
            .max_width = allocation,
            .min_height = if (stretch and constraints.hasBoundedHeight()) constraints.max_height else 0,
            .max_height = constraints.max_height,
        },
        .vertical => .{
            .min_width = if (stretch and constraints.hasBoundedWidth()) constraints.max_width else 0,
            .max_width = constraints.max_width,
            .min_height = if (tight_main) allocation else 0,
            .max_height = allocation,
        },
    };
}

fn mainBounded(axis: types.Axis, constraints: Constraints) bool {
    return switch (axis) {
        .horizontal => constraints.hasBoundedWidth(),
        .vertical => constraints.hasBoundedHeight(),
    };
}

fn mainMaximum(axis: types.Axis, constraints: Constraints) f32 {
    return switch (axis) {
        .horizontal => constraints.max_width,
        .vertical => constraints.max_height,
    };
}

fn mainExtent(axis: types.Axis, size: SizeF) f32 {
    return switch (axis) {
        .horizontal => size.width,
        .vertical => size.height,
    };
}

fn crossExtent(axis: types.Axis, size: SizeF) f32 {
    return switch (axis) {
        .horizontal => size.height,
        .vertical => size.width,
    };
}

fn fromExtents(axis: types.Axis, main: f32, cross: f32) SizeF {
    return switch (axis) {
        .horizontal => .{ .width = main, .height = cross },
        .vertical => .{ .width = cross, .height = main },
    };
}

fn pointFromExtents(axis: types.Axis, main: f32, cross: f32) PointF {
    return switch (axis) {
        .horizontal => .{ .x = main, .y = cross },
        .vertical => .{ .x = cross, .y = main },
    };
}

fn setMainExtent(axis: types.Axis, size: *SizeF, value: f32) void {
    switch (axis) {
        .horizontal => size.width = value,
        .vertical => size.height = value,
    }
}
