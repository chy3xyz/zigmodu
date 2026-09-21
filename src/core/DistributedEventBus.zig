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
//     [4-byte big-endian len][mac: 32 raw bytes][json]   credentials configured
//     [4-byte big-endian len][json]                      none ("bare")
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
// ── Handshake: which node is on the other end of this connection ────────────
//
// A frame's `"source"` is a self-description, and a MAC keyed with one
// cluster-wide secret proves only "some holder of the secret" — anyone with it
// can mint a frame for any id. So the identity is established **once per
// connection**, before any event frame, by the exchange below
// (`docs/dev/cluster-identity-design.md`):
//
//     ① receiver → dialer   [len][rc: 16]                    rc = fresh, from
//     ② dialer   → receiver [len][dc: 16][claim_id][mac: 32]    `randomSecure`,
//                                       mac = HMAC(own_key, claim_id ++ rc ++ dc)
//     ③ receiver → dialer   [len][receiver_id][mac2: 32]
//                                       mac2 = HMAC(own_key, receiver_id ++ dc)
//
// The receiver speaks first, which is what makes the handshake itself
// unreplayable: a captured response carries the **previous** challenge, so it
// cannot verify against a fresh one. `dc` is the dialer's own freshness and sits
// inside the dialer's MAC, so the receiver's reply binds one exchange rather than
// two unrelated halves; `mac2` is what makes it mutual — the dialer trusts the
// peer too, rather than only being trusted by it.
//
// After a successful bind, on that connection:
//
//     inbound   mac = HMAC(peer_keys[bound_id], json)   + `source == bound_id`
//     outbound  mac = HMAC(own_key, json)
//
// i.e. every node signs what it sends with **its own** key and verifies what it
// receives with **the sender's**, which is exactly the credential the handshake
// proved. (Signing outbound with the peer's key instead would make the two
// directions disagree unless every node's key were the same, i.e. a shared
// secret again — see `docs/dev/cluster-identity-design.md` §0.)
//
// `"source"` therefore stops being a claim and becomes a fact about the
// connection, checked on every frame. A signed frame still carries a strictly
// increasing `"seq"` inside the MAC'd region, so a captured event frame cannot be
// replayed at a receiver that already accepted a later one from the same sender.
//
// With credentials configured the handshake is mandatory and there is no
// downgrade: an unknown claimant is closed rather than retried, a bad MAC is
// closed, and a bare frame on an authenticated port is simply a failed
// handshake. A bus with no `cluster_secret`, no `own_key` and no `peer_keys` is
// the standalone/dev one `start()` warns about — nothing to authenticate *with*.
//
// `setRecvTimeout` bounds each inbound read, so a peer that connects and then
// sends nothing cannot hold a fiber (`stop()` waits on those fibers). The bound
// is idle-based and sits well above `heartbeat_interval_ms`, which is why a
// connection that is merely quiet — a healthy peer between heartbeats — is not
// torn down.

/// Length of the `mac32` the send side writes and the receive side strips.
const auth_mac_bytes = 32;

