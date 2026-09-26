//! HTTP/2 prior-knowledge connection loop (cleartext h2c).
//!
//! After the client sends the connection preface, this module:
//! 1. Sends SETTINGS + ACK
//! 2. Reads frames (SETTINGS / PING / WINDOW_UPDATE / GOAWAY / HEADERS / DATA / CONTINUATION)
//! 3. Multiplexes independent streams (END_HEADERS vs END_STREAM lifecycle)
//! 4. Dispatches gRPC (unary / server / client / bidi) or optional site handler
//! 5. Schedules outbound DATA via RFC 7540 PRIORITY weights (`PriorityTree` deficit WRR)
//!
//! HPACK via `Hpack.zig` (static + dynamic table; Huffman supported).
//!
//! STRUCTURE:
//!   §1  Wire types —— SiteResponse, SiteHandler, ServeOptions, ConnWriter
//!   §2  Entry points —— serve, serveAfterPreface and the prefetch variants
//!   §3  Connection loop —— serveAfterPrefacePrefetchReader: frame demux and stream lifecycle
//!   §4  Stream teardown —— abortStream, resetStream, sendGoAway
//!   §5  Outbound scheduler —— PendingOutbound, OutboundScheduler, window-aware DATA chunking
//!   §6  Stream state & live bidi —— StreamState, LiveFlushCtx, gRPC bidi pumping
//!   §7  Response encoding —— buildStreamResponseWire, encodeSiteResponseWire,
//!        assembleSiteResponseBlock (handler fields, h2 filtering, size budget)
//!   §8  Frame readers —— readFrame / readExact and their prefetch variants
//!   §9  Tests
//!
//! Every section carries a matching `// ==== §N ... ====` anchor — `grep "§6"` jumps there.

const std = @import("std");
const Http2 = @import("Http2.zig");
const Hpack = @import("Hpack.zig");
const Grpc = @import("../extensions/GrpcTransport.zig");
const Time = @import("../core/Time.zig");

// ==== §1  Wire types ====

/// Owned site response from `SiteHandler`.
pub const SiteResponse = struct {
    status: u16,
    content_type: []const u8,
    body: []u8,
    /// When true, `deinit` frees `content_type` as well.
    content_type_owned: bool = false,
    /// Every other response field the handler produced — `Set-Cookie`,
    /// `Location`, `Retry-After`, CORS, app headers. Without this the H2
    /// response carried `:status` and `content-type` only, so a handler that
    /// sends cookies and redirects on H1 silently sent neither to an H2 client.
    ///
    /// `content-type` here is ignored: `SiteResponse.content_type` owns that
    /// field, and two of them on one response is a protocol error. A handler
    /// may spell names in any case and add fields H2 cannot carry — the encoder
    /// (`assembleSiteResponseBlock`) lowercases names and filters those out, so
    /// nothing a handler does can make the block unsendable.
    headers: []const Hpack.Header = &.{},
    /// When true, `deinit` frees `headers` and every name/value in it.
    headers_owned: bool = false,

    pub fn deinit(self: *SiteResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.content_type_owned) allocator.free(self.content_type);
        if (self.headers_owned) {
            for (self.headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(self.headers);
        }
        self.* = undefined;
    }
};

/// Optional `user_ctx` is set by the server (e.g. `*Server` for router dispatch).
pub const SiteHandler = *const fn (
    user_ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    headers: []const Hpack.Header,
    body: []const u8,
) anyerror!SiteResponse;

/// Deadline control for the transport the session reads from. The H2 loop sees
/// only a `std.Io.Reader`, which has no deadline concept, so a caller that has
/// one (e.g. `Server`'s `StreamReader`) hands it in here; without it a peer
/// that stops sending parks the loop in `read` and the idle budget below can
/// only be noticed between frames.
pub const ReadDeadline = struct {
    ctx: *anyopaque,
    /// Bound the next read to `ms`; 0 = unbounded.
    arm_ms: *const fn (ctx: *anyopaque, ms: u32) void,
    /// Clear the bound — the session is over.
    clear: *const fn (ctx: *anyopaque) void,
    /// Whether the last failed read was cut short by the deadline rather than
    /// by the transport.
    timed_out: *const fn (ctx: *anyopaque) bool,
};

/// The HTTP/1.1 request that carried an `Upgrade: h2c` (RFC 7540 §3.2),
/// handed to the session that follows the 101 so it can answer it as stream 1.
///
/// RFC 7540 §3.2: "The HTTP/1.1 request that is sent prior to upgrade is
/// assigned a stream identifier of 1 ... Stream 1 is implicitly 'half-closed'
/// from the client toward the server, since the request is completed as an
/// HTTP/1.1 request." The client therefore never sends a HEADERS frame for it,
/// and a session that dispatches only on inbound frames answers the upgrade
/// with silence — the client sees the protocol switch and then hangs.
///
/// Every slice is borrowed for the duration of the `serveAfterUpgrade` call;
/// the session copies what it keeps.
pub const UpgradeRequest = struct {
    /// `:method`, from the HTTP/1.1 request line.
    method: []const u8,
    /// `:path` — the whole request target, query included (RFC 9113 §8.3.1).
    target: []const u8,
    /// `:authority`, from the `Host` field (empty when the request had none).
    authority: []const u8 = "",
    /// `:scheme`. Cleartext on the upgrade path.
    scheme: []const u8 = "http",
    /// Request fields as the HTTP/1.1 parser normalized them (lowercase names).
    /// The ones that describe the upgrade — `connection`, `upgrade`,
    /// `HTTP2-Settings` — are dropped when the stream is seeded: they are not
    /// HTTP/2 request fields (RFC 9113 §8.2.2) and the encoding could not have
    /// carried them.
    headers: []const Hpack.Header = &.{},
    /// Request body, already read in full off the HTTP/1.1 wire. Stream 1 is
    /// half-closed from the first frame, so this is the whole body.
    body: []const u8 = &.{},
    /// Raw `HTTP2-Settings` field value: the peer's SETTINGS payload, base64url.
    /// Applied as peer SETTINGS before the first response (§3.2.1) — the client
    /// also sends that same SETTINGS frame, but nothing waits for it.
    http2_settings: ?[]const u8 = null,
};

pub const ServeOptions = struct {
    /// When set, `:path` + `content-type: application/grpc` → registry dispatch.
    grpc_registry: ?*Grpc.GrpcServiceRegistry = null,
    /// Non-gRPC requests (HTML/JSON site over H2).
    site_handler: ?SiteHandler = null,
    /// Passed as first arg to `site_handler` (e.g. `*Server`).
    site_user_ctx: ?*anyopaque = null,
    /// Max frames to process before returning (tests / idle cap).
    max_frames: usize = 256,
    /// Cap concurrent pending outbound response streams (REFUSED_STREAM when exceeded).
    max_pending_streams: usize = 64,
    /// Cap total pending outbound wire bytes (ENHANCE_YOUR_CALM when exceeded).
    max_pending_bytes: usize = 4 * 1024 * 1024,
    /// Inbound resource limits (RFC 7540 §10.5 denial-of-service defenses).
    inbound: InboundLimits = .{},
    /// Idle-read budget for the session, in milliseconds: the clock starts when
    /// the session does and restarts on every complete frame. The H2 loop has
    /// no request phase to bound (unlike the H1 request-line / body
    /// deadlines), so without this a peer that sends the preface and then goes
    /// quiet holds its connection fiber forever. Over budget the session
    /// answers GOAWAY(ENHANCE_YOUR_CALM) and returns. `0` disables the bound.
    /// `Server` fills this from `Config.header_timeout_ms`.
    read_idle_timeout_ms: u32 = 10_000,
    /// Transport hook that cuts a blocked read short — see `ReadDeadline`.
    read_deadline: ?ReadDeadline = null,
    /// Send bound for every frame this session writes (`SO_SNDTIMEO`, armed and
    /// cleared around each write). Without it a client that stops reading parks
    /// this connection's fiber inside `send`, and whoever drains the fiber
    /// (`Server.stop()`) waits with it. `Server` fills this from
    /// `Config.response_write_timeout_ms`; `0` = unbounded.
    write_timeout_ms: u32 = 0,
};

/// Inbound resource limits for one HTTP/2 connection.
///
/// The H1 path bounds requests through `Server.Config` (`max_body_size`,
/// `header_limits`); the H2 loop has no access to that struct, so it carries its
/// own limits and applies them at the frame layer, before anything is buffered.
/// `Server` fills every field from its `Config` (see `Server.http2ServeOptions`),
/// so both protocols enforce the same numbers; the defaults here are the H1
/// defaults and are what a direct `ServeOptions` caller gets.
pub const InboundLimits = struct {
    /// Largest inbound frame we accept. RFC 7540 §4.2: the peer must not exceed
    /// the value we advertise in SETTINGS, and 16384 is the default. Raise it
    /// only together with an advertised SETTINGS_MAX_FRAME_SIZE.
    max_frame_size: u24 = 16384,
    /// Compressed header-block bytes buffered per stream (HEADERS + CONTINUATION).
    max_header_block_bytes: usize = 64 * 1024,
    /// Request-body bytes buffered per stream. Mirrors the H1 `max_body_size` default.
    max_body_bytes: usize = 8 * 1024 * 1024,
    /// Total inbound frame bytes (header + payload) per connection.
    max_inbound_bytes: usize = 64 * 1024 * 1024,
    /// CONTINUATION frames allowed after one HEADERS frame without END_HEADERS.
    /// Bounds the CONTINUATION-flood class: each frame may be empty, so the byte
    /// budget alone would not stop it.
    max_continuation_frames: usize = 16,
    /// Advertised SETTINGS_MAX_CONCURRENT_STREAMS — and actually enforced (§5.1.2).
    max_concurrent_streams: u32 = 100,
    /// Priority-tree nodes allowed beyond the concurrent-stream cap. PRIORITY on
    /// idle streams is legal, so the tree needs headroom — but not unbounded.
    priority_tree_slack: usize = 32,
    /// Decoded header-list bytes per stream, advertised as
    /// SETTINGS_MAX_HEADER_LIST_SIZE (RFC 9113 §6.5.2: name + value + 32 per
    /// field). `max_header_block_bytes` bounds the compressed block; this
    /// bounds what the block expands to. Mirrors `Server.HeaderLimits.max_total_bytes`.
    max_header_list_bytes: usize = 16 * 1024,
    /// Decoded header fields per stream. HTTP/2 advertises no SETTINGS value
    /// for it; it mirrors `Server.HeaderLimits.max_count`.
    max_header_count: usize = 100,
};

/// Inbound limit breaches. Each maps to a concrete HTTP/2 answer (GOAWAY or
/// RST_STREAM) — none of them may be swallowed, because the alternative is an
/// unbounded buffer or, for the flow-control cases, a desynchronised stream.
pub const InboundLimitError = error{
    /// Frame longer than `InboundLimits.max_frame_size` → GOAWAY FRAME_SIZE_ERROR.
    FrameSizeExceeded,
    /// Connection byte budget spent → GOAWAY ENHANCE_YOUR_CALM.
    BudgetExceeded,
    /// Too many CONTINUATION frames → GOAWAY ENHANCE_YOUR_CALM.
    ContinuationFlood,
    /// New client stream id that is not odd / not strictly increasing → GOAWAY PROTOCOL_ERROR.
    InvalidStreamId,
    /// More concurrent streams than advertised → RST_STREAM REFUSED_STREAM.
    TooManyStreams,
    /// Per-stream header block cap → RST_STREAM ENHANCE_YOUR_CALM.
    HeaderBlockTooLarge,
    /// Per-stream body cap → RST_STREAM ENHANCE_YOUR_CALM.
    BodyTooLarge,
};

/// Peer SETTINGS entries that changed connection-level state.
const AppliedPeerSettings = struct {
    /// New peer INITIAL_WINDOW_SIZE; the caller must propagate it to every open
    /// stream (`Http2.FlowControlState.applyPeerInitialWindowSize`).
    initial_window_size: ?u31 = null,
    /// New peer MAX_FRAME_SIZE — the cap on *our* outbound frames.
    max_frame_size: ?u31 = null,
    /// New peer MAX_HEADER_LIST_SIZE — the peer saying how large a response
    /// field section it will accept (RFC 9113 §6.5.2). Advisory, but we now
    /// have response headers to fit into it, so it bounds them.
    max_header_list_size: ?u32 = null,
};

/// Validate and apply a peer SETTINGS payload (RFC 7540 §6.5.2).
///
/// Connection-fatal values come back as errors so the caller can answer GOAWAY
/// with the code RFC 7540 mandates; `applyPeerSettings` never clamps or
/// truncates. `Http2.validateInitialWindowSize` is the narrowing step: casting
/// `0x8000_0000` used to abort the process here.
fn applyPeerSettings(
    conn_flow: *Http2.FlowControlState,
    payload: []const u8,
) Http2.FlowControlError!AppliedPeerSettings {
    var applied = AppliedPeerSettings{};
    var it = try Http2.SettingsIterator.init(payload);
    while (it.next()) |s| {
        switch (s.id) {
            Http2.SettingsId.initial_window_size => {
                const new_initial = try Http2.validateInitialWindowSize(s.value);
                try conn_flow.applyPeerInitialWindowSize(new_initial);
                applied.initial_window_size = new_initial;
            },
            Http2.SettingsId.max_frame_size => {
                applied.max_frame_size = try Http2.validateMaxFrameSize(s.value);
            },
            Http2.SettingsId.max_header_list_size => {
                // No validation: the field is a size hint and every u32 is a
                // legal value for it (0 = "accept no fields").
                applied.max_header_list_size = s.value;
            },
            else => {},
        }
    }
    return applied;
}

/// RFC 7540 §6.5.2 error code for a rejected SETTINGS frame.
fn settingsErrorCode(err: Http2.FlowControlError) u32 {
    return switch (err) {
        error.InvalidSettingsPayload => Http2.ErrorCode.FRAME_SIZE_ERROR,
        error.InvalidFrameSize => Http2.ErrorCode.PROTOCOL_ERROR,
        else => Http2.ErrorCode.FLOW_CONTROL_ERROR,
    };
}

/// Coalesces small writes and flushes once per drain/control batch.
const ConnWriter = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,
    /// See `ServeOptions.write_timeout_ms`.
    timeout_ms: u32 = 0,

    fn init(io: std.Io, stream: std.Io.net.Stream, timeout_ms: u32) ConnWriter {
        return .{ .io = io, .stream = stream, .timeout_ms = timeout_ms };
    }

    fn write(self: *ConnWriter, data: []const u8) !void {
        var rest = data;
        while (rest.len > 0) {
            const space = self.buf.len - self.len;
            if (space == 0) try self.flush();
            if (rest.len >= self.buf.len and self.len == 0) {
                try self.writeDirect(rest);
                return;
            }
            const n = @min(self.buf.len - self.len, rest.len);
            @memcpy(self.buf[self.len..][0..n], rest[0..n]);
            self.len += n;
            rest = rest[n..];
        }
    }

    fn writeFrame(self: *ConnWriter, typ: Http2.FrameType, flags: u8, stream_id: u31, payload: []const u8) !void {
        if (payload.len > std.math.maxInt(u24)) return error.PayloadTooLarge;
        var hdr: [9]u8 = undefined;
        (Http2.FrameHeader{
            .length = @intCast(payload.len),
            .typ = typ,
            .flags = flags,
            .stream_id = stream_id,
        }).encode(&hdr);
        try self.write(&hdr);
        try self.write(payload);
    }

    fn writeData(self: *ConnWriter, stream_id: u31, data: []const u8, end_stream: bool) !void {
        const flags: u8 = if (end_stream) Http2.FrameFlags.end_stream else 0;
        try self.writeFrame(.data, flags, stream_id, data);
    }

    /// The session's only writer: raw syscalls, with the send bound armed and
    /// cleared around each write.
    ///
    /// `std.Io`'s writer cannot express that bound — it answers a timed-out send
    /// with `errnoBug`, which is `unreachable` — and this is the one place on an
    /// H2 connection where bytes leave, so the bound is applied here rather than
    /// once per connection (which would leave the socket armed for anything else
    /// that ever writes to it).
    fn writeDirect(self: *ConnWriter, data: []const u8) !void {
        return @import("../core/sockread.zig").writeFullBounded(self.stream, data, self.timeout_ms);
    }

    fn flush(self: *ConnWriter) !void {
        if (self.len == 0) return;
        const to_write = self.buf[0..self.len];
        self.len = 0;
        try self.writeDirect(to_write);
    }
};

// ==== §2  Entry points ====

/// Serve one HTTP/2 connection: read client connection preface, then process frames.
pub fn serve(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
) !void {
    var preface_buf: [Http2.connection_preface.len]u8 = undefined;
    try readExact(io, stream, &preface_buf);
    if (!std.mem.eql(u8, &preface_buf, Http2.connection_preface)) return error.InvalidHttp2Preface;
    try serveAfterPreface(io, stream, allocator, opts);
}

/// Serve one HTTP/2 connection whose preface still has to be read, reusing the
/// connection's own reader (h2c upgrade, RFC 7540 §3.2: the 101 is already on
/// the wire, and the client's preface may have been pipelined into the same
/// segment as the upgrade request — those bytes are in `inbound`'s buffer, not
/// in the socket). `null` reads the preface straight from the stream, which is
/// what `serve` does.
///
/// `upgrade` is the request that carried the upgrade: it is stream 1 of this
/// session, and the session has to answer it itself (the client sends no
/// HEADERS frame for it). Passing it is what makes the upgrade a served request
/// rather than a protocol switch followed by silence.
pub fn serveAfterUpgrade(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
    inbound: ?*std.Io.Reader,
    upgrade: UpgradeRequest,
) !void {
    var preface_buf: [Http2.connection_preface.len]u8 = undefined;
    if (inbound) |reader| {
        var off: usize = 0;
        try readExactPrefetch(reader, &.{}, &off, &preface_buf);
    } else {
        try readExact(io, stream, &preface_buf);
    }
    if (!std.mem.eql(u8, &preface_buf, Http2.connection_preface)) return error.InvalidHttp2Preface;
    try serveSession(io, stream, allocator, opts, &.{}, inbound, upgrade);
}

/// Serve one prior-knowledge HTTP/2 connection. Preface must already be consumed.
///
/// `prefetch` holds bytes already buffered by the caller (e.g. StreamReader leftover
/// after consuming the HTTP/2 connection preface) that must be processed before
/// reading further from `stream`.
pub fn serveAfterPreface(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
) !void {
    try serveAfterPrefacePrefetch(io, stream, allocator, opts, &.{});
}

pub fn serveAfterPrefacePrefetch(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
    prefetch: []const u8,
) !void {
    // No shared inbound reader — create one here for the whole H2 session.
    try serveAfterPrefacePrefetchReader(io, stream, allocator, opts, prefetch, null);
}

// ==== §3  Connection loop ====

/// Like `serveAfterPrefacePrefetch`, but reuses an existing `std.Io.Reader` (e.g. the
/// connection's StreamReader) so buffered preface leftovers and further reads share
/// one reader — critical after HTTP/1.1 line-based preface detection.
pub fn serveAfterPrefacePrefetchReader(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
    prefetch: []const u8,
    inbound: ?*std.Io.Reader,
) !void {
    try serveSession(io, stream, allocator, opts, prefetch, inbound, null);
}

