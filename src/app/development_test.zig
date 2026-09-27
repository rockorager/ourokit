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

test "split controls preserve grab offset and clamp both axes at actual layout limits" {
    inline for (.{ "horizontal", "vertical" }) |axis| {
        const f = try Fixture.create("axis='" ++ axis ++ "'\n" ++
            \\position=ouro.signal(0.25)
            \\function build() return ouro.split_view {key='split', axis=axis, position=position(),
            \\ min_first=40, min_second=70, on_change=function(v) position:set(v) end,
            \\ ouro.box {key='first'}, ouro.box {key='second'}} end
        );
        defer f.destroy();
        const horizontal = comptime std.mem.eql(u8, axis, "horizontal");
        const before = try f.runtime.semanticTarget("split/divider");
        try f.play(.{ .hover = "split/divider" });
        try std.testing.expectEqual(if (horizontal) .col_resize else .row_resize, try f.runtime.pointerCursor());
        try f.play(.{ .pointer_down = "split/divider" });
        var position = before.center;
        if (horizontal) position.x += 23 else position.y += 23;
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = position } });
        try f.settle();
        const moved = try f.runtime.semanticTarget("split/divider");
        try std.testing.expectApproxEqAbs(@as(f32, 23), if (horizontal) moved.center.x - before.center.x else moved.center.y - before.center.y, 0.001);
        try std.testing.expectEqual(if (horizontal) .col_resize else .row_resize, try f.runtime.pointerCursor());
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = .{ .x = -500, .y = -500 } } });
        try f.settle();
        const first = (try f.runtime.semanticTarget("split/first")).bounds;
        try std.testing.expectApproxEqAbs(@as(f32, 40), if (horizontal) first.width else first.height, 0.001);
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 3, .button = 0x110, .state = .released } });
        try f.settle();
        try std.testing.expect(f.runtime.split_drag == null);
        try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
        const second = (try f.runtime.semanticTarget("split/second")).bounds;
        try std.testing.expectApproxEqAbs(@as(f32, 70), if (horizontal) second.width else second.height, 0.001);
        try f.play(.{ .key = .{ .keycode = 0, .logical = .home } });
        try f.play(.{ .key = .{ .keycode = 0, .logical = if (horizontal) .arrow_right else .arrow_down } });
        const stepped = (try f.runtime.semanticTarget("split/first")).bounds;
        try std.testing.expectApproxEqAbs(@as(f32, 50), if (horizontal) stepped.width else stepped.height, 0.001);
    }
}

