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
//!       then curl http://127.0.0.1:18087/api/approvals/pending
//!       streaming chat (needs a live LLM):
//!         AI_BASE_URL=http://127.0.0.1:11434/v1/chat/completions \
//!         AI_API_KEY=demo AI_MODEL=qwen3 zig build run
//!       curl -N -X POST http://127.0.0.1:18087/api/ai/chat/stream \
//!         -H 'Content-Type: application/json' \
//!         -d '{"message":"写一句问候"}'
//! Test: zig build test       (asserts every stage + the approval API
//!       + the streaming endpoint against an in-process mock LLM)

const std = @import("std");
const zigmodu = @import("zigmodu");

const ai = zigmodu.ai;
const sqlx = zigmodu.data.sqlx;
const http = zigmodu.http;

/// LLM upstream for the streaming endpoint (env-configured in `main`,
/// pointed at an in-process mock in tests).
const AiConfig = struct {
    base_url: []const u8,
    api_key: []const u8 = "Bearer sk-demo",
    model: []const u8 = "demo-model",
};

/// Per-request state for `streamChatHandler` (legacy RouteGroup user_data).
const StreamState = struct {
    config: ?AiConfig,
};

/// POST /api/ai/chat/stream — JSON body `{"message":"…"}`; streams every
/// provider delta as an SSE `data:` event, then a final answer envelope and
/// the SSE `done` event. When no upstream is configured the stream never
/// starts and the handler answers 503 with plain JSON instead.
fn streamChatHandler(ctx: *http.Context) !void {
    const state = try ctx.state(StreamState);
    const allocator = ctx.allocator;
    const config = state.config orelse {
        try ctx.json(503, "{\"error\":\"LLM not configured: set AI_BASE_URL (optionally AI_API_KEY, AI_MODEL)\"}");
        return;
    };
    const parsed = std.json.parseFromSlice(struct { message: []const u8 }, allocator, ctx.body orelse "", .{}) catch {
        try ctx.json(400, "{\"error\":\"body must be JSON: {\\\"message\\\":\\\"…\\\"}\"}");
        return;
    };
    defer parsed.deinit();

    var client = zigmodu.http.HttpClient.init(allocator, ctx.io.?, 1, 30000);
    defer client.deinit();
    var provider = ai.AiProvider.init(allocator, &client, config.base_url, config.api_key, config.model);
    var registry = ai.SkillRegistry.init(allocator, ctx.io.?);
    defer registry.deinit();
    var agent = ai.Agent{ .provider = &provider, .registry = &registry, .name = "ai-ops-stream" };

    var sse = try http.sse(ctx);
    var bridge = ai.stream_sse.DeltaSse(@TypeOf(sse)).init(allocator, &sse);
    agent.hooks.ctx = &bridge;
    agent.hooks.on_delta = @TypeOf(bridge).onDelta;

    var skill_ctx = ai.SkillContext{ .allocator = allocator };
    var result = agent.run(allocator, parsed.value.message, &skill_ctx, 8) catch |err| {
        std.log.warn("[ai-ops] stream run failed: {}", .{err});
        try sse.sendError(@errorName(err));
        try sse.done();
        return;
    };
    defer result.deinit(allocator);
    const final = try std.json.Stringify.valueAlloc(allocator, .{
        .answer = result.answer,
        .steps = result.steps,
        .model = result.model,
    }, .{});
    defer allocator.free(final);
    try sse.sendData(final);
    try sse.done();
}

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
    \\  tenant_id INTEGER,
    \\  status INTEGER NOT NULL DEFAULT 0,
    \\  retry_count INTEGER NOT NULL DEFAULT 0,
    \\  max_retries INTEGER NOT NULL DEFAULT 5,
    \\  created_at INTEGER NOT NULL,
    \\  updated_at INTEGER NOT NULL,
    \\  error_message TEXT
    \\);
;

pub fn main(init: std.process.Init) !void {
    var ai_config: ?AiConfig = null;
    if (init.environ_map.get("AI_BASE_URL")) |url| {
        ai_config = .{
            .base_url = url,
            .api_key = init.environ_map.get("AI_API_KEY") orelse "Bearer sk-demo",
            .model = init.environ_map.get("AI_MODEL") orelse "demo-model",
        };
    }
    const res = try runDemo(init.gpa, init.io, true, true, ai_config);
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
    queue: *ai.approval_store.PersistentApprovalQueue,
};

