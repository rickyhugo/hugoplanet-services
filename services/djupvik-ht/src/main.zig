const std = @import("std");

const mqtt = @import("mqtt");

const log = std.log.scoped(.djupvik_ht);

const config = struct {
    const client_id = "djupvik-ht";
    const topic = "sensors/#";
    const keepalive_sec: u16 = 30;
    const connect_timeout_ms: i32 = 10_000;
    const read_timeout_ms: i32 = 5_000;
    const write_timeout_ms: i32 = 5_000;
    const max_retries: u16 = 3;
    const reconnect_delay_ms: u64 = 5_000;
};

var host: []const u8 = "localhost";
var port: u16 = 1883;

pub fn main() !void {
    if (std.posix.getenv("MQTT_HOST")) |v| host = v;
    if (std.posix.getenv("MQTT_PORT")) |v| port = std.fmt.parseInt(u16, v, 10) catch port;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    log.info("connecting to {s}:{d}", .{ host, port });

    runClient(gpa.allocator()) catch |err| {
        log.err("fatal error: {}", .{err});
        return err;
    };
}

fn runClient(allocator: std.mem.Allocator) !void {
    while (true) {
        log.info("connecting to {s}:{d}...", .{ host, port });

        var client = mqtt.Client.init(.{
            .host = host,
            .port = port,
            .allocator = allocator,
            .connect_timeout = config.connect_timeout_ms,
            .default_timeout = config.read_timeout_ms,
            .default_retries = config.max_retries,
        }) catch |err| {
            logMqttError(&err, null, "failed to initialize client");
            sleep(config.reconnect_delay_ms);
            continue;
        };
        defer {
            client.disconnect(.{}) catch {};
            client.deinit();
        }

        runSession(&client) catch |err| {
            logMqttError(&err, &client, "session error");
        };

        log.info("reconnecting in {d}ms...", .{config.reconnect_delay_ms});
        sleep(config.reconnect_delay_ms);
    }
}

fn sleep(ms: u64) void {
    std.posix.nanosleep(0, ms * std.time.ns_per_ms);
}

fn runSession(client: *mqtt.Client) !void {
    try sendConnect(client);
    try waitForConnack(client);
    try subscribeToTopic(client);
    try messageLoop(client);
}

fn sendConnect(client: *mqtt.Client) !void {
    log.debug("sending CONNECT...", .{});
    client.connect(.{ .timeout = config.connect_timeout_ms }, .{
        .client_id = config.client_id,
        .keepalive_sec = config.keepalive_sec,
        .clean_session = true,
    }) catch |err| {
        logMqttError(&err, client, "failed to send CONNECT");
        return err;
    };
}

fn waitForConnack(client: *mqtt.Client) !void {
    log.debug("waiting for CONNACK...", .{});
    const packet = client.readPacket(.{ .timeout = config.connect_timeout_ms }) catch |err| {
        logMqttError(&err, client, "failed to read CONNACK");
        return err;
    } orelse {
        log.err("timeout waiting for CONNACK", .{});
        return error.Timeout;
    };

    switch (packet) {
        .connack => |connack| {
            if (connack.return_code != .accepted) {
                log.err("connection refused: {}", .{connack.return_code});
                return error.ConnectionRefused;
            }
            log.info("connected (session_present={})", .{connack.session_present});
        },
        .disconnect => {
            log.err("server sent DISCONNECT during connection", .{});
            return error.ServerDisconnected;
        },
        else => {
            log.err("unexpected packet during connection: {}", .{std.meta.activeTag(packet)});
            return error.UnexpectedPacket;
        },
    }
}

fn subscribeToTopic(client: *mqtt.Client) !void {
    log.debug("subscribing to '{s}' with QoS 1...", .{config.topic});

    const packet_id = client.subscribe(.{ .timeout = config.write_timeout_ms }, .{
        .topics = &.{.{ .filter = config.topic, .qos = .at_least_once }},
    }) catch |err| {
        logMqttError(&err, client, "failed to send SUBSCRIBE");
        return err;
    };

    const packet = client.readPacket(.{ .timeout = config.read_timeout_ms }) catch |err| {
        logMqttError(&err, client, "failed to read SUBACK");
        return err;
    } orelse {
        log.err("timeout waiting for SUBACK", .{});
        return error.Timeout;
    };

    switch (packet) {
        .suback => |suback| {
            if (suback.packet_identifier != packet_id) {
                log.err("SUBACK packet_id mismatch: expected {d}, got {d}", .{ packet_id, suback.packet_identifier });
                return error.PacketIdMismatch;
            }
            const result = suback.result(0) catch |err| switch (err) {
                error.Failure => {
                    log.err("subscription to '{s}' was rejected by server", .{config.topic});
                    return error.SubscriptionRejected;
                },
                else => {
                    log.err("invalid SUBACK result: {}", .{err});
                    return err;
                },
            };
            log.info("subscribed to '{s}' (granted QoS={d})", .{ config.topic, @intFromEnum(result) });
        },
        .disconnect => {
            log.err("server sent DISCONNECT during subscription", .{});
            return error.ServerDisconnected;
        },
        else => {
            log.err("unexpected packet during subscription: {}", .{std.meta.activeTag(packet)});
            return error.UnexpectedPacket;
        },
    }
}

