# ZigModu v0.15.16

一个为 Zig **0.17.0** 打造的模块化应用框架，受 Spring Modulith 启发。从单体架构到分布式系统，支持渐进式架构演进。

[![Zig](https://img.shields.io/badge/Zig-0.17+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/github/v/release/chy3xyz/zigmodu?style=flat-square)]()

[English](README.md) | 中文

## 📚 文档

| 指南 | 描述 |
|------|------|
| [**AGENTS.md**](AGENTS.md) | **AI 操作手册**（DO/DON'T、Path A 鉴权、ComptimeRouter） |
| [快速开始](docs/QUICK-START.md) | 5分钟入门 |
| [Modulith 高并发](docs/MODULITH.md) | 项目第一天：模块边界 + 高并发实践 |
| [声明式路由](docs/ROUTE_TABLE.md) | ComptimeRouter + catalog JWT/RBAC |
| [ZigModu × zent](docs/ZENT.md) | zent ORM 正交接入与最佳实践 |
| [SQLx 驱动链接](docs/SQLX_DRIVERS.md) | `-Ddb=` / `.db=` 选择性链接 |
| [最佳实践](docs/BEST_PRACTICES.md) | DAU 演进 + JWT / 多端身份清单 |
| [API参考](docs/API.md) | 完整API文档 |
| [架构设计](docs/ARCHITECTURE.md) | 系统设计与模式 |
| [示例项目](examples/) | 可运行的示例 |

## ✨ 功能特性

### 核心框架
- **模块系统** - 声明式模块定义与元数据
- **依赖验证** - 编译期依赖检查
- **生命周期管理** - 自动初始化/清理
- **事件驱动** - 类型安全的事件总线

### 分布式能力
- **DistributedEventBus** - 跨节点事件通信
- **ClusterMembership & Raft** - 节点发现、Raft 选主与日志压缩 (`compactLog` / `InstallSnapshot`)
### 弹性模式
- **熔断器** - 三态防止级联故障
- **限流器** - 令牌桶算法与 Redis 自动降级
- **重试策略** - 指数退避与抖动

### 传输与API
- **HTTP服务器** - 异步纤程服务器，支持路由、中间件与级联背压控流
- **gRPC & Kafka** - gRPC Unary + Kafka Wire 协议与 EventBridge

### 可观测性
- **分布式追踪** - OpenTelemetry 兼容 (`OtlpExporter` OTLP/HTTP JSON 上报 + 重试)
- **Prometheus指标** - Counter, Gauge, Histogram 与 HTTP 路由自动关联
- **结构化日志** - JSON 格式与轮转
- **深层健康检查** - 兼容 K8s liveness/readiness 探针与 Pool 水位

### 安全与工具链 (DX)
- **AppSecurity** - std.Io 墙钟 JWT 验证与 `JwksKeyRing` 动态密钥轮换
- **zmodu 代码生成 CLI** - 内置项目脚手架与 MCP Server (`zig build zmodu`)

## 🚀 快速开始

应用依赖 zigmodu 时建议显式收窄 SQL 驱动（默认 `all` 会链三库）：

```zig
const zigmodu_dep = b.dependency("zigmodu", .{
    .target = target,
    .optimize = optimize,
    .db = "sqlite", // 详见 docs/SQLX_DRIVERS.md
});
```

### 前置要求

```bash
# 安装 Zig 0.17.0 — https://ziglang.org/download/
brew install zig   # 或以官网包为准，确保 zig version → 0.17.0
```

### 创建第一个模块

```zig
// src/modules/user.zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const UserModule = struct {
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

    var modules = try zigmodu.scanModules(allocator, .{user});
    defer modules.deinit();

    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    std.log.info("应用启动成功！", .{});
}
```

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

ZigModu 随应用一起成长：

| 阶段 | 日活 | 架构 | 核心能力 |
|------|------|------|----------|
| 1 | 0-1K | 单体 | 模块 + 生命周期 |
| 2 | 1K-10K | 垂直扩展 | 缓存 + 异步 |
| 3 | 10K-100K | 多实例 | DistributedEventBus + 集群 |
| 4 | 100K-1M | 服务网格 | CircuitBreaker + 追踪 |
| 5 | 1M+ | 全球规模 | 热更新 + 插件 |
查看 [最佳实践](BEST_PRACTICES.md) 了解详细演进指南。

## 🛠️ 命令

```bash
# 构建
zig build

# 运行测试
zig build test

# 运行示例
zig build run

# 格式化代码
zig fmt
```

KM|## 📦 示例
JR|
XN|| 示例 | 描述 | 运行 |
PN||------|------|------|
SW|| [基础](examples/basic/) | 模块基础 | `cd examples/basic && zig build run` |
PJ|| [事件驱动](examples/event-driven/) | 发布订阅 | `cd examples/event-driven && zig build run` |
WT|| [测试](examples/testing/) | 测试工具 | `cd examples/testing && zig build test` |
JP|| [HTTP压力测试](examples/http-stress-test/) | 并发连接 | `cd examples/http-stress-test && zig build run` |
NW|| [元宇宙创意](examples/metaverse-creative/) | 创意演示 | `cd examples/metaverse-creative && zig build run` |

## 🤝 贡献

欢迎贡献！查看 [CONTRIBUTING.md](CONTRIBUTING.md)。

```bash
# Fork并克隆
git clone https://github.com/yourusername/zigmodu.git

# 创建功能分支
git checkout -b feature/my-feature

# 运行测试
zig build test

# 提交并推送
git add . && git commit -m "feat: add feature" && git push
```

## 📄 许可证

MIT License - 查看 [LICENSE](LICENSE) 了解详情。

## 🙏 致谢

- [Spring Modulith](https://github.com/spring-projects/spring-modulith) - 架构灵感
- [Zig社区](https://ziglang.org/community/) - 语言生态
- [贡献者](https://github.com/knot3bot/zigmodu/graphs/contributors) - 代码贡献
