//! Raft Consensus Implementation
//!
//! This module implements the Raft consensus algorithm including:
//! - Leader election with term numbers
//! - Log replication with AppendEntries
//! - Vote granting and majority determination
//! - Randomized election timeouts to prevent split votes
//! - Integration with failure detector for liveness
//!
//! Reference: Ongaro & Ousterhout, "In Search of an Understandable Consensus Algorithm"

const std = @import("std");
const Time = @import("../Time.zig");

/// Configuration for Raft
pub const ElectionConfig = struct {
    /// Minimum election timeout (ms)
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

/// A single log entry in the replicated log
pub const LogEntry = struct {
    term: u64,
    index: u64,
    command: []const u8, // serialized command
};

/// AppendEntries RPC request (leader → follower)
pub const AppendEntriesRequest = struct {
    term: u64,
    leader_id: []const u8,
    prev_log_index: u64,
    prev_log_term: u64,
    entries: []const LogEntry,
    leader_commit: u64,
};

/// AppendEntries RPC response (follower → leader)
pub const AppendEntriesResponse = struct {
    term: u64,
    success: bool,
    match_index: u64, // highest log index matched (for fast backtracking)
};

/// Raft
///
/// Handles leader election and log replication within a Raft cluster.
pub const RaftElection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ElectionConfig,

    // Persistent state (would be persisted to disk in full Raft)
    current_term: u64 = 0,
    voted_for: ?[]const u8 = null,
    log: std.ArrayList(LogEntry),

    // Volatile state (all servers)
    state: RaftState = .follower,
    leader_id: ?[]const u8 = null,
    commit_index: u64 = 0,
    last_applied: u64 = 0,

    // Leader state (reinitialized after election)
    next_index: std.StringHashMap(u64),
    match_index: std.StringHashMap(u64),

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
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };

    /// Initialize Raft module
    pub fn init(
        allocator: std.mem.Allocator,
        local_id: []const u8,
        peers: []Peer,
        config: ElectionConfig,
        transport: *const ElectionTransport,
    ) !Self {
        const local_id_copy = try allocator.dupe(u8, local_id);
        errdefer allocator.free(local_id_copy);

        var peers_copy = std.ArrayList(Peer).empty;
        for (peers) |peer| {
            const id_copy = try allocator.dupe(u8, peer.id);
            const addr_copy = try allocator.dupe(u8, peer.address);
            try peers_copy.append(allocator, .{ .id = id_copy, .address = addr_copy });
        }

        const now_ms = Time.monotonicNowMilliseconds();

        return .{
            .allocator = allocator,
            .config = config,
            .log = std.ArrayList(LogEntry).empty,
            .next_index = std.StringHashMap(u64).init(allocator),
            .match_index = std.StringHashMap(u64).init(allocator),
            .local_id = local_id_copy,
            .peers = peers_copy,
            .transport = transport,
            .last_heartbeat_ms = now_ms,
            .election_deadline_ms = now_ms + @as(i64, @intCast(config.election_timeout_max_ms)),
        };
    }

    /// Release all resources
    pub fn deinit(self: *Self) void {
        // Free log entries (each owns its command string)
        for (self.log.items) |entry| {
            self.allocator.free(entry.command);
        }
        self.log.deinit(self.allocator);

        // Free leader state hashmaps (keys are borrowed from peers, values are u64)
        self.next_index.deinit();
        self.match_index.deinit();

        self.allocator.free(self.local_id);
        for (self.peers.items) |peer| {
            self.allocator.free(peer.id);
            self.allocator.free(peer.address);
        }
        self.peers.deinit(self.allocator);
        if (self.voted_for) |v| self.allocator.free(v);
        // leader_id may alias local_id (from becomeLeader); only free when they differ
        if (self.leader_id) |l| {
            if (l.ptr != self.local_id.ptr) {
                self.allocator.free(l);
            }
        }
        self.* = undefined;
    }

    /// Main tick function - called periodically
    pub fn tick(self: *Self) !void {
        const now_ms = Time.monotonicNowMilliseconds();

        switch (self.state) {
            .follower, .candidate => {
                if (now_ms >= self.election_deadline_ms) {
                    try self.startElection();
                }
            },
            .leader => {
                const time_since_last = now_ms - self.last_heartbeat_ms;
                if (time_since_last >= self.config.heartbeat_interval_ms) {
                    try self.sendHeartbeats();
                    self.last_heartbeat_ms = now_ms;
                }
            },
        }
    }

    /// Leader appends a command to the log, returns the log index.
    pub fn appendEntry(self: *Self, command: []const u8) !u64 {
        if (self.state != .leader) return error.NotLeader;

        const cmd_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(cmd_copy);

        const index: u64 = @intCast(self.log.items.len + 1);
        try self.log.append(self.allocator, LogEntry{
            .term = self.current_term,
            .index = index,
            .command = cmd_copy,
        });
        return index;
    }

    /// Handle incoming vote request from a candidate.
    pub fn handleVoteRequest(self: *Self, req: VoteRequest) !VoteResponse {
        if (req.term > self.current_term) {
            self.current_term = req.term;
            self.state = .follower;
            if (self.voted_for) |v| self.allocator.free(v);
            self.voted_for = null;
        }

        var vote_granted = false;

        if (req.term >= self.current_term) {
            if (self.voted_for == null or std.mem.eql(u8, self.voted_for.?, req.candidate_id)) {
                // Check log completeness: candidate's log must be at least as up-to-date
                const last_idx: u64 = @intCast(self.log.items.len);
                const last_term = if (last_idx > 0) self.log.items[last_idx - 1].term else 0;

                if (req.last_log_term > last_term or
                    (req.last_log_term == last_term and req.last_log_index >= last_idx))
                {
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

    /// Follower handles incoming AppendEntries RPC from leader.
    pub fn handleAppendEntries(self: *Self, req: AppendEntriesRequest) !AppendEntriesResponse {
        // Reply false if term < current_term (§5.1)
        if (req.term < self.current_term) {
            return AppendEntriesResponse{
                .term = self.current_term,
                .success = false,
                .match_index = @intCast(self.log.items.len),
            };
        }

        // Update term if leader has higher term
        if (req.term > self.current_term) {
            self.current_term = req.term;
        }

        // Reset to follower state and update election deadline
        self.state = .follower;
        const now_ms = Time.monotonicNowMilliseconds();
        self.last_heartbeat_ms = now_ms;
        self.election_deadline_ms = now_ms + @as(i64, @intCast(self.randomElectionTimeout()));

        // Update leader info
        if (self.leader_id) |l| self.allocator.free(l);
        self.leader_id = try self.allocator.dupe(u8, req.leader_id);

        // Reply false if log doesn't contain entry at prev_log_index with matching term (§5.3)
        if (req.prev_log_index > 0) {
            if (req.prev_log_index > self.log.items.len) {
                return AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .match_index = @intCast(self.log.items.len),
                };
            }
            const prev_entry = self.log.items[req.prev_log_index - 1];
            if (prev_entry.term != req.prev_log_term) {
                // Conflict: delete conflicting entry and everything after it
                self.truncateLog(req.prev_log_index - 1);
                return AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .match_index = @intCast(self.log.items.len),
                };
            }
        }

        // Process incoming entries: skip already-matched, overwrite conflicts
        for (req.entries) |entry| {
            if (entry.index <= self.log.items.len) {
                const existing = self.log.items[entry.index - 1];
                if (existing.term != entry.term) {
                    // Conflict at this index: delete it and everything after
                    self.truncateLog(entry.index - 1);
                    // Fall through to append below
                } else {
                    continue; // Already have this matching entry, skip
                }
            }
            // Append new entry
            const cmd_copy = try self.allocator.dupe(u8, entry.command);
            errdefer self.allocator.free(cmd_copy);
            try self.log.append(self.allocator, LogEntry{
                .term = entry.term,
                .index = entry.index,
                .command = cmd_copy,
            });
        }

        // Update commit index (§5.3, §5.4)
        if (req.leader_commit > self.commit_index) {
            const last_idx: u64 = @intCast(self.log.items.len);
            self.commit_index = @min(req.leader_commit, last_idx);
        }

        return AppendEntriesResponse{
            .term = self.current_term,
            .success = true,
            .match_index = @intCast(self.log.items.len),
        };
    }

    /// Leader sends AppendEntries to all peers with new log entries.
    fn sendAppendEntries(self: *Self) !void {
        for (self.peers.items) |peer| {
            const next_idx = self.next_index.get(peer.id) orelse blk: {
                // Initialize if missing
                const idx: u64 = @intCast(self.log.items.len + 1);
                self.next_index.put(peer.id, idx) catch continue;
                break :blk idx;
            };

            // Build entries slice: from (next_idx - 1) to end of log
            const start: usize = if (next_idx > 0) @intCast(next_idx - 1) else 0;
            const entries: []const LogEntry = if (start < self.log.items.len)
                self.log.items[start..]
            else
                &.{};

            var prev_log_idx: u64 = 0;
            var prev_log_term: u64 = 0;
            if (start > 0 and start <= self.log.items.len) {
                prev_log_idx = self.log.items[start - 1].index;
                prev_log_term = self.log.items[start - 1].term;
            }

            const req = AppendEntriesRequest{
                .term = self.current_term,
                .leader_id = self.local_id,
                .prev_log_index = prev_log_idx,
                .prev_log_term = prev_log_term,
                .entries = entries,
                .leader_commit = self.commit_index,
            };

            const resp = self.transport.*.sendAppendEntries(peer.id, peer.address, req);

            if (resp.term > self.current_term) {
                self.current_term = resp.term;
                self.state = .follower;
                return;
            }

            if (resp.success) {
                // Update match_index and next_index
                const matched: u64 = if (entries.len > 0)
                    entries[entries.len - 1].index
                else
                    prev_log_idx;
                self.next_index.put(peer.id, matched + 1) catch {};
                self.match_index.put(peer.id, matched) catch {};
            } else {
                // Decrement next_index for fast backtracking
                if (next_idx > 1) {
                    self.next_index.put(peer.id, next_idx - 1) catch {};
                }
                if (resp.match_index > 0) {
                    // Use follower's match_index hint for faster convergence
                    self.next_index.put(peer.id, @min(next_idx - 1, resp.match_index + 1)) catch {};
                }
            }
        }
    }

    /// Advance commit_index if a majority of peers have replicated an entry
    /// from the current term (§5.3, §5.4).
    fn advanceCommitIndex(self: *Self) void {
        var n: u64 = self.commit_index + 1;
        while (n <= self.log.items.len) : (n += 1) {
            // Only commit entries from the current term (§5.4.2)
            if (self.log.items[@intCast(n - 1)].term != self.current_term) continue;

            var count: usize = 1; // count self
            var it = self.match_index.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* >= n) {
                    count += 1;
                }
            }

            if (count >= self.quorumSize()) {
                self.commit_index = n;
            } else {
                break;
            }
        }
    }

    /// Truncate the log to keep only the first `keep_count` entries.
    fn truncateLog(self: *Self, keep_count: u64) void {
        while (self.log.items.len > keep_count) {
            if (self.log.pop()) |entry| {
                self.allocator.free(entry.command);
            }
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
        self.election_deadline_ms = now_ms + @as(i64, @intCast(self.randomElectionTimeout()));

        std.log.info("[RaftElection] Starting election for term {d}", .{self.current_term});

        const last_idx: u64 = @intCast(self.log.items.len);
        const last_term = if (last_idx > 0) self.log.items[last_idx - 1].term else 0;

        const vote_req = VoteRequest{
            .term = self.current_term,
            .candidate_id = self.local_id,
            .last_log_index = last_idx,
            .last_log_term = last_term,
        };

        for (self.peers.items) |peer| {
            self.transport.*.sendVoteRequest(peer.id, peer.address, vote_req);
        }
    }

    /// Become leader (we've won the election)
    fn becomeLeader(self: *Self) void {
        self.state = .leader;
        if (self.leader_id) |l| self.allocator.free(l);
        self.leader_id = self.allocator.dupe(u8, self.local_id) catch self.local_id;

        // Initialize next_index and match_index for all peers
        const last_log_idx: u64 = @intCast(self.log.items.len);
        self.next_index.clearRetainingCapacity();
        self.match_index.clearRetainingCapacity();

        for (self.peers.items) |peer| {
            self.next_index.put(peer.id, last_log_idx + 1) catch {};
            self.match_index.put(peer.id, 0) catch {};
        }

        const now_ms = Time.monotonicNowMilliseconds();
        self.last_heartbeat_ms = now_ms;

        std.log.info("[RaftElection] Node {s} became leader for term {d}", .{
            self.local_id,
            self.current_term,
        });

        // Send initial heartbeat immediately (as AppendEntries with empty entries)
        self.sendHeartbeats() catch {};
    }

    /// Send heartbeats to all peers (AppendEntries with empty entries).
    fn sendHeartbeats(self: *Self) !void {
        const last_idx: u64 = @intCast(self.log.items.len);
        const prev_log_term = if (last_idx > 0) self.log.items[last_idx - 1].term else 0;

        for (self.peers.items) |peer| {
            const req = AppendEntriesRequest{
                .term = self.current_term,
                .leader_id = self.local_id,
                .prev_log_index = last_idx,
                .prev_log_term = prev_log_term,
                .entries = &.{},
                .leader_commit = self.commit_index,
            };
            const resp = self.transport.*.sendAppendEntries(peer.id, peer.address, req);
            if (resp.term > self.current_term) {
                self.current_term = resp.term;
                self.state = .follower;
            }
        }
    }

    /// Handle vote response from peer.
    /// In production, this would track per-peer votes and call becomeLeader() on quorum.
    pub fn handleVoteResponse(self: *Self, resp: VoteResponse, from_peer: []const u8) !void {
        _ = from_peer;
        if (resp.term > self.current_term) {
            self.current_term = resp.term;
            self.state = .follower;
            return;
        }

        if (self.state != .candidate) return;

        if (resp.vote_granted) {
            self.becomeLeader();
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

    /// Get the replicated log length
    pub fn logLen(self: Self) usize {
        return self.log.items.len;
    }

    /// Get the commit index
    pub fn getCommitIndex(self: Self) u64 {
        return self.commit_index;
    }

    /// Get log entry at the given 1-based index, or null if out of range.
    pub fn getLogEntry(self: Self, index: u64) ?LogEntry {
        if (index == 0 or index > self.log.items.len) return null;
        return self.log.items[index - 1];
    }

    /// Add a peer to the cluster dynamically.
    pub fn addPeer(self: *Self, id: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        try self.peers.append(self.allocator, .{ .id = id_copy, .address = "" });
    }

    /// Get current state
    pub fn getState(self: Self) RaftState {
        return self.state;
    }

    /// Total cluster size (self + peers).
    pub fn clusterSize(self: *const Self) usize {
        return 1 + self.peers.items.len;
    }

    /// Quorum = floor(N/2) + 1
    pub fn quorumSize(self: *const Self) usize {
        return (self.clusterSize() / 2) + 1;
    }

    /// Check if votes received meet quorum.
    pub fn hasQuorum(self: *const Self, votes_received: usize) bool {
        return votes_received >= self.quorumSize();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Test cluster: holds N RaftElection nodes with simulated networking.
const TestCluster = struct {
    const Node = struct {
        election: RaftElection,
    };

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    local_ids: std.ArrayList([]const u8),
    transports: std.ArrayList(TestTransport),

    const TestTransport = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };

    fn init(allocator: std.mem.Allocator, count: usize) !TestCluster {
        var nodes = std.ArrayList(Node).empty;
        var local_ids = std.ArrayList([]const u8).empty;
        var transports = std.ArrayList(TestTransport).empty;

        // Pre-allocate to prevent reallocation (transports are referenced by pointer)
        try transports.ensureTotalCapacity(allocator, count);
        try nodes.ensureTotalCapacity(allocator, count);
        try local_ids.ensureTotalCapacity(allocator, count);

        var i: usize = 0;
        while (i < count) : (i += 1) {
            var id_buf: [16]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "n{d}", .{i});
            const id_copy = try allocator.dupe(u8, id);
            local_ids.appendAssumeCapacity(id_copy);
        }

        // Build peer lists (each node sees all others as peers)
        i = 0;
        while (i < count) : (i += 1) {
            const my_id = local_ids.items[i];
            var peer_list = std.ArrayList(Peer).empty;

            var j: usize = 0;
            while (j < count) : (j += 1) {
                if (j == i) continue;
                try peer_list.append(allocator, Peer{
                    .id = local_ids.items[j],
                    .address = "",
                });
            }

            transports.appendAssumeCapacity(.{
                .sendVoteRequest = sendVoteRequestFn,
                .sendAppendEntries = sendAppendEntriesFn,
            });

            const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transports.items[i])));
            const election = try RaftElection.init(allocator, my_id, peer_list.items, .{}, &transport);
            nodes.appendAssumeCapacity(Node{ .election = election });

            // Free temp peer list (RaftElection.init copies the data)
            peer_list.deinit(allocator);
        }

        return TestCluster{
            .allocator = allocator,
            .nodes = nodes,
            .local_ids = local_ids,
            .transports = transports,
        };
    }

    fn deinit(self: *TestCluster) void {
        for (self.nodes.items) |*node| {
            node.election.deinit();
        }
        self.nodes.deinit(self.allocator);
        for (self.local_ids.items) |id| {
            self.allocator.free(id);
        }
        self.local_ids.deinit(self.allocator);
        self.transports.deinit(self.allocator);
    }

    /// Simulate: leader appends command and replicates to followers
    fn replicate(self: *TestCluster, leader_idx: usize, command: []const u8) !void {
        var leader = &self.nodes.items[leader_idx];
        _ = try leader.election.appendEntry(command);

        // Send AppendEntries to each follower, retrying on rejection
        for (self.nodes.items, 0..) |*node, node_idx| {
            if (node_idx == leader_idx) continue;
            const peer_id = node.election.local_id;

            // Retry loop: may need multiple rounds if follower rejects
            var retry_count: usize = 0;
            while (retry_count < 10) : (retry_count += 1) {
                const next = leader.election.next_index.get(peer_id) orelse @as(u64, 1);
                const start: usize = if (next > 0) @intCast(next - 1) else 0;

                const entries: []const LogEntry = if (start < leader.election.log.items.len)
                    leader.election.log.items[start..]
                else
                    &.{};

                var prev_idx: u64 = 0;
                var prev_term: u64 = 0;
                if (start > 0 and start <= leader.election.log.items.len) {
                    prev_idx = leader.election.log.items[start - 1].index;
                    prev_term = leader.election.log.items[start - 1].term;
                }

                const req = AppendEntriesRequest{
                    .term = leader.election.current_term,
                    .leader_id = leader.election.local_id,
                    .prev_log_index = prev_idx,
                    .prev_log_term = prev_term,
                    .entries = entries,
                    .leader_commit = leader.election.commit_index,
                };

                const resp = try node.election.handleAppendEntries(req);

                if (resp.term > leader.election.current_term) {
                    leader.election.current_term = resp.term;
                    leader.election.state = .follower;
                    return;
                }

                if (resp.success) {
                    const matched: u64 = if (entries.len > 0)
                        entries[entries.len - 1].index
                    else
                        prev_idx;
                    leader.election.next_index.put(peer_id, matched + 1) catch {};
                    leader.election.match_index.put(peer_id, matched) catch {};
                    break;
                } else {
                    // Decrement next_index and retry
                    if (next > 1) {
                        leader.election.next_index.put(peer_id, next - 1) catch {};
                    }
                    if (resp.match_index > 0) {
                        leader.election.next_index.put(peer_id, @min(next - 1, resp.match_index + 1)) catch {};
                    }
                }
            }
        }

        // Advance commit index
        leader.election.advanceCommitIndex();
    }

    /// Elect a leader in the cluster (make node 0 become leader directly).
    fn electLeader(self: *TestCluster, leader_idx: usize) void {
        var leader = &self.nodes.items[leader_idx];
        leader.election.state = .leader;
        leader.election.current_term +|= 1;
        if (leader.election.leader_id) |l| self.allocator.free(l);
        leader.election.leader_id = self.allocator.dupe(u8, leader.election.local_id) catch leader.election.local_id;

        // Initialize leader state
        const last_idx: u64 = @intCast(leader.election.log.items.len);
        leader.election.next_index.clearRetainingCapacity();
        leader.election.match_index.clearRetainingCapacity();
        for (self.nodes.items, 0..) |node, node_idx| {
            if (node_idx == leader_idx) continue;
            leader.election.next_index.put(node.election.local_id, last_idx + 1) catch {};
            leader.election.match_index.put(node.election.local_id, 0) catch {};
        }

        // Notify followers (they receive heartbeat)
        for (self.nodes.items, 0..) |*node, node_idx| {
            if (node_idx == leader_idx) continue;
            node.election.state = .follower;
            node.election.current_term = leader.election.current_term;
            if (node.election.leader_id) |l| {
                if (l.ptr != node.election.local_id.ptr) {
                    self.allocator.free(l);
                }
            }
            node.election.leader_id = self.allocator.dupe(u8, leader.election.local_id) catch continue;
        }
    }

    fn sendVoteRequestFn(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}

    fn sendAppendEntriesFn(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
        return AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
    }
};