/// The connection loop itself. `upgrade` is non-null only on the h2c upgrade
/// path, where the request that carried the 101 has to be dispatched as stream 1
/// before anything is read (see `UpgradeRequest`).
fn serveSession(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
    prefetch: []const u8,
    inbound: ?*std.Io.Reader,
    upgrade: ?UpgradeRequest,
) !void {
    var writer = ConnWriter.init(io, stream, opts.write_timeout_ms);

    // Advertised limits: the peer must see the same numbers we enforce, or it
    // cannot know which of its requests will be refused (RFC 9113 §6.5.2).
    const settings = try Http2.encodeSettings(allocator, false, &.{
        .{ Http2.SettingsId.max_concurrent_streams, opts.inbound.max_concurrent_streams },
        .{ Http2.SettingsId.initial_window_size, Http2.default_initial_window_size },
        .{ Http2.SettingsId.max_header_list_size, std.math.cast(u32, opts.inbound.max_header_list_bytes) orelse std.math.maxInt(u32) },
    });
    defer allocator.free(settings);
    try writer.write(settings);
    try writer.flush();

    var hpack_dec = Hpack.Decoder.init(allocator);
    defer hpack_dec.deinit();
    hpack_dec.setAdvertisedHeaderListSize(opts.inbound.max_header_list_bytes, opts.inbound.max_header_count);

    var conn_flow = Http2.FlowControlState.init(Http2.default_initial_window_size);
    var conn_max_frame_size: u31 = 16384;
    // Peer `SETTINGS_MAX_HEADER_LIST_SIZE`, until it says otherwise: the bound
    // on the response header blocks we build (see `responseHeaderBudget`).
    var peer_max_header_list: ?u32 = null;
    var last_peer_stream: u31 = 0;
    // Highest client-initiated stream id we have opened state for (RFC 7540 §5.1.1).
    var last_opened_stream: u31 = 0;
    // Stream whose header block is still open (HEADERS without END_HEADERS).
    var continuation_of: ?u31 = null;
    var continuation_frames: usize = 0;
    var inbound_bytes: usize = 0;
    var goaway_sent = false;
    var reject_new_streams = false;

    var priority_tree = Http2.PriorityTree.init(allocator);
    defer priority_tree.deinit();

    var outbound = OutboundScheduler.init(allocator, opts.max_pending_streams, opts.max_pending_bytes);
    defer outbound.deinit();

    var streams = std.AutoHashMap(u31, StreamState).init(allocator);
    defer {
        var it = streams.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        streams.deinit();
    }

    const prefetch_buf = try allocator.dupe(u8, prefetch);
    defer allocator.free(prefetch_buf);
    var prefetch_off: usize = 0;

    var local_rbuf: [8192]u8 = undefined;
    var local_reader_storage: std.Io.net.Stream.Reader = undefined;
    const reader: *std.Io.Reader = if (inbound) |r| r else blk: {
        local_reader_storage = stream.reader(io, &local_rbuf);
        break :blk &local_reader_storage.interface;
    };

    const drain_slice: usize = 8;

    // Idle clock: the budget covers the session, and a complete frame refills
    // it. The enforcement is the transport deadline (`read_deadline`), armed
    // below for whatever is left of the budget — the check at the top of the
    // iteration only runs *between* frames, so on its own it cannot bound a
    // loop parked in a blocking read (a caller that supplies no deadline keeps
    // its reads unbounded, as before).
    const idle_timeout_ms = opts.read_idle_timeout_ms;
    defer if (opts.read_deadline) |d| d.clear(d.ctx);
    var last_progress_ms: i64 = Time.monotonicNowMilliseconds();

    // ---- h2c upgrade: the HTTP/1.1 request is stream 1 (RFC 7540 §3.2) ----
    //
    // The 101 is already on the wire and the client is waiting for the answer to
    // the request it upgraded on. It will not send a HEADERS frame for that
    // request — the RFC assigned it stream 1 — so seeding the stream here, once,
    // before the loop reads anything, is the only way it is ever dispatched: the
    // loop's own dispatch is driven entirely by inbound frames.
    var upgrade_stream_seeded = false;
    if (upgrade) |req| {
        // RFC 7540 §3.2.1: the `HTTP2-Settings` payload *is* the peer's SETTINGS
        // and is applied before anything is answered — the first response is
        // encoded against it. The client's own SETTINGS frame repeats the same
        // values (the RFC requires it to), so applying them twice is a no-op, not
        // a second window shift.
        if (req.http2_settings) |settings_value| {
            var payload = std.ArrayList(u8).empty;
            defer payload.deinit(allocator);
            decodeHttp2Settings(allocator, settings_value, &payload) catch {
                // RFC 7540 §3.2.1: an `HTTP2-Settings` the server cannot read is
                // a connection error. The 101 is already out, so GOAWAY is the
                // only answer left.
                try sendGoAway(&writer, allocator, 1, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
                return;
            };
            const applied = applyPeerSettings(&conn_flow, payload.items) catch |err| {
                try sendGoAway(&writer, allocator, 1, settingsErrorCode(err), &goaway_sent);
                return;
            };
            if (applied.max_frame_size) |peer_max_frame_size| conn_max_frame_size = peer_max_frame_size;
            if (applied.max_header_list_size) |peer_list| peer_max_header_list = peer_list;
        }

        // The map owns stream 1 from here — a failure below releases it.
        const gop = try streams.getOrPut(1);
        if (gop.found_existing) return error.UpgradeStreamAlreadyOpen;
        gop.value_ptr.* = StreamState.initWithPeerWindow(conn_flow.peer_initial);
        errdefer {
            if (streams.fetchRemove(1)) |kv| {
                var removed = kv;
                removed.value.deinit(allocator);
            }
        }
        try fillUpgradeStream(allocator, gop.value_ptr, req);
        // A stream's own send window follows the peer's INITIAL_WINDOW_SIZE, and
        // stream 1 is created after the settings above were applied — the same
        // treatment the SETTINGS branch gives every stream it already holds.
        gop.value_ptr.flow.applyPeerInitialWindowSize(conn_flow.peer_initial) catch |err|
            std.log.debug("[h2] upgrade stream window not adjusted ({s})", .{@errorName(err)});
        // Both markers, so a GOAWAY names stream 1 as the last one processed and
        // a HEADERS frame for it is not mistaken for a new stream.
        last_opened_stream = 1;
        last_peer_stream = 1;
        try priority_tree.ensureStream(1);
        upgrade_stream_seeded = true;

        const more_inbound = (prefetch_off < prefetch_buf.len) or (reader.bufferedLen() > 0);
        try finishStreamScheduled(
            &writer,
            allocator,
            1,
            gop.value_ptr,
            &conn_flow,
            conn_max_frame_size,
            peer_max_header_list,
            opts,
            &priority_tree,
            &outbound,
            more_inbound,
        );
        try writer.flush();
        if (streams.fetchRemove(1)) |kv| {
            var removed = kv;
            removed.value.deinit(allocator);
        }
        if (!outbound.pending.contains(1)) priority_tree.removeStream(1);
    }

    var frames: usize = 0;
    while (frames < opts.max_frames) : (frames += 1) {
        if (idle_timeout_ms > 0) {
            const idle_ms = Time.monotonicNowMilliseconds() - last_progress_ms;
            if (idle_ms >= @as(i64, idle_timeout_ms)) {
                try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.ENHANCE_YOUR_CALM, &goaway_sent);
                return;
            }
            // Arm for what is left of the budget, not a fresh full one: a peer
            // that sends one byte per (budget - 1) ms must not extend the
            // session indefinitely.
            if (opts.read_deadline) |d| d.arm_ms(d.ctx, @intCast(idle_timeout_ms - @as(u32, @intCast(idle_ms))));
        }

        const inbound_ready = (prefetch_off < prefetch_buf.len) or (reader.bufferedLen() > 0);
        if (!inbound_ready and outbound.pending.count() > 0) {
            try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, 0);
            try writer.flush();
        }

        const frame_buf = readFramePrefetch(
            reader,
            allocator,
            prefetch_buf,
            &prefetch_off,
            opts.inbound.max_frame_size,
            opts.inbound.max_inbound_bytes -| inbound_bytes,
        ) catch |err| switch (err) {
            error.ConnectionClosed => {
                try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, 0);
                try writer.flush();
                return;
            },
            error.FrameSizeExceeded => {
                try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.FRAME_SIZE_ERROR, &goaway_sent);
                return;
            },
            error.BudgetExceeded => {
                try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.ENHANCE_YOUR_CALM, &goaway_sent);
                return;
            },
            error.ReadFailed => {
                // A spent deadline is the idle peer: name it, so the client can
                // tell "you went quiet" from a broken transport.
                const timed_out = if (opts.read_deadline) |d| d.timed_out(d.ctx) else false;
                try sendGoAway(&writer, allocator, last_peer_stream, readFailureCode(timed_out), &goaway_sent);
                return;
            },
            else => {
                try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
                return;
            },
        };
        defer allocator.free(frame_buf);
        last_progress_ms = Time.monotonicNowMilliseconds();
        inbound_bytes += frame_buf.len;

        const frame = Http2.decodeFrame(frame_buf) catch {
            try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
            return;
        };
        if (frame.header.stream_id != 0 and frame.header.stream_id > last_peer_stream) {
            last_peer_stream = frame.header.stream_id;
        }

        // RFC 7540 §4.3: a header block stays a single contiguous frame sequence.
        if (continuation_of) |pending_sid| {
            if (frame.header.typ != .continuation or frame.header.stream_id != pending_sid) {
                try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
                return;
            }
        }

        switch (frame.header.typ) {
            .settings => {
                if ((frame.header.flags & Http2.FrameFlags.ack) == 0) {
                    const applied = applyPeerSettings(&conn_flow, frame.payload) catch |err| {
                        try sendGoAway(&writer, allocator, last_peer_stream, settingsErrorCode(err), &goaway_sent);
                        return;
                    };
                    if (applied.initial_window_size) |new_initial| {
                        var it = streams.valueIterator();
                        while (it.next()) |st| {
                            st.flow.applyPeerInitialWindowSize(new_initial) catch |err| std.log.debug("[h2] window-size update ignored ({s})", .{@errorName(err)});
                        }
                        var pit = outbound.pending.valueIterator();
                        while (pit.next()) |p| {
                            p.flow.applyPeerInitialWindowSize(new_initial) catch |err| std.log.debug("[h2] window-size update ignored ({s})", .{@errorName(err)});
                        }
                    }
                    if (applied.max_frame_size) |peer_max_frame_size| conn_max_frame_size = peer_max_frame_size;
                    if (applied.max_header_list_size) |peer_list| peer_max_header_list = peer_list;
                    try writer.writeFrame(.settings, Http2.FrameFlags.ack, 0, &.{});
                    try writer.flush();
                }
            },
            .ping => {
                if ((frame.header.flags & Http2.FrameFlags.ack) == 0 and frame.payload.len == 8) {
                    try writer.writeFrame(.ping, Http2.FrameFlags.ack, 0, frame.payload);
                    try writer.flush();
                }
            },
            .window_update => {
                const increment = Http2.decodeWindowUpdate(frame.payload) catch continue;
                if (frame.header.stream_id == 0) {
                    conn_flow.applyWindowUpdate(increment) catch {
                        try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.FLOW_CONTROL_ERROR, &goaway_sent);
                        return;
                    };
                } else if (streams.getPtr(frame.header.stream_id)) |st| {
                    st.flow.applyWindowUpdate(increment) catch {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, frame.header.stream_id, Http2.ErrorCode.FLOW_CONTROL_ERROR);
                    };
                } else if (outbound.pending.getPtr(frame.header.stream_id)) |p| {
                    p.flow.applyWindowUpdate(increment) catch {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, frame.header.stream_id, Http2.ErrorCode.FLOW_CONTROL_ERROR);
                    };
                }
                try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, drain_slice);
                try writer.flush();
            },
            .priority => {
                const sid = frame.header.stream_id;
                if (sid == 0) continue;
                const pri = Http2.decodePriority(frame.payload) catch continue;
                if (streams.getPtr(sid)) |st| {
                    st.priority = pri;
                } else if (priority_tree.nodes.count() >=
                    @as(usize, opts.inbound.max_concurrent_streams) + opts.inbound.priority_tree_slack)
                {
                    // PRIORITY on an idle stream is advisory (RFC 7540 §5.3): the
                    // hint may be dropped, but the state it would allocate may not
                    // grow without bound.
                    continue;
                }
                try priority_tree.setPriority(sid, pri);
            },
            .rst_stream => {
                const sid = frame.header.stream_id;
                if (sid != 0) {
                    _ = Http2.decodeRstStream(frame.payload) catch |err| std.log.debug("[h2] malformed RST_STREAM ignored ({s})", .{@errorName(err)});
                    abortStream(&outbound, &priority_tree, &streams, allocator, sid);
                }
            },
            .goaway => {
                const info = Http2.decodeGoAway(frame.payload) catch {
                    try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
                    return;
                };
                reject_new_streams = true;
                _ = info;
                try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, 0);
                try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.NO_ERROR, &goaway_sent);
                return;
            },
            .headers => {
                const sid = frame.header.stream_id;
                if (sid == 0) {
                    try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
                    return;
                }
                if (upgrade_stream_seeded and sid == 1) {
                    // Stream 1 is the upgrade request, and it has been answered:
                    // RFC 7540 §3.2 puts it in half-closed (remote) from the
                    // start, so a HEADERS frame for it is the one frame the
                    // client must not send. Treating it as a new stream would
                    // dispatch the same request a second time; §5.1 names the
                    // answer for a half-closed (remote) stream — a stream error.
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.STREAM_CLOSED);
                    continue;
                }
                if (!streams.contains(sid)) {
                    // RFC 7540 §5.1.1 — new client streams are odd and increasing.
                    validateNewClientStreamId(sid, last_opened_stream) catch {
                        try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
                        return;
                    };
                    if (reject_new_streams) {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.REFUSED_STREAM);
                        continue;
                    }
                    // RFC 7540 §5.1.2 — the advertised MAX_CONCURRENT_STREAMS is a promise.
                    checkConcurrentStreams(streams.count(), opts.inbound.max_concurrent_streams) catch {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.REFUSED_STREAM);
                        continue;
                    };
                    last_opened_stream = sid;
                }
                const gop = try streams.getOrPut(sid);
                if (!gop.found_existing) gop.value_ptr.* = StreamState.initWithPeerWindow(conn_flow.peer_initial);
                try priority_tree.ensureStream(sid);
                const header_chunk = blk: {
                    const stripped = Http2.stripHeadersPriority(frame.payload, frame.header.flags) catch break :blk frame.payload;
                    if (stripped.priority) |pri| {
                        gop.value_ptr.priority = pri;
                        try priority_tree.setPriority(sid, pri);
                    }
                    break :blk stripped.header_block;
                };
                gop.value_ptr.appendHeaders(allocator, header_chunk, opts.inbound.max_header_block_bytes) catch |err| {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, inboundLimitCode(err));
                    if ((frame.header.flags & Http2.FrameFlags.end_headers) == 0) continuation_of = null;
                    continue;
                };
                if ((frame.header.flags & Http2.FrameFlags.end_headers) != 0) {
                    gop.value_ptr.headers_done = true;
                    gop.value_ptr.decodeHeaders(allocator, &hpack_dec) catch |err| {
                        // RFC 7541 §4.2 / RFC 7540 §4.2: a failure in the
                        // compression context is a *connection* error — the
                        // decoder's table state has already diverged from the
                        // peer's, so later streams would keep failing. RST alone
                        // would leave the session writing into a broken decoder.
                        // A header list past the size we advertised is the other
                        // case: the block decoded, only *this* stream is refused.
                        if (Hpack.isConnectionError(err)) {
                            try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.COMPRESSION_ERROR, &goaway_sent);
                            return;
                        }
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, headerDecodeErrorCode(err));
                        continue;
                    };
                    maybeStartLiveBidi(&writer, allocator, sid, gop.value_ptr, opts) catch |err| {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                        continue;
                    };
                } else {
                    continuation_of = sid;
                    continuation_frames = 0;
                }
                if ((frame.header.flags & Http2.FrameFlags.end_stream) != 0) {
                    gop.value_ptr.end_stream = true;
                }
                if (gop.value_ptr.bidi_live) {
                    if (gop.value_ptr.end_stream) {
                        finishLiveBidi(&writer, allocator, sid, gop.value_ptr) catch |err| {
                            try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                            continue;
                        };
                        try writer.flush();
                        abortStream(&outbound, &priority_tree, &streams, allocator, sid);
                    }
                } else if (gop.value_ptr.ready()) {
                    const more_inbound = (prefetch_off < prefetch_buf.len) or (reader.bufferedLen() > 0);
                    finishStreamScheduled(&writer, allocator, sid, gop.value_ptr, &conn_flow, conn_max_frame_size, peer_max_header_list, opts, &priority_tree, &outbound, more_inbound) catch |err| {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                        continue;
                    };
                    try writer.flush();
                    if (streams.fetchRemove(sid)) |kv| {
                        var removed = kv;
                        removed.value.deinit(allocator);
                    }
                    if (!outbound.pending.contains(sid)) priority_tree.removeStream(sid);
                }
            },
            .continuation => {
                const sid = frame.header.stream_id;
                continuation_frames += 1;
                if (continuation_frames > opts.inbound.max_continuation_frames) {
                    // CONTINUATION frames may be empty, so the byte budget alone
                    // does not bound this loop (the 2023 "CONTINUATION flood" class).
                    try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.ENHANCE_YOUR_CALM, &goaway_sent);
                    return;
                }
                const st = streams.getPtr(sid) orelse {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.STREAM_CLOSED);
                    continue;
                };
                st.appendHeaders(allocator, frame.payload, opts.inbound.max_header_block_bytes) catch |err| {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, inboundLimitCode(err));
                    continue;
                };
                if ((frame.header.flags & Http2.FrameFlags.end_headers) != 0) {
                    continuation_of = null;
                    continuation_frames = 0;
                    st.headers_done = true;
                    st.decodeHeaders(allocator, &hpack_dec) catch |err| {
                        // Connection-level for the same reason as the
                        // `streams.getOrPut` path above: the HPACK context is
                        // shared by every stream on the connection. A list past
                        // the advertised size is not that kind of failure.
                        if (Hpack.isConnectionError(err)) {
                            try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.COMPRESSION_ERROR, &goaway_sent);
                            return;
                        }
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, headerDecodeErrorCode(err));
                        continue;
                    };
                    maybeStartLiveBidi(&writer, allocator, sid, st, opts) catch |err| {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                        continue;
                    };
                    if (st.bidi_live and st.end_stream) {
                        finishLiveBidi(&writer, allocator, sid, st) catch |err| {
                            try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                            continue;
                        };
                        try writer.flush();
                        abortStream(&outbound, &priority_tree, &streams, allocator, sid);
                    } else if (st.ready()) {
                        const more_inbound = (prefetch_off < prefetch_buf.len) or (reader.bufferedLen() > 0);
                        finishStreamScheduled(&writer, allocator, sid, st, &conn_flow, conn_max_frame_size, peer_max_header_list, opts, &priority_tree, &outbound, more_inbound) catch |err| {
                            try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                            continue;
                        };
                        try writer.flush();
                        if (streams.fetchRemove(sid)) |kv| {
                            var removed = kv;
                            removed.value.deinit(allocator);
                        }
                        if (!outbound.pending.contains(sid)) priority_tree.removeStream(sid);
                    }
                }
            },
            .data => {
                const sid = frame.header.stream_id;
                const data_len: u31 = @intCast(frame.payload.len);
                onInboundData(&writer, allocator, &conn_flow, 0, data_len) catch {
                    try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.FLOW_CONTROL_ERROR, &goaway_sent);
                    return;
                };
                const st = streams.getPtr(sid) orelse {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.STREAM_CLOSED);
                    continue;
                };
                // Per-stream body budget, checked before granting more window: the
                // connection window is replenished as it drains, so flow control
                // alone does not bound what a stream buffers.
                st.inbound_body_bytes +|= frame.payload.len;
                if (st.inbound_body_bytes > opts.inbound.max_body_bytes) {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.ENHANCE_YOUR_CALM);
                    continue;
                }
                onInboundData(&writer, allocator, &st.flow, sid, data_len) catch {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.FLOW_CONTROL_ERROR);
                    continue;
                };
                if ((frame.header.flags & Http2.FrameFlags.end_stream) != 0) {
                    st.end_stream = true;
                }
                if (st.bidi_live) {
                    pumpLiveBidiData(&writer, allocator, sid, st, &conn_flow, conn_max_frame_size, opts, frame.payload) catch |err| {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                        continue;
                    };
                    if (st.end_stream) {
                        finishLiveBidi(&writer, allocator, sid, st) catch |err| {
                            try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                            continue;
                        };
                        try writer.flush();
                        abortStream(&outbound, &priority_tree, &streams, allocator, sid);
                    }
                } else {
                    st.appendData(allocator, frame.payload, opts.inbound.max_body_bytes) catch |err| {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, inboundLimitCode(err));
                        continue;
                    };
                    if (st.ready()) {
                        const more_inbound = (prefetch_off < prefetch_buf.len) or (reader.bufferedLen() > 0);
                        finishStreamScheduled(&writer, allocator, sid, st, &conn_flow, conn_max_frame_size, peer_max_header_list, opts, &priority_tree, &outbound, more_inbound) catch |err| {
                            try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                            continue;
                        };
                        try writer.flush();
                        if (streams.fetchRemove(sid)) |kv| {
                            var removed = kv;
                            removed.value.deinit(allocator);
                        }
                        if (!outbound.pending.contains(sid)) priority_tree.removeStream(sid);
                    }
                }
            },
            .push_promise => {},
        }

        if (outbound.pending.count() > 0) {
            const more_inbound = (prefetch_off < prefetch_buf.len) or (reader.bufferedLen() > 0);
            const budget: usize = if (more_inbound or outbound.pending.count() > 1) drain_slice else 0;
            try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, budget);
            if (!more_inbound) try writer.flush();
        }
    }

    try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, 0);
    try writer.flush();
}

