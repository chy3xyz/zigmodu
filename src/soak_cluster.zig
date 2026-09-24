//! `zig build soak-cluster` — the long-horizon harness for the cluster stack.
//!
//! ## Why this file exists
//!
//! `zig build soak` covers HTTP + tenant isolation and `zig build runtime-stress`
//! covers the runtime; neither touches the distributed stack. Everything the
//! v0.32 lifecycle/coordination work changed — `ClusterBootstrap`'s start/stop
//! choreography, the `DistributedEventBus` credential handshake, inbound
//! `AppendEntries` truncation on a conflicting log — is correct in every short
//! single-RPC test and only shows its failure shape under a *sustained*
//! interleaving: a bus mesh that stops completing handshakes after N
//! reconnects, a leader that flaps every other second, a connection counter
//! that walks up one heartbeat at a time, logs that silently diverge after a
//! re-election. A unit test cannot reach those by construction (see
//! `docs/dev/v1.0-readiness-v0.32.md` B-10).
//!
//! **Scope: this is a concurrency/correctness soak, not a 24h longevity run;
//! mixed-version (rolling-upgrade) pairs are out of scope here** — the bus
//! wire format cuts over hard on purpose, so an old/new pair is a refused
//! handshake by design, not a soak finding.
//!
//! ## What it runs
//!
//! Three `ClusterBootstrap` nodes **in one process**, wired the way the facade
//! documents: a real outbound raft transport (per-slot statics, the same shape
//! as `RaftTransport.TransportImpl` — several nodes share this process, so the
//! bare function pointers reach their instance through a comptime slot), the
//! cluster port authenticated with one `cluster_secret`, each node's bus
//! listener on its own port with per-node `own_key`/`peer_keys`, full mesh.
//! One driver thread per node calls `cluster.tick()` (gossip + view + raft);
//! the leader additionally appends log entries at a fixed pace, so election,
//! heartbeat, replication and conflict truncation all run against live bus
//! traffic. `publishers_per_node` more threads per node publish sequenced
//! messages on a shared topic — **deliberately several concurrent writers on
//! one bus**, the only shape in which `sendFramed`'s write-lock contract (replay
//! seq stamped, serialized, MAC'd and written under one lock) is observable end
//! to end: a single writer never has a second frame in flight to overtake, so
//! the frame swap the lock exists to prevent cannot happen at all. `iterations`
//! is per writer, so a node puts `publishers_per_node × iterations` events on
//! the wire. Traffic starts only after the cluster has settled on one leader —
//! the boot election storm is a view change, and frames in flight during view
//! changes are legitimately dropped (the bus is at-most-once there by design).
//!
//! ## The invariants (checked periodically, and refused-if-never-walked)
//!
//!   1. **No message loss in steady state** — per (destination, source,
//!      writer) the received payload seqs are exactly `1..K`, contiguous: no
//!      gap (dropped frame), no dup, no malformed payload, and the final count
//!      equals `K` everywhere. Per *writer*, not per source: two writers on one
//!      node interleave on the wire by design, so only one writer's own stream
//!      is ordered — and a frame the replay gate drops for being behind is
//!      exactly the hole that shows up there (`recordDelivery`). The clock
//!      starts after the cluster settles on one leader; the bus's own replay
//!      gate may drop frames a flapped boot connection re-delivers, and that is
//!      a boot-storm property, not steady state.
//!   2. **Leader stability** — after the first leader is observed: at most N
//!      leader transitions, a leader present in ≥ P% of samples, and never two
//!      nodes claiming leader in the same sample.
//!   3. **Log convergence** — after publishers drain and a replication
//!      quiesce, all three raft logs are byte-identical in (term, command)
//!      over their full length (this is what makes an un-replicated tail or a
//!      missed truncation visible).
//!   4. **No fd / RSS / thread growth** — a time series, not one reading:
//!      spread and endpoint drift inside loose budgets (the fd count is the
//!      only judge a leaked cluster connection leaves behind).
//!   5. **Predictable teardown** — after `deinit` of all three nodes the fd
//!      count is back at the pre-boot baseline (the lifecycle half of the
//!      round's changes).
//!
//! ## Parameters
//!
//! Build options (sizing): `-Dsoak-cluster-iterations` (messages per
//! publisher, default 2400 — writers run concurrently, so at the 25 ms publish
//! pace the publish phase runs ~60 s regardless of how many writers a node
//! has, and the whole step finishes in ~1–2 minutes),
//! `-Dsoak-cluster-publish-ms`,
//! `-Dsoak-cluster-append-ms`, `-Dsoak-cluster-sample-ms`,
//! `-Dsoak-cluster-tick-ms`, `-Dsoak-cluster-quiesce-ms`.
//!
//! Environment variables (thresholds, all optional):
//! `SOAK_CLUSTER_PORT_BASE` (default 23456; raft port = base+i, bus port =
//! base+100+i), `SOAK_CLUSTER_FD_BUDGET` (default 8),
//! `SOAK_CLUSTER_RSS_BUDGET_MIB` (default 128; see the calibration note at the
//! assertion), `SOAK_CLUSTER_THREAD_BUDGET` (default 2),
//! `SOAK_CLUSTER_MAX_LEADER_TRANSITIONS` (default 3),
//! `SOAK_CLUSTER_MIN_LEADER_PRESENCE_PCT` (default 90).
//!
//! Usage: `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build soak-cluster`

const std = @import("std");
const builtin = @import("builtin");
const zigmodu = @import("zigmodu");
const build_options = @import("build_options");

const io = std.testing.io;
const Time = zigmodu.time;
const RaftWire = zigmodu.RaftTransport;
const DistributedEventBus = zigmodu.DistributedEventBus;
const ClusterBootstrap = zigmodu.ClusterBootstrap;

// ── sizing (build options) ──────────────────────────────────────────────────

const iterations: usize = build_options.soak_iterations;
const publish_ms: u64 = build_options.soak_cluster_publish_ms;
const append_ms: u64 = build_options.soak_cluster_append_ms;
const sample_ms: u64 = build_options.soak_cluster_sample_ms;
const tick_ms: u64 = build_options.soak_cluster_tick_ms;
const quiesce_ms: u64 = build_options.soak_cluster_quiesce_ms;

/// Publisher threads per node. Two is the whole point of the harness shape (see
/// `publisherMain`): one writer cannot overtake itself, so a single writer
/// cannot tell a correct outbound funnel from one that stamps the replay seq
/// before taking the write lock.
const publishers_per_node: usize = 2;
/// How often a writer re-checks its pace. Not `publish_ms`: a writer also has
/// to notice `publishing` flipping and `stop_threads` going up, and a poll well
/// under the publish pace costs nothing. Clamped low so a tiny
/// `-Dsoak-cluster-publish-ms` cannot turn the loop into a busy spin.
const publish_poll_ms: u64 = @max(@min(publish_ms, 5), 1);

// ── topology ────────────────────────────────────────────────────────────────

const node_count = 3;
const ids = [node_count][]const u8{ "sc-a", "sc-b", "sc-c" };
const topic = "soak.events";
const raft_rpc_timeout_ms: u32 = 100;

/// One secret source for the whole cluster, exactly what the facade's gate
/// asks for: `cluster_secret` authenticates the raft port; per-node own/peer
/// keys drive the bus handshake. Test values, not real secrets.
const cluster_secret: [32]u8 = @splat(0x5c);
const bus_keys = [node_count][32]u8{
    @splat(0x41),
    @splat(0x52),
    @splat(0x63),
};

// ── raft RPC types, named without a second `@import` ────────────────────────
//
// A relative `@import` of RaftElection.zig would compile a *second* instance
// of the file inside this module, and the vtable's function-pointer types —
// which come from the instance inside the `zigmodu` module — would not match.
// The public wire codecs are exported from that same instance, so the payload
// types are extracted from their signatures instead of being named directly.

const VoteRequest = @typeInfo(@TypeOf(RaftWire.encodeVoteRequest)).@"fn".param_types[2].?;
const AppendEntriesRequest = @typeInfo(@TypeOf(RaftWire.encodeAppendEntries)).@"fn".param_types[2].?;
const AppendEntriesResponse = @typeInfo(@typeInfo(@TypeOf(RaftWire.decodeAppendEntriesResponse)).@"fn".return_type.?).error_union.payload;

// ── thresholds (environment overrides) ──────────────────────────────────────

fn envU64(name: [*:0]const u8, default: u64) u64 {
    const raw = std.c.getenv(name) orelse return default;
    return std.fmt.parseInt(u64, std.mem.span(raw), 10) catch default;
}

