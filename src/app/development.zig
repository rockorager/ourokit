//! Opt-in development operations below the transport. All calls belong on the
//! window's owning thread, at a safe point after normal runtime phases.
const std = @import("std");
const core = @import("../core/root.zig");
const platform = @import("../platform/window.zig");
const ui = @import("../ui/root.zig");
const renderer = @import("../renderer/root.zig");
const runtime_module = @import("window_runtime.zig");
const WindowRuntime = runtime_module.WindowRuntime;

pub const Token = struct {
    window: platform.WindowHandle,
    generation: u64,
    revision: u64,
    scene_revision: u64,

    pub fn current(runtime: *const WindowRuntime) Token {
        return .{
            .window = runtime.window,
            .generation = runtime.development_generation,
            .revision = runtime.development_revision,
            .scene_revision = runtime.frame_state.scene_revision,
        };
    }

    pub fn validate(self: Token, runtime: *WindowRuntime) !void {
        if (!std.meta.eql(self, current(runtime))) return error.StaleDevelopmentTarget;
        try requireSettled(runtime);
    }
};

/// Does not wait for timers, animation completion, or arbitrary asynchronous
/// application tasks. The host must first drain runnable callbacks and its
/// normal dispatch/reconcile/render phases. Backend acceptance is not display.
pub fn requireSettled(runtime: *WindowRuntime) !void {
    if (!runtime.initialized or !runtime.ready) return error.WindowRuntimeNotReady;
    if (runtime.reconciling or runtime.router.count != 0 or
        runtime.build_owners.dirty.pendingCount() != 0 or
        runtime.frame_state.needsScene() or runtime.frame_state.scene_revision == 0)
        return error.DevelopmentRuntimeNotSettled;
    const root = (try runtime.instances.rootRenderObject()) orelse return error.WindowRuntimeNotReady;
    if (try runtime.tree.layoutDirty(root) or try runtime.tree.paintDirty(root))
        return error.DevelopmentRuntimeNotSettled;
}

pub const Limits = struct {
    nodes: usize = 1024,
    text_bytes: usize = 64 * 1024,
};

pub const Node = struct {
    id: u64,
    parent: ?u64,
    /// Null means unkeyed, ambiguous, or not addressable by slash-key paths.
    path: ?[]const u8,
    role: ui.semantics.Role,
    label: []const u8,
    value: ?[]const u8,
    bounds: core.RectF,
    enabled: bool,
    visible: bool,
    selected: bool,
    selected_value: ?i64,
    checked: bool,
    range: ?@import("../ui/widget/range.zig").Range,
    focused: bool,
    selection: ?ui.text_input.Selection,
    scroll_axis: ?platform.PointerAxis,
    scroll_offset: ?f32,
    read_only: bool,
    multiline: bool,
};

