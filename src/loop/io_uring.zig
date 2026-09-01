const std = @import("std");
const linux = std.os.linux;
const timer_heap = @import("timer_heap.zig");

pub const OperationHandle = timer_heap.TimerHandle;

const Operation = enum(u8) {
    timer_alarm = 0xa0,
    timer_update = 0xa1,
    timer_remove = 0xa2,
    openat2 = 0xa3,
    statx = 0xa4,
    read = 0xa5,
    close = 0xa6,
    operation_cancel = 0xa7,
    accept = 0xa8,
    recv = 0xa9,
    send = 0xaa,
};

pub const OperationKind = enum {
    openat2,
    statx,
    read,
    close,
};

pub const SocketOperationKind = enum {
    accept,
    recv,
    send,
};

pub const OpenHow = extern struct {
    flags: u64,
    mode: u64 = 0,
    resolve: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(OpenHow) == 24);
    std.debug.assert(@alignOf(OpenHow) == 8);
}

pub const Resolve = struct {
    pub const no_magic_links: u64 = 0x02;
    pub const no_symlinks: u64 = 0x04;
    pub const beneath: u64 = 0x08;
};

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    cancel_pending: bool = false,
    operation: Operation = .openat2,
    open_how: OpenHow = .{ .flags = 0 },
};

const Control = enum { none, update, remove };

const timer_generation_bit: u32 = 1 << 31;

pub const Completion = struct {
    operation: OperationHandle,
    deadline_ns: u64,
};

pub const FileCompletion = struct {
    operation: OperationHandle,
    kind: OperationKind,
    result: i32,
};

pub const SocketCompletion = struct {
    operation: OperationHandle,
    kind: SocketOperationKind,
    result: i32,
};

/// `foreign` is intentionally returned unchanged to let one CQ loop route
/// Wayring and future subsystems before or after Ourokit's own operations.
pub const Dispatch = union(enum) {
    foreign,
    stale,
    file: FileCompletion,
    socket: SocketCompletion,
    operation_cancel: Completion,
    timer_wakeup,
    timer_control,
};

