const std = @import("std");
const c = @import("c.zig");
const UiBuild = @import("ui_build.zig").UiBuild;
const Argument = @import("ui_build.zig").Argument;
const Signals = @import("signals.zig").Signals;
const Scheduler = @import("../task/scheduler.zig").Scheduler;
const Scope = @import("../task/scheduler.zig").ScopeHandle;
const owners_module = @import("../ui/instance/build_owner.zig");
const instance = @import("../ui/instance/tree.zig");
const RenderTree = @import("../ui/render_object/root.zig").Tree;
const semantics = @import("../ui/semantics/snapshot.zig");

const Fixture = struct {
    state: *c.State,
    signals: Signals = undefined,
    scheduler: Scheduler = undefined,
    scope: Scope = undefined,
    owners: owners_module.BuildOwners = undefined,
    owner: owners_module.BuildOwnerHandle = undefined,
    renders: RenderTree = undefined,
    instances: instance.Tree = undefined,
    snapshot: semantics.Snapshot = undefined,
    ui: UiBuild = undefined,
    descriptors: [64]instance.Descriptor = undefined,
    semantic_storage: [64]semantics.Descriptor = undefined,

    fn create() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.* = .{ .state = c.luaL_newstate() orelse return error.LuaStateCreationFailed };
        c.lua_createtable(self.state, 0, 4);
        c.lua_setglobal(self.state, "ouro");
        try self.signals.init(std.testing.allocator, self.state, 128, 128, 128);
        try self.scheduler.init(std.testing.allocator, 128, 4, 0);
        self.scope = try self.scheduler.createScope(self.scheduler.application_scope);
        try self.owners.init(std.testing.allocator, &self.scheduler, self.scope, 2, 8);
        self.owner = try self.owners.mount(null, 1);
        try self.renders.init(std.testing.allocator, 64);
        try self.instances.init(std.testing.allocator, &self.scheduler, &self.renders, self.scope, 64);
        try self.snapshot.init(std.testing.allocator, 64, 4096);
        try self.ui.init(self.state, &self.descriptors);
        self.ui.attachSignals(&self.signals);
        self.ui.components.instances = &self.instances;
        self.ui.enableDeclarativeWidgets(.light);
        try self.ui.attachSemantics(&self.semantic_storage);
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.signals.disposeOwner(.{ .owners = &self.owners, .handle = self.owner }) catch unreachable;
        self.ui.disposeOwner(&self.owners, self.owner);
        self.instances.reconcile(&.{}) catch unreachable;
        self.owners.retire(self.owner) catch unreachable;
        self.scheduler.applyQueuedCancellations() catch unreachable;
        self.instances.collectRetired() catch unreachable;
        self.owners.collectRetired() catch unreachable;
        self.snapshot.deinit();
        self.instances.deinit();
        self.renders.deinit();
        self.owners.deinit();
        self.scheduler.destroyScope(self.scope) catch unreachable;
        self.scheduler.deinit();
        c.lua_close(self.state);
        self.signals.deinit();
        std.testing.allocator.destroy(self);
    }

    fn exec(self: *Fixture, source: []const u8) !void {
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        try load(self.state, source);
        if (c.lua_pcallk(self.state, 0, 0, 0, 0, null) != c.ok) {
            report(self.state);
            return error.LuaExecutionFailed;
        }
    }

    fn expect(self: *Fixture, expression: []const u8) !void {
        const source = try std.fmt.allocPrint(std.testing.allocator, "return {s}", .{expression});
        defer std.testing.allocator.free(source);
        const top = c.lua_gettop(self.state);
        defer c.lua_settop(self.state, top);
        try load(self.state, source);
        if (c.lua_pcallk(self.state, 0, 1, 0, 0, null) != c.ok) {
            report(self.state);
            return error.LuaExecutionFailed;
        }
        if (c.lua_toboolean(self.state, -1) == 0) {
            std.debug.print("failed Lua expectation: {s}\n", .{expression});
            return error.TestUnexpectedResult;
        }
    }

    fn build(self: *Fixture) !void {
        return self.buildArgs("build", &.{});
    }

    fn buildArgs(self: *Fixture, name: [*:0]const u8, args: []const Argument) !void {
        var cycle = self.owners.beginCycle();
        const work = (try cycle.take()) orelse return error.ExpectedDirtyBuild;
        errdefer self.owners.retry(work) catch unreachable;
        const descriptors = try self.ui.build(&self.owners, work, name, args);
        errdefer {
            self.ui.rollbackHandlers();
            self.ui.rollbackDependencies(&self.owners, work) catch unreachable;
        }
        const plan = try self.instances.prepareReconcile(descriptors);
        try self.snapshot.validate(self.ui.semanticDescriptors());
        try self.ui.validateDependencies(&self.owners, work);
        self.snapshot.stage(self.ui.semanticDescriptors());
        try self.instances.applyReconcile(plan);
        self.snapshot.commitStaged();
        try self.ui.commitDependencies(&self.owners, work);
        self.ui.rollbackHandlers();
        try self.owners.complete(work);
    }

    fn width(self: *Fixture, path: []const u8) !f32 {
        const node = try self.snapshot.findPath(path);
        const handle = self.instances.handleForId(node.id).?;
        return (try self.renders.objectAt(try self.instances.renderObject(handle))).box.width.?;
    }

    fn clean(self: *Fixture) !void {
        var cycle = self.owners.beginCycle();
        try std.testing.expect((try cycle.take()) == null);
    }
};

