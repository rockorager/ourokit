//! Rendering backends consume `scene.DisplayList`; they do not own UI policy,
//! Lua values, platform objects, or design-token selection.

const build_options = @import("ourokit_build_options");

pub const has_vulkan = build_options.vulkan;
pub const software = @import("software/root.zig");
pub const png = @import("png.zig");
pub const vulkan = if (has_vulkan)
    @import("vulkan/root.zig")
else
    @import("vulkan/disabled.zig");
pub const log = @import("log.zig");
pub const conformance = @import("conformance.zig");

test {
    _ = @import("software/root.zig");
    _ = @import("png.zig");
    _ = vulkan;
    _ = @import("log.zig");
    _ = @import("conformance.zig");
}
