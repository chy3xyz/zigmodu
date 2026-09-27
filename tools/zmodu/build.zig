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

    // The architecture analyser lives in the framework, and the CLI must run it on
    // *scanned source* (the CLI cannot import framework types). Sharing the module
    // keeps one implementation of the cycle/finding logic instead of a CLI copy
    // that drifts — `zmodu doctor` and `ApplicationBuilder.build` then agree.
    const graph_mod = b.createModule(.{
        .root_source_file = b.path("../../src/core/ModuleGraph.zig"),
        .target = target,
        .optimize = optimize,
    });
    zmodu_mod.addImport("module_graph", graph_mod);

    // Test-collection gate (src/test/TestCollection.zig) — one implementation,
    // shared with the framework's build.zig, so `cd tools/zmodu && zig build
    // test` checks the same tree the root build compiles.
    const test_collection_mod = b.createModule(.{
        .root_source_file = b.path("../../src/test/TestCollection.zig"),
        .target = target,
        .optimize = optimize,
    });
    zmodu_mod.addImport("test_collection", test_collection_mod);

    const exe = b.addExecutable(.{
        .name = "zmodu",
        .root_module = zmodu_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zmodu CLI");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` replays a cached run when nothing the *compiler* read has
    // changed. The test-collection gate reads files the compiler never saw (a new
    // source file that nothing imports changes no artifact at all), so a cached
    // replay would report success without running it — `-Dtest-force-run=true`
    // re-executes the binaries, and `scripts/check-test-collection.sh` passes it.
    // Same option name as the root build.zig, which CI's test step uses.
    const test_force_run = b.option(bool, "test-force-run", "Re-execute test binaries even when Zig has a cached run result for them") orelse false;

    const attachTest = struct {
        fn add(b_: *std.Build, step: *std.Build.Step, artifact: *std.Build.Step.Compile, force_run: bool) void {
            const run = b_.addRunArtifact(artifact);
            if (force_run) run.has_side_effects = true;
            step.dependOn(&run.step);
        }
    }.add;

    const test_step = b.step("test", "Run zmodu CLI tests");
    const zmodu_tests = b.addTest(.{ .root_module = zmodu_mod });
    attachTest(b, test_step, zmodu_tests, test_force_run);

    // Dead-code analyzer unit tests (mirrors root build.zig wiring).
    const dc_analyze_mod = b.createModule(.{
        .root_source_file = b.path("src/deadcode/analyze.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_analyze_tests = b.addTest(.{ .root_module = dc_analyze_mod });
    attachTest(b, test_step, dc_analyze_tests, test_force_run);

    const dc_scanner_mod = b.createModule(.{
        .root_source_file = b.path("src/deadcode/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_scanner_tests = b.addTest(.{ .root_module = dc_scanner_mod });
    attachTest(b, test_step, dc_scanner_tests, test_force_run);
}
