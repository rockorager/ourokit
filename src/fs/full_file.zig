const std = @import("std");
const core = @import("../core/root.zig");
const io = @import("../loop/root.zig");

const linux = std.os.linux;
const invalid_fd: linux.fd_t = -1;

pub const ReadHandle = core.Handle;

pub const Options = struct {
    max_bytes: usize,
    resolve: u64 = io.Resolve.beneath | io.Resolve.no_symlinks | io.Resolve.no_magic_links,
};

pub const Identity = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
    mount_id: ?u64,
    size: u64,
    modified: linux.statx_timestamp,
    changed: linux.statx_timestamp,
};

pub const Contents = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    len: usize,
    identity: Identity,

    pub fn bytes(self: *const Contents) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn deinit(self: *Contents) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

const State = enum {
    free,
    opening,
    stat_before,
    reading,
    stat_after,
    closing,
    complete,
};

const Slot = struct {
    generation: u32 = 0,
    state: State = .free,
    directory: linux.fd_t = invalid_fd,
    path: ?[:0]u8 = null,
    max_bytes: usize = 0,
    resolve: u64 = 0,
    fd: linux.fd_t = invalid_fd,
    operation: io.OperationHandle = .invalid,
    before: linux.Statx = undefined,
    after: linux.Statx = undefined,
    storage: ?[]u8 = null,
    bytes_read: usize = 0,
    failure: ?anyerror = null,
    cancellation_requested: bool = false,
};

