# alpha-engine (P0)

A **replay-driven trading pipeline** on the ZigModu runtime. One deterministic
input series in, one deterministic snapshot out — the shape of a real trading
stack, small enough to read in one sitting.

```
feed (thread)      OrderBook        Alpha          Risk           Execution ─▶ PaperExchange
fixed replay  ─▶   top of book  ─▶  mean rev  ─▶   limits    ─▶   adapter   ─▶ instant fills
(200 points)       mailbox 256      mailbox 256    mailbox 256    mailbox 256
```

## Run

```bash
cd examples/alpha-engine
zig build run
```

Output from a run (these numbers are deterministic — the feed is a fixed
triangle wave, there is no RNG and no wall-clock input):

```
info: [book] snapshot #1: bid=10004 ask=10006 mid=10005 prints=200
info: [snapshot] bids=133 asks=67 best_bid=10004 best_ask=10006 mid=10005 fills=95 pnl=-5165 timer_snapshots=1
info: [stats] workers=4 sent=692 received=692 dropped=0 timer_fires=1 timer_lag_max_ms=0
info: [book] mailbox cap=256 len=0 dropped_full=0 coalesced=0 | alpha signals=192 shed=0 | risk rejected=97
info: [done] every worker joined
```

`timer_lag_max_ms` is usually the only field that moves between runs (it
measures the ticker, not the strategy). `pnl` is `cash + position × last print`,
computed by `PaperExchange` — it is a report, not a backtest optimization target.

## Stages

| Stage | Owns | Hands off |
|-------|------|-----------|
| `OrderBook` | best bid/ask around the last print (half-spread 1) | `Quote` (top of book) to Alpha |
| `Alpha` | an 8-point mean of the mid | `Signal` — a *view*, unsized |
| `Risk` | position, `max_position = 24` | `Order` — sized, approved |
| `Execution` | the adapter boundary | `Order` → `PaperExchange`, which fills instantly at the quoted mid |

Each stage is a `rt.spawn`ed worker spawned by the `Pipeline` module in
`initWith` via `ctx.runtime()`, so `app.stop()` joins all four — that is why the
run ends with `[done] every worker joined`. There is no mutex in the file: the
mailbox is the only hand-off, and the workers own their fields outright.

Shutdown is a **drain barrier**, not a sleep: a shutdown marker travels the same
FIFO as the data (`feed → book → alpha → risk → execution`) and the flags `main`
waits on are published only when the tail stages have accounted for it — so
every point that was accepted has been processed by the whole chain before the
snapshot is read. `sendBlocking` keeps the marker from being the one message
that gets dropped when a mailbox is full.

## Scope (P0)

Deliberately **not** in this example yet: the `HotBus` audit/metrics fan-out, a
supervised faulty actor, and the per-stage module split. Those are P1–P3 of
[`docs/dev/alpha-engine-spec.md`](../../docs/dev/alpha-engine-spec.md); this is
the skeleton and it stays runnable on its own.

- Runtime concepts (mailboxes, backpressure, timers, supervision):
  [`docs/RUNTIME.md`](../../docs/RUNTIME.md)
- The fan-out + supervision companion example:
  [`examples/runtime-workers`](../runtime-workers/)
