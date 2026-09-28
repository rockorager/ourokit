//! Immutable native geometry and renderer-independent A8 coverage. Path fields
//! are read-only after create; callers must hold a native lease while using a
//! pointer. The cache never retains/dereferences old paths: identities do not
//! repeat, even after the final lease is released. Cache access is single-threaded.
//!
//! Geometry is limited to 4096 drawing/close segments (moves do not count).
//! A draw or close requires a preceding move; close ends that contour, so a
//! subsequent draw requires another move. Consecutive moves and empty contours
//! are accepted. Move-only contours paint nothing. Degenerate fills paint
//! nothing; zero-length stroke segments retain tiny-skia's round/square caps.
//! Bounds use the control-point hull, expanded for stroke caps/joins, not tight
//! curve extrema. Unrepresentable logical bounds are rejected at creation.
//!
//! Device bounds use glyph-compatible nearest-1/64 origin quantization and one
//! pixel of conservative AA padding. Empty geometry has bounds {0,0,0,0} and no
//! pixels; other degenerate geometry may return a transparent padded mask.
//! Dimensions are <=8192 and masks <=16 Mi pixels; cache entries including
//! metadata total <=32 MiB. These limits exclude temporary rasterizer memory.
//! Rust's internal allocations have the same process-OOM policy as resvg image
//! decoding; Zig allocation failures are recoverable and never publish entries.
const std = @import("std");
const geometry = @import("../core/geometry.zig");
/// Cargo-free embeddings can use geometry without linking the path rasterizer.
pub const has_rasterizer = @import("ourokit_build_options").paths;
pub const PointF = geometry.PointF;
pub const RectF = geometry.RectF;
pub const RectI = geometry.RectI;

pub const Command = union(enum) {
    move: PointF,
    line: PointF,
    quadratic: struct { control: PointF, to: PointF },
    cubic: struct { control1: PointF, control2: PointF, to: PointF },
    close,
};
pub const FillRule = enum { nonzero, even_odd };
pub const Stroke = struct {
    width: f32,
    cap: enum { butt, round, square } = .butt,
    join: enum { miter, round, bevel } = .miter,
    miter_limit: f32 = 4,
};
pub const Style = union(enum) { fill: FillRule, stroke: Stroke };

var next_identity = std.atomic.Value(u64).init(1);

pub const Path = struct {
    commands: []const Command,
    style: Style,
    bounds: RectF,
    identity: u64,
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    empty: bool,

    pub fn create(allocator: std.mem.Allocator, commands: []const Command, style: Style) !*Path {
        const bounds = try validate(commands, style);
        const copy = try allocator.dupe(Command, commands);
        errdefer allocator.free(copy);
        const self = try allocator.create(Path);
        errdefer allocator.destroy(self);
        // Saturate instead of wrapping: no identity can alias a stale cache key.
        var identity = next_identity.load(.monotonic);
        while (true) {
            if (identity == std.math.maxInt(u64)) return error.IdentityExhausted;
            identity = next_identity.cmpxchgWeak(identity, identity + 1, .monotonic, .monotonic) orelse break;
        }
        self.* = .{
            .commands = copy,
            .style = style,
            .bounds = bounds orelse .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .identity = identity,
            .allocator = allocator,
            .empty = bounds == null,
        };
        return self;
    }

    pub fn retain(self: *Path) void {
        const previous = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
    }

    pub fn release(self: *Path) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        allocator.free(self.commands);
        allocator.destroy(self);
    }
};

const Hull = struct {
    min_x: f64 = std.math.inf(f64),
    min_y: f64 = std.math.inf(f64),
    max_x: f64 = -std.math.inf(f64),
    max_y: f64 = -std.math.inf(f64),

    fn add(self: *Hull, point: PointF) !void {
        try validPoint(point);
        self.min_x = @min(self.min_x, point.x);
        self.min_y = @min(self.min_y, point.y);
        self.max_x = @max(self.max_x, point.x);
        self.max_y = @max(self.max_y, point.y);
    }
};

fn validPoint(point: PointF) !void {
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidGeometry;
}

