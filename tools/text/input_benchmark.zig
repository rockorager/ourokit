//! Headless text-input CPU profile; excludes Lua callbacks, rasterization,
//! compositor scheduling, and presentation latency. Run in ReleaseFast.
const std = @import("std");
const ourokit = @import("ourokit");
const text = ourokit.text;
const input = ourokit.ui.text_input;
const render = ourokit.ui.render_object;
const Workload = enum { alternating, growing, right };

pub fn main(init: std.process.Init) !void {
    std.debug.print("text input ({s}); times in microseconds/operation\n", .{@tagName(@import("builtin").mode)});
    // Never fails; records Zig allocations (not allocations inside C libraries).
    var counter = std.testing.FailingAllocator.init(init.gpa, .{});
    const allocator = counter.allocator();
    var fonts = text.FontCache.init(allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/benchmarks/Inter-Regular.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_benchmark_font"),
    });
    defer fonts.release(font) catch unreachable;
    var sources = text.ParagraphSourceCache.init(allocator, &fonts);
    defer sources.deinit();
    var paragraphs = text.ParagraphCache.init(allocator, &fonts);
    defer paragraphs.deinit();

    // One unreported warmup for font/shaper initialization.
    try edits(&counter, &sources, &paragraphs, font, 32, 32, false, .alternating, false);
    std.debug.print("workload bytes operations | edit sync layout scene | total p50 p95\n", .{});
    for ([_]usize{ 32, 256, 1024, 4096, 16384 }) |length| {
        try edits(&counter, &sources, &paragraphs, font, length, 200, false, .alternating, true);
        try edits(&counter, &sources, &paragraphs, font, length, 200, true, .alternating, true);
    }
    // Unlike fixed-size insert/backspace pairs, this models holding one key.
    try edits(&counter, &sources, &paragraphs, font, 0, 4096, false, .growing, true);
    try edits(&counter, &sources, &paragraphs, font, 4096, 4096, false, .right, true);

    std.debug.print("cold paragraph layout: bytes | no carets / carets (us)\n", .{});
    for ([_]usize{ 256, 1024, 4096, 16384 }) |length| {
        const bytes = try init.gpa.alloc(u8, length);
        defer init.gpa.free(bytes);
        @memset(bytes, 'a');
        var times: [2]f64 = undefined;
        for ([_]bool{ false, true }, 0..) |carets, index| {
            const started = nanoTime();
            for (0..50) |_| {
                const handle = try paragraphs.acquire(.{
                    .utf8 = bytes,
                    .language = "und",
                    .logical_size = 16,
                    .max_width = std.math.floatMax(f32),
                    .include_caret_stops = carets,
                    .candidates = &.{font},
                    .configuration_revision = 1,
                });
                // Last release evicts the layout: every iteration is a miss.
                try paragraphs.release(handle);
            }
            times[index] = @as(f64, @floatFromInt(nanoTime() - started)) / 50_000;
        }
        std.debug.print("{d}: {d:.2} / {d:.2}\n", .{ length, times[0], times[1] });
    }
    std.debug.print("isolated stages (us): bytes wrapped | words itemize shape breaks measure select position\n", .{});
    for ([_]usize{ 4096, 16384 }) |length| {
        try layoutStages(init.gpa, .{ .handle = font, .cache = &fonts }, length, false);
        try layoutStages(init.gpa, .{ .handle = font, .cache = &fonts }, length, true);
    }
}

