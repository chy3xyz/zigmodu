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

    // `--fuzz` needs the coverage sections `fuzzer_init` reads through the
    // linker-provided `__start___sancov_{cntrs,pcs1}` / `__stop_…` symbols. On
    // x86_64 the default backend emits none of that data: measured with this
    // toolchain (0.17.0-dev.2151+2ec5523d5) on a one-function object and on a
    // linked test binary —
    //   build-obj -ffuzz -target x86_64-linux         → no `__sancov*` section at all
    //   build-obj -ffuzz -target x86_64-linux -fllvm  → `__sancov_cntrs` + `__sancov_pcs1`
    // the linked binary keeps the same split, and without `-fllvm` its
    // `__start___sancov_cntrs` is an *undefined* weak symbol. The fuzz phase then
    // has no PCs to work with, and the build runner rejects the resulting
    // coverage file (`corrupted coverage file …: pcs_len was zero`) — which is
    // exactly what made the nightly `Fuzz (bounded)` step red on the x86_64
    // ubuntu runner from the day it was added. So test artifacts go through LLVM
    // on x86_64-linux; every other target keeps the default backend, and
    // `-Dtest-llvm=` overrides either way. A *new* test root that contains
    // `std.testing.fuzz` must be attached through `addTest` below, or `--fuzz`
    // loses coverage for it again.
    const test_llvm = b.option(bool, "test-llvm", "Force the LLVM backend for the `test` step's artifacts (default: true on x86_64-linux, where the default backend emits no `--fuzz` coverage sections)") orelse
        (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux);

    // Attach a test artifact to the `test` step. Kept as one helper so the
    // filter, the runner, the backend choice and the side-effect flag cannot
    // drift apart.
    const addTest = struct {
        fn add(
            b_: *std.Build,
            step: *std.Build.Step,
            artifact: *std.Build.Step.Compile,
            filter: ?[]const u8,
            force_run: bool,
            use_llvm: bool,
        ) void {
            if (filter != null) {
                artifact.test_runner = .{
                    .path = b_.path("scripts/test-runner.zig"),
                    .mode = .simple,
                };
            }
            if (use_llvm) artifact.use_llvm = true;
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
    addTest(b, test_step, lib_tests, test_filter, test_force_run, test_llvm);

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
    addTest(b, test_step, log_level_tests, test_filter, test_force_run, test_llvm);

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

    // Fail if examples reintroduce deprecated http_server imports.
    //
    // The gate has to *run* everywhere. It used to `if rg -q …` with `2>/dev/null`,
    // so a host without ripgrep exited 127 into the false branch and reported
    // success without searching anything — the macOS runner is such a host. Adding
    // a `command -v rg || exit 1` guard fixed the silence but turned that host red;
    // both are wrong. So: prefer `rg`, fall back to `grep -R`, and only fail when
    // neither exists.
    const check_api_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\pattern='zigmodu\.http_server'
        \\if command -v rg >/dev/null 2>&1; then
        \\  hits=$(rg -n "$pattern" examples/ || true)
        \\elif command -v grep >/dev/null 2>&1; then
        \\  hits=$(grep -Rn --include='*.zig' "$pattern" examples/ || true)
        \\else
        \\  echo "error: check-api needs ripgrep or grep on PATH" >&2
        \\  exit 1
        \\fi
        \\if [ -n "$hits" ]; then
        \\  echo "error: examples/ must use zigmodu.http, not zigmodu.http_server" >&2
        \\  printf '%s\n' "$hits" >&2
        \\  exit 1
        \\fi
    });
    const check_api_step = b.step("check-api", "Ensure examples use canonical domain imports");
    check_api_step.dependOn(&check_api_cmd.step);

    // Formatting gate, expressed in the build graph instead of as a bare shell
    // command in CI so there is one entry point (`zig build fmt-check`) and the
    // path list cannot drift between jobs. `paths` are handed to `zig fmt`
    // verbatim and directories recurse, so this checks exactly what the inline
    // `zig fmt --check src tools examples` did — including the vendored
    // `examples/*/zig-pkg` snapshots (verified clean before landing). A
    // non-conforming file makes the step fail (exit 1), not skip.
    const fmt_check = b.addFmt(.{
        .paths = &.{ b.path("src"), b.path("tools"), b.path("examples") },
        .check = true,
    });
    const fmt_check_step = b.step("fmt-check", "Check formatting (zig fmt --check src tools examples)");
    fmt_check_step.dependOn(&fmt_check.step);

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
    addTest(b, test_step, zmodu_tests, test_filter, test_force_run, test_llvm);

    // Dead-code analyzer unit tests live in the deadcode/ submodule; include
    // them explicitly so `zig build test` covers the analyzer itself.
    const dc_analyze_mod = b.createModule(.{
        .root_source_file = b.path("tools/zmodu/src/deadcode/analyze.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_analyze_tests = b.addTest(.{ .root_module = dc_analyze_mod });
    addTest(b, test_step, dc_analyze_tests, test_filter, test_force_run, test_llvm);
    const dc_scanner_mod = b.createModule(.{
        .root_source_file = b.path("tools/zmodu/src/deadcode/scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dc_scanner_tests = b.addTest(.{ .root_module = dc_scanner_mod });
    addTest(b, test_step, dc_scanner_tests, test_filter, test_force_run, test_llvm);

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

    // Cluster soak (`zig build soak-cluster`) — in-process 3-node cluster with
    // real raft election/heartbeat/replication over loopback plus
    // DistributedEventBus publish traffic; asserts message continuity, leader
    // stability, log convergence and fd/RSS/thread non-growth while both run.
    // Sibling of `soak` (HTTP + tenants) and `runtime-stress` (runtime), sized
    // so the default finishes in ~1–2 minutes.
    const soak_cluster_options = b.addOptions();
    soak_cluster_options.addOption(usize, "soak_iterations", b.option(usize, "soak-cluster-iterations", "soak-cluster: published messages per writer (2 writers per node)") orelse 2400);
    soak_cluster_options.addOption(usize, "soak_cluster_publish_ms", b.option(usize, "soak-cluster-publish-ms", "soak-cluster: ms between a node's publishes") orelse 25);
    soak_cluster_options.addOption(usize, "soak_cluster_append_ms", b.option(usize, "soak-cluster-append-ms", "soak-cluster: ms between leader log appends") orelse 100);
    soak_cluster_options.addOption(usize, "soak_cluster_sample_ms", b.option(usize, "soak-cluster-sample-ms", "soak-cluster: sample interval for the invariants") orelse 500);
    soak_cluster_options.addOption(usize, "soak_cluster_tick_ms", b.option(usize, "soak-cluster-tick-ms", "soak-cluster: ms between cluster.tick() calls") orelse 25);
    soak_cluster_options.addOption(usize, "soak_cluster_quiesce_ms", b.option(usize, "soak-cluster-quiesce-ms", "soak-cluster: replication settle time before the log snapshot") orelse 600);
    const soak_cluster_options_mod = soak_cluster_options.createModule();

    const soak_cluster_mod = b.createModule(.{
        .root_source_file = b.path("src/soak_cluster.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    soak_cluster_mod.addImport("zigmodu", zigmodu_mod);
    soak_cluster_mod.addImport("build_options", soak_cluster_options_mod);
    db_link.link(soak_cluster_mod, b, features);

    const soak_cluster_tests = b.addTest(.{ .root_module = soak_cluster_mod });
    // The default test runner speaks the build runner's stdin protocol and
    // panics (EndOfStream) when stdin is a closed pipe — exactly what CI gives
    // it. The repo's simple runner reports without the protocol.
    soak_cluster_tests.test_runner = .{
        .path = b.path("scripts/test-runner.zig"),
        .mode = .simple,
    };
    const run_soak_cluster = b.addRunArtifact(soak_cluster_tests);
    // A soak must actually run on every invocation; a cached "run test"
    // result would print nothing and verify nothing.
    run_soak_cluster.has_side_effects = true;
    const soak_cluster_step = b.step("soak-cluster", "Run the 3-node cluster soak (raft + event bus, leader/fd/RSS invariants)");
    soak_cluster_step.dependOn(&run_soak_cluster.step);

    // Long-horizon runtime harness (`zig build runtime-stress`). Sibling of
    // `soak`, and deliberately not a second one of it: `soak` is HTTP + tenant
    // isolation and never touches the runtime, while this one drives the
    // supervision tree, both schedulers, the ready ring and the timer wheel
    // under *sustained* load and checks the invariants periodically. Sizing is
    // by option so the default stays inside ~10 s.
    const stress_options = b.addOptions();
    stress_options.addOption(usize, "runtime_stress_duration_ms", b.option(usize, "runtime-stress-duration-ms", "runtime-stress: sustained-load duration in milliseconds") orelse 5000);
    stress_options.addOption(usize, "runtime_stress_sample_ms", b.option(usize, "runtime-stress-sample-ms", "runtime-stress: time-series sample interval in milliseconds") orelse 100);
    stress_options.addOption(usize, "runtime_stress_workers", b.option(usize, "runtime-stress-workers", "runtime-stress: pooled `.cpu` workers to spawn") orelse 4);
    stress_options.addOption(usize, "runtime_stress_producers", b.option(usize, "runtime-stress-producers", "runtime-stress: producer threads feeding the cpu pool") orelse 2);
    stress_options.addOption(usize, "runtime_stress_blocking_workers", b.option(usize, "runtime-stress-blocking-workers", "runtime-stress: pooled `.blocking` workers to spawn") orelse 2);
    stress_options.addOption(usize, "runtime_stress_restarts", b.option(usize, "runtime-stress-restarts", "runtime-stress: restart budget of the group holding the always-failing member") orelse 3);
    stress_options.addOption(usize, "runtime_stress_pool_threads", b.option(usize, "runtime-stress-pool-threads", "runtime-stress: cpu pool width") orelse 2);
    stress_options.addOption(usize, "runtime_stress_blocking_threads", b.option(usize, "runtime-stress-blocking-threads", "runtime-stress: blocking pool width") orelse 1);
    stress_options.addOption(usize, "runtime_stress_rss_budget_mib", b.option(usize, "runtime-stress-rss-budget-mib", "runtime-stress: RSS spread budget (MiB) for the steady phase") orelse 24);
    stress_options.addOption(usize, "runtime_stress_timers", b.option(usize, "runtime-stress-timers", "runtime-stress: timers armed in the opening burst") orelse 48);
    stress_options.addOption(usize, "runtime_stress_min_windows", b.option(usize, "runtime-stress-min-windows", "runtime-stress: windows that must cover all four paths") orelse 3);
    const stress_options_mod = stress_options.createModule();

    const stress_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_stress.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stress_mod.addImport("zigmodu", zigmodu_mod);
    stress_mod.addImport("build_options", stress_options_mod);
    db_link.link(stress_mod, b, features);

    const stress_exe = b.addExecutable(.{
        .name = "runtime-stress",
        .root_module = stress_mod,
    });
    const run_stress = b.addRunArtifact(stress_exe);
    const stress_step = b.step("runtime-stress", "Run the long-horizon runtime harness (supervision tree, pools, timers, zero-allocation)");
    stress_step.dependOn(&run_stress.step);

    // Compile-only gate for the three targets whose steps only *run* on the
    // nightly `schedule` (or a manual `workflow_dispatch`): `soak`,
    // `soak-cluster` and `runtime-stress`. On a push run nothing compiled them —
    // `zig build test` builds its own root module, and these are three separate
    // ones — so a compile error in any of them was invisible until 03:17 UTC,
    // and stayed invisible on every day the nightly was cancelled. That is not
    // hypothetical: `src/soak_cluster.zig` failed to build for days on Linux
    // (`no field named 'd_name' in struct 'os.linux.dirent64'`, fixed in the
    // batch-12 commit) and the only reason anyone saw it was one nightly going
    // red. This step depends on the three *compile* steps and runs none of them,
    // so the push gate pays seconds instead of the minutes a real soak costs.
    // `fuzz` needs no entry here: its step is `zig build test --fuzz=…`, i.e. the
    // root module push runs already compile.
    const soak_compile_step = b.step("soak-compile", "Compile the nightly-only targets (soak, soak-cluster, runtime-stress) without running them");
    soak_compile_step.dependOn(&soak_tests.step);
    soak_compile_step.dependOn(&soak_cluster_tests.step);
    soak_compile_step.dependOn(&stress_exe.step);

    // The same file, compiled into `zig build test` with a *smoke* budget, so
    // the default suite covers the harness's code path and every check while the
    // long run stays its own step (the split `soak` uses). The numbers are fixed
    // here rather than derived from the options above: `-Druntime-stress-
    // duration-ms=20000` must not quietly add 20 s to every `zig build test`.
    const stress_smoke_options = b.addOptions();
    stress_smoke_options.addOption(usize, "runtime_stress_duration_ms", 2000);
    stress_smoke_options.addOption(usize, "runtime_stress_sample_ms", 100);
    stress_smoke_options.addOption(usize, "runtime_stress_workers", 2);
    stress_smoke_options.addOption(usize, "runtime_stress_producers", 1);
    stress_smoke_options.addOption(usize, "runtime_stress_blocking_workers", 1);
    stress_smoke_options.addOption(usize, "runtime_stress_restarts", 3);
    stress_smoke_options.addOption(usize, "runtime_stress_pool_threads", 2);
    stress_smoke_options.addOption(usize, "runtime_stress_blocking_threads", 1);
    stress_smoke_options.addOption(usize, "runtime_stress_rss_budget_mib", 24);
    stress_smoke_options.addOption(usize, "runtime_stress_timers", 48);
    // 1, not the sustained default of 3: how many four-path windows a machine
    // delivers in this fixed 2 s budget is a property of the machine (a 2-core
    // CI runner covered 2 of 6 samples), and a smoke that fails on runner
    // speed teaches nothing. The sustained step keeps the real floor.
    stress_smoke_options.addOption(usize, "runtime_stress_min_windows", 1);
    const stress_smoke_options_mod = stress_smoke_options.createModule();

    const stress_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_stress.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    stress_smoke_mod.addImport("zigmodu", zigmodu_mod);
    stress_smoke_mod.addImport("build_options", stress_smoke_options_mod);
    db_link.link(stress_smoke_mod, b, features);

    const stress_smoke_tests = b.addTest(.{ .root_module = stress_smoke_mod });
    addTest(b, test_step, stress_smoke_tests, test_filter, test_force_run, test_llvm);

    // ── `soak-smoke`: the push-gate slice of the nightly soaks ─────────────
    //
    // What the push gate already covers, checked rather than assumed:
    // `zig build test` compiles `src/runtime_stress.zig` against the smoke
    // option set above and runs its single test, so every check in *that*
    // harness is walked on a push. It never reaches `src/soak.zig` or
    // `src/soak_cluster.zig` — neither file is imported by `src/tests.zig`, and
    // each is its own root module — so the cross-tenant leak assertion
    // (`soak.zig`) and the cluster's leader / fd / RSS / log-convergence
    // invariants (`soak_cluster.zig`) had exactly one home: the nightly
    // `schedule`, which was cancelled outright on 2026-09-25. A cancelled
    // schedule looks the same as a green one, which is why those assertions
    // need a second home that a push pays for.
    //
    // This step is that home, and only that: it runs the two harnesses
    // `zig build test` cannot reach. `runtime-stress` is deliberately *not*
    // re-run here — it is already walked by `zig build test`, and reaching its
    // real 3-window floor needs a sustained run whose window coverage is a
    // property of the machine (`stress_smoke_options` above documents the
    // 2-core CI runner that covered 2 of 6 samples). Adding that floor to a
    // push would import exactly the runner-speed flakiness this step must not
    // have; the sustained budget stays nightly-only.
    //
    // The options are literals on purpose: a gate whose budget a `-D` flag can
    // move is a gate that can be quieted by moving it (`-Dsoak-cluster-
    // iterations=8` would still exit 0), and the nightly's own sizes are far
    // larger anyway. Sizing is measured, not guessed (Apple M-series, Debug,
    // 10 cores): `soak` costs ~3 s, and `soak-cluster` at iterations=120 /
    // sample-ms=50 leaves 28 samples, 26 appends and log_len=26 against the
    // harness's own floors (samples >= 5 before it will judge fd/RSS/threads,
    // post_steady >= 3, appends >= 5, log_len >= 5) in 16 s warm / 20 s cold.
    // ~15 s of that is cluster boot + election + teardown, which a smaller
    // budget does not remove (iterations=40 measured the same ~16 s), so the
    // larger budget buys ~5x the sample floor for no wall clock.
    const soak_smoke_options = b.addOptions();
    soak_smoke_options.addOption(usize, "soak_clients", 8);
    soak_smoke_options.addOption(usize, "soak_iterations", 10);
    const soak_smoke_options_mod = soak_smoke_options.createModule();

    const soak_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/soak.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    soak_smoke_mod.addImport("zigmodu", zigmodu_mod);
    soak_smoke_mod.addImport("build_options", soak_smoke_options_mod);
    db_link.link(soak_smoke_mod, b, features);

    const soak_smoke_tests = b.addTest(.{ .root_module = soak_smoke_mod });
    // Same reason as `soak_cluster_tests` above: the default runner speaks the
    // build runner's stdin protocol and panics on the closed pipe CI hands it.
    soak_smoke_tests.test_runner = .{
        .path = b.path("scripts/test-runner.zig"),
        .mode = .simple,
    };
    const run_soak_smoke = b.addRunArtifact(soak_smoke_tests);
    // A smoke must actually run on every invocation: without this, Zig's cached
    // "run test" result would print nothing, execute nothing, and exit 0 — a
    // green that proves as little as the cancelled nightly it replaces.
    run_soak_smoke.has_side_effects = true;

    const cluster_smoke_options = b.addOptions();
    cluster_smoke_options.addOption(usize, "soak_iterations", 120);
    cluster_smoke_options.addOption(usize, "soak_cluster_publish_ms", 10);
    cluster_smoke_options.addOption(usize, "soak_cluster_append_ms", 50);
    cluster_smoke_options.addOption(usize, "soak_cluster_sample_ms", 50);
    cluster_smoke_options.addOption(usize, "soak_cluster_tick_ms", 25);
    cluster_smoke_options.addOption(usize, "soak_cluster_quiesce_ms", 300);
    const cluster_smoke_options_mod = cluster_smoke_options.createModule();

    const cluster_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/soak_cluster.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cluster_smoke_mod.addImport("zigmodu", zigmodu_mod);
    cluster_smoke_mod.addImport("build_options", cluster_smoke_options_mod);
    db_link.link(cluster_smoke_mod, b, features);

    const cluster_smoke_tests = b.addTest(.{ .root_module = cluster_smoke_mod });
    cluster_smoke_tests.test_runner = .{
        .path = b.path("scripts/test-runner.zig"),
        .mode = .simple,
    };
    const run_cluster_smoke = b.addRunArtifact(cluster_smoke_tests);
    run_cluster_smoke.has_side_effects = true;

    const soak_smoke_step = b.step("soak-smoke", "Run the soak assertions a push never reached (cross-tenant leak + cluster leader/fd/RSS/log invariants) at a fixed small budget");
    soak_smoke_step.dependOn(&run_soak_smoke.step);
    soak_smoke_step.dependOn(&run_cluster_smoke.step);
}
