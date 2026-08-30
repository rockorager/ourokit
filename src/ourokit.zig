//! Ourokit's public module boundaries.

pub const core = @import("core/root.zig");
pub const design = @import("design/root.zig");
pub const loop = @import("loop/root.zig");
pub const task = @import("task/root.zig");
pub const lua = @import("lua/root.zig");
pub const scene = @import("scene/root.zig");
pub const renderer = @import("renderer/root.zig");
pub const platform = @import("platform/root.zig");
pub const app = @import("app/root.zig");

test {
    _ = core;
    _ = design;
    _ = loop;
    _ = task;
    _ = lua;
    _ = scene;
    _ = renderer;
    _ = platform;
    _ = app;
}
