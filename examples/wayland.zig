const std = @import("std");
const ourokit = @import("ourokit");

const ToplevelDeclaration = ourokit.app.windows.ToplevelDeclaration;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var exit_after_first_frame = false;
    var two_windows = false;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            exit_after_first_frame = true;
        } else if (std.mem.eql(u8, argument, "--two-windows")) {
            two_windows = true;
        } else {
            return error.UnknownArgument;
        }
    }

    var loop: ourokit.loop.Loop = undefined;
    try loop.init(init.gpa, 128, 32);
    defer loop.deinit();

    var scheduler: ourokit.task.Scheduler = undefined;
    try scheduler.init(init.gpa, 16, 1, 0);
    defer scheduler.deinit();

    var lua_vm: ourokit.lua.Vm = undefined;
    try lua_vm.init(init.gpa, &scheduler, &loop);
    var signals: ourokit.lua.Signals = undefined;
    var signals_initialized = false;
    defer {
        lua_vm.deinit();
        if (signals_initialized) signals.deinit();
    }
    try signals.init(init.gpa, lua_vm.state, 16, 32, 16);
    signals_initialized = true;
    var font_database = try ourokit.text.discovery.Database.init();
    defer font_database.deinit();
    var configured_fonts = try font_database.candidates(init.gpa, .{
        .family = "sans-serif",
        .language = "en",
        .pixel_size = 14,
    });
    defer configured_fonts.deinit();
    var font_cache = ourokit.text.FontCache.init(init.gpa);
    defer font_cache.deinit();
    const primary_font = try loadFont(init, &font_cache, configured_fonts.faces[0]);
    defer font_cache.release(primary_font) catch unreachable;
    var shape_cache = ourokit.text.ShapeCache.init(init.gpa, &font_cache);
    defer shape_cache.deinit();
    var glyph_cache = try ourokit.renderer.software.GlyphCache.init(init.gpa, &font_cache);
    defer glyph_cache.deinit();

    var lua_descriptor_storage: [4]ourokit.ui.instance.Descriptor = undefined;
    var lua_ui: ourokit.lua.UiBuild = undefined;
    try lua_ui.init(lua_vm.state, &lua_descriptor_storage);
    lua_ui.attachSignals(&signals);
    try lua_ui.attachLabelText(&shape_cache, &.{primary_font}, 1);
    const application_source =
        \\clicked = ouro.signal(false)
        \\function build_window(width, height, surface, accent, content)
        \\  ouro.box(1, 0, nil, nil, surface)
        \\  ouro.stack(2, 1, true)
        \\  ouro.padded_box(3, 2, 160, 44, 12, accent)
        \\  ouro.label(4, 3, clicked() and "Clicked" or "Benchmark", 14, content)
        \\  ouro.on_pointer(3, function(kind, target, x, y, value1, value2)
        \\    if kind == 4 and value2 == 1 then
        \\      clicked:set(not clicked())
        \\    end
        \\  end)
        \\end
    ;
    _ = try lua_vm.spawnApplication(application_source);
    _ = try lua_vm.resumeRunnable(scheduler.takeRunnable() orelse return error.LuaSetupTaskMissing);

    // The sink stores only this stable address. Host startup performs registry
    // discovery but cannot emit a window event before WindowSet.init below.
    var windows: ourokit.app.windows.WindowSet = undefined;
    var host: ourokit.platform.wayland.Host = undefined;
    try host.init(
        init.gpa,
        &loop,
        init.minimal.environ,
        windows.eventSink(),
        .{ .app_id = "dev.ourokit.benchmark.ourokit", .window_capacity = 2 },
    );
    defer host.deinit();
    try windows.init(init.gpa, &scheduler, host.nativeHost(), 2, 16);
    defer windows.deinit();

    const declarations = [_]ToplevelDeclaration{
        .{
            .id = "main",
            .title = "Ourokit benchmark",
            .initial_width = 480,
            .initial_height = 320,
        },
        .{
            .id = "secondary",
            .title = "Ourokit second window",
            .initial_width = 420,
            .initial_height = 320,
        },
    };
    const theme = ourokit.design.tokens.light;
    var interfaces = [_]ExampleUi{.{}} ** declarations.len;
    defer for (&interfaces) |*interface| interface.deinit();
    var dirty_instances: ourokit.ui.instance.ReconcileQueue = undefined;
    try dirty_instances.init(init.gpa, declarations.len);
    defer dirty_instances.deinit();
    var configured_sizes = [_]?ourokit.core.SizeU{null} ** declarations.len;
    var desired = [_]bool{ true, two_windows };
    var frames_seen = [_]usize{ 0, 0 };
    var disconnect_started = false;

    while (true) {
        var desired_changed = false;
        if (host.failure != null) {
            for (&desired) |*present| {
                if (present.*) desired_changed = true;
                present.* = false;
            }
        }
        while (windows.takeEvent()) |event| switch (event) {
            .close_requested => |handle| {
                for (declarations, 0..) |declaration, index| {
                    const current = windows.handleForId(declaration.id) orelse continue;
                    if (sameWindow(current, handle) and desired[index]) {
                        desired[index] = false;
                        desired_changed = true;
                    }
                }
            },
            .configured => |configured| {
                for (declarations, 0..) |declaration, index| {
                    const current = windows.handleForId(declaration.id) orelse continue;
                    if (!sameWindow(current, configured.window)) continue;
                    configured_sizes[index] = .{
                        .width = configured.width,
                        .height = configured.height,
                    };
                    if (interfaces[index].registered)
                        _ = try dirty_instances.markDirty(configured.window);
                }
            },
            .pointer => |pointer| {
                for (declarations, 0..) |declaration, index| {
                    const current = windows.handleForId(declaration.id) orelse continue;
                    if (!sameWindow(current, pointerWindow(pointer))) continue;
                    if (interfaces[index].ready) try interfaces[index].routePointer(pointer);
                }
            },
        };

        // Task safe point: close-triggered scope cancellation never executes
        // from Wayring dispatch or from native window reconciliation.
        try scheduler.applyQueuedCancellations();
        for (&interfaces) |*interface| try interface.collectRetired();
        for (&interfaces) |*interface| if (interface.ready)
            try interface.dispatchInput(&lua_vm);
        while (scheduler.takeRunnable()) |handle| _ = try lua_vm.resumeRunnable(handle);

        var current_storage: [declarations.len]ToplevelDeclaration = undefined;
        var current_count: usize = 0;
        for (declarations, desired) |declaration, present| {
            if (!present) continue;
            current_storage[current_count] = declaration;
            current_count += 1;
        }
        try windows.reconcile(current_storage[0..current_count]);

        for (declarations, desired, 0..) |declaration, present, index| {
            if (!present) {
                if (interfaces[index].registered) {
                    try dirty_instances.unregister(interfaces[index].window);
                    interfaces[index].registered = false;
                }
                try interfaces[index].clear(&lua_ui);
                continue;
            }
            const handle = windows.handleForId(declaration.id).?;
            if (!interfaces[index].initialized) {
                try interfaces[index].init(
                    init.gpa,
                    &scheduler,
                    try windows.scope(handle),
                    handle,
                    theme.surface_base,
                    theme.accent_default,
                    theme.surface_base,
                    &signals,
                    &shape_cache,
                );
                try dirty_instances.register(handle);
                interfaces[index].registered = true;
                interfaces[index].setDirtyWindowQueue(&dirty_instances);
            }
            if (configured_sizes[index] != null and !(try dirty_instances.hasPending(handle)))
                _ = try dirty_instances.markDirty(handle);
        }

        // Only owners marked dirty by task or platform state produce a typed
        // descriptor snapshot during this reconciliation phase.
        while (dirty_instances.take()) |work| {
            var interface_index: ?usize = null;
            for (&interfaces, 0..) |*interface, index| {
                if (interface.registered and sameWindow(interface.window, work.owner)) {
                    interface_index = index;
                    break;
                }
            }
            const index = interface_index orelse return error.UnknownDirtyWindow;
            const size = configured_sizes[index] orelse
                interfaces[index].frame.size orelse return error.DirtyWindowNotConfigured;
            interfaces[index].reconcile(size, &lua_ui) catch |err| {
                try dirty_instances.retry(work);
                return err;
            };
            configured_sizes[index] = null;
            try dirty_instances.complete(work);
        }

        for (declarations, desired, 0..) |declaration, present, index| {
            if (!present) continue;
            const handle = windows.handleForId(declaration.id).?;
            if (interfaces[index].wantsSubmission()) try host.requestRedraw(handle);
        }

        // Layout and scene construction finish before frame submission. The
        // renderer consumes only immutable display-list data below.
        for (declarations, desired, 0..) |declaration, present, index| {
            if (!present) continue;
            const handle = windows.handleForId(declaration.id).?;
            if (interfaces[index].wantsSubmission()) if (try host.acquireFrame(handle)) |frame| {
                const list = try interfaces[index].render();
                ourokit.renderer.software.renderText(list, .{
                    .pixels = frame.pixels,
                    .width = frame.width,
                    .height = frame.height,
                    .stride = frame.stride,
                    .format = .bgra8_unorm,
                }, &glyph_cache, &shape_cache) catch |err| {
                    try host.discardFrame(frame);
                    return err;
                };
                try host.present(frame);
                try interfaces[index].frameSubmitted();
            };
            frames_seen[index] = @max(frames_seen[index], try host.framesPresented(handle));
        }

        if (exit_after_first_frame) {
            var all_presented = true;
            var any_present = false;
            for (desired, frames_seen) |present, count| {
                any_present = any_present or present;
                if (present and count == 0) all_presented = false;
            }
            if (any_present and all_presented) {
                @memset(&desired, false);
                desired_changed = true;
            }
        }

        const serial_before_flush = windows.changeSerial();
        try host.flush();

        // Host maintenance may have completed an unbusy window synchronously.
        // Loop once more to apply its queued cancellation and retire the
        // declaration tombstone before blocking for another CQE.
        if (!disconnect_started and current_count == 0 and windows.retainedCount() == 0) {
            try host.beginDisconnect();
            disconnect_started = true;
            try host.flush();
        }
        if (host.quiescent() and windows.retainedCount() == 0) break;

        if (desired_changed or windows.changeSerial() != serial_before_flush) continue;
        if (host.quiescent()) continue;

        const completion = try loop.wait();
        switch (loop.dispatch(completion)) {
            .timeout => |timeout| try lua_vm.markTimeoutCompleted(timeout.operation),
            .timeout_cancel => {},
            .foreign => try host.dispatchOne(completion),
            .stale => return error.StaleCompletion,
        }
    }

    if (host.failure) |failure| return failure;

    const total_frames = frames_seen[0] + frames_seen[1];
    std.debug.print(
        "Ourokit Wayland example presented {d} frame(s) across {d} window(s) and exited cleanly.\n",
        .{ total_frames, @as(usize, if (two_windows) 2 else 1) },
    );
}

