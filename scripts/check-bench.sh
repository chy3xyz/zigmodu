#!/usr/bin/env bash
# Performance-regression gate: run the ReleaseFast benchmark suite and fail when
# a tracked metric is slower than its recorded baseline by more than THRESHOLD.
#
# Direction: every metric in the suite is a duration in ms — the same
# `customSmallerIsBetter` convention the CI history action uses — so **a larger
# value is a regression**. The default tolerance is 2.0x on purpose: benchmark
# numbers on a shared CI runner wobble by tens of percent, and a tighter
# threshold produces failures nobody can act on. What this gate is for is an
# order-of-magnitude slip (an allocation that snuck into a hot loop, a mutex
# where there used to be an atomic), not a 15% wobble. Override with
# `BENCH_THRESHOLD=2.5` — never raise it just to make a real regression pass.
#
# Sampling: every metric is a **median of 3 runs**, measured by `median3` in
# `src/benchmark.zig` and recorded that way in `bench-results.json`. One sample
# is not enough to judge a shared machine: `validateModules x100K` measured
# 446 ms under load against 292/295 ms on the two runs right after it — a 1.5x
# spread that sits *inside* the 2.0x window, reported as a regression in code it
# did not touch. A metric that is genuinely 2x slower is slow in all three
# samples, so the verdict keeps its teeth, and a stall shorter than one sample is
# dropped outright. (The 1.5x band above turned out to be run-level rather than
# sample-level — samples inside one run agree to 1.07x — so the note below, not the
# median alone, is the part of this fix that covers the case that was reported.) The suite prints each metric's three samples, sorted, on the `[med3]`
# line above its timing line, and a breach prints them under the offender — so a
# failure reads as "one stall" or "three slowdowns" without re-running anything.
#
# `[pct]` lines are **not** part of the criterion. Since 2026-09-19 the suite also
# prints a latency distribution (p50/p95/p99/p99.9, ns/op, 1000 batch samples per
# metric) for the latency-sensitive metrics — see `src/benchmark.zig` and
# `docs/BEST_PRACTICES.md`. Those numbers never reach `bench-results.json`, so this
# script neither thresholds them nor knows their names: they pass through the log
# verbatim to be read, and nothing here grows a `[pct]` criterion until the
# cross-host spread of a tail is known (the same reason the atomic-path metrics
# became a ratio instead of tighter absolute thresholds).
#
# Where that spread actually comes from, recorded so nobody re-discovers it:
# `validateModules` logs one `info:` line per call, so the `validateModules x*`
# and `App lifecycle x1K` harnesses write ~7 MB of logging per sample, into this
# script's log file. On the recording machine the same binary reports that metric
# at ~63 ms when the bytes go down a pipe something is draining, and ~280 ms when
# they are written to a file — the metric is mostly the host's writeback path, and
# it moves with machine-wide I/O (the same code measured 183, 292 and 446 ms at
# different moments, while 3 samples *inside* one run agree to 1.07x). So the
# median-of-3 fixes sample-level spikes, and the re-recorded baseline covers the
# run-level band. **The durable fix is now in place**: both passes pipe the suite's
# output through a consumer instead of writing it to a file, so those ~7 MB never
# land on the measured path and the metric reports the code rather than the host's
# writeback. Never widen BENCH_THRESHOLD to paper over a band instead.
#
# Missing metrics: a baseline entry this run did not produce is a WARN (deleting
# a benchmark must not break the gate), and a metric this run produced that the
# baseline does not know is a WARN too ("add it with --update"). Only a threshold
# breach fails. A missing *baseline file* is the one hard error: with nothing to
# compare against the gate would silently pass everything.
#
# Monotonicity: `--update` refuses to record a metric more than THRESHOLD slower
# than the baseline (exit 1 + the offending entries); pass `--force` to accept a
# deliberate slowdown. The baseline is a ratchet, not a snapshot of today's
# machine. In-tolerance drift is recorded silently — that is the same bound the
# gate uses, so the baseline never loosens past the point the gate would fire.
#
# Metric scale: a metric needs enough work in it to be timed at all. The three
# `*L x* events` harnesses used to finish in 13-22 us, which this gate could not
# judge — 2.0x of 13 us is a 26 us ceiling, and an ordinary scheduling stall on a
# loaded host crosses it, so the gate kept reporting a regression in code nobody
# had touched (the failures that motivated the 2026-09-18 re-record below). They
# now run 10M deliveries and cost 12-21 ms, and `CircuitBreaker` went from 0.000 /
# 0.6 ms to 6.6 ms / 65 ms. The rest of the metrics that were still on the floor
# were rescaled in the second 2026-09-18 batch — `scanModules x1K/x10K` became
# `x100K/x1M` (9 / 92 ms), `10 checks x1K` / `100 checks x1K` became `x100K` /
# `x10K` (13 / 16 ms), `workflow 20-step x100` became `x5K` (19 ms), `findById x1K`
# became `x20K` (14 ms) and `App lifecycle x1K` became `x3K` (10 ms) — and all of
# them, plus the three event and two breaker metrics above, now sit between 6.6 ms
# and 92 ms. Size a new metric at 5 ms or more: under that the 2.0x window is
# narrower than the wobble it is supposed to see past. `App lifecycle` is the one
# that got there from 4.0 ms rather than from under 2 ms, because it was the entry
# `--update` rejected twice in a row (8.3 and 11.6 ms, a compile running on the
# host at the time) — same failure, same fix.
# A baseline of `0.000` is not a fast metric but a folded-away one, and this gate
# can only WARN on it (see the check below), so it carries no coverage.
#
# `bench-results.json` is a normal benchmark output that lands in the *cwd*
# (`src/benchmark.zig` writes it on purpose). This script builds the binary with
# `zig build benchmark-build` — a build-only step with no implicit run — installs
# it under a temporary `--prefix`, and executes it with that temp directory as its
# cwd, so the repository root never sees the file. The temp dir is removed on
# exit. Pass a cache dir through the environment if you need an isolated build
# cache: `ZIG_LOCAL_CACHE_DIR=.zig-cache-bench bash scripts/check-bench.sh`.
#
# Baseline provenance: `scripts/bench-baseline.json` holds, for each metric, the
# median of 3 samples (its JSON body is a bare array of `{name, unit, value}` —
# the format `--update` round-trips — so this comment, not the file, carries the
# provenance). Re-recorded by `bash scripts/check-bench.sh --update` on
# 2026-09-18 on an Apple M1 Pro (macOS 26.6.2, 10 cores) with the machine under
# its usual background load (load average 5-8) and *not* `--force`d: the 4 metrics
# that moved up (validateModules x10K/x100K, App lifecycle x1K, ~1.4-1.5x) were
# already at those values on this machine before the re-record — see the
# writeback note above — and the rest are unchanged within noise. Re-recorded
# again later the same day (load average 10-12, the high end of this machine's
# usual band, again without `--force`) after two benchmark-side fixes, both in
# `src/benchmark.zig`: `CircuitBreaker x100K/x1M` — whose harness folded away and
# recorded a literal 0.000 — became `x10M/x100M`, and the three `*L x* events`
# metrics were rescaled 1000x. The 5 metrics whose *name* changed came through as
# add+drop, which is also why nothing needed `--force`: a metric that was
# unmeasurable cannot pass the monotonicity check (`actual > 0 * THRESHOLD` holds
# for any positive number), so renaming is how a 0.000 entry gets replaced by a
# real one. Worst in-tolerance drift on the untouched metrics was 1.28x
# (App lifecycle x1K), everything else inside 1.10x.
#
# Re-recorded a third time the same day, again without `--force`, after the
# benchmark-side changes of the second batch (all in `src/benchmark.zig`): the six
# metrics still on the floor were rescaled (see the scale note above), and the
# harnesses whose timed loop allocates on every turn — `scanModules`,
# `checkHealth`, the workflow run, `App lifecycle`, the SQLite query loop — were
# moved off the suite's page-allocator arena onto a reclaiming allocator
# (`harness_allocator`). That second change is what let the rescaling stay honest:
# the arena never frees, so at 20K-1M turns every `free` in those loops was a
# no-op and the suite's peak RSS went 82 MB -> 213 MB, with the clock covering
# page faults instead of the code under test (peak RSS is 40 MB with the
# reclaiming allocator, and `findById x20K`'s three samples spread 1.04x against
# 1.10-1.37x before). Two `--update` attempts were refused by the monotonicity
# check before this one — `App lifecycle x1K` 11.6 ms and then 8.3 ms against a
# 4.0 ms baseline, `RateLimiter x1M` 114.8 ms against 56.7 ms on the first — while
# this machine had a ReleaseFast build of another tree running. The recorded run
# was taken after that finished (load average 9-13, `uptime` 2 days up, 13 users;
# the untouched metrics came back at 0.93-1.17x of their previous values, so no
# ratchet was loosened) and it was still not `--force`d: what moved is what was
# rescaled (7 names add+drop) plus `findById x10K`, 0.93x, which shares its
# harness with `x20K` and therefore its allocator. `App lifecycle x3K` is the
# noisiest entry in the file — 9.3-14.1 ms across the five runs around the
# recording, inside 1.01-1.13x per run — so read a ratio near 1.4x on it as that
# band, not as a regression in the code it covers.
#
# Re-recorded again after v0.27.0, without `--force`, to add the two rows the
# runtime acceptance list was still missing: `Worker spawn+join x1K` (worker
# start plus graceful stop, asserting no leaked worker) and
# `Mailbox full-path x10M` (the rejection path as a number — a full mailbox
# costs `error.Full`, and this is what that costs). `--update` rewrites every
# entry, so the untouched 23 moved as well: 21 tightened (max -18.0%,
# `validateModules x10K`) and two drifted up by noise (+0.9%
# `TimerWheel x100K`, +0.5% `ObjectPool x1M`). Nothing was add+dropped, so the
# ratchet only moved where the machine did.
#
# Re-record it
# with the same command whenever a metric is added, a slowdown is accepted on
# purpose, or the machine class changes. It is an absolute-time baseline, so it
# only transfers to a machine of comparable speed — re-record it on the runner
# that will check it (`--update`, then review the diff) rather than widening
# BENCH_THRESHOLD.
#
# `TimerWheel churn x1M` is the one entry added since the v0.27.0 recording
# (2026-09-19: `--update`, then every other entry restored by hand from the
# previous file, so that commit's baseline diff is that one entry and nothing
# else — the same run measured several untouched metrics 1.2-1.3x high under
# background load, which is why the restore matters). It exists because the wheel
# metric the suite already had, `TimerWheel x100K`, builds a wheel and drops it:
# every insert goes into a map that has never held anything, while the runtime's
# wheel lives for the whole process (`src/runtime/runtime.zig`). Same loop, same op
# count, measured on this laptop: **265.46 ms** on a wheel reused for the run
# against the `AutoHashMapUnmanaged` id index `src/runtime/timer_wheel.zig` used
# then, **28.19 ms** after that index became an `AutoArrayHashMapUnmanaged` —
# a 9.4x no fresh-wheel harness can show, and the recorded 28.193 ms is the
# `--update` run's value. `TimerWheel x100K` is unaffected in the judged run
# (7.24 ms against 6.808 ms, 1.06x). Mechanism: `docs/RUNTIME.md` §4, the `nodes`
# field's comment, and the `a long-lived wheel's lookups do not get slower as it
# ages` test in that file.
#
# That "unaffected" used to be an assertion from one judged run; it has since been
# measured directly (2026-09-19, interleaved A/B against a copy of the pre-change
# wheel, order-balanced within each round, with an A/A control measured in the
# same rounds because this host has to be treated as shared). What it costs
# `TimerWheel x100K` is in the low single digits at worst: ~1.04x on the fixed
# buffer instrument, 1.12-1.17x median on the suite's own allocator where the A/A
# control already reads 1.08x. The cost is **growth**, not steady state — the
# array index keeps two structures and rebuilds the second on every growth step
# (34 growth allocations / 14.75 MB against 15 / 10.06 MB for the hash map on a
# 100k-timer wheel), while at a presized 100k keys it is 6% *faster* to insert
# into than the old map was. That is the trade for the 9.4x above, so no entry
# here moved.
#
# **What this metric's headroom actually is** (the old note claimed "~1.8x of
# headroom"; that was 2.0 / 1.06 of one run, arithmetic rather than a reading —
# the gate only speaks on a breach, so it never reports a margin). Measured, two
# independent sample sets on the same machine, medians of `[med3]`:
#
#   8 runs         6.94 -  8.79 ms   -> 1.02x - 1.29x of the 6.808 baseline
#   12 runs        6.05 - 12.91 ms   -> 0.89x - 1.90x of the same baseline
#   neighbours in those same runs: TimerWheel churn x1M 1.05x, atomic RMW 1.04x
#
# So the metric is roughly five times noisier than the ones beside it, one run in
# the larger set came within 5% of the window, and the spread is structural: a
# **fresh** wheel armed with `count` never-reused ids grows `nodes` (34 growth
# allocations / 14.75 MB at 100k) and first-touches every page it lands on, so the
# host's page path is in the numerator by construction. The steady state is what
# `TimerWheel churn x1M` measures; this one is deliberately the cold shape.
#
#  A slow reading here is therefore a *candidate* regression: re-run before
#  believing it, and check `TimerWheel churn x1M` — if churn is flat and only this
#  one moved, it is the host's page path, not the wheel.
#
# **Do not "fix" it by moving this harness to `harness_allocator`.** That is the
# right call for the other harnesses (see the `findById x20K` note above, where it
# took the spread from 1.10-1.37x to 1.04x) precisely because their loops free
# per iteration, so the blocks come back off the freelist and keep the pages warm.
# This loop never frees — it arms and drops — so nothing returns to any freelist
# and the swap only adds `smp_allocator`'s own slab metadata. Tried and measured:
# 7.95-12.17 ms, run-to-run 1.53x, worst in-run 1.86x. It is worse on every axis.
# Full table: `docs/BEST_PRACTICES.md`, the `[pct]` section's last two bullets.
#
# The CI file (`scripts/bench-baseline.ci.json`) does **not** carry that entry
# yet. Recording it from this laptop would bake a value from the wrong machine
# class into a file whose whole point is that the two classes are not comparable
# (see the two-baselines note below), so until a run on the runner records it the
# gate reports it as a WARN ("this machine class has not recorded them") and still
# passes. Do not copy the laptop value over.
#
# Two baselines exist because there are two machine classes, and one absolute
# baseline cannot serve both:
#
#   scripts/bench-baseline.json      recorded on the maintainer's laptop
#                                    (M1 Pro, load 9-13) — the default, local.
#   scripts/bench-baseline.ci.json   recorded *from* a green CI run on
#                                    ubuntu-latest; ci.yml points
#                                    BENCH_BASELINE at it.
#
# The gap is not small: on the same code the runner measures ~1.3x the laptop
# (CircuitBreaker x10M 6.57 ms vs ~10.9 ms; every metric scales together).
# Gating CI against the laptop baseline left only ~18% of headroom under the
# 2.0x threshold and produced a false red on a commit that touched nothing but a
# shell script. Each class now ratchets against its own reference and keeps the
# full 2.0x sensitivity. `--update` writes whichever file BENCH_BASELINE
# selects, so refreshing the CI baseline means: run the gate on the runner,
# `--update`, then review the diff.
#
# Two caveats when reading or refreshing the CI file:
#
#   * Do not blanket `--update` it. Every runner is its own machine class: the
#     numbers in it came from a runner that measured ~1.19x the one before
#     (median over 23 metrics, range 0.97-1.50x on unchanged code), so a full
#     re-record bakes that day's runner speed into the ratchet. Add the metrics
#     you are introducing and leave the rest alone.
#   * `RingBuffer SPSC x1M` is gated as a ratio for the same reason as the five
#     atomic-path metrics below, but it is the one metric whose *value* differs
#     between the two machine classes by an order of magnitude: 1.09-1.57 ms on
#     the runners (x86_64, where a release store and an acquire load are plain
#     `mov`s and the loop is a store-forwarding chain) vs ~10.7 ms on the laptop
#     (aarch64, where they are `stlr`/`ldar`). Measured directly: the same
#     `benchRingBuffer` loop against a verbatim copy of `src/runtime/ring.zig`
#     with *only* `.release`/`.acquire` relaxed to `.monotonic` costs 11.70 ms on
#     this laptop against 0.954 ms for the copy — a 12.3x difference from the
#     orderings alone, and 0.954 ms is the runner's number. So the inversion was
#     never "a fast slow box": it is the host's memory-ordering implementation,
#     which is what the ratio divides out. Each baseline still holds its own
#     class's ratio (the laptop's is ~0.49, the runner's ~0.052 — they are not
#     comparable either, for the same reason), and a laptop run against the CI
#     file fails on this metric and on nothing else. Read that as a platform
#     difference, not a regression.
#
#     This is also why the metric is *not* folded-away code, and why its old
#     absolute entry was the wrong criterion rather than a pseudo-value: it is
#     reproducible per host and it *moves with the host class*. The 2026-09-19
#     Benchmark failure on `624b423` is the case in point — that commit touches only
#     `src/runtime/timer_wheel.zig` (`RingBuffer` is not reachable from it), and its
#     run landed on a WestUS3 Xeon 8370C: `RingBuffer SPSC x1M` 2.34 ms against
#     1.09/1.24/1.27/1.41/1.57 ms on the other 15 recorded runs, and that same run's
#     `atomic RMW x10M` came back at 60.58 ms against 20.67/23.68/23.69 ms — every
#     run whose host the job printed is an EPYC except this one. Within a run the
#     three samples agree to 1.03x (1.24 / 1.24 / 1.24 ms; 1.09 / 1.09 / 1.09 ms)
#     while the medians step between hosts, which is a latency chain reporting the
#     host's store-to-load-forwarding latency — not noise, and not a fold.
#
# ── Two criteria, because the old one held the host still too (2026-09-19) ──
#
# An absolute millisecond value is a statement about two things at once — the code
# and the host that ran it — and a threshold on it cannot tell them apart. The
# Benchmark job failed on `2462e70` (reproducibly: two attempts 1.3% apart) on
# exactly the metrics whose per-turn path is atomic read-modify-writes, while the
# machine as a whole was *not* slower: that run's control metrics were the fastest
# on record, while `Mailbox post+drain x1M`, `Mailbox full-path x10M`,
# `HotBus 8sub x1M`, `Sequencer x10M` and `1L x10M events` came back 2.59-4.63x
# their baseline values. The previous failure looked the same with the sign
# flipped: the host was 1.09-1.45x slower overall and those same five moved only
# 1.00-1.18x. The code was excluded separately, at the instruction level: the
# `x86_64-linux` base and head binaries contain the timed loops instruction for
# instruction (`benchEventBus`: 2683 instructions, all identical; `benchmark.main`
# differs by 2, both on a cold path), under two CPU models, and A/B runs on this
# laptop (8 rounds) and cross-compiled on Linux (5 rounds) are flat within ±1.5%.
# Across 12 recorded host generations the five never exceeded 1.3x of their own
# minimum — until two runs landed on a region whose atomic path is several times
# slower.
#
# So the gate now measures the host, in the same run, and divides by it. The suite
# grew one metric that does nothing else — `atomic RMW x10M`, a bare
# `fetchAdd(1, .monotonic)` loop (`src/benchmark.zig`, `benchAtomicRmw`) — and the
# metrics listed below are compared as `metric / atomic RMW x10M`, both medians
# from the *same* run, which cancels the host generation. Everything else stays on
# the absolute criterion it was recorded with: normalizing helps only where the
# metric tracks the reference, and the metrics whose work is in the allocator, the
# SQLite driver, a mutex or thread creation do not.
#
#   * A ratio is still a ratio of *code*: an extra allocation, an extra lock or a
#     second atomic in a normalized metric raises the ratio and fails the gate
#     exactly as it did on absolute milliseconds. Measured rather than assumed: one
#     `harness_allocator.create/destroy` pair per turn inside `benchSequencer` (10M
#     turns of ~2 ns) drove `Sequencer x10M` from ratio 1.0310 to 6.7544 and the gate
#     exited 1 naming it. The same pair inside `benchMailbox` moved its ratio
#     0.7902 -> 1.09 (+38%) and did *not* fire — 2.0x is calibrated for the
#     order-of-magnitude slip, and normalization did not change that (the ratio
#     threshold is the same 2.0x the absolute one was). The counter-proof is
#     recorded in the CHANGELOG entry for this change.
#   * The reference is recorded but deliberately *not* gated on the absolute
#     criterion: an absolute threshold on the host's own atomic cost fires exactly
#     when the host generation changes, which is the failure this section exists to
#     remove. When it lands more than THRESHOLD away from its recorded value the
#     gate says so as a host note and keeps it out of the verdict. A benchmark-side
#     bug in it would show up as a smaller denominator — ratios drifting down, not
#     failures — which is why it stays a three-line loop with nothing but the atomic
#     in it, and why the ratio baselines live next to it in the file where a
#     reviewer reads them.
#   * Normalizing is not a licence to raise BENCH_THRESHOLD. Nothing here makes a
#     *regression* pass; it only stops the host's generation from being charged to
#     the code.
#
# Baseline format, both criteria in one file: an entry is either absolute —
# `{name, unit: "ms", value}`, exactly as before — or normalized —
# `{name, unit: "ratio", value, normalized_by: "atomic RMW x10M"}`, where `value`
# is the metric divided by the reference, both as measured in the recording run.
# `normalized_by` names the reference *that entry* was recorded against, which is
# what makes a later change of reference detectable rather than silently compared
# (see the list below).
# A normalized entry with `value: null` means "this machine class has not recorded
# a ratio yet": the gate WARNs and skips it, the same way it treats a metric no
# baseline knows. `--update` writes whichever shape each metric's criterion calls
# for, from the list below; a baseline entry *without* `normalized_by` is never
# silently compared as if it were a ratio (0.77 against 16.9 ms passes anything),
# and a normalized entry whose value is milliseconds is reported as the mismatch
# it is instead of being trusted.
#
# Rolling this out to `scripts/bench-baseline.ci.json`: it was recorded before the
# reference existed, so when the ratio criterion landed its atomic-path entries
# carried `normalized_by` with a `null` value and WARNed — unchecked, but no longer
# compared against milliseconds they were never measured in. A runner recorded them
# afterwards from a real run (`--update` on the runner, then review the diff — do
# not blanket `--update` that file), and `RingBuffer SPSC x1M` was converted the
# same way: its ratio in that file is the median of three *measured* pairs from CI
# logs (1.24/23.68, 1.24/23.56 and 1.09/20.67 -> 0.0523, 0.0524, 0.0527), not a
# number derived from the laptop. Filling ratios in from an estimate is still
# rejected: `Sequencer x10M` is the same `fetchAdd` loop and measured within 2% of
# the reference on the laptop, so a plausible number is one line of arithmetic away
# — but an unmeasured number baked into a ratchet is a guess, and a guess is what
# the reviewer of this file has to trust. (A `note` on an entry records where its
# number came from; `--update` does not preserve notes, so the provenance of
# anything hand-converted belongs here in the header.)
#
# Machine information (region, CPU, cores) is printed with the verdict: a
# benchmark number means nothing without it, and digging it out of the job's "Set
# up job" group after a red build is the step nobody does. Region comes from
# `BENCH_REGION` if set, otherwise from Azure IMDS (the runner's own host
# metadata, one short request), otherwise it prints `?`. It is diagnostic output
# and never fails the gate.
#
# ── Reading a run: the marker, and the two diagnostic modes ──
#
# Every run prints a `references` block: the declared references (`REF_METRICS`)
# with this run's drift from their recorded values, each row carrying the fixed
# token **RE-RUN-BEFORE-FIX**. That token is not "ignore this row" and not a
# verdict — it says a reading on this row is a *candidate fallback*: re-run
# before changing anything. Each row also carries a role tag, which is where the
# measured reason a metric is not gated now lives in machine-readable form
# (`REF_METRIC_ROLES` below: `control` / `candidate` / `hand-off`), and rows
# outside the host-suspect band are additionally tagged `HOST-MOVED`.
#
# `HOST-MOVED` is the signal that matters most here, and it used to live only in
# prose: a run reported `findById x10K` 2.1x slow while the machine's own
# `atomic RMW x10M` reference went 22.2 -> 35.8 ms *in that same run*, so every
# number in it was the host's. The suspect band is deliberately narrower than
# `THRESHOLD` (2.0x): a reference is one of the host's simplest loops, its
# recorded run-to-run drift is a few percent, and a host slowed by 1.6x never
# trips a 2.0x note — which is exactly how that false red survived the gate's
# own host note.
#
# Two modes read a run without producing one, so the question "noise or real
# regression?" is answerable from a log instead of from an argument:
#
#   --explain <log>...   the procedure. Prints step 1 (every declared reference,
#                        this run vs its recorded value, tagged `HOST-MOVED` or
#                        `flat`) and step 2 (what the gate would fail on), then
#                        one verdict token: `RE-RUN-BEFORE-FIX` when a reference
#                        moved in the same run, `REAL-REGRESSION-CANDIDATE` when
#                        they are flat and the metric moved anyway, `NO-BREACH`
#                        when there is nothing to explain. Exit 0 for the first
#                        and third, 1 for the second, 3 when the input cannot be
#                        read. These exit codes are the *procedure's* answer, not
#                        the gate's; the gate is still this script with no
#                        arguments and still fails only on a breach.
#
#   --ratios <log|baseline.json>...
#                        the cross-host procedure for the one decision a single
#                        machine cannot settle: which reference `RingBuffer SPSC
#                        x1M` should divide by. Prints every metric/reference
#                        pair each input can express, then the spread
#                        (max/min) per (metric, reference, host class). It
#                        prints spreads and draws no conclusion, and it sets no
#                        default — see the `StoreForward x10M` note above for
#                        what that decision needs.
#
# Both read `scripts/lib/bench-log.py`, both need a saved log (the stdout of this
# script, of a bare `benchmark` run, or of a CI job that ran either), and neither
# builds, runs or re-records anything. `THRESHOLD`, both baseline files and every
# value in them are untouched by either mode.
#
# The full convention — which number to quote for a test run, which one is the
# secondary label, and what the marker obliges you to do — is
# `docs/dev/READING_NUMBERS.md`.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE="${BENCH_BASELINE:-scripts/bench-baseline.json}"
THRESHOLD="${BENCH_THRESHOLD:-2.0}"

