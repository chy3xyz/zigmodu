# alpha-engine (P3)

A **replay-driven trading pipeline** on the ZigModu runtime, assembled from
modules, with an AI agent that **may propose and may not trade**. One
deterministic input series in, one snapshot out — the shape of a real trading
stack, small enough to read in one sitting.

```
market          book           alpha          risk           exec ─▶ PaperExchange
replay feed ─▶  top of book ─▶ mean rev   ─▶  limits      ─▶  adapter ─▶ instant fills
(thread)        mailbox 64     mailbox 256    mailbox 256    mailbox 256     │
                   │                                                          ▼
                   ├─▶ audit: HotBus(Delta) ─▶ audit (slow worker)   FaultyFillReporter
                   │     frozen             └─▶ metrics (O(1) sink)   (supervised actor)
                   │
                   └─▶ propose: DayEndSnapshot ─▶ ai.AgentWorker ─▶ guard(.propose) ─▶ risk
                                                     (canned,           │
                                                      offline)         └─ guard(.execute) ✗
                                                                            │
                                                          exec: desk worker ◀┘
                                                                └─▶ order ─▶ PaperExchange
```

## Run

```bash
cd examples/alpha-engine
zig build run
```

A run ends like this (counts vary between runs — the accepted prefix of the
series depends on scheduling; the six `[assert]` lines are the contract and must
all say `PASS`):

```
info: [exec] drained: routed=240 fills=240 last=10040 position=-3 pnl=24590 report_shed=207
info: [book] day-end snapshot #1: bid=10039 ask=10041 mid=10040 vwap=10050 prints=281
info: [propose] #1 buy 4 @ 10040: proposed, not permitted (risk=low)
info: [desk] authorized proposal #1: buy 4 @ 10040 (risk=low)
info: [propose] #2 buy 12 @ 10040: rejected by risk (score=120)
info: [snapshot] bids=191 asks=90 best_bid=10039 best_ask=10041 mid=10040 vwap=10050 fills=241 pnl=24590 timer_snapshots=1
info: [fanout] bus: subscribers=2 published=281 delivered=298 dropped=264 | sink deltas=281 | audit kept=17
info: [supervision] fill reporter: attempts=4 stopped_by_supervisor=true mailbox_closed=true | exec report_shed=208
info: [stats] workers=9 sent=1131 received=1102 dropped=2190 handler_errors=4 timer_fires=1 timer_lag_max_ms=0
info: [book] mailbox cap=64 len=0 dropped_full=1719 coalesced=0 | alpha signals=270 shed=0 | risk rejected=30
info: [agent] guard: allowed=2 denied_execute_class=1 denied_not_listed=0 denied_explicitly=0 denied_budget=0 | pipeline effect_reached=0
info: [propose] trigger fired=1 shed=0 | proposals=2 execute_not_permitted=1 risk_rejected=1 refused=0 | handed_to_desk=1 desk_shed=0
info: [desk] authorized=1 declined=0 shed=0 | exec authorized_fills=1 of 241 fills
info: [assert] bus.stats().dropped > 0: PASS (dropped=264)
info: [assert] book.stats().dropped_full > 0: PASS (dropped_full=1719)
info: [assert] faulty.stats().stopped_by_supervisor == true: PASS (attempts=4)
info: [assert] rt.stats().timer_fires > 0: PASS (timer_fires=1)
info: [assert] agent.guard.stats().denied_execute_class > 0: PASS (denied_execute_class=1, effect_reached=0)
info: [assert] proposals > 0 and authorized fills > 0: PASS (proposals=2, authorized_fills=1)
info: [done] every worker joined
```

Any `FAIL` exits the process with a non-zero status, so the example is its own
acceptance gate.

## How the pipeline is split

Seven modules under `src/modules/<name>/`, each declaring itself with
`zmodu.api.Module` — a name, a description and **dependencies by module name, not
by import path** — and each spawning its own workers in `initWith` through
`ctx.runtime()`, so `app.stop()` joins them and no caller has to remember to:

| module | depends on | owns | publishes |
|--------|-----------|------|-----------|
| `market` | `book` | the replay series and the feed thread | `MarketData` into the book, then the shutdown marker |
| `book` | `alpha`, `audit`, `propose` | top of book, the day's VWAP, the snapshot timer | `Quote` to alpha, `Delta` to the bus, `DayEndSnapshot` to the agent |
| `alpha` | `risk` | an 8-point mean of the mid | `Signal` — a *view*, unsized |
| `risk` | `exec` | position, `max_position = 24` | `Order` — sized, approved |
| `exec` | — | `PaperExchange`, the supervised fill reporter, **the desk** | `Fill` to the reporter; the desk turns a proposal into an order |
| `audit` | — | the `HotBus(Delta)` and its two subscribers | nothing — it consumes |
| `propose` | `exec` | the agent worker, its guard, its risk review, its counters | `ProposalEnvelope` to the desk — never an order |

**Nothing imports a neighbour.** A module is parameterised by the module it feeds
(`risk.Module(exec.Module)`, `propose.Module(exec.Module)`,
`book.Module(alpha.Module(risk…), audit.Module, propose.Module(exec))`), and
`main` instantiates that chain once, as the composition root: it builds the
application, runs the feed, waits on the two drain barriers and prints the
report. Wiring by type instead of by file is what makes the declared graph the
real one — initialization order follows `dependencies`, so each module finds its
downstream's handle already published on the type it was handed. The shapes two
modules exchange (the message types) live outside the module tree in
`src/contracts.zig`, the same way `examples/tenant-mgmt` shares
`src/business/enums.zig`.

Inside a module the usual layout applies:

| file | what it holds here |
|------|--------------------|
| `model.zig` | pure data and domain rules (`TopOfBook.mid()`, `Tape.vwap()`, `Position.wouldBreach()`, `Desk.approves()`, `PaperExchange.pnl()`) |
| `service.zig` | the workers: their state, their `handle`, their downstream inbox type as a comptime parameter |
| `api.zig` | the module's public surface — mailbox capacities, the supervision policy, and (in `propose`) the guard policy and risk rules |
| `module.zig` | `info` (name, description, dependencies), `initWith`, the published handle |
| `root.zig` | the barrel everything outside the module imports |
| `persistence.zig` | why this module has no store, or (in `propose`) what its one row is for |

## The six assertions

| assertion | what PASS means |
|-----------|-----------------|
| `bus.stats().dropped > 0` | a slow L0 subscriber was dropped, not waited on |
| `book.stats().dropped_full > 0` | the producer hit `error.Full` and shed — real backpressure |
| `faulty.stats().stopped_by_supervisor == true` | the error budget was spent and the actor was stopped |
| `rt.stats().timer_fires > 0` | the `book.after(200, snapshot)` timer really fired |
| `agent.guard.stats().denied_execute_class > 0` | the agent listed a propose action and was refused *execution* — `allow_execute = false` is the binding constraint |
| `proposals > 0` and `authorized fills > 0` | the loop closed: a proposal survived the gate, the desk authorized it, and the paper venue filled it |

**Fan-out (L0 events).** The book publishes every accepted print to the
`audit` module's bus, frozen before traffic, so publishing is a lock-free slice
walk with no allocation. Two subscribers ride it: the `audit` worker, slow *by
design*, and an O(1) `metrics` sink attached with `subscribeSink`. The slow one
cannot stall the book — its full mailbox becomes a counted drop, and the box is
sized to make that structural: 16 slots against the book's 64-slot intake, so one
drain burst already overflows it.

**Supervision.** Every fill is also forwarded to `FaultyFillReporter`, whose
upstream is always down. It is spawned with
`spawnActor(..., .{ .max_errors = 3, .window_ms = 60_000 })`, so the runtime stops
it on the 4th error and closes its mailbox instead of letting it log forever —
`exec report_shed` shows routing kept going.

**Backpressure.** The feed deliberately outruns the book: 2,000 points into a
64-slot mailbox. The queue is comptime-bounded: it can shed, it can never grow.

**Drain barrier, not a sleep.** A shutdown marker travels the same FIFO as the
data (`market -> book -> alpha -> risk -> exec`), and the latches `main` waits on
are armed only once the tail stages have accounted for it — so every point that
was accepted has been processed by the whole chain before the snapshot is read.
`sendBlocking` keeps the marker from being the one message a full mailbox eats.

