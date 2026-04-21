//! HTTP Server Stress Test
//!
//! This example demonstrates HTTP server load testing with concurrent clients.
//! Run with: cd examples/http-stress-test && zig build run

const std = @import("std");
const zigmodu = @import("zigmodu");

const Server = zigmodu.http_server.Server;
const Route = zigmodu.http_server.Route;
const Context = zigmodu.http_server.Context;

const NUM_CLIENTS: u32 = 20;
const REQUESTS_PER_CLIENT: u32 = 100;

const ClientTask = struct {
    io: std.Io,
    port: u16,
    completed: *u32,
    errors: *u32,
    request_body: []const u8,

    fn run(self: *ClientTask) void {
        var buf: [8192]u8 = undefined;

        var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch {
            self.errors.* += 1;
            return;
        };

        var conn = address.connect(self.io, .{.mode = .stream}) catch {
            self.errors.* += 1;
            return;
        };
        defer conn.close(self.io);

        var writer = conn.writer(self.io, &buf);
        writer.interface.writeAll(self.request_body) catch {
            self.errors.* += 1;
            return;
        };

        var reader = conn.reader(self.io, &buf);
        reader.interface.readSliceAll(&buf) catch {
            self.errors.* += 1;
            return;
        };

        self.completed.* += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const total_requests = NUM_CLIENTS * REQUESTS_PER_CLIENT;

    std.log.info("=== HTTP Server Stress Test ===", .{});
    std.log.info("Concurrent clients: {}", .{NUM_CLIENTS});
    std.log.info("Requests per client: {}", .{REQUESTS_PER_CLIENT});
    std.log.info("Total requests: {}", .{total_requests});
    std.log.info("================================", .{});

    // Initialize server
    var server = Server.init(io, allocator, 8080);
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

    // Start server in background thread
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Server) void {
            s.start() catch |err| {
                std.log.err("Server error: {}", .{err});
            };
        }
    }.run, .{&server});

    const port = server.port;
    std.log.info("Server listening on port {}", .{port});

    // Wait for server to be ready using a simple spin wait
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        // Try to connect to see if server is ready
        var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch continue;
        _ = address.connect(io, .{.mode = .stream}) catch continue;
        break;
    }

    // Prepare client tasks
    var threads: [NUM_CLIENTS]std.Thread = undefined;
    var task_args: [NUM_CLIENTS]ClientTask = undefined;
    var completed: u32 = 0;
    var errors: u32 = 0;

    const request_get = "GET /json HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const request_ping = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

    std.log.info("Starting stress test...", .{});

    const start_time = std.Io.Timestamp.now(io, .real).nanoseconds;

    // Launch client threads
    for (0..NUM_CLIENTS) |i| {
        const req = if (i % 3 == 0) request_ping else request_get;
        task_args[i] = ClientTask{
            .io = io,
            .port = port,
            .completed = &completed,
            .errors = &errors,
            .request_body = req,
        };
        threads[i] = try std.Thread.spawn(.{}, ClientTask.run, .{&task_args[i]});
    }

    // Wait for all clients
    for (threads) |t| {
        t.join();
    }

    const end_time = std.Io.Timestamp.now(io, .real).nanoseconds;
    const duration_secs = @as(f64, @floatFromInt(end_time - start_time)) / 1e9;

    // Stop server
    server.stop();
    server_thread.join();

    // Report results
    const rps = @as(f64, completed) / duration_secs;

    std.log.info("================================", .{});
    std.log.info("=== Stress Test Results ===", .{});
    std.log.info("Duration: {d:.2}s", .{duration_secs});
    std.log.info("Total requests: {}", .{total_requests});
    std.log.info("Completed: {}", .{completed});
    std.log.info("Errors: {}", .{errors});
    std.log.info("Requests/sec: {d:.2}", .{rps});
    std.log.info("Success rate: {d:.1}%", .{
        if (total_requests > 0) @as(f64, completed) / @as(f64, total_requests) * 100 else 0
    });
    std.log.info("================================", .{});

    if (errors > 0) {
        std.log.err("Stress test FAILED with {} errors", .{errors});
        return error.TestFailed;
    }

    std.log.info("Stress test PASSED - Server handled {d} requests/sec", .{rps});
}