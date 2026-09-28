const std = @import("std");
const scene = @import("root.zig");
const RectI = @import("../core/geometry.zig").RectI;

pub const max_groups = 1024;
pub const max_bytes = 64 * 1024 * 1024;
const empty: RectI = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// Device-coordinate cropped surfaces, ordered by push command. Bounds include
/// shadows and overflowing children, not just the container's layout rectangle.
pub const Group = struct {
    begin: usize,
    end: usize,
    bounds: RectI = empty,
    opacity: u16,
};

/// Shared preflight for software and GPU allocations. Budgets cover the sum of
/// all RGBA16 layer pixels in a submission; metadata has its own count bound.
pub const Plan = struct {
    allocator: std.mem.Allocator,
    groups: []Group,
    byte_size: usize,

    pub fn init(allocator: std.mem.Allocator, commands: []const scene.Command, viewport: RectI) !Plan {
        try (scene.DisplayList{ .commands = commands }).validate();
        var count: usize = 0;
        for (commands) |command| if (command == .push_opacity) {
            if (count == max_groups) return error.OpacityGroupLimitExceeded;
            count += 1;
        };
        const groups = try allocator.alloc(Group, count);
        errdefer allocator.free(groups);
        var clips: [scene.max_clip_depth + 1]RectI = undefined;
        clips[0] = viewport;
        var clip_depth: usize = 0;
        var stack: [scene.max_opacity_depth]usize = undefined;
        var depth: usize = 0;
        var index: usize = 0;
        for (commands, 0..) |command, position| switch (command) {
            .push_clip_rect, .push_clip_rounded => {
                const bounds = if (command == .push_clip_rect) command.push_clip_rect else command.push_clip_rounded.bounds;
                clips[clip_depth + 1] = RectI.intersect(clips[clip_depth], bounds);
                clip_depth += 1;
            },
            .pop_clip => clip_depth -= 1,
            .push_opacity => |alpha| {
                groups[index] = .{ .begin = position, .end = undefined, .opacity = alpha };
                stack[depth] = index;
                index += 1;
                depth += 1;
            },
            .pop_opacity => {
                depth -= 1;
                const group = &groups[stack[depth]];
                group.end = position;
                if (group.opacity == 0) group.bounds = empty;
                if (depth != 0) include(&groups[stack[depth - 1]].bounds, group.bounds);
            },
            else => if (depth != 0) {
                const bounds = switch (command) {
                    .solid_rectangle => |value| value.bounds,
                    .decorated_rectangle => |value| value.bounds,
                    .image => |value| value.bounds,
                    .path => |value| value.bounds,
                    .shadow => |value| value.bounds,
                    .glyph_run, .paragraph => clips[clip_depth],
                    else => unreachable,
                };
                include(&groups[stack[depth - 1]].bounds, RectI.intersect(bounds, clips[clip_depth]));
            },
        };
        // A zero-opacity ancestor suppresses allocations too, but never skips
        // command validation or resource resolution by the renderer.
        var hidden_until: usize = 0;
        var bytes: usize = 0;
        for (groups) |*group| {
            if (group.begin < hidden_until) group.bounds = empty;
            if (group.opacity == 0) hidden_until = @max(hidden_until, group.end);
            const area = std.math.mul(usize, group.bounds.width, group.bounds.height) catch return error.OpacityBudgetExceeded;
            const size = std.math.mul(usize, area, 8) catch return error.OpacityBudgetExceeded;
            if (size > max_bytes - bytes) return error.OpacityBudgetExceeded;
            bytes += size;
        }
        return .{ .allocator = allocator, .groups = groups, .byte_size = bytes };
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.groups);
        self.* = undefined;
    }
};

fn include(bounds: *RectI, value: RectI) void {
    if (value.isEmpty()) return;
    if (bounds.isEmpty()) {
        bounds.* = value;
        return;
    }
    // Copy before assigning: struct result-location writes can change x/y
    // before width/height read the previous rectangle.
    const old = bounds.*;
    const left = @min(old.x, value.x);
    const top = @min(old.y, value.y);
    bounds.* = .{
        .x = left,
        .y = top,
        .width = @intCast(@max(@as(i64, old.x) + old.width, @as(i64, value.x) + value.width) - left),
        .height = @intCast(@max(@as(i64, old.y) + old.height, @as(i64, value.y) + value.height) - top),
    };
}

