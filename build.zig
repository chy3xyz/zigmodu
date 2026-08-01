const std = @import("std");
const db_link = @import("examples/_shared/db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_opt = b.option([]const u8, "db", "SQL drivers to link: all|sqlite|postgres|mysql (comma-list)") orelse "all";
    // Framework `zig build test` expects `-Ddb=all` (default). Narrow `-Ddb=` skips linking
    // but many unit tests still open SQLite `:memory:` and will fail without sqlite enabled.
    const features = db_link.parseDb(db_opt) catch {
        @panic("invalid -Ddb= value; use all|sqlite|postgres|mysql (comma-list ok)");
    };

    // Build options for compile-time configuration
    const package_zon = @import("build.zig.zon");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "log_level", b.option([]const u8, "log-level", "Compile-time log level (debug/info/warn/err)") orelse "debug");
    build_options.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(package_zon.version) catch unreachable);
    db_link.addToOptions(build_options, features);
    const build_options_mod = build_options.createModule();

    // Create and export the zigmodu module for dependent packages.
    // Zig 0.17-dev.813: @cImport no longer implicitly links libc.
    const zigmodu_mod = b.addModule("zigmodu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zigmodu_mod.addImport("build_options", build_options_mod);

    db_link.link(zigmodu_mod, b, features);

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
    // b.args removed in Zig 0.17-dev
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test step - test the main library
    const test_step = b.step("test", "Run all tests");

    // Proper build-system test (supports build_options and other generated modules)
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_test_mod.addImport("build_options", build_options_mod);
    db_link.link(lib_test_mod, b, features);
    const lib_tests = b.addTest(.{
        .root_module = lib_test_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Test log_level.zig separately (needs build_options module)
    const log_level_test_mod = b.createModule(.{
        .root_source_file = b.path("src/log_level.zig"),
        .target = target,
        .optimize = optimize,
    });
    log_level_test_mod.addImport("build_options", build_options_mod);
    const log_level_tests = b.addTest(.{
        .root_module = log_level_test_mod,
    });
    const run_log_level_tests = b.addRunArtifact(log_level_tests);
    test_step.dependOn(&run_log_level_tests.step);

    // Benchmark step
    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_mod.addImport("zigmodu", zigmodu_mod);

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_mod,
    });
    const benchmark_run = b.addRunArtifact(benchmark_exe);
    const benchmark_step = b.step("benchmark", "Run benchmarks");
    benchmark_step.dependOn(&benchmark_run.step);

    // Docs step
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("src/docs.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs_mod.addImport("zigmodu", zigmodu_mod);

    const docs_exe = b.addExecutable(.{
        .name = "docs",
        .root_module = docs_mod,
    });
    const docs_run = b.addRunArtifact(docs_exe);
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs_run.step);

    // Fail if examples reintroduce deprecated http_server imports
    const check_api_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\if rg -q 'zigmodu\.http_server' examples/ 2>/dev/null; then
        \\  echo "error: examples/ must use zigmodu.http, not zigmodu.http_server" >&2
        \\  rg 'zigmodu\.http_server' examples/
        \\  exit 1
        \\fi
    });
    const check_api_step = b.step("check-api", "Ensure examples use canonical domain imports");
    check_api_step.dependOn(&check_api_cmd.step);

    const check_prod_cmd = b.addSystemCommand(&.{ "bash", "scripts/check-production.sh" });
    const check_step = b.step("check", "Production gates: no bare catch {} in hot paths");
    check_step.dependOn(&check_prod_cmd.step);

    const gen_jwt_mod = b.createModule(.{
        .root_source_file = b.path("scripts/gen-jwt-token.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_jwt_mod.addImport("zigmodu", zigmodu_mod);
    const gen_jwt_exe = b.addExecutable(.{
        .name = "gen-jwt-token",
        .root_module = gen_jwt_mod,
    });
    b.installArtifact(gen_jwt_exe);
    const gen_jwt_step = b.step("gen-jwt-token", "Build JWT token generator for CI probes");
    gen_jwt_step.dependOn(b.getInstallStep());

    const integration_cmd = b.addSystemCommand(&.{ "bash", "scripts/ci-integration.sh" });
    const integration_step = b.step("integration", "Run tenant-mgmt + http-stress-test integration probes");
    integration_step.dependOn(&integration_cmd.step);

    // Unified ZModu CLI Code Generator (built-in tool)
    const zmodu_cli_mod = b.createModule(.{
        .root_source_file = b.path("tools/zmodu/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zmodu_cli_mod.addImport("build_options", build_options_mod);
    const zmodu_cli_exe = b.addExecutable(.{
        .name = "zmodu",
        .root_module = zmodu_cli_mod,
    });
    b.installArtifact(zmodu_cli_exe);

    const run_zmodu_cmd = b.addRunArtifact(zmodu_cli_exe);
    const zmodu_step = b.step("zmodu", "Build unified zmodu CLI code generator");
    zmodu_step.dependOn(&run_zmodu_cmd.step);

    // Include zmodu CLI test suite in `zig build test`
    const zmodu_tests = b.addTest(.{
        .root_module = zmodu_cli_mod,
    });
    const run_zmodu_tests = b.addRunArtifact(zmodu_tests);
    test_step.dependOn(&run_zmodu_tests.step);

    // Dead-code analyzer unit tests live in the deadcode/ submodule; include
    // them explicitly so `zig build test` covers the analyzer itself.
    const dc_analyze_mod = b.createModule(.{
        .root_source_file = b.path("tools/zmodu/src/deadcode/analyze.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_analyze_tests = b.addTest(.{ .root_module = dc_analyze_mod });
    test_step.dependOn(&b.addRunArtifact(dc_analyze_tests).step);
    const dc_scanner_mod = b.createModule(.{
        .root_source_file = b.path("tools/zmodu/src/deadcode/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_scanner_tests = b.addTest(.{ .root_module = dc_scanner_mod });
    test_step.dependOn(&b.addRunArtifact(dc_scanner_tests).step);
}
