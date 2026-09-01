const std = @import("std");

/// Thread-safe edge between an external control producer and the application
/// coordinator. Producers only request work; source reads and commits remain
/// owned by the coordinator's reconciliation safe point.
pub const ReloadRequests = struct {
    requested: std.atomic.Value(u64) = .init(0),
    consumed: u64 = 0,

    /// Requests coalesce: the coordinator performs one reload for every batch
    /// visible at a safe point, not one reload for every producer call.
    pub fn request(self: *ReloadRequests) u64 {
        return self.requested.fetchAdd(1, .release) + 1;
    }

    /// Single-consumer operation. The returned sequence identifies the newest
    /// request included in this batch. Requests arriving during preparation
    /// remain pending for the following safe point.
    pub fn take(self: *ReloadRequests) ?u64 {
        const newest = self.requested.load(.acquire);
        if (newest == self.consumed) return null;
        self.consumed = newest;
        return newest;
    }
};

test "reload requests coalesce without losing a later request" {
    var requests: ReloadRequests = .{};
    try std.testing.expect(requests.take() == null);

    try std.testing.expectEqual(@as(u64, 1), requests.request());
    try std.testing.expectEqual(@as(u64, 2), requests.request());
    try std.testing.expectEqual(@as(?u64, 2), requests.take());
    try std.testing.expect(requests.take() == null);

    try std.testing.expectEqual(@as(u64, 3), requests.request());
    try std.testing.expectEqual(@as(?u64, 3), requests.take());
}