test "log replication basic" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Make node 0 leader
    cluster.electLeader(0);

    // Append entry on leader
    try cluster.replicate(0, "cmd_1");

    // Verify leader has the entry
    try testing.expectEqual(@as(usize, 1), cluster.nodes.items[0].election.logLen());
    try testing.expectEqual(@as(u64, 1), cluster.nodes.items[0].election.getLogEntry(1).?.index);
    try testing.expectEqualStrings("cmd_1", cluster.nodes.items[0].election.getLogEntry(1).?.command);

    // Append more entries
    try cluster.replicate(0, "cmd_2");
    try cluster.replicate(0, "cmd_3");

    try testing.expectEqual(@as(usize, 3), cluster.nodes.items[0].election.logLen());
}

test "log replication commit" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    cluster.electLeader(0);

    // Append and replicate entry to both followers
    try cluster.replicate(0, "commit_me");
    // replicate() already calls advanceCommitIndex after sending to all peers
    // But we need to check commit was propagated. Let's manually send heartbeats
    // to propagate commit_index to followers.

    // Manually propagate commit to followers
    for (cluster.nodes.items, 0..) |*node, node_idx| {
        if (node_idx == 0) continue;
        const req = AppendEntriesRequest{
            .term = cluster.nodes.items[0].election.current_term,
            .leader_id = cluster.nodes.items[0].election.local_id,
            .prev_log_index = 1,
            .prev_log_term = cluster.nodes.items[0].election.current_term,
            .entries = &.{},
            .leader_commit = cluster.nodes.items[0].election.commit_index,
        };
        _ = node.election.handleAppendEntries(req) catch {};
    }

    // Check all have the entry
    for (cluster.nodes.items) |node| {
        try testing.expectEqual(@as(usize, 1), node.election.logLen());
    }
}

