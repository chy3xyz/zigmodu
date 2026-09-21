const std = @import("std");
const Time = @import("Time.zig");
const sockread = @import("sockread.zig");
const TypedEventBus = @import("EventBus.zig").TypedEventBus;
const ArrayList = std.array_list.Managed;

const WAL = @import("eventbus/WAL.zig").WAL;
const WALConfig = @import("eventbus/WAL.zig").WALConfig;
const DLQ = @import("eventbus/DLQ.zig").DLQ;
const DLQConfig = @import("eventbus/DLQ.zig").DLQConfig;
const RequeuedMessage = @import("eventbus/DLQ.zig").RequeuedMessage;
const Partitioner = @import("eventbus/Partitioner.zig").ConsistentHashPartitioner;
const NetworkTransport = @import("cluster/NetworkTransport.zig");
const ClusterAuth = @import("cluster/TlsTransport.zig").ClusterAuth;

// ── Wire format for peer traffic (both directions) ──────────────────────────
//
//     [4-byte big-endian len][mac: 32 raw bytes][json]   `cluster_secret` set
//     [4-byte big-endian len][json]                      no secret ("bare")
//
// `len` counts everything after it, so the reader's single `readFull(len)` gets
// the whole message. Before this the bus had **no framing at all**: one
// `readSome` was treated as one message, which lost data both ways — a message
// split across two reads failed to parse, and two messages in one read had the
// second one silently dropped. A MAC over an unframed message cannot be
// verified for the same reason (a split read gives a partial body, so a
// legitimate event would be dropped), which is why framing came first
// (`docs/dev/cluster-auth-design.md` §3).
//
// The MAC covers the **json bytes only**. Unlike the Raft port there is no tag
// byte on this surface — the JSON carries its own `"topic"` — so `json` is the
// whole message body, and the raw 32-byte tag is compared with
// `ClusterAuth.timingSafeEql` exactly as `RaftTransport.verifiedRecv` does.
//
// The MAC key is **derived from the identity the frame claims**, instead of
// being one cluster-wide key:
//
//     claim      = json `"source"`                    (what the peer says it is)
//     key(claim) = HMAC-SHA256(cluster_secret, claim)
//     mac        = HMAC-SHA256(key(claim), json)
//
// So a peer that claims `node-b` has to hold `key(node-b)`, and the claim is
// only as forgeable as `cluster_secret` itself — anyone holding the secret can
// still impersonate any node, which is inherent to a cluster-wide PSK and
// outside the L1 threat model. What it buys is that the claim is *bound to the
// framing*: the sender cannot mint a frame for someone else's id without the
// secret, and the receiver no longer trusts a self-description it never
// checked. (An address lookup cannot do this job: `self.nodes` holds the
// `host:listen-port` we dialled, while an inbound peer is `dialer_ip:ephemeral`
// — see `docs/dev/cluster-auth-design.md` §14.)
//
// A signed frame therefore also has to carry a strictly increasing `"seq"`: the
// MAC covers the json, so the sequence sits inside the authenticated region and
// a captured frame cannot be replayed at a receiver that already accepted a
// later one from the same claim. Bare frames have no sequence check — without a
// secret there is no authenticated region to put it in.
//
// `setRecvTimeout` bounds each inbound read, so a peer that connects and then
// sends nothing cannot hold a fiber (`stop()` waits on those fibers). The bound
// is idle-based and sits well above `heartbeat_interval_ms`, which is why a
// connection that is merely quiet — a healthy peer between heartbeats — is not
// torn down.

/// Length of the `mac32` the send side writes and the receive side strips.
const auth_mac_bytes = 32;

/// Idle bound on one inbound read: a peer may be quiet for this long before the
/// connection is dropped. `SO_RCVTIMEO` bounds **each** blocking read, and a
/// healthy peer sends a heartbeat every `heartbeat_interval_ms`, so the bound
/// only fires for a peer that is actually silent.
const default_inbound_idle_timeout_ms: u32 = 30_000;

/// How often `heartbeatLoop` writes a heartbeat to every connected node. Must
/// stay comfortably below `default_inbound_idle_timeout_ms`, which is what makes
/// the idle bound safe for a long-lived stream.
const heartbeat_interval_ms: u32 = 5_000;

/// Cap on one frame body (`mac32 + json`). The same 1 MiB
/// `NetworkTransport.MAX_MESSAGE_SIZE` puts on a Raft frame: same cluster, same
/// kind of socket, and it is checked **before** the body is buffered, so a peer
/// cannot make this node allocate without bound.
const max_frame_size = NetworkTransport.MAX_MESSAGE_SIZE;

