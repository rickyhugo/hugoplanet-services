const std = @import("std");
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const codec = @import("codec.zig");
const Packet = @import("packets.zig").Packet;

pub const QoS = enum(u2) {
    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,
};

pub const ConnectOpts = struct {
    client_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    will: ?Will = null,
    keepalive_sec: u16 = 0,
    clean_session: bool = true,

    pub const Will = struct {
        topic: []const u8,
        message: []const u8,
        qos: QoS,
        retain: bool,
    };
};

pub const SubscribeOpts = struct {
    packet_identifier: ?u16 = null,
    topics: []const Topic,

    pub const Topic = struct {
        filter: []const u8,
        qos: QoS = .at_most_once,
    };
};

pub const UnsubscribeOpts = struct {
    packet_identifier: ?u16 = null,
    topics: []const []const u8,
};

pub const PublishOpts = struct {
    topic: []const u8,
    message: []const u8,
    dup: bool = false,
    qos: QoS = .at_most_once,
    retain: bool = false,
    packet_identifier: ?u16 = null,
};

pub const PubAckOpts = struct {
    packet_identifier: u16,
};

pub const PubRecOpts = struct {
    packet_identifier: u16,
};

pub const PubRelOpts = struct {
    packet_identifier: u16,
};

pub const PubCompOpts = struct {
    packet_identifier: u16,
};

pub const ErrorDetail = union(enum) {
    inner: anyerror,
    details: []const u8,
};

