//! OpenTelemetry (OTLP/HTTP JSON) Exporter for DistributedTracer.
//! Serializes spans to OTLP JSON and POSTs to a collector endpoint with retries.

const std = @import("std");
const DistributedTracer = @import("DistributedTracer.zig").DistributedTracer;
const Span = DistributedTracer.Span;
const HttpClient = @import("../http/HttpClient.zig").HttpClient;

pub const ExportOptions = struct {
    /// Extra attempts after the first try (total tries = 1 + max_retries).
    max_retries: u32 = 3,
    retry_base_ms: u64 = 100,
    /// Cap for HttpClient connection pool / socket timeout.
    timeout_ms: u64 = 5_000,
};

pub const OtlpExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    service_name: []const u8,
    endpoint_url: []const u8,
    /// The exporter's `HttpClient`, created on the first export and kept until
    /// `deinit` so the connection it pools survives from one export to the next.
    /// A client per export re-dials (and, for `https://`, re-handshakes and
    /// re-reads the system CA bundle) on every push.
    ///
    /// Published once, by atomic compare-exchange, rather than under a mutex: two
    /// threads racing on the first export each build a client and the loser
    /// drops its own never-used one (`HttpClient.init` allocates nothing, so that
    /// discard closes no connection). Nothing swaps this pointer again until
    /// `deinit`, so every reader sees the same fully initialized client — and
    /// `HttpClient` is thread-safe for concurrent requests.
    client: std.atomic.Value(?*HttpClient) = .init(null),

    pub fn init(allocator: std.mem.Allocator, service_name: []const u8, endpoint_url: []const u8) !Self {
        return .{
            .allocator = allocator,
            .service_name = try allocator.dupe(u8, service_name),
            .endpoint_url = try allocator.dupe(u8, endpoint_url),
        };
    }

    /// Frees the resident client along with the strings.
    ///
    /// Contract (inherited from `HttpClient.deinit`, which asserts its pool is
    /// idle): no export may be in flight while this runs. Every export releases
    /// its connection before it returns, so calling `deinit` after the exporting
    /// thread has joined is enough — `deinit` while an `exportSpans` call is
    /// still on another thread is a use-after-free.
    pub fn deinit(self: *Self) void {
        if (self.client.swap(null, .acq_rel)) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.allocator.free(self.service_name);
        self.allocator.free(self.endpoint_url);
        self.* = undefined;
    }

    /// This exporter's resident client, created on first use.
    ///
    /// `timeout_ms` is the caller's `ExportOptions.timeout_ms` and is applied on
    /// every call: it is the plain-`http://` socket budget (`HttpClient`'s TLS
    /// path does not read it), so a call that changes it must not be ignored.
    /// That assignment is a plain field store, so concurrent exports of one
    /// exporter should agree on the value — the alternative would be a client per
    /// call, which is what this replaces.
    ///
    /// The `io` of the first call is the one the client keeps; it is the
    /// process-wide scheduler, so later calls passing another `std.Io` still
    /// work as long as it is the same one the app started with.
    fn acquireClient(self: *Self, io: std.Io, timeout_ms: u64) !*HttpClient {
        if (self.client.load(.acquire)) |client| {
            client.timeout_ms = timeout_ms;
            return client;
        }

        const client = try self.allocator.create(HttpClient);
        client.* = HttpClient.init(self.allocator, io, 2, timeout_ms);

        // `cmpxchgStrong` wraps its result again when the payload is already
        // optional, hence the `.?`: a non-null result *is* the "another thread
        // won" case, and null means this thread published.
        if (self.client.cmpxchgStrong(null, client, .release, .acquire)) |published| {
            const existing = published.?;
            // Ours never served a request, so tearing it down frees nothing but
            // the struct itself.
            client.deinit();
            self.allocator.destroy(client);
            existing.timeout_ms = timeout_ms;
            return existing;
        }
        return client;
    }

    /// Serialize a slice of spans into OTLP JSON payload format.
    pub fn serializeSpansJson(self: *Self, spans: []const Span) ![]const u8 {
        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(self.allocator);

        try list.appendSlice(self.allocator, "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"");
        try list.appendSlice(self.allocator, self.service_name);
        try list.appendSlice(self.allocator, "\"}}]},\"scopeSpans\":[{\"spans\":[");

        for (spans, 0..) |span, i| {
            if (i > 0) try list.appendSlice(self.allocator, ",");
            const tid = try span.trace_id.toString(self.allocator);
            defer self.allocator.free(tid);
            const sid = try span.span_id.toString(self.allocator);
            defer self.allocator.free(sid);

            const end_time_val = span.end_time orelse span.start_time;
            const st_ns: u64 = @as(u64, @intCast(@max(0, span.start_time))) *% 1_000_000;
            const et_ns: u64 = @as(u64, @intCast(@max(0, end_time_val))) *% 1_000_000;

            const buf = try std.fmt.allocPrint(self.allocator, "{{\"traceId\":\"{s}\",\"spanId\":\"{s}\",\"name\":\"{s}\",\"kind\":1,\"startTimeUnixNano\":{d},\"endTimeUnixNano\":{d}}}", .{
                tid,
                sid,
                span.name,
                st_ns,
                et_ns,
            });

            defer self.allocator.free(buf);
            try list.appendSlice(self.allocator, buf);
        }

        try list.appendSlice(self.allocator, "]}]}]}");
        return list.toOwnedSlice(self.allocator);
    }

    /// OTLP/HTTP: retryable statuses (throttle + server errors).
    pub fn isRetryableStatus(status_code: u16) bool {
        return status_code == 429 or status_code >= 500;
    }

    /// POST serialized spans to `endpoint_url` (OTLP/HTTP JSON).
    /// Retries on transport errors and retryable HTTP statuses.
    pub fn exportSpans(self: *Self, io: std.Io, spans: []const Span, opts: ExportOptions) !void {
        const json = try self.serializeSpansJson(spans);
        defer self.allocator.free(json);
        try self.postJsonWithRetry(io, json, opts);
    }

    pub fn postJsonWithRetry(self: *Self, io: std.Io, json: []const u8, opts: ExportOptions) !void {
        if (!std.mem.startsWith(u8, self.endpoint_url, "http://") and
            !std.mem.startsWith(u8, self.endpoint_url, "https://"))
        {
            return error.InvalidOtlpEndpoint;
        }

        const client = try self.acquireClient(io, opts.timeout_ms);

        var attempt: u32 = 0;
        const max_attempts = opts.max_retries + 1;
        var last_err: anyerror = error.OtlpExportFailed;

        while (attempt < max_attempts) : (attempt += 1) {
            var resp = client.post(self.endpoint_url, json) catch |err| {
                last_err = err;
                if (attempt + 1 >= max_attempts) return err;
                try sleepBackoff(io, opts.retry_base_ms, attempt);
                continue;
            };
            defer resp.deinit();

            if (resp.isSuccess()) return;

            last_err = error.OtlpExportFailed;
            if (!isRetryableStatus(resp.status_code) or attempt + 1 >= max_attempts) {
                std.log.warn("OTLP export failed: HTTP {d} endpoint={s}", .{ resp.status_code, self.endpoint_url });
                return error.OtlpExportFailed;
            }
            std.log.warn("OTLP export retryable HTTP {d}, attempt {d}/{d}", .{ resp.status_code, attempt + 1, max_attempts });
            try sleepBackoff(io, opts.retry_base_ms, attempt);
        }
        return last_err;
    }
};

