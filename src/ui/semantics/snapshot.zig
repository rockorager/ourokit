const std = @import("std");

pub const Role = enum { group, text, button, text_field, listbox, option, tab_list, tab, separator, image, @"switch", checkbox, radio_group, radio, slider, dialog, link };
const Range = @import("../widget/range.zig").Range;

/// Borrowed normalized semantic data emitted beside render descriptors during
/// one build. Text is copied into the retained Snapshot before another Lua call.
pub const Descriptor = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    key: []const u8 = "",
    label: []const u8 = "",
    enabled: bool = true,
    selected: bool = false,
    checked: bool = false,
    expanded: ?bool = null,
    range: ?Range = null,
    /// Reuse this group's existing semantic descendants from the active snapshot.
    retain_subtree: bool = false,
};

const StoredNode = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    key_start: usize,
    key_len: usize,
    label_start: usize,
    label_len: usize,
    enabled: bool,
    selected: bool,
    checked: bool,
    expanded: ?bool,
    range: ?Range,
    first_child: ?usize,
    next_sibling: ?usize,
};

const IndexEntry = struct { id: u64 = 0, index: usize = 0 };

pub const Node = struct {
    id: u64,
    parent: ?u64,
    role: Role,
    key: []const u8,
    label: []const u8,
    enabled: bool,
    selected: bool,
    checked: bool,
    expanded: ?bool,
    range: ?Range,
};

