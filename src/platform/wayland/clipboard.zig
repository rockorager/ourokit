const std = @import("std");
const wayring = @import("wayring");
const protocol = @import("wayland_protocol");
const Handle = wayring.objects.Handle;
const RequestHandle = @import("../../core/handle.zig").Handle;
const OuroLoop = @import("../../loop/io_uring.zig").Loop;
const FileCompletion = @import("../../loop/io_uring.zig").FileCompletion;
const OperationHandle = @import("../../loop/io_uring.zig").OperationHandle;

const linux = std.os.linux;
const utf8_mime = "text/plain;charset=utf-8";
const plain_mime = "text/plain";
const read_size = 16 * 1024;

const Offer = struct {
    handle: ?Handle = null,
    utf8: bool = false,
    plain: bool = false,
};

const TransferState = enum { free, reading, canceling, closing, completed, delivered };

const Transfer = struct {
    state: TransferState = .free,
    request: RequestHandle = .invalid,
    fd: linux.fd_t = -1,
    operation: OperationHandle = .invalid,
    bytes: std.ArrayList(u8) = .empty,
    scratch: [read_size]u8 = undefined,
    canceled: bool = false,
    failed: bool = false,
};

const Source = struct {
    handle: ?Handle = null,
    id: u32 = 0,
    bytes: std.ArrayList(u8) = .empty,
    canceled: bool = false,
};

const WriteState = enum { free, writing, closing };

const WriteTransfer = struct {
    state: WriteState = .free,
    source_id: u32 = 0,
    fd: linux.fd_t = -1,
    operation: OperationHandle = .invalid,
    offset: usize = 0,
};

pub const Completion = struct {
    request: RequestHandle,
    text: ?[]const u8,
    canceled: bool,
};

