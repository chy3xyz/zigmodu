const std = @import("std");
const db_link = @import("examples/_shared/db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const db_opt = b.option([]const u8, "db", "SQL drivers to link: all|sqlite|postgres|mysql|none (comma-list)") orelse "all";
    // Framework `zig build test` expects `-Ddb=all` (default). Narrow `-Ddb=` skips linking
    // but many unit tests still open SQLite `:memory:` and will fail without sqlite enabled.
    const features = db_link.parseDb(db_opt) catch {
        @panic("invalid -Ddb= value; use all|sqlite|postgres|mysql|none (comma-list ok)");
    };

    // Build options for compile-time configuration
    const package_zon = @import("build.zig.zon");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "log_level", b.option([]const u8, "log-level", "Compile-time log level (debug/info/warn/err)") orelse "debug");
    build_options.addOption(std.SemanticVersion, "version", std.SemanticVersion.parse(package_zon.version) catch unreachable);
    // `-Dnet-tests=false` makes every socket-dependent test skip (sandboxed CI
    // without loopback permission). They run by default.
    build_options.addOption(bool, "net_tests", b.option(bool, "net-tests", "Run tests that need real loopback sockets") orelse true);
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

    // Focused runs: `-Dtest-filter=SUBSTR` runs only tests whose fully qualified
    // name contains SUBSTR.
    //
    // This deliberately does *not* use Zig's `--test-filter` (`Compile.filters`).
    // That one is applied at compile time, and an excluded test is not analyzed
    // at all — so its `@import`s never run and the imported files' tests are never
    // even seen. Filtering is transitive only through *matching* test bodies, and
    // this repo's suite hangs off one aggregate test (`src/tests.zig` →
    // `test "compile all source files"` → …). Measured on 0.17.0-dev.2151:
    // `-Dtest-filter=RaftElection` produced a binary containing exactly one test
    // (`root.test_0`, an unnamed block no filter can match) and exited 0, while
    // `-Dtest-filter=.` — which matches everything — ran the full 1416. Silent,
    // and useless for the thing this option is for.
    //
    // So the filter is applied at *runtime* by `scripts/test-runner.zig`: the
    // whole suite is compiled, the runner sees every test name, and only matches
    // execute. The runner reports `selected N of M tests` per test binary, and
    // `scripts/test-fast.sh` sums those lines: zero in total is a hard failure
    // there (exit 2) instead of a green run that verified nothing. The runner
    // deliberately does *not* fail a single binary that matched nothing — a
    // filter normally matches in only one of the five test binaries.
    //
    // Caching: Zig caches test *runs*, and a cached run neither re-executes nor
    // re-prints results. A filtered run therefore sets `has_side_effects`;
    // `-Dtest-force-run=true` does the same for unfiltered runs. The default
    // (`zig build test`, no options) keeps its cache behaviour untouched.
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose fully qualified name contains this substring (runtime filter via scripts/test-runner.zig; see scripts/test-fast.sh)");
    const test_force_run = b.option(bool, "test-force-run", "Re-execute test binaries even when Zig has a cached run result for them") orelse false;

    // Attach a test artifact to the `test` step. Kept as one helper so the
    // filter, the runner and the side-effect flag cannot drift apart.
    const addTest = struct {
        fn add(
            b_: *std.Build,
            step: *std.Build.Step,
            artifact: *std.Build.Step.Compile,
            filter: ?[]const u8,
            force_run: bool,
        ) void {
            if (filter != null) {
                artifact.test_runner = .{
                    .path = b_.path("scripts/test-runner.zig"),
                    .mode = .simple,
                };
            }
            const run = b_.addRunArtifact(artifact);
            if (filter) |f| run.addArg(b_.fmt("--filter={s}", .{f}));
            if (filter != null or force_run) run.has_side_effects = true;
            step.dependOn(&run.step);
        }
    }.add;

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
    addTest(b, test_step, lib_tests, test_filter, test_force_run);

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
    addTest(b, test_step, log_level_tests, test_filter, test_force_run);

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

    // Build the benchmark binary without running it: the run step writes
    // `bench-results.json` into the *cwd*, which for `zig build benchmark` is the
    // repository root. `scripts/check-bench.sh` installs the binary into a
    // temporary prefix (`--prefix`) and executes it there instead, so the gate
    // never drops a file into the working tree.
    const benchmark_install = b.addInstallArtifact(benchmark_exe, .{});
    const benchmark_build_step = b.step("benchmark-build", "Build the benchmark binary without running it");
    benchmark_build_step.dependOn(&benchmark_install.step);

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
        // Zig 0.17-dev.813: @cImport no longer implicitly links libc. The
        // CLI exercises sqlite/process paths, so it needs the same explicit
        // link as the framework module.
        .link_libc = true,
    });
    zmodu_cli_mod.addImport("build_options", build_options_mod);
    const cli_graph_mod = b.createModule(.{
        .root_source_file = b.path("src/core/ModuleGraph.zig"),
        .target = target,
        .optimize = optimize,
    });
    zmodu_cli_mod.addImport("module_graph", cli_graph_mod);
    const zmodu_cli_exe = b.addExecutable(.{
        .name = "zmodu",
        .root_module = zmodu_cli_mod,
    });
    // Keep the handle: `zig build zmodu` must *install* the binary it just ran,
    // otherwise `zig-out/bin/zmodu` silently stays at whatever an earlier
    // `zig build` left there and callers drive a stale CLI.
    const zmodu_install = b.addInstallArtifact(zmodu_cli_exe, .{});
    b.getInstallStep().dependOn(&zmodu_install.step);

    const run_zmodu_cmd = b.addRunArtifact(zmodu_cli_exe);
    const zmodu_step = b.step("zmodu", "Build and install the unified zmodu CLI code generator");
    zmodu_step.dependOn(&run_zmodu_cmd.step);
    zmodu_step.dependOn(&zmodu_install.step);

    // Include zmodu CLI test suite in `zig build test`
    const zmodu_tests = b.addTest(.{
        .root_module = zmodu_cli_mod,
    });
    addTest(b, test_step, zmodu_tests, test_filter, test_force_run);

    // Dead-code analyzer unit tests live in the deadcode/ submodule; include
    // them explicitly so `zig build test` covers the analyzer itself.
    const dc_analyze_mod = b.createModule(.{
        .root_source_file = b.path("tools/zmodu/src/deadcode/analyze.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_analyze_tests = b.addTest(.{ .root_module = dc_analyze_mod });
    addTest(b, test_step, dc_analyze_tests, test_filter, test_force_run);
    const dc_scanner_mod = b.createModule(.{
        .root_source_file = b.path("tools/zmodu/src/deadcode/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_scanner_tests = b.addTest(.{ .root_module = dc_scanner_mod });
    addTest(b, test_step, dc_scanner_tests, test_filter, test_force_run);

    // Concurrency soak (`zig build soak`) — real sockets, N clients x M
    // tenants, cross-tenant leak assertions. Kept out of `zig build test` so
    // the default suite stays fast; sized via options.
    const soak_options = b.addOptions();
    soak_options.addOption(usize, "soak_clients", b.option(usize, "soak-clients", "soak: concurrent client threads") orelse 16);
    soak_options.addOption(usize, "soak_iterations", b.option(usize, "soak-iterations", "soak: requests per client") orelse 50);
    const soak_options_mod = soak_options.createModule();

    const soak_mod = b.createModule(.{
        .root_source_file = b.path("src/soak.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    soak_mod.addImport("zigmodu", zigmodu_mod);
    soak_mod.addImport("build_options", soak_options_mod);
    db_link.link(soak_mod, b, features);

    const soak_tests = b.addTest(.{ .root_module = soak_mod });
    const run_soak = b.addRunArtifact(soak_tests);
    const soak_step = b.step("soak", "Run concurrency soak tests (N clients x M tenants)");
    soak_step.dependOn(&run_soak.step);
}
