const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add ZigModu dependency from parent directory
    const zigmodu_module = b.createModule(.{
        .root_source_file = b.path("../../src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create a module for the modules directory
    const modules_module = b.createModule(.{
        .root_source_file = b.path("modules/modules.zig"),
        .target = target,
        .optimize = optimize,
    });
    modules_module.addImport("zigmodu", zigmodu_module);

    // Create executable
    const exe = b.addExecutable(.{
        .name = "bookstore-service",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add modules as import
    exe.root_module.addImport("modules", modules_module);
    exe.root_module.addImport("zigmodu", zigmodu_module);

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the bookstore service");
    run_step.dependOn(&run_cmd.step);

    // Test command
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.root_module.addImport("modules", modules_module);
    exe_unit_tests.root_module.addImport("zigmodu", zigmodu_module);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