/// Length of the freshness value (`rc` / `dc`) in a handshake. The same size as
/// the AEAD/AES nonces the rest of the tree uses (128 bits): the value only has
/// to be unpredictable, and 128 bits from `randomSecure` is the house default.
const handshake_nonce_bytes = 16;

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

    /// 32-byte pre-shared key the cluster was configured with. It is **not** a
    /// frame key any more (there is no `HMAC(secret, claim)` derivation — see
    /// the handshake comment at the top): it selects the authenticated path, and
    /// it is the single knob `ClusterBootstrap` turns for `config.cluster_secret`.
    /// `null` plus no `own_key`/`peer_keys` is the bare-frame path `start()`
    /// warns about.
    cluster_secret: ?[32]u8 = null,

    /// This node's own credential: what it proves at handshake time and the key
    /// it signs everything it sends with (its handshake claim, `mac2`, and every
    /// event frame). Source it from `SecretsManager` and call `setOwnKey`; the
    /// framework does not read keys for you. `null` means this node cannot
    /// complete a handshake at all, so with credentials configured every
    /// connection is closed (`start()` says so, loudly).
    own_key: ?[32]u8 = null,

    /// `peer_id → that node's own key`: how the claim of `peer_id` is verified,
    /// and how frames arriving on a connection bound to `peer_id` are verified.
    /// Filled by the app with `setPeerKey` (the framework has no key channel of
    /// its own), so this table is application configuration rather than
    /// peer-controlled state — unlike `peer_seqs`, which only a verified peer can
    /// grow.
    peer_keys: std.StringHashMap([32]u8),

    /// Guards `peer_keys`: `setPeerKey`/`setOwnKey` are wiring-time calls but the
    /// bus is normally already started when an app reaches it through
    /// `ClusterBootstrap.getEventBus()`, while accept fibers read the same table.
    peer_keys_lock: std.Io.Mutex = .init,

    /// Sticky "some credential exists" flag, set by any of the three setters.
    /// `authEnabled` reads it instead of taking `peer_keys_lock`, because
    /// "could not read the table" must never be mistaken for "there are no keys"
    /// (that would be a downgrade to bare frames).
    credentials_configured: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
            .peer_keys = std.StringHashMap([32]u8).init(allocator),
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

        var key_iter = self.peer_keys.iterator();
        while (key_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.peer_keys.deinit();

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
        if (!self.authEnabled()) {
            std.log.warn(
                "[DistributedEventBus] node '{s}' listening on port {d} WITHOUT any credential: any host that can reach " ++
                    "this port may publish events, and every frame is trusted as whatever `source` it claims — " ++
                    "`__heartbeat` included. Call `setOwnKey` + `setPeerKey` (`ClusterBootstrap` calls " ++
                    "`setClusterSecret` for an enforced configuration).",
                .{ self.node_id, port },
            );
        } else if (self.own_key == null) {
            // Authenticated path, but this node has nothing to present: the
            // handshake can never complete, so every peer connection is refused.
            // Fail-closed is the intent — silently accepting bare frames instead
            // would be the downgrade the design forbids — but it is worth saying
            // out loud, because "the bus connects to nobody" has no obvious cause.
            std.log.warn(
                "[DistributedEventBus] node '{s}' listening on port {d} with credentials configured but no `own_key`: " ++
                    "every inbound handshake will be refused. Call `setOwnKey` from SecretsManager.",
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

    /// Apply `inbound_idle_timeout_ms` as `SO_RCVTIMEO` — to an accepted
    /// connection in `handleConnection`, and to the socket `connectToNode` just
    /// opened, because the dialer's first read is also a read that a peer can
    /// simply never answer.
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
    fn applyRecvTimeout(self: *Self, conn: std.Io.net.Stream) void {
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
        try self.sendEventFrame(sock, json);
    }

    /// Frame `json` for the wire (see the wire-format comment at the top of this
    /// file) and write it with a single `writeAll`, so the whole message — MAC
    /// included — leaves as one call. The MAC is keyed with **this node's own
    /// key**: the peer verifies it with `peer_keys[self.node_id]`, i.e. with the
    /// credential the handshake already proved for this connection.
    ///
    /// The frame is built in one heap buffer sized for this event. The old send
    /// path rendered into a fixed `[4096]u8` scratch array and wrote whatever
    /// came out; `serializeEvent` reports overflow by returning an empty slice,
    /// so an event bigger than the array was written as `""` — nothing on the
    /// wire, no failure recorded (`docs/dev/cluster-auth-design.md` §14).
    fn sendEventFrame(self: *Self, sock: std.Io.net.Stream, json: []const u8) !void {
        const mac_len: usize = if (self.authEnabled()) auth_mac_bytes else 0;
        const body_len = mac_len + json.len;
        if (body_len > max_frame_size) return error.MessageTooLarge;

        const frame = try self.allocator.alloc(u8, 4 + body_len);
        defer self.allocator.free(frame);
        std.mem.writeInt(u32, frame[0..4], @intCast(body_len), .big);
        if (mac_len != 0) {
            const key = self.own_key orelse return error.PeerKeyMissing;
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
    /// `sender_key` is the credential of the node this connection is **bound** to
    /// (see the handshake comment at the top of this file). Nothing here reads
    /// the frame before its MAC verifies: the key no longer comes from a
    /// self-description, so this is a straight verify-then-return and the json it
    /// hands back is the first and only parse of those bytes. A null key means
    /// the bare path, where there is nothing to verify against.
    ///
    /// The drops are the `error.ClusterAuthFailed` cases: a body too short to
    /// carry a MAC (a bare frame on an authenticated port — mixed-version
    /// clusters cut over hard), and a MAC that does not match.
    fn openEventFrame(sender_key: ?[32]u8, body: []const u8) ?[]const u8 {
        const key = sender_key orelse return body;
        if (body.len < auth_mac_bytes + 1) {
            std.log.debug("[DEB] dropping connection: {d}-byte body carries no MAC", .{body.len});
            return null;
        }
        const json = body[auth_mac_bytes..];
        // Raw bytes, the same reason `RaftTransport.verifiedRecv` is: the frame
        // carries the tag, raw, not `ClusterAuth.sign`'s hex rendering.
        var expected: [auth_mac_bytes]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, json, &key);
        if (!ClusterAuth.timingSafeEql(&expected, body[0..auth_mac_bytes])) {
            std.log.debug("[DEB] dropping connection: frame MAC does not verify against its bound peer", .{});
            return null;
        }
        return json;
    }

    /// A connection's identity, settled by the handshake: who the peer proved it
    /// is, and the credential its event frames have to be signed with.
    const Binding = struct {
        id: []const u8,
        key: [32]u8,
    };

    /// One length-prefixed handshake message: `[4-byte BE len][body]`. The same
    /// prefix the event frames use, so either side can read either with
    /// `readFull` and neither has to guess where a message ends. False means the
    /// connection is unusable.
    fn writeHandshake(conn: std.Io.net.Stream, body: []const u8) bool {
        if (body.len == 0 or body.len > max_frame_size) return false;
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(body.len), .big);
        sockread.writevAll(conn, &.{ &len_buf, body }) catch |err| {
            std.log.debug("[DEB] handshake write failed: {}", .{err});
            return false;
        };
        return true;
    }

    /// Read one handshake body into `allocator` (the caller frees it). Null on
    /// any failure: a length outside the frame bound, a short read, a timeout, or
    /// a peer that speaks another wire version — in every one of those cases the
    /// connection has no usable identity, which is the only thing that matters
    /// here. The old peer's event frame lands in this shape too (its json is not
    /// a handshake), which is the hard cut-over `docs/dev/cluster-identity-design.md`
    /// §6 describes: it fails, rather than looking fine and going unauthenticated.
    fn readHandshake(conn: std.Io.net.Stream, allocator: std.mem.Allocator) ?[]u8 {
        var len_buf: [4]u8 = undefined;
        sockread.readFull(conn, &len_buf) catch |err| {
            std.log.debug("[DEB] handshake read failed: {}", .{err});
            return null;
        };
        const body_len = std.mem.readInt(u32, &len_buf, .big);
        if (body_len == 0 or body_len > max_frame_size) {
            std.log.debug("[DEB] handshake length {d} outside 1..{d}", .{ body_len, max_frame_size });
            return null;
        }
        const body = allocator.alloc(u8, body_len) catch |err| {
            std.log.debug("[DEB] handshake body of {d} bytes not buffered ({})", .{ body_len, err });
            return null;
        };
        sockread.readFull(conn, body) catch |err| {
            std.log.debug("[DEB] handshake read failed: {}", .{err});
            allocator.free(body);
            return null;
        };
        return body;
    }

    /// The receiving half of the handshake (① and ③ of the protocol comment):
    /// challenge the dialer, verify the claim it answers with, then prove **our**
    /// identity back to it.
    ///
    /// Returns the id bound to this connection (allocated from `self.allocator`;
    /// the caller frees it) together with the key that peer's frames have to be
    /// signed with, or null when the connection must be dropped. Every rejection
    /// here is fail-closed with **no fallback**: an unknown claim is not retried
    /// against the cluster secret, a bad MAC is not treated as a bare frame, and
    /// no path out of this function ends in an accepted unauthenticated
    /// connection.
    fn bindInbound(self: *Self, conn: std.Io.net.Stream) ?Binding {
        const own = self.own_key orelse {
            std.log.debug("[DEB] dropping connection: this node has no own_key to bind with", .{});
            return null;
        };
        // The challenge comes from the OS entropy source, never from a clock: the
        // receiver speaks first so that a captured response cannot be replayed,
        // and a predictable challenge would hand that replay straight back.
        var challenge: [handshake_nonce_bytes]u8 = undefined;
        std.Io.randomSecure(self.io, &challenge) catch |err| {
            std.log.warn("[DEB] handshake refused: no entropy for a challenge ({})", .{err});
            return null;
        };
        if (!writeHandshake(conn, &challenge)) return null;

        const response = readHandshake(conn, self.allocator) orelse return null;
        defer self.allocator.free(response);
        // [dc: 16][claim_id][mac: 32]
        if (response.len < handshake_nonce_bytes + 1 + auth_mac_bytes) {
            std.log.debug("[DEB] dropping connection: handshake response is {d} bytes", .{response.len});
            return null;
        }
        const dc = response[0..handshake_nonce_bytes];
        const claim = response[handshake_nonce_bytes .. response.len - auth_mac_bytes];
        const mac = response[response.len - auth_mac_bytes ..];

        // The claim is what selects the key; a claim we hold no key for is an
        // unknown peer, not a peer to fall back on.
        const claim_key = self.peerKey(claim) orelse {
            std.log.debug("[DEB] dropping connection: no peer key for handshake claim '{s}'", .{claim});
            return null;
        };
        var expected: [auth_mac_bytes]u8 = undefined;
        var claim_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&claim_key);
        claim_hmac.update(claim);
        claim_hmac.update(&challenge);
        claim_hmac.update(dc);
        claim_hmac.final(&expected);
        // Constant-time, for the same reason `RaftTransport.verifiedRecv` is: a
        // byte-wise early exit leaks the tag.
        if (!ClusterAuth.timingSafeEql(&expected, mac)) {
            std.log.debug("[DEB] dropping connection: handshake MAC does not verify for claim '{s}'", .{claim});
            return null;
        }

        // ③ The mutual half. Bound to the dialer's own `dc`, so one receiver
        // reply cannot be lifted into a different exchange, and signed with our
        // key so the dialer can verify it against `peer_keys[us]`.
        const reply = self.allocator.alloc(u8, self.node_id.len + auth_mac_bytes) catch |err| {
            std.log.debug("[DEB] dropping connection: handshake reply not allocated ({})", .{err});
            return null;
        };
        defer self.allocator.free(reply);
        @memcpy(reply[0..self.node_id.len], self.node_id);
        var reply_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&own);
        reply_hmac.update(self.node_id);
        reply_hmac.update(dc);
        reply_hmac.final(reply[self.node_id.len..][0..auth_mac_bytes]);
        if (!writeHandshake(conn, reply)) return null;

        const id_copy = self.allocator.dupe(u8, claim) catch |err| {
            std.log.debug("[DEB] dropping connection: bound id not stored ({})", .{err});
            return null;
        };
        return .{ .id = id_copy, .key = claim_key };
    }

    /// The dialing half of the handshake: read the receiver's challenge, prove
    /// which node this is, and require the receiver to prove itself back before
    /// the connection is used for anything.
    ///
    /// Errors are the fail-closed outcomes; `connectToNode` drops the connection
    /// on every one of them. `PeerKeyMissing` on either side is the case the
    /// design names explicitly: no credential for this link means no link.
    fn bindOutbound(self: *Self, conn: std.Io.net.Stream, peer_id: []const u8) !void {
        // Both lookups happen **before** a byte is written: there is no point
        // opening an exchange we cannot finish, and no path where a missing key
        // degrades into an unverified connection.
        const own = self.own_key orelse return error.PeerKeyMissing;
        const peer_key = self.peerKey(peer_id) orelse return error.PeerKeyMissing;

        const challenge = readHandshake(conn, self.allocator) orelse return error.HandshakeRejected;
        defer self.allocator.free(challenge);
        if (challenge.len != handshake_nonce_bytes) return error.HandshakeRejected;

        var dc: [handshake_nonce_bytes]u8 = undefined;
        std.Io.randomSecure(self.io, &dc) catch |err| {
            std.log.warn("[DEB] handshake refused: no entropy for a nonce ({})", .{err});
            return error.EntropyUnavailable;
        };

        const response = try self.allocator.alloc(u8, handshake_nonce_bytes + self.node_id.len + auth_mac_bytes);
        defer self.allocator.free(response);
        @memcpy(response[0..handshake_nonce_bytes], &dc);
        @memcpy(response[handshake_nonce_bytes..][0..self.node_id.len], self.node_id);
        var response_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&own);
        response_hmac.update(self.node_id);
        response_hmac.update(challenge);
        response_hmac.update(&dc);
        response_hmac.final(response[handshake_nonce_bytes + self.node_id.len ..][0..auth_mac_bytes]);
        if (!writeHandshake(conn, response)) return error.HandshakeRejected;

        const reply = readHandshake(conn, self.allocator) orelse return error.HandshakeRejected;
        defer self.allocator.free(reply);
        if (reply.len < 1 + auth_mac_bytes) return error.HandshakeRejected;
        const receiver_id = reply[0 .. reply.len - auth_mac_bytes];
        // An answer from a node other than the one we dialled is not an answer to
        // this dial (the peer-id discipline of `docs/dev/cluster-auth-design.md` §10).
        if (!std.mem.eql(u8, receiver_id, peer_id)) {
            std.log.debug("[DEB] handshake refused: dialled '{s}', answered by '{s}'", .{ peer_id, receiver_id });
            return error.HandshakeRejected;
        }
        var expected: [auth_mac_bytes]u8 = undefined;
        var reply_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&peer_key);
        reply_hmac.update(receiver_id);
        reply_hmac.update(&dc);
        reply_hmac.final(&expected);
        if (!ClusterAuth.timingSafeEql(&expected, reply[reply.len - auth_mac_bytes ..])) {
            std.log.debug("[DEB] handshake refused: '{s}' did not prove it holds its own key", .{peer_id});
            return error.HandshakeRejected;
        }
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) void {
        defer conn.close(self.io);

        // Bound **each blocking read** — the same `SO_RCVTIMEO` bound Raft's
        // inbound side applies (`sockread.setRecvTimeout`,
        // `ElectionConfig.rpc_timeout_ms`). Without it a peer that connects and
        // then sends nothing holds this handle/fiber forever, and `stop()` waits
        // on those fibers in `fiber_group.await` — a cheap way to stall a node.
        // It covers the handshake reads too, so a peer that opens a connection
        // and never answers the challenge costs the bound rather than the fiber.
        //
        // The bound is per *read* and idle-based rather than per message: this
        // stream is long-lived (a healthy peer is quiet between heartbeats and
        // may be quiet for minutes after the last event), so any bound tighter
        // than `heartbeat_interval_ms` would tear down healthy connections. At
        // 6× the heartbeat interval it only fires for a peer that is *silent*,
        // and 0 still disables it.
        self.applyRecvTimeout(conn);

        // Settle the identity **before** the first event frame. The claim only
        // exists on a connection that proved it; there is no event path that runs
        // before this one (`docs/dev/cluster-identity-design.md` §3.2).
        var binding: ?Binding = null;
        defer {
            if (binding) |b| self.allocator.free(b.id);
        }
        if (self.authEnabled()) {
            binding = self.bindInbound(conn) orelse return;
        }

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

            // Authenticate before parsing anything at all: the key comes from the
            // binding, not from the frame, so the json handed to `parseEvent`
            // below is the only parse of these bytes. An unauthenticated frame
            // never becomes an event, and it is not a *parse* failure either, so
            // it does not go to the DLQ: the connection is dropped.
            const sender_key: ?[32]u8 = if (binding) |b| b.key else null;
            const data = openEventFrame(sender_key, body.items) orelse break;

            // Parse using our arena to avoid multiple tiny heap allocations
            if (parseEvent(ma, data)) |event| {
                // The claim in the json is checked against what the handshake
                // proved, and a mismatch is not a dropped event but a dropped
                // connection: a peer that has proven it is `node-a` and then
                // signs a frame saying `node-b` is either confused or hostile,
                // and either way this connection can no longer be attributed.
                if (binding) |b| {
                    if (!std.mem.eql(u8, event.source_node, b.id)) {
                        std.log.debug(
                            "[DEB] dropping connection: frame claims source '{s}' on a connection bound to '{s}'",
                            .{ event.source_node, b.id },
                        );
                        break;
                    }
                }

                if (!self.admitInbound(event, binding != null)) {
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
    /// returns true only for a frame that gets dispatched. `authenticated` is
    /// whether this connection was bound to a peer; only that path carries a
    /// sequence, and a bare frame has nothing to compare.
    fn admitInbound(self: *Self, event: NetworkEvent, authenticated: bool) bool {
        // Only the authenticated path carries a sequence (it is part of the MAC'd
        // region); a bare frame has nothing to compare.
        if (authenticated and !self.acceptSeq(event.source_node, event.seq)) {
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
    /// Every literal byte the document has outside the three escaped strings and
    /// the two integers: `{"topic":"","payload":"","source":"","time":,"seq":}`.
    const event_json_overhead: usize = 52;

    /// A cursor over the caller's buffer that **cannot overflow it**: once a write
    /// does not fit, `ok` goes false and every later write is a no-op, so the
    /// caller can finish building and then report the failure once.
    ///
    /// This replaces a `std.fmt` format string. `serializeEvent` and
    /// `eventJsonSize` shared that string so they could not drift — but it
    /// interpolated the payload verbatim, so a payload containing a `"` produced
    /// **invalid JSON** (the receiver's parser rejected the event into the DLQ).
    /// They now share these three writers instead, and `eventJsonSize` mirrors
    /// them exactly; the "cannot drift" property is preserved by construction.
    const JsonWriter = struct {
        buf: []u8,
        i: usize = 0,
        ok: bool = true,

        fn put(self: *JsonWriter, s: []const u8) void {
            if (!self.ok) return;
            if (self.i + s.len > self.buf.len) {
                self.ok = false;
                return;
            }
            @memcpy(self.buf[self.i..][0..s.len], s);
            self.i += s.len;
        }

        /// Write `s` JSON-escaped (no surrounding quotes). Mirrors `escapedLen`.
        fn esc(self: *JsonWriter, s: []const u8) void {
            for (s) |c| {
                switch (c) {
                    '"' => self.put("\\\""),
                    '\\' => self.put("\\\\"),
                    0x08 => self.put("\\b"),
                    0x0c => self.put("\\f"),
                    '\n' => self.put("\\n"),
                    '\r' => self.put("\\r"),
                    '\t' => self.put("\\t"),
                    else => {
                        if (c < 0x20) {
                            // \u00XX, written by hand: no error path, no allocation.
                            var esc4: [6]u8 = .{ '\\', 'u', '0', '0', hexDigit(c >> 4), hexDigit(c & 0xf) };
                            self.put(&esc4);
                        } else {
                            self.put(&[_]u8{c});
                        }
                    },
                }
            }
        }

        /// Write an unsigned integer in decimal. Mirrors `decimalLenU64`.
        /// Separate from `dec` because `seq` is `u64`: routing it through `i64`
        /// panics on a value above `maxInt(i64)` (the drift test found this with
        /// `maxInt(u64)` — a real seq, not a synthetic one).
        fn decU64(self: *JsonWriter, v: u64) void {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch {
                self.ok = false;
                return;
            };
            self.put(s);
        }

        /// Write a signed integer in decimal. Mirrors `decimalLen`.
        fn dec(self: *JsonWriter, v: i64) void {
            var tmp: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch {
                self.ok = false;
                return;
            };
            self.put(s);
        }
    };

    fn hexDigit(v: u8) u8 {
        return if (v < 10) '0' + v else 'a' + (v - 10);
    }

    /// Bytes `s` occupies once escaped — the exact mirror of `JsonWriter.esc`.
    fn escapedLen(s: []const u8) usize {
        var n: usize = 0;
        for (s) |c| n += switch (c) {
            '"', '\\', 0x08, 0x0c, '\n', '\r', '\t' => 2,
            else => if (c < 0x20) @as(usize, 6) else 1,
        };
        return n;
    }

    /// Digits `v` occupies in decimal — the exact mirror of `JsonWriter.decU64`.
    fn decimalLenU64(v: u64) usize {
        var n: usize = 1;
        var x = v;
        while (x >= 10) : (x = @divTrunc(x, 10)) n += 1;
        return n;
    }

    /// Digits `v` occupies in decimal — the exact mirror of `JsonWriter.dec`.
    fn decimalLen(v: i64) usize {
        if (v < 0) {
            // `-minInt(i64)` overflows, so the magnitude is taken in u64 via
            // `-(v + 1) + 1`. (The drift test found this: it feeds `minInt(i64)`,
            // which is a legitimate timestamp.)
            const mag: u64 = @as(u64, @intCast(-(v + 1))) + 1;
            return 1 + decimalLenU64(mag);
        }
        return decimalLenU64(@intCast(v));
    }

    // The two functions above must agree to the byte. `serializeEventAlloc` turns a
    // disagreement into `error.EventTooLarge` and nothing on the wire, so a silent
    // drift would look like "events stopped being delivered" — this is the
    // assertion that catches it at the source instead. It exists because the first
    // version of this rewrite got the overhead wrong by one byte (53 vs 52), which
    // every delivery test immediately reported as `EventTooLarge`.
    test "serializeEvent and eventJsonSize agree, including on escaped fields" {
        const cases = [_]NetworkEvent{
            .{ .topic = "t", .payload = "p", .source_node = "n", .timestamp = 0, .seq = 0 },
            .{ .topic = "a\"b", .payload = "back\\slash", .source_node = "tab\there", .timestamp = -1, .seq = 18446744073709551615 },
            .{ .topic = "line\nbreak", .payload = "\x01\x1f", .source_node = "unicode: \u{4e2d}\u{6587}", .timestamp = std.math.minInt(i64), .seq = 7 },
            .{ .topic = "", .payload = "", .source_node = "", .timestamp = 1234567890, .seq = 42 },
        };
        var buf: [4096]u8 = undefined;
        for (cases) |e| {
            const json = serializeEvent(e, &buf);
            try std.testing.expectEqual(eventJsonSize(e), json.len);
            // And it is real JSON: the parser this receiver uses must accept it.
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings(e.topic, parsed.value.object.get("topic").?.string);
            try std.testing.expectEqualStrings(e.payload, parsed.value.object.get("payload").?.string);
            try std.testing.expectEqualStrings(e.source_node, parsed.value.object.get("source").?.string);
            try std.testing.expectEqual(e.timestamp, parsed.value.object.get("time").?.integer);
        }
    }

    fn serializeEvent(event: NetworkEvent, buf: []u8) []const u8 {
        var w = JsonWriter{ .buf = buf };
        w.put("{\"topic\":\"");
        w.esc(event.topic);
        w.put("\",\"payload\":\"");
        w.esc(event.payload);
        w.put("\",\"source\":\"");
        w.esc(event.source_node);
        w.put("\",\"time\":");
        w.dec(event.timestamp);
        w.put(",\"seq\":");
        w.decU64(event.seq);
        w.put("}");
        // Same overflow contract as before: too small a buffer is reported as an
        // empty slice, never as a truncated document.
        if (!w.ok) return buf[0..0];
        return buf[0..w.i];
    }

    /// Byte count of the JSON `serializeEvent` writes for `event` — `std.fmt.count`
    /// over the same format string, so the two cannot drift.
    fn eventJsonSize(event: NetworkEvent) usize {
        return event_json_overhead +
            escapedLen(event.topic) +
            escapedLen(event.payload) +
            escapedLen(event.source_node) +
            decimalLen(event.timestamp) +
            decimalLenU64(event.seq);
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

    /// Select the authenticated path (`ClusterBootstrap` does this behind its
    /// multi-node gate, from `config.cluster_secret`). It is **not** a frame key:
    /// node credentials come from `setOwnKey` / `setPeerKey`. See the handshake
    /// comment at the top of this file.
    pub fn setClusterSecret(self: *Self, key: [32]u8) void {
        self.cluster_secret = key;
        self.credentials_configured.store(true, .release);
    }

    /// This node's own credential — what it proves at handshake time and signs
    /// its frames with. Source it from `secrets.SecretsManager`; the framework
    /// deliberately does not read keys for you (the same convention as
    /// `cluster_secret`).
    pub fn setOwnKey(self: *Self, key: [32]u8) void {
        self.own_key = key;
        self.credentials_configured.store(true, .release);
    }

    /// How this node verifies `peer_id`: that node's **own** key. Set one per
    /// peer — a cluster member we have no key for cannot be talked to at all
    /// (`connectToNode` returns `error.PeerKeyMissing`) and cannot connect to us
    /// (its claim is closed at the handshake), which is the fail-closed shape
    /// `docs/dev/cluster-identity-design.md` §5 asks for.
    pub fn setPeerKey(self: *Self, peer_id: []const u8, key: [32]u8) !void {
        const id_copy = try self.allocator.dupe(u8, peer_id);
        errdefer self.allocator.free(id_copy);

        self.peer_keys_lock.lock(self.io) catch return error.KeyTableLocked;
        defer self.peer_keys_lock.unlock(self.io);

        const gop = try self.peer_keys.getOrPut(id_copy);
        if (!gop.found_existing) {
            gop.key_ptr.* = id_copy;
        } else {
            self.allocator.free(id_copy);
        }
        gop.value_ptr.* = key;
        self.credentials_configured.store(true, .release);
    }

    /// The key recorded for `peer_id`, or null. Locked: the table is read from
    /// accept/handle fibers while an app may still be filling it in.
    fn peerKey(self: *Self, peer_id: []const u8) ?[32]u8 {
        self.peer_keys_lock.lock(self.io) catch return null;
        defer self.peer_keys_lock.unlock(self.io);
        return self.peer_keys.get(peer_id);
    }

    /// True once **any** credential is configured: a `cluster_secret`
    /// (`ClusterBootstrap`'s gate judged it), an `own_key`, or any peer key.
    ///
    /// This is the switch between the two wire formats, and it is the reason
    /// there is no downgrade path: once it is true, `handleConnection` requires a
    /// handshake and `connectToNode` requires a peer key, so a bare frame on this
    /// port is a failed handshake rather than an unauthenticated delivery.
    fn authEnabled(self: *Self) bool {
        return self.cluster_secret != null or self.credentials_configured.load(.acquire);
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

        // Fail-closed **before** the dial: with credentials configured, a peer we
        // hold no key for is a peer we cannot talk to, and finding that out after
        // connecting — or, worse, falling back to bare frames — is exactly the
        // downgrade `docs/dev/cluster-identity-design.md` §5 forbids.
        if (self.authEnabled() and self.peerKey(node_id) == null) return error.PeerKeyMissing;

        const id_copy = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(id_copy);

        var stream: ?std.Io.net.Stream = null;
        stream = address.connect(self.io, .{ .mode = .stream }) catch |err| blk: {
            std.log.warn("[DistributedEventBus] Connection to {s} at {any} failed: {}", .{ node_id, address, err });
            break :blk null;
        };
        errdefer if (stream) |s| s.close(self.io);

        // The identity is settled before the socket is registered anywhere: a
        // peer that cannot prove itself is not a peer, and `socket = null` is how
        // this bus already says "tracked for routing, not reachable". A refused
        // handshake is therefore a *connection* failure, not a fatal error for
        // the caller — the same shape as the connect failure above.
        if (stream) |s| {
            self.applyRecvTimeout(s);
            self.bindOutbound(s, node_id) catch |err| {
                std.log.warn("[DistributedEventBus] Peer {s} at {any} refused the handshake: {}", .{ node_id, address, err });
                s.close(self.io);
                stream = null;
            };
        }

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

/// The bytes of one bus frame, built the way `sendEventFrame` builds them:
/// `[4-byte BE len][mac32][json]` with a key, `[4-byte BE len][json]` without.
/// The MAC is keyed with the **sender's own** key, which is what the receiver
/// looks up for the peer its handshake bound (`peer_keys[bound_id]`) — so a
/// fixture that MAC'd with the receiver's key, or with a cluster secret, would
/// not be a frame any receiver accepts.
fn testFrame(allocator: std.mem.Allocator, key: ?[32]u8, json: []const u8) ![]u8 {
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
/// with the writer half already closed. The writer half is closed *before* the
/// call, so this is only usable on the **bare** path: a bus with credentials
/// sends its challenge first, and a closed peer end turns that into an
/// immediate write error. Authenticated connections need a peer that answers —
/// see `feedAuthed`.
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

// ── Driver for authenticated connections ────────────────────────────────────
//
// A bound connection is a *conversation* — receiver challenges, peer answers,
// receiver answers back — so a fixture that only writes bytes is not a peer any
// more. These helpers play the peer end while `handleConnection` runs on
// another thread, which is also what makes "the connection was closed" an
// observable outcome: a frame written after the receiver gave up reaches
// nobody.

/// Both ends of a fresh `socketpair`.
const SocketPair = struct {
    /// Handed to `handleConnection`.
    conn: std.Io.net.Stream,
    /// The peer end the test drives.
    peer: std.Io.net.Stream,
};

fn openSocketPair() !SocketPair {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    return .{
        .conn = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } },
        .peer = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } },
    };
}

/// Read one length-prefixed handshake message from the peer end. Null on EOF or
/// a short read — which is also how "the receiver hung up" shows up here.
fn peerReadMessage(allocator: std.mem.Allocator, sock: std.Io.net.Stream) ?[]u8 {
    var len_buf: [4]u8 = undefined;
    sockread.readFull(sock, &len_buf) catch |err| {
        std.log.debug("[test] peer read stopped: {}", .{err});
        return null;
    };
    const n = std.mem.readInt(u32, &len_buf, .big);
    if (n == 0 or n > max_frame_size) return null;
    const body = allocator.alloc(u8, n) catch return null;
    sockread.readFull(sock, body) catch |err| {
        std.log.debug("[test] peer read stopped mid-message: {}", .{err});
        allocator.free(body);
        return null;
    };
    return body;
}

fn peerWriteMessage(sock: std.Io.net.Stream, body: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(body.len), .big);
    try sockread.writevAll(sock, &.{ &len_buf, body });
}

/// The dialer half, played from the peer end: answer the receiver's challenge as
/// `claim` (signing with `sign_key`) and require the receiver to prove itself
/// with `receiver_key`. Returns the response body it sent, so a test can replay
/// those exact bytes on a fresh connection.
fn peerAnswerChallenge(
    allocator: std.mem.Allocator,
    sock: std.Io.net.Stream,
    claim: []const u8,
    sign_key: [32]u8,
    receiver_id: []const u8,
    receiver_key: [32]u8,
) ![]u8 {
    const challenge = peerReadMessage(allocator, sock) orelse return error.HandshakeRefused;
    defer allocator.free(challenge);
    if (challenge.len != handshake_nonce_bytes) return error.HandshakeRefused;

    var dc: [handshake_nonce_bytes]u8 = undefined;
    std.Io.randomSecure(std.testing.io, &dc) catch return error.EntropyUnavailable;

    const response = try allocator.alloc(u8, handshake_nonce_bytes + claim.len + auth_mac_bytes);
    errdefer allocator.free(response);
    @memcpy(response[0..handshake_nonce_bytes], &dc);
    @memcpy(response[handshake_nonce_bytes..][0..claim.len], claim);
    var claim_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&sign_key);
    claim_hmac.update(claim);
    claim_hmac.update(challenge);
    claim_hmac.update(&dc);
    claim_hmac.final(response[handshake_nonce_bytes + claim.len ..][0..auth_mac_bytes]);
    try peerWriteMessage(sock, response);

    // ③ The receiver's half of the mutual exchange, over the `dc` above.
    const reply = peerReadMessage(allocator, sock) orelse return error.HandshakeRefused;
    defer allocator.free(reply);
    if (reply.len < 1 + auth_mac_bytes) return error.HandshakeRefused;
    const reply_id = reply[0 .. reply.len - auth_mac_bytes];
    try std.testing.expectEqualStrings(receiver_id, reply_id);
    var expected: [auth_mac_bytes]u8 = undefined;
    var reply_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&receiver_key);
    reply_hmac.update(reply_id);
    reply_hmac.update(&dc);
    reply_hmac.final(&expected);
    try std.testing.expectEqualSlices(u8, &expected, reply[reply.len - auth_mac_bytes ..]);
    return response;
}

/// Write one event frame from the peer end. `key` null writes a bare frame.
fn peerWriteFrame(allocator: std.mem.Allocator, sock: std.Io.net.Stream, key: ?[32]u8, json: []const u8) !void {
    const frame = try testFrame(allocator, key, json);
    defer allocator.free(frame);
    try sockread.writeFull(sock, frame);
}

/// The **receiver** half, played from the peer end — the counterpart of
/// `peerAnswerChallenge`, for tests about what the dialer does with the answer.
/// `reply_key` is the credential the reply is signed with, so a test can hand an
/// otherwise honest receiver the wrong one and watch the dialer refuse it.
/// `claim_key` is what the receiver uses to check the dialer's claim.
fn peerServeAsReceiver(
    allocator: std.mem.Allocator,
    sock: std.Io.net.Stream,
    receiver_id: []const u8,
    reply_key: [32]u8,
    claim_key: [32]u8,
) !void {
    var challenge: [handshake_nonce_bytes]u8 = undefined;
    std.Io.randomSecure(std.testing.io, &challenge) catch return error.EntropyUnavailable;
    try peerWriteMessage(sock, &challenge);

    const response = peerReadMessage(allocator, sock) orelse return error.HandshakeRefused;
    defer allocator.free(response);
    if (response.len < handshake_nonce_bytes + 1 + auth_mac_bytes) return error.HandshakeRefused;
    const dc = response[0..handshake_nonce_bytes];
    const claim = response[handshake_nonce_bytes .. response.len - auth_mac_bytes];
    // The claim is checked before the reply goes out, exactly like the real
    // receiver: an unproven dialer gets nothing back.
    var expected: [auth_mac_bytes]u8 = undefined;
    var claim_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&claim_key);
    claim_hmac.update(claim);
    claim_hmac.update(&challenge);
    claim_hmac.update(dc);
    claim_hmac.final(&expected);
    try std.testing.expectEqualSlices(u8, &expected, response[response.len - auth_mac_bytes ..]);

    const reply = try allocator.alloc(u8, receiver_id.len + auth_mac_bytes);
    defer allocator.free(reply);
    @memcpy(reply[0..receiver_id.len], receiver_id);
    var reply_hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&reply_key);
    reply_hmac.update(receiver_id);
    reply_hmac.update(dc);
    reply_hmac.final(reply[receiver_id.len..][0..auth_mac_bytes]);
    try peerWriteMessage(sock, reply);
}

