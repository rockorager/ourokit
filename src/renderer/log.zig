const std = @import("std");
const scene = @import("../scene/root.zig");

/// Deterministic headless scene logging. Returns the used prefix of `output`.
pub fn render(list: scene.DisplayList, output: []u8) ![]const u8 {
    var used: usize = 0;
    for (list.commands) |command| switch (command) {
        .clear => |color| try append(output, &used, "clear rgba({d},{d},{d},{d})\n", .{
            color.r, color.g, color.b, color.a,
        }),
        .solid_rectangle => |rectangle| try append(
            output,
            &used,
            "solid_rectangle x={d} y={d} width={d} height={d} rgba({d},{d},{d},{d})\n",
            .{
                rectangle.bounds.x,
                rectangle.bounds.y,
                rectangle.bounds.width,
                rectangle.bounds.height,
                rectangle.color.r,
                rectangle.color.g,
                rectangle.color.b,
                rectangle.color.a,
            },
        ),
    };
    return output[0..used];
}

fn append(output: []u8, used: *usize, comptime format: []const u8, args: anytype) !void {
    const written = std.fmt.bufPrint(output[used.*..], format, args) catch return error.OutputTooSmall;
    used.* += written.len;
}

test "scene log is deterministic and ordered" {
    const Color = @import("../core/color.zig").Color;
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(1, 2, 3, 255) },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = -2, .y = 4, .width = 8, .height = 16 },
            .color = Color.rgba(9, 10, 11, 12),
        } },
    };
    var output: [160]u8 = undefined;
    const actual = try render(.{ .commands = &commands }, &output);
    try std.testing.expectEqualStrings(
        "clear rgba(1,2,3,255)\n" ++
            "solid_rectangle x=-2 y=4 width=8 height=16 rgba(9,10,11,12)\n",
        actual,
    );
}
