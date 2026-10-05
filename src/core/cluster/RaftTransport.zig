//! Real Raft transport — the layer `docs/DISTRIBUTED.md`「真选主要什么」describes.
//!
//! `RaftElection` owns the algorithm and only calls out through
//! `ElectionTransport` (three bare function pointers). This file is the
//! implementation the framework used to leave to the app:
//!
//! - **outbound** — `TransportImpl(N).send*` encodes an RPC, dials the peer and
//!   writes one frame. `sendVoteRequest` is fire-and-forget (a failed dial is a
//!   *dropped message* — Raft re-sends); `sendAppendEntries` and
//!   `sendInstallSnapshot` are synchronous and read the reply from the same
//!   connection, answering `AppendEntriesResponse{ .success = false }` /
//!   `InstallSnapshotResponse{ .term = 0 }` when the message is lost.
//! - **inbound** — `handleConnection` reads one frame, dispatches it into
//!   `RaftElection.handleVoteRequest` / `handleAppendEntries` /
//!   `handleVoteResponse` / `handleInstallSnapshot`, and writes the reply back
//!   on the same connection. `InboundServer` drives that from an accept loop.
//! - **address book** — peer id → `host:port` (`BootstrapConfig.peers` form).
//!
//! Vote responses: the candidate's `sendVoteRequest` has already closed its
//! socket when a vote is decided, so the voter *also* pushes the response to the
//! candidate's inbound server — that is the 「应答走入站」path. Without it a
//! tick-driven election would never produce a leader.
//!
//! `RaftElection.tick()` stays externally driven: the tick is what starts
//! elections and sends heartbeats, so keep calling it from your loop.

const std = @import("std");
const builtin = @import("builtin");
const NetworkTransport = @import("NetworkTransport.zig");
const netdial = @import("../netdial.zig");
const sockread = @import("../sockread.zig");
const ClusterAuth = @import("ClusterAuth.zig").ClusterAuth;
const RaftElection = @import("RaftElection.zig").RaftElection;
const ElectionConfig = @import("RaftElection.zig").ElectionConfig;
const Peer = @import("RaftElection.zig").Peer;
const PeerKey = @import("RaftElection.zig").PeerKey;
const VoteRequest = @import("RaftElection.zig").VoteRequest;
const VoteResponse = @import("RaftElection.zig").VoteResponse;
const AppendEntriesRequest = @import("RaftElection.zig").AppendEntriesRequest;
const AppendEntriesResponse = @import("RaftElection.zig").AppendEntriesResponse;
const InstallSnapshotRequest = @import("RaftElection.zig").InstallSnapshotRequest;
const InstallSnapshotResponse = @import("RaftElection.zig").InstallSnapshotResponse;
const LogEntry = @import("RaftElection.zig").LogEntry;
const RaftState = @import("RaftElection.zig").RaftState;
const Time = @import("../Time.zig");

const log = std.log.scoped(.raft_transport);

// ── Wire format ─────────────────────────────────────────────────────────────
//
// Framing is NetworkTransport's: 4-byte big-endian length + payload. The payload
// is 1 tag byte + big-endian fixed-width fields; strings and byte blobs are a
// u16 length followed by that many bytes.
//
// With `ElectionConfig.cluster_secret` set, every frame on the cluster port is
// `[4-byte BE len][tag][payload][mac: 32 raw bytes]` and the MAC covers
// `[tag][payload]` — `len` counts tag + payload + MAC, which is why the length
// side of `recv` needs no change. Verification happens **before** decoding and
// the MAC is stripped there, so `tagOf` / `payloadOf` / the six `decode*` read
// exactly the bytes they read when the feature is off
// (`docs/dev/cluster-auth-design.md` §3.1).
//
// A-1 (`ElectionConfig.own_key` / `peer_keys`): the frame shape is unchanged —
// what changes is **which key** the MAC is checked against. Instead of one
// shared secret, a frame is verified with the key of the sender id it claims
// (requests carry `candidate_id` / `leader_id`; a vote response carries
// `responder_id`; the synchronous RPC replies are verified against the peer the
// caller dialled). Raft needs no handshake for this — unlike the bus
// (`docs/dev/cluster-identity-design.md`): its RPCs are one short
// request/response connection each, so a challenge/response would cost an RTT
// per RPC, while the claimed id already travels inside the MAC's coverage.
// Pinning the identity **per frame** costs nothing extra: only the holder of
// node-X's key can produce a frame that verifies as X.

/// First byte of a payload: which RPC the rest carries.
pub const MessageTag = enum(u8) {
    vote_request = 1,
    vote_response = 2,
    append_entries = 3,
    append_entries_response = 4,
    install_snapshot = 5,
    install_snapshot_response = 6,
};

/// Reasons `decode` rejects a payload. Every failure means "drop this frame and
/// keep reading": the cursor never advances past the bad bytes, so callers must
/// not try to re-parse the same buffer after one of these.
pub const DecodeError = error{
    /// The cursor ran past the declared length — the payload is shorter than its
    /// length prefixes claim. Callers should resync from the next frame instead of
    /// retrying with the same bytes.
    TruncatedMessage,
    /// The version/tag byte is not one of the known `MessageTag` values. Treat it as
    /// a protocol mismatch (peer speaks a newer wire version) and log the byte.
    UnknownMessageTag,
    /// The message is internally inconsistent for its tag — e.g. a response type
    /// arrived where a request was expected. Drop it and surface the bug.
    UnexpectedMessageTag,
    /// An `append_entries` frame declared more entries than
    /// [`MAX_ENTRIES_PER_FRAME`]. Returned **before** the entry array is
    /// allocated, so an oversized count costs the frame and nothing else.
    EntryCountTooLarge,
};

/// Upper bound on the entry count one `append_entries` frame may carry.
///
/// The count is a u16 on the wire, and `decodeAppendEntries` used to hand it
/// straight to `allocator.alloc(LogEntry, count)`: a frame of a few dozen bytes
/// could therefore ask for 65535 × 32 B ≈ 2 MB, allocated **before** the body it
/// would have to contain was validated. The bound is what makes the allocation
/// a function of the frame instead of a function of a peer's number.
///
/// 4096 is 40× the `ElectionConfig.max_append_entries` default and ≈128 KiB of
/// `LogEntry`, i.e. comfortably above any sane chunking size — but it is a hard
/// wire bound, so a peer whose `max_append_entries` exceeds it has its frames
/// dropped (and replication to that peer stalls: the sender keeps re-sending the
/// same too-large batch). `ElectionConfig.max_append_entries` is documented as
/// bounded by this constant; a cluster is not required to use the same chunking
/// size, only to stay under this ceiling on both ends.
pub const MAX_ENTRIES_PER_FRAME: u16 = 4096;

/// Cursor over one payload (the bytes after the tag).
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) DecodeError![]const u8 {
        if (n > self.bytes.len - self.pos) return error.TruncatedMessage;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn fixed(self: *Cursor, comptime n: usize) DecodeError!*const [n]u8 {
        return @ptrCast(try self.take(n));
    }

    fn u8v(self: *Cursor) DecodeError!u8 {
        return (try self.take(1))[0];
    }

    fn u16v(self: *Cursor) DecodeError!u16 {
        return std.mem.readInt(u16, try self.fixed(2), .big);
    }

    fn u64v(self: *Cursor) DecodeError!u64 {
        return std.mem.readInt(u64, try self.fixed(8), .big);
    }

    fn boolv(self: *Cursor) DecodeError!bool {
        return (try self.u8v()) != 0;
    }

    /// u16-length-prefixed bytes, copied into `allocator` (an arena in practice).
    fn str(self: *Cursor, allocator: std.mem.Allocator) ![]const u8 {
        return allocator.dupe(u8, try self.take(try self.u16v()));
    }
};

fn putU8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u8) !void {
    try out.append(allocator, v);
}

fn putU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .big);
    try out.appendSlice(allocator, &buf);
}

fn putU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .big);
    try out.appendSlice(allocator, &buf);
}

fn putBool(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: bool) !void {
    try putU8(out, allocator, @intFromBool(v));
}

/// u16 length + bytes: over-long fields are a wire limitation, not a truncation.
fn putStr(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try putU16(out, allocator, std.math.cast(u16, s.len) orelse return error.FieldTooLong);
    try out.appendSlice(allocator, s);
}

/// The tag of a payload, or null when it is empty or unknown (caller drops it).
fn tagOf(frame: []const u8) ?MessageTag {
    if (frame.len < 1) return null;
    return std.enums.fromInt(MessageTag, frame[0]);
}

fn payloadOf(frame: []const u8, expected: MessageTag) DecodeError![]const u8 {
    const tag = tagOf(frame) orelse return error.UnknownMessageTag;
    if (tag != expected) return error.UnexpectedMessageTag;
    return frame[1..];
}

pub fn encodeVoteRequest(out: *std.ArrayList(u8), allocator: std.mem.Allocator, req: VoteRequest) !void {
    try putU8(out, allocator, @backingInt(MessageTag.vote_request));
    try putU64(out, allocator, req.term);
    try putStr(out, allocator, req.candidate_id);
    try putU64(out, allocator, req.last_log_index);
    try putU64(out, allocator, req.last_log_term);
}

/// `responder_id` travels in the frame because the candidate feeds the response
/// into `handleVoteResponse(resp, from_peer)`.
pub fn encodeVoteResponse(out: *std.ArrayList(u8), allocator: std.mem.Allocator, resp: VoteResponse, responder_id: []const u8) !void {
    try putU8(out, allocator, @backingInt(MessageTag.vote_response));
    try putU64(out, allocator, resp.term);
    try putBool(out, allocator, resp.vote_granted);
    try putStr(out, allocator, responder_id);
}

pub fn encodeAppendEntries(out: *std.ArrayList(u8), allocator: std.mem.Allocator, req: AppendEntriesRequest) !void {
    try putU8(out, allocator, @backingInt(MessageTag.append_entries));
    try putU64(out, allocator, req.term);
    try putStr(out, allocator, req.leader_id);
    try putU64(out, allocator, req.prev_log_index);
    try putU64(out, allocator, req.prev_log_term);
    try putU64(out, allocator, req.leader_commit);
    try putU16(out, allocator, std.math.cast(u16, req.entries.len) orelse return error.FieldTooLong);
    for (req.entries) |entry| {
        try putU64(out, allocator, entry.term);
        try putU64(out, allocator, entry.index);
        try putStr(out, allocator, entry.command);
    }
}

pub fn encodeAppendEntriesResponse(out: *std.ArrayList(u8), allocator: std.mem.Allocator, resp: AppendEntriesResponse) !void {
    try putU8(out, allocator, @backingInt(MessageTag.append_entries_response));
    try putU64(out, allocator, resp.term);
    try putBool(out, allocator, resp.success);
    try putU64(out, allocator, resp.match_index);
}

pub fn encodeInstallSnapshot(out: *std.ArrayList(u8), allocator: std.mem.Allocator, req: InstallSnapshotRequest) !void {
    try putU8(out, allocator, @backingInt(MessageTag.install_snapshot));
    try putU64(out, allocator, req.term);
    try putStr(out, allocator, req.leader_id);
    try putU64(out, allocator, req.last_included_index);
    try putU64(out, allocator, req.last_included_term);
    try putU64(out, allocator, req.offset);
    try putBool(out, allocator, req.done);
    try putStr(out, allocator, req.data);
}

pub fn encodeInstallSnapshotResponse(out: *std.ArrayList(u8), allocator: std.mem.Allocator, resp: InstallSnapshotResponse) !void {
    try putU8(out, allocator, @backingInt(MessageTag.install_snapshot_response));
    try putU64(out, allocator, resp.term);
}

/// Strings are copied into `allocator`; an arena per inbound frame is the norm.
pub fn decodeVoteRequest(allocator: std.mem.Allocator, frame: []const u8) !VoteRequest {
    var cur = Cursor{ .bytes = try payloadOf(frame, .vote_request) };
    return .{
        .term = try cur.u64v(),
        .candidate_id = try cur.str(allocator),
        .last_log_index = try cur.u64v(),
        .last_log_term = try cur.u64v(),
    };
}

pub fn decodeVoteResponse(allocator: std.mem.Allocator, frame: []const u8) !struct { resp: VoteResponse, responder_id: []const u8 } {
    var cur = Cursor{ .bytes = try payloadOf(frame, .vote_response) };
    const term = try cur.u64v();
    const granted = try cur.boolv();
    return .{
        .resp = .{ .term = term, .vote_granted = granted },
        .responder_id = try cur.str(allocator),
    };
}

pub fn decodeAppendEntries(allocator: std.mem.Allocator, frame: []const u8) !AppendEntriesRequest {
    var cur = Cursor{ .bytes = try payloadOf(frame, .append_entries) };
    const term = try cur.u64v();
    const leader_id = try cur.str(allocator);
    const prev_log_index = try cur.u64v();
    const prev_log_term = try cur.u64v();
    const leader_commit = try cur.u64v();
    // The count is checked against the cap *before* the array exists, and before
    // a single entry is walked: a truncated body under an oversized count has to
    // be refused as `EntryCountTooLarge` (the count is wrong), not as
    // `TruncatedMessage` after a pointless allocation.
    const count = try cur.u16v();
    if (count > MAX_ENTRIES_PER_FRAME) return error.EntryCountTooLarge;
    const entries = try allocator.alloc(LogEntry, count);
    for (entries) |*entry| {
        entry.term = try cur.u64v();
        entry.index = try cur.u64v();
        entry.command = try cur.str(allocator);
    }
    return .{
        .term = term,
        .leader_id = leader_id,
        .prev_log_index = prev_log_index,
        .prev_log_term = prev_log_term,
        .entries = entries,
        .leader_commit = leader_commit,
    };
}

pub fn decodeAppendEntriesResponse(frame: []const u8) !AppendEntriesResponse {
    var cur = Cursor{ .bytes = try payloadOf(frame, .append_entries_response) };
    return .{ .term = try cur.u64v(), .success = try cur.boolv(), .match_index = try cur.u64v() };
}

pub fn decodeInstallSnapshot(allocator: std.mem.Allocator, frame: []const u8) !InstallSnapshotRequest {
    var cur = Cursor{ .bytes = try payloadOf(frame, .install_snapshot) };
    const term = try cur.u64v();
    const leader_id = try cur.str(allocator);
    const last_included_index = try cur.u64v();
    const last_included_term = try cur.u64v();
    const offset = try cur.u64v();
    const done = try cur.boolv();
    return .{
        .term = term,
        .leader_id = leader_id,
        .last_included_index = last_included_index,
        .last_included_term = last_included_term,
        .offset = offset,
        .data = try cur.str(allocator),
        .done = done,
    };
}

pub fn decodeInstallSnapshotResponse(frame: []const u8) !InstallSnapshotResponse {
    var cur = Cursor{ .bytes = try payloadOf(frame, .install_snapshot_response) };
    return .{ .term = try cur.u64v() };
}

fn sendAll(stream: std.Io.net.Stream, bytes: []const u8) !void {
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

/// Write one framed message — `send(MSG_NOSIGNAL)`, not
/// `ClusterConnection.send`'s raw `writev`: answering a peer that already closed
/// its socket (exactly what a fire-and-forget vote request leaves behind) would
/// otherwise raise SIGPIPE and take the process down. The framing is identical.
fn writeFrame(stream: std.Io.net.Stream, frame: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(frame.len), .big);
    try sendAll(stream, &header);
    try sendAll(stream, frame);
}

// ── Frame authentication (L1) ───────────────────────────────────────────────
//
// `docs/dev/cluster-auth-design.md` §3: an HMAC-SHA256 tag over `[tag][payload]`
// appended to the frame. The three helpers below are the whole mechanism — the
// call sites are one line each, and the encoders/decoders are untouched.

/// Length of the tag `sendSigned` appends and `verifiedRecv` strips.
const auth_mac_bytes = 32;

/// Sign `frame` (already `[tag][payload]`) and write it length-prefixed.
/// `frame` is NOT modified — the MAC is appended into a temp buffer, making the
/// wire bytes `[len][tag][payload][mac]`.
///
/// The write goes through `writeFrame`, not `ClusterConnection.send`: the latter
/// is a bare `writev`, and answering a peer that already closed its socket would
/// then raise SIGPIPE (`writeFrame`'s comment has the full story). The framing
/// is byte-for-byte the same.
fn sendSigned(key: [32]u8, conn: *NetworkTransport.ClusterConnection, frame: []const u8) !void {
    var mac: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, frame, &key);
    var signed = std.ArrayList(u8).empty;
    defer signed.deinit(conn.allocator);
    try signed.appendSlice(conn.allocator, frame);
    try signed.appendSlice(conn.allocator, &mac);
    try writeFrame(conn.stream, signed.items);
}

/// `conn.recv`, then split off the trailing MAC, verify it constant-time and
/// return the frame **without** it — so the existing decoders are untouched.
///
/// `error.ClusterAuthFailed` covers a frame too short to carry a MAC (a bare
/// frame from a peer that has no secret configured) as well as a MAC that does
/// not match; callers treat both as "drop this peer".
fn verifiedRecv(key: [32]u8, conn: *NetworkTransport.ClusterConnection, buf: *std.ArrayList(u8)) ![]const u8 {
    return verifyFrameMac(key, try conn.recv(buf));
}

/// The pure half of `verifiedRecv`: strip the trailing MAC and check it against
/// `key`, constant-time. Kept separate because the per-node path (A-1) must read
/// the claimed sender id out of the **unverified** bytes before it knows which
/// key to verify with.
fn verifyFrameMac(key: [32]u8, frame: []const u8) ![]const u8 {
    if (frame.len < auth_mac_bytes + 1) return error.ClusterAuthFailed;
    const signed_len = frame.len - auth_mac_bytes;

    // Raw bytes, not `ClusterAuth.verify`: that one re-hexes the tag it computes
    // before comparing, which cannot match a `[32]u8` MAC on the wire.
    var expected: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, frame[0..signed_len], &key);
    if (!ClusterAuth.timingSafeEql(&expected, frame[signed_len..])) return error.ClusterAuthFailed;
    return frame[0..signed_len];
}

/// A-3: `verifyFrameMac` under a rotation window — `current` first, then
/// `previous` while the window is open. At most two HMACs per frame, only
/// during a rotation; signing never uses `previous`.
fn verifyFrameMacWindowed(keys: NodeKeys, frame: []const u8) ![]const u8 {
    if (verifyFrameMac(keys.current, frame)) |payload| return payload else |_| {}
    const prev = keys.previous orelse return error.ClusterAuthFailed;
    return verifyFrameMac(prev, frame);
}

/// `verifiedRecv` under a rotation window — see `verifyFrameMacWindowed`.
fn verifiedRecvWindowed(keys: NodeKeys, conn: *NetworkTransport.ClusterConnection, buf: *std.ArrayList(u8)) ![]const u8 {
    return verifyFrameMacWindowed(keys, try conn.recv(buf));
}

// ── A-1: per-node identity (which key a frame is keyed with) ────────────────
//
// `docs/dev/cluster-identity-design.md`'s threat model applied to the Raft
// port: attacker B holds **one** node's key (a cluster member, or someone who
// obtained that node's credential) and must be unable to appear as any other
// node. With one shared `cluster_secret` B appears as anyone; with per-node
// keys B appears only as the node whose key it holds.
//
// The bus pins identity per *connection* (challenge/response handshake, then a
// bound id for the connection's life). Raft's RPCs are one short connection
// per request/response, so the same shape would cost an RTT per RPC — instead
// the identity is pinned per **frame**: the sender id is already inside every
// frame (`candidate_id` / `leader_id` / `responder_id`), and inside the MAC's
// coverage, so verifying `HMAC(peer_keys[claimed], frame)` binds the two
// together with no extra round trip. Replay needs no sequence numbers here:
// term/index monotonicity plus the idempotent AppendEntries/InstallSnapshot
// handlers already refuse staleness (`cluster-auth-design.md` §3.6) — the bus
// needed `seq` because it has no equivalent of term.

/// How the frames on the cluster port are keyed, derived from the config.
const AuthMode = enum { bare, shared, per_node };

/// Per-node wins over `cluster_secret` when both are set: falling back to the
/// shared key on a per-node miss would re-open exactly the hole this mode
/// exists to close (any PSK holder could sign as any node). Neither set is the
/// bare development path `ClusterBootstrap.start()` gates multi-node clusters
/// away from.
fn authMode(config: *const ElectionConfig) AuthMode {
    if (config.own_key != null or config.peer_keys.len > 0) return .per_node;
    if (config.cluster_secret != null) return .shared;
    return .bare;
}

