const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const Handle = @import("../../core/handle.zig").Handle;
const PointF = @import("../../core/geometry.zig").PointF;
const RectF = @import("../../core/geometry.zig").RectF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Transform = @import("../../core/geometry.zig").Transform;
const Constraints = @import("../layout/constraints.zig").Constraints;
const anchored_impl = @import("anchored.zig");
const box_impl = @import("box.zig");
const flex_impl = @import("flex.zig");
const grid_impl = @import("grid.zig");
const image_impl = @import("image.zig");
const ImageCache = @import("../../image/cache.zig").Cache;
const scroll_impl = @import("scroll.zig");
const split_impl = @import("split.zig");
const stack_impl = @import("stack.zig");
const scene_builder = @import("scene_builder.zig");
const text = @import("../../text/root.zig");
const types = @import("types.zig");

pub const NodeHandle = Handle;
pub const LayoutError = error{
    InvalidConstraints,
    StaleRenderObject,
    LayoutRootHasParent,
    BoxHasMultipleChildren,
    InvalidChildOffset,
    InvalidLayoutSize,
    InvalidTransform,
    UnconstrainedLayoutSize,
    FlexInUnboundedAxis,
    FlexInWrap,
    AspectRatioInUnboundedAxes,
    ScrollInUnboundedAxis,
    PositionedStackInUnboundedAxis,
    UnboundedSplitConstraints,
    SplitRequiresThreeChildren,
    AnchoredRequiresOneOrTwoChildren,
    InvalidParentData,
    TextHasChildren,
    TextInputHasChildren,
    ImageResourcesRequired,
    StaleImageHandle,
    ParagraphResourcesRequired,
    StaleParagraphSource,
    StaleParagraph,
    ParagraphLayoutFailed,
    InvalidTextInputRange,
    LayoutBuilderPending,
    LayoutBuilderIntrinsicMeasurement,
};

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    interactive: bool = true,
    object: types.Object = .{ .box = .{} },
    parent: ?NodeHandle = null,
    first_child: ?NodeHandle = null,
    last_child: ?NodeHandle = null,
    previous_sibling: ?NodeHandle = null,
    next_sibling: ?NodeHandle = null,
    parent_data: types.ParentData = .none,
    size: SizeF = .{ .width = 0, .height = 0 },
    offset: PointF = .{},
    /// First logical text baseline, independent of paint transforms/scrolling.
    baseline: ?f32 = null,
    last_constraints: Constraints = .{},
    has_layout: bool = false,
    needs_layout: bool = true,
    needs_paint: bool = true,
    /// Recomputed during layout, so ordinary subtrees need no deferred walks.
    contains_overlays: bool = false,
    layout_count: usize = 0,
    paragraph_layout: ?text.ParagraphHandle = null,
    placeholder_layout: ?text.ParagraphHandle = null,
    /// Paragraph translation within the editable viewport.
    text_offset_x: f32 = 0,
    text_offset_y: f32 = 0,
    scroll_offset: f32 = 0,
    scroll_extent: f32 = 0,
};

