const std = @import("std");
const builtin = @import("builtin");

const mqtt = @import("mqtt.zig");

const native_endian = builtin.cpu.arch.endian();

pub inline fn readInt(
    comptime T: type,
    buf: *const [@divExact(@typeInfo(T).int.bits, 8)]u8,
) T {
    const value: T = @bitCast(buf.*);
    return if (native_endian == .big) value else @byteSwap(value);
}

pub inline fn writeInt(
    comptime T: type,
    buf: *[@divExact(@typeInfo(T).int.bits, 8)]u8,
    value: T,
) void {
    buf.* = @bitCast(if (native_endian == .big) value else @byteSwap(value));
}

pub fn readString(buf: []const u8) error{InvalidString}!struct { []const u8, usize } {
    if (buf.len < 2) {
        return error.InvalidString;
    }
    const len = readInt(u16, buf[0..2]);
    const end = len + 2;
    if (buf.len < end) {
        return error.InvalidString;
    }
    return .{ buf[2..end], end };
}

pub fn writeString(buf: []u8, value: []const u8) error{WriteBufferFull}!usize {
    const total = value.len + 2;
    if (buf.len < total) {
        return error.WriteBufferFull;
    }

    writeInt(u16, buf[0..2], @intCast(value.len));
    @memcpy(buf[2..total], value);
    return total;
}

pub fn writeVarint(buf: []u8, len: usize) error{ WriteBufferFull, ValueTooLarge }!usize {
    if (len > 268_435_455) return error.ValueTooLarge;

    var i: usize = 0;
    var remaining = len;
    while (true) : (i += 1) {
        if (i >= buf.len) return error.WriteBufferFull;

        const b: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;

        if (remaining == 0) {
            buf[i] = b;
            return i + 1;
        }

        buf[i] = b | 0x80;
    }
}

// This returns the varint value (if we have one) AND the length of the varint
pub fn readVarint(buf: []const u8) error{InvalidVarint}!?struct { usize, usize } {
    if (buf.len == 0) {
        return null;
    }

    if (buf[0] < 128) {
        return .{ @as(usize, @intCast(buf[0])), 1 };
    }

    if (buf.len == 1) {
        return null;
    }

    var total: usize = buf[0] & 0x7f;
    if (buf[1] < 128) {
        return .{ total + @as(usize, buf[1]) * 128, 2 };
    }

    if (buf.len == 2) {
        return null;
    }
    total += (@as(usize, buf[1]) & 0x7f) * 128;
    if (buf[2] < 128) {
        return .{ total + @as(usize, buf[2]) * 16_384, 3 };
    }

    if (buf.len == 3) {
        return null;
    }
    total += (@as(usize, buf[2]) & 0x7f) * 16_384;
    if (buf[3] < 128) {
        return .{ total + @as(usize, buf[3]) * 2_097_152, 4 };
    }

    return error.InvalidVarint;
}

pub fn calcLengthOfVarint(len: usize) usize {
    return switch (len) {
        0...127 => 1,
        128...16_383 => 2,
        16_384...2_097_151 => 3,
        2_097_152...268_435_455 => 4,
        else => unreachable,
    };
}

// Maximum length of MQTT fixed header: 1 byte packet type + 4 bytes max varint length
const MAX_FIXED_HEADER_LEN = 5;

pub const PublishFlags = packed struct(u4) {
    dup: bool,
    qos: mqtt.QoS,
    retain: bool,
};

pub fn encodePacketHeader(buf: []u8, packet_type: u8, packet_flags: u8) ![]u8 {
    const remaining_len = buf.len - MAX_FIXED_HEADER_LEN;
    const length_of_len = calcLengthOfVarint(remaining_len);

    // This is where, in buf, our packet is actually going to start. You'd think
    // it would start at buf[0], but the package length is variable, so it'll
    // only start at buf[0] in the [unlikely] case where the length took 4 bytes.
    const start = MAX_FIXED_HEADER_LEN - length_of_len - 1;

    buf[start] = (packet_type << 4) | packet_flags;
    _ = try writeVarint(buf[start + 1 ..], remaining_len);
    return buf[start..];
}