# The machine reference and the metrics gated as a ratio against it (see the
# header). This list *is* the criterion: a baseline entry that disagrees with it
# is a mismatch the gate reports, not something it quietly trusts.
#
# A metric belongs here when its per-turn critical path is a single memory-ordering
# primitive, so that what moves the number is the host's implementation of it and
# not the framework's code:
#
#   * the five atomic-path metrics below spend the turn in a read-modify-write,
#     which is the host's atomic speed;
#   * `RingBuffer SPSC x1M` spends the turn in one store→load chain per index —
#     `tryPush` stores `tail` and `tryPop` loads it back, and the same for `head` —
#     so it is the host's release/acquire lowering plus its store-to-load-forwarding
#     latency. Both terms are host properties: 1.09/1.24/1.41/1.57 ms across the
#     EPYC runners against 2.34 ms on the one Xeon 8370C run that reddened `624b423`
#     (see the header), and 10.7 ms for the identical loop on aarch64, where the
#     orderings become `stlr`/`ldar` (a verbatim copy of `ring.zig` with only the
#     orderings relaxed measures 0.954 ms on that same laptop).
#
# `ObjectPool x1M` takes a `SpinLock` per turn and is deliberately absent: it stayed
# inside 1.1x across the host generations that moved these five (0.97x on that Xeon
# run), and a ratio that does not track the reference trades a false red for a blind
# spot. The ring's ratio is also only an *approximation* — the Xeon run put it at
# 0.0386 against 0.0523-0.0527 on the EPYCs, a 26% spread, because a store-forwarding
# chain is penalized somewhat less than a locked RMW when the host generation changes.
# That imperfection is still the right trade for a 2.0x window: the ratios stay 26%
# apart where the absolute values were 2.15x apart, and 2.15x is what failed a commit
# that could not reach this code.
#
# ── One reference per metric ──
#
# An entry may name its own reference as `<metric>=<reference>`; a bare name keeps
# the default (`REF_METRIC`). The reason is the ring: a locked RMW and a store→load
# forwarding chain are different host properties, and a single reference cannot
# cancel both — the same commit's ring ratio is 0.0524 on the EPYC runners and
# 0.4976 on the aarch64 laptop that recorded `scripts/bench-baseline.json`, a 9.5x
# gap in the *ratio*, which is the one thing a ratio is supposed to remove.
#
# `StoreForward x10M` (`src/benchmark.zig`) is the closer denominator for that
# metric and nothing else: the ring's turn with the index arithmetic, the mask, the
# fullness branch and the slot array removed, leaving two release stores and two
# acquire loads per round on one cache line in one thread. **It is deliberately not
# wired up here.** Whether it cancels the host better than the atomic does is a
# claim about spread across host generations, and the evidence for the one in use
# (26% on the ratio against 2.15x absolute, from EPYC-vs-Xeon CI logs) cannot be
# beaten from a single machine. This round delivered the mechanism and the
# candidate, both recorded and printed; the decision is one edit in the array below
# (`"RingBuffer SPSC x1M=StoreForward x10M"`) plus `--update` on a machine of each
# class. The gate will not compare across a reference change silently: a baseline
# entry recorded against a different reference than the list names is reported as
# `retargeted` and skipped, not compared.
#
# A reference is a host measurement, not a framework metric, so a metric named as
# one — the default and any reference the list names — is reported but never gated
# on the absolute criterion, even when every run has to be re-recorded for the
# candidate above to be usable. A gate that fires on the host's own memory path is
# the failure this whole criterion exists to remove. The candidate has to be named
# here explicitly to get that treatment while nothing divides by it yet: otherwise
# its recorded millisecond value would be a *second* absolute gate that fires when
# the host generation changes, which is precisely the failure the reference
# criterion exists to remove.
#
# What was measured on the machine that recorded the local baseline (Apple M1 Pro,
# 11 runs of the suite, 2026-09-20). This is the evidence that the mechanism works,
# **not** evidence that the candidate is the better denominator: the ring's ratio to
# the atomic came back 0.4771-0.5086 (median 0.4949, 6.6% spread) and its ratio to
# `StoreForward x10M` 0.0866-0.0903 (median 0.0882, 4.3%). Both are stable run to
# run, and the candidate's is the tighter of the two *on this host* — all a single
# host can show. The open question is the one these numbers cannot answer: does the
# candidate's ratio move less than the 26% the atomic's ratio moved between EPYC and
# Xeon 8370C? That needs runs from at least two host classes. Until then the ring
# keeps its atomic denominator, and `StoreForward x10M` is a recorded, printed,
# ungated number — no entry in either baseline file divides by it.
REF_METRIC="atomic RMW x10M"
# Metrics whose absolute value is a **host** property, so they are recorded and
# printed but never gated. The two hand-off rows are here for a measured reason
# rather than a stylistic one: eight runs of the suite on this machine gave
# `Worker drain dedicated x1M` 122.9-226.2 ms (1.84x) and `Pooled dispatch x1M`
# 214.4-661.6 ms (3.09x), against 1.26x for `Mailbox post+drain x1M` in the same
# runs. A 2.0x window on a number that swings 3x within one machine is a
# false-red machine — one run in eight already breached it against its own low
# sample. What the pair is *for* is the boundary (`docs/RUNTIME.md` §12.5):
# pooled costs ~2x a dedicated hand-off (ratio 1.57-2.93 over those runs), which
# is why the critical path stays dedicated and the long tail pools.
REF_METRICS=(
  "$REF_METRIC"
  "StoreForward x10M"
  "Worker drain dedicated x1M"
  "Pooled dispatch x1M"
)
NORMALIZED_METRICS=(
  "Mailbox post+drain x1M"
  "Mailbox full-path x10M"
  "HotBus 8sub x1M"
  "Sequencer x10M"
  "1L x10M events"
  "RingBuffer SPSC x1M"
)

