const std = @import("std");
const sockread = @import("../core/sockread.zig");
const Time = @import("../core/Time.zig");
const ApplicationModules = @import("../core/Module.zig").ApplicationModules;

/// WebSocket support for real-time monitoring
/// Provides RFC 6455 WebSocket server functionality for live module updates
/// WebSocket support for real-time monitoring
/// Provides RFC 6455 WebSocket server functionality for live module updates
pub const WebSocketServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    server: ?std.Io.net.Server,
    is_running: bool,
    clients: std.array_list.Managed(*WebSocketClient),
    clients_mutex: std.Io.Mutex,
    /// Broadcasts that reached *nobody* because the client lock could not be
    /// taken (the publishing task was canceled). `broadcast` returns `void`, so
    /// this counter — plus the error log — is the only trace a lost push leaves.
    dropped_broadcasts: std.atomic.Value(u64),
    accept_fiber_started: bool,
    /// Group that owns the `acceptLoop` fiber and every spawned
    /// `handleConnection` fiber. Awaited in `stop()` so no futures leak.
    fiber_group: std.Io.Group,
    on_connect_cb: ?*const fn (*WebSocketClient) void,
    on_message_cb: ?*const fn (*WebSocketClient, []const u8) void,
    allowed_origins: []const []const u8 = &.{},
    /// Max WebSocket frame payload, in bytes. Frames larger than this are
    /// rejected with `PayloadTooLarge`. Explicit contract (was previously
    /// implied by a hard-coded 4096-byte stack buffer in `WebSocketClient.run`).
    max_frame_size: usize = 4096,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .port = port,
            .server = null,
            .is_running = false,
            .clients = std.array_list.Managed(*WebSocketClient).init(allocator),
            .clients_mutex = std.Io.Mutex.init,
            .dropped_broadcasts = std.atomic.Value(u64).init(0),
            .accept_fiber_started = false,
            .fiber_group = .init,
            .on_connect_cb = null,
            .on_message_cb = null,
        };
    }

    /// Override the max inbound frame payload (default 4096).
    pub fn setMaxFrameSize(self: *Self, size: usize) void {
        self.max_frame_size = size;
    }

    /// Tear down the registry. `stop()` has already drained the connection
    /// fibers, so the only possible holder of the registry lock is a concurrent
    /// `broadcast` — and the previous shape answered that contention with
    /// `tryLock`, then freed the client list anyway (both branches did the same
    /// work). That is memory unsafety dressed up as a teardown: the holder's
    /// next `clients` access reads freed storage, and a client could be freed
    /// twice. A destructor has to run to completion, so it waits — the rule
    /// `im/BufferPool.zig`, `cache/Lru.zig` and `pool/Pool.zig` follow. Red:
    /// `WebSocketServer: deinit waits for the registry lock instead of freeing
    /// underneath it`.
    pub fn deinit(self: *Self) void {
        self.stop();

        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        for (self.clients.items) |client| {
            // `release`, not `deinit` + `destroy`: a fan-out that selected this
            // client before the lock was taken may still be writing to it, and
            // it holds a reference. The last reference out closes the socket and
            // frees the client (see `WebSocketClient.release`).
            client.release();
        }
        self.clients.deinit();
    }

    /// Start listening, dispatching `acceptLoop` as a member of `fiber_group`.
    ///
    /// `concurrent`, **not** `async`, and that is load-bearing rather than
    /// stylistic. `std.Io.Threaded`'s `groupAsync` answers an exhausted
    /// `async_limit` by running the task body on the **calling** thread
    /// (`std/Io/Threaded.zig:2188-2191` → `groupAsyncEager`, `:2222-2226`; the
    /// limit itself defaults to `cpu_count - 1`, `:1641`). `acceptLoop` is a
    /// `while (self.is_running)` that only ever returns because *another* thread
    /// called `stop()` — so on a machine whose async pool is spent (a 2-core CI
    /// runner: one unit), the eager fallback makes this `start()` itself become
    /// the accept loop, and the caller never gets to call `stop()`: the WebSocket
    /// endpoint does not come up and the whole application hangs with it.
    /// `groupConcurrent` (`:2245-2270`) has no eager path — past
    /// `concurrent_limit` (`.unlimited` by default, `:40`) it returns
    /// `error.ConcurrencyUnavailable`, which is propagated here through
    /// `abortStart`, so a server that cannot be dispatched says so instead of
    /// stealing the caller.
    ///
    /// The other half: `Threaded` decrements `busy_count` only once a task body
    /// *returns* (`:1800-1802`), so a never-returning loop occupies its unit for
    /// the life of the process. Under the eager fallback that unit is the
    /// *caller's* thread, which is the hang above. Same reasoning as
    /// `DistributedEventBus.start()`.
    pub fn start(self: *Self) !void {
        if (self.is_running) return;

        var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.server = try address.listen(self.io, .{ .reuse_address = true });
        self.is_running = true;
        self.accept_fiber_started = true;

        std.log.info("[WebSocketServer] Started on ws://0.0.0.0:{d}", .{self.port});
        // A member of `fiber_group` for the reason in this function's header:
        // the loop never returns on its own.
        self.fiber_group.concurrent(self.io, acceptLoop, .{self}) catch |err| return self.abortStart(err);
    }

    /// Unwind a `start()` that could not dispatch the accept loop, so a failed
    /// `start()` leaves the server exactly as it was found: not running, no
    /// listener, and the port it had bound free again for the next `start()` (or
    /// for whoever else wants it).
    fn abortStart(self: *Self, err: std.Io.ConcurrentError) std.Io.ConcurrentError {
        self.is_running = false;
        self.accept_fiber_started = false;
        if (self.server) |*s| {
            sockread.closeListener(self.io, s);
            self.server = null;
        }
        self.fiber_group.await(self.io) catch |await_err| {
            std.log.err("[ws] fiber drain after a failed start: {}", .{await_err});
        };
        // `warn`, not `err`, for the same reason the rejected-connection log in
        // `acceptLoop` is: the caller has the error in hand and is the party that
        // can act on it, and Zig's test runner fails the whole run when a test
        // logs at `err` — so an `err` here would make this path untestable.
        std.log.warn("[WebSocketServer] accept loop not dispatched: {}", .{err});
        return err;
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.server) |*s| {
            // `shutdown` before `close`: on Linux `close` does not wake a
            // thread blocked in `accept`, and the await below would wait for a
            // loop that can never see `is_running` flip.
            sockread.closeListener(self.io, s);
            self.server = null;
        }
        // Drain any in-flight accept/connection fibers so their futures do
        // not leak. Safe to call repeatedly because `Group.await` is idempotent.
        self.fiber_group.await(self.io) catch |err| {
            std.log.debug("[ws] draining fiber group failed: {s}", .{@errorName(err)});
        };
    }

    fn acceptLoop(self: *Self) void {
        while (self.is_running) {
            if (self.server) |*s| {
                const conn = s.accept(self.io) catch |err| {
                    if (self.is_running) {
                        std.log.err("[WebSocketServer] Accept error: {}", .{err});
                    }
                    continue;
                };
                // `concurrent` (not `async`): handleConnection is a blocking
                // read loop — `async`'s eager fallback at async_limit would
                // run it on the accept thread and freeze accept forever.
                self.fiber_group.concurrent(self.io, handleConnection, .{ self, conn }) catch |err| {
                    std.log.warn("[WebSocketServer] connection rejected (concurrent limit): {}", .{err});
                    conn.close(self.io);
                    continue;
                };
            }
        }
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) void {
        // The socket changes hands once the client is registered: from then on
        // the client owns it, and only its *last* reference closes it
        // (`WebSocketClient.release`) — a fan-out that already selected this
        // client may still be writing to that socket, and closing it underneath
        // the write would hand the number to whatever opens next. Every early
        // return before registration closes it here.
        var frame_owns_socket = true;
        defer {
            if (frame_owns_socket) conn.close(self.io);
        }

        var buf: [4096]u8 = undefined;
        // Raw posix read, like `WebSocketClient.readFull`: this is a
        // long-blocking read waiting for the peer's request head, and the
        // io-based path (`conn.reader(...).interface.readSliceShort`) hangs here
        // even with the bytes already in the kernel buffer once the Io is shared
        // across threads — the reproduction `core/sockread.zig` documents. Red:
        // `WebSocketServer: a live client is handshaken, pushed to, and dropped`
        // (the request head was not read until the peer hung up, so no handshake
        // answer was ever written).
        const bytes_read = sockread.readSome(conn, &buf) catch |err| {
            std.log.err("[WebSocketServer] Read error: {}", .{err});
            return;
        };

        if (bytes_read == 0) return;
        const request = buf[0..bytes_read];

        // Parse WebSocket key from headers
        const ws_key = extractHeaderValue(request, "Sec-WebSocket-Key: ") orelse {
            // Not a WebSocket upgrade request - send HTTP response
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            var write_buf: [256]u8 = undefined;
            var w = conn.writer(self.io, &write_buf);
            // Best-effort: a failed write means the peer is already gone.
            _ = w.interface.writeAll(response) catch |err| {
                std.log.debug("[ws] handshake write failed (peer gone?): {s}", .{@errorName(err)});
            };
            // `writeAll` only *buffers* what fits in `write_buf` (`Io/Writer.zig`
            // returns as soon as the bytes are copied), so without this flush the
            // response dies with `w` — no error, nothing on the wire.
            w.interface.flush() catch |err| {
                std.log.debug("[ws] handshake write failed (peer gone?): {s}", .{@errorName(err)});
            };
            return;
        };
        // Validate Origin header if allowed_origins is configured
        if (self.allowed_origins.len > 0) {
            const origin = extractHeaderValue(request, "Origin: ");
            if (origin) |o| {
                var origin_allowed = false;
                for (self.allowed_origins) |allowed| {
                    if (std.mem.eql(u8, allowed, o)) {
                        origin_allowed = true;
                        break;
                    }
                }
                if (!origin_allowed) {
                    const response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                    var write_buf: [256]u8 = undefined;
                    var w = conn.writer(self.io, &write_buf);
                    // Best-effort: the peer is being rejected anyway; a failed
                    // write only means the socket is already gone.
                    _ = w.interface.writeAll(response) catch |err| {
                        std.log.debug("[ws] handshake write failed (peer gone?): {s}", .{@errorName(err)});
                    };
                    // Same flush contract as the 400 above: without it the 403 is
                    // never sent and the peer sees a hang instead of a rejection.
                    w.interface.flush() catch |err| {
                        std.log.debug("[ws] handshake write failed (peer gone?): {s}", .{@errorName(err)});
                    };
                    return;
                }
            }
        }

        // Generate accept key
        // Generate accept key
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        // **No `hash_input` buffer** — see `src/im/WsFramer.zig` for the full note.
        // This one was only `[60]u8` (24 + 36, the size of the RFC's example key),
        // so *any* key longer than 24 bytes wrote past it, and `ws_key` here comes
        // from a raw request header with no length limit. SHA-1 is incremental, so
        // feeding the two slices removes the buffer and the overflow with it.
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(ws_key);
        sha1.update(magic);
        var digest: [20]u8 = undefined;
        sha1.final(&digest);

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &digest);

        // Send handshake response
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n", .{accept_key}) catch return;

        var write_buf: [4096]u8 = undefined;
        var w = conn.writer(self.io, &write_buf);
        _ = w.interface.writeAll(response) catch |err| {
            std.log.err("[WebSocketServer] Handshake write error: {}", .{err});
            return;
        };
        // The flush is the delivery: the response is ~129 bytes and the buffer is
        // 4096, so `writeAll` alone leaves the 101 in a stack buffer that dies
        // here — the client waits for a handshake that never arrives. Red:
        // `WebSocketServer: a live client is handshaken, pushed to, and dropped`.
        w.interface.flush() catch |err| {
            std.log.err("[WebSocketServer] Handshake write error: {}", .{err});
            return;
        };

        // Create client
        const client = self.allocator.create(WebSocketClient) catch |err| {
            std.log.err("[WebSocketServer] Failed to allocate client: {}", .{err});
            return;
        };

        client.* = WebSocketClient.init(self.allocator, conn, self.io, self);

        // Ownership of `client` is the caller's until `addClient` lands it in the
        // registry. (No `errdefer` here: this function returns `void`, so one
        // could never fire.)
        self.addClient(client) catch |err| {
            std.log.err("[WebSocketServer] Failed to add client: {}", .{err});
            // Still this frame's socket (`frame_owns_socket` is untouched), so
            // the `defer` above closes it; `client.deinit()` here would close the
            // same fd twice.
            self.allocator.destroy(client);
            return;
        };
        frame_owns_socket = false;

        if (self.on_connect_cb) |cb| {
            cb(client);
        }

        client.run();

        // Unregister, then drop this fiber's reference. That reference is
        // usually the last one, so it is what closes the socket and frees the
        // client — but not necessarily: a fan-out that selected this client just
        // before `removeClient` holds a reference of its own and may still be
        // writing. Then the fan-out closes and frees, after the write (see
        // `WebSocketClient.release`). Either way the fd is closed exactly once,
        // after the last write to it, and never while this frame is still using
        // it.
        self.removeClient(client);
        client.release();
    }

    fn extractHeaderValue(request: []const u8, header_name: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, request, header_name)) |idx| {
            const value_start = idx + header_name.len;
            if (std.mem.indexOf(u8, request[value_start..], "\r\n")) |end| {
                return std.mem.trim(u8, request[value_start .. value_start + end], " \t");
            }
        }
        return null;
    }

    /// Register a freshly handshaken client. On failure ownership stays with the
    /// caller.
    ///
    /// Taken uncancelably: `handleConnection` runs on the connection fiber and
    /// returns `void`, so a `Canceled` from `lock` here has no channel to be
    /// reported through — and swallowing it would strand the just-allocated
    /// client (nothing else owns that pointer, and being in `clients` is what
    /// makes it reachable at all). The critical section is one `append`, which is
    /// why waiting for it is cheap. Red: `WebSocketServer: cancelation cannot
    /// strand a client at register`.
    fn addClient(self: *Self, client: *WebSocketClient) !void {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        try self.clients.append(client);
    }

    /// Drop `client` from the live set. `void`: the only caller is
    /// `handleConnection` on its way out, which has no error channel.
    ///
    /// Uncancelable for the same reason as `addClient`, and with more at stake:
    /// this is the *only* place an entry ever leaves `clients`. A canceled lock
    /// would keep a dead client — and its slot — for the life of the server, and
    /// every later `broadcast` would log a send error into it. One `swapRemove`
    /// is the whole critical section. Red: `WebSocketServer: cancelation cannot
    /// strand a client at removal`.
    fn removeClient(self: *Self, client: *WebSocketClient) void {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                return;
            }
        }
    }

    /// Send `message` to every connected client.
    ///
    /// `void` on purpose: a fan-out to N sockets has no single error a caller
    /// could act on (per-client send failures are logged as they happen and the
    /// rest of the fan-out still runs). What `void` *cannot* express is a
    /// broadcast that never started, so that case is counted
    /// (`droppedBroadcasts`) and logged — a loud drop rather than an error nobody
    /// reads or a silent no-op.
    ///
    /// The registry lock covers the **selection** of recipients only. It used to
    /// be held across every socket write, so one peer that stopped reading (a
    /// full send buffer parks the writing thread) froze the whole registry:
    /// `addClient`, `removeClient` and `clientCount` all wait on that lock, and
    /// the first two wait *uncancelably*. The recipients are snapshotted under
    /// the lock, each holding a reference that keeps it alive while the write
    /// runs outside it. Red: `WebSocketServer: broadcast keeps the registry lock
    /// off the socket write`.
    ///
    /// The registry lock stays cancelable here, unlike the registry paths: a
    /// cancel means the publishing task is being torn down, and waiting
    /// uncancelably would hold that teardown open for a full fan-out. The loss is
    /// recoverable for the caller that matters most (`WebSocketMonitor`
    /// re-broadcasts every 5s), whereas a lost registry entry never comes back on
    /// its own.
    pub fn broadcast(self: *Self, message: []const u8) void {
        var recipients = std.array_list.Managed(*WebSocketClient).init(self.allocator);
        defer recipients.deinit();

        self.clients_mutex.lock(self.io) catch |err| {
            // Counted, not just logged: this is the one path that loses a whole
            // message, and `void` gives the caller nowhere else to look. (`.warn`,
            // not `.err`: `scripts/test-runner.zig` fails a run over any
            // err-level log, so an `.err` here would make the drop path
            // untestable. The counter, not the log line, carries the signal.)
            _ = self.dropped_broadcasts.fetchAdd(1, .monotonic);
            std.log.warn("[ws] broadcast of {d} bytes dropped: {s} (it reached no client)", .{ message.len, @errorName(err) });
            return;
        };
        {
            defer self.clients_mutex.unlock(self.io);

            // Sized up front, while the lock is held: a partial snapshot would
            // silently skip recipients, and `void` has no channel to report
            // that. Failing here reaches nobody, so it is a dropped broadcast.
            recipients.ensureTotalCapacity(self.clients.items.len) catch {
                _ = self.dropped_broadcasts.fetchAdd(1, .monotonic);
                std.log.warn("[ws] broadcast of {d} bytes dropped: no memory for {d} recipient(s)", .{ message.len, self.clients.items.len });
                return;
            };

            for (self.clients.items) |client| {
                // A client the owner has already released is on its way out;
                // there is nothing to write to.
                if (!client.acquire()) continue;
                recipients.appendAssumeCapacity(client);
            }
        }

        // Outside the lock: this is the part that can park (a slow peer's socket
        // buffer), and the registry has to stay usable while it does.
        for (recipients.items) |client| {
            defer client.release();

            // One writer per client, or two fan-outs would interleave
            // half-frames on the same socket. Cancelable for the same reason the
            // registry lock is: a canceled publisher must not stay parked on
            // someone else's peer.
            client.write_mutex.lock(self.io) catch |err| {
                std.log.debug("[ws] broadcast to a client abandoned: {s}", .{@errorName(err)});
                continue;
            };
            defer client.write_mutex.unlock(self.io);

            client.sendText(message) catch |err| {
                std.log.err("[WebSocketServer] Broadcast error to client: {}", .{err});
            };
        }
    }

    /// Broadcasts that never reached a single client. Reads the counter
    /// `broadcast` bumps on the one path that drops a whole message; per-client
    /// send failures are not counted here (they are logged, and the other
    /// clients still get the message).
    pub fn droppedBroadcasts(self: *const Self) u64 {
        return self.dropped_broadcasts.load(.monotonic);
    }

    /// Number of live clients.
    ///
    /// Takes the lock (uncancelably) rather than `tryLock`: reporting 0 while
    /// another fiber held the registry lock is a wrong number no caller can tell
    /// apart from an empty registry — it is printed as `clients` in the monitor
    /// payload. Red: `WebSocketServer: clientCount reports the live count, not a
    /// lock verdict`.
    pub fn clientCount(self: *Self) usize {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        return self.clients.items.len;
    }

    pub fn onConnect(self: *Self, callback: *const fn (*WebSocketClient) void) void {
        self.on_connect_cb = callback;
    }

    pub fn onMessage(self: *Self, callback: *const fn (*WebSocketClient, []const u8) void) void {
        self.on_message_cb = callback;
    }
};

