//! Deprecated top-level re-exports — scheduled removal in **v0.14.0**.
//!
//! Prefer canonical domain imports:
//! ```zig
//! const http = @import("zigmodu").http;
//! const data = @import("zigmodu").data;
//! const sec  = @import("zigmodu").security;
//! ```
//!
//! See `docs/API-MIGRATION.md` § Domain Import Convergence.

pub const REMOVAL_VERSION: []const u8 = "0.14.0";

pub const http_server = @import("api/Server.zig");

pub const sqlx = @import("sqlx/sqlx.zig");
pub const orm = @import("persistence/Orm.zig");
pub const SqlxBackend = @import("persistence/backends/SqlxBackend.zig").SqlxBackend;

pub const PasswordEncoder = @import("security/PasswordEncoder.zig").PasswordEncoder;
pub const SecurityModule = @import("security/SecurityModule.zig").SecurityModule;

pub const Cache = @import("cache/Lru.zig").Cache;

test "deprecated aliases match domain exports" {
    const http = @import("http.zig");
    const data = @import("data.zig");
    const security = @import("security.zig");

    try std.testing.expect(@TypeOf(http_server.Server) == @TypeOf(http.Server));
    try std.testing.expect(@TypeOf(sqlx.Client) == @TypeOf(data.Client));
    try std.testing.expect(@TypeOf(PasswordEncoder) == @TypeOf(security.PasswordEncoder));
    try std.testing.expectEqualStrings("0.14.0", REMOVAL_VERSION);
}

const std = @import("std");