# Role and reason per declared reference, `<name>=<role>|<reason>`. **Presentation
# only**: this list decides nothing. What a metric is gated on is
# `NORMALIZED_METRICS` (a ratio) or nothing at all (`REF_METRICS`), and a name
# here that is not in `REF_METRICS` is rejected below rather than quietly
# gaining a second meaning. It exists so the reasons scattered in the comments
# above ("the host's own atomic cost", "a cross-host claim no single machine can
# settle", "swings 3x within one machine") print next to the numbers they are
# about, machine-readable, in the `references` block and in `--explain`.
REF_METRIC_ROLES=(
  "atomic RMW x10M=control|the host's own atomic cost; gating it fires on a host-generation change, which is what the ratio criterion exists to cancel"
  "StoreForward x10M=candidate|the closer denominator for the ring; whether it cancels the host better than the atomic is a cross-host claim"
  "Worker drain dedicated x1M=hand-off|half of the dedicated-vs-pooled boundary; 1.84x run-to-run spread within one machine"
  "Pooled dispatch x1M=hand-off|the other half of that boundary; 3.09x run-to-run spread within one machine"
)
export BENCH_REF_METRIC="$REF_METRIC"
export BENCH_REF_METRICS="$(IFS=';'; printf '%s' "${REF_METRICS[*]}")"
export BENCH_NORMALIZED_METRICS="$(IFS=';'; printf '%s' "${NORMALIZED_METRICS[*]}")"
export BENCH_REF_ROLES="$(IFS=';'; printf '%s' "${REF_METRIC_ROLES[*]}")"
export BENCH_MACHINE=""

