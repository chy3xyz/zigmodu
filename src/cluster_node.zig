//! `cluster-node` — a single-node cluster process: the multi-process harness for
//! the cluster stack (item B-11 of `docs/dev/v1.0-readiness-v0.35.md`).
//!
//! ## Why this file exists
//!
//! `src/soak_cluster.zig` proves the cluster stack under sustained load, but its
//! three nodes live in ONE process: the wire between them is real TCP, yet the
//! binary on both ends is always the same build. Two things were never exercised
//! as independent binaries:
//!
//!   1. **same-version, cross-process** — three `cluster-node` processes
//!      electing one leader over real TCP and gossiping over the authenticated
//!      event bus; and
//!   2. **mixed-version** — a v0.32.0 node (bare frames, no bus handshake)
//!      against master nodes (per-frame HMAC + fail-closed bus handshake). The
//!      design verdict for that pair is a *refused* handshake — the wire format
//!      cuts over hard, on purpose. What B-11 needed proven is that the refusal
//!      is clean, bounded and observable: no panic, no hang, a greppable log
//!      line, and the same-version nodes' own traffic unaffected by the refused
//!      peer.
//!
//! `scripts/ci-mixed-version.sh` drives both runs; this file is the node it
//! launches. The source is deliberately **cross-compilable against v0.32.0**:
//! every post-v0.32.0 API it touches (`BootstrapConfig.cluster_secret`, the bus
//! credential/handshake surface, `snapshotNodes`, `inbound_idle_timeout_ms`) is
//! reached through a comptime capability probe (`@hasField` / `@hasDecl`), and
//! the outbound transport signs frames only when the build it is compiled
//! against has the cluster-auth wire at all — so the same file, copied into a
//! v0.32.0 tree, produces a node that speaks exactly the v0.32.0 wire (bare
//! frames, no handshake). The script does exactly that copy; see its header.
//!
//! ## What it logs (one greppable line per event, stderr, `CN ` prefix)
//!
//!   CN BOOT id=… raft=… bus=… auth=on|off|unsupported peers=…
//!   CN LISTEN raft=… bus=…
//!   CN RAFT_STATE node=… state=follower|candidate|leader term=… leader=…|-   (on change)
//!   CN LEADER_ELECTED id=… term=…                                            (on change, once known)
//!   CN RAFT_LOG len=…                                                        (on change)
//!   CN VIEW members=…                                                        (on change)
//!   CN MESH peer=… state=connected|down|dialed                               (on change)
//!   CN PEER_REPLY_REFUSED peer=…   — a peer's reply failed MAC verification
//!                                    (harness-side observation of the wire rule)
//!   CN SHUTDOWN begin / CN SHUTDOWN clean
//!
//! The framework's own refusal lines ride the same stream — this binary sets the
//! root log level to `.debug` so they are visible: `[raft] inbound frame not
//! authenticated` (RaftTransport.verifiedRecv), `[DEB] dropping connection: …`
//! (the bus's inbound handshake) and `[DistributedEventBus] Peer … refused the
//! handshake` (its outbound half).
//!
//! ## Lifecycle
//!
//! argv → `ClusterBootstrap.init/start` → bus credentials (when the build has
//! them) → `bus.start` → mesh thread (keeps the bus dialed to every `--peer-bus`)
//! → driver loop on the main thread (`cluster.tick()` every `--tick-ms`, state
//! sampling, leader appends every `--append-ms`). SIGTERM/SIGINT → the loop
//! exits, the mesh thread joins, `cluster.deinit()`, `CN SHUTDOWN clean`,
//! exit 0. Boot failures print `CN BOOT_FAIL` and exit 1.

const std = @import("std");
const builtin = @import("builtin");
const zigmodu = @import("zigmodu");

// The framework's refusal lines are `debug`-level by design (a refused frame is
// routine, not an error); this binary exists to make them visible.
pub const std_options: std.Options = .{ .log_level = .debug };

const Time = zigmodu.time;
const RaftWire = zigmodu.RaftTransport;
const DistributedEventBus = zigmodu.DistributedEventBus;
const ClusterBootstrap = zigmodu.ClusterBootstrap;
// `BootstrapConfig` is a file-level decl of ClusterBootstrap.zig, not a member
// of the struct and not re-exported from the root — on either version. Deriving
// it from `init`'s parameter reaches it through the public surface alone.
const BootstrapConfig = @typeInfo(@TypeOf(ClusterBootstrap.init)).@"fn".param_types[2].?;

// ── cross-version capability probes ─────────────────────────────────────────
//
// The one source file compiles against master *and* v0.32.0; every API that
// only exists on master is hidden behind one of these comptime constants.
// `wire_auth` in particular is what makes the copied-into-v0.32.0 binary speak
// the *old* wire: no `cluster_secret` field exists there, so no frame is signed
// even if `--secret-hex` was passed (the arg is parsed and reported as
// `auth=unsupported`, never silently honored).

const wire_auth = @hasField(BootstrapConfig, "cluster_secret");
const bus_credentials = @hasDecl(DistributedEventBus, "setOwnKey");
const bus_snapshot = @hasDecl(DistributedEventBus, "snapshotNodes");
const bus_idle_knob = @hasField(DistributedEventBus, "inbound_idle_timeout_ms");