/// Fixed-capacity storage for the closed typed render-object set. Unchanged
/// layout is allocation-free; dirty Text objects may populate the paragraph cache.
/// This is deliberately not the widget/instance tree.
pub const Tree = struct {
    /// Used only by isolated candidate trees. Stop before an unresolved child;
    /// the build phase supplies its description before layout restarts.
    pub const LayoutProbe = struct {
        pub const Entry = struct { handle: NodeHandle, constraints: ?Constraints, visited: bool = false };
        entries: []Entry,
        request: ?struct { index: usize, constraints: Constraints } = null,
    };

    allocator: std.mem.Allocator,
    slots: []Slot,
    paragraph_sources: ?*text.ParagraphSourceCache = null,
    paragraphs: ?*text.ParagraphCache = null,
    images: ?*ImageCache = null,
    layout_probe: ?*LayoutProbe = null,

    pub fn init(self: *Tree, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *Tree) void {
        for (self.slots) |*entry| if (entry.active) {
            self.releaseParagraphLayout(entry);
            self.releaseObject(entry.object);
        };
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Both caches must outlive this tree. Text objects retain width-independent
    /// sources and tree slots retain their current width-specific layouts.
    pub fn attachTextCaches(
        self: *Tree,
        sources: *text.ParagraphSourceCache,
        paragraphs: *text.ParagraphCache,
    ) void {
        std.debug.assert(self.paragraph_sources == null and self.paragraphs == null);
        self.paragraph_sources = sources;
        self.paragraphs = paragraphs;
    }

    /// Attach immediately after init. The cache must outlive this tree; every
    /// loaded image object owns a lease independent of the loader and frames.
    pub fn attachImageCache(self: *Tree, images: *ImageCache) void {
        std.debug.assert(self.images == null);
        self.images = images;
    }

    pub fn create(self: *Tree, object: types.Object) !NodeHandle {
        try validateObject(object);
        try self.retainObject(object);
        errdefer self.releaseObject(object);
        for (self.slots, 0..) |*candidate, index| {
            if (candidate.active) continue;
            var generation = candidate.generation +% 1;
            if (generation == 0) generation = 1;
            candidate.* = .{ .generation = generation, .active = true, .object = object };
            return .{ .slot = @intCast(index), .generation = generation };
        }
        return error.RenderObjectCapacityExceeded;
    }

    pub fn destroy(self: *Tree, handle: NodeHandle) !void {
        const target = try self.slot(handle);
        if (target.first_child != null) return error.RenderObjectHasChildren;
        const generation = target.generation;
        try self.detach(handle);
        self.releaseParagraphLayout(target);
        self.releaseObject(target.object);
        self.slots[handle.slot] = .{ .generation = generation };
    }

    pub fn detachChild(self: *Tree, handle: NodeHandle) !void {
        try self.detach(handle);
    }

    pub fn availableCapacity(self: *const Tree) usize {
        var count: usize = 0;
        for (self.slots) |candidate| if (!candidate.active) {
            count += 1;
        };
        return count;
    }

    pub fn validate(object: types.Object) !void {
        try validateObject(object);
    }

    pub fn validateEdge(parent: types.Object, data: types.ParentData) !void {
        try validateParentData(parent, data);
    }

    pub fn validateRetain(self: *Tree, object: types.Object) !void {
        switch (object) {
            .text => |value| {
                const cache = self.paragraph_sources orelse return error.TextCacheRequired;
                try cache.validateRetain(value.source);
            },
            .text_input => |value| {
                const cache = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
                try cache.validateRetain(value.source);
                if (value.placeholder) |placeholder| try cache.validateRetain(placeholder);
            },
            .image => |value| if (value.image) |image| {
                const cache = self.images orelse return error.ImageResourcesRequired;
                try cache.validateRetain(image);
            },
            else => {},
        }
    }

    pub fn appendChild(
        self: *Tree,
        parent: NodeHandle,
        child: NodeHandle,
        data: types.ParentData,
    ) !void {
        var ancestor: ?NodeHandle = parent;
        while (ancestor) |current| {
            if (same(current, child)) return error.RenderObjectCycle;
            ancestor = (try self.slot(current)).parent;
        }
        const parent_slot = try self.slot(parent);
        const child_slot = try self.slot(child);
        if (child_slot.parent != null) return error.RenderObjectAlreadyAttached;
        try validateParentData(parent_slot.object, data);
        if ((parent_slot.object == .box or parent_slot.object == .scroll) and
            parent_slot.first_child != null) return error.BoxAlreadyHasChild;
        if (parent_slot.object == .split and self.childCount(parent) >= 3)
            return error.SplitRequiresThreeChildren;
        if (parent_slot.object == .anchored and self.childCount(parent) >= 2)
            return error.AnchoredRequiresOneOrTwoChildren;
        if (parent_slot.object == .text_input) return error.TextInputHasChildren;

        child_slot.parent = parent;
        child_slot.parent_data = data;
        child_slot.previous_sibling = parent_slot.last_child;
        child_slot.next_sibling = null;
        if (parent_slot.last_child) |last|
            (try self.slot(last)).next_sibling = child
        else
            parent_slot.first_child = child;
        parent_slot.last_child = child;
        self.markNeedsLayout(parent);
    }

    pub fn setParentData(self: *Tree, child: NodeHandle, data: types.ParentData) !void {
        const child_slot = try self.slot(child);
        const parent = child_slot.parent orelse return error.RenderObjectNotAttached;
        try validateParentData((try self.slot(parent)).object, data);
        if (std.meta.eql(child_slot.parent_data, data)) return;
        child_slot.parent_data = data;
        self.markNeedsLayout(parent);
    }

    pub fn update(self: *Tree, handle: NodeHandle, object: types.Object) !void {
        try validateObject(object);
        const target = try self.slot(handle);
        if (std.meta.eql(target.object, object)) return;
        if ((object == .box or object == .scroll) and target.first_child != null and
            !same(target.first_child.?, target.last_child.?)) return error.BoxAlreadyHasChild;
        if (object == .split and self.childCount(handle) > 3)
            return error.SplitRequiresThreeChildren;
        if (object == .anchored and self.childCount(handle) > 2)
            return error.AnchoredRequiresOneOrTwoChildren;
        var child = target.first_child;
        while (child) |child_handle| : (child = (try self.slot(child_handle)).next_sibling)
            try validateParentData(object, (try self.slot(child_handle)).parent_data);

        const affects_layout = layoutPropertiesChanged(target.object, object);
        try self.retainObject(object);
        const previous = target.object;
        if (sourceChanged(previous, object)) self.releaseParagraphLayout(target);
        target.object = object;
        self.releaseObject(previous);
        if (affects_layout) {
            self.markNeedsLayout(handle);
        } else {
            if (object == .text_input and target.has_layout and !target.needs_layout and
                (previous.text_input.caret_offset != object.text_input.caret_offset or
                    previous.text_input.caret_affinity != object.text_input.caret_affinity or
                    previous.text_input.caret_shape != object.text_input.caret_shape or
                    previous.text_input.selection_start != object.text_input.selection_start or
                    previous.text_input.selection_end != object.text_input.selection_end or
                    (!previous.text_input.reveal_caret and object.text_input.reveal_caret)))
                try self.updateTextInputOffset(target, target.size);
            if (object == .box and previous == .box and
                previous.box.hidden != object.box.hidden and object.box.hidden)
            {
                self.clearPaintSubtree(handle);
                if (target.parent) |parent|
                    self.markNeedsPaint(parent)
                else
                    target.needs_paint = true;
            } else {
                self.markNeedsPaint(handle);
            }
        }
    }

    pub fn objectAt(self: *Tree, handle: NodeHandle) !types.Object {
        return (try self.slot(handle)).object;
    }

    pub fn layout(self: *Tree, root: NodeHandle, constraints: Constraints) LayoutError!SizeF {
        try constraints.validate();
        const root_slot = try self.slot(root);
        if (root_slot.parent != null) return error.LayoutRootHasParent;
        root_slot.offset = .{};
        const result = try self.layoutNode(root, constraints);
        // A failed floating layout must not leave a seemingly current root.
        errdefer self.markNeedsLayout(root);
        try self.placeOverlays(root, .{}, self.rootViewport(root_slot));
        return result;
    }

    pub fn buildScene(
        self: *Tree,
        root: NodeHandle,
        builder: *scene_builder.Builder,
    ) !void {
        const root_slot = try self.slot(root);
        if (!root_slot.has_layout or root_slot.needs_layout) return error.LayoutRequired;
        // A paint-only transform can move a trigger without invalidating layout.
        try self.placeOverlays(root, .{}, self.rootViewport(root_slot));
        try self.paintNode(root, builder, .{});
        try self.paintOverlays(root, builder, .{});
    }

    /// Replay a source in the window paint plane, without its ancestor clips.
    /// The caller owns window clipping and preview opacity. Floating popups are
    /// deliberately excluded, just as they are from ordinary subtree painting.
    pub fn buildPreview(self: *Tree, handle: NodeHandle, builder: *scene_builder.Builder, delta: PointF) !void {
        const target = try self.slot(handle);
        const own: Transform = if (target.object == .box) target.object.box.transform else .{};
        const inverse: Transform = .{ .scale = 1 / own.scale, .translation = own.inversePoint(.{}) };
        const saved = builder.transform;
        defer builder.transform = saved;
        const moved = try (Transform{ .translation = delta }).compose(try self.paintTransform(handle));
        builder.transform = try saved.compose(try moved.compose(inverse));
        try self.paintNode(handle, builder, .{});
    }

    /// Map local layout coordinates to window logical pixels. Floating children
    /// start a new paint plane, retaining their placed position but not ancestor
    /// scale. Paint, semantic targeting and captured input share this mapping.
    pub fn paintTransform(self: *Tree, handle: NodeHandle) !Transform {
        var result: Transform = .{};
        var current: ?NodeHandle = handle;
        while (current) |node| {
            const target = try self.slot(node);
            const local: Transform = if (target.object == .box) target.object.box.transform else .{};
            const positioned = try (Transform{ .translation = target.offset }).compose(local);
            result = try positioned.compose(result);
            if (target.parent) |parent| {
                if (floatingChild(try self.slot(parent))) |popup| if (same(popup, node)) {
                    var origin: PointF = .{};
                    var ancestor: ?NodeHandle = parent;
                    while (ancestor) |item| {
                        const slot_value = try self.slot(item);
                        origin = PointF.add(origin, slot_value.offset);
                        ancestor = slot_value.parent;
                    }
                    return (Transform{ .translation = origin }).compose(result);
                };
            }
            current = target.parent;
        }
        return result;
    }

    pub fn paintBounds(self: *Tree, handle: NodeHandle) !RectF {
        const extent = try self.nodeSize(handle);
        return (try self.paintTransform(handle)).rect(.{ .x = 0, .y = 0, .width = extent.width, .height = extent.height });
    }

    /// A wrapped or bidi link's bounding-box center can fall in unrelated
    /// text. Playback targets a real visible fragment instead.
    pub fn textRangePoint(self: *Tree, handle: NodeHandle) !?PointF {
        const target = try self.slot(handle);
        if (target.parent_data != .text_range) return null;
        var rectangles = try self.textRangeRectangles(handle, (try self.slot(target.parent.?)).size);
        const rect = (try rectangles.next()) orelse return null;
        return (try self.paintTransform(target.parent.?)).point(.{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 });
    }

    const TextRangeRectangles = struct {
        selection: text.SelectionRectangleIterator,
        viewport: SizeF,

        fn next(self: *TextRangeRectangles) !?RectF {
            while (try self.selection.next()) |rect| {
                const left = @max(0, rect.x);
                const top = @max(0, rect.y);
                const right = @min(self.viewport.width, rect.x + rect.width);
                const bottom = @min(self.viewport.height, rect.y + rect.height);
                if (right > left and bottom > top)
                    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
            }
            return null;
        }
    };

    fn textRangeRectangles(self: *Tree, handle: NodeHandle, viewport: SizeF) !TextRangeRectangles {
        const target = try self.slot(handle);
        const parent = try self.slot(target.parent.?);
        const paragraph_layout = try self.paragraphs.?.get(parent.paragraph_layout orelse return error.LayoutRequired);
        const range = target.parent_data.text_range;
        const end = @min(range.end, paragraph_layout.positioned.ellipsis_byte_offset orelse range.end);
        return .{
            .selection = try paragraph_layout.positioned.selectionRectangleIterator(.{ .start = @min(range.start, end), .end = end }),
            .viewport = viewport,
        };
    }

    pub fn hitTest(self: *Tree, root: NodeHandle, point: PointF) !?NodeHandle {
        const root_slot = try self.slot(root);
        if (!root_slot.has_layout or root_slot.needs_layout) return error.LayoutRequired;
        const viewport = self.rootViewport(root_slot);
        if (!(RectF{ .x = 0, .y = 0, .width = viewport.width, .height = viewport.height }).contains(point)) return null;
        if (try self.hitTestOverlays(root, point)) |hit| return hit;
        return self.hitTestNode(root, point);
    }

    /// Converts a coordinate local to an editable render object into its
    /// retained paragraph position. Input routing remains instance-owned.
    pub fn hitTestText(self: *Tree, handle: NodeHandle, point: PointF) !text.TextHitResult {
        const target = try self.slot(handle);
        if (target.object != .text_input) return error.NotTextInputObject;
        if (!target.has_layout or target.needs_layout) return error.LayoutRequired;
        const paragraph_handle = target.paragraph_layout orelse return error.LayoutRequired;
        const paragraph_layout = self.paragraphs.?.get(paragraph_handle) catch
            return error.StaleParagraph;
        return paragraph_layout.positioned.hitTestPoint(.{
            .x = point.x - target.text_offset_x,
            .y = point.y - target.text_offset_y,
        }) orelse
            return error.TextPositionNotFound;
    }

    pub fn textScrollOffset(self: *Tree, handle: NodeHandle, axis: types.Axis) !f32 {
        const target = try self.ensureTextLayout(handle);
        return if (axis == .vertical) -target.text_offset_y else -target.text_offset_x;
    }

    pub fn revealTextInputCaret(self: *Tree, handle: NodeHandle) !void {
        const target = try self.ensureTextLayout(handle);
        const x = target.text_offset_x;
        const y = target.text_offset_y;
        try self.updateTextInputOffset(target, target.size);
        if (x != target.text_offset_x or y != target.text_offset_y) self.markNeedsPaint(handle);
    }

    /// Signed remaining scroll, clamped to the requested delta.
    pub fn textScrollDelta(self: *Tree, handle: NodeHandle, axis: types.Axis, delta: f32) !f32 {
        const target = try self.ensureTextLayout(handle);
        const paragraph_layout = try self.paragraphs.?.get(target.paragraph_layout.?);
        if (axis == .vertical and !target.object.text_input.multiline) return 0;
        const overhang = try textInputCaretOverhang(
            &paragraph_layout.positioned,
            target.object.text_input,
            paragraph_layout.size.width,
        );
        const minimum = @min(0, if (axis == .horizontal)
            target.size.width - paragraph_layout.size.width - overhang
        else
            target.size.height - paragraph_layout.size.height);
        if (minimum == 0) return 0;
        const caret = try textInputCaretRectangle(&paragraph_layout.positioned, target.object.text_input);
        const left = if (axis == .horizontal) @max(0, -caret.x) else 0;
        const offset = if (axis == .horizontal) target.text_offset_x else target.text_offset_y;
        return offset - std.math.clamp(offset - delta, minimum + left, left);
    }

    pub fn scrollTextInput(self: *Tree, handle: NodeHandle, axis: types.Axis, delta: f32) !bool {
        const actual = try self.textScrollDelta(handle, axis, delta);
        if (actual == 0) return false;
        const target = try self.slot(handle);
        if (axis == .horizontal) target.text_offset_x -= actual else target.text_offset_y -= actual;
        self.markNeedsPaint(handle);
        return true;
    }

    pub fn textCaretRectangle(self: *Tree, handle: NodeHandle) !RectF {
        const target = try self.slot(handle);
        if (target.object != .text_input) return error.NotTextInputObject;
        if (!target.has_layout or target.needs_layout) return error.LayoutRequired;
        const paragraph_handle = target.paragraph_layout orelse return error.LayoutRequired;
        const paragraph_layout = self.paragraphs.?.get(paragraph_handle) catch
            return error.StaleParagraph;
        const input = target.object.text_input;
        var rectangle = try textInputCaretRectangle(&paragraph_layout.positioned, input);
        rectangle.x += target.text_offset_x;
        rectangle.y += target.text_offset_y;
        return rectangle;
    }

    pub fn textVisualNeighbor(
        self: *Tree,
        handle: NodeHandle,
        byte_offset: usize,
        affinity: text.CaretAffinity,
        direction: text.VisualCaretDirection,
    ) !text.CaretStop {
        const target = try self.ensureTextLayout(handle);
        const paragraph_layout = self.paragraphs.?.get(target.paragraph_layout.?) catch
            return error.StaleParagraph;
        return paragraph_layout.positioned.visualNeighbor(
            byte_offset,
            affinity,
            direction,
        ) orelse error.CaretNotFound;
    }

    pub fn textVisualOrder(
        self: *Tree,
        handle: NodeHandle,
        a_offset: usize,
        a_affinity: text.CaretAffinity,
        b_offset: usize,
        b_affinity: text.CaretAffinity,
    ) !std.math.Order {
        const target = try self.ensureTextLayout(handle);
        const paragraph_layout = self.paragraphs.?.get(target.paragraph_layout.?) catch
            return error.StaleParagraph;
        return paragraph_layout.positioned.visualOrder(
            a_offset,
            a_affinity,
            b_offset,
            b_affinity,
        ) orelse error.CaretNotFound;
    }

    pub fn textLineBoundary(
        self: *Tree,
        handle: NodeHandle,
        byte_offset: usize,
        affinity: text.CaretAffinity,
        boundary: text.LineBoundary,
    ) !text.CaretStop {
        const target = try self.ensureTextLayout(handle);
        const paragraph_layout = self.paragraphs.?.get(target.paragraph_layout.?) catch
            return error.StaleParagraph;
        return paragraph_layout.positioned.lineBoundary(
            byte_offset,
            affinity,
            boundary,
        ) orelse error.CaretNotFound;
    }

    pub fn textVerticalNeighbor(
        self: *Tree,
        handle: NodeHandle,
        byte_offset: usize,
        affinity: text.CaretAffinity,
        preferred_x: ?f32,
        direction: text.VerticalCaretDirection,
    ) !text.VerticalCaretMove {
        const target = try self.ensureTextLayout(handle);
        const paragraph_layout = self.paragraphs.?.get(target.paragraph_layout.?) catch
            return error.StaleParagraph;
        return paragraph_layout.positioned.verticalNeighbor(
            byte_offset,
            affinity,
            preferred_x,
            direction,
        ) orelse error.CaretNotFound;
    }

    pub fn nodeSize(self: *Tree, handle: NodeHandle) !SizeF {
        const target = try self.slot(handle);
        if (!target.has_layout or !(try self.layoutPathCurrent(handle))) return error.LayoutRequired;
        return target.size;
    }

    pub fn nodeOffset(self: *Tree, handle: NodeHandle) !PointF {
        const target = try self.slot(handle);
        if (!target.has_layout or !(try self.layoutPathCurrent(handle))) return error.LayoutRequired;
        return target.offset;
    }

    pub fn layoutCount(self: *Tree, handle: NodeHandle) !usize {
        return (try self.slot(handle)).layout_count;
    }

    /// Last completed input, also usable as a proposal before a dirty relayout.
    pub fn lastConstraints(self: *Tree, handle: NodeHandle) !?Constraints {
        const target = try self.slot(handle);
        return if (target.has_layout) target.last_constraints else null;
    }

    pub fn layoutDirty(self: *Tree, handle: NodeHandle) !bool {
        return (try self.slot(handle)).needs_layout;
    }

    pub fn paintDirty(self: *Tree, handle: NodeHandle) !bool {
        return (try self.slot(handle)).needs_paint;
    }

    /// Interaction can be suppressed without changing paint or layout.
    pub fn setInteractive(self: *Tree, handle: NodeHandle, interactive: bool) !void {
        (try self.slot(handle)).interactive = interactive;
    }

    pub fn isInteractive(self: *Tree, handle: NodeHandle) !bool {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = try self.slot(value);
            if (!target.interactive or (target.object == .box and target.object.box.hidden)) return false;
            if (target.parent_data == .text_range and target.has_layout and
                (target.size.width == 0 or target.size.height == 0)) return false;
            current = target.parent;
        }
        return true;
    }

    /// Whether a node is paint/hit-test visible through all retained Box ancestors.
    pub fn isVisible(self: *Tree, handle: NodeHandle) !bool {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = try self.slot(value);
            if (target.object == .box and target.object.box.hidden) return false;
            if (target.parent_data == .text_range and target.has_layout and
                (target.size.width == 0 or target.size.height == 0)) return false;
            current = target.parent;
        }
        return true;
    }

    pub fn firstChild(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).first_child;
    }

    pub fn nextSibling(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).next_sibling;
    }

    pub fn lastChild(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).last_child;
    }

    pub fn previousSibling(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).previous_sibling;
    }

    pub fn childCount(self: *Tree, handle: NodeHandle) usize {
        var count: usize = 0;
        var child = self.firstChild(handle);
        while (child) |current| : (child = self.nextSibling(current)) count += 1;
        return count;
    }

    pub fn onlyChild(self: *Tree, handle: NodeHandle) LayoutError!?NodeHandle {
        const first = (try self.slot(handle)).first_child orelse return null;
        if ((try self.slot(first)).next_sibling != null) return error.BoxHasMultipleChildren;
        return first;
    }

    pub fn parentData(self: *Tree, handle: NodeHandle) LayoutError!types.ParentData {
        return (try self.slot(handle)).parent_data;
    }

    pub fn size(self: *Tree, handle: NodeHandle) LayoutError!SizeF {
        const target = try self.slot(handle);
        if (!target.has_layout) return error.InvalidLayoutSize;
        return target.size;
    }

    /// Layout metric, not a painted-coordinate query. Children have completed
    /// layout when a parent uses this, even while the parent's layout is dirty.
    pub fn baseline(self: *Tree, handle: NodeHandle) LayoutError!?f32 {
        const target = try self.slot(handle);
        if (!target.has_layout or target.needs_layout) return error.InvalidLayoutSize;
        return target.baseline;
    }

    pub fn layoutChild(self: *Tree, handle: NodeHandle, constraints: Constraints) LayoutError!SizeF {
        return self.layoutNode(handle, constraints);
    }

    pub fn setChildOffset(self: *Tree, handle: NodeHandle, offset: PointF) LayoutError!void {
        if (!validPoint(offset)) return error.InvalidChildOffset;
        const child = try self.slot(handle);
        if (std.meta.eql(child.offset, offset)) return;
        child.offset = offset;
        self.markNeedsPaint(handle);
    }

    /// Applies instance-owned scrolling without invalidating layout. Returns
    /// the clamped offset so the instance remains the authoritative state.
    pub fn setScrollOffset(self: *Tree, handle: NodeHandle, requested: f32) !f32 {
        if (!std.math.isFinite(requested)) return error.InvalidScrollOffset;
        const target = try self.slot(handle);
        const scroll = switch (target.object) {
            .scroll => |value| value,
            else => return error.NotScrollObject,
        };
        const offset = std.math.clamp(requested, 0, target.scroll_extent);
        if (target.scroll_offset == offset) return offset;
        target.scroll_offset = offset;
        if (target.first_child) |child|
            try self.setChildOffset(child, scroll_impl.childOffset(scroll.axis, offset));
        self.markNeedsPaint(handle);
        var root = handle;
        while ((try self.slot(root)).parent) |parent| root = parent;
        const root_slot = try self.slot(root);
        if (root_slot.has_layout and !root_slot.needs_layout)
            try self.placeOverlays(root, .{}, self.rootViewport(root_slot));
        return offset;
    }

    pub fn scrollOffset(self: *Tree, handle: NodeHandle) !f32 {
        const target = try self.slot(handle);
        if (target.object != .scroll) return error.NotScrollObject;
        return target.scroll_offset;
    }

    pub fn scrollMetrics(self: *Tree, handle: NodeHandle) !scroll_impl.Metrics {
        const target = try self.slot(handle);
        if (target.object != .scroll) return error.NotScrollObject;
        if (!target.has_layout or target.needs_layout) return error.LayoutRequired;
        const axis = target.object.scroll.axis;
        const content = if (target.first_child) |child| try self.nodeSize(child) else SizeF{ .width = 0, .height = 0 };
        return .{
            .axis = axis,
            .offset = target.scroll_offset,
            .viewport = if (axis == .vertical) target.size.height else target.size.width,
            .content = if (axis == .vertical) content.height else content.width,
            .max_offset = target.scroll_extent,
        };
    }

    pub fn finishScrollLayout(
        self: *Tree,
        handle: NodeHandle,
        viewport: SizeF,
        content: SizeF,
    ) LayoutError!void {
        const target = try self.slot(handle);
        const scroll = target.object.scroll;
        target.scroll_extent = switch (scroll.axis) {
            .vertical => @max(0, content.height - viewport.height),
            .horizontal => @max(0, content.width - viewport.width),
        };
        target.scroll_offset = @min(target.scroll_offset, target.scroll_extent);
        if (target.first_child) |child|
            try self.setChildOffset(child, scroll_impl.childOffset(scroll.axis, target.scroll_offset));
    }

    fn layoutNode(self: *Tree, handle: NodeHandle, constraints: Constraints) LayoutError!SizeF {
        try constraints.validate();
        const current = try self.slot(handle);
        if (self.layout_probe) |probe| for (probe.entries, 0..) |*entry, index| {
            if (!std.meta.eql(entry.handle, handle)) continue;
            if (entry.constraints == null or !std.meta.eql(entry.constraints.?, constraints)) {
                if (entry.visited) return error.LayoutBuilderIntrinsicMeasurement;
                probe.request = .{ .index = index, .constraints = constraints };
                return error.LayoutBuilderPending;
            }
            entry.visited = true;
            break;
        };
        if (!current.needs_layout and current.has_layout and
            std.meta.eql(current.last_constraints, constraints)) return current.size;
        const object = current.object;
        const result = switch (object) {
            .box => |value| try box_impl.layout(value, self, handle, constraints),
            .flex => |value| try flex_impl.layout(value, self, handle, constraints),
            .grid => |value| try grid_impl.layout(value, self, handle, constraints),
            .split => |value| try split_impl.layout(value, self, handle, constraints),
            .stack => |value| try stack_impl.layout(value, self, handle, constraints),
            .anchored => try anchored_impl.layout(self, handle, constraints),
            .scroll => |value| try scroll_impl.layout(value, self, handle, constraints),
            .image => |value| try self.layoutImage(value, constraints),
            .canvas => |value| constraints.constrain(value.size),
            .text => try self.layoutText(handle, object.text, constraints),
            .text_input => try self.layoutTextInput(handle, object.text_input, constraints),
        };
        if (!validSize(result)) return error.InvalidLayoutSize;
        const constrained = constraints.constrain(result);
        if (!std.meta.eql(result, constrained)) return error.UnconstrainedLayoutSize;
        const target = try self.slot(handle);
        target.size = result;
        target.baseline = try self.computeBaseline(target);
        target.last_constraints = constraints;
        target.has_layout = true;
        target.needs_layout = false;
        target.needs_paint = true;
        target.contains_overlays = floatingChild(target) != null;
        var child = target.first_child;
        while (!target.contains_overlays) {
            const child_handle = child orelse break;
            const child_slot = try self.slot(child_handle);
            target.contains_overlays = child_slot.contains_overlays;
            child = child_slot.next_sibling;
        }
        target.layout_count += 1;
        return result;
    }

    fn computeBaseline(self: *Tree, target: *const Slot) LayoutError!?f32 {
        switch (target.object) {
            .text, .text_input => {
                const paragraph = self.paragraphs.?.get(target.placeholder_layout orelse target.paragraph_layout.?) catch
                    return error.StaleParagraph;
                if (paragraph.positioned.lines.len == 0) return null;
                const line = paragraph.positioned.lines[0];
                return line.top + line.baseline;
            },
            // A viewport must not move its parent's alignment as it scrolls.
            .scroll, .image, .canvas => return null,
            else => {},
        }
        var result: ?f32 = null;
        var child = target.first_child;
        while (child) |handle| : (child = self.nextSibling(handle)) {
            const slot_value = try self.slot(handle);
            if (slot_value.parent_data == .positioned) continue;
            if (slot_value.baseline) |value| {
                const distance = slot_value.offset.y + value;
                result = if (result) |old| @min(old, distance) else distance;
                // Columns expose their first baseline-bearing child. Other
                // multi-child containers expose the topmost laid-out baseline.
                if (target.object == .flex and target.object.flex.axis == .vertical) break;
            }
            // Floating content neither contributes size nor a baseline.
            if (target.object == .anchored) break;
        }
        return result;
    }

    fn paintNode(
        self: *Tree,
        handle: NodeHandle,
        builder: *scene_builder.Builder,
        origin: PointF,
    ) !void {
        const target = try self.slot(handle);
        if (target.object == .box and target.object.box.hidden) {
            self.clearPaintSubtree(handle);
            return;
        }
        const saved_transform = builder.transform;
        defer builder.transform = saved_transform;
        if (target.object == .box) {
            var local = target.object.box.transform;
            local.origin = PointF.add(origin, local.origin);
            builder.transform = try saved_transform.compose(local);
        }
        const bounds: RectF = .{
            .x = origin.x,
            .y = origin.y,
            .width = target.size.width,
            .height = target.size.height,
        };
        const isolated = target.object == .box and target.object.box.opacity != 1;
        if (isolated) try builder.pushOpacity(target.object.box.opacity);
        const clips = switch (target.object) {
            .box => |value| paint: {
                if (value.shadow) |shadow| try builder.boxShadow(bounds, value.corner_radius, shadow);
                if (value.background_gradient) |gradient| {
                    try builder.gradientRectangle(bounds, gradient, .{ .x = bounds.x, .y = bounds.y }, value.border_color, value.border_width, value.corner_radius);
                } else if (value.border_color != null or
                    (value.background != null and value.corner_radius != 0))
                {
                    try builder.decoratedRectangle(
                        bounds,
                        value.background,
                        value.border_color,
                        value.border_width,
                        value.corner_radius,
                    );
                } else if (value.background) |color| try builder.solidRectangle(bounds, color);
                if (value.outline_color) |outline_color| {
                    const expansion = if (value.outline_inset)
                        -@min(value.outline_gap, @min(bounds.width, bounds.height) / 2)
                    else
                        value.outline_gap + value.outline_width;
                    try builder.decoratedRectangle(
                        .{
                            .x = bounds.x - expansion,
                            .y = bounds.y - expansion,
                            .width = bounds.width + expansion * 2,
                            .height = bounds.height + expansion * 2,
                        },
                        null,
                        outline_color,
                        value.outline_width,
                        @max(0, value.corner_radius + expansion),
                    );
                }
                break :paint value.clip;
            },
            .flex => false,
            .grid => false,
            .split => false,
            .stack => |value| value.clip,
            .anchored => false,
            .scroll => true,
            .image => |value| paint: {
                if (value.image) |image| try builder.image(image, bounds, value.fit);
                break :paint false;
            },
            .canvas => |value| paint: {
                try value.paint(builder, bounds);
                break :paint false;
            },
            .text => |value| paint: {
                const paragraph_handle = target.paragraph_layout orelse return error.LayoutRequired;
                try builder.pushClip(bounds);
                try builder.paragraph(paragraph_handle, origin, value.color);
                break :paint true;
            },
            .text_input => |value| paint: {
                const paragraph_handle = target.paragraph_layout orelse return error.LayoutRequired;
                const paragraph_layout = self.paragraphs.?.get(paragraph_handle) catch
                    return error.StaleParagraph;
                const text_origin: PointF = .{ .x = origin.x + target.text_offset_x, .y = origin.y + target.text_offset_y };
                try builder.pushClip(bounds);
                if (value.selection_start != value.selection_end) {
                    var rectangles = try paragraph_layout.positioned.selectionRectangleIterator(.{
                        .start = value.selection_start,
                        .end = value.selection_end,
                    });
                    while (try rectangles.next()) |rectangle| try builder.solidRectangle(.{
                        .x = text_origin.x + rectangle.x,
                        .y = text_origin.y + rectangle.y,
                        .width = rectangle.width,
                        .height = rectangle.height,
                    }, value.selection_color);
                }
                if (value.show_caret and value.caret_shape == .block) {
                    const rectangle = try textInputCaretRectangle(&paragraph_layout.positioned, value);
                    var block_color = value.caret_color;
                    block_color.a = @min(block_color.a, 128);
                    try builder.solidRectangle(.{
                        .x = text_origin.x + rectangle.x,
                        .y = text_origin.y + rectangle.y,
                        .width = rectangle.width,
                        .height = rectangle.height,
                    }, block_color);
                }
                if (target.placeholder_layout) |placeholder|
                    try builder.paragraph(placeholder, origin, value.placeholder_color)
                else
                    try builder.paragraph(paragraph_handle, text_origin, value.color);
                if (value.preedit) |range| {
                    var rectangles = try paragraph_layout.positioned.selectionRectangleIterator(.{
                        .start = range.start,
                        .end = range.end,
                    });
                    while (try rectangles.next()) |rectangle| try builder.solidRectangle(.{
                        .x = text_origin.x + rectangle.x,
                        .y = text_origin.y + rectangle.y + rectangle.height - value.preedit_width,
                        .width = rectangle.width,
                        .height = value.preedit_width,
                    }, value.preedit_color.?);
                }
                if (value.show_caret and value.selection_start == value.selection_end and value.caret_shape != .block) {
                    const rectangle = try textInputCaretRectangle(&paragraph_layout.positioned, value);
                    try builder.caretRectangle(.{
                        .x = text_origin.x + rectangle.x,
                        .y = text_origin.y + rectangle.y,
                        .width = rectangle.width,
                        .height = rectangle.height,
                    }, value.caret_color);
                }
                break :paint true;
            },
        };
        if (clips and target.object != .text and target.object != .text_input) {
            if (target.object == .box)
                try builder.pushRoundedClip(bounds, target.object.box.corner_radius)
            else if (target.object == .scroll) {
                const inner = scroll_impl.contentViewport(target.object.scroll, target.size);
                try builder.pushClip(.{ .x = bounds.x, .y = bounds.y, .width = inner.width, .height = inner.height });
            } else try builder.pushClip(bounds);
        }
        var child = target.first_child;
        while (child) |child_handle| {
            const child_slot = try self.slot(child_handle);
            const next = child_slot.next_sibling;
            if (target.object == .text) {
                const appearance = child_slot.object.box;
                var rectangles = try self.textRangeRectangles(child_handle, target.size);
                while (try rectangles.next()) |rect| {
                    const fragment: RectF = .{ .x = origin.x + rect.x, .y = origin.y + rect.y, .width = rect.width, .height = rect.height };
                    if (appearance.background) |color| try builder.solidRectangle(.{
                        .x = fragment.x,
                        .y = fragment.y + fragment.height - 1,
                        .width = fragment.width,
                        .height = 1,
                    }, color);
                    if (appearance.outline_color) |color| try builder.decoratedRectangle(fragment, null, color, appearance.outline_width, 0);
                }
                child_slot.needs_paint = false;
            } else try self.paintNode(child_handle, builder, PointF.add(origin, child_slot.offset));
            child = if (target.object == .anchored) null else next;
        }
        if (clips) try builder.popClip();
        if (target.object == .scroll) if (target.object.scroll.scrollbar) |style| {
            var track = scroll_impl.track(target.object.scroll, target.size);
            track.x += origin.x;
            track.y += origin.y;
            try builder.solidRectangle(track, style.track);
            const metrics = try self.scrollMetrics(handle);
            if (metrics.max_offset > 0) {
                const thumb = scroll_impl.thumb(metrics);
                const rect: RectF = if (metrics.axis == .vertical)
                    .{ .x = track.x + @min(2, track.width / 2), .y = track.y + thumb.start, .width = @max(0, track.width - 4), .height = thumb.length }
                else
                    .{ .x = track.x + thumb.start, .y = track.y + @min(2, track.height / 2), .width = thumb.length, .height = @max(0, track.height - 4) };
                try builder.decoratedRectangle(rect, style.thumb, null, 0, 4);
            }
        };
        if (isolated) try builder.popOpacity();
        target.needs_paint = false;
    }

    fn hitTestNode(self: *Tree, handle: NodeHandle, parent_point: PointF) !?NodeHandle {
        const target = try self.slot(handle);
        if (!target.interactive) return null;
        if (target.object == .box and target.object.box.hidden) return null;
        const point = if (target.object == .box) target.object.box.transform.inversePoint(parent_point) else parent_point;
        if (!validPoint(point)) return null;
        const inside = (RectF{ .x = 0, .y = 0, .width = target.size.width, .height = target.size.height }).contains(point);
        const clips = switch (target.object) {
            .box => |value| value.clip,
            .stack => |value| value.clip,
            .scroll, .text, .text_input, .canvas => true,
            else => false,
        };
        if (!inside and clips) return null;
        if (target.object == .box and target.object.box.clip and
            !(RectF{ .x = 0, .y = 0, .width = target.size.width, .height = target.size.height }).containsRounded(point, target.object.box.corner_radius))
            return null;
        if (target.object == .scroll and target.object.scroll.scrollbar != null and
            scroll_impl.track(target.object.scroll, target.size).contains(point)) return handle;
        var child = if (target.object == .anchored) target.first_child else target.last_child;
        while (child) |child_handle| {
            const child_slot = try self.slot(child_handle);
            const previous = child_slot.previous_sibling;
            if (target.object == .text) {
                if (child_slot.interactive) {
                    var rectangles = try self.textRangeRectangles(child_handle, target.size);
                    while (try rectangles.next()) |rect| if (rect.contains(point)) return child_handle;
                }
            } else if (try self.hitTestNode(child_handle, .{
                .x = point.x - child_slot.offset.x,
                .y = point.y - child_slot.offset.y,
            })) |hit| return hit;
            child = previous;
        }
        return if (inside) handle else null;
    }

    fn rootViewport(_: *Tree, root: *const Slot) SizeF {
        // Bounded root constraints describe the window even when its inline
        // content shrink-wraps. Unbounded axes fall back to the root's size.
        return .{
            .width = if (root.last_constraints.hasBoundedWidth()) root.last_constraints.max_width else root.size.width,
            .height = if (root.last_constraints.hasBoundedHeight()) root.last_constraints.max_height else root.size.height,
        };
    }

    fn floatingChild(target: *const Slot) ?NodeHandle {
        if (target.object != .anchored) return null;
        const first = target.first_child orelse return null;
        const last = target.last_child.?;
        return if (same(first, last)) null else last;
    }

    /// Run after inline layout, with final ancestor offsets. Measuring a popup
    /// may lay out more anchors; recurse only after their containing popup has
    /// its final offset. No allocation or layout work for unchanged children.
    fn placeOverlays(self: *Tree, handle: NodeHandle, origin: PointF, window: SizeF) LayoutError!void {
        const target = try self.slot(handle);
        if (!target.contains_overlays) return;
        if (floatingChild(target)) |popup| {
            const value = target.object.anchored;
            const viewport_rect = anchored_impl.inset(window, value.margin);
            const popup_size = try self.layoutNode(popup, .{
                .max_width = viewport_rect.width,
                .max_height = viewport_rect.height,
            });
            const trigger = try self.slot(target.first_child.?);
            const trigger_bounds = (try self.paintTransform(target.first_child.?)).rect(.{
                .x = 0,
                .y = 0,
                .width = trigger.size.width,
                .height = trigger.size.height,
            });
            const position = anchored_impl.place(value, trigger_bounds, popup_size, viewport_rect);
            try self.setChildOffset(popup, .{ .x = position.x - origin.x, .y = position.y - origin.y });
        }
        var child = target.first_child;
        while (child) |current| : (child = self.nextSibling(current)) {
            const offset = (try self.slot(current)).offset;
            try self.placeOverlays(current, PointF.add(origin, offset), window);
        }
    }

    /// Deferred order is parent popup, then descendants in declaration order.
    /// Thus nested overlays cover parent content, and later sibling subtrees
    /// cover earlier ones. All ordinary ancestor clips have been popped.
    fn paintOverlays(self: *Tree, handle: NodeHandle, builder: *scene_builder.Builder, origin: PointF) !void {
        const target = try self.slot(handle);
        if (!target.contains_overlays) return;
        if (target.object == .box and target.object.box.hidden) return;
        if (floatingChild(target)) |popup|
            try self.paintNode(popup, builder, PointF.add(origin, (try self.slot(popup)).offset));
        var child = target.first_child;
        while (child) |current| : (child = self.nextSibling(current))
            try self.paintOverlays(current, builder, PointF.add(origin, (try self.slot(current)).offset));
    }

    /// Exact reverse of paintOverlays, intentionally without ancestor bounds
    /// gating. Ordinary hitTestNode keeps its existing bounds rules.
    fn hitTestOverlays(self: *Tree, handle: NodeHandle, point: PointF) !?NodeHandle {
        const target = try self.slot(handle);
        if (!target.interactive) return null;
        if (!target.contains_overlays) return null;
        if (target.object == .box and target.object.box.hidden) return null;
        var child = target.last_child;
        while (child) |current| : (child = self.previousSibling(current)) {
            const offset = (try self.slot(current)).offset;
            if (try self.hitTestOverlays(current, .{ .x = point.x - offset.x, .y = point.y - offset.y })) |hit|
                return hit;
        }
        if (floatingChild(target)) |popup| {
            const offset = (try self.slot(popup)).offset;
            return self.hitTestNode(popup, .{ .x = point.x - offset.x, .y = point.y - offset.y });
        }
        return null;
    }

    fn detach(self: *Tree, handle: NodeHandle) !void {
        const target = try self.slot(handle);
        const parent_handle = target.parent orelse return;
        const parent = try self.slot(parent_handle);
        if (target.previous_sibling) |previous|
            (try self.slot(previous)).next_sibling = target.next_sibling
        else
            parent.first_child = target.next_sibling;
        if (target.next_sibling) |next|
            (try self.slot(next)).previous_sibling = target.previous_sibling
        else
            parent.last_child = target.previous_sibling;
        target.parent = null;
        target.previous_sibling = null;
        target.next_sibling = null;
        target.parent_data = .none;
        self.markNeedsLayout(parent_handle);
    }

    fn markNeedsLayout(self: *Tree, handle: NodeHandle) void {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = self.slot(value) catch unreachable;
            target.needs_layout = true;
            target.needs_paint = true;
            current = target.parent;
        }
    }

    fn markNeedsPaint(self: *Tree, handle: NodeHandle) void {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = self.slot(value) catch unreachable;
            if (target.object == .box and target.object.box.hidden) {
                target.needs_paint = false;
                return;
            }
            target.needs_paint = true;
            current = target.parent;
        }
    }

    fn clearPaintSubtree(self: *Tree, handle: NodeHandle) void {
        const target = self.slot(handle) catch unreachable;
        target.needs_paint = false;
        var child = target.first_child;
        while (child) |value| {
            const next = (self.slot(value) catch unreachable).next_sibling;
            self.clearPaintSubtree(value);
            child = next;
        }
    }

    fn layoutPathCurrent(self: *Tree, handle: NodeHandle) !bool {
        var current: ?NodeHandle = handle;
        while (current) |value| {
            const target = try self.slot(value);
            if (target.needs_layout) return false;
            current = target.parent;
        }
        return true;
    }

    fn slot(self: *Tree, handle: NodeHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleRenderObject;
        const target = &self.slots[handle.slot];
        if (!target.active or target.generation != handle.generation)
            return error.StaleRenderObject;
        return target;
    }

    fn layoutImage(self: *Tree, value: types.Image, constraints: Constraints) LayoutError!SizeF {
        const intrinsic: ?SizeF = if (value.image) |image| size: {
            const cache = self.images orelse return error.ImageResourcesRequired;
            const bitmap = cache.get(image) catch return error.StaleImageHandle;
            break :size .{
                .width = @floatFromInt(bitmap.intrinsic_width),
                .height = @floatFromInt(bitmap.intrinsic_height),
            };
        } else null;
        return image_impl.layout(value, intrinsic, constraints);
    }

    fn layoutText(
        self: *Tree,
        handle: NodeHandle,
        value: types.Text,
        constraints: Constraints,
    ) LayoutError!SizeF {
        const sources = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
        const paragraphs = self.paragraphs orelse return error.ParagraphResourcesRequired;
        const source = sources.get(value.source) catch return error.StaleParagraphSource;
        const current = try self.slot(handle);
        // Height constrains the box, not paragraph shaping or line placement.
        // Dirty nodes still resolve style/source/child changes through acquire.
        if (!current.needs_layout and current.has_layout and current.first_child == null and
            current.last_constraints.min_width == constraints.min_width and
            current.last_constraints.max_width == constraints.max_width)
        {
            const retained = paragraphs.get(current.paragraph_layout.?) catch return error.StaleParagraph;
            return constraints.constrain(retained.size);
        }
        var request: text.ParagraphCache.Request = .{
            .utf8 = source.utf8,
            .base_direction = source.base_direction,
            .language = source.language,
            .logical_size = source.logical_size,
            .max_width = if (constraints.hasBoundedWidth())
                constraints.max_width
            else
                std.math.floatMax(f32),
            .candidates = source.candidates,
            .runs = source.runs,
            .include_caret_stops = current.first_child != null,
            .configuration_revision = source.configuration_revision,
            .style = .{
                .alignment = value.alignment,
                .max_lines = value.max_lines,
                .overflow = value.overflow,
            },
        };
        var layout_handle = paragraphs.acquire(request) catch return error.ParagraphLayoutFailed;
        errdefer paragraphs.release(layout_handle) catch unreachable;
        var paragraph_layout = paragraphs.get(layout_handle) catch return error.StaleParagraph;
        const fitted_width = constraints.constrain(.{
            .width = paragraph_layout.positioned.contentWidth(),
            .height = paragraph_layout.size.height,
        }).width;
        if (fitted_width != paragraph_layout.size.width) {
            request.max_width = fitted_width;
            const fitted_handle = paragraphs.acquire(request) catch return error.ParagraphLayoutFailed;
            paragraphs.release(layout_handle) catch unreachable;
            layout_handle = fitted_handle;
            paragraph_layout = paragraphs.get(layout_handle) catch return error.StaleParagraph;
        }
        const result = constraints.constrain(paragraph_layout.size);
        const target = try self.slot(handle);
        self.releaseParagraphLayout(target);
        target.paragraph_layout = layout_handle;
        errdefer target.paragraph_layout = null;
        var child = target.first_child;
        while (child) |link| : (child = self.nextSibling(link)) {
            const link_slot = try self.slot(link);
            if (link_slot.object != .box or link_slot.first_child != null or
                link_slot.parent_data.text_range.end > source.utf8.len) return error.InvalidParentData;
            var rectangles = self.textRangeRectangles(link, result) catch return error.InvalidParentData;
            var bounds: ?RectF = null;
            while (rectangles.next() catch return error.InvalidParentData) |rect| {
                if (bounds) |old| {
                    const x = @min(old.x, rect.x);
                    const y = @min(old.y, rect.y);
                    bounds = .{ .x = x, .y = y, .width = @max(old.x + old.width, rect.x + rect.width) - x, .height = @max(old.y + old.height, rect.y + rect.height) - y };
                } else bounds = rect;
            }
            const rect = bounds orelse RectF{ .x = 0, .y = 0, .width = 0, .height = 0 };
            _ = try self.layoutChild(link, Constraints.tight(.{ .width = rect.width, .height = rect.height }));
            try self.setChildOffset(link, .{ .x = rect.x, .y = rect.y });
        }
        return result;
    }

    fn layoutTextInput(
        self: *Tree,
        handle: NodeHandle,
        input: types.TextInput,
        constraints: Constraints,
    ) LayoutError!SizeF {
        const sources = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
        const paragraphs = self.paragraphs orelse return error.ParagraphResourcesRequired;
        const source = sources.get(input.source) catch return error.StaleParagraphSource;
        if (input.selection_start > input.selection_end or
            input.selection_end > source.utf8.len or input.caret_offset > source.utf8.len)
            return error.InvalidTextInputRange;
        if (input.preedit) |range| if (range.start > range.end or range.end > source.utf8.len)
            return error.InvalidTextInputRange;
        // Reserve the same EOL cell for every shape. A beam-sized gutter
        // lets a block at an upstream wrap edge reveal past the viewport;
        // reserving only in block mode would rewrap on every mode switch.
        const caret_gutter = if (input.multiline and constraints.hasBoundedWidth()) blk: {
            const font = sources.font_cache.get(source.candidates[0]) catch return error.ParagraphLayoutFailed;
            const cell = font.caretFallbackWidth(self.allocator, source.language, source.logical_size) catch return error.ParagraphLayoutFailed;
            break :blk @max(input.caret_width, cell);
        } else input.caret_width;
        const layout_handle = paragraphs.acquire(.{
            .utf8 = source.utf8,
            .base_direction = source.base_direction,
            .language = source.language,
            .logical_size = source.logical_size,
            .max_width = if (input.multiline and constraints.hasBoundedWidth())
                @max(1, constraints.max_width - caret_gutter)
            else
                std.math.floatMax(f32),
            .candidates = source.candidates,
            .configuration_revision = source.configuration_revision,
            .style = .{ .alignment = input.alignment, .break_long_words = input.multiline },
            .include_caret_stops = true,
        }) catch return error.ParagraphLayoutFailed;
        errdefer paragraphs.release(layout_handle) catch unreachable;
        const paragraph_layout = paragraphs.get(layout_handle) catch return error.StaleParagraph;
        if (!hasCaretBoundary(&paragraph_layout.positioned, input.selection_start) or
            !hasCaretBoundary(&paragraph_layout.positioned, input.selection_end) or
            !hasCaretBoundary(&paragraph_layout.positioned, input.caret_offset))
            return error.InvalidTextInputRange;
        if (input.preedit) |range| if (!hasCaretBoundary(&paragraph_layout.positioned, range.start) or
            !hasCaretBoundary(&paragraph_layout.positioned, range.end))
            return error.InvalidTextInputRange;
        var placeholder_layout: ?text.ParagraphHandle = null;
        errdefer if (placeholder_layout) |value| paragraphs.release(value) catch unreachable;
        var content_size = paragraph_layout.size;
        if (source.utf8.len == 0 and input.preedit == null) {
            if (input.placeholder) |placeholder| {
                const hint = sources.get(placeholder) catch return error.StaleParagraphSource;
                const hint_layout = paragraphs.acquire(.{
                    .utf8 = hint.utf8,
                    .base_direction = hint.base_direction,
                    .language = hint.language,
                    .logical_size = hint.logical_size,
                    .max_width = if (constraints.hasBoundedWidth()) constraints.max_width else std.math.floatMax(f32),
                    .candidates = hint.candidates,
                    .configuration_revision = hint.configuration_revision,
                    .style = .{ .alignment = input.alignment, .max_lines = 1, .overflow = .ellipsis },
                }) catch return error.ParagraphLayoutFailed;
                placeholder_layout = hint_layout;
                const hint_size = (paragraphs.get(hint_layout) catch return error.StaleParagraph).size;
                content_size.width = @max(content_size.width, hint_size.width);
                content_size.height = @max(content_size.height, hint_size.height);
            }
        }
        content_size.width = if (constraints.hasBoundedWidth())
            constraints.max_width
        else
            content_size.width + (textInputCaretOverhang(
                &paragraph_layout.positioned,
                input,
                paragraph_layout.size.width,
            ) catch return error.InvalidTextInputRange);
        const result = constraints.constrain(content_size);
        const target = try self.slot(handle);
        self.releaseParagraphLayout(target);
        target.paragraph_layout = layout_handle;
        target.placeholder_layout = placeholder_layout;
        try self.updateTextInputOffset(target, result);
        return result;
    }

    fn updateTextInputOffset(self: *Tree, target: *Slot, viewport: SizeF) LayoutError!void {
        const paragraph_layout = self.paragraphs.?.get(target.paragraph_layout.?) catch
            return error.StaleParagraph;
        const input = target.object.text_input;
        const width = viewport.width;
        const overhang = textInputCaretOverhang(
            &paragraph_layout.positioned,
            input,
            paragraph_layout.size.width,
        ) catch return error.InvalidTextInputRange;
        const caret = textInputCaretRectangle(&paragraph_layout.positioned, input) catch
            return error.InvalidTextInputRange;
        const left = @max(0, -caret.x);
        const remaining = width - paragraph_layout.size.width - overhang;
        const minimum = @min(0, remaining) + left;
        if (remaining >= 0 or !target.has_layout) {
            const rtl = paragraph_layout.positioned.lines[0].base_level & 1 != 0;
            target.text_offset_x = left + switch (input.alignment) {
                .start => if (rtl) remaining else 0,
                .end => if (rtl) 0 else remaining,
                .center => remaining / 2,
                .justify => 0,
            };
        } else {
            target.text_offset_x = std.math.clamp(target.text_offset_x, minimum, left);
        }
        const minimum_y = if (input.multiline) @min(0, viewport.height - paragraph_layout.size.height) else 0;
        target.text_offset_y = std.math.clamp(target.text_offset_y, minimum_y, 0);
        if (!input.reveal_caret and !input.show_caret) return;
        if (caret.x + target.text_offset_x + caret.width > width)
            target.text_offset_x = width - caret.x - caret.width;
        if (caret.x + target.text_offset_x < 0)
            target.text_offset_x = -caret.x;
        if (remaining < 0)
            target.text_offset_x = std.math.clamp(target.text_offset_x, minimum, left);
        if (caret.y + target.text_offset_y + caret.height > viewport.height)
            target.text_offset_y = viewport.height - caret.y - caret.height;
        if (caret.y + target.text_offset_y < 0)
            target.text_offset_y = -caret.y;
        target.text_offset_y = std.math.clamp(target.text_offset_y, minimum_y, 0);
    }

    fn ensureTextLayout(self: *Tree, handle: NodeHandle) !*Slot {
        var target = try self.slot(handle);
        if (target.object != .text_input) return error.NotTextInputObject;
        if (!target.has_layout) return error.LayoutRequired;
        if (target.needs_layout) {
            const constraints = target.last_constraints;
            _ = try self.layoutNode(handle, constraints);
            target = try self.slot(handle);
        }
        if (target.paragraph_layout == null) return error.LayoutRequired;
        return target;
    }

    fn retainObject(self: *Tree, object: types.Object) !void {
        switch (object) {
            .canvas => |value| value.retain(),
            .image => |value| if (value.image) |image| {
                const cache = self.images orelse return error.ImageResourcesRequired;
                try cache.retain(image);
            },
            .text => |value| {
                const sources = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
                try sources.retain(value.source);
            },
            .text_input => |input| {
                const sources = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
                try sources.retain(input.source);
                errdefer sources.release(input.source) catch unreachable;
                if (input.placeholder) |placeholder| try sources.retain(placeholder);
            },
            else => {},
        }
    }

    fn releaseObject(self: *Tree, object: types.Object) void {
        switch (object) {
            .canvas => |value| value.release(),
            .image => |value| if (value.image) |image| self.images.?.release(image) catch unreachable,
            .text => |value| self.paragraph_sources.?.release(value.source) catch unreachable,
            .text_input => |input| {
                self.paragraph_sources.?.release(input.source) catch unreachable;
                if (input.placeholder) |placeholder| self.paragraph_sources.?.release(placeholder) catch unreachable;
            },
            else => {},
        }
    }

    fn releaseParagraphLayout(self: *Tree, slot_value: *Slot) void {
        if (slot_value.paragraph_layout) |paragraph_handle|
            self.paragraphs.?.release(paragraph_handle) catch unreachable;
        slot_value.paragraph_layout = null;
        if (slot_value.placeholder_layout) |placeholder|
            self.paragraphs.?.release(placeholder) catch unreachable;
        slot_value.placeholder_layout = null;
    }
};