/// Fully owned, bounded copy. It survives rebuild/reload; its token does not.
/// Capacity failures are explicit, never silently truncated semantic trees.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    token: Token,
    nodes: []Node,
    text: []u8,
    metrics: runtime_module.Metrics,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn inspect(allocator: std.mem.Allocator, runtime: *WindowRuntime, limits: Limits) !Snapshot {
    try requireSettled(runtime);
    const count = runtime.semantics.count();
    if (count > limits.nodes or limits.nodes > 4096 or limits.text_bytes > 1024 * 1024)
        return error.DevelopmentSnapshotCapacityExceeded;
    const nodes = try allocator.alloc(Node, count);
    errdefer allocator.free(nodes);
    const storage = try allocator.alloc(u8, limits.text_bytes);
    errdefer allocator.free(storage);
    var used: usize = 0;
    for (nodes, 0..) |*node, index| {
        const semantic = try runtime.semantics.node(index);
        // Component groups have semantic identity but no layout instance.
        const handle = runtime.instances.handleForId(semantic.id) orelse ui.instance.InstanceHandle.invalid;
        const target = try runtime.semanticNodeTarget(semantic.id);
        var path: ?[]const u8 = null;
        if (semantic.key.len != 0 and std.mem.indexOfScalar(u8, semantic.key, '/') == null) {
            var prefix: ?[]const u8 = if (semantic.parent == null) "" else null;
            if (semantic.parent) |parent| for (nodes[0..index]) |ancestor| {
                if (ancestor.id == parent) {
                    prefix = ancestor.path;
                    break;
                }
            };
            if (prefix) |parent_path| {
                const start = used;
                if (parent_path.len != 0) {
                    _ = try copyText(storage, &used, parent_path);
                    _ = try copyText(storage, &used, "/");
                }
                _ = try copyText(storage, &used, semantic.key);
                const candidate = storage[start..used];
                const resolved = runtime.semantics.findPath(candidate) catch null;
                if (resolved != null and resolved.?.id == semantic.id) path = candidate;
            }
        }
        var value: ?[]const u8 = null;
        var selection: ?ui.text_input.Selection = null;
        var read_only = false;
        var multiline = false;
        if (runtime.text_inputs.contains(handle)) {
            const session = try runtime.text_inputs.session(handle);
            // Masked fields expose neither their value nor its structure.
            if (!session.model.isSecret()) {
                value = try copyText(storage, &used, session.model.text());
                selection = session.model.selection;
            }
            multiline = session.model.multiline;
            read_only = (try runtime.text_inputs.getBehavior(handle)).read_only;
        }
        const selected = if (runtime.listboxes.option(handle)) |option|
            runtime.listboxes.selectedValue(option.listbox) == option.value
        else
            semantic.selected;
        node.* = .{
            .id = semantic.id,
            .parent = semantic.parent,
            .path = path,
            .role = semantic.role,
            .label = try copyText(storage, &used, semantic.label),
            .value = value,
            .bounds = target.bounds,
            .enabled = target.enabled,
            .visible = target.visible,
            .selected = selected,
            .selected_value = runtime.listboxes.selectedValue(handle),
            .checked = semantic.checked,
            .range = semantic.range,
            .focused = if (runtime.focus.current()) |focused| std.meta.eql(focused, handle) else false,
            .selection = selection,
            .scroll_axis = target.scroll_axis,
            .scroll_offset = if (multiline)
                try runtime.tree.textScrollOffset(try runtime.instances.renderObject(try runtime.text_inputs.content(handle)), .vertical)
            else if (target.scroll_axis != null) try runtime.instances.scrollOffset(handle) else null,
            .read_only = read_only,
            .multiline = multiline,
        };
    }
    return .{ .allocator = allocator, .token = Token.current(runtime), .nodes = nodes, .text = storage, .metrics = runtime.metrics };
}

fn copyText(storage: []u8, used: *usize, bytes: []const u8) ![]const u8 {
    if (bytes.len > storage.len - used.*) return error.DevelopmentSnapshotCapacityExceeded;
    const result = storage[used.*..][0..bytes.len];
    @memcpy(result, bytes);
    used.* += bytes.len;
    return result;
}

pub const Action = union(enum) {
    hover: []const u8,
    pointer_down: []const u8,
    pointer_move: []const u8,
    pointer_up,
    click: []const u8,
    scroll: struct { target: []const u8, delta: f32 },
    key: platform.TranslatedKey,
    text: []const u8,

    fn path(self: Action) ?[]const u8 {
        return switch (self) {
            .hover, .pointer_down, .pointer_move, .click => |path_value| path_value,
            .scroll => |value| value.target,
            .key, .text, .pointer_up => null,
        };
    }
};

