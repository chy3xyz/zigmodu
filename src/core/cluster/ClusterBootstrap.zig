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
//!       .peers = &.{"127.0.0.1:9001", "127.0.0.1:9002"},
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
    /// Serializes the only two threads that touch the same `RaftElection`: this
    /// process's `tick()` (→ `raft.tick()`, on the app's thread) and the inbound
    /// dispatch on `inbound_thread` (an RPC's `raft.handle*` mutates the same
    /// `voted_for` / `log` / `next_index`). Both belong to this facade — `start()`
    /// spawns the second, `tick()` is the documented way to drive the first — so
    /// the lock lives here. `docs/DISTRIBUTED.md`「真选主要什么」has the wiring.
    raft_lock: RaftTransport.RaftLock = .{},
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
        const election_cfg = ElectionConfig{};
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

        // Add peers to Raft. The address book carries the same identity (the host
        // string) so the inbound relay can turn a vote response's candidate back
        // into a `host:port` — the only peer→address mapping this config has.
        for (peers) |p| {
            try raft.addPeer(p.host);
            try self.addresses.add(p.host, p.host, p.port);
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
        RaftTransport.handleConnectionLocked(raft, &self.addresses, &owned, &self.raft_lock);
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
    /// The Raft step runs under `raft_lock`: with a `.transport`, `start()` has an
    /// accept thread dispatching peers' RPCs into the same `RaftElection`, and
    /// `RaftElection` carries no lock of its own (see the field).
    pub fn tick(self: *Self) !void {
        const member = self.membership orelse return;
        try member.runOnce();
        self.view.sync(member) catch |err| switch (err) {
            error.ReadersBusy => {},
            else => return err,
        };
        if (self.raft) |raft| {
            self.raft_lock.acquire();
            defer self.raft_lock.release();
            try raft.tick();
        }
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
    // must start (no acknowledgement needed).
    var cluster = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "byo-transport-node",
        .port = 19004,
        .peers = &.{"127.0.0.1:19005"},
        .transport = transport,
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
    var refusing = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "refusing-node",
        .port = 19002,
        .peers = &.{"127.0.0.1:19003"},
    });
    defer refusing.deinit();
    try std.testing.expectError(error.RaftTransportUnavailable, refusing.start());

    // Acknowledged form: membership + read side only, no elections claimed.
    var acked = try ClusterBootstrap.init(allocator, std.testing.io, .{
        .node_id = "acked-node",
        .port = 19003,
        .peers = &.{"127.0.0.1:19002"},
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
        .peers = &.{"127.0.0.1:19731"},
        .raft_cluster_size = 2,
        .transport = transport,
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
