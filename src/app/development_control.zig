//! Development-only transport adapter. The runner calls poll after normal
//! input, task, reconciliation and backend submission phases, never in a CQE.
const std = @import("std");
const dev = @import("development.zig");
const mcp = @import("../mcp/root.zig");
const platform = @import("../platform/window.zig");
const control = @import("control_server.zig");
const SourceReload = @import("source_reload.zig").SourceReload;
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;
const PathIdentity = @import("control_endpoint.zig").PathIdentity;
const lua = @import("../lua/root.zig");
const task = @import("../task/root.zig");

/// Upper bound of runtime.send's wait.timeout_ms (the MCP schema subset has
/// no numeric constraints, so it is enforced here and in the Lua bridge).
pub const max_wait_ms = 60_000;

/// A runtime.send delivery in flight. It runs as a task in a scope of its own
/// and does not occupy the single pending slot, so other clients' requests
/// are served while it waits; cancelling it retires the scope, which ends the
/// task, its wait_for and its observer.
const Send = struct {
    request: control.DevelopmentRequest,
    token: u64,
    scope: task.ScopeHandle,
    generation: u64,
};

pub const tools = @embedFile("development_tools.json");
pub const Window = struct { id: []const u8, runtime: *WindowRuntime };

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pending: ?control.DevelopmentRequest = null,
    playback: ?dev.Playback = null,
    /// runtime.send deliveries in flight (at most one per client).
    sends: [control.client_capacity]?Send = @splat(null),
    statecharts: ?*lua.StatechartInspector = null,
    runtime: ?*WindowRuntime = null,
    failure: ?anyerror = null,
    captures: [4]?struct { path: [:0]u8, identity: PathIdentity } = @splat(null),
    capture_index: usize = 0,

    pub fn deinit(self: *Service) void {
        if (self.pending) |*request| request.deinit();
        for (&self.sends) |*entry| if (entry.*) |*send| {
            if (self.statecharts) |store| store.dropResult(send.token);
            send.request.deinit();
            entry.* = null;
        };
        for (&self.captures) |*entry| if (entry.*) |capture| {
            capture.identity.unlink(capture.path);
            self.allocator.free(capture.path);
            entry.* = null;
        };
    }

    pub fn playing(self: *const Service) bool {
        return self.playback != null;
    }

    fn finish(self: *Service) void {
        self.pending.?.deinit();
        self.pending = null;
        self.playback = null;
        self.runtime = null;
        self.failure = null;
    }

    /// True means queued input or consumed requests require another turn.
    /// False allows the runner to sleep for normal native/I/O completions.
    pub fn poll(self: *Service, server: *control.ControlServer, reload: *SourceReload, windows: []const Window) !bool {
        const sent = try self.pollSends(server, reload);
        if (self.pending == null) self.pending = server.takeDevelopmentRequest() orelse return sent;
        const request = &self.pending.?;
        if (!server.developmentPending(request.token) or (self.playback != null and server.reloading)) {
            if (self.playback) |*playback| try playback.cancel(self.runtime.?);
            try self.sendError(server, error.DevelopmentCanceled);
            self.finish();
            return true;
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (self.playback) |*playback| {
            const runtime = self.runtime.?;
            // Avoid touching a deinitialized/reused slot after native close.
            if (!runtime.initialized or !runtime.ready) {
                try self.sendError(server, error.StaleDevelopmentTarget);
                self.finish();
                return true;
            }
            if (runtime.wantsSubmission()) return false;
            if (self.failure) |err| {
                dev.requireSettled(runtime) catch return false;
                try self.sendError(server, err);
                self.finish();
                return true;
            }
            const progress = playback.advance(runtime) catch |err| {
                if (err == error.DevelopmentRuntimeNotSettled) return false;
                self.failure = err;
                try playback.cancel(runtime);
                return true;
            };
            if (progress == .routed) return true;
            const result = try jsonValue(a, .{
                .window = try stringField(arguments(request), "window"),
                .token = try encodeToken(a, dev.Token.current(runtime)),
                .settled = "runnable_tasks_and_backend_submission",
            });
            _ = try server.completeDevelopment(request.token, result, false);
            self.finish();
            return true;
        }
        const result = self.execute(a, server, reload, windows) catch |err| {
            try self.sendError(server, err);
            self.finish();
            return true;
        };
        if (result) |value| {
            _ = try server.completeDevelopment(request.token, value, false);
            self.finish();
        }
        return true;
    }

    fn execute(self: *Service, a: std.mem.Allocator, server: *control.ControlServer, reload: *SourceReload, windows: []const Window) !?mcp.Value {
        const request = &self.pending.?;
        const name = try stringField(request.parameters.value, "name");
        const args = arguments(request);
        if (std.mem.eql(u8, name, "runtime.diagnostics")) {
            const Diagnostic = struct { phase: []const u8, source: []const u8, message: []const u8 };
            const diagnostic: ?Diagnostic = if (reload.lastDiagnostic()) |d|
                .{ .phase = @tagName(d.phase), .source = d.source_name, .message = d.message }
            else
                null;
            const Recording = struct { path: []const u8, inputs: u64, segment: u32, bytes: u64, limit: u64, failed: bool, reason: ?[]const u8 };
            const recording: ?Recording = if (reload.config.recording) |sink|
                .{ .path = sink.location(), .inputs = sink.inputs, .segment = sink.segment, .bytes = sink.bytes, .limit = sink.limit, .failed = sink.failed, .reason = sink.reason() }
            else
                null;
            return try jsonValue(a, .{ .generation = reload.generation, .source = reload.active().snapshot.entry_name, .diagnostic = diagnostic, .recording = recording });
        }
        if (std.mem.eql(u8, name, "runtime.inspect") or std.mem.eql(u8, name, "runtime.metrics")) {
            var list: std.array_list.Managed(mcp.Value) = .init(a);
            const requested = if (mcp.get(args, "window")) |_| try stringField(args, "window") else null;
            for (windows) |window| {
                if (requested) |id| if (!std.mem.eql(u8, id, window.id)) continue;
                const runtime = window.runtime;
                if (std.mem.eql(u8, name, "runtime.metrics")) {
                    try list.append(try jsonValue(a, .{
                        .window = window.id,
                        .metrics = runtime.metrics,
                        .timing_enabled = runtime.measure_phases,
                        .scene_revision = runtime.frame_state.scene_revision,
                        .submitted_revision = runtime.frame_state.submitted_revision,
                        .instances = runtime.instances.activeCount(),
                        .semantic_nodes = runtime.semantics.count(),
                        .scene_commands = runtime.command_count,
                        .shared_paragraphs = runtime.paragraphs.count(),
                    }));
                } else if (requested != null) {
                    var snapshot = try dev.inspect(a, runtime, .{});
                    defer snapshot.deinit();
                    var nodes: std.array_list.Managed(mcp.Value) = .init(a);
                    for (snapshot.nodes) |node| {
                        var value = try jsonValue(a, node);
                        // Semantic hashes must round-trip through JavaScript.
                        try value.object.put(a, "id", mcp.string(try std.fmt.allocPrint(a, "{x}", .{node.id})));
                        try value.object.put(a, "parent", if (node.parent) |id| mcp.string(try std.fmt.allocPrint(a, "{x}", .{id})) else .null);
                        try nodes.append(value);
                    }
                    try list.append(try mcp.object(a, .{
                        .{ "window", mcp.string(window.id) },
                        .{ "token", mcp.string(try encodeToken(a, snapshot.token)) },
                        .{ "nodes", mcp.Value{ .array = nodes } },
                    }));
                } else {
                    try list.append(try jsonValue(a, .{
                        .window = window.id,
                        .handle = runtime.window,
                        .token = try encodeToken(a, dev.Token.current(runtime)),
                        .ready = runtime.ready,
                        .size = runtime.frame_state.size,
                    }));
                }
            }
            if (requested != null and list.items.len == 0) return error.DevelopmentWindowNotFound;
            return try mcp.object(a, .{.{ "windows", mcp.Value{ .array = list } }});
        }
        if (std.mem.eql(u8, name, "runtime.statecharts")) return try statecharts(a, reload, args);
        if (std.mem.eql(u8, name, "runtime.send")) {
            // Delivered by a task in the application VM: send needs the task
            // phase for effects and wait_for. pollSends completes it.
            try self.startSend(a, reload, args);
            return null;
        }
        if (server.reloading) return error.DevelopmentReloadInProgress;
        const id = try stringField(args, "window");
        const runtime = for (windows) |window| {
            if (std.mem.eql(u8, window.id, id)) break window.runtime;
        } else return error.DevelopmentWindowNotFound;
        const token = try decodeToken(try stringField(args, "token"));
        if (std.mem.eql(u8, name, "runtime.input")) {
            const action = try parseAction(args);
            self.playback = if (mcp.get(args, "pin")) |pin| blk: {
                if (pin != .string) return error.InvalidDevelopmentArgument;
                break :blk try dev.Playback.initPinned(runtime, token, action, try dev.Pin.parse(pin.string));
            } else try dev.Playback.init(runtime, token, action);
            self.runtime = runtime;
            return null;
        }
        if (!std.mem.eql(u8, name, "runtime.capture")) return error.UnknownDevelopmentOperation;
        var image = try dev.capture(a, runtime, token);
        defer image.deinit();
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}-{d}.png", .{ server.socketPath(.development).?, request.token }, 0);
        errdefer self.allocator.free(path);
        const file = try std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(self.io);
        const identity = try PathIdentity.read(path);
        errdefer identity.unlink(path);
        try file.writeStreamingAll(self.io, image.png);
        const result = try jsonValue(a, .{ .window = id, .token = try encodeToken(a, token), .kind = image.kind, .path = path, .width = image.width, .height = image.height, .bytes = image.png.len });
        if (self.captures[self.capture_index]) |old| {
            old.identity.unlink(old.path);
            self.allocator.free(old.path);
        }
        self.captures[self.capture_index] = .{ .path = path, .identity = identity };
        self.capture_index = (self.capture_index + 1) % self.captures.len;
        return result;
    }

    /// Validates and spawns a runtime.send, then moves the request out of the
    /// pending slot into `sends`.
    fn startSend(self: *Service, a: std.mem.Allocator, reload: *SourceReload, args: mcp.Value) !void {
        const store = reload.config.statecharts orelse return error.StatechartInspectionUnavailable;
        if (mcp.get(args, "wait")) |wait| if (wait == .object) {
            if (try unsignedField(wait, "timeout_ms", 0) > max_wait_ms) return error.InvalidWaitTimeout;
        };
        const slot = for (&self.sends) |*entry| {
            if (entry.* == null) break entry;
        } else return error.DevelopmentSendCapacityExceeded;
        const bytes = try std.json.Stringify.valueAlloc(a, args, .{});
        const vm = &reload.active().vm;
        const scope = try vm.openScope(vm.scheduler.application_scope);
        errdefer vm.closeScope(scope) catch {};
        const token = try lua.sendStatechartEvent(vm, store, scope, bytes);
        self.statecharts = store;
        slot.* = .{ .request = self.pending.?, .token = token, .scope = scope, .generation = reload.generation };
        self.pending = null;
    }

    /// Completes finished sends and stops cancelled ones (request cancelled,
    /// client gone, or source reloaded). True when any slot changed.
    fn pollSends(self: *Service, server: *control.ControlServer, reload: *SourceReload) !bool {
        var changed = false;
        for (&self.sends) |*entry| if (entry.*) |*send| {
            const store = self.statecharts.?;
            const same_vm = send.generation == reload.generation;
            if (server.developmentPending(send.request.token)) {
                const bytes = store.takeResult(send.token) orelse continue;
                defer self.allocator.free(bytes);
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const value = try std.json.parseFromSliceLeaky(mcp.Value, arena.allocator(), bytes, .{ .allocate = .alloc_always });
                _ = try server.completeDevelopment(send.request.token, value, mcp.get(value, "error") != null);
            } else {
                store.dropResult(send.token);
            }
            // A finished task's scope is empty; a cancelled one's task, wait
            // and observer unwind. A reload already retired the old VM's.
            if (same_vm) reload.active().vm.closeScope(send.scope) catch {};
            send.request.deinit();
            entry.* = null;
            changed = true;
        };
        return changed;
    }

    fn sendError(self: *Service, server: *control.ControlServer, err: anyerror) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const result = try jsonValue(arena.allocator(), .{ .@"error" = .{ .code = @errorName(err), .message = @errorName(err) } });
        _ = try server.completeDevelopment(self.pending.?.token, result, true);
    }
};