test "tabs retain hidden editor state and reject hidden input without selecting on close" {
    const f = try Fixture.create(
        \\selected=ouro.signal(17); closed=0
        \\function build() return ouro.tabs {key='tabs', label='Editors', selected=selected(),
        \\ on_select=function(v) selected:set(v) end, on_close=function(v) closed=v end,
        \\ tabs={{value=17,label='First',content=ouro.text_input {key='edit',default_text='',multiline=true,height=70}},
        \\ {value=29,label='Second',closable=true,content=ouro.text_input {key='edit',default_text='other'}}}} end
    );
    defer f.destroy();
    try f.play(.{ .click = "tabs/control/panels/17/edit" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    const text_value = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve";
    try f.play(.{ .text = text_value });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left, .modifiers = .{ .shift = true } } });
    const selection = session.model.selection;
    const content = try f.runtime.text_inputs.content(target);
    const render = try f.runtime.instances.renderObject(content);
    const offset = try f.runtime.tree.textScrollOffset(render, .vertical);
    try std.testing.expect(offset > 0);
    // A close request for a background tab does not implicitly select it.
    try f.play(.{ .click = "tabs/control/bar/29/close" });
    _ = c.lua_getglobal(f.vm.state, "closed");
    var is_number: c_int = 0;
    try std.testing.expectEqual(@as(c.Integer, 29), c.lua_tointegerx(f.vm.state, -1, &is_number));
    c.lua_settop(f.vm.state, -2);
    try std.testing.expect((try f.runtime.semantics.findPath("tabs/control/bar/17")).selected);
    // Selecting a narrow closable tab must hit its label, not its close button.
    try f.play(.{ .click = "tabs/control/bar/29" });
    try std.testing.expect((try f.runtime.semantics.findPath("tabs/control/bar/29")).selected);
    // Focus the tab list, then switch using its native horizontal policy.
    try f.play(.{ .click = "tabs/control/bar/17" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect(!f.runtime.instances.isFocusable(target));
    try std.testing.expectError(error.DevelopmentTargetHidden, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "tabs/control/panels/17/edit" }));
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expect(!(try node(snapshot, "tabs/control/panels/17/edit")).visible);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect((try f.runtime.semantics.findPath("tabs/control/bar/17")).selected);
    try std.testing.expectEqual(target, f.runtime.instances.handleForId((try f.runtime.semantics.findPath("tabs/control/panels/17/edit")).id).?);
    try std.testing.expectEqual(selection, session.model.selection);
    try std.testing.expectEqual(offset, try f.runtime.tree.textScrollOffset(render, .vertical));
    try f.play(.{ .click = "tabs/control/panels/17/edit" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    try f.play(.{ .text = "!" });
    try f.play(.{ .click = "tabs/control/bar/17" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left } });
    try f.play(.{ .click = "tabs/control/panels/17/edit" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true } } });
    try std.testing.expectEqualStrings(text_value, session.model.text());
}

test "development click releases capture when a tab close removes its own target" {
    const f = try Fixture.create(
        \\closed=ouro.signal(false); closes=0; replacements=0
        \\function build()
        \\ if closed() then return ouro.button {key='replacement',label='Replacement',
        \\   on_press=function() replacements=replacements+1 end} end
        \\ return ouro.tabs {key='tabs',label='Tabs',selected=17,on_select=function() end,
        \\   on_close=function() closes=closes+1; closed:set(true) end,
        \\   tabs={{value=17,label='First',closable=true,content=ouro.box {key='body'}}}}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .click = "tabs/control/bar/17/close" });
    try std.testing.expect(f.runtime.router.captured == null);
    try std.testing.expect(f.runtime.buttons.armed == null);
    const check = "assert(closes==1 and replacements==0)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.play(.{ .click = "replacement" });
    const check_replacement = "assert(replacements==1)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check_replacement.ptr, check_replacement.len, "@check", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "hiding a focused retained editor releases IME ownership and composition" {
    const f = try Fixture.create(
        \\hidden=ouro.signal(false)
        \\function build() return ouro.box {key='panel', hidden=hidden(),
        \\ ouro.text_input {key='edit',default_text='keep'}} end
    );
    defer f.destroy();
    try f.play(.{ .click = "panel/edit" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    try std.testing.expect((try f.runtime.textInputStatus()) != null);
    _ = try session.apply(.{ .preedit = .{ .text = "compose", .cursor = null } });
    const hide = "hidden:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, hide.ptr, hide.len, "@hide", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expect(f.runtime.focus.current() == null);
    try std.testing.expect((try f.runtime.textInputStatus()) == null);
    try std.testing.expect(session.preedit() == null);
    try std.testing.expect(f.runtime.instances.isActive(target));
    try std.testing.expectEqualStrings("keep", session.model.text());
    try std.testing.expect((try f.runtime.animationDelay()) == null);
}

test "multiline development editing preserves lines and navigates visual rows" {
    const f = try Fixture.create(
        \\value=ouro.signal('')
        \\function build() return ouro.text_input {key='body', multiline=true, height=84, text=value(),
        \\ on_change=function(v) value:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .click = "body" });
    try f.play(.{ .text = "alpha\nb\nthird\n" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    try std.testing.expectEqualStrings("alpha\nb\nthird\n", session.model.text());
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expect((try node(snapshot, "body")).multiline);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .home, .modifiers = .{ .control = true } } });
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down } });
    try std.testing.expectEqual(@as(usize, 6), session.model.selection.extent);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
    try std.testing.expectEqual(@as(usize, 7), session.model.selection.extent);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down, .modifiers = .{ .shift = true } } });
    try std.testing.expectEqual(@as(usize, 7), session.model.selection.anchor);
    try std.testing.expect(session.model.selection.extent > 8);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    try std.testing.expectEqual(@as(usize, 14), session.model.selection.extent);
    // Native paste uses the same normalization/history as IME commits, not dev text playback.
    try std.testing.expect(try f.runtime.applyClipboardPaste(&f.callbacks, target, "é\r\nlast"));
    try f.settle();
    try std.testing.expectEqualStrings("alpha\nb\nthird\né\nlast", session.model.text());
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true } } });
    try std.testing.expectEqualStrings("alpha\nb\nthird\n", session.model.text());
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true, .shift = true } } });
    try std.testing.expectEqualStrings("alpha\nb\nthird\né\nlast", session.model.text());
    try std.testing.expectError(error.DevelopmentTextContainsControl, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "bad\ttext" }));
    var bottom = try f.snapshot();
    defer bottom.deinit();
    try std.testing.expect((try node(bottom, "body")).scroll_offset.? > 0);
    try f.play(.{ .scroll = .{ .target = "body", .delta = -10000 } });
    var top = try f.snapshot();
    defer top.deinit();
    try std.testing.expectEqual(@as(f32, 0), (try node(top, "body")).scroll_offset.?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    var revealed = try f.snapshot();
    defer revealed.deinit();
    try std.testing.expect((try node(revealed, "body")).scroll_offset.? > 0);
}