pub const WebSocketClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    io: std.Io,
    server: *WebSocketServer,
    is_connected: bool,
    /// Serializes frame writes. `writeFrame` issues more than one syscall once
    /// the payload outgrows its 4096-byte writer buffer, so two concurrent
    /// fan-outs to the same client would otherwise interleave half-frames on its
    /// socket (before `broadcast` was changed to write outside the registry
    /// lock, that lock serialized them by accident).
    write_mutex: std.Io.Mutex,
    /// How many places may still touch this client: 1 for the connection fiber
    /// that owns it, +1 for every fan-out that selected it for a write.
    ///
    /// This is what makes "snapshot under the registry lock, write outside it"
    /// safe: a client removed (and its socket handed to `release`) while a
    /// fan-out is writing to it cannot be freed yet, because the fan-out holds a
    /// reference. Before that, the registry lock was held across the write, so
    /// removal could not start until the write finished.
    refs: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream, io: std.Io, server: *WebSocketServer) Self {
        return .{
            .allocator = allocator,
            .stream = stream,
            .io = io,
            .server = server,
            .is_connected = true,
            .write_mutex = std.Io.Mutex.init,
            .refs = std.atomic.Value(u32).init(1),
        };
    }

    /// Mark the client dead and close its socket. Frees nothing: the object is
    /// freed by whoever drops the last reference (`release`).
    pub fn deinit(self: *Self) void {
        self.is_connected = false;
        self.stream.close(self.io);
        self.* = undefined;
    }

    /// Take a reference for an in-flight write, so this client cannot be freed
    /// underneath it. False once the owner has released (refs == 0): the client
    /// is being torn down and the caller must skip it.
    ///
    /// Only called while holding `WebSocketServer.clients_mutex`, and the
    /// owner's own release happens after `removeClient` — which takes that same
    /// lock — so this load-then-increment cannot race the transition to 0.
    fn acquire(self: *Self) bool {
        var cur = self.refs.load(.acquire);
        while (cur != 0) {
            if (self.refs.cmpxchgWeak(cur, cur + 1, .acquire, .monotonic)) |actual| {
                cur = actual;
                continue;
            }
            return true;
        }
        return false;
    }

    /// Drop a reference. The last one out closes the socket and frees the
    /// client — whoever it is: the connection fiber on its way out, a fan-out
    /// that outlived the registration, or `WebSocketServer.deinit`.
    fn release(self: *Self) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn run(self: *Self) void {
        // Buffer sized to the server's configured max frame size, so the
        // explicit limit and the actual read capacity can't drift apart.
        const buf = self.allocator.alloc(u8, self.server.max_frame_size) catch {
            self.is_connected = false;
            return;
        };
        defer self.allocator.free(buf);
        var read_buf: [4096]u8 = undefined;
        var r = self.stream.reader(self.io, &read_buf);
        while (self.is_connected) {
            const frame = self.readFrame(&r, buf) catch |err| {
                if (self.is_connected) {
                    std.log.debug("[WebSocketClient] Frame read error: {}", .{err});
                }
                break;
            };

            switch (frame.opcode) {
                0x1 => { // Text frame
                    if (self.server.on_message_cb) |cb| {
                        cb(self, frame.payload);
                    }
                },
                0x8 => { // Close frame
                    self.is_connected = false;
                    break;
                },
                0x9 => { // Ping
                    // A failed pong means the connection is dead, and the write
                    // path says so: `sendFrame` has already cleared
                    // `is_connected` by the time this returns, so the loop ends
                    // at its next check instead of waiting for the read to
                    // notice. No recovery is possible here; log it so operators
                    // see flapping links.
                    self.sendPong() catch |err| {
                        std.log.debug("[ws] pong send failed: {}", .{err});
                    };
                },
                else => {},
            }
        }
    }

    const Frame = struct {
        opcode: u8,
        payload: []const u8,
    };

    fn readFull(r: *std.Io.net.Stream.Reader, buf: []u8) !void {
        // Raw posix reads keep the fiber WS read loop working when the Io is
        // shared across threads (io-based socket reads can block forever even
        // with data available — see im/WsFramer.zig readFull).
        try @import("../core/sockread.zig").readFull(r.stream, buf);
    }

    fn readFrame(self: *Self, r: *std.Io.net.Stream.Reader, buf: []u8) !Frame {
        var header: [2]u8 = undefined;
        try readFull(r, &header);

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: usize = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try readFull(r, &ext);
            payload_len = @as(usize, @intCast(std.mem.readInt(u16, &ext, .big)));
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try readFull(r, &ext);
            payload_len = @as(usize, @intCast(std.mem.readInt(u64, &ext, .big)));
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            try readFull(r, &mask_key);
        }

        if (payload_len > self.server.max_frame_size) return error.PayloadTooLarge;
        try readFull(r, buf[0..payload_len]);

        if (masked) {
            for (buf[0..payload_len], 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        return .{
            .opcode = opcode,
            .payload = buf[0..payload_len],
        };
    }

    pub fn sendText(self: *Self, payload: []const u8) !void {
        try self.sendFrame(0x1, payload);
    }

    pub fn sendJson(self: *Self, payload: []const u8) !void {
        try self.sendFrame(0x1, payload);
    }

    fn sendPong(self: *Self) !void {
        try self.sendFrame(0xA, &[_]u8{});
    }

    /// Send one frame.
    ///
    /// Two failures with two different names, so a caller can act:
    ///  * `error.NotConnected` — this client was *already* known dead, so not a
    ///    byte was attempted (the guard below). Nothing to do but drop it.
    ///  * `error.WriteFailed` — the write itself failed. The client is marked
    ///    disconnected before returning, because a frame that fails partway
    ///    through leaves the stream **mid-frame**: a retry would prepend a second
    ///    header to the partial one and the peer's parser would see garbage. So
    ///    the client is unusable whatever the cause was (peer gone, buffer full,
    ///    task canceled) — and the cause is in the debug log.
    ///
    /// The old shape reported *every* write failure as `error.NotConnected`
    /// (`BrokenPipe`, `SocketUnconnected`, a cancel — all the same name) and left
    /// `is_connected` true, so a caller could not tell "the peer is gone" from
    /// "try again", and the object went on advertising a connection that had
    /// already failed. Red: `WebSocketClient: a write failure is named for the
    /// write, and the flag stops lying`.
    fn sendFrame(self: *Self, opcode: u8, payload: []const u8) !void {
        if (!self.is_connected) return error.NotConnected;
        try self.writeFrame(opcode, payload);
    }

    fn writeFrame(self: *Self, opcode: u8, payload: []const u8) error{WriteFailed}!void {
        var header_buf: [14]u8 = undefined;
        var header_len: usize = 2;

        header_buf[0] = 0x80 | opcode;

        if (payload.len < 126) {
            header_buf[1] = @intCast(payload.len);
        } else if (payload.len < 65536) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        var write_buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        _ = w.interface.writeAll(header_buf[0..header_len]) catch return self.writeFailed(&w);
        _ = w.interface.writeAll(payload) catch return self.writeFailed(&w);
        // **The flush is the delivery.** `writeAll` returns as soon as the bytes
        // are copied into `write_buf` (4096 bytes here) and never touches the
        // socket; without this, every frame smaller than the buffer is dropped
        // when `w` goes out of scope — the client receives nothing, no error is
        // returned, and `broadcast` cannot tell. Red: `WebSocketServer: a live
        // client is handshaken, pushed to, and dropped` (the push times out).
        w.interface.flush() catch return self.writeFailed(&w);
    }

    /// The one exit for a failed frame write: keep the writer's own cause (the
    /// `WriteFailed` the `Io.Writer` interface returns hides it — `w.err` is
    /// where the `Io` puts the real one), stop claiming to be connected, and name
    /// the failure for what it is.
    fn writeFailed(self: *Self, w: *std.Io.net.Stream.Writer) error{WriteFailed} {
        self.is_connected = false;
        const cause = if (w.err) |c| @errorName(c) else "unreported";
        std.log.debug("[ws] frame write failed ({s}); the client is now marked disconnected", .{cause});
        return error.WriteFailed;
    }
};

