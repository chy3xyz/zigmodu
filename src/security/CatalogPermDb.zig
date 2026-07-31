//! SQLite-backed role → permission loader for ComptimeRouter catalog JWT.
//!
//! Pair with `http.jwtAuthFromCatalogWithPermissions` + `permissionGateWith(.{ .mode = .rbac })`.
//! Does not touch `ctx.user_data` (safe with ComptimeRouter).
//!
//! Schema:
//!   CREATE TABLE role_permission (
//!     role_name  TEXT NOT NULL,
//!     permission TEXT NOT NULL,
//!     PRIMARY KEY (role_name, permission)
//!   );

const std = @import("std");
const sqlx = @import("../sqlx/sqlx.zig");
const http_middleware = @import("../api/Middleware.zig");

pub const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS role_permission (
    \\    role_name TEXT NOT NULL,
    \\    permission TEXT NOT NULL,
    \\    PRIMARY KEY (role_name, permission)
    \\)
;

pub fn ensureSchema(client: *sqlx.Client) !void {
    _ = try client.exec(SCHEMA, &.{});
}

pub fn grant(client: *sqlx.Client, role: []const u8, permission: []const u8) !void {
    _ = try client.exec(
        "INSERT OR IGNORE INTO role_permission (role_name, permission) VALUES (?, ?)",
        &.{ .{ .string = role }, .{ .string = permission } },
    );
}

/// Collect unique permission codes for JWT role names into an owned CSV.
pub fn permissionsCsv(allocator: std.mem.Allocator, client: *sqlx.Client, roles: []const []const u8) ![]u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    for (roles) |role| {
        var rows = try client.query(
            "SELECT permission FROM role_permission WHERE role_name = ?",
            &.{.{ .string = role }},
        );
        defer rows.deinit();
        for (rows.rows) |*row| {
            const v = row.get("permission") orelse continue;
            const p = switch (v) {
                .string => |s| s,
                else => continue,
            };
            var dup = false;
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, p)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try list.append(allocator, try allocator.dupe(u8, p));
        }
    }

    if (list.items.len == 0) return try allocator.dupe(u8, "");

    var total: usize = 0;
    for (list.items, 0..) |p, i| {
        total += p.len;
        if (i > 0) total += 1;
    }
    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (list.items, 0..) |p, i| {
        if (i > 0) {
            buf[off] = ',';
            off += 1;
        }
        @memcpy(buf[off..][0..p.len], p);
        off += p.len;
    }
    return buf;
}

/// Build a `CatalogPermissionLoader` bound to `client` (must outlive the middleware).
/// Ignores `sub`/`aud` — maps JWT role names via `role_permission` only.
pub fn loaderFromClient(client: *sqlx.Client) http_middleware.CatalogPermissionLoader {
    const Holder = struct {
        var db: *sqlx.Client = undefined;
        fn load(allocator: std.mem.Allocator, input: http_middleware.CatalogPermLoadInput) anyerror![]u8 {
            return permissionsCsv(allocator, @This().db, input.roles);
        }
    };
    Holder.db = client;
    return Holder.load;
}

test "CatalogPermDb loads permissions from sqlite" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var client = try sqlx.Client.open(allocator, io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 1,
    });
    defer client.deinit();

    try ensureSchema(&client);
    try grant(&client, "admin", "tenant:suspend");
    try grant(&client, "admin", "tenant:read");
    try grant(&client, "user", "tenant:read");

    const csv = try permissionsCsv(allocator, &client, &.{"admin"});
    defer allocator.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "tenant:suspend") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "tenant:read") != null);

    const user_csv = try permissionsCsv(allocator, &client, &.{"user"});
    defer allocator.free(user_csv);
    try std.testing.expect(std.mem.indexOf(u8, user_csv, "tenant:suspend") == null);
    try std.testing.expect(std.mem.indexOf(u8, user_csv, "tenant:read") != null);
}
