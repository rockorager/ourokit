const std = @import("std");
const linux = std.os.linux;
const Handle = @import("../core/handle.zig").Handle;

pub const OperationHandle = Handle;

const Operation = enum(u8) {
    timeout = 0xa0,
    timeout_cancel = 0xa1,
    openat2 = 0xa2,
    statx = 0xa3,
    read = 0xa4,
    close = 0xa5,
    operation_cancel = 0xa6,
};

pub const OperationKind = enum {
    openat2,
    statx,
    read,
    close,
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
    operation: Operation = .timeout,
    timeout: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    open_how: OpenHow = .{ .flags = 0 },
};

pub const Completion = struct {
    operation: OperationHandle,
    result: i32,
};

pub const FileCompletion = struct {
    operation: OperationHandle,
    kind: OperationKind,
    result: i32,
};

/// `foreign` is intentionally returned unchanged to let one CQ loop route
/// Wayring and future subsystems before or after Ourokit's own operations.
pub const Dispatch = union(enum) {
    foreign,
    stale,
    timeout: Completion,
    timeout_cancel: Completion,
    file: FileCompletion,
    operation_cancel: Completion,
};

/// Ourokit-owned raw io_uring plus a stable operation directory. `Loop` and
/// its slots must retain stable addresses while a platform adapter borrows the
/// ring or the kernel has active operations.
pub const Loop = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    slots: []Slot,

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
            .slots = slots,
        };
    }

    pub fn deinit(self: *Loop) void {
        for (self.slots) |slot| std.debug.assert(!slot.active and !slot.cancel_pending);
        self.ring.deinit();
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Prepares but does not submit a real CLOCK_MONOTONIC io_uring timeout.
    pub fn prepareTimeout(self: *Loop, nanoseconds: u64) !OperationHandle {
        const index = self.availableSlot() orelse return error.OperationCapacityExceeded;
        const slot = &self.slots[index];
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.active = true;
        slot.cancel_pending = false;
        slot.operation = .timeout;
        slot.timeout = .{
            .sec = @intCast(nanoseconds / std.time.ns_per_s),
            .nsec = @intCast(nanoseconds % std.time.ns_per_s),
        };
        const handle: OperationHandle = .{ .slot = @intCast(index), .generation = slot.generation };
        _ = self.ring.timeout(encode(.timeout, handle), &slot.timeout, 0, 0) catch |err| {
            slot.active = false;
            return err;
        };
        return handle;
    }

    /// Prepares cancellation. The operation slot remains unavailable until
    /// both the operation and cancellation terminal CQEs arrive, regardless
    /// of their ordering.
    pub fn prepareCancel(self: *Loop, handle: OperationHandle) !void {
        const slot = try self.activeSlot(handle);
        if (slot.cancel_pending) return error.CancellationAlreadyPending;
        slot.cancel_pending = true;
        if (slot.operation == .timeout) {
            _ = self.ring.timeout_remove(
                encode(.timeout_cancel, handle),
                encode(.timeout, handle),
                0,
            ) catch |err| {
                slot.cancel_pending = false;
                return err;
            };
        } else {
            _ = self.ring.cancel(
                encode(.operation_cancel, handle),
                encode(slot.operation, handle),
                0,
            ) catch |err| {
                slot.cancel_pending = false;
                return err;
            };
        }
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
        sqe.user_data = encode(.openat2, reserved.handle);
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
            encode(.statx, reserved.handle),
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
            encode(.read, reserved.handle),
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
        _ = self.ring.close(encode(.close, reserved.handle), fd) catch |err| {
            reserved.slot.active = false;
            return err;
        };
        return reserved.handle;
    }

    pub fn submit(self: *Loop) !u32 {
        return self.ring.submit();
    }

    pub fn operationCapacity(self: *const Loop) usize {
        return self.slots.len;
    }

    pub fn wait(self: *Loop) !linux.io_uring_cqe {
        return self.ring.copy_cqe();
    }

    /// Validates namespace, slot, and generation before accessing operation
    /// state. No callback is invoked here; callers may only mark work runnable.
    pub fn dispatch(self: *Loop, cqe: linux.io_uring_cqe) Dispatch {
        const decoded = decode(cqe.user_data) orelse return .foreign;
        if (decoded.handle.slot >= self.slots.len) return .stale;
        const slot = &self.slots[decoded.handle.slot];
        if (slot.generation != decoded.handle.generation) return .stale;
        switch (decoded.operation) {
            .timeout => {
                if (!slot.active) return .stale;
                slot.active = false;
                return .{ .timeout = .{ .operation = decoded.handle, .result = cqe.res } };
            },
            .timeout_cancel => {
                if (!slot.cancel_pending) return .stale;
                slot.cancel_pending = false;
                return .{ .timeout_cancel = .{ .operation = decoded.handle, .result = cqe.res } };
            },
            .operation_cancel => {
                if (!slot.cancel_pending) return .stale;
                slot.cancel_pending = false;
                return .{ .operation_cancel = .{ .operation = decoded.handle, .result = cqe.res } };
            },
            .openat2, .statx, .read, .close => |operation| {
                if (!slot.active or slot.operation != operation) return .stale;
                slot.active = false;
                return .{ .file = .{
                    .operation = decoded.handle,
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
    handle: OperationHandle,
};

fn encode(operation: Operation, handle: OperationHandle) u64 {
    return @intFromEnum(operation) |
        (@as(u64, handle.slot) << 8) |
        (@as(u64, handle.generation) << 32);
}

fn decode(value: u64) ?Decoded {
    const operation: Operation = switch (@as(u8, @truncate(value))) {
        @intFromEnum(Operation.timeout) => .timeout,
        @intFromEnum(Operation.timeout_cancel) => .timeout_cancel,
        @intFromEnum(Operation.openat2) => .openat2,
        @intFromEnum(Operation.statx) => .statx,
        @intFromEnum(Operation.read) => .read,
        @intFromEnum(Operation.close) => .close,
        @intFromEnum(Operation.operation_cancel) => .operation_cancel,
        else => return null,
    };
    return .{
        .operation = operation,
        .handle = .{
            .slot = @truncate((value >> 8) & 0x00ff_ffff),
            .generation = @truncate(value >> 32),
        },
    };
}

test "real io_uring timeout dispatches through a generation-checked slot" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();

    const operation = try loop.prepareTimeout(1 * std.time.ns_per_ms);
    _ = try loop.submit();
    const dispatch = loop.dispatch(try loop.wait());
    const completion = switch (dispatch) {
        .timeout => |value| value,
        else => return error.UnexpectedCompletion,
    };
    try std.testing.expectEqual(operation, completion.operation);
    try std.testing.expectEqual(-@as(i32, @intFromEnum(linux.E.TIME)), completion.result);
}

test "timeout cancellation keeps the slot alive through both CQEs" {
    var loop: Loop = undefined;
    try loop.init(std.testing.allocator, 8, 1);
    defer loop.deinit();

    const operation = try loop.prepareTimeout(std.time.ns_per_s);
    try loop.prepareCancel(operation);
    _ = try loop.submit();
    var timeout_seen = false;
    var cancel_seen = false;
    while (!timeout_seen or !cancel_seen) {
        switch (loop.dispatch(try loop.wait())) {
            .timeout => |completion| {
                try std.testing.expectEqual(operation, completion.operation);
                try std.testing.expectEqual(-@as(i32, @intFromEnum(linux.E.CANCELED)), completion.result);
                timeout_seen = true;
            },
            .timeout_cancel => |completion| {
                try std.testing.expectEqual(operation, completion.operation);
                try std.testing.expectEqual(@as(i32, 0), completion.result);
                cancel_seen = true;
            },
            else => return error.UnexpectedCompletion,
        }
    }
}
