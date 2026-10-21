# zmodu Runtime

A bounded, replayable execution layer for Zig 0.17: one thread owns a worker's state, one mailbox owns handoff, and one timer wheel owns delay.

## 1. Why a second lane

`Application` / `Module` / `DI` / `EventBus` / HTTP stay as they are; they are architecture assets. The runtime adds a separate lane:

- `Application`: modules, DI, lifecycle, L1 bus, outbox, HTTP, ORM, Redis.
- `Runtime`: workers, mailboxes, ring buffers, wheel, pool, clock. Both share `io`, config and observability.

Use a worker only where state ownership pays for itself: WebSocket fan-out, market data and order books, game rooms, IoT aggregation, AI agent loops. CRUD services stay on `Application → Module → Service`.

## 2. Compatibility principles

```text
 1. Existing Module, Application, DI and EventBus APIs remain stable.
 2. New Runtime APIs are additive — no existing Runtime call silently changes
    meaning; a replacement is a deletion plus a documented migration.
 3. Hot-path, distributed and actor runtimes are opt-in.
 4. Existing applications that never touch `runtime` require no migration.
 5. Runtime API may break during 0.x — precedent: v0.28.0 removed
    `Runtime.cancelTimer(id) bool`. Application / Module / DI / EventBus / HTTP
    keep the backward-compatibility promise above.
```

- Compatibility is layered: `runtime.*` may break in 0.x (every break lands in `docs/reference/UPGRADING.md`), while `Application`, `Module`, `DI`, `EventBus` and HTTP only add APIs. `app.runtime()` returns `!*Runtime` and creates it on first call; never calling it means zero threads and zero timers.
- `Application.stop()` calls `runtime.shutdown()` (joins every worker) before stopping modules, because workers may still call module services. `Application.deinit()` releases the runtime.
- The runtime does not touch `Application.events`: `app.eventBus(T)` remains the L1 channel; L0 is separate (§6).

## 3. Workers: one struct, three declaration forms

```zig
const OrderBook = struct {
    pub const Message = Delta;            // the runtime owns recv/handle
    bids: std.ArrayList(Level) = .empty,
    asks: std.ArrayList(Level) = .empty,
    pub fn init(self: *@This(), ctx: anytype) !void { ... }     // optional, once
    pub fn handle(self: *@This(), msg: Delta, ctx: anytype) !void {
        // only this thread touches bids/asks — no lock because there is no sharing
    }
    pub fn deinit(self: *@This()) void { ... }                  // optional, last
};
```

| Declaration | How the runtime drives it | Use when |
|---|---|---|
| `pub const Message = T` + `pub fn handle(self, msg, ctx)` | Message-driven `recv → handle` loop; `stop()` / `close()` ends it | Most workers |
| `pub fn run(self, ctx)` | Own loop, `while (!ctx.stopped())` | Pull sources, precise cadence |
| `pub fn init` / `pub fn deinit` | Lifecycle hooks, once per generation (a rebuild is `deinit` + `init`, §14) | Opening resources |
| `pub fn onError(self, err, ctx) Supervision.Strategy` | Actor only: per-error `.restart` / `.stop` | Only some errors should stop |
| `Supervision{ .group = g }` | Member of a supervision group | Members live and die together |

```zig
const rt = try app.runtime();
const book = try rt.spawn(OrderBook, .{}, 256);   // 256 = mailbox capacity (comptime)
try book.send(.{ .bid = 101, .qty = 2 });         // full → error.Full
_ = try book.after(50, .{ .tick = true });        // post one message in 50 ms
book.stop();                                      // shutdown/join owns the join
```

- `ctx` is `WorkerContext(W, capacity)`, accepted as `anytype`. Keep capacity out of the worker: `pub fn BookModule(comptime capacity: usize) type` passes it through the module argument, the `spawn` call and `Handle(W, capacity)`. `BookModule(4096)` and `BookModule(64)` are two instantiations. `ctx.stopped()` is true after `stop()` or runtime shutdown; not starting the ticker is not a stop. `ctx.traceId()` is the current message's trace, `null` in `init` / `run` and for plain sends.
- `after` only posts a message; it never runs worker code on the ticker thread. The caller takes an id, computes the deadline with its own clock, and pushes an `arm` command into a bounded queue (no allocation); the ticker, or the thread calling `tick()`, drains commands and advances the wheel. Effective delay is `[delay_ms, delay_ms + enqueue delay + tick_interval_ms]` with a 5 ms tick, so `after(50)` means 50 ms from the call. A full queue returns `error.Full`.
- `requestCancelTimer(id)` is the hot path: the request is handed to the runtime and takes effect about one tick later. `cancelTimerSync(id)` waits for the owner and returns whether the timer was still pending. ARM and CANCEL share one FIFO, so both orders are deterministic.
- `shutdown()` releases every un-fired timer (queued arms and wheel nodes) and counts them in `stats().timers_discarded`; it is idempotent. Stop order is `alive = false` → stop ticker (broadcast + join) → request worker stop → join → destroy → clear queue → drain. A fired timer posts to the worker handle, so the ticker must stop before handles are destroyed.
- Errors from `handle` / `run` are counted in `stats().handler_errors` and do not stop the worker. Panics abort the process.

## 3b. Actors: workers with failure policy

```zig
const h = try rt.spawnActor(Reporter, .{}, 32, .{ .max_errors = 3, .window_ms = 60_000 });
```

| Configuration | Meaning |
|---|---|
| `strategy = .restart` (default) | Log the error and keep serving |
| `strategy = .stop` | Stop on the first error: close the mailbox, exit the thread |
| `max_errors` / `window_ms` | Error budget; exceeding it stops the actor. `0` = unlimited |
| `onError(self, err, ctx)` (optional) | Per-error decision, overrides `strategy` |

