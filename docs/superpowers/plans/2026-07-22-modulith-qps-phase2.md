# Phase 2 — Async EventBus + Worker Pools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the event system so modules can process events asynchronously on dedicated worker pools, replacing long synchronous cross-module call chains with fire-and-forget domain events.

**Architecture:** Add a generic `WorkerPool` to `core/` that executes `std.Io` tasks with a fixed number of workers and a bounded input queue. Extend `TypedEventBus` with `subscribeAsync` so subscribers run on a worker pool instead of inline. Wire the pool into `ModuleRuntime` via a new `worker_count` field in `api.Module.RuntimeOptions`. Finally, add a small pilot example showing an order module publishing an event that inventory and payment modules consume asynchronously.

**Tech Stack:** Zig 0.17.0-dev, existing `core.EventBus`, `core.ModuleRuntime`, `std.Io`, `std.ArrayList`, `std.Io.Mutex`.

## Global Constraints

- Target Zig `0.17.0-dev`; use `std.ArrayList(T).empty` + allocator-per-method.
- All mutex operations need `self.io` or the provided `std.Io` instance.
- All time measurements use `Time.monotonicNowSeconds()` or `Time.monotonicNowMilliseconds()`.
- No new mandatory external dependencies.
- Every allocation must have matching `defer`/`errdefer`.
- Tests must pass with `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Keep public API additions additive; do not break existing `api.Module` signatures.
- Existing modules without `runtime.worker_count` must still compile and behave identically.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/api/Module.zig` | Add `worker_count: u32 = 0` to `RuntimeOptions`. |
| `src/core/WorkerPool.zig` | New file. Generic bounded worker pool that executes `std.Io` tasks. |
| `src/core/EventBus.zig` | Add `subscribeAsync` to `TypedEventBus` and `ThreadSafeEventBus`. |
| `src/core/ModuleRuntime.zig` | Own an optional `WorkerPool`; expose `dispatchAsync`. |
| `src/core/ModuleRegistry.zig` | Pass `std.Io` and `worker_count` when constructing runtimes. |
| `src/Application.zig` | Provide `io` to `ModuleRegistry.initFromModules`. |
| `src/root.zig` | Re-export `WorkerPool`. |
| `src/core/EventBus.zig` | New pilot test: separate module runtimes consuming events async. |

---

## Task 1: Add `worker_count` to `api/Module.RuntimeOptions`

**Files:**
- Modify: `src/api/Module.zig`
- Test: `src/api/Module.zig` (existing test block)

**Interfaces:**
- Produces: `RuntimeOptions.worker_count: u32 = 0`.

- [ ] **Step 1: Add the field**

In `src/api/Module.zig`, add to `RuntimeOptions`:

```zig
/// Number of dedicated async workers for this module. 0 = no dedicated pool.
worker_count: u32 = 0,
```

- [ ] **Step 2: Update the compile-time test**

Extend the existing test "Module with runtime options" to assert `worker_count`:

```zig
try std.testing.expectEqual(@as(u32, 4), mod.runtime.worker_count);
```

- [ ] **Step 3: Run the module tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/root.zig --test-filter "Module with runtime options" -Mroot=src/root.zig -lc -lpq -lsqlite3 -lmysqlclient
```

Expected: test passes.

- [ ] **Step 4: Commit**

```bash
git add src/api/Module.zig
git commit -m "feat(api): add worker_count to Module.RuntimeOptions"
```

---

## Task 2: Create `core/WorkerPool.zig`

**Files:**
- Create: `src/core/WorkerPool.zig`
- Test: `src/core/WorkerPool.zig`

**Interfaces:**
- Consumes: `std.Io`, `std.Io.Mutex`, `Time.monotonicNowMilliseconds()`.
- Produces: `WorkerPool` with `init`, `deinit`, `dispatch`, `shutdown`, `pendingCount`.

- [ ] **Step 1: Create the file**

Create `src/core/WorkerPool.zig`:

```zig
//! Bounded worker pool for async task execution.
//! Tasks are submitted to a queue and executed by a fixed number of workers.

const std = @import("std");
const Time = @import("Time.zig");

pub const Task = struct {
    run: *const fn (ctx: ?*anyopaque, io: std.Io) void,
    ctx: ?*anyopaque,
};

