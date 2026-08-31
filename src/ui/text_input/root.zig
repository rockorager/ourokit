pub const Range = @import("model.zig").Range;
pub const Selection = @import("model.zig").Selection;
pub const Model = @import("model.zig").Model;
pub const Session = @import("session.zig").Session;
pub const EditBatch = @import("session.zig").EditBatch;
pub const Preedit = @import("session.zig").Preedit;
pub const Registry = @import("registry.zig").Registry;

test {
    _ = @import("model.zig");
    _ = @import("session.zig");
    _ = @import("registry.zig");
}
