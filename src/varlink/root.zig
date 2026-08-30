pub const Client = @import("client.zig").Client;
pub const ClientEvent = @import("client.zig").Event;
pub const Server = @import("server.zig").Server;
pub const ServerEvent = @import("server.zig").Event;

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
    _ = @import("queue.zig");
    _ = @import("decoder.zig");
    _ = @import("message.zig");
    _ = @import("client.zig");
    _ = @import("server.zig");
}
