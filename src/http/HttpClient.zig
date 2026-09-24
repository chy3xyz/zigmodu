const std = @import("std");
const Time = @import("../core/Time.zig");

/// HTTP client with connection pool and retry
pub const HttpClient = struct {
    const Self = @This();

    /// How far the clock `std.http.Client` verifies certificates against may
    /// drift before it is dropped and re-read.
    ///
    /// `std.http.Client.now` is the time used for certificate expiry
    /// (`std/http/Client.zig`, `.realtime_now` handed to the TLS client), and
    /// std captures it once — on that client's first HTTPS request. A client
    /// kept alive for hours would then keep checking certificates against a
    /// clock from hours ago, so a certificate that expired in the meantime
    /// still verifies. Setting that field to `null` is std's documented way of
    /// asking for a re-read: the next HTTPS request takes the time again and
    /// rescans the system CA bundle. Re-arming on a deviation bound costs one
    /// CA-bundle scan per `https_clock_max_skew_seconds` of traffic instead of
    /// one per request, and bounds how stale a clock a certificate check can
    /// see. Five minutes, like the plain pool's idle window, is a compromise:
    /// far below any certificate's useful lifetime, far above the scan cost.
    ///
    /// A fresh `std.http.Client` would have the same problem one request later,
    /// which is why the resident client is re-armed rather than replaced (a
    /// replacement would also drop every pooled TLS connection).
    pub const https_clock_max_skew_seconds: i64 = 300;

    allocator: std.mem.Allocator,
    connection_pool: ConnectionPool,
    retry_policy: RetryPolicy,
    timeout_ms: u64,
    /// Shared `std.http.Client` for the HTTPS path, created on first use and
    /// kept until `deinit`. One instance is what lets outbound TLS connections
    /// be reused (`keep_alive`) and keeps the system CA bundle from being
    /// rescanned per request.
    ///
    /// Two things it caches go stale with uptime: the CA bundle (that is the
    /// point) and the clock std decides certificate expiry with — see
    /// `https_clock_max_skew_seconds`.
    https_client: ?*std.http.Client,
    /// Guards `https_client`: creation, hand-out, clock re-arm and teardown.
    /// Held only for the hand-out, never across a request — `std.http.Client`
    /// is itself thread-safe, and serializing all outbound TLS behind this
    /// mutex would be a throughput regression.
    ///
    /// Lock order: `https_mutex` → `std.http.Client.connection_pool.mutex`.
    https_mutex: std.Io.Mutex,
    /// How many `std.http.Client` instances this `HttpClient` created. Created
    /// lazily on the first HTTPS request and never replaced, so this stays 1 —
    /// anything else means the shape regressed to one client per request.
    /// Read by tests, and useful when wondering whether outbound TLS is being
    /// re-handshaked per request.
    https_clients_created: u32,
    /// HTTPS hand-outs not yet returned. Another thread may be inside
    /// `std.http.Client` while the clock is checked, and std reads the field
    /// that re-arming clears outside of any lock (its own comment: "TODO data
    /// race here on ca_bundle if the user sets `now` to null"). A non-zero count
    /// therefore suspends the re-arm, which is why it is kept under
    /// `https_mutex` together with the hand-out itself.
    https_inflight: usize,
    /// Set by `deinit`. Later requests fail with `error.HttpClientClosed`
    /// instead of touching torn-down state.
    closed: bool,

    pub const ConnectionPool = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        max_connections: usize,
        idle_connections: std.ArrayList(Connection),
        active_connections: std.ArrayList(Connection),
        mutex: std.Io.Mutex,

        pub const Connection = struct {
            host: []const u8,
            port: u16,
            stream: ?std.Io.net.Stream,
            created_at: i64,
            last_used: i64,
            request_count: u64,

            pub fn isAlive(self: Connection) bool {
                if (self.stream == null) return false;
                // Simplified: check timeout
                const now = Time.monotonicNowSeconds();
                return (now - self.last_used) < 30; // 30-second timeout
            }
        };

        pub fn init(allocator: std.mem.Allocator, io: std.Io, max_connections: usize) ConnectionPool {
            return .{
                .allocator = allocator,
                .io = io,
                .max_connections = max_connections,
                .idle_connections = std.ArrayList(Connection).empty,
                .active_connections = std.ArrayList(Connection).empty,
                .mutex = std.Io.Mutex.init,
            };
        }

        pub fn deinit(self: *ConnectionPool) void {
            for (self.idle_connections.items) |conn| {
                if (conn.stream) |stream| {
                    stream.close(self.io);
                }
                self.allocator.free(conn.host);
            }
            self.idle_connections.deinit(self.allocator);

            for (self.active_connections.items) |conn| {
                if (conn.stream) |stream| {
                    stream.close(self.io);
                }
                self.allocator.free(conn.host);
            }
            self.active_connections.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16) !Connection {
            self.mutex.lock(self.io) catch return error.ServerError;
            defer self.mutex.unlock(self.io);

            // Find idle connection & evict stale ones
            var idx: usize = 0;
            while (idx < self.idle_connections.items.len) {
                const conn = self.idle_connections.items[idx];
                if (std.mem.eql(u8, conn.host, host) and conn.port == port) {
                    if (conn.isAlive()) {
                        // Reserve the active-list slot *before* the removal: the
                        // `swapRemove` is the irreversible half, so a fallible
                        // `append` after it would lose the connection on OOM —
                        // gone from `idle_connections`, never on
                        // `active_connections`, never closed, `host` never freed,
                        // and `max_connections` still counting its slot. Failing
                        // the reservation first leaves the pool as it was, with
                        // the connection still idle for the next caller.
                        try self.active_connections.ensureUnusedCapacity(self.allocator, 1);
                        const connection = self.idle_connections.swapRemove(idx);
                        self.active_connections.appendAssumeCapacity(connection);
                        return connection;
                    } else {
                        const dead = self.idle_connections.swapRemove(idx);
                        if (dead.stream) |stream| stream.close(self.io);
                        self.allocator.free(dead.host);
                        continue;
                    }
                }
                idx += 1;
            }

            // Create new connection
            if (self.active_connections.items.len >= self.max_connections) {
                return error.PoolExhausted;
            }

            const addr = try std.Io.net.IpAddress.resolve(self.io, host, port);
            const stream = try addr.connect(self.io, .{ .mode = .stream });
            // Nothing owns the socket or the copy yet, so these are the only
            // chances to close/free them if a later step fails: the append below
            // is the last fallible operation before the pool takes over.
            errdefer stream.close(self.io);
            const host_copy = try self.allocator.dupe(u8, host);
            errdefer self.allocator.free(host_copy);

            const conn = Connection{
                .host = host_copy,
                .port = port,
                .stream = stream,
                .created_at = Time.monotonicNowSeconds(),
                .last_used = Time.monotonicNowSeconds(),
                .request_count = 0,
            };

            try self.active_connections.append(self.allocator, conn);
            return conn;
        }

        /// Return `conn` to `idle_connections`, making it available to the next
        /// `acquire`.
        ///
        /// Only call this once the request that borrowed it is known to have
        /// completed — `isAlive()` is a 30-second wall-clock window over
        /// `last_used` and says nothing about the request that just ran, so
        /// pooling a connection whose request failed hands the next request a
        /// socket that is already dead. A failed request ends in `discard`.
        pub fn release(self: *ConnectionPool, conn: Connection) void {
            // Uncancelable: `release` is the borrower handing the socket back,
            // and a canceled `lock` has no way to say "never mind". The old
            // `catch return` left the connection on `active_connections` for
            // good — never idle, never closed, with `max_connections` still
            // counting its slot — so every canceled release shrank the pool by
            // one. Waiting is the honest answer: the critical section is a list
            // move. Same choice as `pool.Pool.release` and `sqlx.ConnPool.release`.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.removeActiveLocked(conn);

            // Return to idle pool if still alive
            if (conn.isAlive()) {
                var released_conn = conn;
                released_conn.last_used = Time.monotonicNowSeconds();
                // The connection is off `active_connections` already, so a failed
                // append has to end like the dead-connection branch below:
                // dropped here it would be on no list at all, with nobody left to
                // close the socket or free its host.
                self.idle_connections.append(self.allocator, released_conn) catch |err| {
                    std.log.debug("[http-client] idle connection closed instead of pooled ({s})", .{@errorName(err)});
                    if (released_conn.stream) |stream| stream.close(self.io);
                    self.allocator.free(released_conn.host);
                };
            } else {
                if (conn.stream) |stream| {
                    stream.close(self.io);
                }
                self.allocator.free(conn.host);
            }
        }

        /// Put `conn` down instead of back: close the socket and drop it from
        /// the pool. This is the `release` for a request that failed — the
        /// socket is either dead or left at an unknown position in the response
        /// (timeout mid-head, truncated body, malformed framing), and neither is
        /// a state the next request may resume from.
        pub fn discard(self: *ConnectionPool, conn: Connection) void {
            // Uncancelable for the same reason as `release`: a canceled
            // `catch return` here left a socket the caller had already written
            // off on `active_connections` — never closed, `host` never freed,
            // slot never released.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.removeActiveLocked(conn);
            if (conn.stream) |stream| {
                stream.close(self.io);
            }
            self.allocator.free(conn.host);
        }

        /// Take `conn` out of `active_connections`. Caller holds `mutex`.
        ///
        /// Matched by socket handle, which is how the pool identifies a
        /// connection it handed out (the caller's copy may have moved on:
        /// `request_count` is bumped by the borrower).
        fn removeActiveLocked(self: *ConnectionPool, conn: Connection) void {
            for (self.active_connections.items, 0..) |active_conn, i| {
                if (active_conn.stream != null and conn.stream != null and active_conn.stream.?.socket.handle == conn.stream.?.socket.handle) {
                    _ = self.active_connections.swapRemove(i);
                    break;
                }
            }
        }
    };

    pub const RetryPolicy = struct {
        max_retries: u32,
        initial_delay_ms: u64,
        max_delay_ms: u64,
        backoff_multiplier: f64,

        pub fn default() RetryPolicy {
            return .{
                .max_retries = 3,
                .initial_delay_ms = 100,
                .max_delay_ms = 10000,
                .backoff_multiplier = 2.0,
            };
        }

        pub fn calculateDelay(self: RetryPolicy, attempt: u32) u64 {
            const delay = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.initial_delay_ms)) *
                std.math.pow(f64, self.backoff_multiplier, @as(f64, @floatFromInt(attempt)))));
            return @min(delay, self.max_delay_ms);
        }
    };

    pub const HttpRequest = struct {
        method: []const u8,
        url: []const u8,
        headers: std.StringHashMap([]const u8),
        body: ?[]const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, method: []const u8, url: []const u8) HttpRequest {
            return .{
                .method = method,
                .url = url,
                .headers = std.StringHashMap([]const u8).init(allocator),
                .body = null,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *HttpRequest) void {
            var iter = self.headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            if (self.body) |body| {
                self.allocator.free(body);
            }
            self.* = undefined;
        }

        pub fn setHeader(self: *HttpRequest, key: []const u8, value: []const u8) !void {
            const key_copy = try self.allocator.dupe(u8, key);
            const value_copy = try self.allocator.dupe(u8, value);
            try self.headers.put(key_copy, value_copy);
        }

        pub fn setBody(self: *HttpRequest, body: []const u8) !void {
            self.body = try self.allocator.dupe(u8, body);
        }
    };

    pub const HttpResponse = struct {
        status_code: u16,
        headers: std.StringHashMap([]const u8),
        body: []const u8,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) HttpResponse {
            return .{
                .status_code = 0,
                .headers = std.StringHashMap([]const u8).init(allocator),
                .body = "",
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *HttpResponse) void {
            var iter = self.headers.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.headers.deinit();
            self.allocator.free(self.body);
            self.* = undefined;
        }

        pub fn isSuccess(self: HttpResponse) bool {
            return self.status_code >= 200 and self.status_code < 300;
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, max_connections: usize, timeout_ms: u64) Self {
        return .{
            .allocator = allocator,
            .connection_pool = ConnectionPool.init(allocator, io, max_connections),
            .retry_policy = RetryPolicy.default(),
            .timeout_ms = timeout_ms,
            .https_client = null,
            .https_mutex = .init,
            .https_clients_created = 0,
            .https_inflight = 0,
            .closed = false,
        };
    }

    /// Release the shared HTTPS client and the plain-HTTP connection pool.
    ///
    /// Must not run while another thread has a request in flight: std asserts
    /// that its pool has no used connections (and would close connections out
    /// from under them). Every entry point fails with `error.HttpClientClosed`
    /// once this returned, and a second `deinit` is a no-op.
    pub fn deinit(self: *Self) void {
        if (self.closed) return;
        self.closed = true;

        const io = self.connection_pool.io;
        // Uncancelable: a canceled teardown would leak the client's
        // connections and its CA bundle.
        self.https_mutex.lockUncancelable(io);
        const https_client = self.https_client;
        self.https_client = null;
        self.https_mutex.unlock(io);

        if (https_client) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }

        self.connection_pool.deinit();
    }

    /// Get the shared HTTPS client, creating it on first use, and count the
    /// hand-out.
    ///
    /// The lock is taken cancelably (this is the request path) and released
    /// before the caller starts the request; `deinit` takes the same mutex
    /// uncancelably and nulls the pointer before freeing it. Every hand-out must
    /// be balanced by `releaseHttpsClient`.
    ///
    /// A hand-out that finds no other request in flight re-arms the client's
    /// certificate clock when it has drifted too far (`rearmHttpsClockIfStale`).
    fn httpsClient(self: *Self) !*std.http.Client {
        const io = self.connection_pool.io;
        self.https_mutex.lock(io) catch |err| return err;
        defer self.https_mutex.unlock(io);

        if (self.closed) return error.HttpClientClosed;

        if (self.https_client) |client| {
            // Only when nobody holds the client: std reads the clock field
            // outside its CA-bundle lock, so clearing it under an in-flight
            // request is the data race std's own TODO warns about.
            if (self.https_inflight == 0) rearmHttpsClockIfStale(client, io);
            self.https_inflight += 1;
            return client;
        }

        const client = try self.allocator.create(std.http.Client);
        errdefer self.allocator.destroy(client);
        client.* = .{ .allocator = self.allocator, .io = io };
        self.https_client = client;
        self.https_clients_created += 1;
        self.https_inflight += 1;
        return client;
    }

    /// Counterpart of `httpsClient`: call it once per hand-out, on every path
    /// out of the request (success and failure alike).
    fn releaseHttpsClient(self: *Self) void {
        const io = self.connection_pool.io;
        self.https_mutex.lockUncancelable(io);
        defer self.https_mutex.unlock(io);
        std.debug.assert(self.https_inflight != 0);
        self.https_inflight -= 1;
    }

    /// Drop the resident client's cached certificate clock once it is more than
    /// `https_clock_max_skew_seconds` away from the real clock, so std takes the
    /// time again (and rescans the CA bundle) on the next HTTPS request.
    ///
    /// Deviation in either direction counts, not just a clock that fell behind:
    /// on a backward wall-clock step the cached time would make certificate
    /// checks *stricter* than reality, refusing certificates that are still
    /// valid. Caller holds `https_mutex` and has no request in flight.
    fn rearmHttpsClockIfStale(client: *std.http.Client, io: std.Io) void {
        // `null` means std has not taken the time yet (nothing is stale) or that
        // a request is already going to re-read it — either way, leave it.
        const cached_seconds = (client.now orelse return).toSeconds();
        const real_seconds = std.Io.Clock.real.now(io).toSeconds();
        const skew_seconds = if (real_seconds > cached_seconds)
            real_seconds - cached_seconds
        else
            cached_seconds - real_seconds;
        if (skew_seconds <= https_clock_max_skew_seconds) return;
        client.now = null;
    }

    const Target = struct {
        host: []const u8,
        port: u16,
        path: []const u8,
        is_tls: bool,
    };

    /// Send HTTP(S) request (with retry). HTTPS uses `std.http.Client` (TLS 1.3).
    pub fn request(self: *Self, req: HttpRequest) !HttpResponse {
        if (self.closed) return error.HttpClientClosed;

        var last_error: anyerror = error.Unknown;

        var attempt: u32 = 0;
        while (attempt <= self.retry_policy.max_retries) : (attempt += 1) {
            return self.executeRequest(req) catch |err| {
                last_error = err;

                // The failed attempt has already released its connection by
                // now. A reused TLS connection that the peer closed while it
                // sat idle shows up here as ReadFailed/WriteFailed; std marks
                // the ReadFailed case for closing and destroys it, but a
                // failure *before* the response head leaves std's request
                // reader in `.ready` and std pools that connection again — so
                // the retry would pick the same dead connection. Drop this
                // target's idle TLS connections, forcing a fresh dial.
                //
                // The plain-HTTP pool needs no equivalent here: `executeRequest`
                // closes its failing connection on the way out (the `errdefer`),
                // so it is already gone from `idle_connections` by this point.
                self.discardIdleHttpsConnectionsFor(req.url);

                if (attempt < self.retry_policy.max_retries) {
                    const delay = self.retry_policy.calculateDelay(attempt);
                    std.log.warn("Request failed, retrying in {d}ms (attempt {d}/{d})", .{ delay, attempt + 1, self.retry_policy.max_retries });
                    std.Io.sleep(self.connection_pool.io, .{ .nanoseconds = delay * std.time.ns_per_ms }, .real) catch |sleep_err| std.log.debug("[http-client] retry backoff sleep interrupted ({s})", .{@errorName(sleep_err)});
                }
                continue;
            };
        }

        return last_error;
    }

    pub fn parseTarget(url: []const u8, host_buf: *[256]u8, path_buf: *[4096]u8) !Target {
        const parsed_url = try std.Uri.parse(url);
        const is_https = std.ascii.eqlIgnoreCase(parsed_url.scheme, "https");
        const is_http = std.ascii.eqlIgnoreCase(parsed_url.scheme, "http");
        if (!is_https and !is_http) return error.UnsupportedScheme;

        const host_component = parsed_url.host orelse return error.InvalidUrl;
        const host = host_component.toRaw(host_buf) catch return error.InvalidUrl;
        const port: u16 = if (parsed_url.port) |p|
            if (p <= std.math.maxInt(u16)) @intCast(p) else return error.InvalidPort
        else if (is_https)
            443
        else
            80;

        var path_tmp: [2048]u8 = undefined;
        const path_only_raw = parsed_url.path.toRaw(&path_tmp) catch "/";
        const path_base: []const u8 = if (path_only_raw.len == 0) "/" else path_only_raw;

        if (parsed_url.query) |qcomp| {
            var qbuf: [2048]u8 = undefined;
            const qstr = qcomp.toRaw(&qbuf) catch return error.InvalidUrl;
            const full = std.fmt.bufPrint(path_buf, "{s}?{s}", .{ path_base, qstr }) catch return error.InvalidUrl;
            return .{ .host = host, .port = port, .path = full, .is_tls = is_https };
        }
        if (path_base.len > path_buf.len) return error.InvalidUrl;
        @memcpy(path_buf[0..path_base.len], path_base);
        return .{ .host = host, .port = port, .path = path_buf[0..path_base.len], .is_tls = is_https };
    }

    fn parseMethod(method: []const u8) std.http.Method {
        if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
        if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
        if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
        if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
        if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
        if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .HEAD;
        return .GET;
    }

    /// HTTPS via the shared `std.http.Client` (system CA bundle + TLS 1.3).
    ///
    /// `keep_alive` is std's default (`true`): a completed response leaves the
    /// TLS connection in the client's pool for the next request to the same
    /// host. Failures are handled by the caller's retry loop, which discards
    /// this target's idle connections first.
    fn executeHttps(self: *Self, req: HttpRequest) !HttpResponse {
        const client = try self.httpsClient();
        defer self.releaseHttpsClient();

        var header_list = std.ArrayList(std.http.Header).empty;
        defer header_list.deinit(self.allocator);
        var iter = req.headers.iterator();
        while (iter.next()) |entry| {
            try header_list.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = req.url },
            .method = parseMethod(req.method),
            .payload = req.body,
            .extra_headers = header_list.items,
            .response_writer = &aw.writer,
        }) catch |err| return mapHttpsError(err);

        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();
        resp.status_code = @backingInt(result.status);
        resp.body = try aw.toOwnedSlice();
        return resp;
    }

    /// HTTPS incremental body stream via `std.http.Client` (read loop → on_chunk).
    ///
    /// A stream that stops before the end of the body — `on_chunk` failing, a
    /// read error, the caller giving up in the middle of an SSE/LLM stream —
    /// closes its connection instead of returning it to the pool. Leaving the
    /// connection reusable is not safe here for two reasons: std's
    /// `Request.deinit` would try to *drain* the rest of the body (blocking
    /// until the peer ends a body that may never end), and a half-consumed
    /// stream is not a position a later request may resume from. See the
    /// `errdefer` below for the mechanism.
    fn executeHttpsStream(self: *Self, req: HttpRequest, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        const client = try self.httpsClient();
        defer self.releaseHttpsClient();

        var header_list = std.ArrayList(std.http.Header).empty;
        defer header_list.deinit(self.allocator);
        var iter = req.headers.iterator();
        while (iter.next()) |entry| {
            try header_list.append(self.allocator, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }

        const uri = std.Uri.parse(req.url) catch return error.InvalidUrl;
        var https_req = client.request(parseMethod(req.method), uri, .{
            .extra_headers = header_list.items,
        }) catch |err| return mapHttpsError(err);
        defer https_req.deinit();
        // Registration order is load-bearing: defers run newest-first, so this
        // has to come after `defer https_req.deinit()` to run *before* it.
        // `Request.deinit` only skips the drain (and the return to the pool)
        // when the connection is already marked closing.
        errdefer {
            if (https_req.connection) |conn| conn.closing = true;
        }

        if (req.body) |body| {
            https_req.sendBodyComplete(@constCast(body)) catch |err| return mapHttpsError(err);
        } else {
            https_req.sendBodiless() catch |err| return mapHttpsError(err);
        }

        var response = https_req.receiveHead(&.{}) catch |err| return mapHttpsError(err);

        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();
        resp.status_code = @backingInt(response.head.status);
        resp.body = try self.allocator.dupe(u8, "");

        var transfer_buf: [4096]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        var chunk_buf: [8192]u8 = undefined;
        while (true) {
            const n = body_reader.readSliceShort(&chunk_buf) catch |err| switch (err) {
                error.ReadFailed => {
                    if (response.bodyErr()) |be| return mapHttpsError(be);
                    return error.ConnectionError;
                },
                else => |e| return e,
            };
            if (n == 0) break;
            try on_chunk(cb_ctx, chunk_buf[0..n]);
        }
        return resp;
    }

    /// Drop the shared client's idle TLS connections to one target, so the
    /// next request to it must dial (and handshake) again.
    fn discardIdleHttpsConnections(self: *Self, host: []const u8, port: u16) void {
        const io = self.connection_pool.io;
        self.https_mutex.lockUncancelable(io);
        defer self.https_mutex.unlock(io);

        const client = self.https_client orelse return;
        discardIdleConnections(client, host, port, .tls);
    }

    /// `req.url` flavour of `discardIdleHttpsConnections`; plain-HTTP targets
    /// are left alone (their pool is this struct's own `ConnectionPool`).
    fn discardIdleHttpsConnectionsFor(self: *Self, url: []const u8) void {
        var host_buf: [256]u8 = undefined;
        var path_buf: [4096]u8 = undefined;
        const target = parseTarget(url, &host_buf, &path_buf) catch return;
        if (!target.is_tls) return;
        self.discardIdleHttpsConnections(target.host, target.port);
    }

    /// Close every idle connection `client` holds for `host`/`port`/`protocol`.
    ///
    /// `std.http.Client` has no API for this — `deinit` also closes in-use
    /// connections and invalidates the pool — so the idle list is walked
    /// directly. Connections in `used` (another thread's in-flight request)
    /// are deliberately untouched. Tie the field names to the toolchain: a
    /// rename must break the build here, not silently stop pruning.
    fn discardIdleConnections(
        client: *std.http.Client,
        host: []const u8,
        port: u16,
        protocol: std.http.Client.Protocol,
    ) void {
        comptime {
            for ([_][]const u8{ "free", "free_len", "mutex" }) |field| {
                if (!@hasField(std.http.Client.ConnectionPool, field)) {
                    @compileError("std.http.Client.ConnectionPool." ++ field ++
                        " is gone; update HttpClient.discardIdleConnections");
                }
            }
            if (!@hasField(std.http.Client.Connection, "pool_node")) {
                @compileError("std.http.Connection.pool_node is gone; update HttpClient.discardIdleConnections");
            }
        }

        const io = client.io;
        const pool = &client.connection_pool;
        pool.mutex.lockUncancelable(io);
        defer pool.mutex.unlock(io);

        const wanted = std.Io.net.HostName{ .bytes = host };
        var node = pool.free.first;
        while (node) |current| {
            // `destroy` frees the connection, so advance first.
            node = current.next;
            const conn: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", current));
            if (conn.protocol != protocol or conn.port != port) continue;
            if (!conn.host().eql(wanted)) continue;
            pool.free.remove(current);
            pool.free_len -= 1;
            conn.destroy(io);
        }
    }

    fn mapHttpsError(err: anyerror) anyerror {
        const name = @errorName(err);
        if (std.mem.indexOf(u8, name, "Certificate") != null or
            std.mem.indexOf(u8, name, "Tls") != null or
            std.mem.eql(u8, name, "CertificateBundleLoadFailure"))
        {
            return error.TlsHandshakeFailed;
        }
        if (std.mem.eql(u8, name, "ConnectionRefused")) return error.ConnectionRefused;
        if (std.mem.eql(u8, name, "NetworkUnreachable")) return error.NetworkUnreachable;
        if (std.mem.indexOf(u8, name, "Host") != null or
            std.mem.indexOf(u8, name, "Name") != null or
            std.mem.eql(u8, name, "UnknownHostName"))
        {
            return error.DnsFailed;
        }
        if (std.mem.eql(u8, name, "ConnectionTimedOut") or std.mem.eql(u8, name, "Timeout")) {
            return error.Timeout;
        }
        return error.ConnectionError;
    }

    fn executeRequest(self: *Self, req: HttpRequest) !HttpResponse {
        var host_buf: [256]u8 = undefined;
        var path_buf: [4096]u8 = undefined;
        const target = try parseTarget(req.url, &host_buf, &path_buf);
        if (target.is_tls) return self.executeHttps(req);

        var conn = try self.connection_pool.acquire(target.host, target.port);
        // Whether this connection goes back to `idle` is a fact about the
        // request, not about the socket: `release` leaves a failed request's
        // socket in the pool, and the retry loop above then re-acquires it on
        // every attempt — one peer close poisons the slot for good. The errdefer
        // is the plain-HTTP mirror of the HTTPS path pruning its target's idle
        // connections between attempts.
        errdefer self.connection_pool.discard(conn);

        if (conn.stream) |stream| {
            var write_buf: [4096]u8 = undefined;
            var w = stream.writer(self.connection_pool.io, &write_buf);
            try writeRequestHeaders(&w, req.method, target.path, target.host, target.port, &req.headers, req.body);
            // Buffered writer: the request must reach the peer before we start
            // reading the response, otherwise both sides deadlock forever.
            try w.interface.flush();
            const response = try self.readResponse(stream);
            conn.request_count += 1;
            self.connection_pool.release(conn);
            return response;
        }

        return error.ConnectionError;
    }

    /// Wait up to `timeout_ms` for the socket to become readable so
    /// `request()` cannot block indefinitely against a peer that never
    /// responds. `timeout_ms == 0` disables the timeout.
    /// Blocking read (waitForReadable + posix.read). The streaming path must
    /// not use fiber-based sockread.readSome outside an async context — it
    /// hangs on local HTTP (non-TLS) connections.
    fn blockingRead(stream: std.Io.net.Stream, buf: []u8, timeout_ms: u64) !usize {
        try waitForReadable(stream.socket.handle, timeout_ms);
        return std.posix.read(stream.socket.handle, buf) catch return error.ConnectionError;
    }

    fn waitForReadable(fd: std.posix.socket_t, timeout_ms: u64) !void {
        if (timeout_ms == 0) return;
        var fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const capped: i32 = @intCast(@min(timeout_ms, std.math.maxInt(i32)));
        const n = std.posix.poll(&fds, capped) catch return error.Timeout;
        if (n == 0) return error.Timeout;
    }

    /// Serialize the request line, headers and body into `w`.
    ///
    /// Formatted straight into the writer's buffer: an `allocPrint` per header
    /// line put N+2 allocations on every request for bytes that were copied into
    /// the write buffer and freed immediately.
    fn writeRequestHeaders(
        w: anytype,
        method: []const u8,
        path: []const u8,
        host: []const u8,
        port: u16,
        headers: *const std.StringHashMap([]const u8),
        body: ?[]const u8,
    ) !void {
        w.interface.print("{s} {s} HTTP/1.1\r\n", .{ method, path }) catch return error.ConnectionError;

        var has_host = false;
        var has_content_length = false;
        var iter = headers.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "host")) has_host = true;
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "content-length")) has_content_length = true;
            w.interface.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch return error.ConnectionError;
        }

        if (!has_host) {
            if (port == 80 or port == 443) {
                w.interface.print("Host: {s}\r\n", .{host}) catch return error.ConnectionError;
            } else {
                w.interface.print("Host: {s}:{d}\r\n", .{ host, port }) catch return error.ConnectionError;
            }
        }

        if (!has_content_length) {
            const len = if (body) |b| b.len else 0;
            w.interface.print("Content-Length: {d}\r\n", .{len}) catch return error.ConnectionError;
        }

        w.interface.writeAll("\r\n") catch return error.ConnectionError;
        if (body) |b| {
            if (b.len > 0) w.interface.writeAll(b) catch return error.ConnectionError;
        }
    }

    test "writeRequestHeaders: exact request bytes, no allocation per header" {
        // The signature takes no allocator at all, so the N+2 `allocPrint` calls
        // that used to sit on every request cannot come back without failing to
        // compile. `w` only has to expose `interface`, so no socket is needed.
        const Capture = struct { interface: std.Io.Writer };
        var buf: [256]u8 = undefined;
        var capture = Capture{ .interface = std.Io.Writer.fixed(&buf) };

        var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
        defer headers.deinit();
        try headers.put("X-Test", "v");

        try writeRequestHeaders(&capture, "POST", "/echo?x=1", "example.com", 8080, &headers, "hello");
        try std.testing.expectEqualStrings(
            "POST /echo?x=1 HTTP/1.1\r\nX-Test: v\r\nHost: example.com:8080\r\nContent-Length: 5\r\n\r\nhello",
            capture.interface.buffered(),
        );
    }

    test "writeRequestHeaders: caller Host and Content-Length win, default port elided" {
        const Capture = struct { interface: std.Io.Writer };
        var buf: [256]u8 = undefined;
        var capture = Capture{ .interface = std.Io.Writer.fixed(&buf) };

        var headers = std.StringHashMap([]const u8).init(std.testing.allocator);
        defer headers.deinit();
        try headers.put("Host", "cdn.example");
        try headers.put("Content-Length", "0");

        try writeRequestHeaders(&capture, "GET", "/", "ignored.example", 80, &headers, "");
        const written = capture.interface.buffered();

        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "Host: "));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "Content-Length: "));
        try std.testing.expect(std.mem.indexOf(u8, written, "Host: cdn.example\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, written, "ignored.example") == null);
        try std.testing.expect(std.mem.indexOf(u8, written, "Content-Length: 0\r\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
    }

    fn readResponse(self: *Self, stream: std.Io.net.Stream) !HttpResponse {
        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();

        var buf: [8192]u8 = undefined;

        try waitForReadable(stream.socket.handle, self.timeout_ms);
        const n = std.posix.read(stream.socket.handle, &buf) catch return error.ConnectionError;
        if (n == 0) return error.ConnectionError;
        const raw = buf[0..n];

        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse;
        const head = raw[0..header_end];
        const body_start = header_end + 4;

        var line_it = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = line_it.next() orelse return error.InvalidResponse;
        // Example: HTTP/1.1 200 OK
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next() orelse return error.InvalidResponse; // http version
        const status_str = parts.next() orelse return error.InvalidResponse;
        resp.status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;

        var content_length: usize = 0;
        var chunked = false;
        while (line_it.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key_trim = std.mem.trim(u8, line[0..colon], " \t");
            const val_trim = std.mem.trim(u8, line[colon + 1 ..], " \t");

            const key = try self.allocator.dupe(u8, key_trim);
            errdefer self.allocator.free(key);
            const val = try self.allocator.dupe(u8, val_trim);
            errdefer self.allocator.free(val);
            try resp.headers.put(key, val);

            if (std.ascii.eqlIgnoreCase(key_trim, "content-length")) {
                content_length = std.fmt.parseInt(usize, val_trim, 10) catch 0;
            } else if (std.ascii.eqlIgnoreCase(key_trim, "transfer-encoding")) {
                if (containsIgnoreCaseAscii(val_trim, "chunked")) chunked = true;
            }
        }

        const initial_body = raw[body_start..];
        // A chunked body has no `Content-Length` to read against; without this
        // branch the caller got the raw framing back as the body. (The streaming
        // path has decoded it all along.)
        if (chunked) {
            resp.body = try self.readChunkedBody(stream, &buf, initial_body);
            return resp;
        }
        if (content_length == 0) {
            resp.body = try self.allocator.dupe(u8, initial_body);
            return resp;
        }

        var body_buf = try self.allocator.alloc(u8, content_length);
        var copied: usize = @min(initial_body.len, content_length);
        @memcpy(body_buf[0..copied], initial_body[0..copied]);

        while (copied < content_length) {
            try waitForReadable(stream.socket.handle, self.timeout_ms);
            const more = std.posix.read(stream.socket.handle, &buf) catch return error.ConnectionError;
            if (more == 0) break;
            const to_copy = @min(@as(usize, more), content_length - copied);
            @memcpy(body_buf[copied..][0..to_copy], buf[0..to_copy]);
            copied += to_copy;
        }

        if (copied != content_length) {
            self.allocator.free(body_buf);
            return error.IncompleteBody;
        }

        resp.body = body_buf;
        return resp;
    }

    /// Callback for streamed response body (decoded chunk payload, not raw TCP framing).
    pub const OnBodyChunk = *const fn (ctx: *anyopaque, chunk: []const u8) anyerror!void;

    /// Send HTTP request and stream the response body via `on_chunk` (no retry — streams are not idempotent).
    /// Returned `HttpResponse.body` is empty; status/headers are filled. Caller still owns `deinit`.
    pub fn requestStream(self: *Self, req: HttpRequest, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        if (self.closed) return error.HttpClientClosed;
        return self.executeRequestStream(req, cb_ctx, on_chunk);
    }

    fn executeRequestStream(self: *Self, req: HttpRequest, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        var host_buf: [256]u8 = undefined;
        var path_buf: [4096]u8 = undefined;
        const target = try parseTarget(req.url, &host_buf, &path_buf);
        if (target.is_tls) {
            return self.executeHttpsStream(req, cb_ctx, on_chunk);
        }

        var conn = try self.connection_pool.acquire(target.host, target.port);
        // Same rule as the buffering path: a stream that ended early (reader
        // error, `on_chunk` failing, truncated body) leaves the socket
        // mid-response, so it is closed rather than pooled.
        errdefer self.connection_pool.discard(conn);

        if (conn.stream) |stream| {
            var write_buf: [4096]u8 = undefined;
            var w = stream.writer(self.connection_pool.io, &write_buf);
            try writeRequestHeaders(&w, req.method, target.path, target.host, target.port, &req.headers, req.body);
            // Buffered writer: flush before reading, otherwise the peer waits
            // for a request that never leaves the buffer — deadlock (the
            // non-streaming path flushes too; this was the local-HTTP hang).
            try w.interface.flush();
            const response = try self.readResponseStreaming(stream, cb_ctx, on_chunk);
            conn.request_count += 1;
            self.connection_pool.release(conn);
            return response;
        }
        return error.ConnectionError;
    }

    fn readResponseStreaming(self: *Self, stream: std.Io.net.Stream, cb_ctx: *anyopaque, on_chunk: OnBodyChunk) !HttpResponse {
        var resp = HttpResponse.init(self.allocator);
        errdefer resp.deinit();

        var buf: [8192]u8 = undefined;

        const n = try blockingRead(stream, &buf, self.timeout_ms);
        if (n == 0) return error.ConnectionError;
        const raw = buf[0..n];

        const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidResponse;
        const head = raw[0..header_end];
        const body_start = header_end + 4;

        var line_it = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = line_it.next() orelse return error.InvalidResponse;
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next() orelse return error.InvalidResponse;
        const status_str = parts.next() orelse return error.InvalidResponse;
        resp.status_code = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidResponse;

        var content_length: ?usize = null;
        var chunked = false;
        while (line_it.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key_trim = std.mem.trim(u8, line[0..colon], " \t");
            const val_trim = std.mem.trim(u8, line[colon + 1 ..], " \t");

            const key = try self.allocator.dupe(u8, key_trim);
            errdefer self.allocator.free(key);
            const val = try self.allocator.dupe(u8, val_trim);
            errdefer self.allocator.free(val);
            try resp.headers.put(key, val);

            if (std.ascii.eqlIgnoreCase(key_trim, "content-length")) {
                content_length = std.fmt.parseInt(usize, val_trim, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(key_trim, "transfer-encoding")) {
                if (containsIgnoreCaseAscii(val_trim, "chunked")) chunked = true;
            }
        }

        resp.body = try self.allocator.dupe(u8, "");
        const initial = raw[body_start..];

        if (chunked) {
            try streamChunkedBody(stream, &buf, initial, self.timeout_ms, cb_ctx, on_chunk);
        } else if (content_length) |cl| {
            try streamContentLengthBody(stream, &buf, initial, cl, self.timeout_ms, cb_ctx, on_chunk);
        } else {
            try streamUntilEofBody(stream, &buf, initial, self.timeout_ms, cb_ctx, on_chunk);
        }
        return resp;
    }

    /// Buffer a chunked response body into contiguous bytes, reusing the same
    /// decoder the streaming path uses (so there is one chunked implementation,
    /// not one per entry point).
    fn readChunkedBody(self: *Self, stream: std.Io.net.Stream, buf: []u8, initial: []const u8) ![]u8 {
        const Collector = struct {
            allocator: std.mem.Allocator,
            out: std.ArrayList(u8),

            fn onChunk(raw: *anyopaque, chunk: []const u8) anyerror!void {
                const sink: *@This() = @ptrCast(@alignCast(raw));
                try sink.out.appendSlice(sink.allocator, chunk);
            }
        };
        var collector = Collector{ .allocator = self.allocator, .out = .empty };
        errdefer collector.out.deinit(self.allocator);
        try streamChunkedBody(stream, buf, initial, self.timeout_ms, &collector, Collector.onChunk);
        return try collector.out.toOwnedSlice(self.allocator);
    }

    /// Decode a complete chunked-transfer buffer into contiguous body (unit-test helper).
    pub fn decodeChunkedBuffer(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < data.len) {
            const line_end = std.mem.indexOfPos(u8, data, i, "\r\n") orelse return error.InvalidChunked;
            const size = std.fmt.parseInt(usize, data[i..line_end], 16) catch return error.InvalidChunked;
            i = line_end + 2;
            if (size == 0) break;
            if (i + size + 2 > data.len) return error.IncompleteChunked;
            try out.appendSlice(allocator, data[i .. i + size]);
            i += size + 2;
        }
        return try out.toOwnedSlice(allocator);
    }

    /// GET request without a body.
    pub fn get(self: *Self, url: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "GET", url);
        defer req.deinit();
        return self.request(req);
    }

    /// POST request with a JSON body.
    pub fn post(self: *Self, url: []const u8, body: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "POST", url);
        defer req.deinit();
        try req.setBody(body);
        try req.setHeader("Content-Type", "application/json");
        return self.request(req);
    }

    /// PUT request with a JSON body.
    pub fn put(self: *Self, url: []const u8, body: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "PUT", url);
        defer req.deinit();
        try req.setBody(body);
        try req.setHeader("Content-Type", "application/json");
        return self.request(req);
    }

    /// DELETE request without a body.
    pub fn delete(self: *Self, url: []const u8) !HttpResponse {
        var req = HttpRequest.init(self.allocator, "DELETE", url);
        defer req.deinit();
        return self.request(req);
    }
};

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn streamContentLengthBody(
    stream: std.Io.net.Stream,
    buf: []u8,
    initial: []const u8,
    content_length: usize,
    timeout_ms: u64,
    cb_ctx: *anyopaque,
    on_chunk: HttpClient.OnBodyChunk,
) !void {
    var copied: usize = 0;
    if (initial.len > 0 and content_length > 0) {
        const n = @min(initial.len, content_length);
        if (n > 0) try on_chunk(cb_ctx, initial[0..n]);
        copied = n;
    }
    while (copied < content_length) {
        const more = try HttpClient.blockingRead(stream, buf, timeout_ms);
        if (more == 0) return error.IncompleteBody;
        const to_copy = @min(@as(usize, more), content_length - copied);
        try on_chunk(cb_ctx, buf[0..to_copy]);
        copied += to_copy;
    }
}

