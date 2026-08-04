//! Anomaly diagnosis ("异常归因"): given a detected anomaly (from `alerts` /
//! `recon` / `sla` / app code), gather evidence via configured SQL queries and
//! hand the symptom + evidence to a diagnostic callback (wire to an LLM or a
//! rule engine). The result — likely causes + recommended actions — is written
//! to the outbox (`ai.diagnose`) for audit and downstream automation.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const reporter = @import("reporter.zig");

pub const AnomalyCase = struct {
    /// Source: "alert" | "recon" | "sla" | "app".
    source: []const u8,
    subject: []const u8,
    severity: enum { info, warning, critical },
    description: []const u8,
};

/// Evidence gathered for the case (one per configured query).
pub const EvidenceBlock = struct {
    name: []const u8,
    markdown: []const u8,
};

/// Diagnostic callback: produces likely causes + recommended actions. Returned
/// strings must be allocated in `allocator` (the flow takes ownership and
/// frees them via `DiagnosisResult.deinit`).
pub const DiagnoseFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    case: AnomalyCase,
    evidence: []const EvidenceBlock,
    out_causes: *std.ArrayList([]const u8),
    out_actions: *std.ArrayList([]const u8),
    out_summary: *[]const u8,
) anyerror!void;

pub const DiagnosisResult = struct {
    case: AnomalyCase,
    summary: []const u8,
    causes: []const []const u8,
    actions: []const []const u8,

    pub fn deinit(self: *DiagnosisResult, allocator: std.mem.Allocator) void {
        allocator.free(self.summary);
        for (self.causes) |c| allocator.free(c);
        allocator.free(self.causes);
        for (self.actions) |a| allocator.free(a);
        allocator.free(self.actions);
        self.* = undefined;
    }
};

pub const DiagnosisFlow = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    diagnose: DiagnoseFn,
    evidence_queries: []const reporter.ReportQuery = &.{},
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.diagnose",

    pub fn init(
        allocator: std.mem.Allocator,
        backend: *SqlxBackend,
        diagnose: DiagnoseFn,
    ) DiagnosisFlow {
        return .{ .allocator = allocator, .backend = backend, .diagnose = diagnose };
    }

    /// Run the diagnosis: evidence → callback → outbox. Caller owns the
    /// returned result (`deinit`).
    pub fn run(
        self: *DiagnosisFlow,
        allocator: std.mem.Allocator,
        ctx: *SkillContext,
        case: AnomalyCase,
    ) !DiagnosisResult {
        var blocks = std.ArrayList(EvidenceBlock).empty;
        defer {
            for (blocks.items) |b| allocator.free(b.markdown);
            blocks.deinit(allocator);
        }

        for (self.evidence_queries) |q| {
            var rep = reporter.BusinessReporter.init(allocator, self.backend, q.name, &.{q});
            const md = try rep.generate(allocator);
            errdefer allocator.free(md);
            try blocks.append(allocator, .{ .name = q.name, .markdown = md });
        }

        var causes = std.ArrayList([]const u8).empty;
        defer causes.deinit(allocator);
        var actions = std.ArrayList([]const u8).empty;
        defer {
            for (actions.items) |a| allocator.free(a);
            actions.deinit(allocator);
        }
        errdefer {
            for (causes.items) |c| allocator.free(c);
        }
        var summary: []const u8 = "";
        try self.diagnose(allocator, ctx, case, blocks.items, &causes, &actions, &summary);

        const causes_slice = try causes.toOwnedSlice(allocator);
        errdefer {
            for (causes_slice) |c| allocator.free(c);
            allocator.free(causes_slice);
        }
        const actions_slice = try actions.toOwnedSlice(allocator);
        errdefer {
            for (actions_slice) |a| allocator.free(a);
            allocator.free(actions_slice);
        }

        if (self.outbox != null) try self.writeOutbox(allocator, case, summary, causes_slice, actions_slice);

        return .{
            .case = case,
            .summary = summary,
            .causes = causes_slice,
            .actions = actions_slice,
        };
    }

    fn writeOutbox(
        self: *DiagnosisFlow,
        allocator: std.mem.Allocator,
        case: AnomalyCase,
        summary: []const u8,
        causes: []const []const u8,
        actions: []const []const u8,
    ) !void {
        const ob = self.outbox.?;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{\"source\":\"");
        try buf.appendSlice(allocator, case.source);
        try buf.appendSlice(allocator, "\",\"subject\":\"");
        try buf.appendSlice(allocator, case.subject);
        try buf.appendSlice(allocator, "\",\"summary\":\"");
        try buf.appendSlice(allocator, summary);
        try buf.appendSlice(allocator, "\",\"causes\":[");
        for (causes, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, c);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "],\"actions\":[");
        for (actions, 0..) |a, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            try buf.appendSlice(allocator, a);
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]}");

        const insert = try ob.buildInsert(self.outbox_topic, buf.items);
        _ = try self.backend.exec(insert.sql, &.{
            .{ .string = insert.params.topic },
            .{ .string = insert.params.payload },
            .{ .int = @intCast(insert.params.max_retries) },
            .{ .int = insert.params.created_at },
            .{ .int = insert.params.updated_at },
        });
    }
};

test "DiagnosisFlow gathers evidence, diagnoses and writes outbox" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)", &.{});
    _ = try client.exec("INSERT INTO orders (status) VALUES ('failed'), ('failed')", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    const Diagnoser = struct {
        fn run(
            a: std.mem.Allocator,
            _: *SkillContext,
            _: AnomalyCase,
            evidence: []const EvidenceBlock,
            out_causes: *std.ArrayList([]const u8),
            out_actions: *std.ArrayList([]const u8),
            out_summary: *[]const u8,
        ) anyerror!void {
            try out_causes.append(a, try a.dupe(u8, "payment provider rejected"));
            try out_actions.append(a, try a.dupe(u8, "check provider credentials and retry"));
            out_summary.* = try a.dupe(u8, "2 failed orders in the last hour");
            try std.testing.expect(evidence.len > 0);
            try std.testing.expect(std.mem.indexOf(u8, evidence[0].markdown, "failed") != null);
        }
    };

    const queries = [_]reporter.ReportQuery{
        .{ .name = "recent failures", .sql = "SELECT status, COUNT(*) AS n FROM orders WHERE status = 'failed' GROUP BY status" },
    };
    var flow = DiagnosisFlow.init(allocator, &backend, Diagnoser.run);
    flow.evidence_queries = &queries;
    flow.outbox = &outbox;

    var ctx = SkillContext{ .allocator = allocator };
    var res = try flow.run(allocator, &ctx, .{
        .source = "alert",
        .subject = "orders",
        .severity = .critical,
        .description = "failed orders spike",
    });
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.causes.len);
    try std.testing.expectEqualStrings("payment provider rejected", res.causes[0]);
    try std.testing.expectEqualStrings("check provider credentials and retry", res.actions[0]);
    try std.testing.expect(std.mem.indexOf(u8, res.summary, "failed") != null);

    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next().?;
    try std.testing.expectEqualStrings("ai.diagnose", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "payment provider rejected") != null);
}
