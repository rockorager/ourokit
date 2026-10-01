const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const instance = @import("../instance/tree.zig");
const BuildOwnerHandle = @import("../instance/build_owner.zig").BuildOwnerHandle;

const Entry = struct {
    owner: BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    enabled: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    active: bool = false,
    seen: bool = false,
};

/// Language-neutral activation state, shared by Lua-composed controls and
/// specialized native controls. No stock geometry, typography, or colors live
/// here. The coordinator resolves descriptor paint bindings from this state.
pub const Buttons = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    entry_limit: usize = 0,
    armed: ?instance.InstanceHandle = null,

    pub fn init(self: *Buttons, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidButtonCapacity;
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        self.* = .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *Buttons) void {
        for (self.entries[0..self.entry_limit]) |entry| std.debug.assert(!entry.active);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn availableForOwner(self: *const Buttons, owner: BuildOwnerHandle) usize {
        var count: usize = self.entries.len - self.entry_limit;
        for (self.entries[0..self.entry_limit]) |entry| if (!entry.active or same(entry.owner, owner)) {
            count += 1;
        };
        return count;
    }

    pub fn availableForOwnerRetaining(
        self: *const Buttons,
        owner: BuildOwnerHandle,
        tree: *instance.Tree,
    ) usize {
        var count: usize = self.entries.len - self.entry_limit;
        for (self.entries[0..self.entry_limit]) |entry| if (!entry.active or
            (same(entry.owner, owner) and
                (!tree.isActive(entry.target) or !tree.isRetained(entry.target))))
        {
            count += 1;
        };
        return count;
    }

    pub fn beginOwner(self: *Buttons, owner: BuildOwnerHandle) void {
        for (self.entries[0..self.entry_limit]) |*entry| {
            if (entry.active and same(entry.owner, owner)) entry.seen = false;
        }
    }

    pub fn beginOwnerRetaining(
        self: *Buttons,
        owner: BuildOwnerHandle,
        tree: *instance.Tree,
    ) void {
        for (self.entries[0..self.entry_limit]) |*entry| {
            if (entry.active and same(entry.owner, owner))
                entry.seen = tree.isActive(entry.target) and tree.isRetained(entry.target);
        }
    }

    pub fn set(
        self: *Buttons,
        owner: BuildOwnerHandle,
        target: instance.InstanceHandle,
        is_enabled: bool,
    ) void {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.active and same(entry.target, target)) {
            entry.owner = owner;
            entry.enabled = is_enabled;
            entry.seen = true;
            if (!is_enabled) {
                entry.pressed = false;
                if (self.armed != null and same(self.armed.?, target)) self.armed = null;
            }
            return;
        };
        for (self.entries, 0..) |*entry, index| if (!entry.active) {
            entry.* = .{
                .owner = owner,
                .target = target,
                .enabled = is_enabled,
                .active = true,
                .seen = true,
            };
            self.entry_limit = @max(self.entry_limit, index + 1);
            return;
        };
        unreachable;
    }

    pub fn finishOwner(self: *Buttons, owner: BuildOwnerHandle) void {
        for (self.entries[0..self.entry_limit]) |*entry| {
            if (entry.active and same(entry.owner, owner) and !entry.seen) {
                if (self.armed != null and same(self.armed.?, entry.target)) self.armed = null;
                entry.* = .{};
            }
        }
        while (self.entry_limit > 0 and !self.entries[self.entry_limit - 1].active)
            self.entry_limit -= 1;
    }

    pub fn clear(self: *Buttons) void {
        @memset(self.entries[0..self.entry_limit], .{});
        self.entry_limit = 0;
        self.armed = null;
    }

    pub fn removeInactive(self: *Buttons, tree: *instance.Tree) void {
        for (self.entries[0..self.entry_limit]) |*entry| {
            if (entry.active and !tree.isActive(entry.target)) {
                if (self.armed != null and same(self.armed.?, entry.target)) self.armed = null;
                entry.* = .{};
            }
        }
        while (self.entry_limit > 0 and !self.entries[self.entry_limit - 1].active)
            self.entry_limit -= 1;
    }

    pub fn contains(self: *const Buttons, target: instance.InstanceHandle) bool {
        return self.find(target) != null;
    }

    pub fn isEnabled(self: *const Buttons, target: instance.InstanceHandle) bool {
        return self.find(target).?.enabled;
    }

    pub fn setHovered(self: *Buttons, target: instance.InstanceHandle, value: bool) ?instance.InstanceHandle {
        const entry = self.find(target).?;
        if (entry.hovered == value) return null;
        entry.hovered = value;
        return target;
    }

    fn setPressed(self: *Buttons, target: instance.InstanceHandle, value: bool) ?instance.InstanceHandle {
        const entry = self.find(target).?;
        const next = value and entry.enabled;
        if (entry.pressed == next) return null;
        entry.pressed = next;
        return target;
    }

    pub fn press(self: *Buttons, target: instance.InstanceHandle) ?instance.InstanceHandle {
        if (!self.isEnabled(target)) return null;
        self.armed = target;
        return self.setPressed(target, true);
    }

    pub fn release(self: *Buttons) ?instance.InstanceHandle {
        const armed = self.armed orelse return null;
        self.armed = null;
        return self.setPressed(armed, false);
    }

    pub fn paintColor(self: *const Buttons, target: instance.InstanceHandle, paint: instance.InteractionPaint) ?Color {
        const entry = self.find(target).?;
        if (!entry.enabled) return paint.disabled orelse paint.idle;
        if (entry.pressed) return paint.pressed orelse paint.hover orelse paint.idle;
        if (entry.hovered) return paint.hover orelse paint.idle;
        return paint.idle;
    }

    pub fn targetAt(self: *const Buttons, index: usize) ?instance.InstanceHandle {
        if (index >= self.entries.len or !self.entries[index].active) return null;
        return self.entries[index].target;
    }

    pub fn slotCount(self: *const Buttons) usize {
        return self.entry_limit;
    }

    fn find(self: anytype, target: instance.InstanceHandle) ?if (@TypeOf(self) == *Buttons) *Entry else *const Entry {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.active and same(entry.target, target)) return entry;
        return null;
    }
};