fn streamUntilEofBody(
    stream: std.Io.net.Stream,
    buf: []u8,
    initial: []const u8,
    timeout_ms: u64,
    cb_ctx: *anyopaque,
    on_chunk: HttpClient.OnBodyChunk,
) !void {
    if (initial.len > 0) try on_chunk(cb_ctx, initial);
    while (true) {
        const more = try HttpClient.blockingRead(stream, buf, timeout_ms);
        if (more == 0) break;
        try on_chunk(cb_ctx, buf[0..more]);
    }
}

/// True when a chunk-size line (`<hex>[;extension]`, up to and including its
/// line terminator) starts with at least one hex digit and carries nothing but
/// hex digits before the extension.
fn isHexSizeLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            ';', '\r', '\n' => break,
            else => return false,
        }
    }
    return i > 0;
}

/// Stream a `Transfer-Encoding: chunked` body: framing is decoded with
/// `std.http.ChunkParser` and every payload slice is handed to `on_chunk`
/// straight out of the read buffer.
///
/// Only the current chunk-size line is copied aside (a bounded stack buffer),
/// so the body is walked once and memory stays constant. The version this
/// replaces kept all unconsumed bytes in a growing list and moved the remainder
/// to the front after every chunk — quadratic copying (and a full rescan for the
/// CRLF) once a read window carried many small chunks.
///
/// On the terminal chunk it also consumes the CRLF that closes the trailer
/// section, so a pooled connection is left byte-aligned for the next request.
fn streamChunkedBody(
    stream: std.Io.net.Stream,
    buf: []u8,
    initial: []const u8,
    timeout_ms: u64,
    cb_ctx: *anyopaque,
    on_chunk: HttpClient.OnBodyChunk,
) !void {
    var pending: []const u8 = initial;
    // "<hex>[;extension]\r\n": real servers keep this to a few dozen bytes, and
    // a longer one is malformed framing rather than something to buffer.
    var size_line: [64]u8 = undefined;

    while (true) {
        var line_len: usize = 0;
        while (std.mem.indexOfScalar(u8, size_line[0..line_len], '\n') == null) {
            if (line_len == size_line.len) return error.InvalidChunked;
            try fillFrom(stream, buf, &pending, size_line[line_len..][0..1], timeout_ms);
            line_len += 1;
        }
        // A fresh parser per chunk: `ChunkParser` accumulates `chunk_len` across
        // `feed` calls, so one instance is only good for a single size line.
        // It also accepts `A`…`Z`/`a`…`z` as "digits" (any value: `'z'` counts as
        // 35), so the line is checked for being hex at all first — the decoder
        // this replaced got that from `std.fmt.parseInt`.
        if (!isHexSizeLine(size_line[0..line_len])) return error.InvalidChunked;
        var parser: std.http.ChunkParser = .init;
        _ = parser.feed(size_line[0..line_len]);
        if (parser.state != .data) return error.InvalidChunked;

        if (parser.chunk_len == 0) {
            // End of body. Trailers are not supported (they never were), so the
            // only well-formed continuation is the empty one; consuming it keeps
            // the connection usable for the next request instead of leaving
            // stray CRLF bytes for the next response parser to trip over.
            var trailer_end: [2]u8 = undefined;
            try fillFrom(stream, buf, &pending, &trailer_end, timeout_ms);
            if (!std.mem.eql(u8, &trailer_end, "\r\n")) return error.InvalidChunked;
            return;
        }

        var left = parser.chunk_len;
        while (left > 0) {
            if (pending.len == 0) {
                const more = try HttpClient.blockingRead(stream, buf, timeout_ms);
                if (more == 0) return error.IncompleteChunked;
                pending = buf[0..more];
            }
            const take: usize = @intCast(@min(left, @as(u64, pending.len)));
            try on_chunk(cb_ctx, pending[0..take]);
            pending = pending[take..];
            left -= @intCast(take);
        }

        var crlf: [2]u8 = undefined;
        try fillFrom(stream, buf, &pending, &crlf, timeout_ms);
        if (!std.mem.eql(u8, &crlf, "\r\n")) return error.InvalidChunked;
    }
}

