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

    fn saveListPlan(self: *Fixture, name: [*:0]const u8) !void {
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        _ = c.lua_rawgeti(self.state, c.registry_index, self.ui.root_reference);
        _ = c.lua_getfield(self.state, -1, "lists");
        c.lua_pushnil(self.state);
        if (c.lua_next(self.state, -2) == 0) return error.MissingListPlan;
        c.lua_setglobal(self.state, name);
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
    \\local positions = {}
    \\for i = 0, 10000 do positions['person-' .. i] = i end
    \\function build()
    \\  roots = roots + 1
    \\  local shift = prepend() and 1 or 0
    \\  local invalid = broken()
    \\  return ouro.virtual_list {
    \\    key = 'people', item_count = count(), item_height = 40,
    \\    item_key = function(i) return 'person-' .. (i - shift) end,
    \\    item_index = function(key)
    \\      local i = positions[key]
    \\      if i and i + shift >= 1 and i + shift <= count() then return i + shift end
    \\    end,
    \\    render_item = function(i)
    \\      renders = renders + 1
    \\      if invalid then return false end
    \\      return ouro.box { key = 'row', height = 12 }
    \\    end,
    \\  }
    \\end
;

test "virtual fresh root builds evaluate only mounted keys even for a million items" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\keys, rows = 0, 0
        \\counter = ouro.signal(0)
        \\function build()
        \\  local value = counter()
        \\  return ouro.virtual_list {
        \\    key = 'people', item_count = 1000000, item_height = 40,
        \\    item_key = function(i) keys = keys + 1; return 'person-' .. i end,
        \\    render_item = function() rows = rows + 1; return ouro.box {key='row', height=13+value} end,
        \\  }
        \\end
    );
    try f.build();
    try std.testing.expect(f.number("keys") < 32);
    try std.testing.expect(f.number("rows") < 32);
    try std.testing.expectEqual(@as(f32, 40000000), f.runtime.virtual_lists.lists[0].total);
    try f.exec("keys, rows = 0, 0; counter:set(1)");
    try f.build();
    try std.testing.expect(f.number("keys") < 16);
    try std.testing.expect(f.number("rows") < 16);
    const row = try f.handle("people/person-1/row");
    const object = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(row));
    try std.testing.expectEqual(@as(f32, 14), object.box.height.?);
}

test "virtual million variable rows allocate only sparse mounted measurements" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\calls = 0
        \\counter = ouro.signal(0)
        \\function build()
        \\  local value = counter()
        \\  return ouro.virtual_list {
        \\    key='people', item_count=1000000, estimated_item_height=47,
        \\    item_key=function(i) calls=calls+1; return 'person-'..i end,
        \\    render_item=function() return ouro.box {key='row', height=43+value} end,
        \\  }
        \\end
        \\function nodes(t) if not t then return 0 end; return 1+nodes(t.left)+nodes(t.right) end
    );
    try f.build();
    try std.testing.expect(f.number("calls") < 64);
    try f.saveListPlan("plan");
    try f.exec("allocated = nodes(plan.measurements)");
    try std.testing.expect(f.number("allocated") > 0);
    try std.testing.expect(f.number("allocated") < 256);
    try f.exec("calls=0; counter:set(1)");
    try f.build();
    try std.testing.expect(f.number("calls") < 64);
    const row = try f.handle("people/person-1/row");
    const object = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(row));
    try std.testing.expectEqual(@as(f32, 44), object.box.height.?);
}

