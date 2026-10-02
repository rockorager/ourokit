const std = @import("std");
const build_owner = @import("../instance/build_owner.zig");
const instance = @import("../instance/tree.zig");
const Session = @import("session.zig").Session;
const Controller = @import("controller.zig").Controller;

pub const ValueMode = enum { uncontrolled, controlled };

pub const Behavior = struct {
    controller: ?*Controller = null,
    enabled: bool = true,
    read_only: bool = false,
    /// Direct keyboard/IME entry only; native editing commands remain enabled.
    text_entry: bool = true,
    caret_blink: bool = true,
    autofocus: bool = false,
    key_bindings: @import("keymap.zig").Keymap = .{},
    border_color: ?@import("../../core/color.zig").Color = null,
    focus_color: ?@import("../../core/color.zig").Color = null,
    /// Masked field bound to an authentication prompt: submit sends the text
    /// to this destination instead of Lua.
    secret: ?@import("secret.zig").Secret = null,
};

fn sameSecret(a: ?@import("secret.zig").Secret, b: ?@import("secret.zig").Secret) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

const Entry = struct {
    owner: build_owner.BuildOwnerHandle = .invalid,
    target: instance.InstanceHandle = .invalid,
    content: instance.InstanceHandle = .invalid,
    session: ?Session = null,
    session_generation: u64 = 0,
    behavior: Behavior = .{},
    active: bool = false,
    seen: bool = false,
    autofocus_pending: bool = false,
    controller_mount: ?Controller.Mount = null,
};