// ── argv / config (pure parsing — unit-tested below) ─────────────────────────

pub const max_peers = 8;

pub const ParseError = error{
    UnknownFlag,
    MissingValue,
    BadPort,
    BadHexKey,
    BadPeerSpec,
    MissingRequired,
    BusKeyWithoutSecret,
    TooManyPeers,
    BadNumber,
};

pub const PeerSpec = struct {
    id: []const u8,
    host: []const u8,
    port: u16,
};

/// Parsed argv. Slices borrow the argv storage, which outlives `main`.
pub const Config = struct {
    node_id: []const u8 = "",
    raft_port: u16 = 0,
    bus_port: u16 = 0,
    raft_peers: [max_peers][]const u8 = undefined, // raw "id@host:port", for BootstrapConfig.peers
    raft_specs: [max_peers]PeerSpec = undefined, // the same peers, parsed, for the transport table
    bus_specs: [max_peers]PeerSpec = undefined, // --peer-bus entries, for connectToNode
    raft_count: usize = 0,
    bus_count: usize = 0,
    cluster_size: usize = 0, // 0 → derived as raft_count + 1
    secret: ?[32]u8 = null,
    bus_key: ?[32]u8 = null,
    tick_ms: u64 = 25,
    mesh_ms: u64 = 2000,
    bus_idle_ms: u32 = 0, // 0 → keep the bus default
    append_ms: u64 = 500,

    pub fn raftPeerStrings(self: *const Config) []const []const u8 {
        return self.raft_peers[0..self.raft_count];
    }
    pub fn raftSpecs(self: *const Config) []const PeerSpec {
        return self.raft_specs[0..self.raft_count];
    }
    pub fn busSpecs(self: *const Config) []const PeerSpec {
        return self.bus_specs[0..self.bus_count];
    }
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// `"<64 hex chars>"` → the 32-byte key. Hand-rolled rather than
/// `std.fmt.hexToBytes` so the parse error is ours (`BadHexKey`, not a std
/// panic path) — the script greps `CN BOOT_FAIL` for these.
pub fn parseKeyHex(s: []const u8) ParseError![32]u8 {
    if (s.len != 64) return error.BadHexKey;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| {
        const hi = hexVal(s[i * 2]) orelse return error.BadHexKey;
        const lo = hexVal(s[i * 2 + 1]) orelse return error.BadHexKey;
        b.* = (hi << 4) | lo;
    }
    return out;
}

/// `"<id>@<host>:<port>"` — the facade's peer grammar, parsed for the
/// transport/mesh tables (`RaftWire.parseEndpoint` judges the `host:port` half,
/// so an id-less or port-less spec is `BadPeerSpec` here, not a boot-time
/// surprise inside raft).
pub fn parsePeerSpec(spec: []const u8) ParseError!PeerSpec {
    const at = std.mem.indexOfScalar(u8, spec, '@') orelse return error.BadPeerSpec;
    if (at == 0) return error.BadPeerSpec;
    const ep = RaftWire.parseEndpoint(spec[at + 1 ..]) orelse return error.BadPeerSpec;
    return .{ .id = spec[0..at], .host = ep.host, .port = ep.port };
}

fn parsePort(s: []const u8) ParseError!u16 {
    const p = std.fmt.parseInt(u16, s, 10) catch return error.BadPort;
    if (p == 0) return error.BadPort;
    return p;
}

fn parseU64(s: []const u8) ParseError!u64 {
    return std.fmt.parseInt(u64, s, 10) catch error.BadNumber;
}

/// Parse argv (excluding argv[0]) into a Config. Every failure is a
/// `ParseError`; `main` turns it into a usage line + exit 1.
pub fn parseArgs(args: []const []const u8) ParseError!Config {
    var cfg = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = struct {
            fn take(argv: []const []const u8, idx: *usize) ParseError![]const u8 {
                idx.* += 1;
                if (idx.* >= argv.len) return error.MissingValue;
                return argv[idx.*];
            }
        }.take;
        if (std.mem.eql(u8, a, "--id")) {
            cfg.node_id = try value(args, &i);
        } else if (std.mem.eql(u8, a, "--raft-port")) {
            cfg.raft_port = try parsePort(try value(args, &i));
        } else if (std.mem.eql(u8, a, "--bus-port")) {
            cfg.bus_port = try parsePort(try value(args, &i));
        } else if (std.mem.eql(u8, a, "--peer-raft")) {
            const raw = try value(args, &i);
            const spec = try parsePeerSpec(raw);
            if (cfg.raft_count >= max_peers) return error.TooManyPeers;
            cfg.raft_peers[cfg.raft_count] = raw;
            cfg.raft_specs[cfg.raft_count] = spec;
            cfg.raft_count += 1;
        } else if (std.mem.eql(u8, a, "--peer-bus")) {
            const spec = try parsePeerSpec(try value(args, &i));
            if (cfg.bus_count >= max_peers) return error.TooManyPeers;
            cfg.bus_specs[cfg.bus_count] = spec;
            cfg.bus_count += 1;
        } else if (std.mem.eql(u8, a, "--cluster-size")) {
            const n = try parseU64(try value(args, &i));
            if (n == 0) return error.BadNumber;
            cfg.cluster_size = @intCast(n);
        } else if (std.mem.eql(u8, a, "--secret-hex")) {
            cfg.secret = try parseKeyHex(try value(args, &i));
        } else if (std.mem.eql(u8, a, "--bus-key-hex")) {
            cfg.bus_key = try parseKeyHex(try value(args, &i));
        } else if (std.mem.eql(u8, a, "--tick-ms")) {
            cfg.tick_ms = @max(try parseU64(try value(args, &i)), 1);
        } else if (std.mem.eql(u8, a, "--mesh-ms")) {
            cfg.mesh_ms = @max(try parseU64(try value(args, &i)), 50);
        } else if (std.mem.eql(u8, a, "--bus-idle-ms")) {
            cfg.bus_idle_ms = @intCast(try parseU64(try value(args, &i)));
        } else if (std.mem.eql(u8, a, "--append-ms")) {
            cfg.append_ms = @max(try parseU64(try value(args, &i)), 50);
        } else {
            return error.UnknownFlag;
        }
    }
    if (cfg.node_id.len == 0) return error.MissingRequired;
    if (cfg.raft_port == 0 or cfg.bus_port == 0) return error.MissingRequired;
    if (cfg.cluster_size == 0) cfg.cluster_size = cfg.raft_count + 1;
    // A cluster secret makes the bus fail-closed (authEnabled): with no bus key
    // at all, every bus dial then dies with PeerKeyMissing — a config bug the
    // script would otherwise have to read out of a warn line.
    if (cfg.bus_key == null and cfg.secret != null) return error.BusKeyWithoutSecret;
    return cfg;
}