/// Move exactly `dest.len` bytes from `pending` into `dest`, refilling `pending`
/// from the socket when it runs dry. Bytes past `dest` stay in `pending`, so the
/// caller keeps its place in the stream and nothing is copied twice.
fn fillFrom(
    stream: std.Io.net.Stream,
    buf: []u8,
    pending: *[]const u8,
    dest: []u8,
    timeout_ms: u64,
) !void {
    var got: usize = 0;
    while (got < dest.len) {
        if (pending.len == 0) {
            const more = try HttpClient.blockingRead(stream, buf, timeout_ms);
            if (more == 0) return error.IncompleteChunked;
            pending.* = buf[0..more];
        }
        const take = @min(pending.len, dest.len - got);
        @memcpy(dest[got..][0..take], pending.*[0..take]);
        got += take;
        pending.* = pending.*[take..];
    }
}

test "HttpClient decodeChunkedBuffer" {
    const a = std.testing.allocator;
    const raw = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n";
    const body = try HttpClient.decodeChunkedBuffer(a, raw);
    defer a.free(body);
    try std.testing.expectEqualStrings("hello world", body);
}

test "HttpClient parseTarget https defaults to 443" {
    var host_buf: [256]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const t = try HttpClient.parseTarget("https://api.example.com/v1/chat", &host_buf, &path_buf);
    try std.testing.expect(t.is_tls);
    try std.testing.expectEqual(@as(u16, 443), t.port);
    try std.testing.expectEqualStrings("api.example.com", t.host);
    try std.testing.expectEqualStrings("/v1/chat", t.path);
}

