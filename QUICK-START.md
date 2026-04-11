# ZigModu Quick Reference

## 🚀 快速开始

### 1. 定义模块
```zig
const MyModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "my-module",
        .description = "A sample module",
        .dependencies = &.{"other-module"},  // 可选
    };

    pub fn init() !void {
        std.log.info("Module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("Module cleaned up", .{});
    }
};
```

### 2. 创建应用（推荐方式）
```zig
var app = try zigmodu.Application.init(
    allocator,
    "my-app",                           // 应用名称
    .{ Module1, Module2, Module3 },    // 模块列表
    .{
        .validate_on_start = true,      // 自动验证依赖
        .auto_generate_docs = true,     // 自动生成文档
        .docs_path = "docs/app.puml",   // 文档路径
    },
);
defer app.deinit();

try app.start();
// 应用运行中...
// deinit 自动按依赖顺序停止模块
```

### 3. 使用 Builder 模式
```zig
var builder = zigmodu.builder(allocator);
defer builder.deinit();

var app = try builder
    .withName("my-app")
    .withValidation(true)
    .withDocsPath("docs/app.puml")
    .withAutoDocs(true)
    .build(.{ Module1, Module2 });
defer app.deinit();

try app.start();
```

## 📦 核心 API

### Application 状态
```zig
const state = app.getState();
// .initialized, .validated, .started, .stopped
```

### 模块管理
```zig
// 检查模块是否存在
if (app.hasModule("my-module")) { }

// 获取模块信息
const info = app.getModule("my-module");
```

### 文档生成
```zig
// 自动生成（配置中设置）
// 或手动调用
try app.generateDocs("path/to/docs.puml");
```

## 💉 依赖注入

### 基础用法
```zig
var container = zigmodu.extensions.Container.init(allocator);
defer container.deinit();

// 注册服务
const service = try allocator.create(MyService);
try container.register(MyService, "service", service);

// 获取服务
const svc = container.get(MyService, "service");
if (svc) |s| {
    s.doSomething();
}
```

### 作用域容器
```zig
var parent = Container.init(allocator);
var child = ScopedContainer.init(allocator, "module-scope", &parent);
defer child.deinit();

// 子容器可以访问父容器的服务
const svc = child.get(MyService, "service");
```

## 📊 事件总线

### 定义事件
```zig
const OrderEvent = struct {
    order_id: u64,
    status: enum { pending, confirmed, shipped },
};
```

### 创建和使用
```zig
var bus = zigmodu.EventBus(OrderEvent).init(allocator);
defer bus.deinit();

// 订阅事件
try bus.subscribe(struct {
    fn handle(event: OrderEvent) void {
        std.log.info("Order {d} is {s}", .{ event.order_id, @tagName(event.status) });
    }
}.handle);

// 发布事件
bus.publish(.{ .order_id = 123, .status = .confirmed });
```

## 🧪 测试支持

### 模块测试
```zig
test "My Module" {
    const allocator = std.testing.allocator;
    
    var ctx = try zigmodu.extensions.ModuleTestContext.init(allocator, "my-module");
    defer ctx.deinit();
    
    try ctx.start();
    // 测试模块功能
    ctx.stop();
}
```

### Mock 模块
```zig
const mock = zigmodu.extensions.createMockModule(
    "mock-module",
    "Mock for testing",
    &.{"dependency"},
);
```

## 🏗️ 架构测试

### 基础用法
```zig
var tester = zigmodu.ArchitectureTester.init(allocator, &app.modules);
defer tester.deinit();

// 运行默认规则
try tester.runDefaultRules();

// 检查违规
const passed = try tester.verify();
if (!passed) {
    try tester.printReport(std.io.getStdOut().writer());
}
```

### 自定义规则
```zig
// 限制依赖数量
try tester.ruleLimitedDependencies(5);

// 检查基础模块不依赖业务模块
try tester.ruleBaseModulesShouldNotDependOnOthers(&.{"core", "utils"});
```

## 📈 最佳实践

### 1. 模块设计
- 保持模块单一职责
- 明确定义依赖关系
- 提供清晰的 init/deinit 函数

### 2. 错误处理
```zig
app.start() catch |err| {
    std.log.err("Failed to start: {s}", .{@errorName(err)});
    return err;
};
```

### 3. 资源管理
```zig
// 使用 defer 确保清理
defer app.deinit();  // 自动停止所有模块
```

### 4. 配置管理
```zig
var config = try zigmodu.extensions.ConfigLoader.loadJson("config.json");
defer config.deinit();

const db_url = config.getString("database.url") orelse "localhost";
```

## 🔗 完整示例

参见 `example-new/src/main.zig` 获取完整的电商应用示例。

## 📚 更多文档

- [API 优化说明](docs/API-REFACTORING.md)
- [架构指南](docs/ARCHITECTURE.md)
- [API 参考](docs/API.md)
