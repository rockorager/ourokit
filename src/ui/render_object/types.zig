const Color = @import("../../core/color.zig").Color;
const Insets = @import("../../core/geometry.zig").Insets;
const ParagraphSourceHandle = @import("../../text/paragraph_source_cache.zig").ParagraphSourceHandle;
const paragraph_style = @import("../../text/paragraph_style.zig");

/// Physical alignment within a render object's available axis. Widget policy
/// resolves direction-sensitive start/end before reaching this layer.
pub const AxisAlignment = enum { minimum, center, maximum };

pub const Alignment = struct {
    horizontal: AxisAlignment = .minimum,
    vertical: AxisAlignment = .minimum,

    pub const center: Alignment = .{ .horizontal = .center, .vertical = .center };
};

pub const Box = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    padding: Insets = .{},
    /// When present, the child receives loose inner constraints and is placed
    /// within the resolved padded content box. Null preserves tight propagation.
    alignment: ?Alignment = null,
    background: ?Color = null,
    border_color: ?Color = null,
    border_width: f32 = 0,
    corner_radius: f32 = 0,
    clip: bool = false,
};

pub const Axis = enum { horizontal, vertical };
pub const MainAxisSize = enum { min, max };
pub const CrossAxisAlignment = enum { start, center, end, stretch };

pub const Flex = struct {
    axis: Axis = .horizontal,
    main_axis_size: MainAxisSize = .max,
    cross_axis_alignment: CrossAxisAlignment = .start,
    gap: f32 = 0,
};

pub const Stack = struct {
    clip: bool = false,
};

/// A single-child viewport. Offset is retained by the corresponding instance,
/// not declared widget data, and is applied to this render object separately.
pub const Scroll = struct {
    axis: Axis = .vertical,
};

/// Width-independent paragraph identity. The retained render-tree slot derives
/// and caches a width-specific positioned layout from current constraints.
pub const Label = struct {
    source: ParagraphSourceHandle,
    color: Color,
    alignment: paragraph_style.Alignment = .start,
    max_lines: ?u32 = null,
    overflow: paragraph_style.Overflow = .clip,
};

/// This is a small closed render-object vocabulary, not a generic widget node.
/// Identity, component state, focus, commands, and keyed reconciliation belong
/// to the separate instance layer.
pub const Object = union(enum) {
    box: Box,
    flex: Flex,
    stack: Stack,
    scroll: Scroll,
    label: Label,
};

pub const FlexFit = enum { loose, tight };

/// Layout metadata owned by the parent-child edge. Padding, flex factors, and
/// positioned offsets are not wrapper render objects.
pub const ParentData = union(enum) {
    none,
    flex: struct {
        factor: u16 = 0,
        fit: FlexFit = .tight,
    },
    stack: struct {
        x: f32 = 0,
        y: f32 = 0,
    },
};
