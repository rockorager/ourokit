//! Asynchronous Linux D-Bus client transport.

const std = @import("std");
const linux = std.os.linux;
const io = @import("../loop/io_uring.zig");
const wire = @import("wire.zig");

const max_fds = 16;
const max_messages = 256;
const max_queued_bytes = 4 * 1024 * 1024;
const recv_size = 16 * 1024;
const control_size = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @sizeOf(usize)) +
    std.mem.alignForward(usize, max_fds * @sizeOf(linux.fd_t), @sizeOf(usize));
const startup_timeout_ns = std.time.ns_per_s;

pub const Error = error{ InvalidAddress, AddressUnavailable, AuthenticationFailed, ConnectionClosed, ProtocolError, QueueFull, UnixFdUnsupported, SerialExhausted };

const Phase = enum { connecting, auth_send, auth_recv, negotiate_send, negotiate_recv, begin_send, hello, ready, closing, closed };
const Outgoing = struct {
    bytes: []u8,
    fds: []linux.fd_t,
    offset: usize = 0,
    fds_sent: bool = false,
};

pub const Client = struct {
    allocator: std.mem.Allocator = undefined,
    loop: *io.Loop = undefined,
    addresses: []u8 = &.{},
    next_address: usize = 0,
    fd: linux.fd_t = -1,
    phase: Phase = .closed,
    failure: ?anyerror = null,
    operation: ?io.OperationHandle = null,
    operation_terminal: bool = false,
    write_operation: ?io.OperationHandle = null,
    write_terminal: bool = false,
    read_cancel: bool = false,
    write_cancel: bool = false,
    timer: ?io.OperationHandle = null,
    next_serial: u64 = 1,
    hello_serial: u32 = 0,
    unix_fds: bool = false,

    auth: [192]u8 = undefined,
    auth_len: usize = 0,
    auth_offset: usize = 0,
    auth_line: std.ArrayList(u8) = .empty,
    receive: std.ArrayList(u8) = .empty,
    received_fds: std.ArrayList(linux.fd_t) = .empty,
    messages: std.ArrayList(wire.Message) = .empty,
    message_bytes: usize = 0,
    outgoing: std.ArrayList(Outgoing) = .empty,
    outgoing_bytes: usize = 0,

    recv_buffer: [recv_size]u8 = undefined,
    recv_control: [control_size]u8 align(@alignOf(linux.cmsghdr)) = undefined,
    recv_iov: [1]std.posix.iovec = undefined,
    recv_header: linux.msghdr = undefined,
    send_control: [control_size]u8 align(@alignOf(linux.cmsghdr)) = undefined,
    send_iov: [1]std.posix.iovec_const = undefined,
    send_header: linux.msghdr_const = undefined,

    pub fn init(self: *Client, allocator: std.mem.Allocator, loop: *io.Loop, addresses: []const u8) !void {
        self.* = .{ .allocator = allocator, .loop = loop, .addresses = try allocator.dupe(u8, addresses), .phase = .connecting };
        errdefer self.deinitImmediate();
        self.timer = try loop.prepareTimeout(startup_timeout_ns);
        try self.tryNextAddress();
    }

    pub fn isReady(self: *const Client) bool {
        return self.phase == .ready;
    }
    /// Copies the encoded frame and duplicates every descriptor. The returned
    /// serial is unique for this Client's entire lifetime.
    pub fn send(self: *Client, metadata: wire.Metadata, body: []const u8, fds: []const linux.fd_t) !u32 {
        if (self.failure != null or self.phase == .closing or self.phase == .closed) return error.ConnectionClosed;
        if (self.phase != .ready and self.phase != .hello) return error.NotReady;
        if (fds.len > max_fds) return error.ProtocolError;
        if (fds.len != 0 and !self.unix_fds) return error.UnixFdUnsupported;
        if (self.next_serial > std.math.maxInt(u32)) return error.SerialExhausted;
        const serial: u32 = @intCast(self.next_serial);
        const bytes = try wire.encodeMessage(self.allocator, metadata, serial, body, @intCast(fds.len));
        errdefer self.allocator.free(bytes);
        if (self.outgoing.items.len >= max_messages or bytes.len > max_queued_bytes -| self.outgoing_bytes) return error.QueueFull;
        const owned_fds = try self.allocator.alloc(linux.fd_t, fds.len);
        var count: usize = 0;
        errdefer {
            for (owned_fds[0..count]) |fd| _ = linux.close(fd);
            self.allocator.free(owned_fds);
        }
        for (fds) |fd| {
            const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
            owned_fds[count] = @intCast(rc);
            count += 1;
        }
        // Validate the complete body as well as its declared signature before
        // any bytes or duplicated descriptors enter the transmit queue.
        _ = try wire.parseMessage(self.allocator, bytes, owned_fds);
        try self.outgoing.append(self.allocator, .{ .bytes = bytes, .fds = owned_fds });
        self.outgoing_bytes += bytes.len;
        self.next_serial += 1;
        return serial;
    }

    pub fn takeMessage(self: *Client) !?wire.Message {
        try self.collectCanceled();
        if (self.messages.items.len == 0) return null;
        const message = self.messages.orderedRemove(0);
        self.message_bytes -= message.data.len;
        return message;
    }

    pub fn dispatch(self: *Client, completion: io.SocketCompletion) !bool {
        if (self.write_operation) |operation| if (same(operation, completion.operation)) {
            self.write_terminal = true;
            if (self.phase == .closing) {
                try self.collectCanceled();
                return true;
            }
            self.write_operation = null;
            self.write_terminal = false;
            if (completion.result <= 0) {
                self.fail(error.ConnectionClosed);
                return true;
            }
            const q = &self.outgoing.items[0];
            q.offset += @intCast(completion.result);
            if (!q.fds_sent and q.fds.len != 0) {
                q.fds_sent = true;
                for (q.fds) |fd| _ = linux.close(fd);
                self.allocator.free(q.fds);
                q.fds = &.{};
            }
            if (q.offset == q.bytes.len) {
                self.outgoing_bytes -= q.bytes.len;
                self.allocator.free(q.bytes);
                self.allocator.free(q.fds);
                _ = self.outgoing.orderedRemove(0);
            }
            try self.collectCanceled();
            return true;
        };
        const operation = self.operation orelse return false;
        if (!same(operation, completion.operation)) return false;
        self.operation_terminal = true;
        if (self.phase == .closing) {
            // A successful receive may race with cancellation. Its ancillary
            // descriptors still belong to us, even though the bytes are dropped.
            if (completion.kind == .recvmsg and completion.result > 0)
                closeControlFds(self.recv_control[0..self.recv_header.controllen]);
            try self.collectCanceled();
            return true;
        }
        self.operation = null;
        self.operation_terminal = false;
        if (completion.result < 0 or (completion.result == 0 and completion.kind != .connect)) {
            if (self.phase == .connecting) return self.connectFailed();
            self.fail(error.ConnectionClosed);
            return true;
        }
        self.handleCompletion(completion) catch |err| self.fail(err);
        try self.collectCanceled();
        return true;
    }

    fn handleCompletion(self: *Client, completion: io.SocketCompletion) !void {
        switch (self.phase) {
            .connecting => {
                if (completion.kind != .connect) return error.ProtocolError;
                try self.setAuthExternal();
                self.phase = .auth_send;
                try self.preparePlainSend();
            },
            .auth_send, .negotiate_send, .begin_send => {
                if (completion.kind != .send) return error.ProtocolError;
                self.auth_offset += @intCast(completion.result);
                if (self.auth_offset < self.auth_len) try self.preparePlainSend() else if (self.phase == .begin_send) {
                    self.phase = .hello;
                    self.hello_serial = try self.send(.{ .message_type = .method_call, .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello", .destination = "org.freedesktop.DBus" }, &.{}, &.{});
                    try self.prepareSend();
                } else {
                    self.phase = if (self.phase == .auth_send) .auth_recv else .negotiate_recv;
                }
            },
            .auth_recv, .negotiate_recv, .hello, .ready => {
                if (completion.kind != .recvmsg) return error.ProtocolError;
                try self.consumeReceive(@intCast(completion.result));
            },
            else => return error.ProtocolError,
        }
    }

    pub fn dispatchTimer(self: *Client, operation: io.OperationHandle) !bool {
        const timer = self.timer orelse return false;
        if (!same(timer, operation)) return false;
        self.timer = null;
        if (!self.isReady()) self.fail(error.Timeout);
        return true;
    }

    pub fn close(self: *Client) !void {
        if (self.phase == .closed) return;
        self.phase = .closing;
        if (self.timer) |timer| {
            self.loop.prepareCancel(timer) catch |e| if (e != error.StaleOperation) return e;
            self.timer = null;
        }
        try self.collectCanceled();
    }

    /// Also pumps queued writes and retries SQ backpressure. Call at each
    /// host safe point before submission, not just after cancel completions.
    pub fn collectCanceled(self: *Client) !void {
        if (self.phase == .closed) return;
        if (self.phase != .closing) {
            self.pump() catch |err| {
                if (err != error.SubmissionQueueFull) self.fail(err);
            };
            return;
        }
        if (self.operation) |op| {
            if (self.operation_terminal and !self.loop.operationPending(op)) {
                self.operation = null;
            } else if (!self.operation_terminal and !self.read_cancel) {
                self.loop.prepareCancel(op) catch |err| switch (err) {
                    error.SubmissionQueueFull => return,
                    error.CancellationAlreadyPending => {},
                    else => return err,
                };
                self.read_cancel = true;
            }
        }
        if (self.write_operation) |op| {
            if (self.write_terminal and !self.loop.operationPending(op)) {
                self.write_operation = null;
            } else if (!self.write_terminal and !self.write_cancel) {
                self.loop.prepareCancel(op) catch |err| switch (err) {
                    error.SubmissionQueueFull => return,
                    error.CancellationAlreadyPending => {},
                    else => return err,
                };
                self.write_cancel = true;
            }
        }
        if (self.operation == null and self.write_operation == null) self.finishClose();
    }

    pub fn canDeinit(self: *const Client) bool {
        return self.phase == .closed and self.operation == null and self.write_operation == null and self.timer == null;
    }
    pub fn deinit(self: *Client) void {
        std.debug.assert(self.canDeinit());
        self.deinitImmediate();
        self.* = undefined;
    }

    fn tryNextAddress(self: *Client) !void {
        while (self.next_address < self.addresses.len) {
            const end = std.mem.indexOfScalarPos(u8, self.addresses, self.next_address, ';') orelse self.addresses.len;
            const item = self.addresses[self.next_address..end];
            self.next_address = @min(end + 1, self.addresses.len);
            const address = parseAddress(item) catch continue;
            const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
            if (linux.errno(socket_result) != .SUCCESS) continue;
            self.fd = @intCast(socket_result);
            self.operation = self.loop.prepareUnixConnect(self.fd, &address.address, address.length) catch {
                _ = linux.close(self.fd);
                self.fd = -1;
                continue;
            };
            return;
        }
        self.fail(error.AddressUnavailable);
    }

    fn connectFailed(self: *Client) !bool {
        self.operation = null;
        self.operation_terminal = false;
        _ = linux.close(self.fd);
        self.fd = -1;
        try self.tryNextAddress();
        return true;
    }
    fn setAuthExternal(self: *Client) !void {
        var uid: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&uid, "{d}", .{linux.getuid()});
        var w: std.Io.Writer = .fixed(&self.auth);
        try w.writeByte(0);
        try w.writeAll("AUTH EXTERNAL ");
        for (text) |c| try w.print("{x:0>2}", .{c});
        try w.writeAll("\r\n");
        self.auth_len = w.buffered().len;
        self.auth_offset = 0;
    }
    fn setAuth(self: *Client, value: []const u8) void {
        @memcpy(self.auth[0..value.len], value);
        self.auth_len = value.len;
        self.auth_offset = 0;
    }
    fn preparePlainSend(self: *Client) !void {
        self.operation = try self.loop.prepareSend(self.fd, self.auth[self.auth_offset..self.auth_len]);
    }

    fn pump(self: *Client) !void {
        switch (self.phase) {
            .ready, .hello => {
                // Parsing previously buffered frames must not revisit a receive
                // buffer still owned by the kernel.
                try self.consumeReceive(0);
                if (self.phase == .closing or self.phase == .closed) return;
                if (self.write_operation == null and self.outgoing.items.len != 0) try self.prepareSend();
                if (self.operation == null and self.messages.items.len < max_messages and
                    self.message_bytes < wire.max_message_size and (try wire.messageLength(self.receive.items)) == null)
                    try self.prepareRecv();
            },
            .auth_recv, .negotiate_recv => if (self.operation == null) try self.prepareRecv(),
            .auth_send, .negotiate_send, .begin_send => if (self.operation == null) try self.preparePlainSend(),
            else => {},
        }
    }
    fn prepareRecv(self: *Client) !void {
        self.recv_iov[0] = .{ .base = &self.recv_buffer, .len = self.recv_buffer.len };
        self.recv_header = .{ .name = null, .namelen = 0, .iov = &self.recv_iov, .iovlen = 1, .control = &self.recv_control, .controllen = self.recv_control.len, .flags = 0 };
        self.operation = try self.loop.prepareRecvMsg(self.fd, &self.recv_header);
        self.operation_terminal = false;
    }
    fn prepareSend(self: *Client) !void {
        if (self.outgoing.items.len == 0 or self.write_operation != null) return;
        const q = &self.outgoing.items[0];
        self.send_iov[0] = .{ .base = q.bytes[q.offset..].ptr, .len = q.bytes.len - q.offset };
        var control: ?*const anyopaque = null;
        var control_len: usize = 0;
        if (!q.fds_sent and q.fds.len != 0) {
            @memset(&self.send_control, 0);
            const h: *linux.cmsghdr = @ptrCast(&self.send_control);
            const header_size = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @sizeOf(usize));
            h.* = .{ .len = header_size + q.fds.len * @sizeOf(linux.fd_t), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
            @memcpy(self.send_control[header_size..][0 .. q.fds.len * @sizeOf(linux.fd_t)], std.mem.sliceAsBytes(q.fds));
            control = &self.send_control;
            control_len = header_size + std.mem.alignForward(usize, q.fds.len * @sizeOf(linux.fd_t), @sizeOf(usize));
        }
        self.send_header = .{ .name = null, .namelen = 0, .iov = &self.send_iov, .iovlen = 1, .control = control, .controllen = control_len, .flags = 0 };
        self.write_operation = try self.loop.prepareSendMsg(self.fd, &self.send_header);
        self.write_terminal = false;
    }

    fn consumeReceive(self: *Client, n: usize) !void {
        if (n != 0) {
            if (self.recv_header.flags & linux.MSG.CTRUNC != 0) {
                closeControlFds(self.recv_control[0..self.recv_header.controllen]);
                return error.ProtocolError;
            }
            try self.collectFds(self.recv_control[0..self.recv_header.controllen]);
        }
        if (self.phase == .auth_recv or self.phase == .negotiate_recv) {
            try self.auth_line.appendSlice(self.allocator, self.recv_buffer[0..n]);
            if (self.auth_line.items.len > 1024) return self.protocolFail();
            if (std.mem.indexOf(u8, self.auth_line.items, "\r\n")) |end| {
                if (end + 2 != self.auth_line.items.len) return error.ProtocolError;
                const line = self.auth_line.items[0..end];
                if (self.phase == .auth_recv) {
                    if (!std.mem.startsWith(u8, line, "OK ")) return self.protocolFail();
                    self.setAuth("NEGOTIATE_UNIX_FD\r\n");
                    self.phase = .negotiate_send;
                } else {
                    if (std.mem.eql(u8, line, "AGREE_UNIX_FD")) self.unix_fds = true else if (!std.mem.startsWith(u8, line, "ERROR")) return self.protocolFail();
                    self.setAuth("BEGIN\r\n");
                    self.phase = .begin_send;
                }
                self.auth_line.clearRetainingCapacity();
            }
            return;
        }
        if (n > wire.max_message_size -| self.receive.items.len) return self.protocolFail();
        try self.receive.appendSlice(self.allocator, self.recv_buffer[0..n]);
        while (try wire.messageLength(self.receive.items)) |length| {
            if (self.messages.items.len >= max_messages or length > wire.max_message_size -| self.message_bytes) break;
            try self.messages.ensureUnusedCapacity(self.allocator, 1);
            const data = try self.allocator.dupe(u8, self.receive.items[0..length]);
            var data_owned = true;
            errdefer if (data_owned) self.allocator.free(data);
            const fd_count = try frameFdCount(data);
            if (fd_count > self.received_fds.items.len or fd_count > max_fds) return self.protocolFail();
            const fds = try self.allocator.alloc(linux.fd_t, fd_count);
            @memcpy(fds, self.received_fds.items[0..fd_count]);
            const message = wire.parseMessage(self.allocator, data, fds) catch |e| {
                self.allocator.free(fds);
                return e;
            };
            data_owned = false;
            const remaining_fds = self.received_fds.items.len - fd_count;
            std.mem.copyForwards(linux.fd_t, self.received_fds.items[0..remaining_fds], self.received_fds.items[fd_count..]);
            self.received_fds.items.len = remaining_fds;
            const remain = self.receive.items.len - length;
            std.mem.copyForwards(u8, self.receive.items[0..remain], self.receive.items[length..]);
            self.receive.items.len = remain;
            if (self.phase == .hello and message.header.reply_serial == self.hello_serial) {
                var owned = message;
                defer owned.deinit();
                if (owned.messageType() != .method_return or !std.mem.eql(u8, owned.bodySignature(), "s")) return self.protocolFail();
                var d = owned.bodyDecoder();
                _ = d.string() catch return self.protocolFail();
                d.end() catch return self.protocolFail();
                self.phase = .ready;
                if (self.timer) |timer| {
                    self.loop.prepareCancel(timer) catch {};
                    self.timer = null;
                }
            } else {
                self.messages.appendAssumeCapacity(message);
                self.message_bytes += message.data.len;
            }
        }
    }

    fn collectFds(self: *Client, control: []const u8) !void {
        const previous = self.received_fds.items.len;
        errdefer {
            self.received_fds.items.len = previous;
            closeControlFds(control);
        }
        var offset: usize = 0;
        while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
            const h: *align(1) const linux.cmsghdr = @ptrCast(control[offset..].ptr);
            const hs = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @sizeOf(usize));
            if (h.len < hs or h.len > control.len - offset) return self.protocolFail();
            if (h.level == linux.SOL.SOCKET and h.type == linux.SCM.RIGHTS) {
                const bytes = control[offset + hs .. offset + h.len];
                if (bytes.len % @sizeOf(linux.fd_t) != 0) return self.protocolFail();
                const count = bytes.len / @sizeOf(linux.fd_t);
                if (!self.unix_fds or count > max_fds * max_messages -| self.received_fds.items.len)
                    return error.ProtocolError;
                try self.received_fds.ensureUnusedCapacity(self.allocator, count);
                var i: usize = 0;
                while (i < bytes.len) : (i += @sizeOf(linux.fd_t))
                    self.received_fds.appendAssumeCapacity(std.mem.readInt(linux.fd_t, bytes[i..][0..@sizeOf(linux.fd_t)], .native));
            }
            offset = std.mem.alignForward(usize, offset + h.len, @sizeOf(usize));
        }
    }

    fn protocolFail(self: *Client) Error {
        self.fail(error.ProtocolError);
        return error.ProtocolError;
    }
    fn fail(self: *Client, e: anyerror) void {
        if (self.failure == null) self.failure = e;
        self.close() catch {};
    }
    fn finishClose(self: *Client) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
        self.phase = .closed;
    }
    fn deinitImmediate(self: *Client) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        for (self.outgoing.items) |q| {
            for (q.fds) |fd| _ = linux.close(fd);
            self.allocator.free(q.fds);
            self.allocator.free(q.bytes);
        }
        for (self.messages.items) |*m| m.deinit();
        for (self.received_fds.items) |fd| _ = linux.close(fd);
        self.outgoing.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.received_fds.deinit(self.allocator);
        self.receive.deinit(self.allocator);
        self.auth_line.deinit(self.allocator);
        self.allocator.free(self.addresses);
    }
};