test "virtual reverse lookup tracks moved anchors focus and lookup-only signals" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\keys, positions, calls = {}, {}, 0
        \\revision = ouro.signal(0)
        \\for i = 1, 10000 do keys[i] = 'person-' .. i; positions[keys[i]] = i end
        \\function swap(a, b)
        \\  keys[a], keys[b] = keys[b], keys[a]
        \\  positions[keys[a]], positions[keys[b]] = a, b
        \\end
        \\function build()
        \\  return ouro.virtual_list {
        \\    key = 'people', item_count = 10000, item_height = 40,
        \\    item_key = function(i) calls = calls + 1; return keys[i] end,
        \\    item_index = function(key) revision(); return invalid or positions[key] end,
        \\    render_item = function(i) return ouro.button {key='row', label=keys[i]} end,
        \\  }
        \\end
    );
    try f.build();
    try f.key(.tab);
    try f.key(.tab);
    const focused = try f.handle("people/person-1/row");
    try std.testing.expectEqual(focused, f.runtime.focus.current().?);
    try f.wheel(200013);
    try f.build();
    const anchor = try f.handle("people/person-5001/row");
    try f.exec("calls = 0; swap(1,9000); revision:set(1)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 200013), try f.offset());
    try std.testing.expectEqual(focused, try f.handle("people/person-1/row"));
    try f.saveListPlan("plan");
    try f.exec("pin = plan.pinned");
    try std.testing.expectEqual(@as(f64, 9000), f.number("pin"));
    try std.testing.expect(f.number("calls") < 32);
    try f.exec("calls = 0; swap(5001,1234); revision:set(2)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 49333), try f.offset());
    try std.testing.expectEqual(anchor, try f.handle("people/person-5001/row"));
    try std.testing.expect(f.number("calls") < 32);
    for ([_][]const u8{ "0", "1.5", "10001", "'wrong'", "1235" }) |invalid| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "invalid = {s}; revision:set(revision()+1)", .{invalid});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expectEqual(@as(f32, 49333), try f.offset());
        try std.testing.expectEqual(anchor, try f.handle("people/person-5001/row"));
    }
    try f.exec("invalid = nil; positions['person-1'] = nil; keys[9000] = 'replacement'; revision:set(revision()+1)");
    try f.build();
    try std.testing.expect(!f.runtime.instances.isActive(focused));
    try std.testing.expectEqual(anchor, try f.handle("people/person-5001/row"));
}

test "virtual offscreen keys are validated when visited and recover transactionally" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\bad = ouro.signal(true)
        \\function build()
        \\  return ouro.virtual_list {
        \\    key='people', item_count=10000, item_height=40,
        \\    item_key=function(i) if i==9990 and bad() then return false end; return 'person-'..i end,
        \\    render_item=function() return ouro.box {key='row', height=12} end,
        \\  }
        \\end
    );
    try f.build();
    const old = try f.handle("people/person-1/row");
    try f.wheel(399560);
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(old, try f.handle("people/person-1/row"));
    try f.exec("bad:set(false)");
    try f.build();
    _ = try f.handle("people/person-9990/row");
}

test "virtual sparse measurements agree with dense prefixes across distant jumps" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\seen = {}
        \\function build()
        \\  return ouro.virtual_list {
        \\    key='people', item_count=257, estimated_item_height=47,
        \\    item_key=function(i) return 'person-'..i end,
        \\    render_item=function(i)
        \\      local h = i%7==0 and 81 or (i%5==0 and 19 or 43)
        \\      seen[i]=h
        \\      return ouro.box {key='row', height=h}
        \\    end,
        \\  }
        \\end
    );
    try f.build();
    try f.saveListPlan("initial");
    try f.exec(
        \\function signature(t)
        \\  if not t then return '-' end
        \\  return '('..t.sum..signature(t.left)..signature(t.right)..')'
        \\end
        \\initial_signature = signature(initial.measurements)
    );
    for ([_]f32{ 0, 35, 201, 1873, 4201, -3157, 9000, -20000 }) |delta| {
        try f.wheel(delta);
        try f.build();
        try f.saveListPlan("plan");
        try f.exec(
            \\local prefix = {0}
            \\for i=1,257 do prefix[i+1]=prefix[i]+(seen[i] or 47) end
            \\expected_total = prefix[258]
            \\correct = plan.total == expected_total and 1 or 0
            \\for i=1,#plan.rows do
            \\  local r=plan.rows[i]
            \\  if r.y~=prefix[r.index] or r.height~=seen[r.index] then correct=0 end
            \\end
        );
        try std.testing.expectEqual(@as(f64, 1), f.number("correct"));
        try std.testing.expectEqual(@as(f32, @floatCast(f.number("expected_total"))), f.runtime.virtual_lists.lists[0].total);
    }
    try f.exec("immutable = signature(initial.measurements) == initial_signature and 1 or 0");
    try std.testing.expectEqual(@as(f64, 1), f.number("immutable"));
}

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