const Address = struct {
    host: ?Host = null,
    address: ?net.Address = null,

    const Host = struct {
        port: u16,
        name: []const u8,
    };

    fn init(
        optional_host: ?[]const u8,
        optional_ip: ?[]const u8,
        port: u16,
    ) !Address {
        if (optional_ip) |ip| {
            return .{
                .address = try std.net.Address.parseIp(ip, port),
            };
        }

        const host = optional_host orelse return error.HostOrIPRequired;
        return .{ .host = .{ .name = host, .port = port } };
    }

    fn connect(
        self: *Address,
        allocator: ?Allocator,
        timeout: i32,
    ) !posix.socket_t {
        if (self.address) |addr| {
            return connectTo(addr, timeout);
        }

        // If we don't have an address, then we were given a host:ip.
        // The address can change (DNS can be updated), and there can be multiple
        // IPs, hence why we don't convert host:ip -> net.Address in init.
        const host = self.host.?;
        const list = try net.getAddressList(allocator.?, host.name, host.port);
        defer list.deinit();

        if (list.addrs.len == 0) {
            return error.UnknownHostName;
        }

        for (list.addrs) |addr| {
            return connectTo(addr, timeout) catch continue;
        }

        return posix.ConnectError.ConnectionRefused;
    }

    fn connectTo(addr: net.Address, timeout: i32) !posix.socket_t {
        const sock_flags =
            posix.SOCK.STREAM |
            posix.SOCK.NONBLOCK |
            posix.SOCK.CLOEXEC;

        const socket = try posix.socket(
            addr.any.family,
            sock_flags,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(socket);

        posix.connect(
            socket,
            &addr.any,
            addr.getOsSockLen(),
        ) catch |err| switch (err) {
            error.WouldBlock => {
                var fds = [1]posix.pollfd{.{
                    .fd = socket,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                if (try posix.poll(&fds, timeout) == 0) {
                    return error.Timeout;
                }

                if (fds[0].revents & posix.POLL.OUT != posix.POLL.OUT) {
                    return error.ConnectionRefused;
                }

                // if this returns void, then we've successfully connected
                try posix.getsockoptError(socket);
            },
            else => return err,
        };

        return socket;
    }
};

pub const Client = struct {
    // Our own wrapper around std.net.Address. Handles connect timeout and can
    // pickup DNS changes on reconnect.
    address: Address,

    read_pos: usize,
    read_len: usize,

    // if we own the read_buffer, it's our job to free it on deinit
    read_buf_own: bool,
    read_buf: []u8,

    // if we own the write_buffer, it's our job to free it on deinit
    write_buf_own: bool,
    write_buf: []u8,

    allocator: ?Allocator,

    connect_timeout: i32,

    // set when connect is called, can be unset on error
    // (indicating that we need to reconnect)
    socket: ?posix.socket_t,

    default_retries: u16,
    default_timeout: i32,

    // Many packets take an identifier, we increment this by one on each call
    packet_identifier: u16,

    last_error: ?ErrorDetail,

    // Timestamps for connection health tracking (milliseconds)
    last_recv_time: i64 = 0,
    last_send_time: i64 = 0,
    ping_sent_time: ?i64 = null,

    pub const HealthStatus = enum {
        ok,
        stale, // No recent activity, should send PINGREQ
        unresponsive, // PINGREQ sent but no response within threshold
    };

    pub const Opts = struct {
        port: u16 = 0,

        // either ip or host must be provided
        ip: ?[]const u8 = null,
        host: ?[]const u8 = null,

        connect_timeout: i32 = 10_000,
        default_retries: ?u16 = null,
        default_timeout: ?i32 = null,

        // required if host != null OR read_buffer == null OR write_buffer == null
        allocator: ?Allocator = null,

        // if null, we'll use allocator to create a buffer of read_buffer_size
        read_buf: ?[]u8 = null,
        read_buf_size: u16 = 8192,

        // if null, we'll use allocator to create a buffer of read_buffer_size
        write_buf: ?[]u8 = null,
        write_buf_size: u16 = 8192,
    };

    pub const ReadWriteOpts = struct {
        retries: ?u16 = null,
        timeout: ?i32 = null,
    };

    const Self = @This();

    pub fn init(opts: Opts) !Self {
        const allocator = opts.allocator;

        if (allocator == null and (opts.ip == null or opts.read_buf == null or opts.write_buf == null)) {
            return error.AllocatorRequired;
        }

        var read_buf_own = false;
        var read_buf = opts.read_buf;
        if (read_buf == null) {
            read_buf_own = true;
            read_buf = try allocator.?.alloc(u8, opts.read_buf_size);
        }
        errdefer if (read_buf_own) allocator.?.free(read_buf.?);

        var write_buf_own = false;
        var write_buf = opts.write_buf;
        if (write_buf == null) {
            write_buf_own = true;
            write_buf = try allocator.?.alloc(u8, opts.write_buf_size);
        }
        errdefer if (write_buf_own) allocator.?.free(write_buf.?);

        const address = try Address.init(opts.host, opts.ip, opts.port);

        return .{
            .socket = null,
            .address = address,
            .allocator = allocator,
            .read_pos = 0,
            .read_len = 0,
            .read_buf_own = read_buf_own,
            .read_buf = read_buf.?,
            .write_buf_own = write_buf_own,
            .write_buf = write_buf.?,
            .connect_timeout = opts.connect_timeout,
            .default_retries = opts.default_retries orelse 1,
            .default_timeout = opts.default_timeout orelse 5_000,
            .packet_identifier = 1,
            .last_error = null,
            .last_recv_time = 0,
            .last_send_time = 0,
            .ping_sent_time = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.close();

        if (self.read_buf_own) {
            self.allocator.?.free(self.read_buf);
        }

        if (self.write_buf_own) {
            self.allocator.?.free(self.write_buf);
        }
    }

    pub fn connect(self: *Self, rw: ReadWriteOpts, opts: ConnectOpts) !void {
        const connect_packet = try codec.encodeConnect(self.write_buf, opts);
        try self.write(&self.createContext(rw), connect_packet);
    }

    pub fn subscribe(self: *Self, rw: ReadWriteOpts, opts: SubscribeOpts) !u16 {
        if (opts.topics.len == 0) {
            self.last_error = .{ .details = "must have at least 1 topic" };
            return error.Usage;
        }

        const packet_identifier = self.packetIdentifier(opts.packet_identifier);
        const subscribe_packet = try codec.encodeSubscribe(
            self.write_buf,
            packet_identifier,
            opts,
        );
        try self.write(&self.createContext(rw), subscribe_packet);
        return packet_identifier;
    }

    pub fn unsubscribe(self: *Self, rw: ReadWriteOpts, opts: UnsubscribeOpts) !u16 {
        if (opts.topics.len == 0) {
            self.last_error = .{ .details = "must have at least 1 topic" };
            return error.Usage;
        }

        const packet_identifier = self.packetIdentifier(opts.packet_identifier);
        const unsubscribe_packet = try codec.encodeUnsubscribe(
            self.write_buf,
            packet_identifier,
            opts,
        );
        try self.write(&self.createContext(rw), unsubscribe_packet);
        return packet_identifier;
    }

    pub fn publish(self: *Self, rw: ReadWriteOpts, opts: PublishOpts) !?u16 {
        var packet_identifier: ?u16 = null;
        if (opts.qos != .at_most_once) {
            // when QoS > 0, we include a packet identifier
            packet_identifier = self.packetIdentifier(opts.packet_identifier);
        }

        const publish_packet = try codec.encodePublish(
            self.write_buf,
            packet_identifier,
            opts,
        );

        try self.write(&self.createContext(rw), publish_packet);
        return packet_identifier;
    }

    pub fn puback(self: *Self, rw: ReadWriteOpts, opts: PubAckOpts) !void {
        const puback_packet = try codec.encodePubAck(self.write_buf, opts);
        try self.write(&self.createContext(rw), puback_packet);
    }

    pub fn pubrec(self: *Self, rw: ReadWriteOpts, opts: PubRecOpts) !void {
        const pubrec_packet = try codec.encodePubRec(self.write_buf, opts);
        try self.write(&self.createContext(rw), pubrec_packet);
    }

    pub fn pubrel(self: *Self, rw: ReadWriteOpts, opts: PubRelOpts) !void {
        const pubrel_packet = try codec.encodePubRel(self.write_buf, opts);
        try self.write(&self.createContext(rw), pubrel_packet);
    }

    pub fn pubcomp(self: *Self, rw: ReadWriteOpts, opts: PubCompOpts) !void {
        const pubcomp_packet = try codec.encodePubComp(self.write_buf, opts);
        try self.write(&self.createContext(rw), pubcomp_packet);
    }

    pub fn pingreq(self: *Self, rw: ReadWriteOpts) !void {
        try self.write(&self.createContext(rw), &.{ 0xC0, 0x00 });
        self.ping_sent_time = std.time.milliTimestamp();
    }

    pub fn disconnect(self: *Self, rw: ReadWriteOpts) !void {
        if (self.socket == null) {
            return;
        }

        // copy so we can mutate
        var rw_copy = rw;
        if (rw.retries == null) {
            // unless a retry is explicit set, let's override the default, since we
            // don't want to reconnect just to disconnect.
            rw_copy.retries = 0;
        }

        defer self.close();

        const disconnect_packet = try codec.encodeDisconnect(self.write_buf);
        return self.write(&self.createContext(rw_copy), disconnect_packet);
    }

    pub fn lastError(self: *const Self) ?ErrorDetail {
        return self.last_error;
    }

    pub fn lastReadPacket(self: *const Self) []const u8 {
        return self.read_buf[0..self.read_pos];
    }

    /// Check connection health based on activity timestamps.
    /// `threshold_ms` is how long without activity before connection is considered stale.
    pub fn checkHealth(self: *const Self, threshold_ms: i64) HealthStatus {
        const now = std.time.milliTimestamp();

        // If we sent a ping and haven't received anything since, check if it's overdue
        if (self.ping_sent_time) |ping_time| {
            if (now - ping_time > threshold_ms) {
                return .unresponsive;
            }
            // Ping sent, still waiting (within threshold)
            return .ok;
        }

        // No pending ping - check if we need to send one
        const last_activity = @max(self.last_recv_time, self.last_send_time);
        if (last_activity > 0 and now - last_activity > threshold_ms) {
            return .stale;
        }

        return .ok;
    }

    fn close(self: *Self) void {
        if (self.socket) |socket| {
            posix.close(socket);
            self.socket = null;
        }
    }

    const Context = struct {
        retries: u16 = 1,
        timeout: i32 = 10_000,
    };

    fn packetIdentifier(self: *Self, explicit: ?u16) u16 {
        if (explicit) |packet_identifier| {
            return packet_identifier;
        }
        defer self.packet_identifier +%= 1;
        return self.packet_identifier;
    }

    fn createContext(self: *Self, rw: ReadWriteOpts) Context {
        return .{
            .retries = rw.retries orelse self.default_retries,
            .timeout = rw.timeout orelse self.default_timeout,
        };
    }

    fn getOrConnectSocket(self: *Self) !posix.socket_t {
        return self.socket orelse {
            const socket = try self.address.connect(
                self.allocator,
                self.connect_timeout,
            );
            self.socket = socket;
            return socket;
        };
    }

    fn handleError(self: *Self, retries: *u16) !posix.socket_t {
        self.close();

        const r = retries.*;
        if (r == 0) {
            return error.Closed;
        }

        const socket = try self.getOrConnectSocket();
        retries.* = r - 1;
        return socket;
    }

    pub fn readPacket(self: *Self, rw: ReadWriteOpts) !?Packet {
        var ctx = self.createContext(rw);

        const packet = (try self.readOrBuffered(&ctx)) orelse return null;
        switch (packet) {
            .connack => |*connack| try self.processConnack(connack),
            else => {},
        }
        return packet;
    }

    fn processConnack(self: *Self, connack: *const Packet.ConnAck) !void {
        if (connack.return_code != .accepted) {
            self.close();

            self.last_error = .{
                .details = switch (connack.return_code) {
                    .accepted => unreachable,
                    .unacceptable_protocol_version => "connection refused: unacceptable protocol version",
                    .identifier_rejected => "connection refused: client identifier rejected",
                    .server_unavailable => "connection refused: server unavailable",
                    .bad_username_or_password => "connection refused: bad username or password",
                    .not_authorized => "connection refused: not authorized",
                },
            };

            return error.ConnectionRefused;
        }
    }

    fn readOrBuffered(self: *Self, ctx: *Context) !?Packet {
        if (try self.bufferedPacket()) |buffered_packet| {
            return buffered_packet;
        }

        var buf = self.read_buf;
        var pos = self.read_len;

        if (pos > 0 and pos == self.read_pos) {
            // optimize, our last readPacket read exactly 1 packet
            // we can reset all our indexes to 0 so that we have the full buffer
            // available
            pos = 0;
            self.read_pos = 0;
            self.read_len = 0;
        }

        while (true) {
            if (pos == buf.len) {
                const read_pos = self.read_pos;
                // we have no more space in our buffer ...
                if (read_pos == 0) {
                    // ... and we started reading this packet from the start of our
                    // buffer, so we really have no more space
                    return error.ReadBufferIsFull;
                }

                // ... and we didn't start reading this message from the start of our
                // buffer, so if we move things around, we'll have new free space.
                pos = self.read_len - read_pos;
                @memmove(buf[0..pos], buf[read_pos..][0..pos]);

                self.read_pos = 0;
                self.read_len = pos;
            }

            const n = (try self.read(ctx, buf[pos..])) orelse return null;
            if (n == 0) {
                return error.Closed;
            }

            pos += n;
            self.read_len += n;

            // bufferedPacket() will set read_pos
            if (try self.bufferedPacket()) |packet| {
                return packet;
            }
        }
    }

    // see if we have a full packet in our read_buf already
    fn bufferedPacket(self: *Self) !?Packet {
        const buf = self.read_buf[self.read_pos..self.read_len];

        // always has to be at least 2 bytes
        // 1 for the packet type and at least 1 for the length.
        if (buf.len < 2) {
            return null;
        }

        const remaining_len, const length_of_len = codec.readVarint(
            buf[1..],
        ) catch |err| switch (err) {
            error.InvalidVarint => {
                self.last_error = .{ .inner = err };
                return error.MalformedPacket;
            },
        } orelse return null;

        // +1 for the packet type
        const fixed_header_len = 1 + length_of_len;

        const total_len = fixed_header_len + remaining_len;
        if (buf.len < total_len) {
            // don't have a full packet yet
            return null;
        }

        self.read_pos += total_len;
        self.last_recv_time = std.time.milliTimestamp();
        self.ping_sent_time = null; // Any response clears pending ping

        return Packet.decode(buf[0], buf[fixed_header_len..total_len]) catch |err| {
            self.last_error = .{ .inner = err };
            switch (err) {
                error.UnknownPacketType => return error.Protocol,
                error.InvalidReasonCode => return error.Protocol,
                else => return error.MalformedPacket,
            }
        };
    }

    fn read(self: *Self, ctx: *const Context, buf: []u8) !?usize {
        const absolute_timeout = std.time.milliTimestamp() + ctx.timeout;

        // on disconnect, the number of times that we'll try to reconnect and
        // continue. This counts downwards to 0.
        var retries = ctx.retries;

        // If retries > 0 and we detect a disconnect, we'll attempt to reload the
        // socket (hence socket is var, not const).
        var socket = try self.getOrConnectSocket();

        loop: while (true) {
            const n = posix.read(socket, buf) catch |err| {
                switch (err) {
                    error.BrokenPipe, error.ConnectionResetByPeer => {
                        socket = try self.handleError(&retries);
                        continue :loop;
                    },
                    error.WouldBlock => {
                        const timeout: i32 = @intCast(absolute_timeout - std.time.milliTimestamp());
                        if (timeout < 0) {
                            return null;
                        }

                        var fds = [1]posix.pollfd{.{
                            .fd = socket,
                            .events = posix.POLL.IN,
                            .revents = 0,
                        }};

                        if (try posix.poll(&fds, timeout) == 0) {
                            return null;
                        }

                        if (fds[0].revents & posix.POLL.IN != posix.POLL.IN) {
                            // handle any other non-POLLOUT event as an error
                            socket = try self.handleError(&retries);
                        }

                        // Either poll has told us we can read without blocking OR
                        // poll told us there was a error, but retries > 0 and we managed
                        // to reconnect. Either way, we're gonna try to read again.
                        continue :loop;
                    },
                    else => {
                        self.close();
                        return err;
                    },
                }
            };

            if (n != 0) {
                return n;
            }

            socket = try self.handleError(&retries);
        }
    }

    fn write(self: *Self, ctx: *const Context, data: []const u8) !void {
        const absolute_timeout = std.time.milliTimestamp() + ctx.timeout;

        // on disconnect, the number of times that we'll try to reconnect and
        // continue. This counts downwards to 0.
        var retries = ctx.retries;

        // If retries > 0 and we detect a disconnect, we'll attempt to reload the
        // socket (hence socket is var, not const).
        var socket = try self.getOrConnectSocket();

        // position in data that we've written to so far (or, put differently,
        // positition in data that our next write starts at)
        var pos: usize = 0;

        loop: while (pos < data.len) {
            pos += posix.write(socket, data[pos..]) catch |err| switch (err) {
                error.WouldBlock => {
                    const timeout: i32 = @intCast(absolute_timeout - std.time.milliTimestamp());
                    if (timeout < 0) {
                        return error.Timeout;
                    }

                    var fds = [1]posix.pollfd{.{
                        .fd = socket,
                        .events = posix.POLL.OUT,
                        .revents = 0,
                    }};

                    if (try posix.poll(&fds, timeout) == 0) {
                        return error.Timeout;
                    }

                    const revents = fds[0].revents;
                    if (revents & posix.POLL.OUT != posix.POLL.OUT) {
                        // handle any other non-POLLOUT event as an error
                        socket = try self.handleError(&retries);
                    }

                    // Either poll has told us we can write without blocking OR
                    // poll told us there was a error, but retries > 0 and we managed
                    // to reconnect. Either way, we're gonna try to write again.
                    continue :loop;
                },
                error.BrokenPipe, error.ConnectionResetByPeer => {
                    socket = try self.handleError(&retries);
                    continue :loop;
                },
                else => {
                    self.close();
                    return err;
                },
            };
        }

        self.last_send_time = std.time.milliTimestamp();
    }

    /// Inject data into the read buffer for testing purposes.
    /// This simulates receiving data from the network.
    pub fn injectReadData(self: *Self, data: []const u8) !void {
        if (data.len > self.read_buf.len - self.read_len) {
            return error.ReadBufferIsFull;
        }
        @memcpy(self.read_buf[self.read_len..][0..data.len], data);
        self.read_len += data.len;
    }

    /// Get a buffered packet if one is complete, without doing network I/O.
    /// Useful for testing the packet parsing logic.
    pub fn getBufferedPacket(self: *Self) !?Packet {
        return self.bufferedPacket();
    }
};

test "Client.init with provided buffers" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    try std.testing.expectEqual(@as(?posix.socket_t, null), client.socket);
    try std.testing.expectEqual(@as(usize, 0), client.read_pos);
    try std.testing.expectEqual(@as(usize, 0), client.read_len);
    try std.testing.expectEqual(@as(u16, 1), client.packet_identifier);
    try std.testing.expectEqual(false, client.read_buf_own);
    try std.testing.expectEqual(false, client.write_buf_own);
}

test "Client.init with allocator" {
    const allocator = std.testing.allocator;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .allocator = allocator,
        .read_buf_size = 128,
        .write_buf_size = 256,
    });
    defer client.deinit();

    try std.testing.expectEqual(true, client.read_buf_own);
    try std.testing.expectEqual(true, client.write_buf_own);
    try std.testing.expectEqual(@as(usize, 128), client.read_buf.len);
    try std.testing.expectEqual(@as(usize, 256), client.write_buf.len);
}

test "Client.init requires allocator when no buffers provided" {
    try std.testing.expectError(error.AllocatorRequired, Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
    }));
}

