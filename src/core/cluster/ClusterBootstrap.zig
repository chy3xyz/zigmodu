//! One-shot cluster bootstrap — **the facade** for the distributed stack.
//!
//! Wires together PeerDiscovery → DistributedEventBus → ClusterMembership →
//! RaftElection and hands out the entry points an app needs, so nobody has to
//! assemble the parts (and forget to drive one of them) themselves:
//!
//!   `start()` / `stop()`   — bring the stack (and, with a `.transport`, its
//!                            inbound Raft listener) up and down
//!   `tick()`               — one step of *everything*: gossip/health, then the
//!                            read side, then `raft.tick()`
//!   `pick(key)`            — rendezvous routing over the healthy members
//!   `getView()`            — the refcounted read side, for what `pick` does not cover
//!   `healthJson(allocator)`— the cluster health report
//!   `get{EventBus,Membership,Raft,Metrics}()` — the raw handles
//!
//! Usage:
//!   var cluster = try ClusterBootstrap.init(allocator, io, .{
//!       .node_id = "node-1",
//!       .port = 9000,
//!       .peers = &.{"node-2@127.0.0.1:9001", "node-3@127.0.0.1:9002"},
//!   });
//!   defer cluster.deinit();
//!   try cluster.start();
//!   try cluster.tick();                                // your loop / a runtime timer
//!   const owner = cluster.pick("order-1") orelse return error.NoHealthyNode;

const std = @import("std");
const PeerDiscovery = @import("PeerDiscovery.zig").PeerDiscovery;
const NetworkTransport = @import("NetworkTransport.zig");
const RaftTransport = @import("RaftTransport.zig");
const ClusterMembership = @import("../ClusterMembership.zig").ClusterMembership;
const DistributedEventBus = @import("../DistributedEventBus.zig").DistributedEventBus;
const RaftElection = @import("RaftElection.zig").RaftElection;
const RaftState = @import("RaftElection.zig").RaftState;
const ElectionConfig = @import("RaftElection.zig").ElectionConfig;
const VoteRequest = @import("RaftElection.zig").VoteRequest;
const AppendEntriesRequest = @import("RaftElection.zig").AppendEntriesRequest;
const AppendEntriesResponse = @import("RaftElection.zig").AppendEntriesResponse;
const ClusterMetrics = @import("ClusterMetrics.zig").ClusterMetrics;
const ClusterHealth = @import("ClusterHealth.zig");
const MembershipView = @import("../../cluster/MembershipView.zig").MembershipView;
const Member = @import("../../cluster/ClusterView.zig").Member;

/// Read-side view handed out by `getView()`. 16 members / 2 generations is the
/// documented 3–7 node sweet spot with headroom; bump it for bigger clusters.
pub const view_members = 16;
pub const view_generations = 2;
pub const View = MembershipView(view_members, view_generations);

pub const BootstrapConfig = struct {
    node_id: []const u8,
    /// The node's cluster port: the membership advertises it, and with a
    /// `.transport` the inbound Raft listener binds it (`start()`). Do not also
    /// hand it to `DistributedEventBus.start(port)`.
    port: u16 = 9000,
    /// Static peers, each `"<id>@<host>:<port>"` with the `@<id>` part
    /// **optional** at the parser level (`PeerDiscovery`):
    ///   `"node-b@127.0.0.1:9001"` → raft peer `node-b`, address `127.0.0.1:9001`
    ///   `"127.0.0.1:9001"`        → raft peer `127.0.0.1` (id falls back to host)
    ///
    /// A **multi-node** cluster (`raft_cluster_size > 1`) requires the id: Raft
    /// credits a ballot against `raft.peers[].id` while a node answers a vote with
    /// its own `node_id`, so a peer identified by its host can never be credited —
    /// the vote is dropped and the cluster never elects a leader. `start()` refuses
    /// that shape with `error.PeerIdRequired` rather than running dead.
    peers: []const []const u8 = &.{},
    raft_cluster_size: usize = 3,
    /// Bring your own Raft transport. The built-in one is a stub, so a multi-node
    /// cluster is **refused** unless this is set or the caller acknowledges with
    /// `allow_stub_raft_transport`. What a real transport must do is written out in
    /// `docs/DISTRIBUTED.md`「真选主要什么」（出站发送 + 入站分发到
    /// `RaftElection.handleVoteRequest` / `handleVoteResponse` / `handleAppendEntries`
    /// 并在同一连接上回包）—— 出站由这个 vtable 提供，**入站由 `start()` 自己监听
    /// `port` 并分发**（`RaftTransport.handleConnection`），所以自带的传输只需要管发。
    transport: ?RaftElection.ElectionTransport = null,
    /// Leader election needs votes to actually travel, and the built-in Raft
    /// transport is a **stub** (see `start()`). So a cluster with
    /// `raft_cluster_size > 1` refuses to start unless this is set — which is the
    /// acknowledgement "this process runs membership + the read side only;
    /// elections happen elsewhere, or not at all". `raft_cluster_size <= 1`
    /// (single node) needs no acknowledgement.
    allow_stub_raft_transport: bool = false,
    /// 32-byte pre-shared key authenticating the cluster port. Source it from
    /// `security.SecretsManager` (env > file > vault); the framework deliberately
    /// does not read it for you. Required for a multi-node cluster with a real
    /// `.transport` — see the gate in `start()`.
    cluster_secret: ?[32]u8 = null,
    /// Loud acknowledgement that a multi-node cluster runs **unauthenticated**.
    /// Same idiom as `allow_stub_raft_transport`: refuse unless set.
    allow_unauthenticated_cluster: bool = false,
};

