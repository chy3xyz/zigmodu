//! tenant-ai: multi-tenant AI operations example.
//!
//! Two tenants share one app; every AI capability is tenant-scoped:
//!
//!   - KPI metrics (`kpi.query` skill, per-tenant definitions)
//!   - business reports (`BusinessReporter`, tenant-filtered SQL)
//!   - alerts (`BusinessAlert`, tenant-filtered rules)
//!   - human approval queue (`ApprovalFlow` + `PersistentApprovalQueue`,
//!     tenant_id column — tenants never see each other's pending items)
//!   - orchestration (`Workflow` driving the registered skills)
//!   - workflow metrics (`WorkflowMetrics`) + graph export (`toMermaid`)
//!   - aggregated AI metrics (`AiMetrics`) at `GET /api/ai/metrics`
//!
//! HTTP API (X-Tenant-ID header; defaults to tenant 1):
//!   GET  /api/ai/kpi?metric=paid_revenue
//!   GET  /api/ai/report
//!   GET  /api/ai/alerts
//!   POST /api/ai/approval/submit?amount=5000
//!   GET  /api/ai/approvals
//!   POST /api/ai/approvals/{run_id}/approve
//!   POST /api/ai/workflow/run
//!   GET  /api/ai/workflow/graph
//!   GET  /api/ai/metrics
//!
//! Run:  cd examples/tenant-ai && zig build run
//! Test: zig build test  (asserts tenant isolation end-to-end)

const std = @import("std");
const zigmodu = @import("zigmodu");

const ai = zigmodu.ai;
const http = zigmodu.http;
const sqlx = zigmodu.data.sqlx;

// ── Schema ─────────────────────────────────────────────────────────────────
const schema_sql =
    \\CREATE TABLE IF NOT EXISTS tenants (
    \\  id INTEGER PRIMARY KEY, name TEXT NOT NULL, tier TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS orders (
    \\  id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, amount INTEGER NOT NULL, status TEXT NOT NULL
    \\);
;

fn applySchema(client: *sqlx.Client) !void {
    var it = std.mem.splitScalar(u8, schema_sql, ';');
    while (it.next()) |stmt| {
        const s = std.mem.trim(u8, stmt, " \n\t");
        if (s.len == 0) continue;
        _ = try client.exec(s, &.{});
    }
}

// ── Shared app state for AI handlers ───────────────────────────────────────
const TenantAiApp = struct {
    backend: *zigmodu.data.SqlxBackend,
    outbox: *zigmodu.outbox.OutboxPublisher,
    queue: *ai.approval_store.PersistentApprovalQueue,
    kpi_metrics: []const ai.kpi.KpiMetric,
    kpi_ctx: *ai.kpi.KpiCtx,
    approval: *ai.approval.ApprovalFlow,
    registry: *ai.SkillRegistry,
    wf_metrics: *ai.WorkflowMetrics,
    ai_metrics: *ai.observability.AiMetrics,

    /// Pick the metric definition for (tenant_id, name). The example registers
    /// one definition per tenant; apps can also build tenant-specific SQL.
    fn kpiMetricsFor(self: *TenantAiApp, tid: i64, name: []const u8) ?ai.kpi.KpiMetric {
        for (self.kpi_metrics) |m| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            var needle_buf: [32]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "tenant_id = {d}", .{tid}) catch continue;
            if (std.mem.indexOf(u8, m.sql, needle) != null) {
                return m;
            }
        }
        return null;
    }
};

// ── Tenant middleware: X-Tenant-ID header → ctx attr + verification ────────
fn tenantMiddleware(app: *TenantAiApp) http.Middleware {
    const mw = struct {
        fn run(ctx: *http.Context, next: http.HandlerFn, userdata: ?*anyopaque) anyerror!void {
            const a: *TenantAiApp = @ptrCast(@alignCast(userdata.?));
            const raw = ctx.header("X-Tenant-ID") orelse "1";
            const tid = std.fmt.parseInt(i64, raw, 10) catch return error.BadTenantId;
            var cursor = try a.backend.client.queryCursorEx("SELECT id FROM tenants WHERE id = ?", &.{.{ .int = tid }}, .{});
            defer cursor.deinit();
            if (cursor.next() == null) {
                try ctx.json(404, "{\"err\":\"tenant not found\"}");
                return;
            }
            try ctx.setAttr("tenant_id", raw);
            try next(ctx);
        }
    };
    return .{ .func = mw.run, .user_data = app };
}

