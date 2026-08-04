//! Standalone build entry for the `zmodu` CLI — lets you build / test the CLI
//! without compiling the whole framework:
//!
//!     cd tools/zmodu && zig build          # build the zmodu binary
//!     cd tools/zmodu && zig build test     # run CLI + deadcode analyzer tests
//!
//! The framework's root build.zig also builds this module as part of
//! `zig build test`; the two entries share `src/` and the version is kept in
//! sync via scripts/release.sh.

const std = @import("std");
const package = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(package.version) catch unreachable);
    const build_options_mod = build_options.createModule();

    const zmodu_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zmodu_mod.addImport("build_options", build_options_mod);

    const exe = b.addExecutable(.{
        .name = "zmodu",
        .root_module = zmodu_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zmodu CLI");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run zmodu CLI tests");
    const zmodu_tests = b.addTest(.{ .root_module = zmodu_mod });
    test_step.dependOn(&b.addRunArtifact(zmodu_tests).step);

    // Dead-code analyzer unit tests (mirrors root build.zig wiring).
    const dc_analyze_mod = b.createModule(.{
        .root_source_file = b.path("src/deadcode/analyze.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_analyze_tests = b.addTest(.{ .root_module = dc_analyze_mod });
    test_step.dependOn(&b.addRunArtifact(dc_analyze_tests).step);

    const dc_scanner_mod = b.createModule(.{
        .root_source_file = b.path("src/deadcode/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_scanner_tests = b.addTest(.{ .root_module = dc_scanner_mod });
    test_step.dependOn(&b.addRunArtifact(dc_scanner_tests).step);
}