test "Client.init requires host or ip" {
    // When neither host nor ip is provided, Address.init returns HostOrIPRequired
    // We need an allocator because ip is null (DNS resolution might be needed)
    try std.testing.expectError(error.HostOrIPRequired, Client.init(.{
        .port = 1883,
        .allocator = std.testing.allocator,
    }));
}

test "Client.init default values" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    try std.testing.expectEqual(@as(i32, 10_000), client.connect_timeout);
    try std.testing.expectEqual(@as(u16, 1), client.default_retries);
    try std.testing.expectEqual(@as(i32, 5_000), client.default_timeout);
}

test "Client.init custom timeouts" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
        .connect_timeout = 5_000,
        .default_retries = 3,
        .default_timeout = 10_000,
    });
    defer client.deinit();

    try std.testing.expectEqual(@as(i32, 5_000), client.connect_timeout);
    try std.testing.expectEqual(@as(u16, 3), client.default_retries);
    try std.testing.expectEqual(@as(i32, 10_000), client.default_timeout);
}

test "Client.packetIdentifier auto-increment" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // First call returns 1, then increments
    try std.testing.expectEqual(@as(u16, 1), client.packetIdentifier(null));
    try std.testing.expectEqual(@as(u16, 2), client.packetIdentifier(null));
    try std.testing.expectEqual(@as(u16, 3), client.packetIdentifier(null));
}

