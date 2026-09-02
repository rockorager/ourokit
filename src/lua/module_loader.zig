const std = @import("std");
const bundle = @import("../bundle/root.zig");
const fs = @import("../fs/root.zig");
const io = @import("../loop/root.zig");
const task = @import("../task/root.zig");
const application = @import("application.zig");
const c = @import("c.zig");
const vm_module = @import("vm.zig");

const max_module_bytes = 16 * 1024 * 1024;

const State = enum {
    free,
    reading_file,
    reading_init,
    ready,
    evaluating,
    loaded,
};

const Slot = struct {
    loader: *ModuleLoader = undefined,
    state: State = .free,
    paths: ?bundle.module_name.Paths = null,
    read: fs.ReadHandle = .invalid,
    task: vm_module.TaskHandle = .invalid,
    contents: ?fs.Contents = null,
    failure: ?anyerror = null,
    cache_reference: c_int = c.no_reference,
    cancellation_requested: bool = false,
    used_init_path: bool = false,
};

/// Generation-owned `require` implementation. A cache miss parks the current
/// Lua coroutine on a scoped file-read resource. File CQEs only advance the
/// reader and mark that coroutine runnable; module code runs in task phase.
pub const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    vm: *vm_module.Vm,
    directory: std.os.linux.fd_t,
    reader: fs.Reader,
    slots: []Slot,
    frozen: bool = false,

    pub fn init(
        self: *ModuleLoader,
        allocator: std.mem.Allocator,
        vm: *vm_module.Vm,
        loop: *io.Loop,
        directory: std.os.linux.fd_t,
        capacity: usize,
    ) !void {
        if (capacity == 0) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        self.* = .{
            .allocator = allocator,
            .vm = vm,
            .directory = directory,
            .reader = undefined,
            .slots = slots,
        };
        try self.reader.init(allocator, loop, capacity);
        for (self.slots) |*slot| slot.loader = self;

        c.lua_pushlightuserdata(vm.state, self);
        c.lua_pushcclosure(vm.state, require, 1);
        c.lua_setglobal(vm.state, "require");
    }

    pub fn deinit(self: *ModuleLoader) void {
        for (self.slots) |*slot| {
            std.debug.assert(slot.state == .free or slot.state == .loaded);
            self.release(slot);
        }
        self.reader.deinit();
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Closes the generation's source closure after entry evaluation. Cached
    /// modules remain available; later first-time imports are rejected.
    pub fn freeze(self: *ModuleLoader) void {
        self.frozen = true;
    }

    /// Returns false when the file completion belongs to another reader.
    /// This transition may prepare a follow-up SQE but never submits or enters
    /// Lua. The caller owns submission at the end of the current turn.
    pub fn dispatch(self: *ModuleLoader, completion: io.FileCompletion) !bool {
        if (!(try self.reader.dispatch(completion))) return false;
        for (self.slots) |*slot| {
            if (slot.state != .reading_file and slot.state != .reading_init) continue;
            if (!(try self.reader.finished(slot.read))) continue;
            const contents = self.reader.take(slot.read) catch |err| {
                if (err == error.FileNotFound and slot.state == .reading_file and
                    !slot.cancellation_requested)
                {
                    slot.read = try self.reader.startAt(
                        self.directory,
                        slot.paths.?.init,
                        .{ .max_bytes = max_module_bytes },
                    );
                    slot.state = .reading_init;
                    return true;
                }
                slot.failure = err;
                slot.state = .ready;
                try self.finishWait(slot);
                return true;
            };
            slot.contents = contents.?;
            slot.used_init_path = slot.state == .reading_init;
            slot.state = .ready;
            try self.finishWait(slot);
            return true;
        }
        return true;
    }

    fn finishWait(self: *ModuleLoader, slot: *Slot) !void {
        try self.vm.markExternalCompleted(slot.task);
        if (slot.cancellation_requested) self.release(slot);
    }

    fn require(state: *c.State) callconv(.c) c_int {
        const self = loaderFromUpvalue(state) orelse
            return luaError(state, "missing Ouro module loader");
        if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_string)
            return luaError(state, "require expects one module name");
        var name_len: usize = 0;
        const name_pointer = c.lua_tolstring(state, 1, &name_len) orelse
            return luaError(state, "require expects one module name");
        const name = name_pointer[0..name_len];
        if (std.mem.eql(u8, name, "ouro")) {
            self.vm.pushApi(state);
            return 1;
        }

        for (self.slots) |*slot| {
            if (slot.state == .free or !std.mem.eql(u8, slot.paths.?.canonical, name)) continue;
            if (slot.state == .loaded) {
                _ = c.lua_rawgeti(state, c.registry_index, slot.cache_reference);
                return 1;
            }
            return luaError(state, "module is already being loaded");
        }
        if (self.frozen)
            return luaError(state, "module was not loaded during application bootstrap");

        const slot = self.available() orelse
            return luaError(state, "module capacity exceeded");
        slot.paths = bundle.module_name.paths(self.allocator, name) catch
            return luaError(state, "invalid module name");
        slot.state = .reading_file;
        slot.task = self.vm.beginExternalWait(
            state,
            .operation,
            slot,
            &resource_lifecycle,
        ) catch {
            self.release(slot);
            return luaError(state, "could not park module load");
        };
        slot.read = self.reader.startAt(
            self.directory,
            slot.paths.?.file,
            .{ .max_bytes = max_module_bytes },
        ) catch {
            self.vm.abortExternalWait(state, slot.task) catch unreachable;
            self.release(slot);
            return luaError(state, "could not start module read");
        };
        return c.lua_yieldk(state, 0, contextFor(slot), loadContinuation);
    }

    fn loadContinuation(state: *c.State, _: c_int, context: c.KContext) callconv(.c) c_int {
        const slot = slotFromContext(context);
        if (slot.failure != null) {
            slot.loader.release(slot);
            return luaError(state, "module source could not be read");
        }
        const contents = &slot.contents.?;
        const selected_path = if (slot.used_init_path) slot.paths.?.init else slot.paths.?.file;
        const chunk_name = chunkName(slot.loader.allocator, selected_path) catch {
            slot.loader.release(slot);
            return luaError(state, "module chunk name allocation failed");
        };
        const load_status = c.luaL_loadbufferx(
            state,
            contents.bytes().ptr,
            contents.bytes().len,
            chunk_name,
            null,
        );
        slot.loader.allocator.free(chunk_name);
        if (load_status != c.ok) {
            slot.loader.release(slot);
            return c.lua_error(state);
        }
        slot.state = .evaluating;
        const status = c.lua_pcallk(state, 0, 1, 0, context, moduleContinuation);
        if (status != c.ok) {
            slot.loader.release(slot);
            return c.lua_error(state);
        }
        return finishModule(state, slot);
    }

    fn moduleContinuation(state: *c.State, status: c_int, context: c.KContext) callconv(.c) c_int {
        const slot = slotFromContext(context);
        if (status != c.ok and status != c.yield) {
            slot.loader.release(slot);
            return c.lua_error(state);
        }
        return finishModule(state, slot);
    }

    fn finishModule(state: *c.State, slot: *Slot) c_int {
        if (c.lua_type(state, -1) == c.type_nil) {
            c.lua_settop(state, -2);
            c.lua_pushboolean(state, 1);
        }
        c.lua_pushvalue(state, -1);
        slot.cache_reference = c.luaL_ref(state, c.registry_index);
        slot.state = .loaded;
        return 1;
    }

    fn available(self: *ModuleLoader) ?*Slot {
        for (self.slots) |*slot| if (slot.state == .free) return slot;
        return null;
    }

    fn release(self: *ModuleLoader, slot: *Slot) void {
        if (slot.cache_reference != c.no_reference)
            c.luaL_unref(self.vm.state, c.registry_index, slot.cache_reference);
        if (slot.contents) |*contents| contents.deinit();
        if (slot.paths) |*paths| paths.deinit();
        slot.* = .{ .loader = self };
    }
};