test "HttpClient parseTarget http path and query" {
    var host_buf: [256]u8 = undefined;
    var path_buf: [4096]u8 = undefined;
    const t = try HttpClient.parseTarget("http://api.local:8080/v1/chat?x=1", &host_buf, &path_buf);
    try std.testing.expectEqualStrings("api.local", t.host);
    try std.testing.expectEqual(@as(u16, 8080), t.port);
    try std.testing.expectEqualStrings("/v1/chat?x=1", t.path);
}

test "HttpClient RetryPolicy calculateDelay" {
    const policy = HttpClient.RetryPolicy.default();
    try std.testing.expectEqual(@as(u64, 100), policy.calculateDelay(0));
    try std.testing.expectEqual(@as(u64, 200), policy.calculateDelay(1));
    try std.testing.expectEqual(@as(u64, 400), policy.calculateDelay(2));
}

test "HttpClient ConnectionPool acquire and release" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // Real loopback listener so acquire() gets an actual connection.
    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 2);
    defer pool.deinit();

    // Acquire new connection.
    const conn = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqualStrings("127.0.0.1", conn.host);
    try std.testing.expectEqual(port, conn.port);

    // Release back to pool.
    pool.release(conn);

    // Reacquire should reuse the idle connection.
    const conn2 = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqualStrings("127.0.0.1", conn2.host);
    try std.testing.expectEqual(port, conn2.port);
    try std.testing.expect(conn2.stream.?.socket.handle == conn.stream.?.socket.handle);

    pool.release(conn2);
}

