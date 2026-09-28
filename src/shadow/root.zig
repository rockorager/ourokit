//! Pure-Zig, renderer-independent outset shadow coverage. Shapes are values in
//! device pixels; there are no leases or native rasterizer dependencies. Cache
//! access is single-threaded. Renderers apply color and ancestor clips themselves.
//!
//! Offsets use glyph/path-compatible nearest-1/64 quantization. Bounds include
//! one pixel of conservative AA padding plus ceil(3 * blur/2) kernel support.
//! The spread/offset shape is blurred first, then the ORIGINAL rounded box is
//! knocked out, independently of its background alpha. Empty original boxes or
//! contracted extents return canonical empty bounds and no pixels.
//!
//! Device blur <=128 bounds kernel radius to192; logical Style has no blur cap.
//! Dimensions <=8192 and masks <=16 Mi pixels bound allocation and CPU work.
//! The LRU retains <=32 MiB of pixels AND entry metadata, and <=256 entries to
//! bound its linear lookup cost. Temporary convolution storage is one f32 per
//! pixel (<=64 MiB), plus a fixed 385-element f64 kernel. A miss builds before
//! eviction, so peak memory also includes the new <=16 MiB mask and one entry.
//! Bounds/offset anchors must fit i32, including exclusive right/bottom edges.
//! Allocation failures leave existing entries untouched and are retryable.
const std = @import("std");
const geometry = @import("../core/geometry.zig");
pub const PointF = geometry.PointF;
pub const RectI = geometry.RectI;
pub const Color = @import("../core/color.zig").Color;

pub const Style = struct {
    offset: PointF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color,

    pub fn validate(self: Style) !void {
        if (!std.math.isFinite(self.offset.x) or !std.math.isFinite(self.offset.y) or
            !std.math.isFinite(self.spread) or !std.math.isFinite(self.blur) or self.blur < 0)
            return error.InvalidStyle;
    }
};

pub const Shape = struct {
    box: RectI,
    corner_radius: u32 = 0,
    offset: PointF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
};

/// Integer fields only, suitable for std.AutoHashMap. Integer box translation
/// and color are excluded, but the entire RELATIVE offset matters for knockout.
pub const Key = struct {
    width: u32,
    height: u32,
    corner_radius: u32,
    offset_x_64: i64,
    offset_y_64: i64,
    blur_bits: u32,
    spread_bits: u32,
};

pub const Mask = struct {
    /// Borrowed until the next get or deinit; copy/upload before then.
    /// Tightly packed A8, stride == bounds.width. Color is not baked in.
    pixels: []const u8,
    bounds: RectI,
    key: Key,
};

fn quantizedOffset(value: f32) !i64 {
    // Match path/glyph f32 subtraction and rounding at negative half phases.
    const floor = @floor(value);
    const fraction: u7 = @intFromFloat(@round((value - floor) * 64));
    const anchor = @as(f64, floor) + @as(f64, @floatFromInt(fraction / 64));
    if (anchor < std.math.minInt(i32) or anchor > std.math.maxInt(i32)) return error.InvalidTransform;
    return @as(i64, @intFromFloat(anchor)) * 64 + fraction % 64;
}

const RoundedBox = struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,
    radius: f64,

    fn coverage(self: RoundedBox, x: f64, y: f64) u8 {
        const dx = @abs(x - (self.left + self.width * 0.5)) - (self.width * 0.5 - self.radius);
        const dy = @abs(y - (self.top + self.height * 0.5)) - (self.height * 0.5 - self.radius);
        const outside = @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0));
        const distance = outside + @min(@max(dx, dy), 0) - self.radius;
        return alpha(std.math.clamp(0.5 - distance, 0, 1) * 255);
    }
};

fn alpha(value: f64) u8 {
    return @intFromFloat(@floor(std.math.clamp(value, 0, 255) + 0.5));
}

