const std = @import("std");
const c = @import("c.zig");
const UiBuild = @import("ui_build.zig").UiBuild;
const Signals = @import("signals.zig").Signals;
const Vm = @import("vm.zig").Vm;
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const core = @import("../core/root.zig");
const platform = @import("../platform/window.zig");
const instance = @import("../ui/instance/tree.zig");
const semantics = @import("../ui/semantics/snapshot.zig");
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
    descriptors: [256]instance.Descriptor = undefined,
    semantic_storage: [256]semantics.Descriptor = undefined,
    size: core.SizeU = .{ .width = 324, .height = 224 },

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
        if (c.luaL_loadbufferx(self.state, source.ptr, source.len, "@virtual-test", "t") != c.ok or
            c.lua_pcallk(self.state, 0, 0, 0, 0, null) != c.ok) return error.LuaTestFailed;
    }

    fn number(self: *Fixture, name: [*:0]const u8) f64 {
        _ = c.lua_getglobal(self.state, name);
        defer c.lua_settop(self.state, -2);
        var valid: c_int = 0;
        return c.lua_tonumberx(self.state, -1, &valid);
    }

    fn build(self: *Fixture) !void {
        _ = c.lua_getglobal(self.state, "build");
        const reference = c.luaL_ref(self.state, c.registry_index);
        defer c.luaL_unref(self.state, c.registry_index, reference);
        try self.runtime.reconcile(self.size, &self.ui, reference);
        try self.scheduler.applyQueuedCancellations();
        try self.runtime.collectRetired();
    }

    fn handle(self: *Fixture, path: []const u8) !instance.InstanceHandle {
        return self.runtime.instances.handleForId((try self.runtime.semantics.findPath(path)).id).?;
    }

    fn offset(self: *Fixture) !f32 {
        return self.runtime.instances.scrollOffset(try self.handle("people"));
    }

    fn wheel(self: *Fixture, delta: f32) !void {
        const target = try self.runtime.semanticTarget("people");
        try self.runtime.routePointer(.{ .enter = .{ .window = self.runtime.window, .serial = 1, .position = target.center } });
        try self.runtime.routePointer(.{ .axis = .{ .window = self.runtime.window, .time_ms = 1, .axis = .vertical, .delta = delta } });
        var unused: Vm = undefined;
        try self.runtime.dispatchInput(&unused);
    }

    fn key(self: *Fixture, logical: platform.LogicalKey) !void {
        try self.runtime.routeKeyboard(.{ .key = .{ .window = self.runtime.window, .serial = 1, .time_ms = 1, .state = .pressed, .translated = .{ .keycode = 0, .logical = logical } } });
        var unused: Vm = undefined;
        try self.runtime.dispatchInput(&unused);
    }
};

const fixed_source =
    \\renders, roots = 0, 0
    \\prepend, count, broken = ouro.signal(false), ouro.signal(10000), ouro.signal(false)
    \\function build()
    \\  roots = roots + 1
    \\  local shift = prepend() and 1 or 0
    \\  local invalid = broken()
    \\  return ouro.virtual_list {
    \\    key = 'people', item_count = count(), item_height = 40,
    \\    item_key = function(i) return 'person-' .. (i - shift) end,
    \\    render_item = function(i)
    \\      renders = renders + 1
    \\      if invalid then return false end
    \\      return ouro.box { key = 'row', height = 12 }
    \\    end,
    \\  }
    \\end
;

