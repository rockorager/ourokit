const std = @import("std");
const core = @import("../core/root.zig");
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;
const design = @import("../design/root.zig");
const io_loop = @import("../loop/root.zig");
const lua = @import("../lua/root.zig");
const renderer = @import("../renderer/root.zig");
const task = @import("../task/root.zig");
const text = @import("../text/root.zig");
const ui = @import("../ui/root.zig");
const image_service = @import("../image/service.zig");
const ImageCache = @import("../image/cache.zig").Cache;

pub const StoryDescription = struct {
    id: []u8,
    group: []u8,
    name: []u8,
    viewport: lua.StorybookViewport,
    snapshot_scale: f32,
    color_scheme: lua.StorybookColorScheme,
    action_count: usize,
};

pub const Description = struct {
    allocator: std.mem.Allocator,
    title: []u8,
    stories: []StoryDescription,

    pub fn deinit(self: *Description) void {
        for (self.stories) |story| {
            self.allocator.free(story.name);
            self.allocator.free(story.group);
            self.allocator.free(story.id);
        }
        self.allocator.free(self.stories);
        self.allocator.free(self.title);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    viewport: lua.StorybookViewport,
    snapshot_scale: f32,
    color_scheme: lua.StorybookColorScheme,
    pixel_width: u32,
    pixel_height: u32,
    png: []u8,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.png);
        self.allocator.free(self.id);
        self.* = undefined;
    }
};

/// Evaluates a catalog without running any story content and returns metadata
/// that remains valid after the isolated Lua VM is closed.
pub fn describe(init: std.process.Init, source: []const u8) !Description {
    var loop: io_loop.Loop = undefined;
    try loop.init(init.gpa, 8, 1);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(init.gpa, 4, 1, 1);
    defer scheduler.deinit();
    var vm: lua.Vm = undefined;
    try vm.init(init.gpa, &scheduler, &loop);
    var signals: lua.Signals = undefined;
    var signals_initialized = false;
    defer {
        vm.deinit();
        if (signals_initialized) signals.deinit();
    }
    try signals.initWithApi(
        init.gpa,
        vm.state,
        256,
        1024,
        256,
        vm.apiReference(),
    );
    signals_initialized = true;
    var descriptor_storage: [2]ui.instance.Descriptor = undefined;
    var lua_ui: lua.UiBuild = undefined;
    try lua_ui.initWithApi(vm.state, &descriptor_storage, vm.apiReference());
    lua_ui.attachSignals(&signals);

    var book = try lua.Storybook.loadWithApi(
        init.gpa,
        vm.state,
        vm.apiReference(),
        source,
    );
    defer book.deinit();
    const title = try init.gpa.dupe(u8, book.title);
    errdefer init.gpa.free(title);
    const stories = try init.gpa.alloc(StoryDescription, book.stories.len);
    errdefer init.gpa.free(stories);
    var initialized: usize = 0;
    errdefer for (stories[0..initialized]) |story| {
        init.gpa.free(story.name);
        init.gpa.free(story.group);
        init.gpa.free(story.id);
    };
    for (book.stories, stories) |story, *description| {
        const id = try init.gpa.dupe(u8, story.id);
        errdefer init.gpa.free(id);
        const group = try init.gpa.dupe(u8, story.group);
        errdefer init.gpa.free(group);
        const name = try init.gpa.dupe(u8, story.name);
        errdefer init.gpa.free(name);
        description.* = .{
            .id = id,
            .group = group,
            .name = name,
            .viewport = story.viewport,
            .snapshot_scale = story.snapshot_scale,
            .color_scheme = story.color_scheme,
            .action_count = story.actions.len,
        };
        initialized += 1;
    }
    return .{ .allocator = init.gpa, .title = title, .stories = stories };
}

