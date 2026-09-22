//! Real Raft transport — the layer `docs/DISTRIBUTED.md`「真选主要什么」describes.
//!
//! `RaftElection` owns the algorithm and only calls out through
//! `ElectionTransport` (two bare function pointers). This file is the
//! implementation the framework used to leave to the app:
//!
//! - **outbound** — `TransportImpl(N).send*` encodes an RPC, dials the peer and
//!   writes one frame. `sendVoteRequest` is fire-and-forget (a failed dial is a
//!   *dropped message* — Raft re-sends); `sendAppendEntries` is synchronous and
//!   reads the reply from the same connection, answering
//!   `AppendEntriesResponse{ .success = false }` when the message is lost.
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
const NetworkTransport = @import("NetworkTransport.zig");
const sockread = @import("../sockread.zig");
const ClusterAuth = @import("TlsTransport.zig").ClusterAuth;
const RaftElection = @import("RaftElection.zig").RaftElection;
const ElectionConfig = @import("RaftElection.zig").ElectionConfig;
const Peer = @import("RaftElection.zig").Peer;
const VoteRequest = @import("RaftElection.zig").VoteRequest;
const VoteResponse = @import("RaftElection.zig").VoteResponse;
const AppendEntriesRequest = @import("RaftElection.zig").AppendEntriesRequest;
const AppendEntriesResponse = @import("RaftElection.zig").AppendEntriesResponse;
const InstallSnapshotRequest = @import("RaftElection.zig").InstallSnapshotRequest;
const InstallSnapshotResponse = @import("RaftElection.zig").InstallSnapshotResponse;
const LogEntry = @import("RaftElection.zig").LogEntry;
const RaftState = @import("RaftElection.zig").RaftState;

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

/// The `ClusterAuth` this node signs with, or null when
/// `ElectionConfig.cluster_secret` is null (bare frames — the state
/// `ClusterBootstrap.start()` refuses for a multi-node cluster). A non-null
/// result must be `deinit`ed.
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
    const frame = try conn.recv(buf);
    if (frame.len < auth_mac_bytes + 1) return error.ClusterAuthFailed;
    const signed_len = frame.len - auth_mac_bytes;

    // Raw bytes, not `ClusterAuth.verify`: that one re-hexes the tag it computes
    // before comparing, which cannot match a `[32]u8` MAC on the wire.
    var expected: [auth_mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, frame[0..signed_len], &key);
    if (!ClusterAuth.timingSafeEql(&expected, frame[signed_len..])) return error.ClusterAuthFailed;
    return frame[0..signed_len];
}

/// Write one frame on an already-open connection: signed when the node has a
/// secret, bare otherwise. One place decides, so the outbound half (both RPCs),
/// the reply, and the vote-response relay cannot drift apart.
fn writeFrameAuth(secret: ?[32]u8, conn: *NetworkTransport.ClusterConnection, frame: []const u8) !void {
    if (secret) |k| return sendSigned(k, conn, frame);
    return writeFrame(conn.stream, frame);
}

/// The read side of `writeFrameAuth`: a peer with a secret signs its replies
/// too, so the reply read has to verify for the same reason the inbound one
/// does (and a decoder that ignores trailing bytes would otherwise accept a
/// frame it never authenticated).
fn readFrameAuth(secret: ?[32]u8, conn: *NetworkTransport.ClusterConnection, buf: *std.ArrayList(u8)) ![]const u8 {
    if (secret) |k| return verifiedRecv(k, conn, buf);
    return conn.recv(buf);
}

