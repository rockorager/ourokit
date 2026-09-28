const std = @import("std");
const Color = @import("../core/color.zig").Color;
const PointF = @import("../core/geometry.zig").PointF;
const RectI = @import("../core/geometry.zig").RectI;
const ParagraphHandle = @import("../text/paragraph_cache.zig").ParagraphHandle;
const ParagraphCache = @import("../text/paragraph_cache.zig").ParagraphCache;
const ShapeHandle = @import("../text/shape_cache.zig").ShapeHandle;
const ShapeCache = @import("../text/shape_cache.zig").ShapeCache;
const ImageHandle = @import("../image/cache.zig").ImageHandle;
const ImageCache = @import("../image/cache.zig").Cache;
const paths = @import("../path/root.zig");
const shadows = @import("../shadow/root.zig");
const paint = @import("../paint/root.zig");

pub const DamageTracker = @import("damage.zig").Tracker;

pub const Shadow = struct {
    shape: shadows.Shape,
    /// Complete shadow extent including blur support, not the box's hit bounds.
    bounds: RectI,
    color: Color,
};

/// The display list borrows immutable native geometry; Frame retains it.
/// Identity is copied so damage history never needs to dereference old paths.
pub const Path = struct {
    path: *const paths.Path,
    identity: u64,
    origin: PointF,
    scale: f32,
    bounds: RectI,
    color: Color,
    /// Overrides color when present; endpoints are absolute device pixels.
    gradient: ?paint.LinearGradient = null,
};

pub const Image = struct {
    image: ImageHandle,
    bounds: RectI,
    fit: @import("../image/pixels.zig").Fit = .contain,
};

pub const BlendMode = enum {
    /// Replace destination pixels with the premultiplied source.
    source,
    /// Premultiplied Porter-Duff source-over in linear-light sRGB.
    source_over,
};

pub const max_clip_depth = 64;

/// Device-space, per-draw antialiased child clip; not an isolated layer.
pub const RoundedClip = struct {
    bounds: RectI,
    corner_radius: u32,

    /// Shared CPU/GPU contract: strict separate binary32 operations, nearest
    /// A8 coverage. Nested masks multiply outer-to-inner with (a*b+127)/255.
    pub fn coverage(self: RoundedClip, x: usize, y: usize) u8 {
        @setFloatMode(.strict);
        if (self.bounds.isEmpty()) return 0;
        const left: f32 = @floatFromInt(self.bounds.x);
        const top: f32 = @floatFromInt(self.bounds.y);
        const width: f32 = @floatFromInt(self.bounds.width);
        const height: f32 = @floatFromInt(self.bounds.height);
        const px: f32 = @as(f32, @floatFromInt(x)) + 0.5;
        const py: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        const radius: f32 = @floatFromInt(@min(self.corner_radius, @min(self.bounds.width, self.bounds.height) / 2));
        if (radius == 0) return if (px >= left and px < left + width and py >= top and py < top + height) 255 else 0;
        const half_width = width * 0.5;
        const half_height = height * 0.5;
        const dx = @abs(px - (left + half_width)) - (half_width - radius);
        const dy = @abs(py - (top + half_height)) - (half_height - radius);
        const ox = @max(dx, 0);
        const oy = @max(dy, 0);
        const square_x = ox * ox;
        const square_y = oy * oy;
        const outside = @sqrt(square_x + square_y);
        const distance = outside + @min(@max(dx, dy), 0) - radius;
        const alpha = std.math.clamp(0.5 - distance, 0, 1);
        const scaled = alpha * 255;
        return @intFromFloat(@floor(scaled + 0.5));
    }
};

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
    /// Overrides background when present; endpoints are absolute device pixels.
    background_gradient: ?paint.LinearGradient = null,
    border_color: ?Color = null,
    border_width: u32 = 0,
    corner_radius: u32 = 0,
    blend: BlendMode = .source_over,

    pub fn backgroundIsOpaque(self: DecoratedRectangle) bool {
        if (self.background_gradient) |gradient| return gradient.isOpaque();
        return if (self.background) |color| color.a == 255 else false;
    }
};