/// Fixed-capacity owner for asynchronous whole-file reads. It enters no
/// language runtime and submits nothing itself: callers batch the prepared
/// SQEs through the application-owned loop and route file completions here.
pub const Reader = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    slots: []Slot,

    pub fn init(
        self: *Reader,
        allocator: std.mem.Allocator,
        loop: *io.Loop,
        capacity: usize,
    ) !void {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .loop = loop, .slots = slots };
    }

    pub fn deinit(self: *Reader) void {
        for (self.slots) |slot| std.debug.assert(slot.state == .free);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn startAt(
        self: *Reader,
        directory: linux.fd_t,
        path: []const u8,
        options: Options,
    ) !ReadHandle {
        if (path.len == 0 or options.max_bytes == 0) return error.InvalidReadRequest;
        const index = self.availableSlot() orelse return error.ReadCapacityExceeded;
        const owned_path = try self.allocator.allocSentinel(u8, path.len, 0);
        errdefer self.allocator.free(owned_path);
        @memcpy(owned_path, path);
        const slot = &self.slots[index];
        var generation = slot.generation +% 1;
        if (generation == 0) generation = 1;
        slot.* = .{
            .generation = generation,
            .state = .opening,
            .directory = directory,
            .path = owned_path,
            .max_bytes = options.max_bytes,
            .resolve = options.resolve,
        };
        slot.operation = self.loop.prepareOpenAt2(directory, owned_path, .{
            .flags = @as(u32, @bitCast(linux.O{
                .NONBLOCK = true,
                .NOCTTY = true,
                .CLOEXEC = true,
            })),
            .resolve = options.resolve,
        }) catch |err| {
            self.releaseSlot(slot);
            return err;
        };
        return .{ .slot = @intCast(index), .generation = generation };
    }

    /// Requests cancellation of the current kernel operation. The read and
    /// any opened descriptor remain owned until their terminal CQEs drain.
    pub fn cancel(self: *Reader, handle: ReadHandle) !void {
        const slot = try self.activeSlot(handle);
        if (slot.state == .complete or slot.cancellation_requested) return;
        slot.cancellation_requested = true;
        if (slot.state != .closing) try self.loop.prepareCancel(slot.operation);
    }

    /// Completion-phase transition only. It may prepare the next SQE but never
    /// submits the ring or invokes a consumer callback.
    pub fn dispatch(self: *Reader, completion: io.FileCompletion) !bool {
        const slot = self.slotForOperation(completion.operation) orelse return false;
        if (completion.kind != expectedKind(slot.state)) return error.UnexpectedFileCompletion;
        switch (slot.state) {
            .opening => try self.completeOpen(slot, completion.result),
            .stat_before => try self.completeFirstStat(slot, completion.result),
            .reading => try self.completeRead(slot, completion.result),
            .stat_after => try self.completeSecondStat(slot, completion.result),
            .closing => completeClose(slot, completion.result),
            .free, .complete => return error.UnexpectedFileCompletion,
        }
        return true;
    }

    pub fn finished(self: *Reader, handle: ReadHandle) !bool {
        return (try self.activeSlot(handle)).state == .complete;
    }

    /// Transfers successful bytes to the caller or releases failed/canceled
    /// storage. Returns null while work remains in flight.
    pub fn take(self: *Reader, handle: ReadHandle) !?Contents {
        const slot = try self.activeSlot(handle);
        if (slot.state != .complete) return null;
        const failure = slot.failure;
        const canceled = slot.cancellation_requested;
        if (failure == null and !canceled) {
            const storage = slot.storage.?;
            const result: Contents = .{
                .allocator = self.allocator,
                .storage = storage,
                .len = slot.bytes_read,
                .identity = identity(slot.after),
            };
            slot.storage = null;
            self.releaseSlot(slot);
            return result;
        }
        self.releaseSlot(slot);
        if (canceled) return error.Canceled;
        return failure.?;
    }

    fn completeOpen(self: *Reader, slot: *Slot, result: i32) !void {
        if (result < 0) {
            if (!slot.cancellation_requested) slot.failure = resultError(result);
            slot.state = .complete;
            return;
        }
        slot.fd = result;
        if (slot.cancellation_requested) return self.beginClose(slot);
        slot.state = .stat_before;
        slot.operation = try self.loop.prepareStatx(slot.fd, &slot.before);
    }

    fn completeFirstStat(self: *Reader, slot: *Slot, result: i32) !void {
        if (result < 0) slot.failure = resultError(result);
        if (slot.failure == null and !linux.S.ISREG(slot.before.mode))
            slot.failure = error.NotRegularFile;
        if (slot.failure == null and slot.before.size > slot.max_bytes)
            slot.failure = error.FileTooLarge;
        if (slot.failure != null or slot.cancellation_requested) return self.beginClose(slot);

        const size: usize = std.math.cast(usize, slot.before.size) orelse {
            slot.failure = error.FileTooLarge;
            return self.beginClose(slot);
        };
        const allocation_size = std.math.add(usize, size, 1) catch {
            slot.failure = error.FileTooLarge;
            return self.beginClose(slot);
        };
        slot.storage = self.allocator.alloc(u8, allocation_size) catch |err| {
            slot.failure = err;
            return self.beginClose(slot);
        };
        slot.bytes_read = 0;
        try self.beginRead(slot);
    }

    fn completeRead(self: *Reader, slot: *Slot, result: i32) !void {
        if (result < 0) {
            slot.failure = resultError(result);
            return self.beginClose(slot);
        }
        if (slot.cancellation_requested) return self.beginClose(slot);
        if (result == 0) {
            if (slot.bytes_read != slot.before.size)
                slot.failure = error.FileChangedDuringRead;
            if (slot.failure != null) return self.beginClose(slot);
            slot.state = .stat_after;
            slot.operation = try self.loop.prepareStatx(slot.fd, &slot.after);
            return;
        }
        slot.bytes_read += @intCast(result);
        if (slot.bytes_read > slot.before.size) {
            slot.failure = error.FileChangedDuringRead;
            return self.beginClose(slot);
        }
        try self.beginRead(slot);
    }

    fn completeSecondStat(self: *Reader, slot: *Slot, result: i32) !void {
        if (result < 0)
            slot.failure = resultError(result)
        else if (!sameSnapshot(slot.before, slot.after))
            slot.failure = error.FileChangedDuringRead;
        try self.beginClose(slot);
    }

    fn completeClose(slot: *Slot, result: i32) void {
        slot.fd = invalid_fd;
        if (result < 0 and slot.failure == null and !slot.cancellation_requested)
            slot.failure = resultError(result);
        slot.state = .complete;
    }

    fn beginRead(self: *Reader, slot: *Slot) !void {
        slot.state = .reading;
        slot.operation = try self.loop.prepareRead(
            slot.fd,
            slot.storage.?[slot.bytes_read..],
            slot.bytes_read,
        );
    }

    fn beginClose(self: *Reader, slot: *Slot) !void {
        slot.state = .closing;
        slot.operation = try self.loop.prepareClose(slot.fd);
    }

    fn availableSlot(self: *Reader) ?usize {
        for (self.slots, 0..) |slot, index| if (slot.state == .free) return index;
        return null;
    }

    fn activeSlot(self: *Reader, handle: ReadHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleRead;
        const slot = &self.slots[handle.slot];
        if (slot.state == .free or slot.generation != handle.generation)
            return error.StaleRead;
        return slot;
    }

    fn slotForOperation(self: *Reader, operation: io.OperationHandle) ?*Slot {
        for (self.slots) |*slot| if (slot.state != .free and slot.state != .complete and
            same(slot.operation, operation)) return slot;
        return null;
    }

    fn releaseSlot(self: *Reader, slot: *Slot) void {
        if (slot.storage) |storage| self.allocator.free(storage);
        if (slot.path) |path| self.allocator.free(path);
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
    }
};

