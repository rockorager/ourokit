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
