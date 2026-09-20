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

/// Spin lock guarding a `RaftElection`'s state.
///
/// The algorithm's entry points are driven from two threads in the documented
/// wiring (`docs/DISTRIBUTED.md`): the app's tick loop calls `tick()`, while the
/// node's accept thread dispatches peers' RPCs into `handleVoteRequest` /
/// `handleAppendEntries` / … Both streams free-then-restore `voted_for` and
/// `leader_id`, push into and truncate `log`, and rewrite `next_index` /
/// `match_index` — so every public entry point that touches that state takes
/// this lock for its whole body, instead of leaving it to the caller to
/// remember which pairs of calls must not overlap. The interleave it exists to
/// stop is a process ABRT: `double free of [addr: …, len: 9]` out of
/// `handleVoteRequest` racing `startElection`.
///
/// A spin lock rather than `std.Io.Mutex`: what is guarded is a handful of
/// in-memory field updates on a state machine that ticks at heartbeat rates,
/// and the inbound accept thread is an OS thread spawned outside the `io`'s own
/// pool — the same reason `scheduler.zig` coordinates its pool threads with
/// atomics.
///
/// Deliberately **not** covered: `deinit` (terminal, see its doc), and
/// `clusterSize` / `quorumSize` / `hasQuorum`, which read only the membership
/// and are called from *inside* the locked bodies.
pub const RaftLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn acquire(self: *RaftLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn release(self: *RaftLock) void {
        self.flag.store(false, .release);
    }

    /// True while some thread is inside a locked entry point. Lock-free, and
    /// read by this file's own regression test to tell "the lock serialized the
    /// two windows" from "the two windows really did overlap".
    pub fn isHeld(self: *const RaftLock) bool {
        return self.flag.load(.acquire);
    }
};

