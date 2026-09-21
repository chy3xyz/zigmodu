const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zigmodu_dep = b.dependency("zigmodu", .{
        .target = target,
        .optimize = optimize,
        // The probe speaks HTTP and nothing else; no driver code is reachable
        // from it, so nothing driver-shaped is linked.
        .db = "none",
    });
    exe_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    const exe = b.addExecutable(.{
        .name = "smuggling-probe",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
}