fn validateObject(object: types.Object) !void {
    switch (object) {
        .anchored => |value| try anchored_impl.validate(value),
        .box => |value| try box_impl.validate(value),
        .flex => |value| try flex_impl.validate(value),
        .grid => |value| try grid_impl.validate(value),
        .split => |value| try split_impl.validate(value),
        .stack => {},
        .scroll => {},
        .image => |value| try image_impl.validate(value),
        .canvas => {}, // Drawing.create validates the immutable snapshot.
        .text => |value| {
            if (value.max_lines == 0) return error.InvalidMaxLines;
            if (value.overflow == .ellipsis and value.max_lines == null)
                return error.EllipsisRequiresMaxLines;
        },
        .text_input => |input| {
            if (!std.math.isFinite(input.caret_width) or input.caret_width <= 0)
                return error.InvalidCaretWidth;
            if (!std.math.isFinite(input.preedit_width) or input.preedit_width <= 0)
                return error.InvalidPreeditWidth;
            if (input.selection_start > input.selection_end)
                return error.InvalidTextInputRange;
            if (input.preedit) |range| {
                if (range.start > range.end or input.preedit_color == null)
                    return error.InvalidTextInputRange;
            } else if (input.preedit_color != null) return error.InvalidTextInputRange;
        },
    }
}