/// The key a frame **from** `id` must verify against: that node's own key.
/// `id == local_id` maps to our own `own_key` (null when unset — i.e. refused,
/// which is also the right answer for the nonsense claim "I am you").
///
/// Callers resolving a *verification* key want `nodeKeys` (the rotation window
/// travels with it); this current-only form remains for "does a key exist for
/// this id at all" questions (the vote-relay gate, the fail-closed tests).
fn nodeKey(config: *const ElectionConfig, local_id: []const u8, id: []const u8) ?[32]u8 {
    const keys = nodeKeys(config, local_id, id) orelse return null;
    return keys.current;
}

/// What a frame from `id` may verify against: the current key, and — inside a
/// rotation window (A-3, `RaftElection.rotatePeerKey`) — the key it replaced.
/// Signing never uses `previous`; the window exists so a peer mid-rotation
/// (its own key already swapped, our record not yet closed) still verifies.
/// All value copies: a caller holding `key_lock` releases it before the HMAC.
const NodeKeys = struct { current: [32]u8, previous: ?[32]u8 };

fn nodeKeys(config: *const ElectionConfig, local_id: []const u8, id: []const u8) ?NodeKeys {
    if (std.mem.eql(u8, id, local_id)) {
        // Our own key signs and has no window on the verify side: the window
        // for *our* rotation lives in the peers' `previous` slot for us.
        const own = config.own_key orelse return null;
        return .{ .current = own, .previous = null };
    }
    for (config.peer_keys) |pk| {
        if (std.mem.eql(u8, pk.id, id)) return .{ .current = pk.key, .previous = pk.previous };
    }
    return null;
}

/// The sender id a frame **claims**, read from the unverified bytes. The
/// result borrows `frame` and is trusted only far enough to select the
/// verification key; the raft still sees a `candidate_id` / `leader_id` /
/// `responder_id` decoded from the verified bytes, which are the same bytes.
///
/// The id's offset is tag-dependent (`[tag][term: u64]…`):
/// `vote_request` / `append_entries` / `install_snapshot` carry it first;
/// `vote_response` carries `granted` in between. The two *response* tags for
/// the synchronous RPCs carry no id at all — a caller reading such a reply
/// verifies it against the peer it dialled, and inbound they are strays
/// (`handleConnection` drops both tags), so no key can be selected for them.
fn claimedSenderId(frame: []const u8) ?[]const u8 {
    const tag = tagOf(frame) orelse return null;
    const off: usize = switch (tag) {
        .vote_request, .append_entries, .install_snapshot => 1 + 8,
        .vote_response => 1 + 8 + 1,
        .append_entries_response, .install_snapshot_response => return null,
    };
    if (frame.len < off + 2) return null;
    const n = std.mem.readInt(u16, frame[off..][0..2], .big);
    if (frame.len < off + 2 + @as(usize, n)) return null;
    return frame[off + 2 ..][0..n];
}

/// What this node signs an outbound frame with. `.drop` is the fail-closed
/// answer for "per-node mode but no `own_key`": sending bare there would be a
/// silent downgrade to the unauthenticated wire, so the message is lost instead
/// (Raft re-sends; the misconfiguration surfaces as a cluster that cannot make
/// progress plus the debug line, not as quiet plaintext).
const SignAuth = union(enum) { bare, key: [32]u8, drop };

fn signAuth(config: *const ElectionConfig) SignAuth {
    return switch (authMode(config)) {
        .bare => .bare,
        .shared => .{ .key = config.cluster_secret.? },
        .per_node => if (config.own_key) |k| .{ .key = k } else .drop,
    };
}

/// Write one frame on an already-open connection under a resolved `SignAuth`.
/// One place decides, so the outbound half (all three RPCs), the reply, and
/// the vote-response relay cannot drift apart.
fn writeFrameSigned(auth: SignAuth, conn: *NetworkTransport.ClusterConnection, frame: []const u8) !void {
    switch (auth) {
        .bare => try writeFrame(conn.stream, frame),
        .key => |k| try sendSigned(k, conn, frame),
        .drop => return error.OwnKeyMissing,
    }
}

/// The read side of the signing rule: the peer signs its replies with its own
/// key, so the reply read has to verify against the key of whoever answered
/// (the dialled peer, resolved by the caller) — and a decoder that ignores
/// trailing bytes would otherwise accept a frame it never authenticated.
/// `null` is the bare path. The windowed keys accept a reply signed with the
/// peer's *previous* key too, for the same mid-rotation reason as the inbound
/// verifier (`verifyFrameMacWindowed`).
fn readFrameAuth(keys: ?NodeKeys, conn: *NetworkTransport.ClusterConnection, buf: *std.ArrayList(u8)) ![]const u8 {
    if (keys) |ks| return verifiedRecvWindowed(ks, conn, buf);
    return conn.recv(buf);
}

/// Dial a peer, with the dial itself bounded by `timeout_ms` (`0` = no bound).
///
/// `NetworkTransport.connect` is unreferenced in-tree and does not compile
/// against this Zig (`IpAddress.ConnectOptions` now requires `.mode`), so the
/// two lines live here; it can go back to calling that helper once fixed.
///
/// **The bound cannot come from `IpAddress.ConnectOptions.timeout`.** The field
/// exists (`std/Io/net.zig:341`) but neither `std.Io` backend implements it:
/// `std/Io/Threaded.zig:12358` is
///
///     if (options.timeout != .none) @panic("TODO implement netConnectIpPosix with timeout");
///
/// and `netConnectIpWindows` one function below is the same. Measured on
/// 0.17.0-dev.2151+2ec5523d5: passing a `.timeout` and dialling loopback
/// `127.0.0.1:1` aborts the process (`panic: TODO implement netConnectIpPosix
/// with timeout`, SIGABRT). So the field is a trap rather than a knob, and the
/// bound is built here out of non-blocking `connect` + `poll`.
///
/// It is worth having: without it a peer whose SYNs are dropped (a firewall, a
/// wedged box) costs the kernel's default — measured on macOS, a link-local
/// address with nothing listening for it is still unanswered after 25 s — and
/// `RaftElection.tick`'s replication round dials from inside `RaftLock`. The
/// write and the reply wait were already bounded (`sockread.setSendTimeout` /
/// `setRecvTimeout`); this is the third side of the same RPC.
fn dialTo(allocator: std.mem.Allocator, io: std.Io, ep: Endpoint, timeout_ms: u32) !NetworkTransport.ClusterConnection {
    const addr = try std.Io.net.IpAddress.parse(ep.host, ep.port);
    const stream = try connectTimeout(io, addr, timeout_ms);
    return NetworkTransport.ClusterConnection.init(allocator, stream, io);
}

/// `IpAddress.ConnectError` plus the one error std's connect cannot report on
/// this toolchain, because it never reaches the kernel to find out.
pub const ConnectTimeoutError = std.Io.net.IpAddress.ConnectError || error{ConnectTimeout};

/// Connect to `addr`, giving up `timeout_ms` after the call starts. `0` means
/// no bound — `sockread.setRecvTimeout`'s convention, and what lets a pre-fix
/// `rpc_timeout_ms = 0` config keep the unbounded behaviour.
///
/// The returned stream is **blocking**, like every other socket `std.Io` hands
/// out: `sockread.readSome` is a bare `read` and `writeFull` a bare `write`, so
/// a non-blocking socket would come back `EAGAIN` — which the WebSocket write
/// path, for one, treats as a programmer bug and panics on in debug builds.
///
/// POSIX only: on Windows, where `std.posix.system` has no `poll`, this falls
/// back to the unbounded dial — `netdial.connectBlocking`, which delegates to
/// `IpAddress.connect` there. The raw-syscall layer it is built on
/// (`sockread`) is POSIX-only already. The unbounded branch goes through
/// netdial on POSIX too: std's blocking connect panics when a signal
/// interrupts it (EINTR retry → EISCONN → `errnoBug`; see `core/netdial.zig`).
pub fn connectTimeout(io: std.Io, addr: std.Io.net.IpAddress, timeout_ms: u32) ConnectTimeoutError!std.Io.net.Stream {
    if (builtin.os.tag == .windows or timeout_ms == 0) {
        // The unbounded fallback still must not panic on EINTR→EISCONN (std's
        // posixConnect reads the retry's EISCONN as errnoBug — the batch-112
        // trap), so it dials through netdial rather than std. On Windows
        // netdial delegates back to std, which is fine there.
        return netdial.connectBlocking(io, addr);
    }

    var storage: std.Io.Threaded.PosixAddress = undefined;
    const addr_len = std.Io.Threaded.addressToPosix(&addr, &storage);

    // Raw syscalls, not the `std.posix.*` wrappers: this call has to be able to
    // *return* an error, and the wrappers map several errno values onto
    // `unreachable` (`std.posix.poll`'s `.FAULT`/`.INVAL`, `setsockopt`'s
    // `.INVAL` — the reason `sockread` exists at all). Same shape as
    // `sockread.applyTimeout`.
    const rc = std.posix.system.socket(std.Io.Threaded.posixAddressFamily(&addr), std.posix.SOCK.STREAM, 0);
    const fd: std.posix.socket_t = switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .INVAL => return error.ProtocolUnsupportedBySystem,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
        .PROTOTYPE => return error.SocketModeUnsupported,
        else => |e| return std.posix.unexpectedErrno(e),
    };
    errdefer std.Io.Threaded.closeFd(fd);

    // Neither of these can be a `socket()` flag: macOS rejects `SOCK.NONBLOCK`
    // there (measured: `socket()` → `EINVAL`), which is why std sets
    // `FD_CLOEXEC` by hand on darwin too.
    if (fcntlSet(fd, std.posix.F.SETFD, std.posix.FD_CLOEXEC)) |e| return std.posix.unexpectedErrno(e);
    if (setNonblock(fd, true)) |e| return std.posix.unexpectedErrno(e);

    switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, addr_len))) {
        // Immediate: loopback, or a listener on this host. That is the common
        // case between nodes in one rack, and every case in these tests.
        .SUCCESS => {},
        // The SYN is out and the kernel reports the outcome as writability plus
        // `SO_ERROR`. `EINTR` is the same state reached with a signal on the
        // way in: the attempt is still in flight and must not be retried.
        .INPROGRESS, .AGAIN, .INTR => try awaitConnect(fd, timeout_ms),
        .ADDRNOTAVAIL => return error.AddressUnavailable,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .ALREADY => return error.ConnectionPending,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .HOSTUNREACH => return error.HostUnreachable,
        .NETUNREACH => return error.NetworkUnreachable,
        .TIMEDOUT => return error.Timeout,
        .ACCES => return error.AccessDenied,
        .NETDOWN => return error.NetworkDown,
        else => |e| return std.posix.unexpectedErrno(e),
    }

    // Hand back the same state `netConnectIpPosix` does: a blocking socket
    // whose `address` is the *local* endpoint `getsockname` reports (i.e. the
    // ephemeral port). The name is best-effort there too — a failure leaves a
    // perfectly usable stream.
    if (setNonblock(fd, false)) |e| return std.posix.unexpectedErrno(e);
    var local: std.Io.Threaded.PosixAddress = undefined;
    var local_len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    const local_addr = if (std.posix.errno(std.posix.system.getsockname(fd, &local.any, &local_len)) == .SUCCESS)
        std.Io.Threaded.addressFromPosix(&local)
    else
        addr;
    return .{ .socket = .{ .handle = fd, .address = local_addr } };
}

/// Wait out an in-flight `connect` (`EINPROGRESS`), up to `timeout_ms` from
/// *now*.
///
/// `poll(POLLOUT)` means "the kernel is done with the attempt", not "it
/// worked": `SO_ERROR` carries the verdict, and a refused connection arrives
/// exactly that way — writable, then `ECONNREFUSED`.
fn awaitConnect(fd: std.posix.socket_t, timeout_ms: u32) ConnectTimeoutError!void {
    const started = Time.monotonicNowMilliseconds();
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    while (true) {
        const elapsed = Time.monotonicNowMilliseconds() - started;
        if (elapsed >= timeout_ms) return error.ConnectTimeout;
        const prc = std.posix.system.poll(&fds, 1, @intCast(timeout_ms - elapsed));
        switch (std.posix.errno(prc)) {
            .SUCCESS => {},
            // A signal, not an answer: recompute what is left and wait again.
            .INTR => continue,
            else => |e| return std.posix.unexpectedErrno(e),
        }
        if (prc == 0) return error.ConnectTimeout;
        break;
    }

    var so_error: i32 = 0;
    var len: std.posix.socklen_t = @sizeOf(i32);
    switch (std.posix.errno(std.posix.system.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&so_error), &len))) {
        .SUCCESS => {},
        else => |e| return std.posix.unexpectedErrno(e),
    }
    // The mapping `std.Io.Threaded.posixConnect` applies to the blocking form,
    // so a caller cannot tell which of the two dialled.
    switch (so_error) {
        0 => {},
        @backingInt(std.posix.E.ADDRNOTAVAIL) => return error.AddressUnavailable,
        @backingInt(std.posix.E.CONNREFUSED) => return error.ConnectionRefused,
        @backingInt(std.posix.E.CONNRESET) => return error.ConnectionResetByPeer,
        @backingInt(std.posix.E.HOSTUNREACH) => return error.HostUnreachable,
        @backingInt(std.posix.E.NETUNREACH) => return error.NetworkUnreachable,
        @backingInt(std.posix.E.TIMEDOUT) => return error.Timeout,
        @backingInt(std.posix.E.ACCES), @backingInt(std.posix.E.PERM) => return error.AccessDenied,
        @backingInt(std.posix.E.NETDOWN) => return error.NetworkDown,
        else => |e| {
            log.debug("[raft] connect failed with errno {d}", .{e});
            return error.Unexpected;
        },
    }
}

/// Set or clear `O_NONBLOCK`; returns the errno when the kernel refuses.
///
/// Not a `socket()` flag: macOS rejects `SOCK.NONBLOCK` there (measured:
/// `socket()` → `EINVAL`). `F_SETFL` cannot touch the access-mode bits, so `0`
/// clears exactly `O_NONBLOCK` — the standard way to make a socket blocking
/// again.
fn setNonblock(fd: std.posix.socket_t, on: bool) ?std.posix.E {
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    return fcntlSet(fd, std.posix.F.SETFL, if (on) nonblock else 0);
}

/// `fcntl` with the error reported as a value — `std.posix` has no `fcntl`
/// wrapper in this toolchain, and the raw call is what `sockread.applyTimeout`
/// does for `setsockopt` for the same reason.
fn fcntlSet(fd: std.posix.socket_t, cmd: i32, arg: u32) ?std.posix.E {
    const e = std.posix.errno(std.posix.system.fcntl(fd, cmd, @as(usize, arg)));
    return if (e == .SUCCESS) null else e;
}

// ── Address book ────────────────────────────────────────────────────────────

pub const Endpoint = struct {
    host: []const u8,
    port: u16,
};

/// `"host:port"` (the form peers are configured with), or null when malformed.
pub fn parseEndpoint(address: []const u8) ?Endpoint {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return null;
    if (colon == 0 or colon + 1 == address.len) return null;
    const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch return null;
    if (port == 0) return null;
    return .{ .host = address[0..colon], .port = port };
}

/// peer id → `host:port`. Populate from `BootstrapConfig.peers` (whose strings
/// are `"host:port"`) or one entry at a time with `add`.
pub const AddressBook = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Endpoint),

    pub fn init(allocator: std.mem.Allocator) AddressBook {
        return .{ .allocator = allocator, .entries = std.StringHashMap(Endpoint).init(allocator) };
    }

    pub fn deinit(self: *AddressBook) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.host);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    /// Copy first, free second: `host` may alias the entry being replaced.
    pub fn add(self: *AddressBook, id: []const u8, host: []const u8, port: u16) !void {
        const host_copy = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(host_copy);
        if (self.entries.getPtr(id)) |existing| {
            self.allocator.free(existing.host);
            existing.* = .{ .host = host_copy, .port = port };
            return;
        }
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        try self.entries.put(id_copy, .{ .host = host_copy, .port = port });
    }

    /// `add` straight from a `"host:port"` string.
    pub fn addEndpoint(self: *AddressBook, id: []const u8, address: []const u8) !void {
        const ep = parseEndpoint(address) orelse return error.InvalidAddress;
        try self.add(id, ep.host, ep.port);
    }

    pub fn lookup(self: *const AddressBook, id: []const u8) ?Endpoint {
        return self.entries.get(id);
    }
};

// ── Outbound transport ──────────────────────────────────────────────────────

