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

const std = @import("std");
const Http2 = @import("Http2.zig");
const Hpack = @import("Hpack.zig");
const Grpc = @import("../extensions/GrpcTransport.zig");

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
};

/// Coalesces small writes and flushes once per drain/control batch.
const ConnWriter = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    buf: [32 * 1024]u8 = undefined,
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
        var wbuf: [8192]u8 = undefined;
        var w = self.stream.writer(self.io, &wbuf);
        try w.interface.writeAll(data);
        try w.interface.flush();
    }

    fn flush(self: *ConnWriter) !void {
        if (self.len == 0) return;
        try self.writeDirect(self.buf[0..self.len]);
        self.len = 0;
    }
};

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

    const settings = try Http2.encodeSettings(allocator, false, &.{
        .{ 0x3, 100 }, // MAX_CONCURRENT_STREAMS
        .{ 0x4, 65535 }, // INITIAL_WINDOW_SIZE
    });
    defer allocator.free(settings);
    try writer.write(settings);
    try writer.flush();

    var hpack_dec = Hpack.Decoder.init(allocator);
    defer hpack_dec.deinit();

    var conn_flow = Http2.FlowControlState.init(Http2.default_initial_window_size);
    var conn_max_frame_size: u31 = 16384;
    var last_peer_stream: u31 = 0;
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

    var frames: usize = 0;
    while (frames < opts.max_frames) : (frames += 1) {
        const inbound_ready = (prefetch_off < prefetch_buf.len) or (reader.bufferedLen() > 0);
        if (!inbound_ready and outbound.pending.count() > 0) {
            try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, 0);
            try writer.flush();
        }

        const frame_buf = readFramePrefetch(reader, allocator, prefetch_buf, &prefetch_off) catch |err| switch (err) {
            error.ConnectionClosed => {
                try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, 0);
                try writer.flush();
                return;
            },
            else => {
                try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
                return;
            },
        };
        defer allocator.free(frame_buf);

        const frame = Http2.decodeFrame(frame_buf) catch {
            try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.PROTOCOL_ERROR, &goaway_sent);
            return;
        };
        if (frame.header.stream_id != 0 and frame.header.stream_id > last_peer_stream) {
            last_peer_stream = frame.header.stream_id;
        }

        switch (frame.header.typ) {
            .settings => {
                if ((frame.header.flags & Http2.FrameFlags.ack) == 0) {
                    const peer_settings = Http2.decodeSettings(allocator, frame.payload) catch {
                        try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.FRAME_SIZE_ERROR, &goaway_sent);
                        return;
                    };
                    defer allocator.free(peer_settings);
                    for (peer_settings) |s| {
                        switch (s.id) {
                            Http2.SettingsId.initial_window_size => {
                                const new_initial: u31 = @intCast(s.value);
                                conn_flow.applyPeerInitialWindowSize(new_initial) catch {
                                    try sendGoAway(&writer, allocator, last_peer_stream, Http2.ErrorCode.FLOW_CONTROL_ERROR, &goaway_sent);
                                    return;
                                };
                                var it = streams.valueIterator();
                                while (it.next()) |st| {
                                    st.flow.applyPeerInitialWindowSize(new_initial) catch {};
                                }
                                var pit = outbound.pending.valueIterator();
                                while (pit.next()) |p| {
                                    p.flow.applyPeerInitialWindowSize(new_initial) catch {};
                                }
                            },
                            Http2.SettingsId.max_frame_size => {
                                if (s.value >= 16384 and s.value <= 16777215) {
                                    conn_max_frame_size = @intCast(s.value);
                                }
                            },
                            else => {},
                        }
                    }
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
                const gop = try streams.getOrPut(sid);
                if (!gop.found_existing) gop.value_ptr.* = StreamState.init();
                gop.value_ptr.priority = pri;
                try priority_tree.setPriority(sid, pri);
            },
            .rst_stream => {
                const sid = frame.header.stream_id;
                if (sid != 0) {
                    _ = Http2.decodeRstStream(frame.payload) catch {};
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
                if (reject_new_streams and !streams.contains(sid)) {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.REFUSED_STREAM);
                    continue;
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
                gop.value_ptr.appendHeaders(allocator, header_chunk) catch {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.INTERNAL_ERROR);
                    continue;
                };
                if ((frame.header.flags & Http2.FrameFlags.end_headers) != 0) {
                    gop.value_ptr.headers_done = true;
                    gop.value_ptr.decodeHeaders(allocator, &hpack_dec) catch {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.COMPRESSION_ERROR);
                        continue;
                    };
                    maybeStartLiveBidi(&writer, allocator, sid, gop.value_ptr, opts) catch |err| {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, streamErrorFromAny(err));
                        continue;
                    };
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
                const st = streams.getPtr(sid) orelse {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.STREAM_CLOSED);
                    continue;
                };
                st.appendHeaders(allocator, frame.payload) catch {
                    try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.INTERNAL_ERROR);
                    continue;
                };
                if ((frame.header.flags & Http2.FrameFlags.end_headers) != 0) {
                    st.headers_done = true;
                    st.decodeHeaders(allocator, &hpack_dec) catch {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.COMPRESSION_ERROR);
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
                    st.appendData(allocator, frame.payload) catch {
                        try resetStream(&writer, allocator, &outbound, &priority_tree, &streams, sid, Http2.ErrorCode.INTERNAL_ERROR);
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
            try writer.flush();
        }
    }

    try outbound.drain(&writer, &priority_tree, &conn_flow, conn_max_frame_size, 0);
    try writer.flush();
}

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

    fn appendHeaders(self: *StreamState, allocator: std.mem.Allocator, chunk: []const u8) !void {
        try self.header_block.appendSlice(allocator, chunk);
    }

    fn appendData(self: *StreamState, allocator: std.mem.Allocator, chunk: []const u8) !void {
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
    if (fc.consumeRecv(size)) |increment| {
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
            const status_str = try std.fmt.allocPrint(allocator, "{d}", .{@intFromEnum(unary.grpc_status)});
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

fn readFrame(io: std.Io, stream: std.Io.net.Stream, allocator: std.mem.Allocator) ![]u8 {
    var rbuf: [8192]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var empty: [0]u8 = .{};
    var off: usize = 0;
    return readFramePrefetch(&r.interface, allocator, &empty, &off);
}

fn readFramePrefetch(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    prefetch: []const u8,
    prefetch_off: *usize,
) ![]u8 {
    var hdr: [9]u8 = undefined;
    try readExactPrefetch(reader, prefetch, prefetch_off, &hdr);
    const header = try Http2.FrameHeader.decode(&hdr);
    const total = 9 + @as(usize, header.length);
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
    _ = conn.consumeRecv(size);
    _ = stream.consumeRecv(size);
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

// Regression for prior-knowledge h2c: SETTINGS+HEADERS that arrive with the preface
// must be readable from a prefetch buffer (same bytes StreamReader would leave buffered).
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

    const f0 = try readFramePrefetch(&r, allocator, leftover, &off);
    defer allocator.free(f0);
    const d0 = try Http2.decodeFrame(f0);
    try std.testing.expectEqual(Http2.FrameType.settings, d0.header.typ);

    const f1 = try readFramePrefetch(&r, allocator, leftover, &off);
    defer allocator.free(f1);
    const d1 = try Http2.decodeFrame(f1);
    try std.testing.expectEqual(Http2.FrameType.headers, d1.header.typ);
    try std.testing.expectEqual(@as(u31, 1), d1.header.stream_id);
    try std.testing.expect((d1.header.flags & Http2.FrameFlags.end_stream) != 0);
    try std.testing.expectEqual(leftover.len, off);
}