/// A `peerServeAsReceiver` running on its own thread, so the test thread can be
/// the dialer (`bindOutbound` blocks reading the challenge).
const ReceiverFixture = struct {
    allocator: std.mem.Allocator,
    sock: std.Io.net.Stream,
    id: []const u8,
    reply_key: [32]u8,
    claim_key: [32]u8,
    err: ?anyerror = null,

    fn run(self: *ReceiverFixture) void {
        peerServeAsReceiver(self.allocator, self.sock, self.id, self.reply_key, self.claim_key) catch |e| {
            self.err = e;
            return;
        };
        self.err = null;
    }
};

/// One authenticated connection to `bus`: complete the handshake as `claim`
/// (holding `sign_key`) and then write every frame in `frames`, MAC'd with
/// `frame_key`. The receiver's own key is taken from `bus.own_key`, so the
/// mutual half of the exchange is checked too.
///
/// A receiver that refuses the handshake simply closes, which is why this does
/// not report an error: the assertion in every refusal test is that nothing was
/// delivered — including the frames written **after** the refusal, since a
/// closed connection has to stay closed.
fn feedAuthed(
    bus: *DistributedEventBus,
    claim: []const u8,
    sign_key: [32]u8,
    frame_key: ?[32]u8,
    frames: []const []const u8,
) void {
    const allocator = std.testing.allocator;
    const pair = openSocketPair() catch {
        std.log.debug("[test] no socketpair on this platform", .{});
        return;
    };

    bus.is_running = true;
    const reader = std.Thread.spawn(.{}, DistributedEventBus.handleConnection, .{ bus, pair.conn }) catch {
        pair.conn.close(std.testing.io);
        pair.peer.close(std.testing.io);
        return;
    };
    defer {
        pair.peer.close(std.testing.io);
        reader.join();
        bus.is_running = false;
    }

    const receiver_key = bus.own_key orelse {
        std.log.debug("[test] feedAuthed needs an own_key on the receiver", .{});
        return;
    };
    const response = peerAnswerChallenge(allocator, pair.peer, claim, sign_key, bus.node_id, receiver_key) catch |err| {
        // Expected for the refusal tests: the receiver hung up instead of
        // answering, and the frames below land on a closed socket.
        std.log.debug("[test] peer handshake ended: {}", .{err});
        for (frames) |json| peerWriteFrame(allocator, pair.peer, frame_key, json) catch |werr| {
            std.log.debug("[test] write to a closed connection: {}", .{werr});
        };
        return;
    };
    allocator.free(response);

    for (frames) |json| {
        peerWriteFrame(allocator, pair.peer, frame_key, json) catch |err| {
            std.log.debug("[test] peer write stopped: {}", .{err});
            return;
        };
    }
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
    const frame = try testFrame(allocator, null, json);
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

    const frame_a = try testFrame(allocator, null, json_a);
    defer allocator.free(frame_a);
    const frame_b = try testFrame(allocator, null, json_b);
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
    const sender_key: [32]u8 = @splat(0x5a);
    const receiver_key: [32]u8 = @splat(0x51);
    const topic = "wire.topic";

    // The sender half: a real node with its own credential, writing to the peer
    // end of a socketpair instead of dialling.
    var sender = try DistributedEventBus.init(allocator, std.testing.io, "sender-node");
    defer sender.deinit();
    sender.setOwnKey(sender_key);

    const pair = try openSocketPair();
    const peer_side = pair.conn;
    const bus_side = pair.peer;
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
    // The key is the **sender's own**, which is what the receiver looks up for
    // the peer its handshake bound. The receiver's key must not verify, or the
    // two directions would disagree about who signs what.
    var expected_mac: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_mac, json, &sender_key);
    try std.testing.expectEqualSlices(u8, &expected_mac, body[0..auth_mac_bytes]);
    var peer_keyed: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&peer_keyed, json, &receiver_key);
    try std.testing.expect(!std.mem.eql(u8, &peer_keyed, body[0..auth_mac_bytes]));
    const parsed = DistributedEventBus.parseEvent(allocator, json) orelse return error.TestUnexpectedResult;
    defer allocator.free(parsed.topic);
    defer allocator.free(parsed.payload);
    defer allocator.free(parsed.source_node);
    try std.testing.expectEqualStrings(topic, parsed.topic);
    try std.testing.expectEqualStrings("signed-payload", parsed.payload);
    try std.testing.expectEqualStrings("sender-node", parsed.source_node);

    // …and the same json is what a receiving bus dispatches: the peer plays
    // `sender-node` through a real handshake (holding its own key), and the
    // receiver verifies with the key it holds for that id.
    var received: usize = 0;
    var receiver = try framedBus(allocator, "receiver-node", topic, &received);
    defer receiver.deinit();
    receiver.setOwnKey(receiver_key);
    try receiver.setPeerKey("sender-node", sender_key);
    feedAuthed(&receiver, "sender-node", sender_key, sender_key, &.{json});

    try std.testing.expectEqual(@as(usize, 1), received);
}

