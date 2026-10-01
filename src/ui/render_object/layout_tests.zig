const std = @import("std");
const Tree = @import("tree.zig").Tree;
const types = @import("types.zig");
const Constraints = @import("../layout/constraints.zig").Constraints;
const SizeF = @import("../../core/geometry.zig").SizeF;
const PointF = @import("../../core/geometry.zig").PointF;
const Color = @import("../../core/color.zig").Color;

test "box height factor scales natural outer height without relaying out its child" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    var box: types.Box = .{
        .height_factor = 0,
        .padding = .{ .left = 3, .right = 7, .top = 11, .bottom = 5 },
    };
    const root = try tree.create(.{ .box = box });
    const child = try tree.create(.{ .box = .{ .width = 40, .height = 24 } });
    try tree.appendChild(root, child, .none);

    const loose: Constraints = .{ .max_width = 100, .max_height = 100 };
    try std.testing.expectEqual(SizeF{ .width = 50, .height = 0 }, try tree.layout(root, loose));
    try std.testing.expectEqual(SizeF{ .width = 40, .height = 24 }, try tree.nodeSize(child));
    try std.testing.expectEqual(PointF{ .x = 3, .y = 11 }, try tree.nodeOffset(child));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(child));

    box.height_factor = 0.5;
    try tree.update(root, .{ .box = box });
    try std.testing.expectEqual(SizeF{ .width = 50, .height = 20 }, try tree.layout(root, loose));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(child));
    box.height_factor = 1;
    try tree.update(root, .{ .box = box });
    try std.testing.expectEqual(SizeF{ .width = 50, .height = 40 }, try tree.layout(root, loose));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(child));

    // Tight parent bounds still win for the reported size. The child receives
    // a loose height up to the deflated parent maximum, never the factor result.
    box.height_factor = 0.25;
    try tree.update(root, .{ .box = box });
    const tight = Constraints.tight(.{ .width = 80, .height = 30 });
    try std.testing.expectEqual(SizeF{ .width = 80, .height = 30 }, try tree.layout(root, tight));
    try std.testing.expectEqual(SizeF{ .width = 70, .height = 14 }, try tree.nodeSize(child));
    try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(child));

    for ([_]f32{ -0.01, 1.01, std.math.inf(f32), std.math.nan(f32) }) |factor|
        try std.testing.expectError(error.InvalidHeightFactor, tree.update(root, .{ .box = .{ .height_factor = factor } }));
    try std.testing.expectError(error.ConflictingExtent, tree.update(root, .{ .box = .{ .height_factor = 0.5, .height = 20 } }));
    try std.testing.expectError(error.ConflictingExtent, tree.update(root, .{ .box = .{ .height_factor = 0.5, .fill_height = true } }));
}

test "positioned stack resolves edges after normal children without contributing size" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const overlay = try tree.create(.{ .box = .{ .width = 27, .height = 19 } });
    const base = try tree.create(.{ .box = .{ .width = 120, .height = 80 } });
    // Positioned first deliberately: traversal order must not affect sizing.
    try tree.appendChild(root, overlay, .{ .positioned = .{ .right = 7, .bottom = 11 } });
    try tree.appendChild(root, base, .{ .stack = .{ .x = 3, .y = 5 } });
    const Case = struct { p: types.Positioned, size: SizeF, offset: PointF };
    for ([_]Case{
        .{ .p = .{ .right = 7, .bottom = 11 }, .size = .{ .width = 27, .height = 19 }, .offset = .{ .x = 89, .y = 55 } },
        .{ .p = .{ .left = 9, .right = 14, .top = 6, .bottom = 17 }, .size = .{ .width = 100, .height = 62 }, .offset = .{ .x = 9, .y = 6 } },
        .{ .p = .{ .right = 8, .width = 31, .bottom = 4, .height = 23 }, .size = .{ .width = 31, .height = 23 }, .offset = .{ .x = 84, .y = 58 } },
        .{ .p = .{ .left = -12, .top = -7, .width = 170 }, .size = .{ .width = 170, .height = 19 }, .offset = .{ .x = -12, .y = -7 } },
        .{ .p = .{ .left = 100, .right = 50, .top = 70, .bottom = 20 }, .size = .{ .width = 0, .height = 0 }, .offset = .{ .x = 100, .y = 70 } },
        .{ .p = .{ .width = 46 }, .size = .{ .width = 46, .height = 19 }, .offset = .{} },
    }) |case| {
        try tree.setParentData(overlay, .{ .positioned = case.p });
        try std.testing.expectEqual(SizeF{ .width = 123, .height = 85 }, try tree.layout(root, .{}));
        try std.testing.expectEqual(case.size, try tree.nodeSize(overlay));
        try std.testing.expectEqual(case.offset, try tree.nodeOffset(overlay));
    }
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(base));
    try tree.setParentData(overlay, .{ .positioned = .{ .left = 4, .right = 9, .bottom = 3, .height = 12 } });
    _ = try tree.layout(root, Constraints.tight(.{ .width = 200, .height = 100 }));
    try std.testing.expectEqual(SizeF{ .width = 187, .height = 12 }, try tree.nodeSize(overlay));
    try std.testing.expectEqual(PointF{ .x = 4, .y = 85 }, try tree.nodeOffset(overlay));
}

