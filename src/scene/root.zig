const std = @import("std");
const Color = @import("../core/color.zig").Color;
const PointF = @import("../core/geometry.zig").PointF;
const RectI = @import("../core/geometry.zig").RectI;
const ParagraphHandle = @import("../text/paragraph_cache.zig").ParagraphHandle;
const ParagraphCache = @import("../text/paragraph_cache.zig").ParagraphCache;
const ShapeHandle = @import("../text/shape_cache.zig").ShapeHandle;
const ShapeCache = @import("../text/shape_cache.zig").ShapeCache;

pub const BlendMode = enum {
    /// Replace destination pixels with the premultiplied source.
    source,
    /// Premultiplied Porter-Duff source-over in encoded sRGB channels.
    source_over,
};

pub const max_clip_depth = 64;

pub const GlyphRun = struct {
    shape: ShapeHandle,
    origin: PointF,
    scale: f32,
    color: Color,
};

pub const Paragraph = struct {
    layout: ParagraphHandle,
    /// Device-space top-left origin of the laid-out paragraph.
    origin: PointF,
    scale: f32,
    color: Color,
};

pub const DecoratedRectangle = struct {
    bounds: RectI,
    background: ?Color = null,
    border_color: ?Color = null,
    border_width: u32 = 0,
    corner_radius: u32 = 0,
    blend: BlendMode = .source_over,
};

/// Renderer-neutral, value-only painting vocabulary. Clip commands are
/// balanced and affect subsequent drawing until `pop_clip`.
pub const Command = union(enum) {
    clear: Color,
    push_clip_rect: RectI,
    pop_clip,
    solid_rectangle: struct {
        bounds: RectI,
        color: Color,
        blend: BlendMode = .source_over,
    },
    decorated_rectangle: DecoratedRectangle,
    /// One immutable, already-shaped itemized run. `origin` is the device-space
    /// baseline and `scale` converts the run's logical positions to pixels.
    glyph_run: GlyphRun,
    /// Immutable positioned lines. Text policy and visual ordering are already
    /// complete; renderers only rasterize the referenced glyph sequence.
    paragraph: Paragraph,
};

pub const Damage = union(enum) {
    full,
    /// Device-pixel regions to redraw. Overlap is valid; backends may
    /// canonicalize it. An empty slice means that no pixels need rendering.
    regions: []const RectI,
};

/// A borrowed immutable command batch. This view is suitable for synchronous
/// consumption. Asynchronous backends retain the owning `Frame`, not this view.
pub const DisplayList = struct {
    commands: []const Command,
    damage: Damage = .full,

    pub fn init(commands: []const Command) DisplayList {
        return .{ .commands = commands };
    }

    pub fn validate(self: DisplayList) !void {
        var depth: usize = 0;
        for (self.commands) |command| switch (command) {
            .clear => if (depth != 0) return error.ClearInsideClip,
            .push_clip_rect => depth += 1,
            .pop_clip => {
                if (depth == 0) return error.UnbalancedClipStack;
                depth -= 1;
            },
            .solid_rectangle => {},
            .decorated_rectangle => |rectangle| {
                if (rectangle.background == null and rectangle.border_color == null)
                    return error.EmptyDecoratedRectangle;
                if ((rectangle.border_width == 0) != (rectangle.border_color == null))
                    return error.InvalidDecoratedRectangleBorder;
            },
            .glyph_run => |run| {
                if (run.shape.generation == 0 or
                    !std.math.isFinite(run.origin.x) or
                    !std.math.isFinite(run.origin.y) or
                    !std.math.isFinite(run.scale) or run.scale <= 0)
                    return error.InvalidGlyphRun;
            },
            .paragraph => |value| {
                if (value.layout.generation == 0 or
                    !std.math.isFinite(value.origin.x) or
                    !std.math.isFinite(value.origin.y) or
                    !std.math.isFinite(value.scale) or value.scale <= 0)
                    return error.InvalidParagraph;
            },
        };
        if (depth != 0) return error.UnbalancedClipStack;
        switch (self.damage) {
            .full => {},
            .regions => |regions| for (regions, 0..) |region, index| {
                if (region.isEmpty()) continue;
                for (regions[index + 1 ..]) |other| {
                    if (!RectI.intersect(region, other).isEmpty()) return error.OverlappingDamage;
                }
            },
        }
    }
};

