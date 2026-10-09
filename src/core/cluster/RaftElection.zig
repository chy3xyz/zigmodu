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
const builtin = @import("builtin");
const Time = @import("../Time.zig");

/// The lock guarding a `RaftElection`'s state.
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
/// Not `std.Io.Mutex`, and not by preference: **this file has no `io`**, and
/// threading one in is not a local change. `ClusterBootstrap` owns the `io`
/// (`ClusterBootstrap.zig:97`) but reaches this file without it — it calls
/// `RaftElection.init(self.allocator, self.config.node_id, …)` at `:266` and
/// `raft.tick()` at `:471` — and the accept thread reaches the handlers through
/// `RaftTransport.handleConnection(raft, addresses, conn)` (`RaftTransport.zig:699`),
/// which takes no `io` either (the one that does, `InboundImpl.init` at `:547`,
/// keeps it for its own socket and never stores it on the raft). Adding a
/// parameter would change `init` plus all fifteen public entry points and their
/// ~30 call sites, in `ClusterBootstrap.zig` / `RaftTransport.zig` /
/// `DistributedIntegrationTest.zig`. It would also put `error.Cancelable` — which
/// `std.Io.Mutex.lock` can return — on the error set of seven accessors that
/// return a plain value today (`isLeader`, `getLeader`, `getTerm`, `logLen`,
/// `getCommitIndex`, `getLogEntry`, `getState`).
///
/// So the wait sleeps without an `Io` instead ([`sleepWithoutIo`]). What it is
/// *not* is the flat spin it used to be: see `acquire` for why that mattered
/// here more than the exclusion did.
///
/// Deliberately **not** covered: `deinit` (terminal, see its doc), and
/// `clusterSize` / `quorumSize` / `hasQuorum`, which read only the membership
/// and are called from *inside* the locked bodies.
pub const RaftLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// The wait's three budgets, in loop rounds.
    ///
    /// `spin_rounds` covers micro-contention — a holder that is a few
    /// instructions into its critical section, including the accessors' whole
    /// bodies. `yield_rounds` covers a holder that is runnable but not currently
    /// scheduled, where handing over the slice is cheaper than waiting the budget
    /// out. Past both, the holder is not coming back within a scheduling quantum
    /// and the only thing left that helps is to stop running; `core/SpinLock.zig`
    /// stops at the second stage, which is right for the short sections it
    /// guards and wrong for this one.
    const spin_rounds: u32 = 32;
    const yield_rounds: u32 = 128;

    /// How long the sleep stage sleeps per round. One millisecond — the same
    /// figure `runtime/scheduler.zig` parks on (`idle_wait_ms`), and for the same
    /// reason: it is the granularity that costs nothing next to the waits it
    /// exists for, while keeping the release-to-acquire hand-off delay bounded.
    const sleep_ms: u32 = 1;

    /// Take the lock, waiting in an escalating shape rather than spinning flat.
    ///
    /// **Why the wait shape matters here at all.** When this wait was built, the
    /// holder could be asleep in an RPC for `ElectionConfig.rpc_timeout_ms` (100 ms
    /// by default) — *per peer* — because `tick()` ran its whole outbound round
    /// under this lock, and every waiter spun a core for the whole hold. That was
    /// the cost of the loop this replaced (`while (self.flag.swap(true, .acquire))
    /// spinLoopHint()`), measured at a full core for the whole hold. The outbound
    /// round has since moved out of the lock (`flushOutgoing`'s phase 2 does the IO
    /// unlocked), so the remaining holds are the phase-1 staging copy (bounded by
    /// `max_append_entries` commands, or one snapshot memcpy), the phase-3 map
    /// writes, and the inbound handler bodies — shorter, but still long enough
    /// that a flat spin would be the wrong shape to leave in place.
    ///
    /// Three stages, chosen by round count:
    ///
    ///   1. `spin_rounds` of `spinLoopHint`.
    ///   2. `yield_rounds` of `std.Thread.yield`, so a holder that is runnable
    ///      gets the core back.
    ///   3. `sleepWithoutIo`, `sleep_ms` per round.
    ///
    /// The third stage is the one that does the work, and the second is not a
    /// substitute for it: a holder that is *asleep in a syscall* (the snapshotter
    /// hook, a page fault mid-memcpy) is not runnable at all, so `yield` returns
    /// immediately and the core keeps burning (measured back when the holder was
    /// an RPC wait: `yield` alone cost ~116 ms of CPU for a 120 ms hold, against
    /// ~0 ms with the sleep). The first two stages exist so that the sleep — which
    /// can delay noticing a release by up to `sleep_ms` — is only reached once the
    /// wait has stopped looking like a short critical section.
    ///
    /// The **fast path** is a compare-exchange rather than a `swap`: `swap` wrote
    /// the flag on every attempt, so N waiters kept dirtying the one cache line
    /// they all read — exclusion stayed correct, but every waiter made all the
    /// others slower. A failed compare-exchange does not write.
    ///
    /// Still **not re-entrant**, and still a deadlock if used that way: nothing
    /// here tracks an owner. That is unchanged (a `cmpxchgWeak` on a held flag
    /// fails exactly as the `swap` did), and it is why `clusterSize` /
    /// `quorumSize` / `hasQuorum` are lock-free.
    pub fn acquire(self: *RaftLock) void {
        if (self.tryAcquire()) return;

        var rounds: u32 = 0;
        while (!self.tryAcquire()) {
            rounds +|= 1;
            if (rounds <= spin_rounds) {
                std.atomic.spinLoopHint();
            } else if (rounds <= spin_rounds + yield_rounds) {
                std.Thread.yield() catch |err| {
                    std.log.debug("[RaftLock] wait: yield failed ({s}), retrying", .{@errorName(err)});
                };
            } else {
                sleepWithoutIo(sleep_ms);
            }
        }
    }

    /// One non-blocking attempt. Private: no caller of this lock wants a
    /// non-blocking acquire, and the two places that need the compare-exchange
    /// (the fast path and the loop above) are both in `acquire`.
    fn tryAcquire(self: *RaftLock) bool {
        return self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) == null;
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

/// Targets where `std.posix.poll` is usable. Windows is a `@compileError` there
/// ("use std.Io instead"), and the freestanding-ish targets have no `poll` at
/// all; on those the wait degrades to `std.Thread.yield`.
const can_poll_sleep = switch (builtin.target.os.tag) {
    .windows, .wasi, .uefi, .freestanding, .other => false,
    else => true,
};

/// Sleep for `ms` milliseconds, with no `Io` to hand.
///
/// [`RaftLock`] has none: see its own doc for the call chain that leaves this
/// file io-less. The toolchain's only sleeping primitive (`std.Io.sleep`) takes
/// an `Io`, so an io-free equivalent is used.
///
/// **Why not a timeout-only `poll` with an empty slice** (the first shape here):
/// it *worked on macOS and faulted on Linux CI* — `poll(&.{}, …)` passes the
/// address of a zero-length array literal, which the compiler is free to
/// materialize as a non-dereferenceable value (`0xaa…` under Debug's undefined
/// fill), and Linux answers `EFAULT`. `std.posix.poll` maps `.FAULT` to
/// `unreachable`, so the waiter aborted the process instead of sleeping:
/// `panic: reached unreachable code` in `RaftLock.acquire` →
/// `handleVoteResponse` → `RaftTransport.handleConnection`, reproduced on the
/// Ubuntu runner. The same minimal program passes in a Linux container, which is
/// exactly the trap — the pointer's value, not the API, decided it.
///
/// So: `nanosleep` via libc (no pointer arguments at all), and a `poll` on a
/// **real** zero-length variable where libc is unavailable — that pointer is a
/// stack address and always valid. Signals cut the sleep short; the caller loops
/// on the lock anyway, so one extra round costs nothing.
fn sleepWithoutIo(ms: u32) void {
    if (ms == 0) return;
    if (comptime can_poll_sleep) {
        if (comptime builtin.link_libc) {
            var ts = std.c.timespec{
                .sec = @intCast(ms / 1000),
                .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
            };
            _ = std.c.nanosleep(&ts, null);
        } else {
            var no_fds: [0]std.posix.pollfd = .{};
            _ = std.posix.poll(&no_fds, @intCast(ms)) catch |err| {
                std.log.debug("[RaftLock] wait: poll sleep failed ({s}), retrying", .{@errorName(err)});
            };
        }
    } else {
        std.Thread.yield() catch |err| {
            std.log.debug("[RaftLock] wait: yield failed ({s}), retrying", .{@errorName(err)});
        };
    }
}

/// Configuration for Raft
pub const ElectionConfig = struct {
    /// Minimum election timeout (ms)
    election_timeout_min_ms: u64 = 150,

    /// Maximum election timeout (ms)
    election_timeout_max_ms: u64 = 300,

    /// Heartbeat interval (ms) - leader sends heartbeats at this rate
    heartbeat_interval_ms: u64 = 50,

    /// Maximum entries to send in one AppendEntries RPC, and — the inbound half
    /// — the most entries one received `append_entries` may apply. A lagging
    /// follower is fed its backlog in chunks of this size; values below 1 are
    /// read as 1 on both sides.
    ///
    /// Inbound it is a **clamp, not a refusal**: the follower applies a prefix
    /// and reports the `match_index` it reached, so a peer with a different
    /// value costs an extra round instead of stalling. The decoder's ceiling is
    /// `RaftTransport.MAX_ENTRIES_PER_FRAME` — a frame declaring more than that
    /// is dropped before it is decoded, so **keep this at or below it** on every
    /// node: a sender set higher than a receiver's ceiling would have every
    /// frame dropped and could never catch that follower up.
    max_append_entries: usize = 100,

    /// How long an outbound Raft RPC may take before it is written off as a lost
    /// message (which Raft re-sends — see `RaftTransport`: every failure mode is
    /// the same "lost message" answer, never a panic).
    ///
    /// This used to be a **liveness bound on the lock**, and the reason was the
    /// shape of the driver: `tick()` performed its outbound round while holding
    /// `RaftLock`, so a peer that never answered did not merely delay the round —
    /// it held off every other thread that wanted the state (the accept thread's
    /// inbound RPCs, `appendEntry`, the accessors) for as long as the RPC waited.
    /// Before this field existed the wait was the OS default: a black-holed peer
    /// (SYN dropped, or a connection accepted and never answered) cost the node
    /// *minutes*.
    ///
    /// The outbound round has since moved out of the lock (`flushOutgoing` stages
    /// under the lock, delivers unlocked, applies under the lock), so what this
    /// number bounds now is the round itself: an unreachable peer costs this
    /// number **per peer per round**, and nobody else's access to the state. Keep
    /// it comfortably under `election_timeout_min_ms`: past that point the round
    /// has already missed its own heartbeat, so a larger value buys nothing but a
    /// longer stall. Raise it for a WAN whose RTTs approach the default — a
    /// slow-but-reachable peer now gets its reply written off as lost instead of
    /// being waited for. 0 disables the bound (the pre-fix behaviour).
    rpc_timeout_ms: u32 = 100,

    /// Pre-shared key for the cluster port (docs/dev/cluster-auth-design.md).
    /// When set, every inbound Raft frame must carry a valid HMAC-SHA256 tag and
    /// every outbound one is signed. When null the frames are bare — which is why
    /// `ClusterBootstrap.start()` refuses a multi-node cluster without one.
    ///
    /// **A shared key authenticates a frame but binds no identity**: any holder of
    /// the PSK can sign as any `candidate_id` / `leader_id`. The identity-bound
    /// path is `own_key` / `peer_keys` below; when either is set it wins over
    /// this field (falling back to the shared key would re-open exactly the
    /// impersonation hole per-node mode exists to close).
    cluster_secret: ?[32]u8 = null,

    /// A-1 (docs/dev/cluster-auth-design.md, the Raft half of
    /// docs/dev/cluster-identity-design.md's bus-side identity binding):
    /// **this node's own
    /// credential** — the key every outbound frame is signed with, and the key
    /// peers must have on record as `peer_keys[this node_id]` to verify them.
    /// Source it from `security.SecretsManager`; the framework deliberately does
    /// not read keys for you (the same convention as `cluster_secret`).
    ///
    /// Setting this (or any `peer_keys` entry) switches the cluster port to
    /// per-node identity: a frame is verified against the key of the sender id
    /// it *claims* (`candidate_id` / `leader_id` / `responder_id` — already in
    /// every frame, and inside the MAC's coverage), so only the holder of
    /// node-X's key can appear as X. The mode is fail-closed: a peer with no key
    /// on record is never dialled and its inbound frames are refused.
    ///
    /// A-3: after `init` this field is guarded by `RaftElection.key_lock` —
    /// change it only through `RaftElection.rotateOwnKey`, never by poking the
    /// config directly (the accept thread reads it under that lock).
    own_key: ?[32]u8 = null,

    /// A-1: the peers' credentials — `key` is the key **that node** signs with
    /// (its own `own_key`), `id` is the same namespace as `Peer.id` / `node_id`
    /// (the `@id` half of `BootstrapConfig.peers`). `RaftElection.init` copies
    /// the slice and the ids, so the caller's storage may be freed after init.
    ///
    /// Response frames carry no sender id; the synchronous RPC paths verify a
    /// reply against the key of the peer they dialled, which is why a missing
    /// entry here means "cannot talk to that peer at all", not "talk less
    /// safely".
    ///
    /// A-3: same `key_lock` rule as `own_key` — runtime changes go through
    /// `rotatePeerKey` / `setPeerKey` / `dropPreviousPeerKey` / `revokePeerKey`.
    /// `PeerKey.previous` is the rotation window those calls manage.
    peer_keys: []const PeerKey = &.{},

    /// §7 log compaction, leader-side automatic trigger: once the **live** log
    /// (`log.items.len`, i.e. entries past the snapshot boundary) exceeds this
    /// many entries, the leader's `tick()` compacts the committed prefix into a
    /// snapshot. `0` disables it — the default, so an existing cluster's
    /// behaviour does not change. Compaction never crosses `commit_index`: an
    /// uncommitted entry is never folded into a snapshot.
    snapshot_threshold_entries: usize = 0,

    /// One InstallSnapshot frame carries at most this many bytes of snapshot
    /// payload; a bigger snapshot is sent as `offset`/`done` chunks of this size
    /// (the follower reassembles them in `handleInstallSnapshot`). The wire
    /// length-prefixes payload with a u16, so the effective chunk is clamped to
    /// 65535.
    snapshot_chunk_bytes: usize = default_snapshot_chunk_bytes,

    /// §7: where snapshot bytes come from when `snapshot_threshold_entries`
    /// fires (or when an app drives `compactLog` itself it passes the bytes
    /// directly). Called on the leader with the lock held — keep it cheap. The
    /// returned slice must be allocated with the passed allocator and becomes
    /// the raft's to free (it is released right after `compactLog` copies it).
    ///
    /// When null, a **placeholder** is stored: a parseable debug summary
    /// (`zigmodu-raft-snapshot:v1:last_included_index=…:last_included_term=…:
    /// compacted_entries=…`). The framework has no application state machine, so
    /// restoring application state from a snapshot is the *application's* job —
    /// it supplies this hook (and consumes `snapshot_data`, which has a store
    /// either way).
    snapshotter: ?Snapshotter = null,
    /// Opaque context handed to `snapshotter`.
    snapshotter_ctx: ?*anyopaque = null,
};

/// Default for `ElectionConfig.snapshot_chunk_bytes`, named so
/// `BootstrapConfig` can share it instead of restating the number.
pub const default_snapshot_chunk_bytes: usize = 16 * 1024;

/// See `ElectionConfig.snapshotter`.
pub const Snapshotter = *const fn (ctx: ?*anyopaque, up_to_index: u64, allocator: std.mem.Allocator) anyerror![]u8;

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