test "positioned stack requires bounded all-positioned size and validates edges atomically" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{} });
    const child = try tree.create(.{ .box = .{ .aspect_ratio = 2 } });
    try std.testing.expectEqual(SizeF{ .width = 7, .height = 3 }, try tree.layout(root, .{ .min_width = 7, .max_width = 200, .min_height = 3, .max_height = 100 }));
    const data: types.ParentData = .{ .positioned = .{ .right = 5, .top = 9, .width = 70 } };
    try tree.appendChild(root, child, data);
    for ([_]Constraints{ .{}, .{ .max_width = 200 }, .{ .max_height = 100 } }) |bounds|
        try std.testing.expectError(error.PositionedStackInUnboundedAxis, tree.layout(root, bounds));
    try std.testing.expectEqual(SizeF{ .width = 200, .height = 100 }, try tree.layout(root, .{ .max_width = 200, .max_height = 100 }));
    try std.testing.expectEqual(SizeF{ .width = 70, .height = 35 }, try tree.nodeSize(child));
    try std.testing.expectEqual(PointF{ .x = 125, .y = 9 }, try tree.nodeOffset(child));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(child));
    for ([_]types.Positioned{
        .{},                              .{ .left = 1, .right = 2, .width = 3 }, .{ .top = 1, .bottom = 2, .height = 3 },
        .{ .width = -1 },                 .{ .height = -1 },                      .{ .left = std.math.nan(f32) },
        .{ .bottom = std.math.inf(f32) },
    }) |invalid| {
        try std.testing.expectError(error.InvalidParentData, tree.setParentData(child, .{ .positioned = invalid }));
        try std.testing.expectEqualDeep(data, try tree.parentData(child));
        try std.testing.expect(!(try tree.layoutDirty(root)));
    }
    try std.testing.expectError(error.InvalidParentData, tree.update(root, .{ .box = .{} }));
}

test "aspect ratio solves outer box bounds and yields to explicit sizes and incompatible constraints" {
    const Case = struct { box: types.Box, bounds: Constraints = .{}, expected: SizeF };
    const cases = [_]Case{
        .{ .box = .{ .aspect_ratio = 2 }, .bounds = .{ .max_width = 300, .max_height = 200 }, .expected = .{ .width = 300, .height = 150 } },
        .{ .box = .{ .aspect_ratio = 0.5 }, .bounds = .{ .max_width = 300, .max_height = 80 }, .expected = .{ .width = 40, .height = 80 } },
        .{ .box = .{ .aspect_ratio = 1.5 }, .bounds = .{ .max_height = 60 }, .expected = .{ .width = 90, .height = 60 } },
        .{ .box = .{ .aspect_ratio = 0.25 }, .bounds = .{ .max_width = 50 }, .expected = .{ .width = 50, .height = 200 } },
        .{ .box = .{ .aspect_ratio = 2 }, .bounds = .{ .min_width = 140, .max_width = 200, .max_height = 50 }, .expected = .{ .width = 140, .height = 50 } },
        .{ .box = .{ .aspect_ratio = 2 }, .bounds = .{ .max_width = 160, .min_height = 100, .max_height = 180 }, .expected = .{ .width = 160, .height = 100 } },
        .{ .box = .{ .aspect_ratio = 2 }, .bounds = Constraints.tight(.{ .width = 70, .height = 90 }), .expected = .{ .width = 70, .height = 90 } },
        .{ .box = .{ .aspect_ratio = 2 }, .bounds = .{ .min_width = 100, .max_width = 160, .min_height = 70, .max_height = 100 }, .expected = .{ .width = 160, .height = 80 } },
        .{ .box = .{ .aspect_ratio = 3 }, .bounds = .{ .max_width = 0 }, .expected = .{ .width = 0, .height = 0 } },
        .{ .box = .{ .aspect_ratio = 3 }, .bounds = .{ .max_height = 0 }, .expected = .{ .width = 0, .height = 0 } },
        .{ .box = .{ .aspect_ratio = 3, .max_width = 120, .max_height = 60 }, .expected = .{ .width = 120, .height = 40 } },
        .{ .box = .{ .aspect_ratio = 2, .width = 80 }, .bounds = .{ .max_width = 200, .max_height = 200 }, .expected = .{ .width = 80, .height = 40 } },
        .{ .box = .{ .aspect_ratio = 2, .height = 80 }, .bounds = .{ .max_width = 200, .max_height = 200 }, .expected = .{ .width = 160, .height = 80 } },
        .{ .box = .{ .aspect_ratio = 2, .width = 80, .height = 70 }, .expected = .{ .width = 80, .height = 70 } },
        .{ .box = .{ .aspect_ratio = 2, .fill_width = true }, .bounds = .{ .max_width = 200, .max_height = 60 }, .expected = .{ .width = 200, .height = 60 } },
        .{ .box = .{ .aspect_ratio = 2, .fill_height = true }, .bounds = .{ .max_width = 200, .max_height = 60 }, .expected = .{ .width = 120, .height = 60 } },
        .{ .box = .{ .aspect_ratio = 2, .max_width = 80 }, .bounds = .{ .min_width = 100, .max_width = 200 }, .expected = .{ .width = 100, .height = 50 } },
        .{ .box = .{ .aspect_ratio = 2, .min_height = 90 }, .bounds = .{ .max_width = 200, .max_height = 50 }, .expected = .{ .width = 100, .height = 50 } },
    };
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 1);
    defer tree.deinit();
    const box = try tree.create(.{ .box = .{} });
    for (cases) |case| {
        try tree.update(box, .{ .box = case.box });
        try std.testing.expectEqual(case.expected, try tree.layout(box, case.bounds));
    }
    for ([_]f32{ 0, -1, std.math.inf(f32), std.math.nan(f32) }) |ratio|
        try std.testing.expectError(error.InvalidAspectRatio, tree.update(box, .{ .box = .{ .aspect_ratio = ratio } }));
    try tree.update(box, .{ .box = .{ .aspect_ratio = 2, .min_width = 40, .min_height = 20 } });
    try std.testing.expectError(error.AspectRatioInUnboundedAxes, tree.layout(box, .{}));
    // Extreme ratios must survive bounded corrections without f32 overflow.
    try tree.update(box, .{ .box = .{ .aspect_ratio = 1e-30 } });
    const tiny = try tree.layout(box, .{ .max_width = 1e30, .max_height = 1e30 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), tiny.width, 0.00001);
    try std.testing.expectEqual(@as(f32, 1e30), tiny.height);
    try std.testing.expectError(error.InvalidLayoutSize, tree.layout(box, .{ .max_width = 1e30 }));
    try tree.update(box, .{ .box = .{ .aspect_ratio = 1e30 } });
    const huge = try tree.layout(box, .{ .max_width = 1e30, .max_height = 1e30 });
    try std.testing.expectEqual(@as(f32, 1e30), huge.width);
    try std.testing.expectApproxEqAbs(@as(f32, 1), huge.height, 0.00001);
    try std.testing.expectError(error.InvalidLayoutSize, tree.layout(box, .{ .max_height = 1e30 }));
}

