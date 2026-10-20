//! `zig build bench-http -- --proto h2c --conns 16 --streams 16 --requests 200000`
//!
//! An HTTP load generator written in Zig, so measuring the server does not
//! require nghttp2/h2load or Python's `h2` package. It speaks:
//!
//!   * `h2c` — HTTP/2 prior knowledge over cleartext TCP: one preface per
//!     connection, up to `--streams` requests in flight, frames encoded with the
//!     framework's `http.Http2` primitives (the same wire format the server
//!     decodes, which is what makes this a useful client-side check too).
//!   * `h1` — HTTP/1.1 keep-alive, one request at a time per connection.
//!
//! Raw `send`/`read` on the socket, no buffered writer: every request is one
//! write and the response is parsed in place, so the client stays out of the
//! measurement as much as possible. It is still a *generator*, not an
//! independent implementation: for protocol conformance use `h2load`/curl, for
//! throughput and latency on one host this is enough and dependency-free.
//!
//! Output is one line per run plus latency percentiles; numbers are only
//! meaningful against a **ReleaseFast** server (`scripts/bench-e2e.sh` builds
//! one by default).

const std = @import("std");
const http = @import("zigmodu").http;
const Http2 = http.Http2;

const Proto = enum { h1, h2c };

const Cfg = struct {
    proto: Proto = .h2c,
    host: []const u8 = "127.0.0.1",
    port: u16 = 18088,
    path: []const u8 = "/ping",
    conns: usize = 16,
    streams: usize = 16,
    requests: usize = 100_000,
    warmup: usize = 20,
};

const Worker = struct {
    cfg: *const Cfg,
    io: std.Io,
    index: usize,
    per_conn: usize,
    done: *std.atomic.Value(u64),
    errors: *std.atomic.Value(u64),
    ready: *std.atomic.Value(u32),
    go: *std.atomic.Value(bool),
    samples: []u64,
    sample_count: usize = 0,
    sample_cap: usize,
    signaled: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{ .async_limit = .limited(256) });
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    {
        var iter = try init.minimal.args.iterateAllocator(allocator);
        defer iter.deinit();
        while (iter.next()) |arg| try args.append(allocator, arg);
    }

    var cfg = Cfg{};
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const a = args.items[i];
        if (std.mem.eql(u8, a, "--proto")) {
            i += 1;
            cfg.proto = if (std.mem.eql(u8, argAt(args, i), "h1")) .h1 else .h2c;
        } else if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            cfg.host = argAt(args, i);
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            cfg.port = try std.fmt.parseInt(u16, argAt(args, i), 10);
        } else if (std.mem.eql(u8, a, "--path")) {
            i += 1;
            cfg.path = argAt(args, i);
        } else if (std.mem.eql(u8, a, "--conns")) {
            i += 1;
            cfg.conns = try std.fmt.parseInt(usize, argAt(args, i), 10);
        } else if (std.mem.eql(u8, a, "--streams")) {
            i += 1;
            cfg.streams = try std.fmt.parseInt(usize, argAt(args, i), 10);
        } else if (std.mem.eql(u8, a, "--requests")) {
            i += 1;
            cfg.requests = try std.fmt.parseInt(usize, argAt(args, i), 10);
        } else if (std.mem.eql(u8, a, "--warmup")) {
            i += 1;
            cfg.warmup = try std.fmt.parseInt(usize, argAt(args, i), 10);
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printUsage();
            return;
        } else {
            std.log.err("bench-http: unknown argument {s}", .{a});
            printUsage();
            std.process.exit(2);
        }
    }
    if (cfg.conns == 0 or cfg.requests == 0) {
        std.log.err("bench-http: --conns and --requests must be positive", .{});
        std.process.exit(2);
    }

    const per_conn = @max(1, cfg.requests / cfg.conns);
    const total = per_conn * cfg.conns;
    const sample_cap = @min(per_conn, 100_000);

    var done = std.atomic.Value(u64).init(0);
    var errors = std.atomic.Value(u64).init(0);
    var ready = std.atomic.Value(u32).init(0);
    var go = std.atomic.Value(bool).init(false);

    const workers = try allocator.alloc(Worker, cfg.conns);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, cfg.conns);
    defer allocator.free(threads);
    const samples = try allocator.alloc(u64, cfg.conns * sample_cap);
    defer allocator.free(samples);

    for (0..cfg.conns) |w| {
        workers[w] = .{
            .cfg = &cfg,
            .io = io,
            .index = w,
            .per_conn = per_conn,
            .done = &done,
            .errors = &errors,
            .ready = &ready,
            .go = &go,
            .samples = samples[w * sample_cap ..][0..sample_cap],
            .sample_cap = sample_cap,
        };
        threads[w] = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, workerMain, .{&workers[w]});
    }

    // Wait until every connection is up and warmed, then start the timed phase.
    // Workers signal after their warmup; the timeout is a backstop so a worker
    // that died before signalling cannot hang the whole run.
    var waited_ms: usize = 0;
    while (ready.load(.acquire) < cfg.conns and waited_ms < 5000) : (waited_ms += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .real) catch |err| {
            std.log.debug("bench-http: wait sleep failed: {s}", .{@errorName(err)});
            break;
        };
    }
    const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
    go.store(true, .release);

    for (threads) |t| t.join();
    const elapsed_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - t0;

    var all = std.ArrayList(u64).empty;
    defer all.deinit(allocator);
    for (workers) |*w| {
        try all.appendSlice(allocator, w.samples[0..w.sample_count]);
    }
    std.mem.sort(u64, all.items, {}, std.sort.asc(u64));

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const completed = done.load(.monotonic);
    const failed = errors.load(.monotonic);

    std.debug.print("proto={s} conns={d} streams={d} requests={d}\n" ++
        "done={d} errors={d} elapsed={d:.3}s req/s={d}\n" ++
        "latency_us: p50={d} p95={d} p99={d} max={d}\n", .{
        @tagName(cfg.proto), cfg.conns,         cfg.streams,       total,
        completed,           failed,            elapsed_s,         @as(u64, @intFromFloat(@as(f64, @floatFromInt(completed)) / elapsed_s)),
        us(all.items, 50),   us(all.items, 95), us(all.items, 99), us(all.items, 100),
    });

    if (failed != 0) std.process.exit(1);
}