pub fn encodeConnect(buf: []u8, opts: mqtt.ConnectOpts) ![]u8 {
    var connect_flags = packed struct(u8) {
        _reserved: bool = false,
        clean_session: bool,
        will: bool = false,
        will_qos: mqtt.QoS = .at_most_once,
        will_retain: bool = false,
        username: bool,
        password: bool,
    }{
        .clean_session = opts.clean_session,
        .username = opts.username != null,
        .password = opts.password != null,
    };

    if (opts.will) |w| {
        connect_flags.will = true;
        connect_flags.will_qos = w.qos;
        connect_flags.will_retain = w.retain;
    }

    buf[MAX_FIXED_HEADER_LEN] = 0;
    buf[MAX_FIXED_HEADER_LEN + 1] = 4;
    buf[MAX_FIXED_HEADER_LEN + 2] = 'M';
    buf[MAX_FIXED_HEADER_LEN + 3] = 'Q';
    buf[MAX_FIXED_HEADER_LEN + 4] = 'T';
    buf[MAX_FIXED_HEADER_LEN + 5] = 'T';
    buf[MAX_FIXED_HEADER_LEN + 6] = 4;

    buf[MAX_FIXED_HEADER_LEN + 7] = @bitCast(connect_flags);

    writeInt(u16, buf[MAX_FIXED_HEADER_LEN + 8 ..][0..2], opts.keepalive_sec);

    const PAYLOAD_OFFSET = MAX_FIXED_HEADER_LEN + 10;

    var pos: usize = PAYLOAD_OFFSET;
    pos += try writeString(buf[pos..], opts.client_id orelse "");

    if (opts.will) |will| {
        pos += try writeString(buf[pos..], will.topic);
        pos += try writeString(buf[pos..], will.message);
    }

    if (opts.username) |username| {
        pos += try writeString(buf[pos..], username);
    }

    if (opts.password) |password| {
        pos += try writeString(buf[pos..], password);
    }

    return encodePacketHeader(buf[0..pos], 1, 0);
}

pub fn encodeSubscribe(
    buf: []u8,
    packet_identifier: u16,
    opts: mqtt.SubscribeOpts,
) ![]u8 {
    // reserve MAX_FIXED_HEADER_LEN bytes for the fixed header
    writeInt(u16, buf[MAX_FIXED_HEADER_LEN..][0..2], packet_identifier);

    const PAYLOAD_OFFSET = MAX_FIXED_HEADER_LEN + 2;
    var pos: usize = PAYLOAD_OFFSET;
    for (opts.topics) |topic| {
        pos += try writeString(buf[pos..], topic.filter);
        buf[pos] = @intFromEnum(topic.qos);
        pos += 1;
    }

    return encodePacketHeader(buf[0..pos], 8, 2);
}

pub fn encodeUnsubscribe(
    buf: []u8,
    packet_identifier: u16,
    opts: mqtt.UnsubscribeOpts,
) ![]u8 {
    // reserve MAX_FIXED_HEADER_LEN bytes for the fixed header
    writeInt(u16, buf[MAX_FIXED_HEADER_LEN..][0..2], packet_identifier);

    const PAYLOAD_OFFSET = MAX_FIXED_HEADER_LEN + 2;
    var pos: usize = PAYLOAD_OFFSET;
    for (opts.topics) |topic| {
        pos += try writeString(buf[pos..], topic);
    }

    return encodePacketHeader(buf[0..pos], 10, 2);
}