test "aspect ratio lays out one child once with padded bounds and invalidates retained geometry" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    var box: types.Box = .{ .aspect_ratio = 2, .padding = .{ .left = 3, .right = 5, .top = 7, .bottom = 11 }, .border_width = 2, .border_color = Color.rgba(0, 0, 0, 255) };
    const root = try tree.create(.{ .box = box });
    const child = try tree.create(.{ .box = .{ .width = 20, .height = 16 } });
    try tree.appendChild(root, child, .none);
    const bounds: Constraints = .{ .max_width = 180, .max_height = 200 };
    try std.testing.expectEqual(SizeF{ .width = 180, .height = 90 }, try tree.layout(root, bounds));
    try std.testing.expectEqual(SizeF{ .width = 168, .height = 68 }, try tree.nodeSize(child));
    try std.testing.expectEqual(PointF{ .x = 5, .y = 9 }, try tree.nodeOffset(child));
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(child));
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(child));
    box.alignment = .center;
    try tree.update(root, .{ .box = box });
    _ = try tree.layout(root, bounds);
    try std.testing.expectEqual(SizeF{ .width = 20, .height = 16 }, try tree.nodeSize(child));
    try std.testing.expectEqual(PointF{ .x = 79, .y = 35 }, try tree.nodeOffset(child));
    box.aspect_ratio = 3;
    try tree.update(root, .{ .box = box });
    try std.testing.expect(try tree.layoutDirty(root));
    try std.testing.expectEqual(SizeF{ .width = 180, .height = 60 }, try tree.layout(root, bounds));
    try std.testing.expectEqual(PointF{ .x = 79, .y = 20 }, try tree.nodeOffset(child));
    try std.testing.expectEqual(@as(usize, 3), try tree.layoutCount(child));
    // Removing the ratio restores ordinary intrinsic Box sizing.
    box.aspect_ratio = null;
    try tree.update(root, .{ .box = box });
    try std.testing.expectEqual(SizeF{ .width = 32, .height = 38 }, try tree.layout(root, bounds));
    try std.testing.expectEqual(PointF{ .x = 5, .y = 9 }, try tree.nodeOffset(child));
}

test "baseline rows reserve independent ascents and descents and align each wrapped run" {
    const text = @import("../../text/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{ .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 }, .bytes = @embedFile("ourokit_test_font") });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const source = try sources.acquire(.{ .utf8 = "Ag", .language = "und", .logical_size = 20, .candidates = &.{font}, .configuration_revision = 1 });
    defer sources.release(source) catch unreachable;
    // Expectations come directly from the font, not Tree's baseline reporting.
    var shaped = try (try fonts.get(font)).shape(std.testing.allocator, .{ .paragraph = "Ag", .direction = .left_to_right, .script = .latin, .language = "und", .logical_size = 20 });
    defer shaped.deinit();
    const ascent = shaped.metrics.ascender;
    const height = ascent - shaped.metrics.descender + shaped.metrics.line_gap;
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 9);
    defer tree.deinit();
    tree.attachTextCaches(&sources, &paragraphs);
    var flex: types.Flex = .{ .main_axis_size = .min, .cross_axis_alignment = .baseline, .gap = 5, .run_gap = 7 };
    const row = try tree.create(.{ .flex = flex });
    var first_box: types.Box = .{ .width = 40, .padding = .{ .top = 11, .bottom = 2 } };
    const first = try tree.create(.{ .box = first_box });
    const second = try tree.create(.{ .box = .{ .width = 50, .padding = .{ .top = 3, .bottom = 23 } } });
    const third = try tree.create(.{ .box = .{ .width = 31, .padding = .{ .top = 1, .bottom = 4 } } });
    const marker = try tree.create(.{ .box = .{ .width = 12, .height = 9 } });
    for ([_]@import("tree.zig").NodeHandle{ first, second, third }) |parent| {
        const label = try tree.create(.{ .text = .{ .source = source, .color = Color.rgba(0, 0, 0, 255) } });
        try tree.appendChild(parent, label, .none);
        try tree.appendChild(row, parent, .none);
    }
    try tree.appendChild(row, marker, .none);
    const natural = try tree.layout(row, .{});
    try std.testing.expectApproxEqAbs(height + 34, natural.height, 0.001);
    try std.testing.expectEqual(@as(f32, 148), natural.width);
    for ([_]@import("tree.zig").NodeHandle{ first, second, third, marker }, [_]f32{ 0, 8, 10, 0 }) |child, y|
        try std.testing.expectApproxEqAbs(y, (try tree.nodeOffset(child)).y, 0.001);
    try std.testing.expectApproxEqAbs(ascent + 11, (try tree.baseline(row)).?, 0.001);
    try std.testing.expectEqual(null, try tree.baseline(marker));
    const count = try tree.layoutCount(row);
    _ = try tree.layout(row, .{});
    try std.testing.expectEqual(count, try tree.layoutCount(row));
    // Tight/minimum heights leave surplus below the aligned children.
    _ = try tree.layout(row, .{ .min_height = 120 });
    try std.testing.expectEqual(@as(f32, 8), (try tree.nodeOffset(second)).y);
    _ = try tree.layout(row, .{ .max_height = 35 });
    try std.testing.expectEqual(@as(f32, 35), (try tree.nodeSize(row)).height);
    try std.testing.expectApproxEqAbs(ascent + 11, (try tree.nodeOffset(second)).y + (try tree.baseline(second)).?, 0.001);

    flex.wrap = true;
    try tree.update(row, .{ .flex = flex });
    // 40 + 5 + 50 is an exact first-run fit. Third/marker start a new run.
    _ = try tree.layout(row, .{ .max_width = 95 });
    const next_y = height + 34 + 7;
    try std.testing.expectApproxEqAbs(next_y, (try tree.nodeOffset(third)).y, 0.001);
    try std.testing.expectApproxEqAbs(next_y, (try tree.nodeOffset(marker)).y, 0.001);
    try std.testing.expectApproxEqAbs(2 * height + 46, (try tree.nodeSize(row)).height, 0.001);
    _ = try tree.layout(row, .{ .max_width = 94 });
    try std.testing.expectApproxEqAbs(height + 13 + 7, (try tree.nodeOffset(second)).y, 0.001);
    try std.testing.expectApproxEqAbs(height + 13 + 7 + 2, (try tree.nodeOffset(third)).y, 0.001);

    // A layout change must refresh the metric, unlike paint-only transforms.
    flex.wrap = false;
    try tree.update(row, .{ .flex = flex });
    first_box.padding.top = 17;
    try tree.update(first, .{ .box = first_box });
    _ = try tree.layout(row, .{});
    try std.testing.expectEqual(@as(f32, 14), (try tree.nodeOffset(second)).y);
    const before_paint = try tree.layoutCount(row);
    first_box.transform = .{ .translation = .{ .y = 10 }, .scale = 1.5 };
    try tree.update(first, .{ .box = first_box });
    _ = try tree.layout(row, .{});
    try std.testing.expectEqual(before_paint, try tree.layoutCount(row));
    try std.testing.expectApproxEqAbs(ascent + 17, (try tree.baseline(row)).?, 0.001);
    try tree.update(marker, .{ .box = .{ .width = 12, .height = 120 } });
    _ = try tree.layout(row, .{});
    try std.testing.expectEqual(@as(f32, 120), (try tree.nodeSize(row)).height);
    try std.testing.expectEqual(@as(f32, 14), (try tree.nodeOffset(second)).y);
    try std.testing.expectError(error.BaselineRequiresRow, tree.create(.{ .flex = .{ .axis = .vertical, .cross_axis_alignment = .baseline } }));
}

