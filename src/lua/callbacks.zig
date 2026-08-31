const std = @import("std");
const c = @import("c.zig");
const Handle = @import("../core/handle.zig").Handle;
const task = @import("../task/scheduler.zig");
const Vm = @import("vm.zig").Vm;
const Argument = @import("vm.zig").Argument;

pub const CallbackHandle = Handle;

const Slot = struct {
    generation: u32 = 0,
    active: bool = false,
    vm: ?*Vm = null,
    reference: c_int = c.no_reference,
};

/// Process-lifetime directory for Lua callbacks retained by native UI state.
/// UI bindings store only generation-checked handles; this registry owns the
/// corresponding Lua registry references and routes invocation to the VM that
/// created them, including while that VM is retiring.
pub const CallbackRegistry = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,

    pub fn init(
        self: *CallbackRegistry,
        allocator: std.mem.Allocator,
        capacity: usize,
    ) !void {
        if (capacity == 0 or capacity > std.math.maxInt(u32)) return error.InvalidCapacity;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        self.* = .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *CallbackRegistry) void {
        for (self.slots) |slot| std.debug.assert(!slot.active);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Transfers ownership of an existing Lua registry reference. Callers
    /// must preflight `availableCapacity` when adoption is part of a larger
    /// infallible commit.
    pub fn adoptReference(
        self: *CallbackRegistry,
        vm: *Vm,
        reference: c_int,
    ) !CallbackHandle {
        for (self.slots, 0..) |*slot, index| if (!slot.active) {
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.active = true;
            slot.vm = vm;
            slot.reference = reference;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return error.CallbackCapacityExceeded;
    }

    pub fn release(self: *CallbackRegistry, handle: CallbackHandle) !void {
        const slot = try self.activeSlot(handle);
        const vm = slot.vm.?;
        const reference = slot.reference;
        slot.active = false;
        slot.vm = null;
        slot.reference = c.no_reference;
        c.luaL_unref(vm.state, c.registry_index, reference);
    }

    pub fn spawn(
        self: *CallbackRegistry,
        handle: CallbackHandle,
        scope: task.ScopeHandle,
        arguments: []const Argument,
    ) !@import("vm.zig").TaskHandle {
        const slot = try self.activeSlot(handle);
        return slot.vm.?.spawnReference(scope, slot.reference, arguments);
    }

    pub fn availableCapacity(self: *const CallbackRegistry) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (!slot.active) {
            count += 1;
        };
        return count;
    }

    /// Performs any allocation before a caller begins an otherwise
    /// infallible callback replacement commit.
    pub fn ensureAvailable(self: *CallbackRegistry, required: usize) !void {
        const available = self.availableCapacity();
        if (required <= available) return;
        const additional = required - available;
        const old_len = self.slots.len;
        const new_len = std.math.add(usize, old_len, additional) catch
            return error.CallbackCapacityExceeded;
        if (new_len > std.math.maxInt(u32)) return error.CallbackCapacityExceeded;
        self.slots = try self.allocator.realloc(self.slots, new_len);
        @memset(self.slots[old_len..], .{});
    }

    pub fn countForVm(self: *const CallbackRegistry, vm: *const Vm) usize {
        var count: usize = 0;
        for (self.slots) |slot| if (slot.active and slot.vm.? == vm) {
            count += 1;
        };
        return count;
    }

    fn activeSlot(self: *CallbackRegistry, handle: CallbackHandle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleCallback;
        const slot = &self.slots[handle.slot];
        if (!slot.active or slot.generation != handle.generation)
            return error.StaleCallback;
        return slot;
    }
};

test "callback handles route identical Lua references to their owning VMs" {
    const io = @import("../loop/io_uring.zig");

    var loop: io.Loop = undefined;
    try loop.init(std.testing.allocator, 8, 2);
    defer loop.deinit();
    var scheduler: task.Scheduler = undefined;
    try scheduler.init(std.testing.allocator, 2, 2, 0);
    defer scheduler.deinit();
    var first: Vm = undefined;
    try first.init(std.testing.allocator, &scheduler, &loop);
    defer first.deinit();
    var second: Vm = undefined;
    try second.init(std.testing.allocator, &scheduler, &loop);
    defer second.deinit();
    var callbacks: CallbackRegistry = undefined;
    try callbacks.init(std.testing.allocator, 2);
    defer callbacks.deinit();

    const first_reference = try installCallback(first.state, "first_called");
    const second_reference = try installCallback(second.state, "second_called");
    try std.testing.expectEqual(first_reference, second_reference);
    const first_handle = try callbacks.adoptReference(&first, first_reference);
    const second_handle = try callbacks.adoptReference(&second, second_reference);
    _ = try callbacks.spawn(first_handle, scheduler.application_scope, &.{});
    _ = try callbacks.spawn(second_handle, scheduler.application_scope, &.{});

    while (scheduler.takeRunnable()) |handle| {
        if (first.ownsSchedulerTask(handle)) {
            _ = try first.resumeRunnable(handle);
        } else if (second.ownsSchedulerTask(handle)) {
            _ = try second.resumeRunnable(handle);
        } else return error.UnownedTask;
    }
    try std.testing.expect(first.globalBoolean("first_called"));
    try std.testing.expect(second.globalBoolean("second_called"));

    try callbacks.release(first_handle);
    try callbacks.release(second_handle);
    try std.testing.expectError(error.StaleCallback, callbacks.release(first_handle));
}

fn installCallback(state: *c.State, global: [*:0]const u8) !c_int {
    const source = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "return function() {s} = true end",
        .{std.mem.span(global)},
        0,
    );
    defer std.testing.allocator.free(source);
    if (c.luaL_loadbufferx(state, source.ptr, source.len, "@callback-test", null) != c.ok)
        return error.LuaLoadFailed;
    if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok) return error.LuaChunkFailed;
    return c.luaL_ref(state, c.registry_index);
}
