const std = @import("std");
const Color = @import("../../core/color.zig").Color;
const Handle = @import("../../core/handle.zig").Handle;
const PointF = @import("../../core/geometry.zig").PointF;
const RectF = @import("../../core/geometry.zig").RectF;
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const box_impl = @import("box.zig");
const flex_impl = @import("flex.zig");
const scroll_impl = @import("scroll.zig");
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
    UnconstrainedLayoutSize,
    FlexInUnboundedAxis,
    ScrollInUnboundedAxis,
    InvalidParentData,
    LabelHasChildren,
    TextInputHasChildren,
    ParagraphResourcesRequired,
    StaleParagraphSource,
    StaleParagraph,
    ParagraphLayoutFailed,
    InvalidTextInputRange,
};

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    object: types.Object = .{ .box = .{} },
    parent: ?NodeHandle = null,
    first_child: ?NodeHandle = null,
    last_child: ?NodeHandle = null,
    previous_sibling: ?NodeHandle = null,
    next_sibling: ?NodeHandle = null,
    parent_data: types.ParentData = .none,
    size: SizeF = .{ .width = 0, .height = 0 },
    offset: PointF = .{},
    last_constraints: Constraints = .{},
    has_layout: bool = false,
    needs_layout: bool = true,
    needs_paint: bool = true,
    layout_count: usize = 0,
    paragraph_layout: ?text.ParagraphHandle = null,
    scroll_offset: f32 = 0,
    scroll_extent: f32 = 0,
};