test "Client.packetIdentifier explicit value" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Explicit value doesn't affect internal counter
    try std.testing.expectEqual(@as(u16, 100), client.packetIdentifier(100));
    try std.testing.expectEqual(@as(u16, 1), client.packetIdentifier(null));
    try std.testing.expectEqual(@as(u16, 200), client.packetIdentifier(200));
    try std.testing.expectEqual(@as(u16, 2), client.packetIdentifier(null));
}

test "Client.packetIdentifier wraps around" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    client.packet_identifier = 65535;
    try std.testing.expectEqual(@as(u16, 65535), client.packetIdentifier(null));
    try std.testing.expectEqual(@as(u16, 0), client.packetIdentifier(null));
    try std.testing.expectEqual(@as(u16, 1), client.packetIdentifier(null));
}

test "Client.bufferedPacket with no data" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // No data in buffer
    try std.testing.expectEqual(@as(?Packet, null), try client.getBufferedPacket());
}

test "Client.bufferedPacket incomplete packet" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Only 1 byte - need at least 2
    try client.injectReadData(&[_]u8{0x20});
    try std.testing.expectEqual(@as(?Packet, null), try client.getBufferedPacket());
}

test "Client.bufferedPacket CONNACK" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // CONNACK: type 2, remaining length 2, session_present=0, return_code=0
    try client.injectReadData(&[_]u8{ 0x20, 0x02, 0x00, 0x00 });

    const packet = try client.getBufferedPacket();
    try std.testing.expect(packet != null);
    try std.testing.expect(packet.? == .connack);
    try std.testing.expectEqual(false, packet.?.connack.session_present);
    try std.testing.expectEqual(Packet.ConnAck.ReturnCode.accepted, packet.?.connack.return_code);

    // read_pos should advance past the packet
    try std.testing.expectEqual(@as(usize, 4), client.read_pos);
}

