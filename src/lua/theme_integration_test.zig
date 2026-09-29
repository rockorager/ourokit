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

test "stock Lua controls preserve asymmetric root stack offsets" {
    const f = try Fixture.create();
    defer f.destroy();
    for ([_][]const u8{ "button", "checkbox", "switch", "separator" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return ouro.{s} {{key='control', label='Offset', checked=true, x=17, y=31}} end", .{name});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        try f.build();
        const render = try f.runtime.instances.renderObject(try f.handle("control"));
        try std.testing.expectEqual(core.PointF{ .x = 17, .y = 31 }, try f.runtime.tree.nodeOffset(render));
    }
}

test "Lua composition uses inherited themes and nested native activation paint without rebuilding" {
    const f = try Fixture.create();
    defer f.destroy();
    const Input = struct {
        fn flush(value: *Fixture) !void {
            try value.runtime.dispatchInput(&value.callbacks);
            while (value.scheduler.takeRunnable()) |handle|
                try std.testing.expectEqual(.completed, try value.vm.resumeRunnable(handle));
            try value.runtime.prepareFrame(1);
        }
        fn key(value: *Fixture, logical: @import("../platform/window.zig").LogicalKey, state: @import("../platform/window.zig").KeyState) !void {
            try value.runtime.routeKeyboard(.{ .key = .{ .window = value.runtime.window, .serial = 1, .time_ms = 1, .state = state, .translated = .{ .keycode = 0, .logical = logical } } });
            try flush(value);
        }
    };
    try f.exec(
        \\builds, renders, calls = 0, 0, 0
        \\enabled, failure, changed = ouro.signal(true), ouro.signal(false), ouro.signal(false)
        \\local Custom = ouro.stateless(function(p, children, theme)
        \\  renders = renders + 1
        \\  assert(theme.colors.background == ouro.tokens.dark.background)
        \\  assert(theme.controls.height == 47 and theme.widgets.button.padding_x == 13)
        \\  local idle = theme.colors.primary
        \\  theme.colors.primary = '#ffffff' -- The theme argument is an isolated value.
        \\  return ouro.box {key=p.key, activate=true, role='button', label='Custom',
        \\    enabled=p.enabled, width=140, height=60, alignment='center',
        \\    on_press=function() calls=calls+1 end,
        \\    ouro.row {key='content', cross_alignment='center',
        \\      ouro.box {key='chrome', width=31, height=23, border_width=1, border='#010305',
        \\        background=idle, states={hover='#234567', pressed='#456789', disabled='#6789ab', focus='#abcdef'},
        \\        children=children},
        \\      ouro.text {key='label', text='Nested content'},
        \\    },
        \\  }
        \\end)
        \\function build()
        \\  builds=builds+1
        \\  return ouro.column {key='root',
        \\    ouro.theme {key='scope', color_scheme='dark', controls={height=47},
        \\      widgets={button={padding_x=13}}, colors={primary=changed() and '#192837' or '#123456'},
        \\      Custom {key='control', enabled=enabled(), ouro.box {key='inside', width=7, height=9}},
        \\    },
        \\    ouro.box {key='tail', radius=failure() and -1 or 0},
        \\  }
        \\end
    );
    try f.build();
    try f.runtime.prepareFrame(1);
    const path = "root/scope/control";
    const chrome_path = "root/scope/control/content/chrome";
    const target = try f.handle(path);
    const scope = try f.runtime.instances.scope(target);
    const render_root = (try f.runtime.instances.rootRenderObject()).?;
    const layouts = try f.runtime.tree.layoutCount(render_root);
    try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0x56, 255), (try f.object(chrome_path)).box.background.?);
    const position = (try f.runtime.semanticTarget(chrome_path ++ "/inside")).center;
    try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = position } });
    try Input.flush(f);
    try std.testing.expectEqual(core.Color.rgba(0x23, 0x45, 0x67, 255), (try f.object(chrome_path)).box.background.?);
    try Input.key(f, .tab, .pressed);
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    try std.testing.expectEqual(core.Color.rgba(0xab, 0xcd, 0xef, 255), (try f.object(chrome_path)).box.border_color.?);
    try Input.key(f, .space, .pressed);
    try std.testing.expectEqual(core.Color.rgba(0x45, 0x67, 0x89, 255), (try f.object(chrome_path)).box.background.?);
    try Input.key(f, .space, .repeated);
    try Input.key(f, .space, .released);
    try Input.key(f, .enter, .pressed);
    try Input.key(f, .enter, .repeated);
    try f.exec("assert(builds==1 and renders==1 and calls==2)");
    try std.testing.expectEqual(layouts, try f.runtime.tree.layoutCount(render_root));
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 2, .time_ms = 2, .button = 0x110, .state = .pressed } });
    try Input.flush(f);
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 2, .time_ms = 2, .button = 0x110, .state = .released } });
    try Input.flush(f);
    try f.exec("assert(calls==3)");
    try f.runtime.routePointer(.{ .leave = .{ .window = f.runtime.window, .serial = 3 } });
    try Input.flush(f);
    try f.exec("failure:set(true); changed:set(true)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0x56, 255), (try f.object(chrome_path)).box.background.?);
    try std.testing.expectEqual(scope, try f.runtime.instances.scope(target));
    try Input.key(f, .enter, .pressed);
    try f.exec("assert(calls==4); failure:set(false); enabled:set(false)");
    try f.build();
    try std.testing.expectEqual(target, try f.handle(path));
    try std.testing.expect(f.runtime.focus.current() == null);
    try std.testing.expectEqual(core.Color.rgba(0x67, 0x89, 0xab, 255), (try f.object(chrome_path)).box.background.?);
    try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 4, .position = position } });
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 4, .time_ms = 4, .button = 0x110, .state = .pressed } });
    try Input.flush(f);
    try Input.key(f, .space, .pressed);
    try f.exec("assert(calls==4); enabled:set(true)");
    try f.build();
    try f.runtime.routePointer(.{ .leave = .{ .window = f.runtime.window, .serial = 5 } });
    try Input.flush(f);
    try std.testing.expectEqual(core.Color.rgba(0x19, 0x28, 0x37, 255), (try f.object(chrome_path)).box.background.?);
    try std.testing.expectEqual(target, try f.handle(path));
}

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
        "ouro.box {key='bad', states={hover='#123456'}}",
        "ouro.box {key='bad', activate=true, states=false}",
        "ouro.box {key='bad', activate=true, role='slider'}",
        "ouro.box {key='bad', activate=true, on_press=function() end, on_change=function() end}",
        "ouro.button {key='bad', label='Invalid variant', variant=false}",
        "ouro.button {key='bad', label='Invalid tone', tone=false}",
        "ouro.button {key='bad', label='Invalid off state', disabled_foreground=false}",
        "ouro.button {key='bad', label='Invalid inactive field', enabled=false, foreground='#xyzxyz'}",
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