// ── greppable lifecycle lines ────────────────────────────────────────────────

fn note(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("CN " ++ fmt ++ "\n", args);
}

fn cnSleep(io: std.Io, ms: u64) void {
    // The only failure of this sleep is io cancellation, which this process
    // never requests; a SIGTERM lands as an EINTR-style early return, which is
    // exactly what the shutdown loop wants anyway.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .real) catch |err| {
        note("SLEEP_INTERRUPTED err={s}", .{@errorName(err)});
    };
}

// ── the outbound half of raft, harness-flavoured ─────────────────────────────
//
// Byte-for-byte the framing `RaftTransport` documents: `[4-byte BE len][frame]`
// bare, or `[4-byte BE len][frame][HMAC-SHA256(secret, frame)]` when this build
// has the cluster-auth wire *and* a secret was passed. Reimplemented here for
// the same reason `soak_cluster.zig` reimplements it: the module's send/verify
// helpers are file-private. The one difference from soak: the secret is a
// runtime value, so one source serves both wire formats.
//
// One node per process, so the transport is a single file-scope instance — no
// per-slot generics (the soak needs those because it hosts three nodes in one
// process).

const mac_bytes = 32;

const VoteRequest = @typeInfo(@TypeOf(RaftWire.encodeVoteRequest)).@"fn".param_types[2].?;
const AppendEntriesRequest = @typeInfo(@TypeOf(RaftWire.encodeAppendEntries)).@"fn".param_types[2].?;
const AppendEntriesResponse = @typeInfo(@typeInfo(@TypeOf(RaftWire.decodeAppendEntriesResponse)).@"fn".return_type.?).error_union.payload;

fn sendAllNoSig(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    // `send(MSG_NOSIGNAL)`, not `writev`: answering a peer that already closed
    // its socket would otherwise raise SIGPIPE — the same reasoning
    // `RaftTransport.sendAll` documents.
    _ = io;
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

fn readFullSock(stream: std.Io.net.Stream, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.posix.system.read(stream.socket.handle, buf[got..].ptr, buf.len - got);
        switch (std.posix.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        const nn: usize = @intCast(n);
        if (nn == 0) return error.Eof;
        got += nn;
    }
}

fn setSockTimeoutMs(stream: std.posix.socket_t, opt: u32, timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    const rc = std.posix.system.setsockopt(stream, std.posix.SOL.SOCKET, opt, &tv, @sizeOf(std.posix.timeval));
    // macOS answers EINVAL for SO_RCVTIMEO on a socket whose peer end has
    // already closed — the next read returns EOF anyway.
    if (rc != 0) note("SOCKOPT_FAILED opt={d} errno={s}", .{ opt, @tagName(std.posix.errno(rc)) });
}

fn writeFrameAuth(io: std.Io, stream: std.Io.net.Stream, secret: ?[32]u8, frame: []const u8) !void {
    var header: [4]u8 = undefined;
    if (secret) |key| {
        var mac: [mac_bytes]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, frame, &key);
        std.mem.writeInt(u32, &header, @intCast(frame.len + mac_bytes), .big);
        try sendAllNoSig(io, stream, &header);
        try sendAllNoSig(io, stream, frame);
        try sendAllNoSig(io, stream, &mac);
    } else {
        std.mem.writeInt(u32, &header, @intCast(frame.len), .big);
        try sendAllNoSig(io, stream, &header);
        try sendAllNoSig(io, stream, frame);
    }
}