const Placement = struct {
    key: Key,
    bounds: RectI,
    left: f64 = 0,
    top: f64 = 0,
    original: RoundedBox,
    shadow: RoundedBox,
    support: u32,

    fn init(shape: Shape) !Placement {
        try (Style{ .offset = shape.offset, .blur = shape.blur, .spread = shape.spread, .color = Color.rgba(0, 0, 0, 0) }).validate();
        if (shape.blur > 128) return error.BlurTooLarge;
        const ox = try quantizedOffset(shape.offset.x);
        const oy = try quantizedOffset(shape.offset.y);
        const radius = @min(shape.corner_radius, @min(shape.box.width, shape.box.height) / 2);
        const width = @as(f64, @floatFromInt(shape.box.width)) + 2 * @as(f64, shape.spread);
        const height = @as(f64, @floatFromInt(shape.box.height)) + 2 * @as(f64, shape.spread);
        var adjusted: f64 = @floatFromInt(radius);
        if (shape.spread > 0 and adjusted < shape.spread) {
            // CSS spread corner adjustment; r==0 stays exactly square.
            const ratio = adjusted / shape.spread - 1;
            adjusted += shape.spread * (1 + ratio * ratio * ratio);
        } else adjusted += shape.spread;
        var result: Placement = .{
            .key = .{
                .width = shape.box.width,
                .height = shape.box.height,
                .corner_radius = radius,
                .offset_x_64 = ox,
                .offset_y_64 = oy,
                // Canonicalize signed zero so identical coverage reuses entries.
                .blur_bits = @bitCast(if (shape.blur == 0) @as(f32, 0) else shape.blur),
                .spread_bits = @bitCast(if (shape.spread == 0) @as(f32, 0) else shape.spread),
            },
            .bounds = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .original = .{ .left = 0, .top = 0, .width = @floatFromInt(shape.box.width), .height = @floatFromInt(shape.box.height), .radius = @floatFromInt(radius) },
            .shadow = .{
                .left = @as(f64, @floatFromInt(ox)) / 64 - shape.spread,
                .top = @as(f64, @floatFromInt(oy)) / 64 - shape.spread,
                .width = width,
                .height = height,
                .radius = @max(0, @min(adjusted, @min(width, height) * 0.5)),
            },
            .support = @intFromFloat(@ceil(@as(f64, shape.blur) * 1.5)),
        };
        if (shape.box.isEmpty() or width <= 0 or height <= 0) return result;
        const pad: f64 = @floatFromInt(result.support + 1);
        const left = @floor(result.shadow.left) - pad;
        const top = @floor(result.shadow.top) - pad;
        const right = @ceil(result.shadow.left + width) + pad;
        const bottom = @ceil(result.shadow.top + height) + pad;
        const mask_width = right - left;
        const mask_height = bottom - top;
        if (mask_width > 8192 or mask_height > 8192 or mask_width * mask_height > 16 * 1024 * 1024)
            return error.MaskTooLarge;
        const x = left + @as(f64, @floatFromInt(shape.box.x));
        const y = top + @as(f64, @floatFromInt(shape.box.y));
        if (x < std.math.minInt(i32) or y < std.math.minInt(i32) or
            x + mask_width > std.math.maxInt(i32) or y + mask_height > std.math.maxInt(i32))
            return error.InvalidTransform;
        result.bounds = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = @intFromFloat(mask_width), .height = @intFromFloat(mask_height) };
        result.left = left;
        result.top = top;
        return result;
    }
};

/// Allocation-free; exactly the same quantization, bounds and errors as get.
pub fn deviceBounds(shape: Shape) !RectI {
    return (try Placement.init(shape)).bounds;
}

pub const MaskCache = struct {
    allocator: std.mem.Allocator,
    first: ?*Entry = null,
    last: ?*Entry = null,
    bytes: usize = 0,
    count: usize = 0,

    const budget = 32 * 1024 * 1024;
    const max_entries = 256;
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

    pub fn get(self: *MaskCache, shape: Shape) !Mask {
        const placement = try Placement.init(shape);
        if (placement.bounds.isEmpty()) return .{ .pixels = &.{}, .bounds = placement.bounds, .key = placement.key };
        var cursor = self.first;
        while (cursor) |entry| : (cursor = entry.next) {
            if (!std.meta.eql(entry.key, placement.key)) continue;
            self.unlink(entry);
            self.prepend(entry);
            return .{ .pixels = entry.pixels, .bounds = placement.bounds, .key = entry.key };
        }
        const pixels = try self.allocator.alloc(u8, @as(usize, placement.bounds.width) * placement.bounds.height);
        errdefer self.allocator.free(pixels);
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        try rasterize(self.allocator, placement, pixels);
        const charge = pixels.len + @sizeOf(Entry);
        while (self.bytes + charge > budget or self.count == max_entries) self.evict(self.last.?);
        entry.* = .{ .key = placement.key, .pixels = pixels };
        self.prepend(entry);
        self.bytes += charge;
        self.count += 1;
        return .{ .pixels = pixels, .bounds = placement.bounds, .key = entry.key };
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
        self.count -= 1;
        self.allocator.free(entry.pixels);
        self.allocator.destroy(entry);
    }
};