pub const ClusterBootstrap = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    config: BootstrapConfig,

    bus: ?*DistributedEventBus = null,
    membership: ?*ClusterMembership = null,
    raft: ?*RaftElection = null,
    /// The vtable handed to `RaftElection` (the app's `.transport`, or the stub).
    /// It lives here because the raft keeps a **pointer** to it — see `start()`.
    election_transport: RaftElection.ElectionTransport = undefined,
    metrics: ClusterMetrics,
    /// Accepts inbound Raft RPCs on `config.port` — only when a `.transport` was
    /// supplied (see `start()`); the accept loop runs on `inbound_thread`.
    server: NetworkTransport.ClusterServer,
    inbound_thread: ?std.Thread = null,
    /// peer id → `host:port`, filled from `config.peers` in `start()`: the inbound
    /// dispatch resolves a granted vote's candidate through it.
    addresses: RaftTransport.AddressBook,
    /// Read side fed by `tick()`. Request paths use it instead of the
    /// membership hash map (`acquire`/`pick`, see `cluster/MembershipView.zig`).
    view: View,

    /// `ClusterServer.start` takes a bare handler (no context), so the server's
    /// owner is bound per thread — the same trick `RaftTransport.InboundServer`
    /// uses, without a second listener object.
    threadlocal var inbound_owner: ?*Self = null;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: BootstrapConfig) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .metrics = ClusterMetrics.init(allocator),
            .server = NetworkTransport.ClusterServer.init(allocator, io, config.port),
            .addresses = RaftTransport.AddressBook.init(allocator),
            .view = View.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.view.deinit();
        self.addresses.deinit();
        self.* = undefined;
    }

    /// Start all cluster services.
    pub fn start(self: *Self) !void {
        // 1. Discover peers
        var disco = PeerDiscovery.init(self.allocator, .{
            .static_peers = self.config.peers,
            .local_port = self.config.port,
        });
        // Order matters: `deinit()` poisons the struct (`self.* = undefined`), and
        // `deinitResolved` reads `self.allocator` — so it must run *before* it.
        // Deferred first = runs last (LIFO).
        defer disco.deinit();
        const peers = try disco.resolve();
        defer disco.deinitResolved(peers);
        self.metrics.setNodeCount(1 + peers.len);

        // 2. Create event bus (node communication backbone)
        const bus = try self.allocator.create(DistributedEventBus);
        bus.* = try DistributedEventBus.init(self.allocator, self.io, self.config.node_id);
        self.bus = bus;

        // 3. Create cluster membership (gossip + health)
        const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.config.port);
        const member = try self.allocator.create(ClusterMembership);
        member.* = try ClusterMembership.init(self.allocator, self.io, self.config.node_id, addr, bus);
        self.membership = member;
        try member.start(.{});

        // 4. Create RaftElection (leader election)
        //
        // `config.transport` may be supplied by the app (a real network transport).
        // Without one we fall back to a **stub**: `sendVoteRequest` is a no-op and
        // `sendAppendEntries` always fails, so a multi-node election cannot make
        // progress. Refuse loudly rather than elect a "leader" no peer ever voted
        // for — a single-node cluster has nothing to elect, and a process that only
        // wants membership + the read side acknowledges with
        // `.allow_stub_raft_transport = true`.
        if (self.config.transport == null and self.config.raft_cluster_size > 1 and !self.config.allow_stub_raft_transport) {
            // `warn`, not `err`: the returned error is the loud part, and the test
            // harness treats an `err`-level log as a failure by itself.
            std.log.warn(
                "[ClusterBootstrap] refusing to start node {s}: raft_cluster_size={d} but no Raft transport was supplied " ++
                    "and the built-in one is a stub (votes go nowhere). Pass `.transport`, or acknowledge with " ++
                    "`.allow_stub_raft_transport = true` to run membership + read side only.",
                .{ self.config.node_id, self.config.raft_cluster_size },
            );
            return error.RaftTransportUnavailable;
        }
        // The other half of the same honesty, one level up: a multi-node cluster
        // with a real transport but no pre-shared key runs the cluster port
        // **unauthenticated** — TCP-reachable means cluster member
        // (`docs/dev/cluster-auth-design.md` §1: anyone who can connect can win a
        // vote, forge a leader, or clear the log). Refuse unless the app either
        // supplies a key or says so out loud. `raft_cluster_size <= 1` needs no
        // key: there is no peer to talk to.
        if (self.config.transport != null and self.config.raft_cluster_size > 1 and
            self.config.cluster_secret == null and !self.config.allow_unauthenticated_cluster)
        {
            // `warn`, not `err`: the returned error is the loud part, and the test
            // harness treats an `err`-level log as a failure by itself.
            std.log.warn(
                "[ClusterBootstrap] refusing to start node {s}: raft_cluster_size={d} with a real transport but no " ++
                    "`cluster_secret`, so every frame on the cluster port would be unauthenticated. Set it from " ++
                    "SecretsManager, or acknowledge with `.allow_unauthenticated_cluster = true`.",
                .{ self.config.node_id, self.config.raft_cluster_size },
            );
            return error.ClusterAuthRequired;
        }
        // The third thing a multi-node cluster cannot infer: **who its peers are**.
        // Raft counts a granted ballot against `self.peers[].id` (`peerId` in
        // `RaftElection.zig`), while a node answers a vote with its own `node_id`
        // (`RaftTransport.zig`: `encodeVoteResponse(..., raft.local_id)`). A peer
        // added under its host string therefore never matches: `peerId` returns
        // null, the vote is dropped, `quorumSize()` is never reached and the
        // cluster runs forever without a leader — the address book keyed by host
        // drops the relayed vote response for the same reason
        // (`docs/dev/cluster-auth-design.md` §10). Such a cluster is **already** a
        // dead one, so refusing it is not a regression: it turns a silent
        // no-leader-ever into a startup error. `PeerDiscovery.resolve` reports
        // "no `@id` was given" as `id == host`; a single node
        // (`raft_cluster_size <= 1`) has no ballot to reject.
        if (self.config.raft_cluster_size > 1) {
            for (peers) |p| {
                if (!std.mem.eql(u8, p.id, p.host)) continue;
                // `warn`, not `err`: the returned error is the loud part, and the test
                // harness treats an `err`-level log as a failure by itself.
                std.log.warn(
                    "[ClusterBootstrap] refusing to start node {s}: peer {s}:{d} declares no id (`id` fell back to its host " ++
                        "string), and Raft credits a vote only against `raft.peers[].id` — the peer's ballots would be dropped " ++
                        "and this cluster would never elect a leader. Write that peer as `\"<node_id>@{s}:{d}\"` in `.peers`.",
                    .{ self.config.node_id, p.host, p.port, p.host, p.port },
                );
                return error.PeerIdRequired;
            }
        }
        const election_cfg = ElectionConfig{ .cluster_secret = self.config.cluster_secret };
        const S = struct {
            var transport_impl: ?struct {
                sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
                sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
            } = null;
        };
        if (S.transport_impl == null) {
            S.transport_impl = .{
                .sendVoteRequest = struct {
                    fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
                }.f,
                .sendAppendEntries = struct {
                    fn f(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
                        return AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
                    }
                }.f,
            };
        }
        const stub_transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&S.transport_impl.?)));
        // Stored in a field, not a local: `RaftElection` keeps a pointer to it, and
        // a `start()` local dies with the stack frame — the first election would
        // then jump through a dead function pointer.
        self.election_transport = self.config.transport orelse stub_transport;
        const raft = try self.allocator.create(RaftElection);
        raft.* = try RaftElection.init(self.allocator, self.config.node_id, &.{}, election_cfg, &self.election_transport);
        self.raft = raft;

        // Add peers to Raft **by id** — that is the name their ballots are counted
        // under (a peer answers a vote with its `node_id`, so `addPeer(p.host)`
        // here would drop every vote it sends; see the id gate above). The address
        // book stays keyed by the same id but carries the `host:port` it is
        // reachable at, which is what the inbound relay needs to turn a vote
        // response's candidate back into a dialable endpoint — identity and
        // address are deliberately two facts.
        for (peers) |p| {
            try raft.addPeer(p.id);
            try self.addresses.add(p.id, p.host, p.port);
        }

        // 5. Inbound Raft RPCs: with a real transport the peers' votes and
        //    AppendEntries arrive here, and `RaftTransport.handleConnection`
        //    dispatches them into this node's raft (and answers on the same
        //    connection). Without one there is nothing to answer — the outbound
        //    half is a stub — so the behaviour is exactly as before.
        if (self.config.transport != null) {
            self.inbound_thread = try std.Thread.spawn(.{}, runInbound, .{self});
            // `ClusterServer.start` flips `running` right after a successful
            // listen; a taken port has to fail the boot rather than leave the
            // cluster's votes unanswered while the node pretends to be up.
            var spins: usize = 0;
            while (!self.server.running.load(.monotonic) and spins < 2000) : (spins += 1) {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(1), .awake) catch |err| {
                    std.log.debug("[ClusterBootstrap] inbound listen wait ({})", .{err});
                };
            }
            if (!self.server.running.load(.monotonic)) {
                self.inbound_thread.?.join();
                self.inbound_thread = null;
                std.log.warn("[ClusterBootstrap] node {s}: cannot listen for Raft RPCs on port {d}", .{
                    self.config.node_id, self.config.port,
                });
                return error.RaftInboundListenFailed;
            }
            std.log.info("[ClusterBootstrap] node {s}: inbound Raft RPCs on port {d}", .{
                self.config.node_id, self.config.port,
            });
        }

        // 6. Leader change callback: member.onLeaderChange(callback) already available

        std.log.info("[ClusterBootstrap] Node {s} started on port {d} with {d} peers", .{
            self.config.node_id, self.config.port, peers.len,
        });
    }

    /// Tear the stack down. Idempotent: terminal cleanup hangs off `deinit()`, and
    /// an explicit `stop()` before it must not reach into torn-down memory.
    pub fn stop(self: *Self) void {
        // First: the accept loop holds `self.raft` and `&self.addresses`, so it
        // has to be gone before either is destroyed.
        if (self.inbound_thread) |thread| {
            self.inbound_thread = null;
            const was_running = self.server.running.load(.monotonic);
            self.server.stop();
            // The loop is blocked in `accept`, which a closed listener does not
            // reliably wake — a connection nobody serves is what does (the same
            // trick `RaftTransport.InboundServer` uses).
            if (was_running) wakeAccept(self.io, self.config.port);
            thread.join();
        }
        if (self.membership) |m| {
            m.deinit();
            self.allocator.destroy(m);
            self.membership = null;
        }
        if (self.bus) |b| {
            b.deinit();
            self.allocator.destroy(b);
            self.bus = null;
        }
        if (self.raft) |r| {
            r.deinit();
            self.allocator.destroy(r);
            self.raft = null;
        }
        // `stop()`, not `deinit()`: `deinit` poisons the struct, and a second
        // `stop()` would then read undefined memory (and close a garbage fd).
        self.server.stop();
    }

    /// Accept loop for inbound Raft RPCs. One RPC per connection, matching the
    /// outbound side, which dials per call. Blocks until `stop()`.
    ///
    /// The dispatch runs on this thread while the app's own `tick()` drives the
    /// same `RaftElection`; the serialization is the raft's own lock
    /// (`RaftElection.RaftLock`), not anything the facade arranges — see
    /// `RaftTransport.handleConnection`.
    fn runInbound(self: *Self) void {
        inbound_owner = self;
        defer inbound_owner = null;
        self.server.start(&onInboundConnection) catch |err| {
            std.log.debug("[ClusterBootstrap] inbound Raft server on port {d} exited ({})", .{ self.config.port, err });
        };
    }

    fn onInboundConnection(conn: NetworkTransport.ClusterConnection) void {
        var owned = conn;
        defer owned.deinit();
        const self = inbound_owner orelse {
            std.log.debug("[ClusterBootstrap] inbound connection on an unbound server thread", .{});
            return;
        };
        const raft = self.raft orelse return;
        RaftTransport.handleConnection(raft, &self.addresses, &owned);
    }

    /// The config this node was booted with — read-only entry point for the
    /// facades that report on it (e.g. `ClusterHealth.healthJson`).
    pub fn getConfig(self: *const Self) *const BootstrapConfig {
        return &self.config;
    }

    pub fn getMetrics(self: *Self) *ClusterMetrics {
        return &self.metrics;
    }
    pub fn getEventBus(self: *Self) ?*DistributedEventBus {
        return self.bus;
    }
    pub fn getMembership(self: *Self) ?*ClusterMembership {
        return self.membership;
    }
    /// The raw `RaftElection` — **an unsynchronized pointer, and it stays one**.
    ///
    /// A `*RaftElection` cannot be made safe by giving this accessor a lock:
    /// whatever the caller does *after* it returns is what raises the data race,
    /// so a lock here would suggest a guarantee it does not give. The contract
    /// is therefore explicit:
    ///
    ///   * one **driver thread per raft**. `tick()` and the `handle*` RPCs each
    ///     serialize themselves (`RaftElection.lock`), but a *caller* that drives
    ///     this raft from a thread other than the one `ClusterBootstrap.tick()`
    ///     runs on is responsible for that — either drive it from the same thread
    ///     (the wiring this facade assumes), or hold `raft.lock` around the whole
    ///     sequence you need to be atomic.
    ///   * **reads are the same rule.** The accessors take the raft's lock, so a
    ///     read cannot come back torn; a *sequence* of reads (or reading a
    ///     returned borrow like `getLogEntry().command` / `getLeader()` after
    ///     another call) is not covered.
    ///   * the raft is owned by this bootstrap: `stop()` destroys it, so nothing
    ///     may use the pointer afterwards, and `deinit()` is not synchronized.
    ///
    /// In short: use `tick()`/`pick()`/`getView()`/`healthJson()` from a request
    /// path, and treat this pointer as reachable only from the thread that drives
    /// the cluster.
    pub fn getRaft(self: *Self) ?*RaftElection {
        return self.raft;
    }

    /// The read side: refcounted membership snapshots + rendezvous routing.
    /// Request paths use `getView().acquire()/.release()` (or `.pick(key)`);
    /// they must not read the membership map.
    pub fn getView(self: *Self) *View {
        return &self.view;
    }

    /// Read-side routing for a request path: rendezvous over the *healthy*
    /// members (forwarded from the view). The same key keeps landing on the same
    /// member until membership changes — and a member that is merely suspect is
    /// not a candidate.
    pub fn pick(self: *Self, key: []const u8) ?Member {
        return self.view.pick(key);
    }

    /// The cluster health report as JSON (`ClusterHealth.healthJson`). The caller
    /// owns the returned string — serve it from a `/cluster/health` route or a
    /// metrics scrape hook.
    pub fn healthJson(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        return ClusterHealth.healthJson(allocator, self);
    }

    /// Advance the cluster one step: one gossip/health pass, then refresh the
    /// read side, then one Raft step. **Nothing calls this for you** — both the
    /// membership loop (`ClusterMembership.runOnce`) and the Raft loop
    /// (`RaftElection.tick`) are externally driven by design, so drive it from
    /// your own loop or a runtime timer:
    ///
    /// ```zig
    /// _ = try worker.after(1000, .tick);   // runtime timer → Worker.handle → cluster.tick()
    /// ```
    ///
    /// `error.ReadersBusy` is not a failure: a request path was mid-read, so the
    /// view keeps its previous generation and the next tick publishes again.
    ///
    /// The Raft step is what starts elections and sends heartbeats; without a
    /// `.transport` the built-in one is a stub, so it changes local state only.
    ///
    /// No lock is taken here: with a `.transport`, `start()` has an accept thread
    /// dispatching peers' RPCs into the same `RaftElection`, and both sides are
    /// serialized by the raft's own lock (`raft.tick()` takes it for its body,
    /// as does every `handle*` the inbound dispatch calls — see
    /// `RaftElection.RaftLock` and `RaftTransport.handleConnection`).
    pub fn tick(self: *Self) !void {
        const member = self.membership orelse return;
        try member.runOnce();
        self.view.sync(member) catch |err| switch (err) {
            error.ReadersBusy => {},
            else => return err,
        };
        if (self.raft) |raft| try raft.tick();
    }
};

