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
        self.* = .{ .state = c.luaL_newstate() orelse return error.LuaStateCreationFailed };
        c.lua_createtable(self.state, 0, 4);
        c.lua_setglobal(self.state, "ouro");
        try self.scheduler.init(std.testing.allocator, 1024, 16, 0);
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
        self.ui.attachSignals(&self.signals);
        try self.ui.attachSemantics(&self.semantic_storage);
        try self.ui.attachLabelText(&self.sources, &self.font, 1);
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
        self.scheduler.deinit();
        c.lua_close(self.state);
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
