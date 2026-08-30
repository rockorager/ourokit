const std = @import("std");
const interface_module = @import("interface.zig");
const Interface = interface_module.Interface;
const message = @import("message.zig");
const Server = @import("server.zig").Server;

pub const Info = struct {
    vendor: []const u8,
    product: []const u8,
    version: []const u8,
    url: []const u8,
};

pub const Validation = union(enum) {
    valid,
    interface_not_found: []const u8,
    member_not_found: []const u8,
    invalid_parameter: []const u8,
};

const OwnedInfo = struct {
    vendor: []u8,
    product: []u8,
    version: []u8,
    url: []u8,

    fn init(allocator: std.mem.Allocator, info: Info) !OwnedInfo {
        const vendor = try allocator.dupe(u8, info.vendor);
        errdefer allocator.free(vendor);
        const product = try allocator.dupe(u8, info.product);
        errdefer allocator.free(product);
        const version = try allocator.dupe(u8, info.version);
        errdefer allocator.free(version);
        const url = try allocator.dupe(u8, info.url);
        return .{
            .vendor = vendor,
            .product = product,
            .version = version,
            .url = url,
        };
    }

    fn deinit(self: *OwnedInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.version);
        allocator.free(self.product);
        allocator.free(self.vendor);
        self.* = undefined;
    }
};

