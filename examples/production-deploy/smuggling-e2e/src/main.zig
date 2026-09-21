//! Request-boundary probe: the smallest ZigModu server that makes a
//! front-end/back-end framing disagreement **observable** instead of argued.
//!
//! Two routes, deliberately asymmetric:
//!
//!     GET /ping   → 200 {"who":"ping"}
//!     GET /admin  → 200 {"who":"admin"}      ← the smuggled target
//!
//! Every dispatched request writes one line to stderr:
//!
//!     REQLOG <METHOD> <raw_path>
//!
//! `scripts/run.sh` asserts that `REQLOG GET /admin` never appears when the
//! client's single write was a CL/TE smuggling payload. If it does appear, the
//! gateway and this server disagreed about where the request ended — and the
//! disagreement is now a two-line diff instead of a paragraph of reasoning.
//!
//! This is a probe, not an app: no modules, no DB, no auth.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const port: u16 = blk: {
        const raw = init.environ_map.get("HTTP_PORT") orelse break :blk 18080;
        break :blk std.fmt.parseInt(u16, raw, 10) catch 18080;
    };

    var server = http.Server.init(io, allocator, port);
    defer server.deinit();

    // Every request the backend *received*, not just the ones that reached a
    // handler: a smuggled request to a path with no route is still a request
    // this server accepted, and a log that skips it would make a mismatch
    // invisible in exactly the case worth catching.
    try server.addMiddleware(.{ .func = logEveryRequest });

    try server.addRoute(.{ .method = .GET, .path = "ping", .handler = ping });
    try server.addRoute(.{ .method = .GET, .path = "admin", .handler = admin });
    try server.addRoute(.{ .method = .GET, .path = "health/live", .handler = health });

    // The harness waits for this line rather than polling the port: "listening"
    // and "ready to accept" are not the same event, and the difference is a
    // flaky e2e.
    std.log.warn("READY port={d}", .{port});
    try server.start();
}

fn logEveryRequest(ctx: *http.Context, next: http.HandlerFn, user_data: ?*anyopaque) anyerror!void {
    _ = user_data;
    // `warn`, not `err`: several harnesses in this repo treat error-level log
    // lines as failures, and a served request is not an error.
    std.log.warn("REQLOG {s} {s}", .{ @tagName(ctx.method), ctx.raw_path });
    try next(ctx);
}

fn ping(ctx: *http.Context) !void {
    try ctx.json(200, "{\"who\":\"ping\"}");
}

fn admin(ctx: *http.Context) !void {
    try ctx.json(200, "{\"who\":\"admin\"}");
}

fn health(ctx: *http.Context) !void {
    try ctx.json(200, "{\"status\":\"UP\"}");
}