test "multiline read-only selection auto-scrolls vertically without editing" {
    const f = try Fixture.create(
        \\function build() return ouro.text_input {key='body', multiline=true, height=64, read_only=true,
        \\ default_text='one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n'} end
    );
    defer f.destroy();
    try f.play(.{ .pointer_down = "body" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    const render = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(target));
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = .{ .x = 50, .y = 190 } } });
    try f.settle();
    const initial = session.model.selection.extent;
    for (0..100) |tick| {
        try f.runtime.advanceAnimations(tick * 16 * std.time.ns_per_ms);
        try f.settle();
    }
    try std.testing.expect(session.model.selection.extent > initial);
    try std.testing.expectEqual(session.model.text().len, session.model.selection.extent);
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollDelta(render, .vertical, 100));
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = .{ .x = 0, .y = -80 } } });
    try f.settle();
    for (100..200) |tick| {
        try f.runtime.advanceAnimations(tick * 16 * std.time.ns_per_ms);
        try f.settle();
    }
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollOffset(render, .vertical));
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 3, .button = 0x110, .state = .released } });
    try f.settle();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try std.testing.expect(!try f.runtime.applyClipboardPaste(&f.callbacks, target, "overwrite\n"));
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n", session.model.text());
}

test "multiline mode changes replace retained sessions even for equal uncontrolled text" {
    const f = try Fixture.create(
        \\multi=ouro.signal(false)
        \\function build() return ouro.column {key='root',
        \\ ouro.text_input {key='body', default_text='same', multiline=multi()},
        \\ ouro.button {key='toggle', label='Toggle', on_press=function() multi:set(not multi()) end}} end
    );
    defer f.destroy();
    const semantic = try f.runtime.semantics.findPath("root/body");
    const target = f.runtime.instances.handleForId(semantic.id).?;
    try f.play(.{ .click = "root/body" });
    try std.testing.expectError(error.DevelopmentTextContainsControl, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "a\nb" }));
    try f.play(.{ .click = "root/toggle" });
    try std.testing.expect((try f.runtime.text_inputs.session(target)).model.multiline);
    try std.testing.expectEqualStrings("same", (try f.runtime.text_inputs.session(target)).model.text());
    try f.play(.{ .click = "root/body" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    try f.play(.{ .text = "\nmore" });
    try std.testing.expectEqualStrings("same\nmore", (try f.runtime.text_inputs.session(target)).model.text());
    try f.play(.{ .click = "root/toggle" });
    try std.testing.expect(!(try f.runtime.text_inputs.session(target)).model.multiline);
    try std.testing.expectEqualStrings("same", (try f.runtime.text_inputs.session(target)).model.text());
}

test "focus rings follow keyboard navigation without changing logical pointer focus" {
    const f = try Fixture.create(
        \\function build() return ouro.column {key='root', gap=8,
        \\ ouro.button {key='flat', label='Workspace', border_width=0},
        \\ ouro.button {key='bordered', label='Bordered', border_width=1},
        \\ ouro.text_input {key='edit', default_text='Text'},
        \\} end
    );
    defer f.destroy();
    const flat = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/flat")).id).?;
    const render = try f.runtime.instances.renderObject(flat);
    try f.play(.{ .click = "root/flat" });
    try std.testing.expectEqual(flat, f.runtime.focus.current().?);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.outline_width);
    // Keyboard activation of the SAME pointer-focused button reveals the ring.
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try std.testing.expectEqual(@as(f32, 2), (try f.runtime.tree.objectAt(render)).box.outline_width);
    try f.play(.{ .click = "root/flat" });
    try std.testing.expectEqual(flat, f.runtime.focus.current().?);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.outline_width);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    const bordered = f.runtime.focus.current().?;
    const bordered_render = try f.runtime.instances.renderObject(bordered);
    try std.testing.expectEqual(f.runtime.focus_color, (try f.runtime.tree.objectAt(bordered_render)).box.border_color.?);
    try f.play(.{ .click = "root/bordered" });
    try std.testing.expectEqual(f.runtime.buttons.styleFor(bordered).?.border.?, (try f.runtime.tree.objectAt(bordered_render)).box.border_color.?);
    try f.play(.{ .click = "root/edit" });
    const edit_render = try f.runtime.instances.renderObject(f.runtime.focus.current().?);
    try std.testing.expectEqual(f.runtime.focus_color, (try f.runtime.tree.objectAt(edit_render)).box.border_color.?);
    // A keyboard-ineligible layer panel must never show a ring on click.
    try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 0 } });
    try f.settle();
    try f.play(.{ .click = "root/flat" });
    try std.testing.expectEqual(flat, f.runtime.focus.current().?);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.outline_width);
}

