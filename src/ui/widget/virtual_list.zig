const std = @import("std");

/// Build/layout feedback contains only mounted rows, never item providers.
pub const List = struct {
    id: u64,
    width: f32,
    viewport: f32,
    offset: f32,
    total: f32,
    estimate: f32,
    fixed: bool,
    row_start: usize,
    row_count: usize,
};

pub const Row = struct { id: u64, y: f32, height: f32 };

pub const Snapshot = struct {
    lists: [32]List = undefined,
    count: usize = 0,
    rows: [256]Row = undefined,
    row_count: usize = 0,

    pub fn find(self: *const Snapshot, id: u64) ?List {
        for (self.lists[0..self.count]) |list| if (list.id == id) return list;
        return null;
    }
};

pub fn rowId(list: u64, key: []const u8) u64 {
    return std.hash.Wyhash.hash(0x76697274726f77 ^ list, key) | (@as(u64, 1) << 63);
}