/// Renderer-neutral painting values and immutable native resources. No Lua or
/// plugin callbacks. Clips affect subsequent drawing until `pop_clip`.
pub const Command = union(enum) {
    clear: Color,
    push_clip_rect: RectI,
    push_clip_rounded: RoundedClip,
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
    image: Image,
    path: Path,
    shadow: Shadow,
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

    /// Conservative proof for a reconstructed scene, independent of damage.
    /// A clear or full opaque rectangle establishes every pixel. Source-over
    /// preserves opacity; source replacement can punch holes in it.
    /// This is not a promise about an incremental batch over unknown storage.
    pub fn isOpaque(self: DisplayList, bounds: RectI) bool {
        if (bounds.isEmpty()) return false;
        var result = false;
        var clips: [max_clip_depth + 1]RectI = undefined;
        clips[0] = bounds;
        var rounded = [_]bool{false} ** (max_clip_depth + 1);
        var depth: usize = 0;
        for (self.commands) |command| switch (command) {
            .clear => |color| {
                if (depth != 0) return false;
                result = color.a == 255;
            },
            .push_clip_rect => |clip| {
                if (depth == max_clip_depth) return false;
                clips[depth + 1] = RectI.intersect(clips[depth], clip);
                rounded[depth + 1] = rounded[depth];
                depth += 1;
            },
            .push_clip_rounded => |clip| {
                if (depth == max_clip_depth) return false;
                clips[depth + 1] = RectI.intersect(clips[depth], clip.bounds);
                rounded[depth + 1] = true;
                depth += 1;
            },
            .pop_clip => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .solid_rectangle => |rect| {
                if (rect.blend == .source and rect.color.a != 255) result = false;
                if (!rounded[depth] and rect.color.a == 255 and std.meta.eql(RectI.intersect(rect.bounds, clips[depth]), bounds)) result = true;
            },
            .decorated_rectangle => |rect| {
                if (rect.blend == .source) result = false;
                // Rounded corners and translucent borders do not cover every
                // pixel. Do not infer opacity from just the background alpha.
                if (!rounded[depth] and rect.corner_radius == 0 and rect.backgroundIsOpaque() and
                    (rect.border_color == null or rect.border_color.?.a == 255) and
                    std.meta.eql(RectI.intersect(rect.bounds, clips[depth]), bounds)) result = true;
            },
            .glyph_run, .paragraph, .image, .path, .shadow => {},
        };
        return result and depth == 0;
    }

    pub fn validate(self: DisplayList) !void {
        var depth: usize = 0;
        for (self.commands) |command| switch (command) {
            .clear => if (depth != 0) return error.ClearInsideClip,
            .push_clip_rect, .push_clip_rounded => {
                if (depth == max_clip_depth) return error.ClipStackOverflow;
                depth += 1;
            },
            .pop_clip => {
                if (depth == 0) return error.UnbalancedClipStack;
                depth -= 1;
            },
            .solid_rectangle => {},
            .image => |value| if (value.image.generation == 0) return error.InvalidImage,
            .path => |value| {
                if (value.identity == 0 or value.identity != value.path.identity or
                    !std.meta.eql(value.bounds, try paths.deviceBounds(value.path, value.origin, value.scale)))
                    return error.InvalidPath;
                if (value.gradient) |gradient| try gradient.validate();
            },
            .shadow => |value| {
                if (!std.meta.eql(value.bounds, try shadows.deviceBounds(value.shape)))
                    return error.InvalidShadow;
            },
            .decorated_rectangle => |rectangle| {
                if (rectangle.background_gradient) |gradient| try gradient.validate();
                if (rectangle.background == null and rectangle.background_gradient == null and rectangle.border_color == null)
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
        .push_clip_rounded => return false,
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
            if (rectangle.background == null and rectangle.background_gradient == null) return false;
            const fully_opaque = rectangle.blend == .source or
                (rectangle.backgroundIsOpaque() and
                    (rectangle.border_color == null or rectangle.border_color.?.a == 255));
            return fully_opaque and contains(covered, bounds);
        },
        .glyph_run => if (!clips[depth].isEmpty()) return false,
        .paragraph => if (!clips[depth].isEmpty()) return false,
        .image => |value| if (!RectI.intersect(value.bounds, clips[depth]).isEmpty()) return false,
        .path => |value| if (!RectI.intersect(value.bounds, clips[depth]).isEmpty()) return false,
        .shadow => |value| if (!RectI.intersect(value.bounds, clips[depth]).isEmpty()) return false,
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
    image_cache: ?*ImageCache,
    image_leases: []const ImageHandle,
    full_damage: bool,

    pub const ResourceCaches = struct {
        shapes: ?*ShapeCache = null,
        paragraphs: ?*ParagraphCache = null,
        images: ?*ImageCache = null,
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
        var image_count: usize = 0;
        for (commands) |command| switch (command) {
            .glyph_run => shape_count += 1,
            .paragraph => paragraph_count += 1,
            .image => image_count += 1,
            else => {},
        };
        if ((shape_count != 0 and caches.shapes == null) or
            (paragraph_count != 0 and caches.paragraphs == null) or
            (image_count != 0 and caches.images == null))
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
        const image_leases = try allocator.alloc(ImageHandle, image_count);
        errdefer allocator.free(image_leases);
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
        var images_retained: usize = 0;
        errdefer if (caches.images) |cache| for (image_leases[0..images_retained]) |handle|
            cache.release(handle) catch unreachable;
        if (caches.images) |cache| for (commands) |command| switch (command) {
            .image => |value| {
                try cache.retain(value.image);
                image_leases[images_retained] = value.image;
                images_retained += 1;
            },
            else => {},
        };
        // No fallible operations remain after acquiring these native leases.
        for (owned_commands) |command| switch (command) {
            .path => |value| @constCast(value.path).retain(),
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
            .image_cache = caches.images,
            .image_leases = image_leases,
            .full_damage = full_damage,
        };
    }

    pub fn deinit(self: *Frame) void {
        for (self.command_storage) |command| switch (command) {
            .path => |value| @constCast(value.path).release(),
            else => {},
        };
        if (self.shape_cache) |cache| for (self.shape_leases) |handle|
            cache.release(handle) catch unreachable;
        if (self.paragraph_cache) |cache| for (self.paragraph_leases) |handle|
            cache.release(handle) catch unreachable;
        if (self.image_cache) |cache| for (self.image_leases) |handle|
            cache.release(handle) catch unreachable;
        self.allocator.free(self.image_leases);
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

test "frame owns image leases and rolls back partial resource acquisition" {
    var cache = try ImageCache.init(std.testing.allocator, 1);
    defer cache.deinit();
    const handle = try cache.insert(.{
        .allocator = std.testing.allocator,
        .pixels = try std.testing.allocator.dupe(u8, &.{ 17, 31, 63, 127 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = 1,
        .intrinsic_height = 1,
    });
    const command: Command = .{ .image = .{ .image = handle, .bounds = .{ .x = 0, .y = 0, .width = 4, .height = 4 } } };
    const commands = [_]Command{ command, command };
    try std.testing.expectError(error.ResourceLeaseRequired, Frame.init(std.testing.allocator, &commands, .full));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseImageFrameAllocationFailure, .{ &cache, &commands });
    var invalid = commands;
    invalid[1].image.image.generation += 1;
    try std.testing.expectError(error.StaleImageHandle, Frame.initWithResources(std.testing.allocator, &invalid, .full, .{ .images = &cache }));
    {
        var frame = try Frame.initWithResources(std.testing.allocator, &commands, .full, .{ .images = &cache });
        defer frame.deinit();
        try cache.release(handle);
        try std.testing.expectEqualSlices(u8, &.{ 17, 31, 63, 127 }, (try cache.get(handle)).pixels);
        try std.testing.expectEqual(@as(usize, 2), frame.image_leases.len);
    }
    // Any leaked lease from the failed frame would keep this handle alive.
    try std.testing.expectError(error.StaleImageHandle, cache.get(handle));
}

fn exerciseImageFrameAllocationFailure(allocator: std.mem.Allocator, cache: *ImageCache, commands: []const Command) !void {
    var frame = try Frame.initWithResources(allocator, commands, .full, .{ .images = cache });
    defer frame.deinit();
}

test "opacity proof rejects source holes regardless of damage" {
    const bounds: RectI = .{ .x = 3, .y = 1, .width = 2, .height = 4 };
    const extent: RectI = .{ .x = 0, .y = 0, .width = 9, .height = 7 };
    var commands = [_]Command{
        .{ .clear = Color.rgba(19, 27, 41, 255) },
        .{ .push_clip_rect = bounds },
        .{ .solid_rectangle = .{ .bounds = bounds, .color = Color.rgba(200, 71, 5, 128) } },
        .{ .decorated_rectangle = .{ .bounds = bounds, .background = Color.rgba(20, 40, 80, 64), .corner_radius = 1 } },
        .pop_clip,
    };
    const list: DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{} } };
    try std.testing.expect(list.isOpaque(extent));
    try std.testing.expect(!(DisplayList{ .commands = commands[1..] }).isOpaque(extent));
    commands[2].solid_rectangle.blend = .source;
    try std.testing.expect(!list.isOpaque(extent));
    commands[2].solid_rectangle.color.a = 255;
    try std.testing.expect(list.isOpaque(extent));
    commands[3].decorated_rectangle.blend = .source;
    try std.testing.expect(!list.isOpaque(extent));
    commands[3].decorated_rectangle.blend = .source_over;
    commands[0].clear.a = 254;
    try std.testing.expect(!list.isOpaque(extent));
    commands[0].clear.a = 0;
    try std.testing.expect(!list.isOpaque(extent));
}

test "opacity proof recognizes retained root coverage but not gaps clips or rounded corners" {
    const extent: RectI = .{ .x = 0, .y = 0, .width = 13, .height = 7 };
    var commands = [_]Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) },
        .{ .push_clip_rect = extent },
        .{ .solid_rectangle = .{ .bounds = extent, .color = Color.rgba(254, 247, 255, 255) } },
        .pop_clip,
    };
    const list: DisplayList = .{ .commands = &commands };
    try std.testing.expect(list.isOpaque(extent));
    try std.testing.expect((DisplayList{ .commands = commands[1..] }).isOpaque(extent));
    commands[1].push_clip_rect.width -= 1;
    try std.testing.expect(!list.isOpaque(extent));
    commands[1].push_clip_rect = extent;
    commands[2].solid_rectangle.bounds.y = 1;
    try std.testing.expect(!list.isOpaque(extent));
    commands[2] = .{ .decorated_rectangle = .{ .bounds = extent, .background = Color.rgba(254, 247, 255, 255), .corner_radius = 1 } };
    try std.testing.expect(!list.isOpaque(extent));
    commands[2].decorated_rectangle.corner_radius = 0;
    try std.testing.expect(list.isOpaque(extent));
    commands[2].decorated_rectangle.border_width = 1;
    commands[2].decorated_rectangle.border_color = Color.rgba(1, 2, 3, 254);
    try std.testing.expect(!list.isOpaque(extent));
}

