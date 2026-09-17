# ZigModu Examples

This directory contains comprehensive examples demonstrating various features of ZigModu.

**DB linking**: most runnable examples use sqlite-only (`.db = "sqlite"` or `-Ddb=sqlite`). Path-dep apps share [`_shared/db_link.zig`](_shared/db_link.zig) via per-example symlinks. Full guide: [`docs/SQLX_DRIVERS.md`](../docs/SQLX_DRIVERS.md).

## ★ Start here: Tenant Management (`examples/tenant-mgmt`)

**Flagship runnable demo** — multi-tenant SaaS, `http.productionProfile` (connection
backpressure + security/observability middleware + `/metrics` golden signals +
`/health/live` + `/health/ready`), middleware chain (tenant → JWT → data permission),
dashboard, and `zigmodu.http` canonical imports. Used by CI integration probes (`scripts/ci-integration.sh`).

```bash
cd examples/tenant-mgmt && HTTP_PORT=18080 zig build run
# optional: zig build -Ddb=sqlite   # default for this example is already selectable
curl http://127.0.0.1:18080/health/live
```

See [tenant-mgmt/README.md](tenant-mgmt/README.md) for full API reference.

## Multi-Tenant Shop scaffold (`examples/tenant-shop`)

**Modulith blueprint demo** — storefront domain graph from [`docs/MODULITH_TENANT_SHOP.md`](../docs/MODULITH_TENANT_SHOP.md). Week 1–4 scaffold: `tenant` / `user` / `product` / `inventory` plus `cart` → `order` → `payment` with the `shop_bff` / `admin_bff` edge modules (outbox retry + DLQ included).

```bash
cd examples/tenant-shop && HTTP_PORT=18090 zig build run
curl http://127.0.0.1:18090/health/live
```

## ZigModu × zent (`examples/zent-modulith`)