test "forms checkbox requests remain controlled and disabled controls skip focus" {
    const f = try Fixture.create(
        \\requested=false
        \\function build() return ouro.column {key='form', gap=8,
        \\ ouro.checkbox {key='check', label='Enabled', checked=false, on_change=function(v) requested=v end},
        \\ ouro.checkbox {key='disabled', label='Disabled', checked=true, enabled=false},
        \\ ouro.button {key='after', label='After'},
        \\} end
    );
    defer f.destroy();
    try f.play(.{ .click = "form/check" });
    _ = c.lua_getglobal(f.vm.state, "requested");
    try std.testing.expect(c.lua_toboolean(f.vm.state, -1) != 0);
    c.lua_settop(f.vm.state, -2);
    try std.testing.expect(!(try f.runtime.semantics.findPath("form/check")).checked);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectEqual(f.runtime.instances.handleForId((try f.runtime.semantics.findPath("form/after")).id).?, f.runtime.focus.current().?);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "form/disabled" }));
}

test "forms checkbox accepts toggles without losing its focus identity" {
    const f = try Fixture.create(
        \\checked=ouro.signal(false)
        \\function build() return ouro.checkbox {key='check', label='Check', checked=checked(),
        \\ on_change=function(v) checked:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .click = "check" });
    const focused = f.runtime.focus.current().?;
    try std.testing.expect((try f.runtime.semantics.findPath("check")).checked);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try std.testing.expect(!(try f.runtime.semantics.findPath("check")).checked);
    try std.testing.expectEqual(focused, f.runtime.focus.current().?);
}

