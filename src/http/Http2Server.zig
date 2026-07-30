//! HTTP/2 prior-knowledge connection loop (cleartext h2c).
//!
//! After the client sends the connection preface, this module:
//! 1. Sends SETTINGS + ACK
//! 2. Reads frames (SETTINGS / PING / WINDOW_UPDATE / GOAWAY / HEADERS / DATA)
//! 3. Optionally dispatches gRPC unary/server-stream via `GrpcServiceRegistry`
//!
//! Not a full multiplexed HTTP/2 server (no push, limited HPACK).

const std = @import("std");
const Http2 = @import("Http2.zig");
const Grpc = @import("../extensions/GrpcTransport.zig");

pub const ServeOptions = struct {
    /// When set, `:path` + `content-type: application/grpc` → registry dispatch.
    grpc_registry: ?*Grpc.GrpcServiceRegistry = null,
    /// Max frames to process before returning (tests / idle cap).
    max_frames: usize = 256,
};

/// Serve one prior-knowledge HTTP/2 connection. Preface must already be consumed.
pub fn serveAfterPreface(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    opts: ServeOptions,
) !void {
    // Server SETTINGS
    const settings = try Http2.encodeSettings(allocator, false, &.{
        .{ 0x3, 100 }, // MAX_CONCURRENT_STREAMS
        .{ 0x4, 65535 }, // INITIAL_WINDOW_SIZE
    });
    defer allocator.free(settings);
    try writeAll(io, stream, settings);

    var streams = std.AutoHashMap(u31, StreamState).init(allocator);
    defer {
        var it = streams.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        streams.deinit();
    }

    var frames: usize = 0;
    while (frames < opts.max_frames) : (frames += 1) {
        const frame_buf = readFrame(io, stream, allocator) catch |err| switch (err) {
            error.ConnectionClosed, error.EndOfStream => return,
            else => return err,
        };
        defer allocator.free(frame_buf);

        const frame = try Http2.decodeFrame(frame_buf);
        switch (frame.header.typ) {
            .settings => {
                if ((frame.header.flags & Http2.FrameFlags.ack) == 0) {
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
            .window_update, .priority, .rst_stream => {},
            .goaway => return,
            .headers => {
                const sid = frame.header.stream_id;
                const gop = try streams.getOrPut(sid);
                if (!gop.found_existing) gop.value_ptr.* = StreamState.init();
                try gop.value_ptr.appendHeaders(allocator, frame.payload);
                if ((frame.header.flags & Http2.FrameFlags.end_stream) != 0) {
                    try finishStream(io, stream, allocator, sid, gop.value_ptr, opts);
                    _ = streams.remove(sid);
                }
            },
            .data => {
                const sid = frame.header.stream_id;
                const st = streams.getPtr(sid) orelse continue;
                try st.appendData(allocator, frame.payload);
                if ((frame.header.flags & Http2.FrameFlags.end_stream) != 0) {
                    try finishStream(io, stream, allocator, sid, st, opts);
                    var removed = streams.fetchRemove(sid).?;
                    removed.value.deinit(allocator);
                }
            },
            .continuation => {
                const sid = frame.header.stream_id;
                if (streams.getPtr(sid)) |st| try st.appendHeaders(allocator, frame.payload);
            },
            .push_promise => {},
        }
    }
}

const StreamState = struct {
    header_block: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,

    fn init() StreamState {
        return .{};
    }

    fn deinit(self: *StreamState, allocator: std.mem.Allocator) void {
        self.header_block.deinit(allocator);
        self.data.deinit(allocator);
        self.* = undefined;
    }

    fn appendHeaders(self: *StreamState, allocator: std.mem.Allocator, chunk: []const u8) !void {
        try self.header_block.appendSlice(allocator, chunk);
    }

    fn appendData(self: *StreamState, allocator: std.mem.Allocator, chunk: []const u8) !void {
        try self.data.appendSlice(allocator, chunk);
    }
};

fn finishStream(
    io: std.Io,
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    stream_id: u31,
    st: *StreamState,
    opts: ServeOptions,
) !void {
    const hdrs = try decodeSimpleHeaders(allocator, st.header_block.items);
    defer {
        allocator.free(hdrs.method);
        allocator.free(hdrs.path);
        allocator.free(hdrs.content_type);
    }

    const is_grpc = std.mem.indexOf(u8, hdrs.content_type, "application/grpc") != null;
    if (is_grpc) {
        if (opts.grpc_registry) |reg| {
            const path = hdrs.path;
            // Prefer server-stream if registered; else unary.
            if (reg.findMethod(path)) |method| {
                if (method.method_type == .server_streaming) {
                    var result = try reg.handleHttpServerStream(path, st.data.items, stream_id);
                    defer result.deinit(allocator);
                    if (result.http2_wire) |wire| {
                        try writeAll(io, stream, wire);
                        return;
                    }
                }
            }
            var unary = try reg.handleHttpUnary(path, st.data.items);
            defer unary.deinit(allocator);
            const status_str = try std.fmt.allocPrint(allocator, "{d}", .{@intFromEnum(unary.grpc_status)});
            defer allocator.free(status_str);
            const wire = try Http2.encodeGrpcServerStream(allocator, stream_id, unary.body, status_str, unary.grpc_message);
            defer allocator.free(wire);
            try writeAll(io, stream, wire);
            return;
        }
    }

    // Default: 404 HEADERS+empty DATA
    const block = try Http2.encodeLiteralHeaderBlock(allocator, &.{
        .{ ":status", "404" },
        .{ "content-type", "text/plain" },
    });
    defer allocator.free(block);
    const h = try Http2.encodeHeaders(allocator, stream_id, block, false, true);
    defer allocator.free(h);
    try writeAll(io, stream, h);
    const d = try Http2.encodeData(allocator, stream_id, "not found", true);
    defer allocator.free(d);
    try writeAll(io, stream, d);
    _ = hdrs.method;
}

const DecodedHeaders = struct {
    method: []u8,
    path: []u8,
    content_type: []u8,
};

/// Minimal HPACK: static indexed + literal-without-indexing (new name / indexed name).
fn decodeSimpleHeaders(allocator: std.mem.Allocator, block: []const u8) !DecodedHeaders {
    var method: []u8 = try allocator.dupe(u8, "POST");
    errdefer allocator.free(method);
    var path: []u8 = try allocator.dupe(u8, "/");
    errdefer allocator.free(path);
    var content_type: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(content_type);

    var i: usize = 0;
    while (i < block.len) {
        const b = block[i];
        if (b & 0x80 != 0) {
            // Indexed Header Field
            const idx = b & 0x7f;
            i += 1;
            applyStatic(allocator, idx, &method, &path, &content_type) catch {};
            continue;
        }
        if (b == 0x00 or b == 0x10 or (b & 0x40) != 0) {
            // Literal — new name (simplified: treat as name+value strings)
            i += 1;
            if (i >= block.len) break;
            const name, const n1 = try readHpackString(block[i..]);
            i += n1;
            const value, const n2 = try readHpackString(block[i..]);
            i += n2;
            if (std.mem.eql(u8, name, ":method")) {
                allocator.free(method);
                method = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, name, ":path")) {
                allocator.free(path);
                path = try allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, name, "content-type")) {
                allocator.free(content_type);
                content_type = try allocator.dupe(u8, value);
            }
            continue;
        }
        // Indexed name literal (0x01-0x0f without indexing, or 0x40+ with index)
        if (b & 0x0f != 0 and (b & 0xf0) == 0) {
            const idx = b & 0x0f;
            i += 1;
            const value, const n2 = try readHpackString(block[i..]);
            i += n2;
            applyStaticValue(allocator, idx, value, &method, &path, &content_type) catch {};
            continue;
        }
        // Skip unknown byte to avoid infinite loop
        i += 1;
    }

    return .{ .method = method, .path = path, .content_type = content_type };
}