# A role for a metric that is not a declared reference would be a label on a
# metric nothing reports as a host measurement — reject it here instead.
for role_entry in "${REF_METRIC_ROLES[@]}"; do
  role_name="${role_entry%%=*}"
  found=0
  for ref_name in "${REF_METRICS[@]}"; do
    if [ "$role_name" = "$ref_name" ]; then found=1; fi
  done
  if [ "$found" -ne 1 ]; then
    echo "FAIL: REF_METRIC_ROLES names '$role_name', which is not in REF_METRICS" >&2
    exit 2
  fi
done
unset role_entry role_name ref_name found

# The host-suspect band: how far a *reference* may drift from its recorded value
# before a reading on it is the host rather than the code. Diagnostic only — it
# gates nothing (see the header) — but it is the band `--explain` and the
# `references` block classify with, and it is narrower than `THRESHOLD` on
# purpose: the recorded false red had a reference at 1.61x, which a 2.0x note
# cannot see. A reference is one of the host's simplest loops, so its own
# run-to-run drift on one machine is a few percent: `atomic RMW x10M` stayed
# within 1.04x across the runs that recorded the local baseline, and the ring's
# ratio to it within 1.083x (max/min over 12 runs).
HOST_SUSPECT="${BENCH_HOST_SUSPECT:-1.25}"
export BENCH_HOST_SUSPECT="$HOST_SUSPECT"

