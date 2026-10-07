//! HTTP(S) transfers driven by the application's ring and logical timers.
//! Curl owns protocol sockets; this adapter only watches duplicated descriptors.
const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/root.zig");
const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const default_max_bytes = 16 * 1024 * 1024;
pub const absolute_max_bytes = 64 * 1024 * 1024;
pub const max_header_bytes = 64 * 1024;
pub const capacity = 16;

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Options = struct {
    url: []const u8,
    method: []const u8 = "GET",
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    timeout_ms: u32 = 30_000,
    max_bytes: usize = default_max_bytes,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    easy: ?*c.CURL = null,
    outgoing_headers: ?*c.curl_slist = null,
    body: std.ArrayList(u8) = .empty,
    headers: std.ArrayList(u8) = .empty,
    header_bytes: usize = 0,
    max_bytes: usize,
    status: c_long = 0,
    failure: ?anyerror = null,
    ready: bool = false,

    /// Stable address required through completion; curl copies request inputs.
    pub fn init(self: *Request, allocator: std.mem.Allocator, options: Options) !void {
        if (options.url.len == 0 or options.url.len > 8192 or std.mem.indexOfScalar(u8, options.url, 0) != null)
            return error.InvalidUrl;
        if (!token(options.method)) return error.InvalidMethod;
        if (options.timeout_ms == 0 or options.max_bytes == 0 or options.max_bytes > absolute_max_bytes)
            return error.InvalidHttpLimits;
        if (options.body) |body| if (body.len > absolute_max_bytes) return error.RequestTooLarge;
        self.* = .{ .allocator = allocator, .max_bytes = options.max_bytes };
        self.easy = c.curl_easy_init() orelse return error.OutOfMemory;
        errdefer self.deinit();
        const url = try allocator.dupeZ(u8, options.url);
        defer allocator.free(url);
        const method = try allocator.dupeZ(u8, options.method);
        defer allocator.free(method);
        try self.set(c.CURLOPT_URL, url.ptr);
        try self.set(c.CURLOPT_PROTOCOLS_STR, @as([*:0]const u8, "http,https"));
        try self.set(c.CURLOPT_REDIR_PROTOCOLS_STR, @as([*:0]const u8, "http,https"));
        try self.set(c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        try self.set(c.CURLOPT_TIMEOUT_MS, @as(c_long, options.timeout_ms));
        try self.set(c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
        try self.set(c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        // Do not follow redirects implicitly or treat HTTP error status as I/O failure.
        try self.set(c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        try self.set(c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, ""));
        try self.set(c.CURLOPT_WRITEFUNCTION, &writeBody);
        try self.set(c.CURLOPT_WRITEDATA, self);
        try self.set(c.CURLOPT_HEADERFUNCTION, &writeHeader);
        try self.set(c.CURLOPT_HEADERDATA, self);
        if (options.body) |body| {
            try self.set(c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(body.len)));
            try self.set(c.CURLOPT_COPYPOSTFIELDS, body.ptr);
        }
        if (std.mem.eql(u8, options.method, "HEAD")) try self.set(c.CURLOPT_NOBODY, @as(c_long, 1));
        try self.set(c.CURLOPT_CUSTOMREQUEST, method.ptr);
        var bytes: usize = 0;
        for (options.headers) |header| {
            if (!token(header.name) or std.mem.indexOfAny(u8, header.value, "\r\n\x00") != null)
                return error.InvalidHeader;
            if (header.name.len > max_header_bytes or header.value.len > max_header_bytes) return error.HeadersTooLarge;
            bytes += header.name.len + header.value.len + 4;
            if (bytes > max_header_bytes) return error.HeadersTooLarge;
            // Curl's semicolon spelling sends an empty value instead of removing the header.
            const line = try std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{
                header.name, if (header.value.len == 0) ";" else ": ", header.value,
            }, 0);
            defer allocator.free(line);
            self.outgoing_headers = c.curl_slist_append(self.outgoing_headers, line.ptr) orelse return error.OutOfMemory;
        }
        try self.set(c.CURLOPT_HTTPHEADER, self.outgoing_headers);
    }

    pub fn deinit(self: *Request) void {
        if (self.easy) |easy| c.curl_easy_cleanup(easy);
        c.curl_slist_free_all(self.outgoing_headers);
        self.body.deinit(self.allocator);
        self.headers.deinit(self.allocator);
        self.* = undefined;
    }

    fn set(self: *Request, option: c.CURLoption, value: anytype) !void {
        if (c.curl_easy_setopt(self.easy, option, value) != c.CURLE_OK) return error.CurlOptionFailed;
    }

    fn writeBody(data: [*]const u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
        const self: *Request = @ptrCast(@alignCast(context.?));
        const length = std.math.mul(usize, size, count) catch return 0;
        if (length > self.max_bytes - self.body.items.len) {
            self.failure = error.ResponseTooLarge;
            return 0;
        }
        self.body.appendSlice(self.allocator, data[0..length]) catch {
            self.failure = error.OutOfMemory;
            return 0;
        };
        return length;
    }

    fn writeHeader(data: [*]const u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
        const self: *Request = @ptrCast(@alignCast(context.?));
        const length = std.math.mul(usize, size, count) catch return 0;
        if (length > max_header_bytes - self.header_bytes) {
            self.failure = error.HeadersTooLarge;
            return 0;
        }
        self.header_bytes += length;
        const line = data[0..length];
        // Discard proxy CONNECT and informational headers, not their size budget.
        if (std.mem.startsWith(u8, line, "HTTP/")) self.headers.clearRetainingCapacity() else self.headers.appendSlice(self.allocator, line) catch {
            self.failure = error.OutOfMemory;
            return 0;
        };
        return length;
    }
};

const Watch = struct {
    fd: linux.fd_t,
    owned_fd: linux.fd_t,
    events: u32,
    armed_events: u32 = 0,
    active: bool = true,
    operation: ?io.OperationHandle = null,
    cancel_sent: bool = false,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    loop: *io.Loop,
    multi: ?*c.CURLM = null,
    requests: [capacity]?*Request = @splat(null),
    watches: std.ArrayList(*Watch) = .empty,
    timer: ?io.OperationHandle = null,
    next_timeout_ms: ?c_long = null,
    callback_failure: ?anyerror = null,
    stopping: bool = false,
    cleanup_multi: ?*c.CURLM = null,
    cleanup_thread: ?std.Thread = null,
    cleanup_pipe: ?[2]linux.fd_t = null,
    cleanup_operation: ?io.OperationHandle = null,
    cleanup_signal: [1]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, loop: *io.Loop) Client {
        return .{ .allocator = allocator, .loop = loop };
    }

    /// Lazy initialization starts no DNS threads. The system resolver creates
    /// workers only for cache misses; newer curl pools retire idle workers.
    pub fn ensureInitialized(self: *Client) !void {
        if (self.stopping) return error.HttpStopping;
        if (self.multi != null) return;
        if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.CurlInitFailed;
        errdefer c.curl_global_cleanup();
        const version = c.curl_version_info(c.CURLVERSION_NOW);
        if (version.*.version_num < 0x075500 or version.*.features & c.CURL_VERSION_ASYNCHDNS == 0 or
            version.*.features & c.CURL_VERSION_THREADSAFE == 0 or version.*.features & c.CURL_VERSION_SSL == 0)
            return error.UnsupportedCurlBuild;
        const multi = c.curl_multi_init() orelse return error.OutOfMemory;
        errdefer _ = c.curl_multi_cleanup(multi);
        if (c.curl_multi_setopt(multi, c.CURLMOPT_SOCKETFUNCTION, &socketCallback) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_SOCKETDATA, self) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_TIMERFUNCTION, &timerCallback) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_TIMERDATA, self) != c.CURLM_OK)
            return error.CurlOptionFailed;
        if (@hasDecl(c, "CURLMOPT_RESOLVE_THREADS_MAX")) {
            if (version.*.version_num >= 0x081400 and
                c.curl_multi_setopt(multi, c.CURLMOPT_RESOLVE_THREADS_MAX, @as(c_long, 4)) != c.CURLM_OK)
                return error.CurlOptionFailed;
        }
        self.multi = multi;
    }

    pub fn start(self: *Client, request: *Request) !void {
        try self.ensureInitialized();
        const slot = for (&self.requests) |*slot| {
            if (slot.* == null) break slot;
        } else return error.HttpBusy;
        if (c.curl_multi_add_handle(self.multi, request.easy) != c.CURLM_OK) return error.CurlStartFailed;
        slot.* = request;
        // add_handle schedules a zero timer; it must not drive curl recursively
        // or complete the request before its Lua caller has yielded.
    }

    pub fn cancel(self: *Client, request: *Request) void {
        for (&self.requests) |*slot| if (slot.* == request) {
            request.failure = error.Canceled;
            self.finish(slot);
            return;
        };
    }

    fn finish(self: *Client, slot: *?*Request) void {
        const request = slot.*.?;
        _ = c.curl_easy_getinfo(request.easy, c.CURLINFO_RESPONSE_CODE, &request.status);
        _ = c.curl_multi_remove_handle(self.multi, request.easy);
        c.curl_easy_cleanup(request.easy);
        request.easy = null;
        request.ready = true;
        slot.* = null;
    }

    fn action(self: *Client, fd: c.curl_socket_t, events: c_int) void {
        var running: c_int = 0;
        const result = c.curl_multi_socket_action(self.multi, fd, events, &running);
        if (result != c.CURLM_OK or self.callback_failure != null) {
            const failure = self.callback_failure orelse error.CurlTransferFailed;
            for (&self.requests) |*slot| if (slot.*) |request| {
                request.failure = failure;
                self.finish(slot);
            };
            self.callback_failure = null;
            return;
        }
        var remaining: c_int = 0;
        while (true) {
            const message = c.curl_multi_info_read(self.multi, &remaining);
            if (message == null) break;
            if (message.*.msg != c.CURLMSG_DONE) continue;
            for (&self.requests) |*slot| if (slot.*) |request| {
                if (request.easy != message.*.easy_handle) continue;
                if (request.failure == null) request.failure = switch (message.*.data.result) {
                    c.CURLE_OK => null,
                    c.CURLE_OPERATION_TIMEDOUT => error.HttpTimeout,
                    c.CURLE_COULDNT_RESOLVE_HOST, c.CURLE_COULDNT_RESOLVE_PROXY => error.NameResolutionFailed,
                    c.CURLE_COULDNT_CONNECT => error.ConnectionFailed,
                    c.CURLE_PEER_FAILED_VERIFICATION => error.CertificateVerificationFailed,
                    c.CURLE_UNSUPPORTED_PROTOCOL, c.CURLE_URL_MALFORMAT => error.InvalidUrl,
                    else => error.HttpTransferFailed,
                };
                self.finish(slot);
                break;
            };
        }
    }

    pub fn dispatch(self: *Client, completion: io.SocketCompletion) !bool {
        for (self.watches.items) |watch| {
            const operation = watch.operation orelse continue;
            if (!std.meta.eql(operation, completion.operation)) continue;
            if (watch.active and !watch.cancel_sent and watch.events == watch.armed_events) {
                var events: c_int = 0;
                if (completion.result < 0) events = c.CURL_CSELECT_ERR else {
                    const mask: u32 = @intCast(completion.result);
                    if (mask & linux.POLL.IN != 0) events |= c.CURL_CSELECT_IN;
                    if (mask & linux.POLL.OUT != 0) events |= c.CURL_CSELECT_OUT;
                    if (mask & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0) events |= c.CURL_CSELECT_ERR;
                }
                self.action(watch.fd, events);
            }
            try self.pump();
            return true;
        }
        return false;
    }

    pub fn dispatchTimer(self: *Client, operation: io.OperationHandle) !bool {
        if (self.timer == null or !std.meta.eql(self.timer.?, operation)) return false;
        self.timer = null;
        if (!self.stopping) self.action(c.CURL_SOCKET_TIMEOUT, 0);
        try self.pump();
        return true;
    }

    pub fn dispatchFile(self: *Client, completion: io.FileCompletion) bool {
        if (self.cleanup_operation == null or !std.meta.eql(self.cleanup_operation.?, completion.operation)) return false;
        self.cleanup_thread.?.join();
        self.cleanup_thread = null;
        self.cleanup_multi = null;
        self.cleanup_operation = null;
        _ = linux.close(self.cleanup_pipe.?[0]);
        self.cleanup_pipe = null;
        return true;
    }

    /// Reconcile watches only outside curl callbacks. Removed registrations
    /// survive both CQEs; a duplicate fd prevents close/reuse before SQ submit
    /// from accidentally watching an unrelated descriptor.
    pub fn pump(self: *Client) !void {
        if (self.next_timeout_ms) |timeout_ms| {
            try self.updateTimer(timeout_ms);
            self.next_timeout_ms = null;
        }
        var index: usize = 0;
        while (index < self.watches.items.len) {
            const watch = self.watches.items[index];
            if (watch.operation) |operation| {
                if (!self.loop.operationPending(operation)) {
                    watch.operation = null;
                    watch.cancel_sent = false;
                } else if ((!watch.active or watch.events != watch.armed_events) and !watch.cancel_sent) {
                    self.loop.prepareCancel(operation) catch |err| switch (err) {
                        error.SubmissionQueueFull, error.StaleOperation => {
                            index += 1;
                            continue;
                        },
                        else => return err,
                    };
                    watch.cancel_sent = true;
                }
            }
            if (watch.operation == null) {
                if (!watch.active) {
                    _ = linux.close(watch.owned_fd);
                    self.allocator.destroy(watch);
                    _ = self.watches.swapRemove(index);
                    continue;
                }
                watch.operation = self.loop.preparePoll(watch.owned_fd, watch.events) catch |err| switch (err) {
                    error.SubmissionQueueFull, error.OperationCapacityExceeded, error.OutOfMemory => null,
                };
                watch.armed_events = watch.events;
            }
            index += 1;
        }
        if (self.stopping and self.multi != null and self.watches.items.len == 0) try self.beginCleanup();
        if (self.cleanup_thread != null and self.cleanup_operation == null)
            self.cleanup_operation = self.loop.prepareRead(self.cleanup_pipe.?[0], &self.cleanup_signal, std.math.maxInt(u64)) catch |err| switch (err) {
                error.SubmissionQueueFull, error.OperationCapacityExceeded, error.OutOfMemory => return,
                error.EmptyReadBuffer => unreachable,
            };
    }

    pub fn stop(self: *Client) !void {
        self.stopping = true;
        for (&self.requests) |*slot| if (slot.*) |request| {
            request.failure = error.Canceled;
            self.finish(slot);
        };
        if (self.timer) |timer| try self.loop.prepareCancel(timer);
        self.timer = null;
        for (self.watches.items) |watch| watch.active = false;
        try self.pump();
    }

    pub fn canDeinit(self: *const Client) bool {
        return self.multi == null and self.cleanup_thread == null and self.watches.items.len == 0;
    }

    pub fn deinit(self: *Client) void {
        std.debug.assert(self.canDeinit());
        self.watches.deinit(self.allocator);
        self.* = undefined;
    }

    fn beginCleanup(self: *Client) !void {
        var pipe: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
        errdefer {
            _ = linux.close(pipe[0]);
            _ = linux.close(pipe[1]);
        }
        // Cleanup can wait for an uninterruptible libc resolver call. Never
        // block the UI thread or use QUICK_EXIT (which allows resource leaks).
        _ = c.curl_multi_setopt(self.multi, c.CURLMOPT_SOCKETFUNCTION, @as(?*anyopaque, null));
        _ = c.curl_multi_setopt(self.multi, c.CURLMOPT_TIMERFUNCTION, @as(?*anyopaque, null));
        self.cleanup_multi = self.multi;
        self.cleanup_pipe = pipe;
        self.cleanup_thread = try std.Thread.spawn(.{}, cleanup, .{self});
        self.multi = null;
    }

    fn cleanup(self: *Client) void {
        _ = c.curl_multi_cleanup(self.cleanup_multi);
        c.curl_global_cleanup();
        while (linux.errno(linux.write(self.cleanup_pipe.?[1], &.{1}, 1)) == .INTR) {}
        _ = linux.close(self.cleanup_pipe.?[1]);
    }

    fn socketCallback(_: ?*c.CURL, fd: c.curl_socket_t, what: c_int, context: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(context.?));
        self.updateWatch(fd, what) catch |err| {
            self.callback_failure = err;
            return -1;
        };
        return 0;
    }

    fn updateWatch(self: *Client, fd: linux.fd_t, what: c_int) !void {
        const events: u32 = switch (what) {
            c.CURL_POLL_IN => linux.POLL.IN,
            c.CURL_POLL_OUT => linux.POLL.OUT,
            c.CURL_POLL_INOUT => linux.POLL.IN | linux.POLL.OUT,
            else => 0,
        };
        for (self.watches.items) |watch| if (watch.active and watch.fd == fd) {
            if (events == 0) watch.active = false else watch.events = events;
            return;
        };
        if (events == 0) return;
        const duplicate = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(duplicate) != .SUCCESS) return error.DuplicateFdFailed;
        errdefer _ = linux.close(@intCast(duplicate));
        const watch = try self.allocator.create(Watch);
        errdefer self.allocator.destroy(watch);
        watch.* = .{ .fd = fd, .owned_fd = @intCast(duplicate), .events = events };
        try self.watches.append(self.allocator, watch);
    }

    fn timerCallback(_: ?*c.CURLM, timeout_ms: c_long, context: ?*anyopaque) callconv(.c) c_int {
        const self: *Client = @ptrCast(@alignCast(context.?));
        // In particular, add_handle can invoke this before finishing its own
        // bookkeeping. Defer allocation and zero-timeout work until it returns.
        self.next_timeout_ms = timeout_ms;
        return 0;
    }

    fn updateTimer(self: *Client, timeout_ms: c_long) !void {
        if (self.timer) |timer| try self.loop.prepareCancel(timer);
        self.timer = null;
        if (!self.stopping and timeout_ms >= 0)
            self.timer = try self.loop.prepareTimeout(@as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
    }
};