/// Fixed-capacity storage for the closed typed render-object set. Unchanged
/// layout is allocation-free; dirty Labels may populate the paragraph cache.
/// This is deliberately not the widget/instance tree.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    paragraph_sources: ?*text.ParagraphSourceCache = null,
    paragraphs: ?*text.ParagraphCache = null,

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

    /// Both caches must outlive this tree. Labels retain width-independent
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
            .label => |label| {
                const cache = self.paragraph_sources orelse return error.TextCacheRequired;
                try cache.validateRetain(label.source);
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
        if (parent_slot.object == .label) return error.LabelHasChildren;
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
        var child = target.first_child;
        while (child) |child_handle| : (child = (try self.slot(child_handle)).next_sibling)
            try validateParentData(object, (try self.slot(child_handle)).parent_data);

        const affects_layout = layoutPropertiesChanged(target.object, object);
        try self.retainObject(object);
        const previous = target.object;
        if (sourceChanged(previous, object)) self.releaseParagraphLayout(target);
        target.object = object;
        self.releaseObject(previous);
        if (affects_layout)
            self.markNeedsLayout(handle)
        else
            self.markNeedsPaint(handle);
    }

    pub fn objectAt(self: *Tree, handle: NodeHandle) !types.Object {
        return (try self.slot(handle)).object;
    }

    pub fn layout(self: *Tree, root: NodeHandle, constraints: Constraints) LayoutError!SizeF {
        try constraints.validate();
        const root_slot = try self.slot(root);
        if (root_slot.parent != null) return error.LayoutRootHasParent;
        root_slot.offset = .{};
        return self.layoutNode(root, constraints);
    }

    pub fn buildScene(
        self: *Tree,
        root: NodeHandle,
        builder: *scene_builder.Builder,
    ) !void {
        const root_slot = try self.slot(root);
        if (!root_slot.has_layout or root_slot.needs_layout) return error.LayoutRequired;
        try self.paintNode(root, builder, .{});
    }

    pub fn hitTest(self: *Tree, root: NodeHandle, point: PointF) !?NodeHandle {
        const root_slot = try self.slot(root);
        if (!root_slot.has_layout or root_slot.needs_layout) return error.LayoutRequired;
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
        return paragraph_layout.positioned.hitTestPoint(point) orelse
            return error.TextPositionNotFound;
    }

    pub fn textCaretRectangle(self: *Tree, handle: NodeHandle) !RectF {
        const target = try self.slot(handle);
        if (target.object != .text_input) return error.NotTextInputObject;
        if (!target.has_layout or target.needs_layout) return error.LayoutRequired;
        const paragraph_handle = target.paragraph_layout orelse return error.LayoutRequired;
        const paragraph_layout = self.paragraphs.?.get(paragraph_handle) catch
            return error.StaleParagraph;
        const input = target.object.text_input;
        return paragraph_layout.positioned.caretRectangleForOffset(
            input.caret_offset,
            input.caret_affinity,
            input.caret_width,
        );
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

    pub fn layoutDirty(self: *Tree, handle: NodeHandle) !bool {
        return (try self.slot(handle)).needs_layout;
    }

    pub fn paintDirty(self: *Tree, handle: NodeHandle) !bool {
        return (try self.slot(handle)).needs_paint;
    }

    pub fn firstChild(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).first_child;
    }

    pub fn nextSibling(self: *Tree, handle: NodeHandle) ?NodeHandle {
        return (self.slot(handle) catch unreachable).next_sibling;
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
        return offset;
    }

    pub fn scrollOffset(self: *Tree, handle: NodeHandle) !f32 {
        const target = try self.slot(handle);
        if (target.object != .scroll) return error.NotScrollObject;
        return target.scroll_offset;
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
        if (!current.needs_layout and current.has_layout and
            std.meta.eql(current.last_constraints, constraints)) return current.size;
        const object = current.object;
        const result = switch (object) {
            .box => |value| try box_impl.layout(value, self, handle, constraints),
            .flex => |value| try flex_impl.layout(value, self, handle, constraints),
            .stack => |value| try stack_impl.layout(value, self, handle, constraints),
            .scroll => |value| try scroll_impl.layout(value, self, handle, constraints),
            .label => try self.layoutLabel(handle, object.label, constraints),
            .text_input => try self.layoutTextInput(handle, object.text_input, constraints),
        };
        if (!validSize(result)) return error.InvalidLayoutSize;
        const constrained = constraints.constrain(result);
        if (!std.meta.eql(result, constrained)) return error.UnconstrainedLayoutSize;
        const target = try self.slot(handle);
        target.size = result;
        target.last_constraints = constraints;
        target.has_layout = true;
        target.needs_layout = false;
        target.needs_paint = true;
        target.layout_count += 1;
        return result;
    }

    fn paintNode(
        self: *Tree,
        handle: NodeHandle,
        builder: *scene_builder.Builder,
        origin: PointF,
    ) !void {
        const target = try self.slot(handle);
        const bounds: RectF = .{
            .x = origin.x,
            .y = origin.y,
            .width = target.size.width,
            .height = target.size.height,
        };
        const clips = switch (target.object) {
            .box => |value| paint: {
                if (value.outline_color) |outline_color| {
                    const expansion = value.outline_gap + value.outline_width;
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
                        value.corner_radius + expansion,
                    );
                }
                if (value.border_color != null or value.corner_radius != 0) {
                    try builder.decoratedRectangle(
                        bounds,
                        value.background,
                        value.border_color,
                        value.border_width,
                        value.corner_radius,
                    );
                } else if (value.background) |color| try builder.solidRectangle(bounds, color);
                break :paint value.clip;
            },
            .flex => false,
            .stack => |value| value.clip,
            .scroll => true,
            .label => |value| paint: {
                const paragraph_handle = target.paragraph_layout orelse return error.LayoutRequired;
                try builder.pushClip(bounds);
                try builder.paragraph(paragraph_handle, origin, value.color);
                break :paint true;
            },
            .text_input => |value| paint: {
                const paragraph_handle = target.paragraph_layout orelse return error.LayoutRequired;
                const paragraph_layout = self.paragraphs.?.get(paragraph_handle) catch
                    return error.StaleParagraph;
                try builder.pushClip(bounds);
                if (value.selection_start != value.selection_end) {
                    var rectangles = try paragraph_layout.positioned.selectionRectangleIterator(.{
                        .start = value.selection_start,
                        .end = value.selection_end,
                    });
                    while (try rectangles.next()) |rectangle| try builder.solidRectangle(.{
                        .x = origin.x + rectangle.x,
                        .y = origin.y + rectangle.y,
                        .width = rectangle.width,
                        .height = rectangle.height,
                    }, value.selection_color);
                }
                try builder.paragraph(paragraph_handle, origin, value.color);
                if (value.preedit) |range| {
                    var rectangles = try paragraph_layout.positioned.selectionRectangleIterator(.{
                        .start = range.start,
                        .end = range.end,
                    });
                    while (try rectangles.next()) |rectangle| try builder.solidRectangle(.{
                        .x = origin.x + rectangle.x,
                        .y = origin.y + rectangle.y + rectangle.height - value.preedit_width,
                        .width = rectangle.width,
                        .height = value.preedit_width,
                    }, value.preedit_color.?);
                }
                if (value.show_caret and value.selection_start == value.selection_end) {
                    const rectangle = try paragraph_layout.positioned.caretRectangleForOffset(
                        value.caret_offset,
                        value.caret_affinity,
                        value.caret_width,
                    );
                    try builder.solidRectangle(.{
                        .x = origin.x + rectangle.x,
                        .y = origin.y + rectangle.y,
                        .width = rectangle.width,
                        .height = rectangle.height,
                    }, value.caret_color);
                }
                break :paint true;
            },
        };
        if (clips and target.object != .label and target.object != .text_input)
            try builder.pushClip(bounds);
        var child = target.first_child;
        while (child) |child_handle| {
            const child_slot = try self.slot(child_handle);
            const next = child_slot.next_sibling;
            try self.paintNode(child_handle, builder, PointF.add(origin, child_slot.offset));
            child = next;
        }
        if (clips) try builder.popClip();
        target.needs_paint = false;
    }

    fn hitTestNode(self: *Tree, handle: NodeHandle, point: PointF) !?NodeHandle {
        const target = try self.slot(handle);
        if (!(RectF{ .x = 0, .y = 0, .width = target.size.width, .height = target.size.height }).contains(point))
            return null;
        var child = target.last_child;
        while (child) |child_handle| {
            const child_slot = try self.slot(child_handle);
            const previous = child_slot.previous_sibling;
            if (try self.hitTestNode(child_handle, .{
                .x = point.x - child_slot.offset.x,
                .y = point.y - child_slot.offset.y,
            })) |hit| return hit;
            child = previous;
        }
        return handle;
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
            target.needs_paint = true;
            current = target.parent;
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

    fn layoutLabel(
        self: *Tree,
        handle: NodeHandle,
        label: types.Label,
        constraints: Constraints,
    ) LayoutError!SizeF {
        const sources = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
        const paragraphs = self.paragraphs orelse return error.ParagraphResourcesRequired;
        const source = sources.get(label.source) catch return error.StaleParagraphSource;
        const layout_handle = paragraphs.acquire(.{
            .utf8 = source.utf8,
            .base_direction = source.base_direction,
            .language = source.language,
            .logical_size = source.logical_size,
            .max_width = if (constraints.hasBoundedWidth())
                constraints.max_width
            else
                std.math.floatMax(f32),
            .candidates = source.candidates,
            .configuration_revision = source.configuration_revision,
            .style = .{
                .alignment = label.alignment,
                .max_lines = label.max_lines,
                .overflow = label.overflow,
            },
        }) catch return error.ParagraphLayoutFailed;
        errdefer paragraphs.release(layout_handle) catch unreachable;
        const paragraph_layout = paragraphs.get(layout_handle) catch return error.StaleParagraph;
        const result = constraints.constrain(paragraph_layout.size);
        const target = try self.slot(handle);
        self.releaseParagraphLayout(target);
        target.paragraph_layout = layout_handle;
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
        const layout_handle = paragraphs.acquire(.{
            .utf8 = source.utf8,
            .base_direction = source.base_direction,
            .language = source.language,
            .logical_size = source.logical_size,
            .max_width = if (constraints.hasBoundedWidth())
                constraints.max_width
            else
                std.math.floatMax(f32),
            .candidates = source.candidates,
            .configuration_revision = source.configuration_revision,
            .style = .{ .alignment = input.alignment },
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
        const result = constraints.constrain(paragraph_layout.size);
        const target = try self.slot(handle);
        self.releaseParagraphLayout(target);
        target.paragraph_layout = layout_handle;
        return result;
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
            .label => |label| {
                const sources = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
                try sources.retain(label.source);
            },
            .text_input => |input| {
                const sources = self.paragraph_sources orelse return error.ParagraphResourcesRequired;
                try sources.retain(input.source);
            },
            else => {},
        }
    }

    fn releaseObject(self: *Tree, object: types.Object) void {
        switch (object) {
            .label => |label| self.paragraph_sources.?.release(label.source) catch unreachable,
            .text_input => |input| self.paragraph_sources.?.release(input.source) catch unreachable,
            else => {},
        }
    }

    fn releaseParagraphLayout(self: *Tree, slot_value: *Slot) void {
        if (slot_value.paragraph_layout) |paragraph_handle|
            self.paragraphs.?.release(paragraph_handle) catch unreachable;
        slot_value.paragraph_layout = null;
    }
};

fn validateObject(object: types.Object) !void {
    switch (object) {
        .box => |value| try box_impl.validate(value),
        .flex => |value| try flex_impl.validate(value),
        .stack => {},
        .scroll => {},
        .label => |label| {
            if (label.max_lines == 0) return error.InvalidMaxLines;
            if (label.overflow == .ellipsis and label.max_lines == null)
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
        .box => if (data != .none) return error.InvalidParentData,
        .flex => if (data != .none and data != .flex) return error.InvalidParentData,
        .stack => switch (data) {
            .none => {},
            .stack => |value| if (!validPoint(.{ .x = value.x, .y = value.y }))
                return error.InvalidParentData,
            .flex => return error.InvalidParentData,
        },
        .scroll => if (data != .none) return error.InvalidParentData,
        .label => return error.LabelHasChildren,
        .text_input => return error.TextInputHasChildren,
    }
}

fn layoutPropertiesChanged(old: types.Object, new: types.Object) bool {
    if (std.meta.activeTag(old) != std.meta.activeTag(new)) return true;
    return switch (old) {
        .box => |old_box| changed: {
            const new_box = new.box;
            break :changed old_box.width != new_box.width or old_box.height != new_box.height or
                old_box.border_width != new_box.border_width or
                !std.meta.eql(old_box.padding, new_box.padding) or
                !std.meta.eql(old_box.alignment, new_box.alignment);
        },
        .flex => |old_flex| !std.meta.eql(old_flex, new.flex),
        .stack => false,
        .scroll => |old_scroll| old_scroll.axis != new.scroll.axis,
        .label => |old_label| !sameSource(old_label.source, new.label.source) or
            old_label.alignment != new.label.alignment or
            old_label.max_lines != new.label.max_lines or
            old_label.overflow != new.label.overflow,
        .text_input => |old_input| !sameSource(old_input.source, new.text_input.source) or
            old_input.alignment != new.text_input.alignment,
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
        .label => |label| label.source,
        .text_input => |input| input.source,
        else => null,
    };
}

fn hasCaretBoundary(positioned: *const text.PositionedLines, byte_offset: usize) bool {
    for (positioned.carets) |caret| if (caret.byte_offset == byte_offset) return true;
    return false;
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
    try tree.update(expanded, .{ .box = .{ .background = Color.rgba(70, 80, 90, 255) } });
    try std.testing.expect(!(try tree.layoutDirty(root)));
    try std.testing.expect(try tree.paintDirty(root));
    _ = try tree.layout(root, Constraints.tight(.{ .width = 100, .height = 20 }));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(root));
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

test "labels cache width-specific mixed-script paragraphs across unchanged layout" {
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
    const label = try tree.create(.{ .label = .{
        .source = source,
        .color = Color.rgba(20, 40, 80, 255),
    } });
    try sources.release(source);

    const wide_size = try tree.layout(label, .{ .max_width = 180, .max_height = 200 });
    var commands: [3]scene.Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(label, &builder);
    const wide_layout = builder.displayList().commands[1].paragraph.layout;
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(label));
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());

    _ = try tree.layout(label, .{ .max_width = 180, .max_height = 200 });
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(label));
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());

    const narrow_size = try tree.layout(label, .{ .max_width = 70, .max_height = 200 });
    try std.testing.expect(narrow_size.height > wide_size.height);
    try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(label));
    try std.testing.expectEqual(@as(usize, 1), paragraphs.count());
    builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(label, &builder);
    const narrow_layout = builder.displayList().commands[1].paragraph.layout;
    try std.testing.expect(!sameParagraph(wide_layout, narrow_layout));

    try tree.destroy(label);
    try std.testing.expectEqual(@as(usize, 0), sources.count());
    try std.testing.expectEqual(@as(usize, 0), paragraphs.count());
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

test "box outline is paint-only state" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    defer tree.deinit();
    const box = try tree.create(.{ .box = .{ .width = 40, .height = 20 } });
    _ = try tree.layout(box, Constraints.tight(.{ .width = 40, .height = 20 }));
    var commands: [1]@import("../../scene/root.zig").Command = undefined;
    var builder = try scene_builder.Builder.init(&commands, 1);
    try tree.buildScene(box, &builder);
    try tree.update(box, .{ .box = .{
        .width = 40,
        .height = 20,
        .outline_color = Color.rgba(20, 80, 220, 255),
        .outline_width = 2,
        .outline_gap = 2,
    } });
    try std.testing.expect(!(try tree.layoutDirty(box)));
    try std.testing.expect(try tree.paintDirty(box));
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
