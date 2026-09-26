const Handle = @import("../core/handle.zig").Handle;

pub const Export = struct {
    context: *anyopaque,
    handle: []const u8,
    closeFn: *const fn (*anyopaque) void,

    pub fn close(self: *Export) void {
        self.closeFn(self.context);
        self.* = undefined;
    }
};

pub const Request = struct {
    window: Handle = .invalid,
    context: *anyopaque,
    complete: *const fn (*anyopaque, anyerror!Export) anyerror!void,
};

/// The application adapter resolves the public window id to a current native
/// handle before forwarding the request to the platform host.
pub const Provider = struct {
    context: *anyopaque,
    start: *const fn (*anyopaque, []const u8, *Request) anyerror!void,
    cancel: *const fn (*anyopaque, *Request) anyerror!void,
};