/// Renders one selected story in a fresh VM and platform-neutral window
/// runtime, then encodes the software-rendered pixels as PNG.
pub fn snapshot(init: std.process.Init, source: []const u8, story_id: []const u8, asset_root: ?std.os.linux.fd_t) !Snapshot {
    if (!renderer.software.has_freetype) return error.FreeTypeDisabled;
    const config: @import("window_runtime.zig").Config = .{};
    var loop: io_loop.Loop = undefined;
    try loop.init(init.gpa, 8, 1);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    // One scope per instance, plus the application, window and build owner.
    try scheduler.init(init.gpa, config.node_capacity + 3, 8, 8);
    defer scheduler.deinit();
    var vm: lua.Vm = undefined;
    try vm.init(init.gpa, &scheduler, &loop);
    var signals: lua.Signals = undefined;
    var signals_initialized = false;
    defer {
        vm.deinit();
        if (signals_initialized) signals.deinit();
    }
    try signals.initWithApi(
        init.gpa,
        vm.state,
        256,
        1024,
        256,
        vm.apiReference(),
    );
    signals_initialized = true;

    var fonts = text.FontCache.init(init.gpa);
    defer fonts.deinit();
    var theme_fonts: @import("../lua/theme_fonts.zig").ThemeFonts = .{ .allocator = init.gpa, .io = init.io, .fonts = &fonts };
    defer theme_fonts.deinit();
    const primary_font = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(primary_font) catch unreachable;
    const medium_font = try text.bundled.acquire(&fonts, .sans, .semibold, .roman);
    defer fonts.release(medium_font) catch unreachable;
    const arabic_font = try fonts.acquire(.{
        .key = .{ .file = "/ourokit/storybook/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_storybook_arabic_font"),
    });
    defer fonts.release(arabic_font) catch unreachable;
    var paragraph_sources = text.ParagraphSourceCache.init(init.gpa, &fonts);
    defer paragraph_sources.deinit();
    var paragraphs = text.ParagraphCache.init(init.gpa, &fonts);
    defer paragraphs.deinit();
    var images = try ImageCache.init(init.gpa, 256);
    defer images.deinit();
    var icon_paths = try @import("../xdg/icons.zig").SearchPaths.init(init.gpa, init.minimal.environ);
    defer icon_paths.deinit();
    var assets: image_service.Service = undefined;
    try assets.init(init.gpa, &loop, &images, asset_root);
    assets.icon_roots = icon_paths.paths;
    defer {
        drainImages(&assets, &loop) catch |err| std.debug.panic("image shutdown failed: {s}", .{@errorName(err)});
        assets.deinit();
    }
    var glyphs = try renderer.software.GlyphCache.init(init.gpa, &fonts);
    defer glyphs.deinit();

    var callbacks: lua.CallbackRegistry = undefined;
    try callbacks.init(init.gpa, config.node_capacity);
    defer callbacks.deinit();
    const descriptor_storage = try init.gpa.alloc(ui.instance.Descriptor, config.node_capacity);
    defer init.gpa.free(descriptor_storage);
    const semantic_storage = try init.gpa.alloc(ui.semantics.Descriptor, config.node_capacity);
    defer init.gpa.free(semantic_storage);
    var lua_ui: lua.UiBuild = undefined;
    try lua_ui.initWithApi(vm.state, descriptor_storage, vm.apiReference());
    lua_ui.theme_fonts = &theme_fonts;
    lua_ui.images = &assets;
    lua_ui.attachSignals(&signals);
    lua_ui.attachCallbacks(&callbacks, &vm);
    try lua_ui.attachText(&paragraph_sources, &.{ primary_font, arabic_font }, 1);
    try lua_ui.attachMediumText(&.{ medium_font, arabic_font });
    try lua_ui.attachSemantics(semantic_storage);

    var book = try lua.Storybook.loadWithApi(
        init.gpa,
        vm.state,
        vm.apiReference(),
        source,
    );
    defer book.deinit();
    const story = book.find(story_id) orelse return error.UnknownStory;
    const theme = switch (story.color_scheme) {
        .light => design.tokens.light,
        .dark => design.tokens.dark,
    };
    lua_ui.enableDeclarativeWidgets(theme);

    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var runtime: WindowRuntime = .{};
    try runtime.init(
        init.gpa,
        &scheduler,
        window_scope,
        .{ .slot = 0, .generation = 1 },
        theme.background,
        theme.primary,
        theme.foreground,
        theme.input,
        theme.ring,
        &signals,
        &paragraph_sources,
        &paragraphs,
        config,
    );
    runtime.output_scale = story.snapshot_scale;
    errdefer teardownRuntime(&runtime, &lua_ui, &scheduler, window_scope) catch {};
    try runtime.reconcile(
        .{ .width = story.viewport.width, .height = story.viewport.height },
        &lua_ui,
        story.content_reference,
    );
    try runtime.prepareFrame(story.snapshot_scale);
    try settleImages(&runtime, &lua_ui, story, &loop);
    if (story.actions.len != 0) {
        vm.disableSleep();
        for (story.actions) |action| try playAction(
            &runtime,
            &vm,
            &callbacks,
            &scheduler,
            &lua_ui,
            story,
            action,
        );
    }
    const list = try runtime.displayList();

    const pixel_width = try physicalDimension(story.viewport.width, story.snapshot_scale);
    const pixel_height = try physicalDimension(story.viewport.height, story.snapshot_scale);
    const stride = std.math.mul(usize, pixel_width, 4) catch return error.ImageTooLarge;
    const pixel_len = std.math.mul(usize, stride, pixel_height) catch return error.ImageTooLarge;
    if (pixel_len > 256 * 1024 * 1024) return error.ImageTooLarge;
    const pixels = try init.gpa.alloc(u8, pixel_len);
    defer init.gpa.free(pixels);
    @memset(pixels, 0);
    try renderer.software.renderResources(list, .{
        .pixels = pixels,
        .width = pixel_width,
        .height = pixel_height,
        .stride = stride,
        .format = .rgba8_unorm,
    }, &glyphs, null, &paragraphs, &images);
    // Snapshot PNG is explicit sRGB interchange, not the gamma-2.2 Wayland
    // presentation representation produced by the renderer.
    for (0..pixel_height) |y| for (0..pixel_width) |x| {
        const offset = y * stride + x * 4;
        pixels[offset..][0..4].* = core.gamma22ToStraightSrgba8(.{
            .r = pixels[offset],
            .g = pixels[offset + 1],
            .b = pixels[offset + 2],
            .a = pixels[offset + 3],
        });
    };
    const png = try renderer.png.encode(init.gpa, pixels, pixel_width, pixel_height, stride);
    errdefer init.gpa.free(png);
    const id = try init.gpa.dupe(u8, story.id);
    errdefer init.gpa.free(id);
    const viewport = story.viewport;
    const snapshot_scale = story.snapshot_scale;
    const color_scheme = story.color_scheme;

    try teardownRuntime(&runtime, &lua_ui, &scheduler, window_scope);

    return .{
        .allocator = init.gpa,
        .id = id,
        .viewport = viewport,
        .snapshot_scale = snapshot_scale,
        .color_scheme = color_scheme,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
        .png = png,
    };
}