test "forms radio navigation wraps and follows reordered declarations" {
    const f = try Fixture.create(
        \\selected=ouro.signal(17)
        \\function build()
        \\ local a=ouro.radio {key='a', value=17, label='Seventeen'}
        \\ local b=ouro.radio {key='b', value=29, label='Twenty nine'}
        \\ local d=ouro.radio {key='d', value=43, label='Forty three'}
        \\ return ouro.radio_group {key='choices', selected=selected(),
        \\   on_select=function(v) selected:set(v) end,
        \\   children=selected()==29 and {d,b,a} or {a,b,d}}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect((try f.runtime.semantics.findPath("choices/b")).checked);
    // Now d,b,a: moving right from b must choose a, not its old slot successor d.
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect((try f.runtime.semantics.findPath("choices/a")).checked);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left } });
    try std.testing.expect((try f.runtime.semantics.findPath("choices/d")).checked);
}

test "forms radio indicators stay centered independently of label font metrics" {
    const f = try Fixture.create(
        \\function build() return ouro.radio_group {key='choices', selected=17, on_select=function() end,
        \\ ouro.radio {key='large', value=17, label='Large', height=44, font_size=28},
        \\ ouro.radio {key='small', value=29, label='Small', height=32, font_size=14}} end
    );
    defer f.destroy();
    for ([_][]const u8{ "choices/large", "choices/small" }, [_]f32{ 22, 16 }) |path, center| {
        const semantic = try f.runtime.semantics.findPath(path);
        const render = try f.runtime.instances.renderObject(f.runtime.instances.handleForId(semantic.id).?);
        const content = f.runtime.tree.firstChild(render).?;
        const indicator = f.runtime.tree.firstChild(content).?;
        const circle = (try f.runtime.tree.objectAt(indicator)).box;
        try std.testing.expectEqual(@as(f32, 12), circle.width.?);
        try std.testing.expectEqual(@as(f32, 12), circle.height.?);
        try std.testing.expectEqual(semantic.checked, circle.background != null);
        const y = (try f.runtime.tree.nodeOffset(content)).y + (try f.runtime.tree.nodeOffset(indicator)).y;
        try std.testing.expectApproxEqAbs(center, y + 6, 0.001);
    }
}

test "forms slider keyboard bounds and captured drag use the declared range" {
    const f = try Fixture.create(
        \\value=ouro.signal(-1.25)
        \\function build() return ouro.slider {key='level', label='Level', width=200,
        \\ value=value(), min=-2.25, max=3, step=0.5, on_change=function(v) value:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expectEqual(@as(f64, -0.75), (try f.runtime.semantics.findPath("level")).range.?.value);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
    try std.testing.expectEqual(@as(f64, 3), (try f.runtime.semantics.findPath("level")).range.?.value);
    try f.play(.{ .pointer_down = "level" });
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = .{ .x = -80, .y = 180 } } });
    try f.settle();
    try std.testing.expectEqual(@as(f64, -2.25), (try f.runtime.semantics.findPath("level")).range.?.value);
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 2, .button = 0x110, .state = .released } });
    try f.settle();
    try std.testing.expect(f.runtime.range_drag == null);
}

test "forms slider thumb follows constrained width not requested width" {
    const f = try Fixture.create(
        \\function build() return ouro.box {key='narrow', width=160,
        \\ ouro.slider {key='level', label='Level', width=300, value=7.5, min=0, max=10, step=0.5}} end
    );
    defer f.destroy();
    const semantic = try f.runtime.semantics.findPath("narrow/level");
    const render = try f.runtime.instances.renderObject(f.runtime.instances.handleForId(semantic.id).?);
    const layers = f.runtime.tree.firstChild(render).?;
    const track = f.runtime.tree.firstChild(layers).?;
    const rail = f.runtime.tree.nextSibling(track).?;
    const thumb = f.runtime.tree.nextSibling(f.runtime.tree.firstChild(rail).?).?;
    try std.testing.expectEqual(@as(f32, 160), (try f.runtime.tree.nodeSize(render)).width);
    try std.testing.expectApproxEqAbs(@as(f32, 99), (try f.runtime.tree.nodeOffset(thumb)).x, 0.01);
    try std.testing.expectEqual(@as(f32, 16), (try f.runtime.tree.nodeSize(thumb)).width);
}