/// A-1: one node's credential on the cluster port (`ElectionConfig.peer_keys`).
/// `id` is the same namespace as `Peer.id` / `node_id`; `key` is the key that
/// node signs its frames with (its own `own_key`). See `ElectionConfig.own_key`
/// for the mode this enables.
///
/// A-3 (`RaftElection.rotatePeerKey`): `previous` is the rotation window — while
/// it is set, frames signed with **either** `key` or `previous` verify (signing
/// never uses `previous`). It is cleared by `setPeerKey` / `dropPreviousPeerKey`,
/// and stays null for every entry that was never rotated.
pub const PeerKey = struct {
    id: []const u8,
    key: [32]u8,
    previous: ?[32]u8 = null,
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

/// The default `ElectionTransport.sendInstallSnapshot`: the "lost message"
/// answer (`term = 0` is below any live term, so the leader treats it as a
/// dropped frame and retries next round). See the field's own doc.
fn lostInstallSnapshot(_: ?[]const u8, _: []const u8, _: InstallSnapshotRequest) InstallSnapshotResponse {
    return .{ .term = 0 };
}

/// Raft
///
/// Handles leader election and log replication within a Raft cluster.
pub const RaftElection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ElectionConfig,

    /// Serializes every entry point that touches the fields below — see
    /// `RaftLock` for why this lives here rather than in the caller. Held for
    /// the body of `handle*` / `appendEntry` / `addPeer` / `compactLog`, by the
    /// state accessors, and for phases 1 and 3 of `flushOutgoing` (which is what
    /// `tick` runs) — phase 2, the outbound IO itself, runs with the lock
    /// released. The private helpers called from locked bodies (`startElection`,
    /// `stageLeaderRoundLocked`, `applyStagedRoundLocked`, …) assume it is
    /// already held; `deliverStagedRound` assumes the opposite.
    lock: RaftLock = .{},

    /// A-3: guards **only** the key material — `config.own_key` and
    /// `config.peer_keys` (the slice header included) — against the runtime
    /// rotation/revocation API below. It exists because the inbound read side
    /// is *not* under `lock`: `RaftTransport.handleConnection` deliberately
    /// resolves and verifies a frame's key before the dispatch that would take
    /// `lock` (see its own comment), so a `peer_keys` rebuild holding only
    /// `lock` would free the slice out from under an accept-thread reader.
    ///
    /// Discipline: a reader acquires this lock, resolves the key(s) it needs
    /// **by value** (`[32]u8` copies — `authMode` / `signAuth` / `nodeKeys`),
    /// and releases before any IO; a mutation does its whole rebuild inside the
    /// lock, so no reader can be mid-iteration when an old slice is freed. The
    /// critical sections are a short scan plus value copies (a mutation adds
    /// one allocator call — an operational rarity, not a per-frame path).
    ///
    /// Lock order: `lock` → `key_lock` (`tick`'s outbound round resolves keys
    /// while holding `lock`); `key_lock` is otherwise taken alone, and nothing
    /// holding it ever acquires `lock` or blocks on IO.
    key_lock: RaftLock = .{},

    /// The mutable view of the peer-key table — the **same allocation** as
    /// `config.peer_keys`, owned by this raft since `init`. `ElectionConfig`'s
    /// public shape is `[]const PeerKey` (so callers can pass comptime
    /// literals), but the A-3 rotation/revocation calls mutate entries in
    /// place; every such mutation goes through this view under `key_lock` and
    /// re-publishes **both** views when the slice is rebuilt.
    peer_keys_mut: []PeerKey,

    // Persistent state (would be persisted to disk in full Raft)
    current_term: u64 = 0,
    voted_for: ?[]const u8 = null,
    log: std.ArrayList(LogEntry),
    last_included_index: u64 = 0,
    last_included_term: u64 = 0,
    snapshot_data: ?[]const u8 = null,
    /// Chunk assembly for an inbound InstallSnapshot that arrives in pieces
    /// (`offset`/`done`): `offset == 0` starts it, continuations must name the
    /// same `(pending_snapshot_index, pending_snapshot_term)` and land at
    /// exactly `pending_snapshot.items.len`, and `done` applies it.
    pending_snapshot: std.ArrayList(u8),
    pending_snapshot_index: u64 = 0,
    pending_snapshot_term: u64 = 0,

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

    // ── Outbound staging (the three-phase flush — see `flushOutgoing`) ──

    /// Set by `becomeLeader`, which runs under `lock` and therefore cannot do
    /// IO: the next flush sends the initial heartbeat even when the regular
    /// interval has not elapsed. Cleared by the flush that stages it.
    heartbeat_owed: bool = false,

    /// One flush in flight at a time. The staging buffers below are per-node
    /// and reused, so a second `flushOutgoing` (the accept thread's post-vote
    /// flush meeting the tick thread mid-round) skips instead of racing them;
    /// whatever it would have sent is either redundant (heartbeats repeat every
    /// interval) or stays owed (`heartbeat_owed` is only cleared by the flush
    /// that stages it).
    flush_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Phase-1 scratch: entry commands and snapshot bytes are deep-copied here
    /// so phase 2's IO touches nothing the log owns. `reset(.retain_capacity)`
    /// per leader round — steady state (heartbeats carry no entries) does not
    /// allocate; a catch-up round reuses the retained buffer.
    outbound_arena: std.heap.ArenaAllocator,

    /// The peer snapshot a staged vote fan-out is delivered to — `peers` itself
    /// may be regrown by `addPeer` while phase 2 is mid-iteration, so phase 2
    /// never reads it. `clearRetainingCapacity` per election: no allocation in
    /// the steady state.
    staged_peers: std.ArrayList(Peer),

    /// One leader round, per peer, made self-contained in phase 1. Cleared at
    /// the top of every flush's phase 1 (not only when a round is staged), so
    /// a tick with nothing due delivers nothing — see `flushOutgoing`.
    staged_items: std.ArrayList(StagedOutbound),

    /// The staged election broadcast (values only; `candidate_id` borrows
    /// `local_id`, which outlives every round). Consumed by
    /// `deliverStagedRound`.
    staged_vote: ?VoteRequest = null,

    /// Transport interface for network communication
    pub const ElectionTransport = *const struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
        /// §7: synchronous, like `sendAppendEntries` — the follower replies on
        /// the same connection. Defaults to the "lost message" answer so a
        /// two-field transport literal still compiles: with it a compacted
        /// leader simply never catches a boundary-lagged follower up (the
        /// snapshot send goes nowhere, retried each round) until a real
        /// transport is supplied. **Note for `@ptrCast` vtables**: a hand-rolled
        /// struct must declare this field too — the cast shares the layout.
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse = &lostInstallSnapshot,
    };

    /// One peer's share of a leader round, staged self-contained in phase 1 of
    /// `flushOutgoing` (the obligations are on its doc): everything phase 2's IO
    /// reads is a value, a borrow of memory that outlives the round (`local_id`,
    /// the peers' stored ids), or an `outbound_arena` copy — so the log or the
    /// snapshot being truncated/replaced mid-send cannot reach the wire.
    const StagedOutbound = struct {
        /// Struct copy; `id`/`address` borrow the raft-owned strings (freed only
        /// in `deinit`).
        peer: Peer,
        kind: enum { append_entries, install_snapshot },

        // append_entries
        prev_log_index: u64 = 0,
        prev_log_term: u64 = 0,
        /// Arena-owned deep copies — phase 2 reads these, never `log`.
        entries: []const LogEntry = &.{},
        leader_commit: u64 = 0,
        /// Phase 2's answer, consumed by phase 3.
        resp: ?AppendEntriesResponse = null,

        // install_snapshot (chunked in phase 2 over one arena-owned copy)
        snapshot_index: u64 = 0,
        snapshot_term: u64 = 0,
        snapshot_bytes: []const u8 = &.{},
        /// The last reply's term, and whether the `done` frame was acked in
        /// term. A transfer cut short leaves the peer at the boundary and is
        /// retried next round.
        snapshot_resp_term: ?u64 = null,
        snapshot_completed: bool = false,
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

        // A-1: the peer-key table is read on every inbound frame for the raft's
        // whole life, so it cannot borrow the caller's config slice — copy the
        // entries (ids included) and point the kept config at the copy.
        const peer_keys_copy = try allocator.alloc(PeerKey, config.peer_keys.len);
        var peer_keys_init: usize = 0;
        errdefer {
            for (peer_keys_copy[0..peer_keys_init]) |pk| allocator.free(pk.id);
            allocator.free(peer_keys_copy);
        }
        for (config.peer_keys, 0..) |pk, i| {
            peer_keys_copy[i] = .{ .id = try allocator.dupe(u8, pk.id), .key = pk.key, .previous = pk.previous };
            peer_keys_init = i + 1;
        }
        var config_kept = config;
        config_kept.peer_keys = peer_keys_copy;

        const now_ms = Time.monotonicNowMilliseconds();

        return .{
            .allocator = allocator,
            .config = config_kept,
            .peer_keys_mut = peer_keys_copy,
            .log = std.ArrayList(LogEntry).empty,
            .pending_snapshot = std.ArrayList(u8).empty,
            .next_index = std.StringHashMap(u64).init(allocator),
            .match_index = std.StringHashMap(u64).init(allocator),
            .votes_received = std.StringHashMap(void).init(allocator),
            .local_id = local_id_copy,
            .peers = peers_copy,
            .transport = transport,
            .outbound_arena = std.heap.ArenaAllocator.init(allocator),
            .staged_peers = std.ArrayList(Peer).empty,
            .staged_items = std.ArrayList(StagedOutbound).empty,
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
        self.pending_snapshot.deinit(self.allocator);

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
        // The A-1 peer-key table: owned by this raft since `init` (see there).
        // `config.peer_keys` is the same allocation as `peer_keys_mut` — free
        // it exactly once, through the mutable view.
        for (self.peer_keys_mut) |pk| self.allocator.free(pk.id);
        self.allocator.free(self.peer_keys_mut);
        if (self.voted_for) |v| self.allocator.free(v);
        if (self.snapshot_data) |s| self.allocator.free(s);
        // leader_id may alias local_id (from becomeLeader); only free when they differ

        if (self.leader_id) |l| {
            if (l.ptr != self.local_id.ptr) {
                self.allocator.free(l);
            }
        }
        // The outbound staging: the arena owns its buffers, the lists their
        // element storage (the staged contents borrow, they do not own).
        self.outbound_arena.deinit();
        self.staged_peers.deinit(self.allocator);
        self.staged_items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Main tick function - called periodically.
    ///
    /// One tick is one `flushOutgoing`: decide under `lock` (election timeout →
    /// stage the ballots; leader round due → stage it), deliver with the lock
    /// released, then re-acquire and apply the replies. The lock is never held
    /// across IO — the contract is on `flushOutgoing`.
    pub fn tick(self: *Self) !void {
        try self.flushOutgoing();
    }

    /// The node's outbound pump, and the answer to "the outbound round used to
    /// run under `lock` for its whole length" (docs/DISTRIBUTED.md 「出站 IO 与
    /// 锁」). `tick()` is one call to this; `handleVoteResponse` calls it after
    /// releasing its own lock, so a won election's first heartbeat goes out
    /// immediately rather than at the next due interval.
    ///
    /// Three phases, with the obligations that keep the split safe:
    ///
    ///   1. **Stage self-contained requests (locked).** Everything phase 2 puts
    ///      on the wire is decided and deep-copied here: entry commands and
    ///      snapshot bytes into `outbound_arena`, the peer list into
    ///      `staged_peers`. Once the lock is released, an inbound
    ///      `handleAppendEntries` may truncate the log and free exactly those
    ///      bytes — the wire must never read memory the raft still owns. The
    ///      steady state (heartbeats with empty entries) copies nothing.
    ///   2. **Deliver (unlocked).** Pure IO: the staged ballots and per-peer
    ///      rounds go out, replies are recorded on the staged items. Reads only
    ///      the staging buffers (single-tenant under `flush_active`) and fields
    ///      that are immutable after `init` (`local_id`, `config`, `transport`).
    ///   3. **Apply (locked, validated).** A reply's higher term always steps
    ///      the node down. Everything else applies only if the round is still
    ///      ours — `state == .leader` and `current_term` unchanged since
    ///      staging — otherwise the whole batch is dropped: between the phases
    ///      an inbound RPC may have moved the term, demoted us, or re-elected
    ///      us, and a stale round's bookkeeping is worse than none.
    ///      `next_index` / `match_index` are read and written only in this
    ///      phase, never carried across.
    fn flushOutgoing(self: *Self) !void {
        // The staging buffers are reused, so two flushes may not overlap: the
        // accept thread's post-vote flush can meet the tick thread mid-round.
        // Skipping loses nothing — heartbeats repeat every interval, and an owed
        // one stays owed until a flush actually stages it.
        if (self.flush_active.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) return;
        defer self.flush_active.store(false, .release);

        // ── Phase 1: decide, and stage this round self-contained ──
        var leader_round = false;
        var round_term: u64 = 0;
        {
            self.lock.acquire();
            defer self.lock.release();

            const now_ms = Time.monotonicNowMilliseconds();
            // Both staging buffers reset up front: phase 2 runs on every flush
            // (there is nothing to skip — a vote, a round, or nothing at all),
            // so a tick that stages nothing must carry nothing — never the
            // previous round's leftover items, re-sent under a zero term.
            self.staged_vote = null;
            self.staged_items.clearRetainingCapacity();

            switch (self.state) {
                .follower, .candidate => {
                    if (now_ms >= self.election_deadline_ms) {
                        try self.startElection();
                    }
                },
                .leader => {},
            }

            // A won single-node election lands here in the same flush:
            // `startElection` → `becomeLeader` left a heartbeat owed.
            if (self.state == .leader) {
                const heartbeat_due = now_ms - self.last_heartbeat_ms >= @as(i64, @intCast(self.config.heartbeat_interval_ms));
                if (heartbeat_due or self.heartbeat_owed) {
                    self.heartbeat_owed = false;
                    self.last_heartbeat_ms = now_ms;
                    if (self.stageLeaderRoundLocked()) |term| {
                        round_term = term;
                        leader_round = true;
                    } else |err| {
                        // The round is skipped, not half-sent; the next due
                        // tick retries.
                        self.staged_items.clearRetainingCapacity();
                        std.log.err("[RaftElection] staging the leader round failed, skipping this round: {}", .{err});
                    }
                }
                // §7 housekeeping on the leader: bounded log growth. Off by
                // default (`snapshot_threshold_entries = 0`); when on, a skipped
                // compaction (e.g. an OOM in the snapshotter) must not stop the
                // heartbeat loop, so the error is logged instead of propagated.
                self.maybeCompactLog() catch |err| {
                    std.log.err("[RaftElection] auto-compaction skipped this tick: {}", .{err});
                };
            }
        }

        // ── Phase 2: deliver (no lock held) ──
        self.deliverStagedRound(round_term);

        // ── Phase 3: apply, with the round's validity re-checked ──
        if (leader_round) {
            self.lock.acquire();
            defer self.lock.release();
            self.applyStagedRoundLocked(round_term);
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

        // Absolute index: after a compaction the first live entry is
        // `last_included_index + 1`, so the tail is `lastLogIndex()`, not
        // `log.items.len`.
        const index: u64 = self.lastLogIndex() + 1;
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

        // Only configured cluster members get a vote. `handleVoteResponse` has always
        // checked this; this handler did not, so an arbitrary TCP peer could name any
        // `candidate_id` and be granted a ballot (docs/dev/cluster-auth-design.md §1).
        // Deny rather than error: an unknown candidate is a peer's mistake, not ours.
        // Placed before every state mutation — including the term update below, which
        // would otherwise let an impostor move our term and reset the election clock.
        if (self.peerId(req.candidate_id) == null) {
            return VoteResponse{ .term = self.current_term, .vote_granted = false };
        }

        if (req.term > self.current_term) {
            self.current_term = req.term;
            self.state = .follower;
            if (self.voted_for) |v| self.allocator.free(v);
            self.voted_for = null;
        }

        var vote_granted = false;

        if (req.term >= self.current_term) {
            if (self.voted_for == null or std.mem.eql(u8, self.voted_for.?, req.candidate_id)) {
                // Check log completeness: candidate's log must be at least as
                // up-to-date. Absolute coordinates: with a snapshot installed the
                // tail is `lastLogIndex()`, and an empty live log's last term is
                // the snapshot's `last_included_term` (§7).
                const last_idx = self.lastLogIndex();
                const last_term = self.lastLogTerm();

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
                .match_index = self.lastLogIndex(),
            };
        }

        // The leader must be someone we know (or us — `becomeLeader` sets `leader_id`
        // to our own `local_id`). Placed before every mutation including the term
        // update: an impostor should not be able to move our term, reset our election
        // deadline, or reach the log. `success = false` tells the sender nothing about
        // whether we know them (docs/dev/cluster-auth-design.md §1/#2, §4.1).
        if (!std.mem.eql(u8, req.leader_id, self.local_id) and self.peerId(req.leader_id) == null) {
            return AppendEntriesResponse{
                .term = self.current_term,
                .success = false,
                .match_index = self.lastLogIndex(),
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
        // `getLeader()` hands it out). The alias guard mirrors `becomeLeader`:
        // after its allocation-failure fallback `leader_id` **is** `local_id`,
        // and freeing it here would dangle `local_id` itself.
        const leader_copy = try self.allocator.dupe(u8, req.leader_id);
        if (self.leader_id) |l| {
            if (l.ptr != self.local_id.ptr) self.allocator.free(l);
        }
        self.leader_id = leader_copy;

        // Reply false if the log doesn't contain prev_log_index with a matching
        // term (§5.3) — with the §7 wrinkle that the log no longer starts at
        // index 1 once a snapshot is installed:
        //
        //   * prev **above** the boundary is a live entry: position
        //     `prev - last_included_index`, term compared as before, and a
        //     conflict still truncates from there (never into the snapshot).
        //   * prev **at** the boundary matches against `last_included_term`
        //     (Raft §7's standard rule). A mismatch rejects *without*
        //     truncating — the snapshot is committed history, not ours to cut.
        //   * prev **below** the boundary is implicitly matched: that region is
        //     committed (`compactLog` refuses an uncommitted boundary), so by
        //     leader completeness (§5.4.3) the leader's history there is
        //     identical to ours. The entry loop then skips everything the
        //     snapshot already covers.
        if (req.prev_log_index > 0) {
            if (req.prev_log_index > self.lastLogIndex()) {
                return AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .match_index = self.lastLogIndex(),
                };
            }
            if (req.prev_log_index > self.last_included_index) {
                const prev_pos: usize = @intCast(req.prev_log_index - self.last_included_index);
                const prev_entry = self.log.items[prev_pos - 1];
                if (prev_entry.term != req.prev_log_term) {
                    // Conflict: delete conflicting entry and everything after it
                    self.truncateLog(prev_pos - 1);
                    return AppendEntriesResponse{
                        .term = self.current_term,
                        .success = false,
                        .match_index = self.lastLogIndex(),
                    };
                }
            } else if (req.prev_log_index == self.last_included_index and
                req.prev_log_term != self.last_included_term)
            {
                return AppendEntriesResponse{
                    .term = self.current_term,
                    .success = false,
                    .match_index = self.lastLogIndex(),
                };
            }
        }

        // **The inbound half of `max_append_entries`.** The field was a
        // sender-side chunking knob only — nothing bounded what a peer could put
        // in one frame, so a single `append_entries` applied as many entries as
        // it cared to carry (and by the time the request arrives here, the frame
        // has already been decoded into the arena: see
        // `RaftTransport.MAX_ENTRIES_PER_FRAME`, which is the other half of the
        // bound).
        //
        // **Clamp, do not reject.** Applying a prefix is valid Raft: the follower
        // appends sequentially from `prev_log_index + 1`, and its reply's
        // `match_index` is the tail it actually reached, so the leader resumes
        // from there next round (`sendAppendEntries` takes the lower of "what I
        // sent" and that `match_index` — this is what keeps the leader's
        // bookkeeping honest when the follower applies less than it was sent).
        // Rejecting the frame instead would require both ends to share the same
        // `max_append_entries`: a follower smaller than its leader would refuse
        // every batch the leader can build, and replication would stall forever.
        // Clamping is self-healing across that mismatch — it costs one extra
        // round, not a stuck peer. A cap of 0 is read as 1, same as the sender.
        const max_entries = @max(@as(usize, 1), self.config.max_append_entries);
        const entries: []const LogEntry = if (req.entries.len > max_entries)
            req.entries[0..max_entries]
        else
            req.entries;

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
        //
        // Contiguity is validated here too: entries must run
        // `prev_log_index + 1, +2, …` with no gaps. A gapped batch would
        // otherwise append past the tail and misalign absolute index and
        // position — the invariant every position computation in this file
        // stands on. Rejected alongside the zero-index guard, before any
        // mutation, for the same reason.
        for (entries, 0..) |entry, i| {
            if (entry.index == 0) return error.InvalidLogIndex;
            if (entry.index != req.prev_log_index + 1 + @as(u64, @intCast(i))) return error.InvalidLogIndex;
        }

        // Process incoming entries: skip already-matched, overwrite conflicts.
        // Absolute index → position: the live log starts at
        // `last_included_index + 1`, and anything at or below the boundary is
        // the snapshot's — already committed, already identical (see the prev
        // check), so it is skipped rather than re-appended.
        for (entries) |entry| {
            if (entry.index <= self.last_included_index) continue;
            const pos: u64 = entry.index - self.last_included_index; // 1-based position
            if (pos <= self.log.items.len) {
                const existing = self.log.items[pos - 1];
                if (existing.term != entry.term) {
                    // Conflict at this index: delete it and everything after
                    self.truncateLog(pos - 1);
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
            self.commit_index = @min(req.leader_commit, self.lastLogIndex());
        }

        return AppendEntriesResponse{
            .term = self.current_term,
            .success = true,
            .match_index = self.lastLogIndex(),
        };
    }

    // ── Private helpers ─────────────────────────────────────────────────────
    //
    // Everything from here down falls under one of two locking disciplines.
    // The steps *within* one state transition (`startElection`, `becomeLeader`,
    // `stageLeaderRoundLocked`, `applyStagedRoundLocked`, `advanceCommitIndex`,
    // `truncateLog`, `randomElectionTimeout`, the index helpers,
    // `processInstallSnapshotResponse`) assume `lock` is already held — taking
    // it there would self-deadlock the lock rather than add a safety margin.
    // `deliverStagedRound` is the opposite: it is phase 2 of `flushOutgoing`
    // and assumes the lock is **not** held, touching only the staging buffers
    // and init-time-immutable fields.
    //
    // ── Absolute index ⇄ position ───────────────────────────────────────────
    //
    // `log` holds only the entries **after** the snapshot: the entry with
    // absolute index `i` sits at `log.items[i - last_included_index - 1]`, and
    // `log.items.len` is a *count*, not the last index. Every position
    // computation in this file goes through the three helpers below — an
    // off-by-one here is what made `compactLog` unusable in production (the
    // send path read `log.items[next-1]` as if the log still started at 1).

    /// Absolute index of the newest entry, compacted or live. `0` when the
    /// node holds nothing at all.
    fn lastLogIndex(self: *const Self) u64 {
        return self.last_included_index + @as(u64, @intCast(self.log.items.len));
    }

    /// Term of the newest entry; the snapshot's term when the live log is
    /// empty, `0` when the node holds nothing at all.
    fn lastLogTerm(self: *const Self) u64 {
        if (self.log.items.len > 0) return self.log.items[self.log.items.len - 1].term;
        return self.last_included_term;
    }

    /// Term of absolute index `index`, or null when it is unavailable: `0`
    /// reads as the conventional pre-log term, the boundary reads as
    /// `last_included_term`, and anything below the boundary or past the tail
    /// is unknown (compacted away / not yet replicated).
    fn termAt(self: *const Self, index: u64) ?u64 {
        if (index == 0) return 0;
        if (index == self.last_included_index) return self.last_included_term;
        if (index < self.last_included_index) return null;
        const pos = index - self.last_included_index; // 1-based position
        if (pos > self.log.items.len) return null;
        return self.log.items[pos - 1].term;
    }

    /// Drive one leader round synchronously: stage (locked) → deliver
    /// (unlocked) → apply (locked) — the same pieces `flushOutgoing`'s leader
    /// half runs, minus the due/owed check and the `flush_active`
    /// single-flight. The tests below call it directly to drive rounds by hand;
    /// production reaches the pieces through `flushOutgoing` only.
    fn sendAppendEntries(self: *Self) !void {
        const round_term = blk: {
            self.lock.acquire();
            defer self.lock.release();
            break :blk try self.stageLeaderRoundLocked();
        };
        self.deliverStagedRound(round_term);
        self.lock.acquire();
        defer self.lock.release();
        self.applyStagedRoundLocked(round_term);
    }

    /// Phase 1 for a leader round (lock held): decide each peer's next frame
    /// and stage it self-contained — entry commands as arena copies, and for a
    /// follower lagging into the snapshot, one shared copy of the snapshot
    /// bytes. Returns the term the round is built on; phase 3 re-checks it
    /// before applying anything.
    fn stageLeaderRoundLocked(self: *Self) !u64 {
        _ = self.outbound_arena.reset(.retain_capacity);
        self.staged_items.clearRetainingCapacity();
        const arena = self.outbound_arena.allocator();

        // One copy per round, shared by every snapshot-bound peer: phase 2 must
        // not send `snapshot_data` itself — an inbound InstallSnapshot (or a
        // local compaction) can free and replace it while frames are in flight.
        var snapshot_copy: ?[]const u8 = null;

        for (self.peers.items) |peer| {
            const next_idx = self.next_index.get(peer.id) orelse blk: {
                // Initialize if missing
                const idx: u64 = self.lastLogIndex() + 1;
                self.next_index.put(peer.id, idx) catch continue;
                break :blk idx;
            };

            // §7: what this follower needs next has already been compacted into
            // the snapshot — no AppendEntries can match below the boundary
            // (the entries are gone), so the snapshot itself goes instead, and
            // the next round resumes AppendEntries at `last_included_index + 1`
            // once the follower has installed it.
            if (next_idx <= self.last_included_index) {
                if (snapshot_copy == null) {
                    snapshot_copy = try arena.dupe(u8, self.snapshot_data orelse "");
                }
                try self.staged_items.append(self.allocator, .{
                    .peer = peer,
                    .kind = .install_snapshot,
                    .snapshot_index = self.last_included_index,
                    .snapshot_term = self.last_included_term,
                    .snapshot_bytes = snapshot_copy.?,
                });
                continue;
            }

            // Build entries slice: from the first live entry the follower is
            // missing to the end of the log, capped so a lagging follower is
            // fed in `max_append_entries` chunks instead of one RPC carrying
            // everything. The following round picks up where this one stopped
            // (`next_index` = last entry sent + 1). A cap of 0 would ship empty
            // rounds forever and never advance `next_index`, so it is read as
            // "one entry per round".
            const start: usize = @intCast(next_idx - self.last_included_index); // 1-based position of the first entry to send
            const pending: []const LogEntry = if (start <= self.log.items.len)
                self.log.items[start - 1 ..]
            else
                &.{};
            const batch_max = @max(@as(usize, 1), self.config.max_append_entries);
            const batch: []const LogEntry = if (pending.len > batch_max)
                pending[0..batch_max]
            else
                pending;

            // Deep-copy the batch: phase 2 runs with the lock released, and an
            // inbound AppendEntries may truncate exactly these entries and free
            // their commands while the frame is on the wire.
            const entries = try arena.alloc(LogEntry, batch.len);
            for (batch, 0..) |entry, i| {
                entries[i] = .{
                    .term = entry.term,
                    .index = entry.index,
                    .command = try arena.dupe(u8, entry.command),
                };
            }

            var prev_log_idx: u64 = 0;
            var prev_log_term: u64 = 0;
            if (next_idx > 1) {
                prev_log_idx = next_idx - 1;
                // Boundary hit → the snapshot's `last_included_term` (the
                // follower's §5.3 check matches it against its own boundary); a
                // live entry → its own term. `next_idx > last_included_index`
                // in this branch, so `termAt` misses only when `next_index`
                // outran the tail — the follower then rejects and the
                // backtracking in phase 3 repairs the map.
                prev_log_term = self.termAt(prev_log_idx) orelse 0;
            }

            try self.staged_items.append(self.allocator, .{
                .peer = peer,
                .kind = .append_entries,
                .prev_log_index = prev_log_idx,
                .prev_log_term = prev_log_term,
                .entries = entries,
                .leader_commit = self.commit_index,
            });
        }
        return self.current_term;
    }

    /// Phase 2: deliver everything phase 1 staged, **without the lock**. Reads
    /// only the staging buffers (single-tenant under `flush_active`) and fields
    /// that are immutable after `init` (`local_id`, `config`, `transport`) —
    /// `peers` is *not* read here: the vote fan-out iterates `staged_peers`, the
    /// per-peer rounds carry their own `Peer` copy. A reply with a higher term
    /// ends the round early: everything after it would be stale on arrival.
    fn deliverStagedRound(self: *Self, round_term: u64) void {
        if (self.staged_vote) |vr| {
            self.staged_vote = null;
            for (self.staged_peers.items) |p| {
                self.transport.*.sendVoteRequest(p.id, p.address, vr);
            }
        }
        round: for (self.staged_items.items) |*item| {
            switch (item.kind) {
                .append_entries => {
                    const resp = self.transport.*.sendAppendEntries(item.peer.id, item.peer.address, .{
                        .term = round_term,
                        .leader_id = self.local_id,
                        .prev_log_index = item.prev_log_index,
                        .prev_log_term = item.prev_log_term,
                        .entries = item.entries,
                        .leader_commit = item.leader_commit,
                    });
                    item.resp = resp;
                    if (resp.term > round_term) break :round;
                },
                .install_snapshot => {
                    // The chunk loop, over the staged copy. A reply in another
                    // term (stale or higher) cuts the transfer; the next round
                    // restarts it from `offset = 0`.
                    const snap = item.snapshot_bytes;
                    // u16 length prefix on the wire (`RaftTransport.putStr`) —
                    // the clamp is the wire format's, not a tuning choice.
                    const chunk = @min(@max(@as(usize, 1), self.config.snapshot_chunk_bytes), std.math.maxInt(u16));
                    var offset: usize = 0;
                    while (true) {
                        const end = @min(snap.len, offset + chunk);
                        const done = end == snap.len;
                        const resp = self.transport.*.sendInstallSnapshot(item.peer.id, item.peer.address, .{
                            .term = round_term,
                            .leader_id = self.local_id,
                            .last_included_index = item.snapshot_index,
                            .last_included_term = item.snapshot_term,
                            .offset = @intCast(offset),
                            .data = snap[offset..end],
                            .done = done,
                        });
                        item.snapshot_resp_term = resp.term;
                        if (resp.term != round_term) break;
                        if (done) {
                            item.snapshot_completed = true;
                            break;
                        }
                        offset = end;
                    }
                    if ((item.snapshot_resp_term orelse round_term) > round_term) break :round;
                },
            }
        }
    }

    /// Phase 3 (lock held): apply what phase 2 collected. The term half of a
    /// reply always applies — a higher term steps the node down wherever it
    /// came from. The bookkeeping half applies only while the round is still
    /// ours (`state == .leader` and `current_term == round_term`); otherwise
    /// the rest of the batch is dropped wholesale — between the phases an
    /// inbound RPC may have moved the term, demoted us, or re-elected us, and a
    /// stale round's bookkeeping is worse than none. `next_index` /
    /// `match_index` are read and written only here: nothing about them crosses
    /// the phases, so with the guard there is nothing left to argue about.
    fn applyStagedRoundLocked(self: *Self, round_term: u64) void {
        for (self.staged_items.items) |*item| {
            const resp_term: u64 = switch (item.kind) {
                .append_entries => (item.resp orelse continue).term,
                .install_snapshot => item.snapshot_resp_term orelse continue,
            };
            if (resp_term > self.current_term) {
                self.current_term = resp_term;
                self.state = .follower;
                break; // the rest of the round died with it
            }
            if (self.state != .leader or self.current_term != round_term) break;

            const peer_id = self.peerId(item.peer.id) orelse continue;
            switch (item.kind) {
                .append_entries => {
                    const resp = item.resp.?;
                    if (resp.success) {
                        // Update match_index and next_index. The follower's own
                        // `match_index` is the floor: it applies at most
                        // `max_append_entries` of what it was sent (see
                        // `handleAppendEntries`), so trusting "what we sent" over
                        // "what it acknowledged" would record entries as
                        // replicated that the follower never appended — and
                        // `advanceCommitIndex` commits on `match_index`. `@min`
                        // is a no-op whenever the follower took the whole batch,
                        // and an empty batch acknowledges `prev_log_index` (a
                        // follower that accepted it has at least that).
                        const sent_last: u64 = if (item.entries.len > 0)
                            item.entries[item.entries.len - 1].index
                        else
                            item.prev_log_index;
                        const matched: u64 = @min(sent_last, resp.match_index);
                        self.next_index.put(peer_id, matched + 1) catch |err| std.log.err("[RaftElection] next_index update failed: {}", .{err});
                        self.match_index.put(peer_id, matched) catch |err| std.log.err("[RaftElection] match_index update failed: {}", .{err});
                    } else if (item.prev_log_index > 0) {
                        // Fast backtracking with the follower's hint.
                        // `prev_log_index + 1` is the `next_idx` the request was
                        // built from; a backtrack that lands at/below the
                        // snapshot boundary is the snapshot branch next round,
                        // not a wedge.
                        const next_idx = item.prev_log_index + 1;
                        const back = if (resp.match_index > 0)
                            @min(next_idx - 1, resp.match_index + 1)
                        else
                            next_idx - 1;
                        self.next_index.put(peer_id, back) catch |err| std.log.err("[RaftElection] next_index backtrack failed: {}", .{err});
                    }
                },
                .install_snapshot => {
                    if (!item.snapshot_completed) continue;
                    // The boundary moved while the transfer was out (a local
                    // compaction, or an inbound snapshot): the reply is stale —
                    // its term half above was its only effect.
                    if (item.snapshot_index != self.last_included_index) continue;
                    self.processInstallSnapshotResponse(.{ .term = resp_term }, item.peer.id);
                },
            }
        }

        // Entries held by a quorum are committed (§5.3/§5.4); the next round
        // carries the new leader_commit to the followers.
        if (self.state == .leader and self.current_term == round_term) self.advanceCommitIndex();
    }

    /// Advance commit_index if a majority of peers have replicated an entry
    /// from the current term (§5.3, §5.4). Absolute coordinates: entries at or
    /// below the snapshot boundary are committed by construction, so the scan
    /// starts past both.
    fn advanceCommitIndex(self: *Self) void {
        var n: u64 = @max(self.commit_index, self.last_included_index) + 1;
        while (n <= self.lastLogIndex()) : (n += 1) {
            // Only commit entries from the current term (§5.4.2)
            if ((self.termAt(n) orelse continue) != self.current_term) continue;

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

    /// Truncate the log to keep only the first `keep_count` **live** entries
    /// (a position count, not an absolute index — the snapshot below
    /// `last_included_index` is never touched).
    fn truncateLog(self: *Self, keep_count: u64) void {
        while (self.log.items.len > keep_count) {
            if (self.log.pop()) |entry| {
                self.allocator.free(entry.command);
            }
        }
    }

    /// Start a new election.
    ///
    /// Tallying convention: `votes_received` counts **peer grants**, and the
    /// candidate's own vote is added on top of them (`handleVoteResponse` and
    /// `hasQuorum` carry the +1) — so the tally is an ordinary majority of
    /// `clusterSize()`. A cluster of one has no peer to ask — its own vote is the
    /// entire majority (`quorumSize() == 1`), so that election is won immediately
    /// instead of waiting for a ballot that can never arrive.
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

        const last_idx: u64 = self.lastLogIndex();
        const last_term = self.lastLogTerm();

        // The ballots go out in `flushOutgoing`'s phase 2, with the lock
        // released — this only stages them. The request is values plus
        // `local_id` (which outlives the round); the peer list is copied because
        // `addPeer` may regrow `peers` while the fan-out is on the wire.
        self.staged_vote = .{
            .term = self.current_term,
            .candidate_id = self.local_id,
            .last_log_index = last_idx,
            .last_log_term = last_term,
        };
        self.staged_peers.clearRetainingCapacity();
        self.staged_peers.appendSlice(self.allocator, self.peers.items) catch |err| {
            // A short staging loses ballots, not the election: the deadline is
            // already reset, so the next expiry re-stages from scratch.
            std.log.err("[RaftElection] vote fan-out staging failed, partial ballots this round: {}", .{err});
        };
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
        const last_log_idx: u64 = self.lastLogIndex();
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

        // The initial heartbeat is owed, not sent: this runs under `lock` (via
        // `startElection` or `handleVoteResponse`), and outbound IO no longer
        // happens under it. Whoever promoted us flushes after releasing the
        // lock (`tick` is a `flushOutgoing`; `handleVoteResponse` calls it on
        // the way out).
        self.heartbeat_owed = true;
    }

    /// The bookkeeping half of an InstallSnapshot reply. Assumes `lock` held;
    /// the locking entry points are the public `handleInstallSnapshotResponse`
    /// (a reply arriving out of band) and `applyStagedRoundLocked` (the
    /// synchronous send path's phase 3).
    fn processInstallSnapshotResponse(self: *Self, resp: InstallSnapshotResponse, from_peer: []const u8) void {
        if (resp.term > self.current_term) {
            self.current_term = resp.term;
            self.state = .follower;
            return;
        }
        if (self.state != .leader) return;
        if (resp.term != self.current_term) return; // a reply to an older term's snapshot
        const peer_id = self.peerId(from_peer) orelse return;
        // The reply carries only a term, so "what was installed" is what we
        // sent: the snapshot boundary this node currently holds (stable under
        // the lock across the send).
        self.match_index.put(peer_id, self.last_included_index) catch |err| std.log.err("[RaftElection] match_index update after snapshot failed: {}", .{err});
        self.next_index.put(peer_id, self.last_included_index + 1) catch |err| std.log.err("[RaftElection] next_index update after snapshot failed: {}", .{err});
    }

    /// §7: compact the committed prefix once the live log outgrows
    /// `snapshot_threshold_entries`. Called from `tick()` on the leader with
    /// `lock` held. Never crosses `commit_index`.
    fn maybeCompactLog(self: *Self) !void {
        const threshold = self.config.snapshot_threshold_entries;
        if (threshold == 0) return;
        if (self.log.items.len <= threshold) return;
        // Nothing new to fold in: the committed prefix is already snapshotted.
        if (self.commit_index <= self.last_included_index) return;

        const up_to = self.commit_index;
        const bytes = if (self.config.snapshotter) |snapshotter|
            try snapshotter(self.config.snapshotter_ctx, up_to, self.allocator)
        else
            try self.defaultSnapshotBytes(up_to);
        defer self.allocator.free(bytes);
        try self.compactLogLocked(up_to, bytes);
    }

    /// The no-`snapshotter` snapshot: a parseable debug summary of what was
    /// folded in. **Placeholder semantics** — the framework has no application
    /// state machine, so restoring application state from these bytes is not a
    /// thing; apps that need real snapshots supply `ElectionConfig.snapshotter`.
    fn defaultSnapshotBytes(self: *const Self, up_to_index: u64) ![]u8 {
        const term = self.termAt(up_to_index) orelse 0;
        return self.allocator.print("zigmodu-raft-snapshot:v1:last_included_index={d}:last_included_term={d}:compacted_entries={d}", .{
            up_to_index,
            term,
            up_to_index - self.last_included_index,
        });
    }

    /// Handle a vote response from a peer. Granted votes are tallied per term
    /// and deduplicated by peer id; the candidate becomes leader only once the
    /// tally reaches `quorumSize()` (the same peer-vote convention
    /// `hasQuorum(votes_received)` documents). A cluster of one never gets here
    /// — `startElection` elects it on the self-vote alone.
    ///
    /// Holds `lock` for the tally only: a tally that reaches quorum promotes
    /// the node mid-call (`becomeLeader` frees `leader_id`, resets the per-peer
    /// maps, and registers the owed initial heartbeat), and the term check it
    /// starts with is the same field the ticker writes. The flush after the
    /// locked section is what actually sends that heartbeat — outbound IO stays
    /// off the lock.
    pub fn handleVoteResponse(self: *Self, resp: VoteResponse, from_peer: []const u8) !void {
        locked: {
            self.lock.acquire();
            defer self.lock.release();

            if (resp.term > self.current_term) {
                self.current_term = resp.term;
                self.state = .follower;
                self.votes_received.clearRetainingCapacity();
                break :locked;
            }

            if (self.state != .candidate) break :locked;
            if (resp.term < self.current_term) break :locked; // ballot from a past election
            if (!resp.vote_granted) break :locked;

            // Only configured cluster members count. The map key borrows the
            // peer's stored id, which outlives the (often arena-owned) `from_peer`.
            const peer_id = self.peerId(from_peer) orelse break :locked;
            try self.votes_received.put(peer_id, {});

            // `+ 1` is the candidate's **own** vote: `startElection` set
            // `voted_for = local_id` before asking anyone, and `quorumSize()` counts the
            // whole cluster (it is `clusterSize() / 2 + 1`, and `clusterSize()` includes
            // self). Without it the tally demanded `quorumSize()` *peers* on top of self,
            // i.e. one vote more than a Raft majority — which made N=2 unreachable
            // outright (quorumSize 2, one peer) and cost every larger cluster a node of
            // fault tolerance. `hasQuorum` below carries the same `+ 1`.
            if (@as(usize, self.votes_received.count()) + 1 >= self.quorumSize()) {
                self.becomeLeader();
            }
        }

        // Push out whatever the tally made pending — a won election's first
        // heartbeat — without holding the lock across IO. A failure loses the
        // *immediate* push only: the next due tick flushes the rest.
        self.flushOutgoing() catch |err| std.log.err("[RaftElection] post-vote flush failed: {}", .{err});
    }

    /// Leader consumes an InstallSnapshot reply (§7). The synchronous send path
    /// (`flushOutgoing` phase 2/3) feeds replies through
    /// `processInstallSnapshotResponse` directly; this is the entry point for a
    /// reply that arrives out of band (e.g. an async transport). The reply itself
    /// carries only a term, so the
    /// caller names the snapshot it belongs to: `last_included_index` that does
    /// not match the snapshot this node currently holds is a stale answer — only
    /// the term half of it still applies.
    ///
    /// Holds `lock`: on success it rewrites `next_index` / `match_index`, and a
    /// higher term steps the node down — both are the same writes the ticker
    /// makes.
    pub fn handleInstallSnapshotResponse(self: *Self, resp: InstallSnapshotResponse, from_peer: []const u8, last_included_index: u64) !void {
        self.lock.acquire();
        defer self.lock.release();

        if (last_included_index != self.last_included_index) {
            if (resp.term > self.current_term) {
                self.current_term = resp.term;
                self.state = .follower;
            }
            return;
        }
        self.processInstallSnapshotResponse(resp, from_peer);
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

    /// Get log entry by **absolute** 1-based index, or null when out of range —
    /// which includes indices folded into the snapshot (`<= last_included_index`):
    /// those entries no longer exist individually.
    ///
    /// The lock makes the lookup whole, but the returned entry's `command`
    /// borrows the log: it is valid only until the next call into this raft.
    pub fn getLogEntry(self: *Self, index: u64) ?LogEntry {
        self.lock.acquire();
        defer self.lock.release();
        if (index == 0 or index <= self.last_included_index) return null;
        const pos = index - self.last_included_index;
        if (pos > self.log.items.len) return null;
        return self.log.items[pos - 1];
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

    // ── A-3: runtime key rotation & revocation ──────────────────────────────
    //
    // The operational half of per-node identity (the read half is in
    // `RaftTransport`): `SecretsManager` stays the source of truth — these are
    // the hooks an operator (or a secrets watcher) calls when a key changes.
    // Every one of them holds `key_lock` for its whole rebuild, so a reader on
    // the accept thread or in `tick`'s outbound round always sees a whole
    // table; see the `key_lock` field for the discipline. None of them touches
    // the wire format: a frame is still `[len][tag][payload][mac]`, and the
    // rotation window lives entirely in *which key verifies*.
    //
    // The three-phase, no-partition rotation sequence for node B's key
    // (K1 → K2), spelled out in `docs/DISTRIBUTED.md` §"密钥轮换与撤销":
    //   1. every peer: `rotatePeerKey(B, K2)` — K2 is current, K1 still verifies;
    //   2. B: `rotateOwnKey(K2)` — B's frames now sign with K2 and verify
    //      everywhere as current; in-flight K1 frames verify as previous;
    //   3. every peer: `setPeerKey(B, K2)` or `dropPreviousPeerKey(B)` — the
    //      window closes, K1 stops verifying.

    /// Replace this node's own signing key. Frames signed after the swap carry
    /// `new_key`; a receiver whose window still covers the old key
    /// (`PeerKey.previous`) keeps verifying the in-flight old-signed frames.
    pub fn rotateOwnKey(self: *Self, new_key: [32]u8) void {
        self.key_lock.acquire();
        defer self.key_lock.release();
        self.config.own_key = new_key;
    }

    /// Set (or overwrite) `peer_id`'s credential, closing any open rotation
    /// window (`previous` cleared). For a rotation that keeps the old key
    /// acceptable while peers catch up, use `rotatePeerKey` instead.
    pub fn setPeerKey(self: *Self, peer_id: []const u8, key: [32]u8) !void {
        self.key_lock.acquire();
        defer self.key_lock.release();
        if (self.peerKeyEntry(peer_id)) |pk| {
            pk.key = key;
            pk.previous = null;
            return;
        }
        try self.appendPeerKeyLocked(peer_id, key);
    }

    /// Rotate `peer_id`'s credential: `new_key` becomes the current key and the
    /// old current moves to `previous`, so frames signed with either verify
    /// until the window is closed (`setPeerKey` / `dropPreviousPeerKey`). An
    /// unknown id is upserted with no window (there is no old key to keep).
    pub fn rotatePeerKey(self: *Self, peer_id: []const u8, new_key: [32]u8) !void {
        self.key_lock.acquire();
        defer self.key_lock.release();
        if (self.peerKeyEntry(peer_id)) |pk| {
            pk.previous = pk.key;
            pk.key = new_key;
            return;
        }
        try self.appendPeerKeyLocked(peer_id, new_key);
    }

    /// Close `peer_id`'s rotation window: frames signed with the previous key
    /// stop verifying. True when the entry exists (the post-state is "no
    /// previous" either way); false for an unknown id.
    pub fn dropPreviousPeerKey(self: *Self, peer_id: []const u8) bool {
        self.key_lock.acquire();
        defer self.key_lock.release();
        const pk = self.peerKeyEntry(peer_id) orelse return false;
        pk.previous = null;
        return true;
    }

    /// Revoke `peer_id`'s credential outright: the entry leaves the table, so
    /// an inbound frame claiming that id fails the key lookup in
    /// `RaftTransport.handleConnection`, and an outbound RPC to it is lost in
    /// `outboundKeys` before the dial — both already fail-closed paths. True
    /// when the entry existed. There is no live connection to close: Raft RPCs
    /// are one short connection per call, so the next frame from the revoked
    /// peer is refused at the verify step and nothing lingers (the bus's
    /// long-lived connections are why `DistributedEventBus.removePeerKey` has a
    /// `disconnectNode` half instead).
    ///
    /// `error.OutOfMemory` means the rebuild failed and **nothing changed** —
    /// the entry is still in place and the call may be retried; refusing to
    /// report it would leave an operator believing a revoked key is dead.
    pub fn revokePeerKey(self: *Self, peer_id: []const u8) error{OutOfMemory}!bool {
        self.key_lock.acquire();
        defer self.key_lock.release();
        const old = self.peer_keys_mut;
        var index: ?usize = null;
        for (old, 0..) |pk, i| {
            if (std.mem.eql(u8, pk.id, peer_id)) {
                index = i;
                break;
            }
        }
        const i = index orelse return false;

        const shrunk = try self.allocator.alloc(PeerKey, old.len - 1);
        var out: usize = 0;
        for (old, 0..) |pk, j| {
            if (j == i) continue;
            shrunk[out] = pk;
            out += 1;
        }
        self.allocator.free(old[i].id);
        self.allocator.free(old);
        self.publishPeerKeysLocked(shrunk);
        return true;
    }

    /// The mutable entry for `peer_id`, or null. `key_lock` must be held — the
    /// table is rebuilt by the rotation/revocation calls above.
    fn peerKeyEntry(self: *Self, peer_id: []const u8) ?*PeerKey {
        for (self.peer_keys_mut) |*pk| {
            if (std.mem.eql(u8, pk.id, peer_id)) return pk;
        }
        return null;
    }

    /// Swap the table for a rebuilt slice. `key_lock` held by the caller; the
    /// old slice is already freed (its ids' ownership moved with the entries).
    /// Both views are re-published together — readers only ever hold one of
    /// them for the length of a `key_lock` critical section.
    fn publishPeerKeysLocked(self: *Self, new_table: []PeerKey) void {
        self.peer_keys_mut = new_table;
        self.config.peer_keys = new_table;
    }

    /// Grow the table by one entry. `key_lock` held by the caller; the id copy
    /// and the wider slice are owned by the table from here on, replacing the
    /// old slice (freed here — no reader can hold it: every reader runs inside
    /// this same lock and takes its keys by value).
    fn appendPeerKeyLocked(self: *Self, peer_id: []const u8, key: [32]u8) !void {
        const id_copy = try self.allocator.dupe(u8, peer_id);
        errdefer self.allocator.free(id_copy);
        const old = self.peer_keys_mut;
        const grown = try self.allocator.alloc(PeerKey, old.len + 1);
        @memcpy(grown[0..old.len], old);
        grown[old.len] = .{ .id = id_copy, .key = key, .previous = null };
        self.allocator.free(old);
        self.publishPeerKeysLocked(grown);
    }

    /// Get current state
    /// Log compaction: discard entries up to `up_to_index` (absolute) and
    /// retain `snapshot_data`. The boundary must be **committed** — folding an
    /// uncommitted entry into a snapshot is what makes a minority's uncommitted
    /// state survivable, which Raft forbids — so `up_to_index > commit_index`
    /// is refused rather than clipped.
    ///
    /// Holds `lock`: it frees the entries it discards and compacts `log` under
    /// the readers of both.
    pub fn compactLog(self: *Self, up_to_index: u64, snapshot_bytes: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();
        try self.compactLogLocked(up_to_index, snapshot_bytes);
    }

    /// The lock-held body of `compactLog` (also what `maybeCompactLog` calls
    /// from inside `tick`).
    fn compactLogLocked(self: *Self, up_to_index: u64, snapshot_bytes: []const u8) !void {
        if (up_to_index <= self.last_included_index) return;
        if (up_to_index > self.commit_index) return error.NotCommitted;
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
    ///
    /// Chunks: `offset == 0` starts a transfer, a continuation must name the
    /// same `(last_included_index, last_included_term)` and land at exactly the
    /// assembled length (anything else drops the partial buffer and the
    /// leader's next round restarts it), and `done` applies. Applying **retains
    /// the log suffix** when it continues the snapshot — the entry at
    /// `last_included_index` exists with the same term (§7: "If existing log
    /// entry has same index and term as snapshot's last included entry, retain
    /// log entries following it and reply") — and wipes the log otherwise.
    pub fn handleInstallSnapshot(self: *Self, req: InstallSnapshotRequest) !InstallSnapshotResponse {
        self.lock.acquire();
        defer self.lock.release();

        if (req.term < self.current_term) {
            return InstallSnapshotResponse{ .term = self.current_term };
        }

        // Same check as `handleAppendEntries`, and this is the path that can wipe
        // the whole log, so an unknown sender must be refused before anything
        // moves — term, state and (below) `log` are all reachable from here.
        if (!std.mem.eql(u8, req.leader_id, self.local_id) and self.peerId(req.leader_id) == null) {
            return InstallSnapshotResponse{ .term = self.current_term };
        }

        if (req.term > self.current_term) {
            self.current_term = req.term;
        }
        self.state = .follower;

        // A snapshot from the leader is leader contact, same as an
        // AppendEntries: reset the election clock and record who leads. Both
        // were missing here — the handler moved the term and wiped the log but
        // left the deadline (and `getLeader()`) stale.
        const now_ms = Time.monotonicNowMilliseconds();
        self.last_heartbeat_ms = now_ms;
        self.election_deadline_ms = now_ms + @as(i64, @intCast(self.randomElectionTimeout()));
        const leader_copy = try self.allocator.dupe(u8, req.leader_id);
        if (self.leader_id) |l| {
            if (l.ptr != self.local_id.ptr) self.allocator.free(l);
        }
        self.leader_id = leader_copy;

        // Chunk assembly. A mismatching continuation is dropped, not applied:
        // the sender restarts at `offset = 0` on its next attempt.
        if (req.offset == 0) {
            self.pending_snapshot.clearRetainingCapacity();
            self.pending_snapshot_index = req.last_included_index;
            self.pending_snapshot_term = req.last_included_term;
        } else {
            if (req.last_included_index != self.pending_snapshot_index or
                req.last_included_term != self.pending_snapshot_term or
                req.offset != self.pending_snapshot.items.len)
            {
                self.pending_snapshot.clearRetainingCapacity();
                return InstallSnapshotResponse{ .term = self.current_term };
            }
        }
        try self.pending_snapshot.appendSlice(self.allocator, req.data);
        if (!req.done) return InstallSnapshotResponse{ .term = self.current_term };
        defer self.pending_snapshot.clearRetainingCapacity();

        if (req.last_included_index > self.last_included_index) {
            // Allocate the snapshot **first**: everything below this line is
            // destructive (it frees log entries), so the old order left a
            // dangling `snapshot_data` *and* a wiped log when the dupe failed —
            // the node came back with no snapshot and no log.
            const snap_copy = try self.allocator.dupe(u8, self.pending_snapshot.items);

            // §7 suffix retention: the entry at the snapshot boundary exists and
            // matches `last_included_term` → the log *continues* the snapshot,
            // so only the covered prefix is dropped. Otherwise (gap, or a term
            // that disagrees) the log cannot be trusted to follow the snapshot
            // and is wiped wholesale.
            const covered: usize = @intCast(req.last_included_index - self.last_included_index);
            const drop_count: usize = if (covered <= self.log.items.len and
                self.termAt(req.last_included_index) == req.last_included_term)
                covered
            else
                self.log.items.len;

            for (0..drop_count) |i| {
                self.allocator.free(self.log.items[i].command);
            }
            const remaining = self.log.items.len - drop_count;
            if (remaining > 0) {
                std.mem.copyForwards(LogEntry, self.log.items[0..remaining], self.log.items[drop_count..]);
            }
            self.log.items.len = remaining;

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

    /// Check if `votes_received` **peer** grants meet quorum.
    ///
    /// The candidate's own vote is not in `votes_received` (it is not a grant that
    /// arrived over the wire), but it *is* one of the `quorumSize()` votes a Raft
    /// majority is made of — `clusterSize()` counts self, and `startElection` has
    /// already voted for itself. So the +1 here is that vote, and the tally matches
    /// a plain majority: N=2 needs 1 peer, N=3 needs 1, N=5 needs 2.
    ///
    /// A cluster of one never wins through this path: `startElection` elects it
    /// outright, since there is no peer whose ballot could ever arrive.
    /// Lock-free, see `clusterSize`.
    pub fn hasQuorum(self: *const Self, votes_received: usize) bool {
        return votes_received + 1 >= self.quorumSize();
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
                .sendInstallSnapshot = noopInstallSnapshot,
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    // The leader whose heartbeat is replayed below has to be a configured member:
    // `handleAppendEntries` now refuses a `leader_id` that is neither a peer nor
    // this node (docs/dev/cluster-auth-design.md §4.1).
    var peers = [_]Peer{.{ .id = "leader1", .address = "" }};
    var election = try RaftElection.init(
        allocator,
        "node1",
        &peers,
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    // `leader1` is a configured member: the seeded request below is a real leader's
    // AppendEntries, which the membership check must let through before the
    // malformed entry in it is reached (docs/dev/cluster-auth-design.md §4.1).
    var peers = [_]Peer{.{ .id = "leader1", .address = "" }};
    var election = try RaftElection.init(allocator, "node1", &peers, .{}, &transport);
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    // Backed by `testing.allocator`, so a double free is reported rather than
    // silently reusing the block.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();

    // The candidate is a configured member, so the grant path below (the re-dupe of
    // `voted_for`) is reached at all — an unlisted id gets no ballot
    // (docs/dev/cluster-auth-design.md §4.1).
    var peers = [_]Peer{.{ .id = "c1", .address = "" }};
    var election = try RaftElection.init(allocator, "node1", &peers, .{}, &transport);
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    // A vote is granted only to a configured member, so the candidate under test
    // (a fresh, up-to-date log) has to be one — docs/dev/cluster-auth-design.md §4.1.
    var peers = [_]Peer{.{ .id = "candidate1", .address = "" }};
    var election = try RaftElection.init(
        allocator,
        "node1",
        &peers,
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    // Both candidates are configured members, so the second request below is
    // refused for its **term** — not merely for being unknown, which would make this
    // pass for the wrong reason (docs/dev/cluster-auth-design.md §4.1).
    var peers = [_]Peer{
        .{ .id = "c1", .address = "" },
        .{ .id = "c2", .address = "" },
    };
    var election = try RaftElection.init(allocator, "node-a", &peers, .{}, &transport);
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    var e1 = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e1.deinit();
    // `n1` is one of `n2`'s peers: a vote request from a node that is not a
    // configured member is denied before the ballot is even considered
    // (docs/dev/cluster-auth-design.md §4.1).
    var e2_peers = [_]Peer{.{ .id = "n1", .address = "" }};
    var e2 = try RaftElection.init(allocator, "n2", &e2_peers, .{}, &transport);
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
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    // 3-node cluster: quorum = 2
    var e = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e.deinit();
    try e.addPeer("n2");
    try e.addPeer("n3");

    try testing.expectEqual(@as(usize, 3), e.clusterSize());
    try testing.expectEqual(@as(usize, 2), e.quorumSize());
    // `votes_received` counts **peers**, and the candidate's own vote is added on
    // top of it, so 1 peer grant is already a majority of 3. This assertion used to
    // be `!hasQuorum(1)` — the off-by-one that made N=2 unreachable and cost every
    // larger cluster a node of fault tolerance (docs/dev/cluster-auth-design.md §12).
    try testing.expect(e.hasQuorum(1));
    try testing.expect(!e.hasQuorum(0));

    // 5-node cluster: quorum = 3, so 2 peer grants are a majority.
    var e5 = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e5.deinit();
    try e5.addPeer("n2");
    try e5.addPeer("n3");
    try e5.addPeer("n4");
    try e5.addPeer("n5");
    try testing.expectEqual(@as(usize, 5), e5.clusterSize());
    try testing.expectEqual(@as(usize, 3), e5.quorumSize());
    try testing.expect(e5.hasQuorum(2));
    try testing.expect(!e5.hasQuorum(1));

    // 2-node cluster: quorum = 2, and its single peer's grant is enough — the case
    // that was structurally impossible before the fix.
    var e2 = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e2.deinit();
    try e2.addPeer("n2");
    try testing.expectEqual(@as(usize, 2), e2.clusterSize());
    try testing.expectEqual(@as(usize, 2), e2.quorumSize());
    try testing.expect(e2.hasQuorum(1));
    try testing.expect(!e2.hasQuorum(0));

    // Single node: `startElection` elects it outright (no peer ballot can arrive),
    // so 0 peer grants is already quorum.
    var e1 = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer e1.deinit();
    try testing.expectEqual(@as(usize, 1), e1.clusterSize());
    try testing.expectEqual(@as(usize, 1), e1.quorumSize());
    try testing.expect(e1.hasQuorum(0));
}

// Verified red: reverting the `+ 1` in `handleVoteResponse` makes this fail on the
// `isLeader()` assertion with `expected true, found false`. A 2-node cluster's single
// peer can never supply the two *peer* grants the old tally demanded — `quorumSize()`
// is 2 and there is exactly one peer — so the node stayed a candidate forever. That
// was measured before the fix, not inferred:
//   [PROBE] N=2 clusterSize=2 quorumSize=2
//   [PROBE] after 1/1 peer grants: leader=false
test "a 2-node cluster elects a leader with its single peer's grant" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    var peers = [_]Peer{.{ .id = "node-b", .address = "" }};
    var e = try RaftElection.init(allocator, "node-a", &peers, .{}, &transport);
    defer e.deinit();

    try testing.expectEqual(@as(usize, 2), e.clusterSize());
    try testing.expectEqual(@as(usize, 2), e.quorumSize());

    try e.startElection();
    try testing.expectEqual(RaftState.candidate, e.getState());
    try testing.expect(!e.isLeader());

    // The one peer grants. Self + that grant is a majority of two.
    try e.handleVoteResponse(.{ .term = e.getTerm(), .vote_granted = true }, "node-b");
    try testing.expect(e.isLeader());
}

// The join path, not the `init` peer list: this is what `ClusterBootstrap.start()`
// does — `addPeer(p.id)` with the name the peer answers votes under. A peer added
// under its *address* instead (`addPeer("127.0.0.1")`) has every ballot dropped by
// `peerId()`, so the node below would stay a candidate forever
// (docs/dev/cluster-auth-design.md §10).
test "a raft whose peers were added by id elects a leader (the ClusterBootstrap wiring)" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&transport_impl)));

    var e = try RaftElection.init(allocator, "node-a", &.{}, .{}, &transport);
    defer e.deinit();
    try e.addPeer("node-b");

    try testing.expectEqual(@as(usize, 2), e.clusterSize());
    try e.startElection();
    try testing.expectEqual(RaftState.candidate, e.getState());
    try testing.expect(!e.isLeader());

    try e.handleVoteResponse(.{ .term = e.getTerm(), .vote_granted = true }, "node-b");
    try testing.expect(e.isLeader());
}

test "RaftElection vote counting: leader only at quorum, duplicate and stale votes ignored" {
    const allocator = testing.allocator;

    // Five nodes, not three: `quorumSize()` is 3 and the self-vote is one of them, so
    // a candidate needs **two** peer grants. That leaves room to observe a duplicate
    // and a non-member landing in the tally *before* quorum — with three nodes the
    // first grant already wins, which is exactly why this test had been written
    // against the old off-by-one (docs/dev/cluster-auth-design.md §12).
    var cluster = try TestCluster.init(allocator, 5);
    defer cluster.deinit();

    var cand = &cluster.nodes.items[0].election;

    // Become a candidate for term 1 (vote requests go to the stub transport).
    try cand.startElection();
    try testing.expectEqual(RaftState.candidate, cand.getState());
    try testing.expectEqual(@as(u64, 1), cand.getTerm());
    try testing.expectEqual(@as(usize, 3), cand.quorumSize());

    // A ballot from an older term must not count.
    try cand.handleVoteResponse(.{ .term = 0, .vote_granted = true }, "n1");
    try testing.expect(!cand.isLeader());

    // First granted vote: self + n1 = 2 of 5, still short of 3.
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
    // not enough on its own — the self-vote plus one is 2 of 5, and quorum is 3.
    try cand.startElection();
    try testing.expectEqual(@as(u64, 3), cand.getTerm());
    try cand.handleVoteResponse(.{ .term = 3, .vote_granted = true }, "n1");
    try testing.expect(!cand.isLeader());
    try cand.handleVoteResponse(.{ .term = 3, .vote_granted = true }, "n2");
    try testing.expect(cand.isLeader());
}

test "RaftElection log compaction and InstallSnapshot" {
    const allocator = testing.allocator;

    const TransportImpl = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
        sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
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
        .sendInstallSnapshot = noopInstallSnapshot,
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

    // Follower handle InstallSnapshot. `node-1` is a configured member — the
    // snapshot fires on the log **both** nodes hold, and an unknown sender is now
    // refused before that path is entered (docs/dev/cluster-auth-design.md §4.1).
    var follower_peers = [_]Peer{.{ .id = "node-1", .address = "" }};
    var follower = try RaftElection.init(allocator, "node-2", &follower_peers, .{}, &transport);
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

// ── §7 production-loop tests ────────────────────────────────────────────────
//
// The tests below pin the absolute-index ⇄ position convention the compaction
// rework stands on (`log` holds only the entries after `last_included_index`),
// the leader's snapshot-send path, chunk assembly with suffix retention, and
// threshold-driven auto-compaction in `tick`. The offset arithmetic they guard
// is off-by-one fragile, so each test asserts *absolute* indices on both sides
// of a compaction boundary.

/// Captures the coordinates of each AppendEntries round (prev + batch range).
const AppendCoords = struct {
    var calls: usize = 0;
    var prev_index: u64 = 0;
    var prev_term: u64 = 0;
    var entries_len: usize = 0;
    var first_index: u64 = 0;
    var last_index: u64 = 0;

    fn reset() void {
        calls = 0;
        prev_index = 0;
        prev_term = 0;
        entries_len = 0;
        first_index = 0;
        last_index = 0;
    }

    fn accept(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
        calls += 1;
        prev_index = req.prev_log_index;
        prev_term = req.prev_log_term;
        entries_len = req.entries.len;
        first_index = if (req.entries.len > 0) req.entries[0].index else 0;
        last_index = if (req.entries.len > 0) req.entries[req.entries.len - 1].index else req.prev_log_index;
        return .{ .term = req.term, .success = true, .match_index = last_index };
    }
};

/// An AppendEntries rejection with no backtracking hint — the shape a test
/// wants when the peer must never advance the leader's `match_index`.
fn rejectAppendEntries(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
    return .{ .term = req.term, .success = false, .match_index = 0 };
}

/// Captures InstallSnapshot frames (offsets + reassembled payload) and answers
/// with the sender's own term, so a leader round completes inline.
const SnapshotCapture = struct {
    var calls: usize = 0;
    var done_calls: usize = 0;
    var offsets: [8]u64 = undefined;
    var last_included_index: u64 = 0;
    var last_included_term: u64 = 0;
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        calls = 0;
        done_calls = 0;
        last_included_index = 0;
        last_included_term = 0;
        len = 0;
    }

    fn accept(_: ?[]const u8, _: []const u8, req: InstallSnapshotRequest) InstallSnapshotResponse {
        if (calls < offsets.len) offsets[calls] = req.offset;
        calls += 1;
        last_included_index = req.last_included_index;
        last_included_term = req.last_included_term;
        if (len + req.data.len <= buf.len) {
            @memcpy(buf[len..][0..req.data.len], req.data);
            len += req.data.len;
        }
        if (req.done) done_calls += 1;
        return .{ .term = req.term };
    }

    fn assembled() []const u8 {
        return buf[0..len];
    }
};

/// A `Snapshotter` that records its invocation and hands back named bytes.
const SnapshotterProbe = struct {
    var calls: usize = 0;
    var seen_ctx: ?*anyopaque = null;
    var seen_up_to: u64 = 0;

    fn reset() void {
        calls = 0;
        seen_ctx = null;
        seen_up_to = 0;
    }

    fn snapshot(ctx: ?*anyopaque, up_to_index: u64, allocator: std.mem.Allocator) anyerror![]u8 {
        calls += 1;
        seen_ctx = ctx;
        seen_up_to = up_to_index;
        return allocator.print("app-snapshot@{d}", .{up_to_index});
    }
};

test "RaftElection compaction rebases the log: append and replication continue at absolute indices" {
    const allocator = testing.allocator;
    AppendCoords.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendCoords.accept,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    // No peers yet: a one-node leader self-commits every append.
    var raft = try RaftElection.init(allocator, "n1", &.{}, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;

    for (0..6) |i| {
        var buf: [16]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "cmd-{d}", .{i});
        try testing.expectEqual(@as(u64, i + 1), try raft.appendEntry(cmd));
    }
    try testing.expectEqual(@as(u64, 6), raft.getCommitIndex());

    try raft.compactLog(3, "snap@3");
    try testing.expectEqual(@as(u64, 3), raft.last_included_index);
    try testing.expectEqual(@as(u64, 1), raft.last_included_term);
    try testing.expectEqual(@as(usize, 3), raft.logLen());

    // The tail is boundary + live count: the next append is index 7, not 4.
    try testing.expectEqual(@as(u64, 7), try raft.appendEntry("cmd-6"));
    try testing.expect(raft.getLogEntry(3) == null);
    try testing.expectEqualStrings("cmd-3", raft.getLogEntry(4).?.command);
    try testing.expectEqualStrings("cmd-6", raft.getLogEntry(7).?.command);

    // A follower joining at the boundary gets prev = (boundary, snapshot term)
    // and the whole live suffix.
    try raft.addPeer("n2");
    const peer_key = raft.peers.items[0].id;
    try raft.next_index.put(peer_key, 4);
    try raft.match_index.put(peer_key, 3);

    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 1), AppendCoords.calls);
    try testing.expectEqual(@as(u64, 3), AppendCoords.prev_index);
    try testing.expectEqual(@as(u64, 1), AppendCoords.prev_term);
    try testing.expectEqual(@as(usize, 4), AppendCoords.entries_len);
    try testing.expectEqual(@as(u64, 4), AppendCoords.first_index);
    try testing.expectEqual(@as(u64, 7), AppendCoords.last_index);
    try testing.expectEqual(@as(u64, 8), raft.next_index.get(peer_key).?);

    // Caught up: the next round is an empty probe whose prev is the live tail.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 2), AppendCoords.calls);
    try testing.expectEqual(@as(u64, 7), AppendCoords.prev_index);
    try testing.expectEqual(@as(usize, 0), AppendCoords.entries_len);
    try testing.expectEqual(@as(u64, 8), raft.next_index.get(peer_key).?);
}

test "RaftElection AppendEntries whose prev_log sits on the snapshot boundary matches last_included_term" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = rejectAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "leader", .address = "" }};
    var raft = try RaftElection.init(allocator, "f1", &peers, .{}, &transport);
    defer raft.deinit();

    const seed_entries = [_]LogEntry{
        .{ .term = 1, .index = 1, .command = "e1" },
        .{ .term = 1, .index = 2, .command = "e2" },
        .{ .term = 1, .index = 3, .command = "e3" },
        .{ .term = 1, .index = 4, .command = "e4" },
    };
    const seed = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &seed_entries,
        .leader_commit = 4,
    });
    try testing.expect(seed.success);

    try raft.compactLog(3, "snap@3");
    try testing.expectEqual(@as(usize, 1), raft.logLen());

    // The boundary prev names the snapshot's term; a wrong term rejects and —
    // unlike a live-entry conflict — truncates nothing.
    const wrong_term = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 3,
        .prev_log_term = 9,
        .entries = &.{},
        .leader_commit = 4,
    });
    try testing.expect(!wrong_term.success);
    try testing.expectEqual(@as(usize, 1), raft.logLen());
    try testing.expectEqual(@as(u64, 3), raft.last_included_index);

    // The matching boundary term accepts; the batch replays the live entry
    // (skipped — term matches) and continues the log in absolute coordinates.
    const tail_entries = [_]LogEntry{
        .{ .term = 1, .index = 4, .command = "DIFFERENT" },
        .{ .term = 1, .index = 5, .command = "e5" },
    };
    const ok = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 3,
        .prev_log_term = 1,
        .entries = &tail_entries,
        .leader_commit = 5,
    });
    try testing.expect(ok.success);
    try testing.expectEqual(@as(u64, 5), ok.match_index);
    try testing.expectEqual(@as(usize, 2), raft.logLen());
    try testing.expectEqualStrings("e4", raft.getLogEntry(4).?.command);
    try testing.expectEqualStrings("e5", raft.getLogEntry(5).?.command);
    try testing.expectEqual(@as(u64, 5), raft.getCommitIndex());
}