The fourth argument of `spawnActor` is `runtime.Supervision` (`strategy` / `max_errors` / `window_ms` / `group`). `max_errors` is not `supervisor.Intensity.max_restarts`: the first counts errors in one lifetime, the second counts rebuilds in a window. A stop closes the mailbox (`error.Closed` for producers) and sets `stats().stopped_by_supervisor`; rebuilds are in-place `deinit` + `init` in a supervision group (§14).

## 3c. HotBus: L0 fan-out

```zig
var bus = runtime.HotBus(Trade, 4).init();   // at most 4 subscribers
try bus.subscribe(book);                     // any *Handle(W, cap)
try bus.subscribeSink(metrics.sink());       // a plain sink is fine
try bus.attachRecorder(&rec);                // before freeze
bus.freeze();
if (!try bus.publish(trade)) { /* every subscriber was full */ }
```

1. Wire, then `freeze()`. After freeze, `publish` is a lock-free, allocation-free slice walk. Publishing before freeze returns `error.NotFrozen`; subscribing after freeze returns `error.Frozen`. Treat either as a wiring bug.
2. Drop, but stay bounded. Each subscriber has a bounded mailbox; a full one drops that event and increments `stats().dropped`. A slow subscriber cannot stall the publisher or grow memory. An attached recorder is tapped before fan-out and takes no subscriber slot; a full log returns `error.Full`.

## 3d. Using the runtime from a module

`Application` owns the runtime: it creates it on first use, runs the ticker, and joins on `stop()`. Modules borrow it through `ModuleContext.runtime()`.

```zig
pub const BookModule = struct {
    pub const info = zmodu.api.Module{ .name = "book", .description = "order book worker", .dependencies = &.{} };

    pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        const runtime = try ctx.runtime();          // the app's runtime, not a new one
        _ = try runtime.spawn(OrderBook, .{ .symbol = "BTC/USDT" }, 256);
    }
    pub fn deinit() void {}
};

var b = zmodu.builder(allocator, io);
defer b.deinit();
var app = try b.withName("trader").build(.{BookModule});
defer app.deinit();
try app.start();
defer app.stop();   // joins workers before stopping modules
```

Modules borrow; they do not create or destroy. `Runtime.init` inside a module leaves threads unjoined, and `rt.shutdown()` / `rt.deinit()` from a module interrupts other modules' workers. `app.stop()` joins workers before `Lifecycle.stopAll`; within the runtime the order is ticker first, then workers (§3).

- A manual-clock test that drives `tick()` should create its own runtime (`Runtime.init(alloc, io, .{ .manual = &clk })` with `defer rt.deinit()`). A bare harness without the runtime provider gets `error.RuntimeUnavailable` from `ctx.runtime()`.

## 4. Primitives

| Type | Concurrency | Key properties |
|---|---|---|
| `RingBuffer(T, N)` | 1 producer / 1 consumer | No CAS; `N` a power of two |
| `MpscRing(T, N)` | N producers / 1 consumer | Vyukov bounded queue; `N ≥ 2` at compile time |
| `Mailbox(T, N)` | N producers / 1 consumer | `send` returns `error.Full`, `sendBlocking` waits, `close()` wakes waiters |
| `Wheel(Payload)` | Ticker-owned | O(1) insert/cancel, 10 ms slots, 5 levels, ~124 days, zero locks |
| `ObjectPool(T)` | Multi-threaded | Fixed capacity, spin lock; `acquire` does not allocate, null when exhausted |
| `Clock` | Value type | `.monotonic` in production, `.manual` in tests |
| `Sequencer` | Multi-threaded | Lock-free `next()` / `nextBatch(n)` / `advanceTo()`; not a clock |
| `HotBus(E, N)` | 1 publisher / N subscribers | Lock-free after freeze, drop-on-full, counted (§3c) |
| `Recorder(E, C)` | N producers / single replay | Fixed append log; full returns `error.Full`; sequence equals slot |
| `Scheduler` (§12) | N producers / pool threads | Ready ring of worker tokens; capacity from the declared bound |

The wheel needs one writer, not thread safety. `claimOwner` / `assertOwner` panic on a second writer in Debug and ReleaseSafe and compile away in ReleaseFast. `Clock.Manual.advance` runs only on the test driver or ticker owner thread. The id index is an array hash map, not `AutoHashMapUnmanaged`: tombstones from a long-lived wheel fill the table (206 tombstones in 256 slots, 13.6× slower lookups) and do not recover; array deletion keeps occupancy ≤ 60% structurally. First `schedule` = 2 allocations; `cancel` / `advance` / `drainAll` = 0.

## 5. Backpressure

```text
producer ──send──▶ mailbox (bounded N) ──recv──▶ worker
   full → error.Full        empty → block (recv(0)) or timeout (recv(ms))
```

1. Queues never grow. Capacity is comptime; `error.Full` is the only exit, and the caller decides whether to drop, merge or back off.
2. Drops are visible, and each reason has its own counter:
   - `messages_dropped`: a producer was refused by a full mailbox; the message was never accepted.
   - `messages_discarded_on_stop`: a message was accepted, then abandoned because the worker stopped.
   - `timer_deliveries_dropped`: the timer fired, but the target mailbox refused the message (`error.Closed` or `error.Full`). The `error.Full` half also bumps `messages_dropped`; this counter separates "producer under backpressure" from "a fired timer did not land".
   - `timers_discarded`: an armed timer was released without firing at shutdown, complementing `timer_deliveries_dropped`.