/// Dial a peer. `NetworkTransport.connect` is unreferenced in-tree and does not
/// compile against this Zig (`IpAddress.ConnectOptions` now requires `.mode`), so
/// the three lines live here; it can go back to calling that helper once fixed.
///
/// **The connect cannot be bounded here, and that is a std limitation rather
/// than a choice.** `IpAddress.ConnectOptions` advertises `.timeout`, but on the
/// `std.Io.Threaded` backend Zig 0.17 (the version CI pins) has not implemented
/// it — `netConnectIpPosix` is `if (options.timeout != .none) @panic("TODO
/// implement netConnectIpPosix with timeout")`, measured, not read. Passing one
/// would turn every dial into a process abort.
///
/// So a peer whose SYN is dropped still costs this dial the OS default. What
/// *is* bounded is the reply wait (`sockread.setRecvTimeout` in
/// `TransportImpl.sendAppendEntries`), which covers the other black-hole — a
/// peer that completes the handshake and then never answers. That one is worth
/// more than it looks: a wedged peer (long GC pause, saturated accept queue,
/// overloaded box) is far more common in production than a routing black hole,
/// and it is the case no connect-side bound could ever have covered.
///
/// Closing the remaining gap means a hand-rolled non-blocking `connect` + `poll`
/// with a deadline; `endpoint/server` plumbing is not the place for it.
fn dialTo(allocator: std.mem.Allocator, io: std.Io, ep: Endpoint) !NetworkTransport.ClusterConnection {
    const addr = try std.Io.net.IpAddress.parse(ep.host, ep.port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    return NetworkTransport.ClusterConnection.init(allocator, stream, io);
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
        vtable: VTable = .{ .sendVoteRequest = thunkVoteRequest, .sendAppendEntries = thunkAppendEntries },

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

        /// Dial + write once. A failure here is a lost message (Raft re-sends),
        /// so it is worth a debug line and nothing more.
        pub fn sendFrame(self: *Self, ep: Endpoint, frame: []const u8) void {
            var conn = dialTo(self.allocator, self.io, ep) catch |err| {
                log.debug("[raft] connect {s}:{d} failed, message dropped ({})", .{ ep.host, ep.port, err });
                return;
            };
            defer conn.deinit();
            // The write half of the same bound: a peer that accepts and then
            // stops reading would otherwise block the writing thread on a full
            // send buffer, inside the same spin lock.
            sockread.setSendTimeout(conn.stream, self.rpcTimeoutMs());
            writeFrameAuth(self.raft.config.cluster_secret, &conn, frame) catch |err| {
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
            var frame = std.ArrayList(u8).empty;
            defer frame.deinit(self.allocator);
            encodeVoteRequest(&frame, self.allocator, req) catch |err| {
                log.debug("[raft] encoding the vote request failed ({})", .{err});
                return;
            };
            self.sendFrame(ep, frame.items);
        }

        /// Synchronous: the follower answers on the same connection. Every
        /// failure mode (no address, dial, write, read, decode) is the same
        /// "lost message" answer — never a panic.
        pub fn sendAppendEntries(self: *Self, peer_id: ?[]const u8, address: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
            const lost = AppendEntriesResponse{ .term = 0, .success = false, .match_index = 0 };
            const ep = self.resolve(peer_id, address) orelse return lost;

            var frame = std.ArrayList(u8).empty;
            defer frame.deinit(self.allocator);
            encodeAppendEntries(&frame, self.allocator, req) catch |err| {
                log.debug("[raft] encoding AppendEntries failed ({})", .{err});
                return lost;
            };

            var conn = dialTo(self.allocator, self.io, ep) catch return lost;
            defer conn.deinit();
            sockread.setSendTimeout(conn.stream, self.rpcTimeoutMs());
            writeFrameAuth(self.raft.config.cluster_secret, &conn, frame.items) catch return lost;

            // Bound the wait for the reply as well as the dial: a peer that
            // accepts the connection and never answers is the failure this is
            // here for. It matters more than the connect bound, because this read
            // is the one that happens on every heartbeat from every leader — a
            // half-open peer would otherwise stop the cluster's ticker dead.
            sockread.setRecvTimeout(conn.stream, self.rpcTimeoutMs());

            var reply = std.ArrayList(u8).empty;
            defer reply.deinit(self.allocator);
            const bytes = readFrameAuth(self.raft.config.cluster_secret, &conn, &reply) catch |err| {
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
/// **Nothing here takes a lock, and that is deliberate.** The raft-state window
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
/// The two ends of the function stay outside any lock: a `recv`, the reply, and
/// the relay dial are IO, and a `tick()` that waits on a peer's connect timeout
/// would be a livelock, not a fix. The steps the lock used to wrap but no longer
/// needs to — `decode*` / `encode*` — touch only allocator-local buffers and
/// `raft.local_id`, which is written once in `init` and freed in `deinit`.
///
/// **This paragraph states a principle the outbound half does not yet follow:**
/// `RaftElection.tick`'s replication round calls `sendAppendEntries` below
/// *inside* `RaftLock`. The reply wait there is bounded now
/// (`sockread.setRecvTimeout`, `ElectionConfig.rpc_timeout_ms`), but the dial is
/// not, and a bounded IO under a spin lock is still IO under a spin lock.
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
    // mode this path should have.
    const secret = raft.config.cluster_secret;

    var in = std.ArrayList(u8).empty;
    defer in.deinit(conn.allocator);
    // With a secret configured the frame is verified (and the MAC stripped)
    // *before* any decoder sees it; a bad tag is the same shape of failure as an
    // unreadable frame — drop the connection and keep serving.
    const frame = blk: {
        if (secret) |k| break :blk verifiedRecv(k, conn, &in) catch |err| {
            log.debug("[raft] inbound frame not authenticated ({})", .{err});
            return;
        };
        break :blk conn.recv(&in) catch |err| {
            log.debug("[raft] inbound frame not readable ({})", .{err});
            return;
        };
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
        // Nothing in `RaftElection` consumes these yet (the leader reads its
        // AppendEntries reply on the synchronous path).
        .append_entries_response, .install_snapshot_response => return,
    }

    writeFrameAuth(secret, conn, out.items) catch |err| {
        log.debug("[raft] replying on the inbound connection failed ({})", .{err});
    };

    if (relay_candidate) |candidate| {
        const ep = if (addresses) |book| book.lookup(candidate) else null;
        if (ep) |endpoint| {
            var conn_out = dialTo(conn.allocator, conn.io, endpoint) catch |err| {
                log.debug("[raft] relaying the vote response to {s}:{d} failed ({})", .{ endpoint.host, endpoint.port, err });
                return;
            };
            defer conn_out.deinit();
            // The candidate verifies its inbound frames, so the relay has to be
            // signed too — an unsigned relay is a vote the candidate drops.
            writeFrameAuth(secret, &conn_out, out.items) catch |err| {
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
const Time = @import("../Time.zig");

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
    if (dialTo(testing.allocator, io, .{ .host = "127.0.0.1", .port = inbound.server.port })) |conn| {
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

    const b_endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{b_port});
    defer allocator.free(b_endpoint);
    const c_endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{c_port});
    defer allocator.free(c_endpoint);
    const a_endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{a_port});
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
    const b_endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{b_port});
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
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port });
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
    const b_endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{b_port});
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

    const endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server.port});
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
    if (dialTo(allocator, io, .{ .host = "127.0.0.1", .port = server.port })) |wake| {
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
    var peer_a = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port });
    defer peer_a.deinit();
    sockread.setRecvTimeout(peer_a.stream, stalled_peer_patience_ms);
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, 64, .big);
    try sockread.writeFull(peer_a.stream, &prefix);

    // Peer B: a complete frame whose tag is not a Raft message, i.e. one
    // `handleConnection` answers by closing without a reply.
    var peer_b = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port });
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
    var slow_a = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port });
    defer slow_a.deinit();
    var slow_b = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port });
    defer slow_b.deinit();
    for ([_]*NetworkTransport.ClusterConnection{ &slow_a, &slow_b }) |stalled| {
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, 64, .big);
        try sockread.writeFull(stalled.stream, &prefix);
    }

    // The third peer sends a complete frame and has to be answered while both of
    // the above are still inside their handler.
    var fast = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = port });
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
    const b_endpoint = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{b_port});
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
        var conn = try dialTo(allocator, io, .{ .host = "127.0.0.1", .port = b_port });
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