test "Lua focus requests consume ineligible targets without delayed focus stealing" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\request=0; enabled=true; hidden=false; show=true
        \\function build() return ouro.column {key='root',
        \\ ouro.text_input {key='other', default_text='other', autofocus=true},
        \\ ouro.box {key='panel', hidden=hidden,
        \\   show and ouro.text_input {key='query', text='query', read_only=true,
        \\     enabled=enabled, focus_request=request} or nil},
        \\} end
    );
    try f.build();
    const other = try f.handle("root/other");
    const query = try f.handle("root/panel/query");
    try std.testing.expectEqual(other, f.runtime.focus.current().?);
    for ([_][]const u8{
        "enabled=false; request=1", "enabled=true",
        "hidden=true; request=2",   "hidden=false",
    }) |source| {
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try f.build();
        try std.testing.expectEqual(other, f.runtime.focus.current().?);
    }
    try f.exec("request=3");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(query, f.runtime.focus.current().?);
    try f.tab();
    try std.testing.expectEqual(other, f.runtime.focus.current().?);
    // Zero and nil do not clear focus; a later positive value is a new request.
    for ([_][]const u8{ "request=0", "request=nil" }) |source| {
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try f.build();
        try std.testing.expectEqual(other, f.runtime.focus.current().?);
    }
    try f.exec("request=3");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(query, f.runtime.focus.current().?);
    try f.exec("show=false");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expect(f.runtime.focus.current() == null);
    try f.exec("show=true");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    const remounted = try f.handle("root/panel/query");
    try std.testing.expect(!std.meta.eql(query, remounted));
    try std.testing.expectEqual(remounted, f.runtime.focus.current().?);
}

test "Lua focus requests respect newly mounted dialog boundaries" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\opened=false; request=0
        \\function build()
        \\ local children={}
        \\ if opened then children[1]=ouro.dialog {key='dialog', label='Dialog',
        \\   ouro.column {key='actions',
        \\     ouro.button {key='first', label='First'},
        \\     ouro.text_input {key='last', default_text='', focus_request=1}}} end
        \\ children[#children+1]=ouro.text_input {key='outside', default_text='', autofocus=true, focus_request=request}
        \\ return ouro.stack {key='root', children=children}
        \\end
    );
    try f.build();
    const outside = try f.handle("root/outside");
    try f.exec("opened=true; request=1");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    const last = try f.handle("root/dialog/actions/last");
    try std.testing.expectEqual(last, f.runtime.focus.current().?);
    try f.exec("request=2");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(last, f.runtime.focus.current().?);
    try f.exec("opened=false");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(outside, f.runtime.focus.current().?);
}

test "Lua focus requests validate transactionally and follow current declaration order" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\request=0; invalid=nil; reverse=false
        \\function build()
        \\ local a=ouro.button {key='a', label='A', focus_request=request}
        \\ local b=ouro.text_input {key='b', default_text='', focus_request=request}
        \\ return ouro.column {key='root',
        \\   children={reverse and b or a, reverse and a or b,
        \\     ouro.button {key='bad', label='Bad', focus_request=invalid}}}
        \\end
    );
    try f.build();
    try std.testing.expect(f.runtime.focus.current() == null);
    const a = try f.handle("root/a");
    const b = try f.handle("root/b");
    // Requests encountered before a later invalid declaration must not commit.
    for ([_][]const u8{ "true", "'2'", "-1", "1.5", "{}", "math.huge" }) |value| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "request=7; invalid={s}", .{value});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expect(f.runtime.focus.current() == null);
        try std.testing.expect(f.runtime.instances.takeFocusRequest() == null);
    }
    try f.exec("invalid=nil");
    try f.build();
    try std.testing.expectEqual(b, f.runtime.focus.current().?);
    try f.exec("reverse=true; request=4");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(a, f.runtime.focus.current().?);
    try std.testing.expectEqual(b, try f.handle("root/b"));
}