/// Full demo: pipeline + persistent approval queue + HTTP API. When
/// `serve` is true the HTTP server blocks; tests pass false and dispatch the
/// handlers directly against the router instead.
fn runDemo(allocator: std.mem.Allocator, io: std.Io, verbose: bool, serve: bool, ai_config: ?AiConfig) !PipelineResult {
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

    var approval_queue = ai.approval_store.PersistentApprovalQueue.init(allocator, &backend);
    try approval_queue.migrate();

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
    approval.on_escalated = ai.approval_store.queuedEscalationPersistent;
    approval.escalated_userdata = &approval_queue;
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

    const notify_payload = try allocator.print("{{\"summary\":\"{s}\",\"alerts\":{d},\"large_order\":\"{s}\",\"small_order\":\"{s}\"}}", .{ diag.summary, alerts, @tagName(large.status), @tagName(small.status) });
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

    // ── 6. Human approval queue HTTP API (mounted, optional serve) ────────
    const ApprovalApi = ai.approval_api.ApprovalApi(ai.approval_store.PersistentApprovalQueue);
    var api = ApprovalApi{ .queue = &approval_queue };
    var server = http.Server.init(io, allocator, 18087);
    defer server.deinit();
    const AppState = struct {};
    var app: AppState = .{};
    var router = http.Router(AppState).init(io, allocator, &server, &app);
    defer router.deinit();
    var v1 = router.scope("/api");
    try v1.mount(ApprovalApi, &api);
    var catalog = try router.finish();
    defer catalog.deinit();

    // Streaming chat SSE (legacy RouteGroup — the approval API above is the
    // comptime-router mount; both live on the same server).
    var stream_state = StreamState{ .config = ai_config };
    var api_group = server.group("/api");
    try api_group.post("ai/chat/stream", streamChatHandler, &stream_state);

    if (verbose) {
        std.debug.print("6. queue    : {d} pending approval(s); API GET /api/approvals/pending  POST /api/approvals/{{id}}/approve|reject\n", .{try approval_queue.count(null)});
        std.debug.print("7. stream   : POST /api/ai/chat/stream (SSE; {s})\n", .{if (ai_config != null) "LLM configured" else "set AI_BASE_URL to enable"});
    }
    if (serve) {
        try server.start();
        return PipelineResult{ .alerts = alerts, .diagnosis_cause = "", .large_status = large.status, .small_status = small.status, .notify_delivered = report.delivered, .outbox_consumed = poll.delivered, .queue = &approval_queue };
    } else {
        try std.testing.expect(catalog.findEntry(.GET, "api/approvals/pending") != null);
        var matched = server.router.match(allocator, .POST, "/api/approvals/order-2/approve") orelse return error.RouteNotFound;
        var http_ctx = try http.Context.init(allocator, .POST, "/api/approvals/order-2/approve");
        defer http_ctx.deinit();
        http_ctx.user_data = matched.route.user_data;
        var pit = matched.params.iterator();
        // `RouteParams.iterator` yields `Entry{ key, value }` by value (the
        // match borrows the router's names and the path it matched against);
        // the context owns copies, so dupe both halves.
        while (pit.next()) |p| try http_ctx.params.put(try allocator.dupe(u8, p.key), try allocator.dupe(u8, p.value));
        try matched.route.handler(&http_ctx);
        try std.testing.expectEqual(@as(usize, 0), try approval_queue.count(null));
    }
    return .{
        .alerts = alerts,
        .diagnosis_cause = try allocator.dupe(u8, diag.causes[0]),
        .large_status = large.status,
        .small_status = small.status,
        .notify_delivered = report.delivered,
        .outbox_consumed = poll.delivered,
        .queue = &approval_queue,
    };
}

test "ai-ops end-to-end pipeline" {
    const allocator = std.testing.allocator;
    const res = try runDemo(allocator, std.testing.io, false, false, null);
    defer allocator.free(res.diagnosis_cause);
    try std.testing.expectEqual(@as(usize, 1), res.alerts);
    try std.testing.expectEqualStrings("payment gateway rejected both charges", res.diagnosis_cause);
    try std.testing.expectEqual(ai.approval.ApprovalStatus.pending_human, res.large_status);
    try std.testing.expectEqual(ai.approval.ApprovalStatus.approved, res.small_status);
    try std.testing.expectEqual(@as(usize, 1), res.notify_delivered);
    try std.testing.expect(res.outbox_consumed >= 3); // approval step/final events + notify fallback
}

/// Send `bytes` in full without SIGPIPE (`MSG_NOSIGNAL`) — same contract as
/// the framework's internal `sockread.writeFull`, which examples can't reach.
fn writeFull(stream: std.Io.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.c.send(stream.socket.handle, bytes[sent..].ptr, bytes.len - sent, std.posix.MSG.NOSIGNAL);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return error.WriteTimeout,
            else => return error.ConnectionError,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.ConnectionClosed;
        sent += n;
    }
}

