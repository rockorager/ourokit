const std = @import("std");
const ouro = @import("ourokit");
const paths = @import("native_plugin_paths");
const abi = ouro.native.abi;

const Harness = struct {
    loop: ouro.loop.Loop,
    scheduler: ouro.task.Scheduler,
    vm: ouro.lua.Vm,
    signals: ouro.lua.Signals,
    registry: ouro.native.Registry,

    fn init(self: *Harness, modules: []const ouro.native.Module) !void {
        try self.loop.init(std.testing.allocator, 8, 4);
        errdefer self.loop.deinit();
        try self.scheduler.init(std.testing.allocator, 8, 4, 4);
        errdefer self.scheduler.deinit();
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        errdefer self.vm.deinit();
        try self.signals.initWithApi(std.testing.allocator, self.vm.state, 16, 16, 16, self.vm.apiReference());
        errdefer self.signals.deinit();
        try self.registry.init(std.testing.allocator, &self.vm, &self.signals, modules);
    }

    fn deinit(self: *Harness) void {
        self.vm.deinit();
        self.registry.deinit();
        self.signals.deinit();
        self.scheduler.deinit();
        self.loop.deinit();
    }

    fn run(self: *Harness, source: []const u8) !void {
        _ = try self.vm.spawnApplication(source);
        while (self.scheduler.takeRunnable()) |handle| _ = try self.vm.resumeRunnable(handle);
        try std.testing.expect(self.vm.globalBoolean("ok"));
    }
};

fn openExamples() !ouro.native.Libraries {
    return ouro.native.Libraries.open(std.testing.allocator, &.{
        .{ .name = "counter", .path = paths.counter },
        .{ .name = "echo", .path = paths.echo },
    });
}

test "native C and Zig shared libraries exchange scalars and length-delimited strings" {
    var libraries = try openExamples();
    defer libraries.deinit();
    var host: Harness = undefined;
    try host.init(libraries.modules);
    defer host.deinit();
    try host.run(
        \\local counter, echo = require('counter'), require('echo').echo
        \\local nul = 'a\0bc'
        \\ok = counter.get() == 0 and counter.set(37) == 37 and counter.get() == 37
        \\  and echo(nul) == nul and #echo(nul) == 4 and echo('') == ''
        \\  and echo(nil) == nil and echo(false) == false and echo(true) == true
        \\  and echo(-9007199254740993) == -9007199254740993 and echo(-3.125) == -3.125
        \\  and require('counter') == counter
    );
    try host.run(
        \\local counter = require('counter')
        \\local good, message = pcall(counter.set, 101)
        \\local bad_type = pcall(require('echo').echo, {})
        \\ok = not good and message == 'counter.set expects an integer from 0 to 100'
        \\  and not bad_type and counter.get() == 37
    );
}

test "native signal invalidates only subscribed owners and rejects mutation during builds" {
    var libraries = try openExamples();
    defer libraries.deinit();
    var host: Harness = undefined;
    try host.init(libraries.modules);
    defer host.deinit();
    var owners: ouro.ui.instance.BuildOwners = undefined;
    try owners.init(std.testing.allocator, &host.scheduler, host.scheduler.application_scope, 2, 4);
    defer owners.deinit();
    const watched = try owners.mount(null, 11);
    const unwatched = try owners.mount(null, 23);
    const owner: ouro.lua.SignalOwnerRef = .{ .owners = &owners, .handle = watched };
    defer {
        host.signals.disposeOwner(owner) catch unreachable;
        owners.retire(watched) catch unreachable;
        owners.retire(unwatched) catch unreachable;
        host.scheduler.applyQueuedCancellations() catch unreachable;
        owners.collectRetired() catch unreachable;
    }
    var initial = owners.beginCycle();
    while (try initial.take()) |work| try owners.complete(work);
    try host.signals.beginEvaluation(owner, 1);
    try host.run(
        \\local counter = require('counter')
        \\local good = pcall(counter.set, 73)
        \\ok = not good and counter.get() == 0
    );
    try host.signals.finishEvaluation(owner, 1);
    try host.signals.commit(owner, 1);
    try host.run("ok = require('counter').set(19) == 19");
    var changed = owners.beginCycle();
    const work = (try changed.take()).?;
    try std.testing.expectEqual(watched, work.owner);
    try owners.complete(work);
    try std.testing.expectEqual(null, try changed.take());
    try host.run("ok = require('counter').set(19) == 19");
    var unchanged = owners.beginCycle();
    try std.testing.expectEqual(null, try unchanged.take());
}

