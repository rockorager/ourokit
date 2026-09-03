const std = @import("std");
const Handle = @import("../core/handle.zig").Handle;

pub const WorkspaceHandle = Handle;

pub const State = packed struct(u8) {
    active: bool = false,
    urgent: bool = false,
    hidden: bool = false,
    _padding: u5 = 0,
};

pub const Capabilities = packed struct(u8) {
    activate: bool = false,
    deactivate: bool = false,
    remove: bool = false,
    assign: bool = false,
    _padding: u4 = 0,
};

pub const Snapshot = struct {
    handle: WorkspaceHandle,
    id: ?[]u8 = null,
    name: []u8,
    coordinates: []u32,
    state: State = .{},
    capabilities: Capabilities = .{},

    fn clone(self: Snapshot, allocator: std.mem.Allocator) !Snapshot {
        const id = if (self.id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (id) |value| allocator.free(value);
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const coordinates = try allocator.dupe(u32, self.coordinates);
        return .{
            .handle = self.handle,
            .id = id,
            .name = name,
            .coordinates = coordinates,
            .state = self.state,
            .capabilities = self.capabilities,
        };
    }

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.id) |id| allocator.free(id);
        allocator.free(self.name);
        allocator.free(self.coordinates);
        self.* = undefined;
    }
};

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    pending: Snapshot = undefined,
};

pub const ActionKind = enum { activate, deactivate, remove };

pub const Action = struct {
    workspace: WorkspaceHandle,
    kind: ActionKind,
};

