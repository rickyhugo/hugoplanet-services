const std = @import("std");
const net = std.net;

const mqtt = @import("mqtt");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try mqtt.Client.init(.{
        .port = 1883,
        .host = "localhost",
        .allocator = allocator,
        .connect_timeout = 2000,
        .default_timeout = 2000,
        .default_retries = 2,
    });
    defer {
        client.disconnect(.{}) catch {};
        client.deinit();
    }

    _ = try client.connect(
        .{},
        .{ .client_id = "hugoplanet" },
    );

    if (try client.readPacket(.{})) |packet| switch (packet) {
        .disconnect => {
            std.debug.print("server disconnected us", .{});
            return;
        },
        .connack => {
            std.debug.print("connack: hugoplanet\n", .{});
        },
        else => {
            // The server should not send any other type of packet at this point
            // HOWEVER, we should probably handle this case better than an `unreachable`
            std.debug.print("unreachable; readPacket", .{});
        },
    };

    {
        const packet_identifier = try client.subscribe(
            .{},
            .{ .topics = &.{.{
                .filter = "test/receiver",
                .qos = .at_least_once,
            }} },
        );

        if (try client.readPacket(.{})) |packet| switch (packet) {
            .disconnect => {
                std.debug.print("server disconnected us", .{});
                return;
            },
            .suback => |s| {
                std.debug.assert(s.packet_identifier == packet_identifier);
                std.debug.print("suback: {}\n", .{s});
            },
            else => |err| {
                // The server should not send any other type of packet at this point
                // HOWEVER, we should probably handle this case better than an `unreachable`
                std.debug.print("unreachable; readPacket: {}\n", .{err});
            },
        };
    }

    var count: usize = 0;
    loop: while (true) {
        const packet = try client.readPacket(.{ .timeout = 1000 }) orelse {
            std.debug.print("Still waiting for messages...\n", .{});
            continue :loop;
        };

        switch (packet) {
            .publish => |*publish| {
                try client.puback(.{}, .{ .packet_identifier = publish.packet_identifier.? });

                std.debug.print("received\ntopic: {s}\n{s}\n\n", .{ publish.topic, publish.message });
                count += 1;
                if (count == 2) {
                    return;
                }
            },
            else => {
                // always have to be mindful of the bi-directional nature of MQTT
                // but in this case, nothing here should be possible.
                // client.readPacket handles `disconnect` and our above connect and
                // subscribe should have handled their corresponding connack and suback
                std.debug.print("unexpected packet: {any}\n", .{packet});
            },
        }
    }
}
