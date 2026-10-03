const std = @import("std");

/// Copied command identity shared by editor recipes and contextual bindings.
pub const Name = struct {
    bytes: [64]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(value: []const u8) !Name {
        if (value.len == 0 or value.len > 64) return error.InvalidCommandName;
        var result: Name = .{ .len = @intCast(value.len) };
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn eql(a: Name, b: Name) bool {
        return std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }
};