fn sleepBackoff(io: std.Io, base_ms: u64, attempt: u32) !void {
    const shift: u6 = @intCast(@min(attempt, 6));
    const delay_ms = base_ms * (@as(u64, 1) << shift);
    try std.Io.sleep(io, .{ .nanoseconds = delay_ms * std.time.ns_per_ms }, .real);
}

test "OtlpExporter JSON serialization" {
    const allocator = std.testing.allocator;
    var exporter = try OtlpExporter.init(allocator, "shop-service", "http://localhost:4318/v1/traces");
    defer exporter.deinit();

    var tracer = try DistributedTracer.init(allocator, "test-tracer", "shop-service");
    defer tracer.deinit();

    const span = try tracer.startTrace("GET /api/users");
    defer {
        tracer.endSpan(span);
        span.deinit(allocator);
        allocator.destroy(span);
    }

    const spans = &[_]Span{span.*};
    const json = try exporter.serializeSpansJson(spans);
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "shop-service"));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "GET /api/users"));
}

test "OtlpExporter isRetryableStatus" {
    try std.testing.expect(OtlpExporter.isRetryableStatus(429));
    try std.testing.expect(OtlpExporter.isRetryableStatus(503));
    try std.testing.expect(!OtlpExporter.isRetryableStatus(200));
    try std.testing.expect(!OtlpExporter.isRetryableStatus(400));
}

