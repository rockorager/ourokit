const std = @import("std");
const scene = @import("root.zig");
const RectI = @import("../core/geometry.zig").RectI;

/// Compares complete scenes with the last successfully submitted scene, not
/// the last build. Snapshots contain values only: resource handles are immutable
/// and generation checked, and old bounds never require resolving old leases.
pub const Tracker = struct {
    const Draw = struct {
        command: scene.Command,
        clip: RectI,
        bounds: RectI,
    };

    allocator: std.mem.Allocator,
    previous: []Draw,
    candidate: []Draw,
    previous_count: usize = 0,
    candidate_count: usize = 0,
    previous_viewport: ?RectI = null,
    candidate_viewport: RectI = undefined,
    region: [1]RectI = undefined,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Tracker {
        const previous = try allocator.alloc(Draw, capacity);
        errdefer allocator.free(previous);
        return .{
            .allocator = allocator,
            .previous = previous,
            .candidate = try allocator.alloc(Draw, capacity),
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.allocator.free(self.previous);
        self.allocator.free(self.candidate);
        self.* = undefined;
    }

    pub fn invalidate(self: *Tracker) void {
        self.previous_viewport = null;
    }

    /// Returned regions remain valid until the next comparison. Text uses its
    /// effective clip, not logical font metrics (glyph ink can overhang them).
    /// Retained text nodes provide a tight clip; unclipped text is conservatively
    /// bounded by the viewport. Outlines already have expanded scene rectangles.
    pub fn compare(self: *Tracker, commands: []const scene.Command, viewport: RectI) !scene.Damage {
        self.candidate_count = 0;
        self.candidate_viewport = viewport;
        var clips: [scene.max_clip_depth + 1]RectI = undefined;
        clips[0] = viewport;
        var depth: usize = 0;
        for (commands) |command| {
            switch (command) {
                .push_clip_rect => |clip| {
                    if (depth == scene.max_clip_depth) return error.ClipStackOverflow;
                    depth += 1;
                    clips[depth] = RectI.intersect(clips[depth - 1], clip);
                    continue;
                },
                .pop_clip => {
                    if (depth == 0) return error.UnbalancedClipStack;
                    depth -= 1;
                    continue;
                },
                else => {},
            }
            const bounds = switch (command) {
                .solid_rectangle => |value| RectI.intersect(value.bounds, clips[depth]),
                .decorated_rectangle => |value| RectI.intersect(value.bounds, clips[depth]),
                .image => |value| RectI.intersect(value.bounds, clips[depth]),
                .clear, .glyph_run, .paragraph => clips[depth],
                else => unreachable,
            };
            if (bounds.isEmpty()) continue;
            if (self.candidate_count == self.candidate.len) return error.SceneCapacityExceeded;
            self.candidate[self.candidate_count] = .{ .command = command, .clip = clips[depth], .bounds = bounds };
            self.candidate_count += 1;
        }
        if (depth != 0) return error.UnbalancedClipStack;
        if (self.previous_viewport == null or !std.meta.eql(self.previous_viewport.?, viewport)) return .full;

        const old = self.previous[0..self.previous_count];
        const new = self.candidate[0..self.candidate_count];
        var start: usize = 0;
        while (start < @min(old.len, new.len) and std.meta.eql(old[start], new[start])) : (start += 1) {}
        var old_end = old.len;
        var new_end = new.len;
        while (old_end > start and new_end > start and std.meta.eql(old[old_end - 1], new[new_end - 1])) {
            old_end -= 1;
            new_end -= 1;
        }
        // A single conservative union matches the host's bounded damage history.
        // Equal prefix/suffix draws are still replayed by the renderer in this
        // region, preserving occlusion and source-over composition.
        var bounds: ?RectI = null;
        for (old[start..old_end]) |draw| include(&bounds, draw.bounds);
        for (new[start..new_end]) |draw| include(&bounds, draw.bounds);
        if (bounds) |value| {
            self.region[0] = value;
            return .{ .regions = &self.region };
        }
        return .{ .regions = &.{} };
    }

    /// Only advance history after the backend accepts the candidate scene.
    pub fn submitted(self: *Tracker) void {
        std.mem.swap([]Draw, &self.previous, &self.candidate);
        self.previous_count = self.candidate_count;
        self.previous_viewport = self.candidate_viewport;
    }
};

fn include(result: *?RectI, value: RectI) void {
    const old = result.* orelse {
        result.* = value;
        return;
    };
    const left = @min(old.x, value.x);
    const top = @min(old.y, value.y);
    result.* = .{
        .x = left,
        .y = top,
        .width = @intCast(@max(@as(i64, old.x) + old.width, @as(i64, value.x) + value.width) - left),
        .height = @intCast(@max(@as(i64, old.y) + old.height, @as(i64, value.y) + value.height) - top),
    };
}

test "scene damage includes old and new clipped bounds since submission" {
    const Color = @import("../core/color.zig").Color;
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    var tracker = try Tracker.init(std.testing.allocator, 5);
    defer tracker.deinit();
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) },
        .{ .push_clip_rect = .{ .x = 10, .y = 8, .width = 60, .height = 30 } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 5, .y = 10, .width = 12, .height = 9 }, .color = Color.rgba(255, 0, 0, 128) } },
        .pop_clip,
        // A full-window unchanged overlay must not force full damage.
        .{ .solid_rectangle = .{ .bounds = viewport, .color = Color.rgba(10, 20, 30, 60) } },
    };
    try std.testing.expect(try tracker.compare(&commands, viewport) == .full);
    tracker.submitted();
    try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(&commands, viewport)).regions.len);

    commands[2].solid_rectangle.bounds.x = 25;
    try std.testing.expectEqual(RectI{ .x = 10, .y = 10, .width = 27, .height = 9 }, (try tracker.compare(&commands, viewport)).regions[0]);
    // This candidate was never presented; damage is still relative to x=5.
    commands[2].solid_rectangle.bounds.x = 45;
    try std.testing.expectEqual(RectI{ .x = 10, .y = 10, .width = 47, .height = 9 }, (try tracker.compare(&commands, viewport)).regions[0]);
    tracker.submitted();
    const removed = [_]scene.Command{ commands[0], commands[4] };
    try std.testing.expectEqual(RectI{ .x = 45, .y = 10, .width = 12, .height = 9 }, (try tracker.compare(&removed, viewport)).regions[0]);
    // Discarding a candidate must not mutate the submitted snapshot.
    try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(&commands, viewport)).regions.len);
    commands[0].clear.a = 100;
    try std.testing.expectEqual(viewport, (try tracker.compare(&commands, viewport)).regions[0]);
    tracker.submitted();
    try std.testing.expect(try tracker.compare(&commands, .{ .x = 0, .y = 0, .width = 101, .height = 80 }) == .full);
    tracker.invalidate();
    try std.testing.expect(try tracker.compare(&commands, viewport) == .full);
}

