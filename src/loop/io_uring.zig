const std = @import("std");
const linux = std.os.linux;
const timer_heap = @import("timer_heap.zig");
const StableSlots = @import("../core/stable_slots.zig").StableSlots;

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
    write = 0xa8,
    accept = 0xa9,
    recv = 0xaa,
    send = 0xab,
    connect = 0xac,
    signal_poll = 0xad,
    recvmsg = 0xae,
    sendmsg = 0xaf,
    poll = 0xb0,
};

pub const OperationKind = enum {
    openat2,
    statx,
    read,
    write,
    close,
};

pub const SocketOperationKind = enum {
    accept,
    recv,
    send,
    connect,
    recvmsg,
    sendmsg,
    poll,
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
    connect_address: linux.sockaddr.un = undefined,
    connect_address_len: linux.socklen_t = 0,
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
    signal_wakeup,
};

/// Ourokit-owned raw io_uring plus a userspace logical-timer heap. Logical
/// timers never consume SQEs individually: one absolute kernel timeout tracks
/// the heap root and `IORING_TIMEOUT_UPDATE` moves that alarm when necessary.
pub const Loop = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    timers: timer_heap.TimerHeap,
    /// The kernel reads `open_how` and `connect_address` from a slot after
    /// submission, so slots grow in chunks that never move.
    slots: StableSlots(Slot),
    operation_capacity_hint: usize,

    alarm_generation: u32 = 0,
    alarm_active: bool = false,
    retired_alarm_generation: ?u32 = null,
    alarm_deadline_ns: u64 = 0,
    alarm_time: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    control: Control = .none,
    control_deadline_ns: u64 = 0,
    control_time: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },

    signal_fd: ?linux.fd_t = null,
    previous_signal_mask: linux.sigset_t = undefined,
    signal_poll_active: bool = false,
    signal_poll_failed: bool = false,
    received_signal: ?linux.SIG = null,

    pub fn init(
        self: *Loop,
        allocator: std.mem.Allocator,
        entries: u16,
        operation_capacity: u32,
    ) !void {
        if (operation_capacity == 0 or operation_capacity > 0x00ff_ffff)
            return error.InvalidCapacity;
        var slots = StableSlots(Slot).init(operation_capacity);
        errdefer slots.deinit(allocator);
        _ = try slots.grow(allocator);
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
        // POLL_ADD borrows no userspace buffer. Closing the ring cancels its
        // signal watch after application operations have been drained.
        self.ring.deinit();
        if (self.signal_fd) |fd| {
            var info: linux.signalfd_siginfo = undefined;
            while (linux.read(fd, @ptrCast(&info), @sizeOf(@TypeOf(info))) == @sizeOf(@TypeOf(info))) {}
            _ = linux.close(fd);
            _ = linux.sigprocmask(linux.SIG.SETMASK, &self.previous_signal_mask, null);
        }
        for (0..self.slots.len()) |index| {
            const slot = self.slots.at(index);
            std.debug.assert(!slot.active and !slot.cancel_pending);
        }
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    /// Call before creating worker/renderer threads so they inherit the mask.
    /// The watch is loop-owned, not application work, and does not keep drains
    /// alive. Signal dispositions are unchanged; ignored signals stay ignored.
    pub fn watchSignals(self: *Loop, signals: []const linux.SIG) !void {
        std.debug.assert(self.signal_fd == null);
        var mask = linux.sigemptyset();
        for (signals) |signal| {
            var action: linux.Sigaction = undefined;
            if (linux.errno(linux.sigaction(signal, null, &action)) != .SUCCESS)
                return error.SignalWatchFailed;
            if (action.handler.handler != linux.SIG.IGN) linux.sigaddset(&mask, signal);
        }
        if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &mask, &self.previous_signal_mask)) != .SUCCESS)
            return error.SignalWatchFailed;
        errdefer _ = linux.sigprocmask(linux.SIG.SETMASK, &self.previous_signal_mask, null);
        const result = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.SignalWatchFailed;
        self.signal_fd = @intCast(result);
    }

    /// Retains the first signal across startup, activation and shutdown phases.
    /// Read on the owning thread rather than through an io_uring worker, since
    /// signalfd consumes signals pending for the reading thread/process.
    pub fn receivedSignal(self: *Loop) !?linux.SIG {
        if (self.signal_poll_failed) return error.SignalWatchFailed;
        if (self.received_signal) |signal| return signal;
        const fd = self.signal_fd orelse return null;
        var info: linux.signalfd_siginfo = undefined;
        const result = linux.read(fd, @ptrCast(&info), @sizeOf(@TypeOf(info)));
        if (linux.errno(result) == .AGAIN) return null;
        if (result != @sizeOf(@TypeOf(info))) return error.SignalWatchFailed;
        self.received_signal = @enumFromInt(info.signo);
        return self.received_signal;
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
        const slot = self.slots.get(handle.slot) orelse return false;
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
        _ = self.ring.read(
            encodeFile(.read, reserved.handle),
            fd,
            .{ .buffer = buffer },
            offset,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        // Let io_uring poll pipes. Forcing a blocking io-wq read can make
        // cancellation return EALREADY while the original never completes.
        return reserved.handle;
    }

    /// The caller retains `buffer` until the terminal completion is
    /// dispatched. Pipe and socket callers must handle short writes by
    /// preparing another operation for the remaining suffix.
    pub fn prepareWrite(
        self: *Loop,
        fd: linux.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !OperationHandle {
        if (buffer.len == 0) return error.EmptyWriteBuffer;
        const reserved = try self.reserve(.write);
        _ = self.ring.write(
            encodeFile(.write, reserved.handle),
            fd,
            buffer,
            offset,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
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

    /// One-shot readiness notification. The caller owns the descriptor and
    /// must keep it open until the operation and any cancellation have drained.
    /// Readiness consumes no bytes; result is a POLL event mask or negative errno.
    pub fn preparePoll(self: *Loop, fd: linux.fd_t, events: u32) !OperationHandle {
        const reserved = try self.reserve(.poll);
        _ = self.ring.poll_add(encodeFile(.poll, reserved.handle), fd, events) catch |err| {
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

    /// `message`, its iovecs, buffers, and control storage must remain stable
    /// until the terminal completion is dispatched.
    pub fn prepareRecvMsg(self: *Loop, fd: linux.fd_t, message: *linux.msghdr) !OperationHandle {
        const reserved = try self.reserve(.recvmsg);
        _ = self.ring.recvmsg(encodeFile(.recvmsg, reserved.handle), fd, message, linux.MSG.CMSG_CLOEXEC) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    /// `message`, its iovecs, buffers, and control storage must remain stable
    /// until the terminal completion is dispatched.
    pub fn prepareSendMsg(self: *Loop, fd: linux.fd_t, message: *const linux.msghdr_const) !OperationHandle {
        const reserved = try self.reserve(.sendmsg);
        _ = self.ring.sendmsg(encodeFile(.sendmsg, reserved.handle), fd, message, linux.MSG.NOSIGNAL) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    /// Copies a Unix address into stable operation storage before preparing
    /// the asynchronous connect. The caller may release its address value as
    /// soon as this function returns.
    pub fn prepareUnixConnect(
        self: *Loop,
        fd: linux.fd_t,
        address: *const linux.sockaddr.un,
        address_len: linux.socklen_t,
    ) !OperationHandle {
        const reserved = try self.reserve(.connect);
        reserved.slot.connect_address = address.*;
        reserved.slot.connect_address_len = address_len;
        _ = self.ring.connect(
            encodeFile(.connect, reserved.handle),
            fd,
            @ptrCast(&reserved.slot.connect_address),
            reserved.slot.connect_address_len,
        ) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    pub fn submit(self: *Loop) !u32 {
        try self.synchronizeAlarm();
        if (self.signal_fd) |fd| {
            if (!self.signal_poll_active and !self.signal_poll_failed and self.received_signal == null) {
                _ = try self.ring.poll_add(encode(.signal_poll, 0), fd, linux.POLL.IN);
                self.signal_poll_active = true;
            }
        }
        return self.submitRing();
    }

    /// Submits queued SQEs without synchronizing the logical-timer alarm.
    /// Signal delivery, including the freezer thaw after system resume, can
    /// interrupt io_uring_enter. SQEs stay queued until the kernel consumes
    /// them, so retrying resubmits only what is still pending.
    pub fn submitRing(self: *Loop) !u32 {
        while (true) return self.ring.submit() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
    }

    /// Runs deferred kernel task work without waiting for a completion.
    /// cq_ready alone cannot see work behind IORING_SETUP_DEFER_TASKRUN.
    pub fn flushTaskWork(self: *Loop) !void {
        while (true) {
            _ = self.ring.enter(0, 0, linux.IORING_ENTER_GETEVENTS) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return err,
            };
            return;
        }
    }

    pub fn operationCapacity(self: *const Loop) usize {
        return self.operation_capacity_hint;
    }

    pub fn hasPendingOperations(self: *const Loop) bool {
        for (0..self.slots.len()) |index| {
            const slot = self.slots.at(index);
            if (slot.active or slot.cancel_pending) return true;
        }
        return false;
    }

    pub fn hasPendingTimerKernelWork(self: *const Loop) bool {
        return self.alarm_active or self.retired_alarm_generation != null or self.control != .none;
    }

    /// Blocks for the next completion. An interrupted wait consumes nothing,
    /// so a signal or a thaw after system resume simply repeats the wait.
    pub fn wait(self: *Loop) !linux.io_uring_cqe {
        while (true) return self.ring.copy_cqe() catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
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
            .signal_poll => {
                if (!self.signal_poll_active) return .stale;
                self.signal_poll_active = false;
                self.signal_poll_failed = cqe.res < 0;
                return .signal_wakeup;
            },
            .timer_alarm => {
                if (decoded.generation != self.alarm_generation) return .stale;
                if (!self.alarm_active) return .stale;
                self.alarm_active = false;
                return .timer_wakeup;
            },
            .timer_update => {
                if (decoded.generation != self.alarm_generation) return .stale;
                if (self.control != .update) return .stale;
                if (cqe.res == 0) {
                    self.alarm_deadline_ns = self.control_deadline_ns;
                } else if (cqe.res == -@as(i32, @intFromEnum(linux.E.NOENT)) and self.alarm_active) {
                    // The alarm expired before the update reached it. Its CQE
                    // is still pending; retire this generation instead of
                    // submitting an immediately failing update every turn.
                    self.alarm_active = false;
                    self.retired_alarm_generation = self.alarm_generation;
                }
                self.control = .none;
                return .timer_control;
            },
            .timer_remove => {
                if (decoded.generation != self.alarm_generation) return .stale;
                if (self.control != .remove) return .stale;
                if (cqe.res == 0 or (cqe.res == -@as(i32, @intFromEnum(linux.E.NOENT)) and self.alarm_active)) {
                    // ENOENT means the alarm already fired, but its CQE can be
                    // behind this control CQE. Treat both outcomes as retired
                    // so synchronizeAlarm cannot flood the CQ with retries.
                    self.alarm_active = false;
                    self.retired_alarm_generation = self.alarm_generation;
                }
                self.control = .none;
                return .timer_control;
            },
            .operation_cancel => {
                const handle = decoded.handle orelse return .stale;
                const slot = self.slots.get(handle.slot) orelse return .stale;
                if (slot.generation != handle.generation) return .stale;
                if (!slot.cancel_pending) return .stale;
                slot.cancel_pending = false;
                return .{ .operation_cancel = .{ .operation = handle, .deadline_ns = 0 } };
            },
            .openat2, .statx, .read, .write, .close => |operation| {
                const handle = decoded.handle orelse return .stale;
                const slot = self.slots.get(handle.slot) orelse return .stale;
                if (slot.generation != handle.generation) return .stale;
                if (!slot.active or slot.operation != operation) return .stale;
                slot.active = false;
                return .{ .file = .{
                    .operation = handle,
                    .kind = switch (operation) {
                        .openat2 => .openat2,
                        .statx => .statx,
                        .read => .read,
                        .write => .write,
                        .close => .close,
                        else => unreachable,
                    },
                    .result = cqe.res,
                } };
            },
            .accept, .recv, .send, .connect, .recvmsg, .sendmsg, .poll => |operation| {
                const handle = decoded.handle orelse return .stale;
                const slot = self.slots.get(handle.slot) orelse return .stale;
                if (slot.generation != handle.generation) return .stale;
                if (!slot.active or slot.operation != operation) return .stale;
                slot.active = false;
                return .{ .socket = .{
                    .operation = handle,
                    .kind = switch (operation) {
                        .accept => .accept,
                        .recv => .recv,
                        .send => .send,
                        .connect => .connect,
                        .recvmsg => .recvmsg,
                        .sendmsg => .sendmsg,
                        .poll => .poll,
                        else => unreachable,
                    },
                    .result = cqe.res,
                } };
            },
        }
    }

    fn availableSlot(self: *Loop) ?usize {
        for (0..self.slots.len()) |index| {
            const slot = self.slots.at(index);
            if (!slot.active and !slot.cancel_pending) return index;
        }
        return null;
    }

    fn activeSlot(self: *Loop, handle: OperationHandle) !*Slot {
        const slot = self.slots.get(handle.slot) orelse return error.StaleOperation;
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
        // Preparation may allocate; completion lookup never does. The slot
        // index must fit the 24 bits encodeFile reserves for it.
        const index = self.availableSlot() orelse grown: {
            if (self.slots.len() + self.slots.chunk_len > 0x0100_0000)
                return error.OperationCapacityExceeded;
            break :grown try self.slots.grow(self.allocator);
        };
        const slot = self.slots.at(index);
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
        @intFromEnum(Operation.write) => .write,
        @intFromEnum(Operation.close) => .close,
        @intFromEnum(Operation.operation_cancel) => .operation_cancel,
        @intFromEnum(Operation.accept) => .accept,
        @intFromEnum(Operation.recv) => .recv,
        @intFromEnum(Operation.send) => .send,
        @intFromEnum(Operation.connect) => .connect,
        @intFromEnum(Operation.recvmsg) => .recvmsg,
        @intFromEnum(Operation.sendmsg) => .sendmsg,
        @intFromEnum(Operation.poll) => .poll,
        @intFromEnum(Operation.timer_alarm) => .timer_alarm,
        @intFromEnum(Operation.timer_update) => .timer_update,
        @intFromEnum(Operation.timer_remove) => .timer_remove,
        @intFromEnum(Operation.signal_poll) => .signal_poll,
        else => return null,
    };
    const generation: u32 = @truncate(value >> 32);
    const handle = switch (operation) {
        .openat2, .statx, .read, .write, .close, .operation_cancel, .accept, .recv, .send, .connect, .recvmsg, .sendmsg, .poll => OperationHandle{
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

pub fn monotonicNow() !u64 {
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

test "missing kernel alarm control retires generation without retrying" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 1);
    defer loop.deinit();

    const operation = try loop.prepareTimeout(std.time.ns_per_s);
    _ = try loop.submit();
    try loop.prepareCancel(operation);
    try loop.synchronizeAlarm();
    try std.testing.expectEqual(Control.remove, loop.control);

    const generation = loop.alarm_generation;
    try std.testing.expectEqual(Dispatch.timer_control, loop.dispatch(.{
        .user_data = encode(.timer_remove, generation),
        .res = -@as(i32, @intFromEnum(linux.E.NOENT)),
        .flags = 0,
    }));
    try std.testing.expect(!loop.alarm_active);
    try std.testing.expectEqual(generation, loop.retired_alarm_generation.?);

    // The next submit must not enqueue another remove while the original
    // alarm CQE is pending. Consuming that CQE completes retirement.
    const pending_before = loop.ring.sq.sqe_tail - loop.ring.sq.sqe_head;
    try loop.synchronizeAlarm();
    try std.testing.expectEqual(pending_before, loop.ring.sq.sqe_tail - loop.ring.sq.sqe_head);
    try std.testing.expectEqual(Dispatch.timer_control, loop.dispatch(.{
        .user_data = encode(.timer_alarm, generation),
        .res = -@as(i32, @intFromEnum(linux.E.CANCELED)),
        .flags = 0,
    }));
    try std.testing.expect(loop.retired_alarm_generation == null);
    try std.testing.expect(!loop.hasPendingTimerKernelWork());
}

test "missing alarm control after consumed expiry does not wait for another alarm CQE" {
    for ([_]Control{ .remove, .update }) |control| {
        var loop: Loop = undefined;
        try loop.init(std.testing.allocator, 8, 1);
        defer loop.deinit();
        const operation = try loop.prepareTimeout(std.time.ns_per_s);
        _ = try loop.submit();
        try loop.prepareCancel(operation);
        loop.control = control;
        const generation = loop.alarm_generation;
        try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(.{
            .user_data = encode(.timer_alarm, generation),
            .res = -@as(i32, @intFromEnum(linux.E.TIME)),
            .flags = 0,
        }));
        try std.testing.expectEqual(Dispatch.timer_control, loop.dispatch(.{
            .user_data = encode(if (control == .remove) .timer_remove else .timer_update, generation),
            .res = -@as(i32, @intFromEnum(linux.E.NOENT)),
            .flags = 0,
        }));
        try std.testing.expect(loop.retired_alarm_generation == null);
        try std.testing.expect(!loop.hasPendingTimerKernelWork());
    }
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

test "write operation reports stable identity and writes a pipe" {
    var pipe: [2]linux.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.PipeCreationFailed,
    }
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);

    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 4, 1);
    defer loop.deinit();

    const bytes = "clipboard payload";
    const operation = try loop.prepareWrite(pipe[1], bytes, std.math.maxInt(u64));
    _ = try loop.submit();
    const completion = loop.dispatch(try loop.wait()).file;
    try std.testing.expectEqual(operation, completion.operation);
    try std.testing.expectEqual(OperationKind.write, completion.kind);
    try std.testing.expectEqual(@as(i32, bytes.len), completion.result);

    var output: [bytes.len]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try std.posix.read(pipe[0], &output));
    try std.testing.expectEqualStrings(bytes, &output);
}

test "operation slots grow past their initial capacity without moving" {
    var pipe: [2]linux.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.PipeCreationFailed,
    }
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);

    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 16, 2);
    defer loop.deinit();
    const first = try loop.prepareWrite(pipe[1], "a", std.math.maxInt(u64));
    const first_slot = loop.slots.at(first.slot);
    var operations: [7]OperationHandle = undefined;
    for (&operations) |*operation| operation.* = try loop.prepareWrite(pipe[1], "b", std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 8), loop.slots.len());
    try std.testing.expectEqual(first_slot, loop.slots.at(first.slot));
    _ = try loop.submit();
    for (0..8) |_| try std.testing.expectEqual(@as(i32, 1), loop.dispatch(try loop.wait()).file.result);
    try std.testing.expect(!loop.hasPendingOperations());
    // Drained slots are reused before the storage grows again.
    _ = try loop.prepareWrite(pipe[1], "c", std.math.maxInt(u64));
    _ = try loop.submit();
    _ = loop.dispatch(try loop.wait());
    try std.testing.expectEqual(@as(usize, 8), loop.slots.len());
}