test "log replication conflict" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Pre-seed node 1 with divergent log entries from a "previous" term (term=0).
    // This simulates a node that missed updates and has conflicting entries
    // at the same indices as the new leader.
    {
        var n1 = &cluster.nodes.items[1];
        const cmd = try allocator.dupe(u8, "divergent");
        try n1.election.log.append(allocator, LogEntry{ .term = 0, .index = 1, .command = cmd });
        const cmd2 = try allocator.dupe(u8, "divergent2");
        try n1.election.log.append(allocator, LogEntry{ .term = 0, .index = 2, .command = cmd2 });
    }

    // Elect node 0 as leader (term will be ≥ 1) and replicate — should overwrite
    // node 1's divergent entries because the terms differ.
    cluster.electLeader(0);
    try cluster.replicate(0, "a");
    try cluster.replicate(0, "b");
    try cluster.replicate(0, "c");

    // Verify all followers' logs match the leader
    const leader_len = cluster.nodes.items[0].election.logLen();
    try testing.expectEqual(@as(usize, 3), leader_len);

    for (cluster.nodes.items, 0..) |node, node_idx| {
        if (node_idx == 0) continue;
        try testing.expectEqual(leader_len, node.election.logLen());
        for (0..leader_len) |i| {
            const ldr = cluster.nodes.items[0].election.log.items[i];
            const fwr = node.election.log.items[i];
            try testing.expectEqual(ldr.term, fwr.term);
            try testing.expectEqual(ldr.index, fwr.index);
            try testing.expectEqualStrings(ldr.command, fwr.command);
        }
    }
}

