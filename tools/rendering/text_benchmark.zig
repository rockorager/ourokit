//! CPU raster profile of a Folio-sized editor: 960x760, 680px prose, 23px text.
//! Raster timings exclude shaping/layout (reported separately for typing),
//! Lua, Wayland, and compositor latency.
const std = @import("std");
const ouro = @import("ourokit");
const software = ouro.renderer.software;
const Mode = enum { blank, warm, scroll, fractional, caret, typing };
const prose = "The morning light fell across the open book. Outside, the street was quiet; " ++
    "inside, a reader paused to write a few words in the margin. " ++
    "Small details make a page worth returning to.\n\n";

pub fn main(init: std.process.Init) !void {
    if (!software.has_freetype) @compileError("bench-software-text requires FreeType");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 5) return error.ExpectedModeFramesParagraphsScale;
    const mode: ?Mode = if (args.len > 1 and !std.mem.eql(u8, args[1], "all"))
        std.meta.stringToEnum(Mode, args[1]) orelse return error.UnknownMode
    else
        null;
    const frames = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 120;
    const repeats = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 128;
    const scale = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 1;
    if (frames == 0 or frames > 100000 or repeats == 0 or repeats > 4096 or scale == 0 or scale > 4)
        return error.InvalidWorkloadSize;
    std.debug.print("software text ({s}), {d}x{d}, Inter 23px, {d} frames\n", .{
        @tagName(@import("builtin").mode), 960 * scale, 760 * scale, frames,
    });
    if (@import("builtin").mode == .Debug) std.debug.print("warning: use ReleaseFast for profiling\n", .{});
    const allocator = init.gpa;
    var fonts = ouro.text.FontCache.init(allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/benchmarks/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_benchmark_font"),
    });
    defer fonts.release(font) catch unreachable;
    var paragraphs = ouro.text.ParagraphCache.init(allocator, &fonts);
    defer paragraphs.deinit();
    if (mode == .typing) return typing(allocator, &fonts, &paragraphs, font, frames, scale);
    const bytes = try allocator.alloc(u8, prose.len * repeats);
    defer allocator.free(bytes);
    for (0..repeats) |i| @memcpy(bytes[i * prose.len ..][0..prose.len], prose);
    const layout = try paragraphs.acquire(.{
        .utf8 = bytes,
        .language = "en",
        .logical_size = 23,
        .max_width = 680,
        .include_caret_stops = true,
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    defer paragraphs.release(layout) catch unreachable;
    const positioned = &(try paragraphs.get(layout)).positioned;
    std.debug.print("layout: {d} bytes, {d} lines, {d} glyphs (not timed)\n", .{ bytes.len, positioned.lines.len, positioned.glyphs.len });
    const pixels = try allocator.alloc(u8, 960 * 760 * scale * scale * 4);
    defer allocator.free(pixels);
    // Match the native runner's persistent, page-allocated working storage.
    var scratch: software.Scratch = .{};
    defer scratch.deinit(std.heap.page_allocator);
    const target: software.Target = .{
        .pixels = pixels,
        .width = 960 * scale,
        .height = 760 * scale,
        .stride = 960 * scale * 4,
        .format = .bgra8_unorm,
        .scratch = &scratch,
    };
    inline for (std.meta.tags(Mode)) |candidate| {
        if (candidate == .typing) {
            if (mode == null) try typing(allocator, &fonts, &paragraphs, font, frames, scale);
        } else if (mode == null or mode.? == candidate)
            try measure(allocator, &fonts, &paragraphs, layout, target, scale, frames, candidate);
    }
}

fn measure(
    allocator: std.mem.Allocator,
    fonts: *ouro.text.FontCache,
    paragraphs: *ouro.text.ParagraphCache,
    layout: ouro.text.ParagraphHandle,
    target: software.Target,
    scale: u32,
    frames: usize,
    mode: Mode,
) !void {
    var glyphs = try software.GlyphCache.init(allocator, fonts);
    defer glyphs.deinit();
    const s: f32 = @floatFromInt(scale);
    var commands = [_]ouro.scene.Command{
        .{ .clear = .rgba(247, 245, 240, 255) },
        .{ .push_clip_rect = .{ .x = @intCast(140 * scale), .y = @intCast(50 * scale), .width = 680 * scale, .height = 660 * scale } },
        .{ .paragraph = .{ .layout = layout, .origin = .{ .x = 140 * s, .y = 50 * s }, .scale = s, .color = .rgba(35, 31, 28, 255) } },
        .pop_clip,
    };
    var list: ouro.scene.DisplayList = .{ .commands = if (mode == .blank) commands[0..1] else &commands };
    const cold_start = nanoTime();
    try software.renderParagraphs(list, target, &glyphs, paragraphs);
    const cold_ns = nanoTime() - cold_start;
    const reference = try allocator.dupe(u8, target.pixels);
    defer allocator.free(reference);
    // Cold and warm paths must produce identical pixels and actual visible ink.
    try software.renderParagraphs(list, target, &glyphs, paragraphs);
    try std.testing.expectEqualSlices(u8, reference, target.pixels);
    var ink: usize = 0;
    for (0..target.height) |y| for (0..target.width) |x| {
        const p = target.pixels[y * target.stride + x * 4 ..][0..4];
        if (p[0] < 128 and p[1] < 128 and p[2] < 128) ink += 1;
    };
    if (mode != .blank and ink == 0) return error.NoVisibleText;
    if (mode == .blank and ink != 0) return error.UnexpectedInk;

    // Synthetic caret-sized damage, not a claim about runtime damage policy.
    const damage = [_]ouro.core.RectI{.{ .x = @intCast(173 * scale), .y = @intCast(57 * scale), .width = 2 * scale, .height = 27 * scale }};
    if (mode == .caret) {
        list.damage = .{ .regions = &damage };
        @memset(target.pixels, 0xA5);
        try software.renderParagraphs(list, target, &glyphs, paragraphs);
        // Inside damage matches a full render; outside must remain untouched.
        for (0..target.height) |y| for (0..target.width) |x| {
            const offset = y * target.stride + x * 4;
            const inside = x >= 173 * scale and x < 175 * scale and y >= 57 * scale and y < 84 * scale;
            if (inside) {
                try std.testing.expectEqualSlices(u8, reference[offset..][0..4], target.pixels[offset..][0..4]);
            } else if (!std.mem.allEqual(u8, target.pixels[offset..][0..4], 0xA5)) return error.ModifiedUndamagedPixel;
        };
        @memcpy(target.pixels, reference);
    }

    const samples = try allocator.alloc(u64, frames);
    defer allocator.free(samples);
    const entries_before = glyphs.glyphs.count();
    var total: u64 = 0;
    for (samples, 0..) |*sample, frame| {
        // Cycle through 120 offsets (120px integer / 30px fractional). This
        // exposes subpixel phase churn rather than conflating it with layout.
        if (mode == .scroll or mode == .fractional) {
            const step: f32 = if (mode == .fractional) 0.25 else 1;
            commands[2].paragraph.origin.y = 50 * s - @as(f32, @floatFromInt(frame % 120 + 1)) * step * s;
        }
        const start = nanoTime();
        try software.renderParagraphs(list, target, &glyphs, paragraphs);
        sample.* = nanoTime() - start;
        total += sample.*;
        std.mem.doNotOptimizeAway(target.pixels);
    }
    if ((mode == .scroll or mode == .fractional) and std.mem.eql(u8, reference, target.pixels))
        return error.ScrollDidNotChangePixels;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    std.debug.print("{s}: cold {d:.3} ms; mean {d:.3}, p50 {d:.3}, p95 {d:.3} ms; glyph entries {d}->{d}, {d} KiB\n", .{
        @tagName(mode),                                                         @as(f64, @floatFromInt(cold_ns)) / 1e6,
        @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(frames)) / 1e6, @as(f64, @floatFromInt(samples[frames / 2])) / 1e6,
        @as(f64, @floatFromInt(samples[frames * 95 / 100])) / 1e6,              entries_before,
        glyphs.glyphs.count(),                                                  glyphs.pixel_bytes / 1024,
    });
}