/// One instance per node. `ElectionTransport` is a pair of *bare* function
/// pointers (no context argument), so an instance is reached through per-slot
/// statics: nodes inside one process use different slots (`TransportImpl(1)`,
/// `TransportImpl(2)`, …), a production node uses `TransportImpl(0)`.
///
/// The impl must outlive the `RaftElection` it is given (the raft keeps a
/// pointer into it) and must not move after `init`.
pub fn TransportImpl(comptime slot: usize) type {
    return struct {
        const Self = @This();

        /// Load-bearing: with `slot` unreferenced, this Zig build memoizes
        /// the generic into ONE type for every slot (measured: `Impl(0) ==
        /// Impl(2)` at comptime), collapsing the per-slot `bound` static
        /// into a single variable the last `init` wins — every in-process
        /// node then dispatches through one node's transport. Referencing
        /// the parameter in the type body keeps instantiations distinct.
        pub const slot_id: usize = slot;

        allocator: std.mem.Allocator,
        io: std.Io,
        /// The local node: responses arriving inbound are fed into it.
        raft: *RaftElection,
        addresses: AddressBook,
        vtable: VTable = .{ .sendVoteRequest = thunkVoteRequest, .sendAppendEntries = thunkAppendEntries, .sendInstallSnapshot = thunkInstallSnapshot },

        /// `ElectionConfig.rpc_timeout_ms`, read from the raft at send time.
        ///
        /// Deliberately **not** cached in a field filled by `init`: the wiring
        /// everyone uses calls `impl.init(allocator, io, &raft)` *before*
        /// `raft = try RaftElection.init(...)`, so anything `init` read out of
        /// `raft` would be reading `undefined`. The config is written once by
        /// `RaftElection.init` and never again, so reading it here is free and
        /// cannot see a torn value.
        fn rpcTimeoutMs(self: *const Self) u32 {
            return self.raft.config.rpc_timeout_ms;
        }

        /// Shape of `RaftElection.ElectionTransport` — `transport()` hands out a
        /// pointer to this field.
        pub const VTable = struct {
            sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
            sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
            sendInstallSnapshot: *const fn (?[]const u8, []const u8, InstallSnapshotRequest) InstallSnapshotResponse,
        };

        /// The impl the thunks dispatch to.
        var bound: ?*Self = null;

        /// Build in place — the raft stores pointers into this struct, so it must
        /// live at a stable address. Also binds the slot.
        pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, raft: *RaftElection) void {
            self.* = .{
                .allocator = allocator,
                .io = io,
                .raft = raft,
                .addresses = AddressBook.init(allocator),
            };
            bound = self;
        }

        pub fn deinit(self: *Self) void {
            if (bound == self) bound = null;
            self.addresses.deinit();
            self.* = undefined;
        }

        /// The interface `RaftElection.init` wants. Valid until `deinit`.
        pub fn transport(self: *Self) RaftElection.ElectionTransport {
            return @ptrCast(&self.vtable);
        }

        /// `RaftElection.Peer.address` when set, else the address book, else the
        /// peer id itself when that happens to be a `host:port` string.
        pub fn resolve(self: *Self, peer_id: ?[]const u8, address: []const u8) ?Endpoint {
            if (peer_id) |id| if (self.addresses.lookup(id)) |ep| return ep;
            if (parseEndpoint(address)) |ep| return ep;
            if (peer_id) |id| if (parseEndpoint(id)) |ep| return ep;
            return null;
        }

        /// The two keys one outbound RPC needs, resolved before the dial.
        /// `sign` is always this node's own key (`signAuth`); `verify` is the
        /// key the *answering* peer signs its reply with — under per-node that
        /// is the peer's own key, resolved by the dial target's id, with its
        /// rotation window (`NodeKeys.previous`, A-3) riding along.
        const OutboundKeys = struct { sign: SignAuth, verify: ?NodeKeys };

        /// Resolve both halves of one outbound RPC, or fail closed: per-node
        /// mode with a keyless target (or no `own_key`) returns null, and the
        /// caller loses the message instead of dialling. The dial target is
        /// the identity the reply has to verify against, so a null `peer_id`
        /// there is unverifiable and refused for the same reason.
        ///
        /// Holds the raft's `key_lock` for the lookup: the callers run inside
        /// `RaftLock` (`tick`'s round) or on an app thread, while
        /// `revokePeerKey` may be rebuilding the table on a third. Everything
        /// returned is a value copy, so the lock never spans the dial.
        fn outboundKeys(self: *Self, peer_id: ?[]const u8) ?OutboundKeys {
            const raft = self.raft;
            const config = &raft.config;
            raft.key_lock.acquire();
            defer raft.key_lock.release();
            switch (authMode(config)) {
                .bare => return .{ .sign = .bare, .verify = null },
                .shared => return .{ .sign = .{ .key = config.cluster_secret.? }, .verify = .{ .current = config.cluster_secret.?, .previous = null } },
                .per_node => {
                    const sign = signAuth(config);
                    if (sign == .drop) return null;
                    const id = peer_id orelse return null;
                    const verify = nodeKeys(config, raft.local_id, id) orelse return null;
                    return .{ .sign = sign, .verify = verify };
                },
            }
        }

        /// Dial + write once. A failure here is a lost message (Raft re-sends),
        /// so it is worth a debug line and nothing more.
        pub fn sendFrame(self: *Self, ep: Endpoint, frame: []const u8, auth: SignAuth) void {
            var conn = dialTo(self.allocator, self.io, ep, self.rpcTimeoutMs()) catch |err| {
                log.debug("[raft] connect {s}:{d} failed, message dropped ({})", .{ ep.host, ep.port, err });
                return;
            };
            defer conn.deinit();
            // The write half of the same bound: a peer that accepts and then
            // stops reading would otherwise block the writing thread on a full
            // send buffer, inside the same spin lock.
            sockread.setSendTimeout(conn.stream, self.rpcTimeoutMs());
            writeFrameSigned(auth, &conn, frame) catch |err| {
                log.debug("[raft] write {s}:{d} failed, message dropped ({})", .{ ep.host, ep.port, err });
            };
        }

        /// Fire-and-forget: the voter answers on its own initiative (see
        /// `handleConnection`), so this returns as soon as the frame is out.
        pub fn sendVoteRequest(self: *Self, peer_id: ?[]const u8, address: []const u8, req: VoteRequest) void {
            const ep = self.resolve(peer_id, address) orelse {
                log.debug("[raft] no address for peer {s}, vote request dropped", .{peer_id orelse "?"});
                return;
            };
            const keys = self.outboundKeys(peer_id) orelse {
                log.debug("[raft] no key for peer {s}, vote request dropped", .{peer_id orelse "?"});
                return;
            };
            var frame = std.ArrayList(u8).empty;
            defer frame.deinit(self.allocator);
            encodeVoteRequest(&frame, self.allocator, req) catch |err| {
                log.debug("[raft] encoding the vote request failed ({})", .{err});
                return;
            };
            self.sendFrame(ep, frame.items, keys.sign);
        }

        /// Synchronous: the follower answers on the same connection. Every
        /// failure mode (no address, dial, write, read, decode) is the same
        /// "lost message" answer — never a panic.
        pub fn sendAppendEntries(self: *Self, peer_id: ?[]const u8, address: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
            const lost = AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
            const ep = self.resolve(peer_id, address) orelse return lost;
            const keys = self.outboundKeys(peer_id) orelse {
                log.debug("[raft] no key for peer {s}, AppendEntries dropped", .{peer_id orelse "?"});
                return lost;
            };

            var frame = std.ArrayList(u8).empty;
            defer frame.deinit(self.allocator);
            encodeAppendEntries(&frame, self.allocator, req) catch |err| {
                log.debug("[raft] encoding AppendEntries failed ({})", .{err});
                return lost;
            };

            var conn = dialTo(self.allocator, self.io, ep, self.rpcTimeoutMs()) catch return lost;
            defer conn.deinit();
            sockread.setSendTimeout(conn.stream, self.rpcTimeoutMs());
            writeFrameSigned(keys.sign, &conn, frame.items) catch return lost;

            // Bound the wait for the reply as well as the dial: a peer that
            // accepts the connection and never answers is the failure this is
            // here for. It matters more than the connect bound, because this read
            // is the one that happens on every heartbeat from every leader — a
            // half-open peer would otherwise stop the cluster's ticker dead.
            sockread.setRecvTimeout(conn.stream, self.rpcTimeoutMs());

            var reply = std.ArrayList(u8).empty;
            defer reply.deinit(self.allocator);
            const bytes = readFrameAuth(keys.verify, &conn, &reply) catch |err| {
                log.debug("[raft] no reply from {s}:{d} within {d}ms, or the peer closed ({}) — message dropped", .{ ep.host, ep.port, self.rpcTimeoutMs(), err });
                return lost;
            };
            return decodeAppendEntriesResponse(bytes) catch lost;
        }

        fn thunkVoteRequest(peer_id: ?[]const u8, address: []const u8, req: VoteRequest) void {
            const self = bound orelse {
                log.debug("[raft] unbound transport, vote request dropped", .{});
                return;
            };
            self.sendVoteRequest(peer_id, address, req);
        }

        fn thunkAppendEntries(peer_id: ?[]const u8, address: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
            const self = bound orelse return .{ .term = 0, .success = false, .match_index = 0 };
            return self.sendAppendEntries(peer_id, address, req);
        }

        /// Synchronous, the §7 mirror of `sendAppendEntries`: the follower
        /// answers on the same connection, and every failure mode (no address,
        /// dial, write, read, decode) is the same "lost message" answer —
        /// `term = 0` is below any live term, so the leader treats it as a
        /// dropped frame and retries next round. Never a panic.
        pub fn sendInstallSnapshot(self: *Self, peer_id: ?[]const u8, address: []const u8, req: InstallSnapshotRequest) InstallSnapshotResponse {
            const lost = InstallSnapshotResponse{ .term = 0 };
            const ep = self.resolve(peer_id, address) orelse return lost;
            const keys = self.outboundKeys(peer_id) orelse {
                log.debug("[raft] no key for peer {s}, InstallSnapshot dropped", .{peer_id orelse "?"});
                return lost;
            };

            var frame = std.ArrayList(u8).empty;
            defer frame.deinit(self.allocator);
            encodeInstallSnapshot(&frame, self.allocator, req) catch |err| {
                log.debug("[raft] encoding InstallSnapshot failed ({})", .{err});
                return lost;
            };

            var conn = dialTo(self.allocator, self.io, ep, self.rpcTimeoutMs()) catch return lost;
            defer conn.deinit();
            sockread.setSendTimeout(conn.stream, self.rpcTimeoutMs());
            writeFrameSigned(keys.sign, &conn, frame.items) catch return lost;

            // Same bounded reply wait as `sendAppendEntries` — a snapshot can be
            // the largest frame a peer ever gets, so a WAN should raise
            // `rpc_timeout_ms` for both ends rather than rely on the default.
            sockread.setRecvTimeout(conn.stream, self.rpcTimeoutMs());

            var reply = std.ArrayList(u8).empty;
            defer reply.deinit(self.allocator);
            const bytes = readFrameAuth(keys.verify, &conn, &reply) catch |err| {
                log.debug("[raft] no snapshot reply from {s}:{d} within {d}ms, or the peer closed ({}) — message dropped", .{ ep.host, ep.port, self.rpcTimeoutMs(), err });
                return lost;
            };
            return decodeInstallSnapshotResponse(bytes) catch lost;
        }

        fn thunkInstallSnapshot(peer_id: ?[]const u8, address: []const u8, req: InstallSnapshotRequest) InstallSnapshotResponse {
            const self = bound orelse return .{ .term = 0 };
            return self.sendInstallSnapshot(peer_id, address, req);
        }
    };
}

/// Single-node-per-process form: what an app filling in `BootstrapConfig.transport`
/// uses.
pub const ElectionTransportImpl = TransportImpl(0);

// ── Inbound ─────────────────────────────────────────────────────────────────

/// Serve one Raft RPC on `conn`: read a frame, dispatch it into `raft`, write the
/// reply back on the same connection. The connection lifetime belongs to the
/// caller (see `InboundServer.run`).
///
/// `addresses` is optional and used only to push a vote response back to the
/// candidate (whose own socket is closed by then).
///
/// **Nothing here takes the raft's `lock`, and that is deliberate.** The
/// raft-state window
/// of a frame is `decode → dispatch → encode`, and it is serialized by
/// `RaftElection`'s own `lock` ([`RaftElection.RaftLock`]) — every `handle*` the
/// dispatch calls takes it for its whole body, which is what keeps this file's
/// (and `ClusterBootstrap`'s) accept thread from interleaving with the app
/// thread's `tick()` over `voted_for` / `log` / `next_index`. Taking a lock
/// *here* as well would deadlock against those self-locked bodies; having the
/// **caller** take it (what the first version of this fix did) instead makes the
/// guarantee depend on every path into a `RaftElection` remembering to
/// serialize — an `InboundServer` started directly, or an app driving `tick()`
/// itself, is exactly the case that was left open.
///
/// The exception is `key_lock` (A-3): the frame's verification key is resolved
/// *before* the dispatch above, so it is outside the raft-state window, and the
/// A-3 rotation/revocation API mutates that table at runtime. `key_lock` is a
/// leaf taken for the lookup only — value copies out, HMAC after release — and
/// never held across IO, so it cannot reintroduce the deadlock this comment is
/// about.
///
/// The two ends of the function stay outside any lock: a `recv`, the reply, and
/// the relay dial are IO, and a `tick()` that waits on a peer's connect timeout
/// would be a livelock, not a fix. The steps the lock used to wrap but no longer
/// needs to — `decode*` / `encode*` — touch only allocator-local buffers and
/// `raft.local_id`, which is written once in `init` and freed in `deinit`.
///
/// **This paragraph states a principle the outbound half does not yet follow:**
/// `RaftElection.tick`'s replication round calls `sendAppendEntries` below
/// *inside* `RaftLock`. Both ends of that RPC are bounded now — the dial
/// (`dialTo` → `connectTimeout`) and the reply wait (`sockread.setRecvTimeout`,
/// `ElectionConfig.rpc_timeout_ms`) — but a *bounded* IO under a spin lock is
/// still IO under a spin lock, and `rpc_timeout_ms` is a budget a busy node can
/// still spend in full with the lock held.
/// `docs/DISTRIBUTED.md` §"出站 IO 与锁" holds the three-phase design that closes
/// it, with the obligations (self-contained requests, stale-response guard) any
/// implementation has to meet.
pub fn handleConnection(raft: *RaftElection, addresses: ?*const AddressBook, conn: *NetworkTransport.ClusterConnection) void {
    // **Bound the inbound read** — the mirror of what the outbound side already
    // does (`TransportImpl.sendAppendEntries`). The accept loop serves one
    // connection at a time *inline* on its own thread (`NetworkTransport`), so a
    // peer that connects and then sends a length prefix without a body used to
    // stop the whole node's Raft inbound with four bytes — no votes, no
    // heartbeats, no replication — and `ClusterBootstrap.stop()` would then hang
    // on `thread.join()`, because its wake-up connection only reaches the
    // backlog while the loop sits in `readFull`.
    //
    // `rpc_timeout_ms` is the same bound the outbound side uses, and it now
    // covers both directions of one RPC: a WAN that finds it too tight for a
    // large frame should raise it for both ends at once.
    _ = sockread.setRecvTimeout(conn.stream, raft.config.rpc_timeout_ms);
    _ = sockread.setSendTimeout(conn.stream, raft.config.rpc_timeout_ms);

    // The key travels by value: it is all the MAC needs, and building a
    // `ClusterAuth` per frame would allocate (and could fail) on every vote and
    // heartbeat — dropping a vote because a 6-byte `dupe` failed is not a failure
    // mode this path should have. Per-node mode picks the key off the frame's
    // claimed sender id (A-1, see the section at the top of this file).
    //
    // The reads run under the raft's `key_lock` (A-3): this thread holds no
    // raft lock, and `rotateOwnKey` / `rotatePeerKey` / `revokePeerKey` may be
    // rebuilding the key table on an operator thread right now. The critical
    // sections below only resolve the mode and copy key bytes out; the HMAC
    // itself runs after the release.
    const config = &raft.config;
    raft.key_lock.acquire();
    const mode = authMode(config);
    const sign = signAuth(config);
    raft.key_lock.release();
    switch (sign) {
        // Per-node mode without an `own_key` cannot even answer: the reply
        // would have to go out bare, which the caller refuses to read. Refuse
        // the connection instead of drifting off the authenticated wire.
        .drop => {
            log.debug("[raft] inbound connection dropped: per-node credentials configured but this node has no own_key", .{});
            return;
        },
        else => {},
    }

    var in = std.ArrayList(u8).empty;
    defer in.deinit(conn.allocator);
    // With a secret configured the frame is verified (and the MAC stripped)
    // *before* any decoder sees it; a bad tag is the same shape of failure as an
    // unreadable frame — drop the connection and keep serving.
    const frame = blk: {
        switch (mode) {
            .bare => break :blk conn.recv(&in) catch |err| {
                log.debug("[raft] inbound frame not readable ({})", .{err});
                return;
            },
            .shared => break :blk verifiedRecv(config.cluster_secret.?, conn, &in) catch |err| {
                log.debug("[raft] inbound frame not authenticated ({})", .{err});
                return;
            },
            .per_node => {
                // Raw read first: the claimed sender id selects the key and can
                // only be read off the unverified bytes — it sits inside the
                // MAC's coverage, so a forged id fails the verification below.
                const raw = conn.recv(&in) catch |err| {
                    log.debug("[raft] inbound frame not readable ({})", .{err});
                    return;
                };
                const claimed = claimedSenderId(raw) orelse {
                    log.debug("[raft] inbound frame carries no sender id, dropped", .{});
                    return;
                };
                raft.key_lock.acquire();
                const keys = nodeKeys(config, raft.local_id, claimed);
                raft.key_lock.release();
                const ks = keys orelse {
                    log.debug("[raft] inbound frame from unkeyed node {s}, dropped", .{claimed});
                    return;
                };
                // A-3: current first, then the previous key while the peer's
                // rotation window is open — signing never uses `previous`.
                break :blk verifyFrameMacWindowed(ks, raw) catch |err| {
                    log.debug("[raft] inbound frame not authenticated as {s} ({})", .{ claimed, err });
                    return;
                };
            },
        }
    };

    var arena_state = std.heap.ArenaAllocator.init(conn.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // The reply is built with the arena too: it is written (same connection and
    // relay) before the arena goes away, so nothing needs an individual free.
    var out = std.ArrayList(u8).empty;

    // Only a granted vote needs the extra hop to the candidate.
    var relay_candidate: ?[]const u8 = null;

    // The raft-state window: decode → dispatch → encode. The dispatch is
    // serialized by the raft itself (every `handle*` holds
    // `RaftElection.lock`); decode and encode build only arena buffers and read
    // the immutable `local_id`. Everything after this block (`writeFrame`, the
    // relay dial) is IO and stays outside any lock.
    switch (tagOf(frame) orelse {
        log.debug("[raft] dropping a {d}-byte frame with an unknown tag", .{frame.len});
        return;
    }) {
        .vote_request => {
            const req = decodeVoteRequest(allocator, frame) catch |err| return logDrop(err);
            const resp = raft.handleVoteRequest(req) catch |err| return logDrop(err);
            encodeVoteResponse(&out, allocator, resp, raft.local_id) catch |err| return logDrop(err);
            if (resp.vote_granted) relay_candidate = req.candidate_id;
        },
        .append_entries => {
            const req = decodeAppendEntries(allocator, frame) catch |err| return logDrop(err);
            const resp = raft.handleAppendEntries(req) catch |err| return logDrop(err);
            encodeAppendEntriesResponse(&out, allocator, resp) catch |err| return logDrop(err);
        },
        .install_snapshot => {
            const req = decodeInstallSnapshot(allocator, frame) catch |err| return logDrop(err);
            const resp = raft.handleInstallSnapshot(req) catch |err| return logDrop(err);
            encodeInstallSnapshotResponse(&out, allocator, resp) catch |err| return logDrop(err);
        },
        .vote_response => {
            const decoded = decodeVoteResponse(allocator, frame) catch |err| return logDrop(err);
            raft.handleVoteResponse(decoded.resp, decoded.responder_id) catch |err| return logDrop(err);
            return; // no reply: the candidate asked, this is the answer
        },
        // Nothing consumes these **inbound**: the leader reads its AppendEntries
        // / InstallSnapshot reply synchronously on the connection it opened
        // (`TransportImpl.sendAppendEntries` / `sendInstallSnapshot`), so a
        // response frame arriving here would be a stray — drop it, keep serving.
        .append_entries_response, .install_snapshot_response => return,
    }

    writeFrameSigned(sign, conn, out.items) catch |err| {
        log.debug("[raft] replying on the inbound connection failed ({})", .{err});
    };

    if (relay_candidate) |candidate| {
        const ep = if (addresses) |book| book.lookup(candidate) else null;
        if (ep) |endpoint| {
            raft.key_lock.acquire();
            const candidate_unkeyed = mode == .per_node and nodeKey(config, raft.local_id, candidate) == null;
            raft.key_lock.release();
            if (candidate_unkeyed) {
                log.debug("[raft] candidate {s} has no configured key, vote response not relayed", .{candidate});
                return;
            }
            var conn_out = dialTo(conn.allocator, conn.io, endpoint, raft.config.rpc_timeout_ms) catch |err| {
                log.debug("[raft] relaying the vote response to {s}:{d} failed ({})", .{ endpoint.host, endpoint.port, err });
                return;
            };
            defer conn_out.deinit();
            // The candidate verifies its inbound frames, so the relay has to be
            // signed too — an unsigned relay is a vote the candidate drops.
            writeFrameSigned(sign, &conn_out, out.items) catch |err| {
                log.debug("[raft] relaying the vote response failed ({})", .{err});
            };
        } else {
            log.debug("[raft] candidate {s} is not in the address book, vote response not relayed", .{candidate});
        }
    }
}

fn logDrop(err: anyerror) void {
    log.debug("[raft] inbound RPC dropped ({})", .{err});
}

/// Accept loop for inbound RPCs. `ClusterServer` runs one fiber per connection
/// and passes this server as the handler's context, so several nodes can share a
/// process without any thread-local state. The binding used to be a
/// `threadlocal var current`, which only worked while the handler ran on the
/// accept thread: as soon as the handler was dispatched onto a pool thread,
/// `current` was null there and **every inbound connection was dropped**.
pub const InboundServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    raft: *RaftElection,
    addresses: ?*const AddressBook,
    server: NetworkTransport.ClusterServer,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, raft: *RaftElection, addresses: ?*const AddressBook, port: u16) InboundServer {
        return .{
            .allocator = allocator,
            .io = io,
            .raft = raft,
            .addresses = addresses,
            .server = NetworkTransport.ClusterServer.init(allocator, io, port),
        };
    }

    /// Blocks until `stop()`. One RPC per connection, matching the outbound side,
    /// which opens a fresh connection per call.
    pub fn run(self: *InboundServer) void {
        self.server.start(&onConnection, self) catch |err| {
            log.debug("[raft] inbound server on port {d} exited ({})", .{ self.server.port, err });
        };
    }

    /// Ask `run` to return. The accept is already blocked, so a wake-up
    /// connection is needed (see the tests). Waits for the in-flight handlers as
    /// well: they hold `raft` and `addresses`, which the caller frees next.
    pub fn stop(self: *InboundServer) void {
        self.server.stop();
    }

    fn onConnection(context: ?*anyopaque, conn: NetworkTransport.ClusterConnection) void {
        var owned = conn;
        defer owned.deinit();
        const ctx = context orelse {
            log.debug("[raft] inbound connection with no server context", .{});
            return;
        };
        const self: *InboundServer = @ptrCast(@alignCast(ctx));
        handleConnection(self.raft, self.addresses, &owned);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Loopback dials below complete in the kernel's listen backlog even when the
/// peer's accept loop is busy, so this only has to be long enough not to fire
/// spuriously.
const test_dial_timeout_ms: u32 = 2000;

test "TransportImpl keeps distinct statics per slot" {
    // Regression guard for the comptime-generic memoization trap: on this Zig
    // build a `fn(comptime slot: usize) type` whose body never references
    // `slot` collapses into ONE type for every slot (measured: Impl(0) ==
    // Impl(2)), merging the per-slot `bound` static so the last `init` wins
    // and every node dispatches through one node's transport. The `slot_id`
    // decl in the type body keeps instantiations distinct (same fix as
    // src/soak_cluster.zig's SoakTransport).
    try testing.expect(TransportImpl(0) != TransportImpl(2));
}

test "wire format round-trips every Raft RPC" {
    const allocator = testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const vote_req = VoteRequest{ .term = 7, .candidate_id = "node-a", .last_log_index = 3, .last_log_term = 2 };
    try encodeVoteRequest(&out, allocator, vote_req);
    try testing.expectEqual(MessageTag.vote_request, tagOf(out.items).?);
    const decoded_req = try decodeVoteRequest(allocator, out.items);
    defer allocator.free(decoded_req.candidate_id);
    try testing.expectEqual(vote_req.term, decoded_req.term);
    try testing.expectEqualStrings(vote_req.candidate_id, decoded_req.candidate_id);
    try testing.expectEqual(vote_req.last_log_index, decoded_req.last_log_index);
    try testing.expectEqual(vote_req.last_log_term, decoded_req.last_log_term);

    out.clearRetainingCapacity();
    try encodeVoteResponse(&out, allocator, .{ .term = 7, .vote_granted = true }, "node-b");
    const decoded_resp = try decodeVoteResponse(allocator, out.items);
    defer allocator.free(decoded_resp.responder_id);
    try testing.expect(decoded_resp.resp.vote_granted);
    try testing.expectEqual(@as(u64, 7), decoded_resp.resp.term);
    try testing.expectEqualStrings("node-b", decoded_resp.responder_id);

    out.clearRetainingCapacity();
    const entries = [_]LogEntry{.{ .term = 2, .index = 1, .command = "set x" }};
    try encodeAppendEntries(&out, allocator, .{
        .term = 7,
        .leader_id = "node-a",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &entries,
        .leader_commit = 1,
    });
    const decoded_append = try decodeAppendEntries(allocator, out.items);
    defer {
        allocator.free(decoded_append.leader_id);
        for (decoded_append.entries) |entry| allocator.free(entry.command);
        allocator.free(decoded_append.entries);
    }
    try testing.expectEqual(@as(usize, 1), decoded_append.entries.len);
    try testing.expectEqualStrings("set x", decoded_append.entries[0].command);
    try testing.expectEqual(@as(u64, 1), decoded_append.leader_commit);

    out.clearRetainingCapacity();
    try encodeAppendEntriesResponse(&out, allocator, .{ .term = 8, .success = false, .match_index = 4 });
    const decoded_ack = try decodeAppendEntriesResponse(out.items);
    try testing.expectEqual(@as(u64, 8), decoded_ack.term);
    try testing.expect(!decoded_ack.success);
    try testing.expectEqual(@as(u64, 4), decoded_ack.match_index);

    out.clearRetainingCapacity();
    try encodeInstallSnapshot(&out, allocator, .{
        .term = 9,
        .leader_id = "node-a",
        .last_included_index = 12,
        .last_included_term = 8,
        .offset = 0,
        .data = "snapshot-bytes",
        .done = true,
    });
    const decoded_snap = try decodeInstallSnapshot(allocator, out.items);
    defer {
        allocator.free(decoded_snap.leader_id);
        allocator.free(decoded_snap.data);
    }
    try testing.expectEqual(@as(u64, 12), decoded_snap.last_included_index);
    try testing.expectEqualStrings("snapshot-bytes", decoded_snap.data);
    try testing.expect(decoded_snap.done);

    out.clearRetainingCapacity();
    try encodeInstallSnapshotResponse(&out, allocator, .{ .term = 9 });
    try testing.expectEqual(@as(u64, 9), (try decodeInstallSnapshotResponse(out.items)).term);

    // A frame of the wrong kind is refused instead of misread.
    out.clearRetainingCapacity();
    try encodeVoteResponse(&out, allocator, .{ .term = 1, .vote_granted = false }, "node-b");
    try testing.expectError(error.UnexpectedMessageTag, decodeVoteRequest(allocator, out.items));
    try testing.expectEqual(@as(?MessageTag, null), tagOf(&.{0x7f}));
}

// The entry count is a u16 on the wire, so without a cap `decodeAppendEntries`
// would `alloc(LogEntry, 65535)` ≈ 2 MB on the say-so of a peer, before a single
// entry byte was validated. The frame below is that shape: it declares 65535
// entries and carries **none**, so a decoder that allocates (or walks the body)
// first reports `TruncatedMessage` or `error.OutOfMemory` — the assertion here
// is that the count is refused on its own, and that nothing was requested from
// the allocator on the way to that refusal.
test "an append_entries frame above the decode cap is dropped without allocating" {
    const allocator = testing.allocator;

    const claimed_entries: u16 = 65535;
    try testing.expect(claimed_entries > MAX_ENTRIES_PER_FRAME);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try putU8(&out, allocator, @backingInt(MessageTag.append_entries));
    try putU64(&out, allocator, 7); // term
    try putStr(&out, allocator, "leader1"); // leader_id
    try putU64(&out, allocator, 0); // prev_log_index
    try putU64(&out, allocator, 0); // prev_log_term
    try putU64(&out, allocator, 0); // leader_commit
    try putU16(&out, allocator, claimed_entries);
    // ...and no entries at all.

    // `fail_index = 1`: the `leader_id` copy is allocation #0 and would succeed,
    // so an implementation that allocates the entries array reaches a *failing*
    // allocation (a different error) rather than reporting this one. The arena
    // is what keeps the copied `leader_id` from leaking on the error path — the
    // decoder itself relies on its caller's arena for that.
    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var arena_state = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena_state.deinit();
    try testing.expectError(error.EntryCountTooLarge, decodeAppendEntries(arena_state.allocator(), out.items));

    // Nothing the size of the declared array was ever requested.
    try testing.expect(failing.allocated_bytes < @as(usize, claimed_entries) * @sizeOf(LogEntry));
    try testing.expect(failing.allocated_bytes < 256);

    // The cap is a *ceiling*, not the normal path: a frame at it still decodes.
    out.clearRetainingCapacity();
    const at_cap = try allocator.alloc(LogEntry, MAX_ENTRIES_PER_FRAME);
    defer allocator.free(at_cap);
    for (at_cap, 0..) |*entry, i| entry.* = .{ .term = 1, .index = @intCast(i + 1), .command = "x" };
    try encodeAppendEntries(&out, allocator, .{
        .term = 7,
        .leader_id = "leader1",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = at_cap,
        .leader_commit = 0,
    });
    const decoded = try decodeAppendEntries(allocator, out.items);
    defer {
        for (decoded.entries) |entry| allocator.free(entry.command);
        allocator.free(decoded.entries);
        allocator.free(decoded.leader_id);
    }
    try testing.expectEqual(@as(usize, MAX_ENTRIES_PER_FRAME), decoded.entries.len);
    try testing.expectEqual(@as(u64, MAX_ENTRIES_PER_FRAME), decoded.entries[MAX_ENTRIES_PER_FRAME - 1].index);
}

// ── Fuzz: decoders only error or succeed ────────────────────────────────────
//
// `decode*` is the parse surface an unauthenticated peer reaches first
// (verification is HMAC, but a bare-mode cluster and any post-MAC byte are both
// attacker-controlled here), so it has to survive arbitrary bytes: every outcome
// is a value or a `DecodeError`, never a panic/UB. Runs under `zig build --fuzz`
// against generated inputs; a plain `zig build test` replays the corpus seeds.

/// One seed per RPC kind, built with the real encoders so the corpus starts on
/// the success path instead of hoping mutation finds it.
fn fuzzSeedFrames(allocator: std.mem.Allocator) ![][]const u8 {
    var seeds = std.ArrayList([]const u8).empty;
    errdefer {
        for (seeds.items) |s| allocator.free(s);
        seeds.deinit(allocator);
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    out.clearRetainingCapacity();
    try encodeVoteRequest(&out, allocator, .{ .term = 7, .candidate_id = "node-a", .last_log_index = 3, .last_log_term = 2 });
    try seeds.append(allocator, try out.toOwnedSlice(allocator));

    out.clearRetainingCapacity();
    try encodeVoteResponse(&out, allocator, .{ .term = 7, .vote_granted = true }, "node-b");
    try seeds.append(allocator, try out.toOwnedSlice(allocator));

    out.clearRetainingCapacity();
    const entries = [_]LogEntry{.{ .term = 2, .index = 1, .command = "set x" }};
    try encodeAppendEntries(&out, allocator, .{ .term = 7, .leader_id = "node-a", .prev_log_index = 0, .prev_log_term = 0, .entries = &entries, .leader_commit = 1 });
    try seeds.append(allocator, try out.toOwnedSlice(allocator));

    out.clearRetainingCapacity();
    // The hostile shape from the test above: a count of 65535 and no entries.
    try putU8(&out, allocator, @backingInt(MessageTag.append_entries));
    try putU64(&out, allocator, 7);
    try putStr(&out, allocator, "leader1");
    try putU64(&out, allocator, 0);
    try putU64(&out, allocator, 0);
    try putU64(&out, allocator, 0);
    try putU16(&out, allocator, 65535);
    try seeds.append(allocator, try out.toOwnedSlice(allocator));

    out.clearRetainingCapacity();
    try encodeAppendEntriesResponse(&out, allocator, .{ .term = 8, .success = false, .match_index = 4 });
    try seeds.append(allocator, try out.toOwnedSlice(allocator));

    out.clearRetainingCapacity();
    try encodeInstallSnapshot(&out, allocator, .{ .term = 9, .leader_id = "node-a", .last_included_index = 12, .last_included_term = 8, .offset = 0, .data = "snapshot-bytes", .done = true });
    try seeds.append(allocator, try out.toOwnedSlice(allocator));

    out.clearRetainingCapacity();
    try encodeInstallSnapshotResponse(&out, allocator, .{ .term = 9 });
    try seeds.append(allocator, try out.toOwnedSlice(allocator));

    return seeds.toOwnedSlice(allocator);
}

fn fuzzDecodeFrame(_: void, smith: *std.testing.Smith) !void {
    var frame: [4096]u8 = undefined;
    smith.bytes(&frame);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Retry each tag on the same bytes: arbitrary first bytes rarely land on a
    // valid one, and a fuzz run that only ever reaches `payloadOf`'s rejection
    // would leave the decode bodies uncovered.
    for (@backingInt(MessageTag.vote_request)..@backingInt(MessageTag.install_snapshot_response) + 1) |t| {
        frame[0] = @intCast(t);
        // Any outcome — value or `DecodeError` — is a pass; crashing is not.
        _ = decodeVoteRequest(a, &frame) catch continue;
        _ = decodeVoteResponse(a, &frame) catch continue;
        _ = decodeAppendEntries(a, &frame) catch continue;
        _ = decodeAppendEntriesResponse(&frame) catch continue;
        _ = decodeInstallSnapshot(a, &frame) catch continue;
        _ = decodeInstallSnapshotResponse(&frame) catch continue;
    }
}

test "fuzz: frame decoders only error or succeed on arbitrary bytes" {
    const allocator = testing.allocator;
    const seeds = try fuzzSeedFrames(allocator);
    defer {
        for (seeds) |s| allocator.free(s);
        allocator.free(seeds);
    }
    try std.testing.fuzz({}, fuzzDecodeFrame, .{ .corpus = seeds });
}

// ── Frame authentication tests ──────────────────────────────────────────────

/// A connected pair of `ClusterConnection`s over `socketpair(2)`. The frame
/// helpers are one write and one read around a pure byte transform, so this is
/// the smallest fixture that exercises both halves for real — no ports, no
/// threads, no accept loop. Returns false where `AF.UNIX` socketpairs are
/// unavailable.
fn socketPair(allocator: std.mem.Allocator, io: std.Io, out: *[2]NetworkTransport.ClusterConnection) bool {
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return false,
    }
    out[0] = NetworkTransport.ClusterConnection.init(allocator, .{ .socket = .{ .handle = fds[0], .address = undefined } }, io);
    out[1] = NetworkTransport.ClusterConnection.init(allocator, .{ .socket = .{ .handle = fds[1], .address = undefined } }, io);
    return true;
}

/// Write `wire ++ mac`, where `mac` is the tag of `signed_frame` — the wire shape
/// of a peer that signs one frame and sends another. The length prefix comes from
/// `writeFrame`, so only the payload differs from what `sendSigned` would write.
fn writeSignedAs(
    allocator: std.mem.Allocator,
    key: [32]u8,
    conn: *NetworkTransport.ClusterConnection,
    signed_frame: []const u8,
    wire: []const u8,
) !void {
    var mac: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed_frame, &key);
    var signed = std.ArrayList(u8).empty;
    defer signed.deinit(allocator);
    try signed.appendSlice(allocator, wire);
    try signed.appendSlice(allocator, &mac);
    try writeFrame(conn.stream, signed.items);
}

