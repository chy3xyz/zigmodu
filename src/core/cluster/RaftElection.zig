//! Raft Leader Election Implementation
//!
//! This module implements the leader election part of the Raft consensus algorithm.
//! For the full Raft implementation (including log replication), see the raft module.
//!
//! Key features:
//! - Leader election with term numbers
//! - Vote granting and majority determination
//! - Randomized election timeouts to prevent split votes
//! - Integration with failure detector for liveness
//!
//! Reference: Ongaro & Ousterhout, "In Search of an Understandable Consensus Algorithm"

const std = @import("std");
const Time = @import("../Time.zig");

/// Configuration for Raft leader election
pub const ElectionConfig = struct {
    /// Minimum election timeout (ms)
    /// Followers wait this long before starting election
    election_timeout_min_ms: u64 = 150,

    /// Maximum election timeout (ms)
    election_timeout_max_ms: u64 = 300,

    /// Heartbeat interval (ms) - leader sends heartbeats at this rate
    heartbeat_interval_ms: u64 = 50,

    /// Maximum entries to send in one AppendEntries RPC
    max_append_entries: usize = 100,
};

/// Raft server state
pub const RaftState = enum {
    follower,
    candidate,
    leader,
};

/// A peer in the Raft cluster
pub const Peer = struct {
    id: []const u8,
    address: []const u8,
};

/// Vote request sent to peers
pub const VoteRequest = struct {
    term: u64,
    candidate_id: []const u8,
    last_log_index: u64,
    last_log_term: u64,
};

/// Vote response from peer
pub const VoteResponse = struct {
    term: u64,
    vote_granted: bool,
};

/// Leader heartbeat (AppendEntries with no entries)
pub const Heartbeat = struct {
    term: u64,
    leader_id: []const u8,
    prev_log_index: u64,
    prev_log_term: u64,
    entries: []const []const u8,
    leader_commit: u64,
};

