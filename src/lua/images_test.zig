const std = @import("std");
const c = @import("c.zig");
const UiBuild = @import("ui_build.zig").UiBuild;
const PreparedBuild = @import("prepared_build.zig").PreparedBuild;
const io = @import("../loop/root.zig");
const images = @import("../image/root.zig");
const ui = @import("../ui/root.zig");
const Scheduler = @import("../task/root.zig").Scheduler;

test "Lua images queue after build, apply icon defaults and retain prepared pixels beyond source lifetime" {
    const allocator = std.testing.allocator;
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 4);
    c.lua_setglobal(state, "ouro");
    var loop: io.Loop = undefined;
    try loop.init(allocator, 8, 1);
    defer loop.deinit();
    var scheduler: Scheduler = undefined;
    try scheduler.init(allocator, 4, 1, 0);
    defer scheduler.deinit();
    const scope = try scheduler.createScope(scheduler.application_scope);
    var owners: ui.instance.BuildOwners = undefined;
    try owners.init(allocator, &scheduler, scope, 1, 4);
    defer owners.deinit();
    const owner = try owners.mount(null, 1);
    var cache = try images.Cache.init(allocator, 4);
    defer cache.deinit();
    var assets: images.Service = undefined;
    try assets.init(allocator, &loop, &cache, null);
    var assets_alive = true;
    defer if (assets_alive) {
        assets.shutdown();
        while (!assets.canDeinit()) completeImage(&assets, &loop) catch unreachable;
        assets.deinit();
    };
    var descriptors: [5]ui.instance.Descriptor = undefined;
    var semantics: [3]ui.semantics.Descriptor = undefined;
    var build: UiBuild = undefined;
    try build.init(state, &descriptors);
    build.enableDeclarativeWidgets(@import("../design/root.zig").tokens.light);
    build.images = &assets;
    build.image_scale = 2;
    try build.attachSemantics(&semantics);
    defer build.rollbackHandlers();
    const encoded = try @import("../renderer/png.zig").encode(allocator, &.{
        255, 0,  0,   255, 0, 255, 0,  128, 0,   0,  255, 0,
        31,  63, 127, 255, 3, 7,   11, 255, 127, 63, 31,  255,
    }, 3, 2, 12);
    defer allocator.free(encoded);
    _ = c.lua_pushlstring(state, encoded.ptr, encoded.len);
    c.lua_setglobal(state, "encoded");
    const source =
        \\function build()
        \\  return ouro.row { key = "row",
        \\    ouro.image { key = "photo", bytes = encoded, width = 30, height = 20, fit = "cover", alt = "Mountains" },
        \\    ouro.icon { key = "arrow", bytes = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><path d="M0 0h24v24H0Z"/></svg>' },
        \\  }
        \\end
        \\function both() return ouro.image { key = "bad", src = "photo.png", bytes = encoded } end
        \\function neither() return ouro.image { key = "bad" } end
        \\function badpath() return ouro.image { key = "bad", src = false, bytes = encoded } end
        \\function badbytes() return ouro.image { key = "bad", src = "photo.png", bytes = 1 } end
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@images-test", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 0, 0, 0, null));
    var cycle = owners.beginCycle();
    var work = (try cycle.take()).?;
    for ([_][*:0]const u8{ "both", "neither", "badpath", "badbytes" }) |name|
        try std.testing.expectError(error.LuaBuildFailed, build.build(&owners, work, name, &.{}));
    try std.testing.expect(!assets.hasPending());
    var result = try build.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expect(result[3].object.image.image == null);
    try std.testing.expectEqual(@as(?f32, 30), result[3].object.image.width);
    try std.testing.expectEqual(@as(?f32, 20), result[3].object.image.height);
    try std.testing.expectEqual(images.Fit.cover, result[3].object.image.fit);
    try std.testing.expectEqual(@as(?f32, 24), result[4].object.image.width);
    try std.testing.expectEqualStrings("Mountains", semantics[1].label);
    try std.testing.expectEqual(ui.semantics.Role.image, semantics[1].role);
    try std.testing.expect(!loop.hasPendingOperations());
    try std.testing.expectEqual(@as(usize, 0), cache.byteSize());
    try build.commitDependencies(&owners, work);
    build.rollbackHandlers();
    try owners.complete(work);
    while (assets.hasPending()) {
        try assets.pump();
        if (!assets.canDeinit()) try completeImage(&assets, &loop);
    }
    cycle = owners.beginCycle();
    work = (try cycle.take()).?;
    result = try build.build(&owners, work, "build", &.{});
    const photo = result[3].object.image.image.?;
    const icon = result[4].object.image.image.?;
    try std.testing.expectEqual(@as(u32, 3), (try cache.get(photo)).width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 128, 0, 128 }, (try cache.get(photo)).pixels[0..8]);
    try std.testing.expectEqual(@as(u32, 48), (try cache.get(icon)).width);
    const foreground = @import("../design/root.zig").tokens.light.foreground.premultiplied();
    try std.testing.expectEqualSlices(u8, &.{ foreground.r, foreground.g, foreground.b, foreground.a }, (try cache.get(icon)).pixels[0..4]);
    var prepared: PreparedBuild = undefined;
    try prepared.init(allocator, state, null, 5, 128);
    defer prepared.deinit();
    try build.capturePrepared(&prepared, result);
    try build.commitDependencies(&owners, work);
    try owners.complete(work);
    build.disposeOwner(&owners, owner);
    assets.shutdown();
    assets.deinit();
    assets_alive = false;
    try std.testing.expectEqual(@as(u32, 3), (try cache.get(photo)).width);
    prepared.reset();
    try std.testing.expectError(error.StaleImageHandle, cache.get(photo));
    try std.testing.expectError(error.StaleImageHandle, cache.get(icon));
    try owners.retire(owner);
    try scheduler.applyQueuedCancellations();
    try owners.collectRetired();
    try scheduler.destroyScope(scope);
}

fn completeImage(assets: *images.Service, loop: *io.Loop) !void {
    _ = try loop.submit();
    switch (loop.dispatch(try loop.wait())) {
        .file => |completion| try std.testing.expect(try assets.dispatch(completion)),
        else => return error.UnexpectedImageCompletion,
    }
}