/// Wayland clipboard protocol and pipe-transfer state. It owns no UI or Lua
/// objects; callers identify requests with opaque generation-checked handles.
pub const Clipboard = struct {
    allocator: std.mem.Allocator,
    loop: *OuroLoop,
    offers: []Offer,
    transfers: []Transfer,
    sources: []Source,
    writes: []WriteTransfer,
    max_text_bytes: usize,
    manager: ?Handle = null,
    manager_global_name: ?u32 = null,
    device: ?Handle = null,
    selection_offer_id: ?u32 = null,
    drag_offer_id: ?u32 = null,
    current_source_id: ?u32 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *OuroLoop,
        offer_capacity: usize,
        transfer_capacity: usize,
        source_capacity: usize,
        write_capacity: usize,
        max_text_bytes: usize,
    ) !Clipboard {
        if (offer_capacity == 0 or transfer_capacity == 0 or source_capacity == 0 or
            write_capacity == 0 or max_text_bytes == 0)
            return error.InvalidClipboardCapacity;
        const offers = try allocator.alloc(Offer, offer_capacity);
        errdefer allocator.free(offers);
        const transfers = try allocator.alloc(Transfer, transfer_capacity);
        errdefer allocator.free(transfers);
        const sources = try allocator.alloc(Source, source_capacity);
        errdefer allocator.free(sources);
        const writes = try allocator.alloc(WriteTransfer, write_capacity);
        errdefer allocator.free(writes);
        @memset(offers, .{});
        @memset(transfers, .{});
        @memset(sources, .{});
        @memset(writes, .{});
        return .{
            .allocator = allocator,
            .loop = loop,
            .offers = offers,
            .transfers = transfers,
            .sources = sources,
            .writes = writes,
            .max_text_bytes = max_text_bytes,
        };
    }

    pub fn deinit(self: *Clipboard) void {
        std.debug.assert(self.manager == null and self.device == null);
        for (self.offers) |offer| std.debug.assert(offer.handle == null);
        for (self.transfers) |transfer| std.debug.assert(transfer.state == .free);
        for (self.sources) |source| std.debug.assert(source.handle == null);
        for (self.writes) |write| std.debug.assert(write.state == .free);
        self.allocator.free(self.writes);
        self.allocator.free(self.sources);
        self.allocator.free(self.transfers);
        self.allocator.free(self.offers);
        self.* = undefined;
    }

    pub fn available(self: *const Clipboard) bool {
        return self.device != null;
    }

    pub fn bindManager(
        self: *Clipboard,
        handle: Handle,
        global_name: u32,
    ) void {
        std.debug.assert(self.manager == null);
        self.manager = handle;
        self.manager_global_name = global_name;
    }

    pub fn ensureDevice(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
        seat: ?Handle,
    ) !bool {
        if (self.device != null or self.manager == null or seat == null) return false;
        self.device = (try protocol.wl_data_device_manager.construct_get_data_device(
            objects,
            queue,
            self.manager.?,
            .{ .seat = seat.?.id },
        )).id;
        return true;
    }

    pub fn managerRemoved(self: *const Clipboard, global_name: u32) bool {
        return self.manager_global_name != null and self.manager_global_name.? == global_name;
    }

    pub fn dataDeviceEvent(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const device = self.device orelse return error.ClipboardDeviceUnavailable;
        if (message.header.object_id != device.id) return error.WrongObject;
        const event = try protocol.wl_data_device.decodeEvent(message, fds);
        switch (event) {
            .data_offer => |created| {
                const slot = for (self.offers) |*candidate| {
                    if (candidate.handle == null) break candidate;
                } else return error.ClipboardOfferCapacityExceeded;
                const admitted = try protocol.wl_data_device.admit_event_data_offer(
                    objects,
                    device,
                    created,
                    .{},
                );
                slot.* = .{ .handle = admitted.id };
            },
            .selection => |selection| try self.selectOffer(objects, queue, selection.id),
            .enter => |enter| {
                self.drag_offer_id = enter.id;
                if (enter.id) |id| if (self.offerForId(id)) |offer| {
                    try wayring.client.sendRequest(
                        protocol.wl_data_offer,
                        objects,
                        queue,
                        offer.handle.?,
                        .{ .accept = .{ .serial = enter.serial, .mime_type = null } },
                    );
                };
            },
            .leave => try self.clearDragOffer(objects, queue),
            .drop => try self.clearDragOffer(objects, queue),
            .motion => {},
        }
    }

    pub fn dataOfferEvent(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const offer = self.offerForId(message.header.object_id) orelse
            return error.UnknownClipboardOffer;
        switch (try wayring.client.decodeEvent(
            protocol.wl_data_offer,
            objects,
            offer.handle.?,
            message,
            fds,
        )) {
            .offer => |value| {
                if (std.ascii.eqlIgnoreCase(value.mime_type, utf8_mime))
                    offer.utf8 = true
                else if (std.ascii.eqlIgnoreCase(value.mime_type, plain_mime))
                    offer.plain = true;
            },
            .source_actions, .action => {},
        }
    }

    pub fn dataSourceEvent(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !void {
        const source = self.sourceForId(message.header.object_id) orelse
            return error.UnknownClipboardSource;
        switch (try wayring.client.decodeEvent(
            protocol.wl_data_source,
            objects,
            source.handle.?,
            message,
            fds,
        )) {
            .send => |send| try self.beginWrite(source, send.mime_type, send.fd),
            .cancelled => {
                const id = source.handle.?.id;
                try wayring.client.sendRequest(
                    protocol.wl_data_source,
                    objects,
                    queue,
                    source.handle.?,
                    .{ .destroy = .{} },
                );
                source.handle = null;
                source.canceled = true;
                if (self.current_source_id != null and self.current_source_id.? == id)
                    self.current_source_id = null;
                self.collectSource(source);
            },
            .target, .dnd_drop_performed, .dnd_finished, .action => {},
        }
    }

    pub fn setSelection(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
        serial: u32,
        text: []const u8,
    ) !void {
        const manager = self.manager orelse return error.ClipboardManagerUnavailable;
        const device = self.device orelse return error.ClipboardDeviceUnavailable;
        if (text.len == 0 or text.len > self.max_text_bytes or
            !std.unicode.utf8ValidateSlice(text)) return error.InvalidClipboardText;
        const source = for (self.sources) |*candidate| {
            if (candidate.handle == null and candidate.bytes.items.len == 0) break candidate;
        } else return error.ClipboardSourceCapacityExceeded;
        try source.bytes.appendSlice(self.allocator, text);
        errdefer source.bytes.deinit(self.allocator);
        source.handle = (try protocol.wl_data_device_manager.construct_create_data_source(
            objects,
            queue,
            manager,
            .{},
        )).id;
        errdefer source.handle = null;
        source.id = source.handle.?.id;
        try wayring.client.sendRequest(
            protocol.wl_data_source,
            objects,
            queue,
            source.handle.?,
            .{ .offer = .{ .mime_type = utf8_mime } },
        );
        try wayring.client.sendRequest(
            protocol.wl_data_source,
            objects,
            queue,
            source.handle.?,
            .{ .offer = .{ .mime_type = plain_mime } },
        );
        try wayring.client.sendRequest(
            protocol.wl_data_device,
            objects,
            queue,
            device,
            .{ .set_selection = .{ .source = source.handle.?.id, .serial = serial } },
        );
        source.canceled = false;
        self.current_source_id = source.handle.?.id;
    }

    /// Queues `wl_data_offer.receive` and an io_uring pipe read. Returns false
    /// when no text offer exists; that case is represented as an immediate
    /// empty completion rather than a platform error.
    pub fn requestPaste(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
        request: RequestHandle,
    ) !bool {
        const offer = if (self.selection_offer_id) |id| self.offerForId(id) else null;
        const mime: ?[]const u8 = if (offer) |value|
            if (value.utf8) utf8_mime else if (value.plain) plain_mime else null
        else
            null;
        if (mime == null) return false;
        const transfer = try self.reserveTransfer(request);

        var pipe: [2]linux.fd_t = undefined;
        switch (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true }))) {
            .SUCCESS => {},
            else => {
                self.resetTransfer(transfer);
                return error.ClipboardPipeCreationFailed;
            },
        }
        var read_owned = true;
        var write_owned = true;
        errdefer {
            if (read_owned) _ = linux.close(pipe[0]);
            if (write_owned) _ = linux.close(pipe[1]);
            self.resetTransfer(transfer);
        }
        try wayring.client.sendRequest(
            protocol.wl_data_offer,
            objects,
            queue,
            offer.?.handle.?,
            .{ .receive = .{ .mime_type = mime.?, .fd = pipe[1] } },
        );
        write_owned = false; // Wayring's transmit queue owns the descriptor.
        transfer.fd = pipe[0];
        read_owned = false;
        transfer.operation = try self.loop.prepareRead(
            transfer.fd,
            &transfer.scratch,
            std.math.maxInt(u64),
        );
        transfer.state = .reading;
        return true;
    }

    pub fn cancel(self: *Clipboard, request: RequestHandle) !bool {
        const transfer = self.transferForRequest(request) orelse return false;
        switch (transfer.state) {
            .reading => {
                try self.loop.prepareCancel(transfer.operation);
                transfer.canceled = true;
                transfer.state = .canceling;
                return true;
            },
            .closing => {
                transfer.canceled = true;
                return true;
            },
            .completed => {
                transfer.canceled = true;
                return true;
            },
            .canceling => return true,
            .free, .delivered => return false,
        }
    }

    /// Returns true when this CQE belonged to a clipboard pipe. No application
    /// callback is invoked; bytes become visible only through `takeCompletion`.
    pub fn dispatchFile(self: *Clipboard, completion: FileCompletion) !bool {
        if (self.transferForOperation(completion.operation)) |transfer| {
            switch (completion.kind) {
                .read => try self.readCompleted(transfer, completion.result),
                .close => {
                    if (transfer.state != .closing) return error.InvalidClipboardTransfer;
                    transfer.fd = -1;
                    transfer.state = .completed;
                },
                else => return error.InvalidClipboardOperation,
            }
            return true;
        }
        const write = self.writeForOperation(completion.operation) orelse return false;
        try self.writeCompleted(write, completion);
        return true;
    }

    pub fn takeCompletion(self: *Clipboard) ?Completion {
        for (self.transfers) |*transfer| if (transfer.state == .completed) {
            transfer.state = .delivered;
            return .{
                .request = transfer.request,
                .text = if (!transfer.canceled and !transfer.failed) transfer.bytes.items else null,
                .canceled = transfer.canceled,
            };
        };
        return null;
    }

    pub fn releaseCompletion(self: *Clipboard, request: RequestHandle) !void {
        const transfer = self.transferForRequest(request) orelse
            return error.StaleClipboardRequest;
        if (transfer.state != .delivered) return error.InvalidClipboardTransfer;
        self.resetTransfer(transfer);
    }

    pub fn releaseDevice(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
    ) !bool {
        for (self.transfers) |transfer|
            if (transfer.state != .free) return error.ClipboardTransfersRemain;
        for (self.writes) |write| if (write.state != .free) return error.ClipboardTransfersRemain;
        try self.destroyAllSources(objects, queue);
        try self.destroyAllOffers(objects, queue);
        const device = self.device orelse return false;
        try wayring.client.sendRequest(
            protocol.wl_data_device,
            objects,
            queue,
            device,
            .{ .release = .{} },
        );
        self.device = null;
        return true;
    }

    pub fn releaseManager(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
    ) !bool {
        _ = try self.releaseDevice(objects, queue);
        const manager = self.manager orelse return false;
        try wayring.client.sendRequest(
            protocol.wl_data_device_manager,
            objects,
            queue,
            manager,
            .{ .release = .{} },
        );
        self.manager = null;
        self.manager_global_name = null;
        return true;
    }

    fn reserveTransfer(self: *Clipboard, request: RequestHandle) !*Transfer {
        if (self.transferForRequest(request) != null) return error.DuplicateClipboardRequest;
        for (self.transfers) |*transfer| if (transfer.state == .free) {
            transfer.request = request;
            transfer.state = .completed; // Rollback-safe reservation state.
            transfer.canceled = false;
            transfer.failed = false;
            return transfer;
        };
        return error.ClipboardTransferCapacityExceeded;
    }

    fn readCompleted(self: *Clipboard, transfer: *Transfer, result: i32) !void {
        if (transfer.state != .reading and transfer.state != .canceling)
            return error.InvalidClipboardTransfer;
        if (result > 0 and !transfer.canceled) {
            const count: usize = @intCast(result);
            if (count > self.max_text_bytes -| transfer.bytes.items.len) {
                transfer.bytes.clearRetainingCapacity();
                transfer.failed = true;
            } else {
                try transfer.bytes.appendSlice(self.allocator, transfer.scratch[0..count]);
            }
        }
        if (result < 0 and !transfer.canceled) transfer.failed = true;
        if (result > 0 and !transfer.canceled and !transfer.failed) {
            transfer.operation = try self.loop.prepareRead(
                transfer.fd,
                &transfer.scratch,
                std.math.maxInt(u64),
            );
            transfer.state = .reading;
            return;
        }
        transfer.operation = try self.loop.prepareClose(transfer.fd);
        transfer.state = .closing;
    }

    fn resetTransfer(self: *Clipboard, transfer: *Transfer) void {
        std.debug.assert(transfer.fd == -1);
        transfer.bytes.deinit(self.allocator);
        transfer.* = .{};
    }

    /// Drops protocol identities after the connection itself has been closed.
    /// Transfer resources must already have reached and released completion.
    pub fn abandonProtocol(self: *Clipboard) void {
        for (self.transfers) |transfer| std.debug.assert(transfer.state == .free);
        for (self.writes) |write| std.debug.assert(write.state == .free);
        for (self.sources) |*source| {
            source.bytes.deinit(self.allocator);
            source.* = .{};
        }
        @memset(self.offers, .{});
        self.manager = null;
        self.manager_global_name = null;
        self.device = null;
        self.selection_offer_id = null;
        self.drag_offer_id = null;
        self.current_source_id = null;
    }

    fn transferForRequest(self: *Clipboard, request: RequestHandle) ?*Transfer {
        for (self.transfers) |*transfer|
            if (transfer.state != .free and sameRequest(transfer.request, request)) return transfer;
        return null;
    }

    fn transferForOperation(self: *Clipboard, operation: OperationHandle) ?*Transfer {
        for (self.transfers) |*transfer|
            if (transfer.state != .free and sameRequest(transfer.operation, operation)) return transfer;
        return null;
    }

    fn sourceForId(self: *Clipboard, id: u32) ?*Source {
        for (self.sources) |*source| if (source.id == id and source.handle != null) return source;
        return null;
    }

    fn beginWrite(
        self: *Clipboard,
        source: *Source,
        mime_type: []const u8,
        fd: linux.fd_t,
    ) !void {
        var fd_owned = true;
        errdefer {
            if (fd_owned) _ = linux.close(fd);
        }
        const write = for (self.writes) |*candidate| {
            if (candidate.state == .free) break candidate;
        } else return error.ClipboardWriteCapacityExceeded;
        write.source_id = source.id;
        write.fd = fd;
        write.offset = 0;
        if (std.ascii.eqlIgnoreCase(mime_type, utf8_mime) or
            std.ascii.eqlIgnoreCase(mime_type, plain_mime))
        {
            write.operation = try self.loop.prepareWrite(
                fd,
                source.bytes.items,
                std.math.maxInt(u64),
            );
            write.state = .writing;
        } else {
            write.operation = try self.loop.prepareClose(fd);
            write.state = .closing;
        }
        fd_owned = false;
    }

    fn writeForOperation(self: *Clipboard, operation: OperationHandle) ?*WriteTransfer {
        for (self.writes) |*write|
            if (write.state != .free and sameRequest(write.operation, operation)) return write;
        return null;
    }

    fn writeCompleted(
        self: *Clipboard,
        write: *WriteTransfer,
        completion: FileCompletion,
    ) !void {
        switch (write.state) {
            .writing => {
                if (completion.kind != .write) return error.InvalidClipboardOperation;
                const source = self.sourceForStoredId(write.source_id) orelse
                    return error.UnknownClipboardSource;
                if (completion.result > 0) write.offset += @intCast(completion.result);
                if (completion.result > 0 and write.offset < source.bytes.items.len) {
                    write.operation = try self.loop.prepareWrite(
                        write.fd,
                        source.bytes.items[write.offset..],
                        std.math.maxInt(u64),
                    );
                    return;
                }
                write.operation = try self.loop.prepareClose(write.fd);
                write.state = .closing;
            },
            .closing => {
                if (completion.kind != .close) return error.InvalidClipboardOperation;
                const source_id = write.source_id;
                write.* = .{};
                if (self.sourceForStoredId(source_id)) |source| self.collectSource(source);
            },
            .free => unreachable,
        }
    }

    fn sourceForStoredId(self: *Clipboard, id: u32) ?*Source {
        for (self.sources) |*source| if (source.id == id) return source;
        return null;
    }

    fn collectSource(self: *Clipboard, source: *Source) void {
        if (!source.canceled) return;
        for (self.writes) |write|
            if (write.state != .free and write.source_id == source.id) return;
        source.bytes.deinit(self.allocator);
        source.* = .{};
    }

    fn offerForId(self: *Clipboard, id: u32) ?*Offer {
        for (self.offers) |*offer|
            if (offer.handle != null and offer.handle.?.id == id) return offer;
        return null;
    }

    fn selectOffer(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
        id: ?u32,
    ) !void {
        if (self.selection_offer_id != null and self.selection_offer_id != id)
            try self.destroyOffer(objects, queue, self.selection_offer_id.?);
        if (id) |value| {
            if (self.offerForId(value) == null) return error.UnknownClipboardOffer;
        }
        self.selection_offer_id = id;
    }

    fn clearDragOffer(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
    ) !void {
        const id = self.drag_offer_id orelse return;
        self.drag_offer_id = null;
        if (self.selection_offer_id == null or self.selection_offer_id.? != id)
            try self.destroyOffer(objects, queue, id);
    }

    fn destroyAllOffers(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
    ) !void {
        for (self.offers) |offer| if (offer.handle) |handle|
            try self.destroyOffer(objects, queue, handle.id);
        self.selection_offer_id = null;
        self.drag_offer_id = null;
    }

    fn destroyAllSources(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
    ) !void {
        for (self.sources) |*source| {
            if (source.handle) |handle| try wayring.client.sendRequest(
                protocol.wl_data_source,
                objects,
                queue,
                handle,
                .{ .destroy = .{} },
            );
            source.bytes.deinit(self.allocator);
            source.* = .{};
        }
        self.current_source_id = null;
    }

    fn destroyOffer(
        self: *Clipboard,
        objects: *wayring.objects.ClientObjects,
        queue: *wayring.tx.Queue,
        id: u32,
    ) !void {
        const offer = self.offerForId(id) orelse return;
        try wayring.client.sendRequest(
            protocol.wl_data_offer,
            objects,
            queue,
            offer.handle.?,
            .{ .destroy = .{} },
        );
        offer.* = .{};
        if (self.selection_offer_id != null and self.selection_offer_id.? == id)
            self.selection_offer_id = null;
        if (self.drag_offer_id != null and self.drag_offer_id.? == id)
            self.drag_offer_id = null;
    }
};

