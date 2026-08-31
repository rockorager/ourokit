pub const App = @import("app.zig").App;
pub const Phase = @import("app.zig").Phase;
pub const frame = @import("frame.zig");
pub const turn = @import("turn.zig");
pub const windows = @import("windows.zig");
pub const WindowRuntime = @import("window_runtime.zig").WindowRuntime;
pub const WindowRuntimeConfig = @import("window_runtime.zig").Config;
pub const SourceGeneration = @import("source_generation.zig").SourceGeneration;
pub const runWayland = @import("wayland_runner.zig").run;
pub const runWaylandSource = @import("wayland_runner.zig").runSource;
pub const WaylandRunOptions = @import("wayland_runner.zig").Options;

test {
    _ = @import("app.zig");
    _ = @import("frame.zig");
    _ = @import("turn.zig");
    _ = @import("windows.zig");
    _ = @import("window_runtime.zig");
    _ = @import("source_generation.zig");
    _ = @import("wayland_runner.zig");
}