test "OtlpExporter accepts https endpoint (routes via HttpClient TLS)" {
    const allocator = std.testing.allocator;
    var exporter = try OtlpExporter.init(allocator, "svc", "https://collector.example/v1/traces");
    defer exporter.deinit();
    // No live network in unit tests: an unreachable collector surfaces as a
    // transport error, NOT OtlpTlsNotSupported — https is now a supported
    // scheme routed through std.http.Client.
    if (exporter.postJsonWithRetry(std.testing.io, "{}", .{ .max_retries = 0 })) |_| {
        return error.ExpectedFailure;
    } else |err| {
        try std.testing.expect(err != error.OtlpTlsNotSupported);
        try std.testing.expect(err != error.InvalidOtlpEndpoint);
    }
}

// ── resident-client connection reuse ─────────────────────────────────────────

/// Loopback HTTP server that counts TCP accepts: it answers every request on a
/// connection with `payload` and leaves the connection open (HTTP/1.1
/// keep-alive). One accept for N requests means the client pooled its
/// connection; N accepts means it dialed per request.
const ReuseProbeServer = struct {
    listener: *std.Io.net.Server,
    payload: []const u8,
    accepts: std.atomic.Value(usize) = .init(0),
    requests: std.atomic.Value(usize) = .init(0),

    fn run(ctx: *@This()) void {
        var first = true;
        while (true) {
            // The first accept waits for the client; afterwards only a short
            // grace period, so a finished test ends instead of hanging on join.
            const wait_ms: i32 = if (first) 5000 else 300;
            first = false;
            if (!probeWaitReadable(ctx.listener.socket.handle, wait_ms)) return;
            const accepted = ctx.listener.accept(std.testing.io) catch return;
            _ = ctx.accepts.fetchAdd(1, .monotonic);
            while (probeReadRequest(accepted)) {
                _ = ctx.requests.fetchAdd(1, .monotonic);
                probeWriteAll(accepted.socket.handle, ctx.payload);
            }
            accepted.close(std.testing.io);
        }
    }
};

/// Poll/read/write by raw syscall: this runs on a thread that shares the testing
/// io scheduler with the test thread, where an io-path read can stall (same
/// reason the HttpClient framing probes do it).
fn probeWaitReadable(fd: std.posix.socket_t, timeout_ms: i32) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, timeout_ms) catch return false;
    return n > 0;
}

/// Read exactly one request — the head plus the body its `Content-Length`
/// promises — so a reused connection starts the next request byte-aligned.
/// False when the peer closed instead of sending one.
fn probeReadRequest(accepted: std.Io.net.Stream) bool {
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var body_len: ?usize = null;
    while (total < buf.len) {
        if (!probeWaitReadable(accepted.socket.handle, 1000)) return false;
        const n = std.posix.read(accepted.socket.handle, buf[total..]) catch return false;
        if (n == 0) return false;
        total += n;
        const head_end = std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse continue;
        if (body_len == null) {
            body_len = if (probeHeaderValue(buf[0..head_end], "content-length")) |v|
                std.fmt.parseInt(usize, v, 10) catch 0
            else
                0;
        }
        if (total >= head_end + 4 + body_len.?) return true;
    }
    return false;
}

/// Case-insensitive value of `name` inside a raw request head.
fn probeHeaderValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn probeWriteAll(fd: std.posix.socket_t, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (std.posix.errno(rc) != .SUCCESS) return;
        const n: usize = @intCast(rc);
        if (n == 0) return;
        sent += n;
    }
}