test "Lua focus requests reach native controls and standard compositions" {
    const cases = [_]struct { declaration: []const u8, path: []const u8 }{
        .{ .declaration = "ouro.switch {key='target', label='Switch', checked=false, focus_request=request()}", .path = "root/target" },
        .{ .declaration = "ouro.checkbox {key='target', label='Check', checked=false, focus_request=request()}", .path = "root/target" },
        .{ .declaration = "ouro.slider {key='target', label='Slider', value=3, min=0, max=10, step=1, focus_request=request()}", .path = "root/target" },
        .{ .declaration = "ouro.listbox {key='target', selected=1, on_select=function() end, focus_request=request(), ouro.option {key='one', value=1, label='One'}}", .path = "root/target" },
        .{ .declaration = "ouro.radio_group {key='target', selected=1, on_select=function() end, focus_request=request(), ouro.radio {key='one', value=1, label='One'}}", .path = "root/target" },
        .{ .declaration = "ouro.tab_bar {key='target', selected=1, on_select=function() end, focus_request=request(), ouro.tab {key='one', value=1, label='One'}}", .path = "root/target" },
        .{ .declaration = "ouro.split_view {key='target', flex=1, position=0.5, focus_request=request(), ouro.box {key='a'}, ouro.box {key='b'}}", .path = "root/target/divider" },
        .{ .declaration = "ouro.virtual_list {key='target', height=80, item_count=1, item_height=20, focus_request=request(), item_key=function(i) return tostring(i) end, render_item=function() return ouro.box {key='item'} end}", .path = "root/target" },
        .{ .declaration = "ouro.spinbox {key='target', label='Spin', value=3, min=0, max=10, step=1, focus_request=request()}", .path = "root/target/control/value" },
        .{ .declaration = "ouro.select {key='target', selected=1, options={{value=1, label='One'}}, focus_request=request()}", .path = "root/target/trigger" },
        .{ .declaration = "ouro.tabs {key='target', flex=1, label='Tabs', selected=1, on_select=function() end, tabs={{value=1, label='One', content=ouro.box {key='panel'}}}, focus_request=request()}", .path = "root/target/control/strip/bar" },
    };
    for (cases) |case| {
        const f = try Fixture.create();
        defer f.destroy();
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "request=ouro.signal(0); function build() return ouro.column {{key='root', {s}, ouro.text_input {{key='other', default_text='', autofocus=true}}}} end",
            .{case.declaration},
        );
        defer std.testing.allocator.free(source);
        try f.exec(source);
        f.build() catch |err| {
            std.debug.print("focus request declaration failed: {s}\n", .{case.declaration});
            return err;
        };
        const target = try f.handle(case.path);
        const other = try f.handle("root/other");
        try std.testing.expectEqual(other, f.runtime.focus.current().?);
        try f.exec("request:set(9)");
        try f.build();
        try std.testing.expectEqual(target, f.runtime.focus.current().?);
        _ = try f.runtime.focus.request(&f.runtime.instances, other);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try f.build();
        try std.testing.expectEqual(other, f.runtime.focus.current().?);
        try f.exec("request:set(10)");
        try f.build();
        try std.testing.expectEqual(target, f.runtime.focus.current().?);
    }
}

test "Lua focus requests apply only on prepared source commit" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\request=0
        \\function build() return ouro.column {key='root',
        \\ ouro.text_input {key='other', default_text='', autofocus=true},
        \\ ouro.text_input {key='query', default_text='retained', focus_request=request},
        \\} end
    );
    try f.build();
    const other = try f.handle("root/other");
    const query = try f.handle("root/query");
    var prepared: @import("prepared_build.zig").PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, f.state, &f.sources, 128, 1024);
    defer prepared.deinit();
    _ = c.lua_getglobal(f.state, "build");
    const reference = c.luaL_ref(f.state, c.registry_index);
    defer c.luaL_unref(f.state, c.registry_index, reference);
    for ([_][]const u8{ "request=1", "request=1", "request=2" }, 0..) |source, index| {
        _ = try f.runtime.focus.request(&f.runtime.instances, other);
        try f.exec(source);
        try f.runtime.prepareSourceBuild(.{ .width = 600, .height = 500 }, &f.ui, &prepared, reference, 2);
        try std.testing.expectEqual(other, f.runtime.focus.current().?);
        f.runtime.commitPreparedSource(&prepared, &f.callbacks, &f.vm, &f.signals);
        try std.testing.expectEqual(if (index == 1) other else query, f.runtime.focus.current().?);
        try std.testing.expectEqual(query, try f.handle("root/query"));
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

test "Lua color with_alpha derives token colors for theme and widget props" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\local ouro = require('ouro')
        \\local original = ouro.tokens.dark.background
        \\local tint = ouro.color.with_alpha(original, 0.3)
        \\assert(ouro.tokens.dark.background == original)
        \\function build()
        \\  return ouro.theme { key = 'scope', colors = { primary = tint },
        \\    ouro.column { key = 'root',
        \\      ouro.box { key = 'tint', background = tint, height = 20 },
        \\      ouro.button { key = 'button', label = 'Tint' },
        \\    },
        \\  }
        \\end
    );
    try f.build();
    const expected = core.Color.rgba(17, 17, 19, 77);
    try std.testing.expectEqual(expected, (try f.object("scope/root/tint")).box.background.?);
    try std.testing.expectEqual(expected, (try f.object("scope/root/button")).box.background.?);
    f.ui.widget_theme.?.colors = @import("../design/root.zig").tokens.dark;
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(expected, (try f.object("scope/root/tint")).box.background.?);
    try std.testing.expectEqual(expected, (try f.object("scope/root/button")).box.background.?);
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

