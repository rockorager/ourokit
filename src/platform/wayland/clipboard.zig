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
const uri_mime = "text/uri-list";
const read_size = 16 * 1024;
const drag_event_capacity = 32;

const Offer = struct {
    handle: ?Handle = null,
    utf8: bool = false,
    plain: bool = false,
    uri_list: bool = false,
    source_copy: bool = false,
    selected_copy: bool = false,
};

pub const DragMime = enum { text, uri_list };
pub const DragEvent = union(enum) {
    enter: struct { offer_id: u32, serial: u32, surface: u32, x: f32, y: f32, text: bool, uri_list: bool },
    motion: struct { time_ms: u32, x: f32, y: f32 },
    leave,
    drop,
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
    drag: bool = false,
    drag_offer_id: ?u32 = null,
    drag_mime: DragMime = .text,
};

const Source = struct {
    handle: ?Handle = null,
    id: u32 = 0,
    bytes: std.ArrayList(u8) = .empty,
    canceled: bool = false,
    mime: DragMime = .text,
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

pub const DragCompletion = struct { request: RequestHandle, mime: DragMime, bytes: ?[]const u8 };

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
    drag_events: [drag_event_capacity]DragEvent = undefined,
    drag_event_head: usize = 0,
    drag_event_count: usize = 0,
    drop_seen: bool = false,
    dispatch_offer_id: ?u32 = null,
    dispatch_serial: ?u32 = null,

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
                    self.drop_seen = false;
                    try self.pushDragEvent(.{ .enter = .{
                        .offer_id = id,
                        .serial = enter.serial,
                        .surface = enter.surface,
                        .x = fixedToFloat(enter.x),
                        .y = fixedToFloat(enter.y),
                        .text = offer.utf8 or offer.plain,
                        .uri_list = offer.uri_list,
                    } });
                };
            },
            .leave => {
                try self.pushDragEvent(.leave);
                // Compositors send leave after drop. The offer remains valid
                // until the asynchronous pipe is consumed and finish is sent.
                if (!self.drop_seen) try self.clearDragOffer(objects, queue);
            },
            .drop => {
                self.drop_seen = true;
                try self.pushDragEvent(.drop);
            },
            .motion => |motion| try self.pushDragEvent(.{ .motion = .{
                .time_ms = motion.time,
                .x = fixedToFloat(motion.x),
                .y = fixedToFloat(motion.y),
            } }),
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
                    offer.plain = true
                else if (std.ascii.eqlIgnoreCase(value.mime_type, uri_mime))
                    offer.uri_list = true;
            },
            .source_actions => |actions| offer.source_copy = (actions.source_actions.value & 1) != 0,
            .action => |action| offer.selected_copy = action.dnd_action.value == 1,
        }
    }

    pub fn takeDragEvent(self: *Clipboard) ?DragEvent {
        if (self.drag_event_count == 0) return null;
        const event = self.drag_events[self.drag_event_head];
        self.drag_event_head = (self.drag_event_head + 1) % drag_event_capacity;
        self.drag_event_count -= 1;
        // Protocol dispatch may already have received the next drag. Resolve
        // each queued event against its own offer, never the latest wire state.
        if (event == .enter) {
            self.dispatch_offer_id = event.enter.offer_id;
            self.dispatch_serial = event.enter.serial;
        } else if (event == .leave) {
            self.dispatch_offer_id = null;
            self.dispatch_serial = null;
        }
        return event;
    }

    fn pushDragEvent(self: *Clipboard, event: DragEvent) !void {
        if (event == .motion and self.drag_event_count != 0) {
            const last = &self.drag_events[(self.drag_event_head + self.drag_event_count - 1) % drag_event_capacity];
            if (last.* == .motion) {
                last.* = event;
                return;
            }
        }
        if (self.drag_event_count == drag_event_capacity) return error.DragEventCapacityExceeded;
        self.drag_events[(self.drag_event_head + self.drag_event_count) % drag_event_capacity] = event;
        self.drag_event_count += 1;
    }

    /// Negotiate only after retained hit testing found a matching target.
    pub fn acceptDrag(self: *Clipboard, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue, mime: ?DragMime) !void {
        const id = self.dispatch_offer_id orelse return;
        const offer = self.offerForId(id) orelse return;
        const selected: ?[]const u8 = if (mime) |kind| switch (kind) {
            .text => if (offer.utf8) utf8_mime else if (offer.plain) plain_mime else null,
            .uri_list => if (offer.uri_list) uri_mime else null,
        } else null;
        try wayring.client.sendRequest(protocol.wl_data_offer, objects, queue, offer.handle.?, .{
            .accept = .{ .serial = self.dispatch_serial.?, .mime_type = selected },
        });
        if (objectVersion(objects, offer.handle.?) >= 3) try wayring.client.sendRequest(
            protocol.wl_data_offer,
            objects,
            queue,
            offer.handle.?,
            .{ .set_actions = .{ .dnd_actions = if (selected == null) .none else .copy, .preferred_action = if (selected == null) .none else .copy } },
        );
    }

    /// Starts the bounded asynchronous receive for the current drag offer.
    /// URI-list bytes are only syntax-validated by the application layer; this
    /// module never opens or stats paths named by an untrusted offer.
    pub fn receiveDrop(self: *Clipboard, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue, request: RequestHandle, mime: DragMime) !bool {
        const id = self.dispatch_offer_id orelse return false;
        const offer = self.offerForId(id) orelse return false;
        const selected: ?[]const u8 = switch (mime) {
            .text => if (offer.utf8) utf8_mime else if (offer.plain) plain_mime else null,
            .uri_list => if (offer.uri_list) uri_mime else null,
        };
        if (selected == null or (objectVersion(objects, offer.handle.?) >= 3 and
            (!offer.source_copy or !offer.selected_copy))) return false;
        const transfer = try self.beginReceive(objects, queue, offer, request, selected.?);
        transfer.drag = true;
        transfer.drag_offer_id = id;
        transfer.drag_mime = mime;
        return true;
    }

    pub fn rejectDrop(self: *Clipboard, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue) !void {
        if (self.dispatch_offer_id) |id| try self.destroyOffer(objects, queue, id);
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
            .dnd_finished => {
                const id = source.handle.?.id;
                try wayring.client.sendRequest(protocol.wl_data_source, objects, queue, source.handle.?, .{ .destroy = .{} });
                source.handle = null;
                source.canceled = true;
                if (self.current_source_id != null and self.current_source_id.? == id)
                    self.current_source_id = null;
                self.collectSource(source);
            },
            .target, .dnd_drop_performed, .action => {},
        }
    }

    /// `serial` must be the compositor serial from the button press which
    /// caused this drag. Callers deliberately cannot request a synthetic one.
    pub fn startDrag(self: *Clipboard, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue, serial: u32, origin_surface: u32, mime: DragMime, bytes: []const u8) !void {
        if (serial == 0) return error.InvalidDragSerial;
        if (bytes.len == 0 or bytes.len > self.max_text_bytes) return error.InvalidDragPayload;
        if (mime == .text and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidDragPayload;
        if (mime == .uri_list and !validUriList(bytes)) return error.InvalidDragPayload;
        const manager = self.manager orelse return error.ClipboardManagerUnavailable;
        // Copy negotiation and a definitive source-finished event require v3.
        if (objectVersion(objects, manager) < 3) return error.DragActionsUnavailable;
        const device = self.device orelse return error.ClipboardDeviceUnavailable;
        const source = for (self.sources) |*candidate| {
            if (candidate.handle == null and candidate.bytes.items.len == 0) break candidate;
        } else return error.ClipboardSourceCapacityExceeded;
        try source.bytes.appendSlice(self.allocator, bytes);
        errdefer source.bytes.deinit(self.allocator);
        source.handle = (try protocol.wl_data_device_manager.construct_create_data_source(objects, queue, manager, .{})).id;
        source.id = source.handle.?.id;
        source.canceled = false;
        source.mime = mime;
        try wayring.client.sendRequest(protocol.wl_data_source, objects, queue, source.handle.?, .{
            .offer = .{ .mime_type = if (mime == .text) utf8_mime else uri_mime },
        });
        if (objectVersion(objects, source.handle.?) >= 3) try wayring.client.sendRequest(
            protocol.wl_data_source,
            objects,
            queue,
            source.handle.?,
            .{ .set_actions = .{ .dnd_actions = .copy } },
        );
        try wayring.client.sendRequest(protocol.wl_data_device, objects, queue, device, .{
            .start_drag = .{ .source = source.handle.?.id, .origin = origin_surface, .icon = null, .serial = serial },
        });
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
        _ = try self.beginReceive(objects, queue, offer.?, request, mime.?);
        return true;
    }

    fn beginReceive(self: *Clipboard, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue, offer: *Offer, request: RequestHandle, mime: []const u8) !*Transfer {
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
            offer.handle.?,
            .{ .receive = .{ .mime_type = mime, .fd = pipe[1] } },
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
        return transfer;
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
        for (self.transfers) |*transfer| if (transfer.state == .completed and !transfer.drag) {
            transfer.state = .delivered;
            return .{
                .request = transfer.request,
                .text = if (!transfer.canceled and !transfer.failed) transfer.bytes.items else null,
                .canceled = transfer.canceled,
            };
        };
        return null;
    }

    pub fn takeDragCompletion(self: *Clipboard) ?DragCompletion {
        for (self.transfers) |*transfer| if (transfer.state == .completed and transfer.drag) {
            transfer.state = .delivered;
            return .{ .request = transfer.request, .mime = transfer.drag_mime, .bytes = if (!transfer.canceled and !transfer.failed) transfer.bytes.items else null };
        };
        return null;
    }

    pub fn finishDrop(self: *Clipboard, objects: *wayring.objects.ClientObjects, queue: *wayring.tx.Queue, request: RequestHandle, accepted: bool) !void {
        const transfer = self.transferForRequest(request) orelse return error.StaleClipboardRequest;
        if (!transfer.drag or transfer.state != .delivered) return error.InvalidClipboardTransfer;
        if (transfer.drag_offer_id) |id| if (self.offerForId(id)) |offer| {
            if (accepted and !transfer.failed and !transfer.canceled and objectVersion(objects, offer.handle.?) >= 3)
                try wayring.client.sendRequest(protocol.wl_data_offer, objects, queue, offer.handle.?, .{ .finish = .{} });
            try self.destroyOffer(objects, queue, id);
        };
        self.resetTransfer(transfer);
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
        const object = objects.namespace.resolve(device) orelse return error.StaleHandle;
        if (object.version >= 2) try wayring.client.sendRequest(
            protocol.wl_data_device,
            objects,
            queue,
            device,
            .{ .release = .{} },
        ) else {
            // Older objects have no wire destructor. Keep their ID reserved
            // until disconnect and discard any late events through a tombstone.
            _ = try objects.retireLocal(device);
        }
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
        const object = objects.namespace.resolve(manager) orelse return error.StaleHandle;
        if (object.version >= 4) try wayring.client.sendRequest(
            protocol.wl_data_device_manager,
            objects,
            queue,
            manager,
            .{ .release = .{} },
        ) else {
            _ = try objects.retireLocal(manager);
        }
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
        self.drag_event_head = 0;
        self.drag_event_count = 0;
        self.drop_seen = false;
        self.dispatch_offer_id = null;
        self.dispatch_serial = null;
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
        if ((source.mime == .text and (std.ascii.eqlIgnoreCase(mime_type, utf8_mime) or
            std.ascii.eqlIgnoreCase(mime_type, plain_mime))) or
            (source.mime == .uri_list and std.ascii.eqlIgnoreCase(mime_type, uri_mime)))
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

fn objectVersion(objects: *wayring.objects.ClientObjects, handle: Handle) u32 {
    return if (objects.namespace.resolve(handle)) |object| object.version else 0;
}

fn fixedToFloat(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 256.0;
}

/// RFC 2483 text/uri-list validation. It validates transport syntax only and
/// intentionally performs no filesystem access or URI dereferencing.
pub fn validUriList(bytes: []const u8) bool {
    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return false;
    var found = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, ':') == null) return false;
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        if (colon == 0 or !std.ascii.isAlphabetic(line[0])) return false;
        for (line[1..colon]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return false;
        var index: usize = colon + 1;
        while (index < line.len) : (index += 1) {
            const byte = line[index];
            if (byte < 0x20 or byte == 0x7f or byte == ' ') return false;
            if (byte == '%') {
                if (index + 2 >= line.len or !std.ascii.isHex(line[index + 1]) or !std.ascii.isHex(line[index + 2])) return false;
                index += 2;
            }
        }
        found = true;
    }
    return found;
}

