//! Outbox demo over zent's schema-as-code outbox: transactional enqueue
//! (event row written in the same transaction as the business change) and
//! at-least-once dispatch — both on demand (HTTP) and on a cron schedule.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const zent = @import("zent");
const persist = @import("modules/catalog/persistence.zig");

/// Dispatcher shared by the HTTP endpoint and the cron job. In production the
/// cron would use a pooled client (zent sql_pool) so the background thread
/// never shares a connection with request fibers.
pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    client: *persist.Client,
    io: std.Io,

    fn nowMs(self: *const Dispatcher) i64 {
        const ts = std.Io.Timestamp.now(self.io, .real);
        return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
    }

    fn publish(ctx: ?*anyopaque, entry: zent.outbox.Entry) anyerror!void {
        _ = ctx;
        std.log.info("[outbox] publish {s}#{d} {s} payload={s}", .{
            entry.aggregate_type,
            entry.aggregate_id,
            entry.event_type,
            entry.payload,
        });
    }

    /// Poll pending rows and publish them; failures are requeued with an
    /// incremented attempt counter (permanently failed after max_attempts).
    pub fn dispatchOnce(self: *Dispatcher) !usize {
        const Outbox = zent.outbox.Outbox(persist.infos, persist.OutboxInfo);
        return Outbox.dispatch(self.allocator, self.client.*, self.nowMs(), .{
            .ctx = null,
            .call = publish,
        }, 100, 3);
    }
};

/// ComptimeRouter API: POST /api/v1/outbox/enqueue + /api/v1/outbox/dispatch.
pub fn OutboxDemoApi() type {
    return struct {
        const Self = @This();

        dispatcher: *Dispatcher,

        pub const module_name = "outbox";
        pub const nest = .{"outbox"};
        pub const State = Self;

        pub fn init(dispatcher: *Dispatcher) Self {
            return .{ .dispatcher = dispatcher };
        }

        const EnqueueQ = struct {
            aggregate_type: []const u8,
            aggregate_id: i64,
            event_type: []const u8,
            payload: []const u8 = "{}",
        };

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "enqueue", .handler = enqueue, .meta = .{ .auth = .public } },
            .{ .method = .POST, .path = "dispatch", .handler = dispatch, .meta = .{ .auth = .public } },
        };

        fn enqueue(ctx: *http.Context, self: *State) !void {
            const q = http.extractQuery(ctx, EnqueueQ) catch |err| return http.respondErr(ctx, err);
            const Outbox = zent.outbox.Outbox(persist.infos, persist.OutboxInfo);
            var tx = zent.codegen.client.beginTx(persist.infos, self.dispatcher.client.*) catch |err| return http.respondErr(ctx, err);
            defer tx.deinit();
            const id = Outbox.enqueueTx(tx, self.dispatcher.nowMs(), .{
                .aggregate_type = q.aggregate_type,
                .aggregate_id = q.aggregate_id,
                .event_type = q.event_type,
                .payload = q.payload,
            }) catch |err| return http.respondErr(ctx, err);
            tx.commit() catch |err| return http.respondErr(ctx, err);
            try ctx.jsonStruct(201, .{ .id = id });
        }

        fn dispatch(ctx: *http.Context, self: *State) !void {
            const n = self.dispatcher.dispatchOnce() catch |err| return http.respondErr(ctx, err);
            try ctx.jsonStruct(200, .{ .dispatched = n });
        }
    };
}