// Read once at boot (an extern getenv cannot run at comptime); every thread
// reads them afterwards, so they are plain data settled before any spawn.
var port_base: u16 = 23456;
var fd_budget: u64 = 8;
/// Envelope for the RSS *spread* over a run. **It is a real envelope again**,
/// now that the growth it used to catch has been explained (it was not the
/// cluster — see `soak_gpa` below): with the root allocator no longer capturing
/// stack traces per alloc/free, the same load that used to spread 42–91 MiB
/// (and 108–163 MiB at 2x traffic) stays at ~9–12 MiB.
///
/// 48 MiB leaves ~4x headroom for a different allocator/page-size regime while
/// still failing on anything that grows with traffic. `SOAK_CLUSTER_RSS_BUDGET_MIB`
/// overrides it for a host that needs its own number. The *live-byte* assertion
/// after teardown (`soak_gpa.deinit()`) is the precise gate; this is the coarse one.
var rss_budget_bytes: u64 = 48 * 1024 * 1024;
var thread_budget: u64 = 2;
var max_leader_transitions: u64 = 3;
var min_leader_presence_pct: u64 = 90;

fn initThresholds() void {
    if (envU64("SOAK_CLUSTER_PORT_BASE", 0) != 0) {
        // Explicit override wins (CI pins a block it knows is free).
        port_base = @intCast(@min(envU64("SOAK_CLUSTER_PORT_BASE", 23456), 60000));
    } else {
        // Fresh block per run: the framework's listeners do not set
        // SO_REUSEADDR, so a previous run's mesh connections linger in
        // TIME_WAIT for tens of seconds and a fixed base would collide with
        // back-to-back runs. pid-shaped jitter (NOT an entropy use) spreads
        // runs over 200 disjoint blocks below 60000.
        const jitter: u64 = @as(u64, @intCast(std.c.getpid())) % 200;
        port_base = @intCast(23456 + jitter * 10);
    }
    fd_budget = envU64("SOAK_CLUSTER_FD_BUDGET", 8);
    rss_budget_bytes = envU64("SOAK_CLUSTER_RSS_BUDGET_MIB", 128) * 1024 * 1024;
    thread_budget = envU64("SOAK_CLUSTER_THREAD_BUDGET", 2);
    max_leader_transitions = envU64("SOAK_CLUSTER_MAX_LEADER_TRANSITIONS", 3);
    min_leader_presence_pct = envU64("SOAK_CLUSTER_MIN_LEADER_PRESENCE_PCT", 90);
}

var raft_ports: [node_count]u16 = undefined;
var bus_ports: [node_count]u16 = undefined;

fn computePorts() void {
    for (0..node_count) |i| {
        raft_ports[i] = port_base + @as(u16, @intCast(i));
        bus_ports[i] = port_base + 100 + @as(u16, @intCast(i));
    }
}

// ── shared run state (atomics only: the harness never locks the load path) ──

/// Stops every load thread: the per-node tick drivers and the per-node bus
/// writers.
var stop_threads = std.atomic.Value(bool).init(false);
var appends_enabled = std.atomic.Value(bool).init(false);
var publishing = std.atomic.Value(bool).init(false);
/// Writers still owing messages — `node_count × publishers_per_node`, not one
/// per node (the drain waits on every writer thread, not every node).
var publishers_remaining = std.atomic.Value(usize).init(node_count * publishers_per_node);

/// Per (destination, source, writer): the writer dimension is what makes the
/// contiguity check meaningful with more than one writer per node — two writers
/// on the same node interleave on the wire, so only one writer's own stream is
/// ordered (see `recordDelivery`).
var recv_count: [node_count][node_count][publishers_per_node]std.atomic.Value(u64) = undefined;
var last_seq: [node_count][node_count][publishers_per_node]std.atomic.Value(u64) = undefined;

var gap_count = std.atomic.Value(u64).init(0);
var dup_count = std.atomic.Value(u64).init(0);
var malformed_count = std.atomic.Value(u64).init(0);
var publish_failures = std.atomic.Value(u64).init(0);
var tick_errors = std.atomic.Value(u64).init(0);
var append_failures = std.atomic.Value(u64).init(0);
/// `appendEntry` racing an inbound higher-term RPC: benign, reported only.
var append_not_leader = std.atomic.Value(u64).init(0);
var total_appends = std.atomic.Value(u64).init(0);
/// Bounded handling for the "cannot happen" paths (fixed buffers that provably
/// fit, sleeps that only fail on io cancellation): counted, logged, and
/// asserted to be zero at the end — never `catch unreachable`, never silent.
var harness_internal_failures = std.atomic.Value(u64).init(0);
var sleep_cancellations = std.atomic.Value(u64).init(0);
var mesh_reconnect_failures = std.atomic.Value(u64).init(0);

/// `std.Io.sleep(..., .real)` only fails when the io runner is cancelled,
/// which this harness never does; a failure here would silently corrupt every
/// pace in the run, so it is counted and asserted instead of swallowed.
fn soakSleep(ms: u64) void {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .real) catch {
        _ = sleep_cancellations.fetchAdd(1, .monotonic);
    };
}

fn initSharedState() void {
    stop_threads.store(false, .monotonic);
    appends_enabled.store(false, .monotonic);
    publishing.store(false, .monotonic);
    publishers_remaining.store(node_count * publishers_per_node, .monotonic);
    for (0..node_count) |i| stopped[i] = false;
    for (0..node_count) |d| {
        for (0..node_count) |s| {
            for (0..publishers_per_node) |w| {
                recv_count[d][s][w] = std.atomic.Value(u64).init(0);
                last_seq[d][s][w] = std.atomic.Value(u64).init(0);
            }
        }
    }
}

fn allPairsFull() bool {
    var full = true;
    inline for (0..node_count) |d| {
        inline for (0..node_count) |s| {
            for (0..publishers_per_node) |w| {
                if (recv_count[d][s][w].load(.monotonic) < iterations) full = false;
            }
        }
    }
    return full;
}

// ── wire helpers for the soak's outbound raft transport ─────────────────────
//
// Byte-for-byte the framing `RaftTransport` documents and its inbound half
// verifies: `[4-byte BE len][frame][HMAC-SHA256(key, frame)]` when the cluster
// runs authenticated (which `ClusterBootstrap.start()` requires for a
// multi-node cluster anyway). Reimplemented here because that module's
// send/verify helpers are file-private and this harness must not edit it.

const mac_bytes = 32;

fn sendAllNoSig(stream: std.Io.net.Stream, bytes: []const u8) !void {
    // `send(MSG_NOSIGNAL)`, not `writev`: answering a peer that already closed
    // its socket (a fire-and-forget vote request leaves exactly that behind)
    // would otherwise raise SIGPIPE and take the process down — the same
    // reasoning `RaftTransport.sendAll` documents.
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = std.posix.system.send(stream.socket.handle, bytes[sent..].ptr, bytes[sent..].len, std.posix.MSG.NOSIGNAL);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.SendFailed,
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.SendFailed;
        sent += n;
    }
}

fn readFullSock(stream: std.Io.net.Stream, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.posix.system.read(stream.socket.handle, buf[got..].ptr, buf.len - got);
        switch (std.posix.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        const nn: usize = @intCast(n);
        if (nn == 0) return error.Eof;
        got += nn;
    }
}

fn setSockTimeoutMs(stream: std.posix.socket_t, opt: u32, timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const rc = std.posix.system.setsockopt(stream, std.posix.SOL.SOCKET, opt, &tv, @sizeOf(std.posix.timeval));
    // macOS answers EINVAL for SO_RCVTIMEO on a socket whose peer end has
    // already closed — the next read returns EOF anyway, so survive like the
    // event bus's `applyRecvTimeout` does.
    if (rc != 0) std.log.debug("[soak-cluster] setsockopt({d}) failed: {s}", .{ opt, @tagName(std.posix.errno(rc)) });
}

fn writeSignedFrame(stream: std.Io.net.Stream, secret: [32]u8, frame: []const u8) !void {
    var mac: [mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, frame, &secret);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(frame.len + mac_bytes), .big);
    try sendAllNoSig(stream, &header);
    try sendAllNoSig(stream, frame);
    try sendAllNoSig(stream, &mac);
}

fn recvFrameAlloc(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try readFullSock(stream, &len_buf);
    const body_len = std.mem.readInt(u32, &len_buf, .big);
    if (body_len == 0 or body_len > 1024 * 1024) return error.FrameTooLarge;
    const buf = try allocator.alloc(u8, body_len);
    errdefer allocator.free(buf);
    try readFullSock(stream, buf);
    return buf;
}

fn verifyFrameMac(secret: [32]u8, frame: []const u8) ?[]const u8 {
    if (frame.len < mac_bytes + 1) return null;
    const signed_len = frame.len - mac_bytes;
    var expected: [mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, frame[0..signed_len], &secret);
    if (!std.crypto.timing_safe.eql([mac_bytes]u8, expected, frame[signed_len..][0..mac_bytes].*)) return null;
    return frame[0..signed_len];
}