test "HttpClient ConnectionPool exhaustion" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 1);
    defer pool.deinit();

    const conn = try pool.acquire("127.0.0.1", port);
    const result = pool.acquire("127.0.0.1", port);
    try std.testing.expectError(error.PoolExhausted, result);

    pool.release(conn);
}

// `discard` is `release`'s counterpart for a request that failed: the socket is
// closed and dropped from both lists. Being on neither list is what makes the
// teardown below safe — `std.testing.allocator` fails the run if the host string
// is freed twice or not at all.
test "HttpClient ConnectionPool discard drops the connection instead of pooling it" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 1);
    defer pool.deinit();

    const conn = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqual(@as(usize, 1), pool.active_connections.items.len);

    pool.discard(conn);
    try std.testing.expectEqual(@as(usize, 0), pool.active_connections.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.idle_connections.items.len);

    // The slot is free again, so the pool is still usable after a discard.
    const conn2 = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqual(@as(usize, 1), pool.active_connections.items.len);
    pool.release(conn2);
    try std.testing.expectEqual(@as(usize, 1), pool.idle_connections.items.len);
}

/// The two `ConnectionPool` operations that give a connection back, in the shape
/// the cancelation tests below drive them.
const PoolReturnOp = *const fn (*HttpClient.ConnectionPool, HttpClient.ConnectionPool.Connection) void;

/// Call `op(pool, conn)` on a concurrent task whose wait on the pool mutex is
/// canceled, and return once that task has returned.
///
/// The test thread holds the mutex throughout, and the task is gated behind pure
/// spinning, so a cancel request placed while it is gated is still pending when
/// it reaches the lock wait: the cancelation point is the lock wait under test,
/// never an earlier operation of the task.
fn cancelWhilePoolLocked(
    pool: *HttpClient.ConnectionPool,
    conn: HttpClient.ConnectionPool.Connection,
    op: PoolReturnOp,
) !void {
    const io = pool.io;
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var returned = std.atomic.Value(bool).init(false);

        fn run(
            p: *HttpClient.ConnectionPool,
            c: HttpClient.ConnectionPool.Connection,
            f: PoolReturnOp,
        ) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            f(p, c);
            returned.store(true, .release);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);
    Gate.returned.store(false, .monotonic);

    try pool.mutex.lock(io);
    var op_fut = try io.concurrent(Gate.run, .{ pool, conn, op });
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &op_fut });
    // Give the request time to land on the task's thread while it is still gated.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    // The task is now inside `op`: parked on the mutex (it swaps the state to
    // `contended` on its way into the wait) or already gone.
    while (pool.mutex.state.load(.monotonic) != .contended and !Gate.returned.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    pool.mutex.unlock(io);

    cancel_fut.await(io);
    op_fut.await(io);
    try std.testing.expect(Gate.returned.load(.acquire));
}

// Regression: `release` used to return early when its (cancelable) mutex lock
// came back `error.Canceled`. The connection was then left on
// `active_connections` for good — never idle, never closed, with
// `max_connections` still counting its slot — so every canceled release shrank
// the pool by one until it could not hand anything out, while nothing was in
// flight. Whatever `release` decides about a canceled wait, the connection must
// not fall out of the pool's books.
test "HttpClient ConnectionPool release keeps a connection whose lock wait is canceled" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 1);
    defer pool.deinit();

    const conn = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqual(@as(usize, 1), pool.active_connections.items.len);

    try cancelWhilePoolLocked(&pool, conn, HttpClient.ConnectionPool.release);

    // Accounted for, and in the branch `release` documents for a live
    // connection (see its comment): idle, off the active list. The other
    // defensible answer — treat the cancelation as "this connection is gone",
    // close it and free it — would satisfy "not on the active list" with
    // `idle == 0`; what is not fine is `active == 1`, the lost slot.
    try std.testing.expectEqual(@as(usize, 0), pool.active_connections.items.len);
    try std.testing.expectEqual(@as(usize, 1), pool.idle_connections.items.len);

    // Not merely counted: the next `acquire` gets that same socket back, and the
    // `max_connections = 1` slot is usable again.
    const again = try pool.acquire("127.0.0.1", port);
    try std.testing.expectEqual(conn.stream.?.socket.handle, again.stream.?.socket.handle);
    pool.release(again);
}

// The same defect in `discard`, whose caller has already written the socket off:
// a canceled lock wait left a dead socket on `active_connections` — never
// closed, `host` never freed, and the slot never released.
test "HttpClient ConnectionPool discard drops a connection whose lock wait is canceled" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 1);
    defer pool.deinit();

    const conn = try pool.acquire("127.0.0.1", port);
    try cancelWhilePoolLocked(&pool, conn, HttpClient.ConnectionPool.discard);

    // On neither list, so the slot is free again and the pool is still usable.
    try std.testing.expectEqual(@as(usize, 0), pool.active_connections.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.idle_connections.items.len);
    const conn2 = try pool.acquire("127.0.0.1", port);
    pool.release(conn2);
}

// Regression: `acquire` took the connection out of `idle_connections` and only
// then appended it to `active_connections`, so an OOM in that append lost it
// outright — on neither list, socket never closed, `host` never freed, while
// `max_connections` kept counting its slot. Nothing can hand that slot back:
// the pool simply got smaller, and `std.testing.allocator` reports the missing
// free at the end of the test.
test "HttpClient ConnectionPool acquire keeps an idle connection when the active append fails" {
    const backing = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var failing = std.testing.FailingAllocator.init(backing, .{});
    const allocator = failing.allocator();

    // Two listeners: `acquire` matches on host *and* port, so the second port is
    // what lets connections be created while the first port's sit idle.
    const first_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var first = try first_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer first.deinit(std.testing.io);
    const first_port = first.socket.address.getPort();

    const second_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var second = try second_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer second.deinit(std.testing.io);
    const second_port = second.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 8);
    defer pool.deinit();

    // Fill `active_connections` to exactly its capacity — read from the list
    // rather than assumed, since it comes from ArrayList's growth policy — then
    // hand those connections back. The append under test has to *grow* the list
    // to be fallible at all, and after a `swapRemove` there is always room
    // unless the list is right at capacity.
    var held = std.ArrayList(HttpClient.ConnectionPool.Connection).empty;
    defer held.deinit(backing);
    try held.append(backing, try pool.acquire("127.0.0.1", first_port));
    while (pool.active_connections.items.len < pool.active_connections.capacity) {
        try held.append(backing, try pool.acquire("127.0.0.1", first_port));
    }
    const capacity = pool.active_connections.capacity;
    for (held.items) |conn| pool.release(conn);
    try std.testing.expectEqual(capacity, pool.idle_connections.items.len);

    // Refill `active_connections` — from the other port, so the idle ones stay
    // idle — to the same length: the next idle-path append is at capacity and
    // must allocate.
    for (0..capacity) |_| {
        _ = try pool.acquire("127.0.0.1", second_port);
    }
    try std.testing.expectEqual(capacity, pool.active_connections.items.len);
    try std.testing.expectEqual(capacity, pool.idle_connections.items.len);

    // The next allocation this pool makes is the one inside that append.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, pool.acquire("127.0.0.1", first_port));
    failing.fail_index = std.math.maxInt(usize);

    // The failed `acquire` left the pool as it was: the connection is still
    // idle — reachable by the next caller — and not stranded between the lists.
    try std.testing.expectEqual(capacity, pool.idle_connections.items.len);
    try std.testing.expectEqual(capacity, pool.active_connections.items.len);
}

