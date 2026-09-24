//! Outbox consumer — the read side of the transactional outbox pattern.
//! Polls pending entries (optionally filtered by topic), dispatches each to a
//! registered handler and advances the lifecycle: pending → processing →
//! delivered, or retry_count++ (→ failed once retries are exhausted). A row
//! that cannot even be parsed is failed outright (dead-lettered) rather than
//! left in the pending set, where it would block the queue silently. This
//! closes the loop for the AI business tools (`ai.approval`, `ai.recon`,
//! `ai.notify`, ...) whose outbox writebacks can be routed to handlers here
//! (or paired with `zigmodu.ai.trigger`).

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const Outbox = @import("OutboxPublisher.zig");
const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
const sqlx = @import("../sqlx/sqlx.zig");
const Time = @import("../core/Time.zig");

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

/// Optional metric handles. Wire with `setMetrics` so a stalled outbox shows up
/// as a flat `outbox_delivered_total` plus a rising `outbox_pending` gauge,
/// instead of the "business says it never arrived, logs say nothing" failure
/// mode this pattern is famous for.
pub const Metrics = struct {
    selected: *PrometheusMetrics.Counter,
    delivered: *PrometheusMetrics.Counter,
    failed: *PrometheusMetrics.Counter,
    pending: ?*PrometheusMetrics.Gauge = null,
};

