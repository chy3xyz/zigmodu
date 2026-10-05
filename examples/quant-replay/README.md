# quant-replay (Phase D)

**One recorded trading day, replayed byte-identically.** This is the
Deterministic Runtime's Phase D demonstration (`docs/RUNTIME.md` §15.1, design
`docs/dev/deterministic-runtime-design.md` §4.2/§5): the same pipeline code
runs a live-recorded day and then replays it from the delivery log, and the
two runs agree on every fill, reject and timer mark.

```
market ──md──▶ book ──top──▶ alpha ──signal──▶ risk ──order──▶ exec ──fill──▶ ledger
(external)     top of book   mean reversion    limits          paper         clearing
                  │                                │                            ▲
                  └──────────── mark (timer) ──────┴────────── reject ──────────┘
```

* **record** — a det runtime (manual clock, `pool_threads = 1`, seed 42) runs
  the pipeline while an *external* feed (its own Prng, outside the
  deterministic domain) walks 240 prints into the book. Only the `md` track —
  the input boundary — is recorded to a `ZDL1` delivery log. Cascades and
  timers are *not* recorded: they are deterministic functions of the boundary,
  and the replay recomputes them (§15.1's recording discipline).
* **replay** — a fresh det runtime runs the same pipeline code while
  `replay.Driver` opens the log back: `.message` records are delivered,
  `.timer` records are reproduced by the wheel (never re-posted), and every
  downstream hop is recomputed. The ledger's entry stream is the compared
  artifact.

## Run

```bash
cd examples/quant-replay
zig build run
```

A run ends like this — the six `[assert]` lines are the acceptance gate, and
any `FAIL` exits the process non-zero:

```
info: [record] day done: trades=240 log_records=249 holes=0 (entries=170)
info: [assert] log holds the whole boundary: 249 records for 240 trades (the rest are wheel marks), clean: PASS
info: [assert] ledger byte-identical: record=170 entries digest=0xbcdc937106650c23, replay x2 agree: PASS
info: [assert] book state identical: bid=10008 ask=10008 vwap=10012 prints=240: PASS
info: [assert] counters identical: signals=161 approved=109 rejected=52 fills=109 position=39 pnl=1010 marks=9 (wheel-reproduced): PASS
info: [assert] the day was non-vacuous: every downstream path fired (signals/fills/rejects/marks all > 0): PASS
info: [assert] seed fork is legal: seed 43 digest=0x79db8e9f4f023dc5 != seed 42's 0xbcdc937106650c23, and two seed-43 runs agree: PASS
```

The numbers are deterministic: the feed is a fixed-seed random walk and the
pipeline's only randomness is `rt.rng()` under seed 42, so the digest is a
stable constant of the scenario, not of the machine.

## Inspect the recorded day

The run leaves the `ZDL1` log at `./quant-replay-day/`. The offline inspector
(`zig build` at the repo root installs it) reads it without starting a runtime:

```bash
../../zig-out/bin/replay-inspect quant-replay-day --track md --limit 3
```

```
records: 249 verified
seq: 0..248
kinds: message=240 timer=9
tracks (1): md=249
holes: 0
damage: none
window [start, end): tracks {md} limit 3 3 record(s) listed ...
```

## What this proves (and what it does not)

* Same input + same seed + same topology ⇒ same event sequence — on a
  five-worker cascade with timers and seeded randomness in the handlers, not
  on a synthetic ping-pong.
* The recording discipline is *only the input boundary*: the log holds 240
  messages and 9 timer marks; the 161 signals, 109 fills and 52 rejects exist
  nowhere on disk and are reproduced identically anyway.
* A different seed forks *legally* (alpha's order-size jitter draws on
  `rt.rng()`), and two runs of that seed agree with each other — the guard
  against a random source that was "determinized" by pinning it to a constant.
* It does **not** prove cross-process determinism (P-level, explicitly out of
  scope) and it does not record side effects — the paper exchange keeps its
  books in memory; a real one is behind the injected-side-effect boundary the
  design doc's D6 describes.