pub fn encodePublish(
    buf: []u8,
    packet_identifier: ?u16,
    opts: mqtt.PublishOpts,
) ![]u8 {
    // Validate topic per MQTT 3.1.1 spec
    if (opts.topic.len == 0) return error.EmptyTopic;
    if (opts.topic.len > 65535) return error.TopicTooLong;
    // PUBLISH topics must not contain wildcards
    if (std.mem.indexOfAny(u8, opts.topic, "#+")) |_| return error.InvalidTopicCharacter;

    const publish_flags = PublishFlags{
        .dup = opts.dup,
        .qos = opts.qos,
        .retain = opts.retain,
    };

    // reserve MAX_FIXED_HEADER_LEN bytes for the fixed header
    const topic_len = try writeString(buf[MAX_FIXED_HEADER_LEN..], opts.topic);

    var payload_offset = MAX_FIXED_HEADER_LEN + topic_len;
    if (packet_identifier) |pi| {
        writeInt(u16, buf[payload_offset..][0..2], pi);
        payload_offset += 2;
    }

    const message = opts.message;
    const end = payload_offset + message.len;
    if (end > buf.len) {
        return error.WriteBufferFull;
    }

    @memcpy(buf[payload_offset..end], message);
    return encodePacketHeader(buf[0..end], 3, @as(u4, @bitCast(publish_flags)));
}

pub fn encodePubAck(buf: []u8, opts: mqtt.PubAckOpts) ![]u8 {
    // reserve MAX_FIXED_HEADER_LEN bytes for the fixed header
    // MQTT 3.1.1: only packet identifier (2 bytes)
    writeInt(u16, buf[MAX_FIXED_HEADER_LEN..][0..2], opts.packet_identifier);
    return encodePacketHeader(buf[0 .. MAX_FIXED_HEADER_LEN + 2], 4, 0);
}

pub fn encodePubRec(buf: []u8, opts: mqtt.PubRecOpts) ![]u8 {
    // reserve MAX_FIXED_HEADER_LEN bytes for the fixed header
    // MQTT 3.1.1: only packet identifier (2 bytes)
    writeInt(u16, buf[MAX_FIXED_HEADER_LEN..][0..2], opts.packet_identifier);
    return encodePacketHeader(buf[0 .. MAX_FIXED_HEADER_LEN + 2], 5, 0);
}

pub fn encodePubRel(buf: []u8, opts: mqtt.PubRelOpts) ![]u8 {
    // reserve MAX_FIXED_HEADER_LEN bytes for the fixed header
    // MQTT 3.1.1: only packet identifier (2 bytes), flags must be 0010
    writeInt(u16, buf[MAX_FIXED_HEADER_LEN..][0..2], opts.packet_identifier);
    return encodePacketHeader(buf[0 .. MAX_FIXED_HEADER_LEN + 2], 6, 2);
}

pub fn encodePubComp(buf: []u8, opts: mqtt.PubCompOpts) ![]u8 {
    // reserve MAX_FIXED_HEADER_LEN bytes for the fixed header
    // MQTT 3.1.1: only packet identifier (2 bytes)
    writeInt(u16, buf[MAX_FIXED_HEADER_LEN..][0..2], opts.packet_identifier);
    return encodePacketHeader(buf[0 .. MAX_FIXED_HEADER_LEN + 2], 7, 0);
}

pub fn encodeDisconnect(buf: []u8) ![]u8 {
    // In MQTT 3.1.1, DISCONNECT has no variable header (only fixed header)
    return encodePacketHeader(buf[0..MAX_FIXED_HEADER_LEN], 14, 0);
}

test "readInt/writeInt u16 big-endian" {
    var buf: [2]u8 = undefined;
    writeInt(u16, &buf, 0x1234);
    try std.testing.expectEqual([_]u8{ 0x12, 0x34 }, buf);
    try std.testing.expectEqual(@as(u16, 0x1234), readInt(u16, &buf));
}

test "readInt/writeInt u16 boundary values" {
    var buf: [2]u8 = undefined;

    writeInt(u16, &buf, 0);
    try std.testing.expectEqual(@as(u16, 0), readInt(u16, &buf));

    writeInt(u16, &buf, 0xFFFF);
    try std.testing.expectEqual(@as(u16, 0xFFFF), readInt(u16, &buf));

    writeInt(u16, &buf, 0x0100); // 256
    try std.testing.expectEqual([_]u8{ 0x01, 0x00 }, buf);
}