pub const OutboxConsumer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    config: OutboxConsumerConfig,
    userdata: *anyopaque,
    handler: OutboxHandlerFn,
    metrics: ?Metrics = null,
    io: ?std.Io = null,
    poll_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_interval_ms: u64 = 1000,
    /// Consecutive poll failures, for operators to alert on.
    consecutive_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        backend: *SqlxBackend,
        config: OutboxConsumerConfig,
        userdata: *anyopaque,
        handler: OutboxHandlerFn,
    ) Self {
        return .{ .allocator = allocator, .backend = backend, .config = config, .userdata = userdata, .handler = handler };
    }

    /// Attach Prometheus handles. Creates the counters against `metrics`;
    /// `pending` is refreshed on every poll and on demand via `refreshPending`.
    pub fn setMetrics(self: *Self, metrics: *PrometheusMetrics) !void {
        self.metrics = .{
            .selected = try metrics.createCounter("outbox_selected_total", "Outbox entries picked up for delivery"),
            .delivered = try metrics.createCounter("outbox_delivered_total", "Outbox entries delivered successfully"),
            .failed = try metrics.createCounter("outbox_failed_total", "Outbox entries permanently failed (retries exhausted or unparseable)"),
            .pending = metrics.createGauge("outbox_pending", "Outbox entries waiting to be delivered") catch null,
        };
    }

    /// Refresh the `outbox_pending` gauge (also called after each poll).
    pub fn refreshPending(self: *Self) void {
        const m = self.metrics orelse return;
        const gauge = m.pending orelse return;
        gauge.set(@floatFromInt(self.pendingCount() catch return));
    }

    /// Pending entries (`status IN (0,1)` and retries left). This is the number
    /// that must not keep growing.
    pub fn pendingCount(self: *Self) !u64 {
        const Sql = struct { n: i64 };
        var rows = try self.backend.client.queryRows(Sql, "SELECT COUNT(*) AS n FROM event_outbox WHERE status IN (0, 1)", &.{});
        defer rows.deinit(self.allocator);
        if (rows.items.len == 0) return 0;
        return @intCast(@max(0, rows.items[0].n));
    }

    /// Dispatch in the background every `interval_ms` (replaces the
    /// hand-rolled cron job; a multi-replica deployment still wants
    /// `DistributedLock` around it). Idempotent.
    pub fn startPolling(self: *Self, io: std.Io, interval_ms: u64) !void {
        if (self.running.load(.monotonic)) return;
        self.io = io;
        self.poll_interval_ms = interval_ms;
        self.running.store(true, .monotonic);
        self.poll_thread = try std.Thread.spawn(.{}, pollLoop, .{self});
    }

    /// Stop the background poller and join it.
    pub fn stopPolling(self: *Self) void {
        self.running.store(false, .monotonic);
        if (self.poll_thread) |t| {
            t.join();
            self.poll_thread = null;
        }
    }

    fn pollLoop(self: *Self) void {
        const io = self.io orelse return;
        while (self.running.load(.monotonic)) {
            _ = self.pollOnce() catch |err| {
                _ = self.consecutive_failures.fetchAdd(1, .monotonic);
                std.log.err("[outbox] poll failed ({s}); pending delivery stalled", .{@errorName(err)});
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(self.poll_interval_ms)), .real) catch |sleep_err| std.log.debug("[outbox] poll sleep interrupted ({s})", .{@errorName(sleep_err)});
                continue;
            };
            self.consecutive_failures.store(0, .monotonic);
            self.refreshPending();
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(self.poll_interval_ms)), .real) catch |err| std.log.debug("[outbox] poll sleep interrupted ({s})", .{@errorName(err)});
        }
    }

    /// Poll one batch of pending entries and dispatch them. Returns how many
    /// were selected / delivered / permanently failed.
    pub fn pollOnce(self: *Self) !PollStats {
        const select = try self.buildSelectPending();
        defer self.allocator.free(select);

        var arg_buf: [1]sqlx.Value = undefined;
        var cursor = try self.backend.client.queryCursorEx(select, self.pendingArgs(&arg_buf), .{});
        defer cursor.deinit();

        var stats = PollStats{ .selected = 0, .delivered = 0, .failed = 0 };
        while (try cursor.next()) |row| {
            const entry = self.parseEntry(row) catch |err| {
                // A row that cannot be parsed can never be delivered, and
                // leaving it pending makes it the head of every batch forever:
                // the poller spins on it while everything behind it stays put
                // and no counter moves. Dead-letter it instead.
                stats.selected += 1;
                stats.failed += 1;
                try self.quarantine(row, err);
                continue;
            };
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
        if (self.metrics) |m| {
            m.selected.add(@intCast(stats.selected));
            m.delivered.add(@intCast(stats.delivered));
            m.failed.add(@intCast(stats.failed));
        }
        return stats;
    }

    /// Pending-batch SELECT. The topic is **bound** (`?`), never interpolated:
    /// the filter comes from configuration, and a quote in it used to end the
    /// string literal and change the statement (recorded as low severity in
    /// `docs/dev/security-audit-v0.31.0.md` and left unfixed until now). The
    /// caller supplies the argument — see `pendingArgs`.
    fn buildSelectPending(self: *Self) ![]const u8 {
        if (self.config.topic_filter != null) {
            return std.fmt.allocPrint(
                self.allocator,
                "SELECT id, topic, payload, status, retry_count, max_retries, created_at, updated_at, error_message FROM event_outbox WHERE status IN (0, 1) AND retry_count < max_retries AND topic = ? ORDER BY created_at ASC LIMIT {d}",
                .{self.config.batch_size},
            );
        }
        return std.fmt.allocPrint(
            self.allocator,
            "SELECT id, topic, payload, status, retry_count, max_retries, created_at, updated_at, error_message FROM event_outbox WHERE status IN (0, 1) AND retry_count < max_retries ORDER BY created_at ASC LIMIT {d}",
            .{self.config.batch_size},
        );
    }

    /// Arguments for `buildSelectPending`: the bound topic when a filter is
    /// configured, otherwise none. `buf` is caller-owned scratch, one slot per
    /// possible filter.
    fn pendingArgs(self: *const Self, buf: *[1]sqlx.Value) []const sqlx.Value {
        if (self.config.topic_filter) |topic| {
            buf[0] = .{ .string = topic };
            return buf[0..1];
        }
        return &.{};
    }

    /// Dead-letter a row that could not be parsed (`status = 3`, the same
    /// disposition a handler failure ends in). Nothing else in this file can
    /// retire such a row, and `OutboxPublisher.buildResubmit` is the existing
    /// way back once the schema or the data is fixed.
    fn quarantine(self: *Self, row: *sqlx.Row, err: anyerror) !void {
        // Reported at `warn`: this fires once per bad row (the row is retired
        // right here), it is counted in `outbox_failed_total`, and the
        // neighbouring `OutboxPublisher` reports its permanent failures at the
        // same level.
        const id = unparsedId(row) orelse {
            std.log.warn(
                "[outbox] unparseable entry ({s}) and no usable id column: it cannot be dead-lettered and will be re-selected until the row is fixed",
                .{@errorName(err)},
            );
            return;
        };
        std.log.warn("[outbox] unparseable entry id={d} ({s}); dead-lettering it (status = 3)", .{ id, @errorName(err) });
        _ = try self.backend.exec("UPDATE event_outbox SET status = 3, error_message = ?, updated_at = ? WHERE id = ?", &.{
            .{ .string = @errorName(err) },
            .{ .int = Time.monotonicNowSeconds() },
            .{ .int = id },
        });
    }

    /// `id` of a row that failed to parse. The name lookup is tried first; when
    /// that is itself what failed (a schema whose columns differ in case, say),
    /// fall back to the first column of the pending SELECT, which
    /// `buildSelectPending` puts `id` in.
    fn unparsedId(row: *sqlx.Row) ?i64 {
        const value = (row.get("id") orelse
            (if (row.values.len > 0) row.values[0] else null)) orelse return null;
        return switch (value) {
            .int => |v| v,
            else => null,
        };
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
            .status = @fromBackingInt(@intCast(@as(u8, @intCast(status_v.int)))),
            .retry_count = @intCast(retry_v.int),
            .max_retries = @intCast(max_v.int),
            .created_at = created_v.int,
            .updated_at = updated_v.int,
            .error_message = if (error_v) |ev| ev.string else null,
        };
    }
};