fn validate(commands: []const Command, style: Style) !?RectF {
    var padding: f64 = 0;
    switch (style) {
        .fill => {},
        .stroke => |stroke| {
            if (!std.math.isFinite(stroke.width) or stroke.width <= 0 or
                !std.math.isFinite(stroke.miter_limit) or stroke.miter_limit < 1)
                return error.InvalidStroke;
            const reach: f64 = @max(
                if (stroke.join == .miter) @as(f64, stroke.miter_limit) else 1,
                if (stroke.cap == .square) @sqrt(@as(f64, 2)) else 1,
            );
            padding = @as(f64, stroke.width) * 0.5 * reach;
        },
    }
    var hull: Hull = .{};
    var current: ?PointF = null;
    var segments: usize = 0;
    var drew = false;
    for (commands) |command| {
        switch (command) {
            .move => |point| {
                try validPoint(point);
                current = point;
                continue;
            },
            .close => {
                if (current == null) return error.InvalidSequence;
                current = null;
            },
            else => {
                try hull.add(current orelse return error.InvalidSequence);
                switch (command) {
                    .line => |point| current = point,
                    .quadratic => |curve| {
                        try hull.add(curve.control);
                        current = curve.to;
                    },
                    .cubic => |curve| {
                        try hull.add(curve.control1);
                        try hull.add(curve.control2);
                        current = curve.to;
                    },
                    else => unreachable,
                }
                try hull.add(current.?);
                drew = true;
            },
        }
        segments += 1;
        if (segments > 4096) return error.TooManySegments;
    }
    if (!drew) return null;
    if (style == .fill and (hull.min_x == hull.max_x or hull.min_y == hull.max_y)) return null;
    var x = try outward(hull.min_x - padding, false);
    var y = try outward(hull.min_y - padding, false);
    var right = try outward(hull.max_x + padding, true);
    var bottom = try outward(hull.max_y + padding, true);
    // A small stroke at a huge coordinate can be lost even in f64 addition.
    // Still expand its f32 bounds outwards, or reject an unrepresentable edge.
    if (padding > 0) {
        if (x >= hull.min_x) x = try outward(std.math.nextAfter(f64, hull.min_x, -std.math.inf(f64)), false);
        if (y >= hull.min_y) y = try outward(std.math.nextAfter(f64, hull.min_y, -std.math.inf(f64)), false);
        if (right <= hull.max_x) right = try outward(std.math.nextAfter(f64, hull.max_x, std.math.inf(f64)), true);
        if (bottom <= hull.max_y) bottom = try outward(std.math.nextAfter(f64, hull.max_y, std.math.inf(f64)), true);
    }
    return .{
        .x = x,
        .y = y,
        .width = try outward(@as(f64, right) - x, true),
        .height = try outward(@as(f64, bottom) - y, true),
    };
}

fn outward(value: f64, up: bool) !f32 {
    var result: f32 = @floatCast(value);
    if (!std.math.isFinite(result)) return error.InvalidGeometry;
    if ((up and @as(f64, result) < value) or (!up and @as(f64, result) > value)) {
        result = std.math.nextAfter(f32, result, if (up) std.math.inf(f32) else -std.math.inf(f32));
    }
    if (!std.math.isFinite(result)) return error.InvalidGeometry;
    return result;
}

pub const Key = struct {
    identity: u64,
    scale_bits: u32,
    phase_x: u8,
    phase_y: u8,
};
pub const Mask = struct {
    /// Borrowed immutable A8, stride == bounds.width; valid until the next
    /// cache operation. Copy/upload before another get or deinit.
    pixels: []const u8,
    bounds: RectI,
    key: Key,
};

const Position = struct {
    anchor: i32,
    phase: u8,

    fn init(value: f32) !Position {
        if (!std.math.isFinite(value)) return error.InvalidTransform;
        // Match glyph_position.zig's f32 arithmetic, including rounding in the
        // subtraction at negative half-phase boundaries. Use f64 only to check
        // the carried anchor before converting it to i32.
        const floor = @floor(value);
        const fraction: u7 = @intFromFloat(@round((value - floor) * 64));
        const anchor = @as(f64, floor) + @as(f64, @floatFromInt(fraction / 64));
        if (anchor < std.math.minInt(i32) or anchor > std.math.maxInt(i32)) return error.InvalidTransform;
        return .{ .anchor = @intFromFloat(anchor), .phase = fraction % 64 };
    }
};

const Placement = struct {
    key: Key,
    bounds: RectI,
    // Untranslated pixel anchor, shared by every integer translation of a key.
    left: f64,
    top: f64,

    fn init(path: *const Path, origin: PointF, scale: f32) !Placement {
        if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidTransform;
        const x = try Position.init(origin.x);
        const y = try Position.init(origin.y);
        const key: Key = .{ .identity = path.identity, .scale_bits = @bitCast(scale), .phase_x = x.phase, .phase_y = y.phase };
        if (path.empty) return .{ .key = key, .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .left = 0, .top = 0 };
        const px = @as(f64, @floatFromInt(x.phase)) / 64;
        const py = @as(f64, @floatFromInt(y.phase)) / 64;
        const left = @floor(@as(f64, path.bounds.x) * scale + px) - 1;
        const top = @floor(@as(f64, path.bounds.y) * scale + py) - 1;
        const right = @ceil((@as(f64, path.bounds.x) + path.bounds.width) * scale + px) + 1;
        const bottom = @ceil((@as(f64, path.bounds.y) + path.bounds.height) * scale + py) + 1;
        const width = right - left;
        const height = bottom - top;
        if (width <= 0 or height <= 0 or width > 8192 or height > 8192 or width * height > 16 * 1024 * 1024)
            return error.MaskTooLarge;
        const device_x = left + @as(f64, @floatFromInt(x.anchor));
        const device_y = top + @as(f64, @floatFromInt(y.anchor));
        if (device_x < std.math.minInt(i32) or device_y < std.math.minInt(i32) or
            device_x + width > std.math.maxInt(i32) or device_y + height > std.math.maxInt(i32))
            return error.InvalidTransform;
        return .{
            .key = key,
            .bounds = .{ .x = @intFromFloat(device_x), .y = @intFromFloat(device_y), .width = @intFromFloat(width), .height = @intFromFloat(height) },
            .left = left,
            .top = top,
        };
    }
};

/// Same origin quantization, padding and limits as MaskCache.get, without any
/// allocation. The caller must hold a live path lease.
pub fn deviceBounds(path: *const Path, origin: PointF, scale: f32) !RectI {
    return (try Placement.init(path, origin, scale)).bounds;
}