/// Ourokit-owned raw io_uring plus a userspace logical-timer heap. Logical
/// timers never consume SQEs individually: one absolute kernel timeout tracks
/// the heap root and `IORING_TIMEOUT_UPDATE` moves that alarm when necessary.
pub const Loop = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    timers: timer_heap.TimerHeap,
    slots: []Slot,
    operation_capacity_hint: usize,

    alarm_generation: u32 = 0,
    alarm_active: bool = false,
    retired_alarm_generation: ?u32 = null,
    alarm_deadline_ns: u64 = 0,
    alarm_time: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    control: Control = .none,
    control_deadline_ns: u64 = 0,
    control_time: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    pub fn init(
        self: *Loop,
        allocator: std.mem.Allocator,
        entries: u16,
        operation_capacity: u32,
    ) !void {
        if (operation_capacity == 0 or operation_capacity > 0x00ff_ffff)
            return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, operation_capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        self.* = .{
            .allocator = allocator,
            .ring = try linux.IoUring.init(
                entries,
                linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN,
            ),
            .timers = timer_heap.TimerHeap.init(allocator),
            .slots = slots,
            .operation_capacity_hint = operation_capacity,
        };
    }

    pub fn deinit(self: *Loop) void {
        std.debug.assert(self.timers.count() == 0);
        std.debug.assert(!self.alarm_active and self.retired_alarm_generation == null and
            self.control == .none);
        self.timers.deinit();
        self.ring.deinit();
        for (self.slots) |slot| std.debug.assert(!slot.active and !slot.cancel_pending);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Adds a logical CLOCK_MONOTONIC timer. The next `submit` synchronizes one
    /// kernel alarm with the earliest userspace deadline.
    pub fn prepareTimeout(self: *Loop, nanoseconds: u64) !OperationHandle {
        return timerHandle(try self.timers.scheduleAfter(try monotonicNow(), nanoseconds));
    }

    /// Prepares cancellation. The operation slot remains unavailable until
    /// both the operation and cancellation terminal CQEs arrive, regardless
    /// of their ordering.
    pub fn prepareCancel(self: *Loop, handle: OperationHandle) !void {
        if (handle.generation & timer_generation_bit != 0) {
            if (!self.timers.cancel(rawTimerHandle(handle))) return error.StaleOperation;
            return;
        }
        const slot = try self.activeSlot(handle);
        if (slot.cancel_pending) return error.CancellationAlreadyPending;
        slot.cancel_pending = true;
        _ = self.ring.cancel(
            encodeFile(.operation_cancel, handle),
            encodeFile(slot.operation, handle),
            0,
        ) catch |err| {
            slot.cancel_pending = false;
            return err;
        };
    }

    pub fn operationPending(self: *const Loop, handle: OperationHandle) bool {
        if (handle.generation & timer_generation_bit != 0) return false;
        if (handle.slot >= self.slots.len) return false;
        const slot = &self.slots[handle.slot];
        return slot.generation == handle.generation and (slot.active or slot.cancel_pending);
    }

    pub fn prepareOpenAt2(
        self: *Loop,
        directory: linux.fd_t,
        path: [*:0]const u8,
        how: OpenHow,
    ) !OperationHandle {
        const reserved = try self.reserve(.openat2);
        const slot = reserved.slot;
        slot.open_how = how;
        const sqe = self.ring.get_sqe() catch |err| {
            slot.active = false;
            return err;
        };
        sqe.prep_rw(
            .OPENAT2,
            directory,
            @intFromPtr(path),
            @sizeOf(OpenHow),
            @intFromPtr(&slot.open_how),
        );
        sqe.user_data = encodeFile(.openat2, reserved.handle);
        sqe.flags |= linux.IOSQE_ASYNC;
        return reserved.handle;
    }

    pub fn prepareStatx(
        self: *Loop,
        fd: linux.fd_t,
        output: *linux.Statx,
    ) !OperationHandle {
        const reserved = try self.reserve(.statx);
        const sqe = self.ring.statx(
            encodeFile(.statx, reserved.handle),
            fd,
            "",
            linux.AT.EMPTY_PATH,
            .{
                .TYPE = true,
                .SIZE = true,
                .INO = true,
                .MTIME = true,
                .CTIME = true,
                .MNT_ID = true,
            },
            output,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        sqe.flags |= linux.IOSQE_ASYNC;
        return reserved.handle;
    }

    pub fn prepareRead(
        self: *Loop,
        fd: linux.fd_t,
        buffer: []u8,
        offset: u64,
    ) !OperationHandle {
        if (buffer.len == 0) return error.EmptyReadBuffer;
        const reserved = try self.reserve(.read);
        const sqe = self.ring.read(
            encodeFile(.read, reserved.handle),
            fd,
            .{ .buffer = buffer },
            offset,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        sqe.flags |= linux.IOSQE_ASYNC;
        return reserved.handle;
    }

    pub fn prepareClose(self: *Loop, fd: linux.fd_t) !OperationHandle {
        const reserved = try self.reserve(.close);
        _ = self.ring.close(encodeFile(.close, reserved.handle), fd) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    pub fn prepareAccept(self: *Loop, fd: linux.fd_t) !OperationHandle {
        const reserved = try self.reserve(.accept);
        _ = self.ring.accept(
            encodeFile(.accept, reserved.handle),
            fd,
            null,
            null,
            linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    pub fn prepareRecv(self: *Loop, fd: linux.fd_t, buffer: []u8) !OperationHandle {
        if (buffer.len == 0) return error.EmptyReceiveBuffer;
        const reserved = try self.reserve(.recv);
        _ = self.ring.recv(
            encodeFile(.recv, reserved.handle),
            fd,
            .{ .buffer = buffer },
            0,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    pub fn prepareSend(self: *Loop, fd: linux.fd_t, buffer: []const u8) !OperationHandle {
        if (buffer.len == 0) return error.EmptySendBuffer;
        const reserved = try self.reserve(.send);
        _ = self.ring.send(
            encodeFile(.send, reserved.handle),
            fd,
            buffer,
            linux.MSG.NOSIGNAL,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    pub fn submit(self: *Loop) !u32 {
        try self.synchronizeAlarm();
        return self.ring.submit();
    }

    pub fn operationCapacity(self: *const Loop) usize {
        return self.operation_capacity_hint;
    }

    pub fn hasPendingTimerKernelWork(self: *const Loop) bool {
        return self.alarm_active or self.retired_alarm_generation != null or self.control != .none;
    }

    pub fn wait(self: *Loop) !linux.io_uring_cqe {
        return self.ring.copy_cqe();
    }

    /// Returns every logical timer whose deadline has passed. Callers dispatch
    /// these as state transitions only; language tasks resume at their phase.
    pub fn takeExpired(self: *Loop) !?Completion {
        const expired = self.timers.popExpired(try monotonicNow()) orelse return null;
        return .{ .operation = timerHandle(expired.handle), .deadline_ns = expired.deadline };
    }

    /// Validates the private timer namespace and alarm generation. No callback
    /// is invoked here and logical timer handles never enter kernel user_data.
    pub fn dispatch(self: *Loop, cqe: linux.io_uring_cqe) Dispatch {
        const decoded = decode(cqe.user_data) orelse return .foreign;
        if (decoded.operation == .timer_alarm and
            self.retired_alarm_generation == decoded.generation)
        {
            self.retired_alarm_generation = null;
            return .timer_control;
        }
        switch (decoded.operation) {
            .timer_alarm => {
                if (decoded.generation != self.alarm_generation) return .stale;
                if (!self.alarm_active) return .stale;
                self.alarm_active = false;
                return .timer_wakeup;
            },
            .timer_update => {
                if (decoded.generation != self.alarm_generation) return .stale;
                if (self.control != .update) return .stale;
                if (cqe.res == 0) self.alarm_deadline_ns = self.control_deadline_ns;
                self.control = .none;
                return .timer_control;
            },
            .timer_remove => {
                if (decoded.generation != self.alarm_generation) return .stale;
                if (self.control != .remove) return .stale;
                if (cqe.res == 0) {
                    self.alarm_active = false;
                    self.retired_alarm_generation = self.alarm_generation;
                }
                self.control = .none;
                return .timer_control;
            },
            .operation_cancel => {
                const handle = decoded.handle orelse return .stale;
                if (handle.slot >= self.slots.len) return .stale;
                const slot = &self.slots[handle.slot];
                if (slot.generation != handle.generation) return .stale;
                if (!slot.cancel_pending) return .stale;
                slot.cancel_pending = false;
                return .{ .operation_cancel = .{ .operation = handle, .deadline_ns = 0 } };
            },
            .openat2, .statx, .read, .close => |operation| {
                const handle = decoded.handle orelse return .stale;
                if (handle.slot >= self.slots.len) return .stale;
                const slot = &self.slots[handle.slot];
                if (slot.generation != handle.generation) return .stale;
                if (!slot.active or slot.operation != operation) return .stale;
                slot.active = false;
                return .{ .file = .{
                    .operation = handle,
                    .kind = switch (operation) {
                        .openat2 => .openat2,
                        .statx => .statx,
                        .read => .read,
                        .close => .close,
                        else => unreachable,
                    },
                    .result = cqe.res,
                } };
            },
            .accept, .recv, .send => |operation| {
                const handle = decoded.handle orelse return .stale;
                if (handle.slot >= self.slots.len) return .stale;
                const slot = &self.slots[handle.slot];
                if (slot.generation != handle.generation) return .stale;
                if (!slot.active or slot.operation != operation) return .stale;
                slot.active = false;
                return .{ .socket = .{
                    .operation = handle,
                    .kind = switch (operation) {
                        .accept => .accept,
                        .recv => .recv,
                        .send => .send,
                        else => unreachable,
                    },
                    .result = cqe.res,
                } };
            },
        }
    }

    fn availableSlot(self: *Loop) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (!slot.active and !slot.cancel_pending) return index;
        }
        return null;
    }

    fn activeSlot(self: *Loop, handle: OperationHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleOperation;
        const slot = &self.slots[handle.slot];
        if (!slot.active or slot.generation != handle.generation) return error.StaleOperation;
        return slot;
    }

    fn synchronizeAlarm(self: *Loop) !void {
        if (self.control != .none) return;
        if (self.retired_alarm_generation != null) return;
        const desired = self.timers.nextDeadline();
        if (!self.alarm_active) {
            const deadline = desired orelse return;
            self.alarm_generation +%= 1;
            if (self.alarm_generation == 0) self.alarm_generation = 1;
            self.alarm_deadline_ns = deadline;
            self.alarm_time = timespec(deadline);
            _ = try self.ring.timeout(
                encode(.timer_alarm, self.alarm_generation),
                &self.alarm_time,
                0,
                linux.IORING_TIMEOUT_ABS,
            );
            self.alarm_active = true;
            return;
        }
        if (desired) |deadline| {
            if (deadline == self.alarm_deadline_ns) return;
            self.control = .update;
            self.control_deadline_ns = deadline;
            self.control_time = timespec(deadline);
            const sqe = try self.ring.get_sqe();
            sqe.prep_timeout_remove(
                encode(.timer_alarm, self.alarm_generation),
                linux.IORING_TIMEOUT_UPDATE | linux.IORING_TIMEOUT_ABS,
            );
            // liburing's timeout-update layout: the new timespec is in `off`,
            // while `addr` continues to identify the original timeout.
            sqe.off = @intFromPtr(&self.control_time);
            sqe.user_data = encode(.timer_update, self.alarm_generation);
        } else {
            self.control = .remove;
            _ = try self.ring.timeout_remove(
                encode(.timer_remove, self.alarm_generation),
                encode(.timer_alarm, self.alarm_generation),
                0,
            );
        }
    }

    const Reservation = struct {
        handle: OperationHandle,
        slot: *Slot,
    };

    fn reserve(self: *Loop, operation: Operation) !Reservation {
        const index = self.availableSlot() orelse return error.OperationCapacityExceeded;
        const slot = &self.slots[index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.active = true;
        slot.cancel_pending = false;
        slot.operation = operation;
        return .{
            .handle = .{ .slot = @intCast(index), .generation = slot.generation },
            .slot = slot,
        };
    }
};

const Decoded = struct {
    operation: Operation,
    generation: u32,
    handle: ?OperationHandle,
};

fn encode(operation: Operation, generation: u32) u64 {
    return @intFromEnum(operation) | (@as(u64, generation) << 32);
}

fn encodeFile(operation: Operation, handle: OperationHandle) u64 {
    return @intFromEnum(operation) |
        (@as(u64, handle.slot) << 8) |
        (@as(u64, handle.generation) << 32);
}

fn decode(value: u64) ?Decoded {
    const operation: Operation = switch (@as(u8, @truncate(value))) {
        @intFromEnum(Operation.openat2) => .openat2,
        @intFromEnum(Operation.statx) => .statx,
        @intFromEnum(Operation.read) => .read,
        @intFromEnum(Operation.close) => .close,
        @intFromEnum(Operation.operation_cancel) => .operation_cancel,
        @intFromEnum(Operation.accept) => .accept,
        @intFromEnum(Operation.recv) => .recv,
        @intFromEnum(Operation.send) => .send,
        @intFromEnum(Operation.timer_alarm) => .timer_alarm,
        @intFromEnum(Operation.timer_update) => .timer_update,
        @intFromEnum(Operation.timer_remove) => .timer_remove,
        else => return null,
    };
    const generation: u32 = @truncate(value >> 32);
    const handle = switch (operation) {
        .openat2, .statx, .read, .close, .operation_cancel, .accept, .recv, .send => OperationHandle{
            .slot = @truncate((value >> 8) & 0x00ff_ffff),
            .generation = generation,
        },
        else => null,
    };
    return .{ .operation = operation, .generation = generation, .handle = handle };
}

fn timerHandle(handle: timer_heap.TimerHandle) OperationHandle {
    return .{ .slot = handle.slot, .generation = handle.generation | timer_generation_bit };
}

fn rawTimerHandle(handle: OperationHandle) timer_heap.TimerHandle {
    return .{ .slot = handle.slot, .generation = handle.generation & ~timer_generation_bit };
}

fn timespec(nanoseconds: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(nanoseconds / std.time.ns_per_s),
        .nsec = @intCast(nanoseconds % std.time.ns_per_s),
    };
}

fn monotonicNow() !u64 {
    var value: linux.timespec = undefined;
    switch (linux.errno(linux.clock_gettime(.MONOTONIC, &value))) {
        .SUCCESS => {},
        else => return error.ClockUnavailable,
    }
    return std.math.add(
        u64,
        try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s),
        @intCast(value.nsec),
    );
}

fn drainKernelTimer(loop: *Loop) !void {
    while (loop.hasPendingTimerKernelWork()) {
        _ = try loop.submit();
        _ = loop.dispatch(try loop.wait());
    }
}

test "many logical timers share one kernel alarm and expire in order" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();

    const late = try loop.prepareTimeout(4 * std.time.ns_per_ms);
    const early = try loop.prepareTimeout(1 * std.time.ns_per_ms);
    const middle = try loop.prepareTimeout(2 * std.time.ns_per_ms);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(early, (try loop.takeExpired()).?.operation);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(middle, (try loop.takeExpired()).?.operation);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(late, (try loop.takeExpired()).?.operation);
}

test "an earlier logical timer updates the submitted kernel alarm" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();

    const late = try loop.prepareTimeout(50 * std.time.ns_per_ms);
    _ = try loop.submit();
    const early = try loop.prepareTimeout(1 * std.time.ns_per_ms);
    _ = try loop.submit();
    try std.testing.expectEqual(Dispatch.timer_control, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(early, (try loop.takeExpired()).?.operation);
    try loop.prepareCancel(late);
}

test "logical cancellation invalidates immediately and removes the kernel alarm" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 1);
    defer loop.deinit();

    const operation = try loop.prepareTimeout(std.time.ns_per_s);
    _ = try loop.submit();
    try loop.prepareCancel(operation);
    try std.testing.expectError(error.StaleOperation, loop.prepareCancel(operation));
    try drainKernelTimer(&loop);
    try std.testing.expect((try loop.takeExpired()) == null);
}

test "socket operations accept receive and send on a Unix socket" {
    var address: linux.sockaddr.un = .{ .path = undefined };
    @memset(&address.path, 0);
    const name = try std.fmt.bufPrint(address.path[1..], "ouro-loop-{d}", .{linux.getpid()});
    const address_len: linux.socklen_t = @intCast(
        @offsetOf(linux.sockaddr.un, "path") + 1 + name.len,
    );

    const listener_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(listener_result));
    const listener: linux.fd_t = @intCast(listener_result);
    defer _ = linux.close(listener);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(
        listener,
        @ptrCast(&address),
        address_len,
    )));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(listener, 1)));

    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    const accept_handle = try loop.prepareAccept(listener);
    _ = try loop.submit();

    const client_result = linux.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(client_result));
    const client: linux.fd_t = @intCast(client_result);
    defer _ = linux.close(client);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.connect(
        client,
        @ptrCast(&address),
        address_len,
    )));

    const accepted_dispatch = loop.dispatch(try loop.wait());
    const accepted_completion = switch (accepted_dispatch) {
        .socket => |completion| completion,
        else => return error.UnexpectedCompletion,
    };
    try std.testing.expectEqual(accept_handle, accepted_completion.operation);
    try std.testing.expectEqual(SocketOperationKind.accept, accepted_completion.kind);
    try std.testing.expect(accepted_completion.result >= 0);
    const accepted: linux.fd_t = @intCast(accepted_completion.result);
    defer _ = linux.close(accepted);

    var receive_buffer: [16]u8 = undefined;
    const receive_handle = try loop.prepareRecv(accepted, &receive_buffer);
    try std.testing.expectEqual(@as(usize, 4), linux.write(client, "ping", 4));
    _ = try loop.submit();
    const receive_completion = switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| completion,
        else => return error.UnexpectedCompletion,
    };
    try std.testing.expectEqual(receive_handle, receive_completion.operation);
    try std.testing.expectEqual(SocketOperationKind.recv, receive_completion.kind);
    try std.testing.expectEqual(@as(i32, 4), receive_completion.result);
    try std.testing.expectEqualStrings("ping", receive_buffer[0..4]);

    const send_handle = try loop.prepareSend(accepted, "pong");
    _ = try loop.submit();
    const send_completion = switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| completion,
        else => return error.UnexpectedCompletion,
    };
    try std.testing.expectEqual(send_handle, send_completion.operation);
    try std.testing.expectEqual(SocketOperationKind.send, send_completion.kind);
    try std.testing.expectEqual(@as(i32, 4), send_completion.result);
    var response: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), linux.read(client, &response, response.len));
    try std.testing.expectEqualStrings("pong", &response);
}