const statechart_response_bytes = 2 * 1024 * 1024;

fn unsignedField(args: mcp.Value, name: []const u8, default: u64) !u64 {
    const value = mcp.get(args, name) orelse return default;
    return switch (value) {
        .integer => |n| if (n < 0) error.InvalidDevelopmentArgument else @intCast(n),
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch error.InvalidDevelopmentArgument,
        else => error.InvalidDevelopmentArgument,
    };
}

fn integer(value: u64) mcp.Value {
    return .{ .integer = @intCast(@min(value, std.math.maxInt(i64))) };
}

/// Copies published statechart records out of the host ring. Record bytes
/// were encoded by ouro.json in the application VM; no Lua runs here.
fn statecharts(a: std.mem.Allocator, reload: *SourceReload, args: mcp.Value) !mcp.Value {
    const store = reload.config.statecharts orelse return error.StatechartInspectionUnavailable;
    // The observer exists only while clients keep calling; each call renews
    // it and (re)attaches the active generation, seeding current actors.
    store.keep_alive_ms = @min(try unsignedField(args, "keep_alive_ms", 30_000), 600_000);
    try lua.attachStatechartInspector(&reload.active().vm, store);
    // actor: one live actor's complete current state, read now.
    const snapshot: ?mcp.Value = if (mcp.get(args, "actor") != null) blk: {
        const path = try stringField(args, "actor");
        const bytes = try lua.inspectStatechart(a, &reload.active().vm, path) orelse return error.StatechartActorNotFound;
        break :blk try std.json.parseFromSliceLeaky(mcp.Value, a, bytes, .{ .allocate = .alloc_always });
    } else null;
    // rollup: one summary row per live actor (the visualizer's overview).
    const rollup: ?mcp.Value = if (mcp.get(args, "rollup")) |flag| if (flag == .bool and flag.bool) blk: {
        const bytes = try lua.rollupStatecharts(a, &reload.active().vm) orelse break :blk null;
        break :blk try std.json.parseFromSliceLeaky(mcp.Value, a, bytes, .{ .allocate = .alloc_always });
    } else null else null;
    const after = try unsignedField(args, "after", 0);
    const limit = @min(try unsignedField(args, "limit", 256), 1024);
    // Lua MCP clients convert at most 4096 values per reply; text mode keeps
    // each record as one JSON string for ouro.json.decode.
    const text = if (mcp.get(args, "text")) |value| value == .bool and value.bool else false;
    const Collect = struct {
        a: std.mem.Allocator,
        text: bool,
        list: std.array_list.Managed(mcp.Value),
        bytes: usize = 0,
        last: ?u64 = null,
        fn visit(self: *@This(), entry: lua.StatechartEntry) anyerror!bool {
            if (self.list.items.len != 0 and self.bytes + entry.bytes.len > statechart_response_bytes) return false;
            self.bytes += entry.bytes.len;
            const record: mcp.Value = if (self.text)
                mcp.string(try self.a.dupe(u8, entry.bytes))
            else
                try std.json.parseFromSliceLeaky(mcp.Value, self.a, entry.bytes, .{ .allocate = .alloc_always });
            try self.list.append(try mcp.object(self.a, .{
                .{ "sequence", integer(entry.sequence) },
                .{ "time_ms", integer(entry.time_ms) },
                .{ "record", record },
            }));
            self.last = entry.sequence;
            return true;
        }
    };
    var collect: Collect = .{ .a = a, .text = text, .list = .init(a) };
    _ = try store.each(after, @intCast(limit), &collect, Collect.visit);
    const first = store.firstSequence();
    const next = collect.last orelse @max(after, first -| 1);
    var result = try mcp.object(a, .{
        .{ "next", integer(next) },
        // Records past `next` exist (limit or the byte budget cut the page).
        .{ "more", mcp.Value{ .bool = next + 1 < store.next_sequence } },
        // Changes when the instance restarts on the same socket path; a
        // client then resets its cursor and seed.
        .{ "epoch", integer(store.start_ns) },
        .{ "first", integer(first) },
        .{ "dropped", mcp.Value{ .bool = after + 1 < first and store.next_sequence > 1 } },
        .{ "time_ms", integer(store.elapsedMs()) },
        .{ "seed", integer(store.seed) },
        .{ "reads", integer(store.reads) },
        .{ "records", mcp.Value{ .array = collect.list } },
    });
    // A client passing the seed it last saw gets actors whenever it changed.
    const stale_seed = if (mcp.get(args, "seed") != null) try unsignedField(args, "seed", 0) != store.seed else false;
    const include_actors = stale_seed or if (mcp.get(args, "actors")) |value| value == .bool and value.bool else after == 0;
    if (include_actors) {
        var actors: std.array_list.Managed(mcp.Value) = .init(a);
        const Decode = struct {
            fn value(allocator: std.mem.Allocator, bytes: ?[]u8, as_text: bool) !mcp.Value {
                const owned = bytes orelse return .null;
                if (as_text) return mcp.string(try allocator.dupe(u8, owned));
                return std.json.parseFromSliceLeaky(mcp.Value, allocator, owned, .{ .allocate = .alloc_always });
            }
        };
        for (store.actors.keys(), store.actors.values()) |path, actor| {
            const started = try Decode.value(a, actor.started, text);
            const latest = try Decode.value(a, actor.latest, text);
            try actors.append(try mcp.object(a, .{ .{ "actor", mcp.string(path) }, .{ "started", started }, .{ "latest", latest }, .{ "latest_sequence", integer(actor.latest_sequence) } }));
        }
        try result.object.put(a, "actors", .{ .array = actors });
    }
    if (snapshot) |value| try result.object.put(a, "actor", value);
    if (rollup) |value| try result.object.put(a, "rollup", value);
    return result;
}