MODE=check
FORCE=0
INPUTS=()
usage_line="usage: $0 [--update [--force]] | --explain <log>... | --ratios <log|baseline.json>..."
for arg in "$@"; do
  case "$arg" in
    --update) MODE=update ;;
    --force) FORCE=1 ;;
    --explain) MODE=explain ;;
    --ratios) MODE=ratios ;;
    --explain=*) MODE=explain; INPUTS+=("${arg#--explain=}") ;;
    --ratios=*) MODE=ratios; INPUTS+=("${arg#--ratios=}") ;;
    -*) echo "$usage_line" >&2; exit 2 ;;
    *)
      if [ "$MODE" = explain ] || [ "$MODE" = ratios ]; then
        INPUTS+=("$arg")
      else
        # A log path with no mode that consumes it is a caller who meant to
        # explain: running --update on it instead would rewrite a baseline.
        echo "$usage_line" >&2
        exit 2
      fi
      ;;
  esac
done
if [ ${#INPUTS[@]} -gt 0 ] && [ "$MODE" != explain ] && [ "$MODE" != ratios ]; then
  echo "$usage_line" >&2
  exit 2
fi

# The two diagnostic modes read a saved log and stop here: no temp dir, no build,
# no suite, no comparison against a fresh run. `BENCH_BASELINE_RESOLVED` is what
# `scripts/lib/bench-log.py` compares against — the same file this script would
# have used, so `BENCH_BASELINE=scripts/bench-baseline.ci.json … --explain` reads
# the CI class exactly as the gate does.
if [ "$MODE" = explain ] || [ "$MODE" = ratios ]; then
  export BENCH_BASELINE_RESOLVED="$BASELINE"
  export BENCH_THRESHOLD_EFFECTIVE="$THRESHOLD"
  python3 scripts/lib/bench-log.py "$MODE" ${INPUTS[@]+"${INPUTS[@]}"}
  exit $?
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zigmodu-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Machine identification for the verdict. Every source is best-effort: a missing
# region prints `?` and the gate carries on (see the header).
# 1-minute load average, or `?` when neither source answers. Best-effort like the
# rest of the machine identification: a missing value prints `?` and the gate
# carries on.
machine_load() {
  if [ -r /proc/loadavg ]; then
    cut -d' ' -f1 /proc/loadavg
    return
  fi
  if command -v sysctl >/dev/null 2>&1; then
    # macOS: `{ 10.00 9.67 8.25 }`
    sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'
    return
  fi
  printf '?'
}

machine_region() {
  if [ -n "${BENCH_REGION:-}" ]; then
    printf '%s' "$BENCH_REGION"
    return
  fi
  local region
  region="$(curl -fsS --connect-timeout 2 --max-time 3 -H 'Metadata:true' \
    'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text' 2>/dev/null || true)"
  if [ -n "$region" ]; then printf '%s' "$region"; else printf '?'; fi
}

machine_cpu() {
  local cpu=""
  case "$(uname -s)" in
    Darwin) cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)" ;;
    Linux) cpu="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)" ;;
  esac
  if [ -n "$cpu" ]; then printf '%s' "$cpu"; else printf '?'; fi
}

machine_cores() {
  local cores
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [ -n "$cores" ]; then printf '%s' "$cores"; else printf '?'; fi
}