/// Metadata and validated interface descriptions for the mandatory
/// org.varlink.service methods. It handles only that interface and leaves
/// application method dispatch to the caller's pull-based event loop.
pub const Service = struct {
    allocator: std.mem.Allocator,
    info: OwnedInfo,
    interfaces: std.array_list.Managed(Interface),

    /// `interface_capacity` includes the mandatory org.varlink.service entry.
    pub fn init(
        allocator: std.mem.Allocator,
        info: Info,
        interface_capacity: usize,
    ) !Service {
        if (interface_capacity == 0) return error.InvalidCapacity;
        var owned_info = try OwnedInfo.init(allocator, info);
        errdefer owned_info.deinit(allocator);
        var interfaces = try std.array_list.Managed(Interface).initCapacity(
            allocator,
            interface_capacity,
        );
        errdefer interfaces.deinit();
        var standard = try Interface.parse(allocator, service_interface_description);
        errdefer standard.deinit();
        interfaces.appendAssumeCapacity(standard);
        return .{
            .allocator = allocator,
            .info = owned_info,
            .interfaces = interfaces,
        };
    }

    pub fn deinit(self: *Service) void {
        for (self.interfaces.items) |*interface| interface.deinit();
        self.interfaces.deinit();
        self.info.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addInterface(self: *Service, description: []const u8) !void {
        if (self.interfaces.items.len == self.interfaces.capacity)
            return error.InterfaceCapacityExceeded;
        var interface = try Interface.parse(self.allocator, description);
        errdefer interface.deinit();
        if (self.findInterface(interface.name) != null) return error.DuplicateInterface;
        self.interfaces.appendAssumeCapacity(interface);
    }

    pub fn interfaceCount(self: *const Service) usize {
        return self.interfaces.items.len;
    }

    pub fn findInterface(self: *const Service, name: []const u8) ?*const Interface {
        for (self.interfaces.items) |*interface|
            if (std.mem.eql(u8, interface.name, name)) return interface;
        return null;
    }

    pub fn validateRequest(
        self: *const Service,
        request: *const message.Request,
    ) Validation {
        return self.validateMethodInput(request.method, request.parameters);
    }

    pub fn validateMethodInput(
        self: *const Service,
        qualified_method: []const u8,
        parameters: ?message.Value,
    ) Validation {
        const resolved = self.resolveMethod(qualified_method) orelse
            return self.missingMember(qualified_method);
        if (invalidField(self, resolved.interface, resolved.method.input, parameters)) |field|
            return .{ .invalid_parameter = field };
        return .valid;
    }

    pub fn validateMethodOutput(
        self: *const Service,
        qualified_method: []const u8,
        parameters: ?message.Value,
    ) Validation {
        const resolved = self.resolveMethod(qualified_method) orelse
            return self.missingMember(qualified_method);
        if (invalidField(self, resolved.interface, resolved.method.output, parameters)) |field|
            return .{ .invalid_parameter = field };
        return .valid;
    }

    pub fn validateError(
        self: *const Service,
        qualified_error: []const u8,
        parameters: ?message.Value,
    ) Validation {
        const names = splitQualifiedMember(qualified_error) orelse
            return .{ .member_not_found = qualified_error };
        const interface = self.findInterface(names.interface) orelse
            return .{ .interface_not_found = names.interface };
        const definition = interface.errorDefinition(names.member) orelse
            return .{ .member_not_found = names.member };
        if (invalidField(self, interface, definition.parameters, parameters)) |field|
            return .{ .invalid_parameter = field };
        return .valid;
    }

    /// Handles an org.varlink.service request by submitting a response to the
    /// server state machine. Returns false for application-owned interfaces.
    pub fn handle(
        self: *const Service,
        server: *Server,
        call: message.CallHandle,
        request: *const message.Request,
    ) !bool {
        if (!std.mem.startsWith(u8, request.method, service_method_prefix)) return false;
        if (request.oneway) return true;
        if (request.upgrade) {
            try sendFieldError(
                self.allocator,
                server,
                call,
                "org.varlink.service.MethodNotImplemented",
                "method",
                request.method,
            );
            return true;
        }
        if (std.mem.eql(u8, request.method, service_method_prefix ++ "GetInfo")) {
            if (firstParameter(request.parameters)) |parameter| {
                try self.sendInvalidParameter(server, call, parameter);
            } else try self.sendInfo(server, call);
            return true;
        }
        if (std.mem.eql(
            u8,
            request.method,
            service_method_prefix ++ "GetInterfaceDescription",
        )) {
            const object = request.parameters orelse {
                try self.sendInvalidParameter(server, call, "interface");
                return true;
            };
            const interface_value = object.object.get("interface") orelse {
                try self.sendInvalidParameter(server, call, "interface");
                return true;
            };
            const interface_name = switch (interface_value) {
                .string => |value| value,
                else => {
                    try self.sendInvalidParameter(server, call, "interface");
                    return true;
                },
            };
            if (object.object.count() != 1) {
                var iterator = object.object.iterator();
                while (iterator.next()) |entry| {
                    if (!std.mem.eql(u8, entry.key_ptr.*, "interface")) {
                        try self.sendInvalidParameter(server, call, entry.key_ptr.*);
                        return true;
                    }
                }
            }
            const interface = self.findInterface(interface_name) orelse {
                try sendFieldError(
                    self.allocator,
                    server,
                    call,
                    "org.varlink.service.InterfaceNotFound",
                    "interface",
                    interface_name,
                );
                return true;
            };
            var parameters = std.json.ObjectMap.empty;
            defer parameters.deinit(self.allocator);
            try parameters.put(
                self.allocator,
                "description",
                .{ .string = interface.source },
            );
            try server.sendReply(call, .{ .object = parameters });
            return true;
        }

        try sendFieldError(
            self.allocator,
            server,
            call,
            "org.varlink.service.MethodNotFound",
            "method",
            request.method,
        );
        return true;
    }

    fn sendInfo(
        self: *const Service,
        server: *Server,
        call: message.CallHandle,
    ) !void {
        var names = std.json.Array.init(self.allocator);
        defer names.deinit();
        for (self.interfaces.items) |interface|
            try names.append(.{ .string = interface.name });
        var parameters = std.json.ObjectMap.empty;
        defer parameters.deinit(self.allocator);
        try parameters.put(self.allocator, "vendor", .{ .string = self.info.vendor });
        try parameters.put(self.allocator, "product", .{ .string = self.info.product });
        try parameters.put(self.allocator, "version", .{ .string = self.info.version });
        try parameters.put(self.allocator, "url", .{ .string = self.info.url });
        try parameters.put(self.allocator, "interfaces", .{ .array = names });
        try server.sendReply(call, .{ .object = parameters });
    }

    fn sendInvalidParameter(
        self: *const Service,
        server: *Server,
        call: message.CallHandle,
        parameter: []const u8,
    ) !void {
        try sendFieldError(
            self.allocator,
            server,
            call,
            "org.varlink.service.InvalidParameter",
            "parameter",
            parameter,
        );
    }

    const ResolvedMethod = struct {
        interface: *const Interface,
        method: *const interface_module.Method,
    };

    fn resolveMethod(self: *const Service, qualified: []const u8) ?ResolvedMethod {
        const names = splitQualifiedMember(qualified) orelse return null;
        const interface = self.findInterface(names.interface) orelse return null;
        return .{
            .interface = interface,
            .method = interface.method(names.member) orelse return null,
        };
    }

    fn missingMember(self: *const Service, qualified: []const u8) Validation {
        const names = splitQualifiedMember(qualified) orelse
            return .{ .member_not_found = qualified };
        if (self.findInterface(names.interface) == null)
            return .{ .interface_not_found = names.interface };
        return .{ .member_not_found = names.member };
    }
};

const QualifiedMember = struct {
    interface: []const u8,
    member: []const u8,
};

fn splitQualifiedMember(name: []const u8) ?QualifiedMember {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0 or dot + 1 == name.len) return null;
    return .{ .interface = name[0..dot], .member = name[dot + 1 ..] };
}