/// Process-owned workspace state shared by the Wayland adapter and Lua source
/// generations. Protocol events mutate pending slots; only `commit` publishes
/// a snapshot, preserving ext-workspace-v1's atomic `done` boundary.
pub const Store = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    published: []Snapshot,
    published_count: usize = 0,
    actions: []Action,
    action_head: usize = 0,
    action_count: usize = 0,
    available: bool = false,
    revision: u64 = 0,

    pub fn init(
        self: *Store,
        allocator: std.mem.Allocator,
        workspace_capacity: usize,
        action_capacity: usize,
    ) !void {
        if (workspace_capacity == 0 or action_capacity == 0 or workspace_capacity > std.math.maxInt(u32))
            return error.InvalidWorkspaceCapacity;
        const slots = try allocator.alloc(Slot, workspace_capacity);
        errdefer allocator.free(slots);
        const published = try allocator.alloc(Snapshot, workspace_capacity);
        errdefer allocator.free(published);
        const actions = try allocator.alloc(Action, action_capacity);
        @memset(slots, .{});
        self.* = .{
            .allocator = allocator,
            .slots = slots,
            .published = published,
            .actions = actions,
        };
    }

    pub fn deinit(self: *Store) void {
        for (self.slots) |*slot| if (slot.active) slot.pending.deinit(self.allocator);
        for (self.published[0..self.published_count]) |*workspace| workspace.deinit(self.allocator);
        self.allocator.free(self.actions);
        self.allocator.free(self.published);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn create(self: *Store) !WorkspaceHandle {
        for (self.slots, 0..) |*slot, index| if (!slot.active) {
            var generation = slot.generation +% 1;
            if (generation == 0) generation = 1;
            const handle: WorkspaceHandle = .{ .slot = @intCast(index), .generation = generation };
            const name = try self.allocator.alloc(u8, 0);
            errdefer self.allocator.free(name);
            const coordinates = try self.allocator.alloc(u32, 0);
            slot.* = .{
                .generation = generation,
                .active = true,
                .pending = .{
                    .handle = handle,
                    .name = name,
                    .coordinates = coordinates,
                },
            };
            return handle;
        };
        return error.WorkspaceCapacityExceeded;
    }

    pub fn setId(self: *Store, handle: WorkspaceHandle, value: []const u8) !void {
        const workspace = &(try self.activeSlot(handle)).pending;
        const replacement = try self.allocator.dupe(u8, value);
        if (workspace.id) |id| self.allocator.free(id);
        workspace.id = replacement;
    }

    pub fn setName(self: *Store, handle: WorkspaceHandle, value: []const u8) !void {
        const workspace = &(try self.activeSlot(handle)).pending;
        const replacement = try self.allocator.dupe(u8, value);
        self.allocator.free(workspace.name);
        workspace.name = replacement;
    }

    pub fn setCoordinates(self: *Store, handle: WorkspaceHandle, value: []const u32) !void {
        const workspace = &(try self.activeSlot(handle)).pending;
        const replacement = try self.allocator.dupe(u32, value);
        self.allocator.free(workspace.coordinates);
        workspace.coordinates = replacement;
    }

    pub fn setState(self: *Store, handle: WorkspaceHandle, value: State) !void {
        (try self.activeSlot(handle)).pending.state = value;
    }

    pub fn setCapabilities(self: *Store, handle: WorkspaceHandle, value: Capabilities) !void {
        (try self.activeSlot(handle)).pending.capabilities = value;
    }

    pub fn remove(self: *Store, handle: WorkspaceHandle) !void {
        const slot = try self.activeSlot(handle);
        slot.pending.deinit(self.allocator);
        slot.active = false;
    }

    pub fn commit(self: *Store) !void {
        var next = try self.allocator.alloc(Snapshot, self.slots.len);
        var count: usize = 0;
        errdefer {
            for (next[0..count]) |*workspace| workspace.deinit(self.allocator);
            self.allocator.free(next);
        }
        for (self.slots) |slot| if (slot.active) {
            next[count] = try slot.pending.clone(self.allocator);
            count += 1;
        };
        for (self.published[0..self.published_count]) |*workspace| workspace.deinit(self.allocator);
        self.allocator.free(self.published);
        self.published = next;
        self.published_count = count;
        self.available = true;
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    pub fn unavailable(self: *Store) void {
        for (self.slots) |*slot| if (slot.active) {
            slot.pending.deinit(self.allocator);
            slot.active = false;
        };
        for (self.published[0..self.published_count]) |*workspace| workspace.deinit(self.allocator);
        self.published_count = 0;
        self.available = false;
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    pub fn snapshot(self: *const Store) []const Snapshot {
        return self.published[0..self.published_count];
    }

    pub fn request(self: *Store, action: Action) !void {
        var published = false;
        for (self.snapshot()) |workspace| if (sameHandle(workspace.handle, action.workspace)) {
            published = true;
            break;
        };
        if (!published) return error.StaleWorkspace;
        if (self.action_count == self.actions.len) return error.WorkspaceActionCapacityExceeded;
        const tail = (self.action_head + self.action_count) % self.actions.len;
        self.actions[tail] = action;
        self.action_count += 1;
    }

    pub fn takeAction(self: *Store) ?Action {
        if (self.action_count == 0) return null;
        const action = self.actions[self.action_head];
        self.action_head = (self.action_head + 1) % self.actions.len;
        self.action_count -= 1;
        return action;
    }

    fn activeSlot(self: *Store, handle: WorkspaceHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleWorkspace;
        const candidate = &self.slots[handle.slot];
        if (!candidate.active or candidate.generation != handle.generation)
            return error.StaleWorkspace;
        return candidate;
    }
};

fn sameHandle(a: WorkspaceHandle, b: WorkspaceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "workspace state publishes only at protocol done boundaries" {
    var store: Store = undefined;
    try store.init(std.testing.allocator, 2, 2);
    defer store.deinit();

    const workspace = try store.create();
    try store.setName(workspace, "One");
    try std.testing.expectEqual(@as(usize, 0), store.snapshot().len);
    try store.commit();
    try std.testing.expectEqualStrings("One", store.snapshot()[0].name);

    try store.setName(workspace, "Two");
    try std.testing.expectEqualStrings("One", store.snapshot()[0].name);
    try store.commit();
    try std.testing.expectEqualStrings("Two", store.snapshot()[0].name);
}