fn token(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    return true;
}

test "http response limits include decoded bytes and all header blocks" {
    var request: Request = .{ .allocator = std.testing.allocator, .max_bytes = 5 };
    defer request.deinit();
    try std.testing.expectEqual(@as(usize, 3), Request.writeBody("a\x00b", 1, 3, &request));
    try std.testing.expectEqual(@as(usize, 2), Request.writeBody("cd", 1, 2, &request));
    try std.testing.expectEqual(@as(usize, 0), Request.writeBody("e", 1, 1, &request));
    try std.testing.expectEqual(error.ResponseTooLarge, request.failure.?);
    try std.testing.expectEqualSlices(u8, "a\x00bcd", request.body.items);
    const provisional = "X-Discard: early\r\n";
    _ = Request.writeHeader(provisional, 1, provisional.len, &request);
    const status = "HTTP/1.1 200 OK\r\n";
    _ = Request.writeHeader(status, 1, status.len, &request);
    try std.testing.expectEqual(@as(usize, 0), request.headers.items.len);
    try std.testing.expectEqual(provisional.len + status.len, request.header_bytes);
    request.header_bytes = max_header_bytes - 1;
    try std.testing.expectEqual(@as(usize, 0), Request.writeHeader("\r\n", 1, 2, &request));
    try std.testing.expectEqual(error.HeadersTooLarge, request.failure.?);
}