/// Configuration for Raft
pub const ElectionConfig = struct {
    /// Minimum election timeout (ms)
    election_timeout_min_ms: u64 = 150,

    /// Maximum election timeout (ms)
    election_timeout_max_ms: u64 = 300,

    /// Heartbeat interval (ms) - leader sends heartbeats at this rate
    heartbeat_interval_ms: u64 = 50,

    /// Maximum entries to send in one AppendEntries RPC. A lagging follower is
    /// fed its backlog in chunks of this size; values below 1 are read as 1.
    max_append_entries: usize = 100,

    /// How long an outbound Raft RPC may take before it is written off as a lost
    /// message (which Raft re-sends — see `RaftTransport`: every failure mode is
    /// the same "lost message" answer, never a panic).
    ///
    /// This is a **liveness bound, not a tuning knob**, and the reason is the
    /// shape of the driver: `tick()` performs its outbound round while holding
    /// `RaftLock`, which is a *spin* lock, so a peer that never answers does not
    /// merely delay the round — it has every other thread that wants the state
    /// (the accept thread's inbound RPCs, `appendEntry`, the accessors) burning a
    /// core on `spinLoopHint` for as long as the RPC waits. Before this field
    /// existed the wait was the OS default: a black-holed peer (SYN dropped, or a
    /// connection accepted and never answered) cost the node *minutes*.
    ///
    /// With it, the cost of an unreachable peer is this number **per peer per
    /// round**. Keep it comfortably under `election_timeout_min_ms`: past that
    /// point the round has already missed its own heartbeat, so a larger value
    /// buys nothing but a longer stall. Raise it for a WAN whose RTTs approach
    /// the default — a slow-but-reachable peer now gets its reply written off as
    /// lost instead of being waited for. 0 disables the bound (the pre-fix
    /// behaviour).
    rpc_timeout_ms: u32 = 100,

    /// Pre-shared key for the cluster port (docs/dev/cluster-auth-design.md).
    /// When set, every inbound Raft frame must carry a valid HMAC-SHA256 tag and
    /// every outbound one is signed. When null the frames are bare — which is why
    /// `ClusterBootstrap.start()` refuses a multi-node cluster without one.
    cluster_secret: ?[32]u8 = null,
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

/// InstallSnapshot RPC request (leader → follower)
pub const InstallSnapshotRequest = struct {
    term: u64,
    leader_id: []const u8,
    last_included_index: u64,
    last_included_term: u64,
    offset: u64,
    data: []const u8,
    done: bool,
};

/// InstallSnapshot RPC response (follower → leader)
pub const InstallSnapshotResponse = struct {
    term: u64,
};

/// Raft
///
/// Handles leader election and log replication within a Raft cluster.
pub const RaftElection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ElectionConfig,

    /// Serializes every entry point that touches the fields below — see
    /// `RaftLock` for why this lives here rather than in the caller. Held for
    /// the body of `tick` / `handle*` / `appendEntry` / `addPeer` /
    /// `compactLog` and by the state accessors; the private helpers they call
    /// (`startElection`, `sendHeartbeats`, …) assume it is already held.
    lock: RaftLock = .{},

    // Persistent state (would be persisted to disk in full Raft)
    current_term: u64 = 0,
    voted_for: ?[]const u8 = null,
    log: std.ArrayList(LogEntry),
    last_included_index: u64 = 0,
    last_included_term: u64 = 0,
    snapshot_data: ?[]const u8 = null,

    // Volatile state (all servers)
    state: RaftState = .follower,
    leader_id: ?[]const u8 = null,
    commit_index: u64 = 0,
    last_applied: u64 = 0,

    // Leader state (reinitialized after election)
    next_index: std.StringHashMap(u64),
    match_index: std.StringHashMap(u64),

    // Candidate state: ids of the peers that granted a vote in the current
    // term (keys borrowed from `peers`, so a repeated vote tallies once).
    votes_received: std.StringHashMap(void),

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
            .votes_received = std.StringHashMap(void).init(allocator),
            .local_id = local_id_copy,
            .peers = peers_copy,
            .transport = transport,
            .last_heartbeat_ms = now_ms,
            .election_deadline_ms = now_ms + @as(i64, @intCast(config.election_timeout_max_ms)),
        };
    }

    /// Release all resources.
    ///
    /// Terminal, and therefore not locked: the caller must already have stopped
    /// every other user of this raft (`ClusterBootstrap.stop()` joins the
    /// inbound thread before it gets here). Taking the lock would not make that
    /// true — it would only hide it, because the lock's own memory is what
    /// `self.* = undefined` poisons.
    pub fn deinit(self: *Self) void {
        // Free log entries (each owns its command string)
        for (self.log.items) |entry| {
            self.allocator.free(entry.command);
        }
        self.log.deinit(self.allocator);

        // Free leader state hashmaps (keys are borrowed from peers)
        self.next_index.deinit();
        self.match_index.deinit();
        self.votes_received.deinit();

        self.allocator.free(self.local_id);
        for (self.peers.items) |peer| {
            self.allocator.free(peer.id);
            self.allocator.free(peer.address);
        }
        self.peers.deinit(self.allocator);
        if (self.voted_for) |v| self.allocator.free(v);
        if (self.snapshot_data) |s| self.allocator.free(s);
        // leader_id may alias local_id (from becomeLeader); only free when they differ

        if (self.leader_id) |l| {
            if (l.ptr != self.local_id.ptr) {
                self.allocator.free(l);
            }
        }
        self.* = undefined;
    }

    /// Main tick function - called periodically.
    ///
    /// Holds `lock` for the whole step: this is one of the two entry points
    /// into the shared state (the other is the inbound RPC dispatch), and both
    /// branches reach a read-then-free of an owned string — `voted_for` via
    /// `startElection`, `leader_id` via `sendHeartbeats` — with no safe point
    /// in between.
    pub fn tick(self: *Self) !void {
        self.lock.acquire();
        defer self.lock.release();

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
    ///
    /// Holds `lock`: the append and the commit-index advance it triggers are one
    /// state transition, and `log` is what the inbound `handleAppendEntries` /
    /// `handleInstallSnapshot` truncate and clear.
    pub fn appendEntry(self: *Self, command: []const u8) !u64 {
        self.lock.acquire();
        defer self.lock.release();

        if (self.state != .leader) return error.NotLeader;

        const cmd_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(cmd_copy);

        const index: u64 = @intCast(self.log.items.len + 1);
        try self.log.append(self.allocator, LogEntry{
            .term = self.current_term,
            .index = index,
            .command = cmd_copy,
        });

        // A quorum may already hold this entry (in a one-node cluster the leader
        // *is* the quorum), and waiting for the next heartbeat tick would leave
        // the write uncommitted until then.
        self.advanceCommitIndex();
        return index;
    }

    /// Handle incoming vote request from a candidate.
    ///
    /// Holds `lock`: the body frees `voted_for` twice over (the higher-term
    /// reset and the granted vote) and dupe-replaces it between them — this is
    /// the read-then-free window whose interleave with `startElection` was a
    /// `double free of [addr: …]`.
    pub fn handleVoteRequest(self: *Self, req: VoteRequest) !VoteResponse {
        self.lock.acquire();
        defer self.lock.release();

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
                    // Allocate **before** freeing the old value. The previous order
                    // freed first and then `try`-duped, so a failed allocation left
                    // `voted_for` pointing at freed memory — which the guard two
                    // lines up (`voted_for == null or eql(...)`) and `deinit` both
                    // dereference.
                    const vote_copy = try self.allocator.dupe(u8, req.candidate_id);
                    if (self.voted_for) |v| self.allocator.free(v);
                    self.voted_for = vote_copy;
                }
            }
        }

        return VoteResponse{
            .term = self.current_term,
            .vote_granted = vote_granted,
        };
    }

    /// Follower handles incoming AppendEntries RPC from leader.
    ///
    /// Holds `lock`: the free-then-dupe of `leader_id`, the `truncateLog` /
    /// `log.append` sequence, and the commit-index advance all mutate state the
    /// ticker and the other RPC handlers read.
    pub fn handleAppendEntries(self: *Self, req: AppendEntriesRequest) !AppendEntriesResponse {
        self.lock.acquire();
        defer self.lock.release();

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

        // Update leader info. Allocate before freeing — same reason as
        // `handleVoteRequest`'s `voted_for`: freeing first leaves a dangling
        // `leader_id` on allocation failure, and `deinit` frees it again (and
        // `getLeader()` hands it out).
        const leader_copy = try self.allocator.dupe(u8, req.leader_id);
        if (self.leader_id) |l| self.allocator.free(l);
        self.leader_id = leader_copy;

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

        // A log index is **1-based**, and the loop below reads
        // `log.items[entry.index - 1]`. `entry.index == 0` is not a value that can
        // exist, and nothing on the decode side rejects it (`decodeAppendEntries`
        // copies the index straight off the wire), so an unauthenticated peer can
        // name it in a single frame. Measured with the guard removed, both build
        // shapes are bad and they are bad *differently*:
        //
        //   * Debug / ReleaseSafe — `entry.index - 1` is a runtime subtraction on
        //     a `u64`, so the overflow check fires first and aborts the process:
        //     `panic: integer overflow` → `signal ABRT`. One frame, no credential,
        //     and the node is gone.
        //   * ReleaseFast — no checks, so the subtraction wraps to
        //     0xFFFF_FFFF_FFFF_FFFF and the address arithmetic folds
        //     `items[that]` to `items.ptr - 32` — one `LogEntry`, measured, not a
        //     wild pointer, which is why it does not fault. The loop then compares
        //     an out-of-bounds `term` and, in a measured run, *accepted* the
        //     malformed entry: `handleAppendEntries` returned
        //     `.{ .success = true, .match_index = 2 }` for a log whose two entries
        //     are index 1 and index 0 — telling the leader that index 2 is
        //     replicated. That is a Raft state-machine safety violation, not just a
        //     crash.
        //
        // Note the guard `prev_log_index > 0` six lines above, and the same check in
        // `getLogEntry`: this loop was the one place that arithmetic was reached
        // without one. A missed check, not a convention.
        //
        // Rejected *before any log mutation*: the loop below truncates at
        // `entry.index - 1` and only then appends, so checking inside it would let
        // a malformed request delete committed entries on its way to failing.
        // (The raft-state writes above — term, follower state, deadline,
        // `leader_id` — have already happened by this point; that is the same
        // window every AppendEntries request gets, and losing an election round
        // is the recoverable outcome there.)
        for (req.entries) |entry| {
            if (entry.index == 0) return error.InvalidLogIndex;
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

    // ── Private helpers ─────────────────────────────────────────────────────
    //
    // Everything from here down (`sendAppendEntries`, `advanceCommitIndex`,
    // `truncateLog`, `startElection`, `becomeLeader`, `sendHeartbeats`,
    // `randomElectionTimeout`) is reachable only from the locked entry points
    // above and assumes `lock` is already held: they are steps *within* one
    // state transition, so taking it here would self-deadlock the spin lock
    // rather than add a safety margin.

    /// Leader sends AppendEntries to all peers with new log entries.
    fn sendAppendEntries(self: *Self) !void {
        for (self.peers.items) |peer| {
            const next_idx = self.next_index.get(peer.id) orelse blk: {
                // Initialize if missing
                const idx: u64 = @intCast(self.log.items.len + 1);
                self.next_index.put(peer.id, idx) catch continue;
                break :blk idx;
            };

            // Build entries slice: from (next_idx - 1) to end of log, capped so
            // a lagging follower is fed the log in `max_append_entries` chunks
            // instead of one RPC carrying everything. The following round picks
            // up where this one stopped (`next_index` = last entry sent + 1).
            const start: usize = if (next_idx > 0) @intCast(next_idx - 1) else 0;
            const pending: []const LogEntry = if (start < self.log.items.len)
                self.log.items[start..]
            else
                &.{};
            // A cap of 0 would ship empty rounds forever and never advance
            // `next_index`, so it is read as "one entry per round".
            const batch_max = @max(@as(usize, 1), self.config.max_append_entries);
            const entries: []const LogEntry = if (pending.len > batch_max)
                pending[0..batch_max]
            else
                pending;

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
                self.next_index.put(peer.id, matched + 1) catch |err| std.log.err("[RaftElection] next_index update failed: {}", .{err});
                self.match_index.put(peer.id, matched) catch |err| std.log.err("[RaftElection] match_index update failed: {}", .{err});
            } else {
                // Decrement next_index for fast backtracking
                if (next_idx > 1) {
                    self.next_index.put(peer.id, next_idx - 1) catch |err| std.log.err("[RaftElection] next_index backtrack failed: {}", .{err});
                }
                if (resp.match_index > 0) {
                    // Use follower's match_index hint for faster convergence
                    self.next_index.put(peer.id, @min(next_idx - 1, resp.match_index + 1)) catch |err| std.log.err("[RaftElection] next_index hint update failed: {}", .{err});
                }
            }
        }

        // Entries held by a quorum are committed (§5.3/§5.4); the next round
        // carries the new leader_commit to the followers.
        self.advanceCommitIndex();
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

    /// Start a new election.
    ///
    /// Tallying convention: `votes_received` counts **peer grants**, so a
    /// candidate needs `quorumSize()` distinct peers to answer (the convention
    /// `handleVoteResponse` and `hasQuorum` document). A cluster of one has no
    /// peer to ask — its own vote is the entire majority (`quorumSize() == 1`),
    /// so that election is won immediately instead of waiting for a ballot that
    /// can never arrive.
    fn startElection(self: *Self) !void {
        self.state = .candidate;
        self.current_term +|= 1;

        // Vote for self. Allocate before freeing: on failure the old order left
        // `voted_for` dangling, and `tick` retries elections, so the dangling value
        // would be read on the next round rather than at the point of failure.
        const vote_copy = try self.allocator.dupe(u8, self.local_id);
        if (self.voted_for) |v| self.allocator.free(v);
        self.voted_for = vote_copy;

        // New term, new tally: votes granted in earlier terms must not count.
        self.votes_received.clearRetainingCapacity();

        // Reset election deadline
        const now_ms = Time.monotonicNowMilliseconds();
        self.election_deadline_ms = now_ms + @as(i64, @intCast(self.randomElectionTimeout()));

        std.log.info("[RaftElection] Starting election for term {d}", .{self.current_term});

        if (self.clusterSize() == 1) {
            self.becomeLeader();
            return;
        }

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
        // Allocate before freeing: the old order freed `leader_id` first, so a
        // failed dupe left it dangling until the `catch` reassigned it.
        const leader_copy = self.allocator.dupe(u8, self.local_id) catch self.local_id;
        // Mirror `deinit`'s alias guard. After the `catch` above, `leader_id` **is**
        // `local_id`, so freeing it unconditionally frees `local_id` — and the next
        // election's dupe would then copy from freed memory, with `deinit` freeing
        // it a second time. `deinit` has had this guard (and this comment) all along;
        // `becomeLeader` did not, which is the same intent implemented twice.
        if (self.leader_id) |l| {
            if (l.ptr != self.local_id.ptr) self.allocator.free(l);
        }
        self.leader_id = leader_copy;

        // Initialize next_index and match_index for all peers
        const last_log_idx: u64 = @intCast(self.log.items.len);
        self.next_index.clearRetainingCapacity();
        self.match_index.clearRetainingCapacity();

        for (self.peers.items) |peer| {
            self.next_index.put(peer.id, last_log_idx + 1) catch |err| std.log.err("[RaftElection] next_index reset failed: {}", .{err});
            self.match_index.put(peer.id, 0) catch |err| std.log.err("[RaftElection] match_index reset failed: {}", .{err});
        }

        const now_ms = Time.monotonicNowMilliseconds();
        self.last_heartbeat_ms = now_ms;

        std.log.info("[RaftElection] Node {s} became leader for term {d}", .{
            self.local_id,
            self.current_term,
        });

        // Send initial heartbeat immediately (as AppendEntries with empty entries)
        self.sendHeartbeats() catch |err| std.log.err("[RaftElection] initial heartbeat failed: {}", .{err});
    }

    /// Send heartbeats to all peers. A heartbeat is the same per-peer
    /// AppendEntries round as replication: a caught-up follower receives empty
    /// entries with a `prev_log_*` it actually has, while a lagging follower
    /// rejects the probe and gets its `next_index` backed off one step per
    /// round until the logs line up and the missing entries flow —
    /// `config.max_append_entries` of them per round.
    fn sendHeartbeats(self: *Self) !void {
        try self.sendAppendEntries();
    }

    /// Handle a vote response from a peer. Granted votes are tallied per term
    /// and deduplicated by peer id; the candidate becomes leader only once the
    /// tally reaches `quorumSize()` (the same peer-vote convention
    /// `hasQuorum(votes_received)` documents). A cluster of one never gets here
    /// — `startElection` elects it on the self-vote alone.
    ///
    /// Holds `lock`: a tally that reaches quorum promotes the node mid-call
    /// (`becomeLeader` frees `leader_id` and resets the per-peer maps), and the
    /// term check it starts with is the same field the ticker writes.
    pub fn handleVoteResponse(self: *Self, resp: VoteResponse, from_peer: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        if (resp.term > self.current_term) {
            self.current_term = resp.term;
            self.state = .follower;
            self.votes_received.clearRetainingCapacity();
            return;
        }

        if (self.state != .candidate) return;
        if (resp.term < self.current_term) return; // ballot from a past election
        if (!resp.vote_granted) return;

        // Only configured cluster members count. The map key borrows the
        // peer's stored id, which outlives the (often arena-owned) `from_peer`.
        const peer_id = self.peerId(from_peer) orelse return;
        try self.votes_received.put(peer_id, {});

        if (@as(usize, self.votes_received.count()) >= self.quorumSize()) {
            self.becomeLeader();
        }
    }

    /// The stored id of the peer named `id`, or null when it is not a member.
    fn peerId(self: *const Self, id: []const u8) ?[]const u8 {
        for (self.peers.items) |peer| {
            if (std.mem.eql(u8, peer.id, id)) return peer.id;
        }
        return null;
    }

    /// Generate random election timeout
    fn randomElectionTimeout(self: *Self) u64 {
        // A degenerate window (min == max, or a max below min) must still yield a
        // timeout: `% 0` is a division-by-zero panic, and a timeout of 0 would
        // spin the election loop.
        if (self.config.election_timeout_max_ms <= self.config.election_timeout_min_ms) {
            return @max(@as(u64, 1), self.config.election_timeout_min_ms);
        }

        const range = self.config.election_timeout_max_ms - self.config.election_timeout_min_ms;
        const now = Time.monotonicNowMilliseconds();
        var rng = std.Random.DefaultPrng.init(@bitCast(now));
        return self.config.election_timeout_min_ms + rng.random().int(u64) % range;
    }

    // ── State accessors ─────────────────────────────────────────────────────
    //
    // These take `lock` too, and take `self` by pointer: a reader on the inbound
    // thread (or a request handler) must see a whole value rather than one a
    // writer is midway through. Each call is a single read, not a transaction —
    // a caller that needs several values to agree still has to arrange that
    // itself (the lock is not re-entrant, so it cannot hold it across two of
    // these).

    /// Check if this node is the leader
    pub fn isLeader(self: *Self) bool {
        self.lock.acquire();
        defer self.lock.release();
        return self.state == .leader;
    }

    /// Get current leader ID.
    ///
    /// The returned slice is owned by this raft and replaced by the next
    /// election / AppendEntries, so the lock covers the read, not the borrow:
    /// use it before the next call into this raft, like `getLogEntry`'s command.
    pub fn getLeader(self: *Self) ?[]const u8 {
        self.lock.acquire();
        defer self.lock.release();
        return self.leader_id;
    }

    /// Get current term
    pub fn getTerm(self: *Self) u64 {
        self.lock.acquire();
        defer self.lock.release();
        return self.current_term;
    }

    /// Get the replicated log length
    pub fn logLen(self: *Self) usize {
        self.lock.acquire();
        defer self.lock.release();
        return self.log.items.len;
    }

    /// Get the commit index
    pub fn getCommitIndex(self: *Self) u64 {
        self.lock.acquire();
        defer self.lock.release();
        return self.commit_index;
    }

    /// Get log entry at the given 1-based index, or null if out of range.
    ///
    /// The lock makes the lookup whole, but the returned entry's `command`
    /// borrows the log: it is valid only until the next call into this raft.
    pub fn getLogEntry(self: *Self, index: u64) ?LogEntry {
        self.lock.acquire();
        defer self.lock.release();
        if (index == 0 or index > self.log.items.len) return null;
        return self.log.items[index - 1];
    }

    /// Add a peer to the cluster dynamically. Holds `lock`: `peers` is what
    /// `clusterSize` / `quorumSize` count while elections are running.
    pub fn addPeer(self: *Self, id: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        try self.peers.append(self.allocator, .{ .id = id_copy, .address = "" });
    }

    /// Get current state
    /// Log compaction: Discard entries up to `up_to_index` and retain `snapshot_data`.
    ///
    /// Holds `lock`: it frees the entries it discards and compacts `log` under
    /// the readers of both.
    pub fn compactLog(self: *Self, up_to_index: u64, snapshot_bytes: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        if (up_to_index <= self.last_included_index) return;
        if (self.log.items.len == 0) return;

        var target_idx: ?usize = null;
        var target_term: u64 = 0;
        for (self.log.items, 0..) |entry, i| {
            if (entry.index == up_to_index) {
                target_idx = i;
                target_term = entry.term;
                break;
            }
        }

        const idx = target_idx orelse return error.IndexNotFound;

        // Allocate the snapshot **before touching anything**: this function frees the
        // compacted entries and shortens the log below, so a failed allocation after
        // that point used to leave a dangling `snapshot_data` *and* a half-compacted
        // log. `last_included_term` is held in a local for the same reason — the old
        // code assigned it during the search, i.e. before an allocation that could
        // still fail.
        const snap_copy = try self.allocator.dupe(u8, snapshot_bytes);
        self.last_included_term = target_term;

        // Free entries up to idx
        for (0..idx + 1) |i| {
            self.allocator.free(self.log.items[i].command);
        }

        const remaining = self.log.items.len - (idx + 1);
        if (remaining > 0) {
            std.mem.copyForwards(LogEntry, self.log.items[0..remaining], self.log.items[idx + 1 ..]);
        }
        self.log.items.len = remaining;

        self.last_included_index = up_to_index;

        if (self.snapshot_data) |s| self.allocator.free(s);
        self.snapshot_data = snap_copy;
    }

    /// Follower handles InstallSnapshot RPC from leader (§7 Log Compaction).
    pub fn handleInstallSnapshot(self: *Self, req: InstallSnapshotRequest) !InstallSnapshotResponse {
        self.lock.acquire();
        defer self.lock.release();

        if (req.term < self.current_term) {
            return InstallSnapshotResponse{ .term = self.current_term };
        }

        if (req.term > self.current_term) {
            self.current_term = req.term;
        }
        self.state = .follower;

        if (req.last_included_index > self.last_included_index) {
            // Allocate the snapshot **first**: everything below this line is
            // destructive (it frees every log entry and clears the log), so the old
            // order left a dangling `snapshot_data` *and* a wiped log when the dupe
            // failed — the node came back with no snapshot and no log.
            const snap_copy = try self.allocator.dupe(u8, req.data);

            // Free current log entries
            for (self.log.items) |entry| {
                self.allocator.free(entry.command);
            }
            self.log.clearRetainingCapacity();

            self.last_included_index = req.last_included_index;
            self.last_included_term = req.last_included_term;

            if (self.snapshot_data) |s| self.allocator.free(s);
            self.snapshot_data = snap_copy;

            self.commit_index = @max(self.commit_index, req.last_included_index);
            self.last_applied = @max(self.last_applied, req.last_included_index);
        }

        return InstallSnapshotResponse{ .term = self.current_term };
    }

    pub fn getState(self: *Self) RaftState {
        self.lock.acquire();
        defer self.lock.release();
        return self.state;
    }

    /// Total cluster size (self + peers).
    ///
    /// Lock-free on purpose: it reads only the membership, which `addPeer`
    /// grows before elections start, and the locked bodies call it themselves
    /// (`startElection`, `handleVoteResponse`) — a lock here would be a
    /// self-deadlock, not a safety margin.
    pub fn clusterSize(self: *const Self) usize {
        return 1 + self.peers.items.len;
    }

    /// Quorum = floor(N/2) + 1 — lock-free, see `clusterSize`.
    pub fn quorumSize(self: *const Self) usize {
        return (self.clusterSize() / 2) + 1;
    }

    /// Check if votes received meet quorum.
    ///
    /// `votes_received` is a count of **peer grants** — the candidate's own
    /// vote is not part of the tally, so a multi-node candidate needs
    /// `quorumSize()` peers behind it. A cluster of one never wins through this
    /// path: `startElection` elects it outright, since there is no peer whose
    /// ballot could ever arrive. Lock-free, see `clusterSize`.
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
    /// Stable storage for the `*const ElectionTransport` each raft holds —
    /// taking the address of a loop-local here would dangle after init.
    transport_refs: std.ArrayList(RaftElection.ElectionTransport),

    const TestTransport = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };

    fn init(allocator: std.mem.Allocator, count: usize) !TestCluster {
        var nodes = std.ArrayList(Node).empty;
        var local_ids = std.ArrayList([]const u8).empty;
        var transports = std.ArrayList(TestTransport).empty;
        var transport_refs = std.ArrayList(RaftElection.ElectionTransport).empty;

        // Pre-allocate to prevent reallocation (transports are referenced by pointer)
        try transports.ensureTotalCapacity(allocator, count);
        try transport_refs.ensureTotalCapacity(allocator, count);
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
            transport_refs.appendAssumeCapacity(@ptrCast(@alignCast(@constCast(&transports.items[i]))));

            const election = try RaftElection.init(allocator, my_id, peer_list.items, .{}, &transport_refs.items[i]);
            nodes.appendAssumeCapacity(Node{ .election = election });

            // Free temp peer list (RaftElection.init copies the data)
            peer_list.deinit(allocator);
        }

        return TestCluster{
            .allocator = allocator,
            .nodes = nodes,
            .local_ids = local_ids,
            .transports = transports,
            .transport_refs = transport_refs,
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
        self.transport_refs.deinit(self.allocator);
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
                    leader.election.next_index.put(peer_id, matched + 1) catch |err| std.log.err("[RaftElection] test next_index update failed: {}", .{err});
                    leader.election.match_index.put(peer_id, matched) catch |err| std.log.err("[RaftElection] test match_index update failed: {}", .{err});
                    break;
                } else {
                    // Decrement next_index and retry
                    if (next > 1) {
                        leader.election.next_index.put(peer_id, next - 1) catch |err| std.log.err("[RaftElection] test next_index backtrack failed: {}", .{err});
                    }
                    if (resp.match_index > 0) {
                        leader.election.next_index.put(peer_id, @min(next - 1, resp.match_index + 1)) catch |err| std.log.err("[RaftElection] test next_index hint update failed: {}", .{err});
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
            leader.election.next_index.put(node.election.local_id, last_idx + 1) catch |err| std.log.err("[RaftElection] test next_index reset failed: {}", .{err});
            leader.election.match_index.put(node.election.local_id, 0) catch |err| std.log.err("[RaftElection] test match_index reset failed: {}", .{err});
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
    for (cluster.nodes.items) |*node| {
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

    for (cluster.nodes.items, 0..) |*node, node_idx| {
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
    for (cluster.nodes.items) |*node| {
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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

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

// Verified red: removing the `entry.index == 0` guard makes this abort rather
// than fail an assertion, because the subtraction `entry.index - 1` is a
// runtime `u64` operation and its overflow check fires before the index is ever
// used — `panic: integer overflow`, `signal ABRT`, the whole test binary down.
// There is no assertion to fail first; the abort *is* the defect, and one frame
// from an unauthenticated peer reaches it. In ReleaseFast (no overflow check)
// the same request instead succeeds and reports `match_index = 2` — measured;
// see the guard's comment in `handleAppendEntries` for both shapes.
test "an AppendEntries entry with index 0 is refused before the log is touched" {
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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    var election = try RaftElection.init(allocator, "node1", &.{}, .{}, &transport);
    defer election.deinit();

    // Seed one entry the normal way, so the malformed request below has an index
    // it can plausibly claim to be following.
    const seeded = try election.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader1",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{.{ .term = 1, .index = 1, .command = "keep" }},
        .leader_commit = 1,
    });
    try testing.expect(seeded.success);
    try testing.expectEqual(@as(usize, 1), election.logLen());

    // `prev_log_index`/`prev_log_term` match entry 1, which is what routes this
    // past the §5.3 check and into the entry loop — the shape a real peer sends,
    // not an artificial one.
    try testing.expectError(error.InvalidLogIndex, election.handleAppendEntries(.{
        .term = 2,
        .leader_id = "leader1",
        .prev_log_index = 1,
        .prev_log_term = 1,
        .entries = &.{.{ .term = 2, .index = 0, .command = "boom" }},
        .leader_commit = 1,
    }));

    // The reason the guard sits *before* the loop: the loop truncates at
    // `entry.index - 1` first, so a check inside it would delete the entry above
    // on the way to failing.
    try testing.expectEqual(@as(usize, 1), election.logLen());
    try testing.expectEqualStrings("keep", election.getLogEntry(1).?.command);
}

// Verified red: restoring the free-then-`try dupe` order in `handleVoteRequest`
// makes this fail on `deinit` with the testing allocator reporting a **double
// free**. That is the only shape this defect can take: the stale pointer is never
// dereferenced on the failure path, so nothing asserts before `deinit` frees the
// same buffer a second time. The two assertions below pass either way — they are
// there to document what "intact" means, not to catch it.
test "a failed voted_for re-allocation leaves the old vote intact" {
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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    // Backed by `testing.allocator`, so a double free is reported rather than
    // silently reusing the block.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();

    var election = try RaftElection.init(allocator, "node1", &.{}, .{}, &transport);
    defer election.deinit();

    // 1. Grant a vote, so `voted_for` owns a buffer.
    const granted = try election.handleVoteRequest(.{
        .term = 1,
        .candidate_id = "c1",
        .last_log_index = 0,
        .last_log_term = 0,
    });
    try testing.expect(granted.vote_granted);
    try testing.expectEqualStrings("c1", election.voted_for.?);

    // 2. Repeat the *same* candidate: the grant path re-dupes (it replaces the vote
    //    when the incumbent is the same candidate), so this reaches the dupe.
    failing.fail_index = failing.alloc_index; // the next allocation fails
    try testing.expectError(error.OutOfMemory, election.handleVoteRequest(.{
        .term = 1,
        .candidate_id = "c1",
        .last_log_index = 0,
        .last_log_term = 0,
    }));
    try testing.expect(failing.has_induced_failure);

    // 3. The still-owned vote is what `deinit` frees — once.
    try testing.expectEqualStrings("c1", election.voted_for.?);
}

// Verified red: removing `becomeLeader`'s alias guard (the `l.ptr !=
// self.local_id.ptr` test, which `deinit` has had all along) makes this fail with a
// **double free** at `deinit`. A `panic`, not an assertion — the second
// `becomeLeader` frees `local_id` through the alias, dupes from the freed buffer,
// and `deinit` then frees `local_id` again.
test "a leader_id aliased onto local_id is not freed on the next election win" {
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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();

    var election = try RaftElection.init(allocator, "node1", &.{}, .{}, &transport);
    defer election.deinit();

    // 1. First win with the allocation failing: `becomeLeader` falls back to
    //    `local_id`, so the two now alias.
    failing.fail_index = failing.alloc_index;
    election.becomeLeader();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(election.local_id.ptr, election.leader_id.?.ptr);

    // 2. Win again with a working allocator. Pre-fix this freed `local_id` through
    //    the alias and then copied from the freed buffer.
    failing.fail_index = std.math.maxInt(usize);
    election.becomeLeader();
    try testing.expect(election.leader_id.?.ptr != election.local_id.ptr);
    try testing.expectEqualStrings("node1", election.leader_id.?);
    try testing.expectEqualStrings("node1", election.getLeader().?);
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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    var election = try RaftElection.init(allocator, "node-a", &.{}, .{}, &transport);
    defer election.deinit();

    _ = try election.handleVoteRequest(.{
        .term = 5,
        .candidate_id = "c1",
        .last_log_index = 1,
        .last_log_term = 1,
    });
    try testing.expectEqual(@as(u64, 5), election.getTerm());

    const resp = try election.handleVoteRequest(.{
        .term = 3,
        .candidate_id = "c2",
        .last_log_index = 1,
        .last_log_term = 1,
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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

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

test "RaftElection vote counting: leader only at quorum, duplicate and stale votes ignored" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    var cand = &cluster.nodes.items[0].election;

    // Become a candidate for term 1 (vote requests go to the stub transport).
    try cand.startElection();
    try testing.expectEqual(RaftState.candidate, cand.getState());
    try testing.expectEqual(@as(u64, 1), cand.getTerm());

    // A ballot from an older term must not count.
    try cand.handleVoteResponse(.{ .term = 0, .vote_granted = true }, "n1");
    try testing.expect(!cand.isLeader());

    // First granted vote: 1 peer vote < quorum(2) — must NOT become leader.
    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = true }, "n1");
    try testing.expect(!cand.isLeader());
    try testing.expectEqual(RaftState.candidate, cand.getState());

    // A duplicate vote from the same peer is tallied once.
    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = true }, "n1");
    try testing.expect(!cand.isLeader());

    // Votes from non-members do not count.
    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = true }, "n9");
    try testing.expect(!cand.isLeader());

    // A rejection changes nothing.
    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = false }, "n2");
    try testing.expect(!cand.isLeader());

    // Second distinct peer vote reaches quorum → leader.
    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = true }, "n2");
    try testing.expect(cand.isLeader());
    try testing.expectEqual(@as(u64, 1), cand.getTerm());

    // A higher-term response steps the node back down to follower.
    try cand.handleVoteResponse(.{ .term = 2, .vote_granted = false }, "n1");
    try testing.expectEqual(RaftState.follower, cand.getState());
    try testing.expectEqual(@as(u64, 2), cand.getTerm());

    // The next election starts from a clean tally: one peer vote is, again,
    // not enough on its own.
    try cand.startElection();
    try testing.expectEqual(@as(u64, 3), cand.getTerm());
    try cand.handleVoteResponse(.{ .term = 3, .vote_granted = true }, "n1");
    try testing.expect(!cand.isLeader());
}