// ==== §4  Stream teardown ====

fn abortStream(
    outbound: *OutboundScheduler,
    tree: *Http2.PriorityTree,
    streams: *std.AutoHashMap(u31, StreamState),
    allocator: std.mem.Allocator,
    sid: u31,
) void {
    outbound.cancel(sid);
    tree.removeStream(sid);
    if (streams.fetchRemove(sid)) |kv| {
        var removed = kv;
        removed.value.deinit(allocator);
    }
}

fn resetStream(
    writer: *ConnWriter,
    allocator: std.mem.Allocator,
    outbound: *OutboundScheduler,
    tree: *Http2.PriorityTree,
    streams: *std.AutoHashMap(u31, StreamState),
    sid: u31,
    code: u32,
) !void {
    abortStream(outbound, tree, streams, allocator, sid);
    if (sid == 0) return;
    const frame = try Http2.encodeRstStream(allocator, sid, code);
    defer allocator.free(frame);
    try writer.write(frame);
    try writer.flush();
}

/// RFC 7540 §5.1.1 — a client-initiated stream id must be odd and greater than
/// every id the client has already opened. Anything else is a connection error
/// (PROTOCOL_ERROR), not something to allocate state for.
fn validateNewClientStreamId(sid: u31, last_opened: u31) InboundLimitError!void {
    if ((sid & 1) == 0) return error.InvalidStreamId;
    if (sid <= last_opened) return error.InvalidStreamId;
}

/// RFC 7540 §5.1.2 — enforce the MAX_CONCURRENT_STREAMS we advertised, instead
/// of letting the peer open unbounded stream state (each stream buffers headers,
/// a body and its own flow-control window).
fn checkConcurrentStreams(open_streams: usize, max_concurrent: u32) InboundLimitError!void {
    if (open_streams >= max_concurrent) return error.TooManyStreams;
}

/// HTTP/2 error code for an inbound resource-limit breach (RFC 7540 §10.5).
fn inboundLimitCode(err: anyerror) u32 {
    return switch (err) {
        error.HeaderBlockTooLarge, error.BodyTooLarge => Http2.ErrorCode.ENHANCE_YOUR_CALM,
        else => Http2.ErrorCode.INTERNAL_ERROR,
    };
}

/// HTTP/2 error code for a header block that decoded but produced a list past
/// what we advertised (RFC 9113 §6.5.2). The block itself was fine, so this is
/// one stream's answer, not the connection's — but the list was refused, and
/// `ENHANCE_YOUR_CALM` is that refusal.
fn headerDecodeErrorCode(err: anyerror) u32 {
    return switch (err) {
        error.HeaderListTooLarge, error.TooManyHeaderFields => Http2.ErrorCode.ENHANCE_YOUR_CALM,
        else => Http2.ErrorCode.COMPRESSION_ERROR,
    };
}

/// HTTP/2 error code for a frame read that failed: a read the idle deadline cut
/// short is a peer that stopped talking (`ENHANCE_YOUR_CALM`, the §10.5 answer
/// to excessive load — it is holding a connection slot for nothing), anything
/// else is the transport.
fn readFailureCode(timed_out: bool) u32 {
    return if (timed_out) Http2.ErrorCode.ENHANCE_YOUR_CALM else Http2.ErrorCode.PROTOCOL_ERROR;
}

/// Decode an `HTTP2-Settings` field value into the SETTINGS payload it carries:
/// base64url (RFC 4648 §5), trailing `=` omitted per RFC 7540 §3.2.1.
///
/// Padding is tolerated when a client sends it anyway — that is a spelling of
/// the same bytes, not a different value. Interior `=` is not: it is not base64
/// at all, and `decode` reports it as `InvalidCharacter`.
fn decodeHttp2Settings(
    allocator: std.mem.Allocator,
    value: []const u8,
    out: *std.ArrayList(u8),
) !void {
    var body = value;
    while (body.len > 0 and body[body.len - 1] == '=') body = body[0 .. body.len - 1];
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = try decoder.calcSizeForSlice(body);
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    try decoder.decode(buf, body);
    try out.appendSlice(allocator, buf);
}

/// Fill `st` with the request that carried the h2c upgrade (RFC 7540 §3.2).
/// That request is already complete — it was parsed off the HTTP/1.1 wire — so
/// the stream starts with `headers_done` and `end_stream` set: it is
/// half-closed (remote) from the first frame and its whole body is already in
/// hand.
///
/// The four pseudo-headers a prior-knowledge request would carry are built from
/// the request line and `Host`; the rest are the request's own fields, minus the
/// ones that describe the upgrade rather than the request. Everything is copied
/// with `allocator`, which is also what `StreamState.deinit` frees with.
fn fillUpgradeStream(allocator: std.mem.Allocator, st: *StreamState, req: UpgradeRequest) !void {
    st.method = try allocator.dupe(u8, req.method);
    st.path = try allocator.dupe(u8, req.target);
    st.headers_done = true;
    // Not "the request had no body". The HTTP/1.1 request was read to its end
    // before the session started — `Content-Length` is the only body framing
    // this server accepts, and the parser buffered all of it — so there is
    // nothing left for the peer to send on **any** method. RFC 7540 §3.2 makes
    // stream 1 implicitly half-closed (remote) for exactly that reason, a `POST`
    // with a body included; a session that waited for DATA frames would hang on
    // a request whose body it is already holding.
    st.end_stream = true;
    if (req.body.len > 0) try st.data.appendSlice(allocator, req.body);

    var owned = std.ArrayList(Hpack.Header).empty;
    errdefer {
        for (owned.items) |h| {
            allocator.free(@constCast(h.name));
            allocator.free(@constCast(h.value));
        }
        owned.deinit(allocator);
    }

    for ([_]Hpack.Header{
        .{ .name = ":method", .value = req.method },
        .{ .name = ":path", .value = req.target },
        .{ .name = ":scheme", .value = req.scheme },
        .{ .name = ":authority", .value = req.authority },
    }) |h| try appendOwnedHeader(allocator, &owned, h.name, h.value);

    for (req.headers) |h| {
        if (h.name.len == 0 or h.name[0] == ':') continue;
        // The three fields the upgrade itself was made of. They are not HTTP/2
        // request fields (RFC 9113 §8.2.2), and a handler that saw them on this
        // path would see what no H2 request can carry.
        if (isConnectionSpecific(h.name)) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "http2-settings")) continue;
        // `content-type` decides the gRPC branch of the response encoder, so it
        // is mirrored the way `decodeHeaders` mirrors it for a real H2 request.
        if (st.content_type.len == 0 and h.value.len > 0 and std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            st.content_type = try allocator.dupe(u8, h.value);
        }
        try appendOwnedHeader(allocator, &owned, h.name, h.value);
    }
    st.decoded = try owned.toOwnedSlice(allocator);
}

/// One owned `name: value` pair in `list`. Ownership is recorded per slice so
/// `Hpack.freeHeaders` releases both — the fallback it uses for an unmarked
/// header is a pointer fingerprint, which a `dupe` of a static-table string
/// would not match.
fn appendOwnedHeader(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Hpack.Header),
    name: []const u8,
    value: []const u8,
) !void {
    const n = try allocator.dupe(u8, name);
    errdefer allocator.free(n);
    const v = try allocator.dupe(u8, value);
    errdefer allocator.free(v);
    try list.append(allocator, .{
        .name = n,
        .value = v,
        .name_owner = .owned,
        .value_owner = .owned,
    });
}

fn sendGoAway(
    writer: *ConnWriter,
    allocator: std.mem.Allocator,
    last_stream_id: u31,
    code: u32,
    goaway_sent: *bool,
) !void {
    if (goaway_sent.*) {
        try writer.flush();
        return;
    }
    goaway_sent.* = true;
    const frame = try Http2.encodeGoAway(allocator, last_stream_id, code, "");
    defer allocator.free(frame);
    try writer.write(frame);
    try writer.flush();
}

// ==== §5  Outbound scheduler ====

/// Per-stream pending HTTP/2 wire (HEADERS/DATA/trailers) drained by PriorityTree WRR.
const PendingOutbound = struct {
    wire: []u8,
    /// Logical end of wire (may shrink after in-place DATA partial send).
    end: usize,
    offset: usize = 0,
    flow: Http2.FlowControlState,

    fn deinit(self: *PendingOutbound, allocator: std.mem.Allocator) void {
        allocator.free(self.wire);
        self.* = undefined;
    }

    fn remaining(self: *const PendingOutbound) []const u8 {
        return self.wire[self.offset..self.end];
    }

    fn done(self: *const PendingOutbound) bool {
        return self.offset >= self.end;
    }

    fn byteLen(self: *const PendingOutbound) usize {
        return self.end -| self.offset;
    }
};

/// Weighted outbound DATA scheduler: interleaves pending streams via `PriorityTree.pickNext`.
const OutboundScheduler = struct {
    allocator: std.mem.Allocator,
    pending: std.AutoHashMap(u31, PendingOutbound),
    pending_bytes: usize = 0,
    max_streams: usize,
    max_bytes: usize,

    fn init(allocator: std.mem.Allocator, max_streams: usize, max_bytes: usize) OutboundScheduler {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(u31, PendingOutbound).init(allocator),
            .max_streams = max_streams,
            .max_bytes = max_bytes,
        };
    }

    fn deinit(self: *OutboundScheduler) void {
        var it = self.pending.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.allocator);
        self.pending.deinit();
        self.* = undefined;
    }

    fn cancel(self: *OutboundScheduler, stream_id: u31) void {
        if (self.pending.fetchRemove(stream_id)) |kv| {
            var p = kv.value;
            self.pending_bytes -|= p.byteLen();
            p.deinit(self.allocator);
        }
    }

    fn enqueue(self: *OutboundScheduler, stream_id: u31, wire: []u8, flow: Http2.FlowControlState) !void {
        self.cancel(stream_id);
        if (self.pending.count() >= self.max_streams) {
            self.allocator.free(wire);
            return error.PendingStreamsExceeded;
        }
        if (self.pending_bytes + wire.len > self.max_bytes) {
            self.allocator.free(wire);
            return error.PendingBytesExceeded;
        }
        self.pending_bytes += wire.len;
        errdefer {
            self.pending_bytes -|= wire.len;
            self.allocator.free(wire);
        }
        try self.pending.put(stream_id, .{
            .wire = wire,
            .end = wire.len,
            .offset = 0,
            .flow = flow,
        });
    }

    fn drain(
        self: *OutboundScheduler,
        writer: *ConnWriter,
        tree: *Http2.PriorityTree,
        conn_flow: *Http2.FlowControlState,
        conn_max_frame_size: u31,
        max_frames: usize,
    ) !void {
        var wrote_n: usize = 0;
        var guard: usize = 0;
        while (guard < 4096) : (guard += 1) {
            if (self.pending.count() == 0) return;
            if (max_frames != 0 and wrote_n >= max_frames) return;

            if (self.pending.count() == 1) {
                var single_it = self.pending.iterator();
                if (single_it.next()) |e| {
                    const stream_id = e.key_ptr.*;
                    const p = e.value_ptr;
                    if (!p.done() and canSendNextFrame(p, conn_flow.send_window, conn_max_frame_size)) {
                        const before = p.byteLen();
                        const progress = try writeNextWireFrame(writer, conn_flow, &p.flow, stream_id, p, conn_max_frame_size);
                        const after: usize = if (progress == .done) 0 else p.byteLen();
                        self.pending_bytes = self.pending_bytes - before + after;
                        switch (progress) {
                            .blocked => return,
                            .wrote => wrote_n += 1,
                            .done => {
                                var removed = self.pending.fetchRemove(stream_id).?;
                                removed.value.deinit(self.allocator);
                                tree.removeStream(stream_id);
                                wrote_n += 1;
                            },
                        }
                        continue;
                    }
                }
            }

            var ready_buf: [64]u31 = undefined;
            var ready_n: usize = 0;
            var it = self.pending.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.done()) continue;
                if (ready_n >= ready_buf.len) break;
                if (canSendNextFrame(e.value_ptr, conn_flow.send_window, conn_max_frame_size)) {
                    ready_buf[ready_n] = e.key_ptr.*;
                    ready_n += 1;
                }
            }
            if (ready_n == 0) return;

            const pick = (try tree.pickNext(ready_buf[0..ready_n])) orelse return;
            const p = self.pending.getPtr(pick) orelse continue;
            const before = p.byteLen();
            const progress = try writeNextWireFrame(writer, conn_flow, &p.flow, pick, p, conn_max_frame_size);
            // After write, remaining bytes for this stream (0 if finished).
            const after: usize = if (progress == .done) 0 else p.byteLen();
            self.pending_bytes = self.pending_bytes - before + after;
            switch (progress) {
                .blocked => return,
                .wrote => wrote_n += 1,
                .done => {
                    var removed = self.pending.fetchRemove(pick).?;
                    removed.value.deinit(self.allocator);
                    tree.removeStream(pick);
                    wrote_n += 1;
                },
            }
        }
    }
};

fn canSendNextFrame(p: *PendingOutbound, conn_send_window: u31, conn_max_frame_size: u31) bool {
    const rem = p.remaining();
    if (rem.len < 9) return false;
    const frame = Http2.decodeFrame(rem) catch return false;
    if (frame.header.typ != .data) return true;
    const max_chunk = maxOutboundChunk(&p.flow, conn_send_window, conn_max_frame_size);
    return max_chunk > 0 or frame.payload.len == 0;
}

fn writeNextWireFrame(
    writer: *ConnWriter,
    conn_flow: *Http2.FlowControlState,
    stream_flow: *Http2.FlowControlState,
    stream_id: u31,
    pending: *PendingOutbound,
    conn_max_frame_size: u31,
) !enum { wrote, blocked, done } {
    const rem = pending.remaining();
    if (rem.len < 9) {
        pending.offset = pending.end;
        return .done;
    }
    const frame = try Http2.decodeFrame(rem);
    const frame_len = 9 + @as(usize, frame.header.length);
    if (frame.header.typ == .data and frame.header.stream_id == stream_id) {
        const end_stream = (frame.header.flags & Http2.FrameFlags.end_stream) != 0;
        const max_chunk = maxOutboundChunk(stream_flow, conn_flow.send_window, conn_max_frame_size);
        if (frame.payload.len == 0) {
            try writer.writeData(stream_id, "", end_stream);
            pending.offset += frame_len;
            return if (pending.done()) .done else .wrote;
        }
        if (max_chunk == 0) return .blocked;
        const send_n: usize = @min(@as(usize, max_chunk), frame.payload.len);
        const is_last_of_frame = send_n == frame.payload.len;
        try writer.writeData(stream_id, frame.payload[0..send_n], end_stream and is_last_of_frame);
        const sent: u31 = @intCast(send_n);
        stream_flow.consumeSend(sent);
        conn_flow.consumeSend(sent);
        if (is_last_of_frame) {
            pending.offset += frame_len;
        } else {
            shrinkDataFrameInPlace(pending, send_n);
        }
        return if (pending.done()) .done else .wrote;
    } else {
        try writer.write(rem[0..frame_len]);
        pending.offset += frame_len;
        return if (pending.done()) .done else .wrote;
    }
}

/// After a partial DATA send, shrink the current DATA frame in-place (no realloc).
fn shrinkDataFrameInPlace(pending: *PendingOutbound, sent: usize) void {
    const rem = pending.remaining();
    const frame = Http2.decodeFrame(rem) catch return;
    const old_plen = frame.payload.len;
    if (sent >= old_plen) return;
    const new_plen = old_plen - sent;
    const old_frame_len = 9 + old_plen;
    const new_frame_len = 9 + new_plen;
    const base = pending.offset;
    // Move unsent payload down.
    std.mem.copyForwards(u8, pending.wire[base + 9 ..][0..new_plen], rem[9 + sent ..][0..new_plen]);
    // Move trailing frames down.
    const after_old = base + old_frame_len;
    const after_len = pending.end - after_old;
    if (after_len > 0) {
        std.mem.copyForwards(u8, pending.wire[base + new_frame_len ..][0..after_len], pending.wire[after_old..][0..after_len]);
    }
    (Http2.FrameHeader{
        .length = @intCast(new_plen),
        .typ = .data,
        .flags = rem[4],
        .stream_id = frame.header.stream_id,
    }).encode(pending.wire[base..][0..9]);
    pending.end = base + new_frame_len + after_len;
}

// ==== §6  Stream state & live bidi ====