/// Distributed Event Bus for cross-node communication
/// Allows events to be published and subscribed across multiple processes/machines
pub const DistributedEventBus = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    local_bus: TypedEventBus(NetworkEvent),
    topic_callbacks: std.StringHashMap(std.ArrayList(TopicHandler)),
    nodes: ArrayList(Node),
    listener: ?std.Io.net.Server,
    is_running: bool,
    node_id: []const u8,
    heartbeat_thread: ?std.Thread,
    /// Owns accept/handle/heartbeat fibers; awaited in `stop()`.
    fiber_group: std.Io.Group,

    /// 32-byte pre-shared key authenticating every peer frame in **both**
    /// directions. `null` (the default) means bare frames — length-prefixed
    /// with no MAC, the state `start()` warns about and `ClusterBootstrap`
    /// refuses for a multi-node cluster.
    cluster_secret: ?[32]u8 = null,

    /// Idle bound handed to `sockread.setRecvTimeout` for every inbound
    /// connection, so a peer that connects and then sends nothing cannot hold a
    /// handle/fiber forever. 0 disables it (the pre-§14 behaviour).
    inbound_idle_timeout_ms: u32 = default_inbound_idle_timeout_ms,

    /// Highest `"seq"` accepted per claimed source id, **authenticated path
    /// only**: an entry is created after the frame's MAC verified, so this table
    /// cannot be grown by anyone who does not hold `cluster_secret`.
    peer_seqs: std.StringHashMap(u64),

    /// Guards `peer_seqs`: `handleConnection` runs on several fibers at once.
    seq_lock: std.Io.Mutex = .init,

    /// Next `"seq"` to stamp on an outbound frame (see the wire format above).
    /// Seeded from the host's monotonic clock so that a restarted sender keeps
    /// moving forward rather than colliding with its own history; see
    /// `forgetPeerSeq` for the cases that still roll back.
    next_seq: std.atomic.Value(u64),

    /// Optional distributed components
    partitioner: ?*Partitioner = null,
    wal: ?*WAL = null,
    dlq: ?*DLQ = null,

    /// Soft backpressure: skip fan-out after this many consecutive send failures per node.
    max_send_failures: u32 = 8,

    /// True while the DLQ retry fiber is running.
    dlq_retry_running: bool = false,

    pub const NetworkEvent = struct {
        topic: []const u8,
        payload: []const u8,
        source_node: []const u8,
        timestamp: i64,
        /// Monotonic per sending process, and part of the authenticated region:
        /// a receiver drops a frame that does not move this forward for its
        /// claimed source. 0 when the field is absent (bare frames, or events
        /// rebuilt from the WAL, which never go on the wire).
        seq: u64 = 0,
    };

    /// Topic subscription handler — plain fn or context-carrying callback.
    pub const TopicHandler = union(enum) {
        plain: *const fn (NetworkEvent) void,
        with_ctx: struct {
            ctx: *anyopaque,
            func: *const fn (*anyopaque, NetworkEvent) void,
        },

        fn invoke(self: TopicHandler, event: NetworkEvent) void {
            switch (self) {
                .plain => |f| f(event),
                .with_ctx => |w| w.func(w.ctx, event),
            }
        }
    };

    const Node = struct {
        id: []const u8,
        address: std.Io.net.IpAddress,
        socket: ?std.Io.net.Stream,
        last_seen: i64,
        send_failures: u32 = 0,
        /// Serialises writes to `socket`. `publish` (a request thread) and
        /// `heartbeatLoop` (a fiber) can target the same peer at the same time;
        /// framing bounds the damage of interleaved writes to "one corrupt frame
        /// → verification fails → connection dropped", which is still wrong.
        /// An `Io.Mutex` rather than a spin lock: the guarded section is a
        /// blocking `writeAll`.
        write_lock: std.Io.Mutex = .init,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, node_id: []const u8) !Self {
        const id_copy = try allocator.dupe(u8, node_id);
        errdefer allocator.free(id_copy);
        return .{
            .allocator = allocator,
            .io = io,
            .local_bus = TypedEventBus(NetworkEvent).init(allocator),
            .topic_callbacks = std.StringHashMap(std.ArrayList(TopicHandler)).init(allocator),
            .nodes = ArrayList(Node).init(allocator),
            .listener = null,
            .is_running = false,
            .node_id = id_copy,
            .heartbeat_thread = null,
            .fiber_group = .init,
            .peer_seqs = std.StringHashMap(u64).init(allocator),
            // Milliseconds since the host booted, in the low bits: a *process*
            // restart on a host that did not reboot therefore resumes ahead of
            // the counter it had reached, so peers keep accepting it. A reboot
            // moves this backwards (see `forgetPeerSeq`).
            .next_seq = std.atomic.Value(u64).init(@intCast(Time.monotonicNowMilliseconds())),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.free(self.node_id);
        self.local_bus.deinit();

        var cb_iter = self.topic_callbacks.iterator();
        while (cb_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.topic_callbacks.deinit();

        var seq_iter = self.peer_seqs.iterator();
        while (seq_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.peer_seqs.deinit();

        for (self.nodes.items) |*node| {
            if (node.socket) |sock| {
                sock.close(self.io);
            }
            self.allocator.free(node.id);
        }
        self.nodes.deinit();
        self.* = undefined;
    }

    /// Start listening for incoming connections
    pub fn start(self: *Self, port: u16) !void {
        if (self.is_running) return;

        const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
        self.listener = try address.listen(self.io, .{});
        self.is_running = true;

        std.log.info("[DistributedEventBus] Node '{s}' listening on port {d}", .{ self.node_id, port });

        // A standalone `start(port)` has no cluster shape to judge, so this is a
        // warning and not a refusal: `ClusterBootstrap.start()` owns the
        // enforced gate (multi-node + real transport + no key =
        // `error.ClusterAuthRequired`), and a single-node bus legitimately has
        // no peer to authenticate. All this entry point can honestly do is be
        // loud, so a standalone deployment is not silently open.
        if (self.cluster_secret == null) {
            std.log.warn(
                "[DistributedEventBus] node '{s}' listening on port {d} WITHOUT a cluster_secret: any host that can reach " ++
                    "this port may publish events, and every frame is trusted as whatever `source` it claims — " ++
                    "`__heartbeat` included. Call `setClusterSecret` (`ClusterBootstrap` does it for an enforced " ++
                    "configuration).",
                .{ self.node_id, port },
            );
        }

        // Start accept loop and heartbeat asynchronously as members of
        // `fiber_group` so their futures do not leak.
        self.fiber_group.async(self.io, acceptLoop, .{self});
        self.heartbeat_thread = null;
        self.fiber_group.async(self.io, heartbeatLoop, .{self});

        // Start DLQ retry fiber if a DLQ has been configured.
        if (self.dlq != null and !self.dlq_retry_running) {
            self.dlq_retry_running = true;
            self.fiber_group.async(self.io, dlqRetryLoop, .{self});
        }
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        self.heartbeat_thread = null;
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
        // Drain accept/handle/heartbeat fibers; idempotent.
        self.fiber_group.await(self.io) catch |err| std.log.err("[DEB] Fiber await failed: {}", .{err});
    }

    /// Apply `inbound_idle_timeout_ms` as `SO_RCVTIMEO`.
    ///
    /// This is `sockread.setRecvTimeout`'s option with one deliberate
    /// difference: a failure is **logged and survived**. That helper's own
    /// `catch` cannot fire, because `std.posix.setsockopt` maps `EINVAL` to
    /// `unreachable` — and macOS answers `EINVAL` for `SO_RCVTIMEO` on an
    /// AF_UNIX socket whose peer end has already closed, which is exactly the
    /// "connected, then vanished" peer this bound is about. Calling the helper
    /// from the bus would turn that peer into a panic instead of a dropped
    /// connection. The peer being already gone is also why a failure here is
    /// benign: the next read returns EOF immediately.
    fn boundInboundRead(self: *Self, conn: std.Io.net.Stream) void {
        const timeout_ms = self.inbound_idle_timeout_ms;
        if (timeout_ms == 0) return;
        const tv = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        const rc = std.posix.system.setsockopt(
            conn.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            &tv,
            @sizeOf(std.posix.timeval),
        );
        if (rc != 0) {
            std.log.warn(
                "[DEB] SO_RCVTIMEO ({d} ms) not applied (errno {s}): a peer that connects and then says nothing can hold this connection",
                .{ timeout_ms, @tagName(std.posix.errno(rc)) },
            );
        }
    }

    fn acceptLoop(self: *Self) void {
        while (self.is_running) {
            if (self.listener) |*l| {
                const conn = l.accept(self.io) catch |err| {
                    if (self.is_running) {
                        std.log.err("[DistributedEventBus] Accept error: {}", .{err});
                    }
                    continue;
                };

                // Handle connection in the shared group. Use `concurrent` (not
                // `async`): handleConnection blocks on peer reads, and `async`'s
                // eager fallback at async_limit would run it on the accept
                // thread and freeze the accept loop.
                self.fiber_group.concurrent(self.io, handleConnection, .{ self, conn }) catch |err| {
                    std.log.warn("[DistributedEventBus] connection rejected (concurrent limit): {}", .{err});
                    conn.close(self.io);
                    continue;
                };
            }
        }
    }

    fn heartbeatLoop(self: *Self) void {
        while (self.is_running) {
            // Send heartbeat to all connected nodes (disabled)
            self.sendHeartbeat();
            // The interval a healthy peer is *quiet* for, which is why the
            // inbound idle bound is an order of magnitude larger.
            std.Io.sleep(self.io, .{ .nanoseconds = @as(u64, heartbeat_interval_ms) * 1_000_000 }, .real) catch break;
        }
    }

    fn sendHeartbeat(self: *Self) void {
        const event = NetworkEvent{
            .topic = "__heartbeat",
            .payload = self.node_id,
            .source_node = self.node_id,
            .timestamp = Time.monotonicNowSeconds(),
            .seq = self.nextSeq(),
        };
        // Serialized once for every peer, framed per peer: the frame carries the
        // MAC, and the MAC only has to cover the json.
        const json = serializeEventAlloc(self.allocator, event) catch |err| {
            std.log.warn("[DistributedEventBus] Heartbeat not sent: {}", .{err});
            return;
        };
        defer self.allocator.free(json);

        for (self.nodes.items) |*node| {
            if (node.socket != null) {
                self.sendFramed(node, json) catch |err| {
                    std.log.warn("[DistributedEventBus] Heartbeat failed to node {s}: {}", .{ node.id, err });
                };
            }
        }
    }

    /// The next `"seq"` this node stamps on an outbound frame. Atomic because
    /// `publish` is called from arbitrary threads while `heartbeatLoop` stamps
    /// its own frame from a fiber: the counter has to be strictly increasing
    /// **per receiver**, and one global counter is the simplest way to be.
    fn nextSeq(self: *Self) u64 {
        return self.next_seq.fetchAdd(1, .monotonic) + 1;
    }

    /// A frame claiming `claim` is keyed with `HMAC-SHA256(cluster_secret,
    /// claim)` instead of one cluster-wide key, so a valid MAC also proves the
    /// sender holds the key for the identity it named (see the wire format at
    /// the top of this file).
    fn identityKey(cluster_secret: [32]u8, claim: []const u8) [32]u8 {
        var key: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&key, claim, &cluster_secret);
        return key;
    }

    /// Write one already-serialized frame to `node`'s socket, serialised against
    /// every other writer to the same peer.
    ///
    /// `publish` (a request thread) and `heartbeatLoop` (a fiber) both target
    /// connected peers, and two `writeAll`s interleaving on one socket is a
    /// corrupt frame — after framing it is no longer a *silent* one (the length
    /// prefix bounds the damage to "MAC fails, connection dropped"), but it drops
    /// a live connection and loses the event, so the write is serialised instead.
    fn sendFramed(self: *Self, node: *Node, json: []const u8) !void {
        const sock = node.socket orelse return error.NotConnected;
        node.write_lock.lock(self.io) catch return error.WriteLockUnavailable;
        defer node.write_lock.unlock(self.io);
        // The json was rendered from an event whose `source_node` is this node,
        // so the identity the peer will derive the key from is our own id.
        try self.sendEventFrame(sock, json, self.node_id);
    }

    /// Frame `json` for the wire (see the wire-format comment at the top of this
    /// file) and write it with a single `writeAll`, so the whole message — MAC
    /// included — leaves as one call. `identity` is the `"source"` the json
    /// carries; the peer derives its verification key from exactly that value.
    ///
    /// The frame is built in one heap buffer sized for this event. The old send
    /// path rendered into a fixed `[4096]u8` scratch array and wrote whatever
    /// came out; `serializeEvent` reports overflow by returning an empty slice,
    /// so an event bigger than the array was written as `""` — nothing on the
    /// wire, no failure recorded (`docs/dev/cluster-auth-design.md` §14).
    fn sendEventFrame(self: *Self, sock: std.Io.net.Stream, json: []const u8, identity: []const u8) !void {
        const mac_len: usize = if (self.cluster_secret != null) auth_mac_bytes else 0;
        const body_len = mac_len + json.len;
        if (body_len > max_frame_size) return error.MessageTooLarge;

        const frame = try self.allocator.alloc(u8, 4 + body_len);
        defer self.allocator.free(frame);
        std.mem.writeInt(u32, frame[0..4], @intCast(body_len), .big);
        if (self.cluster_secret) |secret| {
            const key = identityKey(secret, identity);
            std.crypto.auth.hmac.sha2.HmacSha256.create(frame[4..][0..auth_mac_bytes], json, &key);
        }
        @memcpy(frame[4 + mac_len ..], json);

        var write_buf: [4096]u8 = undefined;
        var w = sock.writer(self.io, &write_buf);
        try w.interface.writeAll(frame);
        try w.interface.flush();
    }

    /// The receive half of `sendEventFrame`: return the json inside one frame
    /// body, or null when the frame must be dropped. A drop is terminal for the
    /// connection — the stream cannot be resynchronised past an unauthenticated
    /// frame — which is exactly how `RaftTransport.handleConnection` treats one.
    ///
    /// The MAC is a **prefix** here (`[mac32][json]`, the inverse of the Raft
    /// port's trailing tag): the length is known first, so which bytes are the
    /// tag does not have to be guessed from the body's tail. Its key is derived
    /// from the `"source"` the frame **claims**, which is why this reads that one
    /// field out of an otherwise unverified frame: a claim is only an input to
    /// the KDF, and it has to be *right* — a forged claim derives a key the
    /// sender cannot produce a tag for. Nothing from that scrape is dispatched;
    /// the caller re-parses the event out of the verified bytes.
    ///
    /// The drops are the `error.ClusterAuthFailed` cases: a body too short to
    /// carry a MAC (a bare frame from a peer that has no secret — mixed-version
    /// clusters cut over hard), a frame whose claim cannot be read, and a MAC
    /// that does not match.
    fn openEventFrame(self: *Self, scratch: std.mem.Allocator, body: []const u8) ?[]const u8 {
        const secret = self.cluster_secret orelse return body;
        if (body.len < auth_mac_bytes + 1) {
            std.log.debug("[DEB] dropping connection: {d}-byte body carries no MAC", .{body.len});
            return null;
        }
        const json = body[auth_mac_bytes..];
        const claim = claimedSource(scratch, json) orelse {
            std.log.debug("[DEB] dropping connection: frame names no source to key the MAC with", .{});
            return null;
        };
        // Raw bytes, the same reason `RaftTransport.verifiedRecv` is: the frame
        // carries the tag, raw, not `ClusterAuth.sign`'s hex rendering.
        const key = identityKey(secret, claim);
        var expected: [auth_mac_bytes]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, json, &key);
        if (!ClusterAuth.timingSafeEql(&expected, body[0..auth_mac_bytes])) {
            std.log.debug("[DEB] dropping connection: frame MAC does not verify for claim '{s}'", .{claim});
            return null;
        }
        return json;
    }

    /// The `"source"` a frame claims, read out of bytes that have **not** been
    /// authenticated yet. It is used for one thing only — choosing the KDF input
    /// — so a wrong or hostile value costs a failed MAC, not a mis-parsed event.
    /// The result is copied into `allocator`, which is the per-message arena on
    /// the connection path.
    fn claimedSource(allocator: std.mem.Allocator, json: []const u8) ?[]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
        defer parsed.deinit();
        const claim = jsonStringField(parsed.value, "source") orelse return null;
        return allocator.dupe(u8, claim) catch null;
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) void {
        defer conn.close(self.io);

        // Bound the **inbound read** — the same `SO_RCVTIMEO` bound Raft's
        // inbound side applies (`sockread.setRecvTimeout`,
        // `ElectionConfig.rpc_timeout_ms`). Without it a peer that connects and
        // then sends nothing holds this handle/fiber forever, and `stop()` waits
        // on those fibers in `fiber_group.await` — a cheap way to stall a node.
        //
        // The bound is per *read* and idle-based rather than per message: this
        // stream is long-lived (a healthy peer is quiet between heartbeats and
        // may be quiet for minutes after the last event), so any bound tighter
        // than `heartbeat_interval_ms` would tear down healthy connections. At
        // 6× the heartbeat interval it only fires for a peer that is *silent*,
        // and 0 still disables it.
        self.boundInboundRead(conn);

        // Use an Arena for parsing-related allocations that can be cleared per message
        var msg_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer msg_arena.deinit();

        // One body buffer for every frame on this connection: `resize` keeps the
        // capacity, so a peer sending many small frames allocates once.
        var body = ArrayList(u8).init(self.allocator);
        defer body.deinit();

        while (self.is_running) {
            const ma = msg_arena.allocator();

            // Raw reads (see core/sockread.zig); `readFull` is what makes the
            // stream a stream: the length prefix says how much the message is,
            // so a frame arriving in two reads is not two messages.
            var len_buf: [4]u8 = undefined;
            sockread.readFull(conn, &len_buf) catch |err| {
                // A peer that went away is routine, so this stays at debug
                // level; EOF is the normal end of a connection, and a receive
                // timeout (`EAGAIN`) is the silent peer this bounds.
                if (self.is_running) std.log.debug("[DEB] Read error: {}", .{err});
                break;
            };
            const body_len = std.mem.readInt(u32, &len_buf, .big);
            if (body_len == 0 or body_len > max_frame_size) {
                // Not recoverable: the stream is desynchronised (or the peer
                // speaks another wire version), and guessing where the next
                // frame starts would hand the parser arbitrary bytes.
                std.log.debug("[DEB] dropping connection: frame length {d} outside 1..{d}", .{ body_len, max_frame_size });
                break;
            }
            body.resize(body_len) catch |err| {
                std.log.debug("[DEB] dropping connection: cannot buffer a {d}-byte frame ({})", .{ body_len, err });
                break;
            };
            sockread.readFull(conn, body.items) catch |err| {
                if (self.is_running) std.log.debug("[DEB] Read error: {}", .{err});
                break;
            };

            // Authenticate before parsing the *event*: what `openEventFrame`
            // reads ahead of the MAC is only the claimed source, and that is a
            // KDF input — the event handed to `parseEvent` below comes from the
            // verified bytes. An unauthenticated frame therefore never becomes an
            // event, and it is not a *parse* failure either, so it does not go to
            // the DLQ: the connection is dropped.
            const data = self.openEventFrame(ma, body.items) orelse break;

            // Parse using our arena to avoid multiple tiny heap allocations
            if (parseEvent(ma, data)) |event| {
                if (!self.admitInbound(event)) {
                    _ = msg_arena.reset(.retain_capacity);
                    continue;
                }

                // Topic callback lookup is fast with StringHashMap
                self.publishToTopic(event);

                // Local bus dispatch
                self.local_bus.publish(event);
            } else if (self.dlq) |_| {
                // Deserialization failed — push to DLQ for later inspection
                self.pushParseFailureToDlq(data);
            }

            // Clear arena for next message - extremely fast
            _ = msg_arena.reset(.retain_capacity);
        }
    }

    /// The two gates after authentication: the replay sequence, then the
    /// heartbeat short-circuit. Both `continue` in `handleConnection`, so this
    /// returns true only for a frame that gets dispatched.
    fn admitInbound(self: *Self, event: NetworkEvent) bool {
        // Only the authenticated path carries a sequence (it is part of the MAC'd
        // region); a bare frame has nothing to compare.
        if (self.cluster_secret != null and !self.acceptSeq(event.source_node, event.seq)) {
            std.log.debug(
                "[DEB] dropping frame from '{s}' with seq {d}: not ahead of the last accepted one",
                .{ event.source_node, event.seq },
            );
            return false;
        }
        // A frame from a claim we accept still advances that claim's high-water
        // mark above, so a heartbeat counts as being alive; it is just not
        // dispatched.
        return !std.mem.eql(u8, event.topic, "__heartbeat");
    }

    /// Strictly-increasing per-claim sequence check — the replay defence for the
    /// authenticated path.
    ///
    /// The high-water mark is **not** reset when a peer reconnects: a connection
    /// is not a unit of freshness (an observer can open its own connection and
    /// replay whatever it captured), so a claim's history outlives its sockets.
    /// The residual is written down in `docs/dev/cluster-auth-design.md` §14:
    /// a captured frame the receiver has *not* accepted yet — sent on a
    /// connection that had already gone away — is still replayable once.
    ///
    /// Anything reaching this function has already had its MAC verified against
    /// the key for `claim`, so the table cannot be grown by an unauthenticated
    /// peer no matter how many connections it opens.
    fn acceptSeq(self: *Self, claim: []const u8, seq: u64) bool {
        self.seq_lock.lock(self.io) catch return false;
        defer self.seq_lock.unlock(self.io);

        const gop = self.peer_seqs.getOrPut(claim) catch return false;
        if (gop.found_existing) {
            if (seq <= gop.value_ptr.*) return false;
        } else {
            // The table owns its keys; `claim` lives in the caller's arena.
            gop.key_ptr.* = self.allocator.dupe(u8, claim) catch {
                _ = self.peer_seqs.remove(claim);
                return false;
            };
        }
        gop.value_ptr.* = seq;
        return true;
    }

    /// Forget the sequence remembered for `claim`, so that node's next frame is
    /// admitted whatever it carries.
    ///
    /// This is the manual escape hatch for the one thing the counter cannot tell
    /// apart from a replay: a sender whose own sequence went *backwards*, i.e. a
    /// host reboot resetting the monotonic seed (`next_seq`) while we stayed up.
    /// It reopens the replay window for that claim until the peer's next frame,
    /// so nothing on the receive path calls it.
    pub fn forgetPeerSeq(self: *Self, claim: []const u8) void {
        self.seq_lock.lock(self.io) catch |err| {
            std.log.warn("[DistributedEventBus] forgetPeerSeq('{s}') not applied: {}", .{ claim, err });
            return;
        };
        defer self.seq_lock.unlock(self.io);
        if (self.peer_seqs.fetchRemove(claim)) |entry| self.allocator.free(entry.key);
    }

    /// One field of a json object, or null when `value` is not an object or the
    /// key is absent.
    fn jsonField(value: std.json.Value, key: []const u8) ?std.json.Value {
        const object = switch (value) {
            .object => |o| o,
            else => return null,
        };
        return object.get(key);
    }

    fn jsonStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
        return switch (jsonField(value, key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    /// `"time"` in what this bus writes is an integer; a string is still read
    /// because the field used to be scraped as text. Unreadable or absent → 0.
    fn jsonTimestamp(value: std.json.Value) i64 {
        return switch (jsonField(value, "time") orelse return 0) {
            .integer => |i| i,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
            else => 0,
        };
    }

    /// Absent or nonsensical → 0, which the replay check treats as "the oldest
    /// sequence there is": it is accepted once for a claim and never again.
    fn jsonSeq(value: std.json.Value) u64 {
        return switch (jsonField(value, "seq") orelse return 0) {
            .integer => |i| if (i > 0) @intCast(i) else 0,
            .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
            else => 0,
        };
    }

    /// Parse one event out of `data`, copying its fields into `allocator` (on the
    /// connection path: the per-message arena). Null means "not an event", which
    /// the caller records in the DLQ.
    ///
    /// This replaced a substring matcher (`extractJsonValue`) that looked for the
    /// literal `"topic"` / `"payload"` / `"source"` anywhere in the bytes, so
    /// anything a *payload* contained steered the parse: a payload of
    /// `y","source":"node-b` came back as an event **from `node-b`**. Real
    /// parsing also makes the injected-field shape an error rather than a silent
    /// half-message — `std.json`'s default duplicate-key policy rejects it, so
    /// the frame lands in the DLQ instead of being delivered as somebody else.
    ///
    /// Cost per message: one `std.json` tree, allocated from `allocator` and
    /// released again before this returns (`Parsed.deinit`), so on the connection
    /// path it is the arena that already existed — capacity, not growth.
    fn parseEvent(allocator: std.mem.Allocator, data: []const u8) ?NetworkEvent {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
        defer parsed.deinit();

        const topic = jsonStringField(parsed.value, "topic") orelse return null;
        const payload = jsonStringField(parsed.value, "payload") orelse return null;
        const source = jsonStringField(parsed.value, "source") orelse return null;

        return NetworkEvent{
            .topic = allocator.dupe(u8, topic) catch return null,
            .payload = allocator.dupe(u8, payload) catch return null,
            .source_node = allocator.dupe(u8, source) catch return null,
            .timestamp = jsonTimestamp(parsed.value),
            .seq = jsonSeq(parsed.value),
        };
    }

    /// Publish event to all connected nodes
    pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void {
        // Write to WAL for crash recovery if configured
        if (self.wal) |w| {
            _ = w.append(.{
                .topic = topic,
                .payload = payload,
                .source_node = self.node_id,
                .timestamp_ms = Time.monotonicNowMilliseconds(),
            }) catch |err| {
                std.log.err("[DistributedEventBus] WAL append failed: {}", .{err});
            };
        }

        const event = NetworkEvent{
            .topic = topic,
            .payload = payload,
            .source_node = self.node_id,
            .timestamp = Time.monotonicNowSeconds(),
            // Stamped on the way out and part of the MAC'd region: a receiver
            // keeps the highest it has seen per claim, so a replayed frame does
            // not reach a subscriber twice.
            .seq = self.nextSeq(),
        };

        // Serialize once for every peer (the frame is built per peer in
        // `sendEventFrame`, because the MAC is part of it).
        const json = try serializeEventAlloc(self.allocator, event);
        defer self.allocator.free(json);

        // Route via partitioner if configured; otherwise broadcast.
        var routed = false;
        if (self.partitioner) |p| {
            if (p.route(topic)) |target_node| {
                if (std.mem.eql(u8, target_node, self.node_id)) {
                    // This node owns the partition — skip network fan-out.
                    routed = true;
                } else {
                    for (self.nodes.items) |*node| {
                        if (std.mem.eql(u8, node.id, target_node)) {
                            routed = self.sendToNode(node, topic, payload, json);
                            break;
                        }
                    }
                }
                if (routed) {
                    std.log.info("[DistributedEventBus] Partitioned event '{s}' -> node {s}", .{ topic, target_node });
                } else {
                    std.log.warn("[DistributedEventBus] Partition target '{s}' -> {s} unreachable, falling back to broadcast", .{ topic, target_node });
                }
            } else {
                std.log.warn("[DistributedEventBus] No partition target for '{s}'", .{topic});
            }
        }

        if (!routed) {
            // Broadcast to all connected nodes with soft backpressure on failing sockets
            for (self.nodes.items) |*node| {
                _ = self.sendToNode(node, topic, payload, json);
            }
        }

        // Also publish locally
        self.publishToTopic(event);
        self.local_bus.publish(event);
    }

    /// Send one event's json to a single node as a framed message. Returns true
    /// on success. On failure, increments the node failure counter. The message
    /// is pushed to the DLQ only when the cumulative failures reach
    /// `max_send_failures` (immediately before the node is quarantined).
    fn sendToNode(self: *Self, node: *Node, topic: []const u8, payload: []const u8, json: []const u8) bool {
        if (node.send_failures >= self.max_send_failures) return false;
        // `sendFramed` takes the node's write lock, so a publish from a request
        // thread cannot interleave with a heartbeat fiber on the same socket.
        self.sendFramed(node, json) catch |err| {
            if (node.socket) |sock| self.recordSendFailure(node, sock, topic, payload, err);
            return false;
        };
        node.send_failures = 0;
        return true;
    }

    fn recordSendFailure(self: *Self, node: *Node, sock: std.Io.net.Stream, topic: []const u8, payload: []const u8, err: anyerror) void {
        node.send_failures += 1;
        std.log.err("[DistributedEventBus] Failed to send to node {s} (failures={d}): {}", .{ node.id, node.send_failures, err });
        if (node.send_failures >= self.max_send_failures) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Send failed: {}", .{err}) catch "Send failed";
            self.pushToDlq(topic, payload, "SendError", err_msg);
            std.log.warn("[DistributedEventBus] Quarantining node {s} after {d} send failures", .{ node.id, node.send_failures });
            sock.close(self.io);
            node.socket = null;
        }
    }

    fn publishToTopic(self: *Self, event: NetworkEvent) void {
        if (self.topic_callbacks.get(event.topic)) |callbacks| {
            for (callbacks.items) |handler| {
                handler.invoke(event);
            }
        }
    }

    /// Subscribe to events on a specific topic (no context).
    pub fn subscribe(self: *Self, topic: []const u8, callback: *const fn (NetworkEvent) void) !void {
        try self.subscribeHandler(topic, .{ .plain = callback });
    }

    /// Subscribe with an opaque context pointer — used by ClusterMembership etc.
    pub fn subscribeWithContext(
        self: *Self,
        topic: []const u8,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque, NetworkEvent) void,
    ) !void {
        try self.subscribeHandler(topic, .{ .with_ctx = .{ .ctx = ctx, .func = callback } });
    }

    fn subscribeHandler(self: *Self, topic: []const u8, handler: TopicHandler) !void {
        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);

        const gop = try self.topic_callbacks.getOrPut(topic_copy);
        if (!gop.found_existing) {
            gop.key_ptr.* = topic_copy;
            gop.value_ptr.* = std.ArrayList(TopicHandler).empty;
        } else {
            self.allocator.free(topic_copy);
        }
        try gop.value_ptr.append(self.allocator, handler);
    }

    /// Unsubscribe a plain callback from a topic
    pub fn unsubscribe(self: *Self, topic: []const u8, callback: *const fn (NetworkEvent) void) void {
        if (self.topic_callbacks.getPtr(topic)) |callbacks| {
            for (callbacks.items, 0..) |h, i| {
                switch (h) {
                    .plain => |f| if (f == callback) {
                        _ = callbacks.swapRemove(i);
                        return;
                    },
                    .with_ctx => {},
                }
            }
        }
    }

    pub fn unsubscribeContext(self: *Self, topic: []const u8, ctx: *anyopaque) void {
        if (self.topic_callbacks.getPtr(topic)) |callbacks| {
            for (callbacks.items, 0..) |h, i| {
                switch (h) {
                    .with_ctx => |w| if (w.ctx == ctx) {
                        _ = callbacks.swapRemove(i);
                        return;
                    },
                    .plain => {},
                }
            }
        }
    }

    /// The JSON body of one event — the shape `parseEvent` reads back.
    ///
    /// `"seq"` belongs in this document: the MAC covers these bytes, so the
    /// sequence is authenticated, and the claim the key is derived from has to
    /// travel in the same document as it.
    const event_json_fmt = "{{\"topic\":\"{s}\",\"payload\":\"{s}\",\"source\":\"{s}\",\"time\":{d},\"seq\":{d}}}";

    fn serializeEvent(event: NetworkEvent, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, event_json_fmt, .{
            event.topic,
            event.payload,
            event.source_node,
            event.timestamp,
            event.seq,
        }) catch buf[0..0];
    }

    /// Byte count of the JSON `serializeEvent` writes for `event` — `std.fmt.count`
    /// over the same format string, so the two cannot drift.
    fn eventJsonSize(event: NetworkEvent) usize {
        return std.fmt.count(event_json_fmt, .{
            event.topic,
            event.payload,
            event.source_node,
            event.timestamp,
            event.seq,
        });
    }

    /// `serializeEvent` into a buffer sized for **this** event, so a payload
    /// larger than any fixed scratch array is sent in full: the old send path
    /// rendered into a `[4096]u8` local, and `serializeEvent` reports overflow by
    /// returning an empty slice, so a bigger event left the node as nothing at
    /// all and no failure was recorded (`docs/dev/cluster-auth-design.md` §14).
    fn serializeEventAlloc(allocator: std.mem.Allocator, event: NetworkEvent) ![]u8 {
        const buf = try allocator.alloc(u8, eventJsonSize(event));
        errdefer allocator.free(buf);
        const json = serializeEvent(event, buf);
        // Same format string on both sides, so this cannot fire; it guards the
        // pair against drifting apart, and is never a silently empty frame.
        if (json.len != buf.len) return error.EventTooLarge;
        return buf;
    }

    /// Set the key peer frames are signed and verified with. Null (the default)
    /// means bare frames — `ClusterBootstrap` only ever sets a non-null
    /// `cluster_secret` behind its multi-node gate, so the enforced path is the
    /// authenticated one. See the wire-format comment at the top of this file.
    pub fn setClusterSecret(self: *Self, key: [32]u8) void {
        self.cluster_secret = key;
    }

    /// Get list of connected nodes
    pub fn getConnectedNodes(self: *Self) []const Node {
        return self.nodes.items;
    }

    /// Get node count
    pub fn getNodeCount(self: *Self) usize {
        return self.nodes.items.len;
    }

    /// Connect to a remote node. The node is registered for routing immediately;
    /// the outbound socket is established opportunistically and may remain null.
    pub fn connectToNode(self: *Self, node_id: []const u8, address: std.Io.net.IpAddress) !void {
        // Prevent duplicate entries.
        for (self.nodes.items) |node| {
            if (std.mem.eql(u8, node.id, node_id)) {
                // Reconcile partitioner state in case the node was removed
                // from the ring while still being tracked here.
                if (self.partitioner) |p| {
                    if (!p.nodes.contains(node_id)) {
                        p.addNode(node_id) catch |err| {
                            std.log.err("[DistributedEventBus] Failed to re-add duplicate node {s} to partitioner: {}", .{ node_id, err });
                        };
                    }
                }
                return;
            }
        }

        const id_copy = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(id_copy);

        var stream: ?std.Io.net.Stream = null;
        stream = address.connect(self.io, .{ .mode = .stream }) catch |err| blk: {
            std.log.warn("[DistributedEventBus] Connection to {s} at {any} failed: {}", .{ node_id, address, err });
            break :blk null;
        };
        errdefer if (stream) |s| s.close(self.io);

        try self.nodes.append(.{
            .id = id_copy,
            .address = address,
            .socket = stream,
            .last_seen = Time.monotonicNowSeconds(),
            .send_failures = 0,
        });

        if (self.partitioner) |p| {
            if (!p.nodes.contains(node_id)) {
                p.addNode(node_id) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to add node {s} to partitioner: {}", .{ node_id, err });
                };
            }
        }
    }

    /// Disconnect from a node
    pub fn disconnectNode(self: *Self, node_id: []const u8) void {
        for (self.nodes.items, 0..) |*node, i| {
            if (std.mem.eql(u8, node.id, node_id)) {
                if (node.socket) |sock| {
                    sock.close(self.io);
                }
                self.allocator.free(node.id);
                _ = self.nodes.swapRemove(i);
                if (self.partitioner) |p| {
                    p.removeNode(node_id);
                }
                std.log.info("[DistributedEventBus] Disconnected from node {s}", .{node_id});
                return;
            }
        }
    }

    /// Return this node's identifier.
    pub fn nodeId(self: *Self) []const u8 {
        return self.node_id;
    }

    /// Total cluster size including this node.
    pub fn clusterSize(self: *Self) usize {
        return 1 + self.nodes.items.len;
    }

    /// Set the consistent-hash partitioner for event routing
    pub fn setPartitioner(self: *Self, p: *Partitioner) void {
        self.partitioner = p;
        // Ensure the ring reflects the current topology.
        if (!p.nodes.contains(self.node_id)) {
            p.addNode(self.node_id) catch |err| {
                std.log.err("[DistributedEventBus] Failed to add self to partitioner: {}", .{err});
            };
        }
        for (self.nodes.items) |node| {
            if (!p.nodes.contains(node.id)) {
                p.addNode(node.id) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to add node {s} to partitioner: {}", .{ node.id, err });
                };
            }
        }
    }

    /// Set the write-ahead log for crash recovery
    pub fn setWal(self: *Self, w: *WAL) void {
        self.wal = w;
    }

    /// Set the dead-letter queue for failed messages and start the retry loop
    /// if the bus is already running.
    pub fn setDlq(self: *Self, d: *DLQ) void {
        self.dlq = d;
        if (self.is_running and !self.dlq_retry_running) {
            self.dlq_retry_running = true;
            self.fiber_group.async(self.io, dlqRetryLoop, .{self});
        }
    }

    /// Periodic fiber that purges expired DLQ entries and requeues retryable ones.
    fn dlqRetryLoop(self: *Self) void {
        defer self.dlq_retry_running = false;
        while (self.is_running) {
            if (self.dlq) |dlq| {
                _ = dlq.purgeExpired() catch |err| {
                    std.log.err("[DistributedEventBus] DLQ purgeExpired failed: {}", .{err});
                };
                _ = dlq.requeue(self, &dlqRequeueCallback) catch |err| {
                    std.log.err("[DistributedEventBus] DLQ requeue failed: {}", .{err});
                };
            } else break;
            std.Io.sleep(self.io, .{ .nanoseconds = 1_000_000_000 }, .real) catch break; // 1 second
        }
    }

    fn dlqRequeueCallback(ctx: *anyopaque, msg: RequeuedMessage) void {
        const bus: *Self = @ptrCast(@alignCast(ctx));
        bus.publish(msg.topic, msg.payload) catch |err| {
            std.log.err("[DistributedEventBus] DLQ requeue republish failed: {}", .{err});
        };
    }

    /// Manually trigger a DLQ requeue cycle. Useful for tests and for callers
    /// that want to retry failed messages on demand instead of waiting for the fiber.
    pub fn requeueDlqEntries(self: *Self) !usize {
        const dlq = self.dlq orelse return 0;
        return dlq.requeue(self, &dlqRequeueCallback);
    }

    /// Replay events from WAL starting after the last committed position.
    /// Republishes each recovered event through the local bus.
    pub fn replayFromWal(self: *Self) !void {
        const w = self.wal orelse return;
        const from_seq = w.lastCommittedIndex() + 1;
        const entries = try w.readFrom(from_seq);
        defer {
            for (entries) |entry| {
                self.allocator.free(entry.topic);
                self.allocator.free(entry.payload);
                self.allocator.free(entry.source_node);
            }
            self.allocator.free(entries);
        }
        for (entries) |entry| {
            const event = NetworkEvent{
                .topic = entry.topic,
                .payload = entry.payload,
                .source_node = entry.source_node,
                .timestamp = entry.timestamp_ms,
            };
            self.publishToTopic(event);
            self.local_bus.publish(event);
        }
        std.log.info("[DistributedEventBus] Replayed {d} events from WAL (start={d})", .{ entries.len, from_seq });
    }

    /// Push raw data that failed deserialization into the DLQ.
    /// Used internally by handleConnection; also callable from tests.
    fn pushParseFailureToDlq(self: *Self, raw_data: []const u8) void {
        self.pushToDlq("unknown", raw_data, "ParseError", "Failed to deserialize event");
    }

    /// Push a failed message to the DLQ if one is configured.
    fn pushToDlq(self: *Self, topic: []const u8, payload: []const u8, error_type: []const u8, error_message: []const u8) void {
        const dlq = self.dlq orelse return;
        dlq.push(.{
            .topic = topic,
            .payload = payload,
            .error_type = error_type,
            .error_message = error_message,
            .retry_count = 0,
        }) catch |err| {
            std.log.err("[DistributedEventBus] DLQ push failed: {}", .{err});
        };
    }
};