test "RaftElection AppendEntries below the snapshot boundary skips covered entries and appends the tail" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = rejectAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "leader", .address = "" }};
    var raft = try RaftElection.init(allocator, "f1", &peers, .{}, &transport);
    defer raft.deinit();

    const seed_entries = [_]LogEntry{
        .{ .term = 1, .index = 1, .command = "e1" },
        .{ .term = 1, .index = 2, .command = "e2" },
        .{ .term = 1, .index = 3, .command = "e3" },
        .{ .term = 1, .index = 4, .command = "e4" },
    };
    const seed = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &seed_entries,
        .leader_commit = 4,
    });
    try testing.expect(seed.success);

    try raft.compactLog(3, "snap@3");
    try testing.expectEqual(@as(usize, 1), raft.logLen());

    // prev is INSIDE the snapshot: implicitly matched (that region is
    // committed on both sides), covered entries are skipped, the matching live
    // entry is left untouched, and only the genuine tail is appended.
    const covered = [_]LogEntry{
        .{ .term = 1, .index = 2, .command = "x2" },
        .{ .term = 1, .index = 3, .command = "x3" },
        .{ .term = 1, .index = 4, .command = "DIFFERENT" },
        .{ .term = 1, .index = 5, .command = "e5" },
    };
    const resp = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 1,
        .prev_log_term = 1,
        .entries = &covered,
        .leader_commit = 5,
    });
    try testing.expect(resp.success);
    try testing.expectEqual(@as(u64, 5), resp.match_index);
    try testing.expectEqual(@as(usize, 2), raft.logLen());
    // Index 4 matched by term, so it was skipped — not overwritten.
    try testing.expectEqualStrings("e4", raft.getLogEntry(4).?.command);
    try testing.expectEqualStrings("e5", raft.getLogEntry(5).?.command);

    // A batch with a hole is malformed: rejected before any mutation, even
    // though the hole sits inside the snapshotted region.
    const gapped = [_]LogEntry{
        .{ .term = 1, .index = 2, .command = "x2" },
        .{ .term = 1, .index = 4, .command = "x4" },
    };
    try testing.expectError(error.InvalidLogIndex, raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 1,
        .prev_log_term = 1,
        .entries = &gapped,
        .leader_commit = 5,
    }));
    try testing.expectEqual(@as(usize, 2), raft.logLen());
    try testing.expectEqualStrings("e5", raft.getLogEntry(5).?.command);
}