test "forms disabling slider on change cancels the active drag" {
    const f = try Fixture.create(
        \\enabled=ouro.signal(true)
        \\function build() return ouro.slider {key='level', label='Level', width=200,
        \\ value=0, min=0, max=10, step=1, enabled=enabled(),
        \\ on_change=function() enabled:set(false) end} end
    );
    defer f.destroy();
    try f.play(.{ .pointer_down = "level" });
    try std.testing.expect(!(try f.runtime.semantics.findPath("level")).enabled);
    try std.testing.expect(f.runtime.range_drag == null);
}

test "forms dialog contains focus and restores opener after escape" {
    const f = try Fixture.create(
        \\opened=ouro.signal(false)
        \\function build()
        \\ local children={ouro.button {key='open', label='Open', on_press=function() opened:set(true) end}}
        \\ if opened() then children[2]=ouro.dialog {key='dialog', label='Confirm', width=240,
        \\   on_cancel=function() opened:set(false) end,
        \\   ouro.row {key='actions', gap=8,
        \\     ouro.button {key='first', label='Keep'}, ouro.button {key='last', label='Discard'}}} end
        \\ return ouro.stack {key='root', children=children}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .click = "root/open" });
    const first = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/dialog/actions/first")).id).?;
    const last = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/dialog/actions/last")).id).?;
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab, .modifiers = .{ .shift = true } } });
    try std.testing.expectEqual(last, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary == null);
    try std.testing.expectEqual(f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/open")).id).?, f.runtime.focus.current().?);
}

test "forms dialog escape bubbles from plain fields but not active composition" {
    const f = try Fixture.create(
        \\opened=ouro.signal(true)
        \\function build() return ouro.stack {key='root',
        \\ opened() and ouro.dialog {key='dialog', label='Edit', on_cancel=function() opened:set(false) end,
        \\ ouro.text_input {key='name', default_text='name'}} or ouro.button {key='done', label='Done'}} end
    );
    defer f.destroy();
    const session = try f.runtime.text_inputs.session(f.runtime.focus.current().?);
    _ = try session.apply(.{ .preedit = .{ .text = "composing", .cursor = null } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary != null);
    _ = try session.apply(.{ .preedit = .{ .text = null, .cursor = null } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary == null);
}

test "forms spinbox commits typed drafts and applies native bounds" {
    const f = try Fixture.create(
        \\value=ouro.signal(-1.25)
        \\function build() return ouro.spinbox {key='number', label='Number', value=value(),
        \\ min=-2.25, max=3, step=0.5, on_change=function(v) value:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_a, .modifiers = .{ .control = true } } });
    try f.play(.{ .text = "99" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("3.0", (try node(snapshot, "number/control/value")).value.?);
    try std.testing.expect(!(try node(snapshot, "number/control/increase")).enabled);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down } });
    var changed = try f.snapshot();
    defer changed.deinit();
    try std.testing.expectEqualStrings("2.75", (try node(changed, "number/control/value")).value.?);
}

test "development click releases a button disabled by its own press handler" {
    const f = try Fixture.create(
        \\busy = ouro.signal(false)
        \\function build()
        \\  return ouro.button {key='save', label='Save', enabled=not busy(), on_press=function() busy:set(true) end}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .click = "save" });
    try std.testing.expect(!(try f.runtime.semantics.findPath("save")).enabled);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "save" }));
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