/// Cluster configuration for distributed event bus
pub const ClusterConfig = struct {
    node_id: []const u8,
    listen_port: u16,
    seed_nodes: []const SeedNode,
    heartbeat_interval_ms: u32 = 5000,

    pub const SeedNode = struct {
        id: []const u8,
        host: []const u8,
        port: u16,
    };
};

test "DistributedEventBus init subscribe publish" {
    const allocator = std.testing.allocator;
    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    try std.testing.expectEqual(@as(usize, 0), bus.getNodeCount());

    var received: bool = false;
    const listener = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "test")) {
                flag.* = true;
            }
        }
    };
    listener.flag = &received;

    try bus.subscribe("test", listener.cb);
    try bus.publish("test", "hello");

    try std.testing.expect(received);
}

test "DistributedEventBus serializeEvent" {
    const event = DistributedEventBus.NetworkEvent{
        .topic = "t1",
        .payload = "p1",
        .source_node = "n1",
        .timestamp = 123,
    };
    var buf: [256]u8 = undefined;
    const serialized = DistributedEventBus.serializeEvent(event, &buf);
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "\"topic\":\"t1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "\"time\":123"));
}

test "DistributedEventBus parseEvent" {
    const allocator = std.testing.allocator;
    const data = "{\"topic\":\"test\",\"payload\":\"hello\",\"source\":\"node1\",\"time\":456}";

    const event = DistributedEventBus.parseEvent(allocator, data) orelse {
        return error.ParseFailed;
    };
    defer allocator.free(event.topic);
    defer allocator.free(event.payload);
    defer allocator.free(event.source_node);

    try std.testing.expectEqualStrings("test", event.topic);
    try std.testing.expectEqualStrings("hello", event.payload);
    try std.testing.expectEqualStrings("node1", event.source_node);
    try std.testing.expectEqual(@as(i64, 456), event.timestamp);
}