test "RaftElection sends InstallSnapshot to a follower lagging into the snapshot, then resumes AppendEntries at the boundary" {
    const allocator = testing.allocator;
    AppendCoords.reset();
    SnapshotCapture.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendCoords.accept,
        .sendInstallSnapshot = SnapshotCapture.accept,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 2;

    for (0..7) |i| {
        var buf: [16]u8 = undefined;
        _ = try raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    // Commit through 7 so a boundary at 3 is legal.
    const peer_key = raft.peers.items[0].id;
    try raft.match_index.put(peer_key, 7);
    raft.advanceCommitIndex();
    try testing.expectEqual(@as(u64, 7), raft.getCommitIndex());

    try raft.compactLog(3, "snap@3");
    try testing.expectEqualStrings("snap@3", raft.snapshot_data.?);

    // The follower fell behind into the compacted region: no AppendEntries can
    // match below the boundary, so the round ships the snapshot instead.
    try raft.next_index.put(peer_key, 2);
    try raft.match_index.put(peer_key, 1);

    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 0), AppendCoords.calls);
    try testing.expectEqual(@as(usize, 1), SnapshotCapture.calls);
    try testing.expectEqual(@as(usize, 1), SnapshotCapture.done_calls);
    try testing.expectEqual(@as(u64, 0), SnapshotCapture.offsets[0]);
    try testing.expectEqual(@as(u64, 3), SnapshotCapture.last_included_index);
    try testing.expectEqual(@as(u64, 2), SnapshotCapture.last_included_term);
    try testing.expectEqualStrings("snap@3", SnapshotCapture.assembled());
    // The reply advanced the follower to just past the boundary.
    try testing.expectEqual(@as(u64, 3), raft.match_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 4), raft.next_index.get(peer_key).?);

    // The next round is AppendEntries again, anchored on the snapshot boundary.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 1), AppendCoords.calls);
    try testing.expectEqual(@as(u64, 3), AppendCoords.prev_index);
    try testing.expectEqual(@as(u64, 2), AppendCoords.prev_term);
    try testing.expectEqual(@as(usize, 4), AppendCoords.entries_len);
    try testing.expectEqual(@as(u64, 4), AppendCoords.first_index);
    try testing.expectEqual(@as(u64, 7), AppendCoords.last_index);
}

