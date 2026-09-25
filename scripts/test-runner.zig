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
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.eql(u8, arg, "--listen=-")) {
            @panic("the zigmodu test runner is used in .simple mode; --listen=- is not supported");
        }
        // Anything else (e.g. `--cache-dir=`) is accepted and ignored, so the
        // runner keeps working if the build system starts passing more flags.
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
                std.debug.print("SKIP\n", .{});
            },
            else => {
                fail_count += 1;
                std.debug.print("FAIL ({t})\n", .{err});
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            },
        }
    }

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

/// Entry point the compiler-generated code references whenever the suite
/// contains `std.testing.fuzz` blocks — without this export the filtered
/// build fails to compile (`root ... has no member named 'fuzz'`). Actual
/// fuzzing is not available here (`.simple` wiring); mirror the default
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