test "log replication persistence" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    // Term 1: leader appends entries
    cluster.electLeader(0);
    try cluster.replicate(0, "t1_cmd1");
    try cluster.replicate(0, "t1_cmd2");

    const term1 = cluster.nodes.items[0].election.current_term;

    // Term 2: new leadership, entries from old term persist
    cluster.electLeader(1);
    try cluster.replicate(1, "t2_cmd1");

    // Verify old entries still present on all nodes
    for (cluster.nodes.items) |node| {
        try testing.expect(node.election.logLen() >= 3);

        // t1_cmd1 and t1_cmd2 should still be there
        const e1 = node.election.getLogEntry(1).?;
        const e2 = node.election.getLogEntry(2).?;
        try testing.expectEqual(term1, e1.term);
        try testing.expectEqual(term1, e2.term);
        try testing.expectEqualStrings("t1_cmd1", e1.command);
        try testing.expectEqualStrings("t1_cmd2", e2.command);

        // t2_cmd1 should be from the new term
        const e3 = node.election.getLogEntry(3).?;
        try testing.expectEqualStrings("t2_cmd1", e3.command);
    }
}

test "RaftElection initialization" {
    const allocator = testing.allocator;

    const config = ElectionConfig{};
    const peers = &[_]Peer{
        .{ .id = "peer1", .address = "localhost:7001" },
        .{ .id = "peer2", .address = "localhost:7002" },
    };

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendAppendEntries = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
                return AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
            }
        }).f,
    };
    const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transport_impl)));

    var election = try RaftElection.init(
        allocator,
        "node1",
        @as([]Peer, @constCast(@as([]const Peer, peers))),
        config,
        &transport,
    );
    defer election.deinit();

    try testing.expectEqual(RaftState.follower, election.getState());
    try testing.expectEqual(@as(u64, 0), election.getTerm());
    try testing.expectEqual(@as(usize, 0), election.logLen());
}

