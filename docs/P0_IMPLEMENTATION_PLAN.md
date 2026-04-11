# P0 功能实现计划

## 🎯 Phase 1: 编译时模块边界检查

### 目标
实现编译时验证，阻止非法模块导入，确保模块边界清晰。

### 设计
```zig
// src/core/ModuleBoundary.zig
const std = @import("std");

/// 模块边界验证器
pub const ModuleBoundary = struct {
    /// 验证模块只通过 Public API 访问其他模块
    pub fn validate(comptime module: type) void {
        const info = @typeInfo(module);
        
        // 检查模块定义
        if (!@hasDecl(module, "info")) {
            @compileError("Module must have 'info' declaration");
        }
        
        // 检查 exports - 只允许导出 public API
        inline for (info.Struct.decls) |decl| {
            const is_public = decl.is_pub;
            const name = decl.name;
            
            // 检查是否导出内部实现
            if (is_public and isInternalName(name)) {
                @compileError("Module exports internal implementation: " ++ name);
            }
        }
    }
    
    fn isInternalName(comptime name: []const u8) bool {
        return std.mem.startsWith(u8, name, "_") or
               std.mem.endsWith(u8, name, "Internal");
    }
};

/// 使用示例
comptime {
    ModuleBoundary.validate(@import("order/module.zig"));
}
```

### 实现步骤
1. 创建 `src/core/ModuleBoundary.zig`
2. 实现基础边界检查（导出验证）
3. 实现导入验证（防止直接访问内部）
4. 集成到 `scanModules`
5. 添加编译错误提示

### 验收标准
- [ ] 编译时检测非法导出
- [ ] 清晰的错误信息
- [ ] 支持白名单配置

---

## 🎯 Phase 2: 声明式事件系统

### 目标
实现类似 @PublishedEvent 的声明式事件发布机制。

### 设计
```zig
// src/core/EventPublisher.zig
const std = @import("std");

/// 事件发布者 trait
pub fn EventPublisher(comptime T: type) type {
    return struct {
        /// 发布领域事件
        /// 自动从返回值提取事件
        pub fn publish(self: *T, comptime EventType: type) !void {
            // 编译时生成发布代码
        }
    };
}

/// 使用示例
const OrderService = struct {
    event_bus: *EventBus(OrderEvent),
    
    /// 完成订单并自动发布 OrderCompleted 事件
    pub fn completeOrder(self: *OrderService, id: u64) !Order {
        const order = try self.doComplete(id);
        
        // 声明式发布
        try self.publish(OrderCompleted{ .order_id = id });
        
        return order;
    }
};
```

### 关键特性
1. **自动事件发布**
   ```zig
   pub fn completeOrder(...) !Order {
       // 业务逻辑
       return order;  // 自动发布 OrderCompleted
   }
   ```

2. **显式事件发布**
   ```zig
   try self.event_bus.publish(OrderEvent{...});
   ```

3. **类型安全**
   - 编译时验证事件类型
   - 防止发布未注册事件

### 实现步骤
1. 增强 EventBus 支持元数据
2. 实现事件注册宏
3. 添加发布者 trait
4. 集成到 Application

### 验收标准
- [ ] 支持声明式发布
- [ ] 类型安全验证
- [ ] 性能开销 < 5%

---

## 🎯 Phase 3: 自动事件监听

### 目标
实现编译时扫描和自动注册事件监听器。

### 设计
```zig
// src/core/EventListener.zig

/// 事件监听 trait
pub fn EventListener(comptime T: type) type {
    return struct {
        /// 监听器配置
        pub const Config = struct {
            async_mode: bool = false,
            priority: i32 = 0,  // 执行优先级
        };
        
        /// 自动注册到 EventBus
        pub fn autoRegister(self: *T, bus: anytype) !void {
            // 编译时扫描 @handle 方法
            inline for (@typeInfo(T).Struct.decls) |decl| {
                if (isEventHandler(decl)) {
                    try registerHandler(self, bus, decl);
                }
            }
        }
    };
}

/// 使用示例
const OrderListener = struct {
    pub const config = EventListener.Config{
        .async_mode = true,
        .priority = 10,
    };
    
    /// 标记为事件处理器
    pub fn handleOrderCompleted(self: *OrderListener, event: OrderCompleted) !void {
        // 处理事件
    }
};
```