test "button variants use semantic recipes and tint custom content" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\function build()
        \\  return ouro.theme { key = 'scope', widgets = { button = { background = '#010203ff', padding_x = 5 } },
        \\    ouro.column { key = 'root',
        \\      ouro.button { key = 'solid', label = 'Solid' },
        \\      ouro.button { key = 'soft', label = 'Soft', variant = 'soft', tone = 'neutral' },
        \\      ouro.button { key = 'surface', label = 'Surface', variant = 'surface' },
        \\      ouro.button { key = 'off', label = 'Off', variant = 'surface', enabled = false },
        \\      ouro.button { key = 'ghost', label = 'Ghost', variant = 'ghost', tone = 'destructive', background = '#040506ff' },
        \\      ouro.button { key = 'icon', label = 'Close', variant = 'ghost', tone = 'neutral',
        \\        ouro.text { key = 'glyph', text = 'x' } },
        \\      ouro.separator { key = 'rule' },
        \\    },
        \\  }
        \\end
    );
    try f.build();
    const light = @import("../design/root.zig").tokens.light;
    // Theme button colors style only the default solid accent button;
    // geometry applies to every variant and per-button colors still win.
    try std.testing.expectEqual(core.Color.rgba(1, 2, 3, 255), (try f.object("scope/root/solid")).box.background.?);
    const soft = (try f.object("scope/root/soft")).box;
    try std.testing.expectEqual(light.secondary, soft.background.?);
    try std.testing.expectEqual(@as(f32, 5), soft.padding.left);
    try std.testing.expectEqual(@as(f32, 0), soft.border_width);
    const surface = (try f.object("scope/root/surface")).box;
    try std.testing.expectEqual(light.surface, surface.background.?);
    try std.testing.expectEqual(@as(f32, 1), surface.border_width);
    try std.testing.expectEqual(light.accent_border, surface.border_color.?);
    const off = (try f.object("scope/root/off")).box;
    try std.testing.expectEqual(light.muted, off.background.?);
    try std.testing.expectEqual(light.border, off.border_color.?);
    try std.testing.expectEqual(core.Color.rgba(4, 5, 6, 255), (try f.object("scope/root/ghost")).box.background.?);
    const surface_id = (try f.runtime.semantics.findPath("scope/root/surface")).id;
    for (f.ui.storage[0..f.ui.count]) |descriptor| {
        if (descriptor.parent == surface_id and descriptor.object == .text)
            try std.testing.expectEqual(light.accent_text, descriptor.object.text.color);
    }
    // Custom content inherits the variant foreground and label size.
    const glyph = (try f.object("scope/root/icon/glyph")).text;
    try std.testing.expectEqual(light.muted_foreground, glyph.color);
    try std.testing.expectEqual(@as(f32, 14), (try f.sources.get(glyph.source)).logical_size);
    const rule = (try f.object("scope/root/rule")).box;
    try std.testing.expectEqual(light.border, rule.background.?);
    try std.testing.expectEqual(@as(f32, 1), rule.height.?);
    try std.testing.expectEqual(.separator, (try f.runtime.semantics.findPath("scope/root/rule")).role);

    for ([_][]const u8{
        "ouro.button {key='bad', label='Bad', variant='outline'}",
        "ouro.button {key='bad', label='Bad', tone='gray'}",
        "ouro.button {key='bad', label='Bad', variant=1}",
        "ouro.separator {key='bad', orientation='diagonal'}",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{declaration});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
    }
}

test "separators preserve axis geometry semantics and inherited themes through retained parents" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\changed = ouro.signal(false)
        \\local Rules = ouro.stateful(function()
        \\  return function()
        \\    return ouro.row {key='rules', gap=17,
        \\      ouro.box {key='horizontal', width=173, height=91, alignment='left',
        \\        ouro.separator {key='rule'}},
        \\      ouro.theme {key='nested', colors={border='#ab6543'},
        \\        ouro.box {key='vertical', width=211, height=67, alignment='left',
        \\          ouro.separator {key='rule', orientation='vertical'}}},
        \\      ouro.box {key='explicit', width=59, height=83, alignment='left',
        \\        ouro.separator {key='rule', orientation='horizontal'}},
        \\    }
        \\  end
        \\end)
        \\function build()
        \\  return ouro.theme {key='scope', colors={border=changed() and '#654321' or '#123456'},
        \\    Rules {key='retained'}}
        \\end
    );
    try f.build();
    const horizontal = try f.handle("scope/retained/rules/horizontal/rule");
    for ([_]struct { path: []const u8, size: core.SizeF, color: core.Color }{
        .{ .path = "scope/retained/rules/horizontal/rule", .size = .{ .width = 173, .height = 1 }, .color = .rgba(18, 52, 86, 255) },
        .{ .path = "scope/retained/rules/nested/vertical/rule", .size = .{ .width = 1, .height = 67 }, .color = .rgba(171, 101, 67, 255) },
        .{ .path = "scope/retained/rules/explicit/rule", .size = .{ .width = 59, .height = 1 }, .color = .rgba(18, 52, 86, 255) },
    }) |case| {
        const handle = try f.handle(case.path);
        try std.testing.expectEqual(case.size, try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(handle)));
        try std.testing.expectEqual(case.color, (try f.object(case.path)).box.background.?);
        try std.testing.expectEqual(.separator, (try f.runtime.semantics.findPath(case.path)).role);
        try std.testing.expect(!f.runtime.instances.isFocusable(handle));
    }
    try f.exec("changed:set(true)");
    try f.build();
    try std.testing.expectEqual(horizontal, try f.handle("scope/retained/rules/horizontal/rule"));
    try std.testing.expectEqual(core.Color.rgba(101, 67, 33, 255), (try f.object("scope/retained/rules/horizontal/rule")).box.background.?);
    try std.testing.expectEqual(core.Color.rgba(171, 101, 67, 255), (try f.object("scope/retained/rules/nested/vertical/rule")).box.background.?);

    for ([_][]const u8{
        "ouro.separator {key='bad', orientation=false}",
        "ouro.separator {key='bad', orientation=17}",
        "ouro.separator {key='bad', ouro.box {key='child'}}",
        "ouro.separator {key='bad', flex=0}",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{declaration});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expectEqual(horizontal, try f.handle("scope/retained/rules/horizontal/rule"));
    }
}

