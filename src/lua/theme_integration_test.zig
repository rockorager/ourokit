const std = @import("std");
const c = @import("c.zig");
const UiBuild = @import("ui_build.zig").UiBuild;
const Signals = @import("signals.zig").Signals;
const Vm = @import("vm.zig").Vm;
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const core = @import("../core/root.zig");
const instance = @import("../ui/instance/tree.zig");
const semantics = @import("../ui/semantics/snapshot.zig");
const Object = @import("../ui/render_object/types.zig").Object;
const WindowRuntime = @import("../app/window_runtime.zig").WindowRuntime;

const Fixture = struct {
    state: *c.State,
    loop: @import("../loop/io_uring.zig").Loop = undefined,
    vm: Vm = undefined,
    callbacks: @import("callbacks.zig").CallbackRegistry = undefined,
    scheduler: task.Scheduler = undefined,
    scope: task.ScopeHandle = undefined,
    signals: Signals = undefined,
    fonts: text.FontCache = undefined,
    font: [1]text.FontHandle = undefined,
    sources: text.ParagraphSourceCache = undefined,
    paragraphs: text.ParagraphCache = undefined,
    ui: UiBuild = undefined,
    runtime: WindowRuntime = .{},
    descriptors: [128]instance.Descriptor = undefined,
    semantic_storage: [128]semantics.Descriptor = undefined,

    fn create() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.* = .{ .state = undefined };
        try self.loop.init(std.testing.allocator, 8, 2);
        try self.scheduler.init(std.testing.allocator, 1024, 16, 4);
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        self.state = self.vm.state;
        self.vm.pushApi(self.state);
        c.lua_setglobal(self.state, "ouro");
        try self.callbacks.init(std.testing.allocator, 128);
        self.scope = try self.scheduler.createScope(self.scheduler.application_scope);
        try self.signals.init(std.testing.allocator, self.state, 1024, 1024, 1024);
        self.fonts = text.FontCache.init(std.testing.allocator);
        self.font[0] = try self.fonts.acquire(.{
            .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 },
            .bytes = @embedFile("ourokit_test_font_static"),
        });
        self.sources = text.ParagraphSourceCache.init(std.testing.allocator, &self.fonts);
        self.paragraphs = text.ParagraphCache.init(std.testing.allocator, &self.fonts);
        try self.ui.init(self.state, &self.descriptors);
        self.ui.attachCallbacks(&self.callbacks, &self.vm);
        self.ui.attachSignals(&self.signals);
        try self.ui.attachSemantics(&self.semantic_storage);
        try self.ui.attachText(&self.sources, &self.font, 1);
        const theme = @import("../design/root.zig").tokens.light;
        self.ui.enableDeclarativeWidgets(theme);
        try self.runtime.init(std.testing.allocator, &self.scheduler, self.scope, .{ .slot = 0, .generation = 1 }, theme.background, theme.primary, theme.foreground, theme.input, theme.ring, &self.signals, &self.sources, &self.paragraphs, .{});
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.runtime.clear(&self.ui) catch unreachable;
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

    fn exec(self: *Fixture, source: []const u8) !void {
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        if (c.luaL_loadbufferx(self.state, source.ptr, source.len, "@theme-test", "t") != c.ok or
            c.lua_pcallk(self.state, 0, 0, 0, 0, null) != c.ok) return error.LuaTestFailed;
    }

    fn build(self: *Fixture) !void {
        _ = c.lua_getglobal(self.state, "build");
        const reference = c.luaL_ref(self.state, c.registry_index);
        defer c.luaL_unref(self.state, c.registry_index, reference);
        try self.runtime.reconcile(.{ .width = 600, .height = 500 }, &self.ui, reference);
        try self.scheduler.applyQueuedCancellations();
        try self.runtime.collectRetired();
    }

    fn handle(self: *Fixture, path: []const u8) !instance.InstanceHandle {
        return self.runtime.instances.handleForId((try self.runtime.semantics.findPath(path)).id).?;
    }

    fn object(self: *Fixture, path: []const u8) !Object {
        return self.runtime.tree.objectAt(try self.runtime.instances.renderObject(try self.handle(path)));
    }

    fn tab(self: *Fixture) !void {
        try self.runtime.routeKeyboard(.{ .key = .{ .window = self.runtime.window, .serial = 1, .time_ms = 1, .state = .pressed, .translated = .{ .keycode = 0, .logical = .tab } } });
        var unused: Vm = undefined;
        try self.runtime.dispatchInput(&unused);
    }

    fn pointer(self: *Fixture, event: @import("../platform/window.zig").PointerEvent) !void {
        try self.runtime.routePointer(event);
        var unused: Vm = undefined;
        try self.runtime.dispatchInput(&unused);
        try self.runtime.prepareFrame(1);
    }

    fn pixels(self: *Fixture) ![]u8 {
        const software = @import("../renderer/software/root.zig");
        if (!software.has_freetype) return error.SkipZigTest;
        try self.runtime.prepareFrame(1);
        const size = self.runtime.frame_state.size.?;
        const result = try std.testing.allocator.alloc(u8, size.width * size.height * 4);
        errdefer std.testing.allocator.free(result);
        var glyphs = try software.GlyphCache.init(std.testing.allocator, &self.fonts);
        defer glyphs.deinit();
        const list = try self.runtime.displayList();
        try software.renderParagraphs(.{ .commands = list.commands }, .{
            .pixels = result,
            .width = size.width,
            .height = size.height,
            .stride = size.width * 4,
            .format = .rgba8_unorm,
        }, &glyphs, &self.paragraphs);
        return result;
    }

    fn queueIme(self: *Fixture, commit: ?[]const u8, preedit: ?[]const u8, generation: ?u64) !void {
        try self.runtime.routeTextInput(.{ .batch = .{
            .window = self.runtime.window,
            .generation = generation,
            .serial = 7,
            .serial_matches_state = false,
            .delete_surrounding = null,
            .commit = if (commit) |value| .{ .text = value } else null,
            .preedit = if (preedit) |value| .{ .text = value, .cursor_begin = @intCast(value.len), .cursor_end = @intCast(value.len) } else null,
        } });
    }

    fn dispatch(self: *Fixture) !void {
        var unused: Vm = undefined;
        try self.runtime.dispatchInput(&unused);
        try self.runtime.prepareFrame(1);
    }
};

