# ZigModu v0.35.1

**编译期模块化应用框架 + worker 导向的执行运行时**，为 Zig **0.17.0** 打造。

两条平面，同一个库 —— 用哪条都行，也可以都用：

| 平面 | 你会拿到什么 | 从哪读起 |
|------|--------------|----------|
| **应用平面**（默认就在用） | 模块 + 编译期依赖校验、生命周期、DI、HTTP/1.1 + h2c + WebSocket + gRPC、SQLx / ORM / 迁移、缓存 + Redis、事件 + 事务性 outbox、JWT / RBAC / 多租户、弹性、指标与追踪 | [快速开始](docs/QUICK-START.md) · [Modulith](docs/MODULITH.md) |
| **执行平面**（`app.runtime()` opt-in） | 独占状态的 worker、有界 mailbox、锁自由队列、L0 扇出、毫秒**与**微秒定时器、监督、从段文件回放投递日志 | [Runtime](docs/RUNTIME.md) |

不调 `app.runtime()` 的应用**不会多起一条线程**，应用平面自己站得住。执行平面用于"一请求一 fiber"
不再是对的形状的场合：行情与订单簿、实时网关、AI agent 循环、IoT 状态机。它不是任何东西的移植：
comptime 轨道类型、手写队列、热路径上的分配是被**测试钉住**的契约（见
[如何验证](#-如何验证)），不是口号。

模块系统走的是 **Modulith** 的思路 —— 一个进程、硬模块边界、边界被证明之后才拆服务 —— 并且把依赖规则
放在编译期强制。

[![Zig](https://img.shields.io/badge/Zig-0.17+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/github/v/release/chy3xyz/zigmodu?style=flat-square)]()
[![CI](https://github.com/chy3xyz/zigmodu/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/chy3xyz/zigmodu/actions/workflows/ci.yml)

[English](README.md) | 中文

## 📚 文档

| 指南 | 描述 |
|------|------|
| [**AGENTS.md**](AGENTS.md) | **AI 操作手册**（DO/DON'T、Path A 鉴权、ComptimeRouter） |
| [快速开始](docs/QUICK-START.md) | 5分钟入门 |
| [**Runtime**](docs/RUNTIME.md) | **执行平面**：worker、mailbox、调度器、定时器、监督、回放 |
| [Modulith 高并发](docs/MODULITH.md) | 项目第一天：模块边界 + 高并发实践 |
| [最佳实践](docs/BEST_PRACTICES.md) | **两条平面**：架构演进、JWT / 多端身份清单、执行平面何时该上 |
| [事件与 DI](docs/EVENTS_DI.md) | `initWith(ctx)` + `app.eventBus` + 容器 freeze 最佳实践 |
| [声明式路由](docs/ROUTE_TABLE.md) | ComptimeRouter + catalog JWT/RBAC |
| [ZigModu × zent](docs/ZENT.md) | **电商/社交主推组合**：zent ORM 正交接入与最佳实践 |
| [SQLx 驱动链接](docs/SQLX_DRIVERS.md) | `-Ddb=` / `.db=` 选择性链接 |
| [分布式](docs/DISTRIBUTED.md) | 多实例、集群栈、fail-closed 启动 |
| [Agent 运行时](docs/AGENT_RUNTIME.md) | **Agent 默认不能直接交易**：`Guard` 两条轴 fail-closed（`execute` 二次开关 + `allow` 默认空） |
| [API参考](docs/API.md) | 完整API文档 |
| [架构设计](docs/ARCHITECTURE.md) | 系统设计与模式 |
| [升级注意](docs/UPGRADING.md) | 逐版本：行为变化与一行改法 |
| [状态与就绪度](docs/dev/v1.0-readiness-v0.35.md) | **哪些证明过、哪些没有** —— 逐条 + 证据 + 日期 |
| [示例项目](examples/) | 可运行的示例 |

## ✨ 功能特性

### 应用平面

**核心框架**
- **模块系统** - 声明式模块定义与元数据
- **依赖验证** - 编译期依赖检查（缺失依赖、自依赖、环依赖都在启动时被拦）
- **生命周期管理** - 自动初始化/清理；模块可声明 `initWith(ctx)` 接收框架设施
- **依赖注入** - Application 内置类型安全容器：启动期注册（`withService` / 借用注册），`start()` 后 freeze，运行期无锁只读
- **事件驱动** - Application 级 `EventRegistry` 只发放线程安全的按类型总线（`app.eventBus(T)`）；另含 Outbox（`zigmodu.outbox.*`）

**数据 / 传输 / 可观测 / 安全**
- **数据** - SQLx（PG / MySQL / SQLite，选择性链接）、ORM Repository、Flyway 风格迁移、缓存、Redis、连接池
- **HTTP** - 异步 fiber 服务器（kqueue / io_uring）、HTTP/2 + h2c、WebSocket（text + **binary**）、gRPC、OpenAPI、SSE、幂等中间件
- **弹性** - 熔断器、令牌桶限流、指数退避重试、自适应丢弃
- **可观测性** - OpenTelemetry 兼容 OTLP 导出 + 重试、Prometheus 指标、JSON 结构化日志、K8s 健康探针
- **安全** - 生产 JWT（`AppSecurity`、墙钟 exp）、`JwksKeyRing` 轮换、PBKDF2 口令、多源 Secrets（env > file > Vault KV v2）、多租户（opt-in）
- **分布式** ⚠️ - `DistributedEventBus`（每节点凭证 + 挑战应答）、Raft 选主与日志复制、Kafka、分片（experimental）

### 执行平面（opt-in，`app.runtime()`）

- **Worker** - 一个 struct，`handle` 或 `run`；线程、mailbox、生命周期都归 runtime
- **Worker pool** - `.mode = .dedicated`（一个 worker 一条线程）或 `.pooled`（N 个 worker / N 条池线程，**worker 状态仍然独占**：claim token 保证同一时刻只有一个线程在跑它）
- **阻塞池** - `.execution_class = .blocking` 把会等进程外的 worker 挪出 CPU 池（宽度用 `Application.withBlockingThreads` 声明）—— 必须声明，框架不会替你检测
- **Mailbox / 队列** - 有界 mailbox（满了是 `error.Full`，不是无限增长）、SPSC RingBuffer、Vyukov MpscRing
- **HotBus** - L0 扇出，`freeze()` 后无锁无分配，满了丢并计数。刻意**不是**通用事件总线
- **定时器** - `TimerWheel`（ms 级、分层 O(1)）与 `PrecisionTimer`（µs 级、min-heap + spin window，实测 p50 0 ns / p99 1 µs）
- **监督** - 每 worker 的失败策略（fail-fast 或窗口内错误预算）+ `onError` 钩子 + 停机策略
- **回放** - `Recorder`（零分配投递日志）→ `DeliveryLog` 段文件（`ZDL1`）→ `ReplayFromLog`（从字节回放，自带 `Codec(E)`）
- **可观测** - `RuntimeStats` + `MetricsBridge` 发布 25 条 `zigmodu_runtime_*`（13 通用 + 6 CPU 池 + 6 阻塞池）
- **零分配契约** - `src/runtime/alloc_contract_test.zig` 用会失败的分配器断言热路径**精确 0**
- **affinity 原语** - `runtime.affinity.pinCurrentThread(cpu)` 在 Linux 真的 pin；macOS / Windows 返回 `error.Unsupported`，不假报成功

## 🚧 它不是什么（采用前先定价）

- **集群升级是硬切**：Raft 帧格式与总线握手都变过，新旧二进制**两个方向都听不懂**（刻意如此，不留"降级到不认证"的路）。混合版本滚动升级**从未跑过** —— 这是[就绪度评估](docs/dev/v1.0-readiness-v0.35.md)里排在第一位的那条。
- **线上不加密**：集群帧目前是明文，生产用边车终结 TLS（[examples/production-deploy](examples/production-deploy/)）；`src/core/cluster/TlsTransport.zig` 存在但**没有调用方**。
- **集群身份：总线是按节点，Raft 是共享 PSK**：拿到 Raft 的 `cluster_secret` 就能冒充任意节点；总线已经换成每节点凭证 + 挑战应答。没有轮换、没有撤销。
- **`ws_uring` 只在 Linux 生效**（io_uring）；其它平台走可移植路径。
- **⚠️ 标的是 experimental 模块**：Saga、SecurityScanner、DistributedEventBus、ClusterMembership、2PC、Plugin、WebMonitor、HotReloader。有测试，但在这里没有生产记录。
- **AI 是可选的领域，不是核心**：`src/ai` 只占一小部分，HTTP / 数据 / 安全 / 可观测核心不依赖它；Agent 默认不能动作（[AGENT_RUNTIME.md](docs/AGENT_RUNTIME.md)）。
- **自评**：这里每一个"已完成"都出自同一批维护者与其 AI agent，**没有独立审计**。逐条带日期的版本在 [docs/dev/v1.0-readiness-v0.35.md](docs/dev/v1.0-readiness-v0.35.md)。

## 🔬 如何验证

上面每一条都要靠门禁兜底；它们全都能在本地跑：

| 门禁 | 证明什么 | 命令 |
|------|----------|------|
| 全量套件（`-Ddb=all`） | 6 个 artifact、2000+ 条测试 | `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test` |
| **分配契约** | mailbox / ring / HotBus / `send` / 定时器热路径**精确 0 分配** | `src/runtime/alloc_contract_test.zig` |
| 生产门禁 | 热路径无裸 `catch {}`、CSPRNG 来源、fuzz 声明与树一致 | `zig build check` |
| API 门禁 | 示例必须走 `zigmodu.http` 规范入口 | `zig build check-api` |
| 死代码 ratchet | `src`+`tools` 基线 28、`examples` 基线 0 | `bash scripts/check-deadcode.sh` |
| 性能 ratchet | 32 条指标对 CI 基线 + 32 条分配预算 | `bash scripts/check-bench.sh` |
| Soak（HTTP + 租户） | 跨租户泄漏、FrozenMap 并发、fd/slot 增长 | `zig build soak` |
| Soak（集群） | 3 节点 raft + 总线：seq 连续、leader 稳定、日志收敛、fd/RSS | `zig build soak-cluster` |
| Runtime 压测 | 长交织下的监督、池、就绪环、定时器、零分配 | `zig build runtime-stress` |
| 走私端到端 | 真 nginx 前置：后端服务过的每一条都是网关收到过的 | `examples/production-deploy/smuggling-e2e/run.sh` |
| 交叉编译 | x86_64-linux（CI 还有 Windows 腿）编译干净 | `zig build test -Dtarget=x86_64-linux -Ddb=none` |

## 🚀 快速开始

先在 `build.zig.zon` 里声明依赖（首次 `zig build` 会拒绝占位的 `.fingerprint`，
并打印出该填的值）：

```zig
.{
    .name = .myapp,                 // 必须是合法的 Zig 标识符
    .version = "0.1.0",
    .fingerprint = 0x0,             // ← 把 `zig build` 提示的值填在这里
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        // 本地检出（examples/basic 就是这么写的，不需要 `.hash`）：
        .zigmodu = .{ .path = "../zigmodu" },
        // ……或用 tag 发布版；`.hash` 交给 `zig fetch --save <url>` 生成：
        // .zigmodu = .{ .url = "git+https://github.com/chy3xyz/zigmodu?ref=v0.25.0" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

再按实际用到的驱动收窄链接（依赖侧默认 `all`，会链三库）：

```zig
const zigmodu_dep = b.dependency("zigmodu", .{
    .target = target,
    .optimize = optimize,
    .db = db_opt, // 或 postgres | mysql | "sqlite,postgres" | all
});
```

命令行上的 `-Ddb=` 需要**你自己的** `build.zig` 声明该 option：

```zig
const db_opt = b.option([]const u8, "db", "SQL drivers to link: all|sqlite|postgres|mysql (comma-list)") orelse "sqlite";
```

详见 [docs/SQLX_DRIVERS.md](docs/SQLX_DRIVERS.md)；完整的 `build.zig`（含 `run` / `test` step）见
[docs/QUICK-START.md](docs/QUICK-START.md) 第 3 步。

### 前置要求

```bash
# 安装 CI 锁定的 Zig dev 版本：
zigup 0.17.0-dev.2151+2ec5523d5
# (https://ziglang.org/download/ · https://github.com/marler8997/zigup)

# dev 版本会被 ziglang 镜像回收（旧版开始 404），所以上面这行天然会过时：
# 以 `.github/workflows/ci.yml` → `ZIG_VERSION` 为准。
# `brew install zig` 装的是 stable 版，**编不过本仓库**（框架用的是 dev API：
# `std.process.Init`、`std.Io.Mutex` 等）。
```

### 创建第一个模块

```zig
// src/modules/user.zig
const std = @import("std");
const zigmodu = @import("zigmodu");

// `pub` 是必须的：main.zig 里通过 `user.UserModule` 引用它。
pub const UserModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "user",
        .description = "用户管理模块",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("用户模块初始化", .{});
    }

    pub fn deinit() void {
        std.log.info("用户模块清理", .{});
    }
};
```

### 启动应用

```zig
// src/main.zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const user = @import("modules/user.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var modules = try zigmodu.scanModules(allocator, .{user.UserModule});
    defer modules.deinit();

    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    std.log.info("应用启动成功！", .{});
}
```

### 事件与 DI（Application 内置）

片段（示意）——`OrderModule` / `OrderEvent` / `AppConfig` / `auditListener`
是你自己的类型，`allocator` / `io` 来自 `std.process.Init`：

```zig
// 模块通过 initWith(ctx) 接收框架设施：
pub fn initWith(ctx: *zmodu.ModuleContext) !void {
    const bus = try ctx.eventBus(OrderEvent);            // 共享线程安全总线
    const cfg = ctx.service(AppConfig, "config") orelse
        return error.MissingService;                     // 启动期 fail-fast
    _ = bus; _ = cfg;
}

// main 组装共享服务；start() 完成后容器冻结：
var b = zmodu.builder(allocator, io);                    // 先绑定：builder 方法收 *Self
defer b.deinit();
var app = try b
    .withService(AppConfig, "config", &config)           // 借用注册：容器不销毁
    .build(.{OrderModule});
defer app.deinit();
try app.start();                                          // initWith 运行 → 容器 freeze

const bus = try app.eventBus(OrderEvent);                // 仅 ThreadSafeEventBus
try bus.subscribe(auditListener);
```

完整规则与反模式：[docs/EVENTS_DI.md](docs/EVENTS_DI.md) · 可运行接线：`examples/shopdemo`。

### 构建与运行

```bash
zig build run
```

## 📖 架构

```
┌─────────────────────────────────────────────────────────┐
│                    ZigModu 应用                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │                 模块系统                             │ │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │ │
│  │  │  用户   │ │  订单   │ │  支付   │ │  产品   │  │ │
│  │  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘  │ │
│  │       └───────────┴────────────┴───────────┘        │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
         │
    ┌─────┴─────┐
    │           │
┌───▼───┐   ┌──▼────┐
│ 事件  │   │ DI    │
│ 总线  │   │ 容器  │
└───────┘   └───────┘
```

## 📁 项目结构

```
zigmodu/
├── src/
│   ├── core/           # 核心框架
│   │   ├── Module.zig
│   │   ├── EventBus.zig
│   │   ├── EventRegistry.zig   # 按类型共享总线（仅线程安全版）
│   │   ├── ModuleContext.zig   # 启动上下文：事件 + 服务 + io
│   │   ├── Lifecycle.zig
│   │   └── ...
│   ├── extensions/      # 扩展功能
│   │   ├── di/
│   │   ├── config/
│   │   └── log/
│   ├── resilience/      # 弹性模式
│   │   ├── CircuitBreaker.zig
│   │   └── RateLimiter.zig
│   ├── tracing/        # 可观测性
│   │   └── DistributedTracer.zig
│   ├── metrics/        # 指标
│   │   └── PrometheusMetrics.zig
│   └── api/            # 公共API
│       └── Simplified.zig
├── docs/               # 文档
├── examples/           # 示例项目
│   ├── basic/          # 基础示例
│   ├── event-driven/   # 事件驱动
│   ├── distributed/    # 分布式部署
│   └── ...
└── tests/              # 测试套件
```

## 🎯 渐进式演进

ZigModu 沿**两条正交的轴**成长 —— 可以在一条上走而不动另一条，且两条都不需要拆服务：

| 轴 | 阶段 | 你加什么 | 读哪份 |
|----|------|----------|--------|
| **应用** | 一个进程 | 模块 + 编译期依赖规则、DI、HTTP、数据 | [BEST_PRACTICES.md](docs/BEST_PRACTICES.md) |
| | 多实例 | 限流、熔断、分布式锁、缓存 / Redis、outbox | 同上 |
| | 集群 | `DistributedEventBus` + Raft（`ClusterBootstrap`）、Kafka、分片 | [DISTRIBUTED.md](docs/DISTRIBUTED.md) —— 注意硬切升级边界 |
| **执行** | 请求 → 响应 | 什么都不用做：fiber + 连接池就是为这个形状准备的 | [MODULITH.md](docs/MODULITH.md) |
| | 跨请求的状态 | 持有状态的 worker（`app.runtime()`） | [RUNTIME.md](docs/RUNTIME.md) |
| | 同类 worker 很多 | `.mode = .pooled`：N 个 worker 跑在 N 条池线程上，状态仍独占 | 同上 |
| | 延迟敏感 | `.dedicated` worker、µs 级 `PrecisionTimer`、回放做回测 | [alpha-engine](examples/alpha-engine) |
| | 等进程外的东西 | `.execution_class = .blocking`（否则会吃掉 CPU 池的线程） | 同上 |

应用平面的详细演进指南见[最佳实践](docs/BEST_PRACTICES.md)。

## 🛠️ 命令

```bash
# 构建与运行
zig build && zig build run

# 门禁（每一条都对应 CI 的一个 job 或其中一个 step）
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test    # 全量（默认 -Ddb=all）
bash scripts/test-fast.sh --filter RaftElection --db none --force-run   # 单族测试
zig build check check-api && zig fmt --check src tools examples
bash scripts/check-deadcode.sh && bash scripts/check-bench.sh && bash scripts/check-production.sh

# 长跑 harness
zig build soak           # HTTP + 租户
zig build soak-cluster   # 3 节点 raft + 总线
zig build runtime-stress # 执行平面长交织

# 工具链与部署
zig build zmodu && ./zig-out/bin/zmodu runtime examples/alpha-engine
docker compose up -d
```

## 📦 示例

每个目录都是可运行工程、各自带 README；索引见 [examples/README.md](examples/README.md)。先读这几个：

| 示例 | 展示什么 |
|------|----------|
| **[tenant-mgmt](examples/tenant-mgmt/)** | **应用平面端到端**：多租户 SaaS、模块图、中间件链、权限目录、健康探针（CI 集成目标） |
| **[runtime-workers](examples/runtime-workers/)** | **执行平面**：worker、mailbox、HotBus、监督 —— `app.runtime()` 的最小完整用法 |
| **[alpha-engine](examples/alpha-engine/)** | **执行平面存在的理由**：feed → 订单簿 → alpha → 风控 → 执行 |
| **[production-deploy](examples/production-deploy/)** | TLS 边车（nginx/Envoy）、k8s、systemd、Dockerfile、真实前置代理的走私 e2e |
| [zent-modulith](examples/zent-modulith/) · [tenant-shop](examples/tenant-shop/) | zent 组合 / 模块分层参考实现 |
| [basic](examples/basic/) · [event-driven](examples/event-driven/) · [distributed](examples/distributed/) | 小范例：模块、事件 + outbox、跨节点总线 |

## 🤝 贡献

欢迎贡献！先读 [CONTRIBUTING.md](CONTRIBUTING.md)；提交前把 CI 跑的东西跑一遍：

```bash
git clone https://github.com/chy3xyz/zigmodu.git
git checkout -b feature/my-feature
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
zig build check check-api && zig fmt --check src tools examples
```

## 📄 许可证

MIT License - 查看 [LICENSE](LICENSE) 了解详情。

## 🙏 致谢

- [Spring Modulith](https://github.com/spring-projects/spring-modulith) - 架构灵感
- [Zig社区](https://ziglang.org/community/) - 语言生态
- [贡献者](https://github.com/knot3bot/zigmodu/graphs/contributors) - 代码贡献
