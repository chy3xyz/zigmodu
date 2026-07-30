//! HTTP/2 frame codec (RFC 7540) — framing + SETTINGS/DATA/HEADERS/WINDOW_UPDATE/PING/GOAWAY/RST.
//!
//! Scope: wire helpers for gRPC-over-H2. Not a full multiplexed connection manager
//! (no priority tree, no push, simplified HPACK literal-only header blocks).

const std = @import("std");

pub const connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

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
    const v: u32 = increment;
    payload[0] = @truncate(v >> 24);
    payload[1] = @truncate(v >> 16);
    payload[2] = @truncate(v >> 8);
    payload[3] = @truncate(v);
    return encodeFrame(allocator, .window_update, 0, stream_id, &payload);
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
