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

    // Add zigmodu dependency
    const zigmodu_dep = b.dependency("zigmodu", .{
        .target = target,
        .optimize = optimize,
        .db = "sqlite",
    });
    exe_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    const exe = b.addExecutable(.{
        .name = "basic-example",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the basic example");
    run_step.dependOn(&run_cmd.step);

    // Testing example (ModuleTestContext / mock modules / lifecycle) lives in
    // src/tests.zig and ships its own test step.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    const test_step = b.step("test", "Run the example tests");
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
