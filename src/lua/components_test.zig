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
        self.ui.enableDeclarativeWidgets(@import("../design/root.zig").tokens.light);
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
    \\Counter, Other = ouro.component(initialize), ouro.component(initialize)
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
        \\Counter = ouro.component(function(props)
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
        \\Forward = ouro.component(function(props)
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
        \\Counter = ouro.component(function(props)
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
        \\Counter = ouro.component(function(props)
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
        \\Bad = ouro.component(function() return ouro.signal(ouro.box { key = "bad" }) end)
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
        \\Component = ouro.component(function()
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