test "signal watch wakes the ring and retains the first signal through shutdown" {
    var previous_mask = linux.sigemptyset();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sigprocmask(linux.SIG.BLOCK, null, &previous_mask)));
    {
        var loop: Loop = undefined;
        try loop.init(std.testing.allocator, 4, 1);
        defer loop.deinit();
        try loop.watchSignals(&.{ .USR1, .USR2 });
        try std.testing.expectEqual(null, try loop.receivedSignal());
        _ = try loop.submit();
        try std.testing.expect(!loop.hasPendingOperations());
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.tgkill(linux.getpid(), linux.gettid(), .USR1)));
        try std.testing.expectEqual(Dispatch.signal_wakeup, loop.dispatch(try loop.wait()));
        try std.testing.expectEqual(linux.SIG.USR1, (try loop.receivedSignal()).?);
        // A second signal must not change the exit reason or terminate the
        // process when deinit restores the original mask.
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.tgkill(linux.getpid(), linux.gettid(), .USR2)));
        _ = try loop.submit();
        try std.testing.expectEqual(linux.SIG.USR1, (try loop.receivedSignal()).?);
        try std.testing.expect(!loop.hasPendingOperations());
    }
    var restored_mask = linux.sigemptyset();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sigprocmask(linux.SIG.BLOCK, null, &restored_mask)));
    try std.testing.expectEqualDeep(previous_mask, restored_mask);
}

