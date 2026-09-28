const std = @import("std");
const wayring = @import("wayring");
const p = @import("wayland_protocol");
const model = @import("../../shell/session.zig");
const Handle = wayring.objects.Handle;
const Objects = wayring.objects.ClientObjects;
const Queue = wayring.tx.Queue;

pub const Client = struct {
    store: ?*model.Store = null,
    idle: ?Handle = null,
    power: ?Handle = null,
    manager: ?Handle = null,
    global_names: [3]?u32 = @splat(null),
    lock: ?Handle = null,
    handles: [model.capacity]?Handle = @splat(null),

    pub fn bind(self: *Client, objects: *Objects, tx: *Queue, registry: Handle, global: p.wl_registry.Event_global) !bool {
        const store = self.store orelse return false;
        inline for (.{ p.ext_idle_notifier_v1, p.zwlr_output_power_manager_v1, p.ext_session_lock_manager_v1 }, .{ "idle", "power", "manager" }, 0..) |Interface, field, index| {
            if (std.mem.eql(u8, global.interface, Interface.info.name)) {
                if (@field(self, field) != null) return true;
                const version = @min(global.version, if (Interface == p.ext_idle_notifier_v1) @as(u32, 2) else 1);
                @field(self, field) = try wayring.client.Core(p).bind(objects, tx, registry, global.name, &Interface.info, version, null);
                self.global_names[index] = global.name;
                if (Interface == p.ext_idle_notifier_v1) store.idle_version = version;
                if (Interface == p.zwlr_output_power_manager_v1) store.power_available = true;
                if (Interface == p.ext_session_lock_manager_v1) store.lock_available = true;
                return true;
            }
        }
        return false;
    }

    pub fn removeGlobal(self: *Client, objects: *Objects, tx: *Queue, name: u32) !void {
        const store = self.store orelse return;
        inline for (.{ p.ext_idle_notifier_v1, p.zwlr_output_power_manager_v1, p.ext_session_lock_manager_v1 }, .{ "idle", "power", "manager" }, 0..) |Interface, field, index| {
            if (self.global_names[index] == name) {
                try wayring.client.sendRequest(Interface, objects, tx, @field(self, field).?, .{ .destroy = .{} });
                @field(self, field) = null;
                self.global_names[index] = null;
                // Child objects remain valid, including an acknowledged lock.
                if (Interface == p.ext_idle_notifier_v1) store.idle_version = 0;
                if (Interface == p.zwlr_output_power_manager_v1) store.power_available = false;
                if (Interface == p.ext_session_lock_manager_v1) store.lock_available = false;
            }
        }
    }

    pub fn seatRemoved(self: *Client) void {
        const store = self.store orelse return;
        for (&store.resources) |*resource| {
            if (resource.used and resource.kind == .idle and resource.started) resource.push(.failed);
        }
    }

    pub fn pump(self: *Client, objects: *Objects, tx: *Queue, seat: ?Handle, outputs: anytype) !void {
        const store = self.store orelse return;
        var names: [32][]const u8 = undefined;
        var count: usize = 0;
        var complete = true;
        for (outputs) |output| if (output.name) |name| {
            if (count == names.len) return error.OutputCapacityExceeded;
            names[count] = name;
            count += 1;
        } else if (output.handle != null) {
            // Registry discovery precedes wl_output.name. Never publish an
            // incomplete snapshot that omits a connected, not-yet-named output.
            complete = false;
        };
        store.outputs_ready = complete;
        std.mem.sort([]const u8, names[0..count], {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        if (complete) try store.updateOutputs(names[0..count]);
        for (&store.resources, 0..) |*r, index| {
            if (!r.used) continue;
            if (r.close_requested or (r.terminal and (r.kind != .lock or self.handles[index] == null))) {
                if (self.handles[index]) |handle| {
                    switch (r.kind) {
                        .idle => try wayring.client.sendRequest(p.ext_idle_notification_v1, objects, tx, handle, .{ .destroy = .{} }),
                        .power => try wayring.client.sendRequest(p.zwlr_output_power_v1, objects, tx, handle, .{ .destroy = .{} }),
                        .lock => {}, // Only finished/unlock retire a protocol lock.
                        .outputs => unreachable,
                    }
                    self.handles[index] = null;
                }
                r.push(.closed);
                if (r.detached or r.close_requested) store.release(index);
                continue;
            }
            if (!r.enabled) continue;
            if (!r.started and !r.terminal) {
                r.started = true;
                switch (r.kind) {
                    .outputs => {},
                    .idle => {
                        if (self.idle == null or seat == null or (r.input_only and store.idle_version < 2)) {
                            r.push(.failed);
                            continue;
                        }
                        self.handles[index] = if (r.input_only)
                            (try p.ext_idle_notifier_v1.construct_get_input_idle_notification(objects, tx, self.idle.?, .{ .timeout = r.timeout_ms, .seat = seat.?.id })).id
                        else
                            (try p.ext_idle_notifier_v1.construct_get_idle_notification(objects, tx, self.idle.?, .{ .timeout = r.timeout_ms, .seat = seat.?.id })).id;
                    },
                    .power => {
                        var output: ?Handle = null;
                        for (outputs) |value| if (value.name) |name| {
                            if (std.mem.eql(u8, name, r.output[0..r.output_len])) output = value.handle;
                        };
                        if (self.power == null or output == null) {
                            r.push(.failed);
                            continue;
                        }
                        self.handles[index] = (try p.zwlr_output_power_manager_v1.construct_get_output_power(objects, tx, self.power.?, .{ .output = output.?.id })).id;
                    },
                    .lock => {
                        if (self.manager == null) {
                            r.push(.failed);
                            store.lock_state = .unlocked;
                            store.lock_handle = null;
                            continue;
                        }
                        self.lock = (try p.ext_session_lock_manager_v1.construct_lock(objects, tx, self.manager.?, .{})).id;
                        self.handles[index] = self.lock;
                        store.lock_state = .pending;
                    },
                }
            }
            if (r.kind == .power and !r.terminal) if (r.desired_power) |on| {
                try wayring.client.sendRequest(p.zwlr_output_power_v1, objects, tx, self.handles[index].?, .{ .set_mode = .{ .mode = if (on) p.zwlr_output_power_v1.mode.on else p.zwlr_output_power_v1.mode.off } });
                r.desired_power = null;
            };
            if (r.kind == .lock and !r.terminal and store.lock_state == .unlocking and store.lock_handle.?.slot == index) {
                try wayring.client.sendRequest(p.ext_session_lock_v1, objects, tx, self.lock.?, .{ .unlock_and_destroy = .{} });
                self.lock = null;
                self.handles[index] = null;
                store.lock_state = .unlocked;
                store.lock_handle = null;
                r.push(.unlocked);
            }
        }
    }

    pub fn event(self: *Client, objects: *Objects, tx: *Queue, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !bool {
        const store = self.store orelse return false;
        for (self.handles, 0..) |maybe, index| {
            const handle = maybe orelse continue;
            if (handle.id != message.header.object_id) continue;
            const r = &store.resources[index];
            switch (r.kind) {
                .outputs => unreachable,
                .idle => switch (try wayring.client.decodeEvent(p.ext_idle_notification_v1, objects, handle, message, fds)) {
                    .idled => r.push(.idled),
                    .resumed => r.push(.resumed),
                },
                .power => switch (try wayring.client.decodeEvent(p.zwlr_output_power_v1, objects, handle, message, fds)) {
                    .mode => |value| r.push(if (value.mode.value == p.zwlr_output_power_v1.mode.on.value) .on else .off),
                    .failed => r.push(.failed),
                },
                .lock => switch (try wayring.client.decodeEvent(p.ext_session_lock_v1, objects, handle, message, fds)) {
                    .locked => {
                        store.lock_state = .locked;
                        r.push(.locked);
                    },
                    .finished => {
                        // The compositor may finish a previously locked object
                        // after an alternative secure unlock of its own.
                        if (store.lock_state == .locked or store.lock_state == .unlocking)
                            try wayring.client.sendRequest(p.ext_session_lock_v1, objects, tx, handle, .{ .unlock_and_destroy = .{} })
                        else
                            try wayring.client.sendRequest(p.ext_session_lock_v1, objects, tx, handle, .{ .destroy = .{} });
                        self.handles[index] = null;
                        self.lock = null;
                        store.lock_state = .unlocked;
                        store.lock_handle = null;
                        r.push(.finished);
                    },
                },
            }
            return true;
        }
        return false;
    }

    pub fn disconnect(self: *Client) void {
        const store = self.store orelse return;
        if (store.blocksReload()) store.lock_state = .abandoned;
        for (&store.resources) |*r| if (r.used) r.push(.failed);
        self.handles = @splat(null);
        self.lock = null;
    }
};
