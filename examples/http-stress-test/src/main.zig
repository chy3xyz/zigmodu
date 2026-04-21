//! HTTP Server Stress Test
//!
//! This example demonstrates HTTP server load testing with concurrent clients.
//! Run with: cd examples/http-stress-test && zig build run

const std = @import("std");
const zigmodu = @import("zigmodu");

const Server = zigmodu.http_server.Server;
const Route = zigmodu.http_server.Route;
const Context = zigmodu.http_server.Context;

const NUM_CLIENTS: u32 = 32;
const REQUESTS_PER_CLIENT: u32 = 50;

const ClientTask = struct {
    io: std.Io,
    port: u16,
    completed: *std.atomic.Value(u32),
    errors: *std.atomic.Value(u32),
    request_body: []const u8,

    fn run(self: *ClientTask) void {
        var write_buf: [1024]u8 = undefined;
        var read_buf: [8192]u8 = undefined;

        var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch {
            _ = self.errors.fetchAdd(1, .monotonic);
            return;
        };

        var conn = address.connect(self.io, .{ .mode = .stream }) catch {
            _ = self.errors.fetchAdd(1, .monotonic);
            return;
        };
        defer conn.close(self.io);

        var writer = conn.writer(self.io, &write_buf);
        writer.interface.writeAll(self.request_body) catch {
            _ = self.errors.fetchAdd(1, .monotonic);
            return;
        };
        writer.interface.flush() catch {
            _ = self.errors.fetchAdd(1, .monotonic);
            return;
        };

        // Drain the response so the server side can complete its write cleanly.
        var reader = conn.reader(self.io, &read_buf);
        var total_read: usize = 0;
        while (true) {
            const n = reader.interface.readSliceShort(&read_buf) catch {
                _ = self.errors.fetchAdd(1, .monotonic);
                return;
            };
            if (n == 0) break;
            total_read += n;
            if (total_read > 1024 * 1024) break; // safety cap
        }

        _ = self.completed.fetchAdd(1, .monotonic);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Give the stress test enough fibers for the accept loop + all clients + server
    // connection fibers so scheduling does not degrade to inline execution under the
    // default `CPU-1` limit.
    var threaded = std.Io.Threaded.init(allocator, .{
        .async_limit = .limited(64),
    });
    defer threaded.deinit();

    var io = threaded.io();

    try mainFiber(&io, allocator);
}

fn mainFiber(io: *std.Io, allocator: std.mem.Allocator) !void {
    const total_requests = NUM_CLIENTS * REQUESTS_PER_CLIENT;

    std.log.info("=== HTTP Server Stress Test ===", .{});
    std.log.info("Concurrent clients: {}", .{NUM_CLIENTS});
    std.log.info("Requests per client: {}", .{REQUESTS_PER_CLIENT});
    std.log.info("Total requests: {}", .{total_requests});
    std.log.info("================================", .{});

    // Initialize server
    var server = Server.init(io.*, allocator, 8080);
    defer server.deinit();

    // Setup routes
    try server.addRoute(.{
        .method = .GET,
        .path = "/json",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.json(200, "{\"status\":\"ok\",\"message\":\"Hello from stress test\"}");
            }
        }.handle,
    });

    try server.addRoute(.{
        .method = .GET,
        .path = "/ping",
        .handler = struct {
            fn handle(ctx: *Context) anyerror!void {
                try ctx.text(200, "pong");
            }
        }.handle,
    });

    // Spawn server + client fibers inside a single group so all their
    // futures are released deterministically before main returns.
    var server_group: std.Io.Group = .init;
    defer server_group.await(io.*) catch {};

    var client_group: std.Io.Group = .init;
    defer client_group.await(io.*) catch {};

    server_group.async(io.*, struct {
        fn run(s: *Server) void {
            s.start() catch |err| std.log.err("Server error: {}", .{err});
        }
    }.run, .{&server});

    const port = server.port;
    std.log.info("Server listening on port {}", .{port});

    // Wait for server to be ready
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch {
            try std.Io.sleep(io.*, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real);
            continue;
        };
        var conn = address.connect(io.*, .{ .mode = .stream }) catch {
            try std.Io.sleep(io.*, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real);
            continue;
        };
        conn.close(io.*);
        break;
    }

    // Prepare client tasks
    var completed = std.atomic.Value(u32).init(0);
    var errors = std.atomic.Value(u32).init(0);

    const request_get = "GET /json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const request_ping = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    std.log.info("Starting stress test...", .{});

    const start_time = std.Io.Timestamp.now(io.*, .real).nanoseconds;

    var tasks: [NUM_CLIENTS * REQUESTS_PER_CLIENT]ClientTask = undefined;
    for (0..total_requests) |idx| {
        const i: u32 = @intCast(idx);
        const req = if (i % 3 == 0) request_ping else request_get;
        tasks[idx] = .{
            .io = io.*,
            .port = port,
            .completed = &completed,
            .errors = &errors,
            .request_body = req,
        };
        client_group.async(io.*, ClientTask.run, .{&tasks[idx]});
    }

    // Wait until all clients complete
    while ((completed.load(.monotonic) + errors.load(.monotonic)) < total_requests) {
        try std.Io.sleep(io.*, .{ .nanoseconds = 1 * std.time.ns_per_ms }, .real);
    }

    const end_time = std.Io.Timestamp.now(io.*, .real).nanoseconds;
    const duration_secs = @as(f64, @floatFromInt(end_time - start_time)) / 1e9;

    // Stop server
    server.stop();

    // Give accept loop a moment to observe stop
    try std.Io.sleep(io.*, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .real);

    // Report results
    const completed_n = completed.load(.monotonic);
    const errors_n = errors.load(.monotonic);
    const rps = @as(f64, completed_n) / duration_secs;

    std.log.info("================================", .{});
    std.log.info("=== Stress Test Results ===", .{});
    std.log.info("Duration: {d:.2}s", .{duration_secs});
    std.log.info("Total requests: {}", .{total_requests});
    std.log.info("Completed: {}", .{completed_n});
    std.log.info("Errors: {}", .{errors_n});
    std.log.info("Requests/sec: {d:.2}", .{rps});
    std.log.info("Success rate: {d:.1}%", .{
        if (total_requests > 0) @as(f64, completed_n) / @as(f64, total_requests) * 100 else 0,
    });
    std.log.info("================================", .{});

    if (errors_n > 0) {
        std.log.err("Stress test FAILED with {} errors", .{errors_n});
        return error.TestFailed;
    }

    std.log.info("Stress test PASSED - Server handled {d} requests/sec", .{rps});
}