const ParsedAddress = struct { address: linux.sockaddr.un, length: linux.socklen_t };
fn parseAddress(text: []const u8) !ParsedAddress {
    if (!std.mem.startsWith(u8, text, "unix:")) return error.InvalidAddress;
    var result: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    var found = false;
    var abstract = false;
    var length: usize = 0;
    var options = std.mem.splitScalar(u8, text[5..], ',');
    while (options.next()) |option| {
        const eq = std.mem.indexOfScalar(u8, option, '=') orelse return error.InvalidAddress;
        const key = option[0..eq];
        if (!std.mem.eql(u8, key, "path") and !std.mem.eql(u8, key, "abstract")) continue;
        if (found) return error.InvalidAddress;
        found = true;
        abstract = std.mem.eql(u8, key, "abstract");
        if (abstract) {
            result.path[0] = 0;
            length = 1;
        }
        var i = eq + 1;
        while (i < option.len) {
            var c = option[i];
            if (c == '%') {
                if (i + 2 >= option.len) return error.InvalidAddress;
                c = std.fmt.parseInt(u8, option[i + 1 .. i + 3], 16) catch return error.InvalidAddress;
                i += 3;
            } else i += 1;
            if (c == 0 and !abstract) return error.InvalidAddress;
            if (length >= result.path.len - @intFromBool(!abstract)) return error.InvalidAddress;
            result.path[length] = c;
            length += 1;
        }
    }
    if (!found or length <= @intFromBool(abstract)) return error.InvalidAddress;
    if (!abstract) {
        result.path[length] = 0;
        length += 1;
    }
    return .{ .address = result, .length = @intCast(@offsetOf(linux.sockaddr.un, "path") + length) };
}

