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
//!   §7  Response encoding —— buildStreamResponseWire, encodeSiteResponseWire
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

    pub fn deinit(self: *SiteResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.content_type_owned) allocator.free(self.content_type);
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

    fn init(io: std.Io, stream: std.Io.net.Stream) ConnWriter {
        return .{ .io = io, .stream = stream };
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

    fn writeDirect(self: *ConnWriter, data: []const u8) !void {
        var dummy_buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &dummy_buf);
        try w.interface.writeAll(data);
        try w.interface.flush();
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
pub fn serveAfterUpgrade(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
    inbound: ?*std.Io.Reader,
) !void {
    var preface_buf: [Http2.connection_preface.len]u8 = undefined;
    if (inbound) |reader| {
        var off: usize = 0;
        try readExactPrefetch(reader, &.{}, &off, &preface_buf);
    } else {
        try readExact(io, stream, &preface_buf);
    }
    if (!std.mem.eql(u8, &preface_buf, Http2.connection_preface)) return error.InvalidHttp2Preface;
    try serveAfterPrefacePrefetchReader(io, stream, allocator, opts, &.{}, inbound);
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
    var writer = ConnWriter.init(io, stream);

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
                if (!gop.found_existing) gop.value_ptr.* = StreamState.init();
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
                    finishStreamScheduled(&writer, allocator, sid, gop.value_ptr, &conn_flow, conn_max_frame_size, opts, &priority_tree, &outbound, more_inbound) catch |err| {
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
                        finishStreamScheduled(&writer, allocator, sid, st, &conn_flow, conn_max_frame_size, opts, &priority_tree, &outbound, more_inbound) catch |err| {
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
                        finishStreamScheduled(&writer, allocator, sid, st, &conn_flow, conn_max_frame_size, opts, &priority_tree, &outbound, more_inbound) catch |err| {
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
    flow: Http2.FlowControlState = Http2.FlowControlState.init(Http2.default_initial_window_size),
    priority: Http2.PriorityInfo = .{ .exclusive = false, .depends_on = 0, .weight = 15 },
    /// Inbound request-body bytes counted against `InboundLimits.max_body_bytes`
    /// — covers both `data` and the live bidi `grpc_buf`.
    inbound_body_bytes: usize = 0,
    /// Live interleaved bidi pump (headers sent; DATA flushed as messages arrive).
    bidi_live: bool = false,
    grpc_buf: Grpc.GrpcStreamBuffer = undefined,
    grpc_buf_active: bool = false,

    fn init() StreamState {
        return .{};
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
    opts: ServeOptions,
    tree: *Http2.PriorityTree,
    outbound: *OutboundScheduler,
    more_inbound: bool,
) !void {
    try tree.setPriority(stream_id, st.getPriority());
    const wire = try buildStreamResponseWire(allocator, stream_id, st, opts);
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
    opts: ServeOptions,
) ![]u8 {
    const is_grpc = std.mem.indexOf(u8, st.content_type, "application/grpc") != null;
    if (is_grpc) {
        if (opts.grpc_registry) |reg| {
            const path = st.path;
            if (reg.findMethod(path)) |method| {
                switch (method.method.method_type) {
                    .server_streaming => {
                        var result = try reg.handleHttpServerStream(path, st.data.items, stream_id);
                        defer result.deinit(allocator);
                        if (result.http2_wire) |wire| {
                            result.http2_wire = null;
                            return wire;
                        }
                    },
                    .client_streaming => {
                        var result = try reg.handleHttpClientStream(path, st.data.items, stream_id);
                        defer result.deinit(allocator);
                        if (result.http2_wire) |wire| {
                            result.http2_wire = null;
                            return wire;
                        }
                    },
                    .bidi_streaming => {
                        if (method.bidi_pump_handler != null) {
                            var result = try reg.handleHttpBidiPump(path, st.data.items, stream_id, null);
                            defer result.deinit(allocator);
                            if (result.http2_wire) |wire| {
                                result.http2_wire = null;
                                return wire;
                            }
                        }
                        var result = try reg.handleHttpBidi(path, st.data.items, stream_id);
                        defer result.deinit(allocator);
                        if (result.http2_wire) |wire| {
                            result.http2_wire = null;
                            return wire;
                        }
                    },
                    .unary => {},
                }
            }
            var unary = try reg.handleHttpUnary(path, st.data.items);
            defer unary.deinit(allocator);
            const status_str = try std.fmt.allocPrint(allocator, "{d}", .{@backingInt(unary.grpc_status)});
            defer allocator.free(status_str);
            return try Http2.encodeGrpcServerStream(allocator, stream_id, unary.body, status_str, unary.grpc_message);
        }
    }

    if (opts.site_handler) |handler| {
        const hdrs = st.decoded orelse &[_]Hpack.Header{};
        var resp = try handler(opts.site_user_ctx, allocator, st.method, st.path, hdrs, st.data.items);
        defer resp.deinit(allocator);
        return try encodeSiteResponseWire(allocator, stream_id, resp.status, resp.content_type, resp.body);
    }

    return try encodeSiteResponseWire(allocator, stream_id, 404, "text/plain", "not found");
}

fn encodeSiteResponseWire(
    allocator: std.mem.Allocator,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) ![]u8 {
    const status_str = try std.fmt.allocPrint(allocator, "{d}", .{status});
    defer allocator.free(status_str);
    var enc = Hpack.Encoder.init(allocator);
    const block = try enc.encodeSmart(&.{
        .{ .name = ":status", .value = status_str },
        .{ .name = "content-type", .value = content_type },
    });
    defer allocator.free(block);
    const h = try Http2.encodeHeaders(allocator, stream_id, block, false, true);
    defer allocator.free(h);
    const d = try Http2.encodeData(allocator, stream_id, body, true);
    defer allocator.free(d);
    return try std.mem.concat(allocator, u8, &.{ h, d });
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
    const wire = try encodeSiteResponseWire(allocator, 7, 200, "text/plain", "ok");
    defer allocator.free(wire);
    const f0 = try Http2.decodeFrame(wire);
    try std.testing.expectEqual(Http2.FrameType.headers, f0.header.typ);
    try std.testing.expectEqual(@as(u31, 7), f0.header.stream_id);
    const f1 = try Http2.decodeFrame(wire[9 + f0.header.length ..]);
    try std.testing.expectEqual(Http2.FrameType.data, f1.header.typ);
    try std.testing.expectEqualStrings("ok", f1.payload);
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
fn runLoopbackH2Session(opts: ServeOptions, frames: []const u8, out: []u8) !usize {
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

test "h2 session answers GOAWAY FRAME_SIZE_ERROR for an oversized inbound DATA frame" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // One 65536-byte DATA frame on an idle stream — the reviewer's probe: no
    // stream state, no prior negotiation.
    var payload: [65536]u8 = @splat(0x41);
    const oversized = try Http2.encodeData(allocator, 1, &payload, false);
    defer allocator.free(oversized);

    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{}, oversized, &out);
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
    const n = try runLoopbackH2Session(.{}, headers, &out);
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
    const n = try runLoopbackH2Session(.{}, headers, &out);
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
    const n = try runLoopbackH2Session(.{}, headers, &out);
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
    const n = try runLoopbackH2Session(.{}, script.items, &out);
    const rst = findFrameInReply(out[0..n], .rst_stream, refused_sid) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqual(Http2.ErrorCode.REFUSED_STREAM, try Http2.decodeRstStream(rst.payload));
    try std.testing.expect(findFrameInReply(out[0..n], .rst_stream, 1) == null);
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
    const n = try runLoopbackH2Session(.{ .inbound = .{ .max_header_list_bytes = advertised } }, &.{}, &out);
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
    }, script.items, &out);
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
    }, script.items, &out);
    const reply = out[0..n];

    const rst = findFrameInReply(reply, .rst_stream, 1) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqual(Http2.ErrorCode.ENHANCE_YOUR_CALM, try Http2.decodeRstStream(rst.payload));
    try std.testing.expect(findFrameInReply(reply, .goaway, 0) == null);

    // No site_handler → the loop's built-in 404 body, but a complete response.
    const data = findFrameInReply(reply, .data, 3) orelse return error.TestUnexpectedResultWithMessage;
    try std.testing.expectEqualStrings("not found", data.payload);
}

test "h2 session arms the read idle deadline and clears it on exit" {
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var fake = FakeDeadline{};
    var out: [4096]u8 = undefined;
    const n = try runLoopbackH2Session(.{
        .read_idle_timeout_ms = 30_000,
        .read_deadline = fake.handle(),
    }, &.{}, &out);
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
