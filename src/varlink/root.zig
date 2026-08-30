pub const Address = @import("address.zig").Address;
pub const Client = @import("client.zig").Client;
pub const ClientEvent = @import("client.zig").Event;
pub const Server = @import("server.zig").Server;
pub const ServerEvent = @import("server.zig").Event;
pub const Interface = @import("interface.zig").Interface;
pub const InterfaceField = @import("interface.zig").Field;
pub const InterfaceError = @import("interface.zig").Error;
pub const InterfaceMember = @import("interface.zig").Member;
pub const InterfaceMethod = @import("interface.zig").Method;
pub const InterfaceType = @import("interface.zig").Type;
pub const InterfaceTypeAlias = @import("interface.zig").TypeAlias;
pub const Service = @import("service.zig").Service;
pub const ServiceInfo = @import("service.zig").Info;
pub const ServiceValidation = @import("service.zig").Validation;
pub const service_interface_description = @import("service.zig").service_interface_description;

const message = @import("message.zig");
pub const AfterSend = message.AfterSend;
pub const CallHandle = message.CallHandle;
pub const Config = message.Config;
pub const OutgoingCall = message.OutgoingCall;
pub const Reply = message.Reply;
pub const Request = message.Request;
pub const Transmit = message.Transmit;
pub const Value = message.Value;

test {
    _ = @import("address.zig");
    _ = @import("queue.zig");
    _ = @import("decoder.zig");
    _ = @import("message.zig");
    _ = @import("interface.zig");
    _ = @import("service.zig");
    _ = @import("client.zig");
    _ = @import("server.zig");
}
