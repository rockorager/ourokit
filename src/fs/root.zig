pub const Reader = @import("full_file.zig").Reader;
pub const ReadHandle = @import("full_file.zig").ReadHandle;
pub const ReadOptions = @import("full_file.zig").Options;
pub const Contents = @import("full_file.zig").Contents;
pub const Identity = @import("full_file.zig").Identity;

test {
    _ = @import("full_file.zig");
}
