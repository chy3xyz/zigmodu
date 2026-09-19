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
REF_METRIC="atomic RMW x10M"
NORMALIZED_METRICS=(
  "Mailbox post+drain x1M"
  "Mailbox full-path x10M"
  "HotBus 8sub x1M"
  "Sequencer x10M"
  "1L x10M events"
  "RingBuffer SPSC x1M"
)
export BENCH_REF_METRIC="$REF_METRIC"
export BENCH_NORMALIZED_METRICS="$(IFS=';'; printf '%s' "${NORMALIZED_METRICS[*]}")"
export BENCH_MACHINE=""

MODE=check
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --update) MODE=update ;;
    --force) FORCE=1 ;;
    *)
      echo "usage: $0 [--update [--force]]" >&2
      exit 2
      ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zigmodu-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Machine identification for the verdict. Every source is best-effort: a missing
# region prints `?` and the gate carries on (see the header).
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
BENCH_MACHINE="region=$REGION cpu=$(machine_cpu) cores=$(machine_cores)"
export BENCH_MACHINE

echo "machine: $BENCH_MACHINE  |  $(uname -srm)"
if [ "$REGION" = "?" ]; then
  echo "         region unavailable (no BENCH_REGION, no Azure IMDS answer) — diagnostic only, not a failure"
fi
echo "criterion: absolute ms for every metric except ${#NORMALIZED_METRICS[@]} atomic-path metric(s), which are a ratio to '$REF_METRIC' (same run, both medians of 3)"
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
ref_name = os.environ["BENCH_REF_METRIC"]
normalized = [n for n in os.environ["BENCH_NORMALIZED_METRICS"].split(";") if n]

cur = json.load(open(results_path))
old = {m["name"]: m for m in json.load(open(base_path))} if os.path.exists(base_path) else {}
values = {m["name"]: m["value"] for m in cur}

# The reference value this recording run divides by. Without it a normalized
# metric cannot be expressed as a ratio, and writing milliseconds into a ratio
# entry would compare 0.77 against 16.9 ms and pass everything — so its entry is
# left alone instead.
ref = values.get(ref_name)
if ref is not None and ref <= 0:
    ref = None
if normalized and ref is None:
    print(f"WARN: this run produced no usable '{ref_name}' — the ratio baselines are left as they are", file=sys.stderr)


def recorded_ratio(entry):
    """The ratio a previous recording holds for `entry`, or None if it has none."""
    if entry is None or entry.get("normalized_by") is None or entry.get("value") is None:
        return None
    return entry["value"]


loosened = []
converted = []
out = []
for m in cur:
    name, value = m["name"], m["value"]
    prev = old.get(name)

    if name not in normalized:
        out.append({"name": name, "unit": m.get("unit", "ms"), "value": value})
        was = prev["value"] if prev is not None and prev.get("normalized_by") is None else None
        if was is not None and was > 0 and value > was * threshold:
            loosened.append((name, was, value, None))
        continue

    if ref is None:
        # Keep the recorded ratio (or record the entry as still pending) rather
        # than downgrading a ratio entry to milliseconds.
        out.append(prev if prev is not None else {"name": name, "unit": "ratio", "value": None, "normalized_by": ref_name})
        continue

    ratio = round(value / ref, 4)
    out.append({"name": name, "unit": "ratio", "value": ratio, "normalized_by": ref_name})
    if prev is not None and prev.get("normalized_by") is None:
        converted.append(name)
    was = recorded_ratio(prev)
    if was is not None and ratio > was * threshold:
        loosened.append((name, was, ratio, ref))

if loosened and not force:
    print(f"FAIL: --update would record {len(loosened)} metric(s) more than {threshold}x slower:", file=sys.stderr)
    for name, was, actual, divisor in loosened:
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
print(f"  {len(normalized)} entry/entries recorded as a ratio to '{ref_name}' (`normalized_by`), value = metric ÷ reference, both medians of this run")
if added:
    print(f"  new: {', '.join(added)}")
if dropped:
    print(f"  pruned: {', '.join(dropped)}")
if converted:
    print(f"  converted from absolute ms to a ratio (review these): {', '.join(converted)}")
if pending:
    print(f"  still pending — no ratio recorded, the gate WARNs and skips them: {', '.join(pending)}")
if loosened:
    print(f"  recorded with --force: {', '.join(name for name, _, _, _ in loosened)}")
EOF
  exit 0
