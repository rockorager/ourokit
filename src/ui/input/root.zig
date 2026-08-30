pub const Event = @import("router.zig").Event;
pub const Router = @import("router.zig").Router;
pub const PointerBindings = @import("bindings.zig").PointerBindings;
pub const Handler = @import("bindings.zig").Handler;
pub const HandlerKind = @import("bindings.zig").HandlerKind;

test {
    _ = @import("router.zig");
    _ = @import("bindings.zig");
}