test "DistributedEventBus with WAL persistence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wal_config = WALConfig{ .dir_path = "wal_test_deb", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, wal_config);
    defer wal.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node-wal");
    defer bus.deinit();

    bus.setWal(&wal);

    try bus.publish("test-topic", "msg-1");
    try bus.publish("test-topic", "msg-2");
    try bus.publish("test-topic", "msg-3");

    // Verify events were written to WAL
    try std.testing.expectEqual(@as(u64, 3), wal.lastIndex());

    // replayFromWal should not error (may return empty if readFrom is stub)
    try bus.replayFromWal();
}

test "DistributedEventBus DLQ on parse failure" {
    const allocator = std.testing.allocator;

    const dlq_config = DLQConfig{
        .max_age_seconds = 60,
        .retry_cooldown_seconds = 1,
        .max_retries = 3,
        .storage = .memory,
    };
    var dlq = try DLQ.init(allocator, dlq_config);
    defer dlq.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node-dlq");
    defer bus.deinit();

    bus.setDlq(&dlq);

    try std.testing.expectEqual(@as(usize, 0), dlq.size());

    // Simulate parse failure by pushing malformed data through the internal helper
    bus.pushParseFailureToDlq("garbage-non-json-data");

    try std.testing.expectEqual(@as(usize, 1), dlq.size());
}

