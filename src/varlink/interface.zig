const std = @import("std");

pub const Field = struct {
    name: []const u8,
    type: *const Type,
};

pub const Type = union(enum) {
    boolean,
    integer,
    float,
    string,
    object,
    any,
    named: []const u8,
    optional: *const Type,
    array: *const Type,
    dictionary: *const Type,
    structure: []const Field,
    enumeration: []const []const u8,
};

pub const TypeAlias = struct {
    name: []const u8,
    type: *const Type,
};

pub const Method = struct {
    name: []const u8,
    input: []const Field,
    output: []const Field,
};

pub const Error = struct {
    name: []const u8,
    parameters: []const Field,
};

pub const Member = union(enum) {
    type_alias: TypeAlias,
    method: Method,
    error_definition: Error,

    pub fn name(self: Member) []const u8 {
        return switch (self) {
            .type_alias => |value| value.name,
            .method => |value| value.name,
            .error_definition => |value| value.name,
        };
    }
};

/// Owned and validated Varlink interface description. All AST slices point
/// into `arena`; `source` preserves the exact description used by
/// org.varlink.service.GetInterfaceDescription.
pub const Interface = struct {
    arena: *std.heap.ArenaAllocator,
    source: []const u8,
    name: []const u8,
    members: []const Member,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Interface {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const owned_source = try arena.allocator().dupe(u8, source);
        var parser: Parser = .{
            .allocator = arena.allocator(),
            .source = owned_source,
        };
        const parsed = try parser.parseInterface();
        return .{
            .arena = arena,
            .source = owned_source,
            .name = parsed.name,
            .members = parsed.members,
        };
    }

    pub fn deinit(self: *Interface) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn member(self: *const Interface, name: []const u8) ?Member {
        for (self.members) |candidate|
            if (std.mem.eql(u8, candidate.name(), name)) return candidate;
        return null;
    }

    pub fn method(self: *const Interface, name: []const u8) ?*const Method {
        for (self.members) |*candidate| switch (candidate.*) {
            .method => |*method_value| if (std.mem.eql(u8, method_value.name, name))
                return method_value,
            else => {},
        };
        return null;
    }

    pub fn errorDefinition(self: *const Interface, name: []const u8) ?*const Error {
        for (self.members) |*candidate| switch (candidate.*) {
            .error_definition => |*definition| if (std.mem.eql(u8, definition.name, name))
                return definition,
            else => {},
        };
        return null;
    }

    pub fn typeAlias(self: *const Interface, name: []const u8) ?*const TypeAlias {
        for (self.members) |*candidate| switch (candidate.*) {
            .type_alias => |*alias| if (std.mem.eql(u8, alias.name, name)) return alias,
            else => {},
        };
        return null;
    }
};