test "Switch controlled callbacks, pointer and keyboard preserve state and focus" {
    const platform = @import("../platform/window.zig");
    const tokens = @import("../design/root.zig").tokens;
    const input = struct {
        fn settle(f: *Fixture) !void {
            try f.runtime.dispatchInput(&f.callbacks);
            while (f.scheduler.takeRunnable()) |handle| {
                try std.testing.expectEqual(.completed, try f.vm.resumeRunnable(handle));
            }
            try f.build();
        }
        fn key(f: *Fixture, logical: platform.LogicalKey, state: platform.KeyState, shift: bool) !void {
            try f.runtime.routeKeyboard(.{ .key = .{
                .window = f.runtime.window,
                .serial = 7,
                .time_ms = 0,
                .state = state,
                .translated = .{ .keycode = 0, .logical = logical, .modifiers = .{ .shift = shift } },
            } });
            try settle(f);
        }
        fn pointer(f: *Fixture, path: []const u8, button: u32, state: platform.PointerButtonState) !void {
            const target = try f.runtime.semanticTarget(path);
            // Hit the thumb as well as the track, rather than targeting an instance directly.
            try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 0, .position = .{ .x = target.center.x - 10, .y = target.center.y } } });
            try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 9, .time_ms = 0, .button = button, .state = state } });
            try settle(f);
        }
    };
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\checked, enabled, dark, reverse = ouro.signal(false), ouro.signal(true), ouro.signal(false), ouro.signal(false)
        \\accept, calls, values = false, 0, ''
        \\function changed(value)
        \\  assert(type(value) == 'boolean')
        \\  calls = calls + 1; values = values .. (value and 'T' or 'F')
        \\  if accept then checked:set(value) end
        \\end
        \\function build()
        \\  local toggle = ouro.switch {key='dnd', label='Do Not Disturb', checked=checked(), enabled=enabled(), on_change=changed}
        \\  local other = ouro.switch {key='other', label='Other', checked=true}
        \\  return ouro.theme {key='theme', color_scheme=dark() and 'dark' or 'light',
        \\    ouro.column {key='row', gap=12, children=reverse() and {other, toggle} or {toggle, other}}}
        \\end
    );
    try f.build();
    const path = "theme/row/dnd";
    const target = try f.handle(path);
    const semantic = try f.runtime.semantics.findPath(path);
    try std.testing.expectEqual(.@"switch", semantic.role);
    try std.testing.expectEqualStrings("Do Not Disturb", semantic.label);
    try std.testing.expect(!semantic.checked);
    const track = f.runtime.tree.firstChild(try f.runtime.instances.renderObject(target)).?;
    const thumb = f.runtime.tree.firstChild(track).?;
    try std.testing.expectEqual(@as(f32, 43), (try f.object(path)).box.width.?);
    try std.testing.expectEqual(@as(f32, 35), (try f.runtime.tree.objectAt(track)).box.width.?);
    try std.testing.expectEqual(@as(f32, 4), (try f.runtime.tree.nodeOffset(track)).x);
    try input.key(f, .tab, .pressed, false);
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    try std.testing.expectEqual(tokens.light.ring, (try f.object(path)).box.border_color.?);
    try input.key(f, .space, .pressed, false);
    try input.key(f, .space, .repeated, false);
    try input.key(f, .space, .repeated, false);
    try input.key(f, .space, .released, false);
    try f.exec("assert(calls == 1 and values == 'T')");
    try std.testing.expect(!(try f.runtime.semantics.findPath(path)).checked);
    try std.testing.expectEqual(@as(f32, 1), (try f.runtime.tree.nodeOffset(thumb)).x);

    try f.exec("accept = true");
    try input.pointer(f, path, 0x111, .pressed);
    try input.pointer(f, path, 0x111, .released);
    try f.exec("assert(calls == 1)");
    try input.pointer(f, path, 0x110, .pressed);
    try std.testing.expect((try f.runtime.semantics.findPath(path)).checked);
    try std.testing.expectEqual(@as(f32, 16), (try f.runtime.tree.nodeOffset(thumb)).x);
    try input.pointer(f, path, 0x110, .released);
    try f.exec("assert(calls == 2 and values == 'TT')");
    try input.key(f, .enter, .pressed, false);
    try input.key(f, .enter, .repeated, false);
    try input.key(f, .enter, .released, false);
    try f.exec("assert(calls == 3 and values == 'TTF')");
    try std.testing.expect(!(try f.runtime.semantics.findPath(path)).checked);

    // External updates, reordering, and theme changes do not invoke on_change or remount.
    try f.exec("checked:set(true); dark:set(true); reverse:set(true)");
    try f.build();
    try std.testing.expectEqual(target, try f.handle(path));
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    try std.testing.expectEqual(tokens.dark.primary, (try f.runtime.tree.objectAt(track)).box.background.?);
    try std.testing.expectEqual(tokens.dark.ring, (try f.object(path)).box.border_color.?);
    try f.exec("assert(calls == 3)");
    try input.key(f, .space, .pressed, false);
    // Reconciliation happened while Space is held. Repeat must still be ignored.
    try input.key(f, .space, .repeated, false);
    try input.key(f, .space, .released, false);
    try f.exec("assert(calls == 4 and values == 'TTFF')");
    try input.key(f, .space, .pressed, false);
    try f.exec("enabled:set(false)");
    try f.build();
    try std.testing.expect(f.runtime.focus.current() == null);
    try std.testing.expect(!(try f.runtime.semantics.findPath(path)).enabled);
    try std.testing.expect((try f.runtime.semantics.findPath(path)).checked);
    try std.testing.expectEqual(@as(u8, 0), (try f.object(path)).box.border_color.?.a);
    try input.key(f, .space, .repeated, false);
    try input.key(f, .space, .released, false);
    try input.pointer(f, path, 0x110, .pressed);
    try input.pointer(f, path, 0x110, .released);
    try f.exec("assert(calls == 5 and values == 'TTFFT')");
    try input.key(f, .tab, .pressed, false);
    const other = try f.handle("theme/row/other");
    try std.testing.expectEqual(other, f.runtime.focus.current().?);
    try input.key(f, .tab, .pressed, true);
    try std.testing.expectEqual(other, f.runtime.focus.current().?);
    try f.exec("enabled:set(true)");
    try f.build();
    try input.key(f, .tab, .pressed, false);
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    // Replace the callback on a retained declaration; no stale closure survives.
    try f.exec("changed = function(value) assert(value == false); calls = calls + 10 end");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try input.key(f, .enter, .pressed, false);
    try f.exec("assert(calls == 15)");
    try std.testing.expect((try f.runtime.semantics.findPath(path)).checked);
}

test "Switch prepared commits preserve focus and copy checked semantics atomically" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("function build() return ouro.switch {key='dnd', label='Do Not Disturb', checked=true} end");
    try f.build();
    const target = try f.handle("dnd");
    try f.tab();
    try f.exec("function build() return ouro.switch {key='dnd', label='Quiet mode', checked=false, on_change=function(value) result=value end} end");
    _ = c.lua_getglobal(f.state, "build");
    const reference = c.luaL_ref(f.state, c.registry_index);
    defer c.luaL_unref(f.state, c.registry_index, reference);
    var prepared: @import("prepared_build.zig").PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, f.state, &f.sources, 128, 1024);
    defer prepared.deinit();
    try f.runtime.prepareSourceBuild(.{ .width = 600, .height = 500 }, &f.ui, &prepared, reference, 2);
    try std.testing.expect((try f.runtime.semantics.findPath("dnd")).checked);
    try f.callbacks.ensureAvailable(prepared.handler_count);
    f.runtime.commitPreparedSource(&prepared, &f.callbacks, &f.vm, &f.signals);
    try std.testing.expectEqual(target, try f.handle("dnd"));
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    try std.testing.expect(!(try f.runtime.semantics.findPath("dnd")).checked);
    try std.testing.expectEqualStrings("Quiet mode", (try f.runtime.semantics.findPath("dnd")).label);
    try std.testing.expectEqual(@import("../design/root.zig").tokens.light.ring, (try f.object("dnd")).box.border_color.?);
    try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .serial = 1, .time_ms = 0, .state = .pressed, .translated = .{ .keycode = 0, .logical = .space } } });
    try f.runtime.dispatchInput(&f.callbacks);
    while (f.scheduler.takeRunnable()) |handle| _ = try f.vm.resumeRunnable(handle);
    try f.exec("assert(result == true)");
}

test "Lua stack keeps ordered children and keyed foreground identity" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\reverse = ouro.signal(false)
        \\function build()
        \\  local back = ouro.box { key='back', width=140, height=70, background='#102030' }
        \\  local front = ouro.box { key='front', width=60, height=25, background='#abcdef' }
        \\  return ouro.stack { key='layers', children=reverse() and {front, back} or {back, front} }
        \\end
    );
    try f.build();
    const stack = try f.handle("layers");
    const front = try f.handle("layers/front");
    const back = try f.handle("layers/back");
    const render = try f.runtime.instances.renderObject(stack);
    try std.testing.expect((try f.object("layers")) == .stack);
    try std.testing.expectEqual(.group, (try f.runtime.semantics.findPath("layers")).role);
    try std.testing.expectEqual(try f.runtime.instances.renderObject(front), (try f.runtime.tree.hitTest(render, .{ .x = 10, .y = 10 })).?);
    try f.exec("reverse:set(true)");
    try f.build();
    try std.testing.expectEqual(front, try f.handle("layers/front"));
    try std.testing.expectEqual(back, try f.handle("layers/back"));
    try std.testing.expectEqual(try f.runtime.instances.renderObject(back), (try f.runtime.tree.hitTest(render, .{ .x = 10, .y = 10 })).?);
}