test "scene damage sees changed text clips and immutable resource generations" {
    const Color = @import("../core/color.zig").Color;
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    var tracker = try Tracker.init(std.testing.allocator, 5);
    defer tracker.deinit();
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) },
        .{ .push_clip_rect = .{ .x = 8, .y = 4, .width = 32, .height = 12 } },
        .{ .paragraph = .{ .layout = .{ .slot = 1, .generation = 1 }, .origin = .{}, .scale = 1.5, .color = Color.rgba(0, 0, 0, 255) } },
        .pop_clip,
        .{ .image = .{ .image = .{ .slot = 1, .generation = 1 }, .bounds = .{ .x = 60, .y = 50, .width = 17, .height = 11 } } },
    };
    _ = try tracker.compare(&commands, viewport);
    tracker.submitted();
    // Even an otherwise identical suffix paragraph changes when its clip does.
    commands[1].push_clip_rect.width = 40;
    try std.testing.expectEqual(RectI{ .x = 8, .y = 4, .width = 40, .height = 12 }, (try tracker.compare(&commands, viewport)).regions[0]);
    tracker.submitted();
    commands[2].paragraph.layout.generation += 1;
    try std.testing.expectEqual(commands[1].push_clip_rect, (try tracker.compare(&commands, viewport)).regions[0]);
    tracker.submitted();
    commands[4].image.image.generation += 1;
    try std.testing.expectEqual(commands[4].image.bounds, (try tracker.compare(&commands, viewport)).regions[0]);
}
