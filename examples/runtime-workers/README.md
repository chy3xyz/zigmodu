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
| **Pooled execution (`Scheduler`)** | `audit` is spawned `.{ .capacity = 64, .mode = .pooled }`, and `main` declares the pool with `withMaxPooledWorkers(1)` | `[pool] … spawned=1 dispatched=N push_failures=0` |
| Timers deliver messages | `ctx.handle.after(200, …)` inside the book's handler | `timer_fires=6` in `rt.stats()`, snapshots logged by the book |
| App-owned runtime | `Pipeline.initWith` calls `ctx.runtime()` | `app.stop()` joins every worker → `[done] every worker joined` |

## Which worker is pooled, and why that one

Only **`audit`** — the fan-out target at the end of the `HotBus`, with a metrics
sink next to it. `docs/RUNTIME.md` §12.5 draws the boundary:

- **message-driven** (`pub const Message` + `handle`): a `run`-owned worker could
  never be pooled, because its own loop would occupy the pool thread it was
  handed to;
- **not on the latency chain**: every hop of `feed → book → risk` is on the
  critical path and pays a ready-ring round trip if scheduled, so those two stay
  `.dedicated`. Audit is the opposite: it is slow on purpose, and the bus already
  drops for it (`audit` never slows the book down), which is exactly the long
  tail pooling exists for.

`main` declares the pool with `withMaxPooledWorkers(1)` on the app builder. That
declaration is not decoration: `.pooled` without one is refused at `spawn`, and
the declared bound is what sizes the ready ring (`docs/RUNTIME.md` §12.10).

## How you know the pool was really used

`spawn(…, .mode = .pooled)` compiling is not evidence that a batch ever reached
the pool thread — so the example reads the pool's own counters off the *running*
runtime (`Runtime.poolStats()`) and fails with a non-zero exit code if they say
otherwise:

```
info: [pool] declared=1 threads=1 spawned=1 dispatched=5 claimed=0 ready_len=0 push_failures=0
```

- `spawned=1` — one pooled worker took a pool slot (the audit worker);
- `dispatched>0` — the pool thread ran that worker's batches. A `.dedicated`
  worker never puts a token in the ready ring, so these stay at 0;
- `push_failures=0` — the contract, not a reading: a refused token push would
  strand a worker, and the example exits non-zero on it.

The example also waits for the first dispatch (bounded spin, like the
`book`/`risk` drain barrier) instead of printing whatever it finds, so a pool
that never delivers fails the run rather than printing a zero.

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
info: [pool] declared=1 threads=1 spawned=1 dispatched=6 claimed=0 ready_len=0 push_failures=0
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
- **`[pool] dispatched>0`** — a non-zero exit code is returned (before `[done]`)
  if the pooled worker never reached the pool thread, or if the ready ring
  refused a token. This example's exit code is a conclusion, not a decoration.

Drain correctness does not depend on timing: the shutdown marker travels the
same FIFO as the data (`feed → book → risk`), so `main` waits on a barrier
instead of a sleep. `dropped_full` counts messages the *feed* could not enqueue;
the marker itself is sent with `sendBlocking` so it cannot be the one that is
dropped.

Runtime concepts and their contracts: [`docs/RUNTIME.md`](../../docs/RUNTIME.md).
The next stage of this pipeline lives in [`examples/alpha-engine`](../alpha-engine/).