test "RaftElection log compaction and InstallSnapshot" {
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
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    var raft = try RaftElection.init(allocator, "node-1", &.{}, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;

    _ = try raft.appendEntry("cmd1");
    _ = try raft.appendEntry("cmd2");
    _ = try raft.appendEntry("cmd3");

    try testing.expectEqual(@as(usize, 3), raft.log.items.len);

    // Compact log up to index 2
    try raft.compactLog(2, "snapshot-payload-at-2");

    try testing.expectEqual(@as(u64, 2), raft.last_included_index);
    try testing.expectEqual(@as(usize, 1), raft.log.items.len);
    try testing.expectEqualStrings("snapshot-payload-at-2", raft.snapshot_data.?);

    // Follower handle InstallSnapshot
    var follower = try RaftElection.init(allocator, "node-2", &.{}, .{}, &transport);
    defer follower.deinit();

    const snap_req = InstallSnapshotRequest{
        .term = 1,
        .leader_id = "node-1",
        .last_included_index = 10,
        .last_included_term = 1,
        .offset = 0,
        .data = "follower-snapshot-data",
        .done = true,
    };

    const snap_resp = try follower.handleInstallSnapshot(snap_req);
    try testing.expectEqual(@as(u64, 1), snap_resp.term);
    try testing.expectEqual(@as(u64, 10), follower.last_included_index);
    try testing.expectEqualStrings("follower-snapshot-data", follower.snapshot_data.?);
}

/// Shape of `RaftElection.ElectionTransport`, restated at file scope so the
/// tests below can build transports out of named helper functions.
const TestTransportVTable = struct {
    sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
    sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
};

fn noopVoteRequest(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}

/// Records what a peer was handed, and accepts it.
const AppendEntriesCapture = struct {
    var calls: usize = 0;
    var entries_len: usize = 0;
    var first_index: u64 = 0;
    var last_index: u64 = 0;

    fn reset() void {
        calls = 0;
        entries_len = 0;
        first_index = 0;
        last_index = 0;
    }

    fn accept(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
        calls += 1;
        entries_len = req.entries.len;
        first_index = if (req.entries.len > 0) req.entries[0].index else 0;
        last_index = if (req.entries.len > 0) req.entries[req.entries.len - 1].index else req.prev_log_index;
        return .{ .term = req.term, .success = true, .match_index = last_index };
    }
};

/// Answers with a higher term, which makes the leader step down inside
/// `sendAppendEntries` before it can touch `next_index` / `match_index` — so
/// whatever `becomeLeader` wrote into those maps stays observable.
fn higherTermAppendEntries(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
    return .{ .term = req.term +| 1, .success = false, .match_index = 0 };
}

test "RaftElection single-node cluster elects itself on the first tick" {
    const allocator = testing.allocator;
    AppendEntriesCapture.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendEntriesCapture.accept,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var raft = try RaftElection.init(allocator, "solo", &.{}, .{}, &transport);
    defer raft.deinit();

    try testing.expectEqual(@as(usize, 1), raft.clusterSize());
    try testing.expectEqual(@as(usize, 1), raft.quorumSize());
    try testing.expectEqual(RaftState.follower, raft.getState());

    // No peer will ever answer a vote request, so the self-vote has to be the
    // whole majority: the first elapsed election deadline must elect this node.
    raft.election_deadline_ms = Time.monotonicNowMilliseconds() - 1;
    try raft.tick();

    try testing.expect(raft.isLeader());
    try testing.expectEqual(RaftState.leader, raft.getState());
    try testing.expectEqual(@as(u64, 1), raft.getTerm());
    try testing.expectEqualStrings("solo", raft.getLeader().?);
    try testing.expectEqualStrings("solo", raft.voted_for.?);

    // The leader is the entire quorum, so the append is committed on the spot
    // rather than waiting for a heartbeat round with nobody to send it to.
    try testing.expectEqual(@as(u64, 1), try raft.appendEntry("only-writer"));
    try testing.expectEqual(@as(u64, 1), raft.getCommitIndex());

    // A leader tick with no peers is still a heartbeat round: it must neither
    // reach the transport nor cost the node its leadership.
    raft.last_heartbeat_ms = Time.monotonicNowMilliseconds() - 1000;
    try raft.tick();
    try testing.expect(raft.isLeader());
    try testing.expectEqual(@as(u64, 1), raft.getCommitIndex());
    try testing.expectEqual(@as(usize, 0), AppendEntriesCapture.calls);
}

test "RaftElection three-node candidate needs two peer grants, not its self-vote" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    const cand = &cluster.nodes.items[0].election;

    // `startElection` votes for itself and polls n1/n2 through the stub
    // transport. The self-vote is not a peer grant, so the node stays a
    // candidate: a 3-node cluster is only won with 2 of 3 votes.
    try cand.startElection();
    try testing.expectEqual(RaftState.candidate, cand.getState());
    try testing.expect(!cand.isLeader());
    try testing.expectEqual(@as(usize, 3), cand.clusterSize());
    try testing.expectEqual(@as(usize, 2), cand.quorumSize());

    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = true }, "n1");
    try testing.expect(!cand.isLeader());

    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = true }, "n2");
    try testing.expect(cand.isLeader());
    try testing.expectEqual(RaftState.leader, cand.getState());
}

