const std = @import("std");
const scene = @import("root.zig");
const RectI = @import("../core/geometry.zig").RectI;

/// Compares complete scenes with the last successfully submitted scene, not
/// the last build. Snapshots compare values only: handles are generation checked
/// and paths carry unique identities. Old bounds never resolve old resources.
pub const Tracker = struct {
    /// Owned raster inputs, not layout handles or borrowed glyph bitmaps. Source
    /// clusters and caret stops do not affect pixels and are deliberately absent.
    pub const ParagraphSnapshot = struct {
        pub const Glyph = struct {
            font: @import("../text/api.zig").FontHandle,
            id: u32,
            origin: @import("../core/geometry.zig").PointF,
            size: f32,
            color: @import("../core/color.zig").Color,
        };
        pub const Line = struct {
            bounds: RectI,
            first: usize,
            count: usize,
        };

        allocator: std.mem.Allocator,
        lines: std.ArrayList(Line) = .empty,
        glyphs: std.ArrayList(Glyph) = .empty,

        fn deinit(self: *ParagraphSnapshot) void {
            self.lines.deinit(self.allocator);
            self.glyphs.deinit(self.allocator);
        }

        fn copy(self: *ParagraphSnapshot, source: *const ParagraphSnapshot, range: LineRange) !void {
            for (source.lines.items[range.first..][0..range.count]) |line| {
                const first = self.glyphs.items.len;
                try self.glyphs.appendSlice(self.allocator, source.glyphs.items[line.first..][0..line.count]);
                try self.lines.append(self.allocator, .{ .bounds = line.bounds, .first = first, .count = line.count });
            }
        }
    };

    const LineRange = struct { first: usize, count: usize };
    const Draw = struct {
        command: scene.Command,
        clip: RectI,
        bounds: RectI,
        lines: ?LineRange,

        fn equal(a: Draw, b: Draw) bool {
            // Snapshot offsets may differ after earlier paragraphs change.
            return std.meta.eql(a.command, b.command) and std.meta.eql(a.clip, b.clip) and std.meta.eql(a.bounds, b.bounds);
        }
    };

    allocator: std.mem.Allocator,
    previous: []Draw,
    candidate: []Draw,
    previous_text: ParagraphSnapshot,
    candidate_text: ParagraphSnapshot,
    previous_count: usize = 0,
    candidate_count: usize = 0,
    previous_viewport: ?RectI = null,
    candidate_viewport: RectI = undefined,
    region: [1]RectI = undefined,
    /// Optional backend ink bounds. Without a resolver, text damages its clip.
    /// Resolve only current resources; submitted snapshots own their bounds.
    paragraph_bounds: ?struct {
        context: *anyopaque,
        resolve: *const fn (*anyopaque, scene.Paragraph, RectI) anyerror!RectI,
        snapshot: ?*const fn (*anyopaque, scene.Paragraph, RectI, *ParagraphSnapshot) anyerror!RectI = null,
    } = null,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Tracker {
        const previous = try allocator.alloc(Draw, capacity);
        errdefer allocator.free(previous);
        return .{
            .allocator = allocator,
            .previous = previous,
            .candidate = try allocator.alloc(Draw, capacity),
            .previous_text = .{ .allocator = allocator },
            .candidate_text = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.allocator.free(self.previous);
        self.allocator.free(self.candidate);
        self.previous_text.deinit();
        self.candidate_text.deinit();
        self.* = undefined;
    }

    pub fn invalidate(self: *Tracker) void {
        self.previous_viewport = null;
    }

    /// Returned regions remain valid until the next comparison. Text uses
    /// backend ink bounds when available, never logical font metrics (ink can
    /// overhang them). Outlines already have expanded scene rectangles.
    pub fn compare(self: *Tracker, commands: []const scene.Command, viewport: RectI) !scene.Damage {
        self.candidate_count = 0;
        self.candidate_viewport = viewport;
        self.candidate_text.lines.clearRetainingCapacity();
        self.candidate_text.glyphs.clearRetainingCapacity();
        var clips: [scene.max_clip_depth + 1]RectI = undefined;
        clips[0] = viewport;
        var rounded = [_]bool{false} ** (scene.max_clip_depth + 1);
        var depth: usize = 0;
        for (commands) |command| {
            var clip_change: ?RectI = null;
            switch (command) {
                // Group boundaries conservatively damage their enclosing clip:
                // children and outset shadows may exceed the Box's layout bounds.
                .push_opacity, .pop_opacity => clip_change = clips[depth],
                .push_clip_rect => |clip| {
                    if (depth == scene.max_clip_depth) return error.ClipStackOverflow;
                    depth += 1;
                    clips[depth] = RectI.intersect(clips[depth - 1], clip);
                    rounded[depth] = false;
                    continue;
                },
                .push_clip_rounded => |clip| {
                    if (depth == scene.max_clip_depth) return error.ClipStackOverflow;
                    depth += 1;
                    clips[depth] = RectI.intersect(clips[depth - 1], clip.bounds);
                    rounded[depth] = true;
                    clip_change = clips[depth];
                },
                .pop_clip => {
                    if (depth == 0) return error.UnbalancedClipStack;
                    if (rounded[depth]) clip_change = clips[depth];
                    depth -= 1;
                    if (clip_change == null) continue;
                },
                else => {},
            }
            const line_start = self.candidate_text.lines.items.len;
            var has_lines = false;
            // Keep rounded scope boundaries, not just their bounding rectangle:
            // changing radius or moving a pop must invalidate unchanged children.
            const bounds = clip_change orelse switch (command) {
                .solid_rectangle => |value| RectI.intersect(value.bounds, clips[depth]),
                .decorated_rectangle => |value| RectI.intersect(value.bounds, clips[depth]),
                .image => |value| RectI.intersect(value.bounds, clips[depth]),
                .path => |value| RectI.intersect(value.bounds, clips[depth]),
                .shadow => |value| RectI.intersect(value.bounds, clips[depth]),
                .paragraph => |value| ink: {
                    const resolver = self.paragraph_bounds orelse break :ink clips[depth];
                    // Unchanged text (e.g. caret movement) needs no glyph walk.
                    if (self.candidate_count < self.previous_count) {
                        const previous = self.previous[self.candidate_count];
                        if (std.meta.eql(previous.command, command) and std.meta.eql(previous.clip, clips[depth])) {
                            if (resolver.snapshot == null) break :ink previous.bounds;
                            if (previous.lines) |range| {
                                try self.candidate_text.copy(&self.previous_text, range);
                                has_lines = true;
                                break :ink previous.bounds;
                            }
                        }
                    }
                    if (resolver.snapshot) |snapshot| {
                        has_lines = true;
                        break :ink try snapshot(resolver.context, value, clips[depth], &self.candidate_text);
                    }
                    break :ink RectI.intersect(try resolver.resolve(resolver.context, value, clips[depth]), clips[depth]);
                },
                .clear, .glyph_run => clips[depth],
                else => unreachable,
            };
            // Keep empty paragraph snapshots aligned when text appears or is
            // deleted, rather than treating those edits as command insertion.
            if (bounds.isEmpty() and !has_lines) continue;
            if (self.candidate_count == self.candidate.len) return error.SceneCapacityExceeded;
            self.candidate[self.candidate_count] = .{
                .command = command,
                .clip = clips[depth],
                .bounds = bounds,
                .lines = if (has_lines) .{ .first = line_start, .count = self.candidate_text.lines.items.len - line_start } else null,
            };
            self.candidate_count += 1;
        }
        if (depth != 0) return error.UnbalancedClipStack;
        if (self.previous_viewport == null or !std.meta.eql(self.previous_viewport.?, viewport)) return .full;

        const old = self.previous[0..self.previous_count];
        const new = self.candidate[0..self.candidate_count];
        var start: usize = 0;
        while (start < @min(old.len, new.len) and Draw.equal(old[start], new[start])) : (start += 1) {}
        var old_end = old.len;
        var new_end = new.len;
        while (old_end > start and new_end > start and Draw.equal(old[old_end - 1], new[new_end - 1])) {
            old_end -= 1;
            new_end -= 1;
        }
        // Compare aligned draws inside the changed middle too. Insertions and
        // removals retain the conservative union; do not match across a reorder.
        // Unchanged draws are still replayed inside damage for composition.
        var bounds: ?RectI = null;
        if (old_end - start == new_end - start) {
            for (old[start..old_end], new[start..new_end]) |before, after| {
                if (Draw.equal(before, after)) continue;
                if (before.lines != null and after.lines != null and std.meta.eql(before.clip, after.clip)) {
                    self.compareLines(&bounds, before.lines.?, after.lines.?);
                    continue;
                }
                include(&bounds, before.bounds);
                include(&bounds, after.bounds);
            }
        } else {
            for (old[start..old_end]) |draw| include(&bounds, draw.bounds);
            for (new[start..new_end]) |draw| include(&bounds, draw.bounds);
        }
        if (bounds) |value| {
            self.region[0] = value;
            return .{ .regions = &self.region };
        }
        return .{ .regions = &.{} };
    }

    fn compareLines(self: *const Tracker, bounds: *?RectI, before: LineRange, after: LineRange) void {
        const old = self.previous_text.lines.items[before.first..][0..before.count];
        const new = self.candidate_text.lines.items[after.first..][0..after.count];
        const paired = @min(old.len, new.len);
        for (old[0..paired], new[0..paired]) |a, b| {
            const equal = equal: {
                if (!std.meta.eql(a.bounds, b.bounds) or a.count != b.count) break :equal false;
                const old_glyphs = self.previous_text.glyphs.items[a.first..][0..a.count];
                const new_glyphs = self.candidate_text.glyphs.items[b.first..][0..b.count];
                for (old_glyphs, new_glyphs) |x, y| if (!std.meta.eql(x, y)) break :equal false;
                break :equal true;
            };
            if (equal) continue;
            include(bounds, a.bounds);
            include(bounds, b.bounds);
        }
        for (old[paired..]) |line| include(bounds, line.bounds);
        for (new[paired..]) |line| include(bounds, line.bounds);
    }

    /// Only advance history after the backend accepts the candidate scene.
    pub fn submitted(self: *Tracker) void {
        std.mem.swap([]Draw, &self.previous, &self.candidate);
        std.mem.swap(ParagraphSnapshot, &self.previous_text, &self.candidate_text);
        self.previous_count = self.candidate_count;
        self.previous_viewport = self.candidate_viewport;
    }
};

fn include(result: *?RectI, value: RectI) void {
    if (value.isEmpty()) return;
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

test "aligned changes exclude unchanged middle draws but preserve reorders" {
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const small: RectI = .{ .x = 7, .y = 11, .width = 13, .height = 9 };
    var commands = [_]scene.Command{
        .{ .solid_rectangle = .{ .bounds = small, .color = .rgba(255, 0, 0, 255) } },
        .{ .solid_rectangle = .{ .bounds = viewport, .color = .rgba(20, 30, 40, 50) } },
        .{ .solid_rectangle = .{ .bounds = small, .color = .rgba(0, 0, 255, 100) } },
    };
    var tracker = try Tracker.init(std.testing.allocator, 4);
    defer tracker.deinit();
    _ = try tracker.compare(&commands, viewport);
    tracker.submitted();
    commands[0].solid_rectangle.color.g = 75;
    commands[2].solid_rectangle.bounds.x = 24;
    try std.testing.expectEqualSlices(RectI, &.{.{ .x = 7, .y = 11, .width = 30, .height = 9 }}, (try tracker.compare(&commands, viewport)).regions);
    tracker.submitted();
    std.mem.swap(scene.Command, &commands[0], &commands[1]);
    try std.testing.expectEqualSlices(RectI, &.{viewport}, (try tracker.compare(&commands, viewport)).regions);
    const inserted = [_]scene.Command{ commands[0], commands[2], commands[1], commands[2] };
    try std.testing.expectEqualSlices(RectI, &.{viewport}, (try tracker.compare(&inserted, viewport)).regions);
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

test "rounded clip radius and scope changes damage otherwise unchanged draws" {
    const Color = @import("../core/color.zig").Color;
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 60, .height = 40 };
    const bounds: RectI = .{ .x = 5, .y = 7, .width = 23, .height = 17 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(255, 255, 255, 255) },
        .{ .push_clip_rounded = .{ .bounds = bounds, .corner_radius = 3 } },
        .{ .solid_rectangle = .{ .bounds = bounds, .color = Color.rgba(255, 0, 0, 255) } },
        .pop_clip,
    };
    var tracker = try Tracker.init(std.testing.allocator, commands.len);
    defer tracker.deinit();
    _ = try tracker.compare(&commands, viewport);
    tracker.submitted();
    commands[1].push_clip_rounded.corner_radius = 8;
    try std.testing.expectEqualSlices(RectI, &.{bounds}, (try tracker.compare(&commands, viewport)).regions);
    // Unsubmitted candidates never replace committed clip state.
    commands[1].push_clip_rounded.corner_radius = 3;
    try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(&commands, viewport)).regions.len);
    const moved_pop = [_]scene.Command{ commands[0], commands[1], .pop_clip, commands[2] };
    try std.testing.expectEqualSlices(RectI, &.{bounds}, (try tracker.compare(&moved_pop, viewport)).regions);
    const removed = [_]scene.Command{ commands[0], commands[2] };
    try std.testing.expectEqualSlices(RectI, &.{bounds}, (try tracker.compare(&removed, viewport)).regions);
}

test "opacity changes and moved group boundaries invalidate the enclosing clip" {
    const Color = @import("../core/color.zig").Color;
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 60, .height = 40 };
    const clip: RectI = .{ .x = 4, .y = 3, .width = 25, .height = 20 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(255, 255, 255, 255) },
        .{ .push_clip_rect = clip },
        .{ .push_opacity = 32768 },
        .{ .solid_rectangle = .{ .bounds = viewport, .color = Color.rgba(255, 0, 0, 255) } },
        .pop_opacity,
        .pop_clip,
    };
    var tracker = try Tracker.init(std.testing.allocator, commands.len);
    defer tracker.deinit();
    _ = try tracker.compare(&commands, viewport);
    tracker.submitted();
    commands[2].push_opacity = 12345;
    try std.testing.expectEqualSlices(RectI, &.{clip}, (try tracker.compare(&commands, viewport)).regions);
    commands[2].push_opacity = 32768;
    try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(&commands, viewport)).regions.len);
    std.mem.swap(scene.Command, &commands[3], &commands[4]);
    try std.testing.expectEqualSlices(RectI, &.{clip}, (try tracker.compare(&commands, viewport)).regions);
}
