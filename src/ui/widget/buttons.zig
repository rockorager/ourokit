const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const instance = @import("../instance/tree.zig");
const BuildOwnerHandle = @import("../instance/build_owner.zig").BuildOwnerHandle;
const tokens = @import("../../design/root.zig").tokens;

pub const Style = struct {
    idle: Color,
    hovered: Color,
    pressed: Color,
    disabled: Color,
    border: ?Color = null,
    focus: ?Color = null,
};

/// Radix Themes button variants that retained state can express by recoloring
/// the Button Box background. Outline and classic are intentionally omitted.
pub const Variant = enum { solid, soft, surface, ghost };

/// Semantic color family. Neutral soft and surface use high-contrast gray text.
pub const Tone = enum { accent, neutral, destructive };

pub const Recipe = struct {
    style: Style,
    foreground: Color,
    disabled_foreground: Color,
    /// Surface draws a border even when the shared controls border width is 0.
    bordered: bool,

    /// Radix Themes base-button recipe mapped onto semantic roles. Hover and
    /// pressed change only the background: surface uses soft steps where Radix
    /// strengthens its inset border, and solid pressed omits Radix's filter.
    pub fn init(theme: tokens.Theme, variant: Variant, tone: Tone) Recipe {
        const transparent = Color.rgba(0, 0, 0, 0);
        const soft: [3]Color, const text: Color, const border: Color = switch (tone) {
            .accent => .{ .{ theme.accent, theme.accent_hover, theme.accent_selected }, theme.accent_text, theme.accent_border },
            .neutral => .{ .{ theme.secondary, theme.secondary_hover, theme.secondary_selected }, theme.secondary_foreground, theme.input },
            .destructive => .{ .{ theme.destructive_subtle, theme.destructive_subtle_hover, theme.destructive_subtle_selected }, theme.destructive_text, theme.destructive_border },
        };
        const solid: [2]Color, const solid_text: Color = switch (tone) {
            .accent => .{ .{ theme.primary, theme.primary_hover }, theme.primary_foreground },
            .neutral => .{ .{ theme.foreground, theme.muted_foreground }, theme.background },
            .destructive => .{ .{ theme.destructive, theme.destructive_hover }, theme.destructive_foreground },
        };
        const colors: [4]Color = switch (variant) {
            .solid => .{ solid[0], solid[1], solid[1], theme.disabled },
            .soft => .{ soft[0], soft[1], soft[2], theme.disabled },
            .surface => .{ theme.surface, soft[0], soft[1], theme.muted },
            .ghost => .{ transparent, soft[0], soft[1], transparent },
        };
        return .{
            .style = .{
                .idle = colors[0],
                .hovered = colors[1],
                .pressed = colors[2],
                .disabled = colors[3],
                .border = if (variant == .surface) border else theme.border,
                .focus = theme.ring,
            },
            // Neutral ghost keeps Radix's gray step 11 text for low-emphasis
            // chrome such as close buttons; soft and surface use step 12.
            .foreground = if (variant == .solid) solid_text else if (variant == .ghost and tone == .neutral) theme.muted_foreground else text,
            .disabled_foreground = theme.disabled_foreground,
            .bordered = variant == .surface,
        };
    }
};

pub const VisualUpdate = struct {
    target: instance.InstanceHandle,
    color: Color,
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

    pub fn styleFor(self: *const Buttons, target: instance.InstanceHandle) ?Style {
        for (self.entries) |entry| if (entry.active and same(entry.target, target)) return entry.style;
        return null;
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

    pub fn release(self: *Buttons) ?VisualUpdate {
        const armed = self.armed orelse return null;
        self.armed = null;
        const next = self.setPressed(armed, false);
        return if (next) |value| .{ .target = armed, .color = value } else null;
    }

    pub fn releaseKeyboard(self: *Buttons) ?VisualUpdate {
        const armed = self.armed orelse return null;
        self.armed = null;
        const next = self.setPressed(armed, false);
        return if (next) |value| .{ .target = armed, .color = value } else null;
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

test "Button recipes map variants and tones onto semantic roles" {
    const light = tokens.light;
    const solid = Recipe.init(light, .solid, .accent);
    try std.testing.expectEqual(light.primary, solid.style.idle);
    try std.testing.expectEqual(light.primary_hover, solid.style.pressed);
    try std.testing.expectEqual(light.primary_foreground, solid.foreground);
    try std.testing.expect(!solid.bordered);
    const soft = Recipe.init(light, .soft, .destructive);
    try std.testing.expectEqual(light.destructive_subtle, soft.style.idle);
    try std.testing.expectEqual(light.destructive_subtle_hover, soft.style.hovered);
    try std.testing.expectEqual(light.destructive_subtle_selected, soft.style.pressed);
    try std.testing.expectEqual(light.destructive_text, soft.foreground);
    const surface = Recipe.init(tokens.dark, .surface, .neutral);
    try std.testing.expectEqual(tokens.dark.surface, surface.style.idle);
    try std.testing.expectEqual(tokens.dark.input, surface.style.border.?);
    try std.testing.expectEqual(tokens.dark.secondary_foreground, surface.foreground);
    try std.testing.expect(surface.bordered);
    const ghost = Recipe.init(light, .ghost, .neutral);
    try std.testing.expectEqual(@as(u8, 0), ghost.style.idle.a);
    try std.testing.expectEqual(@as(u8, 0), ghost.style.disabled.a);
    try std.testing.expectEqual(light.secondary, ghost.style.hovered);
    try std.testing.expectEqual(light.muted_foreground, ghost.foreground);
    try std.testing.expectEqual(light.accent_text, Recipe.init(light, .ghost, .accent).foreground);
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
    const release = buttons.release();
    try std.testing.expectEqual(@as(u8, 2), release.?.color.r);
    _ = buttons.press(target);
    _ = buttons.release();
    _ = buttons.press(target);
    const keyboard_release = buttons.releaseKeyboard();
    try std.testing.expectEqual(@as(u8, 2), keyboard_release.?.color.r);
    buttons.clear();
}