test "DistributedEventBus partitioner adds and removes nodes" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var partitioner = Partitioner.init(allocator, .{ .virtual_nodes_per_node = 10 });
    defer partitioner.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "node-1");
    defer bus.deinit();

    bus.setPartitioner(&partitioner);

    // Self is registered automatically.
    try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19001);
    try bus.connectToNode("node-2", addr);

    try std.testing.expectEqual(@as(usize, 2), bus.clusterSize());
    try std.testing.expectEqual(@as(usize, 2), partitioner.nodeCount());

    bus.disconnectNode("node-2");

    try std.testing.expectEqual(@as(usize, 1), bus.clusterSize());
    try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());

    // Routing falls back to broadcast when the ring is empty.
    try bus.publish("orders.created", "payload");
}

test "DistributedEventBus DLQ send failure and requeue republish" {
    const allocator = std.testing.allocator;

    var dlq = try DLQ.init(allocator, .{
        .max_age_seconds = 60,
        .retry_cooldown_seconds = 0,
        .max_retries = 3,
        .storage = .memory,
    });
    defer dlq.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "dlq-replay");
    defer bus.deinit();

    bus.setDlq(&dlq);

    var received: bool = false;
    const Listener = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "retry.topic") and std.mem.eql(u8, evt.payload, "retry-payload")) {
                flag.* = true;
            }
        }
    };
    Listener.flag = &received;
    try bus.subscribe("retry.topic", Listener.cb);

    // Simulate a send failure landing in the DLQ.
    bus.pushToDlq("retry.topic", "retry-payload", "SendError", "simulated send failure");
    try std.testing.expectEqual(@as(usize, 1), dlq.size());

    // Manually trigger a DLQ requeue; the context-backed callback should republish through this bus.
    const requeued = try bus.requeueDlqEntries();
    try std.testing.expectEqual(@as(usize, 1), requeued);
    try std.testing.expect(received);
}