test "ClusterAuth.mac is the raw tag sign hex-encodes" {
    const allocator = testing.allocator;
    var auth = try ClusterAuth.init(allocator, "node-a", @splat(9));
    defer auth.deinit();

    const raw = auth.mac("hello");
    const hex = try auth.sign("hello");
    var hex_of_raw: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (raw, 0..) |byte, i| {
        hex_of_raw[i * 2] = hex_chars[byte >> 4];
        hex_of_raw[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    // Same tag, two encodings — the frame wants the 32 raw bytes.
    try testing.expectEqualSlices(u8, &hex, &hex_of_raw);
}

test "a signed frame round-trips: sendSigned then verifiedRecv strips the MAC" {
    const allocator = testing.allocator;
    const io = testing.io;
    var pair: [2]NetworkTransport.ClusterConnection = undefined;
    if (!socketPair(allocator, io, &pair)) return error.SkipZigTest;
    defer {
        pair[0].deinit();
        pair[1].deinit();
    }

    const key: [32]u8 = @splat(0x5a);
    var sender = try ClusterAuth.init(allocator, "node-a", key);
    defer sender.deinit();
    var receiver = try ClusterAuth.init(allocator, "node-b", key);
    defer receiver.deinit();

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    try encodeVoteRequest(&frame, allocator, .{ .term = 5, .candidate_id = "node-a", .last_log_index = 3, .last_log_term = 2 });

    try sendSigned(sender.pre_shared_key, &pair[0], frame.items);

    var in = std.ArrayList(u8).empty;
    defer in.deinit(allocator);
    const got = try verifiedRecv(receiver.pre_shared_key, &pair[1], &in);

    // The MAC is gone: what the receiver hands the decoders is byte-for-byte the
    // frame the sender built, so `tagOf` / `payloadOf` / `decode*` are untouched.
    try testing.expectEqualSlices(u8, frame.items, got);
    const req = try decodeVoteRequest(allocator, got);
    defer allocator.free(req.candidate_id);
    try testing.expectEqual(@as(u64, 5), req.term);
    try testing.expectEqualStrings("node-a", req.candidate_id);
    try testing.expectEqual(@as(u64, 3), req.last_log_index);
    try testing.expectEqual(@as(u64, 2), req.last_log_term);
}

test "a frame signed with another key is refused" {
    const allocator = testing.allocator;
    const io = testing.io;
    var pair: [2]NetworkTransport.ClusterConnection = undefined;
    if (!socketPair(allocator, io, &pair)) return error.SkipZigTest;
    defer {
        pair[0].deinit();
        pair[1].deinit();
    }

    var sender = try ClusterAuth.init(allocator, "node-a", @splat(0x5a));
    defer sender.deinit();
    var receiver = try ClusterAuth.init(allocator, "node-b", @splat(0x5b));
    defer receiver.deinit();

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    try encodeVoteRequest(&frame, allocator, .{ .term = 5, .candidate_id = "node-a", .last_log_index = 3, .last_log_term = 2 });
    try sendSigned(sender.pre_shared_key, &pair[0], frame.items);

    var in = std.ArrayList(u8).empty;
    defer in.deinit(allocator);
    try testing.expectError(error.ClusterAuthFailed, verifiedRecv(receiver.pre_shared_key, &pair[1], &in));
}

test "a frame whose payload changed after signing is refused" {
    const allocator = testing.allocator;
    const io = testing.io;
    var pair: [2]NetworkTransport.ClusterConnection = undefined;
    if (!socketPair(allocator, io, &pair)) return error.SkipZigTest;
    defer {
        pair[0].deinit();
        pair[1].deinit();
    }

    var sender = try ClusterAuth.init(allocator, "node-a", @splat(0x5a));
    defer sender.deinit();
    var receiver = try ClusterAuth.init(allocator, "node-b", @splat(0x5a));
    defer receiver.deinit();

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    try encodeVoteRequest(&frame, allocator, .{ .term = 5, .candidate_id = "node-a", .last_log_index = 3, .last_log_term = 2 });

    // Signed as built, sent with one payload byte flipped (index 0 is the tag, so
    // index 1 is the first byte of `term`). The trailer stays a valid-looking tag
    // for the *original* bytes.
    const tampered = try allocator.dupe(u8, frame.items);
    defer allocator.free(tampered);
    tampered[1] ^= 0xff;
    try writeSignedAs(allocator, sender.pre_shared_key, &pair[0], frame.items, tampered);

    var in = std.ArrayList(u8).empty;
    defer in.deinit(allocator);
    try testing.expectError(error.ClusterAuthFailed, verifiedRecv(receiver.pre_shared_key, &pair[1], &in));
}

test "a frame whose tag changed after signing is refused" {
    const allocator = testing.allocator;
    const io = testing.io;
    var pair: [2]NetworkTransport.ClusterConnection = undefined;
    if (!socketPair(allocator, io, &pair)) return error.SkipZigTest;
    defer {
        pair[0].deinit();
        pair[1].deinit();
    }

    var sender = try ClusterAuth.init(allocator, "node-a", @splat(0x5a));
    defer sender.deinit();
    var receiver = try ClusterAuth.init(allocator, "node-b", @splat(0x5a));
    defer receiver.deinit();

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    try encodeVoteRequest(&frame, allocator, .{ .term = 5, .candidate_id = "node-a", .last_log_index = 3, .last_log_term = 2 });

    // Same payload, a *different* tag: if the MAC covered only the payload this
    // frame would pass (and be dispatched as an AppendEntries).
    const retagged = try allocator.dupe(u8, frame.items);
    defer allocator.free(retagged);
    retagged[0] = @backingInt(MessageTag.append_entries);
    try writeSignedAs(allocator, sender.pre_shared_key, &pair[0], frame.items, retagged);

    var in = std.ArrayList(u8).empty;
    defer in.deinit(allocator);
    try testing.expectError(error.ClusterAuthFailed, verifiedRecv(receiver.pre_shared_key, &pair[1], &in));
}

test "a bare frame with no MAC is refused once a secret is configured" {
    const allocator = testing.allocator;
    const io = testing.io;
    var pair: [2]NetworkTransport.ClusterConnection = undefined;
    if (!socketPair(allocator, io, &pair)) return error.SkipZigTest;
    defer {
        pair[0].deinit();
        pair[1].deinit();
    }

    var receiver = try ClusterAuth.init(allocator, "node-b", @splat(0x5a));
    defer receiver.deinit();

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    // Deliberately longer than `auth_mac_bytes`: the rejection below has to be the
    // MAC comparison, not the "too short to carry a MAC" length check (which the
    // second half covers).
    try encodeVoteRequest(&frame, allocator, .{ .term = 5, .candidate_id = "node-b-candidate", .last_log_index = 3, .last_log_term = 2 });
    try testing.expect(frame.items.len > auth_mac_bytes + 1);

    // The pre-feature shape, and what a peer with no secret sends: an ordinary
    // `writeFrame`'d frame with nothing appended.
    try writeFrame(pair[0].stream, frame.items);

    var in = std.ArrayList(u8).empty;
    defer in.deinit(allocator);
    try testing.expectError(error.ClusterAuthFailed, verifiedRecv(receiver.pre_shared_key, &pair[1], &in));

    // And a frame with no room for a MAC at all is refused without reading past it.
    try writeFrame(pair[0].stream, &.{ @backingInt(MessageTag.vote_request), 0, 0, 0, 0, 0 });
    try testing.expectError(error.ClusterAuthFailed, verifiedRecv(receiver.pre_shared_key, &pair[1], &in));
}

test "address book parses host:port and resolves by peer id" {
    var book = AddressBook.init(testing.allocator);
    defer book.deinit();

    try book.addEndpoint("node-b", "127.0.0.1:9001");
    try book.add("node-c", "10.0.0.7", 9002);

    try testing.expectEqualStrings("127.0.0.1", book.lookup("node-b").?.host);
    try testing.expectEqual(@as(u16, 9001), book.lookup("node-b").?.port);
    try testing.expectEqual(@as(u16, 9002), book.lookup("node-c").?.port);
    try testing.expectEqual(@as(?Endpoint, null), book.lookup("node-z"));

    // Re-adding an id replaces the endpoint (and must not free the source).
    try book.addEndpoint("node-b", "192.168.1.5:9101");
    try testing.expectEqualStrings("192.168.1.5", book.lookup("node-b").?.host);
    try testing.expectEqual(@as(u16, 9101), book.lookup("node-b").?.port);

    try testing.expect(parseEndpoint("10.0.0.1:1") != null);
    try testing.expectEqual(@as(?Endpoint, null), parseEndpoint("10.0.0.1"));
    try testing.expectEqual(@as(?Endpoint, null), parseEndpoint("10.0.0.1:0"));
    try testing.expectEqual(@as(?Endpoint, null), parseEndpoint(":9001"));
}

/// Start an `InboundServer` for `raft` on the first free port at or after
/// `first_port`.
fn startInbound(
    allocator: std.mem.Allocator,
    io: std.Io,
    raft: *RaftElection,
    addresses: ?*const AddressBook,
    first_port: u16,
    out: *InboundServer,
    thread: *std.Thread,
) !u16 {
    var port = first_port;
    while (port < first_port + 40) : (port += 1) {
        out.* = InboundServer.init(allocator, io, raft, addresses, port);
        thread.* = try std.Thread.spawn(.{}, InboundServer.run, .{out});
        // `ClusterServer.start` flips `running` right after a successful listen.
        var spins: usize = 0;
        while (!out.server.running.load(.monotonic) and spins < 2000) : (spins += 1) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch |err| {
                std.log.debug("[raft] poll sleep interrupted ({s})", .{@errorName(err)});
            };
        }
        if (out.server.running.load(.monotonic)) return port;
        thread.join(); // port taken: `run` already returned
    }
    return error.NoFreePort;
}

fn stopInbound(io: std.Io, inbound: *InboundServer, thread: *std.Thread) void {
    inbound.stop();
    // Wake the blocked accept with a connection that closes without a frame.
    if (dialTo(testing.allocator, io, .{ .host = "127.0.0.1", .port = inbound.server.port }, test_dial_timeout_ms)) |conn| {
        var c = conn;
        c.deinit();
    } else |_| {}
    thread.join();
}

/// Poll `getTerm()` (a single u64, safe to observe) until it changes, then let
/// `voted_for` — written right after — settle before reading it.
fn waitForTerm(io: std.Io, raft: *RaftElection, expected: u64, spins_max: usize) bool {
    var spins: usize = 0;
    while (raft.getTerm() != expected and spins < spins_max) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch |err| {
            std.log.debug("[raft] poll sleep interrupted ({s})", .{@errorName(err)});
        };
    }
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch |err| {
        std.log.debug("[raft] term settle sleep interrupted ({s})", .{@errorName(err)});
    };
    return raft.getTerm() == expected;
}