test "opacity plan crops overflow propagates children and excludes invisible allocations" {
    const Color = @import("../core/color.zig").Color;
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 80, .height = 60 };
    var commands = [_]scene.Command{
        .{ .push_opacity = 32768 },
        .{ .solid_rectangle = .{ .bounds = .{ .x = -4, .y = 5, .width = 12, .height = 9 }, .color = Color.rgba(255, 0, 0, 255) } },
        .{ .push_clip_rect = .{ .x = 30, .y = 20, .width = 7, .height = 11 } },
        .{ .push_opacity = 16384 },
        .{ .solid_rectangle = .{ .bounds = viewport, .color = Color.rgba(0, 255, 0, 255) } },
        .pop_opacity,
        .pop_clip,
        .pop_opacity,
    };
    var plan = try Plan.init(std.testing.allocator, &commands, viewport);
    defer plan.deinit();
    try std.testing.expectEqual(Group{ .begin = 0, .end = 7, .bounds = .{ .x = 0, .y = 5, .width = 37, .height = 26 }, .opacity = 32768 }, plan.groups[0]);
    try std.testing.expectEqual(Group{ .begin = 3, .end = 5, .bounds = commands[2].push_clip_rect, .opacity = 16384 }, plan.groups[1]);
    try std.testing.expectEqual(@as(usize, (37 * 26 + 7 * 11) * 8), plan.byte_size);
    var reversed: RectI = .{ .x = 30, .y = 20, .width = 7, .height = 11 };
    include(&reversed, .{ .x = 0, .y = 5, .width = 8, .height = 9 });
    try std.testing.expectEqual(plan.groups[0].bounds, reversed);
    commands[0].push_opacity = 0;
    var hidden = try Plan.init(std.testing.allocator, &commands, viewport);
    defer hidden.deinit();
    try std.testing.expectEqual(@as(usize, 0), hidden.byte_size);
    for (hidden.groups) |group| try std.testing.expectEqual(empty, group.bounds);
    commands[0].push_opacity = 65535;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator, batch: []const scene.Command, bounds: RectI) !void {
            var value = try Plan.init(allocator, batch, bounds);
            defer value.deinit();
        }
    }.check, .{ @as([]const scene.Command, &commands), viewport });
}

test "opacity plan enforces aggregate pixel and metadata budgets before allocation" {
    const Color = @import("../core/color.zig").Color;
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 4096, .height = 2048 };
    var commands = [_]scene.Command{
        .{ .push_opacity = 1 },
        .{ .solid_rectangle = .{ .bounds = viewport, .color = Color.rgba(0, 0, 0, 255) } },
        .{ .push_opacity = 65535 },
        .{ .solid_rectangle = .{ .bounds = empty, .color = Color.rgba(0, 0, 0, 255) } },
        .pop_opacity,
        .pop_opacity,
    };
    var exact = try Plan.init(std.testing.allocator, &commands, viewport);
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, max_bytes), exact.byte_size);
    commands[3].solid_rectangle.bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    try std.testing.expectError(error.OpacityBudgetExceeded, Plan.init(std.testing.allocator, &commands, viewport));
    const many = try std.testing.allocator.alloc(scene.Command, (max_groups + 1) * 2);
    defer std.testing.allocator.free(many);
    for (0..max_groups + 1) |i| {
        many[i * 2] = .{ .push_opacity = 0 };
        many[i * 2 + 1] = .pop_opacity;
    }
    var limit = try Plan.init(std.testing.allocator, many[0 .. max_groups * 2], viewport);
    defer limit.deinit();
    try std.testing.expectEqual(@as(usize, max_groups), limit.groups.len);
    try std.testing.expectError(error.OpacityGroupLimitExceeded, Plan.init(std.testing.allocator, many, viewport));
}
