const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zent_dep = b.dependency("zent", .{ .target = target, .optimize = optimize });
    const zent_mod = zent_dep.module("zent");

    const helper_mod = b.createModule(.{
        .root_source_file = b.path("zent_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    helper_mod.addImport("zent", zent_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("zent_helpers_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zent", zent_mod);
    test_mod.addImport("zent_helpers", helper_mod);
    test_mod.linkSystemLibrary("sqlite3", .{});

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run shared zent helper tests");
    test_step.dependOn(&run_tests.step);
}