fn load(state: *c.State, source: []const u8) !void {
    if (c.luaL_loadbufferx(state, source.ptr, source.len, "@component-test", "t") != c.ok) {
        report(state);
        return error.LuaLoadFailed;
    }
}

fn report(state: *c.State) void {
    var length: usize = 0;
    if (c.lua_tolstring(state, -1, &length)) |value| std.debug.print("Lua: {s}\n", .{value[0..length]});
}

const counters =
    \\counts, flags, renders, saved_props = {}, {}, {}, {}
    \\initializations, root_renders = 0, 0
    \\offset, shared, alternate = ouro.signal(0), ouro.signal(0), ouro.signal(11)
    \\reversed, visible, replacement = ouro.signal(false), ouro.signal(true), ouro.signal(false)
    \\local function initialize(props)
    \\  initializations = initializations + 1
    \\  local count, choose = ouro.signal(props.initial), ouro.signal(true)
    \\  counts[props.key], flags[props.key], saved_props[props.key] = count, choose, props
    \\  return function()
    \\    renders[props.key] = (renders[props.key] or 0) + 1
    \\    local extra
    \\    if choose() then extra = shared() else extra = alternate() end
    \\    return ouro.box { key = "counter", width = count() + props.extra + extra, height = 9, flex = props.flex }
    \\  end
    \\end
    \\Counter, Other = ouro.stateful(initialize), ouro.stateful(initialize)
    \\unused = Counter { key = "never", initial = 900 }
    \\function build(width)
    \\  root_renders = root_renders + 1
    \\  last_width = width
    \\  local constructor = Counter
    \\  if replacement() then constructor = Other end
    \\  local first = constructor { key = "first", initial = 0, extra = offset(), flex = 1 }
    \\  local second = Counter { key = "second", initial = 100, extra = offset(), flex = 2 }
    \\  local children
    \\  if not visible() then children = { second }
    \\  elseif reversed() then children = { second, first }
    \\  else children = { first, second } end
    \\  return ouro.row { key = "counters", children = children }
    \\end
;

test "stateless and stateful constructors replace the old API names and reject non-functions" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.expect("ouro.compose == nil and ouro.component == nil");
    for ([_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "ouro.stateless()", .message = "ouro.stateless expects one render function" },
        .{ .source = "ouro.stateful({})", .message = "ouro.stateful expects one initializer function" },
    }) |case| {
        const top = c.lua_gettop(f.state);
        defer c.lua_settop(f.state, top);
        try load(f.state, case.source);
        try std.testing.expect(c.lua_pcallk(f.state, 0, 0, 0, 0, null) != c.ok);
        var length: usize = 0;
        const message = c.lua_tolstring(f.state, -1, &length) orelse return error.ExpectedErrorMessage;
        try std.testing.expect(std.mem.endsWith(u8, message[0..length], case.message));
    }
}