test "path frames own geometry and damage never resolves released paths" {
    const allocator = std.testing.allocator;
    const geometry = [_]paths.Command{
        .{ .move = .{ .x = 3, .y = 2 } },
        .{ .line = .{ .x = 17, .y = 5 } },
        .{ .line = .{ .x = 7, .y = 13 } },
        .close,
    };
    const path = try paths.Path.create(allocator, &geometry, .{ .fill = .nonzero });
    var initial_owned = true;
    defer if (initial_owned) path.release();
    const origin: PointF = .{ .x = -1.25, .y = 2.5 };
    var commands = [_]Command{.{ .path = .{
        .path = path,
        .identity = path.identity,
        .origin = origin,
        .scale = 1.5,
        .bounds = try paths.deviceBounds(path, origin, 1.5),
        .color = Color.rgba(13, 170, 31, 128),
    } }};
    try std.testing.checkAllAllocationFailures(allocator, testPathFrameAllocation, .{&commands});
    var frame = try Frame.init(allocator, &commands, .full);
    var frame_owned = true;
    defer if (frame_owned) frame.deinit();
    path.release();
    initial_owned = false;
    var cache = paths.MaskCache.init(allocator);
    defer cache.deinit();
    const value = frame.command_storage[0].path;
    const mask = try cache.get(value.path, value.origin, value.scale);
    try std.testing.expect(std.mem.indexOfScalar(u8, mask.pixels, 255) != null);
    try frame.displayList().validate();
    try std.testing.expect(!frame.displayList().isOpaque(value.bounds));
    var tracker = try DamageTracker.init(allocator, 1);
    defer tracker.deinit();
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 64, .height = 48 };
    _ = try tracker.compare(frame.command_storage, viewport);
    tracker.submitted();
    try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(frame.command_storage, viewport)).regions.len);
    frame.deinit(); // History still contains the freed address but never reads it.
    frame_owned = false;
    const replacement = try paths.Path.create(allocator, &geometry, .{ .fill = .nonzero });
    defer replacement.release();
    try std.testing.expect(replacement.identity != value.identity);
    commands[0].path.path = replacement;
    commands[0].path.identity = replacement.identity;
    const damage = try tracker.compare(&commands, viewport);
    try std.testing.expectEqual(@as(usize, 1), damage.regions.len);
    try std.testing.expectEqual(RectI.intersect(value.bounds, viewport), damage.regions[0]);
    commands[0].path.bounds.width += 1;
    try std.testing.expectError(error.InvalidPath, (DisplayList{ .commands = &commands }).validate());
}

