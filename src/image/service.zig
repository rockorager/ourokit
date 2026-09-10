const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const images = @import("cache.zig");
const codec = @import("codec.zig");
const Bitmap = @import("pixels.zig").Bitmap;
const build = @import("../ui/instance/build_owner.zig");

pub const Source = union(enum) { path: []const u8, bytes: []const u8 };
pub const OwnerRef = struct { owners: *build.BuildOwners, handle: build.BuildOwnerHandle };
pub const Status = enum { missing, pending, ready, failed };

const max_sources = 64;
const max_owners = 256;
const max_encoded = 16 * 1024 * 1024;
const max_encoded_total = 64 * 1024 * 1024;
const max_decoded = 64 * 1024 * 1024;
const max_decoded_total = images.Cache.max_decoded_bytes;
const Decode = *const fn (std.mem.Allocator, []const u8, codec.Options) anyerror!Bitmap;

const Entry = struct {
    source: Source,
    options: codec.Options,
    state: Status = .pending,
    image: ?images.ImageHandle = null,
    failure: ?anyerror = null,
    unowned: bool = false,
    age: u64,
};

const Owner = struct {
    ref: OwnerRef,
    committed: u64 = 0,
    seen: u64 = 0,
    building: bool = false,
};

const Job = struct {
    source: Source,
    options: codec.Options,
    root: ?linux.fd_t,
    encoded_budget: usize,
    decode: Decode,
    pipe: [2]linux.fd_t,
    byte: [1]u8 = undefined,
    operation: ?io.OperationHandle = null,
    thread: ?std.Thread = null,
    result: anyerror!Bitmap = error.WorkerNotStarted,

    fn run(self: *Job) void {
        self.result = self.load();
        self.signal();
    }

    fn signal(self: *Job) void {
        // The read end remains open until the terminal CQE is consumed. A
        // single byte cannot fill this private blocking pipe. Closing also
        // wakes the reader if a write fails, so no completion is lost.
        while (linux.errno(linux.write(self.pipe[1], &.{1}, 1)) == .INTR) {}
        _ = linux.close(self.pipe[1]);
    }

    fn load(self: *Job) !Bitmap {
        const allocator = std.heap.page_allocator;
        switch (self.source) {
            .bytes => |bytes| return self.decode(allocator, bytes, self.options),
            .path => |path| {
                const root = self.root orelse return error.NoImageRoot;
                if (path.len == 0 or path.len >= 4096 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null)
                    return error.InvalidImagePath;
                const name = try allocator.dupeZ(u8, path);
                defer allocator.free(name);
                const how: io.OpenHow = .{
                    .flags = @as(u32, @bitCast(linux.O{ .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true })),
                    .resolve = io.Resolve.beneath | io.Resolve.no_symlinks | io.Resolve.no_magic_links,
                };
                const opened = linux.syscall4(.openat2, @bitCast(@as(isize, root)), @intFromPtr(name.ptr), @intFromPtr(&how), @sizeOf(io.OpenHow));
                if (linux.errno(opened) != .SUCCESS) return fileError(linux.errno(opened));
                const fd: linux.fd_t = @intCast(opened);
                defer _ = linux.close(fd);
                var stat: linux.Statx = undefined;
                const stated = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &stat);
                if (linux.errno(stated) != .SUCCESS) return fileError(linux.errno(stated));
                if (!stat.mask.TYPE or !stat.mask.SIZE or !linux.S.ISREG(stat.mode)) return error.NotRegularFile;
                if (stat.size > self.encoded_budget) return error.ImageEncodedBudgetExceeded;
                const size: usize = @intCast(stat.size);
                const bytes = try allocator.alloc(u8, size);
                defer allocator.free(bytes);
                var read: usize = 0;
                while (read < size) {
                    const n = linux.read(fd, bytes[read..].ptr, size - read);
                    switch (linux.errno(n)) {
                        .SUCCESS => {},
                        .INTR => continue,
                        else => |err| return fileError(err),
                    }
                    if (n == 0) return error.ImageFileChanged;
                    read += n;
                }
                var extra: [1]u8 = undefined;
                while (true) {
                    const n = linux.read(fd, &extra, 1);
                    switch (linux.errno(n)) {
                        .SUCCESS => if (n != 0) return error.ImageFileChanged,
                        .INTR => continue,
                        else => |err| return fileError(err),
                    }
                    break;
                }
                return self.decode(allocator, bytes, self.options);
            },
        }
    }
};

