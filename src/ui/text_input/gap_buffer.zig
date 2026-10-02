const std = @import("std");

/// Editing storage and a lazy contiguous read view. Reserve both before editing
/// so reads and replaying history never allocate. Reads do not move the gap.
pub const GapBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8 = &.{},
    gap_start: usize = 0,
    gap_end: usize = 0,
    non_ascii_bytes: usize = 0,
    snapshot: std.ArrayList(u8) = .empty,
    snapshot_valid: bool = false,

    pub fn deinit(self: *GapBuffer) void {
        self.allocator.free(self.storage);
        self.snapshot.deinit(self.allocator);
    }

    pub fn len(self: *const GapBuffer) usize {
        return self.storage.len - (self.gap_end - self.gap_start);
    }

    pub fn byteAt(self: *const GapBuffer, offset: usize) u8 {
        std.debug.assert(offset < self.len());
        return self.storage[if (offset < self.gap_start) offset else offset + self.gap_end - self.gap_start];
    }

    pub fn copyRange(self: *const GapBuffer, offset: usize, out: []u8) void {
        std.debug.assert(offset + out.len <= self.len());
        const prefix = if (offset < self.gap_start) @min(out.len, self.gap_start - offset) else 0;
        @memcpy(out[0..prefix], self.storage[offset..][0..prefix]);
        const rest = out[prefix..];
        if (rest.len != 0) {
            const start = offset + prefix + self.gap_end - self.gap_start;
            @memcpy(rest, self.storage[start..][0..rest.len]);
        }
    }

    pub fn text(self: *GapBuffer) []const u8 {
        if (!self.snapshot_valid) {
            self.snapshot.items.len = self.len();
            self.copyRange(0, self.snapshot.items);
            self.snapshot_valid = true;
        }
        return self.snapshot.items;
    }

    pub fn reserve(self: *GapBuffer, capacity: usize) !void {
        try self.snapshot.ensureTotalCapacity(self.allocator, capacity);
        if (capacity <= self.storage.len) return;
        const grown = std.math.add(usize, self.storage.len, self.storage.len / 2 + 64) catch capacity;
        const storage = try self.allocator.alloc(u8, @max(capacity, grown));
        const suffix_len = self.storage.len - self.gap_end;
        @memcpy(storage[0..self.gap_start], self.storage[0..self.gap_start]);
        @memcpy(storage[storage.len - suffix_len ..], self.storage[self.gap_end..]);
        self.allocator.free(self.storage);
        self.storage = storage;
        self.gap_end = storage.len - suffix_len;
    }

    /// Replacement must not alias storage or its read view.
    pub fn replaceAssumeCapacity(self: *GapBuffer, start: usize, end: usize, replacement: []const u8) void {
        std.debug.assert(start <= end and end <= self.len());
        std.debug.assert(self.len() - (end - start) + replacement.len <= self.storage.len);
        if (start < self.gap_start) {
            const count = self.gap_start - start;
            std.mem.copyBackwards(u8, self.storage[self.gap_end - count .. self.gap_end], self.storage[start..self.gap_start]);
            self.gap_start -= count;
            self.gap_end -= count;
        } else {
            const count = start - self.gap_start;
            std.mem.copyForwards(u8, self.storage[self.gap_start..][0..count], self.storage[self.gap_end..][0..count]);
            self.gap_start += count;
            self.gap_end += count;
        }
        for (self.storage[self.gap_end..][0 .. end - start]) |byte| {
            if (byte >= 0x80) self.non_ascii_bytes -= 1;
        }
        self.gap_end += end - start;
        @memcpy(self.storage[self.gap_start..][0..replacement.len], replacement);
        self.gap_start += replacement.len;
        for (replacement) |byte| {
            if (byte >= 0x80) self.non_ascii_bytes += 1;
        }
        self.snapshot_valid = false;
    }
};

test "gap moves in both directions and reads leave it in place" {
    var gap: GapBuffer = .{ .allocator = std.testing.allocator };
    defer gap.deinit();
    try gap.reserve(12);
    gap.replaceAssumeCapacity(0, 0, "abcdefΩ");
    gap.replaceAssumeCapacity(1, 3, "XY");
    try std.testing.expectEqualStrings("aXYdefΩ", gap.text());
    try std.testing.expectEqual(@as(usize, 3), gap.gap_start);
    gap.replaceAssumeCapacity(6, 8, "!");
    gap.replaceAssumeCapacity(0, 1, "12");
    try std.testing.expectEqualStrings("12XYdef!", gap.text());
    try std.testing.expectEqual(@as(usize, 0), gap.non_ascii_bytes);
    try gap.reserve(200);
    try std.testing.expectEqualStrings("12XYdef!", gap.text());
    gap.replaceAssumeCapacity(4, 7, "Ω");
    try std.testing.expectEqualStrings("12XYΩ!", gap.text());
    try std.testing.expectEqual(@as(usize, 2), gap.non_ascii_bytes);
}
