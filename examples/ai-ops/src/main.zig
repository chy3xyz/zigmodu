//! ai-ops: end-to-end AI operations pipeline demo.
//!
//! Chains the built-in business tools into one runnable flow:
//!
//!   detect  → diagnose → approve → notify → audit
//!   (alerts)  (DiagnosisFlow)  (ApprovalFlow)  (NotificationHub)  (OutboxConsumer)
//!
//! Scenario: two failed orders are detected by a SQL alert rule. The
//! diagnosis flow gathers evidence and names a likely cause. Both refunds go
//! through an approval chain — the small one is auto-approved, the large one
//! is escalated to a human. A notification summary is delivered to a sink and
//! the outbox. Finally the outbox consumer polls the written events to close
//! the loop.
//!
//! Run:  zig build run        (prints the pipeline trace)
//! Test: zig build test       (asserts every stage)

const std = @import("std");
const zigmodu = @import("zigmodu");

const ai = zigmodu.ai;
const sqlx = zigmodu.data.sqlx;

/// Notification sink: appends the delivered JSON body to a caller-provided
/// buffer (via `userdata`).
fn sinkAppend(userdata: *anyopaque, a: std.mem.Allocator, _: *ai.SkillContext, _: []const u8, body: []const u8) anyerror!void {
    const out: *std.ArrayList(u8) = @ptrCast(@alignCast(userdata));
    try out.appendSlice(a, body);
    try out.append(a, '\n');
}

const outbox_table_sql =
    \\CREATE TABLE event_outbox (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  topic TEXT NOT NULL,
    \\  payload TEXT NOT NULL,
    \\  status INTEGER NOT NULL DEFAULT 0,
    \\  retry_count INTEGER NOT NULL DEFAULT 0,
    \\  max_retries INTEGER NOT NULL DEFAULT 5,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL,
    \\  error_message TEXT
    \\);
;

pub fn main(init: std.process.Init) !void {
    const res = try runPipeline(init.gpa, init.io, true);
    init.gpa.free(res.diagnosis_cause);
}

const PipelineResult = struct {
    alerts: usize,
    /// Owned by the caller (free after use).
    diagnosis_cause: []const u8,
    large_status: ai.approval.ApprovalStatus,
    small_status: ai.approval.ApprovalStatus,
    notify_delivered: usize,
    outbox_consumed: usize,
};

