//! Rendering backends consume `scene.DisplayList`; they do not own UI policy,
//! Lua values, platform objects, or design-token selection.

pub const software = @import("software/root.zig");
pub const vulkan = @import("vulkan/root.zig");
pub const log = @import("log.zig");
pub const conformance = @import("conformance.zig");

test {
    _ = @import("software/root.zig");
    _ = @import("vulkan/root.zig");
    _ = @import("log.zig");
    _ = @import("conformance.zig");
}