test "baseline metrics exclude viewports and floating content and ignore editor scroll" {
    const text = @import("../../text/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{ .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 }, .bytes = @embedFile("ourokit_test_font") });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const source = try sources.acquire(.{ .utf8 = "Ag\nAg\nAg", .language = "und", .logical_size = 18, .candidates = &.{font}, .configuration_revision = 1 });
    defer sources.release(source) catch unreachable;
    var shaped = try (try fonts.get(font)).shape(std.testing.allocator, .{ .paragraph = "Ag", .direction = .left_to_right, .script = .latin, .language = "und", .logical_size = 18 });
    defer shaped.deinit();
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 6);
    defer tree.deinit();
    tree.attachTextCaches(&sources, &paragraphs);
    var input: types.TextInput = .{
        .source = source,
        .multiline = true,
        .color = Color.rgba(0, 0, 0, 255),
        .selection_color = Color.rgba(0, 0, 0, 255),
        .caret_color = Color.rgba(0, 0, 0, 255),
        .selection_start = 8,
        .selection_end = 8,
        .caret_offset = 8,
        .show_caret = true,
    };
    const editor = try tree.create(.{ .text_input = input });
    _ = try tree.layout(editor, Constraints.tight(.{ .width = 80, .height = 24 }));
    try std.testing.expectApproxEqAbs(shaped.metrics.ascender, (try tree.baseline(editor)).?, 0.001);
    const count = try tree.layoutCount(editor);
    input.caret_offset = 0;
    input.selection_start = 0;
    input.selection_end = 0;
    try tree.update(editor, .{ .text_input = input });
    _ = try tree.layout(editor, Constraints.tight(.{ .width = 80, .height = 24 }));
    try std.testing.expectEqual(count, try tree.layoutCount(editor));
    try std.testing.expectApproxEqAbs(shaped.metrics.ascender, (try tree.baseline(editor)).?, 0.001);

    const viewport = try tree.create(.{ .scroll = .{} });
    try tree.appendChild(viewport, editor, .none);
    _ = try tree.layout(viewport, Constraints.tight(.{ .width = 80, .height = 24 }));
    try std.testing.expectEqual(null, try tree.baseline(viewport));
    _ = try tree.setScrollOffset(viewport, 12);
    try std.testing.expectEqual(null, try tree.baseline(viewport));

    const overlay = try tree.create(.{ .anchored = .{} });
    const trigger = try tree.create(.{ .box = .{ .width = 30, .height = 20 } });
    const popup = try tree.create(.{ .text = .{ .source = source, .color = Color.rgba(0, 0, 0, 255) } });
    try tree.appendChild(overlay, trigger, .none);
    try tree.appendChild(overlay, popup, .none);
    _ = try tree.layout(overlay, .{ .max_width = 200, .max_height = 200 });
    try std.testing.expectEqual(null, try tree.baseline(overlay));
    try tree.update(trigger, .{ .text = .{ .source = source, .color = Color.rgba(0, 0, 0, 255) } });
    _ = try tree.layout(overlay, .{ .max_width = 200, .max_height = 200 });
    try std.testing.expectApproxEqAbs(shaped.metrics.ascender, (try tree.baseline(overlay)).?, 0.001);
}