test "RaftElection caps each replication round at max_append_entries" {
    const allocator = testing.allocator;
    AppendEntriesCapture.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendEntriesCapture.accept,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{ .max_append_entries = 4 }, &transport);
    defer raft.deinit();

    raft.state = .leader;
    raft.current_term = 1;
    for (0..10) |i| {
        var buf: [16]u8 = undefined;
        _ = try raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    try testing.expectEqual(@as(usize, 10), raft.logLen());

    const peer_key = raft.peers.items[0].id;
    try raft.next_index.put(peer_key, 1);
    try raft.match_index.put(peer_key, 0);

    // Round 1: the first four entries, not the whole 10-entry log.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 1), AppendEntriesCapture.calls);
    try testing.expectEqual(@as(usize, 4), AppendEntriesCapture.entries_len);
    try testing.expectEqual(@as(u64, 1), AppendEntriesCapture.first_index);
    try testing.expectEqual(@as(u64, 4), AppendEntriesCapture.last_index);
    try testing.expectEqual(@as(u64, 5), raft.next_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 4), raft.getCommitIndex());

    // Round 2: continues where round 1 stopped.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 4), AppendEntriesCapture.entries_len);
    try testing.expectEqual(@as(u64, 5), AppendEntriesCapture.first_index);
    try testing.expectEqual(@as(u64, 8), AppendEntriesCapture.last_index);
    try testing.expectEqual(@as(u64, 9), raft.next_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 8), raft.getCommitIndex());

    // Round 3: the short tail, still within the cap.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 2), AppendEntriesCapture.entries_len);
    try testing.expectEqual(@as(u64, 9), AppendEntriesCapture.first_index);
    try testing.expectEqual(@as(u64, 10), AppendEntriesCapture.last_index);
    try testing.expectEqual(@as(u64, 11), raft.next_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 10), raft.getCommitIndex());

    // Round 4: nothing left → an empty probe that leaves the log untouched.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 0), AppendEntriesCapture.entries_len);
    try testing.expectEqual(@as(u64, 10), AppendEntriesCapture.last_index);
    try testing.expectEqual(@as(usize, 10), raft.logLen());
    try testing.expectEqual(@as(u64, 11), raft.next_index.get(peer_key).?);
}

