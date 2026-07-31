const std = @import("std");
const db_link = @import("db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_opt = b.option([]const u8, "db", "SQL drivers to link: all|sqlite|postgres|mysql (comma-list)") orelse "all";
    const features = db_link.parseDb(db_opt) catch {
        @panic("invalid -Ddb= value; use all|sqlite|postgres|mysql (comma-list ok)");
    };

    const build_options = b.addOptions();
    db_link.addToOptions(build_options, features);
    const build_options_mod = build_options.createModule();

    const zigmodu_mod = b.addModule("zigmodu", .{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigmodu_mod.addImport("build_options", build_options_mod);
    db_link.link(zigmodu_mod, b, features);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigmodu", zigmodu_mod);

    const exe = b.addExecutable(.{
        .name = "shopdemo",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run shopdemo API server");
    run_step.dependOn(&run_cmd.step);
}