pub const MaskCache = struct {
    allocator: std.mem.Allocator,
    first: ?*Entry = null,
    last: ?*Entry = null,
    bytes: usize = 0,

    const budget = 32 * 1024 * 1024;
    const Entry = struct {
        key: Key,
        pixels: []u8,
        previous: ?*Entry = null,
        next: ?*Entry = null,
    };

    pub fn init(allocator: std.mem.Allocator) MaskCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MaskCache) void {
        while (self.last) |entry| self.evict(entry);
    }

    pub fn get(self: *MaskCache, path: *const Path, origin: PointF, scale: f32) !Mask {
        const placement = try Placement.init(path, origin, scale);
        if (placement.bounds.isEmpty()) return .{ .key = placement.key, .bounds = placement.bounds, .pixels = &.{} };
        if (comptime !has_rasterizer) return error.PathRasterizerDisabled;
        var cursor = self.first;
        while (cursor) |entry| : (cursor = entry.next) {
            if (!std.meta.eql(entry.key, placement.key)) continue;
            self.unlink(entry);
            self.prepend(entry);
            return .{ .key = entry.key, .bounds = placement.bounds, .pixels = entry.pixels };
        }
        // Allocate and rasterize before eviction/publication. A failed request
        // leaves all existing entries untouched and is retryable.
        const pixels = try self.allocator.alloc(u8, @as(usize, placement.bounds.width) * placement.bounds.height);
        errdefer self.allocator.free(pixels);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        try rasterize(self.allocator, path, placement, scale, pixels);
        const charge = pixels.len + @sizeOf(Entry);
        while (self.bytes + charge > budget) self.evict(self.last.?);
        entry.* = .{ .key = placement.key, .pixels = pixels };
        self.prepend(entry);
        self.bytes += charge;
        return .{ .key = entry.key, .bounds = placement.bounds, .pixels = pixels };
    }

    fn unlink(self: *MaskCache, entry: *Entry) void {
        if (entry.previous) |previous| previous.next = entry.next else self.first = entry.next;
        if (entry.next) |next| next.previous = entry.previous else self.last = entry.previous;
    }

    fn prepend(self: *MaskCache, entry: *Entry) void {
        entry.previous = null;
        entry.next = self.first;
        if (self.first) |first| first.previous = entry else self.last = entry;
        self.first = entry;
    }

    fn evict(self: *MaskCache, entry: *Entry) void {
        self.unlink(entry);
        self.bytes -= entry.pixels.len + @sizeOf(Entry);
        self.allocator.free(entry.pixels);
        self.allocator.destroy(entry);
    }
};

// Private bridge ABI. Tags and layout match Rust's repr(C) records. Points are
// transformed with f64 arithmetic to small mask-local device coordinates before
// tiny-skia receives them. Colors never cross this boundary.
const NativeCommand = extern struct { tag: u32, points: [6]f32 = @splat(0) };
const NativeStyle = extern struct { kind: u32, cap: u32 = 0, join: u32 = 0, width: f32 = 0, miter_limit: f32 = 4 };
extern fn ourokit_path_mask([*]const NativeCommand, usize, *const NativeStyle, [*]u8, usize, u32, u32) u32;

fn rasterize(allocator: std.mem.Allocator, path: *const Path, placement: Placement, scale: f32, pixels: []u8) !void {
    const commands = try allocator.alloc(NativeCommand, @min(path.commands.len, 8192));
    defer allocator.free(commands);
    // Omit move-only contours, including their closes, so irrelevant distant
    // moves cannot enlarge the rasterizer's hull or acquire stroke caps.
    var pending: ?PointF = null;
    var count: usize = 0;
    for (path.commands) |command| {
        if (command == .move) {
            pending = command.move;
            continue;
        }
        if (pending) |point| {
            pending = null;
            if (command == .close) continue;
            commands[count] = .{ .tag = 0 };
            commands[count].points[0..2].* = localPoint(point, placement, scale);
            count += 1;
        }
        const out = &commands[count];
        count += 1;
        out.* = .{ .tag = switch (command) {
            .move => 0,
            .line => 1,
            .quadratic => 2,
            .cubic => 3,
            .close => 4,
        } };
        switch (command) {
            .move, .line => |point| out.points[0..2].* = localPoint(point, placement, scale),
            .quadratic => |curve| {
                out.points[0..2].* = localPoint(curve.control, placement, scale);
                out.points[2..4].* = localPoint(curve.to, placement, scale);
            },
            .cubic => |curve| {
                out.points[0..2].* = localPoint(curve.control1, placement, scale);
                out.points[2..4].* = localPoint(curve.control2, placement, scale);
                out.points[4..6].* = localPoint(curve.to, placement, scale);
            },
            .close => {},
        }
    }
    const style: NativeStyle = switch (path.style) {
        .fill => |rule| .{ .kind = if (rule == .nonzero) 0 else 1 },
        .stroke => |stroke| .{
            .kind = 2,
            .width = @floatCast(@as(f64, stroke.width) * scale),
            .cap = switch (stroke.cap) {
                .butt => 0,
                .round => 1,
                .square => 2,
            },
            .join = switch (stroke.join) {
                .miter => 0,
                .round => 1,
                .bevel => 2,
            },
            .miter_limit = stroke.miter_limit,
        },
    };
    switch (ourokit_path_mask(commands.ptr, count, &style, pixels.ptr, pixels.len, placement.bounds.width, placement.bounds.height)) {
        0 => {},
        2 => return error.OutOfMemory,
        else => return error.RasterizationFailed,
    }
}

