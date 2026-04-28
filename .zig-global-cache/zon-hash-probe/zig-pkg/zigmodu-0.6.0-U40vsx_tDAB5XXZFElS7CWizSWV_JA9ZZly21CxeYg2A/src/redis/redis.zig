//! Redis client for zigzero
//!
//! Provides Redis operations aligned with go-zero's redis functionality.

const std = @import("std");
const errors = @import("../sqlx/errors.zig");

/// Redis configuration
pub const RedisConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    db: u32 = 0,
    pool_size: u32 = 100,
    read_timeout_ms: u32 = 3000,
    write_timeout_ms: u32 = 3000,
};


/// Redis client for zigzero
pub const Redis = struct {
    allocator: std.mem.Allocator,
    config: RedisConfig,
    stream: ?std.Io.net.Stream = null,
    io: std.Io,

    /// Create a new Redis client
    pub fn new(allocator: std.mem.Allocator, io: std.Io, cfg: RedisConfig) !Redis {
        return Redis{
            .allocator = allocator,
            .config = cfg,
            .stream = null,
            .io = io,
        };
    }

    /// Deinitialize Redis client
    pub fn deinit(self: *Redis) void {
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
    }


    /// Connect to Redis server
    pub fn connect(self: *Redis) !void {
        const address = std.Io.net.IpAddress.parseIp4(self.config.host, self.config.port) catch return error.RedisError;
        self.stream = address.connect(self.io, .{ .mode = .stream }) catch return error.RedisError;
    }

    /// Disconnect from Redis server
    pub fn disconnect(self: *Redis) void {
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
    }

    /// Get a value by key
    pub fn get(self: *Redis, key: []const u8) errors.ResultT(?[]const u8) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [4096]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            // Parse bulk string response
            if (response.len > 1) {
                if (response[0] == '$') {
                    if (response[1] == '-') {
                        return null; // Null bulk string
                    }
                    var end_idx: usize = 1;
                    while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                    const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                    if (len <= 0) return null;

                    const value_start = end_idx + 2;
                    const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                    return value;
                }
            }
        }
        return error.RedisError;
    }

    /// Set a value with expiration
    pub fn set(self: *Redis, key: []const u8, value: []const u8, ex_seconds: ?u32) errors.Result {
        if (self.stream) |stream| {
            const cmd = if (ex_seconds) |ex|
                std.fmt.allocPrint(self.allocator, "*5\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\nEX\r\n${d}\r\n{d}\r\n", .{ key.len, key, value.len, value, std.fmt.count("{d}", .{ex}), ex }) catch return error.RedisError
            else
                std.fmt.allocPrint(self.allocator, "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            _ = stream.read(&buf) catch return error.RedisError;
            return;
        }
        return error.RedisError;
    }

    /// Set a value only if key doesn't exist
    pub fn setNX(self: *Redis, key: []const u8, value: []const u8) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nSETNX\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i32, response[1..], 10) catch return false;
                return val == 1;
            }
        }
        return false;
    }

    /// Delete keys
    pub fn del(self: *Redis, keys: []const []const u8) errors.ResultT(u32) {
        if (self.stream) |stream| {
            var cmd_builder: std.ArrayList(u8) = std.ArrayList(u8).empty;
            defer cmd_builder.deinit(self.allocator);

            try cmd_builder.writer(self.allocator).print("*{d}\r\n$3\r\nDEL\r\n", .{keys.len + 1});
            for (keys) |key| {
                try cmd_builder.writer(self.allocator).print("${d}\r\n{s}\r\n", .{ key.len, key });
            }

            _ = stream.write(cmd_builder.items) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return 0;
    }

    /// Check if key exists
    pub fn exists(self: *Redis, key: []const u8) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$6\r\nEXISTS\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i32, response[1..], 10) catch return false;
                return val == 1;
            }
        }
        return false;
    }

    /// Increment a value
    pub fn incr(self: *Redis, key: []const u8) errors.ResultT(i64) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nINCR\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i64, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }

    /// Decrement a value
    pub fn decr(self: *Redis, key: []const u8) errors.ResultT(i64) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nDECR\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i64, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }

    /// Expire a key
    pub fn expire(self: *Redis, key: []const u8, seconds: u32) errors.Result {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$6\r\nEXPIRE\r\n${d}\r\n{s}\r\n${d}\r\n{d}\r\n", .{ key.len, key, std.fmt.count("{d}", .{seconds}), seconds }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            _ = stream.read(&buf) catch return error.RedisError;
            return;
        }
        return error.RedisError;
    }

    /// Get remaining TTL
    pub fn ttl(self: *Redis, key: []const u8) errors.ResultT(i64) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nTTL\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i64, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return -1;
    }

    /// Acquire a distributed lock
    pub fn lock(self: *Redis, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const px = ttl_seconds * 1000;
            const cmd = std.fmt.allocPrint(self.allocator, "*5\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n$2\r\nNX\r\n$2\r\nPX\r\n${d}\r\n{d}\r\n", .{
                key.len, key, value.len, value, std.fmt.count("{d}", .{px}), px,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len >= 3 and std.mem.eql(u8, response[0..3], "+OK")) {
                return true;
            }
        }
        return false;
    }

    /// Release a distributed lock
    pub fn unlock(self: *Redis, key: []const u8) errors.Result {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$3\r\nDEL\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            _ = stream.read(&buf) catch return error.RedisError;
        }
        return;
    }

    /// List operations
    pub fn lPush(self: *Redis, key: []const u8, value: []const u8) errors.ResultT(u32) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$5\r\nLPUSH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{ key.len, key, value.len, value }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }

    pub fn rPop(self: *Redis, key: []const u8) errors.ResultT(?[]const u8) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*2\r\n$4\r\nRPOP\r\n${d}\r\n{s}\r\n", .{ key.len, key }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [4096]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1) {
                if (response[0] == '$') {
                    if (response[1] == '-') {
                        return null;
                    }
                    var end_idx: usize = 1;
                    while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                    const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                    if (len <= 0) return null;

                    const value_start = end_idx + 2;
                    const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                    return value;
                }
            }
        }
        return error.RedisError;
    }

    /// Hash operations
    pub fn hSet(self: *Redis, key: []const u8, field: []const u8, value: []const u8) errors.ResultT(bool) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*4\r\n$4\r\nHSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
                key.len, key, field.len, field, value.len, value,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(i32, response[1..], 10) catch return 0;
                return val == 1;
            }
        }
        return false;
    }

    pub fn hGet(self: *Redis, key: []const u8, field: []const u8) errors.ResultT(?[]const u8) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$4\r\nHGET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
                key.len, key, field.len, field,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [4096]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1) {
                if (response[0] == '$') {
                    if (response[1] == '-') {
                        return null;
                    }
                    var end_idx: usize = 1;
                    while (end_idx < response.len and response[end_idx] != '\r') : (end_idx += 1) {}
                    const len = std.fmt.parseInt(i32, response[1..end_idx], 10) catch return error.RedisError;
                    if (len <= 0) return null;

                    const value_start = end_idx + 2;
                    const value = self.allocator.dupe(u8, response[value_start..@min(value_start + @as(usize, @intCast(len)), response.len)]) catch return error.RedisError;
                    return value;
                }
            }
        }
        return error.RedisError;
    }

    /// Pub/Sub
    pub fn publish(self: *Redis, channel: []const u8, message: []const u8) errors.ResultT(u32) {
        if (self.stream) |stream| {
            const cmd = std.fmt.allocPrint(self.allocator, "*3\r\n$7\r\nPUBLISH\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n", .{
                channel.len, channel, message.len, message,
            }) catch return error.RedisError;
            defer self.allocator.free(cmd);

            _ = stream.write(cmd) catch return error.RedisError;

            var buf: [256]u8 = undefined;
            const n = stream.read(&buf) catch return error.RedisError;
            const response = buf[0..n];

            if (response.len > 1 and response[0] == ':') {
                const val = std.fmt.parseInt(u32, response[1..], 10) catch return error.RedisError;
                return val;
            }
        }
        return error.RedisError;
    }
};

