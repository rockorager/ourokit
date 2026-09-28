const std = @import("std");
const geometry = @import("../../core/geometry.zig");
const PointF = geometry.PointF;
const SizeF = geometry.SizeF;
const RectF = geometry.RectF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const Anchored = @import("types.zig").Anchored;

pub fn validate(value: Anchored) !void {
    if (!std.math.isFinite(value.gap) or value.gap < 0 or
        !std.math.isFinite(value.margin) or value.margin < 0)
        return error.InvalidAnchored;
}

pub fn layout(context: anytype, node: anytype, constraints: Constraints) !SizeF {
    const count = context.childCount(node);
    if (count < 1 or count > 2) return error.AnchoredRequiresOneOrTwoChildren;
    const trigger = context.firstChild(node).?;
    const size = try context.layoutChild(trigger, constraints);
    try context.setChildOffset(trigger, .{});
    return size;
}

/// Collapse excessive margins to the viewport center, never to an inverted rect.
pub fn inset(viewport: SizeF, margin: f32) RectF {
    const x = @min(margin, viewport.width / 2);
    const y = @min(margin, viewport.height / 2);
    return .{ .x = x, .y = y, .width = viewport.width - x * 2, .height = viewport.height - y * 2 };
}

/// Use wider intermediates so even finite f32 gaps and offscreen anchors cannot
/// overflow during fitting. Ties preserve the requested side. Oversized content
/// pins to the inset's leading edge rather than producing an inverted clamp.
pub fn place(value: Anchored, trigger: RectF, popup: SizeF, viewport: RectF) PointF {
    var position = candidate(value.side, value.alignment, value.gap, trigger, popup);
    if (value.flip) {
        const opposite: Anchored.Side = switch (value.side) {
            .top => .bottom,
            .bottom => .top,
            .left => .right,
            .right => .left,
        };
        const alternative = candidate(opposite, value.alignment, value.gap, trigger, popup);
        if (overflow(alternative, popup, viewport) < overflow(position, popup, viewport))
            position = alternative;
    }
    return .{
        .x = @floatCast(std.math.clamp(position[0], viewport.x, @max(@as(f64, viewport.x), @as(f64, viewport.x) + viewport.width - popup.width))),
        .y = @floatCast(std.math.clamp(position[1], viewport.y, @max(@as(f64, viewport.y), @as(f64, viewport.y) + viewport.height - popup.height))),
    };
}

fn candidate(side: Anchored.Side, alignment: Anchored.Alignment, gap: f64, trigger: RectF, popup: SizeF) [2]f64 {
    const fraction: f64 = switch (alignment) {
        .start => 0,
        .center => 0.5,
        .end => 1,
    };
    const x: f64 = trigger.x;
    const y: f64 = trigger.y;
    return switch (side) {
        .top => .{ x + (@as(f64, trigger.width) - popup.width) * fraction, y - gap - popup.height },
        .bottom => .{ x + (@as(f64, trigger.width) - popup.width) * fraction, y + trigger.height + gap },
        .left => .{ x - gap - popup.width, y + (@as(f64, trigger.height) - popup.height) * fraction },
        .right => .{ x + trigger.width + gap, y + (@as(f64, trigger.height) - popup.height) * fraction },
    };
}

fn overflow(position: [2]f64, popup: SizeF, viewport: RectF) f64 {
    return @max(0, viewport.x - position[0]) + @max(0, viewport.y - position[1]) +
        @max(0, position[0] + popup.width - viewport.x - viewport.width) +
        @max(0, position[1] + popup.height - viewport.y - viewport.height);
}