/// Double-buffered, allocation-free-after-init semantic snapshot suitable for
/// headless assertions and future accessibility protocol translation.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    nodes: [2][]StoredNode,
    text: [2][]u8,
    validation_index: []u64,
    active_index: []IndexEntry,
    output_index: []IndexEntry,
    last_child: []?usize,
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
        errdefer allocator.free(validation_index);
        const active_index = try allocator.alloc(IndexEntry, try indexCapacity(node_capacity));
        errdefer allocator.free(active_index);
        const output_index = try allocator.alloc(IndexEntry, try indexCapacity(node_capacity));
        errdefer allocator.free(output_index);
        const last_child = try allocator.alloc(?usize, node_capacity);
        self.* = .{
            .allocator = allocator,
            .nodes = .{ nodes_a, nodes_b },
            .text = .{ text_a, text_b },
            .validation_index = validation_index,
            .active_index = active_index,
            .output_index = output_index,
            .last_child = last_child,
        };
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.last_child);
        self.allocator.free(self.output_index);
        self.allocator.free(self.active_index);
        self.allocator.free(self.validation_index);
        self.allocator.free(self.text[1]);
        self.allocator.free(self.text[0]);
        self.allocator.free(self.nodes[1]);
        self.allocator.free(self.nodes[0]);
        self.* = undefined;
    }

    pub fn validate(self: *Snapshot, descriptors: []const Descriptor) !void {
        @memset(self.validation_index, 0);
        self.buildActiveIndex();
        var node_count: usize = 0;
        var text_count: usize = 0;
        var dialog_seen = false;
        for (descriptors) |descriptor| {
            try self.validateOne(descriptor.id, descriptor.parent, descriptor.role, descriptor.key, descriptor.label, descriptor.range, &node_count, &text_count, &dialog_seen);
            if (descriptor.retain_subtree) {
                const old_index = lookup(self.active_index, descriptor.id) orelse return error.RetainedSemanticIdNotFound;
                if (!optionalIdEqual(self.nodes[self.active][old_index].parent, descriptor.parent))
                    return error.RetainedSemanticReparented;
                var child = self.nodes[self.active][old_index].first_child;
                while (child) |index| {
                    try self.validateRetained(index, &node_count, &text_count, &dialog_seen);
                    child = self.nodes[self.active][index].next_sibling;
                }
            }
        }
    }

    /// Copies borrowed descriptor text into the inactive buffer before any
    /// subsequent Lua API call can trigger collection. The retained snapshot
    /// remains unchanged until `commitStaged` completes the build transaction.
    pub fn stage(self: *Snapshot, descriptors: []const Descriptor) void {
        const next = 1 - self.active;
        self.buildActiveIndex();
        @memset(self.last_child, null);
        @memset(self.output_index, .{});
        var node_count: usize = 0;
        var text_count: usize = 0;
        for (descriptors) |descriptor| {
            self.stageOne(next, descriptor.id, descriptor.parent, descriptor.role, descriptor.key, descriptor.label, descriptor.enabled, descriptor.selected, descriptor.checked, descriptor.expanded, descriptor.range, &node_count, &text_count);
            if (descriptor.retain_subtree) {
                const old_index = lookup(self.active_index, descriptor.id).?;
                var child = self.nodes[self.active][old_index].first_child;
                while (child) |index| {
                    self.stageRetained(next, index, &node_count, &text_count);
                    child = self.nodes[self.active][index].next_sibling;
                }
            }
        }
        self.staged_node_count = node_count;
        self.staged_text_count = text_count;
        self.has_staged = true;
    }

    fn buildActiveIndex(self: *Snapshot) void {
        @memset(self.active_index, .{});
        for (self.nodes[self.active][0..self.node_count], 0..) |node_value, index|
            putLookup(self.active_index, node_value.id, index);
    }

    fn validateOne(self: *Snapshot, id: u64, parent: ?u64, role: Role, key: []const u8, label: []const u8, range: ?Range, node_count: *usize, text_count: *usize, dialog_seen: *bool) !void {
        if (role == .dialog) {
            if (dialog_seen.*) return error.MultipleDialogsUnsupported;
            dialog_seen.* = true;
        }
        if (range) |value| try value.validate();
        if (id == 0) return error.InvalidSemanticId;
        node_count.* = std.math.add(usize, node_count.*, 1) catch return error.SemanticNodeCapacityExceeded;
        if (node_count.* > self.nodes[0].len) return error.SemanticNodeCapacityExceeded;
        text_count.* = std.math.add(usize, text_count.*, key.len) catch return error.SemanticTextCapacityExceeded;
        text_count.* = std.math.add(usize, text_count.*, label.len) catch return error.SemanticTextCapacityExceeded;
        if (text_count.* > self.text[0].len) return error.SemanticTextCapacityExceeded;
        if (parent) |parent_id| if (!indexContains(self.validation_index, parent_id)) return error.SemanticParentMustPrecedeChild;
        if (!indexPut(self.validation_index, id)) return error.DuplicateSemanticId;
        if ((role == .text or role == .button or role == .link or role == .option or role == .tab or role == .@"switch") and label.len == 0)
            return error.SemanticLabelRequired;
    }

    fn validateRetained(self: *Snapshot, old_index: usize, node_count: *usize, text_count: *usize, dialog_seen: *bool) !void {
        const old = self.nodes[self.active][old_index];
        const key = self.text[self.active][old.key_start..][0..old.key_len];
        const label = self.text[self.active][old.label_start..][0..old.label_len];
        try self.validateOne(old.id, old.parent, old.role, key, label, old.range, node_count, text_count, dialog_seen);
        var child = old.first_child;
        while (child) |index| {
            try self.validateRetained(index, node_count, text_count, dialog_seen);
            child = self.nodes[self.active][index].next_sibling;
        }
    }

    fn stageOne(self: *Snapshot, next: usize, id: u64, parent: ?u64, role: Role, key: []const u8, label: []const u8, enabled: bool, selected: bool, checked: bool, expanded: ?bool, range: ?Range, node_count: *usize, text_count: *usize) void {
        const index = node_count.*;
        const key_start = text_count.*;
        @memcpy(self.text[next][text_count.*..][0..key.len], key);
        text_count.* += key.len;
        const label_start = text_count.*;
        @memcpy(self.text[next][text_count.*..][0..label.len], label);
        text_count.* += label.len;
        self.nodes[next][index] = .{ .id = id, .parent = parent, .role = role, .key_start = key_start, .key_len = key.len, .label_start = label_start, .label_len = label.len, .enabled = enabled, .selected = selected, .checked = checked, .expanded = expanded, .range = range, .first_child = null, .next_sibling = null };
        putLookup(self.output_index, id, index);
        if (parent) |parent_id| {
            const parent_index = lookup(self.output_index, parent_id).?;
            if (self.last_child[parent_index]) |previous| self.nodes[next][previous].next_sibling = index else self.nodes[next][parent_index].first_child = index;
            self.last_child[parent_index] = index;
        }
        node_count.* += 1;
    }

    fn stageRetained(self: *Snapshot, next: usize, old_index: usize, node_count: *usize, text_count: *usize) void {
        const old = self.nodes[self.active][old_index];
        const key = self.text[self.active][old.key_start..][0..old.key_len];
        const label = self.text[self.active][old.label_start..][0..old.label_len];
        self.stageOne(next, old.id, old.parent, old.role, key, label, old.enabled, old.selected, old.checked, old.expanded, old.range, node_count, text_count);
        var child = old.first_child;
        while (child) |index| {
            self.stageRetained(next, index, node_count, text_count);
            child = self.nodes[self.active][index].next_sibling;
        }
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
        return self.nodeUnchecked(index);
    }

    pub fn findId(self: *const Snapshot, id: u64) ?Node {
        for (0..self.node_count) |index| {
            if (self.nodes[self.active][index].id == id) return self.nodeUnchecked(index);
        }
        return null;
    }

    /// Resolves slash-separated sibling keys from a semantic root. Raw keys
    /// are retained specifically so headless tools do not need to duplicate
    /// the domain-separated ID hashing used by widget constructors.
    pub fn findPath(self: *const Snapshot, path: []const u8) !Node {
        if (path.len == 0) return error.InvalidSemanticPath;
        var parent: ?u64 = null;
        var selected: ?Node = null;
        var segments = std.mem.splitScalar(u8, path, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0) return error.InvalidSemanticPath;
            selected = null;
            for (0..self.node_count) |index| {
                const candidate = self.nodeUnchecked(index);
                if (!optionalIdEqual(candidate.parent, parent) or
                    !std.mem.eql(u8, candidate.key, segment)) continue;
                if (selected != null) return error.AmbiguousSemanticPath;
                selected = candidate;
            }
            const node_value = selected orelse return error.SemanticPathNotFound;
            parent = node_value.id;
        }
        return selected.?;
    }

    fn nodeUnchecked(self: *const Snapshot, index: usize) Node {
        const stored = self.nodes[self.active][index];
        return .{
            .id = stored.id,
            .parent = stored.parent,
            .role = stored.role,
            .key = self.text[self.active][stored.key_start..][0..stored.key_len],
            .label = self.text[self.active][stored.label_start..][0..stored.label_len],
            .enabled = stored.enabled,
            .selected = stored.selected,
            .checked = stored.checked,
            .expanded = stored.expanded,
            .range = stored.range,
        };
    }
};