fn frameFdCount(data: []const u8) !usize {
    const endian: std.builtin.Endian = if (data[0] == 'l') .little else .big;
    const fields: usize = std.mem.readInt(u32, data[12..16], endian);
    var d: wire.Decoder = .{ .data = data[16 .. 16 + fields], .endian = endian, .base_offset = 16 };
    var count: usize = 0;
    while (!d.finished()) {
        try d.structAlignment();
        const code = try d.byte();
        const sig = try d.variantSignature();
        if (code == 9) {
            if (!std.mem.eql(u8, sig, "u")) return error.ProtocolError;
            count = try d.uint32();
        } else try d.skipSignatureValue(sig);
    }
    return count;
}
fn same(a: io.OperationHandle, b: io.OperationHandle) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn closeControlFds(control: []const u8) void {
    var offset: usize = 0;
    const hs = std.mem.alignForward(usize, @sizeOf(linux.cmsghdr), @sizeOf(usize));
    while (offset + hs <= control.len) {
        const h: *align(1) const linux.cmsghdr = @ptrCast(control[offset..].ptr);
        if (h.len < hs or h.len > control.len - offset) return;
        if (h.level == linux.SOL.SOCKET and h.type == linux.SCM.RIGHTS) {
            var i = offset + hs;
            while (i + @sizeOf(linux.fd_t) <= offset + h.len) : (i += @sizeOf(linux.fd_t))
                _ = linux.close(std.mem.readInt(linux.fd_t, control[i..][0..4], .native));
        }
        offset = std.mem.alignForward(usize, offset + h.len, @sizeOf(usize));
    }
}