/// Event-thread-owned source index. Keep the service, loop, and cache alive
/// until canDeinit(); owner registries must dispose their subscriptions before
/// destruction. request only stages work; pump belongs after build commit.
/// Cache storage is bounded to 256 MiB; concurrent retired services may each
/// hold another 64 MiB worker output, plus native codec working memory.
pub const Service = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    cache: *images.Cache,
    root: ?linux.fd_t,
    entries: [max_sources]?Entry = @splat(null),
    owners: [max_owners]?Owner = @splat(null),
    active: ?struct { index: usize, job: *Job } = null,
    stopped: bool = false,
    clock: u64 = 0,
    encoded_bytes: usize = 0,
    encoded_reserved: usize = 0,
    decoded_bytes: usize = 0,
    decode: Decode = codec.decode,

    pub fn init(self: *Service, allocator: std.mem.Allocator, loop: *io.Loop, cache: *images.Cache, root: ?linux.fd_t) !void {
        const owned_root: ?linux.fd_t = if (root) |fd| blk: {
            const duplicated = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
            if (linux.errno(duplicated) != .SUCCESS) return error.ImageRootDupFailed;
            break :blk @intCast(duplicated);
        } else null;
        self.* = .{ .allocator = allocator, .loop = loop, .cache = cache, .root = owned_root };
    }

    pub fn deinit(self: *Service) void {
        std.debug.assert(self.canDeinit());
        self.shutdown();
        if (self.root) |fd| _ = linux.close(fd);
        self.* = undefined;
    }

    pub fn beginOwner(self: *Service, owners: *build.BuildOwners, handle: build.BuildOwnerHandle) !void {
        if (self.stopped) return error.ImageServiceStopped;
        const owner = try self.ensureOwner(.{ .owners = owners, .handle = handle });
        if (owner.building) return error.ImageOwnerAlreadyBuilding;
        owner.building = true;
        owner.seen = 0;
    }

    pub fn commitOwner(self: *Service, owners: *build.BuildOwners, handle: build.BuildOwnerHandle) void {
        const owner = self.findOwner(.{ .owners = owners, .handle = handle }) orelse return;
        if (!owner.building) return;
        owner.committed = owner.seen;
        owner.seen = 0;
        owner.building = false;
        self.discardUnwantedQueued();
    }

    pub fn rollbackOwner(self: *Service, owners: *build.BuildOwners, handle: build.BuildOwnerHandle) void {
        const owner = self.findOwner(.{ .owners = owners, .handle = handle }) orelse return;
        owner.seen = 0;
        owner.building = false;
        self.discardUnwantedQueued();
    }

    pub fn disposeOwner(self: *Service, owners: *build.BuildOwners, handle: build.BuildOwnerHandle) void {
        for (&self.owners) |*slot| if (slot.*) |owner| {
            if (sameOwner(owner.ref, .{ .owners = owners, .handle = handle })) slot.* = null;
        };
        self.discardUnwantedQueued();
    }

    /// A ready return is borrowed until the next service mutation. Retain it
    /// in Cache before placing it in a tree/frame or requesting another asset.
    /// Decode/path errors become stable failed entries, never request errors.
    pub fn request(self: *Service, source: Source, options: codec.Options, owner_ref: ?OwnerRef) !?images.ImageHandle {
        if (self.stopped) return error.ImageServiceStopped;
        const owner = if (owner_ref) |ref| try self.ensureOwner(ref) else null;
        const normalized = normalize(options);
        const index = self.find(source, normalized) orelse blk: {
            const key = sourceBytes(source);
            if (key.len > max_encoded) return error.ImageEncodedBudgetExceeded;
            while (self.encoded_bytes + self.encoded_reserved > max_encoded_total - key.len) {
                if (!self.evict(null)) return error.ImageEncodedBudgetExceeded;
            }
            var free = self.freeSlot();
            if (free == null) {
                if (!self.evict(null)) return error.ImageSourceCapacityExceeded;
                free = self.freeSlot();
            }
            const copied = try self.allocator.dupe(u8, key);
            self.encoded_bytes += copied.len;
            self.entries[free.?] = .{
                .source = switch (source) {
                    .bytes => .{ .bytes = copied },
                    .path => .{ .path = copied },
                },
                .options = normalized,
                .age = self.clock,
            };
            break :blk free.?;
        };
        self.clock +%= 1;
        const entry = &self.entries[index].?;
        entry.age = self.clock;
        if (owner) |subscriber| {
            if (subscriber.building) subscriber.seen |= bit(index) else subscriber.committed |= bit(index);
        } else entry.unowned = true;
        return entry.image;
    }

    pub fn status(self: *const Service, source: Source, options: codec.Options) Status {
        const index = self.find(source, normalize(options)) orelse return .missing;
        return self.entries[index].?.state;
    }

    pub fn failure(self: *const Service, source: Source, options: codec.Options) ?anyerror {
        const index = self.find(source, normalize(options)) orelse return null;
        return self.entries[index].?.failure;
    }

    pub fn pump(self: *Service) !void {
        if (self.active) |active| {
            if (active.job.operation == null) active.job.operation = try self.loop.prepareRead(active.job.pipe[0], &active.job.byte, std.math.maxInt(u64));
            return;
        }
        if (self.stopped) return;
        for (&self.entries, 0..) |*slot, index| {
            const entry = if (slot.*) |*e| e else continue;
            if (entry.state != .pending) continue;
            // Make room before starting, then constrain output to the current
            // cache headroom. This is not a reservation across generations;
            // Cache.insert remains the authoritative shared storage bound.
            while (self.cache.byteSize() > max_decoded_total - entry.options.max_decoded_bytes) {
                if (!self.evict(index)) break;
            }
            const job = try std.heap.page_allocator.create(Job);
            errdefer std.heap.page_allocator.destroy(job);
            var pipe: [2]linux.fd_t = undefined;
            if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.ImagePipeFailed;
            errdefer {
                _ = linux.close(pipe[0]);
                _ = linux.close(pipe[1]);
            }
            job.* = .{
                .source = entry.source,
                .options = entry.options,
                .root = self.root,
                .encoded_budget = @min(max_encoded, max_encoded_total - self.encoded_bytes),
                .decode = self.decode,
                .pipe = pipe,
            };
            job.options.max_decoded_bytes = @min(job.options.max_decoded_bytes, max_decoded_total - self.cache.byteSize());
            job.operation = try self.loop.prepareRead(pipe[0], &job.byte, std.math.maxInt(u64));
            self.active = .{ .index = index, .job = job };
            self.encoded_reserved = if (entry.source == .path) job.encoded_budget else 0;
            // After prepareRead, cleanup must follow its CQE even if spawning
            // fails. Publish that failure through the same completion path.
            job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch |err| {
                job.result = err;
                job.signal();
                return;
            };
            return;
        }
    }

    pub fn dispatch(self: *Service, completion: io.FileCompletion) !bool {
        const active = self.active orelse return false;
        const operation = active.job.operation orelse return false;
        if (!sameHandle(operation, completion.operation)) return false;
        if (completion.kind != .read) return error.UnexpectedImageCompletion;
        active.job.operation = null;
        // A canceled/interrupted read is not proof the worker has finished.
        // Re-arm via pump, including while stopped; never join prematurely.
        if (completion.result < 0) {
            try self.pump();
            return true;
        }
        if (active.job.thread) |thread| thread.join();
        _ = linux.close(active.job.pipe[0]);
        const result = active.job.result;
        std.heap.page_allocator.destroy(active.job);
        self.active = null;
        self.encoded_reserved = 0;
        if (self.stopped) {
            if (result) |value| {
                var bitmap = value;
                bitmap.deinit();
            } else |_| {}
            self.remove(active.index);
            return true;
        }
        const entry = &self.entries[active.index].?;
        if (result) |value| {
            var bitmap = value;
            if (bitmap.pixels.len > entry.options.max_decoded_bytes) {
                bitmap.deinit();
                entry.failure = error.ImageDecodedBudgetExceeded;
            } else {
                entry.image = self.cache.insert(bitmap) catch |err| blk: {
                    bitmap.deinit();
                    entry.failure = err;
                    break :blk null;
                };
                if (entry.image != null) self.decoded_bytes += bitmap.pixels.len;
            }
        } else |err| entry.failure = err;
        entry.state = if (entry.image != null) .ready else .failed;
        var notification_error: ?anyerror = null;
        for (&self.owners) |*slot| if (slot.*) |owner| {
            if (!owner.ref.owners.isActive(owner.ref.handle)) {
                slot.* = null;
                continue;
            }
            if (owner.committed & bit(active.index) != 0) {
                _ = owner.ref.owners.markDirty(owner.ref.handle) catch |err| {
                    notification_error = err;
                    continue;
                };
            }
        };
        if (notification_error) |err| return err;
        return true;
    }

    pub fn hasPending(self: *const Service) bool {
        if (self.active != null) return true;
        for (self.entries) |slot| if (slot) |entry| {
            if (entry.state == .pending) return true;
        };
        return false;
    }

    pub fn canDeinit(self: *const Service) bool {
        return self.active == null;
    }

    /// Nonblocking retirement: never cancel the read or close a live worker's
    /// descriptors. Continue routing CQEs (and pump after read errors) until
    /// canDeinit; the eventual bitmap is discarded rather than published.
    pub fn shutdown(self: *Service) void {
        self.stopped = true;
        self.owners = @splat(null);
        for (self.entries, 0..) |entry, index| {
            if (entry == null or self.isActive(index)) continue;
            self.remove(index);
        }
    }

    fn findOwner(self: *Service, ref: OwnerRef) ?*Owner {
        for (&self.owners) |*slot| if (slot.*) |*owner| {
            if (sameOwner(owner.ref, ref)) return owner;
        };
        return null;
    }

    fn ensureOwner(self: *Service, ref: OwnerRef) !*Owner {
        if (!ref.owners.isActive(ref.handle)) return error.StaleBuildOwner;
        if (self.findOwner(ref)) |owner| return owner;
        for (&self.owners) |*slot| {
            if (slot.*) |owner| {
                if (owner.ref.owners.isActive(owner.ref.handle)) continue;
            }
            slot.* = .{ .ref = ref };
            return &slot.*.?;
        }
        return error.ImageOwnerCapacityExceeded;
    }

    fn find(self: *const Service, source: Source, options: codec.Options) ?usize {
        for (self.entries, 0..) |slot, index| if (slot) |entry| {
            if (std.meta.activeTag(source) == std.meta.activeTag(entry.source) and
                std.mem.eql(u8, sourceBytes(source), sourceBytes(entry.source)) and
                optionsEqual(options, entry.options)) return index;
        };
        return null;
    }

    fn freeSlot(self: *const Service) ?usize {
        for (self.entries, 0..) |slot, index| if (slot == null) return index;
        return null;
    }

    fn isActive(self: *const Service, index: usize) bool {
        return if (self.active) |active| active.index == index else false;
    }

    fn subscribed(self: *const Service, index: usize) bool {
        for (self.owners) |slot| if (slot) |owner| {
            if ((owner.committed | owner.seen) & bit(index) != 0 and owner.ref.owners.isActive(owner.ref.handle)) return true;
        };
        return false;
    }

    fn discardUnwantedQueued(self: *Service) void {
        for (self.entries, 0..) |slot, index| if (slot) |entry| {
            if (entry.state == .pending and !entry.unowned and !self.isActive(index) and !self.subscribed(index)) self.remove(index);
        };
    }

    fn evict(self: *Service, except: ?usize) bool {
        var oldest: ?usize = null;
        for (self.entries, 0..) |slot, index| if (slot) |entry| {
            if (except == index or self.isActive(index) or self.subscribed(index)) continue;
            if (oldest == null or entry.age < self.entries[oldest.?].?.age) oldest = index;
        };
        if (oldest) |index| {
            self.remove(index);
            return true;
        }
        return false;
    }

    fn remove(self: *Service, index: usize) void {
        std.debug.assert(!self.isActive(index));
        const entry = self.entries[index].?;
        if (entry.image) |image| {
            self.decoded_bytes -= (self.cache.get(image) catch unreachable).pixels.len;
            self.cache.release(image) catch unreachable;
        }
        const key = sourceBytes(entry.source);
        self.encoded_bytes -= key.len;
        self.allocator.free(key);
        self.entries[index] = null;
        for (&self.owners) |*slot| if (slot.*) |*owner| {
            owner.committed &= ~bit(index);
            owner.seen &= ~bit(index);
        };
    }
};