3. Messages are values. `T` is copied into the queue; pass a pointer and state ownership explicitly for heap objects.
4. A full ready ring is not backpressure. A token is a worker's right to be scheduled, not a message; dropping one permanently retires a worker while its mailbox keeps accepting. The ring is sized from the declared pool bound, so true fullness is structurally impossible; `max_pooled_workers` is a hard limit. `push` waits (spin, yield, 1 ms retry) instead of dropping; past the soft budget it increments `ready_push_failures` (must stay 0) and dumps the ring once (§12.18).

## 6. Event layers

| Layer | Carrier | Semantics | Used for |
|---|---|---|---|
| L0 | `MpscRing` / `Mailbox` + worker | Bounded, allocation-free, single-threaded consumption | Market data, order books, ticks, room broadcast, internal commands |
| L1 | `app.eventBus(T)` | In-process, typed, subscribable | `UserCreated`, `OrderCreated`, domain events |

L0 and L1 are separate channels: do not put hot paths on L1 and do not put business events on L0 (no subscription model, no persistence). L2 (Kafka / NATS / outbox) is cross-process, at least once. "Allocation-free" is asserted: `src/runtime/alloc_contract_test.zig` pins the L0 producer paths (`Handle.send*`, `HotBus.publish`, `Mailbox.send*`, `RingBuffer`, `MpscRing`, `Sequencer.next`, `Runtime.scheduleAction`, `requestCancelTimer`) at zero allocations, and fixes exact counts for entries that do allocate (`Handle.after` = one payload, `Wheel.schedule` = one node).

## 7. When not to use the runtime

- CRUD, admin and ordinary APIs: modules and services are enough; a worker adds a layer.
- State read by several threads: use a frozen snapshot (`FrozenMap`) or move it into one worker. Cross-process ordering belongs to Kafka or NATS (L2).

## 8. Observability

```zig
const s = rt.stats();
// workers / running / messages_sent / messages_received
// messages_dropped / messages_discarded_on_stop / handler_errors
// timer_fires / timers_discarded / timer_deliveries_dropped / timer_lag_max_ms (worst lateness)
```

`messages_discarded_on_stop` is not an alias of `messages_dropped`. A dedicated supervised stop breaks the loop and counts the mailbox tail; pooled shutdown stops the pool first, then counts the tail after all joins and before destroy. The counter is incremental and stays readable after `shutdown()`.

Connect the bridge once at startup; samples are taken at scrape time, with no background thread:

```zig
var bridge = try zmodu.runtime.Runtime.MetricsBridge(PrometheusMetrics).init(&rt, metrics);
metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);
```

It registers 37 `zigmodu_runtime_*` gauges: 13 general, 15 pool (6 main + 3 ready-depth bands + 6 fairness), and 9 blocking-pool (`blocking_` prefix, main 6 + bands 3). They are gauges because they are scrape-time snapshots; a runtime without a pool reports 0 rather than omitting series.

| Gauge | Meaning | Reading |
|---|---|---|
| `pool_declared` | Declared `max_pooled_workers` | `0` = no pool at all |
| `pool_threads` | Pool threads running; after start, the declared width | Ceiling for `pool_claimed` |
| `pool_ready_len` | Tokens waiting in the ready ring | At most one token per worker |
| `pool_claimed` | Workers executing right now | `running` no longer answers this after pooling |
| `pool_dispatches` | Batches run by pool threads | `.pooled` spawns with 0 means they never reached a pool thread |
| `pool_ready_push_failures` | Pushes that waited past the whole soft budget | Must stay 0 (§12.18) |

`zmodu runtime [dir]` reports the static half (declared workers, capacities, primitives, timer sites, clock) with `file:line`; see [`ZMODU_CLI_INTEGRATION.md`](../guide/ZMODU_CLI_INTEGRATION.md).

### 8.1 Worker trace context

`messages_dropped` counts losses but does not say whose. `sendTraced` attaches the originating trace id to one message.

```zig
try worker.sendTraced(.{ .user_id = id }, trace);       // non-blocking; full → error.Full
try worker.sendBlockingTraced(msg, trace, 500);         // wait up to 500 ms
pub fn handle(self: *Self, msg: Msg, ctx: anytype) anyerror!void {
    if (ctx.traceId()) |t| std.log.info("user {d} trace={x:016}{x:016}", .{ msg.user_id, t.high, t.low });
}
```

Trace is per message, carried in the mailbox slot; two concurrent `sendTraced` calls do not overwrite each other. A 16-byte value copy keeps the path allocation-free. Plain `send` / `sendBlocking` and the `init` / `run` phases give `null`; `Handle.after` inside a handler carries the current message's trace. `handler error` and `stopped by supervisor` log lines include `trace=<hex>`. An HTTP trace is a string (`"{x:016}-{x:016}"`); split on `-`, parse both halves as hex, and fall back to `TraceId.generate()` on failure.

## 10. Minimal example

`examples/runtime-workers/` runs feed → order book worker → risk worker → snapshot timer. It shows workers, mailboxes, timers, backpressure (`error.Full` with a merge policy) and graceful shutdown.

## 11. EventRecorder: publish-stream recording

`Recorder(E, C)` records the L0 publish stream before fan-out and replays it on a manual clock without sleeping. Delivery-stream recording is a separate mechanism (§13).

### 11.6 Implemented shape

```zig
var rec = runtime.Recorder(Trade, 4096).init(clock); // same clock as Runtime.init
try bus.attachRecorder(&rec);                        // before bus.freeze()
bus.freeze();
if (rec.hasOverflowed()) { /* incomplete log: discard it, do not replay */ }
var manual = runtime.Clock.Manual{ .now_ms = 0 };
rec.replay(&manual, &harness, Harness.sink);         // advances the clock by seq, no sleep
```