fn argAt(args: std.ArrayList([]const u8), i: usize) []const u8 {
    if (i >= args.items.len) {
        std.log.err("bench-http: missing value for argument", .{});
        std.process.exit(2);
    }
    return args.items[i];
}

fn us(sorted: []const u64, pct: usize) u64 {
    if (sorted.len == 0) return 0;
    const idx = @min(sorted.len - 1, (sorted.len - 1) * pct / 100);
    return sorted[idx] / 1000;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build bench-http -- [options]
        \\  --proto h1|h2c   protocol (default h2c)
        \\  --host HOST      (default 127.0.0.1)
        \\  --port PORT      (default 18088)
        \\  --path PATH      (default /ping)
        \\  --conns N        parallel connections (default 16)
        \\  --streams N      concurrent streams per connection in h2c (default 16)
        \\  --requests N     total timed requests (default 100000)
        \\  --warmup N       untimed requests per connection before the clock (default 20)
        \\
    , .{});
}

fn signalReady(w: *Worker) void {
    if (w.signaled) return;
    w.signaled = true;
    _ = w.ready.fetchAdd(1, .monotonic);
}

fn workerMain(w: *Worker) void {
    defer signalReady(w);
    if (connect(w)) |stream| {
        defer stream.close(w.io);
        switch (w.cfg.proto) {
            .h1 => runH1(w, stream),
            .h2c => runH2(w, stream),
        }
    } else |_| {
        _ = w.errors.fetchAdd(1, .monotonic);
    }
}