test "stateless compositions replace signal dependencies independently of retained components" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\a, b, choose, visible = ouro.signal(13), ouro.signal(29), ouro.signal(true), ouro.signal(true)
        \\root_renders, component_renders, compose_renders = 0, 0, 0
        \\local View = ouro.stateless(function(p)
        \\  compose_renders=compose_renders+1
        \\  return ouro.box {key=p.key, width=choose() and a() or b()}
        \\end)
        \\local Retained = ouro.stateful(function()
        \\  return function()
        \\    component_renders=component_renders+1
        \\    return View {key='value'}
        \\  end
        \\end)
        \\function build()
        \\  root_renders=root_renders+1
        \\  return ouro.row {key='root', visible() and Retained {key='retained'} or nil}
        \\end
    );
    try f.build();
    const original = (try f.snapshot.findPath("root/retained/value")).id;
    try f.exec("a:set(17)");
    try f.build();
    try f.expect("root_renders==1 and component_renders==1 and compose_renders==2");
    try std.testing.expectEqual(@as(f32, 17), try f.width("root/retained/value"));
    try f.exec("choose:set(false)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 29), try f.width("root/retained/value"));
    try f.exec("a:set(41)");
    try f.clean();
    try f.exec("b:set(37)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 37), try f.width("root/retained/value"));
    try std.testing.expectEqual(original, (try f.snapshot.findPath("root/retained/value")).id);
    try f.exec("visible:set(false)");
    try f.build();
    try f.exec("b:set(53); choose:set(true)");
    try f.clean();
}

test "components retain keyed state and execute only subscribed Lua readers" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(counters);
    try f.expect("initializations == 0");
    try f.build();
    try f.expect("initializations == 2 and root_renders == 1 and renders.first == 1 and renders.second == 1");
    try std.testing.expectEqual(@as(f32, 0), try f.width("counters/first/counter"));
    try std.testing.expectEqual(@as(f32, 100), try f.width("counters/second/counter"));
    const first_node = try f.snapshot.findPath("counters/first/counter");
    const first_handle = f.instances.handleForId(first_node.id).?;
    const second_id = (try f.snapshot.findPath("counters/second/counter")).id;
    try std.testing.expect(first_node.id != second_id);
    // No component render wrapper: both boxes remain direct flex children.
    try std.testing.expectEqual(@as(usize, 5), f.instances.activeCount());
    try std.testing.expectEqual(@as(u16, 1), f.descriptors[3].parent_data.flex.factor);
    try std.testing.expectEqual(@as(u16, 2), f.descriptors[4].parent_data.flex.factor);
    try f.exec("counts.first:set(3)");
    try f.build();
    try f.expect("root_renders == 1 and renders.first == 2 and renders.second == 1");
    try std.testing.expectEqual(@as(f32, 3), try f.width("counters/first/counter"));
    try f.exec("offset:set(17)");
    try f.build();
    try f.expect("initializations == 2 and root_renders == 2 and counts.first() == 3 and saved_props.first.extra == 17");
    try std.testing.expectEqual(@as(f32, 20), try f.width("counters/first/counter"));
    try std.testing.expectEqual(@as(f32, 117), try f.width("counters/second/counter"));
    try f.exec("shared:set(5)");
    try f.build();
    try f.expect("root_renders == 2 and renders.first == 4 and renders.second == 3");
    try f.exec("flags.first:set(false)");
    try f.build();
    try f.exec("shared:set(9)");
    try f.build();
    try f.expect("renders.first == 5 and renders.second == 4");
    try std.testing.expectEqual(@as(f32, 31), try f.width("counters/first/counter"));
    try std.testing.expectEqual(@as(f32, 126), try f.width("counters/second/counter"));
    try f.exec("reversed:set(true)");
    try f.build();
    try f.expect("initializations == 2 and renders.first == 5 and renders.second == 4");
    try std.testing.expectEqual(first_handle, f.instances.handleForId(first_node.id).?);
    try std.testing.expectEqual(second_id, f.descriptors[3].id);
    try std.testing.expectEqual(first_node.id, f.descriptors[4].id);

    const scope = try f.instances.scope(first_handle);
    const task = try f.scheduler.createTask(scope);
    try f.exec("old_count = counts.first; visible:set(false)");
    try f.build();
    try std.testing.expect(!f.instances.isActive(first_handle));
    try std.testing.expect(!(try f.scheduler.cancellationRequested(task)));
    try f.scheduler.applyQueuedCancellations();
    try std.testing.expect(try f.scheduler.cancellationRequested(task));
    try std.testing.expectEqual(task, f.scheduler.takeRunnable().?);
    try f.scheduler.complete(task);
    try f.instances.collectRetired();
    try f.exec("old_count:set(888); alternate:set(29)");
    try f.clean();
    try f.exec("visible:set(true)");
    try f.build();
    try f.expect("initializations == 3 and counts.first() == 0");
    const remounted = (try f.snapshot.findPath("counters/first/counter")).id;
    try std.testing.expect(remounted != first_node.id);
    try f.exec("counts.first:set(6)");
    try f.build();
    try f.exec("replacement:set(true)");
    try f.build();
    try f.expect("initializations == 4 and counts.first() == 0 and counts.second() == 100");
    try std.testing.expect(remounted != (try f.snapshot.findPath("counters/first/counter")).id);
}