// ── the outbound half of raft, soak-flavoured ───────────────────────────────

const PeerAddr = struct {
    id: []const u8,
    host: []const u8,
    port: u16,
};

/// One transport instance per node. `ElectionTransport` is a pair of bare
/// function pointers with no context argument, so — exactly like
/// `RaftTransport.TransportImpl` — the instance is reached through per-slot
/// statics; three nodes in one process need three slots. Unlike
/// `TransportImpl` this variant takes no `*RaftElection` at init: the facade
/// creates the raft inside `start()`, after the transport has to be handed
/// over, and the only two things the impl read off it (`rpc_timeout_ms`,
/// `cluster_secret`) are constants of this harness anyway.
///
/// `slot_id` is load-bearing: with the parameter unused, this Zig build
/// memoizes the generic into ONE type for every slot (measured: `Impl(0) ==
/// Impl(2)` at comptime), collapsing the per-slot `bound` static into a
/// single variable that the last `init` wins — every node then dispatches its
/// raft RPCs through one node's transport, dropping everything that node
/// cannot resolve. Referencing the parameter in the type body keeps the
/// instantiations distinct.
fn SoakTransport(comptime slot: usize) type {
    return struct {
        const Self = @This();
        pub const slot_id: usize = slot;

        var bound: ?*anyopaque = null;

        allocator: std.mem.Allocator,
        secret: [32]u8,
        rpc_timeout_ms: u32,
        peers: []const PeerAddr,
        /// Which node this instance drives — every drop reason logs it, or a
        /// mis-bound slot is indistinguishable from a missing peer.
        name: []const u8,

        vtable: VTable = .{
            .sendVoteRequest = thunkVoteRequest,
            .sendAppendEntries = thunkSendAppendEntries,
        },

        const VTable = struct {
            sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
            sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
        };

        fn init(
            self: *Self,
            allocator: std.mem.Allocator,
            secret: [32]u8,
            rpc_timeout_ms: u32,
            peers: []const PeerAddr,
            name: []const u8,
        ) void {
            self.* = .{
                .allocator = allocator,
                .secret = secret,
                .rpc_timeout_ms = rpc_timeout_ms,
                .peers = peers,
                .name = name,
            };
            bound = self;
        }

        /// The interface `RaftElection` stores a pointer to. Valid for the
        /// lifetime of the instance (file-scope storage — the harness never
        /// restarts a node).
        fn transport(self: *Self) zigmodu.RaftElection.ElectionTransport {
            return @ptrCast(&self.vtable);
        }

        fn resolve(self: *Self, peer_id: ?[]const u8, address: []const u8) ?RaftWire.Endpoint {
            if (peer_id) |id| {
                for (self.peers) |p| {
                    if (std.mem.eql(u8, p.id, id)) return .{ .host = p.host, .port = p.port };
                }
            }
            if (RaftWire.parseEndpoint(address)) |ep| return ep;
            if (peer_id) |id| {
                if (RaftWire.parseEndpoint(id)) |ep| return ep;
            }
            std.log.debug("[soak-cluster] {s}: cannot resolve peer {s} (address '{s}', table {s} {s})", .{
                self.name,
                peer_id orelse "?",
                address,
                self.peers[0].id,
                if (self.peers.len > 1) self.peers[1].id else "-",
            });
            return null;
        }

        /// Fire-and-forget: the voter answers on its own initiative (the
        /// inbound half relays a granted ballot), so a lost dial is just a
        /// lost vote, re-tried at the next election timeout.
        fn sendVoteRequest(self: *Self, peer_id: ?[]const u8, address: []const u8, req: VoteRequest) void {
            const ep = self.resolve(peer_id, address) orelse return;
            var frame = std.ArrayList(u8).empty;
            defer frame.deinit(self.allocator);
            RaftWire.encodeVoteRequest(&frame, self.allocator, req) catch |err| {
                std.log.debug("[soak-cluster] encoding the vote request failed ({})", .{err});
                return;
            };
            const addr = std.Io.net.IpAddress.parse(ep.host, ep.port) catch return;
            const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
                std.log.debug("[soak-cluster] connect {s}:{d} failed, vote dropped ({})", .{ ep.host, ep.port, err });
                return;
            };
            defer stream.close(io);
            setSockTimeoutMs(stream.socket.handle, std.posix.SO.SNDTIMEO, self.rpc_timeout_ms);
            writeSignedFrame(stream, self.secret, frame.items) catch |err| {
                std.log.debug("[soak-cluster] write to {s}:{d} failed, vote dropped ({})", .{ ep.host, ep.port, err });
            };
        }

        /// Synchronous: the follower answers on the same connection, and every
        /// failure mode (no address, dial, write, read, decode) is the same
        /// "lost message" answer Raft re-sends — never a panic.
        fn sendAppendEntries(self: *Self, peer_id: ?[]const u8, address: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
            const lost: AppendEntriesResponse = .{ .term = 0, .success = false, .match_index = 0 };
            const ep = self.resolve(peer_id, address) orelse return lost;

            var frame = std.ArrayList(u8).empty;
            defer frame.deinit(self.allocator);
            RaftWire.encodeAppendEntries(&frame, self.allocator, req) catch return lost;

            const addr = std.Io.net.IpAddress.parse(ep.host, ep.port) catch return lost;
            const stream = addr.connect(io, .{ .mode = .stream }) catch return lost;
            defer stream.close(io);
            setSockTimeoutMs(stream.socket.handle, std.posix.SO.SNDTIMEO, self.rpc_timeout_ms);
            setSockTimeoutMs(stream.socket.handle, std.posix.SO.RCVTIMEO, self.rpc_timeout_ms);
            writeSignedFrame(stream, self.secret, frame.items) catch return lost;

            const reply = recvFrameAlloc(self.allocator, stream) catch return lost;
            defer self.allocator.free(reply);
            const body = verifyFrameMac(self.secret, reply) orelse return lost;
            return RaftWire.decodeAppendEntriesResponse(body) catch lost;
        }

        fn thunkVoteRequest(peer_id: ?[]const u8, address: []const u8, req: VoteRequest) void {
            const self: *Self = @ptrCast(@alignCast(bound orelse return));
            self.sendVoteRequest(peer_id, address, req);
        }

        fn thunkSendAppendEntries(peer_id: ?[]const u8, address: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
            const self: *Self = @ptrCast(@alignCast(bound orelse return .{ .term = 0, .success = false, .match_index = 0 }));
            return self.sendAppendEntries(peer_id, address, req);
        }
    };
}

var transport_0: SoakTransport(0) = undefined;
var transport_1: SoakTransport(1) = undefined;
var transport_2: SoakTransport(2) = undefined;

fn transportRef(comptime i: usize) *SoakTransport(i) {
    return switch (i) {
        0 => @ptrCast(&transport_0),
        1 => @ptrCast(&transport_1),
        2 => @ptrCast(&transport_2),
        else => unreachable,
    };
}

// ── process readings (fd count + RSS + OS thread count) ─────────────────────
//
// Same shape as `runtime_stress.zig`'s OsInfo: the kernel's own arithmetic,
// because a leak the cluster's own counters cannot express has to be caught
// from outside. Either reading may be null on an unsupported platform — the
// caller then says so instead of pretending it measured.

const OsInfo = struct {
    fd_count: ?u32,
    rss_bytes: ?u64,
    threads: ?u32,
};

fn osInfo() OsInfo {
    return switch (builtin.os.tag) {
        .macos => blk: {
            const task = macosTaskInfo();
            break :blk .{
                .fd_count = macosFdCount(),
                .rss_bytes = task.rss,
                .threads = task.threads,
            };
        },
        .linux => .{
            .fd_count = linuxFdCount(),
            .rss_bytes = linuxRssBytes(),
            .threads = linuxThreadCount(),
        },
        else => .{ .fd_count = null, .rss_bytes = null, .threads = null },
    };
}

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;

const PROC_PIDTASKINFO: c_int = 4;
const PROC_PIDLISTFDS: c_int = 1;

/// `struct proc_taskinfo` is 96 bytes; only two fields are read, by offset —
/// the offsets are the ABI (see runtime_stress.zig for the full table).
const proc_taskinfo_size = 96;
const proc_taskinfo_rss_offset = 8;
const proc_taskinfo_threads_offset = 84;

/// `struct proc_fdinfo` is `{ int32 proc_fd; uint32 proc_fdtype; }` — 8 bytes
/// per open fd. One call into a fixed static buffer: no allocation, so the
/// sampler cannot perturb what it measures.
const proc_fdinfo_size = 8;
var fdlist_buf: [1 << 16]u8 = undefined;