fn sameRequest(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "clipboard transfer drains a pipe through repeated io_uring reads" {
    var loop: OuroLoop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var clipboard = try Clipboard.init(std.testing.allocator, &loop, 2, 1, 1, 1, 64 * 1024);
    defer clipboard.deinit();

    const request: RequestHandle = .{ .slot = 7, .generation = 11 };
    const transfer = try clipboard.reserveTransfer(request);
    var pipe: [2]linux.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.ClipboardPipeCreationFailed,
    }
    transfer.fd = pipe[0];
    transfer.operation = try loop.prepareRead(
        transfer.fd,
        &transfer.scratch,
        std.math.maxInt(u64),
    );
    transfer.state = .reading;
    _ = try loop.submit();

    var payload: [read_size + 257]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index % 127 + 1);
    var written: usize = 0;
    while (written != payload.len) {
        const result = linux.write(pipe[1], payload[written..].ptr, payload.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => written += result,
            .INTR => continue,
            else => return error.ClipboardPipeWriteFailed,
        }
    }
    _ = linux.close(pipe[1]);

    const completion = while (true) {
        const dispatched = loop.dispatch(try loop.wait());
        switch (dispatched) {
            .file => |file| try std.testing.expect(try clipboard.dispatchFile(file)),
            else => return error.UnexpectedClipboardDispatch,
        }
        if (clipboard.takeCompletion()) |value| break value;
        _ = try loop.submit();
    };
    try std.testing.expectEqual(request, completion.request);
    try std.testing.expect(!completion.canceled);
    try std.testing.expectEqualSlices(u8, &payload, completion.text.?);
    try clipboard.releaseCompletion(request);
}

