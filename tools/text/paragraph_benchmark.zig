const std = @import("std");
const ourokit = @import("ourokit");

const iterations = 20_000;
const layout_iterations = 1_000;

const Workload = struct {
    name: []const u8,
    text: []const u8,
};

const workloads = [_]Workload{
    .{ .name = "latin", .text = "The quick brown fox jumps over the lazy dog." },
    .{ .name = "mixed", .text = "Status: جاهز — build 42 (successful)." },
    .{ .name = "isolates", .text = "LTR \u{2067}RTL 123\u{2069} tail \u{2066}nested\u{2069}." },
    .{ .name = "paragraphs", .text = "First paragraph.\r\nפסקה שנייה with Latin.\n第三段。" },
};

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").mode == .Debug)
        std.debug.print("warning: use -Doptimize=ReleaseFast for meaningful results\n", .{});
    std.debug.print("bidi analysis:\n", .{});
    for (workloads) |workload| try runBidi(init.gpa, workload);
    std.debug.print("script itemization:\n", .{});
    for (workloads) |workload| try runScripts(init.gpa, workload);
    std.debug.print("combined paragraph itemization:\n", .{});
    for (workloads) |workload| try runItemization(init.gpa, workload);
    std.debug.print("UAX #14 opportunities:\n", .{});
    for (workloads) |workload| try runLineBreaks(init.gpa, workload);
    std.debug.print("UAX #29 word boundaries:\n", .{});
    for (workloads) |workload| try runWordBreaks(init.gpa, workload);
    std.debug.print("shaped opportunity measurement:\n", .{});
    for (workloads) |workload| try runMeasurements(init.gpa, workload);
    std.debug.print("greedy selection:\n", .{});
    for (workloads) |workload| try runGreedy(init.gpa, workload);
    std.debug.print("greedy selection + line bidi:\n", .{});
    for (workloads) |workload| try runGreedyLines(init.gpa, workload);
    try runCompleteLayouts(init.gpa);
}

fn runCompleteLayouts(allocator: std.mem.Allocator) !void {
    var fonts = ourokit.text.FontCache.init(allocator);
    defer fonts.deinit();
    const latin = try fonts.acquire(.{
        .key = .{ .file = "/benchmarks/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_benchmark_font"),
    });
    defer fonts.release(latin) catch unreachable;
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/benchmarks/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_benchmark_arabic_font"),
    });
    defer fonts.release(arabic) catch unreachable;
    var paragraphs = ourokit.text.ParagraphCache.init(allocator, &fonts);
    defer paragraphs.deinit();
    const text = "Save حفظ this document, review the complete workflow, and continue to the next step.";

    std.debug.print("complete paragraph cache misses:\n", .{});
    try runCompleteLayout(
        &paragraphs,
        text,
        &.{ latin, arabic },
        .{},
        "wrapped",
    );
    try runCompleteLayout(
        &paragraphs,
        text,
        &.{ latin, arabic },
        .{ .max_lines = 2, .overflow = .ellipsis },
        "ellipsized",
    );
    try runCompleteLayout(
        &paragraphs,
        text,
        &.{ latin, arabic },
        .{ .alignment = .justify },
        "justified",
    );
}

fn runCompleteLayout(
    paragraphs: *ourokit.text.ParagraphCache,
    text: []const u8,
    candidates: []const ourokit.text.FontHandle,
    style: ourokit.text.ParagraphStyle,
    name: []const u8,
) !void {
    const started = nanoTime();
    var total_glyphs: usize = 0;
    for (0..layout_iterations) |_| {
        const handle = try paragraphs.acquire(.{
            .utf8 = text,
            .language = "und",
            .logical_size = 16,
            .max_width = 180,
            .style = style,
            .candidates = candidates,
            .configuration_revision = 1,
        });
        total_glyphs += (try paragraphs.get(handle)).positioned.glyphs.len;
        try paragraphs.release(handle);
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_glyphs);
    std.debug.print(
        "{s}: {d:.1} ns/layout ({d} iterations)\n",
        .{
            name,
            @as(f64, @floatFromInt(elapsed)) / layout_iterations,
            layout_iterations,
        },
    );
}