fn recvFrameAlloc(allocator: std.mem.Allocator, stream: std.Io.net.Stream) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try readFullSock(stream, &len_buf);
    const body_len = std.mem.readInt(u32, &len_buf, .big);
    if (body_len == 0 or body_len > 1024 * 1024) return error.FrameTooLarge;
    const buf = try allocator.alloc(u8, body_len);
    errdefer allocator.free(buf);
    try readFullSock(stream, buf);
    return buf;
}

/// Strip and verify the trailing MAC, constant-time. `null` = refused.
fn verifyFrameMac(secret: [32]u8, frame: []const u8) ?[]const u8 {
    if (frame.len < mac_bytes + 1) return null;
    const signed_len = frame.len - mac_bytes;
    var expected: [mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, frame[0..signed_len], &secret);
    if (!std.crypto.timing_safe.eql([mac_bytes]u8, expected, frame[signed_len..][0..mac_bytes].*)) return null;
    return frame[0..signed_len];
}

const HarnessTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secret: ?[32]u8, // signing is active only when this build has the auth wire
    rpc_timeout_ms: u32,
    peers: []const PeerSpec,
    node_id: []const u8,

    vtable: VTable = .{
        .sendVoteRequest = thunkVoteRequest,
        .sendAppendEntries = thunkSendAppendEntries,
    },

    const VTable = struct {
        sendVoteRequest: *const fn (?[]const u8, []const u8, VoteRequest) void,
        sendAppendEntries: *const fn (?[]const u8, []const u8, AppendEntriesRequest) AppendEntriesResponse,
    };

    var bound: ?*HarnessTransport = null;

    fn transport(self: *HarnessTransport) zigmodu.RaftElection.ElectionTransport {
        return @ptrCast(&self.vtable);
    }

    fn resolve(self: *HarnessTransport, peer_id: ?[]const u8, address: []const u8) ?RaftWire.Endpoint {
        if (peer_id) |id| {
            for (self.peers) |p| {
                // Two peer-id shapes reach this table, one per version:
                // master's raft stores the declared `id` ("mv-b"); v0.32.0's
                // PeerDiscovery pre-dates the `id@host:port` grammar and stores
                // the whole `id@host` prefix as the peer id ("mv-b@127.0.0.1",
                // port split off by its host:port parse). Match both.
                if (std.mem.eql(u8, p.id, id)) return .{ .host = p.host, .port = p.port };
                if (id.len == p.id.len + 1 + p.host.len and
                    std.mem.startsWith(u8, id, p.id) and id[p.id.len] == '@' and
                    std.mem.endsWith(u8, id, p.host))
                {
                    return .{ .host = p.host, .port = p.port };
                }
            }
        }
        if (RaftWire.parseEndpoint(address)) |ep| return ep;
        if (peer_id) |id| {
            if (RaftWire.parseEndpoint(id)) |ep| return ep;
        }
        note("TRANSPORT_UNRESOLVED peer={s} address={s}", .{ peer_id orelse "?", address });
        return null;
    }

    fn sendVoteRequest(self: *HarnessTransport, peer_id: ?[]const u8, address: []const u8, req: VoteRequest) void {
        const ep = self.resolve(peer_id, address) orelse return;
        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(self.allocator);
        RaftWire.encodeVoteRequest(&frame, self.allocator, req) catch |err| {
            note("ENCODE_FAIL what=vote_request err={s}", .{@errorName(err)});
            return;
        };
        const addr = std.Io.net.IpAddress.parse(ep.host, ep.port) catch return;
        const stream = addr.connect(self.io, .{ .mode = .stream }) catch {
            // A peer that is down or refused is a lost vote, re-tried at the
            // next election timeout — raft's own failure model.
            return;
        };
        defer stream.close(self.io);
        setSockTimeoutMs(stream.socket.handle, std.posix.SO.SNDTIMEO, self.rpc_timeout_ms);
        // Fire-and-forget: the voter answers on its own initiative (the inbound
        // half relays a granted ballot), so the write is all there is.
        writeFrameAuth(self.io, stream, self.secret, frame.items) catch |err| {
            note("WIRE_WRITE_FAIL what=vote_request peer={s}:{d} err={s}", .{ ep.host, ep.port, @errorName(err) });
        };
    }

    fn sendAppendEntries(self: *HarnessTransport, peer_id: ?[]const u8, address: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
        const lost: AppendEntriesResponse = .{ .term = 0, .success = false, .match_index = 0 };
        const ep = self.resolve(peer_id, address) orelse return lost;

        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(self.allocator);
        RaftWire.encodeAppendEntries(&frame, self.allocator, req) catch return lost;

        const addr = std.Io.net.IpAddress.parse(ep.host, ep.port) catch return lost;
        const stream = addr.connect(self.io, .{ .mode = .stream }) catch return lost;
        defer stream.close(self.io);
        setSockTimeoutMs(stream.socket.handle, std.posix.SO.SNDTIMEO, self.rpc_timeout_ms);
        setSockTimeoutMs(stream.socket.handle, std.posix.SO.RCVTIMEO, self.rpc_timeout_ms);
        writeFrameAuth(self.io, stream, self.secret, frame.items) catch return lost;

        const reply = recvFrameAlloc(self.allocator, stream) catch return lost;
        defer self.allocator.free(reply);
        const body = if (self.secret) |key| verifyFrameMac(key, reply) orelse {
            // The mixed-version signal this harness exists to make visible: the
            // peer answered, but its frame is not one this build can accept
            // (a v0.32.0 peer signs nothing). The raft treats it as a lost
            // message — bounded, retried, and now *counted in the open*.
            note("PEER_REPLY_REFUSED peer={s}", .{peer_id orelse ep.host});
            return lost;
        } else reply;
        return RaftWire.decodeAppendEntriesResponse(body) catch lost;
    }

    fn thunkVoteRequest(peer_id: ?[]const u8, address: []const u8, req: VoteRequest) void {
        const self = bound orelse return;
        self.sendVoteRequest(peer_id, address, req);
    }

    fn thunkSendAppendEntries(peer_id: ?[]const u8, address: []const u8, req: AppendEntriesRequest) AppendEntriesResponse {
        const self = bound orelse return .{ .term = 0, .success = false, .match_index = 0 };
        return self.sendAppendEntries(peer_id, address, req);
    }
};

