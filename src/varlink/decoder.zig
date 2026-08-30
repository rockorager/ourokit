const std = @import("std");

/// Incrementally collects one NUL-terminated Varlink JSON record. The caller
/// decides when to consume a complete frame so event-queue backpressure can
/// stop before consuming the delimiter.
pub const Decoder = struct {
    storage: std.array_list.Managed(u8),
    max_message_bytes: usize,

    pub fn init(allocator: std.mem.Allocator, max_message_bytes: usize) !Decoder {
        if (max_message_bytes == 0) return error.InvalidCapacity;
        return .{
            .storage = .init(allocator),
            .max_message_bytes = max_message_bytes,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.storage.deinit();
        self.* = undefined;
    }

    pub fn push(self: *Decoder, byte: u8) !?[]const u8 {
        if (byte == 0) return self.storage.items;
        if (self.storage.items.len == self.max_message_bytes) return error.MessageTooLarge;
        try self.storage.append(byte);
        return null;
    }

    pub fn consumeFrame(self: *Decoder) void {
        self.storage.clearRetainingCapacity();
    }
};

test "decoder preserves fragmented records and enforces its bound" {
    var decoder = try Decoder.init(std.testing.allocator, 3);
    defer decoder.deinit();

    try std.testing.expect(try decoder.push('a') == null);
    try std.testing.expect(try decoder.push('b') == null);
    try std.testing.expectEqualSlices(u8, "ab", (try decoder.push(0)).?);
    decoder.consumeFrame();
    try std.testing.expect(try decoder.push('a') == null);
    try std.testing.expect(try decoder.push('b') == null);
    try std.testing.expect(try decoder.push('c') == null);
    try std.testing.expectError(error.MessageTooLarge, decoder.push('d'));
}