test "RaftElection becomeLeader reinitializes per-peer next_index and match_index" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = higherTermAppendEntries,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{
        .{ .id = "n1", .address = "" },
        .{ .id = "n2", .address = "" },
    };
    var raft = try RaftElection.init(allocator, "n0", &peers, .{}, &transport);
    defer raft.deinit();

    // Stale bookkeeping from an earlier term must not survive the promotion.
    try raft.next_index.put(raft.peers.items[0].id, 1);
    try raft.match_index.put(raft.peers.items[0].id, 7);

    raft.state = .leader;
    raft.current_term = 1;
    _ = try raft.appendEntry("a");
    _ = try raft.appendEntry("b");
    _ = try raft.appendEntry("c");

    raft.becomeLeader();

    // The probe answered with a higher term, so the new leader stepped back down
    // before its heartbeat could rewrite the maps — which is what makes
    // `becomeLeader`'s own initialization observable: next_index = last log
    // index + 1, match_index = 0 for every peer.
    try testing.expectEqual(RaftState.follower, raft.getState());
    try testing.expectEqual(@as(u64, 2), raft.getTerm());
    for (raft.peers.items) |peer| {
        try testing.expectEqual(@as(u64, 4), raft.next_index.get(peer.id).?);
        try testing.expectEqual(@as(u64, 0), raft.match_index.get(peer.id).?);
    }
}

