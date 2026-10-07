const std = @import("std");
const scene = @import("root.zig");
const RectI = @import("../core/geometry.zig").RectI;

/// Small owned damage set shared by scene comparison and presentation history.
/// Bounding merges restart intersection checks: a merge can hit a third region.
/// The cap bounds replay and protocol costs; overflow conservatively coalesces.
pub const Regions = struct {
    pub const capacity = 8;
    storage: [capacity]RectI = undefined,
    count: usize = 0,

    pub fn slice(self: *const Regions) []const RectI {
        return self.storage[0..self.count];
    }

    pub fn init(values: []const RectI) Regions {
        var result: Regions = .{};
        for (values) |value| result.add(value);
        return result;
    }

    pub fn add(self: *Regions, value: RectI) void {
        if (value.isEmpty()) return;
        var merged: ?RectI = value;
        var i: usize = 0;
        while (i < self.count) {
            if (RectI.intersect(self.storage[i], merged.?).isEmpty()) {
                i += 1;
                continue;
            }
            include(&merged, self.storage[i]);
            self.count -= 1;
            std.mem.copyForwards(RectI, self.storage[i..self.count], self.storage[i + 1 .. self.count + 1]);
            i = 0;
        }
        if (self.count == capacity) {
            for (self.slice()) |region| include(&merged, region);
            self.count = 0;
        }
        self.storage[self.count] = merged.?;
        self.count += 1;
        std.mem.sort(RectI, self.storage[0..self.count], {}, struct {
            fn less(_: void, a: RectI, b: RectI) bool {
                return a.y < b.y or (a.y == b.y and a.x < b.x);
            }
        }.less);
    }
};

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
            if (!std.meta.eql(a.command, b.command) or !std.meta.eql(a.clip, b.clip)) return false;
            // Child edits own their damage. Updated aggregate bounds alone do
            // not turn an unchanged group boundary into a whole-group repaint.
            return a.command == .push_opacity or a.command == .pop_opacity or std.meta.eql(a.bounds, b.bounds);
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
    regions: Regions = .{},
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

    /// Grows both draw buffers to `capacity`, keeping the previous frame.
    pub fn reserve(self: *Tracker, capacity: usize) !void {
        if (capacity > self.previous.len) self.previous = try self.allocator.realloc(self.previous, capacity);
        if (capacity > self.candidate.len) self.candidate = try self.allocator.realloc(self.candidate, capacity);
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
        var groups: [scene.max_opacity_depth]struct { draw: usize, bounds: ?RectI = null } = undefined;
        var group_depth: usize = 0;
        const empty: RectI = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        for (commands) |command| {
            var clip_change: ?RectI = null;
            switch (command) {
                .push_opacity => {
                    if (group_depth == groups.len) return error.OpacityStackOverflow;
                    groups[group_depth] = .{ .draw = self.candidate_count };
                    group_depth += 1;
                    clip_change = empty;
                },
                .pop_opacity => {
                    if (group_depth == 0) return error.UnbalancedOpacityStack;
                    group_depth -= 1;
                    const group = groups[group_depth];
                    clip_change = group.bounds orelse empty;
                    self.candidate[group.draw].bounds = clip_change.?;
                    if (group_depth != 0) include(&groups[group_depth - 1].bounds, clip_change.?);
                },
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
            // Only actual paint contributes, not clip-boundary bookkeeping.
            // Child ink includes overflow and shadows, including nested groups.
            if (group_depth != 0 and clip_change == null) include(&groups[group_depth - 1].bounds, bounds);
            // Keep empty paragraph snapshots aligned when text appears or is
            // deleted, rather than treating those edits as command insertion.
            if (bounds.isEmpty() and !has_lines and command != .push_opacity and command != .pop_opacity) continue;
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
        if (group_depth != 0) return error.UnbalancedOpacityStack;
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
        self.regions = .{};
        if (old_end - start == new_end - start) {
            for (old[start..old_end], new[start..new_end]) |before, after| {
                if (Draw.equal(before, after)) continue;
                if (before.lines != null and after.lines != null and std.meta.eql(before.clip, after.clip)) {
                    self.compareLines(before.lines.?, after.lines.?);
                    continue;
                }
                self.regions.add(before.bounds);
                self.regions.add(after.bounds);
            }
        } else {
            for (old[start..old_end]) |draw| self.regions.add(draw.bounds);
            for (new[start..new_end]) |draw| self.regions.add(draw.bounds);
        }
        return .{ .regions = self.regions.slice() };
    }

    fn compareLines(self: *Tracker, before: LineRange, after: LineRange) void {
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
            self.regions.add(a.bounds);
            self.regions.add(b.bounds);
        }
        for (old[paired..]) |line| self.regions.add(line.bounds);
        for (new[paired..]) |line| self.regions.add(line.bounds);
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

test "damage regions merge transitively and bound fragmentation without losing coverage" {
    var regions = Regions.init(&.{
        .{ .x = 5, .y = 0, .width = 2, .height = 1 },
        .{ .x = 0, .y = 5, .width = 10, .height = 2 },
    });
    try std.testing.expectEqual(@as(usize, 2), regions.count);
    regions.add(.{ .x = 0, .y = 0, .width = 2, .height = 6 });
    try std.testing.expectEqualSlices(RectI, &.{.{ .x = 0, .y = 0, .width = 10, .height = 7 }}, regions.slice());
    regions = .{};
    for (0..Regions.capacity) |i| regions.add(.{ .x = @intCast(i * 3), .y = 9, .width = 1, .height = 1 });
    try std.testing.expectEqual(@as(usize, Regions.capacity), regions.count);
    regions.add(.{ .x = 24, .y = 9, .width = 1, .height = 1 });
    try std.testing.expectEqualSlices(RectI, &.{.{ .x = 0, .y = 9, .width = 25, .height = 1 }}, regions.slice());

    // Check every added pixel remains covered exactly once, including bounding
    // merges that create intersections and repeated overflow of the cap.
    var random = std.Random.DefaultPrng.init(0x726567696f6e);
    var covered = [_]bool{false} ** (32 * 24);
    regions = .{};
    for (0..200) |_| {
        const rect: RectI = .{
            .x = random.random().intRangeLessThan(i32, 0, 28),
            .y = random.random().intRangeLessThan(i32, 0, 20),
            .width = random.random().intRangeAtMost(u32, 0, 4),
            .height = random.random().intRangeAtMost(u32, 0, 4),
        };
        regions.add(rect);
        for (0..24) |y| for (0..32) |x| {
            const pixel: RectI = .{ .x = @intCast(x), .y = @intCast(y), .width = 1, .height = 1 };
            covered[y * 32 + x] = covered[y * 32 + x] or !RectI.intersect(rect, pixel).isEmpty();
            var count: usize = 0;
            for (regions.slice()) |region| if (!RectI.intersect(region, pixel).isEmpty()) {
                count += 1;
            };
            try std.testing.expect(count <= 1);
            if (covered[y * 32 + x]) try std.testing.expectEqual(@as(usize, 1), count);
        };
    }
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
    try std.testing.expectEqualSlices(RectI, &.{ small, .{ .x = 24, .y = 11, .width = 13, .height = 9 } }, (try tracker.compare(&commands, viewport)).regions);
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
    try std.testing.expectEqualSlices(RectI, &.{
        .{ .x = 10, .y = 10, .width = 7, .height = 9 },
        .{ .x = 25, .y = 10, .width = 12, .height = 9 },
    }, (try tracker.compare(&commands, viewport)).regions);
    // This candidate was never presented; damage is still relative to x=5.
    commands[2].solid_rectangle.bounds.x = 45;
    try std.testing.expectEqualSlices(RectI, &.{
        .{ .x = 10, .y = 10, .width = 7, .height = 9 },
        .{ .x = 45, .y = 10, .width = 12, .height = 9 },
    }, (try tracker.compare(&commands, viewport)).regions);
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

test "opacity damage follows child extents without inflating internal edits" {
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 100, .height = 80 };
    const small: RectI = .{ .x = 5, .y = 7, .width = 8, .height = 6 };
    const distant: RectI = .{ .x = 60, .y = 50, .width = 9, .height = 11 };
    var commands = [_]scene.Command{
        .{ .push_opacity = 32768 },
        .{ .solid_rectangle = .{ .bounds = small, .color = .rgba(255, 0, 0, 255) } },
        .{ .push_opacity = 16384 },
        .{ .solid_rectangle = .{ .bounds = distant, .color = .rgba(0, 255, 0, 255) } },
        .pop_opacity,
        .pop_opacity,
    };
    var tracker = try Tracker.init(std.testing.allocator, commands.len);
    defer tracker.deinit();
    _ = try tracker.compare(&commands, viewport);
    tracker.submitted();
    commands[0].push_opacity = 12345;
    try std.testing.expectEqualSlices(RectI, &.{.{ .x = 5, .y = 7, .width = 64, .height = 54 }}, (try tracker.compare(&commands, viewport)).regions);
    commands[0].push_opacity = 32768;
    commands[2].push_opacity = 0;
    try std.testing.expectEqualSlices(RectI, &.{distant}, (try tracker.compare(&commands, viewport)).regions);
    commands[2].push_opacity = 16384;
    commands[1].solid_rectangle.bounds.x = 20;
    try std.testing.expectEqualSlices(RectI, &.{ small, .{ .x = 20, .y = 7, .width = 8, .height = 6 } }, (try tracker.compare(&commands, viewport)).regions);
    // Moving a boundary must invalidate the child that changes isolation.
    commands[1].solid_rectangle.bounds = small;
    std.mem.swap(scene.Command, &commands[3], &commands[4]);
    try std.testing.expectEqualSlices(RectI, &.{distant}, (try tracker.compare(&commands, viewport)).regions);
}

test "opacity changes and moved group boundaries respect the enclosing clip" {
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
