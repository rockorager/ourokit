const std = @import("std");

/// Hard line breaks become spaces, with CRLF treated as one break. Offsets
/// remain UTF-8 byte offsets; IME preedit cursors use the same transformation.
pub fn breakLength(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return switch (bytes[0]) {
        '\r' => if (bytes.len > 1 and bytes[1] == '\n') 2 else 1,
        '\n', 0x0b, 0x0c => 1,
        0xc2 => if (std.mem.startsWith(u8, bytes, "\u{85}")) 2 else 0,
        0xe2 => if (std.mem.startsWith(u8, bytes, "\u{2028}") or
            std.mem.startsWith(u8, bytes, "\u{2029}")) 3 else 0,
        else => 0,
    };
}

pub fn offset(bytes: []const u8, original: usize) usize {
    var read: usize = 0;
    var written: usize = 0;
    while (read < original) {
        read += @max(1, breakLength(bytes[read..]));
        written += 1;
    }
    return written;
}

/// Returns owned normalized text only when a transformation is necessary.
/// Callers validate UTF-8 before calling this function.
pub fn normalize(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    for (bytes, 0..) |_, index| {
        if (breakLength(bytes[index..]) != 0) break;
    } else return null;
    const result = try allocator.alloc(u8, offset(bytes, bytes.len));
    var read: usize = 0;
    for (result) |*byte| {
        const length = breakLength(bytes[read..]);
        byte.* = if (length != 0) ' ' else bytes[read];
        read += @max(1, length);
    }
    return result;
}

test "single line normalization preserves words and maps preedit byte offsets" {
    const original = "é\r\nB\u{2028}C\n\rD\u{85}E\x0bF\x0cG\u{2029}👩🏽‍🚀";
    const normalized = (try normalize(std.testing.allocator, original)).?;
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("é B C  D E F G 👩🏽‍🚀", normalized);
    try std.testing.expectEqual(@as(usize, 2), offset(original, "é".len));
    try std.testing.expectEqual(@as(usize, 3), offset(original, "é\r".len));
    try std.testing.expectEqual(@as(usize, 3), offset(original, "é\r\n".len));
    try std.testing.expectEqual(@as(usize, 5), offset(original, "é\r\nB\u{2028}".len));
    try std.testing.expectEqual(normalized.len, offset(original, original.len));
    try std.testing.expect((try normalize(std.testing.allocator, "é\t👩🏽‍🚀")) == null);
}