var the_transport: HarnessTransport = undefined;

// ── shutdown signalling ──────────────────────────────────────────────────────

var shutdown_requested = std.atomic.Value(bool).init(false);

fn onShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

// ── bus mesh maintenance (own thread: dials can block for a handshake) ───────

const MeshCtx = struct {
    bus: *DistributedEventBus,
    peers: []const PeerSpec,
    mesh_ms: u64,
    allocator: std.mem.Allocator,
    io: std.Io,
};

var mesh_ctx: MeshCtx = undefined;

fn meshMain(ctx: *MeshCtx) void {
    var connected: [max_peers]bool = @splat(false);
    var ever_dialed: [max_peers]bool = @splat(false);
    while (!shutdown_requested.load(.acquire)) {
        meshPass(ctx, &connected, &ever_dialed);
        cnSleep(ctx.io, ctx.mesh_ms);
    }
}

fn dialBusPeer(ctx: *MeshCtx, p: PeerSpec) void {
    const addr = std.Io.net.IpAddress.parse(p.host, p.port) catch {
        note("MESH peer={s} dial_error=BadAddress", .{p.id});
        return;
    };
    // The dial + handshake can block for the bus's idle timeout (a peer that
    // accepts TCP but never answers the challenge — exactly the old-binary
    // case); that is why this runs on its own thread, never on the tick loop.
    ctx.bus.connectToNode(p.id, addr) catch |err| {
        note("MESH peer={s} dial_error={s}", .{ p.id, @errorName(err) });
    };
}

fn meshPass(ctx: *MeshCtx, connected: *[max_peers]bool, ever_dialed: *[max_peers]bool) void {
    if (bus_snapshot) {
        // Master path: reconnect only peers that are not verifiably connected
        // (a failed dial leaves a registry entry with `socket == null`, which
        // `connectToNode` alone will not retry — hence the disconnect first,
        // the same shape soak_cluster's `reconnectMissingMeshPeers` uses).
        var snap = ctx.bus.snapshotNodes(ctx.allocator) catch |err| {
            note("MESH snapshot_error err={s}", .{@errorName(err)});
            return;
        };
        defer snap.deinit();
        for (ctx.peers, 0..) |p, i| {
            var up = false;
            for (snap.peers) |peer| {
                if (std.mem.eql(u8, peer.id, p.id) and peer.connected) up = true;
            }
            if (up != connected[i]) {
                connected[i] = up;
                note("MESH peer={s} state={s}", .{ p.id, if (up) "connected" else "down" });
            }
            if (up) continue;
            ctx.bus.disconnectNode(p.id);
            dialBusPeer(ctx, p);
        }
    } else {
        // v0.32.0 path: no snapshot API and no handshake, so "connected" is not
        // observable — the bus registers a peer at TCP-connect time and the far
        // end (a master node) closes it once the first frame fails the
        // handshake it never sends. Re-dial on a fixed cadence so the refusal
        // stays exercised; `disconnectNode` first because the stale entry would
        // otherwise dedup the dial away.
        for (ctx.peers, 0..) |p, i| {
            ctx.bus.disconnectNode(p.id);
            dialBusPeer(ctx, p);
            if (!ever_dialed[i]) {
                ever_dialed[i] = true;
                note("MESH peer={s} state=dialed", .{p.id});
            }
        }
    }
}

// ── bootstrap config (the comptime version bridge) ───────────────────────────

fn buildBootstrapConfig(cfg: *const Config) BootstrapConfig {
    if (wire_auth) {
        // Master: a multi-node cluster with a real transport must either carry
        // the cluster secret or say out loud that it runs unauthenticated
        // (ClusterBootstrap.start()'s ClusterAuthRequired gate).
        var bcfg = BootstrapConfig{
            .node_id = cfg.node_id,
            .port = cfg.raft_port,
            .peers = cfg.raftPeerStrings(),
            .raft_cluster_size = cfg.cluster_size,
            .transport = the_transport.transport(),
        };
        if (cfg.secret) |s| {
            bcfg.cluster_secret = s;
        } else {
            bcfg.allow_unauthenticated_cluster = true;
        }
        return bcfg;
    } else {
        // v0.32.0: no cluster_secret / allow_unauthenticated_cluster fields —
        // the wire is bare, unconditionally.
        return BootstrapConfig{
            .node_id = cfg.node_id,
            .port = cfg.raft_port,
            .peers = cfg.raftPeerStrings(),
            .raft_cluster_size = cfg.cluster_size,
            .transport = the_transport.transport(),
        };
    }
}