fn playAction(
    runtime: *WindowRuntime,
    vm: *lua.Vm,
    callbacks: *lua.CallbackRegistry,
    scheduler: *task.Scheduler,
    lua_ui: *lua.UiBuild,
    story: *const lua.StorybookStory,
    action: lua.StorybookAction,
) !void {
    const target = try runtime.semanticTarget(action.target);
    const window = runtime.window;
    try runtime.routePointer(.{ .motion = .{
        .window = window,
        .time_ms = 0,
        .position = target.center,
    } });
    try dispatchAndSettle(runtime, vm, callbacks, scheduler, lua_ui, story);
    if (action.kind == .scroll) {
        try runtime.routePointer(.{ .axis = .{
            .window = window,
            .time_ms = 0,
            .axis = target.scroll_axis orelse return error.StoryActionTargetNotScrollable,
            .delta = action.delta,
        } });
        try dispatchAndSettle(runtime, vm, callbacks, scheduler, lua_ui, story);
        return;
    }
    if (action.kind == .hover) return;
    if (target.role != .button) return error.StoryActionTargetNotInteractive;

    try runtime.routePointer(.{ .button = .{
        .window = window,
        .serial = 1,
        .time_ms = 0,
        .button = 0x110,
        .state = .pressed,
    } });
    try dispatchAndSettle(runtime, vm, callbacks, scheduler, lua_ui, story);
    if (action.kind == .pointer_down) return;

    try runtime.routePointer(.{ .button = .{
        .window = window,
        .serial = 2,
        .time_ms = 0,
        .button = 0x110,
        .state = .released,
    } });
    try dispatchAndSettle(runtime, vm, callbacks, scheduler, lua_ui, story);
}