test "Client.bufferedPacket PUBACK" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // PUBACK: type 4, remaining length 2, packet_id = 0x0042 (66)
    try client.injectReadData(&[_]u8{ 0x40, 0x02, 0x00, 0x42 });

    const packet = try client.getBufferedPacket();
    try std.testing.expect(packet != null);
    try std.testing.expect(packet.? == .puback);
    try std.testing.expectEqual(@as(u16, 66), packet.?.puback.packet_identifier);
}

test "Client.bufferedPacket PUBLISH QoS 0" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // PUBLISH QoS 0: type 3, flags 0, remaining length 7
    // Topic: "t" (len=1), message: "test"
    try client.injectReadData(&[_]u8{ 0x30, 0x07, 0x00, 0x01, 't', 't', 'e', 's', 't' });

    const packet = try client.getBufferedPacket();
    try std.testing.expect(packet != null);
    try std.testing.expect(packet.? == .publish);
    try std.testing.expectEqualStrings("t", packet.?.publish.topic);
    try std.testing.expectEqualStrings("test", packet.?.publish.message);
    try std.testing.expectEqual(QoS.at_most_once, packet.?.publish.qos);
    try std.testing.expectEqual(@as(?u16, null), packet.?.publish.packet_identifier);
}

test "Client.bufferedPacket PUBLISH QoS 1" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // PUBLISH QoS 1: type 3, flags 2 (qos=1), remaining length 9
    // Topic: "t" (len=1), packet_id=0x000A (10), message: "test"
    try client.injectReadData(&[_]u8{ 0x32, 0x09, 0x00, 0x01, 't', 0x00, 0x0A, 't', 'e', 's', 't' });

    const packet = try client.getBufferedPacket();
    try std.testing.expect(packet != null);
    try std.testing.expect(packet.? == .publish);
    try std.testing.expectEqualStrings("t", packet.?.publish.topic);
    try std.testing.expectEqualStrings("test", packet.?.publish.message);
    try std.testing.expectEqual(QoS.at_least_once, packet.?.publish.qos);
    try std.testing.expectEqual(@as(?u16, 10), packet.?.publish.packet_identifier);
}