fn invalidField(
    service: *const Service,
    interface: *const Interface,
    fields: []const interface_module.Field,
    parameters: ?message.Value,
) ?[]const u8 {
    if (parameters) |value| {
        const object = switch (value) {
            .object => |map| map,
            else => return if (fields.len == 0) "parameters" else fields[0].name,
        };
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            var known = false;
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                    known = true;
                    if (!validateValue(service, interface, field.type, entry.value_ptr.*))
                        return field.name;
                    break;
                }
            }
            if (!known) return entry.key_ptr.*;
        }
        for (fields) |field| {
            if (object.get(field.name) == null and field.type.* != .optional) return field.name;
        }
        return null;
    }
    for (fields) |field| if (field.type.* != .optional) return field.name;
    return null;
}

fn validateValue(
    service: *const Service,
    interface: *const Interface,
    expected: *const interface_module.Type,
    value: message.Value,
) bool {
    return switch (expected.*) {
        .boolean => value == .bool,
        .integer => switch (value) {
            .integer => true,
            .number_string => |number| blk: {
                _ = std.fmt.parseInt(i64, number, 10) catch break :blk false;
                break :blk true;
            },
            else => false,
        },
        .float => switch (value) {
            .integer, .float => true,
            .number_string => |number| blk: {
                _ = std.fmt.parseFloat(f64, number) catch break :blk false;
                break :blk true;
            },
            else => false,
        },
        .string => value == .string,
        .object => value == .object,
        .any => value != .null,
        .optional => |child| value == .null or validateValue(service, interface, child, value),
        .array => |child| switch (value) {
            .array => |array| for (array.items) |item| {
                if (!validateValue(service, interface, child, item)) break false;
            } else true,
            else => false,
        },
        .dictionary => |child| switch (value) {
            .object => |object| blk: {
                var iterator = object.iterator();
                while (iterator.next()) |entry|
                    if (!validateValue(service, interface, child, entry.value_ptr.*))
                        break :blk false;
                break :blk true;
            },
            else => false,
        },
        .structure => |fields| invalidField(service, interface, fields, value) == null,
        .enumeration => |values| switch (value) {
            .string => |string| for (values) |candidate| {
                if (std.mem.eql(u8, candidate, string)) break true;
            } else false,
            else => false,
        },
        .named => |name| blk: {
            var target_interface = interface;
            var alias_name = name;
            if (splitQualifiedMember(name)) |qualified| {
                target_interface = service.findInterface(qualified.interface) orelse break :blk false;
                alias_name = qualified.member;
            }
            const alias = target_interface.typeAlias(alias_name) orelse break :blk false;
            break :blk validateValue(service, target_interface, alias.type, value);
        },
    };
}

fn firstParameter(parameters: ?message.Value) ?[]const u8 {
    const object = parameters orelse return null;
    var iterator = object.object.iterator();
    return if (iterator.next()) |entry| entry.key_ptr.* else null;
}

fn sendFieldError(
    allocator: std.mem.Allocator,
    server: *Server,
    call: message.CallHandle,
    error_name: []const u8,
    field: []const u8,
    value: []const u8,
) !void {
    var parameters = std.json.ObjectMap.empty;
    defer parameters.deinit(allocator);
    try parameters.put(allocator, field, .{ .string = value });
    try server.sendError(call, error_name, .{ .object = parameters });
}

const service_method_prefix = "org.varlink.service.";

pub const service_interface_description =
    \\# The Varlink Service Interface is provided by every varlink service. It
    \\# describes the service and the interfaces it implements.
    \\interface org.varlink.service
    \\method GetInfo() -> (vendor: string, product: string, version: string, url: string, interfaces: []string)
    \\method GetInterfaceDescription(interface: string) -> (description: string)
    \\error InterfaceNotFound(interface: string)
    \\error MethodNotFound(method: string)
    \\error MethodNotImplemented(method: string)
    \\error InvalidParameter(parameter: string)
    \\error PermissionDenied()
    \\error ExpectedMore()
;

