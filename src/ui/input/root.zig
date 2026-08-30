pub const Event = @import("router.zig").Event;
pub const Router = @import("router.zig").Router;
pub const PointerBindings = @import("bindings.zig").PointerBindings;
pub const HandlerId = @import("bindings.zig").HandlerId;

test {
    _ = @import("router.zig");
    _ = @import("bindings.zig");
}