/// Poke a listener whose accept loop is blocked, so it can observe `running=false`.
fn wakeAccept(io: std.Io, port: u16) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

test "ClusterBootstrap initialization" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cluster = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "test-node",
        .port = 19000,
        .peers = &.{},
        // Single node: nothing to elect, so the stub transport is fine.
        .raft_cluster_size = 1,
    });
    defer cluster.deinit();

    // Before any tick: the view is the empty cluster (generation 0), not garbage.
    try std.testing.expectEqual(@as(usize, 0), cluster.getView().stats().members);

    try cluster.start();
    try std.testing.expect(cluster.getEventBus() != null);
    try std.testing.expect(cluster.getMembership() != null);
    try std.testing.expect(cluster.getRaft() != null);

    const m = cluster.getMetrics();
    try std.testing.expectEqual(@as(u64, 1), m.node_count.load(.monotonic));

    // One tick drives gossip/health *and* publishes the read side — the wiring
    // that used to be missing on both ends.
    try cluster.tick();
    const snap = cluster.getView().acquire();
    defer cluster.getView().release(snap);
    try std.testing.expectEqual(@as(usize, 1), snap.count());
    try std.testing.expectEqualStrings("test-node", snap.find("test-node").?.id);
    try std.testing.expect(snap.find("test-node").?.healthy);
}

