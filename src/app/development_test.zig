const std = @import("std");
const dev = @import("development.zig");
const lua = @import("../lua/root.zig");
const c = @import("../lua/c.zig");
const ui = @import("../ui/root.zig");
const text = @import("../text/root.zig");
const task = @import("../task/root.zig");
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;

const Fixture = struct {
    loop: @import("../loop/root.zig").Loop = undefined,
    vm: lua.Vm = undefined,
    callbacks: lua.CallbackRegistry = undefined,
    scheduler: task.Scheduler = undefined,
    scope: task.ScopeHandle = undefined,
    signals: lua.Signals = undefined,
    fonts: text.FontCache = undefined,
    font: [1]text.FontHandle = undefined,
    sources: text.ParagraphSourceCache = undefined,
    paragraphs: text.ParagraphCache = undefined,
    builder: lua.UiBuild = undefined,
    runtime: WindowRuntime = .{},
    descriptors: [256]ui.instance.Descriptor = undefined,
    semantics: [256]ui.semantics.Descriptor = undefined,

    fn create(source: []const u8) !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.* = .{};
        try self.loop.init(std.testing.allocator, 8, 2);
        try self.scheduler.init(std.testing.allocator, 1024, 16, 4);
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        self.vm.pushApi(self.vm.state);
        c.lua_setglobal(self.vm.state, "ouro");
        try self.callbacks.init(std.testing.allocator, 256);
        self.scope = try self.scheduler.createScope(self.scheduler.application_scope);
        try self.signals.init(std.testing.allocator, self.vm.state, 1024, 1024, 1024);
        self.fonts = text.FontCache.init(std.testing.allocator);
        self.font[0] = try self.fonts.acquire(.{ .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 }, .bytes = @embedFile("ourokit_test_font_static") });
        self.sources = text.ParagraphSourceCache.init(std.testing.allocator, &self.fonts);
        self.paragraphs = text.ParagraphCache.init(std.testing.allocator, &self.fonts);
        try self.builder.init(self.vm.state, &self.descriptors);
        self.builder.attachCallbacks(&self.callbacks, &self.vm);
        self.builder.attachSignals(&self.signals);
        try self.builder.attachSemantics(&self.semantics);
        try self.builder.attachText(&self.sources, &self.font, 1);
        const theme = @import("../design/root.zig").tokens.light;
        self.builder.enableDeclarativeWidgets(theme);
        try self.runtime.init(std.testing.allocator, &self.scheduler, self.scope, .{ .slot = 3, .generation = 9 }, theme.background, theme.primary, theme.foreground, theme.input, theme.ring, &self.signals, &self.sources, &self.paragraphs, .{ .measure_phases = true });
        errdefer self.destroy();
        if (c.luaL_loadbufferx(self.vm.state, source.ptr, source.len, "@development-test", "t") != c.ok or
            c.lua_pcallk(self.vm.state, 0, 0, 0, 0, null) != c.ok) return error.LuaTestFailed;
        try self.settle();
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.runtime.clear(&self.builder) catch unreachable;
        self.scheduler.applyQueuedCancellations() catch unreachable;
        self.runtime.collectRetired() catch unreachable;
        self.runtime.deinit();
        self.scheduler.destroyScope(self.scope) catch unreachable;
        self.callbacks.deinit();
        self.vm.deinit();
        self.scheduler.deinit();
        self.loop.deinit();
        self.signals.deinit();
        self.paragraphs.deinit();
        self.sources.deinit();
        self.fonts.release(self.font[0]) catch unreachable;
        self.fonts.deinit();
        std.testing.allocator.destroy(self);
    }

    fn settle(self: *Fixture) !void {
        try self.runtime.dispatchInput(&self.callbacks);
        try self.scheduler.applyQueuedCancellations();
        while (self.scheduler.takeRunnable()) |handle|
            try std.testing.expectEqual(.completed, try self.vm.resumeRunnable(handle));
        try self.runtime.collectRetired();
        _ = c.lua_getglobal(self.vm.state, "build");
        const reference = c.luaL_ref(self.vm.state, c.registry_index);
        defer c.luaL_unref(self.vm.state, c.registry_index, reference);
        try self.runtime.reconcile(.{ .width = 324, .height = 224 }, &self.builder, reference);
        if (self.runtime.frame_state.readyForSubmission()) try self.runtime.frameSubmitted();
    }

    fn play(self: *Fixture, action: dev.Action) !void {
        var playback = try dev.Playback.init(&self.runtime, dev.Token.current(&self.runtime), action);
        while (try playback.advance(&self.runtime) == .routed) try self.settle();
    }

    fn snapshot(self: *Fixture) !dev.Snapshot {
        return dev.inspect(std.testing.allocator, &self.runtime, .{});
    }
};

fn node(snapshot: dev.Snapshot, path: []const u8) !dev.Node {
    for (snapshot.nodes) |value| if (value.path) |candidate| {
        if (std.mem.eql(u8, candidate, path)) return value;
    };
    return error.TestPathMissing;
}