test "OutboxConsumer quarantines an unparseable row instead of stalling the queue" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    // `PAYLOAD` (not `payload`) still resolves in SQL, so the SELECT built by
    // the consumer works — but `Row.get` is a case-sensitive name lookup, so
    // `parseEntry` can never parse this row's topic/payload.
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, PAYLOAD TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec(
        "INSERT INTO event_outbox (topic, PAYLOAD, status, retry_count, max_retries, created_at, updated_at) VALUES ('ai.approval', '{\"run\":1}', 0, 0, 3, 100, 100)",
        &.{},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const State = struct {
        var handled: usize = 0;
    };
    const Handler = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: OutboxEntry) anyerror!void {
            State.handled += 1;
        }
    };
    State.handled = 0;
    var dummy: u8 = 0;
    var consumer = OutboxConsumer.init(allocator, &backend, .{}, &dummy, Handler.call);

    const first = try consumer.pollOnce();
    // The defect: an unparsed row was skipped without being marked, so the next
    // poll selected it again — forever — and nothing behind it ever drained.
    const second = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 0), second.selected);
    try std.testing.expectEqual(@as(usize, 0), State.handled);

    // And it is dead-lettered, not silently dropped: one order attempt in the
    // queue is permanently failed, in the counter operators alert on.
    try std.testing.expectEqual(@as(usize, 1), first.selected);
    try std.testing.expectEqual(@as(usize, 0), first.delivered);
    try std.testing.expectEqual(@as(usize, 1), first.failed);

    var cursor = try client.queryCursorEx("SELECT status, error_message FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = (try cursor.next()).?;
    try std.testing.expectEqual(@as(i64, 3), row.get("status").?.int); // DLQ
    try std.testing.expectEqualStrings("MissingColumn", row.get("error_message").?.string);
    try std.testing.expectEqual(@as(u64, 0), try consumer.pendingCount());

    // Quarantining is not the end of the line: the existing resubmit policy
    // brings the row back once the schema is fixed.
    _ = try client.exec("ALTER TABLE event_outbox RENAME COLUMN PAYLOAD TO payload", &.{});
    var publisher = Outbox.OutboxPublisher.init(allocator, .{});
    const resubmit = try publisher.buildResubmit(.{}, 0);
    defer allocator.free(resubmit);
    _ = try client.exec(resubmit, &.{});

    const third = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 1), third.delivered);
    try std.testing.expectEqual(@as(usize, 1), State.handled);
}

