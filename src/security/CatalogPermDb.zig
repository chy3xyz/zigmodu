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
///
/// Each call is bound to its own client: two loaders built from two clients
/// (two permission databases) read their own table and never each other's.
/// See `max_loader_slots` for how that is possible for a bare function pointer.
pub fn loaderFromClient(client: *sqlx.Client) http_middleware.CatalogPermissionLoader {
    const slot = LoaderSlots.claimed.fetchAdd(1, .seq_cst);
    if (slot >= max_loader_slots) {
        @panic("CatalogPermDb.loaderFromClient: loader slot pool exhausted — raise max_loader_slots");
    }
    LoaderSlots.clients[slot] = client;
    return loader_trampolines[slot];
}

/// Number of independently bound loaders one process may build.
///
/// `CatalogPermissionLoader` is a bare `*const fn(allocator, input)` declared in
/// `api/Middleware.zig`, and a Zig function pointer carries no context — so the
/// client has to be reached through *the function itself*. Each
/// `loaderFromClient` call therefore claims one slot and returns that slot's own
/// trampoline, which resolves its own client and nothing else.
///
/// A function-level `var` (the shape this replaced) is process-wide instead: the
/// second `loaderFromClient` would retarget the first loader too, so two
/// permission databases would answer for each other. Giving the loader a
/// context-carrying type would fix it without a bound, but `CatalogPermissionLoader`
/// itself is public API (`api/Middleware.zig`, passed as a bare fn pointer by
/// the two example apps, the CLI template and `docs/ROUTE_TABLE.md`), so the
/// bound is the price of leaving that type — and every call site — alone.
///
/// Slots are claimed at wiring time and never released, so this bounds how many
/// loaders an application *builds*, not how many requests it serves.
pub const max_loader_slots = 64;

const LoaderSlots = struct {
    /// One client per claimed slot; unclaimed slots stay `null` and are not
    /// reachable — their trampolines are never handed out.
    var clients: [max_loader_slots]?*sqlx.Client = @splat(null);
    /// Atomic so two threads wiring loaders concurrently cannot claim one slot
    /// (which would put two loaders on one client again).
    var claimed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
};

fn LoaderTrampoline(comptime slot: usize) type {
    return struct {
        fn load(allocator: std.mem.Allocator, input: http_middleware.CatalogPermLoadInput) anyerror![]u8 {
            // Fail closed rather than guess: reaching this means the pointer was
            // used without claiming a slot. The caller
            // (`verifyJwtLoadPermsAndNext`) turns a loader error into a 500.
            const client = LoaderSlots.clients[slot] orelse return error.LoaderSlotEmpty;
            return permissionsCsv(allocator, client, input.roles);
        }
    };
}

/// One distinct function pointer per slot — the identity a bare fn pointer
/// cannot otherwise carry. Every entry reads a different slot, so they are not
/// interchangeable and no optimizer may fold them into one.
const loader_trampolines: [max_loader_slots]http_middleware.CatalogPermissionLoader = blk: {
    var table: [max_loader_slots]http_middleware.CatalogPermissionLoader = undefined;
    for (0..max_loader_slots) |i| table[i] = LoaderTrampoline(i).load;
    break :blk table;
};

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

test "each loaderFromClient reads its own database" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client_a = try sqlx.Client.open(allocator, io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 1,
    });
    defer client_a.deinit();
    var client_b = try sqlx.Client.open(allocator, io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 1,
    });
    defer client_b.deinit();

    try ensureSchema(&client_a);
    try ensureSchema(&client_b);
    try grant(&client_a, "admin", "tenant:a-only");
    try grant(&client_b, "admin", "tenant:b-only");

    // Two loaders, two permission databases. While the client lived in a
    // function-level `var`, the second `loaderFromClient` retargeted the first
    // loader too, so A's middleware answered from B's table.
    const load_a = loaderFromClient(&client_a);
    const load_b = loaderFromClient(&client_b);

    const csv_a = try load_a(allocator, .{ .sub = "u1", .aud = "t1", .roles = &.{"admin"} });
    defer allocator.free(csv_a);
    try std.testing.expect(std.mem.indexOf(u8, csv_a, "tenant:a-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv_a, "tenant:b-only") == null);

    const csv_b = try load_b(allocator, .{ .sub = "u1", .aud = "t1", .roles = &.{"admin"} });
    defer allocator.free(csv_b);
    try std.testing.expect(std.mem.indexOf(u8, csv_b, "tenant:b-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv_b, "tenant:a-only") == null);
}