test "D-Bus address path and abstract parsing with escaping" {
    const path = try parseAddress("unix:path=/tmp/a%2Db");
    try std.testing.expectEqualStrings("/tmp/a-b", std.mem.sliceTo(path.address.path[0..], 0));
    const abstract = try parseAddress("unix:abstract=ouro%2Dtest");
    try std.testing.expectEqual(@as(u8, 0), abstract.address.path[0]);
    try std.testing.expectEqualStrings("ouro-test", abstract.address.path[1..10]);
}

test "D-Bus transport fragments full duplex messages and transfers FDs once" {
    const a = std.testing.allocator;
    var loop: io.Loop = undefined;
    try loop.init(a, 32, 16);
    defer loop.deinit();
    var sockets: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &sockets)));
    const size: u32 = 4096;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.setsockopt(sockets[0], linux.SOL.SOCKET, linux.SO.SNDBUF, @ptrCast(&size), @sizeOf(u32))));
    var first: Client = .{ .allocator = a, .loop = &loop, .fd = sockets[0], .phase = .ready, .unix_fds = true };
    var second: Client = .{ .allocator = a, .loop = &loop, .fd = sockets[1], .phase = .ready, .unix_fds = true };
    defer first.deinit();
    defer second.deinit();
    defer testDrain(&loop, &first, &second) catch unreachable;
    var body = wire.Encoder.init(a);
    defer body.deinit();
    try body.uint32(0x12345678);
    try body.unixFd(0);
    const array = try body.beginArray(1);
    for (0..96 * 1024) |i| try body.byte(@truncate(i * 17 + 3));
    try body.endArray(array);
    const opened = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    const fd: linux.fd_t = @intCast(opened);
    _ = first.send(.{ .message_type = .signal, .path = "/test", .interface = "dev.ourokit.Test", .member = "Large", .signature = "uhay" }, body.bytes(), &.{fd}) catch |err| {
        _ = linux.close(fd);
        return err;
    };
    _ = linux.close(fd);
    _ = try first.send(.{ .message_type = .signal, .path = "/test", .interface = "dev.ourokit.Test", .member = "After" }, &.{}, &.{});
    _ = try second.send(.{ .message_type = .signal, .path = "/test", .interface = "dev.ourokit.Test", .member = "Reverse", .signature = "y" }, &.{71}, &.{});
    var received: usize = 0;
    var reverse = false;
    while (received < 2 or !reverse) {
        try first.collectCanceled();
        try second.collectCanceled();
        try testStep(&loop, &first, &second);
        if (first.failure) |err| return err;
        if (second.failure) |err| return err;
        while (try first.takeMessage()) |incoming| {
            var message = incoming;
            defer message.deinit();
            try std.testing.expectEqualStrings("Reverse", message.header.member.?);
            try std.testing.expectEqualSlices(u8, &.{71}, message.body());
            reverse = true;
        }
        while (try second.takeMessage()) |incoming| {
            var message = incoming;
            defer message.deinit();
            if (received == 0) {
                try std.testing.expectEqualStrings("Large", message.header.member.?);
                try std.testing.expectEqualSlices(u8, body.bytes(), message.body());
                try std.testing.expectEqual(@as(usize, 1), message.fds.len);
                try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), linux.fcntl(message.fds[0], linux.F.GETFD, 0));
            } else {
                try std.testing.expectEqualStrings("After", message.header.member.?);
                try std.testing.expectEqual(@as(usize, 0), message.fds.len);
            }
            received += 1;
        }
    }
}