test "DistributedEventBus WAL replay triggers local subscribers" {
    const allocator = std.testing.allocator;

    const wal_config = WALConfig{ .dir_path = "wal_test_deb", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, wal_config);
    defer wal.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "wal-replay-bus");
    defer bus.deinit();
    bus.setWal(&wal);

    var received: usize = 0;
    const Listener = struct {
        var count: *usize = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "replay.topic")) {
                count.* += 1;
            }
        }
    };
    Listener.count = &received;
    try bus.subscribe("replay.topic", Listener.cb);

    try bus.publish("replay.topic", "msg-1");
    try bus.publish("replay.topic", "msg-2");

    // Reset counter and replay only uncommitted entries.
    received = 0;
    wal.markCommitted(1);
    try bus.replayFromWal();

    try std.testing.expectEqual(@as(usize, 1), received);
}

test "DistributedEventBus DLQ requeue routes to owning bus" {
    const allocator = std.testing.allocator;

    const config = DLQConfig{
        .max_age_seconds = 60,
        .retry_cooldown_seconds = 0,
        .max_retries = 3,
        .storage = .memory,
    };

    var dlq_a = try DLQ.init(allocator, config);
    defer dlq_a.deinit();
    var dlq_b = try DLQ.init(allocator, config);
    defer dlq_b.deinit();

    var bus_a = try DistributedEventBus.init(allocator, std.testing.io, "bus-a");
    defer bus_a.deinit();
    bus_a.setDlq(&dlq_a);

    var bus_b = try DistributedEventBus.init(allocator, std.testing.io, "bus-b");
    defer bus_b.deinit();
    bus_b.setDlq(&dlq_b);

    var received_a: bool = false;
    var received_b: bool = false;

    const ListenerA = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "topic.a") and std.mem.eql(u8, evt.payload, "payload-a")) {
                flag.* = true;
            }
        }
    };
    ListenerA.flag = &received_a;

    const ListenerB = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "topic.b") and std.mem.eql(u8, evt.payload, "payload-b")) {
                flag.* = true;
            }
        }
    };
    ListenerB.flag = &received_b;

    try bus_a.subscribe("topic.a", ListenerA.cb);
    try bus_b.subscribe("topic.b", ListenerB.cb);

    bus_a.pushToDlq("topic.a", "payload-a", "SendError", "simulated");
    bus_b.pushToDlq("topic.b", "payload-b", "SendError", "simulated");

    const requeued_a = try bus_a.requeueDlqEntries();
    try std.testing.expectEqual(@as(usize, 1), requeued_a);
    try std.testing.expect(received_a);
    try std.testing.expect(!received_b);

    const requeued_b = try bus_b.requeueDlqEntries();
    try std.testing.expectEqual(@as(usize, 1), requeued_b);
    try std.testing.expect(received_b);
}

test "DistributedEventBus duplicate connect reconciles partitioner" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var partitioner = Partitioner.init(allocator, .{ .virtual_nodes_per_node = 10 });
    defer partitioner.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "node-1");
    defer bus.deinit();

    bus.setPartitioner(&partitioner);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19002);
    try bus.connectToNode("node-2", addr);
    try std.testing.expectEqual(@as(usize, 2), partitioner.nodeCount());

    // Simulate an external subsystem removing the node from the ring.
    partitioner.removeNode("node-2");
    try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());

    // Reconnecting the same logical node should add it back to the ring.
    try bus.connectToNode("node-2", addr);
    try std.testing.expectEqual(@as(usize, 2), partitioner.nodeCount());
}

// ── Framing + L1 (`docs/dev/cluster-auth-design.md` §3, §14) ────────────────
//
// These tests drive `handleConnection` directly over a socketpair: it is the
// bare two-ended stream the framing exists for, and it keeps them off the
// network (`NetworkProbe` gates the loopback ones). The peer half is closed
// before the call, so the framed loop drains what is buffered and stops at EOF
// — no thread and no read timing, except where a split into two separately
// observed reads is the thing under test.

/// The bytes of one bus frame, built the way `sendEventFrame` builds them: the
/// receive-side tests need raw bytes (a body split across two writes, a body
/// that changed after it was signed), which is exactly why they do not go
/// through the sender. `claim` is what the frame states as its source, and it is
/// what the key is derived from — a fixture that MAC'd with the raw secret would
/// no longer be a frame any receiver accepts.
fn testFrame(allocator: std.mem.Allocator, secret: ?[32]u8, claim: []const u8, json: []const u8) ![]u8 {
    const key: ?[32]u8 = if (secret) |s| DistributedEventBus.identityKey(s, claim) else null;
    return testFrameRaw(allocator, key, json);
}

/// The same bytes MAC'd with `key` directly — the shape the pre-KDF sender wrote,
/// kept so a test can show that a cluster-wide key no longer verifies.
fn testFrameRaw(allocator: std.mem.Allocator, key: ?[32]u8, json: []const u8) ![]u8 {
    const mac_len: usize = if (key != null) auth_mac_bytes else 0;
    const frame = try allocator.alloc(u8, 4 + mac_len + json.len);
    std.mem.writeInt(u32, frame[0..4], @intCast(mac_len + json.len), .big);
    if (key) |k| {
        var mac: [auth_mac_bytes]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, json, &k);
        @memcpy(frame[4..][0..auth_mac_bytes], &mac);
    }
    @memcpy(frame[4 + mac_len ..], json);
    return frame;
}

/// Hand `bytes` to `bus.handleConnection` as the peer end of a fresh socketpair,
/// with the writer half already closed.
fn feedFrame(bus: *DistributedEventBus, bytes: []const u8) !void {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const reader_side = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    const writer_side = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    sockread.writeFull(writer_side, bytes) catch |err| {
        writer_side.close(std.testing.io);
        reader_side.close(std.testing.io);
        return err;
    };
    writer_side.close(std.testing.io);
    bus.is_running = true;
    bus.handleConnection(reader_side);
    bus.is_running = false;
}

/// A bus with a subscriber that counts events on one topic. `received` is the
/// caller's counter, so a test can reset it between two feeds.
fn framedBus(allocator: std.mem.Allocator, node_id: []const u8, topic: []const u8, received: *usize) !DistributedEventBus {
    var bus = try DistributedEventBus.init(allocator, std.testing.io, node_id);
    errdefer bus.deinit();
    const Listener = struct {
        var count: *usize = undefined;
        var expected: []const u8 = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, expected)) count.* += 1;
        }
    };
    Listener.count = received;
    Listener.expected = topic;
    try bus.subscribe(topic, Listener.cb);
    return bus;
}

test "a frame split across two writes delivers exactly one event" {
    const allocator = std.testing.allocator;
    var received: usize = 0;
    var bus = try framedBus(allocator, "split-node", "split.topic", &received);
    defer bus.deinit();

    var json_buf: [600]u8 = undefined;
    const long_payload: [400]u8 = @splat('x');
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "split.topic",
        .payload = &long_payload,
        .source_node = "peer",
        .timestamp = 7,
    }, &json_buf);
    try std.testing.expect(json.len > 400);
    const frame = try testFrame(allocator, null, "peer", json);
    defer allocator.free(frame);

    // Split inside the payload string, so the first chunk cannot parse as a
    // complete event on its own (`"source"` has not arrived yet). That is the
    // shape a real TCP stream produces, and the reason why one read cannot be
    // one message: on the old loop the first chunk failed to parse and the
    // second failed too — the event was lost.
    const source_at = std.mem.indexOf(u8, frame, "\"source\"") orelse frame.len;
    const cut = frame.len / 2;
    try std.testing.expect(cut > 16 and cut < source_at);

    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const reader_side = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    const writer_side = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };

    bus.is_running = true;
    const reader = try std.Thread.spawn(.{}, DistributedEventBus.handleConnection, .{ &bus, reader_side });
    try sockread.writeFull(writer_side, frame[0..cut]);
    // Let the reader take the first chunk and block on the rest. Without the
    // gap the kernel hands both chunks over in one read, and the split — the
    // whole point of this test — would never happen.
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(100), .awake) catch |err| {
        std.log.debug("[test] inter-chunk wait ({})", .{err});
    };
    try sockread.writeFull(writer_side, frame[cut..]);
    writer_side.close(std.testing.io);
    reader.join();
    bus.is_running = false;

    try std.testing.expectEqual(@as(usize, 1), received);
}