test "service provides info and exact validated interface descriptions" {
    var service = try Service.init(std.testing.allocator, .{
        .vendor = "Ouro",
        .product = "Test",
        .version = "1",
        .url = "https://example.test",
    }, 2);
    defer service.deinit();
    const custom = "interface org.example.test\nmethod Ping() -> ()";
    try service.addInterface(custom);
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();

    const call_bytes =
        "{\"method\":\"org.varlink.service.GetInterfaceDescription\",\"parameters\":{\"interface\":\"org.example.test\"}}\x00";
    _ = try server.feed(call_bytes);
    var event = server.takeEvent().?;
    try std.testing.expect(try service.handle(
        &server,
        event.call.handle,
        &event.call.request,
    ));
    event.deinit();
    {
        var transmit = server.takeTransmit().?;
        defer transmit.deinit();
        var reply = try message.parseReply(
            std.testing.allocator,
            transmit.bytes[0 .. transmit.bytes.len - 1],
        );
        defer reply.deinit();
        try std.testing.expectEqualStrings(
            custom,
            reply.parameters.?.object.get("description").?.string,
        );
    }

    _ = try server.feed("{\"method\":\"org.varlink.service.GetInfo\"}\x00");
    event = server.takeEvent().?;
    try std.testing.expect(try service.handle(
        &server,
        event.call.handle,
        &event.call.request,
    ));
    event.deinit();
    var transmit = server.takeTransmit().?;
    defer transmit.deinit();
    var reply = try message.parseReply(
        std.testing.allocator,
        transmit.bytes[0 .. transmit.bytes.len - 1],
    );
    defer reply.deinit();
    const interfaces = reply.parameters.?.object.get("interfaces").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), interfaces.len);
    try std.testing.expectEqualStrings("org.varlink.service", interfaces[0].string);
    try std.testing.expectEqualStrings("org.example.test", interfaces[1].string);
}

test "service leaves application calls alone and reports invalid standard parameters" {
    var service = try Service.init(std.testing.allocator, .{
        .vendor = "Ouro",
        .product = "Test",
        .version = "1",
        .url = "https://example.test",
    }, 1);
    defer service.deinit();
    var server = try Server.init(std.testing.allocator, .{});
    defer server.deinit();
    const input =
        "{\"method\":\"org.varlink.service.GetInfo\",\"parameters\":{\"extra\":true}}\x00" ++
        "{\"method\":\"org.example.test.Ping\"}\x00";
    _ = try server.feed(input);
    var event = server.takeEvent().?;
    try std.testing.expect(try service.handle(
        &server,
        event.call.handle,
        &event.call.request,
    ));
    event.deinit();
    event = server.takeEvent().?;
    try std.testing.expect(!try service.handle(
        &server,
        event.call.handle,
        &event.call.request,
    ));
    try server.sendReply(event.call.handle, null);
    event.deinit();

    var transmit = server.takeTransmit().?;
    try std.testing.expect(std.mem.indexOf(u8, transmit.bytes, "InvalidParameter") != null);
    transmit.deinit();
    transmit = server.takeTransmit().?;
    transmit.deinit();
}

test "service validates method and error parameters against registered schemas" {
    var service = try Service.init(std.testing.allocator, .{
        .vendor = "Ouro",
        .product = "Test",
        .version = "1",
        .url = "https://example.test",
    }, 2);
    defer service.deinit();
    try service.addInterface(
        \\interface org.example.types
        \\type State (ready, busy)
        \\type Item (name: string, state: State)
        \\method Put(item: Item, tags: ?[]string) -> (accepted: bool)
        \\error BadItem(item: org.example.types.Item)
    );

    var valid = try message.parseRequest(
        std.testing.allocator,
        "{\"method\":\"org.example.types.Put\",\"parameters\":{\"item\":{\"name\":\"one\",\"state\":\"ready\"}}}",
    );
    defer valid.deinit();
    try std.testing.expect(service.validateRequest(&valid) == .valid);

    var invalid = try message.parseRequest(
        std.testing.allocator,
        "{\"method\":\"org.example.types.Put\",\"parameters\":{\"item\":{\"name\":\"one\"}}}",
    );
    defer invalid.deinit();
    switch (service.validateRequest(&invalid)) {
        .invalid_parameter => |field| try std.testing.expectEqualStrings("item", field),
        else => return error.ExpectedInvalidParameter,
    }

    var output_document = try std.json.parseFromSlice(
        message.Value,
        std.testing.allocator,
        "{\"accepted\":true}",
        .{},
    );
    defer output_document.deinit();
    try std.testing.expect(service.validateMethodOutput(
        "org.example.types.Put",
        output_document.value,
    ) == .valid);
    try std.testing.expect(service.validateError(
        "org.example.types.BadItem",
        valid.parameters,
    ) == .valid);
    switch (service.validateMethodInput("org.missing.test.Put", null)) {
        .interface_not_found => |name| try std.testing.expectEqualStrings(
            "org.missing.test",
            name,
        ),
        else => return error.ExpectedMissingInterface,
    }
}

test "service registry unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseServiceAllocationFailure,
        .{},
    );
}

fn exerciseServiceAllocationFailure(allocator: std.mem.Allocator) !void {
    var service = try Service.init(allocator, .{
        .vendor = "Ouro",
        .product = "Test",
        .version = "1",
        .url = "https://example.test",
    }, 2);
    defer service.deinit();
    try service.addInterface("interface org.example.test\nmethod Ping() -> ()");
}