fn runBidi(allocator: std.mem.Allocator, workload: Workload) !void {
    var warmup = try ourokit.text.analyzeBidi(allocator, workload.text, .auto_left_to_right);
    const paragraphs_per_input = warmup.paragraphs.len;
    warmup.deinit();
    const started = nanoTime();
    var total_runs: usize = 0;
    for (0..iterations) |_| {
        var analysis = try ourokit.text.analyzeBidi(allocator, workload.text, .auto_left_to_right);
        total_runs += analysis.runs.len;
        analysis.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_runs);
    const ns_per_input = @as(f64, @floatFromInt(elapsed)) / iterations;
    const ns_per_paragraph = ns_per_input / @as(f64, @floatFromInt(paragraphs_per_input));
    const ns_per_byte = ns_per_input / @as(f64, @floatFromInt(workload.text.len));
    std.debug.print(
        "{s}: {d:.1} ns/input, {d:.1} ns/paragraph, {d:.2} ns/byte ({d} iterations)\n",
        .{ workload.name, ns_per_input, ns_per_paragraph, ns_per_byte, iterations },
    );
}

fn runScripts(allocator: std.mem.Allocator, workload: Workload) !void {
    var warmup = try ourokit.text.analyzeScripts(allocator, workload.text);
    warmup.deinit();
    const started = nanoTime();
    var total_runs: usize = 0;
    for (0..iterations) |_| {
        var analysis = try ourokit.text.analyzeScripts(allocator, workload.text);
        total_runs += analysis.runs.len;
        analysis.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_runs);
    const ns_per_input = @as(f64, @floatFromInt(elapsed)) / iterations;
    const ns_per_byte = ns_per_input / @as(f64, @floatFromInt(workload.text.len));
    std.debug.print(
        "{s}: {d:.1} ns/input, {d:.2} ns/byte ({d} iterations)\n",
        .{ workload.name, ns_per_input, ns_per_byte, iterations },
    );
}

fn runItemization(allocator: std.mem.Allocator, workload: Workload) !void {
    var warmup = try ourokit.text.itemizeParagraphs(allocator, workload.text, .auto_left_to_right);
    warmup.deinit();
    const started = nanoTime();
    var total_runs: usize = 0;
    for (0..iterations) |_| {
        var analysis = try ourokit.text.itemizeParagraphs(allocator, workload.text, .auto_left_to_right);
        total_runs += analysis.runs.len;
        analysis.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_runs);
    const ns_per_input = @as(f64, @floatFromInt(elapsed)) / iterations;
    const ns_per_byte = ns_per_input / @as(f64, @floatFromInt(workload.text.len));
    std.debug.print(
        "{s}: {d:.1} ns/input, {d:.2} ns/byte ({d} iterations)\n",
        .{ workload.name, ns_per_input, ns_per_byte, iterations },
    );
}

fn runLineBreaks(allocator: std.mem.Allocator, workload: Workload) !void {
    var warmup = try ourokit.text.analyzeLineBreaks(allocator, workload.text);
    warmup.deinit();
    const started = nanoTime();
    var total_breaks: usize = 0;
    for (0..iterations) |_| {
        var analysis = try ourokit.text.analyzeLineBreaks(allocator, workload.text);
        total_breaks += analysis.breaks.len;
        analysis.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_breaks);
    printResult(workload, elapsed);
}

fn runWordBreaks(allocator: std.mem.Allocator, workload: Workload) !void {
    var warmup = try ourokit.text.analyzeWordBreaks(allocator, workload.text);
    warmup.deinit();
    const started = nanoTime();
    var total_boundaries: usize = 0;
    for (0..iterations) |_| {
        var analysis = try ourokit.text.analyzeWordBreaks(allocator, workload.text);
        total_boundaries += analysis.boundaries.len;
        analysis.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_boundaries);
    printResult(workload, elapsed);
}

fn runGreedy(allocator: std.mem.Allocator, workload: Workload) !void {
    var opportunities = try ourokit.text.analyzeLineBreaks(allocator, workload.text);
    defer opportunities.deinit();
    const advances = try allocator.alloc(f32, opportunities.breaks.len);
    defer allocator.free(advances);
    @memset(advances, 8);
    const started = nanoTime();
    var total_lines: usize = 0;
    for (0..iterations) |_| {
        var result = try ourokit.text.wrap.greedy.wrap(
            allocator,
            opportunities.breaks,
            advances,
            120,
        );
        total_lines += result.lines.len;
        result.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_lines);
    printResult(workload, elapsed);
}

fn runMeasurements(allocator: std.mem.Allocator, workload: Workload) !void {
    var fixture = try MeasurementFixture.init(allocator, workload.text);
    defer fixture.deinit();
    const started = nanoTime();
    var total_segments: usize = 0;
    for (0..iterations) |_| {
        var measured = try ourokit.text.measureBreakSegments(
            allocator,
            fixture.opportunities.breaks,
            &fixture.shaped,
        );
        total_segments += measured.segments.len;
        measured.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_segments);
    printResult(workload, elapsed);
}