test "Lua box decoration preserves defaults and explicit background overrides surface" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\function build() return ouro.column { key = 'root',
        \\  ouro.box { key = 'default', width = 'fill', height = 20 },
        \\  ouro.box { key = 'surface', surface = 'sidebar', height = 20 },
        \\  ouro.box { key = 'styled', surface = 'card', background = '#12345680',
        \\    border = '#abcdef', border_width = 2.5, radius = 7, height = 30 },
        \\  ouro.box { key = 'border', border_width = 1, height = 20 },
        \\  ouro.box { key = 'zero', border = '#abcdef', border_width = 0, radius = 0 },
        \\} end
    );
    try f.build();
    const tokens = @import("../design/root.zig").tokens;
    const plain = (try f.object("root/default")).box;
    try std.testing.expect(plain.background == null and plain.border_color == null);
    try std.testing.expectEqual(@as(f32, 0), plain.border_width);
    try std.testing.expectEqual(@as(f32, 0), plain.corner_radius);
    try std.testing.expect(plain.fill_width);
    try std.testing.expectEqual(tokens.light.sidebar, (try f.object("root/surface")).box.background.?);
    const styled = (try f.object("root/styled")).box;
    try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0x56, 0x80), styled.background.?);
    try std.testing.expectEqual(core.Color.rgba(0xab, 0xcd, 0xef, 255), styled.border_color.?);
    try std.testing.expectEqual(@as(f32, 2.5), styled.border_width);
    try std.testing.expectEqual(@as(f32, 7), styled.corner_radius);
    try std.testing.expectEqual(tokens.light.border, (try f.object("root/border")).box.border_color.?);
    try std.testing.expect((try f.object("root/zero")).box.border_color == null);
    f.ui.widget_theme.?.colors = tokens.dark;
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(styled.background, (try f.object("root/styled")).box.background);
    try std.testing.expectEqual(tokens.dark.sidebar, (try f.object("root/surface")).box.background.?);
}

test "Lua decoration, stack and input hints reject invalid declarations atomically" {
    const declarations = [_][]const u8{
        "ouro.box {key='bad', background='#xyzxyz'}",
        "ouro.box {key='bad', border='#12345'}",
        "ouro.box {key='bad', background=123}",
        "ouro.box {key='bad', border_width=-1}",
        "ouro.box {key='bad', radius=0/0}",
        "ouro.box {key='bad', radius=1/0}",
        "ouro.box {key='bad', border_width=1e100}",
        "ouro.box {key='bad', radius=1e-100}",
        "ouro.box {key='bad', border_width='2'}",
        "ouro.box {key='bad', surface='invalid', background='#123456'}",
        "ouro.text_input {key='bad', text='', placeholder=3}",
        "ouro.text_input {key='bad', default_text='', label=false}",
        "ouro.switch {key='bad', label='Missing checked'}",
        "ouro.switch {key='bad', label='Invalid checked', checked=1}",
        "ouro.switch {key='bad', checked=false}",
        "ouro.switch {key='bad', label='', checked=false}",
        "ouro.switch {key='bad', label='Disabled', checked=true, enabled='false'}",
        "ouro.switch {key='bad', label='Callback', checked=false, on_change=true}",
        "ouro.switch {key='bad', label='Children', checked=false, ouro.box {key='child'}}",
        "ouro.stack {}",
        "ouro.stack {key='bad', ouro.box {key='child', flex=1}}",
        "ouro.stack {key='bad', children=false}",
        "ouro.stack {key='bad', [2]=ouro.box {key='child'}}",
        "ouro.stack {key='bad', ouro.box {key='child'}, children={}}",
    };
    for (declarations) |declaration| {
        const f = try Fixture.create();
        defer f.destroy();
        try f.exec("function build() return ouro.box {key='good', background='#123456'} end");
        try f.build();
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{declaration});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0x56, 255), (try f.object("good")).box.background.?);
    }
}

test "Lua placeholder and accessible label remain independent of retained input values" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\value = ouro.signal('')
        \\hint = ouro.signal('Search applications')
        \\function build() return ouro.column { key = 'root',
        \\  ouro.text_input {key='controlled', text=value(), placeholder=hint(), label='Application query'},
        \\  ouro.text_input {key='retained', default_text='', placeholder=hint(), label='Retained query'},
        \\  ouro.text_input {key='readonly', text='', placeholder=hint(), read_only=true},
        \\  ouro.text_input {key='disabled', text='', placeholder=hint(), enabled=false},
        \\  ouro.text_input {key='legacy', text='Legacy value'},
        \\} end
    );
    try f.build();
    for ([_][]const u8{ "root/controlled", "root/retained", "root/readonly", "root/disabled" }) |path| {
        const target = try f.handle(path);
        const session = try f.runtime.text_inputs.session(target);
        try std.testing.expectEqualStrings("", session.model.text());
        const render = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(target));
        const input = (try f.runtime.tree.objectAt(render)).text_input;
        try std.testing.expectEqualStrings("", (try f.sources.get(input.source)).utf8);
        try std.testing.expectEqualStrings("Search applications", (try f.sources.get(input.placeholder.?)).utf8);
        try std.testing.expectEqual(@as(usize, 0), input.caret_offset);
        try std.testing.expectEqual(@import("../design/root.zig").tokens.light.muted_foreground, input.placeholder_color);
    }
    try std.testing.expectEqualStrings("Application query", (try f.runtime.semantics.findPath("root/controlled")).label);
    try std.testing.expectEqualStrings("", (try f.runtime.semantics.findPath("root/readonly")).label);
    try std.testing.expectEqualStrings("Legacy value", (try f.runtime.semantics.findPath("root/legacy")).label);
    const retained = try f.handle("root/retained");
    const session = try f.runtime.text_inputs.session(retained);
    _ = try session.apply(.{ .commit = .{ .text = "typed" } });
    try f.exec("value:set('actual'); hint:set('Different hint')");
    try f.build();
    try std.testing.expectEqual(retained, try f.handle("root/retained"));
    try std.testing.expectEqualStrings("typed", (try f.runtime.text_inputs.session(retained)).model.text());
    try std.testing.expectEqualStrings("actual", (try f.runtime.text_inputs.session(try f.handle("root/controlled"))).model.text());
    try std.testing.expectEqualStrings("Application query", (try f.runtime.semantics.findPath("root/controlled")).label);
    try f.exec("value:set(''); hint:set('')");
    try f.build();
    const render = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(try f.handle("root/controlled")));
    const input = (try f.runtime.tree.objectAt(render)).text_input;
    try std.testing.expect(input.placeholder == null);
    try std.testing.expectEqualStrings("", (try f.sources.get(input.source)).utf8);
}

test "Lua tokens work in theme and widget props and preserve button defaults" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\local t = ouro.tokens
        \\function build()
        \\  return ouro.theme { key = 'scope',
        \\    colors = { primary = t.dark.secondary },
        \\    controls = { radius = t.foundation.radius_3, border_width = t.foundation.border_width_strong },
        \\    ouro.column { key = 'root', gap = t.foundation.spacing_5,
        \\      ouro.button { key = 'default', label = 'Default' },
        \\      ouro.text_input { key = 'input', text = 'Tokens', font_size = t.foundation.typography_4,
        \\        foreground = t.palette.light.indigo.step_11 },
        \\      ouro.button { key = 'alpha', label = 'Alpha', background = t.palette.overlay.black.step_5 },
        \\    },
        \\  }
        \\end
    );
    try f.build();
    const button = try f.handle("scope/root/default");
    const box = (try f.object("scope/root/default")).box;
    try std.testing.expectEqual(@as(f32, 6), box.corner_radius);
    try std.testing.expectEqual(@as(f32, 2), box.border_width);
    try std.testing.expectEqual(core.Color.rgba(33, 34, 37, 255), box.background.?);
    const input = try f.handle("scope/root/input");
    const content = try f.runtime.text_inputs.content(input);
    const object = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(content));
    try std.testing.expectEqual(@as(f32, 18), (try f.sources.get(object.text_input.source)).logical_size);
    try std.testing.expectEqual(core.Color.rgba(0, 0, 0, 77), (try f.object("scope/root/alpha")).box.background.?);
    // The button's label remains on the built-in 14px token.
    const button_id = (try f.runtime.semantics.findPath("scope/root/default")).id;
    var found_label = false;
    for (f.ui.storage[0..f.ui.count]) |descriptor| {
        if (descriptor.parent == button_id and descriptor.object == .text) {
            try std.testing.expectEqual(@as(f32, 14), (try f.sources.get(descriptor.object.text.source)).logical_size);
            found_label = true;
            break;
        }
    }
    try std.testing.expect(found_label);
    // A catalog reference is an explicit color; changing the host scheme must
    // not reinterpret it or remount the control.
    f.ui.widget_theme.?.colors = @import("../design/root.zig").tokens.dark;
    try f.build();
    try std.testing.expectEqual(button, try f.handle("scope/root/default"));
    try std.testing.expectEqual(box.background, (try f.object("scope/root/default")).box.background);
}