test "writeVarint single byte values" {
    var buf: [4]u8 = undefined;

    // 0 encodes to single byte 0x00
    try std.testing.expectEqual(@as(usize, 1), try writeVarint(&buf, 0));
    try std.testing.expectEqual(@as(u8, 0), buf[0]);

    // 127 is max single byte value
    try std.testing.expectEqual(@as(usize, 1), try writeVarint(&buf, 127));
    try std.testing.expectEqual(@as(u8, 127), buf[0]);
}

test "writeVarint multi-byte values" {
    var buf: [4]u8 = undefined;

    // 128 requires 2 bytes: 0x80 0x01
    try std.testing.expectEqual(@as(usize, 2), try writeVarint(&buf, 128));
    try std.testing.expectEqual([_]u8{ 0x80, 0x01 }, buf[0..2].*);

    // 16383 is max 2-byte value: 0xFF 0x7F
    try std.testing.expectEqual(@as(usize, 2), try writeVarint(&buf, 16383));
    try std.testing.expectEqual([_]u8{ 0xFF, 0x7F }, buf[0..2].*);

    // 16384 requires 3 bytes: 0x80 0x80 0x01
    try std.testing.expectEqual(@as(usize, 3), try writeVarint(&buf, 16384));
    try std.testing.expectEqual([_]u8{ 0x80, 0x80, 0x01 }, buf[0..3].*);

    // 2097151 is max 3-byte value
    try std.testing.expectEqual(@as(usize, 3), try writeVarint(&buf, 2097151));
    try std.testing.expectEqual([_]u8{ 0xFF, 0xFF, 0x7F }, buf[0..3].*);

    // 2097152 requires 4 bytes
    try std.testing.expectEqual(@as(usize, 4), try writeVarint(&buf, 2097152));
    try std.testing.expectEqual([_]u8{ 0x80, 0x80, 0x80, 0x01 }, buf[0..4].*);

    // max MQTT varint value: 268435455
    try std.testing.expectEqual(@as(usize, 4), try writeVarint(&buf, 268435455));
    try std.testing.expectEqual([_]u8{ 0xFF, 0xFF, 0xFF, 0x7F }, buf[0..4].*);
}

test "writeVarint errors" {
    var buf: [4]u8 = undefined;

    // Value too large (exceeds MQTT max)
    try std.testing.expectError(error.ValueTooLarge, writeVarint(&buf, 268435456));

    // Buffer too small
    var small_buf: [1]u8 = undefined;
    try std.testing.expectError(error.WriteBufferFull, writeVarint(&small_buf, 128));
}

test "readVarint single byte" {
    const result = try readVarint(&[_]u8{0x00});
    try std.testing.expectEqual(@as(usize, 0), result.?[0]);
    try std.testing.expectEqual(@as(usize, 1), result.?[1]);

    const result2 = try readVarint(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(usize, 127), result2.?[0]);
    try std.testing.expectEqual(@as(usize, 1), result2.?[1]);
}

test "readVarint multi-byte" {
    // 128 = 0x80 0x01
    const result = try readVarint(&[_]u8{ 0x80, 0x01 });
    try std.testing.expectEqual(@as(usize, 128), result.?[0]);
    try std.testing.expectEqual(@as(usize, 2), result.?[1]);

    // 16383 = 0xFF 0x7F
    const result2 = try readVarint(&[_]u8{ 0xFF, 0x7F });
    try std.testing.expectEqual(@as(usize, 16383), result2.?[0]);
    try std.testing.expectEqual(@as(usize, 2), result2.?[1]);

    // 16384 = 0x80 0x80 0x01
    const result3 = try readVarint(&[_]u8{ 0x80, 0x80, 0x01 });
    try std.testing.expectEqual(@as(usize, 16384), result3.?[0]);
    try std.testing.expectEqual(@as(usize, 3), result3.?[1]);

    // max value 268435455 = 0xFF 0xFF 0xFF 0x7F
    const result4 = try readVarint(&[_]u8{ 0xFF, 0xFF, 0xFF, 0x7F });
    try std.testing.expectEqual(@as(usize, 268435455), result4.?[0]);
    try std.testing.expectEqual(@as(usize, 4), result4.?[1]);
}

