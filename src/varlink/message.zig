const std = @import("std");

pub const Value = std.json.Value;

pub const Config = struct {
    max_message_bytes: usize = 1024 * 1024,
    max_pending_calls: usize = 32,
    max_events: usize = 32,
    max_transmits: usize = 32,
    max_buffered_replies: usize = 64,
};

pub const CallHandle = struct {
    value: u64,
};

pub const AfterSend = enum {
    none,
    upgrade,
};

/// One complete serialized record. Ownership transfers from the protocol
/// state machine to the asynchronous transport, which may retain `bytes` and
/// advance `offset` across any number of short writes.
pub const Transmit = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    offset: usize = 0,
    after_send: AfterSend = .none,

    pub fn remaining(self: *const Transmit) []const u8 {
        return self.bytes[self.offset..];
    }

    pub fn consume(self: *Transmit, count: usize) !void {
        if (count > self.bytes.len - self.offset) return error.InvalidTransmitCount;
        self.offset += count;
    }

    pub fn complete(self: *const Transmit) bool {
        return self.offset == self.bytes.len;
    }

    pub fn deinit(self: *Transmit) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const OutgoingCall = struct {
    method: []const u8,
    parameters: ?Value = null,
    oneway: bool = false,
    more: bool = false,
    upgrade: bool = false,
};

pub const Request = struct {
    document: std.json.Parsed(Value),
    method: []const u8,
    parameters: ?Value,
    oneway: bool,
    more: bool,
    upgrade: bool,

    pub fn deinit(self: *Request) void {
        self.document.deinit();
        self.* = undefined;
    }
};

pub const Reply = struct {
    document: std.json.Parsed(Value),
    parameters: ?Value,
    error_name: ?[]const u8,
    continues: bool,

    pub fn deinit(self: *Reply) void {
        self.document.deinit();
        self.* = undefined;
    }
};

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !Request {
    if (bytes.len == 0) return error.EmptyMessage;
    var document = std.json.parseFromSlice(Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidJson,
    };
    errdefer document.deinit();
    const object = switch (document.value) {
        .object => |value| value,
        else => return error.InvalidEnvelope,
    };
    const method = try requiredString(object.get("method"));
    if (method.len == 0) return error.InvalidMethod;
    return .{
        .document = document,
        .method = method,
        .parameters = try optionalParameters(object.get("parameters")),
        .oneway = try optionalBool(object.get("oneway")),
        .more = try optionalBool(object.get("more")),
        .upgrade = try optionalBool(object.get("upgrade")),
    };
}

pub fn parseReply(allocator: std.mem.Allocator, bytes: []const u8) !Reply {
    if (bytes.len == 0) return error.EmptyMessage;
    var document = std.json.parseFromSlice(Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidJson,
    };
    errdefer document.deinit();
    const object = switch (document.value) {
        .object => |value| value,
        else => return error.InvalidEnvelope,
    };
    const error_name = try optionalString(object.get("error"));
    const continues = try optionalBool(object.get("continues"));
    if (error_name != null and continues) return error.ErrorCannotContinue;
    return .{
        .document = document,
        .parameters = try optionalParameters(object.get("parameters")),
        .error_name = error_name,
        .continues = continues,
    };
}

pub fn serializeCall(allocator: std.mem.Allocator, call: OutgoingCall) !Transmit {
    if (call.method.len == 0) return error.InvalidMethod;
    if ((call.oneway and (call.more or call.upgrade)) or (call.more and call.upgrade))
        return error.IncompatibleCallFlags;
    try validateParameters(call.parameters);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("method");
    try json.write(call.method);
    if (call.parameters) |parameters| {
        try json.objectField("parameters");
        try json.write(parameters);
    }
    if (call.oneway) {
        try json.objectField("oneway");
        try json.write(true);
    }
    if (call.more) {
        try json.objectField("more");
        try json.write(true);
    }
    if (call.upgrade) {
        try json.objectField("upgrade");
        try json.write(true);
    }
    try json.endObject();
    try output.writer.writeByte(0);
    return .{ .allocator = allocator, .bytes = try output.toOwnedSlice() };
}

pub fn serializeReply(
    allocator: std.mem.Allocator,
    parameters: ?Value,
    error_name: ?[]const u8,
    continues: bool,
    after_send: AfterSend,
) !Transmit {
    try validateParameters(parameters);
    if (error_name) |name| if (name.len == 0) return error.InvalidErrorName;
    if (error_name != null and continues) return error.ErrorCannotContinue;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    if (parameters) |value| {
        try json.objectField("parameters");
        try json.write(value);
    }
    if (continues) {
        try json.objectField("continues");
        try json.write(true);
    }
    if (error_name) |name| {
        try json.objectField("error");
        try json.write(name);
    }
    try json.endObject();
    try output.writer.writeByte(0);
    return .{
        .allocator = allocator,
        .bytes = try output.toOwnedSlice(),
        .after_send = after_send,
    };
}

fn validateParameters(parameters: ?Value) !void {
    if (parameters) |value| switch (value) {
        .object => {},
        else => return error.ParametersMustBeObject,
    };
}

fn requiredString(value: ?Value) ![]const u8 {
    return switch (value orelse return error.MissingRequiredField) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn optionalString(value: ?Value) !?[]const u8 {
    return switch (value orelse return null) {
        .null => null,
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn optionalBool(value: ?Value) !bool {
    return switch (value orelse return false) {
        .null => false,
        .bool => |flag| flag,
        else => error.InvalidFieldType,
    };
}

fn optionalParameters(value: ?Value) !?Value {
    return switch (value orelse return null) {
        .null => null,
        .object => |object| Value{ .object = object },
        else => error.ParametersMustBeObject,
    };
}

test "message envelopes round-trip owned JSON and flags" {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(std.testing.allocator);
    try parameters.put(std.testing.allocator, "number", .{ .integer = 7 });
    var transmit = try serializeCall(std.testing.allocator, .{
        .method = "org.example.Test",
        .parameters = .{ .object = parameters },
        .more = true,
    });
    defer transmit.deinit();
    var request = try parseRequest(std.testing.allocator, transmit.bytes[0 .. transmit.bytes.len - 1]);
    defer request.deinit();
    try std.testing.expectEqualStrings("org.example.Test", request.method);
    try std.testing.expect(request.more);
    try std.testing.expectEqualStrings(
        "7",
        request.parameters.?.object.get("number").?.number_string,
    );
}

test "message parser rejects malformed envelopes" {
    try std.testing.expectError(error.EmptyMessage, parseReply(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidEnvelope, parseReply(std.testing.allocator, "[]"));
    try std.testing.expectError(
        error.ParametersMustBeObject,
        parseRequest(std.testing.allocator, "{\"method\":\"x\",\"parameters\":7}"),
    );
    try std.testing.expectError(
        error.ErrorCannotContinue,
        parseReply(std.testing.allocator, "{\"error\":\"org.example.No\",\"continues\":true}"),
    );
    try std.testing.expectError(
        error.IncompatibleCallFlags,
        serializeCall(std.testing.allocator, .{
            .method = "org.example.Upgrade",
            .more = true,
            .upgrade = true,
        }),
    );
}
