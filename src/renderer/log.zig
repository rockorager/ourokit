const std = @import("std");
const scene = @import("../scene/root.zig");

/// Deterministic headless scene logging. Returns the used prefix of `output`.
pub fn render(list: scene.DisplayList, output: []u8) ![]const u8 {
    try list.validate();
    var used: usize = 0;
    switch (list.damage) {
        .full => try append(output, &used, "damage full\n", .{}),
        .regions => |regions| for (regions) |region| try append(
            output,
            &used,
            "damage x={d} y={d} width={d} height={d}\n",
            .{ region.x, region.y, region.width, region.height },
        ),
    }
    for (list.commands) |command| switch (command) {
        .clear => |color| try append(output, &used, "clear rgba({d},{d},{d},{d})\n", .{
            color.r, color.g, color.b, color.a,
        }),
        .push_clip_rect => |clip| try append(
            output,
            &used,
            "push_clip_rect x={d} y={d} width={d} height={d}\n",
            .{ clip.x, clip.y, clip.width, clip.height },
        ),
        .pop_clip => try append(output, &used, "pop_clip\n", .{}),
        .solid_rectangle => |rectangle| try append(
            output,
            &used,
            "solid_rectangle x={d} y={d} width={d} height={d} rgba({d},{d},{d},{d}) blend={s}\n",
            .{
                rectangle.bounds.x,
                rectangle.bounds.y,
                rectangle.bounds.width,
                rectangle.bounds.height,
                rectangle.color.r,
                rectangle.color.g,
                rectangle.color.b,
                rectangle.color.a,
                @tagName(rectangle.blend),
            },
        ),
        .decorated_rectangle => |rectangle| try append(
            output,
            &used,
            "decorated_rectangle x={d} y={d} width={d} height={d} radius={d} border_width={d} background={any} border={any} blend={s}\n",
            .{
                rectangle.bounds.x,
                rectangle.bounds.y,
                rectangle.bounds.width,
                rectangle.bounds.height,
                rectangle.corner_radius,
                rectangle.border_width,
                rectangle.background,
                rectangle.border_color,
                @tagName(rectangle.blend),
            },
        ),
        .glyph_run => |run| try append(
            output,
            &used,
            "glyph_run shape={d}:{d} baseline=({d},{d}) scale={d} rgba({d},{d},{d},{d})\n",
            .{
                run.shape.slot,
                run.shape.generation,
                run.origin.x,
                run.origin.y,
                run.scale,
                run.color.r,
                run.color.g,
                run.color.b,
                run.color.a,
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
        "damage full\n" ++
            "clear rgba(1,2,3,255)\n" ++
            "solid_rectangle x=-2 y=4 width=8 height=16 rgba(9,10,11,12) blend=source_over\n",
        actual,
    );
}