test "RaftElection InstallSnapshot response: matching index advances the peer, higher term steps down, stale is ignored" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = rejectAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 2;

    for (0..4) |i| {
        var buf: [16]u8 = undefined;
        _ = try raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    const peer_key = raft.peers.items[0].id;
    try raft.match_index.put(peer_key, 4);
    raft.advanceCommitIndex();
    try raft.compactLog(3, "snap@3");

    // A snapshot round is in flight: next_index sits at/below the boundary.
    try raft.next_index.put(peer_key, 2);
    try raft.match_index.put(peer_key, 1);

    // The matching reply resumes the peer just past the snapshot.
    try raft.handleInstallSnapshotResponse(.{ .term = 2 }, "n2", 3);
    try testing.expectEqual(@as(u64, 3), raft.match_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 4), raft.next_index.get(peer_key).?);
    try testing.expectEqual(RaftState.leader, raft.getState());

    // A reply naming a different boundary is stale: nothing moves.
    try raft.handleInstallSnapshotResponse(.{ .term = 2 }, "n2", 99);
    try testing.expectEqual(@as(u64, 4), raft.next_index.get(peer_key).?);
    try testing.expectEqual(RaftState.leader, raft.getState());

    // A reply from an older term moves nothing either.
    try raft.handleInstallSnapshotResponse(.{ .term = 1 }, "n2", 3);
    try testing.expectEqual(@as(u64, 4), raft.next_index.get(peer_key).?);

    // Unknown peer: no-op.
    try raft.handleInstallSnapshotResponse(.{ .term = 2 }, "ghost", 3);
    try testing.expectEqual(RaftState.leader, raft.getState());

    // Higher term steps the node down — even when the boundary it names is
    // stale (the term half of a stale answer still applies).
    try raft.handleInstallSnapshotResponse(.{ .term = 5 }, "n2", 99);
    try testing.expectEqual(RaftState.follower, raft.getState());
    try testing.expectEqual(@as(u64, 5), raft.current_term);

    try raft.handleInstallSnapshotResponse(.{ .term = 7 }, "n2", 3);
    try testing.expectEqual(@as(u64, 7), raft.current_term);
    try testing.expectEqual(RaftState.follower, raft.getState());
}