fn normalize(options: codec.Options) codec.Options {
    var result = options;
    result.max_decoded_bytes = @min(result.max_decoded_bytes, max_decoded);
    result.max_dimension = @min(result.max_dimension, 8192);
    return result;
}

fn optionsEqual(a: codec.Options, b: codec.Options) bool {
    // Even an invalid NaN scale must find its stable failed source record.
    if (@as(u32, @bitCast(a.scale)) != @as(u32, @bitCast(b.scale))) return false;
    var first = a;
    var second = b;
    first.scale = 1;
    second.scale = 1;
    return std.meta.eql(first, second);
}

fn sourceBytes(source: Source) []const u8 {
    return switch (source) {
        inline else => |bytes| bytes,
    };
}

fn bit(index: usize) u64 {
    return @as(u64, 1) << @intCast(index);
}

fn sameHandle(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sameOwner(a: OwnerRef, b: OwnerRef) bool {
    return a.owners == b.owners and sameHandle(a.handle, b.handle);
}

fn fileError(err: linux.E) anyerror {
    return switch (err) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .LOOP => error.ImageSymlinkForbidden,
        .XDEV => error.ImagePathEscapesRoot,
        else => error.ImageFileIoFailed,
    };
}

const TestContext = struct {
    loop: io.Loop,
    cache: images.Cache,
    scheduler: @import("../task/scheduler.zig").Scheduler,
    owners: build.BuildOwners,
    refs: [2]OwnerRef,
    service: Service,

    fn init(self: *TestContext, root: ?linux.fd_t) !void {
        try self.loop.init(std.testing.allocator, 16, 8);
        errdefer self.loop.deinit();
        self.cache = try images.Cache.init(std.testing.allocator, 128);
        errdefer self.cache.deinit();
        try self.scheduler.init(std.testing.allocator, 8, 1, 0);
        errdefer self.scheduler.deinit();
        try self.owners.init(std.testing.allocator, &self.scheduler, self.scheduler.application_scope, 4, 8);
        self.refs = .{
            .{ .owners = &self.owners, .handle = try self.owners.mount(null, 1) },
            .{ .owners = &self.owners, .handle = try self.owners.mount(null, 2) },
        };
        var cycle = self.owners.beginCycle();
        while (try cycle.take()) |work| try self.owners.complete(work);
        try self.service.init(std.testing.allocator, &self.loop, &self.cache, root);
        self.service.decode = testDecode;
    }

    fn deinit(self: *TestContext) void {
        self.service.shutdown();
        self.drain() catch unreachable;
        self.service.deinit();
        for (self.refs) |ref| if (self.owners.isActive(ref.handle)) self.owners.retire(ref.handle) catch unreachable;
        self.scheduler.applyQueuedCancellations() catch unreachable;
        self.owners.collectRetired() catch unreachable;
        self.owners.deinit();
        self.scheduler.deinit();
        self.cache.deinit();
        self.loop.deinit();
    }

    fn drain(self: *TestContext) !void {
        while (self.service.hasPending() or self.loop.hasPendingOperations() or self.loop.hasPendingTimerKernelWork()) {
            try self.service.pump();
            _ = try self.loop.submit();
            switch (self.loop.dispatch(try self.loop.wait())) {
                .file => |completion| try std.testing.expect(try self.service.dispatch(completion)),
                .operation_cancel, .timer_wakeup, .timer_control => {},
                else => return error.UnexpectedTestCompletion,
            }
        }
    }
};