test "native contexts remain independent while reload generations overlap" {
    var libraries = try openExamples();
    defer libraries.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "app.lua" });
    defer std.testing.allocator.free(path);
    const application =
        \\return require('ouro').app { id = 'dev.ouro.native-test', windows = {
        \\  require('ouro').window { id='main', title=tostring(require('counter').get()), content=function() end }
        \\} }
    ;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "app.lua", .data = "require('counter').set(61); " ++ application });
    var provider = try ouro.bundle.SourceProvider.initDisk(std.testing.allocator, path);
    defer provider.deinit();
    var loop: ouro.loop.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var scheduler: ouro.task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 8, 4, 4);
    defer scheduler.deinit();
    const config: @FieldType(ouro.app.SourceReload, "config") = .{ .node_capacity = 8, .native_modules = libraries.modules };
    const initial = try ouro.app.SourceGeneration.create(std.testing.allocator, &scheduler, &loop, try provider.snapshot(std.testing.io, std.testing.allocator), null, config, null);
    var reload: ouro.app.SourceReload = undefined;
    reload.init(std.testing.allocator, std.testing.io, &provider, &scheduler, &loop, null, config, initial);
    defer reload.deinit();
    try std.testing.expectEqualStrings("61", initial.application.windows[0].declaration.toplevel.title);

    // A candidate can mutate its own native state and then fail. The active
    // module must not be affected, nor retain any failed-candidate closures.
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "app.lua", .data = "require('counter').set(7); error('reject candidate')" });
    try std.testing.expectError(error.LuaApplicationFailed, reload.prepare());
    _ = try initial.vm.spawnApplication("ok = require('counter').get() == 61");
    while (scheduler.takeRunnable()) |handle| _ = try initial.vm.resumeRunnable(handle);
    try std.testing.expect(initial.vm.globalBoolean("ok"));

    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "app.lua", .data = "assert(require('counter').get() == 0); require('counter').set(23); " ++ application });
    try reload.prepare();
    const commit = reload.commit();
    try std.testing.expectEqual(2, commit.generation);
    try std.testing.expectEqualStrings("23", reload.active().application.windows[0].declaration.toplevel.title);
    try reload.beginRetirement();
    while (scheduler.takeRunnable()) |handle| _ = try reload.resumeRunnable(handle);
    reload.markRetiringNativeStateDetached(commit.retired);
    _ = reload.collectRetired();
    try std.testing.expectEqual(0, reload.retiringCount());
    _ = try reload.active().vm.spawnApplication("ok = require('counter').set(24) == 24");
    while (scheduler.takeRunnable()) |handle| _ = try reload.resumeRunnable(handle);
    try std.testing.expect(reload.active().vm.globalBoolean("ok"));
}

test "native registrations survive disk loader freeze without enabling arbitrary dlopen" {
    var libraries = try openExamples();
    defer libraries.deinit();
    var host: Harness = undefined;
    try host.init(libraries.modules);
    defer host.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var loader: ouro.lua.ModuleLoader = undefined;
    try loader.init(std.testing.allocator, &host.vm, &host.loop, temp.dir.handle, 2);
    defer loader.deinit();
    loader.freeze();
    try host.run(
        \\local counter = require('counter')
        \\local missing = pcall(require, 'not_registered')
        \\ok = counter.set(12) == 12 and not missing and package == nil
    );
}

const Lifecycle = struct {
    var alive: usize = 0;
    fn destroy(_: ?*anyopaque) callconv(.c) void {
        alive -= 1;
    }
    fn initialize(api: [*c]const abi.ouro_api_v1, context: ?*abi.ouro_context) callconv(.c) i32 {
        if (api.*.set_destroy.?(context, destroy, null) != abi.OURO_OK) return abi.OURO_ERROR;
        alive += 1;
        return abi.OURO_ERROR;
    }
};