test "box maxima cap fill but always yield to parent constraints and invalidate cached layout" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    var box: types.Box = .{ .fill_width = true, .fill_height = true, .min_width = 31, .min_height = 17, .max_width = 97, .max_height = 43, .padding = .{ .left = 3, .right = 5, .top = 2, .bottom = 7 } };
    const root = try tree.create(.{ .box = box });
    const child = try tree.create(.{ .box = .{ .fill_width = true, .fill_height = true } });
    try tree.appendChild(root, child, .none);
    for ([_]Constraints{ .{}, .{ .max_width = 200, .max_height = 80 } }) |bounds| {
        try std.testing.expectEqual(SizeF{ .width = 97, .height = 43 }, try tree.layout(root, bounds));
        try std.testing.expectEqual(SizeF{ .width = 89, .height = 34 }, try tree.nodeSize(child));
    }
    try std.testing.expectEqual(SizeF{ .width = 120, .height = 10 }, try tree.layout(root, .{ .min_width = 120, .max_width = 150, .max_height = 10 }));
    const tight = Constraints.tight(.{ .width = 150, .height = 60 });
    try std.testing.expectEqual(SizeF{ .width = 150, .height = 60 }, try tree.layout(root, tight));
    _ = try tree.layout(root, .{});
    const count = try tree.layoutCount(root);
    _ = try tree.layout(root, .{});
    try std.testing.expectEqual(count, try tree.layoutCount(root));
    box.max_width = 71;
    box.max_height = 29;
    try tree.update(root, .{ .box = box });
    try std.testing.expect(try tree.layoutDirty(root));
    try std.testing.expectEqual(SizeF{ .width = 71, .height = 29 }, try tree.layout(root, .{}));
    try std.testing.expectEqual(count + 1, try tree.layoutCount(root));
    for ([_]types.Box{
        .{ .min_width = 2, .max_width = 1 }, .{ .height = 3, .max_height = 2 },
        .{ .max_width = -1 },                .{ .max_height = std.math.inf(f32) },
        .{ .max_width = std.math.nan(f32) },
    }) |invalid| try std.testing.expectError(error.InvalidExtent, tree.update(root, .{ .box = invalid }));
    try tree.update(root, .{ .box = .{ .fill_width = true, .max_width = 0 } });
    try std.testing.expectEqual(@as(f32, 0), (try tree.layout(root, .{})).width);
}

test "flex alignment distributes actual loose remainder without growing its tight peer" {
    for ([_]types.Axis{ .horizontal, .vertical }) |axis| {
        const horizontal = axis == .horizontal;
        var tree: Tree = undefined;
        try tree.init(std.testing.allocator, 4);
        defer tree.deinit();
        var flex: types.Flex = .{ .axis = axis, .gap = 5 };
        const root = try tree.create(.{ .flex = flex });
        const fixed = try tree.create(.{ .box = .{ .width = 20, .height = 20 } });
        const loose = try tree.create(.{ .box = .{ .width = 30, .height = 30 } });
        const tight = try tree.create(.{ .box = .{} });
        try tree.appendChild(root, fixed, .none);
        try tree.appendChild(root, loose, .{ .flex = .{ .factor = 1, .fit = .loose } });
        try tree.appendChild(root, tight, .{ .flex = .{ .factor = 3 } });
        // 230 - 20 - 10 = 200; allocations 50/150, actual 30/150.
        // The remaining 20 goes into alignment, not into the tight sibling.
        const cases = [_]struct { alignment: types.MainAxisAlignment, offsets: [3]f32 }{
            .{ .alignment = .start, .offsets = .{ 0, 25, 60 } },
            .{ .alignment = .center, .offsets = .{ 10, 35, 70 } },
            .{ .alignment = .end, .offsets = .{ 20, 45, 80 } },
            .{ .alignment = .space_between, .offsets = .{ 0, 35, 80 } },
            .{ .alignment = .space_around, .offsets = .{ 10.0 / 3.0, 35, 230.0 / 3.0 } },
            .{ .alignment = .space_evenly, .offsets = .{ 5, 35, 75 } },
        };
        for (cases) |case| {
            flex.main_axis_alignment = case.alignment;
            try tree.update(root, .{ .flex = flex });
            _ = try tree.layout(root, if (horizontal) .{ .max_width = 230 } else .{ .max_height = 230 });
            try std.testing.expectEqual(@as(f32, 150), if (horizontal) (try tree.nodeSize(tight)).width else (try tree.nodeSize(tight)).height);
            for ([_]@import("tree.zig").NodeHandle{ fixed, loose, tight }, case.offsets) |handle, expected| {
                const offset = try tree.nodeOffset(handle);
                try std.testing.expectApproxEqAbs(expected, if (horizontal) offset.x else offset.y, 0.0001);
            }
        }
        flex.main_axis_size = .min;
        try tree.update(root, .{ .flex = flex });
        const size = try tree.layout(root, if (horizontal) .{ .max_width = 230 } else .{ .max_height = 230 });
        try std.testing.expectEqual(@as(f32, 210), if (horizontal) size.width else size.height);
        try std.testing.expectEqual(PointF{}, try tree.nodeOffset(fixed));
        // Loose Flexible is still invalid on an unbounded main axis.
        try std.testing.expectError(error.FlexInUnboundedAxis, tree.layout(root, .{}));
    }
}

test "main alignment handles single empty overflowing and wrapped runs without changing line breaks" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    var flex: types.Flex = .{ .main_axis_alignment = .space_evenly, .gap = 5 };
    const root = try tree.create(.{ .flex = flex });
    try std.testing.expectEqual(SizeF{ .width = 100, .height = 0 }, try tree.layout(root, .{ .max_width = 100 }));
    const a = try tree.create(.{ .box = .{ .width = 31, .height = 11 } });
    try tree.appendChild(root, a, .none);
    _ = try tree.layout(root, .{ .max_width = 100 });
    try std.testing.expectEqual(@as(f32, 34.5), (try tree.nodeOffset(a)).x);
    flex.main_axis_alignment = .space_between;
    try tree.update(root, .{ .flex = flex });
    _ = try tree.layout(root, .{ .max_width = 100 });
    try std.testing.expectEqual(PointF{}, try tree.nodeOffset(a));
    const b = try tree.create(.{ .box = .{ .width = 64, .height = 23 } });
    const c = try tree.create(.{ .box = .{ .width = 27, .height = 9 } });
    try tree.appendChild(root, b, .none);
    try tree.appendChild(root, c, .none);
    _ = try tree.layout(root, .{ .max_width = 100 });
    try std.testing.expectEqual(@as(f32, 105), (try tree.nodeOffset(c)).x); // No negative spacing on overflow.
    flex.wrap = true;
    flex.main_axis_alignment = .end;
    flex.main_axis_size = .min;
    flex.run_gap = 7;
    try tree.update(root, .{ .flex = flex });
    _ = try tree.layout(root, .{ .max_width = 100 });
    try std.testing.expectEqual(PointF{ .x = 73, .y = 30 }, try tree.nodeOffset(c));
    _ = try tree.layout(root, .{ .max_width = 99 });
    // Widest run is 96, not the maximum 99. First run aligns within 96.
    try std.testing.expectEqual(PointF{ .x = 65, .y = 0 }, try tree.nodeOffset(a));
    try std.testing.expectEqual(PointF{ .x = 0, .y = 18 }, try tree.nodeOffset(b));
    try std.testing.expectEqual(PointF{ .x = 69, .y = 18 }, try tree.nodeOffset(c));
}