test "virtual lazy keys refresh mounted provider dependencies and preserve lookup anchors" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\keys, roots = 0, 0
        \\shift, duplicate = ouro.signal(0), ouro.signal(false)
        \\height = ouro.signal(12)
        \\local positions = {}
        \\for i = -2, 10000 do positions['person-' .. i] = i end
        \\function build()
        \\  roots = roots + 1
        \\  return ouro.virtual_list {
        \\    key = 'people', item_count = 10000, item_height = 40,
        \\    item_key = function(i)
        \\      keys = keys + 1
        \\      if duplicate() and i == 5005 then i = 5001 end
        \\      return 'person-' .. (i - shift())
        \\    end,
        \\    item_index = function(key)
        \\      local i = positions[key] + shift()
        \\      if i >= 1 and i <= 10000 then return i end
        \\    end,
        \\    render_item = function() return ouro.box { key = 'row', height = height() } end,
        \\  }
        \\end
    );
    try f.build();
    const initial_keys = f.number("keys");
    try f.wheel(200013);
    try f.build();
    const retained = try f.handle("people/person-5001/row");
    try f.wheel(40);
    try f.build();
    try std.testing.expect(f.number("keys") - initial_keys < 32);
    try std.testing.expectEqual(@as(f32, 200053), try f.offset());
    // A dependency read only by item_key must still invalidate the metadata
    // after clean native builds, even though the root description is reused.
    try f.exec("shift:set(1)");
    try f.build();
    try std.testing.expect(f.number("keys") > initial_keys);
    try std.testing.expectEqual(@as(f64, 1), f.number("roots"));
    try std.testing.expectEqual(retained, try f.handle("people/person-5001/row"));
    try std.testing.expectEqual(@as(f32, 200093), try f.offset());
    // A duplicate in the visited range must not replace committed rows.
    try f.exec("duplicate:set(true)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(@as(f32, 200093), try f.offset());
    try f.exec("duplicate:set(false); shift:set(2)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 200133), try f.offset());
    try std.testing.expectEqual(retained, try f.handle("people/person-5001/row"));
    const rebuilt_keys = f.number("keys");
    try f.wheel(-80);
    try f.build();
    try std.testing.expect(f.number("keys") - rebuilt_keys < 16);
    try f.exec("height:set(19)");
    try f.build();
    const object = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(retained));
    try std.testing.expectEqual(@as(f32, 19), object.box.height.?);
    try std.testing.expectEqual(@as(f64, 1), f.number("roots"));
    // Removing a list retires both its metadata and visible-row readers.
    try f.exec("function build() return ouro.box { key = 'empty' } end");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    _ = try f.handle("empty");
    try std.testing.expectEqual(@as(usize, 0), f.runtime.virtual_lists.count);
    try std.testing.expect(!f.runtime.instances.isActive(retained));
    for (f.signals.edges) |edge| try std.testing.expect(!edge.active);
}

