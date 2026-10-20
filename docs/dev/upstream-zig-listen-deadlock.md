# Upstream issue draft: `--listen=-` build-runner deadlock and fd-1 protocol desync (Zig 0.17.0)

> Status: **draft** — not filed. Evidence collected while bringing zmodu's CI
> up on Zig 0.17.0 stable. Filed version should drop repo-specific paths.
>
> Related local artefacts: `scripts/zig-build-test-guarded.sh` (workaround),
> `src/ai/skill.zig`/`tools/zmodu/src/life.zig` (the fd-1 write that exposed the
> second symptom), CHANGELOG 0.39.15/0.39.16.

## Environment

| | |
|---|---|
| Zig | 0.17.0 stable (`zig-linux-*` / `zig-macos-*` tarballs from ziglang.org) |
| Hosts | macOS 27 arm64 (local dev), ubuntu-24.04 x64 + arm64, macos-latest (GitHub runners) |
| Project | ~2.3k tests across 8 test binaries, `std.testing.io` (Threaded), custom `scripts/test-runner.zig` in some artifacts |

## Symptom A — `zig build test` hangs forever (host-dependent)

- `zig build test` never finishes; no test output at all.
- `maker build` shows four threads waiting in `futex`; the freshly spawned test
  binary is blocked in `readv` on stdin waiting for a run message that never
  arrives.
- `-j1` does not change it; the same binary run directly
  (`./.zig-cache/o/<hash>/test --cache-dir .zig-cache --seed=…`) passes.
- Killing the runner process tree and re-running the test binaries one by one
  proceeds normally.
- Frequency: reliably on the local macOS host, occasionally on a Linux CI
  container; GitHub-hosted runners usually do not hit it. A 900–1800 s watchdog
  with a standalone fallback has been the only reliable way to keep CI green.

Captured stacks (macOS `sample`, Linux `gdb -p`) show the two sides waiting on
each other: the runner writes the "run" message only after it has drained
something the test binary produces first, while the test binary reads its
command from stdin before producing anything.

## Symptom B — a test that writes to fd 1 desynchronises the protocol

A test that writes to raw **stdout** (fd 1) while the runner is in
`--listen=-` mode is reported as **timed out after N seconds**, even though its
captured stderr shows every step executed (the test finished its own work).

- The test binary's fd 1 is the protocol channel; any framing-agnostic write
  injects bytes the runner's parser does not expect.
- stderr is a separate pipe, so diagnostics survive and the failure looks like
  a hang rather than protocol corruption.
- Consequence: four tests in this repository (a CLI writing its human output to
  stdout) "timed out" on every CI job while passing standalone. Suppressing
  stdout in `builtin.is_test` builds fixed it.

Minimal shape:

```zig
test "writes to stdout" {
    var buf: [64]u8 = undefined;
    var f = std.Io.File.stdout();
    var w = f.writer(std.testing.io, &buf);
    try w.interface.writeAll("hello\n");
    try w.interface.flush();
}
```

Run it under `zig build test` with `--listen=-` (default when invoked by the
build runner) and observe the timeout / protocol error instead of a passing
test.

## Why this matters beyond one project

- Any Zig project whose tests emit output (progress dots, CLI golden tests,
  `std.debug.print` to fd 1, C library logging) can hit symptom B silently:
  the failure is a timeout, not a protocol error, so it reads as a flaky test.
- Symptom A makes `zig build test` unusable on some hosts with no diagnostic;
  the natural workaround (per-binary reruns) abandons the build runner's
  scheduling and caching.

## Suggested directions

1. **Separate the protocol from stdout/stderr** (dedicated fd, socketpair, or
   `--listen=<fd>`), so a test's output cannot corrupt framing.
2. If fd 1 must carry the protocol, **document it as owned by the runner** and
   make a stray write a loud protocol error naming the test, not a timeout.
3. Make the runner's wait for a test binary **observable**: if the child has
   neither produced protocol bytes nor exited within N seconds, print
   "waiting for run message from <pid>" plus a stack sample hint.
4. Provide `zig build test --no-listen` (or equivalent) as a documented
   escape hatch that keeps the build graph but runs binaries directly.

## Reproduce (manual)

```bash
# A: hang (host-dependent)
rm -rf .zig-cache && zig build test -Dtest-force-run=true

# B: fd-1 pollution
cat > /tmp/stdout_test.zig <<'ZIG'
const std = @import("std");
test "writes stdout" {
    var buf: [64]u8 = undefined;
    var f = std.Io.File.stdout();
    var w = f.writer(std.testing.io, &buf);
    try w.interface.writeAll("hello\n");
    try w.interface.flush();
}
ZIG
zig test /tmp/stdout_test.zig --listen=-   # under a build runner
```