Record point: `HotBus.publish`, before the sink loop. It is the fan-out itself, so it takes no subscriber slot and cannot fall into the `dropped` branch; a bus without a recorder pays one optional-pointer check. Overflow: a full ring returns `error.Full`; entries are never overwritten. `entries()` is always a complete prefix in ascending `seq`. `publish` increments `stats().record_dropped` and returns `false`; `hasOverflowed()` stays true.

- Storage and order: the `Sequencer` value is the slot index. One `fetchAdd` reserves order and space, so concurrent producers do not collide; per-slot `ready` flags plus a `published` prefix make `entries()` lock-free. Scope: one event type `E`, value semantics, no codec. Heterogeneous delivery tracks are §13; domain event sourcing is `core/EventStore.zig`. Only code reading the injected `Clock` participates; `spawn` / `init` side effects, network, wall clock and drop patterns are not replayed.

## 12. Scheduler and pools

`spawn(..., .{ .mode = .pooled })` runs message-driven workers on a pool. Defaults stay: no declaration means no pool, and `spawn` remains dedicated (worker → its own thread). Scheduled mode is sender → ready ring → pool thread → `handle`, for the long tail.

Pooling preserves these invariants:

1. State exclusivity: at most one thread runs a worker at any instant. Ownership moves from thread identity to a `claimed` bit.
2. Per-worker FIFO: mailbox order is unchanged; the pool only decides when a worker runs.
3. Pool threads never block: no `recv(0)`, no sleep, no lock wait, and an unclaimable token must not make N−1 threads spin.
4. Hot-path allocation stays zero (ring and thread array are allocated at init), and the wheel stays ticker-only; timer delivery still goes through `handle.send`.

```text
sender                        pool thread
  send(msg)                    loop:
    ├─ mailbox.send(msg)          ├─ ready.pop() → handle
    └─ ready.push(handle)         ├─ claimed.testAndSet(handle); skip on failure
                                  ├─ drain the mailbox (up to batch)
                                  └─ clear claimed; re-push if non-empty
```

- `.pooled` accepts only `pub const Message` + `handle`. A `run(self, ctx)` worker is a compile error: it would hold a pool thread forever. Measured handoff is ~17/128/190 ns (no second thread, dedicated, pooled), so keep latency chains dedicated.
- `batch` (default 16) amortizes ring round-trips and is the fairness bound: FIFO plus one token per worker means the worst wait is one batch.

Decisions: `.mode = .pooled` is the only entry (no `spawnPooled`); the runtime owns the pool and creates no threads without a declaration; `queued` (waiting) and `claimed` (running) are separate bits; release the claim after a batch only after re-checking the mailbox and winning the `queued` bit again, or a wakeup is lost. Out of scope: CPU affinity/NUMA (`.affinity` is not offered; `runtime.pinCurrentThread` returns `error.Unsupported` where the platform cannot comply), remote workers, and priority weights (three fixed classes exist in §12.17).

### 12.6 Interaction with existing parts

`Mailbox`, `Wheel` and `Recorder` keep their contracts; pooling changes who runs `handle`, not what the calls mean.

### 12.10 Pool lifecycle and stop semantics

```zig
var rt = try Runtime.initWithOptions(allocator, io, .{
    .scheduler = .{ .max_pooled_workers = 64 },   // no declaration = no pool
});
const audit = try rt.spawn(AuditWorker, .{}, .{ .capacity = 64, .mode = .pooled });
var app = try b.withName("app").withMaxPooledWorkers(64).build(.{MyModule});
```

- Ring capacity is `ceilPowerOfTwo(max_pooled_workers + pool_threads)`, minimum 2, computed at `Scheduler.init`; it must cover every pooled worker plus each consumer's dequeue window. The `max_pooled_workers + 1`-th `.pooled` spawn is rejected at startup with `error.PoolCapacityExceeded`.

| Item | `.dedicated` | `.pooled` |
|---|---|---|
| `init` hook | Right after `spawn`, on the worker thread | In the first message's batch, inside the claim; never if no message arrives |
| `deinit` hook | After the loop | Before destroy in `shutdown()`; runs after a failed `init`, skipped if `init` never ran |
| Supervised stop | Breaks the loop; the tail is counted in `discarded_on_stop` | Drains the mailbox, then stops scheduling it |

Supervised stop semantics differ: dedicated abandons the tail (counted), pooled drains it. Both feed `messages_discarded_on_stop`, with `sent == received + dropped_full + discarded_on_stop` asserted. `join()` on a pooled worker waits for the claim to be returned (spin 1024 rounds, then poll every 1 ms). `RuntimeStats.running` keeps per-worker meaning, bounded by the declared pool width. Stop order: `alive = false` → stop ticker → stop and join pool threads → assert no worker holds a claim → request/join/destroy workers → release timers; `shutdown()` swaps `started` to 0, so concurrent callers never join the same handle twice.

### 12.12 N pool threads

- `ReadyRing.tryPop` is multi-consumer safe: the index is claimed with `cmpxchgWeak`; the loser re-reads and returns null if it is not its turn. A load-then-store dequeue could hand one token to two consumers or lose it permanently.
- Threads are a `[]std.Thread` allocated once in `Scheduler.init`; `start()` is all-or-nothing; `shutdown()` swaps `started` to 0 and joins that many.
- Width comes from `SchedulerConfig.pool_threads` (default 1), `Application.Config.pool_threads`, `withPoolThreads(N)`, or `Runtime.InitOptions.scheduler.pool_threads`. Width 0 is clamped to 1 and enters the ring capacity formula.
- A claim miss re-pushes the token and backs off; park waits until the ring looks the same as last time (`pushes` unchanged), not until `len() == 0`, because a claimed token stays in the ring. The holder does not wake parked threads, so a stolen token can wait up to `idle_wait_ms` (1 ms). `claim_misses` is 0 at width 1 and may be non-zero above it; `ready_push_failures` must stay 0.

