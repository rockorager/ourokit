//! The common tool catalog for live discovery and packaging. Returned JSON is
//! owned by the caller, bounded to 256 KiB, and deterministic. Object keys and
//! tools are sorted; arrays inside schemas/data preserve declaration order.
const std = @import("std");
const lua = @import("../lua/root.zig");
const mcp = @import("../mcp/root.zig");

pub const max_bytes = 256 * 1024;
pub const builtin_tools =
    \\[
    \\{"name":"runtime.status","description":"Read application status without activating UI.","inputSchema":{"type":"object","additionalProperties":false},"outputSchema":{"type":"object","properties":{"applicationId":{"type":"string"},"activeGeneration":{"type":"integer"},"reloading":{"type":"boolean"},"uiActive":{"type":"boolean"},"diagnostic":{"type":["object","null"]}},"required":["applicationId","activeGeneration","reloading","uiActive","diagnostic"],"additionalProperties":false}},
    \\{"name":"runtime.reload","description":"Validate a candidate source generation and commit it atomically; resets Lua state.","inputSchema":{"type":"object","additionalProperties":false},"outputSchema":{"type":"object","properties":{"generation":{"type":"integer"}},"required":["generation"],"additionalProperties":false}},
    \\{"name":"runtime.activate","description":"Initialize or present the application UI. Focus remains compositor policy.","inputSchema":{"type":"object","properties":{"activationToken":{"type":["string","null"]}},"additionalProperties":false},"outputSchema":{"type":"object","additionalProperties":false}}
    \\]
;
const failure_schema =
    \\{"type":"object","properties":{"error":{"type":"object","properties":{"code":{"type":"string"},"message":{"type":"string"},"parameters":{}},"required":["code","message"],"additionalProperties":false}},"required":["error"],"additionalProperties":false}
;

pub fn descriptor(allocator: std.mem.Allocator, application: *const lua.Application) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "ourokit/apps/{s}", .{application.id});
    return serialize(allocator, try descriptorValue(a, application.id, path, try toolsValue(a, application)));
}

pub fn tools(allocator: std.mem.Allocator, application: ?*const lua.Application) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    return serialize(allocator, try toolsValue(arena.allocator(), application));
}

/// Shared with runtime publication, whose endpoint reflects the actual socket.
pub fn descriptorValue(a: std.mem.Allocator, id: []const u8, path: []const u8, list: mcp.Value) !mcp.Value {
    if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return error.InvalidApplicationId;
    for (id) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return error.InvalidApplicationId;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidRuntimePath;
    return mcp.object(a, .{
        .{ "schema_version", mcp.Value{ .integer = 1 } },
        .{ "application_id", mcp.string(id) },
        .{ "endpoint", try mcp.object(a, .{.{ "runtime_path", mcp.string(path) }}) },
        .{ "tools", list },
    });
}

fn toolsValue(a: std.mem.Allocator, application: ?*const lua.Application) !mcp.Value {
    const builtins = try std.json.parseFromSlice(mcp.Value, a, builtin_tools, .{});
    const failure = try std.json.parseFromSlice(mcp.Value, a, failure_schema, .{});
    var list = std.array_list.Managed(mcp.Value).init(a);
    try list.appendSlice(builtins.value.array.items);
    if (application) |app| if (app.action_schema) |schema| {
        var it = schema.tools.iterator();
        while (it.next()) |entry| try list.append(entry.value_ptr.*);
    };
    // Declarations describe success; all tools can also fail at execution time.
    for (list.items) |*tool| {
        var copy = try mcp.object(a, .{});
        var it = tool.object.iterator();
        while (it.next()) |entry| try copy.object.put(a, entry.key_ptr.*, entry.value_ptr.*);
        var choices = std.array_list.Managed(mcp.Value).init(a);
        try choices.append(mcp.get(copy, "outputSchema").?);
        try choices.append(failure.value);
        try copy.object.put(a, "outputSchema", try mcp.object(a, .{ .{ "type", mcp.string("object") }, .{ "anyOf", mcp.Value{ .array = choices } } }));
        tool.* = copy;
    }
    std.mem.sort(mcp.Value, list.items, {}, struct {
        fn less(_: void, left: mcp.Value, right: mcp.Value) bool {
            return std.mem.lessThan(u8, mcp.get(left, "name").?.string, mcp.get(right, "name").?.string);
        }
    }.less);
    for (list.items, 0..) |tool, index| if (index != 0 and mcp.isString(mcp.get(list.items[index - 1], "name"), mcp.get(tool, "name").?.string)) return error.DuplicateToolName;
    return .{ .array = list };
}

pub fn serialize(allocator: std.mem.Allocator, value: mcp.Value) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const sorted = try canonical(arena.allocator(), value);
    const buffer = try allocator.alloc(u8, max_bytes);
    defer allocator.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(sorted, .{}, &writer) catch return error.CatalogTooLarge;
    return allocator.dupe(u8, writer.buffered());
}

fn canonical(a: std.mem.Allocator, value: mcp.Value) (std.mem.Allocator.Error || error{InvalidUtf8})!mcp.Value {
    switch (value) {
        .object => |object| {
            const keys = try a.dupe([]const u8, object.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, l: []const u8, r: []const u8) bool {
                    return std.mem.lessThan(u8, l, r);
                }
            }.less);
            var sorted = try mcp.object(a, .{});
            for (keys) |key| {
                if (!std.unicode.utf8ValidateSlice(key)) return error.InvalidUtf8;
                try sorted.object.put(a, key, try canonical(a, object.get(key).?));
            }
            return sorted;
        },
        .array => |array| {
            var sorted = std.array_list.Managed(mcp.Value).init(a);
            for (array.items) |item| try sorted.append(try canonical(a, item));
            return .{ .array = sorted };
        },
        .string => |text| {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
            return value;
        },
        else => return value,
    }
}

test "catalog canonical JSON preserves arrays and numeric lexemes" {
    const a = std.testing.allocator;
    var doc = try std.json.parseFromSlice(mcp.Value, a, "{\"z\":[{\"b\":1,\"a\":2},null,1.0000000000000000000000000000001],\"a\":false}", .{ .parse_numbers = false });
    defer doc.deinit();
    const bytes = try serialize(a, doc.value);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{\"a\":false,\"z\":[{\"a\":2,\"b\":1},null,1.0000000000000000000000000000001]}", bytes);
    const oversized = try a.alloc(u8, max_bytes);
    defer a.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.CatalogTooLarge, serialize(a, mcp.string(oversized)));
    try std.testing.expectError(error.InvalidUtf8, serialize(a, mcp.string("\xff")));
}
