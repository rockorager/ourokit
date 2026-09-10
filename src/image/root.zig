pub const Bitmap = @import("pixels.zig").Bitmap;
pub const Fit = @import("pixels.zig").Fit;
pub const Cache = @import("cache.zig").Cache;
pub const ImageHandle = @import("cache.zig").ImageHandle;
pub const codec = @import("codec.zig");
pub const Service = @import("service.zig").Service;

test {
    _ = @import("cache.zig");
    _ = codec;
    _ = @import("service.zig");
}