### 12.13 Stop policy and execution class

| Declaration | `.dedicated` | `.pooled` |
|---|---|---|
| Omitted | `.immediate` (historical) | `.drain` (historical) |
| `.stop_policy = .immediate` | Break on supervised stop; tail counted | Stop the batch and `countAbandoned` |
| `.stop_policy = .drain` | Drain after stop | Drain after stop |

Omitted behavior must reproduce both historical defaults. `.immediate` applies to supervised stops; `Handle.stop()` drains in both modes and both policies. `.blocking` workers run on a separate blocking pool (`blocking_threads`, `max_blocking_workers`), so a handler waiting on a database cannot starve the CPU pool.

Declaration, not detection: declare `.blocking` for DB round-trips, blocking HTTP, file IO and third-party locks, and size `blocking_threads` from downstream concurrency, not cores. The two bounds are independent admissions; the total ceiling is their sum, and `max_blocking_workers = 0` means the CPU-pool count. Wire with `.scheduler = …` or `b.withMaxPooledWorkers(4).withBlockingThreads(2, 7)`; without a declaration, `.blocking` spawn is rejected. The blocking pool publishes the same 9 gauges under `zigmodu_runtime_blocking_pool_*`, reports 0 when undeclared, and is read through `blockingPoolStats()`. `.blocking` + `.dedicated` is a compile error.

### 12.14 WebSocket route auth declarations are enforced

WebSocket upgrades are answered before `router.match` and before global middleware, so `auth` / `permission` / `roles` on `ws_routes` have no execution point.

| Declaration | Result |
|---|---|
| No `.meta.auth` | Compile error |
| Auth other than `.public` | Compile error |
| `permission` / `roles` | Compile error |

A runtime rejection would leave the misleading declaration in the source. Identity for a WebSocket belongs to the application's `on_connect`; the scaffolded IM gateway defaults `ImGateway.verifier` to null and refuses connections without a verifier. HTTP handlers read identity from JWT attributes (`ctx.requireUserIdInt(T)`), never from the query string. `Testkit.auditAuthCoverage` asserts `.auth == .public` instead of skipping WebSocket routes.

### 12.15 `PrecisionTimer` bounds belong to the host

`PrecisionTimer.lateness_p50_bound_ns = 10 µs` is not a mechanism guarantee. The wait loop sleeps `remaining - spin_window_ns`, so it can close the deadline only if the host wake-up lands inside the window. On the dev machine `nanosleep(100 µs)` overshoots by ~55 µs; on GitHub `macos-latest` the same call overshoots by +818 µs and the default 1 ms configuration shows p50 3 531 000 ns.

Assert the absolute bound only when `hostCanHoldTheBound` (a runtime probe using factory knobs) says the host can hold it; otherwise assert the portable property (factory knobs are no worse than handing the whole wait to the kernel) and print the probe plus the sleep-only row. The 100 µs case is pure spin, so it can assert the bound everywhere. On a coarse host, increase `spin_window_ns` (or set it to 0) rather than relaxing the bound.

### 12.16 Fairness and batch

With one pool thread and three workers — A continuously fed, B and C receiving one message at a time — a probe waits while A runs at most one batch. Across 10 runs and 60 000 probes the maximum was exactly 16 with `batch = 16`, while A handled about 96 000 messages. The bound is measured in messages, not microseconds, so it holds on shared CI hosts.

A sweep over `batch` = 1, 4, 8, 16, 32, 64 across saturated, mixed-busy and mixed-x2 shapes found 8 and above on one plateau within 1.2–2.4× run-to-run noise. `batch = 1` is the only default the data rejects: `mixed-busy` p50 146 µs and 46% of the throughput of 16. Keep 16; use 1 only for a pooled worker that truly cannot wait. The p99 tail comes from the 1 ms park (`idle_wait_ms`), not from `batch`; `batch` is the fairness bound itself, and setting it to 65 536 made a probe wait 53 118 messages.

### 12.17 Priorities

`SpawnConfig.priority` is `.high` / `.normal` / `.low`, default `.normal`, and is only valid for `.pooled` (a `.dedicated` declaration is a compile error).

- The ready ring becomes three rings, one per class, each satisfying the same capacity invariant. Normal turns run `high → normal → low`; every 8th turn (`turns % 8 == 7`) is a reservation turn in reverse order. Within a class, FIFO and one token per worker are unchanged.
- Cross-class starvation bound is one reservation period: at most 8 turns × `batch` messages (128 by default). `high` is never delayed across classes; a claim-miss re-push returns to its own class. `ready_len` is the sum of the three rings; `ready_len_by_class` and `zigmodu_runtime_pool_ready_len_{high,normal,low}` expose the split. No pool reports 0, not a missing series; class shares depend on host thread scheduling and are not asserted.

### 12.18 `push` never gives up

A slot holder can be descheduled for longer than any static retry budget (1M spins + 4096 yields, about 100 ms under light load), so a spent budget does not mean the ring is full; dropping the token would permanently retire a worker. The contract is: keep the spin/yield budget as a soft budget; past it, count one `ready_push_failures` per call (the reading still must be 0), dump the ring once (`ring_dumped`), then sleep 1 ms and retry until a slot appears or shutdown returns. Waiting is always correct because the capacity invariant makes true fullness impossible. Regression test: `scheduler: a push outlives a window held past its whole retry budget` expects the push to land with the count exactly 1.

## 13. Runtime replay