test "button content foreground permits nested theme and explicit text overrides" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\function build()
        \\  return ouro.theme { key='scope', widgets={text={foreground='#ab4567'}},
        \\    ouro.column { key='root',
        \\      ouro.button { key='button', label='Custom', foreground='#137ba9',
        \\        ouro.column { key='content',
        \\          ouro.text { key='plain', text='Button foreground' },
        \\          ouro.theme { key='nested', colors={foreground='#369c52'},
        \\            ouro.text { key='label', text='Nested foreground' } },
        \\          ouro.text { key='explicit', text='Explicit foreground', foreground='#e89224' },
        \\        } },
        \\      ouro.text { key='outside', text='Outer widget foreground' },
        \\    } }
        \\end
    );
    try f.build();
    try std.testing.expectEqual(core.Color.rgba(19, 123, 169, 255), (try f.object("scope/root/button/content/plain")).text.color);
    try std.testing.expectEqual(core.Color.rgba(54, 156, 82, 255), (try f.object("scope/root/button/content/nested/label")).text.color);
    try std.testing.expectEqual(core.Color.rgba(232, 146, 36, 255), (try f.object("scope/root/button/content/explicit")).text.color);
    try std.testing.expectEqual(core.Color.rgba(171, 69, 103, 255), (try f.object("scope/root/outside")).text.color);
}

test "theme inheritance and explicit precedence retheme clean components without remounting" {
    const f = try Fixture.create();
    defer f.destroy();
    f.ui.widget_theme.?.controls.height = 41;
    f.ui.widget_theme.?.controls.radius = 9;
    try f.exec(
        \\changed = ouro.signal(false)
        \\local Child = ouro.stateful(function()
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
        \\local Child = ouro.stateful(function()
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
        \\  run = function() return {windows = {ouro.window {id = 'main', title = 'Appearance', content = build}}} end,
        \\}
    );
    defer application.deinit();
    f.ui.widget_theme = application.resolvedTheme(tokens.light, false);
    try f.build();
    const child = try f.handle("root/child/button");
    f.ui.widget_theme = application.resolvedTheme(tokens.dark, true);
    try std.testing.expect(f.ui.widget_theme.?.reduced_motion);
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
        \\  id = 'dev.test.pinned', theme = {color_scheme = 'light', reduced_motion = false},
        \\  run = function() return {windows = {ouro.window {id = 'main', title = 'Pinned', content = build}}} end,
        \\}
    );
    defer pinned.deinit();
    try std.testing.expectEqualDeep(tokens.light, pinned.resolvedTheme(tokens.dark, true).colors);
    try std.testing.expect(!pinned.resolvedTheme(tokens.dark, true).reduced_motion);
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
        \\  run = function() return {windows = {ouro.window {id = 'main', title = 'Bindings', content = build}}} end,
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
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollDelta(render, .horizontal, 100));
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    try f.pointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 3, .position = .{ .x = -80, .y = 16 } } });
    for (100..200) |tick| {
        try f.runtime.advanceAnimations(tick * 16 * std.time.ns_per_ms);
        try f.runtime.prepareFrame(1);
    }
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollDelta(render, .horizontal, -100));
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

test "motion policy honors inherited themes explicit false and wrapper overrides" {
    const f = try Fixture.create();
    defer f.destroy();
    f.ui.widget_theme = .{ .colors = @import("../design/root.zig").tokens.light, .reduced_motion = true };
    try f.exec(
        \\local function sample(key, motion)
        \\  return ouro.animation {key=key,duration=500,motion=motion,render=function(v)
        \\    observed[key]=v
        \\    return ouro.box {key='box',width=10,height=10}
        \\  end}
        \\end
        \\function build()
        \\  observed={}
        \\  return ouro.column {key='root',
        \\    sample('auto'), sample('full','full'), sample('reduce','reduce'),
        \\    ouro.theme {key='child',reduced_motion=false,sample('child-auto')},
        \\    ouro.presence {key='exit',present=false,duration=500,render=function() error('hidden') end},
        \\  }
        \\end
    );
    try f.build();
    try f.exec("assert(observed.auto==1 and observed.full==0 and observed.reduce==1 and observed['child-auto']==0)");
    const original = try f.handle("root/auto/box");
    f.ui.widget_theme.?.reduced_motion = false;
    try f.runtime.setTheme(f.ui.widget_theme.?.colors);
    try f.build();
    try f.exec("assert(observed.auto==0 and observed.full==0 and observed.reduce==1 and observed['child-auto']==0)");
    try std.testing.expectEqual(original, try f.handle("root/auto/box"));
}

