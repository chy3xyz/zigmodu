# ZigModu

[![Zig Version](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/yourusername/zigmodu/workflows/CI/badge.svg)](https://github.com/yourusername/zigmodu/actions)

> 受 Spring Modulith 启发的 Zig 模块化应用框架

[English](README.md) | [中文](README.zh.md)

## 概述

ZigModu 是一个为 Zig 0.15.2 打造的模块化应用框架，将模块化架构的强大功能带入 Zig 生态系统。它提供编译期模块验证、依赖注入、事件驱动通信和自动生成文档等功能。

### 核心特性

- 🏗️ **模块化架构** - 使用显式依赖定义模块
- ✅ **编译期验证** - 在编译时检查模块依赖
- 🔄 **事件总线** - 类型安全的模块间通信
- 📝 **自动文档** - 从模块结构生成 PlantUML 图表
- 💉 **依赖注入** - 简单的服务管理 DI 容器
- ⚡ **零运行时开销** - 编译期模块扫描
- 🧪 **测试支持** - 模块级测试工具
- 📊 **可观测性** - 模块特定的日志和生命周期跟踪

## 快速开始

### 安装

添加 ZigModu 到你的 `build.zig.zon`：

```zig
.{
    .name = "my-app",
    .version = "0.1.0",
    .dependencies = .{
        .zigmodu = .{
            .url = "https://github.com/yourusername/zigmodu/archive/refs/tags/v0.1.0.tar.gz",
            .hash = "...",
        },
    },
}
```

### 定义模块

```zig
const api = @import("zigmodu").api;

pub const info = api.Module{
    .name = "order",
    .description = "订单管理模块",
    .dependencies = &.{"inventory"},  // 依赖库存模块
};

pub fn init() !void {
    std.log.info("订单模块已初始化", .{});
}

pub fn deinit() void {
    std.log.info("订单模块已清理", .{});
}
```

### 创建应用

```zig
const std = @import("std");
const zigmodu = @import("zigmodu");

const order = @import("modules/order.zig");
const inventory = @import("modules/inventory.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. 扫描模块
    var modules = try zigmodu.scanModules(allocator, .{ order, inventory });
    defer modules.deinit();

    // 2. 验证依赖
    try zigmodu.validateModules(&modules);

    // 3. 生成文档
    try zigmodu.generateDocs(&modules, "docs/modules.puml", allocator);

    // 4. 启动所有模块
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    std.log.info("应用启动成功！", .{});
}
```

### 运行应用

```bash
$ zig build run
info: ✅ 所有模块依赖已验证
info: 订单模块已初始化
info: 库存模块已初始化
info: ✅ 所有模块已启动
info: 应用启动成功！
info: 订单模块已清理
info: 库存模块已清理
info: ✅ 所有模块已停止
```

## 项目结构

```
my-app/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig
│   └── modules/
│       ├── order.zig
│       ├── inventory.zig
│       └── payment.zig
└── docs/
    └── modules.puml
```

## 文档

- [API 参考](docs/API.md)
- [架构指南](docs/ARCHITECTURE.md)
- [示例](examples/)
- [贡献指南](CONTRIBUTING.md)

## 核心概念

### 模块定义

每个模块是一个 Zig 文件，导出：
- `info`：模块元数据（名称、描述、依赖）
- `init()`：可选的初始化函数
- `deinit()`：可选的清理函数

### 依赖验证

ZigModu 在两个层面验证模块依赖：
1. **编译期**：模块引用的类型检查
2. **运行时**：验证所有依赖是否存在

### 事件总线

使用类型安全的事件在模块间通信：

```zig
const EventBus = @import("zigmodu").EventBus;

const OrderEvent = struct {
    order_id: u64,
    status: OrderStatus,
};

var bus = EventBus(OrderEvent).init(allocator);
defer bus.deinit();

// 订阅
try bus.subscribe(handleOrderEvent);

// 发布
bus.publish(.{ .order_id = 123, .status = .confirmed });
```

### 依赖注入

```zig
const Container = @import("zigmodu").extensions.Container;

var container = Container.init(allocator);
defer container.deinit();

// 注册服务
var db = Database.init(allocator);
try container.register("database", &db);

// 获取服务
const db_ptr = container.getTyped("database", Database);
```

## 测试

运行测试套件：

```bash
$ zig build test
```

模块级测试：

```zig
const ModuleTestContext = @import("zigmodu").extensions.ModuleTestContext;

test "订单模块" {
    var ctx = try ModuleTestContext.init(allocator, "order");
    defer ctx.deinit();
    
    try ctx.start();
    // 测试你的模块...
    ctx.stop();
}
```

## 基准测试

```bash
$ zig build benchmark
```

## 贡献

我们欢迎贡献！请参阅 [CONTRIBUTING.md](CONTRIBUTING.md) 了解指南。

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件。

## 致谢

- 灵感来自 [Spring Modulith](https://spring.io/projects/spring-modulith)
- 使用 [Zig](https://ziglang.org/) 0.15.2 构建
- 使用 [zio](https://github.com/lalinsky/zio) 作为异步运行时

## 路线图

- [ ] YAML/TOML 配置支持
- [ ] 模块热重载
- [ ] 分布式事件总线
- [ ] 模块监控 Web 界面
- [ ] 插件系统

---

**用 ❤️ 由 ZigModu 团队制作**