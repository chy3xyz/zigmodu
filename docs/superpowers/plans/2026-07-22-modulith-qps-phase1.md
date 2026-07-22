# Phase 1 — ModuleRuntime: Per-Module Resource Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `ModuleRuntime` so every `zigmodu` module can own its own bulkhead, rate limiter, circuit breaker, and resource quota. This is the foundation for Modulith-scale QPS: failures and load spikes are contained inside the offending module instead of affecting the whole process.

**Architecture:** Extend `api.Module` with an optional `runtime` field. At application startup, `Application` builds a `ModuleRuntime` per module containing a `Bulkhead`, `RateLimiter`, and `CircuitBreaker` from the existing `resilience` package. Runtimes are stored in a new `core.ModuleRegistry` and are accessible by module name. The change is fully backward-compatible: modules without `runtime` continue to work exactly as before.

**Tech Stack:** Zig 0.17.0-dev, existing `resilience.Bulkhead|RateLimiter|CircuitBreaker`, `std.StringHashMap`, `std.Io.Mutex`.

## Global Constraints

- Target Zig `0.17.0-dev`; use `std.ArrayList(T).empty` + allocator-per-method.
- All mutex operations need `self.io` or the provided `std.Io` instance.
- All time measurements use `Time.monotonicNowSeconds()` or `Time.monotonicNowMilliseconds()`.
- No new mandatory external dependencies.
- Every allocation must have matching `defer`/`errdefer`.
- Tests must pass with `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Keep public API additions additive; do not break existing `api.Module` signatures.
- Existing modules without `runtime` must still compile and behave identically.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/api/Module.zig` | Add `RuntimeOptions` and optional `runtime` field to `Module`. |
| `src/core/ModuleRuntime.zig` | New file. Per-module runtime containing bulkhead, rate limiter, circuit breaker, and helpers to acquire/check them. |
| `src/core/ModuleRegistry.zig` | New file. Stores all `ModuleRuntime` instances keyed by module name and validates global resource quotas at startup. |
| `src/core/Module.zig` | Extend `ModuleInfo` with `runtime_options: api.RuntimeOptions = .{}`. |
| `src/core/ModuleScanner.zig` | Copy `mod.info.runtime` into `ModuleInfo.runtime_options` at scan time. |
| `src/Application.zig` | Build `ModuleRegistry` during `Application.init()` and expose `getModuleRuntime(name)`. |
| `src/root.zig` | Re-export `ModuleRuntime`, `ModuleRegistry`, and `RuntimeOptions`. |

---

## Task 1: Add `RuntimeOptions` to `api/Module.zig`

**Files:**
- Modify: `src/api/Module.zig`
- Test: `src/api/Module.zig` (existing test block)

**Interfaces:**
- Produces: `RuntimeOptions` struct and `Module.runtime: RuntimeOptions = .{}`.

- [ ] **Step 1: Add the runtime options struct**

Add this block after the existing `Module` struct in `src/api/Module.zig`:

```zig
/// Per-module runtime resource options.
/// All fields are optional and default to "share global resources" so existing
/// modules keep working without changes.
pub const RuntimeOptions = struct {
    /// Maximum concurrent requests/commands for this module. 0 = unlimited.
    max_concurrent: u32 = 0,
    /// Maximum requests per second for this module. 0 = unlimited.
    max_qps: u32 = 0,
    /// Circuit breaker failure threshold. 0 = disabled.
    cb_failure_threshold: u32 = 0,
    /// Circuit breaker success threshold to close again.
    cb_success_threshold: u32 = 0,
    /// Seconds before the breaker moves from OPEN to HALF_OPEN.
    cb_timeout_seconds: u64 = 0,
    /// Max test calls in HALF_OPEN state.
    cb_half_open_max_calls: u32 = 0,
};
```

- [ ] **Step 2: Wire `runtime` into `Module`**

Change the `Module` struct to include the new field:

```zig
pub const Module = struct {
    name: []const u8,
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    is_internal: bool = false,
    runtime: RuntimeOptions = .{},
};
```

- [ ] **Step 3: Add a compile-time test**

Append to the end of `src/api/Module.zig`:

```zig
test "Module with runtime options" {
    const mod = Module{
        .name = "order",
        .description = "Order module",
        .runtime = .{
            .max_concurrent = 50,
            .max_qps = 1000,
            .cb_failure_threshold = 5,
            .cb_success_threshold = 2,
            .cb_timeout_seconds = 10,
            .cb_half_open_max_calls = 3,
        },
    };
    try std.testing.expectEqual(@as(u32, 50), mod.runtime.max_concurrent);
    try std.testing.expectEqual(@as(u32, 1000), mod.runtime.max_qps);
}
```

- [ ] **Step 4: Run the module tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/api/Module.zig
```

Expected: tests pass, no compilation errors.

- [ ] **Step 5: Commit**

```bash
git add src/api/Module.zig
git commit -m "feat(api): add RuntimeOptions to Module contract"
```

---

## Task 2: Create `core/ModuleRuntime.zig`

**Files:**
- Create: `src/core/ModuleRuntime.zig`
- Test: `src/core/ModuleRuntime.zig`

**Interfaces:**
- Consumes: `api.Module.RuntimeOptions`, `resilience.Bulkhead`, `resilience.RateLimiter`, `resilience.CircuitBreaker`, `core.Time`.
- Produces: `ModuleRuntime` struct with `init`, `deinit`, `tryEnter`, `recordSuccess`, `recordFailure`, `getStats`.

- [ ] **Step 1: Create the file**

Create `src/core/ModuleRuntime.zig`:

```zig
//! Per-module runtime resource container.
//! Holds the bulkhead, rate limiter, and circuit breaker for one module.

const std = @import("std");
const api = @import("../api/Module.zig");
const resilience = @import("../resilience.zig");
const Time = @import("Time.zig");

