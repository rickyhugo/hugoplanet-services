const codec = @import("codec.zig");
const mqtt = @import("mqtt.zig");

pub const Packet = union(enum) {
    connack: ConnAck,
    suback: SubAck,
    unsuback: UnsubAck,
    publish: Publish,
    puback: PubAck,
    pubrec: PubRec,
    pubrel: PubRel,
    pubcomp: PubComp,
    disconnect: Disconnect,
    pingresp: void,

    pub const ConnAck = struct {
        session_present: bool,
        return_code: ReturnCode,

        // MQTT 3.1.1 Return Codes
        pub const ReturnCode = enum(u8) {
            accepted = 0,
            unacceptable_protocol_version = 1,
            identifier_rejected = 2,
            server_unavailable = 3,
            bad_username_or_password = 4,
            not_authorized = 5,
        };
    };

    // MQTT 3.1.1: SUBACK contains QoS granted (0,1,2) or protocol failure
    pub const SubAck = struct {
        packet_identifier: u16,
        results: []const u8,

        pub const Error = error{
            OutOfBounds,
            Failure,
            Protocol,
        };

        pub fn result(self: *const SubAck, topic_index: usize) Error!mqtt.QoS {
            if (topic_index >= self.results.len) {
                return error.OutOfBounds;
            }

            return switch (self.results[topic_index]) {
                0 => .at_most_once,
                1 => .at_least_once,
                2 => .exactly_once,
                128 => error.Failure,
                else => error.Protocol,
            };
        }
    };

    // MQTT 3.1.1: UNSUBACK is just packet identifier, no payload/results
    pub const UnsubAck = struct {
        packet_identifier: u16,
    };

    pub const Publish = struct {
        dup: bool,
        qos: mqtt.QoS,
        retain: bool,

        topic: []const u8,
        message: []const u8,
        // null when qos is .at_most_once
        packet_identifier: ?u16,
    };

    // MQTT 3.1.1: PUBACK is just packet identifier
    pub const PubAck = struct {
        packet_identifier: u16,
    };

    // MQTT 3.1.1: PUBREC is just packet identifier
    pub const PubRec = struct {
        packet_identifier: u16,
    };

    // MQTT 3.1.1: PUBREL is just packet identifier
    pub const PubRel = struct {
        packet_identifier: u16,
    };

    // MQTT 3.1.1: PUBCOMP is just packet identifier
    pub const PubComp = struct {
        packet_identifier: u16,
    };

    // MQTT 3.1.1: Server-sent DISCONNECT has no variable header
    // (In 3.1.1, servers typically just close the connection rather than sending DISCONNECT)
    pub const Disconnect = struct {};

    pub fn decode(b1: u8, data: []u8) !Packet {
        const flags: u4 = @intCast(b1 & 15);
        switch (b1 >> 4) {
            2 => return .{ .connack = try decodeConnAck(data, flags) },
            3 => return .{ .publish = try decodePublish(data, flags) },
            4 => return .{ .puback = try decodePubAck(data, flags) },
            5 => return .{ .pubrec = try decodePubRec(data, flags) },
            6 => return .{ .pubrel = try decodePubRel(data, flags) },
            7 => return .{ .pubcomp = try decodePubComp(data, flags) },
            9 => return .{ .suback = try decodeSubAck(data, flags) },
            11 => return .{ .unsuback = try decodeUnsubAck(data, flags) },
            13 => return if (flags == 0) .{ .pingresp = {} } else error.InvalidFlags,
            14 => return .{ .disconnect = try decodeDisconnect(data, flags) },
            else => return error.UnknownPacketType,
        }
    }
};

fn decodeConnAck(data: []u8, flags: u4) !Packet.ConnAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    // MQTT 3.1.1: must have exactly 2 bytes (Connect Acknowledge Flags, Return Code)
    if (data.len < 2) {
        return error.IncompletePacket;
    }

    const session_present = switch (data[0] & 0x01) {
        0 => false,
        1 => true,
        else => unreachable,
    };

    // MQTT 3.1.1: only bits 0 is used for session present, bits 1-7 must be 0
    if (data[0] & 0xFE != 0) {
        return error.MalformedPacket;
    }

    const return_code: Packet.ConnAck.ReturnCode = switch (data[1]) {
        0 => .accepted,
        1 => .unacceptable_protocol_version,
        2 => .identifier_rejected,
        3 => .server_unavailable,
        4 => .bad_username_or_password,
        5 => .not_authorized,
        else => return error.InvalidReasonCode,
    };

    return Packet.ConnAck{
        .session_present = session_present,
        .return_code = return_code,
    };
}

