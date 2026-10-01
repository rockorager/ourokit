//! Matched CPU-side frame work on real Wayland Vulkan, paced by frame callbacks.
//! State mutation and buffer acquisition are outside build/submit wall timing.
const std = @import("std");
const ouro = @import("ourokit");
const linux = std.os.linux;

const Sample = struct {
    build_ns: u64,
    submit_ns: u64,
    submitted_ns: u64,
    offset: f32,
    nodes: usize,
    commands: usize,
    layouts: u64,
    first_row: usize,
    first_value: usize,
    row_height: f32,
    retained: ?RetainedSample = null,
};

const RetainedSample = struct {
    mutation_ns: u64,
    maintenance_ns: u64,
    acquisition_ns: u64,
    root_calls: u64,
    row_calls: u64,
    builds: u64,
    paints: u64,
    lua_heap_bytes: u64,
    source_entries: usize,
    paragraph_entries: usize,
    source_index_capacity: usize,
    paragraph_index_capacity: usize,
    source_slabs: usize,
    paragraph_slabs: usize,
    retiring_instances: usize,
    checked_rows: usize,
    stable_handles: usize,
    changed_value: usize,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 and args.len != 5) return error.ExpectedProfileFrameCountAndOptionalHold;
    const profile = args[1];
    const scrolling = std.mem.eql(u8, profile, "scroll");
    const relayout = std.mem.eql(u8, profile, "relayout");
    const sustained = std.mem.eql(u8, profile, "sustained-scroll");
    const churn = std.mem.eql(u8, profile, "keyed-churn");
    const sparse = std.mem.eql(u8, profile, "sparse-parent") or std.mem.eql(u8, profile, "sparse-leaf");
    const retained = sustained or churn or sparse;
    if (!retained and !scrolling and !relayout and !std.mem.eql(u8, profile, "rebuild")) return error.InvalidProfile;
    const count = try std.fmt.parseInt(usize, args[2], 10);
    if (count == 0 or count > 10000) return error.InvalidFrameCount;
    var hold_ms: u64 = 0;
    if (args.len == 5) {
        if (!std.mem.eql(u8, args[3], "--hold-ms")) return error.UnknownArgument;
        hold_ms = try std.fmt.parseInt(u64, args[4], 10);
        if (hold_ms > 60000) return error.InvalidHoldDuration;
    }
    const samples = try init.arena.allocator().alloc(Sample, count);
    // Fault in sample storage before measuring: filling it must not masquerade
    // as gradually growing application memory in the sustained probes.
    @memset(std.mem.sliceAsBytes(samples), 0);
    var previous_handles: [1000]ouro.ui.instance.InstanceHandle = undefined;
    var current_handles: [1000]ouro.ui.instance.InstanceHandle = undefined;
    var previous_base: usize = 0;
    var loop: ouro.loop.Loop = undefined;
    try loop.init(init.gpa, 128, 32);
    defer loop.deinit();
    var scheduler: ouro.task.Scheduler = undefined;
    try scheduler.init(init.gpa, 8192, 32, 32);
    defer scheduler.deinit();
    var vm: ouro.lua.Vm = undefined;
    try vm.init(init.gpa, &scheduler, &loop);
    var signals: ouro.lua.Signals = undefined;
    try signals.initWithApi(init.gpa, vm.state, 256, 8192, 256, vm.apiReference());
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
    var renderer = try ouro.renderer.vulkan.init(init.gpa);
    defer renderer.deinit();
    var glyphs = try ouro.renderer.vulkan.GlyphCache.init(init.gpa, &fonts, &renderer);
    defer glyphs.deinit();
    var callbacks: ouro.lua.CallbackRegistry = undefined;
    try callbacks.init(init.gpa, 256);
    defer callbacks.deinit();
    const descriptors = try init.arena.allocator().alloc(ouro.ui.instance.Descriptor, 8192);
    const semantics = try init.arena.allocator().alloc(ouro.ui.semantics.Descriptor, 8192);
    var ui: ouro.lua.UiBuild = undefined;
    try ui.initWithApi(vm.state, descriptors, vm.apiReference());
    ui.attachSignals(&signals);
    ui.attachCallbacks(&callbacks, &vm);
    try ui.attachText(&sources, &.{font}, 1);
    try ui.attachMediumText(&.{font});
    try ui.attachSemantics(semantics);
    const theme = ouro.design.tokens.light;
    ui.enableDeclarativeWidgets(theme);
    var book = try ouro.lua.Storybook.loadWithApi(init.gpa, vm.state, vm.apiReference(), @embedFile("benchmark_stories"));
    defer book.deinit();
    const story = book.find(profile) orelse return error.UnknownStory;

    var windows: ouro.app.windows.WindowSet = undefined;
    var host: ouro.platform.wayland.Host = undefined;
    try host.init(init.gpa, &loop, init.minimal.environ, windows.eventSink(), .{
        .app_id = "dev.ourokit.benchmark.workload.ourokit",
        .window_capacity = 1,
        .vulkan = &renderer,
    });
    defer host.deinit();
    if (host.presentationBackend() != .vulkan_dmabuf) return error.HardwareDmabufRequired;
    try windows.init(init.gpa, &scheduler, host.nativeHost(), 1, 32);
    defer windows.deinit();
    try windows.reconcile(&.{.{ .toplevel = .{
        .id = "workload",
        .title = "Ourokit frame workload",
        .initial_width = 640,
        .initial_height = 720,
    } }});
    const handle = windows.handleForId("workload").?;
    var runtime: ouro.app.WindowRuntime = .{};
    try runtime.init(init.gpa, &scheduler, try windows.scope(handle), handle, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, theme.primary, theme.foreground, theme.input, theme.ring, &signals, &sources, &paragraphs, .{
        .node_capacity = 8192,
        .command_capacity = 16384,
        .semantic_text_capacity = 256 * 1024,
    });
    runtime.root_padding = 0;
    var size: ?ouro.core.SizeU = null;
    var focused = false;
    var submitted: usize = 0;
    var pending_list: ?ouro.scene.DisplayList = null;
    var build_ns: u64 = 0;
    var mutation_ns: u64 = 0;
    var maintenance_ns: u64 = 0;
    var acquisition_ns: u64 = 0;
    const epoch = nanoTime();
    while (true) {
        if (host.failure) |failure| return failure;
        while (windows.takeEvent()) |event| switch (event) {
            .configured => |configured| {
                if (configured.width != 640 or configured.height != 720) return error.UnexpectedViewport;
                size = .{ .width = configured.width, .height = configured.height };
            },
            .close_requested => return error.WindowClosedDuringMeasurement,
            .keyboard => |keyboard| switch (keyboard) {
                .enter => focused = true,
                .leave => return error.KeyboardFocusLost,
                .key => return error.UnexpectedKeyboardInput,
            },
            else => {},
        };
        // Keep optional presentation feedback drained, but do not use it to
        // pace this comparison: both toolkits use wl_surface.frame readiness.
        _ = try host.takePresentationTiming(handle);
        if (submitted == count and try host.framesPresented(handle) >= count) {
            if (!focused) return error.KeyboardFocusRequired;
            break;
        }
        if (size) |configured| if (submitted < count) {
            if (try host.outputScale(handle) != 1) return error.ExpectedScaleOne;
            // Build once per callback. Select the presentation pool from the
            // actual scene before acquisition, just like the production runner.
            if (pending_list == null and try host.framesPresented(handle) >= submitted) {
                const mutation_start = if (retained) nanoTime() else 0;
                if (submitted != 0) {
                    if (!focused) return error.KeyboardFocusRequired;
                    _ = try vm.spawnGlobal(try windows.scope(handle), "benchmark_step", &.{.{ .integer = @intCast(submitted) }});
                    while (scheduler.takeRunnable()) |task| {
                        if (try vm.resumeRunnable(task) != .completed) return error.UnexpectedYield;
                    }
                }
                if (retained) mutation_ns = nanoTime() - mutation_start;
                const maintenance_start = if (retained) nanoTime() else 0;
                try scheduler.applyQueuedCancellations();
                try runtime.collectRetired();
                if (retained) maintenance_ns = nanoTime() - maintenance_start;
                acquisition_ns = 0;
                const start = nanoTime();
                var passes: usize = 0;
                while (true) {
                    try runtime.reconcile(configured, &ui, story.content_reference);
                    try runtime.prepareFrame(1);
                    passes += 1;
                    if (runtime.build_owners.dirty.pendingCount() == 0) break;
                    if (passes == 16) return error.UnsettledBuild;
                }
                pending_list = try runtime.displayList();
                try host.prepareScene(handle, pending_list.?);
                build_ns = nanoTime() - start;
                try host.requestRedraw(handle);
            }
            if (pending_list) |prepared| {
                const acquisition_start = if (retained) nanoTime() else 0;
                const acquired_frame = try host.acquireFrame(handle);
                if (retained) acquisition_ns += nanoTime() - acquisition_start;
                if (acquired_frame) |acquired| {
                    var frame = acquired;
                    errdefer host.discardFrame(frame) catch {};
                    if (frame.target != .vulkan) return error.HardwareDmabufRequired;
                    var list = prepared;
                    const submit_start = nanoTime();
                    try host.prepareFrameDamage(&frame, list.damage);
                    list.damage = frame.damage();
                    try renderer.renderDmabufResources(list, frame.target.vulkan, &glyphs, null, &paragraphs, null);
                    try host.present(frame);
                    const done = nanoTime();
                    try runtime.frameSubmitted();
                    const scroll = try runtime.semantics.findPath("rows");
                    const offset = try runtime.instances.scrollOffset(runtime.instances.handleForId(scroll.id).?);
                    const scroll_step = submitted % 4800;
                    const expected: f32 = if (scrolling) @floatFromInt(submitted * 14) else if (sustained)
                        @floatFromInt(@min(scroll_step, 4800 - scroll_step) * 112)
                    else
                        0;
                    if (offset != expected) return error.UnexpectedScrollOffset;
                    var active: usize = 0;
                    for (runtime.instances.slots) |slot| if (slot.state == .active) {
                        active += 1;
                    };
                    // Inspect retained output, not merely the requested generation.
                    // This validation runs outside the recorded build/submit work.
                    var first_row: usize = 0;
                    var first_value: usize = 0;
                    var row_height: f32 = 0;
                    var visible_rows: usize = 0;
                    var checked_rows: usize = 0;
                    var stable_handles: usize = 0;
                    var changed_value: usize = 0;
                    const base = if (churn) submitted / 3 * 8 else 0;
                    const expected_height: f32 = if (relayout and submitted % 2 == 1) 32 else 28;
                    for (0..runtime.semantics.count()) |node_index| {
                        const node = try runtime.semantics.node(node_index);
                        if (node.role != .text or !std.mem.startsWith(u8, node.label, "Row ")) continue;
                        const parent = runtime.instances.handleForId(node.parent.?).?;
                        const bounds = try runtime.tree.paintBounds(try runtime.instances.renderObject(parent));
                        const visible = bounds.y + bounds.height > 0 and bounds.y < 720;
                        if (!retained and !visible) continue;
                        if (node.label.len != 25) return error.UnexpectedLabelFormat;
                        const index = try std.fmt.parseInt(usize, node.label[4..10], 10);
                        const value = try std.fmt.parseInt(usize, node.label[19..25], 10);
                        if (sparse and index == 7) changed_value = value;
                        if (retained and (index <= base or index > base + (if (sustained) @as(usize, 10000) else 1000))) return error.UnexpectedRowIdentity;
                        const ordinal = index - base - 1;
                        const position = if (!churn or submitted % 3 == 0) ordinal else if (submitted % 3 == 1) 999 - ordinal else (ordinal + 1000 - 17) % 1000;
                        const expected_value = if (sparse) (if (index == 7) submitted else 0) else if (!retained and !scrolling and !relayout) submitted else 0;
                        if (bounds.x != 0 or bounds.width != 640 or bounds.height != expected_height or
                            bounds.y != @as(f32, @floatFromInt(position)) * expected_height - offset or
                            value != expected_value)
                            return error.UnexpectedRowGeometryOrText;
                        checked_rows += 1;
                        if (sparse or churn) {
                            current_handles[ordinal] = parent;
                            if (submitted != 0 and index > previous_base and index <= previous_base + 1000) {
                                if (!std.meta.eql(parent, previous_handles[index - previous_base - 1])) return error.UnexpectedIdentityReplacement;
                                stable_handles += 1;
                            }
                        }
                        if (!visible) continue;
                        if (visible_rows == 0) {
                            first_row = index;
                            first_value = value;
                            row_height = bounds.height;
                        }
                        visible_rows += 1;
                    }
                    const first_local: usize = if (submitted % 3 == 1) 1000 else if (submitted % 3 == 2) 18 else 1;
                    const expected_first = if (churn) base + first_local else 1 + @as(usize, @intFromFloat(@floor(offset / expected_height)));
                    if (first_row != expected_first or
                        first_value != (if (!retained and !scrolling and !relayout) submitted else @as(usize, 0)) or
                        row_height != expected_height or visible_rows < 2) return error.UnexpectedRetainedOutput;
                    if (sparse or churn) {
                        if (checked_rows != 1000) return error.UnexpectedRetainedRowCount;
                        previous_handles = current_handles;
                        previous_base = base;
                    }
                    samples[submitted] = .{
                        .build_ns = build_ns,
                        .submit_ns = done - submit_start,
                        .submitted_ns = done - epoch,
                        .offset = offset,
                        .nodes = active,
                        .commands = list.commands.len,
                        .layouts = runtime.metrics.layouts.count,
                        .first_row = first_row,
                        .first_value = first_value,
                        .row_height = row_height,
                    };
                    if (retained) {
                        // Pure diagnostic callback and heap queries stay outside
                        // timing. Do not force collection or change GC policy.
                        _ = try vm.spawnGlobal(try windows.scope(handle), "benchmark_probe", &.{});
                        while (scheduler.takeRunnable()) |task| {
                            if (try vm.resumeRunnable(task) != .completed) return error.UnexpectedYield;
                        }
                        var retiring: usize = 0;
                        for (runtime.instances.occupiedSlots()) |slot| {
                            if (runtime.instances.slots[slot].state == .retiring) retiring += 1;
                        }
                        samples[submitted].retained = .{
                            .mutation_ns = mutation_ns,
                            .maintenance_ns = maintenance_ns,
                            .acquisition_ns = acquisition_ns,
                            .root_calls = try luaCounter(vm.state, "benchmark_root_calls"),
                            .row_calls = try luaCounter(vm.state, "benchmark_row_calls"),
                            .builds = runtime.metrics.builds.count,
                            .paints = runtime.metrics.paints.count,
                            .lua_heap_bytes = @as(u64, @intCast(lua_gc(vm.state, 3))) * 1024 + @as(u64, @intCast(lua_gc(vm.state, 4))),
                            .source_entries = sources.count(),
                            .paragraph_entries = paragraphs.count(),
                            .source_index_capacity = sources.index.capacity(),
                            .paragraph_index_capacity = paragraphs.index.capacity(),
                            .source_slabs = sources.slabs.items.len,
                            .paragraph_slabs = paragraphs.slabs.items.len,
                            .retiring_instances = retiring,
                            .checked_rows = checked_rows,
                            .stable_handles = stable_handles,
                            .changed_value = changed_value,
                        };
                    }
                    submitted += 1;
                    pending_list = null;
                }
            }
        };
        try host.flush();
        try host.dispatchOne(try loop.wait());
    }
    std.debug.print("{{\"kind\":\"metadata\",\"toolkit\":\"Ourokit\",\"profile\":\"{s}\",\"frames\":{d},\"row_count\":{d},\"viewport\":[640,720],\"font\":\"Source Sans 3\",\"font_size\":14,\"font_weight\":400,\"row_padding\":4,\"line_height\":18.5625,\"scale_factor\":1,\"active\":true,\"backend\":\"vulkan_dmabuf\",\"epoch_ns\":{d},\"sample_storage_bytes\":{d},\"timing\":\"CPU wall: reconcile/layout/display list then GPU encoding and host.present; excludes mutation/acquisition; callback paced, not display latency\"}}\n", .{ profile, count, @as(usize, if (scrolling or sustained) 10000 else 1000), epoch, count * @sizeOf(Sample) });
    for (samples, 0..) |sample, index| {
        if (retained) {
            const line = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
                .kind = "sample",
                .frame = index,
                .build_ns = sample.build_ns,
                .submit_ns = sample.submit_ns,
                .work_ns = sample.build_ns + sample.submit_ns,
                .submitted_ns = sample.submitted_ns,
                .offset = sample.offset,
                .row_height = sample.row_height,
                .nodes = sample.nodes,
                .commands = sample.commands,
                .layouts = sample.layouts,
                .first_row = sample.first_row,
                .first_value = sample.first_value,
                .retained = sample.retained.?,
            }, .{});
            std.debug.print("{s}\n", .{line});
            continue;
        }
        std.debug.print("{{\"kind\":\"sample\",\"frame\":{d},\"build_ns\":{d},\"submit_ns\":{d},\"work_ns\":{d},\"submitted_ns\":{d},\"offset\":{d},\"row_height\":{d},\"nodes\":{d},\"commands\":{d},\"layouts\":{d},\"first_row\":{d},\"first_value\":{d}}}\n", .{
            index,            sample.build_ns,    sample.submit_ns, sample.build_ns + sample.submit_ns, sample.submitted_ns,
            sample.offset,    sample.row_height,  sample.nodes,     sample.commands,                    sample.layouts,
            sample.first_row, sample.first_value,
        });
    }
    if (hold_ms != 0) {
        const duration: linux.timespec = .{ .sec = @intCast(hold_ms / 1000), .nsec = @intCast(hold_ms % 1000 * std.time.ns_per_ms) };
        if (linux.errno(linux.nanosleep(&duration, null)) != .SUCCESS) return error.HoldInterrupted;
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

// Public Lua ABI, used only by this diagnostic executable. GCCOUNT/GCCOUNTB
// query managed bytes; they neither collect garbage nor measure GC pause time.
const LuaState = @TypeOf(@as(ouro.lua.Vm, undefined).state);
extern fn lua_gc(state: LuaState, what: c_int, ...) c_int;
extern fn lua_getglobal(state: LuaState, name: [*:0]const u8) c_int;
extern fn lua_tointegerx(state: LuaState, index: c_int, is_number: *c_int) i64;
extern fn lua_settop(state: LuaState, index: c_int) void;

fn luaCounter(state: LuaState, name: [*:0]const u8) !u64 {
    const kind = lua_getglobal(state, name);
    defer lua_settop(state, -2);
    var valid: c_int = 0;
    const value = lua_tointegerx(state, -1, &valid);
    if (kind != 3 or valid == 0 or value < 0) return error.InvalidDiagnosticCounter;
    return @intCast(value);
}
