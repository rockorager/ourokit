const std = @import("std");
const Handle = @import("../../core/handle.zig").Handle;
const instance = @import("../instance/tree.zig");
const BuildOwnerHandle = @import("../instance/build_owner.zig").BuildOwnerHandle;

pub const HandlerKind = enum {
    pointer,
    button,
    @"switch",
    text_input_change,
    text_input_command,
    auth_submit,
    auth_cancel,
    auth_error,
    listbox,
    selection_activate,
    range_change,
    split_change,
    scroll_change,
    interaction_change,
    popup_anchor,
    cancel,
    drop_text,
    drop_uris,
    drop_internal,
    key_capture,
    key_bubble,
    pointer_capture,
    pointer_bubble,
    pointer_down_outside,
    shortcut,
    command,

    fn primary(self: HandlerKind) bool {
        return self == .pointer or self == .button or self == .@"switch" or self == .listbox or self == .range_change or self == .split_change;
    }
};

pub const Handler = struct {
    id: Handle,
    kind: HandlerKind = .pointer,
    /// Internal anchored-surface visibility policy.
    open_override: ?bool = null,
    include_capture: bool = false,
    propagate: bool = true,
    filter: @import("listener.zig").Filter = .{},
    sequence: @import("key_chord.zig").Sequence = .{},
    command: @import("command.zig").Name = .{},
};

const Entry = struct {
    owner: BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    handler: ?Handler = null,
};

const ScrollState = struct {
    target: instance.InstanceHandle = .invalid,
    metrics: ?@import("../render_object/scroll.zig").Metrics = null,
};

const InteractionState = struct {
    target: instance.InstanceHandle = .invalid,
    kind: HandlerKind = .interaction_change,
    active: bool = false,
};