pub const WorkerPool = struct {
    const Self = @This();

    /// Shared state is heap-allocated so worker threads have a stable pointer
    /// even after `WorkerPool.init` returns and the `WorkerPool` value is moved.
    const Shared = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        queue: std.ArrayList(Task),
        mu: std.Io.Mutex,
        cond: std.Io.Condition,
        shutdown: bool,
        max_pending: usize,
    };

    allocator: std.mem.Allocator,
    shared: *Shared,
    threads: std.ArrayList(std.Thread),
    name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        worker_count: u32,
        max_pending: usize,
    ) !Self {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);

        shared.* = .{
            .allocator = allocator,
            .io = io,
            .queue = std.ArrayList(Task).empty,
            .mu = .init,
            .cond = .init,
            .shutdown = false,
            .max_pending = max_pending,
        };
        try shared.queue.ensureTotalCapacity(allocator, max_pending);
        errdefer shared.queue.deinit(allocator);

        var threads = std.ArrayList(std.Thread).empty;
        errdefer threads.deinit(allocator);

        for (0..worker_count) |_| {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{shared});
            try threads.append(allocator, thread);
        }

        return .{
            .allocator = allocator,
            .shared = shared,
            .threads = threads,
            .name = name_copy,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shared.shutdown = true;
        self.shared.cond.broadcast(self.shared.io);
        for (self.threads.items) |thread| {
            thread.join();
        }
        self.threads.deinit(self.allocator);
        self.shared.queue.deinit(self.allocator);
        self.allocator.destroy(self.shared);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// Submit a task. Returns false if the queue is full or shutting down.
    pub fn dispatch(self: *Self, task: Task) bool {
        const shared = self.shared;
        shared.mu.lock(shared.io) catch return false;
        defer shared.mu.unlock(shared.io);

        if (shared.shutdown) return false;
        if (shared.queue.items.len >= shared.max_pending) return false;

        shared.queue.appendAssumeCapacity(task);
        shared.cond.signal(shared.io);
        return true;
    }

    pub fn pendingCount(self: *Self) usize {
        const shared = self.shared;
        shared.mu.lock(shared.io) catch return 0;
        defer shared.mu.unlock(shared.io);
        return shared.queue.items.len;
    }

    fn workerLoop(shared: *Shared) void {
        while (true) {
            shared.mu.lock(shared.io) catch return;
            while (shared.queue.items.len == 0 and !shared.shutdown) {
                shared.cond.wait(shared.io, &shared.mu) catch break;
            }
            if (shared.queue.items.len == 0 and shared.shutdown) {
                shared.mu.unlock(shared.io);
                return;
            }
            const task = shared.queue.orderedRemove(0);
            shared.mu.unlock(shared.io);

            task.run(task.ctx, shared.io);
        }
    }
};

test "WorkerPool executes dispatched tasks" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        var counter: std.atomic.Value(u32) = .init(0);
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            _ = ctx;
            _ = io;
            _ = Ctx.counter.fetchAdd(1, .monotonic);
        }
    };

    var pool = try WorkerPool.init(allocator, std.testing.io, "test", 2, 8);
    defer pool.deinit();

    for (0..10) |_| {
        try std.testing.expect(pool.dispatch(.{ .run = Ctx.run, .ctx = null }));
    }

    while (Ctx.counter.load(.monotonic) < 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 10), Ctx.counter.load(.monotonic));
}

test "WorkerPool rejects when queue is full" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            _ = ctx;
            _ = io;
        }
    };

    var pool = try WorkerPool.init(allocator, std.testing.io, "full", 1, 1);
    defer pool.deinit();

    try std.testing.expect(pool.dispatch(.{ .run = Ctx.run, .ctx = null }));
    try std.testing.expect(!pool.dispatch(.{ .run = Ctx.run, .ctx = null }));
}
```

- [ ] **Step 2: Run the worker pool tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/root.zig --test-filter "WorkerPool" -Mroot=src/root.zig -lc -lpq -lsqlite3 -lmysqlclient
```

