//! HTTP/2 frame codec (RFC 7540) — framing + SETTINGS/DATA/HEADERS/WINDOW_UPDATE/PING/GOAWAY/RST.
//!
//! Scope: wire helpers for gRPC-over-H2. Not a full multiplexed connection manager
//! (no priority tree, no push, simplified HPACK literal-only header blocks).

const std = @import("std");

pub const connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// RFC 7540 default INITIAL_WINDOW_SIZE (65535).
pub const default_initial_window_size: u31 = 65535;

/// Max DATA payload per frame for outbound chunking.
pub const max_data_chunk_size: usize = 16 * 1024;

pub const FlowControlError = error{
    InvalidWindowUpdatePayload,
    ZeroWindowUpdateIncrement,
    FlowControlOverflow,
    FlowControlBlocked,
    InvalidSettingsPayload,
    InvalidInitialWindowSize,
};

/// RFC 7540 §6.5.2 SETTINGS identifiers.
pub const SettingsId = struct {
    pub const header_table_size: u16 = 0x1;
    pub const enable_push: u16 = 0x2;
    pub const max_concurrent_streams: u16 = 0x3;
    pub const initial_window_size: u16 = 0x4;
    pub const max_frame_size: u16 = 0x5;
};

pub const SettingEntry = struct { id: u16, value: u32 };

/// Per-connection or per-stream send/recv window accounting (RFC 7540 §6.9).
pub const FlowControlState = struct {
    /// Our INITIAL_WINDOW_SIZE — used for recv replenish threshold.
    our_initial: u31,
    /// Peer's last SETTINGS INITIAL_WINDOW_SIZE — governs our send window baseline.
    peer_initial: u31,
    recv_window: u31,
    send_window: u31,

    pub fn init(initial: u31) FlowControlState {
        return .{
            .our_initial = initial,
            .peer_initial = initial,
            .recv_window = initial,
            .send_window = initial,
        };
    }

    /// Decrement recv window after inbound DATA. Returns WINDOW_UPDATE increment when below half initial.
    pub fn consumeRecv(self: *FlowControlState, size: u31) ?u31 {
        self.recv_window -= size;
        const threshold = self.our_initial / 2;
        if (self.recv_window <= threshold) {
            const increment = self.our_initial - self.recv_window;
            self.recv_window = self.our_initial;
            return increment;
        }
        return null;
    }

    /// Apply peer SETTINGS INITIAL_WINDOW_SIZE (RFC 7540 §6.9.2): adjust send_window by delta.
    pub fn applyPeerInitialWindowSize(self: *FlowControlState, new_initial: u31) FlowControlError!void {
        if (new_initial == 0) return error.InvalidInitialWindowSize;
        const old = self.peer_initial;
        if (new_initial == old) return;
        const delta: i64 = @as(i64, new_initial) - @as(i64, old);
        const new_send = @as(i64, self.send_window) + delta;
        if (new_send < 0 or new_send > std.math.maxInt(u31)) return error.FlowControlOverflow;
        self.send_window = @intCast(new_send);
        self.peer_initial = new_initial;
    }

    /// Apply peer WINDOW_UPDATE — increases our send window.
    pub fn applyWindowUpdate(self: *FlowControlState, increment: u31) FlowControlError!void {
        const new = @as(u64, self.send_window) + increment;
        if (new > std.math.maxInt(u31)) return error.FlowControlOverflow;
        self.send_window = @intCast(new);
    }

    /// Max outbound DATA bytes allowed now (stream + connection caps, 16 KiB chunk limit).
    pub fn maxOutboundData(self: *const FlowControlState, conn_send_window: u31) u31 {
        const cap = @min(self.send_window, conn_send_window);
        return @min(cap, @as(u31, @intCast(max_data_chunk_size)));
    }

    pub fn consumeSend(self: *FlowControlState, size: u31) void {
        self.send_window -= size;
    }
};

pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
};

pub const FrameFlags = struct {
    pub const end_stream: u8 = 0x1;
    pub const ack: u8 = 0x1; // SETTINGS / PING
    pub const end_headers: u8 = 0x4;
    pub const padded: u8 = 0x8;
    pub const priority: u8 = 0x20;
};