const ParsedInterface = struct {
    name: []const u8,
    members: []const Member,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn parseInterface(self: *Parser) !ParsedInterface {
        try self.skipTrivia();
        try self.expectKeyword("interface");
        try self.requireTrivia();
        const interface_name = try self.parseInterfaceName();
        var members = std.array_list.Managed(Member).init(self.allocator);
        while (true) {
            try self.skipTrivia();
            if (self.index == self.source.len) break;
            const member_value: Member = if (self.consumeKeyword("type")) blk: {
                try self.requireTrivia();
                const name = try self.parseName();
                try self.skipTrivia();
                break :blk .{ .type_alias = .{ .name = name, .type = try self.parseComposite() } };
            } else if (self.consumeKeyword("method")) blk: {
                try self.requireTrivia();
                const name = try self.parseName();
                try self.skipTrivia();
                const input = try self.parseStructure();
                try self.skipTrivia();
                try self.expectBytes("->");
                try self.skipTrivia();
                break :blk .{ .method = .{
                    .name = name,
                    .input = input,
                    .output = try self.parseStructure(),
                } };
            } else if (self.consumeKeyword("error")) blk: {
                try self.requireTrivia();
                const name = try self.parseName();
                try self.skipTrivia();
                break :blk .{ .error_definition = .{
                    .name = name,
                    .parameters = try self.parseStructure(),
                } };
            } else return error.ExpectedMember;
            for (members.items) |existing|
                if (std.mem.eql(u8, existing.name(), member_value.name()))
                    return error.DuplicateMember;
            try members.append(member_value);
        }
        if (members.items.len == 0) return error.InterfaceHasNoMembers;
        const owned_members = try members.toOwnedSlice();
        try validateReferences(owned_members);
        return .{ .name = interface_name, .members = owned_members };
    }

    fn parseType(self: *Parser) anyerror!*const Type {
        try self.skipTrivia();
        if (self.consumeByte('?')) {
            try self.skipTrivia();
            if (try self.parseContainerPrefix()) |container| return self.allocateType(.{
                .optional = try self.allocateType(switch (container) {
                    .array => .{ .array = try self.parseType() },
                    .dictionary => .{ .dictionary = try self.parseType() },
                }),
            });
            return self.allocateType(.{ .optional = try self.parseElementType() });
        }
        if (try self.parseContainerPrefix()) |container| return self.allocateType(switch (container) {
            .array => .{ .array = try self.parseType() },
            .dictionary => .{ .dictionary = try self.parseType() },
        });

        return self.parseElementType();
    }

    const Container = enum { array, dictionary };

    fn parseContainerPrefix(self: *Parser) !?Container {
        if (!self.consumeByte('[')) return null;
        try self.skipTrivia();
        if (self.consumeByte(']')) return .array;
        try self.expectKeyword("string");
        try self.skipTrivia();
        try self.expectByte(']');
        return .dictionary;
    }

    fn parseElementType(self: *Parser) anyerror!*const Type {
        if (self.peekByte() == '(') return self.parseComposite();
        if (self.consumeKeyword("bool")) return self.allocateType(.boolean);
        if (self.consumeKeyword("int")) return self.allocateType(.integer);
        if (self.consumeKeyword("float")) return self.allocateType(.float);
        if (self.consumeKeyword("string")) return self.allocateType(.string);
        if (self.consumeKeyword("object")) return self.allocateType(.object);
        if (self.consumeKeyword("any")) return self.allocateType(.any);
        const name = try self.parseTypeName();
        return self.allocateType(.{ .named = name });
    }

    fn parseComposite(self: *Parser) !*const Type {
        try self.expectByte('(');
        try self.skipTrivia();
        if (self.consumeByte(')')) return self.allocateType(.{ .structure = &.{} });
        const first_name = try self.parseFieldName();
        try self.skipTrivia();
        if (self.consumeByte(':')) {
            var fields = std.array_list.Managed(Field).init(self.allocator);
            try fields.append(.{ .name = first_name, .type = try self.parseType() });
            while (true) {
                try self.skipTrivia();
                if (self.consumeByte(')')) break;
                try self.expectByte(',');
                try self.skipTrivia();
                const name = try self.parseFieldName();
                for (fields.items) |field|
                    if (std.mem.eql(u8, field.name, name)) return error.DuplicateField;
                try self.skipTrivia();
                try self.expectByte(':');
                try fields.append(.{ .name = name, .type = try self.parseType() });
            }
            return self.allocateType(.{ .structure = try fields.toOwnedSlice() });
        }

        var values = std.array_list.Managed([]const u8).init(self.allocator);
        try values.append(first_name);
        while (true) {
            try self.skipTrivia();
            if (self.consumeByte(')')) break;
            try self.expectByte(',');
            try self.skipTrivia();
            const name = try self.parseFieldName();
            for (values.items) |value|
                if (std.mem.eql(u8, value, name)) return error.DuplicateEnumValue;
            try values.append(name);
        }
        return self.allocateType(.{ .enumeration = try values.toOwnedSlice() });
    }

    fn parseStructure(self: *Parser) ![]const Field {
        const parsed = try self.parseComposite();
        return switch (parsed.*) {
            .structure => |fields| fields,
            else => error.ExpectedStructure,
        };
    }

    fn allocateType(self: *Parser, value: Type) !*const Type {
        const pointer = try self.allocator.create(Type);
        pointer.* = value;
        return pointer;
    }

    fn parseName(self: *Parser) ![]const u8 {
        const start = self.index;
        const first = self.peekByte() orelse return error.ExpectedName;
        if (!std.ascii.isUpper(first)) return error.ExpectedName;
        self.index += 1;
        while (self.peekByte()) |byte| {
            if (!std.ascii.isAlphanumeric(byte)) break;
            self.index += 1;
        }
        return self.source[start..self.index];
    }

    fn parseFieldName(self: *Parser) ![]const u8 {
        const start = self.index;
        const first = self.peekByte() orelse return error.ExpectedFieldName;
        if (!std.ascii.isAlphabetic(first)) return error.ExpectedFieldName;
        self.index += 1;
        var previous_underscore = false;
        while (self.peekByte()) |byte| {
            if (std.ascii.isAlphanumeric(byte)) {
                previous_underscore = false;
                self.index += 1;
            } else if (byte == '_') {
                if (previous_underscore) return error.InvalidFieldName;
                previous_underscore = true;
                self.index += 1;
            } else break;
        }
        if (previous_underscore) return error.InvalidFieldName;
        return self.source[start..self.index];
    }

    fn parseInterfaceName(self: *Parser) ![]const u8 {
        const start = self.index;
        var dots: usize = 0;
        var segment_len: usize = 0;
        while (self.peekByte()) |byte| {
            if (std.ascii.isAlphanumeric(byte)) {
                if (dots == 0 and segment_len == 0 and !std.ascii.isAlphabetic(byte))
                    return error.InvalidInterfaceName;
                segment_len += 1;
                self.index += 1;
            } else if (byte == '.') {
                if (segment_len == 0) return error.InvalidInterfaceName;
                segment_len = 0;
                dots += 1;
                self.index += 1;
            } else break;
        }
        if (dots == 0 or segment_len == 0) return error.InvalidInterfaceName;
        return self.source[start..self.index];
    }

    fn parseTypeName(self: *Parser) ![]const u8 {
        if (self.peekByte()) |byte| if (std.ascii.isUpper(byte)) return self.parseName();
        const start = self.index;
        while (self.peekByte()) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '.') break;
            self.index += 1;
        }
        const qualified = self.source[start..self.index];
        const final_dot = std.mem.lastIndexOfScalar(u8, qualified, '.') orelse
            return error.ExpectedName;
        if (final_dot == 0 or final_dot + 1 == qualified.len or
            !std.ascii.isUpper(qualified[final_dot + 1])) return error.ExpectedName;
        var segment_start: usize = 0;
        for (qualified[0..final_dot], 0..) |byte, index| {
            if (byte == '.') {
                if (index == segment_start) return error.ExpectedName;
                segment_start = index + 1;
            } else if (!std.ascii.isAlphanumeric(byte) or
                (index == 0 and !std.ascii.isAlphabetic(byte)))
                return error.ExpectedName;
        }
        if (segment_start == final_dot) return error.ExpectedName;
        for (qualified[final_dot + 2 ..]) |byte|
            if (!std.ascii.isAlphanumeric(byte)) return error.ExpectedName;
        return qualified;
    }

    fn skipTrivia(self: *Parser) !void {
        while (self.index < self.source.len) {
            if (self.source[self.index] == '#') {
                while (self.index < self.source.len) {
                    if (self.source[self.index] == '\n' or self.source[self.index] == '\r') break;
                    const comment_length = std.unicode.utf8ByteSequenceLength(
                        self.source[self.index],
                    ) catch return error.InvalidUtf8;
                    if (self.index + comment_length > self.source.len) return error.InvalidUtf8;
                    const comment_codepoint = std.unicode.utf8Decode(
                        self.source[self.index..][0..comment_length],
                    ) catch return error.InvalidUtf8;
                    if (comment_codepoint == 0x2028 or comment_codepoint == 0x2029) break;
                    self.index += comment_length;
                }
                continue;
            }
            const length = std.unicode.utf8ByteSequenceLength(self.source[self.index]) catch
                return error.InvalidUtf8;
            if (self.index + length > self.source.len) return error.InvalidUtf8;
            const codepoint = std.unicode.utf8Decode(self.source[self.index..][0..length]) catch
                return error.InvalidUtf8;
            if (!isWhitespace(codepoint)) break;
            self.index += length;
        }
    }

    fn requireTrivia(self: *Parser) !void {
        const before = self.index;
        try self.skipTrivia();
        if (self.index == before) return error.ExpectedWhitespace;
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) !void {
        if (!self.consumeKeyword(keyword)) return error.ExpectedKeyword;
    }

    fn consumeKeyword(self: *Parser, keyword: []const u8) bool {
        if (!std.mem.startsWith(u8, self.source[self.index..], keyword)) return false;
        const end = self.index + keyword.len;
        if (end < self.source.len and
            (std.ascii.isAlphanumeric(self.source[end]) or self.source[end] == '_')) return false;
        self.index = end;
        return true;
    }

    fn expectBytes(self: *Parser, bytes: []const u8) !void {
        if (!self.consumeBytes(bytes)) return error.UnexpectedToken;
    }

    fn consumeBytes(self: *Parser, bytes: []const u8) bool {
        if (!std.mem.startsWith(u8, self.source[self.index..], bytes)) return false;
        self.index += bytes.len;
        return true;
    }

    fn expectByte(self: *Parser, byte: u8) !void {
        if (!self.consumeByte(byte)) return error.UnexpectedToken;
    }

    fn consumeByte(self: *Parser, byte: u8) bool {
        if (self.peekByte() != byte) return false;
        self.index += 1;
        return true;
    }

    fn peekByte(self: *const Parser) ?u8 {
        return if (self.index == self.source.len) null else self.source[self.index];
    }
};