test "reused component declarations preserve committed props across failed updates" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\choose, bad, count = ouro.signal(false), ouro.signal(false), ouro.signal(0)
        \\renders = 0
        \\local View = ouro.stateful(function(props)
        \\  escaped = props
        \\  return function()
        \\    renders = renders + 1
        \\    return ouro.box {key='value', width=props.width + count()}
        \\  end
        \\end)
        \\local a = View {key='view', width=13}
        \\local b = View {key='view', width=31}
        \\function build()
        \\  local view = choose() and b or a
        \\  if bad() then
        \\    return ouro.row {key='root', view, ouro.box {key='dup'}, ouro.box {key='dup'}}
        \\  end
        \\  return ouro.row {key='root', view}
        \\end
    );
    try f.build();
    try f.exec("choose:set(true); bad:set(true)");
    try std.testing.expectError(error.DuplicateInstanceId, f.build());
    try f.expect("escaped.width == 13 and renders == 2");
    try f.exec("bad:set(false)");
    try f.build(); // Reuses the exact declaration from the failed transaction.
    try f.expect("escaped.width == 31 and renders == 3");
    try std.testing.expectEqual(@as(f32, 31), try f.width("root/view/value"));
    _ = try f.owners.markDirty(f.owner);
    try f.build(); // Clean declaration takes the no-update path.
    try f.expect("renders == 3");
    try f.exec("count:set(7)");
    try f.build(); // Same props must not hide a dirty component reader.
    try f.expect("renders == 4");
    try std.testing.expectEqual(@as(f32, 38), try f.width("root/view/value"));
}

test "host invalidation callback replacement and changed arguments outrank reader-only caching" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(counters);
    try f.buildArgs("build", &.{.{ .number = 320 }});
    try f.exec("counts.first:set(1)");
    _ = try f.owners.markDirty(f.owner);
    try f.buildArgs("build", &.{.{ .number = 480 }});
    try f.expect("root_renders == 2 and last_width == 480 and initializations == 2");
    try f.exec("counts.first:set(2)");
    _ = try f.owners.markDirty(f.owner);
    try f.buildArgs("build", &.{.{ .number = 480 }});
    try f.expect("root_renders == 3");
    try f.exec("counts.first:set(3); old_build = build; function build(w) return old_build(w + 1) end");
    try f.buildArgs("build", &.{.{ .number = 480 }});
    try f.expect("root_renders == 4 and last_width == 481");
}

test "failed component evaluation and reconcile roll back props output dependencies and new mounts" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\offset, mode, late = ouro.signal(3), ouro.signal(0), ouro.signal(7)
        \\initializations = 0
        \\Counter = ouro.stateful(function(props)
        \\  escaped = props
        \\  initializations = initializations + 1
        \\  local count = ouro.signal(10)
        \\  return function()
        \\    local children = { ouro.box { key = "value", width = count() + props.offset } }
        \\    if mode() == 1 then children[#children + 1] = ouro.box { key = "value", width = late() } end
        \\    if mode() == 2 then props.offset = 999 end
        \\    if mode() == 3 then count:set(999) end
        \\    if mode() == 4 then return false end
        \\    return ouro.column { key = "inner", children = children }
        \\  end
        \\end)
        \\function build() return Counter { key = "outer", offset = offset() } end
    );
    try f.exec("mode:set(4)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try f.expect("escaped.offset == 3");
    try f.exec("mode:set(0)");
    try f.build();
    try f.expect("initializations == 2");
    const original = (try f.snapshot.findPath("outer/inner/value")).id;
    try std.testing.expectEqual(@as(f32, 13), try f.width("outer/inner/value"));
    try f.exec("offset:set(20); mode:set(1)");
    try std.testing.expectError(error.DuplicateInstanceId, f.build());
    try f.expect("escaped.offset == 3 and initializations == 2");
    try std.testing.expectEqual(@as(f32, 13), try f.width("outer/inner/value"));
    try f.exec("mode:set(0)");
    try f.build();
    try std.testing.expectEqual(original, (try f.snapshot.findPath("outer/inner/value")).id);
    try std.testing.expectEqual(@as(f32, 30), try f.width("outer/inner/value"));
    try f.exec("late:set(81)");
    try f.clean();
    for ([_]u8{ 2, 3 }) |mode| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "mode:set({d})", .{mode});
        defer std.testing.allocator.free(source);
        try f.exec(source);
        try std.testing.expectError(error.LuaBuildFailed, f.build());
        try f.expect("escaped.offset == 20");
        try std.testing.expectEqual(@as(f32, 30), try f.width("outer/inner/value"));
        try f.exec("mode:set(0)");
        try f.build();
    }
    try f.expect("initializations == 2");
}

test "component children forward through read-only props without layout wrappers" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\size = ouro.signal(23)
        \\Forward = ouro.stateful(function(props)
        \\  return function() return ouro.row { key = "row", children = props.children } end
        \\end)
        \\function build()
        \\  return Forward { key = "forward", ouro.box { key = "child", width = size(), flex = 2 } }
        \\end
    );
    try f.build();
    try std.testing.expectEqual(@as(f32, 23), try f.width("forward/row/child"));
    try f.exec("size:set(47)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 47), try f.width("forward/row/child"));
    try std.testing.expectEqual(@as(usize, 4), f.instances.activeCount());
}