/// Storybook-style playback, with an explicit yield between input phases.
/// The host owns action strings until completion. Serialize playbacks per
/// window. After EVERY `routed`, run ordinary dispatch, runnable tasks,
/// reconciliation and render submission before calling advance again; only
/// `complete` permits a successful transport reply. This never invokes Lua or
/// changes signals, focus, selection, or widget state directly.
pub const Playback = struct {
    token: Token,
    action: Action,
    target: ?ui.instance.InstanceHandle,
    step: usize = 0,
    text_offset: usize = 0,

    pub fn init(runtime: *WindowRuntime, token: Token, action: Action) !Playback {
        try token.validate(runtime);
        if (runtime.text_inputs.hasSecret()) return error.SecureInputProtected;
        var target: ?ui.instance.InstanceHandle = null;
        if (action.path()) |path| {
            const semantic = try runtime.semantics.findPath(path);
            const geometry = try runtime.semanticTarget(path);
            if (!geometry.visible) return error.DevelopmentTargetHidden;
            if (!geometry.enabled and action != .hover) return error.DevelopmentTargetDisabled;
            target = runtime.instances.handleForId(semantic.id) orelse return error.SemanticInstanceMissing;
            if ((action == .click or action == .pointer_down) and
                semantic.role != .button and semantic.role != .@"switch" and
                semantic.role != .checkbox and semantic.role != .radio and semantic.role != .radio_group and semantic.role != .slider and
                semantic.role != .tab and semantic.role != .tab_list and semantic.role != .separator and
                semantic.role != .text_field and semantic.role != .option and semantic.role != .listbox and
                !runtime.instances.isFocusable(target.?) and
                (try runtime.instances.dragOptions(target.?)).source == null and
                runtime.pointer_bindings.getKind(target.?, .pointer_capture) == null and
                runtime.pointer_bindings.getKind(target.?, .pointer_bubble) == null)
                return error.DevelopmentTargetNotInteractive;
            if (action == .scroll) {
                if (geometry.scroll_axis == null) return error.DevelopmentTargetNotScrollable;
                if (!std.math.isFinite(action.scroll.delta)) return error.InvalidScrollDelta;
            }
            try checkHit(runtime, target.?, geometry.center);
        }
        if (action == .text) {
            if (action.text.len > 16 * 1024) return error.DevelopmentTextTooLong;
            if (!std.unicode.utf8ValidateSlice(action.text)) return error.InvalidUtf8;
            const focused = runtime.focus.current() orelse return error.DevelopmentTargetNotFocused;
            if (!runtime.instances.isVisible(focused)) return error.DevelopmentTargetNotFocused;
            if (!runtime.text_inputs.contains(focused)) return error.DevelopmentTargetNotEditable;
            const multiline = (try runtime.text_inputs.session(focused)).model.multiline;
            var characters = (try std.unicode.Utf8View.init(action.text)).iterator();
            while (characters.nextCodepoint()) |cp| {
                if (cp == '\n' and multiline) continue;
                if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.DevelopmentTextContainsControl;
            }
            const behavior = try runtime.text_inputs.getBehavior(focused);
            if (!behavior.enabled) return error.DevelopmentTargetDisabled;
            if (behavior.read_only) return error.DevelopmentTargetReadOnly;
            if ((try runtime.text_inputs.session(focused)).preedit() != null) return error.DevelopmentCompositionActive;
            target = focused;
        }
        return .{ .token = token, .action = action, .target = target };
    }

    pub fn advance(self: *Playback, runtime: *WindowRuntime) !enum { routed, complete } {
        if (!std.meta.eql(self.token.window, runtime.window) or self.token.generation != runtime.development_generation)
            return error.StaleDevelopmentTarget;
        if (runtime.text_inputs.hasSecret()) return error.SecureInputProtected;
        try requireSettled(runtime);
        if (self.step == 0) try self.token.validate(runtime);
        const steps: usize = switch (self.action) {
            .hover, .pointer_move, .pointer_up => 1,
            .text => if (self.text_offset == self.action.text.len) 0 else std.math.maxInt(usize),
            .scroll, .pointer_down, .key => 2,
            .click => 3,
        };
        if (self.step >= steps) return .complete;
        if (self.action == .click and self.step == 2) {
            // Press callbacks may remove their own widget (closing a tab or
            // dismissing a dialog). Release the capture without looking up
            // the old path or activating anything newly occupying its place.
            try runtime.routePointer(.{ .button = .{ .window = runtime.window, .serial = 0, .time_ms = 0, .button = 0x110, .state = .released } });
            self.step += 1;
            return .routed;
        }
        if (self.target) |target| if (!runtime.instances.isActive(target)) return error.StaleDevelopmentTarget;
        const window = runtime.window;
        if (self.action.path()) |path| {
            const geometry = try runtime.semanticTarget(path);
            if (self.action != .hover and !geometry.enabled) return error.DevelopmentTargetDisabled;
            if (self.step == 0) {
                try checkHit(runtime, self.target.?, geometry.center);
                // Unlike a real seat, headless playback may not have entered.
                if (self.action == .pointer_move) {
                    try runtime.routePointer(.{ .motion = .{ .window = window, .time_ms = 0, .position = geometry.center } });
                } else {
                    try runtime.routePointer(.{ .enter = .{ .window = window, .serial = 0, .position = geometry.center } });
                }
            } else if (self.action == .scroll) {
                const axis = geometry.scroll_axis orelse return error.DevelopmentTargetNotScrollable;
                try checkHit(runtime, self.target.?, runtime.router.pointer_position);
                try runtime.routePointer(.{ .axis = .{ .window = window, .time_ms = 0, .axis = axis, .delta = self.action.scroll.delta } });
            } else {
                try checkHit(runtime, self.target.?, runtime.router.pointer_position);
                try runtime.routePointer(.{ .button = .{ .window = window, .serial = 0, .time_ms = 0, .button = 0x110, .state = .pressed } });
            }
        } else switch (self.action) {
            .pointer_up => try runtime.routePointer(.{ .button = .{ .window = window, .serial = 0, .time_ms = 0, .button = 0x110, .state = .released } }),
            .key => |key| try runtime.routeKeyboard(.{ .key = .{ .window = window, .serial = 0, .time_ms = 0, .state = if (self.step == 0) .pressed else .released, .translated = key } }),
            .text => |bytes| {
                if (!std.meta.eql(runtime.focus.current(), self.target)) return error.DevelopmentTargetNotFocused;
                const behavior = try runtime.text_inputs.getBehavior(self.target.?);
                if (!behavior.enabled) return error.DevelopmentTargetDisabled;
                if (behavior.read_only) return error.DevelopmentTargetReadOnly;
                if ((try runtime.text_inputs.session(self.target.?)).preedit() != null) return error.DevelopmentCompositionActive;
                // Native semantic focus need not own a compositor IME session.
                // Type through translated keys rather than inventing one.
                const len = try std.unicode.utf8ByteSequenceLength(bytes[self.text_offset]);
                const cp = try std.unicode.utf8Decode(bytes[self.text_offset..][0..len]);
                try runtime.routeKeyboard(.{ .key = .{
                    .window = window,
                    .serial = 0,
                    .time_ms = 0,
                    .state = if (self.step % 2 == 0) .pressed else .released,
                    .translated = if (cp == '\n') .{ .keycode = 0, .logical = .enter } else .{ .keycode = 0, .unicode = cp },
                } });
                if (self.step % 2 == 1) self.text_offset += len;
            },
            else => unreachable,
        }
        self.step += 1;
        return .routed;
    }

    /// On failure/disconnect, unwind a routed press via normal input. The host
    /// must dispatch and settle these events too. Already fired press callbacks
    /// are not undone. Reload/closed windows own their normal input teardown.
    pub fn cancel(self: *Playback, runtime: *WindowRuntime) !void {
        if (!runtime.ready or !std.meta.eql(self.token.window, runtime.window) or
            self.token.generation != runtime.development_generation) return;
        if ((self.action == .click or self.action == .pointer_down) and self.step == 2) {
            try runtime.routePointer(.{ .leave = .{ .window = runtime.window, .serial = 0 } });
            try runtime.routePointer(.{ .button = .{ .window = runtime.window, .serial = 0, .time_ms = 0, .button = 0x110, .state = .released } });
        } else if (self.action == .key and self.step == 1) {
            try runtime.routeKeyboard(.{ .key = .{ .window = runtime.window, .serial = 0, .time_ms = 0, .state = .released, .translated = self.action.key } });
        } else if (self.action == .text and self.step % 2 == 1) {
            const bytes = self.action.text;
            const len = try std.unicode.utf8ByteSequenceLength(bytes[self.text_offset]);
            const cp = try std.unicode.utf8Decode(bytes[self.text_offset..][0..len]);
            try runtime.routeKeyboard(.{ .key = .{ .window = runtime.window, .serial = 0, .time_ms = 0, .state = .released, .translated = if (cp == '\n') .{ .keycode = 0, .logical = .enter } else .{ .keycode = 0, .unicode = cp } } });
        }
        self.step = 4;
        if (self.action == .text) self.text_offset = self.action.text.len;
    }
};