// Public stage helpers rebuild their own bidi context. These diagnostic times
// are not additive with the integrated paragraph-cache timings above.
fn layoutStages(allocator: std.mem.Allocator, candidate: text.FallbackCandidate, length: usize, wrapped: bool) !void {
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = if (wrapped and i % 8 == 7) ' ' else 'a';
    var totals = [_]u64{0} ** 7;
    for (0..50) |_| {
        var timestamps: [8]u64 = undefined;
        timestamps[0] = nanoTime();
        var words = try text.analyzeWordBreaks(allocator, bytes);
        defer words.deinit();
        timestamps[1] = nanoTime();
        var itemized = try text.itemizeParagraphs(allocator, bytes, .auto_left_to_right);
        defer itemized.deinit();
        timestamps[2] = nanoTime();
        var shaped = try text.shapeItemizedParagraphs(allocator, bytes, &itemized, &.{candidate}, "und", 16);
        defer shaped.deinit();
        timestamps[3] = nanoTime();
        var breaks = try text.analyzeLineBreaks(allocator, bytes);
        defer breaks.deinit();
        timestamps[4] = nanoTime();
        var measured = try text.measureBreakSegments(allocator, breaks.breaks, &shaped);
        defer measured.deinit();
        timestamps[5] = nanoTime();
        var selected = try text.selectGreedyLines(allocator, bytes, .auto_left_to_right, breaks.breaks, &measured, if (wrapped) 399 else std.math.floatMax(f32));
        defer selected.deinit();
        timestamps[6] = nanoTime();
        var positioned = try text.positionLines(allocator, bytes, &shaped, &selected);
        defer positioned.deinit();
        std.mem.doNotOptimizeAway(positioned.carets.len);
        timestamps[7] = nanoTime();
        for (&totals, 0..) |*total, i| total.* += timestamps[i + 1] - timestamps[i];
    }
    std.debug.print("{d} {} |", .{ length, wrapped });
    for (totals) |total| std.debug.print(" {d:.2}", .{@as(f64, @floatFromInt(total)) / 50_000});
    std.debug.print("\n", .{});
}

