const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const instance = @import("../instance/tree.zig");
const BuildOwnerHandle = @import("../instance/build_owner.zig").BuildOwnerHandle;

pub const Style = struct {
    idle: Color,
    hovered: Color,
    pressed: Color,
    disabled: Color,
};

pub const VisualUpdate = struct {
    target: instance.InstanceHandle,
    color: Color,
};

pub const Release = struct {
    visual: ?VisualUpdate = null,
    activated: ?instance.InstanceHandle = null,
};

const Entry = struct {
    owner: BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    style: Style = undefined,
    enabled: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    active: bool = false,
    seen: bool = false,
};

/// Language-neutral Button instance state. This is widget/input policy, not a
/// render object: it retains generation-checked identity and resolves the
/// current visual color that the window coordinator applies to the Button Box.
pub const Buttons = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    armed: ?instance.InstanceHandle = null,

    pub fn init(self: *Buttons, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidButtonCapacity;
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        self.* = .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *Buttons) void {
        for (self.entries) |entry| std.debug.assert(!entry.active);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn availableForOwner(self: *const Buttons, owner: BuildOwnerHandle) usize {
        var count: usize = 0;
        for (self.entries) |entry| if (!entry.active or same(entry.owner, owner)) {
            count += 1;
        };
        return count;
    }

    pub fn beginOwner(self: *Buttons, owner: BuildOwnerHandle) void {
        for (self.entries) |*entry| {
            if (entry.active and same(entry.owner, owner)) entry.seen = false;
        }
    }

    pub fn set(
        self: *Buttons,
        owner: BuildOwnerHandle,
        target: instance.InstanceHandle,
        style: Style,
        is_enabled: bool,
    ) void {
        for (self.entries) |*entry| if (entry.active and same(entry.target, target)) {
            entry.owner = owner;
            entry.style = style;
            entry.enabled = is_enabled;
            entry.seen = true;
            if (!is_enabled) {
                entry.pressed = false;
                if (self.armed != null and same(self.armed.?, target)) self.armed = null;
            }
            return;
        };
        for (self.entries) |*entry| if (!entry.active) {
            entry.* = .{
                .owner = owner,
                .target = target,
                .style = style,
                .enabled = is_enabled,
                .active = true,
                .seen = true,
            };
            return;
        };
        unreachable;
    }

    pub fn finishOwner(self: *Buttons, owner: BuildOwnerHandle) void {
        for (self.entries) |*entry| {
            if (entry.active and same(entry.owner, owner) and !entry.seen) {
                if (self.armed != null and same(self.armed.?, entry.target)) self.armed = null;
                entry.* = .{};
            }
        }
    }

    pub fn clear(self: *Buttons) void {
        @memset(self.entries, .{});
        self.armed = null;
    }

    pub fn removeInactive(self: *Buttons, tree: *instance.Tree) void {
        for (self.entries) |*entry| {
            if (entry.active and !tree.isActive(entry.target)) {
                if (self.armed != null and same(self.armed.?, entry.target)) self.armed = null;
                entry.* = .{};
            }
        }
    }

    pub fn contains(self: *const Buttons, target: instance.InstanceHandle) bool {
        return self.find(target) != null;
    }

    pub fn isEnabled(self: *const Buttons, target: instance.InstanceHandle) bool {
        return self.find(target).?.enabled;
    }

    pub fn setHovered(self: *Buttons, target: instance.InstanceHandle, value: bool) ?Color {
        const entry = self.find(target).?;
        if (entry.hovered == value) return null;
        entry.hovered = value;
        return color(entry.*);
    }

    pub fn setPressed(self: *Buttons, target: instance.InstanceHandle, value: bool) ?Color {
        const entry = self.find(target).?;
        const next = value and entry.enabled;
        if (entry.pressed == next) return null;
        entry.pressed = next;
        return color(entry.*);
    }

    pub fn press(self: *Buttons, target: instance.InstanceHandle) ?VisualUpdate {
        if (!self.isEnabled(target)) return null;
        self.armed = target;
        const next = self.setPressed(target, true) orelse return null;
        return .{ .target = target, .color = next };
    }

    pub fn release(self: *Buttons, hovered: ?instance.InstanceHandle) Release {
        const armed = self.armed orelse return .{};
        self.armed = null;
        const next = self.setPressed(armed, false);
        const activated = if (hovered != null and same(armed, hovered.?) and self.isEnabled(armed))
            armed
        else
            null;
        return .{
            .visual = if (next) |value| .{ .target = armed, .color = value } else null,
            .activated = activated,
        };
    }

    pub fn releaseKeyboard(self: *Buttons) Release {
        const armed = self.armed orelse return .{};
        self.armed = null;
        const next = self.setPressed(armed, false);
        return .{
            .visual = if (next) |value| .{ .target = armed, .color = value } else null,
            .activated = if (self.isEnabled(armed)) armed else null,
        };
    }

    pub fn currentColor(self: *const Buttons, target: instance.InstanceHandle) Color {
        return color(self.find(target).?.*);
    }

    pub fn visualAt(self: *const Buttons, index: usize) ?VisualUpdate {
        if (index >= self.entries.len or !self.entries[index].active) return null;
        const entry = self.entries[index];
        return .{ .target = entry.target, .color = color(entry) };
    }

    pub fn slotCount(self: *const Buttons) usize {
        return self.entries.len;
    }

    fn find(self: anytype, target: instance.InstanceHandle) ?if (@TypeOf(self) == *Buttons) *Entry else *const Entry {
        for (self.entries) |*entry| if (entry.active and same(entry.target, target)) return entry;
        return null;
    }
};

fn color(entry: Entry) Color {
    if (!entry.enabled) return entry.style.disabled;
    if (entry.pressed) return entry.style.pressed;
    if (entry.hovered) return entry.style.hovered;
    return entry.style.idle;
}

fn same(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "Button state preserves identity and resolves interaction colors" {
    var buttons: Buttons = undefined;
    try buttons.init(std.testing.allocator, 1);
    defer buttons.deinit();
    const owner: BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const style: Style = .{
        .idle = Color.rgba(1, 0, 0, 255),
        .hovered = Color.rgba(2, 0, 0, 255),
        .pressed = Color.rgba(3, 0, 0, 255),
        .disabled = Color.rgba(4, 0, 0, 255),
    };
    buttons.beginOwner(owner);
    buttons.set(owner, target, style, true);
    buttons.finishOwner(owner);
    try std.testing.expectEqual(@as(u8, 1), buttons.currentColor(target).r);
    try std.testing.expectEqual(@as(u8, 2), buttons.setHovered(target, true).?.r);
    try std.testing.expectEqual(@as(u8, 3), buttons.press(target).?.color.r);
    buttons.beginOwner(owner);
    buttons.set(owner, target, style, true);
    buttons.finishOwner(owner);
    try std.testing.expectEqual(@as(u8, 3), buttons.currentColor(target).r);
    const release = buttons.release(target);
    try std.testing.expectEqual(target, release.activated.?);
    try std.testing.expectEqual(@as(u8, 2), release.visual.?.color.r);
    _ = buttons.press(target);
    try std.testing.expect(buttons.release(null).activated == null);
    _ = buttons.press(target);
    const keyboard_release = buttons.releaseKeyboard();
    try std.testing.expectEqual(target, keyboard_release.activated.?);
    buttons.clear();
}
