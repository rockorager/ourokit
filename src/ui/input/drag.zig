const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;
const PointF = @import("../../core/geometry.zig").PointF;

/// App-local type tags and item IDs, copied across the build boundary. No Lua
/// references or Wayland serials survive in a drag session.
pub const Name = struct {
    bytes: [127]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(value: []const u8) !Name {
        if (value.len == 0 or value.len > 127 or !std.unicode.utf8ValidateSlice(value) or
            std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidDragName;
        var result: Name = .{ .len = @intCast(value.len) };
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: Name, b: Name) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }

    fn validate(self: Name) !void {
        if (self.len > self.bytes.len) return error.InvalidDragName;
        _ = try init(self.slice());
    }
};

pub const Payload = struct {
    kind: Name,
    value: Name,
};

pub const Options = struct {
    source: ?Payload = null,
    accept: ?Name = null,

    pub fn validate(self: Options) !void {
        if (self.source) |source| {
            try source.kind.validate();
            try source.value.validate();
        }
        if (self.accept) |accept| try accept.validate();
    }
};

pub const Session = struct {
    source: Handle,
    payload: Payload,
    start: PointF,
    position: PointF,
    target: ?Handle = null,
    active: bool = false,

    pub fn move(self: *Session, position: PointF) void {
        self.position = position;
        const dx = position.x - self.start.x;
        const dy = position.y - self.start.y;
        self.active = self.active or dx * dx + dy * dy >= 36;
    }
};

test "internal drag owns payloads and crosses a logical six pixel threshold" {
    var bytes = [_]u8{ 't', 'a', 'b' };
    const kind = try Name.init(&bytes);
    var session: Session = .{ .source = .{ .slot = 1, .generation = 3 }, .payload = .{ .kind = kind, .value = try Name.init("document-7") }, .start = .{ .x = 20, .y = 40 }, .position = .{ .x = 20, .y = 40 } };
    @memset(&bytes, 'x');
    try std.testing.expectEqualStrings("tab", session.payload.kind.slice());
    session.move(.{ .x = 23, .y = 44 });
    try std.testing.expect(!session.active);
    session.move(.{ .x = 20, .y = 46 });
    try std.testing.expect(session.active);
    session.move(.{ .x = 20, .y = 40 });
    try std.testing.expect(session.active);
    try std.testing.expectError(error.InvalidDragName, Name.init(""));
    try std.testing.expectError(error.InvalidDragName, Name.init("a\x00b"));
    try std.testing.expectError(error.InvalidDragName, Name.init(&(@as([128]u8, @splat('a')))));
}