REGION="$(machine_region)"
# Load average goes **into the machine line**, because it is the one signal the
# offline `--explain` cannot recover any other way. This gate's references are
# deliberately the host's *simplest* loops (`atomic RMW`, and the store->load
# chain next to it), and a cache-local loop stays flat while a memory-path metric
# doubles when the machine is full — so "references flat, metric moved" is the
# *expected* shape under saturation, not the suspicious one. Measured twice on
# 2026-09-20: `TimerWheel x100K` read 2.14x and 2.52x with every reference inside
# 1.08x, at load 10.0 on 10 cores. Without this field `--explain` called both of
# them `REAL-REGRESSION-CANDIDATE`.
BENCH_MACHINE="region=$REGION cpu=$(machine_cpu) cores=$(machine_cores) load=$(machine_load)"
export BENCH_MACHINE

echo "machine: $BENCH_MACHINE  |  $(uname -srm)"
if [ "$REGION" = "?" ]; then
  echo "         region unavailable (no BENCH_REGION, no Azure IMDS answer) — diagnostic only, not a failure"
fi
echo "criterion: absolute ms for every metric except ${#NORMALIZED_METRICS[@]} normalized metric(s), a ratio to a reference measured in the same run (both medians of 3; default '$REF_METRIC'). References are reported, never gated: ${REF_METRICS[*]}"
echo

echo "building benchmark (ReleaseFast)..."
zig build benchmark-build -Doptimize=ReleaseFast --prefix "$WORK/prefix"

mkdir -p "$WORK/run"
# Two passes in the same directory, each of which measures every metric as the
# median of 3 samples (see the header). The first pass is discarded in full:
# exec'ing a freshly installed copy pays a one-off page-in (plus signature
# validation on macOS) worth tens of microseconds, invisible on a 16 ms metric
# but a 2-3x swing on a 12 us one — measured at 2.7x on `100L x100 events`, and
# it would otherwise be baked into whichever values get recorded as the baseline.
# The measured pass is the second one: its three samples per metric are taken
# back to back on pages the discarded pass already brought in, and the middle of
# those three is what gets recorded and compared.
if ! ( cd "$WORK/run" && "$WORK/prefix/bin/benchmark" ) 2>&1 | { grep -v '^info: ' || true; } >"$WORK/bench-warmup.log"; then
  echo "FAIL: the benchmark binary exited non-zero (warm-up pass)" >&2
  grep -v '^info: ' "$WORK/bench-warmup.log" >&2 || true
  exit 2
fi
if ! ( cd "$WORK/run" && "$WORK/prefix/bin/benchmark" ) 2>&1 | { grep -v '^info: ' || true; } >"$WORK/bench.log"; then
  echo "FAIL: the benchmark binary exited non-zero" >&2
  grep -v '^info: ' "$WORK/bench.log" >&2 || true
  exit 2
fi

# Print the timings, not the suite's own progress logging: `validateModules` runs
# 110k times and logs an `info:` line per call (~7 MB) that would bury the gate's
# verdict.
grep -v '^info: ' "$WORK/bench.log" || true

RESULTS="$WORK/run/bench-results.json"
if [ ! -f "$RESULTS" ]; then
  echo "FAIL: the benchmark binary wrote no bench-results.json" >&2
  exit 2
fi

if [ "$MODE" = "update" ]; then
  python3 - "$FORCE" "$RESULTS" "$BASELINE" "$THRESHOLD" <<'EOF'
import json, os, sys

force = sys.argv[1] == "1"
results_path, base_path, threshold = sys.argv[2], sys.argv[3], float(sys.argv[4])
ref_default = os.environ["BENCH_REF_METRIC"]

# The gating list, as `metric -> reference`: `metric=reference` names its own, a
# bare `metric` takes the default. The dict keeps the list's order, so the
# reports below are deterministic.
normalized = {}
for item in os.environ["BENCH_NORMALIZED_METRICS"].split(";"):
    if not item:
        continue
    metric, sep, ref = item.partition("=")
    normalized[metric] = ref if sep else ref_default

cur = json.load(open(results_path))
old = {m["name"]: m for m in json.load(open(base_path))} if os.path.exists(base_path) else {}
values = {m["name"]: m["value"] for m in cur}


def reference_for(metric):
    """(name, value) of the reference `metric` is divided by; value is None when
    this recording run produced no usable one.

    Without a value the metric cannot be expressed as a ratio, and writing
    milliseconds into a ratio entry would compare 0.77 against 16.9 ms and pass
    everything — so that entry is left as it is instead."""
    name = normalized[metric]
    value = values.get(name)
    if value is None or value <= 0:
        return name, None
    return name, value


# One WARN per reference this run could not supply, not one per metric on it.
missing_refs = []
for metric in normalized:
    name, value = reference_for(metric)
    if value is None and name not in missing_refs:
        missing_refs.append(name)
for name in missing_refs:
    print(f"WARN: this run produced no usable '{name}' — the ratio baselines dividing by it are left as they are", file=sys.stderr)


def recorded_ratio(entry):
    """The ratio a previous recording holds for `entry`, or None if it has none."""
    if entry is None or entry.get("normalized_by") is None or entry.get("value") is None:
        return None
    return entry["value"]


loosened = []
converted = []
retargeted = []
out = []
for m in cur:
    name, value = m["name"], m["value"]
    prev = old.get(name)

    if name not in normalized:
        out.append({"name": name, "unit": m.get("unit", "ms"), "value": value})
        was = prev["value"] if prev is not None and prev.get("normalized_by") is None else None
        if was is not None and was > 0 and value > was * threshold:
            loosened.append((name, was, value, None, None))
        continue

    ref_name, ref = reference_for(name)
    if ref is None:
        # Keep the recorded ratio (or record the entry as still pending) rather
        # than downgrading a ratio entry to milliseconds.
        out.append(prev if prev is not None else {"name": name, "unit": "ratio", "value": None, "normalized_by": ref_name})
        continue

    ratio = round(value / ref, 4)
    out.append({"name": name, "unit": "ratio", "value": ratio, "normalized_by": ref_name})
    if prev is not None and prev.get("normalized_by") is None:
        converted.append(name)
    if prev is not None and prev.get("normalized_by") not in (None, ref_name):
        # A ratio to a different reference is a different unit, so the ratchet has
        # nothing to compare against: this is a re-record, not a slowdown. The new
        # ratio is written above (that is what `--update` is for) and named here for
        # review; the check pass reports the same disagreement as `retargeted` and
        # skips it rather than comparing two ratios against different denominators.
        retargeted.append(f"{name} ('{prev['normalized_by']}' → '{ref_name}')")
        continue
    was = recorded_ratio(prev)
    if was is not None and ratio > was * threshold:
        loosened.append((name, was, ratio, ref, ref_name))

if loosened and not force:
    print(f"FAIL: --update would record {len(loosened)} metric(s) more than {threshold}x slower:", file=sys.stderr)
    for name, was, actual, divisor, ref_name in loosened:
        if divisor is None:
            print(f"  {name}: baseline {was:.3f} ms → actual {actual:.3f} ms (+{(actual / was - 1) * 100:.1f}%)", file=sys.stderr)
        else:
            print(f"  {name}: ratio baseline {was:.4f} → actual {actual:.4f} (÷ '{ref_name}' {divisor:.3f} ms = {actual * divisor:.3f} ms) (+{(actual / was - 1) * 100:.1f}%)", file=sys.stderr)
    print("Fix the regression, or pass --force to record a deliberate slowdown.", file=sys.stderr)
    sys.exit(1)

added = [m["name"] for m in cur if m["name"] not in old]
dropped = [n for n in old if n not in {m["name"] for m in cur}]
pending = [e["name"] for e in out if e.get("normalized_by") is not None and e.get("value") is None]

with open(base_path, "w") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")

print(f"baseline updated: {len(old)} -> {len(out)} metric(s) (+{len(added)} / -{len(dropped)})")
print("  absolute entries are the median of 3 samples per metric (see src/benchmark.zig median3)")
if normalized:
    print("  ratio entries hold `value` = this run's metric ÷ its reference, both medians of this run:")
    by_ref = {}
    for metric, ref in normalized.items():
        by_ref.setdefault(ref, []).append(metric)
    for ref, metrics in by_ref.items():
        print(f"    '{ref}'  <- {', '.join(metrics)}")