test "constraint layout Lua loose flex and caps update retained geometry and reject invalid declarations" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\cap=ouro.signal(45); fit=ouro.signal('loose')
        \\function build()
        \\  return ouro.column {key='root',ouro.box {key='frame',width=230,height=60,
        \\    ouro.row {key='row',gap=5,main_alignment='end',
        \\      ouro.box {key='fixed',width=20,height=10},
        \\      ouro.box {key='loose',width='fill',max_width=cap(),height=10,flex={factor=1,fit=fit()}},
        \\      ouro.box {key='tight',height=10,max_width=1,flex=3},
        \\    }}}
        \\end
    );
    try f.build();
    const handle = try f.handle("root/frame/row/loose");
    const loose = try f.runtime.instances.renderObject(handle);
    const tight = try f.runtime.instances.renderObject(try f.handle("root/frame/row/tight"));
    try std.testing.expectEqual(@as(f32, 45), (try f.runtime.tree.nodeSize(loose)).width);
    try std.testing.expectEqual(@as(f32, 150), (try f.runtime.tree.nodeSize(tight)).width);
    try std.testing.expectEqual(@as(f32, 30), (try f.runtime.tree.nodeOffset(loose)).x);
    try f.exec("cap:set(20)");
    try f.build();
    try std.testing.expectEqual(handle, try f.handle("root/frame/row/loose"));
    try std.testing.expectEqual(@as(f32, 20), (try f.runtime.tree.nodeSize(loose)).width);
    try std.testing.expectEqual(@as(f32, 55), (try f.runtime.tree.nodeOffset(loose)).x);
    try f.exec("fit:set('tight')");
    try f.build();
    try std.testing.expectEqual(@as(f32, 50), (try f.runtime.tree.nodeSize(loose)).width);
    try std.testing.expectEqual(@as(f32, 25), (try f.runtime.tree.nodeOffset(loose)).x);

    const invalid = [_][]const u8{
        "ouro.box{key='box',max_width=-1}",
        "ouro.box{key='box',max_height=1/0}",
        "ouro.box{key='box',min_width=10,max_width=9}",
        "ouro.box{key='box',width=11,max_width=10}",
        "ouro.box{key='box',max_width='40'}",
        "ouro.box{key='box',max_height=false}",
        "ouro.row{key='row',main_alignment='sideways'}",
        "ouro.row{key='row',main_alignment=1}",
        "ouro.row{key='row',ouro.box{key='box',flex={factor=1,fit='wide'}}}",
        "ouro.row{key='row',ouro.box{key='box',flex={factor=0}}}",
        "ouro.row{key='row',ouro.box{key='box',flex={factor=1,typo=2}}}",
        "ouro.row{key='row',ouro.box{key='box',flex={fit='loose'}}}",
        "ouro.row{key='row',wrap=true,ouro.box{key='box',flex={factor=1,fit='loose'}}}",
        "ouro.box{key='outer',ouro.box{key='box',flex={factor=1,fit='loose'}}}",
    };
    for (invalid) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{declaration});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expectEqual(handle, try f.handle("root/frame/row/loose"));
        try std.testing.expectEqual(@as(f32, 50), (try f.runtime.tree.nodeSize(loose)).width);
    }
}

test "layout builder measures local constraints in native order and initializes nested components once" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\calls={root=0,init=0,producer=0,consumer=0,scroll=0}
        \\local Panel=ouro.stateful(function(p)
        \\  calls.init=calls.init+1
        \\  return function()
        \\    return ouro.box {key='frame',width=300,height=120,padding=10,
        \\      ouro.row {key='row',gap=7,
        \\        -- Lowered first, but measured after the non-flex producer.
        \\        ouro.layout_builder {key='consumer',flex=1,render=function(c)
        \\          calls.consumer=calls.consumer+1
        \\          assert(c.min_width==200 and c.max_width==200)
        \\          assert(c.min_height==0 and c.max_height==100)
        \\          c.max_width=1 -- Must not alter the retained cache or native input.
        \\          return ouro.box {key='result',width='fill',height=19}
        \\        end},
        \\        ouro.layout_builder {key='producer',render=function(c)
        \\          calls.producer=calls.producer+1
        \\          assert(c.min_width==0 and c.max_width==1/0 and c.max_height==100)
        \\          return ouro.box {key='result',width=73,height=31}
        \\        end},
        \\      }}
        \\  end
        \\end)
        \\function build()
        \\  calls.root=calls.root+1
        \\  return ouro.column {key='root',gap=9,Panel {key='panel'},
        \\    ouro.box {key='viewport',width=151,height=61,
        \\      ouro.scroll {key='scroll',ouro.layout_builder {key='builder',render=function(c)
        \\        calls.scroll=calls.scroll+1
        \\        assert(c.min_width==0 and c.max_width==151)
        \\        assert(c.min_height==0 and c.max_height==1/0)
        \\        return ouro.box {key='content',height=99}
        \\      end}}}}
        \\end
    );
    try f.build();
    try f.exec("assert(calls.root==1 and calls.init==1 and calls.consumer==1 and calls.producer==1 and calls.scroll==1)");
    const consumer = try f.handle("root/panel/frame/row/consumer/result");
    const render = try f.runtime.instances.renderObject(consumer);
    try std.testing.expectEqual(core.SizeF{ .width = 200, .height = 19 }, try f.runtime.tree.nodeSize(render));
    try std.testing.expectEqual(@as(usize, 3), f.runtime.layout_builders.count);
    // A native-only rebuild retains callbacks and dependencies, despite the probe passes.
    _ = try f.runtime.build_owners.markReaderDirty(f.runtime.root_owner);
    f.runtime.native_work = true;
    try f.build();
    try f.exec("assert(calls.root==1 and calls.init==1 and calls.consumer==1 and calls.producer==1 and calls.scroll==1)");
    try std.testing.expectEqual(consumer, try f.handle("root/panel/frame/row/consumer/result"));
}

