pub const window = @import("window.zig");
pub const wayland = @import("wayland/root.zig");

test {
    _ = @import("window.zig");
    _ = @import("wayland/root.zig");
}