### 实现步骤
1. 定义 EventListener trait
2. 实现编译时扫描
3. 集成到 Application 启动流程
4. 支持优先级排序

### 验收标准
- [ ] 自动扫描监听器
- [ ] 支持优先级
- [ ] 异步执行选项

---

## 🎯 Phase 4: 测试框架增强

### 目标
提供类似 @ModulithTest 的测试支持。

### 设计
```zig
// src/test/ModulithTest.zig

/// Modulith 测试上下文
pub fn ModulithTest(comptime modules: anytype) type {
    return struct {
        app: Application,
        event_capture: EventCapture,
        
        pub fn init(allocator: Allocator) !@This() {
            var app = try Application.init(allocator, "test", modules, .{
                .validate_on_start = true,
            });
            
            return .{
                .app = app,
                .event_capture = EventCapture.init(allocator),
            };
        }
        
        /// 验证事件已发布
        pub fn expectEvent(self: *@This(), comptime T: type) !T {
            const captured = try self.event_capture.waitFor(T, 1000);
            return captured;
        }
        
        /// 验证事件数量
        pub fn expectEventCount(self: *@This(), comptime T: type, count: usize) !void {
            const actual = self.event_capture.count(T);
            if (actual != count) {
                return error.UnexpectedEventCount;
            }
        }
    };
}

/// 使用示例
test "order completion publishes event" {
    var ctx = try ModulithTest(.{OrderModule, InventoryModule}).init(allocator);
    defer ctx.deinit();
    
    try ctx.app.start();
    
    // 执行业务操作
    const order = try orderService.complete(123);
    
    // 验证事件
    const event = try ctx.expectEvent(OrderCompleted);
    try std.testing.expectEqual(event.order_id, 123);
}
```

### 关键特性
1. **自动模块扫描** - 只加载测试需要的模块
2. **事件捕获** - 自动记录所有发布的事件
3. **断言 DSL** - 流畅的事件验证 API
4. **隔离性** - 每个测试独立上下文

### 实现步骤
1. 创建 ModulithTest 结构
2. 实现 EventCapture
3. 添加断言 DSL
4. 集成到测试 runner

### 验收标准
- [ ] 自动模块隔离
- [ ] 事件捕获/验证
- [ ] 清晰的测试 API

---

## 📅 时间线

| 阶段 | 功能 | 工期 | 负责人 |
|------|------|------|--------|
| Week 1 | 模块边界检查 | 5 天 | - |
| Week 2-3 | 声明式事件 | 10 天 | - |
| Week 4 | 自动监听 | 5 天 | - |
| Week 5-6 | 测试框架 | 10 天 | - |

**总计**: 约 6 周完成 P0 功能

---

## 🔧 技术要点

### 1. 编译时代码生成
```zig
// 使用 comptime 生成验证代码
comptime {
    const module_info = analyzeModule(OrderModule);
    generateBoundaryCheck(module_info);
}
```

### 2. 类型安全事件
```zig
// 编译时事件注册表
const EventRegistry = struct {
    comptime var events: []const type = &[]type{};
    
    pub fn register(comptime T: type) void {
        events = events ++ &[1]type{T};
    }
};
```

### 3. 测试隔离
```zig
// 使用 arena allocator 确保测试隔离
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

var ctx = try ModulithTest.init(arena.allocator());
```

---

## ✅ 成功标准

完成 P0 功能后，ZigModu 应达到：

1. **编译时安全**
   - 非法模块导入在编译期报错
   - 清晰、可操作的错误信息

2. **事件系统**
   - 支持声明式和命令式发布
   - 自动监听器注册
   - 类型安全

3. **测试支持**
   - 模块隔离测试
   - 事件断言
   - 与 Zig 测试框架无缝集成

4. **文档**
   - 完整 API 文档
   - 迁移指南
   - 最佳实践

**完成度目标**: 从 65% 提升至 **85%**