test "layout builder reacts to local sizing and signals without remounting and rolls back failed branches" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\width=ouro.signal(241); color=ouro.signal('#224466'); fail=ouro.signal(false)
        \\roots=0; renders=0; inits=0
        \\local Child=ouro.stateful(function(p)
        \\  inits=inits+1
        \\  return function() return ouro.box {key='paint',width=p.width,height=17,background=color()} end
        \\end)
        \\local responsive=ouro.layout_builder {key='responsive',render=function(c)
        \\  renders=renders+1
        \\  if fail() and c.max_width<200 then error('narrow failure') end
        \\  return ouro.box {key='inset',padding=3,
        \\    ouro.layout_builder {key='nested',render=function(inner)
        \\      assert(inner.max_width==c.max_width-6)
        \\      return Child {key='child',width=inner.max_width>=200 and 97 or 43}
        \\    end}}
        \\end}
        \\local Host=ouro.stateful(function(p)
        \\  return function() return ouro.box {key='host',width=width(),height=53,alignment='center',responsive} end
        \\end)
        \\function build() roots=roots+1; return Host {key='app'} end
    );
    try f.build();
    const path = "app/host/responsive/inset/nested/child/paint";
    const handle = try f.handle(path);
    const render = try f.runtime.instances.renderObject(handle);
    try std.testing.expectEqual(@as(f32, 97), (try f.runtime.tree.nodeSize(render)).width);
    try f.exec("assert(roots==1 and renders==1 and inits==1); width:set(199)");
    try f.build();
    try std.testing.expectEqual(handle, try f.handle(path));
    try std.testing.expectEqual(@as(f32, 43), (try f.runtime.tree.nodeSize(render)).width);
    try f.exec("assert(roots==1 and renders==2 and inits==1); color:set('#aabbcc')");
    try f.build();
    try f.exec("assert(roots==1 and renders==2 and inits==1)");
    try std.testing.expectEqual(core.Color.rgba(0xaa, 0xbb, 0xcc, 255), (try f.object(path)).box.background.?);
    try f.exec("fail:set(true)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(handle, try f.handle(path));
    try std.testing.expectEqual(@as(f32, 43), (try f.runtime.tree.nodeSize(render)).width);
    // Don't call the rejected narrow branch with stale bounds during recovery.
    try f.exec("width:set(241)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 97), (try f.runtime.tree.nodeSize(render)).width);
    try std.testing.expectEqual(handle, try f.handle(path));
}

test "layout builder rejects intrinsic feedback and invalid declarations before committing" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec("function build() return ouro.box {key='old',width=71,height=29} end");
    try f.build();
    const old = try f.handle("old");
    const cases = [_]struct { expression: []const u8, err: anyerror }{
        .{ .expression = "ouro.layout_builder{key='bad',render=false}", .err = error.LuaBuildFailed },
        .{ .expression = "ouro.layout_builder{key='bad',render=function() return {} end}", .err = error.LuaBuildFailed },
        .{ .expression = "ouro.layout_builder{key='bad',render=function() end,ouro.box{}}", .err = error.LuaBuildFailed },
        .{ .expression = "ouro.column{key='column',ouro.layout_builder{key='dup',render=function() end},ouro.layout_builder{key='dup',render=function() end}}", .err = error.LuaBuildFailed },
        .{ .expression = "ouro.grid{key='grid',columns={'auto'},rows={40},ouro.layout_builder{key='auto',column=1,row=1,render=function() return ouro.box{key='box',width=30,height=20} end}}", .err = error.LayoutBuilderIntrinsicMeasurement },
        .{ .expression = "ouro.row{key='row',cross_alignment='stretch',ouro.layout_builder{key='stretch',render=function() return ouro.box{key='box',width=30,height=20} end}}", .err = error.LayoutBuilderIntrinsicMeasurement },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return ouro.column{{key='root',{s}}} end", .{case.expression});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(case.err, f.build());
        try std.testing.expectEqual(old, try f.handle("old"));
    }
    // Fixed sizing shields the builder from the auto track's speculative pass.
    try f.exec(
        \\function build() return ouro.grid {key='grid',columns={'auto'},rows={40},
        \\  ouro.box {key='fixed',column=1,row=1,width=100,height=40,
        \\    ouro.layout_builder {key='bounded',render=function(c)
        \\      assert(c.min_width==100 and c.max_width==100 and c.min_height==40 and c.max_height==40)
        \\      return ouro.box {key='result',width='fill',height='fill'}
        \\    end}}} end
    );
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    const result = try f.handle("grid/fixed/bounded/result");
    try std.testing.expectEqual(core.SizeF{ .width = 100, .height = 40 }, try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(result)));
}