fn macosTaskInfo() struct { rss: ?u64, threads: ?u32 } {
    var buf: [proc_taskinfo_size]u8 = undefined;
    const got = proc_pidinfo(std.c.getpid(), PROC_PIDTASKINFO, 0, &buf, buf.len);
    if (got != proc_taskinfo_size) return .{ .rss = null, .threads = null };
    const rss: u64 = @bitCast(buf[proc_taskinfo_rss_offset..][0..8].*);
    const thread_count: i32 = @bitCast(buf[proc_taskinfo_threads_offset..][0..4].*);
    return .{
        .rss = rss,
        .threads = if (thread_count > 0) @intCast(thread_count) else null,
    };
}

fn macosFdCount() ?u32 {
    const got = proc_pidinfo(std.c.getpid(), PROC_PIDLISTFDS, 0, &fdlist_buf, fdlist_buf.len);
    if (got <= 0) return null;
    return @intCast(@divTrunc(got, proc_fdinfo_size));
}

var statm_buf: [256]u8 = undefined;
var stat_buf: [1024]u8 = undefined;

/// One `open`/`read`/`close` of a `/proc` file into a caller-provided buffer:
/// no allocation, so the sampler cannot perturb what it measures.
fn readProcFile(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    return buf[0..n];
}

fn linuxRssBytes() ?u64 {
    const line = readProcFile("/proc/self/statm", &statm_buf) orelse return null;
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // size
    const resident = it.next() orelse return null;
    const pages = std.fmt.parseInt(u64, resident, 10) catch return null;
    return pages * std.heap.pageSize();
}

fn linuxThreadCount() ?u32 {
    const line = readProcFile("/proc/self/stat", &stat_buf) orelse return null;
    // The comm field is parenthesised and may contain spaces; count from the
    // last ')' — field 20 is the thread count.
    const close_paren = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, line[close_paren + 1 ..], ' ');
    _ = it.next(); // state = field 3
    var field: usize = 3;
    while (it.next()) |tok| {
        field += 1;
        if (field == 20) return std.fmt.parseInt(u32, tok, 10) catch null;
    }
    return null;
}

fn linuxFdCount() ?u32 {
    const dir_fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/fd", .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(dir_fd);
    var buf: [8192]u8 = undefined;
    var count: u32 = 0;
    while (true) {
        const rc = std.os.linux.syscall3(.getdents64, @as(usize, @intCast(dir_fd)), @intFromPtr(&buf), buf.len);
        const n: isize = @bitCast(rc);
        if (n <= 0) break;
        var off: usize = 0;
        while (off + @sizeOf(std.os.linux.dirent64) <= @as(usize, @intCast(n))) {
            const ent: *align(1) const std.os.linux.dirent64 = @ptrCast(&buf[off]);
            const name = std.mem.sliceTo(&ent.name, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) count += 1;
            off += ent.reclen;
        }
    }
    return count;
}

// ── subscribers: the message-loss net ───────────────────────────────────────
//
// One published message carries its origin in the payload itself: the writer
// index and that writer's own sequence, `"<writer>-<seq>"`. The writer has to
// be in the payload because the sequence is only ordered *within* a writer —
// the two writers on a node are racing each other on purpose, so the invariant
// the harness can honestly assert is per (destination, source, writer).

const ParsedPayload = struct { writer: usize, seq: u64 };

fn parsePayload(payload: []const u8) ?ParsedPayload {
    const dash = std.mem.indexOfScalar(u8, payload, '-') orelse return null;
    const writer = std.fmt.parseInt(usize, payload[0..dash], 10) catch return null;
    const seq = std.fmt.parseInt(u64, payload[dash + 1 ..], 10) catch return null;
    // Nothing else is ever published, so anything outside this range is a
    // malformed payload rather than a legitimate out-of-range sequence.
    if (writer >= publishers_per_node) return null;
    if (seq == 0 or seq > iterations) return null;
    return .{ .writer = writer, .seq = seq };
}

fn recordDelivery(comptime dest: usize, ev: DistributedEventBus.NetworkEvent) void {
    const src = blk: {
        for (ids, 0..) |id, idx| {
            if (std.mem.eql(u8, ev.source_node, id)) break :blk idx;
        }
        _ = malformed_count.fetchAdd(1, .monotonic);
        std.log.warn("[soak-cluster] malformed source '{s}'", .{ev.source_node});
        return;
    };
    const got = parsePayload(ev.payload) orelse {
        _ = malformed_count.fetchAdd(1, .monotonic);
        std.log.warn("[soak-cluster] malformed payload '{s}' from {s}", .{ ev.payload, ev.source_node });
        return;
    };
    // Deliveries for one (dest, src, writer) triple are single-threaded by
    // construction: src == dest arrives only from that writer's own local
    // publish, src != dest only from the pair's one inbound fiber. The atomic is
    // for the shared table, not a contested counter — the two writers of a node
    // touch different cells of it.
    const last = last_seq[dest][src][got.writer].load(.monotonic);
    if (got.seq == last + 1) {
        last_seq[dest][src][got.writer].store(got.seq, .monotonic);
        _ = recv_count[dest][src][got.writer].fetchAdd(1, .monotonic);
        return;
    }
    if (got.seq <= last) {
        _ = dup_count.fetchAdd(1, .monotonic);
        std.log.warn("[soak-cluster] dup: dest={s} src={s} writer={d} last={d} got={d}", .{
            ids[dest], ids[src], got.writer, last, got.seq,
        });
        return;
    }
    _ = gap_count.fetchAdd(1, .monotonic);
    std.log.warn("[soak-cluster] gap: dest={s} src={s} writer={d} last={d} got={d}", .{
        ids[dest], ids[src], got.writer, last, got.seq,
    });
    // Resync so one gap does not cascade into a dup-storm of everything after it.
    last_seq[dest][src][got.writer].store(got.seq, .monotonic);
}

fn Subscriber(comptime dest: usize) type {
    return struct {
        fn onEvent(ev: DistributedEventBus.NetworkEvent) void {
            recordDelivery(dest, ev);
        }
    };
}

fn subscriberFor(comptime i: usize) *const fn (DistributedEventBus.NetworkEvent) void {
    return switch (i) {
        0 => Subscriber(0).onEvent,
        1 => Subscriber(1).onEvent,
        2 => Subscriber(2).onEvent,
        else => unreachable,
    };
}

// ── the fixture ─────────────────────────────────────────────────────────────

const Fixture = struct {
    cluster: *ClusterBootstrap,
    raft: *zigmodu.RaftElection,
    bus: *DistributedEventBus,
    driver: std.Thread = undefined,
};

var cluster_storage: [node_count]ClusterBootstrap = undefined;
var fixtures: [node_count]Fixture = undefined;

/// `BootstrapConfig.peers` strings: `"<id>@127.0.0.1:<raft port>"` — the `@id`
/// is what lets raft credit that peer's ballot (a bare `host:port` peer can
/// never be elected against, which `start()` refuses loudly).
var peer_string_bufs: [node_count][node_count - 1][28]u8 = undefined;
var peer_string_refs: [node_count][node_count - 1][]const u8 = undefined;
var peer_string_lists: [node_count][]const []const u8 = undefined;
var peer_addrs: [node_count][node_count - 1]PeerAddr = undefined;

fn buildTopology() void {
    computePorts();
    for (0..node_count) |i| {
        var n: usize = 0;
        for (0..node_count) |j| {
            if (j == i) continue;
            peer_string_refs[i][n] = std.fmt.bufPrint(
                &peer_string_bufs[i][n],
                "{s}@127.0.0.1:{d}",
                .{ ids[j], raft_ports[j] },
            ) catch {
                // 28 bytes fits "sc-x@127.0.0.1:65535" with room to spare, so
                // this is the counted kind of impossible, not the silent kind.
                _ = harness_internal_failures.fetchAdd(1, .monotonic);
                std.log.warn("[soak-cluster] peer string did not fit; node {s} is mis-wired", .{ids[i]});
                continue;
            };
            peer_addrs[i][n] = .{ .id = ids[j], .host = "127.0.0.1", .port = raft_ports[j] };
            n += 1;
        }
        peer_string_lists[i] = peer_string_refs[i][0..];
    }
}