fn localPoint(point: PointF, placement: Placement, scale: f32) [2]f32 {
    return .{
        @floatCast(@as(f64, point.x) * scale + @as(f64, @floatFromInt(placement.key.phase_x)) / 64 - placement.left),
        @floatCast(@as(f64, point.y) * scale + @as(f64, @floatFromInt(placement.key.phase_y)) / 64 - placement.top),
    };
}

const test_box = [_]Command{
    .{ .move = .{ .x = 0, .y = 0 } },
    .{ .line = .{ .x = 12, .y = 0 } },
    .{ .line = .{ .x = 12, .y = 8 } },
    .{ .line = .{ .x = 0, .y = 8 } },
    .close,
};

fn coverage(mask: Mask, x: i32, y: i32) u8 {
    const column = @as(i64, x) - mask.bounds.x;
    const row = @as(i64, y) - mask.bounds.y;
    if (column < 0 or row < 0 or column >= mask.bounds.width or row >= mask.bounds.height) return 0;
    return mask.pixels[@as(usize, @intCast(row)) * mask.bounds.width + @as(usize, @intCast(column))];
}

test "native path copies commands and independent leases outlive the creator" {
    var commands = test_box;
    const path = try Path.create(std.testing.allocator, &commands, .{ .fill = .nonzero });
    path.retain();
    path.release();
    defer path.release();
    commands[1] = .{ .line = .{ .x = 99 } };
    try std.testing.expectEqual(@as(f32, 12), path.commands[1].line.x);
    try std.testing.expectEqual(RectF{ .x = 0, .y = 0, .width = 12, .height = 8 }, path.bounds);
    if (!has_rasterizer) return;
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const mask = try cache.get(path, .{}, 1);
    try std.testing.expectEqual(@as(u8, 255), coverage(mask, 10, 6));
    try std.testing.expectEqual(@as(u8, 0), coverage(mask, 13, 6));
}

test "native path rejects nonfinite geometry invalid sequencing and stroke parameters" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidSequence, Path.create(a, &.{.{ .line = .{} }}, .{ .fill = .nonzero }));
    try std.testing.expectError(error.InvalidSequence, Path.create(a, &.{.close}, .{ .fill = .nonzero }));
    try std.testing.expectError(error.InvalidSequence, Path.create(a, &.{ .{ .move = .{} }, .close, .{ .line = .{} } }, .{ .fill = .nonzero }));
    try std.testing.expectError(error.InvalidSequence, Path.create(a, &.{ .{ .move = .{} }, .close, .close }, .{ .fill = .nonzero }));
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |invalid| {
        try std.testing.expectError(error.InvalidGeometry, Path.create(a, &.{.{ .move = .{ .x = invalid } }}, .{ .fill = .nonzero }));
        try std.testing.expectError(error.InvalidGeometry, Path.create(a, &.{ .{ .move = .{} }, .{ .quadratic = .{ .control = .{ .y = invalid }, .to = .{} } } }, .{ .fill = .nonzero }));
        try std.testing.expectError(error.InvalidGeometry, Path.create(a, &.{ .{ .move = .{} }, .{ .cubic = .{ .control1 = .{}, .control2 = .{ .x = invalid }, .to = .{} } } }, .{ .fill = .nonzero }));
        try std.testing.expectError(error.InvalidStroke, Path.create(a, &test_box, .{ .stroke = .{ .width = invalid } }));
        try std.testing.expectError(error.InvalidStroke, Path.create(a, &test_box, .{ .stroke = .{ .width = 1, .miter_limit = invalid } }));
    }
    for ([_]f32{ 0, -1 }) |width| try std.testing.expectError(error.InvalidStroke, Path.create(a, &test_box, .{ .stroke = .{ .width = width } }));
    try std.testing.expectError(error.InvalidStroke, Path.create(a, &test_box, .{ .stroke = .{ .width = 1, .miter_limit = 0.99 } }));
    try std.testing.expectError(error.InvalidGeometry, Path.create(a, &.{ .{ .move = .{ .x = -std.math.floatMax(f32) } }, .{ .line = .{ .x = std.math.floatMax(f32), .y = 1 } } }, .{ .fill = .nonzero }));
}

test "native path segment limit accepts its boundary and excludes moves" {
    var commands: [4098]Command = undefined;
    commands[0] = .{ .move = .{} };
    @memset(commands[1..], .{ .line = .{} });
    const path = try Path.create(std.testing.allocator, commands[0..4097], .{ .fill = .nonzero });
    defer path.release();
    try std.testing.expectError(error.TooManySegments, Path.create(std.testing.allocator, &commands, .{ .fill = .nonzero }));
    @memset(&commands, .{ .move = .{} });
    const moves = try Path.create(std.testing.allocator, &commands, .{ .fill = .nonzero });
    defer moves.release();
    try std.testing.expect(moves.empty);
}

