//! Shared DB driver link helpers for zigmodu / examples `build.zig`.
//! Build-scripts only — not part of the runtime library.

const std = @import("std");

pub const Features = struct {
    sqlite: bool = false,
    postgres: bool = false,
    mysql: bool = false,

    pub const all: Features = .{ .sqlite = true, .postgres = true, .mysql = true };
    pub const sqlite_only: Features = .{ .sqlite = true, .postgres = false, .mysql = false };

    pub fn any(self: Features) bool {
        return self.sqlite or self.postgres or self.mysql;
    }
};

pub const ParseError = error{InvalidDbOption};

/// Parse `-Ddb=` value: `all` | `sqlite` | `postgres` | `mysql` | comma-list.
pub fn parseDb(s: []const u8) ParseError!Features {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDbOption;
    if (std.mem.eql(u8, trimmed, "all")) return Features.all;
    if (std.mem.eql(u8, trimmed, "none") or std.mem.eql(u8, trimmed, "off")) return .{};

    var features: Features = .{};
    var it = std.mem.splitScalar(u8, trimmed, ',');
    var saw_any = false;
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        saw_any = true;
        if (std.mem.eql(u8, part, "all")) {
            return Features.all;
        } else if (std.mem.eql(u8, part, "sqlite")) {
            features.sqlite = true;
        } else if (std.mem.eql(u8, part, "postgres") or std.mem.eql(u8, part, "postgresql") or std.mem.eql(u8, part, "pg")) {
            features.postgres = true;
        } else if (std.mem.eql(u8, part, "mysql") or std.mem.eql(u8, part, "mariadb")) {
            features.mysql = true;
        } else {
            return error.InvalidDbOption;
        }
    }
    if (!saw_any or !features.any()) return error.InvalidDbOption;
    return features;
}

pub fn addToOptions(options: *std.Build.Step.Options, features: Features) void {
    options.addOption(bool, "enable_sqlite", features.sqlite);
    options.addOption(bool, "enable_postgres", features.postgres);
    options.addOption(bool, "enable_mysql", features.mysql);
}

const CLibPaths = struct {
    include: ?[]const u8 = null,
    lib: ?[]const u8 = null,
};

fn dirExists(b: *std.Build, path: []const u8) bool {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch return false;
    return true;
}

fn detectPqPaths(b: *std.Build) CLibPaths {
    if (b.graph.environ_map.get("PQ_INCLUDE")) |inc| {
        return .{ .include = b.dupe(inc), .lib = b.graph.environ_map.get("PQ_LIB") };
    }
    const host_target = b.graph.host.result;
    if (host_target.os.tag == .macos) {
        if (dirExists(b, "/opt/homebrew/opt/libpq")) {
            return .{
                .include = "/opt/homebrew/opt/libpq/include",
                .lib = "/opt/homebrew/opt/libpq/lib",
            };
        }
        if (dirExists(b, "/usr/local/opt/libpq")) {
            return .{
                .include = "/usr/local/opt/libpq/include",
                .lib = "/usr/local/opt/libpq/lib",
            };
        }
    } else if (host_target.os.tag == .linux) {
        const lib_dir = if (host_target.cpu.arch == .aarch64) "/usr/lib/aarch64-linux-gnu" else "/usr/lib/x86_64-linux-gnu";
        const candidates = &[_][]const u8{
            "/usr/include/postgresql",
            "/usr/include/pgsql",
            "/usr/pgsql/include",
        };
        for (candidates) |c| {
            if (dirExists(b, c)) {
                return .{ .include = c, .lib = lib_dir };
            }
        }
    }
    return .{};
}

fn detectMysqlPaths(b: *std.Build) CLibPaths {
    if (b.graph.environ_map.get("MYSQL_INCLUDE")) |inc| {
        return .{ .include = b.dupe(inc), .lib = b.graph.environ_map.get("MYSQL_LIB") };
    }
    const host_target = b.graph.host.result;
    if (host_target.os.tag == .macos) {
        const prefixes = &[_][]const u8{
            "/opt/homebrew/opt/mariadb-connector-c",
            "/usr/local/opt/mariadb-connector-c",
            "/opt/homebrew/opt/mysql-client",
            "/usr/local/opt/mysql-client",
            "/opt/homebrew/opt/mysql",
            "/usr/local/opt/mysql",
        };
        for (prefixes) |prefix| {
            if (dirExists(b, prefix)) {
                // Prefer mariadb include layout when present.
                const maria_inc = b.fmt("{s}/include/mariadb", .{prefix});
                if (dirExists(b, maria_inc)) {
                    return .{ .include = maria_inc, .lib = b.fmt("{s}/lib", .{prefix}) };
                }
                const mysql_inc = b.fmt("{s}/include/mysql", .{prefix});
                if (dirExists(b, mysql_inc)) {
                    return .{ .include = mysql_inc, .lib = b.fmt("{s}/lib", .{prefix}) };
                }
                return .{
                    .include = b.fmt("{s}/include", .{prefix}),
                    .lib = b.fmt("{s}/lib", .{prefix}),
                };
            }
        }
    } else if (host_target.os.tag == .linux) {
        const lib_dir = if (host_target.cpu.arch == .aarch64) "/usr/lib/aarch64-linux-gnu" else "/usr/lib/x86_64-linux-gnu";
        const candidates = &[_][]const u8{
            "/usr/include/mariadb",
            "/usr/include/mysql",
            "/usr/local/include/mariadb",
        };
        for (candidates) |c| {
            if (dirExists(b, c)) {
                return .{ .include = c, .lib = lib_dir };
            }
        }
    }
    return .{};
}

/// Link only the drivers enabled in `features`.
pub fn link(mod: *std.Build.Module, b: *std.Build, features: Features) void {
    if (features.postgres) {
        const pq = detectPqPaths(b);
        if (pq.include) |inc| {
            mod.addSystemIncludePath(.{ .cwd_relative = inc });
        }
        if (pq.lib) |lib| {
            mod.addLibraryPath(.{ .cwd_relative = lib });
        }
        mod.linkSystemLibrary("pq", .{});
    }

    if (features.mysql) {
        const mysql = detectMysqlPaths(b);
        if (mysql.include) |inc| {
            mod.addSystemIncludePath(.{ .cwd_relative = inc });
        }
        if (mysql.lib) |lib| {
            mod.addLibraryPath(.{ .cwd_relative = lib });
        }
        mod.linkSystemLibrary("mysqlclient", .{});
    }

    if (features.sqlite) {
        mod.linkSystemLibrary("sqlite3", .{});
    }
}