fn validateParentData(parent: types.Object, data: types.ParentData) !void {
    switch (parent) {
        .box, .anchored => if (data != .none) return error.InvalidParentData,
        .flex => |value| {
            if (data != .none and data != .flex) return error.InvalidParentData;
            if (value.wrap and data == .flex and data.flex.factor != 0) return error.FlexInWrap;
        },
        .grid => |value| try grid_impl.validatePlacement(value, data),
        .split => if (data != .none) return error.InvalidParentData,
        .stack => switch (data) {
            .none => {},
            .stack => |value| if (!validPoint(.{ .x = value.x, .y = value.y }))
                return error.InvalidParentData,
            .positioned => |value| try value.validate(),
            else => return error.InvalidParentData,
        },
        .scroll => if (data != .none) return error.InvalidParentData,
        .image => return error.ImageHasChildren,
        .canvas => return error.CanvasHasChildren,
        .text => {
            if (data != .text_range) return error.TextHasChildren;
            if (data.text_range.start >= data.text_range.end) return error.InvalidParentData;
        },
        .text_input => return error.TextInputHasChildren,
    }
}

fn layoutPropertiesChanged(old: types.Object, new: types.Object) bool {
    if (std.meta.activeTag(old) != std.meta.activeTag(new)) return true;
    return switch (old) {
        .box => |old_box| changed: {
            const new_box = new.box;
            break :changed old_box.width != new_box.width or old_box.height != new_box.height or
                old_box.min_width != new_box.min_width or old_box.min_height != new_box.min_height or
                old_box.max_width != new_box.max_width or old_box.max_height != new_box.max_height or
                old_box.fill_width != new_box.fill_width or old_box.fill_height != new_box.fill_height or
                old_box.height_factor != new_box.height_factor or
                old_box.aspect_ratio != new_box.aspect_ratio or
                old_box.border_width != new_box.border_width or
                !std.meta.eql(old_box.padding, new_box.padding) or
                !std.meta.eql(old_box.alignment, new_box.alignment);
        },
        .flex => |old_flex| !std.meta.eql(old_flex, new.flex),
        .grid => |old_grid| !std.meta.eql(old_grid, new.grid),
        .split => |old_split| !std.meta.eql(old_split, new.split),
        .stack => |old_stack| old_stack.unbounded_height != new.stack.unbounded_height,
        .anchored => |old_anchored| !std.meta.eql(old_anchored, new.anchored),
        .scroll => |old_scroll| old_scroll.axis != new.scroll.axis or (old_scroll.scrollbar == null) != (new.scroll.scrollbar == null),
        .image => |old_image| (old_image.width == null or old_image.height == null) and
            !std.meta.eql(old_image.image, new.image.image) or
            old_image.width != new.image.width or old_image.height != new.image.height or
            old_image.fill_width != new.image.fill_width or old_image.fill_height != new.image.fill_height,
        .canvas => |old_drawing| !std.meta.eql(old_drawing.size, new.canvas.size),
        .text => |old_text| !sameSource(old_text.source, new.text.source) or
            old_text.alignment != new.text.alignment or
            old_text.max_lines != new.text.max_lines or
            old_text.overflow != new.text.overflow,
        .text_input => |old_input| !sameSource(old_input.source, new.text_input.source) or
            !std.meta.eql(old_input.placeholder, new.text_input.placeholder) or
            (old_input.placeholder != null and (old_input.preedit == null) != (new.text_input.preedit == null)) or
            old_input.alignment != new.text_input.alignment or
            old_input.caret_width != new.text_input.caret_width or
            old_input.caret_shape != new.text_input.caret_shape or
            old_input.multiline != new.text_input.multiline,
    };
}

fn validPoint(point: PointF) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn validSize(size_value: SizeF) bool {
    return std.math.isFinite(size_value.width) and std.math.isFinite(size_value.height) and
        size_value.width >= 0 and size_value.height >= 0;
}