fn rasterize(allocator: std.mem.Allocator, p: Placement, pixels: []u8) !void {
    const width: usize = p.bounds.width;
    const height: usize = p.bounds.height;
    for (0..height) |y| {
        for (0..width) |x| pixels[y * width + x] = p.shadow.coverage(p.left + @as(f64, @floatFromInt(x)) + 0.5, p.top + @as(f64, @floatFromInt(y)) + 0.5);
    }
    if (p.support > 0) {
        const scratch = try allocator.alloc(f32, pixels.len);
        defer allocator.free(scratch);
        var storage: [385]f64 = undefined;
        const kernel = storage[0 .. 2 * p.support + 1];
        const sigma = @as(f64, @as(f32, @bitCast(p.key.blur_bits))) / 2;
        var sum: f64 = 0;
        for (kernel, 0..) |*weight, i| {
            const distance = (@as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(p.support))) / sigma;
            weight.* = @exp(-0.5 * distance * distance);
            sum += weight.*;
        }
        for (kernel) |*weight| weight.* /= sum;
        // Samples outside the padded mask are transparent, never edge-clamped.
        // Keep horizontal results in float; quantize only after vertical blur
        // and knockout to avoid accumulating intermediate 8-bit rounding.
        for (0..height) |y| {
            for (0..width) |x| {
                var value: f64 = 0;
                const start = x -| p.support;
                const end = @min(width, x + p.support + 1);
                for (start..end) |sx| value += @as(f64, @floatFromInt(pixels[y * width + sx])) * kernel[sx + p.support - x];
                scratch[y * width + x] = @floatCast(value);
            }
        }
        for (0..height) |y| {
            for (0..width) |x| {
                var value: f64 = 0;
                const start = y -| p.support;
                const end = @min(height, y + p.support + 1);
                for (start..end) |sy| value += @as(f64, scratch[sy * width + x]) * kernel[sy + p.support - y];
                pixels[y * width + x] = knockOut(p, x, y, value);
            }
        }
    } else {
        for (0..height) |y| {
            for (0..width) |x| pixels[y * width + x] = knockOut(p, x, y, @floatFromInt(pixels[y * width + x]));
        }
    }
}

fn knockOut(p: Placement, x: usize, y: usize, value: f64) u8 {
    // For the integer original box, radius-zero SDF coverage is exactly the
    // software renderer's hard square; other radii use its same rounded SDF.
    const original = p.original.coverage(p.left + @as(f64, @floatFromInt(x)) + 0.5, p.top + @as(f64, @floatFromInt(y)) + 0.5);
    return alpha(value * @as(f64, @floatFromInt(255 - original)) / 255);
}

fn at(mask: Mask, x: i32, y: i32) u8 {
    const column = @as(i64, x) - mask.bounds.x;
    const row = @as(i64, y) - mask.bounds.y;
    if (column < 0 or row < 0 or column >= mask.bounds.width or row >= mask.bounds.height) return 0;
    return mask.pixels[@as(usize, @intCast(row)) * mask.bounds.width + @as(usize, @intCast(column))];
}

test "shadow hard asymmetric edges, negative offset and spread, empty contraction" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    var shape: Shape = .{ .box = .{ .x = -3, .y = 7, .width = 9, .height = 5 }, .offset = .{ .x = -2.25, .y = 1.5 } };
    const mask = try cache.get(shape);
    try std.testing.expectEqual(try deviceBounds(shape), mask.bounds);
    try std.testing.expectEqual(@as(u8, 64), at(mask, -6, 10));
    try std.testing.expectEqual(@as(u8, 255), at(mask, -5, 10));
    try std.testing.expectEqual(@as(u8, 0), at(mask, -3, 10));
    try std.testing.expectEqual(@as(u8, 128), at(mask, 0, 13));
    try std.testing.expectEqual(@as(u8, 0), at(mask, 0, 14));
    shape.spread = -1;
    const contracted = try cache.get(shape);
    try std.testing.expectEqual(@as(u8, 0), at(contracted, -6, 10));
    try std.testing.expectEqual(@as(u8, 64), at(contracted, -5, 10));
    try std.testing.expectEqual(@as(u8, 255), at(contracted, -4, 10));
    shape.spread = -2.5;
    try std.testing.expect((try deviceBounds(shape)).isEmpty());
    try std.testing.expectEqual(@as(usize, 0), (try cache.get(shape)).pixels.len);
    shape.box.width = 0;
    shape.spread = 100;
    try std.testing.expect((try cache.get(shape)).bounds.isEmpty());
}