test "readVarint incomplete returns null" {
    // Empty buffer
    try std.testing.expectEqual(@as(?struct { usize, usize }, null), try readVarint(&[_]u8{}));

    // Continuation bit set but no next byte
    try std.testing.expectEqual(@as(?struct { usize, usize }, null), try readVarint(&[_]u8{0x80}));
    try std.testing.expectEqual(@as(?struct { usize, usize }, null), try readVarint(&[_]u8{ 0x80, 0x80 }));
    try std.testing.expectEqual(@as(?struct { usize, usize }, null), try readVarint(&[_]u8{ 0x80, 0x80, 0x80 }));
}

test "readVarint invalid (5th continuation bit)" {
    // 5 bytes with continuation bits - invalid per MQTT spec
    try std.testing.expectError(error.InvalidVarint, readVarint(&[_]u8{ 0x80, 0x80, 0x80, 0x80 }));
}

test "varint roundtrip" {
    const test_values = [_]usize{ 0, 1, 127, 128, 255, 16383, 16384, 2097151, 2097152, 268435455 };
    var buf: [4]u8 = undefined;

    for (test_values) |value| {
        const written = try writeVarint(&buf, value);
        const result = try readVarint(buf[0..written]);
        try std.testing.expectEqual(value, result.?[0]);
        try std.testing.expectEqual(written, result.?[1]);
    }
}

test "calcLengthOfVarint" {
    try std.testing.expectEqual(@as(usize, 1), calcLengthOfVarint(0));
    try std.testing.expectEqual(@as(usize, 1), calcLengthOfVarint(127));
    try std.testing.expectEqual(@as(usize, 2), calcLengthOfVarint(128));
    try std.testing.expectEqual(@as(usize, 2), calcLengthOfVarint(16383));
    try std.testing.expectEqual(@as(usize, 3), calcLengthOfVarint(16384));
    try std.testing.expectEqual(@as(usize, 3), calcLengthOfVarint(2097151));
    try std.testing.expectEqual(@as(usize, 4), calcLengthOfVarint(2097152));
    try std.testing.expectEqual(@as(usize, 4), calcLengthOfVarint(268435455));
}

test "writeString/readString roundtrip" {
    var buf: [100]u8 = undefined;

    const test_strings = [_][]const u8{ "", "a", "hello", "hello/world/topic" };
    for (test_strings) |str| {
        const written = try writeString(&buf, str);
        const result = try readString(buf[0..written]);
        try std.testing.expectEqualStrings(str, result[0]);
        try std.testing.expectEqual(written, result[1]);
    }
}

test "writeString length encoding" {
    var buf: [100]u8 = undefined;

    // Empty string: length 0x0000
    _ = try writeString(&buf, "");
    try std.testing.expectEqual([_]u8{ 0x00, 0x00 }, buf[0..2].*);

    // "AB": length 0x0002
    _ = try writeString(&buf, "AB");
    try std.testing.expectEqual([_]u8{ 0x00, 0x02, 'A', 'B' }, buf[0..4].*);
}

test "readString errors" {
    // Buffer too small for length prefix
    try std.testing.expectError(error.InvalidString, readString(&[_]u8{0x00}));

    // Length exceeds buffer
    try std.testing.expectError(error.InvalidString, readString(&[_]u8{ 0x00, 0x05, 'a', 'b' }));
}

test "writeString buffer full" {
    var buf: [3]u8 = undefined;
    // Need 2 bytes for length + 2 bytes for "ab" = 4 bytes, but only have 3
    try std.testing.expectError(error.WriteBufferFull, writeString(&buf, "ab"));
}