fn same(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "button scan bounds preserve holes and shrink after owner removal" {
    var buttons: Buttons = undefined;
    try buttons.init(std.testing.allocator, 8);
    defer buttons.deinit();
    defer buttons.clear();
    const owner: BuildOwnerHandle = .{ .slot = 1, .generation = 1 };
    const other: BuildOwnerHandle = .{ .slot = 2, .generation = 1 };
    const first: instance.InstanceHandle = .{ .slot = 10, .generation = 1 };
    const middle: instance.InstanceHandle = .{ .slot = 20, .generation = 1 };
    const last: instance.InstanceHandle = .{ .slot = 30, .generation = 1 };
    try std.testing.expectEqual(@as(usize, 0), buttons.slotCount());
    buttons.set(owner, first, true);
    buttons.set(other, middle, true);
    buttons.set(owner, last, true);
    buttons.beginOwner(other);
    buttons.finishOwner(other);
    try std.testing.expectEqual(@as(usize, 3), buttons.slotCount());
    try std.testing.expectEqual(@as(usize, 6), buttons.availableForOwner(other));
    try std.testing.expect(buttons.contains(last));
    buttons.beginOwner(owner);
    buttons.set(owner, first, true);
    buttons.finishOwner(owner);
    try std.testing.expectEqual(@as(usize, 1), buttons.slotCount());
    buttons.set(other, middle, true);
    try std.testing.expectEqual(middle, buttons.targetAt(1).?);
    buttons.clear();
    try std.testing.expectEqual(@as(usize, 0), buttons.slotCount());
    buttons.set(owner, last, false);
    try std.testing.expect(!buttons.isEnabled(last));
    try std.testing.expectEqual(@as(usize, 1), buttons.slotCount());
}

test "activation updates report changed targets and preserve state across rebuilds" {
    var buttons: Buttons = undefined;
    try buttons.init(std.testing.allocator, 1);
    defer buttons.deinit();
    defer buttons.clear();
    const owner: BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    buttons.beginOwner(owner);
    buttons.set(owner, target, true);
    buttons.finishOwner(owner);
    try std.testing.expectEqual(target, buttons.targetAt(0).?);
    try std.testing.expectEqual(null, buttons.targetAt(1));
    try std.testing.expectEqual(null, buttons.setHovered(target, false));
    try std.testing.expectEqual(target, buttons.setHovered(target, true).?);
    try std.testing.expectEqual(null, buttons.setHovered(target, true));
    // Even an owner without paint must report activation changes.
    try std.testing.expectEqual(target, buttons.press(target).?);
    try std.testing.expectEqual(null, buttons.press(target));
    buttons.beginOwner(owner);
    buttons.set(owner, target, true);
    buttons.finishOwner(owner);
    try std.testing.expectEqual(null, buttons.press(target));
    try std.testing.expectEqual(target, buttons.release().?);
    try std.testing.expectEqual(null, buttons.release());
    try std.testing.expectEqual(target, buttons.press(target).?);
    buttons.beginOwner(owner);
    buttons.finishOwner(owner);
    try std.testing.expectEqual(null, buttons.release());
    try std.testing.expectEqual(null, buttons.targetAt(0));
    try std.testing.expect(!buttons.contains(target));
}

test "activation resolves each descriptor paint independently and disabling cancels presses" {
    var buttons: Buttons = undefined;
    try buttons.init(std.testing.allocator, 1);
    defer buttons.deinit();
    defer buttons.clear();
    const owner: BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const background: instance.InteractionPaint = .{
        .source = 17,
        .idle = Color.rgba(13, 0, 0, 255),
        .hover = Color.rgba(29, 0, 0, 255),
        .pressed = Color.rgba(47, 0, 0, 255),
        .disabled = Color.rgba(61, 0, 0, 255),
    };
    const foreground: instance.InteractionPaint = .{
        .source = 17,
        .idle = Color.rgba(83, 0, 0, 255),
        .hover = Color.rgba(101, 0, 0, 255),
    };
    buttons.set(owner, target, true);
    try std.testing.expectEqual(@as(u8, 13), buttons.paintColor(target, background).?.r);
    try std.testing.expectEqual(@as(u8, 83), buttons.paintColor(target, foreground).?.r);
    _ = buttons.setHovered(target, true);
    try std.testing.expectEqual(@as(u8, 29), buttons.paintColor(target, background).?.r);
    try std.testing.expectEqual(@as(u8, 101), buttons.paintColor(target, foreground).?.r);
    _ = buttons.press(target);
    try std.testing.expectEqual(@as(u8, 47), buttons.paintColor(target, background).?.r);
    try std.testing.expectEqual(@as(u8, 101), buttons.paintColor(target, foreground).?.r);
    // A rebuild disabling the armed owner clears the press, not its hover.
    buttons.set(owner, target, false);
    try std.testing.expectEqual(null, buttons.release());
    try std.testing.expectEqual(null, buttons.press(target));
    try std.testing.expectEqual(@as(u8, 61), buttons.paintColor(target, background).?.r);
    try std.testing.expectEqual(@as(u8, 83), buttons.paintColor(target, foreground).?.r);
    buttons.set(owner, target, true);
    try std.testing.expectEqual(@as(u8, 29), buttons.paintColor(target, background).?.r);
    try std.testing.expectEqual(target, buttons.setHovered(target, false).?);
    try std.testing.expectEqual(@as(u8, 13), buttons.paintColor(target, background).?.r);
    try std.testing.expectEqual(@as(u8, 83), buttons.paintColor(target, foreground).?.r);
}