fn connect(w: *Worker) !std.Io.net.Stream {
    const addr = std.Io.net.IpAddress.parseIp4(w.cfg.host, w.cfg.port) catch return error.BadAddress;
    const stream = try addr.connect(w.io, .{ .mode = .stream });
    const one: i32 = 1;
    _ = std.c.setsockopt(stream.socket.handle, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
    return stream;
}

fn waitForGo(w: *Worker) bool {
    while (!w.go.load(.acquire)) {
        std.Io.sleep(w.io, std.Io.Duration.fromMilliseconds(1), .real) catch |err| {
            std.log.debug("bench-http: go sleep failed: {s}", .{@errorName(err)});
            return false;
        };
    }
    return true;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.c.send(fd, bytes[sent..].ptr, bytes.len - sent, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => return error.WriteFailed,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
}

fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.posix.read(fd, buf[got..]) catch return error.ReadFailed;
        if (n == 0) return error.Closed;
        got += n;
    }
}

fn nowNs(w: *Worker) u64 {
    return @intCast(std.Io.Timestamp.now(w.io, .awake).nanoseconds);
}

fn record(w: *Worker, start_ns: u64) void {
    if (w.sample_count < w.sample_cap) {
        w.samples[w.sample_count] = nowNs(w) - start_ns;
        w.sample_count += 1;
    }
}

// ── HTTP/1.1 ────────────────────────────────────────────────────────────────

fn runH1(w: *Worker, stream: std.Io.net.Stream) void {
    const fd = stream.socket.handle;
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: keep-alive\r\n\r\n", .{
        w.cfg.path, w.cfg.host, w.cfg.port,
    }) catch return;

    // Warmup: untimed, but it proves the connection is usable before the clock.
    for (0..w.cfg.warmup) |_| {
        if (!h1Once(fd, req, null, w)) return;
    }
    signalReady(w);
    if (!waitForGo(w)) return;

    for (0..w.per_conn) |_| {
        const start = nowNs(w);
        if (!h1Once(fd, req, start, w)) return;
        _ = w.done.fetchAdd(1, .monotonic);
    }
}

fn h1Once(fd: std.posix.fd_t, req: []const u8, start: ?u64, w: *Worker) bool {
    writeAll(fd, req) catch {
        _ = w.errors.fetchAdd(1, .monotonic);
        return false;
    };
    var buf: [8192]u8 = undefined;
    var have: usize = 0;
    var header_end: ?usize = null;
    while (header_end == null) {
        if (have == buf.len) {
            _ = w.errors.fetchAdd(1, .monotonic);
            return false;
        }
        const n = std.posix.read(fd, buf[have..]) catch {
            _ = w.errors.fetchAdd(1, .monotonic);
            return false;
        };
        if (n == 0) {
            _ = w.errors.fetchAdd(1, .monotonic);
            return false;
        }
        have += n;
        if (std.mem.indexOf(u8, buf[0..have], "\r\n\r\n")) |p| header_end = p + 4;
    }
    const head = buf[0..header_end.?];
    const body_len = contentLength(head) orelse 0;
    var body_have: usize = have - header_end.?;
    while (body_have < body_len) {
        const n = std.posix.read(fd, buf[0..]) catch {
            _ = w.errors.fetchAdd(1, .monotonic);
            return false;
        };
        if (n == 0) {
            _ = w.errors.fetchAdd(1, .monotonic);
            return false;
        }
        body_have += n;
    }
    if (start) |s| record(w, s);
    return true;
}

fn contentLength(head: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) {
            const v = std.mem.trim(u8, line[colon + 1 ..], " ");
            return std.fmt.parseInt(usize, v, 10) catch null;
        }
    }
    return null;
}

// ── HTTP/2 (h2c, prior knowledge) ───────────────────────────────────────────