pub const FrameHeader = struct {
    length: u24,
    typ: FrameType,
    flags: u8,
    stream_id: u31,

    pub fn encode(self: FrameHeader, out: *[9]u8) void {
        out[0] = @truncate(self.length >> 16);
        out[1] = @truncate(self.length >> 8);
        out[2] = @truncate(self.length);
        out[3] = @intFromEnum(self.typ);
        out[4] = self.flags;
        const sid: u32 = self.stream_id;
        out[5] = @truncate(sid >> 24);
        out[6] = @truncate(sid >> 16);
        out[7] = @truncate(sid >> 8);
        out[8] = @truncate(sid);
    }

    pub fn decode(buf: []const u8) !FrameHeader {
        if (buf.len < 9) return error.IncompleteHttp2Frame;
        const length: u24 = (@as(u24, buf[0]) << 16) | (@as(u24, buf[1]) << 8) | buf[2];
        const typ: FrameType = switch (buf[3]) {
            0x0 => .data,
            0x1 => .headers,
            0x2 => .priority,
            0x3 => .rst_stream,
            0x4 => .settings,
            0x5 => .push_promise,
            0x6 => .ping,
            0x7 => .goaway,
            0x8 => .window_update,
            0x9 => .continuation,
            else => return error.UnknownHttp2FrameType,
        };
        const flags = buf[4];
        const stream_id: u31 = @truncate(((@as(u32, buf[5]) << 24) | (@as(u32, buf[6]) << 16) | (@as(u32, buf[7]) << 8) | buf[8]) & 0x7fff_ffff);
        return .{ .length = length, .typ = typ, .flags = flags, .stream_id = stream_id };
    }
};
pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,
};

/// Encode a complete frame (header + payload).
pub fn encodeFrame(allocator: std.mem.Allocator, typ: FrameType, flags: u8, stream_id: u31, payload: []const u8) ![]u8 {
    if (payload.len > std.math.maxInt(u24)) return error.PayloadTooLarge;
    var out = try allocator.alloc(u8, 9 + payload.len);
    const hdr = FrameHeader{ .length = @intCast(payload.len), .typ = typ, .flags = flags, .stream_id = stream_id };
    hdr.encode(out[0..9]);
    @memcpy(out[9..], payload);
    return out;
}

pub fn decodeFrame(buf: []const u8) !Frame {
    const hdr = try FrameHeader.decode(buf);
    const total = 9 + @as(usize, hdr.length);
    if (buf.len < total) return error.IncompleteHttp2Frame;
    return .{ .header = hdr, .payload = buf[9..total] };
}

/// Parse SETTINGS frame payload into (id, value) pairs. Empty payload is valid.
pub fn decodeSettings(allocator: std.mem.Allocator, payload: []const u8) ![]SettingEntry {
    if (@rem(payload.len, 6) != 0) return error.InvalidSettingsPayload;
    const count = payload.len / 6;
    var out = try allocator.alloc(SettingEntry, count);
    errdefer allocator.free(out);
    for (0..count) |i| {
        const off = i * 6;
        const id: u16 = (@as(u16, payload[off]) << 8) | payload[off + 1];
        const value: u32 =
            (@as(u32, payload[off + 2]) << 24) |
            (@as(u32, payload[off + 3]) << 16) |
            (@as(u32, payload[off + 4]) << 8) |
            payload[off + 5];
        out[i] = .{ .id = id, .value = value };
    }
    return out;
}

pub fn encodeSettings(allocator: std.mem.Allocator, ack: bool, params: []const struct { u16, u32 }) ![]u8 {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    if (!ack) {
        for (params) |p| {
            try appendU16(&body, allocator, p[0]);
            try appendU32(&body, allocator, p[1]);
        }
    }
    const flags: u8 = if (ack) FrameFlags.ack else 0;
    return encodeFrame(allocator, .settings, flags, 0, body.items);
}

pub fn encodeWindowUpdate(allocator: std.mem.Allocator, stream_id: u31, increment: u31) ![]u8 {
    var payload: [4]u8 = undefined;
    encodeWindowUpdatePayload(increment, &payload);
    return encodeFrame(allocator, .window_update, 0, stream_id, &payload);
}

fn encodeWindowUpdatePayload(increment: u31, out: *[4]u8) void {
    const v: u32 = increment;
    out[0] = @truncate(v >> 24);
    out[1] = @truncate(v >> 16);
    out[2] = @truncate(v >> 8);
    out[3] = @truncate(v);
}

/// Parse WINDOW_UPDATE payload (4-byte increment). Rejects zero increment (RFC 7540 §6.9).
pub fn decodeWindowUpdate(payload: []const u8) FlowControlError!u31 {
    if (payload.len != 4) return error.InvalidWindowUpdatePayload;
    const increment: u31 = @truncate(
        (@as(u32, payload[0]) << 24) |
            (@as(u32, payload[1]) << 16) |
            (@as(u32, payload[2]) << 8) |
            payload[3],
    );
    if (increment == 0) return error.ZeroWindowUpdateIncrement;
    return increment;
}