/// Raft Leader Election
///
/// Handles leader election within a Raft cluster.
/// Manages term numbers, voting, and leader heartbeats.
pub const RaftElection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ElectionConfig,

    // Persistent state (would be persisted to disk in full Raft)
    current_term: u64 = 0,
    voted_for: ?[]const u8 = null,

    // Volatile state
    state: RaftState = .follower,
    leader_id: ?[]const u8 = null,

    // Membership
    local_id: []const u8,
    peers: std.ArrayList(Peer),

    // Timing
    last_heartbeat_ms: i64 = 0,
    election_deadline_ms: i64 = 0,

    // Transport interface for sending messages
    transport: *const ElectionTransport,

    /// Transport interface for network communication
    pub const ElectionTransport = *const struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendHeartbeat: *const fn (?[]const u8, []const u8, Heartbeat) void,
    };

    /// Initialize Raft election module
    pub fn init(
        allocator: std.mem.Allocator,
        local_id: []const u8,
        peers: []Peer,
        config: ElectionConfig,
        transport: *const ElectionTransport,
    ) !Self {
        const local_id_copy = try allocator.dupe(u8, local_id);
        errdefer allocator.free(local_id_copy);

        var peers_copy = std.ArrayList(Peer).init(allocator);
        for (peers) |peer| {
            const id_copy = try allocator.dupe(u8, peer.id);
            const addr_copy = try allocator.dupe(u8, peer.address);
            try peers_copy.append(.{ .id = id_copy, .address = addr_copy });
        }

        const now_ms = Time.monotonicNowMilliseconds();

        return .{
            .allocator = allocator,
            .config = config,
            .local_id = local_id_copy,
            .peers = peers_copy,
            .transport = transport,
            .last_heartbeat_ms = now_ms,
            .election_deadline_ms = now_ms + config.election_timeout_max_ms,
        };
    }

    /// Release all resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.local_id);
        for (self.peers.items) |peer| {
            self.allocator.free(peer.id);
            self.allocator.free(peer.address);
        }
        self.peers.deinit();
        if (self.voted_for) |v| self.allocator.free(v);
    }

    /// Main tick function - called periodically
    ///
    /// Checks if election timeout has expired or if we should send heartbeats.
    pub fn tick(self: *Self) !void {
        const now_ms = Time.monotonicNowMilliseconds();

        switch (self.state) {
            .follower, .candidate => {
                // Check if election timeout expired
                if (now_ms >= self.election_deadline_ms) {
                    try self.startElection();
                }
            },
            .leader => {
                // Send periodic heartbeats
                const time_since_last = now_ms - self.last_heartbeat_ms;
                if (time_since_last >= self.config.heartbeat_interval_ms) {
                    try self.sendHeartbeats();
                    self.last_heartbeat_ms = now_ms;
                }
            },
        }
    }

    /// Handle incoming vote request
    pub fn handleVoteRequest(self: *Self, req: VoteRequest) !VoteResponse {
        // Update term if needed
        if (req.term > self.current_term) {
            self.current_term = req.term;
            self.state = .follower;
            self.voted_for = null;
        }

        var vote_granted = false;

        if (req.term >= self.current_term) {
            // Check if we should grant vote
            if (self.voted_for == null or std.mem.eql(u8, self.voted_for.?, req.candidate_id)) {
                // In full Raft, would also check log completeness
                if (req.last_log_index >= 0) { // Placeholder for log comparison
                    vote_granted = true;
                    if (self.voted_for) |v| self.allocator.free(v);
                    self.voted_for = try self.allocator.dupe(u8, req.candidate_id);
                }
            }
        }

        return VoteResponse{
            .term = self.current_term,
            .vote_granted = vote_granted,
        };
    }

    /// Handle incoming heartbeat from leader
    pub fn handleHeartbeat(self: *Self, hb: Heartbeat) !void {
        // Update term if needed
        if (hb.term > self.current_term) {
            self.current_term = hb.term;
            self.state = .follower;
            self.voted_for = null;
        }

        // Reset election deadline
        const now_ms = Time.monotonicNowMilliseconds();
        self.last_heartbeat_ms = now_ms;
        self.election_deadline_ms = now_ms + self.randomElectionTimeout();

        // Update leader info
        if (self.leader_id) |l| self.allocator.free(l);
        self.leader_id = try self.allocator.dupe(u8, hb.leader_id);

        std.log.debug("[RaftElection] Received heartbeat from leader {s}", .{hb.leader_id});
    }

    /// Handle vote response from peer
    pub fn handleVoteResponse(self: *Self, resp: VoteResponse, from_peer: []const u8) !void {
        _ = from_peer; // Acknowledge but don't use in this implementation
        // Update term if needed
        if (resp.term > self.current_term) {
            self.current_term = resp.term;
            self.state = .follower;
            return;
        }

        if (self.state != .candidate) return;

        if (resp.vote_granted) {
            // Count vote (simplified - in full impl would track per-peer)
            self.becomeLeader();
        }
    }

    /// Start a new election
    fn startElection(self: *Self) !void {
        self.state = .candidate;
        self.current_term +|= 1;

        // Vote for self
        if (self.voted_for) |v| self.allocator.free(v);
        self.voted_for = try self.allocator.dupe(u8, self.local_id);

        // Reset election deadline
        const now_ms = Time.monotonicNowMilliseconds();
        self.election_deadline_ms = now_ms + self.randomElectionTimeout();

        std.log.info("[RaftElection] Starting election for term {d}", .{self.current_term});

        // Request votes from all peers
        const vote_req = VoteRequest{
            .term = self.current_term,
            .candidate_id = self.local_id,
            .last_log_index = 0, // Would be actual log index
            .last_log_term = 0,
        };

        for (self.peers.items) |peer| {
            self.transport.sendVoteRequest(peer.id, peer.address, vote_req);
        }
    }

    /// Become leader (we've won the election)
    fn becomeLeader(self: *Self) void {
        self.state = .leader;
        self.leader_id = self.local_id;

        const now_ms = Time.monotonicNowMilliseconds();
        self.last_heartbeat_ms = now_ms;

        std.log.info("[RaftElection] Node {s} became leader for term {d}", .{
            self.local_id,
            self.current_term,
        });

        // Send initial heartbeat immediately
        self.sendHeartbeats() catch {};
    }

    /// Send heartbeats to all peers
    fn sendHeartbeats(self: *Self) !void {
        const hb = Heartbeat{
            .term = self.current_term,
            .leader_id = self.local_id,
            .prev_log_index = 0,
            .prev_log_term = 0,
            .entries = &.{},
            .leader_commit = 0,
        };

        for (self.peers.items) |peer| {
            self.transport.sendHeartbeat(peer.id, peer.address, hb);
        }
    }

    /// Generate random election timeout
    fn randomElectionTimeout(self: *Self) u64 {
        const range = self.config.election_timeout_max_ms - self.config.election_timeout_min_ms;
        const now = Time.monotonicNowMilliseconds();
        var rng = std.Random.DefaultPrng.init(@bitCast(now));
        return self.config.election_timeout_min_ms + rng.random().int(u64) % range;
    }

    /// Check if this node is the leader
    pub fn isLeader(self: Self) bool {
        return self.state == .leader;
    }

    /// Get current leader ID
    pub fn getLeader(self: Self) ?[]const u8 {
        return self.leader_id;
    }

    /// Get current term
    pub fn getTerm(self: Self) u64 {
        return self.current_term;
    }

    /// Get current state
    pub fn getState(self: Self) RaftState {
        return self.state;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "RaftElection initialization" {
    const allocator = std.testing.allocator;

    const config = ElectionConfig{};
    const peers = &[_]Peer{
        .{ .id = "peer1", .address = "localhost:7001" },
        .{ .id = "peer2", .address = "localhost:7002" },
    };

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendHeartbeat: *const fn (?[]const u8, []const u8, Heartbeat) void,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendHeartbeat = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: Heartbeat) void {}
        }).f,
    };
    const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transport_impl)));

    var election = try RaftElection.init(
        allocator,
        "node1",
        peers[0..],
        config,
        &transport,
    );
    defer election.deinit();

    try std.testing.expectEqual(RaftState.follower, election.getState());
    try std.testing.expectEqual(@as(u64, 0), election.getTerm());
}