fn testDecode(allocator: std.mem.Allocator, bytes: []const u8, options: codec.Options) !Bitmap {
    if (std.mem.eql(u8, bytes, "bad")) return error.TestBadImage;
    if (options.max_decoded_bytes < 4) return error.ImageDecodedBudgetExceeded;
    return .{
        .allocator = allocator,
        .pixels = try allocator.dupe(u8, &.{ if (bytes.len > 0) bytes[0] else 0, 13, 29, 255 }),
        .width = 1,
        .height = 1,
        .intrinsic_width = options.width orelse 1,
        .intrinsic_height = 1,
    };
}

const TestGate = struct {
    var pipe: [2]linux.fd_t = undefined;

    fn init() !void {
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.TestPipeFailed;
    }

    fn release() void {
        std.debug.assert(linux.write(pipe[1], &.{1}, 1) == 1);
    }

    fn deinit() void {
        _ = linux.close(pipe[0]);
        _ = linux.close(pipe[1]);
    }

    fn decode(allocator: std.mem.Allocator, bytes: []const u8, options: codec.Options) !Bitmap {
        var byte: [1]u8 = undefined;
        while (true) {
            const n = linux.read(pipe[0], &byte, 1);
            if (linux.errno(n) == .INTR) continue;
            if (n != 1) return error.TestGateFailed;
            break;
        }
        return testDecode(allocator, bytes, options);
    }
};

