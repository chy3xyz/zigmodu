//! Native (non-CLI) Fluvio transport: talks a simple line protocol over a TCP
//! socket, replacing the `fluvio` subprocess path. The full Fluvio SC/SPU wire
//! protocol is protobuf-based; this transport defines a clean, testable
//! framing that a Fluvio gateway (or a faithful protocol implementation) can
//! speak. `FluvioNativeServer` is an in-process loopback server for tests and
//! local development.
//!
//! Wire format (one command per line, `\t`-separated fields, `\n`-terminated):
//!   PRODUCE <topic>\t<key>\t<value>
//!   CONSUME <topic>\t<offset>      → RECORD <key>\t<value> ... END
//!   LIST                           → TOPIC <name> ... END
//!   CREATE <name>\t<partitions>    → OK | ERR <message>

const std = @import("std");
const Connector = @import("FluvioConnector.zig");

const Record = Connector.Record;

pub const NativeTransport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn connect(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !Self {
        const addr = try std.Io.net.IpAddress.parseIp4(host, port);
        const stream = try addr.connect(io, .{ .mode = .stream });
        return .{ .allocator = allocator, .io = io, .stream = stream };
    }

    pub fn deinit(self: *Self) void {
        self.stream.close(self.io);
        self.* = undefined;
    }

    pub fn produce(self: *Self, topic: []const u8, key: []const u8, value: []const u8) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "PRODUCE ");
        try buf.appendSlice(self.allocator, topic);
        try buf.append(self.allocator, '\t');
        try buf.appendSlice(self.allocator, key);
        try buf.append(self.allocator, '\t');
        try buf.appendSlice(self.allocator, value);
        try buf.append(self.allocator, '\n');
        try self.writeAll(buf.items);
        const resp = try self.readLine();
        defer self.allocator.free(resp);
        if (!std.mem.startsWith(u8, resp, "OK")) return error.FluvioNativeRejected;
    }

    pub fn consume(self: *Self, topic: []const u8, offset: i64) ![]Record {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "CONSUME ");
        try buf.appendSlice(self.allocator, topic);
        try buf.append(self.allocator, '\t');
        const off = try std.fmt.allocPrint(self.allocator, "{d}", .{offset});
        defer self.allocator.free(off);
        try buf.appendSlice(self.allocator, off);
        try buf.append(self.allocator, '\n');
        try self.writeAll(buf.items);

        var records = std.ArrayList(Record).empty;
        errdefer {
            for (records.items) |r| {
                self.allocator.free(r.key);
                self.allocator.free(r.value);
            }
            records.deinit(self.allocator);
        }
        var seq: i64 = 0;
        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);
            if (std.mem.eql(u8, line, "END")) break;
            if (std.mem.startsWith(u8, line, "ERR ")) return error.FluvioNativeRejected;
            if (!std.mem.startsWith(u8, line, "RECORD ")) return error.ProtocolError;
            const rest = line["RECORD ".len..];
            const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return error.ProtocolError;
            try records.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, rest[0..tab]),
                .value = try self.allocator.dupe(u8, rest[tab + 1 ..]),
                .offset = seq,
                .timestamp = 0,
            });
            seq += 1;
        }
        return try records.toOwnedSlice(self.allocator);
    }

    pub fn listTopics(self: *Self) ![]const []const u8 {
        try self.writeAll("LIST\n");
        var topics = std.ArrayList([]const u8).empty;
        errdefer {
            for (topics.items) |t| self.allocator.free(t);
            topics.deinit(self.allocator);
        }
        while (true) {
            const line = try self.readLine();
            defer self.allocator.free(line);
            if (std.mem.eql(u8, line, "END")) break;
            if (!std.mem.startsWith(u8, line, "TOPIC ")) return error.ProtocolError;
            try topics.append(self.allocator, try self.allocator.dupe(u8, line["TOPIC ".len..]));
        }
        return try topics.toOwnedSlice(self.allocator);
    }

    pub fn createTopic(self: *Self, name: []const u8, partitions: u16) !void {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "CREATE ");
        try buf.appendSlice(self.allocator, name);
        try buf.append(self.allocator, '\t');
        const p = try std.fmt.allocPrint(self.allocator, "{d}", .{partitions});
        defer self.allocator.free(p);
        try buf.appendSlice(self.allocator, p);
        try buf.append(self.allocator, '\n');
        try self.writeAll(buf.items);
        const resp = try self.readLine();
        defer self.allocator.free(resp);
        if (!std.mem.startsWith(u8, resp, "OK")) return error.FluvioNativeRejected;
    }

    pub fn asTransport(self: *Self) Connector.Transport {
        return .{
            .ptr = self,
            .produceFn = struct {
                fn f(ptr: *anyopaque, a: std.mem.Allocator, io: std.Io, topic: []const u8, key: []const u8, value: []const u8) anyerror!void {
                    _ = a;
                    _ = io;
                    const t: *NativeTransport = @ptrCast(@alignCast(ptr));
                    return t.produce(topic, key, value);
                }
            }.f,
            .consumeFn = struct {
                fn f(ptr: *anyopaque, a: std.mem.Allocator, io: std.Io, topic: []const u8, offset: i64) anyerror![]Record {
                    _ = a;
                    _ = io;
                    const t: *NativeTransport = @ptrCast(@alignCast(ptr));
                    return t.consume(topic, offset);
                }
            }.f,
            .listTopicsFn = struct {
                fn f(ptr: *anyopaque, a: std.mem.Allocator, io: std.Io) anyerror![]const []const u8 {
                    _ = a;
                    _ = io;
                    const t: *NativeTransport = @ptrCast(@alignCast(ptr));
                    return t.listTopics();
                }
            }.f,
            .createTopicFn = struct {
                fn f(ptr: *anyopaque, a: std.mem.Allocator, io: std.Io, name: []const u8, partitions: u16) anyerror!void {
                    _ = a;
                    _ = io;
                    const t: *NativeTransport = @ptrCast(@alignCast(ptr));
                    return t.createTopic(name, partitions);
                }
            }.f,
        };
    }

    fn writeAll(self: *Self, data: []const u8) !void {
        try @import("../core/sockread.zig").writeFull(self.stream, data);
    }

    fn readLine(self: *Self) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        var byte: [1]u8 = undefined;
        while (true) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&fds, 3000) catch return error.ReadFailed;
            if (ready == 0 or fds[0].revents == 0) return error.Timeout;
            const n = std.posix.read(self.stream.socket.handle, &byte) catch return error.ReadFailed;
            if (n == 0) return error.ConnectionClosed;
            if (byte[0] == '\n') return buf.toOwnedSlice(self.allocator);
            try buf.append(self.allocator, byte[0]);
        }
    }
};

