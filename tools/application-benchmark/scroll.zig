//! A closed-loop Wayland probe, not a replacement application runner.
//! Reuses the virtual-list story, runtime input path and presentation feedback.
const std = @import("std");
const ouro = @import("ourokit");
const linux = std.os.linux;
const Sample = struct {
    input_ns: u64,
    submitted_ns: u64,
    feedback_received_ns: u64,
    offset: f32,
    timing: ouro.platform.wayland.PresentationTiming,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedStoryAndFrameCount;
    const count = try std.fmt.parseInt(usize, args[2], 10);
    if (count < 2 or count > 10000) return error.InvalidFrameCount;
    const samples = try init.arena.allocator().alloc(Sample, count);

    var loop: ouro.loop.Loop = undefined;
    try loop.init(init.gpa, 128, 32);
    defer loop.deinit();
    var scheduler: ouro.task.Scheduler = undefined;
    try scheduler.init(init.gpa, 1024, 8, 8);
    defer scheduler.deinit();
    var vm: ouro.lua.Vm = undefined;
    try vm.init(init.gpa, &scheduler, &loop);
    var signals: ouro.lua.Signals = undefined;
    try signals.initWithApi(init.gpa, vm.state, 256, 1024, 256, vm.apiReference());
    defer signals.deinit();
    defer vm.deinit();
    var fonts = ouro.text.FontCache.init(init.gpa);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "benchmark/SourceSans3-Regular.otf", .index = 0 },
        .bytes = @embedFile("benchmark_font"),
    });
    defer fonts.release(font) catch unreachable;
    var sources = ouro.text.ParagraphSourceCache.init(init.gpa, &fonts);
    defer sources.deinit();
    var paragraphs = ouro.text.ParagraphCache.init(init.gpa, &fonts);
    defer paragraphs.deinit();
    var glyphs = try ouro.renderer.software.GlyphCache.init(init.gpa, &fonts);
    defer glyphs.deinit();
    var callbacks: ouro.lua.CallbackRegistry = undefined;
    try callbacks.init(init.gpa, 256);
    defer callbacks.deinit();
    var descriptors: [256]ouro.ui.instance.Descriptor = undefined;
    var semantics: [256]ouro.ui.semantics.Descriptor = undefined;
    var ui: ouro.lua.UiBuild = undefined;
    try ui.initWithApi(vm.state, &descriptors, vm.apiReference());
    ui.attachSignals(&signals);
    ui.attachCallbacks(&callbacks, &vm);
    try ui.attachText(&sources, &.{font}, 1);
    try ui.attachMediumText(&.{font});
    try ui.attachSemantics(&semantics);
    const theme = ouro.design.tokens.light;
    ui.enableDeclarativeWidgets(theme);
    var book = try ouro.lua.Storybook.loadWithApi(init.gpa, vm.state, vm.apiReference(), @embedFile("benchmark_stories"));
    defer book.deinit();
    const story = book.find(args[1]) orelse return error.UnknownStory;

    var windows: ouro.app.windows.WindowSet = undefined;
    var host: ouro.platform.wayland.Host = undefined;
    try host.init(init.gpa, &loop, init.minimal.environ, windows.eventSink(), .{
        .app_id = "dev.ourokit.benchmark.scroll",
        .window_capacity = 1,
    });
    defer host.deinit();
    // Without feedback, a frame callback must NOT be passed off as presentation.
    if (host.presentation == null) return error.PresentationFeedbackUnavailable;
    try windows.init(init.gpa, &scheduler, host.nativeHost(), 1, 32);
    defer windows.deinit();
    try windows.reconcile(&.{.{ .toplevel = .{
        .id = "scroll",
        .title = "Ourokit scrolling benchmark",
        .initial_width = story.viewport.width,
        .initial_height = story.viewport.height,
    } }});
    const handle = windows.handleForId("scroll").?;
    var runtime: ouro.app.WindowRuntime = .{};
    try runtime.init(init.gpa, &scheduler, try windows.scope(handle), handle, theme.background, theme.primary, theme.foreground, theme.input, theme.ring, &signals, &sources, &paragraphs, .{});
    var size: ?ouro.core.SizeU = null;
    var pending = false;
    var seen: usize = 0;
    var input_ns: u64 = 0;
    var submitted_ns: u64 = 0;
    var offset: f32 = 0;

    while (seen < count) {
        if (host.failure) |failure| return failure;
        while (windows.takeEvent()) |event| switch (event) {
            .configured => |configured| {
                if (configured.width != story.viewport.width or configured.height != story.viewport.height)
                    return error.UnexpectedViewportUseFloatingCompositor;
                size = .{ .width = configured.width, .height = configured.height };
            },
            .close_requested => return error.WindowClosedDuringMeasurement,
            else => {}, // No physical input is part of this controlled probe.
        };
        if (try host.takePresentationTiming(handle)) |timing| {
            if (!pending) return error.UncorrelatedPresentation;
            samples[seen] = .{ .input_ns = input_ns, .submitted_ns = submitted_ns, .feedback_received_ns = nanoTime(), .offset = offset, .timing = timing };
            seen += 1;
            pending = false;
            if (seen == count) break;
        }
        if (size) |configured| if (!pending) {
            if (try host.outputScale(handle) != 1) return error.ExpectedScaleOne;
            try host.requestRedraw(handle);
            if (try host.acquireFrame(handle)) |acquired| {
                var frame = acquired;
                if (seen != 0) {
                    const target = try runtime.semanticTarget("people");
                    // Pointer position is set before the timed axis event.
                    try runtime.routePointer(.{ .enter = .{ .window = handle, .serial = 0, .position = target.center } });
                    try runtime.dispatchInput(&callbacks);
                    input_ns = nanoTime();
                    // Reverse every 120 events, never reach a list boundary.
                    const delta: f32 = if (((seen - 1) / 120) % 2 == 0) 24 else -24;
                    try runtime.routePointer(.{ .axis = .{ .window = handle, .time_ms = @truncate(input_ns / std.time.ns_per_ms), .axis = .vertical, .delta = delta } });
                    try runtime.dispatchInput(&callbacks);
                }
                try scheduler.applyQueuedCancellations();
                try runtime.collectRetired();
                try runtime.reconcile(configured, &ui, story.content_reference);
                try runtime.prepareFrame(1);
                const semantic = try runtime.semantics.findPath("people");
                const next_offset = try runtime.instances.scrollOffset(runtime.instances.handleForId(semantic.id).?);
                if (seen != 0 and next_offset == offset) return error.ScrollDidNotMove;
                offset = next_offset;
                var list = try runtime.displayList();
                try host.prepareFrameDamage(&frame, list.damage);
                list.damage = frame.damage();
                const target = frame.target.software;
                try ouro.renderer.software.renderResources(list, .{
                    .pixels = target.pixels,
                    .width = frame.width,
                    .height = frame.height,
                    .stride = target.stride,
                    .format = .bgra8_unorm,
                }, &glyphs, null, &paragraphs, null);
                try host.present(frame);
                submitted_ns = nanoTime();
                try runtime.frameSubmitted();
                pending = true;
            }
        };
        try host.flush();
        try host.dispatchOne(try loop.wait());
    }

    // Emit after measurement, before cleanup: a teardown failure must not erase
    // completed samples. The harness retains the process exit status separately.
    for (samples, 0..) |sample, index| {
        const t = sample.timing;
        std.debug.print("{{\"frame\":{d},\"input_ns\":{d},\"submitted_ns\":{d},\"feedback_received_ns\":{d},\"offset\":{d},\"clock_id\":{d},\"presented_ns\":{d},\"refresh_ns\":{d},\"sequence\":{d},\"vsync\":{},\"hardware_clock\":{},\"hardware_completion\":{}}}\n", .{
            index,         sample.input_ns, sample.submitted_ns,                                      sample.feedback_received_ns,
            sample.offset, t.clock_id,      @as(u128, t.seconds) * std.time.ns_per_s + t.nanoseconds, t.refresh_nanoseconds,
            t.sequence,    t.vsync,         t.hardware_clock,                                         t.hardware_completion,
        });
    }
    try runtime.clear(&ui);
    try scheduler.applyQueuedCancellations();
    try runtime.collectRetired();
    runtime.deinit();
    try windows.reconcile(&.{});
    while (windows.retainedCount() != 0) {
        while (windows.takeEvent()) |_| {}
        try scheduler.applyQueuedCancellations();
        try windows.reconcile(&.{});
        try host.flush();
        if (windows.retainedCount() != 0) try host.dispatchOne(try loop.wait());
    }
    while (windows.takeEvent()) |_| {}
    try host.beginDisconnect();
    while (!host.quiescent()) {
        try host.flush();
        if (!host.quiescent()) try host.dispatchOne(try loop.wait());
    }
}

fn nanoTime() u64 {
    var value: linux.timespec = undefined;
    std.debug.assert(linux.errno(linux.clock_gettime(.MONOTONIC, &value)) == .SUCCESS);
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