// The mirror of the test above, on the way back: `release` takes the connection
// off `active_connections` and appends it to `idle_connections` after, so when
// that append fails the connection used to disappear from both lists — socket
// left open, `host` never freed, and nobody left to do either. `release` cannot
// hand the connection back to its caller, so the only honest end is its own
// dead-connection branch: close it and free it. The pool's counters look the
// same either way; the red/green signal is the leak check.
test "HttpClient ConnectionPool release closes a live connection when pooling it fails" {
    const backing = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var failing = std.testing.FailingAllocator.init(backing, .{});
    const allocator = failing.allocator();

    const first_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var first = try first_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer first.deinit(std.testing.io);
    const first_port = first.socket.address.getPort();

    const second_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var second = try second_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer second.deinit(std.testing.io);
    const second_port = second.socket.address.getPort();

    var pool = HttpClient.ConnectionPool.init(allocator, std.testing.io, 8);
    defer pool.deinit();

    // Fill `active_connections` to its capacity, then hand all of it back. Both
    // lists grow the same way from empty, so `idle_connections` ends up exactly
    // at *its* capacity and the next append has to grow — which is what makes it
    // fallible at all.
    var held = std.ArrayList(HttpClient.ConnectionPool.Connection).empty;
    defer held.deinit(backing);
    try held.append(backing, try pool.acquire("127.0.0.1", first_port));
    while (pool.active_connections.items.len < pool.active_connections.capacity) {
        try held.append(backing, try pool.acquire("127.0.0.1", first_port));
    }
    for (held.items) |conn| pool.release(conn);
    const pooled = pool.idle_connections.items.len;
    try std.testing.expectEqual(pool.idle_connections.capacity, pooled);

    // One live connection to give back — from the other port, so it cannot come
    // out of the idle list — and the next allocation is the append's.
    const conn = try pool.acquire("127.0.0.1", second_port);
    try std.testing.expect(conn.isAlive());
    failing.fail_index = failing.alloc_index;
    pool.release(conn);
    failing.fail_index = std.math.maxInt(usize);

    // Not pooled, so it is gone rather than stranded: off the active list, the
    // pool unchanged, and — the part the counters cannot show — the socket
    // closed and its `host` freed, which is what `std.testing.allocator` checks
    // when this test ends.
    try std.testing.expectEqual(@as(usize, 0), pool.active_connections.items.len);
    try std.testing.expectEqual(pooled, pool.idle_connections.items.len);
}

test "HttpClient HttpRequest and HttpResponse" {
    const allocator = std.testing.allocator;

    var req = HttpClient.HttpRequest.init(allocator, "POST", "http://example.com/api");
    defer req.deinit();
    try req.setHeader("Content-Type", "application/json");
    try req.setBody("{\"id\":1}");

    try std.testing.expectEqualStrings("application/json", req.headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("{\"id\":1}", req.body.?);

    var res = HttpClient.HttpResponse.init(allocator);
    defer res.deinit();
    res.status_code = 201;
    try std.testing.expect(res.isSuccess());
}

test "HttpClient live request against loopback listener" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    // Serve one request: read until end of headers, then reply and close.
    // The socket read timeout keeps the test bounded if the request never
    // arrives (regression guard for the missing flush bug).
    const ServerCtx = struct {
        server: *std.Io.net.Server,
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);

            var total: usize = 0;
            var seen: [4096]u8 = undefined;
            while (total < seen.len) {
                // Raw reads keep this thread independent of the io scheduler
                // (spawned-thread io reads can stall on some Io backends).
                HttpClient.waitForReadable(accepted.socket.handle, 3000) catch break;
                const n = std.posix.read(accepted.socket.handle, seen[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, seen[0..total], "\r\n\r\n") != null) break;
            }

            const resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
            _ = std.posix.system.write(accepted.socket.handle, resp.ptr, resp.len);
        }
    };

    var server_ctx = ServerCtx{ .server = &server };
    const th = try std.Thread.spawn(.{}, ServerCtx.run, .{&server_ctx});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/echo", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 2, 3000);
    defer client.deinit();
    var req = HttpClient.HttpRequest.init(allocator, "GET", url);
    defer req.deinit();

    var resp = try client.request(req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("OK", resp.body);
}

test "HttpClient request times out against a stalled peer" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try server_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();

    // Accept, read the request, then never send a response (stalled peer).
    // The thread only exits when the client gives up and closes the socket.
    const StallCtx = struct {
        server: *std.Io.net.Server,
        fn run(ctx: *@This()) void {
            const accepted = ctx.server.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);
            var total: usize = 0;
            var seen: [4096]u8 = undefined;
            while (total < seen.len) {
                HttpClient.waitForReadable(accepted.socket.handle, 3000) catch break;
                const n = std.posix.read(accepted.socket.handle, seen[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, seen[0..total], "\r\n\r\n") != null) break;
            }
            var tail: [512]u8 = undefined;
            while (true) {
                const n = std.posix.read(accepted.socket.handle, &tail) catch break;
                if (n == 0) break;
            }
        }
    };

    var stall_ctx = StallCtx{ .server = &server };
    const th = try std.Thread.spawn(.{}, StallCtx.run, .{&stall_ctx});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/never", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 2, 400);
    defer client.deinit();
    var req = HttpClient.HttpRequest.init(allocator, "GET", url);
    defer req.deinit();

    const err = client.request(req) catch |e| e;
    try std.testing.expectEqual(error.Timeout, err);
}

// ── request framing / chunked decoding ─────────────────────────────────────

/// Loopback server for the framing tests: writes `payload` verbatim on every
/// accepted connection, records the request bytes in `seen`, then closes.
///
/// It stops once the listener has been quiet briefly, so a failing test cannot
/// leave this thread parked in `accept` and hang `join`.
const CannedServer = struct {
    listener: *std.Io.net.Server,
    payload: []const u8,
    seen: []u8,
    seen_len: usize = 0,

    fn run(ctx: *@This()) void {
        var served: usize = 0;
        while (true) {
            // The first accept waits for the client; afterwards only a short
            // grace period, so a retry is still served but an idle test ends.
            const wait_ms: u64 = if (served == 0) 5000 else 300;
            HttpClient.waitForReadable(ctx.listener.socket.handle, wait_ms) catch return;
            const accepted = ctx.listener.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);
            served += 1;
            ctx.drainRequest(accepted);
            writeRawAll(accepted.socket.handle, ctx.payload);
        }
    }

    /// Read one request: the head, plus the body its `Content-Length` promises.
    fn drainRequest(ctx: *@This(), accepted: std.Io.net.Stream) void {
        var total: usize = 0;
        var body_len: ?usize = null;
        while (total < ctx.seen.len) {
            HttpClient.waitForReadable(accepted.socket.handle, 3000) catch break;
            const n = std.posix.read(accepted.socket.handle, ctx.seen[total..]) catch break;
            if (n == 0) break;
            total += n;
            const head_end = std.mem.indexOf(u8, ctx.seen[0..total], "\r\n\r\n") orelse continue;
            if (body_len == null) {
                body_len = if (headerValue(ctx.seen[0..head_end], "content-length")) |v|
                    std.fmt.parseInt(usize, v, 10) catch 0
                else
                    0;
            }
            if (total >= head_end + 4 + body_len.?) break;
        }
        ctx.seen_len = total;
    }
};

/// Case-insensitive value of `name` inside a raw request head.
fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

/// Raw syscall writes only: the io scheduler is shared with the test thread and
/// an io-path write from a helper thread can stall (see the WS tests in
/// `api/Server.zig`).
fn writeRawAll(fd: std.posix.socket_t, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (std.posix.errno(rc) != .SUCCESS) return;
        const n: usize = @intCast(rc);
        if (n == 0) return;
        sent += n;
    }
}

/// Build a chunked-transfer response for `payload`: `count` chunks of `size`
/// bytes each (from `payload`), then the terminal chunk.
fn chunkedResponse(
    allocator: std.mem.Allocator,
    payload: []const u8,
    count: usize,
    size: usize,
) ![]u8 {
    var wire: std.ArrayList(u8) = .empty;
    errdefer wire.deinit(allocator);
    try wire.appendSlice(allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
    for (0..count) |c| {
        var size_line: [16]u8 = undefined;
        const head = try std.fmt.bufPrint(&size_line, "{x}\r\n", .{size});
        try wire.appendSlice(allocator, head);
        try wire.appendSlice(allocator, payload[c * size ..][0..size]);
        try wire.appendSlice(allocator, "\r\n");
    }
    try wire.appendSlice(allocator, "0\r\n\r\n");
    return try wire.toOwnedSlice(allocator);
}

test "HttpClient sends the exact request framing over the wire" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    const seen = try allocator.alloc(u8, 4096);
    defer allocator.free(seen);
    var server = CannedServer{
        .listener = &listener,
        .payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK",
        .seen = seen,
    };
    const th = try std.Thread.spawn(.{}, CannedServer.run, .{&server});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/echo?x=1", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 2, 3000);
    defer client.deinit();
    var req = HttpClient.HttpRequest.init(allocator, "POST", url);
    defer req.deinit();
    try req.setHeader("Content-Type", "text/plain");
    try req.setHeader("X-Test", "v");
    try req.setBody("hello");

    var resp = try client.request(req);
    defer resp.deinit();
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("OK", resp.body);

    const request = seen[0..server.seen_len];
    const head_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.TestUnexpectedResult;
    const head = request[0..head_end];
    try std.testing.expectEqualStrings("hello", request[head_end + 4 ..]);

    var host_line_buf: [64]u8 = undefined;
    const host_line = try std.fmt.bufPrint(&host_line_buf, "Host: 127.0.0.1:{d}", .{port});
    // Header order out of a StringHashMap is not defined, so compare as a set —
    // but count every line, so a duplicate (`Content-Length` written twice, the
    // shape writeResponse guards against on the server side) still fails.
    const expected = [_][]const u8{
        "Content-Type: text/plain",
        "X-Test: v",
        host_line,
        "Content-Length: 5",
    };
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    try std.testing.expectEqualStrings("POST /echo?x=1 HTTP/1.1", lines.next() orelse "");
    var line_count: usize = 0;
    headers: while (lines.next()) |line| {
        line_count += 1;
        for (expected) |want| {
            if (std.mem.eql(u8, line, want)) continue :headers;
        }
        std.debug.print("unexpected request line: '{s}'\n", .{line});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(expected.len, line_count);
}

test "HttpClient streams a 64-chunk body and decodes it identically when buffered" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const chunk_count = 64;
    const chunk_size = 8 * 1024;
    const expected = try allocator.alloc(u8, chunk_count * chunk_size);
    defer allocator.free(expected);
    for (expected, 0..) |*b, i| b.* = @intCast(i % 251);
    const wire = try chunkedResponse(allocator, expected, chunk_count, chunk_size);
    defer allocator.free(wire);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    const seen = try allocator.alloc(u8, 1024);
    defer allocator.free(seen);
    var server = CannedServer{ .listener = &listener, .payload = wire, .seen = seen };
    const th = try std.Thread.spawn(.{}, CannedServer.run, .{&server});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/big", .{port});

    const Sink = struct {
        allocator: std.mem.Allocator,
        data: std.ArrayList(u8) = .empty,
        calls: usize = 0,

        fn onChunk(raw: *anyopaque, chunk: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try self.data.appendSlice(self.allocator, chunk);
        }
    };

    {
        // Streaming entry point (`requestStream` → the chunked decoder).
        var sink = Sink{ .allocator = allocator };
        defer sink.data.deinit(allocator);
        var client = HttpClient.init(allocator, std.testing.io, 2, 5000);
        defer client.deinit();
        var req = HttpClient.HttpRequest.init(allocator, "GET", url);
        defer req.deinit();

        var resp = try client.requestStream(req, &sink, Sink.onChunk);
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expect(sink.calls >= 1);
        try std.testing.expectEqualSlices(u8, expected, sink.data.items);
    }
    {
        // Buffering entry point: a chunked reply must decode to the same body
        // rather than come back as raw framing. Fresh client: the peer closed
        // the connection after the first response.
        var client = HttpClient.init(allocator, std.testing.io, 2, 5000);
        defer client.deinit();
        var req = HttpClient.HttpRequest.init(allocator, "GET", url);
        defer req.deinit();

        var resp = try client.request(req);
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expectEqualSlices(u8, expected, resp.body);
    }
}

