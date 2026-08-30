const Color = @import("../core/color.zig").Color;
const RectI = @import("../core/geometry.zig").RectI;

/// Renderer-neutral, value-only painting vocabulary for the first milestone.
pub const Command = union(enum) {
    clear: Color,
    solid_rectangle: struct {
        bounds: RectI,
        color: Color,
    },
};

/// A borrowed immutable command batch. Producers retain storage ownership and
/// must not mutate commands until every consuming backend has returned.
pub const DisplayList = struct {
    commands: []const Command,

    pub fn init(commands: []const Command) DisplayList {
        return .{ .commands = commands };
    }
};

test "display list preserves command order" {
    const std = @import("std");
    const commands = [_]Command{
        .{ .clear = Color.rgba(1, 2, 3, 255) },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
            .color = Color.rgba(5, 6, 7, 8),
        } },
    };
    const list = DisplayList.init(&commands);
    try std.testing.expectEqual(@as(usize, 2), list.commands.len);
    try std.testing.expectEqual(@as(u8, 1), list.commands[0].clear.r);
}