test "theme inheritance and explicit precedence retheme clean components without remounting" {
    const f = try Fixture.create();
    defer f.destroy();
    f.ui.widget_theme.?.controls.height = 41;
    f.ui.widget_theme.?.controls.radius = 9;
    try f.exec(
        \\changed = ouro.signal(false)
        \\local Child = ouro.component(function()
        \\  return function() return ouro.button { key = 'button', label = 'Child' } end
        \\end)
        \\function build()
        \\  return ouro.column { key = 'root',
        \\    ouro.theme { key = 'scope', controls = { height = changed() and 57 or 33 },
        \\      widgets = { button = { radius = 4, background = '#123456' } },
        \\      ouro.column { key = 'group',
        \\        Child { key = 'child' },
        \\        ouro.button { key = 'explicit', label = 'Local', height = 27, radius = 2, background = '#abcdef' },
        \\      },
        \\    },
        \\    ouro.button { key = 'sibling', label = 'Outside' },
        \\  }
        \\end
    );
    try f.build();
    const child = try f.handle("root/scope/group/child/button");
    var box = (try f.object("root/scope/group/child/button")).box;
    try std.testing.expectEqual(@as(f32, 33), box.height.?);
    try std.testing.expectEqual(@as(f32, 4), box.corner_radius);
    try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0x56, 255), box.background.?);
    box = (try f.object("root/scope/group/explicit")).box;
    try std.testing.expectEqual(@as(f32, 27), box.height.?);
    try std.testing.expectEqual(@as(f32, 2), box.corner_radius);
    try std.testing.expectEqual(core.Color.rgba(0xab, 0xcd, 0xef, 255), box.background.?);
    box = (try f.object("root/sibling")).box;
    try std.testing.expectEqual(@as(f32, 41), box.height.?);
    try std.testing.expectEqual(@as(f32, 9), box.corner_radius);
    try f.exec("changed:set(true)");
    try f.build();
    try std.testing.expectEqual(child, try f.handle("root/scope/group/child/button"));
    try std.testing.expectEqual(@as(f32, 57), (try f.object("root/scope/group/child/button")).box.height.?);
    try std.testing.expectEqual(@as(f32, 41), (try f.object("root/sibling")).box.height.?);
}

test "theme input typography and focus survive rebuilds and zero borders remain valid" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\changed = ouro.signal(false)
        \\function build()
        \\  return ouro.theme { key = 'scope', typography = { size = changed() and 23 or 15 },
        \\    controls = { border_width = 2 },
        \\    widgets = { text_input = { border = '#123456', focus = '#abcdef' }, button = { focus = '#fedcba' } },
        \\    ouro.column { key = 'root',
        \\      ouro.text_input { key = 'input', text = 'Unchanged' },
        \\      ouro.button { key = 'borderless', label = 'Zero', border_width = 0 },
        \\      ouro.button { key = 'bordered', label = 'Bordered' },
        \\    },
        \\  }
        \\end
    );
    try f.build();
    try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0x56, 255), (try f.object("scope/root/input")).box.border_color.?);
    const input = try f.handle("scope/root/input");
    try f.tab();
    try std.testing.expectEqual(input, f.runtime.focus.current().?);
    try std.testing.expectEqual(core.Color.rgba(0xab, 0xcd, 0xef, 255), (try f.object("scope/root/input")).box.border_color.?);
    try f.exec("changed:set(true)");
    try f.build();
    const content = try f.runtime.text_inputs.content(input);
    const object = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(content));
    const source = try f.sources.get(object.text_input.source);
    try std.testing.expectEqual(@as(f32, 23), source.logical_size);
    try std.testing.expectEqualStrings("Unchanged", source.utf8);
    try std.testing.expectEqual(core.Color.rgba(0xab, 0xcd, 0xef, 255), (try f.object("scope/root/input")).box.border_color.?);
    try f.tab();
    try std.testing.expectEqual(@as(?core.Color, null), (try f.object("scope/root/borderless")).box.border_color);
    try f.tab();
    try std.testing.expectEqual(core.Color.rgba(0xfe, 0xdc, 0xba, 255), (try f.object("scope/root/bordered")).box.border_color.?);
}

test "prepared theme changes preserve input text but use candidate typography" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("function build() return ouro.text_input { key = 'input', text = 'Unchanged', font_size = 15 } end");
    try f.build();
    const input = try f.handle("input");
    const content = try f.runtime.text_inputs.content(input);
    const render = try f.runtime.instances.renderObject(content);
    try f.exec("function build() return ouro.text_input { key = 'input', text = 'Unchanged', font_size = 23 } end");
    _ = c.lua_getglobal(f.state, "build");
    const reference = c.luaL_ref(f.state, c.registry_index);
    defer c.luaL_unref(f.state, c.registry_index, reference);
    var prepared: @import("prepared_build.zig").PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, f.state, &f.sources, 128, 1024);
    defer prepared.deinit();
    try f.runtime.prepareSourceBuild(.{ .width = 600, .height = 500 }, &f.ui, &prepared, reference, 2);
    const live = try f.sources.get((try f.runtime.tree.objectAt(render)).text_input.source);
    try std.testing.expectEqual(@as(f32, 15), live.logical_size);
    var found = false;
    for (prepared.descriptors()) |descriptor| {
        if (descriptor.object != .text_input) continue;
        const source = try f.sources.get(descriptor.object.text_input.source);
        try std.testing.expectEqual(@as(f32, 23), source.logical_size);
        try std.testing.expectEqualStrings("Unchanged", source.utf8);
        found = true;
    }
    try std.testing.expect(found);
}

test "host appearance rethemes retained components while app and nested overrides win" {
    const tokens = @import("../design/root.zig").tokens;
    const Application = @import("application.zig").Application;
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\local Child = ouro.component(function()
        \\  return function() return ouro.button { key = 'button', label = 'Retained' } end
        \\end)
        \\function build()
        \\  return ouro.column { key = 'root',
        \\    Child {key = 'child'},
        \\    ouro.theme {key = 'fixed', color_scheme = 'light',
        \\      ouro.button {key = 'button', label = 'Pinned'},
        \\    },
        \\  }
        \\end
    );
    var application = try Application.load(std.testing.allocator, f.state,
        \\return ouro.app {
        \\  id = 'dev.test.appearance',
        \\  theme = {controls = {height = 45}, colors = {background = '#ffffff'}},
        \\  windows = {ouro.window {id = 'main', title = 'Appearance', content = build}},
        \\}
    );
    defer application.deinit();
    f.ui.widget_theme = application.resolvedTheme(tokens.light);
    try f.build();
    const child = try f.handle("root/child/button");
    f.ui.widget_theme = application.resolvedTheme(tokens.dark);
    try f.runtime.setTheme(f.ui.widget_theme.?.colors);
    try f.build();
    try std.testing.expectEqual(child, try f.handle("root/child/button"));
    try std.testing.expectEqual(tokens.dark.primary, (try f.object("root/child/button")).box.background.?);
    try std.testing.expectEqual(tokens.light.primary, (try f.object("root/fixed/button")).box.background.?);
    try std.testing.expectEqual(@as(f32, 45), (try f.object("root/child/button")).box.height.?);
    try std.testing.expectEqual(core.Color.rgba(255, 255, 255, 255), f.ui.widget_theme.?.colors.background);
    try std.testing.expectEqual(tokens.dark.foreground, f.ui.widget_theme.?.colors.foreground);

    var pinned = try Application.load(std.testing.allocator, f.state,
        \\return ouro.app {
        \\  id = 'dev.test.pinned', theme = {color_scheme = 'light'},
        \\  windows = {ouro.window {id = 'main', title = 'Pinned', content = build}},
        \\}
    );
    defer pinned.deinit();
    try std.testing.expectEqualDeep(tokens.light, pinned.resolvedTheme(tokens.dark).colors);
}