test "real loopback election: tick sends real vote requests and the candidate wins quorum" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var a_impl: ElectionTransportImpl = undefined;
    var b_impl: TransportImpl(1) = undefined;
    var c_impl: TransportImpl(2) = undefined;
    var a_raft: RaftElection = undefined;
    var b_raft: RaftElection = undefined;
    var c_raft: RaftElection = undefined;
    var a_inbound: InboundServer = undefined;
    var b_inbound: InboundServer = undefined;
    var c_inbound: InboundServer = undefined;
    var a_thread: std.Thread = undefined;
    var b_thread: std.Thread = undefined;
    var c_thread: std.Thread = undefined;

    // Defers are registered before the work so they unwind in lifetime order:
    // servers first, then the rafts, then the transports they point at.
    var impls_up: u8 = 0;
    var rafts_up: u8 = 0;
    var servers_up: u8 = 0;
    defer {
        if (impls_up >= 3) a_impl.deinit();
        if (impls_up >= 2) c_impl.deinit();
        if (impls_up >= 1) b_impl.deinit();
    }
    defer {
        if (rafts_up >= 3) a_raft.deinit();
        if (rafts_up >= 2) c_raft.deinit();
        if (rafts_up >= 1) b_raft.deinit();
    }
    defer {
        if (servers_up >= 3) stopInbound(io, &a_inbound, &a_thread);
        if (servers_up >= 2) stopInbound(io, &c_inbound, &c_thread);
        if (servers_up >= 1) stopInbound(io, &b_inbound, &b_thread);
    }

    b_impl.init(allocator, io, &b_raft);
    impls_up = 1;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19540, &b_inbound, &b_thread);
    servers_up = 1;

    c_impl.init(allocator, io, &c_raft);
    impls_up = 2;
    const c_port = try startInbound(allocator, io, &c_raft, &c_impl.addresses, b_port + 1, &c_inbound, &c_thread);
    servers_up = 2;

    a_impl.init(allocator, io, &a_raft);
    impls_up = 3;
    const a_port = try startInbound(allocator, io, &a_raft, &a_impl.addresses, c_port + 1, &a_inbound, &a_thread);
    servers_up = 3;

    const b_endpoint = try allocator.print("127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);
    const c_endpoint = try allocator.print("127.0.0.1:{d}", .{c_port});
    defer allocator.free(c_endpoint);
    const a_endpoint = try allocator.print("127.0.0.1:{d}", .{a_port});
    defer allocator.free(a_endpoint);

    // node-a dials from its address book (its Peer entries carry no address, the
    // ClusterBootstrap shape); node-b/node-c need node-a to push votes back.
    try a_impl.addresses.addEndpoint("node-b", b_endpoint);
    try a_impl.addresses.addEndpoint("node-c", c_endpoint);
    try b_impl.addresses.addEndpoint("node-a", a_endpoint);
    try c_impl.addresses.addEndpoint("node-a", a_endpoint);

    // Each follower knows the candidate by **id**. A vote request from a node that is
    // not in `peers` is now denied before the ballot is considered, so the fixture
    // (not the assertion) has to name node-a — the same id-versus-address fact the
    // `ClusterBootstrap` id gate enforces at boot
    // (docs/dev/cluster-auth-design.md §4.1, §10).
    var b_peers = [_]Peer{.{ .id = "node-a", .address = "" }};
    var c_peers = [_]Peer{.{ .id = "node-a", .address = "" }};
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{}, &b_impl.transport());
    rafts_up = 1;
    c_raft = try RaftElection.init(allocator, "node-c", &c_peers, .{}, &c_impl.transport());
    rafts_up = 2;
    var peers = [_]Peer{ .{ .id = "node-b", .address = "" }, .{ .id = "node-c", .address = "" } };
    a_raft = try RaftElection.init(allocator, "node-a", &peers, .{}, &a_impl.transport());
    rafts_up = 3;

    try testing.expectEqual(@as(usize, 3), a_raft.clusterSize());
    try testing.expectEqual(@as(usize, 2), a_raft.quorumSize());

    // One tick past the election deadline: `startElection` sends real vote
    // requests to node-b and node-c, both grant, and their responses arrive on
    // node-a's inbound server.
    a_raft.election_deadline_ms = Time.monotonicNowMilliseconds() - 1;
    try a_raft.tick();

    var spins: usize = 0;
    while (!a_raft.isLeader() and spins < 3000) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(a_raft.isLeader());
    try testing.expectEqual(@as(u64, 1), a_raft.getTerm());

    // Two of three nodes voted for node-a over the wire → quorum. `hasQuorum` takes
    // **peer** grants and adds the candidate's own vote, so one peer grant is a
    // majority of three (this assertion said `hasQuorum(2)` while the off-by-one was
    // in place — docs/dev/cluster-auth-design.md §12).
    try testing.expect(waitForTerm(io, &b_raft, 1, 2000));
    try testing.expect(waitForTerm(io, &c_raft, 1, 2000));
    try testing.expectEqualStrings("node-a", b_raft.voted_for.?);
    try testing.expectEqualStrings("node-a", c_raft.voted_for.?);
    try testing.expect(a_raft.hasQuorum(1));
    try testing.expect(!a_raft.hasQuorum(0));
}

test "real loopback replication: sync AppendEntries and same-connection replies" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var a_impl: ElectionTransportImpl = undefined;
    var b_impl: TransportImpl(1) = undefined;
    var a_raft: RaftElection = undefined;
    var b_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;

    var impls_up: u8 = 0;
    var rafts_up: u8 = 0;
    var servers_up: u8 = 0;
    defer {
        if (impls_up >= 2) a_impl.deinit();
        if (impls_up >= 1) b_impl.deinit();
    }
    defer {
        if (rafts_up >= 2) a_raft.deinit();
        if (rafts_up >= 1) b_raft.deinit();
    }
    defer if (servers_up >= 1) stopInbound(io, &b_inbound, &b_thread);

    b_impl.init(allocator, io, &b_raft);
    impls_up = 1;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19590, &b_inbound, &b_thread);
    servers_up = 1;
    const b_endpoint = try allocator.print("127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);

    a_impl.init(allocator, io, &a_raft);
    impls_up = 2;
    try a_impl.addresses.addEndpoint("node-b", b_endpoint);
    try b_impl.addresses.addEndpoint("node-a", "127.0.0.1:1");

    // node-b is driven by two senders here: node-a (the leader in step 1, the voter in
    // step 2) and node-z (the fire-and-forget vote in step 3). Both are configured
    // members now, because an unlisted sender gets neither a ballot nor the log — the
    // fixture names who is on the wire, which is what the assertions about them meant
    // all along (docs/dev/cluster-auth-design.md §4.1).
    var b_peers = [_]Peer{
        .{ .id = "node-a", .address = "" },
        .{ .id = "node-z", .address = "" },
    };
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{}, &b_impl.transport());
    rafts_up = 1;
    var peers = [_]Peer{.{ .id = "node-b", .address = "" }};
    a_raft = try RaftElection.init(allocator, "node-a", &peers, .{}, &a_impl.transport());
    rafts_up = 2;

    // 1. Synchronous AppendEntries: encoded, written, dispatched on node-b, and
    //    the follower's acknowledgement read back from the same connection.
    const entries = [_]LogEntry{.{ .term = 1, .index = 1, .command = "cmd-1" }};
    const ack = a_impl.sendAppendEntries("node-b", "", .{
        .term = 1,
        .leader_id = "node-a",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &entries,
        .leader_commit = 1,
    });
    try testing.expect(ack.success);
    try testing.expectEqual(@as(u64, 1), ack.term);
    try testing.expectEqual(@as(u64, 1), ack.match_index);
    try testing.expectEqual(@as(usize, 1), b_raft.logLen());
    try testing.expectEqualStrings("cmd-1", b_raft.getLogEntry(1).?.command);
    try testing.expectEqualStrings("node-a", b_raft.getLeader().?);
    try testing.expectEqual(@as(u64, 1), b_raft.getCommitIndex());

    // 2. Same-connection reply to a vote request: read the frame the inbound
    //    handler wrote, not a helper's return value.
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteRequest(&frame, allocator, .{ .term = 2, .candidate_id = "node-a", .last_log_index = 1, .last_log_term = 1 });
        try writeFrame(conn.stream, frame.items);
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        const bytes = try conn.recv(&reply);
        const decoded = try decodeVoteResponse(allocator, bytes);
        defer allocator.free(decoded.responder_id);
        try testing.expect(decoded.resp.vote_granted);
        try testing.expectEqual(@as(u64, 2), decoded.resp.term);
        try testing.expectEqualStrings("node-b", decoded.responder_id);
    }
    try testing.expectEqual(@as(u64, 2), b_raft.getTerm());

    // 3. The fire-and-forget path through the real `ElectionTransport` vtable.
    a_impl.transport().*.sendVoteRequest("node-b", "", .{
        .term = 3,
        .candidate_id = "node-z",
        .last_log_index = 9,
        .last_log_term = 9,
    });
    try testing.expect(waitForTerm(io, &b_raft, 3, 2000));
    try testing.expectEqualStrings("node-z", b_raft.voted_for.?);
    try testing.expectEqual(RaftState.follower, b_raft.getState());

    // 4. A peer that cannot be dialled is a lost message, not a panic: the
    //    synchronous call answers "not replicated" and the async one returns.
    const lost = a_impl.sendAppendEntries("node-ghost", "127.0.0.1:1", .{
        .term = 4,
        .leader_id = "node-a",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{},
        .leader_commit = 0,
    });
    try testing.expect(!lost.success);
    try testing.expectEqual(@as(u64, 0), lost.term);
    a_impl.transport().*.sendVoteRequest("node-ghost", "127.0.0.1:1", .{
        .term = 4,
        .candidate_id = "node-a",
        .last_log_index = 0,
        .last_log_term = 0,
    });
    try testing.expectEqual(@as(u64, 3), b_raft.getTerm());
}

test "real loopback catch-up: empty-log follower converges via per-peer nextIndex" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var a_impl: ElectionTransportImpl = undefined;
    var b_impl: TransportImpl(1) = undefined;
    var a_raft: RaftElection = undefined;
    var b_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;

    var impls_up: u8 = 0;
    var rafts_up: u8 = 0;
    var servers_up: u8 = 0;
    defer {
        if (impls_up >= 2) a_impl.deinit();
        if (impls_up >= 1) b_impl.deinit();
    }
    defer {
        if (rafts_up >= 2) a_raft.deinit();
        if (rafts_up >= 1) b_raft.deinit();
    }
    defer if (servers_up >= 1) stopInbound(io, &b_inbound, &b_thread);

    b_impl.init(allocator, io, &b_raft);
    impls_up = 1;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19640, &b_inbound, &b_thread);
    servers_up = 1;
    const b_endpoint = try allocator.print("127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);

    a_impl.init(allocator, io, &a_raft);
    impls_up = 2;
    try a_impl.addresses.addEndpoint("node-b", b_endpoint);

    // node-b has to recognise the leader whose AppendEntries carries the backlog, or
    // the catch-up below is refused at the door
    // (docs/dev/cluster-auth-design.md §4.1).
    var b_peers = [_]Peer{.{ .id = "node-a", .address = "" }};
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{}, &b_impl.transport());
    rafts_up = 1;
    var peers = [_]Peer{.{ .id = "node-b", .address = "" }};
    a_raft = try RaftElection.init(allocator, "node-a", &peers, .{}, &a_impl.transport());
    rafts_up = 2;

    // node-a leads term 1 with two entries; node-b's log is empty. A heartbeat
    // built from the leader's own tail (prev_log_index = 2) would be rejected
    // forever — the per-peer next_index is what lets the follower catch up.
    a_raft.state = .leader;
    a_raft.current_term = 1;
    _ = try a_raft.appendEntry("cmd-1");
    _ = try a_raft.appendEntry("cmd-2");
    try testing.expectEqual(@as(usize, 2), a_raft.logLen());
    try testing.expectEqual(@as(usize, 0), b_raft.logLen());

    // Every tick runs one heartbeat round; each rejection backs the peer's
    // next_index off one step until prev_log_index matches the follower's log
    // (3 → reject → 2 → reject → 1 → both entries flow). The rounds are
    // synchronous, so a bounded tick loop converges deterministically.
    a_raft.config.heartbeat_interval_ms = 0;
    var ticks: usize = 0;
    while (ticks < 8 and (b_raft.logLen() < 2 or b_raft.getCommitIndex() < 2)) : (ticks += 1) {
        try a_raft.tick();
    }

    // The follower caught up: same entries, same terms, same order.
    try testing.expectEqual(@as(usize, 2), b_raft.logLen());
    var i: u64 = 1;
    while (i <= 2) : (i += 1) {
        const ldr = a_raft.getLogEntry(i).?;
        const fwr = b_raft.getLogEntry(i).?;
        try testing.expectEqual(ldr.term, fwr.term);
        try testing.expectEqual(ldr.index, fwr.index);
        try testing.expectEqualStrings(ldr.command, fwr.command);
    }

    // Majority replication advanced the leader's commit index, and the next
    // heartbeat carried it to the follower.
    try testing.expectEqual(@as(u64, 2), a_raft.getCommitIndex());
    try testing.expectEqual(@as(u64, 2), b_raft.getCommitIndex());

    // Leader bookkeeping reflects the caught-up follower.
    try testing.expectEqual(@as(?u64, 3), a_raft.next_index.get("node-b"));
    try testing.expectEqual(@as(?u64, 2), a_raft.match_index.get("node-b"));

    // A heartbeat on the converged follower is accepted (prev_log_index = the
    // follower's own tail), so the steady state is stable, not flapping.
    const before = a_raft.next_index.get("node-b").?;
    try a_raft.tick();
    try testing.expectEqual(before, a_raft.next_index.get("node-b").?);
}

test "real loopback snapshot catch-up: a follower that fell into the snapshot converges via InstallSnapshot" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var a_impl: ElectionTransportImpl = undefined;
    var b_impl: TransportImpl(1) = undefined;
    var c_impl: TransportImpl(2) = undefined;
    var a_raft: RaftElection = undefined;
    var b_raft: RaftElection = undefined;
    var c_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;
    var c_inbound: InboundServer = undefined;
    var c_thread: std.Thread = undefined;

    var impls_up: u8 = 0;
    var rafts_up: u8 = 0;
    var servers_up: u8 = 0;
    defer {
        if (impls_up >= 3) c_impl.deinit();
        if (impls_up >= 2) a_impl.deinit();
        if (impls_up >= 1) b_impl.deinit();
    }
    defer {
        if (rafts_up >= 3) c_raft.deinit();
        if (rafts_up >= 2) a_raft.deinit();
        if (rafts_up >= 1) b_raft.deinit();
    }
    defer if (servers_up >= 2) stopInbound(io, &c_inbound, &c_thread);
    defer if (servers_up >= 1) stopInbound(io, &b_inbound, &b_thread);

    // b serves from the start; c stays unreachable until after the compaction,
    // which is what strands it behind the snapshot boundary.
    b_impl.init(allocator, io, &b_raft);
    impls_up = 1;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19720, &b_inbound, &b_thread);
    servers_up = 1;
    const b_endpoint = try allocator.print("127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);

    a_impl.init(allocator, io, &a_raft);
    impls_up = 2;
    try a_impl.addresses.addEndpoint("node-b", b_endpoint);

    c_impl.init(allocator, io, &c_raft);
    impls_up = 3;

    // Every node names every member: the follower-side check refuses RPCs from
    // unknown senders (docs/dev/cluster-auth-design.md §4.1).
    var b_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-c", .address = "" } };
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{}, &b_impl.transport());
    rafts_up = 1;
    var c_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-b", .address = "" } };
    c_raft = try RaftElection.init(allocator, "node-c", &c_peers, .{}, &c_impl.transport());
    rafts_up = 2;
    var a_peers = [_]Peer{ .{ .id = "node-b", .address = "" }, .{ .id = "node-c", .address = "" } };
    a_raft = try RaftElection.init(allocator, "node-a", &a_peers, .{}, &a_impl.transport());
    rafts_up = 3;

    // node-a leads term 1 with four entries; node-c's endpoint is not in the
    // address book yet, so the early rounds drop its frames as lost messages
    // and back its next_index down to 1.
    a_raft.state = .leader;
    a_raft.current_term = 1;
    a_raft.config.heartbeat_interval_ms = 0;
    for (0..4) |i| {
        var buf: [16]u8 = undefined;
        _ = try a_raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    var ticks: usize = 0;
    while (ticks < 12 and (b_raft.logLen() < 4 or a_raft.getCommitIndex() < 4)) : (ticks += 1) {
        try a_raft.tick();
    }
    try testing.expectEqual(@as(usize, 4), b_raft.logLen());
    try testing.expectEqual(@as(u64, 4), a_raft.getCommitIndex()); // quorum: a + b

    // Compact the committed prefix, then grow past it. A follower whose
    // next_index is at/below 3 can no longer be fed AppendEntries — §7.
    try a_raft.compactLog(3, "snap-payload");
    _ = try a_raft.appendEntry("cmd-4");
    _ = try a_raft.appendEntry("cmd-5");
    try testing.expectEqual(@as(usize, 3), a_raft.logLen()); // live: 4, 5, 6

    // node-c joins the network now, one snapshot and three entries behind.
    const c_port = try startInbound(allocator, io, &c_raft, &c_impl.addresses, 19760, &c_inbound, &c_thread);
    servers_up = 2;
    const c_endpoint = try allocator.print("127.0.0.1:{d}", .{c_port});
    defer allocator.free(c_endpoint);
    try a_impl.addresses.addEndpoint("node-c", c_endpoint);

    // Bounded rounds: the snapshot branch fires for c (next_index 1 <= the
    // boundary 3), then AppendEntries resumes at boundary + 1 until c holds
    // the live tail and the commit that covers it. Each round is synchronous,
    // so this converges deterministically. The loop condition reads only
    // locked accessors; the fields below are read after the last synchronous
    // round-trip, which orders them after the inbound thread's writes.
    ticks = 0;
    while (ticks < 40 and
        (c_raft.logLen() < 3 or c_raft.getCommitIndex() < 6)) : (ticks += 1)
    {
        try a_raft.tick();
    }

    // The snapshot landed verbatim…
    try testing.expectEqual(@as(u64, 3), c_raft.last_included_index);
    try testing.expectEqual(@as(u64, 1), c_raft.last_included_term);
    try testing.expectEqualStrings("snap-payload", c_raft.snapshot_data.?);

    // …and the live tail replicated on top of it, in absolute coordinates.
    try testing.expectEqual(@as(usize, 3), c_raft.logLen());
    var i: u64 = 4;
    while (i <= 6) : (i += 1) {
        const ldr = a_raft.getLogEntry(i).?;
        const fwr = c_raft.getLogEntry(i).?;
        try testing.expectEqual(ldr.term, fwr.term);
        try testing.expectEqual(ldr.index, fwr.index);
        try testing.expectEqualStrings(ldr.command, fwr.command);
    }
    try testing.expectEqual(@as(u64, 6), a_raft.getCommitIndex());
    try testing.expectEqual(@as(u64, 6), c_raft.getCommitIndex());

    // Leader bookkeeping: c resumed just past the snapshot and ended caught up.
    try testing.expectEqual(@as(?u64, 7), a_raft.next_index.get("node-c"));
    try testing.expectEqual(@as(?u64, 6), a_raft.match_index.get("node-c"));
}

