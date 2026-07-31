const std = @import("std");
const db_link = @import("db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zent demos use SQLite only — do not pull libpq/mysqlclient.
    const features = db_link.Features.sqlite_only;
    const build_options = b.addOptions();
    db_link.addToOptions(build_options, features);
    const build_options_mod = build_options.createModule();

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
    zigmodu_mod.addImport("build_options", build_options_mod);
    db_link.link(zigmodu_mod, b, features);

    const helper_mod = b.createModule(.{
        .root_source_file = b.path("../_shared/zent_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    helper_mod.addImport("zent", zent_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_mod);
    exe_mod.addImport("zent", zent_mod);
    exe_mod.addImport("zent_helpers", helper_mod);

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