test "RaftElection assembles a chunked InstallSnapshot, retains a continuing suffix, wipes a disagreeing one" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = rejectAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "leader", .address = "" }};
    var raft = try RaftElection.init(allocator, "f1", &peers, .{}, &transport);
    defer raft.deinit();

    const cmds = [_][]const u8{ "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8" };
    var seed_entries: [8]LogEntry = undefined;
    for (0..8) |i| seed_entries[i] = .{ .term = 1, .index = @intCast(i + 1), .command = cmds[i] };
    const seed = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &seed_entries,
        .leader_commit = 8,
    });
    try testing.expect(seed.success);
    try testing.expectEqual(@as(u64, 8), raft.getCommitIndex());

    const payload = "0123456789abcdefghij0123456";
    try testing.expectEqual(@as(usize, 27), payload.len);

    // Frames 1–2 assemble but do not apply.
    _ = try raft.handleInstallSnapshot(.{ .term = 1, .leader_id = "leader", .last_included_index = 6, .last_included_term = 1, .offset = 0, .data = payload[0..10], .done = false });
    try testing.expect(raft.snapshot_data == null);
    try testing.expectEqual(@as(usize, 8), raft.logLen());
    _ = try raft.handleInstallSnapshot(.{ .term = 1, .leader_id = "leader", .last_included_index = 6, .last_included_term = 1, .offset = 10, .data = payload[10..20], .done = false });
    try testing.expect(raft.snapshot_data == null);

    // Frame 3 completes the transfer: the entry at the boundary exists with
    // the snapshot's term, so the suffix (7, 8) is retained (§7).
    _ = try raft.handleInstallSnapshot(.{ .term = 1, .leader_id = "leader", .last_included_index = 6, .last_included_term = 1, .offset = 20, .data = payload[20..27], .done = true });
    try testing.expectEqualStrings(payload, raft.snapshot_data.?);
    try testing.expectEqual(@as(u64, 6), raft.last_included_index);
    try testing.expectEqual(@as(usize, 2), raft.logLen());
    try testing.expectEqualStrings("s7", raft.getLogEntry(7).?.command);
    try testing.expectEqualStrings("s8", raft.getLogEntry(8).?.command);
    try testing.expectEqual(@as(u64, 8), raft.getCommitIndex());

    // A continuation that does not land at the assembled length is dropped,
    // not applied.
    _ = try raft.handleInstallSnapshot(.{ .term = 1, .leader_id = "leader", .last_included_index = 6, .last_included_term = 1, .offset = 5, .data = "xx", .done = false });
    try testing.expectEqualStrings(payload, raft.snapshot_data.?);
    try testing.expectEqual(@as(usize, 2), raft.logLen());

    // Replication continues from the retained live tail.
    const tail = [_]LogEntry{.{ .term = 1, .index = 9, .command = "s9" }};
    const ok = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 8,
        .prev_log_term = 1,
        .entries = &tail,
        .leader_commit = 8,
    });
    try testing.expect(ok.success);
    try testing.expectEqualStrings("s9", raft.getLogEntry(9).?.command);

    // A snapshot whose boundary term disagrees with the log wipes it wholesale.
    _ = try raft.handleInstallSnapshot(.{ .term = 1, .leader_id = "leader", .last_included_index = 7, .last_included_term = 9, .offset = 0, .data = "w", .done = true });
    try testing.expectEqual(@as(u64, 7), raft.last_included_index);
    try testing.expectEqual(@as(u64, 9), raft.last_included_term);
    try testing.expectEqual(@as(usize, 0), raft.logLen());
    try testing.expectEqualStrings("w", raft.snapshot_data.?);

    // The log continues after the wipe, anchored on the new boundary term.
    const rebuild = [_]LogEntry{.{ .term = 1, .index = 8, .command = "n8" }};
    const ok2 = try raft.handleAppendEntries(.{
        .term = 1,
        .leader_id = "leader",
        .prev_log_index = 7,
        .prev_log_term = 9,
        .entries = &rebuild,
        .leader_commit = 8,
    });
    try testing.expect(ok2.success);
    try testing.expectEqualStrings("n8", raft.getLogEntry(8).?.command);
}

test "RaftElection leader tick compacts the committed prefix once the log outgrows snapshot_threshold_entries" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = rejectAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var raft = try RaftElection.init(allocator, "n1", &.{}, .{ .snapshot_threshold_entries = 3 }, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;

    for (0..5) |i| {
        var buf: [16]u8 = undefined;
        _ = try raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    try testing.expectEqual(@as(u64, 5), raft.getCommitIndex());
    try testing.expectEqual(@as(usize, 5), raft.logLen());

    try raft.tick();
    try testing.expectEqual(@as(u64, 5), raft.last_included_index);
    try testing.expectEqual(@as(u64, 1), raft.last_included_term);
    try testing.expectEqual(@as(usize, 0), raft.logLen());
    // No snapshotter hook: the stored bytes are the placeholder summary — a
    // debug artifact, not application state.
    const snap = raft.snapshot_data.?;
    try testing.expect(std.mem.indexOf(u8, snap, "zigmodu-raft-snapshot:v1:") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "last_included_index=5") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "compacted_entries=5") != null);

    // Appends continue in absolute coordinates across the auto-compaction.
    try testing.expectEqual(@as(u64, 6), try raft.appendEntry("cmd-5"));
}