test "OutboxConsumer quarantines a row whose id column name differs too" {
    // The name lookup for `id` can be the failing one (this is what a schema
    // with differently-cased columns looks like to `Row.get`), so the
    // quarantine must still be able to address the row.
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (ID INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, PAYLOAD TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec(
        "INSERT INTO event_outbox (topic, PAYLOAD, status, retry_count, max_retries, created_at, updated_at) VALUES ('ai.recon', '{}', 0, 0, 3, 100, 100)",
        &.{},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const Handler = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: OutboxEntry) anyerror!void {}
    };
    var dummy: u8 = 0;
    var consumer = OutboxConsumer.init(allocator, &backend, .{}, &dummy, Handler.call);

    const stats = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 1), stats.failed);
    try std.testing.expectEqual(@as(u64, 0), try consumer.pendingCount());

    const after = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 0), after.selected);
}

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
    const r1 = (try cursor.next()).?;
    try std.testing.expectEqualStrings("ai.approval", r1.get("topic").?.string);
    try std.testing.expectEqual(@as(i64, 2), r1.get("status").?.int);
    const r2 = (try cursor.next()).?;
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
    const row = (try cursor.next()).?;
    try std.testing.expectEqual(@as(i64, 3), row.get("status").?.int);
    try std.testing.expectEqual(@as(i64, 2), row.get("retry_count").?.int);
    try std.testing.expectEqualStrings("DeliveryFailed", row.get("error_message").?.string);
}

test "outbox metrics expose backlog and delivery counters" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec(
        "INSERT INTO event_outbox (topic, payload, status, retry_count, max_retries, created_at, updated_at) VALUES ('t.a', '{}', 0, 0, 3, 1, 1), ('t.b', '{}', 0, 0, 3, 2, 2)",
        &.{},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const Handler = struct {
        fn handle(_: *anyopaque, _: std.mem.Allocator, _: OutboxEntry) anyerror!void {}
    };
    var consumer = OutboxConsumer.init(allocator, &backend, .{}, undefined, Handler.handle);

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();
    try consumer.setMetrics(&metrics);

    // Backlog is visible before anything is delivered — the whole point.
    try std.testing.expectEqual(@as(u64, 2), try consumer.pendingCount());
    consumer.refreshPending();

    const first = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 2), first.delivered);

    const after = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 0), after.selected);
    try std.testing.expectEqual(@as(u64, 0), try consumer.pendingCount());

    const text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "outbox_selected_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "outbox_delivered_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "outbox_failed_total 0") != null);
    // Gauge was refreshed when the backlog was still 2.
    try std.testing.expect(std.mem.indexOf(u8, text, "outbox_pending 2.000000") != null);
}

test "OutboxConsumer binds the topic filter instead of interpolating it" {
    // The filter used to be pasted into a single-quoted literal, so a quote in
    // the configured topic ended the string and changed the statement. It is a
    // bound parameter now: a topic that contains quotes must both select the
    // right row and keep the statement well-formed.
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    const quoted = "ai.o'brien";
    _ = try client.exec(
        "INSERT INTO event_outbox (topic, payload, status, retry_count, max_retries, created_at, updated_at) VALUES (?, '{}', 0, 0, 3, 100, 100), ('ai.other', '{}', 0, 0, 3, 101, 101)",
        &.{.{ .string = quoted }},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const State = struct {
        var handled: usize = 0;
    };
    const Handler = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: OutboxEntry) anyerror!void {
            State.handled += 1;
        }
    };
    State.handled = 0;
    var dummy: u8 = 0;
    var consumer = OutboxConsumer.init(
        allocator,
        &backend,
        .{ .batch_size = 10, .topic_filter = quoted },
        &dummy,
        Handler.call,
    );

    const stats = try consumer.pollOnce();
    try std.testing.expectEqual(@as(usize, 1), stats.selected);
    try std.testing.expectEqual(@as(usize, 1), stats.delivered);
    try std.testing.expectEqual(@as(usize, 1), State.handled);
}
