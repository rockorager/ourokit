const std = @import("std");
const Color = @import("../core/color.zig").Color;
const RectI = @import("../core/geometry.zig").RectI;

pub const BlendMode = enum {
    /// Replace destination pixels with the premultiplied source.
    source,
    /// Premultiplied Porter-Duff source-over in encoded sRGB channels.
    source_over,
};

/// Renderer-neutral, value-only painting vocabulary. Clip commands are
/// balanced and affect subsequent drawing until `pop_clip`.
pub const Command = union(enum) {
    clear: Color,
    push_clip_rect: RectI,
    pop_clip,
    solid_rectangle: struct {
        bounds: RectI,
        color: Color,
        blend: BlendMode = .source_over,
    },
};

pub const Damage = union(enum) {
    full,
    /// Device-pixel regions to redraw. Overlap is valid; backends may
    /// canonicalize it. An empty slice means that no pixels need rendering.
    regions: []const RectI,
};

/// A borrowed immutable command batch. This view is suitable for synchronous
/// consumption. Asynchronous backends retain the owning `Frame`, not this view.
pub const DisplayList = struct {
    commands: []const Command,
    damage: Damage = .full,

    pub fn init(commands: []const Command) DisplayList {
        return .{ .commands = commands };
    }

    pub fn validate(self: DisplayList) !void {
        var depth: usize = 0;
        for (self.commands) |command| switch (command) {
            .clear => if (depth != 0) return error.ClearInsideClip,
            .push_clip_rect => depth += 1,
            .pop_clip => {
                if (depth == 0) return error.UnbalancedClipStack;
                depth -= 1;
            },
            .solid_rectangle => {},
        };
        if (depth != 0) return error.UnbalancedClipStack;
        switch (self.damage) {
            .full => {},
            .regions => |regions| for (regions, 0..) |region, index| {
                if (region.isEmpty()) continue;
                for (regions[index + 1 ..]) |other| {
                    if (!RectI.intersect(region, other).isEmpty()) return error.OverlappingDamage;
                }
            },
        }
    }
};

/// Frame-owned immutable scene storage. The command and damage copies remain
/// valid across worker-thread rendering or asynchronous backend submission
/// until the frame is explicitly released.
pub const Frame = struct {
    allocator: std.mem.Allocator,
    command_storage: []const Command,
    damage_storage: []const RectI,
    full_damage: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        commands: []const Command,
        damage: Damage,
    ) !Frame {
        try (DisplayList{ .commands = commands, .damage = damage }).validate();
        const owned_commands = try allocator.dupe(Command, commands);
        errdefer allocator.free(owned_commands);
        const full_damage = damage == .full;
        const regions = switch (damage) {
            .full => try allocator.alloc(RectI, 0),
            .regions => |values| try allocator.dupe(RectI, values),
        };
        return .{
            .allocator = allocator,
            .command_storage = owned_commands,
            .damage_storage = regions,
            .full_damage = full_damage,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.damage_storage);
        self.allocator.free(self.command_storage);
        self.* = undefined;
    }

    pub fn displayList(self: *const Frame) DisplayList {
        return .{
            .commands = self.command_storage,
            .damage = if (self.full_damage) .full else .{ .regions = self.damage_storage },
        };
    }
};

test "owned frame isolates asynchronous scene lifetime" {
    var commands = [_]Command{.{ .clear = Color.rgba(1, 2, 3, 255) }};
    var damage = [_]RectI{.{ .x = 1, .y = 2, .width = 3, .height = 4 }};
    var frame = try Frame.init(std.testing.allocator, &commands, .{ .regions = &damage });
    defer frame.deinit();
    commands[0] = .{ .clear = Color.rgba(9, 9, 9, 255) };
    damage[0].x = 99;
    const list = frame.displayList();
    try std.testing.expectEqual(@as(u8, 1), list.commands[0].clear.r);
    try std.testing.expectEqual(@as(i32, 1), list.damage.regions[0].x);
}
