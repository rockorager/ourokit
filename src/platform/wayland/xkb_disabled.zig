const platform = @import("../window.zig");

pub const Keyboard = struct {
    pub fn init() !Keyboard {
        return .{};
    }
    pub fn deinit(_: *Keyboard) void {}
    pub fn installKeymap(_: *Keyboard, fd: @import("std").os.linux.fd_t, _: u32) !void {
        _ = @import("std").os.linux.close(fd);
    }
    pub fn updateModifiers(_: *Keyboard, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn translate(_: *Keyboard, keycode: u32) platform.TranslatedKey {
        return .{ .keycode = keycode };
    }
};