test "virtual fresh providers evaluate the visible range and stage late key changes" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\calls, mode = 0, 0
        \\generation, height = ouro.signal(0), ouro.signal(40)
        \\function build()
        \\  local version = generation()
        \\  return ouro.virtual_list {
        \\    key = 'people', item_count = 30, item_height = height(),
        \\    item_key = function(i)
        \\      calls = calls + 1
        \\      if mode == 1 and i == 9 then return 'person-1' end
        \\      if mode >= 2 and i == 9 then return 'replacement' end
        \\      if mode == 3 and i == 10 then return 'replacement' end
        \\      if mode == 4 and i == 10 then return false end
        \\      return 'person-' .. i
        \\    end,
        \\    render_item = function() return ouro.box { key = 'row', height = 12 + version } end,
        \\  }
        \\end
    );
    try f.build();
    try f.wheel(85);
    try f.build();
    const row = try f.handle("people/person-3/row");
    try f.saveListPlan("before");
    const calls = f.number("calls");
    try f.exec("generation:set(1)");
    try f.build();
    // At offset 85, rows 3..8 intersect the 200px viewport; overscan adds 1,2,9,10.
    try std.testing.expectEqual(calls + 10, f.number("calls"));
    try f.saveListPlan("after");
    try f.exec("sparse = (after.keys[10] == 'person-10' and after.keys[11] == nil and after.measurements == nil and after.prefix == nil) and 1 or 0");
    try std.testing.expectEqual(@as(f64, 1), f.number("sparse"));
    const object = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(row));
    try std.testing.expectEqual(@as(f32, 13), object.box.height.?);
    try f.exec("height:set(41)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 1230), f.runtime.virtual_lists.lists[0].total);
    try std.testing.expectEqual(@as(f32, 87), try f.offset());
    try f.saveListPlan("resized");
    try f.exec("resized_ok = (resized.estimate == 41 and resized.measurements == nil) and 1 or 0");
    try std.testing.expectEqual(@as(f64, 1), f.number("resized_ok"));
    // A late visited key collides with an earlier key in this evaluation.
    try f.exec("mode = 1; generation:set(2)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(@as(f32, 87), try f.offset());
    try f.exec("unchanged = (resized.keys[9] == 'person-9' and resized.positions['replacement'] == nil) and 1 or 0; mode = 2");
    try std.testing.expectEqual(@as(f64, 1), f.number("unchanged"));
    try f.build();
    try f.saveListPlan("changed");
    try f.exec("changed_ok = (changed.keys ~= resized.keys and changed.keys[8] == 'person-8' and changed.keys[9] == 'replacement' and changed.positions['replacement'] == 9) and 1 or 0");
    try std.testing.expectEqual(@as(f64, 1), f.number("changed_ok"));
    for ([_][]const u8{ "mode = 3; generation:set(3)", "mode = 4; generation:set(4)" }) |source| {
        try f.exec(source);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try f.exec("unchanged = (changed.keys[10] == 'person-10' and changed.positions['replacement'] == 9) and 1 or 0");
        try std.testing.expectEqual(@as(f64, 1), f.number("unchanged"));
    }
    try f.exec("mode = 0");
    try f.build();
    try std.testing.expectEqual(row, try f.handle("people/person-3/row"));
}

test "virtual clean scopes preserve providers but honor reader render and host invalidation" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\keys, rows, roots, owners, plain = 0, 0, 0, 0, 0
        \\counter, owner, root, key_shift, row_height = ouro.signal(0), ouro.signal(0), ouro.signal(0), ouro.signal(0), ouro.signal(12)
        \\bad, staged = ouro.signal(false), ouro.signal(0)
        \\local description = ouro.virtual_list {
        \\  key = 'people', height = 160, item_count = 30, item_height = 40,
        \\  item_key = function(i)
        \\    keys = keys + 1
        \\    if bad() and i == 7 then local read = staged(); i = 1 end
        \\    return 'person-' .. (i + plain + key_shift())
        \\  end,
        \\  render_item = function()
        \\    rows = rows + 1
        \\    return ouro.box { key = 'row', height = row_height() }
        \\  end,
        \\}
        \\local Counter = ouro.stateful(function()
        \\  return function() return ouro.box { key = 'value', width = counter() + 1, height = 10 } end
        \\end)
        \\local List = ouro.stateful(function()
        \\  return function() owners = owners + 1; local read = owner(); return description end
        \\end)
        \\function build()
        \\  roots = roots + 1; local read = root()
        \\  return ouro.column { key = 'layout', Counter { key = 'counter' }, List { key = 'list' } }
        \\end
    );
    try f.build();
    const keys = f.number("keys");
    const rows = f.number("rows");
    try f.exec("counter:set(1)");
    try f.build();
    try std.testing.expectEqual(keys, f.number("keys"));
    try std.testing.expectEqual(rows, f.number("rows"));
    try std.testing.expectEqual(@as(f64, 1), f.number("roots"));
    try std.testing.expectEqual(@as(f64, 1), f.number("owners"));
    const counter = try f.handle("layout/counter/value");
    const value = try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(counter));
    try std.testing.expectEqual(@as(f32, 2), value.box.width.?);
    try f.exec("row_height:set(17)");
    try f.build();
    try std.testing.expect(f.number("keys") - keys < 16);
    try std.testing.expect(f.number("rows") > rows);
    try f.exec("key_shift:set(1)");
    try f.build();
    try std.testing.expect(f.number("keys") > keys);
    try f.saveListPlan("committed");
    try f.exec("bad:set(true)");
    const edges = try std.testing.allocator.dupe(@TypeOf(f.signals.edges[0]), f.signals.edges);
    defer std.testing.allocator.free(edges);
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    for (edges, f.signals.edges) |before, after| {
        try std.testing.expectEqual(before.active, after.active);
        if (before.active) {
            try std.testing.expectEqual(before.signal, after.signal);
            try std.testing.expectEqual(before.reader, after.reader);
            try std.testing.expectEqual(before.dirty, after.dirty);
        }
    }
    try f.exec("intact = committed.keys[7] == 'person-8' and 1 or 0; bad:set(false)");
    try std.testing.expectEqual(@as(f64, 1), f.number("intact"));
    try f.build();
    // The declaration stays identical, but an enclosing render runs after
    // plain captured data changes. It must not be mistaken for a clean scope.
    for ([_][]const u8{
        "plain = 1; owner:set(1)",
        "plain = 2; root:set(1)",
        "plain = 3; counter:set(2); local previous = build; function build() return previous() end",
    }) |source| {
        const previous = f.number("keys");
        try f.exec(source);
        try f.build();
        try std.testing.expect(f.number("keys") > previous);
    }
    const before_host = f.number("keys");
    try f.exec("plain = 4");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try f.build();
    try std.testing.expect(f.number("keys") > before_host);
    const before_resize = f.number("keys");
    f.size.width += 20;
    try f.build();
    try std.testing.expect(f.number("keys") > before_resize);
}

