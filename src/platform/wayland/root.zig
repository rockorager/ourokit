pub const Adapter = @import("adapter.zig").Adapter;
pub const Host = @import("host.zig").Host;
pub const HostConfig = @import("host.zig").Config;
pub const Frame = @import("host.zig").Frame;
pub const PresentationBackend = @import("host.zig").PresentationBackend;
pub const PresentationTiming = @import("host.zig").PresentationTiming;

test {
    _ = @import("adapter.zig");
    _ = @import("clipboard.zig");
    _ = @import("host.zig");
    _ = @import("repeat.zig");
    _ = @import("text_input.zig");
}