pub const ModuleRuntime = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    module_name: []const u8,
    options: api.RuntimeOptions,
    bulkhead: ?resilience.Bulkhead,
    rate_limiter: ?resilience.RateLimiter,
    circuit_breaker: ?resilience.CircuitBreaker,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, options: api.RuntimeOptions) !Self {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        var bulkhead: ?resilience.Bulkhead = null;
        if (options.max_concurrent > 0) {
            bulkhead = try resilience.Bulkhead.init(allocator, name_copy, options.max_concurrent, 0);
        }
        errdefer if (bulkhead) |*bh| bh.deinit();

        var rate_limiter: ?resilience.RateLimiter = null;
        if (options.max_qps > 0) {
            rate_limiter = try resilience.RateLimiter.init(allocator, name_copy, options.max_qps, options.max_qps);
        }
        errdefer if (rate_limiter) |*rl| rl.deinit();

        var circuit_breaker: ?resilience.CircuitBreaker = null;
        if (options.cb_failure_threshold > 0) {
            circuit_breaker = try resilience.CircuitBreaker.init(allocator, name_copy, .{
                .failure_threshold = options.cb_failure_threshold,
                .success_threshold = if (options.cb_success_threshold > 0) options.cb_success_threshold else 1,
                .timeout_seconds = options.cb_timeout_seconds,
                .half_open_max_calls = if (options.cb_half_open_max_calls > 0) options.cb_half_open_max_calls else 1,
            });
        }

        return .{
            .allocator = allocator,
            .module_name = name_copy,
            .options = options,
            .bulkhead = bulkhead,
            .rate_limiter = rate_limiter,
            .circuit_breaker = circuit_breaker,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.bulkhead) |*bh| bh.deinit();
        if (self.rate_limiter) |*rl| rl.deinit();
        if (self.circuit_breaker) |*cb| cb.deinit();
        self.allocator.free(self.module_name);
        self.* = undefined;
    }

    /// Try to acquire permission to execute one request/command.
    /// Returns false if bulkhead, rate limit, or circuit breaker rejects.
    pub fn tryEnter(self: *Self) bool {
        if (self.bulkhead) |*bh| {
            if (!bh.tryAcquire()) return false;
        }

        if (self.rate_limiter) |*rl| {
            if (!rl.tryAcquire()) {
                if (self.bulkhead) |*bh| bh.release();
                return false;
            }
        }

        if (self.circuit_breaker) |*cb| {
            if (cb.getState() == .OPEN) {
                if (self.bulkhead) |*bh| bh.release();
                if (self.rate_limiter) |*rl| rl.reset();
                return false;
            }
        }

        return true;
    }

    /// Release one bulkhead slot after execution.
    pub fn release(self: *Self) void {
        if (self.bulkhead) |*bh| bh.release();
    }

    pub fn recordSuccess(self: *Self) void {
        if (self.circuit_breaker) |*cb| {
            _ = cb.call(struct {
                fn op() !void {}
            }.op);
        }
    }

    pub fn recordFailure(self: *Self) void {
        if (self.circuit_breaker) |*cb| {
            _ = cb.call(struct {
                fn op() !void {
                    return error.ModuleFailure;
                }
            }.op);
        }
    }

    pub const Stats = struct {
        bulkhead_active: u32 = 0,
        bulkhead_rejected: u64 = 0,
        rate_available: u32 = 0,
        cb_state: ?resilience.CircuitBreaker.State = null,
    };

    pub fn getStats(self: *Self) Stats {
        var stats: Stats = .{};
        if (self.bulkhead) |*bh| {
            stats.bulkhead_active = bh.getActiveCount();
            stats.bulkhead_rejected = bh.getStats().total_rejected;
        }
        if (self.rate_limiter) |*rl| {
            stats.rate_available = rl.availableTokens();
        }
        if (self.circuit_breaker) |*cb| {
            stats.cb_state = cb.getState();
        }
        return stats;
    }
};

test "ModuleRuntime with all protections" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, "order", .{
        .max_concurrent = 2,
        .max_qps = 5,
        .cb_failure_threshold = 1,
        .cb_success_threshold = 1,
        .cb_timeout_seconds = 0,
        .cb_half_open_max_calls = 1,
    });
    defer rt.deinit();

    try std.testing.expect(rt.tryEnter());
    try std.testing.expect(rt.tryEnter());
    try std.testing.expect(!rt.tryEnter()); // bulkhead full

    rt.release();
    try std.testing.expect(rt.tryEnter());
}

test "ModuleRuntime disabled when options are zero" {
    const allocator = std.testing.allocator;
    var rt = try ModuleRuntime.init(allocator, "user", .{});
    defer rt.deinit();

    for (0..10) |_| {
        try std.testing.expect(rt.tryEnter());
    }
}
```

- [ ] **Step 2: Run the runtime tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/core/ModuleRuntime.zig
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/core/ModuleRuntime.zig
git commit -m "feat(core): add ModuleRuntime for per-module bulkhead/rate-limiter/circuit-breaker"
```

---

## Task 3: Extend `core/ModuleInfo` and `ModuleScanner`

**Files:**
- Modify: `src/core/Module.zig`
- Modify: `src/core/ModuleScanner.zig`
- Test: both files

**Interfaces:**
- Consumes: `api.RuntimeOptions` from `src/api/Module.zig`.
- Produces: `ModuleInfo.runtime_options: api.RuntimeOptions = .{}` and scanner wiring.

- [ ] **Step 1: Add `runtime_options` to `ModuleInfo`**

In `src/core/Module.zig`, add the field:

```zig
const api = @import("../api/Module.zig");

pub const ModuleInfo = struct {
    name: []const u8,
    desc: []const u8,
    deps: []const []const u8,
    ptr: ?*anyopaque = null,
    init_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    deinit_fn: ?*const fn (?*anyopaque) void = null,
    runtime_options: api.RuntimeOptions = .{},

    pub fn init(name: []const u8, desc: []const u8, deps: []const []const u8) ModuleInfo {
        return .{
            .name = name,
            .desc = desc,
            .deps = deps,
            .ptr = null,
            .init_fn = null,
            .deinit_fn = null,
            .runtime_options = .{},
        };
    }
};
```

- [ ] **Step 2: Update `ModuleScanner` to copy runtime options**

In `src/core/ModuleScanner.zig`, change the `ModuleInfo` registration to copy `mod.info.runtime` into `runtime_options` at scan time.

```zig
try app_modules.register(ModuleInfo{
    .name = mod.info.name,
    .desc = mod.info.description,
    .deps = mod.info.dependencies,
    .ptr = @ptrCast(@constCast(&mod)),
    .init_fn = init_fn,
    .deinit_fn = deinit_fn,
    .runtime_options = mod.info.runtime,
});
```

The scanner does not create the runtime; it only preserves the options so `ModuleRegistry` can create the runtime later.

- [ ] **Step 3: Add a scanner test for runtime options**

Append to `src/core/ModuleScanner.zig`:

```zig
test "scanModules preserves runtime options" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "runtime-mock",
            .description = "Runtime mock",
            .dependencies = &.{},
            .runtime = .{
                .max_concurrent = 7,
                .max_qps = 99,
            },
        };

        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var modules = try scanModules(allocator, .{MockModule});
    defer modules.deinit();

    const info = modules.get("runtime-mock").?;
    try std.testing.expectEqualStrings("runtime-mock", info.name);
    try std.testing.expectEqual(@as(u32, 7), info.runtime_options.max_concurrent);
    try std.testing.expectEqual(@as(u32, 99), info.runtime_options.max_qps);
}
```

- [ ] **Step 4: Run core module tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/core/Module.zig
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/core/ModuleScanner.zig
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/Module.zig src/core/ModuleScanner.zig
git commit -m "feat(core): link ModuleInfo to ModuleRuntime"
```

---

## Task 4: Create `core/ModuleRegistry.zig`

**Files:**
- Create: `src/core/ModuleRegistry.zig`
- Test: `src/core/ModuleRegistry.zig`

**Interfaces:**
- Consumes: `ApplicationModules`, `ModuleRuntime`, `ModuleInfo`.
- Produces: `ModuleRegistry` with `initFromModules`, `deinit`, `get`, `validateQuotas`.

- [ ] **Step 1: Create the registry file**

Create `src/core/ModuleRegistry.zig`:

```zig
//! Global registry of ModuleRuntime instances keyed by module name.
//! Validates that per-module resource quotas do not exceed system capacity.

const std = @import("std");
const ApplicationModules = @import("Module.zig").ApplicationModules;
const ModuleInfo = @import("Module.zig").ModuleInfo;
const ModuleRuntime = @import("ModuleRuntime.zig").ModuleRuntime;
const api = @import("../api/Module.zig");

pub const ModuleRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    runtimes: std.StringHashMap(*ModuleRuntime),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .runtimes = std.StringHashMap(*ModuleRuntime).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.runtimes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.runtimes.deinit();
        self.* = undefined;
    }

    /// Build runtimes for every module that declares runtime options.
    pub fn initFromModules(self: *Self, modules: *ApplicationModules) !void {
        var iter = modules.modules.iterator();
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;
            const options = info.runtime_options;

            if (!hasAnyProtection(options)) continue;

            const runtime = try self.allocator.create(ModuleRuntime);
            errdefer self.allocator.destroy(runtime);
            runtime.* = try ModuleRuntime.init(self.allocator, info.name, options);
            try self.runtimes.put(runtime.module_name, runtime);
        }
    }

    pub fn get(self: *Self, name: []const u8) ?*ModuleRuntime {
        return self.runtimes.get(name);
    }

    /// Optional global validation hook.
    pub fn validateQuotas(self: *Self, global_max_open: u32) !void {
        var total_db_max_open: u32 = 0;
        var iter = self.runtimes.iterator();
        while (iter.next()) |entry| {
            const rt = entry.value_ptr.*;
            if (rt.options.max_concurrent > 0) {
                total_db_max_open += rt.options.max_concurrent;
            }
        }
        if (global_max_open > 0 and total_db_max_open > global_max_open) {
            std.log.err("ModuleRuntime quota exceeds global capacity: {d} > {d}", .{ total_db_max_open, global_max_open });
            return error.ConfigurationError;
        }
    }

    fn hasAnyProtection(options: api.RuntimeOptions) bool {
        return options.max_concurrent > 0 or
            options.max_qps > 0 or
            options.cb_failure_threshold > 0;
    }
};