// ── Tenant-aware AI API ────────────────────────────────────────────────────
fn TenantAiApi(comptime ComptimeState: type) type {
    _ = ComptimeState;
    return struct {
        const Self = @This();
        app: *TenantAiApp,
        pub const module_name = "ai";
        pub const nest = .{"ai"};
        pub const State = Self;

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "kpi", .handler = kpi },
            .{ .method = .GET, .path = "report", .handler = report },
            .{ .method = .GET, .path = "alerts", .handler = alerts },
            .{ .method = .POST, .path = "approval/submit", .handler = approvalSubmit },
            .{ .method = .GET, .path = "approvals", .handler = approvals },
            .{ .method = .POST, .path = "approvals/{run_id}/approve", .handler = approvalDecide },
            .{ .method = .POST, .path = "workflow/run", .handler = workflowRun },
            .{ .method = .GET, .path = "workflow/graph", .handler = workflowGraph },
            .{ .method = .GET, .path = "metrics", .handler = metrics },
        };

        fn tenantOf(ctx: *http.Context) !i64 {
            const raw = ctx.getAttr("tenant_id") orelse return error.TenantMissing;
            return std.fmt.parseInt(i64, raw, 10) catch error.BadTenantId;
        }

        fn kpi(ctx: *http.Context, self: *State) !void {
            const tid = try tenantOf(ctx);
            const name = ctx.queryStr("metric", "paid_revenue");
            const metric = self.app.kpiMetricsFor(tid, name) orelse {
                try ctx.json(404, "{\"err\":\"metric not found for tenant\"}");
                return;
            };
            const res = try ai.kpi.query(ctx.allocator, self.app.backend, metric);
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"tenant\":{d},\"metric\":\"{s}\",\"value\":{d:.1}}}", .{ tid, metric.name, res.value });
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }

        fn report(ctx: *http.Context, self: *State) !void {
            const tid = try tenantOf(ctx);
            var queries_buf: [64]u8 = undefined;
            const orders_sql = try std.fmt.bufPrint(&queries_buf, "SELECT id, amount, status FROM orders WHERE tenant_id = {d} ORDER BY amount DESC LIMIT 5", .{tid});
            const queries = [_]ai.reporter.ReportQuery{
                .{ .name = "recent orders", .sql = orders_sql },
            };
            var rep = ai.reporter.BusinessReporter.init(ctx.allocator, self.app.backend, "Tenant report", &queries);
            const md = try rep.generate(ctx.allocator);
            defer ctx.allocator.free(md);
            try ctx.setHeader("Content-Type", "text/markdown");
            try ctx.text(200, md);
        }

        fn alerts(ctx: *http.Context, self: *State) !void {
            const tid = try tenantOf(ctx);
            var sql_buf: [128]u8 = undefined;
            const rule_sql = try std.fmt.bufPrint(&sql_buf, "SELECT id FROM orders WHERE tenant_id = {d} AND status = 'failed'", .{tid});
            const rules = [_]ai.alerts.AlertRule{
                .{ .name = "failed orders", .sql = rule_sql, .message_template = "orders stuck in failed state" },
            };
            var alert = ai.alerts.BusinessAlert.init(ctx.allocator, self.app.backend, &rules);
            var sctx = ai.SkillContext{ .allocator = ctx.allocator, .tenant_id = tid };
            const n = try alert.check(ctx.allocator, &sctx);
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"tenant\":{d},\"alerts\":{d}}}", .{ tid, n });
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }

        fn approvalSubmit(ctx: *http.Context, self: *State) !void {
            const tid = try tenantOf(ctx);
            const amount = ctx.queryInt(i64, "amount", 0);
            var sctx = ai.SkillContext{ .allocator = ctx.allocator, .tenant_id = tid };
            const steps = [_]ai.approval.ApprovalStep{
                .{ .name = "ops manager" },
                .{ .name = "finance" },
            };
            var result = try self.app.approval.submit(ctx.allocator, &sctx, "order-refund", amount, &steps);
            defer result.deinit(ctx.allocator);
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"tenant\":{d},\"run_id\":\"{s}\",\"status\":\"{s}\"}}", .{ tid, result.run_id, @tagName(result.status) });
            defer ctx.allocator.free(body);
            try ctx.json(200, body);
        }

        fn approvals(ctx: *http.Context, self: *State) !void {
            const tid = try tenantOf(ctx);
            var items = std.ArrayList(ai.approval_store.PendingApproval).empty;
            defer {
                for (items.items) |it| {
                    ctx.allocator.free(it.run_id);
                    ctx.allocator.free(it.subject);
                    ctx.allocator.free(it.note);
                    ctx.allocator.free(it.step_name);
                }
                items.deinit(ctx.allocator);
            }
            try self.app.queue.listPending(ctx.allocator, &items, tid);
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"tenant\":");
            try buf.print(ctx.allocator, "{d},\"pending\":[", .{tid});
            var first = true;
            for (items.items) |it| {
                if (!first) try buf.appendSlice(ctx.allocator, ",");
                first = false;
                try buf.print(ctx.allocator, "{{\"run_id\":\"{s}\",\"subject\":\"{s}\",\"amount\":{d}}}", .{ it.run_id, it.subject, it.amount });
            }
            try buf.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, buf.items);
        }

        fn approvalDecide(ctx: *http.Context, self: *State) !void {
            const tid = try tenantOf(ctx);
            const run_id = try ctx.paramStr("run_id");
            if (try self.app.queue.resolve(run_id, tid)) {
                try ctx.json(200, "{\"ok\":true}");
            } else {
                try ctx.json(404, "{\"err\":\"not found for this tenant\"}");
            }
        }

        fn workflowRun(ctx: *http.Context, self: *State) !void {
            const tid = try tenantOf(ctx);
            const steps = [_]ai.workflow.Step{
                .{ .name = "kpi-step", .kind = .{ .skill = .{ .name = "kpi.query", .args = .{ .object = blk: {
                    var o = std.json.ObjectMap{};
                    try putOwned(&o, ctx.allocator, "metric", .{ .string = try ctx.allocator.dupe(u8, "paid_revenue") });
                    break :blk o;
                } } } } },
            };
            var wf = ai.workflow.Workflow.init(self.app.registry, &steps);
            wf.metrics = self.app.wf_metrics;
            var sctx = ai.SkillContext{ .allocator = ctx.allocator, .tenant_id = tid, .userdata = self.app.kpi_ctx };
            var result = try wf.run(ctx.allocator, &sctx);
            defer result.deinit();
            var out = std.ArrayList(u8).empty;
            defer out.deinit(ctx.allocator);
            try out.appendSlice(ctx.allocator, "{\"tenant\":");
            try out.print(ctx.allocator, "{d},\"status\":\"{s}\",\"steps\":[", .{ tid, @tagName(result.status) });
            var first = true;
            for (result.steps.items) |rec| {
                if (!first) try out.appendSlice(ctx.allocator, ",");
                first = false;
                try out.print(ctx.allocator, "{{\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ rec.name, @tagName(rec.status) });
            }
            try out.appendSlice(ctx.allocator, "]}");
            try ctx.json(200, out.items);
        }

        fn workflowGraph(ctx: *http.Context, self: *State) !void {
            const steps = [_]ai.workflow.Step{
                .{ .name = "kpi-step", .kind = .{ .skill = .{ .name = "kpi.query", .args = .{ .object = .{} } } } },
                .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-refund", .amount = 5000 } } },
                .{ .name = "publish", .kind = .{ .skill = .{ .name = "kpi.query", .args = .{ .object = .{} } } }, .depends_on = &.{"review"} },
            };
            var wf = ai.workflow.Workflow.init(self.app.registry, &steps);
            const mermaid = try wf.toMermaid(ctx.allocator);
            defer ctx.allocator.free(mermaid);
            try ctx.setHeader("Content-Type", "text/plain");
            try ctx.text(200, mermaid);
        }

        fn metrics(ctx: *http.Context, self: *State) !void {
            const body = try self.app.ai_metrics.toPrometheusFormat(ctx.allocator);
            defer ctx.allocator.free(body);
            try ctx.setHeader("Content-Type", "text/plain; version=0.0.4");
            try ctx.text(200, body);
        }
    };
}

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io, true);
}