/// Frames the black-hole peer below actually read. The handler now gets its
/// context as a parameter, so this is a file-scope counter rather than the
/// thread-local trick that predates it.
var black_hole_frames = std.atomic.Value(u64).init(0);

/// How long the black hole holds its half of the connection open after reading
/// the request. It has to outlast the client's timeout by a wide margin, or the
/// client's `recv` would come back on EOF instead of on the timeout and the test
/// below would pass for the wrong reason.
const black_hole_hold_ms = 2_000;

/// Accept, read the frame, and **never answer**.
///
/// This is the failure a connect timeout cannot cover, and the one a half-open
/// peer produces in production: the TCP handshake completes (so `connect`
/// returns), the request is delivered (so the peer is not "unreachable"), and
/// then nothing comes back. Without `SO_RCVTIMEO` the leader's synchronous reply
/// read waits for the peer to close — which, for a peer that is up but wedged,
/// is never.
fn blackHoleHandler(context: ?*anyopaque, conn: NetworkTransport.ClusterConnection) void {
    _ = context;
    var c = conn;
    defer c.deinit();
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(c.allocator);
    _ = c.recv(&buf) catch return;
    _ = black_hole_frames.fetchAdd(1, .monotonic);
    std.Io.sleep(c.io, std.Io.Duration.fromMilliseconds(black_hole_hold_ms), .awake) catch |err| {
        std.log.debug("[raft test] black-hole hold interrupted ({s})", .{@errorName(err)});
    };
}

// Verified red: setting `rpc_timeout_ms = 0` (the pre-fix behaviour — no bound)
// makes this fail on exactly the elapsed-time assertion, `elapsed <
// black_hole_hold_ms - 500`, because the call then waits for the peer's hold
// instead of the configured timeout. That is the difference between a bound and
// no bound, not a compile error.
test "a peer that accepts and never replies costs rpc_timeout_ms, not the peer's patience" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    black_hole_frames.store(0, .monotonic);

    // The client's bound, well under the peer's hold so "timeout fired" and "the
    // peer closed" are distinguishable by elapsed time alone.
    const timeout_ms: u32 = 200;

    var server = NetworkTransport.ClusterServer.init(allocator, io, 19660);
    var server_up = false;
    defer if (server_up) server.stop();
    const server_thread = try std.Thread.spawn(.{}, NetworkTransport.ClusterServer.start, .{ &server, blackHoleHandler, null });
    server_up = true;
    var spins: usize = 0;
    while (!server.running.load(.monotonic) and spins < 2000) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(server.running.load(.monotonic));

    var impl: ElectionTransportImpl = undefined;
    var raft: RaftElection = undefined;
    // The order every caller uses, and the reason the transport reads the
    // timeout out of the raft at send time instead of caching it in `init`:
    // `raft` is `undefined` right here.
    impl.init(allocator, io, &raft);
    defer impl.deinit();
    raft = try RaftElection.init(allocator, "node-a", &.{}, .{ .rpc_timeout_ms = timeout_ms }, &impl.transport());
    defer raft.deinit();

    const endpoint = try allocator.print("127.0.0.1:{d}", .{server.port});
    defer allocator.free(endpoint);

    const started = Time.monotonicNowMilliseconds();
    const resp = impl.sendAppendEntries("wedged", endpoint, .{
        .term = 1,
        .leader_id = "node-a",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &.{},
        .leader_commit = 0,
    });
    const elapsed = Time.monotonicNowMilliseconds() - started;

    // The answer is the contract's "lost message" — Raft re-sends, nothing else.
    try testing.expectEqual(@as(u64, 0), resp.term);
    try testing.expect(!resp.success);

    // The peer really took delivery: this was a *reply* wait, not a dial that
    // never completed. Without this the test would also pass against a peer that
    // was simply not listening — i.e. against the case that was already safe.
    try testing.expect(black_hole_frames.load(.monotonic) >= 1);

    // Bounded by the configured timeout, and *reached* it: an early return would
    // mean the peer closed (or the dial failed), neither of which is the state
    // under test. The upper bound is the real assertion — the pre-fix behaviour
    // waits for the peer's hold, which is `black_hole_hold_ms`.
    try testing.expect(elapsed >= @as(i64, timeout_ms) - 50);
    try testing.expect(elapsed < black_hole_hold_ms - 500);

    server.stop();
    // The accept loop may be blocked in `accept` rather than inside a handler
    // (which is the whole point of the change above), and closing the listener
    // does not reliably wake that. Same wake-up connection the inbound-server
    // teardown uses.
    if (dialTo(allocator, io, .{ .host = "127.0.0.1", .port = server.port }, test_dial_timeout_ms)) |wake| {
        var c = wake;
        c.deinit();
    } else |err| {
        std.log.debug("[raft test] wake connection not needed ({s})", .{@errorName(err)});
    }
    server_thread.join();
    server_up = false;
}

/// How long the test is willing to wait for the stalled peer's *second*
/// connection to be served. Well above the raft's bound, so "released by the
/// bound" and "still waiting on the peer" are distinguishable by elapsed time.
const stalled_peer_patience_ms: u32 = 2_000;

// Verified red: `rpc_timeout_ms = 0` (the pre-fix behaviour — `setRecvTimeout`
// returns early on 0) makes this fail on `expectError(error.ConnectionClosed,
// ...)` with `error.ConnectionError`: the second peer is never served, because
// A's half-frame holds the node's entire Raft inbound — no votes, no heartbeats,
// no replication — and `ClusterBootstrap.stop()` then blocks in `thread.join()`
// behind it.
//
// The *other* half of the property this test used to encode ("A's bound is what
// released B") is now asserted on A instead: B is served **before** A's bound
// expires, because each connection gets its own handler fiber. That is the
// assertion the inline-dispatch mutation below flips.
test "a half-frame on the inbound side costs rpc_timeout_ms, not the whole node" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const timeout_ms: u32 = 200;

    var impl: ElectionTransportImpl = undefined;
    var raft: RaftElection = undefined;
    impl.init(allocator, io, &raft);
    defer impl.deinit();
    raft = try RaftElection.init(allocator, "node-a", &.{}, .{ .rpc_timeout_ms = timeout_ms }, &impl.transport());
    defer raft.deinit();

    var inbound: InboundServer = undefined;
    var inbound_thread: std.Thread = undefined;
    const port = try startInbound(allocator, io, &raft, null, 19661, &inbound, &inbound_thread);
    defer stopInbound(io, &inbound, &inbound_thread);

    // Peer A: a length prefix promising 64 bytes, then silence. Four bytes. A
    // completed its handshake before B existed, so it is the connection whose
    // handler is stalled on the body if anything serializes the two.
    var peer_a = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port }, test_dial_timeout_ms);
    defer peer_a.deinit();
    sockread.setRecvTimeout(peer_a.stream, stalled_peer_patience_ms);
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, 64, .big);
    try sockread.writeFull(peer_a.stream, &prefix);

    // Peer B: a complete frame whose tag is not a Raft message, i.e. one
    // `handleConnection` answers by closing without a reply.
    var peer_b = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port }, test_dial_timeout_ms);
    defer peer_b.deinit();
    sockread.setRecvTimeout(peer_b.stream, stalled_peer_patience_ms);
    var junk: [8]u8 = @splat(0);
    std.mem.writeInt(u32, junk[0..4], 4, .big); // tag 0: no such MessageTag
    try sockread.writeFull(peer_b.stream, &junk);

    // Clocked before B's dial so the lower bound below cannot be lost to it.
    const started = Time.monotonicNowMilliseconds();
    var reply: [4]u8 = undefined;
    const served = sockread.readFull(peer_b.stream, &reply);
    const elapsed = Time.monotonicNowMilliseconds() - started;

    // B was served: the server closed it, rather than leaving it in the backlog
    // until B's own bound expired.
    try testing.expectError(error.ConnectionClosed, served);

    // ...and it was served *while A's half-frame was still outstanding*: an
    // immediate EOF cannot be the listen socket refusing the connection either
    // (that fails the dial above), and waiting for A's bound would put this at
    // `timeout_ms` or more.
    try testing.expect(elapsed < @as(i64, timeout_ms) - 50);

    // A is where the bound is visible: its half-frame is dropped at
    // `rpc_timeout_ms`, so this read ends in EOF neither immediately (something
    // else closed it) nor at the peer's own patience (nothing bounded it).
    const a_started = Time.monotonicNowMilliseconds();
    try testing.expectError(error.ConnectionClosed, sockread.readFull(peer_a.stream, &reply));
    const a_elapsed = Time.monotonicNowMilliseconds() - a_started;
    try testing.expect(a_elapsed >= @as(i64, timeout_ms) - 50);
    try testing.expect(a_elapsed < @as(i64, stalled_peer_patience_ms) - 500);
}

/// How long each stalled peer in the test below occupies a handler. Long enough
/// that "the third peer was served alongside them" and "the third peer waited
/// its turn" differ by an order of magnitude in elapsed time.
const concurrent_stall_ms: u32 = 1_000;

// Verified red: dispatching the handler inline again (removing `concurrent` from
// `ClusterServer.start`'s dispatch) makes this fail — measured, and **at the
// `fast.recv` bound rather than on the elapsed assertion below**. With inline
// dispatch the third peer's reply is not produced until both stalled peers have
// been released (~2 × `concurrent_stall_ms`), which is past that peer's own 2000 ms
// patience, so `fast.recv` returns `error.ConnectionError`
// (`FAIL (ConnectionError)` at the `try fast.recv` line, not a compile error and
// not a hang). Raising `fast`'s patience above 2 × the stall would move the catch
// to the elapsed assertion instead; "the reply never arrived inside its bound" is
// the stronger of the two statements, so that is the one relied on.
//
// Either way it is exactly the property the recv/send bounds do not provide: they
// bound *how long* one peer may stall the node's Raft inbound, not whether any
// other peer is served during it.
test "two stalled peers do not stop a third connection from being answered" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const timeout_ms = concurrent_stall_ms;

    var impl: ElectionTransportImpl = undefined;
    var raft: RaftElection = undefined;
    impl.init(allocator, io, &raft);
    defer impl.deinit();
    // `node-b` is a declared member, so the vote below passes the membership
    // check (docs/dev/cluster-auth-design.md §4.1) and the reply is a *granted*
    // one: the frame reached the raft, not merely the socket.
    var peers = [_]Peer{.{ .id = "node-b", .address = "" }};
    raft = try RaftElection.init(allocator, "node-a", &peers, .{ .rpc_timeout_ms = timeout_ms }, &impl.transport());
    defer raft.deinit();

    var inbound: InboundServer = undefined;
    var inbound_thread: std.Thread = undefined;
    const port = try startInbound(allocator, io, &raft, null, 19662, &inbound, &inbound_thread);
    defer stopInbound(io, &inbound, &inbound_thread);

    // Two peers that connect and then send a length prefix with no body: each
    // holds a handler until `rpc_timeout_ms` releases it.
    var slow_a = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port }, test_dial_timeout_ms);
    defer slow_a.deinit();
    var slow_b = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port }, test_dial_timeout_ms);
    defer slow_b.deinit();
    for ([_]*NetworkTransport.ClusterConnection{ &slow_a, &slow_b }) |stalled| {
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, 64, .big);
        try sockread.writeFull(stalled.stream, &prefix);
    }

    // The third peer sends a complete frame and has to be answered while both of
    // the above are still inside their handler.
    var fast = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port }, test_dial_timeout_ms);
    defer fast.deinit();
    sockread.setRecvTimeout(fast.stream, stalled_peer_patience_ms);

    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    try encodeVoteRequest(&frame, allocator, .{
        .term = 5,
        .candidate_id = "node-b",
        .last_log_index = 0,
        .last_log_term = 0,
    });

    const started = Time.monotonicNowMilliseconds();
    try writeFrame(fast.stream, frame.items);
    var reply = std.ArrayList(u8).empty;
    defer reply.deinit(allocator);
    const bytes = try fast.recv(&reply);
    const elapsed = Time.monotonicNowMilliseconds() - started;

    const decoded = try decodeVoteResponse(allocator, bytes);
    defer allocator.free(decoded.responder_id);
    try testing.expect(decoded.resp.vote_granted);
    try testing.expectEqual(@as(u64, 5), decoded.resp.term);

    // Served while both stalls were still outstanding. `fast`'s own bound is
    // `stalled_peer_patience_ms` (4× this), so a not-yet-served peer surfaces as
    // that read failing rather than as a hang.
    try testing.expect(elapsed < @as(i64, timeout_ms) / 2);
}

// The frame helpers above are unit-tested against a socketpair; this is the
// acceptance test for the wiring, over real loopback: with a secret configured,
// `sendSigned` → `verifiedRecv` → a *signed* reply → `readFrameAuth` has to work
// end to end, and a bare frame has to be dropped before it reaches the raft.
// The tests above this one all run with no secret, i.e. they cover the bare path.
test "with a cluster_secret, a loopback AppendEntries round-trip is signed end to end" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const secret: [32]u8 = @splat(0x33);

    var a_impl: ElectionTransportImpl = undefined;
    var b_impl: TransportImpl(1) = undefined;
    var a_raft: RaftElection = undefined;
    var b_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;

    var impls_up: u8 = 0;
    var rafts_up: u8 = 0;
    var servers_up: u8 = 0;
    defer {
        if (impls_up >= 2) a_impl.deinit();
        if (impls_up >= 1) b_impl.deinit();
    }
    defer {
        if (rafts_up >= 2) a_raft.deinit();
        if (rafts_up >= 1) b_raft.deinit();
    }
    defer if (servers_up >= 1) stopInbound(io, &b_inbound, &b_thread);

    b_impl.init(allocator, io, &b_raft);
    impls_up = 1;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19740, &b_inbound, &b_thread);
    servers_up = 1;
    const b_endpoint = try allocator.print("127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);

    a_impl.init(allocator, io, &a_raft);
    impls_up = 2;
    try a_impl.addresses.addEndpoint("node-b", b_endpoint);

    const cfg = ElectionConfig{ .cluster_secret = secret };
    // The follower recognises node-a by id, so the signed AppendEntries below reaches
    // the log (docs/dev/cluster-auth-design.md §4.1) — an L2 refusal would look like a
    // `success = false` reply and fail this test for the wrong reason.
    var b_peers = [_]Peer{.{ .id = "node-a", .address = "" }};
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, cfg, &b_impl.transport());
    rafts_up = 1;
    var peers = [_]Peer{.{ .id = "node-b", .address = "" }};
    a_raft = try RaftElection.init(allocator, "node-a", &peers, cfg, &a_impl.transport());
    rafts_up = 2;

    // 1. The signed round-trip: request out signed, reply back signed (the
    //    follower signs what it writes on the same connection), both verified.
    const entries = [_]LogEntry{.{ .term = 1, .index = 1, .command = "signed-cmd" }};
    const ack = a_impl.sendAppendEntries("node-b", "", .{
        .term = 1,
        .leader_id = "node-a",
        .prev_log_index = 0,
        .prev_log_term = 0,
        .entries = &entries,
        .leader_commit = 1,
    });
    try testing.expect(ack.success);
    try testing.expectEqual(@as(u64, 1), ack.match_index);
    try testing.expectEqual(@as(usize, 1), b_raft.logLen());
    try testing.expectEqualStrings("signed-cmd", b_raft.getLogEntry(1).?.command);

    // 2. A peer without the secret is dropped at the verifier: node-b is
    //    listening, the frame is well-formed, and the raft must not see it.
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);

        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteRequest(&frame, allocator, .{ .term = 42, .candidate_id = "outsider", .last_log_index = 9, .last_log_term = 9 });
        try writeFrame(conn.stream, frame.items);

        // No reply: `handleConnection` returns without answering (the same shape
        // as an unreadable frame), and the server then closes the connection.
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        try testing.expectError(error.ConnectionClosed, conn.recv(&reply));
    }
    try testing.expect(b_raft.getTerm() < 42);
    try testing.expectEqualStrings("node-a", b_raft.getLeader().?);
}

// ── A-1: per-node identity ───────────────────────────────────────────────────