test "a frame signed with another key is dropped" {
    const allocator = std.testing.allocator;
    const peer_key: [32]u8 = @splat(0x11);
    const other_key: [32]u8 = @splat(0x22);
    const receiver_key: [32]u8 = @splat(0x23);

    var json_buf: [128]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "key.topic",
        .payload = "confidential",
        .source_node = "peer-a",
        .timestamp = 3,
        .seq = 1,
    }, &json_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "key-node", "key.topic", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("peer-a", peer_key);

    // The handshake succeeds — the peer really does hold `peer_key` — and then it
    // signs the frame with a key the receiver holds nothing for. The key is not
    // negotiated per frame, it is the one the bind established.
    feedAuthed(&bus, "peer-a", peer_key, other_key, &.{json});
    try std.testing.expectEqual(@as(usize, 0), received);

    // Positive control: the same json, from the same bound peer, signed with the
    // key that peer is known by. Delivered — so the assertion above is about the
    // key and not about a frame that could never arrive.
    feedAuthed(&bus, "peer-a", peer_key, peer_key, &.{json});
    try std.testing.expectEqual(@as(usize, 1), received);
}

test "a frame whose json changed after signing is dropped" {
    const allocator = std.testing.allocator;
    const peer_key: [32]u8 = @splat(0x33);
    const receiver_key: [32]u8 = @splat(0x34);

    var json_buf: [128]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "tamper.topic",
        .payload = "original-payload",
        .source_node = "peer-t",
        .timestamp = 4,
        .seq = 1,
    }, &json_buf);
    const frame = try testFrame(allocator, peer_key, json);
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
    const tampered_json = tampered[4 + auth_mac_bytes ..];

    var received: usize = 0;
    var bus = try framedBus(allocator, "tamper-node", "tamper.topic", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("peer-t", peer_key);

    // Positive control: the untampered json on a bound connection is delivered.
    feedAuthed(&bus, "peer-t", peer_key, peer_key, &.{json});
    try std.testing.expectEqual(@as(usize, 1), received);

    // Changed after signing → the MAC no longer matches → the connection is
    // dropped, and nothing is dispatched (the frame never reaches `parseEvent`,
    // so it is not a DLQ entry either). `seq` is one higher so the assertion is
    // about the tag and not about the replay window.
    feedAuthed(&bus, "peer-t", peer_key, peer_key, &.{tampered_json});
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
    // `serializeEvent` now escapes, so this payload's quotes reach the wire as
    // `\"` and the document has exactly one `"source"` field. That is the fix for
    // the vector this test used to reproduce: the injection is inert, and the
    // event round-trips with the text intact **as payload data**.
    var json_buf: [512]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "inject.topic",
        .payload = "y\",\"source\":\"node-b",
        .source_node = "node-a",
        .timestamp = 11,
    }, &json_buf);
    // The payload's `"source":"node-b"` is inside a JSON string, so the document
    // must NOT contain it as a field…
    try std.testing.expect(!std.mem.containsAtLeast(u8, json, 1, "\"source\":\"node-b\""));
    // …and the real source is still the node that sent it.
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"source\":\"node-a\""));

    var received: usize = 0;
    var bus = try framedBus(allocator, "inject-node", "inject.topic", &received);
    defer bus.deinit();

    const frame = try testFrame(allocator, null, json);
    defer allocator.free(frame);
    try feedFrame(&bus, frame);

    // Delivered, with the injected text as *data* — and crucially still attributed
    // to `node-a`, not to the `node-b` the payload tried to install. Before
    // escaping this dispatched an event whose `source_node` was `node-b`; before
    // the JSON parser it read the injected field as the source.
    try std.testing.expectEqual(@as(usize, 1), received);
}