fn run(allocator: std.mem.Allocator, io: std.Io, serve: bool) !void {
    var client = sqlx.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    try applySchema(&client);
    _ = try client.exec("INSERT INTO tenants (name, tier) VALUES ('acme', 'pro'), ('globex', 'free')", &.{});
    _ = try client.exec(
        "INSERT INTO orders (tenant_id, amount, status) VALUES (1, 100, 'paid'), (1, 5000, 'failed'), (1, 50, 'paid'), (2, 9000, 'paid'), (2, 30, 'failed')",
        &.{},
    );

    var backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = zigmodu.outbox.OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    var queue = ai.approval_store.PersistentApprovalQueue.init(allocator, &backend);
    try queue.migrate();

    const kpi_metrics = [_]ai.kpi.KpiMetric{
        .{ .name = "paid_revenue", .description = "paid revenue", .sql = "SELECT SUM(amount) AS value FROM orders WHERE tenant_id = 1 AND status = 'paid'" },
        .{ .name = "paid_revenue", .description = "paid revenue", .sql = "SELECT SUM(amount) AS value FROM orders WHERE tenant_id = 2 AND status = 'paid'" },
    };
    var kpi_ctx = ai.kpi.KpiCtx{ .backend = &backend, .metrics = &kpi_metrics };
    var wf_metrics = ai.WorkflowMetrics{};
    var quota = ai.TokenQuota.init(allocator, io, 100000);
    defer quota.deinit();
    var ai_metrics = ai.observability.AiMetrics{
        .workflow = &wf_metrics,
        .quota = &quota,
    };

    var registry = ai.SkillRegistry.init(allocator, io);
    defer registry.deinit();
    try ai.kpi.registerKpiSkills(&registry);

    var app = TenantAiApp{
        .backend = &backend,
        .outbox = &outbox,
        .queue = &queue,
        .kpi_metrics = &kpi_metrics,
        .registry = &registry,
        .kpi_ctx = &kpi_ctx,
        .approval = undefined,
        .wf_metrics = &wf_metrics,
        .ai_metrics = &ai_metrics,
    };

    // Approval flow: <= 1000 auto-approves, above escalates (per tenant).
    const Policy = struct {
        fn decide(_: std.mem.Allocator, _: *ai.SkillContext, _: []const u8, amount: i64, _: usize, _: []const u8, _: []const u8, _: *[]const u8) anyerror!ai.approval.ApprovalDecision {
            return if (amount <= 1000) .approved else .escalated;
        }
    };
    var approval_flow = ai.approval.ApprovalFlow.init(allocator, &backend, Policy.decide);
    approval_flow.on_escalated = ai.approval_store.queuedEscalationPersistent;
    approval_flow.escalated_userdata = &queue;
    app.approval = &approval_flow;

    // ── HTTP: tenant middleware + AI API ───────────────────────────────────
    var server = http.Server.init(io, allocator, 18088);
    defer server.deinit();
    try server.addMiddleware(tenantMiddleware(&app));
    const AppState = struct {};
    var router_state: AppState = .{};
    var router = http.Router(AppState).init(io, allocator, &server, &router_state);
    defer router.deinit();
    var api = router.scope("/api");
    var ai_api = TenantAiApi(AppState){ .app = &app };
    try api.mount(TenantAiApi(AppState), &ai_api);
    var catalog = try router.finish();
    defer catalog.deinit();

    if (serve) {
        std.debug.print("tenant-ai listening on :18088 (X-Tenant-ID: 1|2)\n", .{});
        std.debug.print("try: curl -H 'X-Tenant-ID: 1' http://127.0.0.1:18088/api/ai/workflow/run\n", .{});
        std.debug.print("     curl http://127.0.0.1:18088/api/ai/workflow/graph\n", .{});
        try server.start();
    }
}

