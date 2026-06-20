const std = @import("std");

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

fn detectPqPaths(b: *std.Build, allocator: std.mem.Allocator) CLibPaths {
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
    _ = allocator;
    return .{};
}

fn detectMysqlPaths(b: *std.Build, allocator: std.mem.Allocator) CLibPaths {
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
        };
        for (prefixes) |prefix| {
            if (dirExists(b, prefix)) {
                return .{
                    .include = b.fmt("{s}/include/mariadb", .{prefix}),
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
    _ = allocator;
    return .{};
}

fn linkDbLibs(mod: *std.Build.Module, b: *std.Build) void {
    const allocator = b.allocator;

    const pq = detectPqPaths(b, allocator);
    if (pq.include) |inc| {
        mod.addSystemIncludePath(.{ .cwd_relative = inc });
    }
    if (pq.lib) |lib| {
        mod.addLibraryPath(.{ .cwd_relative = lib });
    }
    mod.linkSystemLibrary("pq", .{});

    const mysql = detectMysqlPaths(b, allocator);
    if (mysql.include) |inc| {
        mod.addSystemIncludePath(.{ .cwd_relative = inc });
    }
    if (mysql.lib) |lib| {
        mod.addLibraryPath(.{ .cwd_relative = lib });
    }
    mod.linkSystemLibrary("mysqlclient", .{});

    mod.linkSystemLibrary("sqlite3", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigmodu_mod = b.addModule("zigmodu", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkDbLibs(zigmodu_mod, b);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_mod);

    const exe = b.addExecutable(.{
        .name = "tenant-mgmt",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run tenant-mgmt API server");
    run_step.dependOn(&run_cmd.step);
}