// ── Identity binding: the §7 red-evidence list ──────────────────────────────
//
// `docs/dev/cluster-identity-design.md` §7. These are the cases the handshake
// exists for; #3 is the criterion for the whole design — the previous scheme
// (`identityKey`, a key derived from the value the frame itself claims) **passes**
// it whenever the attacker holds the cluster secret.

test "a claim answered with another node's key is refused" {
    const allocator = std.testing.allocator;
    const node_a_key: [32]u8 = @splat(0xa1);
    const node_b_key: [32]u8 = @splat(0xb2);
    const receiver_key: [32]u8 = @splat(0xc3);

    var json_buf: [256]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "claim.topic",
        .payload = "p",
        .source_node = "node-b",
        .timestamp = 12,
        .seq = 1,
    }, &json_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "claim-node", "claim.topic", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("node-a", node_a_key);
    try bus.setPeerKey("node-b", node_b_key);

    // The claim is `node-b` but the MAC is computed with **node-a's** key — the
    // shape of a member that holds its own credential and tries to appear as
    // somebody else. The receiver keys the check off the claim, so this cannot
    // verify. (This is §7 #1.)
    feedAuthed(&bus, "node-b", node_a_key, node_a_key, &.{json});
    try std.testing.expectEqual(@as(usize, 0), received);

    // Positive control: the same claim signed with the key that claim owns is
    // accepted, so the line above is about *whose* key it is, not about a
    // handshake that could never succeed.
    feedAuthed(&bus, "node-b", node_b_key, node_b_key, &.{json});
    try std.testing.expectEqual(@as(usize, 1), received);
}