test "virtual nested list providers follow executed outer row scope" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\keys, captured = 0, 0
        \\value, counter = ouro.signal(0), ouro.signal(0)
        \\local inner = ouro.virtual_list { key = 'inner', height = 80, item_count = 2, item_height = 40,
        \\  item_key = function(i) keys = keys + 1; return 'inner-' .. (i + captured) end,
        \\  render_item = function() return ouro.box { key = 'box', height = 40 } end,
        \\}
        \\local Counter = ouro.stateful(function()
        \\  return function() local read = counter(); return nil end
        \\end)
        \\function build() return ouro.stack { key = 'layout', Counter { key = 'counter' },
        \\  ouro.virtual_list { key = 'outer', height = 120, item_count = 1, item_height = 100,
        \\    item_key = function() return 'outer' end,
        \\    render_item = function() captured = value(); return inner end,
        \\  } } end
    );
    try f.build();
    const keys = f.number("keys");
    try f.exec("counter:set(1)");
    try f.build();
    try std.testing.expectEqual(keys, f.number("keys"));
    const old = try f.handle("layout/outer/outer/inner/inner-1/box");
    try f.exec("value:set(10)");
    try f.build();
    try std.testing.expect(f.number("keys") > keys);
    try std.testing.expect(!f.runtime.instances.isActive(old));
    _ = try f.handle("layout/outer/outer/inner/inner-11/box");
}