test "wrap exact boundary, overflow by one, unbounded main, and line-local alignment" {
    for ([_]types.Axis{ .horizontal, .vertical }) |axis| {
        var tree: Tree = undefined;
        try tree.init(std.testing.allocator, 4);
        defer tree.deinit();
        const horizontal = axis == .horizontal;
        const root = try tree.create(.{ .flex = .{
            .axis = axis,
            .wrap = true,
            .main_axis_size = .min,
            .gap = 5,
            .run_gap = 7,
            .cross_axis_alignment = .end,
        } });
        const a = try tree.create(.{ .box = .{ .width = if (horizontal) 31 else 11, .height = if (horizontal) 11 else 31 } });
        const b = try tree.create(.{ .box = .{ .width = if (horizontal) 64 else 23, .height = if (horizontal) 23 else 64 } });
        const d = try tree.create(.{ .box = .{ .width = if (horizontal) 27 else 9, .height = if (horizontal) 9 else 27 } });
        for ([_]@import("tree.zig").NodeHandle{ a, b, d }) |child| try tree.appendChild(root, child, .none);
        const bounds: Constraints = if (horizontal) .{ .max_width = 100 } else .{ .max_height = 100 };
        try std.testing.expectEqual(SizeF{ .width = if (horizontal) 100 else 39, .height = if (horizontal) 39 else 100 }, try tree.layout(root, bounds));
        try std.testing.expectEqual(PointF{ .x = if (horizontal) 0 else 12, .y = if (horizontal) 12 else 0 }, try tree.nodeOffset(a));
        try std.testing.expectEqual(PointF{ .x = if (horizontal) 36 else 0, .y = if (horizontal) 0 else 36 }, try tree.nodeOffset(b));
        try std.testing.expectEqual(PointF{ .x = if (horizontal) 0 else 30, .y = if (horizontal) 30 else 0 }, try tree.nodeOffset(d));
        _ = try tree.layout(root, if (horizontal) .{ .max_width = 99 } else .{ .max_height = 99 });
        // A moves onto its own run; B and D now fit together (64 + 5 + 27).
        try std.testing.expectEqual(PointF{ .x = if (horizontal) 0 else 18, .y = if (horizontal) 18 else 0 }, try tree.nodeOffset(b));
        try std.testing.expectEqual(PointF{ .x = if (horizontal) 69 else 32, .y = if (horizontal) 32 else 69 }, try tree.nodeOffset(d));
        try std.testing.expectEqual(SizeF{ .width = if (horizontal) 132 else 23, .height = if (horizontal) 23 else 132 }, try tree.layout(root, .{}));
        try std.testing.expectEqual(PointF{ .x = if (horizontal) 105 else 14, .y = if (horizontal) 14 else 105 }, try tree.nodeOffset(d));
    }
}

test "wrap stretch and fill retain finite sizing, empty runs and reject flex" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    const root = try tree.create(.{ .flex = .{ .wrap = true, .gap = 3, .run_gap = 8, .cross_axis_alignment = .stretch } });
    try std.testing.expectEqual(SizeF{ .width = 100, .height = 0 }, try tree.layout(root, .{ .max_width = 100 }));
    const a = try tree.create(.{ .box = .{ .width = 31, .height = 11 } });
    const b = try tree.create(.{ .box = .{ .width = 40, .height = 23 } });
    const fill = try tree.create(.{ .box = .{ .fill_width = true, .height = 13 } });
    try std.testing.expectError(error.FlexInWrap, tree.appendChild(root, a, .{ .flex = .{ .factor = 1 } }));
    try tree.appendChild(root, a, .none);
    try tree.appendChild(root, b, .none);
    try tree.appendChild(root, fill, .none);
    try std.testing.expectEqual(SizeF{ .width = 100, .height = 44 }, try tree.layout(root, .{ .max_width = 100 }));
    try std.testing.expectEqual(SizeF{ .width = 31, .height = 23 }, try tree.nodeSize(a));
    try std.testing.expectEqual(SizeF{ .width = 100, .height = 13 }, try tree.nodeSize(fill));
    try std.testing.expectEqual(PointF{ .x = 0, .y = 31 }, try tree.nodeOffset(fill));
    _ = try tree.layout(root, .{ .max_width = 100 });
    try std.testing.expectEqual(@as(usize, 2), try tree.layoutCount(root));
    // An oversized first item is constrained to its whole run, without an empty run.
    _ = try tree.layout(root, .{ .max_width = 20 });
    try std.testing.expectEqual(PointF{}, try tree.nodeOffset(a));
    try std.testing.expectEqual(SizeF{ .width = 20, .height = 11 }, try tree.nodeSize(a));
}

