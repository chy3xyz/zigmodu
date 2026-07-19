//! Shared outbox INSERT for use inside a DB transaction.
const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;

/// Insert a pending outbox row (retry_count=0, max_retries=3).
pub fn insertPending(
    tx: *data.sqlx.Transaction,
    tenant_id: i64,
    topic: []const u8,
    payload: []const u8,
    now: i64,
) !void {
    _ = try tx.exec(
        "INSERT INTO outbox (tenant_id, topic, payload, status, retry_count, max_retries, created_at, updated_at) VALUES (?, ?, ?, ?, 0, 3, ?, ?)",
        &.{
            .{ .int = tenant_id },
            .{ .string = topic },
            .{ .string = payload },
            .{ .string = "pending" },
            .{ .int = now },
            .{ .int = now },
        },
    );
}
