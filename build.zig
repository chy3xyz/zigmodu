const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the zigmodu module
    const zigmodu_mod = b.createModule(.{
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
}
