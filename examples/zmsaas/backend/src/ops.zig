//! Ops endpoints — outbox delivery flush.
//! 生产把 deliverPending 挂到 cron 周期任务或 DistributedEventBus 消费者；
//! 示例用 POST /api/v1/outbox/flush 在请求线程内演示投递（单线程安全、
//! 兼容 :memory:）。
const std = @import("std");
const zigmodu = @import("zigmodu");

/// 投递回调：这里接 DistributedEventBus / Kafka / webhook。
fn deliver(topic: []const u8, payload: []const u8) anyerror!void {
    std.log.info("[outbox] delivered topic={s} payload={s}", .{ topic, payload });
}

/// 一轮投递：SELECT pending → mark processing → publish → mark delivered；
/// 失败按 retry_count 标记重试或永久失败。
pub fn deliverPending(allocator: std.mem.Allocator, client: *zigmodu.data.Client) !void {
    var poller = zigmodu.outbox.OutboxPoller.init(allocator, .{}, deliver);
    const select_sql = try poller.buildSelectPending();
    defer allocator.free(select_sql);
    // OutboxEntry.status is an enum — scan a plain row shape and map.
    const PendingRow = struct {
        id: i64,
        topic: []const u8,
        payload: []const u8,
        status: i64,
        retry_count: u32,
        max_retries: u32,
        created_at: i64,
        updated_at: i64,
        error_message: ?[]const u8,
    };
    var rows = try client.queryRows(PendingRow, select_sql, &.{});
    defer rows.deinit(allocator);

    for (rows.items) |entry| {
        const outbox_entry = zigmodu.outbox.OutboxEntry{
            .id = entry.id,
            .topic = entry.topic,
            .payload = entry.payload,
            .status = @fromBackingInt(@intCast(entry.status)),
            .retry_count = entry.retry_count,
            .max_retries = entry.max_retries,
            .created_at = entry.created_at,
            .updated_at = entry.updated_at,
            .error_message = entry.error_message,
        };
        const proc_sql = try poller.buildMarkProcessing(outbox_entry.id);
        defer allocator.free(proc_sql);
        _ = try client.exec(proc_sql, &.{});

        deliver(outbox_entry.topic, outbox_entry.payload) catch |err| {
            const retry = outbox_entry.retry_count + 1;
            if (retry >= outbox_entry.max_retries) {
                const fail_sql = try poller.buildMarkFailed(outbox_entry.id, @errorName(err));
                defer allocator.free(fail_sql);
                _ = client.exec(fail_sql, &.{}) catch {};
            } else {
                const retry_sql = try poller.buildMarkRetry(outbox_entry.id, retry, @errorName(err));
                defer allocator.free(retry_sql);
                _ = client.exec(retry_sql, &.{}) catch {};
            }
            continue;
        };

        const done_sql = try poller.buildMarkDelivered(outbox_entry.id);
        defer allocator.free(done_sql);
        _ = try client.exec(done_sql, &.{});
    }
}

/// OpsApi — mounted under /api/v1 (JWT + orders:write).
pub const OpsApi = struct {
    pub const module_name = "outbox";
    pub const nest = .{"outbox"};
    pub const State = @This();

    client: *zigmodu.data.Client,

    pub fn init(client: *zigmodu.data.Client) @This() {
        return .{ .client = client };
    }

    pub const routes = [_]zigmodu.http.RouteSpec(State){
        .{ .method = .POST, .path = "flush", .handler = flush, .meta = .{ .auth = .jwt, .permission = "orders:write" } },
    };

    fn flush(ctx: *zigmodu.http.Context, self: *State) !void {
        deliverPending(ctx.allocator, self.client) catch |err| return zigmodu.http.respondErr(ctx, err);
        try ctx.jsonStruct(200, .{ .code = 0, .status = "flushed" });
    }
};