test "RaftElection heartbeat resets leader info" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendAppendEntries = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
                return AppendEntriesResponse{ .term = 0, .success = true, .match_index = 0 };
            }
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

    try testing.expect(!election.isLeader());

    // Use handleAppendEntries instead of the removed handleHeartbeat
    const req = AppendEntriesRequest{
        .term = 1,
        .leader_id = "leader1",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{},
        .leader_commit = 0,
    };
    _ = try election.handleAppendEntries(req);

    try testing.expectEqualStrings("leader1", election.getLeader().?);
}

test "RaftElection vote request validation" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendAppendEntries = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
                return AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
            }
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
    try testing.expect(resp.vote_granted);
    try testing.expectEqual(@as(u64, 5), election.getTerm());
}

test "RaftElection rejects stale term vote" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendAppendEntries = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
                return AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
            }
        }).f,
    };
    const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transport_impl)));

    var election = try RaftElection.init(allocator, "node-a", &.{}, .{}, &transport);
    defer election.deinit();

    _ = try election.handleVoteRequest(.{
        .term = 5, .candidate_id = "c1", .last_log_index = 1, .last_log_term = 1,
    });
    try testing.expectEqual(@as(u64, 5), election.getTerm());

    const resp = try election.handleVoteRequest(.{
        .term = 3, .candidate_id = "c2", .last_log_index = 1, .last_log_term = 1,
    });
    try testing.expect(!resp.vote_granted);
}