test "image service queues owned deduplicated keys without launching work" {
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    const service = &context.service;
    var bytes = [_]u8{ 7, 21, 43 };
    try std.testing.expect(try service.request(.{ .bytes = &bytes }, .{}, context.refs[0]) == null);
    bytes[0] = 99;
    try std.testing.expect(try service.request(.{ .bytes = &.{ 7, 21, 43 } }, .{}, context.refs[1]) == null);
    try std.testing.expectEqual(@as(usize, 3), service.encoded_bytes);
    _ = try service.request(.{ .bytes = &.{ 7, 21, 43 } }, .{ .width = 5 }, context.refs[1]);
    try std.testing.expectEqual(@as(usize, 6), service.encoded_bytes);
    _ = try service.request(.{ .bytes = &.{ 7, 21, 43 } }, .{ .scale = 2 }, context.refs[1]);
    try std.testing.expectEqual(@as(usize, 9), service.encoded_bytes);
    try std.testing.expect(service.active == null);
    try std.testing.expect(!context.loop.hasPendingOperations());
    try context.drain();
    const first = (try service.request(.{ .bytes = &.{ 7, 21, 43 } }, .{}, context.refs[0])).?;
    const duplicate = (try service.request(.{ .bytes = &.{ 7, 21, 43 } }, .{}, context.refs[1])).?;
    const different = (try service.request(.{ .bytes = &.{ 7, 21, 43 } }, .{ .width = 5 }, context.refs[1])).?;
    const scaled = (try service.request(.{ .bytes = &.{ 7, 21, 43 } }, .{ .scale = 2 }, context.refs[1])).?;
    try std.testing.expectEqual(first, duplicate);
    try std.testing.expect(!sameHandle(first, different));
    try std.testing.expect(!sameHandle(first, scaled));
    try std.testing.expect(optionsEqual(.{ .scale = std.math.nan(f32) }, .{ .scale = std.math.nan(f32) }));
    try std.testing.expectEqualSlices(u8, &.{ 7, 13, 29, 255 }, (try context.cache.get(first)).pixels);
    try std.testing.expectEqual(@as(u32, 5), (try context.cache.get(different)).intrinsic_width);
}