test "ClusterBootstrap accepts an app-supplied Raft transport" {
    const allocator = std.testing.allocator;
    // With a transport supplied the node also opens the inbound listener (on
    // `port`), so this test needs loopback sockets — like the RaftTransport ones.
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // A "real" transport for this test: it records nothing, but it is *not* the
    // stub — which is the point (the guard only fires without one).
    const Impl = struct {
        fn sendVote(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        fn sendAppend(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
            return .{ .term = 7, .success = true, .match_index = 1 };
        }
    };
    var vtable = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void = Impl.sendVote,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse = Impl.sendAppend,
    }{};
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(&vtable));

    // `raft_cluster_size` stays at its default 3: with a transport supplied this
    // must start — the *stub* guard needs no acknowledgement here. The cluster
    // secret is the other requirement a multi-node cluster with a real transport
    // has (see the gate tests below), and the peer carries the `@id` a multi-node
    // cluster needs to credit its votes.
    var cluster = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "byo-transport-node",
        .port = 19004,
        .peers = &.{"peer-node@127.0.0.1:19005"},
        .transport = transport,
        .cluster_secret = @splat(0x11),
    });
    defer cluster.deinit();
    try cluster.start();
    try std.testing.expect(cluster.getRaft() != null);
    // A supplied transport brings the inbound half with it: the node listens for
    // peers' votes / AppendEntries on its cluster port.
    try std.testing.expect(cluster.server.running.load(.monotonic));
    try cluster.tick();
}

