//! A compositor-free GUI scene, using the production paragraph/layout/render APIs.
const std = @import("std");
const ok = @import("ourokit");
const text = ok.text;
const Color = ok.core.Color;
const sw = ok.renderer.software;
const vk = ok.renderer.vulkan;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedOutputDirectory;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    var fonts = text.FontCache.init(init.gpa);
    defer fonts.deinit();
    var paragraphs = text.ParagraphCache.init(init.gpa, &fonts);
    defer paragraphs.deinit();
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "NotoSansArabic-2.013.ttf", .index = 0 },
        .bytes = @embedFile("arabic_font"),
    });
    defer fonts.release(arabic) catch unreachable;
    const samples = [_]struct { family: text.bundled.Family, weight: text.bundled.Weight = .regular, style: text.bundled.Style = .roman, size: f32, content: []const u8 }{
        .{ .family = .sans, .weight = .semibold, .size = 22.25, .content = "Typography workspace" },
        .{ .family = .sans, .weight = .semibold, .size = 13.5, .content = "Overview     Documents     Settings                       Save changes" },
        .{ .family = .sans, .size = 14.25, .content = "Source Sans 3 · Read, edit, and share your work. Aa fi fl 0O 1Il — ‘quotes’…" },
        .{ .family = .sans, .weight = .bold, .size = 14.25, .content = "Bold labels: Important updates · 0123456789 · @ # % & ( ) [ ] { }" },
        .{ .family = .sans, .style = .italic, .size = 14.25, .content = "Italic notes: naïve café; a\u{0301}\u{0323} e\u{0308} x\u{0302} — Save حفظ now." },
        .{ .family = .serif, .weight = .semibold, .size = 19.25, .content = "Source Serif 4 / Reading room" },
        .{ .family = .serif, .size = 16.25, .content = "The quiet art of reading rewards a steady rhythm. Letters should sit naturally\non the page, with space to breathe and details that survive a second look." },
        .{ .family = .serif, .weight = .bold, .size = 16.25, .content = "Bold: An observation—not a conclusion. “Watch the punctuation!”" },
        .{ .family = .serif, .style = .italic, .size = 16.25, .content = "Italic: À bientôt; a\u{0301}\u{0323} e\u{0308} x\u{0302}, fi fl ffi. Save حفظ now." },
        .{ .family = .monospace, .weight = .semibold, .size = 17.25, .content = "Source Code Pro / Editor" },
        .{ .family = .monospace, .size = 13.25, .content = "const position = origin + offset * scale; // 0O 1Il\nif (x < 0.0) return floor(x);             // [a-z] {42}" },
        .{ .family = .monospace, .weight = .bold, .size = 13.25, .content = "Bold: fn render() !void { try draw(1.5); }" },
        .{ .family = .monospace, .style = .italic, .size = 13.25, .content = "Italic: a\u{0301}\u{0323} e\u{0308} x\u{0302}; Ω Ж / Save حفظ now." },
    };
    const ys = [_]f32{ 24.25, 66.5, 111.25, 141.5, 171.75, 221.25, 259.5, 313.25, 345.75, 399.25, 434.5, 480.25, 508.75 };
    var layouts: [samples.len]text.ParagraphHandle = undefined;
    const sans = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(sans) catch unreachable;
    for (samples, 0..) |sample, index| {
        const font = try text.bundled.acquire(&fonts, sample.family, sample.weight, sample.style);
        defer fonts.release(font) catch unreachable;
        layouts[index] = try paragraphs.acquire(.{
            .utf8 = sample.content,
            .language = "und",
            .logical_size = sample.size,
            .max_width = 756,
            .candidates = &.{ font, sans, arabic },
            .configuration_revision = 1,
        });
    }
    defer for (layouts) |layout| paragraphs.release(layout) catch unreachable;
    var software_glyphs = try sw.GlyphCache.init(init.gpa, &fonts);
    defer software_glyphs.deinit();
    var renderer = try vk.init(init.gpa);
    defer renderer.deinit();
    var vulkan_glyphs = try vk.GlyphCache.init(init.gpa, &fonts, &renderer);
    defer vulkan_glyphs.deinit();
    for ([_]f32{ 1.5, 2.0 }) |scale| for ([_]bool{ false, true }) |dark| {
        const width: u32 = @intFromFloat(816 * scale);
        const height: u32 = @intFromFloat(558 * scale);
        const bg = if (dark) Color.rgba(24, 27, 32, 255) else Color.rgba(248, 249, 251, 255);
        const fg = if (dark) Color.rgba(231, 233, 238, 255) else Color.rgba(32, 37, 45, 255);
        var commands: std.ArrayList(ok.scene.Command) = .empty;
        defer commands.deinit(init.gpa);
        try commands.append(init.gpa, .{ .clear = bg });
        try commands.append(init.gpa, .{ .solid_rectangle = .{
            .bounds = .{ .x = 0, .y = @intFromFloat(59 * scale), .width = width, .height = @intFromFloat(34 * scale) },
            .color = if (dark) Color.rgba(43, 49, 58, 255) else Color.rgba(226, 232, 240, 255),
        } });
        for (layouts, ys) |layout, y| try commands.append(init.gpa, .{ .paragraph = .{
            .layout = layout,
            .origin = .{ .x = 28.25 * scale, .y = y * scale },
            .scale = scale,
            .color = fg,
        } });
        const list: ok.scene.DisplayList = .{ .commands = commands.items };
        const pixels = try init.gpa.alloc(u8, width * height * 4);
        defer init.gpa.free(pixels);
        try sw.renderParagraphs(list, .{ .pixels = pixels, .width = width, .height = height, .stride = width * 4, .format = .rgba8_unorm }, &software_glyphs, &paragraphs);
        try save(init, args[1], "software", scale, dark, width, height, pixels);
        var target = try vk.Target.init(&renderer, width, height);
        defer target.deinit(&renderer);
        try renderer.renderParagraphs(list, &target, &vulkan_glyphs, &paragraphs);
        const actual = try init.gpa.alloc(u8, pixels.len);
        defer init.gpa.free(actual);
        try target.readPixels(actual, width * 4, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, pixels, actual);
        try save(init, args[1], "vulkan-compute", scale, dark, width, height, actual);
    };
}

fn save(init: std.process.Init, directory: []const u8, backend: []const u8, scale: f32, dark: bool, width: u32, height: u32, pixels: []u8) !void {
    const srgb = try init.gpa.alloc(u8, pixels.len);
    defer init.gpa.free(srgb);
    for (0..width * height) |index| {
        const offset = index * 4;
        srgb[offset..][0..4].* = ok.core.gamma22ToStraightSrgba8(.{
            .r = pixels[offset],
            .g = pixels[offset + 1],
            .b = pixels[offset + 2],
            .a = pixels[offset + 3],
        });
    }
    const bytes = try ok.renderer.png.encode(init.gpa, srgb, width, height, width * 4);
    defer init.gpa.free(bytes);
    const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}-{d}-{s}.png", .{ directory, backend, @as(u32, @intFromFloat(scale * 100)), if (dark) "dark" else "light" });
    defer init.gpa.free(path);
    var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, bytes);
    std.debug.print("{s}\n", .{path});
}