fn same(a: NodeHandle, b: NodeHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sameSource(a: text.ParagraphSourceHandle, b: text.ParagraphSourceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sameParagraph(a: text.ParagraphHandle, b: text.ParagraphHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sourceChanged(old: types.Object, new: types.Object) bool {
    const old_source = objectSource(old);
    const new_source = objectSource(new);
    if (old_source == null or new_source == null) return old_source != null or new_source != null;
    return !sameSource(old_source.?, new_source.?);
}

fn objectSource(object: types.Object) ?text.ParagraphSourceHandle {
    return switch (object) {
        .text => |value| value.source,
        .text_input => |input| input.source,
        else => null,
    };
}

fn hasCaretBoundary(positioned: *const text.PositionedLines, byte_offset: usize) bool {
    for (positioned.carets) |caret| if (caret.byte_offset == byte_offset) return true;
    return false;
}

fn textInputCaretRectangle(
    positioned: *const text.PositionedLines,
    input: types.TextInput,
) !RectF {
    if (input.caret_shape == .beam) return positioned.caretRectangleForOffset(
        input.caret_offset,
        input.caret_affinity,
        input.caret_width,
    );
    var rectangle = try positioned.caretGraphemeRectangleForOffset(
        input.caret_offset,
        input.caret_affinity,
    );
    if (input.caret_shape == .underline) {
        const thickness = @min(input.caret_width, rectangle.height);
        rectangle.y += rectangle.height - thickness;
        rectangle.height = thickness;
    }
    return rectangle;
}

fn textInputCaretOverhang(
    positioned: *const text.PositionedLines,
    input: types.TextInput,
    paragraph_width: f32,
) !f32 {
    if (input.caret_shape == .beam) return input.caret_width;
    // Reserve fallback space even while the caret covers an interior grapheme.
    // Otherwise an unbounded field changes intrinsic width at EOL, and a
    // centered field shifts its text when only the selection moved.
    const reserve = positioned.caret_fallback_width;
    const rectangle = try textInputCaretRectangle(positioned, input);
    return @max(reserve, @max(0, -rectangle.x) + @max(0, rectangle.x + rectangle.width - paragraph_width));
}

test "layout property classification includes geometry and excludes paint-only state" {
    for ([_]types.Box{
        .{ .min_width = 10 },      .{ .min_height = 5 }, .{ .fill_width = true }, .{ .fill_height = true },
        .{ .height_factor = 0.5 },
    }) |box| try std.testing.expect(layoutPropertiesChanged(.{ .box = .{} }, .{ .box = box }));
    try std.testing.expect(layoutPropertiesChanged(
        .{ .stack = .{} },
        .{ .stack = .{ .unbounded_height = true } },
    ));
    const source: text.ParagraphSourceHandle = .{ .slot = 0, .generation = 1 };
    const input: types.TextInput = .{
        .source = source,
        .color = Color.rgba(1, 2, 3, 255),
        .selection_color = Color.rgba(4, 5, 6, 255),
        .caret_color = Color.rgba(7, 8, 9, 255),
        .selection_start = 0,
        .selection_end = 0,
        .caret_offset = 0,
    };
    var wider_caret = input;
    wider_caret.caret_width = 3;
    try std.testing.expect(layoutPropertiesChanged(.{ .text_input = input }, .{ .text_input = wider_caret }));
    var block_caret = input;
    block_caret.caret_shape = .block;
    try std.testing.expect(layoutPropertiesChanged(.{ .text_input = input }, .{ .text_input = block_caret }));

    try std.testing.expect(!layoutPropertiesChanged(
        .{ .box = .{} },
        .{ .box = .{ .background = Color.rgba(10, 20, 30, 255), .clip = true } },
    ));
    const fixed: types.Image = .{ .width = 40, .height = 20 };
    var replacement = fixed;
    replacement.image = .{ .slot = 0, .generation = 1 };
    try std.testing.expect(!layoutPropertiesChanged(.{ .image = fixed }, .{ .image = replacement }));
    try std.testing.expect(layoutPropertiesChanged(.{ .image = .{ .width = 40 } }, .{ .image = replacement }));
}

test "split lays out three tight children on both axes and resizes" {
    for ([_]types.Axis{ .horizontal, .vertical }) |axis| {
        var tree: Tree = undefined;
        try tree.init(std.testing.allocator, 4);
        defer tree.deinit();
        const root = try tree.create(.{ .split = .{
            .axis = axis,
            .position = 0.2,
            .min_first = 30,
            .min_second = 10,
            .divider = 8,
        } });
        const first = try tree.create(.{ .box = .{} });
        const second = try tree.create(.{ .box = .{} });
        const divider = try tree.create(.{ .box = .{} });
        try tree.appendChild(root, first, .none);
        try tree.appendChild(root, second, .none);
        try tree.appendChild(root, divider, .none);

        _ = try tree.layout(root, Constraints.tight(.{ .width = 108, .height = 68 }));
        const first_size = try tree.nodeSize(first);
        const second_offset = try tree.nodeOffset(second);
        const divider_offset = try tree.nodeOffset(divider);
        if (axis == .horizontal) {
            try std.testing.expectEqual(@as(f32, 30), first_size.width);
            try std.testing.expectEqual(@as(f32, 38), second_offset.x);
            try std.testing.expectEqual(@as(f32, 30), divider_offset.x);
        } else {
            try std.testing.expectEqual(@as(f32, 30), first_size.height);
            try std.testing.expectEqual(@as(f32, 38), second_offset.y);
            try std.testing.expectEqual(@as(f32, 30), divider_offset.y);
        }

        _ = try tree.layout(root, Constraints.tight(.{ .width = 40, .height = 40 }));
        const shrunk = try tree.nodeSize(first);
        try std.testing.expectEqual(@as(f32, 24), if (axis == .horizontal) shrunk.width else shrunk.height);
    }
}

test "split validates properties, child count, and bounded constraints" {
    try std.testing.expectError(error.InvalidSplitPosition, Tree.validate(.{ .split = .{ .position = 1.1 } }));
    try std.testing.expectError(error.InvalidSplitMinimum, Tree.validate(.{ .split = .{ .min_second = -1 } }));
    try std.testing.expectError(error.InvalidSplitDivider, Tree.validate(.{ .split = .{ .divider = std.math.nan(f32) } }));
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .split = .{} });
    try std.testing.expectError(error.SplitRequiresThreeChildren, tree.layout(root, Constraints.tight(.{ .width = 20, .height = 20 })));
    try std.testing.expectError(error.UnboundedSplitConstraints, tree.layout(root, .{ .max_height = 20 }));
}

test "hidden box retains geometry but disappears from hit testing and reappears" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .box = .{ .width = 40, .height = 30 } });
    const child = try tree.create(.{ .box = .{ .width = 10, .height = 10 } });
    try tree.appendChild(root, child, .none);
    _ = try tree.layout(root, .{});
    const retained_size = try tree.nodeSize(child);
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 5, .y = 5 })).?);
    try tree.update(root, .{ .box = .{ .hidden = true, .width = 40, .height = 30 } });
    try std.testing.expect(!(try tree.isVisible(child)));
    try std.testing.expectEqual(@as(?NodeHandle, null), try tree.hitTest(root, .{ .x = 5, .y = 5 }));
    try std.testing.expectEqual(retained_size, try tree.nodeSize(child));
    var commands: [2]@import("../../scene/root.zig").Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(usize, 0), builder.count);
    try tree.update(child, .{ .box = .{ .width = 10, .height = 10, .background = Color.rgba(255, 0, 0, 255) } });
    try std.testing.expect(!(try tree.paintDirty(root)));
    try tree.update(root, .{ .box = .{ .width = 40, .height = 30 } });
    try std.testing.expect(try tree.isVisible(child));
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 5, .y = 5 })).?);
    try std.testing.expect(try tree.paintDirty(root));
    builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(usize, 1), builder.count);
    try std.testing.expect(!(try tree.paintDirty(root)));
}

test "box geometry updates invalidate ancestors and refresh size and hit bounds" {
    const Case = struct { box: types.Box, size: SizeF };
    for ([_]Case{
        .{ .box = .{ .min_width = 73 }, .size = .{ .width = 73, .height = 11 } },
        .{ .box = .{ .min_height = 29 }, .size = .{ .width = 13, .height = 29 } },
        .{ .box = .{ .fill_width = true }, .size = .{ .width = 101, .height = 11 } },
        .{ .box = .{ .fill_height = true }, .size = .{ .width = 13, .height = 83 } },
    }) |case| {
        var tree: Tree = undefined;
        try tree.init(std.testing.allocator, 3);
        defer tree.deinit();
        const root = try tree.create(.{ .stack = .{} });
        const box = try tree.create(.{ .box = .{} });
        const leaf = try tree.create(.{ .box = .{ .width = 13, .height = 11 } });
        try tree.appendChild(root, box, .none);
        try tree.appendChild(box, leaf, .none);
        const bounds: Constraints = .{ .max_width = 101, .max_height = 83 };
        try std.testing.expectEqual(SizeF{ .width = 13, .height = 11 }, try tree.layout(root, bounds));
        const point: PointF = .{ .x = case.size.width - 0.5, .y = case.size.height - 0.5 };
        try std.testing.expectEqual(@as(?NodeHandle, null), try tree.hitTest(root, point));
        try tree.update(box, .{ .box = case.box });
        try std.testing.expect(try tree.layoutDirty(root));
        try std.testing.expectEqual(case.size, try tree.layout(root, bounds));
        try std.testing.expectEqual(case.size, try tree.nodeSize(box));
        // Unaligned boxes pass minimum constraints to their child as well.
        try std.testing.expectEqual(case.size, try tree.nodeSize(leaf));
        try std.testing.expectEqual(leaf, (try tree.hitTest(root, point)).?);
        try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(root));
    }
}

test "stack height constraint updates relayout retained children in both directions" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const child = try tree.create(.{ .box = .{ .width = 13, .height = 140 } });
    try tree.appendChild(root, child, .none);
    const bounds: Constraints = .{ .max_width = 101, .max_height = 83 };
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(@as(f32, 83), (try tree.nodeSize(child)).height);
    try tree.update(root, .{ .stack = .{ .unbounded_height = true } });
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(@as(f32, 140), (try tree.nodeSize(child)).height);
    try tree.update(root, .{ .stack = .{} });
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(@as(f32, 83), (try tree.nodeSize(child)).height);
    try std.testing.expectEqual(@as(usize, 3), try tree.layoutCount(child));
}

test "flex layout is bounded, cached, and separates paint invalidation" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .flex = .{ .gap = 5, .cross_axis_alignment = .stretch } });
    const fixed = try tree.create(.{ .box = .{
        .width = 20,
        .background = Color.rgba(10, 20, 30, 255),
    } });
    const expanded = try tree.create(.{ .box = .{ .background = Color.rgba(40, 50, 60, 255) } });
    try tree.appendChild(root, fixed, .none);
    try tree.appendChild(root, expanded, .{ .flex = .{ .factor = 1 } });

    try std.testing.expectEqual(
        SizeF{ .width = 100, .height = 20 },
        try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 20 })),
    );
    try std.testing.expectEqual(SizeF{ .width = 20, .height = 20 }, try tree.nodeSize(fixed));
    try std.testing.expectEqual(SizeF{ .width = 75, .height = 20 }, try tree.nodeSize(expanded));
    try std.testing.expectEqual(PointF{ .x = 25, .y = 0 }, try tree.nodeOffset(expanded));

    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 20 }));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(root));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(expanded));
    try std.testing.expectEqual(
        SizeF{ .width = 120, .height = 30 },
        try tree.layout(root, Constraints.tight(.{ .width = 120, .height = 30 })),
    );
    try std.testing.expectEqual(SizeF{ .width = 20, .height = 30 }, try tree.nodeSize(fixed));
    try std.testing.expectEqual(SizeF{ .width = 95, .height = 30 }, try tree.nodeSize(expanded));
    try tree.update(expanded, .{ .box = .{ .background = Color.rgba(70, 80, 90, 255) } });
    try std.testing.expect(!(try tree.layoutDirty(root)));
    try std.testing.expect(try tree.paintDirty(root));
    _ = try tree.layout(root, Constraints.tight(.{ .width = 120, .height = 30 }));
    try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(root));
}

test "unbounded cross-axis stretch resolves intrinsic siblings and caches the result" {
    for ([_]types.Axis{ .vertical, .horizontal }) |axis| {
        var tree: Tree = undefined;
        try tree.init(std.testing.allocator, 3);
        defer tree.deinit();
        const vertical = axis == .vertical;
        const root = try tree.create(.{ .flex = .{
            .axis = axis,
            .main_axis_size = .min,
            .cross_axis_alignment = .stretch,
            .gap = 3,
        } });
        const label = try tree.create(.{ .box = .{
            .width = if (vertical) 73 else 17,
            .height = if (vertical) 17 else 73,
        } });
        const line = try tree.create(.{ .box = .{
            .width = if (vertical) null else 2,
            .height = if (vertical) 2 else null,
            .fill_width = vertical,
            .fill_height = !vertical,
        } });
        try tree.appendChild(root, label, .none);
        try tree.appendChild(root, line, .none);
        const constraints: Constraints = if (vertical)
            .{ .min_width = 37, .max_height = 100 }
        else
            .{ .max_width = 100, .min_height = 37 };
        for ([_]f32{ 73, 21 }) |extent| {
            try tree.update(label, .{ .box = .{
                .width = if (vertical) extent else 17,
                .height = if (vertical) 17 else extent,
            } });
            const cross = @max(extent, 37);
            try std.testing.expectEqual(SizeF{
                .width = if (vertical) cross else 22,
                .height = if (vertical) 22 else cross,
            }, try tree.layout(root, constraints));
            try std.testing.expectEqual(SizeF{
                .width = if (vertical) cross else 2,
                .height = if (vertical) 2 else cross,
            }, try tree.nodeSize(line));
            try std.testing.expectEqual(PointF{
                .x = if (vertical) 0 else 20,
                .y = if (vertical) 20 else 0,
            }, try tree.nodeOffset(line));
            const count = try tree.layoutCount(line);
            _ = try tree.layout(root, constraints);
            try std.testing.expectEqual(count, try tree.layoutCount(line));
        }
    }
}

test "unbounded cross-axis start does not imply intrinsic stretch" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .flex = .{ .axis = .vertical, .main_axis_size = .min } });
    const label = try tree.create(.{ .box = .{ .width = 73, .height = 17 } });
    const line = try tree.create(.{ .box = .{ .fill_width = true, .height = 2 } });
    try tree.appendChild(root, label, .none);
    try tree.appendChild(root, line, .none);
    try std.testing.expectEqual(SizeF{ .width = 73, .height = 19 }, try tree.layout(root, .{}));
    try std.testing.expectEqual(SizeF{ .width = 0, .height = 2 }, try tree.nodeSize(line));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(label));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(line));
}

test "intrinsic cross-axis stretch retains main-axis flex allocation" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .flex = .{ .cross_axis_alignment = .stretch, .gap = 3 } });
    const fixed = try tree.create(.{ .box = .{ .width = 17, .height = 37 } });
    const expanded = try tree.create(.{ .box = .{ .fill_height = true } });
    try tree.appendChild(root, fixed, .none);
    try tree.appendChild(root, expanded, .{ .flex = .{ .factor = 1 } });
    try std.testing.expectEqual(SizeF{ .width = 101, .height = 37 }, try tree.layout(root, .{ .max_width = 101 }));
    try std.testing.expectEqual(SizeF{ .width = 81, .height = 37 }, try tree.nodeSize(expanded));
    try std.testing.expectEqual(PointF{ .x = 20, .y = 0 }, try tree.nodeOffset(expanded));
}

test "stack paints in order and hit tests front to back" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{ .clip = true } });
    const back = try tree.create(.{ .box = .{
        .width = 50,
        .height = 50,
        .background = Color.rgba(1, 2, 3, 255),
    } });
    const front = try tree.create(.{ .box = .{
        .width = 20,
        .height = 20,
        .background = Color.rgba(4, 5, 6, 255),
    } });
    try tree.appendChild(root, back, .none);
    try tree.appendChild(root, front, .{ .stack = .{ .x = 10, .y = 10 } });
    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));

    try std.testing.expectEqual(front, (try tree.hitTest(root, .{ .x = 15, .y = 15 })).?);
    try std.testing.expectEqual(back, (try tree.hitTest(root, .{ .x = 5, .y = 5 })).?);
    try std.testing.expectEqual(root, (try tree.hitTest(root, .{ .x = 90, .y = 70 })).?);
    try std.testing.expect((try tree.hitTest(root, .{ .x = 100, .y = 40 })) == null);

    var commands: [4]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    const list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), list.commands.len);
    try std.testing.expectEqual(@as(i32, 0), list.commands[1].solid_rectangle.bounds.x);
    try std.testing.expectEqual(@as(i32, 10), list.commands[2].solid_rectangle.bounds.x);
    try std.testing.expect(!(try tree.paintDirty(root)));
    try list.validate();
}

test "flex children reject an unbounded main axis" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .flex = .{ .axis = .vertical } });
    const child = try tree.create(.{ .box = .{} });
    try tree.appendChild(root, child, .{ .flex = .{ .factor = 1 } });
    try std.testing.expectError(error.FlexInUnboundedAxis, tree.layout(root, .{}));
}

test "box padding participates in constraints and child changes invalidate ancestors" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .box = .{ .padding = .all(4) } });
    const child = try tree.create(.{ .box = .{ .width = 20, .height = 10 } });
    try tree.appendChild(root, child, .none);
    try std.testing.expectEqual(
        SizeF{ .width = 28, .height = 18 },
        try tree.layout(root, .{ .max_width = 100, .max_height = 100 }),
    );
    try std.testing.expectEqual(PointF{ .x = 4, .y = 4 }, try tree.nodeOffset(child));

    try tree.update(child, .{ .box = .{ .width = 30, .height = 10 } });
    try std.testing.expect(try tree.layoutDirty(root));
    try std.testing.expectEqual(
        SizeF{ .width = 38, .height = 18 },
        try tree.layout(root, .{ .max_width = 100, .max_height = 100 }),
    );
    try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(root));
}

test "box border participates in layout and lowers decoration" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .box = .{
        .padding = .all(2),
        .background = Color.rgba(1, 2, 3, 255),
        .border_color = Color.rgba(4, 5, 6, 255),
        .border_width = 1,
        .corner_radius = 4,
    } });
    const child = try tree.create(.{ .box = .{ .width = 10, .height = 5 } });
    try tree.appendChild(root, child, .none);
    try std.testing.expectEqual(
        SizeF{ .width = 16, .height = 11 },
        try tree.layout(root, .{ .max_width = 100, .max_height = 100 }),
    );
    try std.testing.expectEqual(PointF{ .x = 3, .y = 3 }, try tree.nodeOffset(child));

    var commands: [1]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 2);
    try tree.buildScene(root, &builder);
    const decoration = builder.displayList().commands[0].decorated_rectangle;
    try std.testing.expectEqual(@as(u32, 2), decoration.border_width);
    try std.testing.expectEqual(@as(u32, 8), decoration.corner_radius);
}

test "box centers an intrinsic child inside its padded content" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .box = .{
        .width = 100,
        .height = 40,
        .padding = .all(4),
        .alignment = .center,
    } });
    const child = try tree.create(.{ .box = .{ .width = 20, .height = 10 } });
    try tree.appendChild(root, child, .none);

    try std.testing.expectEqual(
        SizeF{ .width = 100, .height = 40 },
        try tree.layout(root, .{ .max_width = 200, .max_height = 200 }),
    );
    try std.testing.expectEqual(SizeF{ .width = 20, .height = 10 }, try tree.nodeSize(child));
    try std.testing.expectEqual(PointF{ .x = 40, .y = 15 }, try tree.nodeOffset(child));

    try tree.update(root, .{ .box = .{
        .width = 100,
        .height = 40,
        .padding = .all(4),
        .alignment = .{ .horizontal = .maximum, .vertical = .maximum },
    } });
    try std.testing.expect(try tree.layoutDirty(root));
    _ = try tree.layout(root, .{ .max_width = 200, .max_height = 200 });
    try std.testing.expectEqual(PointF{ .x = 76, .y = 26 }, try tree.nodeOffset(child));
}

test "box minimum dimensions yield to tighter parent constraints" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    defer tree.deinit();
    const box = try tree.create(.{ .box = .{ .min_width = 80, .min_height = 30 } });

    try std.testing.expectEqual(
        SizeF{ .width = 80, .height = 30 },
        try tree.layout(box, .{ .max_width = 100, .max_height = 100 }),
    );
    try std.testing.expectEqual(
        SizeF{ .width = 40, .height = 20 },
        try tree.layout(box, .{ .max_width = 40, .max_height = 20 }),
    );
}