test "Client.bufferedPacket SUBACK" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // SUBACK: type 9, remaining length 4, packet_id=0x0001, results=[0x00, 0x01]
    try client.injectReadData(&[_]u8{ 0x90, 0x04, 0x00, 0x01, 0x00, 0x01 });

    const packet = try client.getBufferedPacket();
    try std.testing.expect(packet != null);
    try std.testing.expect(packet.? == .suback);
    try std.testing.expectEqual(@as(u16, 1), packet.?.suback.packet_identifier);
    try std.testing.expectEqual(QoS.at_most_once, try packet.?.suback.result(0));
    try std.testing.expectEqual(QoS.at_least_once, try packet.?.suback.result(1));
}

test "Client.bufferedPacket PINGRESP" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // PINGRESP: type 13, remaining length 0
    try client.injectReadData(&[_]u8{ 0xD0, 0x00 });

    const packet = try client.getBufferedPacket();
    try std.testing.expect(packet != null);
    try std.testing.expect(packet.? == .pingresp);
}

test "Client.bufferedPacket multiple packets" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Two packets: PINGRESP + CONNACK
    try client.injectReadData(&[_]u8{
        0xD0, 0x00, // PINGRESP
        0x20, 0x02, 0x01, 0x00, // CONNACK with session_present=1
    });

    // First packet
    const packet1 = try client.getBufferedPacket();
    try std.testing.expect(packet1 != null);
    try std.testing.expect(packet1.? == .pingresp);
    try std.testing.expectEqual(@as(usize, 2), client.read_pos);

    // Second packet
    const packet2 = try client.getBufferedPacket();
    try std.testing.expect(packet2 != null);
    try std.testing.expect(packet2.? == .connack);
    try std.testing.expectEqual(true, packet2.?.connack.session_present);
    try std.testing.expectEqual(@as(usize, 6), client.read_pos);

    // No more packets
    try std.testing.expectEqual(@as(?Packet, null), try client.getBufferedPacket());
}