test "native path empty contours do not paint or enlarge nonempty geometry" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    for ([_][]const Command{ &.{}, &.{.{ .move = .{} }}, &.{ .{ .move = .{} }, .close }, &.{ .{ .move = .{} }, .{ .line = .{ .x = 4 } } } }) |commands| {
        const path = try Path.create(std.testing.allocator, commands, .{ .fill = .nonzero });
        defer path.release();
        const mask = try cache.get(path, .{ .x = -8, .y = 2 }, 2);
        try std.testing.expectEqual(RectI{ .x = 0, .y = 0, .width = 0, .height = 0 }, mask.bounds);
        try std.testing.expectEqual(@as(usize, 0), mask.pixels.len);
    }
    if (!has_rasterizer) return;
    const commands = [_]Command{ .{ .move = .{ .x = 1e30 } }, .close } ++ test_box ++ [_]Command{.{ .move = .{ .y = -1e30 } }};
    const path = try Path.create(std.testing.allocator, &commands, .{ .fill = .nonzero });
    defer path.release();
    const mask = try cache.get(path, .{}, 1);
    try std.testing.expectEqual(RectI{ .x = -1, .y = -1, .width = 14, .height = 10 }, mask.bounds);
    try std.testing.expectEqual(@as(u8, 255), coverage(mask, 11, 7));
}

test "native path concave fill leaves the notch empty" {
    if (!has_rasterizer) return error.SkipZigTest;
    const path = try Path.create(std.testing.allocator, &.{
        .{ .move = .{} },
        .{ .line = .{ .x = 12 } },
        .{ .line = .{ .x = 12, .y = 4 } },
        .{ .line = .{ .x = 4, .y = 4 } },
        .{ .line = .{ .x = 4, .y = 10 } },
        .{ .line = .{ .y = 10 } },
        .close,
    }, .{ .fill = .nonzero });
    defer path.release();
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const mask = try cache.get(path, .{}, 1);
    try std.testing.expectEqual(@as(u8, 255), coverage(mask, 10, 2));
    try std.testing.expectEqual(@as(u8, 255), coverage(mask, 2, 8));
    try std.testing.expectEqual(@as(u8, 0), coverage(mask, 6, 6));
}

test "native path holes distinguish winding and even odd rules" {
    if (!has_rasterizer) return error.SkipZigTest;
    const inner = [_]Command{
        .{ .move = .{ .x = 3, .y = 2 } },
        .{ .line = .{ .x = 9, .y = 2 } },
        .{ .line = .{ .x = 9, .y = 6 } },
        .{ .line = .{ .x = 3, .y = 6 } },
        .close,
    };
    const reversed = [_]Command{ inner[0], .{ .line = .{ .x = 3, .y = 6 } }, inner[2], .{ .line = .{ .x = 9, .y = 2 } }, .close };
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    for ([_]FillRule{ .nonzero, .even_odd }) |rule| {
        for ([_]bool{ false, true }) |reverse| {
            const commands = test_box ++ (if (reverse) reversed else inner);
            const path = try Path.create(std.testing.allocator, &commands, .{ .fill = rule });
            defer path.release();
            const mask = try cache.get(path, .{}, 1);
            try std.testing.expectEqual(@as(u8, 255), coverage(mask, 1, 4));
            const expected: u8 = if (reverse or rule == .even_odd) 0 else 255;
            try std.testing.expectEqual(expected, coverage(mask, 5, 3));
        }
    }
}

test "native path quadratic and cubic interiors differ from their control hull" {
    if (!has_rasterizer) return error.SkipZigTest;
    const quadratic = try Path.create(std.testing.allocator, &.{
        .{ .move = .{ .y = 10 } },
        .{ .quadratic = .{ .control = .{ .x = 10, .y = -10 }, .to = .{ .x = 20, .y = 10 } } },
        .close,
    }, .{ .fill = .nonzero });
    defer quadratic.release();
    const cubic = try Path.create(std.testing.allocator, &.{
        .{ .move = .{ .y = 12 } },
        .{ .cubic = .{ .control1 = .{ .y = -4 }, .control2 = .{ .x = 24, .y = -4 }, .to = .{ .x = 24, .y = 12 } } },
        .close,
    }, .{ .fill = .nonzero });
    defer cubic.release();
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const q = try cache.get(quadratic, .{}, 1);
    try std.testing.expectEqual(@as(u8, 255), coverage(q, 10, 3));
    try std.testing.expectEqual(@as(u8, 0), coverage(q, 1, 1));
    try std.testing.expectEqual(@as(u8, 0), coverage(q, 10, -3));
    const c = try cache.get(cubic, .{}, 1);
    try std.testing.expectEqual(@as(u8, 255), coverage(c, 12, 3));
    try std.testing.expectEqual(@as(u8, 0), coverage(c, 1, 1));
    try std.testing.expectEqual(@as(u8, 0), coverage(c, 12, -2));
}

test "native path stroke caps and zero length segments have distinct coverage" {
    if (!has_rasterizer) return error.SkipZigTest;
    const line = [_]Command{ .{ .move = .{ .x = 4, .y = 6 } }, .{ .line = .{ .x = 14, .y = 6 } } };
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    for ([_]@FieldType(Stroke, "cap"){ .butt, .round, .square }) |cap| {
        const path = try Path.create(std.testing.allocator, &line, .{ .stroke = .{ .width = 8, .cap = cap } });
        defer path.release();
        const mask = try cache.get(path, .{}, 1);
        try std.testing.expectEqual(@as(u8, 255), coverage(mask, 8, 5));
        try std.testing.expectEqual(@as(u8, if (cap == .butt) 0 else 255), coverage(mask, 2, 5));
        // Even the nearest point of this corner pixel lies outside radius 4.
        try std.testing.expectEqual(@as(u8, if (cap == .square) 255 else 0), coverage(mask, 0, 2));
        const point = try Path.create(std.testing.allocator, &.{ line[0], .{ .line = line[0].move } }, .{ .stroke = .{ .width = 6, .cap = cap } });
        defer point.release();
        const dot = try cache.get(point, .{}, 1);
        try std.testing.expectEqual(@as(u8, if (cap == .butt) 0 else 255), coverage(dot, 4, 6));
    }
}