test "native ABI validation and partial initialization clean up without publishing modules" {
    var host: Harness = undefined;
    try host.init(&.{});
    defer host.deinit();
    var registry: ouro.native.Registry = undefined;
    var descriptor: abi.ouro_plugin_descriptor = .{
        .abi_version = 999,
        .struct_size = @sizeOf(abi.ouro_plugin_descriptor),
        .initialize = Lifecycle.initialize,
    };
    const modules = [_]ouro.native.Module{.{ .name = "broken", .descriptor = &descriptor }};
    try std.testing.expectError(error.UnsupportedNativePluginAbi, registry.init(std.testing.allocator, &host.vm, &host.signals, &modules));
    descriptor.abi_version = abi.OURO_ABI_VERSION;
    descriptor.struct_size = 8;
    try std.testing.expectError(error.InvalidNativePluginDescriptor, registry.init(std.testing.allocator, &host.vm, &host.signals, &modules));
    descriptor.struct_size = @sizeOf(abi.ouro_plugin_descriptor);
    try std.testing.expectError(error.NativePluginInitializationFailed, registry.init(std.testing.allocator, &host.vm, &host.signals, &modules));
    try std.testing.expectEqual(0, Lifecycle.alive);
    try std.testing.expectEqual(0, host.vm.native_modules.len);
    try std.testing.expectError(error.ReservedNativeModule, registry.init(std.testing.allocator, &host.vm, &host.signals, &.{.{ .name = "ouro", .descriptor = &descriptor }}));
    try std.testing.expectError(error.DuplicateNativeModule, registry.init(std.testing.allocator, &host.vm, &host.signals, &.{ modules[0], modules[0] }));
}

test "linked native callbacks copy temporary results and unwind normally before Lua errors" {
    const Plugin = struct {
        var returned: usize = 0;
        var destroyed: usize = 0;

        fn copy(_: ?*anyopaque, api: [*c]const abi.ouro_api_v1, _: ?*abi.ouro_context, call: ?*abi.ouro_call) callconv(.c) i32 {
            var bytes = [_]u8{ 'A', 0, 'Z', '!' };
            defer {
                @memset(&bytes, '?');
                returned += 1;
            }
            const value: abi.ouro_value = .{ .type = abi.OURO_STRING, .bytes = &bytes, .length = bytes.len };
            return api.*.set_result.?(call, &value);
        }

        fn fail(_: ?*anyopaque, api: [*c]const abi.ouro_api_v1, _: ?*abi.ouro_context, call: ?*abi.ouro_call) callconv(.c) i32 {
            var bytes = [_]u8{ 'B', 0, 'X', '!' };
            defer {
                @memset(&bytes, '?');
                returned += 1;
            }
            _ = api.*.set_error.?(call, &bytes, bytes.len);
            return abi.OURO_ERROR;
        }

        fn destroy(_: ?*anyopaque) callconv(.c) void {
            destroyed += 1;
        }

        fn initialize(api: [*c]const abi.ouro_api_v1, context: ?*abi.ouro_context) callconv(.c) i32 {
            if (api.*.set_destroy.?(context, destroy, null) != abi.OURO_OK) return abi.OURO_ERROR;
            if (api.*.register_function.?(context, "copy", 4, 0, copy, null) != abi.OURO_OK) return abi.OURO_ERROR;
            return api.*.register_function.?(context, "fail", 4, 0, fail, null);
        }
    };
    const descriptor: abi.ouro_plugin_descriptor = .{ .abi_version = abi.OURO_ABI_VERSION, .struct_size = @sizeOf(abi.ouro_plugin_descriptor), .initialize = Plugin.initialize };
    {
        var host: Harness = undefined;
        try host.init(&.{.{ .name = "linked", .descriptor = &descriptor }});
        defer host.deinit();
        try host.run(
            \\local linked = require('linked')
            \\local value = linked.copy()
            \\local good, message = pcall(linked.fail)
            \\ok = value == 'A\0Z!' and not good and message == 'B\0X!'
        );
        try std.testing.expectEqual(2, Plugin.returned);
        try std.testing.expectEqual(0, Plugin.destroyed);
    }
    try std.testing.expectEqual(1, Plugin.destroyed);
}