test "one Lua generation isolates identical component keys in distinct window registries" {
    const f = try Fixture.create();
    defer f.destroy();
    var other: owners_module.BuildOwners = undefined;
    try other.init(std.testing.allocator, &f.scheduler, f.scope, 1, 8);
    defer other.deinit();
    const owner = try other.mount(null, 1);
    defer {
        f.signals.disposeOwner(.{ .owners = &other, .handle = owner }) catch unreachable;
        f.ui.disposeOwner(&other, owner);
        other.retire(owner) catch unreachable;
        f.scheduler.applyQueuedCancellations() catch unreachable;
        other.collectRetired() catch unreachable;
    }
    try std.testing.expectEqual(f.owner, owner);
    try f.exec(
        \\states, runs, roots = {}, {}, { 0, 0 }
        \\shared = ouro.signal(7)
        \\Counter = ouro.stateful(function(props)
        \\  local count = ouro.signal(props.initial)
        \\  states[props.index] = count
        \\  return function()
        \\    runs[props.index] = (runs[props.index] or 0) + 1
        \\    return ouro.box { key = "value", width = count() + shared() }
        \\  end
        \\end)
        \\function build() roots[1] = roots[1] + 1; return Counter { key = "same", index = 1, initial = 0 } end
        \\function second() roots[2] = roots[2] + 1; return Counter { key = "same", index = 2, initial = 100 } end
    );
    try f.build();
    var cycle = other.beginCycle();
    const first = (try cycle.take()).?;
    const descriptors = try f.ui.build(&other, first, "second", &.{});
    try std.testing.expectEqual(@as(?f32, 107), descriptors[2].object.box.width);
    try f.ui.commitDependencies(&other, first);
    try other.complete(first);
    try f.exec("states[1]:set(2)");
    try f.build();
    try f.expect("runs[1] == 2 and runs[2] == 1 and roots[1] == 1 and roots[2] == 1");
    var clean = other.beginCycle();
    try std.testing.expect((try clean.take()) == null);
    try f.exec("shared:set(13)");
    try f.build();
    var update = other.beginCycle();
    const work = (try update.take()).?;
    const changed = try f.ui.build(&other, work, "second", &.{});
    try std.testing.expectEqual(@as(?f32, 113), changed[2].object.box.width);
    try f.ui.commitDependencies(&other, work);
    try other.complete(work);
    try f.expect("runs[1] == 3 and runs[2] == 2 and roots[1] == 1 and roots[2] == 1");
    try std.testing.expectEqual(@as(f32, 15), try f.width("same/value"));
}

test "nil component output retains state and callable non-function initializers are rejected" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\inits = 0
        \\visible = ouro.signal(true)
        \\Counter = ouro.stateful(function(props)
        \\  inits = inits + 1
        \\  local count = ouro.signal(31)
        \\  state = count
        \\  return function()
        \\    if visible() then return ouro.box { key = "value", width = count() } end
        \\  end
        \\end)
        \\function build() return Counter { key = "maybe" } end
    );
    try f.build();
    try f.exec("visible:set(false)");
    try f.build();
    try std.testing.expectEqual(@as(usize, 2), f.instances.activeCount());
    try f.scheduler.applyQueuedCancellations();
    try f.instances.collectRetired();
    try f.exec("state:set(47)");
    try f.clean();
    try f.exec("visible:set(true)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 47), try f.width("maybe/value"));
    try f.expect("inits == 1");
    try f.exec(
        \\Bad = ouro.stateful(function() return ouro.signal(ouro.box { key = "bad" }) end)
        \\function build() return Bad { key = "bad" } end
    );
    _ = try f.owners.markDirty(f.owner);
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(@as(f32, 47), try f.width("maybe/value"));
}

test "prepared component descriptions remain pinned when the same mount rebuilds" {
    const PreparedBuild = @import("prepared_build.zig").PreparedBuild;
    const f = try Fixture.create();
    defer f.destroy();
    c.lua_createtable(f.state, 0, 2);
    c.lua_createtable(f.state, 0, 1);
    _ = c.lua_pushstring(f.state, "v");
    c.lua_setfield(f.state, -2, "__mode");
    _ = c.lua_setmetatable(f.state, -2);
    c.lua_setglobal(f.state, "weak");
    try f.exec(
        \\size = ouro.signal(23)
        \\Component = ouro.stateful(function()
        \\  return function()
        \\    local output = ouro.box { key = "value", width = size() }
        \\    weak[size()] = output
        \\    return output
        \\  end
        \\end)
        \\function build() return Component { key = "component" } end
    );
    try f.build();
    var prepared: PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, f.state, null, 64, 4096);
    defer prepared.deinit();
    try f.ui.capturePrepared(&prepared, f.ui.storage[0..f.ui.count]);
    try f.exec("size:set(47)");
    try f.build();
    _ = c.lua_gc(f.state, 2);
    try f.expect("weak[23] ~= nil and weak[47] ~= nil");
    try std.testing.expectEqual(@as(?f32, 23), prepared.descriptors()[2].object.box.width);
    prepared.reset();
    _ = c.lua_gc(f.state, 2);
    try f.expect("weak[23] == nil and weak[47] ~= nil");
}