test "HttpClient decodes thousands of tiny chunks sharing one read window" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // 16384 × 1 byte, 6 wire bytes per chunk: a single 8 KiB read carries >1000
    // chunk headers. This is the shape the previous decoder handled by copying
    // (and rescanning) the whole unconsumed remainder once per chunk.
    const chunk_count = 16 * 1024;
    const expected = try allocator.alloc(u8, chunk_count);
    defer allocator.free(expected);
    for (expected, 0..) |*b, i| b.* = @intCast(i % 251);
    const wire = try chunkedResponse(allocator, expected, chunk_count, 1);
    defer allocator.free(wire);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    const seen = try allocator.alloc(u8, 1024);
    defer allocator.free(seen);
    var server = CannedServer{ .listener = &listener, .payload = wire, .seen = seen };
    const th = try std.Thread.spawn(.{}, CannedServer.run, .{&server});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/tiny", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 2, 5000);
    defer client.deinit();
    var req = HttpClient.HttpRequest.init(allocator, "GET", url);
    defer req.deinit();

    var resp = try client.request(req);
    defer resp.deinit();
    try std.testing.expectEqualSlices(u8, expected, resp.body);
}

test "HttpClient chunked decoder rejects malformed framing" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const cases = [_]struct { payload: []const u8, expected: anyerror }{
        // Not a hex size line.
        .{ .payload = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nzz\r\nab\r\n0\r\n\r\n", .expected = error.InvalidChunked },
        // Chunk data shorter than the declared size.
        .{ .payload = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nab", .expected = error.IncompleteChunked },
        // Missing the CRLF that closes the chunk.
        .{ .payload = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nabXX0\r\n\r\n", .expected = error.InvalidChunked },
        // Truncated trailer section.
        .{ .payload = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nab\r\n0\r\n", .expected = error.IncompleteChunked },
    };

    for (cases) |case| {
        const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var listener = try addr.listen(std.testing.io, .{ .reuse_address = true });
        defer listener.deinit(std.testing.io);
        const port = listener.socket.address.getPort();

        const seen = try allocator.alloc(u8, 1024);
        defer allocator.free(seen);
        var server = CannedServer{ .listener = &listener, .payload = case.payload, .seen = seen };
        const th = try std.Thread.spawn(.{}, CannedServer.run, .{&server});
        defer th.join();

        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/bad", .{port});

        const Sink = struct {
            fn onChunk(_: *anyopaque, _: []const u8) anyerror!void {}
        };
        var client = HttpClient.init(allocator, std.testing.io, 1, 2000);
        defer client.deinit();
        // One retry is enough to see the same error; more would just slow it down.
        client.retry_policy.max_retries = 1;
        var req = HttpClient.HttpRequest.init(allocator, "GET", url);
        defer req.deinit();

        const result = client.requestStream(req, undefined, Sink.onChunk);
        try std.testing.expectError(case.expected, result);
    }
}

// ── Shared `std.http.Client` / TLS connection reuse ──────────────────────────
//
// The HTTPS path keeps one `std.http.Client` alive for the lifetime of the
// `HttpClient` (`HttpClient.https_client`) instead of building one per request.
// Three things follow:
//
//   * reusing the client is what makes `keep_alive` do anything — a per-request
//     client has nothing to reuse the connection in (test: "builds one
//     std.http.Client for the HTTPS path", via the creation counter);
//   * the client caches the system CA bundle (`ca_bundle`), so it is scanned
//     once rather than per request. Not locally testable: it only happens on a
//     real TLS request;
//   * it also caches the clock certificate expiry is checked against
//     (`Client.now`), which is what makes a long-lived client dangerous —
//     bounded, and tested, by `https_clock_max_skew_seconds` (test: "re-arms the
//     resident HTTPS client clock when it is stale").
//
// The tests below drive `std.http.Client` over *plain* loopback HTTP for the
// pool mechanics: `Request.deinit` → `ConnectionPool.release` is shared by both
// protocols, so the pool behaviour here is the behaviour the TLS path gets. A
// real TLS handshake cannot be exercised on loopback (self-signed peer, no
// system trust), so TLS-specific reuse is explicitly *not* covered — see the
// note on `HttpClient.httpsClient`.

/// Loopback server for the pool experiments: answers every request on a
/// connection with `payload` and leaves the connection open (HTTP/1.1
/// keep-alive). With `abort_after_reply` it closes the socket right after
/// replying — what an idle timeout (or a crashed peer) does to a connection
/// the client still has in its pool.
const PoolProbeServer = struct {
    listener: *std.Io.net.Server,
    payload: []const u8,
    abort_after_reply: bool = false,
    /// How long the listener keeps accepting after its first connection. Tests
    /// whose client has to dial a *second* connection need this to outlive the
    /// retry backoff (the default is sized for tests that never re-dial).
    accept_grace_ms: u64 = 300,

    fn run(ctx: *@This()) void {
        var first = true;
        while (true) {
            // The first accept waits for the client; afterwards only a short
            // grace period, so the test ends instead of hanging on join.
            const wait_ms: u64 = if (first) 5000 else ctx.accept_grace_ms;
            first = false;
            HttpClient.waitForReadable(ctx.listener.socket.handle, wait_ms) catch return;
            const accepted = ctx.listener.accept(std.testing.io) catch return;

            while (readProbeRequest(accepted)) {
                writeRawAll(accepted.socket.handle, ctx.payload);
                if (ctx.abort_after_reply) break;
            }
            accepted.close(std.testing.io);
        }
    }
};

/// Read one request head; false when the peer closed instead of sending one.
fn readProbeRequest(accepted: std.Io.net.Stream) bool {
    var total: usize = 0;
    var buf: [1024]u8 = undefined;
    while (total < buf.len) {
        HttpClient.waitForReadable(accepted.socket.handle, 1000) catch return false;
        const n = std.posix.read(accepted.socket.handle, buf[total..]) catch return false;
        if (n == 0) return false;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) return true;
    }
    return true;
}

/// A loopback `std.http.Client` request whose body is discarded.
fn probeFetch(client: *std.http.Client, url: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(client.allocator);
    defer aw.deinit();
    _ = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer });
}

/// Start a loopback listener and hand back its port.
fn probeListener() !std.Io.net.Server {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    return addr.listen(std.testing.io, .{ .reuse_address = true });
}

/// A port nothing listens on: bind, read the number, close.
fn deadLoopbackPort() !u16 {
    var listener = try probeListener();
    defer listener.deinit(std.testing.io);
    return listener.socket.address.getPort();
}

// The HTTPS path must hold one `std.http.Client`, not one per request. The
// attempts below fail (nothing listens) — that is the point: they still have
// to be served by the same, lazily created client.
test "HttpClient builds one std.http.Client for the HTTPS path" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var client = HttpClient.init(allocator, std.testing.io, 1, 500);
    defer client.deinit();
    client.retry_policy.max_retries = 0;

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/probe", .{try deadLoopbackPort()});

    for (0..2) |_| {
        var req = HttpClient.HttpRequest.init(allocator, "GET", url);
        defer req.deinit();
        // Refused (or an unusable CA bundle): never a success, and never a
        // crash — a per-request client would already be a different shape.
        if (client.request(req)) |ok| {
            var resp = ok;
            resp.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
        try std.testing.expectEqual(@as(u32, 1), client.https_clients_created);
    }
}

// The resident client caches the clock std decides certificate expiry with
// (`std.http.Client.now`, handed to the TLS client as `realtime_now`) and takes
// it only on that client's first HTTPS request. A client kept alive for hours
// would keep validating certificates against a clock from hours ago, so a
// hand-out re-arms it once it has drifted past `https_clock_max_skew_seconds`.
// The hand-outs here are driven directly: clearing the clock is this file's
// decision, and std re-reading it needs no handshake (it happens before the
// connect), so neither half needs a TLS peer.
test "HttpClient re-arms the resident HTTPS client clock when it is stale" {
    const allocator = std.testing.allocator;

    var client = HttpClient.init(allocator, std.testing.io, 1, 500);
    defer client.deinit();
    client.retry_policy.max_retries = 0;

    const shared = try client.httpsClient();
    client.releaseHttpsClient();
    try std.testing.expectEqual(@as(u32, 1), client.https_clients_created);

    const bound = HttpClient.https_clock_max_skew_seconds;
    const real = std.Io.Clock.real.now(std.testing.io);

    // Inside the bound the cached clock is left alone: a client in use must not
    // pay a CA-bundle rescan per request.
    const inside_ns: i96 = real.toNanoseconds() - (bound - 1) * std.time.ns_per_s;
    shared.now = .fromNanoseconds(inside_ns);
    _ = try client.httpsClient();
    client.releaseHttpsClient();
    try std.testing.expect(shared.now != null);
    try std.testing.expectEqual(inside_ns, shared.now.?.toNanoseconds());

    // Past the bound (either direction) it is dropped, and std reads the time
    // again on the next HTTPS request.
    for ([_]i96{
        real.toNanoseconds() - (bound + 1) * std.time.ns_per_s,
        real.toNanoseconds() + (bound + 1) * std.time.ns_per_s,
    }) |stale_ns| {
        shared.now = .fromNanoseconds(stale_ns);
        _ = try client.httpsClient();
        try std.testing.expect(shared.now == null);
        client.releaseHttpsClient();
    }

    // Re-arming is not a re-create: the CA bundle and the pooled TLS
    // connections survive the clock being dropped.
    try std.testing.expectEqual(@as(u32, 1), client.https_clients_created);

    // And std does take the time again — the field must not stay `null`, or
    // every request from here on would rescan the system CA bundle. One request
    // against a closed port is enough: the clock is read before the connect.
    if (@import("../test/NetworkProbe.zig").available()) {
        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://127.0.0.1:{d}/probe", .{try deadLoopbackPort()});
        var req = HttpClient.HttpRequest.init(allocator, "GET", url);
        defer req.deinit();

        const result = client.request(req);
        if (result) |ok| {
            var resp = ok;
            resp.deinit();
            return error.TestUnexpectedResult;
        } else |err| {
            // Without a usable system CA bundle std never reaches the clock;
            // every other outcome (refused, unusable address) happens after it
            // has taken the time.
            if (err != error.TlsHandshakeFailed) {
                try std.testing.expect(shared.now != null);
            }
        }
    }
}