fn optionalIdEqual(a: ?u64, b: ?u64) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

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

fn putLookup(index: []IndexEntry, key: u64, value: usize) void {
    var slot = hash(key) & (index.len - 1);
    while (index[slot].id != 0) slot = (slot + 1) & (index.len - 1);
    index[slot] = .{ .id = key, .index = value };
}

fn lookup(index: []const IndexEntry, key: u64) ?usize {
    var slot = hash(key) & (index.len - 1);
    for (0..index.len) |_| {
        if (index[slot].id == 0) return null;
        if (index[slot].id == key) return index[slot].index;
        slot = (slot + 1) & (index.len - 1);
    }
    return null;
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
        .{ .id = 1, .parent = null, .role = .group, .key = "content" },
        .{ .id = 2, .parent = 1, .role = .text, .key = "heading", .label = "Settings" },
        .{ .id = 3, .parent = 1, .role = .button, .key = "save", .label = "Save", .enabled = false },
    };
    try snapshot.validate(&initial);
    snapshot.stage(&initial);
    try std.testing.expectEqual(@as(usize, 0), snapshot.count());
    snapshot.commitStaged();
    try std.testing.expectEqual(@as(usize, 3), snapshot.count());
    try std.testing.expectEqualStrings("Settings", (try snapshot.node(1)).label);
    try std.testing.expectEqualStrings("Save", (try snapshot.findPath("content/save")).label);
    try std.testing.expectError(error.SemanticPathNotFound, snapshot.findPath("content/missing"));
    try std.testing.expectError(error.InvalidSemanticPath, snapshot.findPath("content//save"));
    try std.testing.expect(!(try snapshot.node(2)).enabled);
    try std.testing.expectError(error.SemanticParentMustPrecedeChild, snapshot.validate(&.{
        .{ .id = 4, .parent = 9, .role = .text, .label = "Invalid" },
    }));
    try std.testing.expectEqualStrings("Settings", (try snapshot.node(1)).label);
}

test "retained semantic subtree is merged, reordered, and transactional" {
    var snapshot: Snapshot = undefined;
    try snapshot.init(std.testing.allocator, 8, 128);
    defer snapshot.deinit();
    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .role = .group, .key = "root" },
        .{ .id = 2, .parent = 1, .role = .group, .key = "component" },
        .{ .id = 3, .parent = 2, .role = .group, .key = "nested" },
        .{ .id = 4, .parent = 3, .role = .text, .key = "title", .label = "Owned label" },
        .{ .id = 5, .parent = 2, .role = .button, .key = "action", .label = "Act", .enabled = false },
        .{ .id = 6, .parent = 1, .role = .text, .key = "tail", .label = "Tail" },
    };
    try snapshot.validate(&initial);
    snapshot.stage(&initial);
    snapshot.commitStaged();

    const reordered = [_]Descriptor{
        .{ .id = 1, .parent = null, .role = .group, .key = "root" },
        .{ .id = 6, .parent = 1, .role = .text, .key = "tail", .label = "New tail" },
        .{ .id = 2, .parent = 1, .role = .group, .key = "component-new", .retain_subtree = true },
    };
    try snapshot.validate(&reordered);
    snapshot.stage(&reordered);
    try std.testing.expectEqualStrings("Owned label", (snapshot.findId(4).?).label);
    snapshot.discardStaged();
    try std.testing.expectEqualStrings("Tail", (snapshot.findId(6).?).label);
    try snapshot.validate(&reordered);
    snapshot.stage(&reordered);
    snapshot.commitStaged();
    try std.testing.expectEqual(@as(usize, 6), snapshot.count());
    try std.testing.expectEqualStrings("Owned label", (try snapshot.findPath("root/component-new/nested/title")).label);
    try std.testing.expect(!(snapshot.findId(5).?).enabled);
    try std.testing.expectEqualStrings("New tail", (try snapshot.node(1)).label);
}