test "image service worker leaves timers responsive and retirement drains asynchronously" {
    try TestGate.init();
    defer TestGate.deinit();
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    var released = false;
    defer if (!released) TestGate.release();
    context.service.decode = TestGate.decode;
    _ = try context.service.request(.{ .bytes = "blocked" }, .{}, context.refs[0]);
    try context.service.pump();
    _ = try context.service.request(.{ .bytes = "queued" }, .{}, context.refs[1]);
    const timer = try context.loop.prepareTimeout(0);
    _ = try context.loop.submit();
    switch (context.loop.dispatch(try context.loop.wait())) {
        .timer_wakeup => {},
        else => return error.DecoderDidNotRemainBlocked,
    }
    try std.testing.expectEqual(timer, (try context.loop.takeExpired()).?.operation);
    context.service.shutdown();
    try std.testing.expect(context.service.hasPending());
    try std.testing.expect(!context.service.canDeinit());
    try std.testing.expectEqual(Status.missing, context.service.status(.{ .bytes = "queued" }, .{}));
    try std.testing.expectEqual(@as(usize, 7), context.service.encoded_bytes);
    TestGate.release();
    released = true;
    try context.drain();
    try std.testing.expect(context.service.canDeinit());
    try std.testing.expect(!context.service.hasPending());
    try std.testing.expectEqual(@as(usize, 0), context.service.decoded_bytes);
    try std.testing.expectEqual(@as(u64, 1), try context.owners.invalidationRevision(context.refs[0].handle));
}

test "image service owner transactions rollback independently and only committed owners are notified" {
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    const service = &context.service;
    const a = context.refs[0];
    const b = context.refs[1];
    _ = try service.request(.{ .bytes = "old" }, .{}, a);
    try service.beginOwner(a.owners, a.handle);
    try service.beginOwner(b.owners, b.handle);
    _ = try service.request(.{ .bytes = "bad" }, .{}, a);
    _ = try service.request(.{ .bytes = "bad" }, .{}, b);
    service.rollbackOwner(a.owners, a.handle);
    try std.testing.expectEqual(Status.pending, service.status(.{ .bytes = "old" }, .{}));
    try std.testing.expectEqual(Status.pending, service.status(.{ .bytes = "bad" }, .{}));
    service.commitOwner(b.owners, b.handle);
    try context.drain();
    try std.testing.expectEqual(Status.failed, service.status(.{ .bytes = "bad" }, .{}));
    try std.testing.expectEqual(error.TestBadImage, service.failure(.{ .bytes = "bad" }, .{}).?);
    try std.testing.expectEqual(@as(u64, 2), try a.owners.invalidationRevision(a.handle));
    try std.testing.expectEqual(@as(u64, 2), try b.owners.invalidationRevision(b.handle));
    try std.testing.expect(try service.request(.{ .bytes = "bad" }, .{}, b) == null);
    try std.testing.expect(!service.hasPending());
    try service.beginOwner(a.owners, a.handle);
    _ = try service.request(.{ .bytes = "rejected" }, .{}, a);
    service.rollbackOwner(a.owners, a.handle);
    try std.testing.expectEqual(Status.missing, service.status(.{ .bytes = "rejected" }, .{}));
    try service.beginOwner(a.owners, a.handle);
    service.commitOwner(a.owners, a.handle);
    try std.testing.expect(!service.subscribed(service.find(.{ .bytes = "old" }, .{}).?));
}