// `deinit` has to be safe to run twice and to run before any HTTPS request,
// and requests after it must be a defined error rather than a use-after-free
// of the torn-down pool/client.
test "HttpClient refuses requests after deinit" {
    const allocator = std.testing.allocator;

    var client = HttpClient.init(allocator, std.testing.io, 1, 500);
    client.deinit();
    // No shared client was ever created; a second deinit must not touch the
    // (already freed) pool or the null pointer again.
    client.deinit();

    var req = HttpClient.HttpRequest.init(allocator, "GET", "http://127.0.0.1:1/probe");
    defer req.deinit();

    try std.testing.expectError(error.HttpClientClosed, client.request(req));

    const Sink = struct {
        fn onChunk(_: *anyopaque, _: []const u8) anyerror!void {}
    };
    try std.testing.expectError(error.HttpClientClosed, client.requestStream(req, undefined, Sink.onChunk));
}

// Plain HTTP keeps using this struct's own `ConnectionPool` (behaviour
// unchanged) and must not create the HTTPS client on the way.
test "plain HTTP reuses one keep-alive connection and builds no HTTPS client" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var listener = try probeListener();
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    var server = PoolProbeServer{
        .listener = &listener,
        .payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
    };
    const th = try std.Thread.spawn(.{}, PoolProbeServer.run, .{&server});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/probe", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 1, 2000);
    defer client.deinit();

    for (0..3) |_| {
        var req = HttpClient.HttpRequest.init(allocator, "GET", url);
        defer req.deinit();
        var resp = try client.request(req);
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expectEqualStrings("OK", resp.body);
    }

    // Three requests, one socket. `acquire` only dials when no idle connection
    // matches, so the pool's own per-connection counter is the reading that
    // says the same socket served all three (a re-dial would have restarted
    // the counter at 1).
    try std.testing.expectEqual(@as(usize, 1), client.connection_pool.idle_connections.items.len);
    try std.testing.expectEqual(@as(u64, 3), client.connection_pool.idle_connections.items[0].request_count);
    try std.testing.expectEqual(@as(usize, 0), client.connection_pool.active_connections.items.len);
    // The plain path never touches the HTTPS client.
    try std.testing.expectEqual(@as(u32, 0), client.https_clients_created);
}

// A peer that closes every connection after a single reply — a per-connection
// idle timeout, a crashed worker, a rolling restart — is what the plain path
// cannot see: `isAlive()` only checks a 30-second window over `last_used`, never
// the request that just ran. So a socket whose request failed goes straight back
// to `idle_connections` and the next request is handed it; every retry then
// re-acquires the same corpse (`acquire` finds a matching idle entry whose
// window has not elapsed), turning one peer close into a permanently poisoned
// pool slot. Two rounds against a server that closes after each reply: the
// second has to dial again, not reuse the dead socket.
test "plain HTTP does not re-hand-out a connection whose request failed" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var listener = try probeListener();
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    var server = PoolProbeServer{
        .listener = &listener,
        .payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
        .abort_after_reply = true,
        // The retry that must dial a fresh connection lands ~100ms after the
        // failed attempt; the listener has to still be accepting by then.
        .accept_grace_ms = 2000,
    };
    const th = try std.Thread.spawn(.{}, PoolProbeServer.run, .{&server});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/probe", .{port});

    var client = HttpClient.init(allocator, std.testing.io, 1, 2000);
    defer client.deinit();

    for (0..2) |round| {
        var req = HttpClient.HttpRequest.init(allocator, "GET", url);
        defer req.deinit();
        var resp = client.request(req) catch |err| {
            std.debug.print(
                "round {d}: {s} — {} idle connection(s) in the pool, {} active\n",
                .{
                    round,
                    @errorName(err),
                    client.connection_pool.idle_connections.items.len,
                    client.connection_pool.active_connections.items.len,
                },
            );
            return err;
        };
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expectEqualStrings("OK", resp.body);
    }
}

// The retry path relies on `discardIdleConnections` dropping exactly one
// target's idle connections: the next request to that target then has nothing
// to reuse and must dial again, while other targets keep their pooled socket.
test "HttpClient drops idle connections for one target only" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var listener_a = try probeListener();
    defer listener_a.deinit(std.testing.io);
    const port_a = listener_a.socket.address.getPort();
    var listener_b = try probeListener();
    defer listener_b.deinit(std.testing.io);
    const port_b = listener_b.socket.address.getPort();

    const payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
    var server_a = PoolProbeServer{ .listener = &listener_a, .payload = payload };
    var server_b = PoolProbeServer{ .listener = &listener_b, .payload = payload };
    const th_a = try std.Thread.spawn(.{}, PoolProbeServer.run, .{&server_a});
    defer th_a.join();
    const th_b = try std.Thread.spawn(.{}, PoolProbeServer.run, .{&server_b});
    defer th_b.join();

    var url_a_buf: [128]u8 = undefined;
    const url_a = try std.fmt.bufPrint(&url_a_buf, "http://127.0.0.1:{d}/probe", .{port_a});
    var url_b_buf: [128]u8 = undefined;
    const url_b = try std.fmt.bufPrint(&url_b_buf, "http://127.0.0.1:{d}/probe", .{port_b});

    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    try probeFetch(&client, url_a);
    try probeFetch(&client, url_b);
    const free = &client.connection_pool.free_len;
    try std.testing.expectEqual(@as(usize, 2), free.*);

    // Other host, same port: nothing matches, nothing is closed.
    HttpClient.discardIdleConnections(&client, "localhost", port_a, .plain);
    try std.testing.expectEqual(@as(usize, 2), free.*);

    // Wrong port for that host: still nothing.
    HttpClient.discardIdleConnections(&client, "127.0.0.1", port_b +% 1, .plain);
    try std.testing.expectEqual(@as(usize, 2), free.*);

    HttpClient.discardIdleConnections(&client, "127.0.0.1", port_a, .plain);
    try std.testing.expectEqual(@as(usize, 1), free.*);
    // Idempotent: the second call finds nothing left to close.
    HttpClient.discardIdleConnections(&client, "127.0.0.1", port_a, .plain);
    try std.testing.expectEqual(@as(usize, 1), free.*);

    // A is gone from the pool, so this request has nothing to reuse: it must
    // dial again, and its new connection lands next to B's.
    try probeFetch(&client, url_a);
    try std.testing.expectEqual(@as(usize, 2), free.*);

    // B never lost its pooled connection — pruning A left it alone.
    try probeFetch(&client, url_b);
    try std.testing.expectEqual(@as(usize, 2), free.*);
}

// A peer that closes an *idle keep-alive* connection is the failure mode the
// retry loop has to survive: the pooled socket is dead, so the request on it
// fails. Whatever std does with that connection on the way out, the next
// request must not be handed it again — that is what the prune buys, and the
// final fetch proves a usable connection either way.
test "HttpClient retries a dead pooled connection on a fresh one" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var listener = try probeListener();
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    var server = PoolProbeServer{
        .listener = &listener,
        .payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
        .abort_after_reply = true,
    };
    const th = try std.Thread.spawn(.{}, PoolProbeServer.run, .{&server});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/probe", .{port});

    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    // First request succeeded, and its connection was pooled even though the
    // peer has already closed it.
    try probeFetch(&client, url);
    try std.testing.expectEqual(@as(usize, 1), client.connection_pool.free_len);

    // The second request reuses that dead socket and must fail. (Which error
    // depends on how the close races the write — observed on macOS:
    // `HttpConnectionClosing` for a clean close, `WriteFailed` for an abortive
    // one. `WriteFailed` is also the case where std leaves the connection in
    // the pool, which is why the prune below is not optional.)
    const second = probeFetch(&client, url);
    if (second) |_| return error.TestUnexpectedResult else |_| {}

    // Retry shaping: drop the target's idle connections so the retry cannot
    // pick the connection that just failed, then the request must succeed on a
    // freshly dialed one.
    HttpClient.discardIdleConnections(&client, "127.0.0.1", port, .plain);
    try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);
    try probeFetch(&client, url);
    try std.testing.expectEqual(@as(usize, 1), client.connection_pool.free_len);
}

// Why the streaming path closes its connection on an aborted body: std's
// `Request.deinit` *drains* whatever is left of a response before pooling the
// connection. Against a peer that keeps streaming (an SSE/LLM body with no
// final chunk) that drain is a block on a body that may never end, and a
// partially consumed stream is not a position the next request may resume
// from. Marking the connection `closing` skips the drain and destroys it —
// the same two lines the `errdefer` in `executeHttpsStream` executes.
test "std.http.Client drains and re-pools a half-read body unless it is closing" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var listener = try probeListener();
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    var server = PoolProbeServer{
        .listener = &listener,
        // 100 body bytes, as the Content-Length promises.
        .payload = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n" ++
            "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789",
    };
    const th = try std.Thread.spawn(.{}, PoolProbeServer.run, .{&server});
    defer th.join();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/long", .{port});
    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
    defer client.deinit();

    const consumeFourBytes = struct {
        fn run(c: *std.http.Client, req_uri: std.Uri) !void {
            var req = try c.request(.GET, req_uri, .{});
            defer req.deinit();
            try req.sendBodiless();
            var resp = try req.receiveHead(&.{});
            var transfer_buf: [4096]u8 = undefined;
            const body = resp.reader(&transfer_buf);
            var small: [4]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 4), try body.readSliceShort(&small));
        }
    };

    // (a) The caller emptied 4 of the 100 bytes; std reads the other 96 before
    // pooling, and the connection comes back for the next request.
    try consumeFourBytes.run(&client, uri);
    try std.testing.expectEqual(@as(usize, 1), client.connection_pool.free_len);

    // (b) Same shape, but the connection is marked closing first (what the
    // `errdefer` does): no drain, no pooling — the socket is closed instead.
    {
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var resp = try req.receiveHead(&.{});
        var transfer_buf: [4096]u8 = undefined;
        const body = resp.reader(&transfer_buf);
        var small: [4]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 4), try body.readSliceShort(&small));
        req.connection.?.closing = true;
    }
    try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);

    // The pool is empty, so this is another fresh dial and the server is still
    // serving: the abort did not wedge anything.
    try probeFetch(&client, url);
    try std.testing.expectEqual(@as(usize, 1), client.connection_pool.free_len);
}
