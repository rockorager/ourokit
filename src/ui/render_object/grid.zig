const std = @import("std");
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const types = @import("types.zig");

pub fn validate(value: types.Grid) !void {
    for ([_]f32{ value.column_gap, value.row_gap }) |gap|
        if (!std.math.isFinite(gap) or gap < 0) return error.InvalidGap;
    for ([_]types.GridTracks{ value.columns, value.rows }) |tracks| {
        if (tracks.len == 0 or tracks.len > types.GridTracks.capacity) return error.InvalidGridTracks;
        for (tracks.slice()) |track| switch (track) {
            .auto => {},
            .fixed => |size| if (!std.math.isFinite(size) or size < 0) return error.InvalidGridTracks,
            .fr => |weight| if (!std.math.isFinite(weight) or weight <= 0) return error.InvalidGridTracks,
        };
    }
}

pub fn validatePlacement(value: types.Grid, data: types.ParentData) !void {
    if (data != .grid) return error.InvalidParentData;
    const cell = data.grid;
    if (cell.column_span == 0 or cell.row_span == 0 or
        @as(usize, cell.column) + cell.column_span > value.columns.len or
        @as(usize, cell.row) + cell.row_span > value.rows.len)
        return error.InvalidParentData;
}

pub fn layout(value: types.Grid, context: anytype, node: anytype, constraints: Constraints) !SizeF {
    var columns = Axis.init(value.columns, value.column_gap, constraints.max_width);
    var rows = Axis.init(value.rows, value.row_gap, constraints.max_height);
    // Resolve horizontal intrinsic contributions first. Spans grow only auto
    // tracks (and unbounded fractional tracks), shortest spans before longer
    // spans, with child order breaking ties. Fixed tracks never grow.
    var child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        try validatePlacement(value, try context.parentData(handle));
        const cell = (try context.parentData(handle)).grid;
        if (columns.hasIntrinsic(cell.column, cell.column_span))
            _ = try context.layoutChild(handle, .{});
    }
    for (1..@as(usize, value.columns.len) + 1) |span| {
        child = context.firstChild(node);
        while (child) |handle| : (child = context.nextSibling(handle)) {
            const cell = (try context.parentData(handle)).grid;
            if (cell.column_span == span and columns.hasIntrinsic(cell.column, span))
                columns.contribute(cell.column, span, (try context.size(handle)).width);
        }
    }
    columns.resolveFractions();

    // Height depends on resolved width (not vice versa), so wrapping text gets
    // its actual column width before contributing to auto rows.
    child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const cell = (try context.parentData(handle)).grid;
        if (rows.hasIntrinsic(cell.row, cell.row_span))
            _ = try context.layoutChild(handle, .{ .max_width = columns.extent(cell.column, cell.column_span) });
    }
    for (1..@as(usize, value.rows.len) + 1) |span| {
        child = context.firstChild(node);
        while (child) |handle| : (child = context.nextSibling(handle)) {
            const cell = (try context.parentData(handle)).grid;
            if (cell.row_span == span and rows.hasIntrinsic(cell.row, span))
                rows.contribute(cell.row, span, (try context.size(handle)).height);
        }
    }
    rows.resolveFractions();

    child = context.firstChild(node);
    while (child) |handle| : (child = context.nextSibling(handle)) {
        const cell = (try context.parentData(handle)).grid;
        _ = try context.layoutChild(handle, .{
            .max_width = columns.extent(cell.column, cell.column_span),
            .max_height = rows.extent(cell.row, cell.row_span),
        });
        try context.setChildOffset(handle, .{ .x = columns.offset(cell.column), .y = rows.offset(cell.row) });
    }
    return constraints.constrain(.{ .width = columns.extent(0, value.columns.len), .height = rows.extent(0, value.rows.len) });
}

const Axis = struct {
    tracks: types.GridTracks,
    sizes: [types.GridTracks.capacity]f32 = @splat(0),
    gap: f32,
    maximum: f32,

    fn init(tracks: types.GridTracks, gap: f32, maximum: f32) Axis {
        var result: Axis = .{ .tracks = tracks, .gap = gap, .maximum = maximum };
        for (tracks.slice(), 0..) |track, index| {
            if (track == .fixed) result.sizes[index] = track.fixed;
        }
        return result;
    }

    fn intrinsic(self: *const Axis, index: usize) bool {
        return self.tracks.values[index] == .auto or
            (self.tracks.values[index] == .fr and !std.math.isFinite(self.maximum));
    }

    fn hasIntrinsic(self: *const Axis, start: usize, span: usize) bool {
        for (start..start + span) |index| if (self.intrinsic(index)) return true;
        return false;
    }

    fn contribute(self: *Axis, start: usize, span: usize, size: f32) void {
        var count: usize = 0;
        for (start..start + span) |index| {
            if (self.intrinsic(index)) count += 1;
        }
        if (count == 0) return;
        const extra = @max(0, size - self.extent(start, span)) / @as(f32, @floatFromInt(count));
        for (start..start + span) |index| {
            if (self.intrinsic(index)) self.sizes[index] += extra;
        }
    }

    fn resolveFractions(self: *Axis) void {
        if (!std.math.isFinite(self.maximum)) return;
        var weight: f64 = 0;
        for (self.tracks.slice()) |track| {
            if (track == .fr) weight += track.fr;
        }
        if (weight == 0) return;
        const remaining = @max(0, self.maximum - self.extent(0, self.tracks.len));
        for (self.tracks.slice(), 0..) |track, index| {
            if (track == .fr) self.sizes[index] = @floatCast(@as(f64, remaining) * track.fr / weight);
        }
    }

    fn extent(self: *const Axis, start: usize, span: usize) f32 {
        var result = self.gap * @as(f32, @floatFromInt(span - 1));
        for (self.sizes[start .. start + span]) |size| result += size;
        return result;
    }

    fn offset(self: *const Axis, index: usize) f32 {
        return if (index == 0) 0 else self.extent(0, index) + self.gap;
    }
};
