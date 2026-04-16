const std = @import("std");

const CLibPaths = struct {
    include: ?[]const u8 = null,
    lib: ?[]const u8 = null,
};

fn detectPqPaths(b: *std.Build, allocator: std.mem.Allocator) CLibPaths {
    if (b.graph.env_map.get("PQ_INCLUDE")) |inc| {
        return .{ .include = b.dupe(inc), .lib = b.graph.env_map.get("PQ_LIB") };
    }
    const host_target = b.graph.host.result;
    if (host_target.os.tag == .macos) {
        if (dirExists("/opt/homebrew/opt/libpq")) {
            return .{
                .include = "/opt/homebrew/opt/libpq/include",
                .lib = "/opt/homebrew/opt/libpq/lib",
            };
        }
        if (dirExists("/usr/local/opt/libpq")) {
            return .{
                .include = "/usr/local/opt/libpq/include",
                .lib = "/usr/local/opt/libpq/lib",
            };
        }
    } else if (host_target.os.tag == .linux) {
        const candidates = &[_][]const u8{
            "/usr/include/postgresql",
            "/usr/include/pgsql",
            "/usr/pgsql/include",
        };
        for (candidates) |c| {
            if (dirExists(c)) {
                return .{
                    .include = c,
                    .lib = "/usr/lib/x86_64-linux-gnu",
                };
            }
        }
    }
    _ = allocator;
    return .{};
}

fn detectMysqlPaths(b: *std.Build, allocator: std.mem.Allocator) CLibPaths {
    if (b.graph.env_map.get("MYSQL_INCLUDE")) |inc| {
        return .{ .include = b.dupe(inc), .lib = b.graph.env_map.get("MYSQL_LIB") };
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
            if (dirExists(prefix)) {
                return .{
                    .include = b.fmt("{s}/include/mariadb", .{prefix}),
                    .lib = b.fmt("{s}/lib", .{prefix}),
                };
            }
        }
    } else if (host_target.os.tag == .linux) {
        const candidates = &[_][]const u8{
            "/usr/include/mariadb",
            "/usr/include/mysql",
            "/usr/local/include/mariadb",
        };
        for (candidates) |c| {
            if (dirExists(c)) {
                return .{
                    .include = c,
                    .lib = "/usr/lib/x86_64-linux-gnu",
                };
            }
        }
    }
    _ = allocator;
    return .{};
}

fn dirExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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

    // Create and export the zigmodu module for dependent packages
    const zigmodu_mod = b.addModule("zigmodu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zio dependency to zigmodu module
    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    zigmodu_mod.addImport("zio", zio_dep.module("zio"));
    linkDbLibs(zigmodu_mod, b);

    // Create example executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/basic/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_mod);

    const exe = b.addExecutable(.{
        .name = "zigmodu-example",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test step - test the main library
    const test_step = b.step("test", "Run all tests");

    const lib_test = b.addTest(.{
        .root_module = zigmodu_mod,
    });
    const run_lib_test = b.addRunArtifact(lib_test);
    test_step.dependOn(&run_lib_test.step);

    // Benchmark step
    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_mod.addImport("zigmodu", zigmodu_mod);

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_mod,
    });
    const benchmark_run = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step("benchmark", "Run benchmarks");
    benchmark_step.dependOn(&benchmark_run.step);

    // Docs step
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("src/docs.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs_mod.addImport("zigmodu", zigmodu_mod);

    const docs_exe = b.addExecutable(.{
        .name = "docs",
        .root_module = docs_mod,
    });
    const docs_run = b.addRunArtifact(docs_exe);
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs_run.step);

    // ZigCtl step
    const zigctl_mod = b.createModule(.{
        .root_source_file = b.path("tools/zigctl/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zigctl_exe = b.addExecutable(.{
        .name = "zigctl",
        .root_module = zigctl_mod,
    });
    const zigctl_run = b.addRunArtifact(zigctl_exe);
    if (b.args) |args| {
        zigctl_run.addArgs(args);
    }
    const zigctl_step = b.step("zigctl", "Run zigctl code generator");
    zigctl_step.dependOn(&zigctl_run.step);
}
