//! Outbox consumer — the read side of the transactional outbox pattern.
//! Polls pending entries (optionally filtered by topic), dispatches each to a
//! registered handler and advances the lifecycle: pending → processing →
//! delivered, or retry_count++ (→ failed once retries are exhausted). This
//! closes the loop for the AI business tools (`ai.approval`, `ai.recon`,
//! `ai.notify`, ...) whose outbox writebacks can be routed to handlers here
//! (or paired with `zigmodu.ai.trigger`).

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const Outbox = @import("OutboxPublisher.zig");

pub const OutboxEntry = Outbox.OutboxEntry;

/// Handler invoked for each dispatched entry. `userdata` carries app state.
pub const OutboxHandlerFn = *const fn (
    userdata: *anyopaque,
    allocator: std.mem.Allocator,
    entry: OutboxEntry,
) anyerror!void;

pub const OutboxConsumerConfig = struct {
    batch_size: usize = 100,
    /// When set, only entries with this topic are consumed.
    topic_filter: ?[]const u8 = null,
};

pub const PollStats = struct {
    selected: usize,
    delivered: usize,
    failed: usize,
};

pub const OutboxConsumer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    config: OutboxConsumerConfig,
    userdata: *anyopaque,
    handler: OutboxHandlerFn,

    pub fn init(
        allocator: std.mem.Allocator,
        backend: *SqlxBackend,
        config: OutboxConsumerConfig,
        userdata: *anyopaque,
        handler: OutboxHandlerFn,
    ) Self {
        return .{ .allocator = allocator, .backend = backend, .config = config, .userdata = userdata, .handler = handler };
    }

    /// Poll one batch of pending entries and dispatch them. Returns how many
    /// were selected / delivered / permanently failed.
    pub fn pollOnce(self: *Self) !PollStats {
        const select = try self.buildSelectPending();
        defer self.allocator.free(select);

        var cursor = try self.backend.client.queryCursorEx(select, &.{}, .{});
        defer cursor.deinit();

        var stats = PollStats{ .selected = 0, .delivered = 0, .failed = 0 };
        while (cursor.next()) |row| {
            const entry = self.parseEntry(row) catch continue;
            stats.selected += 1;
            _ = try self.backend.exec("UPDATE event_outbox SET status = 1, updated_at = ? WHERE id = ?", &.{
                .{ .int = @intCast(entry.created_at) }, .{ .int = entry.id },
            });

            // Topic/payload live in the cursor arena; hand the handler stable
            // copies that survive until the cursor is freed.
            const topic_copy = try self.allocator.dupe(u8, entry.topic);
            const payload_copy = try self.allocator.dupe(u8, entry.payload);
            defer self.allocator.free(topic_copy);
            defer self.allocator.free(payload_copy);
            var stable_entry = entry;
            stable_entry.topic = topic_copy;
            stable_entry.payload = payload_copy;

            const handled = self.handler(self.userdata, self.allocator, stable_entry);
            if (handled) |_| {
                _ = try self.backend.exec("UPDATE event_outbox SET status = 2, updated_at = ? WHERE id = ?", &.{
                    .{ .int = @intCast(entry.created_at) }, .{ .int = entry.id },
                });
                stats.delivered += 1;
            } else |err| {
                const new_retry = entry.retry_count + 1;
                if (new_retry >= entry.max_retries) {
                    _ = try self.backend.exec(
                        "UPDATE event_outbox SET status = 3, retry_count = ?, error_message = ?, updated_at = ? WHERE id = ?",
                        &.{
                            .{ .int = @intCast(new_retry) },
                            .{ .string = @errorName(err) },
                            .{ .int = @intCast(entry.created_at) },
                            .{ .int = entry.id },
                        },
                    );
                    stats.failed += 1;
                } else {
                    _ = try self.backend.exec(
                        "UPDATE event_outbox SET retry_count = ?, error_message = ?, updated_at = ? WHERE id = ?",
                        &.{
                            .{ .int = @intCast(new_retry) },
                            .{ .string = @errorName(err) },
                            .{ .int = @intCast(entry.created_at) },
                            .{ .int = entry.id },
                        },
                    );
                }
            }
        }
        return stats;
    }

    fn buildSelectPending(self: *Self) ![]const u8 {
        if (self.config.topic_filter) |topic| {
            return std.fmt.allocPrint(
                self.allocator,
                "SELECT id, topic, payload, status, retry_count, max_retries, created_at, updated_at, error_message FROM event_outbox WHERE status IN (0, 1) AND retry_count < max_retries AND topic = '{s}' ORDER BY created_at ASC LIMIT {d}",
                .{ topic, self.config.batch_size },
            );
        }
        return std.fmt.allocPrint(
            self.allocator,
            "SELECT id, topic, payload, status, retry_count, max_retries, created_at, updated_at, error_message FROM event_outbox WHERE status IN (0, 1) AND retry_count < max_retries ORDER BY created_at ASC LIMIT {d}",
            .{self.config.batch_size},
        );
    }

    fn parseEntry(self: *Self, row: *@import("../sqlx/sqlx.zig").Row) !OutboxEntry {
        _ = self;
        const id_v = row.get("id") orelse return error.MissingColumn;
        const topic = row.get("topic") orelse return error.MissingColumn;
        const payload = row.get("payload") orelse return error.MissingColumn;
        const status_v = row.get("status") orelse return error.MissingColumn;
        const retry_v = row.get("retry_count") orelse return error.MissingColumn;
        const max_v = row.get("max_retries") orelse return error.MissingColumn;
        const created_v = row.get("created_at") orelse return error.MissingColumn;
        const updated_v = row.get("updated_at") orelse return error.MissingColumn;
        const error_v = row.get("error_message");

        return .{
            .id = id_v.int,
            .topic = topic.string,
            .payload = payload.string,
            .status = @enumFromInt(@as(u8, @intCast(status_v.int))),
            .retry_count = @intCast(retry_v.int),
            .max_retries = @intCast(max_v.int),
            .created_at = created_v.int,
            .updated_at = updated_v.int,
            .error_message = if (error_v) |ev| ev.string else null,
        };
    }
};

