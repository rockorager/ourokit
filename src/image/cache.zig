const std = @import("std");
const Bitmap = @import("pixels.zig").Bitmap;
pub const ImageHandle = @import("../core/handle.zig").Handle;

/// Event-thread-owned immutable pixel resources. Workers transfer owned bitmaps
/// into this cache; trees and submitted frames retain independent leases.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    decoded_bytes: usize = 0,
    pub const max_decoded_bytes = 256 * 1024 * 1024;

    const Slot = struct {
        generation: u32 = 0,
        references: u32 = 0,
        bitmap: Bitmap = undefined,
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Cache {
        if (capacity == 0 or capacity > std.math.maxInt(u32)) return error.InvalidImageCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        return .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *Cache) void {
        for (self.slots) |*slot| if (slot.references != 0) slot.bitmap.deinit();
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Takes ownership only on success; the returned handle owns one lease.
    pub fn insert(self: *Cache, bitmap: Bitmap) !ImageHandle {
        if (bitmap.width == 0 or bitmap.height == 0 or
            bitmap.intrinsic_width == 0 or bitmap.intrinsic_height == 0)
            return error.InvalidImageDimensions;
        const area = try std.math.mul(usize, bitmap.width, bitmap.height);
        if (bitmap.pixels.len != try std.math.mul(usize, area, 4)) return error.InvalidImagePixels;
        if (bitmap.pixels.len > max_decoded_bytes - self.decoded_bytes) return error.ImageMemoryLimit;
        for (self.slots, 0..) |*slot, index| {
            if (slot.references != 0) continue;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.references = 1;
            slot.bitmap = bitmap;
            self.decoded_bytes += bitmap.pixels.len;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        }
        return error.ImageCapacityExceeded;
    }

    pub fn get(self: *const Cache, handle: ImageHandle) !*const Bitmap {
        try self.validate(handle);
        return &self.slots[handle.slot].bitmap;
    }

    pub fn byteSize(self: *const Cache) usize {
        return self.decoded_bytes;
    }

    pub fn validateRetain(self: *const Cache, handle: ImageHandle) !void {
        try self.validate(handle);
        if (self.slots[handle.slot].references == std.math.maxInt(u32)) return error.Overflow;
    }

    pub fn retain(self: *Cache, handle: ImageHandle) !void {
        try self.validateRetain(handle);
        const slot = &self.slots[handle.slot];
        slot.references = try std.math.add(u32, slot.references, 1);
    }

    pub fn release(self: *Cache, handle: ImageHandle) !void {
        try self.validate(handle);
        const slot = &self.slots[handle.slot];
        slot.references -= 1;
        if (slot.references == 0) {
            self.decoded_bytes -= slot.bitmap.pixels.len;
            slot.bitmap.deinit();
        }
    }

    fn validate(self: *const Cache, handle: ImageHandle) !void {
        if (handle.slot >= self.slots.len) return error.StaleImageHandle;
        const slot = self.slots[handle.slot];
        if (slot.references == 0 or slot.generation != handle.generation)
            return error.StaleImageHandle;
    }
};

test "image cache leases survive caller release and reject recycled handles" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator, 1);
    defer cache.deinit();
    const bitmap: Bitmap = .{
        .allocator = allocator,
        .pixels = try allocator.dupe(u8, &.{ 17, 31, 63, 127 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = 1,
        .intrinsic_height = 1,
    };
    const first = try cache.insert(bitmap);
    try cache.retain(first);
    try cache.release(first);
    try std.testing.expectEqualSlices(u8, &.{ 17, 31, 63, 127 }, (try cache.get(first)).pixels);
    try cache.release(first);
    try std.testing.expectError(error.StaleImageHandle, cache.get(first));
    var second_bitmap = bitmap;
    second_bitmap.pixels = try allocator.dupe(u8, &.{ 3, 7, 11, 255 });
    const second = try cache.insert(second_bitmap);
    try std.testing.expect(second.generation != first.generation);
    try std.testing.expectError(error.StaleImageHandle, cache.retain(first));
    try std.testing.expectEqualSlices(u8, &.{ 3, 7, 11, 255 }, (try cache.get(second)).pixels);
    try cache.release(second);
}
