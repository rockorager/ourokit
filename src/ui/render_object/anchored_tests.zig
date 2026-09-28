const std = @import("std");
const Tree = @import("tree.zig").Tree;
const types = @import("types.zig");
const anchored = @import("anchored.zig");
const Constraints = @import("../layout/constraints.zig").Constraints;
const geometry = @import("../../core/geometry.zig");
const SizeF = geometry.SizeF;
const PointF = geometry.PointF;
const Color = @import("../../core/color.zig").Color;
const scene = @import("../../scene/root.zig");
const Builder = @import("scene_builder.zig").Builder;

test "anchored physical sides and alignments use asymmetric trigger and popup dimensions" {
    const trigger: geometry.RectF = .{ .x = 71, .y = 59, .width = 31, .height = 17 };
    const popup: SizeF = .{ .width = 53, .height = 29 };
    const viewport = anchored.inset(.{ .width = 240, .height = 180 }, 8);
    for ([_]types.Anchored.Alignment{ .start, .center, .end }, 0..) |alignment, i| {
        const dx = [_]f32{ 71, 60, 49 };
        const dy = [_]f32{ 59, 53, 47 };
        for ([_]struct { side: types.Anchored.Side, point: PointF }{
            .{ .side = .top, .point = .{ .x = dx[i], .y = 23 } },
            .{ .side = .bottom, .point = .{ .x = dx[i], .y = 83 } },
            .{ .side = .left, .point = .{ .x = 11, .y = dy[i] } },
            .{ .side = .right, .point = .{ .x = 109, .y = dy[i] } },
        }) |case| try std.testing.expectEqual(case.point, anchored.place(.{
            .side = case.side,
            .alignment = alignment,
            .gap = 7,
        }, trigger, popup, viewport));
    }
}

test "anchored flips only for better fit and clamps cross axis oversized and tiny geometry" {
    const viewport = anchored.inset(.{ .width = 101, .height = 83 }, 8);
    const popup: SizeF = .{ .width = 37, .height = 23 };
    // Bottom fits exactly at y=41, then one additional pixel forces a flip.
    for ([_]struct { y: f32, flip: bool, expected: f32 }{
        .{ .y = 41, .flip = true, .expected = 52 },
        .{ .y = 42, .flip = true, .expected = 15 },
        .{ .y = 42, .flip = false, .expected = 52 },
    }) |case| try std.testing.expectEqual(PointF{ .x = 56, .y = case.expected }, anchored.place(
        .{ .flip = case.flip },
        .{ .x = 80, .y = case.y, .width = 13, .height = 7 },
        popup,
        viewport,
    ));
    // Neither side fits: top has less overflow, even though it still clamps.
    try std.testing.expectEqual(PointF{ .x = 8, .y = 8 }, anchored.place(.{}, .{ .x = 2, .y = 55, .width = 11, .height = 9 }, .{ .width = 90, .height = 60 }, viewport));
    const tiny = anchored.inset(.{ .width = 5, .height = 3 }, std.math.floatMax(f32));
    try std.testing.expectEqual(geometry.RectF{ .x = 2.5, .y = 1.5, .width = 0, .height = 0 }, tiny);
    try std.testing.expectEqual(PointF{ .x = 2.5, .y = 1.5 }, anchored.place(.{ .gap = std.math.floatMax(f32) }, .{ .x = std.math.floatMax(f32), .y = -std.math.floatMax(f32), .width = 17, .height = 31 }, .{ .width = 900, .height = 700 }, tiny));
    // Equal overflow on top and bottom preserves the requested side.
    try std.testing.expectEqual(PointF{ .x = 8, .y = 32 }, anchored.place(.{ .gap = 30 }, .{ .x = 8, .y = 38, .width = 13, .height = 7 }, .{ .width = 37, .height = 43 }, viewport));
    for ([_]struct { side: types.Anchored.Side, x: f32, expected: f32 }{
        .{ .side = .right, .x = 46, .expected = 64 },
        .{ .side = .right, .x = 47, .expected = 11 },
        .{ .side = .left, .x = 44, .expected = 8 },
        .{ .side = .left, .x = 43, .expected = 61 },
    }) |case| try std.testing.expectEqual(PointF{ .x = case.expected, .y = 27 }, anchored.place(
        .{ .side = case.side, .alignment = .center, .gap = 7 },
        .{ .x = case.x, .y = 35, .width = 11, .height = 7 },
        .{ .width = 29, .height = 23 },
        viewport,
    ));
    for ([_]struct { y: f32, expected: f32 }{
        .{ .y = 35, .expected = 8 },
        .{ .y = 34, .expected = 45 },
    }) |case| try std.testing.expectEqual(PointF{ .x = 20, .y = case.expected }, anchored.place(
        .{ .side = .top },
        .{ .x = 20, .y = case.y, .width = 11, .height = 7 },
        popup,
        viewport,
    ));
}

