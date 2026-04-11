const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "metaverse-creative",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add ZigModu dependency
    const zigmodu_dep = b.dependency("zigmodu", .{});
    exe.root_module.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the metaverse creative economy demo");
    run_step.dependOn(&run_cmd.step);
}