test "RaftElection snapshotter hook supplies the bytes, and the uncommitted tail is never compacted" {
    const allocator = testing.allocator;
    SnapshotterProbe.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = rejectAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var marker: u8 = 0;
    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{
        .snapshot_threshold_entries = 3,
        .snapshotter = SnapshotterProbe.snapshot,
        .snapshotter_ctx = &marker,
    }, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;

    for (0..6) |i| {
        var buf: [16]u8 = undefined;
        _ = try raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    // Nothing committed (the peer rejects everything): the tick must not fold
    // uncommitted entries into a snapshot.
    try testing.expectEqual(@as(u64, 0), raft.getCommitIndex());
    try raft.tick();
    try testing.expectEqual(@as(u64, 0), raft.last_included_index);
    try testing.expectEqual(@as(usize, 6), raft.logLen());
    try testing.expect(raft.snapshot_data == null);
    try testing.expectEqual(@as(usize, 0), SnapshotterProbe.calls);

    // Commit through 4: the next tick snapshots exactly the committed prefix.
    const peer_key = raft.peers.items[0].id;
    try raft.match_index.put(peer_key, 4);
    raft.advanceCommitIndex();
    try testing.expectEqual(@as(u64, 4), raft.getCommitIndex());

    try raft.tick();
    try testing.expectEqual(@as(usize, 1), SnapshotterProbe.calls);
    try testing.expectEqual(@as(u64, 4), SnapshotterProbe.seen_up_to);
    try testing.expect(SnapshotterProbe.seen_ctx == @as(?*anyopaque, &marker));
    try testing.expectEqual(@as(u64, 4), raft.last_included_index);
    try testing.expectEqual(@as(usize, 2), raft.logLen());
    try testing.expectEqualStrings("app-snapshot@4", raft.snapshot_data.?);
    try testing.expectEqualStrings("cmd-4", raft.getLogEntry(5).?.command);
}

test "RaftElection compactLog refuses an uncommitted or out-of-range boundary" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = rejectAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    // Two nodes, the peer never acks: commit_index stays 0, so compaction must
    // refuse — folding uncommitted entries into a snapshot is exactly what
    // Raft §7 forbids.
    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;
    for (0..4) |i| {
        var buf: [16]u8 = undefined;
        _ = try raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    try testing.expectEqual(@as(u64, 0), raft.getCommitIndex());
    try testing.expectError(error.NotCommitted, raft.compactLog(3, "x"));
    try testing.expectEqual(@as(usize, 4), raft.logLen());
    try testing.expectEqual(@as(u64, 0), raft.last_included_index);
    try testing.expect(raft.snapshot_data == null);

    // One node: everything commits, so a boundary *inside* the log compacts…
    var solo = try RaftElection.init(allocator, "solo", &.{}, .{}, &transport);
    defer solo.deinit();
    solo.state = .leader;
    solo.current_term = 1;
    _ = try solo.appendEntry("a");
    _ = try solo.appendEntry("b");
    _ = try solo.appendEntry("c");
    try testing.expectEqual(@as(u64, 3), solo.getCommitIndex());
    // …but a boundary past the committed tail is still an uncommitted boundary
    // (commit_index ≤ the tail always, so "past the tail" and "past the
    // committed prefix" are the same refusal here).
    try testing.expectError(error.NotCommitted, solo.compactLog(9, "x"));
    try testing.expectEqual(@as(usize, 3), solo.logLen());
    try solo.compactLog(2, "ok");
    try testing.expectEqual(@as(u64, 2), solo.last_included_index);
    try testing.expectEqual(@as(usize, 1), solo.logLen());
    // Re-compacting at or below the boundary is a no-op, not an error.
    try solo.compactLog(2, "ignored");
    try testing.expectEqualStrings("ok", solo.snapshot_data.?);
}

/// Shape of `RaftElection.ElectionTransport`, restated at file scope so the
/// tests below can build transports out of named helper functions.
const TestTransportVTable = struct {
    sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
    sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
};

fn noopVoteRequest(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}

/// The snapshot half of the test transports below: records nothing, answers
/// "lost message" (`term = 0` reads as a dropped frame to the leader's
/// bookkeeping). Tests that exercise the §7 sender use their own capture.
fn noopInstallSnapshot(_: ?[]const u8, _: []const u8, _: InstallSnapshotRequest) InstallSnapshotResponse {
    return .{ .term = 0 };
}

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

/// Answers with a higher term, which makes the leader step down when the
/// round's replies are applied (phase 3) before it can touch `next_index` /
/// `match_index` — so whatever `becomeLeader` wrote into those maps stays
/// observable.
fn higherTermAppendEntries(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
    return .{ .term = req.term +| 1, .success = false, .match_index = 0 };
}

test "RaftElection single-node cluster elects itself on the first tick" {
    const allocator = testing.allocator;
    AppendEntriesCapture.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendEntriesCapture.accept,
        .sendInstallSnapshot = noopInstallSnapshot,
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

test "a three-node candidate wins with its self-vote plus ONE peer grant" {
    const allocator = testing.allocator;

    var cluster = try TestCluster.init(allocator, 3);
    defer cluster.deinit();

    const cand = &cluster.nodes.items[0].election;

    // `startElection` votes for itself and polls n1/n2 through the stub transport.
    // A 3-node cluster is won with 2 of 3 votes, and the self-vote is one of them —
    // so ONE peer grant is already a majority. This test used to assert the
    // opposite (`needs two peer grants, not its self-vote`), which is 3 of 3: the
    // off-by-one in `handleVoteResponse` that made N=2 unreachable and cost every
    // larger cluster a node of fault tolerance (docs/dev/cluster-auth-design.md §12).
    try cand.startElection();
    try testing.expectEqual(RaftState.candidate, cand.getState());
    try testing.expect(!cand.isLeader());
    try testing.expectEqual(@as(usize, 3), cand.clusterSize());
    try testing.expectEqual(@as(usize, 2), cand.quorumSize());

    try cand.handleVoteResponse(.{ .term = 1, .vote_granted = true }, "n1");
    try testing.expect(cand.isLeader());
    try testing.expectEqual(RaftState.leader, cand.getState());
}

test "RaftElection caps each replication round at max_append_entries" {
    const allocator = testing.allocator;
    AppendEntriesCapture.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = AppendEntriesCapture.accept,
        .sendInstallSnapshot = noopInstallSnapshot,
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

/// A peer that acknowledges only the entries up to `ack_through`: the reply a
/// follower sends after clamping a batch it could not apply in full.
const PartialAppendAck = struct {
    var ack_through: u64 = 0;
    var calls: usize = 0;
    var entries_len: usize = 0;
    var first_index: u64 = 0;

    fn reset(ack_through_: u64) void {
        ack_through = ack_through_;
        calls = 0;
        entries_len = 0;
        first_index = 0;
    }

    fn accept(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
        calls += 1;
        entries_len = req.entries.len;
        first_index = if (req.entries.len > 0) req.entries[0].index else req.prev_log_index;
        const last = if (req.entries.len > 0) req.entries[req.entries.len - 1].index else req.prev_log_index;
        return .{ .term = req.term, .success = true, .match_index = @min(last, ack_through) };
    }
};

// The inbound half of `max_append_entries`. Before this clamp the field was read
// only on the sender side (`sendAppendEntries`), so one `append_entries` applied
// however many entries a peer chose to carry — and the response reported a log
// the follower may not have.
//
// Verified red: removing the clamp from `handleAppendEntries` makes this fail on
// `expected 3, found 10` at the `match_index` assertion (and on `logLen()`),
// an assertion failure rather than a compile error.
test "an inbound AppendEntries applies at most max_append_entries entries, and says so" {
    const allocator = testing.allocator;

    var peers = [_]Peer{.{ .id = "node-leader", .address = "" }};
    var election = try RaftElection.init(allocator, "node1", &peers, .{ .max_append_entries = 3 }, &MembershipTestTransport.vtable);
    defer election.deinit();

    // One batch of ten, as a leader with a *larger* `max_append_entries` would
    // send: the mismatch is what the clamp has to absorb without stalling.
    const batch = [_]LogEntry{
        .{ .term = 1, .index = 1, .command = "one" },
        .{ .term = 1, .index = 2, .command = "two" },
        .{ .term = 1, .index = 3, .command = "three" },
        .{ .term = 1, .index = 4, .command = "four" },
        .{ .term = 1, .index = 5, .command = "five" },
        .{ .term = 1, .index = 6, .command = "six" },
        .{ .term = 1, .index = 7, .command = "seven" },
        .{ .term = 1, .index = 8, .command = "eight" },
        .{ .term = 1, .index = 9, .command = "nine" },
        .{ .term = 1, .index = 10, .command = "ten" },
    };

    const applied = try election.handleAppendEntries(.{
        .term = 1,
        .leader_id = "node-leader",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &batch,
        .leader_commit = 10,
    });

    // Success with the prefix, not a refusal: the next round picks up at 4.
    try testing.expect(applied.success);
    try testing.expectEqual(@as(u64, 3), applied.match_index);
    try testing.expectEqual(@as(usize, 3), election.logLen());
    try testing.expectEqualStrings("three", election.getLogEntry(3).?.command);
    try testing.expect(election.getLogEntry(4) == null);
    // `match_index` is the log tail, so the commit advance is clamped by it too:
    // `leader_commit = 10` cannot commit entries this node never applied.
    try testing.expectEqual(@as(u64, 3), election.getCommitIndex());

    // The rest arrives on the next round, from where the acknowledgement left
    // off — the clamp costs an extra round, not a stuck follower.
    const rest = try election.handleAppendEntries(.{
        .term = 1,
        .leader_id = "node-leader",
        .prev_log_index = 3,
        .prev_log_term = 1,
        .entries = batch[3..],
        .leader_commit = 10,
    });
    try testing.expect(rest.success);
    try testing.expectEqual(@as(u64, 6), rest.match_index);
    try testing.expectEqual(@as(usize, 6), election.logLen());
    try testing.expectEqualStrings("six", election.getLogEntry(6).?.command);
}

// The leader's half of the same property. `resp.success` alone used to mean "the
// whole batch landed": the acknowledged `match_index` was ignored on the success
// path, so a follower that clamped would still be recorded as holding every
// entry in the batch — and `advanceCommitIndex` commits on `match_index`.
test "a follower that acknowledged only part of a batch rewinds the leader to what it acked" {
    const allocator = testing.allocator;
    PartialAppendAck.reset(2);

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = PartialAppendAck.accept,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{ .max_append_entries = 4 }, &transport);
    defer raft.deinit();

    raft.state = .leader;
    raft.current_term = 1;
    for (0..6) |i| {
        var buf: [16]u8 = undefined;
        _ = try raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }

    const peer_key = raft.peers.items[0].id;
    try raft.next_index.put(peer_key, 1);
    try raft.match_index.put(peer_key, 0);

    // Round 1 hands over entries 1..4; the peer acknowledges 1..2.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(usize, 4), PartialAppendAck.entries_len);
    try testing.expectEqual(@as(u64, 1), PartialAppendAck.first_index);
    try testing.expectEqual(@as(u64, 2), raft.match_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 3), raft.next_index.get(peer_key).?);
    // Only what the follower really holds counts toward a quorum.
    try testing.expectEqual(@as(u64, 2), raft.getCommitIndex());

    // Round 2 resumes at the acknowledged prefix instead of re-sending it.
    try raft.sendAppendEntries();
    try testing.expectEqual(@as(u64, 3), PartialAppendAck.first_index);
    try testing.expectEqual(@as(u64, 2), raft.match_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 3), raft.next_index.get(peer_key).?);
}

test "RaftElection becomeLeader reinitializes per-peer next_index and match_index" {
    const allocator = testing.allocator;

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = higherTermAppendEntries,
        .sendInstallSnapshot = noopInstallSnapshot,
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
    // The promotion's first heartbeat is owed, not sent (`becomeLeader` runs
    // where the lock is held, and IO moved out of it) — the flush delivers it.
    try raft.flushOutgoing();

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
        .sendInstallSnapshot = noopInstallSnapshot,
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
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var gate = WindowGate{ .backing = allocator };
    // `peer-a` (the seeded vote below) and `peer-b` (the inbound driver's id) are
    // the two names the windows free and replace, and both have to be configured
    // members: a vote from an unlisted candidate is denied, which would leave the
    // seeded `voted_for` in place and the rendezvous unreachable
    // (docs/dev/cluster-auth-design.md §4.1). The transport stays a no-op — what is
    // under test is the two threads writing `voted_for`, not the wire, and
    // `startElection` still reaches its read-then-free window on every round.
    var raft_peers = [_]Peer{
        .{ .id = "peer-a", .address = "" },
        .{ .id = "peer-b", .address = "" },
    };
    var raft = try RaftElection.init(gate.allocator(), "node-a", &raft_peers, .{}, &transport);
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

/// This thread's own consumed CPU time, in nanoseconds.
///
/// `std.Thread.getCpuTime` went away with the rest of the 0.16→0.17 removals, so
/// the clock behind it is read directly: `CLOCK.THREAD_CPUTIME_ID` is part of
/// `std.c.CLOCK` on every POSIX target this repo runs tests on (macOS 16, Linux
/// 3).
fn threadCpuNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// The reading the lock's wait shape exists for.
//
// When this wait was built, `tick()` kept this lock for its whole outbound
// round, and a black-holed peer was written off only after `rpc_timeout_ms`
// (100 ms by default) — *per peer*. The outbound round has since moved out of
// the lock (`flushOutgoing` phase 2), so the long holds are gone by
// construction; what remains — the phase-1 staging copy (up to one snapshot
// memcpy), the inbound handler bodies — can still outlast a scheduling
// quantum, and "the waiter is waiting" has to keep meaning it is *off* the
// CPU. A core burned per waiter is the cost the old `swap` + unbounded
// `spinLoopHint` loop paid, for as long as the hold took.
//
// Verified red, measured three ways on this toolchain (macOS, 120 ms hold
// driving the same waiter, whose own `CLOCK.THREAD_CPUTIME_ID` delta is the
// reading):
//
//   `swap(true, .acquire)` + `spinLoopHint`   120 ms CPU   (the shape removed here)
//   `cmpxchgWeak` + bounded spin + `yield`    116 ms CPU   (route (b) as prescribed)
//   … + the sleep stage below                   0 ms CPU
//
// The middle row is the whole reason the sleep stage exists: `yield` is not
// enough. A holder asleep in a syscall is *not runnable* — so there is no
// thread to hand the core to and `sched_yield` returns immediately.
// The threshold is deliberately half the hold: what is being asserted is the
// order of magnitude, a core versus nothing, not the reading. This test's own
// numbers, the ones the assertion below sees at `hold_ms = 200`: **200 ms**
// before this change (`swap` + spin) and **0 ms** after it.
test "RaftLock: a wait across a slow RPC costs the waiter sleep, not CPU" {
    const hold_ms: u32 = 200;
    const margin_ns = @as(u64, hold_ms) * std.time.ns_per_ms / 2;

    const Waiter = struct {
        fn run(lock: *RaftLock, measured: *std.atomic.Value(u64)) void {
            const before = threadCpuNanoseconds();
            lock.acquire();
            lock.release();
            measured.store(threadCpuNanoseconds() - before, .release);
        }
    };

    var lock = RaftLock{};
    lock.acquire();

    var waiter_cpu_ns = std.atomic.Value(u64).init(0);
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &lock, &waiter_cpu_ns });

    // The holder's half of the pattern, not an artefact of the test: the lock is
    // held while the holder is off the CPU — what a phase-1 staging copy of a
    // large snapshot looks like from inside now that the RPC wait itself has
    // moved out of the lock.
    sleepWithoutIo(hold_ms);
    lock.release();

    waiter.join();
    try testing.expect(waiter_cpu_ns.load(.acquire) < margin_ns);
}

// The other half of "the wait shape changed and nothing else did": exclusion, and
// the `isHeld` reading the rendezvous above depends on.
//
// `RaftLock` had no test of its own shape before this — the two tests above it
// test the *raft*, through the lock, and would notice a broken lock only as a
// double free somewhere else.
test "RaftLock: excludes, and isHeld tracks the holder" {
    const threads_n: usize = 8;
    const per_thread: usize = 5_000;

    const Shared = struct {
        lock: RaftLock = .{},
        counter: u64 = 0,
        /// Set if a thread that has returned from `acquire` ever reads the lock
        /// as free. It is the one invariant a compare-exchange fast path could
        /// break without breaking exclusion itself.
        saw_free_inside: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn bump(self: *@This()) void {
            self.lock.acquire();
            defer self.lock.release();
            if (!self.lock.isHeld()) self.saw_free_inside.store(true, .release);
            self.counter += 1;
        }
    };

    var shared = Shared{};
    try testing.expect(!shared.lock.isHeld());

    const threads = try testing.allocator.alloc(std.Thread, threads_n);
    defer testing.allocator.free(threads);
    const Worker = struct {
        fn run(s: *Shared, n: usize) void {
            for (0..n) |_| s.bump();
        }
    };
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &shared, per_thread });
    for (threads) |t| t.join();

    // A read-modify-write under the lock: a lost update is two threads inside.
    try testing.expectEqual(@as(u64, threads_n * per_thread), shared.counter);
    try testing.expect(!shared.saw_free_inside.load(.acquire));
    try testing.expect(!shared.lock.isHeld());
}

// ── L2: the inbound membership check (docs/dev/cluster-auth-design.md §4.1) ───
//
// The negative fixtures here hand `init` a peer list that does **not** contain the
// sender — the state a node is in when a TCP-reachable stranger talks to it, since
// the wire cannot add itself to `peers`. The last test is the positive control: a
// sender that *is* in the list still replicates.