pub fn encodePing(allocator: std.mem.Allocator, ack: bool, opaque_data: [8]u8) ![]u8 {
    const flags: u8 = if (ack) FrameFlags.ack else 0;
    return encodeFrame(allocator, .ping, flags, 0, &opaque_data);
}

pub fn encodeRstStream(allocator: std.mem.Allocator, stream_id: u31, error_code: u32) ![]u8 {
    var payload: [4]u8 = undefined;
    payload[0] = @truncate(error_code >> 24);
    payload[1] = @truncate(error_code >> 16);
    payload[2] = @truncate(error_code >> 8);
    payload[3] = @truncate(error_code);
    return encodeFrame(allocator, .rst_stream, 0, stream_id, &payload);
}

pub fn encodeGoAway(allocator: std.mem.Allocator, last_stream_id: u31, error_code: u32, debug: []const u8) ![]u8 {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    const sid: u32 = last_stream_id;
    try appendU32(&body, allocator, sid);
    try appendU32(&body, allocator, error_code);
    try body.appendSlice(allocator, debug);
    return encodeFrame(allocator, .goaway, 0, 0, body.items);
}

pub fn encodeData(allocator: std.mem.Allocator, stream_id: u31, data: []const u8, end_stream: bool) ![]u8 {
    const flags: u8 = if (end_stream) FrameFlags.end_stream else 0;
    return encodeFrame(allocator, .data, flags, stream_id, data);
}

/// Literal-never-indexed HPACK header block (no dynamic table). Enough for gRPC tests.
pub fn encodeLiteralHeaderBlock(allocator: std.mem.Allocator, headers: []const struct { []const u8, []const u8 }) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (headers) |h| {
        // 0x00 = Literal Header Field without Indexing — New Name
        try out.append(allocator, 0x00);
        try appendHpackString(&out, allocator, h[0]);
        try appendHpackString(&out, allocator, h[1]);
    }
    return out.toOwnedSlice(allocator);
}

/// RFC 7540 §6.3 PRIORITY / HEADERS priority prefix (5 bytes).
pub const PriorityInfo = struct {
    exclusive: bool,
    depends_on: u31,
    /// Wire byte 0–255 meaning weight 1–256 (default 16 → wire 15).
    weight: u8,

    pub fn weightValue(self: PriorityInfo) u16 {
        return @as(u16, self.weight) + 1;
    }
};

pub const PriorityError = error{
    InvalidPriorityPayload,
};

