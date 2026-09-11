# ZigModu 最佳实践指南 (Best Practices Guide)

> **Modulith 从第一天怎么写高并发应用**：见专文 [MODULITH.md](MODULITH.md)（边界、fiber、池化、规模阶梯、反模式）。  
> **model / persistence / service / Tx 分层**：见专文 [MODULE_LAYERS.md](MODULE_LAYERS.md)（参考实现 `examples/tenant-shop`）。  
> **ZigModu × zent（schema / Client / privacy / 模块级选型）**：见专文 [ZENT.md](ZENT.md)（参考实现 `examples/zent-modulith`）。  
> **SQLx 选择性驱动链接（`-Ddb=` / `.db=`）**：见专文 [SQLX_DRIVERS.md](SQLX_DRIVERS.md)。  
> **HTTP 路由 + catalog JWT / RBAC**：见专文 [ROUTE_TABLE.md](ROUTE_TABLE.md) §7；可执行清单见下文「JWT / 多端身份」。  
> **AI / Agent 写代码**：先读仓库根目录 [AGENTS.md](../AGENTS.md)（文档地图 + DO/DON'T）；方法论见 [AI_METHODOLOGY.md](AI_METHODOLOGY.md)。

## 📋 目录 (Table of Contents)

- [渐进式架构演进路线图](#-渐进式架构演进路线图)
- [模块设计原则](#-模块设计原则)
- [代码质量规范](#-代码质量规范)
- [错误处理](#-错误处理)
  - [韧性：一个 bug 不拖垮整个后端](#韧性一个-bug-不拖垮整个后端v01536)
  - [连接级背压与慢连接防护](#连接级背压与慢连接防护v01536)
  - [上线前预检](#上线前预检v01536)
  - [JWT 密钥轮换（kid）](#jwt-密钥轮换kidv01536)
  - [迁移失败后怎么恢复](#迁移失败后怎么恢复运维向)
  - [多副本后台任务：跨实例互斥](#多副本后台任务跨实例互斥v01536)
- [数据访问选型（zent / sqlx）](#-数据访问选型zent--sqlx)
- [内存管理](#-内存管理)
- [测试策略](#-测试策略)
- [性能优化](#-性能优化)
- [事务范式（伪事务警示）](#-事务范式伪事务警示)
- [安全实践](#-安全实践)
- [部署与 CI/CD](#-部署与cicd)
- [**生产就绪检查清单**](#-生产就绪检查清单)
- [文档规范](#-文档规范)
- [开发工具](#-开发工具)
- [常见陷阱与避免方法](#-常见陷阱与避免方法)
- [质量指标](#-质量指标)
- [版本升级指南](#-版本升级指南)
- [团队协作](#-团队协作)

## 🚀 渐进式架构演进路线图

ZigModu 核心设计理念：**从单体部署到分布式集群，随着用户规模增长平滑演进**。

**起步请先读** [MODULITH.md](MODULITH.md) 与 [MODULE_LAYERS.md](MODULE_LAYERS.md)：五文件模块边界、Tx 工作单元、Day-1 连接池/Outbox、以及何时才拆独立进程。本节描述用户量增长驱动的架构演进，框架能力随阶段自动解锁。

---

### 领域分层（摘要）

| 层 | 要点 |
|----|------|
| model | 行形状；状态枚举；不写 SQL |
| persistence | `Persistence(Backend)` CRUD；同事务用 `pub const Tx` |
| service | Cmd/Result；`beginTx` 编排 Tx；同事务写 outbox |
| api/BFF | 解析与 JSON；禁止 SQL |

完整规则与 `tenant-shop` 对照表 → **[MODULE_LAYERS.md](MODULE_LAYERS.md)**。

---

### 阶段 1：单机部署（0 - 1,000 用户/日活）

**目标**：最小可行产品，快速上线验证

**用户痛点**：
- 日活 < 1,000
- 单机部署，简单运维
- 快速迭代，小步快跑

**技术架构**：
```
┌─────────────────────────────────┐
│         单机部署                 │
│  ┌─────────────────────────┐    │
│  │   ZigModu Application   │    │
│  │  ┌─────┐ ┌─────┐ ┌────┐ │    │
│  │  │User │ │Order│ │Pay │ │    │
│  │  └─────┘ └─────┘ └────┘ │    │
│  └─────────────────────────┘    │
│           SQLite                  │
└─────────────────────────────────┘
```

**落地步骤**：
```
Week 1: MVP 上线
├── 定义核心模块（User/Order/Product）
├── 依赖关系配置
└── init/deinit 生命周期

Week 2-3: 业务实现
├── 业务模块开发
├── EventBus 事件驱动
└── 单元测试覆盖 > 60%

Week 4: 上线准备
├── 性能基准测试
├── 日志配置
└── 部署脚本
```

**推荐配置**：
```zig
// 单机最小配置
var app = try zigmodu.Application.init(allocator, "shop", .{
    UserModule,
    OrderModule,
    ProductModule,
}, .{
    .validate = true,
    .auto_docs = true,
});
try app.start();
```

**关键指标**：
- 响应时间 < 100ms（P99）
- 吞吐量 100 QPS
- 内存占用 < 200MB

---

### 阶段 2：垂直扩展（1,000 - 10,000 用户）

**目标**：优化单机性能，支撑更大流量

**用户痛点**：
- 日活 1,000 - 10,000
- 请求量增长，单机瓶颈显现
- 需要更好的监控和告警

**演进策略**：
- 连接池优化
- 缓存引入（本地缓存 + Redis）
- 异步处理增强

**技术架构**：
```
┌─────────────────────────────────┐
│       垂直扩展（单机增强）        │
│  ┌─────────────────────────┐    │
│  │   ZigModu Application   │    │
│  │  ┌─────┐ ┌─────┐ ┌────┐ │    │
│  │  │User │ │Order│ │Pay │ │    │
│  │  └─────┘ └─────┘ └────┘ │    │
│  └─────────────────────────┘    │
│  ┌─────────┐  ┌─────────┐     │
│  │  Cache  │  │ DB Pool │     │
│  └─────────┘  └─────────┘     │
└─────────────────────────────────┘
```

**新增能力**：
```zig
// 引入缓存模块
const CacheModule = struct {
    pub const info = api.Module{
        .name = "cache",
        .dependencies = &.{"database"},
    };
    // 本地缓存 + Redis 分布式缓存
};

// 异步事件处理
const async_bus = zigmodu.extensions.AsyncEventBus.init(allocator);
```

**关键指标**：
- 响应时间 < 80ms（P99）
- 吞吐量 500 QPS
- 缓存命中率 > 80%

---

### 阶段 3：多实例部署（10,000 - 100,000 用户）

**目标**：水平扩展，多实例集群

**用户痛点**：
- 日活 10,000 - 100,000
- 单机无法支撑，需要多实例
- 会话共享、负载均衡需求

**技术架构**：
```
                    ┌──────────────────┐
                    │   Load Balancer  │
                    └────────┬─────────┘
           ┌─────────────────┼─────────────────┐
           │                 │                 │
    ┌──────▼──────┐   ┌──────▼──────┐   ┌──────▼──────┐
    │  Instance 1 │   │  Instance 2 │   │  Instance N │
    │ ┌─────────┐ │   │ ┌─────────┐ │   │ ┌─────────┐ │
    │ │ Modules │ │   │ │ Modules │ │   │ │ Modules │ │
    │ └─────────┘ │   │ └─────────┘ │   │ └─────────┘ │
    └──────┬──────┘   └──────┬──────┘   └──────┬──────┘
           │                 │                 │
           └─────────────────┴─────────────────┘
                          │
    ┌─────────────────────┴─────────────────────┐
    │        DistributedEventBus                │
    │     (ClusterMembership + Node Discovery)  │
    └────────────────────────────────────────────┘
                          │
    ┌─────────────────────┴─────────────────────┐
    │              Shared State                 │
    │   ┌────────┐   ┌────────┐   ┌────────┐  │
    │   │ Redis  │   │  DB    │   │ Cache  │  │
    │   └────────┘   └────────┘   └────────┘  │
    └────────────────────────────────────────────┘
```

**新增能力**：

| 能力 | 作用 | 引入方式 |
|------|------|----------|
| DistributedEventBus | 跨实例事件通信 | `zigmodu.core.DistributedEventBus` || ClusterMembership | 节点发现与健康检查 | `zigmodu.core.ClusterMembership` |
| Session 共享 | 分布式会话 | Redis Session Store |
| 负载均衡 | 请求分发 | Nginx/Envoy |

**配置示例**：
```zig
// 多实例部署配置
var cluster = try ClusterMembership.init(allocator, "node-1", address, &bus);
try cluster.start(.{
    .seed_nodes = &.{"node-1", "node-2"},
    .gossip_interval_ms = 1000,
});
// 分布式事件发布
try bus.publish("order.created", event_data);
```

**关键指标**：
- 响应时间 < 50ms（P99）
- 吞吐量 2,000 QPS
- 实例数 3-5 个
- 可用性 > 99.9%

---

### 阶段 4：服务网格（100,000 - 1,000,000 用户）

**目标**：微服务拆分，服务治理

**用户痛点**：
- 日活 100,000 - 1,000,000
- 业务复杂，需要服务拆分
- 需要熔断、限流、追踪

**技术架构**：
```
┌─────────────────────────────────────────────────────────┐
│                     API Gateway                          │
│              (GraphQL / REST / gRPC)                     │
└─────────────────────────────────────────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
┌────────▼────────┐ ┌─────▼─────┐ ┌──────▼──────┐
│   User Service  │ │  Order    │ │  Payment    │
│  (独立部署)      │ │  Service  │ │  Service    │
│  ┌───────────┐  │ │ ┌───────┐  │ │ ┌────────┐  │
│  │ user mod  │  │ │ │order  │  │ │ │payment │  │
│  └───────────┘  │ │ │ mod   │  │ │ │ mod    │  │
│        │        │ │ └───────┘  │ │ └────────┘  │
└────────┬────────┘ └─────┬─────┘ └──────┬──────┘
         │                │               │
         └────────────────┼───────────────┘
                          │
    ┌─────────────────────┴──────────────────────────┐
    │              Service Mesh Layer                  │
    │  • 断路器 (CircuitBreaker)                      │
    │  • 限流 (RateLimiter)                           │
    │  • 追踪 (DistributedTracing)                   │
    │  • 指标 (PrometheusMetrics)                    │
    └──────────────────────────────────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
    ┌────▼────┐     ┌─────▼─────┐   ┌─────▼─────┐
    │  Redis  │     │    DB     │   │   MQTT    │
    │ Cluster │     │  Cluster  │   │  Broker   │
    └─────────┘     └───────────┘   └───────────┘
```

**新增能力**：

| 能力 | 框架支持 | 配置 |
|------|----------|------|
| 断路器 | `zigmodu.resilience.CircuitBreaker` | 5次失败，30秒半开 |
| 限流 | `zigmodu.resilience.RateLimiter` | 令牌桶 1000/s |
| 分布式限流 | `zigmodu.data.redis_rate_limit.RateLimiter` | Redis INCR+EXPIRE 固定窗口（跨实例，fail-closed）|
| 分布式追踪 | `zigmodu.tracing.DistributedTracer` | Jaeger 导出 |
| 指标收集 | `zigmodu.metrics.PrometheusMetrics` | /metrics 端点 |
| gRPC | `zigmodu.core.TransportProtocols.GrpcTransport` | HTTP/2 |
| MQTT | `zigmodu.core.TransportProtocols.MqttTransport` | 消息队列 |

**配置示例**：
```zig
// 服务治理配置
var cb = try CircuitBreaker.init(allocator, "order-service", .{
    .failure_threshold = 5,
    .timeout_ms = 30000,
});

var limiter = try RateLimiter.init(allocator, "api", 1000, 100);

// 分布式限流（跨实例共享固定窗口；Redis 不可用 → error，fail-closed）
var redis = try data.redis.Redis.init(allocator);
defer redis.deinit();
try redis.connect("127.0.0.1", 6379, .{});
var dist_limiter = data.redis_rate_limit.RateLimiter.init(&redis);
const allowed = dist_limiter.allow("login:user-1", 5, 60) catch |err| {
    // fail-closed：限流后端不可用时不放行，按拒绝处理
    std.log.warn("rate limiter backend down: {s}", .{@errorName(err)});
    return error.RateLimited;
};
if (!allowed) return error.RateLimited;

// 跨实例 WebSocket fanout：任意实例 publish → 全集群所有实例本地 broadcast
try bus.subscribeWithContext("ws.fanout", &ws_server, struct {
    fn onEvent(ctx: ?*anyopaque, ev: NetworkEvent) void {
        const s: *WebSocketServer = @ptrCast(@alignCast(ctx.?));
        s.broadcast(ev.payload);
    }
}.onEvent);
try bus.publish("ws.fanout", "{\"type\":\"notice\"}");

// 分布式追踪
var tracer = try DistributedTracer.init(allocator, "order-service", "prod");
var span = try tracer.startTrace("createOrder");
defer tracer.endSpan(span);
```

**关键指标**：
- 响应时间 < 30ms（P99）
- 吞吐量 10,000 QPS
- 实例数 10-50 个
- 可用性 > 99.99%

---

### 阶段 5：大规模分布式（1,000,000+ 用户）

**目标**：全球化部署，多区域协调

**用户痛点**：
- 日活 > 1,000,000
- 多区域部署，低延迟
- 跨区域数据一致性

**技术架构**：
```
┌─────────────────────────────────────────────────────────┐
│                  Global Load Balancer                    │
│                   (Anycast + GeoDNS)                     │
└───────────────────────────┬─────────────────────────────┘
                            │
    ┌───────────────────────┼───────────────────────┐
    │                       │                       │
┌───▼────┐           ┌─────▼─────┐           ┌─────▼─────┐
│ Asia   │           │  Europe   │           │  America  │
│ Region │           │  Region   │           │  Region   │
│ ┌─────┐│           │ ┌─────┐   │           │ ┌─────┐   │
│ │Mesh ││           │ │Mesh │   │           │ │Mesh │   │
│ └─────┘│           │ └─────┘   │           │ └─────┘   │
└───┬────┘           └─────┬─────┘           └─────┬────┘
    │                      │                       │
    └──────────────────────┼───────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────┐
│              PasRaft Consensus Layer                   │
│   (Leader Election + Log Replication + Failover)      │
└─────────────────────────────────────────────────────────┘
```

**新增能力**：

| 能力 | 作用 | 框架支持 |
|------|------|----------|
| PasRaft 共识 | 跨区域协调，选主 | `zigmodu.core.PasRaftAdapter` |
| 多租户 | 租户隔离 | Namespace + 资源配额 |
| 热更新 | 运行时模块替换 | `zigmodu.core.HotReloader` |
| 插件系统 | 动态扩展 | `zigmodu.core.PluginManager` |

**配置示例**：
```zig
// PasRaft 共识集群
var raft = try PasRaftAdapter.init(allocator, .{
    .node_id = "node-asia-1",
    .peers = &.{"node-asia-1", "node-asia-2", "node-eu-1"},
    .election_timeout_ms = 5000,
    .heartbeat_interval_ms = 1000,
});

// 共识日志复制
try raft.proposeModuleOperation(.{
    .operation = .config_change,
    .module = "order",
    .config = new_config,
});
```

**关键指标**：
- 响应时间 < 20ms（P99）
- 吞吐量 50,000+ QPS
- 区域数 3-5 个
- 可用性 > 99.999%

---

### 演进决策树

```
当前日活用户量？
│
├─ < 1,000 → 阶段1：单机部署
│   └─ 简单业务 → 直接开发
│   └─ 有复杂需求 → 预留 EventBus 扩展点
│
├─ 1,000 - 10,000 → 阶段2：垂直扩展
│   └─ 性能瓶颈？→ 引入缓存
│   └─ 并发高？→ 异步处理优化
│
├─ 10,000 - 100,000 → 阶段3：多实例部署
│   └─ 需要分布式？→ DistributedEventBus
│   └─ 需要高可用？→ ClusterMembership
│
├─ 100,000 - 1,000,000 → 阶段4：服务网格
│   └─ 需要服务治理？→ 断路器 + 限流
│   └─ 需要可观测？→ 追踪 + 指标
│
└─ > 1,000,000 → 阶段5：大规模分布式
    └─ 跨区域？→ PasRaft 共识
    └─ 需要弹性？→ 热更新 + 插件
```

---

### 架构演进检查清单

每个阶段启动前检查：

| 阶段 | 前置条件 | 风险点 | 应对策略 |
|------|----------|--------|----------|
| 1→2 | QPS 增长 50% | 缓存穿透 | 预热 + 限流 |
| 2→3 | 实例 CPU > 70% | 会话丢失 | Redis Session |
| 3→4 | 延迟 > 100ms | 服务雪崩 | 断路器 |
| 4→5 | 跨区域部署 | 一致性 | Raft 共识 |

---

### 技术债务演进

| 阶段 | 常见技术债务 | 优先级 | 解决时机 |
|------|-------------|--------|----------|
| 1 | 缺少监控告警 | P2 | 阶段2 |
| 2 | 缓存策略单一 | P2 | 阶段2 |
| 3 | 无分布式追踪 | P1 | 阶段3 |
| 4 | 缺少熔断 | P0 | 阶段4 |
| 5 | 跨区延迟高 | P0 | 阶段5 |

**建议**：每个阶段预留 15-20% 迭代容量处理技术债务

---

### 阶段 3：分布式系统（30+ 模块）

**目标**：支持多实例部署和服务治理

**适用场景**：
- 大型项目（15+ 人）
- 高可用要求
- 多地域部署

**落地步骤**：

```
Month 1-2: 分布式基础
├── 部署 DistributedEventBus
├── 引入 ClusterMembership
└── 实现 PasRaft 共识

Month 3: 服务治理
├── 集成 ServiceMesh
├── 引入 CircuitBreaker
├── 实现 RateLimiter
└── 部署分布式追踪

Month 4: 可观测性
├── 指标收集（Prometheus）
├── 日志聚合（ELK/ Loki）
└── 链路追踪（Jaeger/Zipkin）
```

**技术要点**：
- 使用 `TransportProtocols` 支持多协议（gRPC/MQTT）
- 断路器配置建议：
  ```zig
  const cb = CircuitBreaker.init(5, 30000); // 5次失败，30秒半开
  ```
- 速率限制根据业务峰值配置

---

### 阶段 4：平台化（100+ 模块）

**目标**：构建可扩展的模块化平台

**适用场景**：
- 超大型项目
- 需要支持多产品线
- 生态开放需求

**关键能力**：

| 能力 | 说明 | 优先级 |
|------|------|--------|
| 热更新 | 运行时模块热替换 | P0 |
| 插件系统 | 动态加载扩展 | P0 |
| 网关集成 | GraphQL/REST API 网关 | P1 |
| 多租户 | 租户隔离和配额管理 | P1 |

**架构模式**：
```
┌─────────────────────────────────────────────┐
│                 API Gateway                 │
│         (GraphQL / REST / gRPC)              │
└─────────────────────────────────────────────┘
                      │
┌─────────────────────┴───────────────────────┐
│              Service Mesh Layer             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ Module   │  │ Module   │  │ Module   │   │
│  │ Cluster  │  │ Cluster  │  │ Cluster  │   │
│  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────┘
                      │
┌─────────────────────┴───────────────────────┐
│           Cluster Coordination             │
│  (Raft Consensus / Membership / Discovery)  │
└─────────────────────────────────────────────┘
```

---

### 演进决策树

```
项目当前阶段？
│
├─ < 10 模块 → 阶段1：单体应用
│   └─ 简单需求？→ 直接使用基础功能
│   └─ 复杂需求？→ 引入 DI + EventBus
│
├─ 10-30 模块 → 阶段2：模块化服务
│   └─ 单团队？→ ArchitectureTester 验证
│   └─ 多团队？→ ModuleCapabilities 边界
│
├─ 30-100 模块 → 阶段3：分布式系统
│   └─ 高可用？→ PasRaft + ServiceMesh
│   └─ 性能敏感？→ gRPC + 断路器 + 速率限制
│
└─ > 100 模块 → 阶段4：平台化
    └─ 总是 → 热更新 + 插件系统 + 多租户
```

---

### 技术债务管理

每个阶段应关注的技术债务：

| 阶段 | 技术债务 | 处理策略 |
|------|----------|----------|
| 1 | 缺少测试 | 优先补齐核心模块测试 |
| 2 | 配置分散 | 引入 ConfigManager 统一管理 |
| 3 | 缺乏监控 | 部署 MetricsCollector |
| 4 | 性能瓶颈 | 引入 APM 工具 |

**建议**：每个迭代预留 20% 时间处理技术债务

---

## 🗄 数据访问选型（zent / sqlx）

ZigModu 不绑定 ORM：**同一个应用里按模块选型**，但两者正交——**不要混驱动、不要跨两者共享事务**。

| 场景 | 选 | 理由 |
|------|-----|------|
| 电商 / 社交的实体 CRUD、边关系、行级数据权限 | **zent**（`docs/ZENT.md`） | schema-as-code + 引擎强制租户/数据范围过滤，安全靠结构而非纪律 |
| 复杂报表、多表 join、批量分析 | `data.sqlx` 裸 SQL | zent 不做 join 编排；报表只读连接可独立 |
| 需要与既有 SQL schema 对齐 | zent + `StorageKey`（v0.36+） | 字段名与列名解耦，不必改库表命名 |
| 既有 sqlx 代码迁移 | 逐模块替换 | 分层契约不变（model / persistence / service），改动局限在 persistence |

铁律与细节：[`docs/ZENT.md`](ZENT.md) §1 定位、§2 何时用哪个、§12 反模式、§14 升级注意。
租户来源必须是 JWT 注入的 attr（`.tenant_source = .attr`），从 query 取租户会被
`zmodu audit` b22 拦下。

---

## 🏗️ 模块设计原则

### 单一职责原则
每个模块应只负责一个功能领域：
```zig
// ✅ 正确示例
const UserModule = struct {
    pub const info = api.Module{
        .name = "user",
        .dependencies = &.{"auth"},
    };
    
    pub fn init() !void { /* 用户初始化 */ }
    pub fn deinit() void { /* 用户清理 */ }
};

// ❌ 错误示例 - 职责混合
const BadModule = struct {
    pub const info = api.Module{
        .name = "mixed",
        .dependencies = &.{}, // 职责不明确
    };
};
```

### 依赖管理
- **声明式依赖**：所有依赖必须在 Module.info.dependencies 中明确声明
- **避免循环依赖**：模块间不应形成循环依赖链
- **最小依赖原则**：只依赖必要的模块

### 模块生命周期
每个模块必须实现完整的生命周期：
```zig
pub fn init() !void {
    // 初始化：连接数据库、启动协程、注册事件等
    std.log.info("Module initialized", .{});
}

pub fn deinit() void {
    // 清理：释放资源、停止协程、取消订阅等
    std.log.info("Module cleaned up", .{});
}
```

### 零样板 CRUD（autoCrud）
标准租户 CRUD（list/get/create/update/delete）不需要手写 handler：

```zig
// api.zig —— 整份文件一行注册
pub const OrdersApi = zigmodu.http.CrudApi(model.Orders, service.OrdersService, .{});
```

- 自动生成 5 条路由，JWT + `<module>:read`/`<module>:write` 权限 meta；
- `tenant_id` 从 attrs 注入（勿在 handler 里再验 Bearer）；
- 分页走 `PageParams.parse`（page_size 钳制，杜绝 0 拉全表）；
- 分页 `total` 是真实 COUNT（生成 list 内建）；排序走
  `CrudOpts.sortable` 白名单（`sort=<列>&order=asc|desc`，防注入）；
- 响应白名单：`CrudOpts{ .dto = OrderDto }` 后 list/get 自动经 `toDto`
  映射（隐藏 `org_id`/`secret` 等内部列）；批量导入开
  `CrudOpts{ .bulk = true }` 获得 `POST {nest}/bulk`（一次 RTT）；
- 事件源：service 组合 `data.CrudService(Entity, Persistence)` 后，写操作自动
  publish `CrudEvent{created,updated,deleted}`，业务订阅即可（发通知/审计/外发），
  无需手写事件发布；
- 零透传：service 声明 `pub const impl = data.CrudService(Entity, P)` 与
  `crud: impl` 字段后，`CrudApi` 自动直通（无需再写 5 个转发方法）；
  生成的 service 只有接线 + `validate` 钩子（`zmodu saas` 已按此产出）；
- 读路径禁止手写 `scan()` 列下标取值——列顺序变化会静默错位；分页列表用
  arena-backed `data.ResultSet`（`queryRows.take()`，字符串零拷贝、`deinit`
  一次释放），单行用 `queryRowsSlice`（按列名映射、索引每查询建一次）；
- 多写一致性：`svc.transact(T, f)` 事务封装（生成物自带），避免手写
  begin/commit/rollback 遗漏。
- 可观测一行开：`server.addMiddleware(zigmodu.http.tracingMiddleware())`
  注入 `x-trace-id` + 请求耗时日志（`rateLimitMiddleware` 同款）；autoCrud
  路由与自定义路由一并生效，业务代码无需埋点。
- 多语言错误：`http.setErrorLocalizations(&.{.{ .err = error.ValidationFailed,
  .zh = "校验失败", .en = "Validation failed" }})` 后，`respondErr` 按
  `Accept-Language` 返回中文/英文 detail（覆盖 autoCrud 与自定义路由）。
- 数据权限 SQL 注入：`DataPermissionInterceptor.andWhere(ctx, dept_col,
  user_col)`（镜像 TenantInterceptor）由 `DataPermissionContext` 产出 scope
  子句（`.all` 返回 null、`.self_` 生成 `user_col = ?`、`.dept_*` 生成 IN）；
  中间件解析角色→作用域，handler 只把注入的子句拼进查询——不手写过滤。
- 零配置交互式 API 文档：`http.openApiRoutes(State, &slot, .{ .title = "App" })`
  一行接入 `/openapi.json`、`/docs` (Swagger UI) 与 `/scalar` (Scalar UI)
  公开路由组；亦可使用 `http.swaggerUiHandler("spec.json")` 或
  `http.scalarUiHandler("spec.json")` 单独挂载。

适用边界：规则简单的 CRUD 模块直接用；需要复杂业务编排（多表事务、状态机、
审批流）时保留 service 内手写 Cmd，autoCrud 只覆盖纯增删改查面。

### 自定义业务逻辑（扩展点）
autoCrud 之上加业务逻辑，按复杂度选档，全部向后兼容：

1. **输入校验** — 生成 service 的 `validate(e)` 钩子（create/update 自动调用）。
2. **CRUD 方法覆盖** — 在 service 里声明同名方法即优先于内嵌 impl：
   ```zig
   // create 需要额外副作用（如写 outbox、扣库存）时：
   pub fn create(self: *@This(), e: model.Orders) !i64 {
       const id = try self.crud.create(e);   // 基础行为 + validate + CrudEvent
       try self.persistence.afterCreateHook(org_id_of(e), id); // 自定义 SQL
       return id;
   }
   ```
   未覆盖的方法仍直通 `self.crud`（零透传不回归）。
3. **自定义端点** — 同 `module_name`/`nest` 挂第二个 Api 结构（路径不重叠即可，
   `assertNoDupes` 只查 method+path 重复）：
   ```zig
   pub const OrdersActionsApi = struct {
       pub const module_name = "orders";
       pub const nest = .{"orders"};
       pub const State = @This();
       service: *service.OrdersService,
       pub const routes = [_]zigmodu.http.RouteSpec(State){
           .{ .method = .POST, .path = "{id}/cancel", .handler = cancel,
             .meta = .{ .auth = .jwt, .permission = "orders:write" } },
       };
       // handler：读 attrs 的 tenant_id → self.service.cancel(...) → respondErr 映射
   };
   ```
   状态机、多表事务、审批流等同步逻辑放 service 方法；`crud.get/crud.update`
   可复用基础读写（事件照发），需要新 SQL 时用保留的 `self.persistence` 指针
   写参数化语句。
4. **解耦副作用** — 订阅 `CrudEvent{created,updated,deleted}`（含自定义方法内
   复用 `crud.create/update/delete` 的路径）：
   ```zig
   var bus = zigmodu.TypedEventBus(zigmodu.data.CrudEvent(model.Orders)).init(allocator);
   defer bus.deinit();
   try bus.subscribe(module.events.onOrderEvent);
   svc.crud.setEventBus(&bus);   // 通知/审计/外发/积分，与主流程解耦
   ```

参考实现：`examples/zmsaas/backend`（`POST /orders/{id}/cancel` 状态机 +
`events.zig` 订阅）。注意：`zmodu saas` 重新生成会覆盖
model/persistence/service/api/module/root 五个文件，自定义逻辑可放在
`events.zig` 等独立文件（生成器不写）或重新生成后重放差异。

## 🧪 代码质量规范

### 命名约定
| 类型 | 命名规范 | 示例 |
|------|---------|------|
| 模块 | 小写 + 描述 | `user`, `order_service` |
| 常量 | 全大写下划线 | `MAX_RETRIES`, `DEFAULT_TIMEOUT` |
| 函数 | 小驼峰 | `getUserData()`, `validateToken()` |
| 类型 | 大驼峰 | `UserData`, `OrderService` |
| 错误 | 全大写下划线 | `ERROR_INVALID_TOKEN` |

### 代码结构
- **文件组织**：按功能组织模块目录
- **函数长度**：单个函数不超过 50 行
- **复杂度控制**：圈复杂度保持在 10 以下
- **注释规范**：关键算法和决策点必须有注释

```zig
// ✅ 良好的代码结构
const OrderService = struct {
    /// 创建订单并验证库存
    pub fn createOrder(allocator: Allocator, req: OrderRequest) !Order {
        // 1. 验证请求参数
        try validateRequest(req);
        
        // 2. 检查库存
        const stock = try checkInventory(req.product_id);
        
        // 3. 创建订单实体
        const order = try createOrderEntity(allocator, req);
        
        // 4. 发布事件
        try publishOrderCreated(order);
        
        return order;
    }
};
```

## ⚠️ 错误处理

### 错误类型设计
- **明确错误类型**：为每个错误场景定义具体的错误类型
- **错误传播**：使用 Zig 的错误传播机制
- **上下文信息**：错误应包含足够的上下文信息

```zig
pub const AppError = error{
    DatabaseConnectionFailed,
    InvalidConfiguration,
    NetworkTimeout,
    AuthenticationFailed,
    InsufficientPermissions,
} || std.io.Error || std.json.Error;

pub fn processRequest(req: Request) AppError!Response {
    const db = try connectToDatabase() catch |err| {
        std.log.err("DB connection failed: {}", .{err});
        return err;
    };
    // ...
}
```

### 错误恢复
- **重试机制**：对临时性错误实现指数退避重试
- **降级策略**：在关键服务不可用时提供降级方案
- **断路器模式**：使用 CircuitBreaker 防止雪崩

### 韧性：一个 bug 不拖垮整个后端（v0.15.36+）

Zig 的 panic 不可捕获——请求路径上任何一次 panic 都会终止**整个进程**，
拖垮全部在途请求。框架提供四层防线（预防 → 收口 → 诊断 → 恢复）。

**生产一行接入**（细节与顺序约束见
[`ROUTE_TABLE.md`](ROUTE_TABLE.md) §7.4）：

```zig
var profile = zigmodu.http.ProductionProfileState.init(allocator);
defer profile.deinit(allocator);
try zigmodu.http.productionProfile(&server, .{
    .max_connections = 4096,      // 连接洪泛背压
    .header_timeout_ms = 10_000,  // slowloris（请求行+header 阶段）
}, &profile);                     // ⚠️ 必须在 addRoute / mountAll 之前
```

它同时挂出 `/metrics`（黄金信号）、`/health/live`、`/health/ready` 与
tracing/access-log/security-headers；告警与看板见
[`OBSERVABILITY.md`](OBSERVABILITY.md)。

**1. 预防 · 共享注册表用 FrozenMap（消除最高发的崩溃源）**

app 级共享 HashMap（适配器表、路由缓存、开关表）在 worker 池上并发
`put`/resize 会撕裂元数据，读者随后 `panic: incorrect alignment`——这类
崩溃无 stack 可用、极难定位。正确姿势：启动期填充 → `freeze()` → 运行期
只读（无锁、任意并发读安全）；冻结后写返回 `error.Frozen`（可测试、可在
启动期暴露）：

```zig
var adapters = zmodu.FrozenStringMap(Adapter).init(allocator);
try adapters.put("alipay", .{ .endpoint = "..." });  // 启动期：可写
adapters.freeze();                                   // 服务期：只读
const a = adapters.get("alipay");                    // 无锁、线程安全
```

**2. 收口 · 请求路径禁止裸 panic**

handler/service/persistence 里用错误返回，不用 `catch unreachable` /
`@panic`。`zmodu audit` 规则默认开启并拦截这三类：

| 规则 | 拦截 | 豁免 |
|------|------|------|
| b19 | 请求路径 `@panic(...)` / 语句级 `unreachable;` | switch 分支穷举 `=> unreachable,` 不报；确实不可能的分支用 `// audit: ignore b19` |
| b20 | 文件作用域共享可变 HashMap | `zmodu.FrozenMap/FrozenStringMap` 不报 |
| b21 | 请求路径裸 `@alignCast`（指针来源必须稳定） | `ctx.user_data` 与 `@alignCast(self)`（单例注册）不报 |

**3. 诊断 · panic 钩子（一行接入）**

进程还是要死，但要死得可查：panic 时先把**当前请求的 `METHOD /path`**
打到 stderr（无分配、固定缓冲），再走标准 panic 输出 stack trace。应用
root（含 `main` 的文件）加一行：

```zig
const zmodu = @import("zigmodu");
pub const panic = zmodu.panicHook;
```

Server 在 dispatch 前写入 threadlocal 请求上下文、结束后清除，无需业务
侧任何配合；不接这一行则一切照旧。

**4. 恢复 · 进程级兜底**

panic 钩子管诊断，不管存活。进程存活靠 supervisor：`systemd`
`Restart=always`、k8s `restartPolicy: Always` 或容器编排的重启策略。
多进程隔离（prefork）的边界与前置条件见
[`PRODUCTION_ROADMAP.md`](PRODUCTION_ROADMAP.md)「单进程单点与原位隔离」。

### 连接级背压与慢连接防护（v0.15.36+）

`request_timeout_ms` 只管 **handler 阶段**：连接洪泛与 header 慢速滴入
（slowloris）在它生效之前就把 fd/内存耗尽——这类故障**不需要任何 bug 就能
打挂进程**，所以是独立的两个开关：

```zig
var server = zigmodu.http.Server.initWithConfig(io, allocator, .{
    .port = 8080,
    .max_connections = 4096,          // 0 = 不限（默认）；超限立即处理
    .over_limit_response = .close,    // .close（最省）或 .unavailable（先回 503）
    .header_timeout_ms = 10_000,      // 请求行 + header 阶段的总 deadline
});
```

| 场景 | 行为 |
|------|------|
| 正常请求 | 不受影响；header 读完后 deadline 立即解除，慢速上传（body）不会被误杀 |
| 慢速滴 header | 到点回 `408 Request Timeout` 并关连接 |
| 连接数超限 `.close` | 直接关（不发响应，最省） |
| 连接数超限 `.unavailable` | 先用裸 socket 回 `503` 再关（写在 accept 线程上，不走 io，避免阻塞 accept 循环） |

也可用环境变量：`HTTP_MAX_CONNECTIONS`、`HTTP_HEADER_TIMEOUT_MS`
（`Server.fromEnv`）。上线前按"预期并发 × 2"设 `max_connections`，
`header_timeout_ms` 取 p99 建连时间的两倍左右（默认 10s 已相当宽松）。

**WebSocket 出站**（同属"慢客户端"问题，但发生在写方向）：

```zig
var server = zigmodu.http.Server.initWithConfig(io, allocator, .{
    .port = 8080,
    .ws_write_timeout_ms = 10_000,   // 0 = 旧行为（可无限阻塞）
});
```

不读数据的客户端会让发送缓冲填满，写线程（以及 `im.ConnectionRegistry` 的
shard 锁）被无限期占住。设了超时后写返回 `error.WriteTimeout` 并 shutdown
连接；广播/Fan-out 还可先用 `framer.isWritable()` 做 O(1) 水位探测，主动丢帧
而不是排队堆积。

**并发验收**：`zig build soak`（`-Dsoak-clients=N -Dsoak-iterations=M`）跑真实
socket 的 N 并发 × M 租户压测，断言跨租户读取为 **0**、冻结注册表在并发读 +
拒写下不撕裂、连接计数回落为 0。它刻意不挂在 `zig build test` 里，以便日常
快跑、发布前慢跑。

**沙箱/受限 CI**：`zig build test -Dnet-tests=false` 让所有依赖 loopback 的用例
走 `NetworkProbe.available()` 跳过（默认开启网络用例）。

### 上线前预检（v0.15.36+）

生产事故大多在启动前就已注定：少了一个环境变量、JWT secret 还是示例里的占位值、
数据库连不上、时钟差了几年（签出的 token 直接过期）。这些**在启动时检查几乎零成本**，
上线后排查却极贵：

```zig
var env_ctx = zigmodu.Preflight.EnvCheck.fromMap(init.environ_map, &.{ "JWT_SECRET", "DATABASE_URL" });
var secret_ctx = zigmodu.Preflight.SecretCheck{ .secret = jwt_secret };  // 拒绝占位/过短
var clock_ctx = zigmodu.Preflight.ClockCheck{ .io = io };
var report = zigmodu.Preflight.run(allocator, &.{
    zigmodu.Preflight.envCheck(&env_ctx),
    zigmodu.Preflight.secretCheck(&secret_ctx),
    zigmodu.Preflight.dbCheck(&db_client),      // SELECT 1
    zigmodu.Preflight.migrationCheck(&mig_ctx), // 有待应用迁移就拒绝启动
    zigmodu.Preflight.clockCheck(&clock_ctx),
});
defer report.deinit();
report.log();
if (!report.ok()) return error.PreflightFailed;   // 不启动，胜过带病运行
```

- `Severity.warn` 只告警不阻塞（如"迁移未应用"在自动迁移的应用里只提示）。
- 检查之间互不影响：单个探针失败不会掩盖其它结果。
- 参考接线：`examples/zmsaas/backend/src/main.zig`（env + secret + DB + clock）。

### JWT 密钥轮换（kid，v0.15.36+）

不带 keyring 时签发的 token 头部 `kid` 为空，换密钥只能"全部重启 + 所有人重登"。
接上 `JwksKeyRing` 后，token 头部带 `kid`，验签按 `kid` 取密钥：

```zig
var ring = zigmodu.security.JwksKeyRing.init(allocator);
defer ring.deinit();
try ring.addKey("v1", old_secret, true);      // 上线时的主密钥
app_sec.module.setKeyring(&ring);

// 轮换：新密钥设为主密钥，旧密钥留在环里继续可验
try ring.addKey("v2", new_secret, true);      // 新签发的 token 用 v2
// → 旧 token 在有效期内仍可用；等它们自然过期后再 ring 里移除 v1
```

`kid` 指向环中不存在的密钥时直接拒绝（`error.UnknownKeyId`），不会退化成"用主密钥
试一下"——否则伪造一个未知 kid 就等于绕过。

### 迁移失败后怎么恢复（运维向）

`MigrationRunner.run()` 的失败语义是**明确的**，恢复动作因此也是确定的：

| 事实 | 含义 |
|------|------|
| 失败时写入 `success = false` 的历史行，随后返回 `error.MigrationFailed` | 下一条迁移不会执行（顺序保证） |
| 只有 `success = true` 的行会被跳过 | 修复后**重启即自动重试**那条迁移，无需手工改状态 |
| 部分语句可能已生效（断在第 N 条） | 迁移脚本必须**可重复执行**：`CREATE TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` / 先判断再建索引 |
| `validateChecksums()` 校验已应用迁移的 checksum | 已上线的迁移文件**不许改**；要改就加新版本 |
| `ALTER TABLE` 语句失败会被 log + 跳过并记 success | 这是为了兼容"列已存在"，代价是**真的写错也会被吞**——ALTER 请用 `IF NOT EXISTS` 形式，测试环境先跑一遍 |

恢复步骤：修脚本（保持同一版本号与幂等）→ 重启（或再跑一次 `run()`）→ 用
`getMigrationStatus()` / 查询 `_zigmodu_migrations` 确认 `success = true`。

```sql
-- 事故现场查询：哪条迁移没成功
SELECT version, description, success, execution_time_ms, applied_at
FROM _zigmodu_migrations ORDER BY version;
```

生成迁移文件：`zmodu migration "add orders.notes" --dir src/migrations`（只生成，
不代跑）；应用由应用启动时调 `runner.run(client)`，多副本务必配
`runner.setLock(...)`（见上一节）。

### 多副本后台任务：跨实例互斥（v0.15.36+）

单机跑得对，不代表多副本跑得对：**cron 和迁移在 N 个副本上会各跑一遍**——发券、
对账、outbox 投递会重复执行，迁移则可能并发执行 DDL。

```zig
// 一张表即可，三个驱动通用（表名会做标识符校验）
var lock = try zigmodu.DistributedLock.SqlLock(@TypeOf(db)).init(
    allocator, io, &db, "zigmodu_lock", .sqlite,   // .sqlite | .postgres | .mysql
);
defer lock.deinit();

// 每个 job 每分钟只在一个副本上执行
cron.setLock(lock.lock(), 60_000);

// 滚动发布时只有一个实例应用迁移；抢不到返回 error.MigrationLocked
runner.setLock(lock.lock(), 300_000);
```

要点：

- **TTL 必须大于最慢任务**：持有者崩溃未释放时，锁在 `ttl_ms` 之后被回收；
  若任务运行时间超过 TTL，下个窗口可能被另一副本并行执行。
- **争用不是错误**：抢占是一条原子语句（`INSERT … ON CONFLICT DO NOTHING` /
  `INSERT IGNORE`），`rows_affected == 0` 即"别人持有"，返回 false；连接失败
  等真实错误会向上抛，不会被静默当成"跳过"。
- **默认无锁**（`NoopLock`）：不配置就保持单进程行为，不会有隐藏契约变化。
- Postgres 想用原生 `pg_try_advisory_lock`：实现同一个 `Lock` vtable 即可
  （`tryAcquire(name, ttl_ms)` / `release(name)`），调用点无需改动。

## 🧠 内存管理

### 分配器使用
- **明确生命周期**：每个分配明确的生命周期
- **避免内存泄漏**：确保每处分配都有对应的释放
- **使用 defer**：关键资源使用 `defer` 确保释放

```zig
// ✅ 正确的内存管理
pub fn processData(allocator: Allocator, input: []const u8) ![]u8 {
    const buffer = try allocator.alloc(u8, input.len);
    defer allocator.free(buffer); // 确保释放
    
    // 处理数据...
    
    return buffer;
}

// ❌ 错误的内存管理
pub fn badPractice() ![]u8 {
    const buffer = try allocator.alloc(u8, 1024);
    // 忘记 defer 释放
    return buffer; // 内存泄漏
}
```

### 集合使用
- **预分配容量**：已知大小时预分配容量
- **及时释放**：不再使用的集合及时释放
- **避免共享所有权**：谨慎使用共享引用

## 🧪 测试策略

### 测试金字塔
- **单元测试**：覆盖核心逻辑（70%）
- **集成测试**：验证模块交互（20%）
- **端到端测试**：完整流程验证（10%）

### 测试编写规范
```zig
// ✅ 良好的测试实践
const ModuleTestContext = @import("zigmodu").extensions.ModuleTestContext;

test "用户模块 - 创建用户" {
    const allocator = std.testing.allocator;
    var ctx = try ModuleTestContext.init(allocator, "user");
    defer ctx.deinit();
    
    try ctx.start();
    defer ctx.stop();
    
    // 执行操作
    const result = try createUser(ctx, "test_user");
    
    // 验证结果
    try std.testing.expectEqualStrings("test_user", result.name);
    try std.testing.expect(ctx.hasEvent("user.created"));
}

test "订单模块 - 异常处理" {
    const allocator = std.testing.allocator;
    var ctx = try ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    
    // 测试错误场景
    const result = createOrder(ctx, .{
        .product_id = "invalid",
        .quantity = 0, // 无效数量
    });
    
    try std.testing.expectError(error.InvalidQuantity, result);
}
```

### 覆盖率要求
- **核心模块**：覆盖率 ≥ 80%
- **关键路径**：覆盖率 ≥ 90%
- **错误路径**：必须覆盖所有错误处理分支

## ⚡ 性能优化

### 算法选择
- **数据结构**：根据访问模式选择合适的数据结构
  - 频繁查找：HashMap
  - 顺序访问：ArrayList
  - 先进先出：Queue
  
- **算法复杂度**：避免 O(n²) 复杂度的算法

### 异步处理
- **非阻塞IO**：使用异步IO避免阻塞
- **协程管理**：合理使用协程避免资源耗尽
- **批处理**：合并小请求减少开销

```zig
// ✅ 异步批处理
pub fn processBatch(allocator: Allocator, items: []Item) !void {
    const batch_size = 100;
    var i: usize = 0;
    
    while (i < items.len) {
        const batch = items[i..@min(i + batch_size, items.len)];
        try processBatchAsync(batch); // 异步批处理
        i += batch_size;
    }
}
```

### 内存池
- **对象池**：频繁创建销毁的对象使用对象池
- **缓冲区复用**：复用大缓冲区避免频繁分配
- **避免装箱**：优先使用值类型而非引用类型


## 💱 事务范式（伪事务警示）

**伪事务（最常见的事务缺陷）**：`beginTx()` 之后事务内的写仍用
`backend.exec()` / `client.exec()` —— 那走的是池连接**自动提交**，`rollback`
无效，资金/积分/状态类链路会出现部分写入残留。

正确两种范式：

1. **回调式（推荐，防呆）**：`Client.transact` / `Repository.transact` ——
   回调返回即 commit，出错自动 rollback（errdefer），结构上不可能漏：

   ```zig
   try repo.transact(void, struct {
       fn f(tx: *data.orm.Tx(data.SqlxBackend)) anyerror!void {
           try tx.exec("UPDATE orders SET status = ? WHERE id = ?", &.{.{ .int = 1 }, .{ .int = 42 }});
           try tx.exec("INSERT INTO event_outbox ...", &.{});
       }
   }.f);
   ```

2. **三件套（需要显式控制时）**：

   ```zig
   var tx = try client.beginTx();
   defer tx.rollback() catch {};   // 出错兜底回滚
   try tx.exec("UPDATE ...", &.{});
   try tx.commit();                // 全部成功才提交
   ```

**铁律**：`beginTx()` 之后一切读写**走 tx 句柄**（`tx.exec` / `tx.queryRow` /
`tx.queryRowPartial`），不要混用 `backend.exec`（池连接、非事务）。事务内查询优先
`tx.queryRowPartial`（缺失列置零，与 `Client.queryRowPartial` 同契约）。多写方法
的遗漏由 `zmodu audit` 的 b16 规则兜底（默认开启）。


## 🔒 安全实践

### JWT / 多端身份（与路由栈）

权威细则：[`ROUTE_TABLE.md`](ROUTE_TABLE.md) §7 + §7.1。此处为可执行摘要。

#### 默认栈（路径 A · 新应用必选）

```zig
var app_sec = zigmodu.security.AppSecurity.init(allocator, io, .{
    .jwt_secret = jwt_secret,
    .token_expiry_seconds = 3600,
});
var catalog_slot: http.CatalogSlot = .{};
defer catalog_slot.deinit();

// 1) JWT + 权限展开（写入 attrs；不碰 user_data）
try server.addMiddleware(http.jwtAuthFromCatalogWithPermissions(
    &app_sec.module,
    &catalog_slot,
    // 简单应用：http.catalogLoaderFromTable(&table)
    // 或：zigmodu.security.CatalogPermDb.loaderFromClient(&db)
    // 多主体：自定义 CatalogPermissionLoader（见下）
    http.catalogLoaderFromTable(&role_perm_table),
    .{ .skip_prefixes = &.{ "api/health", "health", "dashboard", "openapi.json" } },
));
// 2) 可选：写入 module attr
try server.addMiddleware(http.moduleGate(&catalog_slot, .{ .unknown = .allow }));
// 3) 门禁：RouteMeta.permission ⊆ permissions CSV
try server.addMiddleware(http.permissionGateWith(&catalog_slot, .{ .mode = .rbac }));

// … Router.mountAll …
catalog_slot.set(try router.finish());
```

签发（唯一源）：

```zig
// aud = 租户；roles = 门户粗身份（勿塞全量菜单树）
const token = try app_sec.module.generateTokenWithTenant(user_id_str, &.{ "shop" }, app_id_str);
```

路由元数据：

```zig
.{ .method = .GET, .path = "product/list", .handler = list,
   .meta = .{ .auth = .jwt, .permission = "portal:shop" } }, // 或细码 tenant:suspend
.{ .method = .POST, .path = "passport/login", .handler = login,
   .meta = .{ .auth = .public } },
```

#### 上下文槽位（正交 · 勿混用）

| 槽位 | 用途 | 禁止 |
|------|------|------|
| `ctx.user_data` | ComptimeRouter `*State` | 写入 AuthInfo / JWT 对象 |
| `ctx.auth_info` | 可选 `Rbac.AuthInfo`（legacy `rbacJwtMiddleware`） | `@ptrCast(user_data)` 当 AuthInfo |
| `ctx.attributes` | `user_id`/`tenant_id`/`roles`/`permissions` | 再验一遍 Bearer（gate 已做过） |

Handler 只读 attrs / 应用侧薄 helper（如 `portal_auth.currentTenant`），**不要**在每个 handler 里 `extractAuth` 重复验签。

#### 多门户 / 多套业务 RBAC

框架 **不** 增加 JWT `type` 枚举。约定：

| 概念 | Claim / 落点 |
|------|----------------|
| 谁 | `sub` → attr `user_id` |
| 哪租户 | `aud` → attr `tenant_id`（SQL 列名可用 `app_id`） |
| 哪门户 | `roles`：`user` / `shop` / `admin` / `supplier` |
| 门户门禁 | `RouteMeta.permission = "portal:shop"` 等 |
| 职务/菜单 | 应用表 → **自定义** `CatalogPermissionLoader` → `permissions` CSV |

自定义 loader 签名（已含身份）：

```zig
fn load(allocator: Allocator, input: http.CatalogPermLoadInput) ![]u8 {
    // input.sub / input.aud / input.roles
    // 按 roles 选 shop_* / supplier_* / admin 表族展开 access.path
    // 始终可附带 portal:* 码，便于粗门禁
}
```

- 简单演示：`RolePermissionTable` / `CatalogPermDb`（**忽略** sub/aud）。  
- 多商户后台：**不要**把三套业务表并进 `CatalogPermDb`。  
- 参考：`examples/tenant-mgmt`（单套库表）；多主体应用见 ZigShop `docs/AUTH_FRAMEWORK_ALIGNMENT.md`（路径 A 已落地）。

#### 刻意不做

- 核心 `JwtPayload` 加必填 `type`  
- 长期「应用自签 + 框架再验」双轨  
- 把业务 `*_role` / `*_access` 内置进框架  

#### Legacy 中间件

`AppSecurity.rbacJwtMiddleware*` / `security.auth.jwtAuth*` 现只写 **`auth_info`**，可与 ComptimeRouter 共存；新代码仍优先 catalog + `permissionGateWith(.rbac)`。

### 输入验证
- **边界检查**：所有外部输入必须验证
- **类型安全**：避免使用 anytype 和强制转型
- **错误处理**：绝不忽略错误

```zig
// ✅ 安全的输入验证
pub fn validateInput(input: []const u8) !void {
    if (input.len == 0 or input.len > 1024) {
        return error.InvalidInput;
    }
    
    if (!std.ascii.isPrint(input)) {
        return error.NonPrintableChar;
    }
    
    // 进一步验证...
}
```

### 并发安全
- **互斥锁**：共享数据使用互斥锁保护
- **原子操作**：简单计数器使用原子操作
- **线程隔离**：避免跨线程共享可变状态

```zig
const std = @import("std");

pub const ThreadSafeCounter = struct {
    mutex: std.Thread.Mutex = .{},
    value: u64 = 0,
    
    pub fn increment(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value += 1;
    }
    
    pub fn get(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.value;
    }
};
```

### 安全扫描
- **静态分析**：使用安全扫描工具定期检查
- **依赖审计**：定期审计第三方依赖
- **代码审查**：安全相关代码必须经过审查

## 🚀 部署与CI/CD

### 构建优化
```zig
// build.zig - 优化构建配置
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe, // 生产环境使用 ReleaseSafe
    });
    
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    
    // 生产环境特定配置
    if (optimize == .ReleaseSafe or optimize == .ReleaseFast) {
        exe.root_module.addDefine("NDEBUG");
        exe.root_module.addDefine("LOG_LEVEL=2"); // 减少日志
    }
}
```

### 环境配置
- **环境分离**：开发、测试、生产环境分离
- **配置管理**：使用环境变量配置
- **密钥管理**：敏感信息使用密钥管理服务

```zig
// config/Loader.zig - 环境感知配置
pub fn loadConfig(allocator: Allocator) !Config {
    const env = std.process.getEnvVarOwned(allocator, "APP_ENV") catch "development";
    
    return switch (env) {
        "production" => .{
            .db_url = std.process.getEnvVarOwned(allocator, "DB_URL").?,
            .log_level = .error,
            .enable_cache = true,
        },
        "staging" => .{
            .db_url = std.process.getEnvVarOwned(allocator, "DB_URL").?,
            .log_level = .info,
            .enable_cache = true,
        },
        else => .{
            .db_url = "sqlite:///dev.db",
            .log_level = .debug,
            .enable_cache = false,
        },
    };
}
```

### CI/CD 流水线
```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [master, develop]
  pull_request:
    branches: [master]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        zig-version: ["0.16.0"]
    
    steps:
      - uses: actions/checkout@v4
      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: ${{ matrix.zig-version }}
      - name: Run tests
        run: zig build test
      - name: Build examples
        run: |
          cd examples/basic && zig build
          cd ../event-driven && zig build
```

## ✅ 生产就绪检查清单

上线前逐条过一遍；每条都对应一个真实故障模式，括号内是承接它的能力。

**进程与启动**
- [ ] 应用 root 接上 `pub const panic = zmodu.panicHook;`（panic 时输出正在处理的请求）
- [ ] 启动跑 `zigmodu.Preflight.run(...)`：必填 env、JWT secret 非占位、DB 连通、无待应用迁移、时钟正常（`!report.ok()` 直接拒绝启动）
- [ ] supervisor 就位：systemd `Restart=always` 或 k8s `restartPolicy: Always`（panic 不可捕获，重启是最后一道可用性防线）

**HTTP 层**
- [ ] `http.productionProfile(&server, cfg, &state)` 在**所有 `addRoute` / `mountAll` 之前**调用
- [ ] `max_connections` 已设（≈ 预期并发 × 2）；`header_timeout_ms` 打开；`.unavailable` 或 `.close` 按需
- [ ] WS 服务设了 `ws_write_timeout_ms`；广播前用 `framer.isWritable()` 丢帧
- [ ] CORS 不再是 `"*"`（profile 会告警）

**数据与并发**
- [ ] 请求路径无裸 `panic`/`catch unreachable`（`zmodu audit` b19 拦截）
- [ ] 共享注册表用 `FrozenMap`/`FrozenStringMap`，启动期填充后 `freeze()`（b20 拦截）
- [ ] 多副本的 cron / 迁移配 `DistributedLock`（`cron.setLock` / `runner.setLock`）
- [ ] 换密钥走 `JwksKeyRing` + `setKeyring`（带 `kid`，新旧双验）
- [ ] zent 数据访问：`.tenant_source = .attr`（b22 拦截）

**可观测**
- [ ] `/metrics` 已挂且**不对公网暴露**；`/health/live` 与 `/health/ready` 语义分离（存活查进程、就绪查依赖）
- [ ] 至少 5 条告警在跑：`up`、5xx 率、P95 延迟、`outbox_pending`、`db_pool_waiters`（`docs/OBSERVABILITY.md`）
- [ ] outbox 有后台轮询 + 指标；池饱和度用 `setScrapeHook` 采样

**验证与发布**
- [ ] `zig build test` 全绿；`bash scripts/ci-integration.sh` 通过
- [ ] 发布前跑 `zig build soak`（跨租户泄漏断言）；CI 夜间已挂 64×200
- [ ] TLS 在边车终结（`examples/production-deploy/`），证书轮换有流程
- [ ] 迁移幂等（`IF NOT EXISTS`），且有失败恢复步骤（本文「迁移失败后怎么恢复」）

---

## 📚 文档规范

### API 文档
- **所有导出项**：必须包含文档注释
- **参数说明**：明确参数含义和约束
- **返回值**：说明可能的返回值和错误

```zig
/// 用户模块 - 提供用户管理服务
/// 
/// ## 示例
/// ```zig
/// const user_mod = try UserModule.init(allocator);
/// defer user_mod.deinit();
/// ```
pub const UserModule = struct {
    /// 用户信息结构
    pub const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
    };
    
    /// 创建新用户
    /// - `allocator`：内存分配器
    /// - `name`：用户名（必须非空）
    /// - `email`：邮箱地址（必须有效格式）
    /// - 返回：创建的用户对象
    pub fn createUser(
        allocator: Allocator,
        name: []const u8,
        email: []const u8,
    ) !User {
        // 实现...
    }
};
```

### 模块文档
每个模块应包含：
- 模块功能说明
- 依赖关系
- 使用示例
- 已知限制

### README 维护
- **及时更新**：功能变更后更新文档
- **示例丰富**：提供完整可运行的示例
- **结构清晰**：逻辑清晰、易于导航

## 🛠 开发工具

### 推荐工具链
- **格式化**：`zig fmt` 保持代码风格一致
- **类型检查**：`zig build check` 定期运行
- **静态分析**：使用 `scan-build` 等工具
- **性能分析**：使用 `zig build benchmark`

### 常用命令
```bash
# 格式化代码
zig fmt --check .

# 类型检查
zig build check

# 运行测试
zig build test

# 性能基准测试
zig build benchmark

# 生成文档
zig build docs
```

## 🚨 常见陷阱与避免方法

### 内存泄漏
- **问题**：忘记释放分配的内存
- **避免**：使用 `defer` 确保资源释放
- **检测**：使用内存分析工具

### 错误处理不完整
- **问题**：忽略错误或错误传播不完整
- **避免**：每个错误分支都有处理逻辑
- **检测**：代码审查时特别关注错误处理

### 竞态条件
- **问题**：多线程环境下数据竞争
- **避免**：使用适当的同步机制
- **检测**：使用数据竞争检测器

### 性能瓶颈
- **问题**：热点代码路径性能差
- **避免**：基准测试识别瓶颈
- **优化**：算法优化、缓存、批处理

### Threaded Io 下的同步阻塞（handler 内禁 `posix.poll/read`）
- **背景**：服务端 handler 跑在 **Threaded Io 的 fiber（io 线程）**上。同步阻塞调用
  （`std.posix.poll` / `std.posix.read` / 忙等）会**阻塞整个 io 线程**——所有
  并发请求共享该线程，一次阻塞 = 全局停顿（表现为超时 / ProviderError / 假死）。
- **对比**：`std.testing.io` 与独立调用线程没有 io 线程概念，同样的同步代码
  "看起来正常"——这是"live 测试通过、服务端挂"类问题的典型根源。
- **正确姿势**：
  - 出站 HTTP：一律走 `http.HttpClient`（内部已封装 io 异步路径；真实
    DeepSeek/OpenAI 流式在 Threaded Io 下实测通过）。
  - 其他网络/等待：使用 `io` 的异步 API（`io.timeout` / fiber 语义），不要
    自己 `posix.poll`。
  - 纯计算（无阻塞）不受影响。
- **诊断**：若服务端出现"单请求挂起拖垮全部"且 live 测试正常 → 查 handler 链路
  里是否有同步阻塞 I/O；`@TypeOf(io)` 打印确认是否为 Threaded。
- **契约**：框架层不强制禁止（工具链兼容），但**应用层默认禁止**在 handler /
  中间件 / Agent 工具回调里做同步阻塞 I/O。

## 📊 质量指标

### 代码质量
- [ ] 零 `@panic` 调用（生产代码）
- [ ] 错误覆盖率 ≥ 95%
- [ ] 代码重复率 < 5%
- [ ] 圈复杂度平均值 < 5

### 测试质量
- [ ] 单元测试覆盖率 ≥ 80%
- [ ] 集成测试覆盖率 ≥ 60%
- [ ] 关键路径覆盖率 ≥ 95%
- [ ] 性能测试定期运行

### 文档质量
- [ ] 所有公共 API 有文档
- [ ] 示例代码可运行
- [ ] 更新及时同步功能变更

## 🛠️ 版本升级指南

### 向后兼容性
- **API 变更**：提供迁移指南
- **行为变更**：明确说明影响
- **废弃功能**：提前版本标记为废弃

### 迁移策略
1. **并行支持**：新旧版本同时支持
2. **自动迁移**：提供迁移工具
3. **文档引导**：详细的迁移说明

## 🤝 团队协作

### 代码审查
- **必查项**：内存管理、错误处理、并发安全
- **选查项**：性能优化、代码简洁性
- **反馈机制**：及时反馈、改进闭环

### 知识共享
- **技术分享**：定期组织技术分享
- **最佳实践**：总结沉淀最佳实践
- **新人培训**：完善 onboarding 流程

--

**最后更新**：2025年4月  
**版本**：1.0  
**维护者**：ZigModu 团队
