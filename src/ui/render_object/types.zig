const Color = @import("../../core/color.zig").Color;
const Insets = @import("../../core/geometry.zig").Insets;
const ShapeHandle = @import("../../text/shape_cache.zig").ShapeHandle;

pub const Box = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    padding: Insets = .{},
    background: ?Color = null,
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

/// A single already-itemized shaped run. Paragraph bidi, wrapping, selection,
/// and editing intentionally remain outside this benchmark-oriented slice.
pub const Label = struct {
    shape: ShapeHandle,
    color: Color,
};

/// This is a small closed render-object vocabulary, not a generic widget node.
/// Identity, component state, focus, commands, and keyed reconciliation belong
/// to the separate instance layer.
pub const Object = union(enum) {
    box: Box,
    flex: Flex,
    stack: Stack,
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