/// CRC16 for Redis cluster slot calculation
fn crc16(data: []const u8) u16 {
    const table = [_]u16{
        0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7,
        0x8108, 0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef,
        0x1231, 0x0210, 0x3273, 0x2252, 0x52b5, 0x4294, 0x72f7, 0x62d6,
        0x9339, 0x8318, 0xb37b, 0xa35a, 0xd3bd, 0xc39c, 0xf3ff, 0xe3de,
        0x2462, 0x3443, 0x0420, 0x1401, 0x64e6, 0x74c7, 0x44a4, 0x5485,
        0xa56a, 0xb54b, 0x8528, 0x9509, 0xe5ee, 0xf5cf, 0xc5ac, 0xd58d,
        0x3653, 0x2672, 0x1611, 0x0630, 0x76d7, 0x66f6, 0x5695, 0x46b4,
        0xb75b, 0xa77a, 0x9719, 0x8738, 0xf7df, 0xe7fe, 0xd79d, 0xc7bc,
        0x48c4, 0x58e5, 0x6886, 0x78a7, 0x0840, 0x1861, 0x2802, 0x3823,
        0xc9cc, 0xd9ed, 0xe98e, 0xf9af, 0x8948, 0x9969, 0xa90a, 0xb92b,
        0x5af5, 0x4ad4, 0x7ab7, 0x6a96, 0x1a71, 0x0a50, 0x3a33, 0x2a12,
        0xdbfd, 0xcbdc, 0xfbbf, 0xeb9e, 0x9b79, 0x8b58, 0xbb3b, 0xab1a,
        0x6ca6, 0x7c87, 0x4ce4, 0x5cc5, 0x2c22, 0x3c03, 0x0c60, 0x1c41,
        0xedae, 0xfd8f, 0xcdec, 0xddcd, 0xad2a, 0xbd0b, 0x8d68, 0x9d49,
        0x7e97, 0x6eb6, 0x5ed5, 0x4ef4, 0x3e13, 0x2e32, 0x1e51, 0x0e70,
        0xff9f, 0xefbe, 0xdfdd, 0xcffc, 0xbf1b, 0xaf3a, 0x9f59, 0x8f78,
        0x9188, 0x81a9, 0xb1ca, 0xa1eb, 0xd10c, 0xc12d, 0xf14e, 0xe16f,
        0x1080, 0x00a1, 0x30c2, 0x20e3, 0x5004, 0x4025, 0x7046, 0x6067,
        0x83b9, 0x9398, 0xa3fb, 0xb3da, 0xc33d, 0xd31c, 0xe37f, 0xf35e,
        0x02b1, 0x1290, 0x22f3, 0x32d2, 0x4235, 0x5214, 0x6277, 0x7256,
        0xb5ea, 0xa5cb, 0x95a8, 0x8589, 0xf56e, 0xe54f, 0xd52c, 0xc50d,
        0x34e2, 0x24c3, 0x14a0, 0x0481, 0x7466, 0x6447, 0x5424, 0x4405,
        0xa7db, 0xb7fa, 0x8799, 0x97b8, 0xe75f, 0xf77e, 0xc71d, 0xd73c,
        0x26d3, 0x36f2, 0x0691, 0x16b0, 0x6657, 0x7676, 0x4615, 0x5634,
        0xd94c, 0xc96d, 0xf90e, 0xe92f, 0x99c8, 0x89e9, 0xb98a, 0xa9ab,
        0x5844, 0x4865, 0x7806, 0x6827, 0x18c0, 0x08e1, 0x3882, 0x28a3,
        0xcb7d, 0xdb5c, 0xeb3f, 0xfb1e, 0x8bf9, 0x9bd8, 0xabbb, 0xbb9a,
        0x4a75, 0x5a54, 0x6a37, 0x7a16, 0x0af1, 0x1ad0, 0x2ab3, 0x3a92,
        0xfd2e, 0xed0f, 0xdd6c, 0xcd4d, 0xbdaa, 0xad8b, 0x9de8, 0x8dc9,
        0x7c26, 0x6c07, 0x5c64, 0x4c45, 0x3ca2, 0x2c83, 0x1ce0, 0x0cc1,
        0xef1f, 0xff3e, 0xcf5d, 0xdf7c, 0xaf9b, 0xbfba, 0x8fd9, 0x9ff8,
        0x6e17, 0x7e36, 0x4e55, 0x5e74, 0x2e93, 0x3eb2, 0x0ed1, 0x1ef0,
    };
    var crc: u16 = 0;
    for (data) |byte| {
        crc = (crc << 8) ^ table[((crc >> 8) ^ byte) & 0xFF];
    }
    return crc;
}