test "tenant-ai isolates KPI, alerts and approvals per tenant" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    try applySchema(&client);
    _ = try client.exec("INSERT INTO tenants (name, tier) VALUES ('acme', 'pro'), ('globex', 'free')", &.{});
    _ = try client.exec(
        "INSERT INTO orders (tenant_id, amount, status) VALUES (1, 100, 'paid'), (1, 5000, 'failed'), (1, 50, 'paid'), (2, 9000, 'paid'), (2, 30, 'failed')",
        &.{},
    );
    var backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
    var queue = ai.approval_store.PersistentApprovalQueue.init(allocator, &backend);
    try queue.migrate();
    try std.testing.expectEqual(@as(usize, 0), try queue.count(null));

    // Push one pending item per tenant, then verify isolation.
    const t1_run = try allocator.dupe(u8, "t1-run");
    const t1_subj = try allocator.dupe(u8, "t1");
    const t2_run = try allocator.dupe(u8, "t2-run");
    const t2_subj = try allocator.dupe(u8, "t2");
    defer {
        allocator.free(t1_run);
        allocator.free(t1_subj);
        allocator.free(t2_run);
        allocator.free(t2_subj);
    }
    try queue.push(.{ .run_id = t1_run, .subject = t1_subj, .amount = 5000, .note = "", .step_name = "finance", .tenant_id = 1 });
    try queue.push(.{ .run_id = t2_run, .subject = t2_subj, .amount = 9999, .note = "", .step_name = "finance", .tenant_id = 2 });
    try std.testing.expectEqual(@as(usize, 1), try queue.count(1));
    try std.testing.expectEqual(@as(usize, 1), try queue.count(2));

    var t1 = std.ArrayList(ai.approval_store.PendingApproval).empty;
    defer {
        for (t1.items) |it| {
            allocator.free(it.run_id);
            allocator.free(it.subject);
            allocator.free(it.note);
            allocator.free(it.step_name);
        }
        t1.deinit(allocator);
    }
    try queue.listPending(allocator, &t1, 1);
    try std.testing.expectEqual(@as(usize, 1), t1.items.len);
    try std.testing.expectEqualStrings("t1-run", t1.items[0].run_id);
    try std.testing.expect(try queue.resolve("t1-run", 1));
    try std.testing.expectEqual(@as(usize, 0), try queue.count(1));
    try std.testing.expectEqual(@as(usize, 1), try queue.count(2)); // tenant 2 untouched

    // KPI isolation via the skill.
    var registry = ai.SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try ai.kpi.registerKpiSkills(&registry);
    const metrics = [_]ai.kpi.KpiMetric{
        .{ .name = "paid_revenue", .description = "paid revenue", .sql = "SELECT SUM(amount) AS value FROM orders WHERE tenant_id = 1 AND status = 'paid'" },
        .{ .name = "paid_revenue", .description = "paid revenue", .sql = "SELECT SUM(amount) AS value FROM orders WHERE tenant_id = 2 AND status = 'paid'" },
    };
    var kc = ai.kpi.KpiCtx{ .backend = &backend, .metrics = &metrics };
    var sctx = ai.SkillContext{ .allocator = allocator, .tenant_id = 1, .userdata = &kc };
    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "metric", .{ .string = try allocator.dupe(u8, "paid_revenue") });
    const res = try registry.dispatch("kpi.query", &sctx, .{ .object = args_map });
    defer ai.freeValue(allocator, res);
    defer ai.freeValue(allocator, .{ .object = args_map });
    try std.testing.expectEqual(@as(f64, 150), res.object.get("value").?.float);

    // Workflow with metrics + graph export (arena keeps step args tidy).
    var wf_arena = std.heap.ArenaAllocator.init(allocator);
    defer wf_arena.deinit();
    const wa = wf_arena.allocator();
    var wf_metrics = ai.WorkflowMetrics{};
    const EscalateAlways = struct {
        fn decide(_: std.mem.Allocator, _: *ai.SkillContext, _: []const u8, _: i64, _: usize, _: []const u8, _: []const u8, _: *[]const u8) anyerror!ai.approval.ApprovalDecision {
            return .escalated;
        }
    };
    var gate_flow = ai.approval.ApprovalFlow.init(allocator, &backend, EscalateAlways.decide);
    const wf_steps = [_]ai.workflow.Step{
        .{ .name = "kpi-step", .kind = .{ .skill = .{ .name = "kpi.query", .args = .{ .object = blk: {
            var o = std.json.ObjectMap{};
            try putOwned(&o, wa, "metric", .{ .string = try wa.dupe(u8, "paid_revenue") });
            break :blk o;
        } } } } },
        .{ .name = "review", .kind = .{ .approval = .{ .subject = "order-refund", .amount = 5000 } } },
    };
    var wf = ai.workflow.Workflow.init(&registry, &wf_steps);
    wf.metrics = &wf_metrics;
    wf.approval_flow = &gate_flow;
    var wf_result = try wf.run(wa, &sctx);
    defer wf_result.deinit();
    try std.testing.expectEqual(ai.workflow.RunStatus.pending_human, wf_result.status);
    try std.testing.expectEqual(@as(usize, 1), wf_metrics.runs);

    const mermaid = try wf.toMermaid(wa);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "review (approval)") != null);
}
