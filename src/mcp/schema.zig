//! Deliberately closed JSON Schema subset. Declaration validation rejects every
//! unsupported keyword (including $ref, formats and numeric/string constraints).
//! Supported: type (single or array), properties, required, additionalProperties
//! (boolean or schema), items, enum, anyOf, title, description, and boolean schemas.
//! Nesting is bounded to 64. Integer means a mathematically integral JSON number.
//! Decimal comparisons are exact; exponent/scale values outside i64 are rejected
//! by numeric constraints rather than rounded. validate requires check first.
const std = @import("std");
const Value = std.json.Value;
const Error = error{ InvalidSchema, UnsupportedSchemaKeyword, SchemaTooDeep };

pub fn check(schema: Value) Error!void {
    try checkAt(schema, 0);
}
fn knownType(name: []const u8) bool {
    inline for (.{ "object", "array", "string", "number", "integer", "boolean", "null" }) |t| if (std.mem.eql(u8, name, t)) return true;
    return false;
}
fn checkAt(s: Value, depth: usize) Error!void {
    if (depth > 64) return error.SchemaTooDeep;
    if (s == .bool) return;
    if (s != .object) return error.InvalidSchema;
    var it = s.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "type")) {
            if (v == .string) {
                if (!knownType(v.string)) return error.InvalidSchema;
            } else if (v == .array and v.array.items.len > 0) {
                for (v.array.items, 0..) |t, i| {
                    if (t != .string or !knownType(t.string)) return error.InvalidSchema;
                    for (v.array.items[0..i]) |prev| if (std.mem.eql(u8, prev.string, t.string)) return error.InvalidSchema;
                }
            } else return error.InvalidSchema;
        } else if (std.mem.eql(u8, key, "properties")) {
            if (v != .object) return error.InvalidSchema;
            var props = v.object.iterator();
            while (props.next()) |p| try checkAt(p.value_ptr.*, depth + 1);
        } else if (std.mem.eql(u8, key, "required")) {
            if (v != .array) return error.InvalidSchema;
            for (v.array.items, 0..) |name, i| {
                if (name != .string) return error.InvalidSchema;
                for (v.array.items[0..i]) |prev| if (std.mem.eql(u8, prev.string, name.string)) return error.InvalidSchema;
            }
        } else if (std.mem.eql(u8, key, "additionalProperties") or std.mem.eql(u8, key, "items")) {
            try checkAt(v, depth + 1);
        } else if (std.mem.eql(u8, key, "anyOf")) {
            if (v != .array or v.array.items.len == 0) return error.InvalidSchema;
            for (v.array.items) |branch| try checkAt(branch, depth + 1);
        } else if (std.mem.eql(u8, key, "enum")) {
            if (v != .array or v.array.items.len == 0) return error.InvalidSchema;
            for (v.array.items, 0..) |choice, i| {
                if (!equal(choice, choice, depth + 1)) return error.InvalidSchema;
                for (v.array.items[0..i]) |previous| if (equal(previous, choice, depth + 1)) return error.InvalidSchema;
            }
        } else if (std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "description")) {
            if (v != .string) return error.InvalidSchema;
        } else return error.UnsupportedSchemaKeyword;
    }
}