test "box fill dimensions use bounded parent maxima" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    defer tree.deinit();
    const box = try tree.create(.{ .box = .{ .fill_width = true, .fill_height = true } });

    try std.testing.expectEqual(
        SizeF{ .width = 100, .height = 60 },
        try tree.layout(box, .{ .max_width = 100, .max_height = 60 }),
    );
}

test "text objects cache width-specific mixed-script paragraphs across unchanged layout" {
    const scene = @import("../../scene/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const latin = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const source = try sources.acquire(.{
        .utf8 = "Save حفظ now and continue",
        .language = "und",
        .logical_size = 18,
        .candidates = &.{ latin, arabic },
        .configuration_revision = 1,
    });
    try fonts.release(latin);
    try fonts.release(arabic);

    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    tree.attachTextCaches(&sources, &paragraphs);
    defer tree.deinit();
    const paragraph = try tree.create(.{ .text = .{
        .source = source,
        .color = Color.rgba(20, 40, 80, 255),
    } });
    try sources.release(source);

    const wide_size = try tree.layout(paragraph, .{ .max_width = 180, .max_height = 200 });
    try std.testing.expect(wide_size.width < 180);
    var commands: [3]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(paragraph, &builder);
    const wide_layout = builder.displayList().commands[1].paragraph.layout;
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(paragraph));
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());

    _ = try tree.layout(paragraph, .{ .max_width = 180, .max_height = 200 });
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(paragraph));
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());

    // The retained layout was fitted to content width. Reacquiring at the
    // original maximum would allocate a temporary paragraph before fitting.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    paragraphs.allocator = failing.allocator();
    const clipped_size = try tree.layout(paragraph, .{ .max_width = 180, .max_height = 7 });
    try std.testing.expectEqual(SizeF{ .width = wide_size.width, .height = 7 }, clipped_size);
    const tall_size = try tree.layout(paragraph, .{ .max_width = 180, .min_height = 150, .max_height = 200 });
    try std.testing.expectEqual(SizeF{ .width = wide_size.width, .height = 150 }, tall_size);
    try std.testing.expectEqual(wide_size, try tree.layout(paragraph, .{ .max_width = 180, .max_height = 200 }));
    try std.testing.expectEqual(wide_layout, (try tree.slot(paragraph)).paragraph_layout.?);
    try std.testing.expect(!failing.has_induced_failure);
    paragraphs.allocator = std.testing.allocator;

    const narrow_size = try tree.layout(paragraph, .{ .max_width = 70, .max_height = 200 });
    try std.testing.expect(narrow_size.height > wide_size.height);
    try std.testing.expectEqual(@as(usize, 5), try tree.layoutCount(paragraph));
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());
    builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(paragraph, &builder);
    const narrow_layout = builder.displayList().commands[1].paragraph.layout;
    try std.testing.expect(!sameParagraph(wide_layout, narrow_layout));

    const tight_size = try tree.layout(paragraph, .{
        .min_width = 180,
        .max_width = 180,
        .max_height = 200,
    });
    try std.testing.expectEqual(@as(f32, 180), tight_size.width);
    try std.testing.expectEqual(@as(usize, 6), try tree.layoutCount(paragraph));
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());

    // A minimum-width change still needs content fitting, even at the same max.
    try std.testing.expectEqual(wide_size, try tree.layout(paragraph, .{ .max_width = 180, .max_height = 200 }));

    // Same width must not reuse a layout after style changes mark it dirty.
    const before_style = (try tree.slot(paragraph)).paragraph_layout.?;
    var restyled = try tree.objectAt(paragraph);
    restyled.text.max_lines = 1;
    try tree.update(paragraph, restyled);
    _ = try tree.layout(paragraph, .{ .max_width = 180, .max_height = 200 });
    const after_style = (try tree.slot(paragraph)).paragraph_layout.?;
    try std.testing.expect(!sameParagraph(before_style, after_style));
    try std.testing.expectEqual(@as(usize, 1), (try paragraphs.get(after_style)).positioned.lines.len);

    try tree.destroy(paragraph);
    try std.testing.expectEqual(@as(usize, 0), sources.count());
    try std.testing.expectEqual(@as(usize, 0), paragraphs.count());
}

test "multiline viewport wraps reveals trailing caret and preserves manual scroll during blink" {
    const scene = @import("../../scene/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    tree.attachTextCaches(&sources, &paragraphs);
    defer tree.deinit();
    const value = "First line wraps over several visual rows\n\nLast\n";
    const source = try sources.acquire(.{ .utf8 = value, .language = "und", .logical_size = 18, .candidates = &.{font}, .configuration_revision = 1 });
    defer sources.release(source) catch unreachable;
    var object: types.Object = .{ .text_input = .{
        .source = source,
        .multiline = true,
        .color = Color.rgba(0, 0, 0, 255),
        .caret_color = Color.rgba(0, 0, 0, 255),
        .selection_color = Color.rgba(80, 120, 240, 120),
        .caret_offset = value.len,
        .selection_start = value.len,
        .selection_end = value.len,
        .reveal_caret = true,
        .show_caret = true,
    } };
    const input = try tree.create(object);
    _ = try tree.layout(input, .{ .max_width = 150, .max_height = 60 });
    const paragraph = try paragraphs.get((try tree.slot(input)).paragraph_layout.?);
    try std.testing.expect(paragraph.positioned.lines.len > 4);
    const narrow_height = paragraph.size.height;
    const beam_layout = (try tree.slot(input)).paragraph_layout.?;
    for ([_]types.CaretShape{ .block, .underline, .beam }) |shape| {
        object.text_input.caret_shape = shape;
        try tree.update(input, object);
        _ = try tree.layout(input, .{ .max_width = 150, .max_height = 60 });
        // Shape changes must reuse precisely the same shaped/wrapped paragraph.
        try std.testing.expectEqual(beam_layout, (try tree.slot(input)).paragraph_layout.?);
        const shaped_caret = try tree.textCaretRectangle(input);
        try std.testing.expect(shaped_caret.width > 0);
        try std.testing.expect(shaped_caret.x >= 0 and shaped_caret.x + shaped_caret.width <= 150.001);
        try std.testing.expect(shaped_caret.y >= 0 and shaped_caret.y + shaped_caret.height <= 60.001);
        var shape_commands: [8]scene.Command = undefined;
        var shape_builder = try scene_builder.Builder.init(&shape_commands, 1);
        try tree.buildScene(input, &shape_builder);
        const painted_shape = shape_builder.displayList().commands;
        try std.testing.expect(painted_shape[if (shape == .block) @as(usize, 1) else 2] == .solid_rectangle);
        try std.testing.expect(painted_shape[if (shape == .block) @as(usize, 2) else 1] == .paragraph);
    }
    const caret = try tree.textCaretRectangle(input);
    try std.testing.expect(caret.y >= 0 and caret.y + caret.height <= 60.001);
    try std.testing.expectEqual(value.len, (try tree.hitTestText(input, .{ .x = caret.x, .y = caret.y + caret.height / 2 })).caret.byte_offset);
    try std.testing.expect(try tree.scrollTextInput(input, .vertical, -10000));
    try std.testing.expectEqual(@as(f32, 0), try tree.textScrollOffset(input, .vertical));
    object.text_input.show_caret = false;
    try tree.update(input, object);
    object.text_input.show_caret = true;
    try tree.update(input, object);
    try std.testing.expectEqual(@as(f32, 0), try tree.textScrollOffset(input, .vertical));
    // Moving selection after scrolling must reveal again; paint uses the same translation.
    object.text_input.selection_start = value.len - 3;
    object.text_input.show_caret = false;
    try tree.update(input, object);
    try std.testing.expect((try tree.textScrollOffset(input, .vertical)) > 0);
    var commands: [40]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(input, &builder);
    for (builder.displayList().commands) |command| if (command == .paragraph) {
        try std.testing.expectEqual(-(try tree.textScrollOffset(input, .vertical)), command.paragraph.origin.y);
    };
    _ = try tree.layout(input, .{ .max_width = 600, .max_height = 200 });
    try std.testing.expect((try paragraphs.get((try tree.slot(input)).paragraph_layout.?)).size.height < narrow_height);
    try std.testing.expectEqual(@as(f32, 0), try tree.textScrollOffset(input, .vertical));
}

test "wrapped editor caret positions never introduce horizontal scroll" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    tree.attachTextCaches(&sources, &paragraphs);
    defer tree.deinit();
    const source = try sources.acquire(.{ .utf8 = "d" ** 101, .language = "und", .logical_size = 23, .candidates = &.{font}, .configuration_revision = 1 });
    defer sources.release(source) catch unreachable;
    var object: types.Object = .{ .text_input = .{
        .source = source,
        .multiline = true,
        .color = Color.rgba(0, 0, 0, 255),
        .caret_color = Color.rgba(0, 0, 0, 255),
        .selection_color = Color.rgba(80, 120, 240, 120),
        .selection_start = 0,
        .selection_end = 0,
        .caret_offset = 0,
        .show_caret = true,
        .reveal_caret = true,
    } };
    const input = try tree.create(object);
    for ([_]f32{ 150, 91.25 }) |width| {
        _ = try tree.layout(input, .{ .max_width = width, .max_height = 80 });
        const layout = (try tree.slot(input)).paragraph_layout.?;
        const positioned = &(try paragraphs.get(layout)).positioned;
        try std.testing.expect(positioned.lines.len > 1);
        for ([_]types.CaretShape{ .beam, .block, .underline }) |shape| {
            object.text_input.caret_shape = shape;
            for (positioned.carets) |stop| {
                object.text_input.caret_offset = stop.byte_offset;
                object.text_input.caret_affinity = stop.affinity;
                try tree.update(input, object);
                _ = try tree.layout(input, .{ .max_width = width, .max_height = 80 });
                try std.testing.expectEqual(layout, (try tree.slot(input)).paragraph_layout.?);
                try std.testing.expectApproxEqAbs(@as(f32, 0), try tree.textScrollOffset(input, .horizontal), 0.001);
                const caret = try tree.textCaretRectangle(input);
                try std.testing.expect(caret.x >= 0 and caret.x + caret.width <= width + 0.001);
            }
        }
    }
}

test "text input scrolls one line and shares viewport coordinates with caret hit testing and paint" {
    const scene = @import("../../scene/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const latin = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    defer fonts.release(latin) catch unreachable;
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    defer fonts.release(arabic) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    tree.attachTextCaches(&sources, &paragraphs);
    defer tree.deinit();

    for ([_][]const u8{ "A long editable value with several words", "حفظ اللغة العربية حفظ اللغة العربية" }, 0..) |value, index| {
        const rtl = index == 1;
        const source = try sources.acquire(.{
            .utf8 = value,
            .language = "und",
            .logical_size = 18,
            .candidates = &.{ latin, arabic },
            .configuration_revision = 1,
        });
        var object: types.Object = .{ .text_input = .{
            .source = source,
            .color = Color.rgba(10, 20, 30, 255),
            .selection_color = Color.rgba(80, 120, 240, 120),
            .caret_color = Color.rgba(20, 40, 80, 255),
            .selection_start = value.len,
            .selection_end = value.len,
            .caret_offset = value.len,
            .show_caret = true,
            .reveal_caret = true,
        } };
        const input = try tree.create(object);
        try sources.release(source);
        _ = try tree.layout(input, .{ .max_width = 91, .max_height = 100 });
        const layout = (try tree.slot(input)).paragraph_layout.?;
        try std.testing.expectEqual(@as(usize, 1), (try paragraphs.get(layout)).positioned.lines.len);
        var caret = try tree.textCaretRectangle(input);
        try std.testing.expectApproxEqAbs(@as(f32, if (rtl) 0 else 90), caret.x, 0.001);
        try std.testing.expectEqual(value.len, (try tree.hitTestText(input, .{ .x = caret.x, .y = 5 })).caret.byte_offset);

        // A selection hides the caret, but its moving extent must still reveal.
        object.text_input.selection_start = 0;
        object.text_input.caret_offset = 0;
        object.text_input.show_caret = false;
        try tree.update(input, object);
        try std.testing.expect(!(try tree.layoutDirty(input)));
        try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(input));
        caret = try tree.textCaretRectangle(input);
        try std.testing.expectApproxEqAbs(@as(f32, if (rtl) 90 else 0), caret.x, 0.001);
        try std.testing.expectEqual(@as(usize, 0), (try tree.hitTestText(input, .{ .x = caret.x, .y = 5 })).caret.byte_offset);

        // Dragging outside either edge reaches offscreen text and reveals it.
        const hit = try tree.hitTestText(input, .{ .x = if (rtl) -1000 else 1000, .y = 5 });
        try std.testing.expectEqual(value.len, hit.caret.byte_offset);
        object.text_input.caret_offset = hit.caret.byte_offset;
        try tree.update(input, object);
        caret = try tree.textCaretRectangle(input);
        try std.testing.expectApproxEqAbs(@as(f32, if (rtl) 0 else 90), caret.x, 0.001);

        // Resizing reuses the unwrapped paragraph and clamps the viewport.
        _ = try tree.layout(input, .{ .max_width = 57, .max_height = 100 });
        try std.testing.expectEqual(layout, (try tree.slot(input)).paragraph_layout.?);
        caret = try tree.textCaretRectangle(input);
        try std.testing.expectApproxEqAbs(@as(f32, if (rtl) 0 else 56), caret.x, 0.001);

        // Preedit underlines and selection rectangles use the same translation.
        object.text_input.preedit = .{ .start = 0, .end = value.len };
        object.text_input.preedit_color = object.text_input.caret_color;
        try tree.update(input, object);
        var commands: [16]scene.Command = undefined;
        var builder = try scene_builder.Builder.init(&commands, 1);
        try tree.buildScene(input, &builder);
        const painted = builder.displayList().commands;
        try std.testing.expectEqual(@as(u32, 57), painted[0].push_clip_rect.width);
        try std.testing.expect(painted[1] == .solid_rectangle);
        try std.testing.expect(painted[2] == .paragraph);
        try std.testing.expect(painted[3] == .solid_rectangle);
        try std.testing.expectEqual(painted[1].solid_rectangle.bounds.x, painted[3].solid_rectangle.bounds.x);

        // Once the whole value fits, no stale negative scroll survives.
        _ = try tree.layout(input, .{ .max_width = 900, .max_height = 100 });
        try std.testing.expect((try tree.slot(input)).text_offset_x >= 0);
        caret = try tree.textCaretRectangle(input);
        try std.testing.expect(caret.x >= 0 and caret.x + caret.width <= 900);
        // Bounded inputs fill their width; unbounded inputs include the caret
        // in their intrinsic width instead.
        const intrinsic = try tree.layout(input, .{ .max_height = 100 });
        object.text_input.caret_width = 5;
        try tree.update(input, object);
        try std.testing.expect(try tree.layoutDirty(input));
        _ = try tree.layout(input, .{ .max_height = 100 });
        try std.testing.expectApproxEqAbs(intrinsic.width + 4, (try tree.nodeSize(input)).width, 0.001);
        try std.testing.expectEqual(intrinsic.height, (try tree.nodeSize(input)).height);
        try std.testing.expectEqual(@as(f32, 5), (try tree.textCaretRectangle(input)).width);
        for ([_]types.CaretShape{ .block, .underline }) |shape| {
            object.text_input.caret_shape = shape;
            object.text_input.caret_offset = 0;
            try tree.update(input, object);
            const start_size = try tree.layout(input, .{ .max_height = 100 });
            object.text_input.caret_offset = value.len;
            try tree.update(input, object);
            try std.testing.expectEqual(start_size, try tree.layout(input, .{ .max_height = 100 }));
            _ = try tree.layout(input, .{ .max_width = 57, .max_height = 100 });
            caret = try tree.textCaretRectangle(input);
            try std.testing.expect(caret.x >= 0 and caret.x + caret.width <= 57.001);
            if (rtl) {
                try std.testing.expectApproxEqAbs(@as(f32, 0), caret.x, 0.001);
                try std.testing.expectEqual(@as(f32, 0), try tree.textScrollDelta(input, .horizontal, -100));
            }
        }
        try tree.destroy(input);
    }
}

