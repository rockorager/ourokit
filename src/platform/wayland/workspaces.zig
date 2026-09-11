const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayland_protocol");
const shell_workspaces = @import("../../shell/workspaces.zig");

const Handle = wayring.objects.Handle;
const Core = wayring.client.Core(protocol);

const WorkspaceSlot = struct {
    protocol_handle: ?Handle = null,
    model_handle: shell_workspaces.WorkspaceHandle = .invalid,
    group: ?Handle = null,
};

const GroupSlot = struct {
    protocol_handle: ?Handle = null,
    outputs: std.ArrayListUnmanaged(Handle) = .empty,
};

const Output = struct { handle: Handle, name: []u8 };

/// Optional ext-workspace-v1 adapter. Registry discovery is passive; `enable`
/// is the only operation that binds the manager, so ordinary Ouro clients do
/// not negotiate this protocol.
pub const Client = struct {
    allocator: std.mem.Allocator,
    store: *shell_workspaces.Store,
    enabled: bool = false,
    global_name: ?u32 = null,
    global_version: u32 = 0,
    manager: ?Handle = null,
    groups: []GroupSlot,
    workspace_slots: []WorkspaceSlot,
    outputs: std.ArrayListUnmanaged(Output) = .empty,
    batch_pending: bool = false,

    pub fn init(
        self: *Client,
        allocator: std.mem.Allocator,
        store: *shell_workspaces.Store,
        workspace_capacity: usize,
    ) !void {
        const groups = try allocator.alloc(GroupSlot, workspace_capacity);
        errdefer allocator.free(groups);
        const workspace_slots = try allocator.alloc(WorkspaceSlot, workspace_capacity);
        @memset(groups, .{});
        @memset(workspace_slots, .{});
        self.* = .{
            .allocator = allocator,
            .store = store,
            .groups = groups,
            .workspace_slots = workspace_slots,
        };
    }

    pub fn deinit(self: *Client) void {
        for (self.groups) |*group| group.outputs.deinit(self.allocator);
        for (self.outputs.items) |output| self.allocator.free(output.name);
        self.outputs.deinit(self.allocator);
        self.allocator.free(self.workspace_slots);
        self.allocator.free(self.groups);
        self.* = undefined;
    }

    pub fn observeGlobal(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        registry: Handle,
        name: u32,
        version: u32,
    ) !void {
        self.global_name = name;
        self.global_version = version;
        if (self.enabled) try self.bind(objects, transmit, registry);
    }

    pub fn removeGlobal(self: *Client, name: u32) void {
        if (self.global_name != null and self.global_name.? == name) {
            self.global_name = null;
            self.global_version = 0;
        }
    }

    pub fn enable(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        registry: Handle,
    ) !bool {
        if (self.enabled) return false;
        self.enabled = true;
        if (self.global_name == null) return false;
        try self.bind(objects, transmit, registry);
        return true;
    }

    fn bind(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        registry: Handle,
    ) !void {
        if (self.manager != null) return;
        self.manager = try Core.bind(
            objects,
            transmit,
            registry,
            self.global_name.?,
            &protocol.ext_workspace_manager_v1.info,
            @min(self.global_version, 1),
            null,
        );
    }

    pub fn managerEvent(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const manager = self.manager orelse return error.WorkspaceManagerUnavailable;
        switch (try wayring.client.decodeEvent(
            protocol.ext_workspace_manager_v1,
            objects,
            manager,
            message,
            fds,
        )) {
            .workspace_group => |event| {
                self.batch_pending = true;
                const slot = self.freeGroupSlot() orelse return error.WorkspaceGroupCapacityExceeded;
                slot.protocol_handle = (try protocol.ext_workspace_manager_v1.admit_event_workspace_group(
                    objects,
                    manager,
                    event,
                    .{},
                )).workspace_group;
            },
            .workspace => |event| {
                self.batch_pending = true;
                const slot = self.freeWorkspaceSlot() orelse return error.WorkspaceCapacityExceeded;
                const model_handle = try self.store.create();
                errdefer self.store.remove(model_handle) catch {};
                const protocol_handle = (try protocol.ext_workspace_manager_v1.admit_event_workspace(
                    objects,
                    manager,
                    event,
                    .{},
                )).workspace;
                slot.* = .{
                    .protocol_handle = protocol_handle,
                    .model_handle = model_handle,
                };
            },
            .done => {
                try self.updateWorkspaceOutputs();
                try self.store.commit();
                self.batch_pending = false;
            },
            .finished => {
                self.batch_pending = false;
                self.manager = null;
                try self.releaseChildren(objects, transmit);
                self.store.unavailable();
            },
        }
    }

    pub fn groupEvent(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        object_id: u32,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const slot = self.groupForObject(object_id) orelse return error.UnknownWorkspaceGroup;
        self.batch_pending = true;
        switch (try wayring.client.decodeEvent(
            protocol.ext_workspace_group_handle_v1,
            objects,
            slot.protocol_handle.?,
            message,
            fds,
        )) {
            .output_enter => |event| try self.addGroupOutput(slot, objects.namespace.lookupHandle(event.output) orelse return error.UnknownOutput),
            .output_leave => |event| self.removeGroupOutput(slot, objects.namespace.lookupHandle(event.output) orelse return error.UnknownOutput),
            .workspace_enter => |event| {
                const workspace = self.workspaceForObject(event.workspace) orelse return error.UnknownWorkspace;
                workspace.group = slot.protocol_handle;
            },
            .workspace_leave => |event| {
                const workspace = self.workspaceForObject(event.workspace) orelse return error.UnknownWorkspace;
                if (workspace.group != null and handlesEqual(workspace.group.?, slot.protocol_handle.?)) workspace.group = null;
            },
            .removed => {
                try wayring.client.sendRequest(
                    protocol.ext_workspace_group_handle_v1,
                    objects,
                    transmit,
                    slot.protocol_handle.?,
                    .{ .destroy = .{} },
                );
                for (self.workspace_slots) |*workspace| {
                    if (workspace.group != null and handlesEqual(workspace.group.?, slot.protocol_handle.?)) workspace.group = null;
                }
                slot.outputs.clearRetainingCapacity();
                slot.protocol_handle = null;
            },
            else => {},
        }
    }

    pub fn workspaceEvent(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
        object_id: u32,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const slot = self.workspaceForObject(object_id) orelse return error.UnknownWorkspace;
        self.batch_pending = true;
        switch (try wayring.client.decodeEvent(
            protocol.ext_workspace_handle_v1,
            objects,
            slot.protocol_handle.?,
            message,
            fds,
        )) {
            .id => |event| try self.store.setId(slot.model_handle, event.id),
            .name => |event| try self.store.setName(slot.model_handle, event.name),
            .coordinates => |event| try self.setCoordinates(slot.model_handle, event.coordinates),
            .state => |event| try self.store.setState(slot.model_handle, .{
                .active = event.state.contains(protocol.ext_workspace_handle_v1.state.active),
                .urgent = event.state.contains(protocol.ext_workspace_handle_v1.state.urgent),
                .hidden = event.state.contains(protocol.ext_workspace_handle_v1.state.hidden),
            }),
            .capabilities => |event| try self.store.setCapabilities(slot.model_handle, .{
                .activate = event.capabilities.contains(protocol.ext_workspace_handle_v1.workspace_capabilities.activate),
                .deactivate = event.capabilities.contains(protocol.ext_workspace_handle_v1.workspace_capabilities.deactivate),
                .remove = event.capabilities.contains(protocol.ext_workspace_handle_v1.workspace_capabilities.remove),
                .assign = event.capabilities.contains(protocol.ext_workspace_handle_v1.workspace_capabilities.assign),
            }),
            .removed => {
                try wayring.client.sendRequest(
                    protocol.ext_workspace_handle_v1,
                    objects,
                    transmit,
                    slot.protocol_handle.?,
                    .{ .destroy = .{} },
                );
                try self.store.remove(slot.model_handle);
                slot.* = .{};
            },
        }
    }

    pub fn serviceActions(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
    ) !bool {
        var sent = false;
        while (self.store.takeAction()) |action| {
            const workspace = self.workspaceForModel(action.workspace) orelse continue;
            const request: protocol.ext_workspace_handle_v1.Request = switch (action.kind) {
                .activate => .{ .activate = .{} },
                .deactivate => .{ .deactivate = .{} },
                .remove => .{ .remove = .{} },
            };
            try wayring.client.sendRequest(
                protocol.ext_workspace_handle_v1,
                objects,
                transmit,
                workspace.protocol_handle.?,
                request,
            );
            sent = true;
        }
        if (sent) try wayring.client.sendRequest(
            protocol.ext_workspace_manager_v1,
            objects,
            transmit,
            self.manager orelse return error.WorkspaceManagerUnavailable,
            .{ .commit = .{} },
        );
        return sent;
    }

    /// Associates an independently owned wl_output name with its generational handle.
    pub fn nameOutput(self: *Client, handle: Handle, name: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, name);
        if (self.outputForHandle(handle)) |output| {
            self.allocator.free(output.name);
            output.name = replacement;
        } else self.outputs.append(self.allocator, .{ .handle = handle, .name = replacement }) catch |err| {
            self.allocator.free(replacement);
            return err;
        };
        if (self.store.available and !self.batch_pending) {
            try self.updateWorkspaceOutputs();
            try self.store.commit();
        }
    }

    pub fn removeOutput(self: *Client, handle: Handle) !void {
        var index: usize = 0;
        while (index < self.outputs.items.len) : (index += 1) if (handlesEqual(self.outputs.items[index].handle, handle)) {
            self.allocator.free(self.outputs.items[index].name);
            _ = self.outputs.swapRemove(index);
            break;
        };
        for (self.groups) |*group| self.removeGroupOutput(group, handle);
        if (self.store.available and !self.batch_pending) {
            try self.updateWorkspaceOutputs();
            try self.store.commit();
        }
    }

    fn setCoordinates(
        self: *Client,
        handle: shell_workspaces.WorkspaceHandle,
        bytes: []const u8,
    ) !void {
        if (bytes.len % @sizeOf(u32) != 0) return error.InvalidWorkspaceCoordinates;
        const coordinates = try self.allocator.alloc(u32, bytes.len / @sizeOf(u32));
        defer self.allocator.free(coordinates);
        for (coordinates, 0..) |*coordinate, index|
            coordinate.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .native);
        try self.store.setCoordinates(handle, coordinates);
    }

    fn releaseChildren(
        self: *Client,
        objects: *wayring.objects.ClientObjects,
        transmit: *wayring.tx.Queue,
    ) !void {
        for (self.workspace_slots) |*slot| if (slot.protocol_handle) |handle| {
            try wayring.client.sendRequest(
                protocol.ext_workspace_handle_v1,
                objects,
                transmit,
                handle,
                .{ .destroy = .{} },
            );
            slot.* = .{};
        };
        for (self.groups) |*slot| if (slot.protocol_handle) |handle| {
            try wayring.client.sendRequest(
                protocol.ext_workspace_group_handle_v1,
                objects,
                transmit,
                handle,
                .{ .destroy = .{} },
            );
            slot.outputs.clearRetainingCapacity();
            slot.protocol_handle = null;
        };
    }

    fn freeGroupSlot(self: *Client) ?*GroupSlot {
        for (self.groups) |*slot| if (slot.protocol_handle == null) return slot;
        return null;
    }

    fn groupForObject(self: *Client, object_id: u32) ?*GroupSlot {
        for (self.groups) |*slot| if (slot.protocol_handle != null and slot.protocol_handle.?.id == object_id) return slot;
        return null;
    }

    fn freeWorkspaceSlot(self: *Client) ?*WorkspaceSlot {
        for (self.workspace_slots) |*slot| if (slot.protocol_handle == null) return slot;
        return null;
    }

    fn workspaceForObject(self: *Client, object_id: u32) ?*WorkspaceSlot {
        for (self.workspace_slots) |*slot|
            if (slot.protocol_handle != null and slot.protocol_handle.?.id == object_id) return slot;
        return null;
    }

    fn workspaceForModel(self: *Client, handle: shell_workspaces.WorkspaceHandle) ?*WorkspaceSlot {
        for (self.workspace_slots) |*slot|
            if (slot.protocol_handle != null and sameHandle(slot.model_handle, handle)) return slot;
        return null;
    }

    fn addGroupOutput(self: *Client, group: *GroupSlot, handle: Handle) !void {
        for (group.outputs.items) |existing| if (handlesEqual(existing, handle)) return;
        try group.outputs.append(self.allocator, handle);
    }

    fn removeGroupOutput(self: *Client, group: *GroupSlot, handle: Handle) void {
        _ = self;
        for (group.outputs.items, 0..) |existing, index| if (handlesEqual(existing, handle)) {
            _ = group.outputs.swapRemove(index);
            return;
        };
    }

    fn outputForHandle(self: *Client, handle: Handle) ?*Output {
        for (self.outputs.items) |*output| if (handlesEqual(output.handle, handle)) return output;
        return null;
    }

    fn updateWorkspaceOutputs(self: *Client) !void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(self.allocator);
        for (self.workspace_slots) |workspace| if (workspace.protocol_handle != null) {
            names.clearRetainingCapacity();
            if (workspace.group) |group_handle| if (self.groupForHandle(group_handle)) |group| {
                for (group.outputs.items) |output_handle| if (self.outputForHandle(output_handle)) |output|
                    try names.append(self.allocator, output.name);
            };
            try self.store.setOutputs(workspace.model_handle, names.items);
        };
    }

    fn groupForHandle(self: *Client, handle: Handle) ?*GroupSlot {
        for (self.groups) |*group| if (group.protocol_handle != null and handlesEqual(group.protocol_handle.?, handle)) return group;
        return null;
    }
};