fn decodeSubAck(data: []u8, flags: u4) !Packet.SubAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    // MQTT 3.1.1: 2 for packet identifier, at least 1 for QoS byte
    const min_len: usize = 3;
    if (data.len < min_len) {
        return error.IncompletePacket;
    }

    var suback = Packet.SubAck{
        .packet_identifier = codec.readInt(u16, data[0..2]),
        .results = undefined,
    };

    const payload_offset: usize = 2;

    // the rest of the packet is the payload, and the payload is 1 or more
    // 1 byte reason codes. 1 reason code per subscribed topic (in the same order)
    // So if you subscribed to 2 topics and want to know the result of the 2nd one
    // you would check suback.results[1], or better for an enum value: suback.result(1).
    suback.results = data[payload_offset..];
    return suback;
}
fn decodeUnsubAck(data: []u8, flags: u4) !Packet.UnsubAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    // MQTT 3.1.1: just 2 bytes for packet identifier (no payload)
    if (data.len < 2) {
        return error.IncompletePacket;
    }

    return Packet.UnsubAck{
        .packet_identifier = codec.readInt(u16, data[0..2]),
    };
}
fn decodePublish(data: []u8, flags: u4) !Packet.Publish {
    // MQTT 3.1.1: 2 for topic length (empty topic + empty message)
    if (data.len < 2) {
        return error.IncompletePacket;
    }

    const publish_flags: codec.PublishFlags = @bitCast(flags);

    const topic, var message_offset = try codec.readString(data);
    var publish = Packet.Publish{
        .dup = publish_flags.dup,
        .qos = publish_flags.qos,
        .retain = publish_flags.retain,
        .topic = topic,
        .message = undefined,
        .packet_identifier = null,
    };

    if (publish.qos != .at_most_once) {
        // QoS 1 and 2 require a 2-byte packet identifier after the topic
        if (data.len < message_offset + 2) {
            return error.IncompletePacket;
        }

        const packet_identifier_offset = message_offset;
        message_offset += 2;
        publish.packet_identifier = codec.readInt(
            u16,
            data[packet_identifier_offset..message_offset][0..2],
        );
    }

    publish.message = data[message_offset..];
    return publish;
}
fn decodePubAck(data: []u8, flags: u4) !Packet.PubAck {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    // MQTT 3.1.1: only packet identifier (2 bytes)
    return .{
        .packet_identifier = codec.readInt(u16, data[0..2]),
    };
}

