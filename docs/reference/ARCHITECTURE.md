# Architecture Guide

## Overview

ZigModu is designed around the concept of **modular architecture** (modulith), where an application is composed of loosely coupled, highly cohesive modules. This guide explains the architectural decisions and how to effectively use ZigModu in your projects.

**Day-one modulith + high-concurrency practices** (boundaries, fiber model, pooling, scale ladder): see **[MODULITH.md](../guide/MODULITH.md)** (中文专文).

## Core Concepts

### What is a Module?

A module in ZigModu is:
- A logical unit of functionality
- A collection of related features
- An independently deployable unit (in theory)
- A namespace for related code

### Module Characteristics

```
┌─────────────────────────────────────┐
│           Module                    │
├─────────────────────────────────────┤
│  • Public API (exports)             │
│  • Internal Implementation          │
│  • Dependencies (other modules)     │
│  • Lifecycle (init/deinit)          │
│  • Configuration                    │
│  • Events (in/out)                  │
└─────────────────────────────────────┘
```

## System Architecture

### 源码子系统和文档的对应（`src/` → 文档）

`src/` 下有 30+ 个目录，但本文原先只提到 3 个。下面这张表把**每个子系统**
指到**该读哪份文档**，免得读者在 44 份文档里猜。

| `src/` 子系统 | 读这份 |
|---------------|--------|
| `runtime/` `scheduler/` `pool/` | [RUNTIME.md](./RUNTIME.md) —— 执行面：worker / 邮箱 / 池 / 优先级 / 监督 / 公平性 / 37 条指标 |
| `api/` `http/` | [ROUTE_TABLE.md](./ROUTE_TABLE.md) · [ARCHITECTURE.md](./ARCHITECTURE.md) · 背压与超时默认值见 [RUNTIME.md](./RUNTIME.md) |
| `core/` | 基础设施原语（Time / EventBus / WAL / 分代工具）；契约散见 [RUNTIME.md](./RUNTIME.md) 与 [DISTRIBUTED.md](./DISTRIBUTED.md) |
| `cluster/` `im/` `security/`（传输层） | [DISTRIBUTED.md](./DISTRIBUTED.md) —— Raft / 总线 / 成员 / 传输加密边界 |
| `data/` `sqlx/` `persistence/` | [SQLX_DRIVERS.md](../guide/SQLX_DRIVERS.md) · [MODULE_LAYERS.md](../guide/MODULE_LAYERS.md) |
| `migration/` | **文档缺失**：见下方 §未成文的子系统 |
| `tenant/` `datapermission/` | 本文 §Multi-Tenancy（`ShardRouter` 分片见该节） |
| `observability/` `metrics/` `tracing/` `log/` | [OBSERVABILITY.md](./OBSERVABILITY.md) · [LOGGING.md](../guide/LOGGING.md) |
| `resilience/` | [BEST_PRACTICES.md](../guide/BEST_PRACTICES.md) §韧性原语（断路器/限流/隔离舱/**自适应卸压**） |
| `ai/` | [AI_DEV_GUIDE.md](../ai/AI_DEV_GUIDE.md) · [AI_ORCHESTRATION.md](../ai/AI_ORCHESTRATION.md) · [MCP.md](../ai/MCP.md) · [AI_BOUNDARY.md](./AI_BOUNDARY.md) |
| `extensions/` | [FRAMEWORK_BACKLOG.md](../archive/status/FRAMEWORK_BACKLOG.md)（多数仍在计划中） |
| `secrets/` `cache/` `kit/` `validation/` `config/` `di/` | **文档缺失**：见下方 §未成文的子系统 |
| `web4/` | [WEB4.md](./WEB4.md) —— DID 身份 + x402 |
| `messaging/` | [AI_ORCHESTRATION.md](../ai/AI_ORCHESTRATION.md)（outbox 消费端接线见 AGENTS.md） |
| `test/` | 各文档的测试约定；`examples/` 见 [QUICK-START.md](../guide/QUICK-START.md) |

#### 未成文的子系统

下列目录**有实现、有导出、但没有任何文档描述它们**。这里先记下事实，
避免读者以为"没文档 = 没有"：

| 子系统 | 已导出的主要类型 | 备注 |
|--------|-----------------|------|
| `src/migration/` | `MigrationRunner` `MigrationEntry` `AppliedMigration` `MigrationStatus` `MigrationStatusEntry` `MigrationLoader` | **命名冲突**：仓库里的 `API-MIGRATION.md` / `MIGRATION_v04_to_v07.md` 说的是**API** 迁移，不是数据库迁移，容易搜不到 |
| `src/secrets/` | `SecretsManager` `SecretsSourcePriority` | 未成文 |
| `src/cache/` | `CacheManager` `CacheAside` | 未成文 |
| `src/config/` | `ConfigLoader` `ConfigManager` `ModuleConfig` `ExternalizedConfig` `TomlLoader` `TomlParser` | 未成文；配置键散落在各文档 |
| `src/validation/` | `Validator` `FieldRules` `Violations` `Violation` `Result` | 未成文 |
| `src/di/` | `Container` `ScopedContainer` | [EVENTS_DI.md](../guide/EVENTS_DI.md) 只覆盖 EventBus 侧 |
| `src/kit/` | 格式化辅助（`formatDuration` / `formatFileSize` / `formatNumber` / `validateDepth`） | 未成文；均为内部辅助函数 |

> 这一节是**缺口清单，不是接口文档**——照着 `src/` 读签名之前，
> 请以代码为准；上表只告诉你"这里有东西"。

### High-Level Design

```
┌─────────────────────────────────────────────────────────┐
│                    Application                           │
├─────────────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐   │
│  │ Module A │  │ Module B │  │ Module C │  │ Module D │   │
│  │         │  │         │  │         │  │         │   │
│  │ • API   │  │ • API   │  │ • API   │  │ • API   │   │
│  │ • Impl  │  │ • Impl  │  │ • Impl  │  │ • Impl  │   │
│  │ • Tests │  │ • Tests │  │ • Tests │  │ • Tests │   │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘   │
│       │            │            │            │         │
│       └────────────┴────────────┴────────────┘         │
│                    Event Bus                             │
└─────────────────────────────────────────────────────────┘
```

### Layered Architecture

```
┌─────────────────────────────────────┐
│  Application Layer (main.zig)       │
│  - Module composition               │
│  - Configuration                    │
│  - Bootstrap                        │
├─────────────────────────────────────┤
│  Module Layer (modules/*.zig)       │
│  - Business logic                   │
│  - Module API                       │
│  - Event handlers                   │
├─────────────────────────────────────┤
│  Framework Layer (zigmodu)          │
│  - Module management                │
│  - Event bus                        │
│  - DI container                     │
│  - Lifecycle management             │
├─────────────────────────────────────┤
│  Infrastructure Layer               │
│  - std library                      │
│  - External dependencies            │
└─────────────────────────────────────┘
```

## Module Communication

### Dependency-Based Communication

```
Order Module ──────► Inventory Module
      │                      │
      │ depends on           │
      │                      │
      └──────────────────────┘
         Direct API calls
```

### Event-Based Communication

```
Order Module         Inventory Module
     │                       │
     │  OrderCreatedEvent    │
     ├──────────────────────►│
     │                       │
     │  StockReservedEvent   │
     │◄──────────────────────┤
     │                       │
```

### Comparison

| Aspect | Direct Dependencies | Event-Based |
|--------|-------------------|-------------|
| Coupling | Tight | Loose |
| Latency | Immediate | Async |
| Complexity | Simple | More complex |
| Testing | Mock dependencies | Subscribe to events |
| Use case | Core dependencies | Cross-cutting concerns |

## Dependency Management

### Valid Dependency Patterns

```
✅ Valid:
   User ──► Order ──► Payment

✅ Valid:
   Inventory ◄── Order
   Payment   ◄── Order

❌ Invalid (Circular):
   A ──► B ──► C ──► A
```

### Dependency Declaration

```zig
// Good: Explicit dependencies
pub const info = api.Module{
    .name = "order",
    .dependencies = &."user", "inventory" },
};

// Good: No dependencies for base modules
pub const info = api.Module{
    .name = "user",
    .dependencies = &.{},
};
```

## Lifecycle Management

### Module Lifecycle

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ Created │────►│  Init   │────►│ Running │────►│  Stop   │────►│Cleaned Up│
└─────────┘     └─────────┘     └─────────┘     └─────────┘     └─────────┘
     │               │               │               │               │
     │               │               │               │               │
  scanModules()  startAll()      Operating      stopAll()      deinit()
```

### Lifecycle Hooks

```zig
pub fn init() !void {
    // Called during startAll()
    // - Allocate resources
    // - Connect to databases
    // - Subscribe to events
    // - Initialize caches
}

pub fn deinit() void {
    // Called during stopAll()
    // - Free resources
    // - Close connections
    // - Unsubscribe from events
    // - Flush caches
}
```

### Error Handling in Lifecycle

```zig
pub fn init() !void {
    // If init fails, the module won't be marked as started
    // Other modules that depend on it will fail to start
    
    db_connection = try Database.connect();
    errdefer db_connection.close();
    
    cache = try Cache.init(allocator);
    errdefer cache.deinit();
    
    try event_bus.subscribe(handleEvent);
}
```

## Memory Management

### Ownership Model

```
Application (owner)
    │
    ├──► ApplicationModules (manages modules)
    │       └──► ModuleInfo (references)
    │
    ├──► EventBus (manages listeners)
    │       └──► Listener functions
    │
    ├──► Container (manages services)
    │       └──► Service pointers (not owners!)
    │
    └──► Services (owned by application)
            └──► Database, Cache, etc.
```

### Best Practices

1. **Explicit Allocators**: Always pass allocators explicitly
2. **Defer Cleanup**: Use `defer` for resource cleanup
3. **No Hidden Allocations**: Framework avoids hidden allocations
4. **Service Ownership**: DI container stores pointers, not owners

```zig
// Good: Explicit ownership
var db = try Database.init(allocator);
defer db.deinit();

try container.register("database", &db);

// Bad: Hidden allocation
// try container.createAndRegister("database", Database);
```

## Testing Strategy

### Unit Testing

Test individual modules in isolation:

```zig
test "order module - calculate total" {
    const order = Order{
        .items = &[_]Item{
            .{ .price = 10.0, .quantity = 2 },
            .{ .price = 5.0, .quantity = 1 },
        },
    };
    
    const total = order.calculateTotal();
    try std.testing.expectEqual(@as(f64, 25.0), total);
}
```

### Integration Testing

Test module interactions:

```zig
test "order -> inventory integration" {
    var ctx = try ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    
    // Mock inventory module
    const mock_inventory = createMockModule(
        "inventory",
        "Mock inventory",
        &.{},
    );
    try ctx.registerMockModule(mock_inventory);
    
    try ctx.start();
    defer ctx.stop();
    
    // Test order creation affects inventory
}
```

### End-to-End Testing

Test the full application:

```zig
test "full application" {
    var modules = try scanModules(allocator, .{
        user_module,
        order_module,
        payment_module,
    });
    defer modules.deinit();
    
    try validateModules(&modules);
    try startAll(&modules);
    defer stopAll(&modules);
    
    // Run full workflow tests
}
```

## Performance Considerations

### Compile-Time Optimizations

- Module scanning happens at compile time
- No runtime reflection
- Static dispatch for events
- Zero-cost abstractions

### Runtime Performance

```
Operation                    Complexity
─────────────────────────────────────────
Module registration          O(1)
Dependency lookup            O(1)  (hash map)
Event publish                O(n)  (n = listeners)
Service retrieval (DI)       O(1)  (hash map)
Documentation generation     O(m)  (m = modules)
```

### Memory Usage

```
Per Module:
- ModuleInfo: ~64 bytes + strings
- Dependencies: ~8 bytes per dependency
- Event listeners: ~8 bytes per listener

Example: 100 modules, avg 3 deps each
≈ 100 * (64 + 24) = 8.8 KB + strings
```

## Scalability Patterns

### Horizontal Scaling

Modules can be distributed across processes:

```
Process 1              Process 2              Process 3
┌─────────┐           ┌─────────┐           ┌─────────┐
│ Module A │◄────────►│ Module B │◄────────►│ Module C │
│ Module D │   IPC    │ Module E │   IPC    │ Module F │
└─────────┘           └─────────┘           └─────────┘
```

### Lazy Loading

Modules can be loaded on demand:

```zig
pub fn init() !void {
    // Only initialize heavy resources when needed
    if (config.lazy_loading) {
        return; // Defer to first use
    }
    
    try initializeHeavyResources();
}
```

## Anti-Patterns

### ❌ Circular Dependencies

```zig
// BAD: Circular dependency
// A depends on B, B depends on A
pub const info = api.Module{
    .name = "a",
    .dependencies = &."b" },
};

pub const info = api.Module{
    .name = "b",
    .dependencies = &."a" ],
};
```

**Solution**: Introduce an abstraction or merge modules.

### ❌ God Modules

```zig
// BAD: Module does everything
pub const info = api.Module{
    .name = "god_module",
    .dependencies = &."db", "cache", "http", "email", "queue" },
};
```

**Solution**: Split into focused modules.

### ❌ Leaky Abstractions

```zig
// BAD: Exposing internal types in public API
pub const InternalDatabaseConnection = struct { ... };

pub fn getConnection() InternalDatabaseConnection { ... }
```

**Solution**: Define public types, hide implementation details.

## Migration Guide

### From Monolith to Modular

1. **Identify boundaries**: Find natural seams in your code
2. **Extract modules**: Move related code into module files
3. **Define APIs**: Create clean public interfaces
4. **Manage dependencies**: Explicitly declare dependencies
5. **Add lifecycle**: Implement init/deinit hooks
6. **Test incrementally**: Ensure each module works independently

### Example Migration

```
Before:
src/
├── main.zig
├── user.zig
├── order.zig
├── payment.zig
└── utils.zig

After:
src/
├── main.zig
└── modules/
    ├── user/
    │   ├── module.zig
    │   ├── api.zig
    │   └── internal.zig
    ├── order/
    │   ├── module.zig
    │   ├── api.zig
    │   └── internal.zig
    └── payment/
        ├── module.zig
        ├── api.zig
        └── internal.zig
```

## Architecture engine（v0.18+）

模块依赖不是"文档里的约定"，而是**可检查的数据**。两半，各有各的输入：

| 哪一半 | 输入 | 何时运行 | 检查什么 |
|--------|------|---------|---------|
| `src/core/ModuleGraph.zig` + `ApplicationBuilder.build(.{...})` | 模块**类型** | **编译期** | 缺失依赖、自依赖、重名、**环**（含路径）→ `@compileError` |
| `zmodu doctor` | **源码扫描** | 任意时刻（不编译工程） | 同一套图检查 + **跨模块直接 import** 的纠缠 |

```bash
zmodu doctor                 # 人类可读，阻塞性问题 exit 1
zmodu doctor --json          # CI / 看板
zmodu doctor --max-deps 6    # 收紧告警阈值
zmodu doctor --allow a->b    # 承认一处纠缠（可重复）
zmodu graph [dir] --out g.mmd  # Mermaid（已有）
```

三层强度，别混淆：

```
编译期（挡住）      缺失/自依赖/重名/环          → 构建失败，信息里带环的路径
启动期（告警）      依赖数超阈值                 → Application.validate() 记 warning
CLI（报告+可选失败）跨模块直接 import 的纠缠     → doctor 的 [warn] + 文件:行
```

为什么"domain 不许 import 数据库"这类规则只在 CLI 层：**模块声明里没有任何字段记录某个文件 import 了什么**。
声明一条无法执行的规则比不声明更糟，所以编译期只做"声明图"能证明的事，
源码级纠缠交给 `doctor` 扫描（它同时给出文件:行，评审能看到具体那行 import）。

优先级约定（与 `ModuleGraph.Report.ok()` 一致）：
**环 / 缺失 / 自依赖 / 重名 = 阻断；依赖数超阈值 / 孤儿叶子 = 告警**。
孤儿叶子（没人依赖、也不依赖别人）在 `shared`/`util` 这类模块上是正常形状，因此永不阻断。

## Multi-Tenancy (Optional)

**多租户不是框架强制能力。** ZigModu 核心（`Application`、HTTP Server、SQLx、EventBus）可在完全不启用租户逻辑的情况下运行，例如 [`examples/basic/`](../../examples/basic/) 就没有任何租户中间件或 `tenant_id` 过滤。

多租户相关代码位于 **可选基础设施层**，按需接入：

| 组件 | 路径 | 何时需要 |
|------|------|----------|
| `TenantContext` | `src/tenant/TenantContext.zig` | 请求级租户 ID；`setTenantColumn("app_id")` 可改 SQL 列名（默认 `tenant_id`） |
| `TenantInterceptor` | `src/tenant/TenantInterceptor.zig` | ORM/SQL 自动追加 `{tenant_column} = ?` |
| `ShardRouter` | `src/tenant/ShardRouter.zig` | 按租户路由到不同 DB 分片（见下） |
| `DataPermission` | `src/datapermission/` | 行级数据权限（与 RBAC 配合） |
| JWT `aud` 租户声明 | `http.jwtAuthFromCatalogWithPermissions` | 用 `generateTokenWithTenant`；attr `tenant_id`←`aud` |
| Catalog RBAC gate | `permissionGateWith(.rbac)` | `RouteMeta.permission` ⊆ `permissions` CSV |

#### 分片（`ShardRouter`）

`ShardRouter` 把 `tenant_id` 映射到分片池索引。**三条 API**：

- `ShardConfig{ .shard_count, .default_pool }` —— `shard_count` 默认 1（即不路由），
  `default_pool` 默认 `"default"`；
- `ShardPool{ .name, .host, .port, .database, .username, .password, .max_conns }`
  —— 单个分片池的连接定义；
- `ShardRouter` —— `setPools` / `assignTenant` / `route` / `getPool` /
  `getPoolForTenant` / `buildConnectionString` / `buildSqlxConfig` /
  `poolCount` / `assignedCount`。

路由规则（`route`，`src/tenant/ShardRouter.zig:88`）：

1. `ctx` 非 active → `null`（不路由）；
2. `pools` 为空 → `null`；
3. **`tenant_map` 有显式绑定** → 用绑定值（`assignTenant` 写入）；
4. 否则**按 `tenant_id % pools.len` 哈希**兜底。

> **⚠️ 哈希兜底不跨分片数稳定。** 它直接对 `pools.len` 取模，所以
> **增删分片会让几乎所有租户换库**。依赖数据亲和性的场景（大租户独立库、
> 本地时延、合规隔离）**必须用 `assignTenant` 显式绑定**；哈希只适合
> "随便哪台都行"的均衡负载。
>
> 迁移分片数时没有内建再平衡——`assignedCount` 只能告诉你绑了多少，
> 重新分配要自己写迁移。

`buildConnectionString` 只拼 **MySQL** DSN（`mysql://user:pass@host:port/db`），
固定 `max_idle_conns = max_conns / 2`；越界索引返回 `error.InvalidShardIndex`。

**典型组合：**

```
单租户应用（默认）
  HTTP → catalog JWT (+ optional permissionGate) → handler → SQLx
  （无 TenantContext，查询不带 tenant_id）

多租户 SaaS（显式启用，见 examples/tenant-mgmt）
  HTTP → catalog JWT（aud→tenant_id attr）→ [moduleGate] → permissionGate(.rbac)
       → [可选 TenantMiddleware / DataPermission] → handler
       → Service（显式传 tenant 值）→ SQL（WHERE tenant_id|app_id = ?）
  启动时可选：zigmodu.setTenantColumn("app_id")  // 与 schema 列名对齐
```

要点：

1. **不挂租户中间件 = 单租户**，与 Spring 里不用 `@TenantLine` 一样。
2. **`TenantContext.isActive()`** 为 false 时，拦截器不注入条件。
3. **租户列名**：默认 `tenant_id`；ZigShop 等用 `app_id` 时调用 `setTenantColumn("app_id")`，且模型字段名与列名一致。`zmodu --tenant-column app_id` 生成对应 `WHERE` 与 `setTenantColumn`。
4. **JWT 默认** `generateToken(user, roles)` 的 `aud` 为 `"zigmodu-app"`，不是租户 ID；租户 claim 用 `generateTokenWithTenant`；catalog 中间件写入 attr `tenant_id`。
5. **`examples/tenant-mgmt`** 是最佳实践演示；鉴权栈见 [`ROUTE_TABLE.md`](./ROUTE_TABLE.md) §7、[`BEST_PRACTICES.md`](../guide/BEST_PRACTICES.md)。
6. Legacy `security.auth.jwtAuth` / `rbacJwtMiddleware` 仅写 `auth_info`；新应用优先 catalog 路径。

认证（`AppSecurity` + catalog JWT）与多租户正交：可以只要 JWT 不要租户，也可以只要租户 header 不要 JWT（不推荐生产）。

## Conclusion

ZigModu's architecture promotes:
- **Modularity**: Clear boundaries and responsibilities
- **Testability**: Easy to test in isolation
- **Maintainability**: Changes are localized
- **Scalability**: Grow your application incrementally

By following these architectural principles, you can build robust, maintainable applications with ZigModu.