const StreamState = struct {
    header_block: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    headers_done: bool = false,
    end_stream: bool = false,
    method: []u8 = &.{},
    path: []u8 = &.{},
    content_type: []u8 = &.{},
    decoded: ?[]Hpack.Header = null,
    /// Our window for *receiving* on this stream is the framework's advertised
    /// value; the window for *sending* is the peer's `SETTINGS_INITIAL_WINDOW_SIZE`
    /// as of the stream's creation — see `Http2.FlowControlState.initStream`. The
    /// field default is only for the tests that build a `StreamState` directly;
    /// the session passes the peer's number through `init`.
    flow: Http2.FlowControlState = Http2.FlowControlState.initStream(Http2.default_initial_window_size, Http2.default_initial_window_size),
    priority: Http2.PriorityInfo = .{ .exclusive = false, .depends_on = 0, .weight = 15 },
    /// Inbound request-body bytes counted against `InboundLimits.max_body_bytes`
    /// — covers both `data` and the live bidi `grpc_buf`.
    inbound_body_bytes: usize = 0,
    /// Live interleaved bidi pump (headers sent; DATA flushed as messages arrive).
    bidi_live: bool = false,
    grpc_buf: Grpc.GrpcStreamBuffer = undefined,
    grpc_buf_active: bool = false,

    fn init() StreamState {
        return .{ .flow = Http2.FlowControlState.initStream(Http2.default_initial_window_size, Http2.default_initial_window_size) };
    }

    /// A stream opened while the peer's `SETTINGS_INITIAL_WINDOW_SIZE` is
    /// `peer_initial_window`: that is the window its **send** side starts at
    /// (RFC 9113 §6.5.2 — the setting applies to streams opened later too).
    fn initWithPeerWindow(peer_initial_window: u31) StreamState {
        return .{ .flow = Http2.FlowControlState.initStream(Http2.default_initial_window_size, peer_initial_window) };
    }

    pub fn getPriority(self: *const StreamState) Http2.PriorityInfo {
        return self.priority;
    }

    fn deinit(self: *StreamState, allocator: std.mem.Allocator) void {
        self.header_block.deinit(allocator);
        self.data.deinit(allocator);
        if (self.method.len > 0) allocator.free(self.method);
        if (self.path.len > 0) allocator.free(self.path);
        if (self.content_type.len > 0) allocator.free(self.content_type);
        if (self.decoded) |h| Hpack.freeHeaders(allocator, h);
        if (self.grpc_buf_active) self.grpc_buf.deinit();
        self.* = undefined;
    }

    fn ready(self: *const StreamState) bool {
        return self.headers_done and self.end_stream and !self.bidi_live;
    }

    fn appendHeaders(self: *StreamState, allocator: std.mem.Allocator, chunk: []const u8, limit: usize) !void {
        if (self.header_block.items.len + chunk.len > limit) return error.HeaderBlockTooLarge;
        try self.header_block.appendSlice(allocator, chunk);
    }

    fn appendData(self: *StreamState, allocator: std.mem.Allocator, chunk: []const u8, limit: usize) !void {
        if (self.data.items.len + chunk.len > limit) return error.BodyTooLarge;
        try self.data.appendSlice(allocator, chunk);
    }

    fn decodeHeaders(self: *StreamState, allocator: std.mem.Allocator, dec: *Hpack.Decoder) !void {
        if (self.decoded) |old| {
            Hpack.freeHeaders(allocator, old);
            self.decoded = null;
        }
        const headers = try dec.decode(self.header_block.items);
        self.decoded = headers;

        var method: []const u8 = "GET";
        var path: []const u8 = "/";
        var content_type: []const u8 = "";
        for (headers) |h| {
            if (std.mem.eql(u8, h.name, ":method")) method = h.value;
            if (std.mem.eql(u8, h.name, ":path")) path = h.value;
            if (std.mem.eql(u8, h.name, "content-type")) content_type = h.value;
        }
        if (self.method.len > 0) allocator.free(self.method);
        if (self.path.len > 0) allocator.free(self.path);
        if (self.content_type.len > 0) allocator.free(self.content_type);
        self.method = try allocator.dupe(u8, method);
        self.path = try allocator.dupe(u8, path);
        self.content_type = try allocator.dupe(u8, content_type);
    }
};

const LiveFlushCtx = struct {
    writer: *ConnWriter,
    stream_id: u31,
    conn_flow: *Http2.FlowControlState,
    stream_flow: *Http2.FlowControlState,
    conn_max_frame_size: u31,
};

fn onInboundData(
    writer: *ConnWriter,
    allocator: std.mem.Allocator,
    fc: *Http2.FlowControlState,
    window_stream_id: u31,
    size: u31,
) !void {
    if (size == 0) return;
    if (try fc.consumeRecv(size)) |increment| {
        const wu = try Http2.encodeWindowUpdate(allocator, window_stream_id, increment);
        defer allocator.free(wu);
        try writer.write(wu);
    }
}

fn maxOutboundChunk(stream_flow: *Http2.FlowControlState, conn_send_window: u31, conn_max_frame_size: u31) u31 {
    const cap = stream_flow.maxOutboundData(conn_send_window);
    return @min(cap, conn_max_frame_size);
}

fn writeFlowControlledData(
    writer: *ConnWriter,
    conn_flow: *Http2.FlowControlState,
    stream_flow: *Http2.FlowControlState,
    stream_id: u31,
    body: []const u8,
    end_stream: bool,
    conn_max_frame_size: u31,
) !void {
    var off: usize = 0;
    while (off < body.len) {
        const max_chunk = maxOutboundChunk(stream_flow, conn_flow.send_window, conn_max_frame_size);
        if (max_chunk == 0) return error.FlowControlBlocked;
        const end = @min(off + max_chunk, body.len);
        const chunk = body[off..end];
        const is_last = end == body.len and end_stream;
        try writer.writeData(stream_id, chunk, is_last);
        const sent: u31 = @intCast(chunk.len);
        stream_flow.consumeSend(sent);
        conn_flow.consumeSend(sent);
        off = end;
    }
    if (body.len == 0 and end_stream) {
        const max_chunk = maxOutboundChunk(stream_flow, conn_flow.send_window, conn_max_frame_size);
        if (max_chunk == 0) return error.FlowControlBlocked;
        try writer.writeData(stream_id, "", true);
    }
}

fn liveFlushCb(user_ctx: ?*anyopaque, framed: []const u8) anyerror!void {
    const ctx: *LiveFlushCtx = @ptrCast(@alignCast(user_ctx.?));
    try writeFlowControlledData(ctx.writer, ctx.conn_flow, ctx.stream_flow, ctx.stream_id, framed, false, ctx.conn_max_frame_size);
}

fn maybeStartLiveBidi(
    writer: *ConnWriter,
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
    opts: ServeOptions,
) !void {
    if (st.bidi_live) return;
    // The interleaved path is the one gRPC shape that writes its DATA frames as
    // the handler flushes them, i.e. outside `buildStreamResponseWire` — so a
    // `HEAD` must not take it, or the octets would be on the wire before the
    // `no_body` decision could be applied. Those requests go through the batch
    // path instead and get the same DATA-stripping as the other gRPC shapes.
    if (std.mem.eql(u8, st.method, "HEAD")) return;
    const is_grpc = std.mem.indexOf(u8, st.content_type, "application/grpc") != null;
    if (!is_grpc) return;
    const reg = opts.grpc_registry orelse return;
    const method = reg.findMethod(st.path) orelse return;
    if (method.bidi_pump_handler == null) return;

    st.bidi_live = true;
    st.grpc_buf = Grpc.GrpcStreamBuffer.init(allocator);
    st.grpc_buf_active = true;

    // Send response HEADERS early so DATA can interleave.
    var enc = Hpack.Encoder.init(allocator);
    const block = try enc.encodeSmart(&.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    });
    defer allocator.free(block);
    const h = try Http2.encodeHeaders(allocator, stream_id, block, false, true);
    defer allocator.free(h);
    try writer.write(h);
}

fn pumpLiveBidiData(
    writer: *ConnWriter,
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
    conn_flow: *Http2.FlowControlState,
    conn_max_frame_size: u31,
    opts: ServeOptions,
    chunk: []const u8,
) !void {
    const reg = opts.grpc_registry orelse return;
    try st.grpc_buf.append(chunk);
    var flush_ctx = LiveFlushCtx{
        .writer = writer,
        .stream_id = stream_id,
        .conn_flow = conn_flow,
        .stream_flow = &st.flow,
        .conn_max_frame_size = conn_max_frame_size,
    };
    var grpc_writer = Grpc.GrpcStreamWriter.init(allocator);
    defer grpc_writer.deinit();
    grpc_writer.on_flush = liveFlushCb;
    grpc_writer.flush_ctx = &flush_ctx;

    while (try st.grpc_buf.tryNext()) |msg| {
        try reg.pumpBidiMessage(st.path, msg, &grpc_writer);
        if (grpc_writer.message_owned and grpc_writer.status != .OK) break;
    }
}

fn finishLiveBidi(
    writer: *ConnWriter,
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
) !void {
    st.grpc_buf.markEnded();
    const status_str = "0";
    const trailers = try Http2.encodeLiteralHeaderBlock(allocator, &.{
        .{ "grpc-status", status_str },
        .{ "grpc-message", "" },
    });
    defer allocator.free(trailers);
    const h = try Http2.encodeHeaders(allocator, stream_id, trailers, true, true);
    defer allocator.free(h);
    try writer.write(h);
}

fn finishStreamScheduled(
    writer: *ConnWriter,
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
    conn_flow: *Http2.FlowControlState,
    conn_max_frame_size: u31,
    peer_max_header_list: ?u32,
    opts: ServeOptions,
    tree: *Http2.PriorityTree,
    outbound: *OutboundScheduler,
    more_inbound: bool,
) !void {
    try tree.setPriority(stream_id, st.getPriority());
    const wire = try buildStreamResponseWire(allocator, stream_id, st, conn_max_frame_size, peer_max_header_list, opts);
    // enqueue takes ownership of wire (frees on refuse).
    try outbound.enqueue(stream_id, wire, st.flow);
    const budget: usize = if (more_inbound or outbound.pending.count() > 1) 8 else 0;
    try outbound.drain(writer, tree, conn_flow, conn_max_frame_size, budget);
}

fn streamErrorFromAny(err: anyerror) u32 {
    return switch (err) {
        error.PendingStreamsExceeded => Http2.ErrorCode.REFUSED_STREAM,
        error.PendingBytesExceeded => Http2.ErrorCode.ENHANCE_YOUR_CALM,
        else => Http2.ErrorCode.INTERNAL_ERROR,
    };
}

// ==== §7  Response encoding ====

/// Build owned HTTP/2 response wire for a completed stream (HEADERS + DATA + optional trailers).
fn buildStreamResponseWire(
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
    conn_max_frame_size: u31,
    peer_max_header_list: ?u32,
    opts: ServeOptions,
) ![]u8 {
    // A `HEAD` request is answered with the same field section and no body
    // (RFC 9113 §8.2) — see `encodeSiteResponseWire`'s `no_body`. The gRPC
    // wires are the one case the encoder cannot decide for us: they are built
    // inside `extensions/GrpcTransport.zig`, which never sees `:method`, so
    // `grpcWireWithoutBody` applies the same rule to them after the fact.
    const no_body = std.mem.eql(u8, st.method, "HEAD");
    const is_grpc = std.mem.indexOf(u8, st.content_type, "application/grpc") != null;
    if (is_grpc) {
        if (opts.grpc_registry) |reg| {
            const path = st.path;
            if (reg.findMethod(path)) |method| {
                // Every streaming shape funnels its wire here so the `HEAD`
                // rule is applied once, on the one path that leaves this
                // function.
                var grpc_wire: ?[]u8 = null;
                switch (method.method.method_type) {
                    .server_streaming => {
                        var result = try reg.handleHttpServerStream(path, st.data.items, stream_id);
                        defer result.deinit(allocator);
                        if (result.http2_wire) |wire| {
                            result.http2_wire = null;
                            grpc_wire = wire;
                        }
                    },
                    .client_streaming => {
                        var result = try reg.handleHttpClientStream(path, st.data.items, stream_id);
                        defer result.deinit(allocator);
                        if (result.http2_wire) |wire| {
                            result.http2_wire = null;
                            grpc_wire = wire;
                        }
                    },
                    .bidi_streaming => {
                        if (method.bidi_pump_handler != null) {
                            var result = try reg.handleHttpBidiPump(path, st.data.items, stream_id, null);
                            defer result.deinit(allocator);
                            if (result.http2_wire) |wire| {
                                result.http2_wire = null;
                                grpc_wire = wire;
                            }
                        }
                        if (grpc_wire == null) {
                            var result = try reg.handleHttpBidi(path, st.data.items, stream_id);
                            defer result.deinit(allocator);
                            if (result.http2_wire) |wire| {
                                result.http2_wire = null;
                                grpc_wire = wire;
                            }
                        }
                    },
                    .unary => {},
                }
                if (grpc_wire) |wire| return try grpcWireWithoutBody(allocator, wire, no_body);
            }
            var unary = try reg.handleHttpUnary(path, st.data.items);
            defer unary.deinit(allocator);
            const status_str = try std.fmt.allocPrint(allocator, "{d}", .{@backingInt(unary.grpc_status)});
            defer allocator.free(status_str);
            const wire = try Http2.encodeGrpcServerStream(allocator, stream_id, unary.body, status_str, unary.grpc_message);
            return try grpcWireWithoutBody(allocator, wire, no_body);
        }
    }

    if (opts.site_handler) |handler| {
        const hdrs = st.decoded orelse &[_]Hpack.Header{};
        var resp = try handler(opts.site_user_ctx, allocator, st.method, st.path, hdrs, st.data.items);
        defer resp.deinit(allocator);
        const budget = responseHeaderBudget(opts, peer_max_header_list, conn_max_frame_size);
        return try encodeSiteResponseWire(
            allocator,
            stream_id,
            resp.status,
            resp.content_type,
            resp.headers,
            resp.body,
            budget,
            // `HEAD`: the field section of the `GET` response and no body at all
            // (RFC 9110 §9.3.2 for H1, RFC 9113 §8.2 for H2, where the response
            // ends at HEADERS with END_STREAM). `resp.body` is still the entity
            // the handler produced, so a declared `content-length` is judged
            // against what a `GET` would have sent.
            no_body,
        );
    }

    // No site handler: the loop's own 404, with no extras to budget for. A
    // `HEAD` 404 is a field section and nothing else, like every other `HEAD`
    // response on this connection.
    const budget = responseHeaderBudget(opts, peer_max_header_list, conn_max_frame_size);
    return try encodeSiteResponseWire(allocator, stream_id, 404, "text/plain", &.{}, "not found", budget, no_body);
}

/// The gRPC response wire, minus its DATA frames when the request was a `HEAD`.
///
/// A `HEAD` is answered with the field section of the `GET` and no body
/// (RFC 9110 §9.3.2), and on H2 "no body" means no DATA frame at all — not a
/// zero-length one, and not the message octets the client would have to skip.
/// The gRPC wires are built by `extensions/GrpcTransport.zig`, which is handed
/// `:path` and the body but no method, so the decision cannot be taken there;
/// it is taken here, on the wire, for every gRPC shape at once.
///
/// Not asking the registry for a response *instead* is the trap: the gRPC
/// branch would then fall through to the site handler (and its built-in 404),
/// answering a `HEAD` with "not found" on a route that exists. So the registry
/// is invoked exactly as it is for `GET` — same handler, same status — and only
/// the octets are dropped.
///
/// That leaves a **trailers-only** response: the head field section
/// (`:status`, `content-type`) plus the wire's own trailer HEADERS, which
/// carries `grpc-status` / `grpc-message` and already ends the stream. gRPC
/// defines that shape as a legitimate answer (`grpc-status` in the trailer
/// section and no message), so what a `HEAD` gets is a valid empty gRPC
/// response rather than a broken one. `HEAD` is not a method gRPC clients
/// send; this is protocol hygiene, and the field sections are the ones the
/// `GET` would have carried.
fn grpcWireWithoutBody(allocator: std.mem.Allocator, wire: []u8, no_body: bool) ![]u8 {
    if (!no_body) return wire;

    var kept = std.ArrayList(u8).empty;
    errdefer kept.deinit(allocator);
    var off: usize = 0;
    while (off < wire.len) {
        if (off + 9 > wire.len) break;
        const frame = Http2.decodeFrame(wire[off..]) catch break;
        const end = off + 9 + @as(usize, frame.header.length);
        if (end > wire.len) break;
        if (frame.header.typ != .data) try kept.appendSlice(allocator, wire[off..end]);
        off = end;
    }
    // A wire with no DATA frame in it is already the answer (a zero-message
    // response has none), and a wire whose framing this loop could not walk is
    // not this module's to rewrite: hand both back untouched.
    if (off != wire.len or kept.items.len == wire.len) {
        kept.deinit(allocator);
        return wire;
    }
    allocator.free(wire);
    return try kept.toOwnedSlice(allocator);
}

/// Caps on the response header block. The inbound side has the same knobs
/// (`opts.inbound`); this is the response half of the same contract, so a
/// number an operator set to bound requests bounds responses too.
const ResponseHeaderBudget = struct {
    /// `SETTINGS_MAX_HEADER_LIST_SIZE` accounting (RFC 9113 §6.5.2: name +
    /// value + 32 per field). `null` = unbounded.
    max_list_bytes: ?usize = null,
    /// Fields in the block, `:status` and `content-type` included. `null` =
    /// unbounded.
    max_count: ?usize = null,
    /// Peer `SETTINGS_MAX_FRAME_SIZE`. The compressed block leaves as a single
    /// HEADERS frame — this module never emits CONTINUATION — so a block past
    /// this is a frame the peer must reject with FRAME_SIZE_ERROR (RFC 9113
    /// §4.2), which may be answered at connection level. Everything we build
    /// fits it.
    max_block_bytes: usize = 16384,
};

/// The response-side budget: the peer's advertised limits where it has them,
/// ours where the number is ours to choose.
///
/// `0` means "off" on our side (`Hpack.Decoder.setAdvertisedHeaderListSize` and
/// every caller of it read it that way) but "accept no fields" on the peer's
/// side (RFC 9113 §6.5.2), so the two cannot simply be `@min`ed.
fn responseHeaderBudget(opts: ServeOptions, peer_max_header_list: ?u32, conn_max_frame_size: u31) ResponseHeaderBudget {
    const mine: ?usize = if (opts.inbound.max_header_list_bytes == 0) null else opts.inbound.max_header_list_bytes;
    const peer: ?usize = if (peer_max_header_list) |v| v else null;
    const list: ?usize = if (mine) |m|
        if (peer) |p| @min(m, p) else m
    else
        peer;
    return .{
        .max_list_bytes = list,
        .max_count = if (opts.inbound.max_header_count == 0) null else opts.inbound.max_header_count,
        .max_block_bytes = conn_max_frame_size,
    };
}

/// Response fields HTTP/2 does not carry (RFC 9113 §8.2.2, "connection-specific
/// header fields"): forwarding one is a MUST NOT, and a peer that receives one
/// is entitled to treat the response as malformed.
const connection_specific_fields = [_][]const u8{
    "connection",
    "keep-alive",
    "proxy-connection",
    "transfer-encoding",
    "upgrade",
};

/// Why a response field did not reach the wire, for the single `warn` this path
/// emits per response.
const DropReport = struct {
    count: usize = 0,
    first_name: []const u8 = "",
    first_reason: []const u8 = "",

    fn note(self: *DropReport, name: []const u8, reason: []const u8) void {
        // `name` is the caller's slice, never the lowercasing scratch, so it is
        // still the right bytes when the log line is written after the loop.
        if (self.count == 0) {
            self.first_name = name;
            self.first_reason = reason;
        }
        self.count += 1;
    }
};

/// `body` is the entity the handler produced and `no_body` is a `HEAD` request:
/// the field section is built from the entity either way — so a declared
/// `content-length` is still judged against the length a `GET` would have sent —
/// while the octets are dropped and the HEADERS frame carries END_STREAM in
/// place of a DATA frame (RFC 9110 §9.3.2, RFC 9113 §8.2). Sending the body
/// under `HEAD` gives the client bytes it has no reason to skip.
fn encodeSiteResponseWire(
    allocator: std.mem.Allocator,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    extra: []const Hpack.Header,
    body: []const u8,
    budget: ResponseHeaderBudget,
    no_body: bool,
) ![]u8 {
    const status_str = try std.fmt.allocPrint(allocator, "{d}", .{status});
    defer allocator.free(status_str);
    const block = try assembleSiteResponseBlock(allocator, status_str, content_type, extra, body.len, budget);
    defer allocator.free(block);
    // A response with no body ends on its HEADERS frame: the stream is closed
    // there, and a zero-length DATA frame would be a body frame that is not one.
    const h = try Http2.encodeHeaders(allocator, stream_id, block, no_body, true);
    if (no_body) return h;
    defer allocator.free(h);
    const d = try Http2.encodeData(allocator, stream_id, body, true);
    defer allocator.free(d);
    return try std.mem.concat(allocator, u8, &.{ h, d });
}

