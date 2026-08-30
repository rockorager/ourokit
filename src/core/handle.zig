/// Non-owning identity for slot-backed state. A generation change makes every
/// older copy inert without relying on an allocated address remaining valid.
pub const Handle = struct {
    slot: u32,
    generation: u32,

    pub const invalid: Handle = .{ .slot = std.math.maxInt(u32), .generation = 0 };

    const std = @import("std");
};