test "http lazy client needs no cleanup worker or ring work" {
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var client = Client.init(std.testing.allocator, &loop);
    defer client.deinit();
    try std.testing.expect(client.multi == null);
    try client.stop();
    try std.testing.expect(client.canDeinit());
    try std.testing.expect(!loop.hasPendingOperations());
    try std.testing.expectEqual(@as(usize, 0), loop.timers.count());
}

test "http zero timer callback defers work and replacement cancels the old deadline" {
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var client = Client.init(std.testing.allocator, &loop);
    defer client.deinit();
    try std.testing.expectEqual(@as(c_int, 0), Client.timerCallback(null, 0, &client));
    try std.testing.expectEqual(@as(usize, 0), loop.timers.count());
    try client.pump();
    const old = client.timer.?;
    _ = Client.timerCallback(null, 60_000, &client);
    try client.pump();
    try std.testing.expectEqual(@as(usize, 1), loop.timers.count());
    try std.testing.expect(!std.meta.eql(old, client.timer.?));
    try std.testing.expect((try loop.takeExpired()) == null);
    _ = Client.timerCallback(null, -1, &client);
    try client.pump();
    try std.testing.expect(client.timer == null);
    try std.testing.expectEqual(@as(usize, 0), loop.timers.count());
}

test "http removed watch retains its fd until cancellation drains and ignores stale readiness" {
    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 16, 2);
    defer loop.deinit();
    var client = Client.init(std.testing.allocator, &loop);
    defer client.deinit();
    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    try client.updateWatch(pipe[0], c.CURL_POLL_IN);
    try client.pump();
    const old = client.watches.items[0].operation.?;
    // Ready before cancellation: either terminal ordering must be safe.
    try std.testing.expectEqual(@as(usize, 1), linux.write(pipe[1], &.{42}, 1));
    _ = try loop.submit();
    try client.updateWatch(pipe[0], c.CURL_POLL_REMOVE);
    try client.updateWatch(pipe[0], c.CURL_POLL_IN);
    try std.testing.expectEqual(@as(usize, 2), client.watches.items.len);
    try std.testing.expect(client.watches.items[0].owned_fd != client.watches.items[1].owned_fd);
    try client.stop();
    while (loop.hasPendingOperations()) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .socket => |completion| {
                try std.testing.expectEqual(old, completion.operation);
                try std.testing.expect(try client.dispatch(completion));
            },
            .operation_cancel => try client.pump(),
            else => return error.UnexpectedCompletion,
        }
    }
    try std.testing.expect(client.canDeinit());
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), linux.read(pipe[0], &byte, 1));
    try std.testing.expectEqual(@as(u8, 42), byte[0]);
}
