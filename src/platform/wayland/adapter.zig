const std = @import("std");
const wayring = @import("wayring");
const OuroLoop = @import("../../loop/io_uring.zig").Loop;

/// Ourokit's containment boundary around Wayring. It intentionally exposes no
/// protocol object types to UI, scene, renderer, Lua, or task modules.
pub const Adapter = struct {
    reactor: wayring.io_uring.Reactor,

    /// Both `self` and `loop` must remain at stable addresses through `deinit`.
    /// The caller retains sole ownership of submission and CQE draining.
    pub fn init(
        self: *Adapter,
        allocator: std.mem.Allocator,
        loop: *OuroLoop,
        config: wayring.io_uring.Config,
    ) !void {
        try self.reactor.initBorrowed(allocator, &loop.ring, config);
    }

    pub fn deinit(self: *Adapter, allocator: std.mem.Allocator) void {
        self.reactor.deinit(allocator);
        self.* = undefined;
    }

    /// Call only after application CQEs have been filtered by their disjoint
    /// low-byte namespace. Wayring owns low-byte tags 1 through 5.
    pub fn route(self: *const Adapter, completion: std.os.linux.io_uring_cqe) ?wayring.io_uring.CompletionTarget {
        return self.reactor.route(null, completion);
    }
};

test "adapter is statically bound to Wayring's borrowed-ring reactor" {
    try std.testing.expect(@hasDecl(wayring.io_uring.Reactor, "initBorrowed"));
    try std.testing.expect(@hasDecl(Adapter, "route"));
}