Expected: tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/core/WorkerPool.zig
git commit -m "feat(core): add bounded WorkerPool for async task execution"
```

---

## Task 3: Add `subscribeAsync` to EventBus

**Files:**
- Modify: `src/core/EventBus.zig`
- Test: `src/core/EventBus.zig`

**Interfaces:**
- Consumes: `core.WorkerPool`.
- Produces: `TypedEventBus.subscribeAsync`, `ThreadSafeEventBus.subscribeAsync`, `AsyncSubscription` handle.

- [ ] **Step 1: Add async subscription types to TypedEventBus**

In `src/core/EventBus.zig`, add imports:

```zig
const WorkerPool = @import("WorkerPool.zig").WorkerPool;
```

Inside `TypedEventBus(T)`, add an async subscriber registry and per-delivery context:

```zig
const AsyncSubscriber = struct {
    pool: *WorkerPool,
    handler: CallbackType,
};

const AsyncDelivery = struct {
    allocator: std.mem.Allocator,
    handler: CallbackType,
    event: T,

    fn run(ctx: ?*anyopaque, io_arg: std.Io) void {
        _ = io_arg;
        const delivery: *AsyncDelivery = @ptrCast(@alignCast(ctx.?));
        delivery.handler(delivery.event);
        delivery.allocator.destroy(delivery);
    }
};

async_subscribers: std.ArrayList(AsyncSubscriber),
```

Update `init`:

```zig
return .{
    .allocator = alloc,
    .listeners = ListenerSet(CallbackType).init(alloc),
    .async_subscribers = std.ArrayList(AsyncSubscriber).empty,
};
```

Update `deinit`:

```zig
self.async_subscribers.deinit(self.allocator);
```

Add `subscribeAsync`:

```zig
pub fn subscribeAsync(self: *Self, pool: *WorkerPool, handler: CallbackType) !void {
    try self.async_subscribers.append(self.allocator, .{ .pool = pool, .handler = handler });
}
```

- [ ] **Step 2: Dispatch events to async subscribers in `publish`**

Update `publish` to clone each event into an `AsyncDelivery` and submit it to the subscriber's worker pool:

```zig
pub fn publish(self: *Self, event: T) void {
    var iter = self.listeners.iterator();
    while (iter.next()) |callback| {
        callback.*(event);
    }

    for (self.async_subscribers.items) |async_sub| {
        const delivery = self.allocator.create(AsyncDelivery) catch continue;
        delivery.* = .{
            .allocator = self.allocator,
            .handler = async_sub.handler,
            .event = event,
        };
        const dispatched = async_sub.pool.dispatch(.{
            .run = AsyncDelivery.run,
            .ctx = delivery,
        });
        if (!dispatched) {
            self.allocator.destroy(delivery);
        }
    }
}
```

- [ ] **Step 3: Add tests**

Append:

```zig
test "TypedEventBus async subscriber" {
    const allocator = std.testing.allocator;
    const Event = struct { value: i32 };

    const Ctx = struct {
        var received: std.atomic.Value(i32) = .init(0);
        fn cb(event: Event) void {
            _ = Ctx.received.fetchAdd(event.value, .monotonic);
        }
    };

    var pool = try WorkerPool.init(allocator, std.testing.io, "bus", 2, 8);
    defer pool.deinit();

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    try bus.subscribeAsync(&pool, Ctx.cb);
    bus.publish(.{ .value = 7 });
    bus.publish(.{ .value = 3 });

    while (Ctx.received.load(.monotonic) != 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(i32, 10), Ctx.received.load(.monotonic));
}
```

- [ ] **Step 4: Mirror `subscribeAsync` in ThreadSafeEventBus**

Add:

```zig
pub fn subscribeAsync(self: *Self, pool: *WorkerPool, listener: TypedEventBus(T).CallbackType) !void {
    self.mu.lock(self.io) catch return;
    defer self.mu.unlock(self.io);
    try self.bus.subscribeAsync(pool, listener);
}
```

- [ ] **Step 5: Run event bus tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/root.zig --test-filter "TypedEventBus" -Mroot=src/root.zig -lc -lpq -lsqlite3 -lmysqlclient
```

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/EventBus.zig
git commit -m "feat(core): add subscribeAsync to TypedEventBus and ThreadSafeEventBus"
```

---

## Task 4: Wire WorkerPool into ModuleRuntime

**Files:**
- Modify: `src/core/ModuleRuntime.zig`
- Test: `src/core/ModuleRuntime.zig`

**Interfaces:**
- Consumes: `core.WorkerPool`, `api.RuntimeOptions.worker_count`.
- Produces: `ModuleRuntime.worker_pool`, `ModuleRuntime.dispatchAsync`.

- [ ] **Step 1: Add optional worker pool to ModuleRuntime**

In `src/core/ModuleRuntime.zig`, add imports:

```zig
const WorkerPool = @import("WorkerPool.zig").WorkerPool;
```

Add field:

```zig
worker_pool: ?WorkerPool,
```

In `init`, after circuit breaker setup:

```zig
var worker_pool: ?WorkerPool = null;
if (options.worker_count > 0) {
    worker_pool = try WorkerPool.init(allocator, io, name_copy, options.worker_count, options.worker_count * 8);
}
```

Update `deinit`:

```zig
if (self.worker_pool) |*wp| wp.deinit();
```

Update return struct.

- [ ] **Step 2: Add `dispatchAsync` helper**

```zig
/// Dispatch a task on this module's worker pool. Returns false if no pool or queue full.
pub fn dispatchAsync(self: *Self, task: WorkerPool.Task) bool {
    if (self.worker_pool) |*wp| {
        return wp.dispatch(task);
    }
    return false;
}
```

- [ ] **Step 3: Update ModuleRuntime tests**

Add a test:

```zig
test "ModuleRuntime creates worker pool from worker_count" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, std.testing.io, "worker", .{
        .worker_count = 2,
    });
    defer rt.deinit();

    const Ctx = struct {
        var counter: std.atomic.Value(u32) = .init(0);
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            _ = ctx;
            _ = io;
            _ = Ctx.counter.fetchAdd(1, .monotonic);
        }
    };

    try std.testing.expect(rt.dispatchAsync(.{ .run = Ctx.run, .ctx = null }));
    while (Ctx.counter.load(.monotonic) < 1) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
}
```

- [ ] **Step 4: Run ModuleRuntime tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/root.zig --test-filter "ModuleRuntime" -Mroot=src/root.zig -lc -lpq -lsqlite3 -lmysqlclient
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/ModuleRuntime.zig
git commit -m "feat(core): integrate WorkerPool into ModuleRuntime"
```