test "encodeConnect minimal" {
    var buf: [100]u8 = undefined;

    const packet = try encodeConnect(&buf, .{});

    // Fixed header: type 1 (CONNECT), flags 0
    try std.testing.expectEqual(@as(u8, 0x10), packet[0]);

    // Variable header starts after fixed header
    // Protocol name length (2) + "MQTT" (4) + protocol level (1) + flags (1) + keepalive (2) = 10
    // Payload: client_id length (2) + "" (0) = 2
    // Total remaining length = 12
    try std.testing.expectEqual(@as(u8, 12), packet[1]);

    // Protocol name: 0x00 0x04 "MQTT"
    try std.testing.expectEqual([_]u8{ 0x00, 0x04, 'M', 'Q', 'T', 'T' }, packet[2..8].*);

    // Protocol level 4 (MQTT 3.1.1)
    try std.testing.expectEqual(@as(u8, 4), packet[8]);

    // Connect flags: clean_session=1, others=0 -> 0x02
    try std.testing.expectEqual(@as(u8, 0x02), packet[9]);

    // Keepalive: 0
    try std.testing.expectEqual([_]u8{ 0x00, 0x00 }, packet[10..12].*);

    // Client ID: empty string
    try std.testing.expectEqual([_]u8{ 0x00, 0x00 }, packet[12..14].*);
}

test "encodeConnect with options" {
    var buf: [200]u8 = undefined;

    const packet = try encodeConnect(&buf, .{
        .client_id = "test-client",
        .username = "user",
        .password = "pass",
        .keepalive_sec = 60,
        .clean_session = false,
    });

    // Fixed header
    try std.testing.expectEqual(@as(u8, 0x10), packet[0]);

    // Protocol level
    try std.testing.expectEqual(@as(u8, 4), packet[8]);

    // Connect flags: username=1, password=1, clean_session=0 -> 0xC0
    try std.testing.expectEqual(@as(u8, 0xC0), packet[9]);

    // Keepalive: 60 = 0x003C
    try std.testing.expectEqual([_]u8{ 0x00, 0x3C }, packet[10..12].*);

    // Client ID
    const client_id_result = try readString(packet[12..]);
    try std.testing.expectEqualStrings("test-client", client_id_result[0]);

    // Username follows client ID
    const username_result = try readString(packet[12 + client_id_result[1] ..]);
    try std.testing.expectEqualStrings("user", username_result[0]);

    // Password follows username
    const password_result = try readString(packet[12 + client_id_result[1] + username_result[1] ..]);
    try std.testing.expectEqualStrings("pass", password_result[0]);
}

test "encodeConnect with will" {
    var buf: [200]u8 = undefined;

    const packet = try encodeConnect(&buf, .{
        .client_id = "test",
        .will = .{
            .topic = "will/topic",
            .message = "goodbye",
            .qos = .at_least_once,
            .retain = true,
        },
    });

    // Connect flags: will=1, will_qos=1, will_retain=1, clean_session=1
    // Bits: 0 0 1 0 1 1 1 0 = 0x2E
    //       | | | | | | | +- reserved (0)
    //       | | | | | | +--- clean_session (1)
    //       | | | | | +----- will flag (1)
    //       | | | | +------- will qos bit 0 (1)
    //       | | | +--------- will qos bit 1 (0)
    //       | | +----------- will retain (1)
    //       | +------------- username (0)
    //       +--------------- password (0)
    try std.testing.expectEqual(@as(u8, 0x2E), packet[9]);
}

test "encodePublish QoS 0" {
    var buf: [100]u8 = undefined;

    const packet = try encodePublish(&buf, null, .{
        .topic = "test/topic",
        .message = "hello",
        .qos = .at_most_once,
    });

    // Fixed header: type 3 (PUBLISH), flags: dup=0, qos=0, retain=0 -> 0x30
    try std.testing.expectEqual(@as(u8, 0x30), packet[0]);

    // Remaining length: topic_len(2) + topic(10) + message(5) = 17
    try std.testing.expectEqual(@as(u8, 17), packet[1]);

    // Topic
    const topic_result = try readString(packet[2..]);
    try std.testing.expectEqualStrings("test/topic", topic_result[0]);

    // Message (no packet identifier for QoS 0)
    try std.testing.expectEqualStrings("hello", packet[2 + topic_result[1] ..]);
}

