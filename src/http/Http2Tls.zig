//! HTTP/2 TLS / ALPN helpers.
//!
//! Zig 0.17 `std.crypto.tls` exposes a **client** stack; there is no stdlib TLS
//! server yet. Production HTTPS+h2 typically terminates TLS in a sidecar
//! (nginx / Caddy / Envoy) with `alpn h2`, then forwards cleartext h2c or
//! HTTP/1.1 to ZigModu.
//!
//! This module documents the ALPN identity and provides a small config surface
//! so apps can declare intent (`enable_alpn_h2`) without pretending server TLS
//! exists in-process.

const std = @import("std");

/// IANA ALPN protocol id for HTTP/2 (RFC 7301 / RFC 7540).
pub const alpn_h2: []const u8 = "h2";

/// Also advertise HTTP/1.1 for dual-stack terminators.
pub const alpn_http_1_1: []const u8 = "http/1.1";

pub const preferred_alpn = [_][]const u8{ alpn_h2, alpn_http_1_1 };

pub const TlsFrontConfig = struct {
    /// When true, operators should configure the TLS terminator to offer `h2`.
    enable_alpn_h2: bool = true,
    /// Path hints for sidecar / future in-process server TLS (unused by runtime today).
    cert_path: ?[]const u8 = null,
    key_path: ?[]const u8 = null,
    /// Expected SNI / host for docs and client helpers.
    server_name: ?[]const u8 = null,

    pub fn alpnList(self: TlsFrontConfig) []const []const u8 {
        if (self.enable_alpn_h2) return &preferred_alpn;
        return &[_][]const u8{alpn_http_1_1};
    }
};

/// Returns true if `proto` is the HTTP/2 ALPN id.
pub fn isHttp2Alpn(proto: []const u8) bool {
    return std.mem.eql(u8, proto, alpn_h2);
}

/// Nginx / Caddy style snippet for operators (not executed).
pub fn sidecarHint(allocator: std.mem.Allocator, listen_port: u16, backend_port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\# Terminate TLS with ALPN h2, forward cleartext to ZigModu h2c/HTTP
        \\# listen {d} ssl http2;
        \\# proxy_pass http://127.0.0.1:{d};
    , .{ listen_port, backend_port });
}

test "ALPN helpers" {
    try std.testing.expect(isHttp2Alpn("h2"));
    try std.testing.expect(!isHttp2Alpn("http/1.1"));
    var cfg = TlsFrontConfig{};
    try std.testing.expectEqual(@as(usize, 2), cfg.alpnList().len);
    cfg.enable_alpn_h2 = false;
    try std.testing.expectEqual(@as(usize, 1), cfg.alpnList().len);

    const allocator = std.testing.allocator;
    const hint = try sidecarHint(allocator, 443, 8080);
    defer allocator.free(hint);
    try std.testing.expect(std.mem.indexOf(u8, hint, "h2") != null);
}