test "D-Bus startup timeout cancels a silent abstract bus without leaking operations" {
    const a = std.testing.allocator;
    var loop: io.Loop = undefined;
    try loop.init(a, 16, 8);
    defer loop.deinit();
    const address_text = try std.fmt.allocPrint(a, "unix:abstract=ouro-dbus-timeout-{d}", .{linux.getpid()});
    defer a.free(address_text);
    const address = try parseAddress(address_text);
    const opened = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(opened));
    const listener: linux.fd_t = @intCast(opened);
    defer _ = linux.close(listener);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(listener, @ptrCast(&address.address), address.length)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.listen(listener, 1)));
    var client: Client = undefined;
    try client.init(a, &loop, address_text);
    defer client.deinit();
    var unused: Client = .{ .allocator = a, .loop = &loop };
    defer testDrain(&loop, &client, &unused) catch unreachable;
    while (client.failure == null) try testStep(&loop, &client, &unused);
    try std.testing.expectEqual(error.Timeout, client.failure.?);
}

fn testStep(loop: *io.Loop, first: *Client, second: *Client) !void {
    _ = try loop.submit();
    switch (loop.dispatch(try loop.wait())) {
        .socket => |completion| if (!(try first.dispatch(completion)) and !(try second.dispatch(completion))) return error.UnownedCompletion,
        .operation_cancel => {
            try first.collectCanceled();
            try second.collectCanceled();
        },
        .timer_control, .timer_wakeup => while (try loop.takeExpired()) |timer| {
            if (!(try first.dispatchTimer(timer.operation)) and !(try second.dispatchTimer(timer.operation))) return error.UnownedCompletion;
        },
        else => return error.UnexpectedCompletion,
    }
}
fn testDrain(loop: *io.Loop, first: *Client, second: *Client) !void {
    try first.close();
    try second.close();
    while (!first.canDeinit() or !second.canDeinit() or loop.hasPendingTimerKernelWork()) try testStep(loop, first, second);
    try std.testing.expect(!loop.hasPendingOperations());
}