if added:
    print(f"  new: {', '.join(added)}")
if dropped:
    print(f"  pruned: {', '.join(dropped)}")
if converted:
    print(f"  converted from absolute ms to a ratio (review these): {', '.join(converted)}")
if retargeted:
    print(f"  recorded against a new reference — the old ratio was in different units, so the ratchet could not compare it (review these): {', '.join(retargeted)}")
if pending:
    print(f"  still pending — no ratio recorded, the gate WARNs and skips them: {', '.join(pending)}")
if loosened:
    print(f"  recorded with --force: {', '.join(name for name, _, _, _, _ in loosened)}")
EOF
  exit 0
fi

python3 - "$THRESHOLD" "$RESULTS" "$BASELINE" "$WORK/bench.log" <<'EOF'
import json, os, sys

threshold = float(sys.argv[1])
results_path, base_path, log_path = sys.argv[2], sys.argv[3], sys.argv[4]
ref_default = os.environ["BENCH_REF_METRIC"]
machine = os.environ.get("BENCH_MACHINE", "")

# The gating list, as `metric -> reference`: `metric=reference` names its own, a
# bare `metric` takes the default. The dict keeps the list's order.
normalized = {}
for item in os.environ["BENCH_NORMALIZED_METRICS"].split(";"):
    if not item:
        continue
    metric, sep, ref = item.partition("=")
    normalized[metric] = ref if sep else ref_default

# Every metric named as a reference — the declared ones (the default divisor plus
# any candidate nothing divides by yet), and any the list names: those are host
# measurements, never framework metrics.
ref_names = {n for n in os.environ["BENCH_REF_METRICS"].split(";") if n} | set(normalized.values())

if not os.path.exists(base_path):
    print(f"FAIL: no baseline at {base_path} — create one with: scripts/check-bench.sh --update", file=sys.stderr)
    sys.exit(2)

cur = json.load(open(results_path))
base = {m["name"]: m for m in json.load(open(base_path))}
seen = set()

# The reference values for this run: every normalized metric is divided by the
# median this same run measured *of its own reference*, which is what cancels the
# host generation.
values = {m["name"]: m["value"] for m in cur}


def reference_for(metric):
    """(name, value) of the reference `metric` is divided by; value None when this
    run has no usable one."""
    name = normalized[metric]
    value = values.get(name)
    if value is None or value <= 0:
        return name, None
    return name, value


# The suite's `[med3] <name>: min / median / max` lines, so a breach can show the
# three samples behind the median it compared. Missing log (deleted temp dir,
# piped run) degrades to no sample lines, never to a crash.
samples = {}
if os.path.exists(log_path):
    with open(log_path, errors="replace") as fh:
        for line in fh:
            entry = line.strip()
            if not entry.startswith("[med3] "):
                continue
            head, _, rest = entry[len("[med3] "):].partition(": ")
            if rest:
                samples[head] = rest

slower, unmeasurable, pending, mismatch, host_notes, retargeted = [], [], [], [], [], []
ratio_detail = []
new_metrics = [m["name"] for m in cur if m["name"] not in base]

# ── the declared references, this run vs their recorded values ──
# Every host reference is a *host* measurement, so the drift here is the context
# the verdict below is read in, and it is printed on every run (pass or fail)
# rather than only when it breaches: the failure this block exists for reported
# the reference 1.61x away, which is inside THRESHOLD and therefore never
# reached the gate's own host note (see the header). `moved` is that reading, and
# the FAIL block below points at it. Role labels and their reasons come from
# `REF_METRIC_ROLES`, which decides nothing (presentation only).
suspect = float(os.environ.get("BENCH_HOST_SUSPECT", "1.25"))
roles = {}
for item in os.environ.get("BENCH_REF_ROLES", "").split(";"):
    if not item:
        continue
    role_name, _, rest = item.partition("=")
    role, _, reason = rest.partition("|")
    roles[role_name] = (role, reason)
role_label = {"control": "control reference", "candidate": "candidate reference",
              "hand-off": "hand-off pair", "reference": "reference"}
# Only these roles are a reading about the *machine*. The hand-off pair is not:
# it swings 1.84x / 3.09x within one machine by construction (thread hand-off),
# so calling its drift "the host moved" would be the wrong answer — it is that
# pair's own noise, and its rows are tagged `MOVED` rather than `HOST-MOVED`.
host_roles = ("control", "candidate", "reference")
declared = [n for n in os.environ.get("BENCH_REF_METRICS", "").split(";") if n]
for ref_name in normalized.values():
    if ref_name not in declared:
        declared.append(ref_name)
reference_rows = []
moved = []
for ref_name in declared:
    actual = values.get(ref_name)
    entry = base.get(ref_name)
    was = None if entry is None else entry.get("value")
    factor = None if not was or actual is None else actual / was
    users = [n for n in normalized if normalized[n] == ref_name]
    divides = f"{len(users)} metric(s) divide by it" if users else "no metric divides by it yet"
    role, _reason = roles.get(ref_name, ("reference", ""))
    out_of_band = factor is not None and (factor > suspect or factor < 1.0 / suspect)
    host_moved = out_of_band and role in host_roles
    if factor is None:
        tag = "n/a"
    elif host_moved:
        tag = "HOST-MOVED"
    elif out_of_band:
        tag = "MOVED"
    else:
        tag = "flat"
    if actual is None:
        detail = "not measured in this run"
    elif was is None:
        detail = f"{actual:>9.3f} ms (no recorded value to compare)"
    else:
        detail = f"{was:>8.3f} → {actual:>9.3f} ms  {factor:.2f}x"
    reference_rows.append((ref_name, detail, tag, role_label.get(role, role), divides, role, factor))
    if host_moved:
        moved.append((ref_name, was, actual, factor))
for m in cur:
    name, actual = m["name"], m["value"]
    seen.add(name)
    if name not in base:
        continue
    entry = base[name]
    was = entry.get("value")
    # Which criterion applies is decided by the gate's list and cross-checked
    # against what the recording actually stored: comparing a ratio to
    # milliseconds (0.77 vs 16.9) or milliseconds to a ratio passes everything,
    # so a disagreement is reported instead of compared.
    baseline_is_ratio = entry.get("normalized_by") is not None
    gate_is_ratio = name in normalized
    if baseline_is_ratio != gate_is_ratio:
        mismatch.append(f"{name} — baseline holds "
                         f"{'a ratio (normalized_by=' + str(entry.get('normalized_by')) + ')' if baseline_is_ratio else 'absolute milliseconds'}"
                         f", the gating list says {'ratio' if gate_is_ratio else 'absolute milliseconds'}")
        continue

    # Two ratios recorded against different denominators are different units, and
    # comparing them would pass (or fail) on arithmetic that means nothing. The
    # check for that lives inside the ratio branch below, after the reference
    # lookup: a *missing* reference is the more specific diagnosis (a name this run
    # did not measure at all) and has to be said first, so that nobody reads
    # "--update" as the fix for a reference name that does not exist.
    if name in ref_names:
        # A reference is the host, not the framework. Gating it on an absolute
        # value would fire on exactly the host generation change this criterion
        # exists to cancel, so it is reported and stays out of the verdict (see
        # the header): a breach here says "this runner is a different generation",
        # which is the context for everything above it, not a regression.
        users = [n for n in normalized if normalized[n] == name]
        divides = (f"{len(users)} normalized metric(s) divide by it" if users
                   else "no metric in the list divides by it yet (candidate reference)")
        if was is None:
            pending.append(f"{name} (absolute ms — reported, never gated)")
        elif was > 0 and (actual > was * threshold or actual < was / threshold):
            host_notes.append(f"{name}: baseline {was:.3f} ms → actual {actual:.3f} ms ({actual / was:.2f}x) — this is the host's memory path, not a framework metric; {divides}, and it is reported rather than gated")
        continue

    if gate_is_ratio:
        ref_name, ref = reference_for(name)
        if ref is None:
            unmeasurable.append(f"{name} (no '{ref_name}' in this run to divide by)")
            continue
        if entry.get("normalized_by") != ref_name:
            # The recording says which reference it divided by, so a later change of
            # reference is visible: reported and skipped, not compared. Re-record it
            # with `--update` on this machine class after changing the list.
            retargeted.append(f"{name} — baseline is a ratio to '{entry.get('normalized_by')}', the gating list says '{ref_name}'")
            continue
        if was is None:
            pending.append(f"{name} (ratio to '{ref_name}')")
            continue
        ratio = actual / ref
        ratio_detail.append((name, ratio, was, actual, ref_name, ref))
        if ratio > was * threshold:
            slower.append((name, "ratio",
                           f"baseline ratio {was:.4f} → actual {ratio:.4f} "
                           f"(= {actual:.3f} ms ÷ '{ref_name}' {ref:.3f} ms)",
                           ratio / was - 1))
        continue

    # A baseline of exactly 0.000 (a benchmark the optimizer folded away) has no
    # ratio to compare against; say so instead of dividing by zero.
    if was is None:
        pending.append(f"{name} (absolute ms)")
    elif was <= 0:
        unmeasurable.append(f"{name} (baseline 0.000)")
    elif actual > was * threshold:
        slower.append((name, "absolute", f"baseline {was:.3f} ms → actual {actual:.3f} ms", actual / was - 1))