fn validateReferences(members: []const Member) !void {
    for (members) |member_value| switch (member_value) {
        .type_alias => |alias| try validateType(alias.type, members),
        .method => |method| {
            for (method.input) |field| try validateType(field.type, members);
            for (method.output) |field| try validateType(field.type, members);
        },
        .error_definition => |definition| {
            for (definition.parameters) |field| try validateType(field.type, members);
        },
    };
}

fn validateType(type_value: *const Type, members: []const Member) !void {
    switch (type_value.*) {
        .named => |name| {
            if (std.mem.indexOfScalar(u8, name, '.') != null) return;
            for (members) |member_value| switch (member_value) {
                .type_alias => |alias| if (std.mem.eql(u8, alias.name, name)) return,
                else => {},
            };
            return error.UnknownType;
        },
        .optional, .array, .dictionary => |child| try validateType(child, members),
        .structure => |fields| for (fields) |field| try validateType(field.type, members),
        else => {},
    }
}

fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        ' ',
        '\t',
        '\n',
        '\r',
        0x00a0,
        0xfeff,
        0x1680,
        0x180e,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

test "interface parser owns nested methods types errors and comments" {
    const source =
        \\# A test interface.
        \\interface org.example.test
        \\type State (idle, busy)
        \\type Item (name: string, state: State, tags: ? [ ] string)
        \\method Get(item: Item, options: [ string ] any) -> (item: ? Item)
        \\error NotFound(name: string)
    ;
    var interface = try Interface.parse(std.testing.allocator, source);
    defer interface.deinit();
    try std.testing.expectEqualStrings("org.example.test", interface.name);
    try std.testing.expectEqual(@as(usize, 4), interface.members.len);
    const method = interface.member("Get").?.method;
    try std.testing.expectEqual(@as(usize, 2), method.input.len);
    try std.testing.expectEqualStrings("item", method.output[0].name);
    try std.testing.expectEqualStrings(source, interface.source);
}