/// Dependency tree + weighted fair pick among ready streams (RFC 7540 priority model).
pub const PriorityTree = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u31, Node),
    deficits: std.AutoHashMap(u31, i64),

    pub const Node = struct {
        parent: u31 = 0,
        /// Weight 1..=256 (not wire byte).
        weight: u16 = 16,
    };

    pub fn init(allocator: std.mem.Allocator) PriorityTree {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u31, Node).init(allocator),
            .deficits = std.AutoHashMap(u31, i64).init(allocator),
        };
    }

    pub fn deinit(self: *PriorityTree) void {
        self.nodes.deinit();
        self.deficits.deinit();
        self.* = undefined;
    }

    pub fn ensureStream(self: *PriorityTree, stream_id: u31) !void {
        if (stream_id == 0) return;
        const gop = try self.nodes.getOrPut(stream_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .parent = 0, .weight = 16 };
        }
    }

    /// Apply PRIORITY / HEADERS priority (exclusive reparenting + cycle guard).
    pub fn setPriority(self: *PriorityTree, stream_id: u31, info: PriorityInfo) !void {
        if (stream_id == 0) return;
        try self.ensureStream(stream_id);

        var parent = info.depends_on;
        if (parent == stream_id) parent = 0;
        if (parent != 0) try self.ensureStream(parent);

        // Cycle: parent is descendant of stream_id → fall back to root.
        if (parent != 0 and self.isAncestor(stream_id, parent)) parent = 0;

        const weight = info.weightValue();

        if (info.exclusive) {
            // Previous children of `parent` (except stream_id) become children of stream_id.
            // Parent 0 = connection root (RFC 7540 exclusive under root).
            var it = self.nodes.iterator();
            while (it.next()) |e| {
                if (e.key_ptr.* == stream_id) continue;
                if (e.value_ptr.parent == parent) {
                    e.value_ptr.parent = stream_id;
                }
            }
        }

        if (self.nodes.getPtr(stream_id)) |n| {
            n.* = .{ .parent = parent, .weight = weight };
        }
    }

    pub fn removeStream(self: *PriorityTree, stream_id: u31) void {
        if (stream_id == 0) return;
        const node = self.nodes.fetchRemove(stream_id) orelse {
            _ = self.deficits.remove(stream_id);
            return;
        };
        const new_parent = node.value.parent;
        var it = self.nodes.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.parent == stream_id) {
                e.value_ptr.parent = new_parent;
            }
        }
        _ = self.deficits.remove(stream_id);
    }

    pub fn parentOf(self: *const PriorityTree, stream_id: u31) u31 {
        if (self.nodes.get(stream_id)) |n| return n.parent;
        return 0;
    }

    pub fn weightOf(self: *const PriorityTree, stream_id: u31) u16 {
        if (self.nodes.get(stream_id)) |n| return n.weight;
        return 16;
    }

    fn isAncestor(self: *const PriorityTree, ancestor: u31, node: u31) bool {
        var cur = node;
        var guard: usize = 0;
        while (cur != 0 and guard < 256) : (guard += 1) {
            if (cur == ancestor) return true;
            cur = self.parentOf(cur);
        }
        return false;
    }

    fn sumChildrenWeights(self: *const PriorityTree, parent: u31) u32 {
        var sum: u32 = 0;
        var it = self.nodes.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.parent == parent) sum += e.value_ptr.weight;
        }
        return sum;
    }

    /// Absolute bandwidth share in fixed-point units (root = 1<<20).
    pub fn absoluteShare(self: *const PriorityTree, stream_id: u31) u64 {
        if (stream_id == 0) return 1 << 20;
        var share: u64 = 1 << 20;
        var cur = stream_id;
        var guard: usize = 0;
        while (cur != 0 and guard < 256) : (guard += 1) {
            const n = self.nodes.get(cur) orelse break;
            const sib_sum = self.sumChildrenWeights(n.parent);
            if (sib_sum == 0) break;
            share = share * n.weight / sib_sum;
            cur = n.parent;
        }
        return if (share == 0) 1 else share;
    }

    /// Weighted deficit round-robin among `ready` stream ids. Returns null if empty.
    pub fn pickNext(self: *PriorityTree, ready: []const u31) !?u31 {
        if (ready.len == 0) return null;
        if (ready.len == 1) return ready[0];

        var best_id: u31 = ready[0];
        var best_def: i64 = std.math.minInt(i64);
        var total_share: u64 = 0;

        for (ready) |sid| {
            try self.ensureStream(sid);
            const share: i64 = @intCast(self.absoluteShare(sid));
            total_share += @intCast(share);
            const gop = try self.deficits.getOrPut(sid);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += share;
            if (gop.value_ptr.* > best_def or (gop.value_ptr.* == best_def and sid < best_id)) {
                best_def = gop.value_ptr.*;
                best_id = sid;
            }
        }

        if (self.deficits.getPtr(best_id)) |d| {
            d.* -= @as(i64, @intCast(if (total_share == 0) 1 else total_share));
        }
        return best_id;
    }

    /// Order `ready` by repeated pickNext (stable weighted order for batch flush).
    pub fn orderReady(self: *PriorityTree, allocator: std.mem.Allocator, ready: []const u31) ![]u31 {
        if (ready.len == 0) return try allocator.alloc(u31, 0);
        var remaining = try allocator.alloc(u31, ready.len);
        defer allocator.free(remaining);
        @memcpy(remaining, ready);

        var out = try allocator.alloc(u31, ready.len);
        errdefer allocator.free(out);
        var n: usize = ready.len;
        var i: usize = 0;
        while (n > 0) : (i += 1) {
            const pick = (try self.pickNext(remaining[0..n])).?;
            out[i] = pick;
            // remove pick from remaining
            var j: usize = 0;
            while (j < n) : (j += 1) {
                if (remaining[j] == pick) {
                    remaining[j] = remaining[n - 1];
                    n -= 1;
                    break;
                }
            }
        }
        return out;
    }
};