/// Retained TextInput state keyed by generation-checked instance identity.
/// Declarative rebuilds rediscover entries but do not replace their editing
/// sessions. Omission or instance retirement deterministically destroys owned
/// text and composition state.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    entry_limit: usize = 0,
    controller_host: ?Controller.Host = null,

    pub fn init(self: *Registry, allocator: std.mem.Allocator, capacity: usize) !void {
        if (capacity == 0) return error.InvalidTextInputCapacity;
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        self.* = .{ .allocator = allocator, .entries = entries };
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries[0..self.entry_limit]) |entry| std.debug.assert(!entry.active);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn availableForOwner(self: *const Registry, owner: build_owner.BuildOwnerHandle) usize {
        var count: usize = self.entries.len - self.entry_limit;
        for (self.entries[0..self.entry_limit]) |entry| if (!entry.active or same(entry.owner, owner)) {
            count += 1;
        };
        return count;
    }

    pub fn availableForOwnerRetaining(
        self: *const Registry,
        owner: build_owner.BuildOwnerHandle,
        tree: *instance.Tree,
    ) usize {
        var count: usize = self.entries.len - self.entry_limit;
        for (self.entries[0..self.entry_limit]) |entry| if (!entry.active or
            (same(entry.owner, owner) and
                (!tree.isActive(entry.target) or !tree.isRetained(entry.target))))
        {
            count += 1;
        };
        return count;
    }

    pub fn beginOwner(self: *Registry, owner: build_owner.BuildOwnerHandle) void {
        for (self.entries[0..self.entry_limit]) |*entry| {
            if (entry.active and same(entry.owner, owner)) entry.seen = false;
        }
    }

    pub fn beginOwnerRetaining(
        self: *Registry,
        owner: build_owner.BuildOwnerHandle,
        tree: *instance.Tree,
    ) void {
        for (self.entries[0..self.entry_limit]) |*entry| {
            if (entry.active and same(entry.owner, owner))
                entry.seen = tree.isActive(entry.target) and tree.isRetained(entry.target);
        }
    }

    pub fn mount(
        self: *Registry,
        owner: build_owner.BuildOwnerHandle,
        target: instance.InstanceHandle,
        content_handle: instance.InstanceHandle,
        initial: []const u8,
    ) !void {
        var prepared: ?Session = try Session.init(self.allocator, initial);
        defer if (prepared) |*session_value| session_value.deinit();
        try self.prepareMount(target, .uncontrolled, &prepared);
        try self.mountPrepared(owner, target, content_handle, .uncontrolled, .{}, &prepared);
    }

    /// Prepares all allocation and selection normalization before a retained
    /// reconciliation commit starts mutating registries.
    pub fn prepareMount(
        self: *Registry,
        target: instance.InstanceHandle,
        mode: ValueMode,
        prepared: *?Session,
    ) !void {
        const candidate = if (prepared.*) |*session_value| session_value else return error.TextInputSessionMissing;
        const entry = self.find(target) orelse return;
        if (entry.session.?.model.multiline == candidate.model.multiline and (mode == .uncontrolled or std.mem.eql(
            u8,
            entry.session.?.model.text(),
            candidate.model.text(),
        ))) return;
        _ = candidate.model.setSelectionClamped(entry.session.?.model.selection);
        candidate.revision = entry.session.?.revision +% 1;
    }

    /// Moves a preallocated session into a new slot without allocating during
    /// reconciliation commit. Rediscovery preserves the retained session and
    /// leaves `prepared` for the caller to destroy.
    pub fn mountPrepared(
        self: *Registry,
        owner: build_owner.BuildOwnerHandle,
        target: instance.InstanceHandle,
        content_handle: instance.InstanceHandle,
        mode: ValueMode,
        behavior: Behavior,
        prepared: *?Session,
    ) !void {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.active and same(entry.target, target)) {
            entry.owner = owner;
            entry.content = content_handle;
            if (entry.behavior.enabled != behavior.enabled or entry.behavior.read_only != behavior.read_only or
                (entry.behavior.text_entry != behavior.text_entry and
                    (!behavior.text_entry or !entry.session.?.model.explicit_group)))
                entry.session.?.model.breakUndoGroup();
            if (!behavior.enabled) entry.session.?.endSelectionDrag();
            entry.seen = true;
            // A new prompt or a mask change starts from a fresh, wiped buffer.
            const replace_secret = entry.session.?.model.isSecret() != prepared.*.?.model.isSecret() or
                !sameSecret(entry.behavior.secret, behavior.secret);
            self.setController(entry, behavior.controller);
            entry.behavior = behavior;
            if (replace_secret or entry.session.?.model.multiline != prepared.*.?.model.multiline or (mode == .controlled and !std.mem.eql(
                u8,
                entry.session.?.model.text(),
                prepared.*.?.model.text(),
            ))) {
                entry.session.?.deinit();
                entry.session = prepared.*.?;
                entry.session_generation +%= 1;
                prepared.* = null;
            }
            return;
        };
        for (self.entries, 0..) |*entry, index| if (!entry.active) {
            entry.* = .{
                .owner = owner,
                .target = target,
                .content = content_handle,
                .session = prepared.* orelse return error.TextInputSessionMissing,
                .behavior = behavior,
                .active = true,
                .seen = true,
                .autofocus_pending = behavior.enabled and behavior.autofocus,
            };
            self.entry_limit = @max(self.entry_limit, index + 1);
            self.setController(entry, behavior.controller);
            prepared.* = null;
            return;
        };
        return error.TextInputCapacityExceeded;
    }

    pub fn finishOwner(self: *Registry, owner: build_owner.BuildOwnerHandle) void {
        for (self.entries[0..self.entry_limit]) |*entry|
            if (entry.active and same(entry.owner, owner) and !entry.seen) destroy(entry);
        while (self.entry_limit > 0 and !self.entries[self.entry_limit - 1].active)
            self.entry_limit -= 1;
    }

    pub fn removeInactive(self: *Registry, tree: *instance.Tree) void {
        for (self.entries[0..self.entry_limit]) |*entry|
            if (entry.active and !tree.isActive(entry.target)) destroy(entry);
        while (self.entry_limit > 0 and !self.entries[self.entry_limit - 1].active)
            self.entry_limit -= 1;
    }

    pub fn clear(self: *Registry) void {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.active) destroy(entry);
        self.entry_limit = 0;
    }

    pub fn contains(self: *const Registry, target: instance.InstanceHandle) bool {
        return self.find(target) != null;
    }

    pub fn session(self: *Registry, target: instance.InstanceHandle) !*Session {
        return &(self.find(target) orelse return error.TextInputNotFound).session.?;
    }

    pub fn content(self: *const Registry, target: instance.InstanceHandle) !instance.InstanceHandle {
        return (self.find(target) orelse return error.TextInputNotFound).content;
    }

    /// Whether any mounted field sends its text to an authentication prompt.
    pub fn hasSecret(self: *const Registry) bool {
        for (self.entries[0..self.entry_limit]) |entry| if (entry.active and entry.behavior.secret != null) return true;
        return false;
    }

    pub fn getBehavior(self: *const Registry, target: instance.InstanceHandle) !Behavior {
        return (self.find(target) orelse return error.TextInputNotFound).behavior;
    }

    pub fn sessionGeneration(self: *const Registry, target: instance.InstanceHandle) !u64 {
        return (self.find(target) orelse return error.TextInputNotFound).session_generation;
    }

    pub const Mounted = struct {
        target: instance.InstanceHandle,
        content: instance.InstanceHandle,
        session: *Session,
    };

    pub fn mountedAt(self: *Registry, index: usize) ?Mounted {
        if (index >= self.entries.len or !self.entries[index].active) return null;
        const entry = &self.entries[index];
        return .{
            .target = entry.target,
            .content = entry.content,
            .session = &entry.session.?,
        };
    }

    pub fn slotCount(self: *const Registry) usize {
        return self.entry_limit;
    }

    /// Returns autofocus once, only for a newly mounted input.
    pub fn takeAutofocus(self: *Registry) ?instance.InstanceHandle {
        for (self.entries[0..self.entry_limit]) |*entry| if (entry.active and entry.autofocus_pending) {
            entry.autofocus_pending = false;
            return entry.target;
        };
        return null;
    }

    fn setController(self: *Registry, entry: *Entry, controller: ?*Controller) void {
        if (entry.controller_mount) |*mounted| {
            if (mounted.controller == controller) return;
            mounted.controller.detach(mounted);
            entry.controller_mount = null;
        }
        if (controller) |value| {
            entry.controller_mount = .{ .controller = value, .registry = self, .target = entry.target };
            value.attach(&entry.controller_mount.?);
        }
    }

    fn destroy(entry: *Entry) void {
        if (entry.controller_mount) |*mounted| mounted.controller.detach(mounted);
        entry.session.?.deinit();
        entry.* = .{};
    }

    fn find(self: anytype, target: instance.InstanceHandle) ?if (@TypeOf(self) == *Registry) *Entry else *const Entry {
        for (self.entries[0..self.entry_limit]) |*entry|
            if (entry.active and same(entry.target, target)) return entry;
        return null;
    }
};