test "development click and hover use dispatch, reject disabled and stale targets, and own bounded snapshots" {
    const f = try Fixture.create(
        \\checked = ouro.signal(false)
        \\function build()
        \\  return ouro.column {key='root', gap=13,
        \\    ouro.switch {key='left', label='Left', checked=checked(), on_change=function(v) checked:set(v) end},
        \\    ouro.switch {key='right', label='Right', checked=true, enabled=false},
        \\  }
        \\end
    );
    defer f.destroy();
    var before = try f.snapshot();
    defer before.deinit();
    const left = try node(before, "root/left");
    const right = try node(before, "root/right");
    try std.testing.expect(!left.checked and right.checked and !right.enabled);
    try std.testing.expect(left.bounds.y < right.bounds.y and left.bounds.width > 0);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, before.token, .{ .click = "root/right" }));
    try std.testing.expectError(error.DevelopmentSnapshotCapacityExceeded, dev.inspect(std.testing.allocator, &f.runtime, .{ .nodes = 1 }));
    try std.testing.expectError(error.DevelopmentSnapshotCapacityExceeded, dev.inspect(std.testing.allocator, &f.runtime, .{ .text_bytes = 5 }));

    var playback = try dev.Playback.init(&f.runtime, before.token, .{ .click = "root/left" });
    try std.testing.expectEqual(.routed, try playback.advance(&f.runtime));
    try std.testing.expectError(error.DevelopmentRuntimeNotSettled, playback.advance(&f.runtime));
    try f.settle();
    try std.testing.expectEqual(.routed, try playback.advance(&f.runtime));
    try std.testing.expect(!(try f.runtime.semantics.findPath("root/left")).checked);
    try f.settle();
    try std.testing.expectEqual(.routed, try playback.advance(&f.runtime));
    try std.testing.expectError(error.DevelopmentRuntimeNotSettled, playback.advance(&f.runtime));
    try f.settle();
    try std.testing.expectEqual(.complete, try playback.advance(&f.runtime));
    var after = try f.snapshot();
    defer after.deinit();
    try std.testing.expect((try node(after, "root/left")).checked);
    try std.testing.expect((try node(after, "root/right")).checked);
    try std.testing.expect(!(try node(before, "root/left")).checked);
    try std.testing.expectError(error.StaleDevelopmentTarget, dev.Playback.init(&f.runtime, before.token, .{ .click = "root/left" }));
    try f.play(.{ .hover = "root/right" });
    var wrong_window = dev.Token.current(&f.runtime);
    wrong_window.window.generation += 1;
    try std.testing.expectError(error.StaleDevelopmentTarget, wrong_window.validate(&f.runtime));
    const old_generation = dev.Token.current(&f.runtime);
    try f.runtime.clear(&f.builder);
    try std.testing.expectError(error.StaleDevelopmentTarget, old_generation.validate(&f.runtime));
}

test "development reports retained list selection and cancels a pressed pointer through routing" {
    const f = try Fixture.create(
        \\function build()
        \\  return ouro.listbox {key='choices', selected=7, on_select=function() end,
        \\    ouro.option {key='first', value=7, label='Seven'},
        \\    ouro.option {key='second', value=29, label='Twenty nine'},
        \\  }
        \\end
    );
    defer f.destroy();
    var initial = try f.snapshot();
    defer initial.deinit();
    try std.testing.expect((try node(initial, "choices/first")).selected);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down } });
    var changed = try f.snapshot();
    defer changed.deinit();
    try std.testing.expectEqual(@as(?i64, 29), (try node(changed, "choices")).selected_value);
    try std.testing.expect(!(try node(changed, "choices/first")).selected);
    try std.testing.expect((try node(changed, "choices/second")).selected);
    // No Lua signal/callback rebuilt the old semantic descriptor.
    try std.testing.expect((try f.runtime.semantics.findPath("choices/first")).selected);
    var playback = try dev.Playback.init(&f.runtime, changed.token, .{ .click = "choices/first" });
    _ = try playback.advance(&f.runtime);
    try f.settle();
    _ = try playback.advance(&f.runtime);
    try f.settle();
    try std.testing.expect(f.runtime.router.captured != null);
    try playback.cancel(&f.runtime);
    try f.settle();
    try std.testing.expect(f.runtime.router.captured == null);
    try std.testing.expectEqual(.complete, try playback.advance(&f.runtime));
}