test "URI lists are validated without resolving their resources" {
    try std.testing.expect(validUriList("# files\r\nfile:///tmp/a%20b\r\nhttps://example.test/x\n"));
    try std.testing.expect(!validUriList("/tmp/not-a-uri\n"));
    try std.testing.expect(!validUriList("file:///tmp/bad%2\n"));
    try std.testing.expect(!validUriList("file:///tmp/raw space\n"));
    try std.testing.expect(!validUriList("# comments only\n"));
}

test "drag event queue preserves enter motion drop and leave in one dispatch batch" {
    var clipboard: Clipboard = undefined;
    clipboard.drag_event_head = 0;
    clipboard.drag_event_count = 0;
    try clipboard.pushDragEvent(.{ .enter = .{ .offer_id = 17, .serial = 1, .surface = 2, .x = 3, .y = 4, .text = true, .uri_list = false } });
    try clipboard.pushDragEvent(.{ .motion = .{ .time_ms = 5, .x = 6, .y = 7 } });
    for (0..100) |i| try clipboard.pushDragEvent(.{ .motion = .{ .time_ms = @intCast(i + 6), .x = @floatFromInt(i), .y = 9 } });
    try clipboard.pushDragEvent(.drop);
    try clipboard.pushDragEvent(.leave);
    try std.testing.expect(clipboard.takeDragEvent().? == .enter);
    try std.testing.expectEqual(@as(?u32, 17), clipboard.dispatch_offer_id);
    try std.testing.expectEqual(@as(?u32, 1), clipboard.dispatch_serial);
    try std.testing.expectEqual(@as(f32, 99), clipboard.takeDragEvent().?.motion.x);
    try std.testing.expect(clipboard.takeDragEvent().? == .drop);
    try std.testing.expect(clipboard.takeDragEvent().? == .leave);
    try std.testing.expect(clipboard.takeDragEvent() == null);
}