test "app and field keymaps dispatch edits and clipboard actions across retained rebuilds" {
    const platform = @import("../platform/window.zig");
    const dispatch = struct {
        fn press(f: *Fixture, logical: platform.LogicalKey, modifiers: platform.Modifiers) !void {
            try f.runtime.routeKeyboard(.{ .key = .{
                .window = f.runtime.window,
                .serial = 37,
                .time_ms = 1,
                .state = .pressed,
                .translated = .{ .keycode = 0, .logical = logical, .modifiers = modifiers },
            } });
            var unused: Vm = undefined;
            try f.runtime.dispatchInput(&unused);
        }
    };
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\overrides = {['Alt+R'] = 'select_all'}
        \\read_only = false
        \\function build()
        \\  return ouro.text_input {key = 'input', default_text = 'one Ωtwo',
        \\    autofocus = true, read_only = read_only, key_bindings = overrides}
        \\end
    );
    var app = try @import("application.zig").Application.load(std.testing.allocator, f.state,
        \\return ouro.app {
        \\  id = 'dev.test.keymaps',
        \\  text_input_bindings = {
        \\    ['Ctrl+Z'] = false, ['Alt+U'] = 'undo', ['Alt+R'] = 'redo',
        \\    ['Ctrl+B'] = 'move_word_previous', ['Ctrl+Shift+B'] = 'select_word_previous',
        \\    ['Alt+D'] = 'delete_word_forward', ['Tab'] = 'select_all',
        \\    ['Ctrl+X'] = false, ['Alt+X'] = 'cut', ['Alt+C'] = 'copy', ['Alt+V'] = 'paste',
        \\  },
        \\  windows = {ouro.window {id = 'main', title = 'Bindings', content = build}},
        \\}
    );
    defer app.deinit();
    f.ui.text_input_bindings = app.text_input_bindings;
    try f.build();
    const target = try f.handle("input");
    const session = try f.runtime.text_inputs.session(target);
    _ = try session.typeText("!");
    try dispatch.press(f, .key_z, .{ .control = true });
    try std.testing.expectEqualStrings("one Ωtwo!", session.model.text());
    try dispatch.press(f, .key_u, .{ .alt = true });
    try std.testing.expectEqualStrings("one Ωtwo", session.model.text());
    try dispatch.press(f, .key_r, .{ .alt = true });
    try std.testing.expectEqualStrings("one Ωtwo", session.model.selectedText());

    // Mutating the Lua table alone cannot mutate the mounted native map.
    try f.exec("overrides['Alt+R'] = nil");
    _ = try session.model.setSelection(.collapsed(0));
    try dispatch.press(f, .key_r, .{ .alt = true });
    try std.testing.expectEqualStrings("one Ωtwo", session.model.selectedText());
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(target, try f.handle("input"));
    try dispatch.press(f, .key_r, .{ .alt = true });
    try std.testing.expectEqualStrings("one Ωtwo!", session.model.text());
    try dispatch.press(f, .key_u, .{ .alt = true });
    try dispatch.press(f, .key_b, .{ .control = true });
    try std.testing.expectEqual(@as(usize, 4), session.model.selection.extent);
    try dispatch.press(f, .key_b, .{ .control = true, .shift = true });
    try std.testing.expectEqual(@as(usize, 4), session.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    try dispatch.press(f, .key_d, .{ .alt = true });
    try std.testing.expectEqualStrings("Ωtwo", session.model.text());
    try dispatch.press(f, .key_u, .{ .alt = true });
    try dispatch.press(f, .tab, .{});
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    try std.testing.expectEqualStrings("one Ωtwo", session.model.selectedText());

    var clipboard: @import("../app/clipboard.zig").Coordinator = undefined;
    try clipboard.init(std.testing.allocator, &f.scheduler, 2, 4, 1024);
    defer clipboard.deinit();
    clipboard.setPlatformAvailable(true);
    f.runtime.clipboard = &clipboard;
    defer f.runtime.clipboard = null;
    try dispatch.press(f, .key_x, .{ .control = true });
    try std.testing.expect(clipboard.takeAction() == null);
    try std.testing.expectEqualStrings("one Ωtwo", session.model.text());
    for ([_]platform.LogicalKey{ .key_c, .key_x }) |logical| {
        try dispatch.press(f, logical, .{ .alt = true });
        const action = clipboard.takeAction().?;
        defer clipboard.releaseAction(action);
        try std.testing.expectEqual(@as(u32, 37), action.set_selection.serial);
        try std.testing.expectEqualStrings("one Ωtwo", action.set_selection.text);
    }
    try std.testing.expectEqualStrings("", session.model.text());
    try dispatch.press(f, .key_v, .{ .alt = true });
    const request = clipboard.takeAction().?.request_paste;
    try std.testing.expectEqual(f.runtime.window, request.window);
    try clipboard.completePaste(request.request, "pasted");
    const completion = clipboard.takeCompletion().?;
    try std.testing.expectEqual(target, completion.target.text_input);
    var unused: Vm = undefined;
    try std.testing.expect(try f.runtime.applyClipboardPaste(&unused, target, completion.text.?));
    try clipboard.releaseCompletion(completion.request);
    try std.testing.expectEqualStrings("pasted", session.model.text());

    // A failed build cannot install even the valid part of a replacement map.
    try f.exec("overrides = {['Alt+U'] = false, ['Ctrl+'] = 'undo'}");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try dispatch.press(f, .key_u, .{ .alt = true });
    try std.testing.expectEqualStrings("", session.model.text());
    try dispatch.press(f, .key_r, .{ .alt = true });
    try f.exec("overrides = {}; read_only = true");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try dispatch.press(f, .tab, .{});
    try dispatch.press(f, .key_u, .{ .alt = true });
    try dispatch.press(f, .key_x, .{ .alt = true });
    try dispatch.press(f, .key_v, .{ .alt = true });
    try std.testing.expectEqualStrings("pasted", session.model.text());
    try std.testing.expect(clipboard.takeAction() == null);
    try dispatch.press(f, .key_c, .{ .alt = true });
    const copied = clipboard.takeAction().?;
    try std.testing.expectEqualStrings("pasted", copied.set_selection.text);
    clipboard.releaseAction(copied);

    try f.exec("read_only = false");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    _ = try session.model.setSelection(.collapsed(6));
    _ = try session.apply(.{ .preedit = .{ .text = "候", .cursor = null } });
    try dispatch.press(f, .key_u, .{ .alt = true });
    try dispatch.press(f, .key_v, .{ .alt = true });
    try std.testing.expectEqualStrings("pasted", session.model.text());
    try std.testing.expectEqualStrings("候", session.preedit().?.text);
    try std.testing.expect(clipboard.takeAction() == null);

    _ = try session.apply(.{});
    try f.exec("overrides = {inherit = false, ['A'] = false}");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try dispatch.press(f, .backspace, .{});
    try dispatch.press(f, .key_z, .{ .control = true });
    try dispatch.press(f, .key_u, .{ .alt = true });
    try std.testing.expectEqualStrings("pasted", session.model.text());
    for ([_]struct { key: platform.LogicalKey, unicode: u32, expected: []const u8 }{
        .{ .key = .key_a, .unicode = 'a', .expected = "pasted" },
        .{ .key = .key_b, .unicode = 'b', .expected = "pastedb" },
    }) |case| {
        try f.runtime.routeKeyboard(.{ .key = .{
            .window = f.runtime.window,
            .serial = 38,
            .time_ms = 2,
            .state = .pressed,
            .translated = .{ .keycode = 0, .logical = case.key, .unicode = case.unicode },
        } });
        try f.runtime.dispatchInput(&unused);
        try std.testing.expectEqualStrings(case.expected, session.model.text());
    }
}

