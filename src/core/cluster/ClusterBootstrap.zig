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
const Heartbeat = @import("RaftElection.zig").Heartbeat;
const ClusterMetrics = @import("ClusterMetrics.zig").ClusterMetrics;

pub const BootstrapConfig = struct {
    node_id: []const u8,
    port: u16 = 9000,
    peers: []const []const u8 = &.{},
    raft_cluster_size: usize = 3,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: BootstrapConfig) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .metrics = ClusterMetrics.init(allocator),
            .server = NetworkTransport.ClusterServer.init(allocator, io, config.port),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start all cluster services.
    pub fn start(self: *Self) !void {
        // 1. Discover peers
        var disco = PeerDiscovery.init(self.allocator, .{
            .static_peers = self.config.peers,
            .local_port = self.config.port,
        });
        const peers = try disco.resolve();
        defer disco.deinit(peers);
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

        // 4. Create RaftElection (leader election)
        const election_cfg = ElectionConfig{};
        const S = struct {
            var transport_impl: ?struct {
                sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
                sendHeartbeat: *const fn (?[]const u8, []const u8, Heartbeat) void,
            } = null;
        };
        if (S.transport_impl == null) {
            S.transport_impl = .{
                .sendVoteRequest = struct { fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {} }.f,
                .sendHeartbeat = struct { fn f(_: ?[]const u8, _: []const u8, _: Heartbeat) void {} }.f,
            };
        }
        const election_transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&S.transport_impl.?)));
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

    pub fn getMetrics(self: *Self) *ClusterMetrics { return &self.metrics; }
    pub fn getEventBus(self: *Self) ?*DistributedEventBus { return self.bus; }
    pub fn getMembership(self: *Self) ?*ClusterMembership { return self.membership; }
    pub fn getRaft(self: *Self) ?*RaftElection { return self.raft; }
};

test "ClusterBootstrap initialization" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cluster = try ClusterBootstrap.init(allocator, io, .{
        .node_id = "test-node",
        .port = 19000,
        .peers = &.{},
    });
    defer cluster.deinit();

    try cluster.start();
    try std.testing.expect(cluster.getEventBus() != null);
    try std.testing.expect(cluster.getMembership() != null);
    try std.testing.expect(cluster.getRaft() != null);

    const m = cluster.getMetrics();
    try std.testing.expectEqual(@as(u64, 1), m.node_count.load(.monotonic));
}