test "shadow CSS corner spread and rounded original knockout" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    var shape: Shape = .{ .box = .{ .x = 0, .y = 0, .width = 15, .height = 9 }, .corner_radius = 3, .spread = 4 };
    const p = try Placement.init(shape);
    // 3 + 4*(1 + (3/4 - 1)^3) = 6.9375, not r+spread.
    try std.testing.expectEqual(@as(f64, 6.9375), p.shadow.radius);
    const mask = try cache.get(shape);
    try std.testing.expectEqual(@as(u8, 255), at(mask, 0, 0));
    // Original radius3 at (1.5,.5): round((.5-(sqrt(8.5)-3))*255)=149.
    try std.testing.expectEqual(@as(u8, 106), at(mask, 1, 0));
    try std.testing.expectEqual(@as(u8, 0), at(mask, 3, 1));
    try std.testing.expectEqual(@as(u8, 0), at(mask, 7, 4));
    try std.testing.expectEqual(@as(u8, 0), at(mask, -5, 4));
    shape.corner_radius = 0;
    try std.testing.expectEqual(@as(f64, 0), (try Placement.init(shape)).shadow.radius);
    shape.corner_radius = 99;
    shape.spread = -1.25;
    const small = try Placement.init(shape);
    try std.testing.expectEqual(@as(f64, 4), small.original.radius);
    try std.testing.expectEqual(@as(f64, 2.75), small.shadow.radius);
}

test "shadow Gaussian analytical edge tails and asymmetric direct convolution" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const shape: Shape = .{ .box = .{ .x = -7, .y = 4, .width = 4, .height = 3 }, .offset = .{ .x = 8, .y = -6 }, .blur = 2 };
    const mask = try cache.get(shape);
    // Independent 2D reference for sigma1, radius3 and hard source [1,5)x[-2,1).
    const weights = [_]f64{ 0.004433048175243745, 0.054005582622414484, 0.2420362293761143, 0.3990502796524549, 0.2420362293761143, 0.054005582622414484, 0.004433048175243745 };
    for (0..mask.bounds.height) |iy| {
        for (0..mask.bounds.width) |ix| {
            const x = mask.bounds.x + @as(i32, @intCast(ix));
            const y = mask.bounds.y + @as(i32, @intCast(iy));
            var expected: f64 = 0;
            for (0..3) |sy| {
                for (0..4) |sx| {
                    const dx = x - (1 + @as(i32, @intCast(sx)));
                    const dy = y - (-2 + @as(i32, @intCast(sy)));
                    if (@abs(dx) <= 3 and @abs(dy) <= 3) expected += 255 * weights[@intCast(dx + 3)] * weights[@intCast(dy + 3)];
                }
            }
            if (x >= -7 and x < -3 and y >= 4 and y < 7) expected = 0;
            try std.testing.expectEqual(@as(u8, @intFromFloat(@floor(expected + 0.5))), at(mask, x, y));
        }
    }
    try std.testing.expect(at(mask, 0, -1) > 0);
    try std.testing.expectEqual(@as(u8, 0), at(mask, -3, -1));
    try std.testing.expectEqual(@as(u8, 0), at(mask, 2, 5));
}