/// Integration with WebMonitor to provide real-time updates via WebSocket
pub const WebSocketMonitor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    ws_server: WebSocketServer,
    modules: ?*ApplicationModules,
    update_thread: ?std.Thread,
    is_running: bool,
    update_group: std.Io.Group,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) Self {
        return .{
            .allocator = allocator,
            .ws_server = WebSocketServer.init(allocator, io, port),
            .modules = null,
            .update_thread = null,
            .is_running = false,
            .update_group = .init,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.ws_server.deinit();
        self.* = undefined;
    }

    /// Start the WebSocket server and dispatch the metrics `updateLoop` as a
    /// member of `update_group`.
    ///
    /// Both halves are `concurrent` (see `WebSocketServer.start` for why the
    /// dispatch must not be `async`): `updateLoop` is a `while (self.is_running)`
    /// that only returns once *another* thread has called `stop()`, so an eager
    /// `async` fallback would run it on whatever thread called `start()` — that
    /// thread then never returns, and the monitor becomes un-stoppable from the
    /// only party that was going to stop it. A dispatch that cannot happen is
    /// reported instead, with the server half rolled back.
    pub fn start(self: *Self, modules: *ApplicationModules) !void {
        self.modules = modules;
        try self.ws_server.start();
        self.is_running = true;
        self.update_thread = null;
        self.update_group.concurrent(self.ws_server.io, updateLoop, .{self}) catch |err| return self.abortStart(err);
    }

    /// Unwind a `start()` that could not dispatch `updateLoop`. The WebSocket
    /// server half *was* started by then, so rolling back means stopping it —
    /// `stop()` closes the listener, and the accept loop (its own group's only
    /// member) exits on the flag, which is what frees the port again.
    fn abortStart(self: *Self, err: std.Io.ConcurrentError) std.Io.ConcurrentError {
        self.is_running = false;
        self.modules = null;
        self.ws_server.stop();
        self.update_group.await(self.ws_server.io) catch |await_err| {
            std.log.err("[ws] update fiber drain after a failed start: {}", .{await_err});
        };
        // `warn` for the reason given in `WebSocketServer.abortStart`.
        std.log.warn("[WebSocketMonitor] update loop not dispatched: {}", .{err});
        return err;
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        self.ws_server.stop();
        self.update_thread = null;
        self.update_group.await(self.ws_server.io) catch |err| {
            std.log.debug("[ws] draining update group failed: {s}", .{@errorName(err)});
        };
    }

    fn updateLoop(self: *Self) void {
        while (self.is_running) {
            self.broadcastMetrics() catch |err| {
                std.log.err("[WebSocketMonitor] Broadcast error: {}", .{err});
            };
            // Broadcast every 5 seconds
            std.Io.sleep(self.ws_server.io, .{ .nanoseconds = 5_000_000_000 }, .real) catch break;
        }
    }

    fn broadcastMetrics(self: *Self) !void {
        const module_count = if (self.modules) |m| m.modules.count() else 0;

        var json_buf: [1024]u8 = undefined;
        // `dropped_broadcasts` is what makes a lost push visible to whoever
        // scrapes this payload: it stays 0 unless a broadcast reached nobody.
        const json = try std.fmt.bufPrint(&json_buf, "{{\"type\":\"metrics\",\"module_count\":{d},\"clients\":{d},\"dropped_broadcasts\":{d},\"timestamp\":{d}}}", .{ module_count, self.ws_server.clientCount(), self.ws_server.droppedBroadcasts(), 0 });

        self.ws_server.broadcast(json);
    }
};

