//! Anomaly diagnosis ("异常归因"): given a detected anomaly (from `alerts` /
//! `recon` / `sla` / app code), gather evidence via configured SQL queries and
//! hand the symptom + evidence to a diagnostic callback (wire to an LLM or a
//! rule engine). The result — likely causes + recommended actions — is written
//! to the outbox (`ai.diagnose`) for audit and downstream automation.

const std = @import("std");
const SqlxBackend = @import("../data.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const reporter = @import("reporter.zig");
const skill = @import("skill.zig");

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
        // The callback's summary is owned by us from here on, and every exit
        // below can fail (the two `toOwnedSlice`s, then the outbox write).
        errdefer if (summary.len > 0) allocator.free(summary);

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
        const payload = try buildOutboxPayload(allocator, case, summary, causes, actions);
        defer allocator.free(payload);

        const insert = try ob.buildInsert(self.outbox_topic, payload);
        _ = try self.backend.exec(insert.sql, &.{
            .{ .string = insert.params.topic },
            .{ .string = insert.params.payload },
            .{ .int = @intCast(insert.params.max_retries) },
            .{ .int = insert.params.created_at },
            .{ .int = insert.params.updated_at },
        });
    }
};

/// The `ai.diagnose` payload: source, subject, summary, causes, actions.
/// Rendered from a `std.json.Value`, so the anomaly text and the diagnoser's
/// causes/actions (LLM output) are escaped instead of interpolated: one quote
/// used to produce an unparseable event for every consumer.
fn buildOutboxPayload(
    allocator: std.mem.Allocator,
    case: AnomalyCase,
    summary: []const u8,
    causes: []const []const u8,
    actions: []const []const u8,
) ![]u8 {
    var obj = std.json.ObjectMap{};
    errdefer skill.freeValue(allocator, .{ .object = obj });
    try skill.putJsonField(allocator, &obj, "source", .{ .string = case.source });
    try skill.putJsonField(allocator, &obj, "subject", .{ .string = case.subject });
    try skill.putJsonField(allocator, &obj, "summary", .{ .string = summary });
    try skill.putJsonField(allocator, &obj, "causes", .{ .array = try stringArray(allocator, causes) });
    try skill.putJsonField(allocator, &obj, "actions", .{ .array = try stringArray(allocator, actions) });

    // The tree is released here and the only statement left cannot fail, so the
    // `errdefer` above cannot double-free. (`valueAlloc` takes `anytype`, so the
    // value must be typed `std.json.Value` — an inline literal would be
    // stringified as an anonymous struct instead.)
    const tree: std.json.Value = .{ .object = obj };
    const out = try std.json.Stringify.valueAlloc(allocator, tree, .{});
    skill.freeValue(allocator, tree);
    return out;
}

/// An owned `.array` of owned `.string`s, ready for `putJsonField`.
///
/// The guard belongs here rather than at the call site: `putJsonField` takes
/// ownership of a non-string value **even when it fails**, so a caller-side
/// `errdefer` would free the array a second time when the field is rejected.
/// Built here, the guard is disarmed by the `return` — and an element is
/// appended only after its copy exists, so no `append` failure can strand one
/// either.
fn stringArray(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    errdefer skill.freeValue(allocator, .{ .array = arr });
    for (items) |s| {
        const copy = try allocator.dupe(u8, s);
        errdefer allocator.free(copy);
        try arr.append(.{ .string = copy });
    }
    return arr;
}

// `checkAllAllocationFailures` fails one allocation at a time inside the call
// and compares allocated/freed bytes, so it covers the copy that the elements
// are made of, the growth of the arrays and the field copies in `obj`.
//
// Red before `stringArray` (the inline `try causes_v.append(…)` loop), on the
// fail index that lands on the first element's `append`: `fail_index: 8/15`,
// `FAIL (MemoryLeakDetected)`, `leaked [len: 24]` — the copy of
// "provider said \"declined\"" — allocated at that line.
test "buildOutboxPayload hands back its tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    const causes = [_][]const u8{"provider said \"declined\""};
    const actions = [_][]const u8{"retry after \"backoff\""};

    const Scan = struct {
        fn run(a: std.mem.Allocator, cs: []const []const u8, as: []const []const u8) !void {
            const payload = try buildOutboxPayload(
                a,
                .{ .source = "alert", .subject = "orders \"eu\"", .severity = .critical, .description = "failed orders" },
                "2 failed orders",
                cs,
                as,
            );
            defer a.free(payload);
            try std.testing.expect(std.mem.indexOf(u8, payload, "declined") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &causes, &actions });
}