// ── the driver loop (main thread) ────────────────────────────────────────────

fn driverLoop(io: std.Io, cluster: *ClusterBootstrap, cfg: *const Config) void {
    const raft = cluster.getRaft().?;
    var last_state: u8 = 0xff; // impossible enum tag: forces the first line
    var last_term: u64 = 0;
    var last_log_len: usize = 0;
    var last_members: usize = 0;
    var last_leader_len: usize = 0;
    var last_leader: [128]u8 = undefined;
    var last_append_ms: i64 = 0;
    var appends: u64 = 0;
    var tick_errors: u64 = 0;

    while (!shutdown_requested.load(.acquire)) {
        cluster.tick() catch |err| {
            tick_errors += 1;
            if (tick_errors == 1 or tick_errors % 100 == 0) {
                note("TICK_ERROR err={s} count={d}", .{ @errorName(err), tick_errors });
            }
        };

        // One serialized sample of the raft: `getState`/`getTerm`/`getLeader`
        // each take this same lock without composing (the lock is not
        // re-entrant), so the sample reads the fields directly under one
        // acquisition — the "hold raft.lock around the whole sequence" contract
        // ClusterBootstrap.getRaft documents. The leader id is copied out
        // before the lock is released (the borrow dies with the next RPC).
        raft.lock.acquire();
        const state = raft.state;
        const term = raft.current_term;
        const log_len = raft.log.items.len;
        var leader_buf: [128]u8 = undefined;
        var leader_len: usize = 0;
        if (raft.leader_id) |l| {
            leader_len = @min(l.len, leader_buf.len);
            @memcpy(leader_buf[0..leader_len], l[0..leader_len]);
        }
        raft.lock.release();

        const state_tag: u8 = @backingInt(state);
        if (state_tag != last_state or term != last_term or
            leader_len != last_leader_len or
            !std.mem.eql(u8, leader_buf[0..leader_len], last_leader[0..last_leader_len]))
        {
            note("RAFT_STATE node={s} state={s} term={d} leader={s}", .{
                cfg.node_id,
                @tagName(state),
                term,
                if (leader_len > 0) leader_buf[0..leader_len] else "-",
            });
            if (leader_len > 0 and (leader_len != last_leader_len or
                !std.mem.eql(u8, leader_buf[0..leader_len], last_leader[0..last_leader_len])))
            {
                note("LEADER_ELECTED id={s} term={d}", .{ leader_buf[0..leader_len], term });
            }
            last_state = state_tag;
            last_term = term;
            @memcpy(last_leader[0..leader_len], leader_buf[0..leader_len]);
            last_leader_len = leader_len;
        }
        if (log_len != last_log_len) {
            last_log_len = log_len;
            note("RAFT_LOG len={d}", .{log_len});
        }
        const members = cluster.getView().stats().members;
        if (members != last_members) {
            last_members = members;
            note("VIEW members={d}", .{members});
        }

        // The leader appends at a fixed pace so replication actually runs (a
        // leader with an empty log proves election only).
        const now = Time.monotonicNowMilliseconds();
        if (state == .leader and now - last_append_ms >= @as(i64, @intCast(cfg.append_ms))) {
            var cmd_buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&cmd_buf, "cn-{s}-{d}", .{ cfg.node_id, appends + 1 })) |cmd| {
                if (raft.appendEntry(cmd)) |index| {
                    appends += 1;
                    note("APPEND index={d}", .{index});
                } else |err| switch (err) {
                    // isLeader() then a higher-term inbound RPC before the
                    // append: legal raft, not a harness failure.
                    error.NotLeader => {},
                    else => note("APPEND_ERROR err={s}", .{@errorName(err)}),
                }
            } else |_| {
                note("APPEND_ERROR err=CommandTooLong", .{});
            }
            last_append_ms = now;
        }

        cnSleep(io, cfg.tick_ms);
    }
}

// ── main ─────────────────────────────────────────────────────────────────────

