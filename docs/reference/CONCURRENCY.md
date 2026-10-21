# Concurrency & Determinism Contract

zmodu provides two concurrency models designed for different state-ownership patterns:
1. **Single-owner `Worker` + `Mailbox`**: A dedicated or pooled worker owns its state exclusively and processes messages sequentially.
2. **Fiber fan-out (`std.Io.Group`)**: Multiple concurrent I/O tasks run within a single request without shared mutable state.

## 1. Model Selection Table

| Problem Shape | Use | Do Not Use | Key Constraint |
|---------------|-----|------------|----------------|
| Mutable state updated by sequential messages (order book, session state, counters) | `Worker` + `Mailbox(T, capacity)` | Shared struct guarded by `std.Io.Mutex` | Single owner; full mailbox returns `error.Full` for explicit backpressure |
| Fan out multiple independent I/O calls within one request and join results | `std.Io.Group` (fibers) | Spawning a `Worker` per request | Each task uses its own allocator/context; cancellation is cooperative |
| Blocking system calls, large file I/O, or synchronous C libraries | `.execution_class = .blocking` worker | Running blocking calls on the CPU worker pool or HTTP fiber | Isolates blocking waits on the dedicated blocking pool (`withBlockingThreads`) |
| Delayed or periodic work | `TimerWheel` / `PrecisionTimer` / `cron.Scheduler` | `sleep` loops inside worker handlers | `TimerWheel` delivers messages into the worker's mailbox |
| Lock-free 1-to-N hot-path broadcast | `runtime.HotBus(E, N)` | Shared mutable subscriber array with locks | Call `freeze()` at startup before the first `publish` |
| Cross-process event broadcast | `DistributedEventBus` / Raft | Ad-hoc raw TCP sockets | Configure `own_key`/`peer_keys` or `cluster_secret` |
| Parallel AI tool execution in a single turn | `Tool.parallel_safe = true` + `AgentSpec.io` | Unsynchronized shared DB connection in parallel tools | All tools in the turn must declare `parallel_safe`; results allocate from `ctx.allocator` |

## 2. Determinism Boundaries

The runtime replay subsystem (`runtime/recorder.zig` + `replay_driver.zig`) guarantees deterministic ordering **inside the execution plane**:

| Dimension | Deterministic? | Mechanism |
|-----------|----------------|-----------|
| Message delivery order | Yes | `Sequencer` assigns monotonic sequence numbers; `DeliveryLog` records per-track order |
| Timer arm / cancel order | Yes | Single-writer `TimerWheel` and FIFO command queue |
| Ready-ring scheduling order | Yes | Deterministic ring and batching rules in `Scheduler` |
| Clock readings | Yes (with manual clock) | Injectable `runtime/clock.zig` (`Clock.manual` in tests/replay) |
| External HTTP / DB / filesystem I/O | No | Network and disk I/O outside `DeliveryLog` are not captured automatically |
| Shared-memory mutation bypassing `Mailbox` | No | Governed by OS thread scheduling |

To include external I/O in deterministic replay (as shown in `examples/quant-replay`), record normalized domain events at the application boundary and feed the recorded `ZDL1` segment log back through `ReplayFromLog`.

## 3. Cooperative Cancellation

- `AgentHandle.requestCancel` and `Budget` check cancellation between steps; in-flight HTTP or LLM calls rely on their socket timeout.
- `Tool.timeout_ms` checks elapsed time on return; long-running custom tools should poll `try ctx.checkDeadline()` inside loops.
- `std.Io` cancellation takes effect only at suspension points.
