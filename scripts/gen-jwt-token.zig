//! Emit a signed JWT for CI / local probes.
//! Usage: JWT_SECRET=dev-secret ./zig-out/bin/gen-jwt-token
//! Optional: JWT_SUB=ci-user JWT_ROLES=admin,user
const std = @import("std");
const zmodu = @import("zigmodu");
const SecurityModule = zmodu.security.SecurityModule;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const secret = init.environ_map.get("JWT_SECRET") orelse "dev-secret";
    const sub = init.environ_map.get("JWT_SUB") orelse "ci-user";

    var owned_roles: ?[]const []const u8 = null;
    defer if (owned_roles) |r| allocator.free(r);

    const roles: []const []const u8 = if (init.environ_map.get("JWT_ROLES")) |raw| blk: {
        var list = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |p| {
            const t = std.mem.trim(u8, p, " ");
            if (t.len > 0) try list.append(allocator, t);
        }
        owned_roles = try list.toOwnedSlice(allocator);
        break :blk owned_roles.?;
    } else &.{ "admin", "user" };

    var sec = SecurityModule.initWithIo(allocator, secret, 3600, init.io);
    const token = try sec.generateToken(sub, roles);
    defer allocator.free(token);

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, token);
    try stdout.writeStreamingAll(init.io, "\n");
}