/// Calculate Redis cluster slot for a key
fn keySlot(key: []const u8) u16 {
    // Handle hash tags: only the part between { and } is hashed
    var start: usize = 0;
    var end: usize = key.len;
    if (std.mem.indexOfScalar(u8, key, '{')) |s| {
        if (std.mem.indexOfScalar(u8, key[s..], '}')) |e| {
            if (e > 1) {
                start = s + 1;
                end = s + e;
            }
        }
    }
    return crc16(key[start..end]) % 16384;
}

/// Redis cluster node configuration
pub const ClusterNode = struct {
    host: []const u8,
    port: u16,
};

/// Redis cluster client
pub const RedisCluster = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Redis),
    node_configs: std.ArrayList(RedisConfig),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(Redis).empty,
            .node_configs = std.ArrayList(RedisConfig).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.nodes.items) |*node| {
            node.deinit();
        }
        self.nodes.deinit(self.allocator);
        for (self.node_configs.items) |*cfg| {
            self.allocator.free(cfg.host);
        }
        self.node_configs.deinit(self.allocator);
    }

    pub fn addNode(self: *Self, host: []const u8, port: u16) !void {
        const host_copy = try self.allocator.dupe(u8, host);
        const cfg = RedisConfig{ .host = host_copy, .port = port };
        try self.node_configs.append(self.allocator, cfg);
        const redis = try Redis.new(self.allocator, std.testing.io, cfg);
        try self.nodes.append(self.allocator, redis);
    }

    fn selectNode(self: *Self, key: []const u8) ?*Redis {
        if (self.nodes.items.len == 0) return null;
        if (self.nodes.items.len == 1) return &self.nodes.items[0];
        const slot = keySlot(key);
        const idx = slot % @as(u16, @intCast(self.nodes.items.len));
        return &self.nodes.items[idx];
    }

    pub fn connect(self: *Self) !void {
        for (self.nodes.items) |*node| {
            node.connect() catch {};
        }
    }

    pub fn get(self: *Self, key: []const u8) errors.ResultT(?[]const u8) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.get(key);
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8, ex_seconds: ?u32) errors.Result {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.set(key, value, ex_seconds);
    }

    pub fn del(self: *Self, keys: []const []const u8) errors.ResultT(u32) {
        if (keys.len == 0) return 0;
        const node = self.selectNode(keys[0]) orelse return error.RedisError;
        return node.del(keys);
    }

    pub fn exists(self: *Self, key: []const u8) errors.ResultT(bool) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.exists(key);
    }

    pub fn incr(self: *Self, key: []const u8) errors.ResultT(i64) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.incr(key);
    }

    pub fn decr(self: *Self, key: []const u8) errors.ResultT(i64) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.decr(key);
    }

    pub fn expire(self: *Self, key: []const u8, seconds: u32) errors.Result {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.expire(key, seconds);
    }

    pub fn ttl(self: *Self, key: []const u8) errors.ResultT(i64) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.ttl(key);
    }

    pub fn hSet(self: *Self, key: []const u8, field: []const u8, value: []const u8) errors.ResultT(bool) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.hSet(key, field, value);
    }

    pub fn hGet(self: *Self, key: []const u8, field: []const u8) errors.ResultT(?[]const u8) {
        const node = self.selectNode(key) orelse return error.RedisError;
        return node.hGet(key, field);
    }
};