/// Decode 5-byte PRIORITY payload (PRIORITY frame or HEADERS priority prefix).
pub fn decodePriority(payload: []const u8) PriorityError!PriorityInfo {
    if (payload.len < 5) return error.InvalidPriorityPayload;
    const dep_word: u32 =
        (@as(u32, payload[0]) << 24) |
        (@as(u32, payload[1]) << 16) |
        (@as(u32, payload[2]) << 8) |
        payload[3];
    const exclusive = (dep_word & 0x8000_0000) != 0;
    const depends_on: u31 = @truncate(dep_word & 0x7fff_ffff);
    return .{
        .exclusive = exclusive,
        .depends_on = depends_on,
        .weight = payload[4],
    };
}

fn encodePriorityPayload(info: PriorityInfo, out: *[5]u8) void {
    var dep: u32 = info.depends_on;
    if (info.exclusive) dep |= 0x8000_0000;
    out[0] = @truncate(dep >> 24);
    out[1] = @truncate(dep >> 16);
    out[2] = @truncate(dep >> 8);
    out[3] = @truncate(dep);
    out[4] = info.weight;
}

/// Encode a PRIORITY frame for `stream_id`.
pub fn encodePriority(allocator: std.mem.Allocator, stream_id: u31, info: PriorityInfo) ![]u8 {
    var payload: [5]u8 = undefined;
    encodePriorityPayload(info, &payload);
    return encodeFrame(allocator, .priority, 0, stream_id, &payload);
}

/// Strip optional 5-byte priority prefix from HEADERS payload when PRIORITY flag set.
pub fn stripHeadersPriority(payload: []const u8, flags: u8) PriorityError!struct { priority: ?PriorityInfo, header_block: []const u8 } {
    if ((flags & FrameFlags.priority) == 0) return .{ .priority = null, .header_block = payload };
    if (payload.len < 5) return error.InvalidPriorityPayload;
    const pri = try decodePriority(payload[0..5]);
    return .{ .priority = pri, .header_block = payload[5..] };
}

/// Case-insensitive substring search for ASCII haystack.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// True when request carries RFC 7540 §3.2 HTTP/1.1 Upgrade to h2c.
pub fn isH2cUpgrade(upgrade: []const u8, connection: []const u8, http2_settings: ?[]const u8) bool {
    if (http2_settings == null or http2_settings.?.len == 0) return false;
    if (!std.ascii.eqlIgnoreCase(upgrade, "h2c")) return false;
    return indexOfIgnoreCase(connection, "upgrade") != null;
}

pub fn encodeHeaders(allocator: std.mem.Allocator, stream_id: u31, header_block: []const u8, end_stream: bool, end_headers: bool) ![]u8 {
    var flags: u8 = 0;
    if (end_stream) flags |= FrameFlags.end_stream;
    if (end_headers) flags |= FrameFlags.end_headers;
    return encodeFrame(allocator, .headers, flags, stream_id, header_block);
}

/// Build a minimal gRPC response on one H2 stream: HEADERS + N DATA (grpc frames) + trailer HEADERS.
pub fn encodeGrpcServerStream(
    allocator: std.mem.Allocator,
    stream_id: u31,
    grpc_framed_body: []const u8,
    grpc_status: []const u8,
    grpc_message: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    const resp_hdrs = try encodeLiteralHeaderBlock(allocator, &.{
        .{ ":status", "200" },
        .{ "content-type", "application/grpc" },
    });
    defer allocator.free(resp_hdrs);
    const h1 = try encodeHeaders(allocator, stream_id, resp_hdrs, false, true);
    defer allocator.free(h1);
    try out.appendSlice(allocator, h1);

    // Split body into DATA frames (chunk ≤ 16KiB for realism).
    var off: usize = 0;
    while (off < grpc_framed_body.len) {
        const end = @min(off + 16 * 1024, grpc_framed_body.len);
        const chunk = grpc_framed_body[off..end];
        const last = end == grpc_framed_body.len;
        // DATA without END_STREAM — trailers carry end
        _ = last;
        const d = try encodeData(allocator, stream_id, chunk, false);
        defer allocator.free(d);
        try out.appendSlice(allocator, d);
        off = end;
    }

    const trailers = try encodeLiteralHeaderBlock(allocator, &.{
        .{ "grpc-status", grpc_status },
        .{ "grpc-message", grpc_message },
    });
    defer allocator.free(trailers);
    const h2 = try encodeHeaders(allocator, stream_id, trailers, true, true);
    defer allocator.free(h2);
    try out.appendSlice(allocator, h2);

    return out.toOwnedSlice(allocator);
}