test "encodePublish QoS 1" {
    var buf: [100]u8 = undefined;

    const packet = try encodePublish(&buf, 42, .{
        .topic = "test/topic",
        .message = "hello",
        .qos = .at_least_once,
    });

    // Fixed header: type 3 (PUBLISH), flags: dup=0, qos=1, retain=0 -> 0x32
    try std.testing.expectEqual(@as(u8, 0x32), packet[0]);

    // Remaining length: topic_len(2) + topic(10) + packet_id(2) + message(5) = 19
    try std.testing.expectEqual(@as(u8, 19), packet[1]);

    // Topic
    const topic_result = try readString(packet[2..]);
    try std.testing.expectEqualStrings("test/topic", topic_result[0]);

    // Packet identifier
    const pi_offset = 2 + topic_result[1];
    try std.testing.expectEqual(@as(u16, 42), readInt(u16, packet[pi_offset..][0..2]));

    // Message
    try std.testing.expectEqualStrings("hello", packet[pi_offset + 2 ..]);
}

test "encodePublish with flags" {
    var buf: [100]u8 = undefined;

    const packet = try encodePublish(&buf, 1, .{
        .topic = "t",
        .message = "",
        .qos = .at_least_once,
        .dup = true,
        .retain = true,
    });

    // Fixed header: type 3, flags: dup=1, qos=1, retain=1
    // Flags bits (low nibble): retain(1) qos(01) dup(1) = 1011 = 0x0B
    // Full byte: 0x30 | 0x0B = 0x3B
    try std.testing.expectEqual(@as(u8, 0x3B), packet[0]);
}

test "encodePublish validation" {
    var buf: [100]u8 = undefined;

    // Empty topic
    try std.testing.expectError(error.EmptyTopic, encodePublish(&buf, null, .{
        .topic = "",
        .message = "test",
    }));

    // Wildcard in topic (not allowed in PUBLISH)
    try std.testing.expectError(error.InvalidTopicCharacter, encodePublish(&buf, null, .{
        .topic = "test/+/topic",
        .message = "test",
    }));

    try std.testing.expectError(error.InvalidTopicCharacter, encodePublish(&buf, null, .{
        .topic = "test/#",
        .message = "test",
    }));
}

test "encodeSubscribe" {
    var buf: [100]u8 = undefined;

    const packet = try encodeSubscribe(&buf, 1, .{
        .topics = &[_]mqtt.SubscribeOpts.Topic{
            .{ .filter = "test/topic", .qos = .at_least_once },
        },
    });

    // Fixed header: type 8 (SUBSCRIBE), flags must be 0x02 -> 0x82
    try std.testing.expectEqual(@as(u8, 0x82), packet[0]);

    // Packet identifier
    try std.testing.expectEqual(@as(u16, 1), readInt(u16, packet[2..4]));

    // Topic filter
    const topic_result = try readString(packet[4..]);
    try std.testing.expectEqualStrings("test/topic", topic_result[0]);

    // QoS
    try std.testing.expectEqual(@as(u8, 1), packet[4 + topic_result[1]]);
}