fi

python3 - "$THRESHOLD" "$RESULTS" "$BASELINE" "$WORK/bench.log" <<'EOF'
import json, os, sys

threshold = float(sys.argv[1])
results_path, base_path, log_path = sys.argv[2], sys.argv[3], sys.argv[4]
ref_name = os.environ["BENCH_REF_METRIC"]
normalized = [n for n in os.environ["BENCH_NORMALIZED_METRICS"].split(";") if n]
machine = os.environ.get("BENCH_MACHINE", "")

if not os.path.exists(base_path):
    print(f"FAIL: no baseline at {base_path} — create one with: scripts/check-bench.sh --update", file=sys.stderr)
    sys.exit(2)

cur = json.load(open(results_path))
base = {m["name"]: m for m in json.load(open(base_path))}
seen = set()

# The reference for this run: every normalized metric is divided by the medians
# this same run measured, which is what cancels the host generation.
ref = {m["name"]: m["value"] for m in cur}.get(ref_name)
if ref is not None and ref <= 0:
    ref = None

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

slower, unmeasurable, pending, mismatch, host_notes = [], [], [], [], []
ratio_detail = []
new_metrics = [m["name"] for m in cur if m["name"] not in base]
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

    if name == ref_name:
        # The reference is the host, not the framework. Gating it on an absolute
        # value would fire on exactly the host generation change this criterion
        # exists to cancel, so it is reported and stays out of the verdict (see
        # the header): a breach here says "this runner is a different generation",
        # which is the context for everything above it, not a regression.
        if was is None:
            pending.append(f"{name} (absolute ms — reported, never gated)")
        elif was > 0 and (actual > was * threshold or actual < was / threshold):
            host_notes.append(f"{name}: baseline {was:.3f} ms → actual {actual:.3f} ms ({actual / was:.2f}x) — this is the host's atomic path, not a framework metric; the ratio criterion cancels it, and it is reported rather than gated")
        continue

    if gate_is_ratio:
        if ref is None:
            unmeasurable.append(f"{name} (no '{ref_name}' in this run to divide by)")
            continue
        if was is None:
            pending.append(f"{name} (ratio to '{ref_name}')")
            continue
        ratio = actual / ref
        ratio_detail.append((name, ratio, was, actual))
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
ref_txt = f"{ref:.3f} ms" if ref is not None else "NOT MEASURED this run"

print(f"machine:  {machine}")
print(f"criterion: {len(cur) - len(gated_ratio)} metric(s) absolute (median ms) + {len(gated_ratio)} normalized (metric ÷ '{ref_name}', this run: {ref_txt}, threshold {threshold}x on both)")

if ratio_detail:
    print(f"normalized ({ref_name} = {ref_txt} — the two ratios the gate compares):")
    for name, ratio, was, actual in ratio_detail:
        compared = f"baseline ratio {was:.4f}, {ratio / was:.2f}x" if was is not None else "no baseline ratio to compare"
        print(f"  {name:<28s} {actual:>9.3f} ms / {ref:>8.3f} ms = {ratio:.4f}  ({compared})")

if slower:
    print(f"FAIL: {len(slower)} metric(s) slower than the baseline by more than {threshold}x (lower is better):")
    for name, kind, detail, pct in slower:
        print(f"  [{kind:8s}] {name}: {detail} (+{pct * 100:.1f}%)")
        if name in samples:
            print(f"      samples: {samples[name]}")
    print("  [absolute] compares milliseconds; [ratio] compares the metric divided by")
    print(f"  this run's '{ref_name}' against the ratio the baseline recorded, so the host")
    print("  cancels out but extra work in the metric does not (an added allocation, lock")
    print("  or atomic raises the ratio). Both compared values are medians of 3; three")
    print("  slow samples are a regression, one outlier sample (see `samples:` above) is")
    print("  machine noise — re-run before fixing.")
    print("Fix the regression, or accept it explicitly with: scripts/check-bench.sh --update --force")

if host_notes:
    print(f"NOTE: the machine reference is more than {threshold}x away from its recorded value (host generation, not code):")
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
if unmeasurable:
    print(f"WARN: no comparison possible for {', '.join(unmeasurable)} — skipped, nothing to compare against")

if not slower:
    print(f"OK: {len(cur)} metric(s) within {threshold}x of the baseline (each a median of 3 samples).")

sys.exit(1 if slower else 0)
EOF
