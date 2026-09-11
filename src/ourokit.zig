//! Ourokit's public module boundaries.

pub const core = @import("core/root.zig");
pub const design = @import("design/root.zig");
pub const text = @import("text/root.zig");
pub const image = @import("image/root.zig");
pub const xdg = @import("xdg/root.zig");
pub const mcp = @import("mcp/root.zig");
pub const loop = @import("loop/root.zig");
pub const fs = @import("fs/root.zig");
pub const task = @import("task/root.zig");
pub const bundle = @import("bundle/root.zig");
pub const lua = @import("lua/root.zig");
pub const scene = @import("scene/root.zig");
pub const renderer = @import("renderer/root.zig");
pub const ui = @import("ui/root.zig");
pub const shell = @import("shell/root.zig");
pub const platform = @import("platform/root.zig");
pub const app = @import("app/root.zig");

test {
    _ = core;
    _ = design;
    _ = text;
    _ = image;
    _ = xdg;
    _ = mcp;
    _ = loop;
    _ = fs;
    _ = task;
    _ = bundle;
    _ = lua;
    _ = scene;
    _ = renderer;
    _ = ui;
    _ = shell;
    _ = platform;
    _ = app;
}