fn checkHit(runtime: *WindowRuntime, target: ui.instance.InstanceHandle, point: core.PointF) !void {
    const root = (try runtime.instances.rootRenderObject()) orelse return error.WindowRuntimeNotReady;
    const hit = (try runtime.tree.hitTest(root, point)) orelse return error.DevelopmentTargetNotVisible;
    var current = runtime.instances.instanceForRenderObject(hit);
    while (current) |handle| {
        if (std.meta.eql(handle, target)) return;
        current = try runtime.instances.parentOf(handle);
    }
    return error.DevelopmentTargetOccluded;
}

pub const Capture = struct {
    allocator: std.mem.Allocator,
    token: Token,
    kind: enum { software_scene_replay } = .software_scene_replay,
    width: u32,
    height: u32,
    png: []u8,

    pub fn deinit(self: *Capture) void {
        self.allocator.free(self.png);
        self.* = undefined;
    }
};

/// Replay the CURRENT display list at its current scale with live resources.
/// This is not GPU readback and does not change damage/submission bookkeeping.
/// A fresh target always needs full replay, even after native submission.
pub fn capture(allocator: std.mem.Allocator, runtime: *WindowRuntime, expected: Token) !Capture {
    try expected.validate(runtime);
    if (runtime.text_inputs.hasSecret()) return error.SecureInputProtected;
    if (!renderer.software.has_freetype) return error.FreeTypeDisabled;
    const size = runtime.frame_state.size.?;
    const w = @ceil(@as(f64, @floatFromInt(size.width)) * runtime.output_scale);
    const h = @ceil(@as(f64, @floatFromInt(size.height)) * runtime.output_scale);
    if (!std.math.isFinite(w) or !std.math.isFinite(h) or w < 1 or h < 1 or w * h > 16 * 1024 * 1024)
        return error.DevelopmentCaptureTooLarge;
    const width: u32 = @intFromFloat(w);
    const height: u32 = @intFromFloat(h);
    const stride = @as(usize, width) * 4;
    const pixels = try allocator.alloc(u8, stride * height);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    var glyphs = try renderer.software.GlyphCache.init(allocator, runtime.paragraphs.font_cache);
    defer glyphs.deinit();
    try renderer.software.renderResources(.{ .commands = runtime.commands[0..runtime.command_count] }, .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = stride,
        .format = .rgba8_unorm,
        .allocator = allocator,
    }, &glyphs, null, runtime.paragraphs, runtime.tree.images);
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) {
        pixels[offset..][0..4].* = core.srgba8ToStraight(.{
            .r = pixels[offset],
            .g = pixels[offset + 1],
            .b = pixels[offset + 2],
            .a = pixels[offset + 3],
        });
    }
    return .{
        .allocator = allocator,
        .token = expected,
        .width = width,
        .height = height,
        .png = try renderer.png.encode(allocator, pixels, width, height, stride),
    };
}

test {
    _ = @import("development_test.zig");
}