test "ClusterBootstrap refuses a multi-node cluster without a real Raft transport" {
    const allocator = std.testing.allocator;

    // Default `raft_cluster_size` is 3 and the built-in Raft transport is a stub,
    // so this must fail loudly instead of electing a leader nobody voted for.
    // (The peer carries an `@id` so this config isolates *that* gate: a missing id
    // is `PeerIdRequired`, refused one gate later.)
    var refusing = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "refusing-node",
        .port = 19002,
        .peers = &.{"peer-node@127.0.0.1:19003"},
    });
    defer refusing.deinit();
    try std.testing.expectError(error.RaftTransportUnavailable, refusing.start());

    // Acknowledged form: membership + read side only, no elections claimed.
    var acked = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "acked-node",
        .port = 19003,
        .peers = &.{"peer-node@127.0.0.1:19002"},
        .allow_stub_raft_transport = true,
    });
    defer acked.deinit();
    try acked.start();
    try acked.tick();

    const view = acked.getView();
    const snap = view.acquire();
    defer view.release(snap);
    try std.testing.expect(snap.count() >= 1);
    try std.testing.expect(snap.find("acked-node") != null);
}

/// The vtable the cluster-secret gate tests hand in as `.transport`. They are
/// about the gate, not about the transport, so this only has to be *not* the
/// built-in stub (`Impl` above); it is never dialled.
const GateTransport = struct {
    fn sendVote(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
    fn sendAppend(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
        return .{ .term = 0, .success = false, .match_index = 0 };
    }
};

fn gateTransport() RaftElection.ElectionTransport {
    const S = struct {
        var vtable = struct {
            sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void = GateTransport.sendVote,
            sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse = GateTransport.sendAppend,
        }{};
    };
    return @ptrCast(@alignCast(&S.vtable));
}

test "ClusterBootstrap refuses a multi-node cluster without a cluster secret" {
    const allocator = std.testing.allocator;

    // Same shape as the `RaftTransportUnavailable` case above, one layer up: a
    // real transport (so votes would actually travel) with no pre-shared key means
    // the cluster port answers anyone who can reach it. The gate fires before the
    // inbound listener is spawned, so this needs no socket.
    var refusing = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "unauthenticated-node",
        .port = 19010,
        .peers = &.{"peer-node@127.0.0.1:19011"},
        .raft_cluster_size = 3,
        .transport = gateTransport(),
    });
    defer refusing.deinit();
    try std.testing.expectError(error.ClusterAuthRequired, refusing.start());
}