test "expanded state distinguishes false true and absent across retained transactions" {
    var snapshot: Snapshot = undefined;
    try snapshot.init(std.testing.allocator, 6, 96);
    defer snapshot.deinit();
    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .role = .group, .key = "root" },
        .{ .id = 2, .parent = 1, .role = .group, .key = "component" },
        .{ .id = 3, .parent = 2, .role = .button, .key = "closed", .label = "Closed", .expanded = false },
        .{ .id = 4, .parent = 2, .role = .button, .key = "open", .label = "Open", .expanded = true },
        .{ .id = 5, .parent = 2, .role = .button, .key = "plain", .label = "Plain" },
    };
    try snapshot.validate(&initial);
    snapshot.stage(&initial);
    snapshot.commitStaged();
    try std.testing.expectEqual(@as(?bool, false), snapshot.findId(3).?.expanded);
    try std.testing.expectEqual(@as(?bool, true), snapshot.findId(4).?.expanded);
    try std.testing.expectEqual(@as(?bool, null), snapshot.findId(5).?.expanded);

    const retained = [_]Descriptor{
        .{ .id = 1, .parent = null, .role = .group, .key = "root", .expanded = true },
        .{ .id = 2, .parent = 1, .role = .group, .key = "component-new", .retain_subtree = true },
    };
    try snapshot.validate(&retained);
    snapshot.stage(&retained);
    try std.testing.expectEqual(@as(?bool, null), snapshot.findId(1).?.expanded);
    try std.testing.expectEqual(@as(?bool, false), snapshot.findId(3).?.expanded);
    snapshot.discardStaged();
    try std.testing.expectEqual(@as(?bool, null), snapshot.findId(1).?.expanded);
    try std.testing.expectEqual(@as(?bool, true), snapshot.findId(4).?.expanded);

    try snapshot.validate(&retained);
    snapshot.stage(&retained);
    snapshot.commitStaged();
    try std.testing.expectEqual(@as(?bool, true), snapshot.findId(1).?.expanded);
    try std.testing.expectEqual(@as(?bool, false), snapshot.findId(3).?.expanded);
    try std.testing.expectEqual(@as(?bool, true), snapshot.findId(4).?.expanded);
    try std.testing.expectEqual(@as(?bool, null), snapshot.findId(5).?.expanded);
}

test "retained semantic subtree rejects conflicts and capacity overflow" {
    var snapshot: Snapshot = undefined;
    try snapshot.init(std.testing.allocator, 4, 32);
    defer snapshot.deinit();
    const initial = [_]Descriptor{
        .{ .id = 1, .parent = null, .role = .group },
        .{ .id = 2, .parent = 1, .role = .group },
        .{ .id = 3, .parent = 2, .role = .text, .label = "child" },
    };
    try snapshot.validate(&initial);
    snapshot.stage(&initial);
    snapshot.commitStaged();
    try std.testing.expectError(error.RetainedSemanticIdNotFound, snapshot.validate(&.{
        .{ .id = 1, .parent = null, .role = .group }, .{ .id = 9, .parent = 1, .role = .group, .retain_subtree = true },
    }));
    try std.testing.expectError(error.RetainedSemanticReparented, snapshot.validate(&.{
        .{ .id = 2, .parent = null, .role = .group, .retain_subtree = true },
    }));
    try std.testing.expectError(error.DuplicateSemanticId, snapshot.validate(&.{
        .{ .id = 1, .parent = null, .role = .group }, .{ .id = 2, .parent = 1, .role = .group, .retain_subtree = true }, .{ .id = 3, .parent = 2, .role = .text, .label = "duplicate" },
    }));
    try std.testing.expectError(error.DuplicateSemanticId, snapshot.validate(&.{
        .{ .id = 1, .parent = null, .role = .group, .retain_subtree = true }, .{ .id = 2, .parent = 1, .role = .group, .retain_subtree = true },
    }));
    try snapshot.validate(&.{
        .{ .id = 1, .parent = null, .role = .group, .retain_subtree = true }, .{ .id = 4, .parent = 1, .role = .group },
    });
    try std.testing.expectError(error.SemanticNodeCapacityExceeded, snapshot.validate(&.{
        .{ .id = 1, .parent = null, .role = .group, .retain_subtree = true }, .{ .id = 4, .parent = 1, .role = .group }, .{ .id = 5, .parent = 1, .role = .group },
    }));
}