// Real retained editor updates starting empty and holding "k". Compare the
// former clip damage/temporary buffer policy against ink damage/reused storage.
// Both consume identical scenes; shaping is timed separately and shared.
fn typing(allocator: std.mem.Allocator, fonts: *ouro.text.FontCache, paragraphs: *ouro.text.ParagraphCache, font: ouro.text.FontHandle, frames: usize, scale: u32) !void {
    const render = ouro.ui.render_object;
    var sources = ouro.text.ParagraphSourceCache.init(allocator, fonts);
    defer sources.deinit();
    var session = try ouro.ui.text_input.Session.initWithMode(allocator, "", true);
    defer session.deinit();
    var tree: render.Tree = undefined;
    try tree.init(allocator, 1);
    tree.attachTextCaches(&sources, paragraphs);
    defer tree.deinit();
    const source = try sources.acquire(.{ .utf8 = "", .language = "en", .logical_size = 23, .candidates = &.{font}, .configuration_revision = 1 });
    var object: render.types.Object = .{ .text_input = .{
        .source = source,
        .multiline = true,
        .color = .rgba(35, 31, 28, 255),
        .caret_color = .rgba(20, 90, 150, 255),
        .selection_color = .rgba(20, 90, 150, 100),
        .selection_start = 0,
        .selection_end = 0,
        .caret_offset = 0,
        .show_caret = true,
        .reveal_caret = true,
    } };
    const node = try tree.create(object);
    try sources.release(source);
    var old_tracker = try ouro.scene.DamageTracker.init(allocator, 16);
    defer old_tracker.deinit();
    var new_tracker = try ouro.scene.DamageTracker.init(allocator, 16);
    defer new_tracker.deinit();
    var old_glyphs = try software.GlyphCache.init(allocator, fonts);
    defer old_glyphs.deinit();
    var new_glyphs = try software.GlyphCache.init(allocator, fonts);
    defer new_glyphs.deinit();
    var old_resolver: software.ParagraphBounds = .{ .glyphs = &old_glyphs, .paragraphs = paragraphs };
    old_tracker.paragraph_bounds = .{ .context = &old_resolver, .resolve = software.ParagraphBounds.resolve };
    var resolver: software.ParagraphBounds = .{ .glyphs = &new_glyphs, .paragraphs = paragraphs };
    new_tracker.paragraph_bounds = .{ .context = &resolver, .resolve = software.ParagraphBounds.resolve, .snapshot = software.ParagraphBounds.snapshot };
    var scratch: software.Scratch = .{};
    defer scratch.deinit(std.heap.page_allocator);
    var old_scratch: software.Scratch = .{};
    defer old_scratch.deinit(std.heap.page_allocator);
    const old_pixels = try allocator.alloc(u8, 960 * 760 * scale * scale * 4);
    defer allocator.free(old_pixels);
    const new_pixels = try allocator.alloc(u8, old_pixels.len);
    defer allocator.free(new_pixels);
    const target: software.Target = .{ .pixels = old_pixels, .width = 960 * scale, .height = 760 * scale, .stride = 960 * scale * 4, .format = .bgra8_unorm, .scratch = &old_scratch };
    var new_target = target;
    new_target.pixels = new_pixels;
    new_target.scratch = &scratch;
    const viewport: ouro.core.RectI = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
    var totals = [_]u64{0} ** 3;
    var areas = [_]u64{0} ** 2;
    // Frame zero establishes the empty document and warms both framebuffers.
    for (0..frames + 1) |frame| {
        const start = nanoTime();
        if (frame != 0) {
            if (!try session.typeText("k")) return error.EditDidNotChange;
            const next = try sources.acquire(.{ .utf8 = session.model.text(), .language = "en", .logical_size = 23, .candidates = &.{font}, .configuration_revision = 1 });
            object.text_input.source = next;
            object.text_input.caret_offset = session.model.selection.extent;
            object.text_input.selection_start = session.model.selection.extent;
            object.text_input.selection_end = session.model.selection.extent;
            try tree.update(node, object);
            try sources.release(next);
        }
        _ = try tree.layout(node, .tight(.{ .width = 680, .height = 660 }));
        var commands: [16]ouro.scene.Command = undefined;
        var builder = try render.Builder.init(&commands, @floatFromInt(scale));
        try builder.clear(.rgba(247, 245, 240, 255));
        builder.transform.translation = .{ .x = @floatFromInt(140 * scale), .y = @floatFromInt(50 * scale) };
        try tree.buildScene(node, &builder);
        if (frame != 0) totals[0] += nanoTime() - start;
        // Alternate execution order so neither path always gets the warm CPU.
        for (0..2) |pass| {
            const which = (frame + pass) % 2;
            const tracker = if (which == 0) &old_tracker else &new_tracker;
            const began = nanoTime();
            const damage = try tracker.compare(commands[0..builder.count], viewport);
            try software.renderParagraphs(.{ .commands = commands[0..builder.count], .damage = damage }, if (which == 0) target else new_target, if (which == 0) &old_glyphs else &new_glyphs, paragraphs);
            if (frame != 0) {
                totals[which + 1] += nanoTime() - began;
                switch (damage) {
                    .full => areas[which] += @as(u64, viewport.width) * viewport.height,
                    .regions => |regions| for (regions) |region| {
                        areas[which] += @as(u64, region.width) * region.height;
                    },
                }
            }
            tracker.submitted();
        }
        // Checks are outside all timed sections.
        try std.testing.expectEqualSlices(u8, old_pixels, new_pixels);
    }
    const divisor = @as(f64, @floatFromInt(frames));
    std.debug.print("typing {d} keys: edit/layout/scene {d:.3} ms; damage+render paragraph {d:.3} -> line {d:.3} ms; mean damaged pixels {d} -> {d}; identical pixels\n", .{
        frames,                                             @as(f64, @floatFromInt(totals[0])) / divisor / 1e6,
        @as(f64, @floatFromInt(totals[1])) / divisor / 1e6, @as(f64, @floatFromInt(totals[2])) / divisor / 1e6,
        areas[0] / frames,                                  areas[1] / frames,
    });
}

fn nanoTime() u64 {
    const linux = std.os.linux;
    var value: linux.timespec = undefined;
    std.debug.assert(linux.errno(linux.clock_gettime(.MONOTONIC, &value)) == .SUCCESS);
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