test "virtual fixed rows bound construction, scroll through input, anchor keys and recover failed builds" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(fixed_source);
    try f.build();
    try std.testing.expect(f.number("renders") < 32);
    try std.testing.expectEqual(@as(f64, 1), f.number("roots"));
    try std.testing.expect(f.runtime.instances.activeCount() < 32);
    try std.testing.expectEqual(@as(f32, 400000), f.runtime.virtual_lists.lists[0].total);
    try std.testing.expectEqual(@as(f32, 200), f.runtime.virtual_lists.lists[0].viewport);
    try f.exec("renders = 0");
    try f.wheel(200013);
    try f.build();
    try std.testing.expectEqual(@as(f32, 200013), try f.offset());
    _ = try f.handle("people/person-5001/row");
    try std.testing.expect(f.number("renders") < 24);
    try std.testing.expectEqual(@as(f64, 1), f.number("roots"));
    const retained = try f.handle("people/person-5001/row");
    try f.exec("prepend:set(true)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 200053), try f.offset());
    try std.testing.expectEqual(retained, try f.handle("people/person-5001/row"));
    try f.exec("broken:set(true)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(retained, try f.handle("people/person-5001/row"));
    try std.testing.expectEqual(@as(f32, 200053), try f.offset());
    try f.exec("broken:set(false); count:set(2)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 0), try f.offset());
    try f.exec("count:set(0)");
    try f.build();
    try std.testing.expectEqual(@as(usize, 0), f.runtime.virtual_lists.row_count);
}

test "virtual list scroll momentum survives recycled rows and cancels on input bounds and removal" {
    const Sink = struct {
        runtime: *WindowRuntime,
        pub fn pointer(self: @This(), event: platform.PointerEvent) !void {
            try self.runtime.routePointer(event);
        }
    };
    for (0..4) |ending| {
        const f = try Fixture.create();
        defer f.destroy();
        try f.exec(fixed_source);
        try f.build();
        const window = f.runtime.window;
        const sink: Sink = .{ .runtime = &f.runtime };
        var unused: Vm = undefined;
        const target = try f.runtime.semanticTarget("people");
        try f.runtime.routePointer(.{ .enter = .{ .window = window, .serial = 1, .position = target.center } });
        try f.runtime.dispatchInput(&unused);
        const hovered = f.runtime.router.hovered.?;
        var pending: @import("../platform/wayland/scroll.zig").Pending = .{};
        for (0..2) |sample| {
            pending.push(.{ .axis = .{ .window = window, .axis = .vertical, .time_ms = @intCast(sample * 8), .delta = 80 } });
            // Source arrives after delta, as permitted by Wayland.
            pending.push(.{ .axis_source = .{ .window = window, .source = .finger } });
            try pending.flush(window, sink);
            try f.runtime.dispatchInput(&unused);
            try f.build();
        }
        try std.testing.expectEqual(@as(f32, 480), try f.offset());
        try std.testing.expect(!f.runtime.instances.isActive(hovered));
        pending.push(.{ .axis_stop = .{ .window = window, .axis = .vertical, .time_ms = 9 } });
        try pending.flush(window, sink);
        try f.runtime.dispatchInput(&unused);
        try std.testing.expectEqual(@as(?u64, 8 * std.time.ns_per_ms), try f.runtime.animationDelay());
        try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
        // Moving off the list must not retarget the in-flight gesture.
        try f.runtime.routePointer(.{ .motion = .{ .window = window, .time_ms = 10, .position = .{ .x = 1, .y = 1 } } });
        try f.runtime.dispatchInput(&unused);
        try f.runtime.advanceAnimations(108 * std.time.ns_per_ms);
        try f.build();
        try std.testing.expectEqual(@as(f32, 544), try f.offset());
        _ = try f.handle("people/person-14/row");
        try std.testing.expect(f.runtime.instances.activeCount() < 32);

        switch (ending) {
            0 => { // A press on the surrounding padding cancels immediately.
                try f.runtime.routePointer(.{ .button = .{ .window = window, .serial = 2, .time_ms = 11, .button = 0x110, .state = .pressed } });
                try f.runtime.dispatchInput(&unused);
                try f.runtime.advanceAnimations(116 * std.time.ns_per_ms);
                try std.testing.expectEqual(@as(f32, 544), try f.offset());
            },
            1 => { // A new wheel gesture cancels, with no synthetic wheel fling.
                try f.runtime.routePointer(.{ .enter = .{ .window = window, .serial = 2, .position = target.center } });
                pending.push(.{ .axis = .{ .window = window, .axis = .vertical, .time_ms = 11, .delta = -3.75 } });
                pending.push(.{ .axis_steps120 = .{ .window = window, .axis = .vertical, .steps120 = -30 } });
                pending.push(.{ .axis_source = .{ .window = window, .source = .wheel } });
                try pending.flush(window, sink);
                try f.runtime.dispatchInput(&unused);
                try f.runtime.advanceAnimations(116 * std.time.ns_per_ms);
                try std.testing.expectEqual(@as(f32, 519), try f.offset());
            },
            2 => { // Shrinking the content clamps and disarms momentum at the edge.
                try f.exec("count:set(2)");
                try f.build();
                try f.runtime.advanceAnimations(116 * std.time.ns_per_ms);
                try std.testing.expectEqual(@as(f32, 0), try f.offset());
            },
            3 => {
                try f.exec("function build() return ouro.box {key = 'replacement'} end");
                _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
                try f.build();
                try f.runtime.advanceAnimations(116 * std.time.ns_per_ms);
            },
            else => unreachable,
        }
        try std.testing.expectEqual(null, try f.runtime.animationDelay());
    }
}

test "virtual variable rows measure beyond estimates and preserve anchors through height and width changes" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\expanded = ouro.signal(false)
        \\function build()
        \\  return ouro.virtual_list {
        \\    key = 'people', item_count = 10000, estimated_item_height = 47,
        \\    item_key = function(i) return 'person-' .. i end,
        \\    render_item = function(i)
        \\      local height = i % 2 == 0 and 61 or 29
        \\      if i == 1 and expanded() then height = 129 end
        \\      return ouro.box { key = 'row', height = height }
        \\    end,
        \\  }
        \\end
    );
    try f.build();
    const first = try f.handle("people/person-1");
    try std.testing.expectEqual(@as(f32, 29), (try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(first))).height);
    try f.wheel(35);
    try f.build();
    try std.testing.expectEqual(@as(f32, 35), try f.offset());
    // Row two stays six pixels above the viewport when row one grows by 100.
    try f.exec("expanded:set(true)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 135), try f.offset());
    f.size.width = 224;
    try f.build();
    try std.testing.expectEqual(@as(f32, 135), try f.offset());
    try std.testing.expect(f.runtime.instances.activeCount() < 40);
    try f.exec(
        \\function build() return ouro.virtual_list {
        \\  key = 'people', item_count = 1, estimated_item_height = 10,
        \\  item_key = function() return 'tall' end,
        \\  render_item = function() return ouro.box { key = 'row', height = 700 } end,
        \\} end
    );
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expectEqual(@as(f32, 700), f.runtime.virtual_lists.lists[0].total);
}