test "ModuleRegistry creates runtimes for protected modules" {
    const allocator = std.testing.allocator;

    const ProtectedModule = struct {
        pub const info = api.Module{
            .name = "protected",
            .description = "Protected",
            .runtime = .{ .max_concurrent = 3 },
        };
    };

    const UnprotectedModule = struct {
        pub const info = api.Module{
            .name = "unprotected",
            .description = "Unprotected",
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{ ProtectedModule, UnprotectedModule });
    defer modules.deinit();

    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    try registry.initFromModules(&modules);

    try std.testing.expect(registry.get("protected") != null);
    try std.testing.expect(registry.get("unprotected") == null);

    const info = modules.get("protected").?;
    try std.testing.expect(info.runtime_options.max_concurrent == 3);
}

test "ModuleRegistry validateQuotas rejects overcommit" {
    const allocator = std.testing.allocator;

    const Module = struct {
        pub const info = api.Module{
            .name = "big",
            .description = "Big",
            .runtime = .{ .max_concurrent = 100 },
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{Module});
    defer modules.deinit();

    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();
    try registry.initFromModules(&modules);

    try std.testing.expectError(error.ConfigurationError, registry.validateQuotas(50));
    try registry.validateQuotas(100);
}
```

- [ ] **Step 2: Run registry tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/core/ModuleRegistry.zig
```

Expected: tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/core/ModuleRegistry.zig
git commit -m "feat(core): add ModuleRegistry to build and validate per-module runtimes"
```

---

## Task 5: Wire `ModuleRegistry` into `Application`

**Files:**
- Modify: `src/Application.zig`
- Test: `src/Application.zig`

**Interfaces:**
- Consumes: `ModuleRegistry`.
- Produces: `Application.registry: ?ModuleRegistry`, `Application.getModuleRuntime(name)`.

- [ ] **Step 1: Add registry field and accessor**

In `src/Application.zig`, add imports:

```zig
const ModuleRegistry = @import("core/ModuleRegistry.zig").ModuleRegistry;
```

Add the field to `Application`:

```zig
pub const Application = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    modules: ApplicationModules,
    config: Config,
    state: State,
    io: std.Io,
    shutdown_hooks: std.ArrayList(*const fn () void),
    registry: ?ModuleRegistry = null,
    // ...
```

- [ ] **Step 2: Build registry in `init`**

After scanning modules in `Application.init`, build the registry:

```zig
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    app_name: []const u8,
    comptime modules_tuple: anytype,
    options: Config,
) !Self {
    const modules = try scanModules(allocator, modules_tuple);

    var registry = ModuleRegistry.init(allocator);
    errdefer registry.deinit();
    try registry.initFromModules(&modules);

    return .{
        .io = io,
        .allocator = allocator,
        .modules = modules,
        .config = .{
            .name = app_name,
            .validate_on_start = options.validate_on_start,
            .auto_generate_docs = options.auto_generate_docs,
            .docs_path = options.docs_path,
        },
        .state = .initialized,
        .shutdown_hooks = std.ArrayList(*const fn () void).empty,
        .registry = registry,
    };
}
```

- [ ] **Step 3: Clean up registry in `deinit`**

```zig
pub fn deinit(self: *Self) void {
    if (self.state == .started) {
        self.stop();
    }
    if (self.registry) |*r| r.deinit();
    self.modules.deinit();
    self.shutdown_hooks.deinit(self.allocator);
    self.state = .stopped;
    self.* = undefined;
}
```

- [ ] **Step 4: Add public accessor**

```zig
pub fn getModuleRuntime(self: *Self, name: []const u8) ?*@import("core/ModuleRuntime.zig").ModuleRuntime {
    if (self.registry) |*r| return r.get(name);
    return null;
}
```

- [ ] **Step 5: Add an application test**

Append to `src/Application.zig` tests:

```zig
test "Application builds ModuleRegistry from module runtime options" {
    const allocator = std.testing.allocator;

    const ResilientModule = struct {
        pub const info = api.Module{
            .name = "resilient",
            .description = "Resilient",
            .runtime = .{ .max_concurrent = 5 },
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var app = try Application.init(std.testing.io, allocator, "runtime-app", .{ResilientModule}, .{});
    defer app.deinit();

    const rt = app.getModuleRuntime("resilient");
    try std.testing.expect(rt != null);
    try std.testing.expect(rt.?.tryEnter());
}
```

- [ ] **Step 6: Run application tests**

Run:

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig test src/Application.zig
```

Expected: tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/Application.zig
git commit -m "feat(app): wire ModuleRegistry into Application lifecycle"
```

---

## Task 6: Re-export from `src/root.zig`

**Files:**
- Modify: `src/root.zig`
- Test: compile check via `zig build test`

- [ ] **Step 1: Add re-exports**

In `src/root.zig`, add:

```zig
pub const ModuleRuntime = @import("core/ModuleRuntime.zig").ModuleRuntime;
pub const ModuleRegistry = @import("core/ModuleRegistry.zig").ModuleRegistry;
```

- [ ] **Step 2: Commit**

```bash
git add src/root.zig
git commit -m "feat(root): re-export ModuleRuntime and ModuleRegistry"
```

---

## Task 7: Run Full Test Suite

- [ ] **Step 1: Run all tests**

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
```

Expected:

```
490+ passed; 18 skipped; 0 failed.
```

(The exact pass count may be higher than 490 because new tests were added.)

- [ ] **Step 2: If failures occur, fix and re-run**

Common issues:
- Missing import of `std` in new test files.
- `errdefer` on optional fields — ensure destructors only run for initialized fields.
- `Application.init` now returns an error path for `ModuleRegistry.initFromModules`; ensure callers handle errors.

- [ ] **Step 3: Final commit**

```bash
git commit -m "test(modulith): full suite green after Phase 1 ModuleRuntime"
```

---

## Self-Review Checklist

- [ ] **Spec coverage:** Every Phase 1 requirement from `docs/superpowers/specs/2026-07-22-modulith-qps-design.md` §3.1, §6, §7 is covered by a task.
- [ ] **Placeholder scan:** No TBD/TODO/"implement later"/"add validation" placeholders remain.
- [ ] **Type consistency:** `ModuleRuntime`, `ModuleRegistry`, `RuntimeOptions` names and signatures match between `api/Module.zig`, `core/ModuleRuntime.zig`, `core/ModuleRegistry.zig`, and `Application.zig`.
- [ ] **Backward compatibility:** `Module.runtime` defaults to `.{}`; `ModuleInfo.runtime_options` defaults to `.{}`; modules without runtime options continue to work.
- [ ] **Memory safety:** Every allocation has a matching free path through `defer`/`errdefer`; `ModuleRuntime.tryEnter` releases acquired bulkhead/rate-limiter tokens explicitly on rejection.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-22-modulith-qps-phase1.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using `executing-plans`, batch execution with checkpoints.

Which approach would you like?