test "image service confines files and duplicates its root capability" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "good", .data = "K" });
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.symlinkat("good", temporary.dir.handle, "link")));
    const external = linux.fcntl(temporary.dir.handle, linux.F.DUPFD_CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(external));
    var context: TestContext = undefined;
    try context.init(@intCast(external));
    _ = linux.close(@intCast(external));
    defer context.deinit();
    const paths = [_][]const u8{ "good", "/etc/passwd", "../outside", "good\x00hidden", "link", ".", "missing" };
    for (paths) |path| _ = try context.service.request(.{ .path = path }, .{}, context.refs[0]);
    try context.drain();
    const image = (try context.service.request(.{ .path = "good" }, .{}, context.refs[0])).?;
    try std.testing.expectEqualSlices(u8, &.{ 'K', 13, 29, 255 }, (try context.cache.get(image)).pixels);
    const failures = [_]anyerror{ error.InvalidImagePath, error.ImagePathEscapesRoot, error.InvalidImagePath, error.ImageSymlinkForbidden, error.NotRegularFile, error.FileNotFound };
    for (paths[1..], failures) |path, expected| {
        try std.testing.expectEqual(Status.failed, context.service.status(.{ .path = path }, .{}));
        try std.testing.expectEqual(expected, context.service.failure(.{ .path = path }, .{}).?);
    }
    const huge = try temporary.dir.createFile(std.testing.io, "huge", .{});
    defer huge.close(std.testing.io);
    try huge.setLength(std.testing.io, max_encoded + 1);
    _ = try context.service.request(.{ .path = "huge" }, .{}, context.refs[0]);
    try context.drain();
    try std.testing.expectEqual(error.ImageEncodedBudgetExceeded, context.service.failure(.{ .path = "huge" }, .{}).?);
}

test "image service source eviction is bounded and does not invalidate frame leases" {
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    const service = &context.service;
    _ = try service.request(.{ .bytes = "retained" }, .{}, null);
    try context.drain();
    const retained = (try service.request(.{ .bytes = "retained" }, .{}, null)).?;
    try context.cache.retain(retained);
    defer context.cache.release(retained) catch unreachable;
    for (0..max_sources + 9) |index| {
        var key: [32]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&key, "source-{d}", .{index});
        try service.beginOwner(context.refs[0].owners, context.refs[0].handle);
        _ = try service.request(.{ .bytes = bytes }, .{}, context.refs[0]);
        service.commitOwner(context.refs[0].owners, context.refs[0].handle);
        try context.drain();
    }
    try std.testing.expectEqual(Status.missing, service.status(.{ .bytes = "retained" }, .{}));
    try std.testing.expectEqualSlices(u8, &.{ 'r', 13, 29, 255 }, (try context.cache.get(retained)).pixels);
    try std.testing.expectEqual(@as(usize, max_sources * 4), service.decoded_bytes);
    try std.testing.expectEqual(@as(?usize, null), service.freeSlot());
    try std.testing.expect(service.encoded_bytes < 1024);
}

test "image service removes stale owners and drains cancellation without premature join" {
    try TestGate.init();
    defer TestGate.deinit();
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    var released = false;
    defer if (!released) TestGate.release();
    const service = &context.service;
    service.decode = TestGate.decode;
    const old = context.refs[0];
    _ = try service.request(.{ .bytes = "blocked" }, .{}, old);
    try service.pump();
    const operation = service.active.?.job.operation.?;
    _ = try context.loop.submit();
    try context.loop.prepareCancel(operation);
    _ = try context.loop.submit();
    var canceled = false;
    while (!canceled) {
        switch (context.loop.dispatch(try context.loop.wait())) {
            .file => |completion| {
                try std.testing.expect(completion.result < 0);
                try std.testing.expect(try service.dispatch(completion));
                canceled = true;
            },
            .operation_cancel => {},
            else => return error.UnexpectedTestCompletion,
        }
    }
    try std.testing.expect(!service.canDeinit());
    try old.owners.retire(old.handle);
    try context.scheduler.applyQueuedCancellations();
    try context.owners.collectRetired();
    context.refs[0].handle = try context.owners.mount(null, 3);
    try std.testing.expectEqual(old.handle.slot, context.refs[0].handle.slot);
    try std.testing.expect(old.handle.generation != context.refs[0].handle.generation);
    TestGate.release();
    released = true;
    try context.drain();
    try std.testing.expectEqual(@as(u64, 1), try context.owners.invalidationRevision(context.refs[0].handle));
    try std.testing.expect(service.findOwner(old) == null);
    try std.testing.expectError(error.StaleBuildOwner, service.request(.{ .bytes = "new" }, .{}, old));
}

test "image service pending-only subscriptions do not receive completion notifications" {
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    const service = &context.service;
    const a = context.refs[0];
    const b = context.refs[1];
    _ = try service.request(.{ .bytes = "shared" }, .{}, a);
    try service.beginOwner(b.owners, b.handle);
    _ = try service.request(.{ .bytes = "shared" }, .{}, b);
    try context.drain();
    try std.testing.expectEqual(@as(u64, 2), try a.owners.invalidationRevision(a.handle));
    try std.testing.expectEqual(@as(u64, 1), try b.owners.invalidationRevision(b.handle));
    service.rollbackOwner(b.owners, b.handle);
    service.disposeOwner(a.owners, a.handle);
    try std.testing.expect(!service.subscribed(service.find(.{ .bytes = "shared" }, .{}).?));
    _ = try service.request(.{ .bytes = "queued" }, .{}, a);
    service.disposeOwner(a.owners, a.handle);
    try std.testing.expectEqual(Status.missing, service.status(.{ .bytes = "queued" }, .{}));
    try std.testing.expect(!context.loop.hasPendingOperations());
}