fn arguments(request: *const control.DevelopmentRequest) mcp.Value {
    return mcp.get(request.parameters.value, "arguments") orelse .{ .object = .empty };
}

fn jsonValue(a: std.mem.Allocator, value: anytype) !mcp.Value {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    return std.json.parseFromSliceLeaky(mcp.Value, a, bytes, .{ .allocate = .alloc_always });
}

fn stringField(value: mcp.Value, name: []const u8) ![]const u8 {
    const field = mcp.get(value, name) orelse return error.MissingDevelopmentArgument;
    return if (field == .string) field.string else error.InvalidDevelopmentArgument;
}

fn modifier(args: mcp.Value, name: []const u8) bool {
    const value = mcp.get(args, name) orelse return false;
    return value == .bool and value.bool;
}

pub fn parseAction(args: mcp.Value) !dev.Action {
    const action = try stringField(args, "action");
    if (std.mem.eql(u8, action, "click")) return .{ .click = try stringField(args, "target") };
    if (std.mem.eql(u8, action, "hover")) return .{ .hover = try stringField(args, "target") };
    if (std.mem.eql(u8, action, "pointer_down")) return .{ .pointer_down = try stringField(args, "target") };
    if (std.mem.eql(u8, action, "pointer_move")) return .{ .pointer_move = try stringField(args, "target") };
    if (std.mem.eql(u8, action, "pointer_up")) return .pointer_up;
    if (std.mem.eql(u8, action, "text")) return .{ .text = try stringField(args, "text") };
    if (std.mem.eql(u8, action, "scroll")) {
        const number = mcp.get(args, "delta") orelse return error.MissingDevelopmentArgument;
        const delta: f32 = switch (number) {
            .number_string => |s| try std.fmt.parseFloat(f32, s),
            .integer => |n| @floatFromInt(n),
            .float => |n| @floatCast(n),
            else => return error.InvalidDevelopmentArgument,
        };
        return .{ .scroll = .{ .target = try stringField(args, "target"), .delta = delta } };
    }
    if (!std.mem.eql(u8, action, "key")) return error.InvalidDevelopmentAction;
    const key = try stringField(args, "key");
    var buffer: [16]u8 = undefined;
    const normalized = if (key.len == 1 and std.ascii.isAlphabetic(key[0]))
        try std.fmt.bufPrint(&buffer, "key_{s}", .{key})
    else
        key;
    const logical = std.meta.stringToEnum(platform.LogicalKey, normalized) orelse return error.InvalidDevelopmentKey;
    if (logical == .unidentified) return error.InvalidDevelopmentKey;
    return .{ .key = .{ .keycode = 0, .logical = logical, .modifiers = .{
        .shift = modifier(args, "shift"),
        .control = modifier(args, "control"),
        .alt = modifier(args, "alt"),
        .logo = modifier(args, "logo"),
    } } };
}