test "clipboard source writes and closes a compositor pipe through io_uring" {
    var loop: OuroLoop = undefined;
    try loop.init(std.testing.allocator, 8, 4);
    defer loop.deinit();
    var clipboard = try Clipboard.init(std.testing.allocator, &loop, 1, 1, 1, 1, 64 * 1024);
    defer clipboard.deinit();

    const source = &clipboard.sources[0];
    source.id = 17;
    try source.bytes.appendSlice(std.testing.allocator, "outbound clipboard");
    var pipe: [2]linux.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true }))) {
        .SUCCESS => {},
        else => return error.ClipboardPipeCreationFailed,
    }
    defer _ = linux.close(pipe[0]);
    try clipboard.beginWrite(source, utf8_mime, pipe[1]);
    _ = try loop.submit();

    const write_completion = loop.dispatch(try loop.wait()).file;
    try std.testing.expectEqual(@as(i32, @intCast(source.bytes.items.len)), write_completion.result);
    try std.testing.expect(try clipboard.dispatchFile(write_completion));

    var output: [64]u8 = undefined;
    const read_result = linux.read(pipe[0], &output, output.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(read_result));
    try std.testing.expectEqualStrings("outbound clipboard", output[0..read_result]);

    _ = try loop.submit();
    try std.testing.expect(try clipboard.dispatchFile(loop.dispatch(try loop.wait()).file));
    clipboard.abandonProtocol();
}