test "anchored inline size loose popup measure cache resize and dimension updates" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const anchor = try tree.create(.{ .anchored = .{ .alignment = .end } });
    const trigger = try tree.create(.{ .box = .{ .width = 31, .height = 17 } });
    const popup = try tree.create(.{ .box = .{ .width = 53, .height = 29 } });
    try tree.appendChild(root, anchor, .{ .stack = .{ .x = 71, .y = 59 } });
    try tree.appendChild(anchor, trigger, .none);
    const bounds: Constraints = .{ .max_width = 240, .max_height = 180 };
    const inline_size = try tree.layout(root, bounds);
    try tree.appendChild(anchor, popup, .none);
    try std.testing.expectEqual(inline_size, try tree.layout(root, bounds));
    try std.testing.expectEqual(SizeF{ .width = 31, .height = 17 }, try tree.nodeSize(anchor));
    try std.testing.expectEqual(SizeF{ .width = 53, .height = 29 }, try tree.nodeSize(popup));
    try std.testing.expectEqual(PointF{ .x = -22, .y = 21 }, try tree.nodeOffset(popup));
    // Root shrink-wraps to height 76. Only floating content receives hits below it.
    try std.testing.expectEqual(popup, (try tree.hitTest(root, .{ .x = 60, .y = 90 })).?);
    try std.testing.expect((try tree.hitTest(root, .{ .x = 150, .y = 100 })) == null);
    var commands: [8]scene.Command = undefined;
    var builder = try Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(root));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(trigger));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(popup));
    try std.testing.expect(!(try tree.paintDirty(root)));
    try tree.update(popup, .{ .box = .{ .width = 67, .height = 41 } });
    try std.testing.expectError(error.LayoutRequired, tree.nodeOffset(popup));
    try std.testing.expectError(error.LayoutRequired, tree.hitTest(root, .{}));
    try std.testing.expectError(error.LayoutRequired, tree.buildScene(root, &builder));
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(PointF{ .x = -36, .y = 21 }, try tree.nodeOffset(popup));
    _ = try tree.layout(root, .{ .max_width = 120, .max_height = 100 });
    try std.testing.expectEqual(PointF{ .x = -36, .y = -45 }, try tree.nodeOffset(popup));
    _ = try tree.layout(root, .{ .max_width = 5, .max_height = 3 });
    try std.testing.expectEqual(SizeF{ .width = 0, .height = 0 }, try tree.nodeSize(popup));
    try std.testing.expectEqual(PointF{ .x = -68.5, .y = -57.5 }, try tree.nodeOffset(popup));
}