## The agent that may propose and may not trade (P3)

The day-end snapshot is also what wakes the agent. The book sends
`DayEndSnapshot` (touch, the day's VWAP, print count) to the `propose` module
*before* it arms its latch, `propose.Trigger` turns it into a goal text, and an
`ai.AgentWorker` runs it — with its **executor injected**
(`ai.AgentWorker.executor`), so the run is a pure, offline, deterministic
function of the message. Nothing in this example talks to a model provider; the
seam is the executor, and a real deployment swaps exactly that one function.

What comes back is a draft with two legs (a sized mean-reversion leg and a
conviction leg), and every leg goes through `ai.ProposalPipeline`:

```
guard.check(.propose, "order.propose")   → allowed     (the allow list names it)
    risk.RiskReview (SQL rules, 30 / 120) → approve | reject
guard.check(.execute, "order.propose")   → DENIED      (allow_execute = false)
    verdict = execute_not_permitted, carrying the risk level
```

That third line is the whole point, and the report proves it stayed that way:
`guard.stats().denied_execute_class = 1`, and the pipeline's executor — the one
function an agent may not reach — was **never called**
(`pipeline effect_reached=0`). The gate is not a convention here; it is the only
path to that function, and it is closed.

The proposal then leaves the agent's world as an envelope of numbers plus the
verdict, addressed to `exec`'s **desk**: a worker on the far side of a mailbox,
with no handle to the agent, that decides for itself (`Desk.approves`) and builds
the `Order` from the envelope's contents. The agent never had a channel to the
exchange, and the desk is the only new door into the venue — which is what
"execution does not pass through the agent's hands" means in code.

Two endings are exercised on every run, so neither branch is a claim:

| leg | risk | gate | desk | result |
|-----|------|------|------|--------|
| 1 (sized, 1–4 contracts) | `low`, score 30 → approve | `execute_not_permitted` | authorizes | `authorized_fills = 1` |
| 2 (conviction, 9–12 contracts) | `high`, score 120 → reject | never reached | never sees it | no fill |

The second leg exists to keep "risk runs before execution" honest: 8 contracts or
more trips the whale rule, so the review rejects it before the execute check is
even reached — an agent that proposes too big is stopped by risk, not by luck.

Assertions, in the order they print:

- `agent.guard.stats().denied_execute_class > 0` — the agent tried to execute and
  was refused. `effect_reached=0` in the same line is the proof the refusal held.
- `proposals > 0 and authorized fills > 0` — the loop closed: `propose.proposals`
  counts what the gate saw, and `exec authorized_fills` counts only orders whose
  `origin` is `.authorized`, not the replay chain's (which is why the assertion is
  not on `exchange.fills` — that number is already large for reasons P3 did not
  contribute to).

Any failure returns `error.P3AssertionFailed` and the process exits non-zero.

To see a *different* policy outcome, flip `allow_execute` in
`src/modules/propose/api.zig`: with `true`, the same proposal reaches the
pipeline's executor, which returns `error.AgentMayNotExecute` — the experiment
shows up as `executor_failed`, `effect_reached=1`, and a failing assertion
instead of a quiet trade.

## Gates

```bash
zmodu doctor examples/alpha-engine   # module graph + cross-module imports
zmodu ci examples/alpha-engine       # build + fmt + verify + audit + deadcode + doctor
```

CI builds every example and runs `doctor` on this one, so a cycle or a
cross-module file import fails there too.

## Scope

- Runtime concepts (mailboxes, backpressure, timers, supervision, HotBus):
  [`docs/RUNTIME.md`](../../docs/RUNTIME.md)
- Agent authority, the two guard axes, and the proposal pipeline:
  [`docs/AGENT_RUNTIME.md`](../../docs/AGENT_RUNTIME.md)
- Module boundaries and the five-file layout:
  [`docs/MODULITH.md`](../../docs/MODULITH.md)
- The smaller fan-out + supervision companion example:
  [`examples/runtime-workers`](../runtime-workers/)