---

## Task 5: Update ModuleRegistry to Create Runtimes for worker_count-only Modules

**Files:**
- Modify: `src/core/ModuleRegistry.zig`
- Test: `src/core/ModuleRegistry.zig`

**Interfaces:**
- Consumes: `api.RuntimeOptions.worker_count`.
- Produces: `ModuleRegistry` creates `ModuleRuntime` for modules that declare only `worker_count`.

- [ ] **Step 1: Include `worker_count` in protection check**

In `src/core/ModuleRegistry.zig`, update `hasAnyProtection`:

```zig
fn hasAnyProtection(options: api.RuntimeOptions) bool {
    return options.max_concurrent > 0 or
        options.max_qps > 0 or
        options.cb_failure_threshold > 0 or
        options.worker_count > 0;
}
```

- [ ] **Step 2: Add a test for worker_count-only modules**

Append:

```zig
test "ModuleRegistry creates runtime for worker_count-only module" {
    const allocator = std.testing.allocator;

    const WorkerModule = struct {
        pub const info = api.Module{
            .name = "worker-only",
            .description = "Worker only",
            .runtime = .{ .worker_count = 3 },
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{WorkerModule});
    defer modules.deinit();

    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();
    try registry.initFromModules(std.testing.io, &modules);

    try std.testing.expect(registry.get("worker-only") != null);
}
```

- [ ] **Step 3: Run registry tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/root.zig --test-filter "ModuleRegistry" -Mroot=src/root.zig -lc -lpq -lsqlite3 -lmysqlclient
```

Expected: tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/core/ModuleRegistry.zig
git commit -m "feat(core): recognize worker_count as a runtime protection"
```

---

## Task 6: Re-export New Types

**Files:**
- Modify: `src/root.zig`
- Test: compile check via `zig build test`

