const Handle = @import("../core/handle.zig").Handle;

/// Provenance of one actual input press, carried by its UI callback only.
pub const Input = struct { window: Handle, serial: u32 };

/// Caller retains stable storage until completion or successful cancellation.
pub const Request = struct {
    input: Input,
    context: *anyopaque,
    complete: *const fn (*anyopaque, anyerror![]const u8) anyerror!void,
};

pub const Provider = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque, *Request) anyerror!void,
    cancel: *const fn (*anyopaque, *Request) anyerror!void,
};