test "shadow blur precedes rounded knockout with fractional contraction and offset" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    const mask = try cache.get(.{
        .box = .{ .x = 0, .y = 0, .width = 7, .height = 5 },
        .corner_radius = 2,
        .offset = .{ .x = -1.25, .y = 2.5 },
        .spread = -0.5,
        .blur = 2.2,
    });
    // Independently evaluated 2D Gaussian convolution (sigma1.1, radius4),
    // then original radius2 knockout. Rows y=3..6, columns x=-3..8. Blurring
    // an already knocked-out source wrongly darkens the fully empty interior.
    const expected = [_][12]u8{
        .{ 8, 37, 90, 12, 0, 0, 0, 0, 0, 1, 3, 0 },
        .{ 12, 53, 127, 119, 18, 0, 0, 0, 7, 16, 5, 0 },
        .{ 12, 53, 127, 193, 224, 228, 212, 161, 83, 26, 5, 0 },
        .{ 8, 37, 90, 140, 166, 170, 156, 114, 57, 17, 3, 0 },
    };
    for (expected, 3..) |row, y| {
        for (row, 0..) |value, x| try std.testing.expectEqual(value, at(mask, @as(i32, @intCast(x)) - 3, @intCast(y)));
    }
    // Padding stays transparent rather than clamping to the nearest sample.
    for (0..mask.bounds.width) |x| {
        try std.testing.expectEqual(@as(u8, 0), mask.pixels[x]);
        try std.testing.expectEqual(@as(u8, 0), mask.pixels[(mask.bounds.height - 1) * mask.bounds.width + x]);
    }
}

test "shadow key phase, integer translation, hashability and relative offset" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    var shape: Shape = .{ .box = .{ .x = -11, .y = 6, .width = 8, .height = 5 }, .offset = .{ .x = -0.01, .y = 2.999 } };
    const first = try cache.get(shape);
    try std.testing.expectEqual(@as(i64, -1), first.key.offset_x_64);
    try std.testing.expectEqual(@as(i64, 192), first.key.offset_y_64);
    shape.box.x += 127;
    shape.box.y -= 19;
    shape.offset.x = -0.016;
    const moved = try cache.get(shape);
    try std.testing.expectEqual(first.key, moved.key);
    try std.testing.expectEqual(first.pixels.ptr, moved.pixels.ptr);
    try std.testing.expectEqual(first.bounds.x + 127, moved.bounds.x);
    try std.testing.expectEqual(first.bounds.y - 19, moved.bounds.y);
    var map = std.AutoHashMap(Key, u8).init(std.testing.allocator);
    defer map.deinit();
    try map.put(first.key, 42);
    try std.testing.expectEqual(@as(u8, 42), map.get(moved.key).?);
    shape.offset.x = -0.03;
    try std.testing.expect(!std.meta.eql(first.key, (try cache.get(shape)).key));
    shape.offset.x = 0.984375;
    try std.testing.expect(!std.meta.eql(first.key, (try cache.get(shape)).key));
    shape.blur = 1;
    const blurred = try cache.get(shape);
    shape.spread = 0.5;
    const spread = try cache.get(shape);
    try std.testing.expect(!std.meta.eql(blurred.key, spread.key));
    shape.corner_radius = 2;
    try std.testing.expect(!std.meta.eql(spread.key, (try cache.get(shape)).key));
}

test "shadow phase ties carry consistently and signed zero reuses masks" {
    try std.testing.expectEqual(@as(i64, 0), try quantizedOffset(-1.0 / 128.0));
    try std.testing.expectEqual(@as(i64, -1), try quantizedOffset(-1.0 / 128.0 - 0.0001));
    try std.testing.expectEqual(@as(i64, 64), try quantizedOffset(1 - 1.0 / 128.0));
    try std.testing.expectEqual(@as(i64, 63), try quantizedOffset(1 - 1.0 / 128.0 - 0.0001));
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    var shape: Shape = .{ .box = .{ .x = 0, .y = 0, .width = 7, .height = 3 }, .corner_radius = 99 };
    const first = try cache.get(shape);
    shape.corner_radius = 1;
    shape.blur = -0.0;
    shape.spread = -0.0;
    shape.offset.x = -0.0;
    const same = try cache.get(shape);
    try std.testing.expectEqual(first.key, same.key);
    try std.testing.expectEqual(first.pixels.ptr, same.pixels.ptr);
    try std.testing.expectEqual(@as(usize, 1), cache.count);
    shape.box.height = 4;
    try std.testing.expect(!std.meta.eql(first.key, (try cache.get(shape)).key));
    shape.blur = std.math.floatMin(f32);
    _ = try cache.get(shape);
}

