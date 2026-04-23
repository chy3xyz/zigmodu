# ZigModu

一个为 Zig 0.16.0 打造的模块化应用框架，受 Spring Modulith 启发。从单体架构到分布式系统，支持渐进式架构演进。

[![Zig](https://img.shields.io/badge/Zig-0.16.0+-orange?style=flat-square)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)](LICENSE)
[![Build](https://img.shields.io/badge/Build-Passing-green?style=flat-square)](https://github.com/knot3bot/zigmodu/actions)

[English](README.md) | 中文

## 📚 文档

| 指南 | 描述 |
|------|------|
| [快速开始](docs/QUICK-START.md) | 5分钟入门 |
| [最佳实践](docs/BEST_PRACTICES.md) | 从1K到1M+日活的架构演进 |
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
- **ClusterMembership** - 节点发现与健康检查
### 弹性模式
- **熔断器** - 防止级联故障
- **限流器** - 令牌桶算法
- **重试策略** - 指数退避

### 传输与API
- **HTTP服务器** - 异步纤程服务器，支持路由和中间件
### 可观测性
- **分布式追踪** - OpenTelemetry兼容
- **Prometheus指标** - Counter, Gauge, Histogram
- **结构化日志** - JSON格式

### 开发者体验
- **热更新** - 运行时模块替换
- **插件系统** - 动态扩展加载
- **Web监控** - HTTP仪表板
- **架构测试器** - 设计规则验证

## 🚀 快速开始

### 前置要求

```bash
# 安装 Zig 0.16.0
brew install zig@0.16.0  # macOS
# 或
apt install zig=0.16.0   # Linux
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