test "a replayed handshake is refused on a fresh connection" {
    const allocator = std.testing.allocator;
    const peer_key: [32]u8 = @splat(0xd4);
    const receiver_key: [32]u8 = @splat(0xd5);

    var json_buf: [256]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "replay.handshake",
        .payload = "p",
        .source_node = "node-a",
        .timestamp = 13,
        .seq = 1,
    }, &json_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "replay-handshake-node", "replay.handshake", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("node-a", peer_key);

    // First connection: the exchange succeeds and the response bytes are kept.
    const first = try openSocketPair();
    bus.is_running = true;
    const first_reader = try std.Thread.spawn(.{}, DistributedEventBus.handleConnection, .{ &bus, first.conn });
    const captured = try peerAnswerChallenge(allocator, first.peer, "node-a", peer_key, bus.node_id, receiver_key);
    defer allocator.free(captured);
    first.peer.close(std.testing.io);
    first_reader.join();
    bus.is_running = false;

    // Second connection: the challenge is new, so the recorded response — MAC
    // over the *previous* challenge — cannot verify. (§7 #2: a receiver that did
    // not put its challenge inside the MAC would accept this and be impersonated.)
    const second = try openSocketPair();
    bus.is_running = true;
    const second_reader = try std.Thread.spawn(.{}, DistributedEventBus.handleConnection, .{ &bus, second.conn });
    const fresh_challenge = peerReadMessage(allocator, second.peer) orelse return error.TestUnexpectedResult;
    defer allocator.free(fresh_challenge);
    try peerWriteMessage(second.peer, captured);
    // A connection that was refused must stay refused: even a frame the receiver
    // would otherwise accept on this bound id has to reach nobody.
    peerWriteFrame(allocator, second.peer, peer_key, json) catch |err| {
        std.log.debug("[test] write to a refused connection: {}", .{err});
    };
    second.peer.close(std.testing.io);
    second_reader.join();
    bus.is_running = false;

    try std.testing.expectEqual(@as(usize, 0), received);
}