test "grid fixed auto fractional tracks use asymmetric gaps and intrinsic versus fill children" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 5);
    defer tree.deinit();
    const grid: types.Grid = .{
        .columns = try .init(&.{ .{ .fixed = 41 }, .auto, .{ .fr = 1 }, .{ .fr = 3 } }),
        .rows = try .init(&.{ .auto, .{ .fixed = 19 } }),
        .column_gap = 5,
        .row_gap = 7,
    };
    const root = try tree.create(.{ .grid = grid });
    const intrinsic = try tree.create(.{ .box = .{ .width = 29, .height = 17 } });
    const one = try tree.create(.{ .box = .{ .fill_width = true, .height = 11 } });
    const three = try tree.create(.{ .box = .{ .fill_width = true, .fill_height = true } });
    const span = try tree.create(.{ .box = .{ .fill_width = true, .fill_height = true } });
    try tree.appendChild(root, intrinsic, .{ .grid = .{ .column = 1, .row = 0 } });
    try tree.appendChild(root, one, .{ .grid = .{ .column = 2, .row = 0 } });
    try tree.appendChild(root, three, .{ .grid = .{ .column = 3, .row = 0 } });
    try tree.appendChild(root, span, .{ .grid = .{ .column = 0, .row = 1, .column_span = 2 } });
    // 245 - 41 - 29 - 15 = 160, divided 1:3 => 40 and 120.
    try std.testing.expectEqual(SizeF{ .width = 245, .height = 43 }, try tree.layout(root, .{ .max_width = 245 }));
    try std.testing.expectEqual(SizeF{ .width = 40, .height = 11 }, try tree.nodeSize(one));
    try std.testing.expectEqual(SizeF{ .width = 120, .height = 17 }, try tree.nodeSize(three));
    try std.testing.expectEqual(PointF{ .x = 125, .y = 0 }, try tree.nodeOffset(three));
    try std.testing.expectEqual(SizeF{ .width = 75, .height = 19 }, try tree.nodeSize(span));
    try std.testing.expectEqual(PointF{ .x = 0, .y = 24 }, try tree.nodeOffset(span));
    _ = try tree.layout(root, .{ .max_width = 245 });
    try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(root));
    var updated = grid;
    updated.column_gap = 9;
    try tree.update(root, .{ .grid = updated });
    try std.testing.expect(try tree.layoutDirty(root));
    _ = try tree.layout(root, .{ .max_width = 245 });
    try std.testing.expectEqual(SizeF{ .width = 37, .height = 11 }, try tree.nodeSize(one));
}

test "grid spans grow intrinsic tracks shortest-first, including unbounded fractions" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    const root = try tree.create(.{ .grid = .{
        .columns = try .init(&.{ .auto, .{ .fr = 3 }, .{ .fixed = 17 } }),
        .rows = try .init(&.{ .auto, .auto }),
        .column_gap = 4,
        .row_gap = 6,
    } });
    const span = try tree.create(.{ .box = .{ .width = 101, .height = 60 } });
    const a = try tree.create(.{ .box = .{ .width = 21, .height = 13 } });
    const b = try tree.create(.{ .box = .{ .width = 36, .height = 19 } });
    // Span declared first deliberately: one-track contributions still go first.
    try tree.appendChild(root, span, .{ .grid = .{ .column = 0, .row = 0, .column_span = 2, .row_span = 2 } });
    try tree.appendChild(root, a, .{ .grid = .{ .column = 0, .row = 0 } });
    try tree.appendChild(root, b, .{ .grid = .{ .column = 1, .row = 1 } });
    // Width deficit 101-(21+4+36)=40 => 41,56. Height deficit 60-(13+6+19)=22 => 24,30.
    try std.testing.expectEqual(SizeF{ .width = 122, .height = 60 }, try tree.layout(root, .{}));
    try std.testing.expectEqual(PointF{ .x = 45, .y = 30 }, try tree.nodeOffset(b));
    try std.testing.expectEqual(SizeF{ .width = 101, .height = 60 }, try tree.nodeSize(span));
    // In a bounded axis the fractional track has no intrinsic minimum.
    _ = try tree.layout(root, .{ .max_width = 80 });
    try std.testing.expectEqual(PointF{ .x = 101, .y = 30 }, try tree.nodeOffset(b));
    try std.testing.expectEqual(@as(f32, 0), (try tree.nodeSize(b)).width);
}

test "grid bounded fractional cells support nested flex without intrinsic probing" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .grid = .{ .columns = try .init(&.{.{ .fr = 1 }}), .rows = try .init(&.{.{ .fr = 1 }}) } });
    const flex = try tree.create(.{ .flex = .{ .cross_axis_alignment = .stretch } });
    const leaf = try tree.create(.{ .box = .{} });
    try tree.appendChild(root, flex, .{ .grid = .{ .column = 0, .row = 0 } });
    try tree.appendChild(flex, leaf, .{ .flex = .{ .factor = 1 } });
    _ = try tree.layout(root, Constraints.tight(.{ .width = 173, .height = 59 }));
    try std.testing.expectEqual(SizeF{ .width = 173, .height = 59 }, try tree.nodeSize(leaf));
}

test "grid overflow and overlap retain paint order, hit coordinates and ancestor clipping" {
    const scene = @import("../../scene/root.zig");
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    const root = try tree.create(.{ .box = .{} });
    const grid = try tree.create(.{ .grid = .{ .columns = try .init(&.{ .{ .fixed = 70 }, .{ .fixed = 40 } }), .rows = try .init(&.{.{ .fixed = 30 }}), .column_gap = 9 } });
    const back = try tree.create(.{ .box = .{ .fill_width = true, .fill_height = true, .background = Color.rgba(10, 20, 30, 255) } });
    const front = try tree.create(.{ .box = .{ .width = 17, .height = 13, .background = Color.rgba(40, 50, 60, 255) } });
    try tree.appendChild(root, grid, .none);
    try tree.appendChild(grid, back, .{ .grid = .{ .column = 1, .row = 0 } });
    try tree.appendChild(grid, front, .{ .grid = .{ .column = 1, .row = 0 } });
    _ = try tree.layout(root, Constraints.tight(.{ .width = 90, .height = 20 }));
    try std.testing.expectEqual(SizeF{ .width = 90, .height = 20 }, try tree.nodeSize(grid));
    try std.testing.expectEqual(SizeF{ .width = 40, .height = 30 }, try tree.nodeSize(back));
    // The window viewport gates hits even when inline ancestors do not clip.
    try std.testing.expect((try tree.hitTest(root, .{ .x = 93, .y = 7 })) == null);
    try std.testing.expect((try tree.hitTest(root, .{ .x = 111, .y = 24 })) == null);
    try std.testing.expectEqual(front, (try tree.hitTest(root, .{ .x = 83, .y = 7 })).?);
    try std.testing.expectEqual(back, (try tree.hitTest(root, .{ .x = 83, .y = 17 })).?);
    var commands: [4]scene.Command = undefined;
    var builder = try @import("scene_builder.zig").Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    const list = builder.displayList();
    try std.testing.expectEqual(@as(usize, 2), list.commands.len);
    try std.testing.expectEqual(@as(i32, 79), list.commands[0].solid_rectangle.bounds.x);
    try std.testing.expectEqual(@as(u32, 40), list.commands[0].solid_rectangle.bounds.width);
    try std.testing.expectEqual(@as(u32, 17), list.commands[1].solid_rectangle.bounds.width);
    try tree.update(root, .{ .box = .{ .clip = true } });
    try std.testing.expect((try tree.hitTest(root, .{ .x = 93, .y = 7 })) == null);
    try std.testing.expectEqual(front, (try tree.hitTest(root, .{ .x = 83, .y = 7 })).?);
    builder = try @import("scene_builder.zig").Builder.init(&commands, 1);
    try tree.buildScene(root, &builder);
    try std.testing.expectEqual(@as(usize, 4), builder.displayList().commands.len);
    try std.testing.expectEqual(@as(u32, 90), commands[0].push_clip_rect.width);
}

