const std = @import("std");
const PointF = @import("../../core/geometry.zig").PointF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn validate(value: types.Flex) !void {
    if (!std.math.isFinite(value.gap) or value.gap < 0) return error.InvalidGap;
    if (!std.math.isFinite(value.run_gap) or value.run_gap < 0) return error.InvalidGap;
}

pub fn layout(value: types.Flex, context: anytype, node: anytype, incoming: Constraints) !SizeF {
    if (value.wrap) return layoutWrap(value, context, node, incoming);
    var constraints = incoming;
    while (true) {
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

        // Stretch needs a finite cross-axis extent. When the parent cannot supply
        // one, measure it from the children, then lay them out against that size.
        // Only explicit stretch takes this extra pass; ordinary intrinsic flex
        // remains one-pass. The resolved bound guarantees the next pass is final.
        if (value.cross_axis_alignment == .stretch) switch (value.axis) {
            .horizontal => if (!constraints.hasBoundedHeight()) {
                constraints.min_height = size.height;
                constraints.max_height = size.height;
                continue;
            },
            .vertical => if (!constraints.hasBoundedWidth()) {
                constraints.min_width = size.width;
                constraints.max_width = size.width;
                continue;
            },
        };

        const spacing = distribute(value.main_axis_alignment, @max(0, mainExtent(value.axis, size) - occupied_main), child_count);
        var cursor: f32 = spacing.leading;
        child = context.firstChild(node);
        while (child) |handle| : (child = context.nextSibling(handle)) {
            const child_size = try context.size(handle);
            const cross_offset = switch (value.cross_axis_alignment) {
                .start, .stretch => 0,
                .center => (crossExtent(value.axis, size) - crossExtent(value.axis, child_size)) / 2,
                .end => crossExtent(value.axis, size) - crossExtent(value.axis, child_size),
            };
            try context.setChildOffset(handle, pointFromExtents(value.axis, cursor, cross_offset));
            cursor += mainExtent(value.axis, child_size) + value.gap + spacing.between;
        }
        return size;
    }
}

const FlexData = struct { factor: u16, fit: types.FlexFit };

fn flexData(data: types.ParentData) !FlexData {
    return switch (data) {
        .none => .{ .factor = 0, .fit = .tight },
        .flex => |value| .{ .factor = value.factor, .fit = value.fit },
        else => error.InvalidParentData,
    };
}

fn layoutWrap(value: types.Flex, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    // A child is measured against the whole run, never the leftover space.
    // This gives exact-fit boundaries and keeps greedy packing predictable.
    const child_constraints = constraints.loosen();
    var measured_main: f32 = 0;
    var line_main: f32 = 0;
    var line_count: usize = 0;
    var child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        if ((try flexData(try context.parentData(handle))).factor != 0)
            return error.FlexInWrap;
        const extent = mainExtent(value.axis, try context.layoutChild(handle, child_constraints));
        const next = line_main + value.gap + extent;
        if (line_count != 0 and next > mainMaximum(value.axis, constraints)) {
            measured_main = @max(measured_main, line_main);
            line_count = 0;
        }
        line_main = if (line_count == 0) extent else next;
        line_count += 1;
    }
    measured_main = @max(measured_main, line_main);
    if (value.main_axis_size == .max and mainBounded(value.axis, constraints))
        measured_main = mainMaximum(value.axis, constraints);
    const resolved_main = mainExtent(value.axis, constraints.constrain(fromExtents(value.axis, measured_main, 0)));

    var run_start = context.firstChild(node);
    var cross_cursor: f32 = 0;
    var main_extent: f32 = 0;
    while (run_start) |first| {
        var run_end = context.nextSibling(first);
        var run_main = mainExtent(value.axis, try context.size(first));
        var run_cross = crossExtent(value.axis, try context.size(first));
        var run_count: usize = 1;
        while (run_end) |handle| {
            const size = try context.size(handle);
            const next_main = run_main + value.gap + mainExtent(value.axis, size);
            if (next_main > mainMaximum(value.axis, constraints)) break;
            run_main = next_main;
            run_cross = @max(run_cross, crossExtent(value.axis, size));
            run_count += 1;
            run_end = context.nextSibling(handle);
        }

        const spacing = distribute(value.main_axis_alignment, @max(0, resolved_main - run_main), run_count);
        var cursor: f32 = spacing.leading;
        child = run_start;
        while (child) |handle| : (child = context.nextSibling(handle)) {
            if (std.meta.eql(child, run_end)) break;
            var size = try context.size(handle);
            if (value.cross_axis_alignment == .stretch) {
                var stretched = child_constraints;
                switch (value.axis) {
                    .horizontal => {
                        stretched.min_height = run_cross;
                        stretched.max_height = run_cross;
                        stretched.min_width = size.width;
                        stretched.max_width = size.width;
                    },
                    .vertical => {
                        stretched.min_width = run_cross;
                        stretched.max_width = run_cross;
                        stretched.min_height = size.height;
                        stretched.max_height = size.height;
                    },
                }
                size = try context.layoutChild(handle, stretched);
            }
            const offset = switch (value.cross_axis_alignment) {
                .start, .stretch => 0,
                .center => (run_cross - crossExtent(value.axis, size)) / 2,
                .end => run_cross - crossExtent(value.axis, size),
            };
            try context.setChildOffset(handle, pointFromExtents(value.axis, cursor, cross_cursor + offset));
            cursor += mainExtent(value.axis, size) + value.gap + spacing.between;
        }
        main_extent = @max(main_extent, run_main);
        cross_cursor += run_cross;
        if (run_end != null) cross_cursor += value.run_gap;
        run_start = run_end;
    }
    if (value.main_axis_size == .max and mainBounded(value.axis, constraints))
        main_extent = mainMaximum(value.axis, constraints);
    return constraints.constrain(fromExtents(value.axis, main_extent, cross_cursor));
}

fn distribute(alignment: types.MainAxisAlignment, free: f32, count: usize) struct { leading: f32 = 0, between: f32 = 0 } {
    if (count == 0) return .{};
    const n: f32 = @floatFromInt(count);
    return switch (alignment) {
        .start => .{},
        .center => .{ .leading = free / 2 },
        .end => .{ .leading = free },
        .space_between => .{ .between = if (count > 1) free / (n - 1) else 0 },
        .space_around => .{ .leading = free / n / 2, .between = free / n },
        .space_evenly => .{ .leading = free / (n + 1), .between = free / (n + 1) },
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