test "prepared stateless output survives later expansions and collection" {
    const f = try Fixture.create();
    defer f.destroy();
    c.lua_createtable(f.state, 0, 2);
    c.lua_createtable(f.state, 0, 1);
    _ = c.lua_pushstring(f.state, "v");
    c.lua_setfield(f.state, -2, "__mode");
    _ = c.lua_setmetatable(f.state, -2);
    c.lua_setglobal(f.state, "weak");
    try f.exec(
        \\size=ouro.signal(19)
        \\local View=ouro.stateless(function(p)
        \\  local result=ouro.box {key=p.key, width=size()}
        \\  weak[size()]=result
        \\  return result
        \\end)
        \\function build() return View {key='view'} end
    );
    try f.build();
    var prepared: @import("prepared_build.zig").PreparedBuild = undefined;
    try prepared.init(std.testing.allocator, f.state, null, 64, 4096);
    defer prepared.deinit();
    try f.ui.capturePrepared(&prepared, f.ui.storage[0..f.ui.count]);
    try f.exec("size:set(43)");
    try f.build();
    _ = c.lua_gc(f.state, 2);
    try f.expect("weak[19] ~= nil and weak[43] ~= nil");
    try std.testing.expectEqual(@as(?f32, 19), prepared.descriptors()[2].object.box.width);
    prepared.reset();
    _ = c.lua_gc(f.state, 2);
    try f.expect("weak[19] == nil and weak[43] ~= nil");
}

test "component boundaries retain native descendants and preserve nested composition dependencies" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\a,b,choose,tick=ouro.signal(17),ouro.signal(39),ouro.signal(true),ouro.signal(3)
        \\inits,expansions=0,0
        \\local View=ouro.stateless(function()
        \\  expansions=expansions+1
        \\  return ouro.box {key='value',width=choose() and a() or b()}
        \\end)
        \\local Child=ouro.stateful(function()
        \\  inits=inits+1
        \\  return function() return View {} end
        \\end)
        \\local Parent=ouro.stateful(function()
        \\  return function() return ouro.column {key='inside',Child {key='child'}} end
        \\end)
        \\local Other=ouro.stateful(function()
        \\  return function() return ouro.box {key='tick',width=tick()} end
        \\end)
        \\function build() return ouro.row {key='root',Parent {key='parent'},Other {key='other'}} end
    );
    try f.build();
    const path = "root/parent/inside/child/value";
    const value_id = (try f.snapshot.findPath(path)).id;
    const handle = f.instances.handleForId(value_id).?;
    const render = try f.instances.renderObject(handle);
    try f.instances.bumpStateRevision(handle);
    try f.exec("tick:set(7)");
    try f.build();
    try std.testing.expectEqual(@as(usize, 5), f.ui.count); // Root chrome, row, retained parent, changed sibling.
    try std.testing.expect(f.descriptors[3].retain_subtree);
    try std.testing.expect(f.instances.isRetained(handle));
    try std.testing.expectEqual(render, try f.instances.renderObject(handle));
    try std.testing.expectEqual(@as(u64, 1), try f.instances.stateRevision(handle));
    try std.testing.expectEqual(@as(f32, 17), try f.width(path));
    try f.expect("inits==1 and expansions==1");
    // A nested stateless reader must still invalidate through the retained parent.
    try f.exec("a:set(23)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 23), try f.width(path));
    try f.expect("inits==1 and expansions==2");
    try f.exec("choose:set(false)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 39), try f.width(path));
    try f.exec("a:set(51)");
    try f.clean();
    try f.exec("tick:set(11)");
    try f.build();
    try f.exec("b:set(43)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 43), try f.width(path));
    try std.testing.expectEqual(handle, f.instances.handleForId(value_id).?);
    try f.expect("inits==1 and expansions==4");
}

test "component boundary context changes relower clean compositions without remounting" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\tick=ouro.signal(0)
        \\local Styled=ouro.stateless(function(_,_,theme)
        \\ return ouro.box {key='value',width=theme.controls.height}
        \\end)
        \\local Stable=ouro.stateful(function() return function() return Styled {} end end)
        \\local Other=ouro.stateful(function() return function() return ouro.box {key='value',width=7+tick()} end end)
        \\function build() return ouro.row {key='root',Stable {key='stable'},Other {key='other'}} end
    );
    try f.build();
    const id = (try f.snapshot.findPath("root/stable/value")).id;
    const handle = f.instances.handleForId(id).?;
    try f.exec("tick:set(1)");
    try f.build();
    try std.testing.expect(f.instances.isRetained(handle));
    f.ui.widget_theme.?.controls.height = 53;
    try f.exec("tick:set(2)");
    try f.build();
    try std.testing.expect(!f.instances.isRetained(handle));
    try std.testing.expectEqual(@as(f32, 53), try f.width("root/stable/value"));
    try std.testing.expectEqual(handle, f.instances.handleForId(id).?);
}