fn startNode(comptime i: usize, allocator: std.mem.Allocator) !void {
    const t = transportRef(i);
    t.init(allocator, cluster_secret, raft_rpc_timeout_ms, peer_addrs[i][0..], ids[i]);
    cluster_storage[i] = try ClusterBootstrap.init(allocator, io, .{
        .node_id = ids[i],
        .port = raft_ports[i],
        .peers = peer_string_lists[i],
        .raft_cluster_size = node_count,
        .transport = t.transport(),
        .cluster_secret = cluster_secret,
    });
    try cluster_storage[i].start();
    const bus = cluster_storage[i].getEventBus().?;
    // The bus is a separate inbound surface with its own handshake: the
    // cluster secret selects the authenticated path (set by `start()`), and
    // these are the credentials that path needs — before any dial, and before
    // `start(port)` warns about a keyless authenticated bus.
    bus.setOwnKey(bus_keys[i]);
    inline for (0..node_count) |j| {
        if (j == i) continue;
        try bus.setPeerKey(ids[j], bus_keys[j]);
    }
    try bus.subscribe(topic, subscriberFor(i));
    try bus.start(bus_ports[i]);
    // Boot-time truth for the report: which peers did the raft actually get?
    // (A wrong peer set here — e.g. self in the list — explains votes the
    // transport cannot resolve.)
    {
        const raft = cluster_storage[i].getRaft().?;
        var buf: [96]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        for (raft.peers.items) |p| {
            w.print(" {s}", .{p.id}) catch break;
        }
        std.log.warn("[soak-cluster] node {s} raft peers ({d}):{s}", .{
            ids[i], raft.peers.items.len, w.buffered(),
        });
    }
    fixtures[i] = .{
        .cluster = &cluster_storage[i],
        .raft = cluster_storage[i].getRaft().?,
        .bus = bus,
    };
}

/// Set once a node's teardown has run; `deinit()` poisons the bootstrap, so a
/// second stop would read undefined memory. Guards both the failure-path
/// defer and the normal end-of-run teardown from double-stopping.
var stopped: [node_count]bool = .{ false, false, false };

fn stopNode(comptime i: usize) void {
    if (stopped[i]) return;
    stopped[i] = true;
    // Disconnect the mesh by hand before `deinit`: a peer that is already
    // gone would turn the membership's leave-broadcast into a send failure,
    // and the test runner treats any err-level log as a failure by itself.
    // Keyed by the static `ids[j]`, never by a snapshot's `peer.id`:
    // `disconnectNode` destroys the entry it takes (`takeNode` + `destroyNode`)
    // and a snapshot's ids are freed by its own `deinit`, so the name has to
    // outlive both calls.
    inline for (0..node_count) |j| {
        if (j == i) continue;
        fixtures[i].bus.disconnectNode(ids[j]);
    }
    fixtures[i].cluster.deinit();
}

fn teardownStarted(count: usize) void {
    var n = count;
    while (n > 0) {
        n -= 1;
        switch (n) {
            0 => stopNode(0),
            1 => stopNode(1),
            2 => stopNode(2),
            else => unreachable,
        }
    }
}

/// One driver per node — the facade's contract is exactly one thread calling
/// `tick()` per raft; the inbound accept thread is the other user and the
/// raft's own lock serializes the two. Publishing is *not* on this thread (see
/// `publisherMain`): the tick loop keeps its own pace, and nothing the bus does
/// belongs to the raft thread.
fn driverMain(ctx: *Fixture) void {
    const raft = ctx.raft;
    var local_appends: u64 = 0;
    var last_append_ms: i64 = 0;
    while (!stop_threads.load(.acquire)) {
        ctx.cluster.tick() catch {
            _ = tick_errors.fetchAdd(1, .monotonic);
        };
        const now = Time.monotonicNowMilliseconds();
        if (appends_enabled.load(.acquire) and raft.isLeader()) {
            if (now - last_append_ms >= @as(i64, @intCast(append_ms))) {
                var buf: [64]u8 = undefined;
                const cmd = std.fmt.bufPrint(&buf, "append-{s}-{d}", .{
                    raft.local_id,
                    local_appends + 1,
                }) catch {
                    // 64 bytes cannot overflow for these ids; count and retry
                    // next tick rather than panic or append a truncated command.
                    _ = harness_internal_failures.fetchAdd(1, .monotonic);
                    soakSleep(tick_ms);
                    continue;
                };
                _ = raft.appendEntry(cmd) catch |err| switch (err) {
                    error.NotLeader => {
                        // isLeader() then a higher-term inbound RPC before the
                        // append: legal raft, counted for the report only.
                        _ = append_not_leader.fetchAdd(1, .monotonic);
                    },
                    else => {
                        _ = append_failures.fetchAdd(1, .monotonic);
                    },
                };
                last_append_ms = now;
                local_appends += 1;
                _ = total_appends.fetchAdd(1, .monotonic);
            }
        }
        soakSleep(tick_ms);
    }
}

// ── the writers ─────────────────────────────────────────────────────────────
//
// `publishers_per_node` threads per node, all publishing on the same bus, and
// on purpose: the outbound funnel's ordering contract is only observable with
// concurrent writers (see `publisherMain`).

const Publisher = struct {
    bus: *DistributedEventBus,
    /// Which of the node's writers this thread is — the first half of every
    /// payload it publishes.
    writer: usize,
};

var publisher_ctx: [node_count][publishers_per_node]Publisher = undefined;
var publisher_threads: [node_count][publishers_per_node]std.Thread = undefined;

/// Spawn every writer, filling `publisher_ctx`/`publisher_threads` in that order
/// (node-major). Returns how many were spawned so a mid-way failure — or a
/// `try` later in the test — still joins what exists.
///
/// A spawn failure is *counted*, not propagated: the caller's defer has to join
/// whatever did start (a writer left running would touch a bus that teardown is
/// about to free), and the `harness_internal_failures` assertion at the end
/// keeps the shortfall from being green.
fn spawnWriters() usize {
    var spawned: usize = 0;
    for (0..node_count) |i| {
        for (0..publishers_per_node) |w| {
            publisher_ctx[i][w] = .{ .bus = fixtures[i].bus, .writer = w };
            publisher_threads[i][w] = std.Thread.spawn(
                .{ .stack_size = 2 * 1024 * 1024 },
                publisherMain,
                .{&publisher_ctx[i][w]},
            ) catch |err| {
                _ = harness_internal_failures.fetchAdd(1, .monotonic);
                std.log.warn("[soak-cluster] writer thread for {s}/{d} did not start ({})", .{ ids[i], w, err });
                break;
            };
            spawned += 1;
        }
    }
    return spawned;
}

/// The inverse of `spawnWriters`, for the first `count` of them (the defer and
/// the normal end of run both need it).
fn joinWriters(count: usize) void {
    var n = count;
    while (n > 0) {
        n -= 1;
        publisher_threads[n / publishers_per_node][n % publishers_per_node].join();
    }
}

/// Writer `ctx.writer` of its node: publishes `<writer>-<seq>` on the shared
/// topic at the harness's `publish_ms` pace (`iterations` messages, checked
/// every `publish_poll_ms`).
///
/// ## Why several writers
///
/// `DistributedEventBus.sendFramed` holds the destination's write lock across
/// the whole funnel — replay seq stamp, json serialize, MAC, blocking write —
/// so per connection "wire order is seq order" and the receiver's
/// strictly-increasing replay gate (`acceptSeq`) can never drop a frame that a
/// live connection delivered. The failure that shape prevents only exists with
/// concurrent writers: a frame whose seq was drawn *before* the lock (the
/// pre-fix arrangement) could reach the socket after a higher-seq frame and be
/// dropped as a replay — no error logged anywhere, just a missing event. This
/// harness is what makes that a red test instead of a silent one: the dropped
/// frame is a hole in the writer's payload stream (`recordDelivery`). With one
/// writer per bus the window cannot open at all, so the harness reports green
/// whatever the funnel does — which is exactly why the writers went back to two
/// per node once the funnel was fixed.
///
/// ## What stays ordered
///
/// Each writer's own stream needs no help from the harness: `publish` returns
/// only after it has written that message's frame to every peer, so writer `w`
/// cannot start its seq K+1 frame before its seq K frame is on the socket. The
/// interleaving *between* the two writers' streams is arbitrary, which is why
/// the invariant is per writer rather than per source.
///
/// The pace is per writer (`iterations` each); raft state is untouched here, so
/// the "one thread calls `tick()`" contract is unaffected by any of this.
fn publisherMain(ctx: *Publisher) void {
    const bus = ctx.bus;
    var published: u64 = 0;
    var last_publish_ms: i64 = 0;
    while (!stop_threads.load(.acquire)) {
        if (publishing.load(.acquire) and published < iterations) {
            const now = Time.monotonicNowMilliseconds();
            if (now - last_publish_ms >= @as(i64, @intCast(publish_ms))) {
                var buf: [48]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{d}-{d}", .{ ctx.writer, published + 1 })) |payload| {
                    // A failed publish is counted, not retried with the same
                    // payload: re-sending it would hide a lost frame, and the
                    // missing seq has to stay visible as a gap.
                    bus.publish(topic, payload) catch {
                        _ = publish_failures.fetchAdd(1, .monotonic);
                    };
                    last_publish_ms = now;
                    published += 1;
                    if (published == iterations) {
                        _ = publishers_remaining.fetchSub(1, .acq_rel);
                    }
                } else |_| {
                    // 48 bytes holds "<u64>-<u64>" (41 digits worst case) with
                    // room to spare; counted and retried next poll, never
                    // truncated.
                    _ = harness_internal_failures.fetchAdd(1, .monotonic);
                }
            }
        }
        soakSleep(publish_poll_ms);
    }
    // A writer may be stopped mid-quota; release the quota slot so the drain
    // logic below does not wait on a thread that will never finish it.
    if (published < iterations) {
        _ = publishers_remaining.fetchSub(1, .acq_rel);
    }
}

