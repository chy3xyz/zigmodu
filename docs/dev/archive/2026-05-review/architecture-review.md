# zmodu Architecture Review

**Date**: 2026-05-11
**Version**: v0.8.3
**Files**: 102 `.zig` files, ~36,000 lines
**Tests**: 338 passed, 5 skipped, 0 failed

---

## Overall Assessment

The architecture is **well-layered** with a strict DAG (no circular dependencies), clean module boundaries, and a clear public API facade. The framework is production-usable for single-node applications.

**Architecture Score: 78/100** — solid foundation with targeted optimization opportunities.

---

## Strengths

### 1. Zero Circular Dependencies
Every import forms a DAG. The deepest chain is 4 hops (`pool → sqlx/errors → core/Error → core/Time → std`). No file imports something that imports itself.

### 2. Clean Public API Facade
`root.zig` is the single entry point. Internal modules (`eventbus/WAL`, `cluster/FailureDetector`, C bindings, etc.) are hidden from consumers. Deprecated APIs are clearly marked in a separate section.

### 3. Self-Contained HTTP Server
`api/Server.zig` (1,615 lines) depends only on `std`. Zero framework imports. It can be extracted and used independently of zmodu.

### 4. Minimal Core Foundation
The dependency root is tiny:
- `api/Module.zig` — 29 lines, depends on nothing
- `core/Time.zig` — 71 lines, depends on nothing except std
- `core/Module.zig` — 91 lines, depends only on api/Module

### 5. Consistent Time Source
`core/Time.zig` is imported by 18+ files. All previously hardcoded `const now = 0` patterns are eliminated.

---

## Optimization Opportunities

### P0 — Compilation Cost: `root.zig` Fan-Out

**Problem**: `root.zig` directly imports 50+ files. Every consumer pays the full compilation cost of all subsystems even if they only use `Application` + one module.

**Root cause**: Zig's compilation model re-compiles `@import`ed files for each dependent, but the root module forces all downstream consumers to parse the entire public API.

**Fix**: Split `root.zig` into per-domain entry files:
```
src/root.zig       → re-exports sub-modules (no direct file imports)
src/http.zig       → re-exports http_server, middleware, client, etc.
src/data.zig       → re-exports sqlx, redis, orm, cache, pool, migration
src/security.zig   → re-exports auth, rbac, secrets, etc.
```
Users who only need HTTP don't pay for SQLx/Redis/Kafka compilation. This is the pattern used by the Zig standard library (`std.http`, `std.crypto`, etc.).

**Impact**: ~30-50% compile-time reduction for consumers using a subset of the framework.

---

### P1 — Monolith File: `sqlx/sqlx.zig` (2,873 lines)

**Problem**: Single file contains connection pooling, query builder, prepared statements, transactions, PostgreSQL/MySQL/SQLite dialects, connection string parsing, ORM helpers, and test suites. It is 8% of the entire codebase.

**Fix**: Split into:
```
src/sqlx/
├── sqlx.zig          # Re-export facade + shared types (Value, Row, Column)
├── conn.zig          # Connection + connection pool
├── query.zig         # Query builder + prepared statement
├── tx.zig            # Transaction
├── dialect.zig       # Dialect trait
├── pg.zig            # PostgreSQL dialect
├── mysql.zig         # MySQL dialect
├── sqlite.zig        # SQLite dialect
├── errors.zig        # (exists)
├── breaker.zig       # (exists)
├── libpq_c.zig       # (exists)
├── libmysql_c.zig    # (exists)
└── sqlite3_c.zig     # (exists)
```

**Impact**: Faster incremental compilation, easier testing of individual components, clearer responsibility boundaries.

---

### P1 — Duplicate Validation Systems

**Problem**: Two parallel validation systems with overlapping purpose:
- `validation/ObjectValidator.zig` (209 lines) — field-level validation with `ValidationError` structs
- `validation/Validator.zig` (336 lines) — GoZero-style struct validation with tag-based rules

Neither is deprecated. Users face a choice with no guidance.

**Fix**: Deprecate one (prefer `ObjectValidator` — it's smaller, simpler, and doesn't rely on struct tags which require reflection support). Add a migration doc section. Merge common logic.

**Impact**: ~300 lines removed, single validation API to document and test.

---

### P2 — Observability Coupling

**Problem**: `metrics/AutoInstrumentation.zig` directly imports both `PrometheusMetrics` and `DistributedTracer`. There is no abstraction layer. Swapping metrics backends (e.g., StatsD, Datadog) requires modifying core files.

**Fix**: Define an `Observer` interface in `metrics/` or `core/`:
```zig
pub const MetricsBackend = struct {
    counter: *const fn (name: []const u8, value: u64) void,
    gauge: *const fn (name: []const u8, value: f64) void,
    histogram: *const fn (name: []const u8, value: f64) void,
};
```
AutoInstrumentation uses the interface; PrometheusMetrics implements it.

**Impact**: Pluggable observability, easier testing (mock backend), cleaner separation.

---

### P2 — Extension Dependencies on Application

**Problem**: `core/HotReloader.zig` and `core/WebMonitor.zig` import `Application.zig`. This means extensions that live in `core/` depend upward on the top-level Application module. If Application's API changes, these "leaf" modules break.

