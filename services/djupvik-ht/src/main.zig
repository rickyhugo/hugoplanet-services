const std = @import("std");

const mqtt = @import("mqtt");

const log = std.log.scoped(.djupvik_ht);

const config = struct {
    const client_id = "djupvik-ht";
    const topics: []const []const u8 = &.{
        "sensors/#",
    };
    const keepalive_sec: u16 = 30;
    const connect_timeout_ms: i32 = 10_000;
    const read_timeout_ms: i32 = 5_000;
    const write_timeout_ms: i32 = 5_000;
    const max_retries: u16 = 3;
    const reconnect_delay_ms: u64 = 5_000;
};

var host: []const u8 = "localhost";
var port: u16 = 1883;
var username: ?[]const u8 = null;
var password: ?[]const u8 = null;

pub fn main() !void {
    if (std.posix.getenv("MQTT_HOST")) |v| host = v;
    if (std.posix.getenv("MQTT_PORT")) |v| port = std.fmt.parseInt(u16, v, 10) catch port;
    if (std.posix.getenv("MQTT_USERNAME")) |v| username = v;
    if (std.posix.getenv("MQTT_PASSWORD")) |v| password = v;

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
    try subscribeToTopics(client);
    try messageLoop(client);
}

fn sendConnect(client: *mqtt.Client) !void {
    log.debug("sending CONNECT...", .{});
    client.connect(.{ .timeout = config.connect_timeout_ms }, .{
        .client_id = config.client_id,
        .keepalive_sec = config.keepalive_sec,
        .clean_session = true,
        .username = username,
        .password = password,
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

fn subscribeToTopics(client: *mqtt.Client) !void {
    var topic_filters: [config.topics.len]mqtt.SubscribeOpts.Topic = undefined;
    for (config.topics, 0..) |topic, i| {
        topic_filters[i] = .{ .filter = topic, .qos = .at_least_once };
    }

    log.debug("subscribing to {d} topic(s) with QoS 1...", .{config.topics.len});

    const packet_id = client.subscribe(.{ .timeout = config.write_timeout_ms }, .{
        .topics = &topic_filters,
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
            for (config.topics, 0..) |topic, i| {
                const result = suback.result(i) catch |err| switch (err) {
                    error.Failure => {
                        log.err("subscription to '{s}' was rejected by server", .{topic});
                        return error.SubscriptionRejected;
                    },
                    else => {
                        log.err("invalid SUBACK result: {}", .{err});
                        return err;
                    },
                };
                log.info("subscribed to '{s}' (granted QoS={d})", .{ topic, @intFromEnum(result) });
            }
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
    // Send PINGREQ at half the keepalive interval to be safe
    const threshold_ms: i64 = @divFloor(keepalive_ms, 2);

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
    const health = client.checkHealth(threshold_ms);
    log.debug("health check: {} (threshold={d}ms)", .{ health, threshold_ms });
    switch (health) {
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

/// Parsed BTHome sensor reading from a BLE device
const SensorReading = struct {
    addr: []const u8 = "",
    rssi: ?i32 = null,
    local_name: []const u8 = "",
    battery: ?u8 = null,
    temperature: ?f64 = null,
    humidity: ?f64 = null,
    illuminance: ?f64 = null,
    motion: ?u8 = null,
    window: ?u8 = null,
    button: ?u16 = null,
    rotation: ?f64 = null,
    distance_mm: ?u16 = null,

    pub fn format(
        self: SensorReading,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("addr={s}", .{self.addr});
        if (self.rssi) |v| try writer.print(" rssi={d}", .{v});
        if (self.local_name.len > 0) try writer.print(" name={s}", .{self.local_name});
        if (self.battery) |v| try writer.print(" battery={d}%", .{v});
        if (self.temperature) |v| try writer.print(" temp={d:.1}C", .{v});
        if (self.humidity) |v| try writer.print(" humidity={d:.1}%", .{v});
        if (self.illuminance) |v| try writer.print(" lux={d:.1}", .{v});
        if (self.motion) |v| try writer.print(" motion={d}", .{v});
        if (self.window) |v| try writer.print(" window={d}", .{v});
        if (self.button) |v| try writer.print(" button={d}", .{v});
        if (self.rotation) |v| try writer.print(" rotation={d:.1}", .{v});
        if (self.distance_mm) |v| try writer.print(" dist={d}mm", .{v});
    }
};

fn processMessage(topic: []const u8, payload: []const u8) !void {
    _ = topic;

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch |err| {
        log.warn("failed to parse JSON: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        log.warn("expected JSON object", .{});
        return error.InvalidFormat;
    }

    var reading = SensorReading{};

    // Top-level fields
    if (root.object.get("addr")) |v| {
        if (v == .string) reading.addr = v.string;
    }
    if (root.object.get("rssi")) |v| {
        if (v == .integer) reading.rssi = @intCast(v.integer);
    }
    if (root.object.get("local_name")) |v| {
        if (v == .string) reading.local_name = v.string;
    }

    // service_data contains the actual sensor values
    if (root.object.get("service_data")) |sd| {
        if (sd == .object) {
            reading.battery = getIntField(u8, sd.object, "battery");
            reading.temperature = getFloatField(sd.object, "temperature");
            reading.humidity = getFloatField(sd.object, "humidity");
            reading.illuminance = getFloatField(sd.object, "illuminance");
            reading.motion = getIntField(u8, sd.object, "motion");
            reading.window = getIntField(u8, sd.object, "window");
            reading.button = getIntField(u16, sd.object, "button");
            reading.rotation = getFloatField(sd.object, "rotation");
            reading.distance_mm = getIntField(u16, sd.object, "distance_mm");
        }
    }

    log.info("sensor: {any}", .{reading});
}

fn getIntField(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| std.math.cast(T, i),
        .float => |f| std.math.lossyCast(T, f),
        else => null,
    };
}

fn getFloatField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
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

test "parseSensorReading parses BTHome JSON" {
    const payload =
        \\{"addr":"aa:bb:cc:dd:ee:ff","rssi":-65,"local_name":"SBBT-002C","service_data":{"BTHome_version":2,"encryption":false,"battery":95,"temperature":22.5,"humidity":45.2}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root == .object);

    // Check top-level fields
    try std.testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", root.object.get("addr").?.string);
    try std.testing.expectEqual(@as(i64, -65), root.object.get("rssi").?.integer);
    try std.testing.expectEqualStrings("SBBT-002C", root.object.get("local_name").?.string);

    // Check service_data
    const sd = root.object.get("service_data").?.object;
    try std.testing.expectEqual(@as(i64, 95), sd.get("battery").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 22.5), sd.get("temperature").?.float, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 45.2), sd.get("humidity").?.float, 0.01);
}

test "getIntField handles integer and float" {
    const payload =
        \\{"int_val":42,"float_val":3.7}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(?u8, 42), getIntField(u8, obj, "int_val"));
    try std.testing.expectEqual(@as(?u8, 3), getIntField(u8, obj, "float_val"));
    try std.testing.expectEqual(@as(?u8, null), getIntField(u8, obj, "missing"));
}

test "getFloatField handles integer and float" {
    const payload =
        \\{"int_val":42,"float_val":3.14}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(?f64, 42.0), getFloatField(obj, "int_val"));
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), getFloatField(obj, "float_val").?, 0.001);
    try std.testing.expectEqual(@as(?f64, null), getFloatField(obj, "missing"));
}