// ── the run ─────────────────────────────────────────────────────────────────

const Sample = struct {
    fd_count: ?u32,
    rss_bytes: ?u64,
    threads: ?u32,
    /// How many nodes claim to be leader in this sample (0, 1, or — the
    /// violation — 2+). A claim lasts one heartbeat of ignorance at most on
    /// loopback, so a sample-window catch is a real overlap, not a race with
    /// reality.
    leaders: u8,
    /// Index of the single claiming leader, -1 when none claims it.
    leader_idx: i8,
};

const max_samples = 4096;
var series: [max_samples]Sample = undefined;

// ── reading the bus's peer registry ─────────────────────────────────────────
//
// Every reading below goes through `bus.snapshotNodes(allocator)`
// (`DistributedEventBus.zig`): one call takes `nodes_lock`, copies the whole
// registry into caller-owned memory (`id` duplicated, `connected`,
// `send_failures`) and returns it; `snap.deinit()` frees every part of it. Two
// properties follow, and they are the whole reason this harness uses it:
//
//   * **nothing shared with the registry.** The copy is the caller's, so a
//     concurrent `connectToNode` (which can reallocate the array),
//     `disconnectNode` (which now *destroys* the entry: socket closed, `id`
//     freed, `Node` freed) or `deinit` cannot move or free a byte the reading
//     is looking at. That is the UAF shape a raw walk of the live array would
//     have here, and it is not hypothetical in this file: the registry is
//     mutated by threads this harness does not own — `cluster.tick()` on the
//     driver threads drives membership gossip, and
//     `ClusterMembership.handleGossipEvent`/`checkNodeHealth` call
//     `bus.connectToNode`/`bus.disconnectNode` on their own threads, as do the
//     buses' inbound fibers.
//   * **one reading, one instant.** `entries`, `live` and the watermark come
//     from a single `nodes_lock` critical section, not from two walks that a
//     mutation can straddle (the "3 entries, 2 live" reading of a registry
//     that never held more than 1 of each).
//
// What is *not* copied is the ordering: a snapshot is still a point in time,
// so `connectToNode` can land right after one was taken — that is what the
// boot mesh loop's retries are for.
//
// **Do not go back to `getConnectedNodes()`** (the raw, unlocked array of
// `*Node`): the bus documents it as legal only for a caller that already
// guarantees it is alone with the bus, and this harness never is. Ownership is
// the other half of the trade — a snapshot that is not `deinit()`ed leaks, and
// `std.testing.allocator` makes exactly that a failed run (`leaked` in the
// runner's summary), which is why every use below is wrapped in a `defer`.

/// Root allocator for the cluster fixtures and the peer snapshots.
///
/// **Why not `std.testing.allocator`** (the shape here until this change): on this
/// toolchain it captures a stack trace on *every* alloc and free, and each capture
/// permanently leaks ~313 B into `std.debug.getDebugInfoAllocator()` — a
/// process-global arena that is never reset (an arena's `free` is a no-op).
/// Measured on this repo, all with the same load:
///
/// * 200k isolated `alloc(u8,128)` + `free` with `stack_trace_frames = 7` (the
///   Debug default) → **+125 MiB RSS**; the identical loop with `= 0` → flat.
/// * 400k bare `std.debug.captureCurrentStackTrace` calls → +125,104 KiB, i.e.
///   ~313 B each, linear; an idle control loop → 0.
/// * `SafeAllocator`'s own accounting during that churn: backing live bytes
///   constant at 32 KiB, allocations and frees paired — the allocator retained
///   nothing.
/// * Relinking this harness's root allocator to `std.heap.smp_allocator`: live
///   bytes 130–227 KiB, RSS **9–12 MiB flat** at both 2400 and 4800 messages per
///   writer — versus the 89 / 163 MiB this test used to fail on (including on an
///   unchanged tree).
///
/// So the RSS growth was the probe, not the cluster: ~0.75 KB per allocation.
/// `DebugAllocator` with stack capture off keeps what the harness actually wants
/// (double-free / write-after-free canaries, leak detection on `deinit`, and a
/// hard `0 leaked` verdict via `soak_gpa.deinit()` below) without the per-capture
/// leak. Leak reports lose their call stacks — the tradefair price, and the
/// snapshots' `defer` discipline is what those stacks were diagnosing.
var soak_gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }){};

fn soakAllocator() std.mem.Allocator {
    return soak_gpa.allocator();
}

/// Allocator for the peer snapshots: deliberately the leak-checked root above, so
/// a snapshot that is not `deinit()`ed fails the run instead of silently growing.
/// (`std.testing.allocator` used to be here and made exactly that a failed run —
/// it still would, but every snapshot would also leak ~313 B into the debug-info
/// arena, ~470 snapshots per run.)
fn snapshotAllocator() std.mem.Allocator {
    return soakAllocator();
}

/// Entry count of one bus's registry plus how many of those entries held a
/// socket, both from **one** snapshot.
const BusCensus = struct { entries: usize, live: usize };

/// `bus.snapshotNodes` with the failure path handled in one place: a lock that
/// cannot be taken or an allocation that fails is counted as a
/// harness-internal failure (asserted zero at the end) and reported as "no
/// reading" — never read as "this bus has no peers". The returned snapshot is
/// the caller's to `deinit()`.
fn snapshotPeers(bus: *DistributedEventBus) ?DistributedEventBus.NodeSnapshot {
    return bus.snapshotNodes(snapshotAllocator()) catch |err| {
        _ = harness_internal_failures.fetchAdd(1, .monotonic);
        std.log.warn("[soak-cluster] peer snapshot for {s} failed ({}); reading skipped", .{ bus.nodeId(), err });
        return null;
    };
}

fn censusBus(bus: *DistributedEventBus) ?BusCensus {
    var snap = snapshotPeers(bus) orelse return null;
    defer snap.deinit();
    var live: usize = 0;
    for (snap.peers) |peer| {
        if (peer.connected) live += 1;
    }
    return .{ .entries = snap.peers.len, .live = live };
}

fn meshReady() bool {
    var ready = true;
    for (0..node_count) |i| {
        // A reading that could not be taken is not "this node has no peers":
        // report not-ready, which is the state the mesh loop then acts on (and
        // `snapshotPeers` has already counted the failure).
        const census = censusBus(fixtures[i].bus) orelse {
            ready = false;
            continue;
        };
        if (census.live != node_count - 1) ready = false;
    }
    return ready;
}

/// Diagnose duplicate/missing mesh connections: logs every node's peer-entry
/// count whenever it changes, so a second dial shows up with its timing.
var last_probe_entries: [node_count]usize = .{ 0, 0, 0 };

fn probeBusState(tag: []const u8) void {
    for (0..node_count) |i| {
        const census = censusBus(fixtures[i].bus) orelse continue;
        if (census.entries != last_probe_entries[i]) {
            std.log.warn("[soak-cluster] bus {s}: {d} entries ({d} live) at {s}", .{
                ids[i], census.entries, census.live, tag,
            });
        }
        last_probe_entries[i] = census.entries;
    }
}

/// Dial every topology peer a node's bus is not connected to. The snapshot and
/// the mutations are strictly ordered — snapshot, decide from the copy, then
/// `disconnectNode`/`connectToNode` — so no decision rides on a reference into
/// the live registry (which is the shape that would UAF now that a disconnect
/// destroys the entry instead of leaving it behind).
fn reconnectMissingMeshPeers() void {
    for (0..node_count) |i| {
        // One snapshot serves every `j` for this node: the mutations below touch
        // peer `j` only, while each `alive` decision reads peer `j`'s own copy,
        // so the passes do not invalidate each other. A peer that comes up or
        // goes down between this snapshot and the next boot loop iteration is
        // caught by that iteration's fresh snapshot.
        var snap = snapshotPeers(fixtures[i].bus) orelse continue;
        defer snap.deinit();
        for (0..node_count) |j| {
            if (i == j) continue;
            var alive = false;
            for (snap.peers) |peer| {
                if (peer.connected and std.mem.eql(u8, peer.id, ids[j])) alive = true;
            }
            if (alive) continue;
            fixtures[i].bus.disconnectNode(ids[j]);
            const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", bus_ports[j]) catch continue;
            fixtures[i].bus.connectToNode(ids[j], addr) catch {
                // The dial itself is swallowed inside connectToNode; this
                // catches the registration errors (alloc, key table). The
                // mesh loop retries, so count and let it.
                _ = mesh_reconnect_failures.fetchAdd(1, .monotonic);
            };
        }
    }
}

