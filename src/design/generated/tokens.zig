// GENERATED FILE: do not edit.
// Source: design/tokens/*.json; generator: tools/design/generate_tokens.py
const Color = @import("../../core/color.zig").Color;

pub const foundation = struct {
    pub const border_width_default: f32 = 1.0;
    pub const border_width_strong: f32 = 2.0;
    pub const component_height_compact: f32 = 24.0;
    pub const component_height_default: f32 = 32.0;
    pub const component_height_large: f32 = 40.0;
    pub const corner_radius_medium: f32 = 8.0;
    pub const corner_radius_small: f32 = 4.0;
    pub const focus_ring_gap: f32 = 2.0;
    pub const focus_ring_width: f32 = 2.0;
    pub const palette_black: Color = Color.rgba(16, 16, 18, 255);
    pub const palette_blue_100: Color = Color.rgba(220, 234, 255, 255);
    pub const palette_blue_300: Color = Color.rgba(114, 165, 245, 255);
    pub const palette_blue_500: Color = Color.rgba(36, 107, 219, 255);
    pub const palette_gray_200: Color = Color.rgba(216, 216, 220, 255);
    pub const palette_gray_50: Color = Color.rgba(247, 247, 248, 255);
    pub const palette_gray_600: Color = Color.rgba(96, 96, 105, 255);
    pub const palette_gray_900: Color = Color.rgba(32, 32, 36, 255);
    pub const palette_green_500: Color = Color.rgba(35, 133, 87, 255);
    pub const palette_orange_500: Color = Color.rgba(185, 101, 22, 255);
    pub const palette_red_500: Color = Color.rgba(201, 59, 59, 255);
    pub const palette_white: Color = Color.rgba(255, 255, 255, 255);
    pub const spacing_1: f32 = 4.0;
    pub const spacing_2: f32 = 8.0;
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
    accent_default: Color,
    border_default: Color,
    content_primary: Color,
    content_secondary: Color,
    focus_ring: Color,
    selection_background: Color,
    status_negative: Color,
    status_notice: Color,
    status_positive: Color,
    surface_base: Color,
    surface_raised: Color,
};

pub const light: Theme = .{
    .accent_default = Color.rgba(36, 107, 219, 255),
    .border_default = Color.rgba(216, 216, 220, 255),
    .content_primary = Color.rgba(32, 32, 36, 255),
    .content_secondary = Color.rgba(96, 96, 105, 255),
    .focus_ring = Color.rgba(36, 107, 219, 255),
    .selection_background = Color.rgba(220, 234, 255, 255),
    .status_negative = Color.rgba(201, 59, 59, 255),
    .status_notice = Color.rgba(185, 101, 22, 255),
    .status_positive = Color.rgba(35, 133, 87, 255),
    .surface_base = Color.rgba(255, 255, 255, 255),
    .surface_raised = Color.rgba(247, 247, 248, 255),
};

pub const dark: Theme = .{
    .accent_default = Color.rgba(114, 165, 245, 255),
    .border_default = Color.rgba(96, 96, 105, 255),
    .content_primary = Color.rgba(255, 255, 255, 255),
    .content_secondary = Color.rgba(216, 216, 220, 255),
    .focus_ring = Color.rgba(114, 165, 245, 255),
    .selection_background = Color.rgba(36, 107, 219, 255),
    .status_negative = Color.rgba(201, 59, 59, 255),
    .status_notice = Color.rgba(185, 101, 22, 255),
    .status_positive = Color.rgba(35, 133, 87, 255),
    .surface_base = Color.rgba(16, 16, 18, 255),
    .surface_raised = Color.rgba(32, 32, 36, 255),
};
