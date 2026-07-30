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
    const settings = try Http2.encodeSettings(allocator, false, &.{
        .{ 0x3, 100 }, // MAX_CONCURRENT_STREAMS
        .{ 0x4, 65535 }, // INITIAL_WINDOW_SIZE
    });
    defer allocator.free(settings);
    try writeAll(io, stream, settings);

    var hpack_dec = Hpack.Decoder.init(allocator);
    defer hpack_dec.deinit();

    var conn_flow = Http2.FlowControlState.init(Http2.default_initial_window_size);
    var conn_max_frame_size: u31 = 16384;

    var priority_tree = Http2.PriorityTree.init(allocator);
    defer priority_tree.deinit();

    var outbound = OutboundScheduler.init(allocator);
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

    var frames: usize = 0;
    while (frames < opts.max_frames) : (frames += 1) {
        const frame_buf = readFramePrefetch(reader, allocator, prefetch_buf, &prefetch_off) catch |err| switch (err) {
            error.ConnectionClosed => return,
            else => return err,
        };
        defer allocator.free(frame_buf);

        const frame = try Http2.decodeFrame(frame_buf);
        switch (frame.header.typ) {
            .settings => {
                if ((frame.header.flags & Http2.FrameFlags.ack) == 0) {
                    const peer_settings = try Http2.decodeSettings(allocator, frame.payload);
                    defer allocator.free(peer_settings);
                    for (peer_settings) |s| {
                        switch (s.id) {
                            Http2.SettingsId.initial_window_size => {
                                const new_initial: u31 = @intCast(s.value);
                                try conn_flow.applyPeerInitialWindowSize(new_initial);
                                var it = streams.valueIterator();
                                while (it.next()) |st| {
                                    try st.flow.applyPeerInitialWindowSize(new_initial);
                                }
                                var pit = outbound.pending.valueIterator();
                                while (pit.next()) |p| {
                                    try p.flow.applyPeerInitialWindowSize(new_initial);
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
                    const ack = try Http2.encodeSettings(allocator, true, &.{});
                    defer allocator.free(ack);
                    try writeAll(io, stream, ack);
                }
            },
            .ping => {
                if ((frame.header.flags & Http2.FrameFlags.ack) == 0 and frame.payload.len == 8) {
                    var opaque_data: [8]u8 = undefined;
                    @memcpy(&opaque_data, frame.payload[0..8]);
                    const pong = try Http2.encodePing(allocator, true, opaque_data);
                    defer allocator.free(pong);
                    try writeAll(io, stream, pong);
                }
            },
            .window_update => {
                const increment = Http2.decodeWindowUpdate(frame.payload) catch continue;
                if (frame.header.stream_id == 0) {
                    conn_flow.applyWindowUpdate(increment) catch return;
                } else if (streams.getPtr(frame.header.stream_id)) |st| {
                    st.flow.applyWindowUpdate(increment) catch return;
                } else if (outbound.pending.getPtr(frame.header.stream_id)) |p| {
                    p.flow.applyWindowUpdate(increment) catch return;
                }
                try outbound.drain(io, stream, &priority_tree, &conn_flow, conn_max_frame_size);
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
                    outbound.cancel(sid);
                    priority_tree.removeStream(sid);
                    if (streams.fetchRemove(sid)) |kv| {
                        var removed = kv;
                        removed.value.deinit(allocator);
                    }
                }
            },
            .goaway => return,
            .headers => {
                const sid = frame.header.stream_id;
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
                try gop.value_ptr.appendHeaders(allocator, header_chunk);
                if ((frame.header.flags & Http2.FrameFlags.end_headers) != 0) {
                    gop.value_ptr.headers_done = true;
                    try gop.value_ptr.decodeHeaders(allocator, &hpack_dec);
                    try maybeStartLiveBidi(io, stream, allocator, sid, gop.value_ptr, opts);
                }
                if ((frame.header.flags & Http2.FrameFlags.end_stream) != 0) {
                    gop.value_ptr.end_stream = true;
                }
                if (gop.value_ptr.bidi_live) {
                    if (gop.value_ptr.end_stream) {
                        try finishLiveBidi(io, stream, allocator, sid, gop.value_ptr, &conn_flow, opts);
                        priority_tree.removeStream(sid);
                        var removed = streams.fetchRemove(sid).?;
                        removed.value.deinit(allocator);
                    }
                } else if (gop.value_ptr.ready()) {
                    try finishStreamScheduled(io, stream, allocator, sid, gop.value_ptr, &conn_flow, conn_max_frame_size, opts, &priority_tree, &outbound);
                    var removed = streams.fetchRemove(sid).?;
                    removed.value.deinit(allocator);
                    if (!outbound.pending.contains(sid)) priority_tree.removeStream(sid);
                }
            },
            .continuation => {
                const sid = frame.header.stream_id;
                const st = streams.getPtr(sid) orelse continue;
                try st.appendHeaders(allocator, frame.payload);
                if ((frame.header.flags & Http2.FrameFlags.end_headers) != 0) {
                    st.headers_done = true;
                    try st.decodeHeaders(allocator, &hpack_dec);
                    try maybeStartLiveBidi(io, stream, allocator, sid, st, opts);
                    if (st.bidi_live and st.end_stream) {
                        try finishLiveBidi(io, stream, allocator, sid, st, &conn_flow, opts);
                        priority_tree.removeStream(sid);
                        var removed = streams.fetchRemove(sid).?;
                        removed.value.deinit(allocator);
                    } else if (st.ready()) {
                        try finishStreamScheduled(io, stream, allocator, sid, st, &conn_flow, conn_max_frame_size, opts, &priority_tree, &outbound);
                        var removed = streams.fetchRemove(sid).?;
                        removed.value.deinit(allocator);
                        if (!outbound.pending.contains(sid)) priority_tree.removeStream(sid);
                    }
                }
            },
            .data => {
                const sid = frame.header.stream_id;
                const data_len: u31 = @intCast(frame.payload.len);
                try onInboundData(io, stream, allocator, &conn_flow, 0, data_len);
                const st = streams.getPtr(sid) orelse continue;
                try onInboundData(io, stream, allocator, &st.flow, sid, data_len);
                if ((frame.header.flags & Http2.FrameFlags.end_stream) != 0) {
                    st.end_stream = true;
                }
                if (st.bidi_live) {
                    try pumpLiveBidiData(io, stream, allocator, sid, st, &conn_flow, conn_max_frame_size, opts, frame.payload);
                    if (st.end_stream) {
                        try finishLiveBidi(io, stream, allocator, sid, st, &conn_flow, opts);
                        priority_tree.removeStream(sid);
                        var removed = streams.fetchRemove(sid).?;
                        removed.value.deinit(allocator);
                    }
                } else {
                    try st.appendData(allocator, frame.payload);
                    if (st.ready()) {
                        try finishStreamScheduled(io, stream, allocator, sid, st, &conn_flow, conn_max_frame_size, opts, &priority_tree, &outbound);
                        var removed = streams.fetchRemove(sid).?;
                        removed.value.deinit(allocator);
                        if (!outbound.pending.contains(sid)) priority_tree.removeStream(sid);
                    }
                }
            },
            .push_promise => {},
        }
    }
}

/// Per-stream pending HTTP/2 wire (HEADERS/DATA/trailers) drained by PriorityTree WRR.
const PendingOutbound = struct {
    wire: []u8,
    offset: usize = 0,
    flow: Http2.FlowControlState,

    fn deinit(self: *PendingOutbound, allocator: std.mem.Allocator) void {
        allocator.free(self.wire);
        self.* = undefined;
    }

    fn remaining(self: *const PendingOutbound) []const u8 {
        return self.wire[self.offset..];
    }

    fn done(self: *const PendingOutbound) bool {
        return self.offset >= self.wire.len;
    }
};

/// Weighted outbound DATA scheduler: interleaves pending streams via `PriorityTree.pickNext`.
const OutboundScheduler = struct {
    allocator: std.mem.Allocator,
    pending: std.AutoHashMap(u31, PendingOutbound),

    fn init(allocator: std.mem.Allocator) OutboundScheduler {
        return .{
            .allocator = allocator,
            .pending = std.AutoHashMap(u31, PendingOutbound).init(allocator),
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
            p.deinit(self.allocator);
        }
    }

    fn enqueue(self: *OutboundScheduler, stream_id: u31, wire: []u8, flow: Http2.FlowControlState) !void {
        // Take ownership of `wire`. Replace any prior pending for this stream.
        self.cancel(stream_id);
        try self.pending.put(stream_id, .{
            .wire = wire,
            .offset = 0,
            .flow = flow,
        });
    }

    /// Drain pending streams until empty or flow-control blocked.
    /// Each frame is chosen via `PriorityTree.pickNext` (deficit WRR) among ready streams.
    fn drain(
        self: *OutboundScheduler,
        io: std.Io,
        net_stream: std.Io.net.Stream,
        tree: *Http2.PriorityTree,
        conn_flow: *Http2.FlowControlState,
        conn_max_frame_size: u31,
    ) !void {
        var guard: usize = 0;
        while (guard < 4096) : (guard += 1) {
            if (self.pending.count() == 0) return;

            var ready_buf: [64]u31 = undefined;
            var ready_n: usize = 0;
            var it = self.pending.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.done()) continue;
                if (ready_n >= ready_buf.len) break;
                // Eligible if next frame is non-DATA, or DATA with send window.
                if (canSendNextFrame(e.value_ptr, conn_flow.send_window, conn_max_frame_size)) {
                    ready_buf[ready_n] = e.key_ptr.*;
                    ready_n += 1;
                }
            }
            if (ready_n == 0) return; // all blocked on flow control

            const pick = (try tree.pickNext(ready_buf[0..ready_n])) orelse return;
            const p = self.pending.getPtr(pick) orelse continue;
            const progress = try writeNextWireFrame(io, net_stream, self.allocator, conn_flow, &p.flow, pick, p, conn_max_frame_size);
            switch (progress) {
                .blocked => return,
                .wrote => {},
                .done => {
                    var removed = self.pending.fetchRemove(pick).?;
                    removed.value.deinit(self.allocator);
                    tree.removeStream(pick);
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
    io: std.Io,
    net_stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    conn_flow: *Http2.FlowControlState,
    stream_flow: *Http2.FlowControlState,
    stream_id: u31,
    pending: *PendingOutbound,
    conn_max_frame_size: u31,
) !enum { wrote, blocked, done } {
    const rem = pending.remaining();
    if (rem.len < 9) {
        pending.offset = pending.wire.len;
        return .done;
    }
    const frame = try Http2.decodeFrame(rem);
    const frame_len = 9 + @as(usize, frame.header.length);
    if (frame.header.typ == .data and frame.header.stream_id == stream_id) {
        const end_stream = (frame.header.flags & Http2.FrameFlags.end_stream) != 0;
        const max_chunk = maxOutboundChunk(stream_flow, conn_flow.send_window, conn_max_frame_size);
        if (frame.payload.len == 0) {
            // Zero-length DATA does not consume flow-control window.
            const d = try Http2.encodeData(allocator, stream_id, "", end_stream);
            defer allocator.free(d);
            try writeAll(io, net_stream, d);
            pending.offset += frame_len;
            return if (pending.done()) .done else .wrote;
        }
        if (max_chunk == 0) return .blocked;
        const send_n: usize = @min(@as(usize, max_chunk), frame.payload.len);
        const is_last_of_frame = send_n == frame.payload.len;
        const d = try Http2.encodeData(allocator, stream_id, frame.payload[0..send_n], end_stream and is_last_of_frame);
        defer allocator.free(d);
        try writeAll(io, net_stream, d);
        const sent: u31 = @intCast(send_n);
        stream_flow.consumeSend(sent);
        conn_flow.consumeSend(sent);
        if (is_last_of_frame) {
            pending.offset += frame_len;
        } else {
            // Rebuild remaining DATA frame in-place after partial send.
            const left = frame.payload[send_n..];
            const new_frame = try Http2.encodeData(allocator, stream_id, left, end_stream);
            defer allocator.free(new_frame);
            const after = pending.wire[pending.offset + frame_len ..];
            const new_wire = try std.mem.concat(allocator, u8, &.{ new_frame, after });
            allocator.free(pending.wire);
            pending.wire = new_wire;
            pending.offset = 0;
        }
        return if (pending.done()) .done else .wrote;
    } else {
        try writeAll(io, net_stream, rem[0..frame_len]);
        pending.offset += frame_len;
        return if (pending.done()) .done else .wrote;
    }
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
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    stream_id: u31,
    conn_flow: *Http2.FlowControlState,
    stream_flow: *Http2.FlowControlState,
    conn_max_frame_size: u31,
};

fn onInboundData(
    io: std.Io,
    net_stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    fc: *Http2.FlowControlState,
    window_stream_id: u31,
    size: u31,
) !void {
    if (size == 0) return;
    if (fc.consumeRecv(size)) |increment| {
        const wu = try Http2.encodeWindowUpdate(allocator, window_stream_id, increment);
        defer allocator.free(wu);
        try writeAll(io, net_stream, wu);
    }
}

fn maxOutboundChunk(stream_flow: *Http2.FlowControlState, conn_send_window: u31, conn_max_frame_size: u31) u31 {
    const cap = stream_flow.maxOutboundData(conn_send_window);
    return @min(cap, conn_max_frame_size);
}

fn writeFlowControlledData(
    io: std.Io,
    net_stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
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
        const d = try Http2.encodeData(allocator, stream_id, chunk, is_last);
        defer allocator.free(d);
        try writeAll(io, net_stream, d);
        const sent: u31 = @intCast(chunk.len);
        stream_flow.consumeSend(sent);
        conn_flow.consumeSend(sent);
        off = end;
    }
    if (body.len == 0 and end_stream) {
        const max_chunk = maxOutboundChunk(stream_flow, conn_flow.send_window, conn_max_frame_size);
        if (max_chunk == 0) return error.FlowControlBlocked;
        const d = try Http2.encodeData(allocator, stream_id, "", true);
        defer allocator.free(d);
        try writeAll(io, net_stream, d);
    }
}

fn liveFlushCb(user_ctx: ?*anyopaque, framed: []const u8) anyerror!void {
    const ctx: *LiveFlushCtx = @ptrCast(@alignCast(user_ctx.?));
    try writeFlowControlledData(ctx.io, ctx.stream, ctx.allocator, ctx.conn_flow, ctx.stream_flow, ctx.stream_id, framed, false, ctx.conn_max_frame_size);
}

fn maybeStartLiveBidi(
    io: std.Io,
    stream: std.Io.net.Stream,
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
    try writeAll(io, stream, h);
}

fn pumpLiveBidiData(
    io: std.Io,
    stream: std.Io.net.Stream,
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
        .io = io,
        .stream = stream,
        .allocator = allocator,
        .stream_id = stream_id,
        .conn_flow = conn_flow,
        .stream_flow = &st.flow,
        .conn_max_frame_size = conn_max_frame_size,
    };
    var writer = Grpc.GrpcStreamWriter.init(allocator);
    defer writer.deinit();
    writer.on_flush = liveFlushCb;
    writer.flush_ctx = &flush_ctx;

    while (try st.grpc_buf.tryNext()) |msg| {
        try reg.pumpBidiMessage(st.path, msg, &writer);
        if (writer.message_owned and writer.status != .OK) break;
    }
}

fn finishLiveBidi(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
    conn_flow: *Http2.FlowControlState,
    opts: ServeOptions,
) !void {
    _ = opts;
    _ = conn_flow;
    st.grpc_buf.markEnded();
    // Drain any remaining complete frames (none expected if pumpLive already ran).
    const status_str = "0";
    const trailers = try Http2.encodeLiteralHeaderBlock(allocator, &.{
        .{ "grpc-status", status_str },
        .{ "grpc-message", "" },
    });
    defer allocator.free(trailers);
    const h = try Http2.encodeHeaders(allocator, stream_id, trailers, true, true);
    defer allocator.free(h);
    try writeAll(io, stream, h);
}

fn finishStreamScheduled(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
    conn_flow: *Http2.FlowControlState,
    conn_max_frame_size: u31,
    opts: ServeOptions,
    tree: *Http2.PriorityTree,
    outbound: *OutboundScheduler,
) !void {
    try tree.setPriority(stream_id, st.getPriority());
    const wire = try buildStreamResponseWire(allocator, stream_id, st, opts);
    errdefer allocator.free(wire);
    try outbound.enqueue(stream_id, wire, st.flow);
    try outbound.drain(io, stream, tree, conn_flow, conn_max_frame_size);
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

fn writeAll(io: std.Io, stream: std.Io.net.Stream, data: []const u8) !void {
    var wbuf: [8192]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(data);
    try w.interface.flush();
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