test "interface parser accepts fully qualified type references and Unicode whitespace" {
    var interface = try Interface.parse(
        std.testing.allocator,
        "interface\u{00a0}org.example.test\nmethod Get(value: org.example.other.Item) -> ()",
    );
    defer interface.deinit();
    const field_type = interface.member("Get").?.method.input[0].type;
    try std.testing.expectEqualStrings("org.example.other.Item", field_type.named);

    var after_comment = try Interface.parse(
        std.testing.allocator,
        "interface org.example.test\u{2028}# method docs\u{2029}method Get() -> ()",
    );
    defer after_comment.deinit();
    try std.testing.expect(after_comment.method("Get") != null);

    var numeric_segment = try Interface.parse(
        std.testing.allocator,
        "interface org.7zip.test\nmethod Get(value: org.7zip.other.Item) -> ()",
    );
    defer numeric_segment.deinit();
}

test "interface parser validates shared namespaces fields and type references" {
    try std.testing.expectError(
        error.DuplicateMember,
        Interface.parse(std.testing.allocator, "interface org.example.test\ntype Item ()\nmethod Item() -> ()"),
    );
    try std.testing.expectError(
        error.DuplicateField,
        Interface.parse(std.testing.allocator, "interface org.example.test\nmethod Get(value: int, value: int) -> ()"),
    );
    try std.testing.expectError(
        error.UnknownType,
        Interface.parse(std.testing.allocator, "interface org.example.test\nmethod Get(value: Missing) -> ()"),
    );
    try std.testing.expectError(
        error.ExpectedName,
        Interface.parse(std.testing.allocator, "interface org.example.test\nmethod Get(value: ??string) -> ()"),
    );
}

test "interface parser unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseInterfaceAllocationFailure,
        .{},
    );
}

fn exerciseInterfaceAllocationFailure(allocator: std.mem.Allocator) !void {
    var interface = try Interface.parse(
        allocator,
        "interface org.example.test\ntype Item (name: string)\nmethod Get(item: Item) -> (item: Item)",
    );
    defer interface.deinit();
}
