pub const Adapter = @import("adapter.zig").Adapter;
pub const Host = @import("host.zig").Host;
pub const HostConfig = @import("host.zig").Config;
pub const Frame = @import("host.zig").Frame;

test {
    _ = @import("adapter.zig");
    _ = @import("host.zig");
}