fn applyStatic(allocator: std.mem.Allocator, idx: u8, method: *[]u8, path: *[]u8, _: *[]u8) !void {
    switch (idx) {
        2 => {
            allocator.free(method.*);
            method.* = try allocator.dupe(u8, "GET");
        },
        3 => {
            allocator.free(method.*);
            method.* = try allocator.dupe(u8, "POST");
        },
        4 => {
            allocator.free(path.*);
            path.* = try allocator.dupe(u8, "/");
        },
        else => {},
    }
}

fn applyStaticValue(allocator: std.mem.Allocator, idx: u8, value: []const u8, method: *[]u8, path: *[]u8, content_type: *[]u8) !void {
    switch (idx) {
        2, 3 => {
            allocator.free(method.*);
            method.* = try allocator.dupe(u8, value);
        },
        4, 5 => {
            allocator.free(path.*);
            path.* = try allocator.dupe(u8, value);
        },
        31 => { // content-type in static table
            allocator.free(content_type.*);
            content_type.* = try allocator.dupe(u8, value);
        },
        else => {},
    }
}

fn readHpackString(buf: []const u8) !struct { []const u8, usize } {
    if (buf.len == 0) return error.InvalidHpack;
    if (buf[0] & 0x80 != 0) return error.HuffmanNotSupported;
    const len: usize = buf[0] & 0x7f;
    if (1 + len > buf.len) return error.InvalidHpack;
    return .{ buf[1 .. 1 + len], 1 + len };
}

fn readFrame(io: std.Io, stream: std.Io.net.Stream, allocator: std.mem.Allocator) ![]u8 {
    var hdr: [9]u8 = undefined;
    try readExact(io, stream, &hdr);
    const header = try Http2.FrameHeader.decode(&hdr);
    const total = 9 + @as(usize, header.length);
    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    @memcpy(buf[0..9], &hdr);
    if (header.length > 0) try readExact(io, stream, buf[9..]);
    return buf;
}

fn readExact(io: std.Io, stream: std.Io.net.Stream, buf: []u8) !void {
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    r.interface.readSliceAll(buf) catch |err| switch (err) {
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

test "decodeSimpleHeaders literal path" {
    const allocator = std.testing.allocator;
    const block = try Http2.encodeLiteralHeaderBlock(allocator, &.{
        .{ ":method", "POST" },
        .{ ":path", "/echo.Echo/Say" },
        .{ "content-type", "application/grpc" },
    });
    defer allocator.free(block);
    const h = try decodeSimpleHeaders(allocator, block);
    defer {
        allocator.free(h.method);
        allocator.free(h.path);
        allocator.free(h.content_type);
    }
    try std.testing.expectEqualStrings("POST", h.method);
    try std.testing.expectEqualStrings("/echo.Echo/Say", h.path);
    try std.testing.expectEqualStrings("application/grpc", h.content_type);
}