fn testPathFrameAllocation(allocator: std.mem.Allocator, commands: []const Command) !void {
    var frame = try Frame.init(allocator, commands, .full);
    defer frame.deinit();
    try frame.displayList().validate();
}

test "gradient frames copy values and damage opacity and occlusion follow paint changes" {
    const viewport: RectI = .{ .x = 3, .y = 5, .width = 17, .height = 11 };
    const gradient = try paint.LinearGradient.init(.{}, .{ .x = 20 }, &.{
        .{ .offset = 0, .color = Color.rgba(0, 0, 0, 255) },
        .{ .offset = 1, .color = Color.rgba(255, 255, 255, 255) },
    });
    var commands = [_]Command{.{ .decorated_rectangle = .{
        .bounds = viewport,
        .background = Color.rgba(255, 0, 0, 255),
        .background_gradient = gradient,
    } }};
    const list: DisplayList = .{ .commands = &commands };
    try list.validate();
    try std.testing.expect(list.isOpaque(viewport));
    try std.testing.expect(occludedByNextDraw(&commands, &.{viewport}, viewport));
    var frame = try Frame.init(std.testing.allocator, &commands, .full);
    defer frame.deinit();
    var tracker = try DamageTracker.init(std.testing.allocator, 1);
    defer tracker.deinit();
    _ = try tracker.compare(&commands, viewport);
    tracker.submitted();
    commands[0].decorated_rectangle.background_gradient.?.end.x = 23;
    try std.testing.expectEqual(viewport, (try tracker.compare(&commands, viewport)).regions[0]);
    commands[0].decorated_rectangle.background_gradient = gradient;
    try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(&commands, viewport)).regions.len);
    commands[0].decorated_rectangle.background_gradient.?.stops[1].color.a = 0;
    try std.testing.expectEqual(viewport, (try tracker.compare(&commands, viewport)).regions[0]);
    // The optional gradient overrides even an opaque legacy background.
    try std.testing.expect(!list.isOpaque(viewport));
    try std.testing.expect(!occludedByNextDraw(&commands, &.{viewport}, viewport));
    try std.testing.expect(frame.displayList().isOpaque(viewport));
    try std.testing.expectEqual(gradient, frame.command_storage[0].decorated_rectangle.background_gradient.?);
    commands[0].decorated_rectangle.background_gradient.?.count = 1;
    try std.testing.expectError(error.InvalidGradient, list.validate());
}