gone = [n for n in base if n not in seen]
gated_ratio = [m["name"] for m in cur if m["name"] in normalized]

print(f"machine:  {machine}")
print(f"criterion: {len(cur) - len(gated_ratio)} metric(s) absolute (median ms) + {len(gated_ratio)} normalized (each metric ÷ its own reference, both medians of this run), threshold {threshold}x on both")

print("references — recorded and printed, never gated; a reading on one of these is a candidate")
print("  fallback (re-run before changing anything), not something to ignore:")
for ref_name, detail, tag, role, divides, _key, _factor in reference_rows:
    print(f"  RE-RUN-BEFORE-FIX  {ref_name:<28s} {detail:<34s} {tag:<10s} ({role}; {divides})")
host_readable = [r for r in reference_rows
                 if r[2] != "n/a" and r[5] in ("control", "candidate", "reference")]
handoff_moved = [r for r in reference_rows if r[2] == "MOVED"]
print(f"  {len(moved)} of {len(host_readable)} host reference(s) outside the {suspect:.2f}x host-suspect band"
      + ("" if moved else " — the host did not move in this run"))
if handoff_moved:
    print(f"  {len(handoff_moved)} hand-off row(s) MOVED — that pair swings 1.84x/3.09x within one machine by")
    print("  construction, so its drift says nothing about the host (docs/RUNTIME.md §12.5).")
print("  role tags: control reference = the host's own atomic cost (gating it fires on a host-generation")
print("  change); candidate reference = recorded for a reference change no single machine can settle;")
print("  hand-off pair = judged against each other (docs/RUNTIME.md §12.5), not against a gate.")
print("  'noise or regression?' — bash scripts/check-bench.sh --explain <this log>; the convention is")
print("  docs/dev/READING_NUMBERS.md.")

if ratio_detail:
    print("normalized — the two ratios the gate compares (metric ÷ its reference, same run):")
    for name, ratio, was, actual, ref_name, ref in ratio_detail:
        compared = f"baseline ratio {was:.4f}, {ratio / was:.2f}x" if was is not None else "no baseline ratio to compare"
        print(f"  {name:<28s} {actual:>9.3f} ms / {ref_name} {ref:>8.3f} ms = {ratio:.4f}  ({compared})")

if slower:
    print(f"FAIL: {len(slower)} metric(s) slower than the baseline by more than {threshold}x (lower is better):")
    for name, kind, detail, pct in slower:
        print(f"  [{kind:8s}] {name}: {detail} (+{pct * 100:.1f}%)")
        if name in samples:
            print(f"      samples: {samples[name]}")
    print("  [absolute] compares milliseconds; [ratio] compares the metric divided by")
    print("  this run's own reference against the ratio the baseline recorded, so the host")
    print("  cancels out but extra work in the metric does not (an added allocation, lock")
    print("  or atomic raises the ratio). Both compared values are medians of 3; three")
    print("  slow samples are a regression, one outlier sample (see `samples:` above) is")
    print("  machine noise — re-run before fixing.")
    # The host check: the references in this run are printed above with their
    # drift, and that is the reading that tells a slow host from slow code —
    # which is what the recorded false red needed and did not have. Only *host*
    # roles count here (see `host_roles`): a hand-off row's drift is that pair's
    # own spread, so it must not be read as "the host moved".
    measured_refs = [r for r in reference_rows
                     if r[2] != "n/a" and r[5] in ("control", "candidate", "reference")]
    if moved:
        print(f"  host check: {len(moved)} of {len(measured_refs)} host reference(s) are outside the {suspect:.2f}x band in this run:")
        for ref_name, was, actual, factor in moved:
            print(f"      {ref_name}: {was:.3f} → {actual:.3f} ms ({factor:.2f}x)")
        print("      RE-RUN-BEFORE-FIX: a host reference moved with the metric, so this failure is not yet")
        print("      evidence about the code. Re-run on a quiet machine and compare (--explain).")
    elif measured_refs:
        worst = max(measured_refs, key=lambda r: max(r[6], 1.0 / r[6]) if r[6] else 1.0)
        print(f"  host check: every measured host reference is inside the {suspect:.2f}x band (worst: {worst[0]} {worst[6]:.2f}x)")
        print(f"      — the host did not move, so this is a real-regression candidate at the {threshold}x window:")
        print("      re-run once to see it again, then look at the code the metric covers (--explain).")
    else:
        print("  host check: no declared reference was measured in this run, so the host cannot be read")
        print("      and neither can this failure — the reference line is part of the evidence (--explain).")
    print("Fix the regression, or accept it explicitly with: scripts/check-bench.sh --update --force")

if host_notes:
    print(f"NOTE: a machine reference is more than {threshold}x away from its recorded value (host generation, not code):")
    for line in host_notes:
        print(f"      {line}")

if gone:
    print(f"WARN: {len(gone)} baseline metric(s) no longer produced: {', '.join(gone)}")
    print("      (removing a benchmark does not fail the gate; run --update to prune)")
if new_metrics:
    print(f"WARN: {len(new_metrics)} metric(s) not in the baseline: {', '.join(new_metrics)}")
    print("      (run --update to record them)")
if pending:
    print(f"WARN: {len(pending)} baseline entry/entries hold no number yet — skipped, nothing to compare against:")
    for line in pending:
        print(f"      {line}")
    print("      (this machine class has not recorded them — run --update on it, then review the diff)")
if mismatch:
    print(f"WARN: {len(mismatch)} metric(s) whose baseline entry and gating list disagree — skipped, not compared:")
    for line in mismatch:
        print(f"      {line}")
if retargeted:
    print(f"WARN: {len(retargeted)} metric(s) recorded against a different reference than the gating list names — skipped, not compared:")
    for line in retargeted:
        print(f"      {line}")
    print("      (a ratio to another reference is a different unit; re-record it with --update on this machine class)")
if unmeasurable:
    print(f"WARN: no comparison possible for {', '.join(unmeasurable)} — skipped, nothing to compare against")

if not slower:
    print(f"OK: {len(cur)} metric(s) within {threshold}x of the baseline (each a median of 3 samples).")

sys.exit(1 if slower else 0)
EOF