test "RaftElection leader commits an append only once a quorum replicates it" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    cluster.electLeader(0);
    const leader = &cluster.nodes.items[0].election;

    // `appendEntry` tries to commit immediately, and in a 3-node cluster the
    // leader alone is not a quorum: the entry stays uncommitted until the
    // followers hold it too.
    _ = try leader.appendEntry("unreplicated");
    try testing.expectEqual(@as(u64, 0), leader.getCommitIndex());

    try cluster.replicate(0, "replicated");
    try testing.expectEqual(@as(u64, 2), leader.getCommitIndex());
}

test "RaftElection degenerate election timeout window still schedules an election" {
    const allocator = testing.allocator;
    AppendEntriesCapture.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendEntriesCapture.accept,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    // min == max used to reach `x % 0` inside `randomElectionTimeout`: a
    // division-by-zero panic on the first elapsed election deadline.
    var peers = [_]Peer{.{ .id = "n1", .address = "" }};
    var raft = try RaftElection.init(allocator, "n0", &peers, .{
        .election_timeout_min_ms = 120,
        .election_timeout_max_ms = 120,
    }, &transport);
    defer raft.deinit();

    const before = Time.monotonicNowMilliseconds();
    raft.election_deadline_ms = before - 1;
    try raft.tick();

    try testing.expectEqual(RaftState.candidate, raft.getState());
    try testing.expectEqual(@as(u64, 1), raft.getTerm());
    // The window is one value wide, so the new deadline is exactly that far out.
    try testing.expect(raft.election_deadline_ms >= before + 120);
}

