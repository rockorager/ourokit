pub const SourceProvider = @import("source.zig").SourceProvider;
pub const SourceSnapshot = @import("source.zig").SourceSnapshot;
pub const SourceContentHash = @import("source.zig").ContentHash;
pub const module_name = @import("module_name.zig");

test {
    _ = @import("source.zig");
    _ = @import("module_name.zig");
}
