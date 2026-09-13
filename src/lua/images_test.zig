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
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const icon_root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(icon_root);
    try temporary.dir.createDirPath(std.testing.io, "test/24");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "test/index.theme", .data = "[Icon Theme]\nDirectories=24\n[24]\nSize=24\nType=Fixed\n" });
    const svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\"><path fill=\"#123456\" d=\"M0 0h24v24H0Z\"/></svg>";
    for ([_][]const u8{ "test/24/folder.svg", "test/24/folder-symbolic.svg" }) |path|
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = svg });
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
    var cache = try images.Cache.init(allocator, 5);
    defer cache.deinit();
    var assets: images.Service = undefined;
    try assets.init(allocator, &loop, &cache, null);
    assets.icon_roots = &.{icon_root};
    var assets_alive = true;
    defer if (assets_alive) {
        assets.shutdown();
        while (!assets.canDeinit()) completeImage(&assets, &loop) catch unreachable;
        assets.deinit();
    };
    var descriptors: [9]ui.instance.Descriptor = undefined;
    var semantics: [7]ui.semantics.Descriptor = undefined;
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
        \\    ouro.xdg.icon { key = "folder", name = "folder", theme = "test", alt = "Folder" },
        \\    ouro.icon { key = "symbolic", name = "folder-symbolic", theme = "test" },
        \\    ouro.xdg.icon { key = "missing", name = "absent", theme = "test", width = 32 },
        \\    ouro.image { key = "fill", bytes = '<svg xmlns="http://www.w3.org/2000/svg" width="31" height="17"><path d="M0 0h31v17H0Z"/></svg>', width = "fill", height = "fill", fit = "fill" },
        \\  }
        \\end
        \\function both() return ouro.image { key = "bad", src = "photo.png", bytes = encoded } end
        \\function neither() return ouro.image { key = "bad" } end
        \\function badpath() return ouro.image { key = "bad", src = false, bytes = encoded } end
        \\function badbytes() return ouro.image { key = "bad", src = "photo.png", bytes = 1 } end
        \\function mixed() return ouro.icon { key = "bad", name = "folder", src = "photo.png" } end
        \\function badname() return ouro.xdg.icon { key = "bad", name = false } end
        \\function badtheme() return ouro.icon { key = "bad", name = "folder", theme = 1 } end
        \\function imagename() return ouro.image { key = "bad", name = "folder" } end
        \\function badwidth() return ouro.image { key = "bad", bytes = encoded, width = "full" } end
        \\function badheight() return ouro.image { key = "bad", bytes = encoded, height = -1 } end
        \\function infinite() return ouro.image { key = "bad", bytes = encoded, width = 1/0 } end
        \\function nan() return ouro.image { key = "bad", bytes = encoded, height = 0/0 } end
        \\function iconfill() return ouro.icon { key = "bad", bytes = encoded, width = "fill" } end
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "@images-test", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 0, 0, 0, null));
    var cycle = owners.beginCycle();
    var work = (try cycle.take()).?;
    for ([_][*:0]const u8{ "both", "neither", "badpath", "badbytes", "mixed", "badname", "badtheme", "imagename", "badwidth", "badheight", "infinite", "nan", "iconfill" }) |name|
        try std.testing.expectError(error.LuaBuildFailed, build.build(&owners, work, name, &.{}));
    try std.testing.expect(!assets.hasPending());
    var result = try build.build(&owners, work, "build", &.{});
    try std.testing.expectEqual(@as(usize, 9), result.len);
    try std.testing.expect(result[3].object.image.image == null);
    try std.testing.expectEqual(@as(?f32, 30), result[3].object.image.width);
    try std.testing.expectEqual(@as(?f32, 20), result[3].object.image.height);
    try std.testing.expectEqual(images.Fit.cover, result[3].object.image.fit);
    try std.testing.expectEqual(@as(?f32, 24), result[4].object.image.width);
    try std.testing.expect(result[8].object.image.fill_width and result[8].object.image.fill_height);
    try std.testing.expect(result[8].object.image.width == null and result[8].object.image.height == null);
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
    const folder = result[5].object.image.image.?;
    const symbolic = result[6].object.image.image.?;
    try std.testing.expectEqual(@as(u32, 48), (try cache.get(folder)).width);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 255 }, (try cache.get(folder)).pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ foreground.r, foreground.g, foreground.b, foreground.a }, (try cache.get(symbolic)).pixels[0..4]);
    try std.testing.expectEqualStrings("Folder", semantics[3].label);
    try std.testing.expectEqual(ui.semantics.Role.image, semantics[3].role);
    try std.testing.expect(result[7].object.image.image == null);
    try std.testing.expectEqual(@as(?f32, 32), result[7].object.image.width);
    // Fill is resolved by layout, not sent as a numeric raster hint. SVG
    // pixels use intrinsic viewport × output scale, without changing intrinsic size.
    const fill = result[8].object.image.image.?;
    try std.testing.expectEqual(@as(u32, 62), (try cache.get(fill)).width);
    try std.testing.expectEqual(@as(u32, 34), (try cache.get(fill)).height);
    try std.testing.expectEqual(@as(u32, 31), (try cache.get(fill)).intrinsic_width);
    try std.testing.expectEqual(@as(u32, 17), (try cache.get(fill)).intrinsic_height);
    try std.testing.expect(!assets.hasPending());
    var prepared: PreparedBuild = undefined;
    try prepared.init(allocator, state, null, 9, 128);
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
    try std.testing.expectError(error.StaleImageHandle, cache.get(folder));
    try std.testing.expectError(error.StaleImageHandle, cache.get(symbolic));
    try std.testing.expectError(error.StaleImageHandle, cache.get(fill));
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
