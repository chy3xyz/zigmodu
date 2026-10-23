# zmodu v0.43.1

面向 Zig 0.17 的编译期模块化应用框架与 Worker 执行运行时。

[![Zig](https://img.shields.io/badge/Zig-0.17+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/github/v/release/chy3xyz/zmodu?style=flat-square)]()
[![CI](https://github.com/chy3xyz/zmodu/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/chy3xyz/zmodu/actions/workflows/ci.yml)

[English](README.md) | 中文

## 概览

zmodu 在单一库中提供两个正交平面：

| 平面 | 核心能力 | 入口文档 |
|------|----------|----------|
| **应用平面**（默认） | 编译期模块依赖图校验、生命周期管理、DI 容器、HTTP/1.1 + HTTP/2 + WebSocket + gRPC、SQLx / ORM / 迁移、Redis + LRU 缓存、EventBus + 事务性 Outbox、JWT / RBAC / 多租户、限流熔断、Prometheus 指标与 OpenTelemetry 追踪 | [Quick Start](docs/guide/QUICK-START.md) · [Modulith 架构](docs/guide/MODULITH.md) |
| **执行平面**（按需启用） | 单线程独占状态的 Worker、有界 Mailbox、无锁 SPSC/MPSC 环形队列、无锁 `HotBus` 扇出、毫秒 `TimerWheel` 与微秒 `PrecisionTimer`、监督树、确定性投递日志回放（`ZDL1`） | [Runtime 参考](docs/reference/RUNTIME.md) |

未调用 `app.runtime()` 的应用不会启动额外的运行时线程。执行平面适用于订单簿、实时网关、AI Agent 循环和有状态流水线等无法仅用「一请求一 Fiber」模型表达的场景。

## 快速开始

### 1. 环境要求

安装 Zig `0.17.0`（与 `.github/workflows/ci.yml` 中的 `ZIG_VERSION` 一致）：

```bash
zigup 0.17.0
zig version
```

### 2. 配置依赖

在 `build.zig.zon` 中声明依赖：

```zig
.{
    .name = .myapp,
    .version = "0.1.0",
    .fingerprint = 0x0, // 首次运行 `zig build` 后替换为提示的 fingerprint
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .zmodu = .{ .path = "../zmodu" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

在 `build.zig` 中按需选择数据库驱动（`sqlite`、`postgres`、`mysql`、`none` 或 `all`）：

```zig
const db_opt = b.option([]const u8, "db", "SQL drivers: all|sqlite|postgres|mysql|none") orelse "sqlite";

const zmodu_dep = b.dependency("zmodu", .{
    .target = target,
    .optimize = optimize,
    .db = db_opt,
});
exe_mod.addImport("zmodu", zmodu_dep.module("zmodu"));
```

### 3. 领域导入

按需导入领域桶：

```zig
const zmodu = @import("zmodu");

const http = zmodu.http;              // Server, Router, Context, Middleware, extract*, sse
const data = zmodu.data;              // SQLx, Repository, MigrationRunner, Cache, Redis
const sec  = zmodu.security;          // AppSecurity, CatalogPermDb, PasswordEncoder, Secrets
const obs  = zmodu.observability;     // PrometheusMetrics, DistributedTracer, OtlpExporter
```

### 4. 最小应用与 HTTP 服务

```zig
const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;

pub const panic = zmodu.panicHook;

pub const UserModule = struct {
    pub const info = zmodu.api.Module{
        .name = "user",
        .description = "User management module",
        .dependencies = &.{},
    };

    pub fn init() !void {}
    pub fn deinit() void {}
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 先绑定 builder 变量（builder 方法接收 `*Self`）
    var b = zmodu.builder(allocator, io);
    defer b.deinit();
    var app = try b.withName("myapp").build(.{UserModule});
    defer app.deinit();

    try app.start();
    defer app.stop();

    var server = http.Server.init(io, allocator, 8080);
    defer server.deinit();

    var profile = http.ProductionProfileState.init(allocator);
    defer profile.deinit(allocator);
    try http.productionProfile(&server, .{
        .max_connections = 4096,
        .header_timeout_ms = 10_000,
    }, &profile);

    try server.addRoute(.{
        .method = .GET,
        .path = "/api/ping",
        .handler = struct {
            fn handle(ctx: *http.Context) anyerror!void {
                try ctx.jsonStruct(200, .{ .ok = true });
            }
        }.handle,
    });

    try server.start();
}
```

## 文档索引

默认文档语言为英文，详见 [`docs/README.md`](docs/README.md)：

| 分类 | 文档 |
|------|------|
| **入门** | [Quick Start](docs/guide/QUICK-START.md) · [CLI 与代码生成](docs/guide/ZMODU_CLI_INTEGRATION.md) · [Modulith 架构](docs/guide/MODULITH.md) · [领域分层](docs/guide/MODULE_LAYERS.md) |
| **指南** | [事件与 DI](docs/guide/EVENTS_DI.md) · [SQLx 驱动链接](docs/guide/SQLX_DRIVERS.md) · [Workflow 与 Saga](docs/guide/WORKFLOW.md) · [结构化日志](docs/guide/LOGGING.md) · [最佳实践](docs/guide/BEST_PRACTICES.md) |
| **参考规范** | [系统架构](docs/reference/ARCHITECTURE.md) · [声明式路由与鉴权](docs/reference/ROUTE_TABLE.md) · [Runtime 运行时](docs/reference/RUNTIME.md) · [可观测性](docs/reference/OBSERVABILITY.md) · [分布式系统](docs/reference/DISTRIBUTED.md) · [Zent ORM](docs/reference/ZENT.md) · [Web4](docs/reference/WEB4.md) · [API 参考](docs/reference/API.md) · [版本升级](docs/reference/UPGRADING.md) |
| **AI 子系统** | [AI 概览](docs/ai/README.md) · [AI 开发指南](docs/ai/AI_DEV_GUIDE.md) · [Agent 运行时](docs/reference/AGENT_RUNTIME.md) · [内置技能](docs/ai/AI_SKILLS.md) · [流程编排](docs/ai/AI_ORCHESTRATION.md) · [LLM 策略](docs/ai/LLM_POLICIES.md) · [MCP 桥接](docs/ai/MCP.md) |
| **AI 协作规范** | [AGENTS.md](AGENTS.md) · [API 冻结面](docs/reference/API_FREEZE.md) · [1.0 就绪状态](docs/dev/v1.0-readiness-v0.35.md) |

## 常用门禁与命令

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
bash scripts/test-fast.sh --db all --filter "RaftElection" --force-run
zig build fmt-check
zig build check
zig build check-api
bash scripts/check-deadcode.sh
bash scripts/check-doc-paths.sh
bash scripts/check-version.sh
```

## 许可证

[MIT License](LICENSE)