test "OtlpExporter reuses one connection across exports (resident client)" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/traces", .{port});

    var server = ReuseProbeServer{
        .listener = &listener,
        .payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
    };
    const th = try std.Thread.spawn(.{}, ReuseProbeServer.run, .{&server});
    var joined = false;
    defer if (!joined) th.join();

    {
        var exporter = try OtlpExporter.init(allocator, "svc", url);
        defer exporter.deinit();

        var tracer = try DistributedTracer.init(allocator, "reuse", "svc");
        defer tracer.deinit();
        const span = try tracer.startTrace("otlp.reuse");
        defer {
            tracer.endSpan(span);
            span.deinit(allocator);
            allocator.destroy(span);
        }

        for (0..3) |_| {
            try exporter.exportSpans(io, &.{span.*}, .{ .max_retries = 0, .timeout_ms = 2_000 });
        }

        // Three exports, one socket: the pool's own per-connection counter is the
        // reading that says the same connection served all three (a re-dial would
        // have restarted it at 1). `std.testing.allocator` fails this test if
        // `deinit` below misses the client it allocates.
        const client = exporter.client.load(.acquire) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 1), client.connection_pool.idle_connections.items.len);
        try std.testing.expectEqual(@as(u64, 3), client.connection_pool.idle_connections.items[0].request_count);
    }

    // `deinit` closed the pooled connection, so the probe's read sees EOF and
    // its accept loop ends.
    th.join();
    joined = true;
    try std.testing.expectEqual(@as(usize, 1), server.accepts.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), server.requests.load(.monotonic));
}

// Lazy creation is the one place where two threads touch the same field at
// once, so it gets a real race rather than an argument: every thread must come
// away with the same client. `std.testing.allocator` fails this test on any
// leaked byte, which is what catches a thread that lost the race and did not
// free the client it built.
test "OtlpExporter's first-use race publishes one client for every thread" {
    const allocator = std.testing.allocator;
    const thread_count = 8;

    var exporter = try OtlpExporter.init(allocator, "svc", "http://127.0.0.1:1/v1/traces");
    defer exporter.deinit();

    const Race = struct {
        exporter: *OtlpExporter,
        io: std.Io,
        gate: *std.atomic.Value(bool),
        results: *[thread_count]?*HttpClient,

        fn run(self: *@This(), slot: usize) void {
            // Line the threads up so they reach the first-use branch together.
            while (!self.gate.load(.acquire)) std.atomic.spinLoopHint();
            self.results[slot] = self.exporter.acquireClient(self.io, 1_000) catch null;
        }
    };

    var gate = std.atomic.Value(bool).init(false);
    var results: [thread_count]?*HttpClient = @splat(null);
    var race = Race{
        .exporter = &exporter,
        .io = std.testing.io,
        .gate = &gate,
        .results = &results,
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try std.Thread.spawn(.{}, Race.run, .{ &race, i });
    gate.store(true, .release);
    for (&threads) |*thread| thread.join();

    const first = results[0] orelse return error.TestUnexpectedResult;
    for (results) |maybe_client| {
        const client = maybe_client orelse return error.TestUnexpectedResult;
        try std.testing.expect(first == client);
    }
    try std.testing.expect(exporter.client.load(.acquire).? == first);
}

test "OtlpExporter live HTTP export" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ep_c = std.c.getenv("OTLP_ENDPOINT") orelse return error.SkipZigTest;
    const ep = std.mem.span(ep_c);
    if (ep.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var exporter = try OtlpExporter.init(allocator, "zigmodu-test", ep);
    defer exporter.deinit();

    var tracer = try DistributedTracer.init(allocator, "live", "zigmodu-test");
    defer tracer.deinit();
    const span = try tracer.startTrace("otlp.live");
    defer {
        tracer.endSpan(span);
        span.deinit(allocator);
        allocator.destroy(span);
    }

    try exporter.exportSpans(io, &.{span.*}, .{ .max_retries = 1, .timeout_ms = 2_000 });
}