test "signal watch does not prevent normal teardown with an outstanding poll" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 4, 1);
    defer loop.deinit();
    try loop.watchSignals(&.{.USR1});
    _ = try loop.submit();
    try std.testing.expect(loop.signal_poll_active);
    try std.testing.expect(!loop.hasPendingOperations());
}

fn ignoreTestSignal(_: linux.SIG) callconv(.c) void {}

fn interruptWaitingThread(pid: linux.pid_t, tid: linux.pid_t) void {
    const delay: linux.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    _ = linux.nanosleep(&delay, null);
    _ = linux.tgkill(pid, tid, .USR1);
}

test "a signal interrupting the completion wait does not fail the loop" {
    // Without SA_RESTART the kernel returns EINTR from io_uring_enter, the
    // same result a freezer thaw produces when the system resumes.
    const action: linux.Sigaction = .{
        .handler = .{ .handler = ignoreTestSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    var previous: linux.Sigaction = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.sigaction(.USR1, &action, &previous)));
    defer _ = linux.sigaction(.USR1, &previous, null);

    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 4, 1);
    defer loop.deinit();

    const timeout = try loop.prepareTimeout(100 * std.time.ns_per_ms);
    _ = try loop.submit();
    const interrupter = try std.Thread.spawn(.{}, interruptWaitingThread, .{ linux.getpid(), linux.gettid() });
    defer interrupter.join();
    try std.testing.expectEqual(Dispatch.timer_wakeup, loop.dispatch(try loop.wait()));
    try std.testing.expectEqual(timeout, (try loop.takeExpired()).?.operation);
}