fn dispatchAndSettle(
    runtime: *WindowRuntime,
    vm: *lua.Vm,
    callbacks: *lua.CallbackRegistry,
    scheduler: *task.Scheduler,
    lua_ui: *lua.UiBuild,
    story: *const lua.StorybookStory,
) !void {
    try runtime.dispatchInput(callbacks);
    try scheduler.applyQueuedCancellations();
    while (scheduler.takeRunnable()) |handle| switch (try vm.resumeRunnable(handle)) {
        .completed, .canceled => {},
        .waiting => return error.StoryActionDidNotSettle,
    };
    try runtime.collectRetired();
    try runtime.reconcile(
        .{ .width = story.viewport.width, .height = story.viewport.height },
        lua_ui,
        story.content_reference,
    );
    try runtime.prepareFrame(story.snapshot_scale);
    try settleImages(runtime, lua_ui, story, vm.loop);
}

fn settleImages(runtime: *WindowRuntime, lua_ui: *lua.UiBuild, story: *const lua.StorybookStory, loop: *io_loop.Loop) !void {
    const assets = lua_ui.images orelse return;
    while (assets.hasPending()) {
        try assets.pump();
        if (assets.canDeinit()) break;
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| if (!(try assets.dispatch(completion))) return error.UnownedImageCompletion,
            else => return error.UnexpectedImageCompletion,
        }
        try runtime.reconcile(.{ .width = story.viewport.width, .height = story.viewport.height }, lua_ui, story.content_reference);
        try runtime.prepareFrame(story.snapshot_scale);
    }
}

fn drainImages(assets: *image_service.Service, loop: *io_loop.Loop) !void {
    assets.shutdown();
    while (!assets.canDeinit()) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| if (!(try assets.dispatch(completion))) return error.UnownedImageCompletion,
            else => return error.UnexpectedImageCompletion,
        }
    }
}

fn teardownRuntime(
    runtime: *WindowRuntime,
    lua_ui: *lua.UiBuild,
    scheduler: *task.Scheduler,
    window_scope: task.ScopeHandle,
) !void {
    try runtime.clear(lua_ui);
    try scheduler.applyQueuedCancellations();
    try runtime.collectRetired();
    runtime.deinit();
    try scheduler.destroyScope(window_scope);
}

fn physicalDimension(logical: u32, scale: f32) !u32 {
    const value = @ceil(@as(f64, @floatFromInt(logical)) * scale);
    if (!std.math.isFinite(value) or value <= 0 or value > std.math.maxInt(u32))
        return error.ImageTooLarge;
    return @intFromFloat(value);
}

test "physical story dimensions round up after scaling" {
    try std.testing.expectEqual(@as(u32, 480), try physicalDimension(320, 1.5));
    try std.testing.expectEqual(@as(u32, 2), try physicalDimension(1, 1.1));
}
