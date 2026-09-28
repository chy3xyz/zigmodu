//! Runtime test filter for `zig build test -Dtest-filter=SUBSTR`.
//!
//! Why this exists, and why it is not Zig's own `--test-filter`:
//!
//! Zig's `--test-filter` is applied at **compile time**. A test it excludes is
//! not analyzed at all — so any `@import` in that test's body never runs, and the
//! tests of the imported file are never even seen by the compiler. Filtering is
//! therefore only transitive through *matching* test bodies, and a repository
//! whose suite is reachable through one aggregate test (`src/tests.zig` →
//! `test "compile all source files"` → …) can only be narrowed by a filter that
//! matches every link of that chain. Measured on this repo: `-Dtest-filter=RaftElection`
//! compiled a test binary containing exactly one test (`root.test_0`, an unnamed
//! `test { … }` block that no filter can match), while `-Dtest-filter=.` — which
//! matches everything — ran the full 1416. A name filter that selects nothing and
//! a filter that works both exit 0.
//!
//! This runner filters at **runtime** instead: the whole suite is compiled, the
//! runner sees every test name, and only the matching ones execute. Costs are
//! ~0 for compilation once the artifact is cached, and only the selected tests
//! run.
//!
//! It also removes the silent failure mode: the summary line it prints says how
//! many tests were selected (`zm-test-runner: selected N of M tests (filter "…")`),
//! and when N is 0 for every binary `scripts/test-fast.sh` fails the run instead
//! of reporting success. A per-binary failure is deliberately not used: the
//! `test` step has five test binaries and a filter normally matches in only one
//! of them.
//!
//! Skipped tests are named twice on purpose: the per-test line already carries
//! the name (`N/M name...SKIP`), and a `zm-test-runner: skipped N test(s) …`
//! block right before the summary lists those same names one per line. That
//! block is what turns a `skipped=` drift (58 → 59) into a set difference over
//! a few dozen lines instead of a grep through every `N/M name...` line of a
//! ~1450-test run. Its lines share the `zm-test-runner: ` prefix — the count
//! parsers in `scripts/test-fast.sh` key on `selected N of M tests`, so extra
//! lines in that family are ignored for counting and echoed at the end of a run.
//!
//! ## Server mode (`--listen=-`), for unfiltered runs
//!
//! A plain `zig build test` never names a skipped test, and the reason is not
//! this runner: without `-Dtest-filter=` the artifacts keep Zig's own runner,
//! the build runner drives it over the internal protocol (`--listen=-`) and
//! **counts** the results itself — it prints `1912 pass, 59 skip (1971 total)`
//! and a skip is only a `u2` in a result message, so no name is ever written
//! anywhere. Measured on this repo: the unfiltered log carries the counts and
//! zero `…SKIP` lines, so nothing downstream can recover the names.
//!
//! Server mode below closes that gap without moving the counts: this runner
//! speaks the same protocol, so the build runner still counts and prints the
//! same summary — `zm-test-count:` lines and their `source=build-summary` stay
//! byte-identical — while this process prints the skipped names to stderr on its
//! way out. `scripts/test-fast.sh` echoes that block, so the aggregate
//! full-suite output names every skipped test.
//!
//! It is opt-in (`-Dtest-skip-names=true` in build.zig) because fuzz mode needs
//! runner features this file deliberately does not implement: `.start_fuzzing`
//! hits the `else` arm and exits 1 with a message instead of pretending. So
//! `zig build test --fuzz=…` keeps Zig's runner, which is also why the default
//! wiring is untouched.
//!
//! Modeled on the compiler's default runner (`lib/compiler/test_runner.zig`,
//! `mainTerminal`) so per-test allocator/io setup — and therefore leak
//! detection — behaves the same. Only the default (unfiltered) path is
//! unaffected: `Compile.test_runner` is set only when `-Dtest-filter=` is given,
//! so `zig build test` still uses Zig's own runner.
//!
//! Fuzz test blocks (`std.testing.fuzz`) are supported to the extent this
//! runner's `.simple` wiring allows: the suite compiles because this root
//! exports the `fuzz` entry point the compiler-generated code references, and
//! a filtered run replays the declared corpus once per input (plus one empty
//! input), mirroring the default runner's non-fuzz behavior. Actual fuzzing
//! (`zig build --fuzz test`) needs the default runner: run it without
//! `-Dtest-filter`. The `--listen=-` server protocol is likewise not
//! supported (this runner is wired as `mode = .simple`); both unsupported
//! modes start with an explicit panic rather than silently doing nothing.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba_buffer: [8192]u8 = undefined;

