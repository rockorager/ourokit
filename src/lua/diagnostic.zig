const std = @import("std");
const c = @import("c.zig");

pub const Phase = enum {
    source,
    setup,
    compile,
    evaluate,
    declaration,
};

/// Owned structured failure from preparing one source generation.
pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    phase: Phase,
    source_name: []u8,
    message: []u8,

    pub fn fromError(
        allocator: std.mem.Allocator,
        phase: Phase,
        source_name: []const u8,
        err: anyerror,
    ) !Diagnostic {
        return init(allocator, phase, source_name, @errorName(err));
    }

    pub fn fromLuaStack(
        allocator: std.mem.Allocator,
        phase: Phase,
        source_name: []const u8,
        state: *c.State,
    ) !Diagnostic {
        var length: usize = 0;
        const pointer = c.lua_tolstring(state, -1, &length);
        const message = if (pointer) |value| value[0..length] else "unknown Lua error";
        return init(allocator, phase, source_name, message);
    }

    fn init(
        allocator: std.mem.Allocator,
        phase: Phase,
        source_name: []const u8,
        message: []const u8,
    ) !Diagnostic {
        const owned_source = try allocator.dupe(u8, source_name);
        errdefer allocator.free(owned_source);
        return .{
            .allocator = allocator,
            .phase = phase,
            .source_name = owned_source,
            .message = try allocator.dupe(u8, message),
        };
    }

    pub fn deinit(self: *Diagnostic) void {
        self.allocator.free(self.message);
        self.allocator.free(self.source_name);
        self.* = undefined;
    }
};

pub fn recordError(
    output: ?*?Diagnostic,
    allocator: std.mem.Allocator,
    phase: Phase,
    source_name: []const u8,
    err: anyerror,
) void {
    const destination = output orelse return;
    if (destination.* != null) return;
    destination.* = Diagnostic.fromError(allocator, phase, source_name, err) catch null;
}

pub fn recordLuaStack(
    output: ?*?Diagnostic,
    allocator: std.mem.Allocator,
    phase: Phase,
    source_name: []const u8,
    state: *c.State,
) void {
    const destination = output orelse return;
    if (destination.* != null) return;
    destination.* = Diagnostic.fromLuaStack(
        allocator,
        phase,
        source_name,
        state,
    ) catch null;
}
