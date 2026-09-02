// GENERATED FILE: do not edit.
// Source: design/tokens/*.json; generator: tools/design/generate_tokens.py
const Color = @import("../../core/color.zig").Color;

pub const foundation = struct {
    pub const border_width_default: f32 = 1.0;
    pub const border_width_strong: f32 = 2.0;
    pub const component_height_compact: f32 = 24.0;
    pub const component_height_default: f32 = 32.0;
    pub const component_height_large: f32 = 40.0;
    pub const focus_ring_gap: f32 = 2.0;
    pub const focus_ring_width: f32 = 2.0;
    pub const radius: f32 = 10.0;
    pub const spacing_1: f32 = 4.0;
    pub const spacing_1_5: f32 = 6.0;
    pub const spacing_2: f32 = 8.0;
    pub const spacing_2_5: f32 = 10.0;
    pub const spacing_3: f32 = 12.0;
    pub const spacing_4: f32 = 16.0;
    pub const spacing_6: f32 = 24.0;
    pub const typography_body: f32 = 14.0;
    pub const typography_family: []const u8 = "sans-serif";
    pub const typography_heading: f32 = 18.0;
    pub const typography_label: f32 = 12.0;
    pub const workflow_icon_large: f32 = 24.0;
    pub const workflow_icon_medium: f32 = 20.0;
    pub const workflow_icon_small: f32 = 16.0;
};

pub const Theme = struct {
    accent: Color,
    accent_foreground: Color,
    background: Color,
    border: Color,
    card: Color,
    card_foreground: Color,
    destructive: Color,
    foreground: Color,
    input: Color,
    muted: Color,
    muted_foreground: Color,
    popover: Color,
    popover_foreground: Color,
    primary: Color,
    primary_foreground: Color,
    ring: Color,
    secondary: Color,
    secondary_foreground: Color,
    sidebar: Color,
    sidebar_accent: Color,
    sidebar_accent_foreground: Color,
    sidebar_border: Color,
    sidebar_foreground: Color,
    sidebar_primary: Color,
    sidebar_primary_foreground: Color,
    sidebar_ring: Color,
};

pub const light: Theme = .{
    .accent = Color.rgba(245, 245, 245, 255),
    .accent_foreground = Color.rgba(23, 23, 23, 255),
    .background = Color.rgba(255, 255, 255, 255),
    .border = Color.rgba(229, 229, 229, 255),
    .card = Color.rgba(255, 255, 255, 255),
    .card_foreground = Color.rgba(10, 10, 10, 255),
    .destructive = Color.rgba(231, 0, 11, 255),
    .foreground = Color.rgba(10, 10, 10, 255),
    .input = Color.rgba(229, 229, 229, 255),
    .muted = Color.rgba(245, 245, 245, 255),
    .muted_foreground = Color.rgba(115, 115, 115, 255),
    .popover = Color.rgba(255, 255, 255, 255),
    .popover_foreground = Color.rgba(10, 10, 10, 255),
    .primary = Color.rgba(23, 23, 23, 255),
    .primary_foreground = Color.rgba(250, 250, 250, 255),
    .ring = Color.rgba(161, 161, 161, 255),
    .secondary = Color.rgba(245, 245, 245, 255),
    .secondary_foreground = Color.rgba(23, 23, 23, 255),
    .sidebar = Color.rgba(250, 250, 250, 255),
    .sidebar_accent = Color.rgba(245, 245, 245, 255),
    .sidebar_accent_foreground = Color.rgba(23, 23, 23, 255),
    .sidebar_border = Color.rgba(229, 229, 229, 255),
    .sidebar_foreground = Color.rgba(10, 10, 10, 255),
    .sidebar_primary = Color.rgba(23, 23, 23, 255),
    .sidebar_primary_foreground = Color.rgba(250, 250, 250, 255),
    .sidebar_ring = Color.rgba(161, 161, 161, 255),
};

pub const dark: Theme = .{
    .accent = Color.rgba(38, 38, 38, 255),
    .accent_foreground = Color.rgba(250, 250, 250, 255),
    .background = Color.rgba(10, 10, 10, 255),
    .border = Color.rgba(255, 255, 255, 26),
    .card = Color.rgba(23, 23, 23, 255),
    .card_foreground = Color.rgba(250, 250, 250, 255),
    .destructive = Color.rgba(255, 100, 103, 255),
    .foreground = Color.rgba(250, 250, 250, 255),
    .input = Color.rgba(255, 255, 255, 38),
    .muted = Color.rgba(38, 38, 38, 255),
    .muted_foreground = Color.rgba(161, 161, 161, 255),
    .popover = Color.rgba(23, 23, 23, 255),
    .popover_foreground = Color.rgba(250, 250, 250, 255),
    .primary = Color.rgba(229, 229, 229, 255),
    .primary_foreground = Color.rgba(23, 23, 23, 255),
    .ring = Color.rgba(115, 115, 115, 255),
    .secondary = Color.rgba(38, 38, 38, 255),
    .secondary_foreground = Color.rgba(250, 250, 250, 255),
    .sidebar = Color.rgba(23, 23, 23, 255),
    .sidebar_accent = Color.rgba(38, 38, 38, 255),
    .sidebar_accent_foreground = Color.rgba(250, 250, 250, 255),
    .sidebar_border = Color.rgba(255, 255, 255, 26),
    .sidebar_foreground = Color.rgba(250, 250, 250, 255),
    .sidebar_primary = Color.rgba(20, 71, 230, 255),
    .sidebar_primary_foreground = Color.rgba(250, 250, 250, 255),
    .sidebar_ring = Color.rgba(115, 115, 115, 255),
};