/// Nothing is ever sent by these tests and an outbound AppendEntries answers "not
/// replicated" — the checks under test are all inbound.
const MembershipTestTransport = struct {
    fn vote(_: ?[]const u8, _: []const u8, _: VoteRequest) void {}
    fn append(_: ?[]const u8, _: []const u8, _: AppendEntriesRequest) AppendEntriesResponse {
        return .{ .term = 0, .success = false, .match_index = 0 };
    }
    const vtable: RaftElection.ElectionTransport = &.{
        .sendVoteRequest = vote,
        .sendAppendEntries = append,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
};

// The red→green target of this change (§7 evidence #5). Before the membership check
// this granted a ballot — and, because the check sits above the term update, moved
// the term — to any peer that named a `candidate_id`, while `handleVoteResponse`
// had always refused exactly that.
test "an unlisted candidate is denied a vote and cannot move the term" {
    const allocator = testing.allocator;

    var peers = [_]Peer{.{ .id = "node-2", .address = "" }};
    var election = try RaftElection.init(allocator, "node1", &peers, .{}, &MembershipTestTransport.vtable);
    defer election.deinit();

    const denied = try election.handleVoteRequest(.{
        .term = 7,
        .candidate_id = "outsider",
        .last_log_index = 99,
        .last_log_term = 99,
    });

    try testing.expect(!denied.vote_granted);
    // Denial rather than error, and denial *before* the mutation: a stranger cannot
    // bump our term (`req.term` is 7) or reset the election deadline.
    try testing.expectEqual(@as(u64, 0), election.getTerm());
    try testing.expect(election.voted_for == null);
}

test "an unlisted leader is refused and mutates nothing" {
    const allocator = testing.allocator;

    var peers = [_]Peer{.{ .id = "node-2", .address = "" }};
    var election = try RaftElection.init(allocator, "node1", &peers, .{}, &MembershipTestTransport.vtable);
    defer election.deinit();

    const refused = try election.handleAppendEntries(.{
        .term = 9,
        .leader_id = "impostor",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{.{ .term = 9, .index = 1, .command = "forged" }},
        .leader_commit = 1,
    });

    // `success = false` is also the answer to "your entry does not fit my log", so
    // the answer alone proves nothing — what this asserts is that every write the
    // handler makes stayed unmade: term, log, commit and the leader slot.
    try testing.expect(!refused.success);
    try testing.expectEqual(@as(u64, 0), election.getTerm());
    try testing.expectEqual(@as(usize, 0), election.logLen());
    try testing.expectEqual(@as(u64, 0), election.getCommitIndex());
    try testing.expect(election.getLeader() == null);
}

// The other side of the same check: `becomeLeader` names this node in `leader_id`,
// so the self case has to read as "us" rather than as an unknown sender — otherwise
// a leader cannot replicate to itself (and §4.1's `!eql(local_id)` clause is dead
// code that no assertion would miss).
test "AppendEntries from this node itself is still accepted" {
    const allocator = testing.allocator;

    // No peers at all: nothing but the `local_id` comparison can let this through.
    var election = try RaftElection.init(allocator, "node1", &.{}, .{}, &MembershipTestTransport.vtable);
    defer election.deinit();

    const appended = try election.handleAppendEntries(.{
        .term = 3,
        .leader_id = "node1",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{.{ .term = 3, .index = 1, .command = "self-run" }},
        .leader_commit = 1,
    });

    try testing.expect(appended.success);
    try testing.expectEqual(@as(u64, 3), appended.term);
    try testing.expectEqual(@as(usize, 1), election.logLen());
    try testing.expectEqualStrings("self-run", election.getLogEntry(1).?.command);
    try testing.expectEqualStrings("node1", election.getLeader().?);
}

test "an unlisted leader cannot wipe the log with InstallSnapshot" {
    const allocator = testing.allocator;

    var peers = [_]Peer{.{ .id = "node-2", .address = "" }};
    var follower = try RaftElection.init(allocator, "node1", &peers, .{}, &MembershipTestTransport.vtable);
    defer follower.deinit();

    // A log to lose, written the way a leader writes one.
    follower.state = .leader;
    follower.current_term = 1;
    _ = try follower.appendEntry("keep-1");
    _ = try follower.appendEntry("keep-2");
    try testing.expectEqual(@as(usize, 2), follower.logLen());

    const out = try follower.handleInstallSnapshot(.{
        .term = 5,
        .leader_id = "impostor",
        .last_included_index = 10,
        .last_included_term = 5,
        .offset = 0,
        .data = "wipe-everything",
        .done = true,
    });

    // The reply carries a term and nothing else, so the log is the observable — and
    // `last_included_index` is what the destructive branch advances.
    try testing.expectEqual(@as(u64, 1), out.term);
    try testing.expectEqual(@as(usize, 2), follower.logLen());
    try testing.expectEqual(@as(u64, 0), follower.last_included_index);
    try testing.expect(follower.snapshot_data == null);
    try testing.expectEqualStrings("keep-1", follower.getLogEntry(1).?.command);
}

// The positive control for the two AppendEntries tests above: a leader that *is* a
// configured member still replicates. Without it, a check that rejected everyone
// would read as a fix.
test "a member leader's AppendEntries is still accepted and appended" {
    const allocator = testing.allocator;

    var peers = [_]Peer{.{ .id = "node-leader", .address = "" }};
    var election = try RaftElection.init(allocator, "node1", &peers, .{}, &MembershipTestTransport.vtable);
    defer election.deinit();

    const appended = try election.handleAppendEntries(.{
        .term = 4,
        .leader_id = "node-leader",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{.{ .term = 4, .index = 1, .command = "from-member" }},
        .leader_commit = 1,
    });

    try testing.expect(appended.success);
    try testing.expectEqual(@as(u64, 1), appended.match_index);
    try testing.expectEqual(@as(u64, 4), election.getTerm());
    try testing.expectEqual(@as(usize, 1), election.logLen());
    try testing.expectEqualStrings("from-member", election.getLogEntry(1).?.command);
    try testing.expectEqualStrings("node-leader", election.getLeader().?);
    try testing.expectEqual(@as(u64, 1), election.getCommitIndex());
}

// ── A-3: runtime key rotation & revocation ──────────────────────────────────

test "runtime key table ops: rotate opens a window, close/revoke settle it" {
    const allocator = testing.allocator;

    const k_own1: [32]u8 = @splat(0xa0);
    const k_own2: [32]u8 = @splat(0xa9);
    const k_b1: [32]u8 = @splat(0xb1);
    const k_b2: [32]u8 = @splat(0xb2);
    const k_c1: [32]u8 = @splat(0xc1);
    const k_d1: [32]u8 = @splat(0xd1);

    var peers = [_]Peer{ .{ .id = "node-b", .address = "" }, .{ .id = "node-c", .address = "" } };
    const keys = [_]PeerKey{ .{ .id = "node-b", .key = k_b1 }, .{ .id = "node-c", .key = k_c1 } };
    var election = try RaftElection.init(allocator, "node-a", &peers, .{ .own_key = k_own1, .peer_keys = &keys }, &MembershipTestTransport.vtable);
    defer election.deinit();

    // rotateOwnKey: the signing key swaps, no window on this side.
    election.rotateOwnKey(k_own2);
    try testing.expectEqual(@as(?[32]u8, k_own2), election.config.own_key);

    // rotatePeerKey on a known id: new current, old current kept as previous.
    try election.rotatePeerKey("node-b", k_b2);
    try testing.expectEqual(k_b2, election.peerKeyEntry("node-b").?.key);
    try testing.expectEqual(@as(?[32]u8, k_b1), election.peerKeyEntry("node-b").?.previous);

    // An unknown id is upserted with no window (nothing old to keep).
    try election.rotatePeerKey("node-d", k_d1);
    try testing.expectEqual(k_d1, election.peerKeyEntry("node-d").?.key);
    try testing.expectEqual(@as(?[32]u8, null), election.peerKeyEntry("node-d").?.previous);
    try testing.expectEqual(@as(usize, 3), election.config.peer_keys.len);

    // setPeerKey overwrites and closes the window.
    try election.setPeerKey("node-b", k_b1);
    try testing.expectEqual(k_b1, election.peerKeyEntry("node-b").?.key);
    try testing.expectEqual(@as(?[32]u8, null), election.peerKeyEntry("node-b").?.previous);
    // …and upserts an unknown id the same way.
    try election.setPeerKey("node-e", k_d1);
    try testing.expectEqual(@as(usize, 4), election.config.peer_keys.len);

    // dropPreviousPeerKey closes an open window; both miss shapes are false.
    try election.rotatePeerKey("node-b", k_b2);
    try testing.expect(election.dropPreviousPeerKey("node-b"));
    try testing.expectEqual(@as(?[32]u8, null), election.peerKeyEntry("node-b").?.previous);
    try testing.expect(!election.dropPreviousPeerKey("node-zz"));

    // revokePeerKey: the entry is gone, the table rebuilt without it; a second
    // revoke and an unknown id are false. (The on-wire halves — inbound refuse,
    // outbound fail-closed — are the RaftTransport tests.)
    try testing.expect(try election.revokePeerKey("node-b"));
    try testing.expect(election.peerKeyEntry("node-b") == null);
    try testing.expectEqual(@as(usize, 3), election.config.peer_keys.len);
    try testing.expect(!try election.revokePeerKey("node-b"));

    // Revoking down to an empty table stays consistent (deinit frees it).
    try testing.expect(try election.revokePeerKey("node-c"));
    try testing.expect(try election.revokePeerKey("node-d"));
    try testing.expect(try election.revokePeerKey("node-e"));
    try testing.expectEqual(@as(usize, 0), election.config.peer_keys.len);
}

// ── Outbound IO off the lock: the three-phase flush's guardrails ────────────
//
// The rendezvous tests above ("a tick and an inbound RPC cannot both free
// voted_for" and its positive control) prove the lock serializes what must be
// serialized. They cannot reach the *other* half of the contract — that the
// outbound round no longer needs the lock, and is safe without it — because
// every transport above answers immediately. The two tests below park the
// transport mid-send (phase 2, lock released) and let the test thread mutate
// the raft underneath it. Both were verified red by mutation; their comments
// say what was removed and what failed.

/// One `tick()` on its own thread, for the guardrail tests below. A leader
/// tick cannot error (staging failures are logged, not propagated), so a panic
/// is the honest report.
fn driveOneTick(raft: *RaftElection) void {
    raft.tick() catch |err| std.debug.panic("[raft test] tick: {s}", .{@errorName(err)});
}

/// The transport behind both guardrail tests: `sendAppendEntries` parks the
/// leader round *inside the send* until the test thread has mutated the raft,
/// then copies out the bytes the request still claims to carry, and answers
/// with a preloaded response. File-scope statics, like the other test
/// transports above.
const BlockingAppend = struct {
    var entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var response: AppendEntriesResponse = .{ .term = 0, .success = false, .match_index = 0 };
    var cmd_count: usize = 0;
    var cmds: [4][64]u8 = undefined;
    var cmd_lens: [4]usize = .{ 0, 0, 0, 0 };

    fn reset(resp: AppendEntriesResponse) void {
        entered.store(false, .monotonic);
        release.store(false, .monotonic);
        response = resp;
        cmd_count = 0;
        cmd_lens = .{ 0, 0, 0, 0 };
    }

    fn waitEntered() void {
        while (!entered.load(.acquire)) std.atomic.spinLoopHint();
    }

    fn accept(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
        entered.store(true, .release);
        while (!release.load(.acquire)) std.atomic.spinLoopHint();
        // The test thread's mutation is already visible at this point — read
        // what the request *still* claims to carry.
        const n = @min(req.entries.len, cmds.len);
        for (0..n) |i| {
            const cmd = req.entries[i].command;
            if (cmd.len > cmds[i].len) continue;
            @memcpy(cmds[i][0..cmd.len], cmd);
            cmd_lens[i] = cmd.len;
        }
        cmd_count = n;
        return response;
    }
};

// Obligation 1 of the three-phase flush: the request on the wire is a **staged
// copy**, so a truncation that frees the log's command buffers mid-send cannot
// reach the bytes the peer receives.
//
// Verified red: making `stageLeaderRoundLocked` borrow (`command = entry.command`
// instead of the arena dupe) fails this on the "cmd-one"/"cmd-two" assertions —
// the testing allocator poisons the freed buffers, so the parked send reads
// garbage where the commands were. And a build with the IO back under the lock
// never gets that far: the truncating `handleAppendEntries` would block on
// `lock` while the send waits for `release` — a deadlock, which is why the test
// asserts `!lock.isHeld()` (and unwinds the parked thread) before mutating.
test "RaftElection: a round in flight reads staged bytes while the log is truncated under it" {
    const allocator = testing.allocator;
    BlockingAppend.reset(.{ .term = 1, .success = true, .match_index = 2 });

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = BlockingAppend.accept,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;
    _ = try raft.appendEntry("cmd-one");
    _ = try raft.appendEntry("cmd-two");

    // A lagging follower: the round carries both entries, and the send parks
    // with the lock released.
    try raft.next_index.put(raft.peers.items[0].id, 1);
    raft.last_heartbeat_ms = 0; // heartbeat due on the first tick

    const t = try std.Thread.spawn(.{}, driveOneTick, .{&raft});
    BlockingAppend.waitEntered();

    // The send is parked. If the IO ran under the lock (the old shape), the
    // mutation below would deadlock against it — fail on the state instead.
    if (raft.lock.isHeld()) {
        BlockingAppend.release.store(true, .release);
        t.join();
        return error.TestUnexpectedResult; // outbound IO ran under the lock again
    }

    // A higher-term AppendEntries from the (configured) peer walks in and
    // truncates the log — freeing the very command bytes the in-flight request
    // used to borrow.
    const conflict = [_]LogEntry{
        .{ .term = 2, .index = 1, .command = "replaced-1" },
        .{ .term = 2, .index = 2, .command = "replaced-2" },
    };
    const resp = try raft.handleAppendEntries(.{
        .term = 2,
        .leader_id = "n2",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &conflict,
        .leader_commit = 0,
    });
    try testing.expect(resp.success);

    // Reclaim the freed slots, so a borrowing implementation reads filler, not
    // stale luck (the testing allocator also poisons freed bytes).
    var fillers = std.ArrayList([]u8).empty;
    defer {
        for (fillers.items) |f| allocator.free(f);
        fillers.deinit(allocator);
    }
    for (0..32) |_| {
        const f = try allocator.dupe(u8, "filler!!");
        try fillers.append(allocator, f);
    }

    BlockingAppend.release.store(true, .release);
    t.join();

    // The staged copies, not the freed originals, are what went out.
    try testing.expectEqual(@as(usize, 2), BlockingAppend.cmd_count);
    try testing.expectEqualStrings("cmd-one", BlockingAppend.cmds[0][0..BlockingAppend.cmd_lens[0]]);
    try testing.expectEqualStrings("cmd-two", BlockingAppend.cmds[1][0..BlockingAppend.cmd_lens[1]]);

    // …and the term-2 world the tick's phase 3 met is intact: the stale round's
    // success was dropped, not written into the maps.
    try testing.expectEqual(@as(u64, 2), raft.getTerm());
    try testing.expectEqual(RaftState.follower, raft.getState());
    try testing.expectEqualStrings("replaced-1", raft.getLogEntry(1).?.command);
    try testing.expectEqual(@as(u64, 1), raft.next_index.get(raft.peers.items[0].id).?);
}

// Obligation 2: a reply that lands after the world moved on is dropped, not
// applied. While the send is parked, a higher-term vote request turns the node
// back into a follower; the parked round's success (term 1) then arrives in
// phase 3 to a node that is no longer the term-1 leader.
//
// Verified red: removing the `state != .leader or current_term != round_term`
// guard from `applyStagedRoundLocked` fails this on the `next_index` assertion
// (`expected 1, found 4`) — the stale success rewrote the maps of a raft that
// had already moved on.
test "RaftElection: a reply that lands after the term moved is dropped, not applied" {
    const allocator = testing.allocator;
    BlockingAppend.reset(.{ .term = 1, .success = true, .match_index = 3 });

    var impl = TestTransportVTable{
        .sendVoteRequest = noopVoteRequest,
        .sendAppendEntries = BlockingAppend.accept,
        .sendInstallSnapshot = noopInstallSnapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;
    _ = try raft.appendEntry("e1");
    _ = try raft.appendEntry("e2");
    _ = try raft.appendEntry("e3");

    const peer_key = raft.peers.items[0].id;
    try raft.next_index.put(peer_key, 1); // lagging: the round carries 1..3
    try raft.match_index.put(peer_key, 0);
    raft.last_heartbeat_ms = 0;

    const t = try std.Thread.spawn(.{}, driveOneTick, .{&raft});
    BlockingAppend.waitEntered();
    if (raft.lock.isHeld()) {
        BlockingAppend.release.store(true, .release);
        t.join();
        return error.TestUnexpectedResult; // outbound IO ran under the lock again
    }

    // The world moves on while the send is parked: a higher-term candidate (a
    // configured member) takes the node back to follower.
    const vr = try raft.handleVoteRequest(.{
        .term = 5,
        .candidate_id = "n2",
        .last_log_index = 3,
        .last_log_term = 1,
    });
    try testing.expect(vr.vote_granted);
    try testing.expectEqual(@as(u64, 5), raft.getTerm());

    BlockingAppend.release.store(true, .release);
    t.join();

    // The parked round's answer (success, match_index = 3, term 1) must have
    // been dropped wholesale: the maps keep what they had before the round.
    try testing.expectEqual(@as(u64, 1), raft.next_index.get(peer_key).?);
    try testing.expectEqual(@as(u64, 0), raft.match_index.get(peer_key).?);
    try testing.expectEqual(RaftState.follower, raft.getState());
    try testing.expectEqual(@as(u64, 5), raft.getTerm());
    try testing.expectEqual(@as(u64, 0), raft.getCommitIndex());
}

/// Counts every frame handed to the transport — the assertion surface for
/// "a tick that staged nothing sent nothing".
const WireCount = struct {
    var votes: usize = 0;
    var appends: usize = 0;
    var snapshots: usize = 0;

    fn reset() void {
        votes = 0;
        appends = 0;
        snapshots = 0;
    }

    fn vote(_: ?[]const u8, _: []const u8, _: VoteRequest) void {
        votes += 1;
    }

    fn append(_: ?[]const u8, _: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
        appends += 1;
        return .{ .term = req.term, .success = true, .match_index = req.prev_log_index };
    }

    fn snapshot(_: ?[]const u8, _: []const u8, _: InstallSnapshotRequest) InstallSnapshotResponse {
        snapshots += 1;
        return .{ .term = 0 };
    }
};

// Phase 2 runs on every flush, so phase 1 owes it clean staging buffers: a
// tick that staged nothing must deliver nothing. Without the phase-1 reset,
// the *previous* round's staged items are re-sent under `round_term = 0` — on
// every between-heartbeats leader tick, and on every follower tick after a
// demotion — one spurious term-0 AppendEntries per tick forever.
//
// Verified red: removing the `staged_items.clearRetainingCapacity()` from
// `flushOutgoing`'s phase 1 fails both assertions below (the counter moves to
// 2 on the first quiet tick, and again after the demotion).
test "RaftElection: a tick that stages no round sends nothing on the wire" {
    const allocator = testing.allocator;
    WireCount.reset();

    var impl = TestTransportVTable{
        .sendVoteRequest = WireCount.vote,
        .sendAppendEntries = WireCount.append,
        .sendInstallSnapshot = WireCount.snapshot,
    };
    const transport: RaftElection.ElectionTransport = @ptrCast(@alignCast(@constCast(&impl)));

    var peers = [_]Peer{.{ .id = "n2", .address = "" }};
    var raft = try RaftElection.init(allocator, "n1", &peers, .{}, &transport);
    defer raft.deinit();
    raft.state = .leader;
    raft.current_term = 1;
    _ = try raft.appendEntry("cmd");
    raft.last_heartbeat_ms = 0; // heartbeat due on the first tick

    try raft.tick();
    try testing.expectEqual(@as(usize, 1), WireCount.appends); // the round went out

    // The heartbeat is no longer due, so this tick stages nothing — and must
    // send nothing (it used to re-deliver the just-applied round at term 0).
    try raft.tick();
    try testing.expectEqual(@as(usize, 1), WireCount.appends);

    // Demoted by a higher-term heartbeat from the configured peer: the stale
    // round must not leak onto the wire from follower ticks either.
    const demote = try raft.handleAppendEntries(.{
        .term = 2,
        .leader_id = "n2",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{},
        .leader_commit = 0,
    });
    try testing.expect(demote.success);
    try testing.expectEqual(RaftState.follower, raft.getState());

    try raft.tick(); // election not due — handleAppendEntries reset the deadline
    try testing.expectEqual(@as(usize, 1), WireCount.appends);
    try testing.expectEqual(@as(usize, 0), WireCount.votes);
    try testing.expectEqual(@as(usize, 0), WireCount.snapshots);
}