test "native input dispatch selects words lines and shift anchored ranges" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("function build() return ouro.text_input {key = 'input', default_text = 'one two three'} end");
    try f.build();
    try f.runtime.prepareFrame(1);
    const session = try f.runtime.text_inputs.session(try f.handle("input"));
    try f.pointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = .{ .x = 14, .y = 16 } } });
    for (1..4) |count| {
        try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 2, .time_ms = @intCast(count * 100), .button = 0x110, .state = .pressed } });
        if (count == 1) try std.testing.expect(session.model.selection.isCollapsed());
        if (count == 2) {
            try std.testing.expectEqual(@as(usize, 0), session.model.selection.anchor);
            try std.testing.expectEqual(@as(usize, 3), session.model.selection.extent);
        }
        if (count == 3) try std.testing.expectEqual(@as(usize, 13), session.model.selection.extent);
        try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 3, .time_ms = @intCast(count * 100 + 1), .button = 0x110, .state = .released } });
    }
    _ = try session.model.setSelection(.{ .anchor = 13, .extent = 4, .anchor_affinity = .upstream });
    try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 4, .time_ms = 400, .button = 0x110, .state = .pressed, .modifiers = .{ .shift = true } } });
    try std.testing.expectEqual(@as(usize, 13), session.model.selection.anchor);
    try std.testing.expectEqual(text.CaretAffinity.upstream, session.model.selection.anchor_affinity);
    try std.testing.expect(session.model.selection.extent < 3);
}

test "stationary edge dragging scrolls to both limits and stops on release" {
    const f = try Fixture.create();
    defer f.destroy();
    f.runtime.root_padding = 0;
    try f.exec("function build() return ouro.column {key = 'root', ouro.text_input {key = 'input', width = 140, default_text = 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen'}} end");
    try f.build();
    try f.runtime.prepareFrame(1);
    const input = try f.handle("root/input");
    const session = try f.runtime.text_inputs.session(input);
    const render = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(input));
    try f.pointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = .{ .x = 9, .y = 16 } } });
    try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 2, .time_ms = 1, .button = 0x110, .state = .pressed } });
    try f.pointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = .{ .x = 200, .y = 16 } } });
    const initial_extent = session.model.selection.extent;
    try std.testing.expect((try f.runtime.animationDelay()) != null);
    for (0..100) |tick| {
        try f.runtime.advanceAnimations(tick * 16 * std.time.ns_per_ms);
        try f.runtime.prepareFrame(1);
    }
    try std.testing.expect(session.model.selection.extent > initial_extent);
    try std.testing.expectEqual(session.model.text().len, session.model.selection.extent);
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollDelta(render, 100));
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    try f.pointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 3, .position = .{ .x = -80, .y = 16 } } });
    for (100..200) |tick| {
        try f.runtime.advanceAnimations(tick * 16 * std.time.ns_per_ms);
        try f.runtime.prepareFrame(1);
    }
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollDelta(render, -100));
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    try f.pointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 4, .position = .{ .x = 200, .y = 16 } } });
    try std.testing.expect((try f.runtime.animationDelay()) != null);
    try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 3, .time_ms = 5, .button = 0x110, .state = .released } });
    try std.testing.expect(!session.isSelecting());
    try std.testing.expect((try f.runtime.animationDelay()) == null);
}

test "edge scrolling stops for composition focus loss disabled and removed inputs" {
    for (0..4) |reason| {
        const f = try Fixture.create();
        defer f.destroy();
        f.runtime.root_padding = 0;
        try f.exec("enabled = true; show = true; function build() return ouro.column {key = 'root', show and ouro.text_input {key = 'input', enabled = enabled, width = 100, default_text = 'one two three four five six seven eight nine ten'} or ouro.text {key = 'empty', text = 'Removed'}} end");
        try f.build();
        try f.pointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = .{ .x = 10, .y = 16 } } });
        try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 2, .time_ms = 1, .button = 0x110, .state = .pressed } });
        try f.pointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = .{ .x = 200, .y = 16 } } });
        try std.testing.expect((try f.runtime.animationDelay()) != null);
        switch (reason) {
            0 => {
                const session = try f.runtime.text_inputs.session(try f.handle("root/input"));
                _ = try session.apply(.{ .preedit = .{ .text = "é", .cursor = null } });
            },
            1 => {
                try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 3 } });
                var unused: Vm = undefined;
                try f.runtime.dispatchInput(&unused);
            },
            else => {
                try f.exec(if (reason == 2) "enabled = false" else "show = false");
                _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
                try f.build();
            },
        }
        try f.runtime.advanceAnimations(16 * std.time.ns_per_ms);
        try std.testing.expect((try f.runtime.animationDelay()) == null);
    }
}

test "caret blink deadlines survive rebuilds and only caret pixels change" {
    const ms = std.time.ns_per_ms;
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("function build() return ouro.column {key = 'root', ouro.text_input {key = 'input', width = 300, autofocus = true, default_text = 'A long line that scrolls horizontally while editing should feel natural.'}} end");
    try f.build();
    const input = try f.handle("root/input");
    const session = try f.runtime.text_inputs.session(input);
    _ = try session.model.setSelection(.collapsed(session.model.text().len));
    try f.runtime.advanceAnimations(0);
    const on = try f.pixels();
    defer std.testing.allocator.free(on);
    const caret = (try f.runtime.textInputStatus()).?.state.cursor_rectangle.?;
    const revision = session.model.revision;
    try std.testing.expectEqual(@as(?u64, 500 * ms), try f.runtime.animationDelay());
    try f.runtime.advanceAnimations(499 * ms);
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expect(f.runtime.caret_visible);
    try std.testing.expectEqual(@as(?u64, ms), try f.runtime.animationDelay());
    try f.runtime.advanceAnimations(500 * ms);
    try std.testing.expect(!f.runtime.caret_visible);
    const off = try f.pixels();
    defer std.testing.allocator.free(off);
    try std.testing.expectEqualDeep(caret, (try f.runtime.textInputStatus()).?.state.cursor_rectangle.?);
    try std.testing.expectEqual(revision, session.model.revision);
    var changed: usize = 0;
    for (on, off, 0..) |a, b, index| {
        if (a == b) continue;
        changed += 1;
        const x: i32 = @intCast((index / 4) % 600);
        const y: i32 = @intCast((index / 4) / 600);
        try std.testing.expect(x >= caret.x and x < caret.x + caret.width);
        // A fractional origin can cover an extra row beyond the IME height.
        try std.testing.expect(y >= caret.y and y <= caret.y + caret.height);
    }
    try std.testing.expect(changed > 0);
    // Missing two deadlines must preserve the phase, not toggle just once.
    try f.runtime.advanceAnimations(1750 * ms);
    try std.testing.expect(!f.runtime.caret_visible);
    try std.testing.expectEqual(@as(?u64, 250 * ms), try f.runtime.animationDelay());
    try f.runtime.advanceAnimations(2000 * ms);
    try std.testing.expect(f.runtime.caret_visible);
    try f.runtime.advanceAnimations(2500 * ms);
    try std.testing.expect(!f.runtime.caret_visible);
    // An interaction at the existing boundary still resets blinking.
    try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .serial = 1, .time_ms = 2600, .state = .pressed, .translated = .{ .keycode = 0, .logical = .end } } });
    var unused: Vm = undefined;
    try f.runtime.dispatchInput(&unused);
    try std.testing.expect(f.runtime.caret_visible);
    try f.runtime.advanceAnimations(2600 * ms);
    try f.runtime.advanceAnimations(3099 * ms);
    try std.testing.expect(f.runtime.caret_visible);
    try f.runtime.advanceAnimations(3100 * ms);
    try std.testing.expect(!f.runtime.caret_visible);
    f.runtime.caret_blink_interval_ns = 0;
    try f.runtime.advanceAnimations(3200 * ms);
    try std.testing.expect(f.runtime.caret_visible);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
}