**Orthogonal ORM demo** — ZigModu `http.Server` + [zent](https://github.com/chy3xyz/zent) schema-as-code Client/migrate. zent is pinned by git tag in `build.zig.zon` (`v0.67.0`); a sibling `../zent` checkout is only for developing zent itself. Practices: [`docs/ZENT.md`](../docs/ZENT.md).

```bash
cd examples/zent-modulith && HTTP_PORT=18100 zig build run
curl http://127.0.0.1:18100/health/live
```

## AI operations pipeline (`examples/ai-ops`)

**Built-in AI business tools end-to-end** — chains detect → diagnose → approve
→ notify → audit in one runnable flow:

1. **detect** — `BusinessAlert` SQL rule finds failed orders;
2. **diagnose** — `DiagnosisFlow` gathers evidence and names likely causes;
3. **approve** — `ApprovalFlow` auto-approves small refunds, escalates large ones;
4. **notify** — `NotificationHub` delivers a summary to a sink + outbox;
5. **audit** — `OutboxConsumer` polls and dispatches every written event.
6. **human queue** — escalated runs land in a `PersistentApprovalQueue` exposed
   over HTTP by `ApprovalApi` (mounted at `/api/approvals`).

```bash
cd examples/ai-ops && zig build run     # prints the trace, then serves :18087
curl http://127.0.0.1:18087/api/approvals/pending
curl -X POST http://127.0.0.1:18087/api/approvals/order-2/approve
zig build test                          # runs the single end-to-end pipeline test
```

Covered in [docs/AI_ORCHESTRATION.md](../docs/AI_ORCHESTRATION.md).

## Multi-tenant AI (`examples/tenant-ai`)

**Tenant-scoped AI operations** — two tenants share one app; every AI
capability is isolated per tenant (via `X-Tenant-ID` middleware →
`SkillContext.tenant_id`):

- `GET  /api/ai/kpi?metric=paid_revenue` — per-tenant KPI (`kpi.query`);
- `GET  /api/ai/report` — tenant-filtered Markdown business report;
- `GET  /api/ai/alerts` — tenant-filtered alert rules;
- `POST /api/ai/approval/submit?amount=N` — approval chain (auto-approve ≤
  1000, escalate above, persisted per tenant);
- `GET  /api/ai/approvals` + `POST /api/ai/approvals/{run_id}/approve` —
  per-tenant human approval queue (tenants cannot see/resolve each other's);
- `POST /api/ai/workflow/run` — orchestration running the registered skills
  (with `WorkflowMetrics`);
- `GET  /api/ai/workflow/graph` — Mermaid graph of the step pipeline
  (including the approval gate).
- `GET  /api/ai/skills` + `GET /api/ai/skills/openapi` — live skill catalog
  and OpenAPI export of the registered AI skills.

```bash
cd examples/tenant-ai && zig build run
curl -H "X-Tenant-ID: 1" "http://127.0.0.1:18088/api/ai/kpi?metric=paid_revenue"   # 150
curl -H "X-Tenant-ID: 2" "http://127.0.0.1:18088/api/ai/kpi?metric=paid_revenue"   # 9000
zig build test                          # asserts isolation end-to-end
```

## LLM-Powered Policies (`examples/llm-policies`)

**Real wiring for `zigmodu.ai.llm`** — connects `AiProvider` to the built-in
LLM policies (`llmApprove` / `llmRiskDecide` / `llmDiagnose` / `llmVerify`),
exactly as documented in [docs/LLM_POLICIES.md](../docs/LLM_POLICIES.md):

```bash
cd examples/llm-policies
zig build test                          # fake json_fn — no network
LLM_ENDPOINT=... LLM_API_KEY='Bearer sk-...' LLM_MODEL=... zig build run
```

Without credentials the demo falls back to an injected fake `json_fn` and
still exercises every policy; with credentials it calls the real model.

## Web4 (DID + x402) (`examples/web4`)

**DID identity + HTTP 402 payment gating** — two protected routes on one
server using `zigmodu.web4.middleware`:

- `GET /api/paywall` — x402 gate: no proof → `402` + invoice; valid proof → `200`
  (dev verifier accepts; production injects an on-chain/allow-list verifier);
- `GET /api/identity` — did:key auth: missing/invalid signature → `401`;
  valid signature (`x-did` / `x-did-message` / `x-did-signature`) → `200`.

```bash
cd examples/web4 && zig build run
zig build test                          # asserts 402→200 and 401→200 flows
```

Covered in [docs/WEB4.md](../docs/WEB4.md).

## Production deployment (`examples/production-deploy`)

**Not a runnable app — a topology reference.** TLS terminates at a sidecar/gateway
(nginx or Envoy config included), the backend speaks h2c/plain HTTP, and a
supervisor (`Restart=always` / k8s `restartPolicy`) is the availability backstop
because a Zig panic aborts the process. Also covers probe semantics
(liveness = process, readiness = dependencies), `docker-compose.yml`,
`k8s.yaml` (probes + HPA + Prometheus annotations), `zigmodu.service`, and a
multi-stage Dockerfile.

Backend flags wired throughout: `HTTP_MAX_CONNECTIONS`, `HTTP_HEADER_TIMEOUT_MS`,
`WS_WRITE_TIMEOUT_MS`. See [`production-deploy/README.md`](production-deploy/README.md)
and [`docs/OBSERVABILITY.md`](../docs/OBSERVABILITY.md).

## ShopDemo boundary (`examples/shopdemo`)

**Minimal runnable app** — the single `order` module extracted from `generated-sample/`, served over HTTP (`zig build run`) and smoke-tested in CI (`scripts/ci-integration.sh`). `schema.sql` keeps the full 152-table e-commerce schema; generating all 30+ modules requires the [zmodu CLI](https://github.com/chy3xyz/zmodu).

---

## 📚 Example Index

Every directory under `examples/` appears in this table exactly once, so the
index and the folder cannot drift apart. Run each row from the repository root,
e.g. `cd examples/ai-ops && zig build run`. Whether a directory ships a `test`
step is stated per row — that is the command CI runs for it.

| Directory | Demonstrates | Commands |
|-----------|--------------|----------|
| [`_shared`](_shared/) | `db_link.zig` helper imported by path — library, no app entry point | no build step of its own (`test` needs a sibling `../zent` checkout) |
| [`ai-ops`](ai-ops/) | AI ops pipeline: detect → diagnose → approve → notify → audit, plus the human approval queue over HTTP | `zig build run` · `zig build test` |
| [`alpha-engine`](alpha-engine/) | Replay pipeline (v0.23 P0 example) | `zig build run` |
| [`basic`](basic/) | Module fundamentals — **and the testing example**: `src/tests.zig` with `ModuleTestContext`, mock modules, lifecycle, dependency validation | `zig build run` · `zig build test` |
| [`distributed`](distributed/) | `DistributedEventBus` demo + the multi-node topology and why start is fail-closed | `zig build run` |
| [`event-driven`](event-driven/) | Publish/subscribe with the EventBus | `zig build run` |
| [`http-stress-test`](http-stress-test/) | Concurrent connections against the fiber-based `Server` | `zig build run` |
| [`llm-policies`](llm-policies/) | `AiProvider` wired to the built-in LLM policies (fake `json_fn`, no network) | `zig build test` · `zig build run` |
| [`mcp-server`](mcp-server/) | AI skills exposed over MCP stdio | `zig build run` |
| [`metaverse-creative`](metaverse-creative/) | Creative domain demo (zent + DID) | `zig build run` |
| [`production-deploy`](production-deploy/) | Deploy topology reference: nginx/Envoy TLS sidecar, k8s, systemd — no app | `docker compose up --build` |
| [`runtime-workers`](runtime-workers/) | Runtime workers: mailbox, backpressure, supervisor, HotBus | `zig build run` |
| [`shopdemo`](shopdemo/) | Generated `order` module + full 152-table e-commerce schema on sqlx | `zig build run` |
| [`shopdemo-zent`](shopdemo-zent/) | Same domain persisted through zent | `zig build run` |
| [`tenant-ai`](tenant-ai/) | Tenant-isolated AI skills, reports and approval queue | `zig build run` · `zig build test` |
| [`tenant-mgmt`](tenant-mgmt/) | Flagship: multi-tenant SaaS on `http.productionProfile` (CI integration demo) | `zig build run` |
| [`tenant-shop`](tenant-shop/) | Modulith blueprint: tenant/user/product/inventory + `shop_bff` / `admin_bff` | `zig build run` |
| [`web4`](web4/) | did:key identity + x402 payment gating | `zig build run` · `zig build test` |
| [`zent-modulith`](zent-modulith/) | ZigModu HTTP + zent schema-as-code ORM (zent pinned by git tag) | `zig build run` |
| [`zmsaas`](zmsaas/) | Backend (ZigModu) + SolidStart frontend | `cd examples/zmsaas/backend && zig build` · `zig build test` |

The three walkthroughs below go one level deeper on a few of those rows.

### 1. Basic Example (`examples/basic`)
**Demonstrates**: Core module system features

This row also carries the testing example: `src/tests.zig` covers
`ModuleTestContext`, `zigmodu.createMockModule`, application lifecycle and
dependency validation, and runs via `zig build test`.

- Module definition with dependencies
- Application initialization
- Dependency validation
- Lifecycle management (init/deinit)
- Topological ordering

**Key Concepts**:
```zig
const MyModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "my-module",
        .dependencies = &.{"other-module"},
    };
};

// Bind the builder first: its methods take `*Self`, a temporary is `*const`.
var b = zigmodu.builder(allocator, io);
defer b.deinit();
var app = try b.withName("app").build(.{MyModule});
defer app.deinit();
try app.start();
```

**Run**: `cd examples/basic && zig build run` · tests: `cd examples/basic && zig build test`

---

### 2. Event-Driven Example (`examples/event-driven`)
**Demonstrates**: Publish-subscribe event pattern

- Domain events definition
- EventBus usage
- Multiple subscribers
- Decoupled communication

**Key Concepts**:
```zig
const OrderCreated = struct {
    order_id: u64,
    total: f64,
};

var bus = EventBus(OrderCreated).init(allocator);
try bus.subscribe(handleOrderCreated);
bus.publish(.{ .order_id = 123, .total = 99.99 });
```

**Run**: `cd examples/event-driven && zig build run`

---

### 3. HTTP Server Stress Test (`examples/http-stress-test`)
**Demonstrates**: Async HTTP server capabilities

- Concurrent connection handling
- Route registration
- JSON and text responses
- ThreadPool-free fiber architecture
- Keep-alive support
- Request timeout handling

**Key Concepts**:
```zig
const http = zigmodu.http;

const Server = http.Server;
const Context = http.Context;

var server = Server.init(io, allocator, 8080);
try server.addRoute(.{ .method = .GET, .path = "/health",
    .handler = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.json(200, "{\"status\":\"ok\"}");
        }
    }.handle,
});
try server.start();
```

**Run**: `cd examples/http-stress-test && zig build run`

**Test API**: `curl http://localhost:8080/json`

---

## 🚀 Quick Start

### Prerequisites

- Zig 0.17.0 or later
- Git

### Running Examples

```bash
# Clone the repository
git clone https://github.com/yourusername/zigmodu.git
cd zigmodu

# Run basic example
cd examples/basic
zig build run

# Run all framework tests
cd ../..
zig build test

# Run one example's tests — the examples with a `test` step are
# ai-ops, basic, llm-policies, tenant-ai, web4 and zmsaas/backend
cd examples/basic
zig build test
```

---

## 📖 Learning Path

### Beginner
1. Start with **Basic Example** to understand core concepts
2. Read the module definition patterns
3. Understand dependency validation

### Intermediate
4. Explore **Event-Driven Example** for decoupled architecture
5. Read `examples/basic/src/tests.zig` for the testing patterns (`ModuleTestContext`, mocks)
6. Study **tenant-mgmt** for JWT + RBAC + tenant isolation

### Advanced
7. Run the **HTTP Stress Test** and inspect its fiber architecture
8. Build a **Complete Application** using all features
9. Contribute new examples!

---

## 🎯 Example Patterns

### Pattern 1: Simple Module
```zig
const SimpleModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "simple",
        .description = "A simple module",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("Simple module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("Simple module cleaned up", .{});
    }
};
```

### Pattern 2: Module with Dependencies
```zig
const DependentModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "dependent",
        .description = "Depends on other modules",
        .dependencies = &.{"simple"},
    };

    pub fn init() !void {
        // Can access SimpleModule
        std.log.info("Dependent module initialized", .{});
    }
};
```

### Pattern 3: Event-Driven Module
```zig
const EventModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "eventful",
        .dependencies = &.{},
    };

    pub fn processEvent(event: MyEvent) void {
        // Handle event
    }
};
```

---

## 🔧 Common Tasks

### Adding a New Example

1. Create directory: `mkdir examples/my-example`
2. Create `build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zigmodu dependency
    const zigmodu_dep = b.dependency("zigmodu", .{});
    exe.root_module.addImport("zigmodu", zigmodu_dep.module("zigmodu"));

    b.installArtifact(exe);
}
```

3. Create `src/main.zig`
4. Add to examples index
5. Submit PR

### Updating Examples

When updating ZigModu API:
1. Update all examples
2. Run each example the way it ships: `zig build test` for the ones with a `test` step (`ai-ops`, `basic`, `llm-policies`, `tenant-ai`, `web4`, `zmsaas/backend`); the rest are `zig build` / `zig build run`
3. Update documentation
4. Test manually

---

## 🐛 Troubleshooting

### Common Issues

**Q: Module not found?**
```
error: Module 'xxx' not found
```
A: Ensure the module is listed in Application.init()

**Q: Circular dependency?**
```
error: Circular dependency detected
```
A: Check dependency declarations and remove cycles

**Q: Compilation errors in examples?**
```
error: expected type 'xxx', found 'yyy'
```
A: Update to latest ZigModu version

---

## 🤝 Contributing

Want to add an example?

1. Check if similar example exists
2. Follow existing patterns
3. Include README.md
4. Add to this index
5. Submit PR

### Example Template

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example: [Name]
// ============================================
// Demonstrates: [What it shows]

const Module1 = struct {
    pub const info = zigmodu.api.Module{
        .name = "module1",
        .dependencies = &.{},
    };
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var b = zigmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("example").build(.{Module1});
    defer app.deinit();

    try app.start();
    std.log.info("Example completed!", .{});
}
```

---

## 📚 Additional Resources

- [API Documentation](../docs/API.md)
- [Quick Start Guide](../docs/QUICK-START.md)
- [Production Roadmap](../docs/PRODUCTION_ROADMAP.md)
- [Observability & alerting](../docs/OBSERVABILITY.md)
- [Contributing Guide](../CONTRIBUTING.md)

---

## 📊 Example Statistics

The index table above is the authority for which examples exist and how each one
runs. The per-example line counts and "Ready" badges that used to live here were
a snapshot that went stale (and duplicated the index), so they are no longer
maintained.

---

*Last updated: 2026-09-17*
