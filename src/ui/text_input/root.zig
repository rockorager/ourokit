pub const Range = @import("model.zig").Range;
pub const Selection = @import("model.zig").Selection;
pub const Model = @import("model.zig").Model;
pub const EditIntent = @import("intent.zig").Intent;
pub const MoveIntent = @import("intent.zig").Move;
pub const MoveDestination = @import("intent.zig").Destination;
pub const Session = @import("session.zig").Session;
pub const EditBatch = @import("session.zig").EditBatch;
pub const Preedit = @import("session.zig").Preedit;
pub const Presentation = @import("presentation.zig").Presentation;
pub const buildPresentation = @import("presentation.zig").build;
pub const Registry = @import("registry.zig").Registry;
pub const ValueMode = @import("registry.zig").ValueMode;
pub const Behavior = @import("registry.zig").Behavior;

test {
    _ = @import("intent.zig");
    _ = @import("model.zig");
    _ = @import("session.zig");
    _ = @import("presentation.zig");
    _ = @import("registry.zig");
}
