pub const SourceProvider = @import("source.zig").SourceProvider;
pub const SourceSnapshot = @import("source.zig").SourceSnapshot;
pub const SourceContentHash = @import("source.zig").ContentHash;

test {
    _ = @import("source.zig");
}