/// Returns whether the next non-empty draw completely replaces `bounds`.
/// Renderers use this while walking a display list to avoid issuing work whose
/// result cannot contribute to the frame. Restricting the lookahead to the
/// next draw keeps the pass linear; chains of covering draws are still culled.
pub fn occludedByNextDraw(
    remaining: []const Command,
    active_clips: []const RectI,
    bounds: RectI,
) bool {
    if (bounds.isEmpty()) return true;
    std.debug.assert(active_clips.len > 0 and active_clips.len <= max_clip_depth + 1);
    var clips: [max_clip_depth + 1]RectI = undefined;
    @memcpy(clips[0..active_clips.len], active_clips);
    var depth = active_clips.len - 1;
    for (remaining) |command| switch (command) {
        .clear => return contains(clips[0], bounds),
        .push_clip_rect => |clip| {
            if (depth == max_clip_depth) return false;
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| {
            const covered = RectI.intersect(rectangle.bounds, clips[depth]);
            if (covered.isEmpty()) continue;
            return (rectangle.blend == .source or rectangle.color.a == 255) and
                contains(covered, bounds);
        },
        .decorated_rectangle => |rectangle| {
            if (rectangle.corner_radius != 0) return false;
            const covered = RectI.intersect(rectangle.bounds, clips[depth]);
            if (covered.isEmpty()) continue;
            const background = rectangle.background orelse return false;
            const fully_opaque = rectangle.blend == .source or
                (background.a == 255 and
                    (rectangle.border_color == null or rectangle.border_color.?.a == 255));
            return fully_opaque and contains(covered, bounds);
        },
        .glyph_run => if (!clips[depth].isEmpty()) return false,
        .paragraph => if (!clips[depth].isEmpty()) return false,
    };
    return false;
}

fn contains(outer: RectI, inner: RectI) bool {
    return @as(i64, outer.x) <= inner.x and
        @as(i64, outer.y) <= inner.y and
        @as(i64, outer.x) + outer.width >= @as(i64, inner.x) + inner.width and
        @as(i64, outer.y) + outer.height >= @as(i64, inner.y) + inner.height;
}

/// Frame-owned immutable scene storage. The command and damage copies remain
/// valid across worker-thread rendering or asynchronous backend submission
/// until the frame is explicitly released.
pub const Frame = struct {
    allocator: std.mem.Allocator,
    command_storage: []const Command,
    damage_storage: []const RectI,
    shape_cache: ?*ShapeCache,
    shape_leases: []const ShapeHandle,
    paragraph_cache: ?*ParagraphCache,
    paragraph_leases: []const ParagraphHandle,
    full_damage: bool,

    pub const ResourceCaches = struct {
        shapes: ?*ShapeCache = null,
        paragraphs: ?*ParagraphCache = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        commands: []const Command,
        damage: Damage,
    ) !Frame {
        return initInternal(allocator, commands, damage, .{});
    }

    /// Copies a display list and retains every shape it references. The cache
    /// must outlive the frame; releasing the UI/render-tree references after
    /// this call cannot invalidate asynchronous rendering.
    pub fn initWithShapes(
        allocator: std.mem.Allocator,
        commands: []const Command,
        damage: Damage,
        shape_cache: *ShapeCache,
    ) !Frame {
        return initInternal(allocator, commands, damage, .{ .shapes = shape_cache });
    }

    /// Copies scene storage and leases every referenced text resource. Each
    /// supplied application-owned cache must outlive the frame.
    pub fn initWithResources(
        allocator: std.mem.Allocator,
        commands: []const Command,
        damage: Damage,
        caches: ResourceCaches,
    ) !Frame {
        return initInternal(allocator, commands, damage, caches);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        commands: []const Command,
        damage: Damage,
        caches: ResourceCaches,
    ) !Frame {
        try (DisplayList{ .commands = commands, .damage = damage }).validate();
        var shape_count: usize = 0;
        var paragraph_count: usize = 0;
        for (commands) |command| switch (command) {
            .glyph_run => shape_count += 1,
            .paragraph => paragraph_count += 1,
            else => {},
        };
        if ((shape_count != 0 and caches.shapes == null) or
            (paragraph_count != 0 and caches.paragraphs == null))
            return error.ResourceLeaseRequired;

        const owned_commands = try allocator.dupe(Command, commands);
        errdefer allocator.free(owned_commands);
        const full_damage = damage == .full;
        const regions = switch (damage) {
            .full => try allocator.alloc(RectI, 0),
            .regions => |values| try allocator.dupe(RectI, values),
        };
        errdefer allocator.free(regions);
        const leases = try allocator.alloc(ShapeHandle, shape_count);
        errdefer allocator.free(leases);
        const paragraph_leases = try allocator.alloc(ParagraphHandle, paragraph_count);
        errdefer allocator.free(paragraph_leases);
        var shapes_retained: usize = 0;
        errdefer if (caches.shapes) |cache| for (leases[0..shapes_retained]) |handle|
            cache.release(handle) catch unreachable;
        if (caches.shapes) |cache| for (commands) |command| switch (command) {
            .glyph_run => |run| {
                try cache.retain(run.shape);
                leases[shapes_retained] = run.shape;
                shapes_retained += 1;
            },
            else => {},
        };
        var paragraphs_retained: usize = 0;
        errdefer if (caches.paragraphs) |cache| for (paragraph_leases[0..paragraphs_retained]) |handle|
            cache.release(handle) catch unreachable;
        if (caches.paragraphs) |cache| for (commands) |command| switch (command) {
            .paragraph => |value| {
                try cache.retain(value.layout);
                paragraph_leases[paragraphs_retained] = value.layout;
                paragraphs_retained += 1;
            },
            else => {},
        };
        return .{
            .allocator = allocator,
            .command_storage = owned_commands,
            .damage_storage = regions,
            .shape_cache = caches.shapes,
            .shape_leases = leases,
            .paragraph_cache = caches.paragraphs,
            .paragraph_leases = paragraph_leases,
            .full_damage = full_damage,
        };
    }

    pub fn deinit(self: *Frame) void {
        if (self.shape_cache) |cache| for (self.shape_leases) |handle|
            cache.release(handle) catch unreachable;
        if (self.paragraph_cache) |cache| for (self.paragraph_leases) |handle|
            cache.release(handle) catch unreachable;
        self.allocator.free(self.paragraph_leases);
        self.allocator.free(self.shape_leases);
        self.allocator.free(self.damage_storage);
        self.allocator.free(self.command_storage);
        self.* = undefined;
    }

    pub fn displayList(self: *const Frame) DisplayList {
        return .{
            .commands = self.command_storage,
            .damage = if (self.full_damage) .full else .{ .regions = self.damage_storage },
        };
    }
};

test "owned frame isolates asynchronous scene lifetime" {
    var commands = [_]Command{.{ .clear = Color.rgba(1, 2, 3, 255) }};
    var damage = [_]RectI{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    var frame = try Frame.init(std.testing.allocator, &commands, .{ .regions = &damage });
    defer frame.deinit();
    commands[0] = .{ .clear = Color.rgba(9, 9, 9, 255) };
    damage[0].x = 99;
    const list = frame.displayList();
    try std.testing.expectEqual(@as(u8, 1), list.commands[0].clear.r);
    try std.testing.expectEqual(@as(i32, 1), list.damage.regions[0].x);
}

test "owned frame leases shapes across asynchronous scene lifetime" {
    const text = @import("../text/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    const shape = try shapes.acquire(.{
        .spec = .{
            .paragraph = "leased",
            .direction = .left_to_right,
            .script = .latin,
            .language = "en",
            .logical_size = 14,
        },
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    const commands = [_]Command{.{ .glyph_run = .{
        .shape = shape,
        .origin = .{ .x = 2, .y = 16 },
        .scale = 1,
        .color = Color.rgba(1, 2, 3, 255),
    } }};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFrameAllocationFailure,
        .{ &shapes, &commands },
    );
    {
        var frame = try Frame.initWithShapes(
            std.testing.allocator,
            &commands,
            .full,
            &shapes,
        );
        defer frame.deinit();
        try shapes.release(shape);
        try fonts.release(font);
        _ = try shapes.get(shape);
        _ = try fonts.get(font);
        try std.testing.expectEqual(shape, frame.displayList().commands[0].glyph_run.shape);
    }
    try std.testing.expectError(error.StaleShape, shapes.get(shape));
    try std.testing.expectError(error.StaleFont, fonts.get(font));
}

fn exerciseFrameAllocationFailure(
    allocator: std.mem.Allocator,
    shapes: *ShapeCache,
    commands: []const Command,
) !void {
    var frame = try Frame.initWithShapes(allocator, commands, .full, shapes);
    defer frame.deinit();
}

test "opaque next draw occludes covered work through clips" {
    const root = RectI{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const commands = [_]Command{
        .{ .push_clip_rect = .{ .x = 10, .y = 10, .width = 20, .height = 20 } },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = 0, .y = 0, .width = 50, .height = 50 },
            .color = Color.rgba(1, 2, 3, 255),
        } },
        .pop_clip,
    };
    try std.testing.expect(occludedByNextDraw(
        &commands,
        &.{root},
        .{ .x = 12, .y = 12, .width = 10, .height = 10 },
    ));
    try std.testing.expect(!occludedByNextDraw(
        &commands,
        &.{root},
        .{ .x = 5, .y = 5, .width = 20, .height = 20 },
    ));
}

test "translucent source-over does not occlude previous work" {
    const root = RectI{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const source_over = [_]Command{.{ .solid_rectangle = .{
        .bounds = root,
        .color = Color.rgba(1, 2, 3, 254),
    } }};
    try std.testing.expect(!occludedByNextDraw(&source_over, &.{root}, root));

    const source = [_]Command{.{ .solid_rectangle = .{
        .bounds = root,
        .color = Color.rgba(1, 2, 3, 0),
        .blend = .source,
    } }};
    try std.testing.expect(occludedByNextDraw(&source, &.{root}, root));
}