test "anchored deferred paint and hits escape clips and opacity preserve nested and later sibling order" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 11);
    defer tree.deinit();
    const red = Color.rgba(210, 30, 40, 255);
    const green = Color.rgba(30, 170, 70, 255);
    const blue = Color.rgba(40, 70, 210, 255);
    const root = try tree.create(.{ .stack = .{ .clip = true } });
    const hidden = try tree.create(.{ .box = .{ .width = 20, .height = 12, .clip = true } });
    const first = try tree.create(.{ .anchored = .{} });
    const trigger = try tree.create(.{ .box = .{} });
    const parent_popup = try tree.create(.{ .box = .{ .width = 53, .height = 29, .background = red, .clip = true } });
    const nested = try tree.create(.{ .anchored = .{ .margin = 8 } });
    const nested_trigger = try tree.create(.{ .box = .{} });
    const nested_popup = try tree.create(.{ .box = .{ .width = 37, .height = 37, .background = green } });
    const later = try tree.create(.{ .anchored = .{} });
    const later_trigger = try tree.create(.{ .box = .{ .width = 13, .height = 7 } });
    const later_popup = try tree.create(.{ .box = .{ .width = 31, .height = 23, .background = blue } });
    try tree.appendChild(root, hidden, .{ .stack = .{ .x = 17, .y = 11 } });
    try tree.appendChild(hidden, first, .none);
    try tree.appendChild(first, trigger, .none);
    try tree.appendChild(first, parent_popup, .none);
    try tree.appendChild(parent_popup, nested, .none);
    try tree.appendChild(nested, nested_trigger, .none);
    try tree.appendChild(nested, nested_popup, .none);
    try tree.appendChild(root, later, .{ .stack = .{ .x = 21, .y = 19 } });
    try tree.appendChild(later, later_trigger, .none);
    try tree.appendChild(later, later_popup, .none);
    // Fitting the nested popup makes it overlap its parent's content.
    _ = try tree.layout(root, Constraints.tight(.{ .width = 101, .height = 83 }));
    try std.testing.expectEqual(PointF{ .x = 0, .y = 16 }, try tree.nodeOffset(parent_popup));
    try std.testing.expectEqual(PointF{ .x = 0, .y = 11 }, try tree.nodeOffset(nested_popup));
    try std.testing.expectEqual(later, tree.lastChild(root).?);
    try std.testing.expectEqual(hidden, tree.previousSibling(later).?);
    try std.testing.expectEqual(later_popup, (try tree.hitTest(root, .{ .x = 25, .y = 40 })).?);
    // Nested content covers its parent where they overlap; both escape clips.
    try std.testing.expectEqual(nested_popup, (try tree.hitTest(root, .{ .x = 19, .y = 40 })).?);
    try std.testing.expectEqual(nested_trigger, (try tree.hitTest(root, .{ .x = 65, .y = 40 })).?);
    var commands: [16]scene.Command = undefined;
    var builder = try Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    try builder.displayList().validate();
    // Root and hidden-container clips close before any floating paint.
    try std.testing.expectEqual(@as(usize, 9), builder.count);
    try std.testing.expect(commands[2] == .pop_clip and commands[3] == .pop_clip);
    try std.testing.expectEqual(red, commands[4].solid_rectangle.color);
    try std.testing.expect(commands[5] == .push_clip_rect and commands[6] == .pop_clip);
    try std.testing.expectEqual(green, commands[7].solid_rectangle.color);
    try std.testing.expectEqual(blue, commands[8].solid_rectangle.color);
    const software = @import("../../renderer/software/root.zig");
    var pixels = [_]u8{255} ** (101 * 83 * 4);
    const target: software.Target = .{ .pixels = &pixels, .width = 101, .height = 83, .stride = 404, .format = .rgba8_unorm };
    try software.render(builder.displayList(), target);
    try std.testing.expectEqualSlices(u8, &.{ 40, 70, 210, 255 }, pixels[(40 * 101 + 25) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 30, 170, 70, 255 }, pixels[(40 * 101 + 19) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 210, 30, 40, 255 }, pixels[(40 * 101 + 65) * 4 ..][0..4]);
    // Floating content is a separate paint plane, just as it escapes clips.
    // Fade its own Box explicitly; a nested popup remains independently painted.
    try tree.update(hidden, .{ .box = .{ .width = 20, .height = 12, .clip = true, .opacity = 0 } });
    try tree.update(parent_popup, .{ .box = .{ .width = 53, .height = 29, .background = Color.rgba(0, 0, 0, 255), .clip = true, .opacity = 0.5 } });
    builder = try Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    try builder.displayList().validate();
    @memset(&pixels, 255);
    try software.render(builder.displayList(), target);
    try std.testing.expectEqualSlices(u8, &.{ 188, 188, 188, 255 }, pixels[(40 * 101 + 65) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 30, 170, 70, 255 }, pixels[(40 * 101 + 19) * 4 ..][0..4]);
    try std.testing.expectEqual(nested_popup, (try tree.hitTest(root, .{ .x = 19, .y = 40 })).?);
    try tree.update(hidden, .{ .box = .{ .width = 20, .height = 12, .clip = true, .hidden = true } });
    try std.testing.expect(!(try tree.layoutDirty(root)));
    try std.testing.expectEqual(root, (try tree.hitTest(root, .{ .x = 19, .y = 40 })).?);
    builder = try Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(usize, 3), builder.count);
    try std.testing.expectEqual(blue, commands[2].solid_rectangle.color);
    try std.testing.expect(!(try tree.paintDirty(root)));
    @memset(&pixels, 255);
    try software.render(builder.displayList(), target);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, pixels[(40 * 101 + 19) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 40, 70, 210, 255 }, pixels[(40 * 101 + 25) * 4 ..][0..4]);
}

