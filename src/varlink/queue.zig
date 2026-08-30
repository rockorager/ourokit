const std = @import("std");

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        storage: []T,
        head: usize = 0,
        count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            return .{
                .allocator = allocator,
                .storage = try allocator.alloc(T, capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.count == 0);
            self.allocator.free(self.storage);
            self.* = undefined;
        }

        pub fn full(self: *const Self) bool {
            return self.count == self.storage.len;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn push(self: *Self, value: T) !void {
            if (self.full()) return error.QueueFull;
            const tail = (self.head + self.count) % self.storage.len;
            self.storage[tail] = value;
            self.count += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const value = self.storage[self.head];
            self.head = (self.head + 1) % self.storage.len;
            self.count -= 1;
            return value;
        }
    };
}
