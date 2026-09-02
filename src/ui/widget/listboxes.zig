const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const instance = @import("../instance/tree.zig");
const BuildOwnerHandle = @import("../instance/build_owner.zig").BuildOwnerHandle;

pub const Visual = struct {
    background: ?Color,
    foreground: Color,
};
pub const Style = struct { idle: Visual, hovered: Visual, selected: Visual };
pub const VisualUpdate = struct {
    option: instance.InstanceHandle,
    content: instance.InstanceHandle,
    visual: Visual,
};
pub const Selection = struct {
    listbox: instance.InstanceHandle,
    option: instance.InstanceHandle,
    value: i64,
};

const ListBox = struct {
    owner: BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    selected: i64 = 0,
    active: bool = false,
    seen: bool = false,
};

const Option = struct {
    owner: BuildOwnerHandle = .invalid,
    listbox: instance.InstanceHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    content: instance.InstanceHandle = .invalid,
    value: i64 = 0,
    style: Style = undefined,
    hovered: bool = false,
    active: bool = false,
    seen: bool = false,
};

/// Retained interaction policy for single-selection list boxes. The listbox is
/// the focus target; options remain ordinary rendered boxes.
pub const ListBoxes = struct {
    allocator: std.mem.Allocator = undefined,
    lists: []ListBox = &.{},
    options: []Option = &.{},

    pub fn init(self: *ListBoxes, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidListBoxCapacity;
        const lists = try allocator.alloc(ListBox, capacity);
        errdefer allocator.free(lists);
        const options = try allocator.alloc(Option, capacity);
        @memset(lists, .{});
        @memset(options, .{});
        self.* = .{ .allocator = allocator, .lists = lists, .options = options };
    }

    pub fn deinit(self: *ListBoxes) void {
        self.allocator.free(self.options);
        self.allocator.free(self.lists);
        self.* = undefined;
    }

    pub fn clear(self: *ListBoxes) void {
        @memset(self.lists, .{});
        @memset(self.options, .{});
    }

    pub fn beginOwner(self: *ListBoxes, owner: BuildOwnerHandle) void {
        for (self.lists) |*entry| {
            if (entry.active and same(entry.owner, owner)) entry.seen = false;
        }
        for (self.options) |*entry| {
            if (entry.active and same(entry.owner, owner)) entry.seen = false;
        }
    }

    pub fn setList(self: *ListBoxes, owner: BuildOwnerHandle, target: instance.InstanceHandle, selected: i64) !void {
        for (self.lists) |*entry| if (entry.active and same(entry.target, target)) {
            entry.owner = owner;
            entry.selected = selected;
            entry.seen = true;
            return;
        };
        for (self.lists) |*entry| if (!entry.active) {
            entry.* = .{ .owner = owner, .target = target, .selected = selected, .active = true, .seen = true };
            return;
        };
        return error.ListBoxCapacityExceeded;
    }

    pub fn setOption(
        self: *ListBoxes,
        owner: BuildOwnerHandle,
        listbox: instance.InstanceHandle,
        target: instance.InstanceHandle,
        content: instance.InstanceHandle,
        value: i64,
        style: Style,
    ) !void {
        for (self.options) |*entry| if (entry.active and same(entry.target, target)) {
            entry.owner = owner;
            entry.listbox = listbox;
            entry.content = content;
            entry.value = value;
            entry.style = style;
            entry.seen = true;
            return;
        };
        for (self.options) |*entry| if (!entry.active) {
            entry.* = .{
                .owner = owner,
                .listbox = listbox,
                .target = target,
                .content = content,
                .value = value,
                .style = style,
                .active = true,
                .seen = true,
            };
            return;
        };
        return error.ListBoxOptionCapacityExceeded;
    }

    pub fn finishOwner(self: *ListBoxes, owner: BuildOwnerHandle) void {
        for (self.lists) |*entry| {
            if (entry.active and same(entry.owner, owner) and !entry.seen) entry.* = .{};
        }
        for (self.options) |*entry| {
            if (entry.active and same(entry.owner, owner) and !entry.seen) entry.* = .{};
        }
    }

    pub fn removeInactive(self: *ListBoxes, tree: *instance.Tree) void {
        for (self.lists) |*entry| {
            if (entry.active and !tree.isActive(entry.target)) entry.* = .{};
        }
        for (self.options) |*entry| {
            if (entry.active and (!tree.isActive(entry.target) or !tree.isActive(entry.listbox))) entry.* = .{};
        }
    }

    pub fn contains(self: *const ListBoxes, target: instance.InstanceHandle) bool {
        return self.findList(target) != null;
    }

    pub fn option(self: *const ListBoxes, target: instance.InstanceHandle) ?Selection {
        for (self.options) |entry| if (entry.active and same(entry.target, target)) return .{
            .listbox = entry.listbox,
            .option = entry.target,
            .value = entry.value,
        };
        return null;
    }

    pub fn move(self: *ListBoxes, listbox: instance.InstanceHandle, delta: i2) ?Selection {
        var selected_index: ?usize = null;
        var first: ?usize = null;
        var last: ?usize = null;
        const selected = self.findListMutable(listbox) orelse return null;
        for (self.options, 0..) |entry, index| if (entry.active and same(entry.listbox, listbox)) {
            if (first == null) first = index;
            last = index;
            if (entry.value == selected.selected) selected_index = index;
        };
        if (first == null) return null;
        const index = if (delta < 0)
            previousOption(self.options, listbox, selected_index orelse first.?) orelse first.?
        else
            nextOption(self.options, listbox, selected_index orelse first.?) orelse last.?;
        const entry = self.options[index];
        selected.selected = entry.value;
        return .{ .listbox = listbox, .option = entry.target, .value = entry.value };
    }

    pub fn edge(self: *ListBoxes, listbox: instance.InstanceHandle, last: bool) ?Selection {
        const list = self.findListMutable(listbox) orelse return null;
        var found: ?Option = null;
        for (self.options) |entry| if (entry.active and same(entry.listbox, listbox)) {
            found = entry;
            if (!last) break;
        };
        const entry = found orelse return null;
        list.selected = entry.value;
        return .{ .listbox = listbox, .option = entry.target, .value = entry.value };
    }

    pub fn select(self: *ListBoxes, selection: Selection) void {
        const list = self.findListMutable(selection.listbox) orelse return;
        list.selected = selection.value;
    }

    pub fn setHovered(self: *ListBoxes, target: instance.InstanceHandle, hovered: bool) ?VisualUpdate {
        for (self.options) |*entry| if (entry.active and same(entry.target, target)) {
            if (entry.hovered == hovered) return null;
            entry.hovered = hovered;
            return update(entry.*, self.optionVisual(entry.*));
        };
        return null;
    }

    pub fn currentVisual(self: *const ListBoxes, target: instance.InstanceHandle) VisualUpdate {
        for (self.options) |entry| if (entry.active and same(entry.target, target)) {
            return update(entry, self.optionVisual(entry));
        };
        unreachable;
    }

    pub fn optionSlots(self: *const ListBoxes) usize {
        return self.options.len;
    }
    pub fn optionAt(self: *const ListBoxes, index: usize) ?instance.InstanceHandle {
        return if (index < self.options.len and self.options[index].active) self.options[index].target else null;
    }

    fn findList(self: *const ListBoxes, target: instance.InstanceHandle) ?*const ListBox {
        for (self.lists) |*entry| if (entry.active and same(entry.target, target)) return entry;
        return null;
    }

    fn findListMutable(self: *ListBoxes, target: instance.InstanceHandle) ?*ListBox {
        for (self.lists) |*entry| if (entry.active and same(entry.target, target)) return entry;
        return null;
    }

    fn optionVisual(self: *const ListBoxes, option_value: Option) Visual {
        const list = self.findList(option_value.listbox).?;
        if (option_value.value == list.selected) return option_value.style.selected;
        if (option_value.hovered) return option_value.style.hovered;
        return option_value.style.idle;
    }
};

