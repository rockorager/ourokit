pub const wire = @import("wire.zig");
pub const Client = @import("connection.zig").Client;

test {
    _ = @import("wire.zig");
    _ = @import("connection.zig");
}