`Recorder` (§11) records the L0 publish stream. This section records the delivery stream: what each worker actually received. Deterministic mode (§15) reproduces whole orchestrated executions from a seed rather than from a log.

| Mechanism | Record point / shape | Question answered |
|---|---|---|
| §11 `Recorder(E)` | `HotBus.publish`, before fan-out | What did producers publish? |
| Delivery track (this section) | `Handle.send*` funnel | What did each worker receive? |
| §15 deterministic mode | `.deterministic = .{ .seed = … }` | Is the whole execution reproducible from input + seed + topology? |
| `http.Testkit.dispatch` | In-process handler call, no socket | Is handler behavior correct (routing, auth, JSON)? |
| L1 `app.eventBus(T)` / outbox | In-process typed bus; outbox for cross-process | Business events, exactly once |

Delivery must be recorded at the `Handle` funnel, not at `publish`: timer delivery never goes through `publish` (`after` → `TimerCommand` → ticker → `Delivery.post` → `handle.send`). A publish-only log cannot replay the timer-driven half; recording before fan-out misses a full subscriber's drop.

Recording is per worker and same-typed. Give each worker its own track and let one shared `Sequencer` stamp a global seq; merged `seq` order is replay order:

```text
worker A → Recorder(A.Message, capA) ─┐
worker B → Recorder(B.Message, capB) ─┼─ one Sequencer → replay merges by seq
worker C → Recorder(C.Message, capC) ─┘
```

Same type inside each track means value semantics, no allocation and no codec. Memory is `Σ(capacity × sizeof(Message))`, bounded and explicitly declared. There is no record-everything default: undeclared workers have no track, and their deliveries do not exist in replay. Entries carry a caller-supplied stable id (e.g. `"book:BTC"`), not `*Handle`; replay receives an id-to-handle map and does not guess by spawn order. Only successful deliveries are replayed; `spawn` / `init` side effects, network, wall clock and drop patterns are not.

The ZDL1 format is public (`src/runtime/delivery_log.zig`: magic `0x314C445A`, little-endian, CRC per frame); a canonical business event schema is out of scope.

### 13.4 Acceptance goal

Given the same worker graph and a recorded delivery track, replay produces the same handler call sequence (same order, same payload fingerprint) without sleeping.

### 13.7 Delivery tracks, implemented

```zig
// One track per worker, with an explicit memory bound.
const book = try rt.spawn(Book, .{}, .{
    .capacity = 256,
    .record = .{ .id = "book:BTC", .capacity = 4096 },
});
// … run: send*, HotBus deliveries and timer deliveries all land in this track …
const log = rt.deliveryLog() orelse return;          // no worker declared a track
var manual = runtime.Clock.Manual{ .now_ms = 0 };    // must be non-negative
var rp = log.replayer(&manual);
try rp.bind("book:BTC", fresh_book);                 // target must not be in this log
while (try rp.step()) |step| {                       // one step; rp.replayAll() loops to the end
    // step already delivered to fresh_book; assert or record here
}
```

- Record point: `Handle.enqueue` / `enqueueBlocking`. Both `send*` and timer delivery pass through it; recording after the mailbox accepts stores only successful deliveries (`error.Full` / `error.Closed` produce no entry). Zero allocation holds: `Handle.track` is `?*TrackRef`, and the allocation contract test for `Handle.send*` still asserts 0.
- Overflow: a full `Track` returns `error.Full` and never overwrites. `send*` still succeeds because the message did reach the mailbox: `DeliveryLog.refused` increments and a warning is logged. A replay of a log with holes returns `error.LogIncomplete` for both `step()` and `replayAll()`.
- `bind` rejects a target that is itself in the source log (`error.TargetIsInSourceLog`): replay deliveries would be recorded again, feeding the next step forever. Timing is not replayed: `after` messages are in the track, but there is no ticker and no sleep. Only code reading `ctx.clock()` participates; direct `core/Time.zig` reads see real time. Refusal counts live on `DeliveryLog.refusedCount()` and `error.LogIncomplete`, not in `RuntimeStats` / `MetricsBridge`.

### 13.8 Narrowing the in-memory replayer

```zig
var rp = log.replayer(&manual);
rp.open(100_000, 120_000);       // [from, to): from inclusive, to exclusive
try rp.onlyTracks(&.{"book"});      // deliver these tracks only
try rp.bind("book", book_handle);
_ = try rp.replayAll();
_ = rp.skipped();                   // total skipped
```

- Window `[from, to)`; `from >= to` is an empty window, not an error. Entries before `from` count in `skippedBefore`; entries at or after `to` are not visited and not counted. Filtered-out tracks advance the cursor and count in `skippedUnselected`. An empty `onlyTracks(&.{})` selects nothing; use `clearTrackFilter()` to return to all. Selected tracks still require bindings (`error.UnboundTrack`); unknown ids are `error.UnknownTrack`.
- Identity: `log.len() == delivered + skipped() + (entries with seq >= to)`; with `to == null`, `delivered + skipped()`. `Replayer` holds no allocator; `remaining()` is O(total entries) with the same value.

### 13.9 Codec contract and `drainTo`

`src/runtime/delivery_log.zig` is the storage layer: segments, magic, version, per-frame CRC, torn-tail detection and repair, zero-allocation append. `drainTo` connects live tracks to bytes.

```zig
/// A track declares how to turn its value into bytes. `E` is the track's Message.
pub fn Codec(comptime E: type) type {
    return struct {
        pub const name: []const u8;      // stable id, written to TrackRef.payload_codec
        pub const version: u16 = 1;      // caller's payload version
        pub fn encode(allocator: std.mem.Allocator, value: E) ![]u8;  // caller frees
        pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !E;
    };
}
```