test "caret stays steady for composition and pauses for selection and window focus" {
    const ms = std.time.ns_per_ms;
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("enabled = true; read_only = false; function build() return ouro.text_input {key = 'input', default_text = 'Typing', autofocus = true, enabled = enabled, read_only = read_only} end");
    try f.build();
    const input = try f.handle("input");
    const session = try f.runtime.text_inputs.session(input);
    const render = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(input));
    try f.runtime.advanceAnimations(0);
    try f.runtime.advanceAnimations(500 * ms);
    try std.testing.expect(!(try f.runtime.tree.objectAt(render)).text_input.show_caret);
    var unused: Vm = undefined;
    for (0..3) |tick| {
        try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .serial = 1, .time_ms = 600, .state = .pressed, .translated = .{ .keycode = 0, .unicode = 'x' } } });
        try f.runtime.dispatchInput(&unused);
        try f.runtime.advanceAnimations((600 + tick * 300) * ms);
        try std.testing.expect((try f.runtime.tree.objectAt(render)).text_input.show_caret);
    }
    try std.testing.expectEqualStrings("Typingxxx", session.model.text());
    _ = try session.apply(.{ .preedit = .{ .text = "é", .cursor = .{ .start = 2, .end = 2 } } });
    try f.runtime.advanceAnimations(2000 * ms);
    try f.runtime.advanceAnimations(9000 * ms);
    try std.testing.expect((try f.runtime.tree.objectAt(render)).text_input.show_caret);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    _ = try session.apply(.{ .preedit = .{ .text = null, .cursor = null } });
    _ = session.model.selectAll();
    try f.runtime.advanceAnimations(9100 * ms);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    _ = try session.model.setSelection(.collapsed(1));
    try f.runtime.advanceAnimations(9200 * ms);
    try std.testing.expect((try f.runtime.animationDelay()) != null);
    try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 2 } });
    try f.runtime.dispatchInput(&unused);
    try f.runtime.advanceAnimations(9300 * ms);
    try std.testing.expect(!(try f.runtime.tree.objectAt(render)).text_input.show_caret);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    try f.runtime.routeKeyboard(.{ .enter = .{ .window = f.runtime.window, .serial = 3 } });
    try f.runtime.dispatchInput(&unused);
    try std.testing.expect((try f.runtime.tree.objectAt(render)).text_input.show_caret);
    try std.testing.expect((try f.runtime.animationDelay()) != null);
    try f.exec("read_only = true");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try f.runtime.advanceAnimations(9400 * ms);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    try f.exec("read_only = false; enabled = false");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try f.runtime.advanceAnimations(9500 * ms);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    try std.testing.expect(!(try f.runtime.tree.objectAt(render)).text_input.show_caret);
}

test "queued IME batches cannot follow focus to another field or back to the same field" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("function build() return ouro.column {key = 'root', ouro.text_input {key = 'a', width = 240, default_text = 'Alpha', autofocus = true}, ouro.text_input {key = 'b', width = 240, default_text = 'Bravo'}} end");
    try f.build();
    const a = try f.handle("root/a");
    const b = try f.handle("root/b");
    const old = (try f.runtime.textInputStatus()).?.generation;
    try f.queueIme(null, "é", null);
    try f.dispatch();
    try std.testing.expect((try f.runtime.text_inputs.session(a)).preedit() != null);
    // Both events are enqueued before the input safe point changes focus.
    try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .serial = 1, .time_ms = 1, .state = .pressed, .translated = .{ .keycode = 0, .logical = .tab } } });
    try f.queueIme("wrong", null, old);
    try f.dispatch();
    try std.testing.expectEqual(b, f.runtime.focus.current().?);
    try std.testing.expect((try f.runtime.text_inputs.session(a)).preedit() == null);
    try std.testing.expectEqualStrings("Alpha", (try f.runtime.text_inputs.session(a)).model.text());
    try std.testing.expectEqualStrings("Bravo", (try f.runtime.text_inputs.session(b)).model.text());
    try f.tab();
    const current = (try f.runtime.textInputStatus()).?.generation;
    try std.testing.expect(current != old);
    try f.queueIme("wrong", null, old);
    try f.queueIme("!", null, current);
    try f.dispatch();
    try std.testing.expectEqualStrings("Alpha!", (try f.runtime.text_inputs.session(a)).model.text());
    // Serial mismatch alone does not reject valid editor effects.
    try std.testing.expect(!f.runtime.text_input_commit_permitted);
}

test "composition is revoked by focus loss disabling replacement and removal" {
    for (0..6) |reason| {
        const f = try Fixture.create();
        defer f.destroy();
        try f.exec("enabled = true; read_only = false; show = true; value = 'Alpha'; function build() return ouro.column {key = 'root', show and ouro.text_input {key = 'input', text = value, enabled = enabled, read_only = read_only, autofocus = true} or ouro.text {key = 'empty', text = 'Removed'}} end");
        try f.build();
        const input = try f.handle("root/input");
        const old = (try f.runtime.textInputStatus()).?.generation;
        try f.queueIme(null, "é", old);
        try f.dispatch();
        switch (reason) {
            0 => try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 2 } }),
            1 => try f.runtime.routeTextInput(.{ .leave = f.runtime.window }),
            else => {
                try f.exec(switch (reason) {
                    2 => "enabled = false",
                    3 => "read_only = true",
                    4 => "value = 'Beta'",
                    else => "show = false",
                });
                _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
                try f.build();
            },
        }
        try f.dispatch();
        if (f.runtime.text_inputs.contains(input))
            try std.testing.expect((try f.runtime.text_inputs.session(input)).preedit() == null);
        switch (reason) {
            0 => try f.runtime.routeKeyboard(.{ .enter = .{ .window = f.runtime.window, .serial = 3 } }),
            1 => try f.runtime.routeTextInput(.{ .enter = f.runtime.window }),
            else => {
                try f.exec("enabled = true; read_only = false; show = true");
                _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
                try f.build();
                if (f.runtime.focus.current() == null) try f.tab();
            },
        }
        try f.dispatch();
        try f.queueIme("wrong", "stale", old);
        try f.dispatch();
        const current_input = try f.handle("root/input");
        const session = try f.runtime.text_inputs.session(current_input);
        try std.testing.expect(session.preedit() == null);
        try std.testing.expectEqualStrings(if (reason == 4) "Beta" else "Alpha", session.model.text());
        try std.testing.expect((try f.runtime.textInputStatus()).?.generation != old);
    }
}

test "text pointer follows hit testing read-only fields drag capture and stationary rebuilds" {
    const Cursor = @import("../platform/window.zig").PointerCursor;
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("enabled = true; show = true; function build() return ouro.column {key = 'root', show and ouro.text_input {key = 'input', width = 240, default_text = 'Select text', read_only = true, enabled = enabled} or ouro.text {key = 'empty', text = 'Removed'}, ouro.button {key = 'button', label = 'Button'}} end");
    try f.build();
    try std.testing.expectEqual(Cursor.default, try f.runtime.pointerCursor());
    const center = (try f.runtime.semanticTarget("root/input")).center;
    const button = (try f.runtime.semanticTarget("root/button")).center;
    try f.pointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = center } });
    try std.testing.expectEqual(Cursor.text, try f.runtime.pointerCursor());
    try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 2, .time_ms = 1, .button = 0x110, .state = .pressed } });
    try f.pointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = button } });
    try std.testing.expectEqual(Cursor.text, try f.runtime.pointerCursor());
    try f.pointer(.{ .button = .{ .window = f.runtime.window, .serial = 3, .time_ms = 3, .button = 0x110, .state = .released } });
    try std.testing.expectEqual(Cursor.default, try f.runtime.pointerCursor());
    try f.pointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 4, .position = center } });
    try std.testing.expectEqual(Cursor.text, try f.runtime.pointerCursor());
    try f.exec("enabled = false");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(Cursor.default, try f.runtime.pointerCursor());
    try f.exec("enabled = true");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(Cursor.text, try f.runtime.pointerCursor());
    try f.pointer(.{ .leave = .{ .window = f.runtime.window, .serial = 4 } });
    try std.testing.expectEqual(Cursor.default, try f.runtime.pointerCursor());
    try f.pointer(.{ .enter = .{ .window = f.runtime.window, .serial = 5, .position = center } });
    try f.exec("show = false");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(Cursor.default, try f.runtime.pointerCursor());
}