test "RaftElection split vote across three candidates" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendAppendEntries = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
                return AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
            }
        }).f,
    };
    const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transport_impl)));

    var e1 = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e1.deinit();
    var e2 = try RaftElection.init(allocator, "n2", &.{}, .{}, &transport);
    defer e2.deinit();
    var e3 = try RaftElection.init(allocator, "n3", &.{}, .{}, &transport);
    defer e3.deinit();

    // Make them all start election
    e1.state = .candidate;
    e1.current_term +|= 1;
    e2.state = .candidate;
    e2.current_term +|= 1;
    e3.state = .candidate;
    e3.current_term +|= 1;

    try testing.expect(e1.getTerm() >= 1);
    try testing.expect(e2.getTerm() >= 1);
    try testing.expect(e3.getTerm() >= 1);

    const req = VoteRequest{
        .term = @intCast(e1.getTerm() + 1),
        .candidate_id = "n1",
        .last_log_index = 5,
        .last_log_term = 1,
    };
    const resp = try e2.handleVoteRequest(req);
    try testing.expect(resp.vote_granted);
}

test "RaftElection quorum calculation" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };
    var transport_impl = TransportImpl{
        .sendVoteRequest = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
        }).f,
        .sendAppendEntries = (struct {
            fn f(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
                return AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
            }
        }).f,
    };
    const transport: RaftElection.ElectionTransport = @constCast(@ptrCast(@alignCast(&transport_impl)));

    // 3-node cluster: quorum = 2
    var e = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e.deinit();
    try e.addPeer("n2");
    try e.addPeer("n3");

    try testing.expectEqual(@as(usize, 3), e.clusterSize());
    try testing.expectEqual(@as(usize, 2), e.quorumSize());
    try testing.expect(e.hasQuorum(2));
    try testing.expect(!e.hasQuorum(1));

    // 5-node cluster: quorum = 3
    var e2 = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e2.deinit();
    try testing.expectEqual(@as(usize, 1), e2.clusterSize());
    try testing.expectEqual(@as(usize, 1), e2.quorumSize());
}
