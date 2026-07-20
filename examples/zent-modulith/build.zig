const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zent_dep = b.dependency("zent", .{
        .target = target,
        .optimize = optimize,
    });
    const zent_mod = zent_dep.module("zent");

    const zigmodu_mod = b.addModule("zigmodu", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigmodu_mod.linkSystemLibrary("sqlite3", .{});
    // Optional drivers used by zigmodu sqlx — keep build green even if unused here.
    linkOptionalDb(zigmodu_mod, b);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_mod);
    exe_mod.addImport("zent", zent_mod);

    const exe = b.addExecutable(.{
        .name = "zent-modulith",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zent + ZigModu demo server");
    run_step.dependOn(&run_cmd.step);
}

fn dirExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn linkOptionalDb(mod: *std.Build.Module, b: *std.Build) void {
    if (dirExists(b, "/opt/homebrew/opt/libpq")) {
        mod.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/include" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/lib" });
        mod.linkSystemLibrary("pq", .{});
    }
    if (dirExists(b, "/opt/homebrew/opt/mariadb-connector-c")) {
        mod.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/mariadb-connector-c/include/mariadb" });
        mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/mariadb-connector-c/lib" });
        mod.linkSystemLibrary("mysqlclient", .{});
    }
}
