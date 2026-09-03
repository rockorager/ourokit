const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayland_protocol");
const shell_workspaces = @import("../../shell/workspaces.zig");

const Handle = wayring.objects.Handle;
const Core = wayring.client.Core(protocol);

const WorkspaceSlot = struct {
    protocol_handle: ?Handle = null,
    model_handle: shell_workspaces.WorkspaceHandle = .invalid,
};

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
    groups: []?Handle,
    workspace_slots: []WorkspaceSlot,

    pub fn init(
        self: *Client,
        allocator: std.mem.Allocator,
        store: *shell_workspaces.Store,
        workspace_capacity: usize,
    ) !void {
        const groups = try allocator.alloc(?Handle, workspace_capacity);
        errdefer allocator.free(groups);
        const workspace_slots = try allocator.alloc(WorkspaceSlot, workspace_capacity);
        @memset(groups, null);
        @memset(workspace_slots, .{});
        self.* = .{
            .allocator = allocator,
            .store = store,
            .groups = groups,
            .workspace_slots = workspace_slots,
        };
    }

    pub fn deinit(self: *Client) void {
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
                const slot = self.freeGroupSlot() orelse return error.WorkspaceGroupCapacityExceeded;
                slot.* = (try protocol.ext_workspace_manager_v1.admit_event_workspace_group(
                    objects,
                    manager,
                    event,
                    .{},
                )).workspace_group;
            },
            .workspace => |event| {
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
            .done => try self.store.commit(),
            .finished => {
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
        switch (try wayring.client.decodeEvent(
            protocol.ext_workspace_group_handle_v1,
            objects,
            slot.*.?,
            message,
            fds,
        )) {
            .removed => {
                try wayring.client.sendRequest(
                    protocol.ext_workspace_group_handle_v1,
                    objects,
                    transmit,
                    slot.*.?,
                    .{ .destroy = .{} },
                );
                slot.* = null;
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
        for (self.groups) |*slot| if (slot.*) |handle| {
            try wayring.client.sendRequest(
                protocol.ext_workspace_group_handle_v1,
                objects,
                transmit,
                handle,
                .{ .destroy = .{} },
            );
            slot.* = null;
        };
    }

    fn freeGroupSlot(self: *Client) ?*?Handle {
        for (self.groups) |*slot| if (slot.* == null) return slot;
        return null;
    }

    fn groupForObject(self: *Client, object_id: u32) ?*?Handle {
        for (self.groups) |*slot| if (slot.* != null and slot.*.?.id == object_id) return slot;
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
};

fn sameHandle(a: shell_workspaces.WorkspaceHandle, b: shell_workspaces.WorkspaceHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