test "ClusterBootstrap starts a multi-node cluster that has a cluster secret" {
    const allocator = std.testing.allocator;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // The gate's positive control: it keys off `cluster_secret`, not off
    // "multi-node with a transport" — so supplying a key must start the node.
    const secret: [32]u8 = @splat(0x2b);
    var authed = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "authenticated-node",
        .port = 19012,
        .peers = &.{"peer-node@127.0.0.1:19013"},
        .raft_cluster_size = 3,
        .transport = gateTransport(),
        .cluster_secret = secret,
    });
    defer authed.deinit();

    try authed.start();
    // The secret reached the raft, which is what `RaftTransport` reads on every
    // frame — outbound (`TransportImpl`) and inbound (`handleConnection`).
    try std.testing.expectEqual(secret, authed.getRaft().?.config.cluster_secret.?);
}

test "ClusterBootstrap refuses a multi-node cluster whose peers carry no id" {
    const allocator = std.testing.allocator;

    // Every other gate is satisfied — real transport, pre-shared key — and the
    // only thing wrong is the peer grammar: `"127.0.0.1:19031"` parses with the
    // host as the id (`PeerDiscovery`), which is the shape that could never
    // credit that peer's vote. Refusing it is not a regression: that cluster
    // already had no leader and never would (`docs/dev/cluster-auth-design.md` §10).
    var refusing = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "idless-node",
        .port = 19030,
        .peers = &.{"127.0.0.1:19031"},
        .raft_cluster_size = 3,
        .transport = gateTransport(),
        .cluster_secret = @splat(0x3c),
    });
    defer refusing.deinit();
    try std.testing.expectError(error.PeerIdRequired, refusing.start());

    // Positive control: the same config with the ids declared starts.
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    var named = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "named-node",
        .port = 19032,
        .peers = &.{"peer-node@127.0.0.1:19033"},
        .raft_cluster_size = 3,
        .transport = gateTransport(),
        .cluster_secret = @splat(0x3c),
    });
    defer named.deinit();
    try named.start();
    // The peer entered the raft (self + one), and it entered under the declared id:
    // that name is what `handleVoteResponse` looks the ballot up by.
    try std.testing.expectEqual(@as(usize, 2), named.getRaft().?.clusterSize());
    try std.testing.expect(named.server.running.load(.monotonic));
}