test "a frame claiming another node on a bound connection is refused, not delivered" {
    const allocator = std.testing.allocator;
    const node_a_key: [32]u8 = @splat(0xe1);
    const node_b_key: [32]u8 = @splat(0xe2);
    const receiver_key: [32]u8 = @splat(0xe3);

    var stolen_buf: [256]u8 = undefined;
    const stolen = DistributedEventBus.serializeEvent(.{
        .topic = "bound.topic",
        .payload = "as-node-b",
        .source_node = "node-b",
        .timestamp = 14,
        .seq = 1,
    }, &stolen_buf);
    var real_buf: [256]u8 = undefined;
    const real = DistributedEventBus.serializeEvent(.{
        .topic = "bound.topic",
        .payload = "as-node-a",
        .source_node = "node-a",
        .timestamp = 15,
        .seq = 2,
    }, &real_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "bound-node", "bound.topic", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("node-a", node_a_key);
    try bus.setPeerKey("node-b", node_b_key);

    // This is §7 #3, the criterion for the whole design: the connection is bound
    // to `node-a` (a real handshake with node-a's key), and then a frame arrives
    // carrying `"source":"node-b"`, signed with node-a's key — i.e. node-a trying
    // to appear as node-b, which is exactly what the old `identityKey` scheme
    // *allowed* for anyone holding the cluster secret.
    //
    // `real` is written **after** `stolen`, and it must not be delivered either:
    // a source mismatch drops the connection, it does not just drop the frame.
    // Without that, an attacker could hide the impersonation attempt at the
    // front of a stream of legitimate-looking events.
    feedAuthed(&bus, "node-a", node_a_key, node_a_key, &.{ stolen, real });

    try std.testing.expectEqual(@as(usize, 0), received);
}

test "an event frame before the handshake is refused" {
    const allocator = std.testing.allocator;
    const peer_key: [32]u8 = @splat(0xf1);
    const receiver_key: [32]u8 = @splat(0xf2);

    var json_buf: [256]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "unbound.topic",
        .payload = "straight-to-the-point",
        .source_node = "node-a",
        .timestamp = 16,
        .seq = 1,
    }, &json_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "unbound-node", "unbound.topic", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("node-a", peer_key);

    // §7 #4: no handshake, just a correctly signed frame on a fresh connection.
    // The first thing an authenticated bus reads must be a handshake response, so
    // this is not an event — it is a malformed answer to the challenge, and the
    // connection goes away. There is no "accept the frame anyway" path.
    const pair = try openSocketPair();
    bus.is_running = true;
    const reader = try std.Thread.spawn(.{}, DistributedEventBus.handleConnection, .{ &bus, pair.conn });

    const challenge = peerReadMessage(allocator, pair.peer);
    try std.testing.expect(challenge != null);
    if (challenge) |c| allocator.free(c);
    peerWriteFrame(allocator, pair.peer, peer_key, json) catch |err| {
        std.log.debug("[test] write to a refused connection: {}", .{err});
    };
    pair.peer.close(std.testing.io);
    reader.join();
    bus.is_running = false;

    try std.testing.expectEqual(@as(usize, 0), received);
}

test "connectToNode refuses a peer with no key before it dials" {
    const allocator = std.testing.allocator;
    var bus = try DistributedEventBus.init(allocator, std.testing.io, "dialer-node");
    defer bus.deinit();
    bus.setOwnKey(@splat(0x77));
    try bus.setPeerKey("node-known", @splat(0x78));

    // §7 #5. The address is deliberately irrelevant: the gate is *before* the
    // dial, so a cluster with credentials never opens a socket it holds no key
    // for (and never falls back to bare frames on the way out).
    const dead = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 1);
    try std.testing.expectError(error.PeerKeyMissing, bus.connectToNode("node-unknown", dead));
    try std.testing.expectError(error.PeerKeyMissing, bus.connectToNode("node-missing-too", dead));

    // The node was not registered either: a refused peer is not a peer.
    try std.testing.expectEqual(@as(usize, 0), bus.getNodeCount());
}