/// The response header block: the two fields this module owns, then every extra
/// field that HTTP/2 can carry and the budget has room for.
///
/// A field that cannot go on the wire is **dropped with a warn**, never a
/// reason to refuse the response. H1 refuses the whole response for such a
/// field (`writeResponse` answers 500), but that is about representation: an H1
/// message whose value carries CRLF is ambiguous on the wire, so it cannot be
/// sent at all. On H2 the block is length-prefixed, so the field can simply be
/// left out — and refusing would turn a middleware that sets `Connection:
/// keep-alive` (this framework's own `Sse` does) or a legacy handler's wrong
/// `Content-Length` into a 5xx for that route on H2 while H1 serves it. The
/// status line and body are the answer; a dropped field costs the client that
/// field only, and the warn tells the operator which one.
fn assembleSiteResponseBlock(
    allocator: std.mem.Allocator,
    status_str: []const u8,
    content_type: []const u8,
    extra: []const Hpack.Header,
    body_len: usize,
    budget: ResponseHeaderBudget,
) ![]u8 {
    const enc = Hpack.Encoder.init(allocator);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Emitted first and unconditionally: `:status` is mandatory and has to be
    // the first field (RFC 9113 §8.3), and a response whose `content-type` was
    // dropped would leave the client unable to read the body — the extras below
    // are the ones a peer can live without. They still count against the
    // budget, so the counters start at two.
    var list_bytes: usize = 0;
    var fields: usize = 0;
    for ([_]Hpack.Header{
        .{ .name = ":status", .value = status_str },
        .{ .name = "content-type", .value = content_type },
    }) |h| {
        const one = try enc.encodeSmart(&.{h});
        defer allocator.free(one);
        try out.appendSlice(allocator, one);
        list_bytes += h.name.len + h.value.len + 32;
        fields += 1;
    }

    var lower = std.ArrayList(u8).empty;
    defer lower.deinit(allocator);

    var report = DropReport{};
    for (extra, 0..) |h, i| {
        if (h.name.len == 0 or h.name[0] == ':') {
            // Pseudo-headers are the encoder's, and they may not follow regular
            // fields — a handler that set one is not obeyed, it is reported.
            report.note(h.name, "pseudo-header");
            continue;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) continue; // SiteResponse.content_type owns it
        // H2 field names are lowercase (RFC 9113 §8.2.1) and a peer MUST treat
        // `Set-Cookie` as malformed, whatever the handler spelled.
        try lower.resize(allocator, h.name.len);
        for (h.name, lower.items) |c, *dst| dst.* = std.ascii.toLower(c);
        const name = lower.items;

        if (isConnectionSpecific(name)) {
            report.note(h.name, "connection-specific field (RFC 9113 §8.2.2)");
            continue;
        }
        if (!isLowercaseFieldName(name)) {
            report.note(h.name, "not a valid field name");
            continue;
        }
        if (!isFieldValue(h.value)) {
            report.note(h.name, "field value carries CR/LF/NUL or edge whitespace (RFC 9113 §8.2)");
            continue;
        }
        if (std.mem.eql(u8, name, "content-length")) {
            // A mismatch between `content-length` and the DATA octets is a
            // malformed response (§8.1.1), so carry the field only when it
            // agrees with what this response actually sends — which is the
            // whole body on this adapter.
            const declared = std.fmt.parseInt(usize, h.value, 10) catch null;
            if (declared != body_len) {
                report.note(h.name, "content-length disagrees with the body");
                continue;
            }
        }

        const field_bytes = name.len + h.value.len + 32;
        if (budget.max_count) |max| {
            if (fields + 1 > max) {
                report.note(h.name, "past the response header count budget");
                report.count += extra.len - i - 1;
                break;
            }
        }
        if (budget.max_list_bytes) |max| {
            if (list_bytes + field_bytes > max) {
                report.note(h.name, "past the response header list budget");
                report.count += extra.len - i - 1;
                break;
            }
        }
        // The block goes out as one HEADERS frame, so the *encoded* size is
        // what has to fit `SETTINGS_MAX_FRAME_SIZE`. `encodeSmart` is stateless
        // (static table only, no dynamic table), so encoding field by field and
        // concatenating is byte-for-byte the whole-list block.
        const one = try enc.encodeSmart(&.{.{ .name = name, .value = h.value }});
        defer allocator.free(one);
        if (out.items.len + one.len > budget.max_block_bytes) {
            report.note(h.name, "past the peer's SETTINGS_MAX_FRAME_SIZE");
            report.count += extra.len - i - 1;
            break;
        }
        try out.appendSlice(allocator, one);
        list_bytes += field_bytes;
        fields += 1;
    }

    if (report.count > 0) {
        // One line per response, not one per field, and `warn` rather than
        // `err`: the request is answered, and an error-level line makes
        // `scripts/test-runner.zig` fail the whole suite.
        std.log.warn(
            "[h2] {d} response field(s) left off the wire (first: '{s}' — {s})",
            .{ report.count, report.first_name, report.first_reason },
        );
    }

    // The two mandatory fields are the floor: if even they do not fit the
    // peer's frame size, sending them would be a connection error there, so
    // fail the stream instead (the caller answers RST_STREAM). Unreachable with
    // any sane `content-type`, and cheaper to state than to reason about.
    if (out.items.len > budget.max_block_bytes) return error.ResponseHeaderBlockTooLarge;
    return out.toOwnedSlice(allocator);
}

fn isConnectionSpecific(name: []const u8) bool {
    for (connection_specific_fields) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

/// `tchar` (RFC 9110 §5.6.2), lowercased: the only bytes an H2 field name may
/// contain (RFC 9113 §8.2.1 requires the lowercase spelling). Callers pass the
/// lowercased copy, so an uppercase byte here is a name that cannot be sent.
fn isLowercaseFieldName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

/// A field value as HTTP/2 defines it: no CR, LF or NUL, and no leading or
/// trailing SP/HTAB (RFC 9113 §8.2) — a peer MUST treat those as malformed, so
/// forwarding such a field is not carrying the header, it is emitting a
/// malformed response.
fn isFieldValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
    }
    if (value.len > 0) {
        const last = value[value.len - 1];
        if (value[0] == ' ' or value[0] == '\t' or last == ' ' or last == '\t') return false;
    }
    return true;
}

// ==== §8  Frame readers ====

fn readFrame(io: std.Io, stream: std.Io.net.Stream, allocator: std.mem.Allocator) ![]u8 {
    var rbuf: [8192]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var empty: [0]u8 = .{};
    var off: usize = 0;
    const limits: InboundLimits = .{};
    return readFramePrefetch(&r.interface, allocator, &empty, &off, limits.max_frame_size, limits.max_inbound_bytes);
}

/// Read one frame (9-byte header + payload) into an owned buffer.
///
/// `max_frame_size` and `budget_remaining` are checked *before* the payload
/// allocation: the header `length` field reaches 2^24-1 (16 MiB), so allocating
/// on the peer's word alone lets a single frame — or a chain of them — exhaust
/// memory before any handler sees it. The caller answers GOAWAY.
fn readFramePrefetch(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    prefetch: []const u8,
    prefetch_off: *usize,
    max_frame_size: u24,
    budget_remaining: usize,
) ![]u8 {
    var hdr: [9]u8 = undefined;
    try readExactPrefetch(reader, prefetch, prefetch_off, &hdr);
    const header = try Http2.FrameHeader.decode(&hdr);
    if (header.length > max_frame_size) return error.FrameSizeExceeded;
    const total = 9 + @as(usize, header.length);
    if (total > budget_remaining) return error.BudgetExceeded;
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    @memcpy(buf[0..9], &hdr);
    if (header.length > 0) try readExactPrefetch(reader, prefetch, prefetch_off, buf[9..]);
    return buf;
}

fn readExact(io: std.Io, stream: std.Io.net.Stream, buf: []u8) !void {
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var empty: [0]u8 = .{};
    var off: usize = 0;
    try readExactPrefetch(&r.interface, &empty, &off, buf);
}

fn readExactPrefetch(
    reader: *std.Io.Reader,
    prefetch: []const u8,
    prefetch_off: *usize,
    buf: []u8,
) !void {
    var filled: usize = 0;
    const avail = prefetch.len -| prefetch_off.*;
    if (avail > 0) {
        const n = @min(buf.len, avail);
        @memcpy(buf[0..n], prefetch[prefetch_off.* .. prefetch_off.* + n]);
        prefetch_off.* += n;
        filled = n;
    }
    if (filled >= buf.len) return;
    reader.readSliceAll(buf[filled..]) catch |err| switch (err) {
        error.EndOfStream => return error.ConnectionClosed,
        error.ReadFailed => return error.ReadFailed,
    };
}

// ==== §9  Tests ====

test "Hpack decode path via Decoder for site headers" {
    const allocator = std.testing.allocator;
    const block = try Http2.encodeLiteralHeaderBlock(allocator, &.{
        .{ ":method", "GET" },
        .{ ":path", "/health" },
        .{ "content-type", "text/plain" },
    });
    defer allocator.free(block);
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const headers = try dec.decode(block);
    defer Hpack.freeHeaders(allocator, headers);
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    try std.testing.expectEqualStrings(":path", headers[1].name);
    try std.testing.expectEqualStrings("/health", headers[1].value);
}

test "StreamState default priority weight 16 wire 15" {
    var st = StreamState.init();
    const pri = st.getPriority();
    try std.testing.expect(!pri.exclusive);
    try std.testing.expectEqual(@as(u31, 0), pri.depends_on);
    try std.testing.expectEqual(@as(u8, 15), pri.weight);
}

test "PRIORITY frame updates StreamState priority" {
    const allocator = std.testing.allocator;
    const info = Http2.PriorityInfo{ .exclusive = true, .depends_on = 5, .weight = 127 };
    const frame = try Http2.encodePriority(allocator, 3, info);
    defer allocator.free(frame);
    const decoded = try Http2.decodeFrame(frame);
    const pri = try Http2.decodePriority(decoded.payload);
    var st = StreamState.init();
    st.priority = pri;
    const got = st.getPriority();
    try std.testing.expect(got.exclusive);
    try std.testing.expectEqual(@as(u31, 5), got.depends_on);
    try std.testing.expectEqual(@as(u8, 127), got.weight);
}

test "StreamState ready requires headers and end_stream" {
    var st = StreamState.init();
    try std.testing.expect(!st.ready());
    st.headers_done = true;
    try std.testing.expect(!st.ready());
    st.end_stream = true;
    try std.testing.expect(st.ready());
}

test "fillUpgradeStream releases every partial allocation when one fails" {
    const base = std.testing.allocator;
    const headers = [_]Hpack.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-tenant", .value = "acme" },
    };

    // Every allocation of the seeding function in turn: the ones before it
    // succeeded and the ones after it never ran, so what this exercises is the
    // unwind — an allocator that fails at index N has to leave a `StreamState`
    // the caller can still `deinit`, with nothing owned twice and nothing
    // dropped. `base` is the testing allocator, so a missed free fails the run
    // instead of hiding in a counter.
    var failures: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var st = StreamState.init();
        fillUpgradeStream(allocator, &st, .{
            .method = "POST",
            .target = "/upgrade?a=1",
            .authority = "example.test",
            .headers = &headers,
            .body = "hello",
        }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            st.deinit(allocator);
            failures += 1;
            continue;
        };
        // Past the last allocation in the function: nothing failed, so the
        // stream is the whole upgrade request and the loop is done.
        try std.testing.expectEqualStrings("POST", st.method);
        try std.testing.expectEqualStrings("/upgrade?a=1", st.path);
        try std.testing.expectEqualStrings("hello", st.data.items);
        st.deinit(allocator);
        break;
    }

    // Both outcomes were reached: at least one allocation was refused, and the
    // loop ran off the end of the function's allocations.
    try std.testing.expect(failures > 0);
    try std.testing.expect(fail_index < 64);
}

test "inbound DATA decrements conn and stream recv windows" {
    var conn = Http2.FlowControlState.init(Http2.default_initial_window_size);
    var stream = Http2.FlowControlState.init(Http2.default_initial_window_size);
    const size: u31 = 1000;
    _ = try conn.consumeRecv(size);
    _ = try stream.consumeRecv(size);
    try std.testing.expectEqual(Http2.default_initial_window_size - size, conn.recv_window);
    try std.testing.expectEqual(Http2.default_initial_window_size - size, stream.recv_window);
}

test "WINDOW_UPDATE increments send window on conn and stream" {
    var conn = Http2.FlowControlState.init(Http2.default_initial_window_size);
    var stream = Http2.FlowControlState.init(Http2.default_initial_window_size);
    conn.send_window = 0;
    stream.send_window = 0;
    const increment: u31 = 8192;
    try conn.applyWindowUpdate(increment);
    try stream.applyWindowUpdate(increment);
    try std.testing.expectEqual(increment, conn.send_window);
    try std.testing.expectEqual(increment, stream.send_window);
}

test "outbound DATA chunk clamped by send windows" {
    var conn = Http2.FlowControlState.init(Http2.default_initial_window_size);
    var stream = Http2.FlowControlState.init(Http2.default_initial_window_size);
    conn.send_window = 5000;
    stream.send_window = 3000;
    try std.testing.expectEqual(@as(u31, 3000), stream.maxOutboundData(conn.send_window));
    stream.consumeSend(3000);
    conn.consumeSend(3000);
    // Stream window exhausted; conn still has 2000 but this stream cannot send.
    try std.testing.expectEqual(@as(u31, 0), stream.maxOutboundData(conn.send_window));
    try std.testing.expectEqual(@as(u31, 2000), conn.send_window);
}

test "PriorityTree pickNext favors high-weight among ready streams" {
    const allocator = std.testing.allocator;
    var tree = Http2.PriorityTree.init(allocator);
    defer tree.deinit();
    try tree.setPriority(1, .{ .exclusive = false, .depends_on = 0, .weight = 0 });
    try tree.setPriority(3, .{ .exclusive = false, .depends_on = 0, .weight = 255 });
    var hi: usize = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if ((try tree.pickNext(&.{ 1, 3 })).? == 3) hi += 1;
    }
    try std.testing.expect(hi >= 24);
}

test "encodeSiteResponseWire is headers then data" {
    const allocator = std.testing.allocator;
    const wire = try encodeSiteResponseWire(allocator, 7, 200, "text/plain", &.{}, "ok", .{}, false);
    defer allocator.free(wire);
    const f0 = try Http2.decodeFrame(wire);
    try std.testing.expectEqual(Http2.FrameType.headers, f0.header.typ);
    try std.testing.expectEqual(@as(u31, 7), f0.header.stream_id);
    const f1 = try Http2.decodeFrame(wire[9 + f0.header.length ..]);
    try std.testing.expectEqual(Http2.FrameType.data, f1.header.typ);
    try std.testing.expectEqualStrings("ok", f1.payload);
}

test "encodeSiteResponseWire answers HEAD with END_STREAM and no DATA frame" {
    const allocator = std.testing.allocator;
    const extra = [_]Hpack.Header{.{ .name = "Content-Length", .value = "2" }};
    const wire = try encodeSiteResponseWire(allocator, 1, 200, "text/plain", &extra, "ok", .{}, true);
    defer allocator.free(wire);

    // The whole message is the HEADERS frame: END_STREAM takes the place of the
    // DATA frame, so the client never sees body octets under `HEAD` (RFC 9113
    // §8.2) and the stream still closes.
    const f0 = try Http2.decodeFrame(wire);
    try std.testing.expectEqual(Http2.FrameType.headers, f0.header.typ);
    try std.testing.expect((f0.header.flags & Http2.FrameFlags.end_stream) != 0);
    try std.testing.expectEqual(wire.len, 9 + @as(usize, f0.header.length));

    const hdrs = try decodeSiteResponseFields(allocator, wire);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", firstHeaderValue(hdrs, ":status").?);
    // The entity length, not the zero octets this message carries: a `HEAD`
    // response declares what the `GET` would have sent.
    try std.testing.expectEqualStrings("2", firstHeaderValue(hdrs, "content-length").?);
}

/// Decode the HEADERS frame of a site-response wire and return its fields.
fn decodeSiteResponseFields(allocator: std.mem.Allocator, wire: []const u8) ![]Hpack.Header {
    const f = try Http2.decodeFrame(wire);
    try std.testing.expectEqual(Http2.FrameType.headers, f.header.typ);
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    return dec.decode(f.payload);
}

fn countFields(headers: []const Hpack.Header, name: []const u8) usize {
    var n: usize = 0;
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, name)) n += 1;
    }
    return n;
}

test "encodeSiteResponseWire carries handler fields, lowercased, and only one content-type" {
    const allocator = std.testing.allocator;
    const extra = [_]Hpack.Header{
        .{ .name = "Set-Cookie", .value = "sid=1; HttpOnly" },
        // The dedicated field owns `content-type`: a second one on the wire is
        // a protocol error, so whatever is here loses.
        .{ .name = "Content-Type", .value = "text/html" },
        // Connection-specific (RFC 9113 §8.2.2): a MUST NOT to forward.
        .{ .name = "Connection", .value = "keep-alive" },
        .{ .name = "Transfer-Encoding", .value = "chunked" },
        // Agrees with the body, so it is carried; the mismatch case is below.
        .{ .name = "Content-Length", .value = "2" },
        .{ .name = "Retry-After", .value = "60" },
        // Pseudo-headers are the encoder's own: the SiteResponse status wins.
        .{ .name = ":status", .value = "999" },
        // CRLF in a value is malformed on H2 (§8.2) — the case H1 refuses the
        // whole response for.
        .{ .name = "X-Split", .value = "a\r\nX-Injected: 1" },
        .{ .name = "X-Padded", .value = "v1 " },
    };
    const wire = try encodeSiteResponseWire(allocator, 1, 429, "text/plain", &extra, "ok", .{}, false);
    defer allocator.free(wire);
    const hdrs = try decodeSiteResponseFields(allocator, wire);
    defer Hpack.freeHeaders(allocator, hdrs);

    // The block starts with the status — pseudo-headers may not follow a
    // regular field (RFC 9113 §8.3) — and the handler's fields are all there.
    try std.testing.expectEqualStrings(":status", hdrs[0].name);
    try std.testing.expectEqualStrings("429", hdrs[0].value);
    try std.testing.expectEqualStrings("text/plain", firstHeaderValue(hdrs, "content-type").?);
    try std.testing.expectEqual(@as(usize, 1), countFields(hdrs, "content-type"));
    try std.testing.expectEqualStrings("sid=1; HttpOnly", firstHeaderValue(hdrs, "set-cookie").?);
    try std.testing.expectEqualStrings("60", firstHeaderValue(hdrs, "retry-after").?);
    try std.testing.expectEqualStrings("2", firstHeaderValue(hdrs, "content-length").?);

    try std.testing.expect(firstHeaderValue(hdrs, "connection") == null);
    try std.testing.expect(firstHeaderValue(hdrs, "transfer-encoding") == null);
    try std.testing.expect(firstHeaderValue(hdrs, "x-split") == null);
    try std.testing.expect(firstHeaderValue(hdrs, "x-padded") == null);
    try std.testing.expectEqual(@as(usize, 0), countFields(hdrs, "connection"));
}

test "encodeSiteResponseWire drops a content-length that disagrees with the body" {
    const allocator = std.testing.allocator;
    const extra = [_]Hpack.Header{.{ .name = "Content-Length", .value = "9999" }};
    const wire = try encodeSiteResponseWire(allocator, 1, 200, "text/plain", &extra, "ok", .{}, false);
    defer allocator.free(wire);
    const hdrs = try decodeSiteResponseFields(allocator, wire);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqual(@as(usize, 0), countFields(hdrs, "content-length"));
    // The response itself is untouched: a wrong field costs the field.
    try std.testing.expectEqualStrings("200", firstHeaderValue(hdrs, ":status").?);
    try std.testing.expectEqualStrings("text/plain", firstHeaderValue(hdrs, "content-type").?);
}