- D1: the codec runs in `drainTo`, not in `record`. `record` stays zero-allocation and value-semantic; overflow between drains becomes a hole on disk. D2: the contract is a caller-provided type, not a format, and the framework never reads the payload.
- D3: holes are visible. `DrainReport` carries `records`, `holes` and `first_hole_seq` (null when none). Writing what exists is correct; calling it complete is not.
- D4: the drain cursor is per track and monotonic (`drained_slots`, `drained_upto`). `drainTo` may allocate but must free everything, and `record` allocates nothing.
- Kinds are recorded per entry (`send*` → `.message`, timer → `.timer`); `Entry` grows by 0 bytes for `E = u32` and 8 bytes for `E = u64`.

A track without a codec cannot be drained: `drainTo` names the track in `error.CodecRequired` and writes nothing (`drainRefusal()` reports it). `Writer.append` rejecting a non-increasing `seq` becomes a counted hole and the cursor crosses it. A track with a codec still replays in memory: `bind` accepts it, because the codec only runs in `drainTo`. `BindError` is `UnknownTrack` / `MessageTypeMismatch` / `TargetIsInSourceLog`; the disk reader keeps `LoadError.CodecRequired`.

### 13.10 Reading back from disk

`ReplayFromLog` is a separate type; `Replayer` signatures and behavior are unchanged.

- A new type shares the contract, not the implementation: same id-to-handle binding, same post-by-value thunk, same visible-holes rule. The reconciliation key is `track_id` only; callers needing more put the version in `track_id`. Holes are refused by default with `error.LogHasHoles` and are not consumed; `allowHoles()` continues, and `crossedHoles()` counts exactly what was crossed. Delivery order is global `seq`, not segment order: records are read into memory first, and an active log is not followed.
- Decoded values are posted by value into the mailbox, so a stack temporary is safe. `ReplayFromLog` holds an allocator (deliberately unlike `Replayer`); `Codec.decode` allocates and every step frees its buffer. Narrowing mirrors `Replayer`: `open(from, to?)`, `seekTo`, `onlyTracks` / `clearTrackFilter`, `skipped*`. Filtered records still anchor the seq chain, so filtering cannot invent holes; a hole spanning the window edge is refused with `refusalSeq()`. `remaining()` is exact, including duplicates. Replay from disk is load-then-replay: an active log is never followed, and CLI, retention, compression and cross-process transport remain out of scope.

```zig
var scanned = try runtime.delivery_log.scan(allocator, io, .{ .dir_path = dir });
defer scanned.deinit(allocator);
var loader = try recorder.ReplayFromLog.init(allocator, &manual, scanned.records);
defer loader.deinit();
try loader.setCodec("book:BTC", BookCodec, BookMsg);
try loader.bindDecoded("book:BTC", fresh_book);
```

`ReplayFromLog` refuses by name: `UnknownTrack`, `CodecRequired`, `UnboundTrack`, `MessageTypeMismatch`, `CodecNameMismatch`; `refusal()` reports the id.

### 13.14 `replay-inspect`

`src/replay_inspect.zig` installs as `zig-out/bin/replay-inspect`. It is read-only: answer what the log contains, whether it is replayable and where to start before starting a runtime.

```bash
zig build replay-inspect -- <dir> [--from N] [--to N] [--limit N] [--track NAME]...
zig-out/bin/replay-inspect <dir> …        # installed binary, skips the build graph
```

The report comes from `delivery_log.scan`'s verified prefix: segment count, records, `seq` range, per-track counts, kind distribution, holes (`after` / `before` / missing count), non-increasing records, and the stop reason `none` / `torn` (with byte count; `repair` can truncate) / `corrupt` (segment, offset, reason; `repair` refuses).

- `--from` inclusive and `--to` exclusive, same as §13.8; `from >= to` is an empty window. Windows select rows only; holes and damage cover the whole log.
- `--track NAME` (repeatable, union) and `--limit N` narrow the listing only; unknown names are rejected (`UnknownTrack`, exit 1).
- Exit codes: `0` clean, `1` usage/IO, `2` torn tail, `3` corrupt record. The file is a standalone root module with tests in the default suite via `src/tests.zig`.

## 14. Supervision trees

`Supervision{ strategy, max_errors, window_ms }` lets one actor count its own errors and stop, but a stop is terminal and invisible outside per-worker stats. A user actor cannot be the parent: its mailbox is typed by its own `Message`, and the runtime cannot synthesize a variant of a user enum. The group coordinator is the runtime itself, which runs no user code.

### 14.3 Groups, policies, intensity

```zig
const book_group = try rt.spawnGroupWith(.one_for_all, .{ .max_restarts = 3, .window_ms = 60_000 });
const feed = try rt.spawnActor(Feed, .{}, 64, .{ .group = book_group });
const book = try rt.spawnActor(Book, .{}, 64, .{ .group = book_group });
```

| Policy | After a member's failure, once its own layer decided to stop |
|---|---|
| `.one_for_one` | Rebuild that member only |
| `.one_for_all` | Rebuild every member of the group |
| `.rest_for_one` | Rebuild it and every member spawned after it |
| `.stop_group` | Stop every member; no rebuild |

`Intensity{ max_restarts, window_ms }`, default `{ 3, 60_000 }`: a group may trigger `max_restarts` rebuild actions per window, then degrades to `.stop_group` with a warning and a count. `max_restarts` counts rebuilds; `max_errors` counts errors in one lifetime.

### 14.4 One thread still owns the state

