//! Emit a signed JWT for CI / local probes.
//! Usage: JWT_SECRET=dev-secret ./zig-out/bin/gen-jwt-token
const std = @import("std");
const zmodu = @import("zigmodu");
const SecurityModule = zmodu.security.SecurityModule;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const secret = init.environ_map.get("JWT_SECRET") orelse "dev-secret";
    const sub = init.environ_map.get("JWT_SUB") orelse "ci-user";

    var sec = SecurityModule.initWithIo(allocator, secret, 3600, init.io);
    const token = try sec.generateToken(sub, &.{});
    defer allocator.free(token);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, token);
    try stdout.writeStreamingAll(init.io, "\n");
}