fn appendHpackString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    // HPACK string: length as 7-bit prefix integer (H=0), then raw octets.
    if (s.len < 127) {
        try buf.append(allocator, @intCast(s.len));
    } else {
        try buf.append(allocator, 127);
        var rem = s.len - 127;
        while (rem >= 128) {
            try buf.append(allocator, @truncate((rem & 0x7f) | 0x80));
            rem >>= 7;
        }
        try buf.append(allocator, @truncate(rem));
    }
    try buf.appendSlice(allocator, s);
}

fn appendU16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    try buf.append(allocator, @truncate(v >> 8));
    try buf.append(allocator, @truncate(v));
}

fn appendU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    try buf.append(allocator, @truncate(v >> 24));
    try buf.append(allocator, @truncate(v >> 16));
    try buf.append(allocator, @truncate(v >> 8));
    try buf.append(allocator, @truncate(v));
}

test "HTTP/2 preface constant" {
    try std.testing.expectEqual(@as(usize, 24), connection_preface.len);
}

test "FrameHeader encode decode roundtrip" {
    var buf: [9]u8 = undefined;
    const hdr = FrameHeader{ .length = 12, .typ = .data, .flags = FrameFlags.end_stream, .stream_id = 3 };
    hdr.encode(&buf);
    const got = try FrameHeader.decode(&buf);
    try std.testing.expectEqual(@as(u24, 12), got.length);
    try std.testing.expectEqual(FrameType.data, got.typ);
    try std.testing.expectEqual(@as(u8, FrameFlags.end_stream), got.flags);
    try std.testing.expectEqual(@as(u31, 3), got.stream_id);
}

test "encodeData and decodeFrame" {
    const allocator = std.testing.allocator;
    const frame = try encodeData(allocator, 1, "hello", true);
    defer allocator.free(frame);
    const decoded = try decodeFrame(frame);
    try std.testing.expectEqual(FrameType.data, decoded.header.typ);
    try std.testing.expectEqual(@as(u31, 1), decoded.header.stream_id);
    try std.testing.expectEqualStrings("hello", decoded.payload);
    try std.testing.expect((decoded.header.flags & FrameFlags.end_stream) != 0);
}

test "encodeSettings ack empty payload" {
    const allocator = std.testing.allocator;
    const frame = try encodeSettings(allocator, true, &.{});
    defer allocator.free(frame);
    const decoded = try decodeFrame(frame);
    try std.testing.expectEqual(FrameType.settings, decoded.header.typ);
    try std.testing.expectEqual(@as(usize, 0), decoded.payload.len);
}

test "decodeWindowUpdate roundtrip with encodeWindowUpdate" {
    const allocator = std.testing.allocator;
    const increment: u31 = 32768;
    const frame = try encodeWindowUpdate(allocator, 1, increment);
    defer allocator.free(frame);
    const decoded = try decodeFrame(frame);
    try std.testing.expectEqual(FrameType.window_update, decoded.header.typ);
    try std.testing.expectEqual(@as(u31, 1), decoded.header.stream_id);
    try std.testing.expectEqual(increment, try decodeWindowUpdate(decoded.payload));
}

test "decodeWindowUpdate rejects zero increment" {
    const payload = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.ZeroWindowUpdateIncrement, decodeWindowUpdate(&payload));
}

test "decodeWindowUpdate rejects short payload" {
    const payload = [_]u8{ 0, 0, 1 };
    try std.testing.expectError(error.InvalidWindowUpdatePayload, decodeWindowUpdate(&payload));
}

test "FlowControlState consumeRecv replenishes at half threshold" {
    var fc = FlowControlState.init(default_initial_window_size);
    // Consume to just above half (32768 remaining after 32767 consumed).
    const inc1 = fc.consumeRecv(32767);
    try std.testing.expect(inc1 == null);
    try std.testing.expectEqual(@as(u31, 32768), fc.recv_window);
    // One more byte drops to half → replenish to initial.
    const inc2 = fc.consumeRecv(1);
    try std.testing.expectEqual(@as(u31, 32768), inc2.?);
    try std.testing.expectEqual(default_initial_window_size, fc.recv_window);
}

test "FlowControlState applyWindowUpdate and maxOutboundData" {
    var fc = FlowControlState.init(default_initial_window_size);
    fc.send_window = 1000;
    try fc.applyWindowUpdate(500);
    try std.testing.expectEqual(@as(u31, 1500), fc.send_window);
    try std.testing.expectEqual(@as(u31, 1500), fc.maxOutboundData(default_initial_window_size));
    fc.send_window = 0;
    try std.testing.expectEqual(@as(u31, 0), fc.maxOutboundData(default_initial_window_size));
}