test "encodeSiteResponseWire never builds a HEADERS block past the peer's frame size" {
    const allocator = std.testing.allocator;

    var values: [16][512]u8 = undefined;
    var extra: [16]Hpack.Header = undefined;
    for (&values, &extra, 0..) |*v, *h, i| {
        @memset(v, 'x');
        const name = try std.fmt.allocPrint(allocator, "x-bulk-{d}", .{i});
        defer allocator.free(name);
        h.* = .{ .name = try allocator.dupe(u8, name), .value = v };
    }
    defer {
        for (extra) |h| allocator.free(h.name);
    }

    // ~8 KiB of extras against a 600-byte frame cap: the block has to be
    // truncated, and the result still a single, sendable HEADERS frame.
    const cap: usize = 600;
    const wire = try encodeSiteResponseWire(allocator, 1, 200, "text/plain", &extra, "ok", .{ .max_block_bytes = cap }, false);
    defer allocator.free(wire);
    const f = try Http2.decodeFrame(wire);
    try std.testing.expectEqual(Http2.FrameType.headers, f.header.typ);
    try std.testing.expect(f.header.length <= cap);
    try std.testing.expect((f.header.flags & Http2.FrameFlags.end_headers) != 0);

    // What could not be dropped is intact, and the DATA frame still follows.
    const hdrs = try decodeSiteResponseFields(allocator, wire);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", firstHeaderValue(hdrs, ":status").?);
    try std.testing.expectEqualStrings("text/plain", firstHeaderValue(hdrs, "content-type").?);
    try std.testing.expect(countFields(hdrs, "content-type") == 1);
    try std.testing.expect(hdrs.len < extra.len + 2);

    const d = try Http2.decodeFrame(wire[9 + f.header.length ..]);
    try std.testing.expectEqual(Http2.FrameType.data, d.header.typ);
    try std.testing.expectEqualStrings("ok", d.payload);
}

test "encodeSiteResponseWire enforces the response header count and list budgets" {
    const allocator = std.testing.allocator;
    const extra = [_]Hpack.Header{
        .{ .name = "x-one", .value = "1" },
        .{ .name = "x-two", .value = "2" },
    };

    // `:status` + `content-type` + one extra = 3 fields.
    {
        const wire = try encodeSiteResponseWire(allocator, 1, 200, "text/plain", &extra, "ok", .{ .max_count = 3 }, false);
        defer allocator.free(wire);
        const hdrs = try decodeSiteResponseFields(allocator, wire);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqual(@as(usize, 3), hdrs.len);
        try std.testing.expect(firstHeaderValue(hdrs, "content-type") != null);
    }

    // 42 + 54 bytes for the mandatory pair, so a 40-byte extra no longer fits.
    {
        const wire = try encodeSiteResponseWire(allocator, 1, 200, "text/plain", &extra, "ok", .{ .max_list_bytes = 100 }, false);
        defer allocator.free(wire);
        const hdrs = try decodeSiteResponseFields(allocator, wire);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqual(@as(usize, 2), hdrs.len);
        try std.testing.expectEqualStrings("text/plain", firstHeaderValue(hdrs, "content-type").?);
    }
}

test "responseHeaderBudget takes the peer's advertised list size when it is smaller" {
    const opts = ServeOptions{ .inbound = .{ .max_header_list_bytes = 16 * 1024, .max_header_count = 100 } };
    // No advertisement: our own number, `0` meaning "off" (our convention).
    try std.testing.expectEqual(@as(?usize, 16 * 1024), responseHeaderBudget(opts, null, 16384).max_list_bytes);
    const off = ServeOptions{ .inbound = .{ .max_header_list_bytes = 0, .max_header_count = 0 } };
    try std.testing.expectEqual(@as(?usize, null), responseHeaderBudget(off, null, 16384).max_list_bytes);
    try std.testing.expectEqual(@as(?usize, null), responseHeaderBudget(off, null, 16384).max_count);
    // The peer's number wins when it is the smaller one, and *is* the bound
    // when we have none — including 0, which for a peer means "no fields".
    try std.testing.expectEqual(@as(?usize, 4096), responseHeaderBudget(opts, 4096, 16384).max_list_bytes);
    try std.testing.expectEqual(@as(?usize, 16 * 1024), responseHeaderBudget(opts, 64 * 1024, 16384).max_list_bytes);
    try std.testing.expectEqual(@as(?usize, 4096), responseHeaderBudget(off, 4096, 16384).max_list_bytes);
    try std.testing.expectEqual(@as(?usize, 0), responseHeaderBudget(opts, 0, 16384).max_list_bytes);
    // The frame size is the peer's, always.
    try std.testing.expectEqual(@as(usize, 32768), responseHeaderBudget(opts, null, 32768).max_block_bytes);
}

// --- Inbound hardening: RFC 7540 §6.5.2 SETTINGS validation (see `applyPeerSettings`) ---

/// Encode a peer SETTINGS frame and return its payload view (owned by caller's `wire`).
fn settingsPayloadForTest(
    allocator: std.mem.Allocator,
    entries: []const struct { u16, u32 },
    wire: *[]u8,
) ![]const u8 {
    wire.* = try Http2.encodeSettings(allocator, false, entries);
    const frame = try Http2.decodeFrame(wire.*);
    return frame.payload;
}

test "SETTINGS INITIAL_WINDOW_SIZE above 2^31-1 is a connection error, not a panic" {
    const allocator = std.testing.allocator;
    var conn_flow = Http2.FlowControlState.init(Http2.default_initial_window_size);

    var wire: []u8 = undefined;
    const payload = try settingsPayloadForTest(allocator, &.{
        .{ Http2.SettingsId.initial_window_size, 0x8000_0000 },
    }, &wire);
    defer allocator.free(wire);

    // The wire value is a u32; narrowing it without a range check aborts the
    // process (`panic: integer does not fit in destination type`) before any
    // GOAWAY can be sent.
    try std.testing.expectError(error.FlowControlOverflow, applyPeerSettings(&conn_flow, payload));
    try std.testing.expectEqual(Http2.ErrorCode.FLOW_CONTROL_ERROR, settingsErrorCode(error.FlowControlOverflow));
    try std.testing.expectEqual(Http2.default_initial_window_size, conn_flow.send_window);

    // 2^31-1 itself is the documented maximum and must still be accepted.
    var wire_max: []u8 = undefined;
    const payload_max = try settingsPayloadForTest(allocator, &.{
        .{ Http2.SettingsId.initial_window_size, std.math.maxInt(u31) },
    }, &wire_max);
    defer allocator.free(wire_max);
    const applied = try applyPeerSettings(&conn_flow, payload_max);
    try std.testing.expectEqual(@as(u31, std.math.maxInt(u31)), applied.initial_window_size.?);
}

test "SETTINGS MAX_FRAME_SIZE outside [2^14, 2^24-1] is a protocol error" {
    const allocator = std.testing.allocator;
    var conn_flow = Http2.FlowControlState.init(Http2.default_initial_window_size);

    var too_small: []u8 = undefined;
    const small = try settingsPayloadForTest(allocator, &.{
        .{ Http2.SettingsId.max_frame_size, 16383 },
    }, &too_small);
    defer allocator.free(too_small);
    try std.testing.expectError(error.InvalidFrameSize, applyPeerSettings(&conn_flow, small));
    try std.testing.expectEqual(Http2.ErrorCode.PROTOCOL_ERROR, settingsErrorCode(error.InvalidFrameSize));

    var too_big: []u8 = undefined;
    const big = try settingsPayloadForTest(allocator, &.{
        .{ Http2.SettingsId.max_frame_size, 16777216 },
    }, &too_big);
    defer allocator.free(too_big);
    try std.testing.expectError(error.InvalidFrameSize, applyPeerSettings(&conn_flow, big));

    // In-range values are applied to the outbound frame cap.
    var ok_wire: []u8 = undefined;
    const ok = try settingsPayloadForTest(allocator, &.{
        .{ Http2.SettingsId.max_frame_size, 65536 },
    }, &ok_wire);
    defer allocator.free(ok_wire);
    const applied = try applyPeerSettings(&conn_flow, ok);
    try std.testing.expectEqual(@as(u31, 65536), applied.max_frame_size.?);
}

test "SETTINGS payload not a multiple of 6 keeps the FRAME_SIZE_ERROR mapping" {
    var conn_flow = Http2.FlowControlState.init(Http2.default_initial_window_size);
    const bad = [_]u8{ 0x00, 0x04, 0x00 };
    try std.testing.expectError(error.InvalidSettingsPayload, applyPeerSettings(&conn_flow, &bad));
    try std.testing.expectEqual(Http2.ErrorCode.FRAME_SIZE_ERROR, settingsErrorCode(error.InvalidSettingsPayload));
}

test "OutboundScheduler refuses over pending stream/byte caps" {
    const allocator = std.testing.allocator;
    const flow = Http2.FlowControlState.init(Http2.default_initial_window_size);

    var by_streams = OutboundScheduler.init(allocator, 1, 1024 * 1024);
    defer by_streams.deinit();
    try by_streams.enqueue(1, try allocator.dupe(u8, "aaaa"), flow);
    try std.testing.expectError(error.PendingStreamsExceeded, by_streams.enqueue(3, try allocator.dupe(u8, "bbbb"), flow));

    var by_bytes = OutboundScheduler.init(allocator, 64, 8);
    defer by_bytes.deinit();
    try std.testing.expectError(error.PendingBytesExceeded, by_bytes.enqueue(1, try allocator.alloc(u8, 32), flow));
}

test "shrinkDataFrameInPlace keeps remaining DATA without realloc" {
    const allocator = std.testing.allocator;
    const wire = try Http2.encodeData(allocator, 7, "abcdefghij", true);
    var pending = PendingOutbound{
        .wire = wire,
        .end = wire.len,
        .offset = 0,
        .flow = Http2.FlowControlState.init(Http2.default_initial_window_size),
    };
    defer pending.deinit(allocator);

    shrinkDataFrameInPlace(&pending, 4);
    const frame = try Http2.decodeFrame(pending.remaining());
    try std.testing.expectEqual(Http2.FrameType.data, frame.header.typ);
    try std.testing.expectEqualStrings("efghij", frame.payload);
    try std.testing.expect((frame.header.flags & Http2.FrameFlags.end_stream) != 0);
}

test "streamErrorFromAny maps outbound backpressure codes" {
    try std.testing.expectEqual(Http2.ErrorCode.REFUSED_STREAM, streamErrorFromAny(error.PendingStreamsExceeded));
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, streamErrorFromAny(error.PendingBytesExceeded));
    try std.testing.expectEqual(Http2.ErrorCode.INTERNAL_ERROR, streamErrorFromAny(error.OutOfMemory));
}

// --- §10  End-to-end: a real prior-knowledge h2c session over loopback ---
//
// The frame-level unit tests above pin the individual gates; these drive the
// whole connection loop (`serveAfterPrefacePrefetchReader`, the entry
// `Server.zig:2803` uses) so a regression in the loop's wiring — not just in a
// helper — shows up. Before the hardening, each of these aborted the process
// (`panic: integer overflow` / `integer does not fit in destination type`).

/// Feed `frames` to one real h2c session (preface already consumed) and return
/// the server's reply bytes in `out`. Client I/O is raw `posix` so the test never
/// shares the io scheduler across threads (same reason as the WS e2e test).
/// One loopback h2 exchange, retried **once** when the frame the caller is about
/// to look for is missing from the reply.
///
/// The retry is for a loaded CI runner, not for a defect: this is a spawn + accept
/// + exchange that takes microseconds when the machine is idle, and the read
/// budget below is a hang budget (3 s). Observed once on a loaded macOS runner
/// (`no GOAWAY → loop did not answer`, green on the rerun and in two local full
/// runs). A real defect answers nothing on *both* attempts, so the retry cannot
/// hide one — the same shape as `PrecisionTimer`'s capable-host retry.
///
/// `expect == null` means "the caller looks at the bytes, not at a frame" (the
/// deadline-hook tests): no retry.
/// Counts the retries below, so a test can assert the retry *happened* rather
/// than believe it did (a counter, not a log line: `scripts/test-runner.zig`
/// counts `err`-level logs as failures, and there is no log-capturing API here).
var h2_exchange_retries: usize = 0;

fn runLoopbackH2Session(opts: ServeOptions, frames: []const u8, out: []u8, expect: ?Http2.FrameType) !usize {
    const first = try runLoopbackH2Exchange(opts, frames, out);
    if (expect == null) return first;
    if (findFrameInReply(out[0..first], expect.?, 0) != null) return first;
    h2_exchange_retries += 1;
    std.log.warn("[h2 test] no {s} in the first exchange ({d} bytes back); retrying once — a loaded runner, not a verdict", .{ @tagName(expect.?), first });
    return runLoopbackH2Exchange(opts, frames, out);
}

fn runLoopbackH2Exchange(opts: ServeOptions, frames: []const u8, out: []u8) !usize {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    const Ctx = struct {
        listener: *std.Io.net.Server,
        opts: ServeOptions,
        fn run(self: *@This()) void {
            const accepted = self.listener.accept(std.testing.io) catch return;
            defer accepted.close(std.testing.io);
            serveAfterPrefacePrefetchReader(std.testing.io, accepted, std.testing.allocator, self.opts, &.{}, null) catch |err| {
                std.log.debug("[h2] test session ended: {s}", .{@errorName(err)});
            };
        }
    };
    var ctx = Ctx{ .listener = &listener, .opts = opts };
    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, Ctx.run, .{&ctx});
    defer th.join();

    const server_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try server_addr.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);

    try @import("../core/sockread.zig").writeFull(stream, frames);
    // Half-close: the server's frame loop sees EOF after our frames, but we can
    // still read the answer it wrote first.
    _ = std.c.shutdown(stream.socket.handle, std.c.SHUT.WR);

    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 3000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(stream.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// First frame of `typ` (any stream when `stream_id` is 0) in a server reply.
fn findFrameInReply(wire: []const u8, typ: Http2.FrameType, stream_id: u31) ?Http2.Frame {
    var off: usize = 0;
    while (off + 9 <= wire.len) {
        const frame = Http2.decodeFrame(wire[off..]) catch return null;
        if (frame.header.typ == typ and (stream_id == 0 or frame.header.stream_id == stream_id)) return frame;
        off += 9 + @as(usize, frame.header.length);
    }
    return null;
}

test "the h2 loopback helper retries once when the expected frame is missing, and returns the retry's reply" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var payload: [65536]u8 = @splat(0x41);
    const oversized = try Http2.encodeData(allocator, 1, &payload, false);
    defer allocator.free(oversized);

    // `.push_promise` is never in this reply, so the retry runs: the counter is
    // what proves it (the two attempts both answer, so nothing else would show
    // it), and what comes back is the *second* attempt's bytes — a caller's own
    // `orelse` is still what reports a missing frame, on both attempts.
    var out: [4096]u8 = undefined;
    h2_exchange_retries = 0;
    const n = try runLoopbackH2Session(.{}, oversized, &out, .push_promise);
    try std.testing.expectEqual(@as(usize, 1), h2_exchange_retries);
    try std.testing.expect(findFrameInReply(out[0..n], .goaway, 0) != null);

    // And with the frame it does answer, there is no retry at all.
    h2_exchange_retries = 0;
    const m = try runLoopbackH2Session(.{}, oversized, &out, .goaway);
    try std.testing.expectEqual(@as(usize, 0), h2_exchange_retries);
    try std.testing.expect(findFrameInReply(out[0..m], .goaway, 0) != null);
}

test "h2 session answers GOAWAY FRAME_SIZE_ERROR for an oversized inbound DATA frame" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // One 65536-byte DATA frame on an idle stream — the reviewer's probe: no
    // stream state, no prior negotiation.
    var payload: [65536]u8 = @splat(0x41);
    const oversized = try Http2.encodeData(allocator, 1, &payload, false);
    defer allocator.free(oversized);

    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{}, oversized, &out, .goaway);
    const goaway = findFrameInReply(out[0..n], .goaway, 0) orelse
        return error.TestUnexpectedResultWithMessage; // no GOAWAY → loop did not answer
    const info = try Http2.decodeGoAway(goaway.payload);
    try std.testing.expectEqual(Http2.ErrorCode.FRAME_SIZE_ERROR, info.error_code);
    try std.testing.expect(findFrameInReply(out[0..n], .rst_stream, 0) == null);
}

test "h2 session answers GOAWAY PROTOCOL_ERROR for an even client stream id" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var enc = Hpack.Encoder.init(allocator);
    const block = try enc.encodeSmart(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "localhost" },
    });
    defer allocator.free(block);
    // Stream 4 is server-initiated space (RFC 7540 §5.1.1).
    const headers = try Http2.encodeHeaders(allocator, 4, block, true, true);
    defer allocator.free(headers);

    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{}, headers, &out, .goaway);
    const goaway = findFrameInReply(out[0..n], .goaway, 0) orelse return error.TestUnexpectedResultWithMessage;
    const info = try Http2.decodeGoAway(goaway.payload);
    try std.testing.expectEqual(Http2.ErrorCode.PROTOCOL_ERROR, info.error_code);
}

test "h2 session answers GOAWAY COMPRESSION_ERROR for a header block the decoder rejects" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // `3f e2 1f` is a Dynamic Table Size Update asking for 4097 — above the
    // advertised/default 4096, so the decoder rejects it. That rejection is a
    // *connection* error (RFC 7541 §4.2): the table state has diverged, so the
    // answer has to be GOAWAY, not RST_STREAM.
    const block = [_]u8{ 0x3f, 0xe2, 0x1f };
    const headers = try Http2.encodeHeaders(allocator, 1, &block, true, true);
    defer allocator.free(headers);

    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{}, headers, &out, .goaway);
    const goaway = findFrameInReply(out[0..n], .goaway, 0) orelse return error.TestUnexpectedResultWithMessage;
    const info = try Http2.decodeGoAway(goaway.payload);
    try std.testing.expectEqual(Http2.ErrorCode.COMPRESSION_ERROR, info.error_code);
    try std.testing.expect(findFrameInReply(out[0..n], .rst_stream, 0) == null);
}

test "h2 session still serves a normal request on stream 1" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var enc = Hpack.Encoder.init(allocator);
    const block = try enc.encodeSmart(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/health" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "localhost" },
    });
    defer allocator.free(block);
    // No site_handler → the loop's built-in 404 body, but a complete response.
    const headers = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(headers);

    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{}, headers, &out, .headers);
    const reply = out[0..n];
    try std.testing.expect(findFrameInReply(reply, .goaway, 0) == null);
    try std.testing.expect(findFrameInReply(reply, .rst_stream, 0) == null);
    const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("not found", data.payload);
    try std.testing.expect((data.header.flags & Http2.FrameFlags.end_stream) != 0);
}

test "h2 session refuses the stream past the advertised MAX_CONCURRENT_STREAMS" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var enc = Hpack.Encoder.init(allocator);
    const block = try enc.encodeSmart(&.{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/hold" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "localhost" },
    });
    defer allocator.free(block);

    // HEADERS without END_STREAM: every stream stays open, so the loop must hold
    // state for all of them and stop at the 100 it advertised.
    var script = std.ArrayList(u8).empty;
    defer script.deinit(allocator);
    const max: u32 = test_limits.max_concurrent_streams;
    var sid: u31 = 1;
    var i: u32 = 0;
    while (i < max + 1) : (i += 1) {
        const h = try Http2.encodeHeaders(allocator, sid, block, false, true);
        defer allocator.free(h);
        try script.appendSlice(allocator, h);
        sid += 2;
    }
    const refused_sid: u31 = 1 + 2 * max;

    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{}, script.items, &out, .rst_stream);
    const rst = findFrameInReply(out[0..n], .rst_stream, refused_sid) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqual(Http2.ErrorCode.REFUSED_STREAM, try Http2.decodeRstStream(rst.payload));
    try std.testing.expect(findFrameInReply(out[0..n], .rst_stream, 1) == null);
}