fn edits(
    counter: *std.testing.FailingAllocator,
    sources: *text.ParagraphSourceCache,
    paragraphs: *text.ParagraphCache,
    font: text.FontHandle,
    length: usize,
    iterations: usize,
    multiline: bool,
    workload: Workload,
    report: bool,
) !void {
    const allocator = counter.allocator();
    const initial = try allocator.alloc(u8, length);
    defer allocator.free(initial);
    // Repeated characters exercise an unbroken held-key run; multiline uses
    // spaces so wrapping is exercised rather than one overflowing word.
    const typed = if (workload == .alternating) "a" else "k";
    for (initial, 0..) |*byte, i| byte.* = if (multiline and i % 8 == 7) ' ' else typed[0];
    var session = try input.Session.initWithMode(allocator, initial, multiline);
    defer session.deinit();
    const initial_caret = if (workload == .right) 0 else length;
    _ = try session.model.setSelection(.collapsed(initial_caret));
    var tree: render.Tree = undefined;
    try tree.init(allocator, 1);
    tree.attachTextCaches(sources, paragraphs);
    defer tree.deinit();
    const source = try sources.acquire(.{
        .utf8 = initial,
        .language = "und",
        .logical_size = 16,
        .candidates = &.{font},
        .configuration_revision = 1,
    });
    var object: render.types.Object = .{ .text_input = .{
        .source = source,
        .color = .rgba(0, 0, 0, 255),
        .selection_color = .rgba(0, 0, 255, 100),
        .caret_color = .rgba(0, 0, 0, 255),
        .caret_offset = initial_caret,
        .selection_start = initial_caret,
        .selection_end = initial_caret,
        .show_caret = true,
        .reveal_caret = true,
        .multiline = multiline,
    } };
    const node = blk: {
        defer sources.release(source) catch unreachable;
        break :blk try tree.create(object);
    };
    const constraints: ourokit.ui.layout.Constraints = .{ .max_width = 400, .max_height = 160 };
    _ = try tree.layout(node, constraints);
    const samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);
    var stages = [_]u64{ 0, 0, 0, 0 };
    var allocations = [_]usize{0} ** 4;
    var allocated_bytes = [_]usize{0} ** 4;
    for (samples, 0..) |*sample, i| {
        var counts: [5]usize = undefined;
        var bytes: [5]usize = undefined;
        counts[0] = counter.allocations;
        bytes[0] = counter.allocated_bytes;
        const start = nanoTime();
        const changed = switch (workload) {
            .growing => try session.typeText(typed),
            .alternating => if (i % 2 == 0) try session.typeText(typed) else try session.model.deleteBackward(),
            .right => blk: {
                const current = session.model.selection;
                const next = try tree.textVisualNeighbor(node, current.extent, current.extent_affinity, .right);
                break :blk try session.model.setSelection(.collapsedAt(next.byte_offset, next.affinity));
            },
        };
        if (!changed) return error.EditDidNotChange;
        const edited = nanoTime();
        counts[1] = counter.allocations;
        bytes[1] = counter.allocated_bytes;
        var presentation = try input.buildPresentation(allocator, &session);
        const next = try sources.acquire(.{
            .utf8 = presentation.text,
            .language = "und",
            .logical_size = 16,
            .candidates = &.{font},
            .configuration_revision = 1,
        });
        object.text_input.source = next;
        object.text_input.caret_offset = presentation.caret_offset;
        object.text_input.caret_affinity = presentation.caret_affinity;
        object.text_input.selection_start = presentation.selection.start;
        object.text_input.selection_end = presentation.selection.end;
        try tree.update(node, object);
        try sources.release(next);
        presentation.deinit();
        const synced = nanoTime();
        counts[2] = counter.allocations;
        bytes[2] = counter.allocated_bytes;
        _ = try tree.layout(node, constraints);
        const laid_out = nanoTime();
        counts[3] = counter.allocations;
        bytes[3] = counter.allocated_bytes;
        var commands: [16]ourokit.scene.Command = undefined;
        var builder = try render.Builder.init(&commands, 1);
        try tree.buildScene(node, &builder);
        std.mem.doNotOptimizeAway(builder.count);
        const painted = nanoTime();
        counts[4] = counter.allocations;
        bytes[4] = counter.allocated_bytes;
        for (0..4) |stage| {
            allocations[stage] += counts[stage + 1] - counts[stage];
            allocated_bytes[stage] += bytes[stage + 1] - bytes[stage];
        }
        stages[0] += edited - start;
        stages[1] += synced - edited;
        stages[2] += laid_out - synced;
        stages[3] += painted - laid_out;
        sample.* = painted - start;
    }
    // Validate actual edits and caret geometry, not just successful execution.
    const expected = if (workload == .growing) length + iterations else length;
    const expected_caret = if (workload == .right) iterations else expected;
    if (session.model.text().len != expected or session.model.selection.extent != expected_caret)
        return error.UnexpectedText;
    if (!std.mem.eql(u8, session.model.text()[0..length], initial)) return error.UnexpectedText;
    if (!std.mem.allEqual(u8, session.model.text()[length..], typed[0])) return error.UnexpectedText;
    if (workload == .right and try tree.layoutCount(node) != 1) return error.UnexpectedRelayout;
    const caret = try tree.textCaretRectangle(node);
    if (caret.x < -0.01 or caret.x + caret.width > 400.01 or
        caret.y < -0.01 or caret.y + caret.height > 160.01) return error.CaretOutsideViewport;
    if (!report) return;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var us: [4]f64 = undefined;
    var total: u64 = 0;
    for (stages, 0..) |ns, i| {
        us[i] = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations * 1000));
        total += ns;
    }
    std.debug.print("{s} {d} {d} | {d:.2} {d:.2} {d:.2} {d:.2} | {d:.2} {d:.2} {d:.2}\n", .{
        if (workload == .growing) "grow-k" else if (workload == .right) "right-k" else if (multiline) "wrapped" else "single",
        length,
        iterations,
        us[0],
        us[1],
        us[2],
        us[3],
        @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(iterations * 1000)),
        @as(f64, @floatFromInt(samples[iterations / 2])) / 1000,
        @as(f64, @floatFromInt(samples[iterations * 95 / 100])) / 1000,
    });
    std.debug.print("  allocations/op, KiB/op (edit sync layout scene):", .{});
    for (allocations, allocated_bytes) |count, bytes| std.debug.print(" {d:.1}/{d:.1}", .{
        @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(iterations)),
        @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(iterations * 1024)),
    });
    std.debug.print("\n", .{});
}

fn nanoTime() u64 {
    const linux = std.os.linux;
    var value: linux.timespec = undefined;
    std.debug.assert(linux.errno(linux.clock_gettime(.MONOTONIC, &value)) == .SUCCESS);
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