test "Client.bufferedPacket incomplete varint" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Packet type + continuation byte (incomplete varint)
    try client.injectReadData(&[_]u8{ 0x30, 0x80 });
    try std.testing.expectEqual(@as(?Packet, null), try client.getBufferedPacket());
}

test "Client.bufferedPacket invalid varint" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // 5 continuation bytes - invalid per MQTT spec
    try client.injectReadData(&[_]u8{ 0x30, 0x80, 0x80, 0x80, 0x80 });
    try std.testing.expectError(error.MalformedPacket, client.getBufferedPacket());
}

test "Client.bufferedPacket unknown packet type" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Type 0 is reserved/unknown
    try client.injectReadData(&[_]u8{ 0x00, 0x00 });
    try std.testing.expectError(error.Protocol, client.getBufferedPacket());
}

test "Client.injectReadData buffer full" {
    var read_buf: [4]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Fill buffer
    try client.injectReadData(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });

    // Try to inject more
    try std.testing.expectError(error.ReadBufferIsFull, client.injectReadData(&[_]u8{0x05}));
}

test "Client.lastReadPacket" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), client.lastReadPacket().len);

    // After reading a packet
    try client.injectReadData(&[_]u8{ 0xD0, 0x00 }); // PINGRESP
    _ = try client.getBufferedPacket();

    // lastReadPacket returns data up to read_pos
    try std.testing.expectEqual(@as(usize, 2), client.lastReadPacket().len);
    try std.testing.expectEqual([_]u8{ 0xD0, 0x00 }, client.lastReadPacket()[0..2].*);
}