test "DiagnosisFlow gathers evidence, diagnoses and writes outbox" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
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
    const row = (try cursor.next()).?;
    try std.testing.expectEqualStrings("ai.diagnose", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "payment provider rejected") != null);
}

test "DiagnosisFlow writeOutbox fills every NOT NULL column of the shipped DDL" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    // The shipped DDL — `created_at` / `updated_at` are NOT NULL. Reproduces the
    // ai-ops failure (2026-09-17): the INSERT carried a sixth placeholder that
    // the call site below never bound, so `updated_at` arrived NULL and the
    // whole pipeline aborted with a constraint violation.
    _ = try client.exec(OutboxPublisher.migrationSqlWithDialect(.sqlite), &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    const Diagnoser = struct {
        fn run(
            a: std.mem.Allocator,
            _: *SkillContext,
            _: AnomalyCase,
            _: []const EvidenceBlock,
            out_causes: *std.ArrayList([]const u8),
            out_actions: *std.ArrayList([]const u8),
            out_summary: *[]const u8,
        ) anyerror!void {
            try out_causes.append(a, try a.dupe(u8, "gateway timeout"));
            try out_actions.append(a, try a.dupe(u8, "retry after backoff"));
            out_summary.* = try a.dupe(u8, "two failed orders");
        }
    };

    var flow = DiagnosisFlow.init(allocator, &backend, Diagnoser.run);
    flow.outbox = &outbox;

    var ctx = SkillContext{ .allocator = allocator };
    var res = try flow.run(allocator, &ctx, .{
        .source = "alert",
        .subject = "orders",
        .severity = .warning,
        .description = "failed orders",
    });
    defer res.deinit(allocator);

    var cursor = try client.queryCursorEx(
        "SELECT topic, payload, tenant_id, status, max_retries, created_at, updated_at FROM event_outbox",
        &.{},
        .{},
    );
    defer cursor.deinit();
    const row = (try cursor.next()).?;
    try std.testing.expectEqualStrings("ai.diagnose", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "gateway timeout") != null);
    // The driver reports SQL NULL as a missing `?Value`, so the tenant column is
    // `== null` (the SELECT above is what makes that unambiguous).
    try std.testing.expectEqual(@as(usize, 7), row.columns.len);
    try std.testing.expect(row.get("tenant_id") == null);
    try std.testing.expectEqual(@as(i64, 0), row.get("status").?.int);
    try std.testing.expectEqual(@as(i64, 3), row.get("max_retries").?.int);
    const created_at = row.get("created_at").?.int;
    try std.testing.expect(created_at > 0);
    try std.testing.expectEqual(created_at, row.get("updated_at").?.int);
}

test "DiagnosisFlow outbox payload escapes quotes in the diagnosed text" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    // Every one of these is what a diagnoser wired to an LLM hands back.
    const summary = "spike of \"failed\" orders \\ retried";
    const cause = "provider said \"declined\"";
    const action = "retry after \"backoff\"";
    const Diagnoser = struct {
        fn run(
            a: std.mem.Allocator,
            _: *SkillContext,
            _: AnomalyCase,
            _: []const EvidenceBlock,
            out_causes: *std.ArrayList([]const u8),
            out_actions: *std.ArrayList([]const u8),
            out_summary: *[]const u8,
        ) anyerror!void {
            try out_causes.append(a, try a.dupe(u8, "provider said \"declined\""));
            try out_actions.append(a, try a.dupe(u8, "retry after \"backoff\""));
            out_summary.* = try a.dupe(u8, "spike of \"failed\" orders \\ retried");
        }
    };

    var flow = DiagnosisFlow.init(allocator, &backend, Diagnoser.run);
    flow.outbox = &outbox;
    var ctx = SkillContext{ .allocator = allocator };
    var res = try flow.run(allocator, &ctx, .{
        .source = "alert",
        .subject = "orders \"eu\"",
        .severity = .critical,
        .description = "failed orders",
    });
    defer res.deinit(allocator);

    var cursor = try client.queryCursorEx("SELECT payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = (try cursor.next()) orelse return error.NoOutboxRow;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, row.get("payload").?.string, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("alert", obj.get("source").?.string);
    try std.testing.expectEqualStrings("orders \"eu\"", obj.get("subject").?.string);
    try std.testing.expectEqualStrings(summary, obj.get("summary").?.string);
    try std.testing.expectEqual(@as(usize, 1), obj.get("causes").?.array.items.len);
    try std.testing.expectEqualStrings(cause, obj.get("causes").?.array.items[0].string);
    try std.testing.expectEqualStrings(action, obj.get("actions").?.array.items[0].string);
}