test "native drawing signal rebuilds a canvas and retained paint outlives Lua and the library" {
    const allocator = std.testing.allocator;
    var tree: ouro.ui.render_object.Tree = undefined;
    try tree.init(allocator, 1);
    defer tree.deinit();
    var leaf: ouro.ui.render_object.NodeHandle = undefined;
    {
        var libraries = try openExamples();
        defer libraries.deinit();
        var host: Harness = undefined;
        try host.init(libraries.modules);
        defer host.deinit();
        var owners: ouro.ui.instance.BuildOwners = undefined;
        try owners.init(allocator, &host.scheduler, host.scheduler.application_scope, 1, 4);
        defer owners.deinit();
        const owner = try owners.mount(null, 41);
        var descriptors: [8]ouro.ui.instance.Descriptor = undefined;
        var semantics: [8]ouro.ui.semantics.Descriptor = undefined;
        var build: ouro.lua.UiBuild = undefined;
        try build.initWithApi(host.vm.state, &descriptors, host.vm.apiReference());
        build.enableDeclarativeWidgets(ouro.design.tokens.light);
        build.attachSignals(&host.signals);
        try build.attachSemantics(&semantics);
        defer {
            build.rollbackHandlers();
            build.disposeOwner(&owners, owner);
            host.signals.disposeOwner(.{ .owners = &owners, .handle = owner }) catch unreachable;
            owners.retire(owner) catch unreachable;
            host.scheduler.applyQueuedCancellations() catch unreachable;
            owners.collectRetired() catch unreachable;
        }
        var prepared: ouro.lua.PreparedBuild = undefined;
        try prepared.init(allocator, host.vm.state, null, 8, 128);
        defer prepared.deinit();
        try host.run(
            \\local ouro, counter = require('ouro'), require('counter')
            \\local Meter = ouro.component(function()
            \\  return function() return ouro.canvas { key='meter', drawing=counter.paint(), alt='Native level' } end
            \\end)
            \\function build() return Meter { key='component' } end
            \\function bad()
            \\  return ouro.row { key='row', ouro.canvas { key='good', drawing=counter.paint() },
            \\    ouro.canvas { key='bad', drawing={} } }
            \\end
            \\ok = true
        );
        var cycle = owners.beginCycle();
        var work = (try cycle.take()).?;
        const initial = try build.build(&owners, work, "build", &.{});
        try std.testing.expectEqual(3, initial.len);
        const original = initial[2].object.canvas;
        try std.testing.expectEqual(@as(f32, 0), original.rectangles[1].bounds.width);
        try std.testing.expectEqualStrings("Native level", build.semanticDescriptors()[1].label);
        leaf = try tree.create(initial[2].object);
        try build.capturePrepared(&prepared, initial);
        try build.commitDependencies(&owners, work);
        try owners.complete(work);
        prepared.reset();
        _ = try tree.layout(leaf, .{ .max_width = 250, .max_height = 29 });
        try std.testing.expectEqual(ouro.core.SizeF{ .width = 250, .height = 29 }, try tree.nodeSize(leaf));

        // Only paint() read the dependency: no scalar getter masks subscription.
        try host.run("ok = require('counter').set(37) == 37");
        cycle = owners.beginCycle();
        work = (try cycle.take()).?;
        const changed = try build.build(&owners, work, "build", &.{});
        try std.testing.expectApproxEqAbs(@as(f32, 108.04), changed[2].object.canvas.rectangles[1].bounds.width, 0.001);
        try std.testing.expectEqual(@as(f32, 0), original.rectangles[1].bounds.width);
        try build.capturePrepared(&prepared, changed);
        try tree.update(leaf, prepared.descriptors()[2].object);
        try std.testing.expect(!try tree.layoutDirty(leaf));
        try std.testing.expect(try tree.paintDirty(leaf));
        try build.commitDependencies(&owners, work);
        try owners.complete(work);
        prepared.reset();

        try host.run("ok = require('counter').set(61) == 61");
        cycle = owners.beginCycle();
        work = (try cycle.take()).?;
        try std.testing.expectError(error.LuaBuildFailed, build.build(&owners, work, "bad", &.{}));
        try std.testing.expect(!build.drawings_staged);
        // Failed lowerings must not replace the previously committed picture.
        try std.testing.expectApproxEqAbs(@as(f32, 108.04), (try tree.objectAt(leaf)).canvas.rectangles[1].bounds.width, 0.001);
        try owners.complete(work);
    }
    // No VM, plugin context, or mapped plugin code remains.
    var commands: [5]ouro.scene.Command = undefined;
    var builder = try ouro.ui.render_object.Builder.init(&commands, 2);
    try tree.buildScene(leaf, &builder);
    try builder.displayList().validate();
    try std.testing.expectEqual(ouro.core.RectI{ .x = 0, .y = 0, .width = 500, .height = 58 }, commands[0].push_clip_rect);
    try std.testing.expectEqual(ouro.core.RectI{ .x = 8, .y = 8, .width = 217, .height = 48 }, commands[2].decorated_rectangle.bounds);
    var frame = try ouro.scene.Frame.init(allocator, builder.displayList().commands, .full);
    defer frame.deinit();
    try tree.destroy(leaf);
    @memset(&commands, .pop_clip);
    try frame.displayList().validate();
    try std.testing.expectEqual(ouro.core.Color.rgba(61, 190, 160, 255), frame.displayList().commands[2].decorated_rectangle.background.?);
}