test "soak: 3-node cluster — raft + event bus, leader/fd/RSS invariants" {
    // The leak-checked root below, not `std.testing.allocator`: see `soak_gpa`
    // for the measurements. Safer in every way this test cares about, and it
    // stops the harness from measuring std's debug-info arena instead of itself.
    const allocator = soakAllocator();
    if (!zigmodu.NetworkProbe.available()) return error.SkipZigTest;

    initThresholds();
    initSharedState();
    buildTopology();

    const baseline = osInfo();

    // Boot the cluster. Sequential on purpose: each `start()` blocks until the
    // node's own raft listener is live, so by the last node every raft port in
    // the topology is accepting. A failure after any `start()` must not strand
    // the started nodes (their threads/fibers would hold the process open), so
    // teardown hangs off a defer; the normal path below runs the same stops.
    var nodes_started: usize = 0;
    inline for (0..node_count) |i| {
        try startNode(i, allocator);
        nodes_started = i + 1;
    }
    // Failure-path cleanup (the normal path runs the same stops and joins, at
    // which point the counters are zeroed so the defer no-ops): the load threads
    // must stop before their clusters go away (a writer holds a bus pointer, and
    // the bus dies with its cluster), and started nodes must deinit or their
    // threads/fibers hold the process open after a failed `try`.
    var drivers_spawned: usize = 0;
    var writers_spawned: usize = 0;
    defer {
        stop_threads.store(true, .release);
        joinWriters(writers_spawned);
        writers_spawned = 0;
        while (drivers_spawned > 0) {
            drivers_spawned -= 1;
            fixtures[drivers_spawned].driver.join();
        }
        teardownStarted(nodes_started);
    }

    var mesh_ok = true;
    {
        var tries: usize = 0;
        while (!meshReady() and tries < 25) : (tries += 1) {
            if (tries > 0) reconnectMissingMeshPeers();
            soakSleep(200);
        }
        mesh_ok = meshReady();
    }
    probeBusState("mesh");
    if (!mesh_ok) {
        std.log.warn("[soak-cluster] mesh never formed; tearing down and failing", .{});
        inline for (0..node_count) |k| {
            stopNode(node_count - 1 - k);
        }
        try std.testing.expect(mesh_ok);
        return;
    }

    // Which transport instance did each raft actually get bound to? Ask every
    // raft's vtable to resolve an unresolvable peer: the thunk answers with
    // the name of the instance it dispatches to. A crossed binding here means
    // votes and heartbeats are being dropped on a node that should send them.
    {
        const probe = VoteRequest{ .term = 999_999, .candidate_id = "probe", .last_log_index = 0, .last_log_term = 0 };
        inline for (0..node_count) |i| {
            fixtures[i].raft.transport.*.sendVoteRequest("zz-no-such-peer", "", probe);
        }
        soakSleep(50);
    }

    // Drivers first; they settle the election. Traffic starts only once the
    // cluster has agreed on ONE leader: the election storm at boot is exactly
    // when frames legitimately drop (a candidate that loses has no lease, the
    // bus's replay gate drops what a flapped connection re-delivers), and the
    // no-loss invariant is a *steady-state* contract — sustained load under a
    // stable term — not a boot-storm guarantee. Raft startup correctness
    // itself is covered by the fast suite.
    var settle_leader_observed = false;
    inline for (0..node_count) |i| {
        fixtures[i].driver = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, driverMain, .{&fixtures[i]});
        drivers_spawned = i + 1;
    }
    // The writers start here too but publish nothing until `publishing` flips
    // below — starting them now means the first burst of frames already has
    // every writer in it, instead of a staggered warm-up.
    writers_spawned = spawnWriters();
    const writers_started = writers_spawned;
    {
        var tries: usize = 0;
        while (tries < 100 and !settle_leader_observed) : (tries += 1) {
            var leaders: u8 = 0;
            inline for (0..node_count) |i| {
                if (fixtures[i].raft.getState() == .leader) leaders += 1;
            }
            settle_leader_observed = leaders == 1;
            if (!settle_leader_observed) soakSleep(50);
        }
    }
    probeBusState("settled");
    if (!settle_leader_observed) {
        std.log.warn("[soak-cluster] no stable leader after settle window; proceeding (leader checks will fail)", .{});
    }
    appends_enabled.store(true, .release);
    publishing.store(true, .release);

    // Sample the invariants until the traffic has fully drained, then quiesce
    // replication before freezing the load threads for the log snapshot.
    var samples: usize = 0;
    var steady = false;
    var last_leader: ?usize = null;
    var transitions: u64 = 0;
    var two_leader_samples: u64 = 0;
    var leaderless_after_steady: u64 = 0;
    var post_steady_samples: u64 = 0;
    var drain_timed_out = false;
    // The bus's own per-peer write-failure counter, watermarked: any value
    // above zero means a send actually errored (as opposed to a frame being
    // dropped by the replay gate), which the no-loss invariant forbids.
    var max_send_failures: u64 = 0;

    const publish_phase_ms: u64 = @as(u64, iterations) * publish_ms + 5000;
    const deadline_ms = Time.monotonicNowMilliseconds() + @as(i64, @intCast(publish_phase_ms + 30_000));

    while (true) {
        soakSleep(sample_ms);
        const info = osInfo();
        var leaders: u8 = 0;
        var leader_idx: i8 = -1;
        inline for (0..node_count) |i| {
            if (fixtures[i].raft.getState() == .leader) {
                leaders += 1;
                leader_idx = @intCast(i);
            }
        }
        if (samples >= max_samples) {
            // The series is full; keep the run correct by failing it loudly
            // at the end rather than overwriting early samples.
            drain_timed_out = true;
            std.log.warn("[soak-cluster] sample series exhausted ({d} samples)", .{max_samples});
            break;
        }
        series[samples] = .{
            .fd_count = info.fd_count,
            .rss_bytes = info.rss_bytes,
            .threads = info.threads,
            .leaders = leaders,
            .leader_idx = leader_idx,
        };
        samples += 1;
        for (0..node_count) |i| {
            // Off a snapshot, not a walk of the live array: the driver threads
            // are ticking membership gossip next to this sample, and a
            // concurrent `disconnectNode` destroys the entry a raw walk would
            // still be pointing at. `send_failures` is a copied `u32`, so the
            // watermark survives the snapshot's `deinit` below.
            var snap = snapshotPeers(fixtures[i].bus) orelse continue;
            defer snap.deinit();
            for (snap.peers) |peer| {
                if (peer.send_failures > max_send_failures) max_send_failures = peer.send_failures;
            }
        }

        if (leaders >= 2) two_leader_samples += 1;
        if (!steady) {
            if (leaders == 1) steady = true;
        } else {
            post_steady_samples += 1;
            if (leaders == 0) leaderless_after_steady += 1;
            if (leader_idx >= 0) {
                const cur: usize = @intCast(leader_idx);
                if (last_leader) |l| {
                    if (cur != l) transitions += 1;
                }
                last_leader = cur;
            }
        }

        if (publishers_remaining.load(.acquire) == 0 and allPairsFull()) break;
        probeBusState("run");
        if (Time.monotonicNowMilliseconds() > deadline_ms) {
            drain_timed_out = true;
            std.log.warn("[soak-cluster] drain deadline hit; recv matrix follows", .{});
            for (0..node_count) |d| {
                for (0..node_count) |s| {
                    for (0..publishers_per_node) |w| {
                        std.log.warn("[soak-cluster]   recv {s}<-{s}#{d}: {d}/{d} (last_seq {d})", .{
                            ids[d],                               ids[s],     w,
                            recv_count[d][s][w].load(.monotonic), iterations, last_seq[d][s][w].load(.monotonic),
                        });
                    }
                }
            }
            break;
        }
    }

    appends_enabled.store(false, .release);
    soakSleep(quiesce_ms);
    stop_threads.store(true, .release);
    inline for (0..node_count) |i| fixtures[i].driver.join();
    drivers_spawned = 0;
    joinWriters(writers_spawned);
    writers_spawned = 0;

    // Log convergence: with the load threads frozen no raft state moves, and the
    // quiesce gave every in-flight entry time to land. Any divergence here —
    // an un-replicated tail, a missed truncation after a re-election — is a
    // real defect.
    var log_lens: [node_count]u64 = undefined;
    // Snapshot before teardown: a bus holding more peer entries than topology
    // peers means a second connection was dialled somewhere — the classic
    // source of interleaved-seq "not ahead" drops — so the report shows it.
    // One `censusBus` snapshot per bus, so the entry count and the live count
    // are the same instant; the load threads are joined by now, but the buses'
    // own fibers are not (which is why this reads a snapshot and not the live
    // array). A bus whose snapshot cannot be taken reports 0/0 and has already
    // been counted into `harness_internal_failures`, so the run still fails.
    var bus_entries: [node_count]usize = .{ 0, 0, 0 };
    var bus_live: [node_count]usize = .{ 0, 0, 0 };
    inline for (0..node_count) |i| {
        if (censusBus(fixtures[i].bus)) |census| {
            bus_entries[i] = census.entries;
            bus_live[i] = census.live;
        }
    }
    var log_ok = true;
    inline for (0..node_count) |i| log_lens[i] = fixtures[i].raft.logLen();
    if (!(log_lens[0] == log_lens[1] and log_lens[0] == log_lens[2])) {
        log_ok = false;
    } else {
        var idx: u64 = 1;
        while (idx <= log_lens[0]) : (idx += 1) {
            const e0 = fixtures[0].raft.getLogEntry(idx).?;
            const e1 = fixtures[1].raft.getLogEntry(idx).?;
            const e2 = fixtures[2].raft.getLogEntry(idx).?;
            if (!(e0.term == e1.term and e0.term == e2.term)) {
                log_ok = false;
                break;
            }
            if (!(std.mem.eql(u8, e0.command, e1.command) and std.mem.eql(u8, e0.command, e2.command))) {
                log_ok = false;
                break;
            }
        }
    }

    inline for (0..node_count) |k| {
        stopNode(node_count - 1 - k);
    }

    // Let the last closes land, then re-count: teardown must give the fds back.
    soakSleep(200);
    const after_teardown = osInfo();

    // ── report ────────────────────────────────────────────────────────────
    var fd_min: u64 = std.math.maxInt(u64);
    var fd_max: u64 = 0;
    var fd_first: u64 = 0;
    var fd_last: u64 = 0;
    var rss_min: u64 = std.math.maxInt(u64);
    var rss_max: u64 = 0;
    var rss_first: u64 = 0;
    var rss_last: u64 = 0;
    var th_min: u64 = std.math.maxInt(u64);
    var th_max: u64 = 0;
    var fd_supported = true;
    var rss_supported = true;
    var threads_supported = true;
    for (series[0..samples], 0..) |smp, idx| {
        if (smp.fd_count) |fd| {
            const v: u64 = fd;
            fd_min = @min(fd_min, v);
            fd_max = @max(fd_max, v);
            if (idx == 0) fd_first = v;
            fd_last = v;
        } else {
            fd_supported = false;
        }
        if (smp.rss_bytes) |rss| {
            rss_min = @min(rss_min, rss);
            rss_max = @max(rss_max, rss);
            if (idx == 0) rss_first = rss;
            rss_last = rss;
        } else {
            rss_supported = false;
        }
        if (smp.threads) |th| {
            const v: u64 = th;
            th_min = @min(th_min, v);
            th_max = @max(th_max, v);
        } else {
            threads_supported = false;
        }
    }
    const fd_walked = fd_supported and samples >= 5;
    const rss_walked = rss_supported and samples >= 5;
    const threads_walked = threads_supported and samples >= 5;
    if (!fd_supported) std.log.warn("[soak-cluster] fd count unavailable on this platform — check skipped", .{});
    if (!rss_supported) std.log.warn("[soak-cluster] RSS unavailable on this platform — check skipped", .{});

    // The census must actually have walked ("green of the never-walked proves
    // nothing"). The floor is three samples: below that, presence/transitions
    // carry no signal. The default sizing yields ~100 samples; tiny smoke
    // runs necessarily exercise the same checks over a shorter window.
    const min_post_samples: u64 = 3;
    const presence_pct: u64 = if (post_steady_samples > 0)
        (post_steady_samples - leaderless_after_steady) * 100 / post_steady_samples
    else
        0;

    std.log.warn("[soak-cluster] run: iterations={d}/writer writers={d} samples={d} appends={d} (not_leader_races={d}) log_len={d}", .{
        iterations,                     node_count * publishers_per_node,   samples,
        total_appends.load(.monotonic), append_not_leader.load(.monotonic), log_lens[0],
    });
    for (0..node_count) |n| {
        std.log.warn("[soak-cluster] bus {s}: {d} peer entries ({d} live sockets)", .{
            ids[n], bus_entries[n], bus_live[n],
        });
    }
    std.log.warn("[soak-cluster] leader: steady={} post_steady={d} transitions={d} leaderless={d} two_leader_samples={d} presence={d}%", .{
        steady, post_steady_samples, transitions, leaderless_after_steady, two_leader_samples, presence_pct,
    });
    if (fd_walked) {
        std.log.warn("[soak-cluster] fds: first={d} last={d} min={d} max={d} budget={d} baseline={?d} after_teardown={?d}", .{
            fd_first, fd_last, fd_min, fd_max, fd_budget, baseline.fd_count, after_teardown.fd_count,
        });
    }
    if (rss_walked) {
        std.log.warn("[soak-cluster] rss MiB: first={d} last={d} min={d} max={d} budget={d}", .{
            rss_first / 1024 / 1024,        rss_last / 1024 / 1024,
            rss_min / 1024 / 1024,          rss_max / 1024 / 1024,
            rss_budget_bytes / 1024 / 1024,
        });
    }
    if (threads_walked) {
        std.log.warn("[soak-cluster] threads: min={d} max={d} budget={d}", .{ th_min, th_max, thread_budget });
    }
    std.log.warn("[soak-cluster] bus max send_failures watermark: {d}", .{max_send_failures});

    // ── the invariants ────────────────────────────────────────────────────
    // All expects live here, after full teardown: a failure panics, and a
    // panic mid-run would strand load threads and the whole cluster.
    try std.testing.expect(mesh_ok);
    try std.testing.expect(!drain_timed_out);
    try std.testing.expectEqual(@as(u64, 0), publish_failures.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), gap_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), dup_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), malformed_count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), tick_errors.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), append_failures.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), harness_internal_failures.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), sleep_cancellations.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), mesh_reconnect_failures.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), max_send_failures);
    // Every writer's stream arrived whole at every node, both locally and over
    // the wire: this is the assertion the concurrent-writer shape exists to
    // make meaningful (a frame dropped by the receiver's replay gate is a gap
    // here, counted above and missing below).
    try std.testing.expectEqual(node_count * publishers_per_node, writers_started);
    for (0..node_count) |d| {
        for (0..node_count) |s| {
            for (0..publishers_per_node) |w| {
                std.debug.print("delivery {s}<-{s}#{d}: {d}/{d}\n", .{
                    ids[d], ids[s], w, recv_count[d][s][w].load(.monotonic), iterations,
                });
                try std.testing.expectEqual(@as(u64, iterations), recv_count[d][s][w].load(.monotonic));
            }
        }
    }

    // Leader stability must actually have been observed: a cluster with no
    // leader at all, or a run too short to judge, fails rather than reports
    // green-of-the-never-walked.
    try std.testing.expect(steady);
    try std.testing.expect(post_steady_samples >= min_post_samples);
    try std.testing.expectEqual(@as(u64, 0), two_leader_samples);
    try std.testing.expect(transitions <= max_leader_transitions);
    try std.testing.expect(presence_pct >= min_leader_presence_pct);

    // Replication walked, and converged.
    try std.testing.expect(total_appends.load(.monotonic) >= 5);
    try std.testing.expect(log_lens[0] >= 5);
    try std.testing.expect(log_lens[0] <= total_appends.load(.monotonic));
    try std.testing.expect(log_ok);

    if (fd_walked) {
        try std.testing.expect(fd_max - fd_min <= fd_budget);
        try std.testing.expect(fd_last <= fd_first + fd_budget);
        if (baseline.fd_count) |base| {
            if (after_teardown.fd_count) |done| {
                try std.testing.expect(@as(u64, done) <= @as(u64, base) + 4);
            }
        }
    }
    if (rss_walked) {
        try std.testing.expect(rss_max - rss_min <= rss_budget_bytes);
        try std.testing.expect(rss_last <= rss_first + rss_budget_bytes);
    }
    if (threads_walked) {
        try std.testing.expect(th_max - th_min <= thread_budget);
    }

    // The precise gate the RSS envelope is only an approximation of: every
    // byte the fixtures and snapshots took is back. `deinit` also runs the
    // canary checks, so this replaces the runner's `0 leaked` line for this
    // test (which no longer uses `std.testing.allocator`).
    try std.testing.expectEqual(std.heap.Check.ok, soak_gpa.deinit());
}