fn runGreedyLines(allocator: std.mem.Allocator, workload: Workload) !void {
    var fixture = try MeasurementFixture.init(allocator, workload.text);
    defer fixture.deinit();
    var measured = try ourokit.text.measureBreakSegments(
        allocator,
        fixture.opportunities.breaks,
        &fixture.shaped,
    );
    defer measured.deinit();
    const started = nanoTime();
    var total_lines: usize = 0;
    for (0..iterations) |_| {
        var selected = try ourokit.text.selectGreedyLines(
            allocator,
            workload.text,
            .auto_left_to_right,
            fixture.opportunities.breaks,
            &measured,
            120,
        );
        total_lines += selected.lines.len;
        selected.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_lines);
    printResult(workload, elapsed);
}

const MeasurementFixture = struct {
    allocator: std.mem.Allocator,
    glyphs: []ourokit.text.Glyph,
    spans: []ourokit.text.ShapedSpan,
    runs: []ourokit.text.ShapedItemizedRun,
    shaped: ourokit.text.ShapedParagraphs,
    opportunities: ourokit.text.LineBreakAnalysis,

    fn init(allocator: std.mem.Allocator, utf8: []const u8) !MeasurementFixture {
        var opportunities = try ourokit.text.analyzeLineBreaks(allocator, utf8);
        errdefer opportunities.deinit();
        var glyphs: std.ArrayList(ourokit.text.Glyph) = .empty;
        errdefer glyphs.deinit(allocator);
        var view = try std.unicode.Utf8View.init(utf8);
        var iterator = view.iterator();
        while (iterator.nextCodepointSlice()) |codepoint| try glyphs.append(allocator, .{
            .id = 1,
            .cluster = @intCast(@intFromPtr(codepoint.ptr) - @intFromPtr(utf8.ptr)),
            .advance = .{ .x = 8 },
            .offset = .{},
            .unsafe_to_break = false,
        });
        const owned_glyphs = try glyphs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_glyphs);
        const spans = try allocator.alloc(ourokit.text.ShapedSpan, 1);
        errdefer allocator.free(spans);
        const runs = try allocator.alloc(ourokit.text.ShapedItemizedRun, 1);
        errdefer allocator.free(runs);
        var result: MeasurementFixture = .{
            .allocator = allocator,
            .glyphs = owned_glyphs,
            .spans = spans,
            .runs = runs,
            .shaped = undefined,
            .opportunities = opportunities,
        };
        result.spans[0] = .{
            .font = .{ .slot = 1, .generation = 1 },
            .run = .{
                .allocator = allocator,
                .glyphs = result.glyphs,
                .direction = .left_to_right,
                .byte_start = 0,
                .byte_len = utf8.len,
                .advance = .{ .x = @floatFromInt(result.glyphs.len * 8) },
                .metrics = .{ .ascender = 1, .descender = 0, .line_gap = 0 },
            },
        };
        result.runs[0] = .{
            .byte_start = 0,
            .byte_len = utf8.len,
            .paragraph_start = 0,
            .paragraph_content_len = utf8.len,
            .level = 0,
            .script = .latin,
            .result = .{
                .allocator = allocator,
                .spans = result.spans,
                .logical_size = 12,
                .advance = result.spans[0].run.advance,
                .metrics = result.spans[0].run.metrics,
                .has_missing_glyphs = false,
            },
        };
        result.shaped = .{
            .allocator = allocator,
            .text_len = utf8.len,
            .candidates = &.{},
            .language = "und",
            .logical_size = 12,
            .runs = result.runs,
        };
        return result;
    }

    fn deinit(self: *MeasurementFixture) void {
        self.opportunities.deinit();
        self.allocator.free(self.runs);
        self.allocator.free(self.spans);
        self.allocator.free(self.glyphs);
        self.* = undefined;
    }
};

fn printResult(workload: Workload, elapsed: u64) void {
    const ns_per_input = @as(f64, @floatFromInt(elapsed)) / iterations;
    const ns_per_byte = ns_per_input / @as(f64, @floatFromInt(workload.text.len));
    std.debug.print(
        "{s}: {d:.1} ns/input, {d:.2} ns/byte ({d} iterations)\n",
        .{ workload.name, ns_per_input, ns_per_byte, iterations },
    );
}

fn nanoTime() u64 {
    const linux = std.os.linux;
    var value: linux.timespec = undefined;
    std.debug.assert(linux.errno(linux.clock_gettime(.MONOTONIC, &value)) == .SUCCESS);
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