test "clipboard teardown respects device and manager destructor versions" {
    const allocator = std.testing.allocator;
    for ([_]u32{ 1, 2, 3, 4 }) |version| {
        var objects = try wayring.objects.ClientObjects.init(allocator, 8, 8, &protocol.wl_display.info, null);
        defer objects.deinit(allocator);
        var blocks = try wayring.pool.SharedBlocks.init(allocator, 1024, 1);
        defer blocks.deinit(allocator);
        var fds = try wayring.pool.SharedFds.init(allocator, 1);
        defer fds.deinit(allocator);
        var queue = wayring.tx.Queue.init(&blocks, 1024, &fds, 0);
        defer queue.deinit();
        var loop: OuroLoop = undefined; // No transfers or kernel operations.
        var clipboard = try Clipboard.init(allocator, &loop, 1, 1, 1, 1, 64);
        defer clipboard.deinit();
        defer clipboard.abandonProtocol();
        const manager = try objects.createLocal(&protocol.wl_data_device_manager.info, version, null);
        const device = try objects.createLocal(&protocol.wl_data_device.info, version, null);
        clipboard.bindManager(manager, 19);
        clipboard.device = device;

        if (version < 3) try std.testing.expectError(error.DragActionsUnavailable, clipboard.startDrag(&objects, &queue, 47, 91, .text, "copy"));
        try std.testing.expect(try clipboard.releaseManager(&objects, &queue));
        try std.testing.expect(clipboard.manager == null and clipboard.device == null);
        try std.testing.expect(clipboard.manager_global_name == null);
        try std.testing.expect(objects.namespace.resolve(manager).?.destroyed);
        try std.testing.expect(objects.namespace.resolve(device).?.destroyed);
        const expected_bytes: usize = if (version == 1) 0 else if (version < 4) 8 else 16;
        try std.testing.expectEqual(expected_bytes, queue.queuedBytes());
        if (version >= 2) {
            const bytes = (try queue.snapshot(&.{}, &.{})).first;
            const device_release = (try wayring.wire.Message.decode(bytes)).?;
            try std.testing.expectEqual(device.id, device_release.header.object_id);
            try std.testing.expectEqual(@as(u16, 2), device_release.header.opcode);
            if (version >= 4) {
                const manager_release = (try wayring.wire.Message.decode(bytes[8..])).?;
                try std.testing.expectEqual(manager.id, manager_release.header.object_id);
                try std.testing.expectEqual(@as(u16, 2), manager_release.header.opcode);
            }
        }
        // A proxy with no wire destructor must not recycle a live server ID.
        const next = try objects.createLocal(&protocol.wl_data_device_manager.info, version, null);
        try std.testing.expect(next.id != manager.id and next.id != device.id);
        try std.testing.expect(!try clipboard.releaseManager(&objects, &queue));
        try std.testing.expectEqual(expected_bytes, queue.queuedBytes());
    }
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
