# runtime-workers

The v0.16+ **runtime** in one runnable, single-process pipeline. It is the
example to read before wiring workers into your own app, because every trap the
runtime docs warn about is visible in its output.

## What it demonstrates

| Concern | Where in `src/main.zig` | How you see it |
|---------|------------------------|----------------|
| State ownership (no locks) | `OrderBook` / `Risk` are `spawn`ed workers, each with its own mailbox | there is not a single `Mutex` in the file |
| Bounded backpressure | the feed thread pushes 5000 deltas faster than the book drains | `stats().dropped_full` > 0 on the book's mailbox |
| Supervision budget | `spawnActor(FaultyReporter, …, .{ .max_errors = 3, .window_ms = 60_000 })` | `stopped_by_supervisor=true` + `mailbox_closed=true` |
| L0 fan-out (`HotBus`) | `bus.subscribe(audit)` + `bus.subscribeSink(metrics)` then `freeze()` | `bus: subscribers=2 … dropped=…` |
| Timers deliver messages | `ctx.handle.after(200, …)` inside the book's handler | `timer_fires=6` in `rt.stats()`, snapshots logged by the book |
| App-owned runtime | `Pipeline.initWith` calls `ctx.runtime()` | `app.stop()` joins every worker → `[done] every worker joined` |

## Run

```bash
cd examples/runtime-workers
zig build run                    # add `--summary all` for the runtime stats table
```

Sample output from one run (counter values move between runs — the *shape* is
the point, the `[done]` line is not):

```
info: [book] started: mailbox capacity 256
info: [snapshot] bids=160 asks=152 risk_exposure=-1 checks=312 rejected=0
info: [v0.17] bus: subscribers=2 published=312 delivered=383 dropped=241 | metrics deltas=312 | audit kept=71
info: [v0.17] supervised actor: attempts=4 stopped_by_supervisor=true mailbox_closed=true
info: [stats] workers=4 sent=705 received=699 dropped=4936 handler_errors=4 timer_fires=6 timer_lag_max_ms=0
info: [book] mailbox cap=256 len=0 dropped_full=4695 coalesced=0
info: [done] every worker joined
```

## Key assertions

- **`dropped_full`** — the feed outruns the book and the book's mailbox is
  comptime-bounded, so `error.Full` is its only exit. The feed sheds and the
  book counts: `mailbox … dropped_full=4695`. A queue that "grows instead" is
  not an option here by construction.
- **`stopped_by_supervisor`** — `FaultyReporter` fails on every message; after a
  4th error in the window the runtime stops it and closes the mailbox instead of
  logging forever (`attempts=4 stopped_by_supervisor=true mailbox_closed=true`).
- **`bus.stats().dropped`** — the audit subscriber is deliberately slow; the
  frozen `HotBus` drops deltas for it rather than slowing the book down.
- **`[done] every worker joined`** — the last line is only printed after
  `app.stop()` has requested stop, woken every blocked `recv`, and joined. If
  this line is missing, something was abandoned.

Drain correctness does not depend on timing: the shutdown marker travels the
same FIFO as the data (`feed → book → risk`), so `main` waits on a barrier
instead of a sleep. `dropped_full` counts messages the *feed* could not enqueue;
the marker itself is sent with `sendBlocking` so it cannot be the one that is
dropped.

Runtime concepts and their contracts: [`docs/RUNTIME.md`](../../docs/RUNTIME.md).
The next stage of this pipeline lives in [`examples/alpha-engine`](../alpha-engine/).
