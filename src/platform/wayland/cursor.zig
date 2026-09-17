const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayland_protocol");
const Shape = @import("../window.zig").PointerCursor;
const Handle = wayring.objects.Handle;

/// Cursor-shape protocol state belongs to the pointer, not a widget or surface.
pub const Cursor = struct {
    manager: ?Handle = null,
    manager_global_name: ?u32 = null,
    device: ?Handle = null,
    enter_serial: ?u32 = null,
    applied: ?Shape = null,

    pub fn ensureDevice(self: *Cursor, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue, pointer: ?Handle) !void {
        if (self.device != null or self.manager == null or pointer == null) return;
        self.device = (try protocol.wp_cursor_shape_manager_v1.construct_get_pointer(objects, queue, self.manager.?, .{ .pointer = pointer.?.id })).cursor_shape_device;
        self.applied = null;
    }

    pub fn enter(self: *Cursor, serial: u32) void {
        self.enter_serial = serial;
        self.applied = null;
    }

    pub fn leave(self: *Cursor) void {
        self.enter_serial = null;
        self.applied = null;
    }

    pub fn set(self: *Cursor, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue, shape: Shape) !bool {
        const device = self.device orelse return false;
        const serial = self.enter_serial orelse return false;
        if (self.applied == shape) return false;
        try wayring.client.sendRequest(protocol.wp_cursor_shape_device_v1, objects, queue, device, .{ .set_shape = .{
            .serial = serial,
            .shape = switch (shape) {
                .default => .default,
                .text => .text,
            },
        } });
        self.applied = shape;
        return true;
    }

    pub fn releaseDevice(self: *Cursor, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue) !void {
        if (self.device) |device| try wayring.client.sendRequest(protocol.wp_cursor_shape_device_v1, objects, queue, device, .{ .destroy = .{} });
        self.device = null;
        self.applied = null;
    }

    pub fn releaseManager(self: *Cursor, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue) !void {
        _ = try self.set(objects, queue, .default);
        try self.releaseDevice(objects, queue);
        if (self.manager) |manager| try wayring.client.sendRequest(protocol.wp_cursor_shape_manager_v1, objects, queue, manager, .{ .destroy = .{} });
        self.manager = null;
        self.manager_global_name = null;
    }
};

test "cursor requests use the latest enter serial and reset on device replacement" {
    const allocator = std.testing.allocator;
    var objects = try wayring.objects.ClientObjects.init(allocator, 16, 16, &protocol.wl_display.info, null);
    defer objects.deinit(allocator);
    var blocks = try wayring.pool.SharedBlocks.init(allocator, 1024, 2);
    defer blocks.deinit(allocator);
    var fds = try wayring.pool.SharedFds.init(allocator, 1);
    defer fds.deinit(allocator);
    var queue = wayring.tx.Queue.init(&blocks, 2048, &fds, 0);
    defer queue.deinit();
    var cursor: Cursor = .{};
    const pointer = try objects.createLocal(&protocol.wl_pointer.info, 1, null);
    try cursor.ensureDevice(&objects, &queue, pointer);
    try std.testing.expect(!try cursor.set(&objects, &queue, .text));
    cursor.manager = try objects.createLocal(&protocol.wp_cursor_shape_manager_v1.info, 1, null);
    try cursor.ensureDevice(&objects, &queue, pointer);
    try std.testing.expect(!try cursor.set(&objects, &queue, .text));
    cursor.enter(17);
    try std.testing.expect(try cursor.set(&objects, &queue, .text));
    try std.testing.expect(!try cursor.set(&objects, &queue, .text));
    cursor.enter(93);
    try std.testing.expect(try cursor.set(&objects, &queue, .default));
    const snapshot = try queue.snapshot(&.{}, &.{});
    // get_pointer (16 bytes), then two set_shape requests (16 bytes each).
    try std.testing.expectEqual(@as(usize, 48), snapshot.first.len);
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, snapshot.first[24..28], .little));
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, snapshot.first[28..32], .little));
    try std.testing.expectEqual(@as(u32, 93), std.mem.readInt(u32, snapshot.first[40..44], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, snapshot.first[44..48], .little));
    cursor.leave();
    try std.testing.expect(!try cursor.set(&objects, &queue, .text));
    const old = cursor.device.?;
    try cursor.releaseDevice(&objects, &queue);
    try cursor.ensureDevice(&objects, &queue, pointer);
    try std.testing.expect(!std.meta.eql(old, cursor.device.?));
    try std.testing.expect(!try cursor.set(&objects, &queue, .text));
    cursor.enter(103);
    try std.testing.expect(try cursor.set(&objects, &queue, .text));
    try cursor.releaseManager(&objects, &queue);
    try std.testing.expect(cursor.device == null and cursor.manager == null);
}