fn update(option: Option, visual: Visual) VisualUpdate {
    return .{ .option = option.target, .content = option.content, .visual = visual };
}

fn previousOption(options: []const Option, listbox: instance.InstanceHandle, start: usize) ?usize {
    var index = start;
    while (index > 0) {
        index -= 1;
        if (options[index].active and same(options[index].listbox, listbox)) return index;
    }
    return null;
}
fn nextOption(options: []const Option, listbox: instance.InstanceHandle, start: usize) ?usize {
    var index = start + 1;
    while (index < options.len) : (index += 1) if (options[index].active and same(options[index].listbox, listbox)) return index;
    return null;
}
fn same(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "listbox moves through options without wrapping" {
    var boxes: ListBoxes = undefined;
    try boxes.init(std.testing.allocator, 3);
    defer boxes.deinit();
    const owner: BuildOwnerHandle = .{ .slot = 1, .generation = 1 };
    const list: instance.InstanceHandle = .{ .slot = 2, .generation = 1 };
    boxes.beginOwner(owner);
    try boxes.setList(owner, list, 1);
    const style: Style = .{
        .idle = .{ .background = null, .foreground = Color.rgba(1, 0, 0, 255) },
        .hovered = .{ .background = Color.rgba(2, 0, 0, 255), .foreground = Color.rgba(4, 0, 0, 255) },
        .selected = .{ .background = Color.rgba(3, 0, 0, 255), .foreground = Color.rgba(5, 0, 0, 255) },
    };
    const first: instance.InstanceHandle = .{ .slot = 3, .generation = 1 };
    const second: instance.InstanceHandle = .{ .slot = 4, .generation = 1 };
    const first_content: instance.InstanceHandle = .{ .slot = 5, .generation = 1 };
    const second_content: instance.InstanceHandle = .{ .slot = 6, .generation = 1 };
    try boxes.setOption(owner, list, first, first_content, 1, style);
    try boxes.setOption(owner, list, second, second_content, 2, style);
    boxes.finishOwner(owner);
    try std.testing.expectEqual(@as(u8, 3), boxes.currentVisual(first).visual.background.?.r);
    try std.testing.expectEqual(@as(u8, 2), boxes.setHovered(second, true).?.visual.background.?.r);
    try std.testing.expectEqual(@as(u8, 4), boxes.currentVisual(second).visual.foreground.r);
    try std.testing.expectEqual(@as(i64, 2), boxes.move(list, 1).?.value);
    try std.testing.expectEqual(@as(u8, 3), boxes.currentVisual(second).visual.background.?.r);
    try std.testing.expectEqual(@as(u8, 5), boxes.currentVisual(second).visual.foreground.r);
    try std.testing.expectEqual(@as(i64, 1), boxes.move(list, -1).?.value);
    boxes.clear();
}