test "native drawing results validate input and replace scalar and drawing ownership" {
    const Plugin = struct {
        fn exercise(_: ?*anyopaque, api: [*c]const abi.ouro_api_v1, _: ?*abi.ouro_context, call: ?*abi.ouro_call) callconv(.c) i32 {
            const value: abi.ouro_value = .{ .type = abi.OURO_STRING, .bytes = "kept", .length = 4 };
            if (api.*.set_result.?(call, &value) != abi.OURO_OK) return abi.OURO_ERROR;
            if (api.*.set_drawing_result.?(call, 1, 1, null, 1) != abi.OURO_ERROR or
                api.*.set_drawing_result.?(call, 1, 1, null, 4097) != abi.OURO_ERROR or
                api.*.set_drawing_result.?(call, -1, 1, null, 0) != abi.OURO_ERROR or
                api.*.set_drawing_result.?(call, 1, std.math.nan(f32), null, 0) != abi.OURO_ERROR) return abi.OURO_ERROR;
            var mode: abi.ouro_value = undefined;
            if (api.*.argument.?(call, 0, &mode) != abi.OURO_OK) return abi.OURO_ERROR;
            if (mode.integer == 0) return abi.OURO_OK; // Failed setters preserve the string.
            if (api.*.set_drawing_result.?(call, 17, 9, null, 0) != abi.OURO_OK) return abi.OURO_ERROR;
            if (api.*.set_drawing_result.?(call, 31, 7, null, 0) != abi.OURO_OK) return abi.OURO_ERROR;
            if (mode.integer == 1) return api.*.set_result.?(call, &value);
            if (mode.integer == 2) return abi.OURO_OK;
            return abi.OURO_ERROR; // Failed callbacks free an unpublished drawing.
        }
        fn initialize(api: [*c]const abi.ouro_api_v1, context: ?*abi.ouro_context) callconv(.c) i32 {
            return api.*.register_function.?(context, "exercise", 8, 0, exercise, null);
        }
    };
    const descriptor: abi.ouro_plugin_descriptor = .{ .abi_version = abi.OURO_ABI_VERSION, .struct_size = @sizeOf(abi.ouro_plugin_descriptor), .initialize = Plugin.initialize };
    var host: Harness = undefined;
    try host.init(&.{.{ .name = "drawing", .descriptor = &descriptor }});
    defer host.deinit();
    try host.run(
        \\local exercise = require('drawing').exercise
        \\ok = exercise(0) == 'kept' and exercise(1) == 'kept'
        \\  and type(exercise(2)) == 'userdata' and not pcall(exercise, 3)
    );
}