// The other error arm of the h2c upgrade: the stream enters the session's map
// *before* it is filled from the HTTP/1.1 request, so an allocation failure
// while filling it has to end the session rather than answer a half-built
// stream 1. Driven with a `FailingAllocator` over the session's allocations,
// with the testing allocator as its base — so what this pins is that the arm is
// reached, that the session ends on the refusal, and that a refusal before the
// response was encoded leaves stream 1 unanswered (nothing leaked, nothing
// freed twice: `base` is the testing allocator). The `errdefer`'s own effect —
// dropping the map entry — is not observable on its own: the session-level
// `defer` over `streams` frees every value in that same map on the same error
// path.
test "serveAfterUpgrade: a refused seeding allocation ends the session with no stream 1 answer" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const base = std.testing.allocator;

    const listen_addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try listen_addr.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);
    const port = listener.socket.address.getPort();

    // Enough fields that the seeding function has a window of allocations to
    // fail in, rather than a single one.
    const headers = [_]Hpack.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-tenant", .value = "acme" },
        .{ .name = "x-extra", .value = "1" },
    };

    // Calibration: a session whose allocator never fails has to answer stream 1
    // (that is the harness being the real upgrade path, not a dead end), and the
    // number of allocations it performs is what bounds the sweep below — a fixed
    // bound either stops short of the seeding window or runs past the end of the
    // walk, and a sweep that never fails anything proves nothing.
    var counting = std.testing.FailingAllocator.init(base, .{});
    var calibrated_answered = false;
    _ = upgradeSessionOutcome(&listener, port, counting.allocator(), &headers, &calibrated_answered);
    try std.testing.expect(calibrated_answered);
    const walk_allocations = counting.allocations;
    try std.testing.expect(walk_allocations > 1);

    var refused_before_answer: usize = 0;
    var refused_after_answer: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < walk_allocations) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
        var answered = false;
        const outcome = upgradeSessionOutcome(&listener, port, failing.allocator(), &headers, &answered);
        if (outcome) |err| {
            // The only error a refused allocation produces out of the session.
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (answered) refused_after_answer += 1 else refused_before_answer += 1;
        }
    }

    // The seeding window is inside the sweep: a refusal that ended the session
    // before the response was encoded is the arm under test being driven.
    try std.testing.expect(refused_before_answer > 0);
    // A refusal before the response was encoded never answered stream 1 — the
    // other half of the same property (a half-built stream is not dispatched).
    try std.testing.expect(refused_before_answer >= refused_after_answer);
}

/// One `serveAfterUpgrade` exchange on a fresh loopback connection: the client
/// sends the preface and half-closes, the server side runs the session with
/// `allocator` (what the seeding-failure sweep above varies). Returns the
/// session's error, `null` when it ended cleanly, and reports through `answered`
/// whether a response HEADERS frame for stream 1 reached the client.
fn upgradeSessionOutcome(
    listener: *std.Io.net.Server,
    port: u16,
    allocator: std.mem.Allocator,
    headers: []const Hpack.Header,
    answered: *bool,
) ?anyerror {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return error.UpgradeHarnessFailed;
    var client = addr.connect(std.testing.io, .{ .mode = .stream }) catch return error.UpgradeHarnessFailed;
    defer client.close(std.testing.io);
    const server_side = listener.accept(std.testing.io) catch return error.UpgradeHarnessFailed;
    defer server_side.close(std.testing.io);

    // No HTTP/1.1 reader to reuse here, so the session reads the preface off the
    // wire; the half-close is what ends its frame loop.
    @import("../core/sockread.zig").writeFull(client, Http2.connection_preface) catch return error.UpgradeHarnessFailed;
    _ = std.c.shutdown(client.socket.handle, std.c.SHUT.WR);

    const outcome: ?anyerror = if (serveAfterUpgrade(std.testing.io, server_side, allocator, .{ .read_idle_timeout_ms = 0 }, null, .{
        .method = "GET",
        .target = "/seed",
        .authority = "localhost",
        .headers = headers,
    })) |_| null else |err| err;

    var out: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = client.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 1000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(client.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    answered.* = findFrameInReply(out[0..total], .headers, 1) != null;
    return outcome;
}

test "readFramePrefetch consumes SETTINGS then HEADERS from leftover buffer" {
    const allocator = std.testing.allocator;
    const settings = try Http2.encodeSettings(allocator, false, &.{.{ 0x3, 100 }});
    defer allocator.free(settings);
    var enc = Hpack.Encoder.init(allocator);
    const block = try enc.encodeSmart(&.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/ping" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":authority", .value = "localhost" },
    });
    defer allocator.free(block);
    const headers = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(headers);
    const leftover = try std.mem.concat(allocator, u8, &.{ settings, headers });
    defer allocator.free(leftover);

    // Reader that immediately EOFs — all frames must come from prefetch.
    var r = std.Io.Reader.fixed(&.{});
    var off: usize = 0;

    const f0 = try readFramePrefetch(&r, allocator, leftover, &off, test_limits.max_frame_size, test_limits.max_inbound_bytes);
    defer allocator.free(f0);
    const d0 = try Http2.decodeFrame(f0);
    try std.testing.expectEqual(Http2.FrameType.settings, d0.header.typ);

    const f1 = try readFramePrefetch(&r, allocator, leftover, &off, test_limits.max_frame_size, test_limits.max_inbound_bytes);
    defer allocator.free(f1);
    const d1 = try Http2.decodeFrame(f1);
    try std.testing.expectEqual(Http2.FrameType.headers, d1.header.typ);
    try std.testing.expectEqual(@as(u31, 1), d1.header.stream_id);
    try std.testing.expect((d1.header.flags & Http2.FrameFlags.end_stream) != 0);
    try std.testing.expectEqual(leftover.len, off);
}

// --- Inbound hardening: frame-size gate, byte budget, per-stream caps, stream lifecycle ---

/// Defaults used by the inbound-limit tests.
const test_limits: InboundLimits = .{};

test "readFramePrefetch rejects an inbound frame above SETTINGS_MAX_FRAME_SIZE" {
    const allocator = std.testing.allocator;
    // 65536 > the 16384 default: one frame, one shot, no prior stream needed.
    var big: [65536]u8 = @splat(0);
    const oversized = try Http2.encodeData(allocator, 1, &big, false);
    defer allocator.free(oversized);

    var r = std.Io.Reader.fixed(&.{});
    var off: usize = 0;
    try std.testing.expectError(
        error.FrameSizeExceeded,
        readFramePrefetch(&r, allocator, oversized, &off, test_limits.max_frame_size, test_limits.max_inbound_bytes),
    );

    // Exactly at the advertised limit is still accepted, and reads through.
    var at_limit_payload: [16384]u8 = @splat(0);
    const at_limit = try Http2.encodeData(allocator, 1, &at_limit_payload, false);
    defer allocator.free(at_limit);
    var off2: usize = 0;
    const ok = try readFramePrefetch(&r, allocator, at_limit, &off2, test_limits.max_frame_size, test_limits.max_inbound_bytes);
    defer allocator.free(ok);
    try std.testing.expectEqual(@as(usize, at_limit.len), ok.len);
}

test "readFramePrefetch enforces the connection byte budget before allocating" {
    const allocator = std.testing.allocator;
    const frame = try Http2.encodeData(allocator, 1, "0123456789", false);
    defer allocator.free(frame);

    var r = std.Io.Reader.fixed(&.{});
    var off: usize = 0;
    // Budget is smaller than header + payload → refuse, do not read the payload.
    try std.testing.expectError(
        error.BudgetExceeded,
        readFramePrefetch(&r, allocator, frame, &off, test_limits.max_frame_size, frame.len - 1),
    );

    var off2: usize = 0;
    const ok = try readFramePrefetch(&r, allocator, frame, &off2, test_limits.max_frame_size, frame.len);
    defer allocator.free(ok);
    try std.testing.expectEqual(frame.len, ok.len);
}

test "StreamState append caps header block and body bytes" {
    const allocator = std.testing.allocator;
    var st = StreamState.init();
    defer st.deinit(allocator);

    try st.appendHeaders(allocator, "abcd", 4);
    try std.testing.expectError(error.HeaderBlockTooLarge, st.appendHeaders(allocator, "e", 4));
    try std.testing.expectEqualStrings("abcd", st.header_block.items);

    try st.appendData(allocator, "xyz", 3);
    try std.testing.expectError(error.BodyTooLarge, st.appendData(allocator, "w", 3));
    try std.testing.expectEqualStrings("xyz", st.data.items);
}

test "inbound limit errors map to ENHANCE_YOUR_CALM, OOM stays INTERNAL_ERROR" {
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, inboundLimitCode(error.HeaderBlockTooLarge));
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, inboundLimitCode(error.BodyTooLarge));
    try std.testing.expectEqual(Http2.ErrorCode.INTERNAL_ERROR, inboundLimitCode(error.OutOfMemory));
}

test "client stream ids must be odd and strictly increasing" {
    // First stream on a connection.
    try validateNewClientStreamId(1, 0);
    try validateNewClientStreamId(5, 3);
    // Server-initiated (even) ids never arrive as client requests (RFC 7540 §5.1.1).
    try std.testing.expectError(error.InvalidStreamId, validateNewClientStreamId(2, 0));
    try std.testing.expectError(error.InvalidStreamId, validateNewClientStreamId(4, 3));
    // Re-use of a spent id, and going backwards.
    try std.testing.expectError(error.InvalidStreamId, validateNewClientStreamId(3, 3));
    try std.testing.expectError(error.InvalidStreamId, validateNewClientStreamId(1, 3));
}

test "advertised MAX_CONCURRENT_STREAMS is enforced" {
    try checkConcurrentStreams(0, 100);
    try checkConcurrentStreams(99, 100);
    try std.testing.expectError(error.TooManyStreams, checkConcurrentStreams(100, 100));
    try std.testing.expectError(error.TooManyStreams, checkConcurrentStreams(101, 100));
}

// --- Header-list budget (RFC 9113 §6.5.2) + session idle deadline, end to end ---

/// HPACK string literal: length prefix + bytes, no Huffman. Test-local because
/// `Hpack.Encoder` never emits a dynamic-table reference, and the block below
/// has to: a client that indexes a name it just inserted is what makes "the
/// decoder kept its table in step past the budget" observable at the session
/// level. Short strings only, so the length-prefix path is one byte.
fn appendHpackString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    std.debug.assert(s.len < 127);
    try buf.append(allocator, @intCast(s.len));
    try buf.appendSlice(allocator, s);
}

/// `GET <path>` pseudo-headers: static indexes for `:method` / `:scheme`,
/// literal values for `:authority` / `:path`. 178 bytes on the header-list
/// budget for `/echo` (42 + 43 + 51 + 42).
fn appendPseudoHeaders(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const u8) !void {
    try buf.append(allocator, 0x82); // :method GET — static index 2
    try buf.append(allocator, 0x86); // :scheme http — static index 6
    try buf.append(allocator, 0x01); // literal, name from static index 1 (:authority)
    try appendHpackString(buf, allocator, "localhost");
    try buf.append(allocator, 0x04); // literal, name from static index 4 (:path)
    try appendHpackString(buf, allocator, path);
}

/// Site handler that answers with the request's `x-big` value, so the body
/// says which slices the decoder actually produced.
fn echoBigHeader(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    headers: []const Hpack.Header,
    body: []const u8,
) anyerror!SiteResponse {
    _ = method;
    _ = path;
    _ = body;
    var value: []const u8 = "none";
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "x-big")) value = h.value;
    }
    return .{ .status = 200, .content_type = "text/plain", .body = try allocator.dupe(u8, value) };
}

/// Stand-in for a transport deadline: records what the loop asked for. The
/// session runs on another thread and the helper joins it before returning, so
/// reading these fields afterwards is ordered by the join.
const FakeDeadline = struct {
    arms: usize = 0,
    last_ms: u32 = 0,
    cleared: bool = false,

    fn arm(ctx: *anyopaque, ms: u32) void {
        const self: *FakeDeadline = @ptrCast(@alignCast(ctx));
        self.arms += 1;
        self.last_ms = ms;
    }

    fn clear(ctx: *anyopaque) void {
        const self: *FakeDeadline = @ptrCast(@alignCast(ctx));
        self.cleared = true;
    }

    fn timedOut(ctx: *anyopaque) bool {
        _ = ctx;
        return false;
    }

    fn handle(self: *FakeDeadline) ReadDeadline {
        return .{ .ctx = self, .arm_ms = arm, .clear = clear, .timed_out = timedOut };
    }
};

test "h2 session advertises SETTINGS_MAX_HEADER_LIST_SIZE from the options" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const advertised: u32 = 4096;
    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{ .inbound = .{ .max_header_list_bytes = advertised } }, &.{}, &out, .settings);
    const reply = out[0..n];

    var seen = false;
    var off: usize = 0;
    while (off + 9 <= reply.len) {
        const f = Http2.decodeFrame(reply[off..]) catch break;
        if (f.header.typ == .settings) {
            const entries = try Http2.decodeSettings(allocator, f.payload);
            defer allocator.free(entries);
            for (entries) |s| {
                if (s.id == Http2.SettingsId.max_header_list_size) {
                    // The advertised value is the one we enforce, not a
                    // hard-coded default: the peer has to be able to tell.
                    try std.testing.expectEqual(advertised, s.value);
                    seen = true;
                }
            }
        }
        off += 9 + @as(usize, f.header.length);
    }
    try std.testing.expect(seen);
}

test "h2 session answers a header list past the advertised size with one RST" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // 250 bytes: one request (178) fits, one request plus a 60-byte field (275)
    // does not.
    var script = std.ArrayList(u8).empty;
    defer script.deinit(allocator);

    // Stream 1 — inserts `x-big` into the dynamic table (index 62), then blows
    // the budget on that very field.
    var block1 = std.ArrayList(u8).empty;
    defer block1.deinit(allocator);
    try appendPseudoHeaders(&block1, allocator, "/echo");
    try block1.append(allocator, 0x40); // literal with incremental indexing, new name
    try appendHpackString(&block1, allocator, "x-big");
    try appendHpackString(&block1, allocator, "012345678901234567890123456789012345678901234567890123456789");
    const h1 = try Http2.encodeHeaders(allocator, 1, block1.items, true, true);
    defer allocator.free(h1);
    try script.appendSlice(allocator, h1);

    // Stream 3 — an indexed reference to that entry (name index 62). If the
    // decoder had stopped at the budget instead of finishing the block, the
    // entry would not exist and this would be a connection error, not a
    // response.
    var block3 = std.ArrayList(u8).empty;
    defer block3.deinit(allocator);
    try appendPseudoHeaders(&block3, allocator, "/echo");
    try block3.append(allocator, 0x40 | 62); // literal with incremental indexing, name from dynamic index 62
    try appendHpackString(&block3, allocator, "synced");
    const h3 = try Http2.encodeHeaders(allocator, 3, block3.items, true, true);
    defer allocator.free(h3);
    try script.appendSlice(allocator, h3);

    var out: [8192]u8 = undefined;
    const n = try runLoopbackH2Session(.{
        .inbound = .{ .max_header_list_bytes = 250 },
        .site_handler = echoBigHeader,
    }, script.items, &out, .rst_stream);
    const reply = out[0..n];

    // The over-size list is refused for *that stream*: RST + ENHANCE_YOUR_CALM,
    // no GOAWAY — the block decoded, only the list is too big.
    const rst = findFrameInReply(reply, .rst_stream, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, try Http2.decodeRstStream(rst.payload));
    try std.testing.expect(findFrameInReply(reply, .goaway, 0) == null);

    // …and the connection is healthy: the next stream decodes against the
    // table the refused block left behind.
    const data = findFrameInReply(reply, .data, 3) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("synced", data.payload);
    try std.testing.expect((data.header.flags & Http2.FrameFlags.end_stream) != 0);
}

test "h2 session answers too many header fields with one RST" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var script = std.ArrayList(u8).empty;
    defer script.deinit(allocator);

    // Stream 1 — five fields against a four-field budget.
    var block1 = std.ArrayList(u8).empty;
    defer block1.deinit(allocator);
    try appendPseudoHeaders(&block1, allocator, "/over");
    try block1.append(allocator, 0x00); // literal without indexing, new name
    try appendHpackString(&block1, allocator, "x-extra");
    try appendHpackString(&block1, allocator, "1");
    const h1 = try Http2.encodeHeaders(allocator, 1, block1.items, true, true);
    defer allocator.free(h1);
    try script.appendSlice(allocator, h1);

    // Stream 3 — exactly four, so the bound is a limit and not a blanket refusal.
    var block3 = std.ArrayList(u8).empty;
    defer block3.deinit(allocator);
    try appendPseudoHeaders(&block3, allocator, "/ok");
    const h3 = try Http2.encodeHeaders(allocator, 3, block3.items, true, true);
    defer allocator.free(h3);
    try script.appendSlice(allocator, h3);

    var out: [8192]u8 = undefined;
    // Byte budget off: this test is about the count.
    const n = try runLoopbackH2Session(.{
        .inbound = .{ .max_header_list_bytes = 0, .max_header_count = 4 },
    }, script.items, &out, .rst_stream);
    const reply = out[0..n];

    const rst = findFrameInReply(reply, .rst_stream, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, try Http2.decodeRstStream(rst.payload));
    try std.testing.expect(findFrameInReply(reply, .goaway, 0) == null);

    // No site_handler → the loop's built-in 404 body, but a complete response.
    const data = findFrameInReply(reply, .data, 3) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("not found", data.payload);
}

test "the h2 loop's own 404 answers HEAD with a field section and no body" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // No `site_handler`: this is the 404 the *loop* builds, the one response no
    // handler and no adapter is involved in. `appendPseudoHeaders` (the shape the
    // tests above send) is `GET`, so the `HEAD` block is built explicitly.
    {
        // The `GET` answer first: the 404 entity the `HEAD` response has to
        // describe, and proof that this session reaches the loop's own 404 at
        // all.
        var block = std.ArrayList(u8).empty;
        defer block.deinit(allocator);
        try appendPseudoHeaders(&block, allocator, "/nope");
        const head = try Http2.encodeHeaders(allocator, 1, block.items, true, true);
        defer allocator.free(head);

        var out: [4096]u8 = undefined;
        const n = try runLoopbackH2Session(.{}, head, &out, .data);
        const reply = out[0..n];
        const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
        try std.testing.expectEqualStrings("not found", data.payload);
    }
    {
        const block = try hpackRequestBlock(allocator, "HEAD", "/nope", &.{});
        defer allocator.free(block);
        const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
        defer allocator.free(head);

        var out: [4096]u8 = undefined;
        const n = try runLoopbackH2Session(.{}, head, &out, .headers);
        const reply = out[0..n];

        // No DATA frame at all, and the HEADERS frame closes the stream
        // (RFC 9110 §9.3.2, RFC 9113 §8.2): the client never sees the `not
        // found` octets it has no reason to skip.
        try std.testing.expect(findFrameInReply(reply, .data, 1) == null);
        const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
        try std.testing.expect((hframe.header.flags & Http2.FrameFlags.end_stream) != 0);

        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("404", firstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);
    }
}

test "h2 session arms the read idle deadline and clears it on exit" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var fake = FakeDeadline{};
    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{
        .read_idle_timeout_ms = 30_000,
        .read_deadline = fake.handle(),
    }, &.{}, &out, null);
    _ = n;

    // Armed before the read (that is what lets a silent peer be cut off) and
    // cleared once the session is over, so the deadline does not leak into
    // whatever the connection does next.
    try std.testing.expect(fake.arms > 0);
    try std.testing.expect(fake.last_ms > 0 and fake.last_ms <= 30_000);
    try std.testing.expect(fake.cleared);
}