test "text input paints selection, text, and caret from interactive paragraph geometry" {
    const scene = @import("../../scene/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const latin = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const source = try sources.acquire(.{
        .utf8 = "office حفظ",
        .language = "und",
        .logical_size = 18,
        .candidates = &.{ latin, arabic },
        .configuration_revision = 1,
    });
    try fonts.release(latin);
    try fonts.release(arabic);

    const foreground = Color.rgba(10, 20, 30, 255);
    const selection = Color.rgba(80, 120, 240, 120);
    const caret = Color.rgba(20, 40, 80, 255);
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    tree.attachTextCaches(&sources, &paragraphs);
    defer tree.deinit();
    const input = try tree.create(.{ .text_input = .{
        .source = source,
        .color = foreground,
        .selection_color = selection,
        .caret_color = caret,
        .selection_start = 1,
        .selection_end = 4,
        .caret_offset = 4,
    } });
    try sources.release(source);
    _ = try tree.layout(input, .{ .max_width = 200, .max_height = 100 });
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());

    var commands: [16]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(input, &builder);
    const selected = builder.displayList();
    try std.testing.expect(selected.commands.len >= 4);
    try std.testing.expect(selected.commands[0] == .push_clip_rect);
    try std.testing.expect(selected.commands[1] == .solid_rectangle);
    try std.testing.expect(selected.commands[2] == .paragraph);
    try std.testing.expect(selected.commands[selected.commands.len - 1] == .pop_clip);

    try tree.update(input, .{ .text_input = .{
        .source = source,
        .color = foreground,
        .selection_color = selection,
        .caret_color = caret,
        .selection_start = 4,
        .selection_end = 4,
        .caret_offset = 4,
        .show_caret = true,
    } });
    try std.testing.expect(!(try tree.layoutDirty(input)));
    try std.testing.expect(try tree.paintDirty(input));
    builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(input, &builder);
    const collapsed = builder.displayList();
    try std.testing.expectEqual(@as(usize, 4), collapsed.commands.len);
    try std.testing.expect(collapsed.commands[1] == .paragraph);
    try std.testing.expect(collapsed.commands[2] == .solid_rectangle);
    const hit = try tree.hitTestText(input, .{
        .x = @floatFromInt(collapsed.commands[2].solid_rectangle.bounds.x),
        .y = 1,
    });
    try std.testing.expect(hit.caret.byte_offset <= "office حفظ".len);

    // Proportional glyph positions must not change the beam's device width.
    for (0..7) |offset| {
        var object = try tree.objectAt(input);
        object.text_input.selection_start = offset;
        object.text_input.selection_end = offset;
        object.text_input.caret_offset = offset;
        try tree.update(input, object);
        builder = try scene_builder.Builder.init(&commands, 1.5);
        try tree.buildScene(input, &builder);
        try std.testing.expectEqual(@as(u32, 2), builder.displayList().commands[2].solid_rectangle.bounds.width);
    }

    try tree.update(input, .{ .text_input = .{
        .source = source,
        .color = foreground,
        .selection_color = selection,
        .caret_color = caret,
        .selection_start = 6,
        .selection_end = 6,
        .caret_offset = 6,
        .show_caret = true,
        .preedit = .{ .start = 0, .end = 6 },
        .preedit_color = caret,
        .preedit_width = 2,
    } });
    builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(input, &builder);
    const composing = builder.displayList();
    try std.testing.expectEqual(@as(usize, 5), composing.commands.len);
    try std.testing.expect(composing.commands[1] == .paragraph);
    try std.testing.expect(composing.commands[2] == .solid_rectangle);
    try std.testing.expectEqual(@as(u32, 2), composing.commands[2].solid_rectangle.bounds.height);
    try std.testing.expect(composing.commands[3] == .solid_rectangle);

    try tree.destroy(input);
    try std.testing.expectEqual(@as(usize, 0), sources.count());
    try std.testing.expectEqual(@as(usize, 0), paragraphs.count());
}

test "text input placeholder paints separately from caret and preedit geometry" {
    const scene = @import("../../scene/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const empty = try sources.acquire(.{
        .utf8 = "",
        .language = "und",
        .logical_size = 18,
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    const hint = try sources.acquire(.{
        .utf8 = "Find an application by name",
        .language = "und",
        .logical_size = 18,
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    tree.attachTextCaches(&sources, &paragraphs);
    defer tree.deinit();
    var object: types.Object = .{ .text_input = .{
        .source = empty,
        .color = Color.rgba(1, 2, 3, 255),
        .placeholder = hint,
        .placeholder_color = Color.rgba(100, 110, 120, 255),
        .caret_color = Color.rgba(20, 40, 80, 255),
        .selection_color = Color.rgba(80, 120, 240, 120),
        .selection_start = 0,
        .selection_end = 0,
        .caret_offset = 0,
        .show_caret = true,
    } };
    const input = try tree.create(object);
    try sources.release(empty);
    try sources.release(hint);
    const constraints: Constraints = .{ .max_width = 100, .max_height = 40 };
    const size = try tree.layout(input, constraints);
    try std.testing.expect(size.width > 0 and size.width <= 100);
    const caret = try tree.textCaretRectangle(input);
    // Clicking the far end of a long hint must still address empty value offset 0.
    try std.testing.expectEqual(@as(usize, 0), (try tree.hitTestText(input, .{ .x = 90, .y = 5 })).caret.byte_offset);
    var commands: [16]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(input, &builder);
    try std.testing.expectEqual(@as(usize, 4), builder.displayList().commands.len);
    try std.testing.expectEqual(object.text_input.placeholder_color, builder.displayList().commands[1].paragraph.color);
    try std.testing.expectEqual(@as(i32, 0), builder.displayList().commands[2].solid_rectangle.bounds.x);

    // Even an empty active preedit hides the hint without changing the source.
    object.text_input.preedit = .{ .start = 0, .end = 0 };
    object.text_input.preedit_color = object.text_input.caret_color;
    try tree.update(input, object);
    try std.testing.expect(try tree.layoutDirty(input));
    _ = try tree.layout(input, constraints);
    try std.testing.expect((try tree.slot(input)).placeholder_layout == null);
    try std.testing.expectEqual(caret, try tree.textCaretRectangle(input));
    object.text_input.preedit = null;
    object.text_input.preedit_color = null;
    try tree.update(input, object);
    _ = try tree.layout(input, constraints);
    try std.testing.expect((try tree.slot(input)).placeholder_layout != null);

    // Real text suppresses the hint even if it exactly equals the hint text.
    object.text_input.source = hint;
    object.text_input.selection_end = "Find an application by name".len;
    object.text_input.caret_offset = object.text_input.selection_end;
    try tree.update(input, object);
    _ = try tree.layout(input, constraints);
    try std.testing.expect((try tree.slot(input)).placeholder_layout == null);
    builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(input, &builder);
    try std.testing.expect(builder.displayList().commands[1] == .solid_rectangle);
    try tree.destroy(input);
    try std.testing.expectEqual(@as(usize, 0), sources.count());
    try std.testing.expectEqual(@as(usize, 0), paragraphs.count());
}

test "render-object topology rejects cycles and stale generations" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const child = try tree.create(.{ .stack = .{} });
    try tree.appendChild(root, child, .none);
    try std.testing.expectError(error.RenderObjectCycle, tree.appendChild(child, root, .none));
    try tree.destroy(child);
    try std.testing.expectError(error.StaleRenderObject, tree.nodeSize(child));
    const replacement = try tree.create(.{ .box = .{} });
    try std.testing.expectEqual(child.slot, replacement.slot);
    try std.testing.expect(child.generation != replacement.generation);
}

test "box outlines stay paint-only and inset rings paint above the background" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    defer tree.deinit();
    const box = try tree.create(.{ .box = .{ .width = 40, .height = 20 } });
    _ = try tree.layout(box, Constraints.tight(.{ .width = 40, .height = 20 }));
    for ([_]bool{ false, true }) |inset| {
        try tree.update(box, .{ .box = .{
            .width = 40,
            .height = 20,
            .background = Color.rgba(255, 255, 255, 255),
            .corner_radius = 4,
            .outline_color = Color.rgba(20, 80, 220, 255),
            .outline_width = 2,
            .outline_gap = 2,
            .outline_inset = inset,
        } });
        try std.testing.expect(!(try tree.layoutDirty(box)));
        try std.testing.expect(try tree.paintDirty(box));
        var commands: [2]@import("../../scene/root.zig").Command = undefined;
        var builder = try scene_builder.Builder.init(&commands, 1);
        try tree.buildScene(box, &builder);
        try std.testing.expectEqual(@as(usize, 2), builder.count);
        try std.testing.expectEqual(Color.rgba(255, 255, 255, 255), commands[0].decorated_rectangle.background.?);
        const outline = commands[1].decorated_rectangle;
        try std.testing.expect(outline.background == null);
        try std.testing.expectEqual(@import("../../core/geometry.zig").RectI{
            .x = if (inset) 2 else -4,
            .y = if (inset) 2 else -4,
            .width = if (inset) 36 else 48,
            .height = if (inset) 16 else 28,
        }, outline.bounds);
        try std.testing.expectEqual(@as(u32, if (inset) 2 else 8), outline.corner_radius);
        try std.testing.expectEqual(@as(u32, 2), outline.border_width);
    }
}

test "paint transforms compose origins without layout and hit overflowing children through real clips" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{ .clip = true } });
    var outer: types.Box = .{ .width = 100, .height = 80, .opacity = 0.5, .transform = .{ .translation = .{ .x = 10, .y = 6 }, .scale = 1.5, .origin = .{ .x = 20, .y = 10 } } };
    const parent = try tree.create(.{ .box = outer });
    const stack = try tree.create(.{ .stack = .{} });
    var inner: types.Box = .{ .width = 40, .height = 30, .background = Color.rgba(255, 0, 0, 255), .transform = .{ .translation = .{ .x = 4, .y = -2 }, .scale = 0.5, .origin = .{ .x = 10, .y = 6 } } };
    const child = try tree.create(.{ .box = inner });
    try tree.appendChild(root, parent, .{ .stack = .{ .x = 20, .y = 30 } });
    try tree.appendChild(parent, stack, .none);
    try tree.appendChild(stack, child, .{ .stack = .{ .x = 20, .y = 15 } });
    _ = try tree.layout(root, Constraints.tight(.{ .width = 240, .height = 160 }));
    try std.testing.expectEqual(RectF{ .x = 63.5, .y = 55, .width = 30, .height = 22.5 }, try tree.paintBounds(child));
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 64, .y = 56 })).?);
    try std.testing.expect(!same(child, (try tree.hitTest(root, .{ .x = 41, .y = 46 })).?));
    var storage: [8]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&storage, 2);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(f32, 2), builder.transform.scale);
    try std.testing.expectEqual(PointF{}, builder.transform.translation);
    try std.testing.expectEqual(@as(usize, 5), builder.count);
    try std.testing.expectEqual(@import("../../core/geometry.zig").RectI{ .x = 127, .y = 110, .width = 60, .height = 45 }, storage[2].solid_rectangle.bounds);
    var pixels: [480 * 320 * 4]u8 = @splat(255);
    try @import("../../renderer/software/root.zig").render(builder.displayList(), .{
        .pixels = &pixels,
        .width = 480,
        .height = 320,
        .stride = 480 * 4,
        .format = .rgba8_unorm,
        .allocator = std.testing.allocator,
    });
    try std.testing.expectEqualSlices(u8, &.{ 255, 188, 188, 255 }, pixels[(112 * 480 + 128) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, pixels[(92 * 480 + 82) * 4 ..][0..4]);
    inner.transform.translation.x = 80;
    try tree.update(child, .{ .box = inner });
    try std.testing.expect(!try tree.layoutDirty(root));
    try std.testing.expectEqual(PointF{ .x = 20, .y = 15 }, try tree.nodeOffset(child));
    try std.testing.expectEqual(SizeF{ .width = 40, .height = 30 }, try tree.nodeSize(child));
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 178, .y = 56 })).?);
    outer.clip = true;
    try tree.update(parent, .{ .box = outer });
    try std.testing.expectEqual(root, (try tree.hitTest(root, .{ .x = 178, .y = 56 })).?);
    builder = try scene_builder.Builder.init(&storage, 1);
    try tree.buildScene(root, &builder);
    for ([_]NodeHandle{ root, parent, stack, child }) |node|
        try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(node));
}

test "internal drag preview replays source geometry without ancestor clips" {
    const scene = @import("../../scene/root.zig");
    const RectI = @import("../../core/geometry.zig").RectI;
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const ancestor = try tree.create(.{ .box = .{
        .width = 90,
        .height = 70,
        .clip = true,
        .transform = .{ .translation = .{ .x = 11, .y = -3 }, .scale = 1.5, .origin = .{ .x = 7, .y = 13 } },
    } });
    const source = try tree.create(.{ .box = .{
        .width = 24,
        .height = 16,
        .clip = true,
        .corner_radius = 3,
        .background = Color.rgba(20, 40, 60, 255),
        .shadow = .{ .offset = .{ .x = 2, .y = -1 }, .color = Color.rgba(0, 0, 0, 255) },
        .transform = .{ .translation = .{ .x = -5, .y = 9 }, .scale = 0.5, .origin = .{ .x = 3, .y = 6 } },
    } });
    try tree.appendChild(root, ancestor, .{ .stack = .{ .x = 17, .y = 23 } });
    try tree.appendChild(ancestor, source, .none);
    _ = try tree.layout(root, Constraints.tight(.{ .width = 180, .height = 140 }));

    var storage: [4]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&storage, 2);
    try tree.buildPreview(source, &builder, .{ .x = 8, .y = -4 });
    try builder.displayList().validate();
    try std.testing.expectEqual(@as(f32, 2), builder.transform.scale);
    try std.testing.expectEqual(PointF{}, builder.transform.translation);
    try std.testing.expectEqual(@as(usize, 4), builder.count);
    try std.testing.expect(storage[0] == .shadow);
    try std.testing.expect(storage[1] == .decorated_rectangle);
    try std.testing.expect(storage[2] == .push_clip_rounded);
    try std.testing.expect(storage[3] == .pop_clip);
    // The only clip is the source's own clip. Its bounds include both unequal
    // transforms exactly once and retain the builder's output scale.
    const bounds = storage[1].decorated_rectangle.bounds;
    try std.testing.expectEqual(RectI{ .x = 55, .y = 55, .width = 135, .height = 105 }, bounds);
    try std.testing.expectEqual(bounds, storage[2].push_clip_rounded.bounds);

    var short: [3]scene.Command = undefined;
    var short_builder = try scene_builder.Builder.init(&short, 2);
    try std.testing.expectError(error.SceneCapacityExceeded, tree.buildPreview(source, &short_builder, .{}));
}

test "box opacity wraps own paint and children without layout or hit changes" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    var box: types.Box = .{ .opacity = 0.5, .clip = true, .corner_radius = 6, .background = Color.rgba(255, 255, 255, 255), .shadow = .{ .offset = .{ .x = 4, .y = 3 }, .color = Color.rgba(0, 0, 0, 255) } };
    const root = try tree.create(.{ .box = box });
    const child = try tree.create(.{ .box = .{ .background = Color.rgba(0, 0, 255, 255) } });
    try tree.appendChild(root, child, .none);
    _ = try tree.layout(root, Constraints.tight(.{ .width = 40, .height = 30 }));
    var storage: [12]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&storage, 1.5);
    try tree.buildScene(root, &builder);
    try builder.displayList().validate();
    try std.testing.expectEqual(@as(u16, 32768), storage[0].push_opacity);
    try std.testing.expect(storage[1] == .shadow);
    try std.testing.expect(storage[2] == .decorated_rectangle);
    try std.testing.expect(storage[3] == .push_clip_rounded);
    try std.testing.expect(storage[builder.count - 2] == .pop_clip);
    try std.testing.expect(storage[builder.count - 1] == .pop_opacity);
    const count = builder.count;
    box.opacity = 0;
    try tree.update(root, .{ .box = box });
    try std.testing.expect(!try tree.layoutDirty(root));
    try std.testing.expect(try tree.paintDirty(root));
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 20, .y = 15 })).?);
    builder = try scene_builder.Builder.init(&storage, 1.5);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(u16, 0), storage[0].push_opacity);
    try std.testing.expectEqual(count, builder.count);
    box.opacity = 1;
    try tree.update(root, .{ .box = box });
    builder = try scene_builder.Builder.init(&storage, 1.5);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(count - 2, builder.count);
    try std.testing.expect(storage[0] == .shadow);
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(root));
    for ([_]f32{ -0.01, 1.01, std.math.nan(f32), std.math.inf(f32) }) |invalid| {
        box.opacity = invalid;
        try std.testing.expectError(error.InvalidOpacity, tree.update(root, .{ .box = box }));
    }
}

test "rounded box clips children and hits without relayout and uses scaled decoration geometry" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const back = try tree.create(.{ .box = .{ .width = 40, .height = 30 } });
    var box: types.Box = .{ .width = 40, .height = 30, .clip = true, .corner_radius = 10 };
    const front = try tree.create(.{ .box = box });
    const child = try tree.create(.{ .box = .{ .background = Color.rgba(255, 0, 0, 255) } });
    try tree.appendChild(root, back, .{ .stack = .{} });
    try tree.appendChild(root, front, .{ .stack = .{} });
    try tree.appendChild(front, child, .none);
    _ = try tree.layout(root, Constraints.tight(.{ .width = 40, .height = 30 }));
    try std.testing.expectEqual(back, (try tree.hitTest(root, .{ .x = 1, .y = 1 })).?);
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 10, .y = 1 })).?);
    try std.testing.expectEqual(back, (try tree.hitTest(root, .{ .x = 39, .y = 29 })).?);
    var storage: [4]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&storage, 1.5);
    try tree.buildScene(root, &builder);
    try builder.displayList().validate();
    try std.testing.expectEqual(scene.RoundedClip{
        .bounds = .{ .x = 0, .y = 0, .width = 60, .height = 45 },
        .corner_radius = 15,
    }, storage[0].push_clip_rounded);
    box.corner_radius = 0;
    try tree.update(front, .{ .box = box });
    try std.testing.expect(!try tree.layoutDirty(root));
    try std.testing.expect(try tree.paintDirty(root));
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 1, .y = 1 })).?);
    builder = try scene_builder.Builder.init(&storage, 1.5);
    try tree.buildScene(root, &builder);
    try std.testing.expect(storage[0] == .push_clip_rect);
    box.corner_radius = 10;
    box.clip = false;
    try tree.update(front, .{ .box = box });
    try std.testing.expect(!try tree.layoutDirty(root));
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 1, .y = 1 })).?);
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(front));
}