**Fix**: Move extensions to `extensions/` directory, or define a `ModuleRegistry` interface in `core/` that Application implements, so extensions depend on the interface, not the concrete type.

**Impact**: Clearer extension boundary, Application changes don't cascade into leaf modules.

---

### P3 — EventBus File Proliferation

**Problem**: The event system is split across 10 files totaling ~2,400 lines:
```
core/Event.zig (35), EventBus.zig (244), EventPublisher.zig (95),
EventLogger.zig (230), EventStore.zig (260), AutoEventListener.zig (159),
TransactionalEvent.zig (246), eventbus/WAL.zig (443),
eventbus/DLQ.zig (413), eventbus/Partitioner.zig (421)
```

Many files are small (`EventPublisher`: 95 lines, `AutoEventListener`: 159 lines). The WAL/DLQ/Partitioner (1,277 lines combined) have production-quality implementations but are unused (tests commented out in `tests.zig`).

**Fix**:
1. Merge small files: `EventPublisher` + `AutoEventListener` → `EventBus.zig`
2. Move `eventbus/WAL`, `eventbus/DLQ`, `eventbus/Partitioner` to `distributed/` or mark as `// WIP` with a plan to activate their tests

**Impact**: ~5 fewer files, clearer "what is production vs R&D" boundary.

---

### P3 — `tests.zig` as Compilation Gate

**Problem**: `tests.zig` imports every module in the codebase. Any compilation error in any file blocks all tests. This also forces C library linking (libpq, mysql, sqlite3) for even basic module tests.

**Fix**: Split into test groups that can run independently:
```
tests.zig          → core modules only (no C deps)
tests_data.zig     → sqlx, redis, orm (requires C libs)
tests_dist.zig     → cluster, distributed (requires network)
```

**Impact**: Faster test iteration, isolated failures, optional C dependency linking.

---

### P4 — Undocumented Module Lifecycle Contract

**Problem**: Multiple module definition patterns exist:
1. Compile-time: `pub const info = api.Module{...}` + `init()` / `deinit()` (Application API)
2. Runtime VTable: `Simplified.Module` with VTable dispatch (deprecated)
3. No-op modules: modules that only define `info` but no `init`/`deinit`

The compile-time contract (`init`/`deinit` signatures, error handling, return values) is implicit — defined only by how `Lifecycle.startAll` calls them. A new user reading `api/Module.zig` (29 lines) sees metadata types but no contract documentation.

**Fix**: Add contract documentation to `api/Module.zig` header comments:
```zig
/// Module lifecycle contract:
/// - `pub fn init() !void` — called at startup in dependency order
/// - `pub fn deinit() void` — called at shutdown in reverse order
/// - `pub const info: Module` — metadata (name, description, dependencies)
```

**Impact**: Self-documenting API, better IDE hints, clear contract.

---

## Dependency Layering Diagram

```
  std (no project imports)
   |
   +-- api/Module.zig           (29L, metadata types)
   +-- api/Server.zig            (1615L, self-contained HTTP)
   +-- core/Time.zig             (71L, imported by 18+ files)
   |      |
   |      +-- core/Error.zig     (333L, unified error type)
   |      |      |
   |      |      +-- sqlx/errors.zig (91L, SQL-specific shim)
   |      |             |
   |      |             +-- pool, redis, resilience/* (leaf consumers)
   |      |
   |      +-- core/EventBus.zig  (244L, typed + thread-safe)
   |      +-- resilience/*       (5 files, all depend on Time)
   |      +-- metrics, tracing, log, migration, cache, scheduler
   |
   +-- core/Module.zig → api/Module
          |
          +-- core/ModuleScanner, ModuleValidator, Lifecycle, Documentation
          +-- core/ModuleContract, ModuleInteractionVerifier, ArchitectureTester
                 |
                 +-- Application.zig (575L, orchestrator hub)
                        |
                        +-- root.zig (260L, public facade)
                        |
                        +-- core/HotReloader, core/WebMonitor (extensions)
```

---

## Summary

| Area | Score | Issue | Fix |
|------|:-----:|-------|-----|
| Dependency graph | ✅ A | No cycles, clean DAG | — |
| Public API | ⚠️ B | root.zig fan-out, 50+ imports | Split into per-domain re-export files |
| sqlx | ❌ C | 2,873-line monolith | Split into conn/query/tx/dialect modules |
| Validation | ⚠️ B | Two overlapping systems | Deprecate one, merge common logic |
| Observability | ⚠️ B | Hardcoded to PrometheusMetrics | Add MetricsBackend interface |
| Extensions | ⚠️ B | HotReloader depends on Application | Move to extensions/ or use interface |
| EventBus split | 🟡 C | 10 files, WAL/DLQ/Partitioner unused | Merge small files, mark WIP |
| tests.zig gate | 🟡 C | All-or-nothing compilation | Split into test groups |
| Module contract | 🟡 C | Implicit lifecycle contract | Document in api/Module.zig |

**Architecture Score: 78/100**

- P0-P1 items would bring it to ~85/100
- P2-P3 items to ~88/100
- P4 items are documentation polish