test "virtual viewport keyboard reaches distant rows without losing focused row instances" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\function build() return ouro.virtual_list {
        \\  key = 'people', item_count = 10000, item_height = 40,
        \\  item_key = function(i) return 'person-' .. i end,
        \\  render_item = function(i) return ouro.button { key = 'button', label = 'Person ' .. i } end,
        \\} end
    );
    try f.build();
    try f.key(.tab);
    try std.testing.expectEqual(try f.handle("people"), f.runtime.focus.current().?);
    try f.key(.end);
    try f.build();
    _ = try f.handle("people/person-10000/button");
    try std.testing.expectEqual(@as(f32, 399800), try f.offset());
    try f.key(.page_up);
    try f.build();
    try std.testing.expectEqual(@as(f32, 399600), try f.offset());
    try f.key(.home);
    try f.build();
    try f.key(.tab);
    const first = try f.handle("people/person-1/button");
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try f.wheel(200000);
    try f.build();
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try std.testing.expect(f.runtime.instances.isActive(first));
    try std.testing.expect(f.runtime.instances.activeCount() < 48);
}

test "virtual wrapped rows retain deep within-row offset across width changes" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\function build() return ouro.virtual_list {
        \\  key = 'people', item_count = 10000, estimated_item_height = 20,
        \\  item_key = function(i) return 'person-' .. i end,
        \\  render_item = function() return ouro.text { key = 'text', size = 24,
        \\    text = 'A long profile with several lines of text. A long profile with several lines of text. A long profile with several lines of text. A long profile with several lines of text.' } end,
        \\} end
    );
    try f.build();
    const row = try f.handle("people/person-1");
    const wide_height = (try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(row))).height;
    try std.testing.expect(wide_height > 100);
    try f.wheel(85);
    try f.build();
    try std.testing.expectEqual(@as(f32, 85), try f.offset());
    f.size.width = 224;
    try f.build();
    try std.testing.expectEqual(@as(f32, 85), try f.offset());
    const narrow_height = (try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(row))).height;
    try std.testing.expect(narrow_height > wide_height);
    f.size.width = 324;
    try f.build();
    try std.testing.expectEqual(@as(f32, 85), try f.offset());
    try std.testing.expectEqual(wide_height, (try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(row))).height);
}

