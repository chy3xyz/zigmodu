const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const outbox = @import("../foundation/outbox.zig");

/// Ops endpoints for outbox drain / DLQ / requeue.
pub fn OutboxApi(comptime Poller: type) type {
    return struct {
        const Self = @This();
        poller: *Poller,

        pub const module_name = "outbox";
        pub const nest = .{"outbox"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .POST, .path = "drain", .handler = drain },
            .{ .method = .GET, .path = "", .handler = list },
            .{ .method = .GET, .path = "dlq", .handler = listDlq },
            .{ .method = .POST, .path = "requeue", .handler = requeue },
        };

        pub fn init(poller: *Poller) Self {
            return .{ .poller = poller };
        }

        fn writeRows(ctx: *http.Context, rows: []const outbox.Row) !void {
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"outbox\":[");
            for (rows, 0..) |r, i| {
                if (i > 0) try buf.appendSlice(ctx.allocator, ",");
                const err_s = r.last_error orelse "";
                const entry = try std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{d},"tenant_id":{d},"topic":"{s}","status":"{s}","retry_count":{d},"max_retries":{d},"last_error":"{s}"}}
                , .{ r.id, r.tenant_id, r.topic, r.status, r.retry_count, r.max_retries, err_s });
                defer ctx.allocator.free(entry);
                try buf.appendSlice(ctx.allocator, entry);
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn drain(ctx: *http.Context, self: *State) !void {
            const sim = ctx.queryParam("simulate_fail");
            const want_fail = if (sim) |s| std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true") else false;
            self.poller.setSimulateFail(want_fail);
            defer self.poller.setSimulateFail(false);

            const res = self.poller.pollOnce() catch {
                try ctx.sendErrorResponse(500, 0, "outbox drain failed");
                return;
            };
            const resp = try std.fmt.allocPrint(ctx.allocator,
                \\{{"published":{d},"retried":{d},"dlq":{d}}}
            , .{ res.published, res.retried, res.dlq });
            defer ctx.allocator.free(resp);
            try ctx.json(200, resp);
        }

        fn list(ctx: *http.Context, self: *State) !void {
            if (ctx.queryParam("status")) |st| {
                var rows_qr = self.poller.listByStatus(st, 50) catch {
                    try ctx.sendErrorResponse(500, 0, "outbox list failed");
                    return;
                };
                defer rows_qr.deinit(ctx.allocator);
                try writeRows(ctx, rows_qr.items);
                return;
            }
            var rows_qr = self.poller.listRecent(50) catch {
                try ctx.sendErrorResponse(500, 0, "outbox list failed");
                return;
            };
            defer rows_qr.deinit(ctx.allocator);
            try writeRows(ctx, rows_qr.items);
        }

        fn listDlq(ctx: *http.Context, self: *State) !void {
            var rows_qr = self.poller.listByStatus("dlq", 50) catch {
                try ctx.sendErrorResponse(500, 0, "outbox dlq list failed");
                return;
            };
            defer rows_qr.deinit(ctx.allocator);
            try writeRows(ctx, rows_qr.items);
        }

        fn requeue(ctx: *http.Context, self: *State) !void {
            const id_s = ctx.queryParam("id") orelse {
                try ctx.sendErrorResponse(400, 0, "Missing id");
                return;
            };
            const id = try std.fmt.parseInt(i64, id_s, 10);
            const ok = self.poller.requeue(id) catch {
                try ctx.sendErrorResponse(500, 0, "requeue failed");
                return;
            };
            if (!ok) {
                try ctx.sendErrorResponse(404, 0, "DLQ entry not found");
                return;
            }
            try ctx.json(200, "{\"status\":\"requeued\"}");
        }
    };
}

pub const DefaultOutboxApi = OutboxApi(outbox.Poller);