test "ClusterBootstrap starts an acknowledged unauthenticated multi-node cluster" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // The loud opt-out, the same idiom as `allow_stub_raft_transport`: the cluster
    // runs, on bare frames, because the app said so.
    var acked = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "acked-unauth-node",
        .port = 19014,
        .peers = &.{"peer-node@127.0.0.1:19015"},
        .raft_cluster_size = 3,
        .transport = gateTransport(),
        .allow_unauthenticated_cluster = true,
    });
    defer acked.deinit();

    try acked.start();
    try std.testing.expect(acked.server.running.load(.monotonic));
    // "Unauthenticated" is exactly this: the raft has no key, so frames are bare.
    try std.testing.expect(acked.getRaft().?.config.cluster_secret == null);
}

test "ClusterBootstrap needs no cluster secret for a single node" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // One node has no peer to talk to, so the gate must not fire — and no
    // acknowledgement is needed to say that.
    var solo = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "solo-node",
        .port = 19016,
        .peers = &.{},
        .raft_cluster_size = 1,
        .transport = gateTransport(),
    });
    defer solo.deinit();

    try solo.start();
    try std.testing.expect(solo.server.running.load(.monotonic));
    try std.testing.expect(solo.getRaft().?.config.cluster_secret == null);
}

test "ClusterBootstrap facade: single node routes, reports health, stops twice" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cluster = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "facade-node",
        .port = 19720,
        .peers = &.{},
        .raft_cluster_size = 1,
    });
    defer cluster.deinit();

    try cluster.start();
    // Several consecutive ticks must be harmless on their own (membership + view +
    // raft). Whether this node ended up leading is another workflow's business.
    var i: usize = 0;
    while (i < 3) : (i += 1) try cluster.tick();

    const snap = cluster.getView().acquire();
    defer cluster.getView().release(snap);
    try std.testing.expectEqual(@as(usize, 1), snap.count());
    try std.testing.expectEqualStrings("facade-node", snap.find("facade-node").?.id);

    // Rendezvous routing: with one member every key has the same answer.
    try std.testing.expectEqualStrings("facade-node", cluster.pick("order-1").?.id);
    try std.testing.expectEqualStrings("facade-node", cluster.pick("order-2").?.id);

    const json = try cluster.healthJson(allocator);
    defer allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("UP", parsed.value.object.get("status").?.string);
    const cluster_obj = parsed.value.object.get("cluster").?.object;
    try std.testing.expectEqual(@as(i64, 1), cluster_obj.get("nodes_active").?.integer);

    // Terminal cleanup is `deinit()`; an explicit stop before it must be safe to
    // repeat (and `deinit` below adds one more).
    cluster.stop();
    cluster.stop();
}