test "component boundary proposals roll back when a dirty sibling fails validation" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\value,bad,tick=ouro.signal(13),ouro.signal(false),ouro.signal(2)
        \\local Good=ouro.stateful(function()
        \\  return function() return ouro.box {key='value',width=value()} end
        \\end)
        \\local Bad=ouro.stateful(function()
        \\  return function() return ouro.box {key='value',width=bad() and -1 or tick()} end
        \\end)
        \\function build() return ouro.row {key='root',Good {key='good'},Bad {key='bad'}} end
    );
    try f.build();
    try f.exec("bad:set(true)");
    try std.testing.expectError(error.LuaBuildFailed, f.build());
    try std.testing.expectEqual(@as(f32, 13), try f.width("root/good/value"));
    try f.exec("bad:set(false);value:set(29)");
    try f.build();
    try std.testing.expectEqual(@as(f32, 29), try f.width("root/good/value"));
    try f.exec("tick:set(5)");
    try f.build();
    try std.testing.expect(f.descriptors[3].retain_subtree);
    try std.testing.expectEqual(@as(f32, 29), try f.width("root/good/value"));
}

test "signal dirty scans track live extent through holes rollback and retirement" {
    const OwnerRef = @import("signals.zig").OwnerRef;
    const SignalHandle = @import("signals.zig").SignalHandle;
    const subscribe = struct {
        fn run(signals: *Signals, owner: OwnerRef, reader: u64, signal: ?SignalHandle) !void {
            try signals.beginEvaluation(owner, 1);
            try signals.selectReader(reader);
            if (signal) |handle| try signals.readExternal(handle);
            try signals.finishEvaluation(owner, 1);
            try signals.commit(owner, 1);
        }
    }.run;
    const f = try Fixture.create();
    defer f.destroy();
    const first: OwnerRef = .{ .owners = &f.owners, .handle = f.owner };
    const second: OwnerRef = .{ .owners = &f.owners, .handle = try f.owners.mount(null, 2) };
    defer {
        f.signals.disposeOwner(second) catch unreachable;
        if (f.owners.isActive(second.handle)) f.owners.retire(second.handle) catch unreachable;
        f.scheduler.applyQueuedCancellations() catch unreachable;
        f.owners.collectRetired() catch unreachable;
    }
    const a = try f.signals.createExternal();
    defer f.signals.releaseExternal(a);
    const b = try f.signals.createExternal();
    defer f.signals.releaseExternal(b);
    const c_signal = try f.signals.createExternal();
    defer f.signals.releaseExternal(c_signal);

    try subscribe(&f.signals, first, 11, a);
    try subscribe(&f.signals, first, 22, b);
    try subscribe(&f.signals, second, 33, c_signal);
    try std.testing.expectEqual(@as(usize, 3), f.signals.edge_extent);
    try f.signals.publishExternal(a);
    try f.signals.publishExternal(c_signal);
    try f.signals.beginEvaluation(first, 2);
    try std.testing.expect(f.signals.readerDirty(null));
    try std.testing.expect(f.signals.readerDirty(11));
    try std.testing.expect(!f.signals.readerDirty(22));
    try std.testing.expect(!f.signals.readerDirty(33)); // Other owner's dirty edge.
    try f.signals.selectReader(44);
    try f.signals.readExternal(c_signal);
    try f.signals.finishEvaluation(first, 2);
    try f.signals.rollback(first, 2);
    try std.testing.expectEqual(@as(usize, 3), f.signals.edge_extent);

    // An interior hole must not hide a later subscription or change its slot.
    f.signals.releaseExternal(b);
    try std.testing.expectEqual(@as(usize, 3), f.signals.edge_extent);
    try f.signals.beginEvaluation(second, 2);
    try std.testing.expect(f.signals.readerDirty(33));
    try std.testing.expect(!f.signals.readerDirty(11));
    try f.signals.abortEvaluation(second, 2);
    try subscribe(&f.signals, first, 44, c_signal);
    try std.testing.expectEqual(@as(usize, 3), f.signals.edge_extent);
    try std.testing.expectEqual(@as(u64, 44), f.signals.edges[1].reader);
    try std.testing.expectEqual(@as(u64, 33), f.signals.edges[2].reader);
    try f.signals.disposeOwner(second);
    try std.testing.expectEqual(@as(usize, 2), f.signals.edge_extent);

    // Empty committed reads trim the suffix; rollback above did not.
    try subscribe(&f.signals, first, 44, null);
    try std.testing.expectEqual(@as(usize, 1), f.signals.edge_extent);
    f.signals.releaseExternal(a);
    try std.testing.expectEqual(@as(usize, 0), f.signals.edge_extent);
    try subscribe(&f.signals, second, 55, c_signal);
    try std.testing.expectEqual(@as(usize, 1), f.signals.edge_extent);
    try f.owners.retire(second.handle);
    try f.signals.publishExternal(c_signal); // Stale owner cleanup also trims.
    try std.testing.expectEqual(@as(usize, 0), f.signals.edge_extent);
    try f.signals.beginEvaluation(first, 3);
    try std.testing.expect(!f.signals.readerDirty(null));
    try f.signals.abortEvaluation(first, 3);
}