fn runPipeline(allocator: std.mem.Allocator, io: std.Io, verbose: bool) !PipelineResult {
    var client = sqlx.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(outbox_table_sql, &.{});
    _ = try client.exec(
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, amount INTEGER, status TEXT)",
        &.{},
    );
    _ = try client.exec(
        "INSERT INTO orders (amount, status) VALUES (100, 'failed'), (50000, 'failed'), (50, 'paid')",
        &.{},
    );

    var backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = zigmodu.outbox.OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    var ctx = ai.SkillContext{ .allocator = allocator };

    // ── 1. Detect ─────────────────────────────────────────────────────────
    const alert_rules = [_]ai.alerts.AlertRule{
        .{
            .name = "failed orders",
            .sql = "SELECT id FROM orders WHERE status = 'failed'",
            .message_template = "orders stuck in failed state",
        },
    };
    var alert = ai.alerts.BusinessAlert.init(allocator, &backend, &alert_rules);
    const alerts = try alert.check(allocator, &ctx);

    // ── 2. Diagnose ───────────────────────────────────────────────────────
    const Diagnoser = struct {
        fn run(
            a: std.mem.Allocator,
            _: *ai.SkillContext,
            _: ai.diagnose.AnomalyCase,
            evidence: []const ai.diagnose.EvidenceBlock,
            out_causes: *std.ArrayList([]const u8),
            out_actions: *std.ArrayList([]const u8),
            out_summary: *[]const u8,
        ) anyerror!void {
            _ = evidence;
            try out_causes.append(a, try a.dupe(u8, "payment gateway rejected both charges"));
            try out_actions.append(a, try a.dupe(u8, "verify gateway credentials and retry the refund"));
            out_summary.* = try a.dupe(u8, "2 failed orders detected by alert rule");
        }
    };
    const evidence_queries = [_]ai.reporter.ReportQuery{
        .{ .name = "failed orders", .sql = "SELECT id, amount, status FROM orders WHERE status = 'failed' ORDER BY amount DESC" },
    };
    var diagnosis = ai.diagnose.DiagnosisFlow.init(allocator, &backend, Diagnoser.run);
    diagnosis.evidence_queries = &evidence_queries;
    diagnosis.outbox = &outbox;
    var diag = try diagnosis.run(allocator, &ctx, .{
        .source = "alert",
        .subject = "orders",
        .severity = .critical,
        .description = "failed orders spike",
    });
    defer diag.deinit(allocator);

    // ── 3. Approve ────────────────────────────────────────────────────────
    const Policy = struct {
        fn decide(
            a: std.mem.Allocator,
            _: *ai.SkillContext,
            _: []const u8,
            amount: i64,
            _: usize,
            _: []const u8,
            _: []const u8,
            out_note: *[]const u8,
        ) anyerror!ai.approval.ApprovalDecision {
            if (amount <= 1000) return .approved;
            out_note.* = try a.dupe(u8, "amount above auto-approval limit");
            return .escalated;
        }
    };
    const steps = [_]ai.approval.ApprovalStep{
        .{ .name = "ops manager" },
        .{ .name = "finance" },
    };
    var approval = ai.approval.ApprovalFlow.init(allocator, &backend, Policy.decide);
    approval.outbox = &outbox;
    var large = try approval.submit(allocator, &ctx, "order-2", 50000, &steps);
    defer large.deinit(allocator);
    var small = try approval.submit(allocator, &ctx, "order-1", 100, &steps);
    defer small.deinit(allocator);

    // ── 4. Notify ─────────────────────────────────────────────────────────
    var notifications = std.ArrayList(u8).empty;
    defer notifications.deinit(allocator);
    const channels = [_]ai.notify.NotificationChannel{
        .{ .name = "ops-channel", .kind = .{ .sink = .{ .userdata = &notifications, .call = sinkAppend } } },
    };
    var hub = ai.notify.NotificationHub.init(allocator, &backend, undefined);
    hub.channels = &channels;
    hub.outbox = &outbox;

    const notify_payload = try std.fmt.allocPrint(
        allocator,
        "{{\"summary\":\"{s}\",\"alerts\":{d},\"large_order\":\"{s}\",\"small_order\":\"{s}\"}}",
        .{ diag.summary, alerts, @tagName(large.status), @tagName(small.status) },
    );
    defer allocator.free(notify_payload);
    const report = try hub.deliver(allocator, &ctx, notify_payload);

    // ── 5. Audit: consume the outbox events written by approve + notify ────
    const ConsumerState = struct {
        var consumed: usize = 0;
    };
    const Consumer = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, entry: zigmodu.outbox.OutboxEntry) anyerror!void {
            ConsumerState.consumed += 1;
            _ = entry;
        }
    };
    var dummy: u8 = 0;
    var consumer = zigmodu.outbox.OutboxConsumer.init(allocator, &backend, .{}, &dummy, Consumer.call);
    const poll = try consumer.pollOnce();

    if (verbose) {
        std.debug.print("=== ai-ops pipeline ===\n", .{});
        std.debug.print("1. detect   : {d} alert(s)\n", .{alerts});
        std.debug.print("2. diagnose : {s} → {s}\n", .{ diag.causes[0], diag.actions[0] });
        std.debug.print("3. approve  : large={s}, small={s}\n", .{ @tagName(large.status), @tagName(small.status) });
        std.debug.print("4. notify   : delivered {d}/{d}\n", .{ report.delivered, report.channels });
        std.debug.print("5. audit    : consumed {d} outbox event(s) ({d} delivered, {d} failed)\n", .{ poll.selected, poll.delivered, poll.failed });
        std.debug.print("notification sink received:\n{s}", .{notifications.items});
        std.debug.print("\n--- demo complete: detect → diagnose → approve → notify → audit ---\n", .{});
    }

    const out = PipelineResult{
        .alerts = alerts,
        .diagnosis_cause = try allocator.dupe(u8, diag.causes[0]),
        .large_status = large.status,
        .small_status = small.status,
        .notify_delivered = report.delivered,
        .outbox_consumed = poll.delivered,
    };
    // The duplicated cause must outlive this frame's deferred frees.
    return out;
}

test "ai-ops end-to-end pipeline" {
    const allocator = std.testing.allocator;
    const res = try runPipeline(allocator, std.testing.io, false);
    defer allocator.free(res.diagnosis_cause);
    try std.testing.expectEqual(@as(usize, 1), res.alerts);
    try std.testing.expectEqualStrings("payment gateway rejected both charges", res.diagnosis_cause);
    try std.testing.expectEqual(ai.approval.ApprovalStatus.pending_human, res.large_status);
    try std.testing.expectEqual(ai.approval.ApprovalStatus.approved, res.small_status);
    try std.testing.expectEqual(@as(usize, 1), res.notify_delivered);
    try std.testing.expect(res.outbox_consumed >= 3); // approval step/final events + notify fallback
}