fn handlesEqual(a: Handle, b: Handle) bool {
    return a.id == b.id and a.generation == b.generation;
}

fn sameHandle(a: shell_workspaces.WorkspaceHandle, b: shell_workspaces.WorkspaceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "workspace groups resolve output names across moves and removal" {
    var store: shell_workspaces.Store = undefined;
    try store.init(std.testing.allocator, 2, 2);
    defer store.deinit();
    var client: Client = undefined;
    try client.init(std.testing.allocator, &store, 2);
    defer client.deinit();

    const first = try store.create();
    const second = try store.create();
    try store.setName(first, "same");
    try store.setName(second, "same");
    const group_a: Handle = .{ .id = 20, .generation = 1 };
    const group_b: Handle = .{ .id = 21, .generation = 1 };
    const output_a: Handle = .{ .id = 7, .generation = 1 };
    const output_b: Handle = .{ .id = 8, .generation = 1 };
    client.groups[0].protocol_handle = group_a;
    client.groups[1].protocol_handle = group_b;
    try client.addGroupOutput(&client.groups[0], output_a);
    try client.addGroupOutput(&client.groups[1], output_b);
    client.workspace_slots[0] = .{ .protocol_handle = .{ .id = 30, .generation = 1 }, .model_handle = first, .group = group_a };
    client.workspace_slots[1] = .{ .protocol_handle = .{ .id = 31, .generation = 1 }, .model_handle = second, .group = group_b };

    try client.nameOutput(output_a, "DP-1");
    try client.nameOutput(output_b, "HDMI-A-1");
    try client.updateWorkspaceOutputs();
    try store.commit();
    try std.testing.expectEqualStrings("DP-1", store.snapshot()[0].outputs[0]);
    try std.testing.expectEqualStrings("HDMI-A-1", store.snapshot()[1].outputs[0]);

    client.workspace_slots[0].group = group_b;
    try client.updateWorkspaceOutputs();
    try store.commit();
    try std.testing.expectEqualStrings("HDMI-A-1", store.snapshot()[0].outputs[0]);
    try client.removeOutput(output_b);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot()[0].outputs.len);
    try std.testing.expectEqual(@as(usize, 0), store.snapshot()[1].outputs.len);

    // Output metadata must not publish an interleaved workspace batch early.
    client.batch_pending = true;
    try store.setName(first, "pending");
    try client.nameOutput(output_a, "renamed");
    try client.removeOutput(output_a);
    try std.testing.expectEqualStrings("same", store.snapshot()[0].name);
    try client.updateWorkspaceOutputs();
    try store.commit();
    client.batch_pending = false;
    try std.testing.expectEqualStrings("pending", store.snapshot()[0].name);
}
