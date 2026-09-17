const Color = @import("../../core/color.zig").Color;
const Insets = @import("../../core/geometry.zig").Insets;
const ParagraphSourceHandle = @import("../../text/paragraph_source_cache.zig").ParagraphSourceHandle;
const paragraph_style = @import("../../text/paragraph_style.zig");
const CaretAffinity = @import("../../text/positioned_lines.zig").CaretAffinity;

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
    fill_width: bool = false,
    fill_height: bool = false,
    min_width: f32 = 0,
    min_height: f32 = 0,
    padding: Insets = .{},
    /// When present, the child receives loose inner constraints and is placed
    /// within the resolved padded content box. Null preserves tight propagation.
    alignment: ?Alignment = null,
    background: ?Color = null,
    border_color: ?Color = null,
    border_width: f32 = 0,
    corner_radius: f32 = 0,
    outline_color: ?Color = null,
    outline_width: f32 = 0,
    outline_gap: f32 = 0,
    clip: bool = false,
};

pub const Axis = enum { horizontal, vertical };
pub const MainAxisSize = enum { min, max };
/// Stretch uses the parent's bounded cross axis, or measures the largest child
/// first when unbounded. The latter takes an extra child-layout pass; prefer
/// bounded constraints for deeply nested stretch containers.
pub const CrossAxisAlignment = enum { start, center, end, stretch };

pub const Flex = struct {
    axis: Axis = .horizontal,
    main_axis_size: MainAxisSize = .max,
    cross_axis_alignment: CrossAxisAlignment = .start,
    gap: f32 = 0,
};

pub const Stack = struct {
    clip: bool = false,
    /// Virtual rows measure intrinsically even while their estimated extent
    /// is smaller than a newly materialized row.
    unbounded_height: bool = false,
};

/// A single-child viewport. Offset is retained by the corresponding instance,
/// not declared widget data, and is applied to this render object separately.
pub const Scroll = struct {
    axis: Axis = .vertical,
};

/// A retained bitmap leaf. Null represents pending or failed loading and paints
/// nothing while preserving any declared layout dimensions.
pub const Image = struct {
    image: ?@import("../../image/cache.zig").ImageHandle = null,
    width: ?f32 = null,
    height: ?f32 = null,
    fill_width: bool = false,
    fill_height: bool = false,
    fit: @import("../../image/pixels.zig").Fit = .contain,
};

/// Width-independent paragraph identity. The retained render-tree slot derives
/// and caches a width-specific positioned layout from current constraints.
pub const Text = struct {
    source: ParagraphSourceHandle,
    color: Color,
    alignment: paragraph_style.Alignment = .start,
    max_lines: ?u32 = null,
    overflow: paragraph_style.Overflow = .clip,
};

pub const TextRange = struct {
    start: usize,
    end: usize,
};

/// Immutable presentation snapshot for retained editable text. The owning
/// TextInput session remains in `ui/text_input`; application coordination
/// replaces this value when committed text, selection, or focus changes.
pub const TextInput = struct {
    source: ParagraphSourceHandle,
    color: Color,
    /// Display-only hint, shaped separately from the editable paragraph. It is
    /// visible only when source is empty and no IME preedit is active.
    placeholder: ?ParagraphSourceHandle = null,
    placeholder_color: Color = Color.rgba(128, 128, 128, 255),
    selection_color: Color,
    caret_color: Color,
    selection_start: usize,
    selection_end: usize,
    caret_offset: usize,
    caret_affinity: CaretAffinity = .downstream,
    caret_width: f32 = 1,
    show_caret: bool = false,
    /// Reveal the selection extent even when a range hides the painted caret.
    reveal_caret: bool = false,
    preedit: ?TextRange = null,
    preedit_color: ?Color = null,
    preedit_width: f32 = 1,
    alignment: paragraph_style.Alignment = .start,
};

/// This is a small closed render-object vocabulary, not a generic widget node.
/// Identity, component state, focus, commands, and keyed reconciliation belong
/// to the separate instance layer.
pub const Object = union(enum) {
    box: Box,
    flex: Flex,
    stack: Stack,
    scroll: Scroll,
    image: Image,
    canvas: *@import("drawing.zig").Drawing,
    text: Text,
    text_input: TextInput,
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
