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
const RaftElection = @import("RaftElection.zig").RaftElection;
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
};

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
    const entries = try allocator.alloc(LogEntry, try cur.u16v());
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

/// Dial a peer. `NetworkTransport.connect` is unreferenced in-tree and does not
/// compile against this Zig (`IpAddress.ConnectOptions` now requires `.mode`), so
/// the three lines live here; it can go back to calling that helper once fixed.
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
    _ = slot; // Distinct statics per instantiation; the value itself is unused.
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        /// The local node: responses arriving inbound are fed into it.
        raft: *RaftElection,
        addresses: AddressBook,
        vtable: VTable = .{ .sendVoteRequest = thunkVoteRequest, .sendAppendEntries = thunkAppendEntries },

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
            writeFrame(conn.stream, frame) catch |err| {
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
            writeFrame(conn.stream, frame.items) catch return lost;

            var reply = std.ArrayList(u8).empty;
            defer reply.deinit(self.allocator);
            const bytes = conn.recv(&reply) catch return lost;
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
pub fn handleConnection(raft: *RaftElection, addresses: ?*const AddressBook, conn: *NetworkTransport.ClusterConnection) void {
    var in = std.ArrayList(u8).empty;
    defer in.deinit(conn.allocator);
    const frame = conn.recv(&in) catch |err| {
        log.debug("[raft] inbound frame not readable ({})", .{err});
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(conn.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // The reply is built with the arena too: it is written (same connection and
    // relay) before the arena goes away, so nothing needs an individual free.
    var out = std.ArrayList(u8).empty;

    // Only a granted vote needs the extra hop to the candidate.
    var relay_candidate: ?[]const u8 = null;

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

    writeFrame(conn.stream, out.items) catch |err| {
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
            writeFrame(conn_out.stream, out.items) catch |err| {
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

/// Accept loop for inbound RPCs. `ClusterServer.start` takes a bare handler (no
/// context), so each `InboundServer` marks its raft and address book as the ones
/// for the thread it runs on — which is what lets several nodes share a process.
pub const InboundServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    raft: *RaftElection,
    addresses: ?*const AddressBook,
    server: NetworkTransport.ClusterServer,

    threadlocal var current: ?*InboundServer = null;

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
        current = self;
        defer current = null;
        self.server.start(&onConnection) catch |err| {
            log.debug("[raft] inbound server on port {d} exited ({})", .{ self.server.port, err });
        };
    }

    /// Ask `run` to return. The accept is already blocked, so a wake-up
    /// connection is needed (see the tests).
    pub fn stop(self: *InboundServer) void {
        self.server.stop();
    }

    fn onConnection(conn: NetworkTransport.ClusterConnection) void {
        var owned = conn;
        defer owned.deinit();
        const self = current orelse {
            log.debug("[raft] inbound connection on an unbound server thread", .{});
            return;
        };
        handleConnection(self.raft, self.addresses, &owned);
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const Time = @import("../Time.zig");

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

    b_raft = try RaftElection.init(allocator, "node-b", &.{}, .{}, &b_impl.transport());
    rafts_up = 1;
    c_raft = try RaftElection.init(allocator, "node-c", &.{}, .{}, &c_impl.transport());
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

    // Two of three nodes voted for node-a over the wire → quorum.
    try testing.expect(waitForTerm(io, &b_raft, 1, 2000));
    try testing.expect(waitForTerm(io, &c_raft, 1, 2000));
    try testing.expectEqualStrings("node-a", b_raft.voted_for.?);
    try testing.expectEqualStrings("node-a", c_raft.voted_for.?);
    try testing.expect(a_raft.hasQuorum(2));
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

    b_raft = try RaftElection.init(allocator, "node-b", &.{}, .{}, &b_impl.transport());
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

    b_raft = try RaftElection.init(allocator, "node-b", &.{}, .{}, &b_impl.transport());
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