test "image service bounds encoded items and aggregate before copying and disposal frees queued keys" {
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    const service = &context.service;
    const owner = context.refs[0];
    const bytes = try std.testing.allocator.alloc(u8, max_encoded + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    try std.testing.expectError(error.ImageEncodedBudgetExceeded, service.request(.{ .bytes = bytes }, .{}, owner));
    try std.testing.expectEqual(@as(usize, 0), service.encoded_bytes);
    for (0..4) |index| {
        bytes[0] = @intCast(index);
        _ = try service.request(.{ .bytes = bytes[0..max_encoded] }, .{}, owner);
    }
    try std.testing.expectEqual(@as(usize, max_encoded_total), service.encoded_bytes);
    try std.testing.expectError(error.ImageEncodedBudgetExceeded, service.request(.{ .bytes = "extra" }, .{}, owner));
    service.disposeOwner(owner.owners, owner.handle);
    try std.testing.expectEqual(@as(usize, 0), service.encoded_bytes);
    try std.testing.expect(!service.hasPending());
    try std.testing.expect(service.canDeinit());
    try std.testing.expect(!context.loop.hasPendingOperations());
    _ = try service.request(.{ .bytes = "tiny output budget" }, .{ .max_decoded_bytes = 3 }, owner);
    try context.drain();
    try std.testing.expectEqual(error.ImageDecodedBudgetExceeded, service.failure(.{ .bytes = "tiny output budget" }, .{ .max_decoded_bytes = 3 }).?);
    try std.testing.expectEqual(@as(usize, 0), service.decoded_bytes);
}

test "image service rejects source overflow without evicting committed or staged dependencies" {
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    const service = &context.service;
    const owner = context.refs[0];
    try service.beginOwner(owner.owners, owner.handle);
    for (0..max_sources) |index| {
        const key = [_]u8{@intCast(index)};
        _ = try service.request(.{ .bytes = &key }, .{}, owner);
    }
    try std.testing.expectError(error.ImageSourceCapacityExceeded, service.request(.{ .bytes = "65th" }, .{}, owner));
    try std.testing.expectEqual(Status.pending, service.status(.{ .bytes = &.{0} }, .{}));
    service.rollbackOwner(owner.owners, owner.handle);
    try std.testing.expectEqual(@as(usize, 0), service.encoded_bytes);
    try std.testing.expect(!service.hasPending());
    try std.testing.expect(!context.loop.hasPendingOperations());
}

test "image native service decodes SVG through worker and publishes stable errors" {
    var context: TestContext = undefined;
    try context.init(null);
    defer context.deinit();
    const service = &context.service;
    service.decode = codec.decode;
    const svg: Source = .{ .bytes =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1"><path fill="#123456" d="M0 0h2v1H0z"/></svg>
    };
    const invalid: Source = .{ .bytes = "not an image" };
    const nan: codec.Options = .{ .scale = std.math.nan(f32) };
    try std.testing.expect(try service.request(svg, .{ .scale = 2 }, context.refs[0]) == null);
    try std.testing.expect(try service.request(invalid, .{}, context.refs[0]) == null);
    try std.testing.expect(try service.request(svg, nan, context.refs[0]) == null);
    try std.testing.expect(!context.loop.hasPendingOperations());
    try context.drain();
    const handle = (try service.request(svg, .{ .scale = 2 }, context.refs[0])).?;
    const bitmap = try context.cache.get(handle);
    try std.testing.expectEqual(@as(u32, 4), bitmap.width);
    try std.testing.expectEqual(@as(u32, 2), bitmap.height);
    try std.testing.expectEqual(@as(u32, 2), bitmap.intrinsic_width);
    try std.testing.expectEqual(@as(u32, 1), bitmap.intrinsic_height);
    try std.testing.expectEqual(@as(usize, 32), bitmap.pixels.len);
    var offset: usize = 0;
    while (offset < bitmap.pixels.len) : (offset += 4)
        try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 255 }, bitmap.pixels[offset..][0..4]);
    try std.testing.expectEqual(Status.failed, service.status(invalid, .{}));
    try std.testing.expectEqual(error.InvalidImage, service.failure(invalid, .{}).?);
    try std.testing.expectEqual(Status.failed, service.status(svg, nan));
    try std.testing.expectEqual(error.InvalidDimensions, service.failure(svg, nan).?);
    try std.testing.expect(try service.request(svg, nan, context.refs[0]) == null);
    try std.testing.expect(!service.hasPending());
}
