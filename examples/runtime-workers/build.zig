const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the basic example executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zmodu dependency
    const zmodu_dep = b.dependency("zmodu", .{
        .target = target,
        .optimize = optimize,
        .db = "sqlite",
    });
    exe_mod.addImport("zmodu", zmodu_dep.module("zmodu"));

    const exe = b.addExecutable(.{
        .name = "runtime-workers",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the runtime workers example");
    run_step.dependOn(&run_cmd.step);
}