/// Language-neutral, instance-owned semantic input bindings. Targets are
/// generation checked; handler IDs are opaque capabilities owned by a bridge.
pub const PointerBindings = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    interactions: []InteractionState,
    scrolls: []ScrollState,
    entry_limit: usize = 0,
    scroll_limit: usize = 0,
    revision: u64 = 0,

    pub fn init(self: *PointerBindings, allocator: std.mem.Allocator, capacity: usize) !void {
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        const interactions = try allocator.alloc(InteractionState, capacity);
        errdefer allocator.free(interactions);
        const scrolls = try allocator.alloc(ScrollState, capacity);
        @memset(entries, .{});
        @memset(interactions, .{});
        @memset(scrolls, .{});
        self.* = .{ .allocator = allocator, .entries = entries, .interactions = interactions, .scrolls = scrolls };
    }

    pub fn deinit(self: *PointerBindings) void {
        self.allocator.free(self.scrolls);
        self.allocator.free(self.interactions);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn pruneScrollStates(self: *PointerBindings, tree: *instance.Tree) void {
        for (self.scrolls[0..self.scroll_limit]) |*state| {
            if (!tree.isActive(state.target) or self.getKind(state.target, .scroll_change) == null) state.* = .{};
        }
        while (self.scroll_limit > 0 and same(self.scrolls[self.scroll_limit - 1].target, .invalid))
            self.scroll_limit -= 1;
    }

    /// Callback references are replaced during builds; observation is retained
    /// until the instance or its on_scroll subscription is removed.
    pub fn scrollObservation(self: *PointerBindings, target: instance.InstanceHandle) *?@import("../render_object/scroll.zig").Metrics {
        for (self.scrolls[0..self.scroll_limit]) |*state| if (same(state.target, target)) return &state.metrics;
        for (self.scrolls, 0..) |*state, index| if (same(state.target, .invalid)) {
            state.target = target;
            self.scroll_limit = @max(self.scroll_limit, index + 1);
            return &state.metrics;
        };
        unreachable; // Each observed target has a live binding.
    }

    pub fn get(self: *const PointerBindings, target: instance.InstanceHandle) ?Handler {
        for (self.entries[0..self.entry_limit]) |entry| if (same(entry.target, target) and entry.handler != null and
            entry.handler.?.kind.primary())
            return entry.handler;
        return null;
    }

    /// State survives callback replacement, but never instance removal or reuse.
    pub fn interactionActive(self: *const PointerBindings, target: instance.InstanceHandle) bool {
        if (self.getKind(target, .interaction_change) == null) return false;
        for (self.interactions) |state| if (same(state.target, target) and state.kind == .interaction_change) return state.active;
        return false;
    }

    pub fn interactionChanged(self: *PointerBindings, tree: *instance.Tree, target: instance.InstanceHandle, kind: HandlerKind, active: bool) bool {
        var empty: ?*InteractionState = null;
        for (self.interactions) |*state| {
            if (!tree.isActive(state.target) or self.getKind(state.target, state.kind) == null)
                state.* = .{};
            if (same(state.target, target) and state.kind == kind) {
                const changed = state.active != active;
                state.active = active;
                return changed;
            }
            if (same(state.target, .invalid)) empty = state;
        }
        // There cannot be more interaction targets than bindings.
        empty.?.* = .{ .target = target, .kind = kind, .active = active };
        // Publish the initial state too: a retained Lua component can replace
        // its observed native instance while keeping its previous signal.
        return true;
    }

    pub fn getKind(self: *const PointerBindings, target: instance.InstanceHandle, kind: HandlerKind) ?Handler {
        for (self.entries[0..self.entry_limit]) |entry| if (same(entry.target, target) and entry.handler != null and
            entry.handler.?.kind == kind) return entry.handler;
        return null;
    }

    pub fn set(
        self: *PointerBindings,
        owner: BuildOwnerHandle,
        target: instance.InstanceHandle,
        handler: Handler,
    ) !?Handler {
        self.revision +%= 1;
        for (self.entries[0..self.entry_limit]) |*entry| if (same(entry.target, target) and entry.handler != null and
            sameBindingKind(entry.handler.?.kind, handler.kind) and
            (handler.kind != .shortcut or std.meta.eql(entry.handler.?.sequence, handler.sequence)) and
            (handler.kind != .command or entry.handler.?.command.eql(handler.command)))
        {
            const old = entry.handler;
            entry.owner = owner;
            entry.handler = handler;
            return old;
        };
        for (self.entries, 0..) |*entry, index| if (entry.handler == null) {
            entry.* = .{ .owner = owner, .target = target, .handler = handler };
            self.entry_limit = @max(self.entry_limit, index + 1);
            return null;
        };
        return error.PointerBindingCapacityExceeded;
    }

    /// Grows storage by at least `additional` entries. Call while
    /// preparing a build so that `set` cannot fail during commit.
    pub fn grow(self: *PointerBindings, additional: usize) !void {
        const old_len = self.entries.len;
        const new_len = @max(old_len + additional, old_len * 2);
        // There are never more interaction or scroll targets than entries.
        self.entries = try self.allocator.realloc(self.entries, new_len);
        @memset(self.entries[old_len..], .{});
        self.interactions = try self.allocator.realloc(self.interactions, new_len);
        @memset(self.interactions[old_len..], .{});
        self.scrolls = try self.allocator.realloc(self.scrolls, new_len);
        @memset(self.scrolls[old_len..], .{});
    }

    pub fn availableAfterReconcile(
        self: *const PointerBindings,
        tree: *instance.Tree,
        owner: BuildOwnerHandle,
    ) usize {
        var count: usize = self.entries.len - self.entry_limit;
        for (self.entries[0..self.entry_limit]) |entry|
            if (entry.handler == null or !tree.isActive(entry.target) or
                (same(entry.owner, owner) and !tree.isRetained(entry.target)))
            {
                count += 1;
            };
        return count;
    }

    pub fn reclaimableForOwner(
        self: *const PointerBindings,
        tree: *instance.Tree,
        owner: BuildOwnerHandle,
    ) usize {
        var count: usize = 0;
        for (self.entries[0..self.entry_limit]) |entry|
            if (entry.handler != null and
                (!tree.isActive(entry.target) or
                    (same(entry.owner, owner) and !tree.isRetained(entry.target))))
            {
                count += 1;
            };
        return count;
    }

    pub fn takeOwner(self: *PointerBindings, owner: BuildOwnerHandle) ?Handler {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.handler != null and same(entry.owner, owner)) {
            self.revision +%= 1;
            const old = entry.handler;
            entry.* = .{};
            self.trim();
            return old;
        };
        return null;
    }

    pub fn takeUnretainedOwner(
        self: *PointerBindings,
        owner: BuildOwnerHandle,
        tree: *instance.Tree,
    ) ?Handler {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.handler != null and
            same(entry.owner, owner) and
            (!tree.isActive(entry.target) or !tree.isRetained(entry.target)))
        {
            self.revision +%= 1;
            const old = entry.handler;
            entry.* = .{};
            self.trim();
            return old;
        };
        return null;
    }

    pub fn remove(self: *PointerBindings, target: instance.InstanceHandle) ?Handler {
        for (self.entries[0..self.entry_limit]) |*entry| if (same(entry.target, target)) {
            self.revision +%= 1;
            const old = entry.handler;
            entry.* = .{};
            self.trim();
            return old;
        };
        return null;
    }

    pub fn takeInactive(self: *PointerBindings, tree: *instance.Tree) ?Handler {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.handler != null and !tree.isActive(entry.target)) {
            self.revision +%= 1;
            const old = entry.handler;
            entry.* = .{};
            self.trim();
            return old;
        };
        return null;
    }

    pub fn takeAny(self: *PointerBindings) ?Handler {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.handler != null) {
            self.revision +%= 1;
            const old = entry.handler;
            entry.* = .{};
            self.trim();
            return old;
        };
        return null;
    }

    fn trim(self: *PointerBindings) void {
        while (self.entry_limit > 0 and self.entries[self.entry_limit - 1].handler == null)
            self.entry_limit -= 1;
    }
};