fn messageLoop(client: *mqtt.Client) !void {
    log.info("entering message loop...", .{});

    const keepalive_ms: i64 = @as(i64, config.keepalive_sec) * 1000;
    const threshold_ms: i64 = @divFloor(keepalive_ms * 3, 4);

    while (true) {
        try handleKeepalive(client, threshold_ms);

        const maybe_packet = client.readPacket(.{
            .timeout = @intCast(@min(threshold_ms, config.read_timeout_ms)),
        }) catch |err| {
            logMqttError(&err, client, "failed to read packet");
            return err;
        };

        const packet = maybe_packet orelse continue;

        switch (packet) {
            .publish => |publish| try handlePublish(client, publish),
            .pingresp => log.debug("received PINGRESP", .{}),
            .disconnect => {
                log.warn("server sent DISCONNECT", .{});
                return error.ServerDisconnected;
            },
            .suback => |p| log.debug("received unexpected SUBACK (packet_id={d})", .{p.packet_identifier}),
            .puback => |p| log.debug("received PUBACK (packet_id={d})", .{p.packet_identifier}),
            .pubrec => |p| log.debug("received unexpected PUBREC (packet_id={d})", .{p.packet_identifier}),
            .pubrel => |p| log.debug("received unexpected PUBREL (packet_id={d})", .{p.packet_identifier}),
            .pubcomp => |p| log.debug("received unexpected PUBCOMP (packet_id={d})", .{p.packet_identifier}),
            else => log.debug("received unexpected packet: {}", .{std.meta.activeTag(packet)}),
        }
    }
}

fn handleKeepalive(client: *mqtt.Client, threshold_ms: i64) !void {
    switch (client.checkHealth(threshold_ms)) {
        .ok => {},
        .stale => {
            log.debug("sending PINGREQ...", .{});
            client.pingreq(.{ .timeout = config.write_timeout_ms }) catch |err| {
                logMqttError(&err, client, "failed to send PINGREQ");
                return err;
            };
        },
        .unresponsive => {
            log.err("connection unresponsive (no PINGRESP received)", .{});
            return error.ConnectionLost;
        },
    }
}

fn handlePublish(client: *mqtt.Client, publish: mqtt.Packet.Publish) !void {
    log.info("message: topic='{s}' qos={d} retain={} dup={}", .{
        publish.topic, @intFromEnum(publish.qos), publish.retain, publish.dup,
    });

    const max_log_len = 256;
    if (publish.message.len <= max_log_len) {
        log.info(
            "  payload ({d} bytes): {s}",
            .{ publish.message.len, publish.message },
        );
    } else {
        log.info(
            "  payload ({d} bytes): {s}...",
            .{ publish.message.len, publish.message[0..max_log_len] },
        );
    }

    processMessage(publish.topic, publish.message) catch |err| {
        log.err("failed to process message: {}", .{err});
    };

    if (publish.qos == .at_least_once) {
        const packet_id = publish.packet_identifier orelse {
            log.err("QoS 1 message missing packet_identifier", .{});
            return error.MalformedPacket;
        };
        log.debug("sending PUBACK (packet_id={d})", .{packet_id});
        client.puback(.{ .timeout = config.write_timeout_ms }, .{
            .packet_identifier = packet_id,
        }) catch |err| {
            logMqttError(&err, client, "failed to send PUBACK");
            return err;
        };
    }
}

fn processMessage(topic: []const u8, payload: []const u8) !void {
    _ = topic;
    _ = payload;
}

fn logMqttError(err: *const anyerror, client: ?*mqtt.Client, context: []const u8) void {
    if (client) |c| {
        if (c.lastError()) |detail| {
            switch (detail) {
                .inner => |inner| log.err("{s}: {} (inner: {})", .{ context, err.*, inner }),
                .details => |msg| log.err("{s}: {} ({s})", .{ context, err.*, msg }),
            }
            return;
        }
    }
    log.err("{s}: {}", .{ context, err.* });
}

test "config defaults are valid" {
    try std.testing.expect(config.keepalive_sec > 0);
    try std.testing.expect(port > 0);
    try std.testing.expect(config.topic.len > 0);
    try std.testing.expect(config.client_id.len > 0);
}