test "rounded clip coverage clamps radius and cannot establish rectangular opacity" {
    const bounds: RectI = .{ .x = 2, .y = 3, .width = 13, .height = 11 };
    const clip: RoundedClip = .{ .bounds = bounds, .corner_radius = 500 };
    // Radius clamps to5, not5.5. Independent circle distances at pixel centers:
    // sqrt(2.5^2+4.5^2) =>90/255, sqrt(3.5^2+3.5^2) =>140/255.
    try std.testing.expectEqual(@as(u8, 0), clip.coverage(2, 3));
    try std.testing.expectEqual(@as(u8, 90), clip.coverage(4, 3));
    try std.testing.expectEqual(@as(u8, 140), clip.coverage(3, 4));
    try std.testing.expectEqual(@as(u8, 255), clip.coverage(8, 7));
    try std.testing.expectEqual(@as(u8, 0), clip.coverage(15, 7));
    try std.testing.expectEqual(@as(u8, 255), (RoundedClip{ .bounds = bounds, .corner_radius = 0 }).coverage(2, 3));
    try std.testing.expectEqual(@as(u8, 0), (RoundedClip{ .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 9 }, .corner_radius = 4 }).coverage(0, 0));
    var commands = [_]Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) },
        .{ .push_clip_rounded = clip },
        .{ .push_clip_rect = bounds },
        .{ .solid_rectangle = .{ .bounds = bounds, .color = Color.rgba(255, 255, 255, 255) } },
        .pop_clip,
        .pop_clip,
    };
    const list: DisplayList = .{ .commands = &commands };
    try list.validate();
    try std.testing.expect(!list.isOpaque(bounds));
    try std.testing.expect(!occludedByNextDraw(commands[1..], &.{bounds}, bounds));
    commands[0].clear.a = 255;
    try std.testing.expect(list.isOpaque(bounds));
    commands[3].solid_rectangle.blend = .source;
    commands[3].solid_rectangle.color.a = 0;
    try std.testing.expect(!list.isOpaque(bounds));
    var frame = try Frame.init(std.testing.allocator, &commands, .full);
    defer frame.deinit();
    commands[1].push_clip_rounded.corner_radius = 0;
    try std.testing.expectEqual(@as(u32, 500), frame.command_storage[1].push_clip_rounded.corner_radius);
    try std.testing.expectError(error.ClearInsideClip, (DisplayList{ .commands = &.{ commands[1], commands[0], .pop_clip } }).validate());
    try std.testing.expectError(error.UnbalancedClipStack, (DisplayList{ .commands = &.{commands[1]} }).validate());
    const too_deep = [_]Command{commands[1]} ** (max_clip_depth + 1);
    try std.testing.expectError(error.ClipStackOverflow, (DisplayList{ .commands = &too_deep }).validate());
}