const usage =
    \\cluster-node — single-node cluster harness (scripts/ci-mixed-version.sh)
    \\  --id <node_id>              this node's id (required)
    \\  --raft-port <port>          cluster/raft port (required)
    \\  --bus-port <port>           event bus port (required)
    \\  --peer-raft <id@host:port>  raft peer (repeatable)
    \\  --peer-bus <id@host:port>   bus peer to keep dialled (repeatable)
    \\  --cluster-size <n>          raft cluster size (default: peers + 1)
    \\  --secret-hex <64 hex>       cluster secret (builds with the auth wire)
    \\  --bus-key-hex <64 hex>      bus credential; required with --secret-hex
    \\  --tick-ms <ms>              cluster.tick() cadence (default 25)
    \\  --mesh-ms <ms>              bus mesh maintenance cadence (default 2000)
    \\  --bus-idle-ms <ms>          bus inbound idle timeout override (0 = default)
    \\  --append-ms <ms>            leader append cadence (default 500)
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    {
        // Same argv pattern as replay_inspect: the pinned toolchain has no
        // `b.args`, so the binary is run directly with real argv.
        var iter = try init.minimal.args.iterateAllocator(allocator);
        defer iter.deinit();
        while (iter.next()) |arg| try args.append(allocator, arg);
    }
    if (args.items.len == 2 and (std.mem.eql(u8, args.items[1], "--help") or std.mem.eql(u8, args.items[1], "-h"))) {
        std.debug.print("{s}", .{usage});
        return;
    }
    const cfg = parseArgs(args.items[1..]) catch |err| {
        std.debug.print("CN BOOT_FAIL err={s}\n{s}", .{ @errorName(err), usage });
        std.process.exit(1);
    };

    if (builtin.os.tag != .windows) {
        const handler = std.posix.Sigaction{
            .handler = .{ .handler = onShutdownSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &handler, null);
        std.posix.sigaction(std.posix.SIG.TERM, &handler, null);
    }

    // Frames are signed only when the build has the auth wire at all: copied
    // into a v0.32.0 tree this compiles to "always bare", which is exactly the
    // old binary's wire — the experiment needs the *version* to decide, not an
    // argv flag the old code could never honor.
    const eff_secret: ?[32]u8 = if (wire_auth) cfg.secret else null;
    const auth_desc: []const u8 = if (!wire_auth) "unsupported" else if (cfg.secret != null) "on" else "off";
    note("BOOT id={s} raft={d} bus={d} auth={s} peers={d}", .{ cfg.node_id, cfg.raft_port, cfg.bus_port, auth_desc, cfg.raft_count });

    the_transport = .{
        .allocator = allocator,
        .io = io,
        .secret = eff_secret,
        .rpc_timeout_ms = 100,
        .peers = cfg.raftSpecs(),
        .node_id = cfg.node_id,
    };
    HarnessTransport.bound = &the_transport;

    var cluster = ClusterBootstrap.init(allocator, io, buildBootstrapConfig(&cfg)) catch |err| {
        std.debug.print("CN BOOT_FAIL phase=init err={s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    cluster.start() catch |err| {
        std.debug.print("CN BOOT_FAIL phase=start err={s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const bus = cluster.getEventBus().?;
    if (bus_credentials) {
        // The facade's `cluster_secret` only flips the bus to fail-closed
        // (`authEnabled`); the handshake itself runs on per-node credentials.
        // This harness uses ONE test key for every node (own + all peers) —
        // the challenge/response/MAC path is exercised in full; per-node keys
        // are soak_cluster's territory.
        if (cfg.bus_key) |k| {
            bus.setOwnKey(k);
            for (cfg.busSpecs()) |p| try bus.setPeerKey(p.id, k);
        }
        if (bus_idle_knob and cfg.bus_idle_ms != 0) {
            bus.inbound_idle_timeout_ms = cfg.bus_idle_ms;
        }
    }
    bus.start(cfg.bus_port) catch |err| {
        std.debug.print("CN BOOT_FAIL phase=bus err={s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    note("LISTEN raft={d} bus={d}", .{ cfg.raft_port, cfg.bus_port });

    mesh_ctx = .{ .bus = bus, .peers = cfg.busSpecs(), .mesh_ms = cfg.mesh_ms, .allocator = allocator, .io = io };
    const mesh_thread = std.Thread.spawn(.{ .stack_size = 1 * 1024 * 1024 }, meshMain, .{&mesh_ctx}) catch |err| {
        std.debug.print("CN BOOT_FAIL phase=mesh err={s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    driverLoop(io, &cluster, &cfg);

    note("SHUTDOWN begin", .{});
    shutdown_requested.store(true, .release);
    mesh_thread.join();
    cluster.deinit();
    note("SHUTDOWN clean", .{});
}

// ── tests (run by the default suite via build.zig's addTest) ─────────────────

test "parseKeyHex: round-trips 32 bytes and rejects malformed input" {
    const key = try parseKeyHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    try std.testing.expectEqual(@as(u8, 0x00), key[0]);
    try std.testing.expectEqual(@as(u8, 0x1f), key[31]);
    try std.testing.expectEqual(@as(u8, 0xab), (try parseKeyHex("ab00000000000000000000000000000000000000000000000000000000000000"))[0]);
    // uppercase accepted
    try std.testing.expectEqual(@as(u8, 0xab), (try parseKeyHex("AB00000000000000000000000000000000000000000000000000000000000000"))[0]);
    try std.testing.expectError(error.BadHexKey, parseKeyHex("00")); // too short
    try std.testing.expectError(error.BadHexKey, parseKeyHex("zz0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"));
    try std.testing.expectError(error.BadHexKey, parseKeyHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00")); // 66 chars
}

test "parsePeerSpec: id@host:port splits and validates" {
    const p = try parsePeerSpec("node-b@127.0.0.1:9001");
    try std.testing.expectEqualStrings("node-b", p.id);
    try std.testing.expectEqualStrings("127.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 9001), p.port);

    try std.testing.expectError(error.BadPeerSpec, parsePeerSpec("127.0.0.1:9001")); // no @id
    try std.testing.expectError(error.BadPeerSpec, parsePeerSpec("@127.0.0.1:9001")); // empty id
    try std.testing.expectError(error.BadPeerSpec, parsePeerSpec("node-b@127.0.0.1")); // no port
    try std.testing.expectError(error.BadPeerSpec, parsePeerSpec("node-b@127.0.0.1:0")); // port 0
    try std.testing.expectError(error.BadPeerSpec, parsePeerSpec("node-b@127.0.0.1:99999")); // > u16
}

test "parseArgs: full argv, derived cluster size, key pairing" {
    const cfg = try parseArgs(&.{
        "--id",          "n1",
        "--raft-port",   "24001",
        "--bus-port",    "24101",
        "--peer-raft",   "n2@127.0.0.1:24002",
        "--peer-raft",   "n3@127.0.0.1:24003",
        "--peer-bus",    "n2@127.0.0.1:24102",
        "--peer-bus",    "n3@127.0.0.1:24103",
        "--secret-hex",  "aa0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        "--bus-key-hex", "bb0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        "--tick-ms",     "10",
        "--bus-idle-ms", "3000",
    });
    try std.testing.expectEqualStrings("n1", cfg.node_id);
    try std.testing.expectEqual(@as(u16, 24001), cfg.raft_port);
    try std.testing.expectEqual(@as(u16, 24101), cfg.bus_port);
    try std.testing.expectEqual(@as(usize, 2), cfg.raft_count);
    try std.testing.expectEqual(@as(usize, 2), cfg.bus_count);
    try std.testing.expectEqual(@as(usize, 3), cfg.cluster_size); // derived: peers + 1
    try std.testing.expectEqual(@as(u8, 0xaa), cfg.secret.?[0]);
    try std.testing.expectEqual(@as(u8, 0xbb), cfg.bus_key.?[0]);
    try std.testing.expectEqual(@as(u64, 10), cfg.tick_ms);
    try std.testing.expectEqual(@as(u32, 3000), cfg.bus_idle_ms);
    try std.testing.expectEqualStrings("n2@127.0.0.1:24002", cfg.raftPeerStrings()[0]);
    try std.testing.expectEqualStrings("n3", cfg.busSpecs()[1].id);
    try std.testing.expectEqual(@as(u16, 24103), cfg.busSpecs()[1].port);
}

test "parseArgs: explicit cluster size wins over derivation" {
    const cfg = try parseArgs(&.{
        "--id",           "n1",
        "--raft-port",    "24001",
        "--bus-port",     "24101",
        "--peer-raft",    "n2@127.0.0.1:24002",
        "--cluster-size", "5",
    });
    try std.testing.expectEqual(@as(usize, 5), cfg.cluster_size);
}

test "parseArgs: missing required fields and bad values are errors" {
    try std.testing.expectError(error.MissingRequired, parseArgs(&.{ "--raft-port", "24001", "--bus-port", "24101" })); // no --id
    try std.testing.expectError(error.MissingRequired, parseArgs(&.{ "--id", "n1", "--bus-port", "24101" })); // no --raft-port
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "--id", "n1", "--raft-port", "24001", "--bus-port", "24101", "--nope" }));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{"--id"}));
    try std.testing.expectError(error.BadPort, parseArgs(&.{ "--id", "n1", "--raft-port", "0", "--bus-port", "24101" }));
    try std.testing.expectError(error.BadPort, parseArgs(&.{ "--id", "n1", "--raft-port", "abc", "--bus-port", "24101" }));
    // A cluster secret without a bus key would fail every bus dial with
    // PeerKeyMissing — refused at parse time instead.
    try std.testing.expectError(error.BusKeyWithoutSecret, parseArgs(&.{
        "--id",         "n1",
        "--raft-port",  "24001",
        "--bus-port",   "24101",
        "--secret-hex", "aa0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    }));
}

test "parseArgs: too many peers is bounded" {
    var argv: [(max_peers + 1) * 2 + 6][]const u8 = undefined;
    argv[0] = "--id";
    argv[1] = "n1";
    argv[2] = "--raft-port";
    argv[3] = "24001";
    argv[4] = "--bus-port";
    argv[5] = "24101";
    for (0..max_peers + 1) |i| {
        argv[6 + i * 2] = "--peer-raft";
        argv[6 + i * 2 + 1] = "n@127.0.0.1:25000";
    }
    try std.testing.expectError(error.TooManyPeers, parseArgs(&argv));
}

test "frame auth: signed frames verify, bare and tampered frames do not" {
    const key: [32]u8 = @splat(0x42);
    const frame = "the quick brown frame";
    var mac: [mac_bytes]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, frame, &key);

    var signed: [frame.len + mac_bytes]u8 = undefined;
    @memcpy(signed[0..frame.len], frame);
    @memcpy(signed[frame.len..], &mac);
    try std.testing.expectEqualStrings(frame, verifyFrameMac(key, &signed).?);

    // Bare frame: too short to carry a MAC → refused (the v0.32.0 shape).
    try std.testing.expect(verifyFrameMac(key, frame) == null);
    // Right length, wrong key.
    try std.testing.expect(verifyFrameMac(@splat(0x43), &signed) == null);
    // One flipped payload byte.
    signed[0] ^= 0x01;
    try std.testing.expect(verifyFrameMac(key, &signed) == null);
}