test "development keyboard and text preserve asymmetric UTF-8 selection through real editing" {
    const f = try Fixture.create(
        \\function build()
        \\  return ouro.column {key='root', gap=11,
        \\    ouro.text_input {key='edit', label='Query', default_text='aéZ'},
        \\    ouro.text_input {key='locked', label='Locked', default_text='keep', read_only=true},
        \\  }
        \\end
    );
    defer f.destroy();
    try std.testing.expectError(error.DevelopmentTargetNotFocused, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "bad" }));
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left, .modifiers = .{ .shift = true } } });
    var selected = try f.snapshot();
    defer selected.deinit();
    const edit = try node(selected, "root/edit");
    try std.testing.expect(edit.focused);
    try std.testing.expectEqualStrings("aéZ", edit.value.?);
    try std.testing.expectEqual(@as(usize, 4), edit.selection.?.anchor);
    try std.testing.expectEqual(@as(usize, 3), edit.selection.?.extent);
    // A native window can retain semantic focus without seat/IME ownership.
    try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 0 } });
    try f.settle();
    try std.testing.expect((try f.runtime.textInputStatus()) == null);
    try std.testing.expectError(error.DevelopmentTextContainsControl, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "a\nb" }));
    try f.play(.{ .text = "Ω!" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .backspace } });
    var after = try f.snapshot();
    defer after.deinit();
    const changed = try node(after, "root/edit");
    try std.testing.expectEqualStrings("aéΩ", changed.value.?);
    try std.testing.expectEqual(@as(usize, 5), changed.selection.?.extent);
    try std.testing.expectEqualStrings("keep", (try node(after, "root/locked")).value.?);
    try std.testing.expectError(error.StaleDevelopmentTarget, dev.Playback.init(&f.runtime, selected.token, .{ .text = "stale" }));
    var canceled = try dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "λnot typed" });
    try std.testing.expectEqual(.routed, try canceled.advance(&f.runtime));
    try f.settle();
    try canceled.cancel(&f.runtime);
    try f.settle();
    try canceled.cancel(&f.runtime);
    try std.testing.expectEqual(.complete, try canceled.advance(&f.runtime));
    var partial = try f.snapshot();
    defer partial.deinit();
    try std.testing.expectEqualStrings("aéΩλ", (try node(partial, "root/edit")).value.?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectError(error.DevelopmentTargetReadOnly, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "bad" }));
}

test "development scrolling, actual phase counts and full PNG replay after submission" {
    const f = try Fixture.create(
        \\function build()
        \\  return ouro.virtual_list {key='rows', item_count=20, item_height=40,
        \\    item_key=function(i) return 'item-' .. i end,
        \\    render_item=function(i) return ouro.box {key='box', height=40, background=i % 2 == 0 and '#d02010' or '#1030c0'} end,
        \\  }
        \\end
    );
    defer f.destroy();
    const metrics = f.runtime.metrics;
    try std.testing.expect(metrics.builds.count > 0 and metrics.layouts.count > 0 and metrics.paints.count > 0);
    try std.testing.expectEqual(metrics.builds.count, metrics.builds.timed_count);
    try f.runtime.prepareFrame(1);
    try std.testing.expectEqualDeep(metrics, f.runtime.metrics);
    try f.play(.{ .scroll = .{ .target = "rows", .delta = 73 } });
    var scrolled = try f.snapshot();
    defer scrolled.deinit();
    try std.testing.expectEqual(@as(f32, 73), (try node(scrolled, "rows")).scroll_offset.?);
    try f.play(.{ .scroll = .{ .target = "rows", .delta = -19 } });
    var back = try f.snapshot();
    defer back.deinit();
    try std.testing.expectEqual(@as(f32, 54), (try node(back, "rows")).scroll_offset.?);
    try std.testing.expectError(error.InvalidScrollDelta, dev.Playback.init(&f.runtime, back.token, .{ .scroll = .{ .target = "rows", .delta = std.math.nan(f32) } }));

    if (!@import("../renderer/software/root.zig").has_freetype) return error.SkipZigTest;
    const state = f.runtime.frame_state;
    const before_capture = f.runtime.metrics;
    var image = try dev.capture(std.testing.allocator, &f.runtime, back.token);
    defer image.deinit();
    var repeated = try dev.capture(std.testing.allocator, &f.runtime, back.token);
    defer repeated.deinit();
    try std.testing.expectEqual(.software_scene_replay, image.kind);
    try std.testing.expectEqualDeep(state, f.runtime.frame_state);
    try std.testing.expectEqualDeep(before_capture, f.runtime.metrics);
    try std.testing.expectEqualSlices(u8, image.png, repeated.png);
    var decoded = try @import("../image/codec.zig").decode(std.testing.allocator, image.png, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 324), decoded.width);
    try std.testing.expectEqual(@as(u32, 224), decoded.height);
    // At offset 54, visible row 2 is red and row 3 is blue. Sample well
    // inside both, independent of the replay implementation.
    const red = (20 * 324 + 40) * 4;
    const blue = (60 * 324 + 40) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x20, 0x10, 0xff }, decoded.pixels[red..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x30, 0xc0, 0xff }, decoded.pixels[blue..][0..4]);
    try std.testing.expectError(error.StaleDevelopmentTarget, dev.capture(std.testing.allocator, &f.runtime, scrolled.token));
}