fn same(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "text input scan bounds retain higher sessions across holes and regrowth" {
    var registry: Registry = undefined;
    try registry.init(std.testing.allocator, 8);
    defer registry.deinit();
    defer registry.clear();
    const owner: build_owner.BuildOwnerHandle = .{ .slot = 1, .generation = 1 };
    const other: build_owner.BuildOwnerHandle = .{ .slot = 2, .generation = 1 };
    const first: instance.InstanceHandle = .{ .slot = 10, .generation = 1 };
    const middle: instance.InstanceHandle = .{ .slot = 20, .generation = 1 };
    const last: instance.InstanceHandle = .{ .slot = 30, .generation = 1 };
    try std.testing.expectEqual(@as(usize, 0), registry.slotCount());
    try registry.mount(owner, first, first, "first");
    try registry.mount(other, middle, middle, "middle");
    try registry.mount(owner, last, last, "last");
    registry.beginOwner(other);
    registry.finishOwner(other);
    try std.testing.expectEqual(@as(usize, 3), registry.slotCount());
    try std.testing.expectEqual(@as(usize, 6), registry.availableForOwner(other));
    try std.testing.expectEqualStrings("last", (try registry.session(last)).model.text());
    registry.beginOwner(owner);
    try registry.mount(owner, first, first, "ignored");
    registry.finishOwner(owner);
    try std.testing.expectEqual(@as(usize, 1), registry.slotCount());
    try registry.mount(other, middle, middle, "new");
    try std.testing.expectEqualStrings("new", registry.mountedAt(1).?.session.model.text());
    registry.clear();
    try std.testing.expectEqual(@as(usize, 0), registry.slotCount());
    try registry.mount(owner, last, last, "fresh");
    try std.testing.expectEqualStrings("fresh", (try registry.session(last)).model.text());
}

test "retained sessions survive rediscovery and dispose with their owner" {
    var registry: Registry = undefined;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const owner: build_owner.BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const content: instance.InstanceHandle = .{ .slot = 5, .generation = 6 };

    registry.beginOwner(owner);
    try registry.mount(owner, target, content, "initial");
    registry.finishOwner(owner);
    _ = try (try registry.session(target)).model.replaceSelection(" edited");
    registry.beginOwner(owner);
    try registry.mount(owner, target, content, "replacement must not reset state");
    registry.finishOwner(owner);
    try std.testing.expectEqualStrings("initial edited", (try registry.session(target)).model.text());

    registry.beginOwner(owner);
    registry.finishOwner(owner);
    try std.testing.expect(!registry.contains(target));
}

test "prepared mount moves new sessions and leaves rediscovered state untouched" {
    var registry: Registry = undefined;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const owner: build_owner.BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const content: instance.InstanceHandle = .{ .slot = 5, .generation = 6 };

    var initial: ?Session = try Session.init(std.testing.allocator, "initial");
    try registry.prepareMount(target, .uncontrolled, &initial);
    try registry.mountPrepared(owner, target, content, .uncontrolled, .{}, &initial);
    try std.testing.expect(initial == null);
    _ = try (try registry.session(target)).model.replaceSelection(" retained");

    var replacement: ?Session = try Session.init(std.testing.allocator, "replacement");
    defer if (replacement) |*session| session.deinit();
    try registry.prepareMount(target, .uncontrolled, &replacement);
    try registry.mountPrepared(owner, target, content, .uncontrolled, .{}, &replacement);
    try std.testing.expect(replacement != null);
    try std.testing.expectEqualStrings("initial retained", (try registry.session(target)).model.text());
    registry.clear();
}

test "autofocus is offered once for a newly mounted enabled input" {
    var registry: Registry = undefined;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const owner: build_owner.BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const content: instance.InstanceHandle = .{ .slot = 5, .generation = 6 };
    var initial: ?Session = try Session.init(std.testing.allocator, "initial");
    try registry.mountPrepared(owner, target, content, .uncontrolled, .{ .autofocus = true }, &initial);
    try std.testing.expectEqual(target, registry.takeAutofocus().?);
    try std.testing.expect(registry.takeAutofocus() == null);

    var rebuilt: ?Session = try Session.init(std.testing.allocator, "rebuilt");
    defer if (rebuilt) |*session| session.deinit();
    try registry.mountPrepared(owner, target, content, .uncontrolled, .{ .autofocus = true }, &rebuilt);
    try std.testing.expect(registry.takeAutofocus() == null);
    registry.clear();
}

test "controlled mounts replace changed values and preserve valid selection" {
    var registry: Registry = undefined;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const owner: build_owner.BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const content: instance.InstanceHandle = .{ .slot = 5, .generation = 6 };
    try registry.mount(owner, target, content, "abcde");
    _ = try (try registry.session(target)).typeText("f");
    _ = try (try registry.session(target)).model.setSelection(.{ .anchor = 2, .extent = 4 });

    var equal: ?Session = try Session.init(std.testing.allocator, "abcdef");
    defer if (equal) |*session_value| session_value.deinit();
    try registry.prepareMount(target, .controlled, &equal);
    try registry.mountPrepared(owner, target, content, .controlled, .{}, &equal);
    try std.testing.expectEqual(@as(usize, 2), (try registry.session(target)).model.selection.anchor);
    try std.testing.expect((try registry.session(target)).model.undo());
    try std.testing.expectEqualStrings("abcde", (try registry.session(target)).model.text());
    try std.testing.expect((try registry.session(target)).model.redo());
    try std.testing.expectEqualStrings("abcdef", (try registry.session(target)).model.text());
    _ = try (try registry.session(target)).model.setSelection(.{ .anchor = 2, .extent = 4 });

    var changed: ?Session = try Session.init(std.testing.allocator, "abc");
    defer if (changed) |*session_value| session_value.deinit();
    try registry.prepareMount(target, .controlled, &changed);
    try registry.mountPrepared(owner, target, content, .controlled, .{}, &changed);
    const retained = try registry.session(target);
    try std.testing.expectEqualStrings("abc", retained.model.text());
    try std.testing.expectEqual(@as(usize, 2), retained.model.selection.anchor);
    try std.testing.expectEqual(@as(usize, 3), retained.model.selection.extent);
    try std.testing.expect(!retained.model.undo());
    try std.testing.expect(!retained.model.redo());
    registry.clear();
}

test "rediscovery updates text input behavior without resetting its session" {
    var registry: Registry = undefined;
    try registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const owner: build_owner.BuildOwnerHandle = .{ .slot = 1, .generation = 2 };
    const target: instance.InstanceHandle = .{ .slot = 3, .generation = 4 };
    const content: instance.InstanceHandle = .{ .slot = 5, .generation = 6 };
    try registry.mount(owner, target, content, "initial");
    _ = try (try registry.session(target)).model.replaceSelection(" edit");

    var candidate: ?Session = try Session.init(std.testing.allocator, "ignored");
    defer if (candidate) |*session_value| session_value.deinit();
    try registry.prepareMount(target, .uncontrolled, &candidate);
    try registry.mountPrepared(
        owner,
        target,
        content,
        .uncontrolled,
        .{ .read_only = true },
        &candidate,
    );
    try std.testing.expect((try registry.getBehavior(target)).read_only);
    try std.testing.expectEqualStrings("initial edit", (try registry.session(target)).model.text());
    registry.clear();
}
