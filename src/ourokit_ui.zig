//! Platform-neutral Ourokit embedding boundary.
//!
//! This module intentionally excludes the application host, scheduler, Lua,
//! Wayland client integration, and Vulkan presentation backend. Applications
//! own text caches and software-rendering targets explicitly.

pub const core = @import("core/root.zig");
pub const text = @import("text/root.zig");
pub const scene = @import("scene/root.zig");
pub const layout = @import("ui/layout/root.zig");
pub const render_object = @import("ui/render_object/root.zig");
pub const software = @import("renderer/software/root.zig");
pub const Surface = @import("ui/surface.zig").Surface;
pub const Descriptor = @import("ui/surface.zig").Descriptor;
pub const PointerResult = @import("ui/surface.zig").PointerResult;

test {
    _ = core;
    _ = text;
    _ = scene;
    _ = layout;
    _ = render_object;
    _ = software;
    _ = Surface;
}