test "anchored follows scrolling before geometry inspection paint and hit without relayout" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 6);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const scroll = try tree.create(.{ .scroll = .{} });
    const content = try tree.create(.{ .box = .{ .width = 80, .height = 240, .alignment = .center } });
    const anchor = try tree.create(.{ .anchored = .{} });
    const trigger = try tree.create(.{ .box = .{ .width = 31, .height = 17 } });
    const popup = try tree.create(.{ .box = .{ .width = 53, .height = 29, .background = Color.rgba(1, 2, 3, 255) } });
    try tree.appendChild(root, scroll, .{ .stack = .{ .x = 13, .y = 7 } });
    try tree.appendChild(scroll, content, .none);
    try tree.appendChild(content, anchor, .none);
    try tree.appendChild(anchor, trigger, .none);
    try tree.appendChild(anchor, popup, .none);
    _ = try tree.layout(root, Constraints.tight(.{ .width = 151, .height = 101 }));
    // Trigger initially below viewport: popup flips and clamps at y=64.
    try std.testing.expectEqual(PointF{ .x = 0, .y = -54.5 }, try tree.nodeOffset(popup));
    _ = try tree.setScrollOffset(scroll, 75);
    // Trigger now at global y=43.5: bottom fits at 64.5? It exceeds margin
    // by 0.5, so top wins at 10.5, reflected immediately in local geometry.
    try std.testing.expectEqual(PointF{ .x = 0, .y = -33 }, try tree.nodeOffset(popup));
    try std.testing.expectEqual(popup, (try tree.hitTest(root, .{ .x = 40, .y = 12 })).?);
    _ = try tree.setScrollOffset(scroll, 76);
    try std.testing.expectEqual(PointF{ .x = 0, .y = 21 }, try tree.nodeOffset(popup));
    var commands: [4]scene.Command = undefined;
    var builder = try Builder.init(&commands, 2);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(i32, 127), commands[2].solid_rectangle.bounds.y);
    for ([_]@import("tree.zig").NodeHandle{ root, scroll, content, anchor, trigger, popup }) |handle|
        try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(handle));
}