test "Client.createContext uses defaults" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
        .default_retries = 5,
        .default_timeout = 15_000,
    });
    defer client.deinit();

    const ctx = client.createContext(.{});
    try std.testing.expectEqual(@as(u16, 5), ctx.retries);
    try std.testing.expectEqual(@as(i32, 15_000), ctx.timeout);
}

test "Client.createContext uses overrides" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
        .default_retries = 5,
        .default_timeout = 15_000,
    });
    defer client.deinit();

    const ctx = client.createContext(.{ .retries = 2, .timeout = 1_000 });
    try std.testing.expectEqual(@as(u16, 2), ctx.retries);
    try std.testing.expectEqual(@as(i32, 1_000), ctx.timeout);
}

test "Client.subscribe validation" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Empty topics should fail
    const result = client.subscribe(.{}, .{ .topics = &[_]SubscribeOpts.Topic{} });
    try std.testing.expectError(error.Usage, result);
    try std.testing.expectEqualStrings("must have at least 1 topic", client.lastError().?.details);
}

test "Client.unsubscribe validation" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Empty topics should fail
    const topics = [_][]const u8{};
    const result = client.unsubscribe(.{}, .{ .topics = &topics });
    try std.testing.expectError(error.Usage, result);
    try std.testing.expectEqualStrings("must have at least 1 topic", client.lastError().?.details);
}

test "Client.checkHealth ok when no activity yet" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // No activity timestamps set yet - should be ok
    try std.testing.expectEqual(Client.HealthStatus.ok, client.checkHealth(5000));
}

test "Client.checkHealth stale after threshold" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Simulate activity in the past
    const now = std.time.milliTimestamp();
    client.last_recv_time = now - 10_000; // 10 seconds ago

    // With 5s threshold, should be stale
    try std.testing.expectEqual(Client.HealthStatus.stale, client.checkHealth(5000));

    // With 15s threshold, should be ok
    try std.testing.expectEqual(Client.HealthStatus.ok, client.checkHealth(15_000));
}

test "Client.checkHealth ok when ping pending within threshold" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Simulate ping sent recently
    const now = std.time.milliTimestamp();
    client.ping_sent_time = now - 1000; // 1 second ago

    // With 5s threshold, should still be ok (waiting for response)
    try std.testing.expectEqual(Client.HealthStatus.ok, client.checkHealth(5000));
}

test "Client.checkHealth unresponsive when ping times out" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Simulate ping sent long ago with no response
    const now = std.time.milliTimestamp();
    client.ping_sent_time = now - 10_000; // 10 seconds ago

    // With 5s threshold, ping timed out - unresponsive
    try std.testing.expectEqual(Client.HealthStatus.unresponsive, client.checkHealth(5000));
}

test "Client.checkHealth clears ping on receive" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    // Simulate pending ping
    client.ping_sent_time = std.time.milliTimestamp() - 1000;

    // Receive a packet (PINGRESP)
    try client.injectReadData(&[_]u8{ 0xD0, 0x00 });
    _ = try client.getBufferedPacket();

    // ping_sent_time should be cleared
    try std.testing.expectEqual(@as(?i64, null), client.ping_sent_time);
    try std.testing.expect(client.last_recv_time > 0);
}

test "Client.checkHealth uses max of send and recv time" {
    var read_buf: [64]u8 = undefined;
    var write_buf: [64]u8 = undefined;

    var client = try Client.init(.{
        .ip = "127.0.0.1",
        .port = 1883,
        .read_buf = &read_buf,
        .write_buf = &write_buf,
    });
    defer client.deinit();

    const now = std.time.milliTimestamp();

    // Old recv, recent send - should be ok
    client.last_recv_time = now - 10_000;
    client.last_send_time = now - 1000;
    try std.testing.expectEqual(Client.HealthStatus.ok, client.checkHealth(5000));

    // Recent recv, old send - should be ok
    client.last_recv_time = now - 1000;
    client.last_send_time = now - 10_000;
    try std.testing.expectEqual(Client.HealthStatus.ok, client.checkHealth(5000));

    // Both old - should be stale
    client.last_recv_time = now - 10_000;
    client.last_send_time = now - 10_000;
    try std.testing.expectEqual(Client.HealthStatus.stale, client.checkHealth(5000));
}