test "interaction observers retain descendant hover and keyboard focus and Escape restores the trigger" {
    const f = try Fixture.create();
    defer f.destroy();
    const Input = struct {
        fn flush(value: *Fixture) !void {
            try value.runtime.dispatchInput(&value.callbacks);
            while (value.scheduler.takeRunnable()) |handle| _ = try value.vm.resumeRunnable(handle);
            try value.build();
            try value.runtime.prepareFrame(1);
        }
        fn key(value: *Fixture, logical: @import("../platform/window.zig").LogicalKey) !void {
            try value.runtime.routeKeyboard(.{ .key = .{ .window = value.runtime.window, .serial = 1, .time_ms = 1, .state = .pressed, .translated = .{ .keycode = 0, .logical = logical } } });
            try flush(value);
        }
    };
    try f.exec(
        \\active, open = ouro.signal(false), ouro.signal(false)
        \\changes, invoked = '', ''
        \\function build()
        \\  return ouro.column { key = 'root', cross_alignment = 'stretch',
        \\    ouro.box { key = 'region', on_interaction_change = function(value)
        \\      changes = changes .. (value and 'T' or 'F'); active:set(value)
        \\    end, ouro.column { key = 'content',
        \\      ouro.button { key = 'dismiss', label = 'Dismiss' },
        \\      active() and ouro.button { key = 'options', label = 'Options', height = 'auto',
        \\        on_press = function() open:set(not open()) end,
        \\        on_cancel = open() and function() open:set(false) end or nil,
        \\        ouro.column { key = 'menu', ouro.text { key = 'label', text = 'Options' },
        \\          open() and ouro.button { key = 'reply', label = 'Reply', on_press = function() invoked = 'reply' end } or
        \\            ouro.box { key = 'empty' },
        \\        },
        \\      } or ouro.box { key = 'hidden', height = 32 },
        \\    } },
        \\    ouro.button { key = 'outside', label = 'Outside' },
        \\  }
        \\end
    );
    try f.build();
    try Input.flush(f);
    try f.exec("assert(changes == 'F' and not active()); changes = ''");
    const dismiss = (try f.runtime.semanticTarget("root/region/content/dismiss")).center;
    try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = dismiss } });
    try Input.flush(f);
    try f.exec("assert(changes == 'T' and active())");
    // Crossing into the revealed child and replacing callback references must
    // not send a false leave/enter pair or restart an open menu.
    const options = (try f.runtime.semanticTarget("root/region/content/options")).center;
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = options } });
    try Input.flush(f);
    try f.exec("assert(changes == 'T')");
    try f.runtime.routePointer(.{ .leave = .{ .window = f.runtime.window, .serial = 2 } });
    try Input.flush(f);
    try f.exec("assert(changes == 'TF' and not active())");
    try Input.key(f, .tab); // Dismiss reveals actions without a default action.
    try f.exec("assert(changes == 'TFT' and active())");
    try Input.key(f, .tab);
    const trigger = try f.handle("root/region/content/options");
    try std.testing.expectEqual(trigger, f.runtime.focus.current().?);
    try Input.key(f, .enter);
    try Input.key(f, .tab);
    try std.testing.expectEqual(try f.handle("root/region/content/options/menu/reply"), f.runtime.focus.current().?);
    try Input.key(f, .escape);
    try f.exec("assert(not open() and invoked == '' and changes == 'TFT')");
    try std.testing.expectEqual(trigger, f.runtime.focus.current().?);
    try Input.key(f, .enter);
    try Input.key(f, .tab);
    try Input.key(f, .enter);
    try f.exec("assert(open() and invoked == 'reply', 'nested activation also toggled the trigger')");
    try Input.key(f, .tab);
    try f.exec("assert(changes == 'TFTF' and not active())");
    // A pointer-only surface must not retain reveal from pointer-assigned focus.
    try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 3, .position = dismiss } });
    try Input.flush(f);
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 4, .time_ms = 2, .button = 0x110, .state = .pressed } });
    try Input.flush(f);
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 5, .time_ms = 3, .button = 0x110, .state = .released } });
    try f.runtime.routePointer(.{ .leave = .{ .window = f.runtime.window, .serial = 6 } });
    try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 7 } });
    try Input.flush(f);
    try f.exec("assert(changes == 'TFTFTF' and not active())");
    try f.exec("active:set(true); function build() return ouro.box {key = 'replacement', on_interaction_change = function(value) active:set(value) end} end");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try Input.flush(f);
    try f.exec("assert(not active(), 'replacement observer retained stale active state')");
}

test "popup anchors accumulate nested layout offsets without changing the parent" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\function build() return ouro.box {key='outer', padding=17,
        \\  ouro.row {key='row', gap=11,
        \\    ouro.box {key='spacer', width=43, height=31},
        \\    ouro.box {key='anchor', width=83, height=31},
        \\  }} end
    );
    try f.build();
    try f.runtime.prepareFrame(1);
    const anchor = try f.runtime.anchorRectangle(try f.handle("outer/row/anchor"));
    // Root padding 12, outer padding 17, preceding width 43 and gap 11.
    try std.testing.expectEqual(core.RectI{ .x = 83, .y = 29, .width = 83, .height = 31 }, anchor);
    try std.testing.expectEqual(core.SizeU{ .width = 600, .height = 500 }, f.runtime.frame_state.size.?);
}

test "popup focus is isolated and selected activation survives visual scope disposal" {
    const f = try Fixture.create();
    defer f.destroy();
    const owner = try f.scheduler.createScope(f.scheduler.application_scope);
    defer f.scheduler.destroyScope(owner) catch unreachable;
    f.runtime.callback_scope = owner;
    const Activation = @import("../platform/activation.zig");
    const Fake = struct {
        request: ?*Activation.Request = null,
        canceled: bool = false,
        fn start(context: *anyopaque, request: *Activation.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.request = request;
        }
        fn cancel(context: *anyopaque, _: *Activation.Request) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.canceled = true;
        }
    };
    var fake: Fake = .{};
    f.callbacks.activation_provider = .{ .context = &fake, .start = Fake.start, .cancel = Fake.cancel };
    try f.exec(
        \\function build() return ouro.column {key='menu',
        \\  ouro.button {key='disabled', label='Unavailable', enabled=false},
        \\  ouro.button {key='first', label='First', on_press=function() error('wrong item') end},
        \\  ouro.button {key='second', label='Second', on_press=function()
        \\    assert(ouro.activation_token() == 'selected-token'); selected=true
        \\  end},
        \\} end
    );
    try f.build();
    try f.runtime.prepareFrame(1);
    try std.testing.expectEqual(try f.handle("menu/first"), f.runtime.focus.current().?);
    try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .serial = 341, .time_ms = 1, .state = .pressed, .translated = .{ .keycode = 15, .logical = .tab } } });
    try f.runtime.dispatchInput(&f.callbacks);
    try std.testing.expectEqual(try f.handle("menu/second"), f.runtime.focus.current().?);
    const physical_parent: core.Handle = .{ .slot = 9, .generation = 4 };
    try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .source_window = physical_parent, .serial = 342, .time_ms = 2, .state = .pressed, .translated = .{ .keycode = 28, .logical = .enter } } });
    try f.runtime.dispatchInput(&f.callbacks);
    try std.testing.expectEqual(.waiting, try f.vm.resumeRunnable(f.scheduler.takeRunnable().?));
    try std.testing.expectEqual(@as(u32, 342), fake.request.?.input.serial);
    try std.testing.expectEqual(physical_parent, fake.request.?.input.window);
    try f.runtime.clear(&f.ui);
    try f.scheduler.queueScopeCancellation(f.scope);
    try f.scheduler.applyQueuedCancellations();
    try std.testing.expect(!fake.canceled);
    try std.testing.expect(f.scheduler.takeRunnable() == null);
    try fake.request.?.complete(fake.request.?.context, "selected-token");
    try std.testing.expectEqual(.completed, try f.vm.resumeRunnable(f.scheduler.takeRunnable().?));
    try f.exec("assert(selected)");
}