test "grid auto rows measure text at resolved width before positioning the next row" {
    const text = @import("../../text/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{ .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 }, .bytes = @embedFile("ourokit_test_font") });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const source = try sources.acquire(.{ .utf8 = "Alpha beta gamma delta epsilon zeta", .language = "und", .logical_size = 18, .candidates = &.{font}, .configuration_revision = 1 });
    defer sources.release(source) catch unreachable;
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    tree.attachTextCaches(&sources, &paragraphs);
    defer tree.deinit();
    const object: types.Object = .{ .text = .{ .source = source, .color = Color.rgba(0, 0, 0, 255) } };
    const reference = try tree.create(object);
    const root = try tree.create(.{ .grid = .{
        .columns = try .init(&.{ .{ .fixed = 37 }, .{ .fr = 1 } }),
        .rows = try .init(&.{ .auto, .{ .fixed = 19 } }),
        .column_gap = 3,
        .row_gap = 7,
    } });
    const label = try tree.create(object);
    const next = try tree.create(.{ .box = .{ .fill_width = true, .height = 19 } });
    try tree.appendChild(root, label, .{ .grid = .{ .column = 1, .row = 0 } });
    try tree.appendChild(root, next, .{ .grid = .{ .column = 0, .row = 1, .column_span = 2 } });
    var narrow_height: f32 = 0;
    for ([_]f32{ 153, 353 }) |width| {
        // Independent Text layout at known width, outside any grid.
        const expected = try tree.layout(reference, .{ .max_width = width - 40 });
        const result = try tree.layout(root, .{ .max_width = width });
        try std.testing.expectEqual(expected.height + 26, result.height);
        try std.testing.expectEqual(PointF{ .x = 0, .y = expected.height + 7 }, try tree.nodeOffset(next));
        try std.testing.expectEqual(expected, try tree.nodeSize(label));
        if (width == 153) narrow_height = result.height else try std.testing.expect(result.height < narrow_height);
    }
}

test "grid fractional rows share bounded height and become intrinsic when unbounded" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 3);
    defer tree.deinit();
    const root = try tree.create(.{ .grid = .{
        .columns = try .init(&.{.auto}),
        .rows = try .init(&.{ .{ .fixed = 17 }, .{ .fr = 2 }, .{ .fr = 3 } }),
        .row_gap = 6,
    } });
    const a = try tree.create(.{ .box = .{ .width = 23, .height = 11, .fill_height = false } });
    const b = try tree.create(.{ .box = .{ .width = 31, .min_height = 7, .fill_height = true } });
    try tree.appendChild(root, a, .{ .grid = .{ .column = 0, .row = 1 } });
    try tree.appendChild(root, b, .{ .grid = .{ .column = 0, .row = 2 } });
    // 129 - 17 - 12 = 100 => fractional heights 40 and 60.
    try std.testing.expectEqual(SizeF{ .width = 31, .height = 129 }, try tree.layout(root, .{ .max_height = 129 }));
    try std.testing.expectEqual(PointF{ .x = 0, .y = 69 }, try tree.nodeOffset(b));
    try std.testing.expectEqual(SizeF{ .width = 31, .height = 60 }, try tree.nodeSize(b));
    try std.testing.expectEqual(SizeF{ .width = 31, .height = 47 }, try tree.layout(root, .{}));
    try std.testing.expectEqual(PointF{ .x = 0, .y = 40 }, try tree.nodeOffset(b));
    try std.testing.expectEqual(SizeF{ .width = 31, .height = 7 }, try tree.nodeSize(b));
}

test "grid validates track numbers and placements before layout" {
    var tree: Tree = undefined;
    try tree.init(std.testing.allocator, 2);
    defer tree.deinit();
    var grid: types.Grid = .{ .columns = try .init(&.{.auto}), .rows = try .init(&.{.auto}) };
    for ([_]types.GridTrack{ .{ .fixed = -1 }, .{ .fixed = std.math.inf(f32) }, .{ .fr = 0 }, .{ .fr = std.math.nan(f32) } }) |invalid| {
        grid.columns.values[0] = invalid;
        try std.testing.expectError(error.InvalidGridTracks, tree.create(.{ .grid = grid }));
    }
    grid.columns.values[0] = .auto;
    const root = try tree.create(.{ .grid = grid });
    const child = try tree.create(.{ .box = .{} });
    try std.testing.expectError(error.InvalidParentData, tree.appendChild(root, child, .none));
    try std.testing.expectError(error.InvalidParentData, tree.appendChild(root, child, .{ .grid = .{ .column = 0, .row = 0, .column_span = 0 } }));
    try std.testing.expectError(error.InvalidParentData, tree.appendChild(root, child, .{ .grid = .{ .column = 0, .row = 0, .row_span = 2 } }));
    try std.testing.expectError(error.InvalidParentData, tree.appendChild(root, child, .{ .grid = .{ .column = 255, .row = 0, .column_span = 255 } }));
}