// Server-mode (`--listen=-`) stdio. The buffers and the reader/writer pair live
// for the whole process, exactly as in the compiler's own runner: `std.zig.Server`
// holds pointers into them, and every `serve…` call flushes, so nothing here
// needs an explicit teardown.
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stdin_reader: std.Io.File.Reader = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
const runner_io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// `test { … }` blocks have no name, so they have no name for a filter to
/// match. Zig names them `test_0`, `test_1`, … inside their file and the runner
/// sees the file-qualified form (`root.test_0`). Detecting that shape is what
/// lets this runner distinguish "the filter matched nothing" from "the filter
/// matched one of the always-compiled aggregate blocks".
fn isUnnamedTest(fqn: []const u8) bool {
    const last = if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| fqn[dot + 1 ..] else fqn;
    if (!std.mem.startsWith(u8, last, "test_")) return false;
    const digits = last["test_".len..];
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    if (builtin.fuzz) @panic("the zigmodu test runner does not support fuzz mode; drop -Dtest-filter so the default runner is used");

    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
    const args = init.args.toSlice(fba.allocator()) catch
        @panic("unable to parse command line arguments");

    var filter: ?[]const u8 = null;
    var server_mode = false;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.eql(u8, arg, "--listen=-")) {
            server_mode = true;
        }
        // Anything else (e.g. `--cache-dir=`) is accepted and ignored, so the
        // runner keeps working if the build system starts passing more flags.
    }

    if (server_mode) {
        // The build runner counts the results over the protocol; this mode only
        // adds the skipped names to stderr (see the module doc).
        mainServer(init) catch |err| {
            std.debug.print("zm-test-runner: internal failure: {t}\n", .{err});
            std.process.exit(1);
        };
    }

    const test_fn_list = builtin.test_functions;

    var named_matched: usize = 0;
    for (test_fn_list) |test_fn| {
        if (isUnnamedTest(test_fn.name)) continue;
        if (filter) |f| if (std.mem.indexOf(u8, test_fn.name, f) == null) continue;
        named_matched += 1;
    }

    if (filter != null and named_matched == 0) {
        // Not fatal here on purpose: the `test` step has several test binaries
        // (the library suite, log_level, the zmodu CLI, the two dead-code
        // analyzers) and a filter is normally meaningful for only one of them.
        // Failing per binary would reject every legitimate focused run. The
        // aggregate verdict belongs to the caller: `scripts/test-fast.sh` sums
        // these lines and refuses to report success when the total is 0.
        std.debug.print(
            "no test name contains filter \"{s}\" — 0 tests selected in this binary\n",
            .{filter.?},
        );
    }

    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leak_count: usize = 0;
    var unnamed_skipped: usize = 0;

    // Skipped names, collected so the summary can name them (see the module doc).
    // Entries are pointers into `builtin.test_functions`, which lives for the
    // whole process — nothing is copied and nothing is freed per entry. The
    // bookkeeping allocation is the runner's own, so it uses `page_allocator`
    // and never touches the per-test allocator that is leak-checked.
    var skipped_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var skipped_names_oom = false;

    for (test_fn_list, 0..) |test_fn, i| {
        if (isUnnamedTest(test_fn.name)) {
            // `test { _ = @import(…); }` blocks are compile-time aggregates: under
            // a filter they are both unmatchable and pointless to execute, and
            // counting them would hide the "matched nothing" case.
            if (filter != null) {
                unnamed_skipped += 1;
                continue;
            }
        } else if (filter) |f| {
            if (std.mem.indexOf(u8, test_fn.name, f) == null) continue;
        }

        testing.environ = init.environ;
        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() != 0) leak_count += 1;
        }
        testing.log_level = .warn;

        // Print the name **and flush it** before running the test.
        //
        // `std.debug.print` buffers into 64 bytes (std/debug.zig) and Zig's
        // `File.Writer` is not line-buffered, so `N/M name...` sits in the buffer
        // until it fills. A test that hangs never fills it: measured, a step that
        // timed out after 25 minutes produced **no test name anywhere** — not in the
        // step log, not in the artifact, not in `tee`'s capture. The bytes never left
        // the process.
        //
        // Format is byte-identical (`N/M name...OK`); the name merely reaches the log
        // before the test can hang, which is the whole point of the per-test line.
        {
            var name_buf: [512]u8 = undefined;
            const stderr = std.debug.lockStderr(&name_buf);
            defer std.debug.unlockStderr();
            stderr.file_writer.interface.print("{d}/{d} {s}...", .{ i + 1, test_fn_list.len, test_fn.name }) catch {};
            stderr.file_writer.interface.flush() catch {};
        }
        if (test_fn.func()) |_| {
            ok_count += 1;
            std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                // `error.SkipZigTest` is the whole vocabulary of "this test did
                // not run": `std.testing.skip()` returns it and Zig has no other
                // skip signal, so it is also the one-line reason the summary
                // block prints. Collect it while it is in hand; the `…SKIP` line
                // above already names the test, this only regroups the names.
                if (!skipped_names_oom) {
                    skipped_names.append(std.heap.page_allocator, test_fn.name) catch {
                        skipped_names_oom = true;
                    };
                }
                std.debug.print("SKIP\n", .{});
            },
            else => {
                fail_count += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

    printSkippedBlock(skip_count, skipped_names.items, skipped_names_oom);
    skipped_names.deinit(std.heap.page_allocator);

    if (filter) |f| {
        std.debug.print("zm-test-runner: selected {d} of {d} tests (filter \"{s}\")", .{
            named_matched, test_fn_list.len, f,
        });
    } else {
        std.debug.print("zm-test-runner: selected {d} of {d} tests (no filter)", .{
            test_fn_list.len, test_fn_list.len,
        });
    }
    std.debug.print(" — {d} passed; {d} skipped; {d} failed; {d} leaked", .{
        ok_count, skip_count, fail_count, leak_count,
    });
    if (unnamed_skipped != 0) {
        std.debug.print("; {d} unnamed test block(s) not selected", .{unnamed_skipped});
    }
    std.debug.print("\n", .{});

    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leak_count != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

/// The one-line-per-name block that turns a `skipped=` drift into a set
/// difference. Both modes print it through here so the two can never drift
/// apart: server mode prints it just before `exit`, and `scripts/test-fast.sh`
/// keys its echo on the `zm-test-runner: ` prefix alone.
fn printSkippedBlock(skip_count: usize, names: []const []const u8, names_oom: bool) void {
    if (skip_count == 0) return;
    std.debug.print("zm-test-runner: skipped {d} test(s) — each returned error.SkipZigTest:\n", .{skip_count});
    for (names) |name| std.debug.print("zm-test-runner:   {s}\n", .{name});
    if (names_oom) {
        std.debug.print("zm-test-runner:   (list truncated: out of memory while collecting names)\n", .{});
    }
}

/// Drive the suite over the build system's test protocol (`--listen=-`), the one
/// `zig build test` uses when the artifact keeps Zig's own runner. Modeled on the
/// compiler's runner (`lib/compiler/test_runner.zig`, `mainServer`) so the build
/// runner's counting, time limits, restart-after-crash and leak/bookkeeping
/// behavior are unchanged; the only addition is the skipped-name block printed
/// on `.exit` (see the module doc for why the plain path cannot do this).
fn mainServer(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();

    stdin_reader = .initStreaming(.stdin(), runner_io, &stdin_buffer);
    stdout_writer = .initStreaming(.stdout(), runner_io, &stdout_buffer);
    var server: std.zig.Server = .{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);

    // Names are pointers into `builtin.test_functions`, which lives for the whole
    // process; only the index bookkeeping is allocated, out of `page_allocator`,
    // so the leak-checked per-test allocator is never touched.
    var skipped_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var skipped_names_oom = false;
    var skip_count: usize = 0;

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                // The build runner sends this once it has requested every test.
                // Exit 0 unconditionally: *it* owns the verdict (it fails the step
                // from the result messages and from this exit status).
                printSkippedBlock(skip_count, skipped_names.items, skipped_names_oom);
                skipped_names.deinit(std.heap.page_allocator);
                std.process.exit(0);
            },
            .query_test_metadata => {
                var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
                defer if (sa.deinit() != 0) @panic("internal test runner memory leak");
                const gpa = sa.allocator();

                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(gpa);
                try string_bytes.append(gpa, 0); // Reserve 0 for null.

                const test_fn_list = builtin.test_functions;
                const names = try gpa.alloc(u32, test_fn_list.len);
                defer gpa.free(names);
                const expected_panic_msgs = try gpa.alloc(u32, test_fn_list.len);
                defer gpa.free(expected_panic_msgs);

                for (test_fn_list, names, expected_panic_msgs) |test_fn, *name, *expected_panic_msg| {
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.appendSlice(gpa, test_fn.name);
                    try string_bytes.append(gpa, 0);
                    expected_panic_msg.* = 0;
                }

                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },
            .run_test => {
                testing.environ = init.environ;
                testing.allocator_instance = .init(std.heap.page_allocator, .{
                    .canary = 0xc3a701ba,
                    .check_write_after_free = true,
                });
                testing.io_instance = .init(testing.allocator, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                log_err_count = 0;
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[index];

                // Tells the build runner the clock for this test starts now, so a
                // `--test-timeout` is not charged for process startup.
                try server.serveStringMessage(.test_started, &.{});

                const TestResults = std.zig.Server.Message.TestResults;
                const status: TestResults.Status = if (test_fn.func()) |_|
                    .pass
                else |err| switch (err) {
                    error.SkipZigTest => .skip,
                    else => s: {
                        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                        break :s .fail;
                    },
                };
                if (status == .skip) {
                    skip_count += 1;
                    if (!skipped_names_oom) {
                        skipped_names.append(std.heap.page_allocator, test_fn.name) catch {
                            skipped_names_oom = true;
                        };
                    }
                }
                testing.io_instance.deinit();
                const leak_count = testing.allocator_instance.deinit();
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = status,
                        // `--fuzz` drives fuzzing through a separate pass, which
                        // needs the `.start_fuzzing` message below; a normal run
                        // never marks a test as a fuzz target.
                        .fuzz = false,
                        .log_err_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "log_err_count"),
                            log_err_count,
                        ),
                        .leak_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "leak_count"),
                            leak_count,
                        ),
                    },
                });
            },
            else => {
                // `.start_fuzzing` lands here (and any protocol message this
                // runner does not implement). Failing loudly beats a run that
                // silently fuzzes nothing: build.zig only wires this runner when
                // `-Dtest-skip-names=true` is passed, and `--fuzz` is meant to
                // keep Zig's own runner.
                std.debug.print(
                    "zm-test-runner: unsupported build-system message 0x{x} — this runner does not implement fuzzing; drop -Dtest-skip-names when passing --fuzz\n",
                    .{@backingInt(hdr.tag)},
                );
                std.process.exit(1);
            },
        }
    }
}

/// Entry point the compiler-generated code references whenever the suite
/// contains `std.testing.fuzz` blocks — without this export the filtered
/// build fails to compile (`root ... has no member named 'fuzz'`). Actual
/// fuzzing is not available here (`.simple`/server mode); mirror the default
/// runner's non-fuzz contract instead: replay the declared corpus once per
/// input, then one empty input as a smoke test.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *std.testing.Smith) anyerror!void,
    options: std.testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();
    if (builtin.fuzz) @panic("the zigmodu test runner does not support fuzz mode; drop -Dtest-filter so the default runner is used");
    for (options.corpus) |input| {
        var smith: std.testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: std.testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