test "shadow validation and allocation-free limits" {
    var style: Style = .{ .color = Color.rgba(0, 0, 0, 0), .blur = 1000 };
    try style.validate();
    const bad = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) };
    for (bad) |value| {
        style.offset.x = value;
        try std.testing.expectError(error.InvalidStyle, style.validate());
        style.offset = .{ .y = value };
        try std.testing.expectError(error.InvalidStyle, style.validate());
        style.offset = .{};
        style.spread = value;
        try std.testing.expectError(error.InvalidStyle, style.validate());
        style.spread = 0;
        style.blur = value;
        try std.testing.expectError(error.InvalidStyle, style.validate());
        style.blur = 0;
    }
    style.blur = -0.1;
    try std.testing.expectError(error.InvalidStyle, style.validate());
    var shape: Shape = .{ .box = .{ .x = 0, .y = 0, .width = 8190, .height = 1 } };
    try std.testing.expectEqual(@as(u32, 8192), (try deviceBounds(shape)).width);
    shape.box.width += 1;
    try std.testing.expectError(error.MaskTooLarge, deviceBounds(shape));
    shape.box = .{ .x = 0, .y = 0, .width = 4094, .height = 4094 };
    _ = try deviceBounds(shape);
    shape.box.height += 1;
    try std.testing.expectError(error.MaskTooLarge, deviceBounds(shape));
    shape.box = .{ .x = 0, .y = 0, .width = 2, .height = 3 };
    shape.blur = 128;
    try std.testing.expectEqual(@as(u32, 388), (try deviceBounds(shape)).width);
    shape.blur = 128.001;
    try std.testing.expectError(error.BlurTooLarge, deviceBounds(shape));
    shape.blur = 0;
    shape.offset.x = std.math.floatMax(f32);
    try std.testing.expectError(error.InvalidTransform, deviceBounds(shape));
    shape.offset = .{};
    shape.spread = std.math.floatMax(f32);
    try std.testing.expectError(error.MaskTooLarge, deviceBounds(shape));
    shape.spread = 0;
    shape.box.x = std.math.minInt(i32);
    try std.testing.expectError(error.InvalidTransform, deviceBounds(shape));
    shape.box.x = std.math.maxInt(i32) - 2;
    try std.testing.expectError(error.InvalidTransform, deviceBounds(shape));
    shape.box.x -= 1;
    _ = try deviceBounds(shape);
}

test "shadow LRU entry limit preserves recent hits" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    var shape: Shape = .{ .box = .{ .x = 0, .y = 0, .width = 2, .height = 3 } };
    const first = try cache.get(shape);
    for (1..MaskCache.max_entries) |i| {
        shape.offset.x = @floatFromInt(i);
        _ = try cache.get(shape);
    }
    const second_key = cache.last.?.previous.?.key;
    shape.offset.x = 0;
    try std.testing.expectEqual(first.pixels.ptr, (try cache.get(shape)).pixels.ptr);
    shape.offset.x = 999;
    _ = try cache.get(shape);
    try std.testing.expectEqual(MaskCache.max_entries, cache.count);
    try std.testing.expect(cache.bytes <= MaskCache.budget);
    var cursor = cache.first;
    while (cursor) |entry| : (cursor = entry.next) try std.testing.expect(!std.meta.eql(second_key, entry.key));
}

test "shadow cache budget includes metadata" {
    var cache = MaskCache.init(std.testing.allocator);
    defer cache.deinit();
    var shape: Shape = .{ .box = .{ .x = 0, .y = 0, .width = 4094, .height = 4094 } };
    const first = try cache.get(shape);
    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024) + @sizeOf(MaskCache.Entry), cache.bytes);
    shape.offset.x = 1;
    _ = try cache.get(shape);
    // Two full-size masks alone fit32MiB, but metadata forces eviction.
    try std.testing.expectEqual(@as(usize, 1), cache.count);
    try std.testing.expect(!std.meta.eql(first.key, cache.first.?.key));
    cache.deinit();
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
    try std.testing.expectEqual(@as(usize, 0), cache.count);
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var cache = MaskCache.init(allocator);
    defer cache.deinit();
    var shape: Shape = .{ .box = .{ .x = 0, .y = 0, .width = 7, .height = 4 }, .offset = .{ .x = -3.25, .y = 1.75 } };
    const first = try cache.get(shape);
    const bytes = cache.bytes;
    shape.blur = 3;
    _ = cache.get(shape) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), cache.count);
        try std.testing.expectEqual(bytes, cache.bytes);
        try std.testing.expectEqual(first.key, cache.first.?.key);
        try std.testing.expectEqual(first.pixels.ptr, cache.first.?.pixels.ptr);
        shape.blur = 0;
        try std.testing.expectEqual(first.pixels.ptr, (try cache.get(shape)).pixels.ptr);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), cache.count);
}

test "shadow all allocation failures preserve entries and leak nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}