pub fn validate(s: Value, value: Value) bool {
    return validateAt(s, value, 0);
}
fn validateAt(s: Value, v: Value, depth: usize) bool {
    if (depth > 64) return false;
    if (s == .bool) return s.bool;
    if (s != .object) return false;
    if (s.object.get("type")) |t| {
        const matches = if (t == .string) typeMatches(t.string, v) else blk: {
            for (t.array.items) |kind| if (typeMatches(kind.string, v)) break :blk true;
            break :blk false;
        };
        if (!matches) return false;
    }
    if (s.object.get("enum")) |choices| {
        const found = for (choices.array.items) |choice| {
            if (equal(choice, v, depth + 1)) break true;
        } else false;
        if (!found) return false;
    }
    if (s.object.get("anyOf")) |choices| {
        const found = for (choices.array.items) |choice| {
            if (validateAt(choice, v, depth + 1)) break true;
        } else false;
        if (!found) return false;
    }
    if (v == .object) {
        if (s.object.get("required")) |required| for (required.array.items) |key| {
            if (!v.object.contains(key.string)) return false;
        };
        const props = s.object.get("properties");
        var it = v.object.iterator();
        while (it.next()) |entry| {
            const property = if (props) |p| p.object.get(entry.key_ptr.*) else null;
            if (property orelse s.object.get("additionalProperties")) |constraint| {
                if (!validateAt(constraint, entry.value_ptr.*, depth + 1)) return false;
            }
        }
    }
    if (v == .array) if (s.object.get("items")) |items| for (v.array.items) |item| {
        if (!validateAt(items, item, depth + 1)) return false;
    };
    return true;
}
const Number = struct { digits: []const u8, negative: bool, scale: i64 };
fn number(v: Value, buffer: []u8) ?Number {
    const text = switch (v) {
        .integer => |n| std.fmt.bufPrint(buffer, "{d}", .{n}) catch return null,
        .float => |n| blk: {
            if (!std.math.isFinite(n)) return null;
            break :blk std.fmt.bufPrint(buffer, "{e}", .{n}) catch return null;
        },
        .number_string => |n| n,
        else => return null,
    };
    if (text.len == 0) return null;
    const end = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
    const mantissa = text[0..end];
    const exponent = if (end < text.len) std.fmt.parseInt(i64, text[end + 1 ..], 10) catch return null else 0;
    const fraction: i64 = @intCast(if (std.mem.indexOfScalar(u8, mantissa, '.')) |dot| mantissa.len - dot - 1 else 0);
    var first: ?usize = null;
    var last: usize = 0;
    var trailing: i64 = 0;
    for (mantissa, 0..) |ch, i| {
        if (ch == '.' or (i == 0 and ch == '-')) continue;
        if (!std.ascii.isDigit(ch)) return null;
        if (ch != '0') {
            first = first orelse i;
            last = i;
            trailing = 0;
        } else trailing += 1;
    }
    const start = first orelse return .{ .digits = "", .negative = false, .scale = 0 };
    const scale = std.math.add(i64, std.math.sub(i64, exponent, fraction) catch return null, trailing) catch return null;
    return .{ .digits = mantissa[start .. last + 1], .negative = text[0] == '-', .scale = scale };
}
pub fn isInteger(v: Value) bool {
    var buffer: [128]u8 = undefined;
    const n = number(v, &buffer) orelse return false;
    return n.scale >= 0;
}
pub fn equalNumbers(a: Value, b: Value) bool {
    var left_buffer: [128]u8 = undefined;
    var right_buffer: [128]u8 = undefined;
    const left = number(a, &left_buffer) orelse return false;
    const right = number(b, &right_buffer) orelse return false;
    if (left.negative != right.negative or left.scale != right.scale) return false;
    var x: usize = 0;
    var y: usize = 0;
    while (x < left.digits.len and y < right.digits.len) {
        if (left.digits[x] == '.') {
            x += 1;
            continue;
        }
        if (right.digits[y] == '.') {
            y += 1;
            continue;
        }
        if (left.digits[x] != right.digits[y]) return false;
        x += 1;
        y += 1;
    }
    return x == left.digits.len and y == right.digits.len;
}
fn typeMatches(t: []const u8, v: Value) bool {
    var buffer: [128]u8 = undefined;
    if (std.mem.eql(u8, t, "number")) return number(v, &buffer) != null;
    if (std.mem.eql(u8, t, "integer")) return isInteger(v);
    if (std.mem.eql(u8, t, "boolean")) return v == .bool;
    return std.mem.eql(u8, t, @tagName(v));
}
fn equal(a: Value, b: Value, depth: usize) bool {
    if (depth > 64) return false;
    if (a == .integer or a == .float or a == .number_string) return equalNumbers(a, b);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!equal(x, y, depth + 1)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |e| if (!equal(e.value_ptr.*, b.object.get(e.key_ptr.*) orelse break :blk false, depth + 1)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

test "closed schema subset and asymmetric object/array/null validation" {
    const a = std.testing.allocator;
    var s = try std.json.parseFromSlice(Value, a,
        \\{"type":"object","properties":{"left":{"type":"integer"},"right":{"anyOf":[{"type":"null"},{"type":"array","items":{"enum":["yes","no"]}}]}},"required":["left","right"],"additionalProperties":false}
    , .{});
    defer s.deinit();
    try check(s.value);
    const cases = .{
        .{ "{\"left\":3,\"right\":[\"yes\"]}", true },
        .{ "{\"left\":3.5,\"right\":null}", false },
        .{ "{\"left\":3}", false },
        .{ "{\"left\":3,\"right\":null,\"extra\":1}", false },
        .{ "{\"left\":3,\"right\":[\"maybe\"]}", false },
        .{ "{\"left\":3,\"right\":null}", true },
    };
    inline for (cases) |case| {
        var v = try std.json.parseFromSlice(Value, a, case[0], .{ .parse_numbers = false });
        defer v.deinit();
        try std.testing.expectEqual(case[1], validate(s.value, v.value));
    }
    var bad = try std.json.parseFromSlice(Value, a, "{\"minimum\":1}", .{});
    defer bad.deinit();
    try std.testing.expectError(error.UnsupportedSchemaKeyword, check(bad.value));
}

test "integer and enum numeric comparisons never round JSON lexemes" {
    const a = std.testing.allocator;
    var s = try std.json.parseFromSlice(Value, a, "{\"enum\":[1,12,9007199254740993]}", .{ .parse_numbers = false });
    defer s.deinit();
    try check(s.value);
    const cases = .{
        .{ "1.000000000000000000000000000000000000001", false, false },
        .{ "1.0", true, true },
        .{ "1200e-2", true, true },
        .{ "9007199254740993", true, true },
        .{ "9007199254740992", true, false },
        .{ "1e-9999", false, false },
        .{ "1e9999", true, false },
        .{ "-0.000e-100", true, false },
        .{ "1e999999999999999999999", false, false },
    };
    inline for (cases) |case| {
        const v: Value = .{ .number_string = case[0] };
        try std.testing.expectEqual(case[1], isInteger(v));
        try std.testing.expectEqual(case[2], validate(s.value, v));
    }
    try std.testing.expect(equalNumbers(.{ .integer = 12 }, .{ .float = 12 }));
}