test "OutboxConsumer dispatches pending entries and updates lifecycle" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec(
        "INSERT INTO event_outbox (topic, payload, status, retry_count, max_retries, created_at, updated_at) VALUES ('ai.approval', '{\"run\":1}', 0, 0, 3, 100, 100), ('ai.recon', '{\"run\":2}', 0, 0, 3, 101, 101)",
        &.{},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const State = struct {
        var handled: usize = 0;
        var last_topic: [32]u8 = undefined;
        var last_topic_len: usize = 0;
    };
    const Handler = struct {
        fn call(_: *anyopaque, a: std.mem.Allocator, entry: OutboxEntry) anyerror!void {
            State.handled += 1;
            // Copies are only valid for the duration of the call; the handler
            // must copy anything it keeps.
            @memcpy(State.last_topic[0..@min(entry.topic.len, State.last_topic.len)], entry.topic[0..@min(entry.topic.len, State.last_topic.len)]);
            State.last_topic_len = entry.topic.len;
            _ = a;
        }
    };
    var dummy: u8 = 0;
    var consumer = OutboxConsumer.init(
        allocator,
        &backend,
        .{ .batch_size = 10, .topic_filter = "ai.approval" },
        &dummy,
        Handler.call,
    );

    const stats = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 1), stats.selected);
    try std.testing.expectEqual(@as(usize, 1), stats.delivered);
    try std.testing.expectEqualStrings("ai.approval", State.last_topic[0..State.last_topic_len]);

    // Delivered entry is no longer pending; the other topic is untouched.
    var cursor = try client.queryCursorEx(
        "SELECT topic, status FROM event_outbox ORDER BY id",
        &.{},
        .{},
    );
    defer cursor.deinit();
    const r1 = cursor.next().?;
    try std.testing.expectEqualStrings("ai.approval", r1.get("topic").?.string);
    try std.testing.expectEqual(@as(i64, 2), r1.get("status").?.int);
    const r2 = cursor.next().?;
    try std.testing.expectEqualStrings("ai.recon", r2.get("topic").?.string);
    try std.testing.expectEqual(@as(i64, 0), r2.get("status").?.int);
}

test "OutboxConsumer marks retry then fails on persistent handler errors" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 2, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec(
        "INSERT INTO event_outbox (topic, payload, status, retry_count, max_retries, created_at, updated_at) VALUES ('ai.notify', '{}', 0, 1, 2, 100, 100)",
        &.{},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const Handler = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: OutboxEntry) anyerror!void {
            return error.DeliveryFailed;
        }
    };
    var dummy: u8 = 0;
    var consumer = OutboxConsumer.init(allocator, &backend, .{}, &dummy, Handler.call);

    // retry_count 1 + 1 = 2 == max_retries → moves to failed.
    const stats = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 1), stats.selected);
    try std.testing.expectEqual(@as(usize, 1), stats.failed);

    var cursor = try client.queryCursorEx("SELECT status, retry_count, error_message FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next().?;
    try std.testing.expectEqual(@as(i64, 3), row.get("status").?.int);
    try std.testing.expectEqual(@as(i64, 2), row.get("retry_count").?.int);
    try std.testing.expectEqualStrings("DeliveryFailed", row.get("error_message").?.string);
}