test "encodeSubscribe multiple topics" {
    var buf: [100]u8 = undefined;

    const packet = try encodeSubscribe(&buf, 100, .{
        .topics = &[_]mqtt.SubscribeOpts.Topic{
            .{ .filter = "a", .qos = .at_most_once },
            .{ .filter = "b", .qos = .at_least_once },
        },
    });

    // Packet identifier
    try std.testing.expectEqual(@as(u16, 100), readInt(u16, packet[2..4]));

    // First topic
    var offset: usize = 4;
    const topic1 = try readString(packet[offset..]);
    try std.testing.expectEqualStrings("a", topic1[0]);
    offset += topic1[1];
    try std.testing.expectEqual(@as(u8, 0), packet[offset]); // QoS 0
    offset += 1;

    // Second topic
    const topic2 = try readString(packet[offset..]);
    try std.testing.expectEqualStrings("b", topic2[0]);
    offset += topic2[1];
    try std.testing.expectEqual(@as(u8, 1), packet[offset]); // QoS 1
}

test "encodePubAck" {
    var buf: [10]u8 = undefined;

    const packet = try encodePubAck(&buf, .{ .packet_identifier = 0x1234 });

    // Fixed header: type 4 (PUBACK), flags 0 -> 0x40
    try std.testing.expectEqual(@as(u8, 0x40), packet[0]);

    // Remaining length: 2
    try std.testing.expectEqual(@as(u8, 2), packet[1]);

    // Packet identifier
    try std.testing.expectEqual(@as(u16, 0x1234), readInt(u16, packet[2..4]));
}

test "encodePubRec" {
    var buf: [10]u8 = undefined;

    const packet = try encodePubRec(&buf, .{ .packet_identifier = 0xABCD });

    // Fixed header: type 5 (PUBREC), flags 0 -> 0x50
    try std.testing.expectEqual(@as(u8, 0x50), packet[0]);
    try std.testing.expectEqual(@as(u8, 2), packet[1]);
    try std.testing.expectEqual(@as(u16, 0xABCD), readInt(u16, packet[2..4]));
}

test "encodePubRel" {
    var buf: [10]u8 = undefined;

    const packet = try encodePubRel(&buf, .{ .packet_identifier = 42 });

    // Fixed header: type 6 (PUBREL), flags must be 0x02 -> 0x62
    try std.testing.expectEqual(@as(u8, 0x62), packet[0]);
    try std.testing.expectEqual(@as(u8, 2), packet[1]);
    try std.testing.expectEqual(@as(u16, 42), readInt(u16, packet[2..4]));
}

test "encodePubComp" {
    var buf: [10]u8 = undefined;

    const packet = try encodePubComp(&buf, .{ .packet_identifier = 999 });

    // Fixed header: type 7 (PUBCOMP), flags 0 -> 0x70
    try std.testing.expectEqual(@as(u8, 0x70), packet[0]);
    try std.testing.expectEqual(@as(u8, 2), packet[1]);
    try std.testing.expectEqual(@as(u16, 999), readInt(u16, packet[2..4]));
}

test "encodeDisconnect" {
    var buf: [10]u8 = undefined;

    const packet = try encodeDisconnect(&buf);

    // Fixed header: type 14 (DISCONNECT), flags 0 -> 0xE0
    try std.testing.expectEqual(@as(u8, 0xE0), packet[0]);

    // Remaining length: 0
    try std.testing.expectEqual(@as(u8, 0), packet[1]);

    // Total packet length should be 2
    try std.testing.expectEqual(@as(usize, 2), packet.len);
}

test "encodeUnsubscribe" {
    var buf: [100]u8 = undefined;

    const topics = [_][]const u8{ "topic/a", "topic/b" };
    const packet = try encodeUnsubscribe(&buf, 55, .{
        .topics = &topics,
    });

    // Fixed header: type 10 (UNSUBSCRIBE), flags must be 0x02 -> 0xA2
    try std.testing.expectEqual(@as(u8, 0xA2), packet[0]);

    // Packet identifier
    try std.testing.expectEqual(@as(u16, 55), readInt(u16, packet[2..4]));

    // Topics
    var offset: usize = 4;
    const topic1 = try readString(packet[offset..]);
    try std.testing.expectEqualStrings("topic/a", topic1[0]);
    offset += topic1[1];

    const topic2 = try readString(packet[offset..]);
    try std.testing.expectEqualStrings("topic/b", topic2[0]);
}