test "box shadows are paint-only obey ancestor clips and never expand hit targets" {
    const scene = @import("../../scene/root.zig");
    const software = @import("../../renderer/software/root.zig");
    const RectI = @import("../../core/geometry.zig").RectI;
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    var parent_box: types.Box = .{ .width = 60, .height = 50, .padding = .all(10), .alignment = .{} };
    var child_box: types.Box = .{ .width = 30, .height = 20, .corner_radius = 4, .clip = true, .background = Color.rgba(255, 255, 255, 255) };
    const root = try tree.create(.{ .box = parent_box });
    const child = try tree.create(.{ .box = child_box });
    try tree.appendChild(root, child, .none);
    _ = try tree.layout(root, .{ .max_width = 90, .max_height = 60 });
    child_box.shadow = .{ .offset = .{ .x = 36, .y = -3 }, .spread = 2, .color = Color.rgba(20, 60, 140, 255) };
    try tree.update(child, .{ .box = child_box });
    try std.testing.expect(!(try tree.layoutDirty(root)));
    try std.testing.expect(try tree.paintDirty(root));
    try std.testing.expectEqual(SizeF{ .width = 30, .height = 20 }, try tree.nodeSize(child));
    try std.testing.expectEqual(child, (try tree.hitTest(root, .{ .x = 20, .y = 15 })).?);
    try std.testing.expectEqual(root, (try tree.hitTest(root, .{ .x = 55, .y = 15 })).?);
    try std.testing.expect((try tree.hitTest(root, .{ .x = 65, .y = 15 })) == null);
    var commands: [8]scene.Command = undefined;
    var pixels: [90 * 60 * 4]u8 = undefined;
    for ([_]bool{ false, true }) |ancestor_clip| {
        parent_box.clip = ancestor_clip;
        try tree.update(root, .{ .box = parent_box });
        var builder = try scene_builder.Builder.init(&commands, 1);
        try builder.clear(Color.rgba(255, 255, 255, 255));
        try tree.buildScene(root, &builder);
        const index: usize = if (ancestor_clip) 2 else 1;
        try std.testing.expectEqual(RectI{ .x = 10, .y = 10, .width = 30, .height = 20 }, commands[index].shadow.shape.box);
        try std.testing.expect(commands[index + 1] == .decorated_rectangle);
        // Own clip begins after the shadow and decoration; ancestor clip begins before them.
        try std.testing.expect(commands[index + 2] == .push_clip_rounded);
        try software.render(builder.displayList(), .{ .pixels = &pixels, .width = 90, .height = 60, .stride = 90 * 4, .format = .rgba8_unorm, .allocator = std.testing.allocator });
        try std.testing.expectEqualSlices(u8, &.{ 20, 60, 140, 255 }, pixels[(15 * 90 + 55) * 4 ..][0..4]);
        try std.testing.expectEqualSlices(u8, if (ancestor_clip) &.{ 255, 255, 255, 255 } else &.{ 20, 60, 140, 255 }, pixels[(15 * 90 + 65) * 4 ..][0..4]);
    }
    child_box.shadow = null;
    try tree.update(child, .{ .box = child_box });
    try std.testing.expect(!(try tree.layoutDirty(root)));
    try std.testing.expect(try tree.paintDirty(root));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(child));
    var builder = try scene_builder.Builder.init(&commands, 1);
    try builder.clear(Color.rgba(255, 255, 255, 255));
    try tree.buildScene(root, &builder);
    for (builder.displayList().commands) |command| try std.testing.expect(command != .shadow);
}

test "scroll lays out unbounded content and clips paint and hit testing" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const scroll = try tree.create(.{ .scroll = .{} });
    const content = try tree.create(.{ .box = .{
        .width = 40,
        .height = 120,
        .background = Color.rgba(20, 40, 80, 255),
    } });
    try tree.appendChild(scroll, content, .none);

    try std.testing.expectEqual(
        SizeF{ .width = 40, .height = 50 },
        try tree.layout(scroll, .{ .max_width = 100, .max_height = 50 }),
    );
    try std.testing.expectEqual(@as(f32, 30), try tree.setScrollOffset(scroll, 30));
    try std.testing.expectEqual(PointF{ .y = -30 }, try tree.nodeOffset(content));

    var commands: [3]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(scroll, &builder);
    try std.testing.expectEqual(@as(usize, 3), builder.displayList().commands.len);
    try std.testing.expectEqual(
        @as(scene.Command, .{ .push_clip_rect = .{ .x = 0, .y = 0, .width = 40, .height = 50 } }),
        builder.displayList().commands[0],
    );
    try std.testing.expectEqual(@as(i32, -30), builder.displayList().commands[1].solid_rectangle.bounds.y);
    try std.testing.expect(builder.displayList().commands[2] == .pop_clip);
    try std.testing.expectEqual(content, (try tree.hitTest(scroll, .{ .x = 10, .y = 10 })).?);
    try std.testing.expect((try tree.hitTest(scroll, .{ .x = 10, .y = 60 })) == null);
    try std.testing.expectEqual(@as(f32, 70), try tree.setScrollOffset(scroll, 500));
}

test "image tree retains intrinsic resources and emits scaled clipped native commands" {
    const scene = @import("../../scene/root.zig");
    const RectI = @import("../../core/geometry.zig").RectI;
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try images.insert(.{
        .allocator = std.testing.allocator,
        .pixels = try std.testing.allocator.dupe(u8, &.{ 17, 31, 63, 255 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = 120,
        .intrinsic_height = 40,
    });
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    tree.attachImageCache(&images);
    const root = try tree.create(.{ .stack = .{ .clip = true } });
    const leaf = try tree.create(.{ .image = .{ .width = 35.5, .height = 17.25 } });
    try tree.appendChild(root, leaf, .{ .stack = .{ .x = 1.25, .y = 2.5 } });
    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));
    try std.testing.expectEqual(SizeF{ .width = 35.5, .height = 17.25 }, try tree.nodeSize(leaf));
    var commands: [3]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 2);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(usize, 2), builder.count);
    try std.testing.expect(commands[0] == .push_clip_rect and commands[1] == .pop_clip);

    // Loading a resource into an explicitly sized image changes paint only.
    try tree.update(leaf, .{ .image = .{ .image = image, .width = 35.5, .height = 17.25 } });
    try std.testing.expect(!(try tree.layoutDirty(root)));
    try std.testing.expect(try tree.paintDirty(root));
    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 80 }));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(leaf));
    builder = try scene_builder.Builder.init(&commands, 2);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(image, commands[1].image.image);
    try std.testing.expectEqual(RectI{ .x = 2, .y = 5, .width = 72, .height = 35 }, commands[1].image.bounds);

    try tree.update(leaf, .{ .image = .{ .image = image } });
    try images.release(image);
    _ = try tree.layout(root, Constraints.tight(.{ .width = 150, .height = 80 }));
    try std.testing.expectEqual(SizeF{ .width = 120, .height = 40 }, try tree.nodeSize(leaf));
    try tree.update(leaf, .{ .image = .{ .image = image, .fit = .cover } });
    try std.testing.expect(!(try tree.layoutDirty(leaf)));
    try std.testing.expect(try tree.paintDirty(leaf));
    builder = try scene_builder.Builder.init(&commands, 2);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(usize, 3), builder.count);
    try std.testing.expectEqual(RectI{ .x = 0, .y = 0, .width = 300, .height = 160 }, commands[0].push_clip_rect);
    try std.testing.expectEqual(image, commands[1].image.image);
    try std.testing.expectEqual(RectI{ .x = 2, .y = 5, .width = 241, .height = 80 }, commands[1].image.bounds);
    try std.testing.expectEqual(@import("../../image/pixels.zig").Fit.cover, commands[1].image.fit);
    try std.testing.expect(commands[2] == .pop_clip);
    try builder.displayList().validate();

    try tree.destroy(leaf);
    try std.testing.expectError(error.StaleImageHandle, images.get(image));
}

test "stack fill image resizes behind centered foreground and cannot steal its hits" {
    const scene = @import("../../scene/root.zig");
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try images.insert(.{
        .allocator = std.testing.allocator,
        .pixels = try std.testing.allocator.dupe(u8, &.{ 0, 0, 0, 128 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = 90,
        .intrinsic_height = 30,
    });
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    tree.attachImageCache(&images);
    const root = try tree.create(.{ .stack = .{} });
    const background = try tree.create(.{ .image = .{ .image = image, .fit = .fill } });
    try images.release(image);
    const foreground = try tree.create(.{ .box = .{ .fill_width = true, .fill_height = true, .alignment = .center } });
    const control = try tree.create(.{ .box = .{ .width = 60, .height = 24, .background = Color.rgba(20, 60, 100, 255) } });
    try tree.appendChild(root, background, .none);
    try tree.appendChild(root, foreground, .none);
    try tree.appendChild(foreground, control, .none);
    _ = try tree.layout(root, .{ .max_width = 240, .max_height = 100 });
    try std.testing.expectEqual(SizeF{ .width = 90, .height = 30 }, try tree.nodeSize(background));
    try tree.update(background, .{ .image = .{ .image = image, .fill_width = true, .fill_height = true, .fit = .fill } });
    try std.testing.expect(try tree.layoutDirty(root));
    for ([_]SizeF{ .{ .width = 240, .height = 100 }, .{ .width = 370, .height = 180 } }) |size_value| {
        // Loose bounded constraints are deliberate: filling cannot depend on
        // receiving a tight window rectangle or using the window's dimensions.
        _ = try tree.layout(root, .{ .max_width = size_value.width, .max_height = size_value.height });
        try std.testing.expectEqual(size_value, try tree.nodeSize(root));
        try std.testing.expectEqual(size_value, try tree.nodeSize(background));
        try std.testing.expectEqual(PointF{ .x = (size_value.width - 60) / 2, .y = (size_value.height - 24) / 2 }, try tree.nodeOffset(control));
        try std.testing.expectEqual(control, (try tree.hitTest(root, .{ .x = size_value.width / 2, .y = size_value.height / 2 })).?);
        var commands: [2]scene.Command = undefined;
        var builder = try scene_builder.Builder.init(&commands, 2);
        try tree.buildScene(root, &builder);
        try std.testing.expectEqual(@as(usize, 2), builder.count);
        try std.testing.expect(commands[0] == .image and commands[1] == .solid_rectangle);
        try std.testing.expectEqual(@as(u32, @intFromFloat(size_value.width * 2)), commands[0].image.bounds.width);
        try std.testing.expectEqual(@as(u32, @intFromFloat(size_value.height * 2)), commands[0].image.bounds.height);
        try std.testing.expectEqual(@as(u32, 1), (try images.get(image)).width);
    }
}

test "image tree rejects stale replacements and children without changing ownership" {
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try images.insert(.{
        .allocator = std.testing.allocator,
        .pixels = try std.testing.allocator.dupe(u8, &.{ 17, 31, 63, 255 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = 90,
        .intrinsic_height = 30,
    });
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    try std.testing.expectError(error.ImageResourcesRequired, tree.create(.{ .image = .{ .image = image } }));
    tree.attachImageCache(&images);
    const leaf = try tree.create(.{ .image = .{ .image = image } });
    try images.release(image);
    const stale: Handle = .{ .slot = image.slot, .generation = image.generation + 1 };
    try std.testing.expectError(error.StaleImageHandle, tree.validateRetain(.{ .image = .{ .image = stale } }));
    try std.testing.expectError(error.StaleImageHandle, tree.update(leaf, .{ .image = .{ .image = stale } }));
    try std.testing.expectError(error.StaleImageHandle, tree.create(.{ .image = .{ .image = stale } }));
    try std.testing.expectEqual(image, (try tree.objectAt(leaf)).image.image.?);
    try tree.validateRetain(.{ .image = .{ .image = image } });
    const parent = try tree.create(.{ .box = .{} });
    const child = try tree.create(.{ .box = .{} });
    try std.testing.expectError(error.ImageHasChildren, tree.appendChild(leaf, child, .none));
    try tree.appendChild(parent, child, .none);
    try std.testing.expectError(error.ImageHasChildren, tree.update(parent, .{ .image = .{ .image = image } }));
    try std.testing.expect((try tree.objectAt(parent)) == .box);
    try std.testing.expectEqual(child, tree.firstChild(parent).?);
    try std.testing.expectError(error.RenderObjectCapacityExceeded, tree.create(.{ .image = .{ .image = image } }));
    try tree.update(leaf, .{ .image = .{ .width = 51, .height = 19 } });
    try std.testing.expectError(error.StaleImageHandle, images.get(image));
    try std.testing.expectEqual(SizeF{ .width = 51, .height = 19 }, try tree.layout(leaf, .{}));
}

test "image tree deinit releases every shared image lease" {
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try images.insert(.{
        .allocator = std.testing.allocator,
        .pixels = try std.testing.allocator.dupe(u8, &.{ 17, 31, 63, 255 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = 90,
        .intrinsic_height = 30,
    });
    {
        var tree: Tree = undefined;
        try tree.init(std.testing.allocator, 2);
        defer tree.deinit();
        tree.attachImageCache(&images);
        const first = try tree.create(.{ .image = .{ .image = image } });
        _ = try tree.create(.{ .image = .{ .image = image } });
        try images.release(image);
        try tree.update(first, .{ .box = .{} });
        try std.testing.expectEqual(@as(u32, 90), (try images.get(image)).intrinsic_width);
    }
    try std.testing.expectError(error.StaleImageHandle, images.get(image));
}

test "inline text links hit only visible fragments and retain focus geometry through reflow" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{ .key = .{ .file = "link-font", .index = 0 }, .bytes = @embedFile("ourokit_test_font") });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const source = try sources.acquire(.{
        .utf8 = "before link\nnext after",
        .language = "en",
        .logical_size = 20,
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    defer sources.release(source) catch unreachable;
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    tree.attachTextCaches(&sources, &paragraphs);
    const paragraph_node = try tree.create(.{ .text = .{ .source = source, .color = Color.rgba(10, 20, 30, 255) } });
    const link = try tree.create(.{ .box = .{ .background = Color.rgba(20, 80, 160, 255), .outline_color = Color.rgba(160, 20, 40, 255), .outline_width = 2 } });
    try tree.appendChild(paragraph_node, link, .{ .text_range = .{ .start = 7, .end = 16 } });
    _ = try tree.layout(paragraph_node, .{ .max_width = 300, .max_height = 200 });
    const layout_value = try paragraphs.get((try tree.slot(paragraph_node)).paragraph_layout.?);
    const first = layout_value.positioned.lines[0];
    const second = layout_value.positioned.lines[1];
    const before: PointF = .{ .x = 1, .y = first.top + first.baseline / 2 };
    const next: PointF = .{ .x = 1, .y = second.top + second.baseline / 2 };
    const end: PointF = .{ .x = first.advance - 1, .y = before.y };
    const union_bounds = try tree.paintBounds(link);
    try std.testing.expect(union_bounds.contains(before));
    try std.testing.expectEqual(paragraph_node, (try tree.hitTest(paragraph_node, before)).?);
    try std.testing.expectEqual(link, (try tree.hitTest(paragraph_node, next)).?);
    try std.testing.expectEqual(link, (try tree.hitTest(paragraph_node, end)).?);
    try std.testing.expectEqual(link, (try tree.hitTest(paragraph_node, (try tree.textRangePoint(link)).?)).?);
    var commands: [24]@import("../../scene/root.zig").Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(paragraph_node, &builder);
    var underlines: usize = 0;
    var outlines: usize = 0;
    for (builder.displayList().commands) |command| switch (command) {
        .solid_rectangle => underlines += 1,
        .decorated_rectangle => outlines += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), underlines);
    try std.testing.expectEqual(@as(usize, 2), outlines);
    _ = try tree.layout(paragraph_node, .{ .max_width = 80, .max_height = 200 });
    try std.testing.expectEqual(link, (try tree.hitTest(paragraph_node, (try tree.textRangePoint(link)).?)).?);
    // Truncated-away links have no synthetic ellipsis hit area.
    try tree.update(paragraph_node, .{ .text = .{ .source = source, .color = Color.rgba(0, 0, 0, 255), .max_lines = 1, .overflow = .ellipsis } });
    _ = try tree.layout(paragraph_node, .{ .max_width = 40, .max_height = 200 });
    try std.testing.expectEqual(@as(?PointF, null), try tree.textRangePoint(link));
    try std.testing.expectEqual(@as(f32, 0), (try tree.nodeSize(link)).width);
    try std.testing.expect(!try tree.isVisible(link));
    try std.testing.expect(!try tree.isInteractive(link));
}