test "two frames in one write deliver both events" {
    const allocator = std.testing.allocator;
    var received: usize = 0;
    var bus = try framedBus(allocator, "pair-node", "pair.topic", &received);
    defer bus.deinit();

    var json_a_buf: [128]u8 = undefined;
    var json_b_buf: [128]u8 = undefined;
    const json_a = DistributedEventBus.serializeEvent(.{
        .topic = "pair.topic",
        .payload = "first",
        .source_node = "peer",
        .timestamp = 1,
    }, &json_a_buf);
    const json_b = DistributedEventBus.serializeEvent(.{
        .topic = "pair.topic",
        .payload = "second",
        .source_node = "peer",
        .timestamp = 2,
    }, &json_b_buf);

    const frame_a = try testFrame(allocator, null, "peer", json_a);
    defer allocator.free(frame_a);
    const frame_b = try testFrame(allocator, null, "peer", json_b);
    defer allocator.free(frame_b);

    // Both messages in a single write. The old loop read once per message, so
    // the second one was silently discarded — this is that data loss.
    const both = try std.mem.concat(allocator, u8, &.{ frame_a, frame_b });
    defer allocator.free(both);
    try feedFrame(&bus, both);

    try std.testing.expectEqual(@as(usize, 2), received);
}

test "a signed frame round-trips: publish → wire → subscriber" {
    const allocator = std.testing.allocator;
    const secret: [32]u8 = @splat(0x5a);
    const topic = "wire.topic";

    // The sender half: a real node with a real secret, writing to the peer end
    // of a socketpair instead of dialling.
    var sender = try DistributedEventBus.init(allocator, std.testing.io, "sender-node");
    defer sender.deinit();
    sender.setClusterSecret(secret);

    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const peer_side = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    const bus_side = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    try sender.nodes.append(.{
        .id = try allocator.dupe(u8, "receiver-node"), // owned by the bus, freed by `deinit`
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19100),
        .socket = peer_side,
        .last_seen = 0,
    });

    try sender.publish(topic, "signed-payload");

    // What actually went out: `[4-byte BE len][mac32][json]`, `len` covering the
    // MAC and the json, and the MAC over the **json bytes only**.
    var len_buf: [4]u8 = undefined;
    try sockread.readFull(bus_side, &len_buf);
    const body_len = std.mem.readInt(u32, &len_buf, .big);
    const body = try allocator.alloc(u8, body_len);
    defer allocator.free(body);
    try sockread.readFull(bus_side, body);
    bus_side.close(std.testing.io);

    try std.testing.expect(body_len > auth_mac_bytes);
    const json = body[auth_mac_bytes..];
    // The key is the *claim's*, not the cluster secret: `identityKey(secret,
    // "sender-node")`. The raw secret must not verify, or the source a peer
    // states would be an unauthenticated self-description again.
    const key = DistributedEventBus.identityKey(secret, "sender-node");
    var expected_mac: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_mac, json, &key);
    try std.testing.expectEqualSlices(u8, &expected_mac, body[0..auth_mac_bytes]);
    var cluster_wide: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&cluster_wide, json, &secret);
    try std.testing.expect(!std.mem.eql(u8, &cluster_wide, body[0..auth_mac_bytes]));
    const parsed = DistributedEventBus.parseEvent(allocator, json) orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed.topic);
    defer allocator.free(parsed.payload);
    defer allocator.free(parsed.source_node);
    try std.testing.expectEqualStrings(topic, parsed.topic);
    try std.testing.expectEqualStrings("signed-payload", parsed.payload);
    try std.testing.expectEqualStrings("sender-node", parsed.source_node);

    // …and the very same bytes are what a receiving bus dispatches.
    const frame = try allocator.alloc(u8, 4 + body_len);
    defer allocator.free(frame);
    @memcpy(frame[0..4], &len_buf);
    @memcpy(frame[4..], body);

    var received: usize = 0;
    var receiver = try framedBus(allocator, "receiver-node", topic, &received);
    defer receiver.deinit();
    receiver.setClusterSecret(secret);
    try feedFrame(&receiver, frame);

    try std.testing.expectEqual(@as(usize, 1), received);
}

test "a frame signed with another key is dropped" {
    const allocator = std.testing.allocator;
    const sender_key: [32]u8 = @splat(0x11);
    const receiver_key: [32]u8 = @splat(0x22);

    var json_buf: [128]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "key.topic",
        .payload = "confidential",
        .source_node = "peer",
        .timestamp = 3,
    }, &json_buf);
    const frame = try testFrame(allocator, sender_key, "peer", json);
    defer allocator.free(frame);

    var received: usize = 0;
    var wrong_key = try framedBus(allocator, "wrong-key-node", "key.topic", &received);
    defer wrong_key.deinit();
    wrong_key.setClusterSecret(receiver_key);
    try feedFrame(&wrong_key, frame);
    try std.testing.expectEqual(@as(usize, 0), received);

    // Positive control: the fixture is a frame that *is* deliverable — the same
    // bytes reach the subscriber when the key matches, so the assertion above is
    // about the key and not about a broken frame.
    var right_key = try framedBus(allocator, "right-key-node", "key.topic", &received);
    defer right_key.deinit();
    right_key.setClusterSecret(sender_key);
    try feedFrame(&right_key, frame);
    try std.testing.expectEqual(@as(usize, 1), received);
}

test "a frame whose json changed after signing is dropped" {
    const allocator = std.testing.allocator;
    const secret: [32]u8 = @splat(0x33);

    var json_buf: [128]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "tamper.topic",
        .payload = "original-payload",
        .source_node = "peer",
        .timestamp = 4,
    }, &json_buf);
    const frame = try testFrame(allocator, secret, "peer", json);
    defer allocator.free(frame);

    // Flip one byte of the payload value, leaving the JSON valid and the topic —
    // which is what the subscriber matches on — untouched: a frame that would be
    // counted if it were accepted.
    const payload_at = std.mem.indexOf(u8, frame, "\"payload\":\"") orelse 0;
    try std.testing.expect(payload_at > 0);
    const tampered = try allocator.dupe(u8, frame);
    defer allocator.free(tampered);
    tampered[payload_at + "\"payload\":\"".len] ^= 0x01;
    try std.testing.expect(!std.mem.eql(u8, frame, tampered));

    var received: usize = 0;
    var bus = try framedBus(allocator, "tamper-node", "tamper.topic", &received);
    defer bus.deinit();
    bus.setClusterSecret(secret);

    // Positive control: the untampered frame is delivered.
    try feedFrame(&bus, frame);
    try std.testing.expectEqual(@as(usize, 1), received);

    // Changed after signing → the MAC no longer matches → dropped, nothing
    // dispatched (the frame never reaches `parseEvent`, so it is not a DLQ entry
    // either).
    try feedFrame(&bus, tampered);
    try std.testing.expectEqual(@as(usize, 1), received);
}

test "without a secret the frame is length-prefixed with no MAC, and accepted" {
    const allocator = std.testing.allocator;
    const topic = "bare.topic";

    // Sent by a real node with no secret: the standalone path, which keeps
    // working — "bare" means framed with the MAC omitted, not unframed.
    var sender = try DistributedEventBus.init(allocator, std.testing.io, "bare-sender");
    defer sender.deinit();

    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const peer_side = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    const bus_side = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    try sender.nodes.append(.{
        .id = try allocator.dupe(u8, "bare-receiver"), // owned by the bus, freed by `deinit`
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19101),
        .socket = peer_side,
        .last_seen = 0,
    });

    try sender.publish(topic, "bare-payload");

    var len_buf: [4]u8 = undefined;
    try sockread.readFull(bus_side, &len_buf);
    const body_len = std.mem.readInt(u32, &len_buf, .big);
    const body = try allocator.alloc(u8, body_len);
    defer allocator.free(body);
    try sockread.readFull(bus_side, body);
    bus_side.close(std.testing.io);

    // The whole body is the json: no MAC bytes anywhere in the frame. Length is
    // the check — re-rendering the parsed event has to come back the same size,
    // which only holds when the frame added nothing to the json.
    const parsed = DistributedEventBus.parseEvent(allocator, body) orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed.topic);
    defer allocator.free(parsed.payload);
    defer allocator.free(parsed.source_node);
    try std.testing.expectEqualStrings(topic, parsed.topic);
    try std.testing.expectEqualStrings("bare-payload", parsed.payload);
    try std.testing.expectEqualStrings("bare-sender", parsed.source_node);
    try std.testing.expect(std.mem.startsWith(u8, body, "{\"topic\":\""));
    try std.testing.expectEqual(body.len, DistributedEventBus.eventJsonSize(parsed));

    var received: usize = 0;
    var receiver = try framedBus(allocator, "bare-receiver", topic, &received);
    defer receiver.deinit();
    // No `setClusterSecret`: this bus is the standalone deployment `start()`
    // warns about.
    try std.testing.expect(receiver.cluster_secret == null);

    const frame = try allocator.alloc(u8, 4 + body_len);
    defer allocator.free(frame);
    @memcpy(frame[0..4], &len_buf);
    @memcpy(frame[4..], body);
    try feedFrame(&receiver, frame);

    try std.testing.expectEqual(@as(usize, 1), received);
}

// ── Closing the five §14 leftovers ──────────────────────────────────────────
//
// Each of these is red under the behaviour it replaced; the mutation that proves
// it is named in `docs/dev/cluster-auth-design.md` §14.