test "virtual retained rows still follow nested measurements and focus pin changes" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\keys, rows = 0, 0
        \\height, counter = ouro.signal(40), ouro.signal(0)
        \\local Row = ouro.stateful(function(props)
        \\  return function() return ouro.box { key = 'box', height = props.index == 1 and height() or 40,
        \\    ouro.button { key = 'button', label = 'Focus' } } end
        \\end)
        \\local Counter = ouro.stateful(function()
        \\  return function() local read = counter(); return nil end
        \\end)
        \\function build() return ouro.stack { key = 'layout', Counter { key = 'counter' },
        \\  ouro.virtual_list { key = 'people', item_count = 30, estimated_item_height = 40,
        \\    item_key = function(i) keys = keys + 1; return 'person-' .. i end,
        \\    render_item = function(i) rows = rows + 1; return Row { key = 'row', index = i } end,
        \\  } } end
    );
    try f.build();
    const keys = f.number("keys");
    const rows = f.number("rows");
    try f.exec("counter:set(1)");
    try f.build();
    try std.testing.expectEqual(keys, f.number("keys"));
    try std.testing.expectEqual(rows, f.number("rows"));
    // Only the mounted row component reads height. Its new measurement must
    // invalidate the clean list plan on the subsequent native layout pass.
    try f.exec("height:set(73)");
    try f.build();
    try std.testing.expect(f.number("keys") - keys < 32);
    try std.testing.expect(f.number("rows") > rows);
    try std.testing.expectEqual(@as(f32, 1233), f.runtime.virtual_lists.lists[0].total);
    try f.key(.tab);
    try f.key(.tab);
    const focused = try f.handle("layout/people/person-1/row/box/button");
    try std.testing.expectEqual(focused, f.runtime.focus.current().?);
    const before_focus = f.number("rows");
    try f.exec("counter:set(2)");
    try f.build();
    try std.testing.expect(f.number("rows") > before_focus);
    try f.saveListPlan("focused");
    try f.exec("pin = focused.pinned");
    try std.testing.expectEqual(@as(f64, 1), f.number("pin"));
    const before_scroll = f.number("keys");
    const target = try f.runtime.semanticTarget("layout/people");
    try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = target.center } });
    try f.runtime.routePointer(.{ .axis = .{ .window = f.runtime.window, .time_ms = 1, .axis = .vertical, .delta = 700 } });
    var unused: Vm = undefined;
    try f.runtime.dispatchInput(&unused);
    try f.build();
    try std.testing.expect(f.runtime.instances.isActive(focused));
    try std.testing.expect(f.number("keys") - before_scroll < 32);
    const before_unpin = f.number("keys");
    try f.key(.tab);
    try f.exec("counter:set(3)");
    try f.build();
    try std.testing.expect(!f.runtime.instances.isActive(focused));
    try std.testing.expect(f.number("keys") - before_unpin < 32);
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
        \\local Row = ouro.stateful(function(props)
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

test "ensure_visible virtual indices reveal lazily without stealing focus or controlling manual scroll" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\selected, count = ouro.signal(700001), ouro.signal(1000000)
        \\broken = ouro.signal(false)
        \\keys, rows = 0, 0
        \\function build()
        \\  return ouro.virtual_list {
        \\    key='people', item_count=count(), item_height=40, ensure_visible=selected(),
        \\    item_key=function(i) keys=keys+1; return 'person-'..i end,
        \\    render_item=function(i) rows=rows+1; if broken() then return false end; return ouro.box {key='row', height=17} end,
        \\  }
        \\end
    );
    try f.build();
    try std.testing.expectEqual(@as(f32, 700001 * 40 - 200), try f.offset());
    _ = try f.handle("people/person-700001/row");
    try std.testing.expect(f.number("keys") < 48);
    try std.testing.expect(f.number("rows") < 48);
    const focus = f.runtime.focus.current();
    try f.exec("selected:set(700002)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 700002 * 40 - 200), try f.offset());
    try std.testing.expectEqual(focus, f.runtime.focus.current());
    try f.exec("selected:set(700001)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 700002 * 40 - 200), try f.offset());
    try f.exec("selected:set(699990)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 699989 * 40), try f.offset());
    try f.wheel(-124);
    try f.build();
    try std.testing.expectEqual(@as(f32, 699989 * 40 - 124), try f.offset());
    try f.build();
    try std.testing.expectEqual(@as(f32, 699989 * 40 - 124), try f.offset());
    f.size.height = 124;
    try f.build();
    try std.testing.expectEqual(@as(f32, 699990 * 40 - 100), try f.offset());
    try f.exec("selected:set(false)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(@as(f32, 699990 * 40 - 100), try f.offset());
    try f.exec("selected:set(800000); broken:set(true)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(@as(f32, 699990 * 40 - 100), try f.offset());
    try f.exec("selected:set(1000001); broken:set(false)"); // A removed/out-of-range target is a no-op.
    try f.build();
    try std.testing.expectEqual(@as(f32, 699990 * 40 - 100), try f.offset());
    try f.exec("count:set(0)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 0), try f.offset());
    try std.testing.expectEqual(@as(usize, 0), f.runtime.virtual_lists.row_count);
}

test "ensure_visible launcher selection respects remaining flex height and keeps search focused" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\selected, gap = ouro.signal(1), ouro.signal(11)
        \\function build()
        \\  return ouro.column {key='content', gap=gap(),
        \\    ouro.text_input {key='search', height=37, default_text='', autofocus=true},
        \\    ouro.virtual_list {
        \\      key='people', flex=1, item_count=1000, item_height=40, ensure_visible=selected(),
        \\      item_key=function(i) return 'person-'..i end,
        \\      render_item=function() return ouro.box {key='row', height=17} end,
        \\    },
        \\  }
        \\end
    );
    try f.build();
    const search = try f.handle("content/search");
    try std.testing.expectEqual(search, f.runtime.focus.current().?);
    try f.exec("selected:set(50)");
    try f.build();
    const list = try f.handle("content/people");
    try std.testing.expectEqual(@as(f32, 50 * 40 - (200 - 37 - 11)), try f.runtime.instances.scrollOffset(list));
    try std.testing.expectEqual(search, f.runtime.focus.current().?);
    try f.exec("gap:set(29)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 50 * 40 - (200 - 37 - 29)), try f.runtime.instances.scrollOffset(list));
    try std.testing.expectEqual(search, f.runtime.focus.current().?);
    const viewport = (try f.runtime.semanticTarget("content/people")).bounds;
    const row = (try f.runtime.semanticTarget("content/people/person-50")).bounds;
    try std.testing.expect(row.y >= viewport.y);
    try std.testing.expectEqual(viewport.y + viewport.height, row.y + row.height);
}

test "ensure_visible virtual keys follow item_index through reordering and removal" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\position, missing = ouro.signal(901), ouro.signal(false)
        \\local positions = {}
        \\for i=1,1000 do positions['person-'..i] = i end
        \\function build()
        \\  return ouro.virtual_list {
        \\    key='people', item_count=1000, item_height=40, ensure_visible='chosen',
        \\    item_key=function(i) return i == position() and not missing() and 'chosen' or 'person-'..i end,
        \\    item_index=function(key)
        \\      if key == 'chosen' then if not missing() then return position() end
        \\      else local i=positions[key]; if i ~= position() or missing() then return i end end
        \\    end,
        \\    render_item=function() return ouro.box {key='row', height=17} end,
        \\  }
        \\end
    );
    try f.build();
    try std.testing.expectEqual(@as(f32, 901 * 40 - 200), try f.offset());
    const chosen = try f.handle("people/chosen/row");
    try f.exec("position:set(23)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 22 * 40), try f.offset());
    try std.testing.expectEqual(chosen, try f.handle("people/chosen/row"));
    try f.exec("missing:set(true)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 22 * 40), try f.offset());
    try f.exec("missing:set(false); position:set(999)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 999 * 40 - 200), try f.offset());
}

test "ensure_visible virtual variable rows correct estimates and settle oversized targets" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\height = ouro.signal(91)
        \\function build()
        \\  return ouro.virtual_list {
        \\    key='people', item_count=1000, estimated_item_height=40, ensure_visible=37,
        \\    item_key=function(i) return 'person-'..i end,
        \\    render_item=function(i) return ouro.box {key='row', height=i == 37 and height() or 40} end,
        \\  }
        \\end
    );
    try f.build();
    try std.testing.expectEqual(@as(f32, 36 * 40 + 91 - 200), try f.offset());
    const viewport = (try f.runtime.semanticTarget("people")).bounds;
    var row = (try f.runtime.semanticTarget("people/person-37")).bounds;
    try std.testing.expectEqual(viewport.y + viewport.height, row.y + row.height);
    try f.exec("height:set(317)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 36 * 40), try f.offset());
    row = (try f.runtime.semanticTarget("people/person-37")).bounds;
    try std.testing.expectEqual(viewport.y, row.y);
    try std.testing.expectEqual(@as(f32, 317), row.height);
    const builds = f.runtime.metrics.builds.count;
    try f.build();
    try std.testing.expectEqual(builds, f.runtime.metrics.builds.count);
    try std.testing.expectEqual(@as(f32, 36 * 40), try f.offset());
}

test "ensure_visible scroll paths use actual nested layout on both axes" {
    inline for (.{ false, true }) |horizontal| {
        const f = try Fixture.create();
        defer f.destroy();
        try f.exec(if (horizontal) "horizontal=true" else "horizontal=false");
        try f.exec(
            \\selected, gap, large = ouro.signal('rows/last'), ouro.signal(13), ouro.signal(false)
            \\local Last = ouro.stateful(function(props)
            \\  return function() return ouro.box {key='body',
            \\    width=horizontal and props.extent or 20, height=horizontal and 20 or props.extent} end
            \\end)
            \\function build()
            \\  local extent = large() and 407 or 51
            \\  local children = {
            \\    ouro.box {key='first', width=horizontal and 277 or 20, height=horizontal and 20 or 277},
            \\    Last {key='last', extent=extent},
            \\  }
            \\  local props = {key='rows', gap=gap(), children=children}
            \\  return ouro.scroll {key='people', axis=horizontal and 'horizontal' or 'vertical',
            \\    ensure_visible=selected(), horizontal and ouro.row(props) or ouro.column(props)}
            \\end
        );
        const viewport: f32 = if (horizontal) 300 else 200;
        try f.build();
        try std.testing.expectEqual(277 + 13 + 51 - viewport, try f.offset());
        const scroll = try f.handle("people");
        try std.testing.expect(try f.runtime.instances.scrollBy(scroll, -19));
        try f.runtime.prepareFrame(1);
        try f.build();
        try std.testing.expectEqual(277 + 13 + 51 - viewport - 19, try f.offset());
        try f.exec("gap:set(29)");
        try f.build();
        try std.testing.expectEqual(277 + 29 + 51 - viewport, try f.offset());
        try f.exec("large:set(true)");
        try f.build();
        try std.testing.expectEqual(@as(f32, 277 + 29), try f.offset());
        try f.runtime.prepareFrame(1);
        try std.testing.expectEqual(@as(f32, 277 + 29), try f.offset());
        try f.exec("selected:set('rows/missing')");
        try f.build();
        try std.testing.expectEqual(@as(f32, 277 + 29), try f.offset());
        try f.exec("selected:set('rows/first')");
        try f.build();
        try std.testing.expectEqual(@as(f32, 0), try f.offset());
        try f.exec("selected:set(nil)");
        try f.build();
        try std.testing.expect(try f.runtime.instances.scrollBy(scroll, 77));
        try f.runtime.prepareFrame(1);
        try std.testing.expectEqual(@as(f32, 77), try f.offset());
    }
}

test "ensure_visible rejects invalid declarations without replacing the committed UI" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(fixed_source);
    try f.build();
    const row = try f.handle("people/person-1/row");
    inline for (.{ "0", "-1", "1.5", "true", "{}", "''", "'person-1'" }) |invalid| {
        try f.exec("function build() return ouro.virtual_list {key='people', item_count=10, item_height=40, ensure_visible=" ++ invalid ++ ", item_key=function(i) return 'person-'..i end, render_item=function() return ouro.box {key='row'} end} end");
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expectEqual(row, try f.handle("people/person-1/row"));
    }
    inline for (.{ "1", "false", "{}", "''", "'rows//last'", "'/last'", "'rows/'" }) |invalid| {
        try f.exec("function build() return ouro.scroll {key='people', ensure_visible=" ++ invalid ++ ", ouro.box {key='row'}} end");
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try std.testing.expectEqual(row, try f.handle("people/person-1/row"));
    }
}

test "virtual scrollbar gutter remeasures wrapping rows without losing their within-row anchor" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\bar=ouro.signal(false); request=ouro.signal({offset=13,token=1})
        \\function build() return ouro.virtual_list {key='people',scrollbar=bar(),scroll_to=request(),
        \\ item_count=10000,estimated_item_height=40,item_key=function(i) return 'row-'..i end,
        \\ render_item=function() return ouro.row {key='tiles',wrap=true,gap=5,run_gap=0,
        \\  ouro.box {key='a',width=145,height=40}, ouro.box {key='b',width=145,height=40}} end} end
    );
    try f.build();
    const row = try f.handle("people/row-1");
    const render = try f.runtime.instances.renderObject(row);
    try std.testing.expectEqual(@as(f32, 40), (try f.runtime.tree.nodeSize(render)).height);
    try std.testing.expectEqual(@as(f32, 13), try f.offset());
    try f.exec("bar:set(true)");
    try f.build();
    try std.testing.expectEqual(row, try f.handle("people/row-1"));
    try std.testing.expectEqual(@as(f32, 288), f.runtime.virtual_lists.lists[0].width);
    try std.testing.expectEqual(@as(f32, 80), (try f.runtime.tree.nodeSize(render)).height);
    try std.testing.expectEqual(@as(f32, 13), try f.offset());
    try f.wheel(17);
    try f.build();
    try std.testing.expectEqual(@as(f32, 30), try f.offset());
    try f.exec("bar:set(false); request:set(nil)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 40), (try f.runtime.tree.nodeSize(render)).height);
    try std.testing.expectEqual(@as(f32, 30), try f.offset());
    try f.exec("request:set({offset=13,token=1})");
    try f.build();
    try std.testing.expectEqual(@as(f32, 13), try f.offset());
    try std.testing.expect(f.runtime.instances.activeCount() < 70);
    // Conflicting requests must fail before replacing the retained viewport.
    const viewport = try f.handle("people");
    try f.exec("function build() return ouro.virtual_list {key='people',item_count=1,item_height=40,scroll_to={offset=0,token=2},ensure_visible=1,item_key=function() return 'a' end,render_item=function() return ouro.box {key='body'} end} end");
    _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(viewport, try f.handle("people"));
    try std.testing.expectEqual(@as(f32, 13), try f.offset());
}
