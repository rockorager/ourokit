const std = @import("std");

/// Growable slot storage whose slots never move. Slots live in fixed-size
/// chunks; growing adds a chunk instead of reallocating, so the kernel (an
/// io_uring buffer), a Lua continuation context, or a resource lifecycle
/// may keep a slot's address across later growth. Lookup and iteration
/// never allocate.
pub fn StableSlots(comptime T: type) type {
    return struct {
        const Self = @This();

        chunk_len: usize,
        chunks: std.ArrayList([]T) = .empty,

        pub fn init(chunk_len: usize) Self {
            std.debug.assert(chunk_len != 0);
            return .{ .chunk_len = chunk_len };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.chunks.items) |chunk| allocator.free(chunk);
            self.chunks.deinit(allocator);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.chunks.items.len * self.chunk_len;
        }

        pub fn at(self: *const Self, index: usize) *T {
            return &self.chunks.items[index / self.chunk_len][index % self.chunk_len];
        }

        pub fn get(self: *const Self, index: usize) ?*T {
            return if (index < self.len()) self.at(index) else null;
        }

        /// Appends one chunk of default-initialized slots and returns the
        /// index of its first slot.
        pub fn grow(self: *Self, allocator: std.mem.Allocator) !usize {
            const first = self.len();
            try self.chunks.ensureUnusedCapacity(allocator, 1);
            const chunk = try allocator.alloc(T, self.chunk_len);
            @memset(chunk, .{});
            self.chunks.appendAssumeCapacity(chunk);
            return first;
        }
    };
}

test "stable slots keep addresses across growth" {
    const Slot = struct { value: u32 = 7 };
    var slots = StableSlots(Slot).init(2);
    defer slots.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), try slots.grow(std.testing.allocator));
    const first = slots.at(1);
    first.value = 42;
    for (0..10) |_| _ = try slots.grow(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 22), slots.len());
    try std.testing.expectEqual(first, slots.at(1));
    try std.testing.expectEqual(@as(u32, 42), slots.at(1).value);
    try std.testing.expectEqual(@as(u32, 7), slots.at(21).value);
    try std.testing.expect(slots.get(22) == null);
}