test "FlowControlState consumeSend decrements send window" {
    var fc = FlowControlState.init(default_initial_window_size);
    fc.consumeSend(4096);
    try std.testing.expectEqual(default_initial_window_size - 4096, fc.send_window);
}

test "decodeSettings parses 6-byte pairs and accepts empty payload" {
    const allocator = std.testing.allocator;
    const empty = try decodeSettings(allocator, &.{});
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const payload = [_]u8{
        0x00, 0x04, 0x00, 0x00, 0xff, 0xff, // INITIAL_WINDOW_SIZE = 65535
        0x00, 0x05, 0x00, 0x00, 0x40, 0x00, // MAX_FRAME_SIZE = 16384
    };
    const got = try decodeSettings(allocator, &payload);
    defer allocator.free(got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(SettingsId.initial_window_size, got[0].id);
    try std.testing.expectEqual(@as(u32, 65535), got[0].value);
    try std.testing.expectEqual(SettingsId.max_frame_size, got[1].id);
    try std.testing.expectEqual(@as(u32, 16384), got[1].value);
}

test "decodeSettings rejects non-multiple-of-6 payload" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{ 0x00, 0x04, 0x00 };
    try std.testing.expectError(error.InvalidSettingsPayload, decodeSettings(allocator, &bad));
}

test "FlowControlState applyPeerInitialWindowSize adjusts send_window by delta" {
    var fc = FlowControlState.init(default_initial_window_size);
    fc.send_window = 10000;
    try fc.applyPeerInitialWindowSize(131072);
    try std.testing.expectEqual(@as(u31, 131072), fc.peer_initial);
    try std.testing.expectEqual(@as(u31, 10000 + (131072 - default_initial_window_size)), fc.send_window);

    // Shrink peer initial — send window decreases.
    try fc.applyPeerInitialWindowSize(default_initial_window_size);
    try std.testing.expectEqual(@as(u31, 10000), fc.send_window);

    // No-op when unchanged.
    try fc.applyPeerInitialWindowSize(default_initial_window_size);
    try std.testing.expectEqual(@as(u31, 10000), fc.send_window);
}

test "FlowControlState applyPeerInitialWindowSize rejects zero and underflow" {
    var fc = FlowControlState.init(default_initial_window_size);
    fc.send_window = 1000;
    try std.testing.expectError(error.InvalidInitialWindowSize, fc.applyPeerInitialWindowSize(0));
    try std.testing.expectError(error.FlowControlOverflow, fc.applyPeerInitialWindowSize(500));
}

test "decodePriority encodePriority roundtrip and exclusive bit" {
    const allocator = std.testing.allocator;
    const info = PriorityInfo{ .exclusive = true, .depends_on = 42, .weight = 15 };
    const frame = try encodePriority(allocator, 7, info);
    defer allocator.free(frame);
    const decoded = try decodeFrame(frame);
    try std.testing.expectEqual(FrameType.priority, decoded.header.typ);
    try std.testing.expectEqual(@as(u31, 7), decoded.header.stream_id);
    const got = try decodePriority(decoded.payload);
    try std.testing.expect(got.exclusive);
    try std.testing.expectEqual(@as(u31, 42), got.depends_on);
    try std.testing.expectEqual(@as(u8, 15), got.weight);
}

test "decodePriority rejects short payload" {
    const bad = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidPriorityPayload, decodePriority(&bad));
}

test "stripHeadersPriority removes 5-byte prefix" {
    var payload: [8]u8 = undefined;
    encodePriorityPayload(.{ .exclusive = false, .depends_on = 3, .weight = 20 }, payload[0..5]);
    payload[5] = 0x82; // indexed :method GET
    payload[6] = 0x84; // indexed :path /
    payload[7] = 0x86; // indexed :scheme http
    const stripped = try stripHeadersPriority(&payload, FrameFlags.priority);
    try std.testing.expect(stripped.priority != null);
    try std.testing.expectEqual(@as(u31, 3), stripped.priority.?.depends_on);
    try std.testing.expectEqual(@as(usize, 3), stripped.header_block.len);
}

test "isH2cUpgrade detects valid upgrade request" {
    try std.testing.expect(isH2cUpgrade("h2c", "Upgrade, keep-alive", "AQA="));
    try std.testing.expect(isH2cUpgrade("H2C", "keep-alive, Upgrade", "x"));
    try std.testing.expect(!isH2cUpgrade("websocket", "Upgrade", "AQA="));
    try std.testing.expect(!isH2cUpgrade("h2c", "close", "AQA="));
    try std.testing.expect(!isH2cUpgrade("h2c", "Upgrade", null));
}

