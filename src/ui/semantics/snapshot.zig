const std = @import("std");

pub const Role = enum { group, label, button };

/// Borrowed normalized semantic data emitted beside render descriptors during
/// one build. Text is copied into the retained Snapshot before another Lua call.
pub const Descriptor = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    label: []const u8 = "",
    enabled: bool = true,
};

const StoredNode = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    label_start: usize,
    label_len: usize,
    enabled: bool,
};

pub const Node = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    label: []const u8,
    enabled: bool,
};

/// Double-buffered, allocation-free-after-init semantic snapshot suitable for
/// headless assertions and future accessibility protocol translation.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    nodes: [2][]StoredNode,
    text: [2][]u8,
    validation_index: []u64,
    active: usize = 0,
    node_count: usize = 0,
    text_count: usize = 0,
    staged_node_count: usize = 0,
    staged_text_count: usize = 0,
    has_staged: bool = false,

    pub fn init(
        self: *Snapshot,
        allocator: std.mem.Allocator,
        node_capacity: usize,
        text_capacity: usize,
    ) !void {
        if (node_capacity == 0 or text_capacity == 0) return error.InvalidSemanticCapacity;
        const nodes_a = try allocator.alloc(StoredNode, node_capacity);
        errdefer allocator.free(nodes_a);
        const nodes_b = try allocator.alloc(StoredNode, node_capacity);
        errdefer allocator.free(nodes_b);
        const text_a = try allocator.alloc(u8, text_capacity);
        errdefer allocator.free(text_a);
        const text_b = try allocator.alloc(u8, text_capacity);
        errdefer allocator.free(text_b);
        const validation_index = try allocator.alloc(u64, try indexCapacity(node_capacity));
        self.* = .{
            .allocator = allocator,
            .nodes = .{ nodes_a, nodes_b },
            .text = .{ text_a, text_b },
            .validation_index = validation_index,
        };
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.validation_index);
        self.allocator.free(self.text[1]);
        self.allocator.free(self.text[0]);
        self.allocator.free(self.nodes[1]);
        self.allocator.free(self.nodes[0]);
        self.* = undefined;
    }

    pub fn validate(self: *Snapshot, descriptors: []const Descriptor) !void {
        if (descriptors.len > self.nodes[0].len) return error.SemanticNodeCapacityExceeded;
        @memset(self.validation_index, 0);
        var text_count: usize = 0;
        for (descriptors) |descriptor| {
            if (descriptor.id == 0) return error.InvalidSemanticId;
            text_count = std.math.add(usize, text_count, descriptor.label.len) catch
                return error.SemanticTextCapacityExceeded;
            if (text_count > self.text[0].len) return error.SemanticTextCapacityExceeded;
            if (descriptor.parent) |parent| if (!indexContains(self.validation_index, parent))
                return error.SemanticParentMustPrecedeChild;
            if (!indexPut(self.validation_index, descriptor.id)) return error.DuplicateSemanticId;
            if ((descriptor.role == .label or descriptor.role == .button) and descriptor.label.len == 0)
                return error.SemanticLabelRequired;
        }
    }

    /// Copies borrowed descriptor text into the inactive buffer before any
    /// subsequent Lua API call can trigger collection. The retained snapshot
    /// remains unchanged until `commitStaged` completes the build transaction.
    pub fn stage(self: *Snapshot, descriptors: []const Descriptor) void {
        const next = 1 - self.active;
        var text_count: usize = 0;
        for (descriptors, self.nodes[next][0..descriptors.len]) |descriptor, *stored_node| {
            @memcpy(self.text[next][text_count..][0..descriptor.label.len], descriptor.label);
            stored_node.* = .{
                .id = descriptor.id,
                .parent = descriptor.parent,
                .role = descriptor.role,
                .label_start = text_count,
                .label_len = descriptor.label.len,
                .enabled = descriptor.enabled,
            };
            text_count += descriptor.label.len;
        }
        self.staged_node_count = descriptors.len;
        self.staged_text_count = text_count;
        self.has_staged = true;
    }

    pub fn commitStaged(self: *Snapshot) void {
        std.debug.assert(self.has_staged);
        self.active = 1 - self.active;
        self.node_count = self.staged_node_count;
        self.text_count = self.staged_text_count;
        self.has_staged = false;
    }

    pub fn discardStaged(self: *Snapshot) void {
        self.has_staged = false;
    }

    pub fn count(self: *const Snapshot) usize {
        return self.node_count;
    }

    pub fn node(self: *const Snapshot, index: usize) !Node {
        if (index >= self.node_count) return error.SemanticNodeOutOfBounds;
        const stored = self.nodes[self.active][index];
        return .{
            .id = stored.id,
            .parent = stored.parent,
            .role = stored.role,
            .label = self.text[self.active][stored.label_start..][0..stored.label_len],
            .enabled = stored.enabled,
        };
    }
};

fn indexCapacity(capacity: usize) !usize {
    const target = std.math.mul(usize, capacity, 2) catch return error.CapacityOverflow;
    var result: usize = 1;
    while (result < target)
        result = std.math.mul(usize, result, 2) catch return error.CapacityOverflow;
    return result;
}

fn indexPut(index: []u64, key: u64) bool {
    var slot = hash(key) & (index.len - 1);
    for (0..index.len) |_| {
        if (index[slot] == 0) {
            index[slot] = key;
            return true;
        }
        if (index[slot] == key) return false;
        slot = (slot + 1) & (index.len - 1);
    }
    unreachable;
}

fn indexContains(index: []const u64, key: u64) bool {
    var slot = hash(key) & (index.len - 1);
    for (0..index.len) |_| {
        if (index[slot] == 0) return false;
        if (index[slot] == key) return true;
        slot = (slot + 1) & (index.len - 1);
    }
    return false;
}

fn hash(key: u64) usize {
    var value = key +% 0x9e3779b97f4a7c15;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    return @truncate(value ^ (value >> 31));
}

test "semantic snapshots are deterministic, validated, and replace atomically" {
    var snapshot: Snapshot = undefined;
    try snapshot.init(std.testing.allocator, 3, 64);
    defer snapshot.deinit();
    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .role = .group },
        .{ .id = 2, .parent = 1, .role = .label, .label = "Settings" },
        .{ .id = 3, .parent = 1, .role = .button, .label = "Save", .enabled = false },
    };
    try snapshot.validate(&initial);
    snapshot.stage(&initial);
    try std.testing.expectEqual(@as(usize, 0), snapshot.count());
    snapshot.commitStaged();
    try std.testing.expectEqual(@as(usize, 3), snapshot.count());
    try std.testing.expectEqualStrings("Settings", (try snapshot.node(1)).label);
    try std.testing.expect(!(try snapshot.node(2)).enabled);
    try std.testing.expectError(error.SemanticParentMustPrecedeChild, snapshot.validate(&.{
        .{ .id = 4, .parent = 9, .role = .label, .label = "Invalid" },
    }));
    try std.testing.expectEqualStrings("Settings", (try snapshot.node(1)).label);
}
