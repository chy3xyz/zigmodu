//! Outbox poller for tenant-shop `outbox` table (TEXT status).
//!
//! pending → publish → published
//! on fail → retry_count++ ; if exhausted → status=dlq
//! Does not reuse framework `event_outbox` schema.

const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const mq = @import("mq.zig");

pub const Row = struct {
    id: i64,
    tenant_id: i64,
    topic: []const u8,
    payload: []const u8,
    status: []const u8,
    retry_count: i64,
    max_retries: i64,
    last_error: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

pub const PollResult = struct {
    published: u32 = 0,
    retried: u32 = 0,
    dlq: u32 = 0,
};

pub const Poller = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    db: *data.Client,
    publisher: *mq.Publisher,
    batch_size: u32,
    poll_interval_ms: u64,
    /// When true, next pollOnce treats publish as failed (smoke / ops).
    simulate_fail: std.atomic.Value(bool),
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        db: *data.Client,
        publisher: *mq.Publisher,
        batch_size: u32,
        poll_interval_ms: u64,
    ) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .db = db,
            .publisher = publisher,
            .batch_size = batch_size,
            .poll_interval_ms = poll_interval_ms,
            .simulate_fail = std.atomic.Value(bool).init(false),
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .monotonic);
    }

    pub fn setSimulateFail(self: *Self, on: bool) void {
        self.simulate_fail.store(on, .monotonic);
    }

    /// Drain up to `batch_size` pending rows.
    pub fn pollOnce(self: *Self) !PollResult {
        var result: PollResult = .{};
        const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());

        const sql = try std.fmt.allocPrint(
            self.allocator,
            \\SELECT id, tenant_id, topic, payload, status, retry_count, max_retries, last_error, created_at, updated_at
            \\FROM outbox WHERE status = 'pending' ORDER BY id ASC LIMIT {d}
        ,
            .{self.batch_size},
        );
        defer self.allocator.free(sql);

        const rows = try self.db.queryRowsPartial(Row, sql, &.{});
        defer self.allocator.free(rows);

        const force_fail = self.simulate_fail.load(.monotonic);

        for (rows) |row| {
            const key_buf = try std.fmt.allocPrint(self.allocator, "{d}", .{row.tenant_id});
            defer self.allocator.free(key_buf);

            const pub_err: ?anyerror = blk: {
                if (force_fail) break :blk error.SimulatedPublishFail;
                self.publisher.publish(row.topic, key_buf, row.payload) catch |err| break :blk err;
                break :blk null;
            };

            if (pub_err) |err| {
                const err_name = @errorName(err);
                const next_retry = row.retry_count + 1;
                if (next_retry >= row.max_retries) {
                    _ = try self.db.exec(
                        "UPDATE outbox SET status = 'dlq', retry_count = ?, last_error = ?, updated_at = ? WHERE id = ? AND status = 'pending'",
                        &.{
                            .{ .int = next_retry },
                            .{ .string = err_name },
                            .{ .int = now },
                            .{ .int = row.id },
                        },
                    );
                    result.dlq += 1;
                    std.log.warn("[outbox] DLQ id={d} topic={s} retries={d} err={s}", .{
                        row.id, row.topic, next_retry, err_name,
                    });
                } else {
                    _ = try self.db.exec(
                        "UPDATE outbox SET retry_count = ?, last_error = ?, updated_at = ? WHERE id = ? AND status = 'pending'",
                        &.{
                            .{ .int = next_retry },
                            .{ .string = err_name },
                            .{ .int = now },
                            .{ .int = row.id },
                        },
                    );
                    result.retried += 1;
                    std.log.warn("[outbox] retry id={d} topic={s} attempt={d}/{d} err={s}", .{
                        row.id, row.topic, next_retry, row.max_retries, err_name,
                    });
                }
                continue;
            }

            _ = try self.db.exec(
                "UPDATE outbox SET status = 'published', last_error = NULL, updated_at = ? WHERE id = ? AND status = 'pending'",
                &.{ .{ .int = now }, .{ .int = row.id } },
            );
            result.published += 1;
            std.log.info("[outbox] published id={d} topic={s}", .{ row.id, row.topic });
        }

        return result;
    }

    pub fn listRecent(self: *Self, limit: u32) ![]Row {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            \\SELECT id, tenant_id, topic, payload, status, retry_count, max_retries, last_error, created_at, updated_at
            \\FROM outbox ORDER BY id DESC LIMIT {d}
        ,
            .{limit},
        );
        defer self.allocator.free(sql);
        return try self.db.queryRowsPartial(Row, sql, &.{});
    }

    pub fn listByStatus(self: *Self, status: []const u8, limit: u32) ![]Row {
        const sql = try std.fmt.allocPrint(
            self.allocator,
            \\SELECT id, tenant_id, topic, payload, status, retry_count, max_retries, last_error, created_at, updated_at
            \\FROM outbox WHERE status = ? ORDER BY id DESC LIMIT {d}
        ,
            .{limit},
        );
        defer self.allocator.free(sql);
        return try self.db.queryRowsPartial(Row, sql, &.{.{ .string = status }});
    }

    /// Move DLQ row back to pending with retry_count reset.
    pub fn requeue(self: *Self, id: i64) !bool {
        const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
        const res = try self.db.exec(
            "UPDATE outbox SET status = 'pending', retry_count = 0, last_error = NULL, updated_at = ? WHERE id = ? AND status = 'dlq'",
            &.{ .{ .int = now }, .{ .int = id } },
        );
        return res.rows_affected == 1;
    }

    pub fn runLoop(self: *Self) void {
        while (self.running.load(.monotonic)) {
            const res = self.pollOnce() catch |err| blk: {
                std.log.err("[outbox] pollOnce error: {}", .{err});
                break :blk PollResult{};
            };
            if (res.published + res.retried + res.dlq > 0) {
                std.log.info("[outbox] batch published={d} retried={d} dlq={d}", .{
                    res.published, res.retried, res.dlq,
                });
            }
            const ns = self.poll_interval_ms *% std.time.ns_per_ms;
            std.Io.sleep(self.io, .{ .nanoseconds = @intCast(ns) }, .real) catch {};
        }
    }
};