test "virtual lists reject invalid providers and sizing without replacing committed rows" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(fixed_source);
    try f.build();
    const row = try f.handle("people/person-1/row");
    for ([_][]const u8{
        "props.item_key = function() return 'duplicate' end",
        "props.item_key = function() return 1 end",
        "props.item_key = function() return '' end",
        "props.render_item = false",
        "props.item_count = -1",
        "props.item_count = 1.5",
        "props.item_height = 0",
        "props.estimated_item_height = 30",
        "props.item_height = nil",
    }) |invalid| {
        try f.exec("props = { key='people', item_count=10, item_height=40, item_key=function(i) return 'person-'..i end, render_item=function() return ouro.box{key='row'} end }");
        try f.exec(invalid);
        try f.exec("function build() return ouro.virtual_list(props) end");
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expectEqual(row, try f.handle("people/person-1/row"));
    }
    try f.exec(fixed_source);
    try f.build();
    for (0..20) |_| {
        try f.wheel(200000);
        try f.build();
        try f.wheel(-200000);
        try f.build();
        try std.testing.expect(f.runtime.instances.activeCount() < 32);
    }
}

test "virtual rows retire component readers and remount with fresh local state" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\renders, roots = 0, 0
        \\local Row = ouro.component(function(props)
        \\  local value = ouro.signal(7)
        \\  if props.index == 1 then first_signal = value end
        \\  return function()
        \\    renders = renders + 1
        \\    return ouro.box { key = 'cell', height = value() }
        \\  end
        \\end)
        \\function build()
        \\  roots = roots + 1
        \\  return ouro.virtual_list {
        \\    key = 'people', item_count = 10000, item_height = 40,
        \\    item_key = function(i) return 'person-' .. i end,
        \\    render_item = function(i) return Row { key = 'row', index = i } end,
        \\  }
        \\end
    );
    try f.build();
    const first = try f.handle("people/person-1/row/cell");
    const first_scope = try f.runtime.instances.scope(first);
    const initial_renders = f.number("renders");
    try f.exec("first_signal:set(13)");
    try f.build();
    try std.testing.expectEqual(initial_renders + 1, f.number("renders"));
    try std.testing.expectEqual(first, try f.handle("people/person-1/row/cell"));
    try f.wheel(200000);
    try f.build();
    try std.testing.expect(!f.runtime.instances.isActive(first));
    try std.testing.expectError(error.StaleScope, f.scheduler.scopeAcceptsResources(first_scope));
    const offscreen_renders = f.number("renders");
    try f.exec("first_signal:set(19)");
    try f.build();
    try std.testing.expectEqual(offscreen_renders, f.number("renders"));
    try f.wheel(-200000);
    try f.build();
    const remounted = try f.handle("people/person-1/row/cell");
    try std.testing.expect(!std.meta.eql(first, remounted));
    const object = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(remounted));
    try std.testing.expectEqual(@as(f32, 7), object.box.height.?);
    try std.testing.expectEqual(@as(f64, 1), f.number("roots"));
}