test "PriorityTree exclusive reparents siblings" {
    const allocator = std.testing.allocator;
    var tree = PriorityTree.init(allocator);
    defer tree.deinit();

    try tree.setPriority(1, .{ .exclusive = false, .depends_on = 0, .weight = 15 });
    try tree.setPriority(3, .{ .exclusive = false, .depends_on = 0, .weight = 15 });
    try tree.setPriority(5, .{ .exclusive = true, .depends_on = 0, .weight = 31 });

    try std.testing.expectEqual(@as(u31, 0), tree.parentOf(5));
    try std.testing.expectEqual(@as(u31, 5), tree.parentOf(1));
    try std.testing.expectEqual(@as(u31, 5), tree.parentOf(3));
    try std.testing.expectEqual(@as(u16, 32), tree.weightOf(5));
}

test "PriorityTree pickNext prefers higher weight" {
    const allocator = std.testing.allocator;
    var tree = PriorityTree.init(allocator);
    defer tree.deinit();

    try tree.setPriority(1, .{ .exclusive = false, .depends_on = 0, .weight = 0 }); // weight 1
    try tree.setPriority(3, .{ .exclusive = false, .depends_on = 0, .weight = 255 }); // weight 256

    var counts = [_]usize{ 0, 0 };
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const pick = (try tree.pickNext(&.{ 1, 3 })).?;
        if (pick == 1) counts[0] += 1 else counts[1] += 1;
    }
    try std.testing.expect(counts[1] > counts[0]);
    try std.testing.expect(counts[1] >= 50);
}

test "PriorityTree absoluteShare splits among siblings" {
    const allocator = std.testing.allocator;
    var tree = PriorityTree.init(allocator);
    defer tree.deinit();
    try tree.setPriority(1, .{ .exclusive = false, .depends_on = 0, .weight = 15 }); // 16
    try tree.setPriority(3, .{ .exclusive = false, .depends_on = 0, .weight = 47 }); // 48
    const s1 = tree.absoluteShare(1);
    const s3 = tree.absoluteShare(3);
    try std.testing.expect(s3 > s1);
    // 48:16 = 3:1
    try std.testing.expectEqual(s1 * 3, s3);
}

test "PriorityTree orderReady returns all streams" {
    const allocator = std.testing.allocator;
    var tree = PriorityTree.init(allocator);
    defer tree.deinit();
    try tree.setPriority(1, .{ .exclusive = false, .depends_on = 0, .weight = 15 });
    try tree.setPriority(3, .{ .exclusive = false, .depends_on = 0, .weight = 15 });
    const ordered = try tree.orderReady(allocator, &.{ 1, 3 });
    defer allocator.free(ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expect((ordered[0] == 1 and ordered[1] == 3) or (ordered[0] == 3 and ordered[1] == 1));
}

test "PriorityTree cycle falls back to root" {
    const allocator = std.testing.allocator;
    var tree = PriorityTree.init(allocator);
    defer tree.deinit();
    try tree.setPriority(1, .{ .exclusive = false, .depends_on = 0, .weight = 15 });
    try tree.setPriority(3, .{ .exclusive = false, .depends_on = 1, .weight = 15 });
    // 1 depends on 3 would cycle → parent becomes 0
    try tree.setPriority(1, .{ .exclusive = false, .depends_on = 3, .weight = 15 });
    try std.testing.expectEqual(@as(u31, 0), tree.parentOf(1));
    try std.testing.expectEqual(@as(u31, 1), tree.parentOf(3));
}

test "encodeGrpcServerStream produces headers+data+trailers" {
    const allocator = std.testing.allocator;
    // one empty grpc frame: flag + len0
    const grpc_body = [_]u8{ 0, 0, 0, 0, 0 };
    const wire = try encodeGrpcServerStream(allocator, 1, &grpc_body, "0", "");
    defer allocator.free(wire);

    var off: usize = 0;
    var saw_data = false;
    var frames: usize = 0;
    while (off + 9 <= wire.len) {
        const f = try decodeFrame(wire[off..]);
        frames += 1;
        if (f.header.typ == .data) saw_data = true;
        off += 9 + @as(usize, f.header.length);
    }
    try std.testing.expect(frames >= 3);
    try std.testing.expect(saw_data);
}
