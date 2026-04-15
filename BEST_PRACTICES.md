# ZigModu 最佳实践指南 (Best Practices Guide)

## 📋 目录 (Table of Contents)

- [模块设计原则](#模块设计原则)
- [代码质量规范](#代码质量规范)
- [错误处理](#错误处理)
- [内存管理](#内存管理)
- [测试策略](#测试策略)
- [性能优化](#性能优化)
- [安全实践](#安全实践)
- [部署与CI/CD](#部署与cicd)
- [文档规范](#文档规范)

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

## 🔒 安全实践

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
        zig-version: ["0.15.2"]
    
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