// ── The lock's regression test ──────────────────────────────────────────────

/// The round's start line: both threads arrive before either proceeds.
///
/// Beyond aligning the two windows, this is what makes the test's own
/// pre-barrier work (the ticker's `election_deadline_ms` write, which takes the
/// same lock) happen-before *both* windows of the round — so the rendezvous
/// below can never be released by that write, only by the lock's own
/// serialization.
const RoundBarrier = struct {
    arrivals: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    generation: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn wait(self: *RoundBarrier) void {
        const generation = self.generation.load(.acquire);
        if (self.arrivals.fetchAdd(1, .acq_rel) + 1 == 2) {
            self.arrivals.store(0, .release);
            self.generation.store(generation + 1, .release);
            return;
        }
        while (self.generation.load(.acquire) == generation) std.atomic.spinLoopHint();
    }
};

/// `std.testing.allocator` plus a rendezvous on the one buffer both drivers of
/// a `RaftElection` free: `startElection` reads `voted_for`, frees it and dupes
/// the self-vote; `handleVoteRequest` does the same with a peer's id. Under the
/// lock only one of them is between those two steps at a time, so each free of
/// a given buffer is the only one there is. Without the lock both threads read
/// the same pointer, and one of the frees is a double free.
///
/// This factor turns that interleave into a certainty instead of a probability:
/// the first free of the watched buffer *holds the window open* until a second
/// thread arrives at it, which is precisely "two threads were in the window at
/// once" — and the two frees then follow. Nothing here sleeps or times out: a
/// window that the lock has serialized is entered by the thread that holds the
/// lock, so `lock.isHeld()` is the state answer to "there is no second thread
/// to wait for".
///
/// `waiting` rather than a visit counter decides who waits, so the allocator
/// handing the same address back for a later round's `voted_for` is not
/// mistaken for an overlap.
const WindowGate = struct {
    backing: std.mem.Allocator,
    /// Address of the `voted_for` buffer the first round's windows free.
    watched: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// The raft's lock: the release condition for a serialized window.
    lock: ?*const RaftLock = null,
    /// Some thread is inside the window, waiting for a second one.
    waiting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// A second thread reached the window while the first was still inside it:
    /// the handshake for that first thread, and the failure this test asserts
    /// against (the double free it leads to aborts before the assertion).
    overlapped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// How many times the watched address was freed — the test asserts the
    /// rendezvous was walked at all, so it cannot pass on a build that never
    /// reaches the window.
    freed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn allocator(self: *WindowGate) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Stop watching: `deinit`'s frees run outside any window (nothing holds the
    /// lock then), so they must not enter the rendezvous.
    fn disarm(self: *WindowGate) void {
        self.watched.store(0, .release);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *WindowGate = @ptrCast(@alignCast(ctx));
        return self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *WindowGate = @ptrCast(@alignCast(ctx));
        return self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *WindowGate = @ptrCast(@alignCast(ctx));
        return self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *WindowGate = @ptrCast(@alignCast(ctx));
        self.enterWindow(memory.ptr);
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
    }

    fn enterWindow(self: *WindowGate, ptr: [*]u8) void {
        if (@intFromPtr(ptr) != self.watched.load(.acquire)) return;
        _ = self.freed.fetchAdd(1, .monotonic);

        if (self.waiting.swap(true, .acq_rel)) {
            self.overlapped.store(true, .release);
            return;
        }

        while (!self.overlapped.load(.acquire)) {
            if (self.lock) |lock| if (lock.isHeld()) break;
            std.atomic.spinLoopHint();
        }
        self.waiting.store(false, .release);
    }
};

/// The app's thread: one `tick()` per round, with the election deadline forced
/// so the tick takes the `startElection` branch (the read-then-free of
/// `voted_for`) instead of the heartbeat one.
fn driveTicker(raft: *RaftElection, barrier: *RoundBarrier, rounds: usize) void {
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        {
            raft.lock.acquire();
            defer raft.lock.release();
            raft.election_deadline_ms = 0;
        }
        barrier.wait();
        raft.tick() catch |err| std.debug.panic("[raft test] tick: {s}", .{@errorName(err)});
    }
}