test "layout builder preparation validates newly selected branches and preserves old handlers on rejection" {
    const click = struct {
        fn run(f: *Fixture) !void {
            const target = try f.runtime.semanticTarget("frame/builder/button");
            try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 0, .position = target.center } });
            for ([_]@import("../platform/window.zig").PointerButtonState{ .pressed, .released }) |state| {
                try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 0, .button = 0x110, .state = state } });
                try f.runtime.dispatchInput(&f.callbacks);
                while (f.scheduler.takeRunnable()) |handle|
                    try std.testing.expectEqual(.completed, try f.vm.resumeRunnable(handle));
            }
        }
    }.run;
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\hits=0
        \\function build() return ouro.box {key='frame',width=240,height=60,
        \\  ouro.layout_builder {key='builder',render=function(c)
        \\    assert(c.max_width==240)
        \\    return ouro.button {key='button',label='Original',on_press=function() hits=hits+3 end}
        \\  end}} end
    );
    try f.build();
    const handle = try f.handle("frame/builder/button");
    var prepared: @import("prepared_build.zig").PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, f.state, &f.sources, 128, 4096);
    defer prepared.deinit();
    try f.exec(
        \\function candidate() return ouro.box {key='frame',width=199,height=60,
        \\  ouro.layout_builder {key='builder',render=function(c)
        \\    -- The old 240px branch is valid; the new local bounds must be checked.
        \\    if c.max_width<200 then error('candidate narrow failure') end
        \\    return ouro.button {key='button',label='Invalid candidate'}
        \\  end}} end
    );
    _ = c.lua_getglobal(f.state, "candidate");
    const rejected = c.luaL_ref(f.state, c.registry_index);
    defer c.luaL_unref(f.state, c.registry_index, rejected);
    try std.testing.expectError(error.LuaBuildFailed, f.runtime.prepareSourceBuild(.{ .width = 600, .height = 500 }, &f.ui, &prepared, rejected, 2));
    try std.testing.expectEqual(handle, try f.handle("frame/builder/button"));
    try std.testing.expectEqual(@as(usize, 0), prepared.descriptor_count);
    try click(f);
    try f.exec("assert(hits==3)");
    try f.exec(
        \\function candidate() return ouro.box {key='frame',width=199,height=60,
        \\  ouro.layout_builder {key='builder',render=function(c)
        \\    assert(c.max_width==199)
        \\    return ouro.button {key='button',label='Accepted',on_press=function() hits=hits+7 end}
        \\  end}} end
    );
    _ = c.lua_getglobal(f.state, "candidate");
    const accepted = c.luaL_ref(f.state, c.registry_index);
    defer c.luaL_unref(f.state, c.registry_index, accepted);
    try f.runtime.prepareSourceBuild(.{ .width = 600, .height = 500 }, &f.ui, &prepared, accepted, 2);
    try f.callbacks.ensureAvailable(prepared.handler_count);
    f.runtime.commitPreparedSource(&prepared, &f.callbacks, &f.vm, &f.signals);
    try f.runtime.prepareFrame(1);
    try std.testing.expectEqual(handle, try f.handle("frame/builder/button"));
    try click(f);
    try f.exec("assert(hits==10)");
}

test "layout builder uses retained editor geometry and removes subscriptions with its branch" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\show=ouro.signal(true); color=ouro.signal('#abcdef'); seen=0
        \\local Child=ouro.stateful(function()
        \\  return function() return ouro.box {key='paint',background=color()} end
        \\end)
        \\function build() return ouro.box {key='frame',width=220,height=240,
        \\  ouro.column {key='column',gap=11,
        \\    ouro.text_editor {key='editor',default_text='one',multiline=true,autofocus=true},
        \\    ouro.layout_builder {key='remaining',flex=1,render=function(c)
        \\      seen=c.max_height
        \\      return show() and Child {key='child'} or nil
        \\    end}}} end
    );
    try f.build();
    const editor = try f.handle("frame/column/editor");
    const session = try f.runtime.text_inputs.session(editor);
    _ = try session.apply(.{ .commit = .{ .text = "\ntwo\nthree\nfour" } });
    // A real input safe point updates the retained paragraph and its height.
    try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .serial = 1, .time_ms = 0, .state = .pressed, .translated = .{ .keycode = 0, .logical = .end } } });
    try f.runtime.dispatchInput(&f.callbacks);
    try f.runtime.prepareFrame(1);
    const editor_height = (try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(editor))).height;
    try std.testing.expect(editor_height > 60);
    // This feedback build must not measure default_text='one' and loop forever.
    try f.build();
    _ = c.lua_getglobal(f.state, "seen");
    var valid: c_int = 0;
    const seen = c.lua_tonumberx(f.state, -1, &valid);
    c.lua_settop(f.state, -2);
    try std.testing.expectApproxEqAbs(@as(f64, 240 - 11 - editor_height), seen, 0.001);
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", (try f.runtime.text_inputs.session(editor)).model.text());
    try f.exec("show:set(false)");
    try f.build();
    try std.testing.expectEqual(@as(usize, 0), f.runtime.build_owners.dirty.pendingCount());
    try f.exec("color:set('#123456')");
    try std.testing.expectEqual(@as(usize, 0), f.runtime.build_owners.dirty.pendingCount());
    try f.exec("show:set(true)");
    try f.build();
    try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0x56, 255), (try f.object("frame/column/remaining/child/paint")).box.background.?);
}