fn sameWindow(a: ourokit.platform.window.WindowHandle, b: ourokit.platform.window.WindowHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn pointerWindow(event: ourokit.platform.window.PointerEvent) ourokit.platform.window.WindowHandle {
    return switch (event) {
        .enter => |value| value.window,
        .leave => |value| value.window,
        .motion => |value| value.window,
        .button => |value| value.window,
        .axis => |value| value.window,
        .axis_source => |value| value.window,
        .axis_stop => |value| value.window,
        .axis_steps => |value| value.window,
        .axis_steps120 => |value| value.window,
        .frame => |window| window,
    };
}

fn loadFont(
    init: std.process.Init,
    cache: *ourokit.text.FontCache,
    face: ourokit.text.discovery.Face,
) !ourokit.text.FontHandle {
    const file = try std.Io.Dir.openFileAbsolute(init.io, face.file, .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    const bytes = try reader.interface.allocRemaining(init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(bytes);
    return cache.acquire(.{
        .key = .{
            .file = face.file,
            .index = face.index,
            .variations = face.variations,
        },
        .bytes = bytes,
    });
}

const ExampleUi = struct {
    initialized: bool = false,
    registered: bool = false,
    ready: bool = false,
    window: ourokit.platform.window.WindowHandle = .invalid,
    tree: ourokit.ui.render_object.Tree = undefined,
    instances: ourokit.ui.instance.Tree = undefined,
    build_owners: ourokit.ui.instance.BuildOwners = undefined,
    root_owner: ourokit.ui.instance.BuildOwnerHandle = .invalid,
    router: ourokit.ui.input.Router = undefined,
    pointer_bindings: ourokit.ui.input.PointerBindings = undefined,
    surface_color: ourokit.core.Color = undefined,
    accent_color: ourokit.core.Color = undefined,
    content_color: ourokit.core.Color = undefined,
    commands: [8]ourokit.scene.Command = undefined,
    command_count: usize = 0,
    frame: ourokit.app.frame.State = .{},
    signals: *ourokit.lua.Signals = undefined,
    dirty_windows: ?*ourokit.ui.instance.ReconcileQueue = null,
    reconciling: bool = false,

    fn init(
        self: *ExampleUi,
        allocator: std.mem.Allocator,
        scheduler: *ourokit.task.Scheduler,
        window_scope: ourokit.task.ScopeHandle,
        window: ourokit.platform.window.WindowHandle,
        surface: ourokit.core.Color,
        accent: ourokit.core.Color,
        content: ourokit.core.Color,
        signals: *ourokit.lua.Signals,
        shapes: *ourokit.text.ShapeCache,
    ) !void {
        try self.tree.init(allocator, 4);
        errdefer self.tree.deinit();
        self.tree.attachTextCache(shapes);
        try self.instances.init(allocator, scheduler, &self.tree, window_scope, 4);
        errdefer self.instances.deinit();
        try self.build_owners.init(allocator, scheduler, window_scope, 1, 8);
        errdefer self.build_owners.deinit();
        try self.router.init(allocator, &self.tree, &self.instances, window, 16);
        errdefer self.router.deinit();
        try self.pointer_bindings.init(allocator, 4);
        errdefer self.pointer_bindings.deinit();
        self.root_owner = try self.build_owners.mount(null, 1);
        self.window = window;
        self.surface_color = surface;
        self.accent_color = accent;
        self.content_color = content;
        self.signals = signals;
        self.initialized = true;
    }

    fn setDirtyWindowQueue(
        self: *ExampleUi,
        dirty_windows: *ourokit.ui.instance.ReconcileQueue,
    ) void {
        self.dirty_windows = dirty_windows;
        self.build_owners.setDirtySink(.{ .context = self, .notify = notifyDirtyWindow });
    }

    fn deinit(self: *ExampleUi) void {
        if (!self.initialized) return;
        std.debug.assert(self.pointer_bindings.takeAny() == null);
        self.pointer_bindings.deinit();
        self.router.deinit();
        self.build_owners.deinit();
        self.instances.deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    fn collectRetired(self: *ExampleUi) !void {
        if (!self.initialized) return;
        try self.build_owners.collectRetired();
        try self.instances.collectRetired();
    }

    fn clear(self: *ExampleUi, lua_ui: *ourokit.lua.UiBuild) !void {
        if (!self.initialized) return;
        lua_ui.clearHandlers(&self.pointer_bindings);
        while (self.router.takeEvent() != null) {}
        if (self.build_owners.isActive(self.root_owner)) {
            try self.signals.disposeOwner(.{
                .owners = &self.build_owners,
                .handle = self.root_owner,
            });
            try self.build_owners.retire(self.root_owner);
        }
        if (self.ready) try self.instances.reconcile(&.{});
        self.ready = false;
        self.command_count = 0;
        self.frame = .{};
    }

    fn reconcile(
        self: *ExampleUi,
        size: ourokit.core.SizeU,
        lua_ui: *ourokit.lua.UiBuild,
    ) !void {
        std.debug.assert(!self.reconciling);
        self.reconciling = true;
        defer self.reconciling = false;
        const size_changed = try self.frame.configure(size);
        if (size_changed and self.ready) _ = try self.build_owners.markDirty(self.root_owner);
        const width: f32 = @floatFromInt(size.width);
        const height: f32 = @floatFromInt(size.height);
        var builds = self.build_owners.beginCycle();
        while (try builds.take()) |work| {
            std.debug.assert(sameWindow(work.owner, self.root_owner));
            const arguments = [_]ourokit.lua.UiBuildArgument{
                .{ .number = width },
                .{ .number = height },
                .{ .integer = encodedColor(self.surface_color) },
                .{ .integer = encodedColor(self.accent_color) },
                .{ .integer = encodedColor(self.content_color) },
            };
            const descriptors = lua_ui.build(
                &self.build_owners,
                work,
                "build_window",
                &arguments,
            ) catch |err| {
                try self.build_owners.retry(work);
                return err;
            };
            self.instances.reconcile(descriptors) catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            lua_ui.commitHandlers(&self.pointer_bindings, &self.instances, work.owner) catch |err| {
                lua_ui.rollbackHandlers();
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            lua_ui.commitDependencies(&self.build_owners, work) catch |err| {
                try lua_ui.rollbackDependencies(&self.build_owners, work);
                try self.build_owners.retry(work);
                return err;
            };
            try self.build_owners.complete(work);
        }
        const root = (try self.instances.rootRenderObject()).?;
        if (try self.tree.layoutDirty(root)) {
            self.frame.invalidateLayout();
            _ = try self.tree.layout(
                root,
                ourokit.ui.layout.Constraints.tight(.{ .width = width, .height = height }),
            );
            try self.frame.layoutComplete();
        }
        if (try self.tree.paintDirty(root)) {
            self.frame.invalidatePaint();
            var builder = try ourokit.ui.render_object.Builder.init(&self.commands, 1);
            try self.tree.buildScene(root, &builder);
            self.command_count = builder.displayList().commands.len;
            _ = try self.frame.sceneBuilt();
        }
        self.ready = true;
    }

    fn routePointer(self: *ExampleUi, event: ourokit.platform.window.PointerEvent) !void {
        try self.router.route(event);
    }

    fn dispatchInput(self: *ExampleUi, vm: *ourokit.lua.Vm) !void {
        while (self.router.takeEvent()) |event| {
            const target = switch (event) {
                .hover_enter => |value| value.target,
                .hover_leave => |value| value.target,
                .pointer => |value| value.target,
            };
            if (!self.instances.isActive(target)) continue;
            const handler = self.pointer_bindings.get(target) orelse continue;
            const values = inputValues(event);
            const arguments = [_]ourokit.lua.TaskArgument{
                .{ .integer = values.kind },
                .{ .integer = @intCast(try self.instances.semanticId(target)) },
                .{ .number = values.x },
                .{ .number = values.y },
                .{ .integer = values.value1 },
                .{ .integer = values.value2 },
            };
            _ = try vm.spawnReference(
                try self.instances.scope(target),
                @intCast(handler),
                &arguments,
            );
        }
    }

    fn wantsSubmission(self: *const ExampleUi) bool {
        return self.initialized and self.frame.readyForSubmission();
    }

    fn render(self: *ExampleUi) !ourokit.scene.DisplayList {
        if (!self.frame.readyForSubmission()) return error.FrameNotReady;
        return .{ .commands = self.commands[0..self.command_count] };
    }

    fn frameSubmitted(self: *ExampleUi) !void {
        try self.frame.submitted();
    }

    fn notifyDirtyWindow(context: *anyopaque) !void {
        const self: *ExampleUi = @ptrCast(@alignCast(context));
        if (!self.registered or self.reconciling) return;
        _ = try self.dirty_windows.?.markDirty(self.window);
    }
};

const InputValues = struct {
    kind: i64,
    x: f64 = 0,
    y: f64 = 0,
    value1: i64 = 0,
    value2: i64 = 0,
};

fn inputValues(event: ourokit.ui.input.Event) InputValues {
    return switch (event) {
        .hover_enter => |value| .{ .kind = 1, .x = value.position.x, .y = value.position.y },
        .hover_leave => .{ .kind = 2 },
        .pointer => |value| switch (value.event) {
            .motion => |motion| .{ .kind = 3, .x = motion.position.x, .y = motion.position.y },
            .button => |button| .{
                .kind = 4,
                .value1 = button.button,
                .value2 = @intFromEnum(button.state),
            },
            .axis => |axis| .{ .kind = 5, .value1 = @intFromEnum(axis.axis), .x = axis.delta },
            else => .{ .kind = 6 },
        },
    };
}

fn encodedColor(color: ourokit.core.Color) i64 {
    return (@as(i64, color.r) << 24) |
        (@as(i64, color.g) << 16) |
        (@as(i64, color.b) << 8) |
        color.a;
}