test "read failure code names the idle peer, not the transport" {
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, readFailureCode(true));
    try std.testing.expectEqual(Http2.ErrorCode.PROTOCOL_ERROR, readFailureCode(false));
}

// --- §10b  End-to-end: the registered-route path (Config → ServeOptions → dispatch) ---
//
// The loopback tests above hand the loop a `ServeOptions` the test built, so
// they cross neither `Server.http2ServeOptions` — the one place where
// `Server.Config` becomes H2 behaviour — nor the router. These drive a real
// `api.Server` (`.port = 0`, `setHttp2Enabled(true)`) with registered routes and
// middleware over prior-knowledge h2c, the only shape that observes that hop.

const api_server = @import("../api/Server.zig");

/// Client side of one prior-knowledge h2c exchange with a running
/// `api_server.Server`: preface, then `frames`, then a half-close so the
/// connection fiber's frame loop sees EOF instead of parking in a read.
fn h2SpeakToServer(port: u16, frames: []const u8, out: []u8) !usize {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);

    try @import("../core/sockread.zig").writeFull(stream, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");
    try @import("../core/sockread.zig").writeFull(stream, frames);
    _ = std.c.shutdown(stream.socket.handle, std.c.SHUT.WR);

    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 3000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(stream.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

/// One HPACK request block: the four pseudo-headers plus `extra`.
fn hpackRequestBlock(
    allocator: std.mem.Allocator,
    method: []const u8,
    path: []const u8,
    extra: []const Hpack.Header,
) ![]u8 {
    var headers = std.ArrayList(Hpack.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = ":method", .value = method });
    try headers.append(allocator, .{ .name = ":path", .value = path });
    try headers.append(allocator, .{ .name = ":scheme", .value = "http" });
    try headers.append(allocator, .{ .name = ":authority", .value = "localhost" });
    try headers.appendSlice(allocator, extra);
    const enc = Hpack.Encoder.init(allocator);
    return enc.encodeSmart(headers.items);
}

fn firstHeaderValue(headers: []const Hpack.Header, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, name)) return h.value;
    }
    return null;
}

/// A real `api.Server` listening on a loopback port on its own thread.
const RunningServer = struct {
    thread: std.Thread,
    port: u16,

    /// Returns once the accept loop has published the port it bound.
    fn start(server: *api_server.Server) !RunningServer {
        const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
            fn run(s: *api_server.Server) void {
                s.start() catch |err| std.log.warn("[h2] test server accept loop ended: {s}", .{@errorName(err)});
            }
        }.run, .{server});

        var port: u16 = 0;
        var tries: usize = 0;
        while (tries < 200) : (tries += 1) {
            if (server.listener) |*l| {
                port = l.socket.address.getPort();
                break;
            }
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err|
                std.log.debug("[h2] test server poll sleep failed: {s}", .{@errorName(err)});
        }
        if (port == 0) {
            server.stop();
            th.join();
            return error.ServerNeverListened;
        }
        return .{ .thread = th, .port = port };
    }

    /// `stop()` before `join()`: the accept loop only unwinds once `running` is
    /// cleared, and `start()`'s `conn_group.await` then waits for the fibers.
    fn stop(self: *RunningServer, server: *api_server.Server) void {
        server.stop();
        self.thread.join();
    }
};

/// Route-level middleware: the H2 adapter copies non-pseudo H2 headers into
/// `ctx.headers`, so middleware sees them exactly as it does on H1 — and
/// answering without calling `next` short-circuits the handler.
fn requireTenant(ctx: *api_server.Context, next: api_server.HandlerFn, _: ?*anyopaque) anyerror!void {
    if (ctx.header("x-tenant") == null) {
        try ctx.sendError(401, "missing tenant");
        return;
    }
    try next(ctx);
}

test "h2 server dispatches a registered route: handler body and content-type reach the client" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-route" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2hello", struct {
        fn h(ctx: *api_server.Context) anyerror!void {
            try ctx.jsonStruct(200, .{ .ok = true, .proto = "h2" });
        }
    }.h, null);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    const block = try hpackRequestBlock(allocator, "GET", "/h2hello", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SpeakToServer(running.port, head, &out);
    const reply = out[0..n];
    try std.testing.expect(findFrameInReply(reply, .goaway, 0) == null);

    // The DATA body is the handler's, not the loop's built-in 404 — i.e. the
    // route was matched and run.
    const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("{\"ok\":true,\"proto\":\"h2\"}", data.payload);
    try std.testing.expect((data.header.flags & Http2.FrameFlags.end_stream) != 0);

    const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("200", firstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);
    // `ctx.jsonStruct` writes `Content-Type` into the response map; the H2 site
    // adapter reads it back case-insensitively, so this must be the JSON type
    // and not the `application/octet-stream` fallback.
    try std.testing.expectEqualStrings("application/json", firstHeaderValue(hdrs, "content-type") orelse return error.TestUnexpectedResultWithMessage);
}

test "h2 server runs route middleware against H2 request headers" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-mw" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = try (server.group("")).use(.{ .func = requireTenant });
    try group.get("h2tenant", struct {
        fn h(ctx: *api_server.Context) anyerror!void {
            try ctx.text(200, "tenanted");
        }
    }.h, null);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    // 1) No `x-tenant`: the middleware answers before the handler runs.
    {
        const block = try hpackRequestBlock(allocator, "GET", "/h2tenant", &.{});
        defer allocator.free(block);
        const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
        defer allocator.free(head);

        var out: [8192]u8 = undefined;
        const n = try h2SpeakToServer(running.port, head, &out);
        const reply = out[0..n];
        const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("401", firstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);
        try std.testing.expect(findFrameInReply(reply, .data, 1) != null);
    }

    // 2) With `x-tenant`: the header reached `ctx.headers`, so the handler ran.
    {
        const extra = [_]Hpack.Header{.{ .name = "x-tenant", .value = "acme" }};
        const block = try hpackRequestBlock(allocator, "GET", "/h2tenant", &extra);
        defer allocator.free(block);
        const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
        defer allocator.free(head);

        var out: [8192]u8 = undefined;
        const n = try h2SpeakToServer(running.port, head, &out);
        const reply = out[0..n];
        const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("200", firstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);
        const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
        try std.testing.expectEqualStrings("tenanted", data.payload);
    }
}

test "h2 server enforces Server.Config.max_body_size on the H2 path" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // 64 bytes is the H1 body limit; the H2 loop has to take the same number
    // from the same `Config` field instead of its own 8 MiB default.
    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .max_body_size = 64,
        .name = "h2-limit",
    });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.post("h2echo", struct {
        fn h(ctx: *api_server.Context) anyerror!void {
            try ctx.text(200, "small ok");
        }
    }.h, null);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    const block = try hpackRequestBlock(allocator, "POST", "/h2echo", &.{});
    defer allocator.free(block);

    var script = std.ArrayList(u8).empty;
    defer script.deinit(allocator);

    // Stream 1 — 128 bytes against the 64-byte budget.
    const h1 = try Http2.encodeHeaders(allocator, 1, block, false, true);
    defer allocator.free(h1);
    try script.appendSlice(allocator, h1);
    var big: [128]u8 = @splat('x');
    const d1 = try Http2.encodeData(allocator, 1, &big, true);
    defer allocator.free(d1);
    try script.appendSlice(allocator, d1);

    // Stream 3 — 8 bytes: the budget is a limit, not a blanket refusal, and the
    // connection survives the RST.
    const h3 = try Http2.encodeHeaders(allocator, 3, block, false, true);
    defer allocator.free(h3);
    try script.appendSlice(allocator, h3);
    const d3 = try Http2.encodeData(allocator, 3, "12345678", true);
    defer allocator.free(d3);
    try script.appendSlice(allocator, d3);

    var out: [8192]u8 = undefined;
    const n = try h2SpeakToServer(running.port, script.items, &out);
    const reply = out[0..n];

    const rst = findFrameInReply(reply, .rst_stream, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, try Http2.decodeRstStream(rst.payload));
    try std.testing.expect(findFrameInReply(reply, .goaway, 0) == null);

    const ok = findFrameInReply(reply, .data, 3) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("small ok", ok.payload);
}

test "h2 server arms ctx.io and the request budget on the dispatched Context" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // A budget that is not the 30s default, so the reply proves the number came
    // from `Server.Config.request_timeout_ms` and not from a literal.
    const budget_ms: u32 = 12_345;
    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{
        .port = 0,
        .request_timeout_ms = budget_ms,
        .name = "h2-ctx",
    });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2ctx", struct {
        fn h(ctx: *api_server.Context) anyerror!void {
            // The H1 dispatch arms `ctx.io` and `ctx.setDeadline(...)` before
            // routing; the H2 adapter used to leave both at their `null`
            // defaults, so `ctx.io` was null and `ctx.sqlContext().deadline_ms`
            // was null (storage unbounded).
            const sc = ctx.sqlContext();
            const rem = ctx.remainingMs();
            const body = try std.fmt.allocPrint(ctx.allocator, "io={s} sql_deadline={s} within_budget={}", .{
                if (ctx.io != null) "set" else "null",
                if (sc.deadline_ms != null) "set" else "none",
                rem != null and rem.? <= budget_ms,
            });
            defer ctx.allocator.free(body);
            try ctx.text(200, body);
        }
    }.h, null);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    const block = try hpackRequestBlock(allocator, "GET", "/h2ctx", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SpeakToServer(running.port, head, &out);
    const reply = out[0..n];
    const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("io=set sql_deadline=set within_budget=true", data.payload);
}

test "h2 server answers 501 instead of framing a streaming handler's chunks as H1 body bytes" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-stream" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2stream", struct {
        fn h(ctx: *api_server.Context) anyerror!void {
            // The H1 chunked API. On H2 `ctx.stream` is null, so the chunks
            // land in `response_body` *with* their H1 chunk framing — which the
            // H2 adapter then served as opaque body bytes (silent corruption,
            // a 200 to the client).
            try ctx.startChunked(200, "application/json");
            try ctx.writeChunk("{\"a\":1}");
            try ctx.endStream();
        }
    }.h, null);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    const block = try hpackRequestBlock(allocator, "GET", "/h2stream", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SpeakToServer(running.port, head, &out);
    const reply = out[0..n];

    const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("501", firstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);

    const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("streaming is not supported over HTTP/2", data.payload);
    // The refusal itself must not carry the H1 framing it replaces.
    try std.testing.expect(std.mem.indexOf(u8, data.payload, "0\r\n\r\n") == null);
}

test "h2 server refuses an SSE handler rather than writing H1 event bytes into DATA frames" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-sse" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2sse", struct {
        fn h(ctx: *api_server.Context) anyerror!void {
            var sse = try @import("../http.zig").sse(ctx);
            try sse.sendEvent("tick", "1");
        }
    }.h, null);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    const block = try hpackRequestBlock(allocator, "GET", "/h2sse", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    var out: [8192]u8 = undefined;
    const n = try h2SpeakToServer(running.port, head, &out);
    const reply = out[0..n];

    // `SseWriter.init` refuses before any byte is framed (`error.NoStream`), so
    // the H2 adapter never sees `ctx.streaming` here: the exchange is a 500
    // whose body names the missing stream, not a 200 carrying `data: tick`.
    const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
    var dec = Hpack.Decoder.init(allocator);
    defer dec.deinit();
    const hdrs = try dec.decode(hframe.payload);
    defer Hpack.freeHeaders(allocator, hdrs);
    try std.testing.expectEqualStrings("500", firstHeaderValue(hdrs, ":status") orelse return error.TestUnexpectedResultWithMessage);

    const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expect(std.mem.indexOf(u8, data.payload, "NoStream") != null);
    try std.testing.expect(std.mem.indexOf(u8, data.payload, "data: tick") == null);
}

test "h2 server fits the response block to the peer's SETTINGS_MAX_HEADER_LIST_SIZE" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-peer-list" });
    defer server.deinit();
    server.setHttp2Enabled(true);

    var group = server.group("");
    try group.get("h2peerlist", struct {
        fn h(ctx: *api_server.Context) anyerror!void {
            // RFC 9113 §6.5.2 accounting: 6 + 400 + 32 = 438 bytes, i.e. past a
            // peer budget of 200 but well inside our own 16 KiB one.
            const big = try ctx.allocator.alloc(u8, 400);
            @memset(big, 'x');
            try ctx.response_headers.put(try ctx.allocator.dupe(u8, "X-Only"), big);
            try ctx.text(200, "ok");
        }
    }.h, null);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    const block = try hpackRequestBlock(allocator, "GET", "/h2peerlist", &.{});
    defer allocator.free(block);
    const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
    defer allocator.free(head);

    // 1) Nothing advertised: the field fits our default budget and goes out —
    //    so case 2 below is the peer's number biting, not a blanket drop.
    {
        var out: [8192]u8 = undefined;
        const n = try h2SpeakToServer(running.port, head, &out);
        const reply = out[0..n];
        const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        const got = firstHeaderValue(hdrs, "x-only") orelse return error.XOnlyMissingFromH2Response;
        try std.testing.expectEqual(@as(usize, 400), got.len);
    }

    // 2) The peer advertises 200 bytes of list, so the 438-byte field cannot be
    //    carried: the block is built without it and the response is otherwise
    //    complete — status, content-type and body all intact, no RST_STREAM.
    {
        const settings = try Http2.encodeSettings(allocator, false, &.{.{ Http2.SettingsId.max_header_list_size, 200 }});
        defer allocator.free(settings);
        var script = std.ArrayList(u8).empty;
        defer script.deinit(allocator);
        try script.appendSlice(allocator, settings);
        try script.appendSlice(allocator, head);

        var out: [8192]u8 = undefined;
        const n = try h2SpeakToServer(running.port, script.items, &out);
        const reply = out[0..n];
        const hframe = findFrameInReply(reply, .headers, 1) orelse return error.TestUnexpectedResultWithMessage;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("200", firstHeaderValue(hdrs, ":status") orelse return error.NoStatusField);
        try std.testing.expectEqualStrings("text/plain", firstHeaderValue(hdrs, "content-type") orelse return error.NoContentTypeField);
        try std.testing.expect(firstHeaderValue(hdrs, "x-only") == null);
        try std.testing.expect(findFrameInReply(reply, .rst_stream, 1) == null);
        const data = findFrameInReply(reply, .data, 1) orelse return error.TestUnexpectedResultWithMessage;
        try std.testing.expectEqualStrings("ok", data.payload);
    }
}

/// How many frames of `typ` (any stream when `stream_id` is 0) a reply carries.
fn countFramesInReply(wire: []const u8, typ: Http2.FrameType, stream_id: u31) usize {
    var count: usize = 0;
    var off: usize = 0;
    while (off + 9 <= wire.len) {
        const frame = Http2.decodeFrame(wire[off..]) catch return count;
        off += 9 + @as(usize, frame.header.length);
        if (frame.header.typ == typ and (stream_id == 0 or frame.header.stream_id == stream_id)) count += 1;
    }
    return count;
}

/// The `n`-th (0-based) frame of `typ` in a reply — how the trailer field
/// section is reached when a response has more than one HEADERS frame.
fn nthFrameInReply(wire: []const u8, typ: Http2.FrameType, stream_id: u31, n: usize) ?Http2.Frame {
    var seen: usize = 0;
    var off: usize = 0;
    while (off + 9 <= wire.len) {
        const frame = Http2.decodeFrame(wire[off..]) catch return null;
        off += 9 + @as(usize, frame.header.length);
        if (frame.header.typ != typ) continue;
        if (stream_id != 0 and frame.header.stream_id != stream_id) continue;
        if (seen == n) return frame;
        seen += 1;
    }
    return null;
}

test "h2 server answers a HEAD on a gRPC route with no DATA frame" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var registry = Grpc.GrpcServiceRegistry.init(allocator);
    defer registry.deinit();
    try registry.registerService("h2grpc.Echo");
    try registry.registerMethod("h2grpc.Echo", "Say", .unary, struct {
        fn h(req: Grpc.GrpcRequest) anyerror!Grpc.GrpcResponse {
            _ = req;
            return .{ .payload = "pong", .status = .OK, .message = "" };
        }
    }.h);

    var server = api_server.Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h2-grpc-head" });
    defer server.deinit();
    server.setHttp2Enabled(true);
    server.setGrpcRegistry(&registry);

    var running = try RunningServer.start(&server);
    defer running.stop(&server);

    const framed_in = try Grpc.GrpcFrame.encode(allocator, "");
    defer allocator.free(framed_in);
    const expected_body = try Grpc.GrpcFrame.encode(allocator, "pong");
    defer allocator.free(expected_body);
    const grpc_extra = [_]Hpack.Header{.{ .name = "content-type", .value = "application/grpc" }};

    // 1) The GET control: the message reaches the client as DATA. Without this
    //    half the test cannot tell "the DATA was dropped for HEAD" from "no DATA
    //    is ever produced on this route".
    {
        const block = try hpackRequestBlock(allocator, "GET", "/h2grpc.Echo/Say", &grpc_extra);
        defer allocator.free(block);
        const head = try Http2.encodeHeaders(allocator, 1, block, false, true);
        defer allocator.free(head);
        const data = try Http2.encodeData(allocator, 1, framed_in, true);
        defer allocator.free(data);
        const script = try std.mem.concat(allocator, u8, &.{ head, data });
        defer allocator.free(script);

        var out: [8192]u8 = undefined;
        const n = try h2SpeakToServer(running.port, script, &out);
        const body = findFrameInReply(out[0..n], .data, 1) orelse return error.NoDataFrameForGet;
        try std.testing.expectEqualStrings(expected_body, body.payload);
    }

    // 2) The same route asked with HEAD. A HEAD body is not sent, so the one
    //    request frame here is HEADERS with END_STREAM.
    {
        const block = try hpackRequestBlock(allocator, "HEAD", "/h2grpc.Echo/Say", &grpc_extra);
        defer allocator.free(block);
        const head = try Http2.encodeHeaders(allocator, 1, block, true, true);
        defer allocator.free(head);

        var out: [8192]u8 = undefined;
        const n = try h2SpeakToServer(running.port, head, &out);
        const reply = out[0..n];

        // The head field section is the gRPC one — not the loop's built-in 404.
        const hframe = findFrameInReply(reply, .headers, 1) orelse return error.NoHeadersFrameForHead;
        var dec = Hpack.Decoder.init(allocator);
        defer dec.deinit();
        const hdrs = try dec.decode(hframe.payload);
        defer Hpack.freeHeaders(allocator, hdrs);
        try std.testing.expectEqualStrings("200", firstHeaderValue(hdrs, ":status") orelse return error.NoStatusField);
        try std.testing.expectEqualStrings("application/grpc", firstHeaderValue(hdrs, "content-type") orelse return error.NoContentTypeField);

        // The trailer field section still carries the gRPC status, and it is
        // what closes the stream.
        const trailers = nthFrameInReply(reply, .headers, 1, 1) orelse return error.NoTrailerHeadersForHead;
        try std.testing.expect((trailers.header.flags & Http2.FrameFlags.end_stream) != 0);
        var tdec = Hpack.Decoder.init(allocator);
        defer tdec.deinit();
        const thdrs = try tdec.decode(trailers.payload);
        defer Hpack.freeHeaders(allocator, thdrs);
        try std.testing.expect(firstHeaderValue(thdrs, "grpc-status") != null);

        // RFC 9110 §9.3.2: the field sections above, and no body.
        try std.testing.expectEqual(@as(usize, 0), countFramesInReply(reply, .data, 1));
        try std.testing.expect(findFrameInReply(reply, .rst_stream, 1) == null);
    }
}