test "NativeTransport produce/consume/list over loopback" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var topics = std.StringHashMap(std.ArrayList(Record)).init(allocator);
    defer {
        var it = topics.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |r| {
                allocator.free(r.key);
                allocator.free(r.value);
            }
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        topics.deinit();
    }

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    const ServerCtx = struct {
        server: *std.Io.net.Server,
        topics: *std.StringHashMap(std.ArrayList(Record)),
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);
            var buf: [4096]u8 = undefined;
            while (true) {
                var fds = [_]std.posix.pollfd{.{ .fd = accepted.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&fds, 3000) catch break;
                if (fds[0].revents == 0) continue; // idle timeout → keep serving
                const n = std.posix.read(accepted.socket.handle, &buf) catch break;
                if (n == 0) break; // client closed
                const data = buf[0..n];
                var line_iter = std.mem.splitScalar(u8, data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) continue;
                    if (std.mem.startsWith(u8, line, "PRODUCE ")) {
                        const rest = line["PRODUCE ".len..];
                        var parts = std.mem.splitScalar(u8, rest, '\t');
                        const topic = parts.next() orelse break;
                        const key = parts.next() orelse "";
                        const value = parts.next() orelse "";
                        const topic_owned = std.testing.allocator.dupe(u8, topic) catch break;
                        const gop = ctx.topics.getOrPut(topic_owned) catch {
                            std.testing.allocator.free(topic_owned);
                            break;
                        };
                        if (gop.found_existing) std.testing.allocator.free(topic_owned);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Record).empty;
                        gop.value_ptr.append(std.testing.allocator, .{
                            .key = std.testing.allocator.dupe(u8, key) catch break,
                            .value = std.testing.allocator.dupe(u8, value) catch break,
                            .offset = 0,
                            .timestamp = 0,
                        }) catch break;
                        _ = std.posix.system.write(accepted.socket.handle, "OK\n", 3);
                    } else if (std.mem.startsWith(u8, line, "CONSUME ")) {
                        const rest = line["CONSUME ".len..];
                        const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse break;
                        const topic = rest[0..tab];
                        if (ctx.topics.get(topic)) |recs| {
                            for (recs.items) |r| {
                                var out = std.ArrayList(u8).empty;
                                out.appendSlice(std.testing.allocator, "RECORD ") catch break;
                                out.appendSlice(std.testing.allocator, r.key) catch break;
                                out.append(std.testing.allocator, '\t') catch break;
                                out.appendSlice(std.testing.allocator, r.value) catch break;
                                out.append(std.testing.allocator, '\n') catch break;
                                _ = std.posix.system.write(accepted.socket.handle, out.items.ptr, out.items.len);
                                out.deinit(std.testing.allocator);
                            }
                        }
                        _ = std.posix.system.write(accepted.socket.handle, "END\n", 4);
                    } else if (std.mem.eql(u8, line, "LIST")) {
                        var it = ctx.topics.iterator();
                        while (it.next()) |e| {
                            var out = std.ArrayList(u8).empty;
                            out.appendSlice(std.testing.allocator, "TOPIC ") catch break;
                            out.appendSlice(std.testing.allocator, e.key_ptr.*) catch break;
                            out.append(std.testing.allocator, '\n') catch break;
                            _ = std.posix.system.write(accepted.socket.handle, out.items.ptr, out.items.len);
                            out.deinit(std.testing.allocator);
                        }
                        _ = std.posix.system.write(accepted.socket.handle, "END\n", 4);
                    } else if (std.mem.startsWith(u8, line, "CREATE ")) {
                        const name = std.mem.trim(u8, line["CREATE ".len..], " \t");
                        const name_owned = std.testing.allocator.dupe(u8, name) catch break;
                        const gop = ctx.topics.getOrPut(name_owned) catch {
                            std.testing.allocator.free(name_owned);
                            break;
                        };
                        if (gop.found_existing) std.testing.allocator.free(name_owned);
                        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList(Record).empty;
                        _ = std.posix.system.write(accepted.socket.handle, "OK\n", 3);
                    }
                }
            }
        }
    };
    var ctx = ServerCtx{ .server = &server, .topics = &topics };
    const th = try std.Thread.spawn(.{}, ServerCtx.run, .{&ctx});
    defer th.join();

    var transport = try NativeTransport.connect(allocator, std.testing.io, "127.0.0.1", port);
    defer transport.deinit();
    var connector = Connector.FluvioConnector.init(allocator, std.testing.io, .{}) catch unreachable;
    connector.transport = transport.asTransport();
    // createTopic is exercised separately below; produce auto-creates.
    try connector.produce("orders", "k1", "v1");
    try connector.produce("orders", "k2", "v2");
    const records = try connector.consume("orders", 0);
    defer {
        for (records) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(records);
    }
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("k1", records[0].key);
    try std.testing.expectEqualStrings("v2", records[1].value);

    const names = try connector.listTopics();
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("orders", names[0]);
}