fn loaderFromUpvalue(state: *c.State) ?*ModuleLoader {
    const pointer = c.lua_touserdata(state, c.upvalueIndex(1)) orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn contextFor(slot: *Slot) c.KContext {
    return @bitCast(@as(usize, @intFromPtr(slot)));
}

fn slotFromContext(context: c.KContext) *Slot {
    return @ptrFromInt(@as(usize, @bitCast(context)));
}

fn chunkName(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, path.len + 1, 0);
    result[0] = '@';
    @memcpy(result[1..], path);
    return result;
}

fn requestCancel(pointer: *anyopaque) !void {
    const slot: *Slot = @ptrCast(@alignCast(pointer));
    slot.cancellation_requested = true;
    try slot.loader.reader.cancel(slot.read);
}

fn destroyResource(_: *anyopaque) void {}

const resource_lifecycle: task.ResourceLifecycle = .{
    .request_cancel = requestCancel,
    .destroy = destroyResource,
};

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "application bootstrap asynchronously loads fallback and nested modules" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "model");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "model/init.lua",
        .data = "return require('answer')",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "answer.lua",
        .data = "return 42",
    });

    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 32, 16);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 1, 2, 4);
    defer scheduler.deinit();
    var vm: vm_module.Vm = undefined;
    try vm.init(std.testing.allocator, &scheduler, &loop);
    defer vm.deinit();
    var loader: ModuleLoader = undefined;
    try loader.init(
        std.testing.allocator,
        &vm,
        &loop,
        temporary.dir.handle,
        4,
    );
    defer loader.deinit();

    var bootstrap = try application.Bootstrap.start(
        std.testing.allocator,
        &vm,
        scheduler.application_scope,
        "local ouro = require('ouro'); " ++
            "local first = require('model'); local second = require('model'); " ++
            "return ouro.app { id = 'dev.ouro.bootstrap-test', windows = { " ++
            "ouro.window { id = 'main', title = first == 42 and first == second " ++
            "and 'Loaded' or 'Wrong', content = function() end } } }",
        "@app.lua",
    );
    var completed = false;
    while (!completed) {
        while (scheduler.takeRunnable()) |runnable| {
            completed = try vm.resumeRunnable(runnable) == .completed;
        }
        if (completed) break;
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| try std.testing.expect(try loader.dispatch(completion)),
            .operation_cancel => {},
            else => return error.UnexpectedCompletion,
        }
    }
    var result = try bootstrap.take();
    defer result.deinit();
    try std.testing.expectEqualStrings("dev.ouro.bootstrap-test", result.id);
    try std.testing.expectEqualStrings("Loaded", result.windows[0].declaration.toplevel.title);
}