/// One HTTP/1.1 exchange against a running server; the caller's
/// `Connection: close` ends the read at EOF.
fn h1Exchange(port: u16, request: []const u8, out: []u8) ![]const u8 {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);

    try writeFull(stream, request);

    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 3000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(stream.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return out[0..total];
}

test "ai-ops streaming chat endpoint streams SSE deltas end to end" {
    const allocator = std.testing.allocator;

    // Mock LLM upstream: serves one connection, then keeps accepting (and
    // immediately closing) until told to stop — a bounded accept loop, so a
    // handler failure that never reaches the LLM cannot hang the join in the
    // defer below.
    const MockLlm = struct {
        server: std.Io.net.Server,
        stop: *std.atomic.Value(bool),
        fn run(srv: *std.Io.net.Server, stop: *std.atomic.Value(bool)) void {
            while (!stop.load(.monotonic)) {
                var fds = [_]std.posix.pollfd{.{ .fd = srv.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&fds, 50) catch return;
                if (fds[0].revents == 0) continue;
                const accepted = srv.accept(std.testing.io) catch return;
                defer accepted.close(std.testing.io);
                var buf: [8192]u8 = undefined;
                var cfds = [_]std.posix.pollfd{.{ .fd = accepted.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&cfds, 3000) catch return;
                _ = std.posix.read(accepted.socket.handle, &buf) catch return;
                const body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}],\"model\":\"mock-model\"}\n\ndata: [DONE]\n\n";
                var hbuf: [1024]u8 = undefined;
                const resp = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
                _ = std.posix.system.write(accepted.socket.handle, resp.ptr, resp.len);
                return; // one stream served — further connects mean a retry
            }
        }
    };
    var llm_stop = std.atomic.Value(bool).init(false);
    const llm_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var llm_server = try llm_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer llm_server.deinit(std.testing.io);
    const llm_thread = try std.Thread.spawn(.{}, MockLlm.run, .{ &llm_server, &llm_stop });

    var url_buf: [128]u8 = undefined;
    const config = AiConfig{
        .base_url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{llm_server.socket.address.getPort()}),
    };

    // App server with the streaming route mounted.
    var server = http.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "ai-ops-stream-test" });
    defer server.deinit();
    var stream_state = StreamState{ .config = config };
    var api_group = server.group("/api");
    try api_group.post("ai/chat/stream", streamChatHandler, &stream_state);
    const th = try std.Thread.spawn(.{}, struct {
        fn run(srv: *http.Server) void {
            srv.start() catch |err| std.log.warn("[ai-ops stream test] accept loop ended: {s}", .{@errorName(err)});
        }
    }.run, .{&server});
    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch break;
    }
    try std.testing.expect(port != 0);
    defer {
        server.stop();
        th.join();
        llm_stop.store(true, .monotonic);
        llm_thread.join();
    }

    const req = "POST /api/ai/chat/stream HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{\"message\":\"hi\"}";
    var out: [4096]u8 = undefined;
    const response = try h1Exchange(port, req, &out);

    if (!std.mem.startsWith(u8, response, "HTTP/1.1 200")) {
        std.log.warn("[ai-ops stream test] unexpected response:\n{s}", .{response});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Type: text/event-stream") != null);
    // Streamed delta event, final answer envelope, SSE-level done.
    try std.testing.expect(std.mem.indexOf(u8, response, "data: {\"content\":{\"delta\":\"Hello\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"answer\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "event: done\ndata: [DONE]") != null);
}

test "ai-ops streaming endpoint without LLM answers 503 as JSON" {
    const allocator = std.testing.allocator;
    var server = http.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "ai-ops-stream-503" });
    defer server.deinit();
    var stream_state = StreamState{ .config = null };
    var api_group = server.group("/api");
    try api_group.post("ai/chat/stream", streamChatHandler, &stream_state);
    const th = try std.Thread.spawn(.{}, struct {
        fn run(srv: *http.Server) void {
            srv.start() catch |err| std.log.warn("[ai-ops stream 503] accept loop ended: {s}", .{@errorName(err)});
        }
    }.run, .{&server});
    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch break;
    }
    try std.testing.expect(port != 0);
    defer {
        server.stop();
        th.join();
    }

    const req = "POST /api/ai/chat/stream HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{\"message\":\"hi\"}";
    var out: [4096]u8 = undefined;
    const response = try h1Exchange(port, req, &out);

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 503"));
    try std.testing.expect(std.mem.indexOf(u8, response, "LLM not configured") != null);
}