- [ ] **Step 1: Add re-exports**

In `src/root.zig`, add:

```zig
pub const WorkerPool = @import("core/WorkerPool.zig").WorkerPool;
```

- [ ] **Step 2: Commit**

```bash
git add src/root.zig
git commit -m "feat(root): re-export WorkerPool"
```

---

## Task 7: Add Pilot Integration Test

**Files:**
- Modify: `src/core/EventBus.zig`
- Test: `src/core/EventBus.zig`

**Interfaces:**
- Consumes: `ModuleRuntime`, `WorkerPool`, `TypedEventBus.subscribeAsync`.
- Produces: A test demonstrating two worker pools consuming the same event type asynchronously.

- [ ] **Step 1: Add a cross-pool async event test**

Append to `src/core/EventBus.zig` tests:

```zig
const ModuleRuntime = @import("ModuleRuntime.zig").ModuleRuntime;

test "TypedEventBus async subscribers on separate ModuleRuntime worker pools" {
    const allocator = std.testing.allocator;
    const Event = struct { order_id: u32 };

    const Ctx = struct {
        var inventory_count: std.atomic.Value(u32) = .init(0);
        var payment_count: std.atomic.Value(u32) = .init(0);

        fn onInventory(event: Event) void {
            _ = event;
            _ = inventory_count.fetchAdd(1, .monotonic);
        }

        fn onPayment(event: Event) void {
            _ = event;
            _ = payment_count.fetchAdd(1, .monotonic);
        }
    };

    var inventory_rt = try ModuleRuntime.init(allocator, std.testing.io, "inventory", .{ .worker_count = 2 });
    defer inventory_rt.deinit();

    var payment_rt = try ModuleRuntime.init(allocator, std.testing.io, "payment", .{ .worker_count = 2 });
    defer payment_rt.deinit();

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    try bus.subscribeAsync(&inventory_rt.worker_pool.?, Ctx.onInventory);
    try bus.subscribeAsync(&payment_rt.worker_pool.?, Ctx.onPayment);

    bus.publish(.{ .order_id = 1 });
    bus.publish(.{ .order_id = 2 });

    while (Ctx.inventory_count.load(.monotonic) < 2 or Ctx.payment_count.load(.monotonic) < 2) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    try std.testing.expectEqual(@as(u32, 2), Ctx.inventory_count.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), Ctx.payment_count.load(.monotonic));
}
```

- [ ] **Step 2: Run the new test**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/root.zig --test-filter "TypedEventBus async subscribers on separate ModuleRuntime worker pools" -Mroot=src/root.zig -lc -lpq -lsqlite3 -lmysqlclient
```

Expected: test passes.

- [ ] **Step 3: Commit**

```bash
git add src/core/EventBus.zig
git commit -m "test(core): pilot async cross-module event flow with separate worker pools"
```

---

## Task 8: Run Full Test Suite

- [ ] **Step 1: Run all tests**

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
```

Expected: `503+ passed; 18 skipped; 0 failed`.

- [ ] **Step 2: If failures occur, fix and re-run**

Common issues:
- `std.Io.Condition.wait` argument order is `(io, &mutex)`; do not swap them.
- `std.Thread.spawn` uses `.{}, function, .{args}`; adapt worker loop signature accordingly.
- Worker pool shutdown may need explicit draining before `deinit` returns.

- [ ] **Step 3: Final commit**

```bash
git commit --allow-empty -m "test(modulith): full suite green after Phase 2 WorkerPool + Async EventBus"
```

---

## Self-Review Checklist

- [ ] **Spec coverage:** Phase 2 items from `docs/superpowers/specs/2026-07-22-modulith-qps-design.md` §3.2, §5, §8 are covered.
- [ ] **Placeholder scan:** No TBD/TODO/"implement later"/"add validation" placeholders remain.
- [ ] **Type consistency:** `WorkerPool`, `ModuleRuntime`, `RuntimeOptions` names and signatures match across tasks.
- [ ] **Backward compatibility:** `RuntimeOptions.worker_count` defaults to `0`; modules without it continue to work.
- [ ] **Memory safety:** Every allocation has a matching free path through `defer`/`errdefer`.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-22-modulith-qps-phase2.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach would you like?