test "a payload containing quoted field names cannot steer the parse" {
    const allocator = std.testing.allocator;
    // Valid JSON whose *payload value* contains the literal `"topic"` and
    // `"source"` (escaped, as real JSON has it). The substring matcher this
    // replaced stopped at the first `"` it met after the key — the escape before
    // `topic` — and read `"source"` out of the payload, so it returned a
    // truncated payload and the wrong source node.
    const json =
        "{\"topic\":\"quoted.topic\",\"payload\":\"say \\\"topic\\\" from \\\"source\\\"\",\"source\":\"node-a\",\"time\":9}";

    const event = DistributedEventBus.parseEvent(allocator, json) orelse return error.TestUnexpectedResult;
    defer allocator.free(event.topic);
    defer allocator.free(event.payload);
    defer allocator.free(event.source_node);

    try std.testing.expectEqualStrings("quoted.topic", event.topic);
    try std.testing.expectEqualStrings("say \"topic\" from \"source\"", event.payload);
    try std.testing.expectEqualStrings("node-a", event.source_node);
    try std.testing.expectEqual(@as(i64, 9), event.timestamp);
}

test "a payload that injects a duplicate field is not delivered as somebody else" {
    const allocator = std.testing.allocator;
    // `serializeEvent` does not escape quotes (unchanged behaviour), so this
    // payload produces a document with the payload's own `"source"` **before**
    // the real one — which the substring matcher read as the event's source.
    var json_buf: [512]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "inject.topic",
        .payload = "y\",\"source\":\"node-b",
        .source_node = "node-a",
        .timestamp = 11,
    }, &json_buf);
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"source\":\"node-b\""));

    var received: usize = 0;
    var bus = try framedBus(allocator, "inject-node", "inject.topic", &received);
    defer bus.deinit();

    const frame = try testFrame(allocator, null, "peer", json);
    defer allocator.free(frame);
    try feedFrame(&bus, frame);

    // `std.json` rejects the duplicated key, so this is a parse failure (→ DLQ):
    // nothing is dispatched. Under the substring matcher it dispatches one event
    // whose `source_node` is `node-b`.
    try std.testing.expectEqual(@as(usize, 0), received);
}

test "a frame is keyed by the source it claims, not by the cluster secret" {
    const allocator = std.testing.allocator;
    const secret: [32]u8 = @splat(0x7e);

    var json_buf: [256]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "claim.topic",
        .payload = "p",
        .source_node = "node-b",
        .timestamp = 12,
    }, &json_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "claim-node", "claim.topic", &received);
    defer bus.deinit();
    bus.setClusterSecret(secret);

    // Signed with the raw cluster secret — the pre-KDF scheme — while claiming
    // `node-b`. The receiver derives its key from the claim, so this cannot
    // verify; a single cluster-wide key would accept it.
    const cluster_wide = try testFrameRaw(allocator, secret, json);
    defer allocator.free(cluster_wide);
    try feedFrame(&bus, cluster_wide);
    try std.testing.expectEqual(@as(usize, 0), received);

    // A frame keyed for a **different** claim must not verify either. Without this
    // the test above proves only that the key is not the raw secret: an
    // `identityKey` that ignored its `claim` argument (say, one fixed label) would
    // still satisfy both cases while the binding this item exists for was gone.
    // Verified red: `_ = claim;` in `identityKey` makes this line fail — the two
    // cases above keep passing, which is exactly why this assertion has to be here.
    const wrong_claim_key = DistributedEventBus.identityKey(secret, "node-a");
    const signed_for_a = try testFrameRaw(allocator, wrong_claim_key, json);
    defer allocator.free(signed_for_a);
    try feedFrame(&bus, signed_for_a);
    try std.testing.expectEqual(@as(usize, 0), received); // still nothing delivered

    // Positive control: the same json keyed the way a sender of `node-b` keys it.
    const per_identity = try testFrame(allocator, secret, "node-b", json);
    defer allocator.free(per_identity);
    try feedFrame(&bus, per_identity);
    try std.testing.expectEqual(@as(usize, 1), received);
}

test "a replayed frame is dropped even on a fresh connection" {
    const allocator = std.testing.allocator;
    const secret: [32]u8 = @splat(0x41);

    var json_buf: [256]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "replay.topic",
        .payload = "once",
        .source_node = "node-r",
        .timestamp = 13,
        .seq = 7,
    }, &json_buf);
    const frame = try testFrame(allocator, secret, "node-r", json);
    defer allocator.free(frame);

    var received: usize = 0;
    var bus = try framedBus(allocator, "replay-node", "replay.topic", &received);
    defer bus.deinit();
    bus.setClusterSecret(secret);

    // `feedFrame` opens a fresh connection every time, so this is the reconnect
    // case: the high-water mark is per claim, not per socket, and a captured
    // frame does not become fresh again by arriving on a new connection.
    try feedFrame(&bus, frame);
    try std.testing.expectEqual(@as(usize, 1), received);
    try feedFrame(&bus, frame);
    try std.testing.expectEqual(@as(usize, 1), received);
    try feedFrame(&bus, frame);
    try std.testing.expectEqual(@as(usize, 1), received);

    // …but a sender moving forward is still delivered: this is a window, not
    // "one frame per claim, ever".
    var newer_buf: [256]u8 = undefined;
    const newer = DistributedEventBus.serializeEvent(.{
        .topic = "replay.topic",
        .payload = "twice",
        .source_node = "node-r",
        .timestamp = 14,
        .seq = 8,
    }, &newer_buf);
    const newer_frame = try testFrame(allocator, secret, "node-r", newer);
    defer allocator.free(newer_frame);
    try feedFrame(&bus, newer_frame);
    try std.testing.expectEqual(@as(usize, 2), received);
}

test "two writers on one socket produce only whole frames" {
    const allocator = std.testing.allocator;
    const secret: [32]u8 = @splat(0x64);
    const frames_per_writer: usize = 5;

    // A frame far larger than the 4 KiB write buffer, so one `writeAll` is dozens
    // of syscalls and two writers can interleave *inside* a frame. That is what
    // the per-node lock removes: without it the reader picks up a length prefix
    // followed by the other writer's bytes, i.e. a MAC that cannot verify.
    const big_payload = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(big_payload);
    @memset(big_payload, 'z');

    const json_buf = try allocator.alloc(u8, big_payload.len + 256);
    defer allocator.free(json_buf);
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "concurrent.topic",
        .payload = big_payload,
        .source_node = "writer-node",
        .timestamp = 21,
        .seq = 1,
    }, json_buf);
    try std.testing.expect(json.len > big_payload.len);

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "writer-node");
    defer bus.deinit();
    bus.setClusterSecret(secret);

    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const peer_side = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    const bus_side = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    try bus.nodes.append(.{
        .id = try allocator.dupe(u8, "node-w"), // owned by the bus, freed by `deinit`
        .address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19102),
        .socket = bus_side,
        .last_seen = 0,
    });

    const Writer = struct {
        fn run(b: *DistributedEventBus, bytes: []const u8, n: usize) void {
            for (0..n) |_| {
                b.sendFramed(&b.nodes.items[0], bytes) catch |err| {
                    std.log.debug("[test] sendFramed: {}", .{err});
                };
            }
        }
    };
    const w1 = try std.Thread.spawn(.{}, Writer.run, .{ &bus, json, frames_per_writer });
    const w2 = try std.Thread.spawn(.{}, Writer.run, .{ &bus, json, frames_per_writer });

    // Read like a receiving bus does: the length prefix says how much to expect,
    // and what follows has to be one frame whose MAC verifies.
    const key = DistributedEventBus.identityKey(secret, "writer-node");
    var good: usize = 0;
    var i: usize = 0;
    while (i < frames_per_writer * 2) : (i += 1) {
        var len_buf: [4]u8 = undefined;
        sockread.readFull(peer_side, &len_buf) catch |err| {
            std.log.debug("[test] reader stopped: {}", .{err});
            break;
        };
        const body_len = std.mem.readInt(u32, &len_buf, .big);
        if (body_len <= auth_mac_bytes or body_len > max_frame_size) break;
        const body = try allocator.alloc(u8, body_len);
        defer allocator.free(body);
        sockread.readFull(peer_side, body) catch |err| {
            std.log.debug("[test] reader stopped mid-frame: {}", .{err});
            break;
        };
        var mac: [auth_mac_bytes]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body[auth_mac_bytes..], &key);
        if (!std.mem.eql(u8, &mac, body[0..auth_mac_bytes])) break;
        good += 1;
    }

    // Unblock the writers either way: on the corrupt path the readers above have
    // stopped, and a writer blocked on a full send buffer would never return.
    peer_side.close(std.testing.io);
    w1.join();
    w2.join();

    try std.testing.expectEqual(@as(usize, frames_per_writer * 2), good);
}

test "a peer that connects and then says nothing costs the idle bound, not the fiber" {
    const allocator = std.testing.allocator;
    var bus = try DistributedEventBus.init(allocator, std.testing.io, "idle-node");
    defer bus.deinit();
    // The production bound, shrunk to test size: what is under test is that a
    // bound is applied to the inbound read at all.
    bus.inbound_idle_timeout_ms = 200;

    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const reader_side = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    const silent_peer = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };

    var returned = std.atomic.Value(bool).init(false);
    const Reader = struct {
        fn run(b: *DistributedEventBus, conn: std.Io.net.Stream, done: *std.atomic.Value(bool)) void {
            b.is_running = true;
            b.handleConnection(conn);
            done.store(true, .release);
        }
    };
    bus.is_running = true;
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ &bus, reader_side, &returned });
    defer {
        // The peer only lets go here, so a reader without a timeout would block
        // until this line — which is the whole point of the assertion below.
        silent_peer.close(std.testing.io);
        reader.join();
    }

    // Five times the bound, and far less than the peer's own patience.
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1000), .awake) catch |err| {
        std.log.debug("[test] idle wait ({})", .{err});
    };
    try std.testing.expect(returned.load(.acquire));
}