fn encodeToken(a: std.mem.Allocator, token: dev.Token) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}:{d}:{d}:{d}:{d}", .{ token.window.slot, token.window.generation, token.generation, token.revision, token.scene_revision });
}

fn decodeToken(value: []const u8) !dev.Token {
    var parts = std.mem.splitScalar(u8, value, ':');
    var numbers: [5]u64 = undefined;
    for (&numbers) |*n| n.* = std.fmt.parseUnsigned(u64, parts.next() orelse return error.InvalidDevelopmentToken, 10) catch return error.InvalidDevelopmentToken;
    if (parts.next() != null or numbers[0] > std.math.maxInt(u32) or numbers[1] > std.math.maxInt(u32)) return error.InvalidDevelopmentToken;
    return .{ .window = .{ .slot = @intCast(numbers[0]), .generation = @intCast(numbers[1]) }, .generation = numbers[2], .revision = numbers[3], .scene_revision = numbers[4] };
}

test "development wire tokens preserve large revisions and reject malformed handles" {
    const token: dev.Token = .{ .window = .{ .slot = 9, .generation = 31 }, .generation = 9007199254740993, .revision = 57, .scene_revision = 109 };
    const encoded = try encodeToken(std.testing.allocator, token);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualDeep(token, try decodeToken(encoded));
    try std.testing.expectError(error.InvalidDevelopmentToken, decodeToken("4294967296:1:2:3:4"));
    try std.testing.expectError(error.InvalidDevelopmentToken, decodeToken("1:2:3:4:5:6"));
    var doc = try std.json.parseFromSlice(mcp.Value, std.testing.allocator, tools, .{});
    defer doc.deinit();
    for (doc.value.array.items) |tool| {
        try mcp.schema.check(mcp.get(tool, "inputSchema").?);
        try mcp.schema.check(mcp.get(tool, "outputSchema").?);
    }
}