test "claimedSenderId reads the sender id off each frame shape" {
    const allocator = testing.allocator;
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);

    try encodeVoteRequest(&frame, allocator, .{ .term = 9, .candidate_id = "node-a", .last_log_index = 1, .last_log_term = 1 });
    try testing.expectEqualStrings("node-a", claimedSenderId(frame.items).?);
    frame.clearRetainingCapacity();

    // The vote response tucks `granted` between the term and the id.
    try encodeVoteResponse(&frame, allocator, .{ .term = 9, .vote_granted = true }, "node-b");
    try testing.expectEqualStrings("node-b", claimedSenderId(frame.items).?);
    frame.clearRetainingCapacity();

    try encodeAppendEntries(&frame, allocator, .{ .term = 9, .leader_id = "node-c", .prev_log_index = 0, .prev_log_term = 0, .entries = &.{}, .leader_commit = 0 });
    try testing.expectEqualStrings("node-c", claimedSenderId(frame.items).?);
    frame.clearRetainingCapacity();

    try encodeInstallSnapshot(&frame, allocator, .{ .term = 9, .leader_id = "node-d", .last_included_index = 3, .last_included_term = 2, .offset = 0, .data = "snap", .done = true });
    try testing.expectEqualStrings("node-d", claimedSenderId(frame.items).?);
    frame.clearRetainingCapacity();

    // The synchronous-RPC replies carry no id: no key can be selected inbound.
    try encodeAppendEntriesResponse(&frame, allocator, .{ .term = 9, .success = true, .match_index = 1 });
    try testing.expectEqual(@as(?[]const u8, null), claimedSenderId(frame.items));
    frame.clearRetainingCapacity();
    try encodeInstallSnapshotResponse(&frame, allocator, .{ .term = 9 });
    try testing.expectEqual(@as(?[]const u8, null), claimedSenderId(frame.items));
    frame.clearRetainingCapacity();

    // Truncations are refused without reading past the bytes that are there:
    // a bare tag, and a frame cut off inside the id's length-prefixed body.
    try testing.expectEqual(@as(?[]const u8, null), claimedSenderId(&.{@backingInt(MessageTag.vote_request)}));
    try encodeVoteRequest(&frame, allocator, .{ .term = 9, .candidate_id = "node-a", .last_log_index = 1, .last_log_term = 1 });
    try testing.expectEqual(@as(?[]const u8, null), claimedSenderId(frame.items[0 .. 1 + 8 + 3]));
    // An unknown tag claims nothing.
    try testing.expectEqual(@as(?[]const u8, null), claimedSenderId(&[_]u8{ 0xfe, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
}

test "authMode and nodeKey resolve keys per node, fail-closed" {
    const key_own: [32]u8 = @splat(0x0a);
    const key_b: [32]u8 = @splat(0x0b);
    const key_s: [32]u8 = @splat(0x5e);

    // Nothing configured: the development path.
    try testing.expectEqual(AuthMode.bare, authMode(&.{}));
    try testing.expectEqual(SignAuth.bare, signAuth(&.{}));

    // `cluster_secret` alone: the shared path, wire-compatible with what shipped.
    const shared = ElectionConfig{ .cluster_secret = key_s };
    try testing.expectEqual(AuthMode.shared, authMode(&shared));
    switch (signAuth(&shared)) {
        .key => |k| try testing.expectEqual(key_s, k),
        else => return error.TestUnexpectedResult,
    }

    // Per-node wins over a shared key when both are set: a fallback would
    // re-open exactly the impersonation hole this mode exists to close.
    const peers = [_]PeerKey{.{ .id = "node-b", .key = key_b }};
    const both = ElectionConfig{ .cluster_secret = key_s, .own_key = key_own, .peer_keys = &peers };
    try testing.expectEqual(AuthMode.per_node, authMode(&both));
    switch (signAuth(&both)) {
        .key => |k| try testing.expectEqual(key_own, k),
        else => return error.TestUnexpectedResult,
    }

    // `peer_keys` alone already selects per-node mode, and without an `own_key`
    // the node refuses to sign at all rather than drift onto the bare wire.
    const listen_only = ElectionConfig{ .peer_keys = &peers };
    try testing.expectEqual(AuthMode.per_node, authMode(&listen_only));
    try testing.expectEqual(SignAuth.drop, signAuth(&listen_only));

    // nodeKey: the local id maps to `own_key` (null when unset — "I am you" is
    // refused), a peer id to its entry, an unknown id to null.
    try testing.expectEqual(@as(?[32]u8, key_own), nodeKey(&both, "node-a", "node-a"));
    try testing.expectEqual(@as(?[32]u8, key_b), nodeKey(&both, "node-a", "node-b"));
    try testing.expectEqual(@as(?[32]u8, null), nodeKey(&both, "node-a", "node-z"));
    try testing.expectEqual(@as(?[32]u8, null), nodeKey(&listen_only, "node-a", "node-a"));
}

/// The trio of keys the per-node loopback tests below run on.
const pernode_key_a: [32]u8 = @splat(0xa1);
const pernode_key_b: [32]u8 = @splat(0xb2);
const pernode_key_c: [32]u8 = @splat(0xc3);

test "real loopback per-node election: three keyed nodes elect a leader and replicate" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var a_impl: ElectionTransportImpl = undefined;
    var b_impl: TransportImpl(1) = undefined;
    var c_impl: TransportImpl(2) = undefined;
    var a_raft: RaftElection = undefined;
    var b_raft: RaftElection = undefined;
    var c_raft: RaftElection = undefined;
    var a_inbound: InboundServer = undefined;
    var b_inbound: InboundServer = undefined;
    var c_inbound: InboundServer = undefined;
    var a_thread: std.Thread = undefined;
    var b_thread: std.Thread = undefined;
    var c_thread: std.Thread = undefined;

    // Defers are registered before the work so they unwind in lifetime order:
    // servers first, then the rafts, then the transports they point at.
    var impls_up: u8 = 0;
    var rafts_up: u8 = 0;
    var servers_up: u8 = 0;
    defer {
        if (impls_up >= 3) a_impl.deinit();
        if (impls_up >= 2) c_impl.deinit();
        if (impls_up >= 1) b_impl.deinit();
    }
    defer {
        if (rafts_up >= 3) a_raft.deinit();
        if (rafts_up >= 2) c_raft.deinit();
        if (rafts_up >= 1) b_raft.deinit();
    }
    defer {
        if (servers_up >= 3) stopInbound(io, &a_inbound, &a_thread);
        if (servers_up >= 2) stopInbound(io, &c_inbound, &c_thread);
        if (servers_up >= 1) stopInbound(io, &b_inbound, &b_thread);
    }

    b_impl.init(allocator, io, &b_raft);
    impls_up = 1;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19840, &b_inbound, &b_thread);
    servers_up = 1;

    c_impl.init(allocator, io, &c_raft);
    impls_up = 2;
    const c_port = try startInbound(allocator, io, &c_raft, &c_impl.addresses, b_port + 1, &c_inbound, &c_thread);
    servers_up = 2;

    a_impl.init(allocator, io, &a_raft);
    impls_up = 3;
    const a_port = try startInbound(allocator, io, &a_raft, &a_impl.addresses, c_port + 1, &a_inbound, &a_thread);
    servers_up = 3;

    const b_endpoint = try allocator.print("127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);
    const c_endpoint = try allocator.print("127.0.0.1:{d}", .{c_port});
    defer allocator.free(c_endpoint);
    const a_endpoint = try allocator.print("127.0.0.1:{d}", .{a_port});
    defer allocator.free(a_endpoint);

    // Same wiring as the shared-key election: node-a dials from its address book,
    // node-b/node-c reach node-a to push granted votes back (the relay).
    try a_impl.addresses.addEndpoint("node-b", b_endpoint);
    try a_impl.addresses.addEndpoint("node-c", c_endpoint);
    try b_impl.addresses.addEndpoint("node-a", a_endpoint);
    try c_impl.addresses.addEndpoint("node-a", a_endpoint);

    // Every node signs with its own key and verifies each peer against that
    // peer's own key — the same secret is `own_key` on one side and the
    // `peer_keys` entry on the other (a symmetric pre-shared-key scheme).
    const b_keys = [_]PeerKey{ .{ .id = "node-a", .key = pernode_key_a }, .{ .id = "node-c", .key = pernode_key_c } };
    const c_keys = [_]PeerKey{ .{ .id = "node-a", .key = pernode_key_a }, .{ .id = "node-b", .key = pernode_key_b } };
    const a_keys = [_]PeerKey{ .{ .id = "node-b", .key = pernode_key_b }, .{ .id = "node-c", .key = pernode_key_c } };

    var b_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-c", .address = "" } };
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{ .own_key = pernode_key_b, .peer_keys = &b_keys }, &b_impl.transport());
    rafts_up = 1;
    var c_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-b", .address = "" } };
    c_raft = try RaftElection.init(allocator, "node-c", &c_peers, .{ .own_key = pernode_key_c, .peer_keys = &c_keys }, &c_impl.transport());
    rafts_up = 2;
    var a_peers = [_]Peer{ .{ .id = "node-b", .address = "" }, .{ .id = "node-c", .address = "" } };
    a_raft = try RaftElection.init(allocator, "node-a", &a_peers, .{ .own_key = pernode_key_a, .peer_keys = &a_keys }, &a_impl.transport());
    rafts_up = 3;

    // The election itself exercises every per-node path at once: signed vote
    // requests out, per-frame verification inbound, and the granted vote relayed
    // back signed with the voter's own key.
    a_raft.election_deadline_ms = Time.monotonicNowMilliseconds() - 1;
    try a_raft.tick();

    var spins: usize = 0;
    while (!a_raft.isLeader() and spins < 3000) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(a_raft.isLeader());
    try testing.expectEqual(@as(u64, 1), a_raft.getTerm());
    try testing.expect(waitForTerm(io, &b_raft, 1, 2000));
    try testing.expect(waitForTerm(io, &c_raft, 1, 2000));
    try testing.expectEqualStrings("node-a", b_raft.voted_for.?);
    try testing.expectEqualStrings("node-a", c_raft.voted_for.?);

    // Replication on the keyed wire: AppendEntries signed by the leader, each
    // follower's same-connection reply signed by the follower.
    a_raft.config.heartbeat_interval_ms = 0;
    _ = try a_raft.appendEntry("pernode-cmd-1");
    var ticks: usize = 0;
    while (ticks < 12 and
        (b_raft.getCommitIndex() < 1 or c_raft.getCommitIndex() < 1)) : (ticks += 1)
    {
        try a_raft.tick();
    }
    try testing.expectEqual(@as(usize, 1), b_raft.logLen());
    try testing.expectEqual(@as(usize, 1), c_raft.logLen());
    try testing.expectEqualStrings("pernode-cmd-1", b_raft.getLogEntry(1).?.command);
    try testing.expectEqualStrings("pernode-cmd-1", c_raft.getLogEntry(1).?.command);
    try testing.expectEqual(@as(u64, 1), a_raft.getCommitIndex());
    try testing.expectEqual(@as(u64, 1), b_raft.getCommitIndex());
    try testing.expectEqual(@as(u64, 1), c_raft.getCommitIndex());
}

// The A-1 acceptance test, and it must stay *mutant-sensitive*: an inbound
// verifier that accepts a frame signed by **any** configured key (instead of
// the claimed sender's own) turns steps 1/4 red — that mutation was run, and
// both steps failed before the fix was restored.
test "per-node: a frame signed with another node's key is refused (impersonation)" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // node-b's inbound, per-node keyed. The attacker holds node-b's key — a
    // legitimate cluster credential — and claims to be node-a with it.
    var b_impl: TransportImpl(1) = undefined;
    var b_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;

    var impl_up = false;
    var raft_up = false;
    var server_up = false;
    defer if (impl_up) b_impl.deinit();
    defer if (raft_up) b_raft.deinit();
    defer if (server_up) stopInbound(io, &b_inbound, &b_thread);

    b_impl.init(allocator, io, &b_raft);
    impl_up = true;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19900, &b_inbound, &b_thread);
    server_up = true;

    const b_keys = [_]PeerKey{.{ .id = "node-a", .key = pernode_key_a }};
    var b_peers = [_]Peer{.{ .id = "node-a", .address = "" }};
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{ .own_key = pernode_key_b, .peer_keys = &b_keys }, &b_impl.transport());
    raft_up = true;
    // The candidacy in step 5 dials node-a: an unreachable placeholder, so the
    // request is a lost message and the test drives the vote itself.
    try b_impl.addresses.addEndpoint("node-a", "127.0.0.1:1");

    // 1. Impersonated vote_request: claims `candidate_id = "node-a"`, signed
    //    with node-b's key. Refused at the verifier, and the raft never sees it.
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteRequest(&frame, allocator, .{ .term = 5, .candidate_id = "node-a", .last_log_index = 0, .last_log_term = 0 });
        try sendSigned(pernode_key_b, &conn, frame.items);
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        try testing.expectError(error.ConnectionClosed, conn.recv(&reply));
    }
    try testing.expectEqual(@as(u64, 0), b_raft.getTerm());

    // 2. Positive control: the same frame signed with node-a's *own* key is
    //    served — and the reply verifies against node-b's own key, which is the
    //    binding the caller checks on every synchronous RPC.
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteRequest(&frame, allocator, .{ .term = 5, .candidate_id = "node-a", .last_log_index = 0, .last_log_term = 0 });
        try sendSigned(pernode_key_a, &conn, frame.items);
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        const bytes = try verifiedRecv(pernode_key_b, &conn, &reply);
        const decoded = try decodeVoteResponse(allocator, bytes);
        defer allocator.free(decoded.responder_id);
        try testing.expect(decoded.resp.vote_granted);
        try testing.expectEqual(@as(u64, 5), decoded.resp.term);
        try testing.expectEqualStrings("node-b", decoded.responder_id);
    }
    try testing.expectEqual(@as(u64, 5), b_raft.getTerm());
    try testing.expectEqualStrings("node-a", b_raft.voted_for.?);

    // 3. Impersonated AppendEntries: same shape, the log must not grow.
    const entries = [_]LogEntry{.{ .term = 5, .index = 1, .command = "forged-cmd" }};
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeAppendEntries(&frame, allocator, .{ .term = 5, .leader_id = "node-a", .prev_log_index = 0, .prev_log_term = 0, .entries = &entries, .leader_commit = 1 });
        try sendSigned(pernode_key_b, &conn, frame.items);
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        try testing.expectError(error.ConnectionClosed, conn.recv(&reply));
    }
    try testing.expectEqual(@as(usize, 0), b_raft.logLen());

    // 4. Positive control: signed with node-a's key the entry lands.
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeAppendEntries(&frame, allocator, .{ .term = 5, .leader_id = "node-a", .prev_log_index = 0, .prev_log_term = 0, .entries = &entries, .leader_commit = 1 });
        try sendSigned(pernode_key_a, &conn, frame.items);
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        const bytes = try verifiedRecv(pernode_key_b, &conn, &reply);
        const ack = try decodeAppendEntriesResponse(bytes);
        try testing.expect(ack.success);
    }
    try testing.expectEqual(@as(usize, 1), b_raft.logLen());
    try testing.expectEqualStrings("forged-cmd", b_raft.getLogEntry(1).?.command);

    // 5. The vote_response branch, driven for a real outcome: with node-b a
    //    candidate of size 2, one genuine grant from node-a elects it — so a
    //    *forged* grant must not. (This tag gets no reply either way; the raft
    //    state is the observable.)
    b_raft.election_deadline_ms = Time.monotonicNowMilliseconds() - 1;
    try b_raft.tick();
    try testing.expectEqual(RaftState.candidate, b_raft.getState());
    const candidacy_term = b_raft.getTerm();
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteResponse(&frame, allocator, .{ .term = candidacy_term, .vote_granted = true }, "node-a");
        try sendSigned(pernode_key_b, &conn, frame.items);
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        try testing.expectError(error.ConnectionClosed, conn.recv(&reply));
    }
    var settle: usize = 0;
    while (settle < 100) : (settle += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(!b_raft.isLeader());
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteResponse(&frame, allocator, .{ .term = candidacy_term, .vote_granted = true }, "node-a");
        try sendSigned(pernode_key_a, &conn, frame.items);
    }
    var spins: usize = 0;
    while (!b_raft.isLeader() and spins < 2000) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(b_raft.isLeader());
}

/// Counts accepted connections; the fail-closed assertions below are "the dial
/// never happened", so the peer is a listener, not a raft.
var failclosed_accepts = std.atomic.Value(u64).init(0);

fn failClosedHandler(context: ?*anyopaque, conn: NetworkTransport.ClusterConnection) void {
    _ = context;
    var c = conn;
    defer c.deinit();
    _ = failclosed_accepts.fetchAdd(1, .monotonic);
}

// Mutant-sensitive the other way: an `outboundKeys` that dials anyway when the
// per-node target has no key turns step 2 red (the listener sees the
// connection) — that mutation was run and failed before the fix was restored.
test "per-node fail-closed: unkeyed sender refused inbound, unkeyed peer never dialled" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // 1. Inbound: node-z is a raft **member** (the L2 check would admit it) but
    //    has no configured key — so the L1 verifier refuses it first. That
    //    isolation is the point: the refusal is the missing key, not membership.
    var b_impl: TransportImpl(1) = undefined;
    var b_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;

    var impl_up = false;
    var raft_up = false;
    var server_up = false;
    defer if (impl_up) b_impl.deinit();
    defer if (raft_up) b_raft.deinit();
    defer if (server_up) stopInbound(io, &b_inbound, &b_thread);

    b_impl.init(allocator, io, &b_raft);
    impl_up = true;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 19960, &b_inbound, &b_thread);
    server_up = true;

    const b_keys = [_]PeerKey{.{ .id = "node-a", .key = pernode_key_a }};
    var b_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-z", .address = "" } };
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{ .own_key = pernode_key_b, .peer_keys = &b_keys }, &b_impl.transport());
    raft_up = true;

    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteRequest(&frame, allocator, .{ .term = 7, .candidate_id = "node-z", .last_log_index = 0, .last_log_term = 0 });
        try sendSigned(@splat(0x99), &conn, frame.items); // any key: none is configured for node-z
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        try testing.expectError(error.ConnectionClosed, conn.recv(&reply));
    }
    try testing.expectEqual(@as(u64, 0), b_raft.getTerm());

    // Control: the same port serves a keyed member, so the refusal above was
    // the missing key, not a dead listener.
    {
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port }, test_dial_timeout_ms);
        defer conn.deinit();
        sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(allocator);
        try encodeVoteRequest(&frame, allocator, .{ .term = 7, .candidate_id = "node-a", .last_log_index = 0, .last_log_term = 0 });
        try sendSigned(pernode_key_a, &conn, frame.items);
        var reply = std.ArrayList(u8).empty;
        defer reply.deinit(allocator);
        const bytes = try verifiedRecv(pernode_key_b, &conn, &reply);
        const decoded = try decodeVoteResponse(allocator, bytes);
        defer allocator.free(decoded.responder_id);
        try testing.expect(decoded.resp.vote_granted);
    }

    // 2. Outbound: a peer with no configured key is never even dialled, on all
    //    three RPC paths — the message is lost (Raft re-sends), the wire stays
    //    authenticated-only.
    failclosed_accepts.store(0, .monotonic);
    var listener = NetworkTransport.ClusterServer.init(allocator, io, 20010);
    var listener_up = false;
    defer if (listener_up) listener.stop();
    const listener_thread = try std.Thread.spawn(.{}, NetworkTransport.ClusterServer.start, .{ &listener, failClosedHandler, null });
    listener_up = true;
    var spins: usize = 0;
    while (!listener.running.load(.monotonic) and spins < 2000) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(listener.running.load(.monotonic));

    var a_impl: ElectionTransportImpl = undefined;
    var a_raft: RaftElection = undefined;
    var a_impl_up = false;
    var a_raft_up = false;
    defer if (a_impl_up) a_impl.deinit();
    defer if (a_raft_up) a_raft.deinit();
    a_impl.init(allocator, io, &a_raft);
    a_impl_up = true;
    const a_keys = [_]PeerKey{.{ .id = "node-b", .key = pernode_key_b }};
    var a_peers = [_]Peer{ .{ .id = "node-b", .address = "" }, .{ .id = "node-c", .address = "" } };
    a_raft = try RaftElection.init(allocator, "node-a", &a_peers, .{ .own_key = pernode_key_a, .peer_keys = &a_keys }, &a_impl.transport());
    a_raft_up = true;
    // node-c is addressable but keyless; node-b is the keyed control, dialled at
    // the same listener.
    try a_impl.addresses.addEndpoint("node-c", "127.0.0.1:20010");
    try a_impl.addresses.addEndpoint("node-b", "127.0.0.1:20010");

    const lost = a_impl.sendAppendEntries("node-c", "", .{ .term = 1, .leader_id = "node-a", .prev_log_index = 0, .prev_log_term = 0, .entries = &.{}, .leader_commit = 0 });
    try testing.expect(!lost.success);
    try testing.expectEqual(@as(u64, 0), lost.term);
    a_impl.transport().*.sendVoteRequest("node-c", "", .{ .term = 1, .candidate_id = "node-a", .last_log_index = 0, .last_log_term = 0 });
    const lost_snap = a_impl.sendInstallSnapshot("node-c", "", .{ .term = 1, .leader_id = "node-a", .last_included_index = 0, .last_included_term = 0, .offset = 0, .data = "", .done = true });
    try testing.expectEqual(@as(u64, 0), lost_snap.term);
    try testing.expectEqual(@as(u64, 0), failclosed_accepts.load(.monotonic));

    // Control: the keyed peer at the same address *is* dialled (the listener
    // closes without answering, which is a lost reply — the accept is the
    // assertion, not the response).
    _ = a_impl.sendAppendEntries("node-b", "", .{ .term = 1, .leader_id = "node-a", .prev_log_index = 0, .prev_log_term = 0, .entries = &.{}, .leader_commit = 0 });
    try testing.expectEqual(@as(u64, 1), failclosed_accepts.load(.monotonic));

    // 3. A node with peer keys but no `own_key` refuses to send at all
    //    (`SignAuth.drop`): sending bare would be a silent downgrade.
    var d_impl: TransportImpl(3) = undefined;
    var d_raft: RaftElection = undefined;
    var d_impl_up = false;
    var d_raft_up = false;
    defer if (d_impl_up) d_impl.deinit();
    defer if (d_raft_up) d_raft.deinit();
    d_impl.init(allocator, io, &d_raft);
    d_impl_up = true;
    var d_peers = [_]Peer{.{ .id = "node-b", .address = "" }};
    d_raft = try RaftElection.init(allocator, "node-d", &d_peers, .{ .peer_keys = &a_keys }, &d_impl.transport());
    d_raft_up = true;
    try d_impl.addresses.addEndpoint("node-b", "127.0.0.1:20010");
    const d_lost = d_impl.sendAppendEntries("node-b", "", .{ .term = 1, .leader_id = "node-d", .prev_log_index = 0, .prev_log_term = 0, .entries = &.{}, .leader_commit = 0 });
    try testing.expect(!d_lost.success);
    try testing.expectEqual(@as(u64, 1), failclosed_accepts.load(.monotonic));

    listener.stop();
    if (dialTo(allocator, io, .{ .host = "127.0.0.1", .port = 20010 }, test_dial_timeout_ms)) |wake| {
        var c = wake;
        c.deinit();
    } else |err| {
        std.log.debug("[raft test] wake connection not needed ({s})", .{@errorName(err)});
    }
    listener_thread.join();
    listener_up = false;
}