fn decodePubRec(data: []u8, flags: u4) !Packet.PubRec {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    // MQTT 3.1.1: only packet identifier (2 bytes)
    return .{
        .packet_identifier = codec.readInt(u16, data[0..2]),
    };
}
fn decodePubRel(data: []u8, flags: u4) !Packet.PubRel {
    if (flags != 2) {
        // MQTT 3.1.1 spec: PUBREL fixed header flags must be 0010
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    // MQTT 3.1.1: only packet identifier (2 bytes)
    return .{
        .packet_identifier = codec.readInt(u16, data[0..2]),
    };
}

fn decodePubComp(data: []u8, flags: u4) !Packet.PubComp {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    if (data.len < 2) {
        return error.IncompletePacket;
    }

    // MQTT 3.1.1: only packet identifier (2 bytes)
    return .{
        .packet_identifier = codec.readInt(u16, data[0..2]),
    };
}

fn decodeDisconnect(_: []u8, flags: u4) !Packet.Disconnect {
    if (flags != 0) {
        return error.InvalidFlags;
    }

    // MQTT 3.1.1: DISCONNECT has no variable header or payload
    return .{};
}

const std = @import("std");

test "Packet.decode dispatches correctly" {
    // CONNACK: type 2, flags 0
    var connack_data = [_]u8{ 0x00, 0x00 };
    const connack = try Packet.decode(0x20, &connack_data);
    try std.testing.expect(connack == .connack);

    // PINGRESP: type 13, flags 0
    const pingresp = try Packet.decode(0xD0, &[_]u8{});
    try std.testing.expect(pingresp == .pingresp);

    // DISCONNECT: type 14, flags 0
    const disconnect = try Packet.decode(0xE0, &[_]u8{});
    try std.testing.expect(disconnect == .disconnect);
}

test "Packet.decode unknown type" {
    // Type 0 is reserved
    try std.testing.expectError(error.UnknownPacketType, Packet.decode(0x00, &[_]u8{}));

    // Type 15 is reserved
    try std.testing.expectError(error.UnknownPacketType, Packet.decode(0xF0, &[_]u8{}));
}

test "decodeConnAck success" {
    // Session present = 0, return code = 0 (accepted)
    var data = [_]u8{ 0x00, 0x00 };
    const packet = try Packet.decode(0x20, &data);
    const connack = packet.connack;

    try std.testing.expectEqual(false, connack.session_present);
    try std.testing.expectEqual(Packet.ConnAck.ReturnCode.accepted, connack.return_code);
}

test "decodeConnAck session present" {
    var data = [_]u8{ 0x01, 0x00 };
    const packet = try Packet.decode(0x20, &data);

    try std.testing.expectEqual(true, packet.connack.session_present);
}

test "decodeConnAck return codes" {
    const test_cases = [_]struct { code: u8, expected: Packet.ConnAck.ReturnCode }{
        .{ .code = 0, .expected = .accepted },
        .{ .code = 1, .expected = .unacceptable_protocol_version },
        .{ .code = 2, .expected = .identifier_rejected },
        .{ .code = 3, .expected = .server_unavailable },
        .{ .code = 4, .expected = .bad_username_or_password },
        .{ .code = 5, .expected = .not_authorized },
    };

    for (test_cases) |tc| {
        var data = [_]u8{ 0x00, tc.code };
        const packet = try Packet.decode(0x20, &data);
        try std.testing.expectEqual(tc.expected, packet.connack.return_code);
    }
}

test "decodeConnAck invalid return code" {
    var data = [_]u8{ 0x00, 0x06 }; // 6 is not valid in MQTT 3.1.1
    try std.testing.expectError(error.InvalidReasonCode, Packet.decode(0x20, &data));
}

test "decodeConnAck invalid flags" {
    var data = [_]u8{ 0x00, 0x00 };
    // Flags should be 0, testing with flags = 1
    try std.testing.expectError(error.InvalidFlags, Packet.decode(0x21, &data));
}

test "decodeConnAck malformed (reserved bits set)" {
    // Bits 1-7 of byte 0 must be 0
    var data = [_]u8{ 0x02, 0x00 };
    try std.testing.expectError(error.MalformedPacket, Packet.decode(0x20, &data));
}

test "decodeConnAck incomplete" {
    var data = [_]u8{0x00};
    try std.testing.expectError(error.IncompletePacket, Packet.decode(0x20, &data));
}

test "decodePublish QoS 0" {
    // Topic: "t" (length 1), no packet identifier, message: "m"
    var data = [_]u8{ 0x00, 0x01, 't', 'm' };
    const packet = try Packet.decode(0x30, &data); // flags: dup=0, qos=0, retain=0
    const publish = packet.publish;

    try std.testing.expectEqual(false, publish.dup);
    try std.testing.expectEqual(mqtt.QoS.at_most_once, publish.qos);
    try std.testing.expectEqual(false, publish.retain);
    try std.testing.expectEqualStrings("t", publish.topic);
    try std.testing.expectEqualStrings("m", publish.message);
    try std.testing.expectEqual(@as(?u16, null), publish.packet_identifier);
}

test "decodePublish QoS 1" {
    // Topic: "ab" (length 2), packet identifier: 0x0064 (100), message: "xyz"
    var data = [_]u8{ 0x00, 0x02, 'a', 'b', 0x00, 0x64, 'x', 'y', 'z' };
    const packet = try Packet.decode(0x32, &data); // flags: qos=1
    const publish = packet.publish;

    try std.testing.expectEqual(mqtt.QoS.at_least_once, publish.qos);
    try std.testing.expectEqualStrings("ab", publish.topic);
    try std.testing.expectEqual(@as(?u16, 100), publish.packet_identifier);
    try std.testing.expectEqualStrings("xyz", publish.message);
}

test "decodePublish with flags" {
    // Topic: "t", message: empty
    var data = [_]u8{ 0x00, 0x01, 't', 0x00, 0x01 };
    // flags: dup=1, qos=1, retain=1 -> 1011 = 0x0B
    const packet = try Packet.decode(0x3B, &data);
    const publish = packet.publish;

    try std.testing.expectEqual(true, publish.dup);
    try std.testing.expectEqual(mqtt.QoS.at_least_once, publish.qos);
    try std.testing.expectEqual(true, publish.retain);
    try std.testing.expectEqual(@as(?u16, 1), publish.packet_identifier);
}

test "decodePublish empty message" {
    var data = [_]u8{ 0x00, 0x01, 't' };
    const packet = try Packet.decode(0x30, &data);

    try std.testing.expectEqualStrings("t", packet.publish.topic);
    try std.testing.expectEqualStrings("", packet.publish.message);
}

test "decodePublish incomplete" {
    // Too short for topic length
    var data1 = [_]u8{0x00};
    try std.testing.expectError(error.IncompletePacket, Packet.decode(0x30, &data1));

    // QoS 1 without packet identifier
    var data2 = [_]u8{ 0x00, 0x01, 't' };
    try std.testing.expectError(error.IncompletePacket, Packet.decode(0x32, &data2));
}

test "decodePubAck" {
    var data = [_]u8{ 0x12, 0x34 };
    const packet = try Packet.decode(0x40, &data);

    try std.testing.expectEqual(@as(u16, 0x1234), packet.puback.packet_identifier);
}

test "decodePubAck invalid flags" {
    var data = [_]u8{ 0x00, 0x01 };
    try std.testing.expectError(error.InvalidFlags, Packet.decode(0x41, &data));
}

test "decodePubAck incomplete" {
    var data = [_]u8{0x00};
    try std.testing.expectError(error.IncompletePacket, Packet.decode(0x40, &data));
}

test "decodePubRec" {
    var data = [_]u8{ 0xAB, 0xCD };
    const packet = try Packet.decode(0x50, &data);

    try std.testing.expectEqual(@as(u16, 0xABCD), packet.pubrec.packet_identifier);
}

test "decodePubRel" {
    var data = [_]u8{ 0x00, 0x2A }; // packet id = 42
    // PUBREL flags must be 0x02
    const packet = try Packet.decode(0x62, &data);

    try std.testing.expectEqual(@as(u16, 42), packet.pubrel.packet_identifier);
}

test "decodePubRel invalid flags" {
    var data = [_]u8{ 0x00, 0x01 };
    // PUBREL with flags 0 instead of required 2
    try std.testing.expectError(error.InvalidFlags, Packet.decode(0x60, &data));
}

test "decodePubComp" {
    var data = [_]u8{ 0x03, 0xE7 }; // packet id = 999
    const packet = try Packet.decode(0x70, &data);

    try std.testing.expectEqual(@as(u16, 999), packet.pubcomp.packet_identifier);
}

test "decodeSubAck" {
    // Packet identifier: 0x0001, results: [0x00, 0x01] (QoS 0, QoS 1)
    var data = [_]u8{ 0x00, 0x01, 0x00, 0x01 };
    const packet = try Packet.decode(0x90, &data);
    const suback = packet.suback;

    try std.testing.expectEqual(@as(u16, 1), suback.packet_identifier);
    try std.testing.expectEqual(@as(usize, 2), suback.results.len);

    // Test the result() helper
    try std.testing.expectEqual(mqtt.QoS.at_most_once, try suback.result(0));
    try std.testing.expectEqual(mqtt.QoS.at_least_once, try suback.result(1));
}

test "decodeSubAck failure result" {
    // Packet identifier: 0x0005, results: [0x80] (failure)
    var data = [_]u8{ 0x00, 0x05, 0x80 };
    const packet = try Packet.decode(0x90, &data);
    const suback = packet.suback;

    try std.testing.expectError(error.Failure, suback.result(0));
}

test "decodeSubAck invalid result code" {
    var data = [_]u8{ 0x00, 0x01, 0x03 }; // 0x03 is not valid (only 0,1,2,128)
    const packet = try Packet.decode(0x90, &data);

    try std.testing.expectError(error.Protocol, packet.suback.result(0));
}

test "decodeSubAck out of bounds" {
    var data = [_]u8{ 0x00, 0x01, 0x00 };
    const packet = try Packet.decode(0x90, &data);

    try std.testing.expectError(error.OutOfBounds, packet.suback.result(1));
}

test "decodeSubAck invalid flags" {
    var data = [_]u8{ 0x00, 0x01, 0x00 };
    try std.testing.expectError(error.InvalidFlags, Packet.decode(0x91, &data));
}

test "decodeSubAck incomplete" {
    // Need at least 3 bytes (2 for packet id, 1 for result)
    var data = [_]u8{ 0x00, 0x01 };
    try std.testing.expectError(error.IncompletePacket, Packet.decode(0x90, &data));
}

test "decodeUnsubAck" {
    var data = [_]u8{ 0x00, 0x37 }; // packet id = 55
    const packet = try Packet.decode(0xB0, &data);

    try std.testing.expectEqual(@as(u16, 55), packet.unsuback.packet_identifier);
}

test "decodeUnsubAck invalid flags" {
    var data = [_]u8{ 0x00, 0x01 };
    try std.testing.expectError(error.InvalidFlags, Packet.decode(0xB1, &data));
}

test "decodeUnsubAck incomplete" {
    var data = [_]u8{0x00};
    try std.testing.expectError(error.IncompletePacket, Packet.decode(0xB0, &data));
}

test "decodePingResp" {
    const packet = try Packet.decode(0xD0, &[_]u8{});
    try std.testing.expect(packet == .pingresp);
}

test "decodePingResp invalid flags" {
    try std.testing.expectError(error.InvalidFlags, Packet.decode(0xD1, &[_]u8{}));
}

test "decodeDisconnect" {
    const packet = try Packet.decode(0xE0, &[_]u8{});
    try std.testing.expect(packet == .disconnect);
}

test "decodeDisconnect invalid flags" {
    try std.testing.expectError(error.InvalidFlags, Packet.decode(0xE1, &[_]u8{}));
}