```text
member thread: W.handle returns error
      ↓
supervise(): account the error
      ↓
does this layer stop? (strategy == .stop or max_errors exceeded)
      ├─ no  → log and keep serving
      └─ yes → no group → stop self
                group, budget → apply policy (14.3 table)
                group, exhausted → stop the group + warn + count
      ↓
"rebuild me"   = deinit(state) → startWorker() → clear the error window → keep looping
"rebuild them" = set restart_requested on their handle; their own thread rebuilds
```

- Rebuild is in place: `deinit` then `init` on the same thread and loop. The thread, handle and mailbox survive, so a `*Handle(W, cap)` stays valid across rebuilds. The rebuild replaces `state`, not the queue; queued messages are handled by the next generation. `run`-owned workers cannot be restarted from outside; placing one in a rebuilding group fails at spawn with `error.NotRestartable`, while `.stop_group` accepts them because it never rebuilds.
- A pooled member checks `restart_requested` at its next claim; if its mailbox is empty, `Ready.pending` reports the pending flag as "has work" so the pool claims it and reads it. `stop_requested` wakes a receiver by closing the mailbox, while restart uses `Mailbox.wake()` (increment `wake_epoch`, broadcast `not_empty`, return null to re-read the flag). A member must read the epoch before the flag, or a wake between the two is lost. Requests are idempotent; `stop` wins over `restart`, and a completed rebuild must clear the flag or every later claim rebuilds again. Panics abort the process.

`supervised_stops` and `group_restarts` are runtime accumulators with gauges `zigmodu_runtime_supervised_stops` / `zigmodu_runtime_group_restarts`; both stay readable after `shutdown()`, which joins and destroys members in the same pass. Cross-process supervision, snapshot restore, restart backoff, per-member policies and panic supervision are out of scope; use systemd or k8s for process liveness.

### 14.5 Nested groups

`spawnGroup` builds a group; `nestGroup(parent, child)` makes the child's subtree a member of the parent.

Actions recurse through group members. When a child group exhausts its intensity, it escalates to its parent, which applies its own policy to the subtree and resets the child's budget on rebuild. `.stop_group` does not escalate: a declared "all die together" is an answer, not an accident. Only `parent → child` edges exist; escalation releases the child lock before taking the parent lock, so nesting cannot deadlock.

## 15. Deterministic mode

Deterministic mode makes the whole execution reproducible: same input + same seed + same topology ⇒ same event sequence. It is a configured execution mode, not a second runtime; default production behavior is unchanged. Design and grading (D/S/P, six invariants) live in [`dev/deterministic-runtime-design.md`](../dev/deterministic-runtime-design.md); this page records the usage contract. The core has no RNG seed; randomness lives in the cluster layer. Determinism comes from an injectable clock, a monotonic `Sequencer`, and one source of delivery order; cross-thread interleaving, claim order with `pool_threads > 1`, and wall time break it.

```zig
var rt = try Runtime.initWithOptions(allocator, io, .{
    .clock = .{ .manual = &clk },               // time is a controlled source
    .scheduler = .{ .max_pooled_workers = 8 },  // pool_threads must be 1 (the default)
    .deterministic = .{ .seed = 42 },           // opt in
});
const r = rt.rng();                              // the only random entry (not a CSPRNG)
```

Violations return `error.DeterministicViolation`:

- `scheduler.pool_threads` must be 1; a second ready-ring consumer is a second interleaving. `blocking_threads` must be 0; a blocking pool is a second scheduling domain. `spawn` rejects `.dedicated` (its own thread is invisible to the total order) and `.execution_class = .blocking`, before pool lookup. `scheduler.batch` is forced to 1, the most conservative total order for cascades.

Timers with the same deadline fire FIFO (arm order), not LIFO, in every mode: it matches the arrival order of arm commands and is causal rather than inverted. Mailbox behavior is unchanged (`error.Full` bubbles up); HotBus drop-on-full is covered by the single-threaded subscriber constraint.

`rng()` is seeded from the configuration in deterministic mode and from system entropy otherwise; it is single-threaded and not a CSPRNG, so do not derive keys or tokens from it. `check-production.sh`'s `dettime` scan keeps runtime production code from reading `core/Time.zig` directly, exempting the Clock real branch, `PrecisionTimer` itself and test helpers.

Process-level determinism (P level) is explicitly not done; `examples/quant-replay` is the end-to-end demonstration.

### 15.1 Replay driver

`runtime/replay_driver.zig` opens a recorded delivery log back into a deterministic runtime, driving clock, messages, timers and cascades through controlled paths.

```zig
var scanned = try runtime.delivery_log.scan(allocator, io, .{ .dir_path = dir });
defer scanned.deinit(allocator);
var loader = try recorder.ReplayFromLog.init(allocator, &clk, scanned.records);
defer loader.deinit();
var driver = try replay.Driver.init(&rt, io, &loader);  // switches to reproduce mode
const report = try driver.runToEnd();   // or runUntilSeq(N) / runUntilClock(t)
```

`init` fails fast: no deterministic mode → `error.NotDeterministic`; no pool (`max_pooled_workers` = 0) → `error.NoPool`; ticker already running → `error.TickerRunning` (two time sources cannot coexist). Each iteration moves the manual clock to the record time and delivers `.message` records, calls `rt.tick()` to drain the command ring and fire due timers, then `settle()` waits for the first increase of `poolStats().idle_waits` (the driver is the only external producer, so the first park means the cascade is quiescent). A counter budget of 300 000 iterations × 200 µs guards against a wedge without reading a clock. `.timer` records are reproduced, not re-delivered: the replay runtime's timer wheel fires them at the same clock points. Records still advance the clock, anchor the seq chain and count; `isFullyBound` skips `.timer`, so a timer-only track needs no binding. Record only input-boundary workers: cascaded messages and timers are deterministic functions of the input, and recording them again would double-deliver. `.timer` records are evidence, not input.
