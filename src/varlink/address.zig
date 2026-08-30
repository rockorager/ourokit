const std = @import("std");

/// A parsed Varlink service address. All slices borrow from the input. Address
/// properties beginning with `;` are deliberately ignored as required by the
/// protocol, leaving extension interpretation to a transport adapter.
pub const Address = union(enum) {
    tcp: struct {
        host: []const u8,
        port: u16,
    },
    unix: struct {
        name: []const u8,
        abstract: bool,
    },
    device: []const u8,

    pub fn parse(input: []const u8) !Address {
        const address = input[0 .. std.mem.indexOfScalar(u8, input, ';') orelse input.len];
        const scheme_end = std.mem.indexOfScalar(u8, address, ':') orelse
            return error.MissingAddressScheme;
        const scheme = address[0..scheme_end];
        const value = address[scheme_end + 1 ..];

        if (std.mem.eql(u8, scheme, "unix")) {
            if (value.len == 0) return error.MissingUnixAddress;
            if (value[0] == '@') {
                if (value.len == 1) return error.MissingUnixAddress;
                return .{ .unix = .{ .name = value[1..], .abstract = true } };
            }
            if (value[0] != '/') return error.UnixPathNotAbsolute;
            return .{ .unix = .{ .name = value, .abstract = false } };
        }
        if (std.mem.eql(u8, scheme, "device")) {
            if (value.len == 0 or value[0] != '/') return error.DevicePathNotAbsolute;
            return .{ .device = value };
        }
        if (std.mem.eql(u8, scheme, "tcp")) return parseTcp(value);
        return error.UnsupportedAddressScheme;
    }
};

fn parseTcp(value: []const u8) !Address {
    if (value.len == 0) return error.MissingTcpHost;
    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;
    if (value[0] == '[') {
        const close = std.mem.indexOfScalar(u8, value, ']') orelse
            return error.InvalidTcpAddress;
        if (close == 1) return error.MissingTcpHost;
        if (close + 1 >= value.len or value[close + 1] != ':')
            return error.MissingTcpPort;
        host = value[1..close];
        port_text = value[close + 2 ..];
    } else {
        const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse
            return error.MissingTcpPort;
        if (separator == 0) return error.MissingTcpHost;
        host = value[0..separator];
        if (std.mem.indexOfScalar(u8, host, ':') != null) return error.InvalidTcpAddress;
        port_text = value[separator + 1 ..];
    }
    if (port_text.len == 0) return error.MissingTcpPort;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidTcpPort;
    return .{ .tcp = .{ .host = host, .port = port } };
}

test "address parser supports standard transports and ignores properties" {
    const filesystem = try Address.parse("unix:/run/org.example.service;mode=0660");
    try std.testing.expectEqualStrings("/run/org.example.service", filesystem.unix.name);
    try std.testing.expect(!filesystem.unix.abstract);
    const abstract = try Address.parse("unix:@org.example.service");
    try std.testing.expectEqualStrings("org.example.service", abstract.unix.name);
    try std.testing.expect(abstract.unix.abstract);
    const ipv4 = try Address.parse("tcp:127.0.0.1:12345");
    try std.testing.expectEqualStrings("127.0.0.1", ipv4.tcp.host);
    try std.testing.expectEqual(@as(u16, 12345), ipv4.tcp.port);
    const ipv6 = try Address.parse("tcp:[::1]:65535");
    try std.testing.expectEqualStrings("::1", ipv6.tcp.host);
    try std.testing.expectEqual(@as(u16, 65535), ipv6.tcp.port);
    const device = try Address.parse("device:/dev/org.kernel.example");
    try std.testing.expectEqualStrings("/dev/org.kernel.example", device.device);
}

test "address parser rejects ambiguous and incomplete addresses" {
    try std.testing.expectError(error.UnixPathNotAbsolute, Address.parse("unix:relative"));
    try std.testing.expectError(error.InvalidTcpAddress, Address.parse("tcp:::1:42"));
    try std.testing.expectError(error.InvalidTcpPort, Address.parse("tcp:localhost:70000"));
    try std.testing.expectError(error.UnsupportedAddressScheme, Address.parse("exec:/bin/test"));
}