test "the dialer requires the receiver to prove its own identity" {
    const allocator = std.testing.allocator;
    const node_a_key: [32]u8 = @splat(0x91);
    const node_b_key: [32]u8 = @splat(0x92);
    const impostor_key: [32]u8 = @splat(0x93);

    var dialer = try DistributedEventBus.init(allocator, std.testing.io, "node-b");
    defer dialer.deinit();
    dialer.setOwnKey(node_b_key);

    // §7 #6, the positive control: node-b holds node-a's key, node-a proves it
    // holds its own, and the bind completes. Everything below is then about the
    // *proof* and not about a handshake that could never work.
    {
        const pair = try openSocketPair();
        var fixture = ReceiverFixture{
            .allocator = allocator,
            .sock = pair.peer,
            .id = "node-a",
            .reply_key = node_a_key,
            .claim_key = node_b_key,
        };
        const receiver = try std.Thread.spawn(.{}, ReceiverFixture.run, .{&fixture});
        try dialer.setPeerKey("node-a", node_a_key);
        try dialer.bindOutbound(pair.conn, "node-a");
        pair.conn.close(std.testing.io);
        receiver.join();
        try std.testing.expect(fixture.err == null);
    }

    // §7 #7: the same honest receiver, except that it signs its reply with a key
    // that is not the one node-b holds for it. Without the `mac2` check the dialer
    // would accept the connection on the strength of its **own** proof alone —
    // i.e. it would trust "whoever answered", which is the half of the threat the
    // mutual exchange closes.
    {
        const pair = try openSocketPair();
        var fixture = ReceiverFixture{
            .allocator = allocator,
            .sock = pair.peer,
            .id = "node-a",
            .reply_key = impostor_key,
            .claim_key = node_b_key,
        };
        const receiver = try std.Thread.spawn(.{}, ReceiverFixture.run, .{&fixture});
        try std.testing.expectError(error.HandshakeRejected, dialer.bindOutbound(pair.conn, "node-a"));
        pair.conn.close(std.testing.io);
        receiver.join();
        // The fake receiver was not the one that failed: it completed its half.
        try std.testing.expect(fixture.err == null);
    }

    // Both gates are already checked by `connectToNode`; they are checked again
    // inside `bindOutbound` so the dial half cannot be reached without them.
    {
        const pair = try openSocketPair();
        defer pair.peer.close(std.testing.io);
        try std.testing.expectError(error.PeerKeyMissing, dialer.bindOutbound(pair.conn, "node-unknown"));
        pair.conn.close(std.testing.io);
    }
    {
        var keyless = try DistributedEventBus.init(allocator, std.testing.io, "keyless-dialer");
        defer keyless.deinit();
        try keyless.setPeerKey("node-a", node_a_key);
        const pair = try openSocketPair();
        defer pair.peer.close(std.testing.io);
        try std.testing.expectError(error.PeerKeyMissing, keyless.bindOutbound(pair.conn, "node-a"));
        pair.conn.close(std.testing.io);
    }
}

test "two credentialed nodes bind over the network and exchange an event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const node_a_key: [32]u8 = @splat(0xaa);
    const node_b_key: [32]u8 = @splat(0xbb);
    const port: u16 = 19018;
    const topic = "e2e.topic";

    // §7 #6, end to end: the accept path (receiver half) and `connectToNode`
    // (dialer half) wired together over a real socket, not just the two halves
    // against a fixture. If the pair disagreed about which key signs in which
    // direction, the frame below would never arrive.
    var received: usize = 0;
    var bus_a = try framedBus(allocator, "node-a", topic, &received);
    defer bus_a.deinit();
    bus_a.setOwnKey(node_a_key);
    try bus_a.setPeerKey("node-b", node_b_key);
    try bus_a.start(port);
    defer bus_a.stop();

    var bus_b = try DistributedEventBus.init(allocator, io, "node-b");
    defer bus_b.deinit();
    bus_b.setOwnKey(node_b_key);
    try bus_b.setPeerKey("node-a", node_a_key);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    try bus_b.connectToNode("node-a", addr);
    // The handshake is synchronous inside `connectToNode`, so a socket that is
    // still there means both ends completed the bind (`socket = null` is how a
    // refused handshake shows up).
    try std.testing.expectEqual(@as(usize, 1), bus_b.getNodeCount());
    try std.testing.expect(bus_b.nodes.items[0].socket != null);

    try bus_b.publish(topic, "hello");
    // The event is delivered by an accept-side fiber, so give it a moment.
    var waited: usize = 0;
    while (received == 0 and waited < 200) : (waited += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch break;
    }
    try std.testing.expectEqual(@as(usize, 1), received);
}

test "a bare frame on an authenticated port is not delivered" {
    const allocator = std.testing.allocator;
    const peer_key: [32]u8 = @splat(0x81);
    const receiver_key: [32]u8 = @splat(0x82);

    var json_buf: [256]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "downgrade.topic",
        .payload = "bare",
        .source_node = "node-a",
        .timestamp = 17,
        .seq = 1,
    }, &json_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "downgrade-node", "downgrade.topic", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("node-a", peer_key);

    // A peer that reads the challenge and then behaves like an old (or
    // unattended) node: no handshake, a bare frame. That is the downgrade the
    // design forbids — "keys configured but a bare frame arrives → close", with no
    // way back to an unauthenticated delivery on the same port.
    const pair = try openSocketPair();
    bus.is_running = true;
    const reader = try std.Thread.spawn(.{}, DistributedEventBus.handleConnection, .{ &bus, pair.conn });

    const challenge = peerReadMessage(allocator, pair.peer);
    try std.testing.expect(challenge != null);
    if (challenge) |c| allocator.free(c);
    peerWriteFrame(allocator, pair.peer, null, json) catch |err| {
        std.log.debug("[test] write to a refused connection: {}", .{err});
    };
    pair.peer.close(std.testing.io);
    reader.join();
    bus.is_running = false;

    try std.testing.expectEqual(@as(usize, 0), received);
}

test "a replayed frame is dropped even on a fresh connection" {
    const allocator = std.testing.allocator;
    const peer_key: [32]u8 = @splat(0x41);
    const receiver_key: [32]u8 = @splat(0x42);

    var json_buf: [256]u8 = undefined;
    const json = DistributedEventBus.serializeEvent(.{
        .topic = "replay.topic",
        .payload = "once",
        .source_node = "node-r",
        .timestamp = 13,
        .seq = 7,
    }, &json_buf);

    var received: usize = 0;
    var bus = try framedBus(allocator, "replay-node", "replay.topic", &received);
    defer bus.deinit();
    bus.setOwnKey(receiver_key);
    try bus.setPeerKey("node-r", peer_key);

    // Every `feedAuthed` opens a fresh connection *and* a fresh handshake, so
    // this is the reconnect case: the high-water mark is per bound id, not per
    // socket, and a captured frame does not become fresh again by arriving on a
    // new connection that is equally well authenticated.
    feedAuthed(&bus, "node-r", peer_key, peer_key, &.{json});
    try std.testing.expectEqual(@as(usize, 1), received);
    feedAuthed(&bus, "node-r", peer_key, peer_key, &.{json});
    try std.testing.expectEqual(@as(usize, 1), received);
    feedAuthed(&bus, "node-r", peer_key, peer_key, &.{json});
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
    feedAuthed(&bus, "node-r", peer_key, peer_key, &.{newer});
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
    // The send path signs with the node's **own** key, so that is the key the
    // reader on the far end has to verify with.
    bus.setOwnKey(secret);

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
    // and what follows has to be one frame whose MAC verifies against the
    // credential of the node that sent it — its own key.
    const key = secret;
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