/// The accept thread's half: one dispatched RPC per round, alternating the vote
/// request (whose grant path frees and replaces `voted_for`) with AppendEntries
/// (whose path frees and replaces `leader_id`).
///
/// Terms step by two while the ticker's advance by one per round, so every
/// request is above the ticker's term — without that the handler would take its
/// early-return branch and never reach the window. No accessor is read here on
/// purpose: nothing but the window may touch the lock, or the rendezvous would
/// find it held for an unrelated reason.
fn driveRpc(raft: *RaftElection, barrier: *RoundBarrier, rounds: usize) void {
    var term: u64 = 3;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        barrier.wait();
        if (round % 2 == 0) {
            _ = raft.handleVoteRequest(.{
                .term = term,
                .candidate_id = "peer-b",
                .last_log_index = 0,
                .last_log_term = 0,
            }) catch |err| std.debug.panic("[raft test] vote request: {s}", .{@errorName(err)});
        } else {
            _ = raft.handleAppendEntries(.{
                .term = term,
                .leader_id = "peer-b",
                .prev_log_index = 0,
                .prev_log_term = 0,
                .entries = &.{},
                .leader_commit = 0,
            }) catch |err| std.debug.panic("[raft test] append entries: {s}", .{@errorName(err)});
        }
        term +|= 2;
    }
}

test "RaftElection: a tick and an inbound RPC cannot both free voted_for" {
    const allocator = testing.allocator;
    const rounds = 2000;

    AppendEntriesCapture.reset();
    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendEntriesCapture.accept,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var gate = WindowGate{ .backing = allocator };
    // A cluster of one: `startElection` elects this node on the self-vote, so a
    // round needs no peer and no wire — what is under test is the two threads,
    // not the transport.
    var raft = try RaftElection.init(gate.allocator(), "node-a", &.{}, .{}, &transport);
    defer raft.deinit();
    // Runs before the `deinit()` above (defers unwind LIFO): its frees are the
    // only ones outside a window, and a rendezvous there would have no partner.
    defer gate.disarm();
    gate.lock = &raft.lock;

    // Seed `voted_for` with the buffer the first round's two windows free: a
    // granted vote for a peer, which the ticker's self-vote replaces.
    _ = try raft.handleVoteRequest(.{
        .term = 1,
        .candidate_id = "peer-a",
        .last_log_index = 0,
        .last_log_term = 0,
    });
    gate.watched.store(@intFromPtr(raft.voted_for.?.ptr), .release);

    var barrier = RoundBarrier{};
    const ticker = try std.Thread.spawn(.{}, driveTicker, .{ &raft, &barrier, rounds });
    const responder = try std.Thread.spawn(.{}, driveRpc, .{ &raft, &barrier, rounds });
    ticker.join();
    responder.join();

    // The rendezvous was walked: a build that never reached the window (say,
    // one whose tick stopped electing) cannot pass this test by doing nothing.
    try testing.expect(gate.freed.load(.acquire) >= 1);
    // Two threads inside the window at once is what the lock forbids. When it
    // happens anyway the double free aborts the run first; this is the
    // assertion-shaped half of the same evidence.
    try testing.expect(!gate.overlapped.load(.acquire));

    // `voted_for` still points at a live buffer holding one of the two ids a
    // whole window can have written — not one freed underneath its owner.
    const voted = raft.voted_for orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.eql(u8, voted, "node-a") or std.mem.eql(u8, voted, "peer-a") or std.mem.eql(u8, voted, "peer-b"));
    // ...and both drivers advanced their own state, so the rounds were not
    // vacuous: the ticker kept electing, the responder kept forcing terms.
    try testing.expect(raft.getTerm() >= 2);
    // Neither driver appends a command, so any entry here would be a write the
    // other thread made out of the interleave.
    try testing.expectEqual(@as(usize, 0), raft.logLen());
}

// The positive control for the rendezvous above — the half that was missing.
//
// The test above shows the lock *prevents* an overlap. In a healthy build that
// is nearly a tautology: mutual exclusion means the two windows cannot be
// entered at once, so `overlapped` cannot become true, and the assertion can
// only fail on a build where the lock is gone. What said the detector *would*
// fire was a manual experiment — delete the lock, watch 6 of 12 seeds abort —
// which lived nowhere in the repo, so nobody could tell whether the guard still
// had teeth.
//
// Here the gate is driven directly, by two threads, and the two halves differ in
// exactly one thing: whether the entry takes the lock. That difference *is* the
// regression the test above guards, isolated down to the mechanism, with no
// allocator, no raft and no sleep — and with no probability in it, because in
// the first half the first thread has nothing left to break out on and therefore
// *must* wait for the second.
//
// Verified red (the whole point of this test existing): giving the first half's
// entry a release condition — a lock the test holds, with the gate pointed at it
// — turns `expect(overlapped)` red. That is what says the assertion tells the two
// states apart rather than holding no matter what. The second half is the
// stability question, and it does not depend on how the two threads interleave:
// the false-returning `swap` cannot leave the window before the true-returning
// one arrives, so the outcome is one of two mirror images and nothing else.
test "RaftElection: the window rendezvous fires iff nothing serializes the entry" {
    // The gate watches one address, and entering the protocol means naming it.
    const watched: usize = 0x1234;

    const Drivers = struct {
        /// No lock: the state of the world the test above is supposed to detect
        /// (a mutator that no longer takes it).
        fn enterFree(g: *WindowGate, ptr: usize) void {
            g.enterWindow(@ptrFromInt(ptr));
        }

        /// The real structure: the entry *is* a locked body, so the second thread
        /// is at `acquire` while the first is inside the window.
        fn enterLocked(g: *WindowGate, ptr: usize, lock: *RaftLock) void {
            lock.acquire();
            defer lock.release();
            g.enterWindow(@ptrFromInt(ptr));
        }
    };

    // 1. Unserialized. The first thread sets `waiting` and then has no release
    //    condition to find, so it spins until the second arrives and sets
    //    `overlapped`. Certain, not likely: the wait cannot end any other way.
    {
        var gate = WindowGate{ .backing = std.testing.allocator };
        gate.watched.store(watched, .release);
        const a = try std.Thread.spawn(.{}, Drivers.enterFree, .{ &gate, watched });
        const b = try std.Thread.spawn(.{}, Drivers.enterFree, .{ &gate, watched });
        a.join();
        b.join();
        try std.testing.expect(gate.overlapped.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), gate.freed.load(.acquire));
    }

    // 2. Serialized — the same two threads, the same gate, only the entry takes a
    //    lock. The first thread is *inside* that lock, so it leaves at once on
    //    `isHeld()`; the second is stuck at `acquire` and cannot set `overlapped`.
    //    The rendezvous reports nothing, which is the healthy reading the test
    //    above asserts — here with a reason rather than by luck of interleaving.
    {
        var lock = RaftLock{};
        var gate = WindowGate{ .backing = std.testing.allocator, .lock = &lock };
        gate.watched.store(watched, .release);
        const a = try std.Thread.spawn(.{}, Drivers.enterLocked, .{ &gate, watched, &lock });
        const b = try std.Thread.spawn(.{}, Drivers.enterLocked, .{ &gate, watched, &lock });
        a.join();
        b.join();
        try std.testing.expect(!gate.overlapped.load(.acquire));
        // Both walked it: the silence above is "they were serialized", not "the
        // protocol was never reached" — the same distinction the test above
        // draws with its own `freed >= 1`.
        try std.testing.expectEqual(@as(usize, 2), gate.freed.load(.acquire));
    }
}