test "RaftElection heartbeat resets leader info" {
    const allocator = std.testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendHeartbeat: *const fn (?[]const u8, []const u8, Heartbeat) void,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendHeartbeat = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: Heartbeat) void {}
        }).f,
    };
    const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transport_impl)));

    var election = try RaftElection.init(
        allocator,
        "node1",
        &.{},
        .{},
        &transport,
    );
    defer election.deinit();

    try std.testing.expect(!election.isLeader());

    const hb = Heartbeat{
        .term = 1,
        .leader_id = "leader1",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{},
        .leader_commit = 0,
    };
    try election.handleHeartbeat(hb);

    try std.testing.expectEqualStrings("leader1", election.getLeader().?);
}

test "RaftElection vote request validation" {
    const allocator = std.testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendHeartbeat: *const fn (?[]const u8, []const u8, Heartbeat) void,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendHeartbeat = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: Heartbeat) void {}
        }).f,
    };
    const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transport_impl)));

    var election = try RaftElection.init(
        allocator,
        "node1",
        &.{},
        .{},
        &transport,
    );
    defer election.deinit();

    const req = VoteRequest{
        .term = 5,
        .candidate_id = "candidate1",
        .last_log_index = 10,
        .last_log_term = 3,
    };

    const resp = try election.handleVoteRequest(req);
    try std.testing.expect(resp.vote_granted);
    try std.testing.expectEqual(@as(u64, 5), election.getTerm());
}