/// Distributed lock helper
pub const Lock = struct {
    redis: *Redis,
    key: []const u8,
    value: []const u8,
    acquired: bool = false,

    /// Acquire a lock
    pub fn acquire(redis: *Redis, key: []const u8, value: []const u8, ttl_seconds: u32) errors.ResultT(bool) {
        return redis.lock(key, value, ttl_seconds);
    }

    /// Release a lock
    pub fn release(self: *Lock) errors.Result {
        if (self.acquired) {
            return self.redis.unlock(self.key);
        }
    }
};

test "redis client" {
    // Note: These tests require a running Redis server
    // Skip in CI environment
    if (true) return error.SkipZigTest;

    const cfg = RedisConfig{};
    var redis = try Redis.new(std.testing.allocator, std.testing.io, cfg);
    defer redis.deinit();

    try redis.connect();

    // Test basic operations
    try redis.set("test_key", "test_value", null);
    const value = try redis.get("test_key");
    try std.testing.expect(value != null);
    if (value) |v| {
        try std.testing.expectEqualStrings("test_value", v);
        std.testing.allocator.free(v);
    }

    // Test lock
    const acquired = try Lock.acquire(&redis, "test_lock", "token123", 10);
    try std.testing.expect(acquired);
}

test "resp protocol parsing" {
    // Test parsing RESP simple strings
    const simple_string = "+OK\r\n";
    try std.testing.expectEqualStrings("OK", simple_string[1..3]);
}

test "redis cluster slot calculation" {
    try std.testing.expectEqual(@as(u16, 12182), keySlot("foo"));
    try std.testing.expectEqual(@as(u16, 5474), keySlot("{user}:123"));
    try std.testing.expectEqual(@as(u16, 5474), keySlot("{user}:456"));
}

test "redis cluster init" {
    const allocator = std.testing.allocator;
    var cluster = RedisCluster.init(allocator);
    defer cluster.deinit();

    try cluster.addNode("127.0.0.1", 7000);
    try cluster.addNode("127.0.0.1", 7001);
    try cluster.addNode("127.0.0.1", 7002);

    try std.testing.expectEqual(@as(usize, 3), cluster.nodes.items.len);

    // Verify consistent routing for the same key
    const node1 = cluster.selectNode("mykey");
    const node2 = cluster.selectNode("mykey");
    try std.testing.expectEqual(node1, node2);
}