test "native path joined strokes fill once without translucent alpha seams" {
    if (!has_rasterizer) return error.SkipZigTest;
    const commands = [_]Command{
        .{ .move = .{ .x = 2, .y = 8 } },
        .{ .line = .{ .x = 12, .y = 8 } },
        .{ .line = .{ .x = 12, .y = 2 } },
    };
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    for ([_]@FieldType(Stroke, "join"){ .miter, .round, .bevel }) |join| {
        const path = try Path.create(std.testing.allocator, &commands, .{ .stroke = .{ .width = 8, .join = join } });
        defer path.release();
        const mask = try cache.get(path, .{}, 1);
        try std.testing.expectEqual(@as(u8, 255), coverage(mask, 11, 7));
        try std.testing.expectEqual(@as(u8, 255), coverage(mask, 10, 6));
        try std.testing.expectEqual(@as(u8, if (join == .miter) 255 else 0), coverage(mask, 15, 11));
    }
    // Coincident antialiased subpaths are a union, not source-over applications
    // of the same fractional alpha. Compare to independently rasterized single.
    const one = try Path.create(std.testing.allocator, &test_box, .{ .fill = .nonzero });
    defer one.release();
    const twice = try Path.create(std.testing.allocator, &(test_box ++ test_box), .{ .fill = .nonzero });
    defer twice.release();
    const first = try cache.get(one, .{ .x = 0.25, .y = 0.5 }, 1);
    const copy = try std.testing.allocator.dupe(u8, first.pixels);
    defer std.testing.allocator.free(copy);
    const second = try cache.get(twice, .{ .x = 0.25, .y = 0.5 }, 1);
    try std.testing.expectEqualSlices(u8, copy, second.pixels);
}

test "native path device bounds phase carry and integer translations agree" {
    if (!has_rasterizer) return error.SkipZigTest;
    const path = try Path.create(std.testing.allocator, &test_box, .{ .fill = .nonzero });
    defer path.release();
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const first = try cache.get(path, .{ .x = -2.25, .y = -3.5 }, 1.5);
    const bounds: RectI = .{ .x = -4, .y = -5, .width = 21, .height = 15 };
    try std.testing.expectEqual(bounds, first.bounds);
    try std.testing.expectEqual(bounds, try deviceBounds(path, .{ .x = -2.25, .y = -3.5 }, 1.5));
    // Device edges are [-2.25,15.75] x [-3.5,8.5]. Corner coverage is
    // independently determined by the rectangle's area inside each pixel.
    try std.testing.expectApproxEqAbs(@as(f32, 255 * 0.25 * 0.5), @as(f32, @floatFromInt(coverage(first, -3, -4))), 1);
    try std.testing.expectApproxEqAbs(@as(f32, 255 * 0.75 * 0.5), @as(f32, @floatFromInt(coverage(first, 15, 8))), 1);
    try std.testing.expectEqual(@as(u8, 48), first.key.phase_x);
    try std.testing.expectEqual(@as(u8, 32), first.key.phase_y);
    const first_pixels = first.pixels.ptr;
    const translated = try cache.get(path, .{ .x = 4.75, .y = 7.5 }, 1.5);
    try std.testing.expectEqual(first.key, translated.key);
    try std.testing.expectEqual(first_pixels, translated.pixels.ptr);
    try std.testing.expectEqual(first.bounds.x + 7, translated.bounds.x);
    try std.testing.expectEqual(first.bounds.y + 11, translated.bounds.y);
    const zero = try cache.get(path, .{}, 1);
    const carry = try cache.get(path, .{ .x = -0.001, .y = 3.999 }, 1);
    try std.testing.expectEqual(zero.key, carry.key);
    try std.testing.expectEqual(zero.bounds.x, carry.bounds.x);
    try std.testing.expectEqual(zero.bounds.y + 4, carry.bounds.y);
    const negative_phase = try cache.get(path, .{ .x = -1.0 / 64.0, .y = 1.0 / 64.0 }, 1);
    try std.testing.expectEqual(@as(u8, 63), negative_phase.key.phase_x);
    try std.testing.expectEqual(@as(u8, 1), negative_phase.key.phase_y);
    const changed_phase = try cache.get(path, .{ .x = 0.25 }, 1);
    try std.testing.expect(!std.meta.eql(zero.key, changed_phase.key));
    const changed_scale = try cache.get(path, .{}, 1.25);
    try std.testing.expect(!std.meta.eql(zero.key, changed_scale.key));
    try std.testing.expectEqual(@as(u8, 255), coverage(changed_scale, 14, 8));
    try std.testing.expectEqual(@as(u8, 0), coverage(changed_scale, 15, 8));
    const clip = RectI.intersect(first.bounds, .{ .x = 0, .y = 0, .width = 5, .height = 4 });
    try std.testing.expectEqual(RectI{ .x = 0, .y = 0, .width = 5, .height = 4 }, clip);
}

