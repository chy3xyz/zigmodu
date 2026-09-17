//! One-shot cluster bootstrap for multi-node deployments.
//!
//! Wires together: PeerDiscovery → ClusterMembership → DistributedEventBus → RaftElection
//! Provides a single start()/stop() API for the entire cluster stack.
//!
//! Usage:
//!   var cluster = try ClusterBootstrap.init(allocator, io, .{
//!       .node_id = "node-1",
//!       .port = 9000,
//!       .peers = &.{"127.0.0.1:9001", "127.0.0.1:9002"},
//!   });
//!   try cluster.start();
//!   defer cluster.stop();

const std = @import("std");
const PeerDiscovery = @import("PeerDiscovery.zig").PeerDiscovery;
const NetworkTransport = @import("NetworkTransport.zig");
const ClusterMembership = @import("../ClusterMembership.zig").ClusterMembership;
const DistributedEventBus = @import("../DistributedEventBus.zig").DistributedEventBus;
const RaftElection = @import("RaftElection.zig").RaftElection;
const ElectionConfig = @import("RaftElection.zig").ElectionConfig;
const VoteRequest = @import("RaftElection.zig").VoteRequest;
const AppendEntriesRequest = @import("RaftElection.zig").AppendEntriesRequest;
const AppendEntriesResponse = @import("RaftElection.zig").AppendEntriesResponse;
const ClusterMetrics = @import("ClusterMetrics.zig").ClusterMetrics;
const MembershipView = @import("../../cluster/MembershipView.zig").MembershipView;

/// Read-side view handed out by `getView()`. 16 members / 2 generations is the
/// documented 3–7 node sweet spot with headroom; bump it for bigger clusters.
pub const view_members = 16;
pub const view_generations = 2;
pub const View = MembershipView(view_members, view_generations);

pub const BootstrapConfig = struct {
    node_id: []const u8,
    port: u16 = 9000,
    peers: []const []const u8 = &.{},
    raft_cluster_size: usize = 3,
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
    metrics: ClusterMetrics,
    server: NetworkTransport.ClusterServer,
    /// Read side fed by `tick()`. Request paths use it instead of the
    /// membership hash map (`acquire`/`pick`, see `cluster/MembershipView.zig`).
    view: View,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: BootstrapConfig) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .metrics = ClusterMetrics.init(allocator),
            .server = NetworkTransport.ClusterServer.init(allocator, io, config.port),
            .view = View.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.view.deinit();
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
        // The transport below is a **stub**: `sendVoteRequest` is a no-op and
        // `sendAppendEntries` always fails. A real one has to carry Raft's
        // request/response over `NetworkTransport` (vote request → vote response,
        // append entries → match index); until that exists, a multi-node election
        // cannot make progress. Refuse loudly rather than elect a "leader" no peer
        // ever voted for — a single-node cluster has nothing to elect, and a
        // process that only wants membership + the read side acknowledges with
        // `.allow_stub_raft_transport = true`.
        if (self.config.raft_cluster_size > 1 and !self.config.allow_stub_raft_transport) {
            // `warn`, not `err`: the returned error is the loud part, and the test
            // harness treats an `err`-level log as a failure by itself.
            std.log.warn(
                "[ClusterBootstrap] refusing to start node {s}: raft_cluster_size={d} but the built-in Raft transport is a stub (votes go nowhere). " ++
                    "Set `.allow_stub_raft_transport = true` to run membership + read side only, or raft_cluster_size = 1 for a single node.",
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
        const election_transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&S.transport_impl.?)));
        const raft = try self.allocator.create(RaftElection);
        raft.* = try RaftElection.init(self.allocator, self.config.node_id, &.{}, election_cfg, &election_transport);
        self.raft = raft;

        // Add peers to Raft
        for (peers) |p| {
            try raft.addPeer(p.host);
        }

        // 5. Leader change callback: member.onLeaderChange(callback) already available

        std.log.info("[ClusterBootstrap] Node {s} started on port {d} with {d} peers", .{
            self.config.node_id, self.config.port, peers.len,
        });
    }

    pub fn stop(self: *Self) void {
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
        self.server.deinit();
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

    /// Advance the cluster one step: one gossip/health pass, then refresh the
    /// read side. **Nothing calls this for you** — the membership loop is
    /// externally driven by design (`ClusterMembership.runOnce`), so drive it
    /// from your own loop or a runtime timer:
    ///
    /// ```zig
    /// _ = try worker.after(1000, .tick);   // runtime timer → Worker.handle → cluster.tick()
    /// ```
    ///
    /// `error.ReadersBusy` is not a failure: a request path was mid-read, so the
    /// view keeps its previous generation and the next tick publishes again.
    pub fn tick(self: *Self) !void {
        const member = self.membership orelse return;
        try member.runOnce();
        self.view.sync(member) catch |err| switch (err) {
            error.ReadersBusy => {},
            else => return err,
        };
    }
};

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