fn same(a: instance.InstanceHandle, b: instance.InstanceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sameBindingKind(a: HandlerKind, b: HandlerKind) bool {
    return a == b or (a.primary() and b.primary());
}

test "pointer bindings replace, clean removal, and reject stale generations" {
    const Scheduler = @import("../../task/scheduler.zig").Scheduler;
    const RenderTree = @import("../render_object/root.zig").Tree;

    var scheduler: Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 6, 1, 0);
    defer scheduler.deinit();
    const window_scope = try scheduler.createScope(scheduler.application_scope);
    var renders: RenderTree = undefined;
    try renders.init(std.testing.allocator, 1);
    defer renders.deinit();
    var tree: instance.Tree = undefined;
    try tree.init(std.testing.allocator, &scheduler, &renders, window_scope, 1);
    defer tree.deinit();
    var bindings: PointerBindings = undefined;
    try bindings.init(std.testing.allocator, 2);
    defer bindings.deinit();

    try tree.reconcile(&.{.{ .id = 1, .parent = null, .object = .{ .box = .{} } }});
    const original = tree.handleForId(1).?;
    const owner: BuildOwnerHandle = .{ .slot = 0, .generation = 1 };
    const first: Handle = .{ .slot = 10, .generation = 1 };
    const second: Handle = .{ .slot = 11, .generation = 2 };
    try std.testing.expect((try bindings.set(owner, original, .{ .id = first })) == null);
    try std.testing.expectEqual(@as(?Handler, .{ .id = first }), bindings.get(original));
    try std.testing.expectEqual(
        @as(?Handler, .{ .id = first }),
        try bindings.set(owner, original, .{ .id = second, .kind = .button }),
    );

    _ = try bindings.set(owner, original, .{ .id = first, .kind = .scroll_change });
    const metrics: @import("../render_object/scroll.zig").Metrics = .{
        .axis = .vertical,
        .offset = 17,
        .viewport = 40,
        .content = 150,
        .max_offset = 110,
    };
    bindings.scrollObservation(original).* = metrics;
    bindings.pruneScrollStates(&tree);
    try std.testing.expectEqual(@as(usize, 1), bindings.scroll_limit);
    try std.testing.expectEqual(metrics, bindings.scrollObservation(original).*.?);

    try tree.reconcile(&.{});
    try std.testing.expectEqual(
        @as(?Handler, .{ .id = second, .kind = .button }),
        bindings.takeInactive(&tree),
    );
    try std.testing.expectEqual(first, bindings.takeInactive(&tree).?.id);
    try std.testing.expectEqual(@as(usize, 0), bindings.entry_limit);
    bindings.pruneScrollStates(&tree);
    try std.testing.expectEqual(@as(usize, 0), bindings.scroll_limit);
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try tree.reconcile(&.{.{ .id = 1, .parent = null, .object = .{ .box = .{} } }});
    const replacement = tree.handleForId(1).?;
    try std.testing.expect(replacement.generation != original.generation);
    try std.testing.expect(bindings.get(original) == null);
    _ = try bindings.set(owner, replacement, .{ .id = second, .kind = .scroll_change });
    try std.testing.expectEqual(null, bindings.scrollObservation(replacement).*);
    try std.testing.expectEqual(@as(usize, 1), bindings.scroll_limit);
    _ = bindings.takeAny();
    bindings.pruneScrollStates(&tree);
    try std.testing.expectEqual(@as(usize, 0), bindings.scroll_limit);

    try tree.reconcile(&.{});
    try scheduler.applyQueuedCancellations();
    try tree.collectRetired();
    try scheduler.destroyScope(window_scope);
}