test "real loopback per-node snapshot catch-up: keyed InstallSnapshot converges" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var a_impl: ElectionTransportImpl = undefined;
    var b_impl: TransportImpl(1) = undefined;
    var c_impl: TransportImpl(2) = undefined;
    var a_raft: RaftElection = undefined;
    var b_raft: RaftElection = undefined;
    var c_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;
    var c_inbound: InboundServer = undefined;
    var c_thread: std.Thread = undefined;

    var impls_up: u8 = 0;
    var rafts_up: u8 = 0;
    var servers_up: u8 = 0;
    defer {
        if (impls_up >= 3) c_impl.deinit();
        if (impls_up >= 2) a_impl.deinit();
        if (impls_up >= 1) b_impl.deinit();
    }
    defer {
        if (rafts_up >= 3) c_raft.deinit();
        if (rafts_up >= 2) a_raft.deinit();
        if (rafts_up >= 1) b_raft.deinit();
    }
    defer if (servers_up >= 2) stopInbound(io, &c_inbound, &c_thread);
    defer if (servers_up >= 1) stopInbound(io, &b_inbound, &b_thread);

    // b serves from the start; c stays unreachable until after the compaction,
    // which is what strands it behind the snapshot boundary.
    b_impl.init(allocator, io, &b_raft);
    impls_up = 1;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 20040, &b_inbound, &b_thread);
    servers_up = 1;
    const b_endpoint = try allocator.print("127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);

    a_impl.init(allocator, io, &a_raft);
    impls_up = 2;
    try a_impl.addresses.addEndpoint("node-b", b_endpoint);

    c_impl.init(allocator, io, &c_raft);
    impls_up = 3;

    // Same per-node keyring as the election test: each node signs with its own
    // key, verifies each peer against that peer's own key.
    const b_keys = [_]PeerKey{ .{ .id = "node-a", .key = pernode_key_a }, .{ .id = "node-c", .key = pernode_key_c } };
    const c_keys = [_]PeerKey{ .{ .id = "node-a", .key = pernode_key_a }, .{ .id = "node-b", .key = pernode_key_b } };
    const a_keys = [_]PeerKey{ .{ .id = "node-b", .key = pernode_key_b }, .{ .id = "node-c", .key = pernode_key_c } };

    var b_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-c", .address = "" } };
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{ .own_key = pernode_key_b, .peer_keys = &b_keys }, &b_impl.transport());
    rafts_up = 1;
    var c_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-b", .address = "" } };
    c_raft = try RaftElection.init(allocator, "node-c", &c_peers, .{ .own_key = pernode_key_c, .peer_keys = &c_keys }, &c_impl.transport());
    rafts_up = 2;
    var a_peers = [_]Peer{ .{ .id = "node-b", .address = "" }, .{ .id = "node-c", .address = "" } };
    a_raft = try RaftElection.init(allocator, "node-a", &a_peers, .{ .own_key = pernode_key_a, .peer_keys = &a_keys }, &a_impl.transport());
    rafts_up = 3;

    // node-a leads term 1 with four entries; node-c's endpoint is not in the
    // address book yet, so the early rounds drop its frames as lost messages
    // and back its next_index down to 1.
    a_raft.state = .leader;
    a_raft.current_term = 1;
    a_raft.config.heartbeat_interval_ms = 0;
    for (0..4) |i| {
        var buf: [16]u8 = undefined;
        _ = try a_raft.appendEntry(try std.fmt.bufPrint(&buf, "cmd-{d}", .{i}));
    }
    var ticks: usize = 0;
    while (ticks < 12 and (b_raft.logLen() < 4 or a_raft.getCommitIndex() < 4)) : (ticks += 1) {
        try a_raft.tick();
    }
    try testing.expectEqual(@as(usize, 4), b_raft.logLen());
    try testing.expectEqual(@as(u64, 4), a_raft.getCommitIndex()); // quorum: a + b

    // Compact the committed prefix, then grow past it. A follower whose
    // next_index is at/below 3 can no longer be fed AppendEntries — §7.
    try a_raft.compactLog(3, "snap-pernode");
    _ = try a_raft.appendEntry("cmd-4");
    _ = try a_raft.appendEntry("cmd-5");
    try testing.expectEqual(@as(usize, 3), a_raft.logLen()); // live: 4, 5, 6

    // node-c joins the network now, one snapshot and three entries behind.
    const c_port = try startInbound(allocator, io, &c_raft, &c_impl.addresses, 20090, &c_inbound, &c_thread);
    servers_up = 2;
    const c_endpoint = try allocator.print("127.0.0.1:{d}", .{c_port});
    defer allocator.free(c_endpoint);
    try a_impl.addresses.addEndpoint("node-c", c_endpoint);

    // Bounded rounds: the keyed snapshot branch fires for c (next_index 1 <= the
    // boundary 3), then keyed AppendEntries resumes at boundary + 1 until c
    // holds the live tail and the commit that covers it.
    ticks = 0;
    while (ticks < 40 and
        (c_raft.logLen() < 3 or c_raft.getCommitIndex() < 6)) : (ticks += 1)
    {
        try a_raft.tick();
    }

    // The snapshot landed verbatim…
    try testing.expectEqual(@as(u64, 3), c_raft.last_included_index);
    try testing.expectEqual(@as(u64, 1), c_raft.last_included_term);
    try testing.expectEqualStrings("snap-pernode", c_raft.snapshot_data.?);

    // …and the live tail replicated on top of it, in absolute coordinates.
    try testing.expectEqual(@as(usize, 3), c_raft.logLen());
    var i: u64 = 4;
    while (i <= 6) : (i += 1) {
        const ldr = a_raft.getLogEntry(i).?;
        const fwr = c_raft.getLogEntry(i).?;
        try testing.expectEqual(ldr.term, fwr.term);
        try testing.expectEqual(ldr.index, fwr.index);
        try testing.expectEqualStrings(ldr.command, fwr.command);
    }
    try testing.expectEqual(@as(u64, 6), a_raft.getCommitIndex());
    try testing.expectEqual(@as(u64, 6), c_raft.getCommitIndex());

    // Leader bookkeeping: c resumed just past the snapshot and ended caught up.
    try testing.expectEqual(@as(?u64, 7), a_raft.next_index.get("node-c"));
    try testing.expectEqual(@as(?u64, 6), a_raft.match_index.get("node-c"));
}

// ── Bounded dial ────────────────────────────────────────────────────────────

/// `O_NONBLOCK` as the *kernel* sees it on `fd`, read back with `fcntl` — the
/// assertion is about the socket's real state rather than about what we meant
/// to ask for.
fn nonblockSet(fd: std.posix.socket_t) bool {
    const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(rc) != .SUCCESS) return false;
    const bits: u32 = @truncate(@as(u64, @bitCast(@as(i64, @intCast(rc)))));
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    return bits & nonblock != 0;
}

// Verified red: with the bound removed (the pre-fix `dialTo`, i.e. a plain
// `IpAddress.connect`) this dial does not return — the SYN to a link-local
// address that has no responder is never answered and macOS keeps the socket in
// SYN_SENT (measured: still pending after 25 s). Green: it returns on the
// configured bound, and the elapsed time proves the bound was *reached* rather
// than the dial failing early for some other reason.
//
// The bound is the assertion; the address is not. `169.254.255.254` is RFC 3927
// link-local with nothing on the link, which is what this machine black-holes
// today (and what the 25 s measurement above used). Another environment may
// answer it, or refuse it outright — hence the probe: without a black hole to
// dial there is nothing to assert, and skipping says so.
test "a black-holed dial returns on the bound, not on the kernel's default" {
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const black_hole = try std.Io.net.IpAddress.parse("169.254.255.254", 80);

    if (connectTimeout(io, black_hole, 150)) |stream| {
        stream.close(io); // something on this link answers: no black hole here
        return error.SkipZigTest;
    } else |err| switch (err) {
        error.ConnectTimeout => {},
        else => {
            std.log.info("[raft] {s}:80 does not black-hole here ({s}) — skipping the connect-bound test", .{ "169.254.255.254", @errorName(err) });
            return error.SkipZigTest;
        },
    }

    const bound_ms: u32 = 700;
    const started = Time.monotonicNowMilliseconds();
    const result = connectTimeout(io, black_hole, bound_ms);
    const elapsed = Time.monotonicNowMilliseconds() - started;
    if (result) |stream| {
        stream.close(io);
        return error.SkipZigTest; // answered inside the bound after all
    } else |err| switch (err) {
        error.ConnectTimeout => {},
        else => {
            // Black-holing a link-local address relies on its ARP going
            // unanswered; back-to-back dials race the kernel's neighbour
            // cache, and a negative entry turns this second dial into an
            // immediate EHOSTUNREACH even though the probe above timed out.
            // The premise (the address hangs) proved unstable — skip, as the
            // probe does, rather than assert on an environment artifact.
            std.log.info("[raft] {s}:80 stopped black-holing between probe and measurement ({s}) — skipping the connect-bound test", .{ "169.254.255.254", @errorName(err) });
            return error.SkipZigTest;
        },
    }

    // The bound, and not something shorter: `ConnectionRefused` and friends
    // would mean the dial was never hanging, which is the case this test is not
    // about. The upper end is the real assertion — the kernel's own default for
    // this address is the >25 s measured above.
    try testing.expect(elapsed >= @as(i64, bound_ms) - 150);
    try testing.expect(elapsed < 5_000);
}

test "connectTimeout hands back a blocking stream the sockread helpers can use" {
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const bind = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try bind.listen(io, .{});
    defer server.deinit(io);
    var client = try connectTimeout(io, try std.Io.net.IpAddress.parse("127.0.0.1", server.socket.address.getPort()), test_dial_timeout_ms);
    defer client.close(io);
    var accepted = try server.accept(io);
    defer accepted.close(io);

    // The invariant `sockread` is built on: a socket left non-blocking would
    // come back `EAGAIN` from these, and the WebSocket write path treats `EAGAIN`
    // as a programmer bug and panics on it in debug builds. Then the helpers
    // themselves, which is what the cluster transport actually calls.
    try testing.expect(!nonblockSet(client.socket.handle));
    try sockread.writeFull(client, "ping");
    var buf: [4]u8 = undefined;
    try sockread.readFull(accepted, &buf);
    try testing.expectEqualStrings("ping", &buf);

    // A dial that really fails is still reported as itself: `SO_ERROR` is read
    // even though `poll` said "ready", so a refused port is not folded into the
    // timeout.
    var gone = try bind.listen(io, .{});
    const gone_port = gone.socket.address.getPort();
    gone.deinit(io);
    try testing.expectError(error.ConnectionRefused, connectTimeout(io, try std.Io.net.IpAddress.parse("127.0.0.1", gone_port), test_dial_timeout_ms));
}

// ── A-3: rotation window & revocation on the wire ───────────────────────────
//
// The runtime half of per-node identity (`RaftElection.rotateOwnKey` /
// `rotatePeerKey` / `setPeerKey` / `dropPreviousPeerKey` / `revokePeerKey`).
// Wire format untouched: the window changes *which key verifies*, never the
// frame shape.

/// Rotated credentials for the A-3 tests (distinct from the `pernode_key_*`
/// constants the A-1 tests run on).
const rotated_key_a: [32]u8 = @splat(0xa2);
const rotated_key_b: [32]u8 = @splat(0xb5);

/// One vote_request round trip: dial `port`, send the request signed with
/// `sign_key`, and hand back the **raw** reply bytes (MAC still attached, so
/// the caller decides which key must verify them — and which must not). Null
/// is the fail-closed answer: the peer dropped the connection without
/// answering.
fn voteExchangeRaw(
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    term: u64,
    candidate_id: []const u8,
    sign_key: [32]u8,
) !?[]u8 {
    var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port }, test_dial_timeout_ms);
    defer conn.deinit();
    sockread.setRecvTimeout(conn.stream, stalled_peer_patience_ms);
    var frame = std.ArrayList(u8).empty;
    defer frame.deinit(allocator);
    try encodeVoteRequest(&frame, allocator, .{ .term = term, .candidate_id = candidate_id, .last_log_index = 0, .last_log_term = 0 });
    try sendSigned(sign_key, &conn, frame.items);
    var reply = std.ArrayList(u8).empty;
    defer reply.deinit(allocator);
    _ = conn.recv(&reply) catch return null;
    return try allocator.dupe(u8, reply.items);
}

test "per-node key revocation: a revoked peer is refused inbound and never dialled, keyed peers unaffected" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // node-b inbound, keyed for node-a and node-c.
    var b_impl: TransportImpl(1) = undefined;
    var b_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;

    var impl_up = false;
    var raft_up = false;
    var server_up = false;
    defer if (impl_up) b_impl.deinit();
    defer if (raft_up) b_raft.deinit();
    defer if (server_up) stopInbound(io, &b_inbound, &b_thread);

    b_impl.init(allocator, io, &b_raft);
    impl_up = true;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 20200, &b_inbound, &b_thread);
    server_up = true;

    const b_keys = [_]PeerKey{ .{ .id = "node-a", .key = pernode_key_a }, .{ .id = "node-c", .key = pernode_key_c } };
    var b_peers = [_]Peer{ .{ .id = "node-a", .address = "" }, .{ .id = "node-c", .address = "" } };
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{ .own_key = pernode_key_b, .peer_keys = &b_keys }, &b_impl.transport());
    raft_up = true;

    // Positive control: node-c is answered before the revocation.
    const before = (try voteExchangeRaw(allocator, io, b_port, 7, "node-c", pernode_key_c)) orelse return error.TestUnexpectedResult;
    defer allocator.free(before);
    _ = try verifyFrameMac(pernode_key_b, before);
    try testing.expectEqual(@as(u64, 7), b_raft.getTerm());

    // Revoke. Second call and an unknown id both report "nothing was there".
    try testing.expect(try b_raft.revokePeerKey("node-c"));
    try testing.expect(!try b_raft.revokePeerKey("node-c"));
    try testing.expect(!try b_raft.revokePeerKey("node-zz"));

    // Inbound frames from node-c — even signed with its erstwhile *legitimate*
    // key — fail the key lookup now, and the raft never sees them.
    try testing.expect((try voteExchangeRaw(allocator, io, b_port, 8, "node-c", pernode_key_c)) == null);
    try testing.expect((try voteExchangeRaw(allocator, io, b_port, 8, "node-c", @splat(0x99))) == null);
    try testing.expectEqual(@as(u64, 7), b_raft.getTerm());

    // Positive control after: node-a is still answered, so the refusal above
    // is the revocation and not a dead listener.
    const after = (try voteExchangeRaw(allocator, io, b_port, 9, "node-a", pernode_key_a)) orelse return error.TestUnexpectedResult;
    defer allocator.free(after);
    _ = try verifyFrameMac(pernode_key_b, after);
    try testing.expectEqual(@as(u64, 9), b_raft.getTerm());

    // Outbound: a revoked peer is never dialled (the fail-closed `outboundKeys`
    // gate now misses on the removed entry). The listener only counts accepts.
    failclosed_accepts.store(0, .monotonic);
    var listener = NetworkTransport.ClusterServer.init(allocator, io, 20210);
    var listener_up = false;
    defer if (listener_up) listener.stop();
    const listener_thread = try std.Thread.spawn(.{}, NetworkTransport.ClusterServer.start, .{ &listener, failClosedHandler, null });
    listener_up = true;
    var spins: usize = 0;
    while (!listener.running.load(.monotonic) and spins < 2000) : (spins += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(listener.running.load(.monotonic));

    var a_impl: ElectionTransportImpl = undefined;
    var a_raft: RaftElection = undefined;
    var a_impl_up = false;
    var a_raft_up = false;
    defer if (a_impl_up) a_impl.deinit();
    defer if (a_raft_up) a_raft.deinit();
    a_impl.init(allocator, io, &a_raft);
    a_impl_up = true;
    const a_keys = [_]PeerKey{ .{ .id = "node-b", .key = pernode_key_b }, .{ .id = "node-c", .key = pernode_key_c } };
    var a_peers = [_]Peer{ .{ .id = "node-b", .address = "" }, .{ .id = "node-c", .address = "" } };
    a_raft = try RaftElection.init(allocator, "node-a", &a_peers, .{ .own_key = pernode_key_a, .peer_keys = &a_keys }, &a_impl.transport());
    a_raft_up = true;
    try a_impl.addresses.addEndpoint("node-c", "127.0.0.1:20210");
    try a_impl.addresses.addEndpoint("node-b", "127.0.0.1:20210");

    try testing.expect(try a_raft.revokePeerKey("node-c"));
    const lost = a_impl.sendAppendEntries("node-c", "", .{ .term = 1, .leader_id = "node-a", .prev_log_index = 0, .prev_log_term = 0, .entries = &.{}, .leader_commit = 0 });
    try testing.expect(!lost.success);
    try testing.expectEqual(@as(u64, 0), failclosed_accepts.load(.monotonic));

    // Control: the keyed peer at the same address *is* dialled.
    _ = a_impl.sendAppendEntries("node-b", "", .{ .term = 1, .leader_id = "node-a", .prev_log_index = 0, .prev_log_term = 0, .entries = &.{}, .leader_commit = 0 });
    try testing.expectEqual(@as(u64, 1), failclosed_accepts.load(.monotonic));

    listener.stop();
    if (dialTo(allocator, io, .{ .host = "127.0.0.1", .port = 20210 }, test_dial_timeout_ms)) |wake| {
        var c = wake;
        c.deinit();
    } else |err| {
        std.log.debug("[raft test] wake connection not needed ({s})", .{@errorName(err)});
    }
    listener_thread.join();
    listener_up = false;
}

test "per-node rotation window: old and new verify until the window closes, and rotateOwnKey re-signs" {
    const allocator = testing.allocator;
    const io = testing.io;
    if (!@import("../../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    // node-b inbound, keyed for node-a.
    var b_impl: TransportImpl(1) = undefined;
    var b_raft: RaftElection = undefined;
    var b_inbound: InboundServer = undefined;
    var b_thread: std.Thread = undefined;

    var impl_up = false;
    var raft_up = false;
    var server_up = false;
    defer if (impl_up) b_impl.deinit();
    defer if (raft_up) b_raft.deinit();
    defer if (server_up) stopInbound(io, &b_inbound, &b_thread);

    b_impl.init(allocator, io, &b_raft);
    impl_up = true;
    const b_port = try startInbound(allocator, io, &b_raft, &b_impl.addresses, 20220, &b_inbound, &b_thread);
    server_up = true;

    const b_keys = [_]PeerKey{.{ .id = "node-a", .key = pernode_key_a }};
    var b_peers = [_]Peer{.{ .id = "node-a", .address = "" }};
    b_raft = try RaftElection.init(allocator, "node-b", &b_peers, .{ .own_key = pernode_key_b, .peer_keys = &b_keys }, &b_impl.transport());
    raft_up = true;

    // Baseline: the only key on record verifies; the reply is signed with
    // node-b's own key.
    const r0 = (try voteExchangeRaw(allocator, io, b_port, 7, "node-a", pernode_key_a)) orelse return error.TestUnexpectedResult;
    defer allocator.free(r0);
    _ = try verifyFrameMac(pernode_key_b, r0);

    // ① Open the window: our record for node-a rotates a1 → a2, keeping a1 as
    //    previous. Both signs verify — a verifier that only tries `current`
    //    refuses the a1 frame here (mutation-tested).
    try b_raft.rotatePeerKey("node-a", rotated_key_a);
    const r1 = (try voteExchangeRaw(allocator, io, b_port, 8, "node-a", pernode_key_a)) orelse return error.TestUnexpectedResult;
    defer allocator.free(r1);
    _ = try verifyFrameMac(pernode_key_b, r1);
    const r2 = (try voteExchangeRaw(allocator, io, b_port, 9, "node-a", rotated_key_a)) orelse return error.TestUnexpectedResult;
    defer allocator.free(r2);
    _ = try verifyFrameMac(pernode_key_b, r2);

    // ② Our own key swaps: replies are signed with the new own key from here
    //    on — verified against both candidates on the same raw reply.
    b_raft.rotateOwnKey(rotated_key_b);
    const r3 = (try voteExchangeRaw(allocator, io, b_port, 10, "node-a", rotated_key_a)) orelse return error.TestUnexpectedResult;
    defer allocator.free(r3);
    _ = try verifyFrameMac(rotated_key_b, r3);
    try testing.expectError(error.ClusterAuthFailed, verifyFrameMac(pernode_key_b, r3));

    // ③ Close the window: the old key stops verifying, the new one is
    //    untouched, and the raft still answers.
    try testing.expect(b_raft.dropPreviousPeerKey("node-a"));
    try testing.expect((try voteExchangeRaw(allocator, io, b_port, 11, "node-a", pernode_key_a)) == null);
    try testing.expectEqual(@as(u64, 10), b_raft.getTerm());
    const r4 = (try voteExchangeRaw(allocator, io, b_port, 12, "node-a", rotated_key_a)) orelse return error.TestUnexpectedResult;
    defer allocator.free(r4);
    _ = try verifyFrameMac(rotated_key_b, r4);

    // `setPeerKey` is the other window closer: an overwrite clears `previous`.
    try b_raft.rotatePeerKey("node-a", pernode_key_a); // current=a1, previous=rotated_key_a
    try b_raft.setPeerKey("node-a", pernode_key_a); // window closed
    try testing.expect((try voteExchangeRaw(allocator, io, b_port, 13, "node-a", rotated_key_a)) == null);
    const r5 = (try voteExchangeRaw(allocator, io, b_port, 14, "node-a", pernode_key_a)) orelse return error.TestUnexpectedResult;
    defer allocator.free(r5);
    _ = try verifyFrameMac(rotated_key_b, r5);
    try testing.expectEqual(@as(u64, 14), b_raft.getTerm());
}