fn runH2(w: *Worker, stream: std.Io.net.Stream) void {
    const fd = stream.socket.handle;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    writeAll(fd, preface) catch return fail(w);

    const settings = Http2.encodeSettings(a, false, &.{
        .{ Http2.SettingsId.initial_window_size, 1 << 20 },
        .{ Http2.SettingsId.enable_push, 0 },
    }) catch return fail(w);
    writeAll(fd, settings) catch return fail(w);
    // The connection-level receive window is fixed at 65535 regardless of
    // SETTINGS; one large WINDOW_UPDATE keeps tiny responses flowing.
    const conn_window = Http2.encodeWindowUpdate(a, 0, 1 << 30) catch return fail(w);
    writeAll(fd, conn_window) catch return fail(w);

    const block = Http2.encodeLiteralHeaderBlock(a, &.{
        .{ ":method", "GET" },
        .{ ":scheme", "http" },
        .{ ":authority", w.cfg.host },
        .{ ":path", w.cfg.path },
    }) catch return fail(w);

    var in_flight: usize = 0;
    var opened: usize = 0;
    var finished: usize = 0;
    // Warmup is capped by the in-flight limit: only that many streams can be
    // opened before the read loop starts, so the rest must be timed requests.
    const warm = @min(w.cfg.warmup, w.cfg.streams);
    const per = w.per_conn + warm;
    // Zeroed: an uninitialised slot would look like a started request when a
    // warmup stream ends on it, inflating `done`.
    var starts = std.mem.zeroes([4096]u64);
    var sid: u31 = 1;

    const openStream = struct {
        fn f(ww: *Worker, fd_: std.posix.fd_t, blk: []const u8, sid_: *u31, starts_: []u64, timed: bool) bool {
            var hdr: [9]u8 = undefined;
            (Http2.FrameHeader{
                .length = @intCast(blk.len),
                .typ = .headers,
                .flags = Http2.FrameFlags.end_stream | Http2.FrameFlags.end_headers,
                .stream_id = sid_.*,
            }).encode(&hdr);
            starts_[sid_.* % starts_.len] = if (timed) nowNs(ww) else 0;
            writeAll(fd_, &hdr) catch return false;
            writeAll(fd_, blk) catch return false;
            sid_.* += 2;
            return true;
        }
    }.f;

    // Warmup first, and only warmup: a timed stream opened before `go` would
    // record its start early and inflate the first latency samples.
    while (opened < warm and in_flight < w.cfg.streams) {
        if (!openStream(w, fd, block, &sid, &starts, false)) return fail(w);
        opened += 1;
        in_flight += 1;
    }

    signalReady(w);
    if (!waitForGo(w)) return;

    while (opened < per and in_flight < w.cfg.streams) {
        if (!openStream(w, fd, block, &sid, &starts, true)) return fail(w);
        opened += 1;
        in_flight += 1;
    }

    var payload: [64 * 1024]u8 = undefined;
    var hdr: [9]u8 = undefined;
    while (finished < per) {
        readExact(fd, &hdr) catch return fail(w);
        const header = Http2.FrameHeader.decode(&hdr) catch return fail(w);
        if (header.length > payload.len) return fail(w);
        if (header.length > 0) readExact(fd, payload[0..header.length]) catch return fail(w);

        switch (header.typ) {
            .settings => {
                if (header.flags & 0x1 == 0) {
                    var ack: [9]u8 = undefined;
                    (Http2.FrameHeader{ .length = 0, .typ = .settings, .flags = 0x1, .stream_id = 0 }).encode(&ack);
                    writeAll(fd, &ack) catch return fail(w);
                }
            },
            .goaway => return fail(w),
            else => {},
        }

        if (header.stream_id != 0 and (header.flags & Http2.FrameFlags.end_stream) != 0) {
            const idx = header.stream_id % starts.len;
            const started = starts[idx];
            if (started != 0) {
                record(w, started);
                _ = w.done.fetchAdd(1, .monotonic);
            }
            starts[idx] = 0;
            finished += 1;
            in_flight -= 1;
            if (opened < per) {
                if (!openStream(w, fd, block, &sid, &starts, true)) return fail(w);
                opened += 1;
                in_flight += 1;
            }
        }
    }
}

fn fail(w: *Worker) void {
    _ = w.errors.fetchAdd(1, .monotonic);
}