test "ClusterBootstrap drives raft.tick and serves inbound Raft RPCs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // Counts what the outbound half is asked to send. The peer is not dialled,
    // which is the point: `tick()` has to reach the transport by itself.
    const Counting = struct {
        var votes_sent: usize = 0;
        fn sendVote(_: ?[]const u8, _: []const u8, _: VoteRequest) void {
            votes_sent += 1;
        }
        fn sendAppend(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
            return .{ .term = 0, .success = false, .match_index = 0 };
        }
    };
    var vtable = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void = Counting.sendVote,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse = Counting.sendAppend,
    }{};
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(&vtable));

    var cluster = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "raft-node",
        .port = 19730,
        .peers = &.{"peer-node@127.0.0.1:19731"},
        .raft_cluster_size = 2,
        .transport = transport,
        // This test drives the **bare** frame shape on purpose (it writes an
        // unsigned vote request by hand below), so it runs unauthenticated —
        // which is what the acknowledgement is for.
        .allow_unauthenticated_cluster = true,
    });
    defer cluster.deinit();
    try cluster.start();

    // 1. `tick()` drives raft: the election timeout is wall-clock (150-300 ms), so
    //    wait it out and tick once — the term moves and a vote request goes out.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(400), .awake) catch {};
    try cluster.tick();
    const raft = cluster.getRaft().?;
    try std.testing.expect(raft.getTerm() >= 1);
    try std.testing.expect(Counting.votes_sent >= 1);

    // 2. Inbound: what a peer's `sendVoteRequest` puts on the wire is dispatched
    //    into this node's raft and answered on the same connection.
    const term_before = raft.getTerm();
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 19730);
    const stream = try addr.connect(io, .{ .mode = .stream });
    var conn = NetworkTransport.ClusterConnection.init(allocator, stream, io);
    defer conn.deinit();

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    try RaftTransport.encodeVoteRequest(&frame, allocator, .{
        .term = term_before + 5,
        .candidate_id = "peer-node",
        .last_log_index = 0,
        .last_log_term = 0,
    });
    try conn.send(frame.items);

    var reply = std.ArrayList(u8).empty;
    defer reply.deinit(allocator);
    const bytes = try conn.recv(&reply);
    const decoded = try RaftTransport.decodeVoteResponse(allocator, bytes);
    defer allocator.free(decoded.responder_id);
    try std.testing.expect(decoded.resp.vote_granted);
    try std.testing.expectEqualStrings("raft-node", decoded.responder_id);
    try std.testing.expectEqual(term_before + 5, decoded.resp.term);
    try std.testing.expectEqual(term_before + 5, raft.getTerm());

    // 3. Stopping the node (with its inbound thread) is safe to repeat.
    cluster.stop();
    cluster.stop();
}

// A `ClusterBootstrap`-configured cluster elects a leader — the defect this test
// exists for (`docs/dev/cluster-auth-design.md` §10). The config below is the
// real shape (`peers` as `"<id>@<host>:<port>"`), and `start()` hands the **id**
// to `raft.addPeer`. With `addPeer(p.host)` the peer would be named `127.0.0.1`,
// `handleVoteResponse(…, "node-b")` would find nothing in `raft.peers[].id`, drop
// the ballot and leave this node a candidate forever — the `isLeader()` assertion
// below is what goes red, not a compile error.
//
// No socket is needed: the stub transport is acknowledged (the vote response is
// fed in by hand), and `transport == null` means no inbound listener is spawned.
test "a ClusterBootstrap-configured cluster elects a leader (peers credited by id)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cluster = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "node-a",
        .port = 19750,
        .peers = &.{"node-b@127.0.0.1:19751"},
        .raft_cluster_size = 2,
        .allow_stub_raft_transport = true,
    });
    defer cluster.deinit();
    try cluster.start();

    const raft = cluster.getRaft().?;
    try std.testing.expectEqual(@as(usize, 2), raft.clusterSize());

    // One tick past the election timeout (wall-clock, 150–300 ms) makes this node
    // a candidate for a new term.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(400), .awake) catch |err| {
        std.log.debug("[test] election-timeout wait ({})", .{err});
    };
    try cluster.tick();
    try std.testing.expectEqual(RaftState.candidate, raft.getState());

    // node-b grants, naming itself the way it does on the wire: its `node_id`.
    // Self + that grant is a majority of two.
    try raft.handleVoteResponse(.{ .term = raft.getTerm(), .vote_granted = true }, "node-b");
    try std.testing.expect(raft.isLeader());
    try std.testing.expectEqualStrings("node-a", raft.getLeader().?);
}
