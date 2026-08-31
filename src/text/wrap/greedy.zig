//! Linear-time greedy selection over measured line-break opportunities.

const std = @import("std");
const line_break = @import("../line_break.zig");

pub const Line = struct {
    byte_start: usize,
    byte_len: usize,
    advance: f32,
    mandatory: bool,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    lines: []Line,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.lines);
        self.* = undefined;
    }
};

/// Selects the last fitting opportunity in O(n) time. `segment_advances[i]`
/// is the measured advance from the preceding opportunity (or paragraph start)
/// through `breaks[i]`. Oversized unbreakable segments overflow on one line;
/// this function never invents a break prohibited by UAX #14.
pub fn wrap(
    allocator: std.mem.Allocator,
    breaks: []const line_break.LineBreak,
    segment_advances: []const f32,
    max_width: f32,
) !Result {
    if (breaks.len != segment_advances.len) return error.InvalidMeasurements;
    if (breaks.len == 0 or breaks[breaks.len - 1].kind != .mandatory)
        return error.MissingFinalBreak;
    if (!std.math.isFinite(max_width) or max_width < 0) return error.InvalidWidth;

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);
    var line_start: usize = 0;
    var previous_break: usize = 0;
    var line_advance: f32 = 0;
    for (breaks, segment_advances) |opportunity, segment_advance| {
        if (opportunity.byte_offset < previous_break or
            !std.math.isFinite(segment_advance) or segment_advance < 0)
            return error.InvalidMeasurements;

        const next_advance = line_advance + segment_advance;
        if (next_advance > max_width and previous_break > line_start) {
            try lines.append(allocator, .{
                .byte_start = line_start,
                .byte_len = previous_break - line_start,
                .advance = line_advance,
                .mandatory = false,
            });
            line_start = previous_break;
            line_advance = segment_advance;
        } else {
            line_advance = next_advance;
        }

        const oversized_first_segment = line_advance > max_width and
            opportunity.byte_offset > line_start;
        if (opportunity.kind == .mandatory or oversized_first_segment) {
            try lines.append(allocator, .{
                .byte_start = line_start,
                .byte_len = opportunity.byte_offset - line_start,
                .advance = line_advance,
                .mandatory = opportunity.kind == .mandatory,
            });
            line_start = opportunity.byte_offset;
            line_advance = 0;
        }
        previous_break = opportunity.byte_offset;
    }
    std.debug.assert(line_start == previous_break);
    return .{ .allocator = allocator, .lines = try lines.toOwnedSlice(allocator) };
}

test "greedy wrapping selects the last fitting opportunity" {
    const opportunities = [_]line_break.LineBreak{
        .{ .byte_offset = 4, .kind = .allowed },
        .{ .byte_offset = 8, .kind = .allowed },
        .{ .byte_offset = 12, .kind = .mandatory },
    };
    var result = try wrap(std.testing.allocator, &opportunities, &.{ 4, 4, 4 }, 9);
    defer result.deinit();
    try std.testing.expectEqualSlices(Line, &.{
        .{ .byte_start = 0, .byte_len = 8, .advance = 8, .mandatory = false },
        .{ .byte_start = 8, .byte_len = 4, .advance = 4, .mandatory = true },
    }, result.lines);
}

test "greedy wrapping preserves oversized unbreakable segments" {
    const opportunities = [_]line_break.LineBreak{
        .{ .byte_offset = 12, .kind = .allowed },
        .{ .byte_offset = 16, .kind = .mandatory },
    };
    var result = try wrap(std.testing.allocator, &opportunities, &.{ 12, 4 }, 8);
    defer result.deinit();
    try std.testing.expectEqualSlices(Line, &.{
        .{ .byte_start = 0, .byte_len = 12, .advance = 12, .mandatory = false },
        .{ .byte_start = 12, .byte_len = 4, .advance = 4, .mandatory = true },
    }, result.lines);
}

test "greedy wrapping validates measurements and allocation failures" {
    const opportunities = [_]line_break.LineBreak{
        .{ .byte_offset = 2, .kind = .allowed },
        .{ .byte_offset = 4, .kind = .mandatory },
    };
    try std.testing.expectError(
        error.InvalidMeasurements,
        wrap(std.testing.allocator, &opportunities, &.{1}, 10),
    );
    try std.testing.expectError(
        error.InvalidWidth,
        wrap(std.testing.allocator, &opportunities, &.{ 1, 1 }, std.math.nan(f32)),
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    const opportunities = [_]line_break.LineBreak{
        .{ .byte_offset = 2, .kind = .allowed },
        .{ .byte_offset = 4, .kind = .mandatory },
    };
    var result = try wrap(allocator, &opportunities, &.{ 2, 2 }, 3);
    defer result.deinit();
}