test "text input callback kinds coexist and retire independently" {
    var bindings: PointerBindings = undefined;
    try bindings.init(std.testing.allocator, 2);
    defer bindings.deinit();
    const owner: BuildOwnerHandle = .{ .slot = 2, .generation = 3 };
    const target: instance.InstanceHandle = .{ .slot = 4, .generation = 5 };
    const change: Handler = .{ .id = .{ .slot = 6, .generation = 7 }, .kind = .text_input_change };
    const command: Handler = .{ .id = .{ .slot = 8, .generation = 9 }, .kind = .text_input_command };

    try std.testing.expect((try bindings.set(owner, target, change)) == null);
    try std.testing.expect((try bindings.set(owner, target, command)) == null);
    try std.testing.expectEqual(change, bindings.getKind(target, .text_input_change).?);
    try std.testing.expectEqual(command, bindings.getKind(target, .text_input_command).?);
    try std.testing.expect(bindings.get(target) == null);
    try std.testing.expect(bindings.takeOwner(owner) != null);
    try std.testing.expect(bindings.takeOwner(owner) != null);
    try std.testing.expect(bindings.takeOwner(owner) == null);
}

test "binding scan bounds shrink across holes without losing other owners" {
    var bindings: PointerBindings = undefined;
    try bindings.init(std.testing.allocator, 8);
    defer bindings.deinit();
    const owner: BuildOwnerHandle = .{ .slot = 1, .generation = 1 };
    const other: BuildOwnerHandle = .{ .slot = 2, .generation = 1 };
    const first: instance.InstanceHandle = .{ .slot = 10, .generation = 1 };
    const middle: instance.InstanceHandle = .{ .slot = 20, .generation = 1 };
    const last: instance.InstanceHandle = .{ .slot = 30, .generation = 1 };
    try std.testing.expectEqual(@as(usize, 0), bindings.entry_limit);
    _ = try bindings.set(owner, first, .{ .id = first });
    _ = try bindings.set(other, middle, .{ .id = middle });
    _ = try bindings.set(owner, last, .{ .id = last });
    try std.testing.expectEqual(middle, bindings.takeOwner(other).?.id);
    try std.testing.expectEqual(@as(usize, 3), bindings.entry_limit);
    try std.testing.expectEqual(last, bindings.get(last).?.id);
    try std.testing.expectEqual(last, bindings.remove(last).?.id);
    try std.testing.expectEqual(@as(usize, 1), bindings.entry_limit);
    _ = try bindings.set(other, middle, .{ .id = middle });
    try std.testing.expectEqual(@as(usize, 2), bindings.entry_limit);
    try std.testing.expectEqual(first, bindings.takeAny().?.id);
    try std.testing.expectEqual(middle, bindings.takeAny().?.id);
    try std.testing.expectEqual(@as(usize, 0), bindings.entry_limit);
    _ = try bindings.set(owner, last, .{ .id = last });
    try std.testing.expectEqual(last, bindings.get(last).?.id);
}