test "native path stale cache identity cannot alias a new path at the same address" {
    if (!has_rasterizer) return error.SkipZigTest;
    var storage: [4096]u8 align(@alignOf(Path)) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const old = try Path.create(fixed.allocator(), &test_box, .{ .fill = .nonzero });
    const address = @intFromPtr(old);
    const old_key = (try cache.get(old, .{}, 1)).key;
    old.release();
    fixed.reset();
    const replacement = try Path.create(fixed.allocator(), &test_box, .{ .stroke = .{ .width = 1 } });
    defer replacement.release();
    try std.testing.expectEqual(address, @intFromPtr(replacement));
    const mask = try cache.get(replacement, .{}, 1);
    try std.testing.expect(old_key.identity != mask.key.identity);
    try std.testing.expectEqual(@as(u8, 0), coverage(mask, 5, 4));
}

fn boxCommands(width: f32, height: f32) [5]Command {
    return .{
        .{ .move = .{} },
        .{ .line = .{ .x = width } },
        .{ .line = .{ .x = width, .y = height } },
        .{ .line = .{ .y = height } },
        .close,
    };
}

test "native path raster limits reject overflow before allocating and preserve cache" {
    if (!has_rasterizer) return error.SkipZigTest;
    const path = try Path.create(std.testing.allocator, &test_box, .{ .fill = .nonzero });
    defer path.release();
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const original = try cache.get(path, .{}, 1);
    const original_pixels = original.pixels.ptr;
    const original_bytes = cache.bytes;
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |scale|
        try std.testing.expectError(error.InvalidTransform, cache.get(path, .{}, scale));
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), std.math.floatMax(f32), 2147483648.0 }) |origin|
        try std.testing.expectError(error.InvalidTransform, cache.get(path, .{ .x = origin }, 1));
    try std.testing.expectError(error.InvalidTransform, cache.get(path, .{ .x = -2147483648.0 }, 1));
    try std.testing.expectError(error.MaskTooLarge, cache.get(path, .{}, 1e30));
    for ([_]struct { width: f32, height: f32, valid: bool }{
        .{ .width = 8190, .height = 1, .valid = true },
        .{ .width = 8191, .height = 1, .valid = false },
        .{ .width = 4094, .height = 4094, .valid = true },
        .{ .width = 4095, .height = 4095, .valid = false },
    }) |case| {
        const large = try Path.create(std.testing.allocator, &boxCommands(case.width, case.height), .{ .fill = .nonzero });
        defer large.release();
        if (case.valid) {
            _ = try deviceBounds(large, .{}, 1);
        } else try std.testing.expectError(error.MaskTooLarge, cache.get(large, .{}, 1));
    }
    try std.testing.expectEqual(original_bytes, cache.bytes);
    try std.testing.expectEqual(original_pixels, (try cache.get(path, .{}, 1)).pixels.ptr);
}

fn allocationLifecycle(allocator: std.mem.Allocator) !void {
    const path = try Path.create(allocator, &test_box, .{ .fill = .nonzero });
    defer path.release();
    path.retain();
    path.release();
    var cache = MaskCache.init(allocator);
    defer cache.deinit();
    const first = try cache.get(path, .{}, 1);
    try std.testing.expectEqual(@as(u8, 255), coverage(first, 3, 4));
    const scaled = try cache.get(path, .{ .x = 0.5 }, 1.25);
    try std.testing.expectEqual(@as(u8, 255), coverage(scaled, 4, 5));
}

test "native path all Zig allocation failures release ownership and cache allocations" {
    if (!has_rasterizer) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationLifecycle, .{});
}

test "native path failed cache allocations do not publish or evict entries" {
    if (!has_rasterizer) return error.SkipZigTest;
    const path = try Path.create(std.testing.allocator, &test_box, .{ .fill = .nonzero });
    defer path.release();
    for (0..3) |failure| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var cache = MaskCache.init(failing.allocator());
        defer cache.deinit();
        const first = try cache.get(path, .{}, 1);
        const pointer = first.pixels.ptr;
        const bytes = cache.bytes;
        failing.fail_index = failing.alloc_index + failure;
        try std.testing.expectError(error.OutOfMemory, cache.get(path, .{}, 2));
        try std.testing.expectEqual(bytes, cache.bytes);
        try std.testing.expectEqual(pointer, (try cache.get(path, .{}, 1)).pixels.ptr);
        failing.fail_index = std.math.maxInt(usize);
        const retried = try cache.get(path, .{}, 2);
        try std.testing.expectEqual(@as(u8, 255), coverage(retried, 20, 12));
    }
}

test "native path LRU includes metadata in its bounded cache budget" {
    if (!has_rasterizer) return error.SkipZigTest;
    var paths: [4]*Path = undefined;
    for (&paths) |*path| path.* = try Path.create(std.testing.allocator, &boxCommands(4094, 2046), .{ .fill = .nonzero });
    defer for (paths) |path| path.release();
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    for (paths[0..3]) |path| _ = try cache.get(path, .{}, 1);
    _ = try cache.get(paths[0], .{ .x = 7 }, 1);
    _ = try cache.get(paths[3], .{}, 1);
    try std.testing.expect(cache.bytes <= MaskCache.budget);
    try std.testing.expectEqual(paths[3].identity, cache.first.?.key.identity);
    try std.testing.expectEqual(paths[2].identity, cache.last.?.key.identity);
    var cursor = cache.first;
    while (cursor) |entry| : (cursor = entry.next) try std.testing.expect(entry.key.identity != paths[1].identity);
    const rerasterized = try cache.get(paths[1], .{}, 1);
    try std.testing.expectEqual(@as(u8, 255), coverage(rerasterized, 3000, 1000));
    try std.testing.expect(cache.bytes <= MaskCache.budget);
}

