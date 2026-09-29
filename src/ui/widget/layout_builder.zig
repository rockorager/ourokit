const Constraints = @import("../layout/constraints.zig").Constraints;

/// Native measurements only. Lua callbacks remain in the build transaction.
pub const Entry = struct { id: u64, constraints: ?Constraints = null };

pub const Snapshot = struct {
    entries: [128]Entry = undefined,
    count: usize = 0,

    pub fn find(self: *const Snapshot, id: u64) ?Constraints {
        for (self.entries[0..self.count]) |entry| if (entry.id == id) return entry.constraints;
        return null;
    }
};
