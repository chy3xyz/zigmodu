const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zmodu_dep = b.dependency("zmodu", .{
        .target = target,
        .optimize = optimize,
        .db = "sqlite",
    });
    exe_mod.addImport("zmodu", zmodu_dep.module("zmodu"));

    const exe = b.addExecutable(.{
        .name = "web4",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the web4 example");
    run_step.dependOn(&run_cmd.step);

    const test_cmd = b.addTest(.{ .root_module = exe_mod });
    const test_step = b.step("test", "Run the web4 example tests");
    test_step.dependOn(&b.addRunArtifact(test_cmd).step);
}
