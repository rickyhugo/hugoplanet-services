//! MQTT 3.1.1 Client Library
//!
//! A lightweight MQTT client implementation for Zig.
//!
//! ## Example
//! ```zig
//! const mqtt = @import("mqtt");
//!
//! var client = try mqtt.Client.init(.{
//!     .host = "localhost",
//!     .port = 1883,
//!     .allocator = allocator,
//! });
//! defer client.deinit();
//!
//! try client.connect(.{}, .{ .client_id = "my-client" });
//! ```

const std = @import("std");

pub const Client = @import("mqtt.zig").Client;
pub const QoS = @import("mqtt.zig").QoS;
pub const ConnectOpts = @import("mqtt.zig").ConnectOpts;
pub const PublishOpts = @import("mqtt.zig").PublishOpts;
pub const SubscribeOpts = @import("mqtt.zig").SubscribeOpts;
pub const UnsubscribeOpts = @import("mqtt.zig").UnsubscribeOpts;
pub const PubAckOpts = @import("mqtt.zig").PubAckOpts;
pub const PubRecOpts = @import("mqtt.zig").PubRecOpts;
pub const PubRelOpts = @import("mqtt.zig").PubRelOpts;
pub const PubCompOpts = @import("mqtt.zig").PubCompOpts;
pub const ErrorDetail = @import("mqtt.zig").ErrorDetail;

pub const Packet = @import("packets.zig").Packet;

/// Low-level codec functions for advanced use cases.
pub const codec = @import("codec.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("mqtt.zig");
    _ = @import("packets.zig");
    _ = @import("codec.zig");
}