test "native path bounds contain acute miters diagonal square caps and curved strokes" {
    if (!has_rasterizer) return error.SkipZigTest;
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const corner = [_]Command{
        .{ .move = .{ .y = 20 } },
        .{ .line = .{ .x = 10 } },
        .{ .line = .{ .x = 20, .y = 20 } },
    };
    for ([_]f32{ 1, 4 }) |limit| {
        const path = try Path.create(std.testing.allocator, &corner, .{ .stroke = .{ .width = 4, .miter_limit = limit } });
        defer path.release();
        const mask = try cache.get(path, .{ .x = -2.25, .y = 0.5 }, 2);
        // The acute miter reaches above twice the stroke radius. A limit of 1
        // instead bevels it. This point is outside a radius-only bounding box.
        if (limit == 4) {
            try std.testing.expect(coverage(mask, 17, -6) > 0);
        } else try std.testing.expectEqual(@as(u8, 0), coverage(mask, 17, -6));
        try std.testing.expectEqual(try deviceBounds(path, .{ .x = -2.25, .y = 0.5 }, 2), mask.bounds);
        for (0..mask.bounds.width) |column| {
            try std.testing.expectEqual(@as(u8, 0), mask.pixels[column]);
            try std.testing.expectEqual(@as(u8, 0), mask.pixels[mask.pixels.len - mask.bounds.width + column]);
        }
    }
    const diagonal = try Path.create(std.testing.allocator, &.{ .{ .move = .{} }, .{ .line = .{ .x = 10, .y = 10 } } }, .{ .stroke = .{ .width = 4, .cap = .square, .miter_limit = 1 } });
    defer diagonal.release();
    try std.testing.expect(diagonal.bounds.x < -2.828 and diagonal.bounds.y < -2.828);
    const curve = try Path.create(std.testing.allocator, &.{
        .{ .move = .{ .y = 12 } },
        .{ .cubic = .{ .control1 = .{ .y = -4 }, .control2 = .{ .x = 24, .y = -4 }, .to = .{ .x = 24, .y = 12 } } },
    }, .{ .stroke = .{ .width = 2 } });
    defer curve.release();
    const mask = try cache.get(curve, .{}, 1);
    try std.testing.expect(coverage(mask, 12, 0) > 200);
    try std.testing.expectEqual(@as(u8, 0), coverage(mask, 12, 5));
}

test "native path phase half boundaries match glyph f32 rounding" {
    const half: f32 = 1.0 / 128.0;
    try std.testing.expectEqual(Position{ .anchor = 0, .phase = 0 }, try Position.init(std.math.nextAfter(f32, half, 0)));
    try std.testing.expectEqual(Position{ .anchor = 0, .phase = 1 }, try Position.init(half));
    // Subtracting floor(-half) rounds to an exact tie in f32 even at the next
    // value below -half. Doing that subtraction in f64 would choose phase 63.
    try std.testing.expectEqual(Position{ .anchor = 0, .phase = 0 }, try Position.init(std.math.nextAfter(f32, -half, -1)));
    try std.testing.expectEqual(Position{ .anchor = -1, .phase = 63 }, try Position.init(-half - 0.000001));
}

test "native path bounds never lose small stroke inflation at huge finite coordinates" {
    const point: PointF = .{ .x = 1e30, .y = -1e30 };
    const path = try Path.create(std.testing.allocator, &.{ .{ .move = point }, .{ .line = point } }, .{ .stroke = .{ .width = 1, .cap = .round } });
    defer path.release();
    try std.testing.expect(path.bounds.x < point.x);
    try std.testing.expect(path.bounds.y < point.y);
    try std.testing.expect(@as(f64, path.bounds.x) + path.bounds.width > point.x);
    try std.testing.expect(@as(f64, path.bounds.y) + path.bounds.height > point.y);
    const extreme: PointF = .{ .x = std.math.floatMax(f32) };
    try std.testing.expectError(error.InvalidGeometry, Path.create(std.testing.allocator, &.{ .{ .move = extreme }, .{ .line = extreme } }, .{ .stroke = .{ .width = 1 } }));
}

test "native path geometry and empty masks remain usable without a rasterizer" {
    if (has_rasterizer) return error.SkipZigTest;
    const path = try Path.create(std.testing.allocator, &test_box, .{ .fill = .nonzero });
    defer path.release();
    try std.testing.expectEqual(RectI{ .x = -1, .y = -1, .width = 14, .height = 10 }, try deviceBounds(path, .{}, 1));
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expectError(error.PathRasterizerDisabled, cache.get(path, .{}, 1));
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
    const empty = try Path.create(std.testing.allocator, &.{}, .{ .fill = .nonzero });
    defer empty.release();
    const mask = try cache.get(empty, .{}, 1);
    try std.testing.expectEqual(@as(usize, 0), mask.pixels.len);
    try std.testing.expect(mask.bounds.isEmpty());
}