test "stateful unmount hooks run once when an instance leaves, never for survivors" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\left = {}
        \\local function tracked(kind)
        \\  return ouro.stateful(function(props)
        \\    return function() return ouro.box {key='value', width=1} end,
        \\      function() left[#left + 1] = kind .. ':' .. props.label end
        \\  end)
        \\end
        \\A, B = tracked('a'), tracked('b')
        \\show, swap, extra, bad = ouro.signal(true), ouro.signal(false), ouro.signal(false), ouro.signal(false)
        \\function build()
        \\  return ouro.row {key='root', A {key='kept', label='kept'},
        \\    show() and (swap() and B or A) {key='item', label='item'} or nil,
        \\    extra() and A {key='extra', label='extra'} or nil,
        \\    bad() and ouro.box {key='dup'} or nil, bad() and ouro.box {key='dup'} or nil}
        \\end
        \\function seen() local out = '' for i = 1, #left do out = out .. (i > 1 and ',' or '') .. left[i] end return out end
    );
    try f.build();
    try f.expect("seen() == ''");
    try f.exec("show:set(false)");
    try f.build();
    try f.expect("seen() == 'a:item'");
    // Remounting creates a new instance; nothing else leaves.
    try f.exec("show:set(true)");
    try f.build();
    try f.expect("seen() == 'a:item'");
    // Reusing the key with another definition replaces the instance.
    try f.exec("swap:set(true)");
    try f.build();
    try f.expect("seen() == 'a:item,a:item'");
    // An instance first initialized by a failed build never mounted: its hook
    // runs on rollback, and the committed instances are untouched.
    try f.exec("extra:set(true); bad:set(true)");
    try std.testing.expectError(error.DuplicateInstanceId, f.build());
    try f.expect("seen() == 'a:item,a:item,a:extra'");
    try f.exec("extra:set(false); bad:set(false)");
    try f.build();
    try f.expect("seen() == 'a:item,a:item,a:extra'");
    // Disposing the owner (window teardown) unmounts what is left, once.
    f.ui.disposeOwner(&f.owners, f.owner);
    try f.expect("seen() == 'a:item,a:item,a:extra,a:kept,b:item' or seen() == 'a:item,a:item,a:extra,b:item,a:kept'");
    f.ui.disposeOwner(&f.owners, f.owner);
    try f.expect("#left == 5");
}

test "a failing unmount hook is reported and does not break the commit" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\show = ouro.signal(true)
        \\local Broken = ouro.stateful(function()
        \\  return function() return ouro.box {key='value'} end, function() error('cleanup failed') end
        \\end)
        \\function build() return ouro.row {key='root', show() and Broken {key='broken'} or nil} end
    );
    try f.build();
    try f.exec("show:set(false)");
    try f.build();
    try f.exec("show:set(true)");
    try f.build();
}

test "one build may read and subscribe to more signals than the initial capacities" {
    const f = try Fixture.create();
    defer f.destroy();
    try f.exec(
        \\values = {}
        \\for i = 1, 300 do values[i] = ouro.signal(1) end
        \\builds = 0
        \\function build()
        \\  builds = builds + 1
        \\  local sum = 0
        \\  for i = 1, #values do sum = sum + values[i]() end
        \\  return ouro.box {key='root', width=sum}
        \\end
    );
    try f.build();
    try f.expect("builds == 1");
    // Every one of the 300 reads became a subscription.
    try f.exec("values[300]:set(2)");
    try f.build();
    try f.expect("builds == 2");
    try f.exec("values[1]:set(2)");
    try f.build();
    try f.expect("builds == 3");
}
