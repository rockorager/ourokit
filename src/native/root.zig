//! Experimental native module boundary, shared by dynamic and linked hosts.
pub const abi = @cImport({
    @cInclude("ourokit/plugin.h");
});
pub const Module = @import("registry.zig").Module;
pub const Registry = @import("registry.zig").Registry;
pub const Libraries = @import("libraries.zig").Libraries;
pub const LibraryPath = @import("libraries.zig").Path;

test {
    _ = @import("registry.zig");
    _ = @import("libraries.zig");
}