test "anchored validates declarations edges child counts and failed deferred layouts" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 5);
    defer tree.deinit();
    for ([_]f32{ -1, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) }) |bad| {
        try std.testing.expectError(error.InvalidAnchored, tree.create(.{ .anchored = .{ .gap = bad } }));
        try std.testing.expectError(error.InvalidAnchored, tree.create(.{ .anchored = .{ .margin = bad } }));
    }
    const root = try tree.create(.{ .anchored = .{} });
    const trigger = try tree.create(.{ .box = .{ .width = 31, .height = 17 } });
    const popup = try tree.create(.{ .anchored = .{} });
    const third = try tree.create(.{ .box = .{} });
    try std.testing.expectError(error.AnchoredRequiresOneOrTwoChildren, tree.layout(root, .{}));
    try std.testing.expectError(error.InvalidParentData, tree.appendChild(root, trigger, .{ .stack = .{} }));
    try tree.appendChild(root, trigger, .none);
    try std.testing.expectEqual(SizeF{ .width = 31, .height = 17 }, try tree.layout(root, .{}));
    try tree.appendChild(root, popup, .none);
    try std.testing.expectError(error.AnchoredRequiresOneOrTwoChildren, tree.appendChild(root, third, .none));
    try std.testing.expectError(error.AnchoredRequiresOneOrTwoChildren, tree.layout(root, .{}));
    try std.testing.expect(try tree.layoutDirty(root));
    try std.testing.expectError(error.LayoutRequired, tree.nodeSize(root));
    try tree.appendChild(popup, third, .none);
    _ = try tree.layout(root, .{});
    try std.testing.expectEqual(PointF{ .x = 8, .y = 9 }, try tree.nodeOffset(popup));
    try tree.update(root, .{ .stack = .{} });
    const extra = try tree.create(.{ .box = .{} });
    try tree.appendChild(root, extra, .none);
    try std.testing.expectError(error.AnchoredRequiresOneOrTwoChildren, tree.update(root, .{ .anchored = .{} }));
    try std.testing.expect((try tree.objectAt(root)) == .stack);
}

test "anchored attach detach invalidates deferred cache without changing ordinary sibling bounds" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 5);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const anchor = try tree.create(.{ .anchored = .{} });
    const trigger = try tree.create(.{ .box = .{ .width = 17, .height = 9 } });
    const popup = try tree.create(.{ .box = .{ .width = 31, .height = 23, .background = Color.rgba(1, 2, 3, 255) } });
    const cover = try tree.create(.{ .box = .{ .fill_width = true, .fill_height = true, .background = Color.rgba(4, 5, 6, 255) } });
    try tree.appendChild(root, anchor, .{ .stack = .{ .x = 20, .y = 15 } });
    try tree.appendChild(anchor, trigger, .none);
    try tree.appendChild(root, cover, .none);
    const bounds = Constraints.tight(.{ .width = 151, .height = 101 });
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(cover, (try tree.hitTest(root, .{ .x = 25, .y = 35 })).?);
    for (0..2) |_| {
        try tree.appendChild(anchor, popup, .none);
        _ = try tree.layout(root, bounds);
        try std.testing.expectEqual(popup, (try tree.hitTest(root, .{ .x = 25, .y = 35 })).?);
        try std.testing.expectEqual(cover, (try tree.hitTest(root, .{ .x = 25, .y = 20 })).?);
        var commands: [2]scene.Command = undefined;
        var builder = try Builder.init(&commands, 1);
        try tree.buildScene(root, &builder);
        try std.testing.expectEqual(@as(usize, 2), builder.count);
        try std.testing.expectEqual(Color.rgba(1, 2, 3, 255), commands[1].solid_rectangle.color);
        try tree.detachChild(popup);
        _ = try tree.layout(root, bounds);
        try std.testing.expectEqual(cover, (try tree.hitTest(root, .{ .x = 25, .y = 35 })).?);
        builder = try Builder.init(&commands, 1);
        try tree.buildScene(root, &builder);
        try std.testing.expectEqual(@as(usize, 1), builder.count);
        try std.testing.expectEqual(Color.rgba(4, 5, 6, 255), commands[0].solid_rectangle.color);
    }
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(popup));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(cover));
}
