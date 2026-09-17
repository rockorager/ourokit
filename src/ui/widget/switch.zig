const tokens = @import("../../design/root.zig").tokens;
const Box = @import("../render_object/types.zig").Box;
const ButtonStyle = @import("buttons.zig").Style;

/// Radix Themes size-2 surface recipe, composed from existing native Boxes.
/// Checked is declarative: activation requests its inverse, never mutates it.
pub const Switch = struct {
    root: Box,
    track: Box,
    thumb: Box,
    style: ButtonStyle,

    pub fn init(theme: tokens.Theme, checked: bool, enabled: bool, radius: ?f32) Switch {
        const height = tokens.foundation.spacing_5 * 5 / 6;
        const inset = tokens.foundation.border_width_default;
        const background = if (!enabled) theme.disabled else if (checked) theme.primary else theme.switch_track;
        const border = if (!enabled) theme.disabled else if (checked) theme.primary else theme.switch_border;
        const ring = tokens.foundation.border_width_strong;
        const transparent = @import("../../core/color.zig").Color.rgba(0, 0, 0, 0);
        return .{
            // Reserve ring + gap inside the hit bounds so parent clips never
            // cut off focus. The transparent border changes only its color.
            .root = .{
                .width = height * 1.75 + ring * 4,
                .height = height + ring * 4,
                .padding = .{ .left = ring, .right = ring, .top = ring, .bottom = ring },
                .alignment = .center,
                .border_width = ring,
                .border_color = transparent,
                .corner_radius = (radius orelse height / 2) + ring * 2,
            },
            .track = .{
                .width = height * 1.75,
                .height = height,
                .alignment = .{ .horizontal = if (checked) .maximum else .minimum, .vertical = .center },
                .background = background,
                .border_color = border,
                .border_width = inset,
                .corner_radius = radius orelse height / 2,
            },
            .thumb = .{
                .width = height - inset * 2,
                .height = height - inset * 2,
                .corner_radius = if (radius) |r| @max(0, r - inset) else height / 2,
                .background = if (enabled) theme.switch_thumb else theme.switch_disabled_thumb,
                .border_width = inset,
                .border_color = theme.switch_border,
            },
            .style = .{
                .idle = transparent,
                .hovered = transparent,
                .pressed = transparent,
                .disabled = transparent,
                .border = transparent,
                .focus = theme.ring,
            },
        };
    }
};

test "Switch recipe uses semantic colors and asymmetric checked positions" {
    const std = @import("std");
    const off = Switch.init(tokens.light, false, true, null);
    const on = Switch.init(tokens.dark, true, true, null);
    const disabled = Switch.init(tokens.dark, true, false, 4);
    try std.testing.expectEqual(@as(f32, 43), off.root.width.?);
    try std.testing.expectEqual(@as(f32, 28), off.root.height.?);
    try std.testing.expectEqual(@as(f32, 35), off.track.width.?);
    try std.testing.expectEqual(@as(f32, 20), off.track.height.?);
    try std.testing.expectEqual(@as(f32, 18), off.thumb.width.?);
    try std.testing.expectEqual(.minimum, off.track.alignment.?.horizontal);
    try std.testing.expectEqual(.maximum, on.track.alignment.?.horizontal);
    try std.testing.expectEqual(tokens.light.switch_track, off.track.background.?);
    try std.testing.expectEqual(tokens.dark.primary, on.track.background.?);
    try std.testing.expectEqual(tokens.dark.disabled, disabled.track.background.?);
    try std.testing.expectEqual(tokens.dark.switch_disabled_thumb, disabled.thumb.background.?);
    try std.testing.expectEqual(@as(f32, 3), disabled.thumb.corner_radius);
}
