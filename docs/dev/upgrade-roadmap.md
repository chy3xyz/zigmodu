# ZigModu Upgrade Roadmap — v0.9 → v1.0

**Current**: v0.9.2, 86/100, 129 files, ~417 tests, 0 failures

---

## Phase 1: Reliability → 90 (est. 3 days)

### 1.1 Multi-node integration test
Add `docker-compose.yml` with 3-node cluster + PostgreSQL + Redis. Run actual
gossip propagation, leader election, and event routing across real TCP connections.
```
examples/cluster-demo/
├── docker-compose.yml
├── node1.zig, node2.zig, node3.zig
└── README.md
```

> **现状（2026-09-17）**：这条计划**没有按此实现**，`examples/cluster-demo/` 已删除（它只有 compose + README，
> 且 compose 构建的是仓根 Dockerfile 跑 basic 示例；`node1/2/3.zig` 从未存在）。今天要看去处：
> 多节点拓扑与 fail-closed 说明 → `examples/distributed/README.md`；集群栈现状（membership + 读侧可用，
> 选主缺状态机、多节点启动默认拒绝）→ `docs/DISTRIBUTED.md`；docker 拓扑参考 → `examples/production-deploy/`。

### 1.2 WAL/DLQ/Partitioner test enablement
Fix Zig 0.16 `std.fs` API calls in WAL/DLQ/Partitioner. Use `std.testing.tmpDir`
to enable 8 existing-but-disabled tests.

### 1.3 Error swallowing audit
Replace critical `catch {}` sites with `catch |err| std.log.err(...)` in:
- `sqlx/sqlx.zig`: transaction rollback, DB reconnection
- `api/Server.zig`: HTTP response writes
- `log/StructuredLogger.zig`: log rotation renames

---

## Phase 2: Performance → 92 (est. 2 days)

### 2.1 Router match() arena buffer
Replace per-call `StringHashMap` allocation with fixed-size param buffer (max 8
path params). Already partially done — complete the refactor.

### 2.2 CacheManager TailQueue LRU
Replace monotonic counter-based eviction (O(n) scan) with `std.TailQueue` for
true O(1) promotion + O(1) eviction.

### 2.3 Response streaming
Add `ctx.writeStream()` API to avoid full response buffering for large payloads.

---

## Phase 3: Security → 92 (est. 2 days)

### 3.1 CSRF middleware integration
Complete the `csrf()` middleware stub with proper double-submit cookie pattern
and token rotation.

### 3.2 Auth header sanitization in logs
Add `Authorization` and `X-API-Key` redaction to `AccessLogger` and `StructuredLogger`.

### 3.3 Request ID propagation
Wire `requestId()` middleware into the default middleware chain so every request
gets a traceable X-Request-ID header.

### 3.4 Argon2 migration path
Document migration from PBKDF2 to Argon2id when `std.crypto.pwhash.argon2` stabilizes.

---

## Phase 4: Architecture → 92 (est. 3 days)

### 4.1 sqlx split
Extract `sqlx/types.zig` (Value, Row, Rows, etc.) and `sqlx/conn.zig` from the
2,900-line monolith. Keep `sqlx.zig` as a re-export facade.

### 4.2 Remove extensions.zig shim
Mark `extensions.zig` as fully deprecated; remove all duplicate exports. Users
migrate from `zigmodu.extensions.HttpServer` to `zigmodu.http.http_server`.

### 4.3 Deprecate GoZero Validator
Remove `validation/Validator.zig` in favor of `validation/ObjectValidator.zig`.
Add migration notes.

---

## Phase 5: Developer Experience (est. 2 days)

### 5.1 zmodu test generation
Add `zmodu test <module>` to generate integration test scaffolding with
mock DB, test fixtures, and health check verification.

### 5.2 zmodu interactive mode
Add `zmodu init` with project questionnaire (name, features, DB backend).

### 5.3 VS Code extension
Publish `zigmodu` snippets and module templates for VS Code Zig extension.

---

## Phase 6: Production Polish (est. 3 days)

### 6.1 Structured logging enforcement
Add `@import("zigmodu").log` check in CI; require `StructuredLogger` over
`std.log.info` for production modules.

### 6.2 Load testing framework
Add `examples/http-stress-test/` with configurable RPS, concurrency, and
Prometheus metrics collection.

### 6.3 Benchmark regression CI
Wire `zig build benchmark` into GitHub Actions with historical comparison
and alert threshold.

---

## Priority Matrix

| Phase | Effort | Score Gain | Priority |
|-------|:------:|:----------:|:--------:|
| 1. Reliability | 3d | +5 | **P0** |
| 2. Performance | 2d | +4 | P1 |
| 3. Security | 2d | +6 | P1 |
| 4. Architecture | 3d | +2 | P2 |
| 5. Developer DX | 2d | +1 | P3 |
| 6. Production Polish | 3d | +2 | P3 |

## Target: v1.0 → 92/100