fn expectedKind(state: State) io.OperationKind {
    return switch (state) {
        .opening => .openat2,
        .stat_before, .stat_after => .statx,
        .reading => .read,
        .closing => .close,
        .free, .complete => unreachable,
    };
}

fn identity(stat: linux.Statx) Identity {
    return .{
        .device_major = stat.dev_major,
        .device_minor = stat.dev_minor,
        .inode = stat.ino,
        .mount_id = if (stat.mask.MNT_ID) stat.mnt_id else null,
        .size = stat.size,
        .modified = stat.mtime,
        .changed = stat.ctime,
    };
}

fn sameSnapshot(first: linux.Statx, second: linux.Statx) bool {
    return first.dev_major == second.dev_major and
        first.dev_minor == second.dev_minor and
        first.ino == second.ino and
        first.size == second.size and
        timestampEqual(first.mtime, second.mtime) and
        timestampEqual(first.ctime, second.ctime) and
        (!first.mask.MNT_ID or !second.mask.MNT_ID or first.mnt_id == second.mnt_id);
}

fn timestampEqual(first: linux.statx_timestamp, second: linux.statx_timestamp) bool {
    return first.sec == second.sec and first.nsec == second.nsec;
}

fn resultError(result: i32) anyerror {
    const errno: linux.E = @enumFromInt(-result);
    return switch (errno) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .XDEV => error.PathEscapesRoot,
        .NAMETOOLONG => error.NameTooLong,
        .CANCELED => error.Canceled,
        .NOMEM => error.OutOfMemory,
        else => error.FileIoFailed,
    };
}

fn same(first: core.Handle, second: core.Handle) bool {
    return first.slot == second.slot and first.generation == second.generation;
}

fn drive(reader: *Reader, loop: *io.Loop, handle: ReadHandle) !Contents {
    while (!(try reader.finished(handle))) {
        _ = try loop.submit();
        const cqe = try loop.wait();
        const dispatch = loop.dispatch(cqe);
        switch (dispatch) {
            .file => |completion| try std.testing.expect(try reader.dispatch(completion)),
            .operation_cancel => {},
            else => {
                std.debug.print("unexpected full-file dispatch: {s} user_data=0x{x}\n", .{
                    @tagName(dispatch), cqe.user_data,
                });
                return error.UnexpectedCompletion;
            },
        }
    }
    return (try reader.take(handle)).?;
}

test "full file reader reads exact bytes and records opened-file identity" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "module.lua",
        .data = "return { answer = 42 }",
    });
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var reader: Reader = undefined;
    try reader.init(std.testing.allocator, &loop, 2);
    defer reader.deinit();

    const handle = try reader.startAt(temporary.dir.handle, "module.lua", .{ .max_bytes = 1024 });
    var contents = try drive(&reader, &loop, handle);
    defer contents.deinit();
    try std.testing.expectEqualStrings("return { answer = 42 }", contents.bytes());
    try std.testing.expectEqual(@as(u64, contents.bytes().len), contents.identity.size);
    try std.testing.expect(contents.identity.inode != 0);
}

test "full file reader rejects files beyond its bound" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "large.lua",
        .data = "12345",
    });
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var reader: Reader = undefined;
    try reader.init(std.testing.allocator, &loop, 1);
    defer reader.deinit();

    const handle = try reader.startAt(temporary.dir.handle, "large.lua", .{ .max_bytes = 4 });
    while (!(try reader.finished(handle))) {
        _ = try loop.submit();
        const cqe = try loop.wait();
        const dispatch = loop.dispatch(cqe);
        switch (dispatch) {
            .file => |completion| try std.testing.expect(try reader.dispatch(completion)),
            else => {
                std.debug.print("unexpected bounded-read dispatch: {s} user_data=0x{x}\n", .{
                    @tagName(dispatch), cqe.user_data,
                });
                return error.UnexpectedCompletion;
            },
        }
    }
    try std.testing.expectError(error.FileTooLarge, reader.take(handle));
}

test "full file reader cancellation drains operation and descriptor completions" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "cancel.lua",
        .data = "return true",
    });
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 8);
    defer loop.deinit();
    var reader: Reader = undefined;
    try reader.init(std.testing.allocator, &loop, 1);
    defer reader.deinit();

    const handle = try reader.startAt(temporary.dir.handle, "cancel.lua", .{ .max_bytes = 1024 });
    try reader.cancel(handle);
    var cancel_seen = false;
    while (!(try reader.finished(handle)) or !cancel_seen) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| try std.testing.expect(try reader.dispatch(completion)),
            .operation_cancel => cancel_seen = true,
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expectError(error.Canceled, reader.take(handle));
}