// ========================================
// Tests
// ========================================

test "WebSocketServer initialization" {
    const allocator = std.testing.allocator;
    var server = WebSocketServer.init(allocator, std.testing.io, 19001);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 19001), server.port);
    try std.testing.expectEqual(@as(usize, 0), server.clientCount());
}

test "WebSocketMonitor initialization" {
    const allocator = std.testing.allocator;
    var monitor = WebSocketMonitor.init(allocator, std.testing.io, 19002);
    defer monitor.deinit();

    try std.testing.expectEqual(@as(u16, 19002), monitor.ws_server.port);
}

// ── Registry ownership under cancelation ─────────────────────────────────────
//
// `std.Io.Mutex.lock` is a cancelation point, and the client registry has no
// error channel back to the acceptor: `handleConnection` returns `void`. So "did
// my client get registered / dropped?" must be decided by the registry, never by
// the task's cancel state. These tests drive a real cancel into the lock (the
// technique `runtime/mailbox.zig` uses for the same class of bug) and then read
// the registry.

/// Bound on the "wait for the other fiber to park" spins, so a missed signal
/// fails the suite instead of hanging it.
const wait_for_parked_fiber_rounds = 200_000_000;

/// True once the fiber inside `clients_mutex.lock` has parked: `lock` swaps the
/// state to `.contended` *before* it futex-waits, and nothing else in these
/// tests contends for that mutex.
fn parkedOnClientsLock(server: *WebSocketServer) bool {
    var spins: usize = 0;
    while (spins < wait_for_parked_fiber_rounds) : (spins += 1) {
        if (server.clients_mutex.state.load(.monotonic) == .contended) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

/// Teardown for a registry holding *stand-ins*: stack values that never owned a
/// socket. The entries must go first, because `WebSocketServer.deinit` calls
/// `WebSocketClient.deinit` on every entry and that closes a stream these values
/// never had.
fn deinitWithStandInClients(server: *WebSocketServer, io: std.Io) void {
    server.clients_mutex.lockUncancelable(io);
    server.clients.clearRetainingCapacity();
    server.clients_mutex.unlock(io);
    server.deinit();
}

test "WebSocketServer: cancelation cannot strand a client at register" {
    const io = std.testing.io;
    var server = WebSocketServer.init(std.testing.allocator, io, 19003);
    defer deinitWithStandInClients(&server, io);

    var stand_in = standInClient(&server, io);

    const Probe = struct {
        var add_err: ?anyerror = null;
        fn add(s: *WebSocketServer, c: *WebSocketClient) void {
            s.addClient(c) catch |err| {
                add_err = err;
            };
        }
        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Probe.add_err = null;

    server.clients_mutex.lockUncancelable(io);
    var add_fut = try io.concurrent(Probe.add, .{ &server, &stand_in });
    try std.testing.expect(parkedOnClientsLock(&server));
    var cancel_fut = try io.concurrent(Probe.cancel, .{ io, &add_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    server.clients_mutex.unlock(io);
    cancel_fut.await(io);
    add_fut.await(io);

    // Cancelation is not an ownership answer: the client ends up registered, or
    // the caller is told it is not (and still owns the pointer).
    try std.testing.expectEqual(@as(?anyerror, null), Probe.add_err);
    try std.testing.expectEqual(@as(usize, 1), server.clientCount());
}

test "WebSocketServer: cancelation cannot strand a client at removal" {
    const io = std.testing.io;
    var server = WebSocketServer.init(std.testing.allocator, io, 19004);
    defer deinitWithStandInClients(&server, io);

    var stand_in = standInClient(&server, io);
    try server.addClient(&stand_in);
    try std.testing.expectEqual(@as(usize, 1), server.clientCount());

    const Probe = struct {
        fn remove(s: *WebSocketServer, c: *WebSocketClient) void {
            s.removeClient(c);
        }
        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    server.clients_mutex.lockUncancelable(io);
    var remove_fut = try io.concurrent(Probe.remove, .{ &server, &stand_in });
    try std.testing.expect(parkedOnClientsLock(&server));
    var cancel_fut = try io.concurrent(Probe.cancel, .{ io, &remove_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    server.clients_mutex.unlock(io);
    cancel_fut.await(io);
    remove_fut.await(io);

    // Nothing else ever drops this entry, so a cancel that skipped the removal
    // would keep a dead client (and its slot) for the life of the server — and
    // every later `broadcast` would log a send error into it.
    try std.testing.expectEqual(@as(usize, 0), server.clientCount());
}

test "WebSocketServer: clientCount reports the live count, not a lock verdict" {
    const io = std.testing.io;
    var server = WebSocketServer.init(std.testing.allocator, io, 19005);
    defer deinitWithStandInClients(&server, io);

    var stand_in = standInClient(&server, io);
    try server.addClient(&stand_in);

    const Probe = struct {
        fn count(s: *WebSocketServer) usize {
            return s.clientCount();
        }
    };

    server.clients_mutex.lockUncancelable(io);
    var count_fut = try io.concurrent(Probe.count, .{&server});
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    server.clients_mutex.unlock(io);
    const live = count_fut.await(io);

    // A contended lock is not "no clients": reporting 0 here is a number the
    // caller cannot tell apart from an empty registry (the monitor prints it as
    // `clients`).
    try std.testing.expectEqual(@as(usize, 1), live);
}

test "WebSocketServer: an abandoned broadcast is counted, not silent" {
    const io = std.testing.io;
    var server = WebSocketServer.init(std.testing.allocator, io, 19006);
    defer deinitWithStandInClients(&server, io);

    const Probe = struct {
        fn cast(s: *WebSocketServer) void {
            s.broadcast("metrics");
        }
        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    server.clients_mutex.lockUncancelable(io);
    var cast_fut = try io.concurrent(Probe.cast, .{&server});
    try std.testing.expect(parkedOnClientsLock(&server));
    var cancel_fut = try io.concurrent(Probe.cancel, .{ io, &cast_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    server.clients_mutex.unlock(io);
    cancel_fut.await(io);
    cast_fut.await(io);

    // The message reached nobody, and `broadcast` returns `void` — there is no
    // channel to report a fan-out that never started. It has to be loud instead.
    try std.testing.expectEqual(@as(u64, 1), server.droppedBroadcasts());
}

/// Poll (bounded) then read, until `want` shows up in `out` or the deadline
/// passes. Returns the bytes read. Same shape as `api/Server.zig`'s `wsProbe`.
fn readUntilSeen(stream: *std.Io.net.Stream, out: []u8, want: []const u8) usize {
    var got: usize = 0;
    var tries: usize = 0;
    while (tries < 60) : (tries += 1) {
        if (got == out.len) break;
        var pfds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if ((std.posix.poll(&pfds, 100) catch 0) == 0) continue;
        const n = std.posix.read(stream.socket.handle, out[got..]) catch break;
        if (n == 0) break;
        got += n;
        if (std.mem.indexOf(u8, out[0..got], want) != null) break;
    }
    return got;
}

/// Bounded wait for the connection fiber to move the registry to `want` (the
/// handshake answers before the fiber has registered the client).
fn waitForClientCount(server: *WebSocketServer, want: usize) void {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.clientCount() == want) return;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err| {
            // A short wait only makes this wait shorter than intended; the
            // assertion after it reports what was actually observed.
            std.log.debug("[test] waitForClientCount sleep: {s}", .{@errorName(err)});
        };
    }
}

test "WebSocketServer: a live client is handshaken, pushed to, and dropped" {
    const io = std.testing.io;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var server = WebSocketServer.init(std.testing.allocator, io, 0);
    defer server.deinit();
    try server.start();
    defer server.stop();

    // Port 0 asks the kernel for a free port. A fixed port here is a shared
    // resource: `start` binds with `reuse_address`, and on macOS a second process
    // asking for the same number can be granted it too — the client's connection
    // then lands in *that* process's accept loop, which is exactly how a fixed
    // port made this test read 0 bytes while "its" server had already flushed a
    // 101 into a socket belonging to another run.
    const port = if (server.server) |*s| s.socket.address.getPort() else 0;
    try std.testing.expect(port != 0);

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // A minimal RFC 6455 upgrade request, in one write (the server reads the
    // request head with a single raw-posix `readSome`). The client side has to
    // flush for the same reason the server does.
    const handshake = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    _ = w.interface.writeAll(handshake) catch return error.HandshakeWriteFailed;
    w.interface.flush() catch return error.HandshakeWriteFailed;

    // 1. The server accepts the connection and registers the client — the
    //    server-side signal that the accept loop is live.
    waitForClientCount(&server, 1);
    var resp_buf: [512]u8 = undefined;
    const resp_len = readUntilSeen(&stream, &resp_buf, "\r\n\r\n");
    try std.testing.expectEqual(@as(usize, 1), server.clientCount());

    // 2. The handshake answer must actually reach the socket: `writeAll` alone
    //    only buffers what fits in the writer's 4096-byte buffer, and the whole
    //    response is ~129 bytes.
    if (std.mem.indexOf(u8, resp_buf[0..resp_len], "101 Switching Protocols") == null) {
        return error.HandshakeResponseMissing;
    }

    // 3. And a broadcast has to reach it — same buffering contract, in
    //    `WebSocketClient.sendFrame`.
    server.broadcast("ping");
    var frame_buf: [64]u8 = undefined;
    const frame_len = readUntilSeen(&stream, &frame_buf, "ping");
    if (frame_len < 6) {
        std.debug.print("[test] broadcast frame was {d} bytes: {any}\n", .{ frame_len, frame_buf[0..frame_len] });
        return error.BroadcastFrameMissing;
    }
    try std.testing.expectEqual(@as(u8, 0x81), frame_buf[0]); // FIN + text
    try std.testing.expectEqual(@as(u8, 4), frame_buf[1]); // unmasked, 4 bytes
    try std.testing.expectEqualStrings("ping", frame_buf[2..6]);
    // A delivered broadcast is not a dropped one.
    try std.testing.expectEqual(@as(u64, 0), server.droppedBroadcasts());

    // 4. The client hangs up, and the *server* drops the entry — nothing in this
    //    test removes it by hand.
    _ = w.interface.writeAll(&[_]u8{ 0x88, 0x00 }) catch return error.CloseWriteFailed;
    w.interface.flush() catch return error.CloseWriteFailed;
    waitForClientCount(&server, 0);
    try std.testing.expectEqual(@as(usize, 0), server.clientCount());
}

// ── Dispatching the loops must not depend on the io's async pool ─────────────
//
// `Group.async` has a backpressure fallback that runs the task body on the
// *calling* thread once `async_limit` is reached (`std/Io/Threaded.zig:2188-2191`
// → `groupAsyncEager`, `:2222-2226`; the limit defaults to `cpu_count - 1`,
// `:1641`), and `Threaded` releases the unit only when the body *returns*
// (`:1800-1802`). Both loops in this file — `acceptLoop` and `updateLoop` — are
// `while (self.is_running)` loops that only ever return because some *other*
// thread called `stop()`, so under that fallback the thread that called
// `start()` becomes the loop and never comes back to call `stop()`: the endpoint
// never serves and nothing can shut it down. On a 2-core runner the pool is one
// unit, which is why the runner hits this and a 10-core laptop does not.
//
// The tests below pin the limit on the io instead of hoping for the hardware:
// one pins the failure (a dispatch that cannot happen is reported and rolled
// back), one pins each loop's unit, and one runs a real client on an io whose
// async pool is empty — the runner's shape, on any machine.

/// A loopback port that was free a moment ago: bind port 0, read back the number
/// the kernel granted, close. The "the port is reusable again" assertions below
/// need the number a failed `start()` had bound, and a fixed literal would be a
/// resource shared with every other run and process.
fn freeLoopbackPort(io: std.Io) !u16 {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

/// `readUntilSeen` with an explicit wall-clock budget. The 60×100 ms it uses is
/// tuned for a handshake (milliseconds); the monitor's update loop only
/// re-broadcasts every 5 s, so its test needs a budget that spans a period and
/// still gives in instead of hanging the suite.
fn readUntilSeenWithin(stream: *std.Io.net.Stream, out: []u8, want: []const u8, budget_ms: i64) usize {
    const deadline = Time.monotonicNowMilliseconds() + budget_ms;
    var got: usize = 0;
    while (got < out.len and Time.monotonicNowMilliseconds() < deadline) {
        var pfds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if ((std.posix.poll(&pfds, 100) catch 0) == 0) continue;
        const n = std.posix.read(stream.socket.handle, out[got..]) catch break;
        if (n == 0) break;
        got += n;
        if (std.mem.indexOf(u8, out[0..got], want) != null) break;
    }
    return got;
}

test "WebSocketServer: a start() that cannot dispatch the accept loop reports it and rolls back" {
    const allocator = std.testing.allocator;
    // Not one concurrent unit available, so every dispatch answers
    // `error.ConcurrencyUnavailable` — the failure the eager `async` fallback
    // used to hide by running the accept loop on this thread instead.
    var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();

    const port = try freeLoopbackPort(io);
    var server = WebSocketServer.init(allocator, io, port);
    defer server.deinit();

    try std.testing.expectError(error.ConcurrencyUnavailable, server.start());
    // Rolled back rather than half-started: down, no listener, and it says so
    // instead of quietly pretending to serve.
    try std.testing.expect(!server.is_running);
    try std.testing.expect(server.server == null);

    // The listener really is closed: the number the failed `start()` had bound
    // (on 0.0.0.0) is bindable again.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
}

test "WebSocketMonitor: an update loop that cannot be dispatched fails start(), and the server half comes back down" {
    const allocator = std.testing.allocator;
    // Exactly one concurrent unit, and the WebSocket server's accept loop takes
    // it (a never-returning body holds its unit until it returns,
    // `std/Io/Threaded.zig:1800-1802`), so the monitor's own dispatch is the one
    // that cannot happen. That ordering is also the assertion that each loop
    // occupies a unit of its own rather than sharing the caller.
    var threaded = std.Io.Threaded.init(allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    const port = try freeLoopbackPort(io);
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    var monitor = WebSocketMonitor.init(allocator, io, port);
    defer monitor.deinit();

    try std.testing.expectError(error.ConcurrencyUnavailable, monitor.start(&modules));
    // The server half *had* started, so unwinding that is the whole job of the
    // rollback: the accept loop is told to stop and the listener is closed.
    try std.testing.expect(!monitor.is_running);
    try std.testing.expect(!monitor.ws_server.is_running);
    try std.testing.expect(monitor.ws_server.server == null);
    try std.testing.expect(monitor.modules == null);

    // `stop()` really did terminate the accept loop — it is blocked in `accept`,
    // and nothing else can have released the port.
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
}

test "WebSocketMonitor: a real client is handshaken and receives the update loop's metrics frame" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // A 2-core runner's default (`async_limit = cpu_count - 1`,
    // `std/Io/Threaded.zig:1641`) taken all the way down to nothing left over:
    // `Group.async` would have no choice but to run the loop on this thread, so
    // this test *is* the runner's shape, on a laptop that cannot reach the
    // limit by accident.
    var threaded = std.Io.Threaded.init(allocator, .{ .async_limit = .limited(0) });
    defer threaded.deinit();
    const io = threaded.io();

    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    var monitor = WebSocketMonitor.init(allocator, io, 0);
    defer monitor.deinit();
    // Returns at all: with the eager fallback this call would still be inside
    // the accept loop.
    try monitor.start(&modules);
    defer monitor.stop();

    const port = if (monitor.ws_server.server) |*s| s.socket.address.getPort() else 0;
    try std.testing.expect(port != 0);

    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    // A minimal RFC 6455 upgrade request, one write (see the live-client test
    // above for why both sides have to flush).
    const handshake = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    _ = w.interface.writeAll(handshake) catch return error.HandshakeWriteFailed;
    w.interface.flush() catch return error.HandshakeWriteFailed;

    // The accept path is live: the connection is registered.
    waitForClientCount(&monitor.ws_server, 1);
    try std.testing.expectEqual(@as(usize, 1), monitor.ws_server.clientCount());

    // The update path is live: its payload reaches this socket. The loop's first
    // broadcast can precede this client's registration — it runs at dispatch,
    // and nobody is connected yet — so the budget has to span one period of 5 s.
    // A frame is the only proof the loop is *running*, as opposed to dispatched.
    var frame_buf: [256]u8 = undefined;
    const want = "\"type\":\"metrics\"";
    const frame_len = readUntilSeenWithin(&stream, &frame_buf, want, 15_000);
    if (std.mem.indexOf(u8, frame_buf[0..frame_len], want) == null) {
        std.debug.print("[test] metrics frame was {d} bytes: {any}\n", .{ frame_len, frame_buf[0..frame_len] });
        return error.MetricsFrameMissing;
    }
    // It reached a client, so nothing was dropped on the way.
    try std.testing.expectEqual(@as(u64, 0), monitor.ws_server.droppedBroadcasts());
}

// ── The client's socket, and the registry lock across a fan-out ──────────────

/// A socket that was never connected to anything, as a `std.Io.net.Stream`.
/// Writing to it fails *in the syscall* (`ENOTCONN` → `error.SocketUnconnected`),
/// which is the write failure `sendFrame` has to name. `null` when the platform
/// refuses the socket, and the caller skips.
fn unconnectedStream() ?struct { stream: std.Io.net.Stream, fd: std.posix.socket_t } {
    const rc = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    const fd: std.posix.socket_t = @intCast(rc);
    return .{
        .stream = .{ .socket = .{ .handle = fd, .address = undefined } },
        .fd = fd,
    };
}

/// One end of a `socketpair` (the client's side) plus the peer end, so a test can
/// drive a client's socket with no network and no port to collide on.
const TestSocketPair = struct {
    stream: std.Io.net.Stream,
    peer_fd: std.posix.socket_t,

    fn open() ?TestSocketPair {
        var fds: [2]std.posix.socket_t = undefined;
        const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => return null,
        }
        return .{
            .stream = .{ .socket = .{ .handle = fds[0], .address = undefined } },
            .peer_fd = fds[1],
        };
    }

    /// Close the peer end. The client's end is owned by whoever took `stream`
    /// (the server, once the client is registered; the test otherwise).
    fn closePeer(self: *const TestSocketPair) void {
        _ = std.posix.system.close(self.peer_fd);
    }

    /// Read up to `want` bytes off the peer end (bounded, so a wedged writer
    /// fails the test instead of hanging the suite).
    fn drain(self: *const TestSocketPair, want: usize) usize {
        var got: usize = 0;
        var buf: [4096]u8 = undefined;
        var idle: usize = 0;
        while (got < want and idle < 500) : (idle += 1) {
            var pfds = [_]std.posix.pollfd{.{ .fd = self.peer_fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if ((std.posix.poll(&pfds, 20) catch 0) == 0) continue;
            const n = std.posix.read(self.peer_fd, &buf) catch break;
            if (n == 0) break;
            got += n;
        }
        return got;
    }
};

/// A registered client that exists only for the registry — identity and
/// placement, never a write. `WebSocketClient.init` has to run because registry
/// paths read the client's own state (`refs` and `write_mutex`), which an
/// `undefined` stand-in leaves as garbage.
fn standInClient(server: *WebSocketServer, io: std.Io) WebSocketClient {
    return WebSocketClient.init(std.testing.allocator, .{ .socket = .{ .handle = -1, .address = undefined } }, io, server);
}

test "WebSocketClient: a write failure is named for the write, and the flag stops lying" {
    const io = std.testing.io;
    const sock = unconnectedStream() orelse return error.SkipZigTest;
    defer _ = std.posix.system.close(sock.fd);

    var server = WebSocketServer.init(std.testing.allocator, io, 0);
    defer server.deinit();

    var client = WebSocketClient.init(std.testing.allocator, sock.stream, io, &server);
    try std.testing.expect(client.is_connected);

    // The write itself fails (`SocketUnconnected`, not `NotConnected`): the peer
    // never went away, the socket was never usable. Naming that "not connected"
    // leaves the caller unable to tell a dead peer from a transient failure.
    const result: anyerror!void = client.sendText("hello");
    try std.testing.expectError(error.WriteFailed, result);

    // ... and the object must stop claiming to be connected: the header may
    // already be on the wire, so the stream is mid-frame and unusable for a
    // later frame. A caller that retries on a still-`is_connected` client is
    // writing into a socket that has already failed.
    try std.testing.expect(!client.is_connected);
}

test "WebSocketServer: broadcast keeps the registry lock off the socket write" {
    const io = std.testing.io;
    const pair = TestSocketPair.open() orelse return error.SkipZigTest;
    defer pair.closePeer();
    var server = WebSocketServer.init(std.testing.allocator, io, 0);
    // `deinit` releases the registered client, which is what closes its end.
    defer server.deinit();

    const client = try std.testing.allocator.create(WebSocketClient);
    client.* = WebSocketClient.init(std.testing.allocator, pair.stream, io, &server);
    try server.addClient(client);
    try std.testing.expectEqual(@as(usize, 1), server.clientCount());

    const payload = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'p');

    const Probe = struct {
        var cast_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var probe_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
        var observed: usize = 0;

        fn cast(s: *WebSocketServer, message: []const u8) void {
            cast_started.store(true, .release);
            s.broadcast(message);
        }
        fn count(s: *WebSocketServer) void {
            observed = s.clientCount();
            probe_done.store(true, .release);
        }
    };
    Probe.cast_started.store(false, .release);
    Probe.probe_done.store(false, .release);
    Probe.observed = 0;

    // The peer never reads, so the fan-out parks in the socket write once the
    // send buffer fills (macOS socketpair: 8 KiB). This is the window in which
    // the registry lock used to be held — the peer is slow, and add/remove/count
    // all wait on that same lock, `addClient`/`removeClient` uncancelably.
    var cast_fut = try io.concurrent(Probe.cast, .{ &server, payload });
    var spins: usize = 0;
    while (spins < wait_for_parked_fiber_rounds and !Probe.cast_started.load(.acquire)) : (spins += 1) {
        std.atomic.spinLoopHint();
    }
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(300), .awake);

    var count_fut = try io.concurrent(Probe.count, .{&server});
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(400), .awake);
    // Read before the drain: under the old shape the count fiber is still parked
    // behind the lock the fan-out holds for the whole write.
    const counted_while_writing = Probe.probe_done.load(.acquire);

    // Drain the peer end so the writer can finish — a fiber parked in a socket
    // write must never outlive the test. The frame is a 10-byte header (opcode +
    // 127 + u64 length, since the payload needs more than 16 bits) plus payload.
    const frame_len = payload.len + 10;
    const drained = pair.drain(frame_len);
    cast_fut.await(io);
    count_fut.await(io);

    try std.testing.expectEqual(@as(usize, frame_len), drained);
    try std.testing.expect(counted_while_writing);
    try std.testing.expectEqual(@as(usize, 1), Probe.observed);
}

test "WebSocketServer: deinit waits for the registry lock instead of freeing underneath it" {
    const io = std.testing.io;
    var server = WebSocketServer.init(std.testing.allocator, io, 0);

    const Probe = struct {
        var deinit_returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        fn drop(s: *WebSocketServer) void {
            s.deinit();
            deinit_returned.store(true, .release);
        }
        fn unlock(s: *WebSocketServer, owner_io: std.Io) void {
            s.clients_mutex.unlock(owner_io);
        }
    };
    Probe.deinit_returned.store(false, .release);

    server.clients_mutex.lockUncancelable(io);
    var drop_fut = try io.concurrent(Probe.drop, .{&server});
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake);
    const returned_under_the_lock = Probe.deinit_returned.load(.acquire);
    var unlock_fut = try io.concurrent(Probe.unlock, .{ &server, io });
    unlock_fut.await(io);
    drop_fut.await(io);

    // A destructor has to run to completion. Answering "someone holds the
    // registry" with `tryLock` and then freeing the client list anyway is memory
    // unsafety, not a teardown — `im/BufferPool.zig`'s and `cache/Lru.zig`'s
    // rule is that it waits.
    try std.testing.expect(!returned_under_the_lock);
    try std.testing.expect(Probe.deinit_returned.load(.acquire));